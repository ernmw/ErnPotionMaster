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

local MOD_NAME     = require("scripts.ErnPotionMaster.ns")
local const        = require("scripts.ErnPotionMaster.const")
local ui           = require("openmw.ui")
local util         = require("openmw.util")
local pself        = require("openmw.self")
local core         = require("openmw.core")
local types        = require("openmw.types")
local placepins    = require("scripts.ErnPotionMaster.placepins")
local settings     = require("scripts.ErnPotionMaster.settings.settings")
local physics      = require("scripts.ErnPotionMaster.physics.pachinko")
local interfaces   = require('openmw.interfaces')
local shuffle      = require("scripts.ErnPotionMaster.shuffle")
local aux_util     = require('openmw_aux.util')
local renderBoard  = require("scripts.ErnPotionMaster.render.board")
local colorutil    = require("scripts.ErnPotionMaster.colorutil")
local myui         = require("scripts.ErnPotionMaster.pcp.myui")
local templates    = require("scripts.ErnPotionMaster.render.templates")
local localization = core.l10n(MOD_NAME)

---@class IngredientRecord any This is a openmw.core#IngredientRecord
---@field name string
---@field icon string
---@field id string

---@class IngredientInfo
---@field record IngredientRecord
---@field count number The running score for this effect. Persists across shots.

local function deepCopy(orig)
    local orig_type = type(orig)
    local copy
    if orig_type == 'table' then
        copy = {}
        for orig_key, orig_value in next, orig, nil do
            copy[deepCopy(orig_key)] = deepCopy(orig_value)
        end
        setmetatable(copy, deepCopy(getmetatable(orig)))
    else
        copy = orig
    end
    return copy
end

local ingredientText = localization("ingredient")



---@class IngredientInfoContainer
---@field ingredients IngredientInfo[]
---@field element any a UI element
---@field _dirty boolean
---@field setIngredients fun(self: IngredientInfoContainer, ingredients : IngredientInfo[]))
---@field ingredientLayout fun (ingredientInfo: IngredientInfo, props: table?)

local IngredientInfoContainer   = {}
IngredientInfoContainer.__index = IngredientInfoContainer

---Layout for one ingredient.
---@param ingredientInfo IngredientInfo
---@param props any
---@return table
function IngredientInfoContainer.ingredientLayout(ingredientInfo, props)
    local iconPath = (ingredientInfo.record and ingredientInfo.record.icon)
        or "textures\\ErnPotionMaster\\cross.png"
    local displayName = (ingredientInfo.record and ingredientInfo.record.name)
        or ingredientText

    -- Build the icon's child content conditionally
    local iconChildren = {}
    if ingredientInfo.count and ingredientInfo.count > 0 then
        iconChildren[#iconChildren + 1] = {
            type = ui.TYPE.Text,
            props = {
                text             = tostring(ingredientInfo.count),
                textColor        = myui.interactiveTextColors.normal.over,
                textShadow       = true,
                textAlignV       = ui.ALIGNMENT.End,
                textAlignH       = ui.ALIGNMENT.End,
                relativeSize     = util.vector2(1, 1),
                relativePosition = util.vector2(1, 1),
                anchor           = util.vector2(1, 1),
                textSize         = 14,
            },
        }
    end

    return {
        props = deepCopy(props or {}),
        external = {
            scale = 1,
        },
        content = ui.content {
            {
                type = ui.TYPE.Flex,
                props = {
                    arrange      = ui.ALIGNMENT.Center,
                    horizontal   = true,
                    autoSize     = false,
                    relativeSize = util.vector2(1, 1),
                },
                content = ui.content {
                    -- Icon with badge count overlaid
                    {
                        type = ui.TYPE.Widget,
                        props = {
                            size = const.IngredientSize,
                        },
                        content = ui.content {
                            {
                                type = ui.TYPE.Image,
                                props = {
                                    resource = ui.texture { path = iconPath },
                                    size     = const.IngredientSize,
                                },
                            },
                            table.unpack(iconChildren),
                        },
                    },
                    myui.padWidget(5, 5),
                    -- Ingredient name
                    {
                        type = ui.TYPE.Text,
                        props = {
                            text       = displayName,
                            textColor  = myui.interactiveTextColors.normal.default,
                            textAlignV = ui.ALIGNMENT.Center,
                            textSize   = 18,
                        },
                    },
                },
            },
        },
    }
end

function IngredientInfoContainer:_layout()
    local contents = {}

    for _, es in ipairs(self.ingredients) do
        table.insert(contents, IngredientInfoContainer.ingredientLayout(
            es,
            {
                size = util.vector2(const.IngredientInfoPaneSize.x, 32)
            }
        ))
    end

    return {
        type = ui.TYPE.Flex,
        name = "IngredientInfosColumn",
        props = {
            horizontal = false,
            align = ui.ALIGNMENT.Start,
            arrange = ui.ALIGNMENT.Start,
            size = const.IngredientInfoPaneSize,
            --autoSize = false,
        },
        content = ui.content(contents)
    }
end

---@param initial IngredientInfo[]
---@return IngredientInfoContainer
function IngredientInfoContainer.new(initial)
    local self = setmetatable({}, IngredientInfoContainer)

    self.ingredients = initial

    self._dirty = false
    local layout = self:_layout()
    settings.debugPrint(aux_util.deepToString(layout, 3))
    self.element = ui.create(layout)

    return self
end

---comment
---@param ingredients IngredientInfo[]
function IngredientInfoContainer:setIngredients(ingredients)
    self._dirty = true
    self.ingredients = ingredients
end

---@param dt number?
function IngredientInfoContainer:onFrame(dt)
    if self._dirty then
        self.element.layout = self:_layout()
        self.element:update()
        self._dirty = false
    end
end

return IngredientInfoContainer
