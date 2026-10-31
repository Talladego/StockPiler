----------------------------------------------------------------
-- StockPiler UpgradeSeed - watch/demand genus climb to Cult floor
-- buy L1 -> plant -> crit harvest -> refine -> repeat.
-- Sources: potion mat shorts + enabled plant watches (unwatch stops that
-- genus). Idle gate matches Level-up skills. Destination is Cult floor
-- even when the known ladder tops early (Special Moment fishing).
-- Shared seed economy (SeedDeficit / PlantableSurplus / GetSeedBudget) and
-- ladder scan helpers also used by SkillUp (mains-only, TargetMaxSkill cap).
----------------------------------------------------------------

StockPiler = StockPiler or {}
StockPiler.UpgradeSeed = StockPiler.UpgradeSeed or {}
local US = StockPiler.UpgradeSeed

US._stallLatch = nil
US._active = nil -- last pick { familyKey, haveReq, needReq, why }

function US.ClearActive()
    US._active = nil
end

US._upgradeTargetsCache = nil
US._upgradeTargetsKey = nil

local function CharRow(create)
    return StockPiler.Util.CharacterRow(create == true)
end

-- Forward-declared: used by DescribePlantWatchClimb / SeedGap / TargetUpgradePlant
-- before their definitions (Lua locals are not visible above their declaration).
local BestOwnedReqOnLadder
local HaveTargetRung
local CultMaxTierBufferFull

function US.IsEnabled()
    local Caps = StockPiler.TradeSkillCaps
    if Caps and Caps.CanAutoGrow and Caps.CanAutoGrow() ~= true then
        return false
    end
    local row = CharRow(false)
    return type(row) == "table" and row.upgradeSeedsEnabled == true
end

function US.SetEnabled(enabled)
    local row = CharRow(true)
    if type(row) ~= "table" then
        return false
    end
    row.upgradeSeedsEnabled = enabled == true
    US.InvalidateUpgradeTargetsCache()
    local Watch = StockPiler.Watch
    if Watch and Watch.BumpGen then
        Watch.BumpGen()
    end
    return true
end

function US.GetCultSkill()
    -- SkillUp owns the Caps facade; fall back if SkillUp is unavailable.
    local SkillUp = StockPiler.SkillUp
    if SkillUp and SkillUp.GetCultSkill then
        return tonumber(SkillUp.GetCultSkill()) or 0
    end
    local Caps = StockPiler.TradeSkillCaps
    if Caps and Caps.GetCultSkill then
        return tonumber(Caps.GetCultSkill()) or 0
    end
    if Caps and Caps.GetCultivationSkill then
        return tonumber(Caps.GetCultivationSkill()) or 0
    end
    return 0
end

--- Cult seed/plant floor (1, 25, ...). Canonical implementation is SkillUp.FloorCultTier.
function US.FloorCultTier(cultSkill)
    local SE = StockPiler.SeedEconomy
    if SE and SE.FloorCultTier then
        return SE.FloorCultTier(cultSkill)
    end
    local SkillUp = StockPiler.SkillUp
    if SkillUp and SkillUp.FloorCultTier then
        return SkillUp.FloorCultTier(cultSkill)
    end
    return 1
end

--- Climb cap for a watch need: min(needed skillReq, Cult floor).
function US.ClimbCap(neededReq)
    neededReq = tonumber(neededReq) or 0
    local floor = US.FloorCultTier(US.GetCultSkill())
    if floor < 1 then
        floor = 1
    end
    if neededReq < 1 then
        return floor
    end
    if neededReq < floor then
        return neededReq
    end
    return floor
end

--- Highest genus-ladder skillReq at or below current Cult floor (0 if unknown).
function US.CultMaxNeedReq(ladder)
    local floor = US.FloorCultTier(US.GetCultSkill())
    if floor < 1 then
        floor = 1
    end
    if type(ladder) ~= "table" or type(ladder.rungs) ~= "table" then
        return 0
    end
    local best = 0
    for i = 1, #ladder.rungs do
        local req = tonumber(ladder.rungs[i].skillReq) or 0
        if req >= 1 and req <= floor and req > best then
            best = req
        end
    end
    return best
end

local function RungCount(ladder)
    if type(ladder) ~= "table" or type(ladder.rungs) ~= "table" then
        return 0
    end
    return #ladder.rungs
end

