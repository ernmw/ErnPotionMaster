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

local MOD_NAME                  = require("scripts.ErnPotionMaster.ns")
local const                     = require("scripts.ErnPotionMaster.const")
local ui                        = require("openmw.ui")
local util                      = require("openmw.util")
local pself                     = require("openmw.self")
local core                      = require("openmw.core")
local types                     = require("openmw.types")
local interfaces                = require('openmw.interfaces')
local settings                  = require("scripts.ErnPotionMaster.settings.settings")
local common                    = require("scripts.ErnPotionMaster.common")
local templates                 = require("scripts.ErnPotionMaster.render.templates")
local myui                      = require("scripts.ErnPotionMaster.pcp.myui")
local keytrack                  = require("scripts.ErnPotionMaster.keytrack")
local virtualListExtras         = require("scripts.ErnEnchantersRecharge.virtual_list.extras")
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

---@class SelectionStateMethods
---@field forward  fun(window: SelectionWindow)
---@field backward fun(window: SelectionWindow)

---@type {[SelectionStateClass]: SelectionStateMethods}
local SelectionStateTransitions = {
    PRIMARY_EFFECT_SELECTION = {
        forward = function(window)
            settings.debugPrint("advance to INGREDIENT_1_SELECTION")
            -- Re-build ingredient 1 list now that we know the effect.
            window:_rebuildIngredient1List()
            window.state = SelectionStateClass.INGREDIENT_1_SELECTION
        end,
        backward = function(window)
            error("should not be hit")
        end
    },
    INGREDIENT_1_SELECTION = {
        forward = function(window)
            settings.debugPrint("advance to INGREDIENT_2_SELECTION")
            -- Re-build ingredient 2 list now that we know ingredient 1.
            window:_rebuildIngredient2List()
            window.state = SelectionStateClass.INGREDIENT_2_SELECTION
        end,
        backward = function(window)
            -- Clear ingredient 1, ingredient 2, and batch.
            window.ingredient1Index = nil
            window.ingredient2Index = nil
            window.batchSize        = 1
            window.scrollListIngredient1:changeSelection(nil)
            window.scrollListIngredient2:changeSelection(nil)
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
            -- Clear ingredient 2 and batch.
            window.ingredient2Index = nil
            window.batchSize        = 1
            window.scrollListIngredient2:changeSelection(nil)
            window.state = SelectionStateClass.INGREDIENT_1_SELECTION
        end
    },
    BATCH_AMOUNT_SELECTION = {
        forward = function(window)
            error("should not be hit")
        end,
        backward = function(window)
            window.batchSize = 1
            window.scrollListBatch:changeSelection(nil)
            window.state = SelectionStateClass.INGREDIENT_2_SELECTION
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
---@field scrollListBatch         VirtualListExt
---@field availableIngredients    ActualizedIngredient[] ALL ingredients, unfiltered
---@field primaryEffects          MagicEffectWithParams[] effects shared by ≥2 different ingredients
---@field filteredIngredients     ActualizedIngredient[] ingredients that carry the chosen primary effect
---@field ingredient1Index        number?  index into filteredIngredients
---@field ingredient2Index        number?  index into filteredIngredients (≠ ingredient1Index)
---@field batchSize               number   1-based; clamped to min(ing1.count, ing2.count)
---@field _batchOptions           number[] list of valid batch sizes (e.g. {1,2,3,4,5})
---@field _keys                   table
---@field state                   SelectionStateClass

---@class BrewData
---@field primaryEffect   MagicEffectWithParams
---@field ingredient1     ActualizedIngredient
---@field ingredient2     ActualizedIngredient
---@field batchSize       number

local SelectionWindow           = {}
SelectionWindow.__index         = SelectionWindow

------------------------------------------------------------------------
-- Key bindings
------------------------------------------------------------------------

local function newKeys()
    return {
        up    = keytrack.NewKey("up", function(dt)
            return input.isKeyPressed(input.KEY.UpArrow) or
                (input.getAxisValue(input.CONTROLLER_AXIS.RightY) < -1 * const.stickDeadzone)
        end),
        down  = keytrack.NewKey("down", function(dt)
            return input.isKeyPressed(input.KEY.DownArrow) or
                (input.getAxisValue(input.CONTROLLER_AXIS.RightY) > const.stickDeadzone)
        end),
        left  = keytrack.NewKey("left", function(dt)
            return input.isKeyPressed(input.KEY.LeftArrow) or
                (input.getAxisValue(input.CONTROLLER_AXIS.RightX) < -1 * const.stickDeadzone)
        end),
        right = keytrack.NewKey("right", function(dt)
            return input.isKeyPressed(input.KEY.RightArrow) or
                (input.getAxisValue(input.CONTROLLER_AXIS.RightX) > const.stickDeadzone)
        end),
        exit  = keytrack.NewKey("back", function(dt)
            -- B button: go back a pane, or cancel on the first pane.
            return input.isControllerButtonPressed(input.CONTROLLER_BUTTON.B)
        end),
        enter = keytrack.NewKey("enter", function(dt)
            -- A / Enter: confirm selection / advance pane, brew on last pane.
            return input.isKeyPressed(input.KEY.Return) or
                input.isControllerButtonPressed(input.CONTROLLER_BUTTON.A)
        end),
    }
end

------------------------------------------------------------------------
-- Internal helpers
------------------------------------------------------------------------

--- Returns the VirtualListExt that is "active" for the current state.
---@param self SelectionWindow
---@return VirtualListExt
local function activeList(self)
    if self.state == SelectionStateClass.PRIMARY_EFFECT_SELECTION then
        return self.scrollListEffects
    elseif self.state == SelectionStateClass.INGREDIENT_1_SELECTION then
        return self.scrollListIngredient1
    elseif self.state == SelectionStateClass.INGREDIENT_2_SELECTION then
        return self.scrollListIngredient2
    else
        return self.scrollListBatch
    end
end

--- Scroll the active list one step up or down.
---@param self SelectionWindow
---@param direction number  -1 for up, +1 for down
local function scrollActiveList(self, direction)
    local list       = activeList(self)
    local scrollData = list:getElement().layout.userData.scrollData

    local current    = list:getSelectedIndex()
    local first      = scrollData:getFirstIndex()
    local last       = scrollData:getLastIndex()

    local newIndex
    if current == nil then
        newIndex = (direction > 0) and first or last
    else
        newIndex = current + direction
        if newIndex < first then newIndex = first end
        if newIndex > last then newIndex = last end
    end

    if newIndex ~= current then
        ambient.playSound("menu click")
        list:changeSelection(newIndex)
        if direction < 0 then
            scrollData:scrollToIndex(newIndex, "top")
        else
            scrollData:scrollToIndex(newIndex, "bottom")
        end
    end
end

--- Whether the current state has a valid selection committed.
--- (For effects/ingredients we require an index; batch always has one.)
---@param self SelectionWindow
---@return boolean
local function currentPaneHasSelection(self)
    if self.state == SelectionStateClass.PRIMARY_EFFECT_SELECTION then
        return self.scrollListEffects:getSelectedIndex() ~= nil
    elseif self.state == SelectionStateClass.INGREDIENT_1_SELECTION then
        return self.ingredient1Index ~= nil
    elseif self.state == SelectionStateClass.INGREDIENT_2_SELECTION then
        return self.ingredient2Index ~= nil
    else -- BATCH_AMOUNT_SELECTION
        return self.scrollListBatch:getSelectedIndex() ~= nil
    end
end

--- Build the summary text shown beneath the scroll columns.
---@param self SelectionWindow
---@return string
local function buildSummaryText(self)
    local parts = {}

    local effectIdx = self.scrollListEffects:getSelectedIndex()
    if effectIdx then
        local eff = self.primaryEffects[effectIdx]
        table.insert(parts, templates.effectToString(eff))
    end

    if self.ingredient1Index then
        local ing = self.filteredIngredients[self.ingredient1Index]
        table.insert(parts, localization("itemQuantity", { name = ing.record.name, quantity = tostring(ing.count) }))
    end

    if self.ingredient2Index then
        local ing = self.filteredIngredients[self.ingredient2Index]
        table.insert(parts, localization("itemQuantity", { name = ing.record.name, quantity = tostring(ing.count) }))
    end

    if self.state == SelectionStateClass.BATCH_AMOUNT_SELECTION then
        table.insert(parts, localization("batchLabel", {}) .. ": " .. tostring(self.batchSize))
    end

    if #parts == 0 then
        return localization("selectEffectHint", {})
    end
    return table.concat(parts, "  |  ")
end

------------------------------------------------------------------------
-- List (re)builders
-- These are called lazily as the player advances through states.
------------------------------------------------------------------------

--- Create the scrollListEffects list.  Called once during construction.
---@param self SelectionWindow
local function buildEffectList(self)
    self.scrollListEffects = virtualListExtras.List.create({
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
                        list:changeSelection(i)
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
            self.scrollListEffects:changeSelection(i)
        end,
    })
end

--- (Re)build the ingredient-1 list filtered by the currently selected effect.
--- Called when advancing from PRIMARY_EFFECT_SELECTION.
function SelectionWindow:_rebuildIngredient1List()
    local effectIdx = self.scrollListEffects:getSelectedIndex()
    if not effectIdx then
        self.filteredIngredients = {}
    else
        local chosenEffect = self.primaryEffects[effectIdx]
        -- Keep only ingredients that carry this effect.
        self.filteredIngredients = {}
        for _, ing in ipairs(self.availableIngredients) do
            for _, mewp in ipairs(ing.record.effects) do
                if common.magicEffectsEqual(mewp, chosenEffect) then
                    table.insert(self.filteredIngredients, ing)
                    break
                end
            end
        end
    end

    -- Reset downstream selections.
    self.ingredient1Index      = nil
    self.ingredient2Index      = nil
    self.batchSize             = 1

    self.scrollListIngredient1 = virtualListExtras.List.create({
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
                        list:changeSelection(i)
                        self.ingredient1Index = i
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
            self.scrollListIngredient1:changeSelection(i)
            self.ingredient1Index = i
        end,
    })
end

--- (Re)build the ingredient-2 list, excluding the ingredient-1 choice.
--- Called when advancing from INGREDIENT_1_SELECTION.
function SelectionWindow:_rebuildIngredient2List()
    -- ingredient2 list is the same filteredIngredients but we disallow the same
    -- index as ingredient1.
    self.ingredient2Index      = nil
    self.batchSize             = 1

    self.scrollListIngredient2 = virtualListExtras.List.create({
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
                        list:changeSelection(i)
                        self.ingredient2Index = i
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
            self.scrollListIngredient2:changeSelection(i)
            self.ingredient2Index = i
        end,
    })
end

--- (Re)build the batch-size list.
--- Called when advancing from INGREDIENT_2_SELECTION.
function SelectionWindow:_rebuildBatchList()
    self.batchSize = 1

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

    self.scrollListBatch = virtualListExtras.List.create({
        viewportSize = const.ScrollListPaneSize,
        itemSize     = const.ScrollListItemSize,
        itemCount    = #self._batchOptions,
        itemLayout   = function(i, list)
            local n = self._batchOptions[i]
            return list:createItemLayout({
                index = i,
                props = { text = "x" .. tostring(n) },
                onMousePress = function(e, layout)
                    if e.button == 1 then
                        list:changeSelection(i)
                        self.batchSize = n
                    end
                end,
            })
        end,
    })
    self.scrollListBatch:setKeyPressHandler({
        setSelectedIndex = function(i)
            self.scrollListBatch:changeSelection(i)
            self.batchSize = self._batchOptions[i]
        end,
    })

    -- Default to first option (x1).
    self.scrollListBatch:changeSelection(1)
    self.batchSize = self._batchOptions[1]
end

------------------------------------------------------------------------
-- Button helpers
------------------------------------------------------------------------

function SelectionWindow:_updateBrewButtonElement()
    -- Brew is only actionable on the last pane AND when there is a batch selection.
    local isReady = (self.state == SelectionStateClass.BATCH_AMOUNT_SELECTION) and
        (self.scrollListBatch ~= nil) and
        (self.scrollListBatch:getSelectedIndex() ~= nil)

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
function SelectionWindow:_doBrew()
    if not self.ingredient1Index or not self.ingredient2Index then
        settings.debugPrint("_doBrew called but ingredients not selected")
        return
    end
    local effectIdx = self.scrollListEffects:getSelectedIndex()
    if not effectIdx then
        settings.debugPrint("_doBrew called but effect not selected")
        return
    end

    ---@type BrewData
    local data = {
        primaryEffect = self.primaryEffects[effectIdx],
        ingredient1   = self.filteredIngredients[self.ingredient1Index],
        ingredient2   = self.filteredIngredients[self.ingredient2Index],
        batchSize     = self.batchSize,
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
            textColor = util.color.rgb(0.8, 0.8, 0.5),
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

--- Builds the right-hand "batch + buttons" column layout.
---@param self SelectionWindow
---@return Layout
local function batchColumnLayout(self)
    local isActive = (self.state == SelectionStateClass.BATCH_AMOUNT_SELECTION)
    local boxTemplate = isActive
        and interfaces.MWUI.templates.box
        or interfaces.MWUI.templates.boxTransparent

    -- Only show the batch list when it has been built.
    local batchListContent
    if self.scrollListBatch then
        batchListContent = {
            type     = ui.TYPE.Container,
            template = boxTemplate,
            content  = ui.content { self.scrollListBatch:getElement() },
        }
    else
        batchListContent = {
            type  = ui.TYPE.Text,
            props = {
                text      = "--",
                textSize  = 14,
                textColor = util.color.rgb(0.5, 0.5, 0.5),
            },
        }
    end

    return {
        type     = ui.TYPE.Flex,
        props    = {
            horizontal = false,
            align      = ui.ALIGNMENT.Center,
        },
        external = { grow = 1 },
        content  = ui.content {
            columnHeader(localization("batchColumn", {})),
            myui.padWidget(0, const.Padding * 0.5),
            batchListContent,
            myui.padWidget(0, const.Padding),
            self._brewButtonElement,
            myui.padWidget(0, const.Padding * 0.5),
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

                            -- Column 4: Batch size + buttons
                            batchColumnLayout(self),
                        }
                    },

                    myui.padWidget(0, const.Padding),

                    ---- Row 2: summary of current selections -------------------------
                    {
                        type     = ui.TYPE.Flex,
                        props    = {
                            horizontal = true,
                            align      = ui.ALIGNMENT.Center,
                            arrange    = ui.ALIGNMENT.Center,
                        },
                        external = { stretch = 1 },
                        content  = ui.content {
                            {
                                template = interfaces.MWUI.templates.textNormal,
                                props    = {
                                    text             = buildSummaryText(self),
                                    relativePosition = util.vector2(0.5, 0.5),
                                    anchor           = util.vector2(0.5, 0.5),
                                },
                            }
                        }
                    },

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
    -- Grab all inventories we care about (player for now; extend as desired).
    local inventories = { pself.type.inventory(pself) }

    local self = setmetatable({
        state                = SelectionStateClass.PRIMARY_EFFECT_SELECTION,
        _cancelCallback      = cancelCallback,
        _brewCallback        = brewCallback,
        _cancelButtonElement = ui.create {},
        _brewButtonElement   = ui.create {},
        _keys                = newKeys(),
        availableIngredients = common.getAllIngredients(inventories),
        filteredIngredients  = {},
        ingredient1Index     = nil,
        ingredient2Index     = nil,
        batchSize            = 1,
        _batchOptions        = {},
        scrollListBatch      = nil,
    }, SelectionWindow)

    self:_updateCancelButtonElement()
    self:_updateBrewButtonElement()

    -- Build the effect list (stable for the lifetime of the window).
    self.primaryEffects = common.getSharedMagicEffectsFromActualizedIngredients(self.availableIngredients)
    buildEffectList(self)

    -- Build placeholder ingredient lists (empty; rebuilt when effect is chosen).
    -- We need non-nil VirtualListExt objects so _getLayout can always call :getElement().
    self:_rebuildIngredient1List() -- will be empty since no effect yet
    self:_rebuildIngredient2List() -- will be empty since no ingredient1 yet

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
    if self._keys.left.fall then
        if self.state ~= SelectionStateClass.PRIMARY_EFFECT_SELECTION then
            ambient.playSound("menu click")
            SelectionStateTransitions[self.state].backward(self)
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
