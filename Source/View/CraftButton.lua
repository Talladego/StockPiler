----------------------------------------------------------------
-- StockPiler View/CraftButton - floating round craft HUD
-- Layout Editor + idle drag (WindowSetMovable when LMB would not craft).
-- Harvest: footer-style Prepare + gameactionbutton. Brew: Macro.CraftClick.
-- RMB: toggle. Scale via /stp button. Growing: pie + optional /stp button timer.
-- Disabled harvest art only when idle (nothing growing / not ready).
----------------------------------------------------------------

StockPiler = StockPiler or {}
StockPiler.CraftButton = StockPiler.CraftButton or {}
local Button = StockPiler.CraftButton

local WIN = "StockPilerCraftButton"
local ICON_WIN = "StockPilerCraftButtonIcon"
local FRAME_WIN = "StockPilerCraftButtonFrame"
local CD_WIN = "StockPilerCraftButtonCooldown"
local CD_TIMER = "StockPilerCraftButtonCooldownTimer"
local GROW_TIMER = "StockPilerCraftButtonGrowTimer"
Button.WINDOW_NAME = WIN
local ICON_HARVEST = 2486
local ICON_BREW = 10985

-- 100% layout (native icon + fitted frame). Runtime sizes = base * scale.
local BASE_FRAME = 92
local BASE_ICON = 64
local FRAME_SLICE = 128
-- GrowTimer XML size at scale 1.0; WindowSetScale tracks /stp button scale.
local BASE_TIMER_W = 72
local BASE_TIMER_H = 20
local DEFAULT_SCALE = 1.0
local MIN_SCALE = 0.25
local MAX_SCALE = 2.0
-- Icon-only hover/press vs idle size (48 = idle baseline).
local HOVER_NUM = 50
local PRESS_NUM = 44
local MOTION_DEN = 48

local _initialized = false
local _iconMode = nil
local _iconLit = nil
local _iconId = nil
local _mode = "idle"
local _hovering = false
local _pressed = false
local _tipSuppressed = false
local _shiftLockClick = false
-- Brief press visual when the hotbar Craft macro actually fires (not HUD LMB).
local _macroFlashRemain = nil
local MACRO_FLASH_SEC = 0.12
local _cdMax = 0
local _cdRemain = nil
local _cdArmed = false

local function T(key, tokens)
    if StockPiler.Util and StockPiler.Util.T then
        return StockPiler.Util.T(key, tokens)
    end
    return L""
end

local function TryCall(context, fn, ...)
    if StockPiler.Util and StockPiler.Util.TryCall then
        return StockPiler.Util.TryCall(context, fn, ...)
    end
    if type(fn) ~= "function" then
        return false
    end
    local ok = pcall(fn, ...)
    return ok == true
end

local function ClampScale(n)
    n = tonumber(n)
    if n == nil then
        return DEFAULT_SCALE
    end
    if n < MIN_SCALE then
        return MIN_SCALE
    end
    if n > MAX_SCALE then
        return MAX_SCALE
    end
    return n
end

function Button.GetScale()
    local s = StockPiler.Persistence and StockPiler.Persistence.EnsureSettings and StockPiler.Persistence.EnsureSettings()
    if type(s) == "table" and s.craftButtonScale ~= nil then
        return ClampScale(s.craftButtonScale)
    end
    return DEFAULT_SCALE
end

-- When true, ready harvest/brew swap the HUD icon to the plant / potion art.
-- Kept off: always use the stock harvest mushroom / brew seed icons.
local USE_READY_ITEM_ICONS = false

--- Floating button only. Craft macro keeps mushroom / seed overlay unchanged.
local function IconIdForMode(iconMode, canUse)
    local Timer = StockPiler.CraftHarvestTimer
    if iconMode == "brew" then
        if USE_READY_ITEM_ICONS == true and Timer and Timer.ReadyPotionIcon then
            local potion = tonumber(Timer.ReadyPotionIcon()) or 0
            if potion > 0 then
                return potion
            end
        end
        return ICON_BREW
    end
    -- Optional: harvest ready shows the grown plant instead of the mushroom.
    if USE_READY_ITEM_ICONS == true then
        local harvestReady = canUse == true
            or (Timer and Timer.HasHarvestReady and Timer.HasHarvestReady() == true)
        if harvestReady and Timer and Timer.ReadyPlantIcon then
            local plant = tonumber(Timer.ReadyPlantIcon()) or 0
            if plant > 0 then
                return plant
            end
        end
    end
    return ICON_HARVEST
end

