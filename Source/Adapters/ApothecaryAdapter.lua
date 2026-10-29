----------------------------------------------------------------
-- StockPiler Adapters/ApothecaryAdapter - open/load/perform/close
----------------------------------------------------------------

StockPiler = StockPiler or {}
StockPiler.ApothecaryAdapter = StockPiler.ApothecaryAdapter or {}
local AA = StockPiler.ApothecaryAdapter

local function TryCall(label, fn, ...)
    return StockPiler.Util.TryCall(label, fn, ...)
end

local function TryQuiet(label, fn, ...)
    return StockPiler.Util.TryCallQuiet(label, fn, ...)
end

--- Crafting-bag reads go through GetCraftingItems, which clears the normal
--- backpack dirty flag. Restore a pending flag after the read, including
--- when the call errors. Inventory reads are left unchanged.
local function CaptureItemsDirty()
    local player = _G.GameData and _G.GameData.Player
    return type(player) == "table" and player.itemsDirty == true
end

local function RestorePendingItemsDirty(hadItemsDirty)
    if hadItemsDirty ~= true then
        return
    end
    if type(_G.GameData) ~= "table" or type(_G.GameData.Player) ~= "table" then
        return
    end
    if _G.GameData.Player.itemsDirty ~= true then
        _G.GameData.Player.itemsDirty = true
    end
end

local function ReadCraftBackpack(bagType)
    local hadItemsDirty = CaptureItemsDirty()
    local ok, items = pcall(EA_Window_Backpack.GetItemsFromBackpack, bagType)
    RestorePendingItemsDirty(hadItemsDirty)
    if ok ~= true then
        return nil
    end
    return items
end

local function RemoveEntry(apo, slot, backpack, seen)
    if slot == nil or backpack == nil then
        return false
    end
    local key = tostring(backpack) .. ":" .. tostring(slot)
    if type(seen) == "table" then
        if seen[key] then
            return false
        end
        seen[key] = true
    end
    if type(RemoveCraftingItem) == "function" then
        TryCall("RemoveCraftingItem", RemoveCraftingItem, apo, slot, backpack)
        return true
    end
    return false
end

function AA.TradeSkill()
    local Caps = StockPiler.TradeSkillCaps
    if Caps and Caps.ApothecaryId then
        return Caps.ApothecaryId()
    end
    return 4
end

function AA.CraftingBackpackType()
    if EA_Window_Backpack and EA_Window_Backpack.TYPE_CRAFTING then
        return EA_Window_Backpack.TYPE_CRAFTING
    end
    return 4
end

function AA.WindowName()
    if type(ApothecaryWindow) == "table" and type(ApothecaryWindow.windowName) == "string" then
        return ApothecaryWindow.windowName
    end
    return "ApothecaryWindow"
end

function AA.IsWindowOpen()
    local name = AA.WindowName()
    return type(DoesWindowExist) == "function"
        and DoesWindowExist(name)
        and WindowGetShowing(name) == true
end

function AA.GetCraftingStatus()
    if not GameData or not GameData.CraftingStatus then
        return { state = -1, skillType = -1, successChance = -1 }
    end
    return {
        state = tonumber(GameData.CraftingStatus.State) or -1,
        skillType = tonumber(GameData.CraftingStatus.SkillType) or -1,
        -- Same field ApothecaryWindow.SetStabilityState uses (HIGH/MEDIUM/LOW).
        successChance = tonumber(GameData.CraftingStatus.SuccessChance) or -1,
    }
end

function AA.CraftingState()
    return AA.GetCraftingStatus().state
end

function AA.CraftingSkillType()
    return AA.GetCraftingStatus().skillType
end

function AA.SuccessChance()
    return AA.GetCraftingStatus().successChance
end

--- Stock red hint: TEXT_CRAFTING_HINT_WILL_DEFINITELY_FAIL (SuccessChance == LOW).
function AA.WillDefinitelyFail()
    local CSC = GameData and GameData.CraftingSuccessChance
    if type(CSC) ~= "table" or CSC.LOW == nil then
        return false
    end
    return AA.SuccessChance() == CSC.LOW
end

--- HIGH or MEDIUM only. LOW = definite fail; INVALID = incomplete / stale after mat change.
function AA.SuccessChanceAllowsPerform()
    local CSC = GameData and GameData.CraftingSuccessChance
    if type(CSC) ~= "table" then
        return true
    end
    local chance = AA.SuccessChance()
    return chance == CSC.HIGH or chance == CSC.MEDIUM
end

--- States where stock UI shows a brewable board (not NEED_* / FAIL / PERFORMING).
function AA.IsBrewableCraftState()
    local cs = GameData and GameData.CraftingStates
    if type(cs) ~= "table" then
        return AA.ServerHasItems() == true
    end
    local state = AA.CraftingState()
    return state == cs.VALID_RECIPE or state == cs.SUCCESS_REPEAT
end

--- Stock UI bug: SetStabilityState rejects SuccessChance < LOW, so INVALID(0) leaves
--- ApothecaryWindow.stabilityCurrentState stuck on the previous (often HIGH/green) value.
--- Returns true when the painted cache disagrees with the live engine field.
function AA.UiStabilityDesync()
    if type(ApothecaryWindow) ~= "table" then
        return false
    end
    local painted = tonumber(ApothecaryWindow.stabilityCurrentState)
    local live = AA.SuccessChance()
    if painted == nil or live < 0 then
        return false
    end
    return painted ~= live
end

--- Stealth brew keeps the apo window hidden; readiness is skill session, not WindowGetShowing.
function AA.IsCraftingSessionActive()
    return AA.CraftingSkillType() == AA.TradeSkill()
end

function AA.IsPerforming()
    if type(ApothecaryWindow) == "table" and ApothecaryWindow.STATE_PERFORMING then
        if ApothecaryWindow.currentState == ApothecaryWindow.STATE_PERFORMING then
            return true
        end
    end
    if GameData and GameData.CraftingStates and GameData.CraftingStates.PERFORMING then
        return AA.CraftingSkillType() == AA.TradeSkill()
            and AA.CraftingState() == GameData.CraftingStates.PERFORMING
    end
    return type(ApothecaryWindow) == "table" and ApothecaryWindow.PerformingLock == true
