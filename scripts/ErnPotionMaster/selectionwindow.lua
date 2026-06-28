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

-- selectionwindow.lua
-- Presents a four-column selection UI:
--   [Effect list] | [Ingredient 1 list] | [Ingredient 2 list] | [Batch size + Cancel/Brew]
--
-- Navigation is left-to-right via controller or keyboard:
--   Up/Down (stick or arrow keys) – scroll current pane
--   Right / A                    – confirm selection and advance to next pane
--   Left  / B (hold exit)        – go back one pane (clears dependent selections)
--   B (on first pane)            – cancel / close
--   Enter / A (on last pane)     – brew!
--
-- State machine: PRIMARY_EFFECT_SELECTION → INGREDIENT_1_SELECTION
--                → INGREDIENT_2_SELECTION → BATCH_AMOUNT_SELECTION
--
-- ARCHITECTURE NOTE (cascade rebuilds):
-- Each column has exactly one "selection setter" (_setPrimaryEffect,
-- _setIngredient1, _setIngredient2) that is the ONLY thing allowed to
-- change that column's selection. Every input path -- mouse click,
-- keyboard/controller confirm, and Up/Down scrolling -- funnels through
-- these setters instead of poking the VirtualListExt or the index fields
-- directly. Each setter is solely responsible for rebuilding everything
-- downstream of its own column (and only its own column), so there is
-- exactly one place that does that work, instead of it being split
-- between click handlers and the forward/backward state-transition table
-- (which previously caused double rebuilds on mouse clicks and NO rebuild
-- at all when navigating with the keyboard/controller, since scrolling
-- used to bypass the setters and write directly into the list widget).
--
-- behavior being preserved:
-- 1. selected an effect like Water Walking. This populates the 1st ingredient column.
-- 2. select a different effect like Resist Poison. This clears and re-calculates the 1st ingredient column.
-- 3. selected a 1st ingredient like Scales. This populates the 2nd ingredient column, but Scales is
--    missing from it because it is currently selected. so only Sload Soap is listed.
-- 4. go back and select Sload Soap for the 1st ingredient. This re-calculates the 2nd ingredient
--    column so only Scales is present now.
-- 5. go back and select a totally different primary effect. This clears out the 2nd ingredient
--    column and replaces the 1st ingredient column with the next batch of ingredients for that effect.

-- NOTE ON THE "batch of 3" crash (out of scope for this file):
-- The log you shared shows startPlay() in alchemy.lua re-decrementing the same batch and
-- re-constructing PlayWindow three times in a row. That isn't caused by selectionwindow.lua --
-- by the time _doBrew() fires here, the correct single BrewData table (one effect, two distinct
-- ingredients, one batch size) has already been handed off exactly once. The actual crash is
-- "attempt to perform arithmetic on local 'index' (a nil value)" inside aux_util.deepToString,
-- called from IngredientInfoContainer.new (ingredientinfo.lua:209) by way of
-- playwindow.lua:600's _init. Because that throw happens *after* alchemy.lua's startPlay() has
-- already sent onDecrementItems for both ingredients, and startPlay() has no guard against being
-- re-entered after a failed/partial attempt, onFrame() just calls startPlay() again next tick
-- (since `play` was never assigned), decrementing and crashing again -- three times, until the
-- stock runs out. Two independent fixes are needed outside this file:
--   1. ingredientinfo.lua / playwindow.lua: stop deep-printing the live UI layout table (it
--      contains userdata the aux util's generic table walker can't index), or guard the print.
--   2. alchemy.lua: make startPlay() idempotent/guarded (e.g. flip a flag, or only decrement
--      ingredients once playwindow.new() has succeeded) so a downstream crash can't cause
--      the same brew to be re-applied on the next frame.
-- Happy to patch those two files as well if you'd like -- just say so.

local MOD_NAME                  = require("scripts.ErnPotionMaster.ns")
local const                     = require("scripts.ErnPotionMaster.const")
local ui                        = require("openmw.ui")
local util                      = require("openmw.util")
local core                      = require("openmw.core")
local interfaces                = require('openmw.interfaces')
local settings                  = require("scripts.ErnPotionMaster.settings.settings")
local common                    = require("scripts.ErnPotionMaster.common")
local inventorysource           = require("scripts.ErnPotionMaster.inventorysource")
local templates                 = require("scripts.ErnPotionMaster.render.templates")
local myui                      = require("scripts.ErnPotionMaster.pcp.myui")
local keytrack                  = require("scripts.ErnPotionMaster.keytrack")
local virtualListExtras         = require("scripts.ErnPotionMaster.virtual_list.extras")
local input                     = require("openmw.input")
local async                     = require("openmw.async")
local ambient                   = require("openmw.ambient")
local localization              = core.l10n(MOD_NAME)

------------------------------------------------------------------------
-- Constants
------------------------------------------------------------------------

-- How many batch sizes to offer (1 .. MAX_BATCH).  The actual maximum
-- shown is clamped to min(ingredient1.count, ingredient2.count).
local MAX_BATCH                 = 10

