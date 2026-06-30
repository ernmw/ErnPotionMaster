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


local MOD_NAME = require("scripts.ErnPotionMaster.ns")
local types    = require('openmw.types')
local core     = require('openmw.core')
local world    = require('openmw.world')
local common   = require("scripts.ErnPotionMaster.common")

--- This file handles converting magic effect scores into potion records.

--- table of "hash" -> potion recordid
local recipes  = {}

---@param score BakedScore
local function potionNameFromScore(score)
    -- build a potion name based on the highest-scoring effect.
    -- this is a placeholder.
    return "Potion of " .. tostring(score.effect.id)
end

---@param score BakedScore
local function hashScore(score)
    return table.concat(
        { score.effect.id, score.effect.affectedAttribute or "_",
            score.effect.affectedSkill or "_", score.score, score.primary },
        ",")
end

---@param scores BakedScore[]
local function hashScores(scores)
    local out = {}
    for _, score in ipairs(scores) do
        table.insert(out, hashScore(score))
    end
    table.sort(out)
    return out
end

---@param score BakedScore
local function getEffectFromScore(score)

end



---@param scores BakedScore[]
local function newPotionRecordDraft(scores)
    --- this should be cached, and persistent across the entire playthrough.
    --- that will allow me to consistently stack identical potions.

    local effectMap = {}
    for idx, score in ipairs(scores) do
        effectMap[idx] = core.magic.effects.records[score.effect.id]
        if not effectMap[idx] then
            error("Unknown effect: " .. tostring(score.effect.id))
            return
        end
    end

    local template = {
        icon = "",
        isAutocalc = false,
        model = "",
        name = "placeholder",
        value = 0,
        effects = {}
    }

    local positiveEffects = {}
    local negativeEffects = {}
    local desiredEffect = nil
    local effects = {}
    local highestScoreIdx = 1
    for idx, score in ipairs(scores) do
        if scores[highestScoreIdx].score < score.score then
            highestScoreIdx = idx
        end
        if effectMap[idx].harmful then
            table.insert(negativeEffects, score)
        else
            table.insert(positiveEffects, score)
        end
        if score.primary then
            desiredEffect = score
        end
    end

    -- multiply score by base cost to get gold value
    local highestScoreEffect = core.magic.effects.records[highestScore.effect.id]
    template.value = math.ceil(highestScore * math.max(1, highestScoreEffect.baseCost) *
        (highestScoreEffect.harmful and 0.3 or 1))

    template.name = potionNameFromScore(highestScore)


    return types.Potion.createRecordDraft(template)
end

---@param scores BakedScore[]
local function getPotionRecord(scores)
    local hash = hashScores(scores)
    if recipes[hash] then
        return types.Potion.record(recipes[hash])
    end

    local draft = newPotionRecordDraft(scores)
    recipes[hash] = draft.id

    return draft
end

local function onLoad(data)
    if data then
        recipes = data
    end
end
local function onSave()
    return recipes
end

return {
    eventHandlers = {
        onLoad = onLoad,
        onSave = onSave,
    },
}
