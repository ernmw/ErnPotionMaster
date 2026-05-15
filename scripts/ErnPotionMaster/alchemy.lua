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

-- This file contains the game state, including the board.
-- It owns and rebuilds the pachinko physics board as necessary.
-- It owns and rebuilds the render board as necessary.
-- It maintains a registry of balls and pins indexed by their ID,
-- and sends this info as necessary to both the pachinko physics board and render board.

local MOD_NAME         = require("scripts.ErnPotionMaster.ns")
local const            = require("scripts.ErnPotionMaster.const")
local ui               = require("openmw.ui")
local util             = require("openmw.util")
local pself            = require("openmw.self")
local core             = require("openmw.core")
local types            = require("openmw.types")
local placepins        = require("scripts.ErnPotionMaster.placepins")
local settings         = require("scripts.ErnPotionMaster.settings.settings")
local physics          = require("scripts.ErnPotionMaster.physics.pachinko")
local interfaces       = require('openmw.interfaces')
local shuffle          = require("scripts.ErnPotionMaster.shuffle")
local aux_util         = require('openmw_aux.util')
local renderBoard      = require("scripts.ErnPotionMaster.render.board")
local templates        = require("scripts.ErnPotionMaster.render.templates")
local effectScore      = require("scripts.ErnPotionMaster.effectscore")
local ingredientInfo   = require("scripts.ErnPotionMaster.ingredientinfo")
local potiondonewindow = require("scripts.ErnPotionMaster.potiondonewindow")
local search           = require("scripts.ErnPotionMaster.search")
local common           = require("scripts.ErnPotionMaster.common")


local shootPosition = util.vector2(0.5, 0.05):emul(const.BoardSize)

--[[
Before you begin, you pick the target effect you want. You can only choose effects that are present in atleast two different ingredients available to you.
This is used to figure out if you are trying to make a potion (positive effect) or poison (negative effect).
If you're making a potion, all positive effects are Intended and negative effects are Unintended.
This is reversed for poisons.

After choosing your effect, you pick at two to four ingredients from a secondary list.
For the first two ingredients you pick, the list will only contain ingredients that contain your desired effect.
For third and and fourth ingredients you might pick, the list will only contain ingredients that have at least one effect in common with all the previously-selected ingredients.
These ingredients are shot as Balls.

After picking two to four ingredients, you can click on a "Create" button.
This will delete the ingredients from your inventory and start up the game board UI.

This file contains the game board UX, which is what follows:

A Ball is one ingredient.
There will be at least one pin per ingredient effect (up to 4). The more expensive the ingredient, and the better your Motar and Pestle, the more pins will be Effect Pins.
Hit the effect pin to increase the Effect Score for that individual effect.
Each time you hit an effect pin for the same effect on the same shot,
you get exponentially more points for that Effect Score.
As the Effect Score increases, you get additional magnitude and duration for that effect.

If you have the appropriate alchemy equipment, you will get one pin per each equipment item:
- Alembic: Reduces a random Unintended effect Effect Score. The amount depends on the tool quality.
- Retort: Multiplies the current Effect Score of a random Intended effect. The amount depends on the tool quality.
- Calcinator: Un-pops pins on the board instantly. The chance to un-Pop a pin depends on the tool quality. Before un-Popping, popped pins have their positions shuffled.
Mortar and Pestle is different, since it has an impact on the number of Effect Pins.

The Effect Score sticks around between Shots.
The board is reset after each Shot.
After making your predetermined number of Shots (2 to 4), the potion is created based on its Effect Scores.

Pins have a chance to Pop when they are hit based on your Alchemy skill, Intelligence, and Luck.
]]

local playwindow = require("scripts.ErnPotionMaster.playwindow")

---@enum StateClass
local StateClass = {
    PRIMARY_EFFECT_SELECTION = 1,
    INGREDIENT_1_SELECTION = 2,
    INGREDIENT_2_SELECTION = 3,
    --- let people do 5x at a time. they end up with 5 identical potions (or failures)
    BATCH_AMOUNT_SELECTION = 4,
    --- the playwindow takes over in this state
    PLAY = 5,
    --- Allow for a quick "do it again" button that sets up the PLAY state
    --- again with the same ingredients, if they are available.
    POTION_DONE_WINDOW = 6,
}

---@type StateClass
local currentState = StateClass.PLAY

local batchSize = 3

---@type PlayWindow?
local play

---@type PotionDoneWindow?
local doneWindow

local function onStopAlchemy()
    settings.debugPrint("stop alchemy")
    -- do cleanup
    if play then
        play:close()
    end
    if doneWindow then
        doneWindow:close()
    end

    settings.debugPrint("removemode: alchemy")
    interfaces.UI.removeMode("Alchemy")
    settings.debugPrint("startmode: alchemy")

    -- forward to global to remove this script
    core.sendGlobalEvent(MOD_NAME .. 'onStopAlchemy', {
        player = pself,
    })
end


local function onInit(data)
    settings.debugPrint("start alchemy")
end

local function onFrame()
    if currentState == StateClass.PLAY then
        if not play then
            --- TODO: start up planning UI.
            --- once that's done, start up playwindow UI.

            -- TODO: actually do selection logic. this is just for testing
            local inventories = { pself.type.inventory(pself) }
            ---@type ActualizedIngredient[]
            local ingredientInfos = {}
            for _, item in ipairs(shuffle(common.getAllIngredients(inventories))) do
                if #ingredientInfos >= 2 then
                    break
                end
                if item.count >= batchSize then
                    table.insert(ingredientInfos, item)
                    settings.debugPrint("found ingredient: " .. aux_util.deepToString(item, 3))
                end
            end

            for _, ingred in ipairs(ingredientInfos) do
                core.sendGlobalEvent(MOD_NAME .. 'onDecrementItems', {
                    items = ingred.objects,
                    amount = batchSize,
                })
                -- force count to batchSize for rendering in play window
                ingred.count = batchSize
            end

            -- todo
            local toolStrengths = {
                [const.ToolClass.CALCINATOR] = 1,
                [const.ToolClass.ALEMBIC] = 1,
                [const.ToolClass.MORTAR] = 1,
                [const.ToolClass.RETORT] = 1,
            }

            local desiredEffect = common.getMagicEffectsFromIngredients({ ingredientInfos[1].record })[1]
            settings.debugPrint("desired effect: " .. tostring(desiredEffect.id))

            play = playwindow.new({
                ingredientInfos = ingredientInfos,
                toolStrengths = toolStrengths,
                desiredEffect = desiredEffect,
                doneCallback = function(data)
                    currentState = StateClass.POTION_DONE_WINDOW
                    play = nil
                end
            })
        end
        play:onFrame()
    elseif currentState == StateClass.POTION_DONE_WINDOW then
        if not doneWindow then
            doneWindow = potiondonewindow.new(
                types.Potion.records["potion_skooma_01"],
                batchSize,
                function(data)
                    -- TODO: finish
                    settings.debugPrint("close alchemy window button pressed")
                    onStopAlchemy()
                end,
                function(data)
                    -- TODO: finish
                    settings.debugPrint("do alchemy again")
                    currentState = StateClass.PLAY
                    if doneWindow then
                        doneWindow:close()
                        doneWindow = nil
                    end
                end
            )
        end
        doneWindow:onFrame()
    end
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
