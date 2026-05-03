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

-- This file contains the game state, including the board.
-- It owns and rebuilds the pachinko physics board as necessary.
-- It owns and rebuilds the render board as necessary.
-- It maintains a registry of balls and pins indexed by their ID,
-- and sends this info as necessary to both the pachinko physics board and render board.

local MOD_NAME      = require("scripts.ErnPotionMaster.ns")
local const         = require("scripts.ErnPotionMaster.const")
local ui            = require("openmw.ui")
local util          = require("openmw.util")
local pself         = require("openmw.self")
local board         = require("scripts.ErnPotionMaster.render.board")
local placepins     = require("scripts.ErnPotionMaster.placepins")
local settings      = require("scripts.ErnPotionMaster.settings.settings")
local physics       = require("scripts.ErnPotionMaster.physics.pachinko")
local interfaces    = require('openmw.interfaces')

local shootPosition = util.vector2(0.5, 0.05):emul(const.BoardSize)

--[[
Before you begin, you pick the target effect you want. You can only choose effects that are present in atleast two different ingredients available to you.
This is used to figure out if you are trying to make a potion (positive effect) or poison (negative effect).
If you're making a potion, all positive effects are Intended and negative effects are Unintended.
This is reversed for poisons.

After choosing your effect, you pick at two to four ingredients from a secondary list.
For the first two ingredients you pick, the list will only contain ingredients that contain your desired effect.
For third and and fourth ingredients you might pick, the list will only contain ingredients that have at least one effect in common with all the previously-selected ingredients.
These ingredients are shot as Balls.

After picking two to four ingredients, you can click on a "Create" button.
This will delete the ingredients from your inventory and start up the game board UI.

A Ball is one ingredient.
There will be at least one pin per ingredient effect (up to 4). The more expensive the ingredient, and the better your Motar and Pestle, the more pins will be Effect Pins.
Hit the effect pin to increase the Effect Score for that individual effect.
Each time you hit an effect pin for the same effect on the same shot,
you get exponentially more points for that Effect Score.
As the Effect Score increases, you get additional magnitude and duration for that effect.

If you have the appropriate alchemy equipment, you will get one pin per each equipment item:
- Alembic: Reduces a random Unintended effect Effect Score. The amount depends on the tool quality.
- Retort: Multiplies the current Effect Score of a random Intended effect. The amount depends on the tool quality.
- Calcinator: Un-pops pins on the board instantly. The chance to un-Pop a pin depends on the tool quality. Before un-Popping, popped pins have their positions shuffled.
Mortar and Pestle is different, since it has an impact on the number of Effect Pins.

The Effect Score sticks around between Shots.
The board is reset after each Shot.
After making your predetermined number of Shots (2 to 4), the potion is created based on its Effect Scores.

Pins have a chance to Pop when they are hit based on your Alchemy skill, Intelligence, and Luck.
]]

---Returns the chance that a Pin will Pop when it is hit.
---If it pops, it gets deleted. The pin hit effect still takes place, though.
---@return number between 0.1 and 1
local function popChance()
    local playerAlchemy = util.remap(util.clamp(pself.type.stats.skills.alchemy(pself).modified, 0, 130), 0, 130, 0, 0.7)
    local playerLuck = util.remap(util.clamp(pself.type.stats.attributes.luck(pself).modified, 0, 130), 0, 130, 0, 0.1)
    local playerIntelligence = util.remap(util.clamp(pself.type.stats.attributes.intelligence(pself).modified, 0, 130), 0,
        130, 0, .2)
    return util.clamp(1 - playerAlchemy - playerLuck - playerIntelligence, 0.1, 1)
end

---@enum (key) PinClass
local PinClass = {
    EFFECT_1 = 1,
    EFFECT_2 = 2,
    EFFECT_3 = 3,
    EFFECT_4 = 4,
    BUFFER = 5,
    ALEMBIC = 6,
    RETORT = 7,
    CALCINATOR = 8,
}

---@class GamePin
---@field class PinClass
---@field ID number
---@field popped boolean

---@class EffectScore
---@field magicEffect any
---@field score number

---@class GameState
---@field ballID number
---@field pins GamePin[]
---@field effectScores EffectScore[]
---@field pendingIngredientRecords any[]
---@field currentIngredientRecord any
---@field physics PachinkoPhysics

---@type GameState?
local gameState

local function onEdgeHit(ballId, edge)
    settings.debugPrint("ball " .. tostring(ballId) .. " hit edge " .. tostring(edge))
end

local function onPinHit(ballId, pinId)
    settings.debugPrint("ball " .. tostring(ballId) .. " hit pin " .. tostring(pinId))
end

---@param pinCounts table
local function resetBoard(pinCounts)
    if not gameState then
        error("gameState is nil")
    end
    gameState.ballID = 0
    gameState.pins = {}
    gameState.physics = physics.new(const.BoardSize)
    gameState.physics.onEdgeHit = onEdgeHit
    gameState.physics.onPinHit = onPinHit

    local totalPins = 0
    for _, count in ipairs(pinCounts) do
        totalPins = totalPins + count
    end

    local topOffset = util.vector2(0, 0.15)
    ---@type Vector2[]
    local potentialSpots = placepins(const.BoardSize:emul(util.vector2(1, 0.85)), const.PinRadius, totalPins)

    local id = 100
    -- assign pins to spots
    for pinType, _ in pairs(pinCounts) do
        id = id + 1
        ---@type Vector2?
        local position = table.remove(potentialSpots)
        if position then
            table.insert(gameState.pins, { class = pinType, id = id })
            gameState.physics:addPin(id, position + topOffset, 0.9, const.PinRadius)
        end
    end
end


return {
    resetBoard = resetBoard
}
