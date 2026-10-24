----------------------------------------------------------------
-- StockPiler RecipeShare -- preview before a recipe link is learned
-- Chat clicks and /stp apply open this window. Learn is the import.
----------------------------------------------------------------

StockPiler = StockPiler or {}
StockPiler.RecipeShare = StockPiler.RecipeShare or {}
local RS = StockPiler.RecipeShare

local WIN = "StockPilerRecipeShareWindow"
local LEARN = WIN .. "Learn"
local MAX_ROWS = 5

RS._fields = nil
RS._learned = false
RS._rows = nil

local ROLE_ORDER = {
    container = 1,
    main = 2,
    stabilizer = 3,
    goldweed = 3,
    extender = 4,
    multiplier = 5,
    stimulant = 5,
    ingredient = 6,
}

local BONUS_KEY = {
    [1] = "material.bonus.stability",
    [2] = "material.bonus.power",
    [3] = "material.bonus.duration",
    [4] = "material.bonus.multiplier",
    [12] = "material.bonus.critical",
    [13] = "material.bonus.fail",
    [14] = "material.bonus.supercrit",
}

local function T(key, tokens)
    return StockPiler.Util.T(key, tokens)
end

local function Print(msg)
    if StockPiler.Debug and StockPiler.Debug.Reply then
        StockPiler.Debug.Reply(msg)
    elseif StockPiler.Debug and StockPiler.Debug.Print then
        StockPiler.Debug.Print(msg, "user")
    end
end

local function ToNarrow(v)
    if StockPiler.Util and StockPiler.Util.ToNarrow then
        return StockPiler.Util.ToNarrow(v)
    end
    return tostring(v or "")
end

local function ToW(v)
    if type(v) == "wstring" then
        return v
    end
    if v == nil then
        return L""
    end
    return towstring(tostring(v))
end

local function SetLabel(win, text)
    if type(LabelSetText) == "function" then
        LabelSetText(win, ToW(text))
    end
end

local function SetShown(win, showing)
    if type(WindowSetShowing) == "function" then
        WindowSetShowing(win, showing == true)
    end
end

local function KnownItem(uid)
    local RL = StockPiler.RecipeLink
    if RL and RL.KnownItemRow then
        return RL.KnownItemRow(uid)
    end
    return nil
end

local function Carried(fields, uid)
    local details = fields and fields.details
    uid = tonumber(uid) or 0
    if uid <= 0 or type(details) ~= "table" then
        return nil
    end
    return details[uid]
end

local function RoleTitle(role)
    role = tostring(role or "")
    if role == "" then
        return T("material.role.ingredient")
    end
    return T("material.role." .. role)
end

local function BonusText(ref, value)
    local n = tonumber(value)
    if n == nil then
        return nil
    end
    local MS = StockPiler.MaterialSpec
    if n ~= 0 and MS and MS.FormatBonusLine then
        local line = MS.FormatBonusLine(ref, n)
        if type(line) == "table" and line.text ~= nil and ToNarrow(line.text) ~= "" then
            return line.text
        end
    end
    if n ~= 0 then
        return nil
    end
    local percent = ref == 12 or ref == 13 or ref == 14
    local key = percent and "material.bonus.pct" or "material.bonus.flat"
    local nameKey = BONUS_KEY[ref] or "material.bonus.generic"
    return T(key, { value = "0", name = T(nameKey) })
end

--- Family, effect, type, level, grow time, and destroy-on-fail are not stats.
--- CraftItemInfo.FormatBonus turns those into "Tradeskill ..." and "Requires Level ...".
local function MetadataBonusRefs()
    local skip = {
        [5] = true,
        [6] = true,
        [8] = true,
        [9] = true,
        [10] = true,
        [15] = true,
    }
    local MS = StockPiler.MaterialSpec
    local B = MS and MS.CraftBonusRefs and MS.CraftBonusRefs()
    if type(B) == "table" then
        local names = {
            "CRAFTING_FAMILY",
            "EFFECT",
            "TYPE",
            "CRAFTING_LEVEL",
            "GROW_TIME",
            "DESTROY_ON_FAIL",
        }
        for i = 1, #names do
            local ref = tonumber(B[names[i]])
            if ref ~= nil and ref > 0 then
                skip[ref] = true
            end
        end
    end
    return skip
end