--- lit=false → disabled texture (idle only). Growing uses lit harvest + pie.
local function SetIconTexture(iconNum, lit)
    if not DoesWindowExist(ICON_WIN) then
        return
    end
    if not (iconNum and iconNum > 0 and type(GetIconData) == "function" and type(CircleImageSetTexture) == "function") then
        if type(CircleImageSetTexture) == "function" then
            CircleImageSetTexture(ICON_WIN, "", 0, 0)
        end
        return
    end
    local ok, texture, x, y, disabledTexture = false, nil, 0, 0, nil
    if StockPiler.Util and StockPiler.Util.TryCallQuiet then
        ok, texture, x, y, disabledTexture = StockPiler.Util.TryCallQuiet("GetIconData", GetIconData, iconNum)
    else
        ok, texture, x, y, disabledTexture = pcall(GetIconData, iconNum)
    end
    if not (ok and texture and texture ~= "") then
        CircleImageSetTexture(ICON_WIN, "", 0, 0)
        return
    end
    if lit ~= true and disabledTexture and disabledTexture ~= "" then
        texture = disabledTexture
    end
    CircleImageSetTexture(ICON_WIN, texture, (x or 0) + 32, (y or 0) + 32)
    WindowSetShowing(ICON_WIN, true)
end

-- Match stock action bars (DefaultColor.ActionCooldown in defaultcolor.lua).
local CD_TINT = { r = 20, g = 20, b = 50, a = 0.75 }

local function StyleGrowCooldown()
    if type(DoesWindowExist) ~= "function" or not DoesWindowExist(CD_WIN) then
        return
    end
    if type(WindowSetTintColor) == "function" then
        WindowSetTintColor(CD_WIN, CD_TINT.r, CD_TINT.g, CD_TINT.b)
    end
    if type(WindowSetAlpha) == "function" then
        WindowSetAlpha(CD_WIN, CD_TINT.a)
    end
    if DoesWindowExist(CD_TIMER) and type(WindowSetShowing) == "function" then
        WindowSetShowing(CD_TIMER, false)
    end
end

local function ClearGrowCooldown()
    _cdMax = 0
    _cdRemain = nil
    _cdArmed = false
    if type(DoesWindowExist) == "function" and DoesWindowExist(CD_WIN) then
        if type(CooldownDisplaySetCooldown) == "function" then
            pcall(CooldownDisplaySetCooldown, CD_WIN, 0, 0)
        end
        if type(WindowSetShowing) == "function" then
            WindowSetShowing(CD_WIN, false)
        end
    end
end

local function SettingsRow()
    local P = StockPiler.Persistence
    return P and P.EnsureSettings and P.EnsureSettings() or nil
end

function Button.IsVisible()
    local s = SettingsRow()
    return type(s) ~= "table" or s.craftButtonVisible ~= false
end

--- Same flag Layout Editor uses: windowsList[WIN].isLocked (Settings[WIN].locked).
local function LayoutWindowData()
    return LayoutEditor and LayoutEditor.windowsList and LayoutEditor.windowsList[WIN]
end

local function PersistLayoutLocked(locked)
    if not LayoutEditor then
        return
    end
    LayoutEditor.Settings = LayoutEditor.Settings or {}
    local st = LayoutEditor.Settings[WIN]
    if type(st) ~= "table" then
        st = {}
        LayoutEditor.Settings[WIN] = st
    end
    st.locked = locked == true
end

function Button.IsLocked()
    local data = LayoutWindowData()
    if type(data) == "table" then
        return data.isLocked == true
    end
    local st = LayoutEditor and LayoutEditor.Settings and LayoutEditor.Settings[WIN]
    if type(st) == "table" then
        return st.locked == true
    end
    return false
end

--- Drag only when HUD is shown, unlocked, and LMB would not harvest/brew.
local function SetIdleMovable(canCraft)
    if type(WindowSetMovable) ~= "function" or not DoesWindowExist(WIN) then
        return
    end
    local allowDrag = Button.IsVisible() == true
        and Button.IsLocked() ~= true
        and canCraft ~= true
    WindowSetMovable(WIN, allowDrag)
end

local function UiScale()
    local s = 1
    if InterfaceCore and InterfaceCore.GetScale then
        s = tonumber(InterfaceCore.GetScale()) or 1
        if s == 0 then
            s = 1
        end
    end
    return s
end

--- Keep the whole button on-screen. Off-edge clips icon/frame differently and
--- looks "dismantled". Returns true when the position changed.
function Button.ClampToScreen()
    if type(DoesWindowExist) ~= "function" or not DoesWindowExist(WIN) then
        return false
    end
    if type(WindowGetScreenPosition) ~= "function"
        or type(WindowGetDimensions) ~= "function"
        or type(WindowClearAnchors) ~= "function"
        or type(WindowAddAnchor) ~= "function"
    then
        return false
    end
    local scale = UiScale()
    local sx, sy = WindowGetScreenPosition(WIN)
    sx = (tonumber(sx) or 0) / scale
    sy = (tonumber(sy) or 0) / scale
    local w, h = WindowGetDimensions(WIN)
    w = tonumber(w) or 0
    h = tonumber(h) or 0
    local sw, sh = WindowGetDimensions("Root")
    sw = tonumber(sw) or 0
    sh = tonumber(sh) or 0
    if sw <= 0 or sh <= 0 or w <= 0 or h <= 0 then
        return false
    end
    local cx = sx
    local cy = sy
    if cx < 0 then
        cx = 0
    end
    if cy < 0 then
        cy = 0
    end
    if cx + w > sw then
        cx = math.max(0, sw - w)
    end
    if cy + h > sh then
        cy = math.max(0, sh - h)
    end
    if cx == sx and cy == sy then
        return false
    end
    WindowClearAnchors(WIN)
    WindowAddAnchor(WIN, "topleft", "Root", "topleft", cx, cy)
    return true
end

--- While idle-dragging, pin the button fully inside Root every frame.
--- Macro press flash drains via TickMacroFlash (defined with ApplyIconMotion).
function Button.OnUpdate(timeElapsed)
    if type(WindowGetMoving) == "function" and DoesWindowExist(WIN)
        and WindowGetMoving(WIN) == true
    then
        Button.ClampToScreen()
    end
    if Button.TickMacroFlash then
        Button.TickMacroFlash(timeElapsed)
    end
end

function Button.SetVisible(on)
    local s = SettingsRow()
    if type(s) ~= "table" then
        return Button.IsVisible()
    end
    s.craftButtonVisible = on ~= false
    if Button.ApplyVisibility then
        pcall(Button.ApplyVisibility)
    end
    return s.craftButtonVisible ~= false
end

function Button.SetLocked(on)
    on = on == true
    local data = LayoutWindowData()
    if type(data) == "table" then
        data.isLocked = on
    end
    PersistLayoutLocked(on)
    -- Drop legacy SP-only lock flag (migrated to LayoutEditor).
    local s = SettingsRow()
    if type(s) == "table" and s.craftButtonLockPosition ~= nil then
        s.craftButtonLockPosition = nil
    end
    if DoesWindowExist(WIN) then
        local Macro = StockPiler.Macro
        local snap = Macro and Macro.ResolveCraftMode and Macro.ResolveCraftMode({ readonly = true })
        local canUse = type(snap) == "table" and snap.craftCanUse == true
        SetIdleMovable(canUse)
    end
    return Button.IsLocked()
end

function Button.ApplyVisibility()
    if not DoesWindowExist(WIN) then
        return
    end
    local show = Button.IsVisible() == true
    if type(WindowSetShowing) == "function" then
        WindowSetShowing(WIN, show)
    end
    if show ~= true then
        if type(WindowSetMovable) == "function" then
            WindowSetMovable(WIN, false)
        end
        local tip = StockPiler.CraftTooltip
        if tip and tip.ClearLive then
            tip.ClearLive()
        end
        if Tooltips and type(Tooltips.ClearTooltip) == "function" then
            Tooltips.ClearTooltip()
        end
        return
    end
    if Button.SyncAppearance then
        pcall(Button.SyncAppearance)
    end
end

local function IsShowTimer()
    local s = SettingsRow()
    return type(s) == "table" and s.craftButtonShowTimer == true
end

function Button.IsShowTimer()
    return IsShowTimer()
end

--- Persist floating-button centered grow countdown (/stp button timer).
function Button.SetShowTimer(on)
    local s = SettingsRow()
    if type(s) ~= "table" then
        return IsShowTimer()
    end
    s.craftButtonShowTimer = on == true
    if Button.TickGrowVisuals then
        pcall(Button.TickGrowVisuals)
    end
    return s.craftButtonShowTimer == true
end

function Button.ToggleShowTimer()
    return Button.SetShowTimer(not IsShowTimer())
end

--- Restore defaults: visible, unlocked, scale 1.0, timer on, centered on Root.
--- Recreates the window if it was destroyed / never created.
function Button.ResetToDefaults()
    local s = SettingsRow()
    if type(s) == "table" then
        s.craftButtonVisible = true
        s.craftButtonLockPosition = nil
        s.craftButtonScale = DEFAULT_SCALE
        s.craftButtonShowTimer = true
        s.craftBadgeScale = nil
    end
    if LayoutEditor and type(LayoutEditor.Settings) == "table" then
        LayoutEditor.Settings[WIN] = nil
    end
    local data = LayoutWindowData()
    if type(data) == "table" then
        data.isLocked = false
        data.isUserHidden = false
    end
    if not DoesWindowExist(WIN) then
        _initialized = false
        Button.Initialize()
    elseif _initialized ~= true then
        Button.Initialize()
    end
    if DoesWindowExist(WIN)
        and type(WindowClearAnchors) == "function"
        and type(WindowAddAnchor) == "function"
    then
        WindowClearAnchors(WIN)
        WindowAddAnchor(WIN, "center", "Root", "center", 0, 0)
    end
    if type(WindowSetShowing) == "function" and DoesWindowExist(WIN) then
        WindowSetShowing(WIN, true)
    end
    Button.ApplyScale()
    Button.SyncAppearance()
    -- Unlock drag explicitly (SyncAppearance only sees craftCanUse).
    SetIdleMovable(false)
    if StockPilerTabWatch then
        StockPilerTabWatch._skillGatesKey = nil
        if StockPilerTabWatch.RefreshHudButtonUi then
            pcall(StockPilerTabWatch.RefreshHudButtonUi)
        elseif StockPilerTabWatch.RefreshSkillGates then
            pcall(StockPilerTabWatch.RefreshSkillGates)
        end
    end
    return true
