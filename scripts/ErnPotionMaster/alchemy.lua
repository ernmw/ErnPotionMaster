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
local core          = require("openmw.core")
local types         = require("openmw.types")
local placepins     = require("scripts.ErnPotionMaster.placepins")
local settings      = require("scripts.ErnPotionMaster.settings.settings")
local physics       = require("scripts.ErnPotionMaster.physics.pachinko")
local interfaces    = require('openmw.interfaces')
local shuffle       = require("scripts.ErnPotionMaster.shuffle")
local aux_util      = require('openmw_aux.util')
local renderBoard   = require("scripts.ErnPotionMaster.render.board")
local templates     = require("scripts.ErnPotionMaster.render.templates")
local effectScore   = require("scripts.ErnPotionMaster.effectscore")

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

This file contains the game board UX, which is what follows:

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

---@enum StateClass
local StateClass = {
    --- First, pick your effect.
    EFFECT_SELECTION = 1,
    -- Pick 2 to 4 ingredients
    INGREDIENT_SELECTION = 2,
    --- The player is picking their shot.
    TARGET_SELECTION = 3,
    --- We're watching the shot play out.
    PHYSICS_SIMULATION = 4,
    --- The shot is done, do Effect Score flourishes.
    SHOT_DONE = 5,
    --- The last shot is done, make the potion.
    FINISHED = 6,
}

---@enum PinClass
local PinClass = {
    EFFECT_1 = 1,
    EFFECT_2 = 2,
    EFFECT_3 = 3,
    EFFECT_4 = 4,
    BUFFER = 5,
    ALEMBIC = 6,
    RETORT = 7,
    CALCINATOR = 8,
    -- special
    MORTAR = 9,
}

---@class GamePin
---@field class PinClass
---@field ID number
---@field popped boolean



---@class GameState
---@field currentState StateClass
---@field isPotion boolean true if a beneficial potion, false if a poison
---@field ballID number
---@field pins {number: GamePin}
---@field effectScores EffectScoreContainer
---@field pendingIngredientRecords any[] subsequent balls that haven't been shot yet
---@field currentIngredientRecord any? the ingredient matching the current ball
---@field physics PachinkoPhysics
---@field toolStrengths {PinClass: number}

---@type GameState?
local gameState

---main window element
local window
---board UI element
local board

local function onStopAlchemy()
    settings.debugPrint("stop alchemy")
    -- do cleanup
    gameState = nil
    if board then board:reset() end
    if window then
        window:destroy()
        window = nil
    end

    -- forward to global to remove this script
    core.sendGlobalEvent(MOD_NAME .. 'onStopAlchemy', {
        player = pself,
    })
end

local function getToolStrengths()
    -- TODO!
    return {
        [PinClass.ALEMBIC] = 1,
        [PinClass.CALCINATOR] = 1,
        [PinClass.RETORT] = 1,
        [PinClass.MORTAR] = 1,
    }
end



local function onEdgeHit(ballId, edge)
    if not gameState then
        error("onEdgeHit(): gameState is nil")
        return
    end
    if not ballId or not edge then
        error("onEdgeHit(): param(s) nil")
        return
    end
    settings.debugPrint("ball " .. tostring(ballId) .. " hit edge " .. tostring(edge))
    if edge == "bottom" then
        settings.debugPrint("ball hit bottom edge")
        gameState.currentState = StateClass.SHOT_DONE
    end
end

---comment
---@param original EffectScore
---@return EffectScore
local function effectPinHit(original)
    original.multiplier = original.multiplier + 1
    original.score = original.score + original.multiplier
    settings.debugPrint("effect " .. tostring(original.magicEffect.id) .. " score is now " .. tostring(original.score))
    return original
end

