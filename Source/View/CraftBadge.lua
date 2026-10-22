----------------------------------------------------------------
-- StockPiler View/CraftBadge - floating round craft HUD
-- LMB: Macro.CraftClick (harvest/brew). RMB: toggle main window.
----------------------------------------------------------------

StockPiler = StockPiler or {}
StockPiler.CraftBadge = StockPiler.CraftBadge or {}
local Badge = StockPiler.CraftBadge

local WIN = "StockPilerCraftBadge"
local ICON_WIN = "StockPilerCraftBadgeIcon"
local ICON_HARVEST = 2486
local ICON_BREW = 10985
local READY_ALPHA = 1
local IDLE_ALPHA = 0.45
local DRAG_SLOP = 6

local _initialized = false
local _downX = nil
local _downY = nil
local _iconMode = nil
local _canUse = nil

local function T(key, tokens)
    if StockPiler.Util and StockPiler.Util.T then
        return StockPiler.Util.T(key, tokens)
    end
    return L""
end

local function IconIdForMode(iconMode)
    if iconMode == "brew" then
        return ICON_BREW
    end
    return ICON_HARVEST
end

local function SetIconTexture(iconNum)
    if not DoesWindowExist(ICON_WIN) then
        return
    end
    if StockPiler.ViewList and StockPiler.ViewList.SetIconTexture then
        StockPiler.ViewList.SetIconTexture(ICON_WIN, iconNum, 1)
        return
    end
    if iconNum and iconNum > 0 and type(GetIconData) == "function" then
        local ok, texture, x, y = false, nil, 0, 0
        if StockPiler.Util and StockPiler.Util.TryCallQuiet then
            ok, texture, x, y = StockPiler.Util.TryCallQuiet("GetIconData", GetIconData, iconNum)
        else
            ok, texture, x, y = pcall(GetIconData, iconNum)
        end
        if ok and texture and texture ~= "" then
            DynamicImageSetTexture(ICON_WIN, texture, x or 0, y or 0)
            if type(DynamicImageSetTextureScale) == "function" then
                DynamicImageSetTextureScale(ICON_WIN, 1)
            end
            WindowSetShowing(ICON_WIN, true)
            return
        end
    end
    DynamicImageSetTexture(ICON_WIN, "", 0, 0)
end

local function SetBadgeAlpha(alpha)
    alpha = tonumber(alpha) or READY_ALPHA
    if type(WindowSetAlpha) == "function" and DoesWindowExist(WIN) then
        WindowSetAlpha(WIN, alpha)
    end
    if type(WindowSetFontAlpha) == "function" and DoesWindowExist(WIN) then
        WindowSetFontAlpha(WIN, alpha)
    end
end

local function ScreenPos()
    if type(WindowGetScreenPosition) ~= "function" or not DoesWindowExist(WIN) then
        return nil, nil
    end
    local ok, x, y = pcall(WindowGetScreenPosition, WIN)
    if ok then
        return tonumber(x), tonumber(y)
    end
    return nil, nil
end

local function MovedPastSlop()
    if _downX == nil or _downY == nil then
        return false
    end
    local x, y = ScreenPos()
    if x == nil or y == nil then
        return false
    end
    local dx = x - _downX
    local dy = y - _downY
    return (dx * dx + dy * dy) >= (DRAG_SLOP * DRAG_SLOP)
end

function Badge.SyncAppearance(opts)
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
        snap = { iconMode = "harvest", craftCanUse = false }
    end
    local iconMode = (snap.iconMode == "brew") and "brew" or "harvest"
    local canUse = snap.craftCanUse == true
    if _iconMode ~= iconMode then
        _iconMode = iconMode
        SetIconTexture(IconIdForMode(iconMode))
    end
    if _canUse ~= canUse then
        _canUse = canUse
        SetBadgeAlpha(canUse and READY_ALPHA or IDLE_ALPHA)
    end
end

function Badge.OnLButtonDown()
    _downX, _downY = ScreenPos()
end

function Badge.OnLButtonUp()
    if MovedPastSlop() then
        _downX, _downY = nil, nil
        return
    end
    _downX, _downY = nil, nil
    local Macro = StockPiler.Macro
    if Macro and Macro.CraftClick then
        Macro.CraftClick()
    end
end

function Badge.OnRButtonUp()
    if StockPiler.Ui and StockPiler.Ui.ToggleWindow then
        StockPiler.Ui.ToggleWindow()
    end
end

function Badge.OnMouseOver()
    local tip = StockPiler.CraftTooltip
    if tip and tip.Show then
        tip.Show(WIN, Tooltips and Tooltips.ANCHOR_WINDOW_TOP)
    end
end

function Badge.Initialize()
    if _initialized then
        Badge.SyncAppearance()
        return
    end
    if not DoesWindowExist(WIN) then
        CreateWindow(WIN, true)
    else
        WindowSetShowing(WIN, true)
    end
    if LayoutEditor and LayoutEditor.RegisterWindow then
        LayoutEditor.RegisterWindow(
            WIN,
            T("badge.layout_name"),
            T("badge.layout_desc"),
            false,
            false,
            true,
            nil
        )
    end
    _initialized = true
    _iconMode = nil
    _canUse = nil
    Badge.SyncAppearance()
end

function Badge.Shutdown()
    if LayoutEditor and LayoutEditor.UnregisterWindow and DoesWindowExist(WIN) then
        pcall(LayoutEditor.UnregisterWindow, WIN)
    end
    _initialized = false
end
