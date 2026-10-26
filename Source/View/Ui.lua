----------------------------------------------------------------
-- StockPiler View/Ui -- window show/hide + coalesced Watch flush
----------------------------------------------------------------

StockPiler = StockPiler or {}
StockPiler.Ui = StockPiler.Ui or {}
local Ui = StockPiler.Ui

local function T(key, tokens)
    return StockPiler.Util.T(key, tokens)
end

Ui.WATCH_UI_MIN_INTERVAL_SEC = 5.0
-- When the Watch tab is visible, react faster to stock/status without a full 5s wait.
Ui.WATCH_UI_OPEN_INTERVAL_SEC = 0.5
Ui.BREW_WATCH_CATCHUP_SEC = 1.0
Ui._watchUiDirty = false
Ui._watchUiFlushedAt = 0
Ui._watchUiBrewCatchupAt = 0
Ui._watchUiLastKey = nil
Ui._watchUiLastKnowledgeGen = 0
Ui._watchUiLastPlanGen = 0
Ui._watchUiLastBrewKey = nil
-- True after Knowledge.Touch structural learn (new potion/recipe). PatchLiveHave
-- only updates Have on existing rows; the Potions list needs a full Refresh.
Ui._catalogStructureDirty = false

--- Drop the Watch paint throttle so the next flush is not skipped.
--- Clears both _watchUiLastKey and _watchUiFlushedAt. The trade-skill load path
--- clears only the key; clearing FlushedAt there would change flush timing.
function Ui.BypassWatchThrottle()
    Ui._watchUiLastKey = nil
    Ui._watchUiFlushedAt = 0
end

--- Clear only the content key. Trade-skill updates use this so the flush
--- interval stays on _watchUiFlushedAt.
function Ui.ClearWatchThrottleKey()
    Ui._watchUiLastKey = nil
end

function Ui.OnTradeSkillsChanged(payload)
    payload = type(payload) == "table" and payload or {}
    if Ui.InvalidateSkillGates then
        Ui.InvalidateSkillGates()
    end
    local Bus = StockPiler.EventBus
    if payload.reason == "trade-caps" then
        Ui.ClearWatchThrottleKey()
        if Bus and Bus.FireWatchUiDirty then
            Bus.FireWatchUiDirty({ reason = "trade-caps" })
        end
        return
    end
    if Ui.BypassWatchThrottle then
        Ui.BypassWatchThrottle()
    end
    if Bus and Bus.FireWatchUiDirty then
        Bus.FireWatchUiDirty({ reason = "trade-skill" })
    end
end

function Ui.OnSessionSettled()
    if Ui.InvalidateSkillGates then
        Ui.InvalidateSkillGates()
    end
    if Ui.BypassWatchThrottle then
        Ui.BypassWatchThrottle()
    end
    local Bus = StockPiler.EventBus
    if Bus and Bus.FireWatchUiDirty then
        Bus.FireWatchUiDirty({ reason = "session-settle" })
    end
end

local function IsWatchTabVisible()
    if not DoesWindowExist("StockPilerWindow") then
        return false
    end
    if WindowGetShowing("StockPilerWindow") ~= true then
        return false
    end
    local selected = StockPilerWindow and StockPilerWindow.SelectedTab
    local watchTab = StockPilerWindow and StockPilerWindow.TABS_WATCH
    return selected ~= nil and watchTab ~= nil and selected == watchTab
end

local function IsCatalogTabVisible()
    if not DoesWindowExist("StockPilerWindow") then
        return false
    end
    if WindowGetShowing("StockPilerWindow") ~= true then
        return false
    end
    local selected = StockPilerWindow and StockPilerWindow.SelectedTab
    if selected == nil then
        return false
    end
    local potions = StockPilerWindow.TABS_POTIONS
    local plants = StockPilerWindow.TABS_PLANTS
    return selected == potions or selected == plants
end

local function IsAnyTabVisible()
    return IsWatchTabVisible() or IsCatalogTabVisible()
end

function Ui.Print(msg)
    if StockPiler.Debug and StockPiler.Debug.Reply then
        StockPiler.Debug.Reply(msg)
    elseif StockPiler.Debug and StockPiler.Debug.Print then
        StockPiler.Debug.Print(msg, "user")
    end
end

function Ui.ToggleWindow()
    if not DoesWindowExist("StockPilerWindow") then
        Ui.Print(T("ui.window_missing"))
        return
    end
    if WindowUtils and WindowUtils.ToggleShowing then
        WindowUtils.ToggleShowing("StockPilerWindow")
        return
    end
    local showing = WindowGetShowing("StockPilerWindow") == true
    WindowSetShowing("StockPilerWindow", not showing)
end

function Ui.ShowWindow(tabId)
    if not DoesWindowExist("StockPilerWindow") then
        return
    end
    WindowSetShowing("StockPilerWindow", true)
    if tabId and StockPilerWindow and StockPilerWindow.SelectTab then
        StockPilerWindow.SelectTab(tabId)
    end
end

local function CurrentPlanGen()
    if StockPiler.PlanSnapshot and StockPiler.PlanSnapshot.Get then
        local plan = StockPiler.PlanSnapshot.Get()
        if type(plan) == "table" then
            return tonumber(plan.planGen) or 0
        end
    end
    return 0
end

local function BrewChromeKey()
    local Brew = StockPiler.Brew
    if not Brew or not Brew.GetSession then
        return "idle"
    end
    local session = Brew.GetSession()
    if type(session) ~= "table" then
        return "idle"
    end
    return tostring(session.phase or "idle")
        .. ":" .. tostring(session.potionRecipeKey or session.potionKey or "")
        .. ":" .. tostring(session.rowId or "")
        .. ":" .. tostring(Brew._loadSource or "")
