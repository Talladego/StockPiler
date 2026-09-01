----------------------------------------------------------------
-- StockPilerAdditives — learn Soil / Watering / Nutrient by craftingBonus
-- stats and pick the best matching item from the crafting bag.
--
-- Soil:      -XX% Stage Grow Time, +XX% Critical Chance
-- Watering:  -XX% Stage Grow Time, +X% Super-Critical Chance
-- Nutrient:  -XX% Stage Grow Time, -X% Fail Chance
----------------------------------------------------------------

StockPiler.Additives = StockPiler.Additives or {}

local function ToNarrow(text)
    return StockPiler.ToNarrow(text)
end

local function EnsureSettings()
    if StockPiler.EnsureSettings then
        return StockPiler.EnsureSettings()
    end
    return StockPiler.Settings
end

local function CultTypes()
    if GameData and GameData.CultivationTypes then
        return GameData.CultivationTypes
    end
    return { NONE = 0, SEED = 1, SOIL = 2, WATERCAN = 3, NUTRIENT = 4, SPORE = 5 }
end

local function FirstBonus(bonuses, ref)
    if type(bonuses) ~= "table" or type(bonuses[ref]) ~= "table" then
        return 0
    end
    return tonumber(bonuses[ref][1]) or 0
end

local function SignedBonus(val)
    val = tonumber(val) or 0
    if val > 32767 then
        return val - 65536
    end
    return val
end

