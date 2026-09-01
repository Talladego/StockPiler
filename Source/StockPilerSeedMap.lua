----------------------------------------------------------------
-- StockPilerSeedMap - seed/spore resolution via plant/harvest/refine learning
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
    return StockPiler.ToNarrow(text)
end

--- WAR Lua has no `os` library. GetGameTime is seconds.
local function NowSec()
    if type(GetGameTime) == "function" then
        return tonumber(GetGameTime()) or 0
    end
    return 0
end

local function GetSettings()
    if StockPiler.EnsureSettings then
        return StockPiler.EnsureSettings()
    end
    if type(StockPiler.Settings) ~= "table" then
        StockPiler.Settings = {}
    end
    if StockPiler.BindAccountIntoSettings then
        StockPiler.BindAccountIntoSettings(StockPiler.Settings)
    end
    return StockPiler.Settings
end

--- Always the Account table for this key (same reference Settings aliases).
local function AccountTable(key)
    if StockPiler.ClearAccountTable and type(StockPiler.Account) == "table"
        and type(StockPiler.Account[key]) ~= "table"
    then
        return StockPiler.ClearAccountTable(key)
    end
    local a = StockPiler.EnsureAccount and StockPiler.EnsureAccount() or StockPiler.Account
    if type(a) ~= "table" then
        a = {}
        StockPiler.Account = a
    end
    if type(a[key]) ~= "table" then
        a[key] = {}
    end
    local s = GetSettings()
    if type(s) == "table" then
        s[key] = a[key]
    end
    return a[key]
end

local function ClearAccountTable(key)
    if StockPiler.ClearAccountTable then
        return StockPiler.ClearAccountTable(key)
    end
    local tbl = AccountTable(key)
    for k in pairs(tbl) do
        tbl[k] = nil
    end
    return tbl
end

local function RecordStat(bucket, uid, count, sampled)
    uid = tonumber(uid) or 0
    count = tonumber(count) or 0
    if uid <= 0 then
        return false
    end
    local key = tostring(uid)
    local row = bucket[key]
    if type(row) ~= "table" then
        row = { samples = 0, countSum = 0, last = 0 }
    end
    if sampled ~= false and count > 0 then
        row.samples = (tonumber(row.samples) or 0) + 1
        row.countSum = (tonumber(row.countSum) or 0) + count
        row.last = count
    elseif sampled == false then
        -- Known pair without a counted sample.
        row.last = tonumber(row.last) or 0
    end
    bucket[key] = row
    return true
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
    s = string.gsub(s, "%s+seed%s+packet$", "")
    s = string.gsub(s, "%s+spore%s+packet$", "")
    s = string.gsub(s, "%s+seed$", "")
    s = string.gsub(s, "%s+spore$", "")
    s = string.gsub(s, "%s+", " ")
    s = string.gsub(s, "^%s+", "")
    s = string.gsub(s, "%s+$", "")
    return s
end

--- Harvested plant and its seed share a stem: "Glossy Spumepetal" / "Glossy Spumepetal Seed".
function StockPiler.SeedMap.GrowNamesRelated(plantName, seedName)
    local a = NormalizeGrowName(ToNarrow(plantName))
    local b = NormalizeGrowName(ToNarrow(seedName))
    if a == "" or b == "" then
        return false
    end
    if a == b then
        return true
    end
    return string.gsub(a, " ", "") == string.gsub(b, " ", "")
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

--- CraftValueTip is no longer used; knowledge comes from planting/harvest/refine.
function StockPiler.SeedMap.CvtAvailable()
    return false
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

    -- Optional live API (not CraftValueTip); never persisted.
    if type(CraftItemInfo) == "table" and type(CraftItemInfo.GetSeedsToProduce) == "function" then
        local ok, list = StockPiler.TryCallQuiet("CraftItemInfo.GetSeedsToProduce", CraftItemInfo.GetSeedsToProduce, plantUid)
        if ok and type(list) == "table" then
            for i = 1, #list do
                AddUniqueUid(uids, seen, list[i])
            end
        end
    end

    local refines = AccountTable("refines")
    local entry = refines[tostring(plantUid)]
    if type(entry) == "table" then
        AddUniqueUid(uids, seen, entry.seedUid)
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
        local ok, seedUid = StockPiler.TryCallQuiet("CraftItemInfo.GetSeedFromPlant", CraftItemInfo.GetSeedFromPlant, plantUid)
        if ok then
            add(seedUid)
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

    local harvested = StockPiler.SeedMap.PrimaryPlantForSeed(seedUid)
    if harvested > 0 then
        return harvested
    end

    local refines = AccountTable("refines")
    for plantKey, entry in pairs(refines) do
        if type(entry) == "table" and tonumber(entry.seedUid) == seedUid then
            local plantUid = tonumber(plantKey) or 0
            if plantUid > 0 then
                return plantUid
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

    if StockPiler.SeedMap.IsResinUid and StockPiler.SeedMap.IsResinUid(plantUid) then
        return false
    end
    if StockPiler.SeedMap.PairLooksLikePlantAndSeed
        and not StockPiler.SeedMap.PairLooksLikePlantAndSeed(plantUid, seedUid)
    then
        return false
    end

    local already = false
    if source == "harvest" then
        local grows = AccountTable("grows")
        local bucket = grows[tostring(seedUid)]
        already = type(bucket) == "table" and type(bucket[tostring(plantUid)]) == "table"
        StockPiler.SeedMap.NoteKnownHarvestPair(seedUid, plantUid)
    else
        local refines = AccountTable("refines")
        local entry = refines[tostring(plantUid)]
        already = type(entry) == "table" and tonumber(entry.seedUid) == seedUid
        StockPiler.SeedMap.NoteKnownRefinePair(plantUid, seedUid)
    end

    if already then
        return false
    end
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
    if StockPiler.Items and StockPiler.Items.Get then
        return StockPiler.Items.Get(uid)
    end
    return nil
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
    local cached = nil
    if StockPiler.Items and StockPiler.Items.AsItemData then
        cached = StockPiler.Items.AsItemData(uid)
    end
    -- Account rows often had itemType=0 before type was persisted from GameData.type.
    -- Prefer database when cache type is missing/NONE so CRAFTING checks stay accurate.
    local cachedType = type(cached) == "table"
        and (tonumber(cached.type) or tonumber(cached.itemType))
        or nil
    if GetDatabaseItemData ~= nil and (cached == nil or cachedType == nil or cachedType == 0) then
        local ok, data = StockPiler.TryCallQuiet("GetDatabaseItemData", GetDatabaseItemData, uid)
        if ok and type(data) == "table" then
            return data
        end
    end
    if type(cached) == "table" then
        return cached
    end
    return nil
end

local function UpsertItem(itemData, kindHint)
    if type(itemData) ~= "table" or not (StockPiler.Items and StockPiler.Items.UpsertFromItemData) then
        return nil
    end
    return StockPiler.Items.UpsertFromItemData(itemData, kindHint)
end

local rejectLogged = {}

function StockPiler.SeedMap.PairLooksLikePlantAndSeed(plantUid, seedUid)
    plantUid = tonumber(plantUid) or 0
    seedUid = tonumber(seedUid) or 0
    if plantUid <= 0 or seedUid <= 0 then
        return false
    end
    local plantData = LookupItemData(plantUid)
    local seedData = LookupItemData(seedUid)
    if type(plantData) ~= "table" or type(seedData) ~= "table" then
        return true
    end
    if StockPiler.SeedMap.GrowNamesRelated(plantData.name, seedData.name) then
        return true
    end
    local logKey = tostring(plantUid) .. ":" .. tostring(seedUid)
    if rejectLogged[logKey] ~= true then
        rejectLogged[logKey] = true
        D("SeedMap reject unrelated plantUid=" .. tostring(plantUid)
            .. " seedUid=" .. tostring(seedUid)
            .. " plant=" .. ToNarrow(plantData.name)
            .. " seed=" .. ToNarrow(seedData.name))
    end
    return false
end

local function ItemNameLooksLikeResin(itemData)
    local n = string.lower(ToNarrow(itemData and itemData.name))
    return n ~= "" and string.find(n, "resin", 1, true) ~= nil
end

--- GameData.ItemTypes.CRAFTING = 34. Live bags use itemData.type; Account cache uses itemType.
--- Failed harvest trash (e.g. Wilted Wild Weed) is typically NONE (0), not CRAFTING.
local function CraftingItemType()
    if GameData and GameData.ItemTypes and GameData.ItemTypes.CRAFTING then
        return GameData.ItemTypes.CRAFTING
    end
    return 34
