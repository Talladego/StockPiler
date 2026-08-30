----------------------------------------------------------------
-- StockPilerMacro - hotbar harvest macro (GatherButton / WarTriage pattern)
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

local FLASH_ANIM = 4
local GLOW_ANIM = 6

local actionButtonHooksInstalled = false
local hotbarEventRegistered = false
local tooltipHookInstalled = false

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
StockPilerMacro.MacroButtonState = {
    glowLevel = 0,
    harvestReady = false,
    brewReady = false,
}
StockPilerMacro._prevHarvestReady = false
StockPilerMacro._prevBrewReady = false

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
        pcall(EA_Window_Macro.UpdateDetails, slot)
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
        pcall(StockPiler.Inventory.BeginPendingCraft)
    end
    if type(PerformCrafting) ~= "function" then
        D("PerformCrafting missing")
        return false
    end
    local ok, err = pcall(PerformCrafting, ApothecaryTradeSkill(), 1)
    D("PerformCrafting apo ok=" .. tostring(ok) .. " err=" .. tostring(err))
    if ok == true and type(ApothecaryWindow) == "table" then
        ApothecaryWindow.PerformingLock = true
    end
    return ok == true
end

local function PerformCraftingAction()
    if GameData and GameData.PlayerActions and GameData.PlayerActions.PERFORM_CRAFTING then
        return GameData.PlayerActions.PERFORM_CRAFTING
    end
    return 8
end

local function getButtonGlowFrame(button)
    if not button then
        return nil
    end
    if button.m_StockPilerGlowFrame then
        return button.m_StockPilerGlowFrame
    end
    local glowFrame = button.m_Windows and button.m_Windows[GLOW_ANIM]
    if not glowFrame and button.GetName then
        local glowWindowName = button:GetName() .. "OverlayGlow"
        if DoesWindowExist(glowWindowName) then
            glowFrame = AnimatedImage:CreateFrameForExistingWindow(glowWindowName)
        end
    end
    button.m_StockPilerGlowFrame = glowFrame
    return glowFrame
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

local function setMacroButtonVisualDisabled(button, disabled)
    setMacroButtonTint(button, disabled and MUTED_TINT or ENABLED_TINT)
    if disabled then
        StockPilerMacro.SetButtonGlow(button, 0)
    end
end

local function isAutoGrowEnabled()
    if StockPiler.AutoGrow and StockPiler.AutoGrow.IsEnabled then
        return StockPiler.AutoGrow.IsEnabled()
    end
    local s = StockPiler.EnsureSettings and StockPiler.EnsureSettings() or StockPiler.Settings
    return type(s) == "table" and s.autoGrowEnabled == true
end

local function canHarvestNow()
    return StockPiler.AutoGrow
        and StockPiler.AutoGrow.CanHarvestNow
        and StockPiler.AutoGrow.CanHarvestNow()
end

local function computeHarvestGlowLevel()
    if StockPiler.AutoGrow and StockPiler.AutoGrow.GetClosestPlotGlowLevel then
        return StockPiler.AutoGrow.GetClosestPlotGlowLevel()
    end
    if canHarvestNow() then
        return 4
    end
    return 0
end

local function formatTooltipIcon(iconNum)
    if StockPiler.AutoGrow and StockPiler.AutoGrow.FormatTooltipIcon then
        return StockPiler.AutoGrow.FormatTooltipIcon(iconNum)
    end
    iconNum = tonumber(iconNum) or 0
    if iconNum <= 0 then
        return L""
    end
    return towstring(string.format("<icon%05d>", iconNum))
end

function StockPilerMacro.SetButtonGlow(button, glowLevel)
    local glowFrame = getButtonGlowFrame(button)
    if not glowFrame then
        return
    end
    glowLevel = tonumber(glowLevel) or 0
    if not isAutoGrowEnabled() or glowLevel <= 0 then
        glowFrame:StopAnimation(true)
        glowFrame:Show(false)
        return
    end
    if glowLevel > 4 then
        glowLevel = 4
    elseif glowLevel < 1 then
        glowLevel = 1
    end
    glowFrame:Show(true)
    glowFrame:StopAnimation(true)
    glowFrame:SetAnimationTexture("anim_fury_" .. tostring(glowLevel))
    glowFrame:StartAnimation(0, true, false, 0)
    button.m_GlowLevel = glowLevel
end

local function flashButton(button)
    if not button or not button.m_Windows then
        return
    end
    local flash = button.m_Windows[FLASH_ANIM]
    if flash then
        flash:StartAnimation(0, false, true, 0)
    end
end

local function bindHarvestGameAction(button)
    if not button or not button.m_Name or WindowSetGameActionData == nil then
        return false
    end
    local actionName = button.m_Name .. "Action"
    if not DoesWindowExist(actionName) then
        return false
    end
    local ok = pcall(
        WindowSetGameActionData,
        actionName,
        PerformCraftingAction(),
        CultivationTradeSkill(),
        L""
    )
    return ok == true
