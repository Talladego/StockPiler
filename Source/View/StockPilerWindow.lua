----------------------------------------------------------------
-- StockPilerWindow -- settings-style chrome
----------------------------------------------------------------

StockPilerWindow = {}

local function T(key, tokens)
    return StockPiler.Util.T(key, tokens)
end

StockPilerWindow.TABS_POTIONS = 1
StockPilerWindow.TABS_PLANTS = 2
StockPilerWindow.TABS_WATCH = 3
StockPilerWindow.TABS_MAX = 3
StockPilerWindow.SelectedTab = StockPilerWindow.TABS_POTIONS

local CLEAR_WATCHES_WIN = "StockPilerWindowClearWatches"
local HARVEST_WIN = "StockPilerWindowHarvest"
local BREW_WIN = "StockPilerWindowBrew"

StockPilerWindow.Tabs = {
    [1] = {
        window = "SPTabPotions",
        name = "StockPilerWindowTabButtonsPotions",
        labelKey = "ui.tab_potions",
        refresh = function()
            if StockPilerTabPotions and StockPilerTabPotions.Refresh then
                StockPilerTabPotions.Refresh()
            end
        end,
    },
    [2] = {
        window = "SPTabPlants",
        name = "StockPilerWindowTabButtonsPlants",
        labelKey = "ui.tab_plants",
        refresh = function()
            if StockPilerTabPlants and StockPilerTabPlants.Refresh then
                StockPilerTabPlants.Refresh()
            end
        end,
    },
    [3] = {
        window = "SPTabWatch",
        name = "StockPilerWindowTabButtonsWatch",
        labelKey = "ui.tab_watch",
        refresh = function()
            if StockPilerTabWatch and StockPilerTabWatch.Refresh then
                StockPilerTabWatch.Refresh()
            end
        end,
    },
}

function StockPilerWindow.OnInitialize()
    local selected = StockPilerWindow.SelectedTab or StockPilerWindow.TABS_POTIONS
    for index, tab in ipairs(StockPilerWindow.Tabs) do
        if DoesWindowExist(tab.window) then
            WindowSetShowing(tab.window, index == selected)
        end
        if DoesWindowExist(tab.name) then
            ButtonSetPressedFlag(tab.name, index == selected)
        end
    end
end

function StockPilerWindow.RequestFooterRefresh()
    StockPilerWindow._footerRefreshPending = true
end