end

function AA.SetSoftLocks(enabled)
    if type(EA_BackpackUtilsMediator) == "table"
        and type(EA_BackpackUtilsMediator.EnableSoftLocks) == "function"
    then
        TryQuiet("EnableSoftLocks", EA_BackpackUtilsMediator.EnableSoftLocks, enabled == true)
    elseif type(EA_Window_Backpack) == "table"
        and type(EA_Window_Backpack.EnableSoftLocks) == "function"
    then
        TryQuiet("EA_Window_Backpack.EnableSoftLocks", EA_Window_Backpack.EnableSoftLocks, enabled == true)
    end
end

function AA.ReleaseBackpackLocks()
    local name = AA.WindowName()
    if type(EA_BackpackUtilsMediator) == "table"
        and type(EA_BackpackUtilsMediator.ReleaseAllLocksForWindow) == "function"
    then
        TryCall("ReleaseAllLocksForWindow", EA_BackpackUtilsMediator.ReleaseAllLocksForWindow, name)
    elseif type(EA_Window_Backpack) == "table"
        and type(EA_Window_Backpack.ReleaseAllLocksForWindow) == "function"
    then
        TryCall("EA_Window_Backpack.ReleaseAllLocksForWindow", EA_Window_Backpack.ReleaseAllLocksForWindow, name)
    end
    AA.SetSoftLocks(false)
end

function AA.ClearSlots()
    AA.InvalidateCraftSlotCache()
    local apo = AA.TradeSkill()
    local cleared = false
    local seen = {}
    if type(GetCraftingBackPackSlots) == "function" then
        local ok, slots = TryQuiet("GetCraftingBackPackSlots", GetCraftingBackPackSlots, apo)
        if ok and type(slots) == "table" then
            for index = 4, 0, -1 do
                local entry = slots[index]
                if type(entry) == "table" then
                    if RemoveEntry(apo, entry.slot, entry.backpack, seen) then
                        cleared = true
                    end
                end
            end
            for _, entry in pairs(slots) do
                if type(entry) == "table" then
                    if RemoveEntry(apo, entry.slot, entry.backpack, seen) then
                        cleared = true
                    end
                end
            end
        end
    end
    if type(ApothecaryWindow) == "table" and type(ApothecaryWindow.craftingData) == "table"
        and type(RemoveCraftingItem) == "function"
    then
        for slotNum = 4, 0, -1 do
            local cd = ApothecaryWindow.craftingData[slotNum]
            if type(cd) == "table" and cd.sourceSlot and cd.sourceBackpack then
                if RemoveEntry(apo, cd.sourceSlot, cd.sourceBackpack, seen) then
                    cleared = true
                end
            end
        end
    end
    return cleared
end

-- Park the Apo root off-screen while SP owns brew. Do not hide widgets or
-- swallow WindowSetShowing: SkillType needs a real show, and SetStateData
-- re-shows bottles/slots independently of the frame. Do not eat the player
-- Apothecary ability (stock ToggleShowing).
local PARK_X = -4000
local PARK_Y = -4000

local function ApoRootName()
    return AA.WindowName()
end

local function CallOrigToggle(tradeSkill)
    local fn = AA._origToggleShowing
    if type(fn) ~= "function" and CraftingSystem and type(CraftingSystem.ToggleShowing) == "function" then
        fn = CraftingSystem.ToggleShowing
    end
    if type(fn) == "function" then
        TryCall("CraftingSystem.ToggleShowing", fn, tradeSkill)
        return true
    end
    return false
end

local function SetRootHandleInput(handle)
    if type(WindowSetHandleInput) ~= "function" then
        return
    end
    local name = ApoRootName()
    if DoesWindowExist and DoesWindowExist(name) then
        TryQuiet("WindowSetHandleInput", WindowSetHandleInput, name, handle == true)
    end
end

local function UnparkApoRoot()
    local name = ApoRootName()
    local wasParked = AA._apoParked == true
    AA._apoParked = false
    if not (DoesWindowExist and DoesWindowExist(name)) then
        return
    end
    -- Clearing anchors on every hide (player-closed stock Apo) can reopen at
    -- top-left. Only strip stealth park anchors.
    if wasParked and type(WindowClearAnchors) == "function" then
        TryQuiet("WindowClearAnchors", WindowClearAnchors, name)
    end
    SetRootHandleInput(true)
    if type(WindowSetAlpha) == "function" then
        TryQuiet("WindowSetAlpha", WindowSetAlpha, name, 1)
    end
    if type(WindowSetFontAlpha) == "function" then
        TryQuiet("WindowSetFontAlpha", WindowSetFontAlpha, name, 1)
    end
end

local function PlaceApoOnScreen()
    local name = ApoRootName()
    UnparkApoRoot()
    if not (DoesWindowExist and DoesWindowExist(name)) then
        return
    end
    local function CloseCallback()
        if CraftingSystem and type(CraftingSystem.SetCurrentTradeSkill) == "function" then
            TryQuiet("SetCurrentTradeSkill", CraftingSystem.SetCurrentTradeSkill, AA.TradeSkill())
        end
        CallOrigToggle(AA.TradeSkill())
    end
    if type(WindowUtils) == "table" and type(WindowUtils.AddToOpenList) == "function" then
        local mode = WindowUtils.Cascade and WindowUtils.Cascade.MODE_AUTOMATIC
        TryQuiet("AddToOpenList", WindowUtils.AddToOpenList, name, CloseCallback, mode)
    elseif type(WindowAddAnchor) == "function" then
        TryQuiet("WindowAddAnchor", WindowAddAnchor, name, "center", "Root", "center", 0, 0)
    end
    if type(WindowForceProcessAnchors) == "function" then
        pcall(WindowForceProcessAnchors, name)
    end
end