end

--- Match grow countdown text size to /stp button scale (font via WindowSetScale).
local function LayoutGrowTimer()
    if type(DoesWindowExist) ~= "function" or not DoesWindowExist(GROW_TIMER) then
        return
    end
    local scale = Button.GetScale()
    if type(WindowSetDimensions) == "function" then
        WindowSetDimensions(GROW_TIMER, BASE_TIMER_W, BASE_TIMER_H)
    end
    if type(WindowSetScale) == "function" then
        WindowSetScale(GROW_TIMER, scale)
    end
    if type(WindowClearAnchors) == "function" and type(WindowAddAnchor) == "function" then
        WindowClearAnchors(GROW_TIMER)
        WindowAddAnchor(GROW_TIMER, "center", WIN, "center", 0, 0)
    end
end

local function UpdateGrowTimerLabel(remain)
    if type(DoesWindowExist) ~= "function" or not DoesWindowExist(GROW_TIMER) then
        return
    end
    remain = tonumber(remain)
    if IsShowTimer() ~= true or remain == nil or remain <= 0 then
        if type(LabelSetText) == "function" then
            LabelSetText(GROW_TIMER, L"")
        end
        if type(WindowSetShowing) == "function" then
            WindowSetShowing(GROW_TIMER, false)
        end
        return
    end
    LayoutGrowTimer()
    local text = L""
    local Timer = StockPiler.CraftHarvestTimer
    if Timer and Timer.Format then
        text = Timer.Format(remain)
    else
        text = towstring(tostring(math.floor(remain + 0.5)) .. "s")
    end
    if type(LabelSetText) == "function" then
        LabelSetText(GROW_TIMER, text)
    end
    if type(LabelSetTextColor) == "function" then
        LabelSetTextColor(GROW_TIMER, 255, 255, 0)
    end
    if type(WindowSetShowing) == "function" then
        WindowSetShowing(GROW_TIMER, true)
    end
end

--- Arm once; engine animates the wipe. Re-arm only when the timer jumps
--- (new plant / next plot). Re-tinting or SetCooldown every second flickers.
local function ApplyGrowCooldown(remain)
    remain = tonumber(remain)
    if remain == nil or remain <= 0 or type(CooldownDisplaySetCooldown) ~= "function"
        or type(DoesWindowExist) ~= "function" or not DoesWindowExist(CD_WIN)
    then
        ClearGrowCooldown()
        return
    end
    local prev = _cdRemain
    local rearm = _cdArmed ~= true
        or _cdMax <= 0
        or remain > _cdMax
        or (prev ~= nil and remain > prev + 0.7)
    if rearm then
        _cdMax = remain
        _cdRemain = remain
        _cdArmed = true
        StyleGrowCooldown()
        if type(WindowSetShowing) == "function" then
            WindowSetShowing(CD_WIN, true)
        end
        pcall(CooldownDisplaySetCooldown, CD_WIN, remain, _cdMax)
        return
    end
    _cdRemain = remain
end

local function LayoutCooldown(iconSize)
    if type(DoesWindowExist) ~= "function" or not DoesWindowExist(CD_WIN) then
        return
    end
    iconSize = math.max(8, tonumber(iconSize) or 8)
    if type(WindowSetDimensions) == "function" then
        WindowSetDimensions(CD_WIN, iconSize, iconSize)
    end
    if type(WindowClearAnchors) == "function" and type(WindowAddAnchor) == "function" then
        WindowClearAnchors(CD_WIN)
        WindowAddAnchor(CD_WIN, "center", WIN, "center", 0, 0)
    end
end

-- Icon-only pop; frame stays fixed. Cap hover so size + nudge stay in the ring.
local function MotionSpec(scale)
    local frameSize = math.max(16, math.floor(BASE_FRAME * scale + 0.5))
    local idle = math.max(8, math.floor(BASE_ICON * scale + 0.5))
    local press = math.max(8, math.floor(idle * (PRESS_NUM / MOTION_DEN) + 0.5))
    local ring = math.max(0, math.floor((frameSize - idle) / 2))
    local nudge = math.min(math.max(1, math.floor(scale + 0.5)), math.max(0, ring - 1))
    local maxHover = math.max(idle, frameSize - 2 * (nudge + 1))
    local hoverWant = math.max(8, math.floor(idle * (HOVER_NUM / MOTION_DEN) + 0.5))
    local hover = math.max(idle, math.min(hoverWant, maxHover))
    return {
        idle = { size = idle, texScale = idle / BASE_ICON, x = 0, y = 0 },
        hover = { size = hover, texScale = hover / BASE_ICON, x = 0, y = -nudge },
        press = { size = press, texScale = press / BASE_ICON, x = nudge, y = nudge },
        frame = frameSize,
    }
end

local function IsPressVisual()
    return _pressed == true or _macroFlashRemain ~= nil
end

local function ApplyIconMotion()
    if not DoesWindowExist(ICON_WIN) then
        return
    end
    local motion = MotionSpec(Button.GetScale())
    local spec = motion.idle
    if IsPressVisual() then
        spec = motion.press
    elseif _hovering then
        spec = motion.hover
    end
    if type(WindowSetDimensions) == "function" then
        WindowSetDimensions(ICON_WIN, spec.size, spec.size)
    end
    if type(CircleImageSetTextureScale) == "function" then
        CircleImageSetTextureScale(ICON_WIN, spec.texScale)
    end
    if type(WindowClearAnchors) == "function" and type(WindowAddAnchor) == "function" then
        WindowClearAnchors(ICON_WIN)
        WindowAddAnchor(ICON_WIN, "center", WIN, "center", spec.x, spec.y)
    end
    -- Pie stays at idle icon size so hover pop does not resize the wipe.
    LayoutCooldown(motion.idle.size)
end

--- Hotbar Craft macro fired: mirror the HUD press squash briefly (visual only).
function Button.PlayMacroClickFeedback()
    if Button.IsVisible() ~= true or not DoesWindowExist(WIN) then
        return
    end
    _macroFlashRemain = MACRO_FLASH_SEC
    ApplyIconMotion()
end

function Button.TickMacroFlash(timeElapsed)
    if _macroFlashRemain == nil then
        return
    end
    _macroFlashRemain = _macroFlashRemain - (tonumber(timeElapsed) or 0)
    if _macroFlashRemain <= 0 then
        _macroFlashRemain = nil
        ApplyIconMotion()
    end
end

--- EventBus: hotbar Craft macro performed — mirror press on the HUD button.
function Button.OnCraftPerformed(payload)
    if type(payload) == "table" and payload.source == "button" then
        return
    end
    Button.PlayMacroClickFeedback()
end

local function SubscribeCraftPerformed()
    if Button._craftPerformedToken then
        return
    end
    local Bus = StockPiler.EventBus
    local E = StockPiler.Events
    if not Bus or not Bus.Subscribe or not E or not E.CRAFT_PERFORMED then
        return
    end
    Button._craftPerformedToken = Bus.Subscribe(E.CRAFT_PERFORMED, Button.OnCraftPerformed)
end

local function UnsubscribeCraftPerformed()
    local token = Button._craftPerformedToken
    Button._craftPerformedToken = nil
    local Bus = StockPiler.EventBus
    if token and Bus and Bus.Unsubscribe then
        Bus.Unsubscribe(token)
    end
end

function Button.ApplyScale()
    if not DoesWindowExist(WIN) then
        return
    end
    local motion = MotionSpec(Button.GetScale())
    local frameSize = motion.frame
    local frameTex = frameSize / FRAME_SLICE
    if type(WindowSetDimensions) == "function" then
        WindowSetDimensions(WIN, frameSize, frameSize)
        if DoesWindowExist(FRAME_WIN) then
            WindowSetDimensions(FRAME_WIN, frameSize, frameSize)
        end
    end
    if DoesWindowExist(FRAME_WIN) and type(DynamicImageSetTextureScale) == "function" then
        DynamicImageSetTextureScale(FRAME_WIN, frameTex)
    end
    ApplyIconMotion()
    LayoutGrowTimer()
    -- Larger scale can push a near-edge button partly off-screen.
    Button.ClampToScreen()
end