--- Sync Harvest/Brew readiness: macros always; footer chrome only when window is open.
--- At most one full Footer/Macro paint per FrameCounter. A later same-frame readiness
--- change queues one deferred flush. A tab change paints on this call: the flush can
--- be held for harvest or refine, and committing the new tab before the windows
--- update made the flush look unchanged, leaving Harvest/Brew up on Potions.
function StockPilerWindow.SyncActionReadiness(opts)
    opts = type(opts) == "table" and opts or {}
    local immediate = opts.immediate == true
    local Perf = StockPiler.Perf
    local frame = tonumber(StockPiler.FrameCounter) or 0

    local windowOpen = DoesWindowExist("StockPilerWindow")
        and WindowGetShowing("StockPilerWindow") == true
    local onWatch = StockPilerWindow.SelectedTab == StockPilerWindow.TABS_WATCH
    local onPotions = StockPilerWindow.SelectedTab == StockPilerWindow.TABS_POTIONS
    local onPlants = StockPilerWindow.SelectedTab == StockPilerWindow.TABS_PLANTS
    local showClearWatches = onPotions or onPlants

    local canHarvest = StockPiler.Grow and StockPiler.Grow.CanHarvestNow
        and StockPiler.Grow.CanHarvestNow() == true
    local canBrew = StockPiler.Brew and StockPiler.Brew.CanBrewNow
        and StockPiler.Brew.CanBrewNow() == true
    -- Same booleans that light the footer and macros, including coalesce
    -- returns, so a deferred paint cannot skip the ready chime.
    if StockPiler.Grow and StockPiler.Grow.AnnounceHarvestEnabled then
        StockPiler.Grow.AnnounceHarvestEnabled(canHarvest)
    end
    if StockPiler.Brew and StockPiler.Brew.AnnounceBrewEnabled then
        StockPiler.Brew.AnnounceBrewEnabled(canBrew)
    end
    local enabledWatches = 0
    if onPlants then
        if StockPiler.Watch and StockPiler.Watch.CountEnabledPlantWatches then
            enabledWatches = tonumber(StockPiler.Watch.CountEnabledPlantWatches()) or 0
        end
    elseif StockPiler.Watch and StockPiler.Watch.CountEnabled then
        enabledWatches = tonumber(StockPiler.Watch.CountEnabled()) or 0
    end
    local canClearWatches = enabledWatches > 0

    -- Same-frame coalesce: first call paints; later calls only re-queue if inputs moved.
    -- Do not write the painted-state cache here. A deferred flush re-enters this
    -- function, and a cache already equal to the new tab/readiness takes the
    -- unchanged return below without ever calling WindowSetShowing.
    -- Exception: immediate, or a tab change, re-paints now (open-fail / op-lock
    -- greying was deferred into plant quiet and left macros lit while clicks no-op).
    if StockPilerWindow._footerSyncFrame == frame and frame > 0 then
        local prevH = StockPilerWindow._footerCanHarvest
        local prevB = StockPilerWindow._footerCanBrew
        local prevClear = StockPilerWindow._footerCanClearWatches
        local prevOnWatch = StockPilerWindow._footerOnWatch
        local prevOnPotions = StockPilerWindow._footerOnPotions
        local prevOnPlants = StockPilerWindow._footerOnPlants
        local tabMoved = prevOnWatch ~= onWatch
            or prevOnPotions ~= onPotions
            or prevOnPlants ~= onPlants
        local moved = tabMoved
            or prevH ~= canHarvest
            or prevB ~= canBrew
            or prevClear ~= canClearWatches
        if moved and (immediate or tabMoved) then
            StockPilerWindow._footerSyncFrame = nil
            -- Fall through to full paint with latest readiness.
        else
            if moved then
                StockPilerWindow._footerRefreshPending = true
                StockPilerWindow._footerSyncAllowDeferred = true
            end
            return canHarvest, canBrew
        end
    end

    local appearanceKey = tostring(canHarvest) .. ":" .. tostring(canBrew)
    local unchanged = StockPilerWindow._footerWindowOpen == windowOpen
        and StockPilerWindow._footerOnWatch == onWatch
        and StockPilerWindow._footerOnPotions == onPotions
        and StockPilerWindow._footerOnPlants == onPlants
        and StockPilerWindow._footerCanHarvest == canHarvest
        and StockPilerWindow._footerCanBrew == canBrew
        and StockPilerWindow._footerCanClearWatches == canClearWatches
    -- `immediate` must re-apply macro tint: ActionButton.UpdateEnabledState greys
    -- our macros mid-craft while CanBrewNow can stay true, so appearanceKey is unchanged.
    local craftWaiting = StockPiler.Macro and StockPiler.Macro._craftUnpainted == true
    if unchanged and not immediate and not craftWaiting then
        local macroKey = StockPiler.Macro and StockPiler.Macro.GetReadinessKey
            and StockPiler.Macro.GetReadinessKey()
        if StockPiler.Macro == nil
            or macroKey == nil
            or macroKey == appearanceKey
        then
            StockPilerWindow._footerSyncFrame = frame
            return canHarvest, canBrew
        end
    end

    if Perf and Perf.Begin then
        Perf.Begin("Footer")
    end

    if windowOpen then
        if DoesWindowExist(CLEAR_WATCHES_WIN) then
            WindowSetShowing(CLEAR_WATCHES_WIN, showClearWatches)
            if showClearWatches and ButtonSetDisabledFlag then
                ButtonSetDisabledFlag(CLEAR_WATCHES_WIN, not canClearWatches)
            end
        end
        if DoesWindowExist(HARVEST_WIN) then
            WindowSetShowing(HARVEST_WIN, onWatch)
            if onWatch then
                if StockPiler.HarvestChrome and StockPiler.HarvestChrome.SetFooterHarvestClickable then
                    StockPiler.HarvestChrome.SetFooterHarvestClickable(canHarvest)
                else
                    ButtonSetDisabledFlag(HARVEST_WIN, not canHarvest)
                end
            elseif StockPiler.HarvestChrome and StockPiler.HarvestChrome.ClearHarvestActionBound then
                StockPiler.HarvestChrome.ClearHarvestActionBound()
            end
        end
        if DoesWindowExist(BREW_WIN) then
            WindowSetShowing(BREW_WIN, onWatch)
            if onWatch then
                ButtonSetDisabledFlag(BREW_WIN, not canBrew)
            end
        end
    end

    local prevOnWatch = StockPilerWindow._footerOnWatch
    local prevOnPotions = StockPilerWindow._footerOnPotions
    local prevOnPlants = StockPilerWindow._footerOnPlants
    local prevHarvest = StockPilerWindow._footerCanHarvest
    local prevBrew = StockPilerWindow._footerCanBrew
    local prevClear = StockPilerWindow._footerCanClearWatches
    StockPilerWindow._footerWindowOpen = windowOpen
    StockPilerWindow._footerOnWatch = onWatch
    StockPilerWindow._footerOnPotions = onPotions
    StockPilerWindow._footerOnPlants = onPlants
    StockPilerWindow._footerCanHarvest = canHarvest
    StockPilerWindow._footerCanBrew = canBrew
    StockPilerWindow._footerCanClearWatches = canClearWatches
    local readinessChanged = prevOnWatch ~= onWatch
        or prevOnPotions ~= onPotions
        or prevOnPlants ~= onPlants
        or prevHarvest ~= canHarvest
        or prevBrew ~= canBrew
        or prevClear ~= canClearWatches

    if not readinessChanged and StockPiler.Macro then
        local skipDrift = false
        if StockPiler.Brew then
            if StockPiler.Brew.IsBusy and StockPiler.Brew.IsBusy() == true then
                skipDrift = true
            else
                local session = StockPiler.Brew.GetSession and StockPiler.Brew.GetSession()
                if type(session) == "table" and session.phase == "loading" then
                    skipDrift = true
                end
            end
        end
        if not skipDrift then
            local macroKey = StockPiler.Macro.GetReadinessKey
                and StockPiler.Macro.GetReadinessKey()
            if macroKey ~= nil and macroKey ~= appearanceKey then
                readinessChanged = true
            end
        end
    end

    if StockPiler.Macro and StockPiler.Macro._craftUnpainted == true then
        readinessChanged = true
    end

    if readinessChanged or immediate then
        if StockPiler.Macro then
            if immediate and StockPiler.Macro.RefreshMacroButtonAppearance then
                if StockPiler.Macro.CancelPendingEnabledSync then
                    StockPiler.Macro.CancelPendingEnabledSync()
                end
                StockPiler.Macro.RefreshMacroButtonAppearance({
                    canHarvest = canHarvest,
                    canBrew = canBrew,
                })
            elseif StockPiler.Macro.RequestEnabledSync then
                StockPiler.Macro.RequestEnabledSync(canHarvest, canBrew)
            elseif StockPiler.Macro.SyncEnabledState then
                StockPiler.Macro.SyncEnabledState(canHarvest, canBrew)
            end
        end
        -- Next frame: hotbar / MACRO_UPDATED echoes relight Craft after the
        -- footer Harvest or Brew button has already changed.
        if (prevHarvest ~= canHarvest or prevBrew ~= canBrew)
            and StockPiler.Macro
            and StockPiler.Macro.ArmEnableReassert
        then
            StockPiler.Macro.ArmEnableReassert()
        end
    end

    StockPilerWindow._footerSyncFrame = frame
    StockPilerWindow._footerSyncAllowDeferred = false

    if Perf and Perf.End then
        Perf.End("Footer")
    end
    return canHarvest, canBrew
