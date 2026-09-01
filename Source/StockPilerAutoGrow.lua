----------------------------------------------------------------
-- StockPilerAutoGrow - automatic cultivation planting
-- Throttling modeled on GatherButton (1 pending plant/refine per plot,
-- decay once per second via UPDATE_PROCESSED).
----------------------------------------------------------------

StockPiler.AutoGrow = StockPiler.AutoGrow or {}

local MAX_PENDING_PLANT = 1
-- GatherButton uses MAX_PENDING_REFINE_REQUESTS = 6 so a single tick can
-- refill the seed buffer without waiting for refine-complete events.
local MAX_PENDING_REFINE = 6
local PLOT_COUNT = 4
local TICK_INTERVAL_SEC = 1
-- Chat-warn when a plant wave spends every remaining seed and that
-- stack is this small (failed harvest can lose the line).
local LAST_SEED_WARN_MAX = 4

-- Forward-declared: helpers below call this before the body is assigned.
local NumPlots

StockPiler.AutoGrow._plotCache = {}
StockPiler.AutoGrow._pendingPlant = {}
StockPiler.AutoGrow._pendingAdditive = {}
StockPiler.AutoGrow._pendingRefine = {}
StockPiler.AutoGrow._wantFill = {}
StockPiler.AutoGrow._lastNotifiedStage = {}
StockPiler.AutoGrow._queueCursor = 1
StockPiler.AutoGrow._fillPlotCursor = 1
-- Set when a harvest game action is sent; covers the gap before plot stage
-- flips to Harvesting (macro spam / CurrentPlot races).
StockPiler.AutoGrow._harvestOpLockUntil = 0
StockPiler.AutoGrow._additiveCursor = 1
StockPiler.AutoGrow._initialized = false
StockPiler.AutoGrow._autoRefinePending = nil
StockPiler.AutoGrow._harvestCursor = 1
StockPiler.AutoGrow._updateAccum = 0
StockPiler.AutoGrow._syncedEnabled = nil
StockPiler.AutoGrow._plotInfoRequested = false
StockPiler.AutoGrow._cachedPlantQueue = nil
StockPiler.AutoGrow._plantQueueDirty = true
StockPiler.AutoGrow._queueAssigned = 0
StockPiler.AutoGrow._queueSnapGen = nil
StockPiler.AutoGrow._suppressInvTicks = 0
StockPiler.AutoGrow._pendingHarvestNotify = nil
StockPiler.AutoGrow._lastTickTrace = nil
-- Seeds planted that live bags may not have subtracted yet (inventory suppress).
StockPiler.AutoGrow._seedCommitted = {}
StockPiler.AutoGrow._seedLastLive = {}
-- Chat-warn when planting spends every remaining seed of a small stack.
StockPiler.AutoGrow._lastSeedExhaustWarn = {}
-- Debounce red "lost seed line" chat until seeds return.
StockPiler.AutoGrow._seedLineLostNotified = {}

local function ToNarrow(text)
    return StockPiler.ToNarrow(text)
end

--- Competitors still queued on other empty plots (for plant op context).
function StockPiler.AutoGrow.QueuedPlantCompetitors(exceptPlot)
    exceptPlot = tonumber(exceptPlot) or 0
    local list = {}
    local queue = StockPiler.AutoGrow._cachedPlantQueue
    if type(queue) ~= "table" then
        return list
    end
    for plotNum = 1, NumPlots() do
        if plotNum ~= exceptPlot then
            local entry = queue[plotNum]
            if type(entry) == "table" then
                list[#list + 1] = string.format(
                    "P%d %s seedUid=%d plantable=%d%s",
                    plotNum,
                    ToNarrow(entry.seedName or entry.specKey or "?"),
                    tonumber(entry.seedUid) or 0,
                    tonumber(entry.seedPlantable) or 0,
                    entry.bufferGrow == true and " buffer" or ""
                )
            end
        end
    end
    return list
end

local function AsWString(text)
    if type(text) == "wstring" then
        return text
    end
    if type(text) == "string" then
        return towstring(text)
    end
    if text == nil then
        return L""
    end
    return towstring(tostring(text))
end

local function GetSettings()
    if StockPiler.EnsureSettings then
        return StockPiler.EnsureSettings()
    end
    return StockPiler.Settings
end

local function D(msg)
    if StockPiler and StockPiler.D then
        StockPiler.D(msg)
    end
end

NumPlots = function()
    if StockPiler.Inventory and StockPiler.Inventory.GetLocalCultivator then
        local info = StockPiler.Inventory.GetLocalCultivator()
        return math.max(0, tonumber(info and info.plots) or 0)
    end
    return 0
end

StockPiler.AutoGrow.NumPlots = NumPlots

local function StageEmpty()
    if GameData and GameData.CultivationStage then
        return GameData.CultivationStage.EMPTY or 0
    end
    return 0
end

local function StageGrown()
    if GameData and GameData.CultivationStage then
        return GameData.CultivationStage.GROWN or 4
    end
    return 4
end

local function StageHarvesting()
    if GameData and GameData.CultivationStage then
        return GameData.CultivationStage.HARVESTING or 5
    end
    return 5
end

local function StageGermination()
    if GameData and GameData.CultivationStage then
        return GameData.CultivationStage.GERMINATION or 1
    end
    return 1
end

local function StageSeedling()
    if GameData and GameData.CultivationStage then
        return GameData.CultivationStage.SEEDLING or 2
    end
    return 2
end

local function StageFlowering()
    if GameData and GameData.CultivationStage then
        return GameData.CultivationStage.FLOWERING or 3
    end
    return 3
end

local function NormalizeStage(stageNum)
    stageNum = tonumber(stageNum) or 0
    if stageNum == 255 then
        return StageEmpty()
    end
    return stageNum
end

function StockPiler.AutoGrow.ShouldTraceGrow()
    return StockPiler.DebugEnabled == true
end

--- AutoGrow uilog line. Live traces need /stp debug.
--- force=true is only for one-shot user dumps (/stp growplan).
function StockPiler.AutoGrow.EmitGrowTrace(msg, force)
    if force ~= true and not StockPiler.AutoGrow.ShouldTraceGrow() then
        return
    end
    local text = "AutoGrow| " .. tostring(msg)
    if StockPiler._EmitLog and StockPiler._LogText then
        StockPiler._EmitLog("StockPiler| " .. StockPiler._LogText(text))
    elseif type(d) == "function" then
        d("StockPiler| " .. text)
    end
end

local function LogGrow(msg)
    StockPiler.AutoGrow.EmitGrowTrace(msg, false)
end

local function LogTickOnce(reason)
    if not StockPiler.AutoGrow.ShouldTraceGrow() then
        return
    end
    if StockPiler.AutoGrow._lastTickTrace ~= reason then
        StockPiler.AutoGrow._lastTickTrace = reason
        LogGrow("tick: " .. reason)
    end
end

--- empty / ready / growing plot counts for op lines.
--- omitReady=true drops ready= (caller already prints ready=N).
function StockPiler.AutoGrow.GardenSummary(omitReady)
    local empty, ready, growing = 0, 0, 0
    local grown = StageGrown()
    local harvesting = StageHarvesting()
    local emptyStage = StageEmpty()
    local plots = NumPlots()
    for plotNum = 1, plots do
        local plotData = StockPiler.AutoGrow._plotCache[plotNum]
        local stage = emptyStage
        if type(plotData) == "table" then
            stage = NormalizeStage(plotData.StageNum)
        end
        if stage == emptyStage then
            empty = empty + 1
        elseif stage == grown or stage == harvesting then
            ready = ready + 1
        else
            growing = growing + 1
        end
    end
    if omitReady == true then
        return string.format("empty=%d growing=%d", empty, growing)
    end
    return string.format("empty=%d ready=%d growing=%d", empty, ready, growing)
end

local function LogPlantOp(msg)
    if StockPiler.LogOp then
        StockPiler.LogOp("plant", msg)
    else
        LogGrow("plant " .. tostring(msg))
    end
end

local function LogHarvestOp(msg)
    if StockPiler.LogOp then
        StockPiler.LogOp("harvest", msg)
    else
        LogGrow("harvest " .. tostring(msg))
    end
end

local function LogRefineOp(msg)
    if StockPiler.LogOp then
        StockPiler.LogOp("refine", msg)
    else
        LogGrow("refine " .. tostring(msg))
    end
end

local function SpecTraceLabel(spec, specKey)
    if type(spec) ~= "table" or not StockPiler.MaterialSpec then
        return tostring(specKey or "?")
    end
    local label = ToNarrow(StockPiler.MaterialSpec.Label(spec))
    local key = specKey or StockPiler.MaterialSpec.Key(spec) or "?"
    local fx = spec.effectId and (" fx:" .. tostring(spec.effectId)) or ""
    local role = spec.role and (" role:" .. tostring(spec.role)) or ""
    return label .. role .. fx .. " [" .. key .. "]"
end

