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

-- This file contains the game state, including the board.
-- It owns and rebuilds the pachinko physics board as necessary.
-- It owns and rebuilds the render board as necessary.
-- It maintains a registry of balls and pins indexed by their ID,
-- and sends this info as necessary to both the pachinko physics board and render board.

local MOD_NAME                  = require("scripts.ErnPotionMaster.ns")
local const                     = require("scripts.ErnPotionMaster.const")
local ui                        = require("openmw.ui")
local util                      = require("openmw.util")
local pself                     = require("openmw.self")
local core                      = require("openmw.core")
local types                     = require("openmw.types")
local placepins                 = require("scripts.ErnPotionMaster.placepins")
local settings                  = require("scripts.ErnPotionMaster.settings.settings")
local physics                   = require("scripts.ErnPotionMaster.physics.pachinko")
local interfaces                = require('openmw.interfaces')
local shuffle                   = require("scripts.ErnPotionMaster.shuffle")
local aux_util                  = require('openmw_aux.util')
local renderBoard               = require("scripts.ErnPotionMaster.render.board")
local templates                 = require("scripts.ErnPotionMaster.render.templates")
local effectScore               = require("scripts.ErnPotionMaster.effectscore")
local ingredientInfo            = require("scripts.ErnPotionMaster.ingredientinfo")
local search                    = require("scripts.ErnPotionMaster.search")
local common                    = require("scripts.ErnPotionMaster.common")
local sprite                    = require("scripts.ErnPotionMaster.render.sprite")
local keytrack                  = require("scripts.ErnPotionMaster.keytrack")
local myui                      = require("scripts.ErnPotionMaster.pcp.myui")
local trajectory                = require("scripts.ErnPotionMaster.render.trajectory")
local input                     = require("openmw.input")
local async                     = require("openmw.async")
local ambient                   = require("openmw.ambient")
local potionux                  = require("scripts.ErnPotionMaster.render.potionwidget")
local localization              = core.l10n(MOD_NAME)

---@enum SelectionStateClass
local SelectionStateClass       = {
    PRIMARY_EFFECT_SELECTION = 1,
    INGREDIENT_1_SELECTION = 2,
    INGREDIENT_2_SELECTION = 3,
    --- let people do 5x at a time. they end up with 5 identical potions (or failures)
    BATCH_AMOUNT_SELECTION = 4,
}

---@class SelectionStateMethods
---@field forward fun(window: SelectionWindow)
---@field backward fun(window: SelectionWindow)

---@type {[SelectionStateClass]: SelectionStateMethods}
local SelectionStateTransitions = {
    PRIMARY_EFFECT_SELECTION = {
        forward = function(window)
            settings.debugPrint("advance to INGREDIENT_1_SELECTION")
            window.state = SelectionStateClass.INGREDIENT_1_SELECTION
        end,
        backward = function(window)
            settings.debugPrint("close!")
            window._cancelCallback()
        end
    },
    INGREDIENT_1_SELECTION = {
        forward = function(window)
            settings.debugPrint("advance to INGREDIENT_2_SELECTION")
            window.state = SelectionStateClass.INGREDIENT_2_SELECTION
        end,
        backward = function(window)
            -- TODO: clear ingred 1, ingred 2, and batch
            window.state = SelectionStateClass.PRIMARY_EFFECT_SELECTION
        end
    },
    INGREDIENT_2_SELECTION = {
        forward = function(window)
            settings.debugPrint("advance to BATCH_AMOUNT_SELECTION")
            window.state = SelectionStateClass.BATCH_AMOUNT_SELECTION
        end,
        backward = function(window)
            -- TODO: clear ingred 2 and batch
            window.state = SelectionStateClass.INGREDIENT_1_SELECTION
        end
    },
    BATCH_AMOUNT_SELECTION = {
        forward = function(window)
            settings.debugPrint("play!")
            --- TODO: pass through relevant data
            window._brewCallback()
        end,
        backward = function(window)
            window.state = SelectionStateClass.INGREDIENT_2_SELECTION
        end
    }
}

---@class SelectionWindow
---@field window table  openmw ui element
---@field _cancelCallback fun(data) close the alchemy window
---@field _brewCallback fun(data) start up another shot with current ingredients
---@field _cancelButtonElement any
---@field _brewButtonElement any
---@field availableIngredients ActualizedIngredient[] this is ALL ingredients, unfiltered.
---@field primaryEffect MagicEffectWithParams? this is the list of effects available to the player. only effects that are shared by at least two different ingredients show up in the list.
---@field filteredIngredients ActualizedIngredient[] this is a subset of availableIngredients. it has only ingredients in which one effect is the primaryEffect.
---@field ingredient1Index number? this is an index into filteredIngredients
---@field ingredient2Index number? this is an index into filteredIngredients. it's not allowed to equal ingredient1Index.
---@field batchSize number this is the batch size. the max value for this is the minimum of ingredient 1 and ingredient 2 counts.
---@field _keys table
---@field state SelectionStateClass
--- TODO: add fields for UI scrollbar stuff
local SelectionWindow           = {}
SelectionWindow.__index         = SelectionWindow