local function ParseStats(itemData)
    local B = StockPiler.Inventory and StockPiler.Inventory.CraftBonus or {
        GROW_TIME = 10,
        CRITICAL_CHANCE = 12,
        FAIL_CHANCE = 13,
        SPECIAL_CHANCE = 14,
    }
    local bonuses = {}
    if type(itemData) == "table" and type(itemData.craftingBonus) == "table" then
        for _, bonus in pairs(itemData.craftingBonus) do
            if type(bonus) == "table" then
                local ref = tonumber(bonus.bonusReference) or 0
                if ref > 0 then
                    if bonuses[ref] == nil then
                        bonuses[ref] = {}
                    end
                    bonuses[ref][#bonuses[ref] + 1] = SignedBonus(bonus.bonusValue)
                end
            end
        end
    end
    return {
        growTime = FirstBonus(bonuses, B.GROW_TIME),
        critChance = FirstBonus(bonuses, B.CRITICAL_CHANCE),
        superCrit = FirstBonus(bonuses, B.SPECIAL_CHANCE),
        failChance = FirstBonus(bonuses, B.FAIL_CHANCE),
    }
end

--- Classify from cultivationType and/or the additive stat fingerprints.
function StockPiler.Additives.Classify(itemData)
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

    local stats = ParseStats(itemData) or {
        growTime = 0,
        critChance = 0,
        superCrit = 0,
        failChance = 0,
    }

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

function StockPiler.Additives.RoleLabel(role)
    if role == "watering" then
        return L"Watering"
    end
    if role == "nutrient" then
        return L"Nutrient"
    end
    return L"Soil"
end

function StockPiler.Additives.IsEnabled()
    if StockPiler.Inventory and StockPiler.Inventory.CultivatorState
        and StockPiler.Inventory.CultivatorState() == false
    then
        return false
    end
    local s = EnsureSettings()
    return type(s) == "table" and s.autoGrowAdditives == true
end

function StockPiler.Additives.SetEnabled(enabled)
    local s = EnsureSettings()
    if type(s) ~= "table" then
        return false
    end
    enabled = enabled == true
    if enabled and StockPiler.Inventory and StockPiler.Inventory.CultivatorState
        and StockPiler.Inventory.CultivatorState() == false
    then
        if StockPiler.Print then
            StockPiler.Print(L"Additives are only available to Cultivators.")
        end
        enabled = false
    end
    local changed = s.autoGrowAdditives ~= enabled
    s.autoGrowAdditives = enabled
    if StockPiler.PersistActiveCharacterSettings then
        StockPiler.PersistActiveCharacterSettings(s)
    end
    if changed then
        if StockPiler.LogOp then
            StockPiler.LogOp("settings", "Additives enabled=" .. tostring(enabled))
        end
        if StockPiler.NotifyManual then
            if enabled then
                StockPiler.NotifyManual(L"AutoGrow", L"Additives on. Uses Soil / Watering / Nutrient from the crafting bag during the matching stage.")
            else
                StockPiler.NotifyManual(L"AutoGrow", L"Additives off.")
            end
        end
    end
    return enabled
end

local function StoreRecord(itemData, info, source)
    local uid = tonumber(itemData.uniqueID) or tonumber(itemData.id) or 0
    if uid <= 0 then
        return false, false
    end
    local s = EnsureSettings()
    if type(s) ~= "table" then
        return false, false
    end
    if type(s.additives) ~= "table" then
        s.additives = {}
    end
    s.learnedAdditives = s.additives
    local key = tostring(uid)
    local isNew = s.additives[key] == nil
    local nameW = itemData.name
    if type(nameW) ~= "wstring" then
        nameW = towstring(tostring(itemData.name or ""))
    end
    s.additives[key] = {
        uniqueID = uid,
        iconNum = tonumber(itemData.iconNum) or 0,
        name = nameW,
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
    if StockPiler.Items and StockPiler.Items.UpsertFromItemData then
        StockPiler.Items.UpsertFromItemData(itemData, "additive")
    end
    return true, isNew
end

--- Persist a slim additive record when bags or a tooltip show Soil / Water / Nutrient.
function StockPiler.Additives.LearnFromItemData(itemData, source)
    local info = StockPiler.Additives.Classify(itemData)
    if info == nil then
        return false
    end
    local stored, isNew = StoreRecord(itemData, info, source)
    if stored and isNew and StockPiler.NotifyAdditiveLearned then
        StockPiler.NotifyAdditiveLearned(itemData, info)
    elseif stored and isNew and StockPiler.D then
        StockPiler.D("Learned additive uid=" .. tostring(itemData.uniqueID)
            .. " role=" .. tostring(info.role))
    end
    return stored
end

function StockPiler.Additives.LearnFromSnapshotSamples()
    local samples = StockPiler.Inventory and StockPiler.Inventory._sampleByUid
    if type(samples) ~= "table" then
        return
    end
    local types = CultTypes()
    local soil = tonumber(types.SOIL) or 2
    local water = tonumber(types.WATERCAN) or 3
    local nutrient = tonumber(types.NUTRIENT) or 4
    for _, item in pairs(samples) do
        if type(item) == "table" then
            local cult = tonumber(item.cultivationType) or 0
            if cult == soil or cult == water or cult == nutrient
                or (cult == 0 and type(item.craftingBonus) == "table")
            then
                StockPiler.Additives.LearnFromItemData(item, "bag")
            end
        end
    end
end

function StockPiler.Additives.PlayerCultivationSkill()
    local cult = (GameData and GameData.TradeSkills and GameData.TradeSkills.CULTIVATION) or 3
    if StockPiler.Inventory and StockPiler.Inventory.PlayerTradeSkill then
        return StockPiler.Inventory.PlayerTradeSkill(cult)
    end
    if GameData and GameData.TradeSkillLevels then
        return tonumber(GameData.TradeSkillLevels[cult]) or 0
    end
    return 0
end

--- Higher is better: Cultivating skill requirement first (highest usable),
--- then item level, then role bonus, then grow-time cut.
function StockPiler.Additives.Score(info, skillReq, iLevel)
    if type(info) ~= "table" then
        return 0
    end
    local roleScore = tonumber(info.critChance) or 0
    if info.role == "watering" then
        roleScore = tonumber(info.superCrit) or 0
    elseif info.role == "nutrient" then
        roleScore = -(tonumber(info.failChance) or 0)
    end
    local timeScore = -(tonumber(info.growTime) or 0)
    return (tonumber(skillReq) or 0) * 100000
        + (tonumber(iLevel) or 0) * 1000
        + roleScore * 100
        + timeScore
end

function StockPiler.Additives.StageForCultType(cultType)
    cultType = tonumber(cultType) or 0
    local types = CultTypes()
    if cultType == (tonumber(types.SOIL) or 2) then
        return (GameData and GameData.CultivationStage and GameData.CultivationStage.GERMINATION) or 1
    end
    if cultType == (tonumber(types.WATERCAN) or 3) then
        return (GameData and GameData.CultivationStage and GameData.CultivationStage.SEEDLING) or 2
    end
    if cultType == (tonumber(types.NUTRIENT) or 4) then
        return (GameData and GameData.CultivationStage and GameData.CultivationStage.FLOWERING) or 3
    end
    return nil
end

function StockPiler.Additives.CultTypeForStage(stageNum)
    stageNum = tonumber(stageNum) or 0
    local stages = GameData and GameData.CultivationStage
    local germ = (stages and stages.GERMINATION) or 1
    local seed = (stages and stages.SEEDLING) or 2
    local flower = (stages and stages.FLOWERING) or 3
    local types = CultTypes()
    if stageNum == germ then
        return tonumber(types.SOIL) or 2
    end
    if stageNum == seed then
        return tonumber(types.WATERCAN) or 3
    end
    if stageNum == flower then
        return tonumber(types.NUTRIENT) or 4
    end
    return nil
end

function StockPiler.Additives.PlotHasAdditive(plotData, cultType)
    cultType = tonumber(cultType) or 0
    if type(plotData) ~= "table" or type(plotData.Additives) ~= "table" or cultType <= 0 then
        return false
    end
    local slot = plotData.Additives[cultType]
    if type(slot) ~= "table" then
        return false
    end
    return (tonumber(slot.id) or 0) ~= 0
end

--- Best usable additive of this cultType in the crafting bag (live slots).
function StockPiler.Additives.FindBestInCraftBag(cultType)
    cultType = tonumber(cultType) or 0
    if cultType <= 0 then
        return 0, nil, nil
    end
    local bag = nil
    if DataUtils and DataUtils.GetCraftingItems then
        local ok, items = StockPiler.TryCallQuiet("DataUtils.GetCraftingItems", DataUtils.GetCraftingItems)
        if ok then
            bag = items
        end
    end
    if type(bag) ~= "table" then
        return 0, nil, nil
    end
    local skill = StockPiler.Additives.PlayerCultivationSkill()
    local backpackType = 4
    if EA_Window_Backpack and EA_Window_Backpack.TYPE_CRAFTING then
        backpackType = EA_Window_Backpack.TYPE_CRAFTING
    end
    local bestSlot = 0
    local bestItem = nil
    local bestScore = nil
    for slot, item in pairs(bag) do
        if type(item) == "table" then
            local info = StockPiler.Additives.Classify(item)
            if info and info.cultType == cultType then
                local req = tonumber(item.craftingSkillRequirement) or 0
                if req <= skill then
                    local iLevel = tonumber(item.iLevel) or tonumber(item.level) or 0
                    local score = StockPiler.Additives.Score(info, req, iLevel)
                    if bestScore == nil or score > bestScore then
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