--- Growing harvest pie + lit icon. Brew / ready / idle leave the pie off.
function Button.TickGrowVisuals(opts)
    if not DoesWindowExist(WIN) then
        return
    end
    opts = type(opts) == "table" and opts or {}
    local Macro = StockPiler.Macro
    local snap = opts.snap
    if type(snap) ~= "table" and Macro and Macro.ResolveCraftMode then
        snap = Macro.ResolveCraftMode({
            readonly = true,
            canHarvest = opts.canHarvest,
            canBrew = opts.canBrew,
        })
    end
    if type(snap) ~= "table" then
        snap = { iconMode = "harvest", craftCanUse = false, mode = "idle" }
    end
    local iconMode = (snap.iconMode == "brew") and "brew" or "harvest"
    local canUse = snap.craftCanUse == true
    local Timer = StockPiler.CraftHarvestTimer
    local harvestReady = Timer and Timer.HasHarvestReady and Timer.HasHarvestReady() == true
    local remain = nil
    -- Grow wipe only while plots are still growing and none are ready yet.
    -- When the first plot finishes, drop the pie (ready harvest icon) — do not
    -- re-arm it for remaining plots.
    if iconMode == "harvest" and not canUse and harvestReady ~= true then
        if Timer and Timer.ShortestSeconds then
            remain = Timer.ShortestSeconds()
        end
    end
    local growing = remain ~= nil
    -- User-block: enabled (non-disabled) icon + 75% red tint, same as Craft macro.
    local userStay = Timer and Timer.NeedsUserStay and Timer.NeedsUserStay() == true
    local lit = canUse or harvestReady == true or growing or userStay == true
    local iconId = IconIdForMode(iconMode, canUse or harvestReady == true)
    if _iconMode ~= iconMode or _iconLit ~= lit or _iconId ~= iconId then
        _iconMode = iconMode
        _iconLit = lit
        _iconId = iconId
        SetIconTexture(iconId, lit)
    end
    if Timer and Timer.ApplyWindowBlockTint then
        Timer.ApplyWindowBlockTint(ICON_WIN, userStay == true)
    elseif type(WindowSetTintColor) == "function" and DoesWindowExist(ICON_WIN) then
        local t = (Timer and Timer.BLOCK_TINT) or { r = 218, g = 97, b = 97 }
        if userStay == true then
            WindowSetTintColor(ICON_WIN, t.r, t.g, t.b)
        else
            WindowSetTintColor(ICON_WIN, 255, 255, 255)
        end
    end
    if growing then
        ApplyGrowCooldown(remain)
    else
        ClearGrowCooldown()
    end
    UpdateGrowTimerLabel(remain)
    -- Keep drag lock in sync between full SyncAppearance passes.
    SetIdleMovable(canUse)
end

--- Persist and apply scale (0.25–2.0). Values > 2 are treated as percent (e.g. 50 → 0.5).
function Button.SetScale(raw)
    local n = tonumber(raw)
    if n == nil then
        return false, Button.GetScale()
    end
    if n > MAX_SCALE then
        n = n / 100
    end
    n = ClampScale(n)
    local s = StockPiler.Persistence and StockPiler.Persistence.EnsureSettings and StockPiler.Persistence.EnsureSettings()
    if type(s) == "table" then
        s.craftButtonScale = n
        s.craftBadgeScale = nil
    end
    Button.ApplyScale()
    return true, n
end

--- Bind PERFORM_CRAFTING on this button (same as StockPilerWindowHarvest).
local function SetHarvestGameAction(enabled)
    enabled = enabled == true
    if type(WindowSetGameActionData) ~= "function" or not DoesWindowExist(WIN) then
        return false
    end
    if enabled then
        local cult = GameData and GameData.TradeSkills and GameData.TradeSkills.CULTIVATION or 3
        local action = GameData and GameData.PlayerActions and GameData.PlayerActions.PERFORM_CRAFTING or 8
        local ok = TryCall("CraftButton.BindHarvest", WindowSetGameActionData, WIN, action, cult, L"")
        if type(ButtonSetDisabledFlag) == "function" then
            ButtonSetDisabledFlag(WIN, false)
        end
        return ok == true
    end
    local none = 0
    if GameData and GameData.PlayerActions and GameData.PlayerActions.NONE ~= nil then
        none = GameData.PlayerActions.NONE
    end
    TryCall("CraftButton.ClearHarvest", WindowSetGameActionData, WIN, none, 0, L"")
    return true
end

function Button.SyncAppearance(opts)
    if not DoesWindowExist(WIN) then
        return
    end
    opts = type(opts) == "table" and opts or {}
    local Macro = StockPiler.Macro
    local snap = opts.snap
    if type(snap) ~= "table" and Macro and Macro.ResolveCraftMode then
        snap = Macro.ResolveCraftMode({
            readonly = true,
            canHarvest = opts.canHarvest,
            canBrew = opts.canBrew,
        })
    end
    if type(snap) ~= "table" then
        snap = { iconMode = "harvest", craftCanUse = false, mode = "idle" }
    end
    local canUse = snap.craftCanUse == true
    local mode = snap.mode or "idle"
    _mode = mode
    opts.snap = snap
    Button.TickGrowVisuals(opts)
    SetHarvestGameAction(mode == "harvest" and canUse)
    SetIdleMovable(canUse)
    if type(ButtonSetDisabledFlag) == "function" then
        ButtonSetDisabledFlag(WIN, false)
    end
    if type(WindowSetHandleInput) == "function" then
        WindowSetHandleInput(WIN, true)
    end
    if type(WindowSetAlpha) == "function" then
        WindowSetAlpha(WIN, 1)
    end
    Button.ApplyScale()
end

local function PlayClick(soundId)
    if soundId and Sound and Sound.Play then
        Sound.Play(soundId)
    end
end

local function HideCraftTip()
    local tip = StockPiler.CraftTooltip
    if tip and tip.ClearLive then
        tip.ClearLive()
    end
    if Tooltips and type(Tooltips.ClearTooltip) == "function" then
        Tooltips.ClearTooltip()
    end
