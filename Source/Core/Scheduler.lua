----------------------------------------------------------------
-- StockPiler Core/Scheduler -- coalesce heavy work, frame budgets
-- UPDATE_PROCESSED pump: bag flush -> FrameWork.Pump -> PlanRebuild
-- -> Watch UI (one heavy). Orch tick on interval.
-- Wake vs snap: only wake forces plant-queue invalidate.
----------------------------------------------------------------

StockPiler = StockPiler or {}
StockPiler.Scheduler = StockPiler.Scheduler or {}

local Sch = StockPiler.Scheduler

Sch.BAG_COALESCE_SEC = 2.0
Sch.PLAN_MAX_WAIT_SEC = 0.5
Sch.PLAN_COALESCE_WHEN_AWAKE_SEC = 3.0
Sch.PLAN_MIN_GAP_SEC = 2.0
Sch.PLAN_WARM_HOLD_MAX_SEC = 3.0
Sch.SESSION_SETTLE_SEC = 2.5
-- 75 frames ended settle in ~1.2s at 60fps - AutoGrow planted before LOADING_END.
Sch.SESSION_SETTLE_MIN_FRAMES = 90
-- LOADING_END is often already gone by addon init; never latch AutoGrow forever.
Sch.SESSION_SETTLE_AWAIT_MAX_SEC = 8
Sch.SESSION_SETTLE_AWAIT_MAX_FRAMES = 480
Sch.AUTO_TICK_SEC = 1.0
Sch.AUTO_TICK_IDLE_SEC = 5.0
Sch.HARVEST_STORM_MIN_SEC = 1.5
Sch.POLL_SEC = 0.25
-- Cover plant/refine inventory + CultivationUpdated lag (0.75 left WarmHave
-- miss storms between IssueOne and the next orch tick).
Sch.PLANT_QUIET_BASE_SEC = 1.25
-- Real issue activity may hold Watch/plan, but not across an idle refine wait.
Sch.ISSUE_BURST_MAX_SEC = 4.0

Sch._bagDue = false
Sch._bagAt = 0
Sch._bagNeedQueue = false
Sch._planDue = false
Sch._planAt = 0
Sch._lastPlanBuiltAt = 0
Sch._autoAccum = 0
Sch._autoGrowFast = true
Sch._suppressInvTicks = 0
Sch._pendingBagFlushAfterSuppress = false
Sch._pendingBagNeedQueueAfterSuppress = false
Sch._pendingPlanAfterSuppress = false
Sch._pendingPlanUrgent = false
Sch._pendingPrewarmAfterQuiet = false
Sch._pendingPrewarmReason = nil
Sch._pendingPlanAfterPrewarm = false
Sch._initialized = false
Sch._harvestStormUntil = 0
Sch._plantQuietUntil = 0
Sch._pollAt = 0
Sch._brewLightAt = 0
Sch._skipPlanThisFrame = false
Sch._skipUiThisFrame = false
Sch._skipUiHoldFooter = false
Sch._awaitingSessionLoad = false
Sch._orchDecisionHoldTicks = 0
Sch._heavyWorkFrame = -1
Sch._pendingBufferFlagsRebuild = false
Sch._burstHoldStartedAt = 0
Sch._busTokens = nil

local function Now()
    if type(GetGameTime) == "function" then
        return tonumber(GetGameTime()) or 0
    end
    return 0
end

