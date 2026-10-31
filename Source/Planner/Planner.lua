----------------------------------------------------------------
-- StockPiler Planner - gen-keyed plan from store snapshots.
-- Have/demand caches live here. The client is Lua 5.1.
-- Build reads watches, bags, and the garden; it is not a pure function.
----------------------------------------------------------------

StockPiler = StockPiler or {}
StockPiler.Planner = StockPiler.Planner or {}
local WatchStillNeedsGrow
local Planner = StockPiler.Planner

Planner._planGen = 0

function Planner.GetPlanGen()
    return tonumber(Planner._planGen) or 0
end
Planner._closedLiveSnapGen = nil
Planner._liveGen = 0
Planner._craftsMemo = nil

-- Have cache (empty table != warm - need warmed-for-snap flag).
Planner._specHaveCache = nil
Planner._specHaveSnapGen = nil
Planner._specHaveWarmedSnap = nil

-- Demand / focus caches
Planner._demandCache = nil
Planner._demandCacheKey = nil
Planner._autoGrowFocusCache = nil
Planner._autoGrowFocusKey = nil
Planner._autoBuyFocusCache = nil
Planner._autoBuyFocusKey = nil

----------------------------------------------------------------
-- Tiny helpers
----------------------------------------------------------------

local function T(key, tokens)
    if StockPiler.T then
        return StockPiler.T(key, tokens)
    end
    return towstring(tostring(key or ""))
end

local function PerfBegin(name)
    local P = StockPiler.Perf
    if P and P.Begin then
        P.Begin(name)
    end
end

local function PerfEnd(name)
    local P = StockPiler.Perf
    if P and P.End then
        P.End(name)
    end
end

local function PerfMark(name)
    local P = StockPiler.Perf
    if P and P.Mark then
        P.Mark(name)
    end
end

local function ToNarrow(v)
    return StockPiler.Util.ToNarrow(v)
end

local function RecipeSpec()
    return StockPiler.RecipeSpec
end

local function MaterialSpec()
    return StockPiler.MaterialSpec
end

local function SpecKey(spec)
    local MS = MaterialSpec()
    if type(spec) ~= "table" then
        return nil
    end
    if MS and MS.Key then
        local bound = nil
        if spec.incomplete == true then
            bound = tonumber(spec.boundUid) or tonumber(spec.uid) or nil
        end
        local k = MS.Key(spec, bound)
        if type(k) == "string" and k ~= "" then
            return k
        end
    end
    if MS and MS.ProductKey then
        local k = MS.ProductKey(spec)
        if type(k) == "string" and k ~= "" then
            return k
        end
    end
    local uid = tonumber(spec.uid or spec.uniqueID) or 0
    if uid > 0 then
        return "uid:" .. tostring(uid)
    end
    return nil
end

--- Bound exemplar uid for incomplete mains (Have/buy still use ProductMatches).
local function SpecBoundUid(spec)
    if type(spec) ~= "table" then
        return 0
    end
    if spec.incomplete == true then
        return tonumber(spec.boundUid) or tonumber(spec.uid) or tonumber(spec.uniqueID) or 0
    end
    return 0
end

local function CurrentSnapGen()
    local Inv = StockPiler.Inventory
    if Inv and Inv.GetSnapGen then
        return tonumber(Inv.GetSnapGen()) or 0
    end
    return 0
end

local function CharacterRow()
    return StockPiler.Util.CharacterRow(false)
end

local function CanBrewPotionsSkill()
    local Caps = StockPiler.TradeSkillCaps
    return Caps and Caps.CanBrewPotions and Caps.CanBrewPotions() == true
end

local function CanAutoGrowSkill()
    local Caps = StockPiler.TradeSkillCaps
    return Caps and Caps.CanAutoGrow and Caps.CanAutoGrow() == true
end

local function RespectGrowReserve()
    if not CanAutoGrowSkill() then
        return false
    end
    local row = CharacterRow()
    if type(row) ~= "table" then
        return true
    end
    return row.brewRespectGrowReserve ~= false
end

local function EmitDefault(line)
    if StockPiler.Debug and StockPiler.Debug.Print then
        StockPiler.Debug.Print(towstring(tostring(line or "")))
    elseif type(d) == "function" then
        d(tostring(line or ""))
    end
end

local function MakeEmit(emit)
    if type(emit) == "function" then
        return emit
    end
    return EmitDefault
end

----------------------------------------------------------------
-- Gen / cache keys
----------------------------------------------------------------

local function SettingsHash()
    local hash = 1
    local Watch = StockPiler.Watch
    if Watch and Watch.IsAutoGrowEnabled and Watch.IsAutoGrowEnabled() == true then
        hash = hash + 1
    end
    if Watch and Watch.IsSeedBufferEnabled and Watch.IsSeedBufferEnabled() == true then
        hash = hash + 2
    end
    if Watch and Watch.GetSeedBufferMin then
        hash = hash + (tonumber(Watch.GetSeedBufferMin()) or 0) * 3
    end
    if Watch and Watch.IsAutoBuyEnabled and Watch.IsAutoBuyEnabled() == true then
        hash = hash + 5
    end
    -- Default on (optimistic). Only flip hash when explicitly off so caches rebuild.
    if Watch and Watch.IsOptimisticOutcomeEstimate
        and Watch.IsOptimisticOutcomeEstimate() ~= true
    then
        hash = hash + 23
    end
    if RespectGrowReserve() then
        hash = hash + 7
    end
    local Caps = StockPiler.TradeSkillCaps
    if Caps then
        -- A single skill point must not miss the cheap rebuild. Only the
        -- on/off craft gates change the plan shape.
        if Caps.CanAutoGrow and Caps.CanAutoGrow() == true then
            hash = hash + 11
        end
        if Caps.CanBrewPotions and Caps.CanBrewPotions() == true then
            hash = hash + 13
        end
    end
    local SkillUp = StockPiler.SkillUp
    if SkillUp then
        -- CharRow toggles (not IsCultEnabled): skill blips must not change the
        -- cache key in a way that rebuilds without SkillUp rows.
        if SkillUp.IsCultToggleOn and SkillUp.IsCultToggleOn() == true then
            hash = hash + 17
        end
        if SkillUp.IsApoToggleOn and SkillUp.IsApoToggleOn() == true then
            hash = hash + 19
        end
    end
    return hash
end

--- SettingsHash reaches the live trade-skill API five times (AutoGrow, seed
--- buffer, grow reserve, and the two capability checks). Read-only plan
--- lookups call CacheKeyFromGens on every pass, so that work is once per
--- frame/tick unless a skill pulse or a watch setting clears it.
local function ClearSettingsHashMemo()
    Planner._memoSettingsHash = nil
    Planner._memoSettingsHashClock = nil
    Planner._memoSettingsHashToken = nil
    -- FullCacheKey keeps its own copy of this hash. Drop it with the memo so
    -- the plan key and the demand/focus key cannot disagree after a clear.
    Planner._fullCacheFrame = nil
    Planner._fullCacheBase = nil
    Planner._fullCacheStatsGen = nil
    Planner._fullCacheSnap = nil
    Planner._fullCacheWatch = nil
end

local function SettingsMemoClock()
    local frame = tonumber(StockPiler.FrameCounter) or 0
    local tick = 0
    if type(GetGameTime) == "function" then
        -- Integer second. The raw clock is a float and can change inside one
        -- OnUpdate; FrameCounter is what stays still for that frame.
        tick = math.floor(tonumber(GetGameTime()) or 0)
    end
    -- No frame and no game clock: do not memo. Callers keep a live hash.
    if frame <= 0 and tick <= 0 then
        return nil
    end
    return tostring(frame) .. ":" .. tostring(tick)
end

--- Raw watch fields and sticky profession availability. No trade-skill API.
--- A direct row write or a sticky on/off change misses the memo on the next
--- lookup even when the game clock has not moved.
local function SettingsMemoToken()
    local row = CharacterRow()
    local autoGrow = "0"
    local seedOn = "1"
    local seedMin = "5"
    local autoBuy = "0"
    local optimistic = "1"
    local reserve = "1"
    local cultToggle = "0"
    local apoToggle = "0"
    if type(row) == "table" then
        if row.autoGrowEnabled == true then
            autoGrow = "1"
        end
        if row.growSeedBufferEnabled == false then
            seedOn = "0"
        end
        local n = tonumber(row.growSeedBufferMin)
        if n == nil or n < 0 then
            n = 5
        else
            n = math.floor(n)
        end
        seedMin = tostring(n)
        if row.autoBuyEnabled == true then
            autoBuy = "1"
        end
        if row.watchOptimisticOutcomeEstimate == false then
            optimistic = "0"
        end
        if row.brewRespectGrowReserve == false then
            reserve = "0"
        end
        if row.skillUpCultEnabled == true then
            cultToggle = "1"
        end
        if row.skillUpApoEnabled == true then
            apoToggle = "1"
        end
    end
    local cultOn = "0"
    local apoOn = "0"
    local Caps = StockPiler.TradeSkillCaps
    if Caps then
        if (tonumber(Caps._lastCult) or 0) > 0 then
            cultOn = "1"
        end
        if (tonumber(Caps._lastApo) or 0) > 0 then
            apoOn = "1"
        end
    end
    return autoGrow .. ":" .. seedOn .. ":" .. seedMin .. ":" .. autoBuy
        .. ":" .. optimistic .. ":" .. reserve
        .. ":" .. cultToggle .. ":" .. apoToggle
        .. ":" .. cultOn .. ":" .. apoOn
end

local function MemoSettingsHash()
    local clock = SettingsMemoClock()
    local token = SettingsMemoToken()
    if clock ~= nil
        and Planner._memoSettingsHash ~= nil
        and Planner._memoSettingsHashClock == clock
        and Planner._memoSettingsHashToken == token
    then
        return Planner._memoSettingsHash
    end
    local hash = SettingsHash()
    if clock ~= nil then
        -- Restamp after the hash so a cold GetCultSkill that fills sticky
        -- availability is part of the token, not a guaranteed miss next call.
        Planner._memoSettingsHash = hash
        Planner._memoSettingsHashClock = clock
        Planner._memoSettingsHashToken = SettingsMemoToken()
    end
    return hash
end

local function ReadGens()
    local Inv = StockPiler.Inventory
    local Garden = StockPiler.Garden
    local RP = StockPiler.RefinePipeline
    local Watch = StockPiler.Watch
    local Know = StockPiler.Knowledge
    return {
        snapGen = Inv and Inv.GetSnapGen and Inv.GetSnapGen() or 0,
        gardenGen = Garden and (Garden.GetPlanGen and Garden.GetPlanGen() or Garden.GetGen and Garden.GetGen()) or 0,
        refineGen = RP and RP.GetGen and RP.GetGen() or 0,
        watchGen = Watch and Watch.GetGen and Watch.GetGen() or 0,
        knowledgeGen = Know and Know.GetGen and Know.GetGen() or 0,
        recipeStatsGen = (StockPiler.RecipeSpec and StockPiler.RecipeSpec.GetRecipeStatsGen
            and StockPiler.RecipeSpec.GetRecipeStatsGen()) or 0,
        settingsHash = MemoSettingsHash(),
    }
end

local function FormatCacheKey(g)
    return string.format(
        "s%d|g%d|r%d|w%d|k%d|h%d|y%d",
        tonumber(g.snapGen) or 0,
        tonumber(g.gardenGen) or 0,
        tonumber(g.refineGen) or 0,
        tonumber(g.watchGen) or 0,
        tonumber(g.knowledgeGen) or 0,
        tonumber(g.settingsHash) or 0,
        tonumber(g.recipeStatsGen) or 0
    )
end

--- Demand, focus, and seed-line caches include every ReadGens field (PLN-5).
--- The base is read once per frame. SettingsHash hits Watch, SkillUp, and both
--- trade skills; the three cache probes were paying that on every hit (L19).
local function FullCacheKey(suffix)
    local frame = tonumber(StockPiler.FrameCounter) or 0
    local RS = StockPiler.RecipeSpec
    local statsGen = RS and RS.GetRecipeStatsGen and RS.GetRecipeStatsGen() or 0
    local Inv = StockPiler.Inventory
    local Watch = StockPiler.Watch
    local snap = Inv and Inv.GetSnapGen and tonumber(Inv.GetSnapGen()) or 0
    local watchGen = Watch and Watch.GetGen and tonumber(Watch.GetGen()) or 0
    local base = Planner._fullCacheBase
    if frame <= 0 or Planner._fullCacheFrame ~= frame
        or Planner._fullCacheStatsGen ~= statsGen
        or Planner._fullCacheSnap ~= snap
        or Planner._fullCacheWatch ~= watchGen
        or type(base) ~= "string"
    then
        base = FormatCacheKey(ReadGens())
        if frame > 0 then
            Planner._fullCacheFrame = frame
            Planner._fullCacheBase = base
            Planner._fullCacheStatsGen = statsGen
            Planner._fullCacheSnap = snap
            Planner._fullCacheWatch = watchGen
        end
    end
    if suffix == nil or suffix == "" then
        return base
    end
    return base .. "|" .. tostring(suffix)
end

--- Structural (non-snap, non-refine): gardenPlan + watch + knowledge + settings.
local function StructuralNonRefineKey(g)
    return string.format(
        "g%d|w%d|k%d|h%d",
        tonumber(g.gardenGen) or 0,
        tonumber(g.watchGen) or 0,
        tonumber(g.knowledgeGen) or 0,
        tonumber(g.settingsHash) or 0
    )
end

--- Recipe-structural: watch + knowledge + settings (garden may change for GardenPatch).
local function RecipeStructuralKey(g)
    return string.format(
        "w%d|k%d|h%d|y%d",
        tonumber(g.watchGen) or 0,
        tonumber(g.knowledgeGen) or 0,
        tonumber(g.settingsHash) or 0,
        tonumber(g.recipeStatsGen) or 0
    )
end

----------------------------------------------------------------
-- Spec-have cache (one-pass WarmSpecHaveCache)
----------------------------------------------------------------

--- Plant/refine quiet + harvest storm + Orch decision hold: keep prior have/demand
--- counts instead of WarmHave.miss bag scans on every Inv.ApplySlots snap bump.
local function HoldHaveCacheQuiet()
    local Sch = StockPiler.Scheduler
    if not Sch then
        return false
    end
    if Sch.IsSuppressed and Sch.IsSuppressed() == true then
        return true
    end
    -- Orch probe frame (before ArmPlantQuiet): remount when have or demand exists.
    if Sch.IsOrchDecisionHold and Sch.IsOrchDecisionHold() == true
        and (type(Planner._specHaveCache) == "table" or type(Planner._demandCache) == "table")
    then
        return true
    end
    return false
end

local function MarkHaveCacheWarmed(snapGen)
    Planner._specHaveWarmedSnap = tonumber(snapGen) or CurrentSnapGen()
end

local function EnsureHaveCacheForSnap()
    local snapGen = CurrentSnapGen()
    if Planner._specHaveSnapGen ~= snapGen or type(Planner._specHaveCache) ~= "table" then
        if HoldHaveCacheQuiet() and type(Planner._specHaveCache) == "table"
            and Planner._forceWarmHave ~= true
        then
            -- Keep prior counts for orch probes, but do NOT claim this snap is warm
            -- and do NOT advance _specHaveSnapGen. Remount-as-warm left CheapRebuild
            -- trusting stale mat totals after the first bag move (Watch craftable stuck).
            Planner._heldCountsUsed = true
            return Planner._specHaveCache, snapGen
        end
        Planner._specHaveCache = {}
        Planner._specHaveSnapGen = snapGen
        Planner._specHaveWarmedSnap = nil
    end
    return Planner._specHaveCache, snapGen
end

local function IsHaveCacheWarmForSnap()
    local snapGen = CurrentSnapGen()
    return Planner._specHaveWarmedSnap ~= nil
        and (tonumber(Planner._specHaveWarmedSnap) or -1) == snapGen
        and type(Planner._specHaveCache) == "table"
end

-- Bag credit budget. One Pump matches this many usable stacks, then yields.
-- BuildFull uses the same budget while it is running as a slice, and this
-- many watch rows per Pump. Direct Planner.Build still finishes in one call.
local WARM_HAVE_ITEMS_PER_PUMP = 8
local BUILD_ROWS_PER_PUMP = 4

local function WarmHaveBudget()
    local n = tonumber(Planner.WARM_HAVE_ITEMS_PER_PUMP) or WARM_HAVE_ITEMS_PER_PUMP
    if n < 1 then
        n = 1
    end
    return math.floor(n)
end

local function BuildRowBudget()
    local n = tonumber(Planner.BUILD_ROWS_PER_PUMP) or BUILD_ROWS_PER_PUMP
    if n < 1 then
        n = 1
    end
    return math.floor(n)
end

local function RunningCoroutine()
    if type(coroutine) ~= "table" or type(coroutine.running) ~= "function" then
        return nil
    end
    return coroutine.running()
end

local function ClearBuildScratch()
    Planner._buildRows = nil
    Planner._buildPlanGen = nil
    Planner._demandDeferStore = nil
    Planner._demandNeedScratch = nil
    Planner._buildYield = nil
    Planner._buildSliceSuspended = nil
    Planner._lazyWatchTips = nil
end

--- True when the in-flight sliced build must stop. Does not yield.
local function BuildSliceStale()
    if Planner._buildSliceAbort ~= nil then
        return true
    end
    local token = Planner._buildSliceToken
    if type(token) ~= "string" or token == "" then
        return false
    end
    return FormatCacheKey(ReadGens()) ~= token
end

--- Yield one Pump from a sliced BuildFull. Sync builds do not yield.
--- Returns true when the slice must unwind without publishing.
local function SliceYield()
    if Planner._buildYield ~= true or RunningCoroutine() == nil then
        return false
    end
    if BuildSliceStale() then
        Planner._buildSliceAbort = Planner._buildSliceAbort or "stale"
        return true
    end
    Planner._buildSliceSuspended = true
    coroutine.yield()
    Planner._buildSliceSuspended = false
    if BuildSliceStale() then
        Planner._buildSliceAbort = Planner._buildSliceAbort or "stale"
        return true
    end
    return false
end

--- True only on the thread that is inside this rebuild. A suspended slice
--- leaves rows and scratch set; main-thread demand must not read them.
local function InProgressBuild()
    if Planner._buildSliceSuspended == true then
        return false
    end
    return type(Planner._buildRows) == "table"
end

local function GameNow()
    if type(GetGameTime) == "function" then
        return tonumber(GetGameTime()) or 0
    end
    return 0
end

-- Assigned after BuildFull. Success clears the restart budget.
local ClearSliceBudget

local function StabilizerSlotTypes()
    local cit = GameData and GameData.CraftingItemType
    local stab = cit and tonumber(cit.STABILIZER) or 1
    local gold = cit and tonumber(cit.GOLDWEED) or 10
    return stab, gold
end

local function SlotIsStabilizerFamily(slot)
    slot = tonumber(slot)
    if slot == nil then
        return false
    end
    local stab, gold = StabilizerSlotTypes()
    return slot == stab or slot == gold
end

--- Stabilizer and goldweed slots cross-match each other. Other roles do not.
local function SpecIsStabilizerFamily(spec)
    if type(spec) ~= "table" then
        return false
    end
    local role = tostring(spec.role or "")
    if role == "stabilizer" or role == "goldweed" then
        return true
    end
    return SlotIsStabilizerFamily(spec.slotType)
end

--- ProductKey is "ts:N|st:N|lv:N|...". Nil, or slot <= 0, means "do not
--- narrow". Thin bag items (vials with no TYPE bonus) key as st:0 until
--- ProductMatches enriches them, and that match can hit any real slot.
--- Trade skill is not a safe cut: ProductMatches rewrites both sides to
--- Apothecary, so a cultivation spec still matches an apo product key.
local function ProductKeySlot(productKey)
    if type(productKey) ~= "string" or productKey == "" then
        return nil
    end
    local slot = tonumber(productKey:match("st:(%-?%d+)"))
    if slot == nil or slot <= 0 then
        return nil
    end
    return slot
end