--- Merge two genus ladders by skillReq (fill missing seedUid/plantUid from either).
--- Needed when plant vs seed names split genus ("Marsh Root" / "Marshroot").
local function MergeGenusLadders(a, b)
    if type(a) ~= "table" or type(a.rungs) ~= "table" then
        return b
    end
    if type(b) ~= "table" or type(b.rungs) ~= "table" then
        return a
    end
    local merged = {
        key = tostring(a.genus or a.key or "x") .. "+merge|*|0",
        genus = a.genus or b.genus,
        role = a.role,
        effectId = tonumber(a.effectId) or tonumber(b.effectId) or 0,
        rungs = {},
        merged = true,
    }
    local roleA = tostring(a.role or "")
    local roleB = tostring(b.role or "")
    if roleA == "" or roleA == "unknown" or roleA == "ingredient" then
        if roleB ~= "" and roleB ~= "unknown" then
            merged.role = b.role
        end
    end
    local byReq = {}
    local function absorb(src)
        for i = 1, #src.rungs do
            local srcRung = src.rungs[i]
            local req = tonumber(srcRung.skillReq) or 0
            if req >= 1 then
                local rung = byReq[req]
                if rung == nil then
                    rung = {
                        skillReq = req,
                        seedUid = 0,
                        plantUid = 0,
                        name = srcRung.name or "",
                    }
                    byReq[req] = rung
                    merged.rungs[#merged.rungs + 1] = rung
                end
                local sUid = tonumber(srcRung.seedUid) or 0
                local pUid = tonumber(srcRung.plantUid) or 0
                if sUid > 0 and (tonumber(rung.seedUid) or 0) <= 0 then
                    rung.seedUid = sUid
                end
                if pUid > 0 and (tonumber(rung.plantUid) or 0) <= 0 then
                    rung.plantUid = pUid
                end
                if (rung.name == nil or rung.name == "") and srcRung.name and srcRung.name ~= "" then
                    rung.name = srcRung.name
                end
            end
        end
    end
    absorb(a)
    absorb(b)
    table.sort(merged.rungs, function(x, y)
        return (tonumber(x.skillReq) or 0) < (tonumber(y.skillReq) or 0)
    end)
    return merged
end

--- Prefer / merge genus ladders from plant name and linked seed name for climb.
--- "Marsh Root" vs "Marshroot" can still split; merge so L25 Fretting seeds count.
function US.LadderForPlantWatch(spec, plantUid)
    plantUid = tonumber(plantUid) or 0
    local SM = StockPiler.SeedMap
    if not SM then
        return nil
    end
    local plantLadder = nil
    if type(spec) == "table" and SM.GetGenusLadderForSpec then
        plantLadder = SM.GetGenusLadderForSpec(spec)
    end
    if type(plantLadder) ~= "table" and type(spec) == "table" and SM.GetFamilyLadderForSpec then
        plantLadder = SM.GetFamilyLadderForSpec(spec)
    end
    local seedLadder = nil
    local seedUid = 0
    if plantUid > 0 and SM.ResolveSeedUidForPlant then
        seedUid = tonumber(SM.ResolveSeedUidForPlant(plantUid, spec)) or 0
    end
    if seedUid > 0 and SM.GenusKeyFromName then
        local Inv = StockPiler.Inventory
        local Items = StockPiler.Items
        local seedName = nil
        if Inv and Inv.GetSample then
            local sample = Inv.GetSample(seedUid)
            seedName = sample and sample.name
        end
        if seedName == nil and Items and Items.GetByUid then
            local row = Items.GetByUid(seedUid)
            seedName = row and row.name
        end
        local genus = SM.GenusKeyFromName(seedName)
        if genus and genus ~= "" and SM.GetGenusLadder then
            seedLadder = SM.GetGenusLadder(genus)
        end
    end
    if type(plantLadder) == "table" and type(seedLadder) == "table" then
        -- Merge always: same genus can still miss a rung seed on one bucket view;
        -- different genus (Marsh Root / Marshroot) needs both sides.
        return MergeGenusLadders(plantLadder, seedLadder)
    end
    local plantMax = US.CultMaxNeedReq(plantLadder)
    local seedMax = US.CultMaxNeedReq(seedLadder)
    if seedMax > plantMax then
        return seedLadder
    end
    if plantMax > seedMax then
        return plantLadder
    end
    if RungCount(seedLadder) > RungCount(plantLadder) then
        return seedLadder
    end
    return plantLadder or seedLadder
end

--- Watched plant stock resolve (never retargets to Cult-max).
--- climbNeedReq = Cult-max rung when Upgrade Seeds is on (climb destination only).
function US.ResolvePlantWatchTarget(watchPlantUid, watchSpec)
    watchPlantUid = tonumber(watchPlantUid) or 0
    local Items = StockPiler.Items
    local SM = StockPiler.SeedMap
    local MS = StockPiler.MaterialSpec
    local Inv = StockPiler.Inventory
    local spec = watchSpec
    if type(spec) ~= "table" and watchPlantUid > 0 then
        if Items and Items.ToSpec then
            spec = Items.ToSpec(watchPlantUid)
        end
        if type(spec) ~= "table" and MS and MS.FromUid then
            spec = MS.FromUid(watchPlantUid)
        end
    end
    local plantUid = watchPlantUid
    local needReq = tonumber(spec and spec.skillLevel) or 0
    if needReq < 1 and plantUid > 0 and Inv and Inv.GetSample then
        local sample = Inv.GetSample(plantUid)
        needReq = tonumber(sample and sample.craftingSkillRequirement) or 0
    end
    if needReq < 1 then
        needReq = 1
    end
    local ladder = US.LadderForPlantWatch(spec, plantUid)
    local climbNeedReq = needReq
    if US.IsEnabled() == true then
        local cultMax = US.CultMaxNeedReq(ladder)
        if cultMax >= 1 then
            climbNeedReq = cultMax
        end
        -- Cult-usable destination is Cult floor. When the known ladder tops
        -- below that (marshroot L1+L25 only; Angry/Savage not yet discovered),
        -- keep climbNeed at floor so Upgrade Seeds keeps Special-Moment fishing.
        local cultFloor = US.FloorCultTier(US.GetCultSkill())
        if cultFloor > climbNeedReq then
            climbNeedReq = cultFloor
        end
    end
    local seedUid = 0
    if plantUid > 0 and SM and SM.ResolveSeedUidForPlant then
        seedUid = tonumber(SM.ResolveSeedUidForPlant(plantUid, spec)) or 0
    end
    if seedUid <= 0 and type(ladder) == "table" and type(ladder.rungs) == "table" then
        for i = 1, #ladder.rungs do
            local rung = ladder.rungs[i]
            if (tonumber(rung.skillReq) or 0) == needReq then
                seedUid = tonumber(rung.seedUid) or 0
                if seedUid > 0 then
                    break
                end
            end
        end
    end
    if seedUid <= 0 and type(spec) == "table" and SM and SM.ResolveSeedForSpec then
        local seed = SM.ResolveSeedForSpec(spec)
        if type(seed) == "table" then
            seedUid = tonumber(seed.uniqueID or seed.uid) or 0
        end
    end
    if seedUid <= 0 and plantUid > 0 and SM and SM.GetSeedUidsForPlant then
        local seeds = SM.GetSeedUidsForPlant(plantUid)
        if type(seeds) == "table" and #seeds > 0 then
            seedUid = tonumber(seeds[1]) or 0
        end
    end
    return {
        plantUid = plantUid,
        seedUid = seedUid,
        needReq = needReq,
        climbNeedReq = climbNeedReq,
        ladder = ladder,
        spec = spec,
        watchPlantUid = watchPlantUid,
        retargeted = false,
    }
end

--- Shared seed budget facade (Refine.GetSeedBudget).
function US.GetSeedBudget(seedUid)
    local Refine = StockPiler.Refine
    if Refine and Refine.GetSeedBudget then
        local b = Refine.GetSeedBudget(seedUid)
        if type(b) == "table" then
            return b
        end
    end
    return {
        live = 0,
        ground = 0,
        outstanding = 0,
        credit = 0,
        headroom = 0,
        bufferMin = 0,
    }
end

function US.CountEmptyPlots()
    local Grow = StockPiler.Grow
    if Grow and Grow.CountEmptyPlots then
        return tonumber(Grow.CountEmptyPlots()) or 0
    end
    return 0
end

--- Seeds still needed for planting / AutoBuy.
--- mode "climb" (default): with buffer on, buy to (buffer + empty) so climb surplus exists.
--- mode "skillup": max(headroom, empty-plot need) - AutoBuy / refine target only.
function US.SeedDeficit(seedUid, mode)
    seedUid = tonumber(seedUid) or 0
    mode = tostring(mode or "climb")
    local empty = US.CountEmptyPlots()
    local budget = US.GetSeedBudget(seedUid)
    local buffer = tonumber(budget.bufferMin) or 0
    local live = tonumber(budget.live) or 0
    local headroom = tonumber(budget.headroom) or 0
    local needPlots = empty
    if live >= empty then
        needPlots = 0
    else
        needPlots = empty - live
    end
    if mode == "skillup" then
        return math.max(headroom, needPlots)
    end
    -- Climb planting only uses surplus above the seed buffer, so AutoBuy must
    -- top up to (buffer + empty plots) or every harvest can wipe the rung.
    if buffer > 0 then
        return math.max(0, buffer + empty - live)
    end
    return math.max(headroom, needPlots)
end

--- How many bag seeds may be planted without dipping the keep cushion.
--- opts.mode "climb" (default): L1 prefers buffer but never stalls empty plots;
--- intermediate rungs keep 0 (not vendor-restocked).
--- opts.mode "skillup": always fill empty plots (min bag, empty). Planting moves
--- live->ground so seed-buffer *credit* is unchanged; PreferRefine + Apo plant
--- reserve protect the cushion. A keep-1 while buffer-short left empty plots idle
--- with 2 bag seeds (plantable=1) and stalled Cult XP.
--- opts.intermediate: climb-only - treat as non-vendor intermediate rung.
function US.PlantableSurplus(seedUid, bagSeeds, empty, opts)
    seedUid = tonumber(seedUid) or 0
    bagSeeds = tonumber(bagSeeds) or 0
    empty = tonumber(empty) or 0
    opts = type(opts) == "table" and opts or {}
    if bagSeeds < 1 or empty < 1 then
        return 0
    end
    local budget = US.GetSeedBudget(seedUid)
    local buffer = tonumber(budget.bufferMin) or 0
    local mode = tostring(opts.mode or "climb")
    if mode == "skillup" then
        return math.min(bagSeeds, empty)
    end
    -- Climb: intermediate rungs keep 0 - those seeds are not at the vendor; holding
    -- even 1 seed with empty plots stalls the climb (seen: have=50, plantable=0).
    if buffer <= 0 or opts.intermediate == true then
        return math.min(bagSeeds, empty)
    end
    -- L1 / vendor floor: prefer surplus above the seed buffer so AutoBuy can
    -- restock. If AutoBuy only filled the cushion (e.g. plots were full then),
    -- still plant into empties - otherwise Majestic Goldweed stays need_buy
    -- forever with 5 L1 seeds and open plots.
    local live = tonumber(budget.live) or bagSeeds
    local surplus = live - buffer
    if surplus >= 1 then
        return math.min(bagSeeds, empty, surplus)
    end
    return math.min(bagSeeds, empty)
end

local function SeedBudget(seedUid)
    return US.GetSeedBudget(seedUid)
end

local function CountEmptyPlots()
    return US.CountEmptyPlots()
end

local function PlantableSurplus(seedUid, bagSeeds, empty, opts)
    return US.PlantableSurplus(seedUid, bagSeeds, empty, opts)
end

local function LadderLowestReq(ladder)
    if type(ladder) ~= "table" or type(ladder.rungs) ~= "table" or #ladder.rungs < 1 then
        return 1
    end
    local lowest = tonumber(ladder.rungs[1].skillReq) or 1
    for i = 2, #ladder.rungs do
        local req = tonumber(ladder.rungs[i].skillReq) or 0
        if req >= 1 and req < lowest then
            lowest = req
        end
    end
    return lowest
end

--- True when bag seeds are not the vendor L1 cushion seed.
--- Multiplier/main ladders often start at 100+; treating that floor as "L1 buffer"
--- trapped Fusk 3010034 (live=1, buffer=5, plantable=0) while Spumepetal refined.
local function IsIntermediateClimb(ladder, ownedReq)
    ownedReq = tonumber(ownedReq) or 0
    local lowest = LadderLowestReq(ladder)
    if ownedReq > lowest then
        return true
    end
    if ownedReq > 1 then
        return true
    end
    return false
end

--- Plantable climb count for one upgrade target (0 if none / cannot plant).
local function TargetPlantableCount(t)
    if type(t) ~= "table" or type(t.ladder) ~= "table" then
        return 0, nil, 0
    end
    local needReq = tonumber(t.needReq) or 0
    local climbCap = US.ClimbCap(needReq)
    local owned = US.PickBestOwnedSeed({
        ladder = t.ladder,
        climbCap = climbCap,
    })
    if type(owned) ~= "table" or (tonumber(owned.seedUid) or 0) <= 0 then
        return 0, owned, climbCap
    end
    local seedUid = tonumber(owned.seedUid) or 0
    local ownedReq = tonumber(owned.skillReq) or 0
    local bagSeeds = tonumber(owned.count) or 0
    local empty = CountEmptyPlots()
    -- Bag-only "best seed" drops to L1 once the higher packet is in the ground.
    -- Block lower planting when a higher rung is still in bags/plants (refine
    -- those first). In-ground higher alone must NOT idle leftover empties -
    -- fill them with the best bag seed (often L1) so a failed crit does not
    -- leave plots unused.
    local achievedBags = BestOwnedReqOnLadder(t.ladder, climbCap, { excludeGround = true })
    if achievedBags > ownedReq then
        return 0, owned, climbCap
    end
    -- Destination rung already owned. Keep planting it only while the Cult-floor
    -- seed buffer is short AND no same-tier plants are waiting to refine into
    -- that buffer. Refining those plants comes first; a full buffer stops both.
    if needReq >= 1 and ownedReq >= needReq then
        if CultMaxTierBufferFull(t.ladder, needReq, t.plantUid, t.seedUid) == true then
            return 0, owned, climbCap
        end
        local plantUid = tonumber(owned.plantUid) or tonumber(t.plantUid) or 0
        local refinable = 0
        if plantUid > 0 and StockPiler.Refine and StockPiler.Refine.CountRefinablePlants then
            local Items = StockPiler.Items
            local spec = Items and Items.ToSpec and Items.ToSpec(plantUid) or t.spec
            refinable = tonumber(StockPiler.Refine.CountRefinablePlants(plantUid, spec)) or 0
        end
        if refinable >= 1 then
            return 0, owned, climbCap
        end
        local intermediate = IsIntermediateClimb(t.ladder, ownedReq)
        return PlantableSurplus(seedUid, bagSeeds, empty, {
            intermediate = intermediate,
        }), owned, climbCap
    end
    local intermediate = IsIntermediateClimb(t.ladder, ownedReq)
    local plantable = PlantableSurplus(seedUid, bagSeeds, empty, {
        intermediate = intermediate,
    })
    return plantable, owned, climbCap
end

--- Refine scan for one target (plants above owned seed rung).
--- Plant-watch buffer fill: also refine Cult-max plants while that seed buffer is short.
local function TargetUpgradePlant(t)
    if type(t) ~= "table" or type(t.ladder) ~= "table" then
        return nil, 0
    end
    local needReq = tonumber(t.needReq) or 0
    local climbCap = US.ClimbCap(needReq)
    local owned = US.PickBestOwnedSeed({
        ladder = t.ladder,
        climbCap = climbCap,
    })
    local ownedReq = type(owned) == "table" and (tonumber(owned.skillReq) or 0) or 0
    local refineCap = US.FloorCultTier(US.GetCultSkill())
    if refineCap < climbCap then
        refineCap = climbCap
    end
    local scanOwnedReq = ownedReq
    local watchPlantUid = tonumber(t.watchPlantUid) or 0
    if watchPlantUid > 0 and needReq >= 1
        and CultMaxTierBufferFull(t.ladder, needReq, t.plantUid, t.seedUid) ~= true
        and ownedReq >= needReq
    then
        -- Already own Cult-max seeds but buffer short: refine same-tier plants.
        scanOwnedReq = math.max(0, needReq - 1)
    end
    local up = US.ScanUpgradePlant({
        ladder = t.ladder,
        familyKey = t.familyKey or (t.ladder and t.ladder.key),
        climbCap = refineCap,
        ownedSeedReq = scanOwnedReq,
    })
    return up, ownedReq
end

--- Seed/plant uids on the needReq rung (Cult-max destination).
--- When the rung exists, use its uids only (s0 stays 0). Fallback applies only
--- when the ladder has no needReq rung - never inherit a lower-tier seed onto a
--- known orphan high rung (Spiderfrond L25 s0 + full Wispy buffer falsely ended climb).
local function RungUidsAtNeed(ladder, needReq, fallbackPlantUid, fallbackSeedUid)
    needReq = tonumber(needReq) or 0
    local seedUid = 0
    local plantUid = 0
    local found = false
    if type(ladder) == "table" and type(ladder.rungs) == "table" and needReq >= 1 then
        for i = 1, #ladder.rungs do
            local rung = ladder.rungs[i]
            if (tonumber(rung.skillReq) or 0) == needReq then
                found = true
                seedUid = tonumber(rung.seedUid) or 0
                plantUid = tonumber(rung.plantUid) or 0
                break
            end
        end
    end
    if not found then
        seedUid = tonumber(fallbackSeedUid) or 0
        plantUid = tonumber(fallbackPlantUid) or 0
    end
    return seedUid, plantUid
end

--- Plant-watch climb done: Cult-max tier seed buffer is full (credit >= buffer).
--- Buffer off: at least one Cult-max seed (or Cult-max plant when seed unknown).
--- Mid-ladder orphans (Cross@75 s0 while needReq=200) are a different rung and
--- do not satisfy Cult-max. Cult-max plant with s0 (Savage Marshroot) uses plant
--- bag count as the cushion so seed buffer / Upgrade Seeds stop SM-fishing.
--- Missing needReq rung on a known ladder (aspirational Cult-floor destination
--- before higher tiers are discovered) is NOT done - do not treat a lower-tier
--- fallback seed buffer as arrival.
CultMaxTierBufferFull = function(ladder, needReq, fallbackPlantUid, fallbackSeedUid)
    needReq = tonumber(needReq) or 0
    if needReq < 1 then
        return false
    end
    local hasLadder = type(ladder) == "table" and type(ladder.rungs) == "table" and #ladder.rungs > 0
    if hasLadder then
        local rungFound = false
        for i = 1, #ladder.rungs do
            if (tonumber(ladder.rungs[i].skillReq) or 0) == needReq then
                rungFound = true
                break
            end
        end
        if not rungFound then
            -- Family known but this Cult-floor tier is not on the ladder yet.
            return false
        end
    end
    local seedUid, plantUid = RungUidsAtNeed(ladder, needReq, fallbackPlantUid, fallbackSeedUid)
    seedUid = tonumber(seedUid) or 0
    plantUid = tonumber(plantUid) or 0
    local buffer = 0
    local Watch = StockPiler.Watch
    if Watch and Watch.IsSeedBufferEnabled and Watch.IsSeedBufferEnabled() == true
        and Watch.GetSeedBufferMin
    then
        buffer = tonumber(Watch.GetSeedBufferMin()) or 5
    end
    if seedUid > 0 then
        local budget = US.GetSeedBudget(seedUid)
        local credit = tonumber(budget.credit) or 0
        local bMin = tonumber(budget.bufferMin) or 0
        if bMin > buffer then
            buffer = bMin
        end
        if buffer < 1 then
            return credit >= 1
        end
        return credit >= buffer
    end
    if plantUid > 0 then
        local Inv = StockPiler.Inventory
        local have = Inv and Inv.CountByUid and tonumber(Inv.CountByUid(plantUid)) or 0
        if buffer < 1 then
            return have >= 1
        end
        return have >= buffer
    end
    return false
end

--- Have the target-tier seed/plant for this climb need?
--- Owned lower-tier seeds must not end the climb (ResolveSeedForSpec prefers bag
--- seeds and would falsely "arrive" at L25). Same-or-higher rung DOES count:
--- watching a mid plant while L200 seeds/plants sit in bag must not restart
--- Phase A arrive (needReq=watched) and AutoBuy L1 under a low ClimbCap.
--- In-ground target seeds count: bag-only checks left "Upgrading fusk 0->200 /
--- need_buy" after AutoGrow planted L200 for the seed buffer.
--- Orphan high plant with no known plantable seed on the rung does NOT count
--- (Fretting in bag, seedUid=0 on ladder falsely ended marshroot climb).
--- opts.requireBufferFull: plant-watch Cult-max climb - keep going until the
--- Cult-max seed buffer is full (not after the first Fretting plant).
HaveTargetRung = function(ladder, needReq, plantUid, seedUid, opts)
    needReq = tonumber(needReq) or 0
    opts = type(opts) == "table" and opts or {}
    if opts.requireBufferFull == true then
        return CultMaxTierBufferFull(ladder, needReq, plantUid, seedUid)
    end
    local requirePlant = opts.requirePlant == true
    local Inv = StockPiler.Inventory
    if not Inv or not Inv.CountByUid then
        return false
    end
    plantUid = tonumber(plantUid) or 0
    seedUid = tonumber(seedUid) or 0
    local Grow = StockPiler.Grow

    local function haveUid(uid)
        uid = tonumber(uid) or 0
        if uid <= 0 then
            return false
        end
        if (tonumber(Inv.CountByUid(uid)) or 0) >= 1 then
            return true
        end
        if Grow and Grow.CountSeedPlotCredit then
            return (tonumber(Grow.CountSeedPlotCredit(uid)) or 0) >= 1
        end
        if Grow and Grow.CountInGroundSeeds then
            return (tonumber(Grow.CountInGroundSeeds(uid)) or 0) >= 1
        end
        return false
    end

    local function rungArrived(rSeed, rPlant)
        rSeed = tonumber(rSeed) or 0
        rPlant = tonumber(rPlant) or 0
        if requirePlant then
            -- Legacy: Cult-max plant in bags only.
            return haveUid(rPlant)
        end
        if haveUid(rSeed) then
            return true
        end
        -- Plant alone only counts when the rung has a known plantable seed.
        if rSeed > 0 and haveUid(rPlant) then
            return true
        end
        return false
    end

    if type(ladder) == "table" and type(ladder.rungs) == "table" and needReq >= 1 then
        for i = 1, #ladder.rungs do
            local rung = ladder.rungs[i]
            local req = tonumber(rung.skillReq) or 0
            -- At-or-above: L200 stock satisfies a L50 watch arrive.
            if req >= needReq and rungArrived(rung.seedUid, rung.plantUid) then
                return true
            end
        end
        return false
    end
    -- Ladder missing: only trust explicit target plant/seed uids (seed required
    -- for plant-only arrive, same orphan rule).
    return rungArrived(seedUid, plantUid)
end

--- Plant-watch climb descriptor (stock N vs Cult-max existence).
--- pending = climb not finished; eligible = stocked, mid-climb, or arrive needed.
--- arriveNeeded: plant stock short and watched-tier seed/plant missing - climb to
--- that tier must run without waiting for WatchesAllowUpgradeClimb (else L200
--- watches with only lower seeds stall forever on "Seed buffer").
--- Arrive completes when HaveTargetRung (any plantable watched-tier seed/plant) -
--- not when every plot can be filled; plant watch + seed buffer take over after that.
--- Phase B (stocked + idle gate) keeps climbing until Cult-max seed buffer is full.
function US.DescribePlantWatchClimb(watchPlantUid)
    watchPlantUid = tonumber(watchPlantUid) or 0
    local out = {
        watchPlantUid = watchPlantUid,
        have = 0,
        target = 40,
        stocked = false,
        midClimb = false,
        arriveNeeded = false,
        haveLower = false,
        eligible = false,
        pending = false,
        climbNeedReq = 0,
        watchedReq = 1,
        ladder = nil,
        spec = nil,
        seedUid = 0,
        plantUid = watchPlantUid,
    }
    if watchPlantUid <= 0 or US.IsEnabled() ~= true then
        return out
    end
    local Watch = StockPiler.Watch
    local Catalog = StockPiler.Catalog
    local Inv = StockPiler.Inventory
    local plantKey = Watch and Watch.PlantKeyFromUid and Watch.PlantKeyFromUid(watchPlantUid)
        or ("plant:" .. tostring(watchPlantUid))
    local watch = Watch and Watch.GetPlantWatch and Watch.GetPlantWatch(plantKey) or nil
    if type(watch) ~= "table" then
        watch = Watch and Watch.GetPlantWatches and Watch.GetPlantWatches() or nil
        watch = type(watch) == "table" and watch[plantKey] or nil
    end
    out.target = tonumber(watch and watch.targetStock) or 40
    if Catalog and Catalog.PlantHave then
        out.have = tonumber(Catalog.PlantHave(watchPlantUid)) or 0
    elseif Inv and Inv.CountByUid then
        out.have = tonumber(Inv.CountByUid(watchPlantUid)) or 0
    end
    out.stocked = out.have >= out.target
    local resolved = US.ResolvePlantWatchTarget(watchPlantUid)
    out.spec = resolved and resolved.spec
    out.seedUid = tonumber(resolved and resolved.seedUid) or 0
    out.plantUid = tonumber(resolved and resolved.plantUid) or watchPlantUid
    out.watchedReq = tonumber(resolved and resolved.needReq) or 1
    out.climbNeedReq = tonumber(resolved and resolved.climbNeedReq) or out.watchedReq
    out.ladder = resolved and resolved.ladder
    local ladder = out.ladder
    local watchedReq = out.watchedReq
    local climbNeed = out.climbNeedReq
    local haveWatched = HaveTargetRung(ladder, watchedReq, out.plantUid, out.seedUid)
    if not out.stocked and not haveWatched then
        out.arriveNeeded = true
        local lowerCap = math.max(1, watchedReq - 1)
        local lowerBest = BestOwnedReqOnLadder(ladder, lowerCap)
        out.haveLower = lowerBest >= 1
    elseif not out.stocked and haveWatched then
        -- Higher-tier stock already covers watched arrive (e.g. L200 vs L50 watch).
        -- Still note lower seeds for UI; do not force Phase A climbNeedReq=watchedReq.
        local lowerCap = math.max(1, watchedReq - 1)
        out.haveLower = BestOwnedReqOnLadder(ladder, lowerCap) >= 1
    end
    if not out.stocked and type(ladder) == "table" and type(ladder.rungs) == "table"
        and Inv and Inv.CountByUid
    then
        local Grow = StockPiler.Grow
        local climbCap = US.ClimbCap(climbNeed)
        for i = 1, #ladder.rungs do
            local rung = ladder.rungs[i]
            local req = tonumber(rung.skillReq) or 0
            if req > watchedReq and req <= climbCap then
                local sUid = tonumber(rung.seedUid) or 0
                local pUid = tonumber(rung.plantUid) or 0
                if sUid > 0 then
                    local seedHave = tonumber(Inv.CountByUid(sUid)) or 0
                    if seedHave < 1 and Grow and Grow.CountSeedPlotCredit then
                        seedHave = tonumber(Grow.CountSeedPlotCredit(sUid)) or 0
                    end
                    if seedHave < 1 and Grow and Grow.CountInGroundSeeds then
                        seedHave = tonumber(Grow.CountInGroundSeeds(sUid)) or 0
                    end
                    if seedHave >= 1 then
                        out.midClimb = true
                        break
                    end
                end
                -- Higher-tier plant (e.g. Cross with no known seed) also latches mid-climb.
                if pUid > 0 and (tonumber(Inv.CountByUid(pUid)) or 0) >= 1 then
                    out.midClimb = true
                    break
                end
            end
        end
    end
    out.eligible = out.stocked or out.midClimb or out.arriveNeeded
    if out.arriveNeeded then
        -- Produce the watched-tier seed/plant so Grow can restock.
        out.pending = true
        out.climbNeedReq = watchedReq
    elseif out.stocked and climbNeed > watchedReq then
        -- Phase B until the Cult-floor seed buffer is full (not after the first
        -- destination seed). Do not clear pending via CultMaxNeedReq: a sparse
        -- ladder such as 1 -> 200 at Cult 25 would drop an L1 climb early.
        -- SkillUp yield is separate (IsActivelyClimbingPlantWatches).
        out.pending = HaveTargetRung(ladder, climbNeed, out.plantUid, out.seedUid, {
            requireBufferFull = true,
        }) ~= true
    elseif out.eligible and climbNeed <= watchedReq then
        -- Nowhere above watched tier on the known ladder.
        out.pending = false
    end
    return out
end

--- Seed-gap hint for plant-watch Status (works with Upgrade Seeds off).
--- haveTarget: watched-tier seed/plant credit exists; haveLower: genus below that tier.
function US.DescribePlantWatchSeedGap(watchPlantUid, watchSpec)
    watchPlantUid = tonumber(watchPlantUid) or 0
    local out = {
        watchPlantUid = watchPlantUid,
        seedUid = 0,
        plantUid = watchPlantUid,
        needReq = 1,
        genus = "plant",
        haveTarget = false,
        haveLower = false,
        lowerReq = 0,
        ladder = nil,
    }
    if watchPlantUid <= 0 then
        return out
    end
    local resolved = US.ResolvePlantWatchTarget(watchPlantUid, watchSpec)
    out.seedUid = tonumber(resolved and resolved.seedUid) or 0
    out.plantUid = tonumber(resolved and resolved.plantUid) or watchPlantUid
    out.needReq = tonumber(resolved and resolved.needReq) or 1
    out.ladder = resolved and resolved.ladder
    out.genus = tostring((out.ladder and out.ladder.genus) or "plant")
    out.haveTarget = HaveTargetRung(out.ladder, out.needReq, out.plantUid, out.seedUid) == true
    local lowerCap = math.max(1, out.needReq - 1)
    out.lowerReq = BestOwnedReqOnLadder(out.ladder, lowerCap)
    out.haveLower = out.lowerReq >= 1
    return out
end

--- True while Upgrade Seeds owns this plant watch for Cult-max climb (ephemeral row).
function US.IsPlantWatchOwnedByUpgrade(watchPlantUid)
    if US.IsEnabled() ~= true then
        return false
    end
    local d = US.DescribePlantWatchClimb(watchPlantUid)
    return d.eligible == true and d.pending == true
end

local function SeedBufferOkForIdle()
    local SE = StockPiler.SeedEconomy
    if SE and SE.SeedBufferOk then
        return SE.SeedBufferOk() == true
    end
    return true
end

local function PlantsStockedForUpgradeIdle()
    local SE = StockPiler.SeedEconomy
    if SE and SE.PlantWatchesStocked then
        return SE.PlantWatchesStocked() == true
    end
    return true
end

--- Idle gate for Cult-max / bag climbs (and SkillUp plant yield check).
--- Matches Level-up skills: WatchesDone, or all shorts progress-blocked with
--- seed buffer OK. Does not call SkillUp.WatchesAllowIdleSkillUp (that calls
--- IsActivelyClimbingPlantWatches and would recurse).
function US.WatchesAllowUpgradeClimb()
    if US.IsEnabled() ~= true then
        return false
    end
    local SkillUp = StockPiler.SkillUp
    if SkillUp and SkillUp.WatchesDone and SkillUp.WatchesDone() == true then
        return true
    end
    if SeedBufferOkForIdle() ~= true then
        return false
    end
    if SkillUp and SkillUp.AllShortWatchesProgressBlocked then
        return SkillUp.AllShortWatchesProgressBlocked() == true
    end
    local Watch = StockPiler.Watch
    if Watch and Watch.AllEnabledPotionWatchesStocked
        and Watch.AllEnabledPotionWatchesStocked() ~= true
    then
        return false
    end
    if PlantsStockedForUpgradeIdle() ~= true then
        return false
    end
    return true
end

--- Shared: scan bags for a refinable upgrade plant (any main family when no ladder).
--- opts: climbCap, mainsOnly, familyKey / ladder, ownedSeedReq
function US.ScanUpgradePlant(opts)
    opts = type(opts) == "table" and opts or {}
    local SM = StockPiler.SeedMap
    local climbCap = tonumber(opts.climbCap) or 0
    local ladder = opts.ladder
    if type(ladder) ~= "table" and opts.familyKey and SM and SM.GetFamilyLadder then
        ladder = SM.GetFamilyLadder(opts.familyKey)
    end
    local fam = tostring(opts.familyKey or "")
    if fam == "" and type(ladder) == "table" then
        fam = tostring(ladder.key or ladder.genus or "")
        if fam == "" and type(ladder.rungs) == "table" and type(ladder.rungs[1]) == "table" then
            fam = "r:" .. tostring(ladder.rungs[1].seedUid or 0)
                .. ":" .. tostring(ladder.rungs[1].plantUid or 0)
        end
    end
    local snapGen = 0
    local PS = StockPiler.PlanSnapshot
    local plan = PS and PS.Get and PS.Get()
    if type(plan) == "table" then
        snapGen = tonumber(plan.planGen) or 0
    end
    local invSnap = 0
    local Inv = StockPiler.Inventory
    if Inv and Inv.GetSnapGen then
        invSnap = tonumber(Inv.GetSnapGen()) or 0
    end
    local emptyPlots = US.CountEmptyPlots and US.CountEmptyPlots() or 0
    local cacheKey = tostring(snapGen) .. ":" .. tostring(invSnap)
        .. ":" .. tostring(climbCap)
        .. ":" .. fam .. ":" .. tostring(opts.ownedSeedReq or 0)
        .. ":" .. tostring(opts.mainsOnly == true)
        .. ":" .. tostring(emptyPlots)
    if US._scanPlantSnap ~= invSnap or type(US._scanPlantByKey) ~= "table" then
        US._scanPlantByKey = {}
        US._scanPlantSnap = invSnap
    end
    local cached = US._scanPlantByKey[cacheKey]
    if type(cached) == "table" and cached.seen == true then
        return cached.value
    end
    local function done(result)
        US._scanPlantByKey[cacheKey] = { seen = true, value = result }
        return result
    end
    if climbCap < 1 then
        return done(nil)
    end
    if type(ladder) == "table" and SM and SM.BestUpgradePlantOnLadder then
        return done(SM.BestUpgradePlantOnLadder(ladder, climbCap, opts.ownedSeedReq or 0, {
            mainsOnly = opts.mainsOnly == true,
        }))
    end
    -- Opportunistic (SkillUp): any main plant under climbCap above ownedSeedReq.
    local Items = StockPiler.Items
    local Refine = StockPiler.Refine
    if not (Inv and Inv.ForEachItem) then
        return done(nil)
    end
    local ownedSeedReq = tonumber(opts.ownedSeedReq) or 0
    local best = nil
    local bestReq = -1
    Inv.ForEachItem(function(item)
        if type(item) ~= "table" then
            return
        end
        if SM and SM.IsBagSeedOrSpore and SM.IsBagSeedOrSpore(item) then
            return
        end
        if SM and SM.ItemLooksLikeRefinablePlant
            and SM.ItemLooksLikeRefinablePlant(item) ~= true
            and item.isRefinable ~= true
        then
            return
        end
        local pUid = tonumber(item.uniqueID) or 0
        if pUid <= 0 then
            return
        end
        local spec = Items and Items.ToSpec and Items.ToSpec(pUid) or nil
        local role = tostring(spec and spec.role or "")
        if opts.mainsOnly == true and role ~= "" and role ~= "main" then
            return
        end
        local req = tonumber(spec and spec.skillLevel) or 0
        if req < 1 then
            req = tonumber(item.craftingSkillRequirement) or 0
        end
        if req <= ownedSeedReq or req > climbCap then
            return
        end
        local sUid = 0
        if SM and SM.ResolveSeedUidForPlant then
            sUid = tonumber(SM.ResolveSeedUidForPlant(pUid, spec)) or 0
        end
        if sUid <= 0 and SM and SM.GetSeedUidsForPlant then
            local seeds = SM.GetSeedUidsForPlant(pUid) or {}
            if type(seeds) == "table" and #seeds > 0 then
                sUid = tonumber(seeds[1]) or 0
            end
        end
        if sUid <= 0 then
            return
        end
        local refinable = 0
        if Refine and Refine.CountRefinablePlants then
            refinable = tonumber(Refine.CountRefinablePlants(pUid, spec)) or 0
        end
        if refinable <= 0 then
            return
        end
        if req > bestReq then
            bestReq = req
            best = {
                seedUid = sUid,
                plantUid = pUid,
                skillReq = req,
                refinable = refinable,
                upgrade = true,
            }
        end
    end)
    return done(best)
end

function US.PickBestOwnedSeed(opts)
    opts = type(opts) == "table" and opts or {}
    local SM = StockPiler.SeedMap
    local climbCap = tonumber(opts.climbCap) or 0
    if climbCap < 1 then
        return nil
    end
    local ladder = opts.ladder
    if type(ladder) ~= "table" and opts.familyKey and SM and SM.GetFamilyLadder then
        ladder = SM.GetFamilyLadder(opts.familyKey)
    end
    local invSnap = 0
    local Inv = StockPiler.Inventory
    if Inv and Inv.GetSnapGen then
        invSnap = tonumber(Inv.GetSnapGen()) or 0
    end
    local fam = tostring(opts.familyKey or "")
    if fam == "" and type(ladder) == "table" then
        fam = tostring(ladder.key or ladder.genus or "")
    end
    local cacheKey = tostring(invSnap) .. ":" .. tostring(climbCap)
        .. ":" .. fam .. ":" .. tostring(opts.mainsOnly == true)
    if US._ownedSeedSnap ~= invSnap or type(US._ownedSeedByKey) ~= "table" then
        US._ownedSeedByKey = {}
        US._ownedSeedSnap = invSnap
    end
    local cached = US._ownedSeedByKey[cacheKey]
    if type(cached) == "table" and cached.seen == true then
        return cached.value
    end
    local result = nil
    if type(ladder) == "table" and SM and SM.BestOwnedSeedOnLadder then
        result = SM.BestOwnedSeedOnLadder(ladder, climbCap, { mainsOnly = opts.mainsOnly == true })
    end
    US._ownedSeedByKey[cacheKey] = { seen = true, value = result }
    return result
end

--- Collect climb targets: potion mat shorts + enabled plant watches.
local function CollectUpgradeTargets()
    local RS = StockPiler.RecipeSpec
    local SM = StockPiler.SeedMap
    local Watch = StockPiler.Watch
    local Items = StockPiler.Items
    local MS = StockPiler.MaterialSpec
    local Catalog = StockPiler.Catalog
    local Inv = StockPiler.Inventory
    if not (SM and Watch and Watch.IsAutoGrowEnabled and Watch.IsAutoGrowEnabled() == true) then
        return {}
    end
    local out = {}
    local seenPlant = {}

    local function LadderFor(spec)
        if SM.GetGenusLadderForSpec then
            return SM.GetGenusLadderForSpec(spec)
        end
        return SM.GetFamilyLadderForSpec and SM.GetFamilyLadderForSpec(spec) or nil
    end

    local function NeedReqFor(spec, plantUid)
        local needReq = tonumber(spec and spec.skillLevel) or 0
        if needReq < 1 and plantUid > 0 and Inv and Inv.GetSample then
            local sample = Inv.GetSample(plantUid)
            needReq = tonumber(sample and sample.craftingSkillRequirement) or 0
        end
        if needReq < 1 then
            needReq = 1
        end
        return needReq
    end

    --- opts.needReq / opts.seedUid / opts.watchPlantUid / opts.ladder (plant-watch climb).
    local function Consider(spec, short, plantUidHint, opts)
        opts = type(opts) == "table" and opts or nil
        if type(spec) ~= "table" or (tonumber(short) or 0) < 1 then
            return
        end
        if not (SM.IsGrowableSpec and SM.IsGrowableSpec(spec) == true) then
            return
        end
        if SM.IsHarvestByproduct and SM.IsHarvestByproduct(spec) == true then
            return
        end
        local plantUid = tonumber(plantUidHint) or 0
        if plantUid <= 0 and SM.FindPlantUidForSpec then
            plantUid = tonumber(SM.FindPlantUidForSpec(spec)) or 0
        end
        if plantUid > 0 and seenPlant[plantUid] == true then
            return
        end
        local needReq = (opts and tonumber(opts.needReq)) or 0
        if needReq < 1 then
            needReq = NeedReqFor(spec, plantUid)
        end
        local ladder = (opts and opts.ladder) or nil
        if type(ladder) ~= "table" then
            ladder = LadderFor(spec)
        end
        local seedUid = (opts and tonumber(opts.seedUid)) or 0
        -- Prefer skill-matched plant->seed link; ResolveSeedForSpec prefers any
        -- owned genus seed in bags and would pin climb to L25 Gobswort spores.
        if seedUid <= 0 and plantUid > 0 and SM.ResolveSeedUidForPlant then
            seedUid = tonumber(SM.ResolveSeedUidForPlant(plantUid, spec)) or 0
        end
        if seedUid <= 0 and type(ladder) == "table" and type(ladder.rungs) == "table" then
            for i = 1, #ladder.rungs do
                local rung = ladder.rungs[i]
                if (tonumber(rung.skillReq) or 0) == needReq then
                    seedUid = tonumber(rung.seedUid) or 0
                    if seedUid > 0 then
                        break
                    end
                end
            end
        end
        if seedUid <= 0 and SM.ResolveSeedForSpec then
            local seed = SM.ResolveSeedForSpec(spec)
            if type(seed) == "table" then
                seedUid = tonumber(seed.uniqueID or seed.uid) or 0
            end
        end
        if seedUid <= 0 and plantUid > 0 and SM.GetSeedUidsForPlant then
            local seeds = SM.GetSeedUidsForPlant(plantUid)
            if type(seeds) == "table" and #seeds > 0 then
                seedUid = tonumber(seeds[1]) or 0
            end
        end
        if HaveTargetRung(ladder, needReq, plantUid, seedUid, {
            -- Phase B Cult-max plant-watch: keep climbing until seed buffer full.
            -- Phase A arrive / potion demand: one target seed/plant is enough.
            requireBufferFull = opts and opts.requireBufferFull == true,
        }) then
            return
        end
        if plantUid > 0 then
            seenPlant[plantUid] = true
        end
        out[#out + 1] = {
            spec = spec,
            needReq = needReq,
            short = tonumber(short) or 0,
            ladder = ladder,
            plantUid = plantUid,
            seedUid = seedUid,
            familyKey = ladder and ladder.key or nil,
            watchPlantUid = (opts and tonumber(opts.watchPlantUid)) or 0,
        }
    end

    -- Potion / balanced demand (growable mats short). Read the cached demand
    -- only. A hold or a cold miss must not be stored as this snap's targets.
    local Sch = StockPiler.Scheduler
    local held = Sch and Sch.IsOrchDecisionHold and Sch.IsOrchDecisionHold() == true
    local demand = RS and RS.BuildBalancedSpecDemand
        and RS.BuildBalancedSpecDemand({ cacheOnly = true }) or nil
    US._upgradeDemandStale = (demand == nil) or (held == true)
    if type(demand) == "table" then
        for _, row in pairs(demand) do
            if type(row) == "table" and type(row.spec) == "table" then
                local absNeed = tonumber(row.absolute) or tonumber(row.brewAbsolute) or 0
                local have = 0
                if RS.CountItemsMatchingSpec then
                    have = tonumber(RS.CountItemsMatchingSpec(row.spec)) or 0
                end
                local short = math.max(0, absNeed - have)
                if short < 1 then
                    short = tonumber(row.craftsShort) or 0
                end
                Consider(row.spec, short, nil)
            end
        end
    end

--- Explicit plant watches:
    -- Phase A arrive: stock short + missing watched-tier seed -> climb to watchedReq
    -- until at least one plantable target-tier seed/plant exists (same as potion-mat
    -- arrive). Then the plant watch owns restock / seed buffer; ephemeral clears.
    -- Phase B Cult-max: after watches/buffer idle gate, climb until Cult-max seed
    -- buffer is full (requireBufferFull). SkillUp is separate (fills every empty plot).
    local allowPlantClimb = US.WatchesAllowUpgradeClimb() == true
    local plantWatches = Watch.GetPlantWatches and Watch.GetPlantWatches() or {}
    if type(plantWatches) == "table" then
        for plantKey, watch in pairs(plantWatches) do
            if type(watch) == "table" and watch.enabled == true
                and (Watch.ShouldAutoGrowPlant == nil or Watch.ShouldAutoGrowPlant(plantKey) == true)
            then
                local watchPlantUid = Watch.ParsePlantKey and Watch.ParsePlantKey(plantKey) or 0
                watchPlantUid = tonumber(watchPlantUid) or 0
                if watchPlantUid > 0 then
                    local d = US.DescribePlantWatchClimb(watchPlantUid)
                    if d.arriveNeeded == true then
                        local short = math.max(1, (tonumber(d.target) or 40) - (tonumber(d.have) or 0))
                        Consider(d.spec, short, watchPlantUid, {
                            needReq = d.watchedReq or d.climbNeedReq,
                            seedUid = d.seedUid,
                            ladder = d.ladder,
                            watchPlantUid = watchPlantUid,
                        })
                    elseif d.stocked == true and allowPlantClimb and d.eligible == true and d.pending == true then
                        Consider(d.spec, 1, watchPlantUid, {
                            needReq = d.climbNeedReq,
                            seedUid = d.seedUid,
                            ladder = d.ladder,
                            watchPlantUid = watchPlantUid,
                            requireBufferFull = true,
                        })
                    end
                end
            end
        end
    end

    -- Potion AutoGrow seed-buffer lines missing Cult-max / target-tier stock.
    -- Must not wait on WatchesAllowUpgradeClimb: that gate requires SeedBufferOk,
    -- which stays false while these lines are empty (Draught stimulant Marshroot
    -- stuck on "Seed buffer" with no climb and no L1 AutoBuy).
    if Watch.IsSeedBufferEnabled and Watch.IsSeedBufferEnabled() == true then
        local lines = RS and RS.CollectAutoGrowSeedLines and RS.CollectAutoGrowSeedLines() or nil
        if type(lines) ~= "table" and StockPiler.Planner and StockPiler.Planner.CollectAutoGrowSeedLines then
            lines = StockPiler.Planner.CollectAutoGrowSeedLines()
        end
        local buffer = Watch.GetSeedBufferMin and tonumber(Watch.GetSeedBufferMin()) or 5
        if buffer < 1 then
            buffer = 1
        end
        if type(lines) == "table" then
            for i = 1, #lines do
                local line = lines[i]
                if type(line) == "table" and type(line.spec) == "table" then
                    local plantUid = tonumber(line.plantUid) or 0
                    local seedUid = tonumber(line.seedUid) or 0
                    if plantUid > 0 and seenPlant[plantUid] ~= true then
                        local credit = 0
                        if seedUid > 0 then
                            local budget = US.GetSeedBudget and US.GetSeedBudget(seedUid)
                            credit = tonumber(budget and budget.credit) or 0
                        elseif Inv and Inv.CountByUid then
                            credit = tonumber(Inv.CountByUid(plantUid)) or 0
                        end
                        if credit < buffer then
                            local needReq = NeedReqFor(line.spec, plantUid)
                            local ladder = LadderFor(line.spec)
                            if not HaveTargetRung(ladder, needReq, plantUid, seedUid, {
                                requireBufferFull = true,
                            }) then
                                Consider(line.spec, math.max(1, buffer - credit), plantUid, {
                                    needReq = needReq,
                                    seedUid = seedUid,
                                    ladder = ladder,
                                    requireBufferFull = true,
                                })
                            end
                        end
                    end
                end
            end
        end
    end

    table.sort(out, function(a, b)
        return (tonumber(a.short) or 0) > (tonumber(b.short) or 0)
    end)
    return out
end

local function UpgradeTargetsCacheKey()
    local Inv = StockPiler.Inventory
    local Watch = StockPiler.Watch
    local snapGen = 0
    local watchGen = 0
    if Inv and Inv.GetSnapGen then
        snapGen = tonumber(Inv.GetSnapGen()) or 0
    end
    if Watch and Watch.GetGen then
        watchGen = tonumber(Watch.GetGen()) or 0
    end
    -- Cult floor gates ClimbCap; include so skill-ups invalidate without bag churn.
    -- Do NOT key on WatchesAllowUpgradeClimb(): that calls IsSeedBufferSatisfied /
    -- AllShortWatchesProgressBlocked and re-entered CollectUpgradeTargets (stack overflow).
    local cult = 0
    if US.GetCultSkill then
        cult = math.floor((tonumber(US.GetCultSkill()) or 0) / 25)
    end
    return tostring(snapGen) .. ":" .. tostring(watchGen) .. ":" .. tostring(cult)
        .. ":" .. tostring(US.IsEnabled() == true)
end

function US.InvalidateUpgradeTargetsCache()
    US._upgradeTargetsCache = nil
    US._upgradeTargetsKey = nil
    US._activelyClimbingFrame = nil
    US._activelyClimbingCached = nil
end

--- True only when the snap/watch cache is fresh and holds a climb target.
--- Does not Collect. A stale cache is not a reason to bag-walk on an empty pick.
function US.FreshTargetsPending()
    if US.IsEnabled() ~= true then
        return false
    end
    local key = UpgradeTargetsCacheKey()
    if US._upgradeTargetsKey ~= key or type(US._upgradeTargetsCache) ~= "table" then
        return false
    end
    return #US._upgradeTargetsCache > 0
end

--- Snap/watch-keyed cache over CollectUpgradeTargets (NeedsRefineFirst / PickPlantJob / status).
local function GetUpgradeTargets()
    -- Re-entrancy: cache is only published after Collect finishes. GrowReserve ->
    -- ShouldCultGrow -> WatchesAllowIdle -> IsActivelyClimbing used to call here while
    -- Collect was already running and blew the C stack (uilog 0.3.348).
    if US._upgradeTargetsBuilding == true then
        if type(US._upgradeTargetsCache) == "table" then
            return US._upgradeTargetsCache
        end
        return {}
    end
    local key = UpgradeTargetsCacheKey()
    if US._upgradeTargetsKey == key and type(US._upgradeTargetsCache) == "table" then
        return US._upgradeTargetsCache
    end
    US._upgradeTargetsBuilding = true
    local ok, out = pcall(CollectUpgradeTargets)
    US._upgradeTargetsBuilding = false
    local stale = US._upgradeDemandStale == true
    US._upgradeDemandStale = nil
    if ok ~= true or type(out) ~= "table" then
        out = type(US._upgradeTargetsCache) == "table" and US._upgradeTargetsCache or {}
        US._upgradeTargetsCache = out
        US._upgradeTargetsKey = key
        return out
    end
    if stale then
        if type(US._upgradeTargetsCache) == "table" then
            return US._upgradeTargetsCache
        end
        return out
    end
    US._upgradeTargetsCache = out
    US._upgradeTargetsKey = key
    return out
end

function US.NeedsRefineFirst()
    if US.IsEnabled() ~= true then
        return false
    end
    local frame = tonumber(StockPiler.FrameCounter) or 0
    local memoKey = tostring(frame) .. ":" .. tostring(US._upgradeTargetsKey)
    if US._needsRefineKey == memoKey and US._needsRefineHit == true then
        return US._needsRefineValue == true
    end
    local targets = GetUpgradeTargets()
    memoKey = tostring(frame) .. ":" .. tostring(US._upgradeTargetsKey)
    local anyRefine = false
    local anyPlantable = false
    for i = 1, #targets do
        local t = targets[i]
        local climbCap = US.ClimbCap(t.needReq)
        if climbCap < t.needReq and climbCap < 1 then
            -- gated
        else
            local up = TargetUpgradePlant(t)
            if type(up) == "table" and (tonumber(up.plantUid) or 0) > 0 then
                anyRefine = true
            end
            local plantable = TargetPlantableCount(t)
            if (tonumber(plantable) or 0) >= 1 then
                anyPlantable = true
            end
        end
    end
    -- Only skip demand/plant when refine is the only climb work.
    -- Spumepetal refine must not starve Fusk (or other) plantable climb seeds.
    local result = anyRefine == true and anyPlantable ~= true
    US._needsRefineKey = memoKey
    US._needsRefineHit = true
    US._needsRefineValue = result
    return result
end

--- Hold empty plots while refine can still fill a climb, and release them when
--- a stuck climb has nothing to plant or refine (that deadlock starved SkillUp
--- after the first Cult-floor seed). A sibling that can plant also releases.
function US.ShouldHoldEmptyPlots(climb)
    if US.IsEnabled() ~= true then
        return false
    end
    local why = tostring(type(climb) == "table" and climb.why or "")
    if why == "refining" then
        -- Refine armed and PickPlantJob found no plantable elsewhere.
        return true
    end
    if why ~= "climbing" and why ~= "need_buy" and why ~= "no_family" then
        return false
    end
    local targets = GetUpgradeTargets()
    local anyProgress = false
    for i = 1, #targets do
        local t = targets[i]
        local plantable = TargetPlantableCount(t)
        if (tonumber(plantable) or 0) >= 1 then
            return false
        end
        local up = TargetUpgradePlant(t)
        if type(up) == "table" and (tonumber(up.plantUid) or 0) > 0 then
            anyProgress = true
        end
    end
    if not anyProgress then
        return false
    end
    return true
end

function US.PickPlantJob()
    if US.IsEnabled() ~= true then
        US._active = nil
        return nil
    end
    local Watch = StockPiler.Watch
    if not (Watch and Watch.IsAutoGrowEnabled and Watch.IsAutoGrowEnabled() == true) then
        return nil
    end
    if CountEmptyPlots() <= 0 then
        return nil
    end
    local SM = StockPiler.SeedMap
    local targets = GetUpgradeTargets()
    local refineActive = nil
    local stallActive = nil
    local plantCandidates = {}
    for i = 1, #targets do
        local t = targets[i]
        local needReq = tonumber(t.needReq) or 0
        local climbCap = US.ClimbCap(needReq)
        local cultFloor = US.FloorCultTier(US.GetCultSkill())
        if cultFloor < 1 then
            US._active = {
                familyKey = t.familyKey,
                haveReq = 0,
                needReq = needReq,
                why = "need_cult",
                genus = t.ladder and t.ladder.genus,
                needCult = needReq,
            }
            return nil
        end
        if type(t.ladder) ~= "table" or type(t.ladder.rungs) ~= "table" or #t.ladder.rungs == 0 then
            stallActive = stallActive or {
                familyKey = t.familyKey,
                haveReq = 0,
                needReq = needReq,
                why = "no_family",
                genus = SM and SM.GenusKeyFromName and SM.GenusKeyFromName(t.spec and t.spec.name),
            }
        else
            local up, ownedReq = TargetUpgradePlant(t)
            local upgradePlantReq = 0
            if type(up) == "table" and (tonumber(up.plantUid) or 0) > 0 then
                upgradePlantReq = tonumber(up.skillReq) or 0
                if StockPiler.Refine and StockPiler.Refine.MarkRefineDue then
                    StockPiler.Refine.MarkRefineDue("upgrade-seed")
                end
                refineActive = refineActive or {
                    familyKey = t.ladder.key,
                    haveReq = ownedReq,
                    needReq = needReq,
                    why = "refining",
                    genus = t.ladder.genus,
                }
                -- Continue: another family (e.g. Fusk) may still have plantable seeds.
            end
            local plantable, owned = TargetPlantableCount(t)
            if type(owned) == "table" and (tonumber(owned.seedUid) or 0) > 0 then
                local seedUid = tonumber(owned.seedUid) or 0
                ownedReq = tonumber(owned.skillReq) or 0
                local budget = SeedBudget(seedUid)
                local headroom = tonumber(budget.headroom) or 0
                local buffer = tonumber(budget.bufferMin) or 0
                local bagSeeds = tonumber(owned.count) or 0
                local empty = CountEmptyPlots()
                local plantUid = tonumber(owned.plantUid) or 0
                local refinable = 0
                if plantUid > 0 and StockPiler.Refine and StockPiler.Refine.CountRefinablePlants then
                    local Items = StockPiler.Items
                    local spec = Items and Items.ToSpec and Items.ToSpec(plantUid) or nil
                    refinable = tonumber(StockPiler.Refine.CountRefinablePlants(plantUid, spec)) or 0
                end
                local intermediate = IsIntermediateClimb(t.ladder, ownedReq)
                -- Do not plant a lower rung while higher-tier plants sit in bag
                -- (L1 Fusk 3010030 filled all plots while Cloudy Fusk waited to refine).
                local plantGoesBackward = upgradePlantReq > ownedReq
                -- Exception: destination-tier plants in bag but Cult-max / needReq
                -- seed buffer still short - keep planting the best owned plantable
                -- rung (SM fishing / refine-fail insurance). Mid-climb already felt
                -- fine because higher plants were below needReq; a few L200 plants
                -- used to stall all L175 planting via no-backslide alone.
                if plantGoesBackward
                    and upgradePlantReq >= needReq
                    and CultMaxTierBufferFull(t.ladder, needReq, t.plantUid, t.seedUid) ~= true
                then
                    plantGoesBackward = false
                end
                local plotCredit = 0
                local Grow = StockPiler.Grow
                if Grow and Grow.CountSeedPlotCredit then
                    plotCredit = tonumber(Grow.CountSeedPlotCredit(seedUid)) or 0
                elseif Grow and Grow.CountInGroundSeeds then
                    plotCredit = tonumber(Grow.CountInGroundSeeds(seedUid)) or 0
                end
                local settleDeferred = false
                if StockPiler.Refine and StockPiler.Refine.SeedBufferSettleDeferred then
                    settleDeferred = StockPiler.Refine.SeedBufferSettleDeferred(seedUid) == true
                else
                    settleDeferred = plotCredit > 0 and empty < 1
                end
                -- Buffer refine wake: allow while empty plots remain (shared settle rule).
                if buffer > 0 and headroom > 0 and refinable > 0
                    and settleDeferred ~= true
                    and (not intermediate or bagSeeds < 1)
                then
                    if StockPiler.Refine and StockPiler.Refine.MarkRefineDue then
                        StockPiler.Refine.MarkRefineDue("upgrade-seed-buffer")
                    end
                    refineActive = refineActive or {
                        familyKey = t.ladder.key,
                        haveReq = ownedReq,
                        needReq = needReq,
                        why = "refining",
                        genus = t.ladder.genus,
                    }
                elseif plantable < 1 and empty > 0 and refinable > 0 then
                    if StockPiler.Refine and StockPiler.Refine.MarkRefineDue then
                        StockPiler.Refine.MarkRefineDue("upgrade-seed-reseed")
                    end
                    refineActive = refineActive or {
                        familyKey = t.ladder.key,
                        haveReq = ownedReq,
                        needReq = needReq,
                        why = "refining",
                        genus = t.ladder.genus,
                    }
                elseif plantable >= 1 and plantGoesBackward ~= true then
                    plantCandidates[#plantCandidates + 1] = {
                        seedUid = seedUid,
                        plantUid = plantUid,
                        bagSeeds = bagSeeds,
                        plantable = plantable,
                        ownedReq = ownedReq,
                        needReq = needReq,
                        short = tonumber(t.short) or 0,
                        intermediate = intermediate == true,
                        familyKey = t.ladder.key,
                        genus = t.ladder.genus,
                        targetIndex = i,
                    }
                elseif plantable >= 1 and plantGoesBackward == true then
                    if StockPiler.Refine and StockPiler.Refine.MarkRefineDue then
                        StockPiler.Refine.MarkRefineDue("upgrade-seed-no-backslide")
                    end
                    refineActive = refineActive or {
                        familyKey = t.ladder.key,
                        haveReq = ownedReq,
                        needReq = needReq,
                        why = "refining",
                        genus = t.ladder.genus,
                    }
                elseif empty < 1 then
                    stallActive = stallActive or {
                        familyKey = t.ladder.key,
                        haveReq = ownedReq,
                        needReq = needReq,
                        why = "climbing",
                        genus = t.ladder.genus,
                    }
                elseif climbCap < needReq and ownedReq >= climbCap then
                    stallActive = stallActive or {
                        familyKey = t.ladder.key,
                        haveReq = ownedReq,
                        needReq = needReq,
                        why = "need_cult",
                        genus = t.ladder.genus,
                        needCult = needReq,
                    }
                elseif not intermediate and US.SeedDeficit(seedUid) >= 1 then
                    stallActive = stallActive or {
                        familyKey = t.ladder.key,
                        haveReq = ownedReq,
                        needReq = needReq,
                        why = "need_buy",
                        genus = t.ladder.genus,
                    }
                else
                    stallActive = stallActive or {
                        familyKey = t.ladder.key,
                        haveReq = ownedReq,
                        needReq = needReq,
                        why = "climbing",
                        genus = t.ladder.genus,
                    }
                end
            elseif climbCap < needReq and ownedReq >= climbCap and ownedReq > 0 then
                stallActive = stallActive or {
                    familyKey = t.ladder.key,
                    haveReq = ownedReq,
                    needReq = needReq,
                    why = "need_cult",
                    genus = t.ladder.genus,
                    needCult = needReq,
                }
            else
                stallActive = stallActive or {
                    familyKey = t.ladder.key,
                    haveReq = ownedReq,
                    needReq = needReq,
                    why = "need_buy",
                    genus = t.ladder.genus,
                }
            end
        end
    end
    if #plantCandidates > 0 then
        -- Prefer the behind family (lowest owned seed rung), not the largest potion short.
        -- Spumepetal@150 with short=24 used to starve Fusk@125 before any Fusk seeds landed.
        table.sort(plantCandidates, function(a, b)
            local oa = tonumber(a.ownedReq) or 0
            local ob = tonumber(b.ownedReq) or 0
            if oa ~= ob then
                return oa < ob
            end
            return (tonumber(a.short) or 0) > (tonumber(b.short) or 0)
        end)
        local function VendorOpen()
            local VA = StockPiler.VendorAdapter
            return VA and VA.IsStoreOpen and VA.IsStoreOpen() == true
        end
        local function SiblingCanPlantNow(t2, index)
            if type(t2) ~= "table" then
                return false
            end
            if type(t2.ladder) ~= "table" or type(t2.ladder.rungs) ~= "table" or #t2.ladder.rungs == 0 then
                return false
            end
            for ci = 1, #plantCandidates do
                if (tonumber(plantCandidates[ci].targetIndex) or 0) == index then
                    return true
                end
            end
            local plantable = TargetPlantableCount(t2)
            if (tonumber(plantable) or 0) >= 1 then
                return true
            end
            -- need_buy holds a climb only while a vendor can actually sell the seed.
            if VendorOpen() then
                return true
            end
            return false
        end
        local function SiblingBehind(cand)
            for i = 1, #targets do
                if i ~= (tonumber(cand.targetIndex) or 0) then
                    local t2 = targets[i]
                    if SiblingCanPlantNow(t2, i) then
                        local owned2 = US.PickBestOwnedSeed({
                            ladder = t2.ladder,
                            climbCap = US.ClimbCap(t2.needReq),
                        })
                        local req2 = type(owned2) == "table" and (tonumber(owned2.skillReq) or 0) or 0
                        if req2 < (tonumber(cand.ownedReq) or 0) then
                            return true
                        end
                    end
                end
            end
            return false
        end
        local function PlotsHoldingSeed(seedUid)
            seedUid = tonumber(seedUid) or 0
            if seedUid <= 0 then
                return 0
            end
            local Grow = StockPiler.Grow
            if Grow and Grow.CountSeedPlotCredit then
                return tonumber(Grow.CountSeedPlotCredit(seedUid)) or 0
            end
            if Grow and Grow.CountInGroundSeeds then
                return tonumber(Grow.CountInGroundSeeds(seedUid)) or 0
            end
            return 0
        end
        local best = nil
        for ci = 1, #plantCandidates do
            local cand = plantCandidates[ci]
            local behind = SiblingBehind(cand)
            -- Cap is per-wave, not per-job: plantable=1 still re-picked every tick and
            -- filled all 4 plots. Skip an ahead family that already holds a plot.
            if behind == true and cand.intermediate == true
                and PlotsHoldingSeed(cand.seedUid) >= 1
            then
                cand = nil
            end
            if cand ~= nil then
                best = cand
                if behind == true and best.intermediate == true then
                    best.plantable = 1
                end
                break
            end
        end
        if best == nil then
            -- Ahead family already occupies a plot; leave empties for the behind family.
            if refineActive then
                US._active = refineActive
            elseif stallActive then
                US._active = stallActive
            end
            return nil
        end
        US._active = {
            familyKey = best.familyKey,
            haveReq = best.ownedReq,
            needReq = best.needReq,
            why = "planting",
            genus = best.genus,
            seedUid = best.seedUid,
            plantUid = best.plantUid,
        }
        US._stallLatch = nil
        local Inv = StockPiler.Inventory
        local sample = Inv and Inv.GetSample and Inv.GetSample(best.seedUid)
        return {
            seedUid = best.seedUid,
            plantUid = best.plantUid,
            seed = sample or { uniqueID = best.seedUid },
            seedHave = best.bagSeeds,
            plantable = tonumber(best.plantable) or 1,
            deficit = tonumber(best.plantable) or 1,
            plantReason = "upgrade_seed",
            pickMode = "upgrade_seed",
            familyKey = best.familyKey,
            skillReq = best.ownedReq,
            needReq = best.needReq,
        }
    end
    if refineActive then
        US._active = refineActive
        return nil
    end
    if stallActive then
        US._active = stallActive
        return nil
    end
    -- No targets (e.g. plant watch unmarked): drop stale active so UI/orch stop.
    US._active = nil
    return nil
end

function US.AppendRefineIntents(intents, appendFn)
    if type(appendFn) ~= "function" then
        return
    end
    if US.IsEnabled() ~= true then
        return
    end
    local targets = GetUpgradeTargets()
    local SM = StockPiler.SeedMap
    for i = 1, #targets do
        local t = targets[i]
        if type(t.ladder) == "table" then
            local climbCap = US.ClimbCap(t.needReq)
            local owned = US.PickBestOwnedSeed({
                ladder = t.ladder,
                climbCap = climbCap,
            })
            local ownedReq = type(owned) == "table" and (tonumber(owned.skillReq) or 0) or 0
            local refineCap = US.FloorCultTier(US.GetCultSkill())
            if refineCap < climbCap then
                refineCap = climbCap
            end
            local up = US.ScanUpgradePlant({
                ladder = t.ladder,
                familyKey = t.familyKey or (t.ladder and t.ladder.key),
                climbCap = refineCap,
                ownedSeedReq = ownedReq,
            })
            if type(up) == "table" and (tonumber(up.plantUid) or 0) > 0 then
                local seedUid = tonumber(up.seedUid) or 0
                local plantUid = tonumber(up.plantUid) or 0
                if seedUid <= 0 and SM and SM.ResolveSeedUidForPlant then
                    seedUid = tonumber(SM.ResolveSeedUidForPlant(plantUid, nil)) or 0
                end
                local budget = SeedBudget(seedUid)
                local Items = StockPiler.Items
                local spec = Items and Items.ToSpec and Items.ToSpec(plantUid) or nil
                local Refine = StockPiler.Refine
                local refinable = tonumber(up.refinable) or 0
                if refinable < 1 and Refine and Refine.CountRefinablePlants then
                    refinable = tonumber(Refine.CountRefinablePlants(plantUid, spec)) or 0
                end
                local uses = math.min(refinable, 5)
                if uses >= 1 then
                    appendFn({
                        spec = spec,
                        seedUid = seedUid,
                        plantUid = plantUid,
                        specKey = "upgrade_seed:" .. tostring(seedUid),
                    }, "upgrade-seed", uses, budget)
                    return
                end
            end
            -- Buffer refine for owned climb seed (settle only when garden full;
            -- empty plots still refine up to headroom - see SeedBufferSettleDeferred).
            if type(owned) == "table" and (tonumber(owned.seedUid) or 0) > 0 then
                local seedUid = tonumber(owned.seedUid) or 0
                local plantUid = tonumber(owned.plantUid) or 0
                local Refine = StockPiler.Refine
                local settleDeferred = false
                if Refine and Refine.SeedBufferSettleDeferred then
                    settleDeferred = Refine.SeedBufferSettleDeferred(seedUid) == true
                else
                    local Grow = StockPiler.Grow
                    if Grow and Grow.CountSeedPlotCredit then
                        settleDeferred = (tonumber(Grow.CountSeedPlotCredit(seedUid)) or 0) > 0
                    end
                end
                local budget = SeedBudget(seedUid)
                local headroom = tonumber(budget.headroom) or 0
                if headroom > 0 and plantUid > 0 and settleDeferred ~= true then
                    local Items = StockPiler.Items
                    local spec = Items and Items.ToSpec and Items.ToSpec(plantUid) or nil
                    local refinable = 0
                    if Refine and Refine.CountRefinablePlants then
                        refinable = tonumber(Refine.CountRefinablePlants(plantUid, spec)) or 0
                    end
                    local uses = math.min(refinable, headroom, 5)
                    if uses >= 1 then
                        appendFn({
                            spec = spec,
                            seedUid = seedUid,
                            plantUid = plantUid,
                            specKey = "upgrade_seed:" .. tostring(seedUid),
                        }, "upgrade-seed-buffer", uses, budget)
                        return
                    end
                end
            end
        end
    end
end

--- Opportunistic L1 vendor buy for one ladder. Mid-tier seeds are never bought.
--- Buy.FindStoreMatch still no-ops when the open merchant does not sell it.
local function AppendL1VendorBuyJob(jobs, seenBuy, ladder, needReq, fallbackSpec)
    if type(ladder) ~= "table" then
        return
    end
    local SM = StockPiler.SeedMap
    local buy = SM and SM.LowestBuySeedOnLadder and SM.LowestBuySeedOnLadder(ladder) or nil
    if type(buy) ~= "table" then
        return
    end
    local seedUid = tonumber(buy.seedUid) or 0
    if seedUid <= 0 then
        return
    end
    local buyReq = math.max(1, tonumber(buy.skillReq) or 1)
    -- Same arrival rule as the climb: bag seeds, in-ground seeds, and plants
    -- on a rung that has a known seed. Seed counts alone still queued the
    -- basic vendor seed after the watched plant was already in the bags.
    -- At the vendor rung itself, a short seed buffer may still buy.
    if HaveTargetRung(ladder, buyReq + 1, 0, 0) then
        return
    end
    if seenBuy[seedUid] == true then
        return
    end
    local deficit = US.SeedDeficit(seedUid)
    if deficit < 1 then
        return
    end
    seenBuy[seedUid] = true
    local MS = StockPiler.MaterialSpec
    local Inv = StockPiler.Inventory
    local sample = Inv and Inv.GetSample and Inv.GetSample(seedUid)
    local spec = nil
    if MS and MS.FromItemData and type(sample) == "table" then
        spec = MS.FromItemData(sample, tostring(ladder.role or "main"))
    elseif MS and MS.FromUid then
        spec = MS.FromUid(seedUid)
    end
    local SE = StockPiler.SeedEconomy
    if not (SE and SE.SeedBuyJob) then
        return
    end
    jobs[#jobs + 1] = SE.SeedBuyJob({
        seedUid = seedUid,
        deficit = deficit,
        upgradeSeed = true,
        role = tostring(ladder.role or "main"),
        spec = spec or fallbackSpec,
        specKey = "upgrade_seed:" .. tostring(seedUid),
        skillReq = buyReq,
        familyKey = ladder.key,
    })
