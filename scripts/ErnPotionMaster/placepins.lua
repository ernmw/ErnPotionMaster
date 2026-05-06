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
local settings = require("scripts.ErnPotionMaster.settings.settings")

---Shuffle a table in place using Fisher-Yates.
local function shuffle(t)
    for i = #t, 2, -1 do
        local j = math.random(i)
        t[i], t[j] = t[j], t[i]
    end
end

---@param boardSize Vector2  -- (width, height)
---@param radius number      -- pin radius (pins must not overlap)
---@param count number       -- target number of pins
---@param maxRetries? number -- jitter retry attempts per cell before relaxing (default 10)
---@return Vector2[]
local function PlacePins(boardSize, radius, count, maxRetries)
    maxRetries = maxRetries or 10
    local minDist = radius * 2

    -- Usable area inset by radius so pins stay fully inside the board.
    local usableW = boardSize.x - 2 * radius
    local usableH = boardSize.y - 2 * radius

    if usableW <= 0 or usableH <= 0 then
        print("[PlacePins] Board too small for the given radius.")
        return {}
    end

    -- Divide the usable area into a cols×rows grid so that every cell
    -- gets exactly one pin.  We pick the grid dimensions that keep the
    -- cells as square as possible.
    --
    -- We want  cols * rows >= count  with  cols/rows ≈ usableW/usableH
    -- => rows = sqrt(count * usableH / usableW),  cols = count / rows
    local rows = math.max(1, math.floor(math.sqrt(count * usableH / usableW) + 0.5))
    local cols = math.ceil(count / rows)
    -- Re-adjust rows so cols*rows is just enough.
    rows = math.ceil(count / cols)

    local cellW = usableW / cols
    local cellH = usableH / rows

    -- All (col, row) cell indices in a random order so we pick a diverse
    -- subset when count < cols*rows.
    local cells = {}
    for r = 0, rows - 1 do
        for c = 0, cols - 1 do
            cells[#cells + 1] = { c = c, r = r }
        end
    end
    shuffle(cells)

    -- Fast neighbour lookup: place accepted pins into a spatial grid.
    local cellSize = minDist / math.sqrt(2)
    local gridW = math.ceil(boardSize.x / cellSize)
    local gridH = math.ceil(boardSize.y / cellSize)
    local spatialGrid = {}

    local function sgKey(gx, gy) return gx * 10000 + gy end

    local function isFarEnough(p)
        local gx = math.floor(p.x / cellSize)
        local gy = math.floor(p.y / cellSize)
        for nx = math.max(0, gx - 2), math.min(gridW - 1, gx + 2) do
            for ny = math.max(0, gy - 2), math.min(gridH - 1, gy + 2) do
                local nb = spatialGrid[sgKey(nx, ny)]
                if nb then
                    local dx = p.x - nb.x
                    local dy = p.y - nb.y
                    if (dx * dx + dy * dy) < (minDist * minDist) then
                        return false
                    end
                end
            end
        end
        return true
    end

    local function addToGrid(p)
        local gx = math.floor(p.x / cellSize)
        local gy = math.floor(p.y / cellSize)
        spatialGrid[sgKey(gx, gy)] = p
    end

    ---@type Vector2[]
    local samples = {}

    for i = 1, math.min(count, #cells) do
        local cell = cells[i]
        -- Cell origin in usable-area coordinates, offset to board space.
        local ox = radius + cell.c * cellW
        local oy = radius + cell.r * cellH

        local placed = false

        -- Try random jitter positions within the cell.
        for _ = 1, maxRetries do
            local px = ox + math.random() * cellW
            local py = oy + math.random() * cellH
            -- Clamp so the pin stays inside the board.
            px = math.max(radius, math.min(boardSize.x - radius, px))
            py = math.max(radius, math.min(boardSize.y - radius, py))
            local p = util.vector2(px, py)
            if isFarEnough(p) then
                samples[#samples + 1] = p
                addToGrid(p)
                placed = true
                break
            end
        end

        -- Fallback: place at the cell centre if every jitter attempt collided.
        if not placed then
            local px = math.max(radius, math.min(boardSize.x - radius,
                ox + cellW * 0.5))
            local py = math.max(radius, math.min(boardSize.y - radius,
                oy + cellH * 0.5))
            local p = util.vector2(px, py)
            if isFarEnough(p) then
                samples[#samples + 1] = p
                addToGrid(p)
            end
            -- If even the centre collides the cell is genuinely saturated;
            -- we simply skip it so we never produce overlapping pins.
        end
    end

    if #samples < count then
        settings.debugPrint(string.format(
            "[PlacePins] Only placed %d/%d pins (space saturated or radius too large)",
            #samples, count
        ))
    end

    return samples
end

return PlacePins
