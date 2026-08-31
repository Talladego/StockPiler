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

function StockPilerWindow.OnShow()
    WindowUtils.OnShown()
    StockPilerWindow.RefreshActiveTab()
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

function StockPilerWindow.SelectTab(tabNumber)
    if tabNumber == nil
        or tabNumber < StockPilerWindow.TABS_POTIONS
        or tabNumber > StockPilerWindow.TABS_MAX
    then
        return
    end

    StockPilerWindow.SelectedTab = tabNumber

    for index, tab in ipairs(StockPilerWindow.Tabs) do
        local selected = (index == tabNumber)
        ButtonSetPressedFlag(tab.name, selected)
        if DoesWindowExist(tab.window) then
            WindowSetShowing(tab.window, selected)
        end
    end

    StockPilerWindow.RefreshActiveTab()
end

function StockPilerWindow.OnLButtonUpTab()
    local tabId = WindowGetId(SystemData.ActiveWindow.name)
    StockPilerWindow.SelectTab(tabId)
end