end

function US.CollectBuyJobs()
    local jobs = {}
    if US.IsEnabled() ~= true then
        return jobs
    end
    local Watch = StockPiler.Watch
    if not (Watch and Watch.IsAutoBuyEnabled and Watch.IsAutoBuyEnabled() == true) then
        return jobs
    end
    local targets = GetUpgradeTargets()
    local seenBuy = {}
    for i = 1, #targets do
        local t = targets[i]
        AppendL1VendorBuyJob(jobs, seenBuy, t.ladder, t.needReq, t.spec)
    end
    -- Climb targets can be empty after a wiped L1 watch (idle / pending false).
    -- Still buy the vendor L1 seed while an enabled plant watch can raise a rung.
    local plantWatches = Watch.GetPlantWatches and Watch.GetPlantWatches() or {}
    if type(plantWatches) == "table" then
        for plantKey, watch in pairs(plantWatches) do
            if type(watch) == "table" and watch.enabled == true
                and (Watch.ShouldAutoGrowPlant == nil or Watch.ShouldAutoGrowPlant(plantKey) == true)
            then
                local watchPlantUid = Watch.ParsePlantKey and Watch.ParsePlantKey(plantKey) or 0
                watchPlantUid = tonumber(watchPlantUid) or 0
                if watchPlantUid > 0 then
                    local d = US.DescribePlantWatchClimb(watchPlantUid)
                    local needReq = tonumber(d.climbNeedReq) or tonumber(d.watchedReq) or 1
                    local climbCap = US.ClimbCap(needReq)
                    local cultFloor = US.FloorCultTier(US.GetCultSkill())
                    local ownedCap = math.max(climbCap, cultFloor)
                    local owned = US.PickBestOwnedSeed({
                        ladder = d.ladder,
                        climbCap = ownedCap,
                    })
                    local ownedReq = type(owned) == "table" and (tonumber(owned.skillReq) or 0) or 0
                    if d.pending == true or d.arriveNeeded == true
                        or (climbCap >= 1 and ownedReq < climbCap)
                    then
                        AppendL1VendorBuyJob(jobs, seenBuy, d.ladder, needReq, d.spec)
                    end
                end
            end
        end
    end
    return jobs