local function TrackBus(token)
    if token == nil then
        return
    end
    Sch._busTokens = Sch._busTokens or {}
    Sch._busTokens[#Sch._busTokens + 1] = token
end

local function InvalidatePlantQueue(reason)
    local Grow = StockPiler.Grow
    if not Grow then
        return
    end
    if Grow.InvalidatePlantQueue then
        if type(reason) == "table" then
            Grow.InvalidatePlantQueue(reason)
        else
            Grow.InvalidatePlantQueue({ reason = reason })
        end
    elseif Grow.MarkPlantJobDirty then
        Grow.MarkPlantJobDirty(reason)
    end
end

local function LatchPrewarm(reason)
    Sch._pendingPrewarmAfterQuiet = true
    if Sch._pendingPrewarmReason == nil then
        Sch._pendingPrewarmReason = reason
    end
    Sch._pendingPlanAfterPrewarm = true
end

local function IssueBurstActive()
    return Sch.IsAutoGrowIssueBurstActive and Sch.IsAutoGrowIssueBurstActive() == true
end

local function RequestCachePrewarm(reason)
    -- Defer prewarm during plant/refine quiet and the seed-buffer issue burst.
    -- Bag coalesce is 2s; quiet is only 1.25s, so the flush was landing in the
    -- gap and running WarmHave + Demand + a full Watch refresh.
    if (Sch.IsSuppressed and Sch.IsSuppressed() == true) or IssueBurstActive() then
        LatchPrewarm(reason)
        return
    end
    local FW = StockPiler.FrameWork
    if not FW or not FW.StartOnce then
        return
    end
    local snapGen = 0
    if StockPiler.Inventory and StockPiler.Inventory.GetSnapGen then
        snapGen = tonumber(StockPiler.Inventory.GetSnapGen()) or 0
    end
    local genKey = tostring(snapGen)
    if FW.EnqueueWarmHave then
        FW.EnqueueWarmHave(genKey)
    end
    if FW.EnqueueDemand then
        FW.EnqueueDemand(genKey)
    end
end

local function FlushPendingPrewarmAfterQuiet()
    if Sch._pendingPrewarmAfterQuiet ~= true then
        return
    end
    if Sch.IsSuppressed and Sch.IsSuppressed() == true then
        return
    end
    Sch._pendingPrewarmAfterQuiet = false
    local reason = Sch._pendingPrewarmReason or "quiet-end"
    Sch._pendingPrewarmReason = nil
    local Planner = StockPiler.Planner
    if Planner and Planner.InvalidateHaveCacheAfterQuiet then
        Planner.InvalidateHaveCacheAfterQuiet()
    end
    RequestCachePrewarm(reason)
    -- Rebuild after prewarm finishes - never same frame as quiet-end flush.
    Sch._pendingPlanAfterPrewarm = true
end

--- True only for a recent plant-quiet arm or an outstanding refine.
--- Idle wait ticks, a dirty flag, and a cached buffer pending bit are not a
--- burst: those stay set while nothing is issuing and were freezing Watch.
--- The hold also caps so a lingering outstanding or a repeated arm cannot
--- freeze the plan for the whole session. now<=0 does not hold forever.
local function AutoGrowIssueBurstActive(now)
    now = tonumber(now) or Now()
    if now <= 0 then
        return false
    end
    local cap = tonumber(Sch.ISSUE_BURST_MAX_SEC) or 4.0
    if cap < 0 then
        cap = 0
    end
    local lastArm = tonumber(Sch._lastPlantQuietArmAt) or 0
    local recentArm = lastArm > 0 and (now - lastArm) < cap
    local RP = StockPiler.RefinePipeline
    local outstanding = RP and RP.HasOutstanding and RP.HasOutstanding() == true
    if recentArm ~= true and outstanding ~= true then
        Sch._burstHoldStartedAt = 0
        return false
    end
    local started = tonumber(Sch._burstHoldStartedAt) or 0
    if started <= 0 or started > now then
        Sch._burstHoldStartedAt = now
        started = now
    end
    if (now - started) >= cap then
        return false
    end
    return true
end

function Sch.IsAutoGrowIssueBurstActive(now)
    return AutoGrowIssueBurstActive(now) == true
end

local function HoldPrewarmForIssueBurst(reason)
    LatchPrewarm(reason)
end

--- After quiet/storm prewarm: enqueue one coalesced rebuild when FrameWork is idle.
local function FlushPendingPlanAfterPrewarm()
    if Sch._pendingPlanAfterPrewarm ~= true then
        return false
    end
    if Sch.SkipPlanThisFrameActive and Sch.SkipPlanThisFrameActive() == true then
        return false
    end
    if Sch.IsSuppressed and Sch.IsSuppressed() == true then
        return false
    end
    if IssueBurstActive() then
        return false
    end
    local FW = StockPiler.FrameWork
    if FW and FW.IsPrewarmBusy and FW.IsPrewarmBusy() == true then
        return false
    end
    if FW and FW.Busy and FW.Busy() == true then
        return false
    end
    Sch._pendingPlanAfterPrewarm = false
    if Sch.EnqueuePlanRebuild then
        Sch.EnqueuePlanRebuild({ nudge = true })
    end
    Sch.MarkWatchUiDirty()
    return true
end

local function DecaySuppressInventorySideEffects()
    local n = tonumber(Sch._suppressInvTicks) or 0
    if n <= 0 then
        return
    end
    Sch._suppressInvTicks = n - 1
    if Sch._suppressInvTicks > 0 then
        return
    end
    Sch._suppressInvTicks = 0
    if StockPiler.Inventory and StockPiler.Inventory.FlushPendingSnapGen then
        StockPiler.Inventory.FlushPendingSnapGen()
    end
    local needBag = Sch._pendingBagFlushAfterSuppress == true
    local needQueue = Sch._pendingBagNeedQueueAfterSuppress == true
    local needPlan = Sch._pendingPlanAfterSuppress == true
    Sch._pendingBagFlushAfterSuppress = false
    Sch._pendingBagNeedQueueAfterSuppress = false
    Sch._pendingPlanAfterSuppress = false
    if needBag then
        Sch.EnqueueBagFlush(needQueue)
    elseif needQueue then
        Sch._bagNeedQueue = true
    end
    if needPlan then
        local urgent = Sch._pendingPlanUrgent == true
        Sch._pendingPlanUrgent = false
        Sch.EnqueuePlanRebuild(urgent and { urgent = true } or nil)
    else
        Sch._pendingPlanUrgent = false
    end
end

--- Idle one-heavy: rebuild BufferFlags after invalidate (never on Orch plant frame).
local function FlushPendingBufferFlagsRebuild(didHeavy)
    if Sch._pendingBufferFlagsRebuild ~= true then
        return false
    end
    if didHeavy == true then
        return false
    end
    if Sch.SkipPlanThisFrameActive and Sch.SkipPlanThisFrameActive() == true then
        return false
    end
    if Sch.IsSuppressed and Sch.IsSuppressed() == true then
        return false
    end
    local Refine = StockPiler.Refine
    if not (Refine and Refine.EnsureBufferFlagsNow) then
        Sch._pendingBufferFlagsRebuild = false
        return false
    end
    Sch._pendingBufferFlagsRebuild = false
    Refine.EnsureBufferFlagsNow()
    return true
end

local function FlushBagIfDue()
    if Sch._bagDue ~= true then
        return false
    end
    if Sch.IsSuppressed and Sch.IsSuppressed() == true then
        Sch._bagAt = Now() + Sch.BAG_COALESCE_SEC
        return false
    end
    -- Brew load AddItem storms enqueue flushes; do not Inv.Flush on the same
    -- Update as AdvanceLoadJob (libperf Brew.LoadJob + BagFlush pileup).
    -- Keep _bagDue; do not extend _bagAt so flush runs on the first eligible
    -- Update after the job clears. Load uses live BagAdapter.
    local Brew = StockPiler.Brew
    if Brew and Brew.IsLoadJobActive and Brew.IsLoadJobActive() then
        return false
    end
    if Now() < (tonumber(Sch._bagAt) or 0) then
        return false
    end
    Sch._bagDue = false
    local needQueue = Sch._bagNeedQueue == true
    local planUrgent = Sch._pendingPlanUrgent == true
    Sch._bagNeedQueue = false
    Sch._pendingPlanUrgent = false
    local Inv = StockPiler.Inventory
    if Inv and Inv.Flush then
        if StockPiler.Perf and StockPiler.Perf.Begin then
            StockPiler.Perf.Begin("BagFlush")
        end
        Inv.Flush({ forceEngine = false })
        if StockPiler.Perf and StockPiler.Perf.End then
            StockPiler.Perf.End("BagFlush")
        end
    end
    if needQueue or planUrgent then
        Sch.EnqueuePlanRebuild(planUrgent and { urgent = true } or nil)
    end
    RequestCachePrewarm("bag-flush")
    return true
end

local function RebuildPlanIfDue()
    if Sch._planDue ~= true then
        return false
    end
    if Sch._skipPlanThisFrame == true then
        return false
    end
    if Sch.IsSuppressed and Sch.IsSuppressed() == true then
        return false
    end
    -- Seed-buffer phase keeps issuing after quiet expires. A plan every 2s
    -- was CheapRebuild + Status.Craftable on that same beat.
    if IssueBurstActive() then
        return false
    end
    -- Orch probe remounts have; wait for hold to drop before CheapRebuild.
    if Sch.IsOrchDecisionHold and Sch.IsOrchDecisionHold() == true then
        return false
    end
    local Orch = StockPiler.Orchestrator
    if Orch and Orch.IsBrewSessionActive and Orch.IsBrewSessionActive() == true then
        return false
    end
    -- Outstanding refine holds the plan only inside the capped issue burst.
    -- A second uncapped HasOutstanding check kept the plan frozen after the cap.
    if Now() < (tonumber(Sch._planAt) or 0) then
        return false
    end
    local Planner = StockPiler.Planner
    local FW = StockPiler.FrameWork
    -- A non-prewarm FrameWork job still waits. Prewarm uses the hold cap below.
    local fwBusyOther = FW and FW.Busy and FW.Busy() == true
        and not (FW.IsPrewarmBusy and FW.IsPrewarmBusy() == true)
    if fwBusyOther then
        return false
    end
    -- Hold rebuild until WarmHave finishes - including Cheap/Garden paths.
    -- Snap bumps InvalidateHaveWarm; without this wait CheapRebuild sync-warms
    -- under a remounted cache and stamps stale craftable after the first move.
    -- Start the hold clock before treating prewarm-busy as a reason to wait.
    -- Both busy returns used to sit above this clock, so a stuck prewarm held
    -- rebuilds forever (CORE-1).
    local warm = Planner and Planner.IsHaveCacheWarmForSnap
        and Planner.IsHaveCacheWarmForSnap() == true
    local prewarmBusy = FW and FW.IsPrewarmBusy and FW.IsPrewarmBusy() == true
    if not warm or prewarmBusy then
        if not warm then
            RequestCachePrewarm("plan-hold-warm")
            prewarmBusy = FW and FW.IsPrewarmBusy and FW.IsPrewarmBusy() == true
        end
        local holdMax = tonumber(Sch.PLAN_WARM_HOLD_MAX_SEC) or 3.0
        local holdStart = tonumber(Sch._planWarmHoldAt) or 0
        if holdStart <= 0 then
            Sch._planWarmHoldAt = Now()
            holdStart = Sch._planWarmHoldAt
        end
        if (Now() - holdStart) < holdMax then
            return false
        end
        -- Hold expired still cold or still busy: re-enqueue and extend, then
        -- fall through so the cap overrides a stuck prewarm.
        local retries = tonumber(Sch._planWarmHoldRetries) or 0
        local maxRetries = 2
        if retries < maxRetries then
            Sch._planWarmHoldRetries = retries + 1
            Sch._planWarmHoldAt = Now()
            RequestCachePrewarm("plan-hold-warm-retry")
            return false
        end
        -- Cap fired: cold-build may run while a prewarm slice is still mid-flight (#35 L8).
        if StockPiler.Debug and StockPiler.Debug.LogAlways then
            StockPiler.Debug.LogAlways(string.format(
                "plan-warm-hold-cap warm=%s prewarmBusy=%s retries=%s",
                tostring(warm),
                tostring(prewarmBusy),
                tostring(retries)
            ))
        end
    end
    Sch._planWarmHoldAt = 0
    Sch._planWarmHoldRetries = 0
    Sch._planDue = false
    Sch._planAt = 0
    Sch._lastPlanBuiltAt = Now()
    if Planner and Planner.GetOrBuild then
        if StockPiler.Perf and StockPiler.Perf.Begin then
            StockPiler.Perf.Begin("PlanRebuild")
        end
        Planner.GetOrBuild(true)
        if StockPiler.Perf and StockPiler.Perf.End then
            StockPiler.Perf.End("PlanRebuild")
        end
        -- Never paint Watch on the same frame as a full Build (WarmHave hitch).
        Sch.SkipUiThisFrame()
        Sch.MarkWatchUiDirty()
        return true
    end
    return false
end

local function MainWindowOpen()
    return type(DoesWindowExist) == "function"
        and DoesWindowExist("StockPilerWindow") == true
        and type(WindowGetShowing) == "function"
        and WindowGetShowing("StockPilerWindow") == true
end

local function FlushWatchUiIfDue(didHeavy)
    if didHeavy == true then
        return false
    end
    if Sch._skipUiThisFrame == true then
        return false
    end
    -- No Watch flush during harvest storm / plant quiet / seed-buffer burst.
    if Sch.IsSuppressed and Sch.IsSuppressed() == true then
        return false
    end
    if IssueBurstActive() then
        return false
    end
    local openPaint = StockPilerWindow and StockPilerWindow._openPaintPending == true
    local Ui = StockPiler.Ui
    -- Skill-up paint is only useful while Watch is open and already dirty.
    local missingSkillUp = false
    if openPaint ~= true and MainWindowOpen() and Ui and Ui._watchUiDirty == true
        and Ui.WatchNeedsSkillUpPaint
    then
        missingSkillUp = Ui.WatchNeedsSkillUpPaint() == true
    end
    if not openPaint and missingSkillUp ~= true then
        if Sch.IsSessionSettling and Sch.IsSessionSettling() == true then
            return false
        end
        local FW = StockPiler.FrameWork
        if FW and FW.IsPrewarmBusy and FW.IsPrewarmBusy() == true then
            return false
        end
        if FW and FW.Busy and FW.Busy() == true then
            return false
        end
    end
    if Ui and Ui.FlushWatchUiIfDirty then
        return Ui.FlushWatchUiIfDirty() == true
    end
    return false
end

Sch.FlushWatchUiIfDue = FlushWatchUiIfDue

local function AutoTickIntervalSec()
    -- Every branch returns the fast interval while this flag is set.
    if Sch._autoGrowFast == true then
        return Sch.AUTO_TICK_SEC
    end
    if StockPiler.Buy and StockPiler.Buy.NeedsTick and StockPiler.Buy.NeedsTick() == true then
        return Sch.AUTO_TICK_SEC
    end
    local Watch = StockPiler.Watch
    if Watch and Watch.IsAutoGrowEnabled and Watch.IsAutoGrowEnabled() == true then
        -- Fast ticks already returned above. AutoGrow otherwise uses the idle interval.
        return Sch.AUTO_TICK_IDLE_SEC
    end
    return Sch.AUTO_TICK_SEC
end

Sch.AutoTickIntervalSec = AutoTickIntervalSec

function Sch.CurrentAutoTickSec()
    return AutoTickIntervalSec()
end

local function ShouldWakeAutoGrowUrgent()
    local Orch = StockPiler.Orchestrator
    if Orch and Orch.HasAutoGrowWork then
        return Orch.HasAutoGrowWork({
            refineDirty = true,
            peek = "cached",
        }) == true
    end
    return false
end

local function OnInventorySnapshot()
    -- Every bag snap must re-warm Have before craftable recount. Remount-under-hold
    -- used to leave IsHaveCacheWarm true with stale mat totals after the first move.
    local Planner = StockPiler.Planner
    if Planner and Planner.InvalidateHaveWarm then
        Planner.InvalidateHaveWarm()
    end
    -- Snap path: avoid full WakeAutoGrow (snap-wake storm risk), but clear a
    -- soft fill-block when empty plots are waiting for bag seeds after refine.
    if StockPiler.Buy and StockPiler.Buy.OnInventorySnapshot then
        StockPiler.Buy.OnInventorySnapshot()
    end
    local Refine = StockPiler.Refine
    -- Peek cached pending before invalidate so wake does not rebuild BufferFlags.
    local pendingBuffer = Refine and Refine.PeekCachedBufferPending
        and Refine.PeekCachedBufferPending() == true
    local suppressed = Sch.IsSuppressed and Sch.IsSuppressed() == true
    local Orch = StockPiler.Orchestrator
    local brewSession = Orch and Orch.IsBrewSessionActive and Orch.IsBrewSessionActive() == true
    if not suppressed and not brewSession then
        local Watch = StockPiler.Watch
        local autoGrowOn = Watch and Watch.IsAutoGrowEnabled and Watch.IsAutoGrowEnabled() == true
        local Grow = StockPiler.Grow
        local hasPlantWork = false
        if autoGrowOn and Grow then
            if Grow.HasEmptyPlot and Grow.HasEmptyPlot() == true then
                hasPlantWork = true
            elseif Grow.NeedsCurrentStageAdditive and Grow.NeedsCurrentStageAdditive() == true then
                hasPlantWork = true
            elseif pendingBuffer then
                hasPlantWork = true
            end
        end
        -- Soft dirty only; do not force plant-queue invalidate on snap.
        if hasPlantWork and Grow and Grow.MarkPlantJobDirty then
            Grow.MarkPlantJobDirty("snap")
        end
        if hasPlantWork and Orch and Orch.IsFillBlocked and Orch.IsFillBlocked() == true
            and Orch.ClearFillBlocked
        then
            Orch.ClearFillBlocked()
        end
        if hasPlantWork or ShouldWakeAutoGrowUrgent() then
            Sch._autoGrowFast = true
        end
    end
    -- Do not InvalidateBufferFlags on every snap: BufferFlagsCacheKey includes snapGen,
    -- so the next real read rebuilds on key mismatch. PeekFreshBufferPending treats
    -- stale/nil as unknown (orch falls through to full check).
    -- Craft-bag / inventory spends must recount Watch craftable (paint-only leaves
    -- stale greens after manual apo / buy / harvest). Coalesce via RebuildPlanIfDue;
    -- never WarmHave or PatchWatch inside this handler.
    local RP = StockPiler.RefinePipeline
    local refineBusy = RP and RP.HasOutstanding and RP.HasOutstanding() == true
    local burst = IssueBurstActive()
    if not suppressed and not brewSession and not refineBusy and not burst then
        Sch.EnqueuePlanRebuild({ nudge = true })
    elseif suppressed or burst then
        -- Bag moves during quiet/storm: latch rebuild after quiet-end invalidate.
        -- Without this, remounted WarmHave stamps stale craftable and Watch only
        -- catches up on a later stack move.
        Sch._pendingPrewarmAfterQuiet = true
        if Sch._pendingPrewarmReason == nil then
            Sch._pendingPrewarmReason = "snap-during-quiet"
        end
        Sch._pendingPlanAfterPrewarm = true
    end
    Sch.MarkWatchUiDirty()
end

local function OnGardenDirty(payload)
    -- Soft (stage-only) pulses: refresh Watch UI, do not wake AutoGrow / plan rebuild.
    if type(payload) == "table" and payload.soft == true then
        Sch.MarkWatchUiDirty()
        return
    end
    -- Harvest storm / plant quiet / refine outstanding: never WakeAutoGrow /
    -- EnqueuePlanRebuild from garden dirty (SP2 Flatten on plant/refine).
    if Sch.IsSuppressed and Sch.IsSuppressed() == true then
        Sch.MarkWatchUiDirty()
        return
    end
    local RP = StockPiler.RefinePipeline
    if RP and RP.HasOutstanding and RP.HasOutstanding() == true then
        Sch.MarkWatchUiDirty()
        return
    end
    if Sch.IsSessionSettling and Sch.IsSessionSettling() == true then
        Sch.MarkWatchUiDirty()
        return
    end
    if Sch.ShouldWakeAutoGrow and Sch.ShouldWakeAutoGrow() == true then
        if Sch._planDue == true then
            Sch._autoGrowFast = true
            return
        end
        Sch.WakeAutoGrow()
        Sch.EnqueuePlanRebuild()
    else
        Sch.MarkWatchUiDirty()
    end
end

local function OnPlanUpdated()
    if StockPiler.Buy and StockPiler.Buy.OnPlanUpdated then
        StockPiler.Buy.OnPlanUpdated()
    end
end

local function OnSessionLoaded()
    Sch._awaitingSessionLoad = false
    if Sch.BeginSessionSettle then
        Sch.BeginSessionSettle()
    end
    Sch.SkipUiThisFrame()
    Sch.EnqueueBagFlush(true)
    -- Drop any plant job picked on empty bags before LOADING_END.
    InvalidatePlantQueue("session-loaded")
    -- Soft Invalidate on mid-session LOADING_END (zone/scenario). Hard Clear only when
    -- character identity changes (or first plan with no prior key) - never serve another
    -- character's stale plan via GetOrBuild(false).
    local charKey = ""
    if StockPiler.Persistence and StockPiler.Persistence.GetCharacterKey then
        charKey = tostring(StockPiler.Persistence.GetCharacterKey() or "")
    elseif StockPiler.Watch and StockPiler.Watch.GetCharacterKey then
        charKey = tostring(StockPiler.Watch.GetCharacterKey() or "")
    end
    local prevKey = tostring(Sch._planSessionCharKey or "")
    local charChanged = charKey ~= "" and prevKey ~= "" and charKey ~= prevKey
    local PS = StockPiler.PlanSnapshot
    local firstPlan = PS == nil or PS.Get == nil or type(PS.Get()) ~= "table"
    if PS then
        if charChanged or (firstPlan and prevKey == "") then
            if PS.Clear then
                PS.Clear()
            elseif PS.Invalidate then
                PS.Invalidate()
            end
        elseif PS.Invalidate then
            PS.Invalidate()
        elseif PS.Clear then
            PS.Clear()
        end
    end
    if charKey ~= "" then
        Sch._planSessionCharKey = charKey
    end
    Sch.EnqueuePlanRebuild()
    Sch.MarkWatchUiDirty()
end

function Sch.IsInventorySideEffectsSuppressed()
    return (tonumber(Sch._suppressInvTicks) or 0) > 0
end

function Sch.SuppressInventorySideEffects(ticks)
    ticks = tonumber(ticks) or 2
    if ticks < 1 then
        ticks = 1
    end
    local cur = tonumber(Sch._suppressInvTicks) or 0
    if ticks > cur then
        Sch._suppressInvTicks = ticks
    end
end

--- Orch plant/refine probe: remount have/demand instead of WarmHave.miss bag walk.
function Sch.ArmOrchDecisionHold(ticks)
    ticks = tonumber(ticks) or 2
    if ticks < 1 then
        ticks = 1
    end
    local cur = tonumber(Sch._orchDecisionHoldTicks) or 0
    if ticks > cur then
        Sch._orchDecisionHoldTicks = ticks
        -- Remember the bag generation this hold started on. A later extend
        -- keeps that generation so a snap move during the hold is still visible
        -- when the hold ends.
        if cur <= 0 then
            local snap = 0
            if StockPiler.Inventory and StockPiler.Inventory.GetSnapGen then
                snap = tonumber(StockPiler.Inventory.GetSnapGen()) or 0
            end
            Sch._orchHoldSnapGen = snap
        end
    end
end

function Sch.IsOrchDecisionHold()
    return (tonumber(Sch._orchDecisionHoldTicks) or 0) > 0
end

local function DecayOrchDecisionHold()
    local n = tonumber(Sch._orchDecisionHoldTicks) or 0
    if n > 0 then
        Sch._orchDecisionHoldTicks = n - 1
        if (tonumber(Sch._orchDecisionHoldTicks) or 0) <= 0 then
            -- Bust Have only when the bag moved during the hold, or a probe
            -- actually served the previous counts. An unchanged snap must not
            -- schedule the quiet-end prewarm; that flag sticks until a harvest
            -- storm ends.
            local snap = 0
            if StockPiler.Inventory and StockPiler.Inventory.GetSnapGen then
                snap = tonumber(StockPiler.Inventory.GetSnapGen()) or 0
            end
            local armed = Sch._orchHoldSnapGen
            Sch._orchHoldSnapGen = nil
            local moved = armed ~= nil and snap ~= armed
            local Planner = StockPiler.Planner
            local substituted = false
            if Planner and Planner.ConsumedHeldCounts then
                substituted = Planner.ConsumedHeldCounts() == true
            end
            if moved or substituted then
                if Planner and Planner.InvalidateHaveWarm then
                    Planner.InvalidateHaveWarm()
                end
                local suppressed = Sch.IsSuppressed and Sch.IsSuppressed() == true
                if suppressed ~= true then
                    RequestCachePrewarm("orch-hold-end")
                end
                Sch._pendingPlanAfterPrewarm = true
            end
        end
    end
end

--- Mark BagFlush / PlanRebuild so WarmHave bag phase can defer same frame.
function Sch.NoteHeavyWork()
    Sch._heavyWorkFrame = tonumber(StockPiler.FrameCounter) or 0
end

function Sch.ShouldDeferWarmHaveBag()
    local frame = tonumber(StockPiler.FrameCounter) or 0
    if frame > 0 and frame == (tonumber(Sch._heavyWorkFrame) or -1) then
        return true
    end
    return false
end

function Sch.RequestBufferFlagsRebuild()
    Sch._pendingBufferFlagsRebuild = true
end

--- Expose prewarm enqueue for PickPlantCandidate cold-cache path.
function Sch.RequestCachePrewarm(reason)
    return RequestCachePrewarm(reason)
end

local function WindowActive(untilT, now)
    untilT = tonumber(untilT) or 0
    now = tonumber(now) or 0
    return untilT > 0 and now > 0 and now < untilT
end

local function ExpireHarvestStorm(now)
    local untilT = tonumber(Sch._harvestStormUntil) or 0
    if untilT <= 0 or WindowActive(untilT, now) then
        return
    end
    if now >= untilT then
        Sch._harvestStormUntil = 0
        -- Storm end: skip plan+UI this frame; enqueue coalesced rebuild for later.
        -- Do not InvalidatePlantQueue / prewarm here (that piled WarmHave + Build
        -- + Watch flush into the first post-harvest / replant hitch).
        Sch.SkipPlanThisFrame()
        Sch.SkipUiThisFrame()
        if Sch.EnqueuePlanRebuild then
            Sch.EnqueuePlanRebuild({ nudge = true })
        end
        Sch.MarkWatchUiDirty()
        if AutoGrowIssueBurstActive(now) then
            HoldPrewarmForIssueBurst("storm-end-burst")
            return
        end
        FlushPendingPrewarmAfterQuiet()
    end
end

local function ExpirePlantQuiet(now)
    local untilT = tonumber(Sch._plantQuietUntil) or 0
    if untilT <= 0 or WindowActive(untilT, now) then
        return
    end
    if now >= untilT then
        Sch._plantQuietUntil = 0
        -- Quiet must clear so Orch can IssueOne. Do not WarmHave between issues.
        Sch.SkipPlanThisFrame()
        Sch.SkipUiThisFrame()
        if AutoGrowIssueBurstActive(now) then
            HoldPrewarmForIssueBurst("quiet-end-burst")
            Sch.MarkWatchUiDirty()
            return
        end
        local Planner = StockPiler.Planner
        if Planner and Planner.InvalidateHaveCacheAfterQuiet then
            Planner.InvalidateHaveCacheAfterQuiet()
        end
        FlushPendingPrewarmAfterQuiet()
        Sch._pendingPlanAfterPrewarm = true
        Sch.MarkWatchUiDirty()
    end
end

--- Expire storm and quiet once per frame. The queries below only read.
function Sch.Advance(now)
    now = tonumber(now) or Now()
    ExpireHarvestStorm(now)
    ExpirePlantQuiet(now)
end

function Sch.ArmHarvestStorm(seconds)
    seconds = tonumber(seconds) or Sch.HARVEST_STORM_MIN_SEC or 1.5
    local minSec = tonumber(Sch.HARVEST_STORM_MIN_SEC) or 1.5
    if seconds < minSec then
        seconds = minSec
    end
    local untilT = Now() + seconds
    local cur = tonumber(Sch._harvestStormUntil) or 0
    if untilT > cur then
        Sch._harvestStormUntil = untilT
    end
    -- Plant quiet >= storm floor.
    local quietSec = math.max(seconds, minSec)
    local quietUntil = Now() + quietSec
    local curQuiet = tonumber(Sch._plantQuietUntil) or 0
    if quietUntil > curQuiet then
        Sch._plantQuietUntil = quietUntil
    end
    Sch._lastPlantQuietArmAt = Now()
end

function Sch.IsHarvestStorm()
    return (tonumber(Sch._harvestStormUntil) or 0) > 0
end

function Sch.IsPlantQuiet()
    return (tonumber(Sch._plantQuietUntil) or 0) > 0
end

function Sch.IsSuppressed()
    return Sch.IsHarvestStorm() == true or Sch.IsPlantQuiet() == true
end

function Sch.ArmPlantQuiet(seconds)
    seconds = tonumber(seconds) or Sch.PLANT_QUIET_BASE_SEC
    local minSec = tonumber(Sch.HARVEST_STORM_MIN_SEC) or 1.5
    if Sch.IsHarvestStorm and Sch.IsHarvestStorm() == true and seconds < minSec then
        seconds = minSec
    end
    local untilT = Now() + seconds
    local cur = tonumber(Sch._plantQuietUntil) or 0
    if untilT > cur then
        Sch._plantQuietUntil = untilT
    end
    Sch._lastPlantQuietArmAt = Now()
end

function Sch.SkipPlanThisFrame()
    Sch._skipPlanThisFrame = true
end

function Sch.SkipUiThisFrame()
    Sch._skipUiThisFrame = true
    Sch._skipUiHoldFooter = true
end

function Sch.SkipPlanThisFrameActive()
    return Sch._skipPlanThisFrame == true
end

function Sch.SkipUiThisFrameActive()
    return Sch._skipUiThisFrame == true
end

--- Hold Watch paint / AutoGrow plant after reload until LOADING_END, then a
--- short window so the first real bag flatten can land.
function Sch.BeginSessionSettle(seconds)
    seconds = tonumber(seconds) or Sch.SESSION_SETTLE_SEC or 2.5
    local untilT = Now() + seconds
    local cur = tonumber(Sch._sessionSettleUntil) or 0
    if untilT > cur then
        Sch._sessionSettleUntil = untilT
    end
    -- Frame-based fallback: GetGameTime can be 0 during early reload.
    local fc = tonumber(StockPiler.FrameCounter) or 0
    local minFrames = tonumber(Sch.SESSION_SETTLE_MIN_FRAMES) or 90
    local frames = math.max(minFrames, math.floor(seconds * 60))
    local untilFrame = fc + frames
    local curFrame = tonumber(Sch._sessionSettleUntilFrame) or 0
    if untilFrame > curFrame then
        Sch._sessionSettleUntilFrame = untilFrame
    end
    Sch._sessionSettleArmed = true
end

--- After reload settle: force Watch SkillUp rows even if the window was already open.
local function MaybeFinishSessionSettle()
    if Sch._sessionSettleArmed ~= true then
        return
    end
    if Sch.IsSessionSettling and Sch.IsSessionSettling() == true then
        return
    end
    Sch._sessionSettleArmed = false
    local Bus = StockPiler.EventBus
    local E = StockPiler.Events
    if Bus and E and E.SESSION_SETTLED then
        Bus.Fire(E.SESSION_SETTLED, { reason = "session-settle" })
    end
    Sch.EnqueuePlanRebuild({ urgent = true })
end

function Sch.MarkAwaitingSessionLoad()
    Sch._awaitingSessionLoad = true
    Sch._awaitingSessionLoadFrame = tonumber(StockPiler.FrameCounter) or 0
    Sch._awaitingSessionLoadAt = Now()
    Sch.BeginSessionSettle()
end

function Sch.IsSessionSettling()
    -- Hold AutoGrow until LOADING_END, but expire if that event never arrives
    -- (common on /reload: LOADING_END fires before EngineEventBridge.Register).
    if Sch._awaitingSessionLoad == true then
        local fc = tonumber(StockPiler.FrameCounter) or 0
        local now = Now()
        local startF = tonumber(Sch._awaitingSessionLoadFrame) or 0
        local startT = tonumber(Sch._awaitingSessionLoadAt) or 0
        local maxF = tonumber(Sch.SESSION_SETTLE_AWAIT_MAX_FRAMES) or 480
        local maxT = tonumber(Sch.SESSION_SETTLE_AWAIT_MAX_SEC) or 8
        local withinFrames = fc < (startF + maxF)
        local withinTime = now <= 0 or startT <= 0 or now < (startT + maxT)
        if withinFrames and withinTime then
            return true
        end
        Sch._awaitingSessionLoad = false
    end
    local fc = tonumber(StockPiler.FrameCounter) or 0
    local untilFrame = tonumber(Sch._sessionSettleUntilFrame) or 0
    if untilFrame > 0 and fc < untilFrame then
        return true
    end
    if untilFrame > 0 and fc >= untilFrame then
        Sch._sessionSettleUntilFrame = 0
    end
    local untilT = tonumber(Sch._sessionSettleUntil) or 0
    if untilT <= 0 then
        return false
    end
    local now = Now()
    -- now==0: trust frame gate above; clear stale time gate once time is valid.
    if now <= 0 then
        return untilFrame > 0
    end
    if now < untilT then
        return true
    end
    Sch._sessionSettleUntil = 0
    return false
end

function Sch.SkipUiHoldFooter()
    return Sch._skipUiHoldFooter == true
end

function Sch.ClearSkipUiHoldFooter()
    Sch._skipUiHoldFooter = false
end

function Sch.EnqueueBagFlush(needQueue)
    if Sch.IsInventorySideEffectsSuppressed() then
        Sch._pendingBagFlushAfterSuppress = true
        if needQueue == true then
            Sch._pendingBagNeedQueueAfterSuppress = true
        end
        return
    end
    local now = Now()
    if Sch._bagDue == true then
        if needQueue == true then
            Sch._bagNeedQueue = true
        end
        return
    end
    Sch._bagDue = true
    Sch._bagAt = now + Sch.BAG_COALESCE_SEC
    if needQueue == true then
        Sch._bagNeedQueue = true
    end
end

function Sch.OnTradeSkillsChanged(payload)
    -- Clear even for load-time "trade-caps". A learned or dropped profession
    -- has to change the plan key before the next read-only lookup.
    local Planner = StockPiler.Planner
    if Planner and Planner.OnTradeSkillsChanged then
        Planner.OnTradeSkillsChanged(payload)
    end
    if type(payload) == "table" and payload.reason == "trade-caps" then
        return
    end
    if StockPiler.Planner and StockPiler.Planner.RefreshSkillGateStatuses then
        StockPiler.Planner.RefreshSkillGateStatuses()
    end
    Sch.EnqueuePlanRebuild({ urgent = true })
    Sch.WakeAutoGrow()
end

function Sch.EnqueuePlanRebuild(opts)
    opts = type(opts) == "table" and opts or {}
    local nudge = opts.nudge == true
    -- Structural watch mark/clear: fire on next tick; skip AutoGrow 3s coalesce + min-gap.
    local urgent = opts.urgent == true
    if Sch.IsInventorySideEffectsSuppressed() then
        Sch._pendingPlanAfterSuppress = true
        if urgent == true then
            Sch._pendingPlanUrgent = true
        end
        return
    end
    -- A pending bag flush used to drop the rebuild, including urgent ones,
    -- and the post-flush enqueue was always the slow coalesce (CORE-9).
    if Sch._bagDue == true then
        Sch._bagNeedQueue = true
        if urgent == true then
            Sch._pendingPlanUrgent = true
        end
        return
    end
    if nudge == true and urgent ~= true and Sch._planDue == true and (tonumber(Sch._planAt) or 0) > 0 then
        return
    end
    local now = Now()
    local wait = 0
    if urgent ~= true then
        wait = tonumber(Sch.PLAN_MAX_WAIT_SEC) or 0.5
        if Sch.ShouldWakeAutoGrow and Sch.ShouldWakeAutoGrow() == true and nudge ~= true then
            wait = tonumber(Sch.PLAN_COALESCE_WHEN_AWAKE_SEC) or 3.0
        end
    end
    local at = now + wait
    if urgent ~= true then
        local minGap = tonumber(Sch.PLAN_MIN_GAP_SEC) or 2.0
        local lastBuilt = tonumber(Sch._lastPlanBuiltAt) or 0
        if lastBuilt > 0 and minGap > 0 then
            local gapAt = lastBuilt + minGap
            if gapAt > at then
                at = gapAt
            end
        end
    end
    Sch._planDue = true
    if Sch._planAt <= 0 or urgent == true then
        Sch._planAt = at
    elseif at > Sch._planAt and nudge ~= true then
        Sch._planAt = at
    end
    if nudge ~= true then
        RequestCachePrewarm("plan-enqueue")
    end
end

function Sch.IsPlanRebuildPending()
    return Sch._planDue == true
end

function Sch.MarkWatchUiDirty(payload)
    local Bus = StockPiler.EventBus
    if Bus and Bus.FireWatchUiDirty then
        Bus.FireWatchUiDirty(type(payload) == "table" and payload or {})
    end
end

function Sch.ShouldWakeAutoGrow()
    local Orch = StockPiler.Orchestrator
    if Orch and Orch.HasAutoGrowWork then
        return Orch.HasAutoGrowWork({
            emptyPlot = true,
            refineDirty = true,
            peek = "cached",
        }) == true
    end
    return false
end

--- Intentional wake: clear fill-block + force plant-queue invalidate + fast ticks.
function Sch.WakeAutoGrow()
    local Orch = StockPiler.Orchestrator
    if Orch and Orch.ClearFillBlocked then
        Orch.ClearFillBlocked()
    end
    local Grow = StockPiler.Grow
    if Grow and Grow.ClearFillBlocked then
        Grow.ClearFillBlocked()
    end
    InvalidatePlantQueue("wake")
    Sch._autoGrowFast = true
end

function Sch.WakeAutoBuy()
    Sch._autoAccum = math.max(tonumber(Sch._autoAccum) or 0, AutoTickIntervalSec())
end

function Sch.SetAutoGrowIdle(idle)
    Sch._autoGrowFast = idle ~= true
end

function Sch.ShouldDeferAutoGrowPlant()
    local SchSelf = Sch
    if SchSelf.IsSessionSettling and SchSelf.IsSessionSettling() == true then
        return true, "session-settle"
    end
    local Inv = StockPiler.Inventory
    if Inv and Inv.IsReady and Inv.IsReady() ~= true then
        return true, "inv-not-ready"
    end
    local Watch = StockPiler.Watch
    if Watch and Watch.IsCombatPauseEnabled and Watch.IsCombatPauseEnabled() ~= true then
        return false, nil
    end
    local player = GameData and GameData.Player
    if type(player) ~= "table" then
        return false, nil
    end
    if player.inCombat == true then
        return true, "combat"
    end
    if player.isInScenario == true then
        return true, "scenario"
    end
    return false, nil
end

function Sch.ArmPlantNextFrame()
    Sch._armPlantNext = true
    Sch._skipBuyThisFrame = true
    -- The next OnUpdate owes an Orchestrator tick, so the plant is one frame
    -- later instead of a full tick with plan and paint suppressed.
    Sch._autoAccum = AutoTickIntervalSec()
end

function Sch.BuySkippedThisFrame()
    return Sch._skipBuyThisFrame == true
end

function Sch.OnUpdate(timeElapsed)
    local plantFrame = Sch._armPlantNext == true
    if plantFrame then
        Sch._armPlantNext = false
        Sch._armedPlantDue = true
        Sch._skipPlanThisFrame = true
        Sch._skipUiThisFrame = true
        Sch._skipBuyThisFrame = true
    end
    local now = Now()
    local pollSec = tonumber(Sch.POLL_SEC) or 0.25
    local pollDue = now <= 0 or (now - (tonumber(Sch._pollAt) or 0) >= pollSec)
    local function Quiet(name, fn)
        local Util = StockPiler.Util
        if Util and Util.TryCallQuiet then
            Util.TryCallQuiet(name, fn)
            return
        end
        pcall(fn)
    end
    if pollDue then
        Sch._pollAt = now
        Quiet("buy-poll", function()
            if StockPiler.Buy and StockPiler.Buy.PollStorePresence then
                StockPiler.Buy.PollStorePresence()
            end
        end)
        Quiet("grow-expire", function()
            if StockPiler.Grow and StockPiler.Grow.ExpireStalePending then
                StockPiler.Grow.ExpireStalePending()
            end
        end)
    end
    local Brew = StockPiler.Brew
    if Brew and Brew.OnUpdate then
        local loadJob = Brew.IsLoadJobActive and Brew.IsLoadJobActive() == true
        if loadJob then
            Quiet("brew-update", function()
                Brew.OnUpdate(timeElapsed)
            end)
        else
            local brewDue = now <= 0 or (now - (tonumber(Sch._brewLightAt) or 0) >= pollSec)
            if brewDue then
                Sch._brewLightAt = now
                Quiet("brew-update", function()
                    Brew.OnUpdate(timeElapsed)
                end)
            end
        end
    end
    DecaySuppressInventorySideEffects()
    DecayOrchDecisionHold()
    Sch.Advance(now)
    MaybeFinishSessionSettle()

    local didHeavy = false
    if FlushBagIfDue() then
        Sch.NoteHeavyWork()
        didHeavy = true
    end
    local brewSession = StockPiler.Orchestrator
        and StockPiler.Orchestrator.IsBrewSessionActive
        and StockPiler.Orchestrator.IsBrewSessionActive() == true
    if StockPiler.Ui and StockPiler.Ui.FlushBurstHeldWatchRecount then
        StockPiler.Ui.FlushBurstHeldWatchRecount()
    end
    -- Quiet often expires before the seed-buffer burst does. Flush the latched
    -- prewarm once, when the burst is idle, instead of on the next 2s bag flush.
    if Sch._pendingPrewarmAfterQuiet == true and not IssueBurstActive()
        and not (Sch.IsSuppressed and Sch.IsSuppressed() == true)
    then
        FlushPendingPrewarmAfterQuiet()
    end
    local skipPump = brewSession
        or Sch._skipPlanThisFrame == true
        or (Sch.IsSuppressed and Sch.IsSuppressed() == true)
    if not didHeavy and not skipPump
        and StockPiler.FrameWork and StockPiler.FrameWork.Pump
        and StockPiler.FrameWork.Pump() == true
    then
        didHeavy = true
    end
    if not didHeavy and FlushPendingPlanAfterPrewarm() then
        -- Enqueued only; RebuildPlanIfDue may still run this frame if due.
    end
    if not didHeavy and RebuildPlanIfDue() then
        Sch.NoteHeavyWork()
        didHeavy = true
    end
    -- BufferFlags rebuild: idle one-heavy, never on Orch plant / BagFlush frame.
    if not didHeavy and FlushPendingBufferFlagsRebuild(false) then
        didHeavy = true
    end
    Sch._skipPlanThisFrame = false
    FlushWatchUiIfDue(didHeavy)
    Sch._skipUiThisFrame = false

    Sch._autoAccum = (tonumber(Sch._autoAccum) or 0) + (tonumber(timeElapsed) or 0)
    local tickSec = AutoTickIntervalSec()
    if Sch._autoAccum >= tickSec then
        -- Heavy work skips the Orchestrator tick. Consuming the accumulator
        -- here dropped that whole interval (CORE-2). Keep one tick owed.
        if didHeavy == true then
            if Sch._autoAccum > tickSec then
                Sch._autoAccum = tickSec
            end
        else
            Sch._autoAccum = Sch._autoAccum - tickSec
            if StockPiler.Refine and StockPiler.Refine.DecayRefineWaitTicks then
                StockPiler.Refine.DecayRefineWaitTicks()
            end
            if StockPiler.Grow and StockPiler.Grow.DecayHarvestOpLock then
                StockPiler.Grow.DecayHarvestOpLock()
            end
            if StockPiler.Orchestrator and StockPiler.Orchestrator.DecayFillBlocked then
                StockPiler.Orchestrator.DecayFillBlocked()
            end
            -- Skip Orch while brew load job runs (AddItem path). Keep Orch when
            -- phase=loaded with no job so ProbeStuckAutoLoaded still ticks.
            local skipOrch = StockPiler.Brew
                and StockPiler.Brew.IsLoadJobActive
                and StockPiler.Brew.IsLoadJobActive() == true
            local tickFn = StockPiler.Orchestrator and StockPiler.Orchestrator.Tick
            local ranTick = false
            local tickOk, tickErr = true, nil
            if not skipOrch and tickFn then
                ranTick = true
                tickOk, tickErr = pcall(tickFn)
            end
            -- Clear even when Tick throws or this owed tick did not run.
            -- Leaving the flag set let a later pick skip the one-frame defer.
            if Sch._armedPlantDue == true and Sch._armPlantNext ~= true then
                Sch._skipBuyThisFrame = false
            end
            Sch._armedPlantDue = false
            if ranTick and tickOk ~= true then
                if StockPiler.Debug and StockPiler.Debug.ReportProtectedCallFailure then
                    StockPiler.Debug.ReportProtectedCallFailure("Orchestrator.Tick", tickErr, true)
                end
            end
        end
    end
end

function Sch.Initialize()
    if Sch._initialized == true then
        return
    end
    Sch._initialized = true
    local E = StockPiler.Events
    local B = StockPiler.EventBus
    if not (B and E) then
        return
    end
    TrackBus(B.Subscribe(E.INVENTORY_SNAPSHOT, OnInventorySnapshot))
    TrackBus(B.Subscribe(E.GARDEN_DIRTY, OnGardenDirty))
    TrackBus(B.Subscribe(E.SESSION_LOADED, OnSessionLoaded))
    if E.PLAN_UPDATED then
        TrackBus(B.Subscribe(E.PLAN_UPDATED, OnPlanUpdated))
    end
end

function Sch.Shutdown()
    local B = StockPiler.EventBus
    local tokens = Sch._busTokens
    if B and B.Unsubscribe and type(tokens) == "table" then
        for i = 1, #tokens do
            B.Unsubscribe(tokens[i])
        end
    end
    Sch._busTokens = nil
    Sch._initialized = false
    Sch._bagDue = false
    Sch._planDue = false
    Sch._harvestStormUntil = 0
    Sch._plantQuietUntil = 0
    Sch._pendingPrewarmAfterQuiet = false
    Sch._pendingPrewarmReason = nil
    Sch._pendingPlanAfterPrewarm = false
    Sch._pendingPlanUrgent = false
    Sch._orchDecisionHoldTicks = 0
    Sch._awaitingSessionLoad = false
    Sch._heavyWorkFrame = -1
    Sch._pendingBufferFlagsRebuild = false
    Sch._pollAt = 0
    Sch._brewLightAt = 0
end
