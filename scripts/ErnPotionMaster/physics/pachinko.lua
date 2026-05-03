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

---@alias ID number|string

---@class Ball
---@field id ID
---@field position Vector2
---@field velocity Vector2
---@field mass number
---@field elasticity number
---@field radius number

---@class Pin
---@field id ID
---@field position Vector2
---@field elasticity number
---@field radius number

---@class PachinkoPhysics
---@field balls table<string, Ball>
---@field pins table<string, Pin>
---@field boundsMin Vector2
---@field boundsMax Vector2
---@field gravity Vector2
---@field onPinHit fun(ballId: ID, pinId: ID)?
---@field onEdgeHit fun(ballId: ID, edge: ID)?
---@field _isStepping boolean
local PachinkoPhysics = {}
PachinkoPhysics.__index = PachinkoPhysics

-- Constructor
---@param boundsMin Vector2
---@param boundsMax Vector2
---@return PachinkoPhysics
function PachinkoPhysics.new(boundsMin, boundsMax)
    local self = setmetatable({}, PachinkoPhysics)

    self.balls = {}
    self.pins = {}

    self.boundsMin = boundsMin
    self.boundsMax = boundsMax

    self.gravity = util.vector2(0, -9.8)

    self.onPinHit = nil
    self.onEdgeHit = nil

    self._isStepping = false

    return self
end

-- Utility
local function reflect(v, normal)
    return v - normal * (2 * v:dot(normal))
end

local function combineElasticity(e1, e2)
    return math.min(e1, e2)
end

-- Public API

function PachinkoPhysics:addBall(id, position, velocity, mass, elasticity, radius)
    if self._isStepping then
        error("addBall cannot be called during advanceSimulation")
    end

    self.balls[id] = {
        id = id,
        position = position,
        velocity = velocity,
        mass = mass,
        elasticity = elasticity,
        radius = radius or 0.1,
    }
end

function PachinkoPhysics:addPin(id, position, elasticity, radius)
    if self._isStepping then
        error("addPin cannot be called during advanceSimulation")
    end

    self.pins[id] = {
        id = id,
        position = position,
        elasticity = elasticity,
        radius = radius or 0.1,
    }
end

-- Core simulation

function PachinkoPhysics:advanceSimulation(dt)
    self._isStepping = true

    -- Integrate motion
    for _, ball in pairs(self.balls) do
        ball.velocity = ball.velocity + self.gravity * dt
        ball.position = ball.position + ball.velocity * dt
    end

    -- Ball ↔ Edge collisions
    for _, ball in pairs(self.balls) do
        local pos = ball.position
        local vel = ball.velocity
        local r = ball.radius

        -- Left
        if pos.x - r < self.boundsMin.x then
            pos.x = self.boundsMin.x + r
            vel.x = -vel.x
            if self.onEdgeHit then
                self.onEdgeHit(ball.id, "left")
            end
        end

        -- Right
        if pos.x + r > self.boundsMax.x then
            pos.x = self.boundsMax.x - r
            vel.x = -vel.x
            if self.onEdgeHit then
                self.onEdgeHit(ball.id, "right")
            end
        end

        -- Bottom
        if pos.y - r < self.boundsMin.y then
            pos.y = self.boundsMin.y + r
            vel.y = -vel.y
            if self.onEdgeHit then
                self.onEdgeHit(ball.id, "bottom")
            end
        end

        -- Top
        if pos.y + r > self.boundsMax.y then
            pos.y = self.boundsMax.y - r
            vel.y = -vel.y
            if self.onEdgeHit then
                self.onEdgeHit(ball.id, "top")
            end
        end

        ball.position = pos
        ball.velocity = vel
    end

    -- Ball ↔ Pin collisions
    for _, ball in pairs(self.balls) do
        for _, pin in pairs(self.pins) do
            local delta = ball.position - pin.position
            local dist = delta:length()
            local minDist = ball.radius + pin.radius

            if dist < minDist and dist > 0 then
                local normal = delta / dist

                -- Push ball out
                ball.position = pin.position + normal * minDist

                -- Reflect velocity
                local e = combineElasticity(ball.elasticity, pin.elasticity)
                ball.velocity = reflect(ball.velocity, normal) * e

                if self.onPinHit then
                    self.onPinHit(ball.id, pin.id)
                end
            end
        end
    end

    -- Ball ↔ Ball collisions
    local ballList = {}
    for _, b in pairs(self.balls) do
        table.insert(ballList, b)
    end

    for i = 1, #ballList do
        for j = i + 1, #ballList do
            local a = ballList[i]
            local b = ballList[j]

            local delta = a.position - b.position
            local dist = delta:length()
            local minDist = a.radius + b.radius

            if dist < minDist and dist > 0 then
                local normal = delta / dist

                -- Separate
                local correction = normal * (minDist - dist) * 0.5
                a.position = a.position + correction
                b.position = b.position - correction

                -- Relative velocity
                local relVel = a.velocity - b.velocity
                local velAlongNormal = relVel:dot(normal)

                if velAlongNormal < 0 then
                    local e = combineElasticity(a.elasticity, b.elasticity)

                    local impulseMag = -(1 + e) * velAlongNormal
                    impulseMag = impulseMag / (1 / a.mass + 1 / b.mass)

                    local impulse = normal * impulseMag

                    a.velocity = a.velocity + impulse / a.mass
                    b.velocity = b.velocity - impulse / b.mass
                end
            end
        end
    end

    self._isStepping = false
end

return PachinkoPhysics
