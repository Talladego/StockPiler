----------------------------------------------------------------
-- StockPiler Knowledge/Additives - Soil / Water / Nutrient catalog stubs
----------------------------------------------------------------

StockPiler = StockPiler or {}
StockPiler.Additives = StockPiler.Additives or {}
local AD = StockPiler.Additives

local function ToNarrow(text)
    return StockPiler.Util.ToNarrow(text)
end

local function CultTypes()
    if GameData and GameData.CultivationTypes then
        return GameData.CultivationTypes
    end
    return { NONE = 0, SEED = 1, SOIL = 2, WATERCAN = 3, NUTRIENT = 4, SPORE = 5 }
end

local function CraftBonusRefs()
    if StockPiler.BrewLearn and StockPiler.BrewLearn.CraftBonus then
        return StockPiler.BrewLearn.CraftBonus
    end
    return { GROW_TIME = 10, CRITICAL_CHANCE = 12, FAIL_CHANCE = 13, SPECIAL_CHANCE = 14 }
end

local function SignedBonus(val)
    val = tonumber(val) or 0
    if val > 32767 then
        return val - 65536
    end
    return val
end

local function ParseStats(itemData)
    local B = CraftBonusRefs()
    local growTime, critChance, superCrit, failChance = 0, 0, 0, 0
    if type(itemData) == "table" and type(itemData.craftingBonus) == "table" then
        for _, bonus in pairs(itemData.craftingBonus) do
            if type(bonus) == "table" then
                local ref = tonumber(bonus.bonusReference) or 0
                local val = SignedBonus(bonus.bonusValue)
                if ref == (B.GROW_TIME or 10) then
                    growTime = val
                elseif ref == (B.CRITICAL_CHANCE or 12) then
                    critChance = val
                elseif ref == (B.SPECIAL_CHANCE or 14) then
                    superCrit = val
                elseif ref == (B.FAIL_CHANCE or 13) then
                    failChance = val
                end
            end
        end
    end
    return {
        growTime = growTime,
        critChance = critChance,
        superCrit = superCrit,
        failChance = failChance,
    }
end

local function AdditivesTable()
    if StockPiler.Knowledge and StockPiler.Knowledge.Additives then
        return StockPiler.Knowledge.Additives()
    end
    return nil
end

local function StoreRecord(itemData, info, source)
    local uid = tonumber(itemData.uniqueID) or tonumber(itemData.id) or 0
    if uid <= 0 then
        return false, false
    end
    local store = AdditivesTable()
    if type(store) ~= "table" then
        return false, false
    end
    local key = tostring(uid)
    local isNew = store[key] == nil
    store[key] = {
        uniqueID = uid,
        iconNum = tonumber(itemData.iconNum) or 0,
        name = itemData.name,
        nameNarrow = ToNarrow(itemData.name),
        cultType = info.cultType,
        role = info.role,
        growTime = info.growTime,
        critChance = info.critChance,
        superCrit = info.superCrit,
        failChance = info.failChance,
        skillReq = tonumber(itemData.craftingSkillRequirement) or 0,
        source = source or "bag",
    }
    if StockPiler.Items and StockPiler.Items.StoreItem then
        StockPiler.Items.StoreItem(itemData, "additive")
    end
    if isNew and StockPiler.Knowledge and StockPiler.Knowledge.Touch then
        StockPiler.Knowledge.Touch("additive")
    end
    return true, isNew
end

function AD.Classify(itemData)
    if type(itemData) ~= "table" then
        return nil
    end
    local types = CultTypes()
    local soil = tonumber(types.SOIL) or 2
    local water = tonumber(types.WATERCAN) or 3
    local nutrient = tonumber(types.NUTRIENT) or 4
    local seed = tonumber(types.SEED) or 1
    local spore = tonumber(types.SPORE) or 5
    local cultType = tonumber(itemData.cultivationType) or 0
    if cultType == seed or cultType == spore then
        return nil
    end

    local stats = ParseStats(itemData)
    if cultType ~= soil and cultType ~= water and cultType ~= nutrient then
        if stats.growTime < 0 and stats.critChance > 0 and stats.superCrit <= 0 then
            cultType = soil
        elseif stats.growTime < 0 and stats.superCrit > 0 then
            cultType = water
        elseif stats.growTime < 0 and stats.failChance < 0 then
            cultType = nutrient
        else
            return nil
        end
    end

    local role = "soil"
    if cultType == water then
        role = "watering"
    elseif cultType == nutrient then
        role = "nutrient"
    end

    return {
        cultType = cultType,
        role = role,
        growTime = stats.growTime,
        critChance = stats.critChance,
        superCrit = stats.superCrit,
        failChance = stats.failChance,
    }
end

function AD.LearnFromItemData(itemData, source)
    local info = AD.Classify(itemData)
    if info == nil then
        return false
    end
    local stored = StoreRecord(itemData, info, source)
    return stored == true
