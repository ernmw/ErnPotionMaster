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
-- TrajectoryRenderer draws a dotted arc preview using sampleTrajectory().
-- Each sample point is rendered as a small circle positioned at an absolute
-- screen coordinate derived from board-space.  Dots fade in opacity toward
-- the end of the arc to give a natural "vanishing" feel.
--
-- The renderer knows nothing about its parent element; the caller is
-- responsible for supplying the board's screen-space origin via setBoardOrigin
-- whenever the layout changes.
--
-- Usage:
--   local tr = TrajectoryRenderer.new(boardOrigin, boardSize)
--   tr:setTrajectory(points)   -- pass output of physics:sampleTrajectory()
--   tr:clearTrajectory()
--   tr:onFrame(dt)             -- call every frame from your onFrame handler

local ui                   = require("openmw.ui")
local util                 = require("openmw.util")
local const                = require("scripts.ErnPotionMaster.const")
local myui                 = require("scripts.ErnPotionMaster.pcp.myui")

-- Dot appearance
local DOT_SIZE             = util.vector2(6, 6)
local DOT_COLOR            = myui.interactiveTextColors.normal.over -- same accent as badge counts
local ALPHA_START          = 0.85                          -- opacity of the first dot
local ALPHA_END            = 0.15                          -- opacity of the last dot

local circleTex            = ui.texture { path = "textures\\ErnPotionMaster\\circle.png" }

---@class TrajectoryRenderer
---@field _boardOrigin Vector2      Screen-space top-left corner of the board canvas.
---@field _boardSize   Vector2      Pixel size of the board canvas.
---@field _points      Vector2[]    Current sample positions in board units.
---@field _dotElements any[]        Live UI elements, one per dot.
---@field _dirty       boolean
local TrajectoryRenderer   = {}
TrajectoryRenderer.__index = TrajectoryRenderer

-- Internal: build the layout table for one dot.
---@param absPos Vector2   Absolute screen position of the dot centre.
---@param alpha  number    Opacity [0..1].
---@return table
local function dotLayout(absPos, alpha)
    return {
        type = ui.TYPE.Image,
        props = {
            resource = circleTex,
            color    = DOT_COLOR,
            alpha    = alpha,
            size     = DOT_SIZE,
            -- Absolute position; anchor centres the dot on the sample point.
            position = absPos - DOT_SIZE * 0.5,
        },
    }
end

-- Internal: destroy all live dot elements.
---@param self TrajectoryRenderer
local function destroyDots(self)
    for _, el in ipairs(self._dotElements) do
        el:destroy()
    end
    self._dotElements = {}
end

-- Internal: rebuild dot elements from self._points.
---@param self TrajectoryRenderer
local function rebuildDots(self)
    destroyDots(self)

    local n = #self._points
    if n == 0 then return end

    for i, pt in ipairs(self._points) do
        -- Board units → absolute screen position.
        local absPos = self._boardOrigin + pt

        -- Linear fade: first dot is ALPHA_START, last is ALPHA_END.
        local t      = (n == 1) and 0 or ((i - 1) / (n - 1))
        local alpha  = ALPHA_START + t * (ALPHA_END - ALPHA_START)

        local el     = ui.create(dotLayout(absPos, alpha))
        el:update()

        table.insert(self._dotElements, el)
    end
end

--- Constructor.
---@param boardOrigin Vector2  Absolute screen position of the board's top-left corner.
---@param boardSize   Vector2  Pixel dimensions of the board canvas.
---@return TrajectoryRenderer
function TrajectoryRenderer.new(boardOrigin, boardSize)
    local self        = setmetatable({}, TrajectoryRenderer)
    self._boardOrigin = boardOrigin
    self._boardSize   = boardSize
    self._points      = {}
    self._dotElements = {}
    self._dirty       = false
    return self
end

--- Replace the displayed arc with a new set of sample points.
--- Pass the table returned by PachinkoPhysics:sampleTrajectory().
---@param points Vector2[]
function TrajectoryRenderer:setTrajectory(points)
    self._points = points or {}
    self._dirty  = true
end

--- Hide the arc (e.g. after a ball is launched).
function TrajectoryRenderer:clearTrajectory()
    self._points = {}
    self._dirty  = true
end

--- Call when the board moves on screen (e.g. window resize, layout change).
---@param boardOrigin Vector2
function TrajectoryRenderer:setBoardOrigin(boardOrigin)
    self._boardOrigin = boardOrigin
    self._dirty       = true
end

--- Call this every frame from your script's onFrame handler.
---@param dt number?
function TrajectoryRenderer:onFrame(dt)
    if self._dirty then
        rebuildDots(self)
        self._dirty = false
    end
end

return TrajectoryRenderer
