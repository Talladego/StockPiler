----------------------------------------------------------------
-- StockPiler View/CraftButton - floating round craft HUD
-- Fixed (Layout Editor). Harvest: footer-style Prepare + gameactionbutton.
-- Brew: Macro.CraftClick on Up. RMB: toggle. Scale via /stp button.
----------------------------------------------------------------

StockPiler = StockPiler or {}
StockPiler.CraftButton = StockPiler.CraftButton or {}
local Button = StockPiler.CraftButton

local WIN = "StockPilerCraftButton"
local ICON_WIN = "StockPilerCraftButtonIcon"
local FRAME_WIN = "StockPilerCraftButtonFrame"
Button.WINDOW_NAME = WIN
local ICON_HARVEST = 2486
local ICON_BREW = 10985

-- 100% layout (native icon + fitted frame). Runtime sizes = base * scale.
local BASE_FRAME = 92
local BASE_ICON = 64
local FRAME_SLICE = 128
local DEFAULT_SCALE = 0.5
local MIN_SCALE = 0.25
local MAX_SCALE = 2.0
-- Icon-only hover/press vs idle size (48 = idle baseline).
local HOVER_NUM = 50
local PRESS_NUM = 44
local MOTION_DEN = 48

local _initialized = false
local _iconMode = nil
local _canUse = nil
local _mode = "idle"
local _hovering = false
local _pressed = false

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

local function IconIdForMode(iconMode)
    if iconMode == "brew" then
        return ICON_BREW
    end
    return ICON_HARVEST
end

local function SetIconTexture(iconNum, canUse)
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
    if canUse ~= true and disabledTexture and disabledTexture ~= "" then
        texture = disabledTexture
    end
    CircleImageSetTexture(ICON_WIN, texture, (x or 0) + 32, (y or 0) + 32)
    WindowSetShowing(ICON_WIN, true)
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

local function ApplyIconMotion()
    if not DoesWindowExist(ICON_WIN) then
        return
    end
    local motion = MotionSpec(Button.GetScale())
    local spec = motion.idle
    if _pressed then
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
    local iconMode = (snap.iconMode == "brew") and "brew" or "harvest"
    local canUse = snap.craftCanUse == true
    local mode = snap.mode or "idle"
    _mode = mode
    if _iconMode ~= iconMode or _canUse ~= canUse then
        _iconMode = iconMode
        _canUse = canUse
        SetIconTexture(IconIdForMode(iconMode), canUse)
    end
    SetHarvestGameAction(mode == "harvest" and canUse)
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

--- Same as StockPilerWindow.OnHarvestPrepare: select plot before the game action fires.
function Button.OnLButtonDown()
    _pressed = true
    ApplyIconMotion()
    -- Distinct press: icon pickup (303). Release uses icon drop (304).
    PlayClick(Sound and Sound.ICON_PICKUP)
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
end

--- Harvest: engine gameactionbutton. Brew: CraftClick.
function Button.OnLButtonUp()
    _pressed = false
    ApplyIconMotion()
    PlayClick(Sound and Sound.ICON_DROP)
    local Macro = StockPiler.Macro
    local snap = Macro and Macro.ResolveCraftMode and Macro.ResolveCraftMode() or nil
    local mode = type(snap) == "table" and snap.mode or _mode
    local canUse = type(snap) == "table" and snap.craftCanUse == true
    if mode == "brew" and canUse and Macro and Macro.CraftClick then
        Macro.CraftClick()
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
    local tip = StockPiler.CraftTooltip
    if tip and tip.Show then
        tip.Show(WIN, Button.TipAnchor(WIN))
    end
end

function Button.OnMouseOverEnd()
    _hovering = false
    _pressed = false
    ApplyIconMotion()
end

function Button.Initialize()
    if _initialized then
        Button.SyncAppearance()
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
    else
        WindowSetShowing(WIN, true)
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
            nil
        )
    end
    _initialized = true
    _iconMode = nil
    _canUse = nil
    _mode = "idle"
    _hovering = false
    _pressed = false
    Button.SyncAppearance()
end

function Button.Shutdown()
    SetHarvestGameAction(false)
    _hovering = false
    _pressed = false
    if LayoutEditor and LayoutEditor.UnregisterWindow and DoesWindowExist(WIN) then
        pcall(LayoutEditor.UnregisterWindow, WIN)
    end
    _initialized = false
end
