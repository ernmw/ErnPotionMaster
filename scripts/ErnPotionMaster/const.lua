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
local util      = require("openmw.util")
local core      = require("openmw.core")
local colorutil = require("scripts.ErnPotionMaster.colorutil")
local ui        = require("openmw.ui")
local settings  = require("scripts.ErnPotionMaster.settings.settings")

--- find scale
---@param layerName string?
---@return number
local function findScale(layerName)
    layerName = layerName or "Windows"
    ---@type Vector2
    local layerSize
    for i, layer in ipairs(ui.layers) do
        if layer.name == layerName then
            layerSize = layer.size
        end
    end
    if not layerSize then
        error("layer " .. tostring(layerName) .. " not found")
    end
    ---@type Vector2
    local screenSize = ui.screenSize()
    local scaleVec = layerSize:ediv(screenSize)
    -- these should be the same
    return scaleVec.x
end
local windowsScale = findScale()
--- scaling factor = 1.15
--- windowsScale: (0.869270861148834228515625, 0.869444429874420166015625)
-- minimum res is 720x480 pixels
--print("windowsScale: " .. tostring(windowsScale))

---@generic T: Vector2|number
---@param size T
---@return T
local function scaleUI(size)
    if settings.ui.enableCustomUIScale then
        return size * windowsScale * util.clamp(settings.ui.customUIScale, 0.25, 4)
    else
        return size
    end
end

local magickColorsDefault = {
    alteration = util.color.hex("9A4CB3"),
    destruction = util.color.hex("C64F46"),
    mysticism = util.color.hex("836986"),
    restoration = util.color.hex("6372A1"),
    conjuration = util.color.hex("7F7534"),
    illusion = util.color.hex("658665"),
}

local magickColors        = {}
for id, defaultColor in pairs(magickColorsDefault) do
    magickColors[id] = {
        default = defaultColor,
        highlight = colorutil.lerpColor(defaultColor, util.color.hex("FFFFFF"), 0.5)
    }
end

return {
    BoardSize = scaleUI(util.vector2(512, 768)),
    PinSize = scaleUI(util.vector2(32, 32)),
    PinRadius = scaleUI(15),
    BallSize = scaleUI(util.vector2(32, 32)),
    BallRadius = scaleUI(15),
    Padding = scaleUI(4),
    EffectScorePaneSize = scaleUI(util.vector2(256, 576)),
    IngredientInfoPaneSize = scaleUI(util.vector2(256, 192)),
    MagickColors = magickColors,
    PopFadeoutSeconds = 2,
    HitFlashColor = util.color.hex("FFFFFF"),
    PinsPerEffect = 4,
    IngredientSize = scaleUI(util.vector2(32, 32)),
}
