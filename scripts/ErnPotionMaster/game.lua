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
local interfaces    = require('openmw.interfaces')

local shootPosition = util.vector2(0.5, 0.05):emul(const.BoardSize)

--[[
Before you begin, you pick the target effect you want. You can only choose effects that are present in atleast two different ingredients available to you.
This is used to figure out if you are trying to make a potion (positive effect) or poison (negative effect).
If you're making a potion, all positive effects are Intended and negative effects are Unintended.
This is reversed for poisons.

After choosing your effect, you pick at two to four ingredients from a secondary list. This list contains only ingredients that contain that effect.
These ingredients are shot as Balls.

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

---@class AnnotatedBall : Ball
---@field ingredientObject any The actual gameobject.
---@field ingredientRecord any The record for the ingredient.

---@class AnnotatedPin : Pin
---@field Class PinClass
---@field Popped boolean

---@class Board
---@field Balls AnnotatedBall[]
---@field Pins AnnotatedPin[]


---@param pinCounts {PinClass: number}[]
local function buildNewBoard(pinCounts)

end
