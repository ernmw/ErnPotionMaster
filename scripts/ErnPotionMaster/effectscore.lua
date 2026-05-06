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

local MOD_NAME               = require("scripts.ErnPotionMaster.ns")
local const                  = require("scripts.ErnPotionMaster.const")
local ui                     = require("openmw.ui")
local util                   = require("openmw.util")
local pself                  = require("openmw.self")
local core                   = require("openmw.core")
local types                  = require("openmw.types")
local placepins              = require("scripts.ErnPotionMaster.placepins")
local settings               = require("scripts.ErnPotionMaster.settings.settings")
local physics                = require("scripts.ErnPotionMaster.physics.pachinko")
local interfaces             = require('openmw.interfaces')
local shuffle                = require("scripts.ErnPotionMaster.shuffle")
local aux_util               = require('openmw_aux.util')
local renderBoard            = require("scripts.ErnPotionMaster.render.board")
local templates              = require("scripts.ErnPotionMaster.render.templates")

---@class MagicEffectWithParams any This is a openmw.core#MagicEffectWithParams
---@field affectedAttribute string
---@field affectedSkill string
---@field id string
---@field effect table

---@class EffectScore
---@field magicEffect MagicEffectWithParams This is a openmw.core#MagicEffectWithParams
---@field score number The running score for this effect. Persists across shots.
---@field multiplier number The multiplier for each hit this shot. Resets.

---@class EffectScoreContainer
---@field scores EffectScore[]
---@field modifyEffectScore fun(self: EffectScoreContainer, magicEffect : MagicEffectWithParams, modFn: fun(original:EffectScore): EffectScore?)

local EffectScoreContainer   = {}
EffectScoreContainer.__index = EffectScoreContainer

---@return EffectScoreContainer
function EffectScoreContainer.new()
    local self = setmetatable({}, EffectScoreContainer)

    self.scores = {}

    return self
end

---comment
---@param magicEffect MagicEffectWithParams
---@param modFn fun(original:EffectScore): EffectScore? return falsey to remove it
function EffectScoreContainer:modifyEffectScore(magicEffect, modFn)
    if not magicEffect then
        error("modifyEffectScore(): magicEffect is nil")
    end
    local found = false
    --- find the matching effect, if any
    for idx, effect in ipairs(self.scores) do
        if effect.magicEffect.affectedAttribute == magicEffect.affectedAttribute and
            effect.magicEffect.affectedSkill == magicEffect.affectedSkill and
            effect.magicEffect.id == magicEffect.id then
            local newScore = modFn(effect)
            if newScore then
                settings.debugPrint("modifying effectScore " .. tostring(effect.magicEffect.id))
                self.scores[idx] = newScore
            else
                settings.debugPrint("deleting effectScore " .. tostring(effect.magicEffect.id))
                table.remove(self.scores, idx)
            end
            found = true
            break
        end
    end
    if not found then
        local newScore = modFn({ magicEffect = magicEffect, score = 0, multiplier = 0 })
        if newScore then
            settings.debugPrint("adding new effectScore " .. tostring(newScore.magicEffect.id))
            table.insert(self.scores, newScore)
        end
    end
end

return EffectScoreContainer
