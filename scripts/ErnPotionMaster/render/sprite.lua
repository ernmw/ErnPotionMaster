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
local ui                     = require("openmw.ui")
local util                   = require("openmw.util")

---@class AnimatedImage
---@field _imageAtlasPath string must be a square image atlas of square frames, with the top left being the starting frame
---@field _imageAtlasResolution Vector2
---@field _frames number number of frames in the atlas
---@field _fps number how fast to play the animation
---@field _loops number? nil if loops forever. else, number of loops to do.
---@field _imageLayouts table[]
---@field _elapsedTime number
---@field _elapsedLoops number
---@field _lastFrameIdx number
---@field GetLayout fun(self: AnimatedImage, dt : number?): table? nil if loop expired

---@class AnimatedImageMethods
local AnimatedImageMethods   = {}
AnimatedImageMethods.__index = AnimatedImageMethods

local function deepCopy(orig)
    local orig_type = type(orig)
    local copy
    if orig_type == 'table' then
        copy = {}
        for orig_key, orig_value in next, orig, nil do
            copy[deepCopy(orig_key)] = deepCopy(orig_value)
        end
        setmetatable(copy, deepCopy(getmetatable(orig)))
    else -- number, string, boolean, etc
        copy = orig
    end
    return copy
end

local function NewAnimatedImage(imageAtlasPath, imageAtlasResolution, frames, fps, loops, props)
    local new = {
        _imageAtlasPath       = imageAtlasPath,
        _imageAtlasResolution = imageAtlasResolution, -- was missing!
        _frames               = frames,
        _fps                  = fps,
        _loops                = loops,
        _lastFrameIdx         = 1,
        _elapsedTime          = 0,
        _elapsedLoops         = 0,
        _imageLayouts         = {}
    }
    setmetatable(new, AnimatedImageMethods)

    local cols      = math.ceil(math.sqrt(frames))
    local rows      = math.ceil(frames / cols)
    local frameSize = util.vector2(
        imageAtlasResolution.x / cols,
        imageAtlasResolution.y / rows
    )

    for i = 0, frames - 1 do
        local col = i % cols
        local row = math.floor(i / cols)

        local tex = ui.texture {
            path   = imageAtlasPath,
            offset = util.vector2(col * frameSize.x, row * frameSize.y),
            size   = frameSize
        }

        local newFrame = {
            type  = ui.TYPE.Image,
            props = deepCopy(props or {})
        }
        newFrame.props.resource = tex
        table.insert(new._imageLayouts, newFrame)
    end

    return new
end

---@param self AnimatedImage
---@param dt number?
---@return table? nil if loop expired
function AnimatedImageMethods:GetLayout(dt)
    -- If we already finished all loops, stay done.
    if self._loops ~= nil and self._elapsedLoops >= self._loops then
        return nil
    end

    dt = dt or 0

    -- Advance elapsed time, ticking forward one frame at a time so we never
    -- skip the loop-boundary accounting even on a very long dt.
    self._elapsedTime = self._elapsedTime + dt
    while self._elapsedTime >= 1 / self._fps do
        self._elapsedTime = self._elapsedTime - 1 / self._fps
        self._lastFrameIdx = self._lastFrameIdx + 1

        -- When we step past the last frame, that is one completed loop.
        if self._lastFrameIdx > self._frames then
            self._lastFrameIdx = 1
            self._elapsedLoops = self._elapsedLoops + 1

            -- Finite-loop check: if we just finished the last loop, return nil.
            if self._loops ~= nil and self._elapsedLoops >= self._loops then
                return nil
            end
        end
    end

    return self._imageLayouts[self._lastFrameIdx]
end

return {
    NewAnimatedImage = NewAnimatedImage
}