end

local function IsCraftingItem(itemData)
    if type(itemData) ~= "table" then
        return false
    end
    local t = tonumber(itemData.type) or tonumber(itemData.itemType)
    if t == nil then
        return false
    end
    return t == CraftingItemType()
end

local function ProductKindForItem(itemData)
    if type(itemData) ~= "table" then
        return "other"
    end
    if ItemNameLooksLikeResin(itemData) then
        return "resin"
    end
    local cultType = tonumber(itemData.cultivationType) or 0
    if cultType == CultivationSporeType() then
        return "spore"
    end
    if cultType == CultivationSeedType() then
        return "seed"
    end
    local n = string.lower(ToNarrow(itemData.name))
    if string.find(n, "spore", 1, true) then
        return "spore"
    end
    if string.find(n, "seed", 1, true) then
        return "seed"
    end
    return "plant"
end

local function OutcomeAvg(prod)
    if type(prod) ~= "table" then
        return 0
    end
    local samples = tonumber(prod.samples) or 0
    if samples > 0 then
        return (tonumber(prod.countSum) or 0) / samples
    end
    return tonumber(prod.last) or 0
end

local function EnsureGrowsBucket(seedUid)
    seedUid = tonumber(seedUid) or 0
    if seedUid <= 0 then
        return nil
    end
    local grows = AccountTable("grows")
    local key = tostring(seedUid)
    local bucket = grows[key]
    if type(bucket) ~= "table" then
        bucket = {}
        grows[key] = bucket
    end
    return bucket
end

local function EnsureRefineEntry(plantUid)
    plantUid = tonumber(plantUid) or 0
    if plantUid <= 0 then
        return nil
    end
    local refines = AccountTable("refines")
    local key = tostring(plantUid)
    local entry = refines[key]
    if type(entry) ~= "table" then
        entry = { seedUid = 0, seedKind = "seed", byproducts = {} }
        refines[key] = entry
    end
    if type(entry.byproducts) ~= "table" then
        entry.byproducts = {}
    end
    return entry
end

local function StatRowToProduct(uid, kind, row)
    row = type(row) == "table" and row or {}
    return {
        uid = tonumber(uid) or 0,
        kind = kind or "other",
        samples = tonumber(row.samples) or 0,
        countSum = tonumber(row.countSum) or 0,
        last = tonumber(row.last) or 0,
    }
end

local function SortedProductList(list)
    table.sort(list, function(a, b)
        local ka = a.kind == "seed" or a.kind == "spore"
        local kb = b.kind == "seed" or b.kind == "spore"
        if ka ~= kb then
            return ka
        end
        if (a.kind or "") ~= (b.kind or "") then
            return tostring(a.kind) < tostring(b.kind)
        end
        return (tonumber(a.uid) or 0) < (tonumber(b.uid) or 0)
    end)
    return list
end

--- Seed/spore -> plants gained when that plot is harvested.
function StockPiler.SeedMap.ObserveHarvest(seedUid, products, sampled)
    seedUid = tonumber(seedUid) or 0
    if seedUid <= 0 or type(products) ~= "table" then
        return false
    end
    local bucket = EnsureGrowsBucket(seedUid)
    if type(bucket) ~= "table" then
        return false
    end
    local seedData = LookupItemData(seedUid)
    if type(seedData) == "table" then
        local kind = ProductKindForItem(seedData)
        UpsertItem(seedData, (kind == "spore") and "spore" or "seed")
    end
    local changed = false
    for uid, count in pairs(products) do
        uid = tonumber(uid) or 0
        count = tonumber(count) or 0
        if uid > 0 and uid ~= seedUid and not StockPiler.SeedMap.IsResinUid(uid) then
            local item = LookupItemData(uid)
            if not IsCraftingItem(item) then
                -- Ignore harvest trash (Wilted Wild Weed, etc.).
            else
                local kind = ProductKindForItem(item)
                if kind ~= "seed" and kind ~= "spore" and kind ~= "resin" then
                    -- Multi-plot harvest deltas can mix plants; only keep name-related pairs
                    -- (e.g. reject Gobswort Spore → Majestic Goldweed).
                    if type(seedData) == "table" and type(item) == "table"
                        and not StockPiler.SeedMap.GrowNamesRelated(item.name, seedData.name)
                    then
                        D("SeedMap ObserveHarvest skip unrelated plantUid=" .. tostring(uid)
                            .. " seedUid=" .. tostring(seedUid)
                            .. " plant=" .. ToNarrow(item.name)
                            .. " seed=" .. ToNarrow(seedData.name))
                    elseif RecordStat(bucket, uid, count, sampled ~= false) then
                        changed = true
                        if type(item) == "table" then
                            UpsertItem(item, "mat")
                        end
                    end
                end
            end
        end
    end
    return changed
end

--- Record Crafting-chat Critical Success / Failure against a seed grow bucket.
--- Does not change AutoGrow; used for seed-buffer insight later.
function StockPiler.SeedMap.RecordHarvestChatCues(seedUid, cues, pending)
    seedUid = tonumber(seedUid) or 0
    if seedUid <= 0 then
        return false, false
    end
    local bucket = EnsureGrowsBucket(seedUid)
    if type(bucket) ~= "table" then
        return false, false
    end
    bucket.harvestAttempts = (tonumber(bucket.harvestAttempts) or 0) + 1
    local critOk = false
    local critFail = false
    if type(pending) == "table" then
        critOk = pending.chatCriticalSuccess == true
        critFail = pending.chatCriticalFailure == true
    end
    if type(cues) == "table" then
        if cues.criticalSuccess == true then
            critOk = true
        end
        if cues.criticalFailure == true then
            critFail = true
        end
    end
    if critOk then
        bucket.chatCriticalSuccess = (tonumber(bucket.chatCriticalSuccess) or 0) + 1
    end
    if critFail then
        bucket.chatCriticalFailure = (tonumber(bucket.chatCriticalFailure) or 0) + 1
    end
    D("SeedMap harvest chat seedUid=" .. tostring(seedUid)
        .. " attempts=" .. tostring(bucket.harvestAttempts)
        .. " critOk=" .. tostring(critOk)
        .. " critFail=" .. tostring(critFail))
    return critOk, critFail
end

--- Critical Failure with no bag gain: clear locked harvest watch and record seed lost.
function StockPiler.SeedMap.CompletePendingHarvestFromChat(cues)
    local pending = StockPiler.SeedMap._pendingHarvest
    if type(pending) ~= "table" or pending.locked ~= true then
        return false
    end
    local seedUid = tonumber(pending.seedUid) or 0
    local plotNum = tonumber(pending.plotNum) or 0
    local _, critFail = StockPiler.SeedMap.RecordHarvestChatCues(seedUid, cues, pending)
    StockPiler.SeedMap._pendingHarvest = nil
    if StockPiler.CraftChat and StockPiler.CraftChat.TakeCues then
        StockPiler.CraftChat.TakeCues()
    end
    if StockPiler.LogOp then
        StockPiler.LogOp("harvest", string.format(
            "fail P%d seedUid=%d critFail=%s reason=Critical Failure",
            plotNum,
            seedUid,
            tostring(critFail == true)
        ))
    end
    if StockPiler.AutoGrow and StockPiler.AutoGrow.MaybeNotifySeedLineLost then
        StockPiler.AutoGrow.MaybeNotifySeedLineLost(seedUid, "critical_failure", plotNum)
    end
    return true
end