------------------------------------------------------------------------
-- State machine
------------------------------------------------------------------------

---@enum SelectionStateClass
local SelectionStateClass       = {
    PRIMARY_EFFECT_SELECTION = 1,
    INGREDIENT_1_SELECTION   = 2,
    INGREDIENT_2_SELECTION   = 3,
    --- let people do 5x at a time. they end up with 5 identical potions (or failures)
    BATCH_AMOUNT_SELECTION   = 4,
}

-- Transitions only move `state` forward/back and clear out state that
-- belongs to panes being abandoned. They deliberately do NOT rebuild any
-- lists -- that's the job of the per-column selection setters
-- (_setPrimaryEffect / _setIngredient1 / _setIngredient2), which run
-- whenever a selection is made (by mouse, keyboard, or controller) and
-- are the single source of truth for "what changed, so what must rebuild".
-- By the time `forward` runs, the current pane's setter has already
-- built everything downstream; by the time `backward` runs, we just
-- need to clear the panes we're leaving so they don't show stale data.

---@class SelectionStateMethods
---@field forward  fun(window: SelectionWindow)
---@field backward fun(window: SelectionWindow)

---@type {[SelectionStateClass]: SelectionStateMethods}
local SelectionStateTransitions = {
    PRIMARY_EFFECT_SELECTION = {
        forward = function(window)
            settings.debugPrint("advance to INGREDIENT_1_SELECTION")
            window.state = SelectionStateClass.INGREDIENT_1_SELECTION
        end,
        backward = function(window)
            error("should not be hit")
        end
    },
    INGREDIENT_1_SELECTION = {
        forward = function(window)
            settings.debugPrint("advance to INGREDIENT_2_SELECTION")
            window.state = SelectionStateClass.INGREDIENT_2_SELECTION
        end,
        backward = function(window)
            -- Leaving ingredient-1 entirely: clear ingredient 1, ingredient 2, and batch.
            window:_clearIngredient1(true)
            window.state = SelectionStateClass.PRIMARY_EFFECT_SELECTION
        end
    },
    INGREDIENT_2_SELECTION = {
        forward = function(window)
            settings.debugPrint("advance to BATCH_AMOUNT_SELECTION")
            window:_rebuildBatchList()
            window.state = SelectionStateClass.BATCH_AMOUNT_SELECTION
        end,
        backward = function(window)
            -- Leaving ingredient-2: clear ingredient 2 and batch.
            window:_clearIngredient2(true)
            window.state = SelectionStateClass.INGREDIENT_1_SELECTION
        end
    },
    BATCH_AMOUNT_SELECTION = {
        forward = function(window)
            error("should not be hit")
        end,
        backward = function(window)
            window._batchIndex = 1
            window.batchSize   = 1
            window.state       = SelectionStateClass.INGREDIENT_2_SELECTION
        end
    }
}

------------------------------------------------------------------------
-- SelectionWindow class
------------------------------------------------------------------------

---@class SelectionWindow
---@field window                  table                  openmw ui element
---@field _cancelCallback         fun()                  close the alchemy window
---@field _brewCallback           fun(data: BrewData)    start up another shot with current ingredients
---@field _cancelButtonElement    any
---@field _brewButtonElement      any
---@field scrollListEffects       VirtualListExt
---@field scrollListIngredient1   VirtualListExt
---@field scrollListIngredient2   VirtualListExt
---@field inventories             table[] every inventory ingredients/apparatuses are gathered from (player + nearby unowned containers)
---@field toolStrengths           {[ToolClass]: number} best available quality of each apparatus type, across `inventories`
---@field availableIngredients    ActualizedIngredient[] ALL ingredients, unfiltered
---@field primaryEffects          MagicEffectWithParams[] effects shared by ≥2 different ingredients
---@field filteredIngredients     ActualizedIngredient[] ingredients that carry the chosen primary effect
---@field effectIndex             number?  index into primaryEffects
---@field ingredient1Index        number?  index into filteredIngredients
---@field ingredient2Index        number?  index into filteredIngredients (≠ ingredient1Index)
---@field batchSize               number   current batch size value
---@field _batchOptions           number[] list of valid batch sizes (e.g. {1,2,3,4,5})
---@field _batchIndex             number   1-based index into _batchOptions
---@field _brewed                 boolean  true once _doBrew has fired for the current selection
---@field _keys                   table
---@field state                   SelectionStateClass

