----------------------------------------------------------------
-- StockPilerSeedMap - seed/spore resolution via CraftValueTip + learning
----------------------------------------------------------------

StockPiler.SeedMap = StockPiler.SeedMap or {}

StockPiler.SeedMap._pendingRefine = nil

local BUTCHER_HINTS = {
    "scale",
    "fragment",
    "hide",
    "claw",
    "fang",
    "horn",
    "bone",
    "gland",
    "organ",
    "blood",
    "ichor",
}

local function ToNarrow(text)
    if text == nil then
        return ""
    end
    if type(text) == "wstring" then
        local ok, s = pcall(WStringToString, text)
        if ok and s then
            return s
        end
        return ""
    end
    return tostring(text)
end

local function GetSettings()
    if StockPiler.EnsureSettings then
        return StockPiler.EnsureSettings()
    end
    return StockPiler.Settings
end

local function CultivationSeedType()
    if GameData and GameData.CultivationTypes then
        return GameData.CultivationTypes.SEED
    end
    return 1
end

local function CultivationSporeType()
    if GameData and GameData.CultivationTypes then
        return GameData.CultivationTypes.SPORE
    end
    return 5
end

local function NormalizeGrowName(nameNarrow)
    local s = string.lower(nameNarrow or "")
    s = string.gsub(s, "%s+seed$", "")
    s = string.gsub(s, "%s+spore$", "")
    s = string.gsub(s, "%s+", " ")
    s = string.gsub(s, "^%s+", "")
    s = string.gsub(s, "%s+$", "")
    return s
end

local function LooksButchering(nameNarrow)
    local s = string.lower(nameNarrow or "")
    for i = 1, #BUTCHER_HINTS do
        if string.find(s, BUTCHER_HINTS[i], 1, true) then
            return true
        end
    end
    return false
end

local function D(msg)
    if StockPiler and StockPiler.D then
        StockPiler.D(msg)
    end
end

function StockPiler.SeedMap.CvtAvailable()
    if type(CraftItemInfo) == "table"
        and type(CraftItemInfo.GetSeedsToProduce) == "function"
        and type(CraftValueTip) == "table"
        and type(CraftValueTip.SeedList) == "table"
    then
        return true
    end
    if type(CraftValueTip) == "table" and type(CraftValueTip.SeedList) == "table" then
        return true
    end
    return false
end

local function CvtSeedListEntry(seedUid)
    seedUid = tonumber(seedUid) or 0
    if seedUid <= 0 or type(CraftValueTip) ~= "table" or type(CraftValueTip.SeedList) ~= "table" then
        return nil
    end
    return CraftValueTip.SeedList[seedUid]
end

