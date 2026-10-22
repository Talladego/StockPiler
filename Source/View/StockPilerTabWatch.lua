----------------------------------------------------------------
-- StockPilerTabWatch -- watched potion dashboard
----------------------------------------------------------------

StockPilerTabWatch = {}
StockPilerTabWatch.listData = {}
StockPilerTabWatch.displayOrder = {}

local function T(key, tokens)
    return StockPiler.Util.T(key, tokens)
end

local TAB_ROOT = "SPTabWatch"
local ENABLE_WIN = "SPTabWatchEnable"
local ADDITIVES_WIN = "SPTabWatchAdditives"
local AUTOBUY_WIN = "SPTabWatchAutoBuy"
local AUTOBREW_WIN = "SPTabWatchAutoBrew"
local SEED_BUFFER_ENABLE_WIN = "SPTabWatchSeedBufferEnable"
local OPTIMISTIC_MODE_WIN = "SPTabWatchOptimisticMode"
local SKILLUP_SKILLS_WIN = "SPTabWatchSkillUpSkills"
local UPGRADE_SEEDS_WIN = "SPTabWatchUpgradeSeeds"
local HUD_BUTTON_WIN = "SPTabWatchHudButton"
local CRAFT_MACRO_WIN = "SPTabWatchCraftMacro"

local COLOR_OK = { 80, 200, 80 }
local COLOR_WARN = { 220, 180, 60 }
local COLOR_BLOCK = { 220, 70, 70 }
local COLOR_GRAY = { 140, 140, 140 }

local ICON_SCALE = 0.34
local TARGET_MAX = 200
local syncingUi = false

--- Checkbox labels use handleinput=true (stock EA_LabelCheckButton pattern).
--- Label clicks do not auto-toggle EA_Button_DefaultCheckBox; flip when ActiveWindow
--- is not the button itself, then let OnToggle* read ButtonGetPressedFlag.
local function SyncCheckFromActive(buttonWin)
    if type(buttonWin) ~= "string" or buttonWin == "" or not DoesWindowExist(buttonWin) then
        return false
    end
    if ButtonGetDisabledFlag and ButtonGetDisabledFlag(buttonWin) == true then
        return false
    end
    local active = tostring(SystemData.ActiveWindow.name or "")
    if active ~= buttonWin then
        ButtonSetPressedFlag(buttonWin, not (ButtonGetPressedFlag(buttonWin) == true))
    end
    return true
end

local SORT_IDS = {
    [1] = "prio",
    [2] = "name",
    [3] = "status",
    [4] = "stock",
    [5] = "craftable",
    [6] = "target",
    [7] = "autoGrow",
}

local SORT_HEADERS = {
    prio = "SPTabWatchColPrio",
    name = "SPTabWatchColPotion",
    status = "SPTabWatchColStatus",
    stock = "SPTabWatchColStock",
    craftable = "SPTabWatchColCraftable",
    target = "SPTabWatchColTarget",
    autoGrow = "SPTabWatchColPriority",
}

local function GetSettings()
    if StockPiler.Persistence and StockPiler.Persistence.EnsureSettings then
        return StockPiler.Persistence.EnsureSettings()
    end
    return StockPiler.Settings
end

local function CharRow(create)
    return StockPiler.Util.CharacterRow(create)
end

local function CanAutoGrowUi()
    local Caps = StockPiler.TradeSkillCaps
    return Caps and Caps.CanAutoGrow and Caps.CanAutoGrow() == true
end

local function CanAutoBuyUi()
    local Caps = StockPiler.TradeSkillCaps
    if Caps and Caps.CanApothecary and Caps.CanApothecary() == true then
        return true
    end
    return CanAutoGrowUi()
end

local function CanAutoBrewUi()
    local Caps = StockPiler.TradeSkillCaps
    return Caps and Caps.CanBrewPotions and Caps.CanBrewPotions() == true
end

local function OnOff(flag)
    return flag and T("boot.on") or T("boot.off")
end

local function NotifySettings(msg)
    if StockPiler.Ui and StockPiler.Ui.Print then
        StockPiler.Ui.Print(msg)
    elseif StockPiler.Debug and StockPiler.Debug.Print then
        StockPiler.Debug.Print(msg)
    end
end

local function TintStepper(bgWin)
    if DoesWindowExist(bgWin) and WindowSetTintColor then
        WindowSetTintColor(bgWin, 40, 40, 40)
    end
end

--- TintableSolidBackground defaults to bright white until SetListRowTint runs.
--- Session settle defers Watch paint ~2.5s, so prime dark chrome and hide
--- unpainted rows so login/reload never flashes white bars.
function StockPilerTabWatch.PrimeRowChrome()
    if not DoesWindowExist("SPTabWatchList") then
        return
    end
    local numVisible = 11
    if SPTabWatchList and SPTabWatchList.numVisibleRows then
        numVisible = tonumber(SPTabWatchList.numVisibleRows) or 11
    end
    local paintKeys = StockPilerTabWatch._rowPaintKey
    for rowIndex = 1, numVisible do
        local rowName = "SPTabWatchListRow" .. rowIndex
        if DoesWindowExist(rowName) then
            if StockPiler.ViewList and StockPiler.ViewList.ApplyRowStripe then
                StockPiler.ViewList.ApplyRowStripe(rowName .. "Background", rowIndex)
            elseif DefaultColor and DefaultColor.SetListRowTint then
                DefaultColor.SetListRowTint(rowName .. "Background", rowIndex, false)
            elseif WindowSetTintColor then
                WindowSetTintColor(rowName .. "Background", 20, 20, 20)
            end
            TintStepper(rowName .. "PrioChipBg")
            TintStepper(rowName .. "TargetChipBg")
            if type(paintKeys) ~= "table" or paintKeys[rowIndex] == nil then
                -- Reload-with-window-open: init PrimeRowChrome used to hide rows
                -- after OnShown and they never came back until a tab click.
                local parentOpen = DoesWindowExist("StockPilerWindow")
                    and WindowGetShowing("StockPilerWindow") == true
                if parentOpen ~= true then
                    WindowSetShowing(rowName, false)
                end
            end
        end
    end
end

local function SetChipNumber(valueWin, chipWin, value)
    if DoesWindowExist(valueWin) then
        LabelSetText(valueWin, towstring(tostring(value)))
        LabelSetTextColor(valueWin, 255, 255, 255)
    end
    if DoesWindowExist(chipWin) then
        TintStepper(chipWin .. "Bg")
    end
end

local function ChipDelta(flags, dir)
    local step = 1
    if SystemData and SystemData.ButtonFlags and flags == SystemData.ButtonFlags.SHIFT then
        step = 10
    elseif type(flags) == "number" and flags ~= 0 then
        -- Some clients pass combined flags; treat nonzero as shift-ish when SHIFT bit present.
        if SystemData and SystemData.ButtonFlags and SystemData.ButtonFlags.SHIFT then
            if bit and bit.band and bit.band(flags, SystemData.ButtonFlags.SHIFT) ~= 0 then
                step = 10
            end
        end
    end
    return step * (dir or 1)
end

local function Clamp(n, lo, hi)
    n = tonumber(n) or lo
    if n < lo then
        return lo
    end
    if n > hi then
        return hi
    end
    return math.floor(n)
end

local function SetIconTexture(iconWin, iconNum)
    StockPiler.ViewList.SetIconTexture(iconWin, iconNum, ICON_SCALE)
end

local STATUS_TIP_COLORS = {
    no_recipe = COLOR_BLOCK,
    no_target = COLOR_BLOCK,
    potion_stocked = COLOR_OK,
    plant_stocked = COLOR_OK,
    ready_to_craft = COLOR_OK,
    ready_to_craft_shared = COLOR_WARN,
    restocking = COLOR_WARN,
    craft_bag_full = COLOR_WARN,
    enable_autogrow = COLOR_BLOCK,
    need_apothecary = COLOR_BLOCK,
    need_skill = COLOR_BLOCK,
    buy_ingredients = COLOR_BLOCK,
    need_seeds = COLOR_WARN,
    upgrading_seed = COLOR_WARN,
    seed_buffer = COLOR_WARN,
    planting = COLOR_OK,
    buffer_plant = COLOR_OK,
    growing = COLOR_OK,
    refining = COLOR_WARN,
    wait_cult = COLOR_WARN,
    idle = COLOR_WARN,
    fallback_blocked = COLOR_OK,
    skill_done = COLOR_OK,
    waiting_watches = COLOR_WARN,
    waiting_potions = COLOR_WARN,
    waiting_plants = COLOR_WARN,
    waiting_seed_buffer = COLOR_WARN,
    no_seeds = COLOR_BLOCK,
    need_vendor = COLOR_BLOCK,
    autobuy_off = COLOR_BLOCK,
    no_vendor_seed = COLOR_BLOCK,
    need_mats = COLOR_BLOCK,
    need_resin = COLOR_BLOCK,
    unstable = COLOR_BLOCK,
    need_container_vendor = COLOR_BLOCK,
    no_vendor_container = COLOR_BLOCK,
    no_vial = COLOR_BLOCK,
    cult_for_apo = COLOR_WARN,
}

local function ApplyStatusColor(labelWin, statusKey)
    statusKey = tostring(statusKey or "")
    local c = STATUS_TIP_COLORS[statusKey] or COLOR_GRAY
    LabelSetTextColor(labelWin, c[1], c[2], c[3])
end

local function IsPlantWatchRow(data)
    return type(data) == "table" and (data.kind == "plant" or data.isPlantWatch == true)
end

local function IsUpgradeWatchRow(data)
    return type(data) == "table" and data.upgradeWatch == true
end

local function IsSkillUpWatchRow(data)
    return type(data) == "table" and data.skillUp == true
end

--- SkillUp + Upgrade Seed ephemeral rows (addon-owned, not saved watches).
local function IsEphemeralWatchRow(data)
    return IsSkillUpWatchRow(data) or IsUpgradeWatchRow(data)
        or (type(data) == "table" and data.addonOwned == true)
end

local function WatchRowKindRank(row)
    if IsPlantWatchRow(row) then
        return 2
    end
    if IsEphemeralWatchRow(row) then
        return 3
    end
    return 1
end

local function NarrowWatchName(row)
    local n = row and row.name
    if StockPiler.Util and StockPiler.Util.ToNarrow then
        return string.lower(StockPiler.Util.ToNarrow(n) or "")
    end
    return string.lower(tostring(n or ""))
end

local function NarrowWatchStatus(row)
    local t = row and (row.statusText or row.statusKey)
    if StockPiler.Util and StockPiler.Util.ToNarrow then
        return string.lower(StockPiler.Util.ToNarrow(t) or "")
    end
    return string.lower(tostring(t or ""))
end

local function WatchRowStableKey(row)
    return tostring(row and (row.potionRecipeKey or row.potionKey or row.id or row.plantKey) or "")
end

local function CompareWatchRows(a, b, column, ascending)
    local function finish(less)
        if ascending then
            return less
        end
        return not less
    end
    local ka, kb = WatchRowKindRank(a), WatchRowKindRank(b)
    if ka ~= kb then
        return ka < kb
    end
    local na, nb = NarrowWatchName(a), NarrowWatchName(b)
    local function compareName()
        if na ~= nb then
            return finish(na < nb)
        end
        return WatchRowStableKey(a) < WatchRowStableKey(b)
    end
    if ka ~= 1 and (column == "prio" or column == "autoGrow") then
        return compareName()
    end
    if column == "prio" then
        local ta = tonumber(a and a.priorityTier) or 1
        local tb = tonumber(b and b.priorityTier) or 1
        if ta == tb then
            return compareName()
        end
        return finish(ta < tb)
    elseif column == "name" then
        return compareName()
    elseif column == "status" then
        local sa, sb = NarrowWatchStatus(a), NarrowWatchStatus(b)
        if sa == sb then
            return compareName()
        end
        return finish(sa < sb)
    elseif column == "stock" then
        local ha = tonumber(a and (a.potionHave or a.have or a.stock)) or 0
        local hb = tonumber(b and (b.potionHave or b.have or b.stock)) or 0
        if ha == hb then
            return compareName()
        end
        return finish(ha < hb)
    elseif column == "craftable" then
        local ca = tonumber(a and a.craftable) or 0
        local cb = tonumber(b and b.craftable) or 0
        if ca == cb then
            return compareName()
        end
        return finish(ca < cb)
    elseif column == "target" then
        local ta = tonumber(a and (a.target or a.potionMin)) or 0
        local tb = tonumber(b and (b.target or b.potionMin)) or 0
        if ta == tb then
            return compareName()
        end
        return finish(ta < tb)
    elseif column == "autoGrow" then
        local aa = a and a.autoGrow == true
        local ab = b and b.autoGrow == true
        if aa == ab then
            return compareName()
        end
        return finish(aa and not ab)
    end
    return compareName()
end

local function SortWatchRows(rows)
    if type(rows) ~= "table" or #rows < 2 then
        return
    end
    local s = GetSettings()
    local column = (type(s) == "table" and s.watchSortColumn) or "name"
    local ascending = type(s) ~= "table" or s.watchSortAscending ~= false
    table.sort(rows, function(a, b)
        return CompareWatchRows(a, b, column, ascending)
    end)
end

--- Bind display list without mutating Planner snapshot row order.
--- Tracks `_boundPlanRows` so brew-hold catch-up can tell a sorted copy from a stale plan.
local function BindSortedList(rows)
    if type(rows) ~= "table" then
        rows = {}
    end
    local list = rows
    local plan = StockPiler.PlanSnapshot and StockPiler.PlanSnapshot.Get
        and StockPiler.PlanSnapshot.Get()
    local planRows = type(plan) == "table" and plan.rows or nil
    if type(planRows) == "table" and rows == planRows then
        list = {}
        for i = 1, #rows do
            list[i] = rows[i]
        end
        StockPilerTabWatch._boundPlanRows = planRows
    elseif type(planRows) == "table" and StockPilerTabWatch._boundPlanRows == planRows then
        -- Re-sorting the existing display copy; still bound to this plan.rows.
        StockPilerTabWatch._boundPlanRows = planRows
    else
        StockPilerTabWatch._boundPlanRows = nil
    end
    SortWatchRows(list)
    StockPilerTabWatch.listData = list
    StockPilerTabWatch.displayOrder = {}
    for i = 1, #list do
        StockPilerTabWatch.displayOrder[i] = i
    end
end

--- Public rebind for brew-hold catch-up (keeps user sort; never assign plan.rows raw).
function StockPilerTabWatch.BindSortedList(rows)
    BindSortedList(rows)
end

local function UpdateSortHeaderLabels()
    local labels = {
        prio = T("watch.col.prio"),
        name = T("watch.col.name"),
        status = T("watch.col.status"),
        stock = T("watch.col.stock"),
        craftable = T("watch.col.craftable"),
        target = T("watch.col.target"),
        autoGrow = T("watch.col.autogrow"),
    }
    for key, win in pairs(SORT_HEADERS) do
        if DoesWindowExist(win) and labels[key] then
            ButtonSetText(win, labels[key])
        end
    end
    if DoesWindowExist("SPTabWatchColBrew") then
        ButtonSetText("SPTabWatchColBrew", T("watch.col.brew"))
    end
end

local function UpdateSortHeaders()
    UpdateSortHeaderLabels()
    local s = GetSettings()
    if StockPiler.ViewList and StockPiler.ViewList.UpdateSortArrows then
        StockPiler.ViewList.UpdateSortArrows(
            SORT_HEADERS,
            (type(s) == "table" and s.watchSortColumn) or "name",
            type(s) ~= "table" or s.watchSortAscending ~= false
        )
    end
end

local function EnsureWatchNameRarityColors(data)
    if type(data) ~= "table" then
        return 255, 255, 255
    end
    local itemData = data.itemData
    local uid = tonumber(data.uniqueID) or tonumber(data.plantUid) or 0
    local isPlant = IsPlantWatchRow(data)
    local needResolve = type(itemData) ~= "table"
        or (tonumber(itemData.rarity) or 0) <= 0
    if not isPlant then
        needResolve = needResolve
            or not (StockPiler.Inventory and StockPiler.Inventory.ItemDataHasUseBonus
                and StockPiler.Inventory.ItemDataHasUseBonus(itemData))
    elseif StockPiler.Inventory then
        -- Plants: always prefer bag/DB sample so rarity tint matches the item tooltip.
        needResolve = true
    end
    if needResolve and StockPiler.Inventory then
        if StockPiler.Inventory.GetSample and uid > 0 then
            local sample = StockPiler.Inventory.GetSample(uid)
            if type(sample) == "table" then
                itemData = sample
                data.itemData = sample
            end
        end
        if StockPiler.Inventory.ResolvePotionItemData then
            itemData = StockPiler.Inventory.ResolvePotionItemData(
                data.potionKey or data.potionBaseKey or data.plantKey,
                uid,
                itemData
            )
            if type(itemData) == "table" then
                data.itemData = itemData
            end
        end
    end
    itemData = data.itemData
    if itemData and DataUtils and DataUtils.GetItemRarityColor then
        local ok, color = pcall(DataUtils.GetItemRarityColor, itemData)
        if ok and type(color) == "table" then
            data.nameR = tonumber(color.r) or 255
            data.nameG = tonumber(color.g) or 255
            data.nameB = tonumber(color.b) or 255
            return data.nameR, data.nameG, data.nameB
        end
    end
    if data.nameR ~= nil and data.nameG ~= nil and data.nameB ~= nil then
        return tonumber(data.nameR) or 255, tonumber(data.nameG) or 255, tonumber(data.nameB) or 255
    end
    data.nameR, data.nameG, data.nameB = 255, 255, 255
    return 255, 255, 255
