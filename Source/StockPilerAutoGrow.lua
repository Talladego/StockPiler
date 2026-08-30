----------------------------------------------------------------
-- StockPilerAutoGrow - automatic cultivation planting
-- Throttling modeled on GatherButton (1 pending plant/refine per plot,
-- decay once per second via UPDATE_PROCESSED).
----------------------------------------------------------------

StockPiler.AutoGrow = StockPiler.AutoGrow or {}
StockPiler.AutoGrow.TraceEnabled = false

local MAX_PENDING_PLANT = 1
-- GatherButton uses MAX_PENDING_REFINE_REQUESTS = 6 so a single tick can
-- refill the seed buffer without waiting for refine-complete events.
local MAX_PENDING_REFINE = 6
local PLOT_COUNT = 4
local TICK_INTERVAL_SEC = 1
-- Chat-warn when a plant wave spends every remaining seed and that
-- stack is this small (failed harvest can lose the line).
local LAST_SEED_WARN_MAX = 4

StockPiler.AutoGrow._plotCache = {}
StockPiler.AutoGrow._pendingPlant = {}
StockPiler.AutoGrow._pendingAdditive = {}
StockPiler.AutoGrow._pendingRefine = {}
StockPiler.AutoGrow._wantFill = {}
StockPiler.AutoGrow._lastNotifiedStage = {}
StockPiler.AutoGrow._queueCursor = 1
StockPiler.AutoGrow._fillPlotCursor = 1
StockPiler.AutoGrow._additiveCursor = 1
StockPiler.AutoGrow._initialized = false
StockPiler.AutoGrow._autoRefinePending = nil
StockPiler.AutoGrow._harvestCursor = 1
StockPiler.AutoGrow._updateAccum = 0
StockPiler.AutoGrow._syncedEnabled = nil
StockPiler.AutoGrow._plotInfoRequested = false
StockPiler.AutoGrow._cachedPlantQueue = nil
StockPiler.AutoGrow._plantQueueDirty = true
StockPiler.AutoGrow._suppressInvTicks = 0
StockPiler.AutoGrow._pendingHarvestNotify = nil
StockPiler.AutoGrow._lastTickTrace = nil
-- Seeds planted that live bags may not have subtracted yet (inventory suppress).
StockPiler.AutoGrow._seedCommitted = {}
StockPiler.AutoGrow._seedLastLive = {}
StockPiler.AutoGrow._lastSeedExhaustWarn = {}

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

local function NumPlots()
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
    return StockPiler.AutoGrow.TraceEnabled == true
        or StockPiler.DebugEnabled == true
end

function StockPiler.AutoGrow.EmitGrowTrace(msg, force)
    local text = "AutoGrow| " .. tostring(msg)
    if force then
        if StockPiler._EmitLog and StockPiler._LogText then
            StockPiler._EmitLog("StockPiler| " .. StockPiler._LogText(text))
        elseif type(d) == "function" then
            d("StockPiler| " .. text)
        end
        return
    end
    if not StockPiler.AutoGrow.ShouldTraceGrow() then
        return
    end
    if StockPiler.Trace then
        StockPiler.Trace(text)
    else
        D(text)
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
        pcall(StockPiler.Inventory.RefreshAllIfNeeded)
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
        local yield = recipe and tonumber(recipe.recipeYield) or 0
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
            "  %s have=%d need=%d deficit=%d craftsHave=%d craftsShort=%d minWatch=%s role=%s weighted=%.3f growable=%s",
            SpecTraceLabel(row.spec, row.specKey),
            tonumber(row.have) or 0,
            tonumber(row.absolute) or 0,
            tonumber(row.deficit) or 0,
            tonumber(row.craftsHave) or 0,
            tonumber(row.craftsShort) or 0,
            tostring(row.minWatchCraftable),
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

    if type(s.growProducers) == "table" then
        local prodCount = 0
        for _ in pairs(s.growProducers) do
            prodCount = prodCount + 1
        end
        emit("--- grow producers (" .. tostring(prodCount) .. ") ---")
        for plantKey, prod in pairs(s.growProducers) do
            local seeds = type(prod.seedSpecKeys) == "table" and table.concat(prod.seedSpecKeys, ",") or ""
            emit("  " .. tostring(plantKey) .. " seeds=[" .. seeds .. "]")
        end
    end

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

