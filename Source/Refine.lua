----------------------------------------------------------------
-- StockPiler Refine -- buffer flags + intents + IssueOne
-- Policy and executor live here. Callees above callers.
----------------------------------------------------------------

StockPiler = StockPiler or {}
StockPiler.Refine = StockPiler.Refine or {}
local Refine = StockPiler.Refine

Refine.MAX_OUTSTANDING_PER_SEED = 6
Refine.MAX_PENDING_PER_PLANT = 6
Refine.SEED_BUFFER_FAIL_COOLDOWN_SEC = 45
Refine.OUTSTANDING_TTL_SEC = 30
Refine.MAX_USES_PER_ISSUE = 1

Refine._refineDirty = false
Refine._refineDirtyReason = nil
Refine._refineDueGen = 0
Refine._refineWaitTicks = 0
Refine._intentCacheKey = nil
Refine._intentCache = nil
Refine._emptyIntentSnapGen = nil
Refine._emptyIntentDueGen = nil
Refine._bufferFlags = nil
Refine._bufferFlagsKey = nil
Refine._bufferFlagsStructKey = nil
Refine._pendingByPlant = Refine._pendingByPlant or {}
Refine._pendingSeedByPlant = Refine._pendingSeedByPlant or {}
Refine._issuedSeedThisTick = nil
Refine._seedBufferCooldownUntil = Refine._seedBufferCooldownUntil or {}
Refine._bagIndex = nil
Refine._bagIndexGen = -1
Refine._reconcileSnapGen = -1
Refine._onUpdateFrame = -1
Refine._liveSeedBaseline = Refine._liveSeedBaseline or {}
Refine._blockedVendorNotified = false
Refine._blockedInteractionNotified = false

----------------------------------------------------------------
-- Helpers
----------------------------------------------------------------

local function NowSec()
    return StockPiler.Util and StockPiler.Util.NowSec and StockPiler.Util.NowSec() or 0
end

local function LogRefine(msg)
    if StockPiler.Debug and StockPiler.Debug.LogOp then
        StockPiler.Debug.LogOp("refine", msg)
    end
end

local function CraftingBackpackType()
    if EA_Window_Backpack and EA_Window_Backpack.TYPE_CRAFTING then
        return EA_Window_Backpack.TYPE_CRAFTING
    end
    return 4
end