end

function StockPilerWindow.FlushPendingFooterRefresh()
    if StockPilerWindow._footerRefreshPending ~= true then
        return
    end
    local Sch = StockPiler.Scheduler
    if Sch and Sch.SkipUiHoldFooter and Sch.SkipUiHoldFooter() == true
        and StockPilerWindow._openPaintPending ~= true
    then
        return
    end
    -- Same-frame: skip flush after an immediate Sync unless readiness inputs moved.
    local frame = tonumber(StockPiler.FrameCounter) or 0
    if StockPilerWindow._footerSyncFrame == frame and frame > 0
        and StockPilerWindow._footerSyncAllowDeferred ~= true
    then
        StockPilerWindow._footerRefreshPending = false
        return
    end
    local RP = StockPiler.RefinePipeline
    if RP and RP.HasOutstanding and RP.HasOutstanding() == true then
        return
    end
    local brewJob = StockPiler.Brew and StockPiler.Brew.IsLoadJobActive
        and StockPiler.Brew.IsLoadJobActive() == true
    if not brewJob then
        if Sch and Sch.IsSuppressed and Sch.IsSuppressed() == true then
            return
        end
    end
    StockPilerWindow._footerRefreshPending = false
    StockPilerWindow._footerSyncAllowDeferred = false
    -- Reset frame latch so deferred flush can paint once with latest inputs.
    StockPilerWindow._footerSyncFrame = nil
    StockPilerWindow.SyncActionReadiness()
    if StockPiler.HarvestTooltip and StockPiler.HarvestTooltip.TickLive then
        StockPiler.HarvestTooltip.TickLive()
    end
    if StockPiler.BrewTooltip and StockPiler.BrewTooltip.TickLive then
        StockPiler.BrewTooltip.TickLive()
    end
    if StockPiler.CraftTooltip and StockPiler.CraftTooltip.TickLive then
        StockPiler.CraftTooltip.TickLive()
    end
end

function StockPilerWindow.RefreshFooterButtons()
    StockPilerWindow.RequestFooterRefresh()
end

function StockPilerWindow.Initialize()
    if not DoesWindowExist("StockPilerWindow") then
        return
    end
    local version = StockPiler.Version or L""
    if version ~= L"" then
        LabelSetText("StockPilerWindowTitleBarText", T("ui.title_version", { version = version }))
    else
        LabelSetText("StockPilerWindowTitleBarText", T("ui.title"))
    end
    if DoesWindowExist(CLEAR_WATCHES_WIN) then
        ButtonSetText(CLEAR_WATCHES_WIN, T("ui.clear_watches"))
        WindowSetShowing(CLEAR_WATCHES_WIN, false)
    end
    if DoesWindowExist(HARVEST_WIN) then
        ButtonSetText(HARVEST_WIN, T("ui.harvest"))
        WindowSetShowing(HARVEST_WIN, false)
        if StockPiler.HarvestChrome and StockPiler.HarvestChrome.EnsureHarvestActionBound then
            StockPiler.HarvestChrome.EnsureHarvestActionBound()
        end
    end
    if DoesWindowExist("StockPilerWindowHarvestAction") then
        WindowSetShowing("StockPilerWindowHarvestAction", false)
    end
    if DoesWindowExist(BREW_WIN) then
        ButtonSetText(BREW_WIN, T("ui.brew"))
        WindowSetShowing(BREW_WIN, false)
    end
    for _, tab in ipairs(StockPilerWindow.Tabs) do
        ButtonSetText(tab.name, T(tab.labelKey))
    end
    -- Defer Watch paint: sync SelectTab->RefreshActiveTab Flattened with WarmHave
    -- inside PatchWatchRowsLiveCounts on the same frame as CultivationUpdated x4.
    StockPilerWindow.SelectTab(StockPilerWindow.SelectedTab, { deferRefresh = true })
    -- Reload with the window already open restores showing=true (savesettings)
    -- without a later /stp OnShown. Arm the same Watch ListBox bind either way.
    StockPilerWindow.BeginOpenPaint()
