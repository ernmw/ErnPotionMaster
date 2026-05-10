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
-- All dots live inside a single widget element (self.element) that the caller
-- can attach wherever it likes.  The widget is sized to the board canvas and
-- uses relative positioning internally, so dots stay aligned without the
-- renderer needing to know its screen-space origin.
--
-- Usage:
--   local tr = TrajectoryRenderer.new(boardSize)
--   -- embed tr.element in your layout like any other element
--   tr:setTrajectory(points)   -- pass output of physics:sampleTrajectory()
--   tr:clearTrajectory()
--   tr:onFrame(dt)             -- call every frame from your onFrame handler

local ui                   = require("openmw.ui")
local util                 = require("openmw.util")
local myui                 = require("scripts.ErnPotionMaster.pcp.myui")

-- Dot appearance
local DOT_SIZE             = util.vector2(6, 6)
local DOT_COLOR            = myui.interactiveTextColors.normal.over
local ALPHA_START          = 0.85
local ALPHA_END            = 0.15

local circleTex            = ui.texture { path = "textures\\ErnPotionMaster\\circle-full.png" }

---@class TrajectoryRenderer
---@field element    any       The single widget element containing all dots. Embed this in your layout.
---@field _boardSize Vector2   Pixel size of the board canvas.
---@field _points    Vector2[] Current sample positions in board units.
---@field _dirty     boolean
local TrajectoryRenderer   = {}
TrajectoryRenderer.__index = TrajectoryRenderer

-- Internal: build a single dot's layout, positioned relative to the container.
---@param relPos Vector2  Position in [0..1] relative to board size.
---@param alpha  number   Opacity [0..1].
---@return table
local function dotLayout(relPos, alpha)
    return {
        type = ui.TYPE.Image,
        props = {
            resource         = circleTex,
            color            = DOT_COLOR,
            alpha            = alpha,
            size             = DOT_SIZE,
            relativePosition = relPos,
            anchor           = util.vector2(0.5, 0.5),
        },
    }
end

-- Internal: rebuild the container layout from self._points.
---@param self TrajectoryRenderer
---@return table
local function containerLayout(self)
    local dots = {}
    local n    = #self._points

    for i, pt in ipairs(self._points) do
        local relX  = pt.x / self._boardSize.x
        local relY  = pt.y / self._boardSize.y

        local t     = (n == 1) and 0 or ((i - 1) / (n - 1))
        local alpha = ALPHA_START + t * (ALPHA_END - ALPHA_START)

        table.insert(dots, dotLayout(util.vector2(relX, relY), alpha))
    end

    return {
        type = ui.TYPE.Widget,
        props = {
            size = self._boardSize,
        },
        content = ui.content(dots),
    }
end

--- Constructor.
---@param boardSize Vector2  Pixel dimensions of the board canvas.
---@return TrajectoryRenderer
function TrajectoryRenderer.new(boardSize)
    local self      = setmetatable({}, TrajectoryRenderer)
    self._boardSize = boardSize
    self._points    = {}
    self._dirty     = false
    self.element    = ui.create(containerLayout(self))
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

--- Update when the board canvas is resized.
---@param boardSize Vector2
function TrajectoryRenderer:setBoardSize(boardSize)
    self._boardSize = boardSize
    self._dirty     = true
end

--- Call this every frame from your script's onFrame handler.
---@param dt number?
function TrajectoryRenderer:onFrame(dt)
    if self._dirty then
        self.element.layout = containerLayout(self)
        self.element:update()
        self._dirty = false
    end
end

return TrajectoryRenderer
