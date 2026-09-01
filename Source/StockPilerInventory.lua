----------------------------------------------------------------
-- Local bag / crafting-bag inventory (this character only)
-- Icons/tooltips: bags / AH / hovered tooltips first; else
-- GetDatabaseItemData(uniqueID) like chat ITEM: links.
-- Never use armory modelId with GetIconData.
----------------------------------------------------------------

StockPiler.Inventory = StockPiler.Inventory or {}

StockPiler.Inventory.byPotion = {}
StockPiler.Inventory._items = {}
StockPiler.Inventory._snapshotDone = false
-- Session-only full itemData for tooltips (not written to SavedVariables)
StockPiler.Inventory._learnedItemData = {} -- [potionId] = itemData copy
StockPiler.Inventory._learnedMatData = {} -- [matchKey or uid:NNN] = itemData copy
StockPiler.Inventory._dbItemCache = {} -- [uniqueID] = itemData from GetDatabaseItemData
StockPiler.Inventory._uiCachesValid = false
StockPiler.Inventory._cachedRecipeList = nil
StockPiler.Inventory._recipeYieldMap = nil

function StockPiler.Inventory.PrimaryRecipeOutput(outputs)
    if type(outputs) ~= "table" then
        return nil
    end
    local best = nil
    local bestCrafts = 0
    for i = 1, #outputs do
        local out = outputs[i]
        if type(out) == "table" then
            local crafts = tonumber(out.crafts) or 0
            if best == nil or crafts > bestCrafts then
                best = out
                bestCrafts = crafts
            end
        end
    end
    if best == nil then
        for _, out in pairs(outputs) do
            if type(out) == "table" then
                local crafts = tonumber(out.crafts) or 0
                if best == nil or crafts > bestCrafts then
                    best = out
                    bestCrafts = crafts
                end
            end
        end
    end
    return best
end

local function D(msg)
    if StockPiler and StockPiler.D then
        StockPiler.D(msg)
    end
end

local function ToNarrow(name)
    return StockPiler.ToNarrow(name)
end

local function NameContains(itemName, asciiNeedle)
    if asciiNeedle == nil or asciiNeedle == "" or itemName == nil then
        return false
    end
    local needle = string.lower(asciiNeedle)
    if needle == "" then
        return false
    end

    -- Prefer wide-string search (avoids WStringToString failures on some names)
    if type(itemName) == "wstring" and type(wstring) == "table" and type(wstring.find) == "function" then
        local ok, found = StockPiler.TryCallQuiet("NameContains.wstring.find", function()
            local hay = itemName
            if type(wstring.lower) == "function" then
                hay = wstring.lower(itemName)
            end
            return wstring.find(hay, towstring(needle), 1, true)
        end)
        if ok and found ~= nil then
            return true
        end
    end

    local n = string.lower(ToNarrow(itemName))
    if n == "" then
        return false
    end
    return string.find(n, needle, 1, true) ~= nil
end

local function NameEquals(itemName, asciiNeedle)
    if asciiNeedle == nil or asciiNeedle == "" or itemName == nil then
        return false
    end
    local needle = string.lower(asciiNeedle)
    if needle == "" then
        return false
    end
    local n = string.lower(ToNarrow(itemName))
    return n ~= "" and n == needle
end

local function MatchKeyImpliesSeedOrSpore(matchKey)
    if matchKey == nil or matchKey == "" then
        return false
    end
    local k = string.lower(tostring(matchKey))
    return string.find(k, " spore$", 1, true) ~= nil or string.find(k, " seed$", 1, true) ~= nil
end

local function IsCultivationSeedOrSpore(itemData)
    if type(itemData) ~= "table" then
        return false
    end
    local cultType = tonumber(itemData.cultivationType) or 0
    if cultType ~= 0 and GameData and GameData.CultivationTypes then
        local ct = GameData.CultivationTypes
        if cultType == ct.SEED or cultType == ct.SPORE then
            return true
        end
    end
    local n = string.lower(ToNarrow(itemData.name))
    if n == "" then
        return false
    end
    return string.find(n, " spore$", 1, true) ~= nil or string.find(n, " seed$", 1, true) ~= nil
end

function StockPiler.Inventory.IsSeedOrSporeItem(itemData)
    return IsCultivationSeedOrSpore(itemData)
end

--- Reject cultivation seeds/spores when resolving apothecary recipe materials by plant name.
local function IsValidRecipeMaterialSample(matchKey, itemData, expectedUid)
    if type(itemData) ~= "table" then
        return false
    end
    expectedUid = tonumber(expectedUid) or 0
    if expectedUid > 0 then
        local uid = tonumber(itemData.uniqueID) or tonumber(itemData.id) or 0
        if uid > 0 and uid ~= expectedUid then
            return false
        end
    end
    if IsCultivationSeedOrSpore(itemData) and not MatchKeyImpliesSeedOrSpore(matchKey) then
        return false
    end
    if matchKey and matchKey ~= "" then
        return NameEquals(itemData.name, matchKey)
    end
    return true
end

local function DescribeItem(item)
    if type(item) ~= "table" then
        return "nil"
    end
    return "name='"
        .. ToNarrow(item.name)
        .. "' nameType="
        .. type(item.name)
        .. " uid="
        .. tostring(item.uniqueID)
        .. " iconNum="
        .. tostring(item.iconNum)
        .. " stack="
        .. tostring(item.stackCount or item.StackCount)
end

local function ItemIsPresent(item)
    if type(item) ~= "table" then
        return false
    end
    local uid = item.uniqueID
    if uid ~= nil and uid ~= 0 and uid ~= "0" then
        return true
    end
    if item.name ~= nil and item.name ~= L"" and ToNarrow(item.name) ~= "" then
        return true
    end
    return false
end

local function StackSize(item)
    local n = tonumber(item.stackCount)
    if n == nil then
        n = tonumber(item.StackCount)
    end
    if n == nil or n < 1 then
        return 1
    end
    return n
end

--- Deep-ish copy so bonus[] Use effects survive SavedVariables / session cache.
local function CopyItemData(item)
    if type(item) ~= "table" then
        return nil
    end
    local function copyVal(v, depth)
        if type(v) ~= "table" then
            return v
        end
        if depth >= 4 then
            return nil
        end
        local out = {}
        for k, val in pairs(v) do
            local cv = copyVal(val, depth + 1)
            if cv ~= nil or type(val) ~= "table" then
                out[k] = cv
            end
        end
        return out
    end
    return copyVal(item, 0)
end

local function EnsureSettings()
    if StockPiler.EnsureSettings then
        return StockPiler.EnsureSettings()
    end
    return StockPiler.Settings
end

local function CatalogPotions()
    return (StockPiler.Catalog and StockPiler.Catalog.Potions)
        or (StockPiler.Mock and StockPiler.Mock.Potions)
        or {}
end

