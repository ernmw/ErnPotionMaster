--[[
ErnPotionMaster for OpenMW.
Copyright (C) 2026 Erin Pentecost

This program is free software: you can redistribute it and/or modify
it under the terms of the GNU Affero General Public License as
published by the Free Software Foundation, either version 3 of the
License, or (at your option) any later version.

This program is distributed in the hope that it will be useful,
but WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
GNU Affero General Public License for more details.

You should have received a copy of the GNU Affero General Public License
along with this program.  If not, see <https://www.gnu.org/licenses/>.
]]

local MOD_NAME            = require("scripts.ErnPotionMaster.ns")
local const               = require("scripts.ErnPotionMaster.const")
local ui                  = require("openmw.ui")
local util                = require("openmw.util")
local pself               = require("openmw.self")
local core                = require("openmw.core")
local types               = require("openmw.types")
local placepins           = require("scripts.ErnPotionMaster.placepins")
local settings            = require("scripts.ErnPotionMaster.settings.settings")
local physics             = require("scripts.ErnPotionMaster.physics.pachinko")
local interfaces          = require('openmw.interfaces')
local shuffle             = require("scripts.ErnPotionMaster.shuffle")
local aux_util            = require('openmw_aux.util')
local renderBoard         = require("scripts.ErnPotionMaster.render.board")
local templates           = require("scripts.ErnPotionMaster.render.templates")
local effectScore         = require("scripts.ErnPotionMaster.effectscore")
local ingredientInfo      = require("scripts.ErnPotionMaster.ingredientinfo")
local potiondonewindow    = require("scripts.ErnPotionMaster.potiondonewindow")
local search              = require("scripts.ErnPotionMaster.search")
local common              = require("scripts.ErnPotionMaster.common")

local playwindow          = require("scripts.ErnPotionMaster.playwindow")
local selectionwindow     = require("scripts.ErnPotionMaster.selectionwindow")

------------------------------------------------------------------------
-- State machine
------------------------------------------------------------------------

---@enum StateClass
local StateClass          = {
    --- Player picks effect, ingredient 1, ingredient 2, and batch size.
    SELECTION_WINDOW       = 1,
    --- The playwindow takes over: pachinko minigame runs.
    PLAY                   = 2,
    --- The shot is over and onPotionBrewed was sent to the global script,
    --- which is the only place that can call world.createRecord()/
    --- world.createObject() to actually make the potion. This state is a
    --- brief holding pattern -- typically resolved within a frame or two --
    --- until that global-script round trip reports back via the
    --- onPotionRecordReady event with the actual record that was created.
    AWAITING_POTION_RECORD = 3,
    --- Allow a quick "do it again" button that re-runs PLAY with the same
    --- ingredients, if they are still available.
    POTION_DONE_WINDOW     = 4,
    STOPPING               = 5,
}

---@type StateClass
local currentState        = StateClass.SELECTION_WINDOW

------------------------------------------------------------------------
-- Per-run data (populated by the selection window, consumed by PLAY)
------------------------------------------------------------------------

---@type BrewData?
local pendingBrewData     = nil

--- Set by onPotionRecordReady once global.lua's onPotionBrewed has actually
--- created (or reused) the potion record and given it to the player. Only
--- meaningful while currentState is AWAITING_POTION_RECORD or
--- POTION_DONE_WINDOW.
---@type table?
local pendingPotionRecord = nil

---@type number
local pendingPotionCount  = 1

------------------------------------------------------------------------
-- Window handles
------------------------------------------------------------------------

---@type SelectionWindow?
local selWindow           = nil

---@type PlayWindow?
local play                = nil

---@type PotionDoneWindow?
local doneWindow          = nil

------------------------------------------------------------------------
-- Re-entrancy guard for startPlay()
------------------------------------------------------------------------

-- startPlay() decrements ingredients and then constructs a PlayWindow.
-- onFrame() calls startPlay() again on every tick where `play` is still
-- nil -- which used to include the tick(s) right after a crash *inside*
-- playwindow.new(), since `play` never got assigned. That caused the same
-- ingredients to be decremented (and the same crash to fire) repeatedly,
-- once per frame, until stock ran out. This flag makes a single attempt
-- atomic from onFrame's point of view: it's set before doing anything
-- destructive and cleared only once we know the outcome (success or a
-- definitive failure), so a re-entrant call during that window is a no-op
-- instead of a repeat of the same work.
local startingPlay        = false

------------------------------------------------------------------------
-- Helpers
------------------------------------------------------------------------

local function onStopAlchemy()
    if currentState == StateClass.STOPPING then
        return
    end
    currentState = StateClass.STOPPING

    settings.debugPrint("stop alchemy")

    if selWindow then
        selWindow:close(); selWindow = nil
    end
    if play then
        play:close(); play = nil
    end
    if doneWindow then
        doneWindow:close(); doneWindow = nil
    end

    pendingBrewData     = nil
    pendingPotionRecord = nil
    pendingPotionCount  = 1
    startingPlay        = false

    settings.debugPrint("removemode: alchemy")
    interfaces.UI.removeMode("Alchemy")
    settings.debugPrint("startmode: alchemy")

    core.sendGlobalEvent(MOD_NAME .. 'onStopAlchemy', {
        player = pself,
    })