local function SeedBufferCooldownCacheToken()
    local parts = {}
    local now = NowSec()
    for seedUid, untilT in pairs(Refine._seedBufferCooldownUntil) do
        untilT = tonumber(untilT) or 0
        if untilT > now then
            parts[#parts + 1] = tostring(seedUid) .. "=" .. tostring(math.floor(untilT))
        end
    end
    table.sort(parts)
    return table.concat(parts, ",")
end

local function IsSeedBufferOnCooldown(seedUid)
    seedUid = tonumber(seedUid) or 0
    if seedUid <= 0 then
        return false
    end
    local untilT = tonumber(Refine._seedBufferCooldownUntil[seedUid]) or 0
    if untilT <= 0 then
        return false
    end
    if NowSec() >= untilT then
        Refine._seedBufferCooldownUntil[seedUid] = nil
        return false
    end
    return true
end

local function ArmSeedBufferFailCooldown(seedUid)
    seedUid = tonumber(seedUid) or 0
    if seedUid <= 0 then
        return
    end
    local untilT = NowSec() + (tonumber(Refine.SEED_BUFFER_FAIL_COOLDOWN_SEC) or 45)
    local cur = tonumber(Refine._seedBufferCooldownUntil[seedUid]) or 0
    if untilT > cur then
        Refine._seedBufferCooldownUntil[seedUid] = untilT
    end
    Refine.InvalidateIntentCache()
end

local function BufferFlagsStructuralKey()
    local gardenGen = 0
    local Garden = StockPiler.Garden
    if Garden then
        gardenGen = tonumber(Garden.GetPlanGen and Garden.GetPlanGen() or Garden.GetGen and Garden.GetGen()) or 0
    end
    local watchGen = StockPiler.Watch and StockPiler.Watch.GetGen and StockPiler.Watch.GetGen() or 0
    local buffer = StockPiler.Watch and StockPiler.Watch.GetSeedBufferMin and StockPiler.Watch.GetSeedBufferMin() or 5
    local outstanding = 0
    local RP = StockPiler.RefinePipeline
    if RP and RP.GetOutstandingSum then
        outstanding = tonumber(RP.GetOutstandingSum()) or 0
    end
    return tostring(gardenGen) .. ":" .. tostring(watchGen)
        .. ":" .. tostring(buffer) .. ":" .. tostring(outstanding)
end

local function BufferFlagsCacheKey()
    local snapGen = 0
    if StockPiler.Inventory and StockPiler.Inventory.GetSnapGen then
        snapGen = tonumber(StockPiler.Inventory.GetSnapGen()) or 0
    end
    return tostring(snapGen) .. ":" .. BufferFlagsStructuralKey()
end

local function IntentCacheKey()
    local Watch = StockPiler.Watch
    local RP = StockPiler.RefinePipeline
    local Garden = StockPiler.Garden
    local gardenGen = 0
    if Garden then
        gardenGen = tonumber(Garden.GetPlanGen and Garden.GetPlanGen() or Garden.GetGen and Garden.GetGen()) or 0
    end
    -- NO snapGen. Include active cooldowns + buffer enabled.
    -- Cult/Apo + TargetMaxSkill: empty-intent latch must bust on tier-floor
    -- skill-ups (bags unchanged) or SkillUp refine stalls at 175/200 crossings.
    local bufferOn = Watch and Watch.IsSeedBufferEnabled and Watch.IsSeedBufferEnabled() == true
    local Caps = StockPiler.TradeSkillCaps
    local cult = Caps and Caps.GetCultSkill and tonumber(Caps.GetCultSkill()) or 0
    local apo = Caps and Caps.GetApoSkill and tonumber(Caps.GetApoSkill()) or 0
    local targetMax = 0
    local SkillUp = StockPiler.SkillUp
    if SkillUp and SkillUp.TargetMaxSkill then
        targetMax = tonumber(SkillUp.TargetMaxSkill()) or 0
    end
    return table.concat({
        tostring(Watch and Watch.GetGen and Watch.GetGen() or 0),
        tostring(RP and RP.GetGen and RP.GetGen() or 0),
        tostring(gardenGen),
        SeedBufferCooldownCacheToken(),
        bufferOn and "1" or "0",
        "tm:" .. tostring(targetMax),
        "c:" .. tostring(cult),
        "a:" .. tostring(apo),
    }, ":")
end

local function LiveSeedCount(seedUid)
    seedUid = tonumber(seedUid) or 0
    if seedUid <= 0 then
        return 0
    end
    local Inv = StockPiler.Inventory
    if Inv and Inv.CountByUid then
        return tonumber(Inv.CountByUid(seedUid)) or 0
    end
    return 0
end

--- Pending plant + established garden rows (seeds in ground are refundable until harvest).
local function CountInGround(seedUid)
    local Grow = StockPiler.Grow
    if Grow and Grow.CountSeedPlotCredit then
        return tonumber(Grow.CountSeedPlotCredit(seedUid)) or 0
    end
    if Grow and Grow.CountInGroundSeeds then
        return tonumber(Grow.CountInGroundSeeds(seedUid)) or 0
    end
    return 0
end

--- Buffer-settle refine: hold only when this seed is still in plots AND there is
--- nowhere left to plant. Empty plots need seeds now; GetSeedBudget headroom
--- already counts in-ground credit, so refine-to-fill must not wait on harvest.
--- (0.3.187 deferred whenever ground>0, which starved empty plots until the
--- first replant harvested - second cycle then refined and filled.)
local function SeedBufferSettleDeferred(seedUid)
    seedUid = tonumber(seedUid) or 0
    if seedUid <= 0 then
        return true
    end
    if CountInGround(seedUid) <= 0 then
        return false
    end
    local Grow = StockPiler.Grow
    if Grow and Grow.HasEmptyPlot and Grow.HasEmptyPlot() == true then
        return false
    end
    if Grow and Grow.CountEmptyPlots and (tonumber(Grow.CountEmptyPlots()) or 0) > 0 then
        return false
    end
    return true
end

local function OpaqueCredit(seedUid, bag)
    local SM = StockPiler.SeedMap
    if SM and SM.EffectiveSeedCredit then
        return tonumber(SM.EffectiveSeedCredit(seedUid, bag)) or bag
    end
    return bag
end

local function ItemLooksRefinable(item)
    if type(item) ~= "table" then
        return false
    end
    local SM = StockPiler.SeedMap
    if SM and SM.ItemLooksLikeRefinablePlant then
        return SM.ItemLooksLikeRefinablePlant(item) == true
    end
    return item.isRefinable == true
end

local function EnsureBagIndex()
    local Inv = StockPiler.Inventory
    local gen = Inv and Inv.GetSnapGen and Inv.GetSnapGen() or 0
    if Refine._bagIndexGen == gen and type(Refine._bagIndex) == "table" then
        return Refine._bagIndex
    end
    local index = { entries = {}, byPlantUid = {} }
    if Inv and Inv.ForEachItem then
        -- Inventory.ForEachItem passes (item [, bagKey, slot]) - not (bagKey, slot, item).
        Inv.ForEachItem(function(item, bagKey, slot)
            if ItemLooksRefinable(item) then
                local plantUid = tonumber(item.uniqueID) or 0
                local stack = tonumber(item.stackCount) or tonumber(item.StackCount) or 1
                slot = tonumber(slot) or tonumber(item.slotNumber) or tonumber(item.slot) or 0
                bagKey = tostring(bagKey or item.bagKey or "craft")
                if stack < 1 then
                    stack = 1
                end
                index.entries[#index.entries + 1] = {
                    bagKey = bagKey,
                    slot = slot,
                    item = item,
                    plantUid = plantUid,
                    stack = stack,
                }
                if plantUid > 0 then
                    local row = index.byPlantUid[plantUid]
                    if type(row) ~= "table" then
                        row = { count = 0, bestSlot = slot, bestItem = item, bestBagKey = bagKey, bestStack = stack }
                        index.byPlantUid[plantUid] = row
                    end
                    row.count = (tonumber(row.count) or 0) + stack
                    if stack <= (tonumber(row.bestStack) or 9999) then
                        row.bestSlot = slot
                        row.bestItem = item
                        row.bestBagKey = bagKey
                        row.bestStack = stack
                    end
                end
            end
        end)
    end
    Refine._bagIndex = index
    Refine._bagIndexGen = gen
    return index
end

local function CountRefinableForSpec(plantUid, spec)
    plantUid = tonumber(plantUid) or 0
    local index = EnsureBagIndex()
    if plantUid > 0 then
        local row = index.byPlantUid[plantUid]
        return type(row) == "table" and (tonumber(row.count) or 0) or 0
    end
    if type(spec) ~= "table" then
        return 0
    end
    local MS = StockPiler.MaterialSpec
    local SM = StockPiler.SeedMap
    local n = 0
    for i = 1, #index.entries do
        local e = index.entries[i]
        local item = e.item
        local match = false
        if MS and MS.FromItemDataCached and MS.Matches then
            local itemSpec = MS.FromItemDataCached(item)
            match = MS.Matches(itemSpec, spec) == true
        elseif SM and SM.PlantMatchesSpec then
            match = SM.PlantMatchesSpec(item, spec) == true
        end
        if match then
            n = n + (tonumber(e.stack) or 0)
        end
    end
    return n
end

local function BagTypeForKey(bagKey)
    local bagType = CraftingBackpackType()
    if bagKey == "main" and EA_Window_Backpack and EA_Window_Backpack.TYPE_INVENTORY then
        bagType = EA_Window_Backpack.TYPE_INVENTORY
    end
    return bagType
end

local function FindPlantSlot(plantUid, spec)
    plantUid = tonumber(plantUid) or 0
    local index = EnsureBagIndex()
    if plantUid > 0 then
        local row = index.byPlantUid[plantUid]
        if type(row) == "table" and (tonumber(row.bestSlot) or 0) > 0 then
            return tonumber(row.bestSlot), row.bestItem, BagTypeForKey(row.bestBagKey)
        end
    end
    local MS = StockPiler.MaterialSpec
    for i = 1, #index.entries do
        local e = index.entries[i]
        local match = false
        if MS and MS.FromItemDataCached and MS.Matches and type(spec) == "table" then
            match = MS.Matches(MS.FromItemDataCached(e.item), spec) == true
        elseif plantUid > 0 and (tonumber(e.plantUid) or 0) == plantUid then
            match = true
        end
        if match then
            return tonumber(e.slot), e.item, BagTypeForKey(e.bagKey)
        end
    end
    return 0, nil, CraftingBackpackType()
end

--- Highest-stack refinable slot matching plantUid/spec (resin convert prefers richest stack).
local function FindPlantSlotHighest(plantUid, spec)
    plantUid = tonumber(plantUid) or 0
    local index = EnsureBagIndex()
    local bestSlot, bestItem, bestBagKey, bestStack = 0, nil, nil, -1
    local MS = StockPiler.MaterialSpec
    for i = 1, #index.entries do
        local e = index.entries[i]
        local match = false
        if plantUid > 0 and (tonumber(e.plantUid) or 0) == plantUid then
            match = true
        elseif MS and MS.FromItemDataCached and MS.Matches and type(spec) == "table" then
            match = MS.Matches(MS.FromItemDataCached(e.item), spec) == true
        end
        if match and (tonumber(e.stack) or 0) > bestStack then
            bestStack = tonumber(e.stack) or 0
            bestSlot = tonumber(e.slot) or 0
            bestItem = e.item
            bestBagKey = e.bagKey
        end
    end
    if bestSlot > 0 then
        return bestSlot, bestItem, BagTypeForKey(bestBagKey)
    end
    return 0, nil, CraftingBackpackType()
end

local function DemandRowSurplus(row)
    if type(row) ~= "table" then
        return 0
    end
    local have = tonumber(row.have) or 0
    local brew = tonumber(row.brewAbsolute)
    if brew == nil then
        brew = tonumber(row.absolute) or 0
    end
    -- Do not refine plant stock below an enabled plant-watch floor.
    local floor = 0
    local Watch = StockPiler.Watch
    local plantUid = tonumber(row.plantUid) or 0
    if plantUid > 0 and Watch and Watch.PlantKeyFromUid and Watch.GetPlantWatch then
        local plantKey = Watch.PlantKeyFromUid(plantUid)
        local pw = Watch.GetPlantWatch(plantKey)
        if type(pw) == "table" and pw.enabled == true then
            floor = tonumber(pw.targetStock) or 0
        end
    end
    local reserved = math.max(brew, floor)
    local surplus = have - reserved
    if surplus < 0 then
        return 0
    end
    return surplus
end

local function RowSharesPotionKeys(row, potionKeys)
    if type(row) ~= "table" or type(potionKeys) ~= "table" then
        return false
    end
    if type(row.watchDetails) == "table" then
        for i = 1, #row.watchDetails do
            local detail = row.watchDetails[i]
            if type(detail) == "table" and detail.potionKey ~= nil and potionKeys[detail.potionKey] == true then
                return true
            end
        end
    end
    if type(row.potionKeys) == "table" then
        for k, v in pairs(row.potionKeys) do
            if v == true and potionKeys[k] == true then
                return true
            end
        end
    end
    return false
end

local function CandidateFromDemandRow(row, SM, tier, resinSkillLevel)
    if type(row) ~= "table" or type(row.spec) ~= "table" then
        return nil
    end
    if row.isByproduct == true then
        return nil
    end
    if not (SM and SM.IsGrowableSpec and SM.IsGrowableSpec(row.spec) == true) then
        return nil
    end
    resinSkillLevel = tonumber(resinSkillLevel)
    if resinSkillLevel ~= nil then
        local plantLv = tonumber(row.spec.skillLevel) or 0
        if plantLv ~= resinSkillLevel then
            return nil
        end
    end
    local surplus = DemandRowSurplus(row)
    if surplus <= 0 then
        return nil
    end
    local seedUid = tonumber(row.seedUid) or 0
    local plantUid = tonumber(row.plantUid) or 0
    if seedUid <= 0 and SM.ResolveSeedForSpec then
        local seed = SM.ResolveSeedForSpec(row.spec)
        if type(seed) == "table" then
            seedUid = tonumber(seed.uniqueID or seed.uid) or 0
            if plantUid <= 0 then
                plantUid = tonumber(seed.plantUid) or 0
            end
        end
    end
    if plantUid <= 0 and SM.FindPlantUidForSpec then
        plantUid = tonumber(SM.FindPlantUidForSpec(row.spec)) or 0
    end
    local refinable = CountRefinableForSpec(plantUid, row.spec)
    if refinable <= 0 then
        return nil
    end
    local slot, item, bagType = FindPlantSlotHighest(plantUid, row.spec)
    if slot <= 0 or type(item) ~= "table" then
        return nil
    end
    if plantUid <= 0 then
        plantUid = tonumber(item.uniqueID) or 0
    end
    if resinSkillLevel ~= nil then
        local itemLv = tonumber(item.craftingSkillRequirement)
            or tonumber(item.skillLevel)
            or tonumber(row.spec.skillLevel)
            or 0
        if itemLv ~= resinSkillLevel then
            return nil
        end
    end
    return {
        tier = tier,
        spec = row.spec,
        specKey = row.specKey,
        seedUid = seedUid,
        plantUid = plantUid,
        surplus = surplus,
        refinable = refinable,
        slot = slot,
        item = item,
        bagType = bagType,
        score = refinable,
    }
end

local function LineBufferShort(line)
    if type(line) ~= "table" then
        return false
    end
    local seedUid = tonumber(line.seedUid) or 0
    local buffer = StockPiler.Watch and StockPiler.Watch.GetSeedBufferMin and StockPiler.Watch.GetSeedBufferMin() or 5
    if seedUid <= 0 then
        -- Plant-only cushion (Savage Marshroot s0): bag plant count is the credit.
        local plantUid = tonumber(line.plantUid) or 0
        if plantUid <= 0 then
            return false
        end
        local Inv = StockPiler.Inventory
        local have = Inv and Inv.CountByUid and tonumber(Inv.CountByUid(plantUid)) or 0
        return have < buffer
    end
    local budget = Refine.GetSeedBudget(seedUid)
    return (tonumber(budget.credit) or 0) < buffer
end

local function LineConvertiblePending(line)
    if type(line) ~= "table" then
        return false
    end
    local seedUid = tonumber(line.seedUid) or 0
    -- Plant-only cushion (s0): no refine->seed path; Upgrade Seeds owns SM fishing.
    if seedUid <= 0 then
        return false
    end
    if IsSeedBufferOnCooldown(seedUid) then
        return false
    end
    -- Do not treat as pending settle while this seed is still in plots and the
    -- garden is full (SeedBufferSettleDeferred). Empty plots still want refine.
    if SeedBufferSettleDeferred(seedUid) then
        return false
    end
    -- Pending buffer refine = plants waiting to fill a short buffer.
    -- Leftover plants after the buffer is met must not hold auto-brew.
    if not LineBufferShort(line) then
        return false
    end
    local refinable = CountRefinableForSpec(line.plantUid, line.spec)
    return refinable > 0
end

local function PeekBufferFlagsSticky()
    if type(Refine._bufferFlags) == "table" then
        return Refine._bufferFlags
    end
    if type(Refine._bufferFlagsSticky) == "table" then
        return Refine._bufferFlagsSticky
    end
    return { pending = false, short = false }
end

local function EnsureBufferFlagsCached()
    local Watch = StockPiler.Watch
    if not (Watch and Watch.IsSeedBufferEnabled and Watch.IsSeedBufferEnabled() == true) then
        Refine._bufferFlags = { pending = false, short = false }
        Refine._bufferFlagsSticky = Refine._bufferFlags
        Refine._bufferFlagsKey = nil
        Refine._bufferFlagsStructKey = nil
        return Refine._bufferFlags
    end
    -- Hard gate: only Scheduler EnsureBufferFlagsNow may rebuild (libperf Orch trails).
    if Refine._allowBufferFlagsRebuild ~= true then
        local Sch = StockPiler.Scheduler
        local quiet = Sch and (
            (Sch.IsSuppressed and Sch.IsSuppressed() == true)
            or (Sch.IsOrchDecisionHold and Sch.IsOrchDecisionHold() == true)
        )
        local Orch = StockPiler.Orchestrator
        local Brew = StockPiler.Brew
        local brewHold = (Orch and Orch.IsBrewSessionActive and Orch.IsBrewSessionActive() == true)
            or (Brew and Brew.IsBusy and Brew.IsBusy() == true)
        if quiet or brewHold then
            return PeekBufferFlagsSticky()
        end
        local key = BufferFlagsCacheKey()
        if Refine._bufferFlagsKey == key and type(Refine._bufferFlags) == "table" then
            return Refine._bufferFlags
        end
        local structKey = BufferFlagsStructuralKey()
        if type(Refine._bufferFlags) == "table"
            and Refine._bufferFlagsStructKey == structKey
        then
            return Refine._bufferFlags
        end
        Refine.RequestBufferFlagsRebuild()
        return PeekBufferFlagsSticky()
    end
    local key = BufferFlagsCacheKey()
    local frame = tonumber(StockPiler.FrameCounter) or 0
    -- Same-frame: after one rebuild, ignore snapGen-only misses.
    if frame > 0 and Refine._bufferFlagsFrame == frame and type(Refine._bufferFlags) == "table" then
        if Refine._bufferFlagsKey == key then
            return Refine._bufferFlags
        end
        local structKey = BufferFlagsStructuralKey()
        if Refine._bufferFlagsStructKey == structKey then
            return Refine._bufferFlags
        end
    end
    local RP = StockPiler.RefinePipeline
    local hasOut = RP and RP.HasOutstanding and RP.HasOutstanding() == true
    local fullGarden = not (StockPiler.Grow and StockPiler.Grow.HasEmptyPlot and StockPiler.Grow.HasEmptyPlot())
    if hasOut and fullGarden and type(Refine._bufferFlags) == "table" then
        if Refine._bufferFlagsKey == key then
            Refine._bufferFlagsFrame = frame
            return Refine._bufferFlags
        end
    end
    if Refine._bufferFlagsKey == key and type(Refine._bufferFlags) == "table" then
        Refine._bufferFlagsFrame = frame
        return Refine._bufferFlags
    end
    local Perf = StockPiler.Perf
    if Perf and Perf.Begin then
        Perf.Begin("Refine.BufferFlags")
    end
    local RS = StockPiler.RecipeSpec
    local lines = (RS and RS.CollectAutoGrowSeedLines and RS.CollectAutoGrowSeedLines()) or {}
    local pending, short = false, false
    for i = 1, #lines do
        if LineConvertiblePending(lines[i]) then
            pending = true
        end
        if LineBufferShort(lines[i]) then
            short = true
        end
        if pending and short then
            break
        end
    end
    Refine._bufferFlags = { pending = pending, short = short }
    Refine._bufferFlagsSticky = Refine._bufferFlags
    Refine._bufferFlagsKey = key
    Refine._bufferFlagsStructKey = BufferFlagsStructuralKey()
    Refine._bufferFlagsFrame = frame
    if Perf and Perf.End then
        Perf.End("Refine.BufferFlags")
    end
    return Refine._bufferFlags
end

local function ReasonPriority(reason)
    if reason == "plant-need" then
        return 0
    end
    if reason == "resin-need" then
        return 1
    end
    return 2
end

local function AppendIntent(intents, line, reason, uses, budget, extra)
    uses = tonumber(uses) or 0
    if uses < 1 then
        return
    end
    local seedUid = tonumber(line.seedUid) or 0
    local plantUid = tonumber(line.plantUid) or 0
    local slot, item, bagType = FindPlantSlot(plantUid, line.spec)
    if slot <= 0 or type(item) ~= "table" then
        return
    end
    local intent = {
        reason = reason,
        spec = line.spec,
        seedUid = seedUid,
        plantUid = plantUid,
        uses = uses,
        headroom = type(budget) == "table" and (tonumber(budget.headroom) or 0) or 0,
        slot = slot,
        item = item,
        bagType = bagType,
        emergencyPlant = false,
    }
    if type(extra) == "table" then
        for k, v in pairs(extra) do
            intent[k] = v
        end
    end
    intents[#intents + 1] = intent
end

local function ClearOrphanPending()
    local RP = StockPiler.RefinePipeline
    for plantUid, pending in pairs(Refine._pendingByPlant) do
        pending = tonumber(pending) or 0
        if pending > 0 then
            local seedUid = tonumber(Refine._pendingSeedByPlant[plantUid]) or 0
            local outstanding = RP and RP.GetOutstanding and RP.GetOutstanding(seedUid) or 0
            if outstanding <= 0 then
                Refine._pendingByPlant[plantUid] = nil
                Refine._pendingSeedByPlant[plantUid] = nil
            end
        end
    end
end

----------------------------------------------------------------
-- Public: buffer / cache / gates
----------------------------------------------------------------

function Refine.IsEnabled()
    return StockPiler.Grow and StockPiler.Grow.IsEnabled and StockPiler.Grow.IsEnabled() == true
end

function Refine.InvalidateIntentCache()
    Refine._intentCacheKey = nil
    Refine._intentCache = nil
    Refine._emptyIntentSnapGen = nil
    Refine._emptyIntentDueGen = nil
end

--- Snap gen can stay put while stacks slide inside the craft bag. The slot
--- index built for that gen then points at the wrong item forever.
function Refine.InvalidateBagIndex()
    Refine._bagIndex = nil
    Refine._bagIndexGen = -1
end

function Refine.InvalidateBufferFlags()
    -- Keep sticky for orch peek; latch idle rebuild (never sync on Orch plant frame).
    if type(Refine._bufferFlags) == "table" then
        Refine._bufferFlagsSticky = Refine._bufferFlags
    end
    Refine._bufferFlagsKey = nil
    Refine._bufferFlags = nil
    Refine._bufferFlagsStructKey = nil
    Refine._bufferFlagsFrame = nil
    Refine.RequestBufferFlagsRebuild()
end

function Refine.RequestBufferFlagsRebuild()
    local Sch = StockPiler.Scheduler
    if Sch and Sch.RequestBufferFlagsRebuild then
        Sch.RequestBufferFlagsRebuild()
    end
end

function Refine.EnsureBufferFlagsNow()
    Refine._allowBufferFlagsRebuild = true
    local ok, result = pcall(EnsureBufferFlagsCached)
    Refine._allowBufferFlagsRebuild = false
    if ok == true then
        return result
    end
    return PeekBufferFlagsSticky()
end

--- Last cached pending flag without rebuilding (snap wake path).
--- Returns false when cache is missing (wake must not suppress work via true-only checks).
function Refine.PeekCachedBufferPending()
    local flags = Refine._bufferFlags
    if type(flags) ~= "table" then
        return false
    end
    return flags.pending == true
end

--- Freshness-aware peek for orch work gates.
--- Returns true/false on a cache hit whose key still matches; nil when missing or stale
--- so callers fall through to HasPendingBufferRefine().
function Refine.PeekFreshBufferPending()
    local flags = Refine._bufferFlags
    if type(flags) ~= "table" then
        return nil
    end
    local key = BufferFlagsCacheKey()
    if Refine._bufferFlagsKey ~= key then
        return nil
    end
    return flags.pending == true
end

function Refine.PeekCachedIntents()
    local key = IntentCacheKey()
    if Refine._intentCacheKey == key and type(Refine._intentCache) == "table" then
        return Refine._intentCache
    end
    return nil
end

function Refine.MarkRefineDue(reason)
    Refine._refineDirty = true
    -- One generation per call. CollectIntents busts an empty latch once for
    -- this value, then stays warm while _refineDirty is still set.
    Refine._refineDueGen = (tonumber(Refine._refineDueGen) or 0) + 1
    reason = tostring(reason or "")
    if reason == "harvest" then
        Refine._refineDirtyReason = "harvest"
    elseif Refine._refineDirtyReason ~= "harvest" then
        Refine._refineDirtyReason = (reason ~= "" and reason) or "generic"
    end
end

function Refine.RefineCheckDue()
    local wait = tonumber(Refine._refineWaitTicks) or 0
    if Refine._refineDirty == true then
        if Refine._refineDirtyReason == "harvest" then
            return true
        end
        return wait <= 0
    end
    return wait <= 0
end

function Refine.DecayRefineWaitTicks()
    local wait = tonumber(Refine._refineWaitTicks) or 0
    if wait > 0 then
        Refine._refineWaitTicks = wait - 1
    end
end

function Refine.HasPendingBufferRefine()
    local Watch = StockPiler.Watch
    if not (Watch and Watch.IsSeedBufferEnabled and Watch.IsSeedBufferEnabled() == true) then
        return false
    end
    local RS = StockPiler.RecipeSpec
    if not (RS and RS.CollectAutoGrowSeedLines) then
        return false
    end
    return EnsureBufferFlagsCached().pending == true
end

function Refine.HasAnyBufferShort()
    local Watch = StockPiler.Watch
    if not (Watch and Watch.IsSeedBufferEnabled and Watch.IsSeedBufferEnabled() == true) then
        return false
    end
    local RS = StockPiler.RecipeSpec
    if not (RS and RS.CollectAutoGrowSeedLines) then
        return false
    end
    return EnsureBufferFlagsCached().short == true
end

function Refine.IsSeedBufferSatisfied()
    local Watch = StockPiler.Watch
    if not (Watch and Watch.IsSeedBufferEnabled and Watch.IsSeedBufferEnabled() == true) then
        return true
    end
    if Refine.HasAnyBufferShort() == true then
        return false
    end
    if Refine.HasPendingBufferRefine() == true then
        return false
    end
    return true
end

function Refine.GetSeedBudget(seedUid)
    seedUid = tonumber(seedUid) or 0
    if seedUid <= 0 then
        return {
            live = 0,
            ground = 0,
            outstanding = 0,
            credit = 0,
            headroom = 0,
            bufferMin = 0,
            unsettled = true,
        }
    end
    local live = OpaqueCredit(seedUid, LiveSeedCount(seedUid))
    local ground = CountInGround(seedUid)
    local outstanding = 0
    local RP = StockPiler.RefinePipeline
    if RP and RP.GetOutstanding then
        outstanding = tonumber(RP.GetOutstanding(seedUid)) or 0
    end
    local credit = live + ground + outstanding
    local buffer = 0
    local Watch = StockPiler.Watch
    if Watch and Watch.IsSeedBufferEnabled and Watch.IsSeedBufferEnabled() == true then
        buffer = Watch.GetSeedBufferMin and tonumber(Watch.GetSeedBufferMin()) or 5
    end
    local headroom = math.max(0, buffer - credit)
    return {
        live = live,
        ground = ground,
        outstanding = outstanding,
        credit = credit,
        headroom = headroom,
        bufferMin = buffer,
        -- True while plots still hold this seed (refundable / outcome unknown).
        unsettled = ground > 0,
    }
end

function Refine.SeedBufferSettleDeferred(seedUid)
    return SeedBufferSettleDeferred(seedUid)
end

function Refine.GetSeedBudgetForSpec(spec, seedUid)
    return Refine.GetSeedBudget(seedUid)
end

function Refine.CountRefinablePlants(plantUid, spec)
    return CountRefinableForSpec(plantUid, spec)
end

function Refine.TrackLiveSeed(seedUid)
    seedUid = tonumber(seedUid) or 0
    if seedUid <= 0 then
        return
    end
    Refine._liveSeedBaseline[seedUid] = LiveSeedCount(seedUid)
end

--- Pick same-tier surplus plant to convert into resin (1:1 plant->seed+resin).
--- Prefers convert-inflated / same-recipe rows, then any same-skill surplus.
function Refine.PickPlantForResinConvert(resinSpec, resinDeficit, preferredPotionKeys)
    if type(resinSpec) ~= "table" then
        return nil
    end
    resinDeficit = tonumber(resinDeficit) or 0
    if resinDeficit <= 0 then
        return nil
    end
    local resinSkillLevel = tonumber(resinSpec.skillLevel) or 0
    if resinSkillLevel <= 0 then
        return nil
    end
    local SM = StockPiler.SeedMap
    local RS = StockPiler.RecipeSpec
    if not (SM and RS and RS.BuildBalancedSpecDemand) then
        return nil
    end
    local demand = RS.BuildBalancedSpecDemand()
    if type(demand) ~= "table" then
        return nil
    end
    preferredPotionKeys = type(preferredPotionKeys) == "table" and preferredPotionKeys or {}

    local best = nil
    local function consider(cand)
        if type(cand) ~= "table" then
            return
        end
        if best == nil
            or cand.tier < best.tier
            or (cand.tier == best.tier and cand.score > best.score)
            or (cand.tier == best.tier and cand.score == best.score
                and (tonumber(cand.plantUid) or 0) < (tonumber(best.plantUid) or 0))
        then
            best = cand
        end
    end

    for _, row in pairs(demand) do
        if type(row) == "table" and type(row.spec) == "table" then
            local preferred = RowSharesPotionKeys(row, preferredPotionKeys)
                or (tonumber(row.byproductConvertExtra) or 0) > 0
            local tier = preferred and 1 or 2
            consider(CandidateFromDemandRow(row, SM, tier, resinSkillLevel))
        end
    end

    if best ~= nil and best.seedUid <= 0 then
        if best.plantUid > 0 and SM.ResolveSeedForPlantUid then
            local resolved = SM.ResolveSeedForPlantUid(best.plantUid, best.spec)
            if type(resolved) == "table" then
                best.seedUid = tonumber(resolved.uniqueID or resolved.uid) or 0
            end
        end
        if best.seedUid <= 0 and SM.ResolveSeedForSpec then
            local resolved = SM.ResolveSeedForSpec(best.spec)
            if type(resolved) == "table" then
                best.seedUid = tonumber(resolved.uniqueID or resolved.uid) or 0
            end
        end
    end
    return best
end

function Refine.HasActiveResinNeed()
    local RS = StockPiler.RecipeSpec
    local SM = StockPiler.SeedMap
    if not (RS and RS.BuildBalancedSpecDemand and SM and SM.IsHarvestByproduct) then
        return false
    end
    local Inv = StockPiler.Inventory
    local snap = Inv and Inv.GetSnapGen and tonumber(Inv.GetSnapGen()) or 0
    local Watch = StockPiler.Watch
    local watchGen = Watch and Watch.GetGen and tonumber(Watch.GetGen()) or 0
    local know = StockPiler.Knowledge and StockPiler.Knowledge.GetGen and tonumber(StockPiler.Knowledge.GetGen()) or 0
    local Garden = StockPiler.Garden
    local gardenGen = Garden and Garden.GetPlanGen and tonumber(Garden.GetPlanGen()) or 0
    local cacheKey = tostring(snap) .. ":" .. tostring(watchGen) .. ":" .. tostring(know) .. ":" .. tostring(gardenGen)
    if Refine._resinNeedKey == cacheKey and Refine._resinNeedVal ~= nil then
        return Refine._resinNeedVal == true
    end
    local demand = RS.BuildBalancedSpecDemand({ cacheOnly = true })
    if type(demand) ~= "table" then
        demand = RS.BuildBalancedSpecDemand()
    end
    local function finish(val)
        Refine._resinNeedKey = cacheKey
        Refine._resinNeedVal = val == true
        return val == true
    end
    if type(demand) ~= "table" then
        return finish(false)
    end
    for _, row in pairs(demand) do
        if type(row) == "table" and type(row.spec) == "table"
            and (row.isByproduct == true or SM.IsHarvestByproduct(row.spec) == true)
            and (tonumber(row.deficit) or 0) > 0
        then
            if demand._resinFeedstock == true then
                return finish(true)
            end
            local pick = Refine.PickPlantForResinConvert(row.spec, tonumber(row.deficit) or 0)
            if type(pick) == "table" then
                return finish(true)
            end
        end
    end
    return finish(false)
end

--- Plant-first: block refine if empty plot + plantable unless buffer-pending or fillBlocked.
--- No refine during brew session.
function Refine.ShouldAllowRefineNow(opts)
    opts = type(opts) == "table" and opts or {}
    local ignoreVendor = opts.ignoreVendor == true
    local ignoreInteraction = opts.ignoreInteraction == true
    if Refine.IsEnabled() ~= true then
        return false, "disabled"
    end
    -- SendUseItem ends the merchant interaction (store listens to INTERACT_DONE).
    -- Keep the vendor open for AutoBuy while the player shops; refine after close.
    -- ignoreVendor only asks whether refine work is waiting, so a closed-merchant
    -- tip is not raised when the bags have nothing to convert.
    local VA = StockPiler.VendorAdapter
    if ignoreVendor ~= true and VA and VA.IsStoreOpen and VA.IsStoreOpen() == true then
        return false, "vendor-open"
    end
    -- Quest / trainer / bank dialogs also listen for INTERACT_DONE. ignoreVendor
    -- only skips the merchant; any other NPC window still blocks SendUseItem.
    -- ignoreInteraction is for the stalled tip (is refine work waiting aside from
    -- that dialog?), same pattern as ignoreVendor.
    if ignoreInteraction ~= true
        and VA and VA.IsNonStoreInteractionOpen and VA.IsNonStoreInteractionOpen() == true
    then
        return false, "interaction-open"
    end
    local Orch = StockPiler.Orchestrator
    if Orch and Orch.IsBrewSessionActive and Orch.IsBrewSessionActive() then
        return false, "brew-session"
    end
    local Grow = StockPiler.Grow
    local bufferPending = Grow and Grow.HasPendingBufferRefine and Grow.HasPendingBufferRefine() == true
    local empty = Grow and Grow.HasEmptyPlot and Grow.HasEmptyPlot() == true
    if empty and Grow then
        local plantable = false
        local plantReason, peekReason = nil, nil
        if Grow.PeekSeedsForNextPlant then
            local ok, jobOrReason = Grow.PeekSeedsForNextPlant()
            if ok == true then
                plantable = true
                if type(jobOrReason) == "table" then
                    plantReason = tostring(jobOrReason.plantReason or "")
                end
            else
                peekReason = tostring(jobOrReason or "")
            end
        end
        if not plantable and (peekReason == "dirty" or peekReason == "unprobed") then
            -- Post-harvest / upgrade refine-first often leaves the plant queue dirty
            -- on purpose (skip demand probe). Do not block refine waiting for a plant
            -- probe that orch will not run this tick.
            local allowDirty = Refine._refineDirty == true
                or tostring(Refine._refineDirtyReason or "") == "harvest"
            if not allowDirty then
                local US = StockPiler.UpgradeSeed
                if US and US.IsEnabled and US.IsEnabled() == true
                    and US.NeedsRefineFirst and US.NeedsRefineFirst() == true
                then
                    allowDirty = true
                end
            end
            if not allowDirty
                and not (Grow.IsFillBlocked and Grow.IsFillBlocked() == true)
            then
                -- Intent checks must not wait on a plant probe that has not run.
                if ignoreVendor ~= true then
                    return false, "plant-probe-pending"
                end
            end
        end
        if plantable then
            local SkillUp = StockPiler.SkillUp
            -- SkillUp: refine higher plant or buffer-fill plants before replanting.
            if SkillUp and SkillUp.PreferRefineOverPlant
                and SkillUp.PreferRefineOverPlant() == true
            then
                if SkillUp.HasUpgradePlant and SkillUp.HasUpgradePlant() == true then
                    return true, "skill-up-upgrade"
                end
                return true, "skill-up-refine"
            end
            if bufferPending then
                if plantReason == "potion_stock" or plantReason == "seed_buffer" then
                    return false, "plant-first"
                end
            else
                return false, "plant-first"
            end
        end
    end
    if bufferPending then
        return true, "seed-buffer"
    end
    if Refine._refineDirtyReason == "harvest" or Refine._refineDirty == true then
        return true, "post-harvest"
    end
    if empty then
        return true, "pre-plant"
    end
    if Refine.HasActiveResinNeed() == true then
        return true, "resin-need"
    end
    -- SkillUp: plots-full idle used to skip CollectIntents entirely, so buffer
    -- plants sat while Apo stayed on "Held for seed buffer" until a manual refine.
    local SkillUpIdle = StockPiler.SkillUp
    if SkillUpIdle then
        if SkillUpIdle.HasUpgradePlant and SkillUpIdle.HasUpgradePlant() == true then
            return true, "skill-up-upgrade"
        end
        if SkillUpIdle.HasRefinablePlants and SkillUpIdle.HasRefinablePlants() == true then
            return true, "skill-up-buffer"
        end
        if SkillUpIdle.HasApoResinRefinePlant and SkillUpIdle.HasApoResinRefinePlant() == true then
            return true, "skill-up-resin"
        end
    end
    return false, "idle-grow"
end

function Refine.ClearBlockedNotify()
    Refine._blockedVendorNotified = false
    Refine._blockedInteractionNotified = false
end

--- One chat line when refine work is waiting on an open merchant or NPC dialog.
--- Returns true only on the first notice per block. ClearBlockedNotify arms again.
function Refine.MaybeNotifyBlocked()
    local VA = StockPiler.VendorAdapter
    local storeOpen = VA and VA.IsStoreOpen and VA.IsStoreOpen() == true
    local interactionOpen = VA and VA.IsNonStoreInteractionOpen
        and VA.IsNonStoreInteractionOpen() == true
    if storeOpen ~= true then
        Refine._blockedVendorNotified = false
    end
    if interactionOpen ~= true then
        Refine._blockedInteractionNotified = false
    end
    if storeOpen ~= true and interactionOpen ~= true then
        return false
    end

    -- Merchant alone: vendor tip (AutoBuy needs the store open).
    if storeOpen == true and interactionOpen ~= true then
        if Refine._blockedVendorNotified == true then
            return false
        end
        if #(Refine.CollectIntents({ ignoreVendor = true }) or {}) == 0 then
            return false
        end
        local msg = (StockPiler.T and StockPiler.T("refine.blocked.vendor_open"))
            or L"<icon02486> Refine stalled - close the merchant window to continue."
        if StockPiler.Debug and StockPiler.Debug.Print then
            StockPiler.Debug.Print(msg)
        end
        Refine._blockedVendorNotified = true
        return true
    end

    -- Quest / trainer / bank / flight master / etc. (with or without the store).
    if interactionOpen == true then
        if Refine._blockedInteractionNotified == true then
            return false
        end
        if #(Refine.CollectIntents({
            ignoreVendor = true,
            ignoreInteraction = true,
        }) or {}) == 0 then
            return false
        end
        local msg = (StockPiler.T and StockPiler.T("refine.blocked.interaction_open"))
            or L"<icon02486> Refine stalled - close the NPC window to continue."
        if StockPiler.Debug and StockPiler.Debug.Print then
            StockPiler.Debug.Print(msg)
        end
        Refine._blockedInteractionNotified = true
        return true
    end
    return false