--- Pull bag tables the same way Shinies / Backpack do (DataUtils + dirty flags).
local function FetchBagTables()
    local bags = {}

    local function add(tbl)
        if type(tbl) == "table" then
            bags[#bags + 1] = tbl
        end
    end

    if GameData and GameData.Player then
        GameData.Player.itemsDirty = true
        GameData.Player.craftingItemsDirty = true
    end

    if DataUtils and type(DataUtils.GetItems) == "function" then
        local ok, data = StockPiler.TryCallQuiet("DataUtils.GetItems", DataUtils.GetItems)
        if ok then
            add(data)
        end
    elseif type(GetInventoryItemData) == "function" then
        local ok, data = StockPiler.TryCallQuiet("GetInventoryItemData", GetInventoryItemData)
        if ok then
            add(data)
        end
    end

    if GameData and GameData.Player then
        GameData.Player.craftingItemsDirty = true
    end
    if DataUtils and type(DataUtils.GetCraftingItems) == "function" then
        local ok, data = StockPiler.TryCallQuiet("DataUtils.GetCraftingItems", DataUtils.GetCraftingItems)
        if ok then
            add(data)
        end
    elseif type(GetCraftingItemData) == "function" then
        local ok, data = StockPiler.TryCallQuiet("GetCraftingItemData", GetCraftingItemData)
        if ok then
            add(data)
        end
    end

    return bags
end

--- Read cached bag tables without forcing engine rebuild (GatherButton-style).
local function FetchBagTablesLight()
    local bags = {}
    if DataUtils and type(DataUtils.GetItems) == "function" then
        local ok, data = StockPiler.TryCallQuiet("DataUtils.GetItems", DataUtils.GetItems)
        if ok and type(data) == "table" then
            bags[#bags + 1] = data
        end
    elseif type(GetInventoryItemData) == "function" then
        local ok, data = StockPiler.TryCallQuiet("GetInventoryItemData", GetInventoryItemData)
        if ok and type(data) == "table" then
            bags[#bags + 1] = data
        end
    end
    if DataUtils and type(DataUtils.GetCraftingItems) == "function" then
        local ok, data = StockPiler.TryCallQuiet("DataUtils.GetCraftingItems", DataUtils.GetCraftingItems)
        if ok and type(data) == "table" then
            bags[#bags + 1] = data
        end
    elseif type(GetCraftingItemData) == "function" then
        local ok, data = StockPiler.TryCallQuiet("GetCraftingItemData", GetCraftingItemData)
        if ok and type(data) == "table" then
            bags[#bags + 1] = data
        end
    end
    return bags
end

local function AppendBagItems(flat, seen, bag)
    if type(bag) ~= "table" then
        return
    end

    local function consider(slot, item)
        if not ItemIsPresent(item) then
            return
        end
        local uid = tonumber(item.uniqueID) or 0
        local key = tostring(uid) .. ":" .. tostring(slot) .. ":" .. ToNarrow(item.name)
        if seen[key] then
            return
        end
        seen[key] = true
        flat[#flat + 1] = item
    end

    -- Contiguous backpack slots (includes empty tables with uniqueID==0)
    local n = #bag
    if n > 0 then
        for slot = 1, n do
            consider(slot, bag[slot])
        end
        return
    end

    -- Sparse / non-array tables
    for slot, item in pairs(bag) do
        consider(slot, item)
    end
end

local function SnapshotItems(forceEngineRefresh)
    if StockPiler.Perf and StockPiler.Perf.Begin then
        StockPiler.Perf.Begin("SnapshotItems")
    end
    forceEngineRefresh = forceEngineRefresh == true
    local flat = {}
    local seen = {}
    local bags = forceEngineRefresh and FetchBagTables() or FetchBagTablesLight()
    for bi = 1, #bags do
        AppendBagItems(flat, seen, bags[bi])
    end
    StockPiler.Inventory._items = flat
    StockPiler.Inventory._itemCount = #flat
    StockPiler.Inventory._specParseCache = {}
    if StockPiler.MaterialSpec and StockPiler.MaterialSpec.FromItemDataCached then
        for i = 1, #flat do
            local item = flat[i]
            if type(item) == "table"
                and (type(item.craftingBonus) == "table"
                    or (tonumber(item.cultivationType) or 0) ~= 0)
            then
                StockPiler.MaterialSpec.FromItemDataCached(item, nil)
            end
        end
    end
    local countByUid = {}
    local sampleByUid = {}
    local refinableByPlantUid = {}
    local seedType = (GameData and GameData.CultivationTypes and GameData.CultivationTypes.SEED) or 1
    local sporeType = (GameData and GameData.CultivationTypes and GameData.CultivationTypes.SPORE) or 5
    local function isRefinablePlant(item)
        if type(item) ~= "table" then
            return false
        end
        if StockPiler.SeedMap and StockPiler.SeedMap.ItemLooksLikeRefinablePlant then
            return StockPiler.SeedMap.ItemLooksLikeRefinablePlant(item)
        end
        if item.isRefinable ~= true then
            return false
        end
        local cultType = tonumber(item.cultivationType) or 0
        if cultType == seedType or cultType == sporeType then
            return false
        end
        return true
    end
    for i = 1, #flat do
        local item = flat[i]
        local uid = tonumber(item.uniqueID) or 0
        if uid > 0 then
            local stack = StackSize(item)
            countByUid[uid] = (countByUid[uid] or 0) + stack
            if sampleByUid[uid] == nil then
                sampleByUid[uid] = item
            end
            if isRefinablePlant(item) then
                refinableByPlantUid[uid] = (refinableByPlantUid[uid] or 0) + stack
            end
        end
    end
    StockPiler.Inventory._countByUid = countByUid
    StockPiler.Inventory._sampleByUid = sampleByUid
    StockPiler.Inventory._refinableCountByPlantUid = refinableByPlantUid
    StockPiler.Inventory._snapshotGen = (tonumber(StockPiler.Inventory._snapshotGen) or 0) + 1
    StockPiler.Inventory._snapshotDone = true
    if StockPiler.Additives and StockPiler.Additives.LearnFromSnapshotSamples then
        StockPiler.Additives.LearnFromSnapshotSamples()
    end
    -- Keep the last plan/specDemand. A new snap gen already prevents
    -- BuildPlan reuse when the Watch tab asks for fresh craftable counts.
    -- Invalidating here made MaybeAutoRefine rebuild demand (~800ms).
    if StockPiler.Perf and StockPiler.Perf.End then
        StockPiler.Perf.End("SnapshotItems")
    end
    return flat
end

local function EachItem(fn)
    -- Empty bags are valid: do not resnapshot on every CountByName call.
    if not StockPiler.Inventory._snapshotDone then
        SnapshotItems(false)
    end
    local items = StockPiler.Inventory._items or {}
    for i = 1, #items do
        fn(items[i])
    end
end

function StockPiler.Inventory.CountByName(asciiNeedle)
    local total = 0
    local sample = nil
    EachItem(function(item)
        if NameContains(item.name, asciiNeedle) then
            total = total + StackSize(item)
            if sample == nil then
                sample = item
            end
        end
    end)
    return total, sample
end

--- Exact name match for recipe materials; never counts seeds/spores for plant names.
function StockPiler.Inventory.CountRecipeMaterialByName(asciiNeedle, expectedUid)
    asciiNeedle = ToNarrow(asciiNeedle)
    if asciiNeedle == "" then
        return 0, nil
    end
    expectedUid = tonumber(expectedUid) or 0
    local total = 0
    local sample = nil
    EachItem(function(item)
        if IsValidRecipeMaterialSample(asciiNeedle, item, expectedUid) then
            total = total + StackSize(item)
            if sample == nil then
                sample = item
            end
        end
    end)
    return total, sample
end

function StockPiler.Inventory.ForEachItem(fn)
    if type(fn) ~= "function" then
        return
    end
    EachItem(fn)
end

function StockPiler.Inventory.InvalidateRecipeCaches()
    StockPiler.Inventory._cachedRecipeList = nil
    StockPiler.Inventory._knownRecipeLookup = nil
    StockPiler.Inventory._recipeYieldMap = nil
end

function StockPiler.Inventory.InvalidateSnapshot()
    StockPiler.Inventory._snapshotDone = false
    StockPiler.Inventory._uiCachesValid = false
    StockPiler.Inventory._refinableCountByPlantUid = nil
end

--- Soft count update without a full bag flatten (brew post-craft).
--- Returns true when the snapshot indexes were adjusted.
function StockPiler.Inventory.AdjustCountByUid(uniqueID, delta)
    uniqueID = tonumber(uniqueID) or 0
    delta = tonumber(delta) or 0
    if uniqueID <= 0 or delta == 0 or StockPiler.Inventory._snapshotDone ~= true then
        return false
    end
    local counts = StockPiler.Inventory._countByUid
    if type(counts) ~= "table" then
        return false
    end
    local nextCount = (counts[uniqueID] or 0) + delta
    if nextCount < 0 then
        nextCount = 0
    end
    counts[uniqueID] = nextCount
    local refinable = StockPiler.Inventory._refinableCountByPlantUid
    if type(refinable) == "table" and refinable[uniqueID] ~= nil then
        local nextRef = (tonumber(refinable[uniqueID]) or 0) + delta
        if nextRef < 0 then
            nextRef = 0
        end
        refinable[uniqueID] = nextRef
    end
    StockPiler.Inventory._snapshotGen = (tonumber(StockPiler.Inventory._snapshotGen) or 0) + 1
    return true
end

function StockPiler.Inventory.CountByUniqueId(uniqueID)
    uniqueID = tonumber(uniqueID) or 0
    if uniqueID == 0 then
        return 0, nil
    end
    if not StockPiler.Inventory._snapshotDone then
        SnapshotItems(false)
    end
    local counts = StockPiler.Inventory._countByUid
    if type(counts) ~= "table" then
        return 0, nil
    end
    return counts[uniqueID] or 0, StockPiler.Inventory._sampleByUid and StockPiler.Inventory._sampleByUid[uniqueID]
end

local function MatchNeedles(entry)
    local needles = {}
    local seen = {}
    local function add(ascii)
        if ascii == nil or ascii == "" or seen[ascii] then
            return
        end
        seen[ascii] = true
        needles[#needles + 1] = ascii
    end
    if type(entry.matchNames) == "table" then
        for i = 1, #entry.matchNames do
            add(entry.matchNames[i])
        end
    end
    add(entry.matchName)
    return needles
end

local function EntryMatchesItem(entry, item)
    if entry == nil or item == nil then
        return false
    end
    local uid = tonumber(item.uniqueID) or 0
    if uid ~= 0 then
        if entry.uniqueID and tonumber(entry.uniqueID) == uid then
            return true
        end
        if type(entry.uniqueIDs) == "table" then
            for i = 1, #entry.uniqueIDs do
                if tonumber(entry.uniqueIDs[i]) == uid then
                    return true
                end
            end
        end
    end
    local needles = MatchNeedles(entry)
    for i = 1, #needles do
        if NameContains(item.name, needles[i]) then
            return true
        end
    end
    -- PotionBar-style effect classification (Strength/Intelligence/Armor/...)
    if entry.effectKey and StockPiler.Classify and StockPiler.Classify.GetEffectKey then
        local effectKey = StockPiler.Classify.GetEffectKey(item)
        if effectKey and effectKey == entry.effectKey then
            return true
        end
    end
    return false
end

--- Count by exact catalog uniqueID(s) only — no name/family grouping.
--- Potent and normal are different uniqueIDs, so they stay separate.
local function CountForEntry(entry)
    local total = 0
    local best = nil
    local bestScore = -1
    local idSet = {}
    if entry.uniqueID then
        local u = tonumber(entry.uniqueID) or 0
        if u > 0 then
            idSet[u] = true
        end
    end
    if type(entry.uniqueIDs) == "table" then
        for i = 1, #entry.uniqueIDs do
            local u = tonumber(entry.uniqueIDs[i]) or 0
            if u > 0 then
                idSet[u] = true
            end
        end
    end

    EachItem(function(item)
        local uid = tonumber(item.uniqueID) or 0
        if uid == 0 or not idSet[uid] then
            return
        end
        total = total + StackSize(item)
        local score = tonumber(item.iLevel) or tonumber(item.level) or 0
        if score > bestScore then
            bestScore = score
            best = item
        end
    end)

    return total, best
end

local function PersistPotionCache(potionId, itemData)
    if itemData == nil or potionId == nil then
        return
    end
    local iconNum = tonumber(itemData.iconNum) or 0
    if iconNum <= 0 then
        return
    end
    local copy = CopyItemData(itemData)
    if copy then
        if type(StockPiler.Inventory._learnedItemData) ~= "table" then
            StockPiler.Inventory._learnedItemData = {}
        end
        StockPiler.Inventory._learnedItemData[potionId] = copy
    end
end

local function PersistMatCache(matchKey, itemData)
    if itemData == nil or matchKey == nil then
        return
    end
    if not IsValidRecipeMaterialSample(matchKey, itemData, nil) then
        return
    end
    local iconNum = tonumber(itemData.iconNum) or 0
    if iconNum <= 0 then
        return
    end
    local copy = CopyItemData(itemData)
    if copy then
        if type(StockPiler.Inventory._learnedMatData) ~= "table" then
            StockPiler.Inventory._learnedMatData = {}
        end
        StockPiler.Inventory._learnedMatData[matchKey] = copy
    end
end

local function CachedPotionIcon(potionId)
    local s = EnsureSettings()
    if type(s) == "table" and type(s.iconCache) == "table" then
        local c = s.iconCache[potionId]
        if c then
            return tonumber(c.iconNum) or 0
        end
    end
    return 0
end

local function CachedPotionUniqueId(potionId)
    local s = EnsureSettings()
    if type(s) == "table" and type(s.iconCache) == "table" then
        local c = s.iconCache[potionId]
        if c then
            return tonumber(c.uniqueID) or 0
        end
    end
    return 0
end

local function CachedMatIcon(matchKey)
    local s = EnsureSettings()
    if type(s) == "table" and type(s.matIconCache) == "table" then
        local c = s.matIconCache[matchKey]
        if c then
            return tonumber(c.iconNum) or 0
        end
    end
    return 0
end

local function CachedMatUniqueId(matchKey)
    local s = EnsureSettings()
    if type(s) == "table" and type(s.matIconCache) == "table" then
        local c = s.matIconCache[matchKey]
        if c then
            return tonumber(c.uniqueID) or 0
        end
    end
    return 0
end

--- Ordered uniqueID list (deduped). Same idea as chat ITEM:<id> links.
local function CollectUniqueIds(...)
    local ids = {}
    local seen = {}
    local function addOne(id)
        id = tonumber(id) or 0
        if id > 0 and not seen[id] then
            seen[id] = true
            ids[#ids + 1] = id
        end
    end
    local function addArg(arg)
        if arg == nil then
            return
        end
        local t = type(arg)
        if t == "number" or t == "string" then
            addOne(arg)
        elseif t == "table" then
            -- Prefer array entries; also allow { uniqueID = n }
            local n = #arg
            if n > 0 then
                for i = 1, n do
                    addOne(arg[i])
                end
            end
            if arg.uniqueID ~= nil then
                addOne(arg.uniqueID)
            end
        end
    end
    for i = 1, select("#", ...) do
        addArg(select(i, ...))
    end
    return ids
end

--- Client item DB lookup (same source as chat item-link popups).
local function DatabaseItemUsable(data)
    if type(data) ~= "table" then
        return false
    end
    local uid = tonumber(data.uniqueID) or tonumber(data.id) or 0
    if uid > 0 then
        return true
    end
    local iconNum = tonumber(data.iconNum) or 0
    if iconNum > 0 then
        return true
    end
    if data.name ~= nil and ToNarrow(data.name) ~= "" then
        return true
    end
    return false
end

--- Green "Use:" lines need itemData.bonus with ITEMBONUS_USE.
local function ItemDataHasUseBonus(itemData)
    if type(itemData) ~= "table" or type(itemData.bonus) ~= "table" then
        return false
    end
    local useType = 3
    if GameDefs and GameDefs.ITEMBONUS_USE then
        useType = GameDefs.ITEMBONUS_USE
    end
    for _, bonus in ipairs(itemData.bonus) do
        if type(bonus) == "table" and bonus.type == useType and bonus.reference and bonus.reference ~= 0 then
            return true
        end
    end
    return false
end

--- Only cache as the catalog row's tooltip sample if it is that recipe (not a random family cousin).
local function IsCatalogTooltipSample(entry, itemData)
    if entry == nil or type(itemData) ~= "table" then
        return false
    end
    local uid = tonumber(itemData.uniqueID) or tonumber(itemData.id) or 0
    local hasCatalogIds = false
    if entry.uniqueID and tonumber(entry.uniqueID) and tonumber(entry.uniqueID) > 0 then
        hasCatalogIds = true
    end
    if type(entry.uniqueIDs) == "table" then
        for i = 1, #entry.uniqueIDs do
            if tonumber(entry.uniqueIDs[i]) and tonumber(entry.uniqueIDs[i]) > 0 then
                hasCatalogIds = true
                break
            end
        end
    end
    if uid > 0 then
        if entry.uniqueID and tonumber(entry.uniqueID) == uid then
            return true
        end
        if type(entry.uniqueIDs) == "table" then
            for i = 1, #entry.uniqueIDs do
                if tonumber(entry.uniqueIDs[i]) == uid then
                    return true
                end
            end
        end
    end
    -- Catalog lists explicit uniqueIDs: reject name-only cousins (Securing vs Stanchion, etc.).
    if hasCatalogIds then
        return false
    end
    -- Name must hit a catalog needle (Verity/Power/...), not merely effectKey=bs (Awareness etc.).
    local needles = MatchNeedles(entry)
    local hit = false
    for i = 1, #needles do
        if NameContains(itemData.name, needles[i]) then
            hit = true
            break
        end
    end
    if not hit then
        return false
    end
    local nm = string.lower(ToNarrow(itemData.name))
    -- Prefer Lasting for buff rows; allow non-lasting for draughts (heal/ap).
    if entry.effectKey == "heal" or entry.effectKey == "ap" then
        return true
    end
    return string.find(nm, "lasting", 1, true) ~= nil
end

local function PreferRicherItemData(a, b)
    if a == nil then
        return b
    end
    if b == nil then
        return a
    end
    local aUse = ItemDataHasUseBonus(a)
    local bUse = ItemDataHasUseBonus(b)
    if aUse and not bUse then
        return a
    end
    if bUse and not aUse then
        return b
    end
    return a
end

local function LookupDatabaseItem(ids)
    if GetDatabaseItemData == nil then
        return nil
    end
    -- Engine C bindings may report as function or userdata
    local apiType = type(GetDatabaseItemData)
    if apiType ~= "function" and apiType ~= "userdata" then
        return nil
    end
    if type(ids) ~= "table" or #ids == 0 then
        return nil
    end
    for i = 1, #ids do
        local id = tonumber(ids[i]) or 0
        if id > 0 then
            if StockPiler.Inventory._dbItemCache[id] then
                return StockPiler.Inventory._dbItemCache[id]
            end
            local ok, data = StockPiler.TryCallQuiet("GetDatabaseItemData", GetDatabaseItemData, id)
            if ok and DatabaseItemUsable(data) then
                StockPiler.Inventory._dbItemCache[id] = data
                return data
            end
        end
    end
    return nil
end

function StockPiler.Inventory.GetDatabaseItemByIds(...)
    return LookupDatabaseItem(CollectUniqueIds(...))
end

--- Thin itemData from Account.items / Account.potions when bags have no sample.
local function CatalogItemFromAccount(uid)
    uid = tonumber(uid) or 0
    if uid <= 0 then
        return nil
    end
    if StockPiler.Items and StockPiler.Items.AsItemData then
        local data = StockPiler.Items.AsItemData(uid)
        if type(data) == "table" and (tonumber(data.iconNum) or 0) > 0 then
            return data
        end
    end
    local s = EnsureSettings()
    if type(s) ~= "table" then
        return nil
    end
    local potions = s.potions or s.knownPotions
    if type(potions) == "table" then
        local pot = potions["uid:" .. tostring(uid)]
        if type(pot) == "table" then
            return {
                uniqueID = uid,
                name = pot.name,
                nameNarrow = pot.nameNarrow,
                iconNum = tonumber(pot.iconNum) or 0,
                craftingSkillRequirement = 0,
            }
        end
    end
    if type(s.items) == "table" then
        local row = s.items[tostring(uid)]
        if type(row) == "table" then
            return {
                uniqueID = uid,
                name = row.name,
                nameNarrow = row.nameNarrow,
                iconNum = tonumber(row.iconNum) or 0,
                craftingSkillRequirement = tonumber(row.skillReq) or 0,
                tradeSkill = tonumber(row.tradeSkill) or 0,
                cultivationType = tonumber(row.cultivationType) or 0,
                isRefinable = row.isRefinable == true,
                itemType = tonumber(row.itemType) or 0,
                type = tonumber(row.itemType) or 0,
                iLevel = tonumber(row.iLevel) or 0,
            }
        end
    end
    return nil
end

--- Fill icon/item caches from Account potions/items when bags are empty.
function StockPiler.Inventory.HydrateCatalogCachesFromObserved()
    for _, entry in ipairs(CatalogPotions()) do
        if entry.id then
            local ids = CollectUniqueIds(entry.uniqueID, entry.uniqueIDs)
            for i = 1, #ids do
                local data = CatalogItemFromAccount(ids[i])
                if type(data) == "table" and IsCatalogTooltipSample(entry, data) then
                    PersistPotionCache(entry.id, data)
                    break
                end
            end
        end
    end
end

--- Resolve best itemData for tooltips: bag/live -> session/SV -> GetDatabaseItemData(uniqueID).
--- Note: on RoR, GetDatabaseItemData often returns nil until the client has seen the item,
--- and even then may return a shell without bonus[] (no green Use text).
function StockPiler.Inventory.ResolveTooltipItemData(entry, existing)
    if entry == nil then
        return existing
    end
    local learned = StockPiler.Inventory._learnedItemData[entry.id]
    local dbItem = LookupDatabaseItem(CollectUniqueIds(
        entry.uniqueID,
        entry.uniqueIDs,
        CachedPotionUniqueId(entry.id),
        learned and learned.uniqueID,
        learned and learned.id,
        existing and existing.uniqueID
    ))

    local best = nil
    -- Prefer full Use-bonus blobs (bag / saved) over thin DB shells.
    if type(existing) == "table" and DatabaseItemUsable(existing) and IsCatalogTooltipSample(entry, existing) then
        best = PreferRicherItemData(best, existing)
    end
    if type(learned) == "table" and DatabaseItemUsable(learned) and IsCatalogTooltipSample(entry, learned) then
        best = PreferRicherItemData(best, learned)
    end
    local catalogIds = CollectUniqueIds(entry.uniqueID, entry.uniqueIDs)
    for i = 1, #catalogIds do
        local acctItem = CatalogItemFromAccount(catalogIds[i])
        if type(acctItem) == "table" and DatabaseItemUsable(acctItem) and IsCatalogTooltipSample(entry, acctItem) then
            best = PreferRicherItemData(best, acctItem)
        end
    end
    if type(dbItem) == "table" and DatabaseItemUsable(dbItem) then
        best = PreferRicherItemData(best, dbItem)
        if best == dbItem and ItemDataHasUseBonus(dbItem) then
            PersistPotionCache(entry.id, dbItem)
        end
    end
    -- Last resort: bag/learned sample only if it belongs to this catalog row
    if best == nil then
        if type(existing) == "table" and DatabaseItemUsable(existing) and IsCatalogTooltipSample(entry, existing) then
            best = existing
        elseif type(learned) == "table" and DatabaseItemUsable(learned) and IsCatalogTooltipSample(entry, learned) then
            best = learned
        end
    end
    return best
end

--- CreateItemTooltip / SetItemTooltipData assume bag-shaped fields.
--- GetDatabaseItemData shells often omit timeLeftBeforeDecay, flags, stackCount
--- and then pcall fails, so the Watch/Potions tabs fall back to a text tooltip.
function StockPiler.Inventory.NormalizeItemDataForTooltip(itemData)
    if type(itemData) ~= "table" then
        return nil
    end
    local data = CopyItemData(itemData)
    if type(data) ~= "table" then
        data = itemData
    end
    if data.timeLeftBeforeDecay == nil then
        data.timeLeftBeforeDecay = 0
    end
    if data.equipSlot == nil then
        data.equipSlot = 0
    end
    local stacks = tonumber(data.stackCount) or 0
    if stacks < 1 then
        data.stackCount = 1
    end
    if type(data.bonus) ~= "table" then
        data.bonus = {}
    end
    if type(data.flags) ~= "table" then
        data.flags = {}
    end
    if data.broken == nil then
        data.broken = false
    end
    if data.sellPrice == nil then
        data.sellPrice = 0
    end
    if data.repairPrice == nil then
        data.repairPrice = 0
    end
    if data.name == nil then
        data.name = L""
    end
    return data
end

function StockPiler.Inventory.ResolvePotionItemData(potionKey, uid, existing)
    uid = tonumber(uid) or 0
    if uid <= 0 and type(potionKey) == "string" then
        local fromKey = string.match(potionKey, "^uid:(%d+)")
        uid = tonumber(fromKey) or 0
    end
    if uid <= 0 then
        return existing
    end
    local entry = {
        id = potionKey or ("uid:" .. tostring(uid)),
        uniqueID = uid,
        uniqueIDs = { uid },
    }
    if type(existing) ~= "table" then
        local _, sample = StockPiler.Inventory.CountByUniqueId(uid)
        existing = sample
    end
    if type(existing) ~= "table" then
        existing = CatalogItemFromAccount(uid)
    end
    if type(existing) ~= "table" then
        existing = StockPiler.Inventory._learnedItemData[entry.id]
            or StockPiler.Inventory._learnedItemData["uid:" .. tostring(uid)]
    end
    return StockPiler.Inventory.ResolveTooltipItemData(entry, existing) or existing
end

function StockPiler.Inventory.ShowItemTooltip(itemData, anchorWindow, extraText)
    if type(itemData) ~= "table" or type(Tooltips) ~= "table"
        or type(Tooltips.CreateItemTooltip) ~= "function"
    then
        return false
    end
    -- Thin Account/DB shells lack bonus[] Use lines; CreateItemTooltip then looks wrong
    -- or fails. Only show the stock item tooltip when we have real Use data (usually bags).
    if not ItemDataHasUseBonus(itemData) then
        return false
    end
    local data = StockPiler.Inventory.NormalizeItemDataForTooltip(itemData)
    if type(data) ~= "table" then
        return false
    end
    if extraText ~= nil and extraText ~= L"" and type(extraText) == "string" then
        extraText = towstring(extraText)
    end
    if extraText == L"" then
        extraText = nil
    end
    local ok = StockPiler.TryCall(
        "Tooltips.CreateItemTooltip", Tooltips.CreateItemTooltip,
        data,
        anchorWindow or SystemData.ActiveWindow.name,
        Tooltips.ANCHOR_WINDOW_RIGHT,
        true,
        extraText,
        nil,
        true
    )
    return ok == true
end

function StockPiler.Inventory.ResolveTooltipMatData(mat, existing)
    if mat == nil then
        return type(existing) == "table" and existing or nil
    end

    local uid = tonumber(mat.uniqueID) or 0
    local best = nil

    if uid > 0 then
        local _, sample = StockPiler.Inventory.CountByUniqueId(uid)
        if type(sample) == "table" then
            best = PreferRicherItemData(best, sample)
        end
    end

    if mat.match and mat.match ~= "" then
        local _, sample = StockPiler.Inventory.CountRecipeMaterialByName(mat.match, uid)
        if type(sample) == "table" then
            best = PreferRicherItemData(best, sample)
        end
        local learned = StockPiler.Inventory._learnedMatData[mat.match]
        if type(learned) == "table" and IsValidRecipeMaterialSample(mat.match, learned, uid) then
            best = PreferRicherItemData(best, learned)
        end
        local sCache = EnsureSettings()
        if type(sCache) == "table" and type(sCache.matDataCache) == "table" then
            local cached = sCache.matDataCache[mat.match]
            if type(cached) == "table" and IsValidRecipeMaterialSample(mat.match, cached, uid) then
                best = PreferRicherItemData(best, cached)
            end
        end
    end

    if uid > 0 then
        local key = StockPiler.Inventory.ObservedId(uid)
        if key then
            local byUid = StockPiler.Inventory._learnedMatData[key]
            if type(byUid) == "table" then
                best = PreferRicherItemData(best, byUid)
            end
        end
        local acctItem = CatalogItemFromAccount(uid)
        if type(acctItem) == "table" then
            best = PreferRicherItemData(best, acctItem)
        end
    end

    if type(existing) == "table" then
        best = PreferRicherItemData(best, existing)
    end

    local dbItem = LookupDatabaseItem(CollectUniqueIds(
        uid,
        CachedMatUniqueId(mat.match),
        best and best.uniqueID,
        best and best.id
    ))
    if dbItem and IsValidRecipeMaterialSample(mat.match, dbItem, uid) then
        best = PreferRicherItemData(best, dbItem)
        if mat.match then
            PersistMatCache(mat.match, dbItem)
        elseif uid > 0 and type(dbItem.name) == "wstring" then
            local narrow = ToNarrow(dbItem.name)
            if narrow ~= "" then
                PersistMatCache(narrow, dbItem)
            end
        end
    end

    if type(best) == "table" and not IsValidRecipeMaterialSample(mat.match, best, uid) then
        best = nil
    end
    if best == nil and type(existing) == "table"
        and IsValidRecipeMaterialSample(mat.match, existing, uid)
    then
        best = existing
    end

    return best
end

--- GameData.ItemTypes.POTION (31) — includes pies/renown pots that are typed Potion.
local function IsPotionType(itemData)
    if type(itemData) ~= "table" then
        return false
    end
    if GameData and GameData.ItemTypes and GameData.ItemTypes.POTION then
        return itemData.type == GameData.ItemTypes.POTION
    end
    return tonumber(itemData.type) == 31
end

local CRAFTING_FAMILY_REF = 5 -- GameData.CraftingBonusRef.CRAFTING_FAMILY
local CRAFTING_TYPE_REF = 8 -- GameData.CraftingBonusRef.TYPE

local function CraftingBonusRefs()
    local family = CRAFTING_FAMILY_REF
    local typ = CRAFTING_TYPE_REF
    if GameData and GameData.CraftingBonusRef then
        family = GameData.CraftingBonusRef.CRAFTING_FAMILY or family
        typ = GameData.CraftingBonusRef.TYPE or typ
    end
    return family, typ
end

--- Parse craftingBonus like CraftingSystem.GetCraftingData (no CraftingWindow dependency).
local function GetCraftingFamiliesAndResource(itemData)
    local families = {}
    local resourceType = 0
    if type(itemData) ~= "table" or type(itemData.craftingBonus) ~= "table" then
        return families, resourceType
    end
    local familyRef, typeRef = CraftingBonusRefs()
    for _, bonus in ipairs(itemData.craftingBonus) do
        if type(bonus) == "table" then
            local ref = tonumber(bonus.bonusReference) or 0
            local val = tonumber(bonus.bonusValue) or 0
            if ref == familyRef and val > 0 then
                families[#families + 1] = val
            elseif ref == typeRef and val > 0 then
                resourceType = val
            end
        end
    end
    return families, resourceType
end

local function IsCultivationMat(itemData)
    return type(itemData) == "table"
        and tonumber(itemData.cultivationType)
        and tonumber(itemData.cultivationType) ~= 0
end

local function IsApothecaryMat(itemData)
    if type(itemData) ~= "table" then
        return false
    end
    -- Prefer DataUtils when crafting UI is loaded
    if DataUtils and type(DataUtils.IsTradeSkillItem) == "function"
        and GameData and GameData.TradeSkills and GameData.TradeSkills.APOTHECARY
    then
        local ok, result = StockPiler.TryCallQuiet("DataUtils.IsTradeSkillItem", DataUtils.IsTradeSkillItem, itemData, GameData.TradeSkills.APOTHECARY)
        if ok and result == true then
            return true
        end
    end
    local apo = (GameData and GameData.TradeSkills and GameData.TradeSkills.APOTHECARY) or 4
    local families = GetCraftingFamiliesAndResource(itemData)
    for i = 1, #families do
        if families[i] == apo then
            return true
        end
    end
    return false
end

--- Only Apothecary + Cultivation (not Talisman / Salvaging / generic Crafting).
local function IsApothecaryOrCultivationMat(itemData)
    if type(itemData) ~= "table" then
        return false
    end
    if IsCultivationMat(itemData) then
        return true
    end
    return IsApothecaryMat(itemData)
end

--- tradeSkill id + resource/cultivation subtype for UI ("200 Apothecary - Main").
local function ClassifyMat(itemData)
    local skillReq = tonumber(itemData.craftingSkillRequirement) or 0
    local cultType = tonumber(itemData.cultivationType) or 0
    if cultType ~= 0 then
        local cult = (GameData and GameData.TradeSkills and GameData.TradeSkills.CULTIVATION) or 3
        return cult, cultType, skillReq, "cultivation"
    end
    local apo = (GameData and GameData.TradeSkills and GameData.TradeSkills.APOTHECARY) or 4
    local families, resourceType = GetCraftingFamiliesAndResource(itemData)
    for i = 1, #families do
        if families[i] == apo then
            return apo, resourceType, skillReq, "apothecary"
        end
    end
    return 0, 0, skillReq, nil
end

function StockPiler.Inventory.ObservedId(uniqueID)
    uniqueID = tonumber(uniqueID) or 0
    if uniqueID <= 0 then
        return nil
    end
    return "uid:" .. tostring(uniqueID)
end

--- Legacy helper: never writes observed* tables; upserts Account.items only.
local function StoreObservedRecord(bucket, itemData, source, logLabel)
    if type(itemData) ~= "table" then
        return false
    end
    local uid = tonumber(itemData.uniqueID) or tonumber(itemData.id) or 0
    if uid <= 0 then
        return false
    end
    local iconNum = tonumber(itemData.iconNum) or 0
    if iconNum <= 0 then
        return false
    end
    local kindHint = "mat"
    if bucket == "observedPotions" or bucket == "potions" then
        kindHint = "potion"
    else
        local _, _, _, kind = ClassifyMat(itemData)
        kindHint = kind or "mat"
    end
    local existed = StockPiler.Items and StockPiler.Items.Get and StockPiler.Items.Get(uid) ~= nil
    if StockPiler.Items and StockPiler.Items.UpsertFromItemData then
        StockPiler.Items.UpsertFromItemData(itemData, kindHint)
    end
    local key = StockPiler.Inventory.ObservedId(uid)
    local copy = CopyItemData(itemData)
    if key and copy then
        if kindHint == "potion" then
            StockPiler.Inventory._learnedItemData[key] = copy
        else
            StockPiler.Inventory._learnedMatData[key] = copy
        end
    end
    if not existed and StockPiler.NotifyItemCollected then
        local nameW = itemData.name
        if type(nameW) ~= "wstring" then
            nameW = towstring(tostring(itemData.name or ""))
        end
        StockPiler.NotifyItemCollected({
            uniqueID = uid,
            iconNum = iconNum,
            name = nameW,
            nameNarrow = ToNarrow(itemData.name),
            source = source or "unknown",
        }, kindHint == "potion" and "potions" or "items", source)
    end
    return true
end

--- Scan bags for catalog cache / additive / seed registration (no observed* writes).
function StockPiler.Inventory.LearnNewFromBags(source)
    if StockPiler.Perf and StockPiler.Perf.Begin then
        StockPiler.Perf.Begin("LearnNewFromBags")
    end
    source = source or "bag"
    StockPiler.Inventory._snapshotDone = false
    SnapshotItems(false)
    local items = StockPiler.Inventory._items or {}
    for i = 1, #items do
        StockPiler.Inventory.LearnFromItemData(items[i], source)
    end
    if StockPiler.Perf and StockPiler.Perf.End then
        StockPiler.Perf.End("LearnNewFromBags")
    end
end

--- No-op: brew path registers potions via RecipeSpec.RegisterKnownPotion.
function StockPiler.Inventory.ObservePotion(itemData, source)
    return false
end

--- Upsert apo/cult mat into Account.items (never observedMats). Callers: refine/harvest/brew only.
function StockPiler.Inventory.ObserveMat(itemData, source)
    if not IsApothecaryOrCultivationMat(itemData) then
        return false
    end
    if IsPotionType(itemData) then
        return false
    end
    local _, _, _, kind = ClassifyMat(itemData)
    if StockPiler.Items and StockPiler.Items.UpsertFromItemData then
        StockPiler.Items.UpsertFromItemData(itemData, kind or "mat")
        local uid = tonumber(itemData.uniqueID) or tonumber(itemData.id) or 0
        local key = StockPiler.Inventory.ObservedId(uid)
        local copy = CopyItemData(itemData)
        if key and copy then
            StockPiler.Inventory._learnedMatData[key] = copy
        end
        return true
    end
    return false
end

--- True if a saved mat record is still in scope (Apothecary / Cultivation).
function StockPiler.Inventory.IsObservedMatInScope(obs)
    if type(obs) ~= "table" then
        return false
    end
    if type(obs.itemData) == "table" then
        return IsApothecaryOrCultivationMat(obs.itemData)
    end
    if obs.matKind == "apothecary" or obs.matKind == "cultivation" then
        return true
    end
    if tonumber(obs.cultivationType) and tonumber(obs.cultivationType) ~= 0 then
        return true
    end
    local apo = (GameData and GameData.TradeSkills and GameData.TradeSkills.APOTHECARY) or 4
    if tonumber(obs.tradeSkill) == apo then
        return true
    end
    return false
end

--- Learn icon/tooltip data from any live itemData (bags, AH, tooltip mouseover).
--- Does not bag-scan into Account.items/potions; brew/plant/harvest/refine register those.
function StockPiler.Inventory.LearnFromItemData(itemData, source)
    if type(itemData) ~= "table" then
        return false
    end
    local iconNum = tonumber(itemData.iconNum) or 0
    if iconNum <= 0 then
        return false
    end

    local learned = false
    -- Skip ObservePotion / ObserveMat / RegisterFromItem: no bag "observe everything".
    -- Brew / harvest / refine paths register items and grow links explicitly.
    if StockPiler.Additives and StockPiler.Additives.LearnFromItemData then
        if StockPiler.Additives.LearnFromItemData(itemData, source) then
            learned = true
        end
    end

    for _, entry in ipairs(CatalogPotions()) do
        if IsCatalogTooltipSample(entry, itemData) then
            PersistPotionCache(entry.id, itemData)
            learned = true
        end
        if entry.materials then
            for _, mat in ipairs(entry.materials) do
                if mat.match and IsValidRecipeMaterialSample(mat.match, itemData, nil) then
                    PersistMatCache(mat.match, itemData)
                    learned = true
                end
            end
        end
    end
    return learned
end

function StockPiler.Inventory.LearnFromAuctionResults(results)
    if type(results) ~= "table" then
        return 0
    end
    local n = 0
    for _, auction in ipairs(results) do
        local itemData = auction and auction.itemData
        if itemData and StockPiler.Inventory.LearnFromItemData(itemData, "auction") then
            n = n + 1
        end
    end
    return n
end

--- Learn from a bag-like table (slot -> itemData). Does not affect Have counts.
function StockPiler.Inventory.LearnFromItemContainer(container, source)
    if type(container) ~= "table" then
        return 0
    end
    local n = 0
    for _, itemData in pairs(container) do
        if type(itemData) == "table" and StockPiler.Inventory.LearnFromItemData(itemData, source) then
            n = n + 1
        end
    end
    return n
end

--- Guild vault open payload: [vaultIndex].itemsAttached[slot] = itemData
--- Update payload: [vaultIndex].itemsUpdated[slot] = itemData
function StockPiler.Inventory.LearnFromGuildVaultData(vaultDataTable, source)
    if type(vaultDataTable) ~= "table" then
        return 0
    end
    source = source or "guildvault"
    local n = 0
    for _, vault in pairs(vaultDataTable) do
        if type(vault) == "table" then
            if type(vault.itemsAttached) == "table" then
                n = n + StockPiler.Inventory.LearnFromItemContainer(vault.itemsAttached, source)
            end
            if type(vault.itemsUpdated) == "table" then
                n = n + StockPiler.Inventory.LearnFromItemContainer(vault.itemsUpdated, source)
            end
        end
    end
    return n
end

function StockPiler.Inventory.LearnFromBankData(source)
    source = source or "bank"
    local bank = nil
    if DataUtils and type(DataUtils.GetBankData) == "function" then
        if GameData and GameData.Player then
            GameData.Player.bankItemsDirty = true
        end
        local ok, data = StockPiler.TryCallQuiet("DataUtils.GetBankData", DataUtils.GetBankData)
        if ok then
            bank = data
        end
    elseif type(GetBankData) == "function" then
        local ok, data = StockPiler.TryCallQuiet("GetBankData", GetBankData)
        if ok then
            bank = data
        end
    end
    local n = StockPiler.Inventory.LearnFromItemContainer(bank, source)
    return n
end

--- Vendor / interaction store listings (GetStoreData returns itemData rows).
function StockPiler.Inventory.LearnFromStoreData(source)
    source = source or "store"
    local store = nil
    if type(GetStoreData) == "function" then
        local ok, data = StockPiler.TryCallQuiet("GetStoreData", GetStoreData)
        if ok then
            store = data
        end
    end
    if type(store) ~= "table" and EA_Window_InteractionStore and type(EA_Window_InteractionStore.storedata) == "table" then
        store = EA_Window_InteractionStore.storedata
    end
    local n = StockPiler.Inventory.LearnFromItemContainer(store, source)
    -- Buy-back list also carries full itemData
    local buyback = nil
    if type(GetBuyBackData) == "function" then
        local ok, data = StockPiler.TryCallQuiet("GetBuyBackData", GetBuyBackData)
        if ok then
            buyback = data
        end
    end
    if type(buyback) ~= "table" and EA_Window_InteractionStore and type(EA_Window_InteractionStore.buyBackData) == "table" then
        buyback = EA_Window_InteractionStore.buyBackData
    end
    n = n + StockPiler.Inventory.LearnFromItemContainer(buyback, source .. "-buyback")
    return n
end

local function TargetCrafts(entry, uniqueID)
    local s = EnsureSettings()
    local min = 0
    if type(s) == "table" and type(s.mins) == "table" and type(entry) == "table" then
        min = tonumber(s.mins[entry.id]) or 0
    end
    if min <= 0 and type(entry) == "table" then
        min = tonumber(entry.defaultMin) or 0
    end
    local yield = 2
    if StockPiler.Inventory and StockPiler.Inventory.RecipeYieldForEntry then
        local learnedYield = StockPiler.Inventory.RecipeYieldForEntry(entry, uniqueID)
        if learnedYield and learnedYield > 0 then
            yield = learnedYield
        end
    end
    if yield <= 0 and type(entry) == "table" then
        yield = tonumber(entry.recipeYield) or 1
    end
    if yield < 1 then
        yield = 1
    end
    if min <= 0 then
        return 1
    end
    return math.ceil(min / yield)
end

local function CountByUniqueIds(ids)
    local total = 0
    local sample = nil
    if type(ids) ~= "table" then
        return 0, nil
    end
    for i = 1, #ids do
        local c, s = StockPiler.Inventory.CountByUniqueId(ids[i])
        total = total + c
        if sample == nil and s ~= nil then
            sample = s
        end
    end
    return total, sample
end

--- Resolve live count + itemData for a catalog potion entry.
function StockPiler.Inventory.ResolvePotion(entry)
    if entry == nil then
        return { count = 0, itemData = nil, iconNum = 0, seedOk = false, materialsText = L"", materials = {} }
    end

    local count = 0
    local itemData = nil

    count, itemData = CountForEntry(entry)

    if itemData then
        PersistPotionCache(entry.id, itemData)
    end
    -- Prefer catalog uniqueID DB / cached full itemData for tooltips (esp. Have=0).
    itemData = StockPiler.Inventory.ResolveTooltipItemData(entry, itemData)

    -- ONLY real in-game iconNum (bags / learned / DB / knownIconNum).
    -- Never use armory modelId with GetIconData.
    local iconNum = 0
    if itemData and tonumber(itemData.iconNum) and tonumber(itemData.iconNum) > 0 then
        iconNum = tonumber(itemData.iconNum)
    else
        iconNum = CachedPotionIcon(entry.id)
    end
    if iconNum <= 0 and entry.knownIconNum then
        iconNum = tonumber(entry.knownIconNum) or 0
    end

    local seedOk = true
    if entry.seedMatch and entry.seedMatch ~= "" then
        local seedCount = StockPiler.Inventory.CountByName(entry.seedMatch)
        seedOk = seedCount > 0
        if not seedOk and entry.materials then
            for _, mat in ipairs(entry.materials) do
                if mat.match and StockPiler.Inventory.CountByName(mat.match) > 0 then
                    seedOk = true
                    break
                end
            end
        end
    elseif entry.seedMatch == nil then
        seedOk = false
        if entry.materials then
            for _, mat in ipairs(entry.materials) do
                if mat.role == "main" and mat.match and StockPiler.Inventory.CountByName(mat.match) > 0 then
                    seedOk = true
                    break
                end
            end
        end
    end

    local crafts = TargetCrafts(entry)
    local materials = {}
    local parts = {}
    if entry.materials then
        for _, mat in ipairs(entry.materials) do
            local have, sample = StockPiler.Inventory.CountRecipeMaterialByName(mat.match, nil)
            local perCraft = tonumber(mat.perCraft)
            local need = tonumber(mat.need)
            if perCraft ~= nil then
                need = crafts * perCraft
            elseif need == nil then
                need = 0
            end
            local label = mat.label or towstring(mat.match)
            if sample then
                PersistMatCache(mat.match, sample)
            end
            local matIcon = 0
            local matItem = StockPiler.Inventory.ResolveTooltipMatData(mat, sample)
            if matItem and tonumber(matItem.iconNum) and tonumber(matItem.iconNum) > 0 then
                matIcon = tonumber(matItem.iconNum)
            else
                matIcon = CachedMatIcon(mat.match)
            end
            table.insert(materials, {
                match = mat.match,
                label = label,
                have = have,
                need = need,
                role = mat.role,
                iconNum = matIcon,
                itemData = matItem,
                countText = towstring(tostring(have)) .. L"/" .. towstring(tostring(need)),
            })
            table.insert(parts, towstring(label) .. L" " .. towstring(tostring(have)) .. L"/" .. towstring(tostring(need)))
        end
    end
    local materialsText = L""
    for i = 1, #parts do
        if i > 1 then
            materialsText = materialsText .. L" | "
        end
        materialsText = materialsText .. parts[i]
    end

    local result = {
        count = count,
        itemData = itemData,
        iconNum = iconNum,
        seedOk = seedOk,
        materialsText = materialsText,
        materials = materials,
        tooltip = entry.tooltip,
        abilityName = entry.abilityName,
        entry = entry,
    }
    StockPiler.Inventory.byPotion[entry.id] = result
    return result
end

function StockPiler.Inventory.RefreshAll(force)
    -- Bag snapshot + UID counts only. Do not walk every observed item or catalog
    -- potion here — that was a hitch on every inventory event. New items are
    -- learned via LearnNewFromBags (deferred). Planner counts use _countByUid.
    SnapshotItems(force == true)
end

function StockPiler.Inventory.RefreshAllIfNeeded(opts)
    opts = opts or {}
    local force = opts.force == true
    if force then
        StockPiler.Inventory.InvalidateSnapshot()
        if StockPiler._bagCountsStale == true then
            StockPiler._bagCountsStale = false
        end
    end
    if StockPiler.Inventory._uiCachesValid == true
        and StockPiler.Inventory._snapshotDone == true
        and not force
    then
        return
    end
    StockPiler.Inventory.RefreshAll(force)
    StockPiler.Inventory._uiCachesValid = true
end

--- Sorted list of observed potion resolve results (for All view).
function StockPiler.Inventory.GetObservedList()
    local list = {}
    local by = StockPiler.Inventory.byObserved or {}
    for _, row in pairs(by) do
        list[#list + 1] = row
    end
    table.sort(list, function(a, b)
        local na = string.lower(a.nameNarrow or "")
        local nb = string.lower(b.nameNarrow or "")
        if na == nb then
            return (a.uniqueID or 0) < (b.uniqueID or 0)
        end
        return na < nb
    end)
    return list
end

--- Sorted list of observed crafting materials with bag counts.
function StockPiler.Inventory.GetObservedMatList()
    local list = {}
    local by = StockPiler.Inventory.byObservedMats or {}
    for _, row in pairs(by) do
        list[#list + 1] = row
    end
    table.sort(list, function(a, b)
        local na = string.lower(a.nameNarrow or "")
        local nb = string.lower(b.nameNarrow or "")
        if na == nb then
            return (a.uniqueID or 0) < (b.uniqueID or 0)
        end
        return na < nb
    end)
    return list
end

----------------------------------------------------------------
-- Apothecary craft learning (materials -> potion outputs)
----------------------------------------------------------------

StockPiler.Inventory._pendingCraft = nil

-- craftingBonus.bonusReference values (matches CraftValueTip / game data).
StockPiler.Inventory.CraftBonus = {
    STABILITY = 1,
    POWER = 2,
    DURATION = 3,
    MULTIPLIER = 4,
    CRAFTING_FAMILY = 5,
    EFFECT = 6,
    SLOTS = 7,
    TYPE = 8,
    CRAFTING_LEVEL = 9,
    GROW_TIME = 10,
    YIELD = 11,
    CRITICAL_CHANCE = 12,
    FAIL_CHANCE = 13,
    SPECIAL_CHANCE = 14,
    DESTROY_ON_FAIL = 15,
}

local function SignedCraftBonusValue(val)
    val = tonumber(val) or 0
    if val > 32767 then
        return val - 65536
    end
    return val
end

function StockPiler.Inventory.GetItemCraftBonuses(itemData)
    local result = {}
    if type(itemData) ~= "table" or type(itemData.craftingBonus) ~= "table" then
        return result
    end
    for _, bonus in ipairs(itemData.craftingBonus) do
        if type(bonus) == "table" then
            local ref = tonumber(bonus.bonusReference) or 0
            if ref > 0 then
                if result[ref] == nil then
                    result[ref] = {}
                end
                result[ref][#result[ref] + 1] = SignedCraftBonusValue(bonus.bonusValue)
            end
        end
    end
    return result
end

function StockPiler.Inventory.GetItemStability(itemData)
    local bonuses = StockPiler.Inventory.GetItemCraftBonuses(itemData)
    local values = bonuses[StockPiler.Inventory.CraftBonus.STABILITY]
    if type(values) == "table" and values[1] ~= nil then
        return tonumber(values[1]) or 0
    end
    return 0
end

function StockPiler.Inventory.GetMaterialStability(mat)
    if type(mat) ~= "table" then
        return 0
    end
    if mat.stability ~= nil then
        return tonumber(mat.stability) or 0
    end
    if type(mat.itemData) == "table" then
        return StockPiler.Inventory.GetItemStability(mat.itemData)
    end
    local uid = tonumber(mat.uniqueID) or 0
    if uid > 0 and type(StockPiler.Inventory._learnedMatData) == "table" then
        local cached = StockPiler.Inventory._learnedMatData["uid:" .. tostring(uid)]
        if type(cached) == "table" then
            return StockPiler.Inventory.GetItemStability(cached)
        end
    end
    return 0
end

function StockPiler.Inventory.IsOptionalModifierMat(mat)
    if type(mat) ~= "table" then
        return false
    end
    local role = mat.role or ""
    if role == "extender" or role == "multiplier" or role == "stimulant" then
        return true
    end
    local resourceType = tonumber(mat.resourceType) or 0
    if GameData and GameData.CraftingItemType then
        local cit = GameData.CraftingItemType
        if resourceType == cit.EXTENDER
            or resourceType == cit.MULTIPLIER
            or resourceType == cit.STIMULANT
        then
            return true
        end
    end
    return false
end

function StockPiler.Inventory.RecipeStabilityTotal(materials)
    local total = 0
    if type(materials) ~= "table" then
        return total
    end
    for i = 1, #materials do
        local mat = materials[i]
        if not StockPiler.Inventory.IsOptionalModifierMat(mat) then
            local perCraft = tonumber(mat.perCraft) or 1
            if perCraft < 1 then
                perCraft = 1
            end
            total = total + (StockPiler.Inventory.GetMaterialStability(mat) * perCraft)
        end
    end
    return total
end

function StockPiler.Inventory.RecipeIsStable(materials)
    return StockPiler.Inventory.RecipeStabilityTotal(materials) >= 0
end

local GROW_BREW_ROLE_ORDER = {
    container = 1,
    main = 2,
    stabilizer = 3,
    goldweed = 3,
    extender = 4,
    multiplier = 5,
    stimulant = 5,
    ingredient = 6,
}

--- Stabilizer slots required for a stable brew (may exceed learned perCraft when recipe was captured incomplete).
function StockPiler.Inventory.EffectiveMaterialPerCraft(mat, materials)
    local perCraft = tonumber(mat.perCraft) or 1
    if perCraft < 1 then
        perCraft = 1
    end
    if type(mat) ~= "table" or type(materials) ~= "table" then
        return perCraft
    end
    local role = mat.role or ""
    if role ~= "stabilizer" and role ~= "goldweed" then
        return perCraft
    end
    local total = StockPiler.Inventory.RecipeStabilityTotal(materials)
    if total >= 0 then
        return perCraft
    end
    local stab = StockPiler.Inventory.GetMaterialStability(mat) or 0
    if stab <= 0 then
        return perCraft
    end
    return perCraft + math.ceil(-total / stab)
end

--- One growable seed/spore per apothecary slot for a single brew (matches Load slot order, skips flask).
function StockPiler.Inventory.BuildGrowableBrewSlots(recipe)
    local slots = {}
    if type(recipe) ~= "table" or type(recipe.materials) ~= "table" then
        return slots
    end
    local materials = recipe.materials
    local sorted = {}
    for i = 1, #materials do
        sorted[i] = materials[i]
    end
    table.sort(sorted, function(a, b)
        local ra = GROW_BREW_ROLE_ORDER[a.role] or 99
        local rb = GROW_BREW_ROLE_ORDER[b.role] or 99
        if ra == rb then
            return (tonumber(a.uniqueID) or 0) < (tonumber(b.uniqueID) or 0)
        end
        return ra < rb
    end)
    for i = 1, #sorted do
        local mat = sorted[i]
        if mat.role ~= "container" then
            local growable = StockPiler.SeedMap
                and StockPiler.SeedMap.IsGrowableMaterial
                and StockPiler.SeedMap.IsGrowableMaterial(mat) == true
            if growable then
                local perCraft = StockPiler.Inventory.EffectiveMaterialPerCraft(mat, materials)
                for _ = 1, perCraft do
                    slots[#slots + 1] = mat
                end
            end
        end
    end
    return slots
end

local ROLE_ORDER = {
    main = 1,
    stabilizer = 2,
    goldweed = 2,
    extender = 3,
    multiplier = 4,
    container = 5,
    ingredient = 6,
}

local function MatResourceRole(resourceType, slotNum)
    resourceType = tonumber(resourceType) or 0
    if GameData and GameData.CraftingItemType then
        local cit = GameData.CraftingItemType
        if resourceType == cit.CONTAINER or resourceType == cit.CONTAINER_DYE then
            return "container"
        end
        if resourceType == cit.MAIN_INGREDIENT or resourceType == cit.PIGMENT then
            return "main"
        end
        if resourceType == cit.STABILIZER or resourceType == cit.GOLDWEED then
            return "stabilizer"
        end
        if resourceType == cit.EXTENDER then
            return "extender"
        end
        if resourceType == cit.MULTIPLIER then
            return "multiplier"
        end
        if resourceType == cit.STIMULANT then
            return "stimulant"
        end
    end
    if slotNum == 0 then
        return "container"
    end
    if slotNum == 1 then
        return "main"
    end
    return "ingredient"
end

function StockPiler.Inventory.CaptureApothecaryMaterials()
    if type(ApothecaryWindow) ~= "table" or type(ApothecaryWindow.craftingData) ~= "table" then
        return nil
    end
    local slots = {}
    for slotNum = 0, 4 do
        local cd = ApothecaryWindow.craftingData[slotNum]
        if type(cd) == "table" and tonumber(cd.objectId) and tonumber(cd.objectId) > 0 then
            local itemData = nil
            if type(EA_Window_Backpack) == "table"
                and type(EA_Window_Backpack.GetItemsFromBackpack) == "function"
                and cd.sourceBackpack
                and cd.sourceSlot
            then
                local bag = EA_Window_Backpack.GetItemsFromBackpack(cd.sourceBackpack)
                if type(bag) == "table" then
                    itemData = bag[cd.sourceSlot]
                end
            end
            local resourceType = 0
            local skillReq = 0
            local matKind = nil
            if type(itemData) == "table" then
                if CraftingSystem and type(CraftingSystem.GetCraftingData) == "function" then
                    local ok, _, rt = StockPiler.TryCallQuiet("CraftingSystem.GetCraftingData", CraftingSystem.GetCraftingData, itemData)
                    if ok then
                        resourceType = tonumber(rt) or 0
                    end
                end
                local _, _, req, kind = ClassifyMat(itemData)
                skillReq = tonumber(req) or 0
                matKind = kind
            end
            local role = MatResourceRole(resourceType, slotNum)
            local uid = tonumber(cd.objectId) or 0
            local stability = 0
            if type(itemData) == "table" then
                stability = StockPiler.Inventory.GetItemStability(itemData)
            end
            slots[#slots + 1] = {
                slot = slotNum,
                uniqueID = uid,
                role = role,
                resourceType = resourceType,
                matKind = matKind,
                craftingSkillRequirement = skillReq,
                stability = stability,
                name = (type(itemData) == "table" and itemData.name) or nil,
                nameNarrow = (type(itemData) == "table" and ToNarrow(itemData.name)) or "",
                iconNum = tonumber(cd.iconId) or (type(itemData) == "table" and tonumber(itemData.iconNum)) or 0,
                itemData = CopyItemData(itemData),
            }
            if itemData and StockPiler.Inventory.LearnFromItemData then
                StockPiler.Inventory.LearnFromItemData(itemData, "craft-slot")
            end
        end
    end
    if #slots == 0 then
        return nil
    end
    return slots
end

function StockPiler.Inventory.SnapshotPotionCounts()
    StockPiler.Inventory._snapshotDone = false
    SnapshotItems()
    local counts = {}
    EachItem(function(item)
        if IsPotionType(item) then
            local uid = tonumber(item.uniqueID) or 0
            if uid > 0 then
                counts[uid] = (counts[uid] or 0) + StackSize(item)
            end
        end
    end)
    return counts
end

local function AggregateMaterials(slots)
    local byUid = {}
    for i = 1, #slots do
        local m = slots[i]
        local uid = tonumber(m.uniqueID) or 0
        if uid > 0 then
            local key = tostring(uid) .. ":" .. tostring(m.role or "ingredient")
            local row = byUid[key]
            if row == nil then
                row = {
                    uniqueID = uid,
                    role = m.role or "ingredient",
                    resourceType = tonumber(m.resourceType) or 0,
                    matKind = m.matKind,
                    craftingSkillRequirement = tonumber(m.craftingSkillRequirement) or 0,
                    stability = tonumber(m.stability) or 0,
                    name = m.name,
                    nameNarrow = m.nameNarrow or "",
                    iconNum = tonumber(m.iconNum) or 0,
                    perCraft = 0,
                    itemData = m.itemData,
                }
                byUid[key] = row
            end
            row.perCraft = row.perCraft + 1
            if (row.stability or 0) == 0 and (tonumber(m.stability) or 0) ~= 0 then
                row.stability = tonumber(m.stability)
            end
            if (row.iconNum or 0) <= 0 and (tonumber(m.iconNum) or 0) > 0 then
                row.iconNum = tonumber(m.iconNum)
            end
            if row.name == nil and m.name ~= nil then
                row.name = m.name
                row.nameNarrow = m.nameNarrow or ToNarrow(m.name)
            end
            if row.itemData == nil and m.itemData ~= nil then
                row.itemData = m.itemData
            end
            if row.matKind == nil and m.matKind ~= nil then
                row.matKind = m.matKind
            end
            if (row.craftingSkillRequirement or 0) <= 0 and (tonumber(m.craftingSkillRequirement) or 0) > 0 then
                row.craftingSkillRequirement = tonumber(m.craftingSkillRequirement)
            end
        end
    end
    local list = {}
    for _, row in pairs(byUid) do
        list[#list + 1] = row
    end
    table.sort(list, function(a, b)
        local ra = ROLE_ORDER[a.role] or 99
        local rb = ROLE_ORDER[b.role] or 99
        if ra == rb then
            return (a.uniqueID or 0) < (b.uniqueID or 0)
        end
        return ra < rb
    end)
    return list
end

function StockPiler.Inventory.BuildRecipeKey(materials, outputUid)
    local mainUid = 0
    local containerUid = 0
    local extras = {}
    for i = 1, #materials do
        local m = materials[i]
        local uid = tonumber(m.uniqueID) or 0
        if uid > 0 then
            if m.role == "main" then
                mainUid = uid
            elseif m.role == "container" then
                containerUid = uid
            else
                extras[uid] = (extras[uid] or 0) + (tonumber(m.perCraft) or 1)
            end
        end
    end
    local parts = {}
    for uid, cnt in pairs(extras) do
        parts[#parts + 1] = tostring(uid) .. "x" .. tostring(cnt)
    end
    table.sort(parts)
    local key = "m:" .. tostring(mainUid) .. "|c:" .. tostring(containerUid) .. "|i:" .. table.concat(parts, ",")
    outputUid = tonumber(outputUid) or 0
    if outputUid > 0 then
        key = key .. "|o:" .. tostring(outputUid)
    end
    return key
end

function StockPiler.Inventory.BeginPendingCraft()
    if StockPiler.EnsureApothecaryHook then
        StockPiler.EnsureApothecaryHook()
    end
    local slots = StockPiler.Inventory.CaptureApothecaryMaterials()
    if slots == nil then
        StockPiler.Inventory._pendingCraft = nil
        return
    end
    local materials = AggregateMaterials(slots)
    local mainCount = 0
    for i = 1, #materials do
        if materials[i].role == "main" then
            mainCount = mainCount + 1
        end
    end
    if mainCount == 0 then
        StockPiler.Inventory._pendingCraft = nil
        return
    end
    local mainUid = 0
    for i = 1, #materials do
        if materials[i].role == "main" then
            mainUid = tonumber(materials[i].uniqueID) or 0
            break
        end
    end
    StockPiler.Inventory._pendingCraft = {
        materials = materials,
        mainUid = mainUid,
        recipeKey = StockPiler.Inventory.BuildRecipeKey(materials),
        potionCountsBefore = StockPiler.Inventory.SnapshotPotionCounts(),
    }
    if StockPiler.Trace then
        local parts = {}
        for i = 1, #materials do
            local m = materials[i]
            parts[#parts + 1] = tostring(m.role or "?") .. ":" .. tostring(m.uniqueID or 0)
                .. "x" .. tostring(m.perCraft or 1)
        end
        StockPiler.Trace("Brew pending key=" .. tostring(StockPiler.Inventory._pendingCraft.recipeKey)
            .. " mats=" .. table.concat(parts, ", "))
    end
end

local function TableCount(t)
    local n = 0
    if type(t) == "table" then
        for _ in pairs(t) do
            n = n + 1
        end
    end
    return n
end

local function SlimMaterial(mat)
    if type(mat) ~= "table" then
        return mat
    end
    return {
        uniqueID = tonumber(mat.uniqueID) or 0,
        role = mat.role or "ingredient",
        resourceType = tonumber(mat.resourceType) or 0,
        matKind = mat.matKind,
        craftingSkillRequirement = tonumber(mat.craftingSkillRequirement) or 0,
        name = mat.name,
        nameNarrow = mat.nameNarrow or "",
        iconNum = tonumber(mat.iconNum) or 0,
        perCraft = tonumber(mat.perCraft) or 1,
        stability = tonumber(mat.stability) or 0,
        isRefinable = mat.isRefinable == true
            or (type(mat.itemData) == "table" and mat.itemData.isRefinable == true),
    }
end

local function SlimMaterialList(materials)
    local list = {}
    if type(materials) ~= "table" then
        return list
    end
    for i = 1, #materials do
        list[i] = SlimMaterial(materials[i])
    end
    return list
end

local function SlimOutput(out, craftsTotal)
    if type(out) ~= "table" then
        return out
    end
    local slim = {
        uniqueID = tonumber(out.uniqueID) or 0,
        name = out.name,
        nameNarrow = out.nameNarrow or "",
        iconNum = tonumber(out.iconNum) or 0,
        crafts = tonumber(craftsTotal) or tonumber(out.crafts) or 1,
    }
    local lastDelta = tonumber(out.lastDelta)
    if lastDelta and lastDelta > 0 then
        slim.lastDelta = lastDelta
    end
    return slim
end

local function SlimRecipe(recipe)
    if type(recipe) ~= "table" then
        return recipe
    end
    local crafts = tonumber(recipe.crafts) or 1
    local slimMats = SlimMaterialList(recipe.materials)
    local outUid = tonumber(recipe.outputUid) or 0
    local outputs = {}
    if type(recipe.outputs) == "table" and #recipe.outputs > 0 then
        local out = recipe.outputs[1]
        outUid = tonumber(out.uniqueID) or outUid
        outputs[1] = SlimOutput(out, crafts)
    elseif outUid > 0 then
        outputs[1] = {
            uniqueID = outUid,
            crafts = crafts,
        }
    end
    return {
        recipeKey = recipe.recipeKey,
        source = recipe.source or "craft",
        crafts = crafts,
        materials = slimMats,
        outputUid = outUid,
        outputs = outputs,
        recipeYield = tonumber(recipe.recipeYield) or nil,
    }
end

local function MigrateLearnedRecipesSplitByOutput(s)
    local migrated = {}
    for key, recipe in pairs(s.learnedRecipes) do
        if type(recipe) ~= "table" then
            migrated[key] = recipe
        elseif string.find(key, "|o:", 1, true) then
            migrated[key] = recipe
        else
            local outputs = type(recipe.outputs) == "table" and recipe.outputs or {}
            if #outputs == 0 then
                migrated[key] = recipe
            else
                for i = 1, #outputs do
                    local out = outputs[i]
                    local uid = tonumber(out.uniqueID) or 0
                    if uid > 0 then
                        local newKey = StockPiler.Inventory.BuildRecipeKey(recipe.materials, uid)
                        local entry = migrated[newKey]
                        if type(entry) ~= "table" then
                            entry = {
                                recipeKey = newKey,
                                source = recipe.source or "craft",
                                crafts = 0,
                                materials = recipe.materials,
                                outputUid = uid,
                                outputs = {},
                            }
                        end
                        local delta = tonumber(out.lastDelta) or tonumber(out.crafts) or 1
                        entry.crafts = (tonumber(entry.crafts) or 0) + delta
                        entry.recipeYield = delta
                        entry.outputs = { out }
                        migrated[newKey] = entry
                    end
                end
            end
        end
    end
    s.learnedRecipes = migrated
end

local function MigrateLearnedRecipes(s)
    if type(s) ~= "table" or type(s.learnedRecipes) ~= "table" then
        return
    end
    local version = tonumber(s.recipeKeyVersion) or 1

    if version < 2 then
        MigrateLearnedRecipesSplitByOutput(s)
        version = 2
    end

    if version < 3 then
        local slimmed = {}
        for key, recipe in pairs(s.learnedRecipes) do
            if type(recipe) == "table" then
                local slim = SlimRecipe(recipe)
                slim.recipeKey = slim.recipeKey or key
                slimmed[slim.recipeKey or key] = slim
            else
                slimmed[key] = recipe
            end
        end
        s.learnedRecipes = slimmed
        version = 3
    end

    if version < 4 then
        for key, recipe in pairs(s.learnedRecipes) do
            if type(recipe) == "table" and (tonumber(recipe.recipeYield) or 0) <= 0 then
                local out = StockPiler.Inventory.PrimaryRecipeOutput(recipe.outputs)
                local delta = out and tonumber(out.lastDelta) or 0
                if delta > 0 then
                    recipe.recipeYield = delta
                end
            end
        end
        version = 4
    end

    if version < 5 then
        for _, recipe in pairs(s.learnedRecipes) do
            if type(recipe) == "table" and type(recipe.materials) == "table" then
                for i = 1, #recipe.materials do
                    local mat = recipe.materials[i]
                    if type(mat) == "table" and mat.stability == nil then
                        mat.stability = StockPiler.Inventory.GetMaterialStability(mat)
                    end
                end
            end
        end
        version = 5
    end

    s.recipeKeyVersion = version
end

function StockPiler.Inventory.RecipeYield(recipe)
    if type(recipe) ~= "table" then
        return 2
    end
    if StockPiler.RecipeSpec and StockPiler.RecipeSpec.RecipeOutputYield then
        return StockPiler.RecipeSpec.RecipeOutputYield(recipe)
    end
    local yield = tonumber(recipe.recipeYield)
    if yield and yield > 0 then
        return yield
    end
    local out = StockPiler.Inventory.PrimaryRecipeOutput(recipe.outputs)
    if out then
        yield = tonumber(out.lastDelta)
        if yield and yield > 0 then
            return yield
        end
    end
    if type(recipe.catalogEntry) == "table" then
        yield = tonumber(recipe.catalogEntry.recipeYield)
        if yield and yield > 0 then
            return yield
        end
    end
    return 2
end

function StockPiler.Inventory.StoreLearnedRecipe(_materials, _outputs)
    -- v8: UID recipe store is retired; specs are written by StoreLearnedRecipeSpec.
    return false
end

local function CauldronStillHasMain(mainUid)
    mainUid = tonumber(mainUid) or 0
    if mainUid <= 0 then
        return nil
    end
    local slots = StockPiler.Inventory.CaptureApothecaryMaterials()
    if type(slots) ~= "table" then
        return nil
    end
    for i = 1, #slots do
        local slot = slots[i]
        if type(slot) == "table" and slot.role == "main"
            and (tonumber(slot.uniqueID) or 0) == mainUid then
            return true
        end
    end
    return false
end

function StockPiler.Inventory.CompletePendingCraftLearn(opts)
    if type(opts) ~= "table" then
        opts = {}
    end
    local pending = StockPiler.Inventory._pendingCraft
    if type(pending) ~= "table" then
        return false
    end
    local after = StockPiler.Inventory.SnapshotPotionCounts()
    local before = pending.potionCountsBefore or {}
    local outputs = {}
    for uid, count in pairs(after) do
        local prev = tonumber(before[uid]) or 0
        if count > prev then
            local delta = count - prev
            local _, sample = StockPiler.Inventory.CountByUniqueId(uid)
            if sample and StockPiler.Inventory.LearnFromItemData then
                StockPiler.Inventory.LearnFromItemData(sample, "craft-output")
            end
            outputs[#outputs + 1] = {
                uniqueID = uid,
                name = sample and sample.name or towstring(tostring(uid)),
                nameNarrow = sample and ToNarrow(sample.name) or tostring(uid),
                iconNum = sample and tonumber(sample.iconNum) or 0,
                crafts = 1,
                lastDelta = delta,
                itemData = sample and CopyItemData(sample) or nil,
            }
        end
    end
    -- SUCCESS with no bag delta yet: keep pending for the inventory fallback.
    -- FAIL / critical failure (window closed, items destroyed) with no
    -- potion is recorded now. A volatile that already landed in bags is
    -- learned even when the engine reports FAIL.
    local chatCues = nil
    if StockPiler.CraftChat and StockPiler.CraftChat.PeekCues then
        chatCues = StockPiler.CraftChat.PeekCues()
    end
    if type(pending.chatCriticalFailure) == "boolean" and pending.chatCriticalFailure then
        opts.failed = opts.failed == true or (#outputs == 0)
    elseif type(chatCues) == "table" and chatCues.criticalFailure == true and #outputs == 0 then
        opts.failed = true
    end
    if #outputs == 0 and opts.failed ~= true then
        if StockPiler.Trace then
            StockPiler.Trace("Brew complete: no new potion outputs yet")
        end
        return false
    end
    local mainStillThere = CauldronStillHasMain(pending.mainUid)
    local mainConsumed = mainStillThere ~= true
    -- Brew chat "Critical Success" pairs with Potent output (name/uid), not main-kept.
    -- Main kept is only from cauldron still holding the main after brew.
    StockPiler.Inventory._pendingCraft = nil
    if StockPiler.CraftChat and StockPiler.CraftChat.TakeCues then
        StockPiler.CraftChat.TakeCues()
    end
    local stored = false
    if StockPiler.RecipeSpec and StockPiler.RecipeSpec.StoreLearnedRecipeSpec then
        stored = StockPiler.RecipeSpec.StoreLearnedRecipeSpec(pending.materials, outputs, {
            failed = #outputs == 0,
            mainConsumed = mainConsumed,
        }) == true
    end
    if StockPiler.Trace then
        local chatCrit = pending.chatCriticalSuccess == true
            or (type(chatCues) == "table" and chatCues.criticalSuccess == true)
        if #outputs == 0 then
            StockPiler.Trace("Brew recorded as failure (no potion produced)"
                .. " mainConsumed=" .. tostring(mainConsumed)
                .. " chatCritFail=" .. tostring(pending.chatCriticalFailure == true))
        else
            for i = 1, #outputs do
                local out = outputs[i]
                StockPiler.Trace("Brew learned uid=" .. tostring(out.uniqueID)
                    .. " delta=" .. tostring(out.lastDelta or out.crafts or 1)
                    .. " mainConsumed=" .. tostring(mainConsumed)
                    .. " chatCritOk=" .. tostring(chatCrit)
                    .. " spec=" .. tostring(stored == true))
            end
        end
    end
    return stored
end

--- Fallback when PLAYER_CRAFTING_UPDATED does not reach addons (instant brew + bag update).
function StockPiler.Inventory.MaybeCompletePendingCraftFromInventory()
    local pending = StockPiler.Inventory._pendingCraft
    if type(pending) ~= "table" then
        return false
    end
    StockPiler.Inventory._snapshotDone = false
    local after = StockPiler.Inventory.SnapshotPotionCounts()
    local before = pending.potionCountsBefore or {}
    for uid, count in pairs(after) do
        if count > (tonumber(before[uid]) or 0) then
            return StockPiler.Inventory.CompletePendingCraftLearn() == true
        end
    end
    return false
end

function StockPiler.Inventory.OnCraftingUpdated()
    if StockPiler.EnsureApothecaryHook then
        StockPiler.EnsureApothecaryHook()
    end
    if not GameData or not GameData.CraftingStatus or not GameData.CraftingStates then
        return false
    end
    local apo = (GameData.TradeSkills and GameData.TradeSkills.APOTHECARY) or 4
    local skill = tonumber(GameData.CraftingStatus.SkillType) or -1
    local state = tonumber(GameData.CraftingStatus.State) or -1
    if skill ~= apo then
        return false
    end
    local SUCCESS = GameData.CraftingStates.SUCCESS
    local SUCCESS_REPEAT = GameData.CraftingStates.SUCCESS_REPEAT
    local FAIL = GameData.CraftingStates.FAIL
    local PERFORMING = GameData.CraftingStates.PERFORMING
    if state == PERFORMING then
        StockPiler.Inventory.BeginPendingCraft()
        return false
    end
    if state == FAIL then
        local err = tonumber(GameData.CraftingStatus.ErrorCode) or 0
        local backpackFull = GameData.CraftingError and GameData.CraftingError.BACKPACK_FULL
        if backpackFull and err == backpackFull then
            return false
        end
        return StockPiler.Inventory.CompletePendingCraftLearn({ failed = true }) == true
    end
    if state == SUCCESS or state == SUCCESS_REPEAT then
        return StockPiler.Inventory.CompletePendingCraftLearn() == true
    end
    return false
end

local function FindCatalogEntryByUid(uid)
    uid = tonumber(uid) or 0
    if uid <= 0 then
        return nil
    end
    for _, entry in ipairs(CatalogPotions()) do
        if entry.uniqueID and tonumber(entry.uniqueID) == uid then
            return entry
        end
        if type(entry.uniqueIDs) == "table" then
            for i = 1, #entry.uniqueIDs do
                if tonumber(entry.uniqueIDs[i]) == uid then
                    return entry
                end
            end
        end
    end
    return nil
end

local function ResolveRecipePotionDisplay(uid, fallbackName, fallbackItemData, catalogEntry)
    uid = tonumber(uid) or 0
    local iconNum = 0
    local itemData = fallbackItemData
    local name = fallbackName

    if catalogEntry == nil and uid > 0 then
        catalogEntry = FindCatalogEntryByUid(uid)
    end

    if type(catalogEntry) == "table" then
        local resolved = StockPiler.Inventory.byPotion[catalogEntry.id]
        if resolved == nil then
            resolved = StockPiler.Inventory.ResolvePotion(catalogEntry)
        end
        if type(resolved) == "table" then
            iconNum = tonumber(resolved.iconNum) or 0
            itemData = itemData or resolved.itemData
            name = name or catalogEntry.name
        end
    end

    if iconNum <= 0 and type(itemData) == "table" and tonumber(itemData.iconNum) and tonumber(itemData.iconNum) > 0 then
        iconNum = tonumber(itemData.iconNum)
    end

    if iconNum <= 0 and uid > 0 then
        local acctItem = CatalogItemFromAccount(uid)
        if type(acctItem) == "table" then
            iconNum = tonumber(acctItem.iconNum) or iconNum
            itemData = itemData or acctItem
            name = name or acctItem.name
        end
    end

    if iconNum <= 0 and uid > 0 then
        local _, sample = StockPiler.Inventory.CountByUniqueId(uid)
        if type(sample) == "table" then
            iconNum = tonumber(sample.iconNum) or iconNum
            itemData = itemData or sample
        end
    end

    if iconNum <= 0 and type(catalogEntry) == "table" and catalogEntry.knownIconNum then
        iconNum = tonumber(catalogEntry.knownIconNum) or 0
    end

    return {
        iconNum = iconNum,
        itemData = itemData,
        name = name or towstring(tostring(uid)),
        catalogEntry = catalogEntry,
    }
end

local function ResolveMatDisplay(matDef)
    if type(matDef) ~= "table" then
        return {
            iconNum = 0,
            perCraft = 1,
            role = "ingredient",
            name = L"",
            nameNarrow = "",
        }
    end
    local match = matDef.match
    local uid = tonumber(matDef.uniqueID) or 0
    local name = matDef.name or matDef.label
    local itemData = matDef.itemData

    if (match == nil or match == "") and matDef.nameNarrow and matDef.nameNarrow ~= "" then
        match = matDef.nameNarrow
    end
    if (match == nil or match == "") and name then
        match = ToNarrow(name)
    end

    local sample = nil
    if uid > 0 then
        local _, bagSample = StockPiler.Inventory.CountByUniqueId(uid)
        sample = bagSample
    end
    if sample == nil and match and match ~= "" then
        local _, bagSample = StockPiler.Inventory.CountRecipeMaterialByName(match, uid)
        sample = bagSample
    end
    if sample and match and IsValidRecipeMaterialSample(match, sample, uid) then
        PersistMatCache(match, sample)
    end

    itemData = StockPiler.Inventory.ResolveTooltipMatData(matDef, itemData or sample)

    local iconNum = 0
    if type(itemData) == "table" and tonumber(itemData.iconNum) and tonumber(itemData.iconNum) > 0 then
        iconNum = tonumber(itemData.iconNum)
    end
    if iconNum <= 0 and uid > 0 then
        local acctItem = CatalogItemFromAccount(uid)
        if type(acctItem) == "table" then
            iconNum = tonumber(acctItem.iconNum) or iconNum
            if name == nil then
                name = acctItem.name
            end
            if itemData == nil then
                itemData = acctItem
            end
        end
    end
    if iconNum <= 0 and match then
        iconNum = CachedMatIcon(match)
    end
    -- Never use matDef.iconNum from catalog stubs (often armory modelIds).

    if name == nil and type(itemData) == "table" and itemData.name then
        name = itemData.name
    end
    if name == nil and match then
        name = towstring(match)
    end

    return {
        uniqueID = uid,
        name = name or L"",
        nameNarrow = matDef.nameNarrow or ToNarrow(name) or tostring(match or uid),
        iconNum = iconNum,
        perCraft = tonumber(matDef.perCraft) or 1,
        role = matDef.role or "ingredient",
        matKind = matDef.matKind,
        craftingSkillRequirement = tonumber(matDef.craftingSkillRequirement) or 0,
        itemData = itemData,
        match = match,
    }
end

local function RecipeMainMaterial(materials)
    if type(materials) ~= "table" then
        return nil
    end
    for i = 1, #materials do
        if materials[i].role == "main" then
            return materials[i]
        end
    end
    return materials[1]
end

local function RecipeMainLabel(materials)
    local main = RecipeMainMaterial(materials)
    if main == nil then
        return L""
    end
    local name = main.name
    if (name == nil or name == L"") and main.nameNarrow and main.nameNarrow ~= "" then
        name = towstring(main.nameNarrow)
    end
    if (name == nil or name == L"") and type(main.itemData) == "table" and main.itemData.name then
        name = main.itemData.name
    end
    return name or L""
end

local function EnrichMainMat(mainMat)
    if type(mainMat) ~= "table" then
        return mainMat
    end
    local uid = tonumber(mainMat.uniqueID) or 0
    if mainMat.matKind == nil and uid > 0 then
        local row = StockPiler.Items and StockPiler.Items.Get and StockPiler.Items.Get(uid)
        if type(row) == "table" then
            mainMat = {
                uniqueID = uid,
                name = mainMat.name or row.name,
                nameNarrow = mainMat.nameNarrow or row.nameNarrow,
                matKind = row.kind == "mat" and (row.role or "ingredient") or row.kind,
                craftingSkillRequirement = tonumber(mainMat.craftingSkillRequirement)
                    or tonumber(row.skillReq) or 0,
                itemData = mainMat.itemData or (StockPiler.Items.AsItemData and StockPiler.Items.AsItemData(uid)),
            }
        end
    end
    if (mainMat.craftingSkillRequirement or 0) <= 0 and type(mainMat.itemData) == "table" then
        mainMat.craftingSkillRequirement = tonumber(mainMat.itemData.craftingSkillRequirement) or 0
    end
    return mainMat
end

local function RecipePathSourceText(mainMat)
    mainMat = EnrichMainMat(mainMat)
    if type(mainMat) ~= "table" then
        return L"Crafted"
    end
    if mainMat.matKind == "cultivation" then
        return L"Cultivation"
    end
    local uid = tonumber(mainMat.uniqueID) or 0
    -- 303xxxx ids are butcher/scavenging drops used in apothecary slots.
    if uid >= 3030000 and uid < 3040000 then
        return L"Butchering"
    end
    local craftReq = tonumber(mainMat.craftingSkillRequirement) or 0
    if craftReq >= 200 or (uid >= 83000 and uid < 1010000) then
        return L"Cultivation"
    end
    return L"Crafted"
end

local function MergeKnownRecipeInfo(info, mainLabel, crafts)
    if type(info) ~= "table" then
        info = { count = 0, crafts = 0, mainLabels = {} }
    end
    info.count = (info.count or 0) + 1
    info.crafts = math.max(info.crafts or 0, tonumber(crafts) or 0)
    if mainLabel and mainLabel ~= L"" then
        if type(info.mainLabels) ~= "table" then
            info.mainLabels = {}
        end
        local key = ToNarrow(mainLabel)
        if key ~= "" then
            info.mainLabels[key] = mainLabel
        end
    end
    return info
end

local function CatalogEntryForRecipeOutput(uid, outputName, outputNameNarrow)
    local entry = FindCatalogEntryByUid(uid)
    if entry then
        return entry
    end
    local narrow = outputNameNarrow or ToNarrow(outputName)
    if narrow == "" then
        return nil
    end
    for _, p in ipairs(CatalogPotions()) do
        if uid > 0 and EntryMatchesItem(p, { uniqueID = uid, name = outputName }) then
            return p
        end
        local needles = MatchNeedles(p)
        for i = 1, #needles do
            if string.find(string.lower(narrow), string.lower(needles[i]), 1, true) then
                return p
            end
        end
    end
    return nil
end

function StockPiler.Inventory.GetRecipeYieldMap()
    if StockPiler.Inventory._recipeYieldMap ~= nil then
        return StockPiler.Inventory._recipeYieldMap
    end
    local map = { byCatalogId = {}, byUid = {} }
    local s = EnsureSettings()
    if type(s) == "table" and type(s.learnedRecipes) == "table" then
        MigrateLearnedRecipes(s)
        for _, recipe in pairs(s.learnedRecipes) do
            if type(recipe) == "table" then
                local yield = StockPiler.Inventory.RecipeYield(recipe)
                if yield > 0 then
                    local out = StockPiler.Inventory.PrimaryRecipeOutput(recipe.outputs)
                    local uid = tonumber(recipe.outputUid) or (out and tonumber(out.uniqueID)) or 0
                    if uid > 0 then
                        map.byUid[uid] = yield
                        local catalogEntry = CatalogEntryForRecipeOutput(
                            uid,
                            out and out.name or nil,
                            out and out.nameNarrow or nil
                        )
                        if catalogEntry and catalogEntry.id then
                            map.byCatalogId[catalogEntry.id] = yield
                        end
                    end
                end
            end
        end
    end
    StockPiler.Inventory._recipeYieldMap = map
    return map
end

function StockPiler.Inventory.RecipeYieldForEntry(entry, uniqueID)
    local map = StockPiler.Inventory.GetRecipeYieldMap()
    if type(entry) == "table" and entry.id and map.byCatalogId[entry.id] then
        return map.byCatalogId[entry.id]
    end
    local uid = tonumber(uniqueID) or (type(entry) == "table" and tonumber(entry.uniqueID)) or 0
    if uid > 0 and map.byUid[uid] then
        return map.byUid[uid]
    end
    return nil
end

function StockPiler.Inventory.BuildKnownRecipeLookup()
    local lookup = {
        byCatalogId = {},
        byUid = {},
    }
    local s = EnsureSettings()
    if type(s) ~= "table" or type(s.learnedRecipes) ~= "table" then
        return lookup
    end
    MigrateLearnedRecipes(s)

    for recipeKey, recipe in pairs(s.learnedRecipes) do
        if type(recipe) == "table" then
            local out = StockPiler.Inventory.PrimaryRecipeOutput(recipe.outputs)
            local uid = tonumber(recipe.outputUid) or (out and (tonumber(out.uniqueID) or 0)) or 0
            if uid > 0 then
                local mats = {}
                local rawMats = recipe.materials or {}
                for j = 1, #rawMats do
                    mats[j] = ResolveMatDisplay(rawMats[j])
                end
                local mainLabel = RecipeMainLabel(mats)
                local crafts = tonumber(recipe.crafts) or tonumber(out and out.crafts) or 0
                lookup.byUid[uid] = MergeKnownRecipeInfo(lookup.byUid[uid], mainLabel, crafts)

                local catalogEntry = CatalogEntryForRecipeOutput(
                    uid,
                    out and out.name or nil,
                    out and out.nameNarrow or nil
                )
                if catalogEntry and catalogEntry.id then
                    lookup.byCatalogId[catalogEntry.id] = MergeKnownRecipeInfo(
                        lookup.byCatalogId[catalogEntry.id],
                        mainLabel,
                        crafts
                    )
                end
            end
        end
    end
    return lookup
end

function StockPiler.Inventory.GetKnownRecipeLookup()
    if StockPiler.Inventory._knownRecipeLookup == nil then
        StockPiler.Inventory._knownRecipeLookup = StockPiler.Inventory.BuildKnownRecipeLookup()
    end
    return StockPiler.Inventory._knownRecipeLookup
end

function StockPiler.Inventory.GetKnownRecipeInfo(catalogEntry, uniqueID)
    local lookup = StockPiler.Inventory.GetKnownRecipeLookup()
    if type(catalogEntry) == "table" and catalogEntry.id then
        return lookup.byCatalogId[catalogEntry.id]
    end
    local uid = tonumber(uniqueID) or 0
    if uid > 0 then
        return lookup.byUid[uid]
    end
    return nil
end

function StockPiler.Inventory.FormatKnownRecipeText(info)
    if type(info) ~= "table" or (info.count or 0) <= 0 then
        return L"-", false
    end
    local labels = {}
    if type(info.mainLabels) == "table" then
        for _, label in pairs(info.mainLabels) do
            labels[#labels + 1] = label
        end
    end
    table.sort(labels, function(a, b)
        return ToNarrow(a) < ToNarrow(b)
    end)
    if #labels == 0 then
        return L"Yes", true
    end
    if #labels == 1 then
        return labels[1], true
    end
    if info.count == 2 then
        return labels[1] .. L" (+1)", true
    end
    return towstring(tostring(info.count)) .. L" recipes", true
end

function StockPiler.Inventory.GetRecipeList()
    if StockPiler.Inventory._cachedRecipeList ~= nil then
        return StockPiler.Inventory._cachedRecipeList
    end
    local s = EnsureSettings()
    local list = {}

    if type(s) == "table" and type(s.learnedRecipes) == "table" then
        MigrateLearnedRecipes(s)
        for recipeKey, recipe in pairs(s.learnedRecipes) do
            if type(recipe) == "table" then
                local out = StockPiler.Inventory.PrimaryRecipeOutput(recipe.outputs)
                local uid = tonumber(recipe.outputUid) or (out and (tonumber(out.uniqueID) or 0)) or 0
                if uid > 0 then
                    local mats = {}
                    local rawMats = recipe.materials or {}
                    for j = 1, #rawMats do
                        mats[j] = ResolveMatDisplay(rawMats[j])
                    end
                    local mainMat = RecipeMainMaterial(mats)
                    local outItemData = out and out.itemData or nil
                    if outItemData == nil then
                        local _, sample = StockPiler.Inventory.CountByUniqueId(uid)
                        outItemData = sample
                    end
                    local catalogEntry = FindCatalogEntryByUid(uid)
                    local potion = ResolveRecipePotionDisplay(
                        uid,
                        out and out.name or nil,
                        outItemData,
                        catalogEntry
                    )
                    local baseName = potion.name or out.name or towstring(tostring(uid))
                    list[#list + 1] = {
                        id = "recipe:" .. tostring(recipe.recipeKey or recipeKey),
                        recipeKey = recipe.recipeKey or recipeKey,
                        potionUid = uid,
                        baseName = baseName,
                        name = baseName,
                        nameNarrow = (out and out.nameNarrow) or ToNarrow(baseName) or tostring(uid),
                        iconNum = potion.iconNum,
                        itemData = potion.itemData,
                        source = "craft",
                        sourceText = RecipePathSourceText(mainMat),
                        crafts = tonumber(recipe.crafts) or tonumber(out.crafts) or 1,
                        recipeYield = StockPiler.Inventory.RecipeYield({
                            recipeYield = recipe.recipeYield,
                            outputs = recipe.outputs,
                            catalogEntry = catalogEntry,
                        }),
                        materials = mats,
                        mainMatLabel = RecipeMainLabel(mats),
                        catalogEntry = potion.catalogEntry,
                    }
                end
            end
        end
    end

    local potionRecipeCount = {}
    for i = 1, #list do
        local potionUid = list[i].potionUid or 0
        potionRecipeCount[potionUid] = (potionRecipeCount[potionUid] or 0) + 1
    end
    for i = 1, #list do
        local row = list[i]
        if (potionRecipeCount[row.potionUid or 0] or 0) > 1 then
            local viaName = row.mainMatLabel
            if viaName and viaName ~= L"" then
                row.name = (row.baseName or row.name) .. L" - " .. viaName
                local viaNarrow = ToNarrow(viaName) or ""
                if viaNarrow ~= "" then
                    row.nameNarrow = (ToNarrow(row.baseName) or row.nameNarrow or "")
                        .. " - " .. viaNarrow
                end
            end
        end
    end

    table.sort(list, function(a, b)
        local na = string.lower(a.nameNarrow or "")
        local nb = string.lower(b.nameNarrow or "")
        if na == nb then
            return (a.recipeKey or "") < (b.recipeKey or "")
        end
        return na < nb
    end)
    StockPiler.Inventory._cachedRecipeList = list
    return list
end

function StockPiler.Inventory.GetSnapshotItemCount()
    return tonumber(StockPiler.Inventory._itemCount) or 0
end

--- Debug: print bag stats + potion match hits ( /stockpiler scan ) -> chat + uilog d()
function StockPiler.Inventory.DebugScan()
    D("===== DebugScan =====")
    StockPiler.DebugEnabled = true
    StockPiler.Inventory._snapshotDone = false
    SnapshotItems()
    local items = StockPiler.Inventory._items or {}
    local n = #items
    D("Bag items seen=" .. tostring(n))
    if StockPiler.Print then
        StockPiler.Print(L"Bag items seen: " .. towstring(tostring(n)))
    end
    local shown = 0
    for i = 1, n do
        local item = items[i]
        local name = ToNarrow(item.name)
        if name ~= "" then
            local lower = string.lower(name)
            if string.find(lower, "potion", 1, true)
                or string.find(lower, "draught", 1, true)
                or string.find(lower, "elixir", 1, true)
                or string.find(lower, "unguent", 1, true)
                or string.find(lower, "aversion", 1, true)
            then
                shown = shown + 1
                D("consumable[" .. tostring(shown) .. "] " .. DescribeItem(item))
                if shown == 1 and StockPiler.DumpTableKeys then
                    StockPiler.DumpTableKeys("first-consumable", item, 60)
                end
                if shown <= 20 and StockPiler.Print then
                    StockPiler.Print(
                        towstring(tostring(shown))
                            .. L") "
                            .. towstring(name)
                            .. L" id="
                            .. towstring(tostring(item.uniqueID or 0))
                            .. L" icon="
                            .. towstring(tostring(item.iconNum or 0))
                            .. L" x"
                            .. towstring(tostring(StackSize(item)))
                    )
                end
            end
        end
    end
    D("Consumable-like stacks=" .. tostring(shown))
    if StockPiler.Print then
        StockPiler.Print(L"Consumable-like stacks listed: " .. towstring(tostring(shown)))
    end
    for _, entry in ipairs(CatalogPotions()) do
        local inv = StockPiler.Inventory.ResolvePotion(entry)
        local line = ToNarrow(entry.name)
            .. " Have="
            .. tostring(inv.count or 0)
            .. " icon="
            .. tostring(inv.iconNum or 0)
            .. " itemData="
            .. tostring(inv.itemData ~= nil)
        D("catalog " .. tostring(entry.id) .. " " .. line)
        if StockPiler.Print then
            StockPiler.Print(towstring(line))
        end
    end
    D("===== DebugScan done =====")
end

function StockPiler.Inventory.BuildBuyHints()
    local hints = {}
    local s = EnsureSettings()
    if type(s) ~= "table" then
        return hints
    end
    local list = CatalogPotions()
    for _, entry in ipairs(list) do
        if s.watchlist[entry.id] == true and entry.seedMatch then
            local seedCount = StockPiler.Inventory.CountByName(entry.seedMatch)
            if seedCount <= 0 then
                table.insert(hints, {
                    item = towstring(entry.seedMatch),
                    reason = L"Watched: " .. entry.name .. L" (no seed in local bags)",
                    where = L"Craft Supply / AH / refine plant",
                })
            end
        end
    end
    return hints
end

local function TradeSkillId(name, fallback)
    local skills = GameData and GameData.TradeSkills
    if type(skills) == "table" and skills[name] ~= nil then
        return tonumber(skills[name]) or fallback
    end
    return fallback
end

function StockPiler.Inventory.PlayerTradeSkill(skillId)
    skillId = tonumber(skillId) or 0
    if skillId <= 0 then
        return 0
    end
    if GameData and type(GameData.TradeSkillLevels) == "table" then
        local n = tonumber(GameData.TradeSkillLevels[skillId])
        if n ~= nil then
            return n
        end
    end
    if type(GetTradeSkillLevel) == "function" then
        local ok, level = StockPiler.TryCallQuiet("GetTradeSkillLevel", GetTradeSkillLevel, skillId)
        if ok then
            return tonumber(level) or 0
        end
    end
    return 0
end

function StockPiler.Inventory.PlotsForCultivatingSkill(level)
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
    return 1
end

local function PlotLockedFlag(plotNum)
    plotNum = tonumber(plotNum) or 0
    if plotNum <= 0 then
        return nil
    end
    local cache = StockPiler.AutoGrow and StockPiler.AutoGrow._plotCache
    if type(cache) == "table" and type(cache[plotNum]) == "table" then
        return cache[plotNum].Locked == true
    end
    if type(GetCultivationInfo) == "function" then
        local ok, info = StockPiler.TryCallQuiet("GetCultivationInfo", GetCultivationInfo, plotNum)
        if ok and type(info) == "table" then
            return info.Locked == true
        end
    end
    return nil
end

function StockPiler.Inventory.IsPlotLocked(plotNum)
    return PlotLockedFlag(plotNum) == true
end

-- true / false / nil (plot lock not loaded yet). Cultivating is exclusive
-- with Butchering/Scavenging. Skill 0 still counts if plot 1 is unlocked.
function StockPiler.Inventory.CultivatorState()
    local cultId = TradeSkillId("CULTIVATION", 3)
    if StockPiler.Inventory.PlayerTradeSkill(cultId) > 0 then
        return true
    end
    local butcher = StockPiler.Inventory.PlayerTradeSkill(TradeSkillId("BUTCHERING", 1))
    local scavenge = StockPiler.Inventory.PlayerTradeSkill(TradeSkillId("SCAVENGING", 2))
    if butcher > 0 or scavenge > 0 then
        return false
    end
    local locked = PlotLockedFlag(1)
    if locked == nil then
        return nil
    end
    return locked ~= true
end

function StockPiler.Inventory.IsCultivator()
    return StockPiler.Inventory.CultivatorState() == true
end

-- Apothecary is independent of gathering (Apo+Butchering is valid).
-- Talisman crafters are not Apothecaries. Both still 0: allow Load so a
-- brand-new Apothecary can use 0-skill recipes.
function StockPiler.Inventory.IsApothecary()
    local apo = StockPiler.Inventory.PlayerTradeSkill(TradeSkillId("APOTHECARY", 4))
    if apo > 0 then
        return true
    end
    local talisman = StockPiler.Inventory.PlayerTradeSkill(TradeSkillId("TALISMAN", 5))
    return talisman <= 0
end

function StockPiler.Inventory.CanUseCraftingItem(item)
    if type(item) ~= "table" then
        return false
    end
    if DataUtils and type(DataUtils.PlayerTradeSkillLevelIsEnoughForItem) == "function" then
        local ok, enough = StockPiler.TryCallQuiet("DataUtils.PlayerTradeSkillLevelIsEnoughForItem", DataUtils.PlayerTradeSkillLevelIsEnoughForItem, item)
        if ok then
            return enough == true
        end
    end
    local req = tonumber(item.craftingSkillRequirement) or 0
    local cultType = tonumber(item.cultivationType) or 0
    if cultType ~= 0 then
        return StockPiler.Inventory.PlayerTradeSkill(TradeSkillId("CULTIVATION", 3)) >= req
    end
    return StockPiler.Inventory.PlayerTradeSkill(TradeSkillId("APOTHECARY", 4)) >= req
end

function StockPiler.Inventory.CanUseUniqueId(uniqueID)
    uniqueID = tonumber(uniqueID) or 0
    if uniqueID <= 0 then
        return false
    end
    local item = nil
    if StockPiler.Inventory.CountByUniqueId then
        local _, sample = StockPiler.Inventory.CountByUniqueId(uniqueID)
        if type(sample) == "table" then
            item = sample
        end
    end
    if type(item) ~= "table" and type(GetDatabaseItemData) == "function" then
        local ok, data = StockPiler.TryCallQuiet("GetDatabaseItemData", GetDatabaseItemData, uniqueID)
        if ok and type(data) == "table" then
            item = data
        end
    end
    if type(item) ~= "table" then
        return true
    end
    return StockPiler.Inventory.CanUseCraftingItem(item)
end

function StockPiler.Inventory.GetLocalCultivator()
    local name = GameData.Player.name or L"Player"
    local career = L""
    if GameData.Player.career and GameData.Player.career.name then
        career = GameData.Player.career.name
    end
    local cultId = TradeSkillId("CULTIVATION", 3)
    local apoId = TradeSkillId("APOTHECARY", 4)
    local level = StockPiler.Inventory.PlayerTradeSkill(cultId)
    local apoLevel = StockPiler.Inventory.PlayerTradeSkill(apoId)
    local cultivator = StockPiler.Inventory.CultivatorState()
    local plots = 0
    if cultivator == true then
        plots = StockPiler.Inventory.PlotsForCultivatingSkill(level)
    end
    return {
        name = name,
        career = career,
        level = level,
        apoLevel = apoLevel,
        cultivator = cultivator,
        apothecary = StockPiler.Inventory.IsApothecary(),
        plots = plots,
        lastSeen = L"now",
    }
end

function StockPiler.Inventory.EnforceProfessionGates()
    -- Runtime gating lives in AutoGrow.IsEnabled / UI Denied helpers.
    -- Do not persist autoGrowEnabled=false here: CultivatorState can be false
    -- briefly at load (skills/plots not ready) and would wipe the saved preference.
    return false
end

--- Drop mat caches where a seed/spore was stored under a harvested plant name.
function StockPiler.Inventory.PurgeInvalidMatCache(s)
    if type(s) ~= "table" then
        return 0
    end
    local dropped = 0
    if type(s.matDataCache) == "table" then
        for matchKey, itemData in pairs(s.matDataCache) do
            if type(itemData) == "table" and not IsValidRecipeMaterialSample(matchKey, itemData, nil) then
                s.matDataCache[matchKey] = nil
                dropped = dropped + 1
                if StockPiler.Inventory._learnedMatData then
                    StockPiler.Inventory._learnedMatData[matchKey] = nil
                end
            end
        end
    end
    if type(s.matIconCache) == "table" then
        for matchKey, entry in pairs(s.matIconCache) do
            local cached = type(s.matDataCache) == "table" and s.matDataCache[matchKey] or nil
            if type(cached) == "table" and not IsValidRecipeMaterialSample(matchKey, cached, nil) then
                s.matIconCache[matchKey] = nil
            elseif cached == nil and not MatchKeyImpliesSeedOrSpore(matchKey) then
                local uid = type(entry) == "table" and tonumber(entry.uniqueID) or 0
                if uid > 0 and StockPiler.Inventory.GetDatabaseItemByIds then
                    local dbItem = StockPiler.Inventory.GetDatabaseItemByIds(uid)
                    if type(dbItem) == "table" and not IsValidRecipeMaterialSample(matchKey, dbItem, nil) then
                        s.matIconCache[matchKey] = nil
                        dropped = dropped + 1
                    end
                end
            end
        end
    end
    return dropped
end
