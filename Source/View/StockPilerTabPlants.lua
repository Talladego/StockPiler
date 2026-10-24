----------------------------------------------------------------
-- StockPilerTabPlants -- known plants (watch / filters / forget)
----------------------------------------------------------------

StockPilerTabPlants = {}

local function T(key, tokens)
    return StockPiler.Util.T(key, tokens)
end

StockPilerTabPlants.listData = {}
StockPilerTabPlants.displayOrder = {}

local ICON_SCALE = 0.34

local SORT_IDS = {
    [1] = "name",
    [2] = "effect",
    [3] = "power",
    [4] = "stability",
    [5] = "superCrit",
    [6] = "stock",
    [7] = "stock",
    [8] = "watch",
    [9] = "level",
    [10] = "multiplier",
    [11] = "duration",
}

local SORT_HEADERS = {
    watch = "SPTabPlantsSortWatch",
    name = "SPTabPlantsSortName",
    level = "SPTabPlantsSortLevel",
    effect = "SPTabPlantsSortEffect",
    power = "SPTabPlantsSortPower",
    stability = "SPTabPlantsSortStability",
    multiplier = "SPTabPlantsSortMultiplier",
    duration = "SPTabPlantsSortDuration",
    superCrit = "SPTabPlantsSortSuperCrit",
    stock = "SPTabPlantsSortStock",
}

local function ToNarrow(text)
    return StockPiler.Util.ToNarrow(text)
end

local function GetSettings()
    if StockPiler.Persistence and StockPiler.Persistence.EnsureSettings then
        return StockPiler.Persistence.EnsureSettings()
    end
    StockPiler.Settings = StockPiler.Settings or {}
    return StockPiler.Settings
end

local function ItemRarityNameColor(itemData)
    return StockPiler.ViewList.ItemRarityNameColor(itemData)
end

local function FormatSignedStat(n)
    return StockPiler.ViewList.FormatSignedStat(n, { zeroAsDash = true })
end

-- Match Potions tab: SPECIAL_CHANCE is already a percent points value (1 -> "1%").
local function FormatPercentStat(n)
    return StockPiler.ViewList.FormatPercentStat(n)
end

local function EffectTextForRow(effectKey)
    return StockPiler.ViewList.EffectTextForRow(effectKey, { emptyDash = true })
end

local function IconMarkup(iconNum)
    iconNum = tonumber(iconNum) or 0
    if iconNum <= 0 then
        return L""
    end
    return towstring(string.format("<icon%05d> ", iconNum))
end

local function CompareName(a, b)
    local na = string.lower(ToNarrow(a.name))
    local nb = string.lower(ToNarrow(b.name))
    if na ~= nb then
        return na < nb
    end
    local ua = tonumber(a.plantUid) or tonumber(a.uniqueID) or 0
    local ub = tonumber(b.plantUid) or tonumber(b.uniqueID) or 0
    if ua ~= ub then
        return ua < ub
    end
    return tostring(a.plantKey or "") < tostring(b.plantKey or "")
end

local function CompareRows(a, b, column, ascending)
    local function finish(less)
        if ascending then
            return less
        end
        return not less
    end
    if column == "level" then
        if (a.levelNum or 0) == (b.levelNum or 0) then
            return CompareName(a, b)
        end
        return finish((a.levelNum or 0) < (b.levelNum or 0))
    elseif column == "effect" then
        local ea = ToNarrow(a.effectText)
        local eb = ToNarrow(b.effectText)
        if ea == eb then
            return CompareName(a, b)
        end
        return finish(ea < eb)
    elseif column == "power" then
        if (a.powerNum or 0) == (b.powerNum or 0) then
            return CompareName(a, b)
        end
        return finish((a.powerNum or 0) < (b.powerNum or 0))
    elseif column == "stability" then
        if (a.stabilityNum or 0) == (b.stabilityNum or 0) then
            return CompareName(a, b)
        end
        return finish((a.stabilityNum or 0) < (b.stabilityNum or 0))
    elseif column == "multiplier" then
        if (a.multiplierNum or 0) == (b.multiplierNum or 0) then
            return CompareName(a, b)
        end
        return finish((a.multiplierNum or 0) < (b.multiplierNum or 0))
    elseif column == "duration" then
        if (a.durationNum or 0) == (b.durationNum or 0) then
            return CompareName(a, b)
        end
        return finish((a.durationNum or 0) < (b.durationNum or 0))
    elseif column == "superCrit" then
        if (a.superCritNum or 0) == (b.superCritNum or 0) then
            return CompareName(a, b)
        end
        return finish((a.superCritNum or 0) < (b.superCritNum or 0))
    elseif column == "stock" or column == "have" then
        if (a.have or 0) == (b.have or 0) then
            return CompareName(a, b)
        end
        return finish((a.have or 0) < (b.have or 0))
    elseif column == "watch" then
        local wa = a.watched == true
        local wb = b.watched == true
        if wa == wb then
            return CompareName(a, b)
        end
        return finish(wa and not wb)
    end
    return CompareName(a, b)