end

-- Validate that an ingredient still has enough stock available across the
-- inventories it was originally gathered from.
--
-- This re-counts live, by record id, instead of trusting the `.objects`
-- list captured back in selectionwindow.lua: those object references can
-- go stale (consumed elsewhere, or simply no longer reachable if the
-- player walked away from a nearby container they were borrowing from),
-- so checking their `:isValid()`/`.count` directly could under- or
-- over-report what's actually available right now.
---@param ing ActualizedIngredient
---@param inventories table[]
---@param minimum number
---@return boolean
local function hasEnough(ing, inventories, minimum)
    return common.countAvailable(ing.record.id, inventories) >= minimum
end

--- Consume pendingBrewData to decrement ingredient stacks and spin up
--- a PlayWindow.  Returns false (and calls onStopAlchemy) if ingredients
--- are no longer available, or if the PlayWindow itself fails to
--- construct.
---@return boolean  success
local function startPlay()
    if startingPlay then
        -- Re-entrant call from the same or a subsequent onFrame tick while
        -- a previous attempt is still being resolved. Do nothing instead
        -- of repeating the decrement/construct work.
        settings.debugPrint("startPlay: already in progress; ignoring re-entrant call")
        return false
    end

    if not pendingBrewData then
        settings.debugPrint("startPlay: no pendingBrewData")
        onStopAlchemy()
        return false
    end

    startingPlay    = true

    local brew      = pendingBrewData
    local batchSize = brew.batchSize

    if not hasEnough(brew.ingredient1, brew.inventories, batchSize) or
        not hasEnough(brew.ingredient2, brew.inventories, batchSize) then
        settings.debugPrint("startPlay: not enough ingredients")
        startingPlay = false
        onStopAlchemy()
        return false
    end

    -- Tool strengths were already computed once, from the same nearby
    -- inventories the ingredients came from, by selectionwindow.lua (via
    -- inventorysource.lua) when the brew was confirmed.
    local toolStrengths = brew.toolStrengths

    -- Build local copies of the ingredient info with the count fixed to
    -- batchSize for rendering inside the play window (actual object counts
    -- may have changed by the time the window reads them). Plain shallow
    -- copies -- not proxies -- so anything that iterates these tables with
    -- pairs() (e.g. debug logging) sees the same fields a normal
    -- ActualizedIngredient would have.
    local function withCount(ing, count)
        local copy = {}
        for k, v in pairs(ing) do
            copy[k] = v
        end
        copy.count = count
        return copy
    end
    local ingredient1 = withCount(brew.ingredient1, batchSize)
    local ingredient2 = withCount(brew.ingredient2, batchSize)

    -- Construct the play window BEFORE touching the player's inventory.
    -- playwindow.new can fail (see ingredientinfo.lua's debug-print crash,
    -- if that hasn't been patched yet) -- pcall turns that into a single,
    -- definitive failure instead of a partially-applied state that
    -- onFrame retries next tick.
    local ok, result = pcall(playwindow.new, {
        ingredientInfos = { ingredient1, ingredient2 },
        toolStrengths   = toolStrengths,
        desiredEffect   = brew.primaryEffect,
        doneCallback    = function(data)
            play = nil
            --- actually make the potions
            if data and #data.scores > 0 then
                -- global.lua creates/reuses the record and hands it back
                -- via onPotionRecordReady once it's done -- see that
                -- handler below for why we wait here instead of building
                -- the done window immediately.
                currentState = StateClass.AWAITING_POTION_RECORD
                core.sendGlobalEvent(MOD_NAME .. 'onPotionBrewed', data)
            else
                -- Nothing scored, so nothing was brewed. There's no global
                -- round trip to wait on (no record to create), so go
                -- straight to the done window with a nil record -- it
                -- shows a failure message instead of a potion, but still
                -- offers "again"/"close" like a normal result.
                pendingPotionRecord = nil
                pendingPotionCount  = 0
                currentState        = StateClass.POTION_DONE_WINDOW
            end
        end,
    })

    if not ok then
        settings.debugPrint("startPlay: playwindow.new failed: " .. tostring(result))
        startingPlay = false
        onStopAlchemy()
        return false
    end

    -- Construction succeeded -- now it's safe to actually remove the
    -- ingredients from wherever they currently are. Gather fresh object
    -- lists right before decrementing rather than reusing the `.objects`
    -- snapshot captured back in selectionwindow.lua: on a "do it again"
    -- replay especially, some of those specific stacks may have already
    -- been fully consumed (or moved) even though hasEnough() above
    -- confirmed enough total stock still exists somewhere in
    -- brew.inventories.
    core.sendGlobalEvent(MOD_NAME .. 'onDecrementItems', {
        items  = common.getObjectsOf(brew.ingredient1.record.id, brew.inventories),
        amount = batchSize,
    })
    core.sendGlobalEvent(MOD_NAME .. 'onDecrementItems', {
        items  = common.getObjectsOf(brew.ingredient2.record.id, brew.inventories),
        amount = batchSize,
    })
    brew.ingredient1.count = batchSize
    brew.ingredient2.count = batchSize

    play                   = result
    startingPlay           = false
    return true
end

------------------------------------------------------------------------
-- Events from global.lua
------------------------------------------------------------------------

--- Sent by global.lua's onPotionBrewed once it has created/reused the
--- potion record and placed the batch into the player's inventory.
---@param data { recordID: string, count: number }
local function onPotionRecordReady(data)
    if currentState ~= StateClass.AWAITING_POTION_RECORD then
        -- Stale event -- e.g. the player backed out of alchemy (or started
        -- a new "do it again" round) while the global round trip was still
        -- in flight. Ignore it rather than clobbering whatever is current.
        settings.debugPrint("onPotionRecordReady: ignoring stale event")
        return
    end

    pendingPotionRecord = types.Potion.record(data.recordID)
    pendingPotionCount  = data.count
    currentState        = StateClass.POTION_DONE_WINDOW
end

------------------------------------------------------------------------
-- onInit / onFrame
------------------------------------------------------------------------

local function onInit(data)
    currentState = StateClass.SELECTION_WINDOW
    settings.debugPrint("start alchemy")
    -- State is already SELECTION_WINDOW; selWindow will be created on the
    -- first onFrame tick so the UI system is fully ready.
end

local function onFrame()
    if currentState == StateClass.STOPPING then
        return
    end

    ---------- SELECTION_WINDOW ----------------------------------------
    if currentState == StateClass.SELECTION_WINDOW then
        if not selWindow then
            selWindow = selectionwindow.new(
            -- cancelCallback: player hit cancel / B on first pane.
                function()
                    settings.debugPrint("selection cancelled")
                    onStopAlchemy()
                end,
                -- brewCallback: player confirmed all four selections.
                ---@param data BrewData
                function(data)
                    settings.debugPrint("selection confirmed, batchSize=" .. tostring(data.batchSize))
                    pendingBrewData = data

                    -- Close the selection window before opening the play window.
                    if selWindow then
                        selWindow:close()
                        selWindow = nil
                    end

                    currentState = StateClass.PLAY
                end
            )
        end
        selWindow:onFrame()

        ---------- PLAY ----------------------------------------------------
    elseif currentState == StateClass.PLAY then
        if not play then
            if not startPlay() then
                return
            end
        end
        play:onFrame()

        ---------- AWAITING_POTION_RECORD -----------------------------------
    elseif currentState == StateClass.AWAITING_POTION_RECORD then
        -- Waiting on the global script's onPotionRecordReady event (sent
        -- from onPotionBrewed) to report back with the record it just
        -- created/reused. Nothing to render in the meantime; onFrame will
        -- just retick until onPotionRecordReady advances currentState.
        return

        ---------- POTION_DONE_WINDOW --------------------------------------
    elseif currentState == StateClass.POTION_DONE_WINDOW then
        if not doneWindow then
            local canMakeAnotherBatch = false
            if pendingBrewData then
                canMakeAnotherBatch = hasEnough(pendingBrewData.ingredient1, pendingBrewData.inventories,
                        pendingBrewData.batchSize) and
                    hasEnough(pendingBrewData.ingredient2, pendingBrewData.inventories, pendingBrewData.batchSize)
            end
            doneWindow = potiondonewindow.new(
                pendingPotionRecord,
                pendingPotionCount,
                -- "Close alchemy" button.
                function(data)
                    settings.debugPrint("close alchemy window button pressed")
                    onStopAlchemy()
                end,
                -- "Do it again" button: only works if we still have pendingBrewData.
                canMakeAnotherBatch and function(data)
                    settings.debugPrint("do alchemy again")
                    currentState = StateClass.PLAY
                    if doneWindow then
                        doneWindow:close()
                        doneWindow = nil
                    end
                    -- pendingBrewData is intentionally kept so startPlay() can
                    -- use it again (it will re-validate stock before decrementing).
                end or nil
            )
        end
        doneWindow:onFrame()
    end
end

------------------------------------------------------------------------
-- Module export
------------------------------------------------------------------------

return {
    engineHandlers = {
        onInit  = onInit,
        onFrame = onFrame,
    },
    eventHandlers = {
        [MOD_NAME .. "onStopAlchemy"] = onStopAlchemy,
        [MOD_NAME .. "onPotionRecordReady"] = onPotionRecordReady,
    }
}
