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
---@field GetLayout fun(self: DynamicContainer, dt : number): table? nil if loop expired

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

---@param imageAtlasPath string must be a square image atlas of square frames, with the top left being the starting frame
---@param imageAtlasResolution Vector2
---@param frames number number of frames in the atlas
---@param fps number how fast to play the animation
---@param loops number? nil if loops forever. else, number of loops to do.
---@return AnimatedImage
local function NewAnimatedImage(imageAtlasPath, imageAtlasResolution, frames, fps, loops, props)
    local new = {
        _imageAtlasPath = imageAtlasPath,
        _frames         = frames,
        _fps            = fps,
        _loops          = loops,
        _lastFrameIdx   = 1,
        _elapsedTime    = 0,
        _elapsedLoops   = 0,
        _imageLayouts   = {}
    }
    setmetatable(new, AnimatedImageMethods)
    --- TODO: build out image table layouts
    --- you need to split up the atlas automatically based on frame count and atlas size
    --- this is how you extract subimages from an atlas:
    --[[
    local frameTextures =
    ---     ui.texture {
        path = "textures\\ErnPotionMaster\\circle-sweep.png",
        offset = util.vector2(0, 0),
        size = util.vector2(64, 64)
    },
    ui.texture {
        path = "textures\\ErnPotionMaster\\circle-sweep.png",
        offset = util.vector2(64, 0),
        size = util.vector2(64, 64)
    },
    ui.texture {
        path = "textures\\ErnPotionMaster\\circle-sweep.png",
        offset = util.vector2(0, 64),
        size = util.vector2(64, 64)
    },
    ui.texture {
        path = "textures\\ErnPotionMaster\\circle-sweep.png",
        offset = util.vector2(64, 64),
        size = util.vector2(64, 64)
    }
    ]] --

    --- then for each image, you do this:
    for _, img in frameTextures do
        local newFrame = {
            type = ui.TYPE.Image,
            props = deepCopy(props or {})
        }
        newFrame.props.resource = img
        table.insert(new._imageLayouts, newFrame)
    end

    return new
end

---@param self AnimatedImage
---@param dt number
---@return table? nil if loop expired
function AnimatedImageMethods:GetLayout(dt)
    --- advance elapsed time and last frame
    self._elapsedTime = self._elapsedTime + dt
    while self._elapsedTime > 1 / self._fps do
        self._lastFrameIdx = self._lastFrameIdx + 1
        self._elapsedTime = self._elapsedTime - 1 / self._fps
    end
    self._lastFrameIdx = ((self._lastFrameIdx - 1) % self._frames) + 1
    -- TODO: handle loops tracking and return nil if we are done

    return self._imageLayouts[self._lastFrameIdx]
end

return {
    NewAnimatedImage = NewAnimatedImage
}