end

function US.MaybeNotifyStall()
    if US.IsEnabled() ~= true then
        US._stallLatch = nil
        return
    end
    local active = US._active
    if type(active) ~= "table" then
        US._stallLatch = nil
        return
    end
    local why = tostring(active.why or "")
    -- Progress: clear latch so a later real stall can warn once.
    if why == "planting" then
        US._stallLatch = nil
        return
    end
    -- Refining / waiting on plots: not a user-action stall. Keep any latch so
    -- need_buy <-> climbing <-> refining flicker cannot spam chat.
    if why == "refining" or why == "climbing" then
        return
    end
    local reason = why
    if reason == "" then
        reason = "need_buy"
    end
    if reason == "need_buy" then
        local Watch = StockPiler.Watch
        if not (Watch and Watch.IsAutoBuyEnabled and Watch.IsAutoBuyEnabled() == true) then
            reason = "autobuy_off"
        else
            local VA = StockPiler.VendorAdapter
            if VA and VA.IsStoreOpen and VA.IsStoreOpen() == true then
                -- Vendor open / AutoBuy can run - not a stall warn.
                return
            end
            reason = "need_vendor"
        end
    end
    -- One chat warn per stall episode (any reason). Reason flips must not re-fire.
    if US._stallLatch ~= nil then
        return
    end
    US._stallLatch = reason
    local genus = tostring(active.genus or "seed")
    local haveReq = tonumber(active.haveReq) or 0
    local needReq = tonumber(active.needReq) or 0
    local msg
    if StockPiler.T then
        msg = StockPiler.T("upgrade.stall." .. reason, {
            genus = genus,
            have = haveReq,
            need = needReq,
            cult = tonumber(active.needCult) or needReq,
        })
    else
        msg = L"<icon02486> Upgrade seed stalled."
    end
    if StockPiler.Debug and StockPiler.Debug.Print then
        StockPiler.Debug.Print(msg)
    end
    -- need_cult clears by planting. Buy / vendor / unknown-family do not.
    local needsUser = reason == "need_buy" or reason == "need_vendor"
        or reason == "autobuy_off" or reason == "no_vendor_seed"
        or reason == "no_family"
    if reason == "need_cult" then
        local Watch = StockPiler.Watch
        local growing = Watch and Watch.IsAutoGrowEnabled and Watch.IsAutoGrowEnabled() == true
        needsUser = growing ~= true
    end
    if needsUser then
        local SE = StockPiler.SeedEconomy
        if SE and SE.PlayUserActionSound then
            SE.PlayUserActionSound()
        end
    end