end

local function WatchContentKey()
    local snapGen = 0
    if StockPiler.Inventory and StockPiler.Inventory.GetSnapGen then
        snapGen = tonumber(StockPiler.Inventory.GetSnapGen()) or 0
    end
    local planGen = CurrentPlanGen()
    local knowledgeGen = 0
    if StockPiler.Knowledge and StockPiler.Knowledge.GetGen then
        knowledgeGen = tonumber(StockPiler.Knowledge.GetGen()) or 0
    end
    local watchGen = 0
    if StockPiler.Watch and StockPiler.Watch.GetGen then
        watchGen = tonumber(StockPiler.Watch.GetGen()) or 0
    end
    local autoGrowOn = false
    if StockPiler.Watch and StockPiler.Watch.IsAutoGrowEnabled then
        autoGrowOn = StockPiler.Watch.IsAutoGrowEnabled() == true
    end
    local skillKey = "0"
    local Caps = StockPiler.TradeSkillCaps
    if Caps and Caps.LevelsHash then
        skillKey = tostring(Caps.LevelsHash())
    end
    local SkillUp = StockPiler.SkillUp
    local skillShow = SkillUp and SkillUp.ShouldShowWatchStatus
        and SkillUp.ShouldShowWatchStatus() == true
    -- Plant/empty/lock (not stage-timer GetGen) so garden dirty actually paints.
    local gardenPlanGen = 0
    local Garden = StockPiler.Garden
    if Garden and Garden.GetPlanGen then
        gardenPlanGen = tonumber(Garden.GetPlanGen()) or 0
    end
    return tostring(snapGen)
        .. ":" .. tostring(planGen)
        .. ":" .. tostring(knowledgeGen)
        .. ":" .. tostring(watchGen)
        .. ":" .. tostring(autoGrowOn)
        .. ":" .. tostring(skillKey)
        .. ":" .. tostring(skillShow)
        .. ":" .. tostring(gardenPlanGen)
        .. ":" .. BrewChromeKey()
end

local function IsWatchPlanStale()
    local Sch = StockPiler.Scheduler
    if Sch and Sch.IsPlanRebuildPending and Sch.IsPlanRebuildPending() == true then
        return true
    end
    local Planner = StockPiler.Planner
    if not Planner or not Planner.CacheKeyFromGens then
        return false
    end
    local wantKey = Planner.CacheKeyFromGens()
    local plan = StockPiler.PlanSnapshot and StockPiler.PlanSnapshot.Get and StockPiler.PlanSnapshot.Get()
    if type(plan) ~= "table" then
        return false
    end
    return tostring(plan.cacheKey or "") ~= tostring(wantKey or "")
end

local function OpenPaintActive()
    return StockPilerWindow and StockPilerWindow._openPaintPending == true
end

local function WatchMissingSkillUpRows()
    local SkillUp = StockPiler.SkillUp
    if not (SkillUp and SkillUp.ShouldShowWatchStatus and SkillUp.ShouldShowWatchStatus() == true) then
        local US = StockPiler.UpgradeSeed
        if not (US and US.ShouldShowWatchStatus and US.ShouldShowWatchStatus() == true) then
            return false
        end
    end
    local list = StockPilerTabWatch and StockPilerTabWatch.listData
    if type(list) ~= "table" or #list == 0 then
        return true
    end
    for i = 1, #list do
        local row = list[i]
        if type(row) == "table" and (row.skillUp == true or row.upgradeWatch == true
            or row.addonOwned == true)
        then
            return false
        end
    end
    return true
end

function Ui.WatchNeedsSkillUpPaint()
    return WatchMissingSkillUpRows()
end

--- Hold Watch paint during harvest storm, refine outstanding, buffer refine,
--- AutoBuy visit, FrameWork prewarm, or session settle.
local function ShouldDeferWatchFlush()
    -- First open / re-show: never leave Watch rows PrimeRowChrome-hidden.
    if OpenPaintActive() then
        return false
    end
    -- SkillUp-only Watch (no potion watches): do not wait on plan/prewarm/settle
    -- or rows stay missing until /stp dumpall or an AutoGrow toggle.
    if WatchMissingSkillUpRows() then
        local SchFast = StockPiler.Scheduler
        if SchFast and SchFast.SkipUiThisFrameActive and SchFast.SkipUiThisFrameActive() == true then
            return true
        end
        if SchFast and SchFast.IsSuppressed and SchFast.IsSuppressed() == true then
            return true
        end
        return false
    end
    local Sch = StockPiler.Scheduler
    if Sch and Sch.SkipUiThisFrameActive and Sch.SkipUiThisFrameActive() == true then
        return true
    end
    if Sch and Sch.IsSessionSettling and Sch.IsSessionSettling() == true then
        return true
    end
    if Sch and Sch.IsSuppressed and Sch.IsSuppressed() == true then
        return true
    end
    if Sch and Sch.IsPlanRebuildPending and Sch.IsPlanRebuildPending() == true then
        return true
    end
    local FW = StockPiler.FrameWork
    if FW and FW.IsPrewarmBusy and FW.IsPrewarmBusy() == true then
        return true
    end
    if FW and FW.Busy and FW.Busy() == true then
        return true
    end
    local RP = StockPiler.RefinePipeline
    if RP and RP.HasOutstanding and RP.HasOutstanding() == true then
        return true
    end
    -- Peek only: HasPendingBufferRefine rebuilds BufferFlags after every snap invalidate.
    local Refine = StockPiler.Refine
    if Refine and Refine.PeekCachedBufferPending and Refine.PeekCachedBufferPending() == true then
        return true
    end
    local Buy = StockPiler.Buy
    if Buy and Buy.ShouldDeferWatchPaint and Buy.ShouldDeferWatchPaint() == true then
        return true
    end
    return false
