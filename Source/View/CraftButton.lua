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
local MIN_SCALE = 0.5
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
    -- NaN fails every ordered compare and must not be stored.
    if n == nil or n ~= n then
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

--- lit=false -> disabled texture (idle only). Growing uses lit harvest + pie.
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

local function WindowScaleOf(name)
    local s = 1
    if type(WindowGetScale) == "function" then
        s = tonumber(WindowGetScale(name)) or 1
        if s == 0 then
            s = 1
        end
    end
    return s
end

--- Anchor-offset units per layout unit. Layout Editor writes offsets as
--- screen pixels / WindowGetScale(parent). Dividing screen position by
--- InterfaceCore.GetScale() is the layout unit, so the ratio converts a
--- layout-unit nudge into that offset space. When the parent scale matches
--- the interface scale the ratio is 1 (same units the old topleft clamp used).
local function OffsetPerLayoutUnit()
    local ui = UiScale()
    local parentScale = ui
    if type(WindowGetParent) == "function" and type(WindowGetScale) == "function" then
        local parent = WindowGetParent(WIN)
        if type(parent) == "wstring" and type(WStringToString) == "function" then
            local ok, text = pcall(WStringToString, parent)
            if ok and type(text) == "string" then
                parent = text
            end
        end
        if type(parent) == "string" and parent ~= "" then
            local ps = tonumber(WindowGetScale(parent)) or 0
            if ps ~= 0 then
                parentScale = ps
            end
        end
    end
    if parentScale == 0 then
        return 1
    end
    return ui / parentScale
end

-- Reused while a drag sits on the screen edge. Not allocated per frame.
local anchorScratch = {}

--- Move the window by a layout-unit delta without changing which points
--- Layout Editor saved. One source of truth: the window anchors (savesettings
--- plus Layout Editor). StockPiler does not keep a second x/y.
local function NudgeAnchors(dx, dy)
    dx = tonumber(dx) or 0
    dy = tonumber(dy) or 0
    if type(WindowGetAnchorCount) ~= "function" or type(WindowGetAnchor) ~= "function" then
        return false
    end
    local count = tonumber(WindowGetAnchorCount(WIN)) or 0
    if count < 1 then
        return false
    end
    for i = 1, count do
        -- point, relativePoint, relativeTo, x, y (RoR WindowGetAnchor order).
        local point, relativePoint, relativeTo, x, y = WindowGetAnchor(WIN, i)
        if point == nil or relativeTo == nil or relativePoint == nil then
            return false
        end
        local slot = anchorScratch[i]
        if slot == nil then
            slot = {}
            anchorScratch[i] = slot
        end
        slot.point = point
        slot.relativePoint = relativePoint
        slot.relativeTo = relativeTo
        slot.x = (tonumber(x) or 0) + dx
        slot.y = (tonumber(y) or 0) + dy
    end
    WindowClearAnchors(WIN)
    for i = 1, count do
        local slot = anchorScratch[i]
        WindowAddAnchor(WIN, slot.point, slot.relativeTo, slot.relativePoint, slot.x, slot.y)
    end
    return true
end

--- Screen position divided by InterfaceCore.GetScale() is a layout unit.
--- WindowGetScale is absolute (it already includes that UI scale), so the
--- on-screen size in the same units is dimensions * WindowGetScale / uiScale.
--- Same split as LayoutFrame:Attach (width * scale / uiScale).
local function LayoutRect()
    local uiScale = UiScale()
    local winScale = WindowScaleOf(WIN)
    local sx, sy = WindowGetScreenPosition(WIN)
    sx = (tonumber(sx) or 0) / uiScale
    sy = (tonumber(sy) or 0) / uiScale
    local dw, dh = WindowGetDimensions(WIN)
    local w = (tonumber(dw) or 0) * winScale / uiScale
    local h = (tonumber(dh) or 0) * winScale / uiScale
    local sw, sh = WindowGetDimensions("Root")
    sw = tonumber(sw) or 0
    sh = tonumber(sh) or 0
    return sx, sy, w, h, sw, sh
end