end

function US.GetActiveStatus()
    return US._active
end

--- Best owned seed/plant skillReq on a ladder at or below climbCap.
--- Counts bag and in-ground seeds (plot credit) so status matches seed-buffer plant.
--- opts.excludeGround: bags/plants only (plantable fill of leftover empty plots).
BestOwnedReqOnLadder = function(ladder, climbCap, opts)
    climbCap = tonumber(climbCap) or 0
    opts = type(opts) == "table" and opts or {}
    local excludeGround = opts.excludeGround == true
    if type(ladder) ~= "table" or type(ladder.rungs) ~= "table" or climbCap < 1 then
        return 0
    end
    local Inv = StockPiler.Inventory
    if not (Inv and Inv.CountByUid) then
        return 0
    end
    local Grow = StockPiler.Grow
    local best = 0
    for i = 1, #ladder.rungs do
        local rung = ladder.rungs[i]
        local req = tonumber(rung.skillReq) or 0
        if req >= 1 and req <= climbCap then
            local seedUid = tonumber(rung.seedUid) or 0
            local plantUid = tonumber(rung.plantUid) or 0
            local have = false
            if seedUid > 0 and (tonumber(Inv.CountByUid(seedUid)) or 0) >= 1 then
                have = true
            elseif plantUid > 0 and (tonumber(Inv.CountByUid(plantUid)) or 0) >= 1 then
                have = true
            elseif not excludeGround and seedUid > 0 and Grow then
                local ground = 0
                if Grow.CountSeedPlotCredit then
                    ground = tonumber(Grow.CountSeedPlotCredit(seedUid)) or 0
                elseif Grow.CountInGroundSeeds then
                    ground = tonumber(Grow.CountInGroundSeeds(seedUid)) or 0
                end
                if ground >= 1 then
                    have = true
                end
            end
            if have and req > best then
                best = req
            end
        end
    end
    return best
