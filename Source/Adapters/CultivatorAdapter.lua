----------------------------------------------------------------
-- StockPiler Adapters/CultivatorAdapter - cultivation read + plant/harvest
----------------------------------------------------------------

StockPiler = StockPiler or {}
StockPiler.CultivatorAdapter = StockPiler.CultivatorAdapter or {}
local CA = StockPiler.CultivatorAdapter

-- Plots 1/2/3/4 unlock at Cultivation skill 1/50/100/150.
local PLOT_UNLOCK_SKILL = { 1, 50, 100, 150 }

local function TryCall(label, fn, ...)
    return StockPiler.Util.TryCall(label, fn, ...)
end

function CA.StageEmpty()
    if GameData and GameData.CultivationStage then
        return GameData.CultivationStage.EMPTY or 0
    end
    return 0
end

local StageEmpty = CA.StageEmpty

local function SeedUidFromSeedTable(seed)
    if type(seed) ~= "table" then
        return 0
    end
    local uid = tonumber(seed.uniqueID) or 0
    if uid <= 0 then
        uid = tonumber(seed.id) or 0
    end
    return uid
end

local function SeedDisplayFromTable(seed)
    if type(seed) ~= "table" then
        return nil
    end
    return {
        uniqueID = SeedUidFromSeedTable(seed),
        name = seed.name,
        iconNum = tonumber(seed.iconNum) or 0,
        rarity = seed.rarity,
        itemSet = seed.itemSet,
    }
end

local function ReadAdditivesMap(src)
    local out = {}
    if type(src) ~= "table" then
        return out
    end
    for cultType, slot in pairs(src) do
        local ct = tonumber(cultType) or 0
        if ct > 0 and type(slot) == "table" then
            local id = tonumber(slot.id) or 0
            local uid = tonumber(slot.uniqueID) or 0
            if uid <= 0 then
                uid = id
            end
            -- Also drop live engine item refs from additives (avoids accidental deep cycles).
out[ct] = {
                id = id,
                uniqueID = uid,
                filled = id ~= 0 or uid ~= 0,
                iconNum = tonumber(slot.iconNum) or 0,
                name = slot.name,
            }
        end
    end
    return out
end

function CA.TradeSkill()
    local Caps = StockPiler.TradeSkillCaps
    if Caps and Caps.CultivationId then
        return Caps.CultivationId()
    end
    return 3
end

function CA.CraftingBackpackType()
    if EA_Window_Backpack and EA_Window_Backpack.TYPE_CRAFTING then
        return EA_Window_Backpack.TYPE_CRAFTING
    end
    return 4
end

--- Unlocked plot count by Cultivation skill (RoR: +1 plot per 50 skill, max 4 at 150).
function CA.PlotsForCultivatingSkill(level)
    level = tonumber(level) or 0
    if level >= 150 then
        return 4
    end
    if level >= 100 then
        return 3
    end
    if level >= 50 then
        return 2
    end
    if level >= 1 then
        return 1
    end
    return 0
end

function CA.UnlockSkillForPlot(plotIndex)
    plotIndex = tonumber(plotIndex) or 0
    if plotIndex < 1 or plotIndex > 4 then
        return nil
    end
    return PLOT_UNLOCK_SKILL[plotIndex]
end

function CA.MaxPlotSlots()
    if GameData and GameData.Cultivation and GameData.Cultivation.NUM_OF_PLOTS ~= nil then
        return tonumber(GameData.Cultivation.NUM_OF_PLOTS) or 4
    end
    return 4
end

function CA.GetCultSkill()
    if StockPiler.TradeSkillCaps and StockPiler.TradeSkillCaps.GetCultSkill then
        return StockPiler.TradeSkillCaps.GetCultSkill()
    end
    return 0
end

function CA.NumPlots()
    local maxSlots = CA.MaxPlotSlots()
    local unlocked = CA.PlotsForCultivatingSkill(CA.GetCultSkill())
    if unlocked < 1 then
        unlocked = 1
    end
    if unlocked > maxSlots then
        unlocked = maxSlots
    end
    return unlocked
end

function CA.IsPlotLocked(plotIndex, cultSkill)
    plotIndex = tonumber(plotIndex) or 0
    if plotIndex <= 0 then
        return true
    end
    cultSkill = tonumber(cultSkill)
    if cultSkill == nil then
        cultSkill = CA.GetCultSkill()
    end
    local need = CA.UnlockSkillForPlot(plotIndex)
    if need == nil then
        return true
    end
    if cultSkill < need then
        return true
    end
    return plotIndex > CA.PlotsForCultivatingSkill(cultSkill)
end