end

local function SessionKeys(session)
    if type(session) ~= "table" then
        return nil
    end
    return {
        tostring(session.potionRecipeKey or ""),
        tostring(session.potionKey or ""),
        tostring(session.rowId or ""),
    }
end

local function RowMatchesBrewSession(data, session)
    if type(data) ~= "table" or type(session) ~= "table" then
        return false
    end
    local sess = SessionKeys(session)
    if sess == nil then
        return false
    end
    local rowKeys = {
        tostring(data.potionRecipeKey or ""),
        tostring(data.id or ""),
        tostring(data.potionKey or ""),
    }
    for i = 1, #rowKeys do
        local rk = rowKeys[i]
        if rk ~= "" then
            for j = 1, #sess do
                if sess[j] ~= "" and rk == sess[j] then
                    return true
                end
            end
        end
    end
    return false
end

local function GetRowCraftUiState(data)
    local Brew = StockPiler.Brew
    if not Brew or type(data) ~= "table" then
        return "idle"
    end
    local session = Brew.GetSession and Brew.GetSession()
    if type(session) ~= "table" then
        return "idle"
    end
    local phase = tostring(session.phase or "idle")
    if phase == "idle" then
        return "idle"
    end
    if not RowMatchesBrewSession(data, session) then
        return "idle"
    end
    if phase == "loading" then
        return "load"
    end
    if phase == "loaded" then
        return "brew"
    end
    return "idle"
end

local function RowCraftableGreen(data)
    local Brew = StockPiler.Brew
    if Brew and Brew.RowCraftableGreen then
        return Brew.RowCraftableGreen(data)
    end
    return false
end

--- Load chip must not look enabled off a craftable number from a prior bag snap.
local function RowCraftableSnapCurrent(data)
    if type(data) ~= "table" then
        return false
    end
    local snapGen = 0
    if StockPiler.Inventory and StockPiler.Inventory.GetSnapGen then
        snapGen = tonumber(StockPiler.Inventory.GetSnapGen()) or 0
    end
    return (tonumber(data._craftableSnapGen) or -1) == snapGen
end

local function SetButtonTextColorAll(windowName, r, g, b)
    if not windowName or not DoesWindowExist(windowName) or type(ButtonSetTextColor) ~= "function" then
        return
    end
    local states = { 0, 1, 2, 3, 4 }
    if Button and Button.ButtonState then
        states = {
            Button.ButtonState.NORMAL or 0,
            Button.ButtonState.HIGHLIGHTED or 1,
            Button.ButtonState.PRESSED or 2,
            Button.ButtonState.PRESSED_HIGHLIGHTED or 3,
            Button.ButtonState.DISABLED or 4,
        }
    end
    for i = 1, #states do
        pcall(ButtonSetTextColor, windowName, states[i], r, g, b)
    end
end

local function ApplyRowBrewButton(btnWin, data)
    if not DoesWindowExist(btnWin) then
        return
    end
    if IsPlantWatchRow(data) or (type(data) == "table" and data.hideBrew == true) then
        WindowSetShowing(btnWin, false)
        return
    end
    WindowSetShowing(btnWin, true)
    -- One-click Brew (load+perform). Label is always Brew; color tracks readiness.
    ButtonSetText(btnWin, T("watch.chip_brew"))
    local craftableGreen = RowCraftableGreen(data)
    local state = GetRowCraftUiState(data)
    if state == "brew" then
        ButtonSetDisabledFlag(btnWin, false)
        SetButtonTextColorAll(btnWin, COLOR_OK[1], COLOR_OK[2], COLOR_OK[3])
        return
    end
    if state == "load" then
        ButtonSetDisabledFlag(btnWin, true)
        SetButtonTextColorAll(btnWin, COLOR_WARN[1], COLOR_WARN[2], COLOR_WARN[3])
        return
    end
    if not craftableGreen then
        ButtonSetDisabledFlag(btnWin, true)
        SetButtonTextColorAll(btnWin, COLOR_GRAY[1], COLOR_GRAY[2], COLOR_GRAY[3])
        return
    end
    -- Idle + craftable: yellow Brew (click loads then performs).
    ButtonSetDisabledFlag(btnWin, false)
    SetButtonTextColorAll(btnWin, COLOR_WARN[1], COLOR_WARN[2], COLOR_WARN[3])
end

local function PatchWatchRowsLiveCounts(rows)
    if type(rows) ~= "table" then
        return
    end
    if StockPiler.Planner and StockPiler.Planner.LiveRecount then
        -- Never WarmHave from Watch paint — FrameWork prewarm owns that.
        StockPiler.Planner.LiveRecount({
            allowWarmHave = false,
        })
        return
    end
    for i = 1, #rows do
        local row = rows[i]
        if type(row) == "table" then
            local uid = tonumber(row.uniqueID) or tonumber(row.outputUid) or 0
            if uid > 0 and StockPiler.Inventory and StockPiler.Inventory.CountByUid then
                local have = tonumber(StockPiler.Inventory.CountByUid(uid)) or 0
                row.potionHave = have
                row.stockText = towstring(tostring(have))
                local target = tonumber(row.target) or 0
                row.potionDeficit = math.max(0, target - have)
            end
        end
    end
end

local function BumpWatch()
    if StockPiler.Watch and StockPiler.Watch.BumpGen then
        StockPiler.Watch.BumpGen()
    end
    if StockPiler.PlanSnapshot and StockPiler.PlanSnapshot.Invalidate then
        StockPiler.PlanSnapshot.Invalidate()
    end
end

--- Soft demand change: bump the watch generation (it is in the craftable stamp
--- key), reconcile AutoGrow status, and queue a plan rebuild.
local function AfterWatchSettingsChanged()
    BumpWatch()
    -- Flip Enable AutoGrow <-> Restocking now (UI throttle / plan gap must not leave stale status).
    if StockPiler.Planner and StockPiler.Planner.ReconcileAutoGrowStatusesNow then
        StockPiler.Planner.ReconcileAutoGrowStatusesNow(StockPilerTabWatch.listData)
    end
    if StockPiler.Grow and StockPiler.Grow.InvalidatePlantQueue then
        StockPiler.Grow.InvalidatePlantQueue({ reason = "watch-settings" })
    end
    if StockPiler.Ui and StockPiler.Ui.ClearWatchTipCaches then
        StockPiler.Ui.ClearWatchTipCaches()
    else
        StockPilerTabWatch._statusTipCache = nil
    end
    local Sch = StockPiler.Scheduler
    if Sch and Sch.EnqueuePlanRebuild then
        Sch.EnqueuePlanRebuild({ urgent = true })
    end
    if StockPiler.Ui then
        -- Bypass 5s Watch flush throttle so status text updates on this click.
        if StockPiler.Ui.BypassWatchThrottle then
            StockPiler.Ui.BypassWatchThrottle()
        end
    end
    local Bus = StockPiler.EventBus
    if Bus and Bus.FireWatchUiDirty then
        Bus.FireWatchUiDirty({ immediate = true, recount = true, reason = "watch-settings" })
    end
    -- Optimistic row paint: do not wait for coalesced flush / plan rebuild.
    StockPilerTabWatch._rowPaintKey = nil
    if StockPilerTabWatch.UpdateRows then
        StockPilerTabWatch.UpdateRows({ keepVisible = true })
    end
    if StockPiler.Buy and StockPiler.Buy.IsEnabled and StockPiler.Buy.IsEnabled() == true then
        local VA = StockPiler.VendorAdapter
        if VA and VA.IsStoreOpen and VA.IsStoreOpen() == true then
            if StockPiler.Buy.InvalidateJobsCache then
                StockPiler.Buy.InvalidateJobsCache()
            end
            if Sch and Sch.WakeAutoBuy then
                Sch.WakeAutoBuy()
            end
        end
    end
end

--- /stp reset and other non-UI callers: same plan/queue sync as Watch toggles.
function StockPilerTabWatch.AfterWatchSettingsChanged()
    AfterWatchSettingsChanged()
end

--- Reserve/Budget: no PlanRebuild; clear money-gate + wake AutoBuy if store open.
local function AfterSoftMoneySetting()
    if StockPiler.Buy and StockPiler.Buy.OnMoneySettingsChanged then
        StockPiler.Buy.OnMoneySettingsChanged()
    end
    local Bus = StockPiler.EventBus
    if Bus and Bus.FireWatchUiDirty then
        Bus.FireWatchUiDirty({ immediate = true, reason = "money-settings" })
    end
    if Bus and Bus.FireFooterDirty then
        Bus.FireFooterDirty({ reason = "money-settings" })
    end
    StockPilerTabWatch.RefreshSkillGates()
    -- Soft money chips already updated via RefreshSkillGates; patch rows now too.
    StockPilerTabWatch._rowPaintKey = nil
    if StockPilerTabWatch.UpdateRows then
        StockPilerTabWatch.UpdateRows({ keepVisible = true })
    end
end

local function ApplyTargetOptimistic(data, target)
    if type(data) ~= "table" then
        return
    end
    target = tonumber(target) or 0
    data.target = target
    data.targetText = towstring(tostring(target))
    data.potionMin = target
    local have = tonumber(data.potionHave) or 0
    data.potionDeficit = math.max(0, target - have)
    StockPilerTabWatch._rowPaintKey = nil
    if StockPilerTabWatch.UpdateRows then
        StockPilerTabWatch.UpdateRows()
    end
end

local function PatchPlanSnapshotTarget(potionKey, target, have)
    if potionKey == nil then
        return
    end
    target = tonumber(target) or 0
    have = tonumber(have)
    local PS = StockPiler.PlanSnapshot
    local plan = PS and PS.Get and PS.Get()
    if type(plan) ~= "table" or type(plan.rows) ~= "table" then
        return
    end
    local keyStr = tostring(potionKey)
    for i = 1, #plan.rows do
        local row = plan.rows[i]
        if type(row) == "table" then
            local rowKey = row.potionRecipeKey or row.id or row.potionKey
            if rowKey ~= nil and tostring(rowKey) == keyStr then
                row.target = target
                row.potionMin = target
                local rowHave = have
                if rowHave == nil then
                    rowHave = tonumber(row.potionHave) or 0
                end
                row.potionDeficit = math.max(0, target - rowHave)
            end
        end
    end
end

local function TargetChangeIsDemandNoop(have, oldTarget, newTarget)
    have = tonumber(have) or 0
    oldTarget = tonumber(oldTarget) or 0
    newTarget = tonumber(newTarget) or 0
    local oldDeficit = math.max(0, oldTarget - have)
    local newDeficit = math.max(0, newTarget - have)
    if oldDeficit > 0 or newDeficit > 0 then
        return false
    end
    if (oldTarget > 0) ~= (newTarget > 0) then
        return false
    end
    return true
end

local function AfterTargetChipChanged(data, potionKey, oldTarget, newTarget)
    local have = tonumber(data and data.potionHave) or 0
    if TargetChangeIsDemandNoop(have, oldTarget, newTarget) then
        ApplyTargetOptimistic(data, newTarget)
        PatchPlanSnapshotTarget(potionKey, newTarget, have)
        return
    end
    ApplyTargetOptimistic(data, newTarget)
    AfterWatchSettingsChanged()
end

local function HasEnabledWatch()
    local watches = StockPiler.Watch and StockPiler.Watch.GetWatches and StockPiler.Watch.GetWatches()
    if type(watches) == "table" then
        for _, w in pairs(watches) do
            if type(w) == "table" and w.enabled == true then
                return true
            end
        end
    end
    if StockPiler.Watch and StockPiler.Watch.CountEnabledPlantWatches then
        if (tonumber(StockPiler.Watch.CountEnabledPlantWatches()) or 0) > 0 then
            return true
        end
    end
    return false
end

local function HasSkillUpWatchStatus()
    local SkillUp = StockPiler.SkillUp
    if SkillUp and SkillUp.ShouldShowWatchStatus and SkillUp.ShouldShowWatchStatus() == true then
        return true
    end
    local US = StockPiler.UpgradeSeed
    return US and US.ShouldShowWatchStatus and US.ShouldShowWatchStatus() == true
end

local function BuildVisibleList(opts)
    opts = type(opts) == "table" and opts or {}
    local prevList = StockPilerTabWatch.listData
    local prevOrder = StockPilerTabWatch.displayOrder
    local plan = nil
    local forcePlan = opts.forcePlan == true
    local hasContent = HasEnabledWatch() or HasSkillUpWatchStatus()
    -- Never sync-force Planner.Build from Watch paint (SP2 Flatten). Empty/stale
    -- plan: keep previous rows and enqueue a coalesced rebuild.
    local Sch = StockPiler.Scheduler
    local holdBuild = (Sch and Sch.IsSuppressed and Sch.IsSuppressed() == true)
        or (Sch and Sch.IsPlanRebuildPending and Sch.IsPlanRebuildPending() == true)
    local snap = StockPiler.PlanSnapshot and StockPiler.PlanSnapshot.Get
        and StockPiler.PlanSnapshot.Get()
    local snapRows = type(snap) == "table" and snap.rows or nil
    local snapEmpty = type(snapRows) ~= "table" or #snapRows == 0
    if hasContent and (forcePlan or snapEmpty) and Sch and Sch.EnqueuePlanRebuild then
        Sch.EnqueuePlanRebuild({ nudge = holdBuild or not forcePlan })
    end
    if StockPiler.Planner and StockPiler.Planner.GetOrBuild then
        plan = StockPiler.Planner.GetOrBuild({ refresh = false })
    elseif StockPiler.PlanSnapshot and StockPiler.PlanSnapshot.Get then
        plan = StockPiler.PlanSnapshot.Get()
    end
    local rows = type(plan) == "table" and plan.rows or nil
    -- Soft Invalidate keeps stale plan.rows; optimistic eye add/remove already mutated
    -- listData. Prefer that until the coalesced rebuild lands a fresh cache key.
    local PS = StockPiler.PlanSnapshot
    local cacheStale = PS and PS.GetCacheKey and PS.GetCacheKey() == nil
    local preferPrev = (cacheStale == true or holdBuild == true)
        and type(prevList) == "table" and #prevList > 0
    if preferPrev then
        PatchWatchRowsLiveCounts(prevList)
        BindSortedList(prevList)
        return
    end
    if type(rows) ~= "table" or #rows == 0 then
        local keepPrev = type(prevList) == "table" and #prevList > 0
        if keepPrev then
            local keep = type(plan) ~= "table"
            if not keep and hasContent then
                keep = true
            end
            if keep then
                PatchWatchRowsLiveCounts(prevList)
                -- Prefer current snapshot rows when they exist (avoid orphaned stale listData).
                local snapNow = StockPiler.PlanSnapshot and StockPiler.PlanSnapshot.Get
                    and StockPiler.PlanSnapshot.Get()
                local snapRowsNow = type(snapNow) == "table" and snapNow.rows or nil
                if type(snapRowsNow) == "table" and #snapRowsNow > 0
                    and not (PS and PS.GetCacheKey and PS.GetCacheKey() == nil)
                then
                    PatchWatchRowsLiveCounts(snapRowsNow)
                    BindSortedList(snapRowsNow)
                else
                    BindSortedList(prevList)
                end
                return
            end
        end
        rows = {}
    end
    PatchWatchRowsLiveCounts(rows)
    BindSortedList(rows)
end

local function UpdateEnableCheckbox()
    if not DoesWindowExist(ENABLE_WIN) then
        return
    end
    local canGrow = CanAutoGrowUi()
    local row = CharRow(false)
    local on = canGrow and type(row) == "table" and row.autoGrowEnabled == true
    syncingUi = true
    ButtonSetCheckButtonFlag(ENABLE_WIN, true)
    ButtonSetPressedFlag(ENABLE_WIN, on)
    ButtonSetDisabledFlag(ENABLE_WIN, not canGrow)
    syncingUi = false
end

local function UpdateAdditivesCheckbox()
    if not DoesWindowExist(ADDITIVES_WIN) then
        return
    end
    local canGrow = CanAutoGrowUi()
    local row = CharRow(false)
    local on = canGrow and type(row) == "table" and row.autoGrowAdditives == true
    syncingUi = true
    ButtonSetCheckButtonFlag(ADDITIVES_WIN, true)
    ButtonSetPressedFlag(ADDITIVES_WIN, on)
    ButtonSetDisabledFlag(ADDITIVES_WIN, not canGrow)
    syncingUi = false
end

local function UpdateAutoBuyCheckbox()
    if not DoesWindowExist(AUTOBUY_WIN) then
        return
    end
    local canBuy = CanAutoBuyUi()
    local row = CharRow(false)
    local on = canBuy and type(row) == "table" and row.autoBuyEnabled == true
    syncingUi = true
    ButtonSetCheckButtonFlag(AUTOBUY_WIN, true)
    ButtonSetPressedFlag(AUTOBUY_WIN, on)
    ButtonSetDisabledFlag(AUTOBUY_WIN, not canBuy)
    syncingUi = false
