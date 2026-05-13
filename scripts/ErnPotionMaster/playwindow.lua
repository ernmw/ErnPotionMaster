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
local keytrack       = require("scripts.ErnPotionMaster.keytrack")
local trajectory     = require("scripts.ErnPotionMaster.render.trajectory")
local input          = require("openmw.input")
local async          = require("openmw.async")
local ambient        = require("openmw.ambient")

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
---@field hit boolean used for vfx
---@field hitLeft boolean true if ball hit it on left side. used for vfx
---@field resilient boolean indicates that the pin will take two hits to pop. after being hit once, resilient is set to false
---@field explodeAnim AnimatedImage?

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

-- Module-level animated image (stateless across instances, safe to share)
local resilientShine = sprite.NewAnimatedImage("textures\\ErnPotionMaster\\circle-sweep.dds",
    util.vector2(2 * 64, 2 * 64),
    4, 10, nil, nil, {
        anchor = util.vector2(0.5, 0.5),
        relativePosition = util.vector2(0.5, 0.5),
        size = const.PinSize,
        color = const.ResilientColor,
    })

local function makeExplodeAnim(props)
    return sprite.NewAnimatedImage("textures\\ErnPotionMaster\\blast.dds",
        util.vector2(2 * 256, 2 * 256),
        4, 20, 1, nil, props)
end

local function makeHitAnim(left, props)
    return sprite.NewAnimatedImage(
        left and "textures\\ErnPotionMaster\\hit_left.dds" or "textures\\ErnPotionMaster\\hit_right.dds",
        util.vector2(2 * 256, 2 * 256),
        4, 20, 1, nil, props)
end

------------------------------------------------------------------------
-- PlayWindow class
------------------------------------------------------------------------

---@class PlayWindow
---@field gameState GameState?
---@field window table?  openmw ui element
---@field board table?   render board
---@field shotAim Vector2?
---@field doneCallback fun(data)?
local PlayWindow = {}
PlayWindow.__index = PlayWindow

---Constructor. Creates, initialises, and opens a PlayWindow.
---@param data {ingredientInfos: ActualizedIngredient[], toolStrengths: table, desiredEffect: MagicEffectWithParams, doneCallback: fun(data)}
---@return PlayWindow
function PlayWindow.new(data)
    settings.debugPrint("start alchemy play window: " .. aux_util.deepToString(data, 3))
    local self = setmetatable({
        gameState    = nil,
        window       = nil,
        board        = nil,
        doneCallback = data.doneCallback,
    }, PlayWindow)
    self:_init(data.ingredientInfos, data.toolStrengths, data.desiredEffect)
    return self
end

------------------------------------------------------------------------
-- Private helpers (receive self explicitly)
------------------------------------------------------------------------

---Returns the chance that a Pin will Pop when hit (0.1 – 1).
---@return number
function PlayWindow:_resilientChance()
    local playerAlchemy = util.remap(
        util.clamp(pself.type.stats.skills.alchemy(pself).modified, 0, 130), 0, 130, 0, 0.7)
    local playerLuck = util.remap(
        util.clamp(pself.type.stats.attributes.luck(pself).modified, 0, 130), 0, 130, 0, 0.1)
    local playerIntelligence = util.remap(
        util.clamp(pself.type.stats.attributes.intelligence(pself).modified, 0, 130), 0, 130, 0, 0.2)
    return util.clamp(1 - playerAlchemy - playerLuck - playerIntelligence, 0.1, 1)
end

---@param original EffectScore
---@return EffectScore
local function effectPinHit(original)
    original.multiplier = original.multiplier + 0.05
    original.score      = original.score + 0.3 + original.multiplier
    settings.debugPrint("effect " ..
        tostring(original.magicEffectParams.id) .. " score is now " .. tostring(original.score))
    return original
end