end

function Button.IsTipSuppressed()
    if _tipSuppressed == true then
        return true
    end
    if type(WindowGetMoving) == "function" and DoesWindowExist(WIN) then
        return WindowGetMoving(WIN) == true
    end
    return false
end

local function IsShiftFlags(flags)
    if SystemData and SystemData.ButtonFlags and SystemData.ButtonFlags.SHIFT then
        if flags == SystemData.ButtonFlags.SHIFT then
            return true
        end
        if type(flags) == "number" and flags ~= 0 and bit and bit.band then
            return bit.band(flags, SystemData.ButtonFlags.SHIFT) ~= 0
        end
    end
    return false
end

--- Same chat path as Watch setting toggles (honors chat on/quiet/off).
local function NotifyHudLock(on)
    local state = on and T("boot.on") or T("boot.off")
    local msg = T("watch.hud_lock", { state = state })
    if StockPiler.Ui and StockPiler.Ui.Print then
        StockPiler.Ui.Print(msg)
    elseif StockPiler.Debug and StockPiler.Debug.Reply then
        StockPiler.Debug.Reply(msg)
    end
end

local function ToggleLockFromUser()
    local on = Button.IsLocked() ~= true
    Button.SetLocked(on)
    NotifyHudLock(on)
    return on
end

--- Same as StockPilerWindow.OnHarvestPrepare: select plot before the game action fires.
--- Shift+LMB toggles Layout Editor lock (no craft / no drag).
function Button.OnLButtonDown(flags)
    _pressed = true
    ApplyIconMotion()
    -- Distinct press: icon pickup (303). Release uses icon drop (304).
    PlayClick(Sound and Sound.ICON_PICKUP)
    if IsShiftFlags(flags) then
        -- Clear any harvest game-action so the engine does not fire it.
        SetHarvestGameAction(false)
        ToggleLockFromUser()
        _shiftLockClick = true
        _tipSuppressed = true
        HideCraftTip()
        return
    end
    _shiftLockClick = false
    local Macro = StockPiler.Macro
    local snap = Macro and Macro.ResolveCraftMode and Macro.ResolveCraftMode() or nil
    local mode = type(snap) == "table" and snap.mode or _mode
    local canUse = type(snap) == "table" and snap.craftCanUse == true
    if mode == "harvest" and canUse then
        SetHarvestGameAction(true)
        local Grow = StockPiler.Grow
        if Grow and Grow.PrepareHarvestPlot then
            local prepared = Grow.PrepareHarvestPlot(true) == true
            if prepared and Sound and Sound.CULTIVATING_HARVEST_CROP then
                PlayClick(Sound.CULTIVATING_HARVEST_CROP)
            end
        end
        return
    end
    SetHarvestGameAction(false)
    -- Idle press may become a drag; hide tip so TipAnchor does not flicker.
    if canUse ~= true then
        _tipSuppressed = true
        HideCraftTip()
    end
end

--- Harvest: engine gameactionbutton. Brew: CraftClick.
function Button.OnLButtonUp(flags)
    local wasShiftLock = _shiftLockClick == true
    if wasShiftLock ~= true and IsShiftFlags(flags) then
        -- Shift only seen on up (some clients): still toggle, skip craft.
        SetHarvestGameAction(false)
        ToggleLockFromUser()
        wasShiftLock = true
    end
    _shiftLockClick = false
    _pressed = false
    _tipSuppressed = false
    ApplyIconMotion()
    PlayClick(Sound and Sound.ICON_DROP)
    -- End of idle drag (and any LE nudge): never leave the button clipped.
    Button.ClampToScreen()
    if wasShiftLock then
        return
    end
    local Macro = StockPiler.Macro
    local snap = Macro and Macro.ResolveCraftMode and Macro.ResolveCraftMode() or nil
    local mode = type(snap) == "table" and snap.mode or _mode
    local canUse = type(snap) == "table" and snap.craftCanUse == true
    if mode == "brew" and canUse and Macro and Macro.CraftClick then
        Macro.CraftClick({ fromButton = true })
    elseif _hovering == true and canUse ~= true then
        local tip = StockPiler.CraftTooltip
        if tip and tip.Show and Button.IsTipSuppressed() ~= true then
            tip.Show(WIN, Button.TipAnchor(WIN))
        end
    end
end

function Button.OnRButtonUp()
    if StockPiler.Ui and StockPiler.Ui.ToggleWindow then
        StockPiler.Ui.ToggleWindow()
    end
end

