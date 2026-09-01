----------------------------------------------------------------
-- StockPilerWindow — settings-style chrome (User Settings / CustomUI Settings)
----------------------------------------------------------------

StockPilerWindow = {}

StockPilerWindow.TABS_POTIONS = 1
StockPilerWindow.TABS_WATCH = 2
StockPilerWindow.TABS_MAX = 2

StockPilerWindow.SelectedTab = StockPilerWindow.TABS_POTIONS

StockPilerWindow.Tabs = {
    [1] = {
        window = "SPTabPotions",
        name = "StockPilerWindowTabButtonsPotions",
        label = L"Potions",
        refresh = function()
            if StockPilerTabPotions and StockPilerTabPotions.Refresh then
                StockPilerTabPotions.Refresh()
            end
        end,
    },
    [2] = {
        window = "SPTabAutoGrow",
        name = "StockPilerWindowTabButtonsAutoGrow",
        label = L"Watch",
        refresh = function()
            if StockPilerTabAutoGrow and StockPilerTabAutoGrow.Refresh then
                StockPilerTabAutoGrow.Refresh()
            end
        end,
    },
}

function StockPilerWindow.OnInitialize()
    -- CreateWindow runs before StockPiler.Initialize — only flip tab visibility here.
    -- Do not Refresh (settings / list data may not be ready yet).
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

function StockPilerWindow.Initialize()
    if not DoesWindowExist("StockPilerWindow") then
        return
    end

    local version = StockPiler.Version or L""
    if version ~= L"" then
        LabelSetText("StockPilerWindowTitleBarText", L"StockPiler v" .. version)
    else
        LabelSetText("StockPilerWindowTitleBarText", L"StockPiler")
    end
    ButtonSetText("StockPilerWindowRefreshButton", L"Refresh")
    ButtonSetText("StockPilerWindowCloseButton", L"Close")

    for _, tab in ipairs(StockPilerWindow.Tabs) do
        ButtonSetText(tab.name, tab.label)
    end

    StockPilerWindow.SelectTab(StockPilerWindow.SelectedTab)
end

function StockPilerWindow.RefreshActiveTab()
    if StockPiler.Perf and StockPiler.Perf.Begin then
        StockPiler.Perf.Begin("RefreshWatch")
    end
    local tab = StockPilerWindow.Tabs[StockPilerWindow.SelectedTab]
    if tab and tab.refresh then
        tab.refresh()
    end
    if StockPiler.Perf and StockPiler.Perf.End then
        StockPiler.Perf.End("RefreshWatch")
    end
end

--- WAR ListBox: labels often stay blank when a tab list first builds while that
--- tab (or the parent window) was hidden. Re-populate once the UI is showing.
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
    if type(WindowGetShowing) == "function" and WindowGetShowing("StockPilerWindow") ~= true then
        return
    end
    StockPilerWindow._repopulatePending = false
    StockPilerWindow.RefreshActiveTab()
end

--- First show: build every tab list while visible so switching later is not blank.
function StockPilerWindow.PrimeTabListsIfNeeded()
    if StockPilerWindow._tabListsPrimed == true then
        return
    end
    if not DoesWindowExist("StockPilerWindow") then
        return
    end
    if type(WindowGetShowing) == "function" and WindowGetShowing("StockPilerWindow") ~= true then
        return
    end
    StockPilerWindow._tabListsPrimed = true

    local selected = StockPilerWindow.SelectedTab or StockPilerWindow.TABS_POTIONS
    for index, tab in ipairs(StockPilerWindow.Tabs) do
        if DoesWindowExist(tab.window) then
            WindowSetShowing(tab.window, true)
            if type(WindowForceProcessAnchors) == "function" then
                StockPiler.TryCall("WindowForceProcessAnchors", WindowForceProcessAnchors, tab.window)
            end
        end
        if tab.refresh then
            tab.refresh()
        end
        if DoesWindowExist(tab.window) and index ~= selected then
            WindowSetShowing(tab.window, false)
        end
    end
    -- Keep the selected tab showing (already true from the loop).
    for index, tab in ipairs(StockPilerWindow.Tabs) do
        if DoesWindowExist(tab.name) then
            ButtonSetPressedFlag(tab.name, index == selected)
        end
        if DoesWindowExist(tab.window) then
            WindowSetShowing(tab.window, index == selected)
        end
    end
end

function StockPilerWindow.OnShow()
    WindowUtils.OnShown()
    if StockPiler._bagCountsStale == true
        and StockPiler.Inventory
        and StockPiler.Inventory.RefreshAllIfNeeded
    then
        StockPiler.Inventory.RefreshAllIfNeeded({ force = true })
    end
    if StockPiler._bagCountsStale == true
        and StockPiler.Planner
        and StockPiler.Planner.InvalidatePlanCache
    then
        StockPiler.Planner.InvalidatePlanCache()
    end
    StockPilerWindow.PrimeTabListsIfNeeded()
    StockPilerWindow.RefreshActiveTab()
    StockPilerWindow.RequestListRepopulate()
end

function StockPilerWindow.OnClose()
    WindowSetShowing("StockPilerWindow", false)
end

function StockPilerWindow.OnRefresh()
    if StockPiler.Inventory and StockPiler.Inventory.RefreshAllIfNeeded then
        StockPiler.Inventory.RefreshAllIfNeeded({ force = true })
    end
    StockPilerWindow.RefreshActiveTab()
    local n = 0
    if StockPiler.Inventory and StockPiler.Inventory.GetSnapshotItemCount then
        n = StockPiler.Inventory.GetSnapshotItemCount()
    end
    StockPiler.Print(L"Refreshed local bags (" .. towstring(tostring(n)) .. L" item stacks).")
end

function StockPilerWindow.SelectTab(tabNumber)
    if tabNumber == nil
        or tabNumber < StockPilerWindow.TABS_POTIONS
        or tabNumber > StockPilerWindow.TABS_MAX
    then
        return
    end

    StockPilerWindow.SelectedTab = tabNumber

    if StockPiler.EnsureSettings then
        local s = StockPiler.EnsureSettings()
        if type(s) == "table" then
            if s.selectedTab ~= tabNumber and StockPiler.LogOp then
                StockPiler.LogOp("settings", "selectedTab=" .. tostring(tabNumber))
            end
            s.selectedTab = tabNumber
        end
    end

    for index, tab in ipairs(StockPilerWindow.Tabs) do
        local selected = (index == tabNumber)
        ButtonSetPressedFlag(tab.name, selected)
        if DoesWindowExist(tab.window) then
            WindowSetShowing(tab.window, selected)
            if selected and type(WindowForceProcessAnchors) == "function" then
                StockPiler.TryCall("WindowForceProcessAnchors", WindowForceProcessAnchors, tab.window)
            end
        end
    end

    StockPilerWindow.RefreshActiveTab()
    StockPilerWindow.RequestListRepopulate()
end

function StockPilerWindow.OnLButtonUpTab()
    local tabId = WindowGetId(SystemData.ActiveWindow.name)
    StockPilerWindow.SelectTab(tabId)
end