end

local function UpdateAutoBrewCheckbox()
    if not DoesWindowExist(AUTOBREW_WIN) then
        return
    end
    local canBrew = CanAutoBrewUi()
    local row = CharRow(false)
    local on = canBrew and type(row) == "table" and row.autoBrewEnabled == true
    syncingUi = true
    ButtonSetCheckButtonFlag(AUTOBREW_WIN, true)
    ButtonSetPressedFlag(AUTOBREW_WIN, on)
    ButtonSetDisabledFlag(AUTOBREW_WIN, not canBrew)
    syncingUi = false
end

local function UpdateOptimisticModeCheckbox()
    if not DoesWindowExist(OPTIMISTIC_MODE_WIN) then
        return
    end
    local row = CharRow(false)
    local on = type(row) ~= "table" or row.watchOptimisticOutcomeEstimate ~= false
    syncingUi = true
    ButtonSetCheckButtonFlag(OPTIMISTIC_MODE_WIN, true)
    ButtonSetPressedFlag(OPTIMISTIC_MODE_WIN, on)
    syncingUi = false
end

local HUD_SCALE_MIN = 0.5
local HUD_SCALE_MAX = 2.0
local HUD_SCALE_STEP = 0.25

local function FormatHudScale(n)
    n = tonumber(n) or HUD_SCALE_MIN
    return string.format("%.2f", n)
end

local function SnapHudScale(n)
    n = tonumber(n) or HUD_SCALE_MIN
    n = math.floor((n / HUD_SCALE_STEP) + 0.5) * HUD_SCALE_STEP
    if n < HUD_SCALE_MIN then
        n = HUD_SCALE_MIN
    elseif n > HUD_SCALE_MAX then
        n = HUD_SCALE_MAX
    end
    return n
end

local function UpdateHudScaleChip()
    local CB = StockPiler.CraftButton
    local scale = CB and CB.GetScale and CB.GetScale() or HUD_SCALE_MIN
    local visible = true
    if CB and CB.IsVisible then
        visible = CB.IsVisible() == true
    end
    local valueWin = "SPTabWatchHudScaleChipValue"
    local chipWin = "SPTabWatchHudScaleChip"
    if DoesWindowExist(valueWin) then
        LabelSetText(valueWin, towstring(FormatHudScale(scale)))
        if visible == true then
            LabelSetTextColor(valueWin, 255, 255, 255)
        else
            LabelSetTextColor(valueWin, COLOR_GRAY[1], COLOR_GRAY[2], COLOR_GRAY[3])
        end
    end
    if DoesWindowExist(chipWin) then
        TintStepper(chipWin .. "Bg")
        if type(WindowSetHandleInput) == "function" then
            WindowSetHandleInput(chipWin, visible == true)
        end
    end
end

local function UpdateHudButtonCheckboxes()
    local CB = StockPiler.CraftButton
    local visible = true
    if CB and CB.IsVisible then
        visible = CB.IsVisible() == true
    end
    local Macro = StockPiler.Macro
    local craftMacroOn = true
    if Macro and Macro.IsCraftMacroEnabled then
        craftMacroOn = Macro.IsCraftMacroEnabled() == true
    end
    if DoesWindowExist(HUD_BUTTON_WIN) then
        syncingUi = true
        ButtonSetCheckButtonFlag(HUD_BUTTON_WIN, true)
        ButtonSetPressedFlag(HUD_BUTTON_WIN, visible == true)
        ButtonSetDisabledFlag(HUD_BUTTON_WIN, false)
        syncingUi = false
    end
    if DoesWindowExist(CRAFT_MACRO_WIN) then
        syncingUi = true
        ButtonSetCheckButtonFlag(CRAFT_MACRO_WIN, true)
        ButtonSetPressedFlag(CRAFT_MACRO_WIN, craftMacroOn == true)
        ButtonSetDisabledFlag(CRAFT_MACRO_WIN, false)
        syncingUi = false
    end
    if DoesWindowExist("SPTabWatchCraftMacroLabel") then
        LabelSetTextColor("SPTabWatchCraftMacroLabel", 255, 255, 255)
    end
    UpdateHudScaleChip()
end

local function AdjustHudScale(dir)
    local CB = StockPiler.CraftButton
    if not (CB and CB.IsVisible and CB.IsVisible() == true) then
        UpdateHudScaleChip()
        return
    end
    if not (CB.GetScale and CB.SetScale) then
        return
    end
    local cur = SnapHudScale(CB.GetScale())
    local nextVal = SnapHudScale(cur + (tonumber(dir) or 0) * HUD_SCALE_STEP)
    if nextVal == cur then
        UpdateHudScaleChip()
        return
    end
    local ok = CB.SetScale(nextVal)
    if ok then
        NotifySettings(T("watch.setting_eq", {
            label = T("watch.setting.hud_scale"),
            value = FormatHudScale(nextVal),
        }))
    end
    UpdateHudScaleChip()
end

local function SkillUpLevelKinds()
    local SkillUp = StockPiler.SkillUp
    if not SkillUp or not SkillUp.CultLevelKind or not SkillUp.ApoLevelKind then
        return "missing", "missing"
    end
    return SkillUp.CultLevelKind(), SkillUp.ApoLevelKind()
end

local function SkillUpWhyText(kind, skillName)
    if kind == "max" then
        return T("tip.watch.skillup_why_max", { skill = skillName })
    end
    if kind == "ready" then
        return T("tip.watch.skillup_why_ready", { skill = skillName })
    end
    return T("tip.watch.skillup_why_missing", { skill = skillName })
end

local function UpdateSkillUpCheckboxes()
    local SkillUp = StockPiler.SkillUp
    if SkillUp and SkillUp.DropToggleIfUnlearned then
        SkillUp.DropToggleIfUnlearned()
    end
    if SkillUp and SkillUp.AdoptReadySkills then
        SkillUp.AdoptReadySkills()
    end
    local cultKind, apoKind = SkillUpLevelKinds()
    local cultReady = cultKind == "ready"
    local apoReady = apoKind == "ready"
    local applicable = cultReady or apoReady
    local cultOn = SkillUp and SkillUp.IsCultToggleOn and SkillUp.IsCultToggleOn() == true
    local apoOn = SkillUp and SkillUp.IsApoToggleOn and SkillUp.IsApoToggleOn() == true
    local on = (cultReady and cultOn) or (apoReady and apoOn)
    local label = "SPTabWatchSkillUpSkillsLabel"

    if DoesWindowExist(SKILLUP_SKILLS_WIN) then
        WindowSetShowing(SKILLUP_SKILLS_WIN, true)
        syncingUi = true
        ButtonSetCheckButtonFlag(SKILLUP_SKILLS_WIN, true)
        ButtonSetPressedFlag(SKILLUP_SKILLS_WIN, applicable and on)
        ButtonSetDisabledFlag(SKILLUP_SKILLS_WIN, not applicable)
        syncingUi = false
    end
    if DoesWindowExist(label) then
        WindowSetShowing(label, true)
        LabelSetTextColor(label, 255, 255, 255)
    end
end

local function UpdateSeedBufferEnableCheckbox()
    if not DoesWindowExist(SEED_BUFFER_ENABLE_WIN) then
        return
    end
    local canGrow = CanAutoGrowUi()
    local row = CharRow(false)
    local on = canGrow and (type(row) ~= "table" or row.growSeedBufferEnabled ~= false)
    syncingUi = true
    ButtonSetCheckButtonFlag(SEED_BUFFER_ENABLE_WIN, true)
    ButtonSetPressedFlag(SEED_BUFFER_ENABLE_WIN, on)
    ButtonSetDisabledFlag(SEED_BUFFER_ENABLE_WIN, not canGrow)
    syncingUi = false
end

local function UpdateUpgradeSeedsCheckbox()
    if not DoesWindowExist(UPGRADE_SEEDS_WIN) then
        return
    end
    local canGrow = CanAutoGrowUi()
    local US = StockPiler.UpgradeSeed
    local on = canGrow and US and US.IsEnabled and US.IsEnabled() == true
    syncingUi = true
    ButtonSetCheckButtonFlag(UPGRADE_SEEDS_WIN, true)
    ButtonSetPressedFlag(UPGRADE_SEEDS_WIN, on == true)
    ButtonSetDisabledFlag(UPGRADE_SEEDS_WIN, not canGrow)
    syncingUi = false
end

local function UpdateSeedBufferLabel()
    local buf = StockPiler.Watch and StockPiler.Watch.GetSeedBufferMin
        and StockPiler.Watch.GetSeedBufferMin() or 5
    SetChipNumber("SPTabWatchSeedBufferChipValue", "SPTabWatchSeedBufferChip", buf)
end

local function UpdateAutoBuyChips()
    local row = CharRow(false)
    local reserve = type(row) == "table" and tonumber(row.autoBuyReserveGold) or 10
    local budget = type(row) == "table" and tonumber(row.autoBuyBudgetGold) or 50
    SetChipNumber("SPTabWatchReserveChipValue", "SPTabWatchReserveChip", reserve)
    SetChipNumber("SPTabWatchBudgetChipValue", "SPTabWatchBudgetChip", budget)

    local spent = 0
    local exhausted = false
    local Buy = StockPiler.Buy
    if Buy and Buy.GetSpentBrass then
        spent = tonumber(Buy.GetSpentBrass()) or 0
    elseif type(row) == "table" then
        spent = tonumber(row.autoBuySpentBrass) or 0
    end
    local budgetBrass = budget * ((Buy and Buy.BRASS_PER_GOLD) or 10000)
    exhausted = spent >= budgetBrass
    local c = exhausted and COLOR_BLOCK or COLOR_OK
    if DoesWindowExist("SPTabWatchBudgetChipValue") then
        LabelSetTextColor("SPTabWatchBudgetChipValue", c[1], c[2], c[3])
    end
    if DoesWindowExist("SPTabWatchBudgetChipBg") and WindowSetTintColor then
        if exhausted then
            WindowSetTintColor("SPTabWatchBudgetChipBg", 90, 30, 30)
        else
            WindowSetTintColor("SPTabWatchBudgetChipBg", 30, 70, 30)
        end
    end
    if DoesWindowExist("SPTabWatchBudgetReset") then
        local canReset = spent > 0
        ButtonSetDisabledFlag("SPTabWatchBudgetReset", not canReset)
        if canReset then
            -- Match per-row Load/Brew: gold when actionable.
            SetButtonTextColorAll("SPTabWatchBudgetReset", COLOR_WARN[1], COLOR_WARN[2], COLOR_WARN[3])
        else
            SetButtonTextColorAll("SPTabWatchBudgetReset", COLOR_GRAY[1], COLOR_GRAY[2], COLOR_GRAY[3])
        end
    end
end

function StockPilerTabWatch.RefreshAutoBuyMoneyUi()
    UpdateAutoBuyChips()
end

local function RowDataFromActiveChild()
    local win = SystemData.ActiveWindow and SystemData.ActiveWindow.name
    for _ = 1, 6 do
        if win == nil or win == "" then
            break
        end
        local rowIndex = WindowGetId(win)
        if rowIndex and rowIndex > 0 and DoesWindowExist("SPTabWatchList") then
            local dataIndex = ListBoxGetDataIndex("SPTabWatchList", rowIndex)
            local data = type(StockPilerTabWatch.listData) == "table"
                and StockPilerTabWatch.listData[dataIndex]
                or nil
            -- keepVisible paint can show rows while PopulatorIndices is empty;
            -- fall back to rowIndex so Target/Prio chips stay clickable.
            if data == nil and type(StockPilerTabWatch.listData) == "table" then
                data = StockPilerTabWatch.listData[rowIndex]
            end
            if data then
                return data, win
            end
        end
        if type(WindowGetParent) == "function" then
            win = WindowGetParent(win)
        else
            break
        end
    end
    return nil
end

local function AdjustTarget(data, delta)
    if type(data) ~= "table" then
        return
    end
    if IsEphemeralWatchRow(data) then
        return
    end
    if IsPlantWatchRow(data) then
        local plantKey = data.plantKey or data.id or data.potionKey
        local oldTarget = tonumber(data.target) or 0
        local newTarget = Clamp(oldTarget + delta, 0, TARGET_MAX)
        if newTarget == oldTarget then
            return
        end
        if StockPiler.Watch and StockPiler.Watch.SetPlantTarget then
            StockPiler.Watch.SetPlantTarget(plantKey, newTarget)
        end
        data.target = newTarget
        data.potionMin = newTarget
        data.targetText = towstring(tostring(newTarget))
        local have = tonumber(data.potionHave) or 0
        data.potionDeficit = math.max(0, newTarget - have)
        AfterWatchSettingsChanged()
        StockPilerTabWatch._rowPaintKey = nil
        StockPilerTabWatch.UpdateRows()
        return
    end
    local potionKey = data.potionRecipeKey or data.id or data.potionKey
    local oldTarget = tonumber(data.target) or 0
    local newTarget = Clamp(oldTarget + delta, 0, TARGET_MAX)
    if newTarget == oldTarget then
        return
    end
    if StockPiler.Watch and StockPiler.Watch.SetTarget then
        StockPiler.Watch.SetTarget(potionKey, newTarget)
    end
    if newTarget > 0 and StockPiler.Watch and StockPiler.Watch.SetEnabled then
        local watch = StockPiler.Watch.EnsureWatch and StockPiler.Watch.EnsureWatch(potionKey)
        if type(watch) == "table" and watch.enabled ~= true then
            StockPiler.Watch.SetEnabled(potionKey, true)
        end
    end
    AfterTargetChipChanged(data, potionKey, oldTarget, newTarget)
end

--- Patch plan + listData tiers, re-sort potion watches, polish shared contest (no BuildFull).
local function AfterPrioritySoftChange(potionKey, newTier)
    newTier = tonumber(newTier) or 1
    local keyStr = tostring(potionKey or "")
    local function patchRows(rows)
        if type(rows) ~= "table" or keyStr == "" then
            return
        end
        for i = 1, #rows do
            local row = rows[i]
            if type(row) == "table"
                and not IsPlantWatchRow(row)
                and not IsEphemeralWatchRow(row)
            then
                local rowKey = row.potionRecipeKey or row.id or row.potionKey
                if rowKey ~= nil and tostring(rowKey) == keyStr then
                    row.priorityTier = newTier
                    row.priorityTierText = towstring(tostring(newTier))
                end
            end
        end
    end
    local PS = StockPiler.PlanSnapshot
    local plan = PS and PS.Get and PS.Get()
    local planRows = type(plan) == "table" and plan.rows or nil
    patchRows(planRows)
    local listData = StockPilerTabWatch.listData
    if listData ~= planRows then
        patchRows(listData)
    end
    -- Display-only reorder (do not mutate Planner snapshot order).
    if type(listData) == "table" then
        if listData == planRows then
            BindSortedList(planRows)
            listData = StockPilerTabWatch.listData
        else
            SortWatchRows(listData)
            StockPilerTabWatch.displayOrder = {}
            for i = 1, #listData do
                StockPilerTabWatch.displayOrder[i] = i
            end
        end
    end
    if StockPiler.Planner and StockPiler.Planner.AfterPrioritySoftChange then
        StockPiler.Planner.AfterPrioritySoftChange(listData)
    end
    StockPilerTabWatch._rowPaintKey = nil
    if DoesWindowExist("SPTabWatchList") and type(StockPilerTabWatch.displayOrder) == "table" then
        local Brew = StockPiler.Brew
        local Orch = StockPiler.Orchestrator
        local brewHold = (Brew and Brew.IsWatchUiHold and Brew.IsWatchUiHold() == true)
            or (Orch and Orch.IsBrewSessionActive and Orch.IsBrewSessionActive() == true)
        local indices = SPTabWatchList and SPTabWatchList.PopulatorIndices
        local hasPopulated = type(indices) == "table" and next(indices) ~= nil
        if not hasPopulated then
            ListBoxSetDisplayOrder("SPTabWatchList", StockPilerTabWatch.displayOrder)
        else
            StockPilerTabWatch.UpdateRows({ keepVisible = true })
        end
    elseif StockPilerTabWatch.UpdateRows then
        StockPilerTabWatch.UpdateRows({ keepVisible = true })
    end
end

local function AdjustPriority(data, delta)
    if type(data) ~= "table" or IsPlantWatchRow(data) or IsEphemeralWatchRow(data) then
        return
    end
    local potionKey = data.potionRecipeKey or data.id or data.potionKey
    if potionKey == nil or not StockPiler.Watch or not StockPiler.Watch.BumpPriorityTier then
        return
    end
    local oldTier = tonumber(data.priorityTier)
    if oldTier == nil and StockPiler.Watch.GetPriorityTier then
        oldTier = StockPiler.Watch.GetPriorityTier(potionKey)
    end
    oldTier = tonumber(oldTier) or 1
    local watch = StockPiler.Watch.BumpPriorityTier(potionKey, delta)
    local newTier = tonumber(watch and watch.priorityTier) or oldTier
    if StockPiler.Watch.GetPriorityTier then
        newTier = StockPiler.Watch.GetPriorityTier(potionKey)
    end
    if newTier == oldTier then
        return
    end
    data.priorityTier = newTier
    data.priorityTierText = towstring(tostring(newTier))
    -- Soft path: prio does not change craftable; avoid BumpWatch / PlanRebuild.
    AfterPrioritySoftChange(potionKey, newTier)
