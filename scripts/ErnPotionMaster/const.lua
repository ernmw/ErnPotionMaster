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
local util = require("openmw.util")
local core = require("openmw.core")

local magickColors = {
    alteration = util.color.hex("9A4CB3"),
    destruction = util.color.hex("C64F46"),
    mysticism = util.color.hex("836986"),
    restoration = util.color.hex("6372A1"),
    conjuration = util.color.hex("7F7534"),
    illusion = util.color.hex("658665"),
}


return {
    BoardSize = util.vector2(512, 768),
    PinSize = util.vector2(32, 32),
    PinRadius = 15,
    BallSize = util.vector2(32, 32),
    BallRadius = 15,
    EffectScorePaneSize = util.vector2(128, 768),
    MagickColors = magickColors,
    PopFadeoutSeconds = 2,
    HitFlashColor = util.color.hex("FFFFFF"),
    PinsPerEffect = 4,
}
