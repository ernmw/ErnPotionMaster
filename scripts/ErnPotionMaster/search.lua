--[[
LivelyMap for OpenMW.
Copyright (C) Erin Pentecost 2025

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

--- @generic T
---@param arr T[]
--- Sorted array over which the predicate transitions from false → true.
--- The predicate MUST be monotonic:
---   - For all i < j: if predicate(arr[i]) is true, predicate(arr[j]) is also true
--- In other words, there exists a single boundary index where the predicate
--- first becomes true, and remains true for all later elements.
---
---@param predicate fun(item: T): boolean
--- Returns true if the element satisfies the search condition.
--- This function will find the *first* index for which predicate(item) == true.
---
---@return integer index
--- The lowest index i such that predicate(arr[i]) is true.
--- Returns #arr+1 if the predicate is false for all elements.
local function binarySearchFirst(arr, predicate)
    local lo = 1
    local hi = #arr
    local result = #arr + 1

    -- Standard binary search over a monotonic predicate.
    -- Invariant:
    --   - All indices < lo are known to be false
    --   - All indices > hi are known to be true
    while lo <= hi do
        local mid = math.floor((lo + hi) / 2)

        if predicate(arr[mid]) then
            -- mid is a valid candidate; keep searching left
            -- to ensure we return the *first* true index.
            result = mid
            hi = mid - 1
        else
            -- mid does not satisfy the predicate; discard left half
            lo = mid + 1
        end
    end

    if result == 0 then
        error("binarySearchFirst returned 0")
    end

    return result
end

return binarySearchFirst