end

--- FrameWork quiet: harvest storm / plant quiet / same-frame SkipUi.
--- ignoreDefer must not paint WatchRows here (v1.1.3 harvest Flatten).
local function IsFrameWorkQuietHold()
    local Sch = StockPiler.Scheduler
    if not Sch then
        return false
    end
    if Sch.SkipUiThisFrameActive and Sch.SkipUiThisFrameActive() == true then
        return true
    end
    if Sch.IsSuppressed and Sch.IsSuppressed() == true then
        return true
    end
    return false
end

--- Light in-place stock/status paint while Watch is open (no ListBox rebind).
--- Defined after ShouldDeferWatchFlush (Lua local visibility).
--- opts.ignoreDefer skips soft holds only. Quiet hold always returns false.
--- opts.forceRecount / allowBrewHold: post-brew event path (session may stay loaded).
local function TryWatchLiveCatchup(opts)
    opts = type(opts) == "table" and opts or {}
    if not IsWatchTabVisible() then
        return false
    end
    if IsFrameWorkQuietHold() then
        return false
    end
    if opts.ignoreDefer ~= true and ShouldDeferWatchFlush() then
        return false
    end
    local Orch = StockPiler.Orchestrator
    local Brew = StockPiler.Brew
    local brewHold = (Orch and Orch.IsBrewSessionActive and Orch.IsBrewSessionActive() == true)
        or (Brew and Brew.IsWatchUiHold and Brew.IsWatchUiHold() == true)
    if brewHold and opts.allowBrewHold ~= true then
        -- Brew path has its own catch-up / BREW_SESSION_CHANGED handler.
        return false
    end
    local listData = StockPilerTabWatch and StockPilerTabWatch.listData
    if type(listData) ~= "table" or #listData == 0 then
        return false
    end
    local Planner = StockPiler.Planner
    if not (Planner and Planner.LiveRecount) then
        return false
    end
    if opts.forceRecount == true then
        Planner.LiveRecount({
            invalidateStamps = true,
            allowWarmHave = true,
            syncSnapshot = true,
            forceRecountCraftable = true,
        })
    else
        Planner.LiveRecount({
            allowWarmHave = false,
            syncSnapshot = false,
            recountCraftable = false,
        })
    end
    if StockPilerTabWatch.UpdateRows then
        StockPilerTabWatch.UpdateRows({ keepVisible = true })
    end
    return true
end

--- True while FrameWork.Pump will not run (Scheduler skips it for the whole brew).
local function BrewSessionBlocksRecount()
    local Orch = StockPiler.Orchestrator
    return Orch and Orch.IsBrewSessionActive and Orch.IsBrewSessionActive() == true
end

--- Bag snaps keep arriving every ~2s through harvest, refine, and replant.
--- The forced craftable recount (WarmHave + Status.Craftable) waits until that stops.
local function IssueBurstHoldsRecount()
    local Sch = StockPiler.Scheduler
    if not Sch then
        return false
    end
    if Sch.IsSuppressed and Sch.IsSuppressed() == true then
        return true
    end
    if Sch.IsAutoGrowIssueBurstActive and Sch.IsAutoGrowIssueBurstActive() == true then
        return true
    end
    return false
end

--- One forced craftable recount per inventory snapGen (coalesced to end of frame).
--- Mid-brew: do not queue ui-force-watch-recount. Pump skips that job until the
--- session ends, and stamping the snap done before the paint used to drop the
--- post-brew recount.
--- Hidden Watch: keep pending only - do not StartOnce a no-op each snapGen.
local function RequestForcedWatchRecount(_reason)
    local Inv = StockPiler.Inventory
    local snapGen = Inv and Inv.GetSnapGen and tonumber(Inv.GetSnapGen()) or 0
    if BrewSessionBlocksRecount() then
        Ui._forceRecountPendingSnapGen = snapGen
        Ui._forceRecountDeferredDuringBrew = true
        return
    end
    if Ui._forceRecountDeferredDuringBrew == true then
        -- Bags can move during brew without a new snapGen (inventory side
        -- effects suppressed). A stamp from before the brew must not skip this.
        Ui._forceRecountDeferredDuringBrew = false
        Ui._forceRecountDoneSnapGen = nil
    end
    if not IsWatchTabVisible() then
        Ui._forceRecountPendingSnapGen = snapGen
        Ui._forceRecountDeferredWhileHidden = true
        return
    end
    if Ui._forceRecountDeferredWhileHidden == true then
        Ui._forceRecountDeferredWhileHidden = false
        Ui._forceRecountDoneSnapGen = nil
    end
    if IssueBurstHoldsRecount() then
        -- Bag snaps during harvest/refine/replant are ~2s apart (bag coalesce).
        -- Each one used to run sync WarmHave + craftable xN in the quiet gap.
        Ui._forceRecountPendingSnapGen = snapGen
        Ui._forceRecountHeldForBurst = true
        return
    end
    if snapGen > 0 and Ui._forceRecountDoneSnapGen == snapGen then
        return
    end
    Ui._forceRecountPendingSnapGen = snapGen
    local FW = StockPiler.FrameWork
    local genKey = snapGen > 0 and snapGen or ((tonumber(Ui._forceRecountOnceGen) or 0) + 1)
    Ui._forceRecountOnceGen = genKey
    local function run()
        if IssueBurstHoldsRecount() then
            Ui._forceRecountHeldForBurst = true
            return
        end
        local doneSnap = tonumber(Ui._forceRecountPendingSnapGen) or 0
        if doneSnap > 0 and Ui._forceRecountDoneSnapGen == doneSnap then
            return
        end
        local painted = TryWatchLiveCatchup({
            ignoreDefer = true,
            allowBrewHold = true,
            forceRecount = true,
        }) == true
        if painted and doneSnap > 0 then
            Ui._forceRecountDoneSnapGen = doneSnap
        end
    end
    if FW and FW.StartOnce then
        FW.StartOnce("ui-force-watch-recount", genKey, run)
    else
        run()
    end
