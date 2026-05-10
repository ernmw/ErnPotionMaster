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

local MOD_NAME       = require("scripts.ErnPotionMaster.ns")
local const          = require("scripts.ErnPotionMaster.const")
local ui             = require("openmw.ui")
local util           = require("openmw.util")
local pself          = require("openmw.self")
local core           = require("openmw.core")
local types          = require("openmw.types")
local placepins      = require("scripts.ErnPotionMaster.placepins")
local settings       = require("scripts.ErnPotionMaster.settings.settings")
local physics        = require("scripts.ErnPotionMaster.physics.pachinko")
local interfaces     = require('openmw.interfaces')
local shuffle        = require("scripts.ErnPotionMaster.shuffle")
local aux_util       = require('openmw_aux.util')
local renderBoard    = require("scripts.ErnPotionMaster.render.board")
local templates      = require("scripts.ErnPotionMaster.render.templates")
local effectScore    = require("scripts.ErnPotionMaster.effectscore")
local ingredientInfo = require("scripts.ErnPotionMaster.ingredientinfo")
local search         = require("scripts.ErnPotionMaster.search")
local common         = require("scripts.ErnPotionMaster.common")
local sprite         = require("scripts.ErnPotionMaster.render.sprite")

local shootPosition  = util.vector2(0.5, 0.05):emul(const.BoardSize)

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
local function resilientChance()
    local playerAlchemy = util.remap(util.clamp(pself.type.stats.skills.alchemy(pself).modified, 0, 130), 0, 130, 0, 0.7)
    local playerLuck = util.remap(util.clamp(pself.type.stats.attributes.luck(pself).modified, 0, 130), 0, 130, 0, 0.1)
    local playerIntelligence = util.remap(util.clamp(pself.type.stats.attributes.intelligence(pself).modified, 0, 130), 0,
        130, 0, .2)
    return util.clamp(1 - playerAlchemy - playerLuck - playerIntelligence, 0.1, 1)
end

---@enum PlayStateClass
local PlayStateClass = {
    --- The player is picking their shot.
    TARGET_SELECTION = 3,
    --- We're watching the shot play out.
    PHYSICS_SIMULATION = 4,
    --- The shot is done.
    SHOT_DONE = 5,
}

---@enum PinClass
local PinClass = {
    EFFECT = 1,
    BUFFER = 2,
    --- Extra life
    ALEMBIC = 3,
    --- Reset
    RETORT = 4,
    --- Multiball
    CALCINATOR = 5,
    --- Replace effects with desired effect
    MORTAR = 6,
}

---@class GamePin
---@field class PinClass
---@field magicEffectWithParamsIdx number? only valid with EFFECT pin class. index in gameState.magicEffectsWithParams
---@field ID number
---@field popped boolean
---@field popTimer number time that counts down post-popping for vfx.
---@field hit boolean used for vfx
---@field resilient boolean indicates that the pin will take two hits to pop. after being hit once, resilient is set to false

---@class GameState
---@field currentState PlayStateClass
---@field isPotion boolean true if a beneficial potion, false if a poison
---@field ballID number
---@field pins {number: GamePin}
---@field effectScores EffectScoreContainer
---@field ingredientInfos IngredientInfoContainer
---@field actualizedIngredients ActualizedIngredient[] all ingredients involved in this shot
---@field magicEffectsWithParams MagicEffectWithParams[] ingredient effects, de-duplicated and sorted
---@field desiredMagicEffectWithParamsIdx number idx in self.magicEffectsWithParams
---@field physics PachinkoPhysics
---@field toolStrengths {[PinClass]:number}

---@type GameState?
local gameState

---main window element
local window
---board UI element
local board

---@type fun(data)?
local doneCallback


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
        gameState.currentState = PlayStateClass.SHOT_DONE
    end
end

---comment
---@param original EffectScore
---@return EffectScore
local function effectPinHit(original)
    original.multiplier = original.multiplier + 0.05
    original.score = original.score + 0.3 + original.multiplier
    settings.debugPrint("effect " ..
        tostring(original.magicEffectParams.id) .. " score is now " .. tostring(original.score))
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

    if gameState.pins[pinId].class == PinClass.EFFECT then
        local effect = gameState.magicEffectsWithParams[gameState.pins[pinId].magicEffectWithParamsIdx]
        if not effect then
            error("onPinHit(): invalid effect " .. tostring(gameState.pins[pinId].magicEffectWithParamsIdx))
            return
        end
        gameState.effectScores:modifyEffectScore(effect, effectPinHit)
    elseif gameState.pins[pinId].class == PinClass.ALEMBIC then
        settings.debugPrint("TODO: Alembic effect")
    elseif gameState.pins[pinId].class == PinClass.RETORT then
        settings.debugPrint("TODO: Retort effect")
    elseif gameState.pins[pinId].class == PinClass.CALCINATOR then
        settings.debugPrint("TODO: Calcinator effect")
    elseif gameState.pins[pinId].class == PinClass.MORTAR then
        -- mortar is not a pin
    end

    gameState.pins[pinId].hit = true
    if gameState.pins[pinId].resilient then
        gameState.pins[pinId].resilient = false
    else
        settings.debugPrint("pin " .. tostring(pinId) .. " popped")
        gameState.pins[pinId].popped = true
        gameState.physics.pins[pinId].enabled = false
    end
end

local resilientShine = sprite.NewAnimatedImage("textures\\ErnPotionMaster\\circle-sweep.png",
    util.vector2(2 * 64, 2 * 64),
    4, 10, nil, {
        anchor = util.vector2(0.5, 0.5),
        relativePosition = util.vector2(0.5, 0.5),
        size = const.BallSize,
        color = util.color.hex("D4AF37"),
    })

local function getEffectPinLayouter(magicEffectWithParams)
    local color = const.MagickColors[magicEffectWithParams.effect.school].default or magicEffectWithParams.effect.color
    local shadeColor = const.MagickColors[magicEffectWithParams.effect.school].highlight or
        magicEffectWithParams.effect.color
    local icon = {
        type = ui.TYPE.Image,
        props = {
            relativePosition = util.vector2(0.5, 0.5),
            anchor = util.vector2(0.5, 0.5),
            size = const.BallSize / 2,
            resource = ui.texture {
                path = magicEffectWithParams.effect.icon
            },
        }
    }
    return function(dt, id)
        if not gameState then
            return false
        end

        local pinInfo = gameState.pins[id]
        local pin = gameState.physics.pins[id]
        local hitThisFrame = pinInfo.hit
        pinInfo.hit = false
        if pin and not pinInfo.popped then
            return {
                type = ui.TYPE.Image,
                props = {
                    position = pin.position,
                    anchor = util.vector2(0.5, 0.5),
                    size = const.BallSize,
                    resource = templates.ballTexture,
                    color = color
                },
                content = ui.content {
                    icon,
                    {
                        type = ui.TYPE.Image,
                        props = {
                            anchor = util.vector2(0.5, 0.5),
                            relativePosition = util.vector2(0.5, 0.5),
                            size = const.BallSize,
                            resource = templates.shadeTexture,
                            color = hitThisFrame and const.HitFlashColor or shadeColor
                        },
                    },
                    pinInfo.resilient and resilientShine:GetLayout(0) or {},
                }
            }
        elseif pin and pinInfo.popped and pinInfo.popTimer > 0 then
            pinInfo.popTimer = pinInfo.popTimer - dt
            local countDown = util.remap(pinInfo.popTimer, 0, const.PopFadeoutSeconds, 0, 1)
            return {
                type = ui.TYPE.Image,
                props = {
                    position = pin.position,
                    anchor = util.vector2(0.5, 0.5),
                    size = const.BallSize / (2 - countDown),
                    resource = templates.ballTexture,
                    color = hitThisFrame and const.HitFlashColor or color,
                    alpha = countDown
                },
            }
        else
            -- delete the pin from renderer
            return false
        end
    end
end