---Called by the physics engine when a ball reaches an edge.
---@param ballId number
---@param edge string
function PlayWindow:_onEdgeHit(ballId, edge)
    if not self.gameState then
        error("_onEdgeHit(): gameState is nil")
        return
    end
    if not ballId or not edge then
        error("_onEdgeHit(): param(s) nil")
        return
    end
    settings.debugPrint("ball " .. tostring(ballId) .. " hit edge " .. tostring(edge))
    if edge == "bottom" then
        settings.debugPrint("ball hit bottom edge")
        self.gameState.currentState = PlayStateClass.SHOT_DONE
    end
end

function PlayWindow:_register_pin_renderer(pin)
    if pin.class == PinClass.EFFECT then
        self.board.pins:AddRenderable({
            layout = self:_getEffectPinLayouter(pin.ID,
                self.gameState.magicEffectsWithParams[pin.magicEffectWithParamsIdx]),
        })
    else
        self.board.pins:AddRenderable({
            layout = self:_getToolPinLayouter(pin.ID),
        })
    end
end

function PlayWindow:_tool_reset()
    local retortStrength = self.gameState.toolStrengths[PinClass.RETORT]
    local resetChance = util.remap(util.clamp(retortStrength, 0, 2), 0, 2, 0, .6)
    for id, pinInfo in pairs(self.gameState.pins) do
        if pinInfo.popped and math.random() < resetChance then
            settings.debugPrint("reset pin " .. tostring(id))
            pinInfo.popped = false
            pinInfo.hit = false
            pinInfo.explodeAnim = nil
            self.gameState.physics.pins[id].enabled = true
            self:_register_pin_renderer(pinInfo)
            --TODO: add some flair when the pins reset
        end
    end
end

---Called by the physics engine when a ball hits a pin.
---@param ballId number
---@param pinId number
function PlayWindow:_onPinHit(ballId, pinId)
    local gs = self.gameState
    if not gs then
        error("_onPinHit(): gameState is nil")
        return
    end
    if not ballId or not pinId then
        error("_onPinHit(): param(s) nil")
        return
    end
    settings.debugPrint("ball " .. tostring(ballId) .. " hit pin " .. tostring(pinId))
    if not gs.pins[pinId] then
        error("_onPinHit(): unknown pinId")
        return
    end

    local pinInfo = gs.pins[pinId]

    if pinInfo.class == PinClass.EFFECT then
        local effect = gs.magicEffectsWithParams[pinInfo.magicEffectWithParamsIdx]
        if not effect then
            error("_onPinHit(): invalid effect " .. tostring(pinInfo.magicEffectWithParamsIdx))
            return
        end
        gs.effectScores:modifyEffectScore(effect, effectPinHit)
    elseif pinInfo.class == PinClass.ALEMBIC then
        settings.debugPrint("TODO: Alembic effect")
    elseif pinInfo.class == PinClass.RETORT then
        settings.debugPrint("Retort effect")
        self:_tool_reset()
    elseif pinInfo.class == PinClass.CALCINATOR then
        settings.debugPrint("TODO: Calcinator effect")
    elseif pinInfo.class == PinClass.MORTAR then
        -- mortar is not a pin
    end

    ambient.playSoundFile("Sound\\ErnPotionMaster\\boink.ogg")

    pinInfo.hitLeft = gs.physics.balls[ballId].position.x < gs.physics.pins[pinId].position.x
    pinInfo.hit = true
    if pinInfo.resilient then
        pinInfo.resilient = false
    else
        settings.debugPrint("pin " .. tostring(pinId) .. " popped")
        pinInfo.popped = true
        gs.physics.pins[pinId].enabled = false
    end
end

