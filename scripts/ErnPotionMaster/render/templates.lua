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

local function pinWidget()
    return {
        type = ui.TYPE.Widget,
        props = {
            size = const.PinSize,
        },
        content = {
            ui.content(
                {
                    template = interfaces.MWUI.templates.textNormal,
                    props = {
                        text = "pin",
                        anchor = util.vector2(0.5, 0.5)
                    }
                }, {
                    type = ui.TYPE.Image,
                    props = {
                        relativeSize = util.vector2(1, 1),
                        resource = ui.texture {
                            path = "textures\\ErnPotionMaster\\circle.png"
                        },
                    },
                    events = {},
                })
        }
    }
end

local function ballWidget()
    return {
        type = ui.TYPE.Widget,
        props = {
            size = const.BallSize,
        },
        content = {
            ui.content({
                type = ui.TYPE.Image,
                props = {
                    relativeSize = util.vector2(1, 1),
                    resource = ui.texture {
                        path = "textures\\ErnPotionMaster\\circle-full.png"
                    },
                },
                events = {},
            })
        }
    }
end

return {
    pinWidget = pinWidget,
    ballWidget = ballWidget,
    ballTexture = ui.texture {
        path = "textures\\ErnPotionMaster\\circle-full.png"
    },
    bufferPinTexture = ui.texture {
        path = "textures\\ErnPotionMaster\\circle.png"
    },
    shadeTexture = ui.texture {
        path = "textures\\ErnPotionMaster\\circle-ball-shade-3.png"
    },
}