---@class BrewData
---@field primaryEffect   MagicEffectWithParams
---@field ingredient1     ActualizedIngredient
---@field ingredient2     ActualizedIngredient
---@field batchSize       number
---@field inventories     table[] every inventory these ingredients were drawn from, so availability can be re-checked later (e.g. potiondonewindow.lua's "do it again")
---@field toolStrengths   {[ToolClass]: number} best available quality of each apparatus type at the time of brewing

local SelectionWindow           = {}
SelectionWindow.__index         = SelectionWindow

------------------------------------------------------------------------
-- Key bindings
------------------------------------------------------------------------

local function newKeys()
    return {
        up    = keytrack.NewKey("up", function(dt)
            return input.isKeyPressed(input.KEY.UpArrow) or
                (input.getAxisValue(input.CONTROLLER_AXIS.RightY) < -1 * const.StickDeadzone)
        end),
        down  = keytrack.NewKey("down", function(dt)
            return input.isKeyPressed(input.KEY.DownArrow) or
                (input.getAxisValue(input.CONTROLLER_AXIS.RightY) > const.StickDeadzone)
        end),
        left  = keytrack.NewKey("left", function(dt)
            return input.isKeyPressed(input.KEY.LeftArrow) or
                (input.getAxisValue(input.CONTROLLER_AXIS.RightX) < -1 * const.StickDeadzone)
        end),
        right = keytrack.NewKey("right", function(dt)
            return input.isKeyPressed(input.KEY.RightArrow) or
                (input.getAxisValue(input.CONTROLLER_AXIS.RightX) > const.StickDeadzone)
        end),
        exit  = keytrack.NewKey("back", function(dt)
            -- B button: go back a pane, or cancel on the first pane.
            return input.isControllerButtonPressed(input.CONTROLLER_BUTTON.B)
        end),
        enter = keytrack.NewKey("enter", function(dt)
            -- A / Enter: confirm selection / advance pane, brew on last pane.
            return input.isKeyPressed(input.KEY.Enter) or
                input.isControllerButtonPressed(input.CONTROLLER_BUTTON.A)
        end),
    }
end

------------------------------------------------------------------------
-- Internal helpers
------------------------------------------------------------------------

--- Returns the VirtualListExt that is "active" for the current state,
--- or nil for the batch pane (which uses a select-style widget, not a list).
---@param self SelectionWindow
---@return VirtualListExt?
local function activeList(self)
    if self.state == SelectionStateClass.PRIMARY_EFFECT_SELECTION then
        return self.scrollListEffects
    elseif self.state == SelectionStateClass.INGREDIENT_1_SELECTION then
        return self.scrollListIngredient1
    elseif self.state == SelectionStateClass.INGREDIENT_2_SELECTION then
        return self.scrollListIngredient2
    else
        -- BATCH_AMOUNT_SELECTION uses a select widget, not a scroll list.
        return nil
    end
end

--- Routes a newly-highlighted index in the active pane through the
--- column's single selection setter, so keyboard/controller scrolling
--- rebuilds downstream columns exactly the same way a mouse click does.
---@param self SelectionWindow
---@param index number
local function setActiveSelection(self, index)
    if self.state == SelectionStateClass.PRIMARY_EFFECT_SELECTION then
        self:_setPrimaryEffect(index)
    elseif self.state == SelectionStateClass.INGREDIENT_1_SELECTION then
        self:_setIngredient1(index)
    elseif self.state == SelectionStateClass.INGREDIENT_2_SELECTION then
        self:_setIngredient2(index)
    end
end

--- Scroll the active list one step up or down.
--- No-ops on the batch pane (which uses left/right, not up/down).
---@param self SelectionWindow
---@param direction number  -1 for up, +1 for down
local function scrollActiveList(self, direction)
    local list = activeList(self)
    if not list then return end

    local scrollData = list:getElement().layout.userData.scrollData

    local current    = list:getSelectedIndex()
    local first      = scrollData:getFirstIndex()
    local last       = scrollData:getLastIndex()

    -- On the ingredient-2 pane, the row matching ingredient1Index is a
    -- disabled placeholder (see buildIngredient2List) and must never become
    -- the selection: if the cursor landed on it, it could never move again
    -- (it can't be confirmed via _setIngredient2, so the next press would
    -- recompute the exact same blocked index forever).
    local function isBlocked(index)
        return self.state == SelectionStateClass.INGREDIENT_2_SELECTION
            and index == self.ingredient1Index
    end

    local newIndex
    if current == nil then
        newIndex = (direction > 0) and first or last
    else
        newIndex = current + direction
        if newIndex < first then newIndex = first end
        if newIndex > last then newIndex = last end
    end

    -- Step past the blocked row in the direction of travel; if that runs
    -- off the end of the list, step back the other way instead (covers the
    -- edge case where the blocked row is the first/last visible item).
    if isBlocked(newIndex) then
        local skipped = newIndex + direction
        if skipped < first or skipped > last then
            skipped = newIndex - direction
        end
        newIndex = skipped
    end

    -- Nowhere valid to land (e.g. only one ingredient shares the effect,
    -- and it's already ingredient1) -- leave the selection unchanged.
    if newIndex < first or newIndex > last or isBlocked(newIndex) then
        return
    end

    if newIndex ~= current then
        ambient.playSound("menu click")
        -- Route through the column's setter (not list:changeSelection directly)
        -- so downstream columns rebuild immediately as the player scrolls,
        -- not only once they press Right/A to confirm.
        setActiveSelection(self, newIndex)
        if direction < 0 then
            scrollData:scrollToIndex(newIndex, "top")
        else
            scrollData:scrollToIndex(newIndex, "bottom")
        end
    end
end

--- Whether the current state has a valid selection committed.
---@param self SelectionWindow
---@return boolean
local function currentPaneHasSelection(self)
    if self.state == SelectionStateClass.PRIMARY_EFFECT_SELECTION then
        return self.effectIndex ~= nil
    elseif self.state == SelectionStateClass.INGREDIENT_1_SELECTION then
        return self.ingredient1Index ~= nil
    elseif self.state == SelectionStateClass.INGREDIENT_2_SELECTION then
        return self.ingredient2Index ~= nil
    else -- BATCH_AMOUNT_SELECTION
        -- The select widget always has a valid value once _rebuildBatchList ran.
        return #self._batchOptions > 0
    end
end

------------------------------------------------------------------------
-- List (re)builders
--
-- Each builder constructs ONE column's VirtualListExt. They never decide
-- *when* to rebuild anything but their own column -- that decision lives
-- in the selection setters below. A builder may be called more than once
-- per column's lifetime (every time an upstream column's selection
-- changes), which is why each one is idempotent and self-contained.
------------------------------------------------------------------------

--- Create the scrollListEffects list.  Called once during construction.
---@param self SelectionWindow
local function buildEffectList(self)
    self.scrollListEffects = virtualListExtras.VirtualListExt.create({
        viewportSize = const.ScrollListPaneSize,
        itemSize     = const.ScrollListItemSize,
        itemCount    = #self.primaryEffects,
        itemLayout   = function(i, list)
            return list:createItemLayout({
                index = i,
                props = { text = templates.effectToString(self.primaryEffects[i]) },
                onMousePress = function(e, layout)
                    if e.button == 1 then
                        -- Mouse click: select and immediately advance.
                        self:_setPrimaryEffect(i)
                        if self.state == SelectionStateClass.PRIMARY_EFFECT_SELECTION then
                            SelectionStateTransitions.PRIMARY_EFFECT_SELECTION.forward(self)
                        end
                    end
                end,
            })
        end,
    })
    self.scrollListEffects:setKeyPressHandler({
        setSelectedIndex = function(i)
            self:_setPrimaryEffect(i)
        end,
    })
end

--- (Re)build the ingredient-1 list filtered by the currently selected effect.
--- Called only from _setPrimaryEffect.
---@param self SelectionWindow
local function buildIngredient1List(self)
    self.scrollListIngredient1 = virtualListExtras.VirtualListExt.create({
        viewportSize = const.ScrollListPaneSize,
        itemSize     = const.ScrollListItemSize,
        itemCount    = #self.filteredIngredients,
        itemLayout   = function(i, list)
            local ing = self.filteredIngredients[i]
            return list:createItemLayout({
                index = i,
                props = { text = ing.record.name .. " (x" .. tostring(ing.count) .. ")" },
                onMousePress = function(e, layout)
                    if e.button == 1 then
                        self:_setIngredient1(i)
                        if self.state == SelectionStateClass.INGREDIENT_1_SELECTION then
                            SelectionStateTransitions.INGREDIENT_1_SELECTION.forward(self)
                        end
                    end
                end,
            })
        end,
    })
    self.scrollListIngredient1:setKeyPressHandler({
        setSelectedIndex = function(i)
            self:_setIngredient1(i)
        end,
    })
end

--- (Re)build the ingredient-2 list, excluding the ingredient-1 choice.
--- Called only from _setIngredient1 (and from the PRIMARY_EFFECT_SELECTION
--- rebuild path, where it produces an empty list since ingredient1Index is nil).
---@param self SelectionWindow
local function buildIngredient2List(self)
    self.scrollListIngredient2 = virtualListExtras.VirtualListExt.create({
        viewportSize = const.ScrollListPaneSize,
        itemSize     = const.ScrollListItemSize,
        itemCount    = #self.filteredIngredients,
        itemLayout   = function(i, list)
            local ing = self.filteredIngredients[i]
            -- Grey out the item that is already chosen as ingredient 1.
            local label = ing.record.name .. " (x" .. tostring(ing.count) .. ")"
            if i == self.ingredient1Index then
                -- Still render it but make it unselectable (show marker).
                label = "-- " .. label
                return list:createPlaceholder({ text = label })
            end
            return list:createItemLayout({
                index = i,
                props = { text = label },
                onMousePress = function(e, layout)
                    if e.button == 1 and i ~= self.ingredient1Index then
                        self:_setIngredient2(i)
                        if self.state == SelectionStateClass.INGREDIENT_2_SELECTION then
                            SelectionStateTransitions.INGREDIENT_2_SELECTION.forward(self)
                        end
                    end
                end,
            })
        end,
    })
    self.scrollListIngredient2:setKeyPressHandler({
        setSelectedIndex = function(i)
            -- Skip the ingredient-1 slot.
            if i == self.ingredient1Index then return end
            self:_setIngredient2(i)
        end,
    })
end

------------------------------------------------------------------------
-- Selection setters
--
-- These are the ONLY functions allowed to change effectIndex /
-- ingredient1Index / ingredient2Index, and the ONLY functions allowed to
-- rebuild a column's list. Every input path (mouse, keyboard/controller
-- confirm, Up/Down scroll) calls into one of these instead of touching
-- the VirtualListExt or the index fields directly.
------------------------------------------------------------------------

