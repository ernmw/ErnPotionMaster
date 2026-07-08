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


local MOD_NAME     = require("scripts.ErnPotionMaster.ns")
local types        = require('openmw.types')
local core         = require('openmw.core')
local world        = require('openmw.world')
local aux_util     = require('openmw_aux.util')
local util         = require('openmw.util')
local common       = require("scripts.ErnPotionMaster.common")
local localization = core.l10n(MOD_NAME)

--- This file handles converting magic effect scores into potion records.


local consts = {
    MAX_MAGNITUDE            = 200,
    MAX_DURATION             = 500,
    VALUE_SCALE              = 5,

    --- Multiplier applied to an effect's score to get its magnitude.
    --- Magnitude min and max are always set equal to each other, since the
    --- minigame produces a single, precise score rather than a random range.
    MAGNITUDE_SCALE          = 10.0,

    --- Multiplier applied to an effect's score to get its duration, in seconds.
    DURATION_SCALE           = 25.0,

    --- Effects with a magnitude are never generated below this value.
    MIN_MAGNITUDE            = 1,

    --- Effects with a duration are never generated below this value.
    MIN_DURATION             = 1,

    --- Gold value is (topScore.score * effect.baseCost), clamped so that
    --- an effect with a very low baseCost still contributes something, then
    --- multiplied by HARMFUL_VALUE_MULTIPLIER if the top-scoring effect is
    --- harmful (poisons are worth less than beneficial potions of the same
    --- strength).
    HARMFUL_VALUE_MULTIPLIER = 0.3,
    MIN_EFFECTIVE_BASE_COST  = 1,
}

---@class BakedScore
---@field effect { id: string, affectedAttribute: string?, affectedSkill: string? } plain, serializable subset of a MagicEffectWithParams
---@field score number
---@field primary boolean


--- Value thresholds used to pick a mesh/icon "quality tier" for the
--- generated potion, cheapest first. The last entry's maxValue should be
--- math.huge so every value has a match.
---@type { maxValue: number, model: string, icon: string }[]
local VALUE_TIERS              = {
    { maxValue = 10,        model = "meshes\\m\\Misc_Potion_Bargain_01.nif",   icon = "textures\\icons\\m\\tx_potion_bargain_01.dds" },
    { maxValue = 25,        model = "meshes\\m\\Misc_Potion_Cheap_01.nif",     icon = "textures\\icons\\m\\tx_potion_cheap_01.dds" },
    { maxValue = 50,        model = "meshes\\m\\Misc_Potion_Fresh_01.nif",     icon = "textures\\icons\\m\\tx_potion_fresh_01.dds" },
    { maxValue = 100,       model = "meshes\\m\\Misc_Potion_Standard_01.nif",  icon = "textures\\icons\\m\\tx_potion_standard_01.dds" },
    { maxValue = 250,       model = "meshes\\m\\Misc_Potion_Quality_01.nif",   icon = "textures\\icons\\m\\tx_potion_quality_01.dds" },
    { maxValue = math.huge, model = "meshes\\m\\Misc_Potion_Exclusive_01.nif", icon = "textures\\icons\\m\\tx_potion_exclusive_01.dds" },
}

------------------------------------------------------------------------

--- table of "hash" -> potion recordid
---@type { [string]: string }
local recipes                  = {}

--- Effect ids whose generic record name (e.g. "Damage Attribute") is just
--- a verb plus a placeholder -- these should have the placeholder replaced
--- with the actual attribute/skill name (e.g. "Damage Personality") so the
--- potion name says what it actually does.
local attributes               = core.stats.Attribute.records
local skills                   = core.stats.Skill.records
local VERB_PLACEHOLDER_EFFECTS = {
    --- TODO: this map is not necessary. you can just check if effect.affectedAttribute and effect.affectedSkill are nil.
    [core.magic.EFFECT_TYPE.DrainAttribute] = true,
    [core.magic.EFFECT_TYPE.DrainSkill] = true,
    [core.magic.EFFECT_TYPE.DamageAttribute] = true,
    [core.magic.EFFECT_TYPE.DamageSkill] = true,
    [core.magic.EFFECT_TYPE.RestoreAttribute] = true,
    [core.magic.EFFECT_TYPE.RestoreSkill] = true,
    [core.magic.EFFECT_TYPE.FortifyAttribute] = true,
    [core.magic.EFFECT_TYPE.FortifySkill] = true,
}

