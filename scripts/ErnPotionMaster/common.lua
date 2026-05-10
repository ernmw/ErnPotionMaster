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
local const    = require("scripts.ErnPotionMaster.const")
local pself    = require("openmw.self")
local types    = require("openmw.types")
local settings = require("scripts.ErnPotionMaster.settings.settings")
local aux_util = require('openmw_aux.util')
local search   = require("scripts.ErnPotionMaster.search")


---comment
---@param a MagicEffectWithParams
---@param b MagicEffectWithParams
---@return boolean
local function magicEffectsEqual(a, b)
    return a.affectedAttribute == b.affectedAttribute and
        a.affectedSkill == b.affectedSkill and
        a.id == b.id
end

---@param a MagicEffectWithParams
---@param b MagicEffectWithParams
---@return boolean
local function magicEffectSortFn(a, b)
    if a.id ~= b.id then
        return a.id < b.id
    end
    if a.affectedAttribute ~= b.affectedAttribute then
        return a.affectedAttribute < b.affectedAttribute
    end
    if a.affectedSkill ~= b.affectedSkill then
        return a.affectedSkill < b.affectedSkill
    end
    return false
end

---@param ingredientRecords table[]
---@return MagicEffectWithParams[]
local function getMagicEffectsFromIngredients(ingredientRecords)
    local outEffects = {}
    for _, ingred in ipairs(ingredientRecords) do
        for idx, effectParam in ipairs(ingred.effects) do
            if not search.contains(outEffects,
                    function(a) return magicEffectsEqual(a, effectParam) end) then
                table.insert(outEffects, effectParam)
            end
        end
    end

    table.sort(outEffects, magicEffectSortFn)
    return outEffects
end

---@class ActualizedIngredient: IngredientInfo
---@field objects table[] actual objects of this type

--- finds all ingredients in the given list of inventories that pass the magic effect filter.
---@param inventories table[]?
---@param mewpFilter (fun(a: MagicEffectWithParams): boolean)?
---@return ActualizedIngredient[]
local function getAllIngredients(inventories, mewpFilter)
    inventories = inventories or { pself.type.inventory(pself) }
    ---@type { [string]: ActualizedIngredient}
    local ingredientsByRecordID = {}
    for _, inventory in ipairs(inventories) do
        for _, item in ipairs(inventory:getAll(types.Ingredient)) do
            settings.debugPrint("checking ingredient: " .. aux_util.deepToString(item, 3))
            local record = types.Ingredient.record(item)
            local passed = false
            if mewpFilter then
                for _, mewp in ipairs(getMagicEffectsFromIngredients({ record })) do
                    if mewpFilter(mewp) then
                        passed = true
                        break
                    end
                end
            end
            if passed or not mewpFilter then
                local prev = ingredientsByRecordID[record.id] or { record = record, count = 0, objects = {} }
                prev.count = prev.count + item.count
                table.insert(prev.objects, item)
                ingredientsByRecordID[record.id] = prev
            end
        end
    end

    --- now sort
    local out = {}

    for _, ingred in pairs(ingredientsByRecordID) do
        local insertIndex = search.binarySearch(out, function(p)
            return ingred.record.id > p.record.id
        end)
        table.insert(out, insertIndex, ingred)
    end


    return out
end


return {
    magicEffectsEqual = magicEffectsEqual,
    magicEffectSortFn = magicEffectSortFn,
    getMagicEffectsFromIngredients = getMagicEffectsFromIngredients,
    getAllIngredients = getAllIngredients,
}
