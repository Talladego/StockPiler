----------------------------------------------------------------
-- StockPiler HarvestChrome -- footer PERFORM_CRAFTING bind (ready transitions only)
----------------------------------------------------------------

StockPiler = StockPiler or {}
StockPiler.HarvestChrome = StockPiler.HarvestChrome or {}
local HarvestChrome = StockPiler.HarvestChrome

local HARVEST_WIN = "StockPilerWindowHarvest"
local HARVEST_ACTION_WIN = "StockPilerWindowHarvestAction"

local function T(key, tokens)
    return StockPiler.Util.T(key, tokens)
end

local function TryCall(context, fn, ...)
    return StockPiler.Util.TryCall(context, fn, ...)
end

local function RestoreHarvestChrome(windowName)
    if windowName == nil or windowName == "" or not DoesWindowExist(windowName) then
        return
    end
    if ButtonSetText then
        ButtonSetText(windowName, T("ui.harvest"))
    end
    if ButtonSetPressedFlag then
        ButtonSetPressedFlag(windowName, false)
    end
end

local function BindCultivationHarvestAction(windowName)
    if WindowSetGameActionData == nil or windowName == nil or windowName == "" then
        return false
    end
    if not DoesWindowExist(windowName) then
        return false
    end
    local cult = GameData and GameData.TradeSkills and GameData.TradeSkills.CULTIVATION or 3
    local action = GameData and GameData.PlayerActions and GameData.PlayerActions.PERFORM_CRAFTING or 8
    local ok = TryCall("WindowSetGameActionData", WindowSetGameActionData, windowName, action, cult, L"")
    if ok ~= true then
        return false
    end
    RestoreHarvestChrome(windowName)
    return true
end

local function ClearHarvestBindOnly()
    local Grow = StockPiler.Grow
    if not Grow or Grow.IsHarvestActionBound() ~= true then
        return false
    end
    if WindowSetGameActionData == nil then
        Grow.SetHarvestActionBound(false)
        return false
    end
    local none = 0
    if GameData and GameData.PlayerActions and GameData.PlayerActions.NONE ~= nil then
        none = GameData.PlayerActions.NONE
    end
    local function clearWin(windowName)
        if not DoesWindowExist(windowName) then
            return false
        end
        local ok = TryCall("WindowSetGameActionData.clear", WindowSetGameActionData, windowName, none, 0, L"")
        RestoreHarvestChrome(windowName)
        return ok == true
    end
    local cleared = clearWin(HARVEST_WIN)
    clearWin(HARVEST_ACTION_WIN)
    Grow.SetHarvestActionBound(false)
    return cleared
end

function HarvestChrome.EnsureHarvestActionBound()
    local Grow = StockPiler.Grow
    if not Grow then
        return false
    end
    if Grow.IsHarvestActionBound() == true and DoesWindowExist(HARVEST_WIN) then
        return true
    end
    if BindCultivationHarvestAction(HARVEST_WIN) or BindCultivationHarvestAction(HARVEST_ACTION_WIN) then
        Grow.SetHarvestActionBound(true)
        return true
    end
    Grow.SetHarvestActionBound(false)
    return false
end

--- Bind/clear PERFORM_CRAFTING only on ready transitions. Keep HandleInput for tooltips.
function HarvestChrome.SetFooterHarvestClickable(enabled)
    local Grow = StockPiler.Grow
    if not Grow or not DoesWindowExist(HARVEST_WIN) then
        return
    end
    enabled = enabled == true
    if WindowSetHandleInput then
        WindowSetHandleInput(HARVEST_WIN, true)
    end
    if Grow.GetFooterHarvestClickable() == enabled then
        return
    end
    if ButtonSetDisabledFlag then
        ButtonSetDisabledFlag(HARVEST_WIN, not enabled)
    end
    if enabled then
        HarvestChrome.EnsureHarvestActionBound()
    else
        ClearHarvestBindOnly()
    end
    Grow.SetFooterHarvestClickable(enabled)
end

function HarvestChrome.ClearHarvestActionBound()
    local Grow = StockPiler.Grow
    if Grow and Grow.SetFooterHarvestClickable then
        Grow.SetFooterHarvestClickable(nil)
    end
    local cleared = ClearHarvestBindOnly()
    if DoesWindowExist(HARVEST_WIN) and WindowSetHandleInput then
        WindowSetHandleInput(HARVEST_WIN, true)
    end
    return cleared
end

--- Footer-only WindowGameAction (no macro bar slots). Used by preferred fire order.
function HarvestChrome.FireFooterHarvestAction()
    HarvestChrome.EnsureHarvestActionBound()
    if type(WindowGameAction) ~= "function" then
        return false
    end
    local function tryWin(windowName, rebind)
        if windowName == nil or windowName == "" or not DoesWindowExist(windowName) then
            return false
        end
        if rebind == true then
            BindCultivationHarvestAction(windowName)
        end
        local child = windowName .. "Action"
        if DoesWindowExist(child) then
            local okChild = TryCall("WindowGameAction", WindowGameAction, child)
            if okChild == true then
                return true
            end
        end
        local ok = TryCall("WindowGameAction", WindowGameAction, windowName)
        return ok == true
    end
    return tryWin(HARVEST_WIN, true) or tryWin(HARVEST_ACTION_WIN, true)
end

--- Craft bar → footer → orphan Harvest slots.
function HarvestChrome.FireHarvestAction()
    if StockPiler.Macro and StockPiler.Macro.FireHarvestActionPreferred then
        return StockPiler.Macro.FireHarvestActionPreferred() == true
    end
    if StockPiler.Macro and StockPiler.Macro.FireCraftHarvestGameAction then
        if StockPiler.Macro.FireCraftHarvestGameAction() == true then
            return true
        end
    end
    if HarvestChrome.FireFooterHarvestAction() then
        return true
    end
    if StockPiler.Macro and StockPiler.Macro.FireHarvestGameAction then
        return StockPiler.Macro.FireHarvestGameAction() == true
    end
    return false
end