end

----------------------------------------------------------------
-- CollectIntents / IssueOne
----------------------------------------------------------------

function Refine.CollectIntents(opts)
    opts = type(opts) == "table" and opts or {}
    if Refine.ShouldAllowRefineNow(opts) ~= true then
        return {}
    end
    local cacheKey = IntentCacheKey()
    if Refine._intentCacheKey == cacheKey and type(Refine._intentCache) == "table" then
        -- Empty-cache bust only when bags moved (snapGen) or harvest dirty.
        -- A 5s timer used to rebuild CollectIntents every idle orch tick while
        -- HasPendingBufferRefine stayed true with no new plants (libperf noise).
        if #Refine._intentCache == 0 then
            local snapGen = 0
            if StockPiler.Inventory and StockPiler.Inventory.GetSnapGen then
                snapGen = tonumber(StockPiler.Inventory.GetSnapGen()) or 0
            end
            local snapMoved = tonumber(Refine._emptyIntentSnapGen) ~= snapGen
            local harvestDirty = Refine._refineDirtyReason == "harvest"
            -- skill-up / upgrade MarkRefineDue does not move bags. Bust the
            -- empty latch once for that mark. _refineDirty stays true until
            -- TryTick, so a later collect with no new mark must stay warm.
            local dueGen = tonumber(Refine._refineDueGen) or 0
            local dueMoved = tonumber(Refine._emptyIntentDueGen) ~= dueGen
            if snapMoved or harvestDirty or dueMoved then
                Refine.InvalidateIntentCache()
            else
                -- Warm hit must not defer IssueOne on this frame.
                Refine._coldRebuildFrame = 0
                return Refine._intentCache
            end
        else
            Refine._coldRebuildFrame = 0
            return Refine._intentCache
        end
    end

    local Perf = StockPiler.Perf
    if Perf and Perf.Begin then
        Perf.Begin("CollectIntents")
    end
    -- Set only when this call rebuilds. A warm return above clears it.
    Refine._coldRebuildFrame = tonumber(StockPiler.FrameCounter) or 0
    Refine._collectedFrame = Refine._coldRebuildFrame
    local intents = {}
    local RS = StockPiler.RecipeSpec
    local SM = StockPiler.SeedMap
    local Watch = StockPiler.Watch
    local bufferOn = Watch and Watch.IsSeedBufferEnabled and Watch.IsSeedBufferEnabled() == true
    local seenBuffer = {}

    -- 1) Seed-buffer (bootstrap when brew deficit 0 but buffer short)
    if Perf and Perf.Mark then
        Perf.Mark("CollectIntents.seedBuffer")
    end
    if bufferOn and RS and RS.CollectAutoGrowSeedLines then
        local lines = RS.CollectAutoGrowSeedLines() or {}
        for i = 1, #lines do
            local line = lines[i]
            local seedUid = tonumber(line.seedUid) or 0
            local key = tostring(line.specKey or seedUid)
            if seenBuffer[key] ~= true and seedUid > 0 and not IsSeedBufferOnCooldown(seedUid)
                and not SeedBufferSettleDeferred(seedUid)
            then
                seenBuffer[key] = true
                local budget = Refine.GetSeedBudget(seedUid)
                local refinable = CountRefinableForSpec(line.plantUid, line.spec)
                local brewNeed = tonumber(line.brewDeficit or line.deficit) or 0
                local convertible = 0
                if refinable > 0 and (tonumber(budget.headroom) or 0) > 0 then
                    if brewNeed <= 0 then
                        -- Bootstrap: buffer short with no brew plant need.
                        convertible = math.min(refinable, tonumber(budget.headroom) or 0, 5)
                    else
                        -- Prefer surplus above brew need.
                        local surplus = math.max(0, refinable - brewNeed)
                        convertible = math.min(surplus > 0 and surplus or 0, tonumber(budget.headroom) or 0, 5)
                        if convertible <= 0 and LineBufferShort(line) and brewNeed <= 0 then
                            convertible = math.min(refinable, tonumber(budget.headroom) or 0, 5)
                        end
                    end
                end
                if convertible > 0 then
                    AppendIntent(intents, line, "seed-buffer", convertible, budget)
                end
            end
        end
    end

    -- 1b) Upgrade Seed: refine family upgrade plants / buffer for climb line.
    if Perf and Perf.Mark then
        Perf.Mark("CollectIntents.upgradeSeed")
    end
    local UpgradeSeed = StockPiler.UpgradeSeed
    if UpgradeSeed and UpgradeSeed.AppendRefineIntents then
        UpgradeSeed.AppendRefineIntents(intents, function(line, reason, uses, budget)
            AppendIntent(intents, line, reason, uses, budget)
        end)
    end

    -- 1c) SkillUp Cult: refine plants back to seeds to fill empty plots.
    if Perf and Perf.Mark then
        Perf.Mark("CollectIntents.skillUp")
    end
    local SkillUp = StockPiler.SkillUp
    if SkillUp and SkillUp.AppendRefineIntents then
        SkillUp.AppendRefineIntents(intents, function(line, reason, uses, budget)
            AppendIntent(intents, line, reason, uses, budget)
        end)
    end
    -- 1d) SkillUp Apo: refine brew-main surplus into Arboreal Resin when resin-short.
    if SkillUp and SkillUp.AppendApoResinRefineIntents then
        SkillUp.AppendApoResinRefineIntents(intents, function(line, reason, uses, budget)
            AppendIntent(intents, line, reason, uses, budget)
        end)
    end

    -- 2) Plant-need / 3) Resin-need share one demand snapshot (warm-cache hit is free).
    -- Orch decision hold / plant quiet: cacheOnly - never WarmHave.miss on this frame.
    if Perf and Perf.Mark then
        Perf.Mark("CollectIntents.demand")
    end
    local demand = nil
    if RS and RS.BuildBalancedSpecDemand then
        local Sch = StockPiler.Scheduler
        local hold = Sch and (
            (Sch.IsOrchDecisionHold and Sch.IsOrchDecisionHold() == true)
            or (Sch.IsSuppressed and Sch.IsSuppressed() == true)
        )
        if hold == true then
            demand = RS.BuildBalancedSpecDemand({ cacheOnly = true })
            if type(demand) ~= "table" and Sch.RequestCachePrewarm then
                Sch.RequestCachePrewarm("refine-demand-cold")
            end
        else
            demand = RS.BuildBalancedSpecDemand()
        end
    end

    -- 2) Plant-need
    if Perf and Perf.Mark then
        Perf.Mark("CollectIntents.plantNeed")
    end
    if type(demand) == "table" then
        for _, row in pairs(demand) do
            if type(row) == "table" and type(row.spec) == "table"
                and not (SM and SM.IsHarvestByproduct and SM.IsHarvestByproduct(row.spec))
                and row.isByproduct ~= true
                -- Containers / vendor mats never plant-need refine (vials were matching via uid).
                and (not SM.IsGrowableSpec or SM.IsGrowableSpec(row.spec) == true)
            then
                local seedUid = tonumber(row.seedUid) or 0
                if seedUid <= 0 and SM and SM.ResolveSeedForSpec then
                    local seed = SM.ResolveSeedForSpec(row.spec)
                    seedUid = type(seed) == "table" and (tonumber(seed.uniqueID) or 0) or 0
                end
                local plantUid = tonumber(row.plantUid) or 0
                if plantUid <= 0 and SM and SM.FindPlantUidForSpec then
                    plantUid = tonumber(SM.FindPlantUidForSpec(row.spec)) or 0
                end
                if plantUid > 0 then
                    local key = tostring(row.specKey or seedUid)
                    if seenBuffer[key] ~= true then
                        local budget = Refine.GetSeedBudget(seedUid)
                        local refinable = CountRefinableForSpec(plantUid, row.spec)
                        local liveOk = (tonumber(budget.live) or 0) <= 0
                            and (tonumber(budget.outstanding) or 0) <= 0
                        local deficitOk = (tonumber(row.deficit) or 0) > 0 and refinable > 0
                        if liveOk and deficitOk then
                            -- Unknown seedUid: still refine plants (learn seed on convert).
                            local allow = seedUid <= 0
                                or not bufferOn
                                or (tonumber(budget.headroom) or 0) > 0
                            if allow then
                                AppendIntent(intents, {
                                    spec = row.spec,
                                    specKey = row.specKey,
                                    seedUid = seedUid,
                                    plantUid = plantUid,
                                }, "plant-need", 1, budget)
                            end
                        end
                    end
                end
            end
        end
    end

    -- 3) Resin-need: convert same-tier surplus plants (never plant-need the resin uid).
    if SM and SM.IsHarvestByproduct and type(demand) == "table" then
        local seen = {}
        for _, row in pairs(demand) do
            if type(row) == "table" and type(row.spec) == "table"
                and (row.isByproduct == true or SM.IsHarvestByproduct(row.spec) == true)
            then
                local deficit = tonumber(row.deficit) or 0
                local resinKey = tostring(row.specKey or "")
                if deficit > 0 and resinKey ~= "" and seen[resinKey] ~= true then
                    seen[resinKey] = true
                    local pick = Refine.PickPlantForResinConvert(row.spec, deficit)
                    if type(pick) == "table" and (tonumber(pick.slot) or 0) > 0 then
                        local uses = math.min(
                            deficit,
                            tonumber(pick.surplus) or 0,
                            tonumber(pick.refinable) or 0,
                            5
                        )
                        if uses > 0 then
                            intents[#intents + 1] = {
                                reason = "resin-need",
                                spec = pick.spec or row.spec,
                                seedUid = tonumber(pick.seedUid) or 0,
                                plantUid = tonumber(pick.plantUid) or 0,
                                uses = uses,
                                headroom = 0,
                                slot = pick.slot,
                                item = pick.item,
                                bagType = pick.bagType or CraftingBackpackType(),
                                emergencyPlant = false,
                            }
                        end
                    end
                end
            end
        end
    end

    table.sort(intents, function(a, b)
        local pa, pb = ReasonPriority(a.reason), ReasonPriority(b.reason)
        if pa ~= pb then
            return pa < pb
        end
        return (tonumber(a.seedUid) or 0) < (tonumber(b.seedUid) or 0)
    end)

    Refine._intentCacheKey = cacheKey
    Refine._intentCache = intents
    if #intents == 0 then
        local snapGen = 0
        if StockPiler.Inventory and StockPiler.Inventory.GetSnapGen then
            snapGen = tonumber(StockPiler.Inventory.GetSnapGen()) or 0
        end
        Refine._emptyIntentSnapGen = snapGen
        Refine._emptyIntentDueGen = tonumber(Refine._refineDueGen) or 0
    else
        Refine._emptyIntentSnapGen = nil
        Refine._emptyIntentDueGen = nil
    end
    if Perf and Perf.End then
        Perf.End("CollectIntents")
    end
    return intents
