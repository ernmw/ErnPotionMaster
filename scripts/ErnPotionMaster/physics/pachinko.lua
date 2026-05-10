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

---@class PachinkoConfig
---@field gravityScale number      Multiplies board-relative gravity. >1 = heavier/snappier, <1 = floatier. Default 1.0.
---@field gravityDirection Vector2 Override gravity vector entirely (skips gravityScale). Default nil.
---@field linearDrag number        Proportional velocity loss per second [0..1]. 0 = none, 0.05 = light, 0.3 = heavy. Default 0.
---@field maxSpeed number          Hard cap on ball speed each step. nil = uncapped. Default nil.
---@field substeps integer         Sub-steps per advanceSimulation call. Fixes tunnelling on fast balls. Default 1.

---@class PachinkoPhysics
---@field balls table<number, Ball>
---@field pins table<number, Pin>
---@field boardSize Vector2
---@field gravity Vector2
---@field linearDrag number
---@field maxSpeed number|nil
---@field substeps integer
---@field onPinHit fun(ballId: ID, pinId: ID)?
---@field onEdgeHit fun(ballId: ID, edge: string)?
---@field _isStepping boolean
local PachinkoPhysics = {}
PachinkoPhysics.__index = PachinkoPhysics

-- Constructor
---@param boardSize Vector2
---@param config PachinkoConfig|nil
---@return PachinkoPhysics
function PachinkoPhysics.new(boardSize, config)
    local self = setmetatable({}, PachinkoPhysics)

    self.balls = {}
    self.pins = {}
    self.boardSize = boardSize

    local cfg = config or {}

    -- Base gravity is proportional to board height so the "feel" is the same
    -- regardless of board scale without any manual tuning.
    -- A ball starting at the top reaches the bottom in ~sqrt(2/0.8) ≈ 1.6 s
    -- at gravityScale 1.  Increase gravityScale to make things snappier.
    if cfg.gravityDirection then
        self.gravity = cfg.gravityDirection
    else
        local scale = cfg.gravityScale ~= nil and cfg.gravityScale or 1.0
        self.gravity = util.vector2(0, boardSize.y * 0.8 * scale)
    end

    -- Drag: applied as  velocity *= (1 - drag)^dt  each sub-step.
    -- Keeps the physics frame-rate independent.
    self.linearDrag  = cfg.linearDrag ~= nil and cfg.linearDrag or 0.0

    -- Optional hard speed cap (in board-units / second).
    self.maxSpeed    = cfg.maxSpeed -- nil = off

    -- Sub-stepping splits each advanceSimulation call into N smaller steps.
    -- Helps fast balls not tunnel through thin pins.
    self.substeps    = cfg.substeps ~= nil and math.max(1, math.floor(cfg.substeps)) or 1

    self.onPinHit    = nil
    self.onEdgeHit   = nil
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
        id         = id,
        position   = position,
        velocity   = velocity,
        mass       = mass,
        elasticity = elasticity,
        radius     = radius or 0.1,
    }
end

function PachinkoPhysics:addPin(id, position, elasticity, radius)
    if self._isStepping then
        error("addPin cannot be called during advanceSimulation")
    end

    self.pins[id] = {
        id         = id,
        position   = position,
        elasticity = elasticity,
        radius     = radius or 0.1,
        enabled    = true,
    }
end

