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
local aux_util = require('openmw_aux.util')
local common   = require("scripts.ErnPotionMaster.common")

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

return {
    eventHandlers = {
        [MOD_NAME .. "onStartAlchemy"] = onStartAlchemy,
        [MOD_NAME .. "onStopAlchemy"] = onStopAlchemy,
        [MOD_NAME .. "onDecrementItems"] = onDecrementItems,
    }
}