---Returns a per-frame layout closure for an EFFECT pin.
---Closes over `self` and the static effect data; reads live state via self.gameState.
---@param pinID number
---@param magicEffectWithParams MagicEffectWithParams
---@return fun(dt:number, id:number): table|boolean
function PlayWindow:_getEffectPinLayouter(pinID, magicEffectWithParams)
    local color = const.MagickColors[magicEffectWithParams.effect.school].default
        or const.MagickColors.unknown.default
    local shadeColor = const.MagickColors[magicEffectWithParams.effect.school].highlight
        or const.MagickColors.unknown.highlight
    local icon = {
        type = ui.TYPE.Image,
        props = {
            relativePosition = util.vector2(0.5, 0.5),
            anchor           = util.vector2(0.5, 0.5),
            size             = const.PinSize / 2,
            resource         = ui.texture { path = magicEffectWithParams.effect.icon },
        }
    }
    return function(dt, id)
        local gs = self.gameState
        if not gs then return false end

        local pinInfo      = gs.pins[pinID]
        local pin          = gs.physics.pins[pinID]
        local hitThisFrame = pinInfo.hit
        pinInfo.hit        = false

        if pin and not pinInfo.popped then
            -- spawn hit effect?
            if hitThisFrame and not pinInfo.explodeAnim then
                pinInfo.explodeAnim = makeHitAnim(pinInfo.hitLeft, {
                    anchor = util.vector2(0.5, 0.5),
                    relativePosition = util.vector2(0.5, 0.5),
                    size = const.PinSize * 4,
                    color = color,
                })
            end
            local hitLayout
            if pinInfo.explodeAnim then
                hitLayout = pinInfo.explodeAnim:GetLayout(dt)
                -- if done with anim, delete it
                if hitLayout == nil then
                    pinInfo.explodeAnim = nil
                end
            end

            return {
                props   = {
                    position = pin.position,
                    anchor   = util.vector2(0.5, 0.5),
                    size     = const.PinSize * 4,
                },
                content = ui.content {
                    {
                        type    = ui.TYPE.Image,
                        props   = {
                            relativePosition = util.vector2(0.5, 0.5),
                            anchor           = util.vector2(0.5, 0.5),
                            size             = const.PinSize,
                            resource         = templates.ballTexture,
                            color            = color
                        },
                        content = ui.content {
                            icon,
                            {
                                type  = ui.TYPE.Image,
                                props = {
                                    anchor           = util.vector2(0.5, 0.5),
                                    relativePosition = util.vector2(0.5, 0.5),
                                    size             = const.PinSize,
                                    resource         = templates.shadeTexture,
                                    color            = hitThisFrame and const.HitFlashColor or shadeColor
                                },
                            },
                            pinInfo.resilient and resilientShine:GetLayout(0) or {},
                        }
                    },
                    hitLayout or {},
                }
            }
        elseif pin and pinInfo.popped and not pinInfo.explodeAnim then
            pinInfo.explodeAnim = makeExplodeAnim({
                anchor = util.vector2(0.5, 0.5),
                position = pin.position,
                size = const.PinSize * 8,
                color = shadeColor,
            })
            return pinInfo.explodeAnim:GetLayout(dt)
        elseif pin and pinInfo.explodeAnim then
            local layout = pinInfo.explodeAnim:GetLayout(dt)
            -- if done with anim, delete it
            if layout == nil then
                pinInfo.explodeAnim = nil
                return false
            end
            -- continue anim
            return layout
        else
            return false -- remove from renderer
        end
    end
end

local function toolLayout(toolClass)
    return {
        type = ui.TYPE.Image,
        props = {
            relativePosition = util.vector2(0.5, 0.5),
            anchor           = util.vector2(0.5, 0.5),
            size             = const.PinSize / 2,
            resource         = templates.toolTextures[toolClass],
            color            = const.ToolColors.icon
        }
    }
end

local toolPinIconLayouts = {
    [PinClass.ALEMBIC] = toolLayout(const.ToolClass.ALEMBIC),
    [PinClass.RETORT] = toolLayout(const.ToolClass.RETORT),
    [PinClass.CALCINATOR] = toolLayout(const.ToolClass.CALCINATOR)
}