-- Core simulation (internal, runs one sub-step of length dt)
function PachinkoPhysics:_step(dt)
    -- Integrate motion
    for _, ball in pairs(self.balls) do
        ball.velocity = ball.velocity + self.gravity * dt

        -- Linear drag (frame-rate independent exponential decay)
        if self.linearDrag > 0 then
            local damping = math.max(0, 1 - self.linearDrag * dt)
            ball.velocity = ball.velocity * damping
        end

        -- Speed cap
        if self.maxSpeed then
            local spd = ball.velocity:length()
            if spd > self.maxSpeed then
                ball.velocity = ball.velocity * (self.maxSpeed / spd)
            end
        end

        ball.position = ball.position + ball.velocity * dt
    end

    -- Ball ↔ Edge collisions
    for _, ball in pairs(self.balls) do
        local pos = ball.position
        local vel = ball.velocity
        local r   = ball.radius
        local max = self.boardSize

        if pos.x - r < 0 then
            pos = util.vector2(r, pos.y)
            vel = util.vector2(-vel.x * ball.elasticity, vel.y)
            if self.onEdgeHit then self.onEdgeHit(ball.id, "left") end
        end

        if pos.x + r > max.x then
            pos = util.vector2(max.x - r, pos.y)
            vel = util.vector2(-vel.x * ball.elasticity, vel.y)
            if self.onEdgeHit then self.onEdgeHit(ball.id, "right") end
        end

        if pos.y - r < 0 then
            pos = util.vector2(pos.x, r)
            vel = util.vector2(vel.x, -vel.y * ball.elasticity)
            if self.onEdgeHit then self.onEdgeHit(ball.id, "top") end
        end

        if pos.y + r > max.y then
            pos = util.vector2(pos.x, max.y - r)
            vel = util.vector2(vel.x, -vel.y * ball.elasticity)
            if self.onEdgeHit then self.onEdgeHit(ball.id, "bottom") end
        end

        ball.position = pos
        ball.velocity = vel
    end

    -- Ball ↔ Pin collisions
    for _, ball in pairs(self.balls) do
        for _, pin in pairs(self.pins) do
            if pin.enabled then
                local delta   = ball.position - pin.position
                local dist    = delta:length()
                local minDist = ball.radius + pin.radius

                if dist < minDist and dist > 0 then
                    local normal = delta / dist

                    ball.position = pin.position + normal * minDist

                    local e = combineElasticity(ball.elasticity, pin.elasticity)
                    ball.velocity = reflect(ball.velocity, normal) * e

                    if self.onPinHit then self.onPinHit(ball.id, pin.id) end
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
            local a       = ballList[i]
            local b       = ballList[j]

            local delta   = a.position - b.position
            local dist    = delta:length()
            local minDist = a.radius + b.radius

            if dist < minDist and dist > 0 then
                local normal         = delta / dist

                local correction     = normal * (minDist - dist) * 0.5
                a.position           = a.position + correction
                b.position           = b.position - correction

                local relVel         = a.velocity - b.velocity
                local velAlongNormal = relVel:dot(normal)

                if velAlongNormal < 0 then
                    local e          = combineElasticity(a.elasticity, b.elasticity)
                    local impulseMag = -(1 + e) * velAlongNormal / (1 / a.mass + 1 / b.mass)
                    local impulse    = normal * impulseMag

                    a.velocity       = a.velocity + impulse / a.mass
                    b.velocity       = b.velocity - impulse / b.mass
                end
            end
        end
    end
end

-- Public step: splits dt into self.substeps equal sub-steps
function PachinkoPhysics:advanceSimulation(dt)
    self._isStepping = true

    local subDt = dt / self.substeps
    for _ = 1, self.substeps do
        self:_step(subDt)
    end

    self._isStepping = false
end

-- Trajectory prediction

--- Traces a ballistic arc under the board's gravity with no pin/edge interaction.
--- Useful for drawing a launch preview curve.
---
--- @param startPos  Vector2   World-space origin of the curve.
--- @param startVel  Vector2   Initial velocity (same units as the simulation).
--- @param samples   integer   Number of points to return (including the start). Min 2.
--- @param stepLen   number    Distance between consecutive samples (board units).
---                            The integrator advances time until the ball has travelled
---                            at least this far, so output points are evenly spaced in
---                            arc-length rather than in time.
--- @return Vector2[]          List of `samples` positions along the arc.
function PachinkoPhysics:sampleTrajectory(startPos, startVel, samples, stepLen)
    samples = math.max(2, math.floor(samples))
    stepLen = math.max(1e-6, stepLen)

    local result = { startPos }

    local pos = startPos
    local vel = startVel

    -- Fixed internal time-step upper bound.  Small enough to keep arc-length
    -- error low at high speeds, large enough not to be expensive.
    local BASE_DT = 1 / 120 -- seconds

    for _ = 2, samples do
        local distAccum = 0

        -- Integrate until we've covered at least stepLen in arc-length.
        while distAccum < stepLen do
            local spd = vel:length()

            -- Adaptive dt: aim to cross the remaining gap in ~10 ticks,
            -- capped at BASE_DT so we don't take huge leaps on slow balls.
            local remaining = stepLen - distAccum
            local dt
            if spd > 1e-6 then
                dt = math.min(remaining / (spd * 10), BASE_DT)
                -- Final-approach clamp: don't overshoot by more than one BASE_DT worth
                dt = math.min(dt, remaining / spd)
            else
                dt = BASE_DT
            end

            local prevPos = pos
            vel = vel + self.gravity * dt
            pos = pos + vel * dt

            distAccum = distAccum + (pos - prevPos):length()
        end

        table.insert(result, pos)
    end

    return result
end

return PachinkoPhysics