--- Prefer engine GetCultivationInfo (same as default CultivationWindow).
function CA.GetPlotInfo(plotNum)
    plotNum = tonumber(plotNum) or 0
    local cultSkill = CA.GetCultSkill()
    local out = {
        plotNum = plotNum,
        stage = 0,
        stageTimer = 0,
        stageTimerOn = false,
        totalTimer = 0,
        totalTimerOn = false,
        seedUid = 0,
        plantUid = 0,
        seedName = nil,
        seedIconNum = 0,
        seed = nil,
        additives = {},
        locked = CA.IsPlotLocked(plotNum, cultSkill),
    }
    if plotNum <= 0 then
        out.locked = true
        return out
    end

    if type(GetCultivationInfo) == "function" then
        local ok, info = TryCall("GetCultivationInfo", GetCultivationInfo, plotNum)
        if ok == true and type(info) == "table" then
            local stage = tonumber(info.StageNum) or 0
            if stage == 255 then
                stage = StageEmpty()
            end
            out.stage = stage
            out.stageTimer = tonumber(info.StageTimer) or 0
            out.totalTimer = tonumber(info.TotalTimer) or 0
            local filled = stage ~= StageEmpty()
            if info.StageTimerOn ~= nil or info.stageTimerOn ~= nil then
                out.stageTimerOn = info.StageTimerOn == true or info.stageTimerOn == true
            else
                out.stageTimerOn = filled and out.stageTimer > 0
            end
            if info.TotalTimerOn ~= nil or info.totalTimerOn ~= nil then
                out.totalTimerOn = info.TotalTimerOn == true or info.totalTimerOn == true
            else
                out.totalTimerOn = filled and out.totalTimer > 0
            end
            out.seedUid = SeedUidFromSeedTable(info.Seed)
            out.seed = SeedDisplayFromTable(info.Seed)
            if type(info.Seed) == "table" then
                out.seedName = info.Seed.name
                out.seedIconNum = tonumber(info.Seed.iconNum) or 0
            end
            if type(info.Plant) == "table" then
                out.plantUid = tonumber(info.Plant.uniqueID) or tonumber(info.Plant.id) or 0
            elseif info.PlantUniqueID ~= nil then
                out.plantUid = tonumber(info.PlantUniqueID) or 0
            end
            out.additives = ReadAdditivesMap(info.Additives)
            if info.Locked ~= nil then
                out.locked = info.Locked == true
            elseif info.locked ~= nil then
                out.locked = info.locked == true
            end
            return out
        end
    end

    if not GameData or not GameData.Player or not GameData.Player.Cultivation then
        return out
    end
    local plots = GameData.Player.Cultivation.Plots
    if type(plots) == "table" and type(plots[plotNum]) == "table" then
        local p = plots[plotNum]
        out.stage = tonumber(p.stage) or tonumber(p.StageNum) or 0
        if out.stage == 255 then
            out.stage = StageEmpty()
        end
        out.stageTimer = tonumber(p.StageTimer) or tonumber(p.stageTimer) or 0
        out.totalTimer = tonumber(p.TotalTimer) or tonumber(p.totalTimer) or 0
        local filled = out.stage ~= StageEmpty()
        out.stageTimerOn = filled and out.stageTimer > 0
        out.totalTimerOn = filled and out.totalTimer > 0
        out.seedUid = tonumber(p.seedUniqueID) or SeedUidFromSeedTable(p.Seed) or 0
        out.seed = SeedDisplayFromTable(p.Seed)
        if type(p.Seed) == "table" then
            out.seedName = p.Seed.name
            out.seedIconNum = tonumber(p.Seed.iconNum) or 0
        end
        out.plantUid = tonumber(p.plantUniqueID) or 0
        out.additives = ReadAdditivesMap(p.Additives)
        if p.Locked ~= nil then
            out.locked = p.Locked == true
        elseif p.locked ~= nil then
            out.locked = p.locked == true
        end
    end
    return out
end

-- Alias used by Garden store / SP2 shape.
function CA.ReadPlot(plotNum)
    return CA.GetPlotInfo(plotNum)
end

function CA.GetPlots()
    local n = CA.NumPlots()
    local maxSlots = CA.MaxPlotSlots()
    if n < maxSlots then
        n = maxSlots
    end
    local out = {}
    for plotNum = 1, n do
        out[plotNum] = CA.GetPlotInfo(plotNum)
    end
    return out
end

function CA.SetCurrentPlot(plotNum)
    plotNum = tonumber(plotNum) or 0
    if plotNum <= 0 or not GameData or not GameData.Player or not GameData.Player.Cultivation then
        return false
    end
    GameData.Player.Cultivation.CurrentPlot = plotNum
    return true