--- Clears ingredient 1, ingredient 2, and the batch -- used both when the
--- primary effect changes and when navigating back out of ingredient 1.
---@param self SelectionWindow
---@param rebuildList boolean  also rebuild scrollListIngredient2 (false during
---                            full effect-change rebuilds, where the caller
---                            rebuilds ingredient2 itself right after)
function SelectionWindow:_clearIngredient1(rebuildList)
    self.ingredient1Index = nil
    self:_clearIngredient2(false)
    if self.scrollListIngredient1 then
        self.scrollListIngredient1:changeSelection(nil)
    end
    if rebuildList then
        buildIngredient2List(self)
    end
end

--- Clears ingredient 2 and the batch -- used both when ingredient 1
--- changes and when navigating back out of ingredient 2.
---@param self SelectionWindow
---@param rebuildList boolean  also rebuild scrollListIngredient2 to drop the
---                            stale onMousePress closures (false when the
---                            caller is about to rebuild it anyway).
function SelectionWindow:_clearIngredient2(rebuildList)
    self.ingredient2Index = nil
    self.batchSize        = 1
    self._batchIndex      = 1
    self._batchOptions    = {}
    self._brewed          = false
    if self.scrollListIngredient2 then
        self.scrollListIngredient2:changeSelection(nil)
    end
    if rebuildList then
        buildIngredient2List(self)
    end