local function StatBonusOrder()
    local MS = StockPiler.MaterialSpec
    local B = MS and MS.CraftBonusRefs and MS.CraftBonusRefs() or {}
    return {
        B.STABILITY or 1,
        B.POWER or 2,
        B.DURATION or 3,
        B.MULTIPLIER or 4,
        B.YIELD or 11,
        B.CRITICAL_CHANCE or 12,
        B.SPECIAL_CHANCE or 14,
        B.FAIL_CHANCE or 13,
    }
end

local function BonusLines(spec)
    local lines = {}
    local bonuses = type(spec) == "table" and spec.bonuses or nil
    if type(bonuses) ~= "table" then
        bonuses = {}
    end
    local effect = tonumber(spec and spec.effectId) or 0
    if effect <= 0 then
        effect = tonumber(bonuses[6]) or 0
    end
    if effect > 0 then
        local named = nil
        local MS = StockPiler.MaterialSpec
        if MS and MS.EffectDisplayName then
            named = MS.EffectDisplayName({ effectId = effect })
        end
        if named ~= nil and ToNarrow(named) ~= "" then
            lines[#lines + 1] = named
        else
            lines[#lines + 1] = T("share.effect", { id = tostring(effect) })
        end
    end
    local skip = MetadataBonusRefs()
    local order = StatBonusOrder()
    for i = 1, #order do
        local ref = order[i]
        if skip[ref] ~= true and bonuses[ref] ~= nil then
            local text = BonusText(ref, bonuses[ref])
            if text ~= nil then
                lines[#lines + 1] = text
            end
        end
    end
    return lines
end

local function JoinTip(lines)
    local out = nil
    for i = 1, #lines do
        local piece = lines[i]
        if piece ~= nil and ToNarrow(piece) ~= "" then
            if out == nil then
                out = ToW(piece)
            else
                out = out .. towstring("\n") .. ToW(piece)
            end
        end
    end
    return out or L""
end

function RS.DescribeSlot(slot, fields)
    slot = type(slot) == "table" and slot or {}
    local spec = type(slot.spec) == "table" and slot.spec or slot
    local uid = tonumber(slot.uid or spec.uid) or 0
    local role = tostring(slot.role or spec.role or "")
    local qty = tonumber(slot.perCraft) or 1
    if qty < 1 then
        qty = 1
    end
    local known = KnownItem(uid)
    local carried = Carried(fields, uid)
    local name = nil
    local icon = 0
    if type(known) == "table" then
        name = known.name
        icon = tonumber(known.iconNum) or 0
    end
    if (name == nil or ToNarrow(name) == "") and type(carried) == "table" then
        name = carried.name
    end
    if icon <= 0 and type(carried) == "table" then
        icon = tonumber(carried.icon) or 0
    end
    if icon <= 0 then
        icon = tonumber(spec.iconNum or slot.iconNum) or 0
    end
    if name == nil or ToNarrow(name) == "" then
        name = T("share.unknown_item", { uid = tostring(uid) })
    end
    local base = T("share.slot_line", {
        qty = tostring(qty),
        role = RoleTitle(role),
        name = name,
    })
    local lines = { base }
    local bonuses = BonusLines(spec)
    for i = 1, #bonuses do
        lines[#lines + 1] = bonuses[i]
    end
    local label = base
    if #bonuses > 0 then
        local summary = nil
        for i = 1, #bonuses do
            local piece = bonuses[i]
            if piece ~= nil and ToNarrow(piece) ~= "" then
                if summary == nil then
                    summary = ToW(piece)
                else
                    summary = summary .. T("share.bonus_sep") .. ToW(piece)
                end
            end
        end
        if summary ~= nil then
            label = ToW(base) .. T("share.bonus_sep") .. summary
        end
    end
    return {
        uid = uid,
        role = role,
        qty = qty,
        name = name,
        icon = icon,
        label = label,
        tip = JoinTip(lines),
    }
end

local function SortedSlots(slots)
    local copy = {}
    if type(slots) ~= "table" then
        return copy
    end
    for i = 1, #slots do
        copy[#copy + 1] = slots[i]
    end
    table.sort(copy, function(a, b)
        local ra = ROLE_ORDER[tostring(a and a.role or "")] or 99
        local rb = ROLE_ORDER[tostring(b and b.role or "")] or 99
        if ra ~= rb then
            return ra < rb
        end
        return (tonumber(a and a.uid) or 0) < (tonumber(b and b.uid) or 0)
    end)
    return copy
end

local function PotionPresentation(fields)
    fields = type(fields) == "table" and fields or {}
    local uid = tonumber(fields.uid) or 0
    local known = KnownItem(uid)
    local carried = Carried(fields, uid)
    local name = fields.name
    local icon = tonumber(fields.icon) or 0
    local rarity = tonumber(fields.rarity)
    local iLevel = tonumber(fields.iLevel) or tonumber(fields.lv)
    if type(known) == "table" then
        if known.name ~= nil and ToNarrow(known.name) ~= "" then
            name = known.name
        end
        if icon <= 0 then
            icon = tonumber(known.iconNum) or 0
        end
        if rarity == nil then
            rarity = tonumber(known.rarity)
        end
        if iLevel == nil or iLevel <= 0 then
            iLevel = tonumber(known.iLevel) or tonumber(known.level)
        end
    end
    local saved = nil
    local Spec = StockPiler.RecipeSpec
    if uid > 0 and Spec and Spec.GetPotion then
        saved = Spec.GetPotion(uid)
    end
    if type(saved) == "table" then
        if (name == nil or ToNarrow(name) == "") and saved.name ~= nil and ToNarrow(saved.name) ~= "" then
            name = saved.name
        end
        if icon <= 0 then
            icon = tonumber(saved.iconNum) or 0
        end
        if rarity == nil then
            rarity = tonumber(saved.rarity)
        end
        if iLevel == nil or iLevel <= 0 then
            iLevel = tonumber(saved.iLevel)
        end
    end
    if (name == nil or ToNarrow(name) == "") and type(carried) == "table" then
        name = carried.name
    end
    if icon <= 0 and type(carried) == "table" then
        icon = tonumber(carried.icon) or 0
    end
    if name == nil or ToNarrow(name) == "" then
        name = T("ui.potion_fallback")
    end
    return name, icon, rarity, iLevel
end

RS.PotionPresentation = PotionPresentation

local function SetPotionNameColor(rarity)
    local r, g, b = 255, 255, 255
    local VL = StockPiler.ViewList
    if VL and VL.ItemRarityNameColor and rarity ~= nil then
        r, g, b = VL.ItemRarityNameColor({ rarity = rarity, itemSet = 0 })
    end
    if type(LabelSetTextColor) == "function" then
        LabelSetTextColor(WIN .. "PotionName", r, g, b)
    end
end

local function StatusKey()
    if RS._learned == true then
        return "share.status_learned"
    end
    local RL = StockPiler.RecipeLink
    if RL and RL.RecipeIsKnown and RL.RecipeIsKnown(RS._fields) == true then
        return "share.status_known"
    end
    return "share.status_new"
end

local function LearnEnabled()
    return StatusKey() == "share.status_new"
end

local SHARE_ICON_SCALE = 28 / 64

local function SetIcon(win, icon)
    icon = tonumber(icon) or 0
    if icon <= 0 then
        SetShown(win, false)
        return
    end
    local VL = StockPiler.ViewList
    if VL and type(VL.SetIconTexture) == "function" then
        VL.SetIconTexture(win, icon, SHARE_ICON_SCALE)
        return
    end
    if type(GetIconData) ~= "function" or type(DynamicImageSetTexture) ~= "function" then
        SetShown(win, false)
        return
    end
    local ok, texture, x, y
    if StockPiler.Util and StockPiler.Util.TryCallQuiet then
        ok, texture, x, y = StockPiler.Util.TryCallQuiet("GetIconData", GetIconData, icon)
    else
        ok, texture, x, y = pcall(GetIconData, icon)
    end
    if ok and texture ~= nil and texture ~= "" then
        DynamicImageSetTexture(win, texture, x or 0, y or 0)
        if type(DynamicImageSetTextureScale) == "function" then
            DynamicImageSetTextureScale(win, SHARE_ICON_SCALE)
        end
        SetShown(win, true)
        return
    end
    SetShown(win, false)
end

function RS.Paint()
    local fields = RS._fields
    if type(fields) ~= "table" then
        return false
    end
    local name, icon, rarity = PotionPresentation(fields)
    SetLabel(WIN .. "TitleText", T("share.title"))
    SetLabel(WIN .. "PotionName", name)
    SetPotionNameColor(rarity)
    SetLabel(WIN .. "Status", T(StatusKey()))
    local hint = T("share.hint")
    local slots = SortedSlots(fields.slots)
    if #slots > MAX_ROWS then
        hint = T("share.more", { extra = tostring(#slots - MAX_ROWS) })
    end
    SetLabel(WIN .. "Hint", hint)
    SetLabel(WIN .. "IngredientsHeading", T("share.ingredients"))
    if type(ButtonSetText) == "function" then
        ButtonSetText(LEARN, T("share.learn"))
        ButtonSetText(WIN .. "Cancel", T("share.cancel"))
    end
    if type(ButtonSetDisabledFlag) == "function" then
        ButtonSetDisabledFlag(LEARN, LearnEnabled() ~= true)
    end
    local rows = {}
    for i = 1, MAX_ROWS do
        local slot = slots[i]
        local iconWin = WIN .. "Ingredient" .. tostring(i) .. "Icon"
        local labelWin = WIN .. "Ingredient" .. tostring(i)
        if type(slot) == "table" then
            local described = RS.DescribeSlot(slot, fields)
            rows[i] = described
            SetShown(iconWin, true)
            SetShown(labelWin, true)
            SetIcon(iconWin, described.icon)
            SetLabel(labelWin, described.label)
        else
            SetShown(iconWin, false)
            SetShown(labelWin, false)
            SetLabel(labelWin, L"")
        end
    end
    RS._rows = rows
    RS._potionName = name
    RS._potionIcon = icon
    RS._statusKey = StatusKey()
    RS._learnEnabled = LearnEnabled()
    return true
end

local function RegisterEscape()
    if type(WindowUtils) == "table" and type(WindowUtils.AddToOpenList) == "function" then
        local mode = WindowUtils.Cascade and WindowUtils.Cascade.MODE_AUTOMATIC
        WindowUtils.AddToOpenList(WIN, RS.OnClose, mode)
    end
end

local function UnregisterEscape()
    if type(WindowUtils) == "table" and type(WindowUtils.RemoveFromOpenList) == "function" then
        WindowUtils.RemoveFromOpenList(WIN)
    end
end

function RS.Show(fields)
    local RL = StockPiler.RecipeLink
    if type(fields) ~= "table" or not (RL and RL.HasMainAndContainer) then
        Print(T("link.bad_payload"))
        return false
    end
    if RL.HasMainAndContainer(fields.slots) ~= true then
        Print(T("link.bad_payload"))
        return false
    end
    RS._fields = fields
    RS._learned = false
    RS.Paint()
    RegisterEscape()
    SetShown(WIN, true)
    RS._open = true
    return true
end

function RS.ShowFromPlain(plain)
    local RL = StockPiler.RecipeLink
    if not (RL and RL.ParsePlain) then
        Print(T("link.bad_payload"))
        return false
    end
    local fields = RL.ParsePlain(plain)
    if type(fields) ~= "table" then
        Print(T("link.bad_payload"))
        return false
    end
    return RS.Show(fields)
end

function RS.OnInitialize()
    SetLabel(WIN .. "TitleText", T("share.title"))
    if type(ButtonSetText) == "function" then
        ButtonSetText(LEARN, T("share.learn"))
        ButtonSetText(WIN .. "Cancel", T("share.cancel"))
    end
end

function RS.OnHidden()
    RS._open = false
    UnregisterEscape()
end

function RS.OnClose()
    RS._learned = false
    SetShown(WIN, false)
    RS.OnHidden()
    return true
end

function RS.OnLearn()
    local fields = RS._fields
    local RL = StockPiler.RecipeLink
    if type(fields) ~= "table" or not (RL and RL.ImportKnownPotion) then
        return false
    end
    if LearnEnabled() ~= true then
        return false
    end
    local result = RL.ImportKnownPotion(fields)
    if result ~= "imported" and result ~= "known" then
        Print(T("link.import_failed", { name = RS._potionName or T("ui.potion_fallback") }))
        return false
    end
    RS._learned = true
    RS.Paint()
    return true
end

function RS.OnMouseOverIngredient()
    local name = SystemData and SystemData.ActiveWindow and SystemData.ActiveWindow.name
    local index = tonumber(string.match(tostring(name or ""), "Ingredient(%d+)"))
    local row = index and RS._rows and RS._rows[index] or nil
    if type(row) ~= "table" then
        return
    end
    if Tooltips and Tooltips.CreateTextOnlyTooltip then
        Tooltips.CreateTextOnlyTooltip(name, row.tip)
        if Tooltips.AnchorTooltip and Tooltips.ANCHOR_WINDOW_RIGHT then
            Tooltips.AnchorTooltip(Tooltips.ANCHOR_WINDOW_RIGHT)
        end
    end
end

function RS.OnMouseOverEndIngredient()
    if Tooltips and Tooltips.ClearTooltip then
        Tooltips.ClearTooltip()
    end
end