--- Plant convert -> seed/spore plus extras (Arboreal Resin is expected on every convert).
function StockPiler.SeedMap.ObserveRefine(plantUid, products, sampled)
    plantUid = tonumber(plantUid) or 0
    if plantUid <= 0 or type(products) ~= "table" then
        return false
    end
    local entry = EnsureRefineEntry(plantUid)
    if type(entry) ~= "table" then
        return false
    end
    local plantData = LookupItemData(plantUid)
    if type(plantData) == "table" then
        UpsertItem(plantData, "mat")
    end
    local changed = false
    for uid, count in pairs(products) do
        uid = tonumber(uid) or 0
        count = tonumber(count) or 0
        if uid > 0 and uid ~= plantUid then
            local item = LookupItemData(uid)
            local kind = ProductKindForItem(item)
            if kind == "seed" or kind == "spore" then
                local seedName = string.lower(ToNarrow(item and item.name))
                if string.find(seedName, "packet", 1, true) then
                    -- Vendor packets are not convert output.
                elseif StockPiler.SeedMap.PairLooksLikePlantAndSeed(plantUid, uid) then
                    entry.seedUid = uid
                    entry.seedKind = kind
                    changed = true
                    if type(item) == "table" then
                        UpsertItem(item, kind)
                    end
                end
            else
                -- Non-seed convert gain: Arboreal Resin (level-matched to the plant).
                if RecordStat(entry.byproducts, uid, count, sampled ~= false) then
                    changed = true
                    if type(item) == "table" then
                        UpsertItem(item, "resin")
                    elseif StockPiler.Items and StockPiler.Items.Upsert then
                        StockPiler.Items.Upsert(uid, { kind = "resin", uniqueID = uid })
                    end
                    if StockPiler.MaterialSpec and type(item) == "table" then
                        local spec = StockPiler.MaterialSpec.FromItemData(item)
                        if type(spec) == "table" then
                            StockPiler.SeedMap.MarkHarvestByproduct(spec, "refine", uid)
                        end
                    end
                end
            end
        end
    end
    return changed
end

function StockPiler.SeedMap.NoteKnownHarvestPair(seedUid, plantUid)
    seedUid = tonumber(seedUid) or 0
    plantUid = tonumber(plantUid) or 0
    if seedUid <= 0 or plantUid <= 0 then
        return false
    end
    return StockPiler.SeedMap.ObserveHarvest(seedUid, { [plantUid] = 0 }, false)
end

function StockPiler.SeedMap.NoteKnownRefinePair(plantUid, productUid)
    plantUid = tonumber(plantUid) or 0
    productUid = tonumber(productUid) or 0
    if plantUid <= 0 or productUid <= 0 then
        return false
    end
    return StockPiler.SeedMap.ObserveRefine(plantUid, { [productUid] = 0 }, false)
end

