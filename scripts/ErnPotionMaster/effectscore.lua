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

local MOD_NAME     = require("scripts.ErnPotionMaster.ns")
local const        = require("scripts.ErnPotionMaster.const")
local ui           = require("openmw.ui")
local util         = require("openmw.util")
local pself        = require("openmw.self")
local core         = require("openmw.core")
local types        = require("openmw.types")
local placepins    = require("scripts.ErnPotionMaster.placepins")
local settings     = require("scripts.ErnPotionMaster.settings.settings")
local physics      = require("scripts.ErnPotionMaster.physics.pachinko")
local interfaces   = require('openmw.interfaces')
local shuffle      = require("scripts.ErnPotionMaster.shuffle")
local aux_util     = require('openmw_aux.util')
local renderBoard  = require("scripts.ErnPotionMaster.render.board")
local colorutil    = require("scripts.ErnPotionMaster.colorutil")
local myui         = require("scripts.ErnPotionMaster.pcp.myui")
local templates    = require("scripts.ErnPotionMaster.render.templates")
local localization = core.l10n(MOD_NAME)
local common       = require("scripts.ErnPotionMaster.common")

---@class MagicEffectWithParams any This is a openmw.core#MagicEffectWithParams
---@field affectedAttribute string
---@field affectedSkill string
---@field id string
---@field effect table

---@class EffectScore
---@field magicEffectParams MagicEffectWithParams This is a openmw.core#MagicEffectWithParams
---@field score number The running score for this effect. Persists across shots.
---@field multiplier number The multiplier for each hit this shot. Resets between shots.
---@field deltaVFX number A decaying-to-zero value used for special VFX.
---@field primary boolean

---comment
---@param value number
---@param color Color
---@param length number
---@return table
local function barLayout(value, color, length)
    return {
        type = ui.TYPE.Widget,
        name = 'bar',
        template = interfaces.MWUI.templates.borders,
        props = {
            size = util.vector2(length, 24)
        },
        content = ui.content {
            {
                type = ui.TYPE.Image,
                name = 'barContainer',
                props = {
                    resource = ui.texture { path = 'white' },
                    relativePosition = util.vector2(0, 0),
                    relativeSize = util.vector2(1, 1),
                    alpha = 0.5,
                    color = value < 1 and util.color.rgb(0.1, 0.1, 0.1) or color,
                },
                events = {},
            },
            {
                type = ui.TYPE.Image,
                name = 'barFill',
                props = {
                    resource = ui.texture { path = 'Textures/ErnPotionMaster/horz_gradient.dds' },
                    anchor = util.vector2(0, 0),
                    --relativePosition = util.vector2(0, 1),
                    relativeSize = util.vector2(value - math.floor(value), 1),
                    --alpha = 0.5,
                    color = color,
                },
            },
            {
                --template = interfaces.MWUI.templates.textHeader,
                type = ui.TYPE.Text,
                props = {
                    text = (value > 1000) and string.format("%e", value) or tostring(math.floor(value)),
                    textColor = const.HitFlashColor,
                    textShadow = true,
                    textAlignV = ui.ALIGNMENT.Center,
                    textAlignH = ui.ALIGNMENT.Center,
                    relativePosition = util.vector2(0.5, 0.5),
                    anchor = util.vector2(0.5, 0.5),
                    textSize = 16
                },
            },
        }
    }
end

local effectIconSize = util.vector2(16, 16)

local attributes = core.stats.Attribute.records
local skills = core.stats.Skill.records



---comment
---@param effectScore EffectScore
---@return table
local function effectScoreLayout(effectScore)
    if not effectScore.magicEffectParams.effect then
        error("nil effect: " .. aux_util.deepToString(effectScore.magicEffectParams, 4))
    end

    local color = const.MagickColors[effectScore.magicEffectParams.effect.school].default or
        const.MagickColors.unknown.default

    local text
    if effectScore.magicEffectParams.affectedAttribute then
        text = localization("effectWithParam", {
            effectName = effectScore.magicEffectParams.effect.name,
            effectParam = attributes[effectScore.magicEffectParams.affectedAttribute].name
        })
    elseif effectScore.magicEffectParams.affectedSkill then
        text = localization("effectWithParam", {
            effectName = effectScore.magicEffectParams.effect.name,
            effectParam = skills[effectScore.magicEffectParams.affectedSkill].name
        })
    else
        text = effectScore.magicEffectParams.effect.name
    end

    return {
        type = ui.TYPE.Flex,
        props = {
            arrange = ui.ALIGNMENT.Start,
            horizontal = false,
            autoSize = true,
        },
        external = {
            scale = 1,
        },
        content = ui.content {
            myui.padWidget(const.Padding, const.Padding),
            {
                type = ui.TYPE.Flex,
                props = {
                    arrange = ui.ALIGNMENT.Center,
                    align = ui.ALIGNMENT.Center,
                    horizontal = true,
                    autoSize = true,
                    --relativeSize = util.vector2(1, 0.2),
                    --size = util.vector2(0, const.EffectScorePaneSize.y)
                    --size = util.vector2(const.EffectScorePaneSize.x, 64),
                    -- myui.padWidget(const.EffectScorePaneSize.x, 0)
                },
                content = ui.content {
                    {
                        type = ui.TYPE.Image,
                        props = {
                            resource = ui.texture {
                                path = effectScore.magicEffectParams.effect.icon
                            },
                            size = effectIconSize
                        },
                    },
                    myui.padWidget(const.Padding, const.Padding),
                    {
                        --template = interfaces.MWUI.templates.textHeader,
                        type = ui.TYPE.Text,
                        props = {
                            text = text,
                            textColor = colorutil.lerpColor(myui.interactiveTextColors.normal.default, const.HitFlashColor, util.clamp(effectScore.deltaVFX, 0, 1)),
                            textAlignV = ui.ALIGNMENT.Center,
                            textSize = 18,
                            --anchor = util.vector2(0.5, 0),
                        },
                    },
                },
            },
            barLayout(effectScore.score,
                color,
                const.EffectScorePaneSize.x),
            myui.padWidget(const.Padding, const.Padding),
        }
    }
