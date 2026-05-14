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
local ui                      = require("openmw.ui")
local util                    = require("openmw.util")
local templates               = require("scripts.ErnPotionMaster.render.templates")
local myui                    = require("scripts.ErnPotionMaster.pcp.myui")
local core                    = require("openmw.core")
local const                   = require("scripts.ErnPotionMaster.const")
local sprite                  = require("scripts.ErnPotionMaster.render.sprite")
local settings                = require("scripts.ErnPotionMaster.settings.settings")
local aux_util                = require('openmw_aux.util')
local MOD_NAME                = require("scripts.ErnPotionMaster.ns")
local localization            = core.l10n(MOD_NAME)

---@class PotionRenderer
---@field _potionRecord table
---@field _props table
---@field _mewpLayouts table[]
---@field _sparklesAnim AnimatedImage
---@field _title string
---@field GetLayout fun(self: PotionRenderer, dt : number?): table

---@class PotionRendererMethods
local PotionRendererMethods   = {}
PotionRendererMethods.__index = PotionRendererMethods

local function deepCopy(orig)
    local orig_type = type(orig)
    local copy
    if orig_type == 'table' then
        copy = {}
        for orig_key, orig_value in next, orig, nil do
            copy[deepCopy(orig_key)] = deepCopy(orig_value)
        end
        setmetatable(copy, deepCopy(getmetatable(orig)))
    else -- number, string, boolean, etc
        copy = orig
    end
    return copy
end

local function NewPotionRenderer(potionRecord, props, count)
    local effectLayouts = {}
    for _, mewp in pairs(potionRecord.effects) do
        table.insert(effectLayouts, templates.effectLayout(mewp))
        table.insert(effectLayouts, templates.effectNumbersLayout(mewp))
    end

    -- this is an ESM3_EffectParams
    --
    local color    = const.MagickColors[potionRecord.effects[1].effect.school].default
        or const.MagickColors.unknown.default
    local glowAnim = sprite.NewAnimatedImage("textures\\ErnPotionMaster\\effect_36.dds",
        util.vector2(512, 512),
        16, 10, nil, nil, {
            anchor = util.vector2(0.5, 0.5),
            relativePosition = util.vector2(0.5, 0.5),
            relativeSize = util.vector2(1, 1),
            color = color,
        })

    count          = count or 1
    local name     = potionRecord.name
    if count > 1 then
        name = localization("itemQuantity", {
            name = name,
            quantity = tostring(math.ceil(count))
        })
    end

    local new = {
        _potionRecord = potionRecord,
        _mewpLayouts  = effectLayouts,
        _sparklesAnim = glowAnim,
        _props        = deepCopy(props or {}),
        _title        = name
    }
    setmetatable(new, PotionRendererMethods)

    return new
end

---@param self PotionRenderer
---@param dt number?
---@return table? nil if loop expired
function PotionRendererMethods:GetLayout(dt)
    return {
        type = ui.TYPE.Flex,
        props = self._props,
        content = ui.content {
            {
                type = ui.TYPE.Widget,
                props = {
                    size = const.PotionReviewIconSize,
                },
                content = ui.content {

                    self._sparklesAnim:GetLayout(dt),
                    {
                        type = ui.TYPE.Image,
                        props = {
                            resource = ui.texture {
                                path = self._potionRecord.icon,
                            },
                            color = util.color.hex("000000"),
                            anchor = util.vector2(0.5, 0.5),
                            relativePosition = util.vector2(0.5, 0.5),
                            relativeSize = util.vector2(1, 1)
                        },
                    },
                    {
                        type = ui.TYPE.Image,
                        props = {
                            resource = ui.texture {
                                path = self._potionRecord.icon
                            },
                            anchor = util.vector2(0.5, 0.5),
                            relativePosition = util.vector2(0.5, 0.5),
                            relativeSize = util.vector2(0.8, 0.8)
                        },
                    },
                }
            },

            myui.padWidget(const.Padding, const.Padding),
            {
                type = ui.TYPE.Text,
                props = {
                    -- itemQuantity: "{name} x{quantity}"
                    text = self._title,
                    textColor = myui.interactiveTextColors.normal.default,
                    textAlignV = ui.ALIGNMENT.Center,
                    textSize = 18,
                },
            },


            myui.padWidget(const.Padding, const.Padding),
            unpack(self._mewpLayouts),
        }
    }
end

return {
    NewPotionRenderer = NewPotionRenderer
}
