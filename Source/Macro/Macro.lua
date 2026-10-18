----------------------------------------------------------------
-- StockPiler Macro - Craft action button, plus Harvest and Brew
-- if the player still has those macros. Does not hijack stock
-- Cultivating / Apothecary craft skills.
-- Craft: brew when CanBrewNow, else harvest when CanHarvestNow, else grey.
----------------------------------------------------------------

StockPiler.Macro = StockPiler.Macro or {}
local Macro = StockPiler.Macro

local function T(key, tokens)
    return StockPiler.Util.T(key, tokens)
end

local MACRO_NAME = L"StockPiler Harvest"
local MACRO_TEXT = L"/script StockPiler.Macro.HarvestClick()"
local MACRO_ICON = 2486 -- Abi_or_Mushroom01.dds (+ _disabled)

local BREW_MACRO_NAME = L"StockPiler Brew"
local BREW_MACRO_TEXT = L"/script StockPiler.Macro.BrewClick()"
local BREW_MACRO_ICON = 10985 -- abi_de_elixirofmaddenedspeed.dds (+ _disabled)

local CRAFT_MACRO_NAME = L"StockPiler Craft"
local CRAFT_MACRO_TEXT = L"/script StockPiler.Macro.CraftClick()"
-- Start + idle-after-harvest: same mushroom as Harvest (greyed when idle).
local CRAFT_MACRO_ICON_HARVEST = MACRO_ICON
local CRAFT_MACRO_ICON_BREW = BREW_MACRO_ICON

local actionButtonHooksInstalled = false
local setActionDataHooked = false
local updateEnabledStateHooked = false
local hotbarEventRegistered = false
local tooltipHookInstalled = false
local gameActionBindCache = {}
local orgSetActionDataFn = nil
local orgUpdateEnabledStateFn = nil
local orgUpdateIconFn = nil
local orgOnLButtonUpFn = nil
local orgCreateMacroTooltipFn = nil
local hookedSetActionDataFn = nil
local hookedUpdateEnabledStateFn = nil
local hookedUpdateIconFn = nil
local hookedOnLButtonUpFn = nil
local hookedCreateMacroTooltipFn = nil

-- ActionButton BASE_ICON window index (ea_actionbars actionbutton.lua).
local ACTION_BUTTON_BASE_ICON = 0

Macro.MacroId = 0
Macro.BrewMacroId = 0
Macro.CraftMacroId = 0
Macro.MacroWarningState = { missing = false, unplaced = false, full = false }
Macro.BrewMacroWarningState = { missing = false, unplaced = false, full = false }
Macro.CraftMacroWarningState = { missing = false, unplaced = false, full = false }
-- Last latched harvest/brew icon for Craft (idle keeps this, greyed). Session memory only.
Macro._craftIconMode = "harvest"

local function D(msg)
    if StockPiler.Debug and StockPiler.Debug.D then
        StockPiler.Debug.D("[Macro] " .. tostring(msg))
    end
end

local function Print(msg)
    if StockPiler.Debug and StockPiler.Debug.Reply then
        StockPiler.Debug.Reply(msg)
    elseif StockPiler.Debug and StockPiler.Debug.Print then
        StockPiler.Debug.Print(msg, "user")
    end
end

local function TryCall(context, fn, ...)
    return StockPiler.Util.TryCall(context, fn, ...)
end

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

local function ForgetGameActionBind(button)
    local key = BindCacheKey(button)
    if key ~= nil then
        gameActionBindCache[key] = nil
    end
end

local function ActionWindowName(button)
    if not button then
        return nil
    end
    if button.m_Name and button.m_Name ~= "" then
        return button.m_Name .. "Action"
    end
    if type(button.GetName) == "function" then
        local name = button:GetName()
        if name ~= nil and name ~= "" then
            return name .. "Action"
        end
    end
    return nil
end

local function forceGreyMacroIcon(button)
    -- Macro icons often ship a colorful *_disabled texture; ActionButton only greys
    -- via tint when no disabled texture exists. Force tint so a disabled macro looks off.
    local icon = button and button.m_Windows and button.m_Windows[ACTION_BUTTON_BASE_ICON]
    if icon and type(icon.SetTintColor) == "function" then
        icon:SetTintColor(125, 125, 125)
    end
end

local function resetMacroIconTint(button)
    local icon = button and button.m_Windows and button.m_Windows[ACTION_BUTTON_BASE_ICON]
    if icon and type(icon.SetTintColor) == "function" then
        icon:SetTintColor(255, 255, 255)
    end
end

local function setButtonEnabledVisual(button, canUse)
    canUse = canUse == true
    if type(button.UpdateEnabledState) == "function" then
        -- Stock UpdateIcon re-applies whatever m_IsEnabled already is. Set it
        -- before the call so a nested icon refresh cannot put the grey texture back.
        button.m_IsEnabled = canUse
        button.m_IsTargetValid = true
        button.m_IsBlocked = false
        button:UpdateEnabledState(canUse, true, false)
        if canUse then
            resetMacroIconTint(button)
        else
            forceGreyMacroIcon(button)
        end
        return
    end
    local win = button.m_Name
    if (win == nil or win == "") and type(button.GetName) == "function" then
        win = button:GetName()
    end
    if win and win ~= "" and ButtonSetDisabledFlag then
        ButtonSetDisabledFlag(win, not canUse)
    end
end

local function canHarvestMacro()
    return StockPiler.Grow and StockPiler.Grow.CanHarvestNow
        and StockPiler.Grow.CanHarvestNow() == true
end

local function canBrewMacro()
    return StockPiler.Brew and StockPiler.Brew.CanBrewNow
        and StockPiler.Brew.CanBrewNow() == true
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

local function NumMacroSlots(macros)
    if EA_Window_Macro and tonumber(EA_Window_Macro.NUM_MACROS) then
        return tonumber(EA_Window_Macro.NUM_MACROS)
    end
    if type(macros) == "table" then
        return #macros
    end
    return #GetMacroTable()
end

local function MacroText(macroData)
    if type(macroData) ~= "table" then
        return L""
    end
    return macroData.text or macroData.macroText or macroData.body or macroData.command or L""
end

local function IsLegacyMacroName(name)
    if name == nil then
        return false
    end
    -- Leave the other addon's harvest and brew macros alone.
    if name == L"StockPiler2 Harvest" or name == L"StockPiler2 Brew" then
        return true
    end
    return false
end

--- Match against a pre-fetched macros table (one GetMacrosData per FindMacroSlot).
local function MacroSlotMatchesIn(macros, slot, name, text)
    slot = tonumber(slot) or 0
    if slot <= 0 or type(macros) ~= "table" then
        return false
    end
    local macro = macros[slot]
    if type(macro) ~= "table" or IsLegacyMacroName(macro.name) then
        return false
    end
    -- Require name+text when both are known so a rewritten slot (e.g. old
    -- Harvest slot now holding /assist) cannot keep our cached id.
    local textMatch = MacroText(macro) == text
    local nameMatch = macro.name == name
    if text ~= nil and text ~= L"" and name ~= nil and name ~= L"" then
        return textMatch and nameMatch
    end
    return textMatch or nameMatch
end

local function MacroSlotMatches(slot, name, text)
    return MacroSlotMatchesIn(GetMacroTable(), slot, name, text)
end

--- Same name+text rule for tooltip data (not slot-indexed).
local function IsOurMacroData(macroData, name, text)
    if type(macroData) ~= "table" or IsLegacyMacroName(macroData.name) then
        return false
    end
    local textMatch = MacroText(macroData) == text
    local nameMatch = macroData.name == name
    if text ~= nil and text ~= L"" and name ~= nil and name ~= L"" then
        return textMatch and nameMatch
    end
    return textMatch or nameMatch
end