--- Stock Layout Editor has no UpdateWindowSize. While it is open, the outline
--- is the LayoutFrame from GetFrameForSourceWindow plus the active control
--- frame (layout size + 2*OFFSET, same as CopySize_LayoutToControls).
local function SyncLayoutEditorChrome()
    if not LayoutEditor or LayoutEditor.isActive ~= true then
        return
    end
    if type(LayoutEditor.windowsList) ~= "table" or LayoutEditor.windowsList[WIN] == nil then
        return
    end
    if type(LayoutEditor.framesList) ~= "table" then
        return
    end
    if type(LayoutEditor.GetFrameForSourceWindow) ~= "function" then
        return
    end
    local frame = LayoutEditor.GetFrameForSourceWindow(WIN)
    if type(frame) ~= "table" or type(frame.SetDimensions) ~= "function" then
        return
    end
    local _, _, w, h = LayoutRect()
    if w <= 0 or h <= 0 then
        return
    end
    frame:SetDimensions(w, h)
    if type(frame.UpdateScreenRect) == "function" then
        frame:UpdateScreenRect()
    end
    local controls = LayoutEditor.controlFramesList
    if type(controls) ~= "table" then
        return
    end
    local offset = 25
    if LayoutControlFrame and tonumber(LayoutControlFrame.OFFSET) then
        offset = LayoutControlFrame.OFFSET
    end
    for _, control in pairs(controls) do
        if type(control) == "table"
            and type(control.GetActiveFrame) == "function"
            and control:GetActiveFrame() == frame
        then
            if LayoutEditorUtils and type(LayoutEditorUtils.CopySize) == "function" then
                LayoutEditorUtils.CopySize(frame, control, 2 * offset, 2 * offset, false)
            elseif type(control.SetDimensions) == "function" then
                control:SetDimensions(w + 2 * offset, h + 2 * offset)
            end
            break
        end
    end
end

--- Keep the whole button on-screen. In-bounds does not touch anchors, so a
--- Layout Editor point is left alone. Returns true when the position changed.
function Button.ClampToScreen()
    -- While the editor is up the button is anchored to the editor frame.
    -- Rewriting that anchor detaches it. EDITING_END clamps after detach.
    if LayoutEditor and LayoutEditor.isActive == true then
        return false
    end
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
    local moved = false
    local prevErr = nil
    -- One nudge can undershoot when the parent scale and the interface scale
    -- differ. Re-read after the anchors process and repeat until the error
    -- is under half a layout unit. Stop if a pass does not get closer.
    for _ = 1, 8 do
        local sx, sy, w, h, sw, sh = LayoutRect()
        if sw <= 0 or sh <= 0 or w <= 0 or h <= 0 then
            break
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
        local dx = cx - sx
        local dy = cy - sy
        local err = math.abs(dx) + math.abs(dy)
        if err < 0.5 then
            break
        end
        if prevErr ~= nil and err >= prevErr - 0.01 then
            break
        end
        prevErr = err
        local per = OffsetPerLayoutUnit()
        local nudged = NudgeAnchors(dx * per, dy * per)
        if not nudged then
            WindowClearAnchors(WIN)
            WindowAddAnchor(WIN, "topleft", "Root", "topleft", cx, cy)
        end
        moved = true
        if type(WindowForceProcessAnchors) == "function" then
            WindowForceProcessAnchors(WIN)
        end
        if not nudged then
            break
        end
        if type(WindowForceProcessAnchors) ~= "function" then
            -- Without a fresh screen position the next pass would stack the
            -- same delta. One nudge is the best we can do.
            break
        end
    end
    if moved then
        SyncLayoutEditorChrome()
    end
    return moved
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

function Button.IsWindowShowing()
    if type(DoesWindowExist) ~= "function" or not DoesWindowExist(WIN) then
        return false
    end
    if type(WindowGetShowing) == "function" then
        return WindowGetShowing(WIN) == true
    end
    return true
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