---@param score BakedScore
---@param effectRecord table core.magic.effects.records[...] entry
---@return string
local function effectDisplayName(score, effectRecord)
    if VERB_PLACEHOLDER_EFFECTS[effectRecord.id] then
        local paramName
        if score.effect.affectedAttribute then
            paramName = attributes[score.effect.affectedAttribute].name
        elseif score.effect.affectedSkill then
            paramName = skills[score.effect.affectedSkill].name
        end
        if paramName then
            -- effectRecord.name is e.g. "Damage Attribute" -- the verb is
            -- always its first word. Swap in the real attribute/skill name
            -- for the generic placeholder, e.g. "Damage Personality".
            local verb = effectRecord.name:match("^(%S+)") or effectRecord.name
            return verb .. " " .. paramName
        end
    end
    return effectRecord.name
end

---@param score BakedScore
---@param effectRecord table core.magic.effects.records[...] entry
---@return string
local function potionNameFromScore(score, effectRecord)
    local key = effectRecord.harmful and "poisonName" or "potionName"
    return localization(key, { effectName = effectDisplayName(score, effectRecord) })
end

---@param value number
---@return { model: string, icon: string }
local function tierForValue(value)
    for _, tier in ipairs(VALUE_TIERS) do
        if value <= tier.maxValue then
            return tier
        end
    end
    -- Should be unreachable since the last tier's maxValue is math.huge.
    return VALUE_TIERS[#VALUE_TIERS]
end

--- Builds the hash contribution of a single score.
--- If the underlying effect has neither magnitude nor duration (e.g. Cure
--- Disease), the score value can't actually change the resulting potion
--- effect, so it's deliberately left out of the hash: two brews that only
--- differ in score for such an effect should still be considered the same
--- recipe. Every other effect includes the score verbatim (no bucketing),
--- since a different score always means a different magnitude/duration
--- and therefore a genuinely different potion effect.
---@param score BakedScore
---@param effectRecord table core.magic.effects.records[...] entry
---@return string
local function hashScore(score, effectRecord)
    local parts = {
        score.effect.id,
        score.effect.affectedAttribute or "_",
        score.effect.affectedSkill or "_",
        tostring(score.primary),
    }
    if effectRecord.hasMagnitude or effectRecord.hasDuration then
        table.insert(parts, tostring(score.score))
    else
        table.insert(parts, "_")
    end
    return table.concat(parts, ",")
end

---@param scores BakedScore[]
---@param effectMap table[] parallel array of core.magic.effects.records entries, indexed the same as scores
---@return string
local function hashScores(scores, effectMap)
    local parts = {}
    for idx, score in ipairs(scores) do
        table.insert(parts, hashScore(score, effectMap[idx]))
    end
    table.sort(parts)
    return table.concat(parts, "|")
end

---@param scores BakedScore[]
---@return table[] effectMap parallel to scores, each entry is a core.magic.effects.records[...] entry
local function getEffectRecords(scores)
    local effectMap = {}
    for idx, score in ipairs(scores) do
        local effectRecord = core.magic.effects.records[score.effect.id]
        if not effectRecord then
            error("Unknown effect: " .. tostring(score.effect.id))
        end
        effectMap[idx] = effectRecord
    end
    return effectMap
end

--- Picks which BakedScore should be used to name the potion and to anchor
--- its gold value: the effect marked `primary` (the one the player was
--- aiming for) if there is one, otherwise whichever effect has the
--- highest score.
---@param scores BakedScore[]
---@param effectMap table[]
---@return number idx
local function pickAnchorIdx(scores, effectMap)
    local highestIdx = 1
    local primaryIdx = nil
    for idx, score in ipairs(scores) do
        if score.score > scores[highestIdx].score then
            highestIdx = idx
        end
        if score.primary then
            primaryIdx = idx
        end
    end
    return primaryIdx or highestIdx
end

local function easeInCirc(x)
    return 1 - math.sqrt(1 - math.pow(x, 2));
end

local function easeMax(x, max)
    return math.ceil(math.min(x / (1 + easeInCirc(x / max)), max))
end

---@param scores BakedScore[]
---@param effectMap table[]
---@return MagicEffectWithParams[]
local function buildEffectsList(scores, effectMap)
    local effects = {}
    for idx, score in ipairs(scores) do
        local effectRecord = effectMap[idx]

        ---@type MagicEffectWithParams
        local mewp = {
            id                = score.effect.id,
            affectedAttribute = score.effect.affectedAttribute,
            affectedSkill     = score.effect.affectedSkill,
            -- Potions only ever apply to the drinker, and never have area
            -- of effect.
            range             = core.magic.RANGE.Self,
            area              = 0,
        }

        local clampedCost = util.remap(util.clamp(effectRecord.baseCost, 1, 10), 1, 10, 0.8, 1.2)

        -- more duration or magnitude if one is missing
        local magScale = (effectRecord.hasDuration and consts.MAGNITUDE_SCALE or 2 * consts.MAGNITUDE_SCALE) /
            clampedCost
        local durScale = (effectRecord.hasMagnitude and consts.DURATION_SCALE or 2 * consts.DURATION_SCALE) / clampedCost



        if effectRecord.hasMagnitude then
            local magnitude = math.max(consts.MIN_MAGNITUDE, score.score * magScale)

            magnitude = easeMax(magnitude, consts.MAX_MAGNITUDE)

            mewp.magnitudeMin = magnitude
            mewp.magnitudeMax = magnitude
        end

        if effectRecord.hasDuration then
            mewp.duration = math.max(consts.MIN_DURATION, score.score * durScale)
            mewp.duration = easeMax(mewp.duration, consts.MAX_DURATION)
        end

        table.insert(effects, mewp)
    end
    print("new effects list: " .. aux_util.deepToString(effects, 5))
    return effects
end

--- Builds a plain table of PotionRecord fields (not yet a record draft,
--- and not yet added to the world database) from a set of baked effect
--- scores.
---@param scores BakedScore[]
---@param effectMap table[]
---@return table
local function newPotionTemplate(scores, effectMap)
    local anchorIdx    = pickAnchorIdx(scores, effectMap)
    local anchorScore  = scores[anchorIdx]
    local anchorEffect = effectMap[anchorIdx]

    local effects      = buildEffectsList(scores, effectMap)

    local value        = 0
    for i, effect in ipairs(effects) do
        local contrib = consts.VALUE_SCALE * scores[i].score *
            math.max(consts.MIN_EFFECTIVE_BASE_COST, effectMap[i].baseCost)
        if effectMap[i].harmful then
            contrib = contrib * (-1) * consts.HARMFUL_VALUE_MULTIPLIER
        end
        value = value + contrib
    end
    value      = math.abs(value)

    local tier = tierForValue(value)

    return {
        icon       = tier.icon,
        model      = tier.model,
        isAutocalc = false,
        name       = potionNameFromScore(anchorScore, anchorEffect),
        value      = value,
        weight     = 0.1,
        effects    = effects,
    }
end

--- Builds a new potion record, adds it to the world database, and returns
--- it. This is the only place a potion record actually gets created --
--- callers should go through getPotionRecord() so identical recipes reuse
--- the same underlying record instead of piling up duplicates in the
--- world database.
---@param scores BakedScore[]
---@param effectMap table[]
---@return #PotionRecord
local function createPotionRecord(scores, effectMap)
    local template = newPotionTemplate(scores, effectMap)
    local draft = types.Potion.createRecordDraft(template)
    return world.createRecord(draft)
end

--- This is cached, and persistent across the entire playthrough (see
--- onSave/onLoad below). That allows identical recipes to consistently
--- stack into the same potion record instead of creating a new record
--- (and a new, unstackable item) every single brew.
---@param scores BakedScore[]
---@return #PotionRecord
local function getPotionRecord(scores)
    local effectMap = getEffectRecords(scores)
    local hash = hashScores(scores, effectMap)

    local existingId = recipes[hash]
    if existingId then
        return types.Potion.record(existingId)
    end

    local record = createPotionRecord(scores, effectMap)
    recipes[hash] = record.id
    return record
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
    getPotionRecord = getPotionRecord,
    -- These are engine handlers (onSave/onLoad), not custom events -- this
    -- module isn't a script the engine talks to directly, so global.lua
    -- must forward its own onSave/onLoad engineHandlers into these for the
    -- recipe cache to actually persist across a save/reload.
    onLoad          = onLoad,
    onSave          = onSave,
}
