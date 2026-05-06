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
local MOD_NAME      = require("scripts.ErnPotionMaster.ns")
local const         = require("scripts.ErnPotionMaster.const")
local ui            = require("openmw.ui")
local util          = require("openmw.util")
local dynamic       = require("scripts.ErnPotionMaster.render.dynamic")
local interfaces    = require('openmw.interfaces')
local aux_util      = require('openmw_aux.util')
local settings      = require("scripts.ErnPotionMaster.settings.settings")

---@class RenderBoard
---@field boardElement any
---@field pins any
---@field balls any
---@field private _pinsElement any
---@field private _ballsElement any
---@field private _ballDT number
---@field private _pinDT number
local RenderBoard   = {}
RenderBoard.__index = RenderBoard

local MIN_UPDATE    = 1 / 63

-- Iterate through all layers
for i, layer in ipairs(ui.layers) do
    print('layer', i, layer.name, layer.size)
end

---@return RenderBoard
function RenderBoard.new()
    local self = setmetatable({}, RenderBoard)

    self._pinsElement = ui.create {
        name = 'pins',
        type = ui.TYPE.Widget,
        props = {
            size = const.BoardSize,
        },
        content = ui.content {}
    }

    self._ballsElement = ui.create {
        name = 'balls',
        type = ui.TYPE.Widget,
        props = {
            size = const.BoardSize,
        },
        content = ui.content {}
    }

    -- Dynamic containers (instance-specific)
    self.pins = dynamic.NewDynamicContainer(self._pinsElement, {})
    self.balls = dynamic.NewDynamicContainer(self._ballsElement, {})

    -- Board root element
    self.boardElement = ui.create({
        name = "board",
        type = ui.TYPE.Widget,
        props = {
            size = const.BoardSize,
            visible = true,
        },
        content = ui.content {
            {
                template = interfaces.MWUI.templates.textNormal,
                props = {
                    text = "left top",
                    relativePosition = util.vector2(0, 0),
                    anchor = util.vector2(0, 0)
                }
            },
            {
                template = interfaces.MWUI.templates.textNormal,
                props = {
                    text = "right bottom",
                    relativePosition = util.vector2(1, 1),
                    anchor = util.vector2(1, 1)
                }
            },
            self._pinsElement,
            self._ballsElement
        }
    })

    -- Timers (instance-specific)
    self._ballDT = 0
    self._pinDT = 0

    return self
end

---@param dt number
function RenderBoard:onFrame(dt)
    if not self.boardElement.layout.props.visible then
        self._ballDT = MIN_UPDATE
        self._pinDT  = MIN_UPDATE
        return
    end

    self._ballDT = self._ballDT + dt
    self._pinDT  = self._pinDT + dt

    if self._ballDT < MIN_UPDATE and self._pinDT < MIN_UPDATE then
        return
    elseif self._ballDT > self._pinDT then
        self.balls:Render(self._ballDT)
        self._ballDT = 0
    else
        self.pins:Render(self._pinDT)
        self._pinDT = 0
    end
end

function RenderBoard:reset()
    self.balls:Reset()
    self.pins:Reset()
    --self.boardElement:update()
end

return RenderBoard
