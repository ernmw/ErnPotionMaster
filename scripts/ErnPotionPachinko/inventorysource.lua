--[[
ErnPotionPachinko for OpenMW.
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

-- inventorysource.lua
--
-- Centralizes "what inventories/apparatuses can the player use right now"
-- so the rest of the mod (selectionwindow.lua, alchemy.lua) doesn't need
-- to know about ownership rules or where nearby containers come from.
--
-- Today this means:
--   * the player's own inventory (always available, even if individual
--     items inside it are "owned" -- you already have them in hand)
--   * nearby containers (barrels, chests, sacks, etc.) that are NOT owned
--     by anyone the player isn't allowed to take from
--
-- This is intentionally the only file that needs to know about
-- `nearby.containers`, ownership rules, or apparatus quality lookups --
-- everything else just consumes the inventory list / tool strength table
-- it produces.
--
-- NOTE: this module can only be required from a *local* script (e.g. one
-- attached to the player, like alchemy.lua), because it uses
-- `openmw.nearby`, which is unavailable to global scripts.

local types  = require("openmw.types")
local nearby = require("openmw.nearby")
local pself  = require("openmw.self")
local const  = require("scripts.ErnPotionPachinko.const")

------------------------------------------------------------------------
-- Ownership
------------------------------------------------------------------------

---@param npc table  an actor (normally the player, `pself`)
---@param factionID string?
---@param rank number?
---@return boolean
local function atLeastRank(npc, factionID, rank)
    if factionID == nil then
        return false
    end
    local inFaction = false
    for _, foundID in pairs(types.NPC.getFactions(npc)) do
        if foundID == factionID then
            inFaction = true
            break
        end
    end
    if inFaction == false then
        return false
    end
    local selfRank = types.NPC.getFactionRank(npc, factionID)
    if selfRank == nil then
        return false
    elseif (rank == nil) then
        return true
    else
        return selfRank >= rank
    end
end

--- Whether `entity` is owned by someone other than the player (i.e.
--- picking it up/using it would be theft).
---@param entity table  a GameObject (e.g. a container)
---@return boolean
local function isOwned(entity)
    if entity.baseType == types.Actor then
        return false
    end
    if entity.owner == nil then
        return false
    end
    if entity.owner.recordId ~= nil then
        return true
    end
    if entity.owner.factionId ~= nil then
        if atLeastRank(pself, entity.owner.factionId, entity.owner.factionRank) == false then
            return true
        end
    end
    return false
end

------------------------------------------------------------------------
-- Inventories
------------------------------------------------------------------------

---@class InventorySourceOptions
---@field radius number?  max distance (in game units) from the player to search for nearby containers. If nil or omitted, nearby containers are not searched at all -- only the player's own inventory is returned.

--- Returns the player's inventory plus the contents of every nearby
--- container that isn't owned (or is owned, but by a faction the player
--- has sufficient rank in). Items already in the player's own inventory
--- are always included, regardless of whether they happen to be flagged
--- as owned.
---@param opts InventorySourceOptions?
---@return table[]  a list of inventories, suitable for common.getAllIngredients
local function getInventories(opts)
    opts = opts or {}

    ---@type table[]
    local inventories = { types.Actor.inventory(pself) }

    if opts.radius then
        local playerPos = pself.position
        for _, container in ipairs(nearby.containers) do
            if container:isValid() and not isOwned(container) then
                local dist = (container.position - playerPos):length()
                if dist <= opts.radius then
                    table.insert(inventories, types.Container.content(container))
                end
            end
        end
    end

    return inventories
end

------------------------------------------------------------------------
-- Apparatuses (tools)
------------------------------------------------------------------------

--- Maps an Apparatus.TYPE value to our own ToolClass enum.
---@param apparatusType number
---@return ToolClass?
local function toToolClass(apparatusType)
    local Apparatus = types.Apparatus
    if apparatusType == Apparatus.TYPE.Alembic then
        return const.ToolClass.ALEMBIC
    elseif apparatusType == Apparatus.TYPE.Retort then
        return const.ToolClass.RETORT
    elseif apparatusType == Apparatus.TYPE.Calcinator then
        return const.ToolClass.CALCINATOR
    elseif apparatusType == Apparatus.TYPE.MortarPestle then
        return const.ToolClass.MORTAR
    end
    return nil
end

--- Folds a single apparatus item into `strengths`, keeping only the
--- highest quality seen so far for its tool class.
---@param strengths {[ToolClass]: number}
---@param item table  a GameObject of type Apparatus
local function considerApparatus(strengths, item)
    if not item:isValid() then return end
    if not types.Apparatus.objectIsInstance(item) then return end
    local record = types.Apparatus.record(item)
    local toolClass = toToolClass(record.type)
    if not toolClass then return end
    if (strengths[toolClass] or 0) < record.quality then
        strengths[toolClass] = record.quality
    end
end

--- Returns the best (highest-quality) available apparatus of each
--- ToolClass, drawn from the player's inventory (regardless of ownership)
--- and any placed tools nearby (within `opts.radius`, if given).
--- A ToolClass with no apparatus available anywhere is reported as 0 --
--- callers shouldn't assume every key is present unless they specifically
--- want to detect "no tool of this kind at all" themselves, in which case
--- they should check for a nil instead of a 0.
---@param opts InventorySourceOptions?
---@return {[ToolClass]: number}
local function getApparatusStrengths(opts)
    opts = opts or {}

    ---@type {[ToolClass]: number}
    local strengths = {}

    for _, item in ipairs(types.Actor.inventory(pself):getAll(types.Apparatus)) do
        considerApparatus(strengths, item)
    end

    if opts.radius then
        local playerPos = pself.position
        for _, item in ipairs(nearby.items) do
            if item:isValid() and not isOwned(item) then
                local dist = (item.position - playerPos):length()
                if dist <= opts.radius then
                    considerApparatus(strengths, item)
                end
            end
        end
    end

    -- Fill in zeroes for any tool class nobody has, so downstream code
    -- (playwindow.lua) can always index this table without a nil check.
    for _, toolClass in pairs(const.ToolClass) do
        if strengths[toolClass] == nil then
            strengths[toolClass] = 0
        end
    end

    return strengths
end

return {
    isOwned               = isOwned,
    getInventories        = getInventories,
    getApparatusStrengths = getApparatusStrengths,
}
