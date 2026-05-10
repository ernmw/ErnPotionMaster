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
local ui    = require("openmw.ui")
local util  = require("openmw.util")
local const = require("scripts.ErnPotionMaster.const")
local myui  = require("scripts.ErnPotionMaster.pcp.myui")


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

local function ingredientLayout(ingredientRecord, count, props)
    return {
        props = deepCopy(props or {}),
        content = ui.content {
            {
                type = ui.TYPE.Flex,
                props = {
                    arrange = ui.ALIGNMENT.Center,
                    horizontal = true,
                    autoSize = false,
                    relativeSize = util.vector2(1, 1),
                },
                content = ui.content {
                    {
                        type = ui.TYPE.Image,
                        path = ingredientRecord and ingredientRecord.icon or "textures\\ErnPotionMaster\\cross.png",
                        props = {
                            size = util.vector2(16, 16),
                        },
                        content = ui.content {
                            (count > 0) and {
                                --template = interfaces.MWUI.templates.textHeader,
                                type = ui.TYPE.Text,
                                props = {
                                    text = count,
                                    textColor = const.HitFlashColor,
                                    textShadow = true,
                                    textAlignV = ui.ALIGNMENT.Center,
                                    textAlignH = ui.ALIGNMENT.Center,
                                    relativePosition = util.vector2(1, 1),
                                    anchor = util.vector2(1, 1),
                                    textSize = 16
                                },
                            } or {}
                        }
                    },
                    {
                        --template = interfaces.MWUI.templates.textHeader,
                        type = ui.TYPE.Text,
                        props = {
                            text = ingredientRecord and ingredientRecord.name or "Select Ingredient",
                            textColor = myui.interactiveTextColors.normal.default,
                            textAlignV = ui.ALIGNMENT.Center,
                            textSize = 18,
                            --anchor = util.vector2(0.5, 0),
                        },
                    },
                }
            }
        }
    }
end

return {
    ingredientLayout = ingredientLayout
}