-- sets the board up for a new shot
---comment
---@param ingredients ActualizedIngredient[]
---@param toolStrengths {[ToolClass]:number}
---@param desiredMagicEffectWithParams MagicEffectWithParams
local function resetBoard(ingredients, toolStrengths, desiredMagicEffectWithParams)
    settings.debugPrint("resetBoard() called")
    board = renderBoard.new()
    settings.debugPrint("finished importing render board")

    gameState = {
        -- todo: finish
        isPotion = true,
        ballID = 1,
        currentState = PlayStateClass.TARGET_SELECTION,
        effectScores = nil,
        ingredientInfos = nil,
        actualizedIngredients = ingredients,
        magicEffectsWithParams = {},
        desiredMagicEffectWithParamsIdx = 0,
        -- add a little extra height so the ball can drop below
        -- TODO: also add height above
        physics = physics.new(const.BoardSize + util.vector2(0, 1.5 * const.BallSize.y)),
        pins = {},
        toolStrengths = toolStrengths,
    }
    gameState.physics.onEdgeHit = onEdgeHit
    gameState.physics.onPinHit = onPinHit

    gameState.ingredientInfos = ingredientInfo.new(gameState.actualizedIngredients)


    --- get magic effects we are dealing with
    local recs = {}
    for _, obj in ipairs(gameState.actualizedIngredients) do
        table.insert(recs, obj.record)
    end
    gameState.magicEffectsWithParams = common.getMagicEffectsFromIngredients(recs)
    local idxOfDesired = search.contains(gameState.magicEffectsWithParams, function(item)
        return common.magicEffectsEqual(desiredMagicEffectWithParams, item)
    end)
    if not idxOfDesired then
        error("effect not found")
    end
    settings.debugPrint("found " .. tostring(#gameState.magicEffectsWithParams) .. " effects")
    gameState.desiredMagicEffectWithParamsIdx = idxOfDesired
    gameState.effectScores = effectScore.new(gameState.magicEffectsWithParams)

    -- determine magic effect pin counts
    local playerAlchemyFactor = util.remap(util.clamp(pself.type.stats.skills.alchemy(pself).modified, 0, 130), 0, 130, 1,
        1.5)
    -- tool strength is from 0.5 to 2
    local replaceChance = util.remap(util.clamp(playerAlchemyFactor * toolStrengths[const.ToolClass.MORTAR], 0.5, 3), 0.5,
        3, 0,
        0.95)
    ---@type {[number]:number}
    local effectPinCounts = {}
    for idx, mewp in ipairs(gameState.magicEffectsWithParams) do
        if idx == gameState.desiredMagicEffectWithParamsIdx then
            -- special treatment for the desired effect
            effectPinCounts[idx] = math.ceil(const.PinsPerEffect * 1.5)
        else
            for _ = 1, const.PinsPerEffect, 1 do
                --- mortar has a chance to replace undesired effects
                if math.random() < replaceChance then
                    effectPinCounts[gameState.desiredMagicEffectWithParamsIdx] = (effectPinCounts
                        [gameState.desiredMagicEffectWithParamsIdx] or 0) + 1
                else
                    effectPinCounts[idx] = (effectPinCounts[idx] or 0) + 1
                end
            end
        end
    end

    ---@type {[PinClass]:number}
    local toolPinCounts = {
        [PinClass.ALEMBIC] = math.ceil(2 * gameState.toolStrengths[const.ToolClass.ALEMBIC]),
        [PinClass.CALCINATOR] = math.ceil(2 * gameState.toolStrengths[const.ToolClass.CALCINATOR]),
        [PinClass.RETORT] = gameState.toolStrengths[const.ToolClass.RETORT] and 1 or 0
    }

    -- get total number of pins
    local totalPins = 0
    for _, count in pairs(effectPinCounts) do
        totalPins = totalPins + count
    end
    for _, count in pairs(toolPinCounts) do
        totalPins = totalPins + count
    end

    local topOffset = util.vector2(0, 0.15)
    local midTopOffsetBorder = const.BoardSize:emul(util.vector2(0, topOffset.y))
    ---@type Vector2[]
    local potentialSpots = placepins(const.BoardSize:emul(util.vector2(1, 1 - topOffset.y)), const.PinRadius, totalPins)

    --- Add pins!
    local nextPinID = 100

    ---@param pin GamePin
    local function addPin(pin)
        if pin.ID == 0 then
            pin.ID = nextPinID
            nextPinID = nextPinID + 1
        end
        if gameState.pins[pin.ID] then
            error("pin ID already taken")
        end
        local position = table.remove(potentialSpots)
        if not position then
            settings.debugPrint("no space for pin " .. tostring(pin.ID))
            return
        end
        gameState.pins[pin.ID] = pin
        gameState.physics:addPin(pin.ID, position + midTopOffsetBorder, 0.9, const.PinRadius)
        if pin.class == PinClass.EFFECT then
            local mewp = gameState.magicEffectsWithParams[pin.magicEffectWithParamsIdx]
            board.pins:AddRenderable({
                id = pin.ID,
                layout = getEffectPinLayouter(mewp)
            })
        else
            board.pins:AddRenderable({
                id = pin.ID,
                layout = function(dt, id)
                    local ppin = gameState.physics.pins[id]
                    if ppin and not gameState.pins[id].popped then
                        return {
                            type = ui.TYPE.Image,
                            props = {
                                position = ppin.position,
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

    local resChance = resilientChance()
    for idx, count in pairs(effectPinCounts) do
        for _ = 1, count, 1 do
            addPin({
                ID = 0,
                class = PinClass.EFFECT,
                magicEffectWithParamsIdx = idx,
                hit = false,
                popped = false,
                popTimer = const.PopFadeoutSeconds,
                resilient = math.random() < resChance
            })
        end
    end

    for class, count in pairs(toolPinCounts) do
        for _ = 1, count, 1 do
            addPin({
                ID = 0,
                class = class,
                hit = false,
                popped = false,
                popTimer = const.PopFadeoutSeconds,
                resilient = math.random() < resChance
            })
        end
    end
end

---Spawns a ball at the top of the screen with the provided velocity vector.
---@param directionVec any
local function shootBall(directionVec)
    if not gameState then
        error("gameState is nil")
    end
    if gameState.currentState ~= PlayStateClass.TARGET_SELECTION then
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
    shootBall(util.vector2(math.random(), math.random()) * 5)
    gameState.currentState = PlayStateClass.PHYSICS_SIMULATION
    board:onFrame(dt)
    window:update()
end
local function physicsSimulation(dt)
    if not gameState then
        error("gameState is nil")
    end
    gameState.physics:advanceSimulation(dt)
    resilientShine:GetLayout(dt) -- to advance the anim
    board:onFrame(dt)
    window:update()
end
local function shotDone(dt)
    -- todo: finish
    settings.debugPrint("stop alchemy")
    -- do cleanup
    gameState = nil
    if board then board:reset() end
    if window then
        window:destroy()
        window = nil
    end
    -- TODO: send effect score results to doneCallback
    if doneCallback then doneCallback() end
end

---@type table
local stateHandlers = {
    [PlayStateClass.TARGET_SELECTION] = targetSelection,
    [PlayStateClass.PHYSICS_SIMULATION] = physicsSimulation,
    [PlayStateClass.SHOT_DONE] = shotDone,
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
        content = ui.content {
            {
                type = ui.TYPE.Flex,
                props = {
                    horizontal = true,
                    align = ui.ALIGNMENT.Center,
                    arrange = ui.ALIGNMENT.Center,
                    --anchor = util.vector2(0.5, 0.5),
                    --relativePosition = util.vector2(0.5, 0.5),
                },
                content = ui.content {
                    board.boardElement,
                    {
                        type = ui.TYPE.Flex,
                        props = {
                            horizontal = false,
                            align = ui.ALIGNMENT.Center,
                            arrange = ui.ALIGNMENT.Center,
                        },
                        content = ui.content {
                            gameState.ingredientInfos.element,
                            gameState.effectScores.element,
                        },
                    },
                },
            },
        }

    })
end

local function onFrame()
    if gameState then
        local dt = core.getRealFrameDuration()
        stateHandlers[gameState.currentState](dt)
        gameState.effectScores:onFrame(dt)
        gameState.ingredientInfos:onFrame(dt)
    end
end


local function showWindow(data)
    settings.debugPrint("start alchemy play window: " .. aux_util.deepToString(data, 3))

    doneCallback = data.doneCallback
    resetBoard(data.ingredientInfos, data.toolStrengths, data.desiredEffect)
    openWindow()
end

return {
    showWindow = showWindow,
    closeWindow = shotDone,
    onFrame = onFrame,
}
