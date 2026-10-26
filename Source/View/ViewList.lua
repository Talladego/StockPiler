----------------------------------------------------------------
-- StockPiler View/ViewList - shared list chrome helpers
----------------------------------------------------------------

StockPiler = StockPiler or {}
StockPiler.ViewList = StockPiler.ViewList or {}
local VL = StockPiler.ViewList

local DEFAULT_ICON_SCALE = 0.34

function VL.T(key, tokens)
    return StockPiler.Util.T(key, tokens)
end

function VL.ItemRarityNameColor(itemData)
    if itemData and DataUtils and DataUtils.GetItemRarityColor then
        -- Engine GetItemRarityColor treats missing itemSet as utility grey.
        -- Known-potion / Items shells often omit itemSet; probe with 0 when rarity is set.
        local probe = itemData
        if itemData.rarity ~= nil and itemData.itemSet == nil then
            probe = {
                rarity = itemData.rarity,
                itemSet = 0,
            }
        end
        local ok, color = StockPiler.Util.TryCallQuiet(
            "DataUtils.GetItemRarityColor",
            DataUtils.GetItemRarityColor,
            probe
        )
        if ok and type(color) == "table" then
            return tonumber(color.r) or 255, tonumber(color.g) or 255, tonumber(color.b) or 255
        end
    end
    return 255, 255, 255
end

--- opts.zeroAsDash: show ui.dash when n == 0 (Plants default).
function VL.FormatSignedStat(n, opts)
    n = tonumber(n) or 0
    opts = type(opts) == "table" and opts or {}
    if n == 0 and opts.zeroAsDash == true then
        return VL.T("ui.dash")
    end
    if n > 0 then
        return towstring("+" .. tostring(n))
    end
    return towstring(tostring(n))
end

function VL.FormatPercentStat(n)
    n = tonumber(n) or 0
    if n == 0 then
        return VL.T("ui.dash")
    end
    return towstring(tostring(n) .. "%")
end

--- opts.emptyDash: return ui.dash when empty (Plants). Else L"" then upper fallback (Potions).
function VL.EffectTextForRow(effectKey, opts)
    opts = type(opts) == "table" and opts or {}
    if type(effectKey) == "string" and effectKey ~= "" then
        local RS = StockPiler.RecipeSpec
        if RS and RS.NormalizeEffectKeyForUi then
            effectKey = RS.NormalizeEffectKeyForUi(effectKey) or effectKey
        end
        if StockPiler.Classify and StockPiler.Classify.EffectShortLabel then
            local label = StockPiler.Classify.EffectShortLabel(effectKey)
            if label ~= nil and label ~= L"" then
                return label
            end
        end
        if opts.emptyDash ~= true then
            return towstring(string.upper(effectKey))
        end
    end
    if opts.emptyDash == true then
        return VL.T("ui.dash")
    end
    return L""
end

function VL.EffectMenuText(effectKey)
    if type(effectKey) == "string" and effectKey ~= "" then
        local RS = StockPiler.RecipeSpec
        if RS and RS.NormalizeEffectKeyForUi then
            effectKey = RS.NormalizeEffectKeyForUi(effectKey) or effectKey
        end
        if StockPiler.Classify and StockPiler.Classify.EffectFullLabel then
            local label = StockPiler.Classify.EffectFullLabel(effectKey)
            if label ~= nil and label ~= L"" then
                return label
            end
        end
    end
    return VL.EffectTextForRow(effectKey)
end

function VL.SetIconTexture(iconWin, iconNum, scale)
    if not DoesWindowExist(iconWin) then
        return
    end
    scale = tonumber(scale) or DEFAULT_ICON_SCALE
    if iconNum and iconNum > 0 and type(GetIconData) == "function" then
        local ok, texture, x, y = StockPiler.Util.TryCallQuiet("GetIconData", GetIconData, iconNum)
        if ok and texture and texture ~= "" then
            DynamicImageSetTexture(iconWin, texture, x or 0, y or 0)
            if type(DynamicImageSetTextureScale) == "function" then
                DynamicImageSetTextureScale(iconWin, scale)
            end
            WindowSetShowing(iconWin, true)
            return
        end
    end
    DynamicImageSetTexture(iconWin, "", 0, 0)
    WindowSetShowing(iconWin, false)
end

function VL.PaintWatchCheckbox(win, watched, blocked)
    if win == nil or win == "" or not DoesWindowExist(win) then
        return
    end
    blocked = blocked == true
    -- Keep checked when skill-blocked so UI matches store.enabled (Clear count / Forget).
    watched = watched == true
    if ButtonSetCheckButtonFlag then
        ButtonSetCheckButtonFlag(win, true)
    end
    ButtonSetPressedFlag(win, watched)
    if ButtonSetDisabledFlag then
        ButtonSetDisabledFlag(win, blocked)
    end
