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

---Shuffles the values of a collection and returns them in a new array.
---@generic T
---@param collection table<any, T> The input collection (can be a list or dictionary).
---@return T[] # A new array containing the shuffled elements.
local function shuffle(collection)
    local randList = {}
    for _, item in pairs(collection) do
        -- get random index to insert into. 1 to size+1.
        -- # is a special op that gets size
        local insertAt = math.random(1, 1 + #randList)
        table.insert(randList, insertAt, item)
    end
    return randList
end

return shuffle
