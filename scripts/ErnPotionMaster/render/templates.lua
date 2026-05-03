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
local MOD_NAME   = require("scripts.ErnPotionMaster.ns")
local const      = require("scripts.ErnPotionMaster.const")
local ui         = require("openmw.ui")
local util       = require("openmw.util")
local dynamic    = require("scripts.ErnPotionMaster.render.dynamic")
local interfaces = require('openmw.interfaces')

local pinWidget  = {
    props = {
        size = const.PinSize,
        anchor = util.vector2(0.5, 0.5),
    },
    content = {
        {
            type = ui.TYPE.Image,
            props = {
                relativeSize = util.vector2(1, 1),
                resource = ui.texture {
                    path = "textures\\ErnPotionMaster\\circle.png"
                },
            },
            events = {},
        }
    }
}

local ballWidget = {
    props = {
        size = const.BallSize,
        anchor = util.vector2(0.5, 0.5),
    },
    content = {
        {
            type = ui.TYPE.Image,
            props = {
                relativeSize = util.vector2(1, 1),
                resource = ui.texture {
                    path = "textures\\ErnPotionMaster\\circle-full.png"
                },
            },
            events = {},
        }
    }
}