end

function StockPilerWindow.RefreshActiveTab(caller)
    caller = tostring(caller or "unknown")
    if StockPiler.Perf and StockPiler.Perf.Tally then
        StockPiler.Perf.Tally("refreshTab", caller)
    end
    if StockPiler.Perf and StockPiler.Perf.Begin then
        StockPiler.Perf.Begin("RefreshWatch")
    end
    if StockPiler.Perf and StockPiler.Perf.Mark then
        StockPiler.Perf.Mark("RefreshWatch." .. caller)
    end
    local tab = StockPilerWindow.Tabs[StockPilerWindow.SelectedTab]
    if tab and tab.refresh then
        tab.refresh()
    end
    StockPilerWindow.RefreshFooterButtons()
    if StockPiler.Perf and StockPiler.Perf.End then
        StockPiler.Perf.End("RefreshWatch")
    end
end

function StockPilerWindow.RequestListRepopulate()
    StockPilerWindow._repopulatePending = true
end

function StockPilerWindow.FlushPendingListRepopulate()
    if StockPilerWindow._repopulatePending ~= true then
        return
    end
    if not DoesWindowExist("StockPilerWindow") then
        return
    end
    if WindowGetShowing("StockPilerWindow") ~= true then
        return
    end
    if StockPilerWindow._openPaintPending == true
        and StockPilerWindow.SelectedTab == StockPilerWindow.TABS_WATCH
    then
        return
    end
    StockPilerWindow._repopulatePending = false
    -- First-open / tab-show must bind ListBox now. Remarking dirty left Watch empty
    -- until a later flush that settle/prewarm often skipped.
    StockPilerWindow.RefreshActiveTab("list-repop")
end

--- Show only SelectedTab's child; hide the others. Recovers stacked tab chrome
--- after KickListBoxLayout / forceRebind accidentally showed Watch over Potions.
function StockPilerWindow.EnsureSelectedTabShowing()
    if not DoesWindowExist("StockPilerWindow") then
        return
    end
    local selected = StockPilerWindow.SelectedTab or StockPilerWindow.TABS_POTIONS
    for index, tab in ipairs(StockPilerWindow.Tabs) do
        if DoesWindowExist(tab.name) then
            ButtonSetPressedFlag(tab.name, index == selected)
        end
        if DoesWindowExist(tab.window) then
            WindowSetShowing(tab.window, index == selected)
        end
    end
end

function StockPilerWindow.PrimeTabListsIfNeeded()
    if StockPilerWindow._tabListsPrimed == true then
        return
    end
    if not DoesWindowExist("StockPilerWindow") then
        return
    end
    if WindowGetShowing("StockPilerWindow") ~= true then
        return
    end
    StockPilerWindow._tabListsPrimed = true
    local selected = StockPilerWindow.SelectedTab or StockPilerWindow.TABS_POTIONS
    -- Layout only. Never call tab.refresh here - that ran WarmHave inside WatchRows
    -- on the same frame as SelectTab/OnShow (SP2 Flatten).
    StockPilerWindow.EnsureSelectedTabShowing()
    local tab = StockPilerWindow.Tabs[selected]
    if tab and DoesWindowExist(tab.window) and type(WindowForceProcessAnchors) == "function" then
        if StockPiler.Debug and StockPiler.Debug.TryCall then
            StockPiler.Debug.TryCall("WindowForceProcessAnchors", WindowForceProcessAnchors, tab.window)
        else
            pcall(WindowForceProcessAnchors, tab.window)
        end
    end
end

local function ForceAnchors(winName)
    if type(winName) ~= "string" or winName == "" then
        return
    end
    if not (DoesWindowExist and DoesWindowExist(winName)) then
        return
    end
    if type(WindowForceProcessAnchors) ~= "function" then
        return
    end
    if StockPiler.Debug and StockPiler.Debug.TryCall then
        StockPiler.Debug.TryCall("WindowForceProcessAnchors", WindowForceProcessAnchors, winName)
    else
        pcall(WindowForceProcessAnchors, winName)
    end
end

local function WatchListPopulated()
    local indices = SPTabWatchList and SPTabWatchList.PopulatorIndices
    if type(indices) ~= "table" then
        return false
    end
    local dataIndex = indices[1]
    if dataIndex == nil then
        return false
    end
    local list = StockPilerTabWatch and StockPilerTabWatch.listData
    return type(list) == "table" and type(list[dataIndex]) == "table"
end

local function WatchListHasPaintedRow()
    if not DoesWindowExist("SPTabWatchListRow1") then
        return false
    end
    return WindowGetShowing("SPTabWatchListRow1") == true
end

--- Placeholder rows (empty statusKey) are not a finished login paint.
local function WatchListNeedsRealRows()
    local list = StockPilerTabWatch and StockPilerTabWatch.listData
    if type(list) ~= "table" or #list < 1 then
        return true
    end
    local sawReal = false
    for i = 1, #list do
        local row = list[i]
        if type(row) == "table" and row._optimisticWatch ~= true
            and tostring(row.statusKey or "") ~= ""
        then
            sawReal = true
            break
        end
    end
    return sawReal ~= true
end