end

function VL.UpdateSortArrows(headers, column, ascending)
    if type(headers) ~= "table" then
        return
    end
    column = tostring(column or "")
    ascending = ascending ~= false
    for key, win in pairs(headers) do
        if DoesWindowExist(win) then
            local up = win .. "UpArrow"
            local down = win .. "DownArrow"
            if key == column then
                WindowSetShowing(up, ascending)
                WindowSetShowing(down, not ascending)
            else
                WindowSetShowing(up, false)
                WindowSetShowing(down, false)
            end
        end
    end
end

local function NormalizeFilterEffectKey(effectKey)
    effectKey = tostring(effectKey or "")
    if effectKey == "" then
        return nil
    end
    local RS = StockPiler.RecipeSpec
    if RS and RS.NormalizeEffectKeyForUi then
        effectKey = RS.NormalizeEffectKeyForUi(effectKey) or effectKey
    end
    if effectKey == "" then
        return nil
    end
    return effectKey
end

local function NoteKnownEffect(known, effectKey)
    local key = NormalizeFilterEffectKey(effectKey)
    if key ~= nil then
        known[key] = true
    end
end

--- kind "potion" uses learned potions. kind "plant" uses known plants.
local function KnownEffectSet(kind)
    local known = {}
    local Cat = StockPiler.Catalog
    if kind == "plant" then
        if Cat and Cat.ListPlantEntries then
            local rows = Cat.ListPlantEntries()
            if type(rows) == "table" then
                for i = 1, #rows do
                    NoteKnownEffect(known, rows[i] and rows[i].effectKey)
                end
            end
        end
        return known
    end
    if Cat and Cat.ListPotionRecipeEntries then
        local rows = Cat.ListPotionRecipeEntries()
        local RS = StockPiler.RecipeSpec
        if type(rows) == "table" then
            for i = 1, #rows do
                local row = rows[i]
                local key = row and row.effectKey
                if (type(key) ~= "string" or key == "") and RS and RS.ResolveEffectKeyForPotion then
                    key = RS.ResolveEffectKeyForPotion(row.potion or row, {
                        recipeKey = row and row.recipeSpecKey,
                        recipe = row and row.recipe,
                        stamp = true,
                    })
                end
                NoteKnownEffect(known, key)
            end
        end
    end
    return known
end

local function EffectCacheStamp(kind)
    local Know = StockPiler.Knowledge
    local gen = Know and Know.GetGen and tonumber(Know.GetGen()) or 0
    if kind == "plant" then
        return tostring(gen)
    end
    local potions = Know and Know.Potions and Know.Potions()
    local count = 0
    local blank = 0
    local keySum = 0
    if type(potions) == "table" then
        for _, potion in pairs(potions) do
            if type(potion) == "table" then
                count = count + 1
                local key = potion.effectKey
                if type(key) ~= "string" or key == "" then
                    blank = blank + 1
                else
                    for i = 1, #key do
                        keySum = keySum + string.byte(key, i)
                    end
                end
            end
        end
    end
    return tostring(gen) .. ":" .. tostring(count) .. ":" .. tostring(blank) .. ":" .. tostring(keySum)
end

