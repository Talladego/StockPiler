----------------------------------------------------------------
-- StockPiler Core/Orchestrator -- phase FSM + paced AutoGrow tick
-- Tick order: plant one -> additives -> refine -> buy (buy also runs when the vendor is open).
-- fillBlocked: extend only if newWait > cur; clear when buffer ok.
----------------------------------------------------------------

StockPiler = StockPiler or {}
StockPiler.Orchestrator = StockPiler.Orchestrator or {}

local Orch = StockPiler.Orchestrator

Orch.Phase = "idle"
Orch._brewPhase = nil
Orch._lastOpId = 0
Orch._initialized = false
Orch._fillBlocked = false
Orch._fillBlockedWait = 0
Orch._busTokens = nil
Orch._seedBufferRefineArmed = false
Orch._inTick = false
-- After this many refine-first misses in a row, allow the plant re-probe so
-- empty plots are not held forever when NeedsRefineFirst disagrees with Issue (#35 N3).
Orch.REFINE_FIRST_MAX_MISSES = 3
Orch._refineFirstMisses = 0

local function SetPhase(phase, reason)
    phase = tostring(phase or "idle")
    if Orch.Phase == phase then
        return
    end
    local prev = Orch.Phase
    Orch.Phase = phase
    if StockPiler.Debug and StockPiler.Debug.LogOp then
        StockPiler.Debug.LogOp("orch", tostring(prev) .. "->" .. phase .. " reason=" .. tostring(reason or "?"))
    end
    local B = StockPiler.EventBus
    local E = StockPiler.Events
    if B and E and E.PHASE_CHANGED then
        B.Fire(E.PHASE_CHANGED, { phase = phase, prev = prev, reason = reason })
    end
end

local function HasAutoBuyWork()
    return StockPiler.Buy and StockPiler.Buy.NeedsTick and StockPiler.Buy.NeedsTick() == true
end

local function TryBuyTick(opId)
    local Sch = StockPiler.Scheduler
    if Sch and Sch.BuySkippedThisFrame and Sch.BuySkippedThisFrame() == true then
        return false
    end
    if not HasAutoBuyWork() then
        return false
    end
    local Buy = StockPiler.Buy
    local ok = false
    if Buy and Buy.IssueOne then
        ok = Buy.IssueOne(opId) == true
    end
    if ok then
        SetPhase("buying", "auto")
        if StockPiler.Scheduler and StockPiler.Scheduler.WakeAutoBuy then
            StockPiler.Scheduler.WakeAutoBuy()
        end
        return true
    end
    return false
end

local function HasPendingBufferRefine()
    local Grow = StockPiler.Grow
    if Grow and Grow.HasPendingBufferRefine and Grow.HasPendingBufferRefine() == true then
        return true
    end
    return false
end

function Orch.HasAutoGrowWork(opts)
    opts = type(opts) == "table" and opts or {}
    local Watch = StockPiler.Watch
    if not Watch or not Watch.IsAutoGrowEnabled or Watch.IsAutoGrowEnabled() ~= true then
        return false
    end
    local Grow = StockPiler.Grow
    if Grow and Grow.NeedsCurrentStageAdditive and Grow.NeedsCurrentStageAdditive() then
        return true
    end
    -- Pending or dirty refine is already work. Skip the Apo resin bag scan.
    local RP = StockPiler.RefinePipeline
    if RP and RP.HasOutstanding and RP.HasOutstanding() == true then
        return true
    end
    local fillBlocked = opts.respectFillBlock == true and Orch.IsFillBlocked()
    local Refine = StockPiler.Refine
    if not fillBlocked and opts.refineDirty == true and Refine and Refine._refineDirty == true then
        return true
    end
    -- Apo resin refine survives a cleared _refineDirty and full plots. The
    -- quiet-idle skip must not drop the tick before the vendor-open tip.
    local SkillUp = StockPiler.SkillUp
    if SkillUp and SkillUp.HasApoResinRefinePlant and SkillUp.HasApoResinRefinePlant() == true then
        return true
    end
    if fillBlocked then
        return HasPendingBufferRefine()
    end
    if opts.emptyPlot == true and Grow and Grow.HasEmptyPlot and Grow.HasEmptyPlot() then
        return true
    end
    if opts.peek == "fresh" and Refine and Refine.PeekFreshBufferPending then
        local peeked = Refine.PeekFreshBufferPending()
        if peeked ~= nil then
            return peeked == true
        end
    elseif opts.peek == "cached" then
        return Refine and Refine.PeekCachedBufferPending and Refine.PeekCachedBufferPending() == true
    end
    if opts.rebuildOnStale == true then
        return HasPendingBufferRefine()
    end
    return false
end

local function HasAutoGrowWork()
    return Orch.HasAutoGrowWork({
        respectFillBlock = true,
        emptyPlot = true,
        refineDirty = true,
        peek = "fresh",
        rebuildOnStale = true,
    }) == true
end

local function ClearFillIfBufferOk()
    local Grow = StockPiler.Grow
    if Grow and Grow.IsSeedBufferSatisfied and Grow.IsSeedBufferSatisfied() == true then
        Orch.ClearFillBlocked()
        if Grow.ClearFillBlocked then
            Grow.ClearFillBlocked()
        end
        return true
    end
    return false
end

local function EndTick()
    Orch._inTick = false
    if StockPiler.Perf and StockPiler.Perf.End then
        StockPiler.Perf.End("Orchestrator.Tick")
    end
end

local function HoldFastTick(Sch)
    if Sch and Sch.SetAutoGrowIdle then
        Sch.SetAutoGrowIdle(false)
    end
end

--- Pick/collect already ran this frame, or this frame already called PlantSeed.
--- Do not stack a second engine issue onto that frame.
local function SkipPlantIssue(Grow, Sch)
    if Grow and Grow.IssuedThisFrame and Grow.IssuedThisFrame() == true then
        return true
    end
    if Grow and Grow.ShouldDeferPlantIssue and Grow.ShouldDeferPlantIssue() == true then
        HoldFastTick(Sch)
        return true
    end
    return false
end

function Orch.GetPhase()
    return tostring(Orch.Phase or "idle")
end

function Orch.IsHarvestActive()
    if StockPiler.Grow and StockPiler.Grow.IsHarvestOpActive then
        return StockPiler.Grow.IsHarvestOpActive() == true
    end
    return false
end

function Orch.IsBrewSessionActive()
    return Orch._brewPhase == "loading" or Orch._brewPhase == "loaded"
end

function Orch.SetBrewPhase(phase)
    Orch._brewPhase = phase
end

function Orch.IsFillBlocked()
    return Orch._fillBlocked == true
end

--- only extend until-time if later than current; wait is seconds via NowSec
function Orch.SetFillBlocked(wait)
    wait = tonumber(wait) or 0
    if wait < 0 then
        wait = 0
    end
    local now = 0
    if StockPiler.Util and StockPiler.Util.NowSec then
        now = tonumber(StockPiler.Util.NowSec()) or 0
    end
    local untilT = now > 0 and (now + wait) or 0
    local curUntil = tonumber(Orch._fillBlockedUntil) or 0
    if untilT > curUntil then
        Orch._fillBlockedUntil = untilT
    end
    local cur = tonumber(Orch._fillBlockedWait) or 0
    if wait > cur then
        Orch._fillBlockedWait = wait
    end
    Orch._fillBlocked = true
end

function Orch.ClearFillBlocked()
    Orch._fillBlocked = false
    Orch._fillBlockedWait = 0
    Orch._fillBlockedUntil = 0
end

function Orch.DecayFillBlocked()
    if Orch._fillBlocked ~= true then
        return
    end
    local now = 0
    if StockPiler.Util and StockPiler.Util.NowSec then
        now = tonumber(StockPiler.Util.NowSec()) or 0
    end
    local untilT = tonumber(Orch._fillBlockedUntil) or 0
    if now > 0 and untilT > 0 then
        if now >= untilT then
            Orch.ClearFillBlocked()
        end
        return
    end
    -- now==0: keep blocked; tick fallback when until was never stamped.
    local wait = tonumber(Orch._fillBlockedWait) or 0
    if wait <= 0 then
        Orch.ClearFillBlocked()
        return
    end
    wait = wait - 1
    Orch._fillBlockedWait = wait
    if wait <= 0 then
        Orch.ClearFillBlocked()
    end
end

function Orch.OnAutoGrowDisabled()
    SetPhase("idle", "autogrow-off")
    Orch.ClearFillBlocked()
    if StockPiler.Scheduler and StockPiler.Scheduler.SetAutoGrowIdle then
        StockPiler.Scheduler.SetAutoGrowIdle(true)
    end
end

function Orch.NewOpId()
    if StockPiler.Debug and StockPiler.Debug.NextOpId then
        Orch._lastOpId = StockPiler.Debug.NextOpId()
    else
        Orch._lastOpId = (tonumber(Orch._lastOpId) or 0) + 1
    end
    return Orch._lastOpId
end

function Orch.Tick()
    -- PlantSeed/AddAdditive can re-enter UPDATE_PROCESSED on the same C stack.
    if Orch._inTick == true then
        return
    end

    -- Quiet idle: skip entirely (no Perf.Begin) when nothing to do.
    -- Brew session still ticks for ProbeStuckAutoLoaded.
    if Orch.IsBrewSessionActive() ~= true and Orch.IsHarvestActive() ~= true then
        local buyNeed = HasAutoBuyWork()
        local Watch = StockPiler.Watch
        local autoGrowOn = Watch and Watch.IsAutoGrowEnabled and Watch.IsAutoGrowEnabled() == true
        if not autoGrowOn then
            if buyNeed ~= true then
                return
            end
        elseif HasAutoGrowWork() ~= true and buyNeed ~= true then
            local Sch = StockPiler.Scheduler
            if Sch and Sch.SetAutoGrowIdle then
                Sch.SetAutoGrowIdle(true)
            end
            if Orch.Phase ~= "idle" then
                SetPhase("idle", "idle-grow-quiet")
            end
            return
        end
    end

    Orch._inTick = true

    local ok, err = pcall(Orch._TickBody)
    if ok ~= true then
        Orch._inTick = false
        if StockPiler.Perf and StockPiler.Perf.End then
            StockPiler.Perf.End("Orchestrator.Tick")
        end
        if StockPiler.Debug and StockPiler.Debug.ReportProtectedCallFailure then
            StockPiler.Debug.ReportProtectedCallFailure("Orchestrator.Tick", err, true)
        end
    end
end

function Orch._TickBody()
    if StockPiler.Perf and StockPiler.Perf.Begin then
        StockPiler.Perf.Begin("Orchestrator.Tick")
    end

    local Watch = StockPiler.Watch
    local autoGrowOn = Watch and Watch.IsAutoGrowEnabled and Watch.IsAutoGrowEnabled() == true
    if not autoGrowOn then
        -- AutoGrow off -> buy only
        TryBuyTick(Orch.NewOpId())
        if Orch.Phase ~= "idle" and not Orch.IsHarvestActive() and not Orch.IsBrewSessionActive() then
            SetPhase("idle", "autogrow-off")
        end
        EndTick()
        return
    end

    local Sch = StockPiler.Scheduler
    if Sch and Sch.IsSessionSettling and Sch.IsSessionSettling() == true then
        if Sch.SetAutoGrowIdle then
            Sch.SetAutoGrowIdle(false)
        end
        TryBuyTick(Orch.NewOpId())
        EndTick()
        return
    end

    -- fillBlocked: allow refine AND plant (FindSeedSlot misses after refine used to
    -- latch fillBlocked and never retry planting while seeds sat in bag).
    if Orch.IsFillBlocked() then
        local Refine = StockPiler.Refine
        if Refine and Refine.ShouldAllowRefineNow and Refine.ShouldAllowRefineNow() ~= true then
            if Refine.MaybeNotifyBlocked then
                Refine.MaybeNotifyBlocked()
            end
        end
        local Grow = StockPiler.Grow
        local Sch = StockPiler.Scheduler
        local bufferRefine = HasPendingBufferRefine()
        local refineForced = Refine and (
            Refine._refineDirty == true
            or tostring(Refine._refineDirtyReason or "") == "harvest"
        )
        local usRefine = false
        local US = StockPiler.UpgradeSeed
        if US and US.IsEnabled and US.IsEnabled() == true
            and US.NeedsRefineFirst and US.NeedsRefineFirst() == true
        then
            usRefine = true
            if Refine and Refine.MarkRefineDue then
                Refine.MarkRefineDue("upgrade-seed")
            end
        end
        local canPlant = Grow and Grow.HasEmptyPlot and Grow.HasEmptyPlot() == true
        -- Remount have/demand for plant/refine probes (before ArmPlantQuiet).
        if Sch and Sch.ArmOrchDecisionHold then
            Sch.ArmOrchDecisionHold(2)
        end
        local hasSeeds = false
        local climbPending = Grow and Grow.ShortClimbPending and Grow.ShortClimbPending() == true
        if usRefine and climbPending ~= true then
            -- Cheap probe clear; do not run PickPlantCandidate while refine-first.
            -- A short potion climb still picks: stamping nil here left the level-50
            -- seed unplanted until /stp all ran GetPlantJob itself.
            if Grow and Grow.MarkPlantJobProbed then
                Grow.MarkPlantJobProbed(nil)
            end
        elseif canPlant and Grow and Grow.GetPlantJob then
            local job = Grow.GetPlantJob()
            hasSeeds = type(job) == "table" and (tonumber(job.seedUid) or 0) > 0
        end
        if canPlant or bufferRefine or refineForced or usRefine then
            if Sch and Sch.SetAutoGrowIdle then
                Sch.SetAutoGrowIdle(false)
            end
        end
        local opId = Orch.NewOpId()
        if canPlant and hasSeeds then
            if SkipPlantIssue(Grow, Sch) then
                EndTick()
                return
            end
            local planted = false
            if Grow and Grow.IssuePlantOne then
                planted = Grow.IssuePlantOne(opId) == true
            end
            if planted then
                SetPhase("planting", "auto")
                Orch.ClearFillBlocked()
                if Sch and Sch.WakeAutoGrow then
                    Sch.WakeAutoGrow()
                end
                EndTick()
                return
            end
        end
        if (bufferRefine or refineForced or usRefine)
            and Refine and Refine.ShouldAllowRefineNow and Refine.ShouldAllowRefineNow() == true
            and Refine.RefineCheckDue and Refine.RefineCheckDue() == true
            and Refine.TryTick
        then
            if Refine.TryTick(opId) == true then
                SetPhase("refining", bufferRefine and "seed-buffer" or "auto")
                Orch.ClearFillBlocked()
                if Sch and Sch.WakeAutoGrow then
                    Sch.WakeAutoGrow()
                end
                EndTick()
                return
            end
            if Refine.TakeDeferredIssue and Refine.TakeDeferredIssue() == true then
                HoldFastTick(Sch)
                EndTick()
                return
            end
        end
        -- Keep fast ticks while empty plots remain; idle-5s made fillBlocked feel stuck.
        if not canPlant and Sch and Sch.SetAutoGrowIdle then
            Sch.SetAutoGrowIdle(true)
        end
        if Orch.Phase ~= "idle" and not Orch.IsHarvestActive() and not Orch.IsBrewSessionActive() then
            SetPhase("idle", "fill-blocked")
        end
        TryBuyTick(Orch.NewOpId())
        EndTick()
        return
    end

    local suppressed = Sch and Sch.IsSuppressed and Sch.IsSuppressed() == true
    local settling = Sch and Sch.IsSessionSettling and Sch.IsSessionSettling() == true
    -- plant quiet / harvest storm / session settle -> fast tick, no grow probes
    if suppressed or settling then
        if Sch and Sch.SetAutoGrowIdle then
            Sch.SetAutoGrowIdle(false)
        end
        TryBuyTick(Orch.NewOpId())
        EndTick()
        return
    end

    -- brew loading/loaded -> skip grow; buy allowed.
    -- Probe first: settle-hold then silence can park phase=loaded forever
    -- (blocks grow + plan rebuild until a forced Build / watchplan).
    if Orch.IsBrewSessionActive() == true then
        local Brew = StockPiler.Brew
        if Brew and Brew.ProbeStuckAutoLoaded then
            Brew.ProbeStuckAutoLoaded("orch-tick")
        end
        if Brew and Brew.MaybeAutoPerformReady then
            Brew.MaybeAutoPerformReady()
        end
    end
    if Orch.IsBrewSessionActive() == true then
        if Sch and Sch.SetAutoGrowIdle then
            Sch.SetAutoGrowIdle(false)
        end
        TryBuyTick(Orch.NewOpId())
        EndTick()
        return
    end

    if not HasAutoGrowWork() then
        if Sch and Sch.SetAutoGrowIdle then
            Sch.SetAutoGrowIdle(true)
        end
        if TryBuyTick(Orch.NewOpId()) then
            EndTick()
            return
        end
        if Orch.Phase ~= "idle" and not Orch.IsHarvestActive() and not Orch.IsBrewSessionActive() then
            SetPhase("idle", "idle-grow")
        end
        EndTick()
        return
    end

    -- Buy takes this tick only when we are not about to plant. A plant frame
    -- must not also IssueOne a purchase (0.3.410 live).
    local Grow = StockPiler.Grow
    local canPlant = Grow and Grow.HasEmptyPlot and Grow.HasEmptyPlot() == true
    if not canPlant then
        if TryBuyTick(Orch.NewOpId()) then
            EndTick()
            return
        end
    end
    -- Remount have/demand for plant/refine probes (before ArmPlantQuiet after IssueOne).
    if Sch and Sch.ArmOrchDecisionHold then
        Sch.ArmOrchDecisionHold(2)
    end
    -- Upgrade Seed refine-first: skip demand pick, clear plant-probe via MarkPlantJobProbed.
    -- Leaving dirty made ShouldAllowRefineNow return plant-probe-pending and block
    -- refine for ~50s after harvest (idle 5s ticks until a dump probed the queue).
    local usRefineFirst = false
    local US = StockPiler.UpgradeSeed
    local climbPending = Grow and Grow.ShortClimbPending and Grow.ShortClimbPending() == true
    if US and US.IsEnabled and US.IsEnabled() == true
        and US.NeedsRefineFirst and US.NeedsRefineFirst() == true
    then
        if StockPiler.Refine and StockPiler.Refine.MarkRefineDue then
            StockPiler.Refine.MarkRefineDue("upgrade-seed")
        end
        if climbPending ~= true then
            usRefineFirst = true
            if Grow and Grow.MarkPlantJobProbed then
                Grow.MarkPlantJobProbed(nil)
            elseif Grow and Grow.GetPlantJob then
                Grow.GetPlantJob()
            end
        end
    else
        Orch._refineFirstMisses = 0
    end
    -- One plant-queue probe per tick (nil-cache makes idle re-entry O(1)).
    local hasSeeds = false
    if canPlant and not usRefineFirst and Grow and Grow.GetPlantJob then
        local job = Grow.GetPlantJob()
        hasSeeds = type(job) == "table" and (tonumber(job.seedUid) or 0) > 0
    end
    local needAdditives = Grow and Grow.NeedsCurrentStageAdditive
        and Grow.NeedsCurrentStageAdditive() == true
    local holdHarvestBatch = Grow and Grow.ShouldHoldPlantForReadyHarvest
        and Grow.ShouldHoldPlantForReadyHarvest() == true
    local opId = Orch.NewOpId()

    if (canPlant and hasSeeds) or needAdditives or usRefineFirst then
        if Sch and Sch.SetAutoGrowIdle then
            Sch.SetAutoGrowIdle(false)
        end
    end

    -- 1) Plant one seed
    if canPlant and hasSeeds and not holdHarvestBatch then
        local deferPlant, deferReason = false, nil
        if Sch and Sch.ShouldDeferAutoGrowPlant then
            deferPlant, deferReason = Sch.ShouldDeferAutoGrowPlant()
        end
        if deferPlant == true then
            if Grow and Grow.LogSkipPlant then
                Grow.LogSkipPlant(tostring(deferReason or "combat"))
            end
            if Sch and Sch.SetAutoGrowIdle then
                Sch.SetAutoGrowIdle(false)
            end
        else
            if SkipPlantIssue(Grow, Sch) then
                EndTick()
                return
            end
            local planted = Grow and Grow.IssuePlantOne and Grow.IssuePlantOne(opId) == true
            if planted then
                SetPhase("planting", "auto")
                if Sch and Sch.WakeAutoGrow then
                    Sch.WakeAutoGrow()
                end
                EndTick()
                return
            end
            -- Transient plant miss (plot still occupied / API fail): re-probe next tick.
        end
    elseif canPlant and hasSeeds and holdHarvestBatch then
        if Sch and Sch.SetAutoGrowIdle then
            Sch.SetAutoGrowIdle(false)
        end
    elseif canPlant and not hasSeeds then
        if HasPendingBufferRefine() or usRefineFirst then
            if not usRefineFirst and Orch._seedBufferRefineArmed ~= true
                and StockPiler.Refine and StockPiler.Refine.MarkRefineDue
            then
                Orch._seedBufferRefineArmed = true
                StockPiler.Refine.MarkRefineDue("seed-buffer")
            end
            if Sch and Sch.SetAutoGrowIdle then
                Sch.SetAutoGrowIdle(false)
            end
        else
            Orch._seedBufferRefineArmed = false
            if not ClearFillIfBufferOk() then
                -- Do NOT re-arm fillBlocked every idle tick when already blocked
                -- or when buffer is merely short without a plant attempt this tick.
            end
            if Sch and Sch.SetAutoGrowIdle then
                Sch.SetAutoGrowIdle(true)
            end
        end
    else
        Orch._seedBufferRefineArmed = false
    end

    -- 2) Additives
    if needAdditives then
        local added = false
        if Grow and Grow.TryAdditive then
            added = Grow.TryAdditive(opId) == true
        end
        if added then
            SetPhase("planting", "additive")
            if Sch and Sch.WakeAutoGrow then
                Sch.WakeAutoGrow()
            end
            EndTick()
            return
        end
    end

    -- 3) Refine
    local Refine = StockPiler.Refine
    local allowRefine = Refine and Refine.ShouldAllowRefineNow and Refine.ShouldAllowRefineNow() == true
    -- Unconditional: MaybeNotifyBlocked also clears its latches once refine is
    -- allowed again or the merchant / NPC dialog is no longer the block.
    if Refine and Refine.MaybeNotifyBlocked then
        Refine.MaybeNotifyBlocked()
    end
    local refineDue = allowRefine == true
        and Refine.RefineCheckDue and Refine.RefineCheckDue() == true
    if refineDue and Refine.TryTick then
        local ok = Refine.TryTick(opId)
        if ok == true then
            Orch._refineFirstMisses = 0
            SetPhase("refining", "auto")
            if Grow and Grow.MarkPlantJobDirty then
                Grow.MarkPlantJobDirty("refine")
            end
            if Sch and Sch.WakeAutoGrow then
                Sch.WakeAutoGrow()
            end
            EndTick()
            return
        end
        if Refine.TakeDeferredIssue and Refine.TakeDeferredIssue() == true then
            HoldFastTick(Sch)
            EndTick()
            return
        end
        -- Refine-first must not fill the plot when the refine did not run (CORE-17),
        -- but after N misses allow the plant re-probe so plots are not held empty
        -- forever when NeedsRefineFirst disagrees with CollectIntents/Issue (#35 N3).
        local maxMisses = tonumber(Orch.REFINE_FIRST_MAX_MISSES) or 3
        if usRefineFirst then
            Orch._refineFirstMisses = (tonumber(Orch._refineFirstMisses) or 0) + 1
        end
        local holdPlantForRefine = usRefineFirst
            and (tonumber(Orch._refineFirstMisses) or 0) < maxMisses
        if holdPlantForRefine then
            if Sch and Sch.SetAutoGrowIdle then
                Sch.SetAutoGrowIdle(false)
            end
        else
        -- After a failed non-refine-first refine (or refine-first miss budget),
        -- re-probe once and plant same tick.
        if canPlant and Grow and Grow.MarkPlantJobDirty then
            Grow.MarkPlantJobDirty("refine-miss")
            if Grow.GetPlantJob then
                local job = Grow.GetPlantJob()
                hasSeeds = type(job) == "table" and (tonumber(job.seedUid) or 0) > 0
            end
        end
        if canPlant and hasSeeds and not holdHarvestBatch then
            if SkipPlantIssue(Grow, Sch) then
                EndTick()
                return
            end
            local planted = Grow and Grow.IssuePlantOne and Grow.IssuePlantOne(opId) == true
            if planted then
                Orch._refineFirstMisses = 0
                SetPhase("planting", "auto")
                if Sch and Sch.WakeAutoGrow then
                    Sch.WakeAutoGrow()
                end
                EndTick()
                return
            end
        elseif canPlant and not hasSeeds then
            if not ClearFillIfBufferOk() then
                Orch.SetFillBlocked(5)
            end
        end
        end
    elseif canPlant and not hasSeeds then
        if not ClearFillIfBufferOk() then
            -- Only arm after a real no-job path this tick (not every idle)
            if Orch._fillBlocked ~= true then
                Orch.SetFillBlocked(5)
            end
        end
    end

    -- 4) Buy
    if TryBuyTick(opId) then
        EndTick()
        return
    end

    if Orch.Phase ~= "idle" and not Orch.IsHarvestActive() and not Orch.IsBrewSessionActive() then
        SetPhase("idle", "tick-idle")
    end
    EndTick()