end

function Refine.CollectedThisFrame()
    local frame = tonumber(StockPiler.FrameCounter) or 0
    return frame > 0 and (tonumber(Refine._coldRebuildFrame) or 0) == frame
end

function Refine.IssuedThisFrame()
    local frame = tonumber(StockPiler.FrameCounter) or 0
    return frame > 0 and Refine._engineIssueFrame == frame
end

--- Cold CollectIntents and SendUseItem were one ~100ms frame. Defer the
--- engine call to a later frame. A cold collect on a later frame still issues.
function Refine.ShouldDeferIssue()
    if Refine.CollectedThisFrame() ~= true then
        return false
    end
    local frame = tonumber(StockPiler.FrameCounter) or 0
    local deferred = tonumber(Refine._deferIssueFrame) or 0
    if deferred > 0 and deferred ~= frame then
        return false
    end
    Refine._deferIssueFrame = frame
    return true
end

function Refine.TakeDeferredIssue()
    if Refine._deferredThisCall == true then
        Refine._deferredThisCall = false
        return true
    end
    return false
end

function Refine.CanIssue(intent)
    if type(intent) ~= "table" then
        return false, "nil-intent"
    end
    local seedUid = tonumber(intent.seedUid) or 0
    local plantUid = tonumber(intent.plantUid) or 0
    local reason = tostring(intent.reason or "")
    if reason == "seed-buffer" and IsSeedBufferOnCooldown(seedUid) then
        return false, "seed-buffer-cooldown"
    end
    if (reason == "seed-buffer" or reason == "upgrade-seed-buffer")
        and SeedBufferSettleDeferred(seedUid)
    then
        return false, "seed-buffer-unsettled"
    end
    if Refine._issuedSeedThisTick ~= nil and seedUid > 0 and Refine._issuedSeedThisTick == seedUid then
        return false, "duplicate-tick"
    end
    local RP = StockPiler.RefinePipeline
    if RP and RP.GetOutstanding and RP.GetOutstanding(seedUid) >= (Refine.MAX_OUTSTANDING_PER_SEED or 6) then
        return false, "outstanding-throttle"
    end
    local pending = tonumber(Refine._pendingByPlant[plantUid]) or 0
    if pending >= (Refine.MAX_PENDING_PER_PLANT or 6) then
        return false, "pending-throttle"
    end
    if (tonumber(intent.slot) or 0) <= 0 or type(intent.item) ~= "table" then
        return false, "no-slot"
    end
    if (tonumber(intent.uses) or 0) <= 0 then
        return false, "no-uses"
    end
    return true