local function onPinHit(ballId, pinId)
    if not gameState then
        error("onPinHit(): gameState is nil")
        return
    end
    if not ballId or not pinId then
        error("onPinHit(): param(s) nil")
        return
    end
    settings.debugPrint("ball " .. tostring(ballId) .. " hit pin " .. tostring(pinId))
    if not gameState.pins[pinId] then
        error("onPinHit(): unknown pinId")
        return
    end

    if gameState.pins[pinId].class == PinClass.EFFECT_1 then
        local effect = gameState.currentIngredientRecord.effects[1]
        if not effect then
            error("onPinHit(): invalid effect 1")
            return
        end
        gameState.effectScores:modifyEffectScore(effect, effectPinHit)
    elseif gameState.pins[pinId].class == PinClass.EFFECT_2 then
        local effect = gameState.currentIngredientRecord.effects[2]
        if not effect then
            error("onPinHit(): invalid effect 2")
            return
        end
        gameState.effectScores:modifyEffectScore(effect, effectPinHit)
    elseif gameState.pins[pinId].class == PinClass.EFFECT_3 then
        local effect = gameState.currentIngredientRecord.effects[3]
        if not effect then
            error("onPinHit(): invalid effect 3")
            return
        end
        gameState.effectScores:modifyEffectScore(effect, effectPinHit)
    elseif gameState.pins[pinId].class == PinClass.EFFECT_4 then
        local effect = gameState.currentIngredientRecord.effects[4]
        if not effect then
            error("onPinHit(): invalid effect 4")
            return
        end
        gameState.effectScores:modifyEffectScore(effect, effectPinHit)
    elseif gameState.pins[pinId].class == PinClass.ALEMBIC then
        -- reduce unintentional
        for i, es in ipairs(shuffle(gameState.effectScores.scores)) do
            if not es.magicEffect then
                error("no magicEffect in effectScore: " .. aux_util.deepToString(es, 3))
            end
            if es.magicEffect.effect.harmful == gameState.isPotion then
                gameState.effectScores:modifyEffectScore(es, function(original)
                    local strength = gameState.toolStrengths[PinClass.ALEMBIC]
                    original.score = original.score / (strength + 1)
                    return original
                end)
                break
            end
        end
    elseif gameState.pins[pinId].class == PinClass.RETORT then
        -- increase intentional
        for i, es in ipairs(shuffle(gameState.effectScores.scores)) do
            if not es.magicEffect then
                error("no magicEffect in effectScore: " .. aux_util.deepToString(es, 3))
            end
            if es.magicEffect.effect.harmful ~= gameState.isPotion then
                gameState.effectScores:modifyEffectScore(es, function(original)
                    local strength = gameState.toolStrengths[PinClass.RETORT]
                    original.score = original.score * (strength + 1)
                    return original
                end)
                break
            end
        end
    elseif gameState.pins[pinId].class == PinClass.CALCINATOR then
        settings.debugPrint("TODO: Calcinator effect")
    end

    -- todo: render a little flash on the pin and maybe scale the pin up a little or jiggle

    if math.random() < popChance() then
        settings.debugPrint("pin " .. tostring(pinId) .. " popped")
        gameState.pins[pinId].popped = true
        gameState.physics.pins[pinId].enabled = false
        -- todo: render a little popping sprite
    end
end

local function addToolPins(pins, toolStrengths)
    pins = pins or {}
    for pinType, strength in pairs(toolStrengths) do
        if pinType ~= PinClass.MORTAR then
            pins[pinType] = 1
        end
    end
    return pins
end

local function addEffectPins(pins, pestleStrength, ingredientRecord)
    pins = pins or {}
    local pinCount = util.clamp(math.floor((pestleStrength + 1) * math.log(10, ingredientRecord.value)), 1, 5)
    for idx, _ in ipairs(ingredientRecord.effects) do
        if idx == 1 then
            pins[PinClass.EFFECT_1] = pinCount
        elseif idx == 2 then
            pins[PinClass.EFFECT_2] = pinCount
        elseif idx == 3 then
            pins[PinClass.EFFECT_3] = pinCount
        elseif idx == 4 then
            pins[PinClass.EFFECT_4] = pinCount
        end
    end
    return pins
end