end

local function SortRows(rows)
    local s = GetSettings()
    local column = s.plantSortColumn or "name"
    local ascending = s.plantSortAscending ~= false
    table.sort(rows, function(a, b)
        return CompareRows(a, b, column, ascending)
    end)
end

local function EffectCycle()
    return StockPiler.ViewList.EffectFilterCycle("plant")
end

local function InitEffectCombo()
    local s = GetSettings()
    local current = tostring(s.plantEffectFilter or "")
    if current ~= "" then
        local cycle = EffectCycle()
        local found = false
        for i = 1, #cycle do
            if cycle[i] == current then
                found = true
                break
            end
        end
        if not found then
            s.plantEffectFilter = ""
            current = ""
        end
    end
    StockPiler.ViewList.InitEffectCombo(
        "SPTabPlantsEffectCombo",
        current,
        EffectTextForRow,
        "plant"
    )
end

local LEVEL_FILTERS = { 0, 1, 25, 50, 75, 100, 125, 150, 175, 200 }

local function InitLevelCombo()
    local combo = "SPTabPlantsLevelCombo"
    if not DoesWindowExist(combo) then
        return
    end
    ComboBoxClearMenuItems(combo)
    ComboBoxAddMenuItem(combo, T("plants.all_levels"))
    for i = 2, #LEVEL_FILTERS do
        ComboBoxAddMenuItem(combo, towstring(tostring(LEVEL_FILTERS[i])))
    end
    local current = tonumber(GetSettings().plantLevelFilter) or 0
    local selected = 1
    for i = 1, #LEVEL_FILTERS do
        if LEVEL_FILTERS[i] == current then
            selected = i
            break
        end
    end
    ComboBoxSetSelectedMenuItem(combo, selected)
end

local function FiltersAreSet(s)
    if type(s) ~= "table" then
        return false
    end
    if tostring(s.plantNameFilter or "") ~= "" then
        return true
    end
    if tostring(s.plantEffectFilter or "") ~= "" then
        return true
    end
    return (tonumber(s.plantLevelFilter) or 0) > 0
end

local function PaintClearButton()
    StockPiler.ViewList.PaintClearButton("SPTabPlantsClearFilters", FiltersAreSet(GetSettings()))
end

local function UpdateSortHeaderLabels()
    local labels = {
        name = T("plants.sort.name"),
        level = T("plants.sort.level"),
        effect = T("plants.sort.effect"),
        power = T("plants.sort.power"),
        stability = T("plants.sort.stability"),
        multiplier = T("plants.sort.multiplier"),
        duration = T("plants.sort.duration"),
        superCrit = T("plants.sort.super_crit"),
        stock = T("plants.sort.stock"),
    }
    for key, win in pairs(SORT_HEADERS) do
        if DoesWindowExist(win) and labels[key] then
            ButtonSetText(win, labels[key])
        end
    end
    if DoesWindowExist("SPTabPlantsSortRecipes") then
        ButtonSetText("SPTabPlantsSortRecipes", T("plants.sort.recipes"))
    end
    if DoesWindowExist("SPTabPlantsSortForget") then
        ButtonSetText("SPTabPlantsSortForget", T("plants.sort.forget"))
    end
end

