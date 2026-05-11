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
local myui         = require("scripts.ErnPotionMaster.pcp.myui")
local core         = require("openmw.core")
local localization = core.l10n(MOD_NAME)





return {
    ballTexture = ui.texture {
        path = "textures\\ErnPotionMaster\\circle-full.png"
    },
    bufferPinTexture = ui.texture {
        path = "textures\\ErnPotionMaster\\circle.png"
    },
    shadeTexture = ui.texture {
        path = "textures\\ErnPotionMaster\\circle-ball-shade-3.png"
    },
    toolTextures = {
        [const.ToolClass.CALCINATOR] = ui.texture {
            path = "textures\\ErnPotionMaster\\group.png"
        },
        [const.ToolClass.ALEMBIC] = ui.texture {
            path = "textures\\ErnPotionMaster\\plus.png"
        },
        [const.ToolClass.RETORT] = ui.texture {
            path = "textures\\ErnPotionMaster\\triangle.png"
        }
    }
}