end

local function RebuildWatchStatusCache()
    local frame = tonumber(StockPiler.FrameCounter) or 0
    if US._statusCacheFrame == frame and type(US._statusByPlant) == "table" then
        return
    end
    US._statusCacheFrame = frame
    US._statusByPlant = {}
    US._statusByGenus = {}
    if US.IsEnabled() ~= true then
        return
    end
    local targets = GetUpgradeTargets()
    if #targets < 1 then
        -- Status is a read. PickPlantJob owns _active, including clearing it
        -- when the climb is finished.
        return
    end
    for i = 1, #targets do
        local t = targets[i]
        local needReq = tonumber(t.needReq) or 0
        local climbCap = US.ClimbCap(needReq)
        local haveReq = BestOwnedReqOnLadder(t.ladder, climbCap)
        local watchPlantUid = tonumber(t.watchPlantUid) or 0
        local bufferDone = true
        if watchPlantUid > 0 then
            bufferDone = CultMaxTierBufferFull(t.ladder, needReq, t.plantUid, t.seedUid) == true
        end
        -- Target rung owned and (non-plant-watch or Cult-max buffer full): idle.
        if haveReq >= needReq and needReq >= 1 and bufferDone then
            -- Seed-buffer / restock paths own the row status.
        else
            local why = "climbing"
            if haveReq < 1 then
                why = "need_buy"
            elseif climbCap < needReq and haveReq >= climbCap then
                why = "need_cult"
            elseif haveReq >= needReq and bufferDone ~= true then
                -- Own Cult-max seeds/plants but seed buffer still short.
                why = "climbing"
            end
            local genus = t.ladder and t.ladder.genus or nil
            local st = {
                familyKey = t.familyKey or (t.ladder and t.ladder.key),
                genus = genus,
                haveReq = haveReq,
                needReq = needReq,
                climbCap = climbCap,
                why = why,
                plantUid = tonumber(t.plantUid) or 0,
                seedUid = tonumber(t.seedUid) or 0,
            }
            local plantUid = tonumber(t.plantUid) or 0
            if plantUid > 0 then
                US._statusByPlant[plantUid] = st
            end
            -- Plant watches keep the low-tier uid in the UI; map status there too.
            if watchPlantUid > 0 and watchPlantUid ~= plantUid then
                US._statusByPlant[watchPlantUid] = st
            end
            if genus and genus ~= "" then
                US._statusByGenus[genus] = st
            end
        end
    end