--- WindowSetScale is absolute and already includes UI scale. A child does not
--- inherit its parent, so each visual piece must use the root's scale or the
--- art stays at 1 while the hit box grows.
local function MatchRootScale(childName)
    if type(WindowSetScale) ~= "function" then
        return
    end
    if type(DoesWindowExist) == "function" and not DoesWindowExist(childName) then
        return
    end
    WindowSetScale(childName, WindowScaleOf(WIN))
end

--- Pin a visual child to the button root and give it the root's absolute scale.
local function AnchorChildCenter(childName)
    if type(DoesWindowExist) ~= "function" or not DoesWindowExist(childName) then
        return
    end
    MatchRootScale(childName)
    if type(WindowClearAnchors) == "function" and type(WindowAddAnchor) == "function" then
        WindowClearAnchors(childName)
        WindowAddAnchor(childName, "center", WIN, "center", 0, 0)
    end
end

--- Countdown stays inside the root. Scale matches the root; it is not 1.
local function LayoutGrowTimer()
    if type(DoesWindowExist) ~= "function" or not DoesWindowExist(GROW_TIMER) then
        return
    end
    if type(WindowSetDimensions) == "function" then
        WindowSetDimensions(GROW_TIMER, BASE_TIMER_W, BASE_TIMER_H)
    end
    AnchorChildCenter(GROW_TIMER)
end

local _growTimerScale = nil

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
    -- Re-anchor only when the absolute scale changes, not every countdown tick.
    local absScale = WindowScaleOf(WIN)
    if _growTimerScale ~= absScale then
        LayoutGrowTimer()
        _growTimerScale = absScale
    end
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
    MatchRootScale(CD_WIN)
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
    -- Sizes are in the root's unscaled space. MatchRootScale grows the art
    -- with the hit box (child scale does not multiply the parent).
    local motion = MotionSpec(1)
    local spec = motion.idle
    if IsPressVisual() then
        spec = motion.press
    elseif _hovering then
        spec = motion.hover
    end
    MatchRootScale(ICON_WIN)
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

--- EventBus: hotbar Craft macro performed - mirror press on the HUD button.
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
    local scale = Button.GetScale()
    -- WindowSetScale is absolute and already includes InterfaceCore.GetScale.
    -- craftButtonScale is the 0.50-2.00 multiplier on top of that.
    if type(WindowSetDimensions) == "function" then
        WindowSetDimensions(WIN, BASE_FRAME, BASE_FRAME)
        if DoesWindowExist(FRAME_WIN) then
            WindowSetDimensions(FRAME_WIN, BASE_FRAME, BASE_FRAME)
        end
    end
    if type(WindowSetScale) == "function" then
        WindowSetScale(WIN, scale * UiScale())
    end
    if DoesWindowExist(FRAME_WIN) and type(DynamicImageSetTextureScale) == "function" then
        DynamicImageSetTextureScale(FRAME_WIN, BASE_FRAME / FRAME_SLICE)
    end
    AnchorChildCenter(FRAME_WIN)
    ApplyIconMotion()
    LayoutGrowTimer()
    _growTimerScale = WindowScaleOf(WIN)
    if DoesWindowExist(CD_TIMER) then
        MatchRootScale(CD_TIMER)
    end
    -- Larger scale can push a near-edge button partly off-screen.
    Button.ClampToScreen()
    SyncLayoutEditorChrome()
end

--- Growing harvest pie + lit icon. Brew / ready / idle leave the pie off.
function Button.TickGrowVisuals(opts)
    if not DoesWindowExist(WIN) then
        return
    end
    -- Hidden HUD has nothing to paint. ApplyVisibility calls SyncAppearance after show.
    if type(WindowGetShowing) == "function" and WindowGetShowing(WIN) ~= true then
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
    -- When the first plot finishes, drop the pie (ready harvest icon) - do not
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