end

local function bindHarvestGameActionForButton(button)
    if not button then
        return false
    end
    if button.m_Name and bindHarvestGameAction(button) then
        return true
    end
    if type(button.GetName) == "function" then
        local actionName = button:GetName() .. "Action"
        if WindowSetGameActionData and DoesWindowExist(actionName) then
            local ok = pcall(
                WindowSetGameActionData,
                actionName,
                PerformCraftingAction(),
                CultivationTradeSkill(),
                L""
            )
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
    local ok = pcall(
        WindowSetGameActionData,
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
    if button.m_Name and bindBrewGameAction(button) then
        return true
    end
    if type(button.GetName) == "function" then
        local actionName = button:GetName() .. "Action"
        if WindowSetGameActionData and DoesWindowExist(actionName) then
            local ok = pcall(
                WindowSetGameActionData,
                actionName,
                PerformCraftingAction(),
                ApothecaryTradeSkill(),
                L""
            )
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

local function canBrewNow()
    return StockPiler.Brew
        and StockPiler.Brew.HasReadyToCraft
        and StockPiler.Brew.HasReadyToCraft() == true
end

function StockPilerMacro.ApplyButtonAppearance(button, opts)
    if not button then
        return
    end
    opts = opts or {}
    local autoGrowOn = isAutoGrowEnabled()
    local glowLevel = computeHarvestGlowLevel()

    setMacroButtonEnabledOverlay(button, autoGrowOn)
    setMacroButtonVisualDisabled(button, not autoGrowOn)
    if autoGrowOn and glowLevel > 0 then
        StockPilerMacro.SetButtonGlow(button, glowLevel)
    else
        StockPilerMacro.SetButtonGlow(button, 0)
    end
    if opts.flash == true then
        flashButton(button)
    end
    bindHarvestGameActionForButton(button)

    StockPilerMacro.MacroButtonState.glowLevel = glowLevel
    StockPilerMacro.MacroButtonState.harvestReady = canHarvestNow()
end

function StockPilerMacro.ApplyBrewButtonAppearance(button, opts)
    if not button then
        return
    end
    opts = opts or {}
    local brewReady = canBrewNow()
    setMacroButtonEnabledOverlay(button, brewReady)
    setMacroButtonVisualDisabled(button, not brewReady)
    StockPilerMacro.SetButtonGlow(button, 0)
    if opts.flash == true then
        flashButton(button)
    end
    bindBrewGameActionForButton(button)
    StockPilerMacro.MacroButtonState.brewReady = brewReady
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

function StockPilerMacro.RefreshMacroButtonAppearance()
    if not ActionBars or not ActionBars.m_Bars then
        return
    end

    local macroId = StockPilerMacro.GetMacroId()
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
            local harvestReady = canHarvestNow()
            local shouldFlash = harvestReady and StockPilerMacro._prevHarvestReady ~= true
            for i = 1, #slots do
                local hbar, buttonId = ActionBars:BarAndButtonIdFromSlot(slots[i])
                local button = hbar and hbar.m_Buttons and hbar.m_Buttons[buttonId]
                if button then
                    StockPilerMacro.ApplyButtonAppearance(button, { flash = shouldFlash })
                end
            end
            StockPilerMacro._prevHarvestReady = harvestReady
        end
    end

    local brewId = StockPilerMacro.GetBrewMacroId()
    if not brewId then
        return
    end
    local brewSlots = StockPilerMacro.GetMacroSlots(brewId)
    if #brewSlots == 0 then
        if not StockPilerMacro.BrewMacroWarningState.unplaced and StockPiler.Print then
            StockPiler.Print(L"<icon" .. towstring(tostring(BREW_MACRO_ICON))
                .. L"> StockPiler Brew macro is not on any action bar. Drag it from the macro list to a hotbar slot.")
            StockPilerMacro.BrewMacroWarningState.unplaced = true
        end
        return
    end
    StockPilerMacro.BrewMacroWarningState.unplaced = false

    local brewReady = canBrewNow()
    local brewFlash = brewReady and StockPilerMacro._prevBrewReady ~= true
    for i = 1, #brewSlots do
        local hbar, buttonId = ActionBars:BarAndButtonIdFromSlot(brewSlots[i])
        local button = hbar and hbar.m_Buttons and hbar.m_Buttons[buttonId]
        if button then
            StockPilerMacro.ApplyBrewButtonAppearance(button, { flash = brewFlash })
        end
    end
    StockPilerMacro._prevBrewReady = brewReady
end

function StockPilerMacro.HarvestClick()
    if StockPiler.AutoGrow and StockPiler.AutoGrow.ExecuteHarvest then
        StockPiler.AutoGrow.ExecuteHarvest(true)
        StockPilerMacro.RefreshMacroButtonAppearance()
    end
end

function StockPilerMacro.BrewClick()
    if StockPilerMacro._brewFired == true then
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
    StockPilerMacro.RefreshMacroButtonAppearance()
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
        if actionType ~= GameData.PlayerActions.DO_MACRO then
            return
        end
        local harvestId = StockPilerMacro.GetMacroId()
        local brewId = StockPilerMacro.GetBrewMacroId()
        if harvestId ~= nil and actionId == harvestId then
            bindHarvestGameActionForButton(self)
            StockPilerMacro.RefreshMacroButtonAppearance()
            return
        end
        if brewId ~= nil and actionId == brewId then
            bindBrewGameActionForButton(self)
            StockPilerMacro.RefreshMacroButtonAppearance()
        end
    end
    StockPilerMacro._setActionDataHooked = true
end

local function handleMacroHarvestActivation(self, flags)
    if Cursor and Cursor.IconOnCursor and Cursor.IconOnCursor() then
        return "cursor"
    end
    if not (StockPiler.AutoGrow and StockPiler.AutoGrow.CanHarvestNow and StockPiler.AutoGrow.CanHarvestNow()) then
        if flags ~= SystemData.ButtonFlags.GAME_ACTION and ActionBars and ActionBars.SetPickupButton then
            ActionBars:SetPickupButton(nil)
        end
        return "blocked"
    end
    if StockPiler.AutoGrow and StockPiler.AutoGrow.PrepareHarvestPlot then
        pcall(StockPiler.AutoGrow.PrepareHarvestPlot, true)
    end
    return "go"
end

local function handleMacroBrewActivation(self, flags)
    if Cursor and Cursor.IconOnCursor and Cursor.IconOnCursor() then
        return "cursor"
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

local function installActionButtonHooks()
    if actionButtonHooksInstalled or not ActionButton then
        return
    end

    local orgOnLButtonDown = ActionButton.OnLButtonDown
    ActionButton.OnLButtonDown = function(self, flags, x, y)
        if StockPilerMacro.IsMacroButton(self) and isControlPressed(flags) then
            ctrlHandledOnThisClick = true
            if StockPiler.AutoGrow and StockPiler.AutoGrow.ToggleEnabled then
                StockPiler.AutoGrow.ToggleEnabled()
            end
            return
        end
        if StockPilerMacro.IsBrewMacroButton(self) and isControlPressed(flags) then
            ctrlHandledOnThisClick = true
            if StockPiler.Brew and StockPiler.Brew.CancelSession then
                StockPiler.Brew.CancelSession()
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
                pcall(StockPilerMacro.RefreshMacroButtonAppearance)
                return
            end
            if result == "blocked" then
                return
            end
        elseif StockPilerMacro.IsBrewMacroButton(self) then
            if ctrlHandledOnThisClick or isControlPressed(flags) then
                if (not ctrlHandledOnThisClick) and isControlPressed(flags) then
                    if StockPiler.Brew and StockPiler.Brew.CancelSession then
                        StockPiler.Brew.CancelSession()
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
                pcall(StockPilerMacro.RefreshMacroButtonAppearance)
                return
            end
            if result == "blocked" then
                pcall(StockPilerMacro.RefreshMacroButtonAppearance)
                return
            end
        end
        orgOnLButtonUp(self, flags, x, y)
    end

    if type(ActionButton.UpdateInventory) == "function" then
        local orgUpdateInventory = ActionButton.UpdateInventory
        ActionButton.UpdateInventory = function(self)
            if StockPilerMacro.IsMacroButton(self) or StockPilerMacro.IsBrewMacroButton(self) then
                orgUpdateInventory(self)
                StockPilerMacro.RefreshMacroButtonAppearance()
                return
            end
            orgUpdateInventory(self)
        end
    end

    if type(ActionButton.UpdateBurning) == "function" then
        local orgUpdateBurning = ActionButton.UpdateBurning
        ActionButton.UpdateBurning = function(self, previousResource, currentResource)
            if StockPilerMacro.IsMacroButton(self) or StockPilerMacro.IsBrewMacroButton(self) then
                return
            end
            orgUpdateBurning(self, previousResource, currentResource)
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

function StockPilerMacro.OnHotBarUpdated()
    StockPilerMacro.RebindHotbarButtons()
    StockPilerMacro.RefreshMacroButtonAppearance()
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
    if StockPilerMacro._initialized then
        StockPilerMacro.UpdateBrewMacro()
        StockPilerMacro.RefreshMacroButtonAppearance()
        return
    end
    installSetActionDataHook()
    installActionButtonHooks()
    installMacroTooltipHook()
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