local function FlushWatchUiIfDirty()
    if StockPiler.AutoGrow._watchUiDirty ~= true then
        return
    end
    if not DoesWindowExist("StockPilerWindow") or not WindowGetShowing("StockPilerWindow") then
        return
    end
    StockPiler.AutoGrow._watchUiDirty = false
    if StockPilerTabAutoGrow and StockPilerTabAutoGrow.Refresh then
        pcall(StockPilerTabAutoGrow.Refresh)
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
    StockPiler.AutoGrow._cachedPlantQueue = nil
    StockPiler.AutoGrow._queueSnapGen = nil
    if already ~= true then
        StockPiler.AutoGrow.EmitGrowTrace("queue invalidated", true)
    end
end

-- Watch list, per-potion AutoGrow, or target changed. Rebuild the queue and
-- fill any empty plots if the global switch is already on.
function StockPiler.AutoGrow.OnDemandChanged()
    StockPiler.AutoGrow.InvalidatePlantQueue()
    if StockPiler.Planner and StockPiler.Planner.InvalidatePlanCache then
        pcall(StockPiler.Planner.InvalidatePlanCache)
    end
    if not IsEnabled() then
        return
    end
    StockPiler.AutoGrow._lastTickTrace = nil
    StockPiler.AutoGrow.MarkAllPlotsWantFill()
    -- Seed buffer / target changes must refine immediately, not wait 1s.
    StockPiler.AutoGrow._updateAccum = TICK_INTERVAL_SEC
    pcall(StockPiler.AutoGrow.ProcessTick)
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

local function ReadBagTables()
    local craftBag = nil
    local invBag = nil
    if DataUtils and DataUtils.GetCraftingItems then
        craftBag = DataUtils.GetCraftingItems()
    end
    if DataUtils and DataUtils.GetItems then
        invBag = DataUtils.GetItems()
    end
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
    local ok, err = pcall(WindowSetGameActionData, windowName, action, cult, L"")
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

local function CountSeedsInLiveBags(seedUid)
    seedUid = tonumber(seedUid) or 0
    if seedUid <= 0 then
        return 0
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

function StockPiler.AutoGrow.GetEffectiveSeedCount(seedUid)
    seedUid = tonumber(seedUid) or 0
    if seedUid <= 0 then
        return 0
    end
    local live = CountSeedsInLiveBags(seedUid)
    local committed = tonumber(StockPiler.AutoGrow._seedCommitted[seedUid]) or 0
    local lastLive = StockPiler.AutoGrow._seedLastLive[seedUid]
    if lastLive ~= nil and live < lastLive then
        committed = math.max(0, committed - (lastLive - live))
        StockPiler.AutoGrow._seedCommitted[seedUid] = committed
    end
    StockPiler.AutoGrow._seedLastLive[seedUid] = live
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
        local ok, color = pcall(DataUtils.GetItemRarityColor, itemData)
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
            local ok = pcall(CreateWindowFromTemplate, rowName, "TooltipRow", "DefaultTooltip")
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
            local ok, built = pcall(StockPiler.Planner.BuildPlan, { refresh = false })
            if ok then
                plan = built
            end
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

--- Any refinable plant (not seed/spore). Used when converting for refine byproducts
--- such as Arboreal Resin, which drop from any plant→seed convert.
function StockPiler.AutoGrow.FindAnyRefinablePlantSlot()
    local seedType = (GameData and GameData.CultivationTypes and GameData.CultivationTypes.SEED) or 1
    local sporeType = (GameData and GameData.CultivationTypes and GameData.CultivationTypes.SPORE) or 5

    local function canRefine(item)
        if type(item) ~= "table" then
            return false
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

function StockPiler.AutoGrow.RefinePlantSlot(slot, item, backpackType, entry, uses)
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
        pcall(StockPiler.SeedMap.BeginPendingRefine, item)
    end

    local location = EA_Window_Backpack.GetCursorForBackpack(backpackType or CraftingBackpackType())
    local sent = 0
    for _ = 1, uses do
        local ok, err = pcall(SendUseItem, location, slot, 0, 0, 0)
        if not ok then
            D("AutoGrow refine failed slot=" .. tostring(slot) .. " err=" .. tostring(err))
            break
        end
        sent = sent + 1
    end
    if sent <= 0 then
        return false
    end

    SuppressInventorySideEffects()
    StockPiler.AutoGrow._pendingRefine[plantUid] = pending + sent
    StockPiler.AutoGrow.InvalidatePlantQueue()
    D("AutoGrow refining plantUid=" .. tostring(plantUid)
        .. " slot=" .. tostring(slot) .. " uses=" .. tostring(sent)
        .. " seed=" .. tostring(entry and entry.seedKey or ""))
    RefreshWatchStatusIfOpen()
    return true