local function FindMacroSlot(name, text, cachedId)
    cachedId = tonumber(cachedId) or 0
    local macros = GetMacroTable()
    -- Never trust a cached id without re-checking the slot contents. A stale
    -- id pointing at the player's Assist macro makes ButtonIsOurs true and
    -- WindowSetGameActionData(NONE) turns WindowGameAction into a no-op.
    if cachedId > 0 and MacroSlotMatchesIn(macros, cachedId, name, text) then
        return cachedId
    end
    -- Name and text together. A player macro that only shares our name
    -- (different body) must not be treated as ours and overwritten at login.
    -- One GetMacroTable for the whole walk (#33); pass macros into NumMacroSlots.
    local limit = NumMacroSlots(macros)
    for slot = 1, limit do
        if MacroSlotMatchesIn(macros, slot, name, text) then
            return slot
        end
    end
    return nil
end

function Macro.GetMacroId()
    local slot = FindMacroSlot(MACRO_NAME, MACRO_TEXT, Macro.MacroId)
    Macro.MacroId = slot or 0
    return slot
end

function Macro.GetBrewMacroId()
    local slot = FindMacroSlot(BREW_MACRO_NAME, BREW_MACRO_TEXT, Macro.BrewMacroId)
    Macro.BrewMacroId = slot or 0
    return slot
end

function Macro.GetCraftMacroId()
    local slot = FindMacroSlot(CRAFT_MACRO_NAME, CRAFT_MACRO_TEXT, Macro.CraftMacroId)
    Macro.CraftMacroId = slot or 0
    return slot
end

local function RebuildOurMacroIds()
    local ids = {}
    local h = Macro.GetMacroId()
    local b = Macro.GetBrewMacroId()
    local c = Macro.GetCraftMacroId()
    if h then
        ids[h] = true
    end
    if b then
        ids[b] = true
    end
    if c then
        ids[c] = true
    end
    Macro._ourIds = ids
end

local function IsDoMacroAction(actionType)
    local pa = GameData and GameData.PlayerActions
    return pa ~= nil and actionType == pa.DO_MACRO
end

local function ButtonIsOurs(button)
    if not button or not IsDoMacroAction(button.m_ActionType) then
        return false
    end
    local id = button.m_ActionId
    if id == nil then
        return false
    end
    -- Trust ids rebuilt on MACROS_LOADED / MACRO_UPDATED (and hook install).
    -- Do not call Get*MacroId here — those rescans GetMacroTable per button paint.
    local ids = Macro._ourIds
    if type(ids) ~= "table" then
        RebuildOurMacroIds()
        ids = Macro._ourIds
    end
    return type(ids) == "table" and ids[id] == true
end

--- m_Bars is keyed by page id or by window name once the id is past the
--- swappable pages. A numeric loop misses those bars, so Craft (or Harvest)
--- never gets the enable paint while the other still does.
local function ForEachActionButton(fn)
    if not ActionBars or not ActionBars.m_Bars or type(fn) ~= "function" then
        return
    end
    for _, bar in pairs(ActionBars.m_Bars) do
        local buttons = bar and bar.m_Buttons
        if type(buttons) == "table" then
            for _, button in pairs(buttons) do
                if type(button) == "table" then
                    fn(button)
                end
            end
        end
    end
end

function Macro.GetMacroSlots(macroId)
    macroId = tonumber(macroId) or 0
    local slots = {}
    if macroId <= 0 or not GameData then
        return slots
    end
    ForEachActionButton(function(button)
        if IsDoMacroAction(button.m_ActionType) and button.m_ActionId == macroId then
            local slot = tonumber(button.m_HotBarSlot)
            if slot ~= nil then
                slots[#slots + 1] = slot
            end
        end
    end)
    return slots
end

local function InvalidateSlotCache()
    Macro._cachedHarvestSlots = nil
    Macro._cachedBrewSlots = nil
    Macro._cachedCraftSlots = nil
    Macro._slotCacheFp = nil
    Macro._cachedHarvestId = nil
    Macro._cachedBrewId = nil
    Macro._cachedCraftId = nil
end

--- Stable fingerprint of harvest/brew/craft hotbar placements (sorted slot ids).
--- Caches slot lists so Refresh does not walk ActionBars repeatedly per apply.
local function SlotFingerprint()
    local harvestId = tonumber(Macro.GetMacroId()) or 0
    local brewId = tonumber(Macro.GetBrewMacroId()) or 0
    local craftId = tonumber(Macro.GetCraftMacroId()) or 0
    local hSlots
    local bSlots
    local cSlots
    if Macro._slotCacheFp ~= nil
        and Macro._cachedHarvestId == harvestId
        and Macro._cachedBrewId == brewId
        and Macro._cachedCraftId == craftId
        and type(Macro._cachedHarvestSlots) == "table"
        and type(Macro._cachedBrewSlots) == "table"
        and type(Macro._cachedCraftSlots) == "table"
    then
        hSlots = Macro._cachedHarvestSlots
        bSlots = Macro._cachedBrewSlots
        cSlots = Macro._cachedCraftSlots
    else
        hSlots = Macro.GetMacroSlots(harvestId)
        bSlots = Macro.GetMacroSlots(brewId)
        cSlots = Macro.GetMacroSlots(craftId)
        table.sort(hSlots)
        table.sort(bSlots)
        table.sort(cSlots)
        Macro._cachedHarvestSlots = hSlots
        Macro._cachedBrewSlots = bSlots
        Macro._cachedCraftSlots = cSlots
        Macro._cachedHarvestId = harvestId
        Macro._cachedBrewId = brewId
        Macro._cachedCraftId = craftId
    end
    local parts = { "h", tostring(harvestId) }
    for i = 1, #hSlots do
        parts[#parts + 1] = tostring(hSlots[i])
    end
    parts[#parts + 1] = "b"
    parts[#parts + 1] = tostring(brewId)
    for i = 1, #bSlots do
        parts[#parts + 1] = tostring(bSlots[i])
    end
    parts[#parts + 1] = "c"
    parts[#parts + 1] = tostring(craftId)
    for i = 1, #cSlots do
        parts[#parts + 1] = tostring(cSlots[i])
    end
    local fp = table.concat(parts, ",")
    Macro._slotCacheFp = fp
    return fp
end

local function RememberSlotFingerprint()
    Macro._lastSlotFingerprint = SlotFingerprint()
end

--- Never call EA_Window_Macro.UpdateDetails here: it switches the Macro
--- window's active slot and overwrites its edit boxes, so a pending edit of
--- another macro (e.g. /assist <name>) would be lost or saved into our slot.
--- Stock OnMacroUpdated already refreshes the icon and the open details.
local function SetMacroSlot(slot, name, text, iconId, kind)
    SetMacroData(name, text, iconId, slot)
    if kind == "brew" then
        Macro.BrewMacroId = slot
    elseif kind == "craft" then
        Macro.CraftMacroId = slot
    else
        Macro.MacroId = slot
    end
end

local function CraftIconIdForMode(iconMode)
    if iconMode == "brew" then
        return CRAFT_MACRO_ICON_BREW
    end
    return CRAFT_MACRO_ICON_HARVEST
end

--- Apply Craft macro icon only when latch harvest↔brew changes (never on idle alone).
local function EnsureCraftMacroIcon(iconMode)
    iconMode = (iconMode == "brew") and "brew" or "harvest"
    local slot = Macro.GetCraftMacroId()
    if not slot then
        return false
    end
    if Macro._craftIconApplied == iconMode then
        return false
    end
    SetMacroSlot(slot, CRAFT_MACRO_NAME, CRAFT_MACRO_TEXT, CraftIconIdForMode(iconMode), "craft")
    Macro._craftIconApplied = iconMode
    Macro._craftIconMode = iconMode
    return true
end

--- Refresh an orphan Harvest macro slot if the player still has one.
--- Does not create new Harvest macros (Craft-only).
function Macro.UpdateMacro()
    local existing = Macro.GetMacroId()
    if not existing then
        Macro.MacroWarningState.missing = true
        return false
    end
    SetMacroSlot(existing, MACRO_NAME, MACRO_TEXT, MACRO_ICON)
    Macro.MacroWarningState.full = false
    Macro.MacroWarningState.missing = false
    return true
end

--- Refresh an orphan Brew macro slot if the player still has one.
--- Does not create new Brew macros (Craft-only).
function Macro.UpdateBrewMacro()
    local existing = Macro.GetBrewMacroId()
    if not existing then
        Macro.BrewMacroWarningState.missing = true
        return false
    end
    SetMacroSlot(existing, BREW_MACRO_NAME, BREW_MACRO_TEXT, BREW_MACRO_ICON, "brew")
    Macro.BrewMacroWarningState.full = false
    Macro.BrewMacroWarningState.missing = false
    return true
end

function Macro.UpdateCraftMacro()
    local macros = GetMacroTable()
    local limit = NumMacroSlots(macros)
    local iconMode = Macro._craftIconMode or "harvest"
    local iconId = CraftIconIdForMode(iconMode)

    local existing = Macro.GetCraftMacroId()
    if existing then
        -- Keep latched icon; do not reset to harvest on every init refresh.
        if Macro._craftIconApplied ~= iconMode then
            SetMacroSlot(existing, CRAFT_MACRO_NAME, CRAFT_MACRO_TEXT, iconId, "craft")
            Macro._craftIconApplied = iconMode
        end
        Macro.CraftMacroWarningState.full = false
        Macro.CraftMacroWarningState.missing = false
        return true
    end

    for slot = 1, limit do
        local macro = macros[slot]
        if type(macro) == "table" and MacroText(macro) == L"" and (macro.name == nil or macro.name == L"") then
            Macro._craftIconMode = "harvest"
            SetMacroSlot(slot, CRAFT_MACRO_NAME, CRAFT_MACRO_TEXT, CRAFT_MACRO_ICON_HARVEST, "craft")
            Macro._craftIconApplied = "harvest"
            Print(T("macro.craft_created", {
                icon = tostring(CRAFT_MACRO_ICON_HARVEST),
                slot = tostring(slot),
            }))
            Macro.CraftMacroWarningState.full = false
            Macro.CraftMacroWarningState.missing = false
            return true
        end
    end

    if not Macro.CraftMacroWarningState.full then
        Print(T("macro.craft_full"))
        Macro.CraftMacroWarningState.full = true
    end
    return false
end

local function SoftHarvestReady()
    local Caps = StockPiler.TradeSkillCaps
    if Caps and Caps.CanAutoGrow and Caps.CanAutoGrow() ~= true then
        return false, 0
    end
    local Grow = StockPiler.Grow
    if not (Grow and Grow.GetReadyHarvestPlots) then
        return false, 0
    end
    local plots = Grow.GetReadyHarvestPlots()
    local n = (type(plots) == "table" and #plots) or 0
    return n > 0, n
end

local function BrewSessionSticky()
    local Brew = StockPiler.Brew
    if not Brew then
        return false, "idle", nil
    end
    if Brew._loadSource == "manual" then
        return false, "idle", nil
    end
    local session = Brew.GetSession and Brew.GetSession()
    if type(session) ~= "table" then
        return false, "idle", nil
    end
    local phase = tostring(session.phase or "idle")
    if phase ~= "loading" and phase ~= "loaded" then
        return false, phase, nil
    end
    local name = session.name
    if name == nil or name == L"" then
        name = nil
    end
    return true, phase, name
end

--- Craft enable matches the footer buttons: brew when CanBrewNow, else harvest
--- when CanHarvestNow, else dark. With AutoBrew on, CanBrewNow stays false so
--- Craft is harvest-only. Icon is the brew icon only while brew is ready;
--- every other state uses the harvest icon. A loading session must not force
--- brew while Brew is dark.
--- Sticky phase and ready-plot count stay on the snap for the tooltip only.
--- opts.canHarvest / opts.canBrew: reuse enable-sync values when provided.
--- opts.readonly: tip path - do not mutate _craftIconMode.
function Macro.ResolveCraftMode(opts)
    opts = type(opts) == "table" and opts or {}
    local canHarvest = opts.canHarvest
    if canHarvest == nil then
        canHarvest = canHarvestMacro()
    else
        canHarvest = canHarvest == true
    end
    local canBrew = opts.canBrew
    if canBrew == nil then
        canBrew = canBrewMacro()
    else
        canBrew = canBrew == true
    end

    local soft, readyPlots = SoftHarvestReady()
    local brewSticky, brewPhase, brewName = BrewSessionSticky()
    if not brewSticky then
        brewPhase = "idle"
    end

    -- Same booleans as footer Harvest / Brew. Prefer brew when both are lit.
    local mode = "idle"
    if canBrew then
        mode = "brew"
    elseif canHarvest then
        mode = "harvest"
    end

    -- Harvest icon unless a brew is ready. Idle does not keep the brew icon.
    local iconMode = canBrew and "brew" or "harvest"
    if opts.readonly ~= true then
        Macro._craftIconMode = iconMode
    end

    local craftCanUse = mode == "harvest" or mode == "brew"

    local snap = {
        mode = mode,
        iconMode = iconMode,
        readyPlots = readyPlots,
        canHarvest = canHarvest,
        canBrew = canBrew,
        craftCanUse = craftCanUse,
        brewPhase = brewPhase,
        brewName = brewName,
        softHarvest = soft == true,
        brewSticky = brewSticky == true,
    }
    if opts.readonly ~= true then
        Macro._craftSnap = snap
    end
    return snap
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

local function PerformCraftingAction()
    if GameData and GameData.PlayerActions and GameData.PlayerActions.PERFORM_CRAFTING then
        return GameData.PlayerActions.PERFORM_CRAFTING
    end
    return 8
end

local function bindHarvestGameAction(button)
    if not button or not button.m_Name or WindowSetGameActionData == nil then
        return false
    end
    local actionName = button.m_Name .. "Action"
    if not DoesWindowExist(actionName) then
        return false
    end
    local ok = TryCall(
        "WindowSetGameActionData", WindowSetGameActionData,
        actionName,
        PerformCraftingAction(),
        CultivationTradeSkill(),
        L""
    )
    return ok == true
end

local function bindHarvestGameActionForButton(button, opts)
    opts = type(opts) == "table" and opts or {}
    if not button then
        return false
    end
    -- force=true on click: engine may have cleared the Action bind while our
    -- cache still says "harvest", which made WindowGameAction a no-op.
    if opts.force ~= true and GameActionAlreadyBound(button, "harvest") then
        return true
    end
    if button.m_Name and bindHarvestGameAction(button) then
        RememberGameActionBind(button, "harvest")
        return true
    end
    if type(button.GetName) == "function" then
        local actionName = button:GetName() .. "Action"
        if WindowSetGameActionData and DoesWindowExist(actionName) then
            local ok = TryCall(
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

--- Put DO_MACRO back on the Action child. Clearing to NONE leaves
--- WindowGameAction as a silent no-op (same failure mode as GCDsaver's
--- WindowGameAction swap — see RoR forums / Talladego on GCDsaver 1.0.5).
local function restoreDoMacroGameActionForButton(button)
    if not button or WindowSetGameActionData == nil then
        return false
    end
    if not IsDoMacroAction(button.m_ActionType) then
        return false
    end
    local macroId = tonumber(button.m_ActionId) or 0
    if macroId <= 0 then
        return false
    end
    local actionName = ActionWindowName(button)
    if actionName == nil or not DoesWindowExist(actionName) then
        return false
    end
    local doMacro = (GameData and GameData.PlayerActions and GameData.PlayerActions.DO_MACRO)
        or 4
    local ok = TryCall(
        "WindowSetGameActionData.restoreDoMacro", WindowSetGameActionData,
        actionName,
        doMacro,
        macroId,
        L""
    )
    ForgetGameActionBind(button)
    return ok == true
end

local function clearHarvestGameActionForButton(button)
    return restoreDoMacroGameActionForButton(button)
end

local function clearBrewGameActionForButton(button)
    return restoreDoMacroGameActionForButton(button)
end

--- Stock UpdateEnabledState skips tint reset when iconType is USE_EMPTY_ICON and the
--- slot is disabled - our forceGrey tint then sticks on Blank-Action-Bar-Icon-Slot
--- after Harvest/Brew is dragged away. WarTriage only tints current macro slots and
--- does not hook UpdateEnabledState, so it rarely leaves this residue.
--- Stock SetActionData has already bound the new occupant (e.g. a player's
--- /assist macro); clearing the Action window here would leave it dead.
local function restoreVacatedMacroSlot(button)
    if not button then
        return
    end
    resetMacroIconTint(button)
    ForgetGameActionBind(button)
end

local function bindBrewGameAction(button)
    if not button or not button.m_Name or WindowSetGameActionData == nil then
        return false
    end
    local actionName = button.m_Name .. "Action"
    if not DoesWindowExist(actionName) then
        return false
    end
    local ok = TryCall(
        "WindowSetGameActionData", WindowSetGameActionData,
        actionName,
        PerformCraftingAction(),
        ApothecaryTradeSkill(),
        L""
    )
    return ok == true
end

local function bindBrewGameActionForButton(button, opts)
    opts = type(opts) == "table" and opts or {}
    if not button then
        return false
    end
    if opts.force ~= true and GameActionAlreadyBound(button, "brew") then
        return true
    end
    if button.m_Name and bindBrewGameAction(button) then
        RememberGameActionBind(button, "brew")
        return true
    end
    if type(button.GetName) == "function" then
        local actionName = button:GetName() .. "Action"
        if WindowSetGameActionData and DoesWindowExist(actionName) then
            local ok = TryCall(
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

function Macro.IsMacroButton(button)
    if not button or not IsDoMacroAction(button.m_ActionType) then
        return false
    end
    local macroId = Macro.GetMacroId()
    return macroId ~= nil and button.m_ActionId == macroId
end

function Macro.IsBrewMacroButton(button)
    if not button or not IsDoMacroAction(button.m_ActionType) then
        return false
    end
    local macroId = Macro.GetBrewMacroId()
    return macroId ~= nil and button.m_ActionId == macroId
end

function Macro.IsCraftMacroButton(button)
    if not button or not IsDoMacroAction(button.m_ActionType) then
        return false
    end
    local macroId = Macro.GetCraftMacroId()
    return macroId ~= nil and button.m_ActionId == macroId
end

local function FireHarvestFromMacroSlots(macroId)
    if type(WindowGameAction) ~= "function" or not ActionBars or not ActionBars.BarAndButtonIdFromSlot then
        return false
    end
    macroId = tonumber(macroId) or 0
    if macroId <= 0 then
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
        if not bindHarvestGameActionForButton(button, { force = true }) then
            return false
        end
        local ok = TryCall("WindowGameAction", WindowGameAction, actionName)
        return ok == true
    end
    local slots = Macro.GetMacroSlots(macroId) or {}
    for i = 1, #slots do
        local hbar, buttonId = ActionBars:BarAndButtonIdFromSlot(slots[i])
        local button = hbar and hbar.m_Buttons and hbar.m_Buttons[buttonId]
        if tryButton(button) then
            return true
        end
    end
    return false
end

--- Fire Cultivation PERFORM_CRAFTING via a placed Craft macro Action window.
function Macro.FireCraftHarvestGameAction()
    return FireHarvestFromMacroSlots(Macro.GetCraftMacroId())
end

--- Legacy: fire via an orphan Harvest macro slot (Craft-only no longer creates these).
function Macro.FireHarvestGameAction()
    return FireHarvestFromMacroSlots(Macro.GetMacroId())
end

--- Preferred harvest fire order: Craft bar → footer chrome → orphan Harvest slots.
function Macro.FireHarvestActionPreferred()
    if Macro.FireCraftHarvestGameAction() then
        return true
    end
    local Chrome = StockPiler.HarvestChrome
    if Chrome and Chrome.FireFooterHarvestAction and Chrome.FireFooterHarvestAction() == true then
        return true
    end
    return Macro.FireHarvestGameAction()
end

local function clearPickupIfMouse(flags)
    if SystemData and SystemData.ButtonFlags
        and flags ~= SystemData.ButtonFlags.GAME_ACTION
        and ActionBars and ActionBars.SetPickupButton
    then
        ActionBars:SetPickupButton(nil)
    end
end

function Macro.ApplyButtonAppearance(button, opts)
    if not button then
        return
    end
    opts = opts or {}
    local canUse = opts.canUse
    if canUse == nil then
        canUse = canHarvestMacro()
    else
        canUse = canUse == true
    end
    if canUse then
        bindHarvestGameActionForButton(button)
    else
        clearHarvestGameActionForButton(button)
    end
    setButtonEnabledVisual(button, canUse)
end

function Macro.ApplyBrewButtonAppearance(button, opts)
    if not button then
        return
    end
    opts = opts or {}
    local canUse = opts.canUse
    if canUse == nil then
        canUse = canBrewMacro()
    else
        canUse = canUse == true
    end
    -- Clear or bind before the tint. WindowSetGameActionData re-enables the slot;
    -- tinting first left Craft lit after the footer Brew button had already greyed.
    if canUse then
        bindBrewGameActionForButton(button)
    else
        clearBrewGameActionForButton(button)
    end
    setButtonEnabledVisual(button, canUse)
end

function Macro.ApplyCraftButtonAppearance(button, opts)
    if not button then
        return
    end
    opts = type(opts) == "table" and opts or {}
    local snap = opts.snap
    if type(snap) ~= "table" then
        snap = Macro.ResolveCraftMode({
            canHarvest = opts.canHarvest,
            canBrew = opts.canBrew,
        })
    end
    local iconMode = snap.iconMode or Macro._craftIconMode or "harvest"
    EnsureCraftMacroIcon(iconMode)
    local canUse = snap.craftCanUse == true
    -- Bind only when the slot is on the wrong action. Clearing every pass
    -- fired a hotbar echo that greys Craft after the tint, and the appearance
    -- key then skipped the repaint. Tint still runs every pass.
    if canUse and snap.mode == "harvest" then
        if not GameActionAlreadyBound(button, "harvest") then
            clearBrewGameActionForButton(button)
            bindHarvestGameActionForButton(button, { force = true })
        end
    elseif canUse and snap.mode == "brew" then
        if not GameActionAlreadyBound(button, "brew") then
            clearHarvestGameActionForButton(button)
            bindBrewGameActionForButton(button, { force = true })
        end
    elseif not GameActionAlreadyBound(button, "none") then
        clearHarvestGameActionForButton(button)
        clearBrewGameActionForButton(button)
        RememberGameActionBind(button, "none")
    end
    setButtonEnabledVisual(button, canUse)
    if StockPiler.CraftHarvestTimer and StockPiler.CraftHarvestTimer.Paint then
        StockPiler.CraftHarvestTimer.Paint(button)
    end
end

--- Paint every placed Craft button from the same booleans as the footers.
--- MACRO_UPDATED (icon swap) relights the slot after Apply; call this again then.
function Macro.ReapplyCraftEnable()
    if Macro._reapplyingCraft == true then
        return
    end
    if not ActionBars or not ActionBars.m_Bars then
        return
    end
    Macro._reapplyingCraft = true
    -- Keep the footer commit. A live CanHarvestNow() here can flicker false
    -- while the Harvest button is still lit and grey only this slot.
    local canHarvest = Macro._commitCanHarvest
    if canHarvest == nil then
        canHarvest = canHarvestMacro()
    else
        canHarvest = canHarvest == true
    end
    local canBrew = Macro._commitCanBrew
    if canBrew == nil then
        canBrew = canBrewMacro()
    else
        canBrew = canBrew == true
    end
    local snap = Macro.ResolveCraftMode({
        canHarvest = canHarvest,
        canBrew = canBrew,
    })
    local craftId = Macro.GetCraftMacroId()
    if craftId then
        local opts = {
            snap = snap,
            canHarvest = canHarvest,
            canBrew = canBrew,
        }
        ForEachActionButton(function(button)
            if Macro.IsCraftMacroButton(button) then
                Macro.ApplyCraftButtonAppearance(button, opts)
            end
        end)
    end
    Macro._craftIconEcho = false
    Macro._reapplyingCraft = false
end

--- Same booleans the footer just committed. Engine slot updates must not
--- recompute CanHarvestNow/CanBrewNow — that greys only Craft after Harvest
--- has already been painted, until some later refresh happens to repaint it.
local function committedWant(which)
    local h = Macro._commitCanHarvest
    local b = Macro._commitCanBrew
    if h == nil and b == nil then
        return nil
    end
    if which == "harvest" then
        return h == true
    end
    if which == "brew" then
        return b == true
    end
    return h == true or b == true
end

--- Cached ids are trusted without rescanning, so a slot the player rewrote
--- (e.g. old Harvest slot now holding /assist) must be dropped or that
--- button keeps getting our enable/bind/click overrides.
local function ForgetCachedMacroSlot(macroId)
    macroId = tonumber(macroId)
    local dropped = false
    if macroId == nil then
        Macro.MacroId = 0
        Macro.BrewMacroId = 0
        Macro.CraftMacroId = 0
        dropped = true
    else
        if tonumber(Macro.MacroId) == macroId then
            Macro.MacroId = 0
            dropped = true
        end
        if tonumber(Macro.BrewMacroId) == macroId then
            Macro.BrewMacroId = 0
            dropped = true
        end
        if tonumber(Macro.CraftMacroId) == macroId then
            Macro.CraftMacroId = 0
            dropped = true
        end
    end
    Macro._ourIds = nil
    return dropped
end

--- Hand a no-longer-ours macro slot back to stock: rebind its Action window
--- and drop our grey tint / forced enable state.
local function ReleaseForeignMacroButtons(macroId)
    RebuildOurMacroIds()
    if Macro._ourIds[macroId] == true then
        return
    end
    ForEachActionButton(function(button)
        if IsDoMacroAction(button.m_ActionType) and button.m_ActionId == macroId
            and type(button.SetActionData) == "function"
        then
            resetMacroIconTint(button)
            ForgetGameActionBind(button)
            button:SetActionData(button.m_ActionType, macroId)
        end
    end)
end

function Macro.OnMacrosLoaded()
    ForgetCachedMacroSlot(nil)
    RebuildOurMacroIds()
    Macro.RequestEnabledSync()
end

function Macro.OnMacroUpdated(macroId)
    if ForgetCachedMacroSlot(macroId) and tonumber(macroId) then
        ReleaseForeignMacroButtons(tonumber(macroId))
    else
        RebuildOurMacroIds()
    end
    local craftId = Macro.GetCraftMacroId()
    if craftId == nil or tonumber(macroId) ~= tonumber(craftId) then
        return
    end
    if Macro._refreshingAppearance == true
        or Macro._reapplyingCraft == true
        or Macro._aligningCraft == true
    then
        Macro._craftIconEcho = true
        return
    end
    Macro.ReapplyCraftEnable()
end

--- Coalesce hotbar enable sync (footer/cultivation storms). Drain via DrainEnabledSync.
function Macro.CancelPendingEnabledSync()
    Macro._enabledSyncPending = false
    Macro._pendingCanHarvest = nil
    Macro._pendingCanBrew = nil
end

function Macro.RequestEnabledSync(canHarvest, canBrew)
    Macro._enabledSyncPending = true
    if canHarvest ~= nil then
        Macro._pendingCanHarvest = canHarvest == true
    end
    if canBrew ~= nil then
        Macro._pendingCanBrew = canBrew == true
    end
end

--- Apply pending RequestEnabledSync once (EngineEventBridge.OnUpdateProcessed).
function Macro.DrainEnabledSync()
    if Macro._enabledSyncPending ~= true then
        return
    end
    Macro._enabledSyncPending = false
    local opts = {}
    if Macro._pendingCanHarvest ~= nil then
        opts.canHarvest = Macro._pendingCanHarvest
        Macro._pendingCanHarvest = nil
    end
    if Macro._pendingCanBrew ~= nil then
        opts.canBrew = Macro._pendingCanBrew
        Macro._pendingCanBrew = nil
    end
    Macro.RefreshMacroButtonAppearance(opts)
end

--- Next frame, force Craft/Harvest/Brew tint to match the footer booleans.
--- A hotbar echo after Perform re-enables the slot without changing readiness,
--- and the appearance-key check then skips the grey.
function Macro.ArmEnableReassert()
    local frame = tonumber(StockPiler.FrameCounter) or 0
    Macro._enableReassertAfter = frame
end

function Macro.DrainEnableReassert()
    local after = Macro._enableReassertAfter
    if after == nil then
        return
    end
    local frame = tonumber(StockPiler.FrameCounter) or 0
    if frame <= after then
        return
    end
    Macro._enableReassertAfter = nil
    Macro._lastAppearanceKey = nil
    Macro.RefreshMacroButtonAppearance({
        canHarvest = canHarvestMacro(),
        canBrew = canBrewMacro(),
    })
end

--- Paint Craft from the footer booleans on every readiness pass.
--- Harvest/Brew already stick; Craft was skipped once the appearance key
--- matched, so a macro-icon echo could leave it grey until a later refresh.
function Macro.AlignCraftEnable(canHarvest, canBrew)
    canHarvest = canHarvest == true
    canBrew = canBrew == true
    Macro._commitCanHarvest = canHarvest
    Macro._commitCanBrew = canBrew
    if Macro._aligningCraft == true
        or Macro._reapplyingCraft == true
        or Macro._refreshingAppearance == true
    then
        return
    end
    if not ActionBars or not ActionBars.m_Bars then
        return
    end
    local frame = tonumber(StockPiler.FrameCounter) or 0
    local snap = Macro.ResolveCraftMode({
        canHarvest = canHarvest,
        canBrew = canBrew,
    })
    local key = tostring(canHarvest) .. ":" .. tostring(canBrew)
        .. ":" .. tostring(snap.mode or "idle")
        .. ":" .. tostring(snap.iconMode or "harvest")
        .. ":" .. tostring(snap.craftCanUse == true)
    if Macro._alignCraftFrame == frame and Macro._alignCraftKey == key then
        return
    end
    Macro._alignCraftFrame = frame
    Macro._alignCraftKey = key
    local craftId = Macro.GetCraftMacroId()
    if not craftId then
        return
    end
    Macro._aligningCraft = true
    local ok, err = pcall(function()
        RebuildOurMacroIds()
        local opts = {
            snap = snap,
            canHarvest = canHarvest,
            canBrew = canBrew,
        }
        local paintedCraft = 0
        ForEachActionButton(function(button)
            if Macro.IsCraftMacroButton(button) then
                Macro.ApplyCraftButtonAppearance(button, opts)
                paintedCraft = paintedCraft + 1
            end
        end)
        if paintedCraft > 0 then
            Macro._craftUnpainted = false
        end
    end)
    Macro._aligningCraft = false
    if ok ~= true then
        D("align craft failed: " .. tostring(err))
    end
    if Macro._craftIconEcho == true then
        Macro._craftIconEcho = false
        Macro.ReapplyCraftEnable()
    end
end

function Macro.RefreshMacroButtonAppearance(opts)
    opts = type(opts) == "table" and opts or {}
    if Macro._refreshingAppearance == true then
        Macro._appearanceDirty = true
        if opts.canHarvest ~= nil then
            Macro._pendingCanHarvest = opts.canHarvest == true
        end
        if opts.canBrew ~= nil then
            Macro._pendingCanBrew = opts.canBrew == true
        end
        return
    end
    if not ActionBars or not ActionBars.m_Bars then
        return
    end

    local canHarvest = opts.canHarvest
    if canHarvest == nil then
        canHarvest = canHarvestMacro()
    else
        canHarvest = canHarvest == true
    end
    local canBrew = opts.canBrew
    if canBrew == nil then
        canBrew = canBrewMacro()
    else
        canBrew = canBrew == true
    end
    local craftSnap = Macro.ResolveCraftMode({
        canHarvest = canHarvest,
        canBrew = canBrew,
    })
    local craftMode = tostring(craftSnap.mode or "idle")
    local craftIconMode = tostring(craftSnap.iconMode or Macro._craftIconMode or "harvest")
    local craftCanUse = craftSnap.craftCanUse == true
    Macro._commitCanHarvest = canHarvest
    Macro._commitCanBrew = canBrew
    local appearanceKey = tostring(canHarvest) .. ":" .. tostring(canBrew)
        .. ":" .. craftMode .. ":" .. craftIconMode .. ":" .. tostring(craftCanUse)
    if Macro._lastAppearanceKey == appearanceKey then
        -- Harvest/Brew already match. Still retint Craft: an icon echo can
        -- grey that slot alone without changing this key.
        Macro.AlignCraftEnable(canHarvest, canBrew)
        return
    end

    local prevKey = Macro._lastAppearanceKey
    local applyHarvest = true
    local applyBrew = true
    local applyCraft = true
    if type(prevKey) == "string" then
        local ph, pb = string.match(prevKey, "^([^:]+):([^:]+)")
        if ph ~= nil then
            applyHarvest = tostring(canHarvest) ~= ph
            applyBrew = tostring(canBrew) ~= pb
            -- Always with Harvest and Brew. A skipped Craft pass stayed grey
            -- after the icon reload until some later refresh.
            applyCraft = true
        else
            -- Legacy two-field key from older builds: refresh all.
            applyHarvest = true
            applyBrew = true
            applyCraft = true
        end
    end

    local Perf = StockPiler.Perf
    if Perf and Perf.Begin then
        Perf.Begin("Macro.Appearance")
    end
    Macro._refreshingAppearance = true
    local ok, err = pcall(function()
        Macro._lastAppearanceKey = appearanceKey
        -- Forced wants for UpdateEnabledState hook (avoid re-CanBrewNow per button).
        Macro._refreshCanHarvest = canHarvest
        Macro._refreshCanBrew = canBrew
        Macro._refreshCraftCanUse = craftCanUse
        Macro._refreshCraftSnap = craftSnap

        RebuildOurMacroIds()
        local macroId = Macro.GetMacroId()
        local brewId = Macro.GetBrewMacroId()
        local craftId = Macro.GetCraftMacroId()
        local harvestOpts = { canUse = canHarvest }
        local brewOpts = { canUse = canBrew }
        local craftOpts = {
            snap = craftSnap,
            canHarvest = canHarvest,
            canBrew = canBrew,
        }

        local paintedHarvest = 0
        local paintedBrew = 0
        local paintedCraft = 0
        if applyCraft and craftId then
            EnsureCraftMacroIcon(craftIconMode)
        end
        ForEachActionButton(function(button)
            if applyHarvest and macroId and Macro.IsMacroButton(button) then
                Macro.ApplyButtonAppearance(button, harvestOpts)
                paintedHarvest = paintedHarvest + 1
            elseif applyBrew and brewId and Macro.IsBrewMacroButton(button) then
                Macro.ApplyBrewButtonAppearance(button, brewOpts)
                paintedBrew = paintedBrew + 1
            elseif applyCraft and craftId and Macro.IsCraftMacroButton(button) then
                Macro.ApplyCraftButtonAppearance(button, craftOpts)
                paintedCraft = paintedCraft + 1
            end
        end)
        -- Harvest/Brew orphans: paint if on a bar; never nag about unplaced.
        if applyHarvest and macroId and paintedHarvest > 0 then
            Macro.MacroWarningState.unplaced = false
        end
        if applyBrew and brewId and paintedBrew > 0 then
            Macro.BrewMacroWarningState.unplaced = false
        end
        if applyCraft and craftId then
            if paintedCraft == 0 then
                -- Button was not on a bar yet. Later syncs retry without
                -- repainting Harvest and Brew (appearance key stays).
                Macro._craftUnpainted = true
            else
                Macro._craftUnpainted = false
            end
            Macro.WarnIfCraftUnplaced()
        end
        RememberSlotFingerprint()
    end)
    Macro._refreshingAppearance = false
    Macro._refreshCanHarvest = nil
    Macro._refreshCanBrew = nil
    Macro._refreshCraftCanUse = nil
    Macro._refreshCraftSnap = nil
    if Perf and Perf.End then
        Perf.End("Macro.Appearance")
    end
    if ok ~= true then
        D("refresh failed: " .. tostring(err))
    end
    if Macro._hotbarEcho == true or Macro._craftIconEcho == true then
        Macro._hotbarEcho = false
        Macro._craftIconEcho = false
        Macro.ArmEnableReassert()
    end
    if Macro._appearanceDirty == true then
        Macro._appearanceDirty = false
        -- Keep _lastAppearanceKey; key check no-ops if can-state unchanged.
        local dirtyOpts = {}
        if Macro._pendingCanHarvest ~= nil then
            dirtyOpts.canHarvest = Macro._pendingCanHarvest
            Macro._pendingCanHarvest = nil
        end
        if Macro._pendingCanBrew ~= nil then
            dirtyOpts.canBrew = Macro._pendingCanBrew
            Macro._pendingCanBrew = nil
        end
        Macro.RefreshMacroButtonAppearance(dirtyOpts)
    end
end

--- Harvest/brew pair from the last appearance key (footer compares this, not the 5-field craft key).
function Macro.GetReadinessKey()
    local key = Macro._lastAppearanceKey
    if type(key) ~= "string" or key == "" then
        return nil
    end
    local h, b = string.match(key, "^([^:]+):([^:]+)")
    if h == nil then
        return key
    end
    return h .. ":" .. b
end

--- Queue hotbar enable sync (coalesced). Prefer RequestEnabledSync from callers.
function Macro.SyncEnabledState(canHarvest, canBrew)
    Macro.RequestEnabledSync(canHarvest, canBrew)
end

local function applySetActionDataAppearance(button, actionType, actionId)
    if not button then
        return
    end
    if not IsDoMacroAction(actionType) then
        return
    end
    local harvestId = Macro.GetMacroId()
    local brewId = Macro.GetBrewMacroId()
    local craftId = Macro.GetCraftMacroId()
    if harvestId ~= nil and actionId == harvestId then
        Macro.ApplyButtonAppearance(button)
        return
    end
    if brewId ~= nil and actionId == brewId then
        Macro.ApplyBrewButtonAppearance(button)
        return
    end
    if craftId ~= nil and actionId == craftId then
        Macro.ApplyCraftButtonAppearance(button, {
            canHarvest = Macro._commitCanHarvest,
            canBrew = Macro._commitCanBrew,
        })
    end
end

local function installSetActionDataHook()
    if not ActionButton or type(ActionButton.SetActionData) ~= "function" then
        return
    end
    if setActionDataHooked then
        return
    end
    orgSetActionDataFn = ActionButton.SetActionData
    hookedSetActionDataFn = function(self, actionType, actionId)
        local wasOurs = ButtonIsOurs(self)
        orgSetActionDataFn(self, actionType, actionId)
        local isOurs = ButtonIsOurs(self)
        if wasOurs and not isOurs then
            restoreVacatedMacroSlot(self)
            return
        end
        if isOurs then
            applySetActionDataAppearance(self, actionType, actionId)
        end
    end
    ActionButton.SetActionData = hookedSetActionDataFn
    setActionDataHooked = true
end

--- Engine ActionBars.UpdateSlotEnabledState / SetActionData re-enable DO_MACRO slots
--- after StockPiler greys them. Appearance-key early-out then skips re-apply until Harvest
--- readiness flips - Brew stays lit while footer is correctly grey. Force our
--- readiness on every UpdateEnabledState for our macros.
local function installUpdateEnabledStateHook()
    if not ActionButton or type(ActionButton.UpdateEnabledState) ~= "function" then
        return
    end
    if updateEnabledStateHooked then
        return
    end
    orgUpdateEnabledStateFn = ActionButton.UpdateEnabledState
    hookedUpdateEnabledStateFn = function(self, isSlotEnabled, isTargetValid, isBlocked)
        if not ButtonIsOurs(self) then
            return orgUpdateEnabledStateFn(self, isSlotEnabled, isTargetValid, isBlocked)
        end
        local forced = false
        local want = false
        -- Do not fall back to "ours but not harvest/brew ⇒ craft". A stale
        -- _ourIds entry for Assist would then clear that slot's Action bind.
        local isCraft = Macro.IsCraftMacroButton(self)
        if isCraft then
            forced = true
            if Macro._refreshingAppearance == true and Macro._refreshCraftCanUse ~= nil then
                want = Macro._refreshCraftCanUse == true
            else
                local committed = committedWant("craft")
                if committed ~= nil then
                    want = committed
                else
                    local snap = Macro.ResolveCraftMode({ readonly = true })
                    want = snap.craftCanUse == true
                end
            end
        elseif Macro.IsBrewMacroButton(self) then
            forced = true
            if Macro._refreshingAppearance == true and Macro._refreshCanBrew ~= nil then
                want = Macro._refreshCanBrew == true
            else
                local committed = committedWant("brew")
                if committed ~= nil then
                    want = committed
                else
                    want = canBrewMacro()
                end
            end
        elseif Macro.IsMacroButton(self) then
            forced = true
            if Macro._refreshingAppearance == true and Macro._refreshCanHarvest ~= nil then
                want = Macro._refreshCanHarvest == true
            else
                local committed = committedWant("harvest")
                if committed ~= nil then
                    want = committed
                else
                    want = canHarvestMacro()
                end
            end
        end
        if forced then
            isSlotEnabled = want
            isTargetValid = true
            isBlocked = false
        end
        orgUpdateEnabledStateFn(self, isSlotEnabled, isTargetValid, isBlocked)
        if forced and want ~= true then
            -- Drop a leftover PERFORM_CRAFTING bind or the slot stays bright
            -- after the footer button has already been disabled.
            if Macro._clearingBind ~= true then
                Macro._clearingBind = true
                local cleared, clearErr = pcall(function()
                    if isCraft then
                        clearHarvestGameActionForButton(self)
                        clearBrewGameActionForButton(self)
                    elseif Macro.IsBrewMacroButton(self) then
                        clearBrewGameActionForButton(self)
                    elseif Macro.IsMacroButton(self) then
                        clearHarvestGameActionForButton(self)
                    end
                    forceGreyMacroIcon(self)
                end)
                Macro._clearingBind = false
                if cleared ~= true and StockPiler.Debug
                    and StockPiler.Debug.ReportProtectedCallFailure
                then
                    StockPiler.Debug.ReportProtectedCallFailure(
                        "Macro.UpdateEnabledState", clearErr, true)
                end
            end
        end
    end
    ActionButton.UpdateEnabledState = hookedUpdateEnabledStateFn
    updateEnabledStateHooked = true
end

--- MACRO_UPDATED -> UpdateIcon reloads the Craft icon and can leave that slot
--- grey while Harvest stays lit. Re-apply the last painted footer booleans.
local function installUpdateIconHook()
    if not ActionButton or type(ActionButton.UpdateIcon) ~= "function" then
        return
    end
    if Macro._updateIconHooked == true then
        return
    end
    orgUpdateIconFn = ActionButton.UpdateIcon
    hookedUpdateIconFn = function(self)
        orgUpdateIconFn(self)
        if Macro._inIconRefresh == true or not ButtonIsOurs(self) then
            return
        end
        Macro._inIconRefresh = true
        local painted, paintErr = pcall(function()
            local canHarvest = Macro._commitCanHarvest
            local canBrew = Macro._commitCanBrew
            if Macro.IsCraftMacroButton(self) then
                if canHarvest == nil then
                    canHarvest = canHarvestMacro()
                end
                if canBrew == nil then
                    canBrew = canBrewMacro()
                end
                Macro.ApplyCraftButtonAppearance(self, {
                    canHarvest = canHarvest == true,
                    canBrew = canBrew == true,
                })
            elseif Macro.IsMacroButton(self) then
                if canHarvest == nil then
                    canHarvest = canHarvestMacro()
                end
                Macro.ApplyButtonAppearance(self, { canUse = canHarvest == true })
            elseif Macro.IsBrewMacroButton(self) then
                if canBrew == nil then
                    canBrew = canBrewMacro()
                end
                Macro.ApplyBrewButtonAppearance(self, { canUse = canBrew == true })
            end
        end)
        Macro._inIconRefresh = false
        if painted ~= true and StockPiler.Debug
            and StockPiler.Debug.ReportProtectedCallFailure
        then
            StockPiler.Debug.ReportProtectedCallFailure("Macro.UpdateIcon", paintErr, true)
        end
    end
    ActionButton.UpdateIcon = hookedUpdateIconFn
    Macro._updateIconHooked = true
end

local function handleMacroHarvestActivation(flags)
    if Cursor and Cursor.IconOnCursor and Cursor.IconOnCursor() then
        return "cursor"
    end
    local Grow = StockPiler.Grow
    if not (Grow and Grow.CanHarvestNow) or Grow.CanHarvestNow() ~= true then
        clearPickupIfMouse(flags)
        return "blocked"
    end
    if Grow and Grow.PrepareHarvestPlot then
        if Grow.PrepareHarvestPlot(true) ~= true then
            clearPickupIfMouse(flags)
            return "blocked"
        end
    end
    return "go"
end

local function handleMacroBrewActivation(flags)
    if Cursor and Cursor.IconOnCursor and Cursor.IconOnCursor() then
        return "cursor"
    end
    if not canBrewMacro() then
        clearPickupIfMouse(flags)
        return "blocked"
    end
    if not (StockPiler.Brew and StockPiler.Brew.TryBrewClick) then
        clearPickupIfMouse(flags)
        return "blocked"
    end
    local result = StockPiler.Brew.TryBrewClick()
    if result == "go" then
        return "go"
    end
    clearPickupIfMouse(flags)
    return "blocked"
end

local function installActionButtonHooks()
    if actionButtonHooksInstalled or not ActionButton then
        return
    end

    local orgOnLButtonUp = ActionButton.OnLButtonUp
    orgOnLButtonUpFn = orgOnLButtonUp
    if not orgOnLButtonUp then
        return
    end
    RebuildOurMacroIds()
    local DO_MACRO = GameData.PlayerActions.DO_MACRO
    -- Foreign buttons must reach the tail call with field reads only: the
    -- client drops /assist from a hotbar macro if addon code calls a Lua
    -- function while the click is handled. Compare against the cached ids
    -- here; ButtonIsOurs re-verifies them for our own buttons.
    hookedOnLButtonUpFn = function(self, flags, x, y)
        local id = self and self.m_ActionType == DO_MACRO and self.m_ActionId
        if not id or (id ~= Macro.MacroId and id ~= Macro.BrewMacroId and id ~= Macro.CraftMacroId) then
            return orgOnLButtonUp(self, flags, x, y)
        end
        if not ButtonIsOurs(self) then
            return orgOnLButtonUp(self, flags, x, y)
        end
        if Macro.IsCraftMacroButton(self) then
            -- Disabled and idle branches return before harvest activation,
            -- which is where the cursor check lives. Pass the click through
            -- so a held item or ability can still land on this button.
            if Cursor and Cursor.IconOnCursor and Cursor.IconOnCursor() then
                return orgOnLButtonUp(self, flags, x, y)
            end
            local snap = Macro.ResolveCraftMode()
            if snap.craftCanUse == true then
                Macro.ApplyCraftButtonAppearance(self, { snap = snap })
            end
            if snap.mode == "harvest" then
                if snap.craftCanUse ~= true then
                    clearHarvestGameActionForButton(self)
                    clearBrewGameActionForButton(self)
                    clearPickupIfMouse(flags)
                    return
                end
                bindHarvestGameActionForButton(self, { force = true })
                local result = handleMacroHarvestActivation(flags)
                if result == "cursor" or result == "go" then
                    return orgOnLButtonUp(self, flags, x, y)
                end
                if result == "blocked" then
                    return
                end
            elseif snap.mode == "brew" then
                local result = handleMacroBrewActivation(flags)
                if result == "cursor" then
                    return orgOnLButtonUp(self, flags, x, y)
                end
                if result == "go" then
                    Macro._brewFired = true
                    Macro._brewFiredAt = (type(GetGameTime) == "function" and tonumber(GetGameTime())) or 0
                    if StockPiler.Brew and StockPiler.Brew.FirePerform then
                        StockPiler.Brew.FirePerform()
                    end
                    return
                end
                if result == "blocked" then
                    -- Load click returns blocked after BeginLoadJob - correct.
                    return
                end
            else
                clearHarvestGameActionForButton(self)
                clearBrewGameActionForButton(self)
                clearPickupIfMouse(flags)
                return
            end
        elseif Macro.IsMacroButton(self) then
            if Cursor and Cursor.IconOnCursor and Cursor.IconOnCursor() then
                return orgOnLButtonUp(self, flags, x, y)
            end
            if not canHarvestMacro() then
                clearHarvestGameActionForButton(self)
                clearPickupIfMouse(flags)
                return
            end
            bindHarvestGameActionForButton(self, { force = true })
            local result = handleMacroHarvestActivation(flags)
            if result == "cursor" or result == "go" then
                return orgOnLButtonUp(self, flags, x, y)
            end
            if result == "blocked" then
                return
            end
        elseif Macro.IsBrewMacroButton(self) then
            local result = handleMacroBrewActivation(flags)
            if result == "cursor" then
                return orgOnLButtonUp(self, flags, x, y)
            end
            if result == "go" then
                -- Suppress BrewClick if the engine also runs the macro script this frame.
                Macro._brewFired = true
                Macro._brewFiredAt = (type(GetGameTime) == "function" and tonumber(GetGameTime())) or 0
                if StockPiler.Brew and StockPiler.Brew.FirePerform then
                    StockPiler.Brew.FirePerform()
                end
                return
            end
            if result == "blocked" then
                return
            end
        end
        return orgOnLButtonUp(self, flags, x, y)
    end
    ActionButton.OnLButtonUp = hookedOnLButtonUpFn

    actionButtonHooksInstalled = true
end

--- Stock ability tips use ActionButton:OnMouseOver's anchor
--- { Point="top", RelativePoint="bottom", YOffset=-50 } on AbilityTooltip.
--- That window is zero-size and its content grows upward from the origin, so
--- the tip sits above the button. DefaultTooltip grows downward from its top;
--- pin its bottom-left to the same point or the macro tip covers the bar.
local function AnchorLikeAbilityTooltip(anchor)
    if type(anchor) ~= "table" then
        return anchor
    end
    if anchor.Point == "top"
        and anchor.RelativePoint == "bottom"
        and (tonumber(anchor.YOffset) or 0) == -50
    then
        return {
            Point = "bottomleft",
            RelativeTo = anchor.RelativeTo,
            RelativePoint = "bottom",
            XOffset = tonumber(anchor.XOffset) or 0,
            YOffset = -50,
        }
    end
    return anchor
end

local function installMacroTooltipHook()
    if tooltipHookInstalled or not Tooltips or type(Tooltips.CreateMacroTooltip) ~= "function" then
        return
    end
    orgCreateMacroTooltipFn = Tooltips.CreateMacroTooltip
    hookedCreateMacroTooltipFn = function(macroData, mouseoverWindow, anchor, extraText)
        local harvestId = Macro.GetMacroId()
        local brewId = Macro.GetBrewMacroId()
        local craftId = Macro.GetCraftMacroId()
        local isHarvest = false
        local isBrew = false
        local isCraft = false
        if type(macroData) == "table" then
            if craftId and (macroData.slot == craftId or macroData.index == craftId or macroData.macroIndex == craftId) then
                isCraft = true
            elseif IsOurMacroData(macroData, CRAFT_MACRO_NAME, CRAFT_MACRO_TEXT) then
                isCraft = true
            end
            if not isCraft then
                if harvestId and (macroData.slot == harvestId or macroData.index == harvestId or macroData.macroIndex == harvestId) then
                    isHarvest = true
                elseif IsOurMacroData(macroData, MACRO_NAME, MACRO_TEXT) then
                    isHarvest = true
                end
                if brewId and (macroData.slot == brewId or macroData.index == brewId or macroData.macroIndex == brewId) then
                    isBrew = true
                elseif IsOurMacroData(macroData, BREW_MACRO_NAME, BREW_MACRO_TEXT) then
                    isBrew = true
                end
            end
        end
        local tipAnchor = AnchorLikeAbilityTooltip(anchor) or Tooltips.ANCHOR_WINDOW_TOP
        if isCraft then
            if StockPiler.CraftTooltip and StockPiler.CraftTooltip.Show then
                StockPiler.CraftTooltip.Show(mouseoverWindow, tipAnchor)
            end
            return
        end
        if isHarvest then
            if StockPiler.HarvestTooltip and StockPiler.HarvestTooltip.Show then
                StockPiler.HarvestTooltip.Show(mouseoverWindow, tipAnchor)
            end
            return
        end
        if isBrew then
            if StockPiler.BrewTooltip and StockPiler.BrewTooltip.Show then
                StockPiler.BrewTooltip.Show(mouseoverWindow, tipAnchor)
            end
            return
        end
        return orgCreateMacroTooltipFn(macroData, mouseoverWindow, anchor, extraText)
    end
    Tooltips.CreateMacroTooltip = hookedCreateMacroTooltipFn
    tooltipHookInstalled = true
end

function Macro.OnHotBarUpdated()
    -- ApplyButtonAppearance / WindowSetGameActionData can fire this event while
    -- we refresh. Ignoring those echoes stops Macro.Appearance xN under trail hold.
    -- Still reassert next frame: the echo re-enables the slot after we grey it.
    if Macro._refreshingAppearance == true then
        Macro._hotbarEcho = true
        return
    end
    -- Rescan bars for fingerprint; only clear bind cache when slots actually moved.
    InvalidateSlotCache()
    local fp = SlotFingerprint()
    -- Unrelated hotbar noise must not wipe appearance key / force Begin - that
    -- was Macro.Appearance x67 storms under trail hold (0.4.23 uilog).
    if Macro._lastSlotFingerprint == fp then
        return
    end
    ClearGameActionBindCache()
    Macro._lastSlotFingerprint = fp
    Macro._lastAppearanceKey = nil
    Macro.WarnIfCraftUnplaced()
    if Macro._enabledSyncPending == true then
        return
    end
    Macro.RequestEnabledSync()
end

function Macro.RegisterHotbarEventHandler()
    if hotbarEventRegistered or not SystemData or not SystemData.Events then
        return
    end
    if SystemData.Events.PLAYER_HOT_BAR_UPDATED then
        RegisterEventHandler(SystemData.Events.PLAYER_HOT_BAR_UPDATED, "StockPiler.Macro.OnHotBarUpdated")
        hotbarEventRegistered = true
    end
    if SystemData.Events.MACRO_UPDATED then
        RegisterEventHandler(SystemData.Events.MACRO_UPDATED, "StockPiler.Macro.OnMacroUpdated")
    end
    if SystemData.Events.MACROS_LOADED then
        RegisterEventHandler(SystemData.Events.MACROS_LOADED, "StockPiler.Macro.OnMacrosLoaded")
    end
end

function Macro.UnregisterHotbarEventHandler()
    if not hotbarEventRegistered or not SystemData or not SystemData.Events then
        return
    end
    if SystemData.Events.PLAYER_HOT_BAR_UPDATED then
        UnregisterEventHandler(SystemData.Events.PLAYER_HOT_BAR_UPDATED, "StockPiler.Macro.OnHotBarUpdated")
    end
    if SystemData.Events.MACRO_UPDATED then
        UnregisterEventHandler(SystemData.Events.MACRO_UPDATED, "StockPiler.Macro.OnMacroUpdated")
    end
    if SystemData.Events.MACROS_LOADED then
        UnregisterEventHandler(SystemData.Events.MACROS_LOADED, "StockPiler.Macro.OnMacrosLoaded")
    end
    hotbarEventRegistered = false
end

function Macro.HarvestClick()
    local Grow = StockPiler.Grow
    if not Grow then
        return
    end
    if Grow.CanHarvestNow and Grow.CanHarvestNow() ~= true then
        return
    end
    if Grow.PrepareHarvestPlot and Grow.PrepareHarvestPlot(true) ~= true then
        return
    end
    if Macro.FireHarvestActionPreferred() then
        return
    end
    if Grow.HarvestClick then
        Grow.HarvestClick()
    end
end

--- Once per placement gap: Craft exists but is not on a hotbar.
function Macro.WarnIfCraftUnplaced()
    if not ActionBars or not ActionBars.m_Bars then
        return
    end
    local craftId = Macro.GetCraftMacroId()
    if not craftId then
        return
    end
    local slots = Macro.GetMacroSlots(craftId) or {}
    if #slots > 0 then
        Macro.CraftMacroWarningState.unplaced = false
        return
    end
    if Macro.CraftMacroWarningState.unplaced == true then
        return
    end
    Macro.CraftMacroWarningState.unplaced = true
    local msg = T("macro.craft_unplaced")
    if StockPiler.Debug and StockPiler.Debug.Print then
        StockPiler.Debug.Print(msg, "force")
    else
        Print(msg)
    end
end

--- One-time tip: legacy Harvest/Brew on a bar while Craft is unplaced.
function Macro.MaybeTipCraftOnly()
    local s = StockPiler.Settings
    if type(s) ~= "table" or s._craftOnlyTipShown == true then
        return
    end
    local craftId = Macro.GetCraftMacroId()
    if not craftId then
        return
    end
    local craftSlots = Macro.GetMacroSlots(craftId) or {}
    if #craftSlots > 0 then
        s._craftOnlyTipShown = true
        return
    end
    local hasLegacyOnBar = false
    local harvestId = Macro.GetMacroId()
    local brewId = Macro.GetBrewMacroId()
    if harvestId then
        local slots = Macro.GetMacroSlots(harvestId) or {}
        if #slots > 0 then
            hasLegacyOnBar = true
        end
    end
    if not hasLegacyOnBar and brewId then
        local slots = Macro.GetMacroSlots(brewId) or {}
        if #slots > 0 then
            hasLegacyOnBar = true
        end
    end
    if not hasLegacyOnBar then
        return
    end
    s._craftOnlyTipShown = true
    Print(T("macro.craft_only_tip", {
        icon = tostring(CraftIconIdForMode(Macro._craftIconMode or "harvest")),
    }))
end

function Macro.BrewClick()
    Macro.ExpireBrewFiredGuard()
    if Macro._brewFired == true then
        Macro._brewFired = false
        Macro._brewFiredAt = nil
        return
    end
    if not canBrewMacro() then
        return
    end
    local Brew = StockPiler.Brew
    if not Brew or not Brew.TryBrewClick then
        return
    end
    local result = Brew.TryBrewClick()
    if result == "go" and Brew.FirePerform then
        Brew.FirePerform()
    end
end

function Macro.CraftClick()
    Macro.ExpireBrewFiredGuard()
    if Macro._brewFired == true then
        Macro._brewFired = false
        Macro._brewFiredAt = nil
        return
    end
    local snap = Macro.ResolveCraftMode()
    if snap.mode == "harvest" then
        if snap.craftCanUse ~= true then
            return
        end
        local Grow = StockPiler.Grow
        if not Grow then
            return
        end
        if Grow.PrepareHarvestPlot and Grow.PrepareHarvestPlot(true) ~= true then
            return
        end
        if Macro.FireHarvestActionPreferred() then
            return
        end
        if Grow.HarvestClick then
            Grow.HarvestClick()
        end
        return
    end
    if snap.mode == "brew" then
        if snap.craftCanUse ~= true then
            return
        end
        local Brew = StockPiler.Brew
        if not Brew or not Brew.TryBrewClick then
            return
        end
        local result = Brew.TryBrewClick()
        if result == "go" and Brew.FirePerform then
            Brew.FirePerform()
        end
    end
end

--- Drop sticky _brewFired if BrewClick never ran after OnLButtonUp FirePerform.
function Macro.ExpireBrewFiredGuard()
    if Macro._brewFired ~= true then
        return
    end
    local at = tonumber(Macro._brewFiredAt) or 0
    local now = (type(GetGameTime) == "function" and tonumber(GetGameTime())) or 0
    if at <= 0 or now <= 0 or (now - at) >= 0.25 then
        Macro._brewFired = false
        Macro._brewFiredAt = nil
    end
end

function Macro.Initialize()
    if Macro._initialized then
        -- Craft-only create; refresh orphan Harvest/Brew text if still present.
        Macro.UpdateMacro()
        Macro.UpdateBrewMacro()
    Macro.UpdateCraftMacro()
    Macro.WarnIfCraftUnplaced()
    Macro.MaybeTipCraftOnly()
    Macro.RefreshMacroButtonAppearance()
        return
    end
    installSetActionDataHook()
    installUpdateEnabledStateHook()
    installUpdateIconHook()
    installActionButtonHooks()
    installMacroTooltipHook()
    if StockPiler.CraftHarvestTimer and StockPiler.CraftHarvestTimer.Install then
        StockPiler.CraftHarvestTimer.Install()
    end
    Macro.UpdateMacro()
    Macro.UpdateBrewMacro()
    Macro.UpdateCraftMacro()
    Macro.WarnIfCraftUnplaced()
    Macro.MaybeTipCraftOnly()
    Macro.RegisterHotbarEventHandler()
    Macro.RefreshMacroButtonAppearance()
    Macro._initialized = true
    D("Initialize harvestId=" .. tostring(Macro.GetMacroId())
        .. " brewId=" .. tostring(Macro.GetBrewMacroId())
        .. " craftId=" .. tostring(Macro.GetCraftMacroId()))
end

function Macro.Shutdown()
    if StockPiler.CraftHarvestTimer and StockPiler.CraftHarvestTimer.Shutdown then
        StockPiler.CraftHarvestTimer.Shutdown()
    end
    Macro.UnregisterHotbarEventHandler()
    if ActionButton and hookedSetActionDataFn and ActionButton.SetActionData == hookedSetActionDataFn then
        ActionButton.SetActionData = orgSetActionDataFn
    end
    if ActionButton and hookedUpdateEnabledStateFn and ActionButton.UpdateEnabledState == hookedUpdateEnabledStateFn then
        ActionButton.UpdateEnabledState = orgUpdateEnabledStateFn
    end
    -- Restore only our wrapper. A later addon that wrapped UpdateIcon
    -- after us keeps its function; clobbering it would drop that hook.
    if ActionButton and hookedUpdateIconFn and ActionButton.UpdateIcon == hookedUpdateIconFn then
        ActionButton.UpdateIcon = orgUpdateIconFn
        orgUpdateIconFn = nil
        hookedUpdateIconFn = nil
        Macro._updateIconHooked = false
    end
    if ActionButton and hookedOnLButtonUpFn and ActionButton.OnLButtonUp == hookedOnLButtonUpFn then
        ActionButton.OnLButtonUp = orgOnLButtonUpFn
    end
    if Tooltips and hookedCreateMacroTooltipFn and Tooltips.CreateMacroTooltip == hookedCreateMacroTooltipFn then
        Tooltips.CreateMacroTooltip = orgCreateMacroTooltipFn
    end
    setActionDataHooked = false
    updateEnabledStateHooked = false
    actionButtonHooksInstalled = false
    tooltipHookInstalled = false
    Macro._initialized = false
end
