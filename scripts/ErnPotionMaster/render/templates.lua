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
local MOD_NAME       = require("scripts.ErnPotionMaster.ns")
local const          = require("scripts.ErnPotionMaster.const")
local ui             = require("openmw.ui")
local util           = require("openmw.util")
local dynamic        = require("scripts.ErnPotionMaster.render.dynamic")
local interfaces     = require('openmw.interfaces')
local myui           = require("scripts.ErnPotionMaster.pcp.myui")
local core           = require("openmw.core")
local localization   = core.l10n(MOD_NAME)

local effectIconSize = util.vector2(16, 16)

local attributes     = core.stats.Attribute.records
local skills         = core.stats.Skill.records

---comment
---@param mewp MagicEffectWithParams
---@param textColor Color?
---@return table
local function effectLayout(mewp, textColor)
    local text
    if mewp.affectedAttribute then
        text = localization("effectWithParam", {
            effectName = mewp.effect.name,
            effectParam = attributes[mewp.affectedAttribute].name
        })
    elseif mewp.affectedSkill then
        text = localization("effectWithParam", {
            effectName = mewp.effect.name,
            effectParam = skills[mewp.affectedSkill].name
        })
    else
        text = mewp.effect.name
    end

    return {
        type = ui.TYPE.Flex,
        props = {
            arrange = ui.ALIGNMENT.Center,
            align = ui.ALIGNMENT.Center,
            horizontal = true,
            autoSize = true,
            --relativeSize = util.vector2(1, 0.2),
            --size = util.vector2(0, const.EffectScorePaneSize.y)
            --size = util.vector2(const.EffectScorePaneSize.x, 64),
            -- myui.padWidget(const.EffectScorePaneSize.x, 0)
        },
        content = ui.content {
            {
                type = ui.TYPE.Image,
                props = {
                    resource = ui.texture {
                        path = mewp.effect.icon
                    },
                    size = effectIconSize
                },
            },
            myui.padWidget(const.Padding, const.Padding),
            {
                --template = interfaces.MWUI.templates.textHeader,
                type = ui.TYPE.Text,
                props = {
                    text = text,
                    textColor = textColor or myui.interactiveTextColors.normal.default,
                    textAlignV = ui.ALIGNMENT.Center,
                    textSize = 18,
                    --anchor = util.vector2(0.5, 0),
                },
            },
        },
    }
end


return {
    effectLayout = effectLayout,
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