end

--- Merge live PickPlantJob/_active action onto a status snapshot for tips.
local function WithLiveActive(st)
    if type(st) ~= "table" then
        return st
    end
    local active = US._active
    if type(active) ~= "table" then
        return st
    end
    local sameGenus = tostring(active.genus or "") ~= ""
        and tostring(active.genus) == tostring(st.genus or "")
    local sameFamily = tostring(active.familyKey or "") ~= ""
        and tostring(active.familyKey) == tostring(st.familyKey or "")
    if not sameGenus and not sameFamily then
        return st
    end
    local why = tostring(active.why or "")
    if why ~= "planting" and why ~= "refining" and why ~= "need_buy"
        and why ~= "need_cult" and why ~= "climbing" and why ~= "no_family"
    then
        return st
    end
    return {
        familyKey = st.familyKey or active.familyKey,
        genus = st.genus or active.genus,
        haveReq = tonumber(active.haveReq) or tonumber(st.haveReq) or 0,
        needReq = tonumber(st.needReq) or tonumber(active.needReq) or 0,
        climbCap = tonumber(st.climbCap) or tonumber(active.climbCap) or 0,
        why = why,
        plantUid = tonumber(active.plantUid) or tonumber(st.plantUid) or 0,
        seedUid = tonumber(active.seedUid) or 0,
        live = true,
    }
end

--- UI: climb status for a plant watch (or genus), or nil if not climbing.
function US.StatusForPlant(plantUid, spec)
    if US.IsEnabled() ~= true then
        return nil
    end
    RebuildWatchStatusCache()
    plantUid = tonumber(plantUid) or 0
    if plantUid > 0 and type(US._statusByPlant[plantUid]) == "table" then
        return WithLiveActive(US._statusByPlant[plantUid])
    end
    local SM = StockPiler.SeedMap
    local genus = nil
    if type(spec) == "table" and SM and SM.GenusKeyFromName then
        genus = SM.GenusKeyFromName(spec.name)
        if (not genus or genus == "") and SM.GetGenusLadderForSpec then
            local ladder = SM.GetGenusLadderForSpec(spec)
            genus = ladder and ladder.genus
        end
    end
    if genus and genus ~= "" and type(US._statusByGenus[genus]) == "table" then
        return WithLiveActive(US._statusByGenus[genus])
    end
    return nil
end

--- UI: climb status for potion seed-buffer rows.
--- Prefer the live active genus so the tip matches what AutoGrow is doing.
function US.StatusForWatch()
    if US.IsEnabled() ~= true then
        return nil
    end
    RebuildWatchStatusCache()
    local active = US._active
    if type(active) == "table" then
        local genus = tostring(active.genus or "")
        if genus ~= "" and type(US._statusByGenus) == "table"
            and type(US._statusByGenus[genus]) == "table"
        then
            return WithLiveActive(US._statusByGenus[genus])
        end
        local why = tostring(active.why or "")
        if why == "planting" or why == "refining" or why == "need_buy"
            or why == "need_cult" or why == "climbing"
        then
            return WithLiveActive({
                familyKey = active.familyKey,
                genus = active.genus,
                haveReq = tonumber(active.haveReq) or 0,
                needReq = tonumber(active.needReq) or 0,
                climbCap = tonumber(active.climbCap) or 0,
                why = why,
                plantUid = tonumber(active.plantUid) or 0,
                seedUid = tonumber(active.seedUid) or 0,
            })
        end
    end
    if type(US._statusByGenus) == "table" then
        for _, st in pairs(US._statusByGenus) do
            if type(st) == "table" then
                return WithLiveActive(st)
            end
        end
    end
    return nil
end