local function WatchHasContent()
    local Watch = StockPiler.Watch
    if Watch and Watch.CountEnabled and (tonumber(Watch.CountEnabled()) or 0) > 0 then
        return true
    end
    if Watch and Watch.CountEnabledPlantWatches
        and (tonumber(Watch.CountEnabledPlantWatches()) or 0) > 0
    then
        return true
    end
    local SkillUp = StockPiler.SkillUp
    if SkillUp and SkillUp.ShouldShowWatchStatus and SkillUp.ShouldShowWatchStatus() == true then
        return true
    end
    local US = StockPiler.UpgradeSeed
    return US and US.ShouldShowWatchStatus and US.ShouldShowWatchStatus() == true
end

function StockPilerWindow.OnSessionSettled()
    if DoesWindowExist("StockPilerWindow")
        and WindowGetShowing("StockPilerWindow") == true
        and StockPilerWindow.BeginOpenPaint
    then
        StockPilerWindow.BeginOpenPaint()
    end
    if StockPilerWindow.SyncActionReadiness then
        StockPilerWindow._footerSyncFrame = nil
        StockPilerWindow.SyncActionReadiness({ immediate = true })
    end
end

function StockPilerWindow.BeginOpenPaint()
    StockPilerWindow._openPaintPending = true
    StockPilerWindow._openPaintGaveUp = false
    StockPilerWindow._openPaintAttempts = 0
    StockPilerWindow._openPaintDidRefresh = false
    StockPilerWindow._openPaintChromePending = true
    StockPilerWindow._openPaintPlanWaits = 0
    StockPilerWindow._openPaintShownFrame = tonumber(StockPiler.FrameCounter) or 0
    StockPilerWindow._openPaintNeedKick = true
    if StockPiler.Ui then
        if StockPiler.Ui.BypassWatchThrottle then
            StockPiler.Ui.BypassWatchThrottle()
        end
        if StockPiler.Ui.MarkWatchUiDirty then
            StockPiler.Ui.MarkWatchUiDirty()
        end
    end
    StockPilerWindow.RequestListRepopulate()
end

--- Bind Watch ListBox after the parent has a real size. Scheduler skip/settle
--- must not cancel this - that left first-open empty until a tab click.
function StockPilerWindow.FlushOpenPaint()
    if StockPilerWindow._openPaintPending ~= true then
        -- Reload while shown: OnShown may not run; catch an unpainted Watch tab.
        if StockPilerWindow._openPaintGaveUp ~= true
            and DoesWindowExist("StockPilerWindow")
            and WindowGetShowing("StockPilerWindow") == true
            and StockPilerWindow.SelectedTab == StockPilerWindow.TABS_WATCH
            and WatchHasContent()
            and not WatchListHasPaintedRow()
        then
            StockPilerWindow._openPaintPending = true
            StockPilerWindow._openPaintNeedKick = true
        else
            return
        end
    end
    if not DoesWindowExist("StockPilerWindow") then
        return
    end
    if WindowGetShowing("StockPilerWindow") ~= true then
        return
    end
    local attempts = (tonumber(StockPilerWindow._openPaintAttempts) or 0) + 1
    StockPilerWindow._openPaintAttempts = attempts
    if attempts > 300 then
        StockPilerWindow._openPaintPending = false
        StockPilerWindow._openPaintGaveUp = true
        return
    end
    local frame = tonumber(StockPiler.FrameCounter) or 0
    local shownAt = tonumber(StockPilerWindow._openPaintShownFrame) or 0
    if frame < shownAt + 2 then
        ForceAnchors("StockPilerWindow")
        ForceAnchors("StockPilerWindowSocket")
        ForceAnchors("SPTabWatch")
        ForceAnchors("SPTabWatchList")
        return
    end
    local selected = StockPilerWindow.SelectedTab
    if selected ~= StockPilerWindow.TABS_WATCH then
        StockPilerWindow.RefreshActiveTab("open-paint-other")
        StockPilerWindow._openPaintPending = false
        return
    end
    -- Reload-restore can leave SPTabWatchList at 0 size until a hide/show edge.
    if StockPilerWindow._openPaintNeedKick == true or (attempts % 5) == 0 then
        if StockPilerTabWatch and StockPilerTabWatch.KickListBoxLayout then
            StockPilerTabWatch.KickListBoxLayout()
        elseif DoesWindowExist("SPTabWatch") then
            WindowSetShowing("SPTabWatch", false)
            WindowSetShowing("SPTabWatch", true)
        end
        ForceAnchors("StockPilerWindow")
        ForceAnchors("StockPilerWindowSocket")
        ForceAnchors("SPTabWatch")
        ForceAnchors("SPTabWatchList")
        StockPilerWindow._openPaintNeedKick = false
    end
    local listCount = 0
    if StockPilerTabWatch and type(StockPilerTabWatch.listData) == "table" then
        listCount = #StockPilerTabWatch.listData
    end
    -- A shown row is not done: login used to stop on placeholder dashes
    -- (no icon, priority, status, or Brew) until a tab round-trip.
    if StockPilerWindow._openPaintDidRefresh == true
        and StockPilerWindow._openPaintChromePending ~= true
        and WatchListNeedsRealRows() ~= true
        and (WatchListPopulated() or (listCount > 0 and WatchListHasPaintedRow()))
    then
        StockPilerWindow._openPaintPending = false
        return
    end
    local needsReal = WatchListNeedsRealRows()
    if StockPilerWindow._openPaintDidRefresh ~= true or needsReal == true then
        StockPilerWindow._openPaintDidRefresh = true
        if StockPilerTabWatch and StockPilerTabWatch.Refresh then
            StockPilerTabWatch.Refresh({ forceRebind = true, forcePlan = false })
        else
            StockPilerWindow.RefreshActiveTab("open-paint-watch")
        end
        if WatchListNeedsRealRows() == true then
            local waits = (tonumber(StockPilerWindow._openPaintPlanWaits) or 0) + 1
            StockPilerWindow._openPaintPlanWaits = waits
            if waits < 40 then
                StockPilerWindow._openPaintAttempts = attempts - 1
                StockPilerWindow._openPaintChromePending = true
                return
            end
        end
        -- ListBox clones row windows a frame after SetDisplayOrder and drops
        -- labels set on the bind frame. Paint chrome on the next pass.
        StockPilerWindow._openPaintChromePending = true
        return
    end
    if StockPilerWindow._openPaintChromePending == true then
        StockPilerWindow._openPaintChromePending = false
        if StockPilerTabWatch then
            StockPilerTabWatch._rowPaintKey = nil
            if StockPilerTabWatch.UpdateRows then
                StockPilerTabWatch.UpdateRows({ keepVisible = true, forceQuietPaint = true })
            end
        end
    end
    listCount = 0
    if StockPilerTabWatch and type(StockPilerTabWatch.listData) == "table" then
        listCount = #StockPilerTabWatch.listData
    end
    if WatchListNeedsRealRows() ~= true
        and (WatchListPopulated() or (listCount > 0 and WatchListHasPaintedRow()))
    then
        StockPilerWindow._openPaintPending = false
        return
    end
    if listCount <= 0 then
        if not WatchHasContent() then
            StockPilerWindow._openPaintPending = false
        else
            -- Plan not built yet; do not burn the attempt budget.
            StockPilerWindow._openPaintAttempts = attempts - 1
            StockPilerWindow._openPaintNeedKick = true
        end
        return
    end
    StockPilerWindow._openPaintNeedKick = true
