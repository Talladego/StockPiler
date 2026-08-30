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
    [3] = "rank",
    [4] = "buff",
    [5] = "duration",
    [6] = "have",
    [7] = "watch",
}

local SORT_HEADERS = {
    watch = "SPTabPotionsSortWatch",
    name = "SPTabPotionsSortName",
    effect = "SPTabPotionsSortEffect",
    rank = "SPTabPotionsSortRank",
    buff = "SPTabPotionsSortBuff",
    duration = "SPTabPotionsSortDuration",
    have = "SPTabPotionsSortHave",
}

local SORT_HEADER_LABELS = {
    name = L"Potion",
    effect = L"Effect",
    rank = L"Rank",
    buff = L"Buff",
    duration = L"Dur",
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
    if text == nil then
        return ""
    end
    if type(text) == "wstring" then
        local ok, s = pcall(WStringToString, text)
        if ok and s then
            return s
        end
        return ""
    end
    return tostring(text)
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

local function BuildRecipeDataForPotion(potionKey, potionName, recipe, potionLevel)
    if type(recipe) ~= "table" then
        return nil
    end
    return {
        name = potionName,
        potionLevel = tonumber(potionLevel) or 0,
        potionUid = tonumber(recipe.outputUid) or 0,
        recipeSpecKey = recipe.recipeSpecKey,
        recipeYield = tonumber(recipe.recipeYield) or 0,
        crafts = tonumber(recipe.crafts) or 0,
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
    if not MatchesNameFilter(row.name, nameFilter) then
        return false
    end
    return MatchesEffectFilter(row.effectKey, effectFilter)
end

local function CompareName(a, b)
    local na = string.lower(ToNarrow(a.name))
    local nb = string.lower(ToNarrow(b.name))
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
    elseif column == "effect" then
        local ea = ToNarrow(a.effectText)
        local eb = ToNarrow(b.effectText)
        if ea == eb then
            return CompareName(a, b)
        end
        return finish(ea < eb)
    elseif column == "rank" then
        local ra = a.rankNum or 0
        local rb = b.rankNum or 0
        if ra == rb then
            return CompareName(a, b)
        end
        return finish(ra < rb)
    elseif column == "buff" then
        local ba = a.buffNum or 0
        local bb = b.buffNum or 0
        if ba == bb then
            return CompareName(a, b)
        end
        return finish(ba < bb)
    elseif column == "duration" then
        local da = a.durationSec or 0
        local db = b.durationSec or 0
        if da == db then
            return CompareName(a, b)
        end
        return finish(da < db)
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
        -- Ascending: watched first.
        return finish(wa and not wb)
    end
    return CompareName(a, b)
end

local function SortRows(rows)
    local s = GetSettings()
    local column = s.potionSortColumn or "rank"
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
    local col = s.potionSortColumn or "rank"
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
    local potions = RS and RS.GetKnownPotionList() or {}

    for i = 1, #potions do
        local potion = potions[i]
        local potionKey = potion.potionKey
        local watch = RS and RS.EnsureWatch(potionKey) or { enabled = false, targetStock = 40 }
        local watched = watch.enabled == true
        local have = RS and RS.PotionHaveCombined(potion) or 0
        local min = tonumber(watch.targetStock) or 0
        local uid = tonumber(potion.outputUid) or 0
        local entry = {
            id = potionKey,
            uniqueID = uid,
            uniqueIDs = { uid },
        }
        local itemData = ResolvePotionItemData(potionKey, uid, nil)
        local effectKey = potion.effectKey
        if not effectKey and itemData and StockPiler.Classify then
            effectKey = StockPiler.Classify.GetEffectKey(itemData)
        end
        local row = {
            id = potionKey,
            potionKey = potionKey,
            entry = entry,
            name = potion.name or towstring(tostring(uid)),
            effectKey = effectKey,
            effectText = EffectTextForRow(effectKey, nil),
            have = have,
            haveText = towstring(tostring(have)),
            min = min,
            minText = towstring(tostring(min)),
            watched = watched,
            iconNum = tonumber(potion.iconNum) or 0,
            itemData = itemData,
            uniqueID = uid,
            observed = true,
        }
        ApplyPotionStats(row, entry, itemData)
        local recipe = RS and RS.RecipeSpecForPotion(potionKey)
        row.recipeSpecKey = recipe and recipe.recipeSpecKey
        row.recipeData = BuildRecipeDataForPotion(potionKey, row.name, recipe, row.rankNum)
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
        local ok, texture, x, y = pcall(GetIconData, iconNum)
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
        L"Known potion outputs from learned recipes. Click the eye header to sort watched first. Hover the note for the recipe; Forget removes it."
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
            LabelSetText(rowName .. "Rank", data.rankText or L"-")
            LabelSetText(rowName .. "Buff", data.buffText or L"-")
            LabelSetText(rowName .. "Duration", data.durationText or L"-")
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
                ButtonSetText(forgetWin, L"Forget")
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
        local ok = pcall(
            Tooltips.CreateItemTooltip,
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
    local line2 = data.effectText or L""
    if data.rankText and data.rankText ~= L"-" then
        if line2 ~= L"" then
            line2 = line2 .. L"  |  "
        end
        line2 = line2 .. L"Rank " .. data.rankText
    end
    if data.buffText and data.buffText ~= L"-" then
        if line2 ~= L"" then
            line2 = line2 .. L"  |  "
        end
        line2 = line2 .. L"Buff " .. data.buffText
    end
    if data.durationText and data.durationText ~= L"-" then
        if line2 ~= L"" then
            line2 = line2 .. L"  |  "
        end
        line2 = line2 .. data.durationText
    end
    if data.uniqueID then
        if line2 ~= L"" then
            line2 = line2 .. L"  |  "
        end
        line2 = line2 .. L"id " .. towstring(tostring(data.uniqueID))
    elseif data.abilityName and data.abilityName ~= L"" then
        if line2 ~= L"" then
            line2 = line2 .. L"  |  "
        end
        line2 = line2 .. data.abilityName
    end
    local line3 = data.tooltip
        or L"Catalog Have counts all matching names in bags (incl. Potent)."
    ShowItemOrTextTooltip(itemData, data.name or L"Potion", line2, line3)
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
    local label = ToNarrow(data.name) or tostring(key)
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

function StockPilerTabPotions.OnMouseOverForget()
    Tooltips.CreateTextOnlyTooltip(
        SystemData.ActiveWindow.name,
        L"Remove this learned recipe from StockPiler. Re-brew at the Apothecary to learn it again."
    )
    Tooltips.AnchorTooltip(Tooltips.ANCHOR_WINDOW_RIGHT)
end