end

function StockPilerTabWatch.Initialize()
    LabelSetText("SPTabWatchBannerTitle", T("watch.banner_title"))
    LabelSetText("SPTabWatchBannerText", T("watch.banner_text"))
    LabelSetText("SPTabWatchEnableLabel", T("watch.enable_autogrow"))
    LabelSetText("SPTabWatchAdditivesLabel", T("watch.use_additives"))
    LabelSetText("SPTabWatchSeedBufferLabel", T("watch.seed_buffer_label"))
    LabelSetText("SPTabWatchAutoBuyLabel", T("watch.autobuy_label"))
    if DoesWindowExist("SPTabWatchAutoBrewLabel") then
        LabelSetText("SPTabWatchAutoBrewLabel", T("watch.autobrew_label"))
    end
    LabelSetText("SPTabWatchOptimisticModeLabel", T("watch.optimistic_mode_label"))
    LabelSetText("SPTabWatchReserveLabel", T("watch.reserve_label"))
    LabelSetText("SPTabWatchBudgetLabel", T("watch.budget_label"))
    if DoesWindowExist("SPTabWatchBudgetReset") then
        ButtonSetText("SPTabWatchBudgetReset", T("watch.budget_reset"))
    end
    if DoesWindowExist("SPTabWatchSkillUpSkillsLabel") then
        LabelSetText("SPTabWatchSkillUpSkillsLabel", T("watch.skillup_skills"))
    end
    if DoesWindowExist("SPTabWatchUpgradeSeedsLabel") then
        LabelSetText("SPTabWatchUpgradeSeedsLabel", T("watch.upgrade_seeds"))
    end
    if DoesWindowExist("SPTabWatchHudButtonLabel") then
        LabelSetText("SPTabWatchHudButtonLabel", T("watch.hud_button_label"))
    end
    if DoesWindowExist("SPTabWatchCraftMacroLabel") then
        LabelSetText("SPTabWatchCraftMacroLabel", T("watch.craft_macro_label"))
    end
    TintStepper("SPTabWatchSeedBufferChipBg")
    TintStepper("SPTabWatchReserveChipBg")
    TintStepper("SPTabWatchBudgetChipBg")
    TintStepper("SPTabWatchHudScaleChipBg")
    UpdateSortHeaders()
    StockPilerTabWatch.RefreshSkillGates()
    if StockPilerTabWatch.PrimeRowChrome then
        StockPilerTabWatch.PrimeRowChrome()
    end
end

function StockPilerTabWatch.OnSortColumn()
    local id = WindowGetId(SystemData.ActiveWindow.name)
    local col = SORT_IDS[id]
    if not col then
        return
    end
    local s = GetSettings()
    if type(s) ~= "table" then
        return
    end
    if s.watchSortColumn == col then
        s.watchSortAscending = not (s.watchSortAscending ~= false)
    else
        s.watchSortColumn = col
        s.watchSortAscending = true
    end
    s.watchSortUserSet = true
    StockPilerTabWatch.Refresh({ forceRebind = true })
end

function StockPilerTabWatch.RefreshSkillGates()
    if not DoesWindowExist(TAB_ROOT) then
        return
    end
    local canGrow = CanAutoGrowUi()
    local canBuy = CanAutoBuyUi()
    local canBrew = CanAutoBrewUi()
    local row = CharRow(false)
    local autoGrow = canGrow and type(row) == "table" and row.autoGrowEnabled == true
    local additives = canGrow and type(row) == "table" and row.autoGrowAdditives == true
    local autoBuy = canBuy and type(row) == "table" and row.autoBuyEnabled == true
    local autoBrew = canBrew and type(row) == "table" and row.autoBrewEnabled == true
    local optimistic = type(row) ~= "table" or row.watchOptimisticOutcomeEstimate ~= false
    local seedBufOn = canGrow and (type(row) ~= "table" or row.growSeedBufferEnabled ~= false)
    local seedBuf = StockPiler.Watch and StockPiler.Watch.GetSeedBufferMin and StockPiler.Watch.GetSeedBufferMin() or 5
    local reserve = type(row) == "table" and tonumber(row.autoBuyReserveGold) or 10
    local budget = type(row) == "table" and tonumber(row.autoBuyBudgetGold) or 50
    local spent = type(row) == "table" and tonumber(row.autoBuySpentBrass) or 0
    local SkillUp = StockPiler.SkillUp
    local skillUpCult = SkillUp and SkillUp.IsCultEnabled and SkillUp.IsCultEnabled() == true
    local skillUpApo = SkillUp and SkillUp.IsApoEnabled and SkillUp.IsApoEnabled() == true
    local cultVis = SkillUp and SkillUp.IsCultVisible and SkillUp.IsCultVisible() == true
    local apoVis = SkillUp and SkillUp.IsApoVisible and SkillUp.IsApoVisible() == true
    local UpgradeSeed = StockPiler.UpgradeSeed
    local upgradeOn = UpgradeSeed and UpgradeSeed.IsEnabled and UpgradeSeed.IsEnabled() == true
    local CB = StockPiler.CraftButton
    local hudVis = CB and CB.IsVisible and CB.IsVisible() == true
    local hudTimer = CB and CB.IsShowTimer and CB.IsShowTimer() == true
    local hudScale = CB and CB.GetScale and CB.GetScale() or 1
    local Macro = StockPiler.Macro
    local craftMacroOn = Macro and Macro.IsCraftMacroEnabled and Macro.IsCraftMacroEnabled() == true
    local gatesKey = table.concat({
        tostring(canGrow), tostring(canBuy), tostring(canBrew), tostring(autoGrow), tostring(additives),
        tostring(autoBuy), tostring(autoBrew), tostring(optimistic), tostring(seedBufOn), tostring(seedBuf),
        tostring(reserve), tostring(budget), tostring(spent),
        tostring(cultVis), tostring(apoVis), tostring(skillUpCult), tostring(skillUpApo),
        tostring(upgradeOn),
        tostring(hudVis), tostring(craftMacroOn), tostring(hudTimer), tostring(hudScale),
    }, ":")
    if StockPilerTabWatch._skillGatesKey == gatesKey then
        return
    end
    StockPilerTabWatch._skillGatesKey = gatesKey
    local prev = StockPilerTabWatch._lastCanAutoGrow
    StockPilerTabWatch._lastCanAutoGrow = canGrow
    UpdateEnableCheckbox()
    UpdateAdditivesCheckbox()
    UpdateAutoBuyCheckbox()
    UpdateAutoBrewCheckbox()
    UpdateOptimisticModeCheckbox()
    UpdateHudButtonCheckboxes()
    UpdateSeedBufferEnableCheckbox()
    UpdateUpgradeSeedsCheckbox()
    UpdateSeedBufferLabel()
    UpdateAutoBuyChips()
    UpdateSkillUpCheckboxes()
    if prev == false and canGrow == true then
        if StockPiler.Ui and StockPiler.Ui.MarkWatchUiDirty then
            StockPiler.Ui.MarkWatchUiDirty()
        end
    end
end

--- Force HUD Button / Craft Macro / scale chip to match settings (e.g. /stp button reset).
function StockPilerTabWatch.RefreshHudButtonUi()
    if not DoesWindowExist(TAB_ROOT) then
        return
    end
    UpdateHudButtonCheckboxes()
end

local function ApplyOptimisticWatchRowFilter(filterRows)
    if type(filterRows) ~= "function" then
        return false
    end
    local list = StockPilerTabWatch.listData
    local newList, listChanged = filterRows(list)
    local snap = StockPiler.PlanSnapshot and StockPiler.PlanSnapshot.Get
        and StockPiler.PlanSnapshot.Get()
    local snapChanged = false
    if type(snap) == "table" and type(snap.rows) == "table" then
        if snap.rows == list and listChanged then
            snap.rows = newList
            snapChanged = true
        else
            local newSnap, ch = filterRows(snap.rows)
            if ch then
                snap.rows = newSnap
                snapChanged = true
            end
        end
    end
    if listChanged then
        StockPilerTabWatch.listData = newList
        StockPilerTabWatch.displayOrder = {}
        for i = 1, #newList do
            StockPilerTabWatch.displayOrder[i] = i
        end
        StockPilerTabWatch._rowPaintKey = nil
    end
    return listChanged or snapChanged
end

local function RowMatchesPotionKey(row, potionKey)
    if type(row) ~= "table" or potionKey == nil or potionKey == "" then
        return false
    end
    local keys = {
        row.potionRecipeKey,
        row.id,
        row.potionKey,
        row.potionBaseKey,
    }
    for i = 1, #keys do
        if keys[i] ~= nil and tostring(keys[i]) == potionKey then
            return true
        end
    end
    return false
end

local function RowMatchesPlantKey(row, plantKey)
    if type(row) ~= "table" or plantKey == nil or plantKey == "" then
        return false
    end
    local keys = {
        row.plantKey,
        row.id,
        row.potionKey,
    }
    for i = 1, #keys do
        if keys[i] ~= nil and tostring(keys[i]) == plantKey then
            return true
        end
    end
    return false
end