local function UpdateSortHeaders()
    UpdateSortHeaderLabels()
    local s = GetSettings()
    StockPiler.ViewList.UpdateSortArrows(
        SORT_HEADERS,
        s.plantSortColumn or "name",
        s.plantSortAscending ~= false
    )
end

local function BuildVisibleList()
    local s = GetSettings()
    if type(s) ~= "table" then
        return
    end
    local nameFilter = string.lower(tostring(s.plantNameFilter or ""))
    local effectFilter = s.plantEffectFilter or ""
    local levelFilter = tonumber(s.plantLevelFilter) or 0
    local rows = {}

    if StockPiler.Inventory and StockPiler.Inventory.RefreshAllIfNeeded then
        StockPiler.Inventory.RefreshAllIfNeeded()
    end

    local Catalog = StockPiler.Catalog
    local plants = Catalog and Catalog.ListPlantEntries and Catalog.ListPlantEntries() or {}

    for i = 1, #plants do
        local plant = plants[i]
        local plantKey = plant.plantKey
        local watch = Catalog and Catalog.GetPlantWatch and Catalog.GetPlantWatch(plantKey)
            or { enabled = false, targetStock = 40 }
        local watched = watch.enabled == true
        local have = tonumber(plant.have) or 0
        if Catalog and Catalog.PlantHave then
            have = Catalog.PlantHave(plant.plantUid)
        end
        local effectKey = plant.effectKey
        local include = true
        if nameFilter ~= "" then
            local nm = string.lower(ToNarrow(plant.name))
            if string.find(nm, nameFilter, 1, true) == nil then
                include = false
            end
        end
        if include and effectFilter ~= "" and tostring(effectKey or "") ~= effectFilter then
            include = false
        end
        if include and levelFilter > 0 and (tonumber(plant.apoLevel) or 0) ~= levelFilter then
            include = false
        end
        if include then
            local powerNum = tonumber(plant.power) or 0
            local stabilityNum = tonumber(plant.stability) or 0
            local durationNum = tonumber(plant.duration) or 0
            local multiplierNum = tonumber(plant.multiplier) or 0
            local superCritNum = tonumber(plant.superCrit) or 0
            local levelNum = tonumber(plant.apoLevel) or 0
            local stockW = towstring(tostring(have))
            local nameR, nameG, nameB = ItemRarityNameColor(plant.itemData)
            rows[#rows + 1] = {
                id = plantKey,
                plantKey = plantKey,
                plantUid = plant.plantUid,
                seedUid = plant.seedUid,
                name = plant.name,
                effectKey = effectKey,
                effectText = EffectTextForRow(effectKey),
                powerNum = powerNum,
                powerText = FormatSignedStat(powerNum),
                stabilityNum = stabilityNum,
                stabilityText = FormatSignedStat(stabilityNum),
                durationNum = durationNum,
                durationText = FormatSignedStat(durationNum),
                multiplierNum = multiplierNum,
                multiplierText = FormatSignedStat(multiplierNum),
                superCritNum = superCritNum,
                superCritText = FormatPercentStat(superCritNum),
                stockText = stockW,
                haveText = L"",
                yieldText = stockW,
                levelNum = levelNum,
                levelText = towstring(levelNum > 0 and tostring(levelNum) or ""),
                have = have,
                watched = watched,
                watchBlocked = (StockPiler.Watch and StockPiler.Watch.CanEnablePlantWatch
                    and StockPiler.Watch.CanEnablePlantWatch(plantKey) ~= true) == true,
                iconNum = tonumber(plant.iconNum) or 0,
                itemData = plant.itemData,
                recipes = plant.recipes,
                recipeCount = tonumber(plant.recipeCount) or 0,
                hasRecipes = (tonumber(plant.recipeCount) or 0) > 0,
                nameR = nameR,
                nameG = nameG,
                nameB = nameB,
                kind = "plant",
            }
        end
    end

    SortRows(rows)
    StockPilerTabPlants.listData = rows
    local order = {}
    local structureKey = tostring(#rows)
    for i = 1, #rows do
        order[i] = i
        local row = rows[i]
        local id = type(row) == "table" and (row.plantKey or row.id or row.plantUid) or ""
        structureKey = structureKey .. "|" .. tostring(id)
    end
    StockPilerTabPlants.displayOrder = order
    StockPilerTabPlants._listStructureKey = structureKey
end

function StockPilerTabPlants.Initialize()
    if DoesWindowExist("SPTabPlantsBannerTitle") then
        LabelSetText("SPTabPlantsBannerTitle", T("plants.banner_title"))
    end
    if DoesWindowExist("SPTabPlantsBannerText") then
        LabelSetText("SPTabPlantsBannerText", T("plants.banner_text"))
    end
    if DoesWindowExist("SPTabPlantsSearchLabel") then
        LabelSetText("SPTabPlantsSearchLabel", T("potions.search"))
    end
    if DoesWindowExist("SPTabPlantsEffectLabel") then
        LabelSetText("SPTabPlantsEffectLabel", T("potions.effect"))
    end
    if DoesWindowExist("SPTabPlantsLevelLabel") then
        LabelSetText("SPTabPlantsLevelLabel", T("plants.level"))
    end
    if DoesWindowExist("SPTabPlantsClearFilters") then
        ButtonSetText("SPTabPlantsClearFilters", T("filters.clear"))
    end
    local s = GetSettings()
    if DoesWindowExist("SPTabPlantsSearchBox") then
        TextEditBoxSetText("SPTabPlantsSearchBox", towstring(s.plantNameFilter or ""))
    end
    InitEffectCombo()
    InitLevelCombo()
    UpdateSortHeaders()
    StockPilerTabPlants.Refresh()
end

function StockPilerTabPlants.Refresh()
    UpdateSortHeaders()
    PaintClearButton()
    local effectSig = StockPiler.ViewList.EffectFilterSignature("plant")
    if effectSig ~= StockPilerTabPlants._effectSig then
        StockPilerTabPlants._effectSig = effectSig
        InitEffectCombo()
    end
    local prevKey = StockPilerTabPlants._listStructureKey
    BuildVisibleList()
    local keyChanged = prevKey ~= StockPilerTabPlants._listStructureKey
    if DoesWindowExist("SPTabPlantsList") then
        -- Empty→full ListBoxSetDisplayOrder resets scroll; skip when row ids unchanged.
        if keyChanged or prevKey == nil then
            ListBoxSetDisplayOrder("SPTabPlantsList", {})
            ListBoxSetDisplayOrder("SPTabPlantsList", StockPilerTabPlants.displayOrder)
        end
        StockPilerTabPlants.UpdateRows()
    end
end

--- Bag-snap live stock (CountByUid) without ListBox rebuild — Watch catchup parity.
function StockPilerTabPlants.PatchLiveHave()
    local list = StockPilerTabPlants.listData
    if type(list) ~= "table" or #list == 0 then
        return false
    end
    local Catalog = StockPiler.Catalog
    local Inv = StockPiler.Inventory
    local dirty = false
    for i = 1, #list do
        local row = list[i]
        if type(row) == "table" then
            local plantUid = tonumber(row.plantUid) or 0
            local have = 0
            if Catalog and Catalog.PlantHave then
                have = tonumber(Catalog.PlantHave(plantUid)) or 0
            elseif plantUid > 0 and Inv and Inv.CountByUid then
                have = tonumber(Inv.CountByUid(plantUid)) or 0
            end
            if (tonumber(row.have) or 0) ~= have then
                row.have = have
                local stockW = towstring(tostring(have))
                row.stockText = stockW
                row.yieldText = stockW
                dirty = true
            end
        end
    end
    return dirty
end

function StockPilerTabPlants.UpdateRows()
    if not SPTabPlantsList then
        return
    end
    local numVisible = tonumber(SPTabPlantsList.numVisibleRows) or 12
    local indices = SPTabPlantsList.PopulatorIndices
    local listData = StockPilerTabPlants.listData
    for rowIndex = 1, numVisible do
        local rowName = "SPTabPlantsListRow" .. tostring(rowIndex)
        if DoesWindowExist(rowName) then
            local dataIndex = type(indices) == "table" and indices[rowIndex] or nil
            local data = type(listData) == "table" and dataIndex and listData[dataIndex] or nil
            if type(data) == "table" then
                WindowSetShowing(rowName, true)
                StockPiler.ViewList.ApplyRowStripe(rowName .. "Background", rowIndex)
                if DoesWindowExist(rowName .. "Watch") then
                    local blocked = data.watchBlocked == true
                    if StockPiler.Watch and StockPiler.Watch.CanEnablePlantWatch then
                        blocked = StockPiler.Watch.CanEnablePlantWatch(data.plantKey) ~= true
                        data.watchBlocked = blocked
                    end
                    StockPiler.ViewList.PaintWatchCheckbox(
                        rowName .. "Watch",
                        data.watched == true,
                        blocked
                    )
                end
                if DoesWindowExist(rowName .. "Icon") then
                    StockPiler.ViewList.SetIconTexture(rowName .. "Icon", data.iconNum, ICON_SCALE)
                end
                if DoesWindowExist(rowName .. "Name") then
                    LabelSetText(rowName .. "Name", data.name or L"")
                    LabelSetTextColor(rowName .. "Name", data.nameR or 255, data.nameG or 255, data.nameB or 255)
                end
                if DoesWindowExist(rowName .. "Yield") then
                    LabelSetText(rowName .. "Yield", data.stockText or towstring(tostring(data.have or 0)))
                end
                if DoesWindowExist(rowName .. "Recipe") then
                    WindowSetShowing(rowName .. "Recipe", data.hasRecipes == true)
                end
            else
                WindowSetShowing(rowName, false)
            end
        end
    end
end

local function RowDataFromSender()
    local rowIndex = WindowGetId(WindowGetParent(SystemData.ActiveWindow.name))
    local dataIndex = ListBoxGetDataIndex("SPTabPlantsList", rowIndex)
    local listData = StockPilerTabPlants.listData
    if type(listData) ~= "table" or dataIndex == nil then
        return nil
    end
    return listData[dataIndex]
end

function StockPilerTabPlants.OnToggleWatch()
    local data = RowDataFromSender()
    if type(data) ~= "table" or data.plantKey == nil then
        return
    end
    local Watch = StockPiler.Watch
    if not (Watch and Watch.SetPlantEnabled) then
        return
    end
    local cur = Watch.GetPlantWatch and Watch.GetPlantWatch(data.plantKey)
    local enable = not (cur and cur.enabled == true)
    local win = SystemData.ActiveWindow.name
    if enable then
        local blocked = data.watchBlocked == true
        if Watch.CanEnablePlantWatch then
            blocked = Watch.CanEnablePlantWatch(data.plantKey) ~= true
            data.watchBlocked = blocked
        end
        if blocked then
            if DoesWindowExist(win) then
                ButtonSetPressedFlag(win, false)
                if ButtonSetDisabledFlag then
                    ButtonSetDisabledFlag(win, true)
                end
            end
            Watch.SetPlantEnabled(data.plantKey, true, { fromPlantsToggle = true })
            return
        end
    end
    local _, ok = Watch.SetPlantEnabled(data.plantKey, enable, { fromPlantsToggle = true })
    if enable and ok == false then
        enable = false
        data.watchBlocked = true
    end
    data.watched = enable
    if DoesWindowExist(win) then
        ButtonSetPressedFlag(win, enable)
        if ButtonSetDisabledFlag then
            ButtonSetDisabledFlag(win, data.watchBlocked == true)
        end
    end
    if StockPilerTabWatch and StockPilerTabWatch.AfterCatalogWatchToggle then
        StockPilerTabWatch.AfterCatalogWatchToggle({
            enabled = enable,
            plantKey = data.plantKey,
            kind = "plant",
        })
    else
        if StockPiler.PlanSnapshot and StockPiler.PlanSnapshot.Invalidate then
            StockPiler.PlanSnapshot.Invalidate()
        end
        if StockPiler.Scheduler and StockPiler.Scheduler.EnqueuePlanRebuild then
            StockPiler.Scheduler.EnqueuePlanRebuild({ urgent = true })
        end
        if StockPiler.Ui then
            if StockPiler.Ui.BypassWatchThrottle then
                StockPiler.Ui.BypassWatchThrottle()
            end
            if StockPiler.Ui.MarkWatchUiDirty then
                StockPiler.Ui.MarkWatchUiDirty()
            end
        end
        if StockPilerWindow and StockPilerWindow.SyncActionReadiness then
            StockPilerWindow.SyncActionReadiness()
        end
    end
end

function StockPilerTabPlants.OnSortColumn()
    local id = WindowGetId(SystemData.ActiveWindow.name)
    local col = SORT_IDS[id]
    if col == nil then
        return
    end
    local s = GetSettings()
    if s.plantSortColumn == col then
        s.plantSortAscending = not (s.plantSortAscending ~= false)
    else
        s.plantSortColumn = col
        s.plantSortAscending = true
    end
    UpdateSortHeaders()
    StockPilerTabPlants.Refresh()
end

function StockPilerTabPlants.OnSearchChanged()
    local s = GetSettings()
    if DoesWindowExist("SPTabPlantsSearchBox") then
        s.plantNameFilter = ToNarrow(TextEditBoxGetText("SPTabPlantsSearchBox"))
    end
    StockPilerTabPlants.Refresh()
end

function StockPilerTabPlants.OnEffectComboChanged()
    local s = GetSettings()
    local sel = ComboBoxGetSelectedMenuItem("SPTabPlantsEffectCombo")
    local cycle = EffectCycle()
    s.plantEffectFilter = cycle[sel] or ""
    StockPilerTabPlants.Refresh()
end

function StockPilerTabPlants.OnLevelComboChanged()
    local s = GetSettings()
    local sel = tonumber(ComboBoxGetSelectedMenuItem("SPTabPlantsLevelCombo")) or 1
    local nextLevel = LEVEL_FILTERS[sel] or 0
    if (tonumber(s.plantLevelFilter) or 0) == nextLevel then
        return
    end
    s.plantLevelFilter = nextLevel
    StockPilerTabPlants.Refresh()
end

function StockPilerTabPlants.OnClearFilters()
    local s = GetSettings()
    s.plantNameFilter = ""
    s.plantEffectFilter = ""
    s.plantLevelFilter = 0
    if DoesWindowExist("SPTabPlantsSearchBox") then
        TextEditBoxSetText("SPTabPlantsSearchBox", L"")
    end
    InitEffectCombo()
    InitLevelCombo()
    StockPilerTabPlants.Refresh()
end

function StockPilerTabPlants.OnMouseOverClearFilters()
    StockPiler.ViewList.Tip(T("tip.filters.clear"))
end

function StockPilerTabPlants.OnMouseOverIcon()
    StockPiler.ViewList.OnRowChildMouseOver()
    local data = RowDataFromSender()
    if type(data) ~= "table" then
        return
    end
    local itemData = data.itemData
    local uid = tonumber(data.plantUid) or 0
    if StockPiler.Inventory and StockPiler.Inventory.ResolvePotionItemData and uid > 0 then
        itemData = StockPiler.Inventory.ResolvePotionItemData(nil, uid, itemData) or itemData
    end
    if StockPiler.Inventory and StockPiler.Inventory.ShowItemTooltip
        and StockPiler.Inventory.ShowItemTooltip(itemData, SystemData.ActiveWindow.name, { allowWithoutUse = true })
    then
        return
    end
    -- Same placeholder as Potions when bag/DB tooltip cannot be built.
    if type(Tooltips) == "table" and type(Tooltips.CreateTextOnlyTooltip) == "function" then
        Tooltips.CreateTextOnlyTooltip(
            SystemData.ActiveWindow.name,
            data.name or T("ui.plant_fallback")
        )
        if Tooltips.AnchorTooltip and Tooltips.ANCHOR_WINDOW_RIGHT then
            Tooltips.AnchorTooltip(Tooltips.ANCHOR_WINDOW_RIGHT)
        end
    end
end

function StockPilerTabPlants.OnMouseOverRecipe()
    StockPiler.ViewList.OnRowChildMouseOver()
    local data = RowDataFromSender()
    if type(data) ~= "table" or type(data.recipes) ~= "table" then
        return
    end
    local tipRows = {}
    local seen = {}
    for i = 1, #data.recipes do
        local r = data.recipes[i]
        local potions = type(r) == "table" and r.potions or nil
        if type(potions) == "table" then
            for j = 1, #potions do
                local p = potions[j]
                if type(p) == "table" then
                    local uid = tonumber(p.outputUid) or 0
                    local key = uid > 0 and tostring(uid) or ToNarrow(p.name)
                    if key ~= "" and seen[key] ~= true then
                        seen[key] = true
                        local itemData = p.itemData
                        if uid > 0 and StockPiler.Inventory and StockPiler.Inventory.ResolvePotionItemData then
                            itemData = StockPiler.Inventory.ResolvePotionItemData(nil, uid, itemData) or itemData
                        end
                        local iconNum = tonumber(p.iconNum) or tonumber(itemData and itemData.iconNum) or 0
                        local rR, rG, rB = ItemRarityNameColor(itemData or p)
                        tipRows[#tipRows + 1] = {
                            sort = string.lower(ToNarrow(p.name)),
                            text = IconMarkup(iconNum) .. (p.name or L""),
                            kind = "body",
                            color = { r = rR, g = rG, b = rB },
                        }
                    end
                end
            end
        elseif type(r) == "table" and type(r.potionNames) == "table" then
            for j = 1, #r.potionNames do
                local nm = ToNarrow(r.potionNames[j])
                if nm ~= "" and seen[nm] ~= true then
                    seen[nm] = true
                    tipRows[#tipRows + 1] = {
                        sort = string.lower(nm),
                        text = r.potionNames[j],
                        kind = "body",
                    }
                end
            end
        end
    end
    table.sort(tipRows, function(a, b)
        return (a.sort or "") < (b.sort or "")
    end)
    if #tipRows == 0 then
        tipRows[1] = { text = T("plants.recipes_none"), kind = "meta" }
    end
    table.insert(tipRows, 1, {
        text = T("plants.recipes_tip_title"),
        kind = "title",
    })
    if StockPiler.RecipeTooltip and StockPiler.RecipeTooltip.ShowColoredRows then
        StockPiler.RecipeTooltip.ShowColoredRows(
            SystemData.ActiveWindow.name,
            tipRows,
            Tooltips and Tooltips.ANCHOR_WINDOW_RIGHT
        )
        return
    end
    local lines = {}
    for i = 1, #tipRows do
        lines[#lines + 1] = ToNarrow(tipRows[i].text)
    end
    if Tooltips and Tooltips.CreateTextOnlyTooltip then
        Tooltips.CreateTextOnlyTooltip(SystemData.ActiveWindow.name, towstring(table.concat(lines, "\n")))
        Tooltips.AnchorTooltip(Tooltips.ANCHOR_WINDOW_RIGHT)
    end
end

function StockPilerTabPlants.OnMouseOverForget()
    StockPiler.ViewList.OnRowChildMouseOver()
    StockPiler.ViewList.ShowTextTip(SystemData.ActiveWindow.name, T("tip.plants.forget"))
end

function StockPilerTabPlants.ConfirmForgetPlant(uid)
    uid = tonumber(uid) or 0
    if uid <= 0 then
        return
    end
    if StockPiler.Catalog and StockPiler.Catalog.ForgetPlant then
        StockPiler.Catalog.ForgetPlant(uid)
    end
    local plantKey = StockPiler.Watch and StockPiler.Watch.PlantKeyFromUid
        and StockPiler.Watch.PlantKeyFromUid(uid) or ("plant:" .. tostring(uid))
    if StockPilerTabWatch and StockPilerTabWatch.AfterCatalogWatchToggle then
        StockPilerTabWatch.AfterCatalogWatchToggle({
            enabled = false,
            plantKey = plantKey,
            kind = "plant",
        })
    elseif StockPilerTabWatch and StockPilerTabWatch.Refresh then
        StockPilerTabWatch.Refresh({ forcePlan = true })
    end
    StockPilerTabPlants.Refresh()
end

function StockPilerTabPlants.OnForgetRow()
    local data = RowDataFromSender()
    if type(data) ~= "table" then
        return
    end
    local uid = tonumber(data.plantUid) or 0
    if uid <= 0 then
        return
    end
    local name = ToNarrow(data.name)
    StockPiler.ViewList.ConfirmTwoButton(
        T("plants.forget_confirm", { name = towstring(name) }),
        function()
            StockPilerTabPlants.ConfirmForgetPlant(uid)
        end
    )
end
