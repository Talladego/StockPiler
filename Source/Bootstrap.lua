----------------------------------------------------------------
-- StockPiler Bootstrap -- init, shutdown, slash commands
----------------------------------------------------------------

StockPiler = StockPiler or {}
StockPiler.Version = L"1.0.1"

local function T(key, tokens)
    return StockPiler.Util.T(key, tokens)
end

local function EmitLog(msg)
    if StockPiler.Debug and StockPiler.Debug.LogAlways then
        StockPiler.Debug.LogAlways(msg)
    end
end

local function Print(msg)
    if StockPiler.Debug and StockPiler.Debug.Reply then
        StockPiler.Debug.Reply(msg)
    elseif StockPiler.Debug and StockPiler.Debug.Print then
        StockPiler.Debug.Print(msg, "user")
    end
end

local function OnOff(on)
    return on and T("boot.on") or T("boot.off")
end

local function SetDebugEnabled(on)
    local s = StockPiler.Persistence.EnsureSettings()
    s.debugEnabled = on == true
    StockPiler.Debug.Enabled = s.debugEnabled
    EmitLog("settings| debug=" .. (StockPiler.Debug.Enabled and "ON" or "OFF"))
    Print(T("boot.debug", { state = OnOff(StockPiler.Debug.Enabled) }))
end

local function ChatModeLabel(mode)
    if mode == "quiet" then
        return T("boot.chat_quiet")
    end
    if mode == "off" then
        return T("boot.chat_off")
    end
    return T("boot.chat_on")
end

local function SetChatMode(mode)
    local Dbg = StockPiler.Debug
    local normalized = "on"
    if Dbg and Dbg.NormalizeChatMode then
        normalized = Dbg.NormalizeChatMode(mode)
    end
    local s = StockPiler.Persistence.EnsureSettings()
    s.chatMode = normalized
    if Dbg then
        Dbg.ChatMode = normalized
    end
    EmitLog("settings| chat=" .. normalized)
    local msg = T("boot.chat", { state = ChatModeLabel(normalized) })
    if Dbg and Dbg.Print then
        Dbg.Print(msg, "force")
    end
end

local function SetEventTrace(on)
    local s = StockPiler.Persistence.EnsureSettings()
    s.eventTrace = on == true
    StockPiler.Debug.EventTrace = s.eventTrace
    Print(T("boot.event_trace", { state = OnOff(s.eventTrace) }))
end

local function PrintHelp()
    Print(T("boot.help.header"))
    Print(T("boot.help.open"))
    Print(T("boot.help.chat"))
    Print(T("boot.help.button"))
end

--- Settings only (prefs / watches / toggles). Leaves learned Account data alone.
local function ResetAllSettings()
    local P = StockPiler.Persistence
    if not (P and P.ResetSettingsToDefaults) then
        return
    end
    P.ResetSettingsToDefaults()
    local s = P.EnsureSettings and P.EnsureSettings() or StockPiler.Settings
    if StockPiler.Debug then
        StockPiler.Debug.Enabled = type(s) == "table" and s.debugEnabled == true
        StockPiler.Debug.EventTrace = type(s) == "table" and s.eventTrace == true
        StockPiler.Debug.ChatMode = (type(s) == "table" and s.chatMode) or "on"
    end
    local Macro = StockPiler.Macro
    if Macro and Macro.SetCraftMacroEnabled then
        local on = type(s) ~= "table" or s.craftMacroEnabled ~= false
        Macro.SetCraftMacroEnabled(on)
    end
    local CraftButton = StockPiler.CraftButton
    if CraftButton and CraftButton.ResetToDefaults then
        CraftButton.ResetToDefaults()
    end
    -- Same sync as Watch toggles: bump gen, clear plant queue, rebuild plan.
    if StockPilerTabWatch and StockPilerTabWatch.AfterWatchSettingsChanged then
        pcall(StockPilerTabWatch.AfterWatchSettingsChanged)
    else
        if StockPiler.Watch and StockPiler.Watch.BumpGen then
            pcall(StockPiler.Watch.BumpGen)
        end
        if StockPiler.PlanSnapshot and StockPiler.PlanSnapshot.Invalidate then
            pcall(StockPiler.PlanSnapshot.Invalidate)
        end
        if StockPiler.Grow and StockPiler.Grow.InvalidatePlantQueue then
            pcall(StockPiler.Grow.InvalidatePlantQueue, { reason = "settings-reset" })
        end
        local Sch = StockPiler.Scheduler
        if Sch and Sch.EnqueuePlanRebuild then
            pcall(Sch.EnqueuePlanRebuild, { urgent = true })
        end
        if StockPiler.Ui and StockPiler.Ui.MarkWatchUiDirty then
            pcall(StockPiler.Ui.MarkWatchUiDirty)
        end
    end
    if StockPiler.Ui and StockPiler.Ui.RequestFooterRefresh then
        pcall(StockPiler.Ui.RequestFooterRefresh)
    end
    if StockPilerTabWatch then
        StockPilerTabWatch._skillGatesKey = nil
        if StockPilerTabWatch.RefreshHudButtonUi then
            pcall(StockPilerTabWatch.RefreshHudButtonUi)
        elseif StockPilerTabWatch.RefreshSkillGates then
            pcall(StockPilerTabWatch.RefreshSkillGates)
        end
    end
    Print(T("boot.settings_reset"))
