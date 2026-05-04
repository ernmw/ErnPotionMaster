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
local util                      = require("openmw.util")
local search                    = require("scripts.ErnPotionMaster.search")
local const                     = require("scripts.ErnPotionMaster.const")

---@class Renderable
---@field id number
---@field layout fun(dt: number, id: number): table|nil|false

---@class DynamicContainer
---@field name string
---@field element userdata
---@field renderables Renderable[]
---@field _layoutCache table<number, table> -- id -> layout
---@field _order number[]                  -- stable ordered ids
---@field AddRenderable fun(self: DynamicContainer, renderable: Renderable)
---@field Render fun(self: DynamicContainer, dt: number)
---@field Reset fun(self: DynamicContainer)

---@class DynamicContainerMethods
local DynamicContainerMethods   = {}
DynamicContainerMethods.__index = DynamicContainerMethods

---@param self DynamicContainer
---@param renderable Renderable
function DynamicContainerMethods:AddRenderable(renderable)
    assert(type(renderable.id) == "number", "Renderable must have numeric id")
    assert(type(renderable.layout) == "function", "Renderable must have layout(dt)")

    local insertIndex = search(self.renderables, function(p)
        return p.id > renderable.id
    end)

    table.insert(self.renderables, insertIndex, renderable)
    table.insert(self._order, insertIndex, renderable.id)
end

---@param name string
---@param renderables Renderable[]
---@return DynamicContainer
local function NewDynamicContainer(name, renderables)
    local elem = ui.create({
        name = name,
        type = ui.TYPE.Widget,
        props = {
            relativeSize = util.vector2(1, 1),
        },
        content = ui.content {},
    })
    local new = {
        name = name,
        element = elem,
        renderables = {},
        _layoutCache = {},
        _order = {},
    }
    setmetatable(new, DynamicContainerMethods)

    for _, r in ipairs(renderables) do
        new:AddRenderable(r)
    end

    return new
end

---@param self DynamicContainer
function DynamicContainerMethods:Reset()
    self.renderables = {}
    self._layoutCache = {}
    self._order = {}
end

---@param self DynamicContainer
---@param dt number
function DynamicContainerMethods:Render(dt)
    local dirty = false

    for _, r in ipairs(self.renderables) do
        local result = r.layout(dt, r.id)

        if result == false then
            -- remove
            self._layoutCache[r.id] = nil
            dirty = true
        elseif result ~= nil then
            -- changed
            self._layoutCache[r.id] = result
            dirty = true
        end
        -- nil = unchanged
    end

    if not dirty then
        return -- nothing changed, skip UI update entirely
    end

    -- rebuild only when something actually changed
    local newContent = {}

    for _, id in ipairs(self._order) do
        local layout = self._layoutCache[id]
        if layout then
            table.insert(newContent, layout)
        end
    end

    self.element.layout.content = ui.content(newContent)
    self.element:update()
end

return {
    NewDynamicContainer = NewDynamicContainer
}
