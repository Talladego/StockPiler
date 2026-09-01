----------------------------------------------------------------
-- StockPilerTabPotions - potion stock targets (watch / min / filters)
----------------------------------------------------------------

StockPilerTabPotions = {}
StockPilerTabPotions.listData = {}
StockPilerTabPotions.displayOrder = {}

local ICON_SCALE = 0.34

local SORT_IDS = {
    [1] = "name",
    [2] = "effect",
    [3] = "power",
    [4] = "stability",
    [5] = "superCrit",
    [6] = "yield",
    [7] = "have",
    [8] = "watch",
}

local SORT_HEADERS = {
    watch = "SPTabPotionsSortWatch",
    name = "SPTabPotionsSortName",
    effect = "SPTabPotionsSortEffect",
    power = "SPTabPotionsSortPower",
    stability = "SPTabPotionsSortStability",
    superCrit = "SPTabPotionsSortSuperCrit",
    yield = "SPTabPotionsSortYield",
    have = "SPTabPotionsSortHave",
}

local SORT_HEADER_LABELS = {
    name = L"Name",
    effect = L"Effect",
    power = L"Power",
    stability = L"Stability",
    superCrit = L"Super-Crit",
    yield = L"Yield",
    have = L"Stock",
}

local EFFECT_CYCLE = { "", "str", "int", "wp", "bs", "tou", "armor", "absorb", "heal", "hot", "ap" }

local EFFECT_LABELS = {
    str = L"Str",
    int = L"Int",
    wp = L"WP",
    bs = L"BS",
    tou = L"Tou",
    armor = L"Armor",
    absorb = L"Absorb",
    heal = L"Heal",
    hot = L"HoT",
    ap = L"AP",
}

local function ToNarrow(text)
    return StockPiler.ToNarrow(text)
end

local function GetSettings()
    if StockPiler.EnsureSettings then
        return StockPiler.EnsureSettings()
    end
    return StockPiler.Settings
end

local function ResolveEffectKey(entry, itemData)
    if entry and entry.effectKey then
        return entry.effectKey
    end
    if itemData and StockPiler.Classify and StockPiler.Classify.GetEffectKey then
        return StockPiler.Classify.GetEffectKey(itemData)
    end
    return nil
end

local function EffectTextForRow(effectKey, _catalogEffect)
    if effectKey and EFFECT_LABELS[effectKey] then
        return EFFECT_LABELS[effectKey]
    end
    return L""
end

local function ResolveTooltipItemData(entry, itemData)
    if StockPiler.Inventory and StockPiler.Inventory.ResolveTooltipItemData then
        return StockPiler.Inventory.ResolveTooltipItemData(entry, itemData) or itemData
    end
    return itemData
end

local function ApplyPotionStats(row, entry, itemData)
    local rankText = L"-"
    local buffText = L"-"
    local durationText = L"-"
    row.rankNum = 0
    row.buffNum = 0
    row.durationSec = 0

    if StockPiler.Classify and StockPiler.Classify.GetPotionStats then
        local minRank, buffValue, durationSec, instant = StockPiler.Classify.GetPotionStats(itemData, entry)
        row.rankNum = tonumber(minRank) or 0
        row.buffNum = tonumber(buffValue) or 0
        row.durationSec = tonumber(durationSec) or 0
        if minRank and minRank > 0 then
            rankText = towstring(tostring(minRank))
        end
        if buffValue and buffValue > 0 then
            buffText = towstring(tostring(buffValue))
        end
        if instant then
            durationText = L"Inst"
        elseif durationSec and durationSec > 0 and StockPiler.Classify.FormatDuration then
            durationText = StockPiler.Classify.FormatDuration(durationSec)
            if durationText == L"" then
                durationText = L"-"
            end
        end
    end

    row.rankText = rankText
    row.buffText = buffText
    row.durationText = durationText
end