end

--- One craftable recount after the harvest/refine/replant burst goes idle.
function Ui.FlushBurstHeldWatchRecount()
    if Ui._forceRecountHeldForBurst ~= true then
        return
    end
    if IssueBurstHoldsRecount() then
        return
    end
    Ui._forceRecountHeldForBurst = false
    RequestForcedWatchRecount("burst-idle")
end

--- Watch became paintable (tab select / window open). Flush bag snaps that
--- arrived while the tab was hidden without queuing no-op FrameWork jobs.
function Ui.FlushDeferredWatchRecount()
    if Ui._forceRecountDeferredWhileHidden == true then
        RequestForcedWatchRecount("watch-visible")
    end
end

--- Rebuild Potions/Plants list after a structural knowledge learn.
--- The structure-dirty flag still needs a full refresh after a brew-hold or
--- plan-defer flush. Have-only patching does not clear it.
local function FlushCatalogIfStructureDirty()
    if Ui._catalogStructureDirty ~= true then
        return false
    end
    if not IsCatalogTabVisible() then
        return false
    end
    local selected = StockPilerWindow and StockPilerWindow.SelectedTab
    if selected == StockPilerWindow.TABS_POTIONS
        and StockPilerTabPotions
        and StockPilerTabPotions.Refresh
    then
        StockPilerTabPotions.Refresh()
        Ui._catalogStructureDirty = false
        return true
    end
    if selected == StockPilerWindow.TABS_PLANTS
        and StockPilerTabPlants
        and StockPilerTabPlants.Refresh
    then
        StockPilerTabPlants.Refresh()
        Ui._catalogStructureDirty = false
        return true
    end
    return false
end

--- Potions/Plants Have from L0 CountByUid - does not need Have-warm or plan rebuild.
--- Run even while plan/prewarm defers Watch craftable paint.
local function TryCatalogLiveCatchup()
    if FlushCatalogIfStructureDirty() then
        return true
    end
    if not IsCatalogTabVisible() then
        return false
    end
    local selected = StockPilerWindow and StockPilerWindow.SelectedTab
    if selected == StockPilerWindow.TABS_POTIONS
        and StockPilerTabPotions
        and StockPilerTabPotions.PatchLiveHave
    then
        if StockPilerTabPotions.PatchLiveHave() == true
            and StockPilerTabPotions.UpdateRows
        then
            StockPilerTabPotions.UpdateRows()
        end
        return true
    end
    if selected == StockPilerWindow.TABS_PLANTS
        and StockPilerTabPlants
        and StockPilerTabPlants.PatchLiveHave
    then
        if StockPilerTabPlants.PatchLiveHave() == true
            and StockPilerTabPlants.UpdateRows
        then
            StockPilerTabPlants.UpdateRows()
        end
        return true
    end
    return false
end

--- Catalog tab: never RefreshActiveTab for bag/plan churn (ListBoxSetDisplayOrder
--- {}->order resets Potions/Plants scroll). Structure learns rebuild once; Have patches in place.
local function FlushCatalogTabUi()
    if not IsCatalogTabVisible() then
        return false
    end
    local knowledgeGen = 0
    if StockPiler.Knowledge and StockPiler.Knowledge.GetGen then
        knowledgeGen = tonumber(StockPiler.Knowledge.GetGen()) or 0
    end
    local structureNeeded = Ui._catalogStructureDirty == true
        or knowledgeGen ~= (tonumber(Ui._watchUiLastKnowledgeGen) or 0)
    if structureNeeded then
        Ui._catalogStructureDirty = true
        FlushCatalogIfStructureDirty()
    else
        TryCatalogLiveCatchup()
    end
    local now = 0
    if type(GetGameTime) == "function" then
        now = tonumber(GetGameTime()) or 0
    end
    Ui._watchUiDirty = false
    Ui._watchUiFlushedAt = now
    Ui._watchUiLastKnowledgeGen = knowledgeGen
    Ui._watchUiLastPlanGen = CurrentPlanGen()
    Ui._watchUiLastBrewKey = BrewChromeKey()
    Ui._watchUiLastKey = WatchContentKey()
    if StockPilerWindow and StockPilerWindow.RequestFooterRefresh then
        StockPilerWindow.RequestFooterRefresh()
    end
    return true
end

function Ui.ClearWatchTipCaches()
    if StockPilerTabWatch then
        StockPilerTabWatch._statusTipCache = nil
        StockPilerTabWatch._seedBufferTipCache = nil
    end
end

function Ui.MarkWatchUiDirty()
    Ui._watchUiDirty = true
end

function Ui.RequestFooterRefresh()
    if StockPilerWindow and StockPilerWindow.RequestFooterRefresh then
        StockPilerWindow.RequestFooterRefresh()
    end
end

function Ui.FlushPendingFooterRefresh()
    if StockPilerWindow and StockPilerWindow.FlushPendingFooterRefresh then
        StockPilerWindow.FlushPendingFooterRefresh()
    end
end

--- FOOTER_DIRTY -> footer/macro chrome. payload.immediate syncs readiness now.
local function OnFooterDirty(payload)
    Ui.RequestFooterRefresh()
    if type(payload) ~= "table" or payload.immediate ~= true then
        return
    end
    local Sch = StockPiler.Scheduler
    if Sch then
        if Sch.IsSuppressed and Sch.IsSuppressed() == true then
            return
        end
        if Sch.IsSessionSettling and Sch.IsSessionSettling() == true then
            return
        end
    end
    if StockPilerWindow and StockPilerWindow.SyncActionReadiness then
        StockPilerWindow.SyncActionReadiness({ immediate = true })
    elseif payload.syncMacro == true and StockPiler.Macro
        and StockPiler.Macro.RefreshMacroButtonAppearance
    then
        local Brew = StockPiler.Brew
        local canHarvest = StockPiler.Grow and StockPiler.Grow.CanHarvestNow
            and StockPiler.Grow.CanHarvestNow() == true
        local canBrew = Brew and Brew.CanBrewNow and Brew.CanBrewNow() == true
        StockPiler.Macro.RefreshMacroButtonAppearance({
            canHarvest = canHarvest,
            canBrew = canBrew,
        })
    end
end

--- WATCH_UI_DIRTY -> coalesced Watch flush; payload.immediate paints rows now.
local function OnWatchUiDirty(payload)
    payload = type(payload) == "table" and payload or {}
    Ui.MarkWatchUiDirty()
    if payload.immediate ~= true then
        return
    end
    if StockPilerTabWatch and StockPilerTabWatch.InvalidateBrewChrome then
        StockPilerTabWatch.InvalidateBrewChrome()
    end
    if payload.recount == true or payload.forceRecount == true then
        RequestForcedWatchRecount(payload.reason or "watch-ui-dirty")
    else
        TryWatchLiveCatchup({
            ignoreDefer = true,
            allowBrewHold = true,
            forceRecount = false,
        })
    end
    TryCatalogLiveCatchup()
end

--- BREW_SESSION_CHANGED -> row Brew chrome + live counts without waiting on coalesce.
local function OnBrewSessionChanged(payload)
    payload = type(payload) == "table" and payload or {}
    Ui.MarkWatchUiDirty()
    Ui._watchUiLastBrewKey = nil
    if StockPilerTabWatch and StockPilerTabWatch.InvalidateBrewChrome then
        StockPilerTabWatch.InvalidateBrewChrome()
    end
    local wantsRecount = payload.recount == true or payload.forceRecount == true
    if Ui._forceRecountDeferredDuringBrew == true and not BrewSessionBlocksRecount() then
        wantsRecount = true
    end
    if wantsRecount then
        RequestForcedWatchRecount(payload.reason or "brew-session")
    elseif DoesWindowExist("StockPilerWindow")
        and WindowGetShowing("StockPilerWindow") == true
        and StockPilerTabWatch
        and StockPilerTabWatch.UpdateRows
    then
        StockPilerTabWatch.UpdateRows({ keepVisible = true })
    end
    OnFooterDirty({ immediate = true, syncMacro = true })
end

function Ui.InvalidateSkillGates()
    if StockPilerTabWatch then
        StockPilerTabWatch._skillGatesKey = nil
        if StockPilerTabWatch.RefreshSkillGates then
            StockPilerTabWatch.RefreshSkillGates()
        end
    end
end

function Ui.RefreshCatalogRows()
    -- Patch Have from L0 first; UpdateRows alone left stale stock after bag moves.
    if StockPilerTabPotions and StockPilerTabPotions.PatchLiveHave then
        StockPilerTabPotions.PatchLiveHave()
    end
    if StockPilerTabPotions and StockPilerTabPotions.UpdateRows then
        StockPilerTabPotions.UpdateRows()
    end
    if StockPilerTabPlants and StockPilerTabPlants.PatchLiveHave then
        StockPilerTabPlants.PatchLiveHave()
    end
    if StockPilerTabPlants and StockPilerTabPlants.UpdateRows then
        StockPilerTabPlants.UpdateRows()
    end
end

function Ui.FlushWatchUiIfDirty()
    if Ui._watchUiDirty ~= true then
        return
    end
    local windowOpen = DoesWindowExist("StockPilerWindow")
        and WindowGetShowing("StockPilerWindow") == true
    -- Ready wake must run even while AutoBuy visit defers full Watch paint
    -- (flask fills clear Shared/Buy-flasks without a potion craftable delta).
    local function WakeReadyFromLiveStatus()
        if StockPiler.Planner and StockPiler.Planner.SyncLiveStatusClosedWindow then
            StockPiler.Planner.SyncLiveStatusClosedWindow()
        elseif StockPiler.Brew and StockPiler.Brew.SyncLiveStatusClosedWindow then
            StockPiler.Brew.SyncLiveStatusClosedWindow()
        end
        if StockPiler.Brew and StockPiler.Brew.MaybeNotifyBrewReady then
            StockPiler.Brew.MaybeNotifyBrewReady()
        end
    end
    if not windowOpen then
        WakeReadyFromLiveStatus()
        -- Closed window: both defer outcomes used to return immediately.
        -- Keep the ready wake and leave dirty set for the next open.
        return
    end
    -- Bag snaps while on Potions/Plants (or while closed) only set pending;
    -- recount now that Watch can paint.
    if IsWatchTabVisible() then
        Ui.FlushDeferredWatchRecount()
    end
    if ShouldDeferWatchFlush() then
        WakeReadyFromLiveStatus()
        -- While settle/prewarm holds full paint, kill the white ListBox flash.
        if StockPilerTabWatch and StockPilerTabWatch.PrimeRowChrome then
            StockPilerTabWatch.PrimeRowChrome()
        end
        -- Plan coalesce holds RefreshActiveTab, but Load chips must grey as soon as
        -- bag snap advances past row._craftableSnapGen (ApplyRowBrewButton).
        local Sch = StockPiler.Scheduler
        local planPending = Sch and Sch.IsPlanRebuildPending and Sch.IsPlanRebuildPending() == true
        local hardHold = (Sch and Sch.SkipUiThisFrameActive and Sch.SkipUiThisFrameActive() == true)
            or (Sch and Sch.IsSuppressed and Sch.IsSuppressed() == true)
            or (Sch and Sch.IsSessionSettling and Sch.IsSessionSettling() == true)
        if planPending and not hardHold and IsWatchTabVisible()
            and StockPilerTabWatch and StockPilerTabWatch.UpdateRows
        then
            StockPilerTabWatch.UpdateRows({ keepVisible = true })
        end
        -- Catalog Have is L0-only; do not wait for Have-warm / plan like Watch craftable.
        -- Consume dirty on catalog so a later defer-end does not RefreshActiveTab
        -- (empty->full ListBoxSetDisplayOrder) and yank Potions scroll to the top.
        if IsCatalogTabVisible() then
            FlushCatalogTabUi()
            return true
        end
        TryCatalogLiveCatchup()
        -- Do not LiveRecount/UpdateRows during harvest/plant quiet. ignoreDefer
        -- here stacked WatchRows on every bag dirty (libperf WatchRows xN).
        return
    end

    local Orch = StockPiler.Orchestrator
    local Brew = StockPiler.Brew
    local brewSessionActive = (Orch and Orch.IsBrewSessionActive and Orch.IsBrewSessionActive() == true)
        or (Brew and Brew.IsWatchUiHold and Brew.IsWatchUiHold() == true)
    -- Mid-brew / inter-craft hold: hold full RefreshWatch; chrome via ForceBrewUiRefresh;
    -- ~1s Stock/Status catch-up. Rebind listData only when the ListBox is empty
    -- (stuck session / scenario load). planGen bumps every brew cycle otherwise
    -- caused SkillUp / watch row flicker/disappear via ListBoxSetDisplayOrder.
    if brewSessionActive then
        -- Manual/apo learn can land during Watch brew-hold; still rebuild Potions.
        if IsCatalogTabVisible() then
            FlushCatalogTabUi()
            return true
        end
        FlushCatalogIfStructureDirty()
        local listData = StockPilerTabWatch and StockPilerTabWatch.listData
        local listEmpty = type(listData) ~= "table" or #listData == 0
        local planGen = CurrentPlanGen()
        local planChanged = planGen ~= (tonumber(Ui._watchUiLastPlanGen) or 0)
        if planChanged then
            Ui._watchUiLastPlanGen = planGen
            -- Never ListBoxSetDisplayOrder mid-brew (hides all rows). Empty list only.
            if listEmpty and StockPilerTabWatch and StockPilerTabWatch.Refresh then
                StockPilerTabWatch.Refresh({ forcePlan = false, brewHold = true })
            elseif StockPilerTabWatch and StockPilerTabWatch.UpdateRows then
                StockPilerTabWatch.UpdateRows({ keepVisible = true })
            end
            -- Consume dirty during AutoBrew continuum; next plan.updated re-marks.
            -- Leaving dirty true forced a full RefreshActiveTab the instant hold
            -- dropped and cleared the Watch list between crafts.
            Ui._watchUiDirty = false
            return
        end
        local brewKey = BrewChromeKey()
        local brewChanged = brewKey ~= tostring(Ui._watchUiLastBrewKey or "")
        local now = 0
        if type(GetGameTime) == "function" then
            now = tonumber(GetGameTime()) or 0
        end
        if brewChanged then
            Ui._watchUiLastBrewKey = brewKey
            if StockPilerTabWatch and StockPilerTabWatch.InvalidateBrewChrome then
                StockPilerTabWatch.InvalidateBrewChrome()
            end
            if StockPilerTabWatch and StockPilerTabWatch.UpdateRows then
                StockPilerTabWatch.UpdateRows({ keepVisible = true })
            end
            Ui._watchUiDirty = false
            return
        end
        local catchupSec = tonumber(Ui.BREW_WATCH_CATCHUP_SEC) or 1.0
        local lastCatchup = tonumber(Ui._watchUiBrewCatchupAt) or 0
        if lastCatchup > 0 and (now - lastCatchup) < catchupSec then
            return
        end
        Ui._watchUiBrewCatchupAt = now
        listData = StockPilerTabWatch and StockPilerTabWatch.listData
        listEmpty = type(listData) ~= "table" or #listData == 0
        local snap = StockPiler.PlanSnapshot and StockPiler.PlanSnapshot.Get
            and StockPiler.PlanSnapshot.Get()
        local planRows = type(snap) == "table" and snap.rows or nil
        -- listData is a sorted copy of plan.rows; compare bound plan identity, not listData.
        local boundPlanRows = StockPilerTabWatch and StockPilerTabWatch._boundPlanRows
        if type(planRows) == "table" and planRows ~= boundPlanRows then
            if listEmpty and StockPilerTabWatch and StockPilerTabWatch.Refresh then
                StockPilerTabWatch.Refresh({ forcePlan = false, brewHold = true })
            elseif type(planRows) == "table" and #planRows > 0 and StockPilerTabWatch then
                -- Rebind sorted copy (never assign unsorted plan.rows as listData).
                if StockPilerTabWatch.BindSortedList then
                    StockPilerTabWatch.BindSortedList(planRows)
                else
                    StockPilerTabWatch.listData = planRows
                    StockPilerTabWatch._boundPlanRows = planRows
                end
                if StockPilerTabWatch.UpdateRows then
                    StockPilerTabWatch.UpdateRows({ keepVisible = true })
                end
            end
            Ui._watchUiDirty = false
            return
        end
        if type(listData) == "table"
            and #listData > 0
            and StockPiler.Planner
            and StockPiler.Planner.LiveRecount
        then
            if StockPiler.Perf and StockPiler.Perf.Begin then
                StockPiler.Perf.Begin("UiFlush.BrewCatchup")
            end
            -- Post-brew / bag snap while session stays loaded: recount craftable too
            -- (manual Brew used to leave Craftable stuck until hold expired).
            StockPiler.Planner.LiveRecount({
                invalidateStamps = true,
                allowWarmHave = true,
                syncSnapshot = true,
                forceRecountCraftable = true,
            })
            if StockPilerTabWatch.UpdateRows then
                StockPilerTabWatch.UpdateRows({ keepVisible = true })
            end
            if StockPiler.Perf and StockPiler.Perf.End then
                StockPiler.Perf.End("UiFlush.BrewCatchup")
            end
        end
        Ui._watchUiDirty = false
        return
    end

    -- Potions/Plants selected: Have/structure only - never RefreshActiveTab (scroll jump).
    if FlushCatalogTabUi() then
        return true
    end

    -- Brew hold just dropped (or never held): one ListBox rebind if indices empty.
    if StockPilerTabWatch and StockPilerTabWatch.FlushPendingListRebind then
        StockPilerTabWatch.FlushPendingListRebind()
    end

    local knowledgeGen = 0
    if StockPiler.Knowledge and StockPiler.Knowledge.GetGen then
        knowledgeGen = tonumber(StockPiler.Knowledge.GetGen()) or 0
    end
    local planGen = CurrentPlanGen()
    local brewKey = BrewChromeKey()
    local contentKey = WatchContentKey()
    local planChanged = planGen ~= (tonumber(Ui._watchUiLastPlanGen) or 0)
    local knowledgeChanged = knowledgeGen ~= (tonumber(Ui._watchUiLastKnowledgeGen) or 0)
        or Ui._catalogStructureDirty == true
    local openPaint = OpenPaintActive()
    -- Plan/knowledge can change without stock/craftable deltas; never skip those.
    if not openPaint and Ui._watchUiLastKey == contentKey and not planChanged and not knowledgeChanged then
        if WatchMissingSkillUpRows() then
            -- SkillUp rows never made it into listData; Flatten again.
        else
            Ui._watchUiDirty = false
            return
        end
    end
    local now = 0
    if type(GetGameTime) == "function" then
        now = tonumber(GetGameTime()) or 0
    end
    local last = tonumber(Ui._watchUiFlushedAt) or 0
    local brewChanged = brewKey ~= tostring(Ui._watchUiLastBrewKey or "")
    local interval = Ui.WATCH_UI_MIN_INTERVAL_SEC
    if IsAnyTabVisible() then
        interval = tonumber(Ui.WATCH_UI_OPEN_INTERVAL_SEC) or 0.5
    end
    if not knowledgeChanged and not planChanged and not brewChanged and IsWatchPlanStale() then
        interval = math.min(interval, 1.0)
    end
    if not openPaint
        and not knowledgeChanged
        and not planChanged
        and not brewChanged
        and last > 0
        and (now - last) < interval
    then
        return
    end

    if StockPiler.Perf and StockPiler.Perf.Begin then
        StockPiler.Perf.Begin("UiFlush")
    end
    Ui._watchUiDirty = false
    Ui._watchUiFlushedAt = now
    Ui._watchUiBrewCatchupAt = 0
    Ui._watchUiLastKey = contentKey
    Ui._watchUiLastKnowledgeGen = knowledgeGen
    Ui._watchUiLastPlanGen = planGen
    Ui._watchUiLastBrewKey = brewKey
    if StockPilerWindow and StockPilerWindow.RefreshActiveTab then
        StockPilerWindow.RefreshActiveTab()
    end
    if OpenPaintActive() then
        local watchVisible = IsWatchTabVisible()
        local listCount = 0
        if StockPilerTabWatch and type(StockPilerTabWatch.listData) == "table" then
            listCount = #StockPilerTabWatch.listData
        end
        local populated = false
        if SPTabWatchList and type(SPTabWatchList.PopulatorIndices) == "table"
            and next(SPTabWatchList.PopulatorIndices) ~= nil
        then
            populated = true
        end
        if (not watchVisible) or populated then
            StockPilerWindow._openPaintPending = false
        else
            if listCount > 0 and StockPilerTabWatch and DoesWindowExist("SPTabWatchList") then
                local order = StockPilerTabWatch.displayOrder
                if type(order) == "table" and #order > 0 then
                    ListBoxSetDisplayOrder("SPTabWatchList", order)
                end
            end
            Ui._watchUiDirty = true
        end
    end
    if StockPiler.Perf and StockPiler.Perf.End then
        StockPiler.Perf.End("UiFlush")
    end
    return true
end

function Ui.InitializeWindow()
    if StockPilerWindow and StockPilerWindow.Initialize then
        StockPilerWindow.Initialize()
    end
end

function Ui.RegisterEventRefresh()
    if Ui._eventsRegistered == true then
        return
    end
    local B = StockPiler.EventBus
    local E = StockPiler.Events
    if not B or not E then
        return
    end
    Ui._busTokens = Ui._busTokens or {}
    local tokens = Ui._busTokens
    local function track(token)
        if token then
            tokens[#tokens + 1] = token
        end
    end
    local function markDirty()
        Ui.MarkWatchUiDirty()
    end
    track(B.Subscribe(E.PLAN_UPDATED, function()
        Ui.ClearWatchTipCaches()
        Ui.MarkWatchUiDirty()
        Ui.RequestFooterRefresh()
    end))
    track(B.Subscribe(E.PLAN_INVALIDATED, markDirty))
    track(B.Subscribe(E.INVENTORY_SNAPSHOT, function()
        Ui.MarkWatchUiDirty()
        -- Stock/status paints now. Craftable is one WarmHave per snapGen, not
        -- a sync walk on every brew slot event: mid-brew snaps only set the
        -- defer flag (Pump will not run the job until the session is idle).
        RequestForcedWatchRecount("inventory-snapshot")
        TryWatchLiveCatchup({ forceRecount = false })
        TryCatalogLiveCatchup()
    end))
    if E.INVENTORY_DIRTY then
        track(B.Subscribe(E.INVENTORY_DIRTY, markDirty))
    end
    track(B.Subscribe(E.GARDEN_SNAPSHOT, markDirty))
    if E.GARDEN_DIRTY then
        track(B.Subscribe(E.GARDEN_DIRTY, markDirty))
    end
    if E.PHASE_CHANGED then
        track(B.Subscribe(E.PHASE_CHANGED, function()
            Ui.InvalidateSkillGates()
            markDirty()
            Ui.RequestFooterRefresh()
        end))
    end
    if E.REFINE_OUTSTANDING then
        track(B.Subscribe(E.REFINE_OUTSTANDING, markDirty))
    end
    if E.VENDOR_UPDATED then
        track(B.Subscribe(E.VENDOR_UPDATED, function()
            markDirty()
            Ui.RequestFooterRefresh()
        end))
    end
    if E.CRAFT_READY_CHANGED then
        track(B.Subscribe(E.CRAFT_READY_CHANGED, function()
            Ui.RequestFooterRefresh()
            -- Defer recount so we do not re-enter PatchWatchRowsLiveCounts mid-call.
            RequestForcedWatchRecount("craft-ready")
            Ui.MarkWatchUiDirty()
        end))
    end
    if E.FOOTER_DIRTY then
        track(B.Subscribe(E.FOOTER_DIRTY, OnFooterDirty))
    end
    if E.WATCH_UI_DIRTY then
        track(B.Subscribe(E.WATCH_UI_DIRTY, OnWatchUiDirty))
    end
    if E.BREW_SESSION_CHANGED then
        track(B.Subscribe(E.BREW_SESSION_CHANGED, OnBrewSessionChanged))
    end
    if E.KNOWLEDGE_UPDATED then
        track(B.Subscribe(E.KNOWLEDGE_UPDATED, function()
            -- Knowledge can land after an inventory flush already painted Potions.
            -- Bypass Watch throttle for the next coalesced flush - never sync paint
            -- (WarmHave used to hide inside WatchRows on the same frame as CultivationUpdated).
            -- Structural learn needs a full catalog list rebuild, not PatchLiveHave.
            Ui._catalogStructureDirty = true
            Ui.BypassWatchThrottle()
            Ui._watchUiLastKnowledgeGen = 0
            Ui.MarkWatchUiDirty()
            -- Show newly learned potions while the catalog tab is open (no tab flip).
            if IsCatalogTabVisible() then
                FlushCatalogIfStructureDirty()
            end
        end))
    end
    if E.SESSION_LOADED then
        track(B.Subscribe(E.SESSION_LOADED, function()
            if StockPilerTabWatch and StockPilerTabWatch.RefreshSkillGates then
                StockPilerTabWatch.RefreshSkillGates()
            end
            -- Session load: mark dirty only. Sync RefreshActiveTab here caused the
            -- SP2 Flatten hitch (Planner.Build + WarmHave + WatchRows + CultivationUpdated
            -- x4 on the same frame as Garden.SyncAll / first plan rebuild).
            Ui.BypassWatchThrottle()
            Ui._watchUiLastBrewKey = nil
            Ui._watchUiLastPlanGen = 0
            Ui._watchUiLastKnowledgeGen = 0
            Ui.ClearWatchTipCaches()
            Ui.MarkWatchUiDirty()
        end))
    end
    Ui._eventsRegistered = true
end

function Ui.UnregisterEventRefresh()
    local B = StockPiler.EventBus
    local tokens = Ui._busTokens
    if B and B.Unsubscribe and type(tokens) == "table" then
        for i = 1, #tokens do
            B.Unsubscribe(tokens[i])
        end
    end
    Ui._busTokens = nil
    Ui._eventsRegistered = false
end