--- All live climb statuses (one per genus), for multi-family tips.
function US.ListClimbStatuses()
    if US.IsEnabled() ~= true then
        return {}
    end
    RebuildWatchStatusCache()
    local out = {}
    local seen = {}
    if type(US._statusByGenus) == "table" then
        for genus, st in pairs(US._statusByGenus) do
            if type(st) == "table" and seen[tostring(genus)] ~= true then
                seen[tostring(genus)] = true
                out[#out + 1] = WithLiveActive(st)
            end
        end
    end
    table.sort(out, function(a, b)
        local ga = tostring(a and a.genus or "")
        local gb = tostring(b and b.genus or "")
        if ga ~= gb then
            return ga < gb
        end
        return (tonumber(a and a.needReq) or 0) < (tonumber(b and b.needReq) or 0)
    end)
    return out
end

local function ClimbCapShow(climb)
    local needReq = tonumber(climb and climb.needReq) or 0
    local climbCap = tonumber(climb and climb.climbCap) or 0
    if climbCap < 1 and US.ClimbCap then
        climbCap = US.ClimbCap(needReq) or needReq
    end
    local capShow = climbCap
    if needReq > 0 and needReq < capShow then
        capShow = needReq
    end
    return capShow, needReq, tonumber(climb and climb.haveReq) or 0
end

--- Short parenthetical for tip Have/Need notes (per recipe slot).
function US.FormatClimbSlotNote(climb)
    if type(climb) ~= "table" then
        return nil
    end
    local why = tostring(climb.why or "")
    if why ~= "planting" and why ~= "refining" and why ~= "need_buy"
        and why ~= "need_cult" and why ~= "climbing" and why ~= "no_family"
    then
        return nil
    end
    local capShow, needReq, haveReq = ClimbCapShow(climb)
    local T = function(key, tokens)
        return StockPiler.Util.T(key, tokens)
    end
    if why == "planting" then
        return T("watch.note.climb_planting", {
            have = tostring(haveReq),
        })
    end
    if why == "refining" then
        return T("watch.note.climb_refining", {
            have = tostring(haveReq),
        })
    end
    if why == "need_buy" then
        return T("watch.note.climb_buy")
    end
    if why == "need_cult" or (needReq > 0 and capShow > 0 and capShow < needReq) then
        return T("watch.note.climb_cult", {
            need = tostring(needReq),
            floor = tostring(capShow),
        })
    end
    return T("watch.note.climb_progress", {
        have = tostring(haveReq),
        cap = tostring(capShow),
    })
end

local function TUpgrade(key, tokens)
    if StockPiler.Util and StockPiler.Util.T then
        return StockPiler.Util.T(key, tokens)
    end
    return towstring(tostring(key))
end

--- True when this target can still raise a seed rung at the current Cult floor.
--- Buffer-only fills (owned already at ClimbCap) and needs above ClimbCap do not
--- count: those must not hard-yield SkillUp.
local function TargetCanRaiseRung(t)
    if type(t) ~= "table" then
        return false
    end
    local needReq = tonumber(t.needReq) or 0
    local haveReq = tonumber(t.haveReq) or 0
    local climbCap = US.ClimbCap(needReq > 0 and needReq or haveReq)
    if climbCap < 1 then
        return false
    end
    if needReq > climbCap then
        return false
    end
    if type(t.ladder) == "table" then
        local owned = BestOwnedReqOnLadder(t.ladder, climbCap)
        return owned < climbCap
    end
    if haveReq >= climbCap then
        return false
    end
    return needReq > haveReq or haveReq < climbCap
end

--- True when Upgrade Seeds has climb work (potions, plant watches, or bag seeds).
--- SkillUp yields Cult plots while this is true.
--- Never sync-builds GetUpgradeTargets here: GrowReserve -> ShouldCultGrow ->
--- WatchesAllowIdleSkillUp calls this on every CountCraftsPossible slot.
function US.IsActivelyClimbingPlantWatches()
    if US.IsEnabled() ~= true then
        return false
    end
    local frame = tonumber(StockPiler.FrameCounter) or 0
    if US._activelyClimbingFrame == frame and US._activelyClimbingCached ~= nil then
        return US._activelyClimbingCached == true
    end
    local active = false
    -- Prefer last Collect / status rebuild (no CollectUpgradeTargets).
    -- A cached target that only fills the Cult-floor buffer, or whose next rung
    -- is above ClimbCap, is not climb work.
    if type(US._upgradeTargetsCache) == "table" and #US._upgradeTargetsCache >= 1 then
        for i = 1, #US._upgradeTargetsCache do
            if TargetCanRaiseRung(US._upgradeTargetsCache[i]) == true then
                active = true
                break
            end
        end
    elseif type(US._active) == "table" then
        local why = tostring(US._active.why or "")
        -- need_cult is waiting on skill, not a rung Upgrade Seeds can raise.
        if why == "planting" or why == "refining" or why == "need_buy"
            or why == "climbing" or why == "no_family"
        then
            if TargetCanRaiseRung(US._active) == true then
                active = true
            end
        end
    end
    if not active then
        local Watch = StockPiler.Watch
        local plantWatches = Watch and Watch.GetPlantWatches and Watch.GetPlantWatches() or {}
        if type(plantWatches) == "table" then
            for plantKey, watch in pairs(plantWatches) do
                if type(watch) == "table" and watch.enabled == true then
                    local uid = Watch.ParsePlantKey and Watch.ParsePlantKey(plantKey) or 0
                    uid = tonumber(uid) or 0
                    if uid > 0 then
                        local d = US.DescribePlantWatchClimb(uid)
                        if d.eligible == true and d.pending == true then
                            local climbCap = US.ClimbCap(d.climbNeedReq or d.watchedReq)
                            local ownedReq = BestOwnedReqOnLadder(d.ladder, climbCap)
                            if d.arriveNeeded == true
                                or (climbCap >= 1 and ownedReq < climbCap)
                            then
                                active = true
                                break
                            end
                        end
                    end
                end
            end
        end
    end
    US._activelyClimbingFrame = frame
    US._activelyClimbingCached = active
    return active
end

function US.ShouldShowWatchStatus()
    return US.IsEnabled() == true
end

--- Ephemeral Watch-tab rows for plant-watch Cult-max climbs. Never saved.
function US.BuildWatchStatusRows()
    local rows = {}
    if US.IsEnabled() ~= true then
        return rows
    end
    local Watch = StockPiler.Watch
    local Items = StockPiler.Items
    local Inv = StockPiler.Inventory
    local plantWatches = Watch and Watch.GetPlantWatches and Watch.GetPlantWatches() or {}
    if type(plantWatches) ~= "table" then
        return rows
    end
    local agOn = Watch and Watch.IsAutoGrowEnabled and Watch.IsAutoGrowEnabled() == true
    local allowIdle = US.WatchesAllowUpgradeClimb() == true
    local list = {}
    for plantKey, watch in pairs(plantWatches) do
        if type(watch) == "table" and watch.enabled == true then
            list[#list + 1] = { plantKey = tostring(plantKey), watch = watch }
        end
    end
    table.sort(list, function(a, b)
        return tostring(a.plantKey) < tostring(b.plantKey)
    end)
    local dash = TUpgrade("ui.dash")
    for i = 1, #list do
        local plantKey = list[i].plantKey
        local watchPlantUid = Watch.ParsePlantKey and Watch.ParsePlantKey(plantKey) or 0
        watchPlantUid = tonumber(watchPlantUid) or 0
        if watchPlantUid > 0 then
            local d = US.DescribePlantWatchClimb(watchPlantUid)
            if d.eligible == true and d.pending == true then
                local name = nil
                local iconNum = 0
                local itemData = nil
                if Items and Items.GetByUid then
                    local item = Items.GetByUid(watchPlantUid)
                    if type(item) == "table" then
                        name = item.name
                        iconNum = tonumber(item.iconNum) or 0
                        itemData = item.itemData or item
                    end
                end
                if Inv and Inv.GetSample then
                    local sample = Inv.GetSample(watchPlantUid)
                    if type(sample) == "table" then
                        itemData = sample
                        iconNum = tonumber(sample.iconNum) or iconNum
                        if sample.name ~= nil then
                            name = sample.name
                        end
                    end
                end
                if name == nil then
                    name = towstring("Upgrade " .. tostring(watchPlantUid))
                end
                local climbCap = US.ClimbCap(d.climbNeedReq)
                -- Arrive climbs must run immediately; Cult-max climbs wait on idle gate.
                local allow = d.arriveNeeded == true or allowIdle == true
                local statusKey = "waiting_watches"
                local statusText = TUpgrade("upgrade.watch.waiting_watches")
                local statusLines = {
                    TUpgrade("upgrade.watch.tip"),
                    TUpgrade("upgrade.watch.ag_tip"),
                }
                if allow ~= true then
                    local potionShort = Watch.AllEnabledPotionWatchesStocked
                        and Watch.AllEnabledPotionWatchesStocked() ~= true
                    local bufferShort = SeedBufferOkForIdle() ~= true
                    if potionShort and not bufferShort then
                        statusKey = "waiting_potions"
                        statusText = TUpgrade("upgrade.watch.waiting_potions")
                    elseif bufferShort and not potionShort then
                        statusKey = "waiting_seed_buffer"
                        statusText = TUpgrade("upgrade.watch.waiting_seed_buffer")
                    end
                    statusLines[#statusLines + 1] = TUpgrade("upgrade.watch.waiting_tip")
                elseif agOn ~= true then
                    statusKey = "enable_autogrow"
                    statusText = TUpgrade("plan.status.enable_autogrow")
                else
                    local climb = US.StatusForPlant(watchPlantUid, d.spec)
                    local why = type(climb) == "table" and tostring(climb.why or "") or "climbing"
                    local haveReq = type(climb) == "table" and (tonumber(climb.haveReq) or 0) or 0
                    if why == "need_buy" then
                        statusKey = "need_buy"
                        statusText = TUpgrade("upgrade.watch.need_buy")
                    elseif why == "need_cult" then
                        statusKey = "need_cult"
                        statusText = TUpgrade("upgrade.watch.need_cult", {
                            need = tostring(d.climbNeedReq),
                            floor = tostring(climbCap),
                        })
                    elseif why == "refining" then
                        statusKey = "refining"
                        statusText = TUpgrade("upgrade.watch.refining")
                    elseif why == "planting" then
                        statusKey = "planting"
                        statusText = TUpgrade("upgrade.watch.planting")
                    else
                        statusKey = "upgrading_seed"
                        statusText = TUpgrade("plan.status.upgrading_seed_progress", {
                            have = tostring(haveReq),
                            cap = tostring(climbCap),
                        })
                    end
                    statusLines[#statusLines + 1] = TUpgrade("upgrade.watch.tier_line", {
                        have = tostring(haveReq),
                        need = tostring(d.climbNeedReq),
                        floor = tostring(climbCap),
                    })
                end
                local id = "upgrade_seed:" .. tostring(watchPlantUid)
                rows[#rows + 1] = {
                    id = id,
                    potionKey = id,
                    potionRecipeKey = id,
                    kind = "upgrade",
                    upgradeWatch = true,
                    addonOwned = true,
                    skillUp = false,
                    isPlantWatch = false,
                    watchPlantUid = watchPlantUid,
                    plantUid = watchPlantUid,
                    seedUid = d.seedUid,
                    name = TUpgrade("upgrade.watch.name", { name = name }),
                    iconNum = iconNum,
                    itemData = itemData,
                    uniqueID = watchPlantUid,
                    potionHave = d.have,
                    stockText = dash,
                    target = d.climbNeedReq,
                    potionMin = d.climbNeedReq,
                    potionDeficit = 0,
                    targetText = dash,
                    priorityTier = 0,
                    priorityTierText = L"-",
                    plantPrioSentinel = true,
                    autoGrow = agOn == true,
                    hideAutoGrow = false,
                    hideBrew = true,
                    hideCraftable = true,
                    craftable = 0,
                    craftableText = L"",
                    statusKey = statusKey,
                    statusText = statusText,
                    statusLines = statusLines,
                    skillReq = d.climbNeedReq,
                    nameR = 255,
                    nameG = 255,
                    nameB = 255,
                }
            end
        end
    end
    return rows
end

function US.Dump(emit)
    emit = emit or print
    emit("--- upgrade seed ---")
    emit("  enabled=" .. tostring(US.IsEnabled() == true))
    local cult = US.GetCultSkill()
    emit("  cultSkill=" .. tostring(cult)
        .. " cultFloor=" .. tostring(US.FloorCultTier(cult)))
    local targets = GetUpgradeTargets()
    emit("  targets=" .. tostring(#targets))
    for i = 1, math.min(5, #targets) do
        local t = targets[i]
        local rungN = (type(t.ladder) == "table" and type(t.ladder.rungs) == "table")
            and #t.ladder.rungs or 0
        emit(string.format(
            "  target[%d] genus=%s needReq=%s short=%s plant=%s seed=%s rungs=%s key=%s",
            i,
            tostring(t.ladder and t.ladder.genus),
            tostring(t.needReq),
            tostring(t.short),
            tostring(t.plantUid),
            tostring(t.seedUid),
            tostring(rungN),
            tostring(t.familyKey)
        ))
    end
    local active = US._active
    if type(active) == "table" then
        emit(string.format(
            "  active family=%s genus=%s have=%s need=%s why=%s",
            tostring(active.familyKey),
            tostring(active.genus),
            tostring(active.haveReq),
            tostring(active.needReq),
            tostring(active.why)
        ))
    else
        emit("  active=(none)")
    end
    local jobs = US.CollectBuyJobs() or {}
    emit("  buyJobs=" .. tostring(#jobs))
    for i = 1, #jobs do
        local j = jobs[i]
        emit(string.format(
            "  buy[%d] uid=%s deficit=%s skillReq=%s family=%s",
            i,
            tostring(j.uid),
            tostring(j.deficit),
            tostring(j.skillReq),
            tostring(j.familyKey)
        ))
    end
    emit("  emptyPlots=" .. tostring(CountEmptyPlots()))
    -- Merged genus ladders for climb targets (from CollectUpgradeTargets cache;
    -- BuildAllFamilyLadders is gen-cached so this stays cheap).
    for i = 1, math.min(5, #targets) do
        local t = targets[i]
        local ladder = t.ladder
        if type(ladder) == "table" and type(ladder.rungs) == "table" then
            local parts = {}
            for r = 1, #ladder.rungs do
                local rung = ladder.rungs[r]
                parts[#parts + 1] = string.format(
                    "%d:s%d/p%d",
                    tonumber(rung.skillReq) or 0,
                    tonumber(rung.seedUid) or 0,
                    tonumber(rung.plantUid) or 0
                )
            end
            emit(string.format(
                "  merged[%s] role=%s %s",
                tostring(ladder.genus or ladder.key),
                tostring(ladder.role),
                table.concat(parts, " ")
            ))
        end
    end
    local SM = StockPiler.SeedMap
    if SM and SM.DumpFamilies then
        SM.DumpFamilies(emit)
    end
end