end

function StockPilerWindow.OnShow()
    WindowUtils.OnShown()
    if StockPiler.Inventory and StockPiler.Inventory.RefreshAllIfNeeded then
        StockPiler.Inventory.RefreshAllIfNeeded({
            force = StockPiler.Inventory.IsDirty and StockPiler.Inventory.IsDirty(),
        })
    end
    if StockPilerTabWatch and StockPilerTabWatch.RefreshSkillGates then
        StockPilerTabWatch.RefreshSkillGates()
    end
    if StockPilerTabWatch and StockPilerTabWatch.ClearRowPaintCache then
        StockPilerTabWatch.ClearRowPaintCache()
    end
    -- Allow PrimeTabListsIfNeeded to run on every show; first-open layout is stale
    -- if we only primed while the window was still hidden.
    StockPilerWindow._tabListsPrimed = false
    StockPilerWindow.PrimeTabListsIfNeeded()
    ForceAnchors("StockPilerWindow")
    local tab = StockPilerWindow.Tabs[StockPilerWindow.SelectedTab]
    if tab and DoesWindowExist(tab.window) then
        -- Same hidden->shown edge as clicking the tab. Init already left the
        -- selected child showing while this parent was hidden, so ListBox never laid out.
        WindowSetShowing(tab.window, false)
        WindowSetShowing(tab.window, true)
        ForceAnchors(tab.window)
        if tab.window == "SPTabWatch" then
            ForceAnchors("SPTabWatchList")
        end
    end
    -- Footer Harvest/Brew vs Clear Watches must apply on this show, not after
    -- UPDATE_PROCESSED (XML defaults all three visible and they overlap).
    StockPilerWindow._footerSyncFrame = nil
    StockPilerWindow._footerWindowOpen = false
    StockPilerWindow.SyncActionReadiness({ immediate = true })
    StockPilerWindow.BeginOpenPaint()
end

function StockPilerWindow.OnClose()
    WindowSetShowing("StockPilerWindow", false)
end