function StockPiler.SeedMap.HarvestProducts(seedUid)
    seedUid = tonumber(seedUid) or 0
    local list = {}
    if seedUid <= 0 then
        return list
    end
    local grows = AccountTable("grows")
    local bucket = grows[tostring(seedUid)]
    if type(bucket) ~= "table" then
        return list
    end
    for plantKey, row in pairs(bucket) do
        if type(row) == "table" and tonumber(plantKey) then
            list[#list + 1] = StatRowToProduct(plantKey, "plant", row)
        end
    end
    return SortedProductList(list)
end

--- Expected plants gained per successful harvest of this seed.
--- Uses observed bag deltas (samples/countSum). Returns (yield, samples).
--- Default yield is 1 until at least one counted harvest (fresh / low skill).
function StockPiler.SeedMap.ExpectedHarvestYield(seedUid, plantUid)
    seedUid = tonumber(seedUid) or 0
    plantUid = tonumber(plantUid) or 0
    if seedUid <= 0 then
        return 1, 0
    end
    local products = StockPiler.SeedMap.HarvestProducts(seedUid)
    if plantUid <= 0 and StockPiler.SeedMap.PrimaryPlantForSeed then
        plantUid = tonumber(StockPiler.SeedMap.PrimaryPlantForSeed(seedUid)) or 0
    end
    local function avgOf(prod)
        local samples = tonumber(prod and prod.samples) or 0
        if samples <= 0 then
            return 0, 0
        end
        local avg = (tonumber(prod.countSum) or 0) / samples
        if avg < 1 then
            avg = 1
        end
        return avg, samples
    end
    if plantUid > 0 then
        for i = 1, #products do
            if (tonumber(products[i].uid) or 0) == plantUid then
                local avg, samples = avgOf(products[i])
                if samples > 0 then
                    return avg, samples
                end
                break
            end
        end
    end
    local bestAvg, bestSamples = 0, 0
    for i = 1, #products do
        local avg, samples = avgOf(products[i])
        if samples > bestSamples then
            bestSamples = samples
            bestAvg = avg
        end
    end
    if bestSamples > 0 then
        return bestAvg, bestSamples
    end
    return 1, 0
end

function StockPiler.SeedMap.RefineProducts(plantUid)
    plantUid = tonumber(plantUid) or 0
    local list = {}
    if plantUid <= 0 then
        return list
    end
    local refines = AccountTable("refines")
    local entry = refines[tostring(plantUid)]
    if type(entry) ~= "table" then
        return list
    end
    local seedUid = tonumber(entry.seedUid) or 0
    if seedUid > 0 then
        list[#list + 1] = StatRowToProduct(seedUid, entry.seedKind or "seed", {
            samples = 0,
            countSum = 0,
            last = 0,
        })
    end
    if type(entry.byproducts) == "table" then
        for resinKey, row in pairs(entry.byproducts) do
            if type(row) == "table" then
                list[#list + 1] = StatRowToProduct(resinKey, "resin", row)
            end
        end
    end
    return SortedProductList(list)
end

function StockPiler.SeedMap.PrimaryPlantForSeed(seedUid)
    seedUid = tonumber(seedUid) or 0
    local products = StockPiler.SeedMap.HarvestProducts(seedUid)
    if #products == 0 then
        return 0
    end
    local seedData = seedUid > 0 and LookupItemData(seedUid) or nil
    local bestUid = 0
    local bestSamples = -1
    for i = 1, #products do
        local plantUid = tonumber(products[i].uid) or 0
        if plantUid > 0 then
            local plantData = LookupItemData(plantUid)
            if type(seedData) == "table" and type(plantData) == "table"
                and not StockPiler.SeedMap.GrowNamesRelated(plantData.name, seedData.name)
            then
                -- Stale/wrong grows row (mixed harvest learn).
            else
                local samples = tonumber(products[i].samples) or 0
                if samples > bestSamples then
                    bestSamples = samples
                    bestUid = plantUid
                end
            end
        end
    end
    return bestUid
end

function StockPiler.SeedMap.IsResinUid(uid)
    uid = tonumber(uid) or 0
    if uid <= 0 then
        return false
    end
    if StockPiler.Items and StockPiler.Items.Get then
        local row = StockPiler.Items.Get(uid)
        if type(row) == "table" and row.kind == "resin" then
            return true
        end
    end
    if ItemNameLooksLikeResin(LookupItemData(uid)) then
        return true
    end
    local refines = AccountTable("refines")
    local key = tostring(uid)
    for _, entry in pairs(refines) do
        if type(entry) == "table" and type(entry.byproducts) == "table"
            and type(entry.byproducts[key]) == "table"
        then
            return true
        end
    end
    return false
end

--- When a recipe has no growable ingredients but needs resin (etc.), pick a plant
--- to grow and convert. Prefers same-level extenders (Cultivating-only), then any
--- plantable seed already in bags at that crafting level.
function StockPiler.SeedMap.FindByproductConvertGrowSpec(skillLevel)
    skillLevel = tonumber(skillLevel) or 0
    if skillLevel <= 0 or not StockPiler.MaterialSpec then
        return nil
    end
    local MS = StockPiler.MaterialSpec
    local bestSpec = nil
    local bestScore = -1
    local bestSeedHave = -1
    local seenPlant = {}

    local function seedHaveOf(seedUid)
        seedUid = tonumber(seedUid) or 0
        if seedUid <= 0 then
            return 0
        end
        if StockPiler.AutoGrow and StockPiler.AutoGrow.GetEffectiveSeedCount then
            return tonumber(StockPiler.AutoGrow.GetEffectiveSeedCount(seedUid)) or 0
        end
        if StockPiler.Inventory and StockPiler.Inventory.CountByUniqueId then
            return tonumber(StockPiler.Inventory.CountByUniqueId(seedUid)) or 0
        end
        return 0
    end

    local function canUseSeed(seedUid)
        seedUid = tonumber(seedUid) or 0
        if seedUid <= 0 then
            return false
        end
        if StockPiler.Inventory and StockPiler.Inventory.CanUseUniqueId then
            return StockPiler.Inventory.CanUseUniqueId(seedUid) == true
        end
        return true
    end

    local function plantSpecForUid(plantUid)
        plantUid = tonumber(plantUid) or 0
        if plantUid <= 0 then
            return nil
        end
        local itemData = nil
        if StockPiler.Inventory and StockPiler.Inventory.CountByUniqueId then
            local _, sample = StockPiler.Inventory.CountByUniqueId(plantUid)
            itemData = sample
        end
        if type(itemData) ~= "table" then
            itemData = LookupItemData(plantUid)
        end
        if type(itemData) == "table" and MS.FromItemData then
            local spec = MS.FromItemData(itemData)
            if type(spec) == "table" then
                return spec
            end
        end
        if StockPiler.Items and StockPiler.Items.ToSpec then
            return StockPiler.Items.ToSpec(plantUid)
        end
        return nil
    end

    local function consider(plantUid, seedUid)
        plantUid = tonumber(plantUid) or 0
        seedUid = tonumber(seedUid) or 0
        if plantUid <= 0 or seenPlant[plantUid] == true then
            return
        end
        if StockPiler.SeedMap.IsResinUid(plantUid) then
            return
        end
        if seedUid <= 0 and StockPiler.SeedMap.ResolveSeedForPlantUid then
            local seed = StockPiler.SeedMap.ResolveSeedForPlantUid(plantUid)
            if type(seed) == "table" then
                seedUid = tonumber(seed.uniqueID) or 0
            end
        end
        if seedUid <= 0 then
            return
        end
        local spec = plantSpecForUid(plantUid)
        if type(spec) ~= "table" then
            return
        end
        if (tonumber(spec.skillLevel) or 0) ~= skillLevel then
            return
        end
        if StockPiler.SeedMap.IsHarvestByproduct
            and StockPiler.SeedMap.IsHarvestByproduct(spec) == true
        then
            return
        end
        local role = spec.role or ""
        local seedHave = seedHaveOf(seedUid)
        local usable = canUseSeed(seedUid)
        -- Extenders first (even with 0 seeds); other roles only if a seed is in bags.
        local score
        if role == "extender" then
            score = 300
            if seedHave > 0 then
                score = score + 20
            end
        elseif seedHave > 0 then
            score = 100
        else
            return
        end
        if usable then
            score = score + 1
        end
        seenPlant[plantUid] = true
        if score > bestScore
            or (score == bestScore and seedHave > bestSeedHave)
        then
            bestScore = score
            bestSeedHave = seedHave
            bestSpec = spec
        end
    end

    local refines = AccountTable("refines")
    for plantKey, entry in pairs(refines) do
        if type(entry) == "table" then
            consider(tonumber(plantKey), entry.seedUid)
        end
    end
    local grows = AccountTable("grows")
    for seedKey, plants in pairs(grows) do
        local seedUid = tonumber(seedKey) or 0
        if type(plants) == "table" then
            for plantKey in pairs(plants) do
                consider(tonumber(plantKey), seedUid)
            end
        end
    end
    if StockPiler.Inventory and StockPiler.Inventory.ForEachItem then
        local seedType = CultivationSeedType()
        local sporeType = CultivationSporeType()
        StockPiler.Inventory.ForEachItem(function(item)
            if type(item) ~= "table" then
                return
            end
            local cultType = tonumber(item.cultivationType) or 0
            if cultType ~= seedType and cultType ~= sporeType then
                return
            end
            local seedUid = tonumber(item.uniqueID) or 0
            local plantUid = 0
            if seedUid > 0 and StockPiler.SeedMap.GetPlantUidForSeed then
                plantUid = tonumber(StockPiler.SeedMap.GetPlantUidForSeed(seedUid)) or 0
            end
            if plantUid > 0 then
                consider(plantUid, seedUid)
            end
        end)
    end
    return bestSpec
end

function StockPiler.SeedMap.PlantsThatYieldResin(resinUid)
    resinUid = tonumber(resinUid) or 0
    local plants = {}
    if resinUid <= 0 then
        return plants
    end
    local refines = AccountTable("refines")
    local key = tostring(resinUid)
    for plantKey, entry in pairs(refines) do
        if type(entry) == "table" and type(entry.byproducts) == "table"
            and type(entry.byproducts[key]) == "table"
        then
            plants[#plants + 1] = tonumber(plantKey) or 0
        end
    end
    return plants
end

function StockPiler.SeedMap.CountLearnedGrowPairs()
    local grows = AccountTable("grows")
    local n = 0
    for _, plants in pairs(grows) do
        if type(plants) == "table" then
            for _, row in pairs(plants) do
                if type(row) == "table" then
                    n = n + 1
                end
            end
        end
    end
    return n
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

    local asItem = itemData
    if type(asItem) ~= "table" and StockPiler.Items and StockPiler.Items.AsItemData then
        asItem = StockPiler.Items.AsItemData(seedUid)
    end

    return {
        uniqueID = seedUid,
        plantUid = tonumber(plantUid) or 0,
        name = name or towstring(nameNarrow),
        nameNarrow = nameNarrow,
        match = nameNarrow,
        count = count,
        iconNum = iconNum,
        itemData = asItem,
        source = source or "unknown",
        seedKind = kind,
        isSpore = isSpore,
        reaps = false,
    }
end

local function FindObservedSeed(baseNameNarrow)
    baseNameNarrow = NormalizeGrowName(baseNameNarrow)
    if baseNameNarrow == "" then
        return nil
    end
    local items = AccountTable("items")
    local seedType = CultivationSeedType()
    local sporeType = CultivationSporeType()
    local best = nil
    for _, obs in pairs(items) do
        if type(obs) == "table" then
            local cultType = tonumber(obs.cultivationType) or 0
            local kind = obs.kind
            if cultType == seedType or cultType == sporeType
                or kind == "seed" or kind == "spore"
            then
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
            local source = "learned"
            local refines = AccountTable("refines")
            local entry = refines[tostring(plantUid)]
            if type(entry) == "table" and tonumber(entry.seedUid) == seedUid then
                source = "refine"
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

-- Plants that convert to seeds are often ct=0 apo mains. Molotov convert
-- junk (Smoking Pyre Ivy) is also isRefinable with ct=0.
function StockPiler.SeedMap.ItemLooksLikeRefinablePlant(itemData)
    if type(itemData) ~= "table" then
        return false
    end
    if itemData.isRefinable ~= true then
        return false
    end
    if IsSeedOrSporeItem(itemData) then
        return false
    end
    if StockPiler.MaterialSpec and StockPiler.MaterialSpec.FromItemData then
        local spec = StockPiler.MaterialSpec.FromItemData(itemData)
        local role = spec and spec.role or ""
        if role == "main" or role == "stabilizer" or role == "goldweed"
            or role == "extender" or role == "multiplier" or role == "stimulant"
        then
            return true
        end
    end
    return false
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
            -- Only CRAFTING (34): skip inventory trash like Wilted Wild Weed (NONE).
            if type(item) == "table" and IsCraftingItem(item) and not IsPotionBagItem(item) then
                local uid = tonumber(item.uniqueID) or 0
                if uid > 0 then
                    counts[uid] = (counts[uid] or 0) + ItemStackCount(item)
                end
            end
        end
    end
    if DataUtils and type(DataUtils.GetItems) == "function" then
        local ok, data = StockPiler.TryCallQuiet("DataUtils.GetItems", DataUtils.GetItems)
        if ok then
            addBag(data)
        end
    elseif type(GetInventoryItemData) == "function" then
        local ok, data = StockPiler.TryCallQuiet("GetInventoryItemData", GetInventoryItemData)
        if ok then
            addBag(data)
        end
    end
    if DataUtils and type(DataUtils.GetCraftingItems) == "function" then
        local ok, data = StockPiler.TryCallQuiet("DataUtils.GetCraftingItems", DataUtils.GetCraftingItems)
        if ok then
            addBag(data)
        end
    elseif type(GetCraftingItemData) == "function" then
        local ok, data = StockPiler.TryCallQuiet("GetCraftingItemData", GetCraftingItemData)
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
    if not StockPiler.SeedMap.ItemLooksLikeRefinablePlant(itemData) then
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
        started = NowSec(),
    }
end

function StockPiler.SeedMap.MaybeCompletePendingRefine()
    local pending = StockPiler.SeedMap._pendingRefine
    if type(pending) ~= "table" then
        return false
    end
    local started = tonumber(pending.started) or 0
    local now = NowSec()
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

    local seedUid = tonumber(pending.confirmedSeedUid) or 0
    local delta = tonumber(pending.confirmedSeedDelta) or 0
    local expectedSeedUid = 0
    local expectedDelta = 0
    local extras = type(pending.extras) == "table" and pending.extras or {}

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
                local prev = tonumber(extras[uid]) or 0
                if change > prev then
                    extras[uid] = change
                end
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

    local plantAfter = tonumber(countsAfter[plantUid]) or 0
    local plantBefore = tonumber(before[plantUid]) or 0
    if plantAfter >= plantBefore then
        return false
    end

    -- Seed often lands one inventory event before Arboreal Resin. Hold the
    -- watch briefly so the byproduct delta is included in the same observe.
    local hasResin = false
    for uid, _ in pairs(extras) do
        local item = LookupItemData(uid)
        if ItemNameLooksLikeResin(item)
            or (StockPiler.SeedMap.IsResinUid and StockPiler.SeedMap.IsResinUid(uid))
            or (type(item) == "table" and not IsSeedOrSporeItem(item))
        then
            hasResin = true
            break
        end
    end
    if not hasResin then
        if pending.confirmedSeedUid == nil then
            pending.confirmedSeedUid = seedUid
            pending.confirmedSeedDelta = delta
            pending.seedSeenAt = now
            pending.extras = extras
            D("SeedMap refine waiting for resin plantUid=" .. tostring(plantUid)
                .. " seedUid=" .. tostring(seedUid))
        else
            pending.extras = extras
        end
        local seenAt = tonumber(pending.seedSeenAt) or now
        if now > 0 and (now - seenAt) < 2.5 then
            return false
        end
        -- Timed out waiting for resin; still record the seed.
        seedUid = tonumber(pending.confirmedSeedUid) or seedUid
        delta = tonumber(pending.confirmedSeedDelta) or delta
    else
        seedUid = tonumber(pending.confirmedSeedUid) or seedUid
        delta = tonumber(pending.confirmedSeedDelta) or delta
        if type(pending.extras) == "table" then
            for uid, change in pairs(pending.extras) do
                local cur = tonumber(extras[uid]) or 0
                if change > cur then
                    extras[uid] = change
                end
            end
        end
    end

    StockPiler.SeedMap._pendingRefine = nil

    local refineProducts = { [seedUid] = delta }
    for uid, change in pairs(extras) do
        uid = tonumber(uid) or 0
        change = tonumber(change) or 0
        if uid > 0 and change > 0 and uid ~= plantUid and uid ~= seedUid then
            local item = LookupItemData(uid)
            if not IsSeedOrSporeItem(item) then
                refineProducts[uid] = change
                if StockPiler.MaterialSpec and type(item) == "table" then
                    local spec = StockPiler.MaterialSpec.FromItemData(item)
                    if type(spec) == "table" then
                        StockPiler.SeedMap.MarkHarvestByproduct(spec, "refine", uid)
                        D("SeedMap refine extra uid=" .. tostring(uid)
                            .. " +" .. tostring(change)
                            .. " spec=" .. tostring(StockPiler.MaterialSpec.Key(spec)))
                    end
                else
                    D("SeedMap refine extra uid=" .. tostring(uid) .. " +" .. tostring(change))
                end
            end
        end
    end
    StockPiler.SeedMap.ObserveRefine(plantUid, refineProducts, true)

    local learned = StockPiler.SeedMap.LearnMapping(plantUid, seedUid, "refine")
    if learned and StockPiler.SeedMap.ObserveMatFromRefine then
        StockPiler.SeedMap.ObserveMatFromRefine(plantUid, seedUid)
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
        started = NowSec(),
        locked = true,
        lootDirty = false,
        lootDirtyAt = 0,
        lastCompleteAttempt = 0,
    }
    D("SeedMap harvest watch plot=" .. tostring(plotNum) .. " seedUid=" .. tostring(seedUid))
