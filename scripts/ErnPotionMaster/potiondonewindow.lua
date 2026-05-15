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

local MOD_NAME           = require("scripts.ErnPotionMaster.ns")
local const              = require("scripts.ErnPotionMaster.const")
local ui                 = require("openmw.ui")
local util               = require("openmw.util")
local pself              = require("openmw.self")
local core               = require("openmw.core")
local types              = require("openmw.types")
local placepins          = require("scripts.ErnPotionMaster.placepins")
local settings           = require("scripts.ErnPotionMaster.settings.settings")
local physics            = require("scripts.ErnPotionMaster.physics.pachinko")
local interfaces         = require('openmw.interfaces')
local shuffle            = require("scripts.ErnPotionMaster.shuffle")
local aux_util           = require('openmw_aux.util')
local renderBoard        = require("scripts.ErnPotionMaster.render.board")
local templates          = require("scripts.ErnPotionMaster.render.templates")
local effectScore        = require("scripts.ErnPotionMaster.effectscore")
local ingredientInfo     = require("scripts.ErnPotionMaster.ingredientinfo")
local search             = require("scripts.ErnPotionMaster.search")
local common             = require("scripts.ErnPotionMaster.common")
local sprite             = require("scripts.ErnPotionMaster.render.sprite")
local keytrack           = require("scripts.ErnPotionMaster.keytrack")
local myui               = require("scripts.ErnPotionMaster.pcp.myui")
local trajectory         = require("scripts.ErnPotionMaster.render.trajectory")
local input              = require("openmw.input")
local async              = require("openmw.async")
local ambient            = require("openmw.ambient")
local potionux           = require("scripts.ErnPotionMaster.render.potionwidget")
local localization       = core.l10n(MOD_NAME)

---@class PotionDoneWindow
---@field window table  openmw ui element
---@field _potionRenderer PotionRenderer
---@field _closeCallback fun(data) close the alchemy window
---@field _againCallback fun(data)? start up another shot with current ingredients
---@field _doneButtonElement any
---@field _againButtonElement any
---@field _keys table
local PotionDoneWindow   = {}
PotionDoneWindow.__index = PotionDoneWindow


local function newKeys()
    return {
        exit  = keytrack.NewKey("exit", function(dt)
            return input.isControllerButtonPressed(input.CONTROLLER_BUTTON.B)
        end),
        enter = keytrack.NewKey("enter", function(dt)
            return input.isKeyPressed(input.KEY.Enter) or
                (input.isControllerButtonPressed(input.CONTROLLER_BUTTON.A))
        end),
    }
end

function PotionDoneWindow:_updateAgainButtonElement()
    local saveFn = function()
        settings.debugPrint("again clicked")
        if self._againCallback then self._againCallback() end
    end
    self._againButtonElement.layout = myui.createTextButton(
        self._againButtonElement,
        localization("againButton", {}),
        self._againCallback and "normal" or "disabled",
        "saveButton",
        {},
        const.ButtonSize,
        saveFn)
    self._againButtonElement:update()
end

function PotionDoneWindow:_updateDoneButtonElement()
    local saveFn = function()
        settings.debugPrint("done clicked")
        self._closeCallback()
    end
    self._doneButtonElement.layout = myui.createTextButton(
        self._doneButtonElement,
        localization("doneButton", {}),
        "normal",
        "saveButton",
        {},
        const.ButtonSize,
        saveFn)
    self._doneButtonElement:update()
end

function PotionDoneWindow:_getLayout(dt)
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
                            self._potionRenderer:GetLayout(dt)
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
                            self._againButtonElement,
                            myui.padWidget(const.Padding, 0),
                            self._doneButtonElement,
                        }
                    }
                }
            }, const.Padding)
        }
    }
end

---@param record table potion record
---@param count number
---@param closeCallback fun(data)? close the alchemy window
---@param againCallback fun(data)? start up another shot with current ingredients
---@return PotionDoneWindow
function PotionDoneWindow.new(record, count, closeCallback, againCallback)
    local self = setmetatable({
        _potionRenderer     = potionux.NewPotionRenderer(
            record,
            {
                --size = util.vector2(500, 500),
                arrange = ui.ALIGNMENT.Center,
            },
            count
        ),
        _closeCallback      = closeCallback,
        _againCallback      = againCallback,
        _doneButtonElement  = ui.create {},
        _againButtonElement = ui.create {},
        _keys               = newKeys()
    }, PotionDoneWindow)
    self:_updateAgainButtonElement()
    self:_updateDoneButtonElement()
    self.window = ui.create(self._potionRenderer)
    return self
end

---Must be called from the global onFrame handler every frame.
function PotionDoneWindow:onFrame()
    if not self.window then return end
    local dt = core.getRealFrameDuration()

    -- Track inputs.
    for _, inp in pairs(self._keys) do
        inp:update(dt)
    end

    self.window.layout = self:_getLayout(dt)
    self.window:update()

    if self._keys.exit.fall then
        settings.debugPrint("exit button")
        self._closeCallback()
    elseif self._keys.enter.fall then
        settings.debugPrint("again button")
        self._againCallback()
    end
end

function PotionDoneWindow:close()
    if not self.window then return end
    self.window:destroy()
    self.window = nil
    self._potionRenderer = nil
end

------------------------------------------------------------------------
-- Module export
------------------------------------------------------------------------

return PotionDoneWindow