end

function AD.LearnFromPlotRow(row)
    if type(row) ~= "table" then
        return 0
    end
    local n = 0
    local slots = row.additives or row.Additives
    if type(slots) ~= "table" then
        return 0
    end
    for _, slot in pairs(slots) do
        if type(slot) == "table" then
            local item = slot.item or slot
            if AD.LearnFromItemData(item, "plot") then
                n = n + 1
            end
        end
    end
    return n
end

function AD.CultTypeForStage(stageNum)
    stageNum = tonumber(stageNum) or 0
    local types = CultTypes()
    if stageNum == 1 then
        return tonumber(types.SOIL) or 2
    end
    if stageNum == 2 then
        return tonumber(types.WATERCAN) or 3
    end
    if stageNum == 3 then
        return tonumber(types.NUTRIENT) or 4
    end
    return 0
end

--- True when plot already has this additive slot filled.
function AD.PlotHasAdditive(plotData, cultType)
    cultType = tonumber(cultType) or 0
    if type(plotData) ~= "table" or cultType <= 0 then
        return false
    end
    if type(plotData.additives) == "table" then
        local slot = plotData.additives[cultType]
        if type(slot) == "table" then
            if slot.filled == true then
                return true
            end
            return (tonumber(slot.id) or 0) ~= 0
                or (tonumber(slot.uniqueID) or 0) ~= 0
        end
    end
    if type(plotData.Additives) == "table" then
        local slot = plotData.Additives[cultType]
        if type(slot) == "table" then
            return (tonumber(slot.id) or 0) ~= 0
                or (tonumber(slot.uniqueID) or 0) ~= 0
        end
    end
    return false
end

function AD.PlayerCultivationSkill()
    local CA = StockPiler.CultivatorAdapter
    if CA and CA.GetCultSkill then
        return tonumber(CA.GetCultSkill()) or 0
    end
    if StockPiler.TradeSkillCaps and StockPiler.TradeSkillCaps.GetCultSkill then
        return tonumber(StockPiler.TradeSkillCaps.GetCultSkill()) or 0
    end
    return 0
end

--- Score for stage preference: prefer higher superCrit, then crit, then shorter grow.
function AD.Score(info, skillReq, _iLevel)
    if type(info) ~= "table" then
        return -999999
    end
    skillReq = tonumber(skillReq) or tonumber(info.skillReq) or 0
    local score = (tonumber(info.superCrit) or 0) * 1000
        + (tonumber(info.critChance) or 0) * 10
        - (tonumber(info.growTime) or 0)
        - skillReq
    return score
end

--- Best usable additive of this cultType in the crafting bag.
--- @return bestSlot, bestItem, backpackType
function AD.FindBestInCraftBag(cultType, opts)
    cultType = tonumber(cultType) or 0
    if cultType <= 0 then
        return 0, nil, nil
    end
    local CA = StockPiler.CultivatorAdapter
    local backpackType = 4
    if CA and CA.CraftingBackpackType then
        backpackType = CA.CraftingBackpackType()
    elseif EA_Window_Backpack and EA_Window_Backpack.TYPE_CRAFTING then
        backpackType = EA_Window_Backpack.TYPE_CRAFTING
    end

    local bag = nil
    local Inv = StockPiler.Inventory
    if Inv and Inv._ready == true and type(Inv._itemBySlot) == "table"
        and type(Inv._itemBySlot.craft) == "table"
    then
        bag = Inv._itemBySlot.craft
    end
    if type(bag) ~= "table" and DataUtils and DataUtils.GetCraftingItems then
        local ok, items = pcall(DataUtils.GetCraftingItems)
        if ok then
            bag = items
        end
    end
    if type(bag) ~= "table" then
        return 0, nil, nil
    end

    opts = type(opts) == "table" and opts or {}
    local cheap = opts.policy == "cheap"
    local skill = AD.PlayerCultivationSkill()
    local bestSlot = 0
    local bestItem = nil
    local bestScore = nil
    for slot, item in pairs(bag) do
        if type(item) == "table" then
            local info = AD.Classify(item)
            if info and tonumber(info.cultType) == cultType then
                local req = tonumber(item.craftingSkillRequirement) or 0
                local usable = req <= skill
                if usable and Inv and Inv.CanUseCraftingItem then
                    usable = Inv.CanUseCraftingItem(item) == true
                end
                if usable then
                    local iLevel = tonumber(item.iLevel) or tonumber(item.level) or 0
                    local score = AD.Score(info, req, iLevel)
                    local better = bestScore == nil or (cheap and score < bestScore) or (not cheap and score > bestScore)
                    if better then
                        bestScore = score
                        bestSlot = tonumber(slot) or 0
                        bestItem = item
                    end
                end
            end
        end
    end
    if bestSlot <= 0 then
        return 0, nil, nil
    end
    return bestSlot, bestItem, backpackType