function AA.ParkApoRoot()
    if AA._playerWantsApo == true then
        return false
    end
    local name = ApoRootName()
    if not (DoesWindowExist and DoesWindowExist(name)) then
        return false
    end
    if type(WindowClearAnchors) == "function" then
        TryQuiet("WindowClearAnchors", WindowClearAnchors, name)
    end
    if type(WindowAddAnchor) == "function" then
        TryQuiet("WindowAddAnchor", WindowAddAnchor, name, "topleft", "Root", "topleft", PARK_X, PARK_Y)
    end
    if type(WindowForceProcessAnchors) == "function" then
        pcall(WindowForceProcessAnchors, name)
    end
    SetRootHandleInput(false)
    if type(WindowUtils) == "table" and type(WindowUtils.RemoveFromOpenList) == "function" then
        TryQuiet("RemoveFromOpenList", WindowUtils.RemoveFromOpenList, name)
    end
    -- First brew after login/reload: Show can paint one frame at the XML
    -- default (center) before park anchors stick. Alpha 0 hides that flash;
    -- later brews often skip stock ShowCurrentWindow because showing is already
    -- true from a prior stealth open, so the flash looks "first only".
    if type(WindowSetAlpha) == "function" then
        TryQuiet("WindowSetAlpha", WindowSetAlpha, name, 0)
    end
    if type(WindowSetFontAlpha) == "function" then
        TryQuiet("WindowSetFontAlpha", WindowSetFontAlpha, name, 0)
    end
    AA._apoParked = true
    return true
end

--- True while SP should ignore engine CRAFTING_SHOW_WINDOW echoes from SendInitCrafting.
--- Check the TTL before returning sticky true, except the synchronous _spOpening
--- latch. A sticky boolean swallows the Apothecary ability until reload.
local function EngineShowSuppressed()
    -- Synchronous headless open only. Async echoes use the TTL below.
    if AA._spOpening == true then
        return true
    end
    local untilT = tonumber(AA._suppressEngineShowUntil) or 0
    if AA._suppressEngineShow ~= true and untilT <= 0 then
        return false
    end
    local now = 0
    if type(GetGameTime) == "function" then
        now = tonumber(GetGameTime()) or 0
    end
    -- No clock, no TTL, or TTL elapsed: drop the latch. A sticky boolean here
    -- swallows the Apothecary ability until /reload.
    if untilT <= 0 or now <= 0 or now > untilT then
        AA._suppressEngineShow = false
        AA._suppressEngineShowUntil = 0
        return false
    end
    return true
end

local function ArmEngineShowSuppress(sec)
    AA._suppressEngineShow = true
    local now = 0
    if type(GetGameTime) == "function" then
        now = tonumber(GetGameTime()) or 0
    end
    AA._suppressEngineShowUntil = now + (tonumber(sec) or 2)
end

-- Late init echoes arrive just after the 2.5s show suppress. A longer gap is
-- the player's press. Do not learn the wait from it, and do not count it as a hit.
-- Before three samples, accept a late echo for up to 10s so a slow login is
-- not recorded as a miss. After that, accept only about one second past the
-- usual delay so a player press cannot stretch the learned wait.
local ECHO_SUPPRESS_SEC = 2.5
local ECHO_POST_SUPPRESS_BAND = 1
local ECHO_LATE_SAMPLE_CAP = 6
local ECHO_LATE_BOOTSTRAP_SEC = 10
local ECHO_LATE_MAX_WAIT = ECHO_LATE_SAMPLE_CAP + 1

local function EchoLateMedian(dts)
    local n = #dts
    if n <= 0 then
        return 0
    end
    local copy = {}
    for i = 1, n do
        copy[i] = dts[i]
    end
    table.sort(copy)
    if n % 2 == 1 then
        return copy[(n + 1) / 2]
    end
    return (copy[n / 2] + copy[n / 2 + 1]) / 2
end

