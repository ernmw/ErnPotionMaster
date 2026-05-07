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
local myui         = require("scripts.ErnPotionMaster.pcp.myui")
local templates    = require("scripts.ErnPotionMaster.render.templates")
local localization = core.l10n(MOD_NAME)

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

local function barLayout(ratio, relativeLength)
    return {
        type = ui.TYPE.Widget,
        name = 'bar',
        template = interfaces.MWUI.templates.borders,
        props = {
            relativeSize = util.vector2(relativeLength or 1, 0),
            size = util.vector2(0, 8)
        },
        content = ui.content {
            {
                type = ui.TYPE.Image,
                name = 'barContainer',
                props = {
                    resource = ui.texture { path = 'white' },
                    relativePosition = util.vector2(0, 0),
                    relativeSize = util.vector2(1, 1),
                    alpha = 0.7,
                    color = util.color.rgb(0.1, 0.1, 0.1),
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
                    relativeSize = util.vector2(ratio, 1),
                    alpha = 0.7,
                    color = myui.textColors.magic_fill,
                },
            },
        }
    }
end

local effectIconSize = util.vector2(16, 16)

---comment
---@param effectScore EffectScore
---@return table
local function effectScoreLayout(effectScore)
    if not effectScore.magicEffectParams.effect then
        error("nil effect: " .. aux_util.deepToString(effectScore.magicEffectParams, 4))
    end

    return {
        type = ui.TYPE.Flex,
        props = {
            arrange = ui.ALIGNMENT.Start,
            horizontal = true,
            autoSize = true,
            --relativeSize = util.vector2(1, 0.2),
            --size = util.vector2(0, const.EffectScorePaneSize.y)
            --size = util.vector2(const.EffectScorePaneSize.x, 64),
            -- myui.padWidget(const.EffectScorePaneSize.x, 0)
        },
        external = {
            scale = 1,
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
            {
                template = interfaces.MWUI.templates.textHeader,
                type = ui.TYPE.Text,
                props = {
                    text = localization("effectScore", {
                        effectName = effectScore.magicEffectParams.effect.name,
                        --score = string.format("%.1f", effectScore.score)
                        score = math.floor(effectScore.score)
                    }),
                    textColor = myui.interactiveTextColors.normal.default,
                    textAlignV = ui.ALIGNMENT.Center,
                },
            },
        },
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

---@return EffectScoreContainer
function EffectScoreContainer.new()
    local self = setmetatable({}, EffectScoreContainer)

    self.scores = {}
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
    for idx, es in ipairs(self.scores) do
        if es.magicEffectParams.affectedAttribute == magicEffectParams.affectedAttribute and
            es.magicEffectParams.affectedSkill == magicEffectParams.affectedSkill and
            es.magicEffectParams.id == magicEffectParams.id then
            local newScore = modFn(es)
            if newScore then
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
        local newScore = modFn({ magicEffectParams = magicEffectParams, score = 0, multiplier = 0, deltaVFX = 0 })
        if newScore then
            if not newScore.magicEffectParams.effect then
                error("newScore.magicEffectParams.effect is nil: " ..
                aux_util.deepToString(newScore.magicEffectParams, 4))
            end
            settings.debugPrint("adding new effectScore " .. aux_util.deepToString(newScore, 3))
            table.insert(self.scores, newScore)
        end
    end
end

local DELTA_VFX_DECAY = 0.1

---@param dt number
function EffectScoreContainer:onFrame(dt)
    local decay = DELTA_VFX_DECAY * dt
    local stillDecaying = false

    for idx, es in ipairs(self.scores) do
        if self.scores[idx] then
            if math.abs(es.deltaVFX) <= DELTA_VFX_DECAY then
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