function StockPiler.AutoGrow.DumpGrowPlan(opts)
    opts = opts or {}
    local force = opts.force == true
    local function emit(msg)
        StockPiler.AutoGrow.EmitGrowTrace(msg, force)
    end

    emit("=== grow plan ===")
    local s = GetSettings()
    local enabled = s.autoGrowEnabled == true
    local buffer = 2
    if StockPiler.Planner and StockPiler.Planner.GetSeedBufferMin then
        buffer = StockPiler.Planner.GetSeedBufferMin()
    end
    local additives = StockPiler.Additives and StockPiler.Additives.IsEnabled and StockPiler.Additives.IsEnabled()
    emit("autoGrow=" .. tostring(enabled)
        .. " additives=" .. tostring(additives == true)
        .. " seedBuffer=" .. tostring(buffer))

    if StockPiler.Inventory and StockPiler.Inventory.RefreshAllIfNeeded then
        StockPiler.Inventory.RefreshAllIfNeeded()
    end

    local RS = StockPiler.RecipeSpec
    local targets = {}
    if StockPiler.Planner and StockPiler.Planner.BuildPlan then
        local plan = StockPiler.Planner.BuildPlan({ refresh = false })
        if type(plan) == "table" and type(plan.rows) == "table" then
            for i = 1, #plan.rows do
                local row = plan.rows[i]
                targets[#targets + 1] = row
            end
        end
    end

    emit("--- watches (" .. tostring(#targets) .. ") ---")
    for i = 1, #targets do
        local row = targets[i]
        local recipe = row.specRecipe
        local quality = recipe and recipe.quality or "?"
        local yield = 0
        if StockPiler.RecipeSpec and StockPiler.RecipeSpec.RecipeOutputYield then
            yield = StockPiler.RecipeSpec.RecipeOutputYield(recipe)
        else
            yield = recipe and tonumber(recipe.recipeYield) or 0
        end
        local crafts = row.craftsNeeded or 0
        emit(string.format(
            "  %s have=%d target=%d deficit=%d recipe=%s yield=%d crafts=%d autoGrow=%s growable=%s status=%s",
            ToNarrow(row.name or row.potionKey or "?"),
            tonumber(row.potionHave) or 0,
            tonumber(row.potionMin) or 0,
            tonumber(row.potionDeficit) or 0,
            tostring(quality),
            yield,
            crafts,
            tostring(row.autoGrow == true),
            tostring(row.growable == true),
            ToNarrow(row.statusText or row.statusKey or "?")
        ))
        if row.statusDetail and ToNarrow(row.statusDetail) ~= "" then
            emit("    detail: " .. ToNarrow(row.statusDetail))
        end
    end

    local specDemand = RS and RS.BuildBalancedSpecDemand() or {}
    local demandCount = 0
    for _ in pairs(specDemand) do
        demandCount = demandCount + 1
    end
    emit("--- spec demand (" .. tostring(demandCount) .. ") ---")
    local demandSorted = {}
    for _, row in pairs(specDemand) do
        demandSorted[#demandSorted + 1] = row
    end
    table.sort(demandSorted, function(a, b)
        if StockPiler.Planner and StockPiler.Planner.CompareGrowPriority then
            return StockPiler.Planner.CompareGrowPriority(a, b)
        end
        if (a.weighted or 0) ~= (b.weighted or 0) then
            return (a.weighted or 0) > (b.weighted or 0)
        end
        return (a.deficit or 0) > (b.deficit or 0)
    end)
    for i = 1, #demandSorted do
        local row = demandSorted[i]
        local growable = StockPiler.MaterialSpec
            and StockPiler.MaterialSpec.IsGrowable(row.spec)
        emit(string.format(
            "  %s have=%d need=%d deficit=%d craftsHave=%d craftsShort=%d minWatch=%s stock=%s role=%s weighted=%.3f growable=%s",
            SpecTraceLabel(row.spec, row.specKey),
            tonumber(row.have) or 0,
            tonumber(row.absolute) or 0,
            tonumber(row.deficit) or 0,
            tonumber(row.craftsHave) or 0,
            tonumber(row.craftsShort) or 0,
            tostring(row.minWatchCraftable),
            tostring(row.minWatchStock),
            tostring(row.role or "?"),
            tonumber(row.weighted) or 0,
            tostring(growable == true)
        ))
        if (row.deficit or 0) <= 0 then
            emit("    -> stocked (no grow demand)")
        elseif growable ~= true then
            emit("    -> not growable")
        end
    end

    local traceLines = {}
    local queue = {}
    if StockPiler.Planner and StockPiler.Planner.BuildGrowQueueFromSpecDeficits then
        queue = StockPiler.Planner.BuildGrowQueueFromSpecDeficits(specDemand, traceLines)
    end
    emit("--- queue build ---")
    for i = 1, #traceLines do
        emit("  " .. traceLines[i])
    end
    if #traceLines == 0 then
        emit("  (no growable deficits with plantable seeds)")
    end

    if StockPiler.Planner and StockPiler.Planner.CollectGrowCycleRefineJobs then
        emit("--- grow-cycle refine ---")
        local plotCount = NumPlots()
        local emptyPlots = 0
        for plotNum = 1, plotCount do
            if StockPiler.AutoGrow.CanPlantPlot(plotNum) then
                emptyPlots = emptyPlots + 1
            end
        end
        local allowed, gateReason = StockPiler.AutoGrow.ShouldAllowRefineNow()
        local includeBuffer = gateReason == "post-harvest"
        emit("  refineGate=" .. tostring(allowed == true)
            .. " reason=" .. tostring(gateReason or "?")
            .. " includeBuffer=" .. tostring(includeBuffer)
            .. " emptyPlots=" .. tostring(emptyPlots))
        local jobs = StockPiler.Planner.CollectGrowCycleRefineJobs(emptyPlots, {
            includeBuffer = includeBuffer,
        })
        if type(jobs) ~= "table" or #jobs == 0 then
            emit("  (no grow-cycle refine jobs; seeds may already cover empty plots)")
        else
            for i = 1, #jobs do
                local job = jobs[i]
                local plantUid = tonumber(job.plantUid) or 0
                local uses = tonumber(job.uses) or 0
                local slot = 0
                if plantUid > 0 and StockPiler.AutoGrow.FindRefinablePlantSlot then
                    slot = select(1, StockPiler.AutoGrow.FindRefinablePlantSlot(plantUid))
                end
                if slot <= 0 and job.seedUid and StockPiler.AutoGrow.FindRefinablePlantSlotForSeed then
                    slot = select(1, StockPiler.AutoGrow.FindRefinablePlantSlotForSeed(job.seedUid))
                end
                emit(string.format(
                    "  job #%d seedUid=%d plantUid=%d seedHave=%d want=%d uses=%d deficit=%d refinableSlot=%d",
                    i,
                    tonumber(job.seedUid) or 0,
                    plantUid,
                    tonumber(job.seedHave) or 0,
                    tonumber(job.wantSeeds) or 0,
                    uses,
                    tonumber(job.deficit) or 0,
                    slot
                ))
            end
        end
    end

    emit("--- plot queue ---")
    local plotCount = NumPlots()
    for plotNum = 1, plotCount do
        local entry = queue[plotNum]
        if type(entry) == "table" then
            emit(string.format(
                "  P%d %s seedUid=%d plantUid=%d seedHave=%d plantable=%d matHave=%d specKey=%s",
                plotNum,
                ToNarrow(entry.seedName or entry.seedKey or "?"),
                tonumber(entry.seedUid) or 0,
                tonumber(entry.plantUid) or 0,
                tonumber(entry.seedHave) or 0,
                tonumber(entry.seedPlantable) or 0,
                tonumber(entry.matHave) or 0,
                tostring(entry.specKey or "?")
            ))
        else
            emit("  P" .. tostring(plotNum) .. " (empty)")
        end
    end

    emit("--- plot state ---")
    for plotNum = 1, plotCount do
        local plotData = StockPiler.AutoGrow._plotCache[plotNum]
        local stage = plotData and NormalizeStage(plotData.StageNum) or "?"
        local want = StockPiler.AutoGrow._wantFill[plotNum] == true
        local pending = tonumber(StockPiler.AutoGrow._pendingPlant[plotNum]) or 0
        local assign = StockPiler.AutoGrow.GetPlotAssignment(plotNum)
        local assignText = "none"
        if type(assign) == "table" then
            assignText = ToNarrow(assign.seedName or assign.seedKey or "?")
                .. " uid=" .. tostring(StockPiler.AutoGrow.ResolveSeedUid(assign))
        end
        local block = StockPiler.AutoGrow.PlantBlockReason(plotNum)
        emit(string.format(
            "  P%d stage=%s wantFill=%s pending=%d assign=%s block=%s",
            plotNum,
            tostring(stage),
            tostring(want),
            pending,
            assignText,
            block or "ok"
        ))
    end

    local growPairs = 0
    if StockPiler.SeedMap and StockPiler.SeedMap.CountLearnedGrowPairs then
        growPairs = StockPiler.SeedMap.CountLearnedGrowPairs() or 0
    end
    emit("--- learned grow pairs (" .. tostring(growPairs) .. ") ---")

    local ready = StockPiler.AutoGrow.GetReadyHarvestPlots()
    emit("--- runtime ---")
    emit("readyHarvest=" .. tostring(#ready)
        .. " refinePending=" .. tostring(StockPiler.AutoGrow._autoRefinePending ~= nil)
        .. " tickState=" .. tostring(StockPiler.AutoGrow._lastTickTrace or "idle"))
    emit("=== end grow plan ===")
end

function StockPiler.AutoGrow.LogGrowQueueSummary(plan)
    if not StockPiler.AutoGrow.ShouldTraceGrow() or type(plan) ~= "table" then
        return
    end
    local queue = plan.queue
    if type(queue) ~= "table" then
        LogGrow("queue rebuilt: empty")
        return
    end
    local parts = {}
    for plotNum = 1, NumPlots() do
        local entry = queue[plotNum]
        if type(entry) == "table" then
            parts[#parts + 1] = "P" .. tostring(plotNum) .. "="
                .. ToNarrow(entry.seedName or entry.seedKey or "?")
                .. " plantable=" .. tostring(entry.seedPlantable or 0)
                .. (entry.bufferGrow == true and " buffer" or "")
        end
    end
    if #parts == 0 then
        LogGrow("queue rebuilt: no plantable assignments")
    else
        LogGrow("queue rebuilt: " .. table.concat(parts, " | "))
    end
end

function StockPiler.AutoGrow.IsEnabled()
    if StockPiler.Inventory and StockPiler.Inventory.CultivatorState
        and StockPiler.Inventory.CultivatorState() == false
    then
        return false
    end
    local s = GetSettings()
    return type(s) == "table" and s.autoGrowEnabled == true
end

--- True while SendUseItem convert commands are still in flight (a few seconds).
function StockPiler.AutoGrow.HasPendingRefine(plantUid)
    plantUid = tonumber(plantUid) or 0
    if plantUid > 0 then
        return (tonumber(StockPiler.AutoGrow._pendingRefine[plantUid]) or 0) > 0
    end
    for _, n in pairs(StockPiler.AutoGrow._pendingRefine) do
        if (tonumber(n) or 0) > 0 then
            return true
        end
    end
    return false
end

local function RefreshWatchStatusIfOpen()
    StockPiler.AutoGrow._watchUiDirty = true
end

local WATCH_UI_MIN_INTERVAL_SEC = 5.0

local function WatchContentKey()
    local snapGen = StockPiler.Inventory and tonumber(StockPiler.Inventory._snapshotGen) or 0
    local planGen = StockPiler.Planner and tonumber(StockPiler.Planner._planSnapshotGen) or 0
    local autoGrowOn = StockPiler.AutoGrow.IsEnabled and StockPiler.AutoGrow.IsEnabled() == true
    return tostring(snapGen) .. ":" .. tostring(planGen) .. ":" .. tostring(autoGrowOn)
end

local function FlushWatchUiIfDirty()
    if StockPiler.AutoGrow._watchUiDirty ~= true then
        return
    end
    if not DoesWindowExist("StockPilerWindow") or not WindowGetShowing("StockPilerWindow") then
        return
    end
    local contentKey = WatchContentKey()
    if StockPiler.AutoGrow._watchUiLastKey == contentKey then
        StockPiler.AutoGrow._watchUiDirty = false
        return
    end
    local now = 0
    if type(GetGameTime) == "function" then
        now = tonumber(GetGameTime()) or 0
    end
    local last = tonumber(StockPiler.AutoGrow._watchUiFlushedAt) or 0
    if last > 0 and (now - last) < WATCH_UI_MIN_INTERVAL_SEC then
        return
    end
    StockPiler.AutoGrow._watchUiDirty = false
    StockPiler.AutoGrow._watchUiFlushedAt = now
    StockPiler.AutoGrow._watchUiLastKey = contentKey
    if StockPilerTabAutoGrow and StockPilerTabAutoGrow.Refresh then
        StockPilerTabAutoGrow.Refresh()
    end
end

local function CachedPlot(plotNum)
    return StockPiler.AutoGrow._plotCache[plotNum]
end

local function IsEnabled()
    return StockPiler.AutoGrow.IsEnabled()
end

function StockPiler.AutoGrow.Stop()
    StockPiler.AutoGrow._wantFill = {}
    StockPiler.AutoGrow._pendingPlant = {}
    StockPiler.AutoGrow._pendingAdditive = {}
    StockPiler.AutoGrow._pendingRefine = {}
    StockPiler.AutoGrow._seedCommitted = {}
    StockPiler.AutoGrow._seedLastLive = {}
    StockPiler.AutoGrow._lastSeedExhaustWarn = {}
    StockPiler.AutoGrow._seedLineLostNotified = {}
    StockPiler.AutoGrow._autoRefinePending = nil
end

function StockPiler.AutoGrow.SyncEnabledFromSettings(prevEnabled, newEnabled, force)
    prevEnabled = prevEnabled == true
    newEnabled = newEnabled == true
    if force ~= true
        and StockPiler.AutoGrow._syncedEnabled == newEnabled
        and prevEnabled == newEnabled
    then
        return
    end
    StockPiler.AutoGrow._syncedEnabled = newEnabled
    StockPiler.AutoGrow.OnEnabledChanged(newEnabled)
end

function StockPiler.AutoGrow.InvalidatePlantQueue()
    local already = StockPiler.AutoGrow._plantQueueDirty == true
    StockPiler.AutoGrow._plantQueueDirty = true
    -- Keep the last queue during a harvest/loot debounce so GetPlantQueue
    -- does not rebuild while bags are still changing.
    if not (StockPiler.BagWorkPending and StockPiler.BagWorkPending()) then
        StockPiler.AutoGrow._cachedPlantQueue = nil
        StockPiler.AutoGrow._queueSnapGen = nil
    end
    if already ~= true then
        LogGrow("queue invalidated")
    end
end

function StockPiler.AutoGrow.RefineCheckDue()
    if StockPiler.AutoGrow._refineDirty == true then
        return true
    end
    return (tonumber(StockPiler.AutoGrow._refineWaitTicks) or 0) <= 0
end

function StockPiler.AutoGrow.MarkRefineDue(reason)
    StockPiler.AutoGrow._refineDirty = true
    if reason == "harvest" then
        StockPiler.AutoGrow._refineDirtyReason = "harvest"
    end
    if StockPiler.AutoGrow.InvalidateHarvestBusyCache then
        StockPiler.AutoGrow.InvalidateHarvestBusyCache()
    end
end

function StockPiler.AutoGrow.MarkAdditiveDue()
    StockPiler.AutoGrow._additiveDirty = true
end

-- Watch list, per-potion AutoGrow, or target changed. Rebuild the queue and
-- fill any empty plots if the global switch is already on.
function StockPiler.AutoGrow.OnDemandChanged()
    StockPiler.AutoGrow.InvalidatePlantQueue()
    StockPiler.AutoGrow._watchUiLastKey = nil
    if StockPiler.Planner and StockPiler.Planner.InvalidatePlanCache then
        StockPiler.Planner.InvalidatePlanCache()
    end
    if not IsEnabled() then
        return
    end
    StockPiler.AutoGrow._lastTickTrace = nil
    StockPiler.AutoGrow.MarkAllPlotsWantFill()
    -- Convert plants to seeds before planting so empty plots can all fill.
    StockPiler.AutoGrow.MarkRefineDue()
    -- Seed buffer / target changes must refine immediately, not wait 1s.
    StockPiler.AutoGrow._updateAccum = TICK_INTERVAL_SEC
    StockPiler.AutoGrow.ProcessTick()
end

local function SuppressInventorySideEffects()
    StockPiler.AutoGrow._suppressInvTicks = 2
end

local function DecaySuppressInventorySideEffects()
    local n = tonumber(StockPiler.AutoGrow._suppressInvTicks) or 0
    if n > 0 then
        StockPiler.AutoGrow._suppressInvTicks = n - 1
    end
end

local _bagCache = nil
local _bagCacheAt = 0

local function NowSec()
    if type(GetGameTime) == "function" then
        return tonumber(GetGameTime()) or 0
    end
    return 0
end

local function ReadBagTables()
    local now = NowSec()
    if type(_bagCache) == "table" and (now - _bagCacheAt) < 0.25 then
        return _bagCache.craft, _bagCache.inv
    end
    local craftBag = nil
    local invBag = nil
    if DataUtils and DataUtils.GetCraftingItems then
        local ok, data = StockPiler.TryCallQuiet("DataUtils.GetCraftingItems", DataUtils.GetCraftingItems)
        if ok then
            craftBag = data
        end
    end
    if DataUtils and DataUtils.GetItems then
        local ok, data = StockPiler.TryCallQuiet("DataUtils.GetItems", DataUtils.GetItems)
        if ok then
            invBag = data
        end
    end
    _bagCache = { craft = craftBag, inv = invBag }
    _bagCacheAt = now
    return craftBag, invBag
end

local HARVEST_ACTION_WIN = "SPTabAutoGrowHarvest"
local CULTIVATION_HARVEST_WIN = "CultivationWindowHarvest"

local function BindCultivationHarvestAction(windowName)
    if WindowSetGameActionData == nil or windowName == nil or windowName == "" then
        return false
    end
    if not DoesWindowExist(windowName) then
        return false
    end
    local cult = GameData and GameData.TradeSkills and GameData.TradeSkills.CULTIVATION or 3
    local action = GameData and GameData.PlayerActions and GameData.PlayerActions.PERFORM_CRAFTING or 8
    local ok, err = StockPiler.TryCall("WindowSetGameActionData", WindowSetGameActionData, windowName, action, cult, L"")
    if not ok then
        D("BindCultivationHarvestAction failed win=" .. tostring(windowName) .. " err=" .. tostring(err))
        return false
    end
    return true
end

function StockPiler.AutoGrow.EnsureHarvestActionBound()
    if BindCultivationHarvestAction(HARVEST_ACTION_WIN) then
        StockPiler.AutoGrow._harvestActionBound = true
        return true
    end
    if BindCultivationHarvestAction(CULTIVATION_HARVEST_WIN) then
        StockPiler.AutoGrow._harvestActionBound = true
        return true
    end
    StockPiler.AutoGrow._harvestActionBound = false
    return false
end

local function CultivationTradeSkill()
    if GameData and GameData.TradeSkills and GameData.TradeSkills.CULTIVATION then
        return GameData.TradeSkills.CULTIVATION
    end
    return 3
end

local function NameEquals(itemName, asciiNeedle)
    if asciiNeedle == nil or asciiNeedle == "" or itemName == nil then
        return false
    end
    local needle = string.lower(asciiNeedle)
    local n = string.lower(ToNarrow(itemName))
    return n ~= "" and n == needle
end

local function IsPlotGrown(stageNum)
    return NormalizeStage(stageNum) == StageGrown()
end

local function IsPlotHarvesting(stageNum)
    return NormalizeStage(stageNum) == StageHarvesting()
end

local function IsPlotReadyToHarvest(stageNum)
    stageNum = NormalizeStage(stageNum)
    return stageNum == StageGrown() or stageNum == StageHarvesting()
end

local function StageLabel(stageNum)
    stageNum = NormalizeStage(stageNum)
    if stageNum == StageEmpty() then
        return L"Empty"
    end
    if stageNum == StageGermination() then
        return L"Germination"
    end
    if stageNum == StageSeedling() then
        return L"Seedling"
    end
    if stageNum == StageFlowering() then
        return L"Flowering"
    end
    if stageNum == StageGrown() then
        return L"Ready to harvest"
    end
    if stageNum == StageHarvesting() then
        return L"Harvesting"
    end
    return L"Stage " .. towstring(tostring(stageNum))
end

local function CraftingBackpackType()
    if EA_Window_Backpack and EA_Window_Backpack.TYPE_CRAFTING then
        return EA_Window_Backpack.TYPE_CRAFTING
    end
    return 4
end

local function InventoryBackpackType()
    if EA_Window_Backpack and EA_Window_Backpack.TYPE_INVENTORY then
        return EA_Window_Backpack.TYPE_INVENTORY
    end
    return 2
end

function StockPiler.AutoGrow.DecayPendingRequests()
    for plotNum, n in pairs(StockPiler.AutoGrow._pendingPlant) do
        n = tonumber(n) or 0
        if n > 0 then
            StockPiler.AutoGrow._pendingPlant[plotNum] = n - 1
        end
    end
    for plotNum, n in pairs(StockPiler.AutoGrow._pendingAdditive) do
        n = tonumber(n) or 0
        if n > 0 then
            StockPiler.AutoGrow._pendingAdditive[plotNum] = n - 1
        end
    end
    local refineWasPending = StockPiler.AutoGrow.HasPendingRefine()
    for uid, n in pairs(StockPiler.AutoGrow._pendingRefine) do
        n = tonumber(n) or 0
        if n > 0 then
            StockPiler.AutoGrow._pendingRefine[uid] = n - 1
        end
    end
    if refineWasPending and not StockPiler.AutoGrow.HasPendingRefine() then
        RefreshWatchStatusIfOpen()
    end
end

function StockPiler.AutoGrow.MarkAllPlotsWantFill()
    if not IsEnabled() then
        return
    end
    local plots = NumPlots()
    for plotNum = 1, plots do
        local plotData = StockPiler.AutoGrow._plotCache[plotNum]
        local stage = StageEmpty()
        if type(plotData) == "table" then
            stage = NormalizeStage(plotData.StageNum)
        end
        if stage == StageEmpty() then
            StockPiler.AutoGrow._wantFill[plotNum] = true
        end
    end
end

function StockPiler.AutoGrow.ResolveSeedUid(entry)
    if type(entry) ~= "table" then
        return 0
    end
    local seedKey = entry.seedKey or ToNarrow(entry.seedName)
    local uid = tonumber(entry.seedUid) or 0
    if uid > 0 and StockPiler.AutoGrow.GetRawSeedCount(uid) > 0 then
        return uid
    end
    local _, item = StockPiler.AutoGrow.FindSeedSlot(uid, seedKey)
    if type(item) == "table" then
        return tonumber(item.uniqueID) or 0
    end
    return 0
end

function StockPiler.AutoGrow.InvalidateBagCache()
    _bagCache = nil
    _bagCacheAt = 0
end

local function CountSeedsInLiveBags(seedUid)
    seedUid = tonumber(seedUid) or 0
    if seedUid <= 0 then
        return 0
    end
    if StockPiler.Perf and StockPiler.Perf.Mark then
        StockPiler.Perf.Mark("CountSeedsLive")
    end
    local function sumBag(bagItems)
        if type(bagItems) ~= "table" then
            return 0
        end
        local total = 0
        for _, item in pairs(bagItems) do
            if type(item) == "table" and tonumber(item.uniqueID) == seedUid then
                local stack = tonumber(item.stackCount) or tonumber(item.StackCount) or 1
                total = total + math.max(1, stack)
            end
        end
        return total
    end
    local craftBag, invBag = ReadBagTables()
    return sumBag(craftBag) + sumBag(invBag)
end

local function CountSeedsFromSnapshot(seedUid)
    seedUid = tonumber(seedUid) or 0
    if seedUid <= 0 then
        return nil
    end
    if StockPiler.Inventory == nil or StockPiler.Inventory._snapshotDone ~= true then
        return nil
    end
    local counts = StockPiler.Inventory._countByUid
    if type(counts) ~= "table" then
        return nil
    end
    return tonumber(counts[seedUid]) or 0
end

--- Seeds physically in bags right now. Ignores snapshot and in-flight commits.
function StockPiler.AutoGrow.GetLiveSeedCount(seedUid)
    return CountSeedsInLiveBags(seedUid)
end

function StockPiler.AutoGrow.GetEffectiveSeedCount(seedUid)
    seedUid = tonumber(seedUid) or 0
    if seedUid <= 0 then
        return 0
    end
    local live = CountSeedsFromSnapshot(seedUid)
    if live == nil then
        live = CountSeedsInLiveBags(seedUid)
    end
    local committed = tonumber(StockPiler.AutoGrow._seedCommitted[seedUid]) or 0
    local lastLive = StockPiler.AutoGrow._seedLastLive[seedUid]
    if lastLive ~= nil and live < lastLive then
        committed = math.max(0, committed - (lastLive - live))
        StockPiler.AutoGrow._seedCommitted[seedUid] = committed
    end
    StockPiler.AutoGrow._seedLastLive[seedUid] = live
    if live > 0 and StockPiler.AutoGrow.NoteSeedLinePresent then
        StockPiler.AutoGrow.NoteSeedLinePresent(seedUid)
    end
    return math.max(0, live - committed)
end

function StockPiler.AutoGrow.NoteSeedPlanted(seedUid)
    seedUid = tonumber(seedUid) or 0
    if seedUid <= 0 then
        return
    end
    StockPiler.AutoGrow._seedCommitted[seedUid] =
        (tonumber(StockPiler.AutoGrow._seedCommitted[seedUid]) or 0) + 1
end

local function EntrySeedPlantable(entry)
    if type(entry) ~= "table" then
        return 0
    end
    local uid = tonumber(entry.seedUid) or 0
    if uid <= 0 then
        uid = StockPiler.AutoGrow.ResolveSeedUid(entry)
    end
    if uid <= 0 then
        return 0
    end
    local count = StockPiler.AutoGrow.GetEffectiveSeedCount(uid)
    local buffer = 4
    if StockPiler.Planner and StockPiler.Planner.GetSeedBufferMin then
        buffer = StockPiler.Planner.GetSeedBufferMin()
    end
    if StockPiler.Planner and StockPiler.Planner.ComputeSeedPlantable then
        return StockPiler.Planner.ComputeSeedPlantable(count, buffer)
    end
    return count
end

function StockPiler.AutoGrow.GetPlantableSeedCount(seedUid)
    seedUid = tonumber(seedUid) or 0
    if seedUid <= 0 then
        return 0
    end
    local count = StockPiler.AutoGrow.GetEffectiveSeedCount(seedUid)
    local buffer = 4
    if StockPiler.Planner and StockPiler.Planner.GetSeedBufferMin then
        buffer = StockPiler.Planner.GetSeedBufferMin()
    end
    if StockPiler.Planner and StockPiler.Planner.ComputeSeedPlantable then
        return StockPiler.Planner.ComputeSeedPlantable(count, buffer)
    end
    return count
end

function StockPiler.AutoGrow.NeedsSeedConversion(seedUid)
    seedUid = tonumber(seedUid) or 0
    if seedUid <= 0 then
        return false
    end
    local buffer = 4
    if StockPiler.Planner and StockPiler.Planner.GetSeedBufferMin then
        buffer = StockPiler.Planner.GetSeedBufferMin()
    end
    if StockPiler.Planner and StockPiler.Planner.NeedsSeedConversion then
        return StockPiler.Planner.NeedsSeedConversion(StockPiler.AutoGrow.GetEffectiveSeedCount(seedUid), buffer)
    end
    return StockPiler.AutoGrow.GetEffectiveSeedCount(seedUid) < buffer
end

function StockPiler.AutoGrow.GetRawSeedCount(seedUid)
    seedUid = tonumber(seedUid) or 0
    if seedUid <= 0 then
        return 0
    end
    if StockPiler.Inventory and StockPiler.Inventory.CountByUniqueId then
        local count = StockPiler.Inventory.CountByUniqueId(seedUid)
        return tonumber(count) or 0
    end
    return 0
end

local function PlantDisplayName(plotData, plotNum)
    if type(plotData) ~= "table" then
        return L"Plot " .. towstring(tostring(plotNum or "?"))
    end
    -- Seed.name is the planted crop. PlantName is overwritten by the last
    -- additive (e.g. Arid Soil) once soil/water/nutrient is added.
    if type(plotData.Seed) == "table" and plotData.Seed.name and plotData.Seed.name ~= L"" then
        return plotData.Seed.name
    end
    if plotData.PlantName and plotData.PlantName ~= L"" then
        return plotData.PlantName
    end
    return L"Plot " .. towstring(tostring(plotNum or "?"))
end

local function SeedItemData(plotData)
    if type(plotData) ~= "table" or type(plotData.Seed) ~= "table" then
        return nil
    end
    local seed = plotData.Seed
    if seed.rarity ~= nil or seed.itemSet ~= nil then
        return seed
    end
    local uid = tonumber(seed.uniqueID) or 0
    if uid > 0 and StockPiler.Inventory and StockPiler.Inventory.CountByUniqueId then
        local _, sample = StockPiler.Inventory.CountByUniqueId(uid)
        if type(sample) == "table" then
            return sample
        end
    end
    if seed.name and seed.name ~= L"" then
        return seed
    end
    return nil
end

local function ItemRarityColor(itemData)
    if itemData and DataUtils and DataUtils.GetItemRarityColor then
        local ok, color = StockPiler.TryCallQuiet("DataUtils.GetItemRarityColor", DataUtils.GetItemRarityColor, itemData)
        if ok and type(color) == "table" then
            return color
        end
    end
    if DefaultColor and DefaultColor.WHITE then
        return DefaultColor.WHITE
    end
    return { r = 255, g = 255, b = 255 }
end

local function FormatTooltipIcon(iconNum)
    iconNum = tonumber(iconNum) or 0
    if iconNum <= 0 then
        return L""
    end
    return towstring(string.format("<icon%05d>", iconNum))
end

local function SeedIconNum(plotData)
    if type(plotData) ~= "table" then
        return 0
    end
    if type(plotData.Seed) == "table" then
        local iconNum = tonumber(plotData.Seed.iconNum) or 0
        if iconNum > 0 then
            return iconNum
        end
        local uid = tonumber(plotData.Seed.uniqueID) or 0
        if uid > 0 and StockPiler.Inventory and StockPiler.Inventory.CountByUniqueId then
            local _, sample = StockPiler.Inventory.CountByUniqueId(uid)
            if type(sample) == "table" and tonumber(sample.iconNum) and tonumber(sample.iconNum) > 0 then
                return tonumber(sample.iconNum)
            end
        end
    end
    return 0
end

local function FormatPlotTooltipTitle(plotNum)
    return L"Plot " .. towstring(tostring(plotNum))
end

local function FormatPlotTooltipSeedLine(plotData, plotNum)
    local icon = FormatTooltipIcon(SeedIconNum(plotData))
    local name = PlantDisplayName(plotData, plotNum)
    if icon ~= L"" then
        return icon .. L" " .. name
    end
    return name
end

local function AdditiveSlotFilled(slot)
    return type(slot) == "table" and (tonumber(slot.id) or 0) ~= 0
end

local function FormatPlotTooltipAdditiveLines(plotData)
    local lines = {}
    if type(plotData) ~= "table" or type(plotData.Additives) ~= "table" then
        return lines
    end
    local types = (GameData and GameData.CultivationTypes) or {}
    local order = {
        { tonumber(types.SOIL) or 2, L"Soil" },
        { tonumber(types.WATERCAN) or 3, L"Water" },
        { tonumber(types.NUTRIENT) or 4, L"Nutrient" },
    }
    for i = 1, #order do
        local slot = plotData.Additives[order[i][1]]
        if AdditiveSlotFilled(slot) then
            local icon = FormatTooltipIcon(slot.iconNum)
            local name = slot.name
            if name == nil or name == L"" then
                name = order[i][2]
            end
            if icon ~= L"" then
                lines[#lines + 1] = icon .. L" " .. name
            else
                lines[#lines + 1] = order[i][2] .. L" " .. name
            end
        end
    end
    return lines
end

local function FormatPlotTooltipStatus(stage)
    return StageLabel(stage)
end

function StockPiler.AutoGrow.FormatTooltipIcon(iconNum)
    return FormatTooltipIcon(iconNum)
end

function StockPiler.AutoGrow.GetItemRarityColor(itemData)
    return ItemRarityColor(itemData)
end

local function setTooltipRowColor(row, column, color)
    if not color or not Tooltips then
        return
    end
    if Tooltips.SetTooltipColor then
        Tooltips.SetTooltipColor(row, column, color.r or 255, color.g or 255, color.b or 255)
    elseif Tooltips.SetTooltipColorDef then
        Tooltips.SetTooltipColorDef(row, column, color)
    end
end

local function setTooltipBodyColor(row, column)
    if Tooltips and Tooltips.COLOR_BODY then
        setTooltipRowColor(row, column, Tooltips.COLOR_BODY)
    else
        setTooltipRowColor(row, column, { r = 255, g = 255, b = 255 })
    end
end

local function applyTooltipTextRow(row, text, color)
    Tooltips.SetTooltipText(row, 1, text or L"", false)
    if color then
        setTooltipRowColor(row, 1, color)
    else
        setTooltipBodyColor(row, 1)
    end
end

function StockPiler.AutoGrow.ApplyPlotTooltipRow(row, entry)
    row = tonumber(row) or 1
    if type(entry) ~= "table" then
        return row + 1
    end
    if entry.noPlants == true then
        applyTooltipTextRow(row, entry.text or L"No plants growing.")
        return row + 1
    end
    if entry.title and entry.title.text and entry.title.text ~= L"" then
        local heading = entry.title.color
            or (Tooltips and Tooltips.COLOR_HEADING)
            or { r = 255, g = 204, b = 102 }
        applyTooltipTextRow(row, entry.title.text, heading)
        row = row + 1
    end
    if entry.seed and entry.seed.text and entry.seed.text ~= L"" then
        applyTooltipTextRow(row, entry.seed.text, entry.seed.color)
        row = row + 1
    end
    if type(entry.additives) == "table" then
        local lines = entry.additives.lines
        if type(lines) ~= "table" and entry.additives.text and entry.additives.text ~= L"" then
            lines = { entry.additives.text }
        end
        if type(lines) == "table" then
            for i = 1, #lines do
                if lines[i] and lines[i] ~= L"" then
                    applyTooltipTextRow(row, lines[i])
                    row = row + 1
                end
            end
        end
    end
    if entry.status and entry.status.text and entry.status.text ~= L"" then
        applyTooltipTextRow(row, entry.status.text)
        row = row + 1
    elseif entry.text and entry.text ~= L"" then
        applyTooltipTextRow(row, entry.text, entry.color)
        row = row + 1
    end
    return row
end

function StockPiler.AutoGrow.ApplyPlotTooltipRows(startRow, refresh)
    if not Tooltips or type(Tooltips.SetTooltipText) ~= "function" then
        return tonumber(startRow) or 1
    end
    startRow = tonumber(startRow) or 1
    local entries = StockPiler.AutoGrow.GetPlotTooltipEntries(refresh)
    if #entries == 0 or (entries[1] and entries[1].noPlants == true) then
        Tooltips.SetTooltipText(startRow, 1, L"No plants growing.", false)
        setTooltipBodyColor(startRow, 1)
        return startRow + 1
    end
    Tooltips.SetTooltipText(startRow, 1, L"Growing:", false)
    setTooltipBodyColor(startRow, 1)
    startRow = startRow + 1
    for i = 1, #entries do
        startRow = StockPiler.AutoGrow.ApplyPlotTooltipRow(startRow, entries[i])
    end
    return startRow
end

local HARVEST_TOOLTIP_ICON = 3317
-- DefaultTooltip only ships 17 rows. Four plots with seed + 3 additives + status
-- plus header/plan need more. Extra rows are created once from TooltipRow.
local HARVEST_TOOLTIP_ROWS = 36

function StockPiler.AutoGrow.EnsureHarvestTooltipRows()
    if StockPiler.AutoGrow._harvestTooltipRowsReady == true then
        return true
    end
    if not DoesWindowExist("DefaultTooltip") or CreateWindowFromTemplate == nil then
        return false
    end
    local have = tonumber(Tooltips and Tooltips.NUM_ROWS) or 17
    for rowNum = have + 1, HARVEST_TOOLTIP_ROWS do
        local rowName = "DefaultTooltipRow" .. tostring(rowNum)
        if not DoesWindowExist(rowName) then
            local ok = StockPiler.TryCall("CreateWindowFromTemplate", CreateWindowFromTemplate, rowName, "TooltipRow", "DefaultTooltip")
            if not ok or not DoesWindowExist(rowName) then
                return false
            end
            WindowClearAnchors(rowName)
            local prev = "DefaultTooltipRow" .. tostring(rowNum - 1)
            -- Same anchors as DefaultTooltipRow2+ in easystem_tooltips.
            WindowAddAnchor(rowName, "bottomleft", prev, "topleft", 0, 5)
            WindowAddAnchor(rowName, "bottomright", prev, "topright", 0, 5)
        end
    end
    if Tooltips then
        local n = tonumber(Tooltips.NUM_ROWS) or 17
        if n < HARVEST_TOOLTIP_ROWS then
            Tooltips.NUM_ROWS = HARVEST_TOOLTIP_ROWS
        end
    end
    StockPiler.AutoGrow._harvestTooltipRowsReady = true
    return true
end

--- Shared Watch-tab / hotbar-macro harvest tooltip.
function StockPiler.AutoGrow.ShowHarvestTooltip(anchorWindow, anchor)
    if not Tooltips or type(Tooltips.CreateTextOnlyTooltip) ~= "function" then
        return
    end
    if anchorWindow == nil or anchorWindow == "" then
        return
    end
    StockPiler.AutoGrow.EnsureHarvestTooltipRows()
    Tooltips.CreateTextOnlyTooltip(anchorWindow)
    local titleIcon = FormatTooltipIcon(HARVEST_TOOLTIP_ICON)
    if titleIcon ~= L"" then
        Tooltips.SetTooltipText(1, 1, titleIcon .. L" StockPiler Harvest")
    else
        Tooltips.SetTooltipText(1, 1, L"StockPiler Harvest")
    end
    local heading = (Tooltips and Tooltips.COLOR_HEADING) or { r = 255, g = 204, b = 102 }
    setTooltipRowColor(1, 1, heading)
    local ready = (StockPiler.AutoGrow.CanHarvestNow and StockPiler.AutoGrow.CanHarvestNow())
        and L"ready" or L"not ready"
    Tooltips.SetTooltipText(2, 1, L"Click or hotkey: harvest next grown plot (" .. ready .. L").")
    local agOn = IsEnabled()
    local ag = agOn and L"on" or L"off"
    local agIcon = agOn and L"<icon00057>" or L"<icon00058>"
    Tooltips.SetTooltipText(3, 1, agIcon .. L" AutoGrow is " .. ag .. L". Ctrl+click: toggle AutoGrow.")
    local nextRow = StockPiler.AutoGrow.ApplyPlotTooltipRows(4, true)
    if StockPiler.Planner and StockPiler.Planner.FormatGrowQueueText then
        local plan = nil
        if StockPiler.Planner.BuildPlan then
            plan = StockPiler.Planner.BuildPlan({ refresh = false })
        end
        local summary = StockPiler.Planner.FormatGrowQueueText(plan and plan.queue, 4)
        if summary and summary ~= L"" then
            Tooltips.SetTooltipText(nextRow, 1, summary, false)
            setTooltipBodyColor(nextRow, 1)
        end
    end
    Tooltips.Finalize()
    Tooltips.AnchorTooltip(anchor or Tooltips.ANCHOR_WINDOW_TOP)
end

function StockPiler.AutoGrow.FindRefinablePlantSlot(plantUid)
    plantUid = tonumber(plantUid) or 0
    if plantUid <= 0 then
        return 0, nil, nil
    end

    local seedType = (GameData and GameData.CultivationTypes and GameData.CultivationTypes.SEED) or 1
    local sporeType = (GameData and GameData.CultivationTypes and GameData.CultivationTypes.SPORE) or 5

    local function canRefine(item)
        if type(item) ~= "table" or tonumber(item.uniqueID) ~= plantUid then
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

    local function scanBag(bagItems, backpackType)
        if type(bagItems) ~= "table" then
            return 0, nil, backpackType
        end
        local bestSlot = 0
        local bestItem = nil
        local bestStack = 10000
        for slot, item in pairs(bagItems) do
            if canRefine(item) then
                local stack = tonumber(item.stackCount) or tonumber(item.StackCount) or 1
                if stack < bestStack then
                    bestSlot = slot
                    bestStack = stack
                    bestItem = item
                end
            end
        end
        return bestSlot, bestItem, backpackType
    end

    local craftBag, invBag = ReadBagTables()
    local slot, item, bagType = scanBag(craftBag, CraftingBackpackType())
    if slot > 0 then
        return slot, item, bagType
    end
    return scanBag(invBag, InventoryBackpackType())
end

--- How many plant items in bags can refine into seeds for this plantUid.
function StockPiler.AutoGrow.CountRefinablePlants(plantUid)
    plantUid = tonumber(plantUid) or 0
    if plantUid <= 0 then
        return 0
    end
    if StockPiler.Inventory and StockPiler.Inventory._snapshotDone == true then
        local idx = StockPiler.Inventory._refinableCountByPlantUid
        if type(idx) == "table" then
            return tonumber(idx[plantUid]) or 0
        end
    end
    if StockPiler.Perf and StockPiler.Perf.Mark then
        StockPiler.Perf.Mark("CountRefinableLive")
    end
    local seedType = (GameData and GameData.CultivationTypes and GameData.CultivationTypes.SEED) or 1
    local sporeType = (GameData and GameData.CultivationTypes and GameData.CultivationTypes.SPORE) or 5

    local function canRefine(item)
        if type(item) ~= "table" or tonumber(item.uniqueID) ~= plantUid then
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

    local function sumBag(bagItems)
        if type(bagItems) ~= "table" then
            return 0
        end
        local total = 0
        for _, item in pairs(bagItems) do
            if canRefine(item) then
                local stack = tonumber(item.stackCount) or tonumber(item.StackCount) or 1
                if stack < 1 then
                    stack = 1
                end
                total = total + stack
            end
        end
        return total
    end

    local craftBag, invBag = ReadBagTables()
    return sumBag(craftBag) + sumBag(invBag)
end

--- Refinable plant that produces this seed (UID may differ from the seed map cache).
function StockPiler.AutoGrow.FindRefinablePlantSlotForSeed(seedUid)
    seedUid = tonumber(seedUid) or 0
    if seedUid <= 0 or not StockPiler.SeedMap then
        return 0, nil, nil
    end
    local plantUid = 0
    if StockPiler.SeedMap.GetPlantUidForSeed then
        plantUid = tonumber(StockPiler.SeedMap.GetPlantUidForSeed(seedUid)) or 0
    end
    if plantUid > 0 then
        local slot, item, bagType = StockPiler.AutoGrow.FindRefinablePlantSlot(plantUid)
        if slot > 0 then
            return slot, item, bagType
        end
    end
    if type(StockPiler.SeedMap.ResolveSeedForPlantUid) ~= "function" then
        return 0, nil, nil
    end
    local seedType = (GameData and GameData.CultivationTypes and GameData.CultivationTypes.SEED) or 1
    local sporeType = (GameData and GameData.CultivationTypes and GameData.CultivationTypes.SPORE) or 5
    local bestSlot, bestItem, bestBag = 0, nil, nil
    local function consider(slot, item, backpackType)
        if type(item) ~= "table" then
            return
        end
        if StockPiler.SeedMap and StockPiler.SeedMap.ItemLooksLikeRefinablePlant then
            if not StockPiler.SeedMap.ItemLooksLikeRefinablePlant(item) then
                return
            end
        elseif item.isRefinable ~= true then
            return
        else
            local cultType = tonumber(item.cultivationType) or 0
            if cultType == seedType or cultType == sporeType then
                return
            end
        end
        local uid = tonumber(item.uniqueID) or 0
        if uid <= 0 then
            return
        end
        local seed = StockPiler.SeedMap.ResolveSeedForPlantUid(uid)
        if type(seed) == "table" and (tonumber(seed.uniqueID) or 0) == seedUid then
            bestSlot = slot
            bestItem = item
            bestBag = backpackType
        end
    end
    local craftBag, invBag = ReadBagTables()
    local craftType = CraftingBackpackType()
    local invType = InventoryBackpackType()
    if type(craftBag) == "table" then
        for slot, item in pairs(craftBag) do
            consider(slot, item, craftType)
            if bestSlot > 0 then
                return bestSlot, bestItem, bestBag
            end
        end
    end
    if type(invBag) == "table" then
        for slot, item in pairs(invBag) do
            consider(slot, item, invType)
            if bestSlot > 0 then
                return bestSlot, bestItem, bestBag
            end
        end
    end
    return 0, nil, nil
end

--- Any refinable plant (not seed/spore). Used when converting for refine byproducts
--- such as Arboreal Resin, which drop from any plant→seed convert.
function StockPiler.AutoGrow.FindAnyRefinablePlantSlot()
    local seedType = (GameData and GameData.CultivationTypes and GameData.CultivationTypes.SEED) or 1
    local sporeType = (GameData and GameData.CultivationTypes and GameData.CultivationTypes.SPORE) or 5

    local function canRefine(item)
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

    local function scanBag(bagItems, backpackType)
        if type(bagItems) ~= "table" then
            return 0, nil, backpackType
        end
        local bestSlot = 0
        local bestItem = nil
        local bestStack = 10000
        for slot, item in pairs(bagItems) do
            if canRefine(item) then
                local stack = tonumber(item.stackCount) or tonumber(item.StackCount) or 1
                if stack < bestStack then
                    bestSlot = slot
                    bestStack = stack
                    bestItem = item
                end
            end
        end
        return bestSlot, bestItem, backpackType
    end

    local craftBag, invBag = ReadBagTables()
    local slot, item, bagType = scanBag(craftBag, CraftingBackpackType())
    if slot > 0 then
        return slot, item, bagType
    end
    return scanBag(invBag, InventoryBackpackType())
end

local function CapRefineUses(plantUid, uses)
    uses = tonumber(uses) or 0
    if uses <= 0 then
        return 0
    end
    if StockPiler.Planner and StockPiler.Planner.WatchedPlantCraftSurplus then
        local surplus = tonumber(StockPiler.Planner.WatchedPlantCraftSurplus(plantUid)) or 0
        if uses > surplus then
            uses = surplus
        end
    end
    return uses
end

function StockPiler.AutoGrow.RefinePlantSlot(slot, item, backpackType, entry, uses, decisionKind)
    if SendUseItem == nil or type(item) ~= "table" then
        return false
    end
    if EA_Window_Backpack and EA_Window_Backpack.GetCursorForBackpack == nil then
        return false
    end

    local plantUid = tonumber(item.uniqueID) or 0
    local pending = tonumber(StockPiler.AutoGrow._pendingRefine[plantUid]) or 0
    if pending >= MAX_PENDING_REFINE then
        return false
    end

    uses = tonumber(uses) or 1
    if uses < 1 then
        uses = 1
    end
    local stack = tonumber(item.stackCount) or tonumber(item.StackCount) or 1
    uses = math.min(uses, stack, MAX_PENDING_REFINE - pending)
    if uses < 1 then
        return false
    end

    if StockPiler.SeedMap and StockPiler.SeedMap.BeginPendingRefine then
        StockPiler.SeedMap.BeginPendingRefine(item)
    end

    local location = EA_Window_Backpack.GetCursorForBackpack(backpackType or CraftingBackpackType())
    local sent = 0
    StockPiler.AutoGrow._refineBatchActive = true
    SuppressInventorySideEffects()
    for _ = 1, uses do
        local ok, err = StockPiler.TryCall("SendUseItem", SendUseItem, location, slot, 0, 0, 0)
        if not ok then
            D("AutoGrow refine failed slot=" .. tostring(slot) .. " err=" .. tostring(err))
            break
        end
        sent = sent + 1
    end
    StockPiler.AutoGrow._refineBatchActive = false
    if sent <= 0 then
        return false
    end

    StockPiler.AutoGrow._pendingRefine[plantUid] = pending + sent
    do
        local seedUid = tonumber(entry and entry.seedUid) or 0
        if seedUid <= 0 and plantUid > 0 and StockPiler.SeedMap
            and StockPiler.SeedMap.GetSeedUidsForPlant
        then
            local uids = StockPiler.SeedMap.GetSeedUidsForPlant(plantUid)
            if type(uids) == "table" then
                seedUid = tonumber(uids[1]) or 0
            end
        end
        LogRefineOp(string.format(
            "%s plantUid=%d seedUid=%d uses=%d name=%s plantable=%s %s",
            tostring(decisionKind or "refine"),
            plantUid,
            seedUid,
            sent,
            ToNarrow(item.name),
            tostring(entry and entry.seedPlantable or "?"),
            StockPiler.AutoGrow.GardenSummary()
        ))
    end
    if StockPiler.ScheduleBagWork then
        StockPiler.ScheduleBagWork(false)
    else
        RefreshWatchStatusIfOpen()
    end
    return true
end

function StockPiler.AutoGrow.MaybeAutoRefine()
    if StockPiler.BagWorkPending and StockPiler.BagWorkPending() then
        return false
    end
    if StockPiler.Perf and StockPiler.Perf.Mark then
        StockPiler.Perf.Mark("MaybeAutoRefine")
    end
    if not IsEnabled() then
        return false
    end
    StockPiler.AutoGrow._refineNoRefinable = false

    local allowed, gateReason = StockPiler.AutoGrow.ShouldAllowRefineNow()
    if allowed ~= true then
        LogGrow("refine skipped gate=" .. tostring(gateReason or "blocked"))
        return false
    end

    local seen = {}
    local plots = NumPlots()
    -- Post-harvest: grow-cycle wants emptyPlots only; buffer via CollectSeedBufferRefills.
    -- seed-buffer gate: only CollectSeedBufferRefills (buffer gap), not grow-cycle.
    local includeBuffer = gateReason == "post-harvest"
    local runBufferRefills = includeBuffer or gateReason == "seed-buffer"
    -- Build the plan once so CollectGrowCycleRefineJobs can reuse specDemand.
    StockPiler.AutoGrow.GetPlantQueue()

    -- Pre-plant and post-harvest: refine only enough seeds for empty plots.
    -- Buffer refill is CollectSeedBufferRefills (surplus-gated when plant-short).
    if gateReason ~= "seed-buffer"
        and StockPiler.Planner
        and StockPiler.Planner.CollectGrowCycleRefineJobs
    then
        local emptyPlots = 0
        for plotNum = 1, plots do
            if StockPiler.AutoGrow.CanPlantPlot(plotNum) then
                emptyPlots = emptyPlots + 1
            end
        end
        local jobs = StockPiler.Planner.CollectGrowCycleRefineJobs(emptyPlots, {
            includeBuffer = includeBuffer,
        })
        if type(jobs) == "table" then
            for i = 1, #jobs do
                local job = jobs[i]
                local plantUid = tonumber(job.plantUid) or 0
                local seenKey = plantUid > 0 and plantUid or (tonumber(job.seedUid) or 0)
                if seenKey > 0 and seen[seenKey] ~= true then
                    seen[seenKey] = true
                    local pending = plantUid > 0
                        and (tonumber(StockPiler.AutoGrow._pendingRefine[plantUid]) or 0)
                        or 0
                    if pending > 0 then
                        LogGrow("refine grow-cycle wait plantUid=" .. tostring(plantUid)
                            .. " pending=" .. tostring(pending))
                    else
                        -- Surplus-gated: keep brew-short plants in bags; only convert extras.
                        local uses = CapRefineUses(plantUid, tonumber(job.uses) or 0)
                        local slot, item, bagType = StockPiler.AutoGrow.FindRefinablePlantSlot(plantUid)
                        if slot <= 0 and job.seedUid and StockPiler.AutoGrow.FindRefinablePlantSlotForSeed then
                            slot, item, bagType = StockPiler.AutoGrow.FindRefinablePlantSlotForSeed(job.seedUid)
                        end
                        local bucket = includeBuffer and "post-harvest" or "pre-plant"
                        if uses > 0 and slot > 0 and type(item) == "table" then
                            LogGrow("refine grow-cycle plantUid=" .. tostring(plantUid)
                                .. " seedUid=" .. tostring(job.seedUid or 0)
                                .. " seedHave=" .. tostring(job.seedHave or 0)
                                .. " want=" .. tostring(job.wantSeeds or 0)
                                .. " emptyPlots=" .. tostring(emptyPlots)
                                .. " includeBuffer=" .. tostring(includeBuffer)
                                .. " deficit=" .. tostring(job.deficit or 0)
                                .. " yield=" .. tostring(job.harvestYield or 1)
                                .. " surplus=" .. tostring(job.surplus or 0)
                                .. " plantHave=" .. tostring(job.plantHave or 0)
                                .. " uses=" .. tostring(uses))
                            StockPiler.AutoGrow.MarkAllPlotsWantFill()
                            return StockPiler.AutoGrow.RefinePlantSlot(slot, item, bagType, {
                                seedUid = tonumber(job.seedUid) or 0,
                                seedPlantable = tonumber(job.seedHave) or 0,
                            }, uses, bucket)
                        end
                        if uses > 0 then
                            local skipKey = string.format(
                                "no-refinable:%s:%d:%d",
                                tostring(bucket),
                                plantUid,
                                tonumber(job.seedUid) or 0
                            )
                            if StockPiler.AutoGrow._lastRefineSkipKey ~= skipKey then
                                StockPiler.AutoGrow._lastRefineSkipKey = skipKey
                                LogRefineOp(string.format(
                                    "%s skip no-refinable plantUid=%d seedUid=%d seedHave=%d want=%d uses=%d",
                                    bucket,
                                    plantUid,
                                    tonumber(job.seedUid) or 0,
                                    tonumber(job.seedHave) or 0,
                                    tonumber(job.wantSeeds) or 0,
                                    uses
                                ))
                            end
                            -- Remember we cannot convert this plant right now so
                            -- post-harvest settle can clear instead of spinning forever.
                            StockPiler.AutoGrow._refineNoRefinable = true
                        end
                    end
                end
            end
        end
    end

    -- Shared across queue shortfall + byproduct surplus passes below.
    local queue = StockPiler.AutoGrow.GetPlantQueue()
    if type(queue) ~= "table" then
        queue = {}
    end

    -- Queue fallback (seed shortfall for assigned plots). Skip bufferGrow entries —
    -- those plant leftover seeds only; refining for them burned brew stock in 0.9.61.
    if gateReason ~= "seed-buffer" then
        for plotNum = 1, plots do
            local entry = queue[plotNum]
            if type(entry) == "table" and entry.bufferGrow ~= true then
                -- Use the queued seed UID even when bags have 0 seeds. ResolveSeedUid
                -- returns 0 in that case and would skip converting harvested plants.
                local seedUid = tonumber(entry.seedUid) or 0
                if seedUid <= 0 then
                    seedUid = StockPiler.AutoGrow.ResolveSeedUid(entry)
                end
                local plantUid = tonumber(entry.plantUid) or 0
                if plantUid <= 0 and seedUid > 0 and StockPiler.SeedMap and StockPiler.SeedMap.GetPlantUidForSeed then
                    plantUid = StockPiler.SeedMap.GetPlantUidForSeed(seedUid)
                end
                if seedUid > 0 and plantUid > 0 and seen[plantUid] ~= true then
                    seen[plantUid] = true
                    local seedHave = StockPiler.AutoGrow.GetEffectiveSeedCount(seedUid)
                    -- Only seeds for plots already assigned this seed — not all
                    -- empty plots (that overshot when harvest yield > 1).
                    local assigned = 0
                    for n = 1, plots do
                        local e = queue[n]
                        if type(e) == "table"
                            and e.bufferGrow ~= true
                            and (tonumber(e.seedUid) or 0) == seedUid
                        then
                            assigned = assigned + 1
                        end
                    end
                    local need = 0
                    if seedHave < assigned then
                        need = assigned - seedHave
                    end
                    need = CapRefineUses(plantUid, need)
                    local pendingRefine = tonumber(StockPiler.AutoGrow._pendingRefine[plantUid]) or 0
                    if need > 0 and pendingRefine < MAX_PENDING_REFINE then
                        local slot, item, bagType = StockPiler.AutoGrow.FindRefinablePlantSlot(plantUid)
                        if slot <= 0 and seedUid > 0 and StockPiler.AutoGrow.FindRefinablePlantSlotForSeed then
                            slot, item, bagType = StockPiler.AutoGrow.FindRefinablePlantSlotForSeed(seedUid)
                        end
                        if slot > 0 and type(item) == "table" then
                            LogGrow("refine queue P" .. tostring(plotNum)
                                .. " plantUid=" .. tostring(plantUid)
                                .. " seedUid=" .. tostring(seedUid)
                                .. " seedHave=" .. tostring(seedHave)
                                .. " assigned=" .. tostring(assigned)
                                .. " need=" .. tostring(need))
                            return StockPiler.AutoGrow.RefinePlantSlot(slot, item, bagType, entry, need, "queue")
                        end
                        LogGrow("refine skip P" .. tostring(plotNum)
                            .. " plantUid=" .. tostring(plantUid)
                            .. " seedUid=" .. tostring(seedUid)
                            .. " seedHave=" .. tostring(seedHave)
                            .. " reason=no plant in bags")
                    end
                end
            end
        end
    end

    -- Buffer gap: surplus first, else convert only (buffer - seedHave) plants.
    -- Do not CapRefineUses — surplus is often 0 exactly when plant targets are met.
    if runBufferRefills
        and StockPiler.Planner
        and StockPiler.Planner.CollectSeedBufferRefills
    then
        local jobs = StockPiler.Planner.CollectSeedBufferRefills()
        if type(jobs) == "table" then
            for i = 1, #jobs do
                local job = jobs[i]
                local plantUid = tonumber(job.plantUid) or 0
                if plantUid > 0 and seen[plantUid] ~= true then
                    seen[plantUid] = true
                    local pending = tonumber(StockPiler.AutoGrow._pendingRefine[plantUid]) or 0
                    if pending < MAX_PENDING_REFINE then
                        local uses = tonumber(job.uses) or 0
                        local slot, item, bagType = StockPiler.AutoGrow.FindRefinablePlantSlot(plantUid)
                        if uses > 0 and slot > 0 and type(item) == "table" then
                            LogGrow("refine buffer plantUid=" .. tostring(plantUid)
                                .. " seedUid=" .. tostring(job.seedUid or 0)
                                .. " seedHave=" .. tostring(job.seedHave or 0)
                                .. " surplus=" .. tostring(job.surplus or 0)
                                .. " gap=" .. tostring(job.bufferGap or 0)
                                .. " uses=" .. tostring(uses))
                            return StockPiler.AutoGrow.RefinePlantSlot(slot, item, bagType, {
                                seedUid = tonumber(job.seedUid) or 0,
                                seedPlantable = tonumber(job.seedHave) or 0,
                            }, uses, "seed-buffer")
                        end
                    end
                end
            end
        end
    end

    -- Convert extras (Arboreal Resin) after harvest only — do not burn brew
    -- plants during the pre-plant seed-for-plots pass.
    local extraNeed = 0
    if includeBuffer
        and StockPiler.Planner
        and StockPiler.Planner.RefineByproductCraftsShort
    then
        extraNeed = tonumber(StockPiler.Planner.RefineByproductCraftsShort()) or 0
    end
    if extraNeed > 0 then
        local function surplusOf(plantUid)
            if StockPiler.Planner and StockPiler.Planner.WatchedPlantCraftSurplus then
                return tonumber(StockPiler.Planner.WatchedPlantCraftSurplus(plantUid)) or 0
            end
            return 9999
        end
        local slot, item, bagType, entry = 0, nil, nil, nil
        local uses = extraNeed
        for plotNum = 1, plots do
            local queued = queue[plotNum]
            if type(queued) == "table" then
                local plantUid = tonumber(queued.plantUid) or 0
                if plantUid > 0 and surplusOf(plantUid) > 0 then
                    slot, item, bagType = StockPiler.AutoGrow.FindRefinablePlantSlot(plantUid)
                    if slot > 0 then
                        entry = queued
                        uses = extraNeed
                        if surplusOf(plantUid) < uses then
                            uses = surplusOf(plantUid)
                        end
                        break
                    end
                end
            end
        end
        if slot <= 0 then
            slot, item, bagType = StockPiler.AutoGrow.FindAnyRefinablePlantSlot()
            if slot > 0 and type(item) == "table" then
                local plantUid = tonumber(item.uniqueID) or 0
                if surplusOf(plantUid) <= 0 then
                    slot, item, bagType = 0, nil, nil
                else
                    uses = extraNeed
                    if surplusOf(plantUid) < uses then
                        uses = surplusOf(plantUid)
                    end
                end
            end
        end
        if slot > 0 and type(item) == "table" and uses > 0 then
            local plantUid = tonumber(item.uniqueID) or 0
            uses = CapRefineUses(plantUid, uses)
        end
        if slot > 0 and type(item) == "table" and uses > 0 then
            LogGrow("refine byproduct need=" .. tostring(extraNeed)
                .. " uses=" .. tostring(uses)
                .. " plantUid=" .. tostring(item.uniqueID or 0))
            return StockPiler.AutoGrow.RefinePlantSlot(slot, item, bagType, entry, uses, "byproduct-resin")
        end
        LogGrow("refine byproduct skip need=" .. tostring(extraNeed)
            .. " reason=no surplus plant in bags")
    end
    return false
end

function StockPiler.AutoGrow.OnRefineComplete(plantUid, seedUid)
    local pending = StockPiler.AutoGrow._autoRefinePending
    StockPiler.AutoGrow._autoRefinePending = nil
    if type(pending) == "table" and StockPiler.NotifyAutoGrowRefined then
        StockPiler.NotifyAutoGrowRefined(plantUid, seedUid)
    end
    if StockPiler.AutoGrow._refineBatchActive == true then
        return
    end
    if IsEnabled() then
        StockPiler.AutoGrow.MarkAllPlotsWantFill()
        StockPiler.AutoGrow.MarkRefineDue()
    end
    if StockPiler.ScheduleBagWork then
        StockPiler.ScheduleBagWork(false)
    else
        RefreshWatchStatusIfOpen()
    end
end

function StockPiler.AutoGrow.NotifyStageChange(plotNum, plotData, stage)
    if not IsEnabled() then
        return
    end
    if not (StockPiler.NotifyAutoGrowStage and StockPiler.StatusMessagesEnabled and StockPiler.StatusMessagesEnabled()) then
        return
    end
    stage = NormalizeStage(stage)
    if StockPiler.AutoGrow._lastNotifiedStage[plotNum] == stage then
        return
    end
    if stage == StageEmpty() then
        StockPiler.AutoGrow._lastNotifiedStage[plotNum] = stage
        return
    end
    StockPiler.AutoGrow._lastNotifiedStage[plotNum] = stage
    if stage ~= StageGrown() then
        return
    end
    local plantName = PlantDisplayName(plotData, plotNum)
    StockPiler.NotifyAutoGrowStage(plotNum, plantName, StageLabel(stage), true)
end

function StockPiler.AutoGrow.GetPlantQueue()
    if StockPiler.AutoGrow._buildingPlantQueue == true then
        return StockPiler.AutoGrow._cachedPlantQueue or {}
    end
    -- Harvest burst: keep the last queue until FlushBagWork runs once.
    if StockPiler.BagWorkPending and StockPiler.BagWorkPending() then
        return StockPiler.AutoGrow._cachedPlantQueue or {}
    end
    local snapGen = StockPiler.Inventory and tonumber(StockPiler.Inventory._snapshotGen) or 0
    -- Reuse the cached queue until something explicitly dirties it.
    -- Snap gen changes on every plant bag tick and must not rebuild the plan
    -- once plots are assigned. An empty assignment after /reloadui is often
    -- the first incomplete bag snap; rebuild when bags change so we do not
    -- sit idle until AutoGrow is toggled.
    if StockPiler.AutoGrow._plantQueueDirty ~= true
        and type(StockPiler.AutoGrow._cachedPlantQueue) == "table"
    then
        local emptyStuck = (tonumber(StockPiler.AutoGrow._queueAssigned) or 0) <= 0
            and IsEnabled()
            and StockPiler.AutoGrow.HasEmptyPlotWantingFill()
            and snapGen ~= (tonumber(StockPiler.AutoGrow._queueSnapGen) or -1)
        if emptyStuck ~= true then
            return StockPiler.AutoGrow._cachedPlantQueue
        end
        LogGrow("queue retry after empty assign snap=" .. tostring(snapGen))
        if StockPiler.Planner and StockPiler.Planner.InvalidatePlanCache then
            StockPiler.Planner.InvalidatePlanCache()
        end
    end
    if not (StockPiler.Planner and StockPiler.Planner.BuildPlan) then
        return {}
    end
    StockPiler.AutoGrow._buildingPlantQueue = true
    if StockPiler.Perf and StockPiler.Perf.Begin then
        StockPiler.Perf.Begin("GetPlantQueue")
    end
    local plan = StockPiler.Planner.BuildPlan({ refresh = false })
    if StockPiler.Perf and StockPiler.Perf.End then
        StockPiler.Perf.End("GetPlantQueue")
    end
    StockPiler.AutoGrow._buildingPlantQueue = false
    if type(plan) ~= "table" then
        LogGrow("queue build failed")
        return StockPiler.AutoGrow._cachedPlantQueue or {}
    end
    local queue = (type(plan) == "table" and type(plan.queue) == "table") and plan.queue or {}
    StockPiler.AutoGrow._cachedPlantQueue = queue
    StockPiler.AutoGrow._plantQueueDirty = false
    StockPiler.AutoGrow._queueSnapGen = snapGen
    StockPiler.AutoGrow._queueAssigned = 0
    StockPiler.AutoGrow._lastPlantSkip = nil
    local assigned = 0
    local bufferGrow = 0
    for plotNum = 1, NumPlots() do
        if type(queue[plotNum]) == "table" then
            assigned = assigned + 1
            if queue[plotNum].bufferGrow == true then
                bufferGrow = bufferGrow + 1
            end
        end
    end
    StockPiler.AutoGrow._queueAssigned = assigned
    LogGrow(
        "queue rebuilt snap=" .. tostring(snapGen)
            .. " assigned=" .. tostring(assigned)
            .. " bufferGrow=" .. tostring(bufferGrow)
            .. " emptyWantFill=" .. tostring(StockPiler.AutoGrow.CountEmptyPlotsWantingFill())
            .. " " .. StockPiler.AutoGrow.GardenSummary()
    )
    if StockPiler.AutoGrow.LogGrowQueueSummary then
        StockPiler.AutoGrow.LogGrowQueueSummary(plan)
    end
    return queue
end

function StockPiler.AutoGrow.GetPlotAssignment(plotNum)
    plotNum = tonumber(plotNum) or 0
    if plotNum <= 0 then
        return nil
    end
    local queue = StockPiler.AutoGrow.GetPlantQueue()
    local entry = queue[plotNum]
    if type(entry) ~= "table" then
        return nil
    end
    if EntrySeedPlantable(entry) <= 0 then
        return nil
    end
    local uid = StockPiler.AutoGrow.ResolveSeedUid(entry)
    if uid <= 0 then
        return nil
    end
    entry.seedUid = uid
    return entry
end

function StockPiler.AutoGrow.PickQueueEntry()
    local plots = NumPlots()
    for plotNum = 1, plots do
        local entry = StockPiler.AutoGrow.GetPlotAssignment(plotNum)
        if entry ~= nil then
            return entry, plotNum
        end
    end
    return nil
end

function StockPiler.AutoGrow.FindSeedSlot(seedUid, seedKey)
    seedUid = tonumber(seedUid) or 0
    seedKey = ToNarrow(seedKey or "")

    local function scanBag(bagItems, backpackType)
        if type(bagItems) ~= "table" then
            return 0, nil, backpackType
        end
        local bestSlot = 0
        local bestItem = nil
        local bestStack = 10000
        for slot, item in pairs(bagItems) do
            if type(item) == "table" then
                local uid = tonumber(item.uniqueID) or 0
                local matched = false
                if seedUid > 0 and uid == seedUid then
                    matched = true
                elseif seedKey ~= "" and NameEquals(item.name, seedKey) then
                    matched = true
                end
                if matched then
                    if StockPiler.Inventory and StockPiler.Inventory.CanUseCraftingItem
                        and not StockPiler.Inventory.CanUseCraftingItem(item)
                    then
                        matched = false
                    end
                end
                if matched then
                    local stack = tonumber(item.stackCount) or tonumber(item.StackCount) or 1
                    if stack < bestStack then
                        bestSlot = slot
                        bestStack = stack
                        bestItem = item
                    end
                end
            end
        end
        return bestSlot, bestItem, backpackType
    end

    local craftBag, invBag = ReadBagTables()
    local slot, item, bagType = scanBag(craftBag, CraftingBackpackType())
    if slot > 0 then
        return slot, item, bagType
    end
    slot, item, bagType = scanBag(invBag, InventoryBackpackType())
    return slot, item, bagType
end

-- Server pull (ECLTCMD_GET_INFO) — expensive; CultivationWindow.InitAllPlots uses this once at login.
function StockPiler.AutoGrow.RequestAllPlotInfo()
    if UpdateCraftingStatus == nil then
        return
    end
    local cult = CultivationTradeSkill()
    local plots = NumPlots()
    for plotNum = 1, plots do
        StockPiler.TryCall("UpdateCraftingStatus", UpdateCraftingStatus, cult, 4, plotNum)
    end
end

function StockPiler.AutoGrow.RequestPlotInfoOnce()
    if StockPiler.AutoGrow._plotInfoRequested == true then
        return false
    end
    StockPiler.AutoGrow._plotInfoRequested = true
    StockPiler.AutoGrow.RequestAllPlotInfo()
    return true
end

function StockPiler.AutoGrow.ResetPlotInfoRequest()
    StockPiler.AutoGrow._plotInfoRequested = false
end

-- Cheap local read; safe to call on cultivation events. Do not pair with RequestAllPlotInfo in loops.
function StockPiler.AutoGrow.RefreshHarvestButtonFromCache()
    if StockPilerTabAutoGrow and StockPilerTabAutoGrow.RefreshHarvestButton then
        StockPilerTabAutoGrow.RefreshHarvestButton()
    end
end

local function CountQueuedPlantsForSeed(seedUid, includePlot)
    seedUid = tonumber(seedUid) or 0
    includePlot = tonumber(includePlot) or 0
    if seedUid <= 0 then
        return 0
    end
    local n = 0
    local queue = StockPiler.AutoGrow.GetPlantQueue()
    local plots = NumPlots()
    for plotNum = 1, plots do
        local entry = queue[plotNum]
        if type(entry) == "table" then
            local uid = tonumber(entry.seedUid) or 0
            if uid <= 0 then
                uid = StockPiler.AutoGrow.ResolveSeedUid(entry)
            end
            if uid == seedUid then
                if plotNum == includePlot or StockPiler.AutoGrow.CanPlantPlot(plotNum) then
                    n = n + 1
                end
            end
        end
    end
    return n
end

function StockPiler.AutoGrow.MaybeWarnLastSeeds(seedUid, seedName, plotNum)
    seedUid = tonumber(seedUid) or 0
    if seedUid <= 0 then
        return
    end
    if type(StockPiler.AutoGrow._lastSeedExhaustWarn) ~= "table" then
        StockPiler.AutoGrow._lastSeedExhaustWarn = {}
    end
    local have = StockPiler.AutoGrow.GetEffectiveSeedCount(seedUid)
    if have > LAST_SEED_WARN_MAX then
        StockPiler.AutoGrow._lastSeedExhaustWarn[seedUid] = nil
        return
    end
    if have < 1 then
        StockPiler.AutoGrow._lastSeedExhaustWarn[seedUid] = nil
        return
    end
    local queued = CountQueuedPlantsForSeed(seedUid, plotNum)
    if queued < have then
        return
    end
    if StockPiler.AutoGrow._lastSeedExhaustWarn[seedUid] == true then
        return
    end
    StockPiler.AutoGrow._lastSeedExhaustWarn[seedUid] = true
    LogGrow(
        "last-seed warning seedUid=" .. tostring(seedUid)
            .. " have=" .. tostring(have)
            .. " queued=" .. tostring(queued)
    )
    if StockPiler.NotifyAutoGrowLastSeeds then
        StockPiler.NotifyAutoGrowLastSeeds(seedName, have)
    elseif StockPiler.Print then
        StockPiler.Print(L"Warning: AutoGrow is planting all remaining seeds ("
            .. towstring(tostring(have)) .. L").")
    end
end

--- True if bags, garden, or refinable plant mats can still continue this seed.
--- excludePlotNum: plot that just failed harvest (may still look planted).
function StockPiler.AutoGrow.SeedLineStillExists(seedUid, excludePlotNum)
    seedUid = tonumber(seedUid) or 0
    excludePlotNum = tonumber(excludePlotNum) or 0
    if seedUid <= 0 then
        return false
    end
    if CountSeedsInLiveBags(seedUid) > 0 then
        return true
    end
    if StockPiler.Inventory and StockPiler.Inventory.CountByUniqueId then
        local bagCount = tonumber(StockPiler.Inventory.CountByUniqueId(seedUid)) or 0
        if bagCount > 0 then
            return true
        end
    end
    local plots = NumPlots()
    for plotNum = 1, plots do
        if plotNum ~= excludePlotNum then
            local plotData = CachedPlot(plotNum)
            if type(plotData) == "table" then
                local stage = NormalizeStage(plotData.StageNum)
                if stage ~= StageEmpty() then
                    local planted = 0
                    if type(plotData.Seed) == "table" then
                        planted = tonumber(plotData.Seed.uniqueID) or 0
                    end
                    if planted == seedUid then
                        return true
                    end
                end
            end
        end
    end
    local plantUid = 0
    if StockPiler.SeedMap and StockPiler.SeedMap.GetPlantUidForSeed then
        plantUid = tonumber(StockPiler.SeedMap.GetPlantUidForSeed(seedUid)) or 0
    end
    if plantUid > 0 then
        if StockPiler.Inventory and StockPiler.Inventory.CountByUniqueId then
            local plantHave = tonumber(StockPiler.Inventory.CountByUniqueId(plantUid)) or 0
            if plantHave > 0 then
                return true
            end
        end
        if StockPiler.AutoGrow.FindRefinablePlantSlot then
            local slot = StockPiler.AutoGrow.FindRefinablePlantSlot(plantUid)
            if (tonumber(slot) or 0) > 0 then
                return true
            end
        end
    end
    return false
end

--- After a critical harvest failure (or similar), warn in red if the seed line is gone.
function StockPiler.AutoGrow.MaybeNotifySeedLineLost(seedUid, reason, excludePlotNum)
    seedUid = tonumber(seedUid) or 0
    if seedUid <= 0 then
        return false
    end
    if StockPiler.AutoGrow.SeedLineStillExists(seedUid, excludePlotNum) then
        return false
    end
    if type(StockPiler.AutoGrow._seedLineLostNotified) ~= "table" then
        StockPiler.AutoGrow._seedLineLostNotified = {}
    end
    if StockPiler.AutoGrow._seedLineLostNotified[seedUid] == true then
        return false
    end
    StockPiler.AutoGrow._seedLineLostNotified[seedUid] = true
    if type(StockPiler.AutoGrow._lastSeedExhaustWarn) == "table" then
        StockPiler.AutoGrow._lastSeedExhaustWarn[seedUid] = nil
    end
    local seedName = L"seed"
    if StockPiler.ItemDisplayName then
        seedName = StockPiler.ItemDisplayName(seedUid, L"seed")
    end
    LogGrow(
        "seed-line lost seedUid=" .. tostring(seedUid)
            .. " reason=" .. tostring(reason or "?")
            .. " name=" .. ToNarrow(seedName)
    )
    if StockPiler.NotifySeedLineLost then
        StockPiler.NotifySeedLineLost(seedName)
    elseif StockPiler.Print then
        StockPiler.Print(L"Lost seed line: " .. AsWString(seedName) .. L".")
    end
    return true
end

--- Clear lost-line debounce when the player acquires seeds again.
function StockPiler.AutoGrow.NoteSeedLinePresent(seedUid)
    seedUid = tonumber(seedUid) or 0
    if seedUid <= 0 then
        return
    end
    if type(StockPiler.AutoGrow._seedLineLostNotified) == "table" then
        StockPiler.AutoGrow._seedLineLostNotified[seedUid] = nil
    end
end

function StockPiler.AutoGrow.NotifyPlanted(plotNum, entry, reason)
    if StockPiler.NotifyAutoGrowPlanted then
        StockPiler.NotifyAutoGrowPlanted(plotNum, entry, reason)
        return
    end
    if not (StockPiler.NotifyFeature and StockPiler.StatusMessagesEnabled and StockPiler.StatusMessagesEnabled()) then
        return
    end
    local seedName = entry and entry.seedName or L"seed"
    local detail = L"Plot " .. towstring(tostring(plotNum)) .. L": " .. AsWString(seedName)
    if reason == "harvest" then
        detail = detail .. L" (after harvest)"
    end
    StockPiler.NotifyFeature(L"AutoGrow", L"Planted " .. detail .. L".")
end

function StockPiler.AutoGrow.PlantBlockReason(plotNum)
    if not IsEnabled() then
        return "disabled"
    end
    plotNum = tonumber(plotNum) or 0
    if plotNum <= 0 or plotNum > NumPlots() then
        return "invalid plot"
    end
    if StockPiler.AutoGrow.IsHarvestOpActive and StockPiler.AutoGrow.IsHarvestOpActive() then
        return "harvest busy"
    end
    if StockPiler.Inventory and StockPiler.Inventory.IsPlotLocked
        and StockPiler.Inventory.IsPlotLocked(plotNum)
    then
        return "locked"
    end
    local pending = tonumber(StockPiler.AutoGrow._pendingPlant[plotNum]) or 0
    if pending >= MAX_PENDING_PLANT then
        return "pending plant"
    end
    local plotData = StockPiler.AutoGrow._plotCache[plotNum]
    if type(plotData) == "table" and NormalizeStage(plotData.StageNum) ~= StageEmpty() then
        return "not empty stage=" .. tostring(NormalizeStage(plotData.StageNum))
    end
    return nil
end

function StockPiler.AutoGrow.CanPlantPlot(plotNum)
    return StockPiler.AutoGrow.PlantBlockReason(plotNum) == nil
end

function StockPiler.AutoGrow.TryPlantPlot(plotNum, reason)
    plotNum = tonumber(plotNum) or 0
    local block = StockPiler.AutoGrow.PlantBlockReason(plotNum)
    if block ~= nil then
        LogGrow("plant blocked plot=" .. tostring(plotNum) .. " reason=" .. block)
        return false
    end
    if AddCraftingItem == nil then
        LogGrow("plant blocked plot=" .. tostring(plotNum) .. " reason=AddCraftingItem missing")
        return false
    end

    local entry = StockPiler.AutoGrow.GetPlotAssignment(plotNum)
    if entry == nil then
        local raw = StockPiler.AutoGrow.GetPlantQueue()[plotNum]
        -- Idle empty plots with no assignment are expected; covered by ProcessTick
        -- "plant no progress" once — do not spam here.
        if type(raw) ~= "table" then
            return false
        end
        local liveUid = tonumber(raw.seedUid) or 0
        local liveHave = 0
        local buffer = 4
        if StockPiler.Planner and StockPiler.Planner.GetSeedBufferMin then
            buffer = StockPiler.Planner.GetSeedBufferMin()
        end
        if liveUid > 0 then
            liveHave = StockPiler.AutoGrow.GetEffectiveSeedCount(liveUid)
        end
        -- One line per seed shortfall (not per plot/tick).
        local skipMsg = "plant skip no-seeds seedUid=" .. tostring(liveUid)
            .. " liveHave=" .. tostring(liveHave)
            .. " buffer=" .. tostring(buffer)
            .. " plantable=" .. tostring(raw.seedPlantable or 0)
        if StockPiler.AutoGrow._lastPlantSkip ~= skipMsg then
            StockPiler.AutoGrow._lastPlantSkip = skipMsg
            LogGrow(skipMsg)
        end
        -- Queue booked this plot; refine must catch up before plant can proceed.
        StockPiler.AutoGrow.MarkRefineDue()
        return false
    end

    local seedUid = StockPiler.AutoGrow.ResolveSeedUid(entry)
    local seedKey = entry.seedKey or ToNarrow(entry.seedName)
    local slot, item, backpackType = StockPiler.AutoGrow.FindSeedSlot(seedUid, seedKey)
    if slot <= 0 or type(item) ~= "table" then
        D("AutoGrow plot=" .. tostring(plotNum) .. " no seed slot uid=" .. tostring(seedUid)
            .. " key=" .. tostring(seedKey))
        return false
    end
    seedUid = tonumber(item.uniqueID) or seedUid

    if GameData and GameData.Player and GameData.Player.Cultivation then
        GameData.Player.Cultivation.CurrentPlot = plotNum
    end

    local cult = CultivationTradeSkill()
    backpackType = backpackType or CraftingBackpackType()
    -- Engine bag/plot events fire inside AddCraftingItem; arm suppress first.
    SuppressInventorySideEffects()
    StockPiler.AutoGrow._pendingPlant[plotNum] = (tonumber(StockPiler.AutoGrow._pendingPlant[plotNum]) or 0) + 1
    StockPiler.AutoGrow._wantFill[plotNum] = false
    StockPiler.AutoGrow.MarkAdditiveDue()
    if StockPiler.AutoGrow.InvalidateHarvestBusyCache then
        StockPiler.AutoGrow.InvalidateHarvestBusyCache()
    end
    local ok, err = StockPiler.TryCall("AddCraftingItem", AddCraftingItem, cult, plotNum, slot, backpackType)
    if not ok then
        StockPiler.AutoGrow._pendingPlant[plotNum] = 0
        StockPiler.AutoGrow._wantFill[plotNum] = true
        if StockPiler.AutoGrow.InvalidateHarvestBusyCache then
            StockPiler.AutoGrow.InvalidateHarvestBusyCache()
        end
        D("AutoGrow AddCraftingItem failed plot=" .. tostring(plotNum) .. " err=" .. tostring(err))
        return false
    end

    StockPiler.AutoGrow.MaybeWarnLastSeeds(seedUid, entry and entry.seedName or seedKey, plotNum)
    StockPiler.AutoGrow.NoteSeedPlanted(seedUid)
    if StockPiler.AutoGrow.GetEffectiveSeedCount(seedUid) <= 0 then
        StockPiler.AutoGrow._lastSeedExhaustWarn[seedUid] = nil
    end
    do
        local comps = StockPiler.AutoGrow.QueuedPlantCompetitors(plotNum)
        local other = (#comps > 0) and table.concat(comps, " | ") or "none"
        LogPlantOp(string.format(
            "P%d %s uid=%d plantUid=%d reason=%s plantable=%s seedsLeft=%d otherQueued=%s %s",
            plotNum,
            ToNarrow(entry.seedName or seedKey),
            seedUid,
            tonumber(entry.plantUid) or 0,
            tostring(entry.plantReason or reason or "?"),
            tostring(entry.seedPlantable or 0),
            StockPiler.AutoGrow.GetEffectiveSeedCount(seedUid),
            other,
            StockPiler.AutoGrow.GardenSummary()
        ))
    end
    StockPiler.AutoGrow.NotifyPlanted(plotNum, entry, reason)
    return true
end

function StockPiler.AutoGrow.TryPlantNextEmptyPlot()
    if not IsEnabled() then
        return false
    end
    local plots = NumPlots()
    if plots <= 0 then
        return false
    end
    local start = tonumber(StockPiler.AutoGrow._fillPlotCursor) or 1
    if start < 1 or start > plots then
        start = 1
    end
    for i = 0, plots - 1 do
        local plotNum = ((start - 1 + i) % plots) + 1
        if StockPiler.AutoGrow._wantFill[plotNum] == true and StockPiler.AutoGrow.CanPlantPlot(plotNum) then
            if StockPiler.AutoGrow.TryPlantPlot(plotNum, "tick") then
                StockPiler.AutoGrow._fillPlotCursor = (plotNum % plots) + 1
                return true
            end
        end
    end
    return false
end

function StockPiler.AutoGrow.CountEmptyPlots()
    local n = 0
    local plots = NumPlots()
    for plotNum = 1, plots do
        local plotData = StockPiler.AutoGrow._plotCache[plotNum]
        local stage = StageEmpty()
        if type(plotData) == "table" then
            stage = NormalizeStage(plotData.StageNum)
        end
        if stage == StageEmpty() then
            n = n + 1
        end
    end
    return n
end

-- Plots that stay Empty never get _wantFill from OnPlotUpdated (only harvest
-- / toggle / inventory). Recover those so Restocking actually plants.
function StockPiler.AutoGrow.RecoverStuckEmptyPlots()
    if not IsEnabled() then
        return 0
    end
    local n = 0
    local plots = NumPlots()
    for plotNum = 1, plots do
        local plotData = StockPiler.AutoGrow._plotCache[plotNum]
        local stage = StageEmpty()
        if type(plotData) == "table" then
            stage = NormalizeStage(plotData.StageNum)
        end
        if stage == StageEmpty() and StockPiler.AutoGrow._wantFill[plotNum] ~= true then
            local pending = tonumber(StockPiler.AutoGrow._pendingPlant[plotNum]) or 0
            if pending < 1 then
                StockPiler.AutoGrow._wantFill[plotNum] = true
                n = n + 1
            end
        end
    end
    return n
end

function StockPiler.AutoGrow.CountEmptyPlotsWantingFill()
    local n = 0
    local plots = NumPlots()
    for plotNum = 1, plots do
        if StockPiler.AutoGrow._wantFill[plotNum] == true and StockPiler.AutoGrow.CanPlantPlot(plotNum) then
            n = n + 1
        end
    end
    return n
end

function StockPiler.AutoGrow.HasEmptyPlotWantingFill()
    return StockPiler.AutoGrow.CountEmptyPlotsWantingFill() > 0
end

--- True when any known seed stack is below the buffer and plants are on hand
--- to convert (buffer-gap only — see CollectSeedBufferRefills).
local function SeedBufferNeedsPlantConversion()
    if not (StockPiler.Planner and StockPiler.Planner.CollectSeedBufferRefills) then
        return false
    end
    local jobs = StockPiler.Planner.CollectSeedBufferRefills()
    return type(jobs) == "table" and #jobs > 0
end

local function PostHarvestBufferStillShort()
    if SeedBufferNeedsPlantConversion() then
        return true
    end
    if StockPiler.Planner and StockPiler.Planner.CollectGrowCycleRefineJobs then
        local jobs = StockPiler.Planner.CollectGrowCycleRefineJobs(0, {
            includeBuffer = true,
        })
        if type(jobs) == "table" and #jobs > 0 then
            return true
        end
    end
    return false
end

local function HasPendingRefineCounts()
    local pending = StockPiler.AutoGrow._pendingRefine
    if type(pending) ~= "table" then
        return false
    end
    for _, n in pairs(pending) do
        if (tonumber(n) or 0) > 0 then
            return true
        end
    end
    return false
end

--- Refine only pre-plant (empty plots want seeds), post-harvest buffer refill,
--- or when plant targets are met but the seed buffer is still short.
--- Harvest takes priority so buffer refill runs even while emptied plots want fill.
function StockPiler.AutoGrow.ShouldAllowRefineNow()
    if not IsEnabled() then
        return false, "disabled"
    end
    if StockPiler.AutoGrow._refineDirtyReason == "harvest" then
        return true, "post-harvest"
    end
    if StockPiler.AutoGrow.HasEmptyPlotWantingFill() then
        return true, "pre-plant"
    end
    if SeedBufferNeedsPlantConversion() then
        return true, "seed-buffer"
    end
    return false, "idle-grow"
end

--- True when a growing plot is missing the additive for its current stage.
--- Soil = Germination, Watering = Seedling, Nutrient = Flowering.
function StockPiler.AutoGrow.NeedsCurrentStageAdditive()
    if not IsEnabled() then
        return false
    end
    if not (StockPiler.Additives and StockPiler.Additives.IsEnabled and StockPiler.Additives.IsEnabled()) then
        return false
    end
    if not (StockPiler.Additives.CultTypeForStage and StockPiler.Additives.PlotHasAdditive) then
        return false
    end
    local plots = NumPlots()
    for plotNum = 1, plots do
        if (tonumber(StockPiler.AutoGrow._pendingAdditive[plotNum]) or 0) < 1 then
            local plotData = StockPiler.AutoGrow._plotCache[plotNum]
            if type(plotData) == "table" then
                local cultType = StockPiler.Additives.CultTypeForStage(NormalizeStage(plotData.StageNum))
                if cultType and not StockPiler.Additives.PlotHasAdditive(plotData, cultType) then
                    return true
                end
            end
        end
    end
    return false
end

function StockPiler.AutoGrow.TryApplyNextAdditive()
    if not IsEnabled() then
        return false
    end
    if not (StockPiler.Additives and StockPiler.Additives.IsEnabled and StockPiler.Additives.IsEnabled()) then
        return false
    end
    if AddCraftingItem == nil then
        return false
    end
    local plots = NumPlots()
    if plots <= 0 then
        return false
    end
    local start = tonumber(StockPiler.AutoGrow._additiveCursor) or 1
    if start < 1 or start > plots then
        start = 1
    end
    for i = 0, plots - 1 do
        local plotNum = ((start - 1 + i) % plots) + 1
        if (tonumber(StockPiler.AutoGrow._pendingAdditive[plotNum]) or 0) < 1 then
            local plotData = StockPiler.AutoGrow._plotCache[plotNum]
            if type(plotData) == "table" then
                local stage = NormalizeStage(plotData.StageNum)
                local cultType = StockPiler.Additives.CultTypeForStage(stage)
                if cultType
                    and not StockPiler.Additives.PlotHasAdditive(plotData, cultType)
                then
                    local slot, item, backpackType = StockPiler.Additives.FindBestInCraftBag(cultType)
                    if slot > 0 and type(item) == "table" then
                        if GameData and GameData.Player and GameData.Player.Cultivation then
                            GameData.Player.Cultivation.CurrentPlot = plotNum
                        end
                        local cult = CultivationTradeSkill()
                        backpackType = backpackType or CraftingBackpackType()
                        SuppressInventorySideEffects()
                        StockPiler.AutoGrow._pendingAdditive[plotNum] =
                            (tonumber(StockPiler.AutoGrow._pendingAdditive[plotNum]) or 0) + 1
                        local ok, err = StockPiler.TryCall("AddCraftingItem", AddCraftingItem, cult, plotNum, slot, backpackType)
                        if not ok then
                            StockPiler.AutoGrow._pendingAdditive[plotNum] = 0
                            D("AutoGrow AddCraftingItem additive failed plot=" .. tostring(plotNum)
                                .. " err=" .. tostring(err))
                            return false
                        end
                        StockPiler.AutoGrow._additiveCursor = (plotNum % plots) + 1
                        local info = StockPiler.Additives.Classify(item)
                        local role = info and info.role or "?"
                        LogGrow("additive plot=" .. tostring(plotNum)
                            .. " role=" .. tostring(role)
                            .. " uid=" .. tostring(item.uniqueID)
                            .. " slot=" .. tostring(slot))
                        if StockPiler.NotifyAutoGrowAdditive then
                            StockPiler.NotifyAutoGrowAdditive(plotNum, item, info)
                        end
                        return true
                    end
                end
            end
        end
    end
    return false
end

function StockPiler.AutoGrow.ProcessTick()
    if StockPiler.Perf and StockPiler.Perf.Mark then
        StockPiler.Perf.Mark("ProcessTick")
    end
    if not IsEnabled() then
        LogTickOnce("disabled")
        return
    end
    if StockPiler.BagWorkPending and StockPiler.BagWorkPending() then
        LogTickOnce("bag work pending")
        return
    end
    if StockPiler.Brew and StockPiler.Brew.IsBusy and StockPiler.Brew.IsBusy() then
        LogTickOnce("brew busy")
        return
    end
    -- Don't plant/refine while a harvest action is in flight (CurrentPlot race).
    if StockPiler.AutoGrow.IsHarvestOpActive and StockPiler.AutoGrow.IsHarvestOpActive() then
        LogTickOnce("harvest op active")
        return
    end
    local wait = tonumber(StockPiler.AutoGrow._refineWaitTicks) or 0
    if wait > 0 then
        StockPiler.AutoGrow._refineWaitTicks = wait - 1
    end
    local wantFill = StockPiler.AutoGrow.HasEmptyPlotWantingFill()
    local additiveDue = StockPiler.AutoGrow._additiveDirty == true
    -- Hold planting until post-harvest refine settles (buffer / pending uses).
    local holdPlantForHarvestRefine = StockPiler.AutoGrow._refineDirtyReason == "harvest"
        and (HasPendingRefineCounts() or StockPiler.AutoGrow._autoRefinePending ~= nil)
    if holdPlantForHarvestRefine then
        LogTickOnce("post-harvest refine pending")
        wantFill = false
    end

    -- Seed buffer first, then plant. Also after harvest (plot empty sets
    -- refineDirty). Throttle with refineWaitTicks; gate blocks idle grow.
    local refineDue = false
    if StockPiler.AutoGrow._refineDirty == true or wait <= 0 then
        if StockPiler.AutoGrow.ShouldAllowRefineNow() == true then
            refineDue = true
        end
    end
    if refineDue then
        StockPiler.AutoGrow._refineDirty = false
        StockPiler.AutoGrow._refineWaitTicks = 5
        if StockPiler.AutoGrow.MaybeAutoRefine() then
            LogTickOnce("started auto-refine")
            return
        end
        -- Keep post-harvest until live bag seeds meet the buffer and no empty
        -- plots remain. Use live counts (not effective) so a just-planted seed
        -- that is still "committed" cannot look like a full buffer.
        -- If bags have no refinable plants, stop spinning — harvest/plant must proceed.
        if StockPiler.AutoGrow._refineDirtyReason == "harvest" then
            local emptyWant = StockPiler.AutoGrow.HasEmptyPlotWantingFill()
            local bufferShort = PostHarvestBufferStillShort()
            local noRefinable = StockPiler.AutoGrow._refineNoRefinable == true
            if noRefinable then
                StockPiler.AutoGrow._refineDirtyReason = nil
                StockPiler.AutoGrow._refineNoRefinable = false
                if StockPiler.AutoGrow.InvalidateHarvestBusyCache then
                    StockPiler.AutoGrow.InvalidateHarvestBusyCache()
                end
                LogTickOnce("post-harvest refine cleared (no refinable)")
            elseif emptyWant or bufferShort then
                StockPiler.AutoGrow._refineDirty = true
            else
                StockPiler.AutoGrow._refineDirtyReason = nil
                if StockPiler.AutoGrow.InvalidateHarvestBusyCache then
                    StockPiler.AutoGrow.InvalidateHarvestBusyCache()
                end
            end
        end
    end
    if additiveDue then
        if StockPiler.AutoGrow.TryApplyNextAdditive() then
            LogTickOnce("applied additive")
            return
        end
        StockPiler.AutoGrow._additiveDirty = false
    end

    if not wantFill then
        local recovered = StockPiler.AutoGrow.RecoverStuckEmptyPlots()
        if recovered > 0 then
            LogGrow("recovered wantFill on " .. tostring(recovered) .. " empty plots")
        end
    end
    if not StockPiler.AutoGrow.HasEmptyPlotWantingFill() then
        -- Plant wave done: if harvest left the seed buffer short, keep
        -- converting until buffer is full (e.g. landed at 3/4).
        if StockPiler.AutoGrow._refineDirtyReason == "harvest" then
            if PostHarvestBufferStillShort() then
                StockPiler.AutoGrow._refineDirty = true
            else
                StockPiler.AutoGrow._refineDirtyReason = nil
                if StockPiler.AutoGrow.InvalidateHarvestBusyCache then
                    StockPiler.AutoGrow.InvalidateHarvestBusyCache()
                end
            end
        end
        local ready = StockPiler.AutoGrow.GetReadyHarvestPlots()
        local emptyN = StockPiler.AutoGrow.CountEmptyPlots()
        if #ready > 0 then
            LogTickOnce("harvest ready plots=" .. tostring(#ready))
        elseif emptyN > 0 then
            if StockPiler.AutoGrow._lastTickTrace ~= "empty no wantFill" then
                StockPiler.AutoGrow._lastTickTrace = "empty no wantFill"
                LogGrow(
                    "empty plots=" .. tostring(emptyN) .. " none want fill (pending or blocked)"
                )
            end
        else
            LogTickOnce("no empty plots wanting fill")
        end
        return
    end
    -- One plant per second (GatherButton: do not burst AddCraftingItem on all plots).
    if StockPiler.AutoGrow.TryPlantNextEmptyPlot() then
        StockPiler.AutoGrow._lastTickTrace = nil
        if StockPiler.AutoGrow.HasEmptyPlotWantingFill() then
            StockPiler.AutoGrow.MarkRefineDue()
        elseif StockPiler.AutoGrow._refineDirtyReason == "harvest" then
            -- Last empty plot filled while post-harvest is still active: ensure
            -- buffer refill runs even if the previous refine tick saw a full buffer.
            StockPiler.AutoGrow.MarkRefineDue("harvest")
        end
    else
        -- Idle: empty plots want fill but queue has nothing plantable.
        -- One tick reason only — do not flip-flop with "plant skip: no queue entry".
        local q = StockPiler.AutoGrow._cachedPlantQueue
        local assigned = 0
        if type(q) == "table" then
            for plotNum = 1, NumPlots() do
                if type(q[plotNum]) == "table" then
                    assigned = assigned + 1
                end
            end
        end
        local reason = "plant no progress assigned=" .. tostring(assigned)
            .. " emptyWantFill=" .. tostring(StockPiler.AutoGrow.CountEmptyPlotsWantingFill())
        if StockPiler.AutoGrow._lastTickTrace ~= reason then
            StockPiler.AutoGrow._lastTickTrace = reason
            LogGrow(reason)
            if StockPiler.Planner and StockPiler.Planner.MaybeNotifyProgressBlockers then
                StockPiler.Planner.MaybeNotifyProgressBlockers()
            end
        end
    end
end

function StockPiler.AutoGrow.OnPlotUpdated(plotNum, plotData)
    plotNum = tonumber(plotNum) or 0
    if plotNum <= 0 or type(plotData) ~= "table" then
        return
    end

    local stage = NormalizeStage(plotData.StageNum)
    local prev = StockPiler.AutoGrow._plotCache[plotNum]
    local prevStage = prev and NormalizeStage(prev.StageNum) or nil

    StockPiler.AutoGrow.NotifyStageChange(plotNum, plotData, stage)
    StockPiler.AutoGrow._plotCache[plotNum] = plotData
    if plotNum == 1 and StockPiler.Inventory and StockPiler.Inventory.EnforceProfessionGates then
        StockPiler.Inventory.EnforceProfessionGates()
    end

    local pending = StockPiler.AutoGrow._pendingHarvestNotify
    if type(pending) == "table" and pending.plotNum == plotNum then
        if prevStage and IsPlotReadyToHarvest(prevStage) and not IsPlotReadyToHarvest(stage) then
            if StockPiler.NotifyAutoGrowHarvested then
                StockPiler.NotifyAutoGrowHarvested(plotNum, pending.plantName, pending.manual == true)
            end
            StockPiler.AutoGrow._pendingHarvestNotify = nil
            if IsEnabled() then
                StockPiler.AutoGrow._wantFill[plotNum] = true
            end
            if #StockPiler.AutoGrow.GetReadyHarvestPlots() == 0 then
                StockPiler.AutoGrow._harvestCursor = 1
            end
        end
    end

    if IsPlotGrown(stage)
        and prevStage ~= StageGrown()
        and StockPiler.SeedMap
        and StockPiler.SeedMap.RefreshHarvestWatch
    then
        StockPiler.SeedMap.RefreshHarvestWatch(plotNum, plotData)
    end

    if stage ~= StageEmpty() then
        local wePlanted = (tonumber(StockPiler.AutoGrow._pendingPlant[plotNum]) or 0) > 0
        StockPiler.AutoGrow._pendingPlant[plotNum] = 0
        StockPiler.AutoGrow._wantFill[plotNum] = false
        -- Our own plant must not rebuild the grow plan; other empty plots
        -- keep their queue assignments.
        if not wePlanted and (prevStage == nil or prevStage == StageEmpty()) then
            StockPiler.AutoGrow.InvalidatePlantQueue()
            if StockPiler.Planner and StockPiler.Planner.InvalidatePlanCache then
                StockPiler.Planner.InvalidatePlanCache()
            end
        end
        -- Soil is applied at plant time. Watering and Nutrient only become
        -- legal at Seedling / Flowering, so re-arm when the stage changes.
        if IsEnabled()
            and StockPiler.Additives
            and StockPiler.Additives.IsEnabled
            and StockPiler.Additives.IsEnabled()
            and (prevStage == nil or prevStage ~= stage)
            and StockPiler.Additives.CultTypeForStage
            and StockPiler.Additives.PlotHasAdditive
        then
            local cultType = StockPiler.Additives.CultTypeForStage(stage)
            if cultType and not StockPiler.Additives.PlotHasAdditive(plotData, cultType) then
                StockPiler.AutoGrow.MarkAdditiveDue()
            end
        end
        return
    end

    local becameEmpty = prevStage ~= nil and prevStage ~= StageEmpty()
    if becameEmpty then
        if StockPiler.Perf and StockPiler.Perf.Mark then
            StockPiler.Perf.Mark("plotEmpty")
        end
        if StockPiler.SeedMap and StockPiler.SeedMap.TryCompletePendingHarvest then
            StockPiler.SeedMap.TryCompletePendingHarvest(true)
        end
        if StockPiler.AutoGrow.ClearHarvestOpLock then
            StockPiler.AutoGrow.ClearHarvestOpLock()
        end
        if StockPiler.AutoGrow.InvalidateHarvestBusyCache then
            StockPiler.AutoGrow.InvalidateHarvestBusyCache()
        end
        StockPiler.AutoGrow.MarkRefineDue("harvest")
        if StockPiler.ScheduleBagWork then
            StockPiler.ScheduleBagWork()
        end
    end

    if not IsEnabled() then
        return
    end

    if prevStage == StageGrown() or prevStage == StageHarvesting() then
        StockPiler.AutoGrow._wantFill[plotNum] = true
        StockPiler.AutoGrow._lastNotifiedStage[plotNum] = StageEmpty()
    elseif prevStage == nil or prevStage ~= StageEmpty() then
        StockPiler.AutoGrow._wantFill[plotNum] = true
    end
end

function StockPiler.AutoGrow.UpdatePlot(plotNum)
    plotNum = tonumber(plotNum) or 0
    if plotNum <= 0 or GetCultivationInfo == nil then
        return
    end
    local ok, plotData = StockPiler.TryCallQuiet("GetCultivationInfo", GetCultivationInfo, plotNum)
    if ok and type(plotData) == "table" then
        StockPiler.AutoGrow.OnPlotUpdated(plotNum, plotData)
    end
end

function StockPiler.AutoGrow.SyncAllPlots()
    local plots = NumPlots()
    for plotNum = 1, plots do
        StockPiler.AutoGrow.UpdatePlot(plotNum)
    end
end

function StockPiler.AutoGrow.GetReadyHarvestPlots()
    local ready = {}
    local plots = NumPlots()
    for plotNum = 1, plots do
        local plotData = CachedPlot(plotNum)
        if type(plotData) == "table" and IsPlotGrown(plotData.StageNum) then
            ready[#ready + 1] = plotNum
        end
    end
    table.sort(ready)
    return ready
end

function StockPiler.AutoGrow.HasHarvestInProgress()
    local plots = NumPlots()
    for plotNum = 1, plots do
        local plotData = CachedPlot(plotNum)
        if type(plotData) == "table" and IsPlotHarvesting(plotData.StageNum) then
            return true
        end
    end
    return false
end

--- True while AutoGrow has an in-flight AddCraftingItem plant on any plot.
function StockPiler.AutoGrow.HasPlantInProgress()
    for _, n in pairs(StockPiler.AutoGrow._pendingPlant) do
        if (tonumber(n) or 0) > 0 then
            return true
        end
    end
    return false
end

--- Harvest click → stage Harvesting → empty. Covers macro spam before the
--- engine updates plot stage. Stale Prepare notifies expire with the lock.
function StockPiler.AutoGrow.IsHarvestOpActive()
    if StockPiler.AutoGrow.HasHarvestInProgress() then
        return true
    end
    local now = NowSec()
    local lockUntil = tonumber(StockPiler.AutoGrow._harvestOpLockUntil) or 0
    if lockUntil > 0 and now < lockUntil then
        return true
    end
    if lockUntil > 0 and now >= lockUntil then
        StockPiler.AutoGrow._harvestOpLockUntil = 0
        -- Prepare without a successful harvest: allow retry / planting.
        if type(StockPiler.AutoGrow._pendingHarvestNotify) == "table"
            and not StockPiler.AutoGrow.HasHarvestInProgress()
        then
            StockPiler.AutoGrow._pendingHarvestNotify = nil
        end
    end
    return false
end

function StockPiler.AutoGrow.ArmHarvestOpLock(seconds)
    seconds = tonumber(seconds) or 1.5
    if seconds < 0.5 then
        seconds = 0.5
    end
    local untilT = NowSec() + seconds
    local cur = tonumber(StockPiler.AutoGrow._harvestOpLockUntil) or 0
    if untilT > cur then
        StockPiler.AutoGrow._harvestOpLockUntil = untilT
    end
    if StockPiler.AutoGrow.InvalidateHarvestBusyCache then
        StockPiler.AutoGrow.InvalidateHarvestBusyCache()
    end
end

function StockPiler.AutoGrow.ClearHarvestOpLock()
    StockPiler.AutoGrow._harvestOpLockUntil = 0
end

--- True while a harvest action is in flight, or a refine convert is pending.
--- Do not treat "planner still wants seeds" as busy — that stuck the harvest
--- macro glowing ready while clicks were blocked (no refinable plants in bags).
function StockPiler.AutoGrow.IsHarvestCycleBusy()
    local now = NowSec()
    local cachedAt = tonumber(StockPiler.AutoGrow._harvestBusyCachedAt) or 0
    if cachedAt > 0 and (now - cachedAt) < 0.25
        and StockPiler.AutoGrow._harvestBusyCached ~= nil
    then
        return StockPiler.AutoGrow._harvestBusyCached == true
    end

    local busy = false
    if StockPiler.AutoGrow.IsHarvestOpActive() then
        busy = true
    elseif StockPiler.AutoGrow._autoRefinePending ~= nil then
        busy = true
    elseif HasPendingRefineCounts() then
        busy = true
    end

    StockPiler.AutoGrow._harvestBusyCached = busy
    StockPiler.AutoGrow._harvestBusyCachedAt = now
    return busy
end

function StockPiler.AutoGrow.InvalidateHarvestBusyCache()
    StockPiler.AutoGrow._harvestBusyCached = nil
    StockPiler.AutoGrow._harvestBusyCachedAt = 0
end

function StockPiler.AutoGrow.CanHarvestNow()
    -- Do not harvest while a plant AddCraftingItem is in flight (CurrentPlot race).
    if StockPiler.AutoGrow.HasPlantInProgress() then
        return false
    end
    if StockPiler.AutoGrow.IsHarvestCycleBusy() then
        return false
    end
    return #StockPiler.AutoGrow.GetReadyHarvestPlots() > 0
end

--- Watch Harvest button: idle (empty), growing (occupied, not ready), harvest (ready).
function StockPiler.AutoGrow.GetHarvestUiState()
    if StockPiler.AutoGrow.CanHarvestNow() then
        return "harvest"
    end
    local plots = NumPlots()
    for plotNum = 1, plots do
        local plotData = CachedPlot(plotNum)
        if type(plotData) == "table" then
            local stage = NormalizeStage(plotData.StageNum)
            if stage ~= StageEmpty() then
                return "growing"
            end
        end
    end
    return "idle"
end

function StockPiler.AutoGrow.CountReadyHarvestPlots()
    return #StockPiler.AutoGrow.GetReadyHarvestPlots()
end

--- Macro fury glow: 4 only when harvest can fire now; else 1 if any plot growing/ready.
function StockPiler.AutoGrow.GetClosestPlotGlowLevel()
    if StockPiler.AutoGrow.CanHarvestNow and StockPiler.AutoGrow.CanHarvestNow() then
        return 4
    end
    local plots = NumPlots()
    local empty = StageEmpty()
    for plotNum = 1, plots do
        local plotData = CachedPlot(plotNum)
        if type(plotData) == "table" then
            local stage = NormalizeStage(plotData.StageNum)
            if stage ~= empty then
                return 1
            end
        end
    end
    return 0
end

--- Live plot / queue notes for a growable spec (tooltip). Does not rebuild the plant queue.
function StockPiler.AutoGrow.GrowingNotesForSpec(spec)
    if type(spec) ~= "table" then
        return L""
    end
    local seedUid = 0
    local specKey = ""
    if StockPiler.MaterialSpec and StockPiler.MaterialSpec.Key then
        specKey = StockPiler.MaterialSpec.Key(spec) or ""
    end
    if StockPiler.SeedMap and StockPiler.SeedMap.ResolveSeedForSpec then
        local seed = StockPiler.SeedMap.ResolveSeedForSpec(spec)
        if type(seed) == "table" then
            seedUid = tonumber(seed.uniqueID) or 0
        end
    end
    local parts = {}
    local seenPlot = {}
    local plots = NumPlots()
    for plotNum = 1, plots do
        local plotData = StockPiler.AutoGrow._plotCache[plotNum]
        if type(plotData) == "table" then
            local plotSeedUid = 0
            if type(plotData.Seed) == "table" then
                plotSeedUid = tonumber(plotData.Seed.uniqueID) or 0
            end
            local stage = NormalizeStage(plotData.StageNum)
            if seedUid > 0 and plotSeedUid == seedUid and stage ~= StageEmpty() then
                seenPlot[plotNum] = true
                parts[#parts + 1] = "P" .. tostring(plotNum) .. " " .. ToNarrow(StageLabel(stage))
            end
        end
    end
    local queue = StockPiler.AutoGrow._cachedPlantQueue
    if type(queue) == "table" and specKey ~= "" then
        for plotNum = 1, plots do
            if seenPlot[plotNum] ~= true then
                local entry = queue[plotNum]
                if type(entry) == "table" and tostring(entry.specKey or "") == specKey then
                    parts[#parts + 1] = "P" .. tostring(plotNum) .. " queued"
                end
            end
        end
    end
    if #parts == 0 then
        return L""
    end
    return towstring(table.concat(parts, ", "))
end

--- Structured tooltip rows for cultivation plots.
function StockPiler.AutoGrow.GetPlotTooltipEntries(refresh)
    if refresh == true and StockPiler.AutoGrow.SyncAllPlots then
        StockPiler.AutoGrow.SyncAllPlots()
    end
    local entries = {}
    local plots = NumPlots()
    local anyGrowing = false
    for plotNum = 1, plots do
        local plotData = CachedPlot(plotNum)
        if type(plotData) ~= "table" and refresh == true and GetCultivationInfo then
            local ok, data = StockPiler.TryCallQuiet("GetCultivationInfo", GetCultivationInfo, plotNum)
            if ok and type(data) == "table" then
                plotData = data
                StockPiler.AutoGrow._plotCache[plotNum] = data
            end
        end
        if type(plotData) == "table" then
            local stage = NormalizeStage(plotData.StageNum)
            if stage ~= StageEmpty() then
                anyGrowing = true
                local additiveLines = FormatPlotTooltipAdditiveLines(plotData)
                local entry = {
                    iconNum = SeedIconNum(plotData),
                    title = {
                        text = FormatPlotTooltipTitle(plotNum),
                    },
                    seed = {
                        text = FormatPlotTooltipSeedLine(plotData, plotNum),
                        color = ItemRarityColor(SeedItemData(plotData)),
                    },
                    status = {
                        text = FormatPlotTooltipStatus(stage),
                    },
                }
                if #additiveLines > 0 then
                    entry.additives = { lines = additiveLines }
                end
                entries[#entries + 1] = entry
            end
        end
    end
    if not anyGrowing then
        entries[#entries + 1] = {
            noPlants = true,
            text = L"No plants growing.",
        }
    end
    return entries
end

--- Flat text lines (three per plot: title, colored seed line, status).
function StockPiler.AutoGrow.GetPlotTooltipLines(refresh)
    local entries = StockPiler.AutoGrow.GetPlotTooltipEntries(refresh)
    local lines = {}
    for i = 1, #entries do
        local entry = entries[i]
        if entry.noPlants == true then
            lines[#lines + 1] = entry.text
        elseif entry.title and entry.title.text then
            lines[#lines + 1] = entry.title.text
            if entry.seed and entry.seed.text then
                lines[#lines + 1] = entry.seed.text
            end
            if type(entry.additives) == "table" then
                local additiveLines = entry.additives.lines
                if type(additiveLines) ~= "table" and entry.additives.text then
                    additiveLines = { entry.additives.text }
                end
                if type(additiveLines) == "table" then
                    for a = 1, #additiveLines do
                        lines[#lines + 1] = additiveLines[a]
                    end
                end
            end
            if entry.status and entry.status.text then
                lines[#lines + 1] = entry.status.text
            end
        elseif entry.text then
            lines[#lines + 1] = entry.text
        end
    end
    return lines
end

function StockPiler.AutoGrow.SelectHarvestPlot(manual)
    local ready = StockPiler.AutoGrow.GetReadyHarvestPlots()
    if #ready == 0 then
        return false
    end

    -- Always take the lowest ready plot number. Re-check live stage so a
    -- stale cache entry (e.g. P1 still "grown" while actually growing) cannot
    -- block P3/P4 that are truly ready.
    table.sort(ready)
    local start = tonumber(StockPiler.AutoGrow._harvestCursor) or 1
    if start < 1 then
        start = 1
    end
    for offset = 0, #ready - 1 do
        local idx = ((start - 1 + offset) % #ready) + 1
        local plotNum = ready[idx]
        StockPiler.AutoGrow.UpdatePlot(plotNum)
        local plotData = StockPiler.AutoGrow._plotCache[plotNum]
        if type(plotData) == "table" and IsPlotGrown(plotData.StageNum) then
            if GameData and GameData.Player and GameData.Player.Cultivation then
                GameData.Player.Cultivation.CurrentPlot = plotNum
            end
            StockPiler.AutoGrow._pendingHarvestNotify = {
                plotNum = plotNum,
                plantName = PlantDisplayName(plotData, plotNum),
                manual = manual == true,
            }
            if StockPiler.SeedMap and StockPiler.SeedMap.BeginPendingHarvest then
                StockPiler.SeedMap.BeginPendingHarvest(plotNum, plotData)
            end
            -- Next click starts after this plot in the ready list.
            StockPiler.AutoGrow._harvestCursor = idx + 1
            if StockPiler.AutoGrow._harvestCursor > #ready then
                StockPiler.AutoGrow._harvestCursor = 1
            end
            return true
        end
    end
    return false
end

function StockPiler.AutoGrow.PrepareHarvestPlot(manual)
    if StockPiler.Perf and StockPiler.Perf.Mark then
        StockPiler.Perf.Mark("PrepareHarvestPlot")
    end
    StockPiler.AutoGrow.EnsureHarvestActionBound()
    if not StockPiler.AutoGrow.SelectHarvestPlot(manual) then
        return false
    end
    -- Macro path prepares then fires the game action; arm the lock here so
    -- ProcessTick cannot plant before the plot stage flips to Harvesting.
    StockPiler.AutoGrow.ArmHarvestOpLock(1.5)
    local pending = StockPiler.AutoGrow._pendingHarvestNotify
    local plotNum = pending and pending.plotNum or 0
    local seedUid = 0
    if StockPiler.SeedMap and type(StockPiler.SeedMap._pendingHarvest) == "table" then
        seedUid = tonumber(StockPiler.SeedMap._pendingHarvest.seedUid) or 0
    end
    local readyN = 0
    if StockPiler.AutoGrow.GetReadyHarvestPlots then
        local ready = StockPiler.AutoGrow.GetReadyHarvestPlots() or {}
        readyN = #ready
    end
    LogHarvestOp(string.format(
        "start P%d plant=%s seedUid=%d manual=%s ready=%d %s",
        plotNum,
        ToNarrow(pending and pending.plantName or "?"),
        seedUid,
        tostring(manual == true),
        readyN,
        StockPiler.AutoGrow.GardenSummary(true)
    ))
    return true
end

function StockPiler.AutoGrow.ExecuteHarvest(manual)
    if StockPiler.Perf and StockPiler.Perf.Mark then
        StockPiler.Perf.Mark("harvestClick")
    end
    if StockPiler.AutoGrow.HasPlantInProgress and StockPiler.AutoGrow.HasPlantInProgress() then
        LogHarvestOp("blocked plant-in-progress")
        return false
    end
    if StockPiler.AutoGrow.IsHarvestOpActive and StockPiler.AutoGrow.IsHarvestOpActive() then
        LogHarvestOp("blocked harvest-already-active")
        return false
    end
    if not StockPiler.AutoGrow.PrepareHarvestPlot(manual) then
        return false
    end

    -- Cultivation does not harvest via PerformCrafting() (returns ok, no-op).
    -- Fire PERFORM_CRAFTING through a hotbar Action window (Harvest macro or cult skill).
    if StockPilerMacro and StockPilerMacro.FireHarvestGameAction then
        local ok = StockPilerMacro.FireHarvestGameAction()
        if ok then
            StockPiler.AutoGrow.ArmHarvestOpLock(1.5)
            return true
        end
        LogHarvestOp("FireHarvestGameAction failed")
    end

    StockPiler.AutoGrow.EnsureHarvestActionBound()

    if WindowGameAction then
        if DoesWindowExist(CULTIVATION_HARVEST_WIN) then
            BindCultivationHarvestAction(CULTIVATION_HARVEST_WIN)
            local ok = StockPiler.TryCall("WindowGameAction", WindowGameAction, CULTIVATION_HARVEST_WIN)
            if ok then
                StockPiler.AutoGrow.ArmHarvestOpLock(1.5)
                return true
            end
        end
        if DoesWindowExist(HARVEST_ACTION_WIN) then
            local ok = StockPiler.TryCall("WindowGameAction", WindowGameAction, HARVEST_ACTION_WIN)
            if ok then
                StockPiler.AutoGrow.ArmHarvestOpLock(1.5)
                return true
            end
        end
    end

    if PerformCrafting then
        local ok, err = StockPiler.TryCall("PerformCrafting", PerformCrafting, CultivationTradeSkill(), 1)
        if ok then
            StockPiler.AutoGrow.ArmHarvestOpLock(1.5)
            LogHarvestOp("PerformCrafting ok (may be no-op for cult)")
            return true
        end
        LogHarvestOp("PerformCrafting failed err=" .. tostring(err))
    end

    StockPiler.AutoGrow._pendingHarvestNotify = nil
    StockPiler.AutoGrow.ClearHarvestOpLock()
    LogHarvestOp("failed no-working-API")
    return false
end

function StockPiler.AutoGrow.TryHarvestNextPlot(manual)
    return StockPiler.AutoGrow.ExecuteHarvest(manual)
end

function StockPiler.AutoGrow.OnUpdate(timeElapsed)
    if StockPiler.Perf and StockPiler.Perf.Mark then
        StockPiler.Perf.Mark("AutoGrow.OnUpdate")
    end
    if StockPilerWindow and StockPilerWindow.FlushPendingListRepopulate then
        if StockPilerWindow._repopulatePending == true then
            if StockPiler.Perf and StockPiler.Perf.Mark then
                StockPiler.Perf.Mark("FlushListRepopulate")
            end
            StockPilerWindow.FlushPendingListRepopulate()
        end
    end
    if StockPiler.Perf and StockPiler.Perf.OnFrame then
        StockPiler.Perf.OnFrame(timeElapsed)
    end
    if StockPiler.SeedMap and StockPiler.SeedMap.TryCompletePendingHarvest
        and type(StockPiler.SeedMap._pendingHarvest) == "table"
    then
        if StockPiler.Perf and StockPiler.Perf.Mark then
            StockPiler.Perf.Mark("TryCompleteHarvest")
        end
        StockPiler.SeedMap.TryCompletePendingHarvest(false)
    end
    if StockPiler.FlushBagWorkIfDue then
        local flushed = StockPiler.FlushBagWorkIfDue()
        if flushed and StockPiler.Perf and StockPiler.Perf.Mark then
            StockPiler.Perf.Mark("FlushBagWorkIfDue")
        end
    end
    if StockPiler.Brew and StockPiler.Brew.IsBusy and StockPiler.Brew.IsBusy() then
        if StockPiler.Perf and StockPiler.Perf.Mark then
            StockPiler.Perf.Mark("Brew.OnUpdate")
        end
        if StockPiler.Brew.OnUpdate then
            StockPiler.Brew.OnUpdate(timeElapsed)
        end
    end
    StockPiler.AutoGrow._updateAccum = (StockPiler.AutoGrow._updateAccum or 0) + (tonumber(timeElapsed) or 0)
    if StockPiler.AutoGrow._updateAccum < TICK_INTERVAL_SEC then
        return
    end
    StockPiler.AutoGrow._updateAccum = StockPiler.AutoGrow._updateAccum - TICK_INTERVAL_SEC
    DecaySuppressInventorySideEffects()
    StockPiler.AutoGrow.DecayPendingRequests()
    if StockPiler.ProcessDeferredInventoryWork then
        StockPiler.ProcessDeferredInventoryWork()
    end
    if StockPiler.AutoGrow._plotsNeedSync == true then
        StockPiler.AutoGrow._plotsNeedSync = false
        StockPiler.AutoGrow.SyncAllPlots()
    end
    if IsEnabled() then
        StockPiler.AutoGrow.ProcessTick()
    end
    if StockPiler.Buy and StockPiler.Buy.OnTick then
        StockPiler.Buy.OnTick()
    end
    FlushWatchUiIfDirty()
end

function StockPiler.AutoGrow.OnCultivationUpdated()
    -- Event = cache write only. Cultivation can fire 8+ times in a burst.
    if GameData and GameData.Player and GameData.Player.Cultivation then
        local plotNum = tonumber(GameData.Player.Cultivation.UpdatedIndex) or 0
        if plotNum > 0 then
            StockPiler.AutoGrow.UpdatePlot(plotNum)
            return
        end
    end
    StockPiler.AutoGrow._plotsNeedSync = true
end

function StockPiler.AutoGrow.OnCraftingSlotUpdated()
    if not IsEnabled() then
        return
    end
    local emptyStage = StageEmpty()
    for plotNum = 1, NumPlots() do
        local prev = StockPiler.AutoGrow._plotCache[plotNum]
        if prev == nil or NormalizeStage(prev.StageNum) == emptyStage then
            if (tonumber(StockPiler.AutoGrow._pendingPlant[plotNum]) or 0) < MAX_PENDING_PLANT then
                StockPiler.AutoGrow._wantFill[plotNum] = true
            end
        end
    end
end

-- Same kick as toggling AutoGrow on: reset caches, fill empty plots, refine.
function StockPiler.AutoGrow.ResumeAfterLoad()
    if not IsEnabled() then
        return
    end
    StockPiler.AutoGrow.OnEnabledChanged(true)
    StockPiler.AutoGrow._updateAccum = TICK_INTERVAL_SEC
end

function StockPiler.AutoGrow.OnLoadingEnd()
    if StockPiler.Inventory and StockPiler.Inventory.EnforceProfessionGates then
        StockPiler.Inventory.EnforceProfessionGates()
    end
    if StockPiler.Inventory and StockPiler.Inventory.RefreshAllIfNeeded then
        StockPiler.Inventory.RefreshAllIfNeeded({ force = true })
    end
    StockPiler._bagCountsStale = false
    if StockPiler.SeedMap and StockPiler.SeedMap.EnsureSpecBootstrap then
        StockPiler.SeedMap.EnsureSpecBootstrap()
    end
    if StockPiler.Planner and StockPiler.Planner.InvalidatePlanCache then
        StockPiler.Planner.InvalidatePlanCache()
    end
    if StockPiler.ScheduleBagWork then
        StockPiler.ScheduleBagWork(false)
    end
    StockPiler.AutoGrow.ResetPlotInfoRequest()
    StockPiler.AutoGrow.ResumeAfterLoad()
    StockPiler.AutoGrow.RequestPlotInfoOnce()
    StockPiler.AutoGrow._watchUiDirty = true
    StockPiler.AutoGrow.RefreshHarvestButtonFromCache()
    if StockPilerMacro and StockPilerMacro.UpdateMacro then
        StockPilerMacro.UpdateMacro()
    end
    if StockPilerMacro and StockPilerMacro.SyncCraftSkillBindings then
        StockPilerMacro.SyncCraftSkillBindings(true)
    end
    if StockPilerMacro and StockPilerMacro.RefreshMacroButtonAppearance then
        StockPilerMacro.RefreshMacroButtonAppearance()
    end
end

function StockPiler.AutoGrow.SetEnabled(enabled)
    local s = StockPiler.EnsureSettings and StockPiler.EnsureSettings() or StockPiler.Settings
    if type(s) ~= "table" then
        return false
    end
    enabled = enabled == true
    if enabled and StockPiler.Inventory and StockPiler.Inventory.CultivatorState
        and StockPiler.Inventory.CultivatorState() == false
    then
        if StockPiler.Print then
            StockPiler.Print(L"AutoGrow is only available to Cultivators.")
        end
        enabled = false
    end
    local changed = s.autoGrowEnabled ~= enabled
    s.autoGrowEnabled = enabled
    if StockPiler.PersistActiveCharacterSettings then
        StockPiler.PersistActiveCharacterSettings(s)
    end
    if changed then
        if StockPiler.LogOp then
            StockPiler.LogOp("settings", "AutoGrow enabled=" .. tostring(enabled))
        end
        StockPiler.AutoGrow.OnEnabledChanged(enabled)
        if StockPiler.NotifyAutoGrowState then
            local queue = nil
            if enabled and StockPiler.Planner and StockPiler.Planner.BuildPlan then
                local plan = StockPiler.Planner.BuildPlan({ refresh = false, reuse = false })
                queue = plan and plan.queue
            end
            StockPiler.NotifyAutoGrowState(enabled, queue)
        end
    end
    if StockPilerTabAutoGrow and StockPilerTabAutoGrow.Refresh then
        StockPilerTabAutoGrow.Refresh()
    end
    if StockPilerMacro then
        if StockPilerMacro.InvalidateHotbarBindings then
            StockPilerMacro.InvalidateHotbarBindings()
        else
            StockPilerMacro._lastCultBindAutoGrow = nil
        end
        if StockPilerMacro.SyncCraftSkillBindings then
            StockPilerMacro.SyncCraftSkillBindings(true)
        end
        if StockPilerMacro.RequestRefreshMacroButtonAppearance then
            StockPilerMacro.RequestRefreshMacroButtonAppearance(true)
        end
    end
    return enabled
end

function StockPiler.AutoGrow.ToggleEnabled()
    local s = StockPiler.EnsureSettings and StockPiler.EnsureSettings() or StockPiler.Settings
    if type(s) ~= "table" then
        return false
    end
    return StockPiler.AutoGrow.SetEnabled(not (s.autoGrowEnabled == true))
end

function StockPiler.AutoGrow.OnEnabledChanged(enabled)
    enabled = enabled == true
    StockPiler.AutoGrow._syncedEnabled = enabled
    StockPiler.AutoGrow._lastTickTrace = nil
    if enabled then
        StockPiler.AutoGrow._queueCursor = 1
        StockPiler.AutoGrow._fillPlotCursor = 1
        StockPiler.AutoGrow._plotCache = {}
        StockPiler.AutoGrow._pendingPlant = {}
        StockPiler.AutoGrow._pendingAdditive = {}
        StockPiler.AutoGrow._pendingRefine = {}
        StockPiler.AutoGrow._additiveCursor = 1
        StockPiler.AutoGrow._seedCommitted = {}
        StockPiler.AutoGrow._seedLastLive = {}
        StockPiler.AutoGrow._autoRefinePending = nil
        StockPiler.AutoGrow._refineDirtyReason = nil
        StockPiler.AutoGrow._lastNotifiedStage = {}
        StockPiler.AutoGrow.InvalidatePlantQueue()
        if StockPiler.Planner and StockPiler.Planner.InvalidatePlanCache then
            StockPiler.Planner.InvalidatePlanCache()
        end
        StockPiler.AutoGrow.SyncAllPlots()
        StockPiler.AutoGrow.MarkAllPlotsWantFill()
        StockPiler.AutoGrow.MarkRefineDue()
        if StockPiler.AutoGrow.ShouldTraceGrow() then
            StockPiler.AutoGrow.DumpGrowPlan({ force = true })
        end
    else
        if StockPiler.Planner and StockPiler.Planner.InvalidatePlanCache then
            StockPiler.Planner.InvalidatePlanCache()
        end
        StockPiler.AutoGrow.Stop()
        StockPiler.AutoGrow.RefreshHarvestButtonFromCache()
    end
end

function StockPiler.AutoGrow.Initialize()
    if StockPiler.AutoGrow._initialized then
        return
    end
    if SystemData and SystemData.Events then
        if SystemData.Events.PLAYER_CULTIVATION_UPDATED then
            RegisterEventHandler(SystemData.Events.PLAYER_CULTIVATION_UPDATED, "StockPiler.AutoGrow.OnCultivationUpdated")
        end
        if SystemData.Events.LOADING_END then
            RegisterEventHandler(SystemData.Events.LOADING_END, "StockPiler.AutoGrow.OnLoadingEnd")
        end
        if SystemData.Events.UPDATE_PROCESSED then
            RegisterEventHandler(SystemData.Events.UPDATE_PROCESSED, "StockPiler.AutoGrow.OnUpdate")
        end
    end
    StockPiler.AutoGrow._initialized = true
    D("AutoGrow Initialize")
    if StockPiler.Inventory and StockPiler.Inventory.EnforceProfessionGates then
        StockPiler.Inventory.EnforceProfessionGates()
    end
    if IsEnabled() then
        StockPiler.AutoGrow.ResumeAfterLoad()
    else
        StockPiler.AutoGrow.Stop()
    end
    StockPiler.AutoGrow.RequestPlotInfoOnce()
    StockPiler.AutoGrow.EnsureHarvestTooltipRows()
end

function StockPiler.AutoGrow.Shutdown()
    if not StockPiler.AutoGrow._initialized then
        return
    end
    if SystemData and SystemData.Events then
        if SystemData.Events.PLAYER_CULTIVATION_UPDATED then
            UnregisterEventHandler(SystemData.Events.PLAYER_CULTIVATION_UPDATED, "StockPiler.AutoGrow.OnCultivationUpdated")
        end
        if SystemData.Events.LOADING_END then
            UnregisterEventHandler(SystemData.Events.LOADING_END, "StockPiler.AutoGrow.OnLoadingEnd")
        end
        if SystemData.Events.UPDATE_PROCESSED then
            UnregisterEventHandler(SystemData.Events.UPDATE_PROCESSED, "StockPiler.AutoGrow.OnUpdate")
        end
    end
    StockPiler.AutoGrow._initialized = false
end