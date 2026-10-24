----------------------------------------------------------------
-- StockPilerTabPotions -- known potions list (watch / filters / forget)
----------------------------------------------------------------

StockPilerTabPotions = {}

local function T(key, tokens)
    return StockPiler.Util.T(key, tokens)
end

StockPilerTabPotions.listData = {}
StockPilerTabPotions.displayOrder = {}

local ICON_SCALE = 0.34
local TAB_ROOT = "SPTabPotions"

local SORT_IDS = {
    [1] = "name",
    [2] = "effect",
    [3] = "power",
    [4] = "stability",
    [5] = "superCrit",
    [6] = "yield",
    [7] = "have",
    [8] = "watch",
    [9] = "level",
    [10] = "multiplier",
    [11] = "duration",
}

local SORT_HEADERS = {
    watch = "SPTabPotionsSortWatch",
    name = "SPTabPotionsSortName",
    level = "SPTabPotionsSortLevel",
    effect = "SPTabPotionsSortEffect",
    power = "SPTabPotionsSortPower",
    stability = "SPTabPotionsSortStability",
    duration = "SPTabPotionsSortDuration",
    multiplier = "SPTabPotionsSortMultiplier",
    superCrit = "SPTabPotionsSortSuperCrit",
    yield = "SPTabPotionsSortYield",
    have = "SPTabPotionsSortHave",
}

local function ToNarrow(text)
    return StockPiler.Util.ToNarrow(text)
end

local function GetSettings()
    if StockPiler.Persistence and StockPiler.Persistence.EnsureSettings then
        return StockPiler.Persistence.EnsureSettings()
    end
    return StockPiler.Settings
end

local function EffectTextForRow(effectKey)
    return StockPiler.ViewList.EffectTextForRow(effectKey)
end

local function ItemRarityNameColor(itemData)
    return StockPiler.ViewList.ItemRarityNameColor(itemData)
end

local function FormatSignedStat(value)
    return StockPiler.ViewList.FormatSignedStat(value)
end

local function FormatPercentStat(value)
    return StockPiler.ViewList.FormatPercentStat(value)
end

local function FormatYieldStat(value)
    value = tonumber(value) or 0
    if value <= 0 then
        return T("ui.dash")
    end
    local rounded = math.floor(value + 0.5)
    if math.abs(value - rounded) < 0.05 then
        return towstring(tostring(rounded))
    end
    return towstring(string.format("%.1f", value))
end

local function ApplyPotionStats(row, itemData)
    local dash = T("ui.dash")
    row.rankNum = 0
    row.levelNum = 0
    row.levelText = dash
    if StockPiler.Classify and StockPiler.Classify.GetPotionStats then
        local stats = StockPiler.Classify.GetPotionStats(itemData)
        if type(stats) == "table" then
            row.rankNum = tonumber(stats.rank) or tonumber(stats.level) or 0
            row.levelNum = tonumber(stats.level) or row.rankNum
            if type(stats.levelText) == "wstring" and stats.levelText ~= L"" then
                row.levelText = stats.levelText
            elseif row.levelNum > 0 then
                row.levelText = towstring(tostring(row.levelNum))
            end
            if (not row.effectKey or row.effectKey == "") and stats.effectKey then
                row.effectKey = stats.effectKey
                row.effectText = stats.effectText or EffectTextForRow(stats.effectKey)
            end
            return
        end
    end
    if type(itemData) == "table" then
        local lvl = tonumber(itemData.iLevel) or tonumber(itemData.level) or 0
        row.rankNum = lvl
        row.levelNum = lvl
        if lvl > 0 then
            row.levelText = towstring(tostring(lvl))
        end
    end
end

local function BuildRecipeDataForPotion(potionName, recipe, potionLevel, potionUid, potionBase)
    if type(recipe) ~= "table" then
        return nil
    end
    local uid = tonumber(potionUid) or tonumber(recipe.outputUid) or 0
    local RS = StockPiler.RecipeSpec
    local attempts = tonumber(recipe.brewAttempts) or 0
    local successes = tonumber(recipe.brewSuccesses) or 0
    local successRate = nil
    -- Prefer per-outcome rate so Potent / good siblings on one fingerprint
    -- show distinct odds (outcome.successes / brewAttempts).
    if RS and RS.OutcomeSuccessStats then
        local ocStats = RS.OutcomeSuccessStats(recipe, uid)
        if type(ocStats) == "table" then
            attempts = tonumber(ocStats.brewAttempts) or attempts
            successes = tonumber(ocStats.brewSuccesses) or successes
            successRate = ocStats.successRate
        end
    elseif attempts > 0 then
        successRate = successes / attempts
    end
    local recipeYield = tonumber(recipe.recipeYield) or 0
    if RS and RS.RecipeFingerprintStats then
        local stats = RS.RecipeFingerprintStats(recipe, uid)
        if type(stats) == "table" and tonumber(stats.yield) and tonumber(stats.yield) > 0 then
            recipeYield = tonumber(stats.yield)
        end
    end
    local effectKey = nil
    if type(potionBase) == "table" and type(potionBase.effectKey) == "string" and potionBase.effectKey ~= "" then
        effectKey = potionBase.effectKey
    end
    if (type(effectKey) ~= "string" or effectKey == "") and RS and RS.ResolveEffectKeyForPotion
        and type(potionBase) == "table"
    then
        effectKey = RS.ResolveEffectKeyForPotion(potionBase, {
            recipe = recipe,
            stamp = false,
            allowClassify = true,
        })
    end
    if type(effectKey) == "string" and effectKey ~= "" and RS and RS.NormalizeEffectKeyForUi then
        effectKey = RS.NormalizeEffectKeyForUi(effectKey) or effectKey
    end
    return {
        name = potionName,
        potionLevel = tonumber(potionLevel) or 0,
        potionUid = uid,
        recipeSpecKey = recipe.recipeSpecKey,
        recipe = recipe,
        recipeYield = recipeYield,
        brewAttempts = attempts,
        brewSuccesses = successes,
        successRate = successRate,
        effectKey = effectKey,
        materials = recipe.slots or {},
    }
end

local function MatchesNameFilter(name, filter)
    if filter == nil or filter == "" then
        return true
    end
    return string.find(string.lower(ToNarrow(name)), string.lower(filter), 1, true) ~= nil
end

local function MatchesEffectFilter(effectKey, filter)
    if filter == nil or filter == "" then
        return true
    end
    return effectKey == filter
end

local function PassesFilters(row, nameFilter, effectFilter)
    -- Legacy defense: SkillUp Apo no longer learns potions; hide any leftover
    -- skillUpOrigin rows unless the player watched them.
    if row.skillUpOrigin == true and row.watched ~= true then
        return false
    end
    if not MatchesNameFilter(row.name, nameFilter)
        and not MatchesNameFilter(row.baseName, nameFilter)
        and not MatchesNameFilter(row.recipeLabel, nameFilter)
    then
        return false
    end
    return MatchesEffectFilter(row.effectKey, effectFilter)
end

local function CompareName(a, b)
    local na = string.lower(ToNarrow(a.baseName or a.name))
    local nb = string.lower(ToNarrow(b.baseName or b.name))
    if na == nb then
        return ToNarrow(a.id) < ToNarrow(b.id)
    end
    return na < nb
end

local function CompareRows(a, b, column, ascending)
    local function finish(lt)
        if lt then
            return ascending
        end
        return not ascending
    end
    if column == "name" then
        local na = string.lower(ToNarrow(a.name))
        local nb = string.lower(ToNarrow(b.name))
        if na == nb then
            return CompareName(a, b)
        end
        return finish(na < nb)
    elseif column == "level" then
        local la = a.levelNum or a.rankNum or 0
        local lb = b.levelNum or b.rankNum or 0
        if la == lb then
            return CompareName(a, b)
        end
        return finish(la < lb)
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
    elseif column == "duration" then
        if (a.durationNum or 0) == (b.durationNum or 0) then
            return CompareName(a, b)
        end
        return finish((a.durationNum or 0) < (b.durationNum or 0))
    elseif column == "multiplier" then
        if (a.multiplierNum or 0) == (b.multiplierNum or 0) then
            return CompareName(a, b)
        end
        return finish((a.multiplierNum or 0) < (b.multiplierNum or 0))
    elseif column == "superCrit" then
        if (a.superCritNum or 0) == (b.superCritNum or 0) then
            return CompareName(a, b)
        end
        return finish((a.superCritNum or 0) < (b.superCritNum or 0))
    elseif column == "yield" then
        if (a.yieldNum or 0) == (b.yieldNum or 0) then
            return CompareName(a, b)
        end
        return finish((a.yieldNum or 0) < (b.yieldNum or 0))
    elseif column == "have" then
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
    local column = s.potionSortColumn or "name"
    local ascending = s.potionSortAscending ~= false
    table.sort(rows, function(a, b)
        return CompareRows(a, b, column, ascending)
    end)
end

local function EffectCycle()
    return StockPiler.ViewList.EffectFilterCycle("potion")
end

local function SyncEffectComboSelection()
    StockPiler.ViewList.SyncEffectCombo(
        "SPTabPotionsEffectCombo",
        (GetSettings().potionEffectFilter) or "",
        nil,
        "potion"
    )
end

local function InitEffectCombo()
    local s = GetSettings()
    local current = tostring(s.potionEffectFilter or "")
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
            s.potionEffectFilter = ""
            current = ""
        end
    end
    StockPiler.ViewList.InitEffectCombo(
        "SPTabPotionsEffectCombo",
        current,
        EffectTextForRow,
        "potion"
    )
end

local function FiltersAreSet(s)
    if type(s) ~= "table" then
        return false
    end
    if tostring(s.potionNameFilter or "") ~= "" then
        return true
    end
    return tostring(s.potionEffectFilter or "") ~= ""
end

local function PaintClearButton()
    StockPiler.ViewList.PaintClearButton("SPTabPotionsClearFilters", FiltersAreSet(GetSettings()))
end

local function UpdateSortHeaderLabels()
    local labels = {
        name = T("potions.sort.name"),
        level = T("potions.sort.level"),
        effect = T("potions.sort.effect"),
        power = T("potions.sort.power"),
        stability = T("potions.sort.stability"),
        duration = T("potions.sort.duration"),
        multiplier = T("potions.sort.multiplier"),
        superCrit = T("potions.sort.super_crit"),
        yield = T("potions.sort.yield"),
        have = T("potions.sort.have"),
    }
    for key, win in pairs(SORT_HEADERS) do
        if DoesWindowExist(win) and labels[key] then
            ButtonSetText(win, labels[key])
        end
    end
    if DoesWindowExist("SPTabPotionsSortRecipe") then
        ButtonSetText("SPTabPotionsSortRecipe", T("potions.sort.recipe"))
    end
    if DoesWindowExist("SPTabPotionsSortForget") then
        ButtonSetText("SPTabPotionsSortForget", T("potions.sort.forget"))
    end
end

local function UpdateSortHeaders()
    UpdateSortHeaderLabels()
    local s = GetSettings()
    StockPiler.ViewList.UpdateSortArrows(
        SORT_HEADERS,
        s.potionSortColumn or "name",
        s.potionSortAscending ~= false
    )
end

local function ResolvePotionItemData(uid)
    uid = tonumber(uid) or 0
    if uid <= 0 then
        return nil
    end
    if StockPiler.Inventory and StockPiler.Inventory.ResolvePotionItemData then
        return StockPiler.Inventory.ResolvePotionItemData(nil, uid, nil)
    end
    return nil
end