end

---@param self SelectionWindow
---@param effectIndex number
function SelectionWindow:_setPrimaryEffect(effectIndex)
    if self.effectIndex == effectIndex then
        return
    end

    self.effectIndex = effectIndex
    self.scrollListEffects:changeSelection(effectIndex)

    -- Recompute which ingredients carry this effect.
    local chosenEffect = self.primaryEffects[effectIndex]
    self.filteredIngredients = {}
    for _, ing in ipairs(self.availableIngredients) do
        for _, mewp in ipairs(ing.record.effects) do
            if common.magicEffectsEqual(mewp, chosenEffect) then
                table.insert(self.filteredIngredients, ing)
                break
            end
        end
    end

    -- Everything downstream of the effect column is now stale: clear
    -- ingredient 1 (which also clears ingredient 2 and the batch), then
    -- rebuild both ingredient lists against the new filteredIngredients.
    self.ingredient1Index = nil
    self:_clearIngredient2(false)
    buildIngredient1List(self)
    buildIngredient2List(self)
end

---@param self SelectionWindow
---@param ingredientIndex number
function SelectionWindow:_setIngredient1(ingredientIndex)
    if ingredientIndex == self.ingredient1Index then
        return
    end

    self.ingredient1Index = ingredientIndex
    self.scrollListIngredient1:changeSelection(ingredientIndex)

    -- Ingredient 2 depends on ingredient 1 (it must exclude this index,
    -- and any prior ingredient-2 choice may now be invalid/stale).
    self:_clearIngredient2(false)
    buildIngredient2List(self)
end

---@param self SelectionWindow
---@param ingredientIndex number
function SelectionWindow:_setIngredient2(ingredientIndex)
    if ingredientIndex == self.ingredient1Index then
        -- Defensive: never allow ingredient 2 to match ingredient 1.
        return
    end
    if ingredientIndex == self.ingredient2Index then
        return
    end

    self.ingredient2Index = ingredientIndex
    self.scrollListIngredient2:changeSelection(ingredientIndex)

    -- Batch size depends on both ingredient counts; reset it so a stale
    -- value can't leak in from a previous ingredient-2 choice. The actual
    -- options list is (re)computed by _rebuildBatchList when advancing
    -- into BATCH_AMOUNT_SELECTION.
    self.batchSize     = 1
    self._batchIndex   = 1
    self._batchOptions = {}
    self._brewed       = false
end

--- (Re)build the batch-size options.
--- Called when advancing from INGREDIENT_2_SELECTION.
--- No VirtualListExt -- the batch pane uses a select-style widget instead.
function SelectionWindow:_rebuildBatchList()
    -- Determine the maximum number of batches we can brew.
    local maxCount = MAX_BATCH
    if self.ingredient1Index and self.filteredIngredients[self.ingredient1Index] then
        maxCount = math.min(maxCount, self.filteredIngredients[self.ingredient1Index].count)
    end
    if self.ingredient2Index and self.filteredIngredients[self.ingredient2Index] then
        maxCount = math.min(maxCount, self.filteredIngredients[self.ingredient2Index].count)
    end
    maxCount = math.max(1, maxCount)

    self._batchOptions = {}
    for n = 1, maxCount do
        table.insert(self._batchOptions, n)
    end

    -- Default to x1.
    self._batchIndex = 1
    self.batchSize   = self._batchOptions[1]
    self._brewed     = false
end

------------------------------------------------------------------------
-- Button helpers
------------------------------------------------------------------------

