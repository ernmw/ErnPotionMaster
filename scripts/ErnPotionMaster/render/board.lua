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
local MOD_NAME     = require("scripts.ErnPotionMaster.ns")
local const        = require("scripts.ErnPotionMaster.const")
local ui           = require("openmw.ui")
local util         = require("openmw.util")
local dynamic      = require("scripts.ErnPotionMaster.render.dynamic")
local interfaces   = require('openmw.interfaces')

local pins         = dynamic.NewDynamicContainer("pins", {})
-- balls are in their own container because they change often.
local balls        = dynamic.NewDynamicContainer("balls", {})
local boardElement = ui.create {
    name = 'board',
    type = ui.TYPE.Widget,
    props = {
        size = const.BoardSize,
        visible = true,
        --propagateEvents = false,
    },
    content = ui.content {
        pins.element,
        balls.element,
    }
}

local minUpdate    = 0.01
local ballDT       = 0
local pinDT        = 0
local function onFrame(dt)
    if not boardElement.layout.props.visible then
        ballDT = minUpdate
        pinDT  = minUpdate
        return
    end

    ballDT = ballDT + dt
    pinDT = pinDT + dt

    if ballDT < minUpdate and pinDT < minUpdate then
        return
    elseif ballDT > pinDT then
        balls:Render(ballDT)
        ballDT = 0
        boardElement:update()
    else
        pins:Render(pinDT)
        boardElement:update()
        pinDT = 0
    end
end

return {
    boardElement = boardElement,
    balls = balls,
    pins = pins,
    onFrame = onFrame,
    reset = function()
        balls:Reset()
        pins:Reset()
    end
}
