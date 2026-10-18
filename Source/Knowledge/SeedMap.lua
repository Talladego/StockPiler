----------------------------------------------------------------
-- StockPiler Knowledge/SeedMap - single facade (observe / resolve / stats)
-- Learn/snapshot ONLY on harvest complete attempts.
----------------------------------------------------------------

StockPiler = StockPiler or {}
StockPiler.SeedMap = StockPiler.SeedMap or {}
local SM = StockPiler.SeedMap

SM.REFINE_CONVERT_FAIL_COOLDOWN_SEC = 45
SM.REFINE_FAST_FAIL_SEC = 1.5
SM._refineConvertFailed = SM._refineConvertFailed or {}
SM._refineConvertFailedUntil = SM._refineConvertFailedUntil or {}
SM._pendingHarvest = {}
SM._pendingRefine = nil
SM._plotSeeds = SM._plotSeeds or {}
SM._harvestWatch = SM._harvestWatch or {}
SM._plantUidCache = SM._plantUidCache or {}
SM._plantUidCacheSnap = nil

-- Permanent purple (Eternal *) - never consumed.
local ETERNAL_SEED_UID = {
    [199801] = true, [199802] = true, [199803] = true, [199804] = true,
    [199805] = true, [199806] = true, [199809] = true, [199810] = true,
    [199811] = true, [199812] = true,
}
-- Charged purple (Exceptional *) - ~250 grows then spent.
local EXCEPTIONAL_SEED_UID = {
    [2018021] = true, [2018022] = true, [2018023] = true,
    [2018024] = true, [2018025] = true, [2018026] = true,
}
-- One-shot hybrid seeds (infertile for sustainable regrowth). waremu probe 2026-09-16.
local INFERTILE_SEED_UID = {
    [2017641] = true, [2017642] = true, [2017643] = true, [2017644] = true,
    [2017645] = true, [2017646] = true, [2017647] = true, [2017648] = true,
    [2017649] = true, [2017650] = true, [2017651] = true, [2017652] = true,
}

----------------------------------------------------------------
-- Helpers (callees first)
----------------------------------------------------------------

local function ToNarrow(text)
    return StockPiler.Util.ToNarrow(text)
end

-- Defined with the family-ladder section. Forward-declared so
-- ResolveSeedUidForPlant does not call an undefined global (BUG-1).
local ItemSkillReq

local function NowSec()
    return StockPiler.Util and StockPiler.Util.NowSec and StockPiler.Util.NowSec() or 0
end

local function GrowsTable()
    return StockPiler.Knowledge and StockPiler.Knowledge.Grows and StockPiler.Knowledge.Grows() or nil
end

local function RefinesTable()
    return StockPiler.Knowledge and StockPiler.Knowledge.Refines and StockPiler.Knowledge.Refines() or nil
end

local function CultSeedType()
    return (GameData and GameData.CultivationTypes and GameData.CultivationTypes.SEED) or 1
end

local function CultSporeType()
    return (GameData and GameData.CultivationTypes and GameData.CultivationTypes.SPORE) or 5
end

local function BagSample(uid)
    uid = tonumber(uid) or 0
    if uid <= 0 then
        return nil
    end
    if StockPiler.Inventory and StockPiler.Inventory.GetSample then
        local s = StockPiler.Inventory.GetSample(uid)
        if type(s) == "table" then
            return s
        end
    end
    if StockPiler.Items and StockPiler.Items.AsItemData then
        return StockPiler.Items.AsItemData(uid)
    end
    return nil
end

local function NormalizeGrowName(nameNarrow)
    local s = string.lower(nameNarrow or "")
    if StockPiler.Items and StockPiler.Items.StripEternalExceptionalBunchedPrefixes then
        s = StockPiler.Items.StripEternalExceptionalBunchedPrefixes(s)
    else
        s = string.gsub(s, "^bunched%s+", "")
        s = string.gsub(s, "^eternal%s+", "")
        s = string.gsub(s, "^exceptional%s+", "")
    end
    s = string.gsub(s, "%s+seed%s+packet$", "")
    s = string.gsub(s, "%s+spore%s+packet$", "")
    s = string.gsub(s, "%s+bloodseed$", "")
    s = string.gsub(s, "bloodseed$", "")
    s = string.gsub(s, "%s+seed$", "")
    s = string.gsub(s, "%s+spore$", "")
    s = string.gsub(s, "seed$", "")
    s = string.gsub(s, "spore$", "")
    s = string.gsub(s, "%s+powder$", "")
    s = string.gsub(s, "%s+extract$", "")
    s = string.gsub(s, "%s+blood$", "")
    s = string.gsub(s, "%s+dust$", "")
    s = string.gsub(s, "%s+oil$", "")
    s = string.gsub(s, "%s+pulp$", "")
    s = string.gsub(s, "%s+", " ")
    s = string.gsub(s, "^%s+", "")
    s = string.gsub(s, "%s+$", "")
    return s
end

local function GrowNamesRelated(plantName, seedName)
    local a = NormalizeGrowName(ToNarrow(plantName))
    local b = NormalizeGrowName(ToNarrow(seedName))
    if a == "" or b == "" then
        return false
    end
    if a == b then
        return true
    end
    if string.gsub(a, " ", "") == string.gsub(b, " ", "") then
        return true
    end
    -- Genus token (last word) match for crit tiers.
    local ta = string.match(a, "([^%s]+)$") or a
    local tb = string.match(b, "([^%s]+)$") or b
    return ta ~= "" and ta == tb
end

local function SeedReplantTier(seedUid, nameHint)
    seedUid = tonumber(seedUid) or 0
    if seedUid > 0 and ETERNAL_SEED_UID[seedUid] then
        return 3
    end
    if seedUid > 0 and EXCEPTIONAL_SEED_UID[seedUid] then
        return 2
    end
    local n = string.lower(ToNarrow(nameHint))
    if n == "" then
        local data = BagSample(seedUid)
        n = string.lower(ToNarrow(data and data.name))
    end
    if string.find(n, "eternal", 1, true) then
        return 3
    end
    if string.find(n, "exceptional", 1, true) then
        return 2
    end
    return 1
end

local function IsBagSeedOrSporeItem(itemData)
    if type(itemData) ~= "table" then
        return false
    end
    local cult = tonumber(itemData.cultivationType) or 0
    if cult == CultSeedType() or cult == CultSporeType() then
        return true
    end
    local n = string.lower(ToNarrow(itemData.name))
    return string.find(n, "seed", 1, true) ~= nil or string.find(n, "spore", 1, true) ~= nil
end

local function IsSeedPacketItem(itemData)
    if type(itemData) ~= "table" then
        return false
    end
    local n = string.lower(ToNarrow(itemData.name))
    return string.find(n, "seed packet", 1, true) ~= nil
        or string.find(n, "spore packet", 1, true) ~= nil
end

local function LooksSpecialSquigBits(itemData)
    if type(itemData) ~= "table" then
        return false
    end
    local n = string.lower(ToNarrow(itemData.name))
    return string.find(n, "special squig", 1, true) ~= nil
        or string.find(n, "squig bits", 1, true) ~= nil
end

local function LooksButcher(nameNarrow)
    local n = string.lower(nameNarrow or "")
    -- Animal / vendor butcher apo mains (spittle = glue-bomb / snare family).
    return string.find(n, "tooth", 1, true)
        or string.find(n, "scale", 1, true)
        or string.find(n, "chitin", 1, true)
        or string.find(n, "zoic", 1, true)
        or string.find(n, "gore", 1, true)
        or string.find(n, "squig", 1, true)
        or string.find(n, "daemonic", 1, true)
        or string.find(n, "khornish", 1, true)
        or string.find(n, "spittle", 1, true)
        or string.find(n, "bile", 1, true)
        or string.find(n, "ichor", 1, true)
        or string.find(n, "feather", 1, true)
        or string.find(n, "flesh", 1, true)
        or string.find(n, "tongue", 1, true)
        or string.find(n, "claw", 1, true)
        or string.find(n, "humor", 1, true)
        or string.find(n, "wing", 1, true)
        or string.find(n, "shard", 1, true)
end

local function DescLooksInfertileSeed(description)
    local d = string.lower(ToNarrow(description))
    if d == "" then
        return false
    end
    return string.find(d, "infertile for sustainable regrowth", 1, true) ~= nil
        or string.find(d, "infertile", 1, true) ~= nil
end

local function LookupDescription(specOrItem)
    if type(specOrItem) ~= "table" then
        return ""
    end
    local desc = specOrItem.description or specOrItem.desc or specOrItem.descriptionNarrow
    if desc ~= nil and ToNarrow(desc) ~= "" then
        return desc
    end
    local uid = tonumber(specOrItem.uid) or tonumber(specOrItem.uniqueID) or tonumber(specOrItem.boundUid) or 0
    if uid > 0 and StockPiler.Items and StockPiler.Items.GetByUid then
        local row = StockPiler.Items.GetByUid(uid)
        if type(row) == "table" then
            local rd = row.description or row.descriptionNarrow
            if rd ~= nil and ToNarrow(rd) ~= "" then
                return rd
            end
        end
    end
    if uid > 0 and type(GetDatabaseItemData) == "function" then
        local ok, data = pcall(GetDatabaseItemData, uid)
        if ok and type(data) == "table" and data.description ~= nil then
            return data.description
        end
    end
    return ""
end

local function TouchIfStructural(reason)
    if StockPiler.Knowledge and StockPiler.Knowledge.Touch then
        StockPiler.Knowledge.Touch(reason or "seedmap")
    end
end

local function EnsureGrowBucket(seedUid)
    local grows = GrowsTable()
    if type(grows) ~= "table" then
        return nil
    end
    local key = tostring(seedUid)
    local bucket = grows[key]
    if type(bucket) ~= "table" then
        bucket = {
            seedUid = seedUid,
            products = {},
            plantAttempts = 0,
            harvestAttempts = 0,
            cultSkillHits = 0,
            specialMomentHits = 0,
            chatCriticalSuccess = 0,
            chatCriticalFailure = 0,
        }
        grows[key] = bucket
    end
    return bucket
end

local function EnsureRefineEntry(plantUid, persist)
    local refines = RefinesTable()
    if type(refines) ~= "table" then
        return nil
    end
    local key = tostring(plantUid)
    local entry = refines[key]
    if type(entry) ~= "table" then
        entry = {
            plantUid = plantUid,
            refineAttempts = 0,
            seedUid = 0,
            seedOut = {},
        }
        -- Only persist when a seed convert is proven (avoid dead seedUid=0 rows).
        if persist == true then
            refines[key] = entry
        end
    end
    return entry
end

local function HasProvenSeedConvert(plantUid)
    plantUid = tonumber(plantUid) or 0
    if plantUid <= 0 then
        return false
    end
    local entry = RefinesTable() and RefinesTable()[tostring(plantUid)]
    if type(entry) == "table" and type(entry.seedOut) == "table" then
        for _, row in pairs(entry.seedOut) do
            if type(row) == "table" and (tonumber(row.samples) or 0) > 0 then
                return true
            end
        end
    end
    local uids = SM.GetSeedUidsForPlant(plantUid)
    return type(uids) == "table" and #uids > 0
end

--- EFFECT id from a seed item (bag / learned / DB). Seeds parse as non-main unless hinted.
function SM.ResolveSeedEffectId(seedUid)
    seedUid = tonumber(seedUid) or 0
    if seedUid <= 0 then
        return 0
    end
    if SM.IsSeedPacketUid(seedUid) then
        return 0
    end
    local MS = StockPiler.MaterialSpec
    local sample = BagSample(seedUid)
    if type(sample) == "table" and MS and MS.FromItemData then
        local spec = MS.FromItemData(sample, "main")
        local eid = type(spec) == "table" and tonumber(spec.effectId) or 0
        if eid > 0 then
            return eid
        end
    end
    local Items = StockPiler.Items
    if Items and Items.GetByUid then
        local row = Items.GetByUid(seedUid)
        if type(row) == "table" then
            local eid = tonumber(row.effectId) or 0
            if eid <= 0 and type(row.bonuses) == "table" then
                eid = tonumber(row.bonuses[6]) or 0
            end
            if eid > 0 then
                return eid
            end
        end
    end
    if type(GetDatabaseItemData) == "function" and MS and MS.FromItemData then
        local ok, data = pcall(GetDatabaseItemData, seedUid)
        if ok and type(data) == "table" then
            local spec = MS.FromItemData(data, "main")
            local eid = type(spec) == "table" and tonumber(spec.effectId) or 0
            if eid > 0 then
                return eid
            end
        end
    end
    return 0
end

local function PlantLooksLikeByproduct(plantUid, plantData)
    plantUid = tonumber(plantUid) or 0
    if type(plantData) == "table" and SM.IsHarvestByproduct(plantData) then
        return true
    end
    if plantUid > 0 and StockPiler.Items and StockPiler.Items.GetByUid then
        local learned = StockPiler.Items.GetByUid(plantUid)
        if type(learned) == "table" and SM.IsHarvestByproduct(learned) then
            return true
        end
    end
    return false
end

local function StampPlantEffectFromSeedLink(seedUid, plantUid, plantData)
    seedUid = tonumber(seedUid) or 0
    plantUid = tonumber(plantUid) or 0
    if seedUid <= 0 or plantUid <= 0 then
        return 0
    end
    if SM.IsSeedPacketUid(seedUid) or PlantLooksLikeByproduct(plantUid, plantData) then
        return 0
    end
    local effectId = SM.ResolveSeedEffectId(seedUid)
    -- Only EFFECT transfers seed→plant (cult Super-Crit / Fail Chance stay on seeds).
    if StockPiler.Items and StockPiler.Items.StampPlantEffectFromSeed then
        StockPiler.Items.StampPlantEffectFromSeed(plantUid, effectId, plantData, seedUid)
    end
    return effectId
end

--- True when this plant can be learned as a product of this seed.
--- Unknown seed or plant samples are accepted so a first harvest can still link.
local function HarvestProductRelated(seedUid, plantUid)
    seedUid = tonumber(seedUid) or 0
    plantUid = tonumber(plantUid) or 0
    if seedUid <= 0 or plantUid <= 0 then
        return false
    end
    local plantData = BagSample(plantUid)
    local seedData = BagSample(seedUid)
    if type(plantData) == "table" and type(seedData) == "table" then
        if not GrowNamesRelated(plantData.name, seedData.name) then
            return false
        end
    end
    if type(plantData) == "table" and LooksButcher(ToNarrow(plantData.name))
        and not GrowNamesRelated(plantData.name, seedData and seedData.name)
    then
        return false
    end
    return true
end