end

function Orch.DumpState(emit)
    emit = type(emit) == "function" and emit or function(msg)
        if StockPiler.Debug and StockPiler.Debug.Print then
            StockPiler.Debug.Print(msg)
        end
    end
    emit("=== StockPiler state ===")
    emit("phase=" .. Orch.GetPhase() .. " lastOpId=" .. tostring(Orch._lastOpId or 0))
    local Bridge = StockPiler.EngineEventBridge
    local streaks = Bridge and Bridge._stageFailStreak
    if type(streaks) == "table" then
        for name, n in pairs(streaks) do
            if (tonumber(n) or 0) > 0 then
                emit("stageFail " .. tostring(name) .. "=" .. tostring(n))
            end
        end
    end
    emit("harvestActive=" .. tostring(Orch.IsHarvestActive() == true))
    emit("brewPhase=" .. tostring(Orch._brewPhase or "none"))
    emit("fillBlocked=" .. tostring(Orch._fillBlocked == true)
        .. " wait=" .. tostring(Orch._fillBlockedWait or 0))
    local Sch = StockPiler.Scheduler
    if Sch then
        emit("harvestStorm=" .. tostring(Sch.IsHarvestStorm and Sch.IsHarvestStorm() == true))
        emit("plantQuiet=" .. tostring(Sch.IsPlantQuiet and Sch.IsPlantQuiet() == true))
    end
    if StockPiler.Inventory and StockPiler.Inventory.GetSnapshotMeta then
        local m = StockPiler.Inventory.GetSnapshotMeta()
        emit(string.format(
            "inventory snapGen=%s ready=%s dirty=%s",
            tostring(m.snapGen), tostring(m.ready), tostring(m.dirty)
        ))
    elseif StockPiler.Inventory and StockPiler.Inventory.GetSnapGen then
        emit("inventory snapGen=" .. tostring(StockPiler.Inventory.GetSnapGen()))
    end
    if StockPiler.Garden and StockPiler.Garden.GetGen then
        emit("gardenGen=" .. tostring(StockPiler.Garden.GetGen()))
    end
    if StockPiler.Watch and StockPiler.Watch.GetGen then
        emit("watchGen=" .. tostring(StockPiler.Watch.GetGen()))
    end
    if StockPiler.Knowledge and StockPiler.Knowledge.GetGen then
        emit("knowledgeGen=" .. tostring(StockPiler.Knowledge.GetGen()))
    end
    if StockPiler.RefinePipeline and StockPiler.RefinePipeline.GetGen then
        emit("refinePipelineGen=" .. tostring(StockPiler.RefinePipeline.GetGen()))
    end
    if StockPiler.PlanSnapshot and StockPiler.PlanSnapshot.Get then
        local plan = StockPiler.PlanSnapshot.Get()
        if type(plan) == "table" then
            emit("planGen=" .. tostring(plan.planGen) .. " cacheKey=" .. tostring(plan.cacheKey))
        end
    end
    emit("=== end state ===")
end

function Orch.Initialize()
    if Orch._initialized == true then
        return
    end
    local E = StockPiler.Events
    local B = StockPiler.EventBus
    if not B or not E then
        return
    end
    Orch._initialized = true
end

function Orch.Shutdown()
    local B = StockPiler.EventBus
    local tokens = Orch._busTokens
    if B and B.Unsubscribe and type(tokens) == "table" then
        for i = 1, #tokens do
            B.Unsubscribe(tokens[i])
        end
    end
    Orch._busTokens = nil
    Orch._initialized = false
    Orch.Phase = "idle"
    Orch._brewPhase = nil
    Orch.ClearFillBlocked()
end