function StockPilerWindow.ConfirmClearWatches(kind)
    -- Kind is captured by the dialog closure. A later dialog must not retarget this one.
    if kind ~= "plant" and kind ~= "potion" then
        return
    end
    local onPlants = kind == "plant"
    local n = 0
    if onPlants then
        if StockPiler.Catalog and StockPiler.Catalog.ClearPlantWatchList then
            n = tonumber(StockPiler.Catalog.ClearPlantWatchList()) or 0
        end
        if StockPiler.Ui and StockPiler.Ui.Print then
            StockPiler.Ui.Print(T("ui.plant_watches_cleared", { count = tostring(n) }))
        end
        if StockPilerTabPlants and StockPilerTabPlants.Refresh then
            StockPilerTabPlants.Refresh()
        end
    else
        if StockPiler.Catalog and StockPiler.Catalog.ClearWatchList then
            n = tonumber(StockPiler.Catalog.ClearWatchList()) or 0
        end
        if StockPiler.Ui and StockPiler.Ui.Print then
            StockPiler.Ui.Print(T("ui.watches_cleared", { count = tostring(n) }))
        end
        if StockPilerTabPotions and StockPilerTabPotions.Refresh then
            StockPilerTabPotions.Refresh()
        end
    end
    if StockPilerTabWatch and StockPilerTabWatch.OptimisticClearWatchKind then
        StockPilerTabWatch.OptimisticClearWatchKind(kind)
    end
    if StockPiler.PlanSnapshot and StockPiler.PlanSnapshot.Invalidate then
        StockPiler.PlanSnapshot.Invalidate()
    end
    local Sch = StockPiler.Scheduler
    if Sch and Sch.EnqueuePlanRebuild then
        Sch.EnqueuePlanRebuild({ urgent = true })
    end
    if StockPiler.Ui then
        if StockPiler.Ui.BypassWatchThrottle then
            StockPiler.Ui.BypassWatchThrottle()
        end
        if StockPiler.Ui.ClearWatchTipCaches then
            StockPiler.Ui.ClearWatchTipCaches()
        end
        if StockPiler.Ui.MarkWatchUiDirty then
            StockPiler.Ui.MarkWatchUiDirty()
        end
    end
    -- forceRebind only while Watch is visible - otherwise KickListBoxLayout
    -- would show Watch on top of Potions/Plants (Clear Watches runs from those tabs).
    if StockPilerWindow.SelectedTab == StockPilerWindow.TABS_WATCH
        and StockPilerTabWatch and StockPilerTabWatch.Refresh
    then
        StockPilerTabWatch.Refresh({ forcePlan = false, forceRebind = true })
    end
    if StockPilerWindow.EnsureSelectedTabShowing then
        StockPilerWindow.EnsureSelectedTabShowing()
    end
    -- Clear Watches must grey immediately after bulk clear.
    if StockPilerWindow.SyncActionReadiness then
        StockPilerWindow.SyncActionReadiness({ immediate = true })
    else
        StockPilerWindow.RefreshFooterButtons()
    end
end

function StockPilerWindow.OnClearWatches()
    local onPlants = StockPilerWindow.SelectedTab == StockPilerWindow.TABS_PLANTS
    local count = 0
    if onPlants then
        if StockPiler.Watch and StockPiler.Watch.CountEnabledPlantWatches then
            count = tonumber(StockPiler.Watch.CountEnabledPlantWatches()) or 0
        end
        if count <= 0 then
            if StockPiler.Ui and StockPiler.Ui.Print then
                StockPiler.Ui.Print(T("ui.no_plant_watches"))
            end
            StockPilerWindow.RefreshFooterButtons()
            return
        end
        local kind = "plant"
        StockPiler.ViewList.ConfirmTwoButton(
            T("ui.clear_plant_watches_confirm", { count = tostring(count) }),
            function()
                StockPilerWindow.ConfirmClearWatches(kind)
            end
        )
        return
    end
    if StockPiler.Watch and StockPiler.Watch.CountEnabled then
        count = tonumber(StockPiler.Watch.CountEnabled()) or 0
    end
    if count <= 0 then
        if StockPiler.Ui and StockPiler.Ui.Print then
            StockPiler.Ui.Print(T("ui.no_watches"))
        end
        StockPilerWindow.RefreshFooterButtons()
        return
    end
    local kind = "potion"
    StockPiler.ViewList.ConfirmTwoButton(
        T("ui.clear_watches_confirm", { count = tostring(count) }),
        function()
            StockPilerWindow.ConfirmClearWatches(kind)
        end
    )
end

function StockPilerWindow.OnMouseOverClearWatches()
    local tip = T("ui.clear_watches_tip")
    if StockPilerWindow.SelectedTab == StockPilerWindow.TABS_PLANTS then
        tip = T("ui.clear_plant_watches_tip")
    end
    StockPiler.ViewList.ShowTextTip(SystemData.ActiveWindow.name, tip)
end

function StockPilerWindow.OnHarvestPrepare()
    if StockPiler.Grow and StockPiler.Grow.CanHarvestNow then
        if StockPiler.Grow.CanHarvestNow() ~= true then
            return
        end
    else
        local ready = 0
        if StockPiler.Grow and StockPiler.Grow.GetReadyHarvestPlots then
            local plots = StockPiler.Grow.GetReadyHarvestPlots()
            ready = type(plots) == "table" and #plots or 0
        end
        if ready <= 0 then
            return
        end
    end
    if DoesWindowExist(HARVEST_WIN) and ButtonGetDisabledFlag(HARVEST_WIN) == true then
        return
    end
    local prepared = false
    if StockPiler.Grow and StockPiler.Grow.PrepareHarvestPlot then
        prepared = StockPiler.Grow.PrepareHarvestPlot(true) == true
    end
    if prepared then
        if Sound and Sound.Play and Sound.CULTIVATING_HARVEST_CROP then
            Sound.Play(Sound.CULTIVATING_HARVEST_CROP)
        end
    end
end

-- Empty: XML requires OnLButtonUp; harvest fires via gameactionbutton after OnHarvestPrepare.
function StockPilerWindow.OnHarvest()
end

function StockPilerWindow.OnMouseOverHarvest()
    if StockPiler.HarvestTooltip and StockPiler.HarvestTooltip.Show then
        StockPiler.HarvestTooltip.Show(
            SystemData.ActiveWindow.name,
            Tooltips.ANCHOR_WINDOW_TOP
        )
        return
    end
    Tooltips.CreateTextOnlyTooltip(SystemData.ActiveWindow.name, T("ui.harvest_tip_none"))
    Tooltips.AnchorTooltip(Tooltips.ANCHOR_WINDOW_RIGHT)