--- Persist and apply scale.
--- 0.50-2.00 is used as-is. Above 0 and below 0.50, or above 2.00 through 10,
--- clamps to 0.50/2.00. Above 10 up to 200 is a percent (then clamped).
--- asPercent (a % in /stp button) always divides by 100 first.
--- NaN and anything else is rejected and does not change the saved scale.
--- Third return is true when the accepted value was clamped into range.
function Button.SetScale(raw, asPercent)
    local n = tonumber(raw)
    if n == nil or n ~= n or n <= 0 or n > 200 then
        return false, Button.GetScale(), false
    end
    local clamped = false
    if asPercent == true or n > 10 then
        n = n / 100
    end
    if n < MIN_SCALE or n > MAX_SCALE then
        clamped = true
        n = ClampScale(n)
    end
    local s = StockPiler.Persistence and StockPiler.Persistence.EnsureSettings and StockPiler.Persistence.EnsureSettings()
    if type(s) == "table" then
        s.craftButtonScale = n
        s.craftBadgeScale = nil
    end
    Button.ApplyScale()
    return true, n, clamped
end

--- Layout Editor corner resize writes an absolute WindowSetScale (UI scale
--- included). Edge handles write dimensions. Fold both into craftButtonScale
--- and put the square button back. Do not reanchor: the button is still
--- attached to the editor frame.
local function ReadEditorCraftScale()
    local dw = BASE_FRAME
    if type(WindowGetDimensions) == "function" then
        dw = tonumber(WindowGetDimensions(WIN)) or BASE_FRAME
    end
    local ui = UiScale()
    return ClampScale((dw * WindowScaleOf(WIN)) / BASE_FRAME / ui)
end

function Button.OnLayoutResizeEnd()
    if type(DoesWindowExist) ~= "function" or not DoesWindowExist(WIN) then
        return
    end
    local n = ReadEditorCraftScale()
    if type(WindowSetDimensions) == "function" then
        WindowSetDimensions(WIN, BASE_FRAME, BASE_FRAME)
    end
    if type(WindowSetScale) == "function" then
        WindowSetScale(WIN, n * UiScale())
    end
    local s = SettingsRow()
    if type(s) == "table" then
        s.craftButtonScale = n
        s.craftBadgeScale = nil
    end
    AnchorChildCenter(FRAME_WIN)
    ApplyIconMotion()
    LayoutGrowTimer()
    _growTimerScale = WindowScaleOf(WIN)
    if DoesWindowExist(CD_TIMER) then
        MatchRootScale(CD_TIMER)
    end
    SyncLayoutEditorChrome()
end

--- Editor closed and Detach has anchored the button to Root again.
--- Divide the absolute scale back out so UI scale is not saved.
function Button.OnLayoutEditingEnd()
    if type(DoesWindowExist) ~= "function" or not DoesWindowExist(WIN) then
        return
    end
    local n = ReadEditorCraftScale()
    local s = SettingsRow()
    if type(s) == "table" then
        s.craftButtonScale = n
        s.craftBadgeScale = nil
    end
    Button.ApplyScale()
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
    if type(WindowGetShowing) == "function" and WindowGetShowing(WIN) ~= true then
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
        -- Width and height on, aspect locked: the editor resizes via
        -- WindowSetScale (same knob as /stp button). Position stays the
        -- window anchors; move end only clamps when the editor is closed.
        LayoutEditor.RegisterWindow(
            WIN,
            T("button.layout_name"),
            T("button.layout_desc"),
            true,
            true,
            true,
            nil, -- setHiddenCallback
            nil, -- allowableAnchorList
            false, -- neverLockAspect
            { x = BASE_FRAME * MIN_SCALE, y = BASE_FRAME * MIN_SCALE },
            Button.OnLayoutResizeEnd,
            Button.ClampToScreen
        )
    end
    if LayoutEditor and LayoutEditor.RegisterEditCallback and Button._layoutEditHooked ~= true then
        LayoutEditor.RegisterEditCallback(function(code)
            local ending = LayoutEditor.EDITING_END
            if ending ~= nil and code == ending then
                Button.OnLayoutEditingEnd()
            end
        end)
        Button._layoutEditHooked = true
    end
    -- Drop a legacy lock flag without locking. New installs and upgrades
    -- start movable; Shift+click / the editor lock still works after that.
    do
        local s = SettingsRow()
        if type(s) == "table" and s.craftButtonLockPosition ~= nil then
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
