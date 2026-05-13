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
local ui                        = require("openmw.ui")
local search                    = require("scripts.ErnPotionMaster.search")

---@class Renderable
---@field _id number?
---@field layout fun(dt: number, id: number): table|nil|false

---@class DynamicContainer
---@field element table
---@field renderables Renderable[]
---@field _nextID number
---@field _layoutCache table<number, table>  -- id -> last known layout
---@field _pendingRemove table<number, true> -- ids flagged for removal this frame
---@field AddRenderable fun(self: DynamicContainer, renderable: Renderable)
---@field Render fun(self: DynamicContainer, dt: number): boolean
---@field Reset fun(self: DynamicContainer)

---@class DynamicContainerMethods
local DynamicContainerMethods   = {}
DynamicContainerMethods.__index = DynamicContainerMethods

---@param self DynamicContainer
---@param renderable Renderable
function DynamicContainerMethods:AddRenderable(renderable)
    renderable._id = self._nextID
    self._nextID = self._nextID + 1
    assert(type(renderable.layout) == "function", "Renderable must have layout(dt, id)")
    --[[local insertIndex = search.binarySearch(self.renderables, function(p)
        return p._id > renderable._id
    end)]]
    table.insert(self.renderables, renderable)
end

---@param element table
---@param renderables Renderable[]
---@return DynamicContainer
local function NewDynamicContainer(element, renderables)
    local new = {
        element        = element,
        renderables    = {},
        _layoutCache   = {},
        _pendingRemove = {},
        _nextID        = 1,
    }
    setmetatable(new, DynamicContainerMethods)
    for _, r in ipairs(renderables) do
        new:AddRenderable(r)
    end
    return new
end

---@param self DynamicContainer
function DynamicContainerMethods:Reset()
    self.renderables            = {}
    self._layoutCache           = {}
    self._pendingRemove         = {}
    self.element.layout.content = ui.content({})
    self.element:update()
end

---@param self DynamicContainer
---@param dt number
---@return boolean true if changed
function DynamicContainerMethods:Render(dt)
    local dirty = false

    -- 1. Evaluate all renderables, collect removals.
    --    Removals are deferred so we don't mutate `renderables` mid-iteration.
    for _, r in ipairs(self.renderables) do
        local result = r.layout(dt, r._id)
        if result == false then
            -- Flag for removal. Evict from cache NOW so it won't appear
            -- in the content rebuild below — this is what prevents the
            -- one-frame flash.
            if self._layoutCache[r._id] ~= nil then
                self._layoutCache[r._id] = nil
                dirty = true
            end
            self._pendingRemove[r._id] = true
        elseif result ~= nil then
            self._layoutCache[r._id] = result
            dirty = true
        end
        -- nil → unchanged; skip
    end

    -- 2. Purge removed renderables in one pass (avoids repeated table.remove shifts).
    if next(self._pendingRemove) then
        local kept = {}
        for _, r in ipairs(self.renderables) do
            if not self._pendingRemove[r._id] then
                kept[#kept + 1] = r
            end
        end
        self.renderables    = kept
        self._pendingRemove = {}
        -- dirty is already true from the cache eviction above
    end

    if not dirty then
        return false
    end

    -- 3. Rebuild content in sorted order (renderables is kept sorted by id).
    local newContent = {}
    for _, r in ipairs(self.renderables) do
        local layout = self._layoutCache[r._id]
        if layout then
            newContent[#newContent + 1] = layout
        end
    end
    self.element.layout.content = ui.content(newContent)
    self.element:update()
    return true
end

return {
    NewDynamicContainer = NewDynamicContainer
}