--- Drop a disabled potion/plant watch from live Watch listData (+ plan rows if shared).
local function OptimisticRemoveWatchRow(opts)
    opts = type(opts) == "table" and opts or {}
    local potionKey = opts.potionKey ~= nil and tostring(opts.potionKey) or nil
    local plantKey = opts.plantKey ~= nil and tostring(opts.plantKey) or nil
    if potionKey == nil and plantKey == nil then
        return false
    end
    return ApplyOptimisticWatchRowFilter(function(rows)
        if type(rows) ~= "table" then
            return rows, false
        end
        local out = {}
        local changed = false
        for i = 1, #rows do
            local row = rows[i]
            local drop = false
            if type(row) == "table" then
                if plantKey ~= nil and (row.kind == "plant" or row.isPlantWatch == true) then
                    drop = RowMatchesPlantKey(row, plantKey)
                elseif potionKey ~= nil and row.kind ~= "plant" and row.isPlantWatch ~= true then
                    drop = RowMatchesPotionKey(row, potionKey)
                end
            end
            if drop then
                changed = true
            else
                out[#out + 1] = row
            end
        end
        if changed then
            return out, true
        end
        return rows, false
    end)
end

--- Stub row so Watch keeps the new eye-on entry while plan rebuild is in flight.
--- (Disable already had OptimisticRemove; enable used to wait on PLAN_UPDATED.)
local function BuildOptimisticPotionWatchRow(potionKey)
    potionKey = tostring(potionKey or "")
    if potionKey == "" then
        return nil
    end
    local RS = StockPiler.RecipeSpec
    local resolved = RS and RS.ResolveWatchPotion and RS.ResolveWatchPotion(potionKey) or nil
    local potion = resolved and resolved.potion
    local outputUid = (type(resolved) == "table" and tonumber(resolved.outputUid)) or 0
    if outputUid <= 0 then
        outputUid = tonumber(string.match(potionKey, "^uid:(%d+)")) or 0
    end
    local watch = StockPiler.Watch and StockPiler.Watch.GetWatch
        and StockPiler.Watch.GetWatch(potionKey) or nil
    local have = 0
    if StockPiler.Catalog and StockPiler.Catalog.PotionHaveCombined and type(potion) == "table" then
        have = tonumber(StockPiler.Catalog.PotionHaveCombined(potion)) or 0
    elseif StockPiler.Inventory and StockPiler.Inventory.CountByUid and outputUid > 0 then
        have = tonumber(StockPiler.Inventory.CountByUid(outputUid)) or 0
    end
    local min = tonumber(watch and watch.targetStock) or 40
    local prio = 1
    if StockPiler.Watch and StockPiler.Watch.GetPriorityTier then
        prio = tonumber(StockPiler.Watch.GetPriorityTier(potionKey)) or 1
    else
        prio = tonumber(watch and watch.priorityTier) or 1
    end
    local name = (type(potion) == "table" and potion.name)
        or towstring(tostring(outputUid > 0 and outputUid or potionKey))
    local iconNum = (type(potion) == "table" and tonumber(potion.iconNum)) or 0
    local recipeSpecKey = type(resolved) == "table" and resolved.recipeSpecKey or nil
    return {
        id = potionKey,
        potionKey = potionKey,
        potionRecipeKey = potionKey,
        potionBaseKey = (type(resolved) == "table" and resolved.potionKey)
            or ("uid:" .. tostring(outputUid)),
        recipeSpecKey = recipeSpecKey,
        uniqueID = outputUid,
        name = name,
        iconNum = iconNum,
        potionHave = have,
        stockText = towstring(tostring(have)),
        potionMin = min,
        target = min,
        targetText = towstring(tostring(min)),
        potionDeficit = math.max(0, min - have),
        craftable = 0,
        craftableText = T("ui.dash"),
        autoGrow = type(watch) == "table" and watch.autoGrow == true,
        priorityTier = prio,
        priorityTierText = towstring(tostring(prio)),
        hasRecipe = recipeSpecKey ~= nil and recipeSpecKey ~= "",
        statusText = T("ui.dash"),
        statusKey = "",
        _optimisticWatch = true,
    }
end

local function BuildOptimisticPlantWatchRow(plantKey)
    plantKey = tostring(plantKey or "")
    if plantKey == "" then
        return nil
    end
    local Watch = StockPiler.Watch
    local plantUid = Watch and Watch.ParsePlantKey and Watch.ParsePlantKey(plantKey) or 0
    plantUid = tonumber(plantUid) or 0
    if plantUid <= 0 then
        plantUid = tonumber(string.match(plantKey, "^plant:(%d+)")) or 0
    end
    local watch = Watch and Watch.GetPlantWatch and Watch.GetPlantWatch(plantKey) or nil
    local have = 0
    if StockPiler.Inventory and StockPiler.Inventory.CountByUid and plantUid > 0 then
        have = tonumber(StockPiler.Inventory.CountByUid(plantUid)) or 0
    end
    local target = tonumber(watch and watch.targetStock) or 40
    local name = towstring(tostring(plantUid > 0 and plantUid or plantKey))
    local iconNum = 0
    local itemData = nil
    if StockPiler.Items and StockPiler.Items.AsItemData and plantUid > 0 then
        itemData = StockPiler.Items.AsItemData(plantUid)
    end
    if type(itemData) == "table" then
        if itemData.name ~= nil then
            name = itemData.name
        end
        iconNum = tonumber(itemData.iconNum) or 0
    end
    return {
        kind = "plant",
        isPlantWatch = true,
        id = plantKey,
        plantKey = plantKey,
        potionKey = plantKey,
        potionRecipeKey = plantKey,
        plantUid = plantUid,
        uniqueID = plantUid,
        name = name,
        iconNum = iconNum,
        itemData = itemData,
        potionHave = have,
        stockText = towstring(tostring(have)),
        potionMin = target,
        target = target,
        targetText = towstring(tostring(target)),
        potionDeficit = math.max(0, target - have),
        craftable = 0,
        craftableText = L"",
        autoGrow = type(watch) == "table" and watch.autoGrow == true,
        priorityTierText = L"-",
        plantPrioSentinel = true,
        hideBrew = true,
        statusText = T("ui.dash"),
        statusKey = "",
        _optimisticWatch = true,
    }
end

local function OptimisticAddWatchRow(opts)
    opts = type(opts) == "table" and opts or {}
    local potionKey = opts.potionKey ~= nil and tostring(opts.potionKey) or nil
    local plantKey = opts.plantKey ~= nil and tostring(opts.plantKey) or nil
    local stub = nil
    if plantKey ~= nil and plantKey ~= "" then
        stub = BuildOptimisticPlantWatchRow(plantKey)
    elseif potionKey ~= nil and potionKey ~= "" then
        stub = BuildOptimisticPotionWatchRow(potionKey)
    end
    if type(stub) ~= "table" then
        return false
    end
    -- Mutate listData only (PlanSnapshot.Invalidate follows and drops snap.rows).
    local list = StockPilerTabWatch.listData
    if type(list) ~= "table" then
        list = {}
        StockPilerTabWatch.listData = list
    end
    for i = 1, #list do
        local row = list[i]
        if type(row) == "table" then
            if plantKey ~= nil and IsPlantWatchRow(row) and RowMatchesPlantKey(row, plantKey) then
                return false
            end
            if potionKey ~= nil and not IsPlantWatchRow(row) and RowMatchesPotionKey(row, potionKey) then
                return false
            end
        end
    end
    list[#list + 1] = stub
    StockPilerTabWatch.displayOrder = {}
    for i = 1, #list do
        StockPilerTabWatch.displayOrder[i] = i
    end
    StockPilerTabWatch._rowPaintKey = nil
    -- Length changed off-tab: next Watch Refresh must ListBoxSetDisplayOrder
    -- (order is always 1..n so orderChanged alone misses this).
    StockPilerTabWatch._pendingListRebind = true
    return true
end

local function IsEphemeralPlanRow(row)
    return type(row) == "table"
        and (row.skillUp == true or row.addonOwned == true or row.upgradeWatch == true)
end

--- Strip all saved potion or plant watch rows from live list/plan (keep SkillUp / Upgrade).
function StockPilerTabWatch.OptimisticClearWatchKind(kind)
    kind = tostring(kind or "")
    if kind ~= "potion" and kind ~= "plant" then
        return false
    end
    return ApplyOptimisticWatchRowFilter(function(rows)
        if type(rows) ~= "table" then
            return rows, false
        end
        local out = {}
        local changed = false
        for i = 1, #rows do
            local row = rows[i]
            local drop = false
            if type(row) == "table" and not IsEphemeralPlanRow(row) then
                local isPlant = row.kind == "plant" or row.isPlantWatch == true
                if kind == "plant" then
                    drop = isPlant
                else
                    drop = not isPlant
                end
            end
            if drop then
                changed = true
            else
                out[#out + 1] = row
            end
        end
        if changed then
            return out, true
        end
        return rows, false
    end)
end

--- Potions/Plants eye toggle / clear: urgent rebuild, throttle bypass, optimistic
--- add/remove, footer Clear-Watches nudge. Call after Watch.SetEnabled /
--- SetPlantEnabled succeeds.
function StockPilerTabWatch.AfterCatalogWatchToggle(opts)
    opts = type(opts) == "table" and opts or {}
    local enabled = opts.enabled == true
    -- Mutate live listData before soft-invalidate so Watch (or a later tab open)
    -- does not keep a prevList that is missing the new eye / still has a removed one.
    local listTouched = false
    if enabled == true then
        listTouched = OptimisticAddWatchRow(opts) == true
    else
        listTouched = OptimisticRemoveWatchRow(opts) == true
        if listTouched == true then
            StockPilerTabWatch._pendingListRebind = true
        end
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
        if StockPiler.Ui.MarkWatchUiDirty then
            StockPiler.Ui.MarkWatchUiDirty()
        end
    end
    -- Only paint/rebind Watch while that tab is selected. forceRebind used to
    -- KickListBoxLayout (hide/show SPTabWatch) from Potions/Plants and stack
    -- both tabs' headers/rows on screen.
    local onWatch = StockPilerWindow
        and StockPilerWindow.SelectedTab == StockPilerWindow.TABS_WATCH
    if onWatch == true and DoesWindowExist("SPTabWatchList") then
        if listTouched == true and StockPilerTabWatch.Refresh then
            -- Optimistic add/remove changes list length; force ListBoxSetDisplayOrder.
            StockPilerTabWatch.Refresh({ forcePlan = false, forceRebind = true })
        elseif StockPilerTabWatch.Refresh then
            StockPilerTabWatch.Refresh({ forcePlan = false })
        end
    elseif listTouched == true then
        -- Off Watch: keep optimistic listData; force rebind on next Watch paint.
        StockPilerTabWatch._pendingListRebind = true
    end
    -- Restore tab visibility if a prior KickListBoxLayout left Watch stacked.
    if StockPilerWindow and StockPilerWindow.EnsureSelectedTabShowing then
        StockPilerWindow.EnsureSelectedTabShowing()
    end
    -- Clear Watches enable state must flip with the eye, not wait for PLAN_UPDATED.
    if StockPilerWindow and StockPilerWindow.SyncActionReadiness then
        StockPilerWindow.SyncActionReadiness()
    elseif StockPilerWindow and StockPilerWindow.RequestFooterRefresh then
        StockPilerWindow.RequestFooterRefresh()
    end
end

function StockPilerTabWatch.ClearRowPaintCache()
    StockPilerTabWatch._rowPaintKey = {}
    StockPilerTabWatch._rowIconNum = {}
end

function StockPilerTabWatch.InvalidateBrewChrome()
    -- Do not nil _rowPaintKey: that rewrites every label and looks like a full
    -- list clear/repaint between crafts. Only refresh Load/Brew buttons.
    StockPilerTabWatch._brewChromeDirty = true
end

--- After brew hold: one ListBoxSetDisplayOrder if keepVisible left PopulatorIndices empty.
function StockPilerTabWatch.FlushPendingListRebind()
    if StockPilerTabWatch._pendingListRebind ~= true then
        return false
    end
    local Brew = StockPiler.Brew
    local Orch = StockPiler.Orchestrator
    if (Brew and Brew.IsWatchUiHold and Brew.IsWatchUiHold() == true)
        or (Orch and Orch.IsBrewSessionActive and Orch.IsBrewSessionActive() == true)
    then
        return false
    end
    if not DoesWindowExist("SPTabWatchList") then
        StockPilerTabWatch._pendingListRebind = nil
        return false
    end
    local listData = StockPilerTabWatch.listData
    local listCount = type(listData) == "table" and #listData or 0
    if listCount <= 0 then
        StockPilerTabWatch._pendingListRebind = nil
        return false
    end
    local indices = SPTabWatchList and SPTabWatchList.PopulatorIndices
    local hasPopulated = type(indices) == "table" and next(indices) ~= nil
    if hasPopulated then
        StockPilerTabWatch._pendingListRebind = nil
        return false
    end
    local order = StockPilerTabWatch.displayOrder
    if type(order) ~= "table" or #order == 0 then
        order = {}
        for i = 1, listCount do
            order[i] = i
        end
        StockPilerTabWatch.displayOrder = order
    end
    StockPilerTabWatch._pendingListRebind = nil
    StockPilerTabWatch._rowPaintKey = {}
    StockPilerTabWatch._rowIconNum = {}
    ListBoxSetDisplayOrder("SPTabWatchList", order)
    return true
end

function StockPilerTabWatch.KickListBoxLayout()
    if not DoesWindowExist("StockPilerWindow") or WindowGetShowing("StockPilerWindow") ~= true then
        return false
    end
    if not DoesWindowExist(TAB_ROOT) or not DoesWindowExist("SPTabWatchList") then
        return false
    end
    -- Never force-show Watch over Potions/Plants (eye-clear forceRebind path).
    if not (StockPilerWindow
        and StockPilerWindow.SelectedTab == StockPilerWindow.TABS_WATCH)
    then
        return false
    end
    -- Child tab is SetShowing(true) during Initialize while the parent is hidden.
    -- WAR ListBox does not lay out until a hidden->shown edge after the parent is up.
    WindowSetShowing(TAB_ROOT, false)
    WindowSetShowing(TAB_ROOT, true)
    if type(WindowForceProcessAnchors) == "function" then
        pcall(WindowForceProcessAnchors, TAB_ROOT)
        pcall(WindowForceProcessAnchors, "SPTabWatchList")
    end
    WindowSetShowing("SPTabWatchList", false)
    WindowSetShowing("SPTabWatchList", true)
    if type(WindowForceProcessAnchors) == "function" then
        pcall(WindowForceProcessAnchors, "SPTabWatchList")
    end
    return true
end

local function RebindWatchListBox(order)
    order = type(order) == "table" and order or {}
    StockPilerTabWatch._pendingListRebind = nil
    StockPilerTabWatch._rowPaintKey = {}
    StockPilerTabWatch._rowIconNum = {}
    local listData = StockPilerTabWatch.listData
    StockPilerTabWatch._lastBoundListCount = type(listData) == "table" and #listData or 0
    -- Same kick Potions/Plants use: empty order then real order forces populate.
    ListBoxSetDisplayOrder("SPTabWatchList", {})
    ListBoxSetDisplayOrder("SPTabWatchList", order)
    if StockPilerTabWatch.UpdateRows then
        StockPilerTabWatch.UpdateRows({ keepVisible = true })
    end
end

function StockPilerTabWatch.Refresh(opts)
    opts = type(opts) == "table" and opts or {}
    if not DoesWindowExist(TAB_ROOT) then
        return
    end
    UpdateSortHeaders()
    StockPilerTabWatch.RefreshSkillGates()
    local prevOrder = StockPilerTabWatch.displayOrder
    local prevBoundCount = tonumber(StockPilerTabWatch._lastBoundListCount)
    BuildVisibleList(opts)
    if not DoesWindowExist("SPTabWatchList") then
        return
    end
    local order = StockPilerTabWatch.displayOrder
    local listData = StockPilerTabWatch.listData
    local listCount = type(listData) == "table" and #listData or 0
    local indices = SPTabWatchList and SPTabWatchList.PopulatorIndices
    local hasPopulated = type(indices) == "table" and next(indices) ~= nil
    local Brew = StockPiler.Brew
    local Orch = StockPiler.Orchestrator
    local brewHold = opts.brewHold == true
        or (Brew and Brew.IsWatchUiHold and Brew.IsWatchUiHold() == true)
        or (Orch and Orch.IsBrewSessionActive and Orch.IsBrewSessionActive() == true)

    local orderChanged = type(prevOrder) ~= "table" or type(order) ~= "table" or #prevOrder ~= #order
    if not orderChanged and type(prevOrder) == "table" and type(order) == "table" then
        for i = 1, #order do
            if prevOrder[i] ~= order[i] then
                orderChanged = true
                break
            end
        end
    end

    local forceRebind = opts.forceRebind == true
        or StockPilerTabWatch._pendingListRebind == true
    -- Eye toggle off-tab already grew displayOrder; orderChanged stays false.
    if not forceRebind and (prevBoundCount == nil or prevBoundCount ~= listCount) then
        forceRebind = true
    end
    -- Stale PopulatorIndices after optimistic eye-clear (indices past #listData).
    if not forceRebind and hasPopulated and type(indices) == "table" then
        for _, dataIndex in pairs(indices) do
            local di = tonumber(dataIndex) or 0
            if di > listCount then
                forceRebind = true
                break
            end
        end
    end

    -- Empty PopulatorIndices mid-brew: keepVisible + defer one SetDisplayOrder
    -- until hold ends (avoids ListBox flash every ForceBrew; chips rebind once).
    if brewHold and listCount > 0 and not hasPopulated then
        StockPilerTabWatch._pendingListRebind = true
        StockPilerTabWatch.UpdateRows({ keepVisible = true })
        return
    end
    if not brewHold and (forceRebind or (listCount > 0 and not hasPopulated)) then
        if forceRebind and opts.forceRebind == true then
            StockPilerTabWatch.KickListBoxLayout()
        end
        RebindWatchListBox(order or {})
        return
    end

    -- AutoBrew continuum / same order: in-place paint only (no ListBox flash).
    if brewHold or not orderChanged then
        if brewHold and listCount > 0 and not hasPopulated then
            StockPilerTabWatch._pendingListRebind = true
        end
        StockPilerTabWatch.UpdateRows({ keepVisible = true })
        return
    end

    RebindWatchListBox(order or {})
end

function StockPilerTabWatch.UpdateRows(opts)
    opts = type(opts) == "table" and opts or {}
    if not DoesWindowExist("SPTabWatchList") then
        return
    end
    if StockPiler.Perf and StockPiler.Perf.Begin then
        StockPiler.Perf.Begin("WatchRows")
    end
    local box = SPTabWatchList
    local numVisible = 11
    local indices = nil
    if type(box) == "table" then
        numVisible = tonumber(box.numVisibleRows) or 11
        indices = box.PopulatorIndices
    end
    local active = {}
    if type(indices) == "table" then
        for rowIndex, dataIndex in ipairs(indices) do
            active[rowIndex] = dataIndex
        end
    end
    local listData = StockPilerTabWatch.listData
    local listCount = type(listData) == "table" and #listData or 0
    -- ListBox briefly clears PopulatorIndices during order/rebuild; never blank rows.
    local keepVisible = opts.keepVisible == true
        or (listCount > 0 and next(active) == nil)
    if keepVisible and next(active) == nil and listCount > 0 then
        for rowIndex = 1, math.min(numVisible, listCount) do
            active[rowIndex] = rowIndex
        end
    end
    StockPilerTabWatch._rowPaintKey = StockPilerTabWatch._rowPaintKey or {}
    local canGrow = CanAutoGrowUi()
    for rowIndex = 1, numVisible do
        local rowName = "SPTabWatchListRow" .. rowIndex
        if DoesWindowExist(rowName) then
            local dataIndex = active[rowIndex]
            local data = dataIndex and type(listData) == "table" and listData[dataIndex] or nil
            if data then
                WindowSetShowing(rowName, true)
                StockPiler.ViewList.ApplyRowStripe(rowName .. "Background", rowIndex)
                local brewState = GetRowCraftUiState(data)
                local craftableGreen = RowCraftableGreen(data)
                local craftableSnapOk = RowCraftableSnapCurrent(data)
                local nameR, nameG, nameB = EnsureWatchNameRarityColors(data)
                local paintKey = table.concat({
                    tostring(data.iconNum or 0),
                    tostring(data.name or ""),
                    tostring(nameR), tostring(nameG), tostring(nameB),
                    tostring(data.statusText or ""),
                    tostring(data.stockText or data.potionHave or 0),
                    tostring(data.craftableText or ""),
                    tostring(data.craftable or 0),
                    tostring(data.targetText or data.target or 0),
                    tostring(data.priorityTierText or data.priorityTier or 1),
                    tostring(data.statusKey or ""),
                    tostring(data.autoGrow == true),
                    tostring(data.hideAutoGrow == true),
                    tostring(data.hideBrew == true),
                    tostring(data.craftableShared == true),
                    tostring(data.seedBufferShort == true),
                    tostring(craftableGreen),
                    tostring(craftableSnapOk),
                    tostring(data._craftableSnapGen or -1),
                    tostring(brewState),
                    tostring(canGrow),
                }, "|")
                if StockPilerTabWatch._rowPaintKey[rowIndex] ~= paintKey then
                    local lastIcon = StockPilerTabWatch._rowIconNum
                    if type(lastIcon) ~= "table" then
                        lastIcon = {}
                        StockPilerTabWatch._rowIconNum = lastIcon
                    end
                    if lastIcon[rowIndex] ~= data.iconNum then
                        lastIcon[rowIndex] = data.iconNum
                        SetIconTexture(rowName .. "Icon", data.iconNum)
                    end
                    local prio = tonumber(data.priorityTier) or 1
                    if IsPlantWatchRow(data) then
                        LabelSetText(rowName .. "Prio", data.priorityTierText or L"-")
                    else
                        LabelSetText(rowName .. "Prio", data.priorityTierText or towstring(tostring(prio)))
                    end
                    TintStepper(rowName .. "PrioChipBg")
                    LabelSetTextColor(rowName .. "Prio", 255, 255, 255)
                    LabelSetText(rowName .. "Name", data.name or L"")
                    LabelSetTextColor(rowName .. "Name", nameR, nameG, nameB)
                    LabelSetText(rowName .. "Status", data.statusText or L"")
                    LabelSetText(rowName .. "Stock", data.stockText or towstring(tostring(data.potionHave or 0)))
                    if IsEphemeralWatchRow(data) or IsPlantWatchRow(data) then
                        LabelSetText(rowName .. "Craftable", L"")
                    else
                        LabelSetText(rowName .. "Craftable", data.craftableText or T("ui.dash"))
                    end
                    LabelSetText(rowName .. "Target", data.targetText or towstring(tostring(data.target or 0)))
                    TintStepper(rowName .. "TargetChipBg")
                    ApplyStatusColor(rowName .. "Status", data.statusKey)
                    local autoGrowWin = rowName .. "AutoGrow"
                    if DoesWindowExist(autoGrowWin) then
                        local hideAg = type(data) == "table" and data.hideAutoGrow == true
                        WindowSetShowing(autoGrowWin, hideAg ~= true)
                        if hideAg ~= true then
                            syncingUi = true
                            ButtonSetCheckButtonFlag(autoGrowWin, true)
                            local pressed = false
                            if IsUpgradeWatchRow(data)
                                or (IsSkillUpWatchRow(data) and tostring(data.skillUpKind or "") == "cult")
                            then
                                -- Cult SkillUp / Upgrade Seed: read-only mirror of master AutoGrow.
                                pressed = canGrow and data.autoGrow == true
                                ButtonSetPressedFlag(autoGrowWin, pressed)
                                ButtonSetDisabledFlag(autoGrowWin, true)
                            else
                                pressed = canGrow and data.autoGrow == true
                                ButtonSetPressedFlag(autoGrowWin, pressed)
                                ButtonSetDisabledFlag(autoGrowWin, (not canGrow) or IsEphemeralWatchRow(data))
                            end
                            syncingUi = false
                        end
                    end
                    LabelSetTextColor(rowName .. "Target", 255, 255, 255)
                    local target = tonumber(data.target) or 0
                    local have = tonumber(data.potionHave) or 0
                    local craftable = tonumber(data.craftable) or 0
                    local stockColor = { 255, 255, 255 }
                    if IsEphemeralWatchRow(data) then
                        stockColor = { 255, 255, 255 }
                    elseif target > 0 then
                        if have >= target then
                            stockColor = COLOR_OK
                        elseif (have + craftable) >= target then
                            stockColor = COLOR_WARN
                        else
                            stockColor = COLOR_BLOCK
                        end
                    end
                    LabelSetTextColor(rowName .. "Stock", stockColor[1], stockColor[2], stockColor[3])
                    if IsEphemeralWatchRow(data) or IsPlantWatchRow(data) then
                        LabelSetTextColor(rowName .. "Craftable", COLOR_GRAY[1], COLOR_GRAY[2], COLOR_GRAY[3])
                    else
                        local craftColor = COLOR_BLOCK
                        if craftable > 0 then
                            -- Yellow: craftable but seed buffer short. Green: buffer-safe (shared OK).
                            if data.seedBufferShort == true or data.craftableSafe == false then
                                craftColor = COLOR_WARN
                            else
                                craftColor = COLOR_OK
                            end
                        end
                        LabelSetTextColor(rowName .. "Craftable", craftColor[1], craftColor[2], craftColor[3])
                    end
                    ApplyRowBrewButton(rowName .. "Load", data)
                    StockPilerTabWatch._rowPaintKey[rowIndex] = paintKey
                elseif StockPilerTabWatch._brewChromeDirty == true then
                    ApplyRowBrewButton(rowName .. "Load", data)
                end
            else
                -- keepVisible preserves mid-rebuild flashes, but never leave a
                -- ghost slot when listData shrank (eye-clear / Forget / Clear).
                local pastEnd = dataIndex == nil or dataIndex > listCount
                if keepVisible ~= true or pastEnd then
                    WindowSetShowing(rowName, false)
                    StockPilerTabWatch._rowPaintKey[rowIndex] = nil
                end
            end
        end
    end
    StockPilerTabWatch._brewChromeDirty = false
    if StockPiler.Perf and StockPiler.Perf.End then
        StockPiler.Perf.End("WatchRows")
    end
end

function StockPilerTabWatch.OnToggleEnabled()
    if syncingUi then
        return
    end
    if not SyncCheckFromActive(ENABLE_WIN) then
        UpdateEnableCheckbox()
        return
    end
    if not CanAutoGrowUi() then
        UpdateEnableCheckbox()
        return
    end
    local on = ButtonGetPressedFlag(ENABLE_WIN) == true
    local Watch = StockPiler.Watch
    if not Watch or not Watch.SetCharacterField
        or Watch.SetCharacterField("autoGrowEnabled", on) ~= true
    then
        return
    end
    NotifySettings(T("watch.autogrow", { state = OnOff(on) }))
    if on ~= true and StockPiler.Orchestrator and StockPiler.Orchestrator.OnAutoGrowDisabled then
        StockPiler.Orchestrator.OnAutoGrowDisabled()
    end
    AfterWatchSettingsChanged()
    StockPilerTabWatch.RefreshSkillGates()
    StockPilerTabWatch._rowPaintKey = nil
    StockPilerTabWatch.UpdateRows()
end

function StockPilerTabWatch.OnToggleAdditives()
    if syncingUi then
        return
    end
    if not SyncCheckFromActive(ADDITIVES_WIN) then
        UpdateAdditivesCheckbox()
        return
    end
    if not CanAutoGrowUi() then
        UpdateAdditivesCheckbox()
        return
    end
    local on = ButtonGetPressedFlag(ADDITIVES_WIN) == true
    local Watch = StockPiler.Watch
    if not Watch or not Watch.SetCharacterField
        or Watch.SetCharacterField("autoGrowAdditives", on) ~= true
    then
        return
    end
    NotifySettings(T("watch.additives", { state = OnOff(on) }))
    AfterWatchSettingsChanged()
end

function StockPilerTabWatch.OnToggleSeedBuffer()
    if syncingUi then
        return
    end
    if not SyncCheckFromActive(SEED_BUFFER_ENABLE_WIN) then
        UpdateSeedBufferEnableCheckbox()
        return
    end
    if not CanAutoGrowUi() then
        UpdateSeedBufferEnableCheckbox()
        return
    end
    local on = ButtonGetPressedFlag(SEED_BUFFER_ENABLE_WIN) == true
    local Watch = StockPiler.Watch
    if not Watch or not Watch.SetCharacterField
        or Watch.SetCharacterField("growSeedBufferEnabled", on) ~= true
    then
        return
    end
    NotifySettings(T("watch.seed_buffer", { state = OnOff(on) }))
    AfterWatchSettingsChanged()
    UpdateSeedBufferEnableCheckbox()
end

function StockPilerTabWatch.OnToggleUpgradeSeeds()
    if syncingUi then
        return
    end
    if not SyncCheckFromActive(UPGRADE_SEEDS_WIN) then
        UpdateUpgradeSeedsCheckbox()
        return
    end
    if not CanAutoGrowUi() then
        UpdateUpgradeSeedsCheckbox()
        return
    end
    local US = StockPiler.UpgradeSeed
    local on = ButtonGetPressedFlag(UPGRADE_SEEDS_WIN) == true
    if US and US.SetEnabled then
        US.SetEnabled(on)
    else
        local row = CharRow(true)
        if type(row) == "table" then
            row.upgradeSeedsEnabled = on
        end
    end
    NotifySettings(T("watch.upgrade_seeds_state", { state = OnOff(on) }))
    AfterWatchSettingsChanged()
    UpdateUpgradeSeedsCheckbox()
end

function StockPilerTabWatch.OnToggleAutoBuy()
    if syncingUi then
        return
    end
    if not SyncCheckFromActive(AUTOBUY_WIN) then
        UpdateAutoBuyCheckbox()
        return
    end
    if not CanAutoBuyUi() then
        UpdateAutoBuyCheckbox()
        return
    end
    local on = ButtonGetPressedFlag(AUTOBUY_WIN) == true
    local Watch = StockPiler.Watch
    if not Watch or not Watch.SetCharacterField
        or Watch.SetCharacterField("autoBuyEnabled", on) ~= true
    then
        return
    end
    NotifySettings(T("watch.autobuy", { state = OnOff(on) }))
    AfterSoftMoneySetting()
    if on == true and StockPiler.Scheduler and StockPiler.Scheduler.WakeAutoBuy then
        StockPiler.Scheduler.WakeAutoBuy()
    end
    if StockPiler.Buy and StockPiler.Buy.InvalidateJobsCache then
        StockPiler.Buy.InvalidateJobsCache()
    end
end

function StockPilerTabWatch.OnToggleAutoBrew()
    if syncingUi then
        return
    end
    if not SyncCheckFromActive(AUTOBREW_WIN) then
        UpdateAutoBrewCheckbox()
        return
    end
    if not CanAutoBrewUi() then
        UpdateAutoBrewCheckbox()
        return
    end
    local on = ButtonGetPressedFlag(AUTOBREW_WIN) == true
    local Watch = StockPiler.Watch
    if not Watch or not Watch.SetCharacterField
        or Watch.SetCharacterField("autoBrewEnabled", on) ~= true
    then
        return
    end
    NotifySettings(T("watch.autobrew", { state = OnOff(on) }))
    UpdateAutoBrewCheckbox()
    if StockPiler.Brew and StockPiler.Brew.InvalidateCanBrewCache then
        StockPiler.Brew.InvalidateCanBrewCache()
    end
    -- Footer Brew + Craft-macro brew path follow CanBrewNow (false while AutoBrew on).
    if StockPiler.Ui and StockPiler.Ui.RequestFooterRefresh then
        StockPiler.Ui.RequestFooterRefresh()
    elseif StockPilerWindow and StockPilerWindow.SyncActionReadiness then
        StockPilerWindow.SyncActionReadiness()
    end
end

function StockPilerTabWatch.OnToggleHudButton()
    if syncingUi then
        return
    end
    if not SyncCheckFromActive(HUD_BUTTON_WIN) then
        UpdateHudButtonCheckboxes()
        return
    end
    local on = ButtonGetPressedFlag(HUD_BUTTON_WIN) == true
    local CB = StockPiler.CraftButton
    if CB and CB.SetVisible then
        CB.SetVisible(on)
    end
    NotifySettings(T("watch.hud_button", { state = OnOff(on) }))
    UpdateHudButtonCheckboxes()
end

function StockPilerTabWatch.OnToggleCraftMacro()
    if syncingUi then
        return
    end
    if not SyncCheckFromActive(CRAFT_MACRO_WIN) then
        UpdateHudButtonCheckboxes()
        return
    end
    local on = ButtonGetPressedFlag(CRAFT_MACRO_WIN) == true
    local Macro = StockPiler.Macro
    if Macro and Macro.SetCraftMacroEnabled then
        Macro.SetCraftMacroEnabled(on)
    end
    NotifySettings(T("watch.craft_macro", { state = OnOff(on) }))
    UpdateHudButtonCheckboxes()
end

function StockPilerTabWatch.OnToggleOptimisticMode()
    if syncingUi then
        return
    end
    if not SyncCheckFromActive(OPTIMISTIC_MODE_WIN) then
        UpdateOptimisticModeCheckbox()
        return
    end
    local on = ButtonGetPressedFlag(OPTIMISTIC_MODE_WIN) == true
    local Watch = StockPiler.Watch
    if not Watch or not Watch.SetCharacterField
        or Watch.SetCharacterField("watchOptimisticOutcomeEstimate", on) ~= true
    then
        return
    end
    NotifySettings(T("watch.optimistic_mode", { state = OnOff(on) }))
    AfterWatchSettingsChanged()
    UpdateOptimisticModeCheckbox()
end

function StockPilerTabWatch.OnToggleSkillUpSkills()
    if syncingUi then
        return
    end
    if not SyncCheckFromActive(SKILLUP_SKILLS_WIN) then
        UpdateSkillUpCheckboxes()
        return
    end
    local SkillUp = StockPiler.SkillUp
    local cultKind, apoKind = SkillUpLevelKinds()
    if cultKind ~= "ready" and apoKind ~= "ready" then
        UpdateSkillUpCheckboxes()
        return
    end
    local on = ButtonGetPressedFlag(SKILLUP_SKILLS_WIN) == true
    if cultKind == "ready" and SkillUp and SkillUp.SetCultEnabled then
        SkillUp.SetCultEnabled(on)
    end
    if apoKind == "ready" and SkillUp and SkillUp.SetApoEnabled then
        SkillUp.SetApoEnabled(on)
    end
    NotifySettings(T("watch.skillup_skills_state", { state = OnOff(on) }))
    AfterWatchSettingsChanged()
    UpdateSkillUpCheckboxes()
    StockPilerTabWatch.Refresh({ forcePlan = true })
    if on and StockPiler.Scheduler and StockPiler.Scheduler.WakeAutoGrow then
        StockPiler.Scheduler.WakeAutoGrow()
    end
    if StockPiler.Buy and StockPiler.Buy.InvalidateJobsCache then
        StockPiler.Buy.InvalidateJobsCache()
    end
end

local function AdjustSeedBuffer(flags, dir)
    if not CanAutoGrowUi() then
        UpdateSeedBufferEnableCheckbox()
        return
    end
    local cur = 5
    local row = CharRow(false)
    if type(row) == "table" then
        cur = tonumber(row.growSeedBufferMin) or 5
    end
    local nextVal = Clamp(cur + ChipDelta(flags, dir), 4, 20)
    if nextVal == cur then
        return
    end
    local Watch = StockPiler.Watch
    if not Watch or not Watch.SetCharacterField
        or Watch.SetCharacterField("growSeedBufferMin", nextVal) ~= true
    then
        return
    end
    NotifySettings(T("watch.setting_eq", {
        label = T("watch.setting.seed_buffer"),
        value = tostring(nextVal),
    }))
    UpdateSeedBufferLabel()
    AfterWatchSettingsChanged()
end

local function AdjustReserve(flags, dir)
    local cur = 10
    local row = CharRow(false)
    if type(row) == "table" then
        cur = tonumber(row.autoBuyReserveGold) or 10
    end
    local nextVal = Clamp(cur + ChipDelta(flags, dir), 1, 99)
    if nextVal == cur then
        return
    end
    local Watch = StockPiler.Watch
    if not Watch or not Watch.SetCharacterField
        or Watch.SetCharacterField("autoBuyReserveGold", nextVal) ~= true
    then
        return
    end
    NotifySettings(T("watch.setting_eq", {
        label = T("watch.setting.reserve"),
        value = tostring(nextVal),
    }))
    UpdateAutoBuyChips()
    AfterSoftMoneySetting()
end

local function AdjustBudget(flags, dir)
    local cur = 50
    local row = CharRow(false)
    if type(row) == "table" then
        cur = tonumber(row.autoBuyBudgetGold) or 50
    end
    local nextVal = Clamp(cur + ChipDelta(flags, dir), 1, 999)
    if nextVal == cur then
        return
    end
    local Watch = StockPiler.Watch
    if not Watch or not Watch.SetCharacterField
        or Watch.SetCharacterField("autoBuyBudgetGold", nextVal) ~= true
    then
        return
    end
    NotifySettings(T("watch.setting_eq", {
        label = T("watch.setting.budget"),
        value = tostring(nextVal),
    }))
    UpdateAutoBuyChips()
    AfterSoftMoneySetting()
end

function StockPilerTabWatch.OnSeedBufferLButtonUp(flags)
    AdjustSeedBuffer(flags, 1)
end

function StockPilerTabWatch.OnSeedBufferRButtonUp(flags)
    AdjustSeedBuffer(flags, -1)
end

function StockPilerTabWatch.OnReserveLButtonUp(flags)
    AdjustReserve(flags, 1)
end

function StockPilerTabWatch.OnReserveRButtonUp(flags)
    AdjustReserve(flags, -1)
end

function StockPilerTabWatch.OnBudgetLButtonUp(flags)
    AdjustBudget(flags, 1)
end

function StockPilerTabWatch.OnBudgetRButtonUp(flags)
    AdjustBudget(flags, -1)
end

function StockPilerTabWatch.OnHudScaleLButtonUp()
    AdjustHudScale(1)
end

function StockPilerTabWatch.OnHudScaleRButtonUp()
    AdjustHudScale(-1)
end

function StockPilerTabWatch.OnBudgetReset()
    if syncingUi then
        return
    end
    local Buy = StockPiler.Buy
    local spent = Buy and Buy.GetSpentBrass and Buy.GetSpentBrass() or 0
    if spent <= 0 then
        UpdateAutoBuyChips()
        return
    end
    if Buy and Buy.ResetAllowanceSpent then
        Buy.ResetAllowanceSpent()
    elseif StockPiler.Watch and StockPiler.Watch.ResetAutoBuySpentBrass then
        StockPiler.Watch.ResetAutoBuySpentBrass()
    end
    NotifySettings(T("watch.budget_reset_done"))
    UpdateAutoBuyChips()
    AfterSoftMoneySetting()
end

function StockPilerTabWatch.OnToggleRowAutoGrow()
    if syncingUi then
        return
    end
    local data = RowDataFromActiveChild()
    if not data or not CanAutoGrowUi() then
        return
    end
    if IsEphemeralWatchRow(data) then
        -- Addon-owned SkillUp / Upgrade rows: AutoGrow is master-linked (display-only).
        StockPilerTabWatch._rowPaintKey = nil
        StockPilerTabWatch.UpdateRows()
        return
    end
    if IsPlantWatchRow(data) then
        local plantKey = data.plantKey or data.id or data.potionKey
        local enabled = ButtonGetPressedFlag(SystemData.ActiveWindow.name) == true
        if StockPiler.Watch and StockPiler.Watch.SetPlantAutoGrow then
            StockPiler.Watch.SetPlantAutoGrow(plantKey, enabled)
        end
        data.autoGrow = enabled
        AfterWatchSettingsChanged()
        StockPilerTabWatch._rowPaintKey = nil
        StockPilerTabWatch.UpdateRows()
        return
    end
    local potionKey = data.potionRecipeKey or data.id or data.potionKey
    local enabled = ButtonGetPressedFlag(SystemData.ActiveWindow.name) == true
    if StockPiler.Watch and StockPiler.Watch.SetAutoGrow then
        StockPiler.Watch.SetAutoGrow(potionKey, enabled)
    end
    data.autoGrow = enabled
    AfterWatchSettingsChanged()
    StockPilerTabWatch._rowPaintKey = nil
    -- UpdateRows alone used to paint pre-reconcile status; Refresh re-patches listData.
    StockPilerTabWatch.UpdateRows()
end

function StockPilerTabWatch.OnTargetLButtonUp(flags)
    local data = RowDataFromActiveChild()
    AdjustTarget(data, ChipDelta(flags, 1))
end

function StockPilerTabWatch.OnTargetRButtonUp(flags)
    local data = RowDataFromActiveChild()
    AdjustTarget(data, ChipDelta(flags, -1))
end

function StockPilerTabWatch.OnPrioLButtonUp(flags)
    local data = RowDataFromActiveChild()
    AdjustPriority(data, ChipDelta(flags, 1))
end

function StockPilerTabWatch.OnPrioRButtonUp(flags)
    local data = RowDataFromActiveChild()
    AdjustPriority(data, ChipDelta(flags, -1))
end

function StockPilerTabWatch.OnLoadRow()
    local data = RowDataFromActiveChild()
    if not data or IsPlantWatchRow(data) or IsEphemeralWatchRow(data) or not StockPiler.Brew then
        return
    end
    if StockPiler.Brew.OnRowCraftClick then
        StockPiler.Brew.OnRowCraftClick(data)
    end
    if StockPiler.BrewChrome and StockPiler.BrewChrome.RefreshBrewUi then
        StockPiler.BrewChrome.RefreshBrewUi()
    end
end

function StockPilerTabWatch.OnLoadRowRightClick()
    local data = RowDataFromActiveChild()
    if not data or IsEphemeralWatchRow(data) then
        return
    end
    if StockPiler.Brew and StockPiler.Brew.OnRowCraftRightClick then
        StockPiler.Brew.OnRowCraftRightClick(data)
    end
    if StockPiler.BrewChrome and StockPiler.BrewChrome.RefreshBrewUi then
        StockPiler.BrewChrome.RefreshBrewUi()
    end
end

local function Tip(text)
    Tooltips.CreateTextOnlyTooltip(SystemData.ActiveWindow.name, text)
    Tooltips.AnchorTooltip(Tooltips.ANCHOR_WINDOW_RIGHT)
end

local function TipTradeSkill(skillId)
    skillId = tonumber(skillId) or 0
    if skillId > 0 and Tooltips and type(Tooltips.CreateTradeskillTooltip) == "function" then
        Tooltips.CreateTradeskillTooltip(skillId, Tooltips.ANCHOR_WINDOW_RIGHT)
        return
    end
    local Caps = StockPiler.TradeSkillCaps
    local level = Caps and Caps.Level and Caps.Level(skillId) or 0
    local label = L"Trade skill"
    if skillId == (Caps and Caps.CultivationId and Caps.CultivationId() or 3) then
        label = T("watch.skillup_cult")
    elseif skillId == (Caps and Caps.ApothecaryId and Caps.ApothecaryId() or 4) then
        label = T("watch.skillup_apo")
    end
    if level > 0 then
        Tip(towstring(string.format("%s\nSkill Level: %d", tostring(label), level)))
    else
        Tip(label)
    end
end

local function ToNarrow(v)
    return StockPiler.Util.ToNarrow(v)
end

local function RgbDef(rgb)
    if type(rgb) ~= "table" then
        return nil
    end
    return {
        r = tonumber(rgb[1]) or 255,
        g = tonumber(rgb[2]) or 255,
        b = tonumber(rgb[3]) or 255,
    }
end

local function StatusTitleColor(statusKey)
    local def = RgbDef(STATUS_TIP_COLORS[statusKey or ""])
    if def ~= nil then
        return def
    end
    if Tooltips and Tooltips.COLOR_HEADING then
        return Tooltips.COLOR_HEADING
    end
    return nil
end

local function PlanTipCacheKey()
    local planGen = 0
    local cacheKey = ""
    if StockPiler.PlanSnapshot and StockPiler.PlanSnapshot.Get then
        local plan = StockPiler.PlanSnapshot.Get()
        if type(plan) == "table" then
            planGen = tonumber(plan.planGen) or 0
            cacheKey = tostring(plan.cacheKey or "")
        end
    end
    return tostring(planGen) .. ":" .. cacheKey
end

local function SpecIsAutoGrowProgressableTip(entry)
    if type(entry) ~= "table" then
        return false
    end
    if entry.role == "container" then
        return false
    end
    local spec = entry.spec
    if type(spec) ~= "table" then
        return false
    end
    local SM = StockPiler.SeedMap
    if SM and SM.IsGrowableSpec and SM.IsGrowableSpec(spec) == true then
        return true
    end
    return false
end

local function TipEntrySpecKey(entry)
    if type(entry) ~= "table" then
        return ""
    end
    if type(entry.specKey) == "string" and entry.specKey ~= "" then
        return entry.specKey
    end
    local MS = StockPiler.MaterialSpec
    local spec = entry.spec
    if MS and MS.Key and type(spec) == "table" then
        local bound = nil
        if spec.incomplete == true then
            bound = tonumber(spec.boundUid) or tonumber(spec.uid) or nil
        end
        local k = MS.Key(spec, bound)
        if type(k) == "string" and k ~= "" then
            return k
        end
    end
    return ""
end

local function TrimStatusTooltipRows(rows, limit)
    limit = tonumber(limit) or 17
    if type(rows) ~= "table" or #rows <= limit then
        return rows
    end

    local function isIngredientDivider(i)
        local prev = rows[i - 1]
        local nextRow = rows[i + 1]
        if not (nextRow and nextRow.kind == "ingredient") or not prev then
            return false
        end
        if prev.kind == "stocked" or prev.kind == "bonus" or prev.kind == "effect"
            or prev.kind == "positive" or prev.kind == "negative"
        then
            return true
        end
        if prev.kind == "body" or prev.kind == "warning" then
            local t = ToNarrow(prev.text)
            if string.find(t, "Have ", 1, true) then
                return true
            end
        end
        return false
    end

    for i = #rows, 1, -1 do
        if #rows <= limit then
            return rows
        end
        local r = rows[i]
        if r.kind == "meta" and r.metaRole == "yield" then
            table.remove(rows, i)
        end
    end
    for i = #rows, 1, -1 do
        if #rows <= limit then
            return rows
        end
        if rows[i].kind == "warning" then
            local t = ToNarrow(rows[i].text)
            if string.find(t, "success", 1, true) then
                table.remove(rows, i)
            end
        end
    end

    while #rows > limit do
        local removed = false
        for i = #rows, 1, -1 do
            if rows[i].kind == "separator" and not isIngredientDivider(i) then
                table.remove(rows, i)
                removed = true
                break
            end
        end
        if not removed then
            break
        end
    end
    return rows
end

local function BuildStatusTooltipRows(data)
    local rows = {
        {
            text = data.statusText or T("watch.col.status"),
            kind = "title",
            color = StatusTitleColor(data.statusKey),
        },
    }

    local function appendMeta(text)
        if text and text ~= L"" then
            rows[#rows + 1] = { text = text, kind = "meta" }
        end
    end

    -- SkillUp / Upgrade ephemeral rows: status message + statusLines only.
    if IsEphemeralWatchRow(data) then
        if type(data.statusLines) == "table" then
            for i = 1, #data.statusLines do
                appendMeta(data.statusLines[i])
            end
        end
        return rows
    end

    local liveHave = tonumber(data.potionHave)
    local liveMin = tonumber(data.potionMin) or tonumber(data.target) or 0

    -- Plant watches: title + color-coded Have/Target (no recipe ingredient slots).
    if IsPlantWatchRow(data) then
        if type(data.statusLines) == "table" then
            for i = 1, #data.statusLines do
                local line = data.statusLines[i]
                if line and line ~= L"" then
                    rows[#rows + 1] = {
                        text = line,
                        kind = "warning",
                        color = StatusTitleColor(data.statusKey),
                    }
                end
            end
        end
        if liveHave ~= nil and liveMin > 0 then
            local stocked = liveHave >= liveMin
            local statusKey = tostring(data.statusKey or "")
            local haveColor = RgbDef(COLOR_BLOCK)
            local noteKind = "block"
            local statusNote = nil
            if stocked or statusKey == "plant_stocked" then
                haveColor = RgbDef(COLOR_OK)
                noteKind = "stocked"
                statusNote = T("watch.note.stocked")
            elseif statusKey == "need_seeds" or statusKey == "upgrading_seed" then
                haveColor = RgbDef(COLOR_WARN)
                noteKind = "warning"
                if statusKey == "upgrading_seed" then
                    statusNote = data.statusText or T("plan.status.upgrading_seed")
                else
                    statusNote = data.statusText or T("plan.status.need_seeds")
                end
            elseif statusKey == "waiting_potions" then
                haveColor = RgbDef(COLOR_WARN)
                noteKind = "warning"
                statusNote = T("watch.note.waiting_potions")
            elseif statusKey == "restocking" then
                -- Match potion tip plant-slot warn tint while AutoGrow can progress.
                haveColor = RgbDef(COLOR_WARN)
                noteKind = "warning"
                if data.autoGrow == true then
                    statusNote = T("watch.note.needs_planting")
                else
                    statusNote = T("watch.note.autogrow_off")
                    haveColor = RgbDef(COLOR_BLOCK)
                    noteKind = "block"
                end
            elseif statusKey == "craft_bag_full" then
                haveColor = RgbDef(COLOR_WARN)
                noteKind = "warning"
                statusNote = T("watch.note.craft_bag_full")
            elseif statusKey == "enable_autogrow" then
                haveColor = RgbDef(COLOR_BLOCK)
                noteKind = "block"
                statusNote = T("watch.note.autogrow_off")
            else
                haveColor = RgbDef(COLOR_WARN)
                noteKind = "warning"
                statusNote = T("watch.note.needs_planting")
            end
            local haveText
            if statusNote and statusNote ~= L"" then
                haveText = T("tip.watch.have_need_note", {
                    have = tostring(liveHave),
                    need = tostring(liveMin),
                    note = statusNote,
                })
            else
                haveText = T("tip.watch.have_target", {
                    have = tostring(liveHave),
                    target = tostring(liveMin),
                })
            end
            rows[#rows + 1] = {
                text = haveText,
                kind = noteKind,
                color = haveColor,
            }
        end
        return rows
    end

    local slots = data.statusTipSlots
    local craftsNeeded = tonumber(data.tipCraftsNeeded)
    if craftsNeeded == nil then
        craftsNeeded = tonumber(data.craftsNeeded) or 0
    end
    local deficit = tonumber(data.tipDeficit)
    if deficit == nil then
        deficit = tonumber(data.potionDeficit) or 0
    end
    local yield = tonumber(data.tipYield) or 0
    local observed = tonumber(data.tipObservedYield) or 0
    local recipe = data.recipe or data.specRecipe

    if type(slots) == "table" and #slots > 0 then
        if craftsNeeded > 0 and deficit > 0 then
            rows[#rows + 1] = {
                text = T("tip.watch.need_crafts", {
                    crafts = tostring(craftsNeeded),
                    deficit = tostring(deficit),
                }),
                kind = "body",
            }
            if yield > 0 then
                rows[#rows + 1] = {
                    text = T("tip.watch.yield_best_case", { yield = tostring(yield) }),
                    kind = "meta",
                    metaRole = "yield",
                }
                if observed > 0 and math.abs(observed - yield) > 0.05 then
                    local obsText
                    local obsNear = math.floor(observed + 0.5)
                    if math.abs(observed - obsNear) < 0.05 then
                        obsText = tostring(obsNear)
                    else
                        obsText = string.format("%.1f", observed)
                    end
                    rows[#rows + 1] = {
                        text = T("tip.watch.yield_observed", { yield = obsText }),
                        kind = "meta",
                        metaRole = "yield",
                    }
                end
            end
            if data.statusKey == "enable_autogrow" then
                rows[#rows + 1] = {
                    text = T("tip.watch.enable_autogrow_row"),
                    kind = "warning",
                    color = RgbDef(COLOR_BLOCK),
                }
            elseif data.statusKey == "need_skill" then
                local lines = data.statusLines
                if type(lines) == "table" and #lines > 0 then
                    for i = 1, #lines do
                        rows[#rows + 1] = {
                            text = lines[i],
                            kind = "warning",
                            color = RgbDef(COLOR_BLOCK),
                        }
                    end
                else
                    rows[#rows + 1] = {
                        text = data.statusText or T("tip.watch.need_higher_skill"),
                        kind = "warning",
                        color = RgbDef(COLOR_BLOCK),
                    }
                end
            elseif data.statusKey == "need_apothecary" then
                rows[#rows + 1] = {
                    text = T("tip.watch.apo_only_brew"),
                    kind = "warning",
                    color = RgbDef(COLOR_BLOCK),
                }
            elseif data.statusKey == "buy_ingredients" and not CanAutoGrowUi() then
                local st = string.lower(ToNarrow(data.statusText))
                if not string.find(st, "flask", 1, true) then
                    rows[#rows + 1] = {
                        text = T("tip.watch.cult_required"),
                        kind = "warning",
                        color = RgbDef(COLOR_BLOCK),
                    }
                end
            elseif data.statusKey == "need_seeds" or data.statusKey == "upgrading_seed" then
                local lines = data.statusLines
                if type(lines) == "table" then
                    for i = 1, #lines do
                        local line = lines[i]
                        if line and line ~= L"" then
                            rows[#rows + 1] = {
                                text = line,
                                kind = "warning",
                                color = RgbDef(COLOR_WARN),
                            }
                        end
                    end
                end
            end
            local RS = StockPiler.RecipeSpec
            local uid = tonumber(data.uniqueID) or 0
            if RS and RS.ExpectedCraftsForDeficit and type(recipe) == "table" then
                local expectedCrafts, rate = RS.ExpectedCraftsForDeficit(deficit, recipe, uid)
                if rate ~= nil and rate < 0.99 and expectedCrafts and expectedCrafts > craftsNeeded then
                    local pct = math.floor(rate * 100 + 0.5)
                    rows[#rows + 1] = {
                        text = T("tip.watch.success_expected", {
                            pct = tostring(pct),
                            crafts = tostring(expectedCrafts),
                        }),
                        kind = "warning",
                    }
                end
                if RS.FormatApoSkillUpLine then
                    local apoLine = RS.FormatApoSkillUpLine(recipe)
                    if apoLine and apoLine ~= L"" then
                        appendMeta(apoLine)
                    end
                end
            end
        elseif data.statusNeedLine and data.statusNeedLine ~= L"" then
            appendMeta(data.statusNeedLine)
        end

        local RT = StockPiler.RecipeTooltip
        rows[#rows + 1] = {
            text = (RT and RT.SEP_LINE) or T("watch.sep"),
            kind = "separator",
        }

        local MS = StockPiler.MaterialSpec
        local Grow = StockPiler.Grow
        local colorOk = RgbDef(COLOR_OK)
        local colorWarn = RgbDef(COLOR_WARN)
        local colorBlock = RgbDef(COLOR_BLOCK)
        local slotShown = 0
        for i = 1, #slots do
            local entry = slots[i]
            if type(entry) == "table" and type(entry.spec) == "table" then
                if slotShown > 0 then
                    if RT and RT.AppendSeparator then
                        RT.AppendSeparator(rows)
                    else
                        rows[#rows + 1] = { text = T("watch.sep"), kind = "separator" }
                    end
                end
                slotShown = slotShown + 1

                local parts = MS and MS.NeedLabelParts and MS.NeedLabelParts(entry.spec) or nil
                local header = parts and parts.header
                    or (MS and MS.NeedLabel and MS.NeedLabel(entry.spec))
                    or T("watch.material_fallback")
                local detail = parts and parts.detail or L""
                rows[#rows + 1] = {
                    text = header,
                    kind = "ingredient",
                    role = entry.role,
                }
                if detail ~= nil and detail ~= L"" then
                    rows[#rows + 1] = {
                        text = detail,
                        kind = "bonus",
                        role = entry.role,
                    }
                end

                -- Live Have: copy tip-slot fields locally - never write back into statusTipSlots.
                local tipHave = tonumber(entry.have) or 0
                local tipNeed = tonumber(entry.need) or 0
                local tipDeficit = tonumber(entry.deficit) or math.max(0, tipNeed - tipHave)
                local tipStocked = entry.stocked == true or tipDeficit <= 0
                local Planner = StockPiler.Planner
                if Planner and Planner.CountItemsMatchingSpec and type(entry.spec) == "table" then
                    local live = Planner.CountItemsMatchingSpec(entry.spec, { cacheOnly = true })
                    if live ~= nil then
                        tipHave = tonumber(live) or tipHave
                        tipDeficit = math.max(0, tipNeed - tipHave)
                        tipStocked = tipDeficit <= 0
                    end
                end
                local stocked = tipStocked
                local agProgressable = SpecIsAutoGrowProgressableTip(entry)
                local haveColor = colorOk
                if not stocked then
                    if entry.kind == "convert" then
                        local feedable = data.convertFeedable == true
                        if not feedable then
                            for j = 1, #slots do
                                local sibling = slots[j]
                                if type(sibling) == "table" and sibling.kind == "plant" then
                                    feedable = true
                                    break
                                end
                            end
                        end
                        haveColor = feedable and colorWarn or colorBlock
                    elseif agProgressable then
                        haveColor = colorWarn
                    else
                        haveColor = colorBlock
                    end
                end
                local statusNote = nil
                local noteKind = stocked and "stocked" or "body"
                if (entry.kind == "plant" or (agProgressable and entry.kind ~= "convert"))
                    and not stocked
                then
                    -- Prefer per-slot Upgrade Seed climb note (Spumepetal vs Fusk).
                    local climbNote = nil
                    local US = StockPiler.UpgradeSeed
                    if US and US.IsEnabled and US.IsEnabled() == true
                        and US.StatusForPlant and US.FormatClimbSlotNote
                    then
                        local climb = US.StatusForPlant(entry.plantUid, entry.spec)
                        climbNote = US.FormatClimbSlotNote(climb)
                    end
                    if climbNote ~= nil and climbNote ~= L"" then
                        statusNote = climbNote
                        noteKind = "warning"
                        haveColor = colorWarn
                    else
                        local notes = nil
                        if Grow and Grow.GrowingNotesForSpec then
                            notes = Grow.GrowingNotesForSpec(entry.spec, { cacheOnly = true })
                        end
                        if notes == nil or notes == L"" then
                            notes = entry.growingNotes
                        end
                        if notes == nil or notes == L"" then
                            notes = L""
                        end
                        if notes == L"" then
                            if not CanAutoGrowUi() then
                                statusNote = T("watch.note.needs_cult")
                                haveColor = colorBlock
                                noteKind = "negative"
                            elseif data.autoGrow == true then
                                local seedUid = tonumber(entry.seedUid) or 0
                                local credit = tonumber(entry.seedCredit) or 0
                                if seedUid > 0 and credit <= 0 then
                                    statusNote = T("watch.note.buy_seeds")
                                elseif seedUid <= 0 then
                                    statusNote = T("watch.note.buy_plants")
                                else
                                    statusNote = T("watch.note.needs_planting")
                                end
                                haveColor = colorWarn
                                noteKind = "warning"
                            else
                                statusNote = T("watch.note.autogrow_off")
                                haveColor = colorBlock
                                noteKind = "negative"
                            end
                        else
                            statusNote = notes
                            noteKind = entry.noteKind or "body"
                        end
                    end
                elseif not stocked then
                    if entry.role == "container" then
                        statusNote = T("watch.note.buy_flasks")
                    elseif entry.buySeedOrMat == true
                        and (tonumber(entry.seedUid) or 0) > 0
                    then
                        statusNote = T("watch.note.buy_seeds")
                    else
                        statusNote = T("watch.note.buy_materials")
                    end
                    noteKind = "block"
                    haveColor = colorBlock
                elseif stocked then
                    local contestedKeys = data.contestedSpecKeys
                    local specKey = TipEntrySpecKey(entry)
                    local claimContested = (data.craftableShared == true
                            or data.statusKey == "ready_to_craft_shared"
                            or data.statusKey == "buy_ingredients")
                        and type(contestedKeys) == "table"
                        and specKey ~= ""
                        and contestedKeys[specKey] == true
                    if entry.noteKind == "shared" or claimContested then
                        if data.statusKey == "buy_ingredients"
                            and not SpecIsAutoGrowProgressableTip(entry)
                        then
                            if entry.role == "container" then
                                statusNote = T("watch.note.buy_flasks")
                            elseif entry.buySeedOrMat == true
                                and (tonumber(entry.seedUid) or 0) > 0
                            then
                                statusNote = T("watch.note.buy_seeds")
                            else
                                statusNote = T("watch.note.buy_materials")
                            end
                            noteKind = "block"
                            haveColor = colorBlock
                        else
                            statusNote = T("watch.note.shared")
                            noteKind = "warning"
                            haveColor = colorWarn
                        end
                    elseif entry.noteKind == "pooled" or entry.sharedPool == true then
                        statusNote = T("watch.note.pooled")
                        noteKind = "warning"
                        haveColor = colorWarn
                    else
                        statusNote = T("watch.note.stocked")
                        noteKind = "stocked"
                    end
                end
                local haveText
                if statusNote and statusNote ~= L"" then
                    haveText = T("tip.watch.have_need_note", {
                        have = tostring(tipHave),
                        need = tostring(tipNeed),
                        note = statusNote,
                    })
                else
                    haveText = T("tip.watch.have_need", {
                        have = tostring(tipHave),
                        need = tostring(tipNeed),
                    })
                end
                rows[#rows + 1] = {
                    text = haveText,
                    kind = noteKind,
                    color = haveColor,
                }
            end
        end
    elseif type(recipe) == "table" then
        appendMeta(T("tip.status.plan_pending"))
        if type(data.statusLines) == "table" and #data.statusLines > 0 then
            for i = 1, #data.statusLines do
                appendMeta(data.statusLines[i])
            end
        end
        if liveHave ~= nil and liveMin > 0 then
            appendMeta(T("tip.watch.have_target", {
                have = tostring(liveHave),
                target = tostring(liveMin),
            }))
        end
    elseif type(data.statusLines) == "table" and #data.statusLines > 0 then
        for i = 1, #data.statusLines do
            appendMeta(data.statusLines[i])
        end
        if liveHave ~= nil and liveMin > 0 then
            appendMeta(T("tip.watch.have_target", {
                have = tostring(liveHave),
                target = tostring(liveMin),
            }))
        end
    elseif data.statusDetail and data.statusDetail ~= L"" then
        appendMeta(data.statusDetail)
    elseif liveHave ~= nil and liveMin > 0 then
        appendMeta(T("tip.watch.have_target", {
            have = tostring(liveHave),
            target = tostring(liveMin),
        }))
    end

    return rows
end

function StockPilerTabWatch.OnMouseOverEnabled()
    Tip(T("tip.watch.autogrow_master"))
end

function StockPilerTabWatch.OnMouseOverAdditives()
    Tip(T("tip.watch.additives"))
end

local function BuyJobName(job)
    local name = type(job) == "table" and (job.name or job.label) or nil
    if type(name) == "wstring" and name ~= L"" then
        return name
    end
    local uid = type(job) == "table" and (tonumber(job.uid) or tonumber(job.uniqueID) or 0) or 0
    local function FromRow(row)
        if type(row) == "table" and row.name ~= nil then
            if type(row.name) == "wstring" then
                return row.name
            end
            return towstring(tostring(row.name))
        end
        return nil
    end
    if uid > 0 then
        local Inv = StockPiler.Inventory
        local named = Inv and Inv.GetSample and FromRow(Inv.GetSample(uid)) or nil
        if named == nil then
            local Items = StockPiler.Items
            named = Items and Items.GetByUid and FromRow(Items.GetByUid(uid)) or nil
        end
        if named == nil and type(GetDatabaseItemData) == "function" then
            local ok, data = pcall(GetDatabaseItemData, uid)
            if ok == true then
                named = FromRow(data)
            end
        end
        if type(named) == "wstring" and named ~= L"" then
            return named
        end
        return towstring(tostring(uid))
    end
    if name == nil then
        return towstring("?")
    end
    return towstring(tostring(name))
end

function StockPilerTabWatch.OnMouseOverAutoBuy()
    local text = T("tip.watch.autobuy")
    local Buy = StockPiler.Buy
    local jobs = Buy and Buy.CollectBuyJobs and Buy.CollectBuyJobs()
    if type(jobs) == "table" and #jobs > 0 then
        local VA = StockPiler.VendorAdapter
        local storeOpen = VA and VA.IsStoreOpen and VA.IsStoreOpen() == true
        local shown = {}
        for i = 1, #jobs do
            local job = jobs[i]
            local growable = type(job) == "table" and (job.growable == true or job.isGrowable == true)
            local special = type(job) == "table" and (job.skillUp == true or job.upgradeSeed == true)
            if storeOpen == true or growable ~= true or special == true then
                shown[#shown + 1] = job
            end
        end
        if #shown > 0 then
            local queueKey = storeOpen == true and "tip.watch.autobuy_queue" or "tip.watch.autobuy_queue_estimate"
            text = text .. L"\n" .. T(queueKey)
            local limit = math.min(#shown, 12)
            for i = 1, limit do
                local job = shown[i]
                local count = 0
                if type(job) == "table" then
                    count = tonumber(job.deficit) or tonumber(job.need) or 0
                end
                text = text .. L"\n" .. BuyJobName(job) .. L"  x" .. towstring(tostring(count))
            end
            if #shown > limit then
                text = text .. L"\n" .. T("tip.watch.autobuy_more", { count = #shown - limit })
            end
        end
    end
    Tip(text)
end

function StockPilerTabWatch.OnMouseOverAutoBrew()
    if not CanAutoBrewUi() then
        Tip(T("tip.watch.autobrew_need_apo"))
        return
    end
    Tip(T("tip.watch.autobrew"))
end

function StockPilerTabWatch.OnMouseOverHudButton()
    Tip(T("tip.watch.hud_button"))
end

function StockPilerTabWatch.OnMouseOverHudScale()
    local CB = StockPiler.CraftButton
    if not (CB and CB.IsVisible and CB.IsVisible() == true) then
        Tip(T("tip.watch.hud_lock_need_hud"))
        return
    end
    local scale = CB.GetScale and CB.GetScale() or HUD_SCALE_MIN
    Tip(T("tip.watch.hud_scale", { scale = FormatHudScale(scale) }))
end

function StockPilerTabWatch.OnMouseOverCraftMacro()
    Tip(T("tip.watch.craft_macro"))
end

function StockPilerTabWatch.OnMouseOverOptimisticMode()
    Tip(T("tip.watch.optimistic_mode"))
end

function StockPilerTabWatch.OnMouseOverSkillUpSkills()
    local cultKind, apoKind = SkillUpLevelKinds()
    if cultKind == "ready" and apoKind == "ready" then
        Tip(T("tip.watch.skillup_skills"))
        return
    end
    local cultName = T("watch.skill_name_cult")
    local apoName = T("watch.skill_name_apo")
    Tip(T("tip.watch.skillup_why_pair", {
        cult = SkillUpWhyText(cultKind, cultName),
        apo = SkillUpWhyText(apoKind, apoName),
    }))
end

function StockPilerTabWatch.OnMouseOverSeedBufferEnable()
    if not CanAutoGrowUi() then
        Tip(T("tip.watch.cult_required"))
        return
    end
    Tip(T("tip.watch.seed_buffer"))
end

function StockPilerTabWatch.OnMouseOverUpgradeSeeds()
    if not CanAutoGrowUi() then
        Tip(T("tip.watch.cult_required"))
        return
    end
    Tip(T("tip.watch.upgrade_seeds"))
end

function StockPilerTabWatch.OnMouseOverSeedBuffer()
    if not CanAutoGrowUi() then
        Tip(T("tip.watch.cult_required"))
        return
    end
    Tip(T("tip.watch.seed_buffer"))
end

function StockPilerTabWatch.OnMouseOverReserve()
    Tip(T("tip.watch.reserve_chip"))
end

function StockPilerTabWatch.OnMouseOverBudget()
    local Buy = StockPiler.Buy
    local spent = Buy and Buy.GetSpentBrass and Buy.GetSpentBrass() or 0
    local allowance = Buy and Buy.GetBudgetGold and Buy.GetBudgetGold() or 50
    local spentLabel = (Buy and Buy.FormatMoneyBrass and Buy.FormatMoneyBrass(spent))
        or tostring(spent)
    local remain = Buy and Buy.GetAllowanceRemainingBrass and Buy.GetAllowanceRemainingBrass() or 0
    local remainLabel = (Buy and Buy.FormatMoneyBrass and Buy.FormatMoneyBrass(remain))
        or tostring(remain)
    Tip(T("tip.watch.budget_chip", {
        spent = spentLabel,
        allowance = tostring(allowance) .. "g",
        remain = remainLabel,
    }))
end

function StockPilerTabWatch.OnMouseOverBudgetReset()
    Tip(T("tip.watch.budget_reset"))
end

function StockPilerTabWatch.OnMouseOverIcon()
    StockPiler.ViewList.OnRowChildMouseOver()
    local data = RowDataFromActiveChild()
    if not data then
        return
    end
    if IsSkillUpWatchRow(data) then
        local Caps = StockPiler.TradeSkillCaps
        local skillId = 0
        if tostring(data.skillUpKind or "") == "apo" then
            skillId = Caps and Caps.ApothecaryId and Caps.ApothecaryId() or 4
        else
            skillId = Caps and Caps.CultivationId and Caps.CultivationId() or 3
        end
        TipTradeSkill(skillId)
        return
    end
    local uid = tonumber(data.uniqueID) or tonumber(data.plantUid) or 0
    local itemData = data.itemData
    local isPlant = IsPlantWatchRow(data)
    if StockPiler.Inventory then
        if StockPiler.Inventory.GetSample and uid > 0 and isPlant then
            local sample = StockPiler.Inventory.GetSample(uid)
            if type(sample) == "table" then
                itemData = sample
            end
        end
        if StockPiler.Inventory.ResolvePotionItemData then
            itemData = StockPiler.Inventory.ResolvePotionItemData(
                data.potionKey or data.potionBaseKey or data.plantKey,
                uid,
                itemData
            )
            if type(itemData) == "table" then
                data.itemData = itemData
                -- Refresh rarity tint if we just got a richer sample.
                data.nameR, data.nameG, data.nameB = nil, nil, nil
                EnsureWatchNameRarityColors(data)
            end
        end
    end
    local tipOpts = (isPlant or IsUpgradeWatchRow(data)) and { allowWithoutUse = true } or nil
    if StockPiler.Inventory and StockPiler.Inventory.ShowItemTooltip
        and StockPiler.Inventory.ShowItemTooltip(itemData, SystemData.ActiveWindow.name, tipOpts)
    then
        return
    end
    Tip(data.name or (isPlant and T("ui.item_fallback") or T("ui.potion_fallback")))
end

function StockPilerTabWatch.OnMouseOverName()
    StockPilerTabWatch.OnMouseOverIcon()
end

function StockPilerTabWatch.OnMouseOverStatus()
    StockPiler.ViewList.OnRowChildMouseOver()
    local data = RowDataFromActiveChild()
    if not data then
        return
    end
    local RT = StockPiler.RecipeTooltip
    if not RT or not RT.ShowColoredRows then
        Tip(data.statusText or T("watch.col.status"))
        return
    end

    local engineMax = RT.EnsureRows and RT.EnsureRows(17) or 17
    local snapGen = 0
    if StockPiler.Inventory and StockPiler.Inventory.GetSnapGen then
        snapGen = tonumber(StockPiler.Inventory.GetSnapGen()) or 0
    end
    local genKey = PlanTipCacheKey() .. ":s" .. tostring(snapGen)
    local watchKey = tostring(data.potionKey or data.id or "")
        .. ":k" .. tostring(data.statusKey or "")
        .. ":t" .. ToNarrow(data.statusText or "")
    local cache = StockPilerTabWatch._statusTipCache
    if type(cache) ~= "table" or cache.genKey ~= genKey then
        cache = { genKey = genKey, byWatch = {} }
        StockPilerTabWatch._statusTipCache = cache
    end
    local tipRows = watchKey ~= "" and cache.byWatch[watchKey] or nil
    if type(tipRows) ~= "table" then
        tipRows = BuildStatusTooltipRows(data)
        TrimStatusTooltipRows(tipRows, engineMax)
        if watchKey ~= "" then
            cache.byWatch[watchKey] = tipRows
        end
    end

    RT.ShowColoredRows(
        SystemData.ActiveWindow.name,
        tipRows,
        Tooltips.ANCHOR_WINDOW_TOP,
        engineMax
    )
end

function StockPilerTabWatch.OnMouseOverStock()
    StockPiler.ViewList.OnRowChildMouseOver()
    local data = RowDataFromActiveChild()
    if not data then
        return
    end
    if IsUpgradeWatchRow(data) then
        Tip(T("upgrade.watch.tip"))
        return
    end
    if IsSkillUpWatchRow(data) then
        Tip(T("tip.watch.skillup_metrics"))
        return
    end
    Tip(T("tip.watch.have_target", {
        have = tostring(data.potionHave or 0),
        target = tostring(data.target or 0),
    }))
end

function StockPilerTabWatch.OnMouseOverCraftable()
    StockPiler.ViewList.OnRowChildMouseOver()
    local data = RowDataFromActiveChild()
    if not data or IsPlantWatchRow(data) then
        return
    end
    if IsUpgradeWatchRow(data) then
        Tip(T("upgrade.watch.tip"))
        return
    end
    if IsSkillUpWatchRow(data) then
        Tip(T("tip.watch.skillup_metrics"))
        return
    end
    local craftable = tonumber(data.craftable) or 0
    if craftable <= 0 then
        Tip(T("tip.watch.craftable_none"))
        return
    end
    if data.seedBufferShort == true or data.craftableSafe == false then
        Tip(T("tip.watch.craftable_seed_buffer"))
        return
    end
    Tip(T("tip.watch.craftable_ready"))
end

function StockPilerTabWatch.OnMouseOverTarget()
    StockPiler.ViewList.OnRowChildMouseOver()
    local data = RowDataFromActiveChild()
    if data and IsUpgradeWatchRow(data) then
        Tip(T("upgrade.watch.tip"))
        return
    end
    if data and IsSkillUpWatchRow(data) then
        Tip(T("tip.watch.skillup_metrics"))
        return
    end
    Tip(T("tip.watch.target_chip"))
end

function StockPilerTabWatch.OnMouseOverPrio()
    StockPiler.ViewList.OnRowChildMouseOver()
    Tip(T("tip.watch.prio_chip"))
end

function StockPilerTabWatch.OnMouseOverRowAutoGrow()
    StockPiler.ViewList.OnRowChildMouseOver()
    local data = RowDataFromActiveChild()
    if data and IsUpgradeWatchRow(data) then
        Tip(T("upgrade.watch.ag_tip"))
        return
    end
    if data and IsSkillUpWatchRow(data) and tostring(data.skillUpKind or "") == "cult" then
        Tip(T("tip.watch.skillup_cult_autogrow"))
        return
    end
    Tip(T("tip.watch.row_autogrow"))
end

function StockPilerTabWatch.OnMouseOverLoad()
    StockPiler.ViewList.OnRowChildMouseOver()
    local data = RowDataFromActiveChild()
    if StockPiler.BrewTooltip and StockPiler.BrewTooltip.ShowRow then
        StockPiler.BrewTooltip.ShowRow(SystemData.ActiveWindow.name, data)
        return
    end
    Tip(T("watch.col.brew"))
end