local function AddUniqueUid(list, seen, uid)
    uid = tonumber(uid) or 0
    if uid > 0 and not seen[uid] then
        seen[uid] = true
        list[#list + 1] = uid
    end
end

function StockPiler.SeedMap.GetSeedUidsForPlant(plantUid)
    plantUid = tonumber(plantUid) or 0
    local uids = {}
    local seen = {}
    if plantUid <= 0 then
        return uids
    end

    if type(CraftItemInfo) == "table" and type(CraftItemInfo.GetSeedsToProduce) == "function" then
        local ok, list = pcall(CraftItemInfo.GetSeedsToProduce, plantUid)
        if ok and type(list) == "table" then
            for i = 1, #list do
                AddUniqueUid(uids, seen, list[i])
            end
        end
    elseif type(CraftValueTip) == "table" and type(CraftValueTip.SeedList) == "table" then
        for seedUid, row in pairs(CraftValueTip.SeedList) do
            if type(row) == "table" and (row[4] == plantUid or row[5] == plantUid) then
                AddUniqueUid(uids, seen, seedUid)
            end
        end
    end

    local s = GetSettings()
    if type(s.learnedSeedMap) == "table" then
        local learned = s.learnedSeedMap[tostring(plantUid)]
        if type(learned) == "table" then
            AddUniqueUid(uids, seen, learned.seedUid)
        end
    end
    if type(s.seedMap) == "table" then
        for _, entry in pairs(s.seedMap) do
            if type(entry) == "table" and tonumber(entry.plantUidCache) == plantUid then
                AddUniqueUid(uids, seen, entry.seedUidCache)
            end
        end
    end

    return uids
end

function StockPiler.SeedMap.PickBestSeedUid(plantUid, seedUids)
    plantUid = tonumber(plantUid) or 0
    if plantUid <= 0 then
        return 0
    end

    local seen = {}
    local candidates = {}
    local function add(uid)
        uid = tonumber(uid) or 0
        if uid > 0 and seen[uid] ~= true then
            seen[uid] = true
            candidates[#candidates + 1] = uid
        end
    end

    if type(CraftItemInfo) == "table" and type(CraftItemInfo.GetSeedFromPlant) == "function" then
        local ok, seedUid = pcall(CraftItemInfo.GetSeedFromPlant, plantUid)
        if ok then
            add(seedUid)
        end
    end

    if type(CraftValueTip) == "table" and type(CraftValueTip.SeedList) == "table" then
        for seedUid, row in pairs(CraftValueTip.SeedList) do
            if type(row) == "table" and row[4] == plantUid and row[1] == "std" then
                add(seedUid)
            end
        end
    end

    if type(seedUids) == "table" then
        for i = 1, #seedUids do
            add(seedUids[i])
        end
    end

    local bestUid = 0
    local bestCount = -1
    for i = 1, #candidates do
        local uid = candidates[i]
        local count = 0
        if StockPiler.Inventory and StockPiler.Inventory.CountByUniqueId then
            count = StockPiler.Inventory.CountByUniqueId(uid)
            count = tonumber(count) or 0
        end
        if count > bestCount then
            bestCount = count
            bestUid = uid
        end
    end
    if bestUid > 0 then
        return bestUid
    end
    return candidates[1] or 0
end

function StockPiler.SeedMap.GetPlantUidForSeed(seedUid)
    seedUid = tonumber(seedUid) or 0
    if seedUid <= 0 then
        return 0
    end

    if type(CraftValueTip) == "table" and type(CraftValueTip.SeedList) == "table" then
        local row = CraftValueTip.SeedList[seedUid]
        if type(row) == "table" then
            local plantUid = tonumber(row[4]) or tonumber(row[5]) or 0
            if plantUid > 0 then
                return plantUid
            end
        end
    end

    local s = GetSettings()
    if type(s.learnedSeedMap) == "table" then
        for plantKey, learned in pairs(s.learnedSeedMap) do
            if type(learned) == "table" and tonumber(learned.seedUid) == seedUid then
                return tonumber(plantKey) or tonumber(learned.plantUid) or 0
            end
        end
    end
    if type(s.seedMap) == "table" then
        for _, entry in pairs(s.seedMap) do
            if type(entry) == "table" and tonumber(entry.seedUidCache) == seedUid then
                local plantUid = tonumber(entry.plantUidCache) or 0
                if plantUid > 0 then
                    return plantUid
                end
            end
        end
    end

    return 0
end

function StockPiler.SeedMap.LearnMapping(plantUid, seedUid, source)
    plantUid = tonumber(plantUid) or 0
    seedUid = tonumber(seedUid) or 0
    if plantUid <= 0 or seedUid <= 0 then
        return false
    end

    local s = GetSettings()
    if type(s.learnedSeedMap) ~= "table" then
        s.learnedSeedMap = {}
    end

    local key = tostring(plantUid)
    local existing = s.learnedSeedMap[key]
    if type(existing) == "table" and tonumber(existing.seedUid) == seedUid then
        return false
    end

    s.learnedSeedMap[key] = {
        seedUid = seedUid,
        source = source or "learned",
    }
    if StockPiler.NotifySeedLearned then
        StockPiler.NotifySeedLearned(plantUid, seedUid, source)
    end
    return true
end

local function ObservedMatRecord(uid)
    uid = tonumber(uid) or 0
    if uid <= 0 then
        return nil
    end
    local s = GetSettings()
    if type(s.observedMats) ~= "table" then
        return nil
    end
    if StockPiler.Inventory and StockPiler.Inventory.ObservedId then
        return s.observedMats[StockPiler.Inventory.ObservedId(uid)]
    end
    return s.observedMats["uid:" .. tostring(uid)]
end

local function LookupItemData(uid)
    uid = tonumber(uid) or 0
    if uid <= 0 then
        return nil
    end
    if StockPiler.Inventory and StockPiler.Inventory.CountByUniqueId then
        local _, sample = StockPiler.Inventory.CountByUniqueId(uid)
        if type(sample) == "table" then
            return sample
        end
    end
    if StockPiler.Inventory and type(StockPiler.Inventory._learnedMatData) == "table" then
        local cached = StockPiler.Inventory._learnedMatData["uid:" .. tostring(uid)]
        if type(cached) == "table" then
            return cached
        end
    end
    local obs = ObservedMatRecord(uid)
    if type(obs) == "table" and type(obs.itemData) == "table" then
        return obs.itemData
    end
    if GetDatabaseItemData == nil then
        return nil
    end
    local ok, data = pcall(GetDatabaseItemData, uid)
    if ok and type(data) == "table" then
        return data
    end
    return nil
end

local function SeedKindFromItem(itemData, seedUid)
    local cultType = 0
    if type(itemData) == "table" then
        cultType = tonumber(itemData.cultivationType) or 0
    end
    if cultType == CultivationSporeType() then
        return "spore", true
    end
    if cultType == CultivationSeedType() then
        return "seed", false
    end
    local name = string.lower(ToNarrow(itemData and itemData.name))
    if string.find(name, "spore", 1, true) then
        return "spore", true
    end
    return "seed", false
end

local function BuildSeedRecord(seedUid, source, plantUid)
    seedUid = tonumber(seedUid) or 0
    if seedUid <= 0 then
        return nil
    end

    local count = 0
    local sample = nil
    if StockPiler.Inventory and StockPiler.Inventory.CountByUniqueId then
        count, sample = StockPiler.Inventory.CountByUniqueId(seedUid)
    end

    local itemData = sample
    if type(itemData) ~= "table" then
        itemData = LookupItemData(seedUid)
    end

    local obs = ObservedMatRecord(seedUid)
    local name = (type(sample) == "table" and sample.name)
        or (type(obs) == "table" and obs.name)
        or (type(itemData) == "table" and itemData.name)
    local nameNarrow = ToNarrow(name)
    if nameNarrow == "" and type(obs) == "table" then
        nameNarrow = obs.nameNarrow or ""
    end
    if nameNarrow == "" and plantUid and plantUid > 0 then
        local plantData = LookupItemData(plantUid)
        local plantName = ToNarrow(plantData and plantData.name)
        if plantName ~= "" then
            local kind = SeedKindFromItem(itemData, seedUid)
            nameNarrow = plantName .. (kind == "spore" and " Spore" or " Seed")
            name = towstring(nameNarrow)
        end
    end

    local kind, isSpore = SeedKindFromItem(itemData or obs, seedUid)
    local iconNum = 0
    if type(sample) == "table" and tonumber(sample.iconNum) then
        iconNum = tonumber(sample.iconNum)
    elseif type(obs) == "table" then
        iconNum = tonumber(obs.iconNum) or 0
    elseif type(itemData) == "table" then
        iconNum = tonumber(itemData.iconNum) or 0
    end

    local reaps = false
    local entry = CvtSeedListEntry(seedUid)
    if type(entry) == "table" then
        reaps = entry[1] == "std" and entry[2] == true
    end

    return {
        uniqueID = seedUid,
        plantUid = tonumber(plantUid) or 0,
        name = name or towstring(nameNarrow),
        nameNarrow = nameNarrow,
        match = nameNarrow,
        count = count,
        iconNum = iconNum,
        itemData = itemData or (obs and obs.itemData),
        source = source or "unknown",
        seedKind = kind,
        isSpore = isSpore,
        reaps = reaps,
    }
end

local function FindObservedSeed(baseNameNarrow)
    baseNameNarrow = NormalizeGrowName(baseNameNarrow)
    if baseNameNarrow == "" then
        return nil
    end
    local s = GetSettings()
    if type(s.observedMats) ~= "table" then
        return nil
    end
    local seedType = CultivationSeedType()
    local sporeType = CultivationSporeType()
    local best = nil
    for _, obs in pairs(s.observedMats) do
        if type(obs) == "table" then
            local cultType = tonumber(obs.cultivationType) or 0
            if cultType == seedType or cultType == sporeType then
                local obsBase = NormalizeGrowName(obs.nameNarrow or ToNarrow(obs.name))
                if obsBase == baseNameNarrow
                    or string.find(obsBase, baseNameNarrow, 1, true)
                    or string.find(baseNameNarrow, obsBase, 1, true)
                then
                    best = obs
                    if obsBase == baseNameNarrow then
                        return obs
                    end
                end
            end
        end
    end
    return best
end

function StockPiler.SeedMap.IsGrowableMaterial(mat)
    if type(mat) ~= "table" then
        return false
    end
    if mat.role == "container" then
        return false
    end

    local nameNarrow = mat.nameNarrow or ToNarrow(mat.name) or ToNarrow(mat.match)
    if nameNarrow == "" then
        return false
    end
    if LooksButchering(nameNarrow) then
        return false
    end

    local cultType = tonumber(mat.cultivationType) or 0
    if cultType == 0 and type(mat.itemData) == "table" then
        cultType = tonumber(mat.itemData.cultivationType) or 0
    end
    if cultType == CultivationSeedType() or cultType == CultivationSporeType() then
        return false
    end

    local plantUid = tonumber(mat.uniqueID) or 0
    if plantUid > 0 then
        local uids = StockPiler.SeedMap.GetSeedUidsForPlant(plantUid)
        if #uids > 0 then
            return true
        end
    end

    if mat.isRefinable == true then
        return true
    end
    if type(mat.itemData) == "table" and mat.itemData.isRefinable == true then
        return true
    end
    if plantUid > 0 then
        local obs = ObservedMatRecord(plantUid)
        if type(obs) == "table" and obs.isRefinable == true then
            return true
        end
        local itemData = LookupItemData(plantUid)
        if type(itemData) == "table" and itemData.isRefinable == true then
            return true
        end
    end

    if mat.matKind == "cultivation" and plantUid > 0 then
        return true
    end

    -- Lasting/extra slots (stabilizer, extender, …) use the same plants as main mats.
    local lower = string.lower(nameNarrow)
    if string.find(lower, "goldweed", 1, true) then
        return true
    end
    if string.find(lower, "nettle", 1, true)
        or string.find(lower, "beardweed", 1, true)
        or string.find(lower, "gobswort", 1, true)
        or string.find(lower, "weed", 1, true)
        or string.find(lower, "fungus", 1, true)
        or string.find(lower, "leaf", 1, true)
    then
        return true
    end

    if mat.role == "main" then
        return not LooksButchering(nameNarrow)
    end

    return false
end

function StockPiler.SeedMap.ResolveSeedForMaterial(mat, catalogEntry)
    if type(mat) ~= "table" then
        return nil
    end

    local plantUid = tonumber(mat.uniqueID) or 0
    local useCatalogSeed = type(catalogEntry) == "table"
        and catalogEntry.seedMatch
        and catalogEntry.seedMatch ~= ""
        and (mat.role == "main" or mat.role == nil)

    local function resolveByMaterialName()
        local matName = mat.nameNarrow or ToNarrow(mat.name) or ToNarrow(mat.match)
        if matName == "" then
            return nil
        end

        local candidates = {
            matName .. " Spore",
            matName .. " Seed",
            matName,
        }
        for i = 1, #candidates do
            local match = candidates[i]
            if StockPiler.Inventory and StockPiler.Inventory.CountByName then
                local count, sample = StockPiler.Inventory.CountByName(match)
                if count > 0 or sample ~= nil then
                    local record = BuildSeedRecord(
                        type(sample) == "table" and sample.uniqueID or 0,
                        "name",
                        plantUid
                    )
                    if record == nil then
                        record = {
                            name = (type(sample) == "table" and sample.name) or towstring(match),
                            nameNarrow = match,
                            match = match,
                            uniqueID = type(sample) == "table" and sample.uniqueID or nil,
                            plantUid = plantUid,
                            count = count,
                            iconNum = type(sample) == "table" and (tonumber(sample.iconNum) or 0) or 0,
                            itemData = sample,
                            source = "name",
                            seedKind = string.find(string.lower(match), "spore", 1, true) and "spore" or "seed",
                            isSpore = string.find(string.lower(match), "spore", 1, true) ~= nil,
                        }
                    else
                        record.count = count
                        record.source = "name"
                    end
                    return record
                end
            end
        end

        local obs = FindObservedSeed(matName)
        if obs then
            local seedUid = tonumber(obs.uniqueID) or 0
            local record = BuildSeedRecord(seedUid, "observed", plantUid)
            if record and (record.count or 0) > 0 then
                return record
            end
        end

        local guessName = matName .. " Spore"
        if string.find(string.lower(matName), "seed", 1, true)
            or string.find(string.lower(matName), "spore", 1, true)
        then
            guessName = matName .. " Seed"
        end
        return {
            name = towstring(guessName),
            nameNarrow = guessName,
            match = guessName,
            plantUid = plantUid,
            count = 0,
            iconNum = 0,
            source = "guess",
            seedKind = string.find(string.lower(guessName), "spore", 1, true) and "spore" or "seed",
            isSpore = string.find(string.lower(guessName), "spore", 1, true) ~= nil,
        }
    end

    if useCatalogSeed then
        local seedMatch = catalogEntry.seedMatch
        local count = 0
        local sample = nil
        if StockPiler.Inventory and StockPiler.Inventory.CountByName then
            count, sample = StockPiler.Inventory.CountByName(seedMatch)
        end
        if count > 0 or type(sample) == "table" then
            return {
                name = (type(sample) == "table" and sample.name) or towstring(seedMatch),
                nameNarrow = seedMatch,
                match = seedMatch,
                uniqueID = type(sample) == "table" and sample.uniqueID or nil,
                plantUid = plantUid,
                count = count,
                iconNum = type(sample) == "table" and (tonumber(sample.iconNum) or 0) or 0,
                itemData = sample,
                source = "catalog",
                seedKind = string.find(string.lower(seedMatch), "spore", 1, true) and "spore" or "seed",
                isSpore = string.find(string.lower(seedMatch), "spore", 1, true) ~= nil,
            }
        end
    end

    if plantUid > 0 then
        local seedUids = StockPiler.SeedMap.GetSeedUidsForPlant(plantUid)
        local seedUid = StockPiler.SeedMap.PickBestSeedUid(plantUid, seedUids)
        if seedUid > 0 then
            local source = "cvt"
            if type(CraftItemInfo) ~= "table" or type(CraftItemInfo.GetSeedsToProduce) ~= "function" then
                local s = GetSettings()
                local learned = type(s.learnedSeedMap) == "table" and s.learnedSeedMap[tostring(plantUid)]
                if type(learned) == "table" and tonumber(learned.seedUid) == seedUid then
                    source = learned.source or "learned"
                end
            end
            local record = BuildSeedRecord(seedUid, source, plantUid)
            if type(record) == "table" then
                return record
            end
        end
    end

    return resolveByMaterialName()
end

local function ItemStackCount(item)
    return tonumber(item.stackCount) or tonumber(item.StackCount) or 1
end

local function IsSeedOrSporeItem(itemData)
    if type(itemData) ~= "table" then
        return false
    end
    local cultType = tonumber(itemData.cultivationType) or 0
    return cultType == CultivationSeedType() or cultType == CultivationSporeType()
end

local function IsPotionBagItem(itemData)
    if type(itemData) ~= "table" then
        return false
    end
    if GameData and GameData.ItemTypes and GameData.ItemTypes.POTION then
        return itemData.type == GameData.ItemTypes.POTION
    end
    return tonumber(itemData.type) == 31
end

--- Live bag counts without InvalidateSnapshot / itemsDirty.
--- Harvest-watch used to force a full engine bag rebuild + grow-plan
--- rebuild every second while plots sat Ready to harvest (~300ms spikes).
local function SnapshotCraftingMatCounts()
    local counts = {}
    local function addBag(bag)
        if type(bag) ~= "table" then
            return
        end
        for _, item in pairs(bag) do
            if type(item) == "table" and not IsPotionBagItem(item) then
                local uid = tonumber(item.uniqueID) or 0
                if uid > 0 then
                    counts[uid] = (counts[uid] or 0) + ItemStackCount(item)
                end
            end
        end
    end
    if DataUtils and type(DataUtils.GetItems) == "function" then
        local ok, data = pcall(DataUtils.GetItems)
        if ok then
            addBag(data)
        end
    elseif type(GetInventoryItemData) == "function" then
        local ok, data = pcall(GetInventoryItemData)
        if ok then
            addBag(data)
        end
    end
    if DataUtils and type(DataUtils.GetCraftingItems) == "function" then
        local ok, data = pcall(DataUtils.GetCraftingItems)
        if ok then
            addBag(data)
        end
    elseif type(GetCraftingItemData) == "function" then
        local ok, data = pcall(GetCraftingItemData)
        if ok then
            addBag(data)
        end
    end
    return counts
end

function StockPiler.SeedMap.BeginPendingRefine(itemData)
    if type(itemData) ~= "table" then
        StockPiler.SeedMap._pendingRefine = nil
        return
    end
    local plantUid = tonumber(itemData.uniqueID) or 0
    if plantUid <= 0 then
        StockPiler.SeedMap._pendingRefine = nil
        return
    end
    local cultType = tonumber(itemData.cultivationType) or 0
    if cultType == CultivationSeedType() or cultType == CultivationSporeType() then
        StockPiler.SeedMap._pendingRefine = nil
        return
    end

    local expected = StockPiler.SeedMap.GetSeedUidsForPlant(plantUid)
    local best = StockPiler.SeedMap.PickBestSeedUid(plantUid, expected)
    if best > 0 then
        expected = { best }
    end

    StockPiler.SeedMap._pendingRefine = {
        plantUid = plantUid,
        plantName = ToNarrow(itemData.name),
        expectedSeeds = expected,
        countsBefore = SnapshotCraftingMatCounts(),
        started = os.time and os.time() or 0,
    }
end

function StockPiler.SeedMap.MaybeCompletePendingRefine()
    local pending = StockPiler.SeedMap._pendingRefine
    if type(pending) ~= "table" then
        return false
    end
    local started = tonumber(pending.started) or 0
    local now = os.time and os.time() or 0
    if started > 0 and now > 0 and (now - started) > 8 then
        StockPiler.SeedMap._pendingRefine = nil
        return false
    end

    local plantUid = tonumber(pending.plantUid) or 0
    if plantUid <= 0 then
        StockPiler.SeedMap._pendingRefine = nil
        return false
    end

    local countsAfter = SnapshotCraftingMatCounts()
    local before = pending.countsBefore or {}
    local expected = pending.expectedSeeds
    local expectedSet = {}
    if type(expected) == "table" then
        for i = 1, #expected do
            local uid = tonumber(expected[i]) or 0
            if uid > 0 then
                expectedSet[uid] = true
            end
        end
    end

    local seedUid = 0
    local delta = 0
    local expectedSeedUid = 0
    local expectedDelta = 0
    local extras = {}

    for uid, afterCount in pairs(countsAfter) do
        uid = tonumber(uid) or 0
        local prior = tonumber(before[uid]) or 0
        local change = afterCount - prior
        if uid > 0 and change > 0 then
            local item = LookupItemData(uid)
            if IsSeedOrSporeItem(item) then
                if change > delta then
                    delta = change
                    seedUid = uid
                end
                if expectedSet[uid] == true and change > expectedDelta then
                    expectedDelta = change
                    expectedSeedUid = uid
                end
            elseif uid ~= plantUid then
                extras[uid] = change
            end
        end
    end
    if expectedSeedUid > 0 then
        seedUid = expectedSeedUid
        delta = expectedDelta
    end

    if seedUid <= 0 or delta <= 0 then
        return false
    end

    StockPiler.SeedMap._pendingRefine = nil

    if StockPiler.MaterialSpec then
        for uid, change in pairs(extras) do
            local item = LookupItemData(uid)
            if type(item) == "table" and not IsSeedOrSporeItem(item) then
                local spec = StockPiler.MaterialSpec.FromItemData(item)
                if type(spec) == "table" then
                    StockPiler.SeedMap.MarkHarvestByproduct(spec, "refine", uid)
                    D("SeedMap refine extra uid=" .. tostring(uid)
                        .. " +" .. tostring(change)
                        .. " spec=" .. tostring(StockPiler.MaterialSpec.Key(spec)))
                end
            end
        end
    end

    local learned = StockPiler.SeedMap.LearnMapping(plantUid, seedUid, "refine")
    if learned and StockPiler.SeedMap.ObserveMatFromRefine then
        pcall(StockPiler.SeedMap.ObserveMatFromRefine, plantUid, seedUid)
    end
    return { plantUid = plantUid, seedUid = seedUid, learned = learned }
end

local function PlotSeedUid(plotData)
    if type(plotData) ~= "table" or type(plotData.Seed) ~= "table" then
        return 0
    end
    return tonumber(plotData.Seed.uniqueID) or 0
end

function StockPiler.SeedMap.BeginPendingHarvest(plotNum, plotData)
    plotNum = tonumber(plotNum) or 0
    local seedUid = PlotSeedUid(plotData)
    StockPiler.SeedMap._pendingHarvest = {
        plotNum = plotNum,
        seedUid = seedUid,
        countsBefore = SnapshotCraftingMatCounts(),
        started = os.time and os.time() or 0,
        locked = true,
    }
    D("SeedMap harvest watch plot=" .. tostring(plotNum) .. " seedUid=" .. tostring(seedUid))
end

--- After refine/brew bag changes, rebase an unlocked harvest snapshot so convert
--- deltas are not treated as harvest loot.
function StockPiler.SeedMap.RefreshHarvestWatchAfterBagChange()
    local pending = StockPiler.SeedMap._pendingHarvest
    if type(pending) ~= "table" or pending.locked == true then
        return
    end
    pending.countsBefore = SnapshotCraftingMatCounts()
    pending.started = os.time and os.time() or pending.started
end

--- Keep a pre-harvest bag snapshot while a plot is grown (GatherButton / other harvesters).
function StockPiler.SeedMap.RefreshHarvestWatch(plotNum, plotData)
    local pending = StockPiler.SeedMap._pendingHarvest
    if type(pending) == "table" and pending.locked == true then
        return
    end
    plotNum = tonumber(plotNum) or 0
    local seedUid = PlotSeedUid(plotData)
    local seedsByPlot = {}
    if type(pending) == "table" and type(pending.seedsByPlot) == "table" then
        seedsByPlot = pending.seedsByPlot
    end
    local already = plotNum > 0 and seedUid > 0 and seedsByPlot[plotNum] == seedUid
    if plotNum > 0 and seedUid > 0 then
        seedsByPlot[plotNum] = seedUid
    end
    -- Same grown plot already watched: keep the baseline. Re-snapshoting
    -- every cultivation tick was a 1 Hz hitch while waiting to harvest.
    if already == true and type(pending) == "table" and type(pending.countsBefore) == "table" then
        pending.seedsByPlot = seedsByPlot
        pending.plotNum = plotNum
        if seedUid > 0 then
            pending.seedUid = seedUid
        end
        return
    end
    StockPiler.SeedMap._pendingHarvest = {
        plotNum = plotNum,
        seedUid = seedUid > 0 and seedUid or (pending and pending.seedUid) or 0,
        seedsByPlot = seedsByPlot,
        countsBefore = SnapshotCraftingMatCounts(),
        started = os.time and os.time() or 0,
        locked = false,
    }
end

function StockPiler.SeedMap.MaybeCompletePendingHarvest()
    local pending = StockPiler.SeedMap._pendingHarvest
    if type(pending) ~= "table" then
        return false
    end
    local started = tonumber(pending.started) or 0
    local now = os.time and os.time() or 0
    if started > 0 and now > 0 and (now - started) > 12 then
        StockPiler.SeedMap._pendingHarvest = nil
        return false
    end
    local before = pending.countsBefore or {}
    local after = SnapshotCraftingMatCounts()
    local deltas = {}
    local hasNonSeedGain = false
    for uid, afterCount in pairs(after) do
        local change = afterCount - (tonumber(before[uid]) or 0)
        if change > 0 then
            deltas[uid] = change
            local item = LookupItemData(uid)
            if not IsSeedOrSporeItem(item) then
                hasNonSeedGain = true
            end
        end
    end
    if not hasNonSeedGain then
        return false
    end

    local seedUid = tonumber(pending.seedUid) or 0
    local primaryUid = 0
    local primaryDelta = 0
    local linkedUid = 0
    local bestRefinable = 0
    local bestRefinableDelta = 0
    for uid, change in pairs(deltas) do
        local item = LookupItemData(uid)
        if not IsSeedOrSporeItem(item) then
            local linked = false
            if seedUid > 0 then
                local seedUids = StockPiler.SeedMap.GetSeedUidsForPlant(uid)
                for i = 1, #seedUids do
                    if tonumber(seedUids[i]) == seedUid then
                        linked = true
                    end
                end
            end
            if linked then
                linkedUid = uid
            end
            if type(item) == "table" and item.isRefinable == true and change > bestRefinableDelta then
                bestRefinableDelta = change
                bestRefinable = uid
            end
            if change > primaryDelta then
                primaryDelta = change
                primaryUid = uid
            end
        end
    end
    if linkedUid > 0 then
        primaryUid = linkedUid
    elseif bestRefinable > 0 then
        primaryUid = bestRefinable
    end

    if primaryUid <= 0 then
        StockPiler.SeedMap._pendingHarvest = nil
        return false
    end

    if seedUid <= 0 and type(pending.seedsByPlot) == "table" then
        local seedUids = StockPiler.SeedMap.GetSeedUidsForPlant(primaryUid)
        for _, sid in pairs(pending.seedsByPlot) do
            sid = tonumber(sid) or 0
            for i = 1, #seedUids do
                if tonumber(seedUids[i]) == sid then
                    seedUid = sid
                    break
                end
            end
            if seedUid > 0 then
                break
            end
        end
        if seedUid <= 0 then
            for _, sid in pairs(pending.seedsByPlot) do
                sid = tonumber(sid) or 0
                if sid > 0 then
                    seedUid = sid
                    break
                end
            end
        end
    end

    StockPiler.SeedMap._pendingHarvest = nil

    if seedUid > 0 then
        local learned = StockPiler.SeedMap.LearnMapping(primaryUid, seedUid, "harvest")
        local plantData = LookupItemData(primaryUid)
        if type(plantData) == "table" then
            StockPiler.SeedMap.RegisterFromItem(plantData, seedUid)
        end
        D("SeedMap harvest plantUid=" .. tostring(primaryUid)
            .. " seedUid=" .. tostring(seedUid)
            .. " learned=" .. tostring(learned == true))
    end

    return true
end

function StockPiler.SeedMap.ObserveMatFromRefine(plantUid, seedUid)
    plantUid = tonumber(plantUid) or 0
    seedUid = tonumber(seedUid) or 0
    if StockPiler.Inventory and StockPiler.Inventory.ObserveMat then
        local plantData = LookupItemData(plantUid)
        if type(plantData) == "table" then
            StockPiler.Inventory.ObserveMat(plantData, "refine-plant")
            StockPiler.SeedMap.RegisterFromItem(plantData, seedUid)
        end
        local seedData = LookupItemData(seedUid)
        if type(seedData) == "table" then
            StockPiler.Inventory.ObserveMat(seedData, "refine-seed")
            StockPiler.SeedMap.RegisterFromItem(seedData, plantUid)
        end
    end
end

function StockPiler.SeedMap.RegisterSpecLink(plantSpec, seedSpec, seedUid, plantUid, source)
    if not StockPiler.MaterialSpec or type(plantSpec) ~= "table" or type(seedSpec) ~= "table" then
        return false
    end
    local s = GetSettings()
    if type(s.seedMap) ~= "table" then
        s.seedMap = {}
    end
    if type(s.growProducers) ~= "table" then
        s.growProducers = {}
    end
    local plantKey = StockPiler.MaterialSpec.Key(plantSpec)
    local seedKey = StockPiler.MaterialSpec.Key(seedSpec)
    if plantKey == "" or seedKey == "" then
        return false
    end
    local seedEntry = s.seedMap[seedKey]
    if type(seedEntry) == "table"
        and type(seedEntry.plantSpecKey) == "string"
        and seedEntry.plantSpecKey ~= ""
        and seedEntry.plantSpecKey ~= plantKey
    then
        seedKey = plantKey .. ">" .. seedKey
        seedEntry = s.seedMap[seedKey]
    end
    if type(seedEntry) ~= "table" then
        seedEntry = {
            plantSpecKey = plantKey,
            plantSpec = StockPiler.MaterialSpec.Copy(plantSpec),
            source = source or "learned",
        }
    end
    if seedUid and tonumber(seedUid) > 0 then
        seedEntry.seedUidCache = tonumber(seedUid)
    end
    if plantUid and tonumber(plantUid) > 0 then
        seedEntry.plantUidCache = tonumber(plantUid)
    end
    seedEntry.plantSpecKey = plantKey
    seedEntry.plantSpec = StockPiler.MaterialSpec.Copy(plantSpec)
    s.seedMap[seedKey] = seedEntry

    local prod = s.growProducers[plantKey]
    if type(prod) ~= "table" then
        prod = { seedSpecKeys = {}, sources = {} }
    end
    if type(prod.seedSpecKeys) ~= "table" then
        prod.seedSpecKeys = {}
    end
    if type(prod.sources) ~= "table" then
        prod.sources = {}
    end
    local seen = {}
    for i = 1, #prod.seedSpecKeys do
        seen[prod.seedSpecKeys[i]] = true
    end
    if not seen[seedKey] then
        prod.seedSpecKeys[#prod.seedSpecKeys + 1] = seedKey
    end
    prod.sources[source or "learned"] = true
    s.growProducers[plantKey] = prod
    if tonumber(plantUid) and tonumber(plantUid) > 0
        and tonumber(seedUid) and tonumber(seedUid) > 0
    then
        StockPiler.SeedMap.LearnMapping(plantUid, seedUid, source)
    end
    return true
end

function StockPiler.SeedMap.RegisterFromItem(itemData, linkedUid)
    if type(itemData) ~= "table" or not StockPiler.MaterialSpec then
        return false
    end
    local cultType = tonumber(itemData.cultivationType) or 0
    local spec = StockPiler.MaterialSpec.FromItemData(itemData)
    if spec == nil then
        return false
    end
    local seedType = CultivationSeedType()
    local sporeType = CultivationSporeType()
    if cultType == seedType or cultType == sporeType then
        local plantUid = tonumber(linkedUid) or 0
        if plantUid <= 0 and type(CraftValueTip) == "table" and type(CraftValueTip.SeedList) == "table" then
            local row = CraftValueTip.SeedList[tonumber(itemData.uniqueID) or 0]
            if type(row) == "table" then
                plantUid = tonumber(row[4]) or 0
            end
        end
        local plantData = plantUid > 0 and LookupItemData(plantUid) or nil
        local plantSpec = type(plantData) == "table" and StockPiler.MaterialSpec.FromItemData(plantData)
            or spec
        return StockPiler.SeedMap.RegisterSpecLink(plantSpec, spec, itemData.uniqueID, plantUid, "learned")
    end
    local plantRole = spec.role or ""
    if itemData.isRefinable == true
        or plantRole == "main" or plantRole == "stabilizer" or plantRole == "goldweed"
        or plantRole == "extender" or plantRole == "multiplier" or plantRole == "stimulant"
    then
        local plantUid = tonumber(itemData.uniqueID) or 0
        local seedUid = tonumber(linkedUid) or 0
        if seedUid <= 0 and plantUid > 0 then
            local seedUids = StockPiler.SeedMap.GetSeedUidsForPlant(plantUid)
            seedUid = StockPiler.SeedMap.PickBestSeedUid(plantUid, seedUids)
        end
        if seedUid > 0 and plantUid > 0 then
            local seedData = LookupItemData(seedUid)
            local seedSpec = type(seedData) == "table" and StockPiler.MaterialSpec.FromItemData(seedData)
            if seedSpec == nil then
                return false
            end
            local source = "learned"
            if tonumber(linkedUid) == nil or tonumber(linkedUid) <= 0 then
                source = "cvt"
            end
            return StockPiler.SeedMap.RegisterSpecLink(spec, seedSpec, seedUid, plantUid, source)
        end
        if (plantRole == "stabilizer" or plantRole == "goldweed")
            and itemData.isRefinable ~= true
        then
            StockPiler.SeedMap.MaybeLearnHarvestByproduct(itemData, spec)
        end
    end
    return false
end

function StockPiler.SeedMap.RegisterPlantUid(plantUid, source)
    plantUid = tonumber(plantUid) or 0
    if plantUid <= 0 then
        return false
    end
    local plantData = LookupItemData(plantUid)
    if type(plantData) ~= "table" then
        return false
    end
    local linkedUid = nil
    local seedUids = StockPiler.SeedMap.GetSeedUidsForPlant(plantUid)
    local seedUid = StockPiler.SeedMap.PickBestSeedUid(plantUid, seedUids)
    if seedUid > 0 then
        linkedUid = seedUid
    end
    if StockPiler.SeedMap.RegisterFromItem(plantData, linkedUid) then
        return true
    end
    return false
end

local GROW_REPAIR_ROLES = {
    main = true,
    stabilizer = true,
    goldweed = true,
    extender = true,
    multiplier = true,
    stimulant = true,
}

local function IsCultivatablePlantItem(item)
    if type(item) ~= "table" or IsSeedOrSporeItem(item) then
        return false
    end
    if item.isRefinable == true then
        return true
    end
    local uid = tonumber(item.uniqueID) or 0
    if uid > 0 then
        local seedUids = StockPiler.SeedMap.GetSeedUidsForPlant(uid)
        if type(seedUids) == "table" and #seedUids > 0 then
            return true
        end
    end
    return false
end

function StockPiler.SeedMap.FindPlantUidForSpec(spec)
    if type(spec) ~= "table" or not StockPiler.MaterialSpec then
        return 0
    end
    local MS = StockPiler.MaterialSpec
    local s = GetSettings()
    local bestUid = 0

    -- Bags may also hold butcher substitutes with the same spec (e.g. Zoic Gore
    -- vs Goldweed). Only a refinable plant is valid for grow/refine.
    if StockPiler.Inventory and StockPiler.Inventory.ForEachItem and MS.Matches then
        StockPiler.Inventory.ForEachItem(function(item)
            if type(item) == "table" and MS.Matches(item, spec) and IsCultivatablePlantItem(item) then
                local uid = tonumber(item.uniqueID) or 0
                if uid > 0 then
                    bestUid = uid
                end
            end
        end)
        if bestUid > 0 then
            return bestUid
        end
    end

    local cached = StockPiler.SeedMap.CachedPlantUidForSpec and StockPiler.SeedMap.CachedPlantUidForSpec(spec) or 0
    if cached > 0 then
        return cached
    end

    local function considerUid(uid, role)
        uid = tonumber(uid) or 0
        if uid <= 0 then
            return
        end
        local itemData = nil
        if StockPiler.Inventory and StockPiler.Inventory.CountByUniqueId then
            local _, sample = StockPiler.Inventory.CountByUniqueId(uid)
            itemData = sample
        end
        if type(itemData) ~= "table" then
            itemData = LookupItemData(uid)
        end
        if type(itemData) == "table" then
            if MS.Matches and MS.Matches(itemData, spec) and IsCultivatablePlantItem(itemData) then
                bestUid = uid
            end
            return
        end
        -- Thin GetDatabaseItemData has no craftingBonus. Trust the recipe UID
        -- when the learned slot role matches and this uid already has a seed map.
        if role ~= nil and role == spec.role then
            local seedUids = StockPiler.SeedMap.GetSeedUidsForPlant(uid)
            if type(seedUids) == "table" and #seedUids > 0 then
                bestUid = uid
            end
        end
    end

    if type(s.learnedRecipes) == "table" then
        for _, recipe in pairs(s.learnedRecipes) do
            if type(recipe) == "table" and type(recipe.materials) == "table" then
                for i = 1, #recipe.materials do
                    local mat = recipe.materials[i]
                    if type(mat) == "table" then
                        considerUid(mat.uniqueID, mat.role)
                    end
                end
            end
        end
    end
    if bestUid > 0 then
        return bestUid
    end

    if type(s.observedMats) == "table" then
        for _, obs in pairs(s.observedMats) do
            if type(obs) == "table" then
                considerUid(obs.uniqueID, nil)
            end
        end
    end
    return bestUid
end

function StockPiler.SeedMap.ResolveSeedForPlantUid(plantUid, spec)
    plantUid = tonumber(plantUid) or 0
    if plantUid <= 0 then
        return nil
    end
    local seedUids = StockPiler.SeedMap.GetSeedUidsForPlant(plantUid)
    local seedUid = StockPiler.SeedMap.PickBestSeedUid(plantUid, seedUids)
    if seedUid <= 0 then
        local plantData = LookupItemData(plantUid)
        local nameNarrow = ToNarrow(plantData and plantData.name)
        if nameNarrow ~= "" then
            return StockPiler.SeedMap.ResolveSeedForMaterial({
                uniqueID = plantUid,
                nameNarrow = nameNarrow,
                name = plantData and plantData.name,
                role = type(spec) == "table" and spec.role or nil,
            }, nil)
        end
        return nil
    end
    local record = BuildSeedRecord(seedUid, "plant", plantUid)
    if type(record) ~= "table" then
        return nil
    end
    if StockPiler.MaterialSpec and spec then
        local plantData = LookupItemData(plantUid)
        local seedData = LookupItemData(seedUid)
        local plantSpec = type(plantData) == "table" and StockPiler.MaterialSpec.FromItemData(plantData, spec.role)
        local seedSpec = type(seedData) == "table" and StockPiler.MaterialSpec.FromItemData(seedData)
        if plantSpec and seedSpec then
            StockPiler.SeedMap.RegisterSpecLink(plantSpec, seedSpec, seedUid, plantUid, "learned")
        end
    end
    return record
end

local function LookupSeedMapEntry(s, plantKey, seedKey)
    if type(s.seedMap) ~= "table" then
        return nil, seedKey
    end
    local entry = s.seedMap[seedKey]
    if type(entry) == "table" then
        return entry, seedKey
    end
    local composite = plantKey .. ">" .. seedKey
    entry = s.seedMap[composite]
    if type(entry) == "table" then
        return entry, composite
    end
    return nil, seedKey
end

local function SeedEntryMatchesPlantKey(entry, plantKey)
    if type(entry) ~= "table" or plantKey == nil or plantKey == "" then
        return false
    end
    return entry.plantSpecKey == plantKey
end

function StockPiler.SeedMap.CachedPlantUidForSpec(spec)
    if type(spec) ~= "table" or not StockPiler.MaterialSpec then
        return 0
    end
    local plantKey = StockPiler.MaterialSpec.Key(spec)
    if plantKey == "" then
        return 0
    end
    local s = GetSettings()
    if type(s.seedMap) == "table" then
        for _, entry in pairs(s.seedMap) do
            if type(entry) == "table" and entry.plantSpecKey == plantKey then
                local uid = tonumber(entry.plantUidCache) or 0
                if uid > 0 then
                    return uid
                end
            end
        end
    end
    local prod = type(s.growProducers) == "table" and s.growProducers[plantKey] or nil
    if type(prod) == "table" and type(prod.seedSpecKeys) == "table" then
        for i = 1, #prod.seedSpecKeys do
            local entry = LookupSeedMapEntry(s, plantKey, prod.seedSpecKeys[i])
            if type(entry) == "table" then
                local uid = tonumber(entry.plantUidCache) or 0
                if uid > 0 then
                    return uid
                end
            end
        end
    end
    return 0
end

--- Prefer live bag stacks over a cached uniqueID that may be empty or stale.
function StockPiler.SeedMap.FindSeedInBagsForPlantSpec(spec)
    if type(spec) ~= "table" or not StockPiler.MaterialSpec then
        return nil
    end
    if not (StockPiler.Inventory and StockPiler.Inventory.ForEachItem) then
        return nil
    end
    local MS = StockPiler.MaterialSpec
    local plantKey = MS.Key(spec)
    local s = GetSettings()
    local expectedPlant = StockPiler.SeedMap.CachedPlantUidForSpec(spec)
    local linkedSeedUids = {}
    if type(s.seedMap) == "table" then
        for _, entry in pairs(s.seedMap) do
            if SeedEntryMatchesPlantKey(entry, plantKey) then
                local sid = tonumber(entry.seedUidCache) or 0
                local pid = tonumber(entry.plantUidCache) or 0
                if sid > 0 then
                    linkedSeedUids[sid] = pid
                end
                if pid > 0 then
                    expectedPlant = pid
                end
            end
        end
    end
    local prod = type(s.growProducers) == "table" and s.growProducers[plantKey] or nil
    if type(prod) == "table" and type(prod.seedSpecKeys) == "table" then
        for i = 1, #prod.seedSpecKeys do
            local entry = LookupSeedMapEntry(s, plantKey, prod.seedSpecKeys[i])
            -- growProducers can list another plant's composite key (e.g. Smedleycap
            -- spore on a Hurling fx:1 producer). Never treat that as this spec.
            if SeedEntryMatchesPlantKey(entry, plantKey) then
                local sid = tonumber(entry.seedUidCache) or 0
                local pid = tonumber(entry.plantUidCache) or 0
                if sid > 0 then
                    linkedSeedUids[sid] = pid
                end
                if pid > 0 then
                    expectedPlant = pid
                end
            end
        end
    end

    local bestUid = 0
    local bestPlant = expectedPlant
    local bestCount = 0
    StockPiler.Inventory.ForEachItem(function(item)
        if type(item) ~= "table" or not IsSeedOrSporeItem(item) then
            return
        end
        local seedUid = tonumber(item.uniqueID) or 0
        if seedUid <= 0 then
            return
        end
        local plantUid = StockPiler.SeedMap.GetPlantUidForSeed(seedUid)
        local ok = false
        if linkedSeedUids[seedUid] ~= nil then
            ok = true
            if plantUid <= 0 then
                plantUid = linkedSeedUids[seedUid]
            end
        elseif expectedPlant > 0 and plantUid == expectedPlant then
            ok = true
        elseif plantUid > 0 and MS.Matches then
            local plantData = LookupItemData(plantUid)
            if type(plantData) == "table" and MS.Matches(plantData, spec) == true then
                ok = true
            end
        end
        if not ok then
            return
        end
        local stack = ItemStackCount(item)
        if stack > bestCount then
            bestCount = stack
            bestUid = seedUid
            bestPlant = plantUid > 0 and plantUid or expectedPlant
        end
    end)
    if bestUid <= 0 then
        return nil
    end
    return BuildSeedRecord(bestUid, "bags", bestPlant)
end

function StockPiler.SeedMap.RepairFromLearnedRecipes()
    local s = GetSettings()
    local seen = {}
    local repaired = 0
    if type(s.learnedRecipes) == "table" then
        for _, recipe in pairs(s.learnedRecipes) do
            if type(recipe) == "table" and type(recipe.materials) == "table" then
                for i = 1, #recipe.materials do
                    local mat = recipe.materials[i]
                    if type(mat) == "table" and GROW_REPAIR_ROLES[mat.role] then
                        local uid = tonumber(mat.uniqueID) or 0
                        if uid > 0 and not seen[uid] then
                            seen[uid] = true
                            if StockPiler.SeedMap.RegisterPlantUid(uid, "learned") then
                                repaired = repaired + 1
                            end
                        end
                    end
                end
            end
        end
    end
    return repaired
end

function StockPiler.SeedMap.ResetSpecMaps()
    local s = GetSettings()
    s.seedMap = {}
    s.growProducers = {}
    StockPiler.SeedMap._specBootstrapDone = false
    local bootstrapped = StockPiler.SeedMap.EnsureSpecBootstrap() or 0
    local repaired = StockPiler.SeedMap.RepairFromLearnedRecipes() or 0
    if StockPiler.Trace then
        StockPiler.Trace("Reset spec maps bootstrap=" .. tostring(bootstrapped)
            .. " recipeRepair=" .. tostring(repaired))
    end
    if StockPiler.AutoGrow and StockPiler.AutoGrow.InvalidatePlantQueue then
        StockPiler.AutoGrow.InvalidatePlantQueue()
    end
    return bootstrapped, repaired
end

function StockPiler.SeedMap.ApplyPendingMapReset()
    local s = GetSettings()
    if s._seedMapResetPending ~= true then
        return false
    end
    s._seedMapResetPending = nil
    StockPiler.SeedMap._specBootstrapDone = false
    local bootstrapped = StockPiler.SeedMap.EnsureSpecBootstrap() or 0
    local repaired = StockPiler.SeedMap.RepairFromLearnedRecipes() or 0
    if StockPiler.Trace then
        StockPiler.Trace("Spec map migration bootstrap=" .. tostring(bootstrapped)
            .. " recipeRepair=" .. tostring(repaired))
    end
    if StockPiler.AutoGrow and StockPiler.AutoGrow.InvalidatePlantQueue then
        StockPiler.AutoGrow.InvalidatePlantQueue()
    end
    return true
end

local function SpecHasGoldweedMultiplier(spec)
    if type(spec) ~= "table" or type(spec.bonuses) ~= "table" then
        return false
    end
    local B = StockPiler.Inventory and StockPiler.Inventory.CraftBonus
    local ref = (B and B.MULTIPLIER) or 4
    local val = tonumber(spec.bonuses[ref])
    return val ~= nil and val ~= 0
end

local function SpecHasGrowProducer(spec)
    if type(spec) ~= "table" or not StockPiler.MaterialSpec then
        return false
    end
    local key = StockPiler.MaterialSpec.Key(spec)
    if key == "" then
        return false
    end
    local s = GetSettings()
    local prod = type(s.growProducers) == "table" and s.growProducers[key]
    return type(prod) == "table" and type(prod.seedSpecKeys) == "table" and #prod.seedSpecKeys > 0
end

function StockPiler.SeedMap.MarkHarvestByproduct(spec, source, uniqueID)
    if type(spec) ~= "table" or not StockPiler.MaterialSpec then
        return false
    end
    -- Goldweed (and butcher substitutes like Zoic Gore) share +stab/+multiplier.
    -- Resin convert extras do not. Never let those specs occupy harvestByproducts.
    if SpecHasGoldweedMultiplier(spec) or SpecHasGrowProducer(spec) then
        return false
    end
    local key = StockPiler.MaterialSpec.Key(spec)
    if key == "" then
        return false
    end
    local s = GetSettings()
    if type(s.harvestByproducts) ~= "table" then
        s.harvestByproducts = {}
    end
    local existing = s.harvestByproducts[key]
    s.harvestByproducts[key] = {
        source = source or "learned",
        uniqueID = tonumber(uniqueID) or 0,
        role = spec.role,
    }
    if existing == nil then
        D("SeedMap harvest byproduct " .. key .. " source=" .. tostring(source or "learned"))
    end
    return true
end

function StockPiler.SeedMap.IsHarvestByproduct(spec)
    if type(spec) ~= "table" or not StockPiler.MaterialSpec then
        return false
    end
    local key = StockPiler.MaterialSpec.Key(spec)
    if key == "" then
        return false
    end
    local s = GetSettings()
    if type(s.harvestByproducts) ~= "table" or type(s.harvestByproducts[key]) ~= "table" then
        return false
    end
    -- Stale marks: cultivated goldweed (or a grow-mapped plant) was stored as resin.
    if SpecHasGoldweedMultiplier(spec) or SpecHasGrowProducer(spec) then
        s.harvestByproducts[key] = nil
        return false
    end
    return true
end

--- Seedless, non-refinable stabilizer seen on a learned recipe (no name matching).
--- Converting plants to seeds is the primary teacher (typically 1 plant → 1 seed + 1 resin);
--- this covers the item from a recipe before a convert is observed.
function StockPiler.SeedMap.MaybeLearnHarvestByproduct(itemData, spec)
    if not StockPiler.MaterialSpec then
        return false
    end
    if type(spec) ~= "table" and type(itemData) == "table" then
        spec = StockPiler.MaterialSpec.FromItemData(itemData)
    end
    if type(spec) ~= "table" then
        return false
    end
    local role = spec.role or ""
    if role ~= "stabilizer" and role ~= "goldweed" then
        return false
    end
    if SpecHasGoldweedMultiplier(spec) or SpecHasGrowProducer(spec) then
        return false
    end
    if type(itemData) ~= "table" then
        local plantUid = StockPiler.SeedMap.FindPlantUidForSpec(spec)
        if plantUid > 0 then
            if StockPiler.Inventory and StockPiler.Inventory.CountByUniqueId then
                local _, sample = StockPiler.Inventory.CountByUniqueId(plantUid)
                if type(sample) == "table" then
                    itemData = sample
                end
            end
            if type(itemData) ~= "table" then
                itemData = LookupItemData(plantUid)
            end
        end
    end
    if type(itemData) ~= "table" then
        return false
    end
    if itemData.isRefinable == true then
        return false
    end
    local cultType = tonumber(itemData.cultivationType) or 0
    if cultType == CultivationSeedType() or cultType == CultivationSporeType() then
        return false
    end
    local uid = tonumber(itemData.uniqueID) or 0
    if uid > 0 then
        local seedUids = StockPiler.SeedMap.GetSeedUidsForPlant(uid)
        if #seedUids > 0 then
            return false
        end
    end
    return StockPiler.SeedMap.MarkHarvestByproduct(spec, "learned", uid)
end

function StockPiler.SeedMap.IsGrowableSpec(spec)
    if type(spec) ~= "table" or not StockPiler.MaterialSpec then
        return false
    end
    local role = spec.role or ""
    if role == "container" then
        return false
    end
    local plantKey = StockPiler.MaterialSpec.Key(spec)
    if plantKey == "" then
        return false
    end
    local s = GetSettings()
    if type(s.growProducers) == "table" then
        local prod = s.growProducers[plantKey]
        if type(prod) == "table" and type(prod.seedSpecKeys) == "table" and #prod.seedSpecKeys > 0 then
            return true
        end
    end
    if StockPiler.SeedMap.IsHarvestByproduct(spec) then
        return false
    end
    return role == "main" or role == "stabilizer" or role == "goldweed"
        or role == "extender" or role == "multiplier" or role == "stimulant"
end

function StockPiler.SeedMap.ResolveSeedForSpec(spec)
    if type(spec) ~= "table" or not StockPiler.MaterialSpec then
        return nil
    end
    local MS = StockPiler.MaterialSpec

    local inBags = StockPiler.SeedMap.FindSeedInBagsForPlantSpec(spec)
    if type(inBags) == "table" and (tonumber(inBags.count) or 0) > 0 then
        return inBags
    end

    local plantUid = StockPiler.SeedMap.FindPlantUidForSpec(spec)
    if plantUid > 0 then
        local direct = StockPiler.SeedMap.ResolveSeedForPlantUid(plantUid, spec)
        if type(direct) == "table" and (tonumber(direct.count) or 0) > 0 then
            return direct
        end
        local plantData = LookupItemData(plantUid)
        local plantName = ToNarrow(plantData and plantData.name)
        if plantName ~= "" then
            local named = StockPiler.SeedMap.ResolveSeedForMaterial({
                uniqueID = plantUid,
                nameNarrow = plantName,
                name = plantData and plantData.name,
                role = spec.role,
            }, nil)
            if type(named) == "table" and (tonumber(named.count) or 0) > 0 then
                return named
            end
        end
        if type(direct) == "table" then
            return direct
        end
    end

    local plantKey = MS.Key(spec)
    local s = GetSettings()
    local prod = type(s.growProducers) == "table" and s.growProducers[plantKey] or nil
    local fallback = nil
    if type(prod) == "table" and type(prod.seedSpecKeys) == "table" then
        for i = 1, #prod.seedSpecKeys do
            local seedKey = prod.seedSpecKeys[i]
            local seedEntry = LookupSeedMapEntry(s, plantKey, seedKey)
            if type(seedEntry) == "table" then
                local cachedPlantUid = tonumber(seedEntry.plantUidCache) or 0
                if not SeedEntryMatchesPlantKey(seedEntry, plantKey) then
                    seedEntry = nil
                elseif cachedPlantUid > 0 and MS.Matches then
                    local plantData = LookupItemData(cachedPlantUid)
                    if type(plantData) == "table" then
                        local liveSpec = MS.FromItemData(plantData, spec.role)
                        local comparable = type(liveSpec) == "table"
                            and liveSpec.incomplete ~= true
                            and ((tonumber(liveSpec.tradeSkill) or 0) > 0
                                or (tonumber(liveSpec.slotType) or 0) > 0)
                        if comparable and not MS.Matches(plantData, spec) then
                            seedEntry = nil
                        end
                    end
                end
            end
            if type(seedEntry) == "table" then
                local seedUid = tonumber(seedEntry.seedUidCache) or 0
                local count = 0
                local sample = nil
                if seedUid > 0 and StockPiler.Inventory and StockPiler.Inventory.CountByUniqueId then
                    count, sample = StockPiler.Inventory.CountByUniqueId(seedUid)
                end
                local record = {
                    uniqueID = seedUid,
                    plantUid = tonumber(seedEntry.plantUidCache) or 0,
                    count = count,
                    name = sample and sample.name or MS.Label(seedEntry.plantSpec or spec),
                    nameNarrow = ToNarrow(MS.Label(seedEntry.plantSpec or spec)),
                    source = seedEntry.source or "spec",
                    specKey = seedKey,
                }
                if count > 0 then
                    return record
                end
                if seedUid > 0 and fallback == nil then
                    fallback = record
                end
            end
        end
    end

    local named = StockPiler.SeedMap.ResolveSeedForMaterial({
        uniqueID = plantUid > 0 and plantUid or nil,
        nameNarrow = ToNarrow(MS.Label(spec)),
        role = spec.role,
    }, nil)
    if type(named) == "table" and (tonumber(named.count) or 0) > 0 then
        return named
    end
    return fallback or named
end

function StockPiler.SeedMap.BootstrapSpecMap()
    if type(CraftValueTip) ~= "table" or type(CraftValueTip.SeedList) ~= "table" then
        return 0
    end
    if not StockPiler.MaterialSpec then
        return 0
    end
    if type(GetDatabaseItemData) ~= "function" then
        return 0
    end
    local n = 0
    for seedUid, row in pairs(CraftValueTip.SeedList) do
        if type(row) == "table" then
            local plantUid = tonumber(row[4]) or 0
            if plantUid > 0 then
                local okSeed, seedData = pcall(LookupItemData, seedUid)
                local okPlant, plantData = pcall(LookupItemData, plantUid)
                if okSeed and okPlant
                    and type(seedData) == "table"
                    and type(plantData) == "table"
                then
                    local seedSpec = StockPiler.MaterialSpec.FromItemData(seedData)
                    local plantSpec = StockPiler.MaterialSpec.FromItemData(plantData)
                    if seedSpec and plantSpec
                        and StockPiler.SeedMap.RegisterSpecLink(plantSpec, seedSpec, seedUid, plantUid, "cvt")
                    then
                        n = n + 1
                    end
                end
            end
        end
    end
    return n
end

function StockPiler.SeedMap.EnsureSpecBootstrap()
    if StockPiler.SeedMap._specBootstrapDone == true then
        return 0
    end
    StockPiler.SeedMap._specBootstrapDone = true
    local ok, n = pcall(StockPiler.SeedMap.BootstrapSpecMap)
    if ok and StockPiler.Trace then
        StockPiler.Trace("SeedMap CVT bootstrap entries=" .. tostring(n or 0))
    elseif ok and StockPiler.D then
        StockPiler.D("SeedMap spec bootstrap entries=" .. tostring(n or 0))
    end
    return ok and n or 0
end

