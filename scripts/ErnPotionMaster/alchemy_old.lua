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
local settings = require("scripts.ErnPotionMaster.settings.settings")

local function onInit(data)
    settings.debugPrint("start alchemy")
end

local function onStopAlchemy()
    settings.debugPrint("stop alchemy")
    -- do cleanup

    -- forward to global to remove this script
    core.sendGlobalEvent(MOD_NAME .. 'onStopAlchemy', {
        player = pself,
    })
end

local function onFrame(dt)
    -- physics and stuff
end

return {
    engineHandlers = {
        onInit = onInit,
        onFrame = onFrame,
    },
    eventHandlers = {
        [MOD_NAME .. "onStopAlchemy"] = onStopAlchemy,
    }
}
