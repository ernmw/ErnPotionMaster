local util = require("openmw.util")

---@alias ID number

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
---@field enabled boolean

---@class PachinkoPhysics
---@field balls table<number, Ball>
---@field pins table<number, Pin>
---@field boardSize Vector2
---@field gravity Vector2
---@field onPinHit fun(ballId: ID, pinId: ID)?
---@field onEdgeHit fun(ballId: ID, edge: string)?
---@field _isStepping boolean
local PachinkoPhysics = {}
PachinkoPhysics.__index = PachinkoPhysics

-- Constructor
---@param boardSize Vector2
---@return PachinkoPhysics
function PachinkoPhysics.new(boardSize)
    local self = setmetatable({}, PachinkoPhysics)

    self.balls = {}
    self.pins = {}

    self.boardSize = boardSize

    -- +Y is downward in UI space
    --self.gravity = util.vector2(0, 9.8)
    self.gravity = util.vector2(0, 98)

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
        enabled = true,
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
        local max = self.boardSize

        -- Left (x = 0)
        if pos.x - r < 0 then
            pos = util.vector2(r, pos.y)
            vel = util.vector2(-vel.x * ball.elasticity, vel.y)
            if self.onEdgeHit then
                self.onEdgeHit(ball.id, "left")
            end
        end

        -- Right (x = width)
        if pos.x + r > max.x then
            pos = util.vector2(max.x - r, pos.y)
            vel = util.vector2(-vel.x * ball.elasticity, vel.y)
            if self.onEdgeHit then
                self.onEdgeHit(ball.id, "right")
            end
        end

        -- Top (y = 0)
        if pos.y - r < 0 then
            pos = util.vector2(pos.x, r)
            vel = util.vector2(vel.x, -vel.y * ball.elasticity)
            if self.onEdgeHit then
                self.onEdgeHit(ball.id, "top")
            end
        end

        -- Bottom (y = height)
        if pos.y + r > max.y then
            pos = util.vector2(pos.x, max.y - r)
            vel = util.vector2(vel.x, -vel.y * ball.elasticity)
            if self.onEdgeHit then
                self.onEdgeHit(ball.id, "bottom")
            end
        end

        ball.position = pos
        ball.velocity = vel
    end

    -- Ball ↔ Pin collisions
    for _, ball in pairs(self.balls) do
        for _, pin in pairs(self.pins) do
            if pin.enabled then
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