local function newKeys()
    return {
        forward  = keytrack.NewKey("forward", function(dt)
            return input.isKeyPressed(input.KEY.UpArrow) or
                (input.getAxisValue(input.CONTROLLER_AXIS.RightY) < -1 * const.stickDeadzone)
        end),
        backward = keytrack.NewKey("backward", function(dt)
            return input.isKeyPressed(input.KEY.DownArrow) or
                (input.getAxisValue(input.CONTROLLER_AXIS.RightY) > const.stickDeadzone)
        end),
        back     = keytrack.NewKey("back", function(dt)
            return input.isControllerButtonPressed(input.CONTROLLER_BUTTON.B)
        end),
        enter    = keytrack.NewKey("enter", function(dt)
            return input.isKeyPressed(input.KEY.Enter) or
                (input.isControllerButtonPressed(input.CONTROLLER_BUTTON.A))
        end),
    }
end

function SelectionWindow:_updateBrewButtonElement()
    local saveFn = function()
        settings.debugPrint("brew clicked")
        if self.state == SelectionStateClass.BATCH_AMOUNT_SELECTION then
            self._brewCallback()
        else
            -- TODO: play "no" sound
        end
    end
    self._brewButtonElement.layout = myui.createTextButton(
        self._brewButtonElement,
        localization("brewButton", {}),
        self._brewCallback and "normal" or "disabled",
        "saveButton",
        {},
        const.ButtonSize,
        saveFn)
    self._brewButtonElement:update()
end

function SelectionWindow:_updateCancelButtonElement()
    local saveFn = function()
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
        saveFn)
    self._cancelButtonElement:update()
end

function SelectionWindow:_getLayout(dt)
    return {
        layer = "Windows",
        type = ui.TYPE.Container,
        template = interfaces.MWUI.templates.boxTransparent,
        props = {
            anchor = util.vector2(0.5, 0.5),
            relativePosition = util.vector2(0.5, 0.5),
        },

        content = ui.content {
            templates.addMarginLayout({
                type = ui.TYPE.Flex,
                props = {
                    horizontal = false,
                },
                external = {
                    grow = 1,
                },

                content = ui.content {

                    -- Main potion renderer
                    {
                        type = ui.TYPE.Container,
                        external = {
                            grow = 1,
                        },
                        content = ui.content {
                            {
                                template = interfaces.MWUI.templates.textNormal,
                                props = {
                                    text = "placeholder",
                                    relativePosition = util.vector2(0.5, 0.5),
                                    anchor = util.vector2(0.5, 0.5)
                                }
                            }
                        }
                    },

                    -- Padding above buttons
                    myui.padWidget(0, const.Padding),

                    -- Bottom button row
                    {
                        type = ui.TYPE.Flex,
                        props = {
                            horizontal = true,
                            align = ui.ALIGNMENT.Center,
                            arrange = ui.ALIGNMENT.Center,
                        },
                        external = {
                            grow = 1,
                            stretch = 1,
                        },
                        content = ui.content {
                            self._brewButtonElement,
                            myui.padWidget(const.Padding, 0),
                            self._cancelButtonElement,
                        }
                    }
                }
            }, const.Padding)
        }
    }
end

---@param record table potion record
---@param count number
---@param cancelCallback fun(data) close the alchemy window
---@param brewCallback fun(data) start up another shot with current ingredients
---@return SelectionWindow
function SelectionWindow.new(record, count, cancelCallback, brewCallback)
    local self = setmetatable({
        state                = SelectionStateClass.PRIMARY_EFFECT_SELECTION,
        _cancelCallback      = cancelCallback,
        _brewCallback        = brewCallback,
        _cancelButtonElement = ui.create {},
        _brewButtonElement   = ui.create {},
        _keys                = newKeys(),
        availableIngredients = {},
    }, SelectionWindow)
    self:_updateCancelButtonElement()
    self:_updateBrewButtonElement()


    --- TODO: grab all nearby inventories
    local inventories = { pself.type.inventory(pself) }

    self.availableIngredients = common.getAllIngredients(inventories)

    self.window = ui.create(self:_getLayout(0))
    return self
end

---Must be called from the global onFrame handler every frame.
function SelectionWindow:onFrame()
    if not self.window then return end
    local dt = core.getRealFrameDuration()

    -- Track inputs.
    for _, inp in pairs(self._keys) do
        inp:update(dt)
    end

    -- todo: update disabled status of brew button

    self.window.layout = self:_getLayout(dt)
    self.window:update()

    ---- TODO: these buttons should go back/forth on the scrollbars
    --- TODO: scroll up/down the current bar
    if self._keys.exit.fall then
        SelectionStateTransitions[self.state].backward(self)
    elseif self._keys.enter.fall then
        SelectionStateTransitions[self.state].forward(self)
    end
end

function SelectionWindow:close()
    if not self.window then return end
    self.window:destroy()
    self.window = nil
end

------------------------------------------------------------------------
-- Module export
------------------------------------------------------------------------

return SelectionWindow