end

--- AddCraftingItem opens Cultivation a moment later. That show joins the
--- automatic layout and closes the bag and bank. The bag close is a queued
--- toggle, so putting the window back inside OnShown is already too late.
--- While this plant's show is still pending, layout may not close a bag or
--- bank that was already open. Opening Cultivation yourself is unchanged.
local function CompanionWindowNames()
    local bag = "EA_Window_Backpack"
    if type(EA_Window_Backpack) == "table" and type(EA_Window_Backpack.windowName) == "string" then
        bag = EA_Window_Backpack.windowName
    end
    return { bag, "BankWindow" }
end

local function SnapshotCompanionWindows()
    local shown = {}
    local names = CompanionWindowNames()
    for i = 1, #names do
        local name = names[i]
        if type(DoesWindowExist) == "function" and DoesWindowExist(name)
            and WindowGetShowing(name) == true
        then
            shown[name] = true
        end
    end
    return shown
end

local function NowSec()
    if StockPiler.Util and StockPiler.Util.NowSec then
        return tonumber(StockPiler.Util.NowSec()) or 0
    end
    return 0
end

local function PlantKeepActive()
    local pending = CA._keepOpenAfterPlant
    if type(pending) ~= "table" then
        return nil
    end
    if NowSec() > (tonumber(pending.untilSec) or 0) then
        CA._keepOpenAfterPlant = nil
        return nil
    end
    return pending.shown
end

local function InstallPlantCascadeGuard()
    local Cascade = WindowUtils and WindowUtils.Cascade
    if not Cascade or type(Cascade.Resolve) ~= "function" or CA._plantCascadeWrapped then
        return
    end
    CA._plantCascadeWrapped = true
    local orig = Cascade.Resolve
    Cascade.Resolve = function(...)
        local shown = PlantKeepActive()
        local list = Cascade.List
        local saved = nil
        if type(shown) == "table" and type(list) == "table" then
            saved = {}
            for i = 1, #list do
                local entry = list[i]
                if type(entry) == "table" and type(entry.name) == "string" and shown[entry.name] == true then
                    saved[entry.name] = { fn = entry.closeFunction }
                    entry.closeFunction = function() end
                end
            end
        end
        local ok, err = pcall(orig, ...)
        list = Cascade.List
        if saved and type(list) == "table" then
            for i = 1, #list do
                local entry = list[i]
                local prior = type(entry) == "table" and saved[entry.name] or nil
                if prior then
                    entry.closeFunction = prior.fn
                end
            end
        end
        if not ok then
            error(err)
        end
    end
end

--- Plant seed from bag slot into plot. Same engine API as additives.
function CA.PlantSeed(plotNum, bagSlot, backpackType)
    plotNum = tonumber(plotNum) or 0
    bagSlot = tonumber(bagSlot) or 0
    if plotNum <= 0 or bagSlot <= 0 or type(AddCraftingItem) ~= "function" then
        return false, "invalid-args"
    end
    backpackType = tonumber(backpackType) or CA.CraftingBackpackType()
    InstallPlantCascadeGuard()
    local shown = SnapshotCompanionWindows()
    local keepCount = 0
    for _ in pairs(shown) do
        keepCount = keepCount + 1
    end
    if keepCount > 0 then
        CA._keepOpenAfterPlant = {
            shown = shown,
            untilSec = NowSec() + 2,
        }
        if StockPiler.Debug and StockPiler.Debug.LogOp then
            StockPiler.Debug.LogOp("grow", "plant-keep windows=" .. tostring(keepCount))
        end
    end
    local ok, err = TryCall("AddCraftingItem", AddCraftingItem, CA.TradeSkill(), plotNum, bagSlot, backpackType)
    if not ok then
        CA._keepOpenAfterPlant = nil
        return false, err or "pcall-failed"
    end
    return true
end

function CA.AddAdditive(plotNum, bagSlot, backpackType)
    return CA.PlantSeed(plotNum, bagSlot, backpackType)
end

--- Select plot then PerformCrafting(Cultivation). Macro/chrome bind is alternate path.
function CA.HarvestPlot(plotNum)
    plotNum = tonumber(plotNum) or 0
    if plotNum <= 0 then
        return false, "invalid-plot"
    end
    CA.SetCurrentPlot(plotNum)
    if type(PerformCrafting) ~= "function" then
        return false, "no-api"
    end
    local ok, err = TryCall("PerformCrafting", PerformCrafting, CA.TradeSkill(), 1)
    if not ok then
        return false, err or "pcall-failed"
    end
    return true
end