---@param pinID number
---@return fun(dt:number, id:number): table|boolean
function PlayWindow:_getToolPinLayouter(pinID)
    return function(dt, id)
        local gs = self.gameState
        if not gs then return false end

        local pinInfo      = gs.pins[pinID]
        local pin          = gs.physics.pins[pinID]
        local hitThisFrame = pinInfo.hit
        pinInfo.hit        = false

        if pin and not pinInfo.popped then
            return {
                type    = ui.TYPE.Image,
                props   = {
                    position = pin.position,
                    anchor   = util.vector2(0.5, 0.5),
                    size     = const.PinSize,
                    resource = templates.ballTexture,
                    color    = const.ToolColors.default,
                },
                content = ui.content {
                    toolPinIconLayouts[pinInfo.class],
                    {
                        type  = ui.TYPE.Image,
                        props = {
                            anchor           = util.vector2(0.5, 0.5),
                            relativePosition = util.vector2(0.5, 0.5),
                            size             = const.PinSize,
                            resource         = templates.shadeTexture,
                            color            = hitThisFrame and const.HitFlashColor or const.ToolColors.highlight
                        },
                    },
                }
            }
        elseif pin and pinInfo.popped and not pinInfo.explodeAnim then
            pinInfo.explodeAnim = makeExplodeAnim({
                anchor = util.vector2(0.5, 0.5),
                position = pin.position,
                size = const.PinSize * 8,
                color = const.ToolColors.highlight,
            })
            return pinInfo.explodeAnim:GetLayout(dt)
        elseif pin and pinInfo.explodeAnim then
            local layout = pinInfo.explodeAnim:GetLayout(dt)
            -- if done with anim, delete it
            if layout == nil then
                pinInfo.explodeAnim = nil
                return false
            end
            -- continue anim
            return layout
        else
            return false -- remove from renderer
        end
    end
end

---Returns a per-frame layout closure for a non-EFFECT (buffer / tool) pin.
---@return fun(dt:number, id:number): table|boolean
function PlayWindow:_getBufferPinLayouter()
    return function(dt, id)
        local gs = self.gameState
        if not gs then return false end
        local ppin = gs.physics.pins[id]
        if ppin and not gs.pins[id].popped then
            return {
                type  = ui.TYPE.Image,
                props = {
                    position = ppin.position,
                    anchor   = util.vector2(0.5, 0.5),
                    size     = const.BallSize,
                    resource = templates.bufferPinTexture,
                },
            }
        else
            return false -- remove from renderer
        end
    end
end

---Returns a per-frame layout closure for a ball.
---@param ballID number
---@return fun(dt:number, id:number): table|boolean
function PlayWindow:_getBallLayouter(ballID)
    return function(dt, id)
        local gs = self.gameState
        if not gs then return false end
        local ball = gs.physics.balls[ballID]
        if ball then
            return {
                type  = ui.TYPE.Image,
                props = {
                    position = ball.position,
                    anchor   = util.vector2(0.5, 0.5),
                    size     = const.BallSize,
                    resource = templates.ballTexture,
                },
            }
        else
            return false -- remove from renderer
        end
    end
end

------------------------------------------------------------------------
-- Board + window initialisation
------------------------------------------------------------------------