function SelectionWindow:_updateBrewButtonElement()
    -- Brew is only actionable on the last pane once options have been built.
    local isReady = (self.state == SelectionStateClass.BATCH_AMOUNT_SELECTION) and
        (#self._batchOptions > 0) and not self._brewed

    local brewFn = function()
        settings.debugPrint("brew clicked")
        if isReady then
            self:_doBrew()
        else
            ambient.playSound("menu click")
        end
    end

    self._brewButtonElement.layout = myui.createTextButton(
        self._brewButtonElement,
        localization("brewButton", {}),
        isReady and "normal" or "disabled",
        "saveButton",
        {},
        const.ButtonSize,
        brewFn)
    self._brewButtonElement:update()
end

function SelectionWindow:_updateCancelButtonElement()
    local cancelFn = function()
        settings.debugPrint("done clicked")
        self._cancelCallback()
    end
    self._cancelButtonElement.layout = myui.createTextButton(
        self._cancelButtonElement,
        localization("cancelButton", {}),
        "normal",
        "saveButton",
        {},
        const.ButtonSize,
        cancelFn)
    self._cancelButtonElement:update()
end

--- Gather the BrewData and call the brew callback.
--- Guarded by _brewed so a double-fire (e.g. a stray extra Enter/click
--- landing before the window closes) can't hand off the same selection
--- to alchemy.lua twice.
function SelectionWindow:_doBrew()
    if self._brewed then
        settings.debugPrint("_doBrew called again; ignoring (already brewed this selection)")
        return
    end
    if not self.ingredient1Index or not self.ingredient2Index then
        settings.debugPrint("_doBrew called but ingredients not selected")
        return
    end
    if not self.effectIndex then
        settings.debugPrint("_doBrew called but effect not selected")
        return
    end

    self._brewed = true

    ---@type BrewData
    local data = {
        primaryEffect = self.primaryEffects[self.effectIndex],
        ingredient1   = self.filteredIngredients[self.ingredient1Index],
        ingredient2   = self.filteredIngredients[self.ingredient2Index],
        batchSize     = self.batchSize,
        inventories   = self.inventories,
        toolStrengths = self.toolStrengths,
    }
    settings.debugPrint("brewCallback with batchSize=" .. tostring(data.batchSize))
    self._brewCallback(data)
end

------------------------------------------------------------------------
-- Layout
------------------------------------------------------------------------

--- Returns a column header text widget.
---@param label string
---@return Layout
local function columnHeader(label)
    return {
        type     = ui.TYPE.Text,
        props    = {
            text      = label,
            textSize  = 14,
            textColor = myui.textColors.header,
        },
        external = { stretch = 1 },
    }
end

--- Wraps a list element with a visible header label and an active-pane highlight.
---@param self SelectionWindow
---@param label string
---@param listExt VirtualListExt
---@param paneState SelectionStateClass
---@return Layout
local function columnLayout(self, label, listExt, paneState)
    local isActive = (self.state == paneState)

    -- Use a slightly lighter border template when this pane is active.
    local boxTemplate = isActive
        and interfaces.MWUI.templates.box
        or interfaces.MWUI.templates.boxTransparent

    return {
        type     = ui.TYPE.Flex,
        props    = {
            horizontal = false,
            align      = ui.ALIGNMENT.Start,
        },
        external = { grow = 1 },
        content  = ui.content {
            columnHeader(label),
            myui.padWidget(0, const.Padding * 0.5),
            {
                type     = ui.TYPE.Container,
                template = boxTemplate,
                content  = ui.content { listExt:getElement() },
            },
        },
    }
end

--- Step the batch selector by delta (-1 or +1). Called from onFrame and mouse clicks.
---@param delta number
function SelectionWindow:_stepBatch(delta)
    local newIdx = self._batchIndex + delta
    if newIdx < 1 then newIdx = 1 end
    if newIdx > #self._batchOptions then newIdx = #self._batchOptions end
    if newIdx ~= self._batchIndex then
        ambient.playSound("menu click")
        self._batchIndex = newIdx
        self.batchSize   = self._batchOptions[newIdx]
    end
end

--- Builds the inline select widget for batch size (left arrow / value / right arrow).
--- Mirrors the 'select' renderer from renderers.lua.
---@param self SelectionWindow
---@return Layout
local function batchSelectorLayout(self)
    local isActive   = (self.state == SelectionStateClass.BATCH_AMOUNT_SELECTION)
    local hasOptions = #self._batchOptions > 0

    -- Disabled appearance when options haven't been built yet.
    if not hasOptions then
        return {
            template = interfaces.MWUI.templates.disabled,
            content  = ui.content {
                {
                    template = interfaces.MWUI.templates.box,
                    content  = ui.content {
                        {
                            template = interfaces.MWUI.templates.padding,
                            content  = ui.content {
                                {
                                    type    = ui.TYPE.Flex,
                                    props   = {
                                        horizontal = true,
                                        arrange    = ui.ALIGNMENT.Center,
                                    },
                                    content = ui.content {
                                        {
                                            type  = ui.TYPE.Image,
                                            props = {
                                                resource = ui.texture { path = "textures/omw_menu_scroll_left.dds" },
                                                size     = util.vector2(12, 12),
                                            },
                                        },
                                        { template = interfaces.MWUI.templates.interval },
                                        {
                                            template = interfaces.MWUI.templates.textNormal,
                                            props    = { text = "--" },
                                            external = { grow = 1 },
                                        },
                                        { template = interfaces.MWUI.templates.interval },
                                        {
                                            type  = ui.TYPE.Image,
                                            props = {
                                                resource = ui.texture { path = "textures/omw_menu_scroll_right.dds" },
                                                size     = util.vector2(12, 12),
                                            },
                                        },
                                    },
                                },
                            },
                        },
                    },
                },
            },
        }
    end

    local function stepBatch(delta)
        self:_stepBatch(delta)
    end

    local label      = "x" .. tostring(self.batchSize)
    local labelColor = isActive
        and myui.interactiveTextColors.normal.default
        or myui.interactiveTextColors.disabled.default

    return {
        template = interfaces.MWUI.templates.box,
        content  = ui.content {
            {
                template = interfaces.MWUI.templates.padding,
                content  = ui.content {
                    {
                        type    = ui.TYPE.Flex,
                        props   = {
                            horizontal = true,
                            arrange    = ui.ALIGNMENT.Center,
                        },
                        content = ui.content {
                            -- Left arrow
                            {
                                type   = ui.TYPE.Image,
                                props  = {
                                    resource = ui.texture { path = "textures/omw_menu_scroll_left.dds" },
                                    size     = util.vector2(12, 12),
                                },
                                events = {
                                    mouseClick = async:callback(function()
                                        if isActive then stepBatch(-1) end
                                    end),
                                },
                            },
                            { template = interfaces.MWUI.templates.interval },
                            -- Current value
                            {
                                template = interfaces.MWUI.templates.textNormal,
                                props    = {
                                    text      = label,
                                    textColor = labelColor,
                                },
                                external = { grow = 1 },
                            },
                            { template = interfaces.MWUI.templates.interval },
                            -- Right arrow
                            {
                                type   = ui.TYPE.Image,
                                props  = {
                                    resource = ui.texture { path = "textures/omw_menu_scroll_right.dds" },
                                    size     = util.vector2(12, 12),
                                },
                                events = {
                                    mouseClick = async:callback(function()
                                        if isActive then stepBatch(1) end
                                    end),
                                },
                            },
                        },
                    },
                },
            },
        },
    }
end

--- Builds the right-hand "batch + buttons" column layout.
---@param self SelectionWindow
---@return Layout
local function batchColumnLayout(self)
    return {
        type     = ui.TYPE.Flex,
        props    = {
            horizontal = true,
            align      = ui.ALIGNMENT.Center,
            arrange    = ui.ALIGNMENT.Center,
        },
        external = { grow = 1, stretch = 1 },
        content  = ui.content {
            {
                type     = ui.TYPE.Text,
                props    = {
                    textAlignV = ui.ALIGNMENT.Center,
                    text       = localization("batchColumn", {}),
                    textSize   = 16,
                    textColor  = myui.interactiveTextColors.normal.default,
                },
                external = { stretch = 1 },
            },
            myui.padWidget(const.Padding, const.Padding),
            batchSelectorLayout(self),
            myui.padWidget(const.Padding, const.Padding),
            self._brewButtonElement,
            myui.padWidget(const.Padding, const.Padding),
            self._cancelButtonElement,
        },
    }
end

--- Full window layout.
---@param self SelectionWindow
---@return Layout
function SelectionWindow:_getLayout()
    return {
        layer    = "Windows",
        type     = ui.TYPE.Container,
        template = interfaces.MWUI.templates.boxTransparent,
        props    = {
            anchor           = util.vector2(0.5, 0.5),
            relativePosition = util.vector2(0.5, 0.5),
        },

        content  = ui.content {
            templates.addMarginLayout({
                type     = ui.TYPE.Flex,
                props    = { horizontal = false },
                external = { grow = 1 },

                content  = ui.content {

                    ---- Row 1: four scrollbar columns --------------------------------
                    {
                        type     = ui.TYPE.Flex,
                        props    = {
                            horizontal = true,
                            align      = ui.ALIGNMENT.Start,
                            arrange    = ui.ALIGNMENT.Start,
                        },
                        external = { grow = 1, stretch = 1 },

                        content  = ui.content {
                            -- Column 1: Magic effect
                            columnLayout(self,
                                localization("effectColumn", {}),
                                self.scrollListEffects,
                                SelectionStateClass.PRIMARY_EFFECT_SELECTION),

                            myui.padWidget(const.Padding, 0),

                            -- Column 2: Ingredient 1
                            columnLayout(self,
                                localization("ingredient1Column", {}),
                                self.scrollListIngredient1,
                                SelectionStateClass.INGREDIENT_1_SELECTION),

                            myui.padWidget(const.Padding, 0),

                            -- Column 3: Ingredient 2
                            columnLayout(self,
                                localization("ingredient2Column", {}),
                                self.scrollListIngredient2,
                                SelectionStateClass.INGREDIENT_2_SELECTION),

                            myui.padWidget(const.Padding, 0),

                        }
                    },

                    myui.padWidget(0, const.Padding),

                    ---- Row 2: batch size and buttons
                    batchColumnLayout(self),

                } -- outer Flex content
            }, const.Padding)
        }
    }
end

------------------------------------------------------------------------
-- Constructor
------------------------------------------------------------------------

---@param cancelCallback fun()            close the alchemy window
---@param brewCallback   fun(data: BrewData) start up another shot with current ingredients
---@return SelectionWindow
function SelectionWindow.new(cancelCallback, brewCallback)
    -- Gather every inventory we're allowed to draw ingredients/apparatuses
    -- from: the player's own inventory (always available, owned or not),
    -- plus any nearby container that isn't owned (or is owned by a
    -- faction the player has sufficient rank in). See inventorysource.lua
    -- for the ownership rules and nearby-search radius handling.
    local inventories = inventorysource.getInventories({ radius = const.NearbyContainerRadius })
    local toolStrengths = inventorysource.getApparatusStrengths({ radius = const.NearbyContainerRadius })

    local self = setmetatable({
        state                = SelectionStateClass.PRIMARY_EFFECT_SELECTION,
        _cancelCallback      = cancelCallback,
        _brewCallback        = brewCallback,
        _cancelButtonElement = ui.create {},
        _brewButtonElement   = ui.create {},
        _keys                = newKeys(),
        inventories          = inventories,
        toolStrengths        = toolStrengths,
        availableIngredients = common.getAllIngredients(inventories),
        filteredIngredients  = {},
        effectIndex          = nil,
        ingredient1Index     = nil,
        ingredient2Index     = nil,
        batchSize            = 1,
        _batchOptions        = {},
        _batchIndex          = 1,
        _brewed              = false,
    }, SelectionWindow)

    self:_updateCancelButtonElement()
    self:_updateBrewButtonElement()

    -- Build the effect list (stable for the lifetime of the window).
    self.primaryEffects = common.getSharedMagicEffectsFromActualizedIngredients(self.availableIngredients)
    buildEffectList(self)

    -- Build placeholder ingredient lists (empty; populated once an effect
    -- is chosen via _setPrimaryEffect). We need non-nil VirtualListExt
    -- objects so _getLayout can always call :getElement().
    buildIngredient1List(self) -- empty: filteredIngredients is still {}
    buildIngredient2List(self) -- empty: filteredIngredients is still {}

    self.window = ui.create(self:_getLayout())
    return self
