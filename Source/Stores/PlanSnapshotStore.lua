----------------------------------------------------------------
-- StockPiler Stores/PlanSnapshotStore - cached planner output
----------------------------------------------------------------

StockPiler = StockPiler or {}
StockPiler.PlanSnapshot = StockPiler.PlanSnapshot or {}
local PS = StockPiler.PlanSnapshot

PS._plan = nil
PS._cacheKey = nil

local function FireInvalidated()
    local B = StockPiler.EventBus
    local E = StockPiler.Events
    if B and E and E.PLAN_INVALIDATED then
        B.Fire(E.PLAN_INVALIDATED, {})
    end
end

function PS.Get()
    return PS._plan
end

--- Store only. PublishPlan fires PLAN_UPDATED once. Firing here as well
--- delivered the event twice per rebuild, and GetOrBuild fired it again on
--- cache hits (CORE-4 / PLN-1).
function PS.Set(plan, cacheKey)
    PS._plan = plan
    PS._cacheKey = cacheKey
end

function PS.GetCacheKey()
    return PS._cacheKey
end

--- Soft invalidate: drop cache key, keep stale plan for UI / GetOrBuild(false).
function PS.Invalidate()
    PS._cacheKey = nil
    FireInvalidated()
end

--- Hard clear: drop plan (character / session change only).
function PS.Clear()
    PS._plan = nil
    PS._cacheKey = nil
    FireInvalidated()
end

--- Never sync-build while a coalesced rebuild is pending.
--- GetOrBuild(false) / {refresh=false}: return stale only (may nudge enqueue).
--- GetOrBuild() / true / {refresh=true}: build when Planner exists and not pending.
function PS.GetOrBuild(refresh)
    local opts = {}
    local wantRefresh = true
    if refresh == false then
        wantRefresh = false
    elseif type(refresh) == "table" then
        opts = refresh
        if opts.refresh == false then
            wantRefresh = false
        end
        if opts.force == true then
            wantRefresh = true
        end
    elseif refresh == true then
        wantRefresh = true
    end

    local Sch = StockPiler.Scheduler
    local pending = Sch and Sch.IsPlanRebuildPending and Sch.IsPlanRebuildPending() == true

    -- Pending rebuild: never sync-build; serve last plan (or nil).
    if pending then
        return PS._plan
    end

    if not wantRefresh then
        if Sch and Sch.EnqueuePlanRebuild and type(PS._plan) == "table" then
            -- Stale key (missing or no longer the planner key): nudge only.
            local staleKey = PS._cacheKey == nil
            if staleKey ~= true and StockPiler.Planner
                and StockPiler.Planner.CacheKeyFromGens
            then
                staleKey = PS._cacheKey ~= StockPiler.Planner.CacheKeyFromGens()
            end
            if staleKey and Sch.EnqueuePlanRebuild then
                Sch.EnqueuePlanRebuild({ nudge = true })
            end
        elseif Sch and Sch.EnqueuePlanRebuild then
            Sch.EnqueuePlanRebuild({ nudge = true })
        end
        return PS._plan
    end

    local Planner = StockPiler.Planner
    if Planner and type(Planner.Build) == "function" then
        local plan = Planner.Build(opts)
        if type(plan) == "table" then
            -- Fresh builds are stored and announced in PublishPlan. A cache
            -- hit is already the current snapshot; storing it again fired
            -- PLAN_UPDATED with no new plan.
            return plan
        end
    end

    return PS._plan
end