local function RecordHarvestProduct(seedUid, plantUid, qty)
    seedUid = tonumber(seedUid) or 0
    plantUid = tonumber(plantUid) or 0
    if not HarvestProductRelated(seedUid, plantUid) then
        return false
    end
    local plantData = BagSample(plantUid)
    local seedData = BagSample(seedUid)
    local bucket = EnsureGrowBucket(seedUid)
    if type(bucket) ~= "table" then
        return false
    end
    local products = bucket.products
    if type(products) ~= "table" then
        products = {}
        bucket.products = products
    end
    local pk = tostring(plantUid)
    local row = products[pk]
    local isNew = type(row) ~= "table"
    if isNew then
        row = { uid = plantUid, samples = 0, qtySum = 0 }
        products[pk] = row
    end
    row.samples = (tonumber(row.samples) or 0) + 1
    row.qtySum = (tonumber(row.qtySum) or 0) + (tonumber(qty) or 1)
    local plantReq = 0
    if type(plantData) == "table" then
        plantReq = tonumber(plantData.craftingSkillRequirement) or tonumber(plantData.skillReq) or 0
    end
    if plantReq <= 0 and StockPiler.Items and StockPiler.Items.GetByUid then
        local learned = StockPiler.Items.GetByUid(plantUid)
        if type(learned) == "table" then
            plantReq = tonumber(learned.skillReq) or tonumber(learned.skillLevel)
                or tonumber(learned.craftingSkillRequirement) or 0
        end
    end
    if plantReq > 0 then
        row.skillReq = plantReq
    end
    -- Stamp plant EFFECT from seed (harvest + refine share this path).
    local stampedFx = StampPlantEffectFromSeedLink(seedUid, plantUid, plantData)
    if stampedFx > 0 then
        row.effectId = stampedFx
    end
    -- Infertile / special apo harvest products are never plant->seed refinable.
    local ME = StockPiler.MaterialExceptions
    local markSpecial = SM.IsInfertileSeed(seedUid, seedData and seedData.name)
        or (ME and ME.LooksSpecialApoMain and type(plantData) == "table" and ME.LooksSpecialApoMain(plantData))
    if markSpecial and ME and ME.MarkForceNotRefinable then
        local reason = SM.IsInfertileSeed(seedUid) and "infertile-harvest" or "special-harvest"
        ME.MarkForceNotRefinable(plantUid, reason)
    end
    if markSpecial and StockPiler.Items and StockPiler.Items.StoreItem and type(plantData) == "table" then
        plantData.isRefinable = false
        StockPiler.Items.StoreItem(plantData, "plant")
    end
    return true, isNew
end

----------------------------------------------------------------
-- Public: seed tiers / packets / relatedness
----------------------------------------------------------------

function SM.IsSeedPacketUid(uid)
    return IsSeedPacketItem(BagSample(uid))
end

function SM.IsBagSeedOrSpore(itemOrSpec)
    if type(itemOrSpec) ~= "table" then
        return false
    end
    if itemOrSpec.uniqueID or itemOrSpec.name then
        return IsBagSeedOrSporeItem(itemOrSpec)
    end
    local uid = tonumber(itemOrSpec.uid) or 0
    return IsBagSeedOrSporeItem(BagSample(uid))
end

function SM.SeedReplantTier(seedUid, nameHint)
    return SeedReplantTier(seedUid, nameHint)
end

function SM.IsEternalSeed(seedUid, nameHint)
    return SeedReplantTier(seedUid, nameHint) >= 3
end

function SM.IsExceptionalSeed(seedUid, nameHint)
    return SeedReplantTier(seedUid, nameHint) == 2
end

function SM.IsOpaqueReplantSeed(seedUid, nameHint)
    return SeedReplantTier(seedUid, nameHint) >= 2
end

--- One-shot hybrid seeds (infertile) - never Eternal/Exceptional opaque credit.
function SM.IsInfertileSeed(seedUid, nameHint)
    seedUid = tonumber(seedUid) or 0
    if seedUid > 0 and INFERTILE_SEED_UID[seedUid] then
        return true
    end
    local data = (seedUid > 0) and BagSample(seedUid) or nil
    local n = string.lower(ToNarrow(nameHint))
    if n == "" then
        n = string.lower(ToNarrow(data and data.name))
    end
    local desc = LookupDescription(data or { uid = seedUid, name = nameHint })
    if DescLooksInfertileSeed(desc) then
        return true
    end
    if string.find(n, "infertile", 1, true) then
        return true
    end
    return false
end

--- Eternal: full plot wave while owned; Exceptional: same while charges remain (~250).
--- Also covers the configured seed-buffer floor: with buffer=5 and 4 plots, returning
--- only `plots` left Eternal owners permanently stuck on Seed buffer (credit 4 < 5).
function SM.EffectiveSeedCredit(seedUid, bagCount)
    bagCount = tonumber(bagCount) or 0
    if bagCount <= 0 then
        return 0
    end
    if not SM.IsOpaqueReplantSeed(seedUid) then
        return bagCount
    end
    local plots = 4
    local CA = StockPiler.CultivatorAdapter
    if CA and CA.NumPlots then
        plots = tonumber(CA.NumPlots()) or 4
    end
    if plots < 1 then
        plots = 4
    end
    local buffer = 5
    local Watch = StockPiler.Watch
    if Watch and Watch.GetSeedBufferMin then
        buffer = tonumber(Watch.GetSeedBufferMin()) or 5
    end
    if buffer < 1 then
        buffer = 1
    end
    -- Owned opaque seed = infinite replant capacity for cushion math.
    return math.max(plots, buffer, bagCount)
end