end

local function ItemUidOf(item)
    if type(item) ~= "table" then
        return 0
    end
    return tonumber(item.uniqueID) or tonumber(item.uid) or 0
end

local function BagKeyForType(bagType)
    if EA_Window_Backpack and EA_Window_Backpack.TYPE_INVENTORY ~= nil
        and bagType == EA_Window_Backpack.TYPE_INVENTORY
    then
        return "main"
    end
    return "craft"
end

--- Live craft/backpack table, not the snap-gen slot index. Stacks move inside
--- a bag without a new inventory generation.
local function FindUidInBagTable(bagTable, plantUid)
    plantUid = tonumber(plantUid) or 0
    if plantUid <= 0 or type(bagTable) ~= "table" then
        return nil, nil
    end
    for slot, item in pairs(bagTable) do
        local nslot = tonumber(slot)
        if nslot and nslot > 0 and type(item) == "table" then
            local uid = tonumber(item.uniqueID) or tonumber(item.uid) or 0
            local qty = tonumber(item.stackCount) or tonumber(item.StackCount) or 0
            if uid == plantUid and qty > 0 then
                return nslot, item
            end
        end
    end
    return nil, nil
end

--- Intent cache omits snapGen, so the slot from CollectIntents can point at
--- a different item after a bag move (EXE-8). Re-resolve and abort when the
--- live slot is not this plant. A missing bag table falls back to the index.
--- resin-need: FindPlantSlotHighest may pick a larger same-spec twin uid; adopt
--- that live uid instead of stale-slot looping (#32).
local function ResolveIntentSlot(intent)
    local plantUid = tonumber(intent.plantUid) or 0
    local spec = intent.spec
    local reason = tostring(intent.reason or "")
    local slot, item, bagType
    if reason == "resin-need" then
        slot, item, bagType = FindPlantSlotHighest(plantUid, spec)
    else
        slot, item, bagType = FindPlantSlot(plantUid, spec)
    end
    -- Index slot can name a neighbor after an in-bag move that did not bump
    -- snap gen. Search the live tables before giving up.
    local function fromLiveBags()
        local BA = StockPiler.BagAdapter
        if not (BA and BA.GetBagTable) or plantUid <= 0 then
            Refine.InvalidateBagIndex()
            return nil
        end
        local hinted = BagKeyForType(bagType)
        local order = { "craft", "main" }
        if hinted == "main" then
            order = { "main", "craft" }
        end
        for i = 1, #order do
            local key = order[i]
            local bag = BA.GetBagTable(key)
            local liveSlot, liveItem = FindUidInBagTable(bag, plantUid)
            if liveSlot ~= nil and type(liveItem) == "table" then
                Refine.InvalidateBagIndex()
                return liveSlot, liveItem, BagTypeForKey(key)
            end
        end
        Refine.InvalidateBagIndex()
        return nil
    end
    slot = tonumber(slot) or 0
    if slot <= 0 or type(item) ~= "table" then
        return fromLiveBags()
    end
    local expected = ItemUidOf(item)
    if plantUid > 0 and expected > 0 and expected ~= plantUid then
        if reason == "resin-need" then
            intent.plantUid = expected
            plantUid = expected
        else
            return fromLiveBags()
        end
    end
    local BA = StockPiler.BagAdapter
    if BA and BA.GetBagTable and BA.ReadSlotFromTable then
        local bagKey = BagKeyForType(bagType)
        local bag = BA.GetBagTable(bagKey)
        if type(bag) == "table" then
            -- One bag fetch: ReadSlot would call GetBagTable again (#26 L1).
            local liveUid, liveQty, liveItem = BA.ReadSlotFromTable(bag, slot)
            liveUid = tonumber(liveUid) or 0
            liveQty = tonumber(liveQty) or 0
            if (expected > 0 and liveUid ~= expected) or liveUid <= 0 or liveQty <= 0 then
                return fromLiveBags()
            end
            if type(liveItem) == "table" then
                item = liveItem
            end
        end
    end
    return slot, item, bagType
end

function Refine.IssueOne(intent, opId)
    if Refine.CanIssue(intent) ~= true then
        return false
    end
    local VA = StockPiler.VendorAdapter
    if VA and VA.IsStoreOpen and VA.IsStoreOpen() == true then
        return false
    end
    if type(SendUseItem) ~= "function"
        or type(EA_Window_Backpack) ~= "table"
        or type(EA_Window_Backpack.GetCursorForBackpack) ~= "function"
    then
        return false
    end

    local Perf = StockPiler.Perf
    if Perf and Perf.Begin then
        Perf.Begin("Refine.IssueOne")
    end
    local function done(ok)
        if Perf and Perf.End then
            Perf.End("Refine.IssueOne")
        end
        return ok == true
    end

    -- A dialog can open after CollectIntents. Refuse before any stamp,
    -- live-seed record, quiet arm, or SendUseItem (that event closes it).
    if VA and VA.IsNonStoreInteractionOpen and VA.IsNonStoreInteractionOpen() == true then
        return done(false)
    end

    local slot, item, bagType = ResolveIntentSlot(intent)
    if slot == nil or type(item) ~= "table" then
        LogRefine(string.format(
            "stale-slot reason=%s plantUid=%s cachedSlot=%s",
            tostring(intent.reason or ""),
            tostring(intent.plantUid or 0),
            tostring(intent.slot or 0)
        ))
        Refine.InvalidateIntentCache()
        return done(false)
    end
    local plantUid = tonumber(intent.plantUid) or tonumber(item.uniqueID) or 0
    local seedUid = tonumber(intent.seedUid) or 0
    local uses = tonumber(intent.uses) or 1
    local reason = tostring(intent.reason or "refine")
    local pending = tonumber(Refine._pendingByPlant[plantUid]) or 0
    local stack = tonumber(item.stackCount) or tonumber(item.StackCount) or 1
    uses = math.min(
        uses,
        stack,
        (Refine.MAX_PENDING_PER_PLANT or 6) - pending,
        Refine.MAX_USES_PER_ISSUE or 1
    )

    -- Clamp to live headroom (not resin-need).
    local bufferOn = StockPiler.Watch and StockPiler.Watch.IsSeedBufferEnabled
        and StockPiler.Watch.IsSeedBufferEnabled() == true
    if (reason == "seed-buffer" or reason == "upgrade-seed-buffer")
        and SeedBufferSettleDeferred(seedUid)
    then
        return done(false)
    end
    if seedUid > 0 and reason ~= "resin-need"
        and (reason == "seed-buffer" or reason == "upgrade-seed-buffer"
            or (reason == "plant-need" and bufferOn))
    then
        local budget = Refine.GetSeedBudget(seedUid)
        local headroom = tonumber(budget.headroom) or 0
        if headroom < 1 then
            return done(false)
        end
        uses = math.min(uses, headroom)
    end
    if uses < 1 then
        return done(false)
    end

    -- Same-frame guard before any live-seed record or quiet arm.
    -- A refused issue must not look like a seed was sent.
    if Refine.IssuedThisFrame() == true then
        return done(false)
    end

    local SM = StockPiler.SeedMap
    -- Snapshot bag counts before SendUseItem. Moving this after the call
    -- would see the consumed stack and miss the seed gain.
    if SM and SM.BeginPendingRefine then
        SM.BeginPendingRefine(item)
    end

    local issueFrame = tonumber(StockPiler.FrameCounter) or 0
    Refine._engineIssueFrame = issueFrame
    local location = EA_Window_Backpack.GetCursorForBackpack(bagType)
    local sent = 0
    for _ = 1, uses do
        local ok = true
        if StockPiler.Debug and StockPiler.Debug.TryCall then
            ok = StockPiler.Debug.TryCall("SendUseItem", SendUseItem, location, slot, 0, 0, 0)
        else
            ok = pcall(SendUseItem, location, slot, 0, 0, 0)
        end
        if ok ~= true then
            break
        end
        sent = sent + 1
        local RP = StockPiler.RefinePipeline
        if RP and RP.Register then
            RP.Register(seedUid, plantUid)
        end
    end
    if sent <= 0 then
        return done(false)
    end

    Refine.TrackLiveSeed(seedUid)
    Refine._pendingByPlant[plantUid] = pending + sent
    if plantUid > 0 and seedUid > 0 then
        Refine._pendingSeedByPlant[plantUid] = seedUid
    end
    Refine._deferIssueFrame = 0
    Refine._issuedSeedThisTick = seedUid
    Refine._reconcileSnapGen = -1
    LogRefine(string.format(
        "%s plantUid=%d seedUid=%d uses=%d opId=%s",
        reason, plantUid, seedUid, sent, tostring(opId or "?")
    ))
    if StockPiler.Grow and StockPiler.Grow.InvalidatePlantQueue then
        StockPiler.Grow.InvalidatePlantQueue({ jobOnly = true })
    end
    -- Quiet only after SendUseItem actually went out.
    local Sch = StockPiler.Scheduler
    if Sch and Sch.ArmPlantQuiet then
        Sch.ArmPlantQuiet()
    end
    if Sch and Sch.SkipPlanThisFrame then
        Sch.SkipPlanThisFrame()
    end
    if Sch and Sch.SkipUiThisFrame then
        Sch.SkipUiThisFrame()
    end
    if Sch and Sch.EnqueueBagFlush then
        Sch.EnqueueBagFlush(false)
    end
    Refine.InvalidateIntentCache()
    Refine._refineWaitTicks = (reason == "seed-buffer") and 2 or 5
    Refine._refineDirty = false
    Refine._refineDirtyReason = nil
    if Sch and Sch.WakeAutoGrow then
        Sch.WakeAutoGrow()
    end
    return done(true)
end

function Refine.TryTick(opId)
    Refine._issuedSeedThisTick = nil
    if Refine.IsEnabled() ~= true then
        return false
    end
    if Refine.ShouldAllowRefineNow() ~= true then
        return false
    end
    if Refine.RefineCheckDue() ~= true then
        return false
    end
    ClearOrphanPending()
    local intents = Refine.CollectIntents()
    if type(intents) ~= "table" or #intents == 0 then
        Refine._deferredThisCall = false
        -- No actionable refine: back off so grow-wait ticks do not rebuild intents
        -- every AutoGrow second (LibPerf ~300-450ms CollectIntents spikes).
        Refine._refineWaitTicks = math.max(tonumber(Refine._refineWaitTicks) or 0, 5)
        if Refine._refineDirty == true and Refine._refineDirtyReason ~= "harvest" then
            Refine._refineDirty = false
            Refine._refineDirtyReason = nil
        end
        return false
    end
    if Refine.ShouldDeferIssue() == true then
        Refine._deferredThisCall = true
        return false
    end
    Refine._deferredThisCall = false
    if Refine.IssuedThisFrame() == true then
        return false
    end
    for i = 1, #intents do
        if Refine.IssueOne(intents[i], opId) == true then
            return true
        end
    end
    -- No issue: throttle only (do not fill-block).
    if Refine._refineDirty == true then
        Refine._refineWaitTicks = math.max(tonumber(Refine._refineWaitTicks) or 0, 3)
        Refine._refineDirty = false
        if Refine._refineDirtyReason ~= "harvest" then
            Refine._refineDirtyReason = nil
        end
    end
    return false
end

----------------------------------------------------------------
-- Reconcile / OnUpdate
----------------------------------------------------------------

function Refine.ReconcileAll()
    local RP = StockPiler.RefinePipeline
    if not RP or not RP.Snapshot then
        return
    end
    local snap = RP.Snapshot()
    for seedUid, outstanding in pairs(snap) do
        seedUid = tonumber(seedUid) or 0
        outstanding = tonumber(outstanding) or 0
        if seedUid > 0 and outstanding > 0 then
            local live = LiveSeedCount(seedUid)
            local base = tonumber(Refine._liveSeedBaseline[seedUid])
            if base ~= nil and live > base then
                local delivered = live - base
                RP.Reconcile(seedUid, delivered)
                Refine._liveSeedBaseline[seedUid] = live
                Refine.InvalidateIntentCache()
            end
        end
    end
end

function Refine.ExpireStuckOutstanding()
    local RP = StockPiler.RefinePipeline
    if not RP or not RP.ExpireStuck then
        return false
    end
    local changed = RP.ExpireStuck() == true
    if changed then
        -- Arm cooldown when pending cleared with no delivery.
        for plantUid, seedUid in pairs(Refine._pendingSeedByPlant) do
            seedUid = tonumber(seedUid) or 0
            local outstanding = RP.GetOutstanding and RP.GetOutstanding(seedUid) or 0
            if outstanding <= 0 then
                ArmSeedBufferFailCooldown(seedUid)
                Refine._pendingByPlant[plantUid] = nil
                Refine._pendingSeedByPlant[plantUid] = nil
            end
        end
        Refine.InvalidateIntentCache()
    end
    return changed
end

--- Frame-gated Reconcile / ExpireStuck.
function Refine.OnUpdateProcessed(timeElapsed)
    local frame = tonumber(StockPiler.FrameCounter) or 0
    if Refine._onUpdateFrame == frame then
        return
    end
    Refine._onUpdateFrame = frame

    local Inv = StockPiler.Inventory
    local snapGen = Inv and Inv.GetSnapGen and Inv.GetSnapGen() or 0
    if snapGen ~= Refine._reconcileSnapGen then
        Refine._reconcileSnapGen = snapGen
        Refine.ReconcileAll()
    end
    Refine.ExpireStuckOutstanding()
    -- Wait ticks count Orchestrator ticks. Scheduler.OnUpdate decrements them.
end

function Refine.OnUpdate(timeElapsed)
    Refine.OnUpdateProcessed(timeElapsed)
end

function Refine.DumpDiagnostics(emit)
    emit = type(emit) == "function" and emit or function(msg)
        if StockPiler.Debug and StockPiler.Debug.Print then
            StockPiler.Debug.Print(msg)
        end
    end
    emit("=== refine ===")
    emit("enabled=" .. tostring(Refine.IsEnabled())
        .. " dirty=" .. tostring(Refine._refineDirty)
        .. " reason=" .. tostring(Refine._refineDirtyReason)
        .. " wait=" .. tostring(Refine._refineWaitTicks))
    local allow, why = Refine.ShouldAllowRefineNow()
    emit("allow=" .. tostring(allow) .. " why=" .. tostring(why))
    emit("bufferSatisfied=" .. tostring(Refine.IsSeedBufferSatisfied())
        .. " pending=" .. tostring(Refine.HasPendingBufferRefine())
        .. " short=" .. tostring(Refine.HasAnyBufferShort()))
    local intents = Refine.PeekCachedIntents() or {}
    emit("cachedIntents=" .. tostring(#intents) .. " key=" .. tostring(Refine._intentCacheKey))
    for i = 1, math.min(#intents, 12) do
        local it = intents[i]
        emit(string.format(
            "  %s seed=%s plant=%s uses=%s",
            tostring(it.reason), tostring(it.seedUid), tostring(it.plantUid), tostring(it.uses)
        ))
    end
    emit("=== end refine ===")
end