end

local function SetCraftButtonScale(raw)
    local CraftButton = StockPiler.CraftButton
    if not CraftButton or not CraftButton.SetScale then
        return
    end
    local function scaleToken(n)
        return towstring(string.format("%.2f", tonumber(n) or 1.0))
    end
    if raw == nil or raw == "" then
        local scale = CraftButton.GetScale and CraftButton.GetScale() or 1.0
        Print(T("boot.button", { scale = scaleToken(scale) }))
        Print(T("boot.button_usage"))
        return
    end
    raw = string.gsub(tostring(raw), "%%", "")
    local ok, scale, clamped = CraftButton.SetScale(raw)
    if ok and clamped then
        Print(T("boot.button_clamped", { scale = scaleToken(scale) }))
    elseif ok then
        Print(T("boot.button", { scale = scaleToken(scale) }))
    else
        Print(T("boot.button_usage"))
    end
end

local function DumpMem(emit)
    emit = emit or EmitLog
    local function count(t)
        if StockPiler.Debug and StockPiler.Debug.SafeKeyCount then
            return StockPiler.Debug.SafeKeyCount(t, 0, {})
        end
        if type(t) ~= "table" then
            return 0
        end
        local n = 0
        for _ in pairs(t) do
            n = n + 1
        end
        return n
    end
    emit("mem| StockPiler top keys=" .. tostring(count(StockPiler)))
    if type(StockPiler.Account) == "table" then
        emit("mem| Account keys=" .. tostring(count(StockPiler.Account)))
        local tables = StockPiler.Persistence and StockPiler.Persistence.ACCOUNT_TABLES
            or { "items", "grows", "refines", "recipes", "potions", "skillUpRates" }
        for _, name in ipairs(tables) do
            emit("mem| Account." .. name .. "=" .. tostring(count(StockPiler.Account[name])))
        end
    end
    do
        local vi = StockPiler.Knowledge and StockPiler.Knowledge.VendorItems
            and StockPiler.Knowledge.VendorItems()
        emit("mem| session.vendorItems=" .. tostring(count(vi)))
    end
    if type(StockPiler.Settings) == "table" then
        emit("mem| Settings keys=" .. tostring(count(StockPiler.Settings)))
        emit("mem| Settings.characters=" .. tostring(count(StockPiler.Settings.characters)))
    end
end