end

--- True when any growing plot needs Soil/Water/Nutrient for its current stage.
function AD.NeedsCurrentStage()
    if AD.IsEnabled() ~= true then
        return false
    end
    local Garden = StockPiler.Garden
    local plots = Garden and Garden.GetPlots and Garden.GetPlots()
    if type(plots) ~= "table" then
        local CA = StockPiler.CultivatorAdapter
        plots = CA and CA.GetPlots and CA.GetPlots()
    end
    if type(plots) ~= "table" then
        return false
    end
    for plotNum, plot in pairs(plots) do
        if type(plot) == "table" then
            local stage = tonumber(plot.stage) or 0
            local cultType = AD.CultTypeForStage(stage)
            if cultType > 0 and not AD.PlotHasAdditive(plot, cultType) then
                -- Only when a seed is present (not empty).
                if (tonumber(plot.seedUid) or 0) > 0 or stage > 0 then
                    return true
                end
            end
        end
    end
    return false
end

--- True when a plot needs an additive AND bags have one we can apply now.
--- Use this for AutoGrow wake/work so grow-wait does not 1s-tick CollectIntents.
function AD.CanApplyCurrentStage(opts)
    if AD.IsEnabled() ~= true then
        return false
    end
    opts = type(opts) == "table" and opts or {}
    local pending = opts.pendingAdditive
    if pending == nil and StockPiler.Grow then
        pending = StockPiler.Grow._pendingAdditive
    end
    local pick = AD.PickNext({
        pendingAdditive = pending,
        cursor = opts.cursor,
        stalled = opts.stalled or (StockPiler.Grow and StockPiler.Grow._additiveStall),
        plotReason = opts.plotReason or (StockPiler.Grow and StockPiler.Grow._plotReason),
    })
    return type(pick) == "table" and (tonumber(pick.plotNum) or 0) > 0
end

--- Pick one plot+bag slot for the next additive apply.
--- @return { plotNum, slot, backpackType, item, cultType, role } | nil
function AD.PickNext(opts)
    opts = type(opts) == "table" and opts or {}
    if AD.IsEnabled() ~= true then
        return nil
    end
    local CA = StockPiler.CultivatorAdapter
    local Garden = StockPiler.Garden
    local plots = Garden and Garden.GetPlots and Garden.GetPlots()
    if type(plots) ~= "table" then
        plots = CA and CA.GetPlots and CA.GetPlots()
    end
    if type(plots) ~= "table" then
        return nil
    end
    local n = CA and CA.NumPlots and CA.NumPlots() or 4
    local start = tonumber(opts.cursor) or 1
    if start < 1 or start > n then
        start = 1
    end
    local pending = opts.pendingAdditive
    local stalled = opts.stalled
    local reasons = opts.plotReason
    for i = 0, n - 1 do
        local plotNum = ((start - 1 + i) % n) + 1
        if type(pending) == "table" and (tonumber(pending[plotNum]) or 0) > 0 then
            -- Skip plots with an in-flight additive apply.
        elseif type(stalled) == "table" and stalled[plotNum] == true then
            -- Retry cap reached for this plot.
        else
            local plot = plots[plotNum]
            if type(plot) ~= "table" and Garden and Garden.GetPlot then
                plot = Garden.GetPlot(plotNum)
            end
            if type(plot) == "table" then
                local stage = tonumber(plot.stage) or 0
                local cultType = AD.CultTypeForStage(stage)
                if cultType > 0 and not AD.PlotHasAdditive(plot, cultType) then
                    local reason = type(reasons) == "table" and tostring(reasons[plotNum] or "") or ""
                    local policy = nil
                    if reason == "skill_up" or reason == "surplus" then
                        policy = "cheap"
                    end
                    local slot, item, backpackType = AD.FindBestInCraftBag(cultType, { policy = policy })
                    if (tonumber(slot) or 0) > 0 and type(item) == "table" then
                        local info = AD.Classify(item)
                        return {
                            plotNum = plotNum,
                            slot = slot,
                            backpackType = backpackType,
                            item = item,
                            cultType = cultType,
                            role = info and info.role or "?",
                            uniqueID = tonumber(item.uniqueID) or 0,
                        }
                    end
                end
            end
        end
    end
    return nil
end

function AD.IsEnabled()
    if StockPiler.Watch and StockPiler.Watch.IsAutoGrowAdditivesEnabled then
        return StockPiler.Watch.IsAutoGrowAdditivesEnabled() == true
    end
    if StockPiler.Persistence and StockPiler.Persistence.GetCharacterBucket then
        local row = StockPiler.Persistence.GetCharacterBucket(false)
        return type(row) == "table" and row.autoGrowAdditives == true
    end
    return false
end