function SM.GetSeedUidsForPlant(plantUid)
    plantUid = tonumber(plantUid) or 0
    local out = {}
    if plantUid <= 0 then
        return out
    end
    local seen = {}
    local function addSeed(seedUid)
        seedUid = tonumber(seedUid) or 0
        if seedUid > 0 and not seen[seedUid] and not SM.IsSeedPacketUid(seedUid) then
            seen[seedUid] = true
            out[#out + 1] = seedUid
        end
    end
    local grows = GrowsTable()
    if type(grows) == "table" then
        for seedKey, bucket in pairs(grows) do
            if type(bucket) == "table" and type(bucket.products) == "table" then
                local prod = bucket.products[tostring(plantUid)]
                if type(prod) == "table" then
                    addSeed(tonumber(seedKey) or tonumber(bucket.seedUid) or 0)
                end
            end
        end
    end
    local entry = RefinesTable() and RefinesTable()[tostring(plantUid)]
    if type(entry) == "table" then
        addSeed(entry.seedUid)
        -- Crit harvest plants often refine back to the lower planted seed; also keep
        -- every observed seedOut so same-tier seeds (e.g. 3010035 vs 3010034) compete.
        if type(entry.seedOut) == "table" then
            for seedKey, _ in pairs(entry.seedOut) do
                addSeed(seedKey)
            end
        end
    end
    return out
end

function SM.HarvestProducts(seedUid)
    seedUid = tonumber(seedUid) or 0
    local list = {}
    if seedUid <= 0 then
        return list
    end
    local bucket = GrowsTable() and GrowsTable()[tostring(seedUid)]
    if type(bucket) ~= "table" or type(bucket.products) ~= "table" then
        return list
    end
    for _, row in pairs(bucket.products) do
        if type(row) == "table" and (tonumber(row.uid) or 0) > 0 then
            list[#list + 1] = {
                uid = tonumber(row.uid),
                samples = tonumber(row.samples) or 0,
            }
        end
    end
    table.sort(list, function(a, b)
        return (a.samples or 0) > (b.samples or 0)
    end)
    return list
end

--- Cultivation linkage wins; PrimaryPlant never returns unrelated products.
--- Prefers same-skillReq plant over crit-upgraded higher plants (more samples).
function SM.PrimaryPlantForSeed(seedUid)
    seedUid = tonumber(seedUid) or 0
    local products = SM.HarvestProducts(seedUid)
    if #products == 0 then
        return 0
    end
    local seedData = BagSample(seedUid)
    if type(seedData) ~= "table" and StockPiler.Items and StockPiler.Items.GetByUid then
        seedData = StockPiler.Items.GetByUid(seedUid)
    end
    local function dataSkillReq(data)
        if type(data) ~= "table" then
            return 0
        end
        local req = tonumber(data.craftingSkillRequirement) or tonumber(data.skillReq) or 0
        if req <= 0 and type(data.bonuses) == "table" then
            req = tonumber(data.bonuses[9]) or 0
        end
        return req
    end
    local function dataName(data, uid)
        if type(data) == "table" and data.name then
            return data.name
        end
        if uid and uid > 0 and StockPiler.Items and StockPiler.Items.GetByUid then
            local row = StockPiler.Items.GetByUid(uid)
            return row and row.name
        end
        return nil
    end
    local seedReq = dataSkillReq(seedData)
    local seedName = dataName(seedData, seedUid)
    local bestUid, bestScore = 0, -1
    for i = 1, #products do
        local plantUid = tonumber(products[i].uid) or 0
        if plantUid > 0 then
            local plantData = BagSample(plantUid)
            if type(plantData) ~= "table" and StockPiler.Items and StockPiler.Items.GetByUid then
                plantData = StockPiler.Items.GetByUid(plantUid)
            end
            local plantName = dataName(plantData, plantUid)
            local plantReq = dataSkillReq(plantData)
            local related = false
            if seedName and plantName then
                related = GrowNamesRelated(plantName, seedName)
            elseif seedReq > 0 and plantReq == seedReq then
                -- Names unavailable but skill matches harvest product - accept.
                related = true
            elseif #products == 1 then
                -- Sole harvest product for this seed.
                related = true
            end
            if related and not (type(plantData) == "table"
                and LooksButcher(ToNarrow(plantData.name))
                and not (seedName and GrowNamesRelated(plantData.name, seedName)))
            then
                local samples = tonumber(products[i].samples) or 0
                local score = samples
                if seedReq > 0 and plantReq == seedReq then
                    score = score + 100000
                elseif seedReq > 0 and plantReq > seedReq then
                    score = score - 1000
                end
                if score > bestScore then
                    bestScore = score
                    bestUid = plantUid
                end
            end
        end
    end
    return bestUid
end

--- Prefer Eternal >> Exceptional >> blue; exclude Seed Packets.
--- When plant/spec skillReq is known, prefer matching seed skillReq over bag
--- ownership (owned L1 must not beat missing L200 for a L200 plant).
function SM.PickBestSeedUid(plantUid, seedUids, spec)
    plantUid = tonumber(plantUid) or 0
    local plantReq = 0
    if type(spec) == "table" then
        plantReq = tonumber(spec.skillLevel) or tonumber(spec.craftingSkillRequirement)
            or tonumber(spec.skillReq) or 0
    end
    if plantReq <= 0 and plantUid > 0 then
        local plantData = BagSample(plantUid)
        if type(plantData) == "table" then
            plantReq = tonumber(plantData.craftingSkillRequirement) or tonumber(plantData.skillReq) or 0
            if plantReq <= 0 and type(plantData.bonuses) == "table" then
                plantReq = tonumber(plantData.bonuses[9]) or 0
            end
        end
        if plantReq <= 0 and StockPiler.Items and StockPiler.Items.ToSpec then
            local pSpec = StockPiler.Items.ToSpec(plantUid)
            plantReq = tonumber(pSpec and pSpec.skillLevel) or 0
        end
    end

    local function seedSkillReq(uid, item)
        local req = 0
        if type(item) == "table" then
            req = tonumber(item.craftingSkillRequirement) or tonumber(item.skillReq)
                or tonumber(item.skillLevel) or 0
            if req <= 0 and type(item.bonuses) == "table" then
                req = tonumber(item.bonuses[9]) or 0
            end
        end
        if req <= 0 and StockPiler.Items and StockPiler.Items.GetByUid then
            local row = StockPiler.Items.GetByUid(uid)
            if type(row) == "table" then
                req = tonumber(row.craftingSkillRequirement) or tonumber(row.skillReq)
                    or tonumber(row.skillLevel) or 0
                if req <= 0 and type(row.bonuses) == "table" then
                    req = tonumber(row.bonuses[9]) or 0
                end
            end
        end
        return req
    end

    local candidates = {}
    local seen = {}
    local function addUid(uid)
        uid = tonumber(uid) or 0
        if uid <= 0 or seen[uid] or SM.IsSeedPacketUid(uid) then
            return
        end
        local item = BagSample(uid)
        if not IsBagSeedOrSporeItem(item) then
            return
        end
        if plantUid > 0 then
            local plantData = BagSample(plantUid)
            if type(plantData) == "table" and type(item) == "table" then
                if not GrowNamesRelated(plantData.name, item.name) then
                    return
                end
            end
        end
        seen[uid] = true
        candidates[#candidates + 1] = uid
    end

    if type(seedUids) == "table" then
        for i = 1, #seedUids do
            addUid(seedUids[i])
        end
    end
    if plantUid > 0 then
        local mapped = SM.GetSeedUidsForPlant(plantUid)
        for i = 1, #mapped do
            addUid(mapped[i])
        end
        -- Prefer the skill-matched plant->seed link as an explicit candidate.
        if SM.ResolveSeedUidForPlant then
            addUid(SM.ResolveSeedUidForPlant(plantUid, spec))
        end
    end
    if StockPiler.Inventory and StockPiler.Inventory.ForEachItem then
        StockPiler.Inventory.ForEachItem(function(item)
            if IsBagSeedOrSporeItem(item) then
                addUid(item.uniqueID)
            end
        end)
    end

    local hasExactSkill = false
    if plantReq > 0 then
        for i = 1, #candidates do
            local item = BagSample(candidates[i])
            if seedSkillReq(candidates[i], item) == plantReq then
                hasExactSkill = true
                break
            end
        end
    end

    -- Prefer seeds actually in bags among skill-appropriate candidates.
    -- ownedBoost must stay below skill-match so missing L200 beats owned L1.
    local bestUid, bestScore = 0, -1
    for i = 1, #candidates do
        local uid = candidates[i]
        local item = BagSample(uid)
        local sReq = seedSkillReq(uid, item)
        if hasExactSkill and plantReq > 0 and sReq > 0 and sReq < plantReq then
            -- Drop lower-tier seeds when the exact plant tier exists as a candidate.
        else
            local count = 0
            if StockPiler.Inventory and StockPiler.Inventory.CountByUid then
                count = tonumber(StockPiler.Inventory.CountByUid(uid)) or 0
            end
            local skillScore = 0
            if plantReq > 0 then
                if sReq == plantReq then
                    skillScore = 10000000
                elseif sReq > plantReq then
                    skillScore = 100000
                elseif sReq > 0 and sReq < plantReq then
                    skillScore = -5000000
                end
            end
            local ownedBoost = count > 0 and 100000 or 0
            local score = skillScore + ownedBoost + (SeedReplantTier(uid) * 1000) + count
            if score > bestScore then
                bestScore = score
                bestUid = uid
            end
        end
    end
    return bestUid
end

--- Seed UID for buffer / refine / Apo plant-hold math.
--- Prefer the seed this plant refines into, then same skillReq as the plant.
--- Do NOT use PickBestSeedUid alone: that prefers Eternal L1 in bags and lets
--- Apo burn a rare higher-tier plant while counting L1 seeds as "buffer OK".
function SM.ResolveSeedUidForPlant(plantUid, plantSpec)
    plantUid = tonumber(plantUid) or 0
    if plantUid <= 0 then
        return 0
    end
    local snap = 0
    local InvSnap = StockPiler.Inventory
    if InvSnap and InvSnap.GetSnapGen then
        snap = tonumber(InvSnap.GetSnapGen()) or 0
    end
    if (tonumber(SM._resolveSeedSnap) or -1) ~= snap then
        SM._resolveSeedByPlant = {}
        SM._resolveSeedSnap = snap
    end
    local cache = SM._resolveSeedByPlant
    if type(cache) ~= "table" then
        cache = {}
        SM._resolveSeedByPlant = cache
    end
    local hit = cache[plantUid]
    if hit ~= nil then
        return hit
    end
    local function remember(uid)
        uid = tonumber(uid) or 0
        cache[plantUid] = uid
        return uid
    end
    local plantReq = 0
    if type(plantSpec) == "table" then
        plantReq = tonumber(plantSpec.skillLevel) or tonumber(plantSpec.craftingSkillRequirement) or 0
    end
    if plantReq <= 0 then
        local plantData = BagSample(plantUid)
        if type(plantData) == "table" then
            plantReq = tonumber(plantData.craftingSkillRequirement) or tonumber(plantData.skillReq) or 0
            if plantReq <= 0 and type(plantData.bonuses) == "table" then
                plantReq = tonumber(plantData.bonuses[9]) or 0
            end
        end
    end
    if plantReq <= 0 and StockPiler.Items and StockPiler.Items.ToSpec then
        local spec = StockPiler.Items.ToSpec(plantUid)
        plantReq = tonumber(spec and spec.skillLevel) or 0
    end

    local function seedSkillReq(uid)
        uid = tonumber(uid) or 0
        if uid <= 0 then
            return 0
        end
        local item = BagSample(uid)
        if type(item) == "table" then
            local req = tonumber(item.craftingSkillRequirement) or tonumber(item.skillReq) or 0
            if req <= 0 and type(item.bonuses) == "table" then
                req = tonumber(item.bonuses[9]) or 0
            end
            if req > 0 then
                return req
            end
        end
        if StockPiler.Items and StockPiler.Items.GetByUid then
            local row = StockPiler.Items.GetByUid(uid)
            if type(row) == "table" then
                local req = tonumber(row.craftingSkillRequirement) or tonumber(row.skillReq) or 0
                if req <= 0 and type(row.bonuses) == "table" then
                    req = tonumber(row.bonuses[9]) or 0
                end
                return req
            end
        end
        return 0
    end

    local plantData = BagSample(plantUid)
    local plantName = plantData and plantData.name
    if (not plantName or plantName == "") and StockPiler.Items and StockPiler.Items.GetByUid then
        local row = StockPiler.Items.GetByUid(plantUid)
        plantName = row and row.name
    end

    local function seedName(uid)
        local item = BagSample(uid)
        if type(item) == "table" and item.name then
            return item.name
        end
        if StockPiler.Items and StockPiler.Items.GetByUid then
            local row = StockPiler.Items.GetByUid(uid)
            return row and row.name
        end
        return nil
    end

    -- Score candidates: exact normalized name >> skillReq match >> genus-related.
    -- Never return a genus-only / lower-seed guess (Wolfpaw Fusk must not resolve
    -- to Dusty L1 spore just because both are "fusk").
    local function scoreSeed(uid, isRefinePrimary)
        uid = tonumber(uid) or 0
        if uid <= 0 or SM.IsSeedPacketUid(uid) then
            return -1
        end
        local score = 0
        local sReq = seedSkillReq(uid)
        local sName = seedName(uid)
        if plantName and sName then
            local a = NormalizeGrowName(ToNarrow(plantName))
            local b = NormalizeGrowName(ToNarrow(sName))
            if a ~= "" and a == b then
                score = score + 100000
            elseif GrowNamesRelated(plantName, sName) then
                score = score + 1000
            else
                return -1
            end
        end
        if plantReq > 0 and sReq == plantReq then
            score = score + 10000
        elseif plantReq > 0 and sReq > 0 and sReq < plantReq then
            -- Lower seed that crit into this plant (refine often returns it).
            -- Must lose to same-skillReq even when both share an exact grow name
            -- (seen: L175 plant resolved to L150 seed → Apo brew reserve=0 while
            -- the true L175 seed buffer was still short).
            score = score - 150000
        end
        if isRefinePrimary then
            score = score + 10
        end
        if sReq > 0 then
            score = score + math.min(sReq, 200)
        end
        return score
    end

    local linked = SM.GetSeedUidsForPlant(plantUid) or {}
    local entry = RefinesTable() and RefinesTable()[tostring(plantUid)]
    local refineSeed = type(entry) == "table" and (tonumber(entry.seedUid) or 0) or 0

    local bestUid, bestScore = 0, -1
    local function consider(uid, isPrimary)
        local sc = scoreSeed(uid, isPrimary == true)
        if sc > bestScore then
            bestScore = sc
            bestUid = tonumber(uid) or 0
        end
    end
    for i = 1, #linked do
        consider(linked[i], (tonumber(linked[i]) or 0) == refineSeed)
    end
    consider(refineSeed, true)

    -- Bag / account same-genus seed at plant skill (covers missing grow link).
    -- Also scan when plantReq is unknown but plantName is known (exact name match),
    -- otherwise Wolfpaw Fusk plant with no bag sample never finds Wolfpaw Fusk Spore.
    -- Exact-name *lower*-tier seeds used to score 100000+ and skip this scan, so a
    -- crit-tier plant kept resolving to the planted L150 seed while the true
    -- same-skillReq seed sat buffer-short (or only in grows/account).
    local bestMatchesSkill = plantReq > 0 and bestUid > 0 and seedSkillReq(bestUid) == plantReq
    if (not bestMatchesSkill) and (plantReq > 0 or (plantName and plantName ~= "" and bestScore < 100000)) then
        local plantGenus = SM.GenusKeyFromName(plantName)
        local function considerItem(item)
            if type(item) ~= "table" then
                return
            end
            if not IsBagSeedOrSporeItem(item) then
                return
            end
            local uid = tonumber(item.uniqueID) or tonumber(item.uid) or 0
            if uid <= 0 or SM.IsSeedPacketUid(uid) then
                return
            end
            if plantGenus ~= "" and SM.GenusKeyFromName(item.name) ~= plantGenus then
                return
            end
            local req = tonumber(item.craftingSkillRequirement) or tonumber(item.skillReq)
                or tonumber(item.skillLevel) or 0
            if req <= 0 and type(item.bonuses) == "table" then
                req = tonumber(item.bonuses[9]) or 0
            end
            if req <= 0 then
                req = ItemSkillReq(item)
            end
            local exact = plantName and item.name
                and NormalizeGrowName(ToNarrow(plantName)) == NormalizeGrowName(ToNarrow(item.name))
            if (plantReq > 0 and req == plantReq) or exact == true then
                consider(uid, false)
            end
        end
        local Inv = StockPiler.Inventory
        if Inv and Inv.ForEachItem then
            Inv.ForEachItem(considerItem)
        end
        local items = StockPiler.Account and StockPiler.Account.items
        if type(items) == "table" then
            for key, row in pairs(items) do
                if type(row) == "table" then
                    if row.uniqueID == nil and tonumber(key) then
                        row = {
                            uniqueID = tonumber(key),
                            name = row.name,
                            craftingSkillRequirement = row.craftingSkillRequirement
                                or row.skillReq or row.skillLevel,
                            cultivationType = row.cultivationType,
                            bonuses = row.bonuses,
                        }
                    end
                    considerItem(row)
                end
            end
        end
    end

    if bestUid > 0 and bestScore >= 10000 then
        -- Exact name (100000+) or same skillReq (10000+). Reject genus-only guesses.
        -- Still reject known lower-tier seeds when plant skill is higher.
        if plantReq > 0 then
            local bReq = seedSkillReq(bestUid)
            if bReq > 0 and bReq < plantReq then
                bestUid = 0
                bestScore = -1
            else
                return remember(bestUid)
            end
        else
            return remember(bestUid)
        end
    end
    -- Prefer any grow/refine-linked seed at the plant's skillReq before falling
    -- back to a lower planted seed (crit refine often returns L150 for an L175 plant).
    -- Grow-linked seeds with unknown skillReq still count (84043 may lack Items
    -- sample after the last seed was planted) — never pick known-lower seeds.
    if plantReq > 0 then
        local bestSame, bestSameScore = 0, -1
        local bestUnknown = 0
        local function considerSame(uid)
            uid = tonumber(uid) or 0
            if uid <= 0 or SM.IsSeedPacketUid(uid) then
                return
            end
            local sReq = seedSkillReq(uid)
            if sReq == plantReq then
                local sc = scoreSeed(uid, false)
                if sc > bestSameScore then
                    bestSameScore = sc
                    bestSame = uid
                elseif sc < 0 and bestSame <= 0 then
                    bestSame = uid
                    bestSameScore = 0
                end
            elseif sReq <= 0 and bestUnknown <= 0 then
                bestUnknown = uid
            end
        end
        for i = 1, #linked do
            considerSame(linked[i])
        end
        considerSame(refineSeed)
        if bestSame > 0 then
            return remember(bestSame)
        end
        if bestUnknown > 0 then
            return remember(bestUnknown)
        end
    end
    -- Explicit refine/grow link wins when the seed is not in bags (score cannot
    -- verify name/skill). Without this, GrowReserve still falls back to
    -- GetSeedUidsForPlant[1] while CollectAutoGrowSeedLines leaves seedUid=0 —
    -- brew craftable=0 with no seed-buffer plant job (Rejuvenating/Fusk stall).
    -- Never return a known lower-tier seed for a higher plant (buffer math would
    -- use the met lower buffer and brew away scarce same-tier feedstock).
    if refineSeed > 0 then
        local rReq = seedSkillReq(refineSeed)
        if plantReq <= 0 or rReq <= 0 or rReq >= plantReq then
            return remember(refineSeed)
        end
    end
    if type(linked) == "table" then
        for i = 1, #linked do
            local cand = tonumber(linked[i]) or 0
            if cand > 0 then
                local cReq = seedSkillReq(cand)
                if plantReq <= 0 or cReq <= 0 or cReq >= plantReq then
                    return remember(cand)
                end
            end
        end
    end
    -- Do not fall back to PickBestSeedUid (prefers Eternal/L1 in bags).
    return remember(0)
end

function SM.IsOneWayHarvestSpec(spec)
    if type(spec) ~= "table" then
        return false
    end
    if StockPiler.RecipeSpec and StockPiler.RecipeSpec.IsLinimentClass
        and StockPiler.RecipeSpec.IsLinimentClass(spec)
    then
        return true
    end
    local ME = StockPiler.MaterialExceptions
    if ME and ME.LooksSpecialApoMain and ME.LooksSpecialApoMain(spec) == true then
        return true
    end
    local name = spec.name
    local uid = tonumber(spec.uid) or tonumber(spec.uniqueID) or 0
    if (not name or name == "") and uid > 0 then
        local row = StockPiler.Items and StockPiler.Items.GetByUid and StockPiler.Items.GetByUid(uid)
        name = row and row.name
    end
    local n = string.lower(ToNarrow(name))
    if string.find(n, "powder", 1, true) or string.find(n, "extract", 1, true)
        or string.find(n, "liniment", 1, true)
    then
        return true
    end
    if uid > 0 then
        local row = StockPiler.Items and StockPiler.Items.GetByUid and StockPiler.Items.GetByUid(uid)
        if type(row) == "table" and row.isRefinable == false then
            local seeds = SM.GetSeedUidsForPlant(uid)
            -- Linked to grow but not refinable -> one-way.
            if type(seeds) == "table" and #seeds > 0 then
                return true
            end
            -- Also: seed primary plant is this uid with no refine entry.
            local grows = GrowsTable()
            if type(grows) == "table" then
                for _, bucket in pairs(grows) do
                    if type(bucket) == "table" and type(bucket.products) == "table"
                        and type(bucket.products[tostring(uid)]) == "table"
                    then
                        local entry = RefinesTable() and RefinesTable()[tostring(uid)]
                        if type(entry) ~= "table" or (tonumber(entry.seedUid) or 0) <= 0 then
                            return true
                        end
                    end
                end
            end
        end
    end
    return false
end

--- True/false when known from spec or learned item; nil when never observed.
--- MaterialExceptions can force false when the engine lies (Squig Bits, etc.).
function SM.ResolveIsRefinable(spec)
    if type(spec) ~= "table" then
        return nil
    end
    local ME = StockPiler.MaterialExceptions
    if ME and ME.IsForceNotRefinable and ME.IsForceNotRefinable(spec) == true then
        return false
    end
    if spec.isRefinable ~= nil then
        return spec.isRefinable == true
    end
    local uid = tonumber(spec.uid) or tonumber(spec.uniqueID) or tonumber(spec.boundUid) or 0
    if uid <= 0 then
        return nil
    end
    if ME and ME.IsForceNotRefinable and ME.IsForceNotRefinable(uid) == true then
        return false
    end
    if StockPiler.Items and StockPiler.Items.GetByUid then
        local learned = StockPiler.Items.GetByUid(uid)
        if type(learned) == "table" then
            if ME and ME.IsForceNotRefinable and ME.IsForceNotRefinable(learned) == true then
                return false
            end
            if learned.isRefinable ~= nil then
                return learned.isRefinable == true
            end
        end
    end
    return nil
end

--- Byproduct stabilizer (Arboreal Resin etc.) - not planted / not butcher mains.
function SM.IsHarvestByproduct(spec)
    if type(spec) ~= "table" then
        return false
    end
    local role = tostring(spec.role or "")
    -- Recipe mains (armor chitin, scales, etc.) are never cultivation convert byproducts.
    if role == "main" or role == "container" then
        return false
    end
    local uid = tonumber(spec.uid) or tonumber(spec.uniqueID) or tonumber(spec.boundUid) or 0
    local learned = nil
    if uid > 0 and StockPiler.Items and StockPiler.Items.GetByUid then
        learned = StockPiler.Items.GetByUid(uid)
    end
    if type(learned) == "table" and tostring(learned.kind or "") == "resin" then
        return true
    end
    local n = string.lower(ToNarrow(spec.name))
    if n == "" and type(learned) == "table" then
        n = string.lower(ToNarrow(learned.name))
    end
    -- Resin / Arboreal only - do not treat chitin/scales or isRefinable==false as byproduct.
    if string.find(n, "resin", 1, true) or string.find(n, "arboreal", 1, true) then
        return true
    end
    return false
end

local function SpecLinkedToGrowOrRefine(spec)
    local uid = tonumber(spec.uid) or tonumber(spec.uniqueID) or tonumber(spec.boundUid) or 0
    if uid <= 0 then
        return false
    end
    local seeds = SM.GetSeedUidsForPlant(uid)
    if type(seeds) == "table" and #seeds > 0 then
        return true
    end
    local entry = RefinesTable() and RefinesTable()[tostring(uid)]
    if type(entry) == "table" and (tonumber(entry.seedUid) or 0) > 0 then
        return true
    end
    local grows = GrowsTable()
    if type(grows) == "table" then
        for _, bucket in pairs(grows) do
            if type(bucket) == "table" and type(bucket.products) == "table"
                and type(bucket.products[tostring(uid)]) == "table"
            then
                return true
            end
        end
    end
    return false
end

local function SpecLooksButchering(spec)
    local n = string.lower(ToNarrow(spec and spec.name))
    if n == "" then
        local uid = tonumber(spec and spec.uid) or tonumber(spec and spec.uniqueID)
            or tonumber(spec and spec.boundUid) or 0
        if uid > 0 and StockPiler.Items and StockPiler.Items.GetByUid then
            local row = StockPiler.Items.GetByUid(uid)
            n = string.lower(ToNarrow(row and row.name))
        end
    end
    if n ~= "" and LooksButcher(n) then
        return true
    end
    -- Fingerprint-only mains (no name/uid): any learned isRefinable==false twin.
    local MS = StockPiler.MaterialSpec
    local items = StockPiler.Account and StockPiler.Account.items
    if type(spec) ~= "table" or type(items) ~= "table" or not (MS and MS.ProductMatches) then
        return false
    end
    for uidKey, row in pairs(items) do
        if type(row) == "table" and row.isRefinable == false then
            local rowUid = tonumber(row.uniqueID) or tonumber(uidKey) or 0
            local probe = row
            if rowUid > 0 and StockPiler.Items and StockPiler.Items.AsItemData then
                probe = StockPiler.Items.AsItemData(rowUid) or row
            end
            -- isRefinable==false + ProductMatch: butcher/vendor twin (scales, spittle, …).
            if MS.ProductMatches(probe, spec) == true then
                return true
            end
        end
    end
    return false
end

--- Goldweed-class stabilizer fingerprint: MULTIPLIER bonus present (SP2 SpecHasGoldweedMultiplier).
function SM.SpecHasGoldweedMultiplier(spec)
    if type(spec) ~= "table" or type(spec.bonuses) ~= "table" then
        return false
    end
    local B = StockPiler.MaterialSpec and StockPiler.MaterialSpec.CraftBonusRefs
        and StockPiler.MaterialSpec.CraftBonusRefs()
    local ref = (B and B.MULTIPLIER) or 4
    local val = tonumber(spec.bonuses[ref]) or tonumber(spec.bonuses[tostring(ref)])
    return val ~= nil and val ~= 0
end

local function IsGrowProducerItem(itemData)
    if type(itemData) ~= "table" then
        return false
    end
    if IsBagSeedOrSporeItem(itemData) or IsSeedPacketItem(itemData) then
        return false
    end
    local n = string.lower(ToNarrow(itemData.name))
    if string.find(n, "resin", 1, true) or string.find(n, "arboreal", 1, true) then
        return false
    end
    if LooksButcher(n) and not string.find(n, "goldweed", 1, true)
        and not string.find(n, "gobswort", 1, true)
    then
        return false
    end
    return true
end

local function SpecProductCacheKey(spec)
    local MS = StockPiler.MaterialSpec
    if not MS then
        return ""
    end
    if MS.ProductKey then
        local k = tostring(MS.ProductKey(spec) or "")
        if k ~= "" then
            return k
        end
    end
    if MS.Key then
        return tostring(MS.Key(spec) or "")
    end
    return ""
end

local _growableCache = {}
local _growableCacheGen = nil

local function PlantUidCacheGen()
    local snap = 0
    if StockPiler.Inventory and StockPiler.Inventory.GetSnapGen then
        snap = tonumber(StockPiler.Inventory.GetSnapGen()) or 0
    end
    local know = 0
    if StockPiler.Knowledge and StockPiler.Knowledge.GetGen then
        know = tonumber(StockPiler.Knowledge.GetGen()) or 0
    end
    return tostring(snap) .. ":" .. tostring(know)
end

--- Cultivation main/extender/stimulant/goldweed growable; resin byproducts not.
--- Cultivation linkage (grows/refines) wins over butcher ProductMatches.
--- Explicit isRefinable==false blocks optimistic cult-role -> plant (chitin/scales/etc.).
local function IsGrowableSpecUncached(spec)
    if type(spec) ~= "table" then
        return false
    end
    local role = tostring(spec.role or "")
    if role == "container" then
        return false
    end
    if SM.IsHarvestByproduct(spec) then
        return false
    end
    if SpecLinkedToGrowOrRefine(spec) then
        return true
    end
    if SpecLooksButchering(spec) then
        return false
    end
    -- Unlinked hybrid/liniment specials: growable only when a related seed resolves
    -- (Eternal / infertile / Bloodseed). Dungeon drops (Primal / Daemonic) stay non-growable.
    local ME = StockPiler.MaterialExceptions
    if ME and ME.LooksSpecialApoMain and ME.LooksSpecialApoMain(spec) == true then
        local seed = SM.ResolveSeedForSpec and SM.ResolveSeedForSpec(spec)
        local seedUid = type(seed) == "table"
            and (tonumber(seed.uniqueID) or tonumber(seed.uid) or 0) or 0
        return seedUid > 0
    end
    local refinable = SM.ResolveIsRefinable(spec)
    if refinable == false then
        return false
    end
    if refinable == true then
        return true
    end
    -- Fingerprint specs often omit uid/isRefinable; resolve via plant twin.
    -- Bottled Rat Spittle / scales match as "plants" until LooksButcher runs —
    -- their learned isRefinable==false must win over the cult-role heuristic.
    local plantUid = SM.FindPlantUidForSpec and tonumber(SM.FindPlantUidForSpec(spec)) or 0
    if plantUid > 0 then
        local plantRef = SM.ResolveIsRefinable({
            uid = plantUid,
            uniqueID = plantUid,
            role = role,
        })
        if plantRef == false then
            return false
        end
        if plantRef == true then
            return true
        end
    end
    -- Unknown isRefinable: cult-role heuristic so unlearned fingerprints still AutoGrow.
    if role == "main" or role == "extender" or role == "multiplier"
        or role == "stimulant" or role == "goldweed"
    then
        return true
    end
    if role == "stabilizer" then
        -- Goldweed-class stabilizers are planted; resin handled above.
        if SM.SpecHasGoldweedMultiplier(spec) then
            return true
        end
        local n = string.lower(ToNarrow(spec.name))
        if string.find(n, "goldweed", 1, true) or string.find(n, "gobswort", 1, true) then
            return true
        end
    end
    return false
end

--- Memo per uid and role for the bag snapshot and knowledge generation.
--- The answer depends on role (and the stabilizer/goldweed name check), so one
--- uid can be growable as a main and not as a stabilizer in the same snapshot.
--- BrewAvailableForSpec asks this for every seedless slot; butcher fingerprints
--- otherwise scan Account.items.
function SM.IsGrowableSpec(spec)
    if type(spec) ~= "table" then
        return false
    end
    local gen = PlantUidCacheGen()
    if gen ~= _growableCacheGen then
        _growableCache = {}
        _growableCacheGen = gen
    end
    local uid = tonumber(spec.uid) or tonumber(spec.uniqueID) or tonumber(spec.boundUid) or 0
    local role = tostring(spec.role or "")
    local cacheKey = tostring(uid) .. ":" .. role
    if uid > 0 and _growableCache[cacheKey] ~= nil then
        return _growableCache[cacheKey] == true
    end
    local growable = IsGrowableSpecUncached(spec) == true
    if uid > 0 then
        _growableCache[cacheKey] = growable
    end
    return growable
end

--- Resolve plant uid for fingerprint specs (no bound uid) via ProductMatches.
function SM.FindPlantUidForSpec(spec)
    if type(spec) ~= "table" then
        return 0
    end
    -- Resin / byproduct mats are never cultivable plants (even with bound uid).
    if SM.IsHarvestByproduct(spec) then
        return 0
    end
    -- Apo containers (vials/flasks) bind a uid but are never plants to refine/grow.
    if tostring(spec.role or "") == "container" then
        return 0
    end
    local uid = tonumber(spec.uid) or tonumber(spec.uniqueID) or tonumber(spec.boundUid) or 0
    if uid > 0 then
        return uid
    end
    local MS = StockPiler.MaterialSpec
    if not (MS and MS.ProductMatches) then
        return 0
    end
    local cacheKey = SpecProductCacheKey(spec)
    local gen = PlantUidCacheGen()
    if SM._plantUidCacheSnap ~= gen then
        SM._plantUidCache = {}
        SM._plantUidCacheSnap = gen
    end
    if cacheKey ~= "" and SM._plantUidCache[cacheKey] ~= nil then
        return tonumber(SM._plantUidCache[cacheKey]) or 0
    end

    local bestUid = 0
    local function considerItem(itemData, considerUid)
        considerUid = tonumber(considerUid) or 0
        if considerUid <= 0 or not IsGrowProducerItem(itemData) then
            return
        end
        if MS.ProductMatches(itemData, spec) == true then
            bestUid = considerUid
        end
    end

    -- 1) Live bags
    local Inv = StockPiler.Inventory
    if Inv and Inv.ForEachItem then
        Inv.ForEachItem(function(item)
            if type(item) == "table" and bestUid <= 0 then
                considerItem(item, item.uniqueID or item.uniqueId or item.uid)
            end
        end)
    end

    -- 2) Learned Items store
    if bestUid <= 0 then
        local items = nil
        if StockPiler.Account and type(StockPiler.Account.items) == "table" then
            items = StockPiler.Account.items
        elseif StockPiler.Knowledge and StockPiler.Knowledge.Items then
            items = StockPiler.Knowledge.Items()
        end
        if type(items) == "table" then
            for uidKey, row in pairs(items) do
                if bestUid > 0 then
                    break
                end
                if type(row) == "table" then
                    local kind = tostring(row.kind or "")
                    if kind ~= "seed" and kind ~= "spore" and kind ~= "resin" then
                        local rowUid = tonumber(row.uniqueID) or tonumber(uidKey) or 0
                        local asItem = nil
                        if StockPiler.Items and StockPiler.Items.AsItemData then
                            asItem = StockPiler.Items.AsItemData(rowUid)
                        end
                        considerItem(asItem or row, rowUid)
                    end
                end
            end
        end
    end

    -- 3) Grows product tables
    if bestUid <= 0 then
        local grows = GrowsTable()
        if type(grows) == "table" then
            for _, bucket in pairs(grows) do
                if bestUid > 0 then
                    break
                end
                if type(bucket) == "table" and type(bucket.products) == "table" then
                    for plantKey, _ in pairs(bucket.products) do
                        if bestUid > 0 then
                            break
                        end
                        local plantUid = tonumber(plantKey) or 0
                        if plantUid > 0 then
                            local sample = BagSample(plantUid)
                            if type(sample) == "table" then
                                considerItem(sample, plantUid)
                            elseif StockPiler.Items and StockPiler.Items.AsItemData then
                                considerItem(StockPiler.Items.AsItemData(plantUid), plantUid)
                            end
                        end
                    end
                end
            end
        end
    end

    if cacheKey ~= "" then
        SM._plantUidCache[cacheKey] = bestUid
    end
    return bestUid