local function DumpAudit(emit, applyFix)
    emit = emit or EmitLog
    local unexpected = {}
    if StockPiler.Persistence and StockPiler.Persistence.AuditAccountKeys then
        unexpected = StockPiler.Persistence.AuditAccountKeys() or {}
    end
    emit("audit| unexpected Account keys=" .. tostring(#unexpected))
    for i = 1, #unexpected do
        emit("audit|  " .. tostring(unexpected[i]))
    end
    -- Report-only unless the caller passes fix. ValidateAndRepair merges and
    -- deletes; a diagnostic dump must not do that (KNW-20). Load-time repair
    -- still runs from Knowledge.MigrateFingerprints.
    if applyFix == true then
        if StockPiler.Knowledge and StockPiler.Knowledge.ValidateAndRepairSavedData then
            local r = StockPiler.Knowledge.ValidateAndRepairSavedData() or {}
            emit(string.format(
                "audit| repair itemsStamped=%s recipesRemapped=%s merged=%s dropped=%s potionsDropped=%s watchesDropped=%s scrubbed=%s",
                tostring(r.itemsStamped),
                tostring(r.recipesRemapped),
                tostring(r.recipesMerged),
                tostring(r.recipesDropped),
                tostring(r.potionsDropped),
                tostring(r.watchesDropped),
                tostring(r.scrubbed)
            ))
        end
    else
        emit("audit| report-only (use /stp audit fix to apply repair)")
    end
    -- Session-only quarantine counts (#28 L3); nothing is restored from here.
    local RS = StockPiler.RecipeSpec
    local q = RS and RS._repairQuarantine
    if type(q) == "table" then
        local function countKeys(t)
            if type(t) ~= "table" then
                return 0
            end
            local n = 0
            for _ in pairs(t) do
                n = n + 1
            end
            return n
        end
        emit(string.format(
            "audit| quarantine recipes=%s potions=%s watches=%s (session RecipeSpec._repairQuarantine)",
            tostring(countKeys(q.recipes)),
            tostring(countKeys(q.potions)),
            tostring(countKeys(q.watches))
        ))
    else
        emit("audit| quarantine empty (no RecipeSpec._repairQuarantine this session)")
    end
end

--- One-shot dump of every plan / bag / diagnostic into uilog (/stp dumpall).
local function DumpAll()
    local emit = function(msg)
        EmitLog(msg)
    end
    local function section(name)
        emit("--- dumpall: " .. tostring(name) .. " ---")
    end

    emit("=== dumpall begin v" .. tostring(StockPiler.Version) .. " ===")

    section("state")
    if StockPiler.Orchestrator and StockPiler.Orchestrator.DumpState then
        StockPiler.Orchestrator.DumpState(emit)
    end

    section("bags")
    if StockPiler.BagAdapter and StockPiler.BagAdapter.Dump then
        StockPiler.BagAdapter.Dump(emit, { force = true })
    elseif StockPiler.Inventory and StockPiler.Inventory.RefreshAllIfNeeded then
        StockPiler.Inventory.RefreshAllIfNeeded({ force = true })
        emit("bags| refresh forced (BagAdapter.Dump unavailable)")
    end

    section("plan")
    if StockPiler.Planner and StockPiler.Planner.Dump then
        StockPiler.Planner.Dump(emit)
    end

    section("watchplan")
    if StockPiler.Planner and StockPiler.Planner.DumpWatchPlan then
        StockPiler.Planner.DumpWatchPlan(emit)
    end

    section("growplan")
    if StockPiler.Planner and StockPiler.Planner.DumpGrowPlan then
        StockPiler.Planner.DumpGrowPlan(emit)
    elseif StockPiler.Grow and StockPiler.Grow.DumpGrowPlan then
        StockPiler.Grow.DumpGrowPlan(emit)
    end

    section("brewplan")
    if StockPiler.Planner and StockPiler.Planner.DumpBrewPlan then
        StockPiler.Planner.DumpBrewPlan(emit)
    elseif StockPiler.Brew and StockPiler.Brew.DumpPlan then
        StockPiler.Brew.DumpPlan(emit)
    end

    section("buyplan")
    if StockPiler.Buy and StockPiler.Buy.DumpBuyPlan then
        StockPiler.Buy.DumpBuyPlan({ force = true })
    end

    section("skillplan")
    if StockPiler.SkillUp and StockPiler.SkillUp.DumpSkillPlan then
        StockPiler.SkillUp.DumpSkillPlan(emit)
    else
        emit("skillplan| dump unavailable")
    end

    section("families")
    if StockPiler.SeedMap and StockPiler.SeedMap.DumpFamilies then
        StockPiler.SeedMap.DumpFamilies(emit)
    else
        emit("families| dump unavailable")
    end

    section("upgradeplan")
    if StockPiler.UpgradeSeed and StockPiler.UpgradeSeed.Dump then
        StockPiler.UpgradeSeed.Dump(emit)
    else
        emit("upgradeplan| dump unavailable")
    end

    section("stats")
    if StockPiler.SeedMap and StockPiler.SeedMap.DumpCraftCycleStats then
        StockPiler.SeedMap.DumpCraftCycleStats(emit)
    else
        emit("stats| craft-cycle dump unavailable")
    end

    section("mem")
    DumpMem(emit)

    section("audit")
    DumpAudit(emit)

    section("events")
    if StockPiler.Debug and StockPiler.Debug.DumpEventRing then
        StockPiler.Debug.DumpEventRing(emit)
    end

    emit("=== dumpall end ===")
    Print(T("boot.dumpall_dumped"))
end

function StockPiler.OnSlash(input)
    local text = ""
    if input ~= nil then
        text = tostring(input)
    end
    text = string.gsub(text, "^%s+", "")
    text = string.gsub(text, "%s+$", "")
    local lower = string.lower(text)

    if lower == "" then
        if StockPiler.Ui and StockPiler.Ui.ToggleWindow then
            StockPiler.Ui.ToggleWindow()
        end
        return
    end
    if lower == "help" then
        PrintHelp()
        return
    end
    if lower == "reset" then
        ResetAllSettings()
        return
    end
    if lower == "debug" then
        local s = StockPiler.Persistence.EnsureSettings()
        Print(T("boot.debug", { state = OnOff(s.debugEnabled == true) }))
        return
    end
    if lower == "debug on" then
        SetDebugEnabled(true)
        return
    end
    if lower == "debug off" then
        SetDebugEnabled(false)
        return
    end
    if lower == "chat" then
        local s = StockPiler.Persistence.EnsureSettings()
        SetChatMode(s.chatMode or "on")
        return
    end
    if lower == "chat on" then
        SetChatMode("on")
        return
    end
    if lower == "chat quiet" then
        SetChatMode("quiet")
        return
    end
    if lower == "chat off" then
        SetChatMode("off")
        return
    end
    if lower == "button" then
        SetCraftButtonScale(nil)
        return
    end
    if lower == "button reset" then
        local CraftButton = StockPiler.CraftButton
        if CraftButton and CraftButton.ResetToDefaults then
            CraftButton.ResetToDefaults()
            Print(T("boot.button_reset"))
        end
        return
    end
    if lower == "button timer" then
        local CraftButton = StockPiler.CraftButton
        if CraftButton and CraftButton.ToggleShowTimer then
            local on = CraftButton.ToggleShowTimer()
            Print(T("boot.button_timer", {
                state = on and T("boot.button_timer_on") or T("boot.button_timer_off"),
            }))
        end
        return
    end
    do
        local timerArg = string.match(lower, "^button%s+timer%s+(.+)$")
        if timerArg then
            timerArg = string.gsub(timerArg, "^%s+", "")
            timerArg = string.gsub(timerArg, "%s+$", "")
            local CraftButton = StockPiler.CraftButton
            if not (CraftButton and CraftButton.SetShowTimer) then
                return
            end
            local on = nil
            if timerArg == "on" or timerArg == "center" or timerArg == "centred" then
                on = true
            elseif timerArg == "off" then
                on = false
            end
            if on == nil then
                Print(T("boot.button_timer_usage"))
                return
            end
            CraftButton.SetShowTimer(on)
            Print(T("boot.button_timer", {
                state = on and T("boot.button_timer_on") or T("boot.button_timer_off"),
            }))
            return
        end
    end
    do
        local buttonArg = string.match(lower, "^button%s+(.+)$")
        if buttonArg then
            buttonArg = string.gsub(buttonArg, "^scale%s+", "")
            -- "button reset" / "button timer …" are handled above; do not treat as scale.
            if buttonArg == "reset" or buttonArg == "timer"
                or string.match(buttonArg, "^timer%s")
            then
                return
            end
            SetCraftButtonScale(buttonArg)
            return
        end
    end
    if lower == "dumpall" then
        DumpAll()
        return
    end
    if lower == "plan" then
        if StockPiler.Planner and StockPiler.Planner.Dump then
            StockPiler.Planner.Dump(function(msg) EmitLog(msg) end)
            Print(T("boot.plan_dumped"))
        end
        return
    end
    if lower == "watchplan" then
        if StockPiler.Planner and StockPiler.Planner.DumpWatchPlan then
            StockPiler.Planner.DumpWatchPlan(function(msg) EmitLog(msg) end)
            Print(T("boot.watchplan_dumped"))
        end
        return
    end
    if lower == "state" then
        if StockPiler.Orchestrator and StockPiler.Orchestrator.DumpState then
            StockPiler.Orchestrator.DumpState(function(msg) EmitLog(msg) end)
            Print(T("boot.state_dumped"))
        end
        return
    end
    if lower == "growplan" then
        if StockPiler.Planner and StockPiler.Planner.DumpGrowPlan then
            StockPiler.Planner.DumpGrowPlan(function(msg) EmitLog(msg) end)
            Print(T("boot.growplan_dumped"))
        elseif StockPiler.Grow and StockPiler.Grow.DumpGrowPlan then
            StockPiler.Grow.DumpGrowPlan(function(msg) EmitLog(msg) end)
            Print(T("boot.growplan_dumped"))
        end
        return
    end
    if lower == "brewplan" then
        if StockPiler.Planner and StockPiler.Planner.DumpBrewPlan then
            StockPiler.Planner.DumpBrewPlan(function(msg) EmitLog(msg) end)
            Print(T("boot.brewplan_dumped"))
        elseif StockPiler.Brew and StockPiler.Brew.DumpPlan then
            StockPiler.Brew.DumpPlan(function(msg) EmitLog(msg) end)
            Print(T("boot.brewplan_dumped"))
        end
        return
    end
    if lower == "buyplan" then
        if StockPiler.Buy and StockPiler.Buy.DumpBuyPlan then
            StockPiler.Buy.DumpBuyPlan({ force = true })
            Print(T("boot.buyplan_dumped"))
        end
        return
    end
    if lower == "skillplan" then
        local SkillUp = StockPiler.SkillUp
        if SkillUp and SkillUp.DumpSkillPlan then
            SkillUp.DumpSkillPlan(function(msg) EmitLog(msg) end)
            Print(T("boot.skillplan_dumped"))
        else
            EmitLog("skillplan| dump unavailable")
            Print(T("boot.skillplan_dumped"))
        end
        return
    end
    if lower == "families" then
        local SM = StockPiler.SeedMap
        if SM and SM.DumpFamilies then
            SM.DumpFamilies(function(msg) EmitLog(msg) end)
            Print(T("boot.families_dumped"))
        else
            EmitLog("families| dump unavailable")
            Print(T("boot.families_dumped"))
        end
        return
    end
    if lower == "upgradeplan" then
        local US = StockPiler.UpgradeSeed
        if US and US.Dump then
            US.Dump(function(msg) EmitLog(msg) end)
            Print(T("boot.upgrade_dumped"))
        else
            EmitLog("upgradeplan| dump unavailable")
            Print(T("boot.upgrade_dumped"))
        end
        return
    end
    if lower == "stats" then
        if StockPiler.SeedMap and StockPiler.SeedMap.DumpCraftCycleStats then
            StockPiler.SeedMap.DumpCraftCycleStats(function(msg) EmitLog(msg) end)
            Print(T("boot.stats_dumped"))
        else
            EmitLog("stats| craft-cycle dump unavailable")
            Print(T("boot.stats_dumped"))
        end
        return
    end
    if lower == "stats clear" then
        local SkillUp = StockPiler.SkillUp
        if SkillUp and SkillUp.ClearRates and SkillUp.ClearRates() then
            EmitLog("stats| skill-up rates cleared")
            Print(T("boot.stats_cleared"))
        else
            EmitLog("stats| clear unavailable")
            Print(T("boot.unknown_cmd"))
        end
        return
    end
    if lower == "bags" or lower == "bags force" then
        if StockPiler.BagAdapter and StockPiler.BagAdapter.Dump then
            local force = string.find(lower, "force", 1, true) ~= nil
            StockPiler.BagAdapter.Dump(function(msg) EmitLog(msg) end, { force = force })
            Print(T("boot.bags_dumped"))
        elseif StockPiler.Inventory and StockPiler.Inventory.RefreshAllIfNeeded then
            StockPiler.Inventory.RefreshAllIfNeeded({ force = true })
            Print(T("boot.bags_dumped"))
        end
        return
    end
    -- /stp fingerprint <uidA> [uidB] - ProductKey + ProductMatches (butcher twin check).
    local fpA, fpB = string.match(lower, "^fingerprint%s+(%d+)%s*(%d*)$")
    if fpA then
        if StockPiler.MaterialSpec and StockPiler.MaterialSpec.DumpFingerprintCompare then
            StockPiler.MaterialSpec.DumpFingerprintCompare(
                tonumber(fpA),
                (fpB ~= nil and fpB ~= "") and tonumber(fpB) or nil,
                function(msg) EmitLog(msg) end
            )
            Print(T("boot.fingerprint_dumped"))
        end
        return
    end
    if lower == "events on" then
        SetEventTrace(true)
        return
    end
    if lower == "events off" then
        SetEventTrace(false)
        return
    end
    if lower == "events dump" then
        if StockPiler.Debug and StockPiler.Debug.DumpEventRing then
            StockPiler.Debug.DumpEventRing(function(msg) EmitLog(msg) end)
            Print(T("boot.events_dumped"))
        end
        return
    end
    if lower == "events" then
        local s = StockPiler.Persistence.EnsureSettings()
        Print(T("boot.event_trace", { state = OnOff(s.eventTrace == true) }))
        return
    end
    if lower == "mem" then
        DumpMem(function(msg) EmitLog(msg) end)
        Print(T("boot.mem_dumped"))
        return
    end
    if lower == "audit" or lower == "audit fix" then
        DumpAudit(function(msg) EmitLog(msg) end, lower == "audit fix")
        Print(T("boot.audit_dumped"))
        return
    end
    if lower == "perf" or string.sub(lower, 1, 5) == "perf " then
        if StockPiler.Perf and StockPiler.Perf.PrintSummary then
            StockPiler.Perf.PrintSummary()
        else
            Print(T("boot.help.perf"))
        end
        return
    end
    Print(T("boot.unknown_cmd"))
end

function StockPiler.Initialize()
    StockPiler.Persistence.EnsureSettings()
    if StockPiler.Perf and StockPiler.Perf.SetEnabled then
        StockPiler.Perf.SetEnabled(false)
    elseif StockPiler.Perf and StockPiler.Perf.Disable then
        StockPiler.Perf.Disable()
    end
    if StockPiler.Locale and StockPiler.Locale.Initialize then
        StockPiler.Locale.Initialize()
    end
    StockPiler.T = StockPiler.Locale and StockPiler.Locale.Format or StockPiler.T
    StockPiler.Persistence.EnsureAccount()
    if StockPiler.Knowledge and StockPiler.Knowledge.Ensure then
        StockPiler.Knowledge.Ensure()
    end
    -- After Account exists: fingerprint migrate (must not run inside EnsureAccount).
    if StockPiler.Knowledge and StockPiler.Knowledge.MigrateFingerprints then
        StockPiler.Knowledge.MigrateFingerprints()
    end
    if StockPiler.Watch and StockPiler.Watch.MigratePriorityTiersIfNeeded then
        StockPiler.Watch.MigratePriorityTiersIfNeeded()
    end
    local s = StockPiler.Settings
    if type(s) == "table" and StockPilerWindow then
        -- Plants is tab 2 and Watch is tab 3. Move a saved tab 2 selection once.
        if s.watchTabPlantsBump ~= true then
            if tonumber(s.selectedTab) == 2 then
                s.selectedTab = 3
            end
            s.watchTabPlantsBump = true
        end
        local tab = tonumber(s.selectedTab) or 1
        if tab < 1 or tab > 3 then
            tab = 1
        end
        StockPilerWindow.SelectedTab = tab
    end
    if StockPiler.Scheduler and StockPiler.Scheduler.Initialize then
        StockPiler.Scheduler.Initialize()
    end
    if StockPiler.Orchestrator and StockPiler.Orchestrator.Initialize then
        StockPiler.Orchestrator.Initialize()
    end
    if StockPiler.Macro and StockPiler.Macro.Initialize then
        StockPiler.Macro.Initialize()
    end
    if StockPiler.CraftButton and StockPiler.CraftButton.Initialize then
        StockPiler.CraftButton.Initialize()
    end
    -- Optional WarBoard board chip (no-op if WarBoard is not installed).
    if StockPiler.WarBoardBridge and StockPiler.WarBoardBridge.Initialize then
        pcall(StockPiler.WarBoardBridge.Initialize)
    end
    -- Pre-create DefaultTooltip extra rows so craft/macro tips are not clipped
    -- on first hover (LabelGetTextDimensions is 0 on brand-new rows).
    if StockPiler.RecipeTooltip and StockPiler.RecipeTooltip.WarmRows then
        StockPiler.RecipeTooltip.WarmRows()
    end
    if StockPiler.EngineEventBridge and StockPiler.EngineEventBridge.Register then
        StockPiler.EngineEventBridge.Register()
    end
    local Bus = StockPiler.EventBus
    local E = StockPiler.Events
    if Bus and Bus.Subscribe and E then
        if E.TRADE_SKILLS_CHANGED then
            if StockPiler.Ui and StockPiler.Ui.OnTradeSkillsChanged then
                Bus.Subscribe(E.TRADE_SKILLS_CHANGED, StockPiler.Ui.OnTradeSkillsChanged)
            end
            if StockPiler.Grow and StockPiler.Grow.OnTradeSkillsChanged then
                Bus.Subscribe(E.TRADE_SKILLS_CHANGED, StockPiler.Grow.OnTradeSkillsChanged)
            end
            if StockPiler.Scheduler and StockPiler.Scheduler.OnTradeSkillsChanged then
                Bus.Subscribe(E.TRADE_SKILLS_CHANGED, StockPiler.Scheduler.OnTradeSkillsChanged)
            end
        end
        if E.CRAFT_CHAT then
            if StockPiler.SeedMap and StockPiler.SeedMap.OnCraftChat then
                Bus.Subscribe(E.CRAFT_CHAT, StockPiler.SeedMap.OnCraftChat)
            end
            if StockPiler.Grow and StockPiler.Grow.OnCraftChat then
                Bus.Subscribe(E.CRAFT_CHAT, StockPiler.Grow.OnCraftChat)
            end
            if StockPiler.BrewLearn and StockPiler.BrewLearn.OnCraftChat then
                Bus.Subscribe(E.CRAFT_CHAT, StockPiler.BrewLearn.OnCraftChat)
            end
            if StockPiler.Brew and StockPiler.Brew.OnCraftChat then
                Bus.Subscribe(E.CRAFT_CHAT, StockPiler.Brew.OnCraftChat)
            end
        end
        if E.SESSION_SETTLED then
            if StockPiler.Ui and StockPiler.Ui.OnSessionSettled then
                Bus.Subscribe(E.SESSION_SETTLED, StockPiler.Ui.OnSessionSettled)
            end
            if StockPilerWindow and StockPilerWindow.OnSessionSettled then
                Bus.Subscribe(E.SESSION_SETTLED, StockPilerWindow.OnSessionSettled)
            end
        end
    end
    if StockPiler.CraftChatAdapter and StockPiler.CraftChatAdapter.RegisterChat then
        StockPiler.CraftChatAdapter.RegisterChat()
    end
    if StockPiler.VendorAdapter and StockPiler.VendorAdapter.EnsureStoreHook then
        StockPiler.VendorAdapter.EnsureStoreHook()
    end
    if StockPiler.LearnBridge and StockPiler.LearnBridge.Initialize then
        StockPiler.LearnBridge.Initialize()
    end
    if StockPiler.Ui and StockPiler.Ui.InitializeWindow then
        StockPiler.Ui.InitializeWindow()
    end
    if StockPiler.Ui and StockPiler.Ui.RegisterEventRefresh then
        StockPiler.Ui.RegisterEventRefresh()
    end
    if Bus and Bus.Subscribe and E and E.VENDOR_UPDATED
        and StockPiler.Buy and StockPiler.Buy.OnStoreUpdated
    then
        Bus.Subscribe(E.VENDOR_UPDATED, function(payload)
            StockPiler.Buy.OnStoreUpdated(type(payload) == "table" and payload or { refreshLists = true })
        end)
    end
    if StockPiler.Brew and StockPiler.Brew.RegisterEventHandlers then
        StockPiler.Brew.RegisterEventHandlers()
    end
    if StockPiler.Debug and StockPiler.Debug.InstallChatLinkHook then
        StockPiler.Debug.InstallChatLinkHook()
    end
    if LibSlash and LibSlash.RegisterWSlashCmd then
        LibSlash.RegisterWSlashCmd("stp", StockPiler.OnSlash)
        LibSlash.RegisterWSlashCmd("stockpiler", StockPiler.OnSlash)
    else
        EmitLog("init LibSlash missing - /stp may need manual binding; addon still loads")
    end
    EmitLog("init v" .. tostring(StockPiler.Version)
        .. " debug=" .. tostring(StockPiler.Debug and StockPiler.Debug.Enabled == true))
    if StockPiler.Debug and StockPiler.Debug.Print then
        StockPiler.Debug.Print(T("boot.loaded", { version = StockPiler.Version }))
    end
    if StockPiler.Scheduler and StockPiler.Scheduler.MarkAwaitingSessionLoad then
        StockPiler.Scheduler.MarkAwaitingSessionLoad()
    elseif StockPiler.Scheduler and StockPiler.Scheduler.BeginSessionSettle then
        StockPiler.Scheduler.BeginSessionSettle()
    end
    if StockPiler.Scheduler and StockPiler.Scheduler.SkipUiThisFrame then
        StockPiler.Scheduler.SkipUiThisFrame()
    end
    if StockPiler.Scheduler and StockPiler.Scheduler.EnqueueBagFlush then
        StockPiler.Scheduler.EnqueueBagFlush(true)
    end
    local Bridge = StockPiler.EngineEventBridge
    if Bridge and Bridge.MaybeCatchUpLoadingEnd then
        Bridge.MaybeCatchUpLoadingEnd()
    end
end

function StockPiler.Shutdown()
    if StockPiler.Debug and StockPiler.Debug.UninstallChatLinkHook then
        StockPiler.Debug.UninstallChatLinkHook()
    end
    if StockPiler.CraftButton and StockPiler.CraftButton.Shutdown then
        StockPiler.CraftButton.Shutdown()
    end
    if StockPiler.Macro and StockPiler.Macro.Shutdown then
        StockPiler.Macro.Shutdown()
    end
    if StockPiler.Brew and StockPiler.Brew.UnregisterEventHandlers then
        StockPiler.Brew.UnregisterEventHandlers()
    end
    if StockPiler.Ui and StockPiler.Ui.UnregisterEventRefresh then
        StockPiler.Ui.UnregisterEventRefresh()
    end
    if StockPiler.Orchestrator and StockPiler.Orchestrator.Shutdown then
        StockPiler.Orchestrator.Shutdown()
    end
    if StockPiler.LearnBridge and StockPiler.LearnBridge.Shutdown then
        StockPiler.LearnBridge.Shutdown()
    end
    if StockPiler.EngineEventBridge and StockPiler.EngineEventBridge.Unregister then
        StockPiler.EngineEventBridge.Unregister()
    end
    if StockPiler.CraftChatAdapter and StockPiler.CraftChatAdapter.UnregisterChat then
        StockPiler.CraftChatAdapter.UnregisterChat()
    end
    if StockPiler.Scheduler and StockPiler.Scheduler.Shutdown then
        StockPiler.Scheduler.Shutdown()
    end
    if StockPiler.RecipeSpec and StockPiler.RecipeSpec.SlimAllRecipesForStorage then
        StockPiler.RecipeSpec.SlimAllRecipesForStorage()
    end
    if StockPiler.Persistence and StockPiler.Persistence.StripUnexpectedAccountKeys then
        StockPiler.Persistence.StripUnexpectedAccountKeys()
    end
    EmitLog("shutdown")
end