local function BuildRecipeDataForPotion(potionKey, potionName, recipe, potionLevel, potionUid)
    if type(recipe) ~= "table" then
        return nil
    end
    local uid = tonumber(potionUid) or tonumber(recipe.outputUid) or tonumber(recipe.activeOutcomeUid) or 0
    local RS = StockPiler.RecipeSpec
    local attempts = tonumber(recipe.brewAttempts) or 0
    local successes = tonumber(recipe.brewSuccesses) or 0
    local successRate = nil
    local yieldSamples = tonumber(recipe.yieldSamples) or 0
    local yieldProductSum = tonumber(recipe.yieldProductSum) or 0
    if RS and RS.OutcomeSuccessRate then
        local rate, ok, att = RS.OutcomeSuccessRate(recipe, uid)
        successRate = rate
        if att and att > 0 then
            attempts = att
        end
        if ok ~= nil then
            successes = ok
        end
    elseif RS and RS.RecipeSuccessRate then
        successRate = RS.RecipeSuccessRate(recipe)
    end
    local oc = RS and RS.OutcomeForPotion and RS.OutcomeForPotion(recipe, uid) or nil
    if type(oc) == "table" then
        local ocOk = tonumber(oc.successes) or 0
        local ocQty = tonumber(oc.qtySum) or 0
        if ocOk > 0 then
            yieldSamples = ocOk
            yieldProductSum = ocQty
        end
    end
    local recipeYield = 0
    if RS and RS.RecipeOutputYield then
        recipeYield = RS.RecipeOutputYield(recipe, uid) or 0
    else
        recipeYield = tonumber(recipe.recipeYield) or 0
    end
    return {
        name = potionName,
        potionLevel = tonumber(potionLevel) or 0,
        potionUid = uid,
        recipeSpecKey = recipe.recipeSpecKey,
        recipeYield = recipeYield,
        crafts = tonumber(recipe.crafts) or 0,
        brewAttempts = attempts,
        brewSuccesses = successes,
        brewCrits = tonumber(recipe.brewCrits) or 0,
        brewSuperCrits = tonumber(recipe.brewSuperCrits) or 0,
        brewFailures = tonumber(recipe.brewFailures) or 0,
        brewVolatiles = tonumber(recipe.brewVolatiles) or 0,
        yieldProductSum = yieldProductSum,
        yieldSamples = yieldSamples,
        successRate = successRate,
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

local function ResolvePotionItemData(potionKey, uid, existing)
    if StockPiler.Inventory and StockPiler.Inventory.ResolvePotionItemData then
        return StockPiler.Inventory.ResolvePotionItemData(potionKey, uid, existing)
    end
    return existing
end

local function PassesFilters(row, nameFilter, effectFilter)
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
        local la = string.lower(ToNarrow(a.recipeLabel))
        local lb = string.lower(ToNarrow(b.recipeLabel))
        if la ~= lb then
            return la < lb
        end
        return ToNarrow(a.id) < ToNarrow(b.id)
    end
    return na < nb
end

local function FormatSignedStat(value)
    value = tonumber(value) or 0
    if value > 0 then
        return towstring("+" .. tostring(value))
    end
    return towstring(tostring(value))
end

local function FormatPercentStat(value)
    value = tonumber(value) or 0
    if value == 0 then
        return L"-"
    end
    return towstring(tostring(value) .. "%")
end

local function FormatYieldStat(value)
    value = tonumber(value) or 0
    if value <= 0 then
        return L"-"
    end
    local rounded = math.floor(value + 0.5)
    if math.abs(value - rounded) < 0.05 then
        return towstring(tostring(rounded))
    end
    return towstring(string.format("%.1f", value))
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
    elseif column == "effect" then
        local ea = ToNarrow(a.effectText)
        local eb = ToNarrow(b.effectText)
        if ea == eb then
            return CompareName(a, b)
        end
        return finish(ea < eb)
    elseif column == "power" then
        local pa = a.powerNum or 0
        local pb = b.powerNum or 0
        if pa == pb then
            return CompareName(a, b)
        end
        return finish(pa < pb)
    elseif column == "stability" then
        local sa = a.stabilityNum or 0
        local sb = b.stabilityNum or 0
        if sa == sb then
            return CompareName(a, b)
        end
        return finish(sa < sb)
    elseif column == "superCrit" then
        local ca = a.superCritNum or 0
        local cb = b.superCritNum or 0
        if ca == cb then
            return CompareName(a, b)
        end
        return finish(ca < cb)
    elseif column == "yield" then
        local ya = a.yieldNum or 0
        local yb = b.yieldNum or 0
        if ya == yb then
            return CompareName(a, b)
        end
        return finish(ya < yb)
    elseif column == "have" then
        local ha = a.have or 0
        local hb = b.have or 0
        if ha == hb then
            return CompareName(a, b)
        end
        return finish(ha < hb)
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

local function SyncEffectComboSelection()
    local w = "SPTabPotionsEffectCombo"
    if not DoesWindowExist(w) then
        return
    end
    local cur = (GetSettings().potionEffectFilter) or ""
    local selected = 1
    for i = 1, #EFFECT_CYCLE do
        if EFFECT_CYCLE[i] == cur then
            selected = i
            break
        end
    end
    ComboBoxSetSelectedMenuItem(w, selected)
end

local function InitEffectCombo()
    local w = "SPTabPotionsEffectCombo"
    if not DoesWindowExist(w) then
        return
    end
    ComboBoxClearMenuItems(w)
    ComboBoxAddMenuItem(w, L"All effects")
    for i = 2, #EFFECT_CYCLE do
        local key = EFFECT_CYCLE[i]
        ComboBoxAddMenuItem(w, EFFECT_LABELS[key])
    end
    SyncEffectComboSelection()
end

local function UpdateSortHeaderLabels()
    for key, win in pairs(SORT_HEADERS) do
        if DoesWindowExist(win) and SORT_HEADER_LABELS[key] then
            ButtonSetText(win, SORT_HEADER_LABELS[key])
        end
    end
    if DoesWindowExist("SPTabPotionsSortRecipe") then
        ButtonSetText("SPTabPotionsSortRecipe", L"Recipe")
    end
    if DoesWindowExist("SPTabPotionsSortForget") then
        ButtonSetText("SPTabPotionsSortForget", L"Forget")
    end
end

local function UpdateSortHeaders()
    UpdateSortHeaderLabels()
    local s = GetSettings()
    local col = s.potionSortColumn or "name"
    local asc = s.potionSortAscending ~= false
    for key, win in pairs(SORT_HEADERS) do
        if DoesWindowExist(win) then
            local up = win .. "UpArrow"
            local down = win .. "DownArrow"
            if key == col then
                WindowSetShowing(up, asc)
                WindowSetShowing(down, not asc)
            else
                WindowSetShowing(up, false)
                WindowSetShowing(down, false)
            end
        end
    end
end

local function UpdateKnownRecipeFilterCheckbox()
    local s = GetSettings()
    if DoesWindowExist("SPTabPotionsFilterKnownRecipe") then
        ButtonSetCheckButtonFlag("SPTabPotionsFilterKnownRecipe", true)
        ButtonSetPressedFlag("SPTabPotionsFilterKnownRecipe", s.potionKnownRecipeOnly == true)
    end
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

    local RS = StockPiler.RecipeSpec
    if RS and RS.MigrateWatchesToPotionRecipeKeys then
        RS.MigrateWatchesToPotionRecipeKeys()
    end
    local potions = RS and RS.ListPotionRecipeEntries and RS.ListPotionRecipeEntries()
        or (RS and RS.GetKnownPotionList())
        or {}

    for i = 1, #potions do
        local potion = potions[i]
        local potionKey = potion.potionRecipeKey or potion.potionKey
        local potionBase = potion.potion or potion
        local watch = RS and RS.EnsureWatch(potionKey) or { enabled = false, targetStock = 40 }
        local watched = watch.enabled == true
        local have = RS and RS.PotionHaveCombined(potionBase) or 0
        local min = tonumber(watch.targetStock) or 0
        local uid = tonumber(potion.outputUid or potionBase.outputUid) or 0
        local entry = {
            id = potionKey,
            uniqueID = uid,
            uniqueIDs = { uid },
        }
        local itemData = ResolvePotionItemData(potion.potionKey or potionKey, uid, nil)
        local effectKey = potion.effectKey or potionBase.effectKey
        if not effectKey and itemData and StockPiler.Classify then
            effectKey = StockPiler.Classify.GetEffectKey(itemData)
        end
        local recipeLabel = potion.recipeLabel or L""
        local baseName = potion.name or potionBase.name or towstring(tostring(uid))
        local powerNum = tonumber(potion.power) or 0
        local stabilityNum = tonumber(potion.stability) or 0
        local superCritNum = tonumber(potion.superCrit) or 0
        local yieldNum = tonumber(potion.yield) or 0
        local row = {
            id = potionKey,
            potionKey = potionKey,
            potionBaseKey = potion.potionKey or potionBase.potionKey,
            recipeSpecKey = potion.recipeSpecKey,
            recipeLabel = recipeLabel,
            entry = entry,
            name = baseName,
            baseName = baseName,
            effectKey = effectKey,
            effectText = EffectTextForRow(effectKey, nil),
            powerNum = powerNum,
            powerText = FormatSignedStat(powerNum),
            stabilityNum = stabilityNum,
            stabilityText = FormatSignedStat(stabilityNum),
            superCritNum = superCritNum,
            superCritText = FormatPercentStat(superCritNum),
            yieldNum = yieldNum,
            yieldText = FormatYieldStat(yieldNum),
            have = have,
            haveText = towstring(tostring(have)),
            min = min,
            minText = towstring(tostring(min)),
            watched = watched,
            iconNum = tonumber(potion.iconNum or potionBase.iconNum) or 0,
            itemData = itemData,
            uniqueID = uid,
            observed = true,
        }
        ApplyPotionStats(row, entry, itemData)
        local recipe = nil
        if RS and RS.RecipeSpecForPotion then
            recipe = RS.RecipeSpecForPotion(potionKey)
        end
        row.recipeSpecKey = (recipe and recipe.recipeSpecKey) or potion.recipeSpecKey
        if recipe and RS.RecipeFingerprintStats then
            local stats = RS.RecipeFingerprintStats(recipe, uid)
            row.powerNum = stats.power
            row.powerText = FormatSignedStat(stats.power)
            row.stabilityNum = stats.stability
            row.stabilityText = FormatSignedStat(stats.stability)
            row.superCritNum = stats.superCrit
            row.superCritText = FormatPercentStat(stats.superCrit)
            row.yieldNum = stats.yield
            row.yieldText = FormatYieldStat(stats.yield)
        end
        row.recipeData = BuildRecipeDataForPotion(potionKey, baseName, recipe, row.rankNum, uid)
        row.hasRecipe = row.recipeData ~= nil
        if PassesFilters(row, nameFilter, effectFilter) then
            rows[#rows + 1] = row
        end
    end

    SortRows(rows)

    local order = {}
    for i = 1, #rows do
        order[i] = i
    end
    StockPilerTabPotions.listData = rows
    StockPilerTabPotions.displayOrder = order
end

local function UpdateKnownRecipeFilterCheckbox()
    local s = GetSettings()
    if DoesWindowExist("SPTabPotionsFilterKnownRecipe") then
        ButtonSetCheckButtonFlag("SPTabPotionsFilterKnownRecipe", true)
        ButtonSetPressedFlag("SPTabPotionsFilterKnownRecipe", s.potionKnownRecipeOnly == true)
    end
end

local function SetIconTexture(iconWin, iconNum)
    if not DoesWindowExist(iconWin) then
        return
    end
    if iconNum and iconNum > 0 and type(GetIconData) == "function" then
        local ok, texture, x, y = StockPiler.TryCallQuiet("GetIconData", GetIconData, iconNum)
        if ok and texture and texture ~= "" then
            DynamicImageSetTexture(iconWin, texture, x or 0, y or 0)
            if type(DynamicImageSetTextureScale) == "function" then
                DynamicImageSetTextureScale(iconWin, ICON_SCALE)
            end
            WindowSetShowing(iconWin, true)
            return
        end
    end
    DynamicImageSetTexture(iconWin, "", 0, 0)
    WindowSetShowing(iconWin, false)
end

function StockPilerTabPotions.Initialize()
    LabelSetText("SPTabPotionsBannerTitle", L"Known potions")
    LabelSetText(
        "SPTabPotionsBannerText",
        L"Recipes are learned by brewing manually. One row per recipe; columns are fingerprint stats (effect / rank / buff / duration in the icon tip)."
    )
    LabelSetText("SPTabPotionsSearchLabel", L"Search:")
    LabelSetText("SPTabPotionsEffectLabel", L"Effect:")
    UpdateSortHeaderLabels()

    local s = GetSettings()
    if DoesWindowExist("SPTabPotionsSearchBox") then
        TextEditBoxSetText("SPTabPotionsSearchBox", towstring(s.potionNameFilter or ""))
    end
    if DoesWindowExist("SPTabPotionsFilterKnownRecipe") then
        WindowSetShowing("SPTabPotionsFilterKnownRecipe", false)
    end
    if DoesWindowExist("SPTabPotionsFilterKnownRecipeLabel") then
        WindowSetShowing("SPTabPotionsFilterKnownRecipeLabel", false)
    end
    InitEffectCombo()
    UpdateSortHeaders()
end

function StockPilerTabPotions.Refresh()
    if not DoesWindowExist("SPTabPotions") then
        return
    end
    SyncEffectComboSelection()
    UpdateSortHeaders()
    BuildVisibleList()

    if DoesWindowExist("SPTabPotionsList") then
        ListBoxSetDisplayOrder("SPTabPotionsList", {})
        ListBoxSetDisplayOrder("SPTabPotionsList", StockPilerTabPotions.displayOrder)
        StockPilerTabPotions.UpdateRows()
    end
end

function StockPilerTabPotions.UpdateRows()
    if SPTabPotionsList.PopulatorIndices == nil then
        return
    end
    for rowIndex, dataIndex in ipairs(SPTabPotionsList.PopulatorIndices) do
        local data = StockPilerTabPotions.listData[dataIndex]
        if data then
            local rowName = "SPTabPotionsListRow" .. rowIndex
            DefaultColor.SetListRowTint(rowName .. "Background", rowIndex, false)
            ButtonSetCheckButtonFlag(rowName .. "Watch", true)
            ButtonSetPressedFlag(rowName .. "Watch", data.watched == true)
            SetIconTexture(rowName .. "Icon", data.iconNum)

            LabelSetText(rowName .. "Name", data.name or L"")
            LabelSetText(rowName .. "Effect", data.effectText or L"")
            LabelSetText(rowName .. "Power", data.powerText or L"0")
            LabelSetText(rowName .. "Stability", data.stabilityText or L"0")
            LabelSetText(rowName .. "SuperCrit", data.superCritText or L"-")
            LabelSetText(rowName .. "Yield", data.yieldText or L"-")
            LabelSetText(rowName .. "Have", data.haveText or towstring(tostring(data.have or 0)))

            local min = data.min or 0
            if min > 0 and data.have < min then
                LabelSetTextColor(rowName .. "Have", 220, 160, 60)
            else
                LabelSetTextColor(rowName .. "Have", 255, 255, 255)
            end

            local recipeWin = rowName .. "Recipe"
            if DoesWindowExist(recipeWin) then
                WindowSetShowing(recipeWin, data.hasRecipe == true)
            end

            local forgetWin = rowName .. "Forget"
            if DoesWindowExist(forgetWin) then
                WindowSetShowing(forgetWin, data.hasRecipe == true)
            end
        end
    end
end

function StockPilerTabPotions.OnToggleKnownRecipeFilter()
    local s = GetSettings()
    s.potionKnownRecipeOnly = ButtonGetPressedFlag(SystemData.ActiveWindow.name) == true
    StockPilerTabPotions.Refresh()
end

function StockPilerTabPotions.OnSearchChanged()
    local text = TextEditBoxGetText("SPTabPotionsSearchBox")
    GetSettings().potionNameFilter = ToNarrow(text)
    StockPilerTabPotions.Refresh()
end

function StockPilerTabPotions.OnEffectComboChanged()
    local idx = tonumber(ComboBoxGetSelectedMenuItem("SPTabPotionsEffectCombo")) or 1
    local newFilter = EFFECT_CYCLE[idx] or ""
    local s = GetSettings()
    if s.potionEffectFilter == newFilter then
        return
    end
    s.potionEffectFilter = newFilter
    StockPilerTabPotions.Refresh()
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

local function RowDataFromActiveChild()
    local rowWindow = WindowGetParent(SystemData.ActiveWindow.name)
    local rowIndex = WindowGetId(rowWindow)
    local dataIndex = ListBoxGetDataIndex("SPTabPotionsList", rowIndex)
    return StockPilerTabPotions.listData[dataIndex]
end

function StockPilerTabPotions.OnToggleWatch()
    local data = RowDataFromActiveChild()
    if not data then
        return
    end
    local s = GetSettings()
    local potionKey = data.potionKey or data.id
    if not (StockPiler.RecipeSpec and StockPiler.RecipeSpec.EnsureWatch) then
        return
    end
    local watch = StockPiler.RecipeSpec.EnsureWatch(potionKey)
    watch.enabled = ButtonGetPressedFlag(SystemData.ActiveWindow.name) == true
    if watch.autoGrow == nil then
        watch.autoGrow = true
    end
    if StockPiler.PersistActiveCharacterSettings then
        StockPiler.PersistActiveCharacterSettings(s)
    end
    if StockPiler.LogOp then
        StockPiler.LogOp("settings", string.format(
            "watch enabled=%s potion=%s key=%s target=%d autoGrow=%s",
            tostring(watch.enabled == true),
            StockPiler.ToNarrow(data.name or data.id or "?"),
            StockPiler.ShortLogKey and StockPiler.ShortLogKey(potionKey) or tostring(potionKey),
            tonumber(watch.targetStock) or 0,
            tostring(watch.autoGrow ~= false)
        ))
    end
    if StockPiler.AutoGrow and StockPiler.AutoGrow.OnDemandChanged then
        StockPiler.AutoGrow.OnDemandChanged()
    elseif StockPiler.AutoGrow and StockPiler.AutoGrow.InvalidatePlantQueue then
        StockPiler.AutoGrow.InvalidatePlantQueue()
    end
    StockPilerTabPotions.Refresh()
    if StockPilerTabAutoGrow and StockPilerTabAutoGrow.Refresh then
        StockPilerTabAutoGrow.Refresh()
    end
end

local function ShowItemOrTextTooltip(itemData, title, line2, line3)
    if StockPiler.Inventory and StockPiler.Inventory.ShowItemTooltip then
        if StockPiler.Inventory.ShowItemTooltip(itemData, SystemData.ActiveWindow.name) then
            return
        end
    elseif itemData ~= nil and type(Tooltips.CreateItemTooltip) == "function" then
        local ok = StockPiler.TryCall(
            "Tooltips.CreateItemTooltip", Tooltips.CreateItemTooltip,
            itemData,
            SystemData.ActiveWindow.name,
            Tooltips.ANCHOR_WINDOW_RIGHT,
            true
        )
        if ok then
            return
        end
    end
    Tooltips.CreateTextOnlyTooltip(SystemData.ActiveWindow.name)
    Tooltips.SetTooltipText(1, 1, title or L"Item")
    local row = 2
    if line2 and line2 ~= L"" then
        Tooltips.SetTooltipText(row, 1, line2)
        row = row + 1
    end
    if line3 and line3 ~= L"" then
        Tooltips.SetTooltipText(row, 1, line3)
    end
    Tooltips.Finalize()
    Tooltips.AnchorTooltip(Tooltips.ANCHOR_WINDOW_RIGHT)
end

function StockPilerTabPotions.OnMouseOverIcon()
    local data = RowDataFromActiveChild()
    if not data then
        return
    end
    local itemData = ResolvePotionItemData(data.potionKey, data.uniqueID, data.itemData)
    if itemData then
        data.itemData = itemData
    end
    -- Full stock tooltip only when bags/session have Use-bonus itemData.
    -- Otherwise name only — do not invent or cache full tooltip blobs.
    ShowItemOrTextTooltip(itemData, data.name or L"Potion", nil, nil)
end

function StockPilerTabPotions.OnMouseOverRecipe()
    local data = RowDataFromActiveChild()
    if not data or not data.recipeData then
        return
    end
    if StockPilerRecipeTooltip and StockPilerRecipeTooltip.ShowRecipeTooltip then
        StockPilerRecipeTooltip.ShowRecipeTooltip(SystemData.ActiveWindow.name, data.recipeData)
    end
end

function StockPilerTabPotions.ConfirmForgetRecipe()
    local key = StockPilerTabPotions._pendingForgetKey
    local label = StockPilerTabPotions._pendingForgetLabel or key
    StockPilerTabPotions._pendingForgetKey = nil
    StockPilerTabPotions._pendingForgetLabel = nil
    if not key or key == "" then
        return
    end
    if StockPiler.RecipeSpec and StockPiler.RecipeSpec.ForgetLearnedRecipeSpec then
        if StockPiler.RecipeSpec.ForgetLearnedRecipeSpec(key) then
            if StockPiler.Print then
                StockPiler.Print(L"Forgot recipe: " .. towstring(label))
            end
            if StockPiler.AutoGrow and StockPiler.AutoGrow.InvalidatePlantQueue then
                StockPiler.AutoGrow.InvalidatePlantQueue()
            end
            StockPilerTabPotions.Refresh()
            if StockPilerTabAutoGrow and StockPilerTabAutoGrow.Refresh then
                StockPilerTabAutoGrow.Refresh()
            end
        end
    end
end

function StockPilerTabPotions.OnForgetRow()
    local data = RowDataFromActiveChild()
    if not data then
        return
    end
    local key = data.recipeSpecKey
    if (not key or key == "") and data.recipeData then
        key = data.recipeData.recipeSpecKey
    end
    if not key or key == "" then
        return
    end
    local label = ToNarrow(data.baseName or data.name) or tostring(key)
    local statsHint = ToNarrow(data.recipeLabel)
    if statsHint and statsHint ~= "" then
        label = label .. " (" .. statsHint .. ")"
    end
    StockPilerTabPotions._pendingForgetKey = key
    StockPilerTabPotions._pendingForgetLabel = label
    if type(DialogManager) == "table" and type(DialogManager.MakeTwoButtonDialog) == "function" then
        local yes = GetString and GetString(StringTables.Default.LABEL_YES) or L"Yes"
        local no = GetString and GetString(StringTables.Default.LABEL_NO) or L"No"
        DialogManager.MakeTwoButtonDialog(
            L"Forget learned recipe?\n" .. towstring(label),
            yes,
            StockPilerTabPotions.ConfirmForgetRecipe,
            no,
            nil
        )
        return
    end
    StockPilerTabPotions.ConfirmForgetRecipe()
end

function StockPilerTabPotions.OnMouseOverForget()
    Tooltips.CreateTextOnlyTooltip(
        SystemData.ActiveWindow.name,
        L"Forget this learned recipe. Re-brew at the Apothecary to learn it again."
    )
    Tooltips.AnchorTooltip(Tooltips.ANCHOR_WINDOW_RIGHT)
end