end

local function SeedUidsFromGrowsMatchingSpec(spec)
    local out = {}
    local MS = StockPiler.MaterialSpec
    if not (MS and MS.ProductMatches) then
        return out
    end
    local grows = GrowsTable()
    if type(grows) ~= "table" then
        return out
    end
    for seedKey, bucket in pairs(grows) do
        local seedUid = tonumber(seedKey) or (type(bucket) == "table" and tonumber(bucket.seedUid)) or 0
        if seedUid > 0 and type(bucket) == "table" and type(bucket.products) == "table" then
            for plantKey, _ in pairs(bucket.products) do
                local plantUid = tonumber(plantKey) or 0
                if plantUid > 0 then
                    local sample = BagSample(plantUid)
                    if type(sample) ~= "table" and StockPiler.Items and StockPiler.Items.AsItemData then
                        sample = StockPiler.Items.AsItemData(plantUid)
                    end
                    if type(sample) == "table" and IsGrowProducerItem(sample)
                        and MS.ProductMatches(sample, spec) == true
                    then
                        out[#out + 1] = seedUid
                        break
                    end
                end
            end
        end
    end
    return out
end

--- Resolve best seed for a plant/spec. Uses grows/refines; falls back to bag name match.
function SM.ResolveSeedForSpec(spec)
    if type(spec) ~= "table" then
        return nil
    end
    local plantUid = SM.FindPlantUidForSpec(spec)
    -- Skill-matched plant->seed first (never let owned L1 vendor seeds win).
    if plantUid > 0 and SM.ResolveSeedUidForPlant then
        local matched = tonumber(SM.ResolveSeedUidForPlant(plantUid, spec)) or 0
        if matched > 0 then
            return { uniqueID = matched, uid = matched, plantUid = plantUid }
        end
    end
    local seedUids = {}
    if plantUid > 0 then
        seedUids = SM.GetSeedUidsForPlant(plantUid) or {}
    end
    if (not seedUids or #seedUids == 0) then
        seedUids = SeedUidsFromGrowsMatchingSpec(spec)
        if plantUid <= 0 and #seedUids > 0 then
            -- Infer plant from first matching grow product.
            local grows = GrowsTable()
            local seedUid = seedUids[1]
            local bucket = type(grows) == "table" and grows[tostring(seedUid)]
            if type(bucket) == "table" and type(bucket.products) == "table" then
                local MS = StockPiler.MaterialSpec
                for plantKey, _ in pairs(bucket.products) do
                    local pUid = tonumber(plantKey) or 0
                    local sample = BagSample(pUid)
                    if type(sample) ~= "table" and StockPiler.Items and StockPiler.Items.AsItemData then
                        sample = StockPiler.Items.AsItemData(pUid)
                    end
                    if pUid > 0 and type(sample) == "table" and MS and MS.ProductMatches
                        and MS.ProductMatches(sample, spec) == true
                    then
                        plantUid = pUid
                        break
                    end
                end
            end
        end
    end
    local best = SM.PickBestSeedUid(plantUid, seedUids, spec)
    if best > 0 then
        return { uniqueID = best, uid = best, plantUid = plantUid }
    end
    if plantUid <= 0 then
        return nil
    end
    -- Empty grows: match bag seeds/spores by name relatedness to plant.
    local plantName = spec.name
    if (not plantName or plantName == "") and StockPiler.Items and StockPiler.Items.GetByUid then
        local row = StockPiler.Items.GetByUid(plantUid)
        plantName = row and row.name
    end
    if (not plantName or plantName == "") and StockPiler.Inventory and StockPiler.Inventory.GetSample then
        local sample = StockPiler.Inventory.GetSample(plantUid)
        plantName = sample and sample.name
    end
    local candidates = {}
    local Inv = StockPiler.Inventory
    if Inv and Inv.ForEachItem then
        Inv.ForEachItem(function(item)
            if type(item) ~= "table" then
                return
            end
            if not SM.IsBagSeedOrSpore(item) then
                return
            end
            local seedUid = tonumber(item.uniqueID) or 0
            if seedUid <= 0 or SM.IsSeedPacketUid(seedUid) then
                return
            end
            if GrowNamesRelated(plantName, item.name) then
                candidates[#candidates + 1] = seedUid
            end
        end)
    end
    -- Learned Items store (seeds not currently in bags).
    if #candidates == 0 and StockPiler.Items and StockPiler.Items.GetByUid then
        local items = nil
        if StockPiler.Account and type(StockPiler.Account.items) == "table" then
            items = StockPiler.Account.items
        elseif StockPiler.Knowledge and StockPiler.Knowledge.Items then
            items = StockPiler.Knowledge.Items()
        end
        if type(items) == "table" then
            for uidKey, row in pairs(items) do
                if type(row) == "table" then
                    local kind = tostring(row.kind or "")
                    if kind == "seed" or kind == "spore" or IsBagSeedOrSporeItem(row) then
                        local seedUid = tonumber(row.uniqueID) or tonumber(uidKey) or 0
                        if seedUid > 0 and not SM.IsSeedPacketUid(seedUid)
                            and GrowNamesRelated(plantName, row.name)
                        then
                            candidates[#candidates + 1] = seedUid
                        end
                    end
                end
            end
        end
    end
    best = SM.PickBestSeedUid(plantUid, candidates, spec)
    if best > 0 then
        return { uniqueID = best, uid = best, plantUid = plantUid }
    end
    return nil
end

----------------------------------------------------------------
-- Observe plant / refine / harvest (learn only on complete)
----------------------------------------------------------------

function SM.NotePlotSeed(plotNum, seedUid)
    plotNum = tonumber(plotNum) or 0
    seedUid = tonumber(seedUid) or 0
    if plotNum <= 0 or seedUid <= 0 then
        return
    end
    SM._plotSeeds[plotNum] = seedUid
end

function SM.ResolvePlotSeed(plotNum, liveSeed)
    liveSeed = tonumber(liveSeed) or 0
    if liveSeed > 0 then
        SM.NotePlotSeed(plotNum, liveSeed)
        return liveSeed
    end
    return tonumber(SM._plotSeeds[tonumber(plotNum) or 0]) or 0
end

function SM.ObservePlant(plotNum, seedUid)
    seedUid = tonumber(seedUid) or 0
    if seedUid <= 0 then
        return
    end
    SM.NotePlotSeed(plotNum, seedUid)
    local bucket = EnsureGrowBucket(seedUid)
    if type(bucket) == "table" then
        bucket.plantAttempts = (tonumber(bucket.plantAttempts) or 0) + 1
    end
end

function SM.RefreshHarvestWatch(plotNum, info)
    plotNum = tonumber(plotNum) or 0
    if plotNum <= 0 then
        return
    end
    local seedUid = 0
    if type(info) == "table" and type(info.Seed) == "table" then
        seedUid = tonumber(info.Seed.uniqueID) or 0
    end
    if seedUid <= 0 then
        seedUid = SM.ResolvePlotSeed(plotNum, 0)
    end
    if seedUid <= 0 then
        return
    end
    SM._harvestWatch[plotNum] = {
        seedUid = seedUid,
        armedAt = NowSec(),
    }
end

function SM.PendingHarvestMap()
    local pending = SM._pendingHarvest
    if type(pending) ~= "table" or pending.plotNum ~= nil then
        local old = pending
        pending = {}
        SM._pendingHarvest = pending
        if type(old) == "table" and old.plotNum ~= nil then
            local plotNum = tonumber(old.plotNum) or 0
            if plotNum > 0 then
                pending[plotNum] = old
            end
        end
    end
    return pending
end

local function SweepExpiredPendingHarvests()
    local now = NowSec()
    if now <= 0 then
        return
    end
    local map = SM.PendingHarvestMap()
    local drop = {}
    for key, entry in pairs(map) do
        if type(entry) == "table" then
            local started = tonumber(entry.startedAt) or 0
            if started > 0 and (now - started) > 30 then
                drop[#drop + 1] = key
            end
        end
    end
    for i = 1, #drop do
        map[drop[i]] = nil
    end
end

function SM.HasPendingHarvest()
    SweepExpiredPendingHarvests()
    return next(SM.PendingHarvestMap()) ~= nil
end

local function NewestPendingHarvest()
    SweepExpiredPendingHarvests()
    local best = nil
    local bestAt = -1
    for _, entry in pairs(SM.PendingHarvestMap()) do
        if type(entry) == "table" then
            local at = tonumber(entry.startedAt) or 0
            if best == nil or at >= bestAt then
                best = entry
                bestAt = at
            end
        end
    end
    return best
end

local function SnapshotNonSeedCounts()
    local after = {}
    if StockPiler.Inventory and StockPiler.Inventory.ForEachItem then
        StockPiler.Inventory.ForEachItem(function(item)
            local uid = tonumber(item.uniqueID) or 0
            if uid > 0 and not IsBagSeedOrSporeItem(item) then
                local stack = tonumber(item.stackCount) or tonumber(item.Count) or 1
                after[uid] = (after[uid] or 0) + stack
            end
        end)
    end
    return after
end

local function EntryRelatedGains(entry, after)
    local gains = {}
    if type(entry) ~= "table" or type(after) ~= "table" then
        return gains
    end
    local seedUid = tonumber(entry.seedUid) or 0
    local before = type(entry.before) == "table" and entry.before or {}
    for uid, count in pairs(after) do
        local delta = (tonumber(count) or 0) - (tonumber(before[uid]) or 0)
        if delta > 0 and HarvestProductRelated(seedUid, uid) then
            gains[uid] = delta
        end
    end
    return gains
end

local function PickPendingHarvest(force)
    SweepExpiredPendingHarvests()
    local after = SnapshotNonSeedCounts()
    local bestKey = nil
    local best = nil
    local bestAt = nil
    local sawCandidate = false
    for key, entry in pairs(SM.PendingHarvestMap()) do
        if type(entry) == "table" and (force == true or entry.lootDirty == true) then
            sawCandidate = true
            if next(EntryRelatedGains(entry, after)) ~= nil then
                local at = tonumber(entry.startedAt) or 0
                if best == nil or at < bestAt then
                    bestKey = key
                    best = entry
                    bestAt = at
                end
            end
        end
    end
    if best == nil and sawCandidate then
        for _, entry in pairs(SM.PendingHarvestMap()) do
            if type(entry) == "table" and (force == true or entry.lootDirty == true) then
                entry.lootDirty = nil
            end
        end
    end
    return bestKey, best
end

function SM.MarkHarvestLootDirty()
    for _, entry in pairs(SM.PendingHarvestMap()) do
        if type(entry) == "table" then
            entry.lootDirty = true
        end
    end
end

function SM.OnCraftChat(payload)
    if type(payload) ~= "table" then
        return
    end
    local kind = tostring(payload.kind or "")
    local pending = NewestPendingHarvest()
    local CC = StockPiler.CraftChatAdapter
    if kind == "critical_failure" then
        if type(pending) == "table" then
            pending.chatCriticalFailure = true
            if SM.CompletePendingHarvestAsCritFail then
                SM.CompletePendingHarvestAsCritFail()
            end
        elseif CC and CC.ArmHarvestFailSticky then
            CC.ArmHarvestFailSticky()
        end
    elseif kind == "critical_success" then
        if type(pending) == "table" then
            pending.chatCriticalSuccess = true
        elseif CC and CC.ArmHarvestSuccessSticky then
            CC.ArmHarvestSuccessSticky()
        end
    elseif kind == "special_moment" then
        if type(pending) == "table" then
            pending.chatCriticalSuccess = true
            pending.chatSpecialMoment = true
        elseif CC and CC.ArmHarvestSpecialMomentSticky then
            CC.ArmHarvestSpecialMomentSticky()
        end
    elseif kind == "harvested" then
        SM.MarkHarvestLootDirty()
    end
end

function SM.ShouldAttemptHarvestComplete(force)
    local _, pending = PickPendingHarvest(force == true)
    return type(pending) == "table"
end

--- Arm pending harvest; actual learn runs in TryCompletePendingHarvest.
function SM.BeginPendingHarvest(plotNum, seedUid)
    plotNum = tonumber(plotNum) or 0
    -- tonumber(0) is truthy, so `or ResolvePlotSeed` never ran for a zero uid (KNW-16).
    seedUid = tonumber(seedUid) or 0
    if seedUid <= 0 then
        seedUid = tonumber(SM.ResolvePlotSeed(plotNum, 0)) or 0
    end
    if seedUid <= 0 then
        seedUid = tonumber(SM._harvestWatch[plotNum] and SM._harvestWatch[plotNum].seedUid) or 0
    end
    local chatFail = false
    local chatOk = false
    local CC = StockPiler.CraftChatAdapter
    if CC and CC.ConsumeHarvestCriticalFailureSticky then
        chatFail = CC.ConsumeHarvestCriticalFailureSticky() == true
    end
    if CC and CC.ConsumeHarvestCriticalSuccessSticky then
        chatOk = CC.ConsumeHarvestCriticalSuccessSticky() == true
    end
    SM.PendingHarvestMap()[plotNum] = {
        plotNum = plotNum,
        seedUid = seedUid,
        startedAt = NowSec(),
        before = {},
        lootDirty = false,
        chatCriticalFailure = chatFail,
        chatCriticalSuccess = chatOk,
        chatSpecialMoment = false,
    }
    local armed = SM.PendingHarvestMap()[plotNum]
    if CC and CC.ConsumeHarvestSpecialMomentSticky
        and CC.ConsumeHarvestSpecialMomentSticky() == true
    then
        armed.chatSpecialMoment = true
        armed.chatCriticalSuccess = true
    end
    -- Snapshot plant counts for delta (no learn yet).
    if StockPiler.Inventory and StockPiler.Inventory.ForEachItem then
        StockPiler.Inventory.ForEachItem(function(item)
            local uid = tonumber(item.uniqueID) or 0
            if uid > 0 and not IsBagSeedOrSporeItem(item) then
                local stack = tonumber(item.stackCount) or tonumber(item.Count) or 1
                armed.before[uid] = (tonumber(armed.before[uid]) or 0) + stack
            end
        end)
    end
end

function SM.NoteCultSkillHit(seedUid, delta)
    seedUid = tonumber(seedUid) or 0
    delta = tonumber(delta) or 1
    if seedUid <= 0 or delta <= 0 then
        return false
    end
    local bucket = EnsureGrowBucket(seedUid)
    if type(bucket) ~= "table" then
        return false
    end
    bucket.cultSkillHits = (tonumber(bucket.cultSkillHits) or 0) + delta
    return true
end

--- Chat "Your creation failed." with an armed pending: close without learning bag trash.
--- plotKey closes that plot. With no key, the newest pending harvest is closed
--- (crafting chat does not name the plot).
function SM.CompletePendingHarvestAsCritFail(plotKey)
    local pending = nil
    local map = SM.PendingHarvestMap()
    plotKey = tonumber(plotKey)
    if plotKey ~= nil and plotKey > 0 then
        pending = map[plotKey]
    end
    if type(pending) ~= "table" then
        pending = NewestPendingHarvest()
        plotKey = type(pending) == "table" and tonumber(pending.plotNum) or nil
    end
    if type(pending) ~= "table" then
        return false
    end
    local seedUid = tonumber(pending.seedUid) or 0
    local plotNum = tonumber(pending.plotNum) or tonumber(plotKey) or 0
    local bucket = seedUid > 0 and EnsureGrowBucket(seedUid) or nil
    if type(bucket) == "table" then
        bucket.harvestAttempts = (tonumber(bucket.harvestAttempts) or 0) + 1
        bucket.chatCriticalFailure = (tonumber(bucket.chatCriticalFailure) or 0) + 1
    end
    SM.PendingHarvestMap()[plotNum] = nil
    if StockPiler.Grow and StockPiler.Grow.NotifyHarvestOutcome then
        StockPiler.Grow.NotifyHarvestOutcome(plotNum, { critFail = true })
    end
    return true
end

function SM.TryCompletePendingHarvest(force)
    if not SM.ShouldAttemptHarvestComplete(force) then
        return false
    end
    local plotKey, pending = PickPendingHarvest(force == true)
    if type(pending) ~= "table" then
        return false
    end
    -- A missed loot event must not learn a later bank or mail gain.
    local started = tonumber(pending.startedAt) or 0
    local now = NowSec()
    if started > 0 and now > 0 and (now - started) > 30 then
        SM.PendingHarvestMap()[plotKey] = nil
        return false
    end
    -- Crafting chat said the harvest failed: do not learn any bag delta as a product.
    if pending.chatCriticalFailure == true then
        return SM.CompletePendingHarvestAsCritFail(plotKey)
    end
    -- Snapshot / learn ONLY on complete attempt.
    local after = SnapshotNonSeedCounts()
    local seedUid = tonumber(pending.seedUid) or 0
    local plotNum = tonumber(pending.plotNum) or 0
    -- Only a plant related to this plot's seed counts. A potion, a vial, or
    -- another plot's loot leaves this entry pending.
    local related = EntryRelatedGains(pending, after)
    if next(related) == nil then
        pending.lootDirty = nil
        return false
    end
    local learned = false
    local structural = false
    local products = {}
    local bucket = nil
    if seedUid > 0 then
        bucket = EnsureGrowBucket(seedUid)
        if type(bucket) == "table" then
            bucket.harvestAttempts = (tonumber(bucket.harvestAttempts) or 0) + 1
            if pending.chatCriticalSuccess == true then
                bucket.chatCriticalSuccess = (tonumber(bucket.chatCriticalSuccess) or 0) + 1
            end
            if pending.chatSpecialMoment == true then
                bucket.specialMomentHits = (tonumber(bucket.specialMomentHits) or 0) + 1
            end
        end
        local credited = {}
        for uid, delta in pairs(related) do
            credited[uid] = delta
            local accepted, isNew = RecordHarvestProduct(seedUid, uid, delta)
                if accepted == true then
                    if isNew == true then
                        structural = true
                    end
                    learned = true
                    local sample = BagSample(uid)
                    if sample and StockPiler.Items and StockPiler.Items.StoreItem then
                        StockPiler.Items.StoreItem(sample, "plant")
                    end
                    -- Collect all non-seed plant gains for harvest chat (Special Moment
                    -- often adds a higher-tier plant alongside the normal yield).
                    if sample and not IsBagSeedOrSporeItem(sample)
                        and SM.IsHarvestByproduct(sample) ~= true
                    then
                        local sReq = tonumber(sample.craftingSkillRequirement)
                            or tonumber(sample.skillReq) or 0
                        if sReq <= 0 and type(sample.bonuses) == "table" then
                            sReq = tonumber(sample.bonuses[9]) or 0
                        end
                        products[#products + 1] = {
                            uid = uid,
                            delta = delta,
                            name = sample.name,
                            skillReq = sReq,
                        }
                    end
                end
        end
        -- A plot armed after this loot landed already has it in `before`.
        -- Raising that baseline up to the post-loot count keeps the same
        -- stack from being subtracted again. Only uids this seed accepted
        -- move, so the other plot keeps a plant that was not this seed's.
        local startedAt = tonumber(pending.startedAt) or 0
        local others = SM.PendingHarvestMap()
        local dropOlder = {}
        for key, other in pairs(others) do
            if key ~= plotKey and type(other) == "table" then
                if type(other.before) == "table" then
                    for uid in pairs(credited) do
                        other.before[uid] = math.max(tonumber(other.before[uid]) or 0, after[uid])
                    end
                end
                local otherAt = tonumber(other.startedAt) or 0
                if otherAt < startedAt and next(EntryRelatedGains(other, after)) == nil then
                    dropOlder[#dropOlder + 1] = key
                elseif next(EntryRelatedGains(other, after)) == nil then
                    other.lootDirty = nil
                end
            end
        end
        for i = 1, #dropOlder do
            others[dropOlder[i]] = nil
        end
    end
    local specialMoment = pending.chatSpecialMoment == true
    SM.PendingHarvestMap()[plotKey] = nil
    if structural then
        TouchIfStructural("harvest")
    end
    if learned and #products > 0 and StockPiler.Grow and StockPiler.Grow.NotifyHarvestOutcome then
        table.sort(products, function(a, b)
            local sa = tonumber(a.skillReq) or 0
            local sb = tonumber(b.skillReq) or 0
            if sa ~= sb then
                return sa > sb
            end
            return (tonumber(a.delta) or 0) > (tonumber(b.delta) or 0)
        end)
        -- Always announce every distinct plant product (usually 1; SM can be 2+).
        local maxLines = 4
        for i = 1, math.min(maxLines, #products) do
            local p = products[i]
            local special = specialMoment == true and i == 1
                and (tonumber(p.skillReq) or 0) > 0
            StockPiler.Grow.NotifyHarvestOutcome(plotNum, {
                name = p.name,
                count = p.delta,
                uniqueID = p.uid,
                specialMoment = special == true,
            })
        end
    end
    return learned
end

function SM.BeginPendingRefine(itemData)
    if type(itemData) ~= "table" then
        return false
    end
    local plantUid = tonumber(itemData.uniqueID) or 0
    if plantUid <= 0 then
        return false
    end
    if SM.IsRefineConvertFailed(plantUid) then
        return false
    end
    local expected = SM.GetSeedUidsForPlant(plantUid)
    local best = SM.PickBestSeedUid(plantUid, expected)
    SM._pendingRefine = {
        plantUid = plantUid,
        expectedSeedUid = best,
        startedAt = NowSec(),
        beforeSeed = best > 0 and (StockPiler.Inventory and StockPiler.Inventory.CountByUid(best) or 0) or 0,
    }
    return true
end

function SM.IsRefineConvertFailed(uid)
    uid = tonumber(uid) or 0
    if uid <= 0 then
        return false
    end
    local untilT = tonumber(SM._refineConvertFailedUntil[uid]) or 0
    if untilT > 0 then
        if NowSec() < untilT then
            return true
        end
        SM._refineConvertFailedUntil[uid] = nil
    end
    if HasProvenSeedConvert(uid) then
        return false
    end
    if SM._refineConvertFailed[uid] == true then
        return true
    end
    local row = StockPiler.Items and StockPiler.Items.GetByUid and StockPiler.Items.GetByUid(uid)
    return type(row) == "table" and row.refineConvertFailed == true
end

function SM.MarkRefineConvertFailed(plantUid, reason)
    plantUid = tonumber(plantUid) or 0
    if plantUid <= 0 then
        return
    end
    local item = BagSample(plantUid)
    -- Special Squig Bits-class: permanent block + exception registry.
    if LooksSpecialSquigBits(item) then
        SM._refineConvertFailed[plantUid] = true
        local ME = StockPiler.MaterialExceptions
        if ME and ME.MarkForceNotRefinable then
            ME.MarkForceNotRefinable(plantUid, reason or "refine-fail-squig")
        end
        if StockPiler.Items and StockPiler.Items.GetByUid then
            local row = StockPiler.Items.GetByUid(plantUid)
            if type(row) == "table" then
                row.refineConvertFailed = true
            elseif StockPiler.Items.StoreItem and item then
                local stored = StockPiler.Items.StoreItem(item, "mat")
                if type(stored) == "table" then
                    stored.refineConvertFailed = true
                end
            end
        end
        return
    end
    if HasProvenSeedConvert(plantUid) then
        -- Session cooldown only - not permanent blacklist.
        local sec = tonumber(SM.REFINE_CONVERT_FAIL_COOLDOWN_SEC) or 45
        SM._refineConvertFailedUntil[plantUid] = NowSec() + sec
        SM._refineConvertFailed[plantUid] = nil
        return
    end
    -- Unproven: session cooldown (not sticky SV) except squig class above.
    local sec = tonumber(SM.REFINE_CONVERT_FAIL_COOLDOWN_SEC) or 45
    SM._refineConvertFailedUntil[plantUid] = NowSec() + sec
end

function SM.ObserveRefineComplete(plantUid, seedUid, seedDelta)
    plantUid = tonumber(plantUid) or 0
    seedUid = tonumber(seedUid) or 0
    seedDelta = tonumber(seedDelta) or 0
    if plantUid <= 0 then
        return false
    end
    -- No SV row until a seed convert is observed (failed/unknown refines stay ephemeral).
    if seedUid <= 0 or seedDelta <= 0 then
        return false
    end
    local entry = EnsureRefineEntry(plantUid, true)
    if type(entry) ~= "table" then
        return false
    end
    entry.refineAttempts = (tonumber(entry.refineAttempts) or 0) + 1
    local structural = false
    if (tonumber(entry.seedUid) or 0) ~= seedUid then
        entry.seedUid = seedUid
        structural = true
    end
    local so = entry.seedOut
    if type(so) ~= "table" then
        so = {}
        entry.seedOut = so
    end
    local row = so[tostring(seedUid)]
    if type(row) ~= "table" then
        row = { samples = 0, qtySum = 0 }
        so[tostring(seedUid)] = row
        structural = true
    end
    row.samples = (tonumber(row.samples) or 0) + 1
    row.qtySum = (tonumber(row.qtySum) or 0) + seedDelta
    -- Link grow products via cultivation path (not butcher ProductMatches).
    RecordHarvestProduct(seedUid, plantUid, 1)
    if structural then
        TouchIfStructural("refine")
    end
    return true
end

function SM.TryCompletePendingRefine()
    local pending = SM._pendingRefine
    if type(pending) ~= "table" then
        return false
    end
    local elapsed = NowSec() - (tonumber(pending.startedAt) or 0)
    local plantUid = tonumber(pending.plantUid) or 0
    local seedUid = tonumber(pending.expectedSeedUid) or 0
    local after = 0
    if seedUid > 0 and StockPiler.Inventory and StockPiler.Inventory.CountByUid then
        after = StockPiler.Inventory.CountByUid(seedUid)
    end
    local delta = after - (tonumber(pending.beforeSeed) or 0)
    if delta > 0 then
        SM.ObserveRefineComplete(plantUid, seedUid, delta)
        SM._pendingRefine = nil
        return true
    end
    -- Fast-fail ~1.5s with no convert.
    if elapsed >= (tonumber(SM.REFINE_FAST_FAIL_SEC) or 1.5) then
        SM.MarkRefineConvertFailed(plantUid, "fast-fail")
        -- Do not EnsureRefineEntry here - that created dead seedUid=0 SV rows.
        SM._pendingRefine = nil
        return false
    end
    return false
end

function SM.ItemLooksLikeRefinablePlant(itemData)
    if type(itemData) ~= "table" then
        return false
    end
    if IsBagSeedOrSporeItem(itemData) or IsSeedPacketItem(itemData) then
        return false
    end
    local ME = StockPiler.MaterialExceptions
    if ME and ME.IsForceNotRefinable and ME.IsForceNotRefinable(itemData) == true then
        return false
    end
    -- Apo containers share cult=0 + craftingBonus with some plants; never refine them.
    local role = tostring(itemData.craftingRole or itemData.role or "")
    if role == "container" then
        return false
    end
    local cit = GameData and GameData.CraftingItemType
    if type(itemData.craftingBonus) == "table" and cit then
        for _, bonus in pairs(itemData.craftingBonus) do
            if type(bonus) == "table" then
                local ref = tonumber(bonus.bonusReference) or 0
                local val = tonumber(bonus.bonusValue) or 0
                if ref == 8 and (val == cit.CONTAINER or val == cit.CONTAINER_DYE) then
                    return false
                end
            end
        end
    end
    if itemData.isRefinable == true then
        return true
    end
    local uid = tonumber(itemData.uniqueID) or tonumber(itemData.uid) or 0
    if uid > 0 and StockPiler.Items and StockPiler.Items.GetByUid then
        local learned = StockPiler.Items.GetByUid(uid)
        if type(learned) == "table" then
            if ME and ME.IsForceNotRefinable and ME.IsForceNotRefinable(learned) == true then
                return false
            end
            if tostring(learned.role or learned.craftingRole or "") == "container" then
                return false
            end
            if learned.isRefinable == true then
                return true
            end
        end
    end
    local n = string.lower(ToNarrow(itemData.name))
    if string.find(n, "goldweed", 1, true) or string.find(n, "gobswort", 1, true) then
        return true
    end
    local cult = tonumber(itemData.cultivationType) or 0
    return cult == 0 and type(itemData.craftingBonus) == "table"
end

----------------------------------------------------------------
-- Migrate: stamp plant effectId from known seed links (one-shot).
-- Only EFFECT transfers seed→plant (never cult SPECIAL_CHANCE).
----------------------------------------------------------------

-- Retired. The latch stays on old saves so validation still accepts it.
function SM.MigratePlantEffectsFromSeeds()
    return 0
end

----------------------------------------------------------------
-- Craft-cycle stats (/stp stats)
----------------------------------------------------------------

function SM.DumpCraftCycleStats(emit)
    emit = type(emit) == "function" and emit or function(msg)
        if StockPiler.Debug and StockPiler.Debug.Print then
            StockPiler.Debug.Print(msg)
        end
    end
    emit("=== StockPiler craft-cycle stats ===")

    local grows = GrowsTable() or {}
    emit("--- grows (seed) ---")
    local growN = 0
    for seedKey, bucket in pairs(grows) do
        if type(bucket) == "table" then
            local plants = tonumber(bucket.plantAttempts) or 0
            local harvests = tonumber(bucket.harvestAttempts) or 0
            if plants > 0 or harvests > 0 then
                growN = growN + 1
                local cultHits = tonumber(bucket.cultSkillHits) or 0
                local cultPct = harvests > 0 and (cultHits / harvests * 100) or 0
                local sample = BagSample(tonumber(seedKey) or 0)
                emit(string.format(
                    "  %s uid=%s plant=%d harvest=%d cultSkillUp=%.0f%%",
                    tostring(ToNarrow(sample and sample.name) ~= "" and ToNarrow(sample.name) or seedKey),
                    tostring(seedKey),
                    plants,
                    harvests,
                    cultPct
                ))
            end
        end
    end
    if growN == 0 then
        emit("  (none)")
    end

    local SkillUp = StockPiler.SkillUp
    if SkillUp and SkillUp.DumpRates then
        SkillUp.DumpRates(emit)
    end

    local refines = RefinesTable() or {}
    emit("--- refines (plant) ---")
    local refineN = 0
    for plantKey, entry in pairs(refines) do
        if type(entry) == "table" then
            local attempts = tonumber(entry.refineAttempts) or 0
            if attempts > 0 then
                refineN = refineN + 1
                local sample = BagSample(tonumber(plantKey) or 0)
                emit(string.format(
                    "  %s uid=%s refineAttempts=%d seedUid=%d",
                    tostring(ToNarrow(sample and sample.name) ~= "" and ToNarrow(sample.name) or plantKey),
                    tostring(plantKey),
                    attempts,
                    tonumber(entry.seedUid) or 0
                ))
            end
        end
    end
    if refineN == 0 then
        emit("  (none)")
    end

    local recipes = StockPiler.Knowledge and StockPiler.Knowledge.Recipes and StockPiler.Knowledge.Recipes() or {}
    emit("--- brew (recipe) ---")
    local brewN = 0
    for key, recipe in pairs(recipes) do
        if type(recipe) == "table" then
            local attempts = tonumber(recipe.brewAttempts) or 0
            if attempts > 0 then
                brewN = brewN + 1
                local ok = tonumber(recipe.brewSuccesses) or 0
                local pct = attempts > 0 and (ok / attempts * 100) or 0
                emit(string.format(
                    "  key=%s attempts=%d success=%.0f%% yield=%.2f",
                    tostring(key):sub(1, 48),
                    attempts,
                    pct,
                    tonumber(recipe.recipeYield) or 0
                ))
            end
        end
    end
    if brewN == 0 then
        emit("  (none)")
    end
end

----------------------------------------------------------------
-- Family ladders (Upgrade Seed / SkillUp graduation)
----------------------------------------------------------------

ItemSkillReq = function(item)
    if type(item) ~= "table" then
        return 0
    end
    local req = tonumber(item.craftingSkillRequirement) or tonumber(item.skillReq) or 0
    if req <= 0 and type(item.bonuses) == "table" then
        req = tonumber(item.bonuses[9]) or 0
    end
    if req <= 0 then
        local Items = StockPiler.Items
        local uid = tonumber(item.uniqueID) or tonumber(item.uid) or 0
        if uid > 0 and Items and Items.ToSpec then
            local spec = Items.ToSpec(uid)
            req = tonumber(spec and spec.skillLevel) or 0
        end
    end
    return req
end

--- Last-token genus after normalize (e.g. "majestic goldweed" -> "goldweed").
function SM.GenusKeyFromName(name)
    local n = NormalizeGrowName(ToNarrow(name))
    if n == "" then
        return ""
    end
    -- RoR spelling split: plant "Marsh Root" vs seed "Marshroot" must share a genus
    -- or Fretting seeds sit on marshroot|unknown while climb uses root|* with s0.
    n = string.gsub(n, "marsh%s+root", "marshroot")
    return string.match(n, "([^%s]+)$") or n
end

function SM.FamilyKeyParts(genus, role, effectId)
    genus = string.lower(tostring(genus or ""))
    role = string.lower(tostring(role or "unknown"))
    if role == "" then
        role = "unknown"
    end
    effectId = tonumber(effectId) or 0
    if genus == "" then
        return nil
    end
    return genus .. "|" .. role .. "|" .. tostring(effectId), genus, role, effectId
end

function SM.FamilyKeyFromSpec(spec)
    if type(spec) ~= "table" then
        return nil
    end
    local genus = SM.GenusKeyFromName(spec.name)
    if genus == "" then
        local uid = tonumber(spec.uid) or tonumber(spec.uniqueID) or tonumber(spec.boundUid) or 0
        local sample = BagSample(uid)
        genus = SM.GenusKeyFromName(sample and sample.name)
    end
    local role = tostring(spec.role or "unknown")
    if role == "" then
        role = "unknown"
    end
    local effectId = tonumber(spec.effectId) or 0
    return SM.FamilyKeyParts(genus, role, effectId)
end

local function EnsureRung(bucket, skillReq)
    skillReq = tonumber(skillReq) or 0
    if skillReq < 1 then
        return nil
    end
    local rungs = bucket.rungs
    for i = 1, #rungs do
        if rungs[i].skillReq == skillReq then
            return rungs[i]
        end
    end
    local rung = { skillReq = skillReq, seedUid = 0, plantUid = 0, name = "" }
    rungs[#rungs + 1] = rung
    return rung
end

local function SortRungs(rungs)
    table.sort(rungs, function(a, b)
        return (tonumber(a.skillReq) or 0) < (tonumber(b.skillReq) or 0)
    end)
end

local function NoteSeedPlant(families, seedUid, plantUid, skillReq, name, role, effectId, opts)
    opts = type(opts) == "table" and opts or {}
    seedUid = tonumber(seedUid) or 0
    plantUid = tonumber(plantUid) or 0
    skillReq = tonumber(skillReq) or 0
    if skillReq < 1 then
        return
    end
    -- Heal plant-only notes from grows/refines/vendor links before bucketing.
    -- Crit tier-up notes pass healSeed=false so a lower planted seed cannot claim
    -- the higher plant's rung before a same-tier seed is known.
    if plantUid > 0 and seedUid <= 0 and opts.healSeed ~= false and SM.ResolveSeedUidForPlant then
        seedUid = tonumber(SM.ResolveSeedUidForPlant(plantUid, nil)) or 0
    end
    local genus = SM.GenusKeyFromName(name)
    if genus == "" and plantUid > 0 then
        local plantSample = BagSample(plantUid)
        genus = SM.GenusKeyFromName(plantSample and plantSample.name)
    end
    if genus == "" and seedUid > 0 then
        local seedSample = BagSample(seedUid)
        genus = SM.GenusKeyFromName(seedSample and seedSample.name)
    end
    local key, g, r, e = SM.FamilyKeyParts(genus, role, effectId)
    if not key then
        return
    end
    local bucket = families[key]
    if type(bucket) ~= "table" then
        bucket = { key = key, genus = g, role = r, effectId = e, rungs = {} }
        families[key] = bucket
    end
    local rung = EnsureRung(bucket, skillReq)
    if not rung then
        return
    end
    if seedUid > 0 then
        local function uidReq(uid)
            uid = tonumber(uid) or 0
            if uid <= 0 then
                return 0
            end
            local sample = BagSample(uid)
            local req = 0
            if type(sample) == "table" then
                req = tonumber(sample.craftingSkillRequirement) or tonumber(sample.skillReq) or 0
                if req <= 0 and type(sample.bonuses) == "table" then
                    req = tonumber(sample.bonuses[9]) or 0
                end
            end
            if req <= 0 and StockPiler.Items and StockPiler.Items.GetByUid then
                local row = StockPiler.Items.GetByUid(uid)
                if type(row) == "table" then
                    req = tonumber(row.craftingSkillRequirement) or tonumber(row.skillReq) or 0
                    if req <= 0 and type(row.bonuses) == "table" then
                        req = tonumber(row.bonuses[9]) or 0
                    end
                end
            end
            return req
        end
        local newReq = uidReq(seedUid)
        -- Never pin a known lower-tier seed onto a higher plant rung.
        -- Exact grow-name match used to allow this (Beardweed L150 seed on the
        -- L175 plant rung) so Apo brew reserved against the met L150 buffer and
        -- burned the only L175 plant. Crit plants share names with lower seeds.
        if newReq > 0 and newReq < skillReq then
            seedUid = 0
        end
    end
    if seedUid > 0 then
        local curSeed = tonumber(rung.seedUid) or 0
        if curSeed <= 0 then
            rung.seedUid = seedUid
        elseif curSeed ~= seedUid then
            local function uidReq(uid)
                uid = tonumber(uid) or 0
                if uid <= 0 then
                    return 0
                end
                local sample = BagSample(uid)
                local req = 0
                if type(sample) == "table" then
                    req = tonumber(sample.craftingSkillRequirement) or tonumber(sample.skillReq) or 0
                    if req <= 0 and type(sample.bonuses) == "table" then
                        req = tonumber(sample.bonuses[9]) or 0
                    end
                end
                if req <= 0 and StockPiler.Items and StockPiler.Items.GetByUid then
                    local row = StockPiler.Items.GetByUid(uid)
                    if type(row) == "table" then
                        req = tonumber(row.craftingSkillRequirement) or tonumber(row.skillReq) or 0
                        if req <= 0 and type(row.bonuses) == "table" then
                            req = tonumber(row.bonuses[9]) or 0
                        end
                    end
                end
                return req
            end
            local curReq = uidReq(curSeed)
            local newReq = uidReq(seedUid)
            if newReq == skillReq and curReq ~= skillReq then
                rung.seedUid = seedUid
            elseif curReq ~= skillReq and newReq ~= skillReq and newReq > curReq then
                rung.seedUid = seedUid
            end
        end
    end
    if plantUid > 0 then
        local curPlant = tonumber(rung.plantUid) or 0
        if curPlant <= 0 or seedUid > 0 then
            rung.plantUid = plantUid
        end
    end
    if name and name ~= "" and (rung.name == nil or rung.name == "") then
        rung.name = ToNarrow(name)
    end
end

local function HealFamilyRungSeeds(families)
    if type(families) ~= "table" then
        return
    end
    for _, bucket in pairs(families) do
        if type(bucket) == "table" and type(bucket.rungs) == "table" then
            for i = 1, #bucket.rungs do
                local rung = bucket.rungs[i]
                local plantUid = tonumber(rung.plantUid) or 0
                local seedUid = tonumber(rung.seedUid) or 0
                if plantUid > 0 and seedUid <= 0 and SM.ResolveSeedUidForPlant then
                    seedUid = tonumber(SM.ResolveSeedUidForPlant(plantUid, nil)) or 0
                    local rungReq = tonumber(rung.skillReq) or 0
                    local seedReq = 0
                    if seedUid > 0 then
                        local sample = BagSample(seedUid)
                        if type(sample) == "table" then
                            seedReq = tonumber(sample.craftingSkillRequirement)
                                or tonumber(sample.skillReq) or 0
                        end
                        if seedReq <= 0 and StockPiler.Items and StockPiler.Items.GetByUid then
                            local learned = StockPiler.Items.GetByUid(seedUid)
                            if type(learned) == "table" then
                                seedReq = tonumber(learned.skillReq) or tonumber(learned.skillLevel)
                                    or tonumber(learned.craftingSkillRequirement) or 0
                            end
                        end
                    end
                    if seedUid > 0 and rungReq > 0 and seedReq == rungReq then
                        rung.seedUid = seedUid
                    end
                end
            end
        end
    end
end

--- Build all known family ladders from grows/refines/bags/account/vendor.
--- Returns map familyKey -> { key, genus, role, effectId, rungs[] }.
--- Cached by Knowledge gen so dumps / climb ticks do not rebuild every frame.
function SM.BuildAllFamilyLadders()
    local Know = StockPiler.Knowledge
    local gen = Know and Know.GetGen and Know.GetGen() or 0
    if type(SM._familyLadderCache) == "table" and SM._familyLadderCacheGen == gen then
        return SM._familyLadderCache
    end
    local families = {}
    local Items = StockPiler.Items
    local MS = StockPiler.MaterialSpec

    local function roleEffectForUid(uid)
        uid = tonumber(uid) or 0
        local role, effectId = "unknown", 0
        if uid > 0 and Items and Items.ToSpec then
            local spec = Items.ToSpec(uid)
            if type(spec) == "table" then
                role = tostring(spec.role or "unknown")
                effectId = tonumber(spec.effectId) or 0
            end
        end
        if (role == "" or role == "unknown") and uid > 0 and MS and MS.FromUid then
            local spec = MS.FromUid(uid)
            if type(spec) == "table" then
                if role == "unknown" or role == "" then
                    role = tostring(spec.role or "unknown")
                end
                if effectId <= 0 then
                    effectId = tonumber(spec.effectId) or 0
                end
            end
        end
        return role, effectId
    end

    local grows = GrowsTable()
    if type(grows) == "table" then
        for seedKey, bucket in pairs(grows) do
            local seedUid = tonumber(seedKey) or 0
            if seedUid > 0 and type(bucket) == "table" then
                local seedSample = BagSample(seedUid)
                local seedReq = ItemSkillReq(seedSample or {})
                if seedReq < 1 then
                    seedReq = ItemSkillReq(bucket)
                end
                if type(bucket.products) == "table" then
                    for plantKey, _ in pairs(bucket.products) do
                        local plantUid = tonumber(plantKey) or 0
                        local plantSample = BagSample(plantUid)
                        local plantReq = ItemSkillReq(plantSample or {})
                        local role, effectId = roleEffectForUid(plantUid > 0 and plantUid or seedUid)
                        local plantName = (plantSample and plantSample.name) or ""
                        local seedName = (seedSample and seedSample.name) or ""
                        -- Crit / special harvest can yield a higher-tier plant from a
                        -- lower seed. Do not pin that higher rung to the lower seedUid
                        -- (Fusk L100 spore must not own the L125 rung when L125 spore exists).
                        if plantReq > 0 and seedReq > 0 and plantReq > seedReq then
                            NoteSeedPlant(families, seedUid, 0, seedReq, seedName, role, effectId)
                            NoteSeedPlant(families, 0, plantUid, plantReq, plantName, role, effectId, {
                                healSeed = false,
                            })
                        else
                            local req = plantReq > 0 and plantReq or seedReq
                            local name = plantName ~= "" and plantName or seedName
                            NoteSeedPlant(families, seedUid, plantUid, req, name, role, effectId)
                        end
                    end
                elseif seedReq >= 1 then
                    local role, effectId = roleEffectForUid(seedUid)
                    NoteSeedPlant(families, seedUid, 0, seedReq, seedSample and seedSample.name, role, effectId)
                end
            end
        end
    end

    local refines = RefinesTable()
    if type(refines) == "table" then
        for plantKey, entry in pairs(refines) do
            if type(entry) == "table" then
                local plantUid = tonumber(plantKey) or 0
                local seedUid = tonumber(entry.seedUid) or 0
                local plantSample = BagSample(plantUid)
                local req = ItemSkillReq(plantSample or {})
                if req < 1 and seedUid > 0 then
                    req = ItemSkillReq(BagSample(seedUid) or {})
                end
                local role, effectId = roleEffectForUid(plantUid > 0 and plantUid or seedUid)
                NoteSeedPlant(families, seedUid, plantUid, req, plantSample and plantSample.name, role, effectId)
            end
        end
    end

    local function considerItem(item)
        if type(item) ~= "table" then
            return
        end
        local uid = tonumber(item.uniqueID) or tonumber(item.uid) or 0
        if uid <= 0 then
            return
        end
        if SM.IsSeedPacketUid and SM.IsSeedPacketUid(uid) then
            return
        end
        local req = ItemSkillReq(item)
        if req < 1 then
            return
        end
        if IsBagSeedOrSporeItem(item) then
            local plantUid = tonumber(SM.PrimaryPlantForSeed and SM.PrimaryPlantForSeed(uid)) or 0
            local role, effectId = roleEffectForUid(plantUid > 0 and plantUid or uid)
            NoteSeedPlant(families, uid, plantUid, req, item.name, role, effectId)
        elseif SM.ItemLooksLikeRefinablePlant and SM.ItemLooksLikeRefinablePlant(item) == true then
            local seedUid = 0
            if SM.ResolveSeedUidForPlant then
                seedUid = tonumber(SM.ResolveSeedUidForPlant(uid, nil)) or 0
            end
            local role, effectId = roleEffectForUid(uid)
            NoteSeedPlant(families, seedUid, uid, req, item.name, role, effectId)
        end
    end

    local Inv = StockPiler.Inventory
    if Inv and Inv.ForEachItem then
        Inv.ForEachItem(considerItem)
    end

    local items = StockPiler.Account and StockPiler.Account.items
    if type(items) == "table" then
        for key, row in pairs(items) do
            if type(row) == "table" then
                if row.uniqueID == nil and tonumber(key) then
                    row = { uniqueID = tonumber(key), name = row.name, craftingSkillRequirement = row.craftingSkillRequirement }
                end
                considerItem(row)
            end
        end
    end

    local VA = StockPiler.VendorAdapter
    if VA and VA.GetMatchIndex then
        local index = VA.GetMatchIndex()
        if type(index) == "table" and type(index.rows) == "table" then
            for i = 1, #index.rows do
                local row = index.rows[i]
                considerItem(row and row.item)
            end
        end
    end

    for _, bucket in pairs(families) do
        SortRungs(bucket.rungs)
    end
    HealFamilyRungSeeds(families)
    SM._familyLadderCache = families
    SM._familyLadderCacheGen = gen
    return families
end

function SM.GetFamilyLadder(familyKey)
    familyKey = tostring(familyKey or "")
    if familyKey == "" then
        return nil
    end
    local all = SM.BuildAllFamilyLadders()
    return all[familyKey]
end

function SM.GetFamilyLadderForSpec(spec)
    local key = SM.FamilyKeyFromSpec(spec)
    if not key then
        return nil
    end
    return SM.GetFamilyLadder(key)
end

--- Merge all role/effect buckets that share a genus into one climb ladder.
--- Needed when L1 vendor seed is labeled ingredient and the watch plant is extender
--- (e.g. Gobswort Spore @1 vs Taut Gobswort @200).
function SM.GetGenusLadder(genus)
    genus = string.lower(tostring(genus or ""))
    if genus == "" then
        return nil
    end
    local all = SM.BuildAllFamilyLadders()
    local merged = nil
    local roles = {}
    for _, bucket in pairs(all) do
        if type(bucket) == "table" and tostring(bucket.genus or "") == genus then
            if type(merged) ~= "table" then
                merged = {
                    key = genus .. "|*|0",
                    genus = genus,
                    role = tostring(bucket.role or "unknown"),
                    effectId = tonumber(bucket.effectId) or 0,
                    rungs = {},
                    merged = true,
                }
            end
            local role = tostring(bucket.role or "")
            if role ~= "" and role ~= "unknown" then
                roles[role] = true
                -- Prefer a concrete cult role over "ingredient" for buy-path labeling.
                if merged.role == "unknown" or merged.role == "ingredient" then
                    merged.role = role
                end
            end
            if type(bucket.rungs) == "table" then
                local srcRole = tostring(bucket.role or "")
                local srcKnown = srcRole ~= "" and srcRole ~= "unknown"
                for i = 1, #bucket.rungs do
                    local src = bucket.rungs[i]
                    local rung = EnsureRung(merged, tonumber(src.skillReq) or 0)
                    if rung then
                        local seedUid = tonumber(src.seedUid) or 0
                        local plantUid = tonumber(src.plantUid) or 0
                        local curSeed = tonumber(rung.seedUid) or 0
                        local curPlant = tonumber(rung.plantUid) or 0
                        local wantReq = tonumber(rung.skillReq) or 0
                        local function uidReq(uid)
                            uid = tonumber(uid) or 0
                            if uid <= 0 then
                                return 0
                            end
                            local sample = BagSample(uid)
                            return ItemSkillReq(sample or {})
                        end
                        if seedUid > 0 then
                            if curSeed <= 0 then
                                rung.seedUid = seedUid
                                curSeed = seedUid
                            elseif curSeed ~= seedUid then
                                local curReq = uidReq(curSeed)
                                local newReq = uidReq(seedUid)
                                if newReq == wantReq and curReq ~= wantReq then
                                    rung.seedUid = seedUid
                                    curSeed = seedUid
                                elseif curReq ~= wantReq and newReq ~= wantReq and newReq > curReq then
                                    rung.seedUid = seedUid
                                    curSeed = seedUid
                                elseif srcKnown and curReq ~= wantReq and newReq == 0 then
                                    -- keep current
                                end
                            end
                        end
                        if plantUid > 0 then
                            -- Prefer plant from a seed-linked / known-role bucket over plant-only unknown.
                            if curPlant <= 0 or (seedUid > 0 and curSeed > 0 and srcKnown) then
                                rung.plantUid = plantUid
                            elseif curPlant <= 0 or (curSeed <= 0 and seedUid > 0) then
                                rung.plantUid = plantUid
                            end
                        end
                        if src.name and src.name ~= "" and (rung.name == nil or rung.name == "") then
                            rung.name = src.name
                        end
                    end
                end
            end
        end
    end
    if type(merged) ~= "table" then
        return nil
    end
    SortRungs(merged.rungs)
    -- Final heal: invent missing seeds, and replace wrong lower-tier seeds on
    -- higher plant rungs (exact-name crit links used to pin L150 onto L175).
    for i = 1, #merged.rungs do
        local rung = merged.rungs[i]
        local plantUid = tonumber(rung.plantUid) or 0
        local seedUid = tonumber(rung.seedUid) or 0
        local wantReq = tonumber(rung.skillReq) or 0
        local function seedReqOf(uid)
            uid = tonumber(uid) or 0
            if uid <= 0 then
                return 0
            end
            local sample = BagSample(uid)
            return ItemSkillReq(sample or {})
        end
        local curReq = seedReqOf(seedUid)
        local needResolve = plantUid > 0 and (
            seedUid <= 0
            or (wantReq > 0 and curReq > 0 and curReq < wantReq)
        )
        if needResolve and SM.ResolveSeedUidForPlant then
            if wantReq > 0 and curReq > 0 and curReq < wantReq then
                seedUid = 0
                rung.seedUid = 0
            end
            local resolved = tonumber(SM.ResolveSeedUidForPlant(plantUid, nil)) or 0
            if resolved > 0 then
                local sReq = seedReqOf(resolved)
                -- Reject lower-tier guesses on higher rungs (no exact-name exception).
                if sReq > 0 and wantReq > 0 and sReq < wantReq then
                    resolved = 0
                end
            end
            if resolved > 0 then
                rung.seedUid = resolved
                seedUid = resolved
            end
        end
        -- Bag seed at this genus + skillReq (covers Resolve miss when grow link
        -- never recorded the same-tier seed as a product of this plant).
        seedUid = tonumber(rung.seedUid) or 0
        if seedUid <= 0 and wantReq > 0 and merged.genus and merged.genus ~= "" then
            local Inv = StockPiler.Inventory
            if Inv and Inv.ForEachItem then
                local found = 0
                Inv.ForEachItem(function(item)
                    if found > 0 or type(item) ~= "table" then
                        return
                    end
                    if not IsBagSeedOrSporeItem(item) then
                        return
                    end
                    local uid = tonumber(item.uniqueID) or 0
                    if uid <= 0 or SM.IsSeedPacketUid(uid) then
                        return
                    end
                    if SM.GenusKeyFromName(item.name) ~= merged.genus then
                        return
                    end
                    if ItemSkillReq(item) == wantReq then
                        found = uid
                    end
                end)
                if found > 0 then
                    rung.seedUid = found
                end
            end
        end
    end
    if next(roles) ~= nil then
        -- Keep a stable preferred role for dump/status (extender/main/etc. over ingredient).
        local prefer = { "extender", "stabilizer", "multiplier", "stimulant", "main", "goldweed" }
        for i = 1, #prefer do
            if roles[prefer[i]] == true then
                merged.role = prefer[i]
                break
            end
        end
    end
    return merged
end

function SM.GetGenusLadderForSpec(spec)
    if type(spec) ~= "table" then
        return nil
    end
    local _, genus = SM.FamilyKeyFromSpec(spec)
    if not genus or genus == "" then
        genus = SM.GenusKeyFromName(spec.name)
    end
    if (not genus or genus == "") then
        local uid = tonumber(spec.uid) or tonumber(spec.uniqueID) or tonumber(spec.boundUid) or 0
        if uid > 0 then
            local sample = BagSample(uid)
            genus = SM.GenusKeyFromName(sample and sample.name)
        end
    end
    return SM.GetGenusLadder(genus)
end

--- Best owned (bag) seed on the ladder with skillReq <= climbCap.
--- Skips infertile climb seeds. Prefers highest skillReq then Eternal tier.
--- A seed UID may only score at a rung it legitimately owns: its own skillReq,
--- or a contiguous same-seedUid band above it (Fusk L1+L25 share 3010030).
--- Prevents L1 spore attached to a bogus L150 plant rung from beating L125.
function SM.BestOwnedSeedOnLadder(ladder, climbCap, opts)
    opts = type(opts) == "table" and opts or {}
    if type(ladder) ~= "table" or type(ladder.rungs) ~= "table" then
        return nil
    end
    climbCap = tonumber(climbCap) or 0
    if climbCap < 1 then
        return nil
    end
    local Inv = StockPiler.Inventory
    local function seedItemReq(seedUid)
        seedUid = tonumber(seedUid) or 0
        if seedUid <= 0 then
            return 0
        end
        local sample = BagSample(seedUid)
        local req = ItemSkillReq(sample or {})
        if req <= 0 and StockPiler.Items and StockPiler.Items.GetByUid then
            req = ItemSkillReq(StockPiler.Items.GetByUid(seedUid) or {})
        end
        return req
    end
    local function seedOwnsRung(seedUid, seedReq, rungReq)
        seedUid = tonumber(seedUid) or 0
        seedReq = tonumber(seedReq) or 0
        rungReq = tonumber(rungReq) or 0
        if seedUid <= 0 or rungReq < 1 then
            return false
        end
        if seedReq <= 0 or seedReq == rungReq then
            return true
        end
        if rungReq < seedReq then
            return false
        end
        -- Contiguous same-seedUid band from seedReq to rungReq (no other seed in between).
        for i = 1, #ladder.rungs do
            local r = ladder.rungs[i]
            local req = tonumber(r.skillReq) or 0
            local s = tonumber(r.seedUid) or 0
            if req > seedReq and req <= rungReq and s > 0 and s ~= seedUid then
                return false
            end
        end
        return true
    end
    local best = nil
    local bestScore = -1
    for i = 1, #ladder.rungs do
        local rung = ladder.rungs[i]
        local req = tonumber(rung.skillReq) or 0
        if req >= 1 and req <= climbCap then
            local seedUid = tonumber(rung.seedUid) or 0
            if seedUid > 0 and not (SM.IsInfertileSeed and SM.IsInfertileSeed(seedUid)) then
                local seedReq = seedItemReq(seedUid)
                if not seedOwnsRung(seedUid, seedReq, req) then
                    seedUid = 0
                end
            end
            if seedUid > 0 and not (SM.IsInfertileSeed and SM.IsInfertileSeed(seedUid)) then
                local count = Inv and Inv.CountByUid and tonumber(Inv.CountByUid(seedUid)) or 0
                if count > 0 then
                    if opts.mainsOnly == true then
                        local role = tostring(ladder.role or "")
                        if role ~= "" and role ~= "main" and role ~= "unknown" then
                            count = 0
                        end
                    end
                end
                if count > 0 then
                    local tier = SeedReplantTier(seedUid)
                    -- Score by the seed's real tier when known, not a bogus higher rung.
                    local scoreReq = seedItemReq(seedUid)
                    if scoreReq < 1 then
                        scoreReq = req
                    end
                    local score = (scoreReq * 100000) + (tier * 1000) + count
                    if score > bestScore then
                        bestScore = score
                        best = {
                            seedUid = seedUid,
                            plantUid = tonumber(rung.plantUid) or 0,
                            skillReq = scoreReq,
                            count = count,
                            familyKey = ladder.key,
                            genus = ladder.genus,
                            role = ladder.role,
                        }
                    end
                end
            end
        end
    end
    -- Bag seeds of this genus whose skillReq matches a rung (or any owned skill <= cap)
    -- even when the ladder rung still has seedUid=0 (Wolfpaw Spore before grow link).
    local genus = string.lower(tostring(ladder.genus or ""))
    if genus ~= "" and Inv and Inv.ForEachItem then
        local rungPlantByReq = {}
        for i = 1, #ladder.rungs do
            local r = ladder.rungs[i]
            local req = tonumber(r.skillReq) or 0
            if req >= 1 then
                rungPlantByReq[req] = tonumber(r.plantUid) or 0
            end
        end
        Inv.ForEachItem(function(item)
            if type(item) ~= "table" or not IsBagSeedOrSporeItem(item) then
                return
            end
            local uid = tonumber(item.uniqueID) or tonumber(item.uid) or 0
            if uid <= 0 or (SM.IsSeedPacketUid and SM.IsSeedPacketUid(uid)) then
                return
            end
            if SM.IsInfertileSeed and SM.IsInfertileSeed(uid) then
                return
            end
            if SM.GenusKeyFromName(item.name) ~= genus then
                return
            end
            local sReq = ItemSkillReq(item)
            if sReq < 1 or sReq > climbCap then
                return
            end
            if opts.mainsOnly == true then
                local role = tostring(ladder.role or "")
                if role ~= "" and role ~= "main" and role ~= "unknown" then
                    return
                end
            end
            local count = Inv.CountByUid and tonumber(Inv.CountByUid(uid)) or 0
            if count < 1 then
                return
            end
            local tier = SeedReplantTier(uid)
            local score = (sReq * 100000) + (tier * 1000) + count
            if score > bestScore then
                bestScore = score
                best = {
                    seedUid = uid,
                    plantUid = rungPlantByReq[sReq] or 0,
                    skillReq = sReq,
                    count = count,
                    familyKey = ladder.key,
                    genus = ladder.genus,
                    role = ladder.role,
                }
            end
        end)
    end
    return best
end

--- Refinable plant on the ladder with skillReq > ownedSeedReq and <= climbCap.
function SM.BestUpgradePlantOnLadder(ladder, climbCap, ownedSeedReq, opts)
    opts = type(opts) == "table" and opts or {}
    if type(ladder) ~= "table" or type(ladder.rungs) ~= "table" then
        return nil
    end
    climbCap = tonumber(climbCap) or 0
    ownedSeedReq = tonumber(ownedSeedReq) or 0
    if climbCap < 1 then
        return nil
    end
    local Refine = StockPiler.Refine
    local Items = StockPiler.Items
    local best = nil
    local bestReq = -1
    for i = 1, #ladder.rungs do
        local rung = ladder.rungs[i]
        local req = tonumber(rung.skillReq) or 0
        local plantUid = tonumber(rung.plantUid) or 0
        if plantUid > 0 and req > ownedSeedReq and req <= climbCap then
            if opts.mainsOnly == true then
                local role = tostring(ladder.role or "")
                if role ~= "" and role ~= "main" and role ~= "unknown" then
                    plantUid = 0
                end
            end
            if plantUid > 0 and Refine and Refine.CountRefinablePlants then
                local spec = Items and Items.ToSpec and Items.ToSpec(plantUid) or nil
                local refinable = tonumber(Refine.CountRefinablePlants(plantUid, spec)) or 0
                if refinable > 0 and req > bestReq then
                    local seedUid = tonumber(rung.seedUid) or 0
                    if seedUid <= 0 and SM.ResolveSeedUidForPlant then
                        seedUid = tonumber(SM.ResolveSeedUidForPlant(plantUid, nil)) or 0
                    end
                    bestReq = req
                    best = {
                        seedUid = seedUid,
                        plantUid = plantUid,
                        skillReq = req,
                        refinable = refinable,
                        familyKey = ladder.key,
                        genus = ladder.genus,
                        role = ladder.role,
                        upgrade = true,
                    }
                end
            end
        end
    end
    return best
end

--- Lowest buyable seed rung on ladder (usually skillReq 1), skipping infertile.
function SM.LowestBuySeedOnLadder(ladder)
    if type(ladder) ~= "table" or type(ladder.rungs) ~= "table" then
        return nil
    end
    for i = 1, #ladder.rungs do
        local rung = ladder.rungs[i]
        local seedUid = tonumber(rung.seedUid) or 0
        local req = tonumber(rung.skillReq) or 0
        if seedUid > 0 and req >= 1 and not (SM.IsInfertileSeed and SM.IsInfertileSeed(seedUid)) then
            return {
                seedUid = seedUid,
                plantUid = tonumber(rung.plantUid) or 0,
                skillReq = req,
                familyKey = ladder.key,
                genus = ladder.genus,
                role = ladder.role,
            }
        end
    end
    return nil
end

function SM.DumpFamilies(emit)
    emit = emit or print
    local all = SM.BuildAllFamilyLadders()
    local keys = {}
    for k in pairs(all) do
        keys[#keys + 1] = k
    end
    table.sort(keys)
    emit("--- seed families (" .. tostring(#keys) .. ") ---")
    for i = 1, #keys do
        local bucket = all[keys[i]]
        local parts = {}
        for r = 1, #bucket.rungs do
            local rung = bucket.rungs[r]
            parts[#parts + 1] = string.format(
                "%d:s%d/p%d",
                tonumber(rung.skillReq) or 0,
                tonumber(rung.seedUid) or 0,
                tonumber(rung.plantUid) or 0
            )
        end
        emit(string.format(
            "  %s [%s/%s/fx%s] %s",
            tostring(bucket.key),
            tostring(bucket.genus),
            tostring(bucket.role),
            tostring(bucket.effectId),
            table.concat(parts, " ")
        ))
    end
end