local function resetBoard(ingredientObjects, toolStrengths)
    settings.debugPrint("resetBoard() called")
    board = renderBoard.new()
    settings.debugPrint("finished importing render board")

    gameState = {
        -- todo: finish
        isPotion = true,
        ballID = 1,
        currentState = StateClass.TARGET_SELECTION,
        effectScores = effectScore.new(),
        pendingIngredientRecords = {},
        -- add a little extra height so the ball can drop below
        physics = physics.new(const.BoardSize + util.vector2(0, 1.5 * const.BallSize.y)),
        pins = {},
        toolStrengths = toolStrengths,
        currentIngredientRecord = nil,
    }
    gameState.physics.onEdgeHit = onEdgeHit
    gameState.physics.onPinHit = onPinHit

    for _, obj in ipairs(ingredientObjects) do
        local record = types.Ingredient.record(obj)
        settings.debugPrint("ingredient: " .. tostring(record.name))
        table.insert(gameState.pendingIngredientRecords, record)
        -- obj:remove(1) -- TODO: this doesn't work for some reason
    end

    gameState.currentIngredientRecord = table.remove(gameState.pendingIngredientRecords, 1)
    if not gameState.currentIngredientRecord then
        error("gameState.currentIngredientRecord is nil")
    end

    local pinCounts = {}
    pinCounts[PinClass.BUFFER] = 5
    pinCounts = addToolPins(pinCounts, gameState.toolStrengths)
    pinCounts = addEffectPins(pinCounts, gameState.toolStrengths[PinClass.MORTAR] or 0,
        gameState.currentIngredientRecord)

    local totalPins = 0
    for _, count in pairs(pinCounts) do
        totalPins = totalPins + count
    end

    local topOffset = util.vector2(0, 0.15)
    local midTopOffsetBorder = const.BoardSize:emul(util.vector2(0, topOffset.y))
    ---@type Vector2[]
    local potentialSpots = placepins(const.BoardSize:emul(util.vector2(1, 1 - topOffset.y)), const.PinRadius, totalPins)

    local pinID = 100
    -- assign pins to spots
    for pinType, count in pairs(pinCounts) do
        for i = 1, count do
            pinID = pinID + 1
            ---@type Vector2?
            local position = table.remove(potentialSpots)
            if position then
                gameState.pins[pinID] = { class = pinType, ID = pinID, popped = false }
                gameState.physics:addPin(pinID, position + midTopOffsetBorder, 0.9, const.PinRadius)
                board.pins:AddRenderable({
                    id = pinID,
                    layout = function(dt, id)
                        local pin = gameState.physics.pins[id]
                        if pin and not gameState.pins[id].popped then
                            return {
                                type = ui.TYPE.Image,
                                props = {
                                    position = pin.position,
                                    anchor = util.vector2(0.5, 0.5),
                                    size = const.BallSize,
                                    resource = templates.bufferPinTexture,
                                },
                            }
                        else
                            -- delete the pin from renderer
                            return false
                        end
                    end
                })
            end
        end
    end
end

---Spawns a ball at the top of the screen with the provided velocity vector.
---@param directionVec any
local function shootBall(directionVec)
    if not gameState then
        error("gameState is nil")
    end
    if gameState.currentState ~= StateClass.TARGET_SELECTION then
        error("gameState.currentState is not Target Selection")
    end
    gameState.ballID = gameState.ballID + 1
    local ballID = gameState.ballID
    gameState.physics:addBall(ballID, shootPosition, directionVec, 1, 1, const.BallRadius)
    board.balls:AddRenderable({
        id = ballID,
        layout = function(dt, id)
            local ball = gameState.physics.balls[id]
            if ball then
                return {
                    type = ui.TYPE.Image,
                    props = {
                        position = ball.position,
                        anchor = util.vector2(0.5, 0.5),
                        size = const.BallSize,
                        resource = templates.ballTexture,
                    },
                }
            else
                -- delete the ball from renderer
                return false
            end
        end
    })
end

local function targetSelection(dt)
    -- TODO: fill out stub
    shootBall(util.vector2(math.random(), math.random()))
    gameState.currentState = StateClass.PHYSICS_SIMULATION
    board:onFrame(dt)
    window:update()
end
local function physicsSimulation(dt)
    if not gameState then
        error("gameState is nil")
    end
    gameState.physics:advanceSimulation(dt)
    board:onFrame(dt)
    window:update()
end
local function shotDone(dt)
    -- todo: set up next shot?
end
local function finished(dt)
    -- todo: finish
    onStopAlchemy()
end

---@type table
local stateHandlers = {
    [StateClass.TARGET_SELECTION] = targetSelection,
    [StateClass.PHYSICS_SIMULATION] = physicsSimulation,
    [StateClass.SHOT_DONE] = shotDone,
    [StateClass.FINISHED] = finished,
}


local function openWindow()
    window = ui.create({
        layer = "Windows",
        type = ui.TYPE.Container,
        template = interfaces.MWUI.templates.boxTransparent,
        props = {
            --size = const.BoardSize + util.vector2(const.BoardSize.x, 32),
            anchor = util.vector2(0.5, 0.5),
            relativePosition = util.vector2(0.5, 0.5),
            --resource = ui.texture({ path = "black" }),
        },
        content = ui.content({
            board.boardElement,
            gameState.effectScores:layout()
        })
    })
end

local function onFrame(dt)
    if gameState then
        stateHandlers[gameState.currentState](core.getRealFrameDuration())
    end
end

local function onInit(data)
    settings.debugPrint("start alchemy")

    -- TODO: actually do selection logic. this is just for testing
    local ingredients = {}
    for _, item in ipairs(shuffle(pself.type.inventory(pself):getAll(types.Ingredient))) do
        table.insert(ingredients, item)
        if #ingredients > 2 then
            break
        end
    end

    local toolStrengths = getToolStrengths()

    resetBoard(ingredients, toolStrengths)
    openWindow()
end

return {
    engineHandlers = {
        onInit = onInit,
        onFrame = onFrame,
    },
    eventHandlers = {
        [MOD_NAME .. "onStopAlchemy"] = onStopAlchemy,
    }
}