end

------------------------------------------------------------------------
-- onFrame – called every frame by the owning script
------------------------------------------------------------------------

function SelectionWindow:onFrame()
    if not self.window then return end

    -- Update key trackers.
    local dt = core.getRealFrameDuration()
    for _, inp in pairs(self._keys) do
        inp:update(dt)
    end

    -- ---- Directional input -----------------------------------------------

    -- Up / Down: scroll the active pane.
    if self._keys.up.fall then
        scrollActiveList(self, -1)
    elseif self._keys.down.fall then
        scrollActiveList(self, 1)
    end

    -- Left: go back one pane (or no-op on first pane — handled by 'exit').
    --        On the batch pane, left/right step the selector instead.
    if self.state == SelectionStateClass.BATCH_AMOUNT_SELECTION then
        if self._keys.left.fall then
            self:_stepBatch(-1)
        elseif self._keys.right.fall then
            self:_stepBatch(1)
        end
    else
        if self._keys.left.fall then
            if self.state ~= SelectionStateClass.PRIMARY_EFFECT_SELECTION then
                ambient.playSound("menu click")
                SelectionStateTransitions[self.state].backward(self)
            end
        end
    end

    -- Right / Enter / A: advance to next pane (or brew on last pane).
    local wantForward = self._keys.right.fall or self._keys.enter.fall
    if wantForward then
        if self.state == SelectionStateClass.BATCH_AMOUNT_SELECTION then
            -- Brew!
            settings.debugPrint("brewCallback via key")
            self:_doBrew()
            return
        end
        -- Only advance if the current pane has something selected.
        if currentPaneHasSelection(self) then
            ambient.playSound("menu click")
            SelectionStateTransitions[self.state].forward(self)
        else
            -- Play a "no" feedback sound.
            ambient.playSound("menu click")
        end
    end

    -- B button: back one pane, or cancel from first pane.
    if self._keys.exit.fall then
        if self.state == SelectionStateClass.PRIMARY_EFFECT_SELECTION then
            settings.debugPrint("cancelCallback via exit key")
            self._cancelCallback()
            return
        end
        ambient.playSound("menu click")
        SelectionStateTransitions[self.state].backward(self)
    end

    -- ---- Rebuild buttons and re-render ------------------------------------
    self:_updateBrewButtonElement()

    self.window.layout = self:_getLayout()
    self.window:update()
end

------------------------------------------------------------------------
-- close
------------------------------------------------------------------------

function SelectionWindow:close()
    if not self.window then return end
    self.window:destroy()
    self.window = nil
end

------------------------------------------------------------------------
-- Module export
------------------------------------------------------------------------

return SelectionWindow