end

---@class EffectScoreContainer
---@field scores EffectScore[]
---@field element any a UI element
---@field _dirty boolean
---@field modifyEffectScore fun(self: EffectScoreContainer, magicEffect : MagicEffectWithParams, modFn: fun(original:EffectScore): EffectScore?)

local EffectScoreContainer   = {}
EffectScoreContainer.__index = EffectScoreContainer

function EffectScoreContainer:_layout()
    local contents = {}

    for _, es in ipairs(self.scores) do
        table.insert(contents, effectScoreLayout(es))
    end

    return {
        type = ui.TYPE.Flex,
        name = "effectScoresColumn",
        props = {
            horizontal = false,
            align = ui.ALIGNMENT.Start,
            arrange = ui.ALIGNMENT.Start,
            size = const.EffectScorePaneSize,
            --autoSize = false,
        },
        content = ui.content(contents)
    }
end

---@param mewp MagicEffectWithParams
---@param primary boolean
---@return EffectScore
local function makeNewScore(mewp, primary)
    return { magicEffectParams = mewp, score = 0, multiplier = 0, deltaVFX = 0, primary = primary }
end

---@param initial MagicEffectWithParams[]
---@param idxOfDesired number
---@return EffectScoreContainer
function EffectScoreContainer.new(initial, idxOfDesired)
    local self = setmetatable({}, EffectScoreContainer)

    self.scores = {}
    for i, mewp in pairs(initial or {}) do
        table.insert(self.scores, makeNewScore(mewp, i == idxOfDesired))
    end

    self._dirty = false
    local layout = self:_layout()
    settings.debugPrint(aux_util.deepToString(layout, 3))
    self.element = ui.create(layout)

    return self
end

---comment
---@param magicEffectParams MagicEffectWithParams
---@param modFn fun(original:EffectScore): EffectScore? return falsey to remove it
function EffectScoreContainer:modifyEffectScore(magicEffectParams, modFn)
    if not magicEffectParams then
        error("modifyEffectScore(): magicEffect is nil")
    end
    if not magicEffectParams.effect then
        error("magicEffectParams.effect is nil: " .. aux_util.deepToString(magicEffectParams, 4))
    end
    self._dirty = true
    local found = false
    --- find the matching effect, if any

    ---@param es EffectScore
    for idx, es in ipairs(self.scores) do
        if common.magicEffectsEqual(es.magicEffectParams, magicEffectParams) then
            local newScore = modFn(es)
            if newScore then
                newScore.deltaVFX = 1
                if not newScore.magicEffectParams.effect then
                    error("newScore.magicEffectParams.effect is nil: " ..
                        aux_util.deepToString(newScore.magicEffectParams, 4))
                end
                settings.debugPrint("modifying effectScore " .. tostring(es.magicEffectParams.id))
                self.scores[idx] = newScore
            else
                settings.debugPrint("deleting effectScore " .. tostring(es.magicEffectParams.id))
                table.remove(self.scores, idx)
            end
            found = true
            break
        end
    end
    if not found then
        error("effect not found: " .. tostring(magicEffectParams.id))
    end
end

local DELTA_VFX_DECAY = 0.5

---@param dt number
function EffectScoreContainer:onFrame(dt)
    local decay = DELTA_VFX_DECAY * dt
    local stillDecaying = false

    for idx, es in ipairs(self.scores) do
        if self.scores[idx] then
            es.deltaVFX = util.clamp(es.deltaVFX, -1, 1)
            if es.deltaVFX == 0 then
                --no-op
            elseif math.abs(es.deltaVFX) <= DELTA_VFX_DECAY then
                stillDecaying = true
                self.scores[idx].deltaVFX = 0
            elseif es.deltaVFX > 0 then
                stillDecaying = true
                self.scores[idx].deltaVFX = es.deltaVFX - decay
            else
                stillDecaying = true
                self.scores[idx].deltaVFX = es.deltaVFX + decay
            end
        end
    end
    self._dirty = stillDecaying or self._dirty
    if self._dirty then
        self.element.layout = self:_layout()
        self.element:update()
        self._dirty = false
    end
end

return EffectScoreContainer
