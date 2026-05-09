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
local util = require('openmw.util')

local function lerpColor(a, b, t)
    return util.color.rgba(
        a.r + (b.r - a.r) * t,
        a.g + (b.g - a.g) * t,
        a.b + (b.b - a.b) * t,
        a.a + (b.a - a.a) * t
    )
end

local function rgbToHsv(c)
    local r = c.r
    local g = c.g
    local b = c.b

    local max = math.max(r, g, b)
    local min = math.min(r, g, b)
    local delta = max - min

    local h = 0
    local s = 0
    local v = max

    if delta > 0 then
        s = delta / max

        if max == r then
            h = ((g - b) / delta) % 6
        elseif max == g then
            h = ((b - r) / delta) + 2
        else
            h = ((r - g) / delta) + 4
        end

        h = h / 6
    end

    return h, s, v
end

local function hsvToRgb(h, s, v)
    local r, g, bl -- rename b → bl
    local i = math.floor(h * 6)
    local f = h * 6 - i
    local p = v * (1 - s)
    local q = v * (1 - f * s)
    local tt = v * (1 - (1 - f) * s) -- rename t → tt
    i = i % 6
    if i == 0 then
        r, g, bl = v, tt, p
    elseif i == 1 then
        r, g, bl = q, v, p
    elseif i == 2 then
        r, g, bl = p, v, tt
    elseif i == 3 then
        r, g, bl = p, q, v
    elseif i == 4 then
        r, g, bl = tt, p, v
    else
        r, g, bl = v, p, q
    end
    return r, g, bl
end

local function lerpColorHSV(a, b, t)
    local function lerp(x, y, s)
        return x + (y - x) * s
    end

    local h1, s1, v1 = rgbToHsv(a)
    local h2, s2, v2 = rgbToHsv(b)

    -- Shortest-path hue interpolation
    local dh = h2 - h1

    if dh > 0.5 then
        dh = dh - 1
    elseif dh < -0.5 then
        dh = dh + 1
    end

    local h = (h1 + dh * t) % 1
    local s = lerp(s1, s2, t)
    local v = lerp(v1, v2, t)

    local r1, g1, b1 = hsvToRgb(h, s, v)

    return util.color.rgba(
        r1,
        g1,
        b1,
        lerp(a.a, b.a, t)
    )
end


return {
    lerpColor = lerpColor,
    lerpColorHSV = lerpColorHSV
}