-- Tip beside the button. Point = button corner, RelativePoint = tip corner
-- (stock Tooltips.ANCHOR_* table convention). Prefer right+down.
local TIP_GAP = 4
local TIP_RIGHT_DOWN = {
    Point = "topright", RelativeTo = "", RelativePoint = "topleft",
    XOffset = TIP_GAP, YOffset = 0,
}
local TIP_RIGHT_UP = {
    Point = "bottomright", RelativeTo = "", RelativePoint = "bottomleft",
    XOffset = TIP_GAP, YOffset = 0,
}
local TIP_LEFT_DOWN = {
    Point = "topleft", RelativeTo = "", RelativePoint = "topright",
    XOffset = -TIP_GAP, YOffset = 0,
}
local TIP_LEFT_UP = {
    Point = "bottomleft", RelativeTo = "", RelativePoint = "bottomright",
    XOffset = -TIP_GAP, YOffset = 0,
}

function Button.TipAnchor(win)
    win = win or WIN
    if type(DoesWindowExist) ~= "function" or not DoesWindowExist(win) then
        return TIP_RIGHT_DOWN
    end
    local x, y = WindowGetScreenPosition(win)
    local w, h = WindowGetDimensions(win)
    local sw, sh = WindowGetDimensions("Root")
    x = tonumber(x) or 0
    y = tonumber(y) or 0
    w = tonumber(w) or 0
    h = tonumber(h) or 0
    sw = tonumber(sw) or 0
    sh = tonumber(sh) or 0
    -- Screen positions are scaled; dimensions are not (same as stock tooltips).
    local uiScale = 1
    if InterfaceCore and InterfaceCore.GetScale then
        uiScale = tonumber(InterfaceCore.GetScale()) or 1
        if uiScale == 0 then
            uiScale = 1
        end
    end
    x = x / uiScale
    y = y / uiScale
    local goLeft = (sw - (x + w)) < x
    local goUp = (sh - (y + h)) < y
    if goLeft and goUp then
        return TIP_LEFT_UP
    elseif goLeft then
        return TIP_LEFT_DOWN
    elseif goUp then
        return TIP_RIGHT_UP
    end
    return TIP_RIGHT_DOWN
end

function Button.OnMouseOver()
    _hovering = true
    if not _pressed then
        ApplyIconMotion()
    end
    if Button.IsTipSuppressed() == true then
        return
    end
    local tip = StockPiler.CraftTooltip
    if tip and tip.Show then
        tip.Show(WIN, Button.TipAnchor(WIN))
    end
end

function Button.OnMouseOverEnd()
    _hovering = false
    _pressed = false
    _tipSuppressed = false
    ApplyIconMotion()
end

function Button.Initialize()
    if _initialized then
        SubscribeCraftPerformed()
        Button.ApplyVisibility()
        return
    end
    -- Drop legacy CraftBadge window if a prior build left it around.
    if DoesWindowExist("StockPilerCraftBadge") then
        if LayoutEditor and LayoutEditor.UnregisterWindow then
            pcall(LayoutEditor.UnregisterWindow, "StockPilerCraftBadge")
        end
        if type(DestroyWindow) == "function" then
            pcall(DestroyWindow, "StockPilerCraftBadge")
        end
    end
    if not DoesWindowExist(WIN) then
        CreateWindow(WIN, true)
    end
    if type(WindowSetHandleInput) == "function" then
        WindowSetHandleInput(WIN, true)
    end
    if type(ButtonSetDisabledFlag) == "function" then
        ButtonSetDisabledFlag(WIN, false)
    end
    if LayoutEditor and LayoutEditor.RegisterWindow then
        LayoutEditor.RegisterWindow(
            WIN,
            T("button.layout_name"),
            T("button.layout_desc"),
            false,
            false,
            true,
            nil, -- setHiddenCallback
            nil, -- allowableAnchorList
            nil, -- neverLockAspect
            nil, -- minSize
            nil, -- resizeEndCallback
            Button.ClampToScreen -- moveEndCallback
        )
    end
    -- One-shot: old SP lock → LayoutEditor.isLocked (same as HUD Editor lock).
    do
        local s = SettingsRow()
        if type(s) == "table" and s.craftButtonLockPosition == true then
            Button.SetLocked(true)
            s.craftButtonLockPosition = nil
        end
    end
    _initialized = true
    _iconMode = nil
    _iconLit = nil
    _iconId = nil
    _mode = "idle"
    _hovering = false
    _pressed = false
    _macroFlashRemain = nil
    ClearGrowCooldown()
    StyleGrowCooldown()
    UpdateGrowTimerLabel(nil)
    SubscribeCraftPerformed()
    Button.ApplyVisibility()
    -- Saved / LE position may be partly off-screen from older builds.
    Button.ClampToScreen()
end

function Button.Shutdown()
    SetHarvestGameAction(false)
    ClearGrowCooldown()
    UpdateGrowTimerLabel(nil)
    _hovering = false
    _pressed = false
    _macroFlashRemain = nil
    UnsubscribeCraftPerformed()
    if LayoutEditor and LayoutEditor.UnregisterWindow and DoesWindowExist(WIN) then
        pcall(LayoutEditor.UnregisterWindow, WIN)
    end
    _initialized = false
end