function VL.EffectFilterCycle(kind)
    kind = kind == "plant" and "plant" or "potion"
    local full = {}
    if StockPiler.Classify and StockPiler.Classify.EffectFilterKeys then
        local list = StockPiler.Classify.EffectFilterKeys(kind)
        for i = 1, #list do
            full[#full + 1] = list[i]
        end
    end
    local stamp = EffectCacheStamp(kind)
    VL._effectCycle = VL._effectCycle or {}
    VL._effectCycleGen = VL._effectCycleGen or {}
    if VL._effectCycleGen[kind] == stamp and type(VL._effectCycle[kind]) == "table" then
        return VL._effectCycle[kind]
    end
    local known = KnownEffectSet(kind)
    local keys = { "" }
    for i = 1, #full do
        local key = full[i]
        if known[key] == true then
            keys[#keys + 1] = key
        end
    end
    VL._effectCycle[kind] = keys
    VL._effectCycleGen[kind] = stamp
    return keys
end

function VL.EffectFilterSignature(kind)
    return table.concat(VL.EffectFilterCycle(kind), ",")
end

function VL.SyncEffectCombo(comboWin, currentKey, effectTextFn, kind)
    if not DoesWindowExist(comboWin) then
        return
    end
    local cycle = VL.EffectFilterCycle(kind)
    currentKey = tostring(currentKey or "")
    local selected = 1
    for i = 1, #cycle do
        if cycle[i] == currentKey then
            selected = i
            break
        end
    end
    ComboBoxSetSelectedMenuItem(comboWin, selected)
end

VL.COLOR_WARN = { 220, 180, 60 }
VL.COLOR_GRAY = { 140, 140, 140 }
VL._clearPaint = {}

function VL.SetButtonTextColorAll(windowName, r, g, b)
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

--- Short settings / chrome tips: above the control (stock User Settings).
function VL.Tip(text)
    if Tooltips and Tooltips.CreateTextOnlyTooltip then
        Tooltips.CreateTextOnlyTooltip(SystemData.ActiveWindow.name, text)
        Tooltips.AnchorTooltip(Tooltips.ANCHOR_WINDOW_TOP)
    end
end

function VL.PaintClearButton(win, active)
    if not win or not DoesWindowExist(win) then
        return
    end
    active = active == true
    if VL._clearPaint[win] == active then
        return
    end
    VL._clearPaint[win] = active
    ButtonSetDisabledFlag(win, not active)
    local c = active and VL.COLOR_WARN or VL.COLOR_GRAY
    VL.SetButtonTextColorAll(win, c[1], c[2], c[3])
end

function VL.InitEffectCombo(comboWin, currentKey, effectTextFn, kind)
    if not DoesWindowExist(comboWin) then
        return
    end
    effectTextFn = type(effectTextFn) == "function" and effectTextFn or VL.EffectTextForRow
    ComboBoxClearMenuItems(comboWin)
    ComboBoxAddMenuItem(comboWin, VL.T("potions.all_effects"))
    local cycle = VL.EffectFilterCycle(kind)
    for i = 2, #cycle do
        ComboBoxAddMenuItem(comboWin, VL.EffectMenuText(cycle[i]))
    end
    VL.SyncEffectCombo(comboWin, currentKey, effectTextFn, kind)
end

--- Two-button confirm; calls onYes immediately if DialogManager missing.
function VL.ConfirmTwoButton(message, onYes)
    if type(DialogManager) == "table" and type(DialogManager.MakeTwoButtonDialog) == "function" then
        local yes = GetString and GetString(StringTables.Default.LABEL_YES) or VL.T("ui.yes")
        local no = GetString and GetString(StringTables.Default.LABEL_NO) or VL.T("ui.no")
        DialogManager.MakeTwoButtonDialog(message, yes, onYes, no, nil)
        return true
    end
    if type(onYes) == "function" then
        onYes()
    end
    return false
end

function VL.ShowTextTip(anchorWin, text, anchor)
    if not (Tooltips and Tooltips.CreateTextOnlyTooltip) then
        return
    end
    Tooltips.CreateTextOnlyTooltip(anchorWin or SystemData.ActiveWindow.name, text)
    -- Default matches SettingsWindowTabbed.CreateAutoTooltip (above the control).
    Tooltips.AnchorTooltip(anchor or Tooltips.ANCHOR_WINDOW_TOP)
end

--- Live text tooltip shell: state table with _liveWindow/_liveAnchor/_liveFp.
--- api = { buildText=fn, fingerprint=fn, show=fn? }
function VL.LiveTipShow(state, buildText, fingerprint, mouseoverWindow, anchor, defaultAnchor)
    mouseoverWindow = mouseoverWindow or (SystemData and SystemData.ActiveWindow and SystemData.ActiveWindow.name)
    if mouseoverWindow == nil or mouseoverWindow == "" then
        return
    end
    state._liveWindow = mouseoverWindow
    state._liveAnchor = anchor or defaultAnchor or (Tooltips and Tooltips.ANCHOR_WINDOW_TOP)
    state._liveFp = fingerprint()
    Tooltips.CreateTextOnlyTooltip(mouseoverWindow, buildText())
    Tooltips.AnchorTooltip(state._liveAnchor)
end

function VL.LiveTipClear(state)
    state._liveWindow = nil
    state._liveFp = nil
end

function VL.LiveTipMaybeRefresh(state, buildText, fingerprint, showFn)
    local win = state._liveWindow
    if win == nil or win == "" then
        return
    end
    -- Engine clears the tip when mouse leaves; without this gate, TickLive re-Shows
    -- the tip (timer/fingerprint churn) and it flickers with no hover.
    local mouseWin = SystemData and SystemData.MouseOverWindow and SystemData.MouseOverWindow.name
    if mouseWin ~= win then
        VL.LiveTipClear(state)
        return
    end
    local fp = fingerprint()
    if fp == state._liveFp then
        return
    end
    if type(showFn) == "function" then
        showFn(win, state._liveAnchor)
    else
        VL.LiveTipShow(state, buildText, fingerprint, win, state._liveAnchor)
    end
end

----------------------------------------------------------------
-- List row zebra + mouseover highlight
----------------------------------------------------------------

--- Walk up from a child control to the ListBox row that owns ...Background.
function VL.ResolveListRow(winName)
    winName = tostring(winName or "")
    local guard = 0
    while winName ~= "" and guard < 8 do
        guard = guard + 1
        if string.find(winName, "ListRow", 1, true)
            and type(DoesWindowExist) == "function"
            and DoesWindowExist(winName .. "Background")
        then
            return winName
        end
        if type(WindowGetParent) ~= "function" then
            break
        end
        winName = WindowGetParent(winName) or ""
    end
    return nil
end

local function PaintRowHover(bgName)
    if type(DoesWindowExist) == "function" and not DoesWindowExist(bgName) then
        return
    end
    local c = DefaultColor and DefaultColor.ROW_BACKGROUND_HIGHLIGHT
    if type(c) ~= "table" then
        c = { r = 66, g = 35, b = 0, a = 1 }
    end
    WindowSetTintColor(bgName, tonumber(c.r) or 66, tonumber(c.g) or 35, tonumber(c.b) or 0)
    if type(WindowSetAlpha) == "function" and c.a ~= nil then
        WindowSetAlpha(bgName, tonumber(c.a) or 1)
    end
end

--- Apply zebra stripe, or keep mouseover highlight if this row is hovered.
function VL.ApplyRowStripe(bgName, rowIndex)
    if type(DoesWindowExist) == "function" and not DoesWindowExist(bgName) then
        return
    end
    rowIndex = tonumber(rowIndex) or 1
    if VL._hoverRow and (VL._hoverRow .. "Background") == bgName then
        PaintRowHover(bgName)
        return
    end
    if DefaultColor and DefaultColor.SetListRowTint then
        DefaultColor.SetListRowTint(bgName, rowIndex, false)
    end
end

function VL.BeginRowHover(rowName)
    rowName = tostring(rowName or "")
    if rowName == "" or (type(DoesWindowExist) == "function" and not DoesWindowExist(rowName)) then
        return
    end
    local rowIndex = tonumber(WindowGetId(rowName)) or 1
    if VL._hoverRow and VL._hoverRow ~= rowName then
        local prev = VL._hoverRow
        local prevIdx = VL._hoverRowIndex or 1
        VL._hoverRow = nil
        VL._hoverRowIndex = nil
        if DoesWindowExist(prev .. "Background") and DefaultColor and DefaultColor.SetListRowTint then
            DefaultColor.SetListRowTint(prev .. "Background", prevIdx, false)
        end
    end
    VL._hoverRow = rowName
    VL._hoverRowIndex = rowIndex
    PaintRowHover(rowName .. "Background")
end

function VL.EndRowHover(rowName)
    rowName = tostring(rowName or "")
    if rowName == "" or VL._hoverRow ~= rowName then
        return
    end
    local mouseWin = SystemData and SystemData.MouseOverWindow and SystemData.MouseOverWindow.name
    if mouseWin and mouseWin ~= "" and VL.ResolveListRow(mouseWin) == rowName then
        return
    end
    local idx = VL._hoverRowIndex or 1
    VL._hoverRow = nil
    VL._hoverRowIndex = nil
    if DoesWindowExist(rowName .. "Background") and DefaultColor and DefaultColor.SetListRowTint then
        DefaultColor.SetListRowTint(rowName .. "Background", idx, false)
    end
end

function VL.OnRowMouseOver()
    VL.BeginRowHover(SystemData.ActiveWindow.name)
end

function VL.OnRowMouseOverEnd()
    VL.EndRowHover(SystemData.ActiveWindow.name)
end

function VL.OnRowChildMouseOver()
    local row = VL.ResolveListRow(SystemData.ActiveWindow.name)
    if row then
        VL.BeginRowHover(row)
    end
end

function VL.OnRowChildMouseOverEnd()
    local row = VL.ResolveListRow(SystemData.ActiveWindow.name)
    if row then
        VL.EndRowHover(row)
    end
end

-- Flat global for XML EventHandler paths (engine resolves one table level).
StockPilerViewList = VL
