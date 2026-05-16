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

local MOD_NAME         = require("scripts.ErnPotionMaster.ns")
local const            = require("scripts.ErnPotionMaster.const")
local ui               = require("openmw.ui")
local util             = require("openmw.util")
local pself            = require("openmw.self")
local core             = require("openmw.core")
local types            = require("openmw.types")
local placepins        = require("scripts.ErnPotionMaster.placepins")
local settings         = require("scripts.ErnPotionMaster.settings.settings")
local physics          = require("scripts.ErnPotionMaster.physics.pachinko")
local interfaces       = require('openmw.interfaces')
local shuffle          = require("scripts.ErnPotionMaster.shuffle")
local aux_util         = require('openmw_aux.util')
local renderBoard      = require("scripts.ErnPotionMaster.render.board")
local templates        = require("scripts.ErnPotionMaster.render.templates")
local effectScore      = require("scripts.ErnPotionMaster.effectscore")
local ingredientInfo   = require("scripts.ErnPotionMaster.ingredientinfo")
local potiondonewindow = require("scripts.ErnPotionMaster.potiondonewindow")
local search           = require("scripts.ErnPotionMaster.search")
local common           = require("scripts.ErnPotionMaster.common")

local playwindow       = require("scripts.ErnPotionMaster.playwindow")
local selectionwindow  = require("scripts.ErnPotionMaster.selectionwindow")

------------------------------------------------------------------------
-- State machine
------------------------------------------------------------------------

---@enum StateClass
local StateClass       = {
    --- Player picks effect, ingredient 1, ingredient 2, and batch size.
    SELECTION_WINDOW   = 1,
    --- The playwindow takes over: pachinko minigame runs.
    PLAY               = 2,
    --- Allow a quick "do it again" button that re-runs PLAY with the same
    --- ingredients, if they are still available.
    POTION_DONE_WINDOW = 3,
}

---@type StateClass
local currentState     = StateClass.SELECTION_WINDOW

------------------------------------------------------------------------
-- Per-run data (populated by the selection window, consumed by PLAY)
------------------------------------------------------------------------

---@type BrewData?
local pendingBrewData  = nil

------------------------------------------------------------------------
-- Window handles
------------------------------------------------------------------------

---@type SelectionWindow?
local selWindow        = nil

---@type PlayWindow?
local play             = nil

---@type PotionDoneWindow?
local doneWindow       = nil

------------------------------------------------------------------------
-- Helpers
------------------------------------------------------------------------

local function onStopAlchemy()
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

    pendingBrewData = nil

    settings.debugPrint("removemode: alchemy")
    interfaces.UI.removeMode("Alchemy")
    settings.debugPrint("startmode: alchemy")

    core.sendGlobalEvent(MOD_NAME .. 'onStopAlchemy', {
        player = pself,
    })
end

--- Consume pendingBrewData to decrement ingredient stacks and spin up
--- a PlayWindow.  Returns false (and calls onStopAlchemy) if ingredients
--- are no longer available.
---@return boolean  success
local function startPlay()
    if not pendingBrewData then
        settings.debugPrint("startPlay: no pendingBrewData")
        onStopAlchemy()
        return false
    end

    local brew      = pendingBrewData
    local batchSize = brew.batchSize

    -- Validate that both ingredients still have enough stock.
    local function hasEnough(ing)
        local total = 0
        for _, obj in ipairs(ing.objects) do
            if obj:isValid() then total = total + obj.count end
        end
        return total >= batchSize
    end

    if not hasEnough(brew.ingredient1) or not hasEnough(brew.ingredient2) then
        settings.debugPrint("startPlay: not enough ingredients")
        onStopAlchemy()
        return false
    end

    -- Decrement both ingredient stacks.
    core.sendGlobalEvent(MOD_NAME .. 'onDecrementItems', {
        items  = brew.ingredient1.objects,
        amount = batchSize,
    })
    core.sendGlobalEvent(MOD_NAME .. 'onDecrementItems', {
        items  = brew.ingredient2.objects,
        amount = batchSize,
    })

    -- Fix the counts for rendering inside the play window
    -- (actual object counts may have changed by the time the window reads them).
    brew.ingredient1.count = batchSize
    brew.ingredient2.count = batchSize

    -- TODO: read actual tool strengths from player inventory.
    local toolStrengths = {
        [const.ToolClass.CALCINATOR] = 1,
        [const.ToolClass.ALEMBIC]    = 1,
        [const.ToolClass.MORTAR]     = 1,
        [const.ToolClass.RETORT]     = 1,
    }

    play = playwindow.new({
        ingredientInfos = { brew.ingredient1, brew.ingredient2 },
        toolStrengths   = toolStrengths,
        desiredEffect   = brew.primaryEffect,
        doneCallback    = function(data)
            currentState = StateClass.POTION_DONE_WINDOW
            play         = nil
        end,
    })

    return true
end

------------------------------------------------------------------------
-- onInit / onFrame
------------------------------------------------------------------------

local function onInit(data)
    settings.debugPrint("start alchemy")
    -- State is already SELECTION_WINDOW; selWindow will be created on the
    -- first onFrame tick so the UI system is fully ready.
end

local function onFrame()
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
                -- startPlay already called onStopAlchemy on failure.
                return
            end
        end
        play:onFrame()

        ---------- POTION_DONE_WINDOW --------------------------------------
    elseif currentState == StateClass.POTION_DONE_WINDOW then
        if not doneWindow then
            -- TODO: replace the hardcoded skooma record with the actual
            --       potion produced by the play window.
            doneWindow = potiondonewindow.new(
                types.Potion.records["potion_skooma_01"],
                pendingBrewData and pendingBrewData.batchSize or 1,
                -- "Close alchemy" button.
                function(data)
                    settings.debugPrint("close alchemy window button pressed")
                    onStopAlchemy()
                end,
                -- "Do it again" button: only works if we still have pendingBrewData.
                function(data)
                    settings.debugPrint("do alchemy again")
                    currentState = StateClass.PLAY
                    if doneWindow then
                        doneWindow:close()
                        doneWindow = nil
                    end
                    -- pendingBrewData is intentionally kept so startPlay() can
                    -- use it again (it will re-validate stock before decrementing).
                end
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
    }
}
