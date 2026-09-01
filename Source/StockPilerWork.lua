----------------------------------------------------------------
-- StockPilerWork — exclusive auto vs user lanes + completion refresh
----------------------------------------------------------------

StockPiler.Work = StockPiler.Work or {}

local function SnapGen()
    return tonumber(StockPiler.Inventory and StockPiler.Inventory._snapshotGen) or 0
end

local function PlanGen()
    local plan = StockPiler.Planner and StockPiler.Planner._planCache
    if type(plan) == "table" then
        return tonumber(plan.gen) or tonumber(plan.planGen) or 0
    end
    return 0
end

--- True when full bag flatten should wait (combat or RvR lake).
function StockPiler.ShouldDeferHeavyBagWork()
    local player = GameData and GameData.Player
    if type(player) ~= "table" then
        return false
    end
    if player.inCombat == true then
        return true
    end
    if player.isInRvRLake == true then
        return true
    end
    return false
end

--- Brew session owns apo (loading or loaded) — auto plant/refine must halt.
function StockPiler.Work.BrewSessionActive()
    if not StockPiler.Brew then
        return false
    end
    if StockPiler.Brew.IsBusy and StockPiler.Brew.IsBusy() == true then
        return true
    end
    local session = StockPiler.Brew.GetSession and StockPiler.Brew.GetSession()
    if type(session) ~= "table" then
        return false
    end
    return session.phase == "loaded" or session.phase == "loading"
end

--- Plant-need refine or post-harvest buffer settle in flight.
function StockPiler.Work.GrowOpActive()
    if not StockPiler.AutoGrow then
        return false
    end
    if StockPiler.AutoGrow.HasPendingRefine and StockPiler.AutoGrow.HasPendingRefine() then
        return true
    end
    if StockPiler.AutoGrow._autoRefinePending ~= nil then
        return true
    end
    if StockPiler.AutoGrow.AnyHarvestBufferMaintenancePending
        and StockPiler.AutoGrow.AnyHarvestBufferMaintenancePending()
    then
        return true
    end
    -- Pending plant AddCraftingItem
    local pending = StockPiler.AutoGrow._pendingPlant
    if type(pending) == "table" then
        for _, n in pairs(pending) do
            if (tonumber(n) or 0) > 0 then
                return true
            end
        end
    end
    return false
end

--- Auto lane may plant / refine / additive.
function StockPiler.Work.CanRunAuto()
    if StockPiler.Work.BrewSessionActive() then
        return false, "brew-session"
    end
    if StockPiler.BagWorkPending and StockPiler.BagWorkPending() then
        return false, "bag-work"
    end
    return true, nil
end

--- User lane may start a brew load (not while grow refine/settle in flight).
function StockPiler.Work.CanStartBrewLoad()
    if StockPiler.Work.GrowOpActive() then
        return false, L"Brew held: AutoGrow is converting or planting. Wait a moment."
    end
    return true, nil
end

function StockPiler.Work.SnapGen()
    return SnapGen()
end

function StockPiler.Work.PlanGen()
    return PlanGen()
end

--- Soft completion: infer counts when possible, mark dirty, schedule coalesce (no inline snap).
--- opts.forceSnap — request full bag flush when safe (validate fail / session clear).
--- opts.ui — mark Watch dirty for refresh.
function StockPiler.Work.Complete(kind, opts)
    opts = type(opts) == "table" and opts or {}
    kind = tostring(kind or "op")
    if StockPiler.LogOp then
        StockPiler.LogOp("work", "complete kind=" .. kind
            .. " forceSnap=" .. tostring(opts.forceSnap == true)
            .. " snapGen=" .. tostring(SnapGen()))
    end
    if opts.ui ~= false and StockPiler.AutoGrow then
        StockPiler.AutoGrow._watchUiDirty = true
    end
    if opts.forceSnap == true then
        StockPiler._bagCountsStale = true
        if StockPiler.Planner and StockPiler.Planner.InvalidatePlanCache then
            StockPiler.Planner.InvalidatePlanCache()
        end
        if StockPiler.ScheduleBagWork then
            StockPiler.ScheduleBagWork(true)
        end
    elseif StockPiler.ScheduleBagWork then
        StockPiler.ScheduleBagWork(false)
    end
    if opts.refreshBrewUi == true
        and StockPilerTabAutoGrow
        and StockPilerTabAutoGrow.RefreshBrewUi
    then
        StockPilerTabAutoGrow.RefreshBrewUi()
    end
end