end

function StockPiler.AutoGrow.MaybeAutoRefine()
    if not IsEnabled() then
        return false
    end

    local buffer = 4
    if StockPiler.Planner and StockPiler.Planner.GetSeedBufferMin then
        buffer = StockPiler.Planner.GetSeedBufferMin()
    end
    local seen = {}
    local plots = NumPlots()

    -- Grow cycle: convert plants up to the seed buffer (and enough to fill
    -- empty plots). Planting may spend those seeds down to 0. Include
    -- harvest-ready plots so refine can start before you harvest.
    if StockPiler.Planner and StockPiler.Planner.CollectGrowCycleRefineJobs then
        local emptyPlots = 0
        for plotNum = 1, plots do
            if StockPiler.AutoGrow.CanPlantPlot(plotNum) then
                emptyPlots = emptyPlots + 1
            end
        end
        local ready = 0
        if StockPiler.AutoGrow.GetReadyHarvestPlots then
            ready = #(StockPiler.AutoGrow.GetReadyHarvestPlots() or {})
        end
        local soonNeed = emptyPlots + ready
        if soonNeed > plots then
            soonNeed = plots
        end
        local jobs = StockPiler.Planner.CollectGrowCycleRefineJobs(soonNeed)
        if type(jobs) == "table" then
            for i = 1, #jobs do
                local job = jobs[i]
                local plantUid = tonumber(job.plantUid) or 0
                if plantUid > 0 and seen[plantUid] ~= true then
                    seen[plantUid] = true
                    local pending = tonumber(StockPiler.AutoGrow._pendingRefine[plantUid]) or 0
                    if pending > 0 then
                        LogGrow("refine grow-cycle wait plantUid=" .. tostring(plantUid)
                            .. " pending=" .. tostring(pending))
                    else
                        local uses = tonumber(job.uses) or 0
                        local slot, item, bagType = StockPiler.AutoGrow.FindRefinablePlantSlot(plantUid)
                        if uses > 0 and slot > 0 and type(item) == "table" then
                            LogGrow("refine grow-cycle plantUid=" .. tostring(plantUid)
                                .. " seedUid=" .. tostring(job.seedUid or 0)
                                .. " seedHave=" .. tostring(job.seedHave or 0)
                                .. " want=" .. tostring(job.wantSeeds or 0)
                                .. " emptyPlots=" .. tostring(emptyPlots)
                                .. " harvestReady=" .. tostring(ready)
                                .. " soonNeed=" .. tostring(soonNeed)
                                .. " deficit=" .. tostring(job.deficit or 0)
                                .. " uses=" .. tostring(uses))
                            StockPiler.AutoGrow.MarkAllPlotsWantFill()
                            return StockPiler.AutoGrow.RefinePlantSlot(slot, item, bagType, nil, uses)
                        end
                        if uses > 0 then
                            LogGrow("refine grow-cycle skip plantUid=" .. tostring(plantUid)
                                .. " seedUid=" .. tostring(job.seedUid or 0)
                                .. " seedHave=" .. tostring(job.seedHave or 0)
                                .. " want=" .. tostring(job.wantSeeds or 0)
                                .. " reason=no refinable plant in bags")
                        end
                    end
                end
            end
        end
    end

    local queue = StockPiler.AutoGrow.GetPlantQueue()
    for plotNum = 1, plots do
        local entry = queue[plotNum]
        if type(entry) == "table" then
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
                if seedHave < buffer then
                    local pending = tonumber(StockPiler.AutoGrow._pendingRefine[plantUid]) or 0
                    if pending < MAX_PENDING_REFINE then
                        -- Buffer is a refine target. Convert plants in bags even
                        -- when those stacks are also recipe ingredients.
                        local need = buffer - seedHave
                        if need <= 0 then
                            LogGrow("refine skip P" .. tostring(plotNum)
                                .. " plantUid=" .. tostring(plantUid)
                                .. " seedUid=" .. tostring(seedUid)
                                .. " seedHave=" .. tostring(seedHave)
                                .. " target=" .. tostring(buffer)
                                .. " reason=already at buffer")
                        else
                            local slot, item, bagType = StockPiler.AutoGrow.FindRefinablePlantSlot(plantUid)
                            if slot > 0 and type(item) == "table" then
                                LogGrow("refine queue P" .. tostring(plotNum)
                                    .. " plantUid=" .. tostring(plantUid)
                                    .. " seedUid=" .. tostring(seedUid)
                                    .. " seedHave=" .. tostring(seedHave)
                                    .. " buffer=" .. tostring(buffer)
                                    .. " need=" .. tostring(need))
                                return StockPiler.AutoGrow.RefinePlantSlot(slot, item, bagType, entry, need)
                            end
                            LogGrow("refine skip P" .. tostring(plotNum)
                                .. " plantUid=" .. tostring(plantUid)
                                .. " seedUid=" .. tostring(seedUid)
                                .. " seedHave=" .. tostring(seedHave)
                                .. " target=" .. tostring(buffer)
                                .. " reason=no plant in bags")
                        end
                    end
                end
            end
        end
    end

    -- Refill seed buffer from surplus plants even when the plant queue is empty
    -- (Ready to Craft). Never converts stacks still needed for brewing.
    if StockPiler.Planner and StockPiler.Planner.CollectSeedBufferRefills then
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
                                .. " uses=" .. tostring(uses))
                            return StockPiler.AutoGrow.RefinePlantSlot(slot, item, bagType, nil, uses)
                        end
                    end
                end
            end
        end
    end

    -- Convert extras (Arboreal Resin) even when seeds are already at buffer.
    local extraNeed = 0
    if StockPiler.Planner and StockPiler.Planner.RefineByproductCraftsShort then
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
            LogGrow("refine byproduct need=" .. tostring(extraNeed)
                .. " uses=" .. tostring(uses)
                .. " plantUid=" .. tostring(item.uniqueID or 0))
            return StockPiler.AutoGrow.RefinePlantSlot(slot, item, bagType, entry, uses)
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
    StockPiler.AutoGrow.InvalidatePlantQueue()
    if IsEnabled() then
        StockPiler.AutoGrow.MarkAllPlotsWantFill()
        pcall(StockPiler.AutoGrow.ProcessTick)
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
    local snapGen = StockPiler.Inventory and tonumber(StockPiler.Inventory._snapshotGen) or 0
    if StockPiler.AutoGrow._plantQueueDirty ~= true
        and type(StockPiler.AutoGrow._cachedPlantQueue) == "table"
        and tonumber(StockPiler.AutoGrow._queueSnapGen) == snapGen
    then
        return StockPiler.AutoGrow._cachedPlantQueue
    end
    if not (StockPiler.Planner and StockPiler.Planner.BuildPlan) then
        return {}
    end
    StockPiler.AutoGrow._buildingPlantQueue = true
    local ok, plan = pcall(StockPiler.Planner.BuildPlan, { refresh = false })
    StockPiler.AutoGrow._buildingPlantQueue = false
    if not ok then
        LogGrow("queue build failed err=" .. tostring(plan))
        return StockPiler.AutoGrow._cachedPlantQueue or {}
    end
    local queue = (type(plan) == "table" and type(plan.queue) == "table") and plan.queue or {}
    StockPiler.AutoGrow._cachedPlantQueue = queue
    StockPiler.AutoGrow._plantQueueDirty = false
    StockPiler.AutoGrow._queueSnapGen = snapGen
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
    StockPiler.AutoGrow.EmitGrowTrace(
        "queue rebuilt snap=" .. tostring(snapGen)
            .. " assigned=" .. tostring(assigned)
            .. " bufferGrow=" .. tostring(bufferGrow)
            .. " emptyWantFill=" .. tostring(StockPiler.AutoGrow.CountEmptyPlotsWantingFill()),
        true
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
        pcall(UpdateCraftingStatus, cult, 4, plotNum)
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
        pcall(StockPilerTabAutoGrow.RefreshHarvestButton)
    end
    if StockPilerMacro and StockPilerMacro.RefreshMacroButtonAppearance then
        pcall(StockPilerMacro.RefreshMacroButtonAppearance)
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
    StockPiler.AutoGrow.EmitGrowTrace(
        "last-seed warning seedUid=" .. tostring(seedUid)
            .. " have=" .. tostring(have)
            .. " queued=" .. tostring(queued),
        true
    )
    if StockPiler.NotifyAutoGrowLastSeeds then
        pcall(StockPiler.NotifyAutoGrowLastSeeds, seedName, have)
    elseif StockPiler.Print then
        pcall(StockPiler.Print, L"Warning: AutoGrow is planting all remaining seeds ("
            .. towstring(tostring(have)) .. L").")
    end
end

function StockPiler.AutoGrow.NotifyPlanted(plotNum, entry, reason)
    if StockPiler.NotifyAutoGrowPlanted then
        pcall(StockPiler.NotifyAutoGrowPlanted, plotNum, entry, reason)
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
        local skipMsg
        if type(raw) ~= "table" then
            skipMsg = "plant skip plot=" .. tostring(plotNum) .. " reason=no queue entry"
        else
            local liveUid = tonumber(raw.seedUid) or 0
            local liveHave = 0
            local buffer = 4
            if StockPiler.Planner and StockPiler.Planner.GetSeedBufferMin then
                buffer = StockPiler.Planner.GetSeedBufferMin()
            end
            if liveUid > 0 then
                liveHave = StockPiler.AutoGrow.GetEffectiveSeedCount(liveUid)
            end
            skipMsg = "plant skip plot=" .. tostring(plotNum)
                .. " reason=no seeds in bags"
                .. " seedUid=" .. tostring(liveUid)
                .. " liveHave=" .. tostring(liveHave)
                .. " buffer=" .. tostring(buffer)
                .. " queuedHave=" .. tostring(raw.seedHave or 0)
                .. " plantable=" .. tostring(raw.seedPlantable or 0)
                .. " specKey=" .. tostring(raw.specKey or "?")
        end
        if StockPiler.AutoGrow._lastPlantSkip ~= skipMsg then
            StockPiler.AutoGrow._lastPlantSkip = skipMsg
            StockPiler.AutoGrow.EmitGrowTrace(skipMsg, true)
        end
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
    local ok, err = pcall(AddCraftingItem, cult, plotNum, slot, backpackType)
    if not ok then
        D("AutoGrow AddCraftingItem failed plot=" .. tostring(plotNum) .. " err=" .. tostring(err))
        return false
    end

    SuppressInventorySideEffects()
    StockPiler.AutoGrow.MaybeWarnLastSeeds(seedUid, entry and entry.seedName or seedKey, plotNum)
    StockPiler.AutoGrow.NoteSeedPlanted(seedUid)
    if StockPiler.AutoGrow.GetEffectiveSeedCount(seedUid) <= 0 then
        StockPiler.AutoGrow._lastSeedExhaustWarn[seedUid] = nil
    end
    StockPiler.AutoGrow._pendingPlant[plotNum] = (tonumber(StockPiler.AutoGrow._pendingPlant[plotNum]) or 0) + 1
    StockPiler.AutoGrow._wantFill[plotNum] = false
    D("AutoGrow planted plot=" .. tostring(plotNum) .. " seedUid=" .. tostring(seedUid)
        .. " slot=" .. tostring(slot) .. " reason=" .. tostring(reason or ""))
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
                        local ok, err = pcall(AddCraftingItem, cult, plotNum, slot, backpackType)
                        if not ok then
                            D("AutoGrow AddCraftingItem additive failed plot=" .. tostring(plotNum)
                                .. " err=" .. tostring(err))
                            return false
                        end
                        SuppressInventorySideEffects()
                        StockPiler.AutoGrow._pendingAdditive[plotNum] =
                            (tonumber(StockPiler.AutoGrow._pendingAdditive[plotNum]) or 0) + 1
                        StockPiler.AutoGrow._additiveCursor = (plotNum % plots) + 1
                        local info = StockPiler.Additives.Classify(item)
                        local role = info and info.role or "?"
                        LogGrow("additive plot=" .. tostring(plotNum)
                            .. " role=" .. tostring(role)
                            .. " uid=" .. tostring(item.uniqueID)
                            .. " slot=" .. tostring(slot))
                        if StockPiler.NotifyAutoGrowAdditive then
                            pcall(StockPiler.NotifyAutoGrowAdditive, plotNum, item, info)
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
    if not IsEnabled() then
        LogTickOnce("disabled")
        return
    end
    if StockPiler.Brew and StockPiler.Brew.IsBusy and StockPiler.Brew.IsBusy() then
        LogTickOnce("brew busy")
        return
    end
    -- Don't plant/refine while a harvest action is in flight (CurrentPlot race).
    -- Ready-but-unharvested plots must not block filling plots that are already empty.
    if StockPiler.AutoGrow.HasHarvestInProgress() then
        LogTickOnce("harvest in progress")
        return
    end
    -- Snapshot harvest bags once when a plot first becomes ready, not every tick.
    local pendingHarvest = StockPiler.SeedMap and StockPiler.SeedMap._pendingHarvest
    if StockPiler.SeedMap and StockPiler.SeedMap.RefreshHarvestWatch
        and type(pendingHarvest) ~= "table"
    then
        local ready = StockPiler.AutoGrow.GetReadyHarvestPlots()
        for i = 1, #ready do
            local plotNum = ready[i]
            local plotData = StockPiler.AutoGrow._plotCache[plotNum]
            if type(plotData) == "table" then
                pcall(StockPiler.SeedMap.RefreshHarvestWatch, plotNum, plotData)
                break
            end
        end
    end
    if StockPiler.AutoGrow.MaybeAutoRefine() then
        LogTickOnce("started auto-refine")
        return
    end
    -- Current-stage additives first — grow-time cuts make the window short.
    if StockPiler.AutoGrow.TryApplyNextAdditive() then
        LogTickOnce("applied additive")
        return
    end
    if not StockPiler.AutoGrow.HasEmptyPlotWantingFill() then
        local recovered = StockPiler.AutoGrow.RecoverStuckEmptyPlots()
        if recovered > 0 then
            StockPiler.AutoGrow.EmitGrowTrace(
                "recovered wantFill on " .. tostring(recovered) .. " empty plots",
                true
            )
        end
    end
    if not StockPiler.AutoGrow.HasEmptyPlotWantingFill() then
        local ready = StockPiler.AutoGrow.GetReadyHarvestPlots()
        local emptyN = StockPiler.AutoGrow.CountEmptyPlots()
        if #ready > 0 then
            LogTickOnce("harvest ready plots=" .. tostring(#ready))
        elseif emptyN > 0 then
            if StockPiler.AutoGrow._lastTickTrace ~= "empty no wantFill" then
                StockPiler.AutoGrow._lastTickTrace = "empty no wantFill"
                StockPiler.AutoGrow.EmitGrowTrace(
                    "empty plots=" .. tostring(emptyN) .. " none want fill (pending or blocked)",
                    true
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
    else
        if StockPiler.AutoGrow._lastTickTrace ~= "plant no progress" then
            StockPiler.AutoGrow._lastTickTrace = "plant no progress"
            local q = StockPiler.AutoGrow._cachedPlantQueue
            local assigned = 0
            if type(q) == "table" then
                for plotNum = 1, NumPlots() do
                    if type(q[plotNum]) == "table" then
                        assigned = assigned + 1
                    end
                end
            end
            StockPiler.AutoGrow.EmitGrowTrace(
                "plant no progress emptyWantFill="
                    .. tostring(StockPiler.AutoGrow.CountEmptyPlotsWantingFill())
                    .. " queueAssigned=" .. tostring(assigned)
                    .. " brewBusy=" .. tostring(StockPiler.Brew and StockPiler.Brew.IsBusy and StockPiler.Brew.IsBusy()),
                true
            )
            if StockPiler.Planner and StockPiler.Planner.MaybeNotifyProgressBlockers then
                pcall(StockPiler.Planner.MaybeNotifyProgressBlockers)
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
        pcall(StockPiler.Inventory.EnforceProfessionGates)
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
            StockPiler.AutoGrow._harvestUiDirty = true
        end
    end

    if IsPlotGrown(stage)
        and prevStage ~= StageGrown()
        and StockPiler.SeedMap
        and StockPiler.SeedMap.RefreshHarvestWatch
    then
        pcall(StockPiler.SeedMap.RefreshHarvestWatch, plotNum, plotData)
    end

    if stage ~= StageEmpty() then
        StockPiler.AutoGrow._pendingPlant[plotNum] = 0
        StockPiler.AutoGrow._wantFill[plotNum] = false
        if prevStage == nil or prevStage == StageEmpty() then
            StockPiler.AutoGrow.InvalidatePlantQueue()
            if StockPiler.Planner and StockPiler.Planner.InvalidatePlanCache then
                pcall(StockPiler.Planner.InvalidatePlanCache)
            end
        end
        return
    end

    local becameEmpty = prevStage ~= nil and prevStage ~= StageEmpty()
    if becameEmpty then
        StockPiler.AutoGrow.InvalidatePlantQueue()
        if StockPiler.Inventory and StockPiler.Inventory.InvalidateSnapshot then
            pcall(StockPiler.Inventory.InvalidateSnapshot)
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
    local ok, plotData = pcall(GetCultivationInfo, plotNum)
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

function StockPiler.AutoGrow.CanHarvestNow()
    if StockPiler.AutoGrow.HasHarvestInProgress() then
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

--- Macro fury glow: 4 if any plot is ready to harvest, else 1 if any is growing.
function StockPiler.AutoGrow.GetClosestPlotGlowLevel()
    local ready = StockPiler.AutoGrow.GetReadyHarvestPlots and StockPiler.AutoGrow.GetReadyHarvestPlots() or {}
    if #ready > 0 then
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
        pcall(StockPiler.AutoGrow.SyncAllPlots)
    end
    local entries = {}
    local plots = NumPlots()
    local anyGrowing = false
    for plotNum = 1, plots do
        local plotData = CachedPlot(plotNum)
        if type(plotData) ~= "table" and refresh == true and GetCultivationInfo then
            local ok, data = pcall(GetCultivationInfo, plotNum)
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

    local cursor = tonumber(StockPiler.AutoGrow._harvestCursor) or 1
    if cursor < 1 or cursor > #ready then
        cursor = 1
    end
    local plotNum = ready[cursor]
    StockPiler.AutoGrow.UpdatePlot(plotNum)

    if GameData and GameData.Player and GameData.Player.Cultivation then
        GameData.Player.Cultivation.CurrentPlot = plotNum
    end

    local plotData = StockPiler.AutoGrow._plotCache[plotNum]
    if type(plotData) ~= "table" or not IsPlotGrown(plotData.StageNum) then
        return false
    end

    StockPiler.AutoGrow._pendingHarvestNotify = {
        plotNum = plotNum,
        plantName = PlantDisplayName(plotData, plotNum),
        manual = manual == true,
    }
    if StockPiler.SeedMap and StockPiler.SeedMap.BeginPendingHarvest then
        pcall(StockPiler.SeedMap.BeginPendingHarvest, plotNum, plotData)
    end
    return true
end

function StockPiler.AutoGrow.PrepareHarvestPlot(manual)
    StockPiler.AutoGrow.EnsureHarvestActionBound()
    if not StockPiler.AutoGrow.SelectHarvestPlot(manual) then
        return false
    end
    local pending = StockPiler.AutoGrow._pendingHarvestNotify
    D("AutoGrow harvest prepared plot=" .. tostring(pending and pending.plotNum or "?"))
    return true
end

function StockPiler.AutoGrow.ExecuteHarvest(manual)
    if not StockPiler.AutoGrow.PrepareHarvestPlot(manual) then
        return false
    end

    StockPiler.AutoGrow.EnsureHarvestActionBound()

    if WindowGameAction then
        if DoesWindowExist(HARVEST_ACTION_WIN) then
            local ok = pcall(WindowGameAction, HARVEST_ACTION_WIN)
            if ok then
                D("AutoGrow harvest game action plot manual=" .. tostring(manual == true))
                return true
            end
        end
        if DoesWindowExist(CULTIVATION_HARVEST_WIN) then
            BindCultivationHarvestAction(CULTIVATION_HARVEST_WIN)
            local ok = pcall(WindowGameAction, CULTIVATION_HARVEST_WIN)
            if ok then
                D("AutoGrow harvest via CultivationWindowHarvest manual=" .. tostring(manual == true))
                return true
            end
        end
    end

    if PerformCrafting then
        local ok, err = pcall(PerformCrafting, CultivationTradeSkill(), 1)
        if ok then
            D("AutoGrow harvest via PerformCrafting manual=" .. tostring(manual == true))
            return true
        end
        D("AutoGrow PerformCrafting harvest failed err=" .. tostring(err))
    end

    StockPiler.AutoGrow._pendingHarvestNotify = nil
    D("AutoGrow harvest failed: no working harvest API")
    return false
end

function StockPiler.AutoGrow.TryHarvestNextPlot(manual)
    return StockPiler.AutoGrow.ExecuteHarvest(manual)
end

function StockPiler.AutoGrow.OnUpdate(timeElapsed)
    if StockPiler.Brew and StockPiler.Brew.IsBusy and StockPiler.Brew.IsBusy() then
        if StockPiler.Brew.OnUpdate then
            pcall(StockPiler.Brew.OnUpdate, timeElapsed)
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
        pcall(StockPiler.ProcessDeferredInventoryWork)
    end
    if StockPiler.AutoGrow._plotsNeedSync == true then
        StockPiler.AutoGrow._plotsNeedSync = false
        StockPiler.AutoGrow.SyncAllPlots()
    end
    if IsEnabled() then
        StockPiler.AutoGrow.ProcessTick()
    end
    if StockPiler.AutoGrow._harvestUiDirty == true then
        StockPiler.AutoGrow._harvestUiDirty = false
        StockPiler.AutoGrow.RefreshHarvestButtonFromCache()
    end
    FlushWatchUiIfDirty()
end

function StockPiler.AutoGrow.OnCultivationUpdated()
    -- Event = cache write only. Cultivation can fire 8+ times in a burst.
    if GameData and GameData.Player and GameData.Player.Cultivation then
        local plotNum = tonumber(GameData.Player.Cultivation.UpdatedIndex) or 0
        if plotNum > 0 then
            local prev = StockPiler.AutoGrow._plotCache[plotNum]
            local prevStage = prev and NormalizeStage(prev.StageNum) or nil
            StockPiler.AutoGrow.UpdatePlot(plotNum)
            local now = StockPiler.AutoGrow._plotCache[plotNum]
            local nowStage = now and NormalizeStage(now.StageNum) or nil
            if prevStage ~= nowStage then
                StockPiler.AutoGrow._harvestUiDirty = true
            end
            return
        end
    end
    StockPiler.AutoGrow._plotsNeedSync = true
    StockPiler.AutoGrow._harvestUiDirty = true
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

function StockPiler.AutoGrow.OnLoadingEnd()
    if StockPiler.Inventory and StockPiler.Inventory.EnforceProfessionGates then
        pcall(StockPiler.Inventory.EnforceProfessionGates)
    end
    if StockPiler.SeedMap and StockPiler.SeedMap.EnsureSpecBootstrap then
        pcall(StockPiler.SeedMap.EnsureSpecBootstrap)
    end
    if StockPiler.Planner and StockPiler.Planner.InvalidatePlanCache then
        pcall(StockPiler.Planner.InvalidatePlanCache)
    end
    StockPiler.AutoGrow.ResetPlotInfoRequest()
    if IsEnabled() then
        StockPiler.AutoGrow.InvalidatePlantQueue()
        StockPiler.AutoGrow.SyncAllPlots()
        StockPiler.AutoGrow.MarkAllPlotsWantFill()
    end
    StockPiler.AutoGrow.RequestPlotInfoOnce()
    StockPiler.AutoGrow._harvestUiDirty = true
    StockPiler.AutoGrow.RefreshHarvestButtonFromCache()
    if StockPilerMacro and StockPilerMacro.UpdateMacro then
        pcall(StockPilerMacro.UpdateMacro)
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
        pcall(StockPilerTabAutoGrow.Refresh)
    end
    if StockPilerMacro and StockPilerMacro.RefreshMacroButtonAppearance then
        pcall(StockPilerMacro.RefreshMacroButtonAppearance)
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
        StockPiler.AutoGrow._lastNotifiedStage = {}
        StockPiler.AutoGrow.InvalidatePlantQueue()
        if StockPiler.Planner and StockPiler.Planner.InvalidatePlanCache then
            pcall(StockPiler.Planner.InvalidatePlanCache)
        end
        StockPiler.AutoGrow.SyncAllPlots()
        StockPiler.AutoGrow.MarkAllPlotsWantFill()
        if StockPiler.AutoGrow.ShouldTraceGrow() then
            StockPiler.AutoGrow.DumpGrowPlan({ force = true })
        end
        StockPiler.AutoGrow._harvestUiDirty = true
    else
        if StockPiler.Planner and StockPiler.Planner.InvalidatePlanCache then
            pcall(StockPiler.Planner.InvalidatePlanCache)
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
        pcall(StockPiler.Inventory.EnforceProfessionGates)
    end
    if IsEnabled() then
        StockPiler.AutoGrow.InvalidatePlantQueue()
        if StockPiler.Planner and StockPiler.Planner.InvalidatePlanCache then
            pcall(StockPiler.Planner.InvalidatePlanCache)
        end
        StockPiler.AutoGrow.SyncAllPlots()
        StockPiler.AutoGrow.MarkAllPlotsWantFill()
    else
        StockPiler.AutoGrow.Stop()
    end
    StockPiler.AutoGrow.RequestPlotInfoOnce()
    StockPiler.AutoGrow._harvestUiDirty = true
    pcall(StockPiler.AutoGrow.EnsureHarvestTooltipRows)
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