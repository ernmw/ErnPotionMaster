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
local core = require("openmw.core")
local pself = require("openmw.self")
local util = require('openmw.util')
local async = require("openmw.async")
local types = require('openmw.types')
local input = require('openmw.input')
local interfaces = require('openmw.interfaces')
local settings = require("scripts.ErnPotionMaster.settings.settings")

if settings.admin.disable then
    print(MOD_NAME .. " is disabled.")
    return
end

local function startAlchemy()
    -- send to global so the alchemy script can be attached
    core.sendGlobalEvent(MOD_NAME .. 'onStartAlchemy', {
        player = pself,
    })
end

local function stopAlchemy()
    -- send to alchemy script so it can do cleanup
    pself:sendEvent(MOD_NAME .. 'onStopAlchemy', {
        player = pself,
    })
end

interfaces.UI.registerWindow("Alchemy", startAlchemy, stopAlchemy)

return {}
