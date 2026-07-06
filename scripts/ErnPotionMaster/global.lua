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
local world    = require('openmw.world')
local types    = require('openmw.types')
local aux_util = require('openmw_aux.util')
local common   = require("scripts.ErnPotionMaster.common")
local recipes  = require("scripts.ErnPotionMaster.recipes")

if require("openmw.core").API_REVISION < 62 then
    error("OpenMW 0.49 or newer is required!")
end

local MOD_NAME = require("scripts.ErnPotionMaster.ns")

local alchemyScript = "scripts/ErnPotionMaster/alchemy.lua"

local function onStartAlchemy(data)
    if not data.player:hasScript(alchemyScript) then
        data.player:addScript(alchemyScript, {})
    end
end

local function onStopAlchemy(data)
    if data.player:hasScript(alchemyScript) then
        data.player:removeScript(alchemyScript)
    end
end

local function onDecrementItems(data)
    common.decrementItems(data.items, data.amount)
end

---@class PotionBrewedArgs
---@field scores BakedScore[]
---@field player table
---@field batchSize number

---@param data PotionBrewedArgs
local function onPotionBrewed(data)
    local batchSize = data.batchSize or 1

    -- getPotionRecord() reuses an existing record for an identical recipe
    -- instead of creating a new one every brew, so identical potions stack.
    local record = recipes.getPotionRecord(data.scores)

    -- Give the actual potions to the player. world.createObject/moveInto is
    -- the only way to place items into an actor's inventory from a global
    -- script (types.Actor.inventory(actor):addItem(...) does not exist).
    local item = world.createObject(record.id, batchSize)
    item:moveInto(types.Actor.inventory(data.player))

    -- Tell the player-side alchemy script (which can't call
    -- world.createRecord itself) which potion was actually made, so it can
    -- show it in the "potion done" window instead of a placeholder.
    data.player:sendEvent(MOD_NAME .. "onPotionRecordReady", {
        record = record,
        count  = batchSize,
    })
end

return {
    engineHandlers = {
        onSave = recipes.onSave,
        onLoad = recipes.onLoad,
    },
    eventHandlers = {
        [MOD_NAME .. "onStartAlchemy"] = onStartAlchemy,
        [MOD_NAME .. "onStopAlchemy"] = onStopAlchemy,
        [MOD_NAME .. "onDecrementItems"] = onDecrementItems,
        [MOD_NAME .. "onPotionBrewed"] = onPotionBrewed,
    }
}