local function NoteEchoLateSample(dt)
    dt = tonumber(dt) or 0
    if dt < 0 or dt > ECHO_LATE_SAMPLE_CAP then
        return false
    end
    local dts = AA._echoLateDts
    if type(dts) ~= "table" then
        dts = {}
        AA._echoLateDts = dts
    end
    if #dts >= 3 then
        local med = EchoLateMedian(dts)
        if dt > (med + 1) then
            return false
        end
    end
    dts[#dts + 1] = dt
    if #dts > 8 then
        table.remove(dts, 1)
    end
    local maxDt = 0
    for i = 1, #dts do
        if dts[i] > maxDt then
            maxDt = dts[i]
        end
    end
    AA._echoLateSamples = #dts
    AA._echoLateMax = maxDt
    return true
end

local function EchoClock()
    if type(GetGameTime) ~= "function" then
        return 0
    end
    return tonumber(GetGameTime()) or 0
end

--- Accept-window end for one late echo. Before three samples this is the
--- 10s cold-start window. After that it is the usual delay plus one second,
--- capped, and still not the full player-press wait.
local function EchoAcceptEnd(armed)
    if (tonumber(AA._echoLateSamples) or 0) < 3 then
        return armed + ECHO_LATE_BOOTSTRAP_SEC
    end
    local med = 0
    if type(AA._echoLateDts) == "table" then
        med = EchoLateMedian(AA._echoLateDts)
    end
    local span = med + 1
    if span > ECHO_LATE_MAX_WAIT then
        span = ECHO_LATE_MAX_WAIT
    end
    local shortEnd = ECHO_SUPPRESS_SEC + ECHO_POST_SUPPRESS_BAND
    if span < shortEnd then
        span = shortEnd
    end
    return armed + span
end

local function ClearEchoExpectation()
    AA._echoPending = false
    AA._echoWatch = false
    AA._echoBandUntil = 0
end

--- The open's echo never arrived. force is set when a player press ends the
--- wait before _expectEchoUntil. Two misses with no majority of hits means
--- later opens do not swallow the first press.
local function NoteEchoMiss(reason, force)
    if AA._echoPending ~= true and AA._echoWatch ~= true then
        return false
    end
    local now = EchoClock()
    local echoUntil = tonumber(AA._expectEchoUntil) or 0
    if force ~= true then
        if now <= 0 or echoUntil <= 0 or now < echoUntil then
            return false
        end
    end
    AA._echoMisses = (tonumber(AA._echoMisses) or 0) + 1
    ClearEchoExpectation()
    if StockPiler.Debug and StockPiler.Debug.LogOp then
        StockPiler.Debug.LogOp("brew", string.format(
            "echo-miss hits=%d misses=%d reason=%s",
            tonumber(AA._echoHits) or 0,
            tonumber(AA._echoMisses) or 0,
            tostring(reason or "")))
    end
    return true
end

local function EchoStillExpected()
    local misses = tonumber(AA._echoMisses) or 0
    local hits = tonumber(AA._echoHits) or 0
    return misses < 2 or hits > misses
end

--- A parked show is the late init echo only inside the accept band, and only
--- when the outlier filter keeps the sample. A player press fails that test:
--- it is not a hit and it does not move the learned wait.
local function AcceptLateEcho(now)
    if AA._echoWatch ~= true then
        return false
    end
    local armed = tonumber(AA._echoArmedAt) or 0
    local bandUntil = tonumber(AA._echoBandUntil) or 0
    if armed <= 0 or bandUntil <= 0 or now <= 0 or now < armed or now >= bandUntil then
        return false
    end
    local dt = now - armed
    if NoteEchoLateSample(dt) ~= true then
        return false
    end
    AA._echoHits = (tonumber(AA._echoHits) or 0) + 1
    if StockPiler.Debug and StockPiler.Debug.LogOp then
        StockPiler.Debug.LogOp("brew", string.format(
            "echo-late dt=%.2f max=%.2f samples=%d hits=%d",
            dt,
            tonumber(AA._echoLateMax) or 0,
            tonumber(AA._echoLateSamples) or 0,
            tonumber(AA._echoHits) or 0))
    end
    ClearEchoExpectation()
    return true
end

function AA.ClearEngineShowSuppress()
    AA._suppressEngineShow = false
    AA._suppressEngineShowUntil = 0
    AA._expectEchoUntil = 0
    ClearEchoExpectation()
end

function AA.InstallStealthHooks()
    if CraftingSystem and type(CraftingSystem.ToggleShowing) == "function" and not AA._origToggleShowing then
        AA._origToggleShowing = CraftingSystem.ToggleShowing
        CraftingSystem.ToggleShowing = function(tradeSkill)
            local apo = AA.TradeSkill()
            local isApo = tradeSkill == nil or tradeSkill == apo
            -- Echo window (sync open or unexpired TTL): do not run stock ShowCurrentWindow.
            -- A show here is not the player's ability. The sync open already
            -- produced its show, so the long latch comes down. One late echo
            -- can still land in the short post-suppress band.
            if isApo and EngineShowSuppressed() then
                if AA._spOpening == true then
                    AA._echoPending = false
                else
                    -- The echo arrived inside the 2.5s suppress, after the
                    -- sync call returned. It is consumed. Do not also wait
                    -- for a late one, and do not count this as a miss.
                    AA._expectEchoUntil = 0
                    ClearEchoExpectation()
                end
                -- Re-park even when we swallow: a concurrent layout pass can
                -- still re-anchor the root before our InitHeadless Park runs.
                AA.ParkApoRoot()
                return
            end
            -- After the show-suppress TTL, one late CRAFTING_SHOW_WINDOW echo
            -- is still expected, but only inside the accept band. Outside that
            -- band a parked show is usually the player - except while AutoBrew
            -- owns the headless session: engine echoes after open-timeout /
            -- load / perform must not PlaceApoOnScreen or latch _playerWantsApo
            -- (ParkApoRoot then no-ops for the rest of the brew).
            if isApo and AA._apoParked == true then
                local echoNow = EchoClock()
                if AcceptLateEcho(echoNow) then
                    AA.ParkApoRoot()
                    return
                end
                local ownedStealth = AA._suppressCascadeClose == true
                    and AA._playerWantsApo ~= true
                if ownedStealth then
                    if AA._echoWatch == true then
                        NoteEchoMiss("owned-late-show", true)
                    end
                    AA.ParkApoRoot()
                    if StockPiler.Debug and StockPiler.Debug.LogOp then
                        StockPiler.Debug.LogOp("brew", "echo-repark owned")
                    end
                    return
                end
                if AA._echoWatch == true then
                    local untilT = tonumber(AA._expectEchoUntil) or 0
                    local reason = "player-press"
                    if untilT > 0 and echoNow >= untilT then
                        reason = "late-show"
                    end
                    NoteEchoMiss(reason, true)
                end
                AA._playerWantsApo = true
                AA.ClearEngineShowSuppress()
                -- Player asked for the window. Stock layout may close the bag.
                AA._suppressCascadeClose = false
                AA._keepShown = nil
                AA._cascadeSuppressed = nil
                PlaceApoOnScreen()
                local name = ApoRootName()
                if type(DoesWindowExist) == "function"
                    and DoesWindowExist(name)
                    and WindowGetShowing(name) == true
                then
                    return
                end
            end
            -- Owned headless brew but apo not marked parked (close/retry race):
            -- never run stock ShowCurrentWindow; park if the root exists.
            if isApo and AA._suppressCascadeClose == true and AA._playerWantsApo ~= true then
                AA.ParkApoRoot()
                if StockPiler.Debug and StockPiler.Debug.LogOp then
                    StockPiler.Debug.LogOp("brew", "echo-repark owned-unparked")
                end
                return
            end
            return AA._origToggleShowing(tradeSkill)
        end
    end
    if type(ApothecaryWindow) == "table" and type(ApothecaryWindow.OnHidden) == "function" and not AA._origApoOnHidden then
        AA._origApoOnHidden = ApothecaryWindow.OnHidden
        ApothecaryWindow.OnHidden = function(...)
            AA._playerWantsApo = false
            UnparkApoRoot()
            return AA._origApoOnHidden(...)
        end
    end
end

--- AutoBrew must not run the stock cascade close. Bag and bank are on the same
--- automatic layout list as Apothecary, so a brew show that joins the list
--- closes whichever of them no longer fits. A player-opened Apothecary still
--- uses the normal layout.
local WindowIsShowing

local function InstallCascadeGuard()
    local Cascade = WindowUtils and WindowUtils.Cascade
    if not Cascade or type(Cascade.Resolve) ~= "function" or AA._origCascadeResolve then
        return
    end
    AA._origCascadeResolve = Cascade.Resolve
    Cascade.Resolve = function(...)
        local keep = AA._keepShown
        local list = Cascade.List
        local saved = {}
        if AA._suppressCascadeClose == true and type(keep) == "table" and type(list) == "table" then
            for i = 1, #list do
                local entry = list[i]
                if type(entry) == "table" and type(entry.name) == "string" and keep[entry.name] == true then
                    saved[entry.name] = { fn = entry.closeFunction }
                    entry.closeFunction = function() end
                    -- The queued close can still hide a window we just stubbed.
                    -- Remember it so Restore can put that one back. A window
                    -- that is already hidden was closed by the player.
                    if WindowIsShowing(entry.name) then
                        local suppressed = AA._cascadeSuppressed
                        if type(suppressed) ~= "table" then
                            suppressed = {}
                            AA._cascadeSuppressed = suppressed
                        end
                        suppressed[entry.name] = true
                    end
                end
            end
        else
            return AA._origCascadeResolve(...)
        end
        local ok, err = pcall(AA._origCascadeResolve, ...)
        list = Cascade.List
        if type(list) == "table" then
            for i = 1, #list do
                local entry = list[i]
                if type(entry) == "table" and type(entry.name) == "string" and saved[entry.name] then
                    entry.closeFunction = saved[entry.name].fn
                end
            end
        end
        if not ok then
            error(err)
        end
    end
end

WindowIsShowing = function(name)
    return type(DoesWindowExist) == "function" and DoesWindowExist(name)
        and type(WindowGetShowing) == "function" and WindowGetShowing(name) == true
end

local function CompanionWindowNames()
    local bag = "EA_Window_Backpack"
    if type(EA_Window_Backpack) == "table" and type(EA_Window_Backpack.windowName) == "string" then
        bag = EA_Window_Backpack.windowName
    end
    return { bag, "BankWindow" }
end

local function RememberCompanionWindows()
    local keep = AA._keepShown
    if type(keep) ~= "table" then
        keep = {}
        AA._keepShown = keep
    end
    local suppressed = AA._cascadeSuppressed
    local names = CompanionWindowNames()
    for i = 1, #names do
        local name = names[i]
        if WindowIsShowing(name) then
            keep[name] = true
            if type(suppressed) == "table" then
                suppressed[name] = nil
            end
        elseif type(suppressed) ~= "table" or suppressed[name] ~= true then
            -- Hidden, and this open's cascade did not stub it. The player
            -- closed it. Do not put it back on the next retry.
            keep[name] = nil
        end
    end
end

local function RestoreCompanionWindows()
    local keep = AA._keepShown
    local suppressed = AA._cascadeSuppressed
    AA._cascadeSuppressed = nil
    if type(keep) ~= "table" or type(suppressed) ~= "table" then
        return
    end
    for name, was in pairs(suppressed) do
        if was == true and keep[name] == true
            and type(DoesWindowExist) == "function" and DoesWindowExist(name)
            and WindowIsShowing(name) ~= true
        then
            TryCall("WindowSetShowing", WindowSetShowing, name, true)
        end
    end
end

function AA.BeginOwnedSession()
    AA.InstallStealthHooks()
    InstallCascadeGuard()
end

function AA.EndStealthUi()
    AA._spOpening = false
    AA.ClearEngineShowSuppress()
    AA._playerWantsApo = false
    AA._suppressCascadeClose = false
    AA._keepShown = nil
    AA._cascadeSuppressed = nil
    UnparkApoRoot()
end

--- Show Apo without stock ShowCurrentWindow side effects:
--- - AddToOpenList(MODE_AUTOMATIC) + Cascade.Resolve can close the vendor
---   (store is MODE_HIGHLANDER; overflow windows get Done/closeFunction)
--- - EA_BackpackUtilsMediator.ShowBackpack() opens bags the player left closed
--- Cultivation planting uses AddCraftingItem. The client may still show
--- CultivationWindow; that layout is left to the default UI.
local function ShowApoRootVisible()
    local name = ApoRootName()
    if not (DoesWindowExist and DoesWindowExist(name)) then
        return false
    end
    if WindowGetShowing(name) == true then
        return true
    end
    -- Direct show only. Apo XML OnShown clears the board; it does not join cascade.
    TryCall("WindowSetShowing", WindowSetShowing, name, true)
    return WindowGetShowing(name) == true
end

function AA.InitHeadlessSession()
    local apo = AA.TradeSkill()
    -- Park + alpha 0 before SetCurrentTradeSkill / SetStaticData: those can
    -- kick CRAFTING_SHOW_WINDOW while the root still has login-default anchors.
    AA.ParkApoRoot()
    if CraftingSystem and type(CraftingSystem.SetCurrentTradeSkill) == "function" then
        TryQuiet("SetCurrentTradeSkill", CraftingSystem.SetCurrentTradeSkill, apo)
    end
    if CraftingSystem and type(CraftingSystem.SetStaticData) == "function" then
        TryQuiet("SetStaticData", CraftingSystem.SetStaticData)
    end
    -- Re-park after static data (layout may have moved the root), then show.
    AA.ParkApoRoot()
    ShowApoRootVisible()
    AA.ParkApoRoot()
    -- Prefer SendInitCrafting without ApothecaryWindow.Show: Show() enables soft
    -- locks that make AddCraftingItem no-op for mains/ingredients (container still
    -- works). Soft locks stay off for headless brew load.
    if type(SendInitCrafting) == "function" then
        TryCall("SendInitCrafting", SendInitCrafting, apo)
    elseif type(ApothecaryWindow) == "table" and type(ApothecaryWindow.Show) == "function" then
        TryQuiet("ApothecaryWindow.Show", ApothecaryWindow.Show)
    end
    AA.SetSoftLocks(false)
    -- Re-park: engine CRAFTING_SHOW_WINDOW / SetStateData can reset anchors.
    AA.ParkApoRoot()
    RestoreCompanionWindows()
end

function AA.HideWindowOnly()
    return AA.ParkApoRoot()
end

function AA.EnforceStealthHide(session)
    session = type(session) == "table" and session or nil
    if not session or session._brewOwnedSession ~= true then
        return false
    end
    if AA._playerWantsApo == true then
        return false
    end
    AA.BeginOwnedSession()
    if AA.IsWindowOpen() and AA.ParkApoRoot() then
        if session and StockPiler.Brew and StockPiler.Brew.SetApoSessionFlags then
            StockPiler.Brew.SetApoSessionFlags(session, { stealth = true })
        end
        return true
    end
    return false
end

--- Headless show (no cascade / backpack) so SkillType can stamp, then park
--- off-screen in the same call. Player ability still uses stock ToggleShowing
--- via InstallStealthHooks / PlaceApoOnScreen.
function AA.OpenWindow(session)
    session = type(session) == "table" and session or nil
    local apo = AA.TradeSkill()
    AA.BeginOwnedSession()
    AA._suppressCascadeClose = true
    RememberCompanionWindows()
    AA._playerWantsApo = false
    if session and StockPiler.Brew and StockPiler.Brew.SetApoSessionFlags then
        StockPiler.Brew.SetApoSessionFlags(session, {
            idleForceClosed = false,
            owned = true,
            stealth = false,
        })
    end

    -- Already stealth-active: do not re-show (OpenWindow retries must not flash).
    if AA.IsCraftingSessionActive() == true and AA._apoParked == true then
        if session and StockPiler.Brew and StockPiler.Brew.SetApoSessionFlags then
            StockPiler.Brew.SetApoSessionFlags(session, { stealth = true })
        end
        AA.ParkApoRoot()
        return true
    end

    ArmEngineShowSuppress(ECHO_SUPPRESS_SEC)
    -- The previous open's window may have closed without a late echo.
    NoteEchoMiss("next-open")
    local echoNow = EchoClock()
    AA._echoArmedAt = echoNow
    -- 10s until three late echoes have been timed. Then wait the longest
    -- accepted delay plus one second, capped so a slow player press cannot
    -- hold the window near 10s for the rest of the session.
    local echoWait = 10
    if (tonumber(AA._echoLateSamples) or 0) >= 3 then
        echoWait = (tonumber(AA._echoLateMax) or 0) + 1
        if echoWait < 3 then
            echoWait = 3
        elseif echoWait > (ECHO_LATE_SAMPLE_CAP + 1) then
            echoWait = ECHO_LATE_SAMPLE_CAP + 1
        end
    end
    AA._expectEchoUntil = echoNow + echoWait
    -- Stop expecting that echo once misses outnumber hits. While it is
    -- expected, only a show inside the post-suppress band counts as the
    -- late echo. The rest of _expectEchoUntil is the player's press.
    local expect = EchoStillExpected()
    AA._echoWatch = expect
    AA._echoPending = expect
    if expect then
        AA._echoBandUntil = EchoAcceptEnd(echoNow)
    else
        AA._echoBandUntil = 0
    end
    AA._spOpening = true
    -- A throw here used to leave the latch set and swallow the player's
    -- Apothecary ability until the window closed (ADP-19).
    TryCall("AA.InitHeadlessSession", AA.InitHeadlessSession)
    AA._spOpening = false
    if AA.IsWindowOpen() and AA.ParkApoRoot() and session
        and StockPiler.Brew and StockPiler.Brew.SetApoSessionFlags
    then
        StockPiler.Brew.SetApoSessionFlags(session, { stealth = true })
    end
    return AA.CraftingSkillType() == apo
end

function AA.CloseWindow(session)
    AA._echoPending = false
    AA._echoWatch = false
    AA._echoBandUntil = 0
    AA._expectEchoUntil = 0
    session = type(session) == "table" and session or nil
    local apo = AA.TradeSkill()
    local closeApo = session and session._brewOpenedApo == true
    local ownedSession = session and session._brewOwnedSession == true
    local stealth = session and session._brewApoStealth == true
    local placedOnBoard = session and session._brewPlacedOnBoard == true
    local playerVisible = AA.IsWindowOpen()
    local apoSkillActive = AA.CraftingSkillType() == apo

    if session and StockPiler.Brew and StockPiler.Brew.SetApoSessionFlags then
        StockPiler.Brew.SetApoSessionFlags(session, {
            openedApo = false,
            openedBackpack = false,
            owned = false,
            stealth = false,
            placedOnBoard = false,
        })
    end

    local endEngine = ownedSession or stealth or closeApo
        or (apoSkillActive == true and not playerVisible)
    if not endEngine then
        -- Player-opened Apo: still clear slots SP itself placed (#35 N4 / ADP-20).
        -- Also reset bottle UI / nextFreeSlot when not mid-perform (L13).
        if placedOnBoard then
            AA.ClearSlots()
            AA.ReleaseBackpackLocks()
            if type(ApothecaryWindow) == "table"
                and ApothecaryWindow.PerformingLock ~= true
            then
                if type(ApothecaryWindow.Clear) == "function" then
                    TryCall("ApothecaryWindow.Clear", ApothecaryWindow.Clear)
                end
                ApothecaryWindow.nextFreeSlot = 0
            end
        end
        AA.EndStealthUi()
        return
    end

    -- Only after the session is ours. Clearing first wiped a player's
    -- visible Apothecary board (ADP-20).
    AA.ClearSlots()
    AA.ReleaseBackpackLocks()
    AA.ClearEngineShowSuppress()

    if CraftingSystem and type(CraftingSystem.SetCurrentTradeSkill) == "function" then
        TryQuiet("SetCurrentTradeSkill", CraftingSystem.SetCurrentTradeSkill, apo)
    end

    if type(ApothecaryWindow) == "table" then
        if type(ApothecaryWindow.Clear) == "function" then
            TryCall("ApothecaryWindow.Clear", ApothecaryWindow.Clear)
        end
        ApothecaryWindow.nextFreeSlot = 0
        ApothecaryWindow.PerformingLock = false
    end

    if type(SendCloseCrafting) == "function" then
        TryCall("SendCloseCrafting", SendCloseCrafting, apo)
    end

    AA.ReleaseBackpackLocks()

    local name = AA.WindowName()
    if type(DoesWindowExist) == "function" and DoesWindowExist(name) then
        TryCall("WindowSetShowing", WindowSetShowing, name, false)
        if type(WindowUtils) == "table" and type(WindowUtils.RemoveFromOpenList) == "function" then
            TryQuiet("RemoveFromOpenList", WindowUtils.RemoveFromOpenList, name)
        end
    end
    RestoreCompanionWindows()
    AA.EndStealthUi()
    -- Trailing CRAFTING_SHOW_WINDOW from the closed SendInit/SendClose can
    -- still arrive after Unpark. Swallow briefly so stock ShowCurrentWindow
    -- does not pop Apo after open-timeout or after-brew.
    ArmEngineShowSuppress(1.5)
end

--- Same gate as a manual drop on ApothecaryWindow.
--- IsCraftingItem requires an Apothecary crafting-family bonus. A TYPE=container
--- item with no family (Wilted Wild Weed) shows "0 - Container" and is refused
--- by the window. AddCraftingContainer still accepts it, so AutoBrew must not.
--- A bag copy with no craftingBonus table cannot be judged; leave it eligible.
function AA.ItemIsAllowedInSlot(itemData, craftSlot)
    craftSlot = tonumber(craftSlot)
    if type(itemData) ~= "table" or craftSlot == nil then
        return false
    end
    if type(itemData.craftingBonus) ~= "table" then
        return true
    end
    if DataUtils and type(DataUtils.IsValidItem) == "function" then
        if DataUtils.IsValidItem(itemData) ~= true then
            return false
        end
    end
    if type(ApothecaryWindow) == "table"
        and type(ApothecaryWindow.ItemIsAllowedInSlot) == "function"
    then
        local ok, allowed = pcall(ApothecaryWindow.ItemIsAllowedInSlot, itemData, craftSlot)
        if ok then
            return allowed == true
        end
        return false
    end
    if not (CraftingSystem and type(CraftingSystem.IsCraftingItem) == "function"
        and type(CraftingSystem.GetCraftingData) == "function"
        and GameData and GameData.CraftingItemType)
    then
        return true
    end
    if CraftingSystem.IsCraftingItem(itemData, AA.TradeSkill()) ~= true then
        return false
    end
    local _, resourceType = CraftingSystem.GetCraftingData(itemData)
    local cit = GameData.CraftingItemType
    resourceType = tonumber(resourceType) or 0
    if resourceType == cit.CONTAINER or resourceType == cit.CONTAINER_DYE then
        return craftSlot == 0
    end
    if resourceType == cit.MAIN_INGREDIENT or resourceType == cit.PIGMENT then
        return craftSlot == 1
    end
    local minType = tonumber(cit.MIN_CRAFTING_ITEM_NUM)
    local maxType = tonumber(cit.MAX_CRAFTING_ITEM_NUM)
    if minType and maxType and resourceType >= minType and resourceType <= maxType then
        return craftSlot >= 2 and craftSlot <= 4
    end
    return false
end

function AA.InvalidateCraftSlotCache()
    AA._craftSlotFrame = nil
    AA._craftSlotFn = nil
    AA._craftSlotTable = nil
    AA._craftBagFrame = nil
    AA._craftBagFn = nil
    AA._craftBags = nil
end

local function CraftSlotTable()
    local fn = GetCraftingBackPackSlots
    local frame = tonumber(StockPiler.FrameCounter) or 0
    if frame > 0 and AA._craftSlotFrame == frame and AA._craftSlotFn == fn then
        return AA._craftSlotTable
    end
    local slots = nil
    if type(fn) == "function" then
        local ok, result = TryQuiet("GetCraftingBackPackSlots", fn, AA.TradeSkill())
        if ok and type(result) == "table" then
            slots = result
        end
    end
    if frame > 0 then
        AA._craftSlotFrame = frame
        AA._craftSlotFn = fn
        AA._craftSlotTable = slots
    end
    return slots
end

local function BagTableForBackpack(backpack, slotNum)
    local frame = tonumber(StockPiler.FrameCounter) or 0
    local fn = EA_Window_Backpack and EA_Window_Backpack.GetItemsFromBackpack
    local key = tostring(backpack)
    if frame > 0 and AA._craftBagFrame == frame and AA._craftBagFn == fn
        and type(AA._craftBags) == "table" and AA._craftBags[key] ~= nil
    then
        local cached = AA._craftBags[key]
        if cached == false then
            return nil
        end
        return cached
    end
    local bag = nil
    local craftType = AA.CraftingBackpackType()
    -- Same readers as before, remembered for this frame. A light fetch here
    -- double-reads the craft bag and drops a pending itemsDirty flag.
    if tonumber(backpack) == tonumber(craftType) then
        bag = ReadCraftBackpack(backpack)
    elseif type(fn) == "function" then
        local okItems, items = pcall(fn, backpack)
        if okItems and type(items) == "table" then
            bag = items
        end
    end
    if frame > 0 then
        if AA._craftBagFrame ~= frame or AA._craftBagFn ~= fn or type(AA._craftBags) ~= "table" then
            AA._craftBags = {}
            AA._craftBagFrame = frame
            AA._craftBagFn = fn
        end
        AA._craftBags[key] = bag or false
    end
    return bag
end

function AA.AddItemToCrafting(craftSlot, bagSlot, bagType, itemData)
    craftSlot = tonumber(craftSlot)
    bagSlot = tonumber(bagSlot) or 0
    if bagSlot <= 0 or type(AddCraftingItem) ~= "function" then
        return false
    end
    AA.InvalidateCraftSlotCache()
    bagType = tonumber(bagType) or AA.CraftingBackpackType()
    local item = type(itemData) == "table" and itemData or nil
    if item == nil and type(EA_Window_Backpack) == "table"
        and type(EA_Window_Backpack.GetItemsFromBackpack) == "function"
    then
        local items
        if tonumber(bagType) == tonumber(AA.CraftingBackpackType()) then
            items = ReadCraftBackpack(bagType)
        else
            local okItems
            okItems, items = pcall(EA_Window_Backpack.GetItemsFromBackpack, bagType)
            if okItems ~= true then
                items = nil
            end
        end
        item = type(items) == "table" and items[bagSlot] or nil
    end
    if type(item) == "table" and AA.ItemIsAllowedInSlot(item, craftSlot) ~= true then
            if StockPiler.Debug and StockPiler.Debug.LogOp then
                StockPiler.Debug.LogOp("brew", string.format(
                    "window-reject uid=%s bag=%s bagType=%s craftSlot=%s",
                    tostring(item.uniqueID), tostring(bagSlot), tostring(bagType), tostring(craftSlot)
                ))
            end
            return false
    end
    -- Stock ApothecaryWindow.AddItem stamps clientSlotList before the engine
    -- call; without it AddCraftingItem often no-ops while pcall still succeeds.
    if type(ApothecaryWindow) == "table" then
        if type(ApothecaryWindow.clientSlotList) ~= "table" then
            ApothecaryWindow.clientSlotList = {}
        end
        if craftSlot ~= nil then
            ApothecaryWindow.clientSlotList[craftSlot] = {
                slot = bagSlot,
                backpack = bagType,
            }
        end
    end
    -- Container is slot 0 only. Nil craftSlot used to fall through to
    -- AddCraftingContainer and silently "succeed" for mains/stabs.
    if craftSlot == 0 then
        if type(AddCraftingContainer) == "function" then
            return TryCall(
                "AddCraftingContainer",
                AddCraftingContainer,
                AA.TradeSkill(),
                bagSlot,
                bagType
            ) == true
        end
    elseif craftSlot == nil then
        return false
    end
    -- Soft locks from ApothecaryWindow.Show / a prior container add make
    -- AddCraftingItem no-op for mains/ingredients while AddCraftingContainer
    -- still works. Only clear soft locks - ReleaseAllLocks mid-load can
    -- disturb the board (flask flicker) without helping the add.
    AA.SetSoftLocks(false)
    return TryCall(
        "AddCraftingItem",
        AddCraftingItem,
        AA.TradeSkill(),
        craftSlot,
        bagSlot,
        bagType
    ) == true
end

function AA.PerformCrafting()
    if type(PerformCrafting) ~= "function" then
        return false
    end
    AA.InvalidateCraftSlotCache()
    -- Arm learn before the engine craft: SkillUp / macros call AA.Perform, not
    -- ApothecaryWindow.Perform (that hook never runs on this path).
    if StockPiler.BrewLearn and StockPiler.BrewLearn.BeginPendingCraft then
        pcall(StockPiler.BrewLearn.BeginPendingCraft)
    end
    local ok = TryCall("PerformCrafting", PerformCrafting, AA.TradeSkill(), 1)
    if ok and type(ApothecaryWindow) == "table" then
        ApothecaryWindow.PerformingLock = true
    end
    return ok == true
end

-- Alias
function AA.Perform()
    return AA.PerformCrafting()
end

function AA.GetSlottedItem(craftingSlot)
    craftingSlot = tonumber(craftingSlot) or -1
    if craftingSlot < 0 then
        return nil
    end
    if type(GetCraftingBackPackSlots) == "function"
        and type(EA_Window_Backpack) == "table"
        and type(EA_Window_Backpack.GetItemsFromBackpack) == "function"
    then
        local slots = CraftSlotTable()
        if type(slots) == "table" then
            local entry = slots[craftingSlot]
            if type(entry) == "table" and entry.slot and entry.backpack then
                local bag = BagTableForBackpack(entry.backpack, entry.slot)
                local item = type(bag) == "table" and bag[entry.slot] or nil
                if type(item) == "table" and (tonumber(item.uniqueID) or 0) > 0 then
                    return item
                end
            end
        end
    end
    if type(ApothecaryWindow) == "table" and type(ApothecaryWindow.craftingData) == "table" then
        local cd = ApothecaryWindow.craftingData[craftingSlot]
        if type(cd) == "table" then
            if cd.sourceSlot ~= nil and type(EA_Window_Backpack) == "table"
                and type(EA_Window_Backpack.GetItemsFromBackpack) == "function"
            then
                local sourceBackpack = cd.sourceBackpack or AA.CraftingBackpackType()
                local bag = BagTableForBackpack(sourceBackpack, cd.sourceSlot)
                local fromBag = type(bag) == "table" and bag[cd.sourceSlot] or nil
                if type(fromBag) == "table" and (tonumber(fromBag.uniqueID) or 0) > 0 then
                    return fromBag
                end
            end
            if (tonumber(cd.objectId) or 0) > 0 then
                return {
                    uniqueID = tonumber(cd.objectId) or 0,
                    iconNum = tonumber(cd.iconId) or 0,
                }
            end
        end
    end
    return nil
end

function AA.ReadBoard()
    local out = {}
    for slotNum = 0, 4 do
        out[slotNum] = AA.GetSlottedItem(slotNum)
    end
    return out
end

function AA.ServerHasItems()
    if type(GetCraftingData) == "function" then
        local ok, data = TryQuiet("GetCraftingData", GetCraftingData, AA.TradeSkill())
        if ok and type(data) == "table" then
            for slotNum = 0, 4 do
                local row = data[slotNum]
                if type(row) == "table" then
                    local id = tonumber(row.id) or tonumber(row.objectId) or tonumber(row.uniqueID) or 0
                    if id > 0 then
                        return true
                    end
                end
            end
        end
    end
    for slotNum = 0, 4 do
        if AA.GetSlottedItem(slotNum) ~= nil then
            return true
        end
    end
    return false
end