end

--- Inventory events during harvest only mark dirty — do not snapshot here
--- (multi-item loot was causing multi-second frametime spikes).
function StockPiler.SeedMap.MarkHarvestLootDirty()
    local pending = StockPiler.SeedMap._pendingHarvest
    if type(pending) ~= "table" then
        return
    end
    pending.lootDirty = true
    pending.lootDirtyAt = NowSec()
end

--- After refine/brew bag changes, rebase an unlocked harvest snapshot so convert
--- deltas are not treated as harvest loot.
function StockPiler.SeedMap.RefreshHarvestWatchAfterBagChange()
    local pending = StockPiler.SeedMap._pendingHarvest
    if type(pending) ~= "table" or pending.locked == true then
        return
    end
    pending.countsBefore = SnapshotCraftingMatCounts()
    pending.started = NowSec()
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
        started = NowSec(),
        locked = false,
        lootDirty = false,
        lootDirtyAt = 0,
        lastCompleteAttempt = 0,
    }
end

--- Throttled harvest completion: one bag snapshot after loot settles (~200ms),
--- or immediately when force=true (plot became empty).
function StockPiler.SeedMap.TryCompletePendingHarvest(force)
    local pending = StockPiler.SeedMap._pendingHarvest
    if type(pending) ~= "table" then
        return false
    end
    force = force == true
    if not force and pending.lootDirty ~= true then
        return false
    end
    local now = NowSec()
    local dirtyAt = tonumber(pending.lootDirtyAt) or 0
    if not force and dirtyAt > 0 and (now - dirtyAt) < 0.2 then
        return false
    end
    local lastTry = tonumber(pending.lastCompleteAttempt) or 0
    if not force and lastTry > 0 and (now - lastTry) < 0.15 then
        return false
    end
    pending.lastCompleteAttempt = now
    pending.lootDirty = false
    return StockPiler.SeedMap.MaybeCompletePendingHarvest()
end