end

function StockPilerWindow.OnBrew()
    if DoesWindowExist(BREW_WIN) and ButtonGetDisabledFlag(BREW_WIN) == true then
        return
    end
    if not StockPiler.Brew then
        return
    end
    local result = nil
    if StockPiler.Brew.TryBrewClick then
        result = StockPiler.Brew.TryBrewClick()
    end
    if result == "go" and StockPiler.Brew.FirePerform then
        StockPiler.Brew.FirePerform()
    end
    StockPilerWindow.RefreshFooterButtons()
end

function StockPilerWindow.OnBrewRightClick()
    if StockPiler.Brew and StockPiler.Brew.ClearLoadedSession then
        StockPiler.Brew.ClearLoadedSession()
    end
    StockPilerWindow.RefreshFooterButtons()
end

function StockPilerWindow.OnMouseOverBrew()
    if StockPiler.BrewTooltip and StockPiler.BrewTooltip.Show then
        StockPiler.BrewTooltip.Show(
            SystemData.ActiveWindow.name,
            Tooltips.ANCHOR_WINDOW_TOP
        )
        return
    end
    Tooltips.CreateTextOnlyTooltip(SystemData.ActiveWindow.name, T("brew.none_ready"))
    Tooltips.AnchorTooltip(Tooltips.ANCHOR_WINDOW_TOP)
end

function StockPilerWindow.SelectTab(tabNumber, opts)
    opts = type(opts) == "table" and opts or {}
    tabNumber = tonumber(tabNumber)
    if tabNumber == nil or tabNumber < StockPilerWindow.TABS_POTIONS or tabNumber > StockPilerWindow.TABS_MAX then
        return
    end
    StockPilerWindow.SelectedTab = tabNumber
    local s = StockPiler.Persistence and StockPiler.Persistence.EnsureSettings
        and StockPiler.Persistence.EnsureSettings()
    if type(s) == "table" then
        s.selectedTab = tabNumber
    end
    for index, tab in ipairs(StockPilerWindow.Tabs) do
        local selected = (index == tabNumber)
        ButtonSetPressedFlag(tab.name, selected)
        if DoesWindowExist(tab.window) then
            WindowSetShowing(tab.window, selected)
            if selected and type(WindowForceProcessAnchors) == "function" then
                if StockPiler.Debug and StockPiler.Debug.TryCall then
                    StockPiler.Debug.TryCall("WindowForceProcessAnchors", WindowForceProcessAnchors, tab.window)
                else
                    pcall(WindowForceProcessAnchors, tab.window)
                end
            end
        end
    end
    -- Footer Harvest/Brew/Clear show-hide must track the tab on the click frame
    -- (do not wait for UPDATE_PROCESSED FlushPendingFooterRefresh).
    StockPilerWindow.SyncActionReadiness()
    if tabNumber == StockPilerWindow.TABS_WATCH
        and StockPiler.Ui
        and StockPiler.Ui.FlushDeferredWatchRecount
    then
        StockPiler.Ui.FlushDeferredWatchRecount()
    end
    if opts.deferRefresh == true then
        if StockPiler.Ui and StockPiler.Ui.MarkWatchUiDirty then
            StockPiler.Ui.MarkWatchUiDirty("select-tab-defer")
        end
        local parentOpen = DoesWindowExist("StockPilerWindow")
            and WindowGetShowing("StockPilerWindow") == true
        if tabNumber == StockPilerWindow.TABS_WATCH
            and parentOpen ~= true
            and StockPilerTabWatch
            and StockPilerTabWatch.PrimeRowChrome
        then
            StockPilerTabWatch.PrimeRowChrome()
        end
        StockPilerWindow.RequestListRepopulate()
        return
    end
    -- One refresh only. RefreshActiveTab + RequestListRepopulate used to run
    -- RefreshWatch twice per click (libperf RefreshWatch.select-tab + list-repop
    -- ~150ms each). Re-arm list-repop only when Watch still has no PopulatorIndices.
    if tabNumber == StockPilerWindow.TABS_WATCH
        and StockPilerTabWatch
        and StockPilerTabWatch.PaintTabSwitch
    then
        StockPilerTabWatch.PaintTabSwitch()
        StockPilerWindow.RefreshFooterButtons()
        if StockPiler.Perf and StockPiler.Perf.Tally then
            StockPiler.Perf.Tally("refreshTab", "select-tab-watch")
        end
    else
        StockPilerWindow.RefreshActiveTab("select-tab")
    end
    if tabNumber == StockPilerWindow.TABS_WATCH then
        local indices = SPTabWatchList and SPTabWatchList.PopulatorIndices
        local hasPopulated = type(indices) == "table" and next(indices) ~= nil
        local listCount = 0
        if StockPilerTabWatch and type(StockPilerTabWatch.listData) == "table" then
            listCount = #StockPilerTabWatch.listData
        end
        if listCount > 0 and not hasPopulated then
            StockPilerWindow.RequestListRepopulate()
        end
    end
end

function StockPilerWindow.OnLButtonUpTab()
    local tabId = WindowGetId(SystemData.ActiveWindow.name)
    StockPilerWindow.SelectTab(tabId)
end
