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

---@param boardSize Vector2  -- (width, height)
---@param radius number           -- pin radius
---@param count number            -- target number of pins
---@param k? number               -- attempts per active point (default 30)
---@return Vector2[]
local function PlacePins(boardSize, radius, count, k)
    k = k or 30

    local minDist = radius * 2
    local cellSize = minDist / math.sqrt(2)

    local gridWidth = math.ceil(boardSize.x / cellSize)
    local gridHeight = math.ceil(boardSize.y / cellSize)

    ---@type (Vector2|nil)[][]
    local grid = {}
    for x = 1, gridWidth do
        grid[x] = {}
    end

    local function gridCoords(p)
        return math.floor(p.x / cellSize) + 1,
            math.floor(p.y / cellSize) + 1
    end

    local function inBounds(p)
        return p.x >= radius and p.y >= radius
            and p.x <= (boardSize.x - radius)
            and p.y <= (boardSize.y - radius)
    end

    local function isFarEnough(p)
        local gx, gy = gridCoords(p)

        for x = math.max(1, gx - 2), math.min(gridWidth, gx + 2) do
            for y = math.max(1, gy - 2), math.min(gridHeight, gy + 2) do
                local neighbor = grid[x][y]
                if neighbor then
                    local dx = p.x - neighbor.x
                    local dy = p.y - neighbor.y
                    if (dx * dx + dy * dy) < (minDist * minDist) then
                        return false
                    end
                end
            end
        end

        return true
    end

    local function randomPointAround(p)
        local angle = math.random() * (2 * math.pi)
        local dist = minDist * (1 + math.random())
        return util.vector2(
            p.x + math.cos(angle) * dist,
            p.y + math.sin(angle) * dist
        )
    end

    ---@type Vector2[]
    local samples = {}
    ---@type Vector2[]
    local active = {}

    -- initial point
    local first = util.vector2(
        radius + math.random() * (boardSize.x - 2 * radius),
        radius + math.random() * (boardSize.y - 2 * radius)
    )

    table.insert(samples, first)
    table.insert(active, first)

    local gx, gy = gridCoords(first)
    grid[gx][gy] = first

    while #active > 0 and #samples < count do
        local idx = math.random(#active)
        local point = active[idx]

        local found = false

        for _ = 1, k do
            local candidate = randomPointAround(point)

            if inBounds(candidate) and isFarEnough(candidate) then
                table.insert(samples, candidate)
                table.insert(active, candidate)

                local cgx, cgy = gridCoords(candidate)
                grid[cgx][cgy] = candidate

                found = true
                break
            end
        end

        if not found then
            -- remove from active list
            active[idx] = active[#active]
            active[#active] = nil
        end
    end

    if #samples < count then
        print(string.format(
            "[GeneratePins] Only placed %d/%d pins (space saturated)",
            #samples, count
        ))
    end

    return samples
end

return PlacePins