function StockPiler.SeedMap.MaybeCompletePendingHarvest()
    local pending = StockPiler.SeedMap._pendingHarvest
    if type(pending) ~= "table" then
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
        -- Loot may still be arriving; keep watch and allow another dirty mark.
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
        local harvestProducts = {}
        local productParts = {}
        for uid, change in pairs(deltas) do
            uid = tonumber(uid) or 0
            if uid > 0 and change > 0 and not IsSeedOrSporeItem(LookupItemData(uid))
                and not StockPiler.SeedMap.IsResinUid(uid)
                and IsCraftingItem(LookupItemData(uid))
            then
                harvestProducts[uid] = change
                local item = LookupItemData(uid)
                productParts[#productParts + 1] = ToNarrow(item and item.name or uid)
                    .. "x" .. tostring(change)
            end
        end
        local chatCues = nil
        if StockPiler.CraftChat and StockPiler.CraftChat.TakeCues then
            chatCues = StockPiler.CraftChat.TakeCues()
        end
        local critOk, critFail = StockPiler.SeedMap.RecordHarvestChatCues(seedUid, chatCues, pending)
        StockPiler.SeedMap.ObserveHarvest(seedUid, harvestProducts, true)
        local primaryData = LookupItemData(primaryUid)
        if IsCraftingItem(primaryData) and not StockPiler.SeedMap.IsResinUid(primaryUid) then
            local learned = StockPiler.SeedMap.LearnMapping(primaryUid, seedUid, "harvest")
            if type(primaryData) == "table" then
                StockPiler.SeedMap.RegisterFromItem(primaryData, seedUid)
            end
            D("SeedMap harvest plantUid=" .. tostring(primaryUid)
                .. " seedUid=" .. tostring(seedUid)
                .. " learned=" .. tostring(learned == true)
                .. " chatCritOk=" .. tostring(critOk == true)
                .. " chatCritFail=" .. tostring(critFail == true))
        end
        local yield = 1
        if StockPiler.SeedMap.ExpectedHarvestYield then
            yield = StockPiler.SeedMap.ExpectedHarvestYield(seedUid, primaryUid) or 1
        end
        local garden = ""
        if StockPiler.AutoGrow and StockPiler.AutoGrow.GardenSummary then
            garden = " " .. StockPiler.AutoGrow.GardenSummary()
        end
        if StockPiler.LogOp then
            StockPiler.LogOp("harvest", string.format(
                "done P%d seedUid=%d plantUid=%d gained=%d products=%s critOk=%s critFail=%s yieldAvg=%.2f%s",
                tonumber(pending.plotNum) or 0,
                seedUid,
                primaryUid,
                tonumber(primaryDelta) or 0,
                (#productParts > 0) and table.concat(productParts, ",") or "none",
                tostring(critOk == true),
                tostring(critFail == true),
                tonumber(yield) or 1,
                garden
            ))
        end
    end

    return true
end

function StockPiler.SeedMap.ObserveMatFromRefine(plantUid, seedUid)
    plantUid = tonumber(plantUid) or 0
    seedUid = tonumber(seedUid) or 0
    local plantData = LookupItemData(plantUid)
    if type(plantData) == "table" then
        UpsertItem(plantData, "mat")
        StockPiler.SeedMap.RegisterFromItem(plantData, seedUid)
    end
    local seedData = LookupItemData(seedUid)
    if type(seedData) == "table" then
        local kind = ProductKindForItem(seedData)
        UpsertItem(seedData, (kind == "spore") and "spore" or "seed")
        StockPiler.SeedMap.RegisterFromItem(seedData, plantUid)
    end
end

function StockPiler.SeedMap.RegisterSpecLink(plantSpec, seedSpec, seedUid, plantUid, source)
    plantUid = tonumber(plantUid) or 0
    seedUid = tonumber(seedUid) or 0
    if plantUid > 0 and seedUid > 0 then
        return StockPiler.SeedMap.LearnMapping(plantUid, seedUid, source)
    end
    return false
end

function StockPiler.SeedMap.RegisterFromItem(itemData, linkedUid)
    if type(itemData) ~= "table" then
        return false
    end
    local cultType = tonumber(itemData.cultivationType) or 0
    local seedType = CultivationSeedType()
    local sporeType = CultivationSporeType()
    local uid = tonumber(itemData.uniqueID) or 0

    if cultType == seedType or cultType == sporeType then
        UpsertItem(itemData, (cultType == sporeType) and "spore" or "seed")
        local plantUid = tonumber(linkedUid) or 0
        if plantUid > 0 and uid > 0 then
            return StockPiler.SeedMap.LearnMapping(plantUid, uid, "learned")
        end
        return false
    end

    local spec = StockPiler.MaterialSpec and StockPiler.MaterialSpec.FromItemData(itemData)
    local plantRole = type(spec) == "table" and (spec.role or "") or ""
    if itemData.isRefinable == true
        or plantRole == "main" or plantRole == "stabilizer" or plantRole == "goldweed"
        or plantRole == "extender" or plantRole == "multiplier" or plantRole == "stimulant"
    then
        UpsertItem(itemData, "mat")
        local plantUid = uid
        local seedUid = tonumber(linkedUid) or 0
        if seedUid <= 0 and plantUid > 0 then
            local seedUids = StockPiler.SeedMap.GetSeedUidsForPlant(plantUid)
            seedUid = StockPiler.SeedMap.PickBestSeedUid(plantUid, seedUids)
        end
        if seedUid > 0 and plantUid > 0 then
            local seedData = LookupItemData(seedUid)
            if type(seedData) == "table" then
                local kind = ProductKindForItem(seedData)
                UpsertItem(seedData, (kind == "spore") and "spore" or "seed")
            end
            return StockPiler.SeedMap.LearnMapping(plantUid, seedUid, "learned")
        end
        if (plantRole == "stabilizer" or plantRole == "goldweed")
            and itemData.isRefinable ~= true
            and type(spec) == "table"
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

    local items = AccountTable("items")
    for uidKey, row in pairs(items) do
        if type(row) == "table" and row.kind ~= "seed" and row.kind ~= "spore" and row.kind ~= "resin" then
            local uid = tonumber(row.uniqueID) or tonumber(uidKey) or 0
            if uid > 0 then
                if StockPiler.Items and StockPiler.Items.ToSpec and MS.Key then
                    local itemSpec = StockPiler.Items.ToSpec(uid)
                    if type(itemSpec) == "table" and MS.Key(itemSpec) == MS.Key(spec) then
                        if IsCultivatablePlantItem(StockPiler.Items.AsItemData(uid) or row) then
                            bestUid = uid
                        end
                    elseif MS.Matches then
                        local asItem = StockPiler.Items.AsItemData(uid)
                        if type(asItem) == "table" and MS.Matches(asItem, spec)
                            and IsCultivatablePlantItem(asItem)
                        then
                            bestUid = uid
                        end
                    end
                else
                    considerUid(uid, row.role)
                end
            end
        end
    end
    if bestUid > 0 then
        return bestUid
    end

    local grows = AccountTable("grows")
    for _, plants in pairs(grows) do
        if type(plants) == "table" then
            for plantKey, row in pairs(plants) do
                if type(row) == "table" then
                    considerUid(plantKey, nil)
                end
            end
        end
    end
    if bestUid > 0 then
        return bestUid
    end

    local recipes = AccountTable("recipes")
    for _, recipe in pairs(recipes) do
        if type(recipe) == "table" and type(recipe.slots) == "table" then
            for i = 1, #recipe.slots do
                local slot = recipe.slots[i]
                if type(slot) == "table" then
                    considerUid(slot.uid, slot.role)
                end
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
    StockPiler.SeedMap.LearnMapping(plantUid, seedUid, "learned")
    return record
end

function StockPiler.SeedMap.CachedPlantUidForSpec(spec)
    if type(spec) ~= "table" or not StockPiler.MaterialSpec then
        return 0
    end
    local MS = StockPiler.MaterialSpec
    local plantKey = MS.Key(spec)
    if plantKey == "" then
        return 0
    end

    local function uidMatches(uid)
        uid = tonumber(uid) or 0
        if uid <= 0 then
            return false
        end
        if StockPiler.Items and StockPiler.Items.ToSpec then
            local itemSpec = StockPiler.Items.ToSpec(uid)
            if type(itemSpec) == "table" and MS.Key(itemSpec) == plantKey then
                return true
            end
        end
        local itemData = LookupItemData(uid)
        if type(itemData) == "table" and MS.Matches and MS.Matches(itemData, spec) then
            return true
        end
        return false
    end

    local grows = AccountTable("grows")
    for _, plants in pairs(grows) do
        if type(plants) == "table" then
            for plantUidKey, row in pairs(plants) do
                if type(row) == "table" and uidMatches(plantUidKey) then
                    return tonumber(plantUidKey) or 0
                end
            end
        end
    end

    local items = AccountTable("items")
    for uidKey, row in pairs(items) do
        if type(row) == "table" and row.kind ~= "seed" and row.kind ~= "spore" and row.kind ~= "resin" then
            local uid = tonumber(row.uniqueID) or tonumber(uidKey) or 0
            if uidMatches(uid) then
                return uid
            end
        end
    end

    local refines = AccountTable("refines")
    for plantKeyUid, entry in pairs(refines) do
        if type(entry) == "table" and (tonumber(entry.seedUid) or 0) > 0 and uidMatches(plantKeyUid) then
            return tonumber(plantKeyUid) or 0
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
    local expectedPlant = StockPiler.SeedMap.CachedPlantUidForSpec(spec)
    if expectedPlant <= 0 then
        expectedPlant = StockPiler.SeedMap.FindPlantUidForSpec(spec)
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
        if expectedPlant > 0 and plantUid == expectedPlant then
            ok = true
        elseif plantUid > 0 and MS.Matches then
            local plantData = LookupItemData(plantUid)
            if type(plantData) == "table" and MS.Matches(plantData, spec) == true then
                ok = true
            end
        end
        -- Seed name must match the plant it claims to grow (blocks Gobswort→Goldweed).
        if ok then
            local plantData = (plantUid > 0 and LookupItemData(plantUid)) or nil
            if type(plantData) == "table"
                and not StockPiler.SeedMap.GrowNamesRelated(plantData.name, item.name)
            then
                ok = false
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
    local seen = {}
    local repaired = 0
    local recipes = AccountTable("recipes")
    for _, recipe in pairs(recipes) do
        if type(recipe) == "table" and type(recipe.slots) == "table" then
            for i = 1, #recipe.slots do
                local slot = recipe.slots[i]
                if type(slot) == "table" and GROW_REPAIR_ROLES[slot.role] then
                    local uid = tonumber(slot.uid) or 0
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
    return repaired
end

function StockPiler.SeedMap.ResetSpecMaps()
    ClearAccountTable("grows")
    ClearAccountTable("refines")
    StockPiler.SeedMap._specBootstrapDone = true
    local repaired = StockPiler.SeedMap.RepairFromLearnedRecipes() or 0
    if StockPiler.Trace then
        StockPiler.Trace("Reset grow/refine maps recipeRepair=" .. tostring(repaired))
    end
    if StockPiler.AutoGrow and StockPiler.AutoGrow.InvalidatePlantQueue then
        StockPiler.AutoGrow.InvalidatePlantQueue()
    end
    return 0, repaired
end

function StockPiler.SeedMap.ApplyPendingMapReset()
    return false
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

--- True when a plant matching this spec appears in grows products or has a refine seed.
local function SpecLinkedToGrowOrRefine(spec)
    if type(spec) ~= "table" or not StockPiler.MaterialSpec then
        return false
    end
    local MS = StockPiler.MaterialSpec
    local plantKey = MS.Key(spec)
    if plantKey == "" then
        return false
    end

    local function uidMatches(uid)
        uid = tonumber(uid) or 0
        if uid <= 0 then
            return false
        end
        if StockPiler.Items and StockPiler.Items.ToSpec then
            local itemSpec = StockPiler.Items.ToSpec(uid)
            if type(itemSpec) == "table" and MS.Key(itemSpec) == plantKey then
                return true
            end
        end
        local itemData = LookupItemData(uid)
        return type(itemData) == "table" and MS.Matches and MS.Matches(itemData, spec) == true
    end

    local grows = AccountTable("grows")
    for _, plants in pairs(grows) do
        if type(plants) == "table" then
            for plantUidKey, row in pairs(plants) do
                if type(row) == "table" and uidMatches(plantUidKey) then
                    return true
                end
            end
        end
    end

    local refines = AccountTable("refines")
    for plantUidKey, entry in pairs(refines) do
        if type(entry) == "table" and (tonumber(entry.seedUid) or 0) > 0 and uidMatches(plantUidKey) then
            return true
        end
    end
    return false
end

local function SpecHasGrowProducer(spec)
    return SpecLinkedToGrowOrRefine(spec)
end

function StockPiler.SeedMap.MarkHarvestByproduct(spec, source, uniqueID)
    if type(spec) ~= "table" or not StockPiler.MaterialSpec then
        return false
    end
    -- Goldweed (and butcher substitutes like Zoic Gore) share +stab/+multiplier.
    -- Resin convert extras do not.
    if SpecHasGoldweedMultiplier(spec) or SpecHasGrowProducer(spec) then
        return false
    end
    uniqueID = tonumber(uniqueID) or 0
    if uniqueID <= 0 then
        return false
    end
    local itemData = LookupItemData(uniqueID)
    if type(itemData) == "table" then
        UpsertItem(itemData, "resin")
    elseif StockPiler.Items and StockPiler.Items.Upsert then
        StockPiler.Items.Upsert(uniqueID, { kind = "resin" })
    end
    D("SeedMap harvest byproduct uid=" .. tostring(uniqueID)
        .. " source=" .. tostring(source or "learned"))
    return true
end

function StockPiler.SeedMap.IsHarvestByproduct(spec)
    if type(spec) ~= "table" or not StockPiler.MaterialSpec then
        return false
    end
    local MS = StockPiler.MaterialSpec
    local key = MS.Key(spec)
    if key == "" then
        return false
    end
    if SpecHasGoldweedMultiplier(spec) or SpecHasGrowProducer(spec) then
        return false
    end

    local function uidMatchesSpec(uid)
        uid = tonumber(uid) or 0
        if uid <= 0 then
            return false
        end
        if StockPiler.Items and StockPiler.Items.ToSpec then
            local itemSpec = StockPiler.Items.ToSpec(uid)
            if type(itemSpec) == "table" and MS.Key(itemSpec) == key then
                return true
            end
        end
        local itemData = LookupItemData(uid)
        return type(itemData) == "table" and MS.Matches and MS.Matches(itemData, spec) == true
    end

    local items = AccountTable("items")
    for uidKey, row in pairs(items) do
        if type(row) == "table" and row.kind == "resin" then
            local uid = tonumber(row.uniqueID) or tonumber(uidKey) or 0
            if uidMatchesSpec(uid) then
                return true
            end
        end
    end

    local refines = AccountTable("refines")
    for _, entry in pairs(refines) do
        if type(entry) == "table" and type(entry.byproducts) == "table" then
            for resinKey, _ in pairs(entry.byproducts) do
                if uidMatchesSpec(resinKey) then
                    return true
                end
            end
        end
    end
    return false
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
    -- Name-like resin, or treat seedless stabilizer as resin byproduct.
    if ItemNameLooksLikeResin(itemData) or role == "stabilizer" then
        return StockPiler.SeedMap.MarkHarvestByproduct(spec, "learned", uid)
    end
    return false
end

function StockPiler.SeedMap.IsGrowableSpec(spec)
    if type(spec) ~= "table" or not StockPiler.MaterialSpec then
        return false
    end
    local role = spec.role or ""
    if role == "container" then
        return false
    end
    if StockPiler.SeedMap.IsHarvestByproduct(spec) then
        return false
    end
    return SpecLinkedToGrowOrRefine(spec)
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

    local named = StockPiler.SeedMap.ResolveSeedForMaterial({
        uniqueID = plantUid > 0 and plantUid or nil,
        nameNarrow = ToNarrow(MS.Label(spec)),
        role = spec.role,
    }, nil)
    if type(named) == "table" and (tonumber(named.count) or 0) > 0 then
        return named
    end
    return named
end

function StockPiler.SeedMap.BootstrapSpecMap()
    return 0
end

function StockPiler.SeedMap.ForgetUnrelatedLearnedMaps()
    local dropped = 0

    local grows = AccountTable("grows")
    for seedKey, plants in pairs(grows) do
        if type(plants) == "table" then
            local seedUid = tonumber(seedKey) or 0
            local seedData = seedUid > 0 and LookupItemData(seedUid) or nil
            for plantKey, row in pairs(plants) do
                if type(row) == "table" then
                    local plantUid = tonumber(plantKey) or 0
                    local plantData = plantUid > 0 and LookupItemData(plantUid) or nil
                    local resinPlant = StockPiler.SeedMap.IsResinUid and StockPiler.SeedMap.IsResinUid(plantUid)
                    if resinPlant
                        or (type(plantData) == "table" and type(seedData) == "table"
                            and not StockPiler.SeedMap.GrowNamesRelated(plantData.name, seedData.name))
                    then
                        plants[plantKey] = nil
                        dropped = dropped + 1
                        D("SeedMap forgot unrelated grow plantUid=" .. tostring(plantUid)
                            .. " seedUid=" .. tostring(seedUid))
                    end
                end
            end
            if next(plants) == nil then
                grows[seedKey] = nil
            end
        end
    end

    local refines = AccountTable("refines")
    for plantKey, entry in pairs(refines) do
        if type(entry) == "table" then
            local plantUid = tonumber(plantKey) or 0
            local seedUid = tonumber(entry.seedUid) or 0
            if plantUid > 0 and seedUid > 0 then
                local plantData = LookupItemData(plantUid)
                local seedData = LookupItemData(seedUid)
                local resinPlant = StockPiler.SeedMap.IsResinUid and StockPiler.SeedMap.IsResinUid(plantUid)
                if resinPlant
                    or (type(plantData) == "table" and type(seedData) == "table"
                        and not StockPiler.SeedMap.GrowNamesRelated(plantData.name, seedData.name))
                then
                    entry.seedUid = 0
                    entry.seedKind = nil
                    dropped = dropped + 1
                    D("SeedMap forgot unrelated refine plantUid=" .. tostring(plantUid)
                        .. " seedUid=" .. tostring(seedUid))
                end
            end
        end
    end
    return dropped
end

local function OutcomeItemName(uid)
    uid = tonumber(uid) or 0
    if uid <= 0 then
        return "?"
    end
    local data = LookupItemData(uid)
    local name = ToNarrow(data and data.name)
    if name ~= "" then
        return name
    end
    if StockPiler.ItemDisplayName then
        name = ToNarrow(StockPiler.ItemDisplayName(uid, nil))
        if name ~= "" then
            return name
        end
    end
    return tostring(uid)
end

local function FormatOutcomeQty(prod)
    if type(prod) ~= "table" then
        return ""
    end
    if (tonumber(prod.samples) or 0) > 0 then
        return string.format("%.1fx ", OutcomeAvg(prod))
    end
    if (tonumber(prod.last) or 0) > 0 then
        return tostring(prod.last) .. "x "
    end
    return ""
end

local function FormatOutcomeProducts(list)
    local parts = {}
    for i = 1, #list do
        local prod = list[i]
        local uid = tonumber(prod.uid) or 0
        parts[#parts + 1] = FormatOutcomeQty(prod)
            .. OutcomeItemName(uid)
            .. " (" .. tostring(uid) .. ")"
    end
    if #parts == 0 then
        return "(none)"
    end
    return table.concat(parts, ", ")
end

local function DumpGrowsToChat(chatMax)
    local grows = AccountTable("grows")
    local rows = {}
    for seedKey, plants in pairs(grows) do
        if type(plants) == "table" then
            local seedUid = tonumber(seedKey) or 0
            local products = StockPiler.SeedMap.HarvestProducts(seedUid)
            rows[#rows + 1] = {
                uid = seedUid,
                name = OutcomeItemName(seedUid),
                products = products,
            }
        end
    end
    table.sort(rows, function(a, b)
        if a.name ~= b.name then
            return string.lower(a.name) < string.lower(b.name)
        end
        return (a.uid or 0) < (b.uid or 0)
    end)
    local header = "Grows (seed -> plants): " .. tostring(#rows)
    D("SeedMap dump " .. header)
    if StockPiler.Print then
        StockPiler.Print(towstring(header))
    end
    chatMax = tonumber(chatMax) or 30
    for i = 1, #rows do
        local row = rows[i]
        local line = row.name .. " (" .. tostring(row.uid) .. ") -> "
            .. FormatOutcomeProducts(row.products)
        D("SeedMap " .. line)
        if i <= chatMax and StockPiler.Print then
            StockPiler.Print(towstring(line))
        end
    end
    if #rows > chatMax and StockPiler.Print then
        StockPiler.Print(L"... " .. towstring(tostring(#rows - chatMax))
            .. L" more written to uilog.log")
    end
    return #rows
end

local function DumpRefinesToChat(chatMax)
    local refines = AccountTable("refines")
    local rows = {}
    for plantKey, entry in pairs(refines) do
        if type(entry) == "table" then
            local plantUid = tonumber(plantKey) or 0
            rows[#rows + 1] = {
                uid = plantUid,
                name = OutcomeItemName(plantUid),
                products = StockPiler.SeedMap.RefineProducts(plantUid),
            }
        end
    end
    table.sort(rows, function(a, b)
        if a.name ~= b.name then
            return string.lower(a.name) < string.lower(b.name)
        end
        return (a.uid or 0) < (b.uid or 0)
    end)
    local header = "Refines (plant -> seed + extras): " .. tostring(#rows)
    D("SeedMap dump " .. header)
    if StockPiler.Print then
        StockPiler.Print(towstring(header))
    end
    chatMax = tonumber(chatMax) or 30
    for i = 1, #rows do
        local row = rows[i]
        local line = row.name .. " (" .. tostring(row.uid) .. ") -> "
            .. FormatOutcomeProducts(row.products)
        D("SeedMap " .. line)
        if i <= chatMax and StockPiler.Print then
            StockPiler.Print(towstring(line))
        end
    end
    if #rows > chatMax and StockPiler.Print then
        StockPiler.Print(L"... " .. towstring(tostring(#rows - chatMax))
            .. L" more written to uilog.log")
    end
    return #rows
end

function StockPiler.SeedMap.DumpToChat()
    local growN = DumpGrowsToChat(25)
    local refineN = DumpRefinesToChat(25)
    return growN + refineN
end

--- Prefer engine/bag type; skip Account AsItemData (often itemType=0 until relearned).
local function LiveItemType(uid)
    uid = tonumber(uid) or 0
    if uid <= 0 then
        return nil
    end
    if StockPiler.Inventory and StockPiler.Inventory.CountByUniqueId then
        local _, sample = StockPiler.Inventory.CountByUniqueId(uid)
        if type(sample) == "table" then
            local t = tonumber(sample.type) or tonumber(sample.itemType)
            if t ~= nil then
                return t
            end
        end
    end
    if GetDatabaseItemData ~= nil then
        local ok, data = StockPiler.TryCallQuiet("GetDatabaseItemData", GetDatabaseItemData, uid)
        if ok and type(data) == "table" then
            return tonumber(data.type) or tonumber(data.itemType)
        end
    end
    return nil
end

--- Drop grow products that are not ItemTypes.CRAFTING (cleans Wilted Wild Weed, etc.).
function StockPiler.SeedMap.PruneNonCraftingGrowProducts()
    local dropped = 0
    local grows = AccountTable("grows")
    for seedKey, plants in pairs(grows) do
        if type(plants) == "table" then
            for plantKey, row in pairs(plants) do
                if type(row) == "table" then
                    local plantUid = tonumber(plantKey) or 0
                    local t = LiveItemType(plantUid)
                    if t ~= nil and t ~= CraftingItemType() then
                        plants[plantKey] = nil
                        dropped = dropped + 1
                        D("SeedMap pruned non-crafting grow plantUid=" .. tostring(plantUid)
                            .. " seedUid=" .. tostring(seedKey)
                            .. " type=" .. tostring(t))
                    end
                end
            end
            if next(plants) == nil then
                grows[seedKey] = nil
            end
        end
    end
    return dropped
end

--- Remove harvest-trash leftovers that landed in Account.items (e.g. Wilted Wild Weed).
function StockPiler.SeedMap.PruneNonCraftingItemOrphans()
    local dropped = 0
    if not (StockPiler.Items and StockPiler.Items.Get) then
        return 0
    end
    local items = AccountTable("items")
    local remove = {}
    for uidKey, row in pairs(items) do
        if type(row) == "table" then
            local uid = tonumber(row.uniqueID) or tonumber(uidKey) or 0
            local t = LiveItemType(uid)
            local cachedType = tonumber(row.itemType)
            local knownType = t
            if knownType == nil and cachedType ~= nil and cachedType > 0 then
                knownType = cachedType
            end
            -- Wilted-style trash: non-crafting, never a recipe/grow/refine actor.
            local name = string.lower(ToNarrow(row.nameNarrow or row.name))
            local looksWilted = string.find(name, "wilted", 1, true) ~= nil
            if looksWilted or (knownType ~= nil and knownType ~= CraftingItemType()
                and row.kind == "mat" and (tonumber(row.skillReq) or 0) == 0
                and (row.role == "container" or row.role == "ingredient"))
            then
                -- Don't drop real vials/containers used in recipes.
                local inRecipe = false
                local recipes = AccountTable("recipes")
                for _, recipe in pairs(recipes) do
                    if type(recipe) == "table" and type(recipe.slots) == "table" then
                        for _, slot in pairs(recipe.slots) do
                            if type(slot) == "table" and (tonumber(slot.uid) or 0) == uid then
                                inRecipe = true
                                break
                            end
                        end
                    end
                    if inRecipe then
                        break
                    end
                end
                if not inRecipe then
                    remove[#remove + 1] = uidKey
                end
            end
        end
    end
    for i = 1, #remove do
        items[remove[i]] = nil
        dropped = dropped + 1
        D("SeedMap pruned non-crafting item orphan uid=" .. tostring(remove[i]))
    end
    return dropped
end

function StockPiler.SeedMap.PruneOrphanRefineByproducts()
    local refines = AccountTable("refines")
    local pruned = 0
    for plantKey, entry in pairs(refines) do
        if type(entry) == "table" and type(entry.byproducts) == "table" then
            local plantUid = tonumber(plantKey) or 0
            local remove = {}
            for uidKey, row in pairs(entry.byproducts) do
                local uid = tonumber(uidKey) or 0
                if uid > 0 then
                    local samples = type(row) == "table" and (tonumber(row.samples) or 0) or 0
                    local countSum = type(row) == "table" and (tonumber(row.countSum) or 0) or 0
                    local badPair = StockPiler.SeedMap.PairLooksLikePlantAndSeed
                        and not StockPiler.SeedMap.PairLooksLikePlantAndSeed(plantUid, uid)
                    if (samples <= 0 and countSum <= 0) or badPair == true then
                        remove[#remove + 1] = uidKey
                    end
                end
            end
            for i = 1, #remove do
                entry.byproducts[remove[i]] = nil
                pruned = pruned + 1
            end
        end
    end
    if pruned > 0 and StockPiler.D then
        StockPiler.D("SeedMap pruned orphan refine byproducts=" .. tostring(pruned))
    end
    return pruned
end

function StockPiler.SeedMap.EnsureSpecBootstrap()
    StockPiler.SeedMap._specBootstrapDone = true
    StockPiler.SeedMap.PruneNonCraftingGrowProducts()
    StockPiler.SeedMap.PruneNonCraftingItemOrphans()
    StockPiler.SeedMap.PruneOrphanRefineByproducts()
    -- Drop mixed-harvest pairs (e.g. Gobswort Spore → Majestic Goldweed).
    StockPiler.SeedMap.ForgetUnrelatedLearnedMaps()
    return 0
end

