----------------------------------------------------------------
-- StockPilerMacro - hotbar harvest/brew macros + craft-skill hijack
-- (GatherButton / WarTriage pattern). Stock Cultivating/Apothecary
-- DO_CRAFTING slots share AutoGrow / One-Click Brew toggles.
----------------------------------------------------------------

StockPilerMacro = StockPilerMacro or {}

local MACRO_NAME = L"StockPiler Harvest"
local MACRO_TEXT = L"/script StockPilerMacro.HarvestClick()"
local MACRO_ICON = 3317 -- Dw_Tool_2H_Shovel01.dds (eatemplate_icons)

local BREW_MACRO_NAME = L"StockPiler Brew"
local BREW_MACRO_TEXT = L"/script StockPilerMacro.BrewClick()"
local BREW_MACRO_ICON = 529 -- Itm_ge_cauldronmoltenmetal.dds (eatemplate_icons)

local ENABLED_TINT = { 255, 255, 255 }
local MUTED_TINT = { 125, 125, 125 }

local actionButtonHooksInstalled = false
local hotbarEventRegistered = false
local tooltipHookInstalled = false
local gameActionBindCache = {}

local function BindCacheKey(button)
    if not button then
        return nil
    end
    if type(button.GetName) == "function" then
        local name = button:GetName()
        if name ~= nil and name ~= "" then
            return name
        end
    end
    return button.m_Name
end

local function ClearGameActionBindCache()
    gameActionBindCache = {}
end

local function GameActionAlreadyBound(button, token)
    local key = BindCacheKey(button)
    if key == nil or token == nil then
        return false
    end
    return gameActionBindCache[key] == token
end

local function RememberGameActionBind(button, token)
    local key = BindCacheKey(button)
    if key ~= nil and token ~= nil then
        gameActionBindCache[key] = token
    end
end

StockPilerMacro.MacroId = 0
StockPilerMacro.BrewMacroId = 0
StockPilerMacro.MacroWarningState = {
    missing = false,
    unplaced = false,
    full = false,
}
StockPilerMacro.BrewMacroWarningState = {
    missing = false,
    unplaced = false,
    full = false,
}

local function D(msg)
    if StockPiler and StockPiler.D then
        StockPiler.D("[Macro] " .. tostring(msg))
    end
end

local function GetMacroTable()
    if type(GetMacrosData) == "function" then
        return GetMacrosData()
    end
    if DataUtils and type(DataUtils.GetMacros) == "function" then
        return DataUtils.GetMacros()
    end
    return {}
end

local function NumMacroSlots()
    if EA_Window_Macro and tonumber(EA_Window_Macro.NUM_MACROS) then
        return tonumber(EA_Window_Macro.NUM_MACROS)
    end
    local macros = GetMacroTable()
    return #macros
end

local function MacroText(macroData)
    if type(macroData) ~= "table" then
        return L""
    end
    return macroData.text or macroData.macroText or macroData.body or macroData.command or L""
end

local function FindMacroSlot(name, text, cachedId)
    cachedId = tonumber(cachedId) or 0
    if cachedId > 0 then
        return cachedId
    end
    local macros = GetMacroTable()
    local limit = NumMacroSlots()
    for slot = 1, limit do
        local macro = macros[slot]
        if type(macro) == "table" then
            if MacroText(macro) == text then
                return slot
            end
            if macro.name == name then
                return slot
            end
        end
    end
    return nil
end

function StockPilerMacro.GetMacroId()
    local slot = FindMacroSlot(MACRO_NAME, MACRO_TEXT, StockPilerMacro.MacroId)
    if slot then
        StockPilerMacro.MacroId = slot
    end
    return slot
end

function StockPilerMacro.GetBrewMacroId()
    local slot = FindMacroSlot(BREW_MACRO_NAME, BREW_MACRO_TEXT, StockPilerMacro.BrewMacroId)
    if slot then
        StockPilerMacro.BrewMacroId = slot
    end
    return slot
end