local function BuildVisibleList()
    local s = GetSettings()
    if type(s) ~= "table" then
        return
    end
    local nameFilter = s.potionNameFilter or ""
    local effectFilter = s.potionEffectFilter or ""
    local rows = {}

    if StockPiler.Inventory and StockPiler.Inventory.RefreshAllIfNeeded then
        StockPiler.Inventory.RefreshAllIfNeeded()
    end
    if StockPiler.Watch and StockPiler.Watch.ScrubPristineDisabledStubs then
        StockPiler.Watch.ScrubPristineDisabledStubs()
    end

    local Catalog = StockPiler.Catalog
    local RS = StockPiler.RecipeSpec
    local potions = Catalog and Catalog.ListPotionRecipeEntries and Catalog.ListPotionRecipeEntries() or {}

    for i = 1, #potions do
        local potion = potions[i]
        local potionKey = potion.potionRecipeKey or potion.potionKey
        local potionBase = potion.potion or potion
        local watch = Catalog and Catalog.GetWatch and Catalog.GetWatch(potionKey)
            or { enabled = false, targetStock = 40 }
        local watched = watch.enabled == true
        local have = Catalog and Catalog.PotionHaveCombined and Catalog.PotionHaveCombined(potionBase) or 0
        local uid = tonumber(potion.outputUid or potionBase.outputUid) or 0
        local itemData = ResolvePotionItemData(uid)
        local effectKey = nil
        if RS and RS.ResolveEffectKeyForPotion then
            effectKey = RS.ResolveEffectKeyForPotion(potionBase, {
                recipeKey = potion.recipeSpecKey,
                recipe = potion.recipe,
                itemData = itemData,
                stamp = true,
            })
        else
            effectKey = potion.effectKey or potionBase.effectKey
            if (not effectKey or effectKey == "") and itemData and StockPiler.Classify and StockPiler.Classify.GetEffectKey then
                effectKey = StockPiler.Classify.GetEffectKey(itemData)
            end
        end
        local baseName = potion.name or potionBase.name or towstring(tostring(uid))
        local skillUpOrigin = potion.skillUpOrigin == true
            or (type(potionBase) == "table" and potionBase.skillUpOrigin == true)
            or (type(potion.recipe) == "table" and potion.recipe.skillUpOrigin == true)
        local displayName = baseName
        if skillUpOrigin == true then
            displayName = baseName .. T("potions.tag.skillup")
        end
        local powerNum = tonumber(potion.power) or 0
        local stabilityNum = tonumber(potion.stability) or 0
        local multiplierNum = tonumber(potion.multiplier) or 0
        local superCritNum = tonumber(potion.superCrit) or 0
        local yieldNum = tonumber(potion.yield) or 0
        local row = {
            id = potionKey,
            potionKey = potionKey,
            potionBaseKey = potion.potionKey or potionBase.potionKey,
            recipeSpecKey = potion.recipeSpecKey,
            recipeLabel = potion.recipeLabel or L"",
            name = displayName,
            baseName = baseName,
            skillUpOrigin = skillUpOrigin,
            effectKey = effectKey,
            effectText = EffectTextForRow(effectKey),
            powerNum = powerNum,
            powerText = FormatSignedStat(powerNum),
            stabilityNum = stabilityNum,
            stabilityText = FormatSignedStat(stabilityNum),
            durationNum = 0,
            durationText = FormatSignedStat(0),
            multiplierNum = multiplierNum,
            multiplierText = FormatSignedStat(multiplierNum),
            superCritNum = superCritNum,
            superCritText = FormatPercentStat(superCritNum),
            yieldNum = yieldNum,
            yieldText = FormatYieldStat(yieldNum),
            have = have,
            haveText = towstring(tostring(have)),
            watched = watched,
            watchBlocked = (StockPiler.Watch and StockPiler.Watch.CanEnablePotionWatch
                and StockPiler.Watch.CanEnablePotionWatch(potionKey) ~= true) == true,
            iconNum = tonumber(potion.iconNum or potionBase.iconNum) or 0,
            itemData = itemData,
            uniqueID = uid,
        }
        ApplyPotionStats(row, itemData)
        -- Learned Account.items tier when bag/DB shell still lacks iLevel/skillReq.
        if (tonumber(row.levelNum) or 0) <= 0 and uid > 0 then
            local learned = StockPiler.Items and StockPiler.Items.GetByUid and StockPiler.Items.GetByUid(uid)
            if type(learned) == "table" then
                local lvl = tonumber(learned.iLevel) or tonumber(learned.skillReq) or tonumber(learned.skillLevel) or 0
                if lvl <= 0 and type(learned.bonuses) == "table" then
                    lvl = tonumber(learned.bonuses[9]) or 0
                end
                if lvl > 0 then
                    row.rankNum = lvl
                    row.levelNum = lvl
                    row.levelText = towstring(tostring(lvl))
                end
            end
        end
        if (tonumber(row.levelNum) or 0) <= 0 and type(potionBase) == "table" then
            local lvl = tonumber(potionBase.iLevel) or tonumber(potionBase.level) or 0
            if lvl > 0 then
                row.rankNum = lvl
                row.levelNum = lvl
                row.levelText = towstring(tostring(lvl))
            end
        end
        row.nameR, row.nameG, row.nameB = ItemRarityNameColor(itemData)
        local recipe = potion.recipe
        if not recipe and RS and RS.GetRecipe and potion.recipeSpecKey then
            recipe = RS.GetRecipe(potion.recipeSpecKey)
        end
        if recipe and RS and RS.RecipeFingerprintStats then
            local stats = RS.RecipeFingerprintStats(recipe, uid)
            row.powerNum = stats.power
            row.powerText = FormatSignedStat(stats.power)
            row.stabilityNum = stats.stability
            row.stabilityText = FormatSignedStat(stats.stability)
            row.durationNum = stats.duration
            row.durationText = FormatSignedStat(stats.duration)
            row.multiplierNum = stats.multiplier
            row.multiplierText = FormatSignedStat(stats.multiplier)
            row.superCritNum = stats.superCrit
            row.superCritText = FormatPercentStat(stats.superCrit)
            row.yieldNum = stats.yield
            row.yieldText = FormatYieldStat(stats.yield)
        end
        row.recipeData = BuildRecipeDataForPotion(
            baseName,
            recipe,
            row.levelNum or row.rankNum,
            uid,
            potionBase
        )
        row.hasRecipe = row.recipeData ~= nil
        if PassesFilters(row, nameFilter, effectFilter) then
            rows[#rows + 1] = row
        end
    end

    SortRows(rows)
    local order = {}
    local structureKey = tostring(#rows)
    for i = 1, #rows do
        order[i] = i
        local row = rows[i]
        local id = type(row) == "table" and (row.potionKey or row.id or row.uniqueID) or ""
        structureKey = structureKey .. "|" .. tostring(id)
    end
    StockPilerTabPotions.listData = rows
    StockPilerTabPotions.displayOrder = order
    StockPilerTabPotions._listStructureKey = structureKey
end

local function SetIconTexture(iconWin, iconNum)
    StockPiler.ViewList.SetIconTexture(iconWin, iconNum, ICON_SCALE)
end

local function RowDataFromActiveChild()
    local win = SystemData.ActiveWindow and SystemData.ActiveWindow.name
    for _ = 1, 6 do
        if win == nil or win == "" then
            break
        end
        local rowIndex = WindowGetId(win)
        if rowIndex and rowIndex > 0 and DoesWindowExist("SPTabPotionsList") then
            local dataIndex = ListBoxGetDataIndex("SPTabPotionsList", rowIndex)
            local listData = StockPilerTabPotions.listData
            if type(listData) == "table" and dataIndex ~= nil and listData[dataIndex] then
                return listData[dataIndex]
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

local function AfterWatchToggle(opts)
    opts = type(opts) == "table" and opts or {}
    if StockPilerTabWatch and StockPilerTabWatch.AfterCatalogWatchToggle then
        StockPilerTabWatch.AfterCatalogWatchToggle(opts)
        return
    end
    -- Fallback if Watch tab module missing.
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
    if StockPilerWindow and StockPilerWindow.SyncActionReadiness then
        StockPilerWindow.SyncActionReadiness()
    end
end

function StockPilerTabPotions.Initialize()
    LabelSetText("SPTabPotionsBannerTitle", T("potions.banner_title"))
    LabelSetText("SPTabPotionsBannerText", T("potions.banner_text"))
    LabelSetText("SPTabPotionsSearchLabel", T("potions.search"))
    LabelSetText("SPTabPotionsEffectLabel", T("potions.effect"))
    if DoesWindowExist("SPTabPotionsClearFilters") then
        ButtonSetText("SPTabPotionsClearFilters", T("filters.clear"))
    end
    UpdateSortHeaderLabels()

    local s = GetSettings()
    if DoesWindowExist("SPTabPotionsSearchBox") then
        TextEditBoxSetText("SPTabPotionsSearchBox", towstring(s.potionNameFilter or ""))
    end
    InitEffectCombo()
    UpdateSortHeaders()
end

function StockPilerTabPotions.Refresh()
    if not DoesWindowExist(TAB_ROOT) then
        return
    end
    PaintClearButton()
    local effectSig = StockPiler.ViewList.EffectFilterSignature("potion")
    if effectSig ~= StockPilerTabPotions._effectSig then
        StockPilerTabPotions._effectSig = effectSig
        InitEffectCombo()
    else
        SyncEffectComboSelection()
    end
    UpdateSortHeaders()
    local prevKey = StockPilerTabPotions._listStructureKey
    BuildVisibleList()
    local keyChanged = prevKey ~= StockPilerTabPotions._listStructureKey
    if DoesWindowExist("SPTabPotionsList") then
        -- Empty→full ListBoxSetDisplayOrder resets scroll; skip when row ids unchanged.
        if keyChanged or prevKey == nil then
            ListBoxSetDisplayOrder("SPTabPotionsList", {})
            ListBoxSetDisplayOrder("SPTabPotionsList", StockPilerTabPotions.displayOrder)
        end
        StockPilerTabPotions.UpdateRows()
    end
end

--- Bag-snap live Have (CountByUid) without ListBox rebuild — Watch catchup parity.
function StockPilerTabPotions.PatchLiveHave()
    local list = StockPilerTabPotions.listData
    if type(list) ~= "table" or #list == 0 then
        return false
    end
    local Catalog = StockPiler.Catalog
    local Inv = StockPiler.Inventory
    local dirty = false
    for i = 1, #list do
        local row = list[i]
        if type(row) == "table" then
            local have = 0
            local uid = tonumber(row.uniqueID) or 0
            if Catalog and Catalog.PotionHaveCombined then
                have = tonumber(Catalog.PotionHaveCombined({ outputUid = uid })) or 0
            elseif uid > 0 and Inv and Inv.CountByUid then
                have = tonumber(Inv.CountByUid(uid)) or 0
            end
            if (tonumber(row.have) or 0) ~= have then
                row.have = have
                row.haveText = towstring(tostring(have))
                dirty = true
            end
        end
    end
    return dirty
end

function StockPilerTabPotions.UpdateRows()
    if not SPTabPotionsList then
        return
    end
    local numVisible = tonumber(SPTabPotionsList.numVisibleRows) or 12
    local indices = SPTabPotionsList.PopulatorIndices
    local active = {}
    if type(indices) == "table" then
        for rowIndex, dataIndex in ipairs(indices) do
            active[rowIndex] = dataIndex
        end
    end
    local listData = StockPilerTabPotions.listData
    for rowIndex = 1, numVisible do
        local rowName = "SPTabPotionsListRow" .. rowIndex
        if DoesWindowExist(rowName) then
            local dataIndex = active[rowIndex]
            local data = dataIndex and type(listData) == "table" and listData[dataIndex] or nil
            if data then
                WindowSetShowing(rowName, true)
                StockPiler.ViewList.ApplyRowStripe(rowName .. "Background", rowIndex)
                local blocked = data.watchBlocked == true
                if StockPiler.Watch and StockPiler.Watch.CanEnablePotionWatch then
                    blocked = StockPiler.Watch.CanEnablePotionWatch(data.potionKey or data.id) ~= true
                    data.watchBlocked = blocked
                end
                StockPiler.ViewList.PaintWatchCheckbox(rowName .. "Watch", data.watched == true, blocked)
                SetIconTexture(rowName .. "Icon", data.iconNum)
                LabelSetText(rowName .. "Name", data.name or L"")
                LabelSetTextColor(
                    rowName .. "Name",
                    tonumber(data.nameR) or 255,
                    tonumber(data.nameG) or 255,
                    tonumber(data.nameB) or 255
                )
                LabelSetText(rowName .. "Level", data.levelText or T("ui.dash"))
                LabelSetText(rowName .. "Effect", data.effectText or L"")
                LabelSetText(rowName .. "Power", data.powerText or L"0")
                LabelSetText(rowName .. "Stability", data.stabilityText or L"0")
                LabelSetText(rowName .. "Duration", data.durationText or L"0")
                LabelSetText(rowName .. "Multiplier", data.multiplierText or L"0")
                LabelSetText(rowName .. "SuperCrit", data.superCritText or T("ui.dash"))
                LabelSetText(rowName .. "Yield", data.yieldText or T("ui.dash"))
                LabelSetText(rowName .. "Have", data.haveText or towstring(tostring(data.have or 0)))
                LabelSetTextColor(rowName .. "Have", 255, 255, 255)
                if DoesWindowExist(rowName .. "Recipe") then
                    WindowSetShowing(rowName .. "Recipe", data.hasRecipe == true)
                end
                if DoesWindowExist(rowName .. "Forget") then
                    WindowSetShowing(rowName .. "Forget", data.hasRecipe == true)
                end
            else
                WindowSetShowing(rowName, false)
            end
        end
    end
end

function StockPilerTabPotions.OnSearchChanged()
    local text = TextEditBoxGetText("SPTabPotionsSearchBox")
    GetSettings().potionNameFilter = ToNarrow(text)
    StockPilerTabPotions.Refresh()
end

function StockPilerTabPotions.OnEffectComboChanged()
    local idx = tonumber(ComboBoxGetSelectedMenuItem("SPTabPotionsEffectCombo")) or 1
    local cycle = EffectCycle()
    local newFilter = cycle[idx] or ""
    local s = GetSettings()
    if s.potionEffectFilter == newFilter then
        return
    end
    s.potionEffectFilter = newFilter
    StockPilerTabPotions.Refresh()
end

function StockPilerTabPotions.OnClearFilters()
    local s = GetSettings()
    s.potionNameFilter = ""
    s.potionEffectFilter = ""
    if DoesWindowExist("SPTabPotionsSearchBox") then
        TextEditBoxSetText("SPTabPotionsSearchBox", L"")
    end
    InitEffectCombo()
    StockPilerTabPotions.Refresh()
end

function StockPilerTabPotions.OnMouseOverClearFilters()
    StockPiler.ViewList.Tip(T("tip.filters.clear"))
end

function StockPilerTabPotions.OnSortColumn()
    local id = WindowGetId(SystemData.ActiveWindow.name)
    local col = SORT_IDS[id]
    if not col then
        return
    end
    local s = GetSettings()
    if s.potionSortColumn == col then
        s.potionSortAscending = not (s.potionSortAscending ~= false)
    else
        s.potionSortColumn = col
        s.potionSortAscending = true
    end
    StockPilerTabPotions.Refresh()
end

function StockPilerTabPotions.OnToggleWatch()
    local data = RowDataFromActiveChild()
    if not data then
        return
    end
    -- Prefer composite recipe key so sibling recipes for the same output uid
    -- do not share one Watch.SetEnabled / GetWatch alias.
    local potionKey = data.potionRecipeKey or data.potionKey or data.id
    local win = SystemData.ActiveWindow.name
    local enabled = ButtonGetPressedFlag(win) == true
    if enabled then
        local blocked = data.watchBlocked == true
        if StockPiler.Watch and StockPiler.Watch.CanEnablePotionWatch then
            blocked = StockPiler.Watch.CanEnablePotionWatch(potionKey) ~= true
            data.watchBlocked = blocked
        end
        if blocked then
            if DoesWindowExist(win) then
                ButtonSetPressedFlag(win, false)
                if ButtonSetDisabledFlag then
                    ButtonSetDisabledFlag(win, true)
                end
            end
            -- Notify via the shared gate (does not enable).
            if StockPiler.Watch and StockPiler.Watch.SetEnabled then
                StockPiler.Watch.SetEnabled(potionKey, true, { fromPotionsToggle = true })
            end
            return
        end
    end
    local ok = true
    if StockPiler.Watch and StockPiler.Watch.SetEnabled then
        local _, setOk = StockPiler.Watch.SetEnabled(potionKey, enabled, { fromPotionsToggle = true })
        ok = setOk ~= false
        if enabled and ok ~= true then
            enabled = false
            if DoesWindowExist(win) then
                ButtonSetPressedFlag(win, false)
                if ButtonSetDisabledFlag then
                    ButtonSetDisabledFlag(win, true)
                end
            end
            data.watchBlocked = true
        end
    else
        local watch = StockPiler.Catalog and StockPiler.Catalog.EnsureWatch and StockPiler.Catalog.EnsureWatch(potionKey)
        if type(watch) == "table" then
            watch.enabled = enabled
            if enabled then
                watch.autoGrow = true
            end
        end
        if StockPiler.Watch and StockPiler.Watch.BumpGen then
            StockPiler.Watch.BumpGen()
        end
    end
    data.watched = enabled
    AfterWatchToggle({
        enabled = enabled,
        potionKey = potionKey,
        kind = "potion",
    })
    if StockPilerTabPotions.UpdateRows then
        StockPilerTabPotions.UpdateRows()
    end
end

function StockPilerTabPotions.OnMouseOverIcon()
    StockPiler.ViewList.OnRowChildMouseOver()
    local data = RowDataFromActiveChild()
    if not data then
        return
    end
    local itemData = data.itemData
    if StockPiler.Inventory and StockPiler.Inventory.ShowItemTooltip
        and StockPiler.Inventory.ShowItemTooltip(itemData, SystemData.ActiveWindow.name)
    then
        return
    end
    Tooltips.CreateTextOnlyTooltip(SystemData.ActiveWindow.name, data.name or T("ui.potion_fallback"))
    Tooltips.AnchorTooltip(Tooltips.ANCHOR_WINDOW_RIGHT)
end

function StockPilerTabPotions.OnMouseOverRecipe()
    StockPiler.ViewList.OnRowChildMouseOver()
    local data = RowDataFromActiveChild()
    if not data or not data.recipeData then
        return
    end
    if StockPiler.RecipeTooltip and StockPiler.RecipeTooltip.Show then
        StockPiler.RecipeTooltip.Show(SystemData.ActiveWindow.name, data.recipeData)
    end
end

function StockPilerTabPotions.ConfirmForgetRecipe(outputUid, recipeSpecKey, potionKey, label)
    label = label or recipeSpecKey
    local forgot = false
    if StockPiler.Catalog and StockPiler.Catalog.ForgetPotionRecipeLink then
        forgot = StockPiler.Catalog.ForgetPotionRecipeLink(outputUid, recipeSpecKey) == true
    end
    if forgot then
        if potionKey == nil or potionKey == "" then
            local RS = StockPiler.RecipeSpec
            if RS and RS.PotionRecipeKey and tonumber(outputUid) and recipeSpecKey then
                potionKey = RS.PotionRecipeKey(outputUid, recipeSpecKey)
            end
        end
        if StockPiler.Ui and StockPiler.Ui.Print then
            StockPiler.Ui.Print(T("ui.forgot_recipe", { name = label }))
        end
        AfterWatchToggle({
            enabled = false,
            potionKey = potionKey,
            kind = "potion",
        })
        StockPilerTabPotions.Refresh()
    end
end

function StockPilerTabPotions.OnForgetRow()
    local data = RowDataFromActiveChild()
    if not data or not data.hasRecipe then
        return
    end
    local outputUid = tonumber(data.uniqueID) or 0
    local recipeSpecKey = data.recipeSpecKey
    local potionKey = data.potionRecipeKey or data.potionKey
    local label = data.name or T("ui.potion_fallback")
    StockPiler.ViewList.ConfirmTwoButton(
        T("potions.forget_confirm", { name = label }),
        function()
            StockPilerTabPotions.ConfirmForgetRecipe(outputUid, recipeSpecKey, potionKey, label)
        end
    )
end

function StockPilerTabPotions.OnMouseOverForget()
    StockPiler.ViewList.OnRowChildMouseOver()
    StockPiler.ViewList.ShowTextTip(SystemData.ActiveWindow.name, T("potions.forget_tip"))
end

--- Shift+left-click row / icon / name inserts the chat link. An ordinary click does not.
function StockPilerTabPotions.OnLinkClick(flags)
    local data = RowDataFromActiveChild()
    if StockPiler.RecipeLink and StockPiler.RecipeLink.ShareRowIfShift then
        StockPiler.RecipeLink.ShareRowIfShift(data, flags)
    end
end

--- Right-click row / icon / name: Link in chat (recipe share).
function StockPilerTabPotions.OnRowRightClick()
    local data = RowDataFromActiveChild()
    if not data then
        return
    end
    if StockPiler.RecipeLink and StockPiler.RecipeLink.ShowContextMenuForRow then
        StockPiler.RecipeLink.ShowContextMenuForRow(data)
    end
end