---Initialises game state, populates the board with pins, and opens the UI window.
---@param ingredients ActualizedIngredient[]
---@param toolStrengths {[ToolClass]:number}
---@param desiredMagicEffectWithParams MagicEffectWithParams
function PlayWindow:_init(ingredients, toolStrengths, desiredMagicEffectWithParams)
    local physicsContainer  = physics.new(
        const.BoardSize + util.vector2(0, 1.5 * const.BallSize.y)
    )
    -- Render board
    self.shotAim            = util.vector2(1, 0)
    self.board              = renderBoard.new({
        mousePress = async:callback(function(data, elem)
            if self.gameState and self.gameState.currentState == PlayStateClass.TARGET_SELECTION then
                if data.button == 1 then
                    ambient.playSound("menu click")
                    self.shotAim = (data.offset - const.ShootPosition):normalize()
                    self:_shootBall(self.shotAim)
                end
            end
        end),
        mouseMove = async:callback(function(data, elem)
            if self.gameState and self.gameState.currentState == PlayStateClass.TARGET_SELECTION and self.trajectoryRenderer then
                self.shotAim = (data.offset - const.ShootPosition):normalize()
            end
        end),
    })
    self.trajectoryRenderer = trajectory.new(const.BoardSize)

    -- Game state
    local gs                = {
        isPotion                        = true,
        ballID                          = 1,
        currentState                    = PlayStateClass.TARGET_SELECTION,
        actualizedIngredients           = ingredients,
        magicEffectsWithParams          = {},
        desiredMagicEffectWithParamsIdx = 0,
        physics                         = physicsContainer,
        pins                            = {},
        toolStrengths                   = toolStrengths,
    }
    self.gameState          = gs

    gs.physics.onEdgeHit    = function(ballId, edge) self:_onEdgeHit(ballId, edge) end
    gs.physics.onPinHit     = function(ballId, pinId) self:_onPinHit(ballId, pinId) end

    gs.ingredientInfos      = ingredientInfo.new(gs.actualizedIngredients)

    local recs              = {}
    for _, obj in ipairs(gs.actualizedIngredients) do
        table.insert(recs, obj.record)
    end
    gs.magicEffectsWithParams = common.getMagicEffectsFromIngredients(recs)

    local idxOfDesired = search.contains(gs.magicEffectsWithParams, function(item)
        return common.magicEffectsEqual(desiredMagicEffectWithParams, item)
    end)
    if not idxOfDesired then error("effect not found") end
    settings.debugPrint("found " .. tostring(#gs.magicEffectsWithParams) .. " effects")
    gs.desiredMagicEffectWithParamsIdx = idxOfDesired
    gs.effectScores = effectScore.new(gs.magicEffectsWithParams, idxOfDesired)

    -- Pin counts
    local playerAlchemyFactor = util.remap(
        util.clamp(pself.type.stats.skills.alchemy(pself).modified, 0, 130), 0, 130, 1, 1.5)
    local replaceChance = util.remap(
        util.clamp(playerAlchemyFactor * toolStrengths[const.ToolClass.MORTAR], 0.5, 3), 0.5, 3, 0, 0.95)

    ---@type {[number]:number}
    local effectPinCounts = {}
    for idx, _ in ipairs(gs.magicEffectsWithParams) do
        if idx == gs.desiredMagicEffectWithParamsIdx then
            effectPinCounts[idx] = math.ceil(const.PinsPerEffect * 1.5)
        else
            for _ = 1, const.PinsPerEffect, 1 do
                local target = math.random() < replaceChance and gs.desiredMagicEffectWithParamsIdx or idx
                effectPinCounts[target] = (effectPinCounts[target] or 0) + 1
            end
        end
    end

    ---@type {[PinClass]:number}
    local toolPinCounts = {
        [PinClass.ALEMBIC]    = math.ceil(2 * gs.toolStrengths[const.ToolClass.ALEMBIC]),
        [PinClass.CALCINATOR] = math.ceil(2 * gs.toolStrengths[const.ToolClass.CALCINATOR]),
        [PinClass.RETORT]     = gs.toolStrengths[const.ToolClass.RETORT] and 1 or 0,
    }

    local totalPins = 0
    for _, count in pairs(effectPinCounts) do totalPins = totalPins + count end
    for _, count in pairs(toolPinCounts) do totalPins = totalPins + count end

    local topOffset          = util.vector2(0, 0.15)
    local midTopOffsetBorder = const.BoardSize:emul(util.vector2(0, topOffset.y))
    local potentialSpots     = placepins(
        const.BoardSize:emul(util.vector2(1, 1 - topOffset.y)), const.PinRadius, totalPins)

    local nextPinID          = 100
    local resChance          = self:_resilientChance()

    local function addPin(pin)
        if pin.ID == 0 then
            pin.ID    = nextPinID
            nextPinID = nextPinID + 1
        end
        if gs.pins[pin.ID] then error("pin ID already taken") end
        local position = table.remove(potentialSpots)
        if not position then
            settings.debugPrint("no space for pin " .. tostring(pin.ID))
            return
        end
        gs.pins[pin.ID] = pin
        gs.physics:addPin(pin.ID, position + midTopOffsetBorder, 0.9, const.PinRadius)
        self:_register_pin_renderer(pin)
    end

    local function newPin(class, effectIdx, resilient)
        return {
            ID                       = 0,
            class                    = class,
            magicEffectWithParamsIdx = effectIdx,
            hit                      = false,
            popped                   = false,
            resilient                = resilient,
        }
    end

    for idx, count in pairs(effectPinCounts) do
        for _ = 1, count do addPin(newPin(PinClass.EFFECT, idx, math.random() < resChance)) end
    end
    for class, count in pairs(toolPinCounts) do
        for _ = 1, count do addPin(newPin(class, nil, false)) end
    end

    -- UI window
    self.window = ui.create({
        layer    = "Windows",
        type     = ui.TYPE.Container,
        template = interfaces.MWUI.templates.boxTransparent,
        props    = {
            anchor           = util.vector2(0.5, 0.5),
            relativePosition = util.vector2(0.5, 0.5),
        },
        content  = ui.content {
            {
                type    = ui.TYPE.Flex,
                props   = {
                    horizontal = true,
                    align      = ui.ALIGNMENT.Center,
                    arrange    = ui.ALIGNMENT.Center,
                },
                content = ui.content {
                    {
                        type = ui.TYPE.Container,
                        template = interfaces.MWUI.templates.box,
                        props = {
                            size = const.BoardSize,
                            visible = true,
                        },
                        content = ui.content {
                            {
                                name = "board",
                                type = ui.TYPE.Widget,
                                props = {
                                    size = const.BoardSize,
                                },
                                content = ui.content {
                                    self.trajectoryRenderer.element,
                                    self.board.boardElement,
                                }
                            },
                        }
                    },
                    {
                        type    = ui.TYPE.Flex,
                        props   = {
                            horizontal = false,
                            align      = ui.ALIGNMENT.Center,
                            arrange    = ui.ALIGNMENT.Center,
                        },
                        content = ui.content {
                            gs.ingredientInfos.element,
                            gs.effectScores.element,
                        },
                    },
                },
            },
        },
    })
end

------------------------------------------------------------------------
-- Shot mechanics
------------------------------------------------------------------------

---Spawns a ball at the top of the board with the given velocity vector.
---@param directionVec Vector2
function PlayWindow:_shootBall(directionVec)
    local gs = self.gameState
    if not gs then
        error("_shootBall(): gameState is nil")
    end
    if gs.currentState ~= PlayStateClass.TARGET_SELECTION then
        error("_shootBall(): not in TARGET_SELECTION state")
    end
    settings.debugPrint("shooting ball: " .. tostring(directionVec))
    gs.ballID = gs.ballID + 1
    local ballID = gs.ballID
    gs.physics:addBall(ballID, const.ShootPosition, directionVec * const.ShootVelocity, 1, 1, const.BallRadius)
    self.board.balls:AddRenderable({
        layout = self:_getBallLayouter(ballID),
    })
    self.trajectoryRenderer:clearTrajectory()
    self.trajectoryRenderer:onFrame()
    gs.currentState = PlayStateClass.PHYSICS_SIMULATION
end

local stickDeadzone = 0.3
local keys          = {
    left  = keytrack.NewKey("left", function(dt)
        return input.isKeyPressed(input.KEY.LeftArrow) or
            (input.getAxisValue(input.CONTROLLER_AXIS.RightX) < -1 * stickDeadzone)
    end),
    right = keytrack.NewKey("right", function(dt)
        return input.isKeyPressed(input.KEY.RightArrow) or
            (input.getAxisValue(input.CONTROLLER_AXIS.RightX) > stickDeadzone)
    end),
    enter = keytrack.NewKey("enter", function(dt)
        return input.isKeyPressed(input.KEY.Enter) or
            (input.isControllerButtonPressed(input.CONTROLLER_BUTTON.A))
    end),
}

------------------------------------------------------------------------
-- Per-state update handlers
------------------------------------------------------------------------

---@param v Vector2
---@param theta number
---@return Vector2
local function rotateClockwise(v, theta)
    local c = math.cos(theta)
    local s = math.sin(theta)
    return util.vector2(
        v.x * c + v.y * s,
        -v.x * s + v.y * c
    )
end

function PlayWindow:_targetSelection(dt)
    if keys.enter.rise then
        ambient.playSound("menu click")
        self:_shootBall(self.shotAim)
        return
    end

    local leftRight = keys.right.analog - keys.left.analog
    self.shotAim = rotateClockwise(self.shotAim, dt * leftRight * const.ControllerAimSensitivity):normalize()

    local vel = self.shotAim * const.ShootVelocity
    local points = self.gameState.physics:sampleTrajectory(const.ShootPosition, vel, 20, 18)
    self.trajectoryRenderer:setTrajectory(points)
    self.trajectoryRenderer:onFrame(dt)
    resilientShine:GetLayout(dt) -- advance shared animations
    self.board:onFrame(dt)
    self.window:update()
end

function PlayWindow:_physicsSimulation(dt)
    if not self.gameState then
        error("_physicsSimulation(): gameState is nil")
    end
    self.gameState.physics:advanceSimulation(dt)
    resilientShine:GetLayout(dt) -- advance shared animations
    self.board:onFrame(dt)
    self.window:update()
end

function PlayWindow:close()
    self.gameState = nil
    if self.board then
        self.board:reset()
        self.board = nil
    end
    if self.window then
        self.window:destroy()
        self.window = nil
    end
end

function PlayWindow:_shotDone(dt)
    settings.debugPrint("shot done")

    local scores = {}
    for _, mewp in ipairs(self.gameState.effectScores.scores) do
        local floorScore = math.floor(mewp.score)
        if floorScore > 0 then
            table.insert(scores, {
                effect = mewp.magicEffectParams,
                score = floorScore,
                primary = mewp.primary
            })
        end
    end
    settings.debugPrint("Shot scores: " .. aux_util.deepToString(scores, 3))

    self:close()

    -- TODO: forward effect score results to doneCallback
    if self.doneCallback then self.doneCallback(scores) end
end

------------------------------------------------------------------------
-- Public API
------------------------------------------------------------------------

---Must be called from the global onFrame handler every frame.
function PlayWindow:onFrame()
    if not self.gameState then return end
    local dt = core.getRealFrameDuration()


    -- Track inputs.
    for _, inp in pairs(keys) do
        inp:update(dt)
    end

    local state = self.gameState.currentState
    if state == PlayStateClass.TARGET_SELECTION then
        self:_targetSelection(dt)
    elseif state == PlayStateClass.PHYSICS_SIMULATION then
        self:_physicsSimulation(dt)
    elseif state == PlayStateClass.SHOT_DONE then
        self:_shotDone(dt)
    end
    -- Post-update sub-system frames (guard: _shotDone may have cleared gameState)
    if self.gameState then
        self.gameState.effectScores:onFrame(dt)
        self.gameState.ingredientInfos:onFrame(dt)
    end
end

------------------------------------------------------------------------
-- Module export
------------------------------------------------------------------------

return PlayWindow