function StockPilerMacro.GetMacroSlots(macroId)
    macroId = tonumber(macroId) or 0
    local slots = {}
    if macroId <= 0 or not ActionBars or not ActionBars.m_Bars then
        return slots
    end
    for i = 1, #ActionBars.m_Bars do
        local bar = ActionBars.m_Bars[i]
        if bar and bar.m_Buttons then
            for j = 1, #bar.m_Buttons do
                local button = bar.m_Buttons[j]
                if button
                    and button.m_ActionType == GameData.PlayerActions.DO_MACRO
                    and button.m_ActionId == macroId
                then
                    slots[#slots + 1] = button.m_HotBarSlot
                end
            end
        end
    end
    return slots
end

local function SetMacroSlot(slot, name, text, iconId, kind)
    SetMacroData(name, text, iconId, slot)
    if EA_Window_Macro and EA_Window_Macro.UpdateDetails then
        StockPiler.TryCall("EA_Window_Macro.UpdateDetails", EA_Window_Macro.UpdateDetails, slot)
    end
    if kind == "brew" then
        StockPilerMacro.BrewMacroId = slot
    else
        StockPilerMacro.MacroId = slot
    end
end

function StockPilerMacro.UpdateMacro()
    local macros = GetMacroTable()
    local limit = NumMacroSlots()

    local existing = StockPilerMacro.GetMacroId()
    if existing then
        SetMacroSlot(existing, MACRO_NAME, MACRO_TEXT, MACRO_ICON)
        StockPilerMacro.MacroWarningState.full = false
        StockPilerMacro.MacroWarningState.missing = false
        return true
    end

    for slot = 1, limit do
        local macro = macros[slot]
        if type(macro) == "table" and MacroText(macro) == L"" and (macro.name == nil or macro.name == L"") then
            SetMacroSlot(slot, MACRO_NAME, MACRO_TEXT, MACRO_ICON)
            if StockPiler.Print then
                StockPiler.Print(L"<icon" .. towstring(tostring(MACRO_ICON)) .. L"> StockPiler Harvest macro created (slot "
                    .. towstring(tostring(slot)) .. L"). Drag it to your action bar.")
            end
            StockPilerMacro.MacroWarningState.full = false
            StockPilerMacro.MacroWarningState.missing = false
            return true
        end
    end

    if not StockPilerMacro.MacroWarningState.full and StockPiler.Print then
        StockPiler.Print(L"StockPiler: could not create Harvest macro (no empty macro slot).")
        StockPilerMacro.MacroWarningState.full = true
    end
    return false
end

function StockPilerMacro.UpdateBrewMacro()
    local macros = GetMacroTable()
    local limit = NumMacroSlots()

    local existing = StockPilerMacro.GetBrewMacroId()
    if existing then
        SetMacroSlot(existing, BREW_MACRO_NAME, BREW_MACRO_TEXT, BREW_MACRO_ICON, "brew")
        StockPilerMacro.BrewMacroWarningState.full = false
        StockPilerMacro.BrewMacroWarningState.missing = false
        return true
    end

    for slot = 1, limit do
        local macro = macros[slot]
        if type(macro) == "table" and MacroText(macro) == L"" and (macro.name == nil or macro.name == L"") then
            SetMacroSlot(slot, BREW_MACRO_NAME, BREW_MACRO_TEXT, BREW_MACRO_ICON, "brew")
            if StockPiler.Print then
                StockPiler.Print(L"<icon" .. towstring(tostring(BREW_MACRO_ICON)) .. L"> StockPiler Brew macro created (slot "
                    .. towstring(tostring(slot)) .. L"). Drag it to your action bar.")
            end
            StockPilerMacro.BrewMacroWarningState.full = false
            StockPilerMacro.BrewMacroWarningState.missing = false
            return true
        end
    end

    if not StockPilerMacro.BrewMacroWarningState.full and StockPiler.Print then
        StockPiler.Print(L"StockPiler: could not create Brew macro (no empty macro slot).")
        StockPilerMacro.BrewMacroWarningState.full = true
    end
    return false
end

local function CultivationTradeSkill()
    if GameData and GameData.TradeSkills and GameData.TradeSkills.CULTIVATION then
        return GameData.TradeSkills.CULTIVATION
    end
    return 3
end

local function ApothecaryTradeSkill()
    if GameData and GameData.TradeSkills and GameData.TradeSkills.APOTHECARY then
        return GameData.TradeSkills.APOTHECARY
    end
    return 4
end

-- Hotbar WindowGameAction stays DO_MACRO; apo brew is a Lua call like ApothecaryWindow.Perform().
local function FireApothecaryBrew()
    if StockPilerMacro._brewFired == true then
        return false
    end
    StockPilerMacro._brewFired = true
    if StockPiler.Inventory and StockPiler.Inventory.BeginPendingCraft then
        StockPiler.Inventory.BeginPendingCraft()
    end
    if type(PerformCrafting) ~= "function" then
        D("PerformCrafting missing")
        return false
    end
    local ok, err = StockPiler.TryCall("PerformCrafting", PerformCrafting, ApothecaryTradeSkill(), 1)
    D("PerformCrafting apo ok=" .. tostring(ok) .. " err=" .. tostring(err))
    if ok == true then
        if type(ApothecaryWindow) == "table" then
            ApothecaryWindow.PerformingLock = true
        end
        if StockPiler.Brew and StockPiler.Brew.ArmBrewOpLock then
            StockPiler.Brew.ArmBrewOpLock(1.25)
        end
    end
    return ok == true
end

function StockPilerMacro.FireApothecaryBrew()
    return FireApothecaryBrew()
end

local function PerformCraftingAction()
    if GameData and GameData.PlayerActions and GameData.PlayerActions.PERFORM_CRAFTING then
        return GameData.PlayerActions.PERFORM_CRAFTING
    end
    return 8
end

local function DoCraftingAction()
    if GameData and GameData.PlayerActions and GameData.PlayerActions.DO_CRAFTING then
        return GameData.PlayerActions.DO_CRAFTING
    end
    return 7
end

local function getButtonBaseIconFrame(button)
    if not button or not button.m_Windows then
        return nil
    end
    return button.m_Windows[0]
end

local function getButtonStatusOverlayFrame(button)
    if not button or not button.m_Windows then
        return nil
    end
    return button.m_Windows[7]
end

local function setMacroButtonEnabledOverlay(button, enabled)
    local overlay = getButtonStatusOverlayFrame(button)
    if not overlay then
        return
    end
    overlay:Show(true)
    if enabled then
        overlay:SetText(L"<icon00057>")
    else
        overlay:SetText(L"<icon00058>")
    end
end

local function setMacroButtonTint(button, tint)
    local iconFrame = getButtonBaseIconFrame(button)
    if iconFrame then
        iconFrame:SetTintColor(tint[1], tint[2], tint[3])
    end
end

local function isAutoGrowEnabled()
    if StockPiler.AutoGrow and StockPiler.AutoGrow.IsEnabled then
        return StockPiler.AutoGrow.IsEnabled()
    end
    local s = StockPiler.EnsureSettings and StockPiler.EnsureSettings() or StockPiler.Settings
    return type(s) == "table" and s.autoGrowEnabled == true
end

local isBrewMacroEnabled

local function bindHarvestGameAction(button)
    if not button or not button.m_Name or WindowSetGameActionData == nil then
        return false
    end
    local actionName = button.m_Name .. "Action"
    if not DoesWindowExist(actionName) then
        return false
    end
    local ok = StockPiler.TryCall(
        "WindowSetGameActionData", WindowSetGameActionData,
        actionName,
        PerformCraftingAction(),
        CultivationTradeSkill(),
        L""
    )
    return ok == true
end

local function bindDoCraftingGameAction(button, tradeSkillId)
    if not button or not button.m_Name or WindowSetGameActionData == nil then
        return false
    end
    local actionName = button.m_Name .. "Action"
    if not DoesWindowExist(actionName) then
        return false
    end
    local ok = StockPiler.TryCall(
        "WindowSetGameActionData", WindowSetGameActionData,
        actionName,
        DoCraftingAction(),
        tonumber(tradeSkillId) or 0,
        L""
    )
    return ok == true
end

local function bindHarvestGameActionForButton(button)
    if not button then
        return false
    end
    if GameActionAlreadyBound(button, "harvest") then
        return true
    end
    if button.m_Name and bindHarvestGameAction(button) then
        RememberGameActionBind(button, "harvest")
        return true
    end
    if type(button.GetName) == "function" then
        local actionName = button:GetName() .. "Action"
        if WindowSetGameActionData and DoesWindowExist(actionName) then
            local ok = StockPiler.TryCall(
                "WindowSetGameActionData", WindowSetGameActionData,
                actionName,
                PerformCraftingAction(),
                CultivationTradeSkill(),
                L""
            )
            if ok == true then
                RememberGameActionBind(button, "harvest")
            end
            return ok == true
        end
    end
    return false
end

local function bindDoCraftingGameActionForButton(button, tradeSkillId)
    if not button then
        return false
    end
    tradeSkillId = tonumber(tradeSkillId) or 0
    local token = "docraft:" .. tostring(tradeSkillId)
    if GameActionAlreadyBound(button, token) then
        return true
    end
    if button.m_Name and bindDoCraftingGameAction(button, tradeSkillId) then
        RememberGameActionBind(button, token)
        return true
    end
    if type(button.GetName) == "function" then
        local actionName = button:GetName() .. "Action"
        if WindowSetGameActionData and DoesWindowExist(actionName) then
            local ok = StockPiler.TryCall(
                "WindowSetGameActionData", WindowSetGameActionData,
                actionName,
                DoCraftingAction(),
                tradeSkillId,
                L""
            )
            if ok == true then
                RememberGameActionBind(button, token)
            end
            return ok == true
        end
    end
    return false
end

local function bindBrewGameAction(button)
    if not button or not button.m_Name or WindowSetGameActionData == nil then
        return false
    end
    local actionName = button.m_Name .. "Action"
    if not DoesWindowExist(actionName) then
        return false
    end
    local ok = StockPiler.TryCall(
        "WindowSetGameActionData", WindowSetGameActionData,
        actionName,
        PerformCraftingAction(),
        ApothecaryTradeSkill(),
        L""
    )
    return ok == true
end

local function bindBrewGameActionForButton(button)
    if not button then
        return false
    end
    if GameActionAlreadyBound(button, "brew") then
        return true
    end
    if button.m_Name and bindBrewGameAction(button) then
        RememberGameActionBind(button, "brew")
        return true
    end
    if type(button.GetName) == "function" then
        local actionName = button:GetName() .. "Action"
        if WindowSetGameActionData and DoesWindowExist(actionName) then
            local ok = StockPiler.TryCall(
                "WindowSetGameActionData", WindowSetGameActionData,
                actionName,
                PerformCraftingAction(),
                ApothecaryTradeSkill(),
                L""
            )
            if ok == true then
                RememberGameActionBind(button, "brew")
            end
            return ok == true
        end
    end
    return false
end

function StockPilerMacro.IsMacroButton(button)
    if not button or button.m_ActionType ~= GameData.PlayerActions.DO_MACRO then
        return false
    end
    local macroId = StockPilerMacro.GetMacroId()
    return macroId ~= nil and button.m_ActionId == macroId
end

function StockPilerMacro.IsBrewMacroButton(button)
    if not button or button.m_ActionType ~= GameData.PlayerActions.DO_MACRO then
        return false
    end
    local macroId = StockPilerMacro.GetBrewMacroId()
    return macroId ~= nil and button.m_ActionId == macroId
end

--- Stock Cultivating hotbar skill (opens Cultivation unless AutoGrow hijacks).
function StockPilerMacro.IsCultivationSkillButton(button)
    if not button or button.m_ActionType ~= DoCraftingAction() then
        return false
    end
    return tonumber(button.m_ActionId) == tonumber(CultivationTradeSkill())
end

--- Stock Apothecary hotbar skill (opens Apothecary unless One-Click Brew hijacks).
function StockPilerMacro.IsApothecarySkillButton(button)
    if not button or button.m_ActionType ~= DoCraftingAction() then
        return false
    end
    return tonumber(button.m_ActionId) == tonumber(ApothecaryTradeSkill())
end

local craftSkillSlotCache = {}

local function GetCraftSkillSlots(tradeSkillId)
    tradeSkillId = tonumber(tradeSkillId) or 0
    if tradeSkillId <= 0 then
        return {}
    end
    local cached = craftSkillSlotCache[tradeSkillId]
    if type(cached) == "table" then
        return cached
    end
    local slots = {}
    if type(GetHotbarData) ~= "function" then
        return slots
    end
    local craftType = DoCraftingAction()
    for btnNum = 1, 60 do
        local actionType, actionId = GetHotbarData(btnNum)
        if actionType == craftType and tonumber(actionId) == tradeSkillId then
            slots[#slots + 1] = btnNum
        end
    end
    craftSkillSlotCache[tradeSkillId] = slots
    return slots
end

--- Fire PERFORM_CRAFTING via a hotbar Action window (macros / cult skill).
--- PerformCrafting() is a silent no-op for cultivation; WindowGameAction on a
--- bound hotbar Action is the path that actually harvests.
function StockPilerMacro.FireHarvestGameAction()
    if type(WindowGameAction) ~= "function" or not ActionBars or not ActionBars.BarAndButtonIdFromSlot then
        return false
    end
    local function tryButton(button)
        if not button or not button.m_Name then
            return false
        end
        local actionName = button.m_Name .. "Action"
        if not DoesWindowExist(actionName) then
            return false
        end
        if not bindHarvestGameActionForButton(button) then
            return false
        end
        local ok = StockPiler.TryCall("WindowGameAction", WindowGameAction, actionName)
        return ok == true
    end
    local macroId = StockPilerMacro.GetMacroId and StockPilerMacro.GetMacroId()
    if macroId then
        local slots = StockPilerMacro.GetMacroSlots(macroId) or {}
        for i = 1, #slots do
            local hbar, buttonId = ActionBars:BarAndButtonIdFromSlot(slots[i])
            local button = hbar and hbar.m_Buttons and hbar.m_Buttons[buttonId]
            if tryButton(button) then
                return true
            end
        end
    end
    local cultSlots = GetCraftSkillSlots(CultivationTradeSkill())
    for i = 1, #cultSlots do
        local hbar, buttonId = ActionBars:BarAndButtonIdFromSlot(cultSlots[i])
        local button = hbar and hbar.m_Buttons and hbar.m_Buttons[buttonId]
        if tryButton(button) then
            if not isAutoGrowEnabled() then
                bindDoCraftingGameActionForButton(button, CultivationTradeSkill())
            end
            return true
        end
    end
    return false
end

isBrewMacroEnabled = function()
    if StockPiler.Brew and StockPiler.Brew.IsMacroEnabled then
        return StockPiler.Brew.IsMacroEnabled() == true
    end
    local s = StockPiler.EnsureSettings and StockPiler.EnsureSettings() or StockPiler.Settings
    return type(s) ~= "table" or s.brewMacroEnabled ~= false
end

local function clearPickupIfMouse(flags)
    if flags ~= SystemData.ButtonFlags.GAME_ACTION and ActionBars and ActionBars.SetPickupButton then
        ActionBars:SetPickupButton(nil)
    end
end

function StockPilerMacro.ApplyButtonAppearance(button, opts)
    if not button then
        return
    end
    opts = opts or {}
    local autoGrowOn = isAutoGrowEnabled()
    setMacroButtonEnabledOverlay(button, autoGrowOn)
    if opts.craftSkill == true then
        setMacroButtonTint(button, ENABLED_TINT)
        if opts.skipBind ~= true then
            if autoGrowOn then
                bindHarvestGameActionForButton(button)
            else
                bindDoCraftingGameActionForButton(button, CultivationTradeSkill())
            end
        end
        return
    end
    setMacroButtonTint(button, autoGrowOn and ENABLED_TINT or MUTED_TINT)
    if opts.skipBind ~= true then
        bindHarvestGameActionForButton(button)
    end
end

function StockPilerMacro.ApplyBrewButtonAppearance(button, opts)
    if not button then
        return
    end
    opts = opts or {}
    local brewOn = isBrewMacroEnabled()
    setMacroButtonEnabledOverlay(button, brewOn)
    if opts.craftSkill == true then
        setMacroButtonTint(button, ENABLED_TINT)
        if opts.skipBind ~= true then
            if brewOn then
                bindBrewGameActionForButton(button)
            else
                bindDoCraftingGameActionForButton(button, ApothecaryTradeSkill())
            end
        end
        return
    end
    setMacroButtonTint(button, brewOn and ENABLED_TINT or MUTED_TINT)
    if opts.skipBind ~= true then
        bindBrewGameActionForButton(button)
    end
end

function StockPilerMacro.RebindHotbarButtons()
    local harvestId = StockPilerMacro.GetMacroId()
    local brewId = StockPilerMacro.GetBrewMacroId()
    if type(GetHotbarData) ~= "function" or not ActionBars then
        return
    end
    for btnNum = 1, 60 do
        local actionType, actionId = GetHotbarData(btnNum)
        if actionType == GameData.PlayerActions.DO_MACRO
            and ((harvestId and actionId == harvestId) or (brewId and actionId == brewId))
        then
            local barObject, buttonId = ActionBars:BarAndButtonIdFromSlot(btnNum)
            if barObject and barObject.SetButtonData then
                barObject:SetButtonData(buttonId, actionType, actionId)
            end
        end
    end
end

function StockPilerMacro.SyncCraftSkillApothecaryBindings(force)
    if not ActionBars or not ActionBars.BarAndButtonIdFromSlot then
        return
    end
    local brewOn = isBrewMacroEnabled()
    if force == true or StockPilerMacro._lastApoBindBrew ~= brewOn then
        ClearGameActionBindCache()
    end
    if force ~= true and StockPilerMacro._lastApoBindBrew == brewOn then
        return
    end
    StockPilerMacro._lastApoBindBrew = brewOn
    local apoSlots = GetCraftSkillSlots(ApothecaryTradeSkill())
    for i = 1, #apoSlots do
        local hbar, buttonId = ActionBars:BarAndButtonIdFromSlot(apoSlots[i])
        local button = hbar and hbar.m_Buttons and hbar.m_Buttons[buttonId]
        if button then
            if brewOn then
                bindBrewGameActionForButton(button)
            else
                bindDoCraftingGameActionForButton(button, ApothecaryTradeSkill())
            end
        end
    end
end

function StockPilerMacro.SyncCraftSkillBindings(force)
    StockPilerMacro.SyncCraftSkillHarvestBindings(force)
    StockPilerMacro.SyncCraftSkillApothecaryBindings(force)
end

function StockPilerMacro.SyncCraftSkillHarvestBindings(force)
    if not ActionBars or not ActionBars.BarAndButtonIdFromSlot then
        return
    end
    local autoGrowOn = isAutoGrowEnabled()
    if force == true or StockPilerMacro._lastCultBindAutoGrow ~= autoGrowOn then
        ClearGameActionBindCache()
    end
    if force ~= true and StockPilerMacro._lastCultBindAutoGrow == autoGrowOn then
        return
    end
    StockPilerMacro._lastCultBindAutoGrow = autoGrowOn
    local cultSlots = GetCraftSkillSlots(CultivationTradeSkill())
    for i = 1, #cultSlots do
        local hbar, buttonId = ActionBars:BarAndButtonIdFromSlot(cultSlots[i])
        local button = hbar and hbar.m_Buttons and hbar.m_Buttons[buttonId]
        if button then
            if autoGrowOn then
                bindHarvestGameActionForButton(button)
            else
                bindDoCraftingGameActionForButton(button, CultivationTradeSkill())
            end
        end
    end
end

--- Appearance only changes on toggle / hotbar / SetActionData — apply immediately.
function StockPilerMacro.RequestRefreshMacroButtonAppearance(urgent)
    if urgent == true then
        StockPilerMacro._lastAppearanceKey = nil
    end
    StockPilerMacro.ForceRefreshMacroButtonAppearance()
end

function StockPilerMacro.ForceRefreshMacroButtonAppearance()
    StockPilerMacro._lastAppearanceKey = nil
    StockPilerMacro._appearanceDirty = false
    StockPilerMacro._appearanceUrgent = false
    StockPilerMacro.RefreshMacroButtonAppearance()
end

function StockPilerMacro.FlushAppearanceRefreshIfDirty()
    if StockPilerMacro._appearanceDirty ~= true then
        return
    end
    StockPilerMacro._appearanceDirty = false
    StockPilerMacro._appearanceUrgent = false
    StockPilerMacro.RefreshMacroButtonAppearance()
end

function StockPilerMacro.RefreshMacroButtonAppearance()
    if StockPilerMacro._refreshingAppearance == true then
        StockPilerMacro._appearanceDirty = true
        return
    end
    if not ActionBars or not ActionBars.m_Bars then
        return
    end
    StockPilerMacro._appearanceDirty = false
    StockPilerMacro._refreshingAppearance = true
    if StockPiler.Perf and StockPiler.Perf.Begin then
        StockPiler.Perf.Begin("RefreshMacroAppearance")
    end
    -- Raw pcall so the flag always clears; TryCall logging can re-enter the UI.
    local ok, err = pcall(StockPilerMacro._RefreshMacroButtonAppearanceBody)
    if StockPiler.Perf and StockPiler.Perf.End then
        StockPiler.Perf.End("RefreshMacroAppearance")
    end
    StockPilerMacro._refreshingAppearance = false
    if ok ~= true and StockPiler.D then
        StockPiler.D("[Macro] refresh failed: " .. tostring(err))
    end
end

function StockPilerMacro._RefreshMacroButtonAppearanceBody()
    if not ActionBars or not ActionBars.m_Bars then
        return
    end

    local autoGrowOn = isAutoGrowEnabled()
    local brewOn = isBrewMacroEnabled()
    local appearanceKey = tostring(autoGrowOn) .. ":" .. tostring(brewOn)
    if StockPilerMacro._lastAppearanceKey == appearanceKey then
        return
    end
    StockPilerMacro._lastAppearanceKey = appearanceKey

    StockPilerMacro.SyncCraftSkillBindings(true)

    local macroId = StockPilerMacro.GetMacroId()
    local brewId = StockPilerMacro.GetBrewMacroId()
    local cultSlots = GetCraftSkillSlots(CultivationTradeSkill())
    local apoSlots = GetCraftSkillSlots(ApothecaryTradeSkill())
    local harvestSlots = macroId and (StockPilerMacro.GetMacroSlots(macroId) or {}) or {}
    local brewSlots = brewId and (StockPilerMacro.GetMacroSlots(brewId) or {}) or {}
    if #harvestSlots == 0 and #brewSlots == 0 and #cultSlots == 0 and #apoSlots == 0 then
        return
    end

    if macroId then
        local slots = StockPilerMacro.GetMacroSlots(macroId)
        if #slots == 0 then
            if not StockPilerMacro.MacroWarningState.unplaced and StockPiler.Print then
                StockPiler.Print(L"<icon" .. towstring(tostring(MACRO_ICON))
                    .. L"> StockPiler Harvest macro is not on any action bar. Drag it from the macro list to a hotbar slot.")
                StockPilerMacro.MacroWarningState.unplaced = true
            end
        else
            StockPilerMacro.MacroWarningState.unplaced = false
            for i = 1, #slots do
                local hbar, buttonId = ActionBars:BarAndButtonIdFromSlot(slots[i])
                local button = hbar and hbar.m_Buttons and hbar.m_Buttons[buttonId]
                if button then
                    StockPilerMacro.ApplyButtonAppearance(button, { skipBind = true })
                end
            end
        end
    end

    for i = 1, #cultSlots do
        local hbar, buttonId = ActionBars:BarAndButtonIdFromSlot(cultSlots[i])
        local button = hbar and hbar.m_Buttons and hbar.m_Buttons[buttonId]
        if button then
            StockPilerMacro.ApplyButtonAppearance(button, { skipBind = true, craftSkill = true })
        end
    end

    if brewId then
        local slots = StockPilerMacro.GetMacroSlots(brewId)
        if #slots == 0 then
            if not StockPilerMacro.BrewMacroWarningState.unplaced and StockPiler.Print then
                StockPiler.Print(L"<icon" .. towstring(tostring(BREW_MACRO_ICON))
                    .. L"> StockPiler Brew macro is not on any action bar. Drag it from the macro list to a hotbar slot.")
                StockPilerMacro.BrewMacroWarningState.unplaced = true
            end
        else
            StockPilerMacro.BrewMacroWarningState.unplaced = false
            for i = 1, #slots do
                local hbar, buttonId = ActionBars:BarAndButtonIdFromSlot(slots[i])
                local button = hbar and hbar.m_Buttons and hbar.m_Buttons[buttonId]
                if button then
                    StockPilerMacro.ApplyBrewButtonAppearance(button, { skipBind = true })
                end
            end
        end
    end

    for i = 1, #apoSlots do
        local hbar, buttonId = ActionBars:BarAndButtonIdFromSlot(apoSlots[i])
        local button = hbar and hbar.m_Buttons and hbar.m_Buttons[buttonId]
        if button then
            StockPilerMacro.ApplyBrewButtonAppearance(button, { skipBind = true, craftSkill = true })
        end
    end
end

function StockPilerMacro.HarvestClick()
    if StockPiler.AutoGrow and StockPiler.AutoGrow.ExecuteHarvest then
        StockPiler.AutoGrow.ExecuteHarvest(true)
    end
end

function StockPilerMacro.BrewClick()
    if StockPilerMacro._brewFired == true then
        StockPilerMacro._brewFired = false
        return
    end
    if not isBrewMacroEnabled() then
        StockPilerMacro._brewFired = false
        return
    end
    local result = "blocked"
    if StockPiler.Brew and StockPiler.Brew.TryBrewClick then
        result = StockPiler.Brew.TryBrewClick()
    end
    if result == "go" then
        FireApothecaryBrew()
    end
    StockPilerMacro._brewFired = false
end

local function applySetActionDataAppearance(button, actionType, actionId)
    if not button then
        return
    end
    if actionType == GameData.PlayerActions.DO_MACRO then
        local harvestId = StockPilerMacro.GetMacroId()
        local brewId = StockPilerMacro.GetBrewMacroId()
        if harvestId ~= nil and actionId == harvestId then
            bindHarvestGameActionForButton(button)
            StockPilerMacro.ApplyButtonAppearance(button, { skipBind = true })
            return
        end
        if brewId ~= nil and actionId == brewId then
            bindBrewGameActionForButton(button)
            StockPilerMacro.ApplyBrewButtonAppearance(button, { skipBind = true })
        end
        return
    end
    if actionType == DoCraftingAction() then
        local aid = tonumber(actionId) or 0
        if aid == tonumber(CultivationTradeSkill()) then
            if isAutoGrowEnabled() then
                bindHarvestGameActionForButton(button)
            else
                bindDoCraftingGameActionForButton(button, CultivationTradeSkill())
            end
            StockPilerMacro.ApplyButtonAppearance(button, { skipBind = true, craftSkill = true })
        elseif aid == tonumber(ApothecaryTradeSkill()) then
            if isBrewMacroEnabled() then
                bindBrewGameActionForButton(button)
            else
                bindDoCraftingGameActionForButton(button, ApothecaryTradeSkill())
            end
            StockPilerMacro.ApplyBrewButtonAppearance(button, { skipBind = true, craftSkill = true })
        end
    end
end

local function installSetActionDataHook()
    if not ActionButton or type(ActionButton.SetActionData) ~= "function" then
        return
    end
    if StockPilerMacro._setActionDataHooked then
        return
    end
    local orgSetActionData = ActionButton.SetActionData
    ActionButton.SetActionData = function(self, actionType, actionId)
        orgSetActionData(self, actionType, actionId)
        applySetActionDataAppearance(self, actionType, actionId)
    end
    StockPilerMacro._setActionDataHooked = true
end

local function handleMacroHarvestActivation(self, flags)
    if Cursor and Cursor.IconOnCursor and Cursor.IconOnCursor() then
        return "cursor"
    end
    if not (StockPiler.AutoGrow and StockPiler.AutoGrow.CanHarvestNow and StockPiler.AutoGrow.CanHarvestNow()) then
        if StockPiler.AutoGrow and StockPiler.LogOp then
            local readyN = 0
            if StockPiler.AutoGrow.CountReadyHarvestPlots then
                readyN = StockPiler.AutoGrow.CountReadyHarvestPlots() or 0
            end
            local reason = "not-ready"
            if StockPiler.AutoGrow.HasPlantInProgress and StockPiler.AutoGrow.HasPlantInProgress() then
                reason = "plant-in-progress"
            elseif StockPiler.AutoGrow.IsHarvestCycleBusy and StockPiler.AutoGrow.IsHarvestCycleBusy() then
                reason = "harvest-cycle-busy"
            elseif readyN > 0 then
                reason = "blocked-other"
            end
            StockPiler.LogOp("harvest", "blocked macro reason=" .. reason .. " ready=" .. tostring(readyN))
        end
        if flags ~= SystemData.ButtonFlags.GAME_ACTION and ActionBars and ActionBars.SetPickupButton then
            ActionBars:SetPickupButton(nil)
        end
        return "blocked"
    end
    if StockPiler.AutoGrow and StockPiler.AutoGrow.PrepareHarvestPlot then
        StockPiler.AutoGrow.PrepareHarvestPlot(true)
    end
    return "go"
end

local function handleMacroBrewActivation(self, flags)
    if Cursor and Cursor.IconOnCursor and Cursor.IconOnCursor() then
        return "cursor"
    end
    if not isBrewMacroEnabled() then
        if flags ~= SystemData.ButtonFlags.GAME_ACTION and ActionBars and ActionBars.SetPickupButton then
            ActionBars:SetPickupButton(nil)
        end
        return "blocked"
    end
    if not (StockPiler.Brew and StockPiler.Brew.TryBrewClick) then
        return "blocked"
    end
    local result = StockPiler.Brew.TryBrewClick()
    if result == "go" then
        return "go"
    end
    if flags ~= SystemData.ButtonFlags.GAME_ACTION and ActionBars and ActionBars.SetPickupButton then
        ActionBars:SetPickupButton(nil)
    end
    return "blocked"
end

local function isControlPressed(flags)
    flags = tonumber(flags) or 0
    local ctrl = 8
    if SystemData and SystemData.ButtonFlags and SystemData.ButtonFlags.CONTROL then
        ctrl = tonumber(SystemData.ButtonFlags.CONTROL) or 8
    end
    if flags == ctrl then
        return true
    end
    if type(bit) == "table" and type(bit.band) == "function" then
        return bit.band(flags, ctrl) ~= 0
    end
    if ctrl <= 0 then
        return false
    end
    return math.mod(math.floor(flags / ctrl), 2) == 1
end

local ctrlHandledOnThisClick = false

local function isSpHarvestButton(button)
    return StockPilerMacro.IsMacroButton(button) or StockPilerMacro.IsCultivationSkillButton(button)
end

local function isSpBrewButton(button)
    return StockPilerMacro.IsBrewMacroButton(button) or StockPilerMacro.IsApothecarySkillButton(button)
end

--- Stock UpdateInventory hides STACK_COUNT_TEXT (m_Windows[7]); re-apply checkbox.
local function reapplyEnabledOverlay(button)
    if not button then
        return
    end
    if isSpHarvestButton(button) then
        setMacroButtonEnabledOverlay(button, isAutoGrowEnabled())
    elseif isSpBrewButton(button) then
        setMacroButtonEnabledOverlay(button, isBrewMacroEnabled())
    end
end

local function installActionButtonHooks()
    if actionButtonHooksInstalled or not ActionButton then
        return
    end

    local orgOnLButtonDown = ActionButton.OnLButtonDown
    ActionButton.OnLButtonDown = function(self, flags, x, y)
        if isSpHarvestButton(self) and isControlPressed(flags) then
            ctrlHandledOnThisClick = true
            if StockPiler.AutoGrow and StockPiler.AutoGrow.ToggleEnabled then
                StockPiler.AutoGrow.ToggleEnabled()
            end
            return
        end
        if isSpBrewButton(self) and isControlPressed(flags) then
            ctrlHandledOnThisClick = true
            if StockPiler.Brew and StockPiler.Brew.ToggleMacroEnabled then
                StockPiler.Brew.ToggleMacroEnabled()
            end
            return
        end
        if orgOnLButtonDown then
            orgOnLButtonDown(self, flags, x, y)
        end
    end

    local orgOnLButtonUp = ActionButton.OnLButtonUp
    ActionButton.OnLButtonUp = function(self, flags, x, y)
        if StockPilerMacro.IsMacroButton(self) then
            if ctrlHandledOnThisClick or isControlPressed(flags) then
                if (not ctrlHandledOnThisClick) and isControlPressed(flags) then
                    if StockPiler.AutoGrow and StockPiler.AutoGrow.ToggleEnabled then
                        StockPiler.AutoGrow.ToggleEnabled()
                    end
                end
                ctrlHandledOnThisClick = false
                return
            end
            local result = handleMacroHarvestActivation(self, flags)
            if result == "cursor" or result == "go" then
                orgOnLButtonUp(self, flags, x, y)
                return
            end
            if result == "blocked" then
                return
            end
        elseif StockPilerMacro.IsCultivationSkillButton(self) then
            if ctrlHandledOnThisClick or isControlPressed(flags) then
                if (not ctrlHandledOnThisClick) and isControlPressed(flags) then
                    if StockPiler.AutoGrow and StockPiler.AutoGrow.ToggleEnabled then
                        StockPiler.AutoGrow.ToggleEnabled()
                    end
                end
                ctrlHandledOnThisClick = false
                return
            end
            -- Toggle off: restore open-window action and let stock open Cultivation.
            if not isAutoGrowEnabled() then
                bindDoCraftingGameActionForButton(self, CultivationTradeSkill())
                orgOnLButtonUp(self, flags, x, y)
                return
            end
            -- Same as Harvest macro: Prepare, then fire hotbar PERFORM_CRAFTING via org.
            -- ExecuteHarvest/PerformCrafting alone does not harvest for cultivation.
            bindHarvestGameActionForButton(self)
            local result = handleMacroHarvestActivation(self, flags)
            if result == "cursor" or result == "go" then
                orgOnLButtonUp(self, flags, x, y)
                return
            end
            if result == "blocked" then
                return
            end
            return
        elseif StockPilerMacro.IsBrewMacroButton(self) then
            if ctrlHandledOnThisClick or isControlPressed(flags) then
                if (not ctrlHandledOnThisClick) and isControlPressed(flags) then
                    if StockPiler.Brew and StockPiler.Brew.ToggleMacroEnabled then
                        StockPiler.Brew.ToggleMacroEnabled()
                    end
                end
                ctrlHandledOnThisClick = false
                return
            end
            local result = handleMacroBrewActivation(self, flags)
            if result == "cursor" then
                orgOnLButtonUp(self, flags, x, y)
                return
            end
            if result == "go" then
                StockPilerMacro._brewFired = false
                FireApothecaryBrew()
                return
            end
            if result == "blocked" then
                return
            end
        elseif StockPilerMacro.IsApothecarySkillButton(self) then
            if ctrlHandledOnThisClick or isControlPressed(flags) then
                if (not ctrlHandledOnThisClick) and isControlPressed(flags) then
                    if StockPiler.Brew and StockPiler.Brew.ToggleMacroEnabled then
                        StockPiler.Brew.ToggleMacroEnabled()
                    end
                end
                ctrlHandledOnThisClick = false
                return
            end
            if not isBrewMacroEnabled() then
                orgOnLButtonUp(self, flags, x, y)
                return
            end
            local result = handleMacroBrewActivation(self, flags)
            if result == "cursor" then
                orgOnLButtonUp(self, flags, x, y)
                return
            end
            if result == "go" then
                clearPickupIfMouse(flags)
                StockPilerMacro._brewFired = false
                FireApothecaryBrew()
                return
            end
            if result == "blocked" then
                return
            end
        end
        orgOnLButtonUp(self, flags, x, y)
    end

    if type(ActionButton.UpdateBurning) == "function" then
        local orgUpdateBurning = ActionButton.UpdateBurning
        ActionButton.UpdateBurning = function(self, previousResource, currentResource)
            if isSpHarvestButton(self) or isSpBrewButton(self) then
                reapplyEnabledOverlay(self)
                return
            end
            orgUpdateBurning(self, previousResource, currentResource)
        end
    end

    if type(ActionButton.UpdateInventory) == "function" then
        local orgUpdateInventory = ActionButton.UpdateInventory
        ActionButton.UpdateInventory = function(self)
            if isSpHarvestButton(self) or isSpBrewButton(self) then
                reapplyEnabledOverlay(self)
                return
            end
            orgUpdateInventory(self)
        end
    end

    actionButtonHooksInstalled = true
end

local function appendPlotTooltipLines(startLine)
    if StockPiler.AutoGrow and StockPiler.AutoGrow.ApplyPlotTooltipRows then
        return StockPiler.AutoGrow.ApplyPlotTooltipRows(startLine, true)
    end
    startLine = tonumber(startLine) or 4
    Tooltips.SetTooltipText(startLine, 1, L"No plants growing.", false)
    return startLine + 1
end

local function installMacroTooltipHook()
    if tooltipHookInstalled or not Tooltips or type(Tooltips.CreateMacroTooltip) ~= "function" then
        return
    end
    local orgCreateMacroTooltip = Tooltips.CreateMacroTooltip
    Tooltips.CreateMacroTooltip = function(macroData, mouseoverWindow, anchor, extraText)
        local harvestId = StockPilerMacro.GetMacroId()
        local brewId = StockPilerMacro.GetBrewMacroId()
        local isHarvest = false
        local isBrew = false
        if type(macroData) == "table" then
            if harvestId and (macroData.slot == harvestId or macroData.index == harvestId or macroData.macroIndex == harvestId) then
                isHarvest = true
            elseif macroData.name == MACRO_NAME or MacroText(macroData) == MACRO_TEXT then
                isHarvest = true
            end
            if brewId and (macroData.slot == brewId or macroData.index == brewId or macroData.macroIndex == brewId) then
                isBrew = true
            elseif macroData.name == BREW_MACRO_NAME or MacroText(macroData) == BREW_MACRO_TEXT then
                isBrew = true
            end
        end
        if isHarvest then
            if StockPiler.AutoGrow and StockPiler.AutoGrow.ShowHarvestTooltip then
                StockPiler.AutoGrow.ShowHarvestTooltip(mouseoverWindow, anchor or Tooltips.ANCHOR_WINDOW_TOP)
            end
            return
        end
        if isBrew then
            if StockPiler.Brew and StockPiler.Brew.ShowBrewTooltip then
                StockPiler.Brew.ShowBrewTooltip(mouseoverWindow, anchor or Tooltips.ANCHOR_WINDOW_TOP)
            end
            return
        end
        return orgCreateMacroTooltip(macroData, mouseoverWindow, anchor, extraText)
    end
    tooltipHookInstalled = true
end

local tradeskillTooltipHookInstalled = false

local function installTradeskillTooltipHook()
    if tradeskillTooltipHookInstalled or not Tooltips or type(Tooltips.CreateTradeskillTooltip) ~= "function" then
        return
    end
    local orgCreateTradeskillTooltip = Tooltips.CreateTradeskillTooltip
    Tooltips.CreateTradeskillTooltip = function(tradeSkillId, anchor)
        tradeSkillId = tonumber(tradeSkillId) or 0
        local mouseWin = SystemData and SystemData.MouseOverWindow and SystemData.MouseOverWindow.name
        local tipAnchor = anchor or Tooltips.ANCHOR_WINDOW_TOP
        local button = nil
        if FrameManager and type(FrameManager.GetMouseOverWindow) == "function" then
            button = FrameManager:GetMouseOverWindow()
        end

        -- Hotbar craft skill while hijacked: same tooltip as the matching macro.
        if button and tradeSkillId == tonumber(CultivationTradeSkill())
            and isAutoGrowEnabled()
            and StockPilerMacro.IsCultivationSkillButton(button)
            and StockPiler.AutoGrow and StockPiler.AutoGrow.ShowHarvestTooltip
            and mouseWin
        then
            StockPiler.AutoGrow.ShowHarvestTooltip(mouseWin, tipAnchor)
            return
        end
        if button and tradeSkillId == tonumber(ApothecaryTradeSkill())
            and isBrewMacroEnabled()
            and StockPilerMacro.IsApothecarySkillButton(button)
            and StockPiler.Brew and StockPiler.Brew.ShowBrewTooltip
            and mouseWin
        then
            StockPiler.Brew.ShowBrewTooltip(mouseWin, tipAnchor)
            return
        end

        orgCreateTradeskillTooltip(tradeSkillId, anchor)
        local extra = nil
        if tradeSkillId == tonumber(CultivationTradeSkill()) then
            extra = L"StockPiler: Ctrl-click the Cultivating hotbar skill to toggle AutoGrow."
        elseif tradeSkillId == tonumber(ApothecaryTradeSkill()) then
            extra = L"StockPiler: Ctrl-click the Apothecary hotbar skill to toggle One-Click Brew."
        end
        if extra then
            Tooltips.SetTooltipText(4, 1, extra)
            Tooltips.Finalize()
            if anchor then
                Tooltips.AnchorTooltip(anchor)
            end
        end
    end
    tradeskillTooltipHookInstalled = true
end

function StockPilerMacro.InvalidateHotbarSlotCache()
    craftSkillSlotCache = {}
    ClearGameActionBindCache()
    StockPilerMacro._lastCultBindAutoGrow = nil
    StockPilerMacro._lastApoBindBrew = nil
end

function StockPilerMacro.InvalidateHotbarBindings()
    StockPilerMacro.InvalidateHotbarSlotCache()
    StockPilerMacro._lastAppearanceKey = nil
end

function StockPilerMacro.OnHotBarUpdated()
    StockPilerMacro.InvalidateHotbarSlotCache()
    StockPilerMacro.RequestRefreshMacroButtonAppearance(false)
end

function StockPilerMacro.RegisterHotbarEventHandler()
    if hotbarEventRegistered or not SystemData or not SystemData.Events then
        return
    end
    if SystemData.Events.PLAYER_HOT_BAR_UPDATED then
        RegisterEventHandler(SystemData.Events.PLAYER_HOT_BAR_UPDATED, "StockPilerMacro.OnHotBarUpdated")
        hotbarEventRegistered = true
    end
end

function StockPilerMacro.UnregisterHotbarEventHandler()
    if not hotbarEventRegistered or not SystemData or not SystemData.Events then
        return
    end
    if SystemData.Events.PLAYER_HOT_BAR_UPDATED then
        UnregisterEventHandler(SystemData.Events.PLAYER_HOT_BAR_UPDATED, "StockPilerMacro.OnHotBarUpdated")
    end
    hotbarEventRegistered = false
end

function StockPilerMacro.Initialize()
    StockPilerMacro._refreshingAppearance = false
    if StockPilerMacro._initialized then
        StockPilerMacro.UpdateBrewMacro()
        StockPilerMacro.RefreshMacroButtonAppearance()
        return
    end
    installSetActionDataHook()
    installActionButtonHooks()
    installMacroTooltipHook()
    installTradeskillTooltipHook()
    StockPilerMacro.UpdateMacro()
    StockPilerMacro.UpdateBrewMacro()
    StockPilerMacro.RegisterHotbarEventHandler()
    StockPilerMacro.RefreshMacroButtonAppearance()
    StockPilerMacro._initialized = true
    D("Initialize harvestId=" .. tostring(StockPilerMacro.GetMacroId())
        .. " brewId=" .. tostring(StockPilerMacro.GetBrewMacroId()))
end

function StockPilerMacro.Shutdown()
    StockPilerMacro.UnregisterHotbarEventHandler()
    StockPilerMacro._initialized = false
end