local function BuildSpecFilter(pending)
    local bySlot = {}
    local stabilizers = {}
    local open = {}
    local incomplete = {}
    for i = 1, #pending do
        local entry = pending[i]
        local spec = type(entry) == "table" and entry.spec or nil
        if type(spec) ~= "table" then
            open[#open + 1] = entry
        elseif spec.incomplete == true then
            -- Bound-uid hits ignore slot. Always test these.
            incomplete[#incomplete + 1] = entry
        else
            local slot = tonumber(spec.slotType)
            if slot == nil or slot <= 0 then
                -- Missing or zero slot cannot prove a miss. Keep the old walk.
                open[#open + 1] = entry
            else
                local list = bySlot[slot]
                if list == nil then
                    list = {}
                    bySlot[slot] = list
                end
                list[#list + 1] = entry
                if SpecIsStabilizerFamily(spec) then
                    stabilizers[#stabilizers + 1] = entry
                end
            end
        end
    end
    return {
        bySlot = bySlot,
        stabilizers = stabilizers,
        open = open,
        incomplete = incomplete,
        openAll = #open == #pending,
        pending = pending,
    }
end

local function AppendUnique(out, seen, list)
    if type(list) ~= "table" then
        return
    end
    for i = 1, #list do
        local entry = list[i]
        if seen[entry] ~= true then
            seen[entry] = true
            out[#out + 1] = entry
        end
    end
end

local function CandidatesForItem(filter, productKey)
    if type(filter) ~= "table" or filter.openAll == true then
        return filter and filter.pending or {}
    end
    local slot = ProductKeySlot(productKey)
    if slot == nil or slot <= 0 then
        -- Thin or slot-less product. ProductMatches may enrich it onto any spec.
        return filter.pending
    end
    local out = {}
    local seen = {}
    AppendUnique(out, seen, filter.open)
    AppendUnique(out, seen, filter.incomplete)
    AppendUnique(out, seen, filter.bySlot[slot])
    if SlotIsStabilizerFamily(slot) then
        AppendUnique(out, seen, filter.stabilizers)
    end
    return out
end

local function BagItemUsable(item, Inv, MS)
    if type(item) ~= "table" then
        return false
    end
    if Inv and Inv.CanUseCraftingItem and Inv.CanUseCraftingItem(item) ~= true then
        return false
    end
    if MS and MS.IsSeedOrSpore and MS.IsSeedOrSpore(item) == true then
        return false
    end
    return true
end

local function CreditItemTotals(item, totals, keyIndex, filter)
    local MS = MaterialSpec()
    local qty = tonumber(item.stackCount) or tonumber(item.stackcount) or 1
    if qty < 1 then
        qty = 1
    end
    local productKey = nil
    if MS and MS.ProductKey then
        productKey = MS.ProductKey(item)
    end
    local fastKey = nil
    if type(productKey) == "string" and productKey ~= "" and keyIndex[productKey] then
        totals[productKey] = (totals[productKey] or 0) + qty
        fastKey = productKey
    end
    local pending = filter and filter.pending or {}
    local candidates = pending
    if filter ~= nil then
        candidates = CandidatesForItem(filter, productKey)
    end
    for i = 1, #candidates do
        local entry = candidates[i]
        if fastKey ~= nil and entry.key == fastKey then
            -- ProductKey already credited this spec. Still test the others.
        else
            local match = false
            if MS and MS.ProductMatches then
                match = MS.ProductMatches(item, entry.spec) == true
            elseif MS and MS.Matches then
                match = MS.Matches(item, entry.spec) == true
            else
                local uid = tonumber(item.uniqueID) or 0
                match = uid > 0 and uid == SpecBoundUid(entry.spec)
            end
            if match then
                totals[entry.key] = (totals[entry.key] or 0) + qty
            end
        end
    end
end

local function CollectUsableBagItems()
    local items = {}
    local Inv = StockPiler.Inventory
    local MS = MaterialSpec()
    if Inv and Inv.ForEachItem then
        Inv.ForEachItem(function(item)
            if BagItemUsable(item, Inv, MS) then
                items[#items + 1] = item
            end
        end)
    end
    return items
end

--- Sync bag walk. Yields every N usable items only inside a sliced BuildFull.
--- Returns true when the walk was abandoned and must not commit.
local function RunBagCredit(pending, totals, keyIndex, filter)
    local Inv = StockPiler.Inventory
    local MS = MaterialSpec()
    local seen = 0
    local budget = WarmHaveBudget()
    local aborted = false
    if Inv and Inv.ForEachItem then
        Inv.ForEachItem(function(item)
            if aborted or Planner._buildSliceAbort ~= nil then
                aborted = true
                return
            end
            if not BagItemUsable(item, Inv, MS) then
                return
            end
            CreditItemTotals(item, totals, keyIndex, filter)
            seen = seen + 1
            if budget > 0 and (seen % budget) == 0 then
                if SliceYield() then
                    aborted = true
                end
            end
        end)
    end
    if aborted or Planner._buildSliceAbort ~= nil then
        return true
    end
    return false
end

local function WarmHaveToken()
    local watchGen = 0
    local knowGen = 0
    local Watch = StockPiler.Watch
    local Know = StockPiler.Knowledge
    if Watch and Watch.GetGen then
        watchGen = tonumber(Watch.GetGen()) or 0
    end
    if Know and Know.GetGen then
        knowGen = tonumber(Know.GetGen()) or 0
    end
    return tostring(CurrentSnapGen()) .. ":" .. tostring(watchGen) .. ":" .. tostring(knowGen)
end

--- One bag pass via ProductMatches (incomplete stubs count fingerprint twins).
--- Do not pre-zero craftable / cache entries during brew-load WarmHave.
local function WarmSpecHaveCache(specs)
    if type(specs) ~= "table" then
        MarkHaveCacheWarmed(CurrentSnapGen())
        return 0
    end
    -- During quiet/orch hold: never bag-walk and never mark warm (stale remount).
    -- Post-brew forceRecount may set _forceWarmHave to walk bags anyway.
    if HoldHaveCacheQuiet() and type(Planner._specHaveCache) == "table"
        and Planner._forceWarmHave ~= true
    then
        Planner._heldCountsUsed = true
        EnsureHaveCacheForSnap()
        return 0
    end
    local cache, snapGen = EnsureHaveCacheForSnap()
    local list = {}
    if specs[1] ~= nil then
        for i = 1, #specs do
            local v = specs[i]
            if type(v) == "table" then
                list[#list + 1] = type(v.spec) == "table" and v.spec or v
            end
        end
    else
        for _, v in pairs(specs) do
            if type(v) == "table" then
                list[#list + 1] = type(v.spec) == "table" and v.spec or v
            end
        end
    end
    local pending = {}
    local pendingKeys = {}
    local filled = 0
    local keyIndex = {} -- complete SpecKey -> list of pending entries (usually 1)
    for i = 1, #list do
        local spec = list[i]
        local key = SpecKey(spec)
        if key ~= nil and cache[key] == nil and pendingKeys[key] ~= true then
            -- Incomplete+boundUid used to CountByUid-only; that skipped butcher twins.
            pendingKeys[key] = true
            local entry = { key = key, spec = spec }
            pending[#pending + 1] = entry
            keyIndex[key] = entry
        end
    end
    if #pending == 0 then
        MarkHaveCacheWarmed(snapGen)
        return filled
    end
    PerfMark("WarmHave.miss")
    local totals = {}
    for i = 1, #pending do
        totals[pending[i].key] = 0
    end
    local filter = BuildSpecFilter(pending)
    if RunBagCredit(pending, totals, keyIndex, filter) then
        -- Slice aborted mid-walk. Leave the cache cold so the next pass restarts.
        return 0
    end
    for i = 1, #pending do
        local entry = pending[i]
        -- Write after bag pass only (never pre-zero so live readers stay cold).
        cache[entry.key] = tonumber(totals[entry.key]) or 0
    end
    MarkHaveCacheWarmed(snapGen)
    return filled + #pending
end

local function CollectWatchedHaveSpecs()
    local Watch = StockPiler.Watch
    local RS = RecipeSpec()
    local watches = Watch and Watch.GetWatches and Watch.GetWatches() or {}
    local specs = {}
    if type(watches) ~= "table" then
        return specs
    end
    for watchKey, watch in pairs(watches) do
        if type(watch) == "table" and watch.enabled == true and RS and RS.RecipeSpecForPotion then
            local recipe = RS.RecipeSpecForPotion(watchKey)
            if type(recipe) == "table" then
                if RS.HydrateRecipeSlots then
                    RS.HydrateRecipeSlots(recipe)
                end
                local slots = recipe.slots
                if type(slots) == "table" then
                    for i = 1, #slots do
                        local spec = slots[i] and slots[i].spec
                        if type(spec) == "table" then
                            specs[#specs + 1] = spec
                        end
                    end
                end
            end
        end
    end
    return specs
end

local function WarmSpecHaveCacheForWatches()
    return WarmSpecHaveCache(CollectWatchedHaveSpecs())
end

--- Frame-slice WarmHave: one Pump builds the pending list. Later Pumps
--- credit WARM_HAVE_ITEMS_PER_PUMP bag stacks and keep the cursor on the slice.
local function BeginWarmHaveSlice()
    if HoldHaveCacheQuiet() then
        Planner._warmHaveSlice = nil
        if type(Planner._specHaveCache) == "table" then
            EnsureHaveCacheForSnap()
        end
        -- Still cold: post-hold / quiet-end must re-warm before craftable recount.
        return "done"
    end
    local token = WarmHaveToken()
    local existing = Planner._warmHaveSlice
    if type(existing) == "table" and existing.token == token and existing.committed ~= true then
        -- Same bags and watches: keep the cursor. A second Begin must not restart.
        return "continue"
    end
    Planner._warmHaveSlice = nil
    local specs = CollectWatchedHaveSpecs()
    if type(specs) ~= "table" or #specs == 0 then
        MarkHaveCacheWarmed(CurrentSnapGen())
        return "done"
    end
    local cache, snapGen = EnsureHaveCacheForSnap()
    local pending = {}
    local pendingKeys = {}
    local keyIndex = {}
    local filled = 0
    for i = 1, #specs do
        local spec = specs[i]
        local key = SpecKey(spec)
        if key ~= nil and cache[key] == nil and pendingKeys[key] ~= true then
            -- Bag-pass all specs (incl. incomplete) so fingerprint twins count.
            pendingKeys[key] = true
            local entry = { key = key, spec = spec }
            pending[#pending + 1] = entry
            keyIndex[key] = entry
        end
    end
    if #pending == 0 then
        MarkHaveCacheWarmed(snapGen)
        return "done"
    end
    Planner._warmHaveSlice = {
        snapGen = snapGen,
        token = token,
        pending = pending,
        keyIndex = keyIndex,
        filled = filled,
        items = nil,
        itemIndex = 1,
        totals = nil,
        filter = nil,
        committed = false,
    }
    return "continue"
end

--- Freeze stackCount so a later in-place bag edit cannot change a stack
--- this pump already accepted. Nested bonus tables stay shared.
local function SnapshotBagItem(item)
    local copy = {}
    if type(item) == "table" then
        for k, v in pairs(item) do
            if type(v) ~= "function" then
                copy[k] = v
            end
        end
    end
    local qty = tonumber(copy.stackCount) or tonumber(copy.stackcount) or 1
    if qty < 1 then
        qty = 1
    end
    copy.stackCount = qty
    copy.stackcount = qty
    return copy, qty
end

local function BagSlotCap()
    local n = WarmHaveBudget() * 4
    if n < 1 then
        n = 1
    end
    return n
end

--- Visit up to maxSlots slots from a cursor. fn returning false stops the walk.
--- ForEachItemChunk keeps the cost bounded. A cooperative ForEachItem that
--- stops on false does the same. The cursor is slot counts, not a live pairs().
local function VisitBagSlots(state, maxSlots, fn)
    if type(state) ~= "table" or state.done == true then
        return 0
    end
    maxSlots = tonumber(maxSlots) or 1
    if maxSlots < 1 then
        maxSlots = 1
    end
    local Inv = StockPiler.Inventory
    if not Inv or type(fn) ~= "function" then
        state.done = true
        return 0
    end
    if type(Inv.ForEachItemChunk) == "function" then
        return Inv.ForEachItemChunk(state, maxSlots, fn)
    end
    if type(Inv.ForEachItem) ~= "function" then
        state.done = true
        return 0
    end
    local skip = tonumber(state.seen) or 0
    local index = 0
    local visited = 0
    local stop = false
    Inv.ForEachItem(function(item, bag, slot)
        if stop or visited >= maxSlots then
            return false
        end
        index = index + 1
        if index <= skip then
            return nil
        end
        visited = visited + 1
        local keep = fn(item, bag, slot)
        if keep == false or visited >= maxSlots then
            stop = true
            return false
        end
        return nil
    end)
    state.seen = skip + visited
    if visited == 0 or (visited < maxSlots and stop ~= true) then
        state.done = true
    else
        state.done = false
    end
    return visited
end

local function FrozenCountsStillMatch(frozen)
    if type(frozen) ~= "table" then
        return true
    end
    for i = 1, #frozen do
        local row = frozen[i]
        local item = type(row) == "table" and row.item or nil
        if type(item) == "table" then
            local live = tonumber(item.stackCount) or tonumber(item.stackcount) or 1
            if live < 1 then
                live = 1
            end
            if live ~= row.count then
                return false
            end
        end
    end
    return true
end

--- One assignment. Readers see the previous table or the finished totals.
local function PublishHaveTotals(snapGen, pending, totals)
    local dest = {}
    if Planner._specHaveSnapGen == snapGen and type(Planner._specHaveCache) == "table" then
        for k, v in pairs(Planner._specHaveCache) do
            dest[k] = v
        end
    end
    for i = 1, #pending do
        local entry = pending[i]
        dest[entry.key] = tonumber(totals[entry.key]) or 0
    end
    Planner._specHaveCache = dest
    Planner._specHaveSnapGen = snapGen
    MarkHaveCacheWarmed(snapGen)
end

local function FinishWarmHaveSlice()
    local slice = Planner._warmHaveSlice
    if type(slice) ~= "table" or type(slice.pending) ~= "table" then
        -- Missing slice means cancel or invalidate. Do not stamp a cold cache warm.
        return "done"
    end
    -- Never bag-walk on the same frame as BagFlush / PlanRebuild (libperf Pump storms).
    local Sch = StockPiler.Scheduler
    if Sch and Sch.ShouldDeferWarmHaveBag and Sch.ShouldDeferWarmHaveBag() == true then
        return "defer"
    end
    local snapGen = CurrentSnapGen()
    local token = WarmHaveToken()
    if snapGen ~= (tonumber(slice.snapGen) or -1) or slice.token ~= token then
        -- Bag, watches, or knowledge moved. Drop partial totals and restart later.
        Planner._warmHaveSlice = nil
        if snapGen == (tonumber(slice.snapGen) or -1) then
            Planner._specHaveWarmedSnap = nil
        end
        return "done"
    end
    -- A stack we already accepted changed in place. Publishing would mix
    -- the old count with stacks read after the edit. Drop the partial.
    if FrozenCountsStillMatch(slice.frozen) ~= true then
        Planner._warmHaveSlice = nil
        Planner._specHaveWarmedSnap = nil
        return "done"
    end
    if slice.totals == nil then
        slice.totals = {}
        slice.frozen = {}
        slice.scan = { done = false }
        for i = 1, #slice.pending do
            slice.totals[slice.pending[i].key] = 0
        end
        slice.filter = BuildSpecFilter(slice.pending)
        PerfMark("WarmHave.miss")
        if CurrentSnapGen() ~= (tonumber(slice.snapGen) or -1) or WarmHaveToken() ~= token then
            Planner._warmHaveSlice = nil
            return "done"
        end
    end
    if slice.scan == nil or slice.scan.done ~= true then
        slice.scan = slice.scan or { done = false }
        local budget = WarmHaveBudget()
        local credited = 0
        local Inv = StockPiler.Inventory
        local MS = MaterialSpec()
        local keyIndex = slice.keyIndex or {}
        local totals = slice.totals
        VisitBagSlots(slice.scan, BagSlotCap(), function(item)
            if not BagItemUsable(item, Inv, MS) then
                return true
            end
            local copy, qty = SnapshotBagItem(item)
            slice.frozen[#slice.frozen + 1] = { item = item, count = qty }
            CreditItemTotals(copy, totals, keyIndex, slice.filter)
            credited = credited + 1
            if credited >= budget then
                return false
            end
            return true
        end)
        if slice.scan.invalid == true
            or CurrentSnapGen() ~= (tonumber(slice.snapGen) or -1)
            or WarmHaveToken() ~= token
            or FrozenCountsStillMatch(slice.frozen) ~= true
        then
            Planner._warmHaveSlice = nil
            Planner._specHaveWarmedSnap = nil
            return "done"
        end
        if slice.scan.done ~= true then
            return "continue"
        end
    end
    if CurrentSnapGen() ~= (tonumber(slice.snapGen) or -1) or WarmHaveToken() ~= token then
        Planner._warmHaveSlice = nil
        return "done"
    end
    if FrozenCountsStillMatch(slice.frozen) ~= true then
        Planner._warmHaveSlice = nil
        Planner._specHaveWarmedSnap = nil
        return "done"
    end
    PublishHaveTotals(snapGen, slice.pending, slice.totals)
    slice.committed = true
    Planner._warmHaveSlice = nil
    return "done"
end

local function CountItemsMatchingSpec(spec, opts)
    opts = type(opts) == "table" and opts or {}
    local key = SpecKey(spec)
    if key == nil then
        return opts.cacheOnly == true and nil or 0
    end
    local cache = Planner._specHaveCache
    if type(cache) == "table" and cache[key] ~= nil and IsHaveCacheWarmForSnap() then
        return tonumber(cache[key]) or 0
    end
    if opts.cacheOnly == true then
        if type(cache) == "table" and cache[key] ~= nil then
            return tonumber(cache[key]) or 0
        end
        return nil
    end
    local RS = RecipeSpec()
    if RS and RS.CountItemsMatchingSpec then
        return tonumber(RS.CountItemsMatchingSpec(spec)) or 0
    end
    local MS = MaterialSpec()
    local Inv = StockPiler.Inventory
    local total = 0
    if Inv and Inv.ForEachItem and MS and MS.ProductMatches then
        Inv.ForEachItem(function(item)
            if type(item) ~= "table" then
                return
            end
            if MS.IsSeedOrSpore and MS.IsSeedOrSpore(item) == true then
                return
            end
            if MS.ProductMatches(item, spec) == true then
                local qty = tonumber(item.stackCount) or 1
                if qty < 1 then
                    qty = 1
                end
                total = total + qty
            end
        end)
    end
    return total
end

local function BeginPlanCraftsMemo()
    Planner._craftsMemo = {}
    Planner._craftsMemoSnap = CurrentSnapGen()
end

local function CountCraftsPossibleMemo(recipe)
    local RS = RecipeSpec()
    if type(recipe) ~= "table" or not RS or not RS.CountCraftsPossible then
        return 0
    end
    local snap = CurrentSnapGen()
    if Planner._craftsMemoSnap ~= snap or type(Planner._craftsMemo) ~= "table" then
        Planner._craftsMemo = {}
        Planner._craftsMemoSnap = snap
    end
    local memo = Planner._craftsMemo
    local key = tostring(recipe.recipeKey or recipe.key or recipe.id or "")
    if key ~= "" and type(memo) == "table" and memo[key] ~= nil then
        return memo[key]
    end
    local opts = nil
    if RespectGrowReserve() then
        opts = { respectGrowReserve = true }
    end
    PerfMark("Status.Craftable")
    local n = math.max(0, math.floor((tonumber(RS.CountCraftsPossible(recipe, opts)) or 0) + 0.5))
    if key ~= "" and type(memo) == "table" then
        memo[key] = n
    end
    return n
end

local function OptimisticOutcomeEstimate()
    local Watch = StockPiler.Watch
    if Watch and Watch.IsOptimisticOutcomeEstimate then
        return Watch.IsOptimisticOutcomeEstimate() ~= false
    end
    return true
end

local function RecipeYield(recipe, potionUid)
    local RS = RecipeSpec()
    if RS and RS.StableCraftYield then
        local y = tonumber(RS.StableCraftYield(recipe, potionUid)) or 0
        if y >= 1 then
            return y
        end
    end
    return math.max(1, tonumber(recipe and recipe.recipeYield) or 1)
end

local function CraftsNeededForDeficit(deficit, recipe, potionUid)
    deficit = tonumber(deficit) or 0
    if deficit <= 0 then
        return 0
    end
    local RS = RecipeSpec()
    if not OptimisticOutcomeEstimate() and RS and RS.ExpectedCraftsForDeficit then
        local n = RS.ExpectedCraftsForDeficit(deficit, recipe, potionUid)
        return tonumber(n) or 0
    end
    if RS and RS.CraftsNeededForDeficit then
        return tonumber(RS.CraftsNeededForDeficit(deficit, recipe, potionUid)) or 0
    end
    local yield = RecipeYield(recipe, potionUid)
    return math.ceil(deficit / yield)
end

local function CountPotionsCraftable(recipe, potionUid)
    local RS = RecipeSpec()
    if not OptimisticOutcomeEstimate() and RS and RS.ExpectedCraftableBottles then
        local expected, rate, best = RS.ExpectedCraftableBottles(recipe, potionUid)
        if expected ~= nil then
            return math.max(0, math.floor((tonumber(expected) or 0) + 0.5))
        end
        if best ~= nil then
            return math.max(0, math.floor((tonumber(best) or 0) + 0.5))
        end
    end
    local crafts = CountCraftsPossibleMemo(recipe)
    return math.max(0, math.floor((crafts * RecipeYield(recipe, potionUid)) + 0.5))
end

----------------------------------------------------------------
-- Growable / slot classification (stub-safe)
----------------------------------------------------------------

--- Twin lookup for Watch / plan paint. Never starts a live bag scan.
local function FindGrowableTwinCached(spec)
    local SM = StockPiler.SeedMap
    if not (SM and SM.FindGrowableTwinUid) then
        return 0
    end
    return tonumber(SM.FindGrowableTwinUid(spec, { cacheOnly = true })) or 0
end

--- True when the slot can progress via AutoGrow: exemplar is cultivable, or a
--- known cult twin exists (e.g. Majestic Goldweed for Brutal Zoic Gore). Used by
--- ContestedBuyOnlyKind / RecipeSlotPlanEntry so Buy materials never blocks a
--- watch that can plant instead. Brew still prefers non-growable bag picks.
local function SpecIsGrowable(spec, role)
    if role == "container" then
        return false
    end
    local SM = StockPiler.SeedMap
    if SM and SM.IsHarvestByproduct and SM.IsHarvestByproduct(spec) == true then
        return false
    end
    if SM and SM.IsGrowableSpec and SM.IsGrowableSpec(spec) == true then
        return true
    end
    local MS = MaterialSpec()
    if MS and MS.IsGrowable and MS.IsGrowable(spec) == true then
        return true
    end
    -- Fingerprint may bind a butcher/vendor exemplar; a ProductMatches cult twin
    -- still means we can grow rather than Buy-block the watch.
    if FindGrowableTwinCached(spec) > 0 then
        return true
    end
    return false
end

local function SpecIsHarvestByproduct(spec)
    local SM = StockPiler.SeedMap
    if SM and SM.IsHarvestByproduct then
        return SM.IsHarvestByproduct(spec) == true
    end
    return false
end

--- AutoGrow can still move this slot: a cult plant, or a butcher/vendor
--- exemplar that has a cultivable twin. Containers and harvest byproducts cannot.
local function SpecCanAutoGrowProgress(spec, role)
    if tostring(role or "") == "container" then
        return false
    end
    if SpecIsHarvestByproduct(spec) == true then
        return false
    end
    if SpecIsGrowable(spec, role) == true then
        return true
    end
    return FindGrowableTwinCached(spec) > 0
end

--- Prefer main -> goldweed/stab -> extender -> multiplier when growing convert feedstock for resin.
local function ByproductConvertRoleRank(role)
    role = tostring(role or "")
    if role == "main" then
        return 1
    end
    if role == "stabilizer" or role == "goldweed" then
        return 2
    end
    if role == "extender" then
        return 3
    end
    if role == "multiplier" or role == "stimulant" then
        return 4
    end
    return 99
end

local function InflateConvertGrowRow(row, byproductItemsShort)
    if type(row) ~= "table" or (tonumber(byproductItemsShort) or 0) <= 0 then
        return
    end
    if row.brewAbsolute == nil then
        row.brewAbsolute = tonumber(row.absolute) or 0
    end
    row.byproductConvertExtra = (tonumber(row.byproductConvertExtra) or 0)
        + byproductItemsShort
    row.absolute = (tonumber(row.absolute) or 0) + byproductItemsShort
    row.deficit = math.max(0, (tonumber(row.absolute) or 0) - (tonumber(row.have) or 0))
    local pc = math.max(1, tonumber(row.perCraft) or 1)
    row.craftsHave = math.floor((tonumber(row.have) or 0) / pc)
    row.craftsNeeded = math.ceil((tonumber(row.absolute) or 0) / pc)
    row.craftsShort = math.max(0, row.craftsNeeded - row.craftsHave)
end

local function EffectivePerCraft(slot, slots)
    local RS = RecipeSpec()
    if RS and RS.EffectiveSpecPerCraft then
        return math.max(1, tonumber(RS.EffectiveSpecPerCraft(slot, slots)) or 1)
    end
    return math.max(1, tonumber(slot and slot.perCraft) or 1)
end

local function ResolveSlotSpec(slot)
    if type(slot) ~= "table" then
        return nil
    end
    if type(slot.spec) == "table" then
        return slot.spec
    end
    local RS = RecipeSpec()
    if RS and RS.ResolveSlotSpec then
        return RS.ResolveSlotSpec(slot)
    end
    return nil
end

--- One RecipeSlotPlanEntry: status + tipSlots share.
local function RecipeSlotPlanEntry(slot, slots, craftsNeeded, demand)
    local spec = ResolveSlotSpec(slot)
    if type(spec) ~= "table" then
        return nil
    end
    local role = slot.role or spec.role
    local perCraft = EffectivePerCraft(slot, slots)
    local need = (tonumber(craftsNeeded) or 0) * perCraft
    local have = CountItemsMatchingSpec(spec)
    local deficit = math.max(0, need - have)
    local entry = {
        spec = spec,
        role = role,
        perCraft = perCraft,
        need = need,
        have = have,
        deficit = deficit,
        craftsHave = math.floor(have / perCraft),
        craftsNeeded = math.ceil(need / math.max(1, perCraft)),
        kind = "buy",
        needsRefine = false,
        buySeedOrMat = false,
        seedUid = 0,
        plantUid = 0,
        seedHave = 0,
        seedCredit = 0,
        note = nil,
        noteKind = nil,
    }
    local demandRow = nil
    local key = SpecKey(spec)
    if type(demand) == "table" and key ~= nil then
        demandRow = demand[key]
    end
    local function FillPlantEntry(plantUidHint)
        entry.kind = "plant"
        local SM = StockPiler.SeedMap
        local growTwin = FindGrowableTwinCached(spec)
        -- Prefer cult twin plant uid over butcher bound exemplar for seed/refine.
        local plantProbe = spec
        if growTwin > 0 and (tonumber(spec.uid) or tonumber(spec.uniqueID) or tonumber(spec.boundUid) or 0) ~= growTwin then
            plantProbe = {
                uid = growTwin,
                uniqueID = growTwin,
                boundUid = growTwin,
                role = spec.role,
                name = spec.name,
                level = spec.level,
                rarity = spec.rarity,
                incomplete = spec.incomplete,
            }
            local MS = MaterialSpec()
            if MS and MS.FromItemData and StockPiler.Items and StockPiler.Items.AsItemData then
                local sample = StockPiler.Items.AsItemData(growTwin)
                if type(sample) == "table" then
                    local twinSpec = MS.FromItemData(sample, role)
                    if type(twinSpec) == "table" then
                        plantProbe = twinSpec
                    end
                end
            end
        end
        local seed = nil
        if SM and SM.ResolveSeedForSpec then
            seed = SM.ResolveSeedForSpec(plantProbe)
            if type(seed) ~= "table" and plantProbe ~= spec then
                seed = SM.ResolveSeedForSpec(spec)
            end
        end
        if type(seed) == "table" then
            entry.seed = seed
            entry.seedUid = tonumber(seed.uniqueID or seed.uid) or 0
            entry.plantUid = tonumber(seed.plantUid) or 0
        else
            entry.plantUid = 0
        end
        -- Hint is the cult twin from the non-growable branch. growTwin covers
        -- the same case when the slot was already classified plant. Butcher
        -- bound uid is only a last resort.
        plantUidHint = tonumber(plantUidHint) or 0
        if (tonumber(entry.plantUid) or 0) <= 0 then
            if plantUidHint > 0 then
                entry.plantUid = plantUidHint
            elseif growTwin > 0 then
                entry.plantUid = growTwin
            else
                entry.plantUid = SpecBoundUid(spec)
                if entry.plantUid <= 0 and SM and SM.FindPlantUidForSpec then
                    entry.plantUid = tonumber(SM.FindPlantUidForSpec(plantProbe)) or 0
                end
            end
        end
        local Inv = StockPiler.Inventory
        if entry.seedUid > 0 and Inv and Inv.CountByUid then
            entry.seedHave = tonumber(Inv.CountByUid(entry.seedUid)) or 0
        end
        -- Prefer refine / seed-buffer over Buy seeds when refinable plants remain.
        if entry.seedHave <= 0 and entry.plantUid > 0 and Inv and Inv.CountByUid then
            local plants = tonumber(Inv.CountByUid(entry.plantUid)) or 0
            if plants > 0 then
                entry.needsRefine = true
            elseif entry.seedUid > 0 then
                entry.buySeedOrMat = true
            end
        elseif entry.seedHave <= 0 and entry.seedUid > 0 then
            entry.buySeedOrMat = true
        end
        local Refine = StockPiler.Refine
        if Refine and Refine.GetSeedBudgetForSpec then
            local budget = Refine.GetSeedBudgetForSpec(spec, entry.seedUid)
            entry.seedCredit = tonumber(budget and budget.credit) or 0
        end
    end
    if SpecIsHarvestByproduct(spec) then
        entry.kind = "convert"
    elseif SpecIsGrowable(spec, role) then
        FillPlantEntry(0)
    elseif role == "container" then
        entry.kind = "buy"
    else
        -- Butcher/vendor exemplar with a cultivable twin: plant that twin.
        local twinUid = FindGrowableTwinCached(spec)
        if twinUid > 0 then
            FillPlantEntry(twinUid)
        else
            entry.kind = "buy"
        end
    end
    -- Tip notes: (Shared) contested vs (Pooled) multi-watch demand.
    if type(demandRow) == "table" and type(demandRow.watchNames) == "table" and #demandRow.watchNames > 1 then
        entry.note = "(Pooled)"
        entry.noteKind = "pooled"
    end
    return entry
end

----------------------------------------------------------------
-- Balanced demand + water-fill focus
----------------------------------------------------------------

local function BottleGap(target, stock, craftable)
    return math.max(0, (tonumber(target) or 0) - (tonumber(stock) or 0) - (tonumber(craftable) or 0))
end

--- Stable store lookup key for a plan/list row (matches Watch tab toggles).
local function RowWatchKey(row)
    if type(row) ~= "table" then
        return nil
    end
    return row.potionRecipeKey or row.id or row.potionKey
end

local function ResolveWatchRow(watchKey, watch)
    if type(watch) == "table" then
        return watch
    end
    local Watch = StockPiler.Watch
    if Watch and Watch.ResolveWatchEntry then
        return select(1, Watch.ResolveWatchEntry(watchKey))
    end
    local watches = Watch and Watch.GetWatches and Watch.GetWatches() or nil
    if type(watches) ~= "table" then
        return nil
    end
    local key = tostring(watchKey or "")
    if key == "" then
        return nil
    end
    return watches[key]
end

local function WatchWantsAutoGrow(watchKey, watch)
    local RS = RecipeSpec()
    watch = ResolveWatchRow(watchKey, watch)
    if RS and RS.ShouldAutoGrowPotion then
        return RS.ShouldAutoGrowPotion(watchKey, watch) == true
    end
    if type(watch) ~= "table" or watch.enabled ~= true then
        return false
    end
    local Watch = StockPiler.Watch
    if Watch and Watch.IsAutoGrowEnabled and Watch.IsAutoGrowEnabled() ~= true then
        return false
    end
    return watch.autoGrow == true
end

--- Grow needs master+row AutoGrow; buy acting set needs enabled+row AutoGrow
--- (master AutoGrow may be off - AutoBuy still runs at vendors).
local function WatchInActingSet(watchKey, watch, mode)
    if mode == "buy" then
        watch = ResolveWatchRow(watchKey, watch)
        return type(watch) == "table" and watch.enabled == true and watch.autoGrow == true
    end
    return WatchWantsAutoGrow(watchKey, watch)
end

local function ResolveWatchPotion(watchKey)
    local RS = RecipeSpec()
    if RS and RS.ResolveWatchPotion then
        return RS.ResolveWatchPotion(watchKey)
    end
    return nil
end

local function PotionHave(resolved, potion, outputUid)
    local uid = tonumber(outputUid)
        or (resolved and tonumber(resolved.outputUid))
        or (type(potion) == "table" and tonumber(potion.outputUid))
        or 0
    local Inv = StockPiler.Inventory
    if uid > 0 and Inv and Inv.CountByUid then
        return tonumber(Inv.CountByUid(uid)) or 0
    end
    return 0
end

local function WatchPriorityTier(watchKey, watch)
    watch = ResolveWatchRow(watchKey, watch)
    local Watch = StockPiler.Watch
    if Watch and Watch.GetPriorityTier then
        local tier = tonumber(Watch.GetPriorityTier(watchKey))
        if tier ~= nil and tier > 0 then
            return tier
        end
    end
    if type(watch) == "table" and watch.priorityTier ~= nil then
        return tonumber(watch.priorityTier) or 1
    end
    return 1
end

--- One output uid, one recipe: best priority (lowest tier), ties by watch key.
--- maxTarget is the highest target in the group. winner.raw is the source row.
local function GroupWatchesByOutputUid(entries)
    local byUid = {}
    local order = {}
    local loose = {}
    entries = type(entries) == "table" and entries or {}
    for i = 1, #entries do
        local entry = entries[i]
        if type(entry) == "table" then
            local uid = tonumber(entry.uid) or 0
            if uid <= 0 then
                loose[#loose + 1] = entry
            else
                local group = byUid[uid]
                local tier = tonumber(entry.tier) or 1
                local key = tostring(entry.key or "")
                local target = tonumber(entry.target) or 0
                if group == nil then
                    group = {
                        uid = uid,
                        key = entry.key,
                        tier = tier,
                        maxTarget = target,
                        have = tonumber(entry.have) or 0,
                        recipe = entry.recipe,
                        potion = entry.potion,
                        stillNeeds = entry.stillNeeds == true,
                        bottleGap = entry.bottleGap,
                        winner = entry,
                    }
                    byUid[uid] = group
                    order[#order + 1] = uid
                else
                    if target > group.maxTarget then
                        group.maxTarget = target
                    end
                    local gkey = tostring(group.key or "")
                    if tier < group.tier or (tier == group.tier and key < gkey) then
                        group.tier = tier
                        group.key = entry.key
                        group.recipe = entry.recipe
                        group.potion = entry.potion
                        group.stillNeeds = entry.stillNeeds == true
                        group.have = tonumber(entry.have) or group.have
                        group.bottleGap = entry.bottleGap
                        group.winner = entry
                    end
                end
            end
        end
    end
    local groups = {}
    for i = 1, #order do
        groups[#groups + 1] = byUid[order[i]]
    end
    for i = 1, #loose do
        local entry = loose[i]
        groups[#groups + 1] = {
            uid = 0,
            key = entry.key,
            tier = tonumber(entry.tier) or 1,
            maxTarget = tonumber(entry.target) or 0,
            have = tonumber(entry.have) or 0,
            recipe = entry.recipe,
            potion = entry.potion,
            stillNeeds = entry.stillNeeds == true,
            bottleGap = entry.bottleGap,
            winner = entry,
        }
    end
    return groups
end

local function CollapseFocusCandidates(list)
    local entries = {}
    list = type(list) == "table" and list or {}
    for i = 1, #list do
        local row = list[i]
        if type(row) == "table" then
            entries[#entries + 1] = {
                key = row.potionKey,
                tier = row.priorityTier,
                target = row.target,
                have = row.stock,
                recipe = row.recipe,
                uid = row.uniqueID,
                bottleGap = row.bottleGap,
                stillNeeds = true,
                raw = row,
            }
        end
    end
    local groups = GroupWatchesByOutputUid(entries)
    local out = {}
    for i = 1, #groups do
        local group = groups[i]
        local row = group.winner and group.winner.raw or nil
        if type(row) == "table" then
            row.target = group.maxTarget
            row.stock = group.have
            row.recipe = group.recipe
            row.priorityTier = group.tier
            row.potionKey = tostring(group.key or row.potionKey or "")
            row.bottleGap = BottleGap(group.maxTarget, group.have, row.craftable)
            out[#out + 1] = row
        end
    end
    return out
end

local function BuildBalancedSpecDemand(opts)
    opts = type(opts) == "table" and opts or {}
    local Watch = StockPiler.Watch
    -- Suspended rebuild state stays private. WarmDemand runs between pumps.
    local building = InProgressBuild()
    local planGen
    if building then
        -- This build's gen, not the plan still published from the previous build.
        planGen = tonumber(Planner._buildPlanGen) or tonumber(Planner._planGen) or 0
    else
        local PS = StockPiler.PlanSnapshot
        local plan = PS and PS.Get and PS.Get() or nil
        planGen = type(plan) == "table" and tonumber(plan.planGen) or 0
    end
    local deferStore = building and Planner._demandDeferStore == true
    local cacheKey = FullCacheKey("demand:" .. tostring(planGen))
    if type(Planner._demandCache) == "table" and Planner._demandCacheKey == cacheKey then
        return Planner._demandCache
    end
    -- Plant/refine quiet / Orch decision hold: reuse last demand (ignore snap bump).
    -- The old watch/plan suffix test returned the same cache on both sides (PLN-4).
    if HoldHaveCacheQuiet() and type(Planner._demandCache) == "table" then
        Planner._heldCountsUsed = true
        return Planner._demandCache
    end
    -- Orch PickPlantCandidate: never bag-walk; FrameWork prewarm owns cold fills.
    if opts.cacheOnly == true then
        if type(Planner._demandCache) == "table" then
            return Planner._demandCache
        end
        return nil
    end
    PerfBegin("BuildBalancedSpecDemand")
    local demand = {}
    local RS = RecipeSpec()
    local watches = Watch and Watch.GetWatches and Watch.GetWatches() or {}
    if type(watches) ~= "table" or not RS then
        if deferStore ~= true then
            Planner._demandCache = demand
            Planner._demandCacheKey = cacheKey
        end
        PerfEnd("BuildBalancedSpecDemand")
        return demand
    end
    local entries = {}
    for watchKey, watch in pairs(watches) do
        if WatchWantsAutoGrow(watchKey, watch) then
            local resolved = ResolveWatchPotion(watchKey)
            local potion = resolved and resolved.potion
            local recipe = RS.RecipeSpecForPotion and RS.RecipeSpecForPotion(watchKey)
            if type(potion) == "table" and type(recipe) == "table" then
                if RS.HydrateRecipeSlots then
                    RS.HydrateRecipeSlots(recipe)
                end
                local uid = tonumber(resolved and resolved.outputUid) or tonumber(potion.outputUid) or 0
                local target = tonumber(watch.targetStock) or 0
                local have = PotionHave(resolved, potion, uid)
                local deficit = math.max(0, target - have)
                local stillNeeds = WatchStillNeedsGrow(
                    potion, recipe, target, watchKey, building and Planner._buildRows or nil
                ) == true
                if building and type(Planner._demandNeedScratch) == "table" then
                    Planner._demandNeedScratch[tostring(watchKey)] = stillNeeds
                end
                if uid > 0 and deficit > 0 and target > 0 then
                    entries[#entries + 1] = {
                        key = watchKey,
                        tier = WatchPriorityTier(watchKey, watch),
                        target = target,
                        have = have,
                        recipe = recipe,
                        potion = potion,
                        uid = uid,
                        stillNeeds = stillNeeds,
                    }
                end
            end
        end
    end
    local groups = GroupWatchesByOutputUid(entries)
    local convertPref = {}
    for gi = 1, #groups do
        local group = groups[gi]
        local recipe = group.recipe
        local target = group.maxTarget
        local have = group.have
        local deficit = math.max(0, target - have)
        local craftsNeeded = CraftsNeededForDeficit(deficit, recipe, group.uid)
        local slots = recipe.slots or {}
        local prefKey, prefRank = nil, 99
        local byproductKeys = {}
        for j = 1, #slots do
            local slot = slots[j]
            local spec = ResolveSlotSpec(slot)
            if type(spec) == "table" then
                local specKey = SpecKey(spec)
                if specKey ~= nil then
                    local perCraft = EffectivePerCraft(slot, slots)
                    local absNeed = craftsNeeded * perCraft
                    local role = slot.role or spec.role
                    local byproduct = SpecIsHarvestByproduct(spec) == true
                    local row = demand[specKey]
                    if row == nil then
                        row = {
                            spec = spec,
                            specKey = specKey,
                            role = slot.role,
                            perCraft = perCraft,
                            absolute = 0,
                            reserveAbsolute = 0,
                            watchNames = {},
                            watchDetails = {},
                        }
                        demand[specKey] = row
                    end
                    row.reserveAbsolute = (tonumber(row.reserveAbsolute) or 0) + absNeed
                    -- Grow targets only watches that still need planting.
                    -- Byproduct rows keep the pooled claim so convert uses one deficit.
                    -- Covered watches still reserve plants (Refine must not treat them as surplus).
                    if byproduct or group.stillNeeds == true then
                        row.absolute = (tonumber(row.absolute) or 0) + absNeed
                    end
                    if perCraft > (row.perCraft or 0) then
                        row.perCraft = perCraft
                    end
                    local watchName = (group.potion and group.potion.name) or towstring(tostring(group.key))
                    row.watchNames[#row.watchNames + 1] = watchName
                    row.watchDetails[#row.watchDetails + 1] = {
                        potionKey = group.key,
                        name = watchName,
                        have = have,
                        target = target,
                        deficit = deficit,
                    }
                    if byproduct then
                        byproductKeys[#byproductKeys + 1] = specKey
                    elseif SpecCanAutoGrowProgress(spec, role) then
                        local rank = ByproductConvertRoleRank(role)
                        if rank < prefRank then
                            prefRank = rank
                            prefKey = specKey
                        end
                    end
                end
            end
        end
        if prefKey ~= nil then
            for b = 1, #byproductKeys do
                local bpKey = byproductKeys[b]
                local prev = convertPref[bpKey]
                if prev == nil or prefRank < prev.rank
                    or (prefRank == prev.rank and tostring(prefKey) < tostring(prev.plantKey))
                then
                    convertPref[bpKey] = { plantKey = prefKey, rank = prefRank }
                end
            end
        end
    end
    WarmSpecHaveCache(demand)
    if Planner._buildSliceAbort ~= nil then
        PerfEnd("BuildBalancedSpecDemand")
        return nil
    end
    local SM = StockPiler.SeedMap
    for _, row in pairs(demand) do
        row.have = CountItemsMatchingSpec(row.spec)
        row.deficit = math.max(0, (tonumber(row.absolute) or 0) - (tonumber(row.have) or 0))
        local pc = math.max(1, tonumber(row.perCraft) or 1)
        row.craftsHave = math.floor((tonumber(row.have) or 0) / pc)
        row.craftsNeeded = math.ceil((tonumber(row.absolute) or 0) / pc)
        row.craftsShort = math.max(0, row.craftsNeeded - row.craftsHave)
        if row.reserveAbsolute == nil then
            row.reserveAbsolute = tonumber(row.absolute) or 0
        end
        -- Refine surplus uses brewAbsolute, which includes covered watches.
        row.brewAbsolute = tonumber(row.reserveAbsolute) or tonumber(row.absolute) or 0
        row.byproductConvertExtra = 0
        -- Resolve plant/seed uids once for Grow/Refine (fingerprint specs included).
        if type(row.spec) == "table" and SM then
            if SpecIsHarvestByproduct(row.spec) then
                row.isByproduct = true
                row.plantUid = 0
                row.seedUid = 0
            else
                row.isByproduct = false
                local plantUid = 0
                local seedUid = 0
                -- Containers are buy-only; never assign plantUid (84904 vials looked "refinable").
                local role = tostring(row.role or row.spec.role or "")
                local progress = role ~= "container" and SpecCanAutoGrowProgress(row.spec, role)
                if progress then
                    if SpecIsGrowable(row.spec, role) and SM.FindPlantUidForSpec then
                        plantUid = tonumber(SM.FindPlantUidForSpec(row.spec)) or 0
                    else
                        plantUid = FindGrowableTwinCached(row.spec)
                    end
                    if SM.ResolveSeedForSpec then
                        local seed = SM.ResolveSeedForSpec(row.spec)
                        if type(seed) == "table" then
                            seedUid = tonumber(seed.uniqueID or seed.uid) or 0
                            if plantUid <= 0 then
                                plantUid = tonumber(seed.plantUid) or 0
                            end
                        end
                    end
                end
                row.plantUid = plantUid
                row.seedUid = seedUid
            end
        end
    end

    -- One pooled byproduct deficit inflates the preferred plant row once.
    for bpKey, pref in pairs(convertPref) do
        local bp = demand[bpKey]
        local short = type(bp) == "table" and (tonumber(bp.deficit) or 0) or 0
        local plant = pref and demand[pref.plantKey] or nil
        if short > 0 and type(plant) == "table" then
            InflateConvertGrowRow(plant, short)
        end
    end

    -- One-pass feedstock flag: surplus growable plant at a skill level with resin short.
    local shortResinLevels = {}
    for _, row in pairs(demand) do
        if type(row) == "table" and row.isByproduct == true and (tonumber(row.deficit) or 0) > 0 then
            local lv = tonumber(row.spec and row.spec.skillLevel) or 0
            if lv > 0 then
                shortResinLevels[lv] = true
            end
        end
    end
    local hasResinFeedstock = false
    local Refine = StockPiler.Refine
    for _, row in pairs(demand) do
        if type(row) == "table" and row.isByproduct ~= true and type(row.spec) == "table" then
            local lv = tonumber(row.spec.skillLevel) or 0
            if shortResinLevels[lv] == true and SpecIsGrowable(row.spec, row.role) then
                local brewAbs = tonumber(row.brewAbsolute) or 0
                local surplus = (tonumber(row.have) or 0) - brewAbs
                if surplus > 0 then
                    local refinable = 0
                    if Refine and Refine.CountRefinablePlants then
                        refinable = tonumber(Refine.CountRefinablePlants(row.plantUid, row.spec)) or 0
                    elseif (tonumber(row.plantUid) or 0) > 0 then
                        refinable = surplus
                    end
                    if refinable > 0 then
                        hasResinFeedstock = true
                        break
                    end
                end
            end
        end
    end
    demand._resinFeedstock = hasResinFeedstock

    if deferStore ~= true then
        Planner._demandCache = demand
        Planner._demandCacheKey = cacheKey
    end
    PerfEnd("BuildBalancedSpecDemand")
    return demand
end

local function CollectFocus(mode, rowsOpt)
    local Watch = StockPiler.Watch
    local RS = RecipeSpec()
    local PS = StockPiler.PlanSnapshot
    local plan = PS and PS.Get and PS.Get() or nil
    local planRows
    local planGen
    if type(rowsOpt) == "table" then
        planRows = rowsOpt
        planGen = tonumber(Planner._buildPlanGen) or tonumber(Planner._planGen) or 0
    elseif InProgressBuild() then
        planRows = Planner._buildRows
        planGen = tonumber(Planner._buildPlanGen) or tonumber(Planner._planGen) or 0
    else
        planGen = type(plan) == "table" and tonumber(plan.planGen) or 0
        planRows = type(plan) == "table" and plan.rows or nil
    end
    local cacheKey = FullCacheKey(tostring(mode) .. ":" .. tostring(planGen))
    local cacheField = mode == "buy" and "_autoBuyFocusCache" or "_autoGrowFocusCache"
    local keyField = mode == "buy" and "_autoBuyFocusKey" or "_autoGrowFocusKey"
    if type(Planner[cacheField]) == "table" and Planner[keyField] == cacheKey then
        return Planner[cacheField]
    end
    local focus = { maxBottleGap = nil, minCraftable = nil, watches = {} }
    local candidates = {}

    -- Prefer polished plan rows (single source of truth) when available.
    -- During a build, planRows is the rows being built, not the published snapshot.
    if type(planRows) == "table" and #planRows > 0 then
        for i = 1, #planRows do
            local row = planRows[i]
            if type(row) == "table" then
                local watchKey = tostring(row.potionKey or row.potionRecipeKey or row.id or "")
                if row.kind == "plant" or row.isPlantWatch == true then
                    -- Plant stock rows never enter potion grow/buy focus.
                else
                local watch = ResolveWatchRow(watchKey, nil)
                local ok = WatchInActingSet(watchKey, watch, mode)
                local deficit = tonumber(row.potionDeficit) or 0
                if ok and deficit > 0 and watchKey ~= "" then
                    local gap = tonumber(row.bottleGap)
                    if gap == nil then
                        gap = BottleGap(row.potionMin or row.target, row.potionHave, row.craftable)
                    end
                    local statusKey = tostring(row.statusKey or "")
                    local still = gap > 0
                    if not still then
                        -- Shared contest (gap=0): Grow and Buy both keep these watches.
                        -- Buy must purchase contested flasks so AutoBrew can clear the set.
                        still = row.craftableShared == true
                        if mode ~= "buy" and not still then
                            still = statusKey == "need_seeds"
                        end
                    end
                    if still then
                        local priorityTier = tonumber(row.priorityTier)
                        if priorityTier == nil and Watch and Watch.GetPriorityTier then
                            priorityTier = Watch.GetPriorityTier(watchKey)
                        end
                        candidates[#candidates + 1] = {
                            potionKey = watchKey,
                            name = row.name or L"",
                            craftable = tonumber(row.craftable) or 0,
                            stock = tonumber(row.potionHave) or 0,
                            target = tonumber(row.potionMin) or tonumber(row.target) or 0,
                            bottleGap = gap,
                            recipe = row.recipe,
                            statusKey = statusKey,
                            craftableShared = row.craftableShared == true,
                            priorityTier = tonumber(priorityTier) or 1,
                            uniqueID = tonumber(row.uniqueID) or 0,
                        }
                        if focus.maxBottleGap == nil or gap > focus.maxBottleGap then
                            focus.maxBottleGap = gap
                        end
                    end
                end
                end
            end
        end
    else
        -- Cold boot: no plan yet - resolve watches once.
        local watches = Watch and Watch.GetWatches and Watch.GetWatches() or {}
        if type(watches) == "table" and RS then
            for watchKey, watch in pairs(watches) do
                if WatchInActingSet(watchKey, watch, mode) then
                    local resolved = ResolveWatchPotion(watchKey)
                    local potion = resolved and resolved.potion
                    local recipe = RS.RecipeSpecForPotion and RS.RecipeSpecForPotion(watchKey)
                    if type(potion) == "table" and type(recipe) == "table" then
                        local target = tonumber(watch.targetStock) or 0
                        local outUid = tonumber(potion.outputUid) or 0
                        local stock = PotionHave(resolved, potion, outUid)
                        local deficit = math.max(0, target - stock)
                        if deficit > 0 and target > 0 then
                            local craftable = CountPotionsCraftable(recipe, outUid)
                            local gap = BottleGap(target, stock, craftable)
                            local still = gap > 0
                            if not still then
                                -- Plan-backed shared contest / grow still-needed.
                                still = WatchStillNeedsGrow(potion, recipe, target, watchKey, planRows) == true
                            end
                            if still then
                                local priorityTier = 1
                                if Watch and Watch.GetPriorityTier then
                                    priorityTier = Watch.GetPriorityTier(watchKey)
                                else
                                    priorityTier = tonumber(watch.priorityTier) or 1
                                end
                                candidates[#candidates + 1] = {
                                    potionKey = watchKey,
                                    name = potion.name or L"",
                                    craftable = craftable,
                                    stock = stock,
                                    target = target,
                                    bottleGap = gap,
                                    recipe = recipe,
                                    priorityTier = tonumber(priorityTier) or 1,
                                    uniqueID = outUid,
                                }
                                if focus.maxBottleGap == nil or gap > focus.maxBottleGap then
                                    focus.maxBottleGap = gap
                                end
                            end
                        end
                    end
                end
            end
        end
    end

    -- Same output uid shares one stock target and the best-priority recipe.
    candidates = CollapseFocusCandidates(candidates)

    -- Best priority tier among armed candidates that still need work, then
    -- bottle-gap water-fill within that band.
    local bestTier = nil
    for i = 1, #candidates do
        local t = tonumber(candidates[i].priorityTier) or 1
        if bestTier == nil or t < bestTier then
            bestTier = t
        end
    end
    bestTier = tonumber(bestTier) or 1

    local tierBand = {}
    for i = 1, #candidates do
        if (tonumber(candidates[i].priorityTier) or 1) == bestTier then
            tierBand[#tierBand + 1] = candidates[i]
        end
    end

    local maxGap = 0
    for i = 1, #tierBand do
        local gap = tonumber(tierBand[i].bottleGap) or 0
        if gap > maxGap then
            maxGap = gap
        end
    end
    focus.maxBottleGap = maxGap
    focus.bestPriorityTier = bestTier

    local atMax = {}
    for i = 1, #tierBand do
        if (tonumber(tierBand[i].bottleGap) or 0) == maxGap then
            atMax[#atMax + 1] = tierBand[i]
            local c = tonumber(tierBand[i].craftable) or 0
            if focus.minCraftable == nil or c < focus.minCraftable then
                focus.minCraftable = c
            end
        end
    end
    -- Among max bottleGap: lowest craftable first (raise emptiest glasses).
    table.sort(atMax, function(a, b)
        local ca = tonumber(a and a.craftable) or 0
        local cb = tonumber(b and b.craftable) or 0
        if ca ~= cb then
            return ca < cb
        end
        local ga = tonumber(a and a.bottleGap) or 0
        local gb = tonumber(b and b.bottleGap) or 0
        if ga ~= gb then
            return ga > gb
        end
        return ToNarrow(a and a.name) < ToNarrow(b and b.name)
    end)
    -- Buy: keep all short watches for focus->fallback; Grow uses max-gap only.
    -- Sort full list by tier then gap so fallback respects priority too.
    if mode == "buy" then
        table.sort(candidates, function(a, b)
            local ta = tonumber(a and a.priorityTier) or 1
            local tb = tonumber(b and b.priorityTier) or 1
            if ta ~= tb then
                return ta < tb
            end
            local ga = tonumber(a and a.bottleGap) or 0
            local gb = tonumber(b and b.bottleGap) or 0
            if ga ~= gb then
                return ga > gb
            end
            local ca = tonumber(a and a.craftable) or 0
            local cb = tonumber(b and b.craftable) or 0
            if ca ~= cb then
                return ca < cb
            end
            return ToNarrow(a and a.name) < ToNarrow(b and b.name)
        end)
        focus.allWatches = candidates
    end
    focus.watches = atMax
    focus.fromPlan = type(planRows) == "table" and #planRows > 0
    focus.planGen = planGen
    Planner[cacheField] = focus
    Planner[keyField] = cacheKey
    return focus
end

--- Deficit remains and craftable does not yet cover target (or craftable is contested).
--- Prefer polished plan-row fields (SoT); fall back to live craftable when no plan.
--- rows, when passed, is this build's rows. Nil keeps the published snapshot.
WatchStillNeedsGrow = function(potion, recipe, target, watchKey, rows)
    target = tonumber(target) or 0
    if target <= 0 then
        return false
    end
    watchKey = tostring(watchKey or "")
    if type(rows) ~= "table" then
        local PS = StockPiler.PlanSnapshot
        local plan = PS and PS.Get and PS.Get()
        rows = plan and plan.rows
    end
    -- Plan SoT first: works without a live potion table (published rows omit it).
    if type(rows) == "table" and watchKey ~= "" then
        for i = 1, #rows do
            local row = rows[i]
            if type(row) == "table" then
                local rk = tostring(row.potionKey or row.potionRecipeKey or row.id or "")
                if rk == watchKey then
                    if (tonumber(row.potionDeficit) or 0) <= 0 then
                        return false
                    end
                    local gap = tonumber(row.bottleGap)
                    if gap == nil then
                        gap = BottleGap(row.potionMin or row.target, row.potionHave, row.craftable)
                    end
                    if gap > 0 then
                        return true
                    end
                    if row.craftableShared == true
                        or tostring(row.statusKey or "") == "ready_to_craft_shared"
                    then
                        return true
                    end
                    if tostring(row.statusKey or "") == "need_seeds" then
                        return true
                    end
                    return false
                end
            end
        end
    end
    if type(potion) ~= "table" then
        return false
    end
    local outUid = tonumber(potion.outputUid) or 0
    local have = PotionHave(nil, potion, outUid)
    local deficit = math.max(0, target - have)
    if deficit <= 0 then
        return false
    end
    local craftable = CountPotionsCraftable(recipe, outUid)
    return have + craftable < target
end

local function CollectAutoGrowSeedLines()
    local Watch = StockPiler.Watch
    local cacheKey = FullCacheKey("seeds")
    if type(Planner._seedLinesCache) == "table" and Planner._seedLinesCacheKey == cacheKey then
        return Planner._seedLinesCache
    end
    local lines = {}
    local seen = {}
    local SM = StockPiler.SeedMap
    local MS = MaterialSpec()
    local RS = RecipeSpec()
    local watches = Watch and Watch.GetWatches and Watch.GetWatches() or {}
    if type(watches) ~= "table" or type(SM) ~= "table" or not SM.IsGrowableSpec then
        Planner._seedLinesCache = lines
        Planner._seedLinesCacheKey = cacheKey
        return lines
    end
    for watchKey, watch in pairs(watches) do
        if WatchWantsAutoGrow(watchKey, watch) then
            -- Include stocked watches: seed buffer protects the line even at potion target.
            local recipe = RS and RS.RecipeSpecForPotion and RS.RecipeSpecForPotion(watchKey)
            if type(recipe) == "table" then
                if RS.HydrateRecipeSlots then
                    RS.HydrateRecipeSlots(recipe)
                end
                local slots = recipe.slots or {}
                for i = 1, #slots do
                    local spec = ResolveSlotSpec(slots[i])
                    if type(spec) == "table" and SM.IsGrowableSpec(spec) == true then
                        if SM.IsOneWayHarvestSpec and SM.IsOneWayHarvestSpec(spec) == true then
                            -- skip buffer lines for one-way
                        else
                            local productKey = SpecKey(spec)
                                or (MS and MS.ProductKey and MS.ProductKey(spec))
                                or ""
                            if productKey ~= "" and seen[productKey] ~= true then
                                local plantUid = 0
                                if SM.FindPlantUidForSpec then
                                    plantUid = tonumber(SM.FindPlantUidForSpec(spec)) or 0
                                end
                                local seedUid = 0
                                local seed = nil
                                -- Prefer skill-matched link (owned L1 must not become the buffer seed).
                                local plantKnownNoSeed = false
                                if plantUid > 0 and SM.ResolveSeedUidForPlant then
                                    seedUid = tonumber(SM.ResolveSeedUidForPlant(plantUid, spec)) or 0
                                    if seedUid > 0 then
                                        seed = { uniqueID = seedUid, plantUid = plantUid }
                                    else
                                        -- Cult-max s0 (Savage Marshroot): do not ResolveSeedForSpec /
                                        -- GetSeedUidsForPlant[1] - those prefer bag lower-tier seeds
                                        -- and drop the plant cushion from AutoGrow seed lines.
                                        plantKnownNoSeed = true
                                    end
                                end
                                if seedUid <= 0 and not plantKnownNoSeed and SM.ResolveSeedForSpec then
                                    seed = SM.ResolveSeedForSpec(spec)
                                    if type(seed) == "table" then
                                        seedUid = tonumber(seed.uniqueID) or 0
                                        if plantUid <= 0 then
                                            plantUid = tonumber(seed.plantUid) or 0
                                        end
                                    end
                                end
                                if seedUid <= 0 and not plantKnownNoSeed and plantUid > 0
                                    and SM.PickBestSeedUid
                                then
                                    local seedUids = SM.GetSeedUidsForPlant and SM.GetSeedUidsForPlant(plantUid) or {}
                                    seedUid = tonumber(SM.PickBestSeedUid(plantUid, seedUids, spec)) or 0
                                end
                                if seedUid <= 0 and not plantKnownNoSeed and plantUid > 0
                                    and SM.GetSeedUidsForPlant
                                then
                                    local seedUids = SM.GetSeedUidsForPlant(plantUid)
                                    seedUid = type(seedUids) == "table" and (tonumber(seedUids[1]) or 0) or 0
                                end
                                if plantUid > 0 and seedUid > 0 then
                                    seen[productKey] = true
                                    lines[#lines + 1] = {
                                        spec = spec,
                                        specKey = productKey,
                                        seedUid = seedUid,
                                        plantUid = plantUid,
                                        seed = seed or { uniqueID = seedUid, plantUid = plantUid },
                                    }
                                elseif plantUid > 0 and seedUid <= 0 then
                                    -- Plant-only cushion (ladder 200:s0/p84348).
                                    seen[productKey] = true
                                    lines[#lines + 1] = {
                                        spec = spec,
                                        specKey = productKey,
                                        seedUid = 0,
                                        plantUid = plantUid,
                                        seed = nil,
                                        plantOnly = true,
                                    }
                                end
                            end
                        end
                    end
                end
            end
        end
    end
    -- Plant watches: same seed-buffer lines so plant_stock planting respects cushion.
    local plantWatches = Watch and Watch.GetPlantWatches and Watch.GetPlantWatches() or {}
    if type(plantWatches) == "table" then
        for plantKey, watch in pairs(plantWatches) do
            if type(watch) == "table" and watch.enabled == true
                and (Watch.ShouldAutoGrowPlant == nil or Watch.ShouldAutoGrowPlant(plantKey) == true)
            then
                local plantUid = Watch.ParsePlantKey and Watch.ParsePlantKey(plantKey) or 0
                plantUid = tonumber(plantUid) or 0
                if plantUid > 0 then
                    local Items = StockPiler.Items
                    local spec = Items and Items.ToSpec and Items.ToSpec(plantUid) or nil
                    if type(spec) ~= "table" and MS and MS.FromUid then
                        spec = MS.FromUid(plantUid)
                    end
                    if type(spec) == "table" and SM.IsGrowableSpec(spec) == true then
                        if not (SM.IsOneWayHarvestSpec and SM.IsOneWayHarvestSpec(spec) == true) then
                            local productKey = SpecKey(spec)
                                or (MS and MS.ProductKey and MS.ProductKey(spec))
                                or ("plant:" .. tostring(plantUid))
                            if productKey ~= "" and seen[productKey] ~= true then
                                local seedUid = 0
                                local seed = nil
                                if SM.ResolveSeedUidForPlant then
                                    seedUid = tonumber(SM.ResolveSeedUidForPlant(plantUid, spec)) or 0
                                end
                                if seedUid <= 0 and SM.ResolveSeedForSpec then
                                    seed = SM.ResolveSeedForSpec(spec)
                                    if type(seed) == "table" then
                                        seedUid = tonumber(seed.uniqueID) or 0
                                    end
                                end
                                if seedUid <= 0 and SM.GetSeedUidsForPlant then
                                    local seeds = SM.GetSeedUidsForPlant(plantUid)
                                    if type(seeds) == "table" and #seeds > 0 then
                                        seedUid = tonumber(seeds[1]) or 0
                                    end
                                end
                                if seedUid > 0 then
                                    seed = seed or { uniqueID = seedUid }
                                end
                                seen[productKey] = true
                                lines[#lines + 1] = {
                                    spec = spec,
                                    specKey = productKey,
                                    seedUid = seedUid,
                                    plantUid = plantUid,
                                    seed = seed,
                                    plantStock = true,
                                }
                            end
                        end
                    end
                end
            end
        end
    end
    Planner._seedLinesCache = lines
    Planner._seedLinesCacheKey = cacheKey
    local Refine = StockPiler.Refine
    if Refine and Refine.InvalidateBufferFlags then
        Refine.InvalidateBufferFlags()
    end
    return lines
end

----------------------------------------------------------------
-- Shared craftable (deficit crafts only) - plan-row SoT
----------------------------------------------------------------

local function ApplyDeficitCraftableShared(rows)
    local RS = RecipeSpec()
    if type(rows) ~= "table" then
        return
    end
    local matUsers = {}
    for i = 1, #rows do
        local row = rows[i]
        if type(row) == "table" then
            if row.kind == "plant" or row.isPlantWatch == true then
                row.craftableShared = false
                row.contestedSpecKeys = nil
            else
            row.craftableShared = false
            row.contestedSpecKeys = nil
            local deficit = tonumber(row.potionDeficit) or 0
            local craftable = tonumber(row.craftable) or 0
            local potionKey = tostring(row.potionKey or row.potionRecipeKey or row.id or "")
            -- Only AutoGrow-armed watches compete for mats. Manual/off watches stay brewable
            -- without flipping siblings to "Shared materials".
            local armed = WatchWantsAutoGrow(potionKey, nil)
            if armed and deficit > 0 and craftable > 0 and type(row.recipe) == "table" then
                local recipe = row.recipe
                if RS and RS.HydrateRecipeSlots then
                    RS.HydrateRecipeSlots(recipe)
                end
                local slots = recipe.slots
                if type(slots) == "table" then
                    local craftsPossible = tonumber(row.craftsPossible) or 0
                    local outUid = tonumber(row.uniqueID) or 0
                    local craftsNeeded = tonumber(row.craftsNeeded)
                        or CraftsNeededForDeficit(deficit, recipe, outUid)
                    local crafts = math.min(craftsPossible, craftsNeeded)
                    row.craftsClaim = crafts
                    for s = 1, #slots do
                        local slot = slots[s]
                        local spec = ResolveSlotSpec(slot)
                        local specKey = SpecKey(spec)
                        if type(specKey) == "string" then
                            local list = matUsers[specKey]
                            if list == nil then
                                list = {}
                                matUsers[specKey] = list
                            end
                            list[#list + 1] = {
                                infoIdx = i,
                                perCraft = EffectivePerCraft(slot, slots),
                                crafts = crafts,
                                spec = spec,
                            }
                        end
                    end
                end
            end
            end
        end
    end
    for i = 1, #rows do
        local row = rows[i]
        local potionKey = type(row) == "table"
            and tostring(row.potionKey or row.potionRecipeKey or row.id or "") or ""
        if type(row) == "table"
            and row.kind ~= "plant" and row.isPlantWatch ~= true
            and WatchWantsAutoGrow(potionKey, nil)
            and (tonumber(row.potionDeficit) or 0) > 0
            and (tonumber(row.craftable) or 0) > 0
            and type(row.recipe) == "table"
        then
            local contested = false
            local contestedSpecKeys = {}
            local slots = row.recipe.slots
            if type(slots) == "table" then
                for s = 1, #slots do
                    local spec = ResolveSlotSpec(slots[s])
                    local specKey = SpecKey(spec)
                    local users = type(specKey) == "string" and matUsers[specKey] or nil
                    if type(users) == "table" and #users > 1 then
                        local combinedNeed = 0
                        for u = 1, #users do
                            combinedNeed = combinedNeed + users[u].crafts * users[u].perCraft
                        end
                        local have = CountItemsMatchingSpec(spec)
                        if have < combinedNeed then
                            contested = true
                            contestedSpecKeys[specKey] = true
                        end
                    end
                end
            end
            row.craftableShared = contested
            row.contestedSpecKeys = contested and contestedSpecKeys or nil
            -- Tip note override: contested -> (Shared)
            if contested and type(row.statusTipSlots) == "table" then
                for t = 1, #row.statusTipSlots do
                    local e = row.statusTipSlots[t]
                    if type(e) == "table" then
                        local k = SpecKey(e.spec)
                        if k ~= nil and contestedSpecKeys[k] == true then
                            e.note = "(Shared)"
                            e.noteKind = "shared"
                        end
                    end
                end
            end
        end
    end
end

--- Join distinct buy notes (Buy flasks / Buy materials / Buy seeds).
local function ComposeBuyStatusText(opts)
    opts = type(opts) == "table" and opts or {}
    local parts = {}
    if opts.flasks == true then
        parts[#parts + 1] = T("watch.note.buy_flasks")
    end
    if opts.seeds == true then
        parts[#parts + 1] = T("watch.note.buy_seeds")
    end
    if opts.materials == true then
        parts[#parts + 1] = T("watch.note.buy_materials")
    end
    if #parts == 0 then
        return T("plan.status.buy_ingredients")
    end
    if #parts == 1 then
        return parts[1]
    end
    local join = T("watch.note.buy_join")
    local out = parts[1]
    for i = 2, #parts do
        out = out .. join .. parts[i]
    end
    return out
end

local function BuyNoteFlagsFromEntry(entry)
    if type(entry) ~= "table" then
        return false, false, false
    end
    if tostring(entry.role or "") == "container" then
        return true, false, false
    end
    if entry.buySeedOrMat == true and (tonumber(entry.seedUid) or 0) > 0 then
        return false, true, false
    end
    return false, false, true
end

local function TipCountsForSpec(row, spec)
    local tips = row and row.statusTipSlots
    if type(tips) ~= "table" or type(spec) ~= "table" then
        return nil, nil, nil
    end
    local key = SpecKey(spec)
    for i = 1, #tips do
        local e = tips[i]
        if type(e) == "table" then
            local same = e.spec == spec
            if not same and key ~= nil then
                local ek = e.specKey
                if ek == nil and type(e.spec) == "table" then
                    ek = SpecKey(e.spec)
                end
                same = ek == key
            end
            if same then
                return tonumber(e.have), tonumber(e.need), tonumber(e.deficit)
            end
        end
    end
    return nil, nil, nil
end

--- True when this row still has a cult plant or cultivable twin below its need.
--- Have comes from the warm cache, then statusTipSlots. Never a cold bag scan:
--- PolishSharedContest runs on the live tick and a miss is WarmHave.miss.
local function RowHasGrowableShortfall(row)
    if type(row) ~= "table" then
        return false
    end
    local craftsNeeded = tonumber(row.craftsNeeded) or 0
    if craftsNeeded <= 0 then
        local deficit = tonumber(row.potionDeficit) or 0
        if deficit > 0 and type(row.recipe) == "table" then
            craftsNeeded = CraftsNeededForDeficit(
                deficit, row.recipe, tonumber(row.uniqueID) or 0
            )
        end
    end
    if craftsNeeded <= 0 then
        craftsNeeded = math.max(0, (tonumber(row.targetCount) or tonumber(row.target) or 0)
            - (tonumber(row.potionHave) or 0))
    end
    local slots = row.slotSpecs or row.slots
    if type(slots) ~= "table" then
        slots = row.recipe and row.recipe.slots
    end
    local function slotShort(spec, role, slot, slotList)
        if SpecCanAutoGrowProgress(spec, role) ~= true then
            return false
        end
        local per = 1
        if type(slot) == "table" then
            per = EffectivePerCraft(slot, slotList or slots)
        end
        local need = (tonumber(craftsNeeded) or 0) * per
        local have = CountItemsMatchingSpec(spec, { cacheOnly = true })
        if have ~= nil then
            return need > 0 and have < need
        end
        local tipHave, tipNeed, tipDeficit = TipCountsForSpec(row, spec)
        if tipDeficit ~= nil then
            return tipDeficit > 0
        end
        if tipHave ~= nil and tipNeed ~= nil then
            return tipHave < tipNeed
        end
        return false
    end
    if type(slots) == "table" then
        for i = 1, #slots do
            local slot = slots[i]
            local spec = ResolveSlotSpec(slot)
            if type(spec) ~= "table" and type(slot) == "table" and type(slot.spec) ~= "table" then
                spec = slot
            end
            if type(spec) == "table" then
                local role = (type(slot) == "table" and slot.role) or spec.role
                if slotShort(spec, role, slot, slots) then
                    return true
                end
            end
        end
        return false
    end
    local tips = row.statusTipSlots
    if type(tips) ~= "table" then
        return false
    end
    for i = 1, #tips do
        local e = tips[i]
        if type(e) == "table" and SpecCanAutoGrowProgress(e.spec, e.role) then
            local deficit = tonumber(e.deficit)
            if deficit ~= nil and deficit > 0 then
                return true
            end
            if (tonumber(e.have) or 0) < (tonumber(e.need) or 0) then
                return true
            end
        end
    end
    return false
end

--- Contested specs that are all non-growable -> "flasks" | "materials" | "both" | nil.
local function ContestedBuyOnlyKind(row)
    if type(row) ~= "table" or row.craftableShared ~= true then
        return nil
    end
    local contested = row.contestedSpecKeys
    if type(contested) ~= "table" then
        return nil
    end
    local slots = row.recipe and row.recipe.slots
    if type(slots) ~= "table" then
        return nil
    end
    local anyContested = false
    local anyGrowable = false
    local anyContainer = false
    local anyMaterials = false
    for i = 1, #slots do
        local slot = slots[i]
        local spec = ResolveSlotSpec(slot)
        local sk = SpecKey(spec)
        if type(sk) == "string" and contested[sk] == true then
            anyContested = true
            local role = slot.role or (type(spec) == "table" and spec.role) or nil
            if SpecIsHarvestByproduct(spec) ~= true and SpecCanAutoGrowProgress(spec, role) == true then
                anyGrowable = true
            elseif tostring(role or "") == "container" then
                anyContainer = true
            else
                anyMaterials = true
            end
        end
    end
    if not anyContested or anyGrowable then
        return nil
    end
    -- Shared flasks can be short across watches while this row can still grow.
    if RowHasGrowableShortfall(row) then
        return nil
    end
    if anyContainer and anyMaterials then
        return "both"
    end
    if anyContainer then
        return "flasks"
    end
    return "materials"
end

local function PaintBuyOnlySharedStatus(row, kind)
    row.statusKey = "buy_ingredients"
    if kind == "flasks" then
        row.statusText = T("watch.note.buy_flasks")
        row.statusLines = { T("watch.note.shared_buy_flasks") }
    elseif kind == "both" then
        row.statusText = ComposeBuyStatusText({ flasks = true, materials = true })
        row.statusLines = { T("watch.note.shared_buy_both") }
    else
        row.statusText = T("plan.status.buy_ingredients")
        row.statusLines = { T("watch.note.shared_buy") }
    end
end

local function PaintSharedMaterialsStatus(row)
    row.statusKey = "ready_to_craft_shared"
    row.statusText = T("plan.status.ready_to_craft_shared")
    row.statusLines = { T("watch.note.shared") }
end

-- Defined with the status helpers below. ApplySharedStatusFlip runs later.
local SetMaterialsShortStatus

local function RowCoveredForReady(row)
    local have = tonumber(row.potionHave) or 0
    local craftable = tonumber(row.craftable) or 0
    local target = tonumber(row.potionMin) or tonumber(row.target) or 0
    return target > 0 and (have + craftable) >= target
end

--- Ready <-> Shared / buy-only-shared paint from craftableShared (armed watches only).
--- Buy-only contests paint Buy flasks/materials (craftableShared stays true -> AutoBrew blocked).
--- Returns true when any row's shared flag or statusKey changed.
local function ApplySharedStatusFlip(rows)
    if type(rows) ~= "table" then
        return false
    end
    local changed = false
    for i = 1, #rows do
        local row = rows[i]
        if type(row) == "table" then
            local prevKey = tostring(row.statusKey or "")
            local prevShared = row.craftableShared == true
            local key = prevKey
            local pk = tostring(row.potionKey or row.potionRecipeKey or row.id or "")
            local armed = WatchWantsAutoGrow(pk, nil)
            local sharedPaintKeys = key == "ready_to_craft"
                or key == "ready_to_craft_shared"
                or (key == "buy_ingredients" and RowCoveredForReady(row))
            if row.craftableShared == true and armed and sharedPaintKeys then
                local buyKind = ContestedBuyOnlyKind(row)
                if buyKind ~= nil then
                    PaintBuyOnlySharedStatus(row, buyKind)
                elseif RowHasGrowableShortfall(row) then
                    -- Armed AutoGrow can still plant. Restocking, not Shared-only.
                    SetMaterialsShortStatus(row, true, nil)
                else
                    PaintSharedMaterialsStatus(row)
                end
            elseif key == "ready_to_craft" and row.craftableShared == true and not armed then
                row.craftableShared = false
                row.contestedSpecKeys = nil
            elseif key == "ready_to_craft_shared"
                and (row.craftableShared ~= true or not armed)
            then
                row.craftableShared = false
                row.contestedSpecKeys = nil
                row.statusKey = "ready_to_craft"
                row.statusText = T("plan.status.ready_to_craft")
                row.statusLines = { T("brew.ready", { name = row.name or T("brew.potion_fallback") }) }
            elseif key == "buy_ingredients"
                and row.craftableShared ~= true
                and armed
                and RowCoveredForReady(row)
            then
                -- Shared buy paint cleared after vendor fill -> Ready (AutoBrew can run).
                row.contestedSpecKeys = nil
                row.statusKey = "ready_to_craft"
                row.statusText = T("plan.status.ready_to_craft")
                row.statusLines = { T("brew.ready", { name = row.name or T("brew.potion_fallback") }) }
            end
            if tostring(row.statusKey or "") ~= prevKey or (row.craftableShared == true) ~= prevShared then
                changed = true
            end
        end
    end
    return changed
end

--- Cheap Shared contest + Ready/Shared paint. Safe on live craftable/deficit patches.
local function PolishSharedContest(rows)
    ApplyDeficitCraftableShared(rows)
    return ApplySharedStatusFlip(rows) == true
end

local function StampBottleGap(row)
    if type(row) ~= "table" then
        return
    end
    row.bottleGap = BottleGap(
        row.potionMin or row.target,
        row.potionHave,
        row.craftable
    )
end

local function AutoGrowWantsDemand()
    local Watch = StockPiler.Watch
    local Caps = StockPiler.TradeSkillCaps
    local master = false
    if Watch and Watch.IsAutoGrowMasterEnabled then
        master = Watch.IsAutoGrowMasterEnabled() == true
    elseif Watch and Watch.IsAutoGrowEnabled then
        master = Watch.IsAutoGrowEnabled() == true
    end
    if master ~= true then
        return false
    end
    if Caps and Caps.CanAutoGrow and Caps.CanAutoGrow() ~= true then
        return false
    end
    return true
end

--- Ask FrameWork to refill _demandCache. If that queue is not available,
--- mark the plan due so the next build warms demand instead of leaving it nil.
local function ScheduleDemandPrewarm(reason)
    if AutoGrowWantsDemand() ~= true then
        return
    end
    reason = reason or "focus-demand"
    local FW = StockPiler.FrameWork
    -- Already queued: do not re-enqueue (same snapGen would restart after finish).
    if FW and FW.IsActive and FW.IsActive("prewarm-demand") == true then
        Planner._demandPrewarmDue = true
        return
    end
    local dueKey = FullCacheKey("demand-prewarm")
    if Planner._demandPrewarmDue == true and Planner._demandPrewarmDueKey == dueKey then
        return
    end
    local Sch = StockPiler.Scheduler
    if Sch and Sch._pendingPrewarmAfterQuiet == true then
        Planner._demandPrewarmDue = true
        Planner._demandPrewarmDueKey = dueKey
        return
    end
    Planner._demandPrewarmDue = true
    Planner._demandPrewarmDueKey = dueKey
    if Sch and Sch.RequestDemandPrewarm then
        Sch.RequestDemandPrewarm(reason)
    elseif Sch and Sch.RequestCachePrewarm then
        Sch.RequestCachePrewarm(reason)
    end
    if not (FW and FW.EnqueueDemand) and Sch then
        Sch._planDue = true
    end
end

local function InvalidateFocusCaches(reason)
    reason = tostring(reason or "focus")
    if StockPiler.Perf and StockPiler.Perf.Tally then
        StockPiler.Perf.Tally("focusInv", reason)
    end
    ClearSettingsHashMemo()
    Planner._autoGrowFocusCache = nil
    Planner._autoGrowFocusKey = nil
    Planner._autoBuyFocusCache = nil
    Planner._autoBuyFocusKey = nil
    -- Demand was keyed only on snap/watch gen; empty demand cached while gap=0 then
    -- plan craftable/gap moved (same snap) left AutoGrow with plantJob=nil no-demand-short.
    Planner._demandCache = nil
    Planner._demandCacheKey = nil
    Planner._craftBagFull = nil
    Planner._craftBagFullSnap = nil
    Planner._craftBagFreeCached = nil
    -- Stocked potion rows clear demand without a plan rebuild. Prewarm it back
    -- so potion lift is not stuck on a nil cache (plant_stock does not wait).
    ScheduleDemandPrewarm(reason)
end

function Planner.InvalidateFocusCaches(reason)
    InvalidateFocusCaches(reason)
end

----------------------------------------------------------------
-- Status helpers
----------------------------------------------------------------

function SetMaterialsShortStatus(row, growable, buyLabel)
    if growable == true and CanAutoGrowSkill() then
        local key = nil
        local watch = nil
        if type(row) == "table" then
            key = RowWatchKey(row)
            -- Keep row.autoGrow aligned with the watch store (live rows can drift).
            watch = ResolveWatchRow(key, nil)
            if type(watch) == "table" then
                row.autoGrow = watch.autoGrow == true
            else
                -- Missed lookup must not leave a checked AutoGrow + Enable AutoGrow status.
                row.autoGrow = false
            end
        end
        -- Single source of truth: master + per-watch + enabled.
        if WatchWantsAutoGrow(key, watch) then
            row.statusKey = "restocking"
            row.statusText = T("plan.status.restocking")
            row.statusLines = nil
            return
        end
        row.statusKey = "enable_autogrow"
        row.statusText = T("plan.status.enable_autogrow")
        row.statusLines = nil
        return
    end
    row.statusKey = "buy_ingredients"
    row.statusText = buyLabel or T("plan.status.buy_ingredients")
    row.statusLines = nil
end

--- After live patches / toggle: Enable AutoGrow <-> Restocking must track current toggles.
--- Also demotes Seed buffer -> Enable AutoGrow when master/per-watch AutoGrow turns off.
--- Plant stock waits only while potion watches still need Cult grow (soft gate).
--- Optional rows: in-build potion rows so we do not read a stale PlanSnapshot.
local function PlantWatchesAwaitPotions(rows)
    local Watch = StockPiler.Watch
    if Watch and Watch.EnabledPotionWatchesNeedCultGrow then
        return Watch.EnabledPotionWatchesNeedCultGrow(rows) == true
    end
    if not (Watch and Watch.AllEnabledPotionWatchesStocked) then
        return false
    end
    return Watch.AllEnabledPotionWatchesStocked() ~= true
end

--- Seed-buffer short for plant watches (used by Reconcile + ApplyPlantWatchStatus).
--- Must be defined above ReconcileAutoGrowStatus (Lua local visibility).
local function PlantSeedBufferShort(seedUid, plantUid, spec)
    local Watch = StockPiler.Watch
    if not (Watch and Watch.IsSeedBufferEnabled and Watch.IsSeedBufferEnabled() == true) then
        return false
    end
    seedUid = tonumber(seedUid) or 0
    plantUid = tonumber(plantUid) or 0
    if seedUid <= 0 and plantUid > 0 then
        local SM = StockPiler.SeedMap
        if SM and SM.ResolveSeedUidForPlant then
            seedUid = tonumber(SM.ResolveSeedUidForPlant(plantUid, spec)) or 0
        end
    end
    local buffer = Watch.GetSeedBufferMin and tonumber(Watch.GetSeedBufferMin()) or 5
    local Inv = StockPiler.Inventory
    if seedUid <= 0 then
        -- Plant-only cushion (no known seed), e.g. Savage Marshroot s0.
        if plantUid <= 0 then
            return false
        end
        local have = Inv and Inv.CountByUid and tonumber(Inv.CountByUid(plantUid)) or 0
        return have < buffer
    end
    local Refine = StockPiler.Refine
    if Refine and Refine.GetSeedBudget then
        local b = Refine.GetSeedBudget(seedUid)
        if type(b) == "table" then
            local credit = tonumber(b.credit)
            if credit == nil then
                credit = tonumber(b.live) or 0
            end
            return credit < buffer
        end
    end
    local have = Inv and Inv.CountByUid and tonumber(Inv.CountByUid(seedUid)) or 0
    return have < buffer
end

local function ReconcileAutoGrowStatus(row)
    if type(row) ~= "table" then
        return false
    end
    if row.skillUp == true or row.addonOwned == true then
        return false
    end
    -- Plant watches: flip Enable AutoGrow <-> Restocking / Stocked immediately on toggle.
    -- Full seed-buffer / Upgrade Seed paint waits for ApplyPlantWatchStatus (live patch / rebuild).
    if row.kind == "plant" or row.isPlantWatch == true then
        local Watch = StockPiler.Watch
        local plantKey = row.plantKey or row.id or row.potionKey
        local armed = Watch and Watch.ShouldAutoGrowPlant
            and Watch.ShouldAutoGrowPlant(plantKey) == true
        row.autoGrow = armed == true
        local key = tostring(row.statusKey or "")
        local deficit = tonumber(row.potionDeficit) or 0
        local prev = key
        if deficit <= 0 then
            if PlantSeedBufferShort(row.seedUid, row.plantUid, row.spec) then
                row.statusKey = "need_seeds"
                row.statusText = T("plan.status.need_seeds")
                row.statusLines = {
                    T("tip.watch.seed_buffer"),
                }
            else
                row.statusKey = "plant_stocked"
                row.statusText = T("plan.status.plant_stocked")
                row.statusLines = nil
            end
        elseif not armed then
            row.statusKey = "enable_autogrow"
            row.statusText = T("plan.status.enable_autogrow")
            row.statusLines = nil
        elseif key == "enable_autogrow" or key == "waiting_potions" or key == "restocking"
            or key == "craft_bag_full"
        then
            if PlantWatchesAwaitPotions() then
                row.statusKey = "waiting_potions"
                row.statusText = T("plan.status.waiting_potions")
                row.statusLines = {
                    T("tip.watch.plant_waiting_potions"),
                }
            else
                row.statusKey = "restocking"
                row.statusText = T("plan.status.restocking")
                row.statusLines = nil
            end
        end
        return tostring(row.statusKey or "") ~= prev
    end
    local key = tostring(row.statusKey or "")
    if key ~= "enable_autogrow" and key ~= "restocking" and key ~= "craft_bag_full"
        and key ~= "need_seeds"
        and key ~= "upgrading_seed"
    then
        return false
    end
    if not CanAutoGrowSkill() then
        return false
    end
    local potionKey = RowWatchKey(row)
    local watch = ResolveWatchRow(potionKey, nil)
    if type(watch) == "table" then
        row.autoGrow = watch.autoGrow == true
    else
        row.autoGrow = false
    end
    local armed = WatchWantsAutoGrow(potionKey, watch)
    local prev = key
    if armed and key == "enable_autogrow" then
        row.statusKey = "restocking"
        row.statusText = T("plan.status.restocking")
        row.statusLines = nil
    elseif (not armed) and (key == "restocking" or key == "craft_bag_full"
        or key == "need_seeds" or key == "upgrading_seed")
    then
        row.statusKey = "enable_autogrow"
        row.statusText = T("plan.status.enable_autogrow")
        row.statusLines = nil
    end
    return tostring(row.statusKey or "") ~= prev
end

--- Immediate Enable<->Restocking flip after master/per-watch AutoGrow toggles (no rebuild wait).
local function ReconcileAutoGrowStatusesForRows(rows)
    if type(rows) ~= "table" then
        return false
    end
    local changed = false
    for i = 1, #rows do
        if ReconcileAutoGrowStatus(rows[i]) then
            changed = true
        end
    end
    return changed
end

local StampRowSeedBufferUids

--- True when a stamped buffer seed/plant line has no credit at all (0/5), not
--- merely under the cushion (3/5). Empty lines need Buy seeds / Restocking, not
--- the "Seed buffer" cushion message.
local function SeedBufferHasEmptyLine(row)
    if type(row) ~= "table" then
        return false
    end
    StampRowSeedBufferUids(row)
    local Refine = StockPiler.Refine
    local Inv = StockPiler.Inventory
    local uids = row.seedBufferSeedUids
    if type(uids) == "table" then
        for i = 1, #uids do
            local uid = tonumber(uids[i]) or 0
            if uid > 0 then
                local credit = 0
                if Refine and Refine.GetSeedBudget then
                    local budget = Refine.GetSeedBudget(uid)
                    credit = tonumber(budget and budget.credit) or 0
                elseif Inv and Inv.CountByUid then
                    credit = tonumber(Inv.CountByUid(uid)) or 0
                end
                if credit <= 0 then
                    return true
                end
            end
        end
    end
    local pUids = row.seedBufferPlantUids
    if type(pUids) == "table" then
        for i = 1, #pUids do
            local uid = tonumber(pUids[i]) or 0
            if uid > 0 then
                local credit = Inv and Inv.CountByUid and tonumber(Inv.CountByUid(uid)) or 0
                if credit <= 0 then
                    return true
                end
            end
        end
    end
    return false
end

local function ApplySeedBufferStatus(row)
    local buffer = 5
    local Watch = StockPiler.Watch
    if Watch and Watch.GetSeedBufferMin then
        buffer = tonumber(Watch.GetSeedBufferMin()) or 5
    end
    -- Empty line (0/5) before climb paint. A live climb would otherwise hide
    -- Restocking / Buy seeds and leave the row looking like a cushion problem.
    -- Partial credit still falls through to Seed buffer below.
    if SeedBufferHasEmptyLine(row) then
        SetMaterialsShortStatus(row, true, T("watch.note.buy_seeds"))
        row.tipBuffer = buffer
        row.seedBufferShort = true
        row.craftableShared = false
        return
    end
    local US = StockPiler.UpgradeSeed
    local climb = nil
    local climbs = nil
    local isPlantWatch = row.isPlantWatch == true or row.kind == "plant"
    if US and US.IsEnabled and US.IsEnabled() == true and not isPlantWatch then
        -- Plant watches: stock / seed-buffer UI only. Climb status lives on
        -- ephemeral Upgrade rows (was painting "Upgrading marshroot" on the watch).
        if (tonumber(row.plantUid) or 0) > 0 then
            climb = US.StatusForPlant and US.StatusForPlant(row.plantUid, row.spec) or nil
        else
            -- Potion rows: only climbs for THIS watch's seeds/plants - never
            -- ListClimbStatuses()[1] (was painting "Upgrading fusk" on every short row).
            StampRowSeedBufferUids(row)
            local seedSet = {}
            local plantSet = {}
            local uids = row.seedBufferSeedUids
            if type(uids) == "table" then
                for i = 1, #uids do
                    local u = tonumber(uids[i]) or 0
                    if u > 0 then
                        seedSet[u] = true
                    end
                end
            end
            local tips = row.statusTipSlots
            if type(tips) == "table" then
                for i = 1, #tips do
                    local tip = tips[i]
                    if type(tip) == "table" then
                        local su = tonumber(tip.seedUid) or 0
                        local pu = tonumber(tip.plantUid) or 0
                        if su > 0 then
                            seedSet[su] = true
                        end
                        if pu > 0 then
                            plantSet[pu] = true
                        end
                    end
                end
            end
            local all = US.ListClimbStatuses and US.ListClimbStatuses() or nil
            if type(all) == "table" and #all > 0 then
                climbs = {}
                for i = 1, #all do
                    local c = all[i]
                    if type(c) == "table" then
                        local su = tonumber(c.seedUid) or 0
                        local pu = tonumber(c.plantUid) or 0
                        if (su > 0 and seedSet[su] == true) or (pu > 0 and plantSet[pu] == true) then
                            climbs[#climbs + 1] = c
                        end
                    end
                end
                if #climbs > 0 then
                    climb = climbs[1]
                else
                    climbs = nil
                end
            end
        end
    end
    if type(climb) == "table" and (climb.why == "planting" or climb.why == "refining"
        or climb.why == "need_buy" or climb.why == "need_cult" or climb.why == "no_family"
        or climb.why == "climbing")
    then
        row.statusKey = "upgrading_seed"
        local haveReq = tonumber(climb.haveReq) or 0
        local needReq = tonumber(climb.needReq) or 0
        local climbCap = tonumber(climb.climbCap) or 0
        if climbCap < 1 then
            climbCap = US.ClimbCap and US.ClimbCap(needReq) or needReq
        end
        local capShow = climbCap
        if needReq > 0 and needReq < capShow then
            capShow = needReq
        end
        local multi = type(climbs) == "table" and #climbs > 1
        if multi then
            row.statusText = T("plan.status.upgrading_seed_multi", {
                count = tostring(#climbs),
            })
        else
            row.statusText = T("plan.status.upgrading_seed_progress", {
                have = tostring(haveReq),
                cap = tostring(capShow),
            })
        end
        -- Detail lives on tip slot Have/Need notes (FormatClimbSlotNote).
        local lines = {}
        local autoGrowOn = Watch and Watch.IsAutoGrowEnabled and Watch.IsAutoGrowEnabled() == true
        if autoGrowOn ~= true then
            lines[#lines + 1] = T("plan.status.upgrading_seed_autogrow_off")
        end
        lines[#lines + 1] = T("tip.watch.upgrade_seeds")
        row.statusLines = lines
        row.craftableShared = false
        return
    end
    row.statusKey = "need_seeds"
    row.statusText = T("plan.status.need_seeds")
    row.tipBuffer = buffer
    row.statusLines = {
        T("tip.watch.seed_buffer"),
    }
    row.craftableShared = false
end

local function RoundTipYield(yield)
    yield = tonumber(yield) or 0
    if yield <= 0 then
        return 0
    end
    local nearest = math.floor(yield + 0.5)
    if math.abs(yield - nearest) <= 0.05 then
        return nearest
    end
    yield = math.floor(yield)
    if yield < 1 then
        return 1
    end
    return yield
end

--- Kind for a grow-note string. The Watch tooltip reads noteKind and does not
--- scan the English text.
local function ClassifyGrowingNote(notes)
    local n = string.lower(ToNarrow(notes))
    if string.find(n, "needs planting", 1, true)
        or string.find(n, "converting", 1, true)
        or string.find(n, "need seed", 1, true)
        or string.find(n, "buy seeds", 1, true)
        or string.find(n, "buy plants", 1, true)
        or string.find(n, "climbing", 1, true)
        or string.find(n, "climb ", 1, true)
        or string.find(n, "refining", 1, true)
        or string.find(n, "buy lower", 1, true)
    then
        return "warning"
    end
    if string.find(n, "buy flasks", 1, true)
        or string.find(n, "buy materials", 1, true)
        or string.find(n, "autogrow off", 1, true)
        or string.find(n, "needs cultivation", 1, true)
        or string.find(n, "need cult", 1, true)
    then
        return "negative"
    end
    if string.find(n, "ready to harvest", 1, true)
        or string.find(n, "growing", 1, true)
        or string.find(n, "germination", 1, true)
        or string.find(n, "seedling", 1, true)
        or string.find(n, "flowering", 1, true)
        or string.find(n, "planting", 1, true)
    then
        return "positive"
    end
    return "body"
end

--- statusKind, yield, and slot noteKind for the Watch tooltip. View renders these.
local function StampRowTipPresentation(row)
    if type(row) ~= "table" then
        return
    end
    row.statusKind = tostring(row.statusKey or "")
    local recipe = row.recipe or row.specRecipe
    local uid = tonumber(row.uniqueID) or 0
    local yield = tonumber(row.recipeYield) or 0
    local observed = 0
    local RS = RecipeSpec()
    if type(recipe) == "table" and RS then
        if RS.StableCraftYield then
            local stable = tonumber(RS.StableCraftYield(recipe, uid)) or 0
            if stable >= 1 then
                yield = stable
            end
        end
        if yield <= 0 then
            yield = tonumber(recipe.recipeYield) or 0
        end
        if RS.RecipeOutputYield then
            observed = tonumber(RS.RecipeOutputYield(recipe, uid)) or 0
        end
    end
    row.tipYield = RoundTipYield(yield)
    row.tipObservedYield = tonumber(observed) or 0
    row.tipDeficit = tonumber(row.potionDeficit) or 0
    row.tipCraftsNeeded = tonumber(row.craftsNeeded) or 0
    local tips = row.statusTipSlots
    if type(tips) ~= "table" then
        return
    end
    for i = 1, #tips do
        local entry = tips[i]
        if type(entry) == "table" then
            local kind = entry.noteKind
            if kind ~= "shared" and kind ~= "pooled" then
                local note = string.lower(tostring(entry.note or ""))
                if note == "(shared)" or note == "shared" then
                    entry.noteKind = "shared"
                elseif note == "(pooled)" or note == "pooled" then
                    entry.noteKind = "pooled"
                elseif entry.growingNotes ~= nil and entry.growingNotes ~= L"" then
                    entry.noteKind = ClassifyGrowingNote(entry.growingNotes)
                end
            end
        end
    end
end

local function StampPlanTipPresentation(plan)
    local rows = type(plan) == "table" and plan.rows or nil
    if type(rows) ~= "table" then
        return
    end
    for i = 1, #rows do
        StampRowTipPresentation(rows[i])
    end
end

--- All growable seed UIDs for this watch (recipe slots + tip). Shared mats across
--- watches must appear here so a short cushion demotes every sharing row.
--- Hot path: tip / prior stamp first; ResolveSeedForSpec only on cold miss.
StampRowSeedBufferUids = function(row)
    if type(row) ~= "table" then
        return
    end
    local snapGen = CurrentSnapGen()
    local prior = row.seedBufferSeedUids
    local priorPlants = row.seedBufferPlantUids
    -- Seeds alone OR plants alone are enough to skip restamp. Requiring both
    -- tables (0.3.348) forced FindPlantUid storms when plantUids was still nil.
    local priorSeedN = type(prior) == "table" and #prior or 0
    local priorPlantN = type(priorPlants) == "table" and #priorPlants or 0
    if (priorSeedN > 0 or priorPlantN > 0)
        and snapGen > 0
        and tonumber(row._seedBufferUidSnapGen) == snapGen
    then
        if type(row.seedBufferPlantUids) ~= "table" then
            row.seedBufferPlantUids = {}
        end
        return
    end
    local uids = {}
    local plantUids = {}
    local seen = {}
    local seenPlant = {}
    local function add(uid)
        uid = tonumber(uid) or 0
        if uid > 0 and seen[uid] ~= true then
            seen[uid] = true
            uids[#uids + 1] = uid
        end
    end
    local function addPlant(uid)
        uid = tonumber(uid) or 0
        if uid > 0 and seenPlant[uid] ~= true and seen[uid] ~= true then
            seenPlant[uid] = true
            plantUids[#plantUids + 1] = uid
        end
    end
    -- Prefer plan tip seed/plant uids (already resolved during status tip build).
    local tips = row.statusTipSlots
    if type(tips) == "table" then
        for i = 1, #tips do
            local tip = tips[i]
            if type(tip) == "table" then
                local sUid = tonumber(tip.seedUid) or 0
                local pUid = tonumber(tip.plantUid) or 0
                if sUid > 0 then
                    add(sUid)
                elseif pUid > 0 then
                    -- Orphan high plant (Savage s0): cushion is plant stock.
                    addPlant(pUid)
                end
            end
        end
    end
    -- Cold miss: tip plantUid / bound spec uid only - never FindPlantUidForSpec
    -- (full bag/Items ProductMatches walk) on the Watch status hot path.
    if #uids == 0 and #plantUids == 0 then
        local RS = RecipeSpec()
        local SM = StockPiler.SeedMap
        local recipe = row.recipe or row.specRecipe
        if type(recipe) == "table" and SM and SM.IsGrowableSpec then
            if RS and RS.HydrateRecipeSlots then
                RS.HydrateRecipeSlots(recipe)
            end
            local slots = recipe.slots or {}
            for i = 1, #slots do
                local slot = slots[i]
                local spec = ResolveSlotSpec(slot)
                if type(spec) == "table" and SM.IsGrowableSpec(spec) == true then
                    if not (SM.IsOneWayHarvestSpec and SM.IsOneWayHarvestSpec(spec) == true) then
                        local seedUid = 0
                        if SM.ResolveSeedForSpec then
                            local seed = SM.ResolveSeedForSpec(spec)
                            if type(seed) == "table" then
                                seedUid = tonumber(seed.uniqueID or seed.uid) or 0
                                if seedUid <= 0 then
                                    local pFromSeed = tonumber(seed.plantUid) or 0
                                    if pFromSeed > 0 then
                                        addPlant(pFromSeed)
                                    end
                                end
                            end
                        end
                        if seedUid > 0 then
                            add(seedUid)
                        else
                            local plantUid = tonumber(spec.uid) or tonumber(spec.uniqueID)
                                or tonumber(spec.boundUid) or 0
                            addPlant(plantUid)
                        end
                    end
                end
            end
        end
    elseif #plantUids == 0 and type(tips) == "table" then
        -- Tips already gave seeds; still pick up plant-only stimulant tips.
        for i = 1, #tips do
            local tip = tips[i]
            if type(tip) == "table" then
                local sUid = tonumber(tip.seedUid) or 0
                local pUid = tonumber(tip.plantUid) or 0
                if sUid <= 0 and pUid > 0 then
                    addPlant(pUid)
                end
            end
        end
    end
    row.seedBufferSeedUids = uids
    row.seedBufferPlantUids = plantUids
    row._seedBufferUidSnapGen = snapGen
end

local function SeedBufferShort(recipe, potionKey, row)
    local RS = RecipeSpec()
    if type(recipe) ~= "table" then
        return false
    end
    if not WatchWantsAutoGrow(potionKey, nil) then
        return false
    end
    local Watch = StockPiler.Watch
    if not (Watch and Watch.IsSeedBufferEnabled and Watch.IsSeedBufferEnabled() == true) then
        return false
    end
    -- Stocked watches still enforce buffer (protect seed lines from exhaustion).
    if RS and RS.WatchHasSeedBufferShort then
        if type(row) == "table" then
            local snapGen = CurrentSnapGen()
            local prior = row.seedBufferSeedUids
            local priorPlants = row.seedBufferPlantUids
            local stamped = snapGen > 0
                and tonumber(row._seedBufferUidSnapGen) == snapGen
                and (
                    (type(prior) == "table" and #prior > 0)
                    or (type(priorPlants) == "table" and #priorPlants > 0)
                )
            if not stamped then
                StampRowSeedBufferUids(row)
            end
        end
        local seedUids = type(row) == "table" and row.seedBufferSeedUids or nil
        local plantUids = type(row) == "table" and row.seedBufferPlantUids or nil
        return RS.WatchHasSeedBufferShort(recipe, {
            seedUids = seedUids,
            plantUids = plantUids,
        }) == true
    end
    return false
end

--- If any seed cushion is short, stamp seedBufferShort on every AutoGrow watch that
--- uses that seed. Only demote Ready / Stocked -> Seed buffer - never overwrite Buy
--- flasks/seeds/materials when bags are the real blocker.
local function PropagateSharedSeedBufferStatus(rows)
    if type(rows) ~= "table" or #rows == 0 then
        return false
    end
    local Watch = StockPiler.Watch
    if not (Watch and Watch.IsSeedBufferEnabled and Watch.IsSeedBufferEnabled() == true) then
        return false
    end
    local buffer = Watch.GetSeedBufferMin and tonumber(Watch.GetSeedBufferMin()) or 5
    local Refine = StockPiler.Refine
    local shortUids = {}
    local anyShort = false
    for i = 1, #rows do
        local row = rows[i]
        if type(row) == "table" then
            local pk = row.potionKey or row.potionRecipeKey or row.id
            if WatchWantsAutoGrow(pk, nil) then
                StampRowSeedBufferUids(row)
                local uids = row.seedBufferSeedUids
                if type(uids) == "table" then
                    for u = 1, #uids do
                        local uid = tonumber(uids[u]) or 0
                        if uid > 0 and shortUids[uid] == nil then
                            local credit = 0
                            if Refine and Refine.GetSeedBudget then
                                local budget = Refine.GetSeedBudget(uid)
                                credit = tonumber(budget and budget.credit) or 0
                            else
                                local Inv = StockPiler.Inventory
                                credit = Inv and Inv.CountByUid and tonumber(Inv.CountByUid(uid)) or 0
                            end
                            if credit < buffer then
                                shortUids[uid] = true
                                anyShort = true
                            else
                                shortUids[uid] = false
                            end
                        end
                    end
                end
                local pUids = row.seedBufferPlantUids
                if type(pUids) == "table" then
                    local Inv = StockPiler.Inventory
                    for u = 1, #pUids do
                        local uid = tonumber(pUids[u]) or 0
                        if uid > 0 and shortUids[uid] == nil then
                            local credit = Inv and Inv.CountByUid and tonumber(Inv.CountByUid(uid)) or 0
                            if credit < buffer then
                                shortUids[uid] = true
                                anyShort = true
                            else
                                shortUids[uid] = false
                            end
                        end
                    end
                end
            end
        end
    end
    if not anyShort then
        return false
    end
    local changed = false
    for i = 1, #rows do
        local row = rows[i]
        if type(row) == "table" then
            local pk = row.potionKey or row.potionRecipeKey or row.id
            if WatchWantsAutoGrow(pk, nil) then
                local uids = row.seedBufferSeedUids
                local hit = false
                if type(uids) == "table" then
                    for u = 1, #uids do
                        if shortUids[tonumber(uids[u]) or 0] == true then
                            hit = true
                            break
                        end
                    end
                end
                if not hit then
                    local pUids = row.seedBufferPlantUids
                    if type(pUids) == "table" then
                        for u = 1, #pUids do
                            if shortUids[tonumber(pUids[u]) or 0] == true then
                                hit = true
                                break
                            end
                        end
                    end
                end
                if hit then
                    row.seedBufferShort = true
                    row.craftableSafe = false
                    local prev = tostring(row.statusKey or "")
                    -- Ready/stocked only: buffer gates brew, not buy shortages.
                    if prev == "ready_to_craft"
                        or prev == "ready_to_craft_shared"
                        or prev == "potion_stocked"
                    then
                        ApplySeedBufferStatus(row)
                        changed = true
                    end
                end
            end
        end
    end
    return changed
end

--- Green craftable means Ready to Brew: the count covers the target, the seed
--- buffer is met, and the mats are not shared. Anything else with a count is yellow.
local function StampCraftableSafety(row)
    if type(row) ~= "table" then
        return
    end
    local pk = row.potionKey or row.potionRecipeKey or row.id
    local short = SeedBufferShort(row.recipe or row.specRecipe, pk, row) == true
    row.seedBufferShort = short
    local craftable = tonumber(row.craftable) or 0
    local have = tonumber(row.potionHave) or 0
    local target = tonumber(row.potionMin) or tonumber(row.target) or 0
    local covers = target > 0 and (have + craftable) >= target
    local key = tostring(row.statusKey or "")
    local shared = row.craftableShared == true or key == "ready_to_craft_shared"
    local ready = key == "ready_to_craft" and covers and not shared and not short
    -- Target already met. Still green when a brew would be safe.
    local stocked = key == "potion_stocked" and not shared and not short
    row.craftableSafe = craftable > 0 and (ready or stocked)
end

local function ApplyNeedApothecaryStatus(row)
    if row.statusKey ~= "ready_to_craft" and row.statusKey ~= "ready_to_craft_shared" then
        return
    end
    if not CanBrewPotionsSkill() then
        row.statusKey = "need_apothecary"
        row.statusText = T("plan.status.need_apothecary")
    end
end

local function ApplyNeedSkillStatus(row)
    local RS = RecipeSpec()
    if not RS or not RS.RecipeSkillRequirements then
        return
    end
    if row.statusKey ~= "ready_to_craft" and row.statusKey ~= "ready_to_craft_shared" then
        return
    end
    local req = RS.RecipeSkillRequirements(row.recipe)
    if type(req) ~= "table" then
        return
    end
    local Caps = StockPiler.TradeSkillCaps
    local apo = Caps and Caps.GetApoSkill and Caps.GetApoSkill() or 0
    local need = tonumber(req.apothecary) or tonumber(req.apo) or 0
    if need > 0 and apo < need then
        row.statusKey = "need_skill"
        row.statusText = T("plan.status.need_skill")
    end
end

local function ApplyReadyStatus(row)
    local pk = RowWatchKey(row)
    -- With Cultivation: covered but AutoGrow off -> Enable AutoGrow (not Ready).
    -- Apo-only: Ready whenever bags cover the craft (manual + AutoBrew).
    if CanAutoGrowSkill() and not WatchWantsAutoGrow(pk, nil) then
        row.statusKey = "enable_autogrow"
        row.statusText = T("plan.status.enable_autogrow")
        row.craftableShared = false
        row.statusLines = nil
        return
    end
    row.statusKey = "ready_to_craft"
    row.statusText = T("plan.status.ready_to_craft")
    row.craftableShared = false
    if CanBrewPotionsSkill() then
        row.statusLines = { T("brew.ready", { name = row.name or T("brew.potion_fallback") }) }
    else
        row.statusLines = { T("brew.requires_apo") }
    end
end

--- True when this recipe's apothecary requirement is above the live skill.
local function SkillBlocksRow(row)
    local RS = RecipeSpec()
    if not RS or not RS.RecipeSkillRequirements or type(row) ~= "table" then
        return false
    end
    local req = RS.RecipeSkillRequirements(row.recipe)
    if type(req) ~= "table" then
        return false
    end
    local need = tonumber(req.apothecary) or tonumber(req.apo) or 0
    if need <= 0 then
        return false
    end
    local Caps = StockPiler.TradeSkillCaps
    local apo = Caps and Caps.GetApoSkill and Caps.GetApoSkill() or 0
    return apo < need
end

local function RowCoveredForSkillGate(row)
    local have = tonumber(row.potionHave) or 0
    local craftable = tonumber(row.craftable) or 0
    local target = tonumber(row.potionMin) or tonumber(row.target) or 0
    local deficit = tonumber(row.potionDeficit)
    if deficit == nil then
        deficit = math.max(0, target - have)
    end
    return target > 0 and deficit > 0 and (have + craftable) >= target
end

--- Re-apply need_skill / need_apothecary on one cached row.
--- A skill point that does not cross a watched requirement leaves the row alone.
local function RefreshRowSkillGate(row)
    if type(row) ~= "table" or row.skillUp == true or row.addonOwned == true
        or row.kind == "plant" or row.isPlantWatch == true
    then
        return false
    end
    local key = tostring(row.statusKey or "")
    local gate = key == "ready_to_craft" or key == "ready_to_craft_shared"
        or key == "need_skill" or key == "need_apothecary"
    if not gate or not RowCoveredForSkillGate(row) then
        return false
    end
    local prev = key
    local blocks = SkillBlocksRow(row)
    local canBrew = CanBrewPotionsSkill()
    if key == "need_skill" and not blocks then
        ApplyReadyStatus(row)
        if not canBrew then
            ApplyNeedApothecaryStatus(row)
        end
    elseif key == "need_apothecary" and canBrew then
        ApplyReadyStatus(row)
        ApplyNeedSkillStatus(row)
    elseif (key == "ready_to_craft" or key == "ready_to_craft_shared")
        and (blocks or not canBrew)
    then
        if not canBrew then
            ApplyNeedApothecaryStatus(row)
        end
        if blocks then
            ApplyNeedSkillStatus(row)
        end
    end
    return tostring(row.statusKey or "") ~= prev
end

--- Cheap status pass. Does not BuildFull. Unrelated +1 skill points no-op.
function Planner.RefreshSkillGateStatuses()
    local PS = StockPiler.PlanSnapshot
    local plan = PS and PS.Get and PS.Get()
    local rows = type(plan) == "table" and plan.rows or nil
    if type(rows) ~= "table" then
        return false
    end
    local changed = false
    for i = 1, #rows do
        if RefreshRowSkillGate(rows[i]) then
            changed = true
        end
    end
    if changed then
        InvalidateFocusCaches("skill-gate")
        local Brew = StockPiler.Brew
        if Brew and Brew.InvalidateCanBrewCache then
            Brew.InvalidateCanBrewCache()
        end
    end
    return changed
end

local function ApplyStockedStatus(row)
    row.statusKey = "potion_stocked"
    row.statusText = T("plan.status.potion_stocked")
    row.statusLines = { T("watch.note.stocked") }
    row.craftableShared = false
end

--- Craft bag too tight for brew load (need a free slot to pull inventory mats).
--- Potion products land in the main bag - do not reserve craft space for output.
--- Cache by snap + live free count so freeing slots is not stuck on an old snap.
local function IsCraftBagFullCached()
    local Inv = StockPiler.Inventory
    local snap = Inv and Inv.GetSnapGen and tonumber(Inv.GetSnapGen()) or 0
    local BA = StockPiler.BagAdapter
    local fetchGen = BA and BA.GetCraftFetchGen and tonumber(BA.GetCraftFetchGen()) or 0
    if snap > 0 and Planner._craftBagFullSnap == snap
        and Planner._craftBagFetchGen == fetchGen
        and Planner._craftBagFull ~= nil
    then
        return Planner._craftBagFull == true
    end
    local free = BA and BA.CraftBagFreeSlots and tonumber(BA.CraftBagFreeSlots()) or nil
    local full = BA and BA.IsCraftBagFull and BA.IsCraftBagFull() == true
    if full ~= true and free ~= nil and free < 1 then
        full = true
    end
    Planner._craftBagFullSnap = snap
    Planner._craftBagFetchGen = fetchGen
    Planner._craftBagFreeCached = free
    Planner._craftBagFull = full
    return full
end

local function ApplyCraftBagFullStatus(row)
    row.statusKey = "craft_bag_full"
    row.statusText = T("plan.status.craft_bag_full")
    row.statusLines = { T("watch.note.craft_bag_full") }
    row.craftableShared = false
end

local function ApplySpecPlanStatus(row, target, recipe, demand)
    row.statusLines = nil
    row.statusTipSlots = nil
    row.statusSlots = nil
    if (tonumber(target.min) or 0) <= 0 then
        row.statusKey = "no_target"
        row.statusText = T("plan.status.no_target")
        return
    end
    if recipe == nil then
        row.statusKey = "no_recipe"
        row.statusText = T("plan.status.no_recipe")
        return
    end
    if (tonumber(target.deficit) or 0) <= 0 then
        -- At/above potion target: Seed buffer until cushion is met, else Potions stocked.
        if SeedBufferShort(recipe, target.potionKey, row) then
            ApplySeedBufferStatus(row)
        else
            ApplyStockedStatus(row)
        end
        return
    end
    local outUid = tonumber(target.uniqueID) or 0
    local craftsNeeded = CraftsNeededForDeficit(target.deficit, recipe, outUid)
    row.craftsNeeded = craftsNeeded
    row.recipeYield = RecipeYield(recipe, outUid)

    local craftable = CountPotionsCraftable(recipe, outUid)
    local covered = (tonumber(target.have) or 0) + craftable >= (tonumber(target.min) or 0)
    if covered then
        if SeedBufferShort(recipe, target.potionKey, row) then
            ApplySeedBufferStatus(row)
            return
        end
        -- Bags cover the brew but craft bag is too tight to load from inventory.
        if IsCraftBagFullCached() then
            ApplyCraftBagFullStatus(row)
            return
        end
        ApplyReadyStatus(row)
        return
    end

    local slots = recipe.slots or {}
    local allEntries = {}
    local limiting, containerShort, vendorShort, byproductShort
    local plantShort, convertShort, buyShort = {}, {}, {}
    for i = 1, #slots do
        local entry = RecipeSlotPlanEntry(slots[i], slots, craftsNeeded, demand)
        if entry ~= nil then
            allEntries[#allEntries + 1] = entry
            if entry.deficit > 0 then
                if entry.kind == "buy" and entry.role == "container" then
                    containerShort = entry
                    buyShort[#buyShort + 1] = entry
                elseif entry.kind == "convert" then
                    byproductShort = byproductShort or entry
                    convertShort[#convertShort + 1] = entry
                elseif entry.kind == "plant" then
                    limiting = limiting or entry
                    plantShort[#plantShort + 1] = entry
                else
                    vendorShort = vendorShort or entry
                    buyShort[#buyShort + 1] = entry
                end
            end
        end
    end
    row.statusTipSlots = allEntries
    StampRowSeedBufferUids(row)

    -- Ready only when have+craftable covers target (see covered early-return above).
    -- Partial craftable with bottleGap>0 -> Restocking / Buy, so AutoGrow can fill first.

    -- Prefer Refine / Seed buffer over Buy seeds when refinable plants remain.
    -- Seed buffer status only when buffer is actually short for this watch (has seed lines).
    if limiting ~= nil and limiting.needsRefine == true then
        if SeedBufferShort(recipe, target.potionKey, row) then
            ApplySeedBufferStatus(row)
        else
            SetMaterialsShortStatus(row, true, T("plan.status.buy_ingredients"))
        end
        row.specDeficit = limiting
        return
    end
    if limiting ~= nil then
        row.specDeficit = limiting
        local buyLabel = T("plan.status.buy_ingredients")
        if limiting.buySeedOrMat == true and (tonumber(limiting.seedUid) or 0) > 0 then
            buyLabel = T("watch.note.buy_seeds")
        end
        -- Plant short is growable: master off -> Enable AutoGrow, master on -> Restocking.
        SetMaterialsShortStatus(row, true, buyLabel)
        return
    end
    if byproductShort ~= nil then
        -- Byproduct short with no plant feedstock -> red buy, not yellow restocking.
        local hasFeedstock = false
        for i = 1, #allEntries do
            local e = allEntries[i]
            if type(e) == "table" and e.kind == "plant" and (tonumber(e.have) or 0) > 0 then
                hasFeedstock = true
                break
            end
        end
        if hasFeedstock then
            SetMaterialsShortStatus(row, true, T("plan.status.buy_ingredients"))
        else
            row.statusKey = "buy_ingredients"
            row.statusText = T("plan.status.buy_ingredients")
        end
        row.specDeficit = byproductShort
        return
    end
    -- Seed buffer before container/vendor buy paint (matches DemoteToMaterialsShort).
    -- Otherwise Publish paints Buy flasks then live patch flips to Seed buffer - stall chat lies.
    if SeedBufferShort(recipe, target.potionKey, row) then
        ApplySeedBufferStatus(row)
        return
    end
    -- Vendor / flask buy shorts (craftable==0): list every distinct buy note.
    -- Container alone used to paint Buy flasks and skip materials that were also short.
    local wantFlasks = containerShort ~= nil
    local wantSeeds = false
    local wantMats = false
    for i = 1, #buyShort do
        local flasks, seeds, mats = BuyNoteFlagsFromEntry(buyShort[i])
        wantFlasks = wantFlasks or flasks
        wantSeeds = wantSeeds or seeds
        wantMats = wantMats or mats
    end
    if wantFlasks or wantSeeds or wantMats then
        row.statusKey = "buy_ingredients"
        row.statusText = ComposeBuyStatusText({
            flasks = wantFlasks,
            seeds = wantSeeds,
            materials = wantMats,
        })
        row.specDeficit = containerShort or vendorShort or buyShort[1]
        return
    end
    -- Tip slots look covered (raw Have) but craftable may still be 0 under grow reserve,
    -- or partial craftable remains with bottleGap>0 (not Ready until covered).
    -- Craft bag full: no room for brew output / harvest - do not paint Restocking.
    if IsCraftBagFullCached() then
        ApplyCraftBagFullStatus(row)
        return
    end
    -- Growable short / partial craftable: gate on skill only; master toggle picks Enable vs Restocking.
    if CanAutoGrowSkill() then
        SetMaterialsShortStatus(row, true, nil)
        row.specDeficit = row.specDeficit or limiting or byproductShort or containerShort or vendorShort
        return
    end
    row.statusKey = "buy_ingredients"
    row.statusText = T("plan.status.buy_ingredients")
    row.specDeficit = row.specDeficit or containerShort or limiting or byproductShort or vendorShort
end

local function ApplyLiveWatchStatus(row, recipe, deficit, have, craftable, target)
    local key = tostring(row.statusKey or "")
    local potionKey = RowWatchKey(row)
    -- Heal stale Learn recipe when bags/recipe resolve again after brew learn/scrub.
    if key == "no_recipe" and type(recipe) == "table" then
        ApplySpecPlanStatus(row, {
            min = target,
            deficit = deficit,
            have = have,
            potionKey = potionKey,
            entry = row,
        }, recipe, Planner._lastDemand)
        key = tostring(row.statusKey or "")
    end
    local flippable = key == "ready_to_craft"
        or key == "ready_to_craft_shared"
        or key == "potion_stocked"
        or key == "need_seeds"
        or key == "upgrading_seed"
        or key == "restocking"
        or key == "craft_bag_full"
        or key == "buy_ingredients"
        or key == "enable_autogrow"
        or key == "need_skill"
        or key == "need_apothecary"
    if not flippable then
        return
    end

    local function LiveSlotHave(spec, role, slot)
        local count = CountItemsMatchingSpec(spec, { cacheOnly = true })
        if count ~= nil then
            return count
        end
        -- Cold path: ProductMatches / RS count (never uid-only for complete containers).
        return CountItemsMatchingSpec(spec)
    end

    local function DemoteToMaterialsShort()
        if SeedBufferShort(recipe, potionKey, row) then
            ApplySeedBufferStatus(row)
            return
        end
        local slots = type(recipe) == "table" and recipe.slots or nil
        local craftsNeeded = tonumber(row.craftsNeeded) or 0
        if craftsNeeded <= 0 and deficit > 0 then
            craftsNeeded = CraftsNeededForDeficit(deficit, recipe, tonumber(row.uniqueID) or 0)
        end
        if craftsNeeded < 1 then
            craftsNeeded = 1
        end
        local growableShort, containerShort, buyShort, anyGrowable = false, false, false, false
        if type(slots) == "table" then
            for i = 1, #slots do
                local slot = slots[i]
                local spec = ResolveSlotSpec(slot)
                if type(spec) == "table" then
                    local role = slot.role
                    local need = craftsNeeded * EffectivePerCraft(slot, slots)
                    local slotHave = LiveSlotHave(spec, role, slot)
                    if SpecCanAutoGrowProgress(spec, role) then
                        anyGrowable = true
                        if slotHave ~= nil and slotHave < need then
                            growableShort = true
                        end
                    elseif role == "container" then
                        if slotHave ~= nil and slotHave < need then
                            containerShort = true
                        end
                    else
                        if slotHave ~= nil and slotHave < need then
                            buyShort = true
                        end
                    end
                end
            end
        end
        if growableShort then
            SetMaterialsShortStatus(row, true, nil)
            row.craftableShared = false
            return
        end
        if containerShort or buyShort then
            row.statusKey = "buy_ingredients"
            row.statusText = ComposeBuyStatusText({
                flasks = containerShort == true,
                materials = buyShort == true,
            })
            row.statusLines = nil
            row.craftableShared = false
            return
        end
        -- Tips look covered but craftable is still 0: craft bag full beats Restocking.
        -- (Expected craftable 0 with mats in bag = watched outcome never drops on
        -- this fingerprint; AutoBrew also requires craftable > 0.)
        if IsCraftBagFullCached() then
            ApplyCraftBagFullStatus(row)
            return
        end
        if anyGrowable then
            SetMaterialsShortStatus(row, true, nil)
        else
            row.statusKey = "buy_ingredients"
            row.statusText = T("plan.status.buy_ingredients")
            row.statusLines = nil
        end
        row.craftableShared = false
    end

    if deficit <= 0 then
        if SeedBufferShort(recipe, potionKey, row) then
            -- Always re-apply so need_seeds <-> upgrading_seed text stays live.
            ApplySeedBufferStatus(row)
        elseif key ~= "potion_stocked" then
            ApplyStockedStatus(row)
        end
        return
    end

    local covered = target > 0 and (have + (tonumber(craftable) or 0)) >= target
    if covered then
        if SeedBufferShort(recipe, potionKey, row) then
            ApplySeedBufferStatus(row)
        elseif key == "buy_ingredients" and row.craftableShared == true then
            -- Shared buy-only paint; PolishSharedContest refreshes flasks vs Ready.
            return
        elseif IsCraftBagFullCached() then
            ApplyCraftBagFullStatus(row)
        else
            ApplyReadyStatus(row)
            ApplyNeedApothecaryStatus(row)
            ApplyNeedSkillStatus(row)
        end
        return
    end

    if key == "ready_to_craft" or key == "ready_to_craft_shared"
        or key == "potion_stocked" or key == "buy_ingredients"
        or key == "restocking"
        or key == "craft_bag_full"
        or key == "enable_autogrow"
        or key == "need_skill"
        or key == "need_apothecary"
    then
        -- Uncovered target: never Ready (partial craftable waits for AutoGrow / buy).
        -- Seed buffer only gates Ready/stocked - buy shortages keep Buy flasks/seeds.
        if SeedBufferShort(recipe, potionKey, row)
            and (key == "ready_to_craft" or key == "ready_to_craft_shared" or key == "potion_stocked")
        then
            ApplySeedBufferStatus(row)
        else
            DemoteToMaterialsShort()
        end
        return
    end
    -- Seed buffer / climb cleared (or AutoGrow off so SeedBufferShort is false):
    -- leave need_seeds / upgrading_seed via materials / Ready / Buy paths.
    if (key == "need_seeds" or key == "upgrading_seed") and not SeedBufferShort(recipe, potionKey, row) then
        DemoteToMaterialsShort()
        return
    end
    -- Buffer still short: always re-apply so need_seeds <-> upgrading_seed stays live.
    if (key == "need_seeds" or key == "upgrading_seed") and SeedBufferShort(recipe, potionKey, row) then
        ApplySeedBufferStatus(row)
        return
    end
    -- Restocking + buffer short: only flip to Seed buffer when grow path exists
    -- (not when tip is Buy seeds / Buy flasks).
    if key == "restocking" and SeedBufferShort(recipe, potionKey, row) then
        local tips = row.statusTipSlots
        local hardBuy = false
        if type(tips) == "table" then
            for i = 1, #tips do
                local e = tips[i]
                if type(e) == "table" and (tonumber(e.deficit) or 0) > 0 then
                    if e.kind == "buy"
                        or (e.kind == "plant" and e.buySeedOrMat == true and e.needsRefine ~= true)
                    then
                        hardBuy = true
                        break
                    end
                end
            end
        end
        if not hardBuy then
            ApplySeedBufferStatus(row)
        end
    end
end

----------------------------------------------------------------
-- Seed-buffer tip (PeekCachedIntents only - never CollectIntents)
----------------------------------------------------------------

local function BuildSeedBufferTipData(opts)
    opts = type(opts) == "table" and opts or {}
    local previous = type(opts.previous) == "table" and opts.previous or nil
    local Watch = StockPiler.Watch
    local buffer = Watch and Watch.GetSeedBufferMin and Watch.GetSeedBufferMin() or 5
    local enabled = Watch and Watch.IsSeedBufferEnabled and Watch.IsSeedBufferEnabled() == true
    local rows = {}
    local RS = RecipeSpec()
    local lines = {}
    if RS and RS.CollectAutoGrowSeedLines then
        lines = RS.CollectAutoGrowSeedLines() or {}
    elseif Planner.CollectAutoGrowSeedLines then
        lines = Planner.CollectAutoGrowSeedLines() or {}
    end
    local byKey = {}
    for i = 1, #lines do
        local line = lines[i]
        local spec = line and line.spec
        if type(spec) == "table" then
            local seedUid = tonumber(line.seedUid) or 0
            local specKey = tostring(line.specKey or SpecKey(spec) or seedUid or i)
            if byKey[specKey] == nil then
                local live, ground, planned, credit = 0, 0, 0, 0
                local plantUid = tonumber(line.plantUid) or 0
                local Refine = StockPiler.Refine
                if seedUid > 0 and Refine and Refine.GetSeedBudgetForSpec then
                    local budget = Refine.GetSeedBudgetForSpec(spec, seedUid)
                    live = tonumber(budget and budget.live) or 0
                    ground = tonumber(budget and budget.ground) or 0
                    planned = tonumber(budget and budget.outstanding) or 0
                    credit = tonumber(budget and budget.credit) or (live + ground + planned)
                else
                    local Inv = StockPiler.Inventory
                    if seedUid > 0 and Inv and Inv.CountByUid then
                        live = tonumber(Inv.CountByUid(seedUid)) or 0
                        credit = live
                    elseif seedUid <= 0 and plantUid > 0 and Inv and Inv.CountByUid then
                        -- Plant-only cushion credit (Savage Marshroot s0).
                        live = tonumber(Inv.CountByUid(plantUid)) or 0
                        credit = live
                    end
                end
                local rec = {
                    key = specKey,
                    spec = spec,
                    seedUid = seedUid,
                    plantUid = plantUid,
                    plantOnly = seedUid <= 0 and plantUid > 0,
                    live = live,
                    ground = ground,
                    planned = planned,
                    total = credit,
                    shortBy = math.max(0, (tonumber(buffer) or 0) - credit),
                }
                byKey[specKey] = rec
                rows[#rows + 1] = rec
            end
        end
    end
    local intents = nil
    local Refine = StockPiler.Refine
    local Grow = StockPiler.Grow
    if Refine and Refine.PeekCachedIntents then
        intents = Refine.PeekCachedIntents()
    elseif Grow and Grow.PeekCachedIntents then
        intents = Grow.PeekCachedIntents()
    end
    if type(intents) ~= "table" then
        if previous ~= nil and type(previous.intents) == "table" then
            return {
                buffer = tonumber(buffer) or 5,
                enabled = enabled,
                watched = rows,
                intents = previous.intents,
            }
        end
        intents = {}
    end
    return {
        buffer = tonumber(buffer) or 5,
        enabled = enabled,
        watched = rows,
        intents = intents,
    }
end

----------------------------------------------------------------
-- Watch targets + rows
----------------------------------------------------------------

local function BuildWatchedTargets(ctx, watches)
    local targets = {}
    local RS = RecipeSpec()
    if type(watches) ~= "table" then
        watches = {}
    end
    for watchKey, watch in pairs(watches) do
        if type(watch) == "table" and watch.enabled == true then
            local resolved = ResolveWatchPotion(watchKey)
            local potion = resolved and resolved.potion
            local outputUid = 0
            local name = towstring(tostring(watchKey))
            local iconNum = 0
            local recipeSpecKey = resolved and resolved.recipeSpecKey
            if type(potion) == "table" then
                outputUid = tonumber(resolved and resolved.outputUid) or tonumber(potion.outputUid) or 0
                name = potion.name or name
                iconNum = tonumber(potion.iconNum) or 0
            else
                -- Always parse uid from key so missing ResolveWatchPotion cannot drop watches.
                local uidMatch = string.match(tostring(watchKey), "^uid:(%d+)")
                outputUid = tonumber(uidMatch) or 0
                local rkMatch = string.match(tostring(watchKey), "|rk:(.+)$")
                if type(rkMatch) == "string" and rkMatch ~= "" then
                    recipeSpecKey = recipeSpecKey or rkMatch
                end
            end
            if type(potion) == "table" or outputUid > 0 then
                local have = PotionHave(resolved, potion, outputUid)
                local min = tonumber(watch.targetStock) or 0
                targets[#targets + 1] = {
                    id = watchKey,
                    potionKey = watchKey,
                    potionBaseKey = (resolved and resolved.potionKey) or ("uid:" .. tostring(outputUid)),
                    recipeSpecKey = recipeSpecKey,
                    entry = potion,
                    uniqueID = outputUid,
                    name = name,
                    iconNum = iconNum,
                    have = have,
                    min = min,
                    deficit = math.max(0, min - have),
                    autoGrow = watch.autoGrow == true,
                    priorityTier = (StockPiler.Watch and StockPiler.Watch.GetPriorityTier
                        and StockPiler.Watch.GetPriorityTier(watchKey))
                        or tonumber(watch.priorityTier) or 1,
                }
            end
        end
    end
    table.sort(targets, function(a, b)
        local ta = tonumber(a.priorityTier) or 1
        local tb = tonumber(b.priorityTier) or 1
        if ta ~= tb then
            return ta < tb
        end
        local na, nb = ToNarrow(a.name), ToNarrow(b.name)
        if na ~= nb then
            return na < nb
        end
        return tostring(a.potionKey) < tostring(b.potionKey)
    end)
    return targets
end

local function StampRowCraftMatIndex(row)
    if type(row) ~= "table" then
        return
    end
    local uids = {}
    local keys = {}
    local outUid = tonumber(row.uniqueID) or 0
    if outUid > 0 then
        uids[outUid] = true
    end
    local recipe = row.recipe or row.specRecipe
    if type(recipe) == "table" then
        local slots = recipe.slots or {}
        local MS = MaterialSpec()
        for i = 1, #slots do
            local spec = ResolveSlotSpec(slots[i])
            if type(spec) == "table" then
                local bound = SpecBoundUid(spec)
                if bound <= 0 then
                    bound = tonumber(spec.uid) or tonumber(spec.uniqueID) or 0
                end
                if bound > 0 then
                    uids[bound] = true
                end
                local sk = SpecKey(spec)
                if type(sk) == "string" and sk ~= "" then
                    keys[sk] = true
                end
                if MS and MS.ProductKey then
                    local pk = MS.ProductKey(spec)
                    if type(pk) == "string" and pk ~= "" then
                        keys[pk] = true
                    end
                end
            end
        end
    end
    row._craftMatUids = uids
    row._craftMatKeys = keys
end

--- Resolve last net uid delta into touch sets. unresolved=true -> full craftable recount.
local function BuildDeltaTouchSets(delta)
    local uids = {}
    local keys = {}
    local unresolved = false
    if type(delta) ~= "table" then
        return uids, keys, true
    end
    local Inv = StockPiler.Inventory
    local MS = MaterialSpec()
    local any = false
    for uid, _ in pairs(delta) do
        uid = tonumber(uid) or 0
        if uid > 0 then
            any = true
            uids[uid] = true
            local sample = Inv and Inv.GetSample and Inv.GetSample(uid)
            if type(sample) ~= "table" then
                unresolved = true
            else
                local matched = false
                if MS and MS.FromItemDataCached then
                    local itemSpec = MS.FromItemDataCached(sample)
                    if type(itemSpec) == "table" then
                        local sk = SpecKey(itemSpec)
                        if type(sk) == "string" and sk ~= "" then
                            keys[sk] = true
                            matched = true
                        end
                        if MS.ProductKey then
                            local pk = MS.ProductKey(itemSpec)
                            if type(pk) == "string" and pk ~= "" then
                                keys[pk] = true
                                matched = true
                            end
                        end
                    end
                elseif MS and MS.ProductKey then
                    local pk = MS.ProductKey(sample)
                    if type(pk) == "string" and pk ~= "" then
                        keys[pk] = true
                        matched = true
                    end
                end
                if not matched then
                    unresolved = true
                end
            end
        end
    end
    if not any then
        return uids, keys, true
    end
    return uids, keys, unresolved
end

local function RowTouchesCraftDelta(row, deltaUids, deltaKeys)
    if type(row) ~= "table" then
        return true
    end
    if type(row._craftMatUids) ~= "table" or type(row._craftMatKeys) ~= "table" then
        StampRowCraftMatIndex(row)
    end
    if type(deltaUids) == "table" then
        for uid in pairs(deltaUids) do
            if row._craftMatUids[uid] == true then
                return true
            end
        end
    end
    if type(deltaKeys) == "table" then
        for k in pairs(deltaKeys) do
            if row._craftMatKeys[k] == true then
                return true
            end
        end
    end
    return false
end

local function FillWatchRowCraftable(row, ctx)
    if type(row) ~= "table" then
        return
    end
    local recipe = row.recipe
    local outUid = tonumber(row.uniqueID) or 0
    local craftsPossible = CountCraftsPossibleMemo(recipe)
    local craftable = CountPotionsCraftable(recipe, outUid)
    row.craftable = craftable
    row.craftsPossible = craftsPossible
    row.craftableShared = false
    row.craftableText = towstring(tostring(craftable))
    StampCraftableSafety(row)
    StampBottleGap(row)
    StampRowCraftMatIndex(row)
    local snapGen = type(ctx) == "table" and tonumber(ctx.snapGen) or CurrentSnapGen()
    if snapGen > 0 then
        row._craftableSnapGen = snapGen
        row._craftableStructKey = RecipeStructuralKey(type(ctx) == "table" and ctx or ReadGens())
    end
end

local function PolishWatchRowsStatus(rows)
    for i = 1, #rows do
        local row = rows[i]
        if type(row) == "table" and row.skillUp ~= true and row.addonOwned ~= true then
            StampBottleGap(row)
            local craftable = tonumber(row.craftable) or 0
            local have = tonumber(row.potionHave) or 0
            local target = tonumber(row.potionMin) or tonumber(row.target) or 0
            local covered = target > 0 and (have + craftable) >= target
            local key = tostring(row.statusKey or "")
            -- Ready only when bags+craftable cover the target and craft bag can load.
            if craftable > 0 and covered
                and (key == "buy_ingredients" or key == "restocking" or key == "craft_bag_full")
            then
                if IsCraftBagFullCached() then
                    ApplyCraftBagFullStatus(row)
                    key = "craft_bag_full"
                else
                    ApplyReadyStatus(row)
                    key = "ready_to_craft"
                end
            end
            -- Uncovered Ready (partial craftable / race) -> Enable AutoGrow / Restocking / Buy.
            if (not covered or craftable <= 0)
                and (key == "ready_to_craft" or key == "ready_to_craft_shared")
            then
                if IsCraftBagFullCached() then
                    ApplyCraftBagFullStatus(row)
                else
                    SetMaterialsShortStatus(row, CanAutoGrowSkill(), nil)
                end
                key = tostring(row.statusKey or "")
            end
            -- Covered Ready stuck while craft bag is too tight to pull inventory mats.
            if (key == "ready_to_craft" or key == "ready_to_craft_shared")
                and covered and craftable > 0 and IsCraftBagFullCached()
            then
                ApplyCraftBagFullStatus(row)
                key = "craft_bag_full"
            end
            -- Stale Enable AutoGrow / Restocking / craft-bag-full after toggles change.
            if key == "enable_autogrow" or key == "restocking" or key == "craft_bag_full" then
                if covered then
                    if (tonumber(row.potionDeficit) or 0) <= 0 then
                        if SeedBufferShort(row.recipe, row.potionKey or row.potionRecipeKey or row.id, row) then
                            ApplySeedBufferStatus(row)
                        else
                            ApplyStockedStatus(row)
                        end
                    elseif craftable > 0 then
                        if IsCraftBagFullCached() then
                            ApplyCraftBagFullStatus(row)
                        else
                            ApplyReadyStatus(row)
                        end
                    elseif IsCraftBagFullCached() then
                        ApplyCraftBagFullStatus(row)
                    else
                        SetMaterialsShortStatus(row, CanAutoGrowSkill(), nil)
                    end
                elseif IsCraftBagFullCached() then
                    ApplyCraftBagFullStatus(row)
                else
                    SetMaterialsShortStatus(row, CanAutoGrowSkill(), nil)
                end
                key = tostring(row.statusKey or "")
            end
            -- AutoGrow-off must not stay Ready when Cultivation is trained
            -- (manual brew still uses the Craftable/Load chip). Apo-only keeps Ready.
            if CanAutoGrowSkill()
                and (key == "ready_to_craft" or key == "ready_to_craft_shared")
            then
                local pk = tostring(RowWatchKey(row) or "")
                if not WatchWantsAutoGrow(pk, nil) then
                    ApplyReadyStatus(row)
                    key = tostring(row.statusKey or "")
                end
            end
            ApplyNeedApothecaryStatus(row)
            ApplyNeedSkillStatus(row)
            ReconcileAutoGrowStatus(row)
        end
    end
    -- Shared contest + Ready<->Shared after promote/demote (plan-row SoT).
    PolishSharedContest(rows)
    for i = 1, #rows do
        StampCraftableSafety(rows[i])
    end
    -- Shared seed cushion: any short seed demotes every AutoGrow watch that uses it.
    PropagateSharedSeedBufferStatus(rows)
end

local function FillWatchRowTips(row, demand)
    if type(row) ~= "table" or type(row.recipe) ~= "table" then
        return
    end
    if type(row.statusTipSlots) == "table" and #row.statusTipSlots > 0 then
        -- A prior stamp on this snap ignored tips. Force the merge.
        row._seedBufferUidSnapGen = nil
        StampRowSeedBufferUids(row)
        return
    end
    local craftsNeeded = tonumber(row.craftsNeeded) or 0
    local slots = row.recipe.slots or {}
    local entries = {}
    for i = 1, #slots do
        local entry = RecipeSlotPlanEntry(slots[i], slots, craftsNeeded, demand)
        if entry ~= nil then
            if type(row.contestedSpecKeys) == "table" then
                local k = SpecKey(entry.spec)
                if k ~= nil and row.contestedSpecKeys[k] == true then
                    entry.note = "(Shared)"
                    entry.noteKind = "shared"
                end
            end
            entries[#entries + 1] = entry
        end
    end
    row.statusTipSlots = entries
    row.seedBufferTip = {
        seedUids = {},
    }
    for i = 1, #entries do
        local tip = entries[i]
        local seedUid = tonumber(tip and tip.seedUid) or 0
        if seedUid > 0 then
            row.seedBufferTip.seedUids[#row.seedBufferTip.seedUids + 1] = seedUid
        end
    end
    row._seedBufferUidSnapGen = nil
    StampRowSeedBufferUids(row)
end

local function ApplyPlantWatchStatus(row, potionRows)
    if type(row) ~= "table" then
        return
    end
    local deficit = tonumber(row.potionDeficit) or 0
    local Watch = StockPiler.Watch
    local armed = Watch and Watch.ShouldAutoGrowPlant
        and Watch.ShouldAutoGrowPlant(row.plantKey or row.id) == true
    row.craftableShared = false
    row.craftable = 0
    row.craftableText = L""
    row.hideBrew = true
    row.hideCraftable = true
    row.priorityTierText = L"-"
    row.plantPrioSentinel = true
    local SM = StockPiler.SeedMap
    if SM and SM.ResolveSeedUidForPlant then
        local resolved = tonumber(SM.ResolveSeedUidForPlant(row.plantUid, row.spec)) or 0
        if resolved > 0 then
            row.seedUid = resolved
        end
    end
    local bufferShort = PlantSeedBufferShort(row.seedUid, row.plantUid, row.spec)
    local US = StockPiler.UpgradeSeed
    local function ApplyMissingSeedStatus()
        local gap = US and US.DescribePlantWatchSeedGap
            and US.DescribePlantWatchSeedGap(row.plantUid, row.spec) or nil
        local upgradeOn = US and US.IsEnabled and US.IsEnabled() == true
        local missingTarget = type(gap) == "table" and gap.haveTarget ~= true
        if missingTarget and upgradeOn ~= true then
            -- No watched-tier seed/plant: tell the player how to unblock.
            row.statusKey = "need_seeds"
            row.statusText = T("plan.status.need_seed_or_upgrade")
            if gap.haveLower == true then
                row.statusLines = {
                    T("tip.watch.need_seed_or_upgrade_lower", {
                        have = tostring(gap.lowerReq or 0),
                        need = tostring(gap.needReq or 0),
                    }),
                }
            else
                row.statusLines = {
                    T("tip.watch.need_seed_or_upgrade"),
                }
            end
            row.seedBufferShort = true
            return true
        end
        if missingTarget and upgradeOn == true then
            -- Upgrade Seeds owns arrive climb; keep a clear plant-row hint.
            row.statusKey = "need_seeds"
            if type(gap) == "table" and gap.haveLower == true then
                row.statusText = T("plan.status.need_seed_upgrade_on")
                row.statusLines = {
                    T("tip.watch.need_seed_upgrade_on", {
                        have = tostring(gap.lowerReq or 0),
                        need = tostring(gap.needReq or 0),
                    }),
                }
            else
                row.statusText = T("plan.status.need_seed_buy")
                row.statusLines = {
                    T("tip.watch.need_seed_buy"),
                }
            end
            row.seedBufferShort = true
            return true
        end
        row.statusKey = "need_seeds"
        row.statusText = T("plan.status.need_seeds")
        row.statusLines = {
            T("tip.watch.seed_buffer"),
        }
        row.seedBufferShort = true
        return true
    end
    if deficit <= 0 then
        -- Stocked: stock UI only. Seed buffer short -> need_seeds (never climb text;
        -- ephemeral Upgrade row owns upgrading status).
        if bufferShort then
            -- Still have target seed credit path for cushion-only shorts.
            local gap = US and US.DescribePlantWatchSeedGap
                and US.DescribePlantWatchSeedGap(row.plantUid, row.spec) or nil
            if type(gap) == "table" and gap.haveTarget ~= true then
                ApplyMissingSeedStatus()
                return
            end
            row.statusKey = "need_seeds"
            row.statusText = T("plan.status.need_seeds")
            row.statusLines = {
                T("tip.watch.seed_buffer"),
            }
            row.seedBufferShort = true
            return
        end
        row.statusKey = "plant_stocked"
        row.statusText = T("plan.status.plant_stocked")
        row.statusLines = nil
        row.seedBufferShort = false
        return
    end
    if not armed then
        row.statusKey = "enable_autogrow"
        row.statusText = T("plan.status.enable_autogrow")
        row.statusLines = nil
        row.seedBufferShort = false
        return
    end
    if bufferShort then
        ApplyMissingSeedStatus()
        return
    end
    row.seedBufferShort = false
    -- plant_stock waits while potions still need Cult grow (buy/brew do not block).
    if PlantWatchesAwaitPotions(potionRows) then
        row.statusKey = "waiting_potions"
        row.statusText = T("plan.status.waiting_potions")
        row.statusLines = {
            T("tip.watch.plant_waiting_potions"),
        }
        return
    end
    row.statusKey = "restocking"
    row.statusText = T("plan.status.restocking")
    row.statusLines = nil
end

local function BuildPlantWatchRows(potionRows)
    local rows = {}
    local Watch = StockPiler.Watch
    local plantWatches = Watch and Watch.GetPlantWatches and Watch.GetPlantWatches() or {}
    if type(plantWatches) ~= "table" then
        return rows
    end
    local Catalog = StockPiler.Catalog
    local Items = StockPiler.Items
    local SM = StockPiler.SeedMap
    local MS = MaterialSpec()
    local list = {}
    for plantKey, watch in pairs(plantWatches) do
        if type(watch) == "table" and watch.enabled == true then
            list[#list + 1] = { plantKey = tostring(plantKey), watch = watch }
        end
    end
    table.sort(list, function(a, b)
        return tostring(a.plantKey) < tostring(b.plantKey)
    end)
    for i = 1, #list do
        local plantKey = list[i].plantKey
        local watch = list[i].watch
        local plantUid = Watch.ParsePlantKey and Watch.ParsePlantKey(plantKey) or 0
        plantUid = tonumber(plantUid) or 0
        if plantUid > 0 then
            local item = Items and Items.GetByUid and Items.GetByUid(plantUid) or nil
            local itemData = item
            if type(item) == "table" and type(item.itemData) == "table" then
                itemData = item.itemData
            end
            local spec = Items and Items.ToSpec and Items.ToSpec(plantUid) or nil
            if type(spec) ~= "table" and MS and MS.FromItemData and type(itemData) == "table" then
                spec = MS.FromItemData(itemData)
            end
            -- Same-tier refine seed is the cushion. GetSeedUidsForPlant()[1] is
            -- unordered grows[] (crit-from-lower can win and paint Seed buffer
            -- while the watched-tier seed is already at 5).
            local seedUid = 0
            if SM and SM.ResolveSeedUidForPlant then
                seedUid = tonumber(SM.ResolveSeedUidForPlant(plantUid, spec)) or 0
            end
            if seedUid <= 0 and SM and SM.GetSeedUidsForPlant then
                local seeds = SM.GetSeedUidsForPlant(plantUid)
                if type(seeds) == "table" and #seeds > 0 then
                    seedUid = tonumber(seeds[1]) or 0
                end
            end
            if seedUid <= 0 and type(spec) == "table" and SM and SM.ResolveSeedForSpec then
                local seed = SM.ResolveSeedForSpec(spec)
                if type(seed) == "table" then
                    seedUid = tonumber(seed.uniqueID or seed.uid) or 0
                end
            end
            local have = 0
            if Catalog and Catalog.PlantHave then
                have = tonumber(Catalog.PlantHave(plantUid)) or 0
            elseif StockPiler.Inventory and StockPiler.Inventory.CountByUid then
                have = tonumber(StockPiler.Inventory.CountByUid(plantUid)) or 0
            end
            local target = tonumber(watch.targetStock) or 40
            local deficit = math.max(0, target - have)
            local name = (item and item.name) or (itemData and itemData.name)
                or (spec and spec.name) or towstring(tostring(plantUid))
            local iconNum = tonumber(item and item.iconNum) or tonumber(itemData and itemData.iconNum) or 0
            if StockPiler.Inventory and StockPiler.Inventory.GetSample then
                local sample = StockPiler.Inventory.GetSample(plantUid)
                if type(sample) == "table" then
                    itemData = sample
                    iconNum = tonumber(sample.iconNum) or iconNum
                    if sample.name ~= nil then
                        name = sample.name
                    end
                end
            end
            if type(itemData) ~= "table" and Items and Items.AsItemData then
                itemData = Items.AsItemData(plantUid)
            end
            if StockPiler.Inventory and StockPiler.Inventory.ResolvePotionItemData then
                itemData = StockPiler.Inventory.ResolvePotionItemData(nil, plantUid, itemData) or itemData
            end
            if type(itemData) == "table" and (tonumber(itemData.uniqueID) or 0) <= 0 then
                itemData.uniqueID = plantUid
            end
            local nameR, nameG, nameB = 255, 255, 255
            if type(itemData) == "table" and DataUtils and DataUtils.GetItemRarityColor then
                local ok, color = pcall(DataUtils.GetItemRarityColor, itemData)
                if ok and type(color) == "table" then
                    nameR = tonumber(color.r) or 255
                    nameG = tonumber(color.g) or 255
                    nameB = tonumber(color.b) or 255
                end
            end
            iconNum = tonumber(itemData and itemData.iconNum) or iconNum
            local row = {
                kind = "plant",
                isPlantWatch = true,
                id = plantKey,
                plantKey = plantKey,
                potionKey = plantKey,
                potionRecipeKey = plantKey,
                plantUid = plantUid,
                seedUid = seedUid,
                uniqueID = plantUid,
                name = name,
                iconNum = iconNum,
                itemData = itemData or item,
                nameR = nameR,
                nameG = nameG,
                nameB = nameB,
                spec = spec,
                potionHave = have,
                stockText = towstring(tostring(have)),
                potionMin = target,
                target = target,
                targetText = towstring(tostring(target)),
                potionDeficit = deficit,
                craftable = 0,
                craftableText = L"",
                craftableShared = false,
                autoGrow = watch.autoGrow == true,
                priorityTierText = L"-",
                plantPrioSentinel = true,
                hideBrew = true,
                hideCraftable = true,
                hasRecipe = false,
                recipe = nil,
            }
            ApplyPlantWatchStatus(row, potionRows)
            rows[#rows + 1] = row
        end
    end
    table.sort(rows, function(a, b)
        return string.lower(ToNarrow(a.name)) < string.lower(ToNarrow(b.name))
    end)
    return rows
end

--- Single status entry: spec paint (live patch uses ApplyLiveWatchStatus).
local function DecideStatus(row, target, recipe, demand)
    ApplySpecPlanStatus(row, target, recipe, demand)
end

local function BuildWatchRows(ctx, watches)
    local rows = {}
    Planner._buildRows = rows
    Planner._buildPlanGen = tonumber(Planner._planGen) or 0
    local RS = RecipeSpec()
    local targets = BuildWatchedTargets(ctx, watches)
    PerfBegin("Build.Demand")
    -- Rows are still empty, so this pass uses bag counts. Do not cache it under
    -- the new planGen; the pass after rows exist is what later callers read.
    Planner._demandNeedScratch = {}
    Planner._demandDeferStore = true
    local demand = BuildBalancedSpecDemand()
    Planner._demandDeferStore = nil
    if Planner._buildSliceAbort ~= nil or type(demand) ~= "table" then
        PerfEnd("Build.Demand")
        return nil
    end
    local needsPass1 = Planner._demandNeedScratch
    Planner._demandNeedScratch = nil
    PerfEnd("Build.Demand")
    PerfBegin("Build.Status")
    for i = 1, #targets do
        local target = targets[i]
        local recipe = RS and RS.RecipeSpecForPotion and RS.RecipeSpecForPotion(target.potionKey) or nil
        if recipe and RS and RS.HydrateRecipeSlots then
            RS.HydrateRecipeSlots(recipe)
        end
        local row = {
            id = target.id,
            potionKey = target.potionKey,
            potionRecipeKey = target.potionKey,
            name = target.name,
            iconNum = target.iconNum,
            uniqueID = target.uniqueID,
            potionHave = target.have,
            stockText = towstring(tostring(target.have)),
            potionMin = target.min,
            target = target.min,
            potionDeficit = target.deficit,
            recipe = recipe,
            recipeSpecKey = target.recipeSpecKey,
            potionBaseKey = target.potionBaseKey,
            autoGrow = target.autoGrow == true,
            priorityTier = tonumber(target.priorityTier) or 1,
            priorityTierText = towstring(tostring(tonumber(target.priorityTier) or 1)),
            hasRecipe = type(recipe) == "table",
        }
        DecideStatus(row, target, recipe, demand)
        FillWatchRowCraftable(row, ctx)
        rows[#rows + 1] = row
        if Planner._buildYield == true and (i % BuildRowBudget()) == 0 and i < #targets then
            if SliceYield() then
                PerfEnd("Build.Status")
                return nil
            end
        end
    end
    if SliceYield() then
        PerfEnd("Build.Status")
        return nil
    end
    Planner._lastDemand = demand
    PolishWatchRowsStatus(rows)
    local plantRows = BuildPlantWatchRows(rows)
    for i = 1, #plantRows do
        rows[#rows + 1] = plantRows[i]
    end
    local UpgradeSeed = StockPiler.UpgradeSeed
    if UpgradeSeed and UpgradeSeed.BuildWatchStatusRows then
        local upRows = UpgradeSeed.BuildWatchStatusRows() or {}
        for i = 1, #upRows do
            local ur = upRows[i]
            if type(ur) == "table" then
                rows[#rows + 1] = ur
            end
        end
    end
    local SkillUp = StockPiler.SkillUp
    if SkillUp and SkillUp.BuildWatchStatusRows then
        local skillRows = SkillUp.BuildWatchStatusRows() or {}
        for i = 1, #skillRows do
            local sr = skillRows[i]
            if type(sr) == "table" then
                rows[#rows + 1] = sr
            end
        end
        -- Full rebuild can miss SkillUp while tradeSkills briefly read 0. Carry
        -- prior ephemeral rows only while SkillUp still wants them (not at cap).
        local needCult = SkillUp.WantCultWatchRow and SkillUp.WantCultWatchRow() == true
        local needApo = SkillUp.WantApoWatchRow and SkillUp.WantApoWatchRow() == true
        if needCult or needApo then
            local haveCult, haveApo = false, false
            for i = 1, #rows do
                local r = rows[i]
                if type(r) == "table" and r.skillUp == true then
                    if tostring(r.skillUpKind or "") == "cult" then
                        haveCult = true
                    elseif tostring(r.skillUpKind or "") == "apo" then
                        haveApo = true
                    end
                end
            end
            if (needCult and not haveCult) or (needApo and not haveApo) then
                local prev = StockPiler.PlanSnapshot and StockPiler.PlanSnapshot.Get
                    and StockPiler.PlanSnapshot.Get()
                local prevRows = type(prev) == "table" and prev.rows or nil
                if type(prevRows) == "table" then
                    for i = 1, #prevRows do
                        local pr = prevRows[i]
                        if type(pr) == "table" and pr.skillUp == true then
                            local kind = tostring(pr.skillUpKind or "")
                            if (kind == "cult" and needCult and not haveCult)
                                or (kind == "apo" and needApo and not haveApo)
                            then
                                local copied = {}
                                for k, v in pairs(pr) do
                                    copied[k] = v
                                end
                                rows[#rows + 1] = copied
                                if kind == "cult" then
                                    haveCult = true
                                else
                                    haveApo = true
                                end
                            end
                        end
                    end
                end
            end
        end
    end
    PerfEnd("Build.Status")
    PerfBegin("Build.Tips")
    if Planner._lazyWatchTips ~= true then
        for i = 1, #rows do
            if rows[i].kind ~= "plant" and rows[i].isPlantWatch ~= true
                and rows[i].skillUp ~= true and rows[i].addonOwned ~= true
            then
                FillWatchRowTips(rows[i], demand)
            end
        end
    end
    -- Tips can add seed UIDs; re-propagate so shared shorts demote all sharers.
    PropagateSharedSeedBufferStatus(rows)
    PerfEnd("Build.Tips")
    local prevPlan = StockPiler.PlanSnapshot and StockPiler.PlanSnapshot.Get
        and StockPiler.PlanSnapshot.Get()
    local seedBufferTipData = BuildSeedBufferTipData({
        previous = type(prevPlan) == "table" and prevPlan.seedBufferTipData or nil,
    })
    if SliceYield() then
        return nil
    end
    Planner._demandNeedScratch = {}
    if type(needsPass1) ~= "table" or next(needsPass1) == nil then
        -- Nothing in the first pass can change. Keep that demand.
        if Planner._demandDeferStore == true then
            Planner._demandDeferStore = nil
        end
        Planner._demandCache = demand
        Planner._demandCacheKey = FullCacheKey("demand:" .. tostring(Planner._buildPlanGen or Planner._planGen or 0))
    else
        demand = BuildBalancedSpecDemand()
        if Planner._buildSliceAbort ~= nil or type(demand) ~= "table" then
            return nil
        end
    end
    Planner._lastDemand = demand
    -- Status was decided from the bag-only pass. Re-decide only the watches
    -- whose grow answer changed once the rows exist.
    local needsPass2 = Planner._demandNeedScratch
    Planner._demandNeedScratch = nil
    if type(needsPass1) == "table" and type(needsPass2) == "table" then
        local statusChanged = false
        for i = 1, #targets do
            local target = targets[i]
            local key = tostring(target.potionKey or "")
            local row = rows[i]
            if key ~= "" and needsPass1[key] ~= nil and needsPass2[key] ~= nil
                and needsPass1[key] ~= needsPass2[key]
                and type(row) == "table" and row.skillUp ~= true and row.addonOwned ~= true
            then
                local recipe = row.recipe
                DecideStatus(row, target, recipe, demand)
                FillWatchRowCraftable(row, ctx)
                if Planner._lazyWatchTips ~= true then
                    FillWatchRowTips(row, demand)
                end
                statusChanged = true
            end
        end
        if statusChanged == true then
            -- Re-decide resets status from the spec and skips the polish that
            -- already ran on these rows. Plant, upgrade, and SkillUp rows were
            -- appended after that pass; polish only the potion rows again.
            local potionRows = {}
            local n = #targets
            if n > #rows then
                n = #rows
            end
            for i = 1, n do
                potionRows[i] = rows[i]
            end
            PolishWatchRowsStatus(potionRows)
        end
    end
    Planner._buildRows = nil
    Planner._buildPlanGen = nil
    return rows, seedBufferTipData, demand
end

----------------------------------------------------------------
-- Live Status overlay
----------------------------------------------------------------

local livePatchIndex

local function BuildLivePatchIndex()
    local index = { members = {}, byKey = {}, byUid = {}, plan = nil, rows = nil, rowCount = 0 }
    local PS = StockPiler.PlanSnapshot
    local plan = PS and PS.Get and PS.Get()
    index.plan = plan
    if type(plan) ~= "table" or type(plan.rows) ~= "table" then
        return index
    end
    index.rows = plan.rows
    index.rowCount = #plan.rows
    for i = 1, #plan.rows do
        local snap = plan.rows[i]
        if type(snap) == "table" then
            index.members[snap] = true
            local snapKey = tostring(snap.potionRecipeKey or snap.id or snap.potionKey or "")
            if snapKey ~= "" and index.byKey[snapKey] == nil then
                index.byKey[snapKey] = snap
            end
            local uid = tonumber(snap.uniqueID) or 0
            if uid > 0 then
                local list = index.byUid[uid]
                if list == nil then
                    list = {}
                    index.byUid[uid] = list
                end
                list[#list + 1] = snap
            end
        end
    end
    return index
end

local function DropLivePatchIndex()
    livePatchIndex = nil
end

local function PatchPlanSnapshotLiveStatus(row)
    local index = livePatchIndex
    local PS = StockPiler.PlanSnapshot
    local plan = PS and PS.Get and PS.Get()
    local planRows = type(plan) == "table" and plan.rows or nil
    local rowCount = type(planRows) == "table" and #planRows or 0
    -- Session cache is owned by PatchWatchRowsLiveCounts. A rebuild here must
    -- not outlive the call: RemovePlanSnapshotRowByKey edits plan.rows in place.
    if type(index) ~= "table" or index.plan ~= plan
        or index.rows ~= planRows or index.rowCount ~= rowCount
    then
        index = BuildLivePatchIndex()
    end
    if index.members[row] == true then
        return
    end
    local keyStr = tostring(row.potionRecipeKey or row.id or row.potionKey or "")
    local uid = tonumber(row.uniqueID) or 0
    local rowEph = row.upgradeWatch == true or row.skillUp == true or row.addonOwned == true
    local rowPlant = row.kind == "plant" or row.isPlantWatch == true

    local function sameKind(snap)
        local snapEph = snap.upgradeWatch == true or snap.skillUp == true or snap.addonOwned == true
        local snapPlant = snap.kind == "plant" or snap.isPlantWatch == true
        -- Upgrade ephemeral rows reuse the watched plant uniqueID; never match across kinds.
        if rowEph ~= snapEph then
            return false
        end
        if rowPlant ~= snapPlant then
            return false
        end
        return true
    end

    local function apply(snap)
        snap.potionHave = row.potionHave
        snap.potionDeficit = row.potionDeficit
        snap.craftable = row.craftable
        snap.statusKey = row.statusKey
        snap.statusText = row.statusText
        snap.statusLines = row.statusLines
        snap.craftableShared = row.craftableShared
        snap.seedBufferShort = row.seedBufferShort == true
        snap.craftableSafe = row.craftableSafe == true
    end

    -- Prefer exact watch key (plant:uid vs upgrade_seed:uid).
    if keyStr ~= "" then
        local snap = index.byKey[keyStr]
        if type(snap) == "table" then
            apply(snap)
            return
        end
    end
    -- UID fallback only within the same row kind.
    if uid > 0 then
        local list = index.byUid[uid]
        if type(list) == "table" then
            for i = 1, #list do
                local snap = list[i]
                if type(snap) == "table" and sameKind(snap) then
                    apply(snap)
                    return
                end
            end
        end
    end
end

local function RemovePlanSnapshotRowByKey(keyStr)
    keyStr = tostring(keyStr or "")
    if keyStr == "" then
        return false
    end
    local PS = StockPiler.PlanSnapshot
    local plan = PS and PS.Get and PS.Get()
    if type(plan) ~= "table" or type(plan.rows) ~= "table" then
        return false
    end
    for i = #plan.rows, 1, -1 do
        local snap = plan.rows[i]
        if type(snap) == "table" then
            local snapKey = tostring(snap.potionRecipeKey or snap.id or snap.potionKey or "")
            if snapKey == keyStr then
                table.remove(plan.rows, i)
                DropLivePatchIndex()
                return true
            end
        end
    end
    return false
end

local function RefreshSkillUpWatchRows(rows, opts)
    opts = type(opts) == "table" and opts or {}
    if type(rows) ~= "table" then
        return false
    end
    local SkillUp = StockPiler.SkillUp
    local UpgradeSeed = StockPiler.UpgradeSeed
    local fresh = {}
    if UpgradeSeed and UpgradeSeed.BuildWatchStatusRows then
        local up = UpgradeSeed.BuildWatchStatusRows() or {}
        for i = 1, #up do
            fresh[#fresh + 1] = up[i]
        end
    end
    if SkillUp and SkillUp.BuildWatchStatusRows then
        local sk = SkillUp.BuildWatchStatusRows() or {}
        for i = 1, #sk do
            fresh[#fresh + 1] = sk[i]
        end
    end
    -- Still run when fresh is empty so completed Upgrade/SkillUp ephemerals are dropped.
    if not (SkillUp and SkillUp.BuildWatchStatusRows)
        and not (UpgradeSeed and UpgradeSeed.BuildWatchStatusRows)
    then
        return false
    end
    local byKey = {}
    for i = 1, #fresh do
        local sr = fresh[i]
        if type(sr) == "table" then
            local k = tostring(sr.potionKey or sr.id or "")
            if k ~= "" then
                byKey[k] = sr
            end
        end
    end
    local dirty = false
    local removed = false
    local present = {}
    for i = #rows, 1, -1 do
        local row = rows[i]
        if type(row) == "table" and (row.skillUp == true or row.addonOwned == true
            or row.upgradeWatch == true)
        then
            local k = tostring(row.potionKey or row.id or "")
            local sr = byKey[k]
            if type(sr) == "table" then
                present[k] = true
                local prevKey = tostring(row.statusKey or "")
                local prevText = row.statusText
                local prevLines = row.statusLines
                row.statusKey = sr.statusKey
                row.statusText = sr.statusText
                row.statusLines = sr.statusLines
                row.seedUid = sr.seedUid
                row.plantUid = sr.plantUid
                row.mainUid = sr.mainUid
                row.autoGrow = sr.autoGrow
                row.hideBrew = sr.hideBrew
                row.hideAutoGrow = sr.hideAutoGrow
                row.craftable = sr.craftable
                row.craftableSafe = sr.craftableSafe
                row.craftableText = sr.craftableText
                row.potionHave = sr.potionHave
                row.potionMin = sr.potionMin
                row.potionDeficit = sr.potionDeficit
                row.target = sr.target
                row.skillReq = sr.skillReq
                row.iconNum = sr.iconNum
                -- Recipe must travel with ready_to_craft or Brew load skips no-recipe
                -- while the footer stays lit (craftable>0 without slots).
                row.recipe = sr.recipe
                row.recipeYield = sr.recipeYield
                local newKey = tostring(row.statusKey or "")
                if newKey ~= prevKey or row.statusText ~= prevText
                    or row.statusLines ~= prevLines
                then
                    dirty = true
                    if opts.syncSnapshot ~= false then
                        PatchPlanSnapshotLiveStatus(row)
                    end
                end
            else
                -- Ephemeral no longer emitted (arrive done / SkillUp off or at cap):
                -- drop the row instead of leaving a zombie. Keep only on a transient
                -- empty Build (combat/scenario skill blip) via Want*WatchRow.
                local keepSkillUp = false
                if row.skillUp == true and SkillUp then
                    local kind = tostring(row.skillUpKind or "")
                    if kind == "apo" then
                        keepSkillUp = SkillUp.WantApoWatchRow and SkillUp.WantApoWatchRow() == true
                    elseif kind == "cult" then
                        keepSkillUp = SkillUp.WantCultWatchRow and SkillUp.WantCultWatchRow() == true
                    end
                end
                if keepSkillUp then
                    -- leave row in place
                else
                    table.remove(rows, i)
                    dirty = true
                    removed = true
                    DropLivePatchIndex()
                    if opts.syncSnapshot ~= false then
                        RemovePlanSnapshotRowByKey(k)
                    end
                end
            end
        end
    end
    -- Re-add ephemerals that BuildWatchStatusRows emits but live patch dropped
    -- (e.g. transient unstocked mid seed-buffer refine -> ephemeral-cleared).
    for i = 1, #fresh do
        local sr = fresh[i]
        if type(sr) == "table" then
            local k = tostring(sr.potionKey or sr.id or "")
            if k ~= "" and present[k] ~= true then
                rows[#rows + 1] = sr
                present[k] = true
                dirty = true
                DropLivePatchIndex()
            end
        end
    end
    if removed then
        local B = StockPiler.EventBus
        local E = StockPiler.Events
        if B and E and E.PLAN_UPDATED then
            B.Fire(E.PLAN_UPDATED, { reason = "ephemeral-cleared" })
        else
            local Bus = StockPiler.EventBus
            if Bus and Bus.FireWatchUiDirty then
                Bus.FireWatchUiDirty({ reason = "ephemeral-cleared" })
            end
        end
        local Grow = StockPiler.Grow
        if Grow and Grow.MarkPlantJobDirty then
            Grow.MarkPlantJobDirty("ephemeral-cleared")
        end
        if UpgradeSeed and UpgradeSeed.InvalidateUpgradeTargetsCache then
            UpgradeSeed.InvalidateUpgradeTargetsCache()
        end
    end
    return dirty
end

-- Forward declare: PatchWatchRowsLiveCounts calls this before the definition below.
local SyncTipSlotNeeds

local function PatchWatchRowsLiveCounts(rows, opts)
    opts = type(opts) == "table" and opts or {}
    local syncSnapshot = opts.syncSnapshot ~= false
    local allowWarmHave = opts.allowWarmHave ~= false
    -- After brew / bag settle: recount craftable even while apo session stays loaded.
    local forceRecountCraftable = opts.forceRecountCraftable == true
    if type(rows) ~= "table" then
        return
    end
    livePatchIndex = BuildLivePatchIndex()
    local Brew = StockPiler.Brew
    local brewSessionActive = false
    if Brew and Brew.GetSession then
        local session = Brew.GetSession()
        if type(session) == "table"
            and (session.phase == "loading" or session.phase == "loaded")
        then
            if forceRecountCraftable ~= true then
                allowWarmHave = false
            end
            brewSessionActive = true
        end
    end
    -- Empty plan after reload/logon: still mount SkillUp / Upgrade rows.
    -- Skipping here left Watch blank until /stp dumpall or an AutoGrow toggle.
    if #rows == 0 then
        if brewSessionActive ~= true then
            RefreshSkillUpWatchRows(rows, { syncSnapshot = syncSnapshot })
        end
        livePatchIndex = nil
        return
    end
    local Inv = StockPiler.Inventory
    if not Inv or not Inv.CountByUid then
        livePatchIndex = nil
        return
    end
    -- Skip WarmHave while refine outstanding / brew session / closed-window.
    local RP = StockPiler.RefinePipeline
    if RP and RP.HasOutstanding and RP.HasOutstanding() == true then
        allowWarmHave = false
    end
    local snapGen = CurrentSnapGen()
    local structKey = RecipeStructuralKey(ReadGens())
    local needCraftable = false
    local structDirty = false
    for i = 1, #rows do
        local row = rows[i]
        if type(row) == "table" and type(row.recipe or row.specRecipe) == "table" then
            local snapMiss = (tonumber(row._craftableSnapGen) or -1) ~= snapGen
            local structMiss = tostring(row._craftableStructKey or "") ~= tostring(structKey)
            if structMiss then
                structDirty = true
                needCraftable = true
            elseif snapMiss then
                needCraftable = true
            end
        end
    end
    if forceRecountCraftable then
        needCraftable = true
    end
    local haveWarm = IsHaveCacheWarmForSnap()
    if needCraftable then
        BeginPlanCraftsMemo()
        if not haveWarm and (allowWarmHave or forceRecountCraftable) then
            if forceRecountCraftable then
                Planner._forceWarmHave = true
            end
            -- Always clear the force flag even if WarmHave errors.
            local ok, warmErr = pcall(WarmSpecHaveCacheForWatches)
            Planner._forceWarmHave = nil
            if ok then
                haveWarm = IsHaveCacheWarmForSnap()
            elseif StockPiler.Debug and StockPiler.Debug.ReportProtectedCallFailure then
                StockPiler.Debug.ReportProtectedCallFailure(
                    "Planner.WarmSpecHaveCacheForWatches", warmErr, true)
            end
        end
    end
    -- Prefer warm cache; force path still recounts after WarmHave attempt.
    local recountCraftable = needCraftable and (haveWarm or allowWarmHave or forceRecountCraftable)
    -- Mid-brew Watch catch-up: Stock/Status only (no craftable recount).
    if opts.recountCraftable == false and forceRecountCraftable ~= true then
        recountCraftable = false
    end
    -- Quiet/storm remount keeps prior have counts warm for orch probes. Never stamp
    -- craftable from that remount - Watch would look one bag-move behind.
    if recountCraftable and HoldHaveCacheQuiet() and forceRecountCraftable ~= true then
        recountCraftable = false
    end
    local selectiveCraftable = false
    local deltaUids, deltaKeys
    -- Settings / knowledge / watch-gen changes must full-recount (not bag-delta).
    -- forceRecountCraftable always full-recounts (post-brew mat spend).
    if recountCraftable and forceRecountCraftable ~= true and structDirty ~= true
        and Inv.GetLastNetUidDelta
    then
        local delta = Inv.GetLastNetUidDelta()
        if type(delta) == "table" then
            -- Any spend or restore: full craftable recount. Selective touch-sets
            -- miss family specs (extender/multiplier) and bank L0-slot-set.
            local anySigned = false
            for _, d in pairs(delta) do
                if (tonumber(d) or 0) ~= 0 then
                    anySigned = true
                    break
                end
            end
            local unresolved
            deltaUids, deltaKeys, unresolved = BuildDeltaTouchSets(delta)
            local hasUid = type(deltaUids) == "table" and next(deltaUids) ~= nil
            -- A signed bag delta still only recounts rows that touch those uids
            -- when every uid resolved to a spec key. Unresolved stays a full pass.
            if anySigned == true then
                if unresolved ~= true and hasUid then
                    selectiveCraftable = true
                end
            elseif unresolved ~= true then
                selectiveCraftable = true
            end
        end
    end
    local contestDirty = false
    -- Snapshot before paint so focus-cache invalidate uses net status, not
    -- intermediate ApplyLiveWatchStatus flips that PolishSharedContest undoes.
    local focusSnap = {}
    for i = 1, #rows do
        local row = rows[i]
        if type(row) == "table" then
            focusSnap[i] = {
                key = tostring(row.statusKey or ""),
                shared = row.craftableShared == true,
            }
        end
    end
    local function FocusKeyQualifies(key)
        return key == "restocking" or key == "need_seeds"
            or key == "upgrading_seed" or key == "ready_to_craft_shared"
            or key == "buy_ingredients"
    end
    for i = 1, #rows do
        local row = rows[i]
        if type(row) == "table" and (row.skillUp == true or row.addonOwned == true) then
            -- Refreshed after the plant/potion loop (see RefreshSkillUpWatchRows).
        elseif type(row) == "table" and (row.kind == "plant" or row.isPlantWatch == true) then
            local uid = tonumber(row.uniqueID) or tonumber(row.plantUid) or 0
            if uid <= 0 then
                local Watch = StockPiler.Watch
                local plantKey = row.plantKey or row.id or row.potionKey
                if Watch and Watch.ParsePlantKey then
                    uid = tonumber(Watch.ParsePlantKey(plantKey)) or 0
                end
                if uid > 0 then
                    row.plantUid = uid
                    row.uniqueID = uid
                end
            end
            if uid > 0 then
                local have = tonumber(Inv.CountByUid(uid)) or 0
                local prevKey = tostring(row.statusKey or "")
                local prevText = row.statusText
                row.potionHave = have
                row.stockText = towstring(tostring(have))
                local min = tonumber(row.potionMin) or tonumber(row.target) or 0
                local deficit = math.max(0, min - have)
                row.potionDeficit = deficit
                row.targetText = towstring(tostring(min))
                ApplyPlantWatchStatus(row, rows)
                local newKey = tostring(row.statusKey or "")
                if syncSnapshot and (newKey ~= prevKey or row.statusText ~= prevText) then
                    PatchPlanSnapshotLiveStatus(row)
                end
                if newKey ~= prevKey then
                    local Grow = StockPiler.Grow
                    if Grow and Grow.MarkPlantJobDirty then
                        Grow.MarkPlantJobDirty()
                    end
                end
            end
        elseif type(row) == "table" then
            local uid = tonumber(row.uniqueID) or 0
            if uid > 0 then
                local have = tonumber(Inv.CountByUid(uid)) or 0
                local prevDeficit = tonumber(row.potionDeficit) or 0
                local prevCraftable = tonumber(row.craftable) or 0
                local prevKey = tostring(row.statusKey or "")
                local prevText = row.statusText
                row.potionHave = have
                row.stockText = towstring(tostring(have))
                local min = tonumber(row.potionMin) or tonumber(row.target) or 0
                local deficit = math.max(0, min - have)
                row.potionDeficit = deficit
                local recipe = row.recipe or row.specRecipe
                -- Re-resolve after brew learn/scrub left status=Learn recipe with a live rk.
                if type(recipe) ~= "table" or tostring(row.statusKey or "") == "no_recipe" then
                    local RS = RecipeSpec()
                    local pk = row.potionRecipeKey or row.id or row.potionKey
                    if RS and RS.RecipeSpecForPotion and pk ~= nil then
                        local resolved = RS.RecipeSpecForPotion(pk)
                        if type(resolved) == "table" then
                            recipe = resolved
                            row.recipe = resolved
                            row.hasRecipe = true
                        end
                    end
                end
                local craftable = tonumber(row.craftable) or 0
                local outUid = tonumber(row.uniqueID) or 0
                if type(recipe) == "table" then
                    local prevCraftsNeeded = tonumber(row.craftsNeeded) or 0
                    local craftsNeeded = CraftsNeededForDeficit(deficit, recipe, outUid)
                    row.craftsNeeded = craftsNeeded
                    local snapMiss = (tonumber(row._craftableSnapGen) or -1) ~= snapGen
                    local structMiss = tostring(row._craftableStructKey or "") ~= tostring(structKey)
                    if recountCraftable and (snapMiss or structMiss) then
                        local doRecount = structMiss
                            or (not selectiveCraftable)
                            or RowTouchesCraftDelta(row, deltaUids, deltaKeys)
                        if doRecount then
                            craftable = CountPotionsCraftable(recipe, outUid)
                            row.craftable = craftable
                            row.craftsPossible = CountCraftsPossibleMemo(recipe)
                            row.craftableText = towstring(tostring(craftable))
                            StampRowCraftMatIndex(row)
                            -- Only stamp when recounted. Stamping on a selective miss
                            -- locked Restocking until /stp dumpall force-built.
                            row._craftableSnapGen = snapGen
                            row._craftableStructKey = structKey
                            SyncTipSlotNeeds(row, craftsNeeded)
                        end
                    elseif craftsNeeded ~= prevCraftsNeeded then
                        SyncTipSlotNeeds(row, craftsNeeded)
                    end
                end
                StampBottleGap(row)
                if deficit ~= prevDeficit or craftable ~= prevCraftable then
                    contestDirty = true
                end
                ApplyLiveWatchStatus(row, recipe, deficit, have, craftable, min)
                ReconcileAutoGrowStatus(row)
                StampCraftableSafety(row)
                StampRowTipPresentation(row)
                local newKey = tostring(row.statusKey or "")
                -- ApplyReadyStatus clears craftableShared; re-contest on Ready/Shared transitions.
                if newKey ~= prevKey
                    and (newKey == "ready_to_craft" or newKey == "ready_to_craft_shared"
                        or newKey == "buy_ingredients"
                        or prevKey == "ready_to_craft" or prevKey == "ready_to_craft_shared"
                        or prevKey == "buy_ingredients")
                then
                    contestDirty = true
                end
                if syncSnapshot and (newKey ~= prevKey or row.statusText ~= prevText) then
                    PatchPlanSnapshotLiveStatus(row)
                end
                if (prevKey == "need_seeds" or prevKey == "upgrading_seed"
                        or prevKey == "ready_to_craft"
                        or prevKey == "ready_to_craft_shared"
                        or prevKey == "potion_stocked")
                    and newKey ~= prevKey
                    and (newKey == "restocking" or newKey == "need_seeds"
                        or newKey == "upgrading_seed"
                        or newKey == "buy_ingredients" or newKey == "enable_autogrow")
                then
                    local Grow = StockPiler.Grow
                    if Grow and Grow.MarkPlantJobDirty then
                        Grow.MarkPlantJobDirty()
                    end
                end
                -- Focus-cache invalidate deferred to net compare after PolishSharedContest.
            end
        end
    end
    -- Plants were painted before potions in the loop; re-apply soft gate after potion statuses.
    for i = 1, #rows do
        local row = rows[i]
        if type(row) == "table" and (row.kind == "plant" or row.isPlantWatch == true) then
            local key = tostring(row.statusKey or "")
            if key == "waiting_potions" or key == "restocking" then
                local prevKey = key
                local prevText = row.statusText
                ApplyPlantWatchStatus(row, rows)
                local newKey = tostring(row.statusKey or "")
                if syncSnapshot and (newKey ~= prevKey or row.statusText ~= prevText) then
                    PatchPlanSnapshotLiveStatus(row)
                end
                if newKey ~= prevKey then
                    local Grow = StockPiler.Grow
                    if Grow and Grow.MarkPlantJobDirty then
                        Grow.MarkPlantJobDirty()
                    end
                end
            end
        end
    end
    -- SkillUp rows are not count-patched above; rebuild status so waiting -> planting
    -- flips when watches stock without a full plan rebuild.
    -- Mid-brew: skip - SeedBufferOk -> BufferFlags after every ApplySlots (libperf hitch).
    -- ForceBrew / post-session full flush refreshes SkillUp status.
    if not brewSessionActive then
        RefreshSkillUpWatchRows(rows, { syncSnapshot = syncSnapshot })
    end
    -- Shared contest: mat buys (flasks) often leave potion deficit/craftable unchanged,
    -- so contestDirty alone misses clearing craftableShared / Buy-flasks paint.
    local needSharedPolish = contestDirty
    if not needSharedPolish then
        for i = 1, #rows do
            local row = rows[i]
            if type(row) == "table"
                and (row.craftableShared == true
                    or tostring(row.statusKey or "") == "ready_to_craft_shared"
                    or tostring(row.statusKey or "") == "buy_ingredients")
            then
                needSharedPolish = true
                break
            end
        end
    end
    local craftReadyBrew = nil
    local craftReadyBefore = nil
    if needSharedPolish then
        craftReadyBrew = StockPiler.Brew
        craftReadyBefore = craftReadyBrew and craftReadyBrew.HasReadyToCraft
            and craftReadyBrew.HasReadyToCraft() == true
        PolishSharedContest(rows)
        if craftReadyBrew and craftReadyBrew.InvalidateCanBrewCache then
            craftReadyBrew.InvalidateCanBrewCache()
        end
        if syncSnapshot then
            for i = 1, #rows do
                local row = rows[i]
                if type(row) == "table" then
                    PatchPlanSnapshotLiveStatus(row)
                end
            end
        end
    end
    -- One focus-cache bust per pass, only when a qualifying status really changed.
    local focusDirty = false
    for i = 1, #rows do
        local row = rows[i]
        local before = focusSnap[i]
        if type(row) == "table" and type(before) == "table" then
            local afterKey = tostring(row.statusKey or "")
            local afterShared = row.craftableShared == true
            if afterKey ~= before.key or afterShared ~= before.shared then
                if FocusKeyQualifies(afterKey) or FocusKeyQualifies(before.key) then
                    focusDirty = true
                    break
                end
            end
        end
    end
    if focusDirty then
        InvalidateFocusCaches("live-status")
    end
    for i = 1, #rows do
        StampCraftableSafety(rows[i])
    end
    if PropagateSharedSeedBufferStatus(rows) then
        if syncSnapshot then
            for i = 1, #rows do
                local row = rows[i]
                if type(row) == "table" then
                    PatchPlanSnapshotLiveStatus(row)
                end
            end
        end
        local BrewLive = StockPiler.Brew
        if BrewLive and BrewLive.InvalidateCanBrewCache then
            BrewLive.InvalidateCanBrewCache()
        end
        local Bus = StockPiler.EventBus
        if Bus and Bus.FireFooterDirty then
            Bus.FireFooterDirty({ reason = "seed-buffer" })
        end
    end
    -- Fire CRAFT_READY_CHANGED only after stamps/propagate (no mid-patch re-entry).
    if needSharedPolish and craftReadyBrew then
        local afterReady = craftReadyBrew.HasReadyToCraft
            and craftReadyBrew.HasReadyToCraft() == true
        if craftReadyBefore ~= afterReady then
            local Bus = StockPiler.EventBus
            local E = StockPiler.Events
            if Bus and Bus.Fire and E and E.CRAFT_READY_CHANGED then
                Bus.Fire(E.CRAFT_READY_CHANGED, { ready = afterReady == true })
            end
            if Bus and Bus.FireFooterDirty then
                Bus.FireFooterDirty({ reason = "craft-ready" })
            end
        end
        if craftReadyBrew.MaybeNotifyBrewReady then
            craftReadyBrew.MaybeNotifyBrewReady()
        end
    end
    if StockPiler.Grow and StockPiler.Grow.MaybeNotifyAutoGrowStall then
        StockPiler.Grow.MaybeNotifyAutoGrowStall()
    end
    livePatchIndex = nil
end

----------------------------------------------------------------
-- HasReadyToCraft / closed-window sync
----------------------------------------------------------------

local function RowIsReadyToCraft(row)
    if type(row) ~= "table" then
        return false
    end
    if row.kind == "plant" or row.isPlantWatch == true then
        return false
    end
    if tostring(row.statusKey or "") ~= "ready_to_craft" then
        return false
    end
    local pk = RowWatchKey(row)
    if not WatchWantsAutoGrow(pk, nil) then
        return false
    end
    if row.craftableShared == true then
        return false
    end
    local craftable = tonumber(row.craftable) or 0
    if craftable <= 0 or (tonumber(row.potionDeficit) or 0) <= 0 then
        return false
    end
    local have = tonumber(row.potionHave) or 0
    local target = tonumber(row.potionMin) or tonumber(row.target) or 0
    if target > 0 and (have + craftable) < target then
        return false
    end
    return true
end

local function HasReadyToCraftFromPlan()
    local PS = StockPiler.PlanSnapshot
    local plan = PS and PS.Get and PS.Get()
    if type(plan) ~= "table" or type(plan.rows) ~= "table" then
        return false
    end
    for i = 1, #plan.rows do
        if RowIsReadyToCraft(plan.rows[i]) then
            return true
        end
    end
    return false
end

----------------------------------------------------------------
-- Publish / cheap / garden / full build
----------------------------------------------------------------

local function PublishPlan(plan, key, meta)
    StampPlanTipPresentation(plan)
    local PS = StockPiler.PlanSnapshot
    if PS and PS.Set then
        PS.Set(plan, key)
    end
    local B = StockPiler.EventBus
    local E = StockPiler.Events
    if B and E and E.PLAN_UPDATED then
        local payload = { planGen = plan.planGen, cacheKey = key }
        if type(meta) == "table" then
            for k, v in pairs(meta) do
                payload[k] = v
            end
        end
        B.Fire(E.PLAN_UPDATED, payload)
    end
    if StockPiler.Brew and StockPiler.Brew.MaybeNotifyBrewReady then
        StockPiler.Brew.MaybeNotifyBrewReady()
    end
    if StockPiler.Grow and StockPiler.Grow.MaybeNotifyAutoGrowStall then
        StockPiler.Grow.MaybeNotifyAutoGrowStall()
    end
end

local function RefreshStaleCtx(stale)
    local g = ReadGens()
    stale.ctx = stale.ctx or {}
    stale.ctx.snapGen = g.snapGen
    stale.ctx.gardenGen = g.gardenGen
    stale.ctx.refineGen = g.refineGen
    stale.ctx.watchGen = g.watchGen
    stale.ctx.knowledgeGen = g.knowledgeGen
    stale.ctx.recipeStatsGen = g.recipeStatsGen
    stale.ctx.settingsHash = g.settingsHash
    return FormatCacheKey(stale.ctx)
end

--- Potion rows with a recipe must have craftable stamped for this snap and
--- recipe key before a cheap or garden publish advances the plan cache key.
--- Otherwise Build early-returns a stale plan.
local function RowsCraftableCurrentForSnap(rows, snapGen, structKey)
    snapGen = tonumber(snapGen) or CurrentSnapGen()
    structKey = structKey or RecipeStructuralKey(ReadGens())
    if type(rows) ~= "table" then
        return true
    end
    for i = 1, #rows do
        local row = rows[i]
        if type(row) == "table"
            and type(row.recipe or row.specRecipe) == "table"
            and row.kind ~= "plant"
            and row.isPlantWatch ~= true
            and row.skillUp ~= true
            and row.addonOwned ~= true
        then
            if (tonumber(row._craftableSnapGen) or -1) ~= snapGen then
                return false
            end
            if tostring(row._craftableStructKey or "") ~= tostring(structKey) then
                return false
            end
        end
    end
    return true
end

--- Keep tip Have/Need aligned when craftsNeeded changes without a full Build
--- (Optimistic off / rate samples / deficit edits).
function SyncTipSlotNeeds(row, craftsNeeded)
    local tips = row and row.statusTipSlots
    if type(tips) ~= "table" then
        return
    end
    craftsNeeded = tonumber(craftsNeeded) or 0
    for t = 1, #tips do
        local entry = tips[t]
        if type(entry) == "table" then
            local per = math.max(1, tonumber(entry.perCraft) or 1)
            local need = craftsNeeded * per
            entry.need = need
            entry.craftsNeeded = craftsNeeded
            local have = tonumber(entry.have) or 0
            if type(entry.spec) == "table" then
                local live = CountItemsMatchingSpec(entry.spec, { cacheOnly = true })
                if live ~= nil then
                    have = tonumber(live) or have
                    entry.have = have
                end
            end
            entry.deficit = math.max(0, need - have)
            entry.craftsHave = math.floor(have / per)
            entry.stocked = entry.deficit <= 0
        end
    end
end

local function TryCheapRebuild()
    local PS = StockPiler.PlanSnapshot
    local stale = PS and PS.Get and PS.Get()
    if type(stale) ~= "table" or type(stale.rows) ~= "table" or #stale.rows == 0 then
        return nil
    end
    if type(stale.ctx) ~= "table" then
        return nil
    end
    -- Remounted have during quiet/orch hold must not publish a new snap cacheKey
    -- with unrecounted craftable (Build early-return then freezes Watch until dumpall).
    if HoldHaveCacheQuiet() then
        return nil
    end
    local cur = ReadGens()
    if StructuralNonRefineKey(stale.ctx) ~= StructuralNonRefineKey(cur) then
        return nil
    end
    PerfBegin("Planner.CheapRebuild")
    PatchWatchRowsLiveCounts(stale.rows, { syncSnapshot = false })
    if not RowsCraftableCurrentForSnap(stale.rows, cur.snapGen) then
        -- Do not RefreshStaleCtx / PublishPlan: advancing the key without a recount
        -- locks Build into a stale cache hit until another snap or dumpall.
        PerfEnd("Planner.CheapRebuild")
        return nil
    end
    stale.seedBufferTipData = BuildSeedBufferTipData({
        previous = stale.seedBufferTipData,
    })
    local key = RefreshStaleCtx(stale)
    local planGen = (tonumber(Planner._planGen) or 0) + 1
    Planner._planGen = planGen
    stale.planGen = planGen
    stale.cacheKey = key
    stale.builtAt = (type(GetGameTime) == "function" and GetGameTime()) or 0
    PublishPlan(stale, key, { cheap = true })
    Planner.RefreshSkillGateStatuses()
    PerfEnd("Planner.CheapRebuild")
    return stale
end

local function TryGardenPatch()
    local PS = StockPiler.PlanSnapshot
    local stale = PS and PS.Get and PS.Get()
    if type(stale) ~= "table" or type(stale.rows) ~= "table" or #stale.rows == 0 then
        return nil
    end
    if type(stale.ctx) ~= "table" then
        return nil
    end
    -- Same hold rule as CheapRebuild: garden patch used to publish a new snap key
    -- with allowWarmHave=false and no craftable stamp.
    if HoldHaveCacheQuiet() then
        return nil
    end
    local cur = ReadGens()
    if RecipeStructuralKey(stale.ctx) ~= RecipeStructuralKey(cur) then
        return nil
    end
    PerfBegin("Planner.GardenPatch")
    -- Reuse tips; flip restocking via live overlay; live potion counts; no Tips/Demand.
    PatchWatchRowsLiveCounts(stale.rows, {
        syncSnapshot = false,
        allowWarmHave = false,
    })
    if not RowsCraftableCurrentForSnap(stale.rows, cur.snapGen) then
        PerfEnd("Planner.GardenPatch")
        return nil
    end
    -- cacheOnly growing notes when Grow provides them
    local Grow = StockPiler.Grow
    if Grow and Grow.GrowingNotesForSpec then
        for i = 1, #stale.rows do
            local row = stale.rows[i]
            local tips = row and row.statusTipSlots
            if type(tips) == "table" then
                for t = 1, #tips do
                    local entry = tips[t]
                    if type(entry) == "table" and type(entry.spec) == "table" then
                        local notes = Grow.GrowingNotesForSpec(entry.spec, { cacheOnly = true })
                        if notes ~= nil then
                            entry.growingNotes = notes
                        end
                    end
                end
            end
        end
    end
    local key = RefreshStaleCtx(stale)
    local planGen = (tonumber(Planner._planGen) or 0) + 1
    Planner._planGen = planGen
    stale.planGen = planGen
    stale.cacheKey = key
    stale.builtAt = (type(GetGameTime) == "function" and GetGameTime()) or 0
    PublishPlan(stale, key, { gardenPatch = true })
    Planner.RefreshSkillGateStatuses()
    PerfEnd("Planner.GardenPatch")
    return stale
end

local function BuildFull(opts)
    opts = type(opts) == "table" and opts or {}
    Planner._demandDeferStore = nil
    PerfBegin("Planner.Build")
    BeginPlanCraftsMemo()
    PerfBegin("Build.WarmHave")
    if IsHaveCacheWarmForSnap() then
        -- prewarm hit
    else
        WarmSpecHaveCacheForWatches()
    end
    PerfEnd("Build.WarmHave")
    Planner._buildRows = nil
    Planner._buildPlanGen = nil
    Planner._demandDeferStore = nil
    Planner._demandNeedScratch = nil
    if Planner._buildSliceAbort ~= nil then
        ClearBuildScratch()
        PerfEnd("Planner.Build")
        return nil
    end
    local ctx = ReadGens()
    local Watch = StockPiler.Watch
    local watches = Watch and Watch.GetWatches and Watch.GetWatches() or {}
    local key = FormatCacheKey(ctx)
    local planGen = (tonumber(Planner._planGen) or 0) + 1
    Planner._planGen = planGen
    local slicing = Planner._buildYield == true
        and RunningCoroutine() ~= nil
        and RunningCoroutine() == Planner._buildSliceCo
    local ok, rows, seedBufferTipData, demand
    if slicing then
        -- Yields inside the row loop and the bag walk. pcall would block them.
        rows, seedBufferTipData, demand = BuildWatchRows(ctx, watches)
        if Planner._buildSliceAbort ~= nil or type(rows) ~= "table" then
            ClearBuildScratch()
            PerfEnd("Planner.Build")
            return nil
        end
        ok = true
    else
        ok, rows, seedBufferTipData, demand = pcall(BuildWatchRows, ctx, watches)
    end
    Planner._buildRows = nil
    Planner._buildPlanGen = nil
    Planner._demandDeferStore = nil
    Planner._demandNeedScratch = nil
    if ok ~= true then
        if StockPiler.Debug and StockPiler.Debug.ReportProtectedCallFailure then
            StockPiler.Debug.ReportProtectedCallFailure("Planner.BuildWatchRows", rows, true)
        end
        ClearBuildScratch()
        PerfEnd("Planner.Build")
        return nil
    end
    local plan = {
        planGen = planGen,
        cacheKey = key,
        ctx = ctx,
        rows = rows,
        seedBufferTipData = seedBufferTipData,
        builtAt = (type(GetGameTime) == "function" and GetGameTime()) or 0,
    }
    PublishPlan(plan, key, nil)
    Planner._buildYield = nil
    Planner._lazyWatchTips = nil
    Planner._buildSliceSuspended = nil
    if ClearSliceBudget then
        ClearSliceBudget()
    end
    PerfEnd("Planner.Build")
    return plan
end

----------------------------------------------------------------
-- Public API
----------------------------------------------------------------

--- Drops the per-frame settings-hash memo. Watch settings and skill pulses
--- call this so the plan key changes on the same game tick.
function Planner.InvalidateSettingsHashMemo()
    ClearSettingsHashMemo()
end

--- Bus handler for TRADE_SKILLS_CHANGED. Load pulses (trade-caps) and later
--- skill pulses both clear the memo. The scheduler still decides whether to
--- enqueue a rebuild.
function Planner.OnTradeSkillsChanged(_payload)
    -- trade-skill and trade-caps both drop the memo.
    ClearSettingsHashMemo()
end

function Planner.CacheKeyFromGens()
    return FormatCacheKey(ReadGens())
end

local function RefreshSharedSeedBuffer(rows)
    if PropagateSharedSeedBufferStatus(rows) == true then
        return true
    end
    return false
end

local function ApplyRowTipSideEffects(row)
    if type(row) ~= "table" then
        return
    end
    SyncTipSlotNeeds(row, row.craftsNeeded)
    local Grow = StockPiler.Grow
    local tips = row.statusTipSlots
    if Grow and Grow.GrowingNotesForSpec and type(tips) == "table" then
        for t = 1, #tips do
            local entry = tips[t]
            if type(entry) == "table" and type(entry.spec) == "table" then
                local notes = Grow.GrowingNotesForSpec(entry.spec, { cacheOnly = true })
                if notes ~= nil then
                    entry.growingNotes = notes
                end
            end
        end
    end
end

function Planner.EnsureWatchRowTip(row)
    if type(row) ~= "table" then
        return nil
    end
    if type(row.statusTipSlots) ~= "table" or #row.statusTipSlots == 0 then
        row._seedBufferUidSnapGen = nil
        FillWatchRowTips(row, Planner._lastDemand)
        ApplyRowTipSideEffects(row)
        local PS = StockPiler.PlanSnapshot
        local plan = PS and PS.Get and PS.Get()
        if type(plan) == "table" and type(plan.rows) == "table" then
            for i = 1, #plan.rows do
                if plan.rows[i] == row then
                    RefreshSharedSeedBuffer(plan.rows)
                    if type(plan.seedBufferTipData) ~= "table" then
                        plan.seedBufferTipData = BuildSeedBufferTipData({
                            previous = plan.seedBufferTipData,
                        })
                    end
                    break
                end
            end
        end
    end
    return row.statusTipSlots
end

function Planner.EnqueueLazyWatchTips()
    local PS = StockPiler.PlanSnapshot
    local plan = PS and PS.Get and PS.Get()
    local rows = type(plan) == "table" and plan.rows or nil
    if type(rows) ~= "table" or #rows == 0 then
        return false
    end
    local function fillOne(row)
        if type(row) ~= "table" then
            return
        end
        if type(row.statusTipSlots) == "table" and #row.statusTipSlots > 0 then
            row._seedBufferUidSnapGen = nil
            StampRowSeedBufferUids(row)
            return
        end
        row._seedBufferUidSnapGen = nil
        FillWatchRowTips(row, Planner._lastDemand)
        ApplyRowTipSideEffects(row)
    end
    local FW = StockPiler.FrameWork
    if not FW or not FW.Start then
        for i = 1, #rows do
            fillOne(rows[i])
        end
        RefreshSharedSeedBuffer(rows)
        plan.seedBufferTipData = BuildSeedBufferTipData({
            previous = plan.seedBufferTipData,
        })
        return true
    end
    FW.Start({
        id = "watch-row-tips",
        gen = tostring(plan.planGen or 0) .. ":" .. tostring(#rows),
        stepsPerFrame = 1,
        resume = function(state)
            local index = tonumber(state.index) or 1
            local last = math.min(#rows, index + 2)
            for i = index, last do
                fillOne(rows[i])
            end
            state.index = last + 1
            if state.index <= #rows then
                return "continue"
            end
            RefreshSharedSeedBuffer(rows)
            if type(plan) == "table" then
                plan.seedBufferTipData = BuildSeedBufferTipData({
                    previous = plan.seedBufferTipData,
                })
            end
            return "done"
        end,
    })
    return true
end

function Planner.BuildWatchRowTips(row, demand)
    if type(row) ~= "table" then
        return nil
    end
    FillWatchRowTips(row, demand or Planner._lastDemand)
    return row.statusTipSlots
end

function Planner.GetSeedBufferTip()
    local PS = StockPiler.PlanSnapshot
    local plan = PS and PS.Get and PS.Get()
    if type(plan) == "table" then
        return plan.seedBufferTipData
    end
    return nil
end

function Planner.BeginDemandSlice()
    return "continue"
end

function Planner.IsHaveCacheWarmForSnap()
    return IsHaveCacheWarmForSnap()
end

function Planner.WarmSpecHaveCacheForWatches()
    return WarmSpecHaveCacheForWatches()
end

--- FrameWork prewarm alias (must warm watched specs, not empty cache).
function Planner.WarmHave()
    return WarmSpecHaveCacheForWatches()
end

--- Frame-slice: collect+CountByUid this frame; bag pass next (see FrameWork.EnqueueWarmHave).
function Planner.BeginWarmHaveSlice()
    return BeginWarmHaveSlice()
end

function Planner.FinishWarmHaveSlice()
    return FinishWarmHaveSlice()
end

function Planner.CountItemsMatchingSpec(spec, opts)
    return CountItemsMatchingSpec(spec, opts)
end

function Planner.BuildBalancedSpecDemand(opts)
    return BuildBalancedSpecDemand(opts)
end

--- FrameWork demand prewarm. cacheOnly cannot fill a nil cache, so this
--- runs the real build and stores _demandCache.
function Planner.WarmDemand()
    Planner._demandPrewarmDue = nil
    Planner._demandPrewarmDueKey = nil
    return BuildBalancedSpecDemand()
end

--- True once when a quiet/orch hold served the previous have or demand counts.
--- The caller (hold end) uses this to decide whether those counts must be rebuilt.
function Planner.ConsumedHeldCounts()
    local used = Planner._heldCountsUsed == true
    Planner._heldCountsUsed = nil
    return used
end

function Planner.GetVendorBuyMeta()
    local meta = Planner._vendorBuyJobsMeta
    if type(meta) ~= "table" then
        return nil
    end
    return meta
end

function Planner.SetWatchListSource(fn)
    if type(fn) == "function" then
        Planner._watchListSource = fn
    else
        Planner._watchListSource = nil
    end
end

function Planner.CollectGrowFocus(rowsOpt)
    return CollectFocus("grow", rowsOpt)
end

--- Bust Have warm only (bag snap / orch-hold end). Forces re-warm before craftable.
function Planner.InvalidateHaveWarm()
    Planner._specHaveSnapGen = -1
    Planner._specHaveWarmedSnap = nil
    Planner._warmHaveSlice = nil
end

--- Quiet-end: force next EnsureHaveCache / demand build to refresh counts.
function Planner.InvalidateHaveCacheAfterQuiet()
    Planner.InvalidateHaveWarm()
    Planner._demandCacheKey = nil
    -- Live craftable must recount after plant/harvest quiet; otherwise Watch can
    -- sit on Restocking with stale craftable=0 until a force Build (/stp dumpall).
    local PS = StockPiler.PlanSnapshot
    local plan = PS and PS.Get and PS.Get()
    if type(plan) == "table" and type(plan.rows) == "table" then
        for i = 1, #plan.rows do
            local row = plan.rows[i]
            if type(row) == "table" then
                row._craftableSnapGen = -1
                row._craftableStructKey = nil
            end
        end
    end
    -- Drop cache key so Build cannot early-return a snap stamped without recount.
    if PS and PS.Invalidate then
        PS.Invalidate()
    end
end

--- Bust live craftable stamps so Watch recounts without waiting on a bag snap
--- (Optimistic / seed-buffer / skill toggles). Used by Watch settings UI.
function Planner.InvalidateCraftableStamps(extraRows)
    local function clearRows(rows)
        if type(rows) ~= "table" then
            return
        end
        for i = 1, #rows do
            local row = rows[i]
            if type(row) == "table" then
                row._craftableSnapGen = -1
                row._craftableStructKey = nil
            end
        end
    end
    local PS = StockPiler.PlanSnapshot
    local plan = PS and PS.Get and PS.Get()
    if type(plan) == "table" then
        clearRows(plan.rows)
    end
    clearRows(extraRows)
    Planner._demandCacheKey = nil
end

function Planner.BottleGap(target, stock, craftable)
    return BottleGap(target, stock, craftable)
end

function Planner.WatchStillNeedsGrow(potion, recipe, target, watchKey)
    return WatchStillNeedsGrow(potion, recipe, target, watchKey)
end

function Planner.CollectAutoGrowSeedLines()
    return CollectAutoGrowSeedLines()
end

--- Vendor AutoBuy jobs: hydrated spec + exemplar uid; match by MS.Matches not uid-only.
function Planner.CollectVendorBuyJobs(opts)
    opts = type(opts) == "table" and opts or {}
    local jobs = {}
    Planner._vendorBuyJobsMeta = {
        source = "none",
        maxBottleGap = nil,
        focusWatchCount = 0,
    }
    local Inv = StockPiler.Inventory
    if Inv and Inv._ready ~= true then
        return jobs
    end
    local MS = MaterialSpec()
    local Caps = StockPiler.TradeSkillCaps
    local allowPlantBuys = opts.allowPlantBuys
    if allowPlantBuys == nil then
        allowPlantBuys = not (Caps and Caps.CanAutoGrow and Caps.CanAutoGrow() == true)
    end

    local function AddBuyNeed(pool, spec, role, need, bottleGap)
        if type(spec) ~= "table" or (tonumber(need) or 0) <= 0 then
            return
        end
        role = role or spec.role
        if SpecIsHarvestByproduct(spec) then
            return
        end
        local kind = "buy"
        -- Skip cult plants and butcher/vendor twins while AutoGrow can plant them.
        if SpecCanAutoGrowProgress(spec, role) then
            kind = "plant"
            if allowPlantBuys ~= true then
                return
            end
        end
        local specKey = SpecKey(spec)
        if specKey == nil then
            return
        end
        local row = pool[specKey]
        if row == nil then
            local uid = tonumber(spec.uid) or tonumber(spec.boundUid) or 0
            local label = (MS and MS.Label and MS.Label(spec)) or tostring(role or "mat")
            row = {
                kind = kind,
                growable = kind == "plant",
                spec = spec,
                role = role or spec.role,
                uid = uid,
                uniqueID = uid,
                specKey = specKey,
                acquireKey = "sk:" .. tostring(specKey),
                absolute = 0,
                label = label,
                name = label,
                bottleGap = nil,
            }
            pool[specKey] = row
        end
        row.absolute = (tonumber(row.absolute) or 0) + (tonumber(need) or 0)
        local gap = tonumber(bottleGap)
        if gap ~= nil and (row.bottleGap == nil or gap > row.bottleGap) then
            row.bottleGap = gap
        end
    end

    local function JobsFromPool(pool)
        local out = {}
        local specs = {}
        for _, row in pairs(pool) do
            specs[#specs + 1] = row.spec
        end
        WarmSpecHaveCache(specs)
        for specKey, row in pairs(pool) do
            local have = CountItemsMatchingSpec(row.spec)
            local deficit = math.max(0, (tonumber(row.absolute) or 0) - have)
            if deficit > 0 then
                out[#out + 1] = {
                    kind = row.kind or "buy",
                    growable = row.growable == true or row.kind == "plant",
                    spec = row.spec,
                    role = row.role,
                    uid = row.uid,
                    uniqueID = row.uid,
                    have = have,
                    need = row.absolute,
                    deficit = deficit,
                    specKey = specKey,
                    acquireKey = row.acquireKey,
                    label = row.label,
                    name = row.label,
                    bottleGap = row.bottleGap,
                }
            end
        end
        table.sort(out, function(a, b)
            local ar = (a and a.role) or ""
            local br = (b and b.role) or ""
            if ar == "container" and br ~= "container" then
                return true
            end
            if br == "container" and ar ~= "container" then
                return false
            end
            local ad = tonumber(a and a.deficit) or 0
            local bd = tonumber(b and b.deficit) or 0
            if ad ~= bd then
                return ad > bd
            end
            return ToNarrow(a and (a.label or a.name)) < ToNarrow(b and (b.label or b.name))
        end)
        return out
    end

    local function FillPoolFromWatches(pool, watches)
        if type(watches) ~= "table" then
            return
        end
        local entries = {}
        for i = 1, #watches do
            local fw = watches[i]
            if type(fw) == "table" then
                entries[#entries + 1] = {
                    key = fw.potionKey,
                    tier = fw.priorityTier,
                    target = fw.target,
                    have = fw.stock,
                    recipe = fw.recipe,
                    uid = fw.uniqueID,
                    bottleGap = fw.bottleGap,
                    stillNeeds = true,
                    raw = fw,
                }
            end
        end
        local groups = GroupWatchesByOutputUid(entries)
        for gi = 1, #groups do
            local group = groups[gi]
            local fw = group.winner and group.winner.raw or nil
            local recipe = group.recipe
            local deficit = math.max(0, (tonumber(group.maxTarget) or 0) - (tonumber(group.have) or 0))
            if type(recipe) == "table" and deficit > 0 then
                local RS = RecipeSpec()
                if RS and RS.HydrateRecipeSlots then
                    RS.HydrateRecipeSlots(recipe)
                end
                local outUid = tonumber(group.uid) or 0
                if outUid <= 0 then
                    outUid = tonumber(fw and fw.uniqueID) or tonumber(fw and fw.outputUid) or 0
                end
                local craftsNeeded = CraftsNeededForDeficit(deficit, recipe, outUid)
                local slots = recipe.slots or {}
                local gap = (fw and fw.bottleGap) or group.bottleGap
                for j = 1, #slots do
                    local slot = slots[j]
                    local spec = ResolveSlotSpec(slot)
                    if type(spec) == "table" then
                        local per = EffectivePerCraft(slot, slots)
                        AddBuyNeed(
                            pool,
                            spec,
                            slot.role or spec.role,
                            craftsNeeded * per,
                            gap
                        )
                    end
                end
            end
        end
    end

    -- All buy candidates (not atMax-only): SpecKey pool sums shared flasks/mats.
    local focus = CollectFocus("buy")
    local watches = type(focus.allWatches) == "table" and focus.allWatches or focus.watches
    local watchCount = type(watches) == "table" and #watches or 0
    Planner._vendorBuyJobsMeta.maxBottleGap = focus.maxBottleGap
    Planner._vendorBuyJobsMeta.focusWatchCount = watchCount
    local pool = {}
    FillPoolFromWatches(pool, watches)
    jobs = JobsFromPool(pool)
    Planner._vendorBuyJobsMeta.source = (#jobs > 0) and "all" or "none"
    return jobs
end

function Planner.PatchWatchRowsLiveCounts(rows, opts)
    return PatchWatchRowsLiveCounts(rows, opts)
end

--- Shared live recount for Buy, Brew, Ui, and TabWatch (PLN-3 / PLN-18).
--- Patches plan.rows, then a distinct unbound listData with syncSnapshot false
--- so the snapshot is not written twice. Callers keep their own UI events.
--- opts.clearClosedSnap, opts.invalidateStamps, plus the patch flags
--- allowWarmHave, syncSnapshot, forceRecountCraftable, and recountCraftable.
function Planner.LiveRecount(opts)
    opts = type(opts) == "table" and opts or {}
    if opts.clearClosedSnap == true then
        Planner._closedLiveSnapGen = nil
    end
    local PS = StockPiler.PlanSnapshot
    local plan = PS and PS.Get and PS.Get()
    local planRows = type(plan) == "table" and plan.rows or nil
    local listData = opts.listData
    local boundRows = opts.boundPlanRows
    if listData == nil and type(Planner._watchListSource) == "function" then
        local srcOk, srcList, srcBound = pcall(Planner._watchListSource)
        if srcOk == true then
            listData = srcList
            if boundRows == nil then
                boundRows = srcBound
            end
        end
    end
    if opts.invalidateStamps == true and Planner.InvalidateCraftableStamps then
        Planner.InvalidateCraftableStamps(listData)
    end
    -- Stamp forced recount so BrewCatchup / RequestForcedWatchRecount can skip
    -- a second Status.Craftable pass on the same snapGen+frame.
    if opts.forceRecountCraftable == true then
        local Inv = StockPiler.Inventory
        local snap = Inv and Inv.GetSnapGen and tonumber(Inv.GetSnapGen()) or 0
        local frame = tonumber(StockPiler.FrameCounter) or 0
        Planner._forcedRecountStamp = tostring(snap) .. ":" .. tostring(frame)
    end
    local patchOpts = {
        allowWarmHave = opts.allowWarmHave,
        syncSnapshot = opts.syncSnapshot,
        forceRecountCraftable = opts.forceRecountCraftable,
        recountCraftable = opts.recountCraftable,
    }
    if type(planRows) == "table" and #planRows > 0 then
        PatchWatchRowsLiveCounts(planRows, patchOpts)
    end
    if type(listData) == "table" and #listData > 0 and listData ~= planRows then
        local bound = boundRows
        -- A sorted copy shares plan row objects, so the plan patch is enough.
        -- preferPrev can keep the bound flag on a list of different row objects.
        local shares = type(planRows) == "table" and bound == planRows
        if shares then
            local seen = {}
            for i = 1, #planRows do
                local row = planRows[i]
                if type(row) == "table" then
                    seen[row] = true
                end
            end
            for i = 1, #listData do
                local row = listData[i]
                if type(row) ~= "table" or seen[row] ~= true then
                    shares = false
                    break
                end
            end
        end
        if shares ~= true then
            PatchWatchRowsLiveCounts(listData, {
                allowWarmHave = opts.allowWarmHave,
                syncSnapshot = false,
                forceRecountCraftable = opts.forceRecountCraftable,
                recountCraftable = opts.recountCraftable,
            })
        end
    end
    Planner.RefreshSkillGateStatuses()
    Planner._liveGen = (tonumber(Planner._liveGen) or 0) + 1
    return Planner._liveGen
end

--- True when LiveRecount already forced craftable this snapGen+frame.
function Planner.ForcedRecountMatches(snapGen, frame)
    local stamp = Planner._forcedRecountStamp
    if stamp == nil then
        return false
    end
    snapGen = tonumber(snapGen) or 0
    frame = tonumber(frame) or 0
    return stamp == (tostring(snapGen) .. ":" .. tostring(frame))
end

--- Flip Enable AutoGrow <-> Restocking on current plan + optional extra rows (listData).
--- Call from Watch UI after master/per-watch AutoGrow toggles - do not wait for rebuild.
function Planner.ReconcileAutoGrowStatusesNow(extraRows)
    local changed = false
    local PS = StockPiler.PlanSnapshot
    local plan = PS and PS.Get and PS.Get()
    if type(plan) == "table" and type(plan.rows) == "table" then
        if ReconcileAutoGrowStatusesForRows(plan.rows) then
            changed = true
        end
        -- Armed set changed -> Shared contest membership must refresh.
        if PolishSharedContest(plan.rows) then
            changed = true
        end
        if RefreshSkillUpWatchRows(plan.rows, { syncSnapshot = true }) then
            changed = true
        end
    end
    if type(extraRows) == "table" and extraRows ~= (plan and plan.rows) then
        if ReconcileAutoGrowStatusesForRows(extraRows) then
            changed = true
        end
        if PolishSharedContest(extraRows) then
            changed = true
        end
        if RefreshSkillUpWatchRows(extraRows, { syncSnapshot = false }) then
            changed = true
        end
    end
    if changed then
        InvalidateFocusCaches("autogrow-reconcile")
    end
    return changed
end

--- Priority-only soft change: refresh shared contest + focus (no BuildFull).
function Planner.AfterPrioritySoftChange(extraRows)
    local PS = StockPiler.PlanSnapshot
    local plan = PS and PS.Get and PS.Get()
    local seen = {}
    local function polish(rows)
        if type(rows) ~= "table" or seen[rows] then
            return
        end
        seen[rows] = true
        PolishSharedContest(rows)
    end
    if type(plan) == "table" then
        polish(plan.rows)
    end
    polish(extraRows)
    InvalidateFocusCaches("priority-soft")
end

function Planner.HasReadyToCraft()
    local Brew = StockPiler.Brew
    if Brew and Brew.HasReadyToCraft then
        return Brew.HasReadyToCraft() == true
    end
    return HasReadyToCraftFromPlan()
end

--- Closed-window: patch plan.rows Status without WarmHave / list paint.
--- Returns whether HasReadyToCraft flipped (caller may RequestFooterRefresh).
function Planner.SyncLiveStatusClosedWindow()
    local snapGen = CurrentSnapGen()
    if snapGen > 0 and Planner._closedLiveSnapGen == snapGen then
        return false
    end
    local PS = StockPiler.PlanSnapshot
    local plan = PS and PS.Get and PS.Get()
    if type(plan) ~= "table" or type(plan.rows) ~= "table" or #plan.rows == 0 then
        return false
    end
    if snapGen > 0 then
        Planner._closedLiveSnapGen = snapGen
    end
    local before = Planner.HasReadyToCraft()
    PatchWatchRowsLiveCounts(plan.rows, {
        syncSnapshot = false,
        allowWarmHave = false,
    })
    local Brew = StockPiler.Brew
    if Brew and Brew.InvalidateCanBrewCache then
        Brew.InvalidateCanBrewCache()
    end
    local after = Planner.HasReadyToCraft()
    local flipped = before ~= after
    if flipped then
        local Bus = StockPiler.EventBus
        local E = StockPiler.Events
        if Bus and Bus.Fire and E and E.CRAFT_READY_CHANGED then
            Bus.Fire(E.CRAFT_READY_CHANGED, { ready = after == true })
        end
        if Bus and Bus.FireFooterDirty then
            Bus.FireFooterDirty({ reason = "closed-live" })
        end
    end
    if Brew and Brew.MaybeNotifyBrewReady then
        Brew.MaybeNotifyBrewReady()
    end
    if StockPiler.Grow and StockPiler.Grow.MaybeNotifyAutoGrowStall then
        StockPiler.Grow.MaybeNotifyAutoGrowStall()
    end
    return flipped
end

local function TryFastPlan(opts)
    opts = type(opts) == "table" and opts or {}
    local PS = StockPiler.PlanSnapshot
    if opts.force ~= true and PS and PS.GetCacheKey then
        local key = Planner.CacheKeyFromGens()
        if PS.GetCacheKey() == key then
            local cached = PS.Get and PS.Get()
            -- Miss when potion craftable lags the bag snap (quiet-end clear or
            -- a prior publish that advanced the key without recounting).
            if type(cached) == "table" and RowsCraftableCurrentForSnap(cached.rows) then
                -- Skill points do not change the cache key. Re-check watched
                -- need_skill / need_apothecary gates without BuildFull.
                Planner.RefreshSkillGateStatuses()
                return cached
            end
        end
    end
    if opts.force ~= true then
        local cheap = TryCheapRebuild()
        if type(cheap) == "table" then
            return cheap
        end
        local patched = TryGardenPatch()
        if type(patched) == "table" then
            return patched
        end
    end
    return nil
end

local function CanSliceBuild()
    return type(coroutine) == "table"
        and type(coroutine.create) == "function"
        and type(coroutine.resume) == "function"
        and type(coroutine.status) == "function"
end

--- Drop an in-flight sliced build without publishing. Safe from outside the coroutine.
function Planner.AbortBuildSlice()
    if RunningCoroutine() ~= nil and RunningCoroutine() == Planner._buildSliceCo then
        Planner._buildSliceAbort = "abort"
        return
    end
    Planner._buildSliceCo = nil
    Planner._buildSliceToken = nil
    Planner._buildSliceAbort = nil
    Planner._buildSliceSuspended = nil
    ClearBuildScratch()
end

local function BrewBlocksSliceFinish()
    local Orch = StockPiler.Orchestrator
    return Orch and Orch.IsBrewSessionActive and Orch.IsBrewSessionActive() == true
end

local function EndOpenBuildPerf()
    PerfEnd("Build.WarmHave")
    PerfEnd("Build.Demand")
    PerfEnd("Build.Status")
    PerfEnd("Build.Tips")
    PerfEnd("Planner.Build")
end

ClearSliceBudget = function()
    Planner._buildSliceRestarts = 0
    Planner._buildSliceArmedAt = 0
    Planner._buildSliceErrorLogged = nil
    Planner._buildSliceRetryAt = nil
end

local function ArmBuildSliceClock()
    if (tonumber(Planner._buildSliceArmedAt) or 0) <= 0 then
        Planner._buildSliceArmedAt = GameNow()
    end
end

--- Restarts, or the wall clock since this rebuild was armed. After the cap
--- the next attempt finishes in one call instead of starting over.
function Planner.BuildSliceOverCap()
    local cap = tonumber(Planner.BUILD_SLICE_RESTART_CAP) or 3
    if cap < 1 then
        cap = 1
    end
    if (tonumber(Planner._buildSliceRestarts) or 0) >= cap then
        return true
    end
    local budget = tonumber(Planner.BUILD_SLICE_BUDGET_SEC) or 8
    local armed = tonumber(Planner._buildSliceArmedAt) or 0
    local now = GameNow()
    if budget > 0 and armed > 0 and now > 0 and (now - armed) >= budget then
        return true
    end
    return false
end

function Planner.NoteBuildSliceRestart()
    ArmBuildSliceClock()
    Planner._buildSliceRestarts = (tonumber(Planner._buildSliceRestarts) or 0) + 1
    return Planner.BuildSliceOverCap() == true
end

function Planner.BuildSliceRetryAt()
    return tonumber(Planner._buildSliceRetryAt) or 0
end

local function LogBuildSliceError(err)
    if Planner._buildSliceErrorLogged == true then
        return
    end
    Planner._buildSliceErrorLogged = true
    local Debug = StockPiler.Debug
    if Debug and Debug.ReportProtectedCallFailure then
        Debug.ReportProtectedCallFailure("Planner.BuildWatchRows", err, true)
    elseif Debug and Debug.LogAlways then
        Debug.LogAlways("plan-build-slice-error " .. tostring(err))
    end
end

local function MarkBuildSliceRetry()
    local now = GameNow()
    local wait = tonumber(Planner.BUILD_SLICE_ERROR_BACKOFF_SEC) or 2
    if wait < 0 then
        wait = 0
    end
    if now > 0 then
        Planner._buildSliceRetryAt = now + wait
    else
        Planner._buildSliceRetryAt = nil
    end
end

--- Drop the partial cursor and build the current plan in one call.
function Planner.FinishBuildSliceSync()
    Planner._buildSliceCo = nil
    Planner._buildSliceToken = nil
    Planner._buildSliceAbort = nil
    Planner._buildYield = nil
    Planner._buildSliceSuspended = nil
    ClearBuildScratch()
    local fast = TryFastPlan({})
    if type(fast) == "table" then
        ClearSliceBudget()
        return fast
    end
    Planner._lazyWatchTips = true
    local plan = BuildFull({})
    Planner._lazyWatchTips = nil
    return plan
end

local function AbandonStaleBuildSlice()
    local over = Planner.NoteBuildSliceRestart()
    Planner._buildSliceCo = nil
    Planner._buildSliceToken = nil
    Planner._buildSliceAbort = nil
    ClearBuildScratch()
    -- A brew frame stays light. The cap stays latched so the next eligible
    -- rebuild finishes in one call instead of starting another walk.
    if over == true and BrewBlocksSliceFinish() ~= true then
        local plan = Planner.FinishBuildSliceSync()
        if type(plan) == "table" then
            return "done"
        end
        EndOpenBuildPerf()
        LogBuildSliceError("plan-build-sync-failed")
        MarkBuildSliceRetry()
        return "retry"
    end
    return "restart"
end

local function FailBuildSlice(err)
    Planner._buildSliceCo = nil
    Planner._buildSliceToken = nil
    Planner._buildSliceAbort = nil
    ClearBuildScratch()
    EndOpenBuildPerf()
    LogBuildSliceError(err)
    MarkBuildSliceRetry()
    return "retry"
end

--- Scheduler entry. Fast paths publish and return "done". A full rebuild
--- returns "continue" until PumpBuildSlice finishes the same plan a sync Build would.
function Planner.BeginBuildSlice()
    if Planner._buildSliceCo ~= nil and RunningCoroutine() ~= Planner._buildSliceCo then
        Planner.AbortBuildSlice()
    end
    local fast = TryFastPlan({})
    if type(fast) == "table" then
        ClearSliceBudget()
        return "done"
    end
    if not CanSliceBuild() then
        Planner._lazyWatchTips = true
        local plan = BuildFull({})
        Planner._lazyWatchTips = nil
        if type(plan) == "table" then
            return "done"
        end
        return "done"
    end
    ArmBuildSliceClock()
    Planner._lazyWatchTips = true
    Planner._buildYield = true
    Planner._buildSliceAbort = nil
    Planner._buildSliceSuspended = nil
    Planner._buildSliceToken = FormatCacheKey(ReadGens())
    Planner._buildSliceCo = coroutine.create(function()
        return BuildFull({})
    end)
    return "continue"
end

--- One chunk of a sliced BuildFull.
--- "restart" drops the partial plan. "retry" keeps the rebuild pending.
function Planner.PumpBuildSlice()
    local co = Planner._buildSliceCo
    if co == nil then
        return "done"
    end
    if coroutine.status(co) == "dead" then
        Planner._buildSliceCo = nil
        return "done"
    end
    if BuildSliceStale() then
        return AbandonStaleBuildSlice()
    end
    local ok, err = coroutine.resume(co)
    if not ok then
        return FailBuildSlice(err)
    end
    if Planner._buildSliceAbort ~= nil then
        return AbandonStaleBuildSlice()
    end
    if coroutine.status(co) == "dead" then
        Planner._buildSliceCo = nil
        Planner._buildSliceToken = nil
        Planner._buildSliceAbort = nil
        return "done"
    end
    return "continue"
end

function Planner.Build(opts)
    opts = type(opts) == "table" and opts or {}
    if RunningCoroutine() ~= Planner._buildSliceCo then
        local FW = StockPiler.FrameWork
        if FW and FW.IsActive and FW.IsActive("plan-build") and FW.Cancel then
            FW.Cancel("plan-build")
        elseif Planner._buildSliceCo ~= nil then
            Planner.AbortBuildSlice()
        end
        Planner._buildYield = nil
    end
    local fast = TryFastPlan(opts)
    if type(fast) == "table" then
        return fast
    end
    return BuildFull(opts)
end

--- Prefer PlanSnapshot.GetOrBuild so refresh=false never sync-builds while pending.
function Planner.GetOrBuild(opts)
    opts = type(opts) == "table" and opts or {}
    local PS = StockPiler.PlanSnapshot
    if PS and PS.GetOrBuild then
        return PS.GetOrBuild(opts)
    end
    local Sch = StockPiler.Scheduler
    if Sch and Sch.IsPlanRebuildPending and Sch.IsPlanRebuildPending() == true then
        return PS and PS.Get and PS.Get() or nil
    end
    if opts.refresh == false then
        if Sch and Sch.EnqueuePlanRebuild then
            Sch.EnqueuePlanRebuild({ nudge = true })
        end
        return PS and PS.Get and PS.Get() or nil
    end
    return Planner.Build(opts)
end

----------------------------------------------------------------
-- Dumps
----------------------------------------------------------------

local function DumpWatchRows(emit, rows, planMeta)
    planMeta = type(planMeta) == "table" and planMeta or {}
    emit("=== StockPiler watchplan ===")
    emit(string.format(
        "  watches=%d planGen=%s",
        type(rows) == "table" and #rows or 0,
        tostring(planMeta.planGen or Planner._planGen or 0)
    ))
    if type(rows) ~= "table" then
        emit("=== end watchplan ===")
        return
    end
    for i = 1, #rows do
        local row = rows[i]
        if type(row) == "table" then
            local gap = tonumber(row.bottleGap)
            if gap == nil then
                gap = BottleGap(row.potionMin or row.target, row.potionHave, row.craftable)
            end
            emit(string.format(
                "  [%d] %s key=%s status=%s stock=%s/%s deficit=%s craftable=%s shared=%s bottleGap=%s autoGrow=%s",
                i,
                ToNarrow(row.name),
                tostring(row.potionKey or ""),
                tostring(row.statusKey or ""),
                tostring(row.potionHave or 0),
                tostring(row.potionMin or row.target or 0),
                tostring(row.potionDeficit or 0),
                tostring(row.craftable or 0),
                tostring(row.craftableShared == true),
                tostring(gap),
                tostring(row.autoGrow == true)
            ))
            if row.statusText ~= nil then
                emit("      statusText=" .. ToNarrow(row.statusText))
            end
            if row.kind == "plant" or row.isPlantWatch == true then
                emit(string.format(
                    "      plantUid=%s seedUid=%s",
                    tostring(row.plantUid or 0),
                    tostring(row.seedUid or 0)
                ))
            end
            local seedUids = row.seedBufferSeedUids
            if type(seedUids) == "table" and #seedUids > 0 then
                local parts = {}
                for u = 1, #seedUids do
                    local uid = tonumber(seedUids[u]) or 0
                    local credit = 0
                    local Refine = StockPiler.Refine
                    if uid > 0 and Refine and Refine.GetSeedBudget then
                        local b = Refine.GetSeedBudget(uid)
                        credit = tonumber(b and b.credit) or 0
                    end
                    parts[#parts + 1] = tostring(uid) .. "@" .. tostring(credit)
                end
                emit("      seedBufferUids=" .. table.concat(parts, ","))
            end
            local plantBuf = row.seedBufferPlantUids
            if type(plantBuf) == "table" and #plantBuf > 0 then
                local parts = {}
                local Inv = StockPiler.Inventory
                for u = 1, #plantBuf do
                    local uid = tonumber(plantBuf[u]) or 0
                    local credit = Inv and Inv.CountByUid and tonumber(Inv.CountByUid(uid)) or 0
                    parts[#parts + 1] = tostring(uid) .. "@" .. tostring(credit)
                end
                emit("      seedBufferPlantUids=" .. table.concat(parts, ","))
            end
            local tips = row.statusTipSlots
            if type(tips) == "table" then
                for t = 1, #tips do
                    local e = tips[t]
                    if type(e) == "table" then
                        emit(string.format(
                            "      slot role=%s kind=%s have=%s need=%s key=%s note=%s refine=%s",
                            tostring(e.role or "?"),
                            tostring(e.kind or "?"),
                            tostring(e.have or 0),
                            tostring(e.need or 0),
                            tostring(
                                (e.spec and StockPiler.MaterialSpec and StockPiler.MaterialSpec.Key
                                    and StockPiler.MaterialSpec.Key(e.spec))
                                    or e.specKey
                                    or ""
                            ),
                            tostring(e.note or ""),
                            tostring(e.needsRefine == true)
                        ))
                    end
                end
            end
        end
    end
    emit("=== end watchplan ===")
end

function Planner.DumpWatchPlan(emit)
    emit = MakeEmit(emit)
    local watches = StockPiler.Watch and StockPiler.Watch.GetWatches and StockPiler.Watch.GetWatches() or {}
    local enabledN = 0
    local stubN = 0
    if type(watches) == "table" then
        for _, w in pairs(watches) do
            if type(w) == "table" then
                if w.enabled == true then
                    enabledN = enabledN + 1
                else
                    stubN = stubN + 1
                end
            end
        end
    end
    emit(string.format("  enabledWatches=%d disabledStubs=%d", enabledN, stubN))
    local plan = nil
    if StockPiler.Planner and StockPiler.Planner.Build then
        plan = StockPiler.Planner.Build({ force = true })
    else
        local PS = StockPiler.PlanSnapshot
        plan = PS and PS.Get and PS.Get()
    end
    DumpWatchRows(emit, plan and plan.rows, plan)
end

function Planner.Dump(emit)
    emit = MakeEmit(emit)
    local g = ReadGens()
    emit("=== StockPiler plan ===")
    emit(string.format(
        "  key=%s warmHave=%s planGen=%s",
        Planner.CacheKeyFromGens(),
        tostring(IsHaveCacheWarmForSnap()),
        tostring(Planner._planGen or 0)
    ))
    emit(string.format(
        "  gens snap=%s garden=%s refine=%s watch=%s know=%s settings=%s",
        tostring(g.snapGen), tostring(g.gardenGen), tostring(g.refineGen),
        tostring(g.watchGen), tostring(g.knowledgeGen), tostring(g.settingsHash)
    ))
    emit(string.format("  hasReady=%s", tostring(Planner.HasReadyToCraft())))
    local PS = StockPiler.PlanSnapshot
    local plan = PS and PS.Get and PS.Get()
    DumpWatchRows(emit, plan and plan.rows, plan)
    emit("=== end plan ===")
end

function Planner.DumpGrowPlan(emit)
    emit = MakeEmit(emit)
    emit("=== StockPiler growplan ===")
    local focus = CollectFocus("grow")
    emit(string.format(
        "  maxBottleGap=%s focusWatches=%d autoGrowMaster=%s fromPlan=%s planGen=%s",
        tostring(focus.maxBottleGap),
        type(focus.watches) == "table" and #focus.watches or 0,
        tostring(StockPiler.Watch and StockPiler.Watch.IsAutoGrowEnabled
            and StockPiler.Watch.IsAutoGrowEnabled()),
        tostring(focus.fromPlan == true),
        tostring(focus.planGen or 0)
    ))
    local bad = 0
    if type(focus.watches) == "table" then
        for i = 1, #focus.watches do
            local w = focus.watches[i]
            emit(string.format(
                "  focus[%d] %s gap=%s stock=%s/%s craftable=%s shared=%s status=%s",
                i,
                ToNarrow(w.name),
                tostring(w.bottleGap),
                tostring(w.stock),
                tostring(w.target),
                tostring(w.craftable),
                tostring(w.craftableShared == true),
                tostring(w.statusKey or "")
            ))
            local key = tostring(w.potionKey or "")
            if not WatchWantsAutoGrow(key, nil) then
                bad = bad + 1
                emit("      ASSERT fail not-armed key=" .. key)
            else
                local gap = tonumber(w.bottleGap) or 0
                local okStill = gap > 0 or w.craftableShared == true
                    or tostring(w.statusKey or "") == "need_seeds"
                    or tostring(w.statusKey or "") == "buy_ingredients"
                if not okStill then
                    bad = bad + 1
                    emit("      ASSERT fail no-gap/shared/need_seeds key=" .. key)
                end
            end
        end
    end
    emit(string.format("  focusAssertFails=%d", bad))
    local demand = BuildBalancedSpecDemand()
    local n = 0
    local SM = StockPiler.SeedMap
    local Grow = StockPiler.Grow
    emit(string.format(
        "  resinFeedstock=%s",
        tostring(type(demand) == "table" and demand._resinFeedstock)
    ))
    for _, row in pairs(demand) do
        if type(row) == "table" and type(row.spec) == "table" then
            n = n + 1
            local isByproduct = row.isByproduct == true
                or (SM and SM.IsHarvestByproduct and SM.IsHarvestByproduct(row.spec) == true)
            local convertExtra = tonumber(row.byproductConvertExtra) or 0
            local show = (tonumber(row.deficit) or 0) > 0 or convertExtra > 0 or isByproduct
            if show then
                local plantUid = tonumber(row.plantUid) or 0
                local seedUid = tonumber(row.seedUid) or 0
                local resolveNote = ""
                if isByproduct then
                    resolveNote = " convert-byproduct"
                elseif plantUid <= 0 then
                    resolveNote = " no-plant-uid"
                elseif seedUid <= 0 then
                    resolveNote = " no-seed"
                end
                if convertExtra > 0 then
                    resolveNote = resolveNote .. " convertExtra=" .. tostring(convertExtra)
                end
                local brewAbs = tonumber(row.brewAbsolute)
                if brewAbs == nil then
                    brewAbs = tonumber(row.absolute) or 0
                end
                emit(string.format(
                    "  demand %s role=%s have=%s abs=%s brewAbs=%s short=%s plantUid=%s seedUid=%s%s",
                    tostring(row.specKey),
                    tostring(row.role),
                    tostring(row.have),
                    tostring(row.absolute),
                    tostring(brewAbs),
                    tostring(row.craftsShort),
                    tostring(plantUid),
                    tostring(seedUid),
                    resolveNote
                ))
            end
        end
    end
    emit(string.format("  demandSpecs=%d", n))
    if Grow and Grow.GetPlantJob then
        local job = Grow.GetPlantJob()
        if type(job) == "table" then
            emit(string.format(
                "  plantJob mode=%s role=%s seedUid=%s plantUid=%s reason=%s craftsShort=%s bottleneck=%s share=%s",
                tostring(job.pickMode),
                tostring(job.role),
                tostring(job.seedUid),
                tostring(job.plantUid),
                tostring(job.plantReason),
                tostring(job.craftsShort),
                tostring(job.bottleneckScore),
                tostring(job.focusShare)
            ))
        else
            local nilReason = "unplantable"
            if Grow.HasEmptyPlot and Grow.HasEmptyPlot() ~= true then
                nilReason = "plots-busy"
            else
                local anyShort = false
                local anyGrowableShort = false
                local anyBuyOnlyShort = false
                local anyPlantUid = false
                local anySeed = false
                local anyBagSeed = false
                local anyRefineFirst = false
                local Refine = StockPiler.Refine
                for _, row in pairs(demand) do
                    if type(row) == "table" and type(row.spec) == "table"
                        and (tonumber(row.craftsShort) or 0) > 0
                    then
                        anyShort = true
                        local growable = SM and SM.IsGrowableSpec and SM.IsGrowableSpec(row.spec) == true
                        local byproduct = row.isByproduct == true
                            or (SM and SM.IsHarvestByproduct and SM.IsHarvestByproduct(row.spec) == true)
                        if growable == true and byproduct ~= true then
                            anyGrowableShort = true
                            local pUid = tonumber(row.plantUid) or 0
                            if pUid <= 0 and SM.FindPlantUidForSpec then
                                pUid = tonumber(SM.FindPlantUidForSpec(row.spec)) or 0
                            end
                            if pUid > 0 then
                                anyPlantUid = true
                            end
                            local sUid = tonumber(row.seedUid) or 0
                            if sUid <= 0 and SM.ResolveSeedForSpec then
                                local seed = SM.ResolveSeedForSpec(row.spec)
                                sUid = type(seed) == "table" and (tonumber(seed.uniqueID or seed.uid) or 0) or 0
                            end
                            if sUid > 0 then
                                anySeed = true
                                local Inv = StockPiler.Inventory
                                local bag = Inv and Inv.CountByUid and tonumber(Inv.CountByUid(sUid)) or 0
                                if bag > 0 then
                                    anyBagSeed = true
                                elseif pUid > 0 and Refine and Refine.CountRefinablePlants then
                                    local refn = tonumber(Refine.CountRefinablePlants(pUid, row.spec)) or 0
                                    if refn > 0 then
                                        anyRefineFirst = true
                                    end
                                end
                            elseif pUid > 0 and Refine and Refine.CountRefinablePlants then
                                local refn = tonumber(Refine.CountRefinablePlants(pUid, row.spec)) or 0
                                if refn > 0 then
                                    anyRefineFirst = true
                                end
                            end
                        else
                            anyBuyOnlyShort = true
                        end
                    end
                end
                if not anyShort then
                    nilReason = "no-demand-short"
                elseif not anyGrowableShort then
                    -- Flasks / butcher / resin only - grow correctly handed off.
                    -- plant_stock may still run (soft gate); GetPlantJob above would
                    -- have returned a job if so - nil here means plant floors also idle.
                    nilReason = anyBuyOnlyShort and "buy-only-short" or "no-growable-short"
                elseif not anyPlantUid then
                    nilReason = "no-plant-uid"
                elseif anyRefineFirst and not anyBagSeed then
                    nilReason = "refine-first"
                elseif not anySeed then
                    nilReason = "no-seed"
                elseif not anyBagSeed then
                    nilReason = "no-bag-seed"
                elseif anyBuyOnlyShort then
                    -- Growables + bag seeds exist but picker still nil (buffer/fill gate etc.).
                    nilReason = "picker-nil-with-buy-short"
                end
            end
            local SkillUp = StockPiler.SkillUp
            local suNote = ""
            if SkillUp and SkillUp.PickPlantJob then
                local su = SkillUp.PickPlantJob()
                if type(su) == "table" and (tonumber(su.seedUid) or 0) > 0 then
                    suNote = string.format(
                        " skillupJob seedUid=%s (Grow cache missed SkillUp)",
                        tostring(su.seedUid)
                    )
                end
            end
            local Sch = StockPiler.Scheduler
            local settleNote = ""
            if Sch then
                settleNote = string.format(
                    " settling=%s awaiting=%s",
                    tostring(Sch.IsSessionSettling and Sch.IsSessionSettling() == true),
                    tostring(Sch._awaitingSessionLoad == true)
                )
            end
            emit("  plantJob=nil reason=" .. tostring(nilReason) .. suNote .. settleNote)
        end
    end
    local tip = nil
    local PS = StockPiler.PlanSnapshot
    local plan = PS and PS.Get and PS.Get()
    if type(plan) == "table" then
        tip = plan.seedBufferTipData
    end
    if type(tip) == "table" then
        emit(string.format(
            "  seedBuffer enabled=%s buffer=%s watched=%d intents=%d",
            tostring(tip.enabled),
            tostring(tip.buffer),
            type(tip.watched) == "table" and #tip.watched or 0,
            type(tip.intents) == "table" and #tip.intents or 0
        ))
        local watched = tip.watched
        if type(watched) == "table" then
            for i = 1, #watched do
                local rec = watched[i]
                if type(rec) == "table" then
                    if rec.plantOnly == true then
                        emit(string.format(
                            "    plant uid=%s live=%s total=%s shortBy=%s key=%s",
                            tostring(rec.plantUid or 0),
                            tostring(rec.live or 0),
                            tostring(rec.total or 0),
                            tostring(rec.shortBy or 0),
                            tostring(rec.key or "")
                        ))
                    else
                        emit(string.format(
                            "    seed uid=%s live=%s ground=%s planned=%s total=%s shortBy=%s key=%s",
                            tostring(rec.seedUid or 0),
                            tostring(rec.live or 0),
                            tostring(rec.ground or 0),
                            tostring(rec.planned or 0),
                            tostring(rec.total or 0),
                            tostring(rec.shortBy or 0),
                            tostring(rec.key or "")
                        ))
                    end
                end
            end
        end
    end
    if Grow and Grow.DumpPlantJob then
        Grow.DumpPlantJob(emit)
    end
    emit("=== end growplan ===")
end

function Planner.DumpBrewPlan(emit)
    emit = MakeEmit(emit)
    emit("=== StockPiler brewplan ===")
    local Brew = StockPiler.Brew
    local blockedWhy = Brew and Brew.AutoBrewBlockedReason and Brew.AutoBrewBlockedReason() or nil
    emit(string.format(
        "  hasReady=%s canBrew=%s openFail=%s autoBlocked=%s respectGrowReserve=%s",
        tostring(Planner.HasReadyToCraft()),
        tostring(Brew and Brew.CanBrewNow and Brew.CanBrewNow()),
        tostring(Brew and Brew._openFailLatched == true),
        tostring(blockedWhy or "no"),
        tostring(RespectGrowReserve())))
    local Grow = StockPiler.Grow
    emit(string.format(
        "  bufferSatisfied=%s bufferShort=%s pendingRefine=%s pendingPlant=%s refineOut=%s",
        tostring(Grow and Grow.IsSeedBufferSatisfied and Grow.IsSeedBufferSatisfied()),
        tostring(Grow and Grow.HasAnyBufferShort and Grow.HasAnyBufferShort()),
        tostring(Grow and Grow.HasPendingBufferRefine and Grow.HasPendingBufferRefine()),
        tostring(Grow and Grow.HasPendingPlant and Grow.HasPendingPlant()),
        tostring(StockPiler.RefinePipeline and StockPiler.RefinePipeline.HasOutstanding
            and StockPiler.RefinePipeline.HasOutstanding())
    ))
    local PS = StockPiler.PlanSnapshot
    local plan = PS and PS.Get and PS.Get()
    if type(plan) == "table" and type(plan.rows) == "table" then
        for i = 1, #plan.rows do
            local row = plan.rows[i]
            if type(row) == "table" and RowIsReadyToCraft(row) then
                emit(string.format(
                    "  ready %s deficit=%s craftable=%s",
                    ToNarrow(row.name),
                    tostring(row.potionDeficit),
                    tostring(row.craftable)
                ))
            end
        end
    end
    if Brew and Brew.DumpSession then
        Brew.DumpSession(emit)
    end
    emit("=== end brewplan ===")
end
