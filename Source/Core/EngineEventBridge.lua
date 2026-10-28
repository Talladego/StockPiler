----------------------------------------------------------------
-- StockPiler Core/EngineEventBridge -- SystemData.Events -> stores
-- Host: StockPilerWindow (WindowRegisterEventHandler).
-- UPDATE_PROCESSED: Perf.OnFrame -> ApplySlots -> snapGen ->
-- LearnBridge -> Refine.OnUpdate -> Scheduler.OnUpdate (Orch due).
----------------------------------------------------------------

StockPiler = StockPiler or {}
StockPiler.EngineEventBridge = StockPiler.EngineEventBridge or {}

local Bridge = StockPiler.EngineEventBridge

Bridge._registered = false
Bridge._host = "StockPilerWindow"
Bridge._handlers = Bridge._handlers or {}
-- Nil used to look like "loading already finished" to the craft-unplaced warn.
-- /reload still reaches OnLoadingEnd through MaybeCatchUpLoadingEnd when the
-- LOADING_END event fired before this bridge registered.
Bridge._loadingEndSeen = false

StockPiler.FrameCounter = tonumber(StockPiler.FrameCounter) or 0

local function Events()
    return SystemData and SystemData.Events
end

local function BusFire(name, payload)
    local B = StockPiler.EventBus
    if B and B.Fire then
        B.Fire(name, payload)
    end
end

local function RequestFooterViaBus(payload)
    local B = StockPiler.EventBus
    if B and B.FireFooterDirty then
        B.FireFooterDirty(type(payload) == "table" and payload or {})
    end
end

local function HostWindow()
    return Bridge._host or "StockPilerWindow"
end

local function TrackHandler(eventId, handlerName)
    Bridge._handlers[#Bridge._handlers + 1] = {
        event = eventId,
        handler = handlerName,
    }
end

local function CoalesceSlots(pendingList, pendingSet, updatedSlots)
    if type(updatedSlots) ~= "table" then
        return
    end
    local n = 0
    for _, v in ipairs(updatedSlots) do
        local slot = tonumber(v) or 0
        if slot > 0 and pendingSet[slot] ~= true then
            pendingSet[slot] = true
            pendingList[#pendingList + 1] = slot
            n = n + 1
        end
    end
    if n > 0 then
        return
    end
    for k, v in pairs(updatedSlots) do
        local slot = tonumber(k)
        if slot == nil or slot <= 0 then
            slot = tonumber(v) or 0
        end
        if slot > 0 and pendingSet[slot] ~= true then
            pendingSet[slot] = true
            pendingList[#pendingList + 1] = slot
        end
    end
end

local function ApplyInventorySlots(bagKind, slots, reason)
    local Inv = StockPiler.Inventory
    if not Inv then
        return
    end
    if type(slots) == "table" and #slots > 0 and Inv.ApplySlotUpdates then
        Inv.ApplySlotUpdates(bagKind, slots, reason)
    elseif Inv.MarkDirty then
        Inv.MarkDirty({ reason = reason, full = true })
    end
end

function Bridge.OnInventoryUpdated(updatedSlots)
    -- Stock DataUtils.ReloadItems sticks itemsDirty; mirror so force reads see it.
    -- Stock EASystem_Utils already reloads items. Keep the dirty flag so a
    -- later read still sees the update; do not reload again here.
    if GameData and GameData.Player then
        GameData.Player.itemsDirty = true
    end
    Bridge._pendingMainSlots = Bridge._pendingMainSlots or {}
    Bridge._pendingMainSlotSet = Bridge._pendingMainSlotSet or {}
    CoalesceSlots(Bridge._pendingMainSlots, Bridge._pendingMainSlotSet, updatedSlots)
    Bridge._pendingMainApply = true
end

function Bridge.OnCraftingSlotUpdated(updatedSlots)
    local AA = StockPiler.ApothecaryAdapter
    if AA and AA.InvalidateCraftSlotCache then
        AA.InvalidateCraftSlotCache()
    end
    -- Stock: PLAYER_CRAFTING_SLOT_UPDATED -> DataUtils.ReloadCraftingItems (craft bag).
    -- Distinct from PLAYER_INVENTORY_SLOT_UPDATED (main bag). Never route craft here->main.
    if GameData and GameData.Player then
        GameData.Player.craftingItemsDirty = true
    end
    Bridge._pendingCraftSlots = Bridge._pendingCraftSlots or {}
    Bridge._pendingCraftSlotSet = Bridge._pendingCraftSlotSet or {}
    CoalesceSlots(Bridge._pendingCraftSlots, Bridge._pendingCraftSlotSet, updatedSlots)
    Bridge._pendingCraftApply = true
    local Grow = StockPiler.Grow
    local Sch = StockPiler.Scheduler
    if Grow and Grow.NeedsCurrentStageAdditive and Grow.NeedsCurrentStageAdditive()
        and Sch and Sch.WakeAutoGrow
        and not (Sch.IsSuppressed and Sch.IsSuppressed() == true)
    then
        Sch.WakeAutoGrow()
    end
end

--- Stock backpack icon view: PLAYER_CRAFTING_INVENTORY_UPDATED (craft bag capacity / full rebuild).
function Bridge.OnCraftingInventoryUpdated()
    if GameData and GameData.Player then
        GameData.Player.craftingItemsDirty = true
    end
    local Inv = StockPiler.Inventory
    if Inv and Inv.ForceFullRefresh then
        Inv.ForceFullRefresh({
            forceEngine = true,
            needQueue = true,
            reason = "engine-crafting-inventory",
        })
    elseif Inv and Inv.MarkDirty then
        Inv.MarkDirty({ reason = "engine-crafting-inventory", full = true, needQueue = true })
    end
end

function Bridge.FlushPendingMainSlots()
    if Bridge._pendingMainApply ~= true then
        return false
    end
    Bridge._pendingMainApply = false
    local slots = Bridge._pendingMainSlots
    Bridge._pendingMainSlots = {}
    Bridge._pendingMainSlotSet = {}
    if StockPiler.Perf and StockPiler.Perf.Begin then
        StockPiler.Perf.Begin("Inv.ApplySlots")
    end
    ApplyInventorySlots("main", slots, "engine-inventory")
    if StockPiler.Perf and StockPiler.Perf.End then
        StockPiler.Perf.End("Inv.ApplySlots")
    end
    -- Same-frame FrameWork.Pump used to run ui-force-watch-recount + WarmHave.miss
    -- on top of ApplySlots (libperf Inv.ApplySlots + Status.Craftable x18).
    local Sch = StockPiler.Scheduler
    if Sch and Sch.NoteHeavyWork then
        Sch.NoteHeavyWork()
    end
    return true
end

function Bridge.FlushPendingCraftSlots()
    if Bridge._pendingCraftApply ~= true then
        return false
    end
    Bridge._pendingCraftApply = false
    local slots = Bridge._pendingCraftSlots
    Bridge._pendingCraftSlots = {}
    Bridge._pendingCraftSlotSet = {}
    if StockPiler.Perf and StockPiler.Perf.Begin then
        StockPiler.Perf.Begin("Inv.ApplySlots")
    end
    ApplyInventorySlots("craft", slots, "engine-crafting-slot")
    if StockPiler.Perf and StockPiler.Perf.End then
        StockPiler.Perf.End("Inv.ApplySlots")
    end
    local Sch = StockPiler.Scheduler
    if Sch and Sch.NoteHeavyWork then
        Sch.NoteHeavyWork()
    end
    return true
end

function Bridge.OnCraftingUpdated()
    local AA = StockPiler.ApothecaryAdapter
    if AA and AA.InvalidateCraftSlotCache then
        AA.InvalidateCraftSlotCache()
    end
    if StockPiler.LearnBridge and StockPiler.LearnBridge.OnCraftingUpdated then
        StockPiler.LearnBridge.OnCraftingUpdated()
    end
    if StockPiler.Brew and StockPiler.Brew.OnCraftingUpdated then
        StockPiler.Brew.OnCraftingUpdated()
    end
    -- Brew.ForceBrewUiRefresh already synced footer/macro this frame.
    local Brew = StockPiler.Brew
    local frame = tonumber(StockPiler.FrameCounter) or 0
    if Brew and tonumber(Brew._brewUiForcedFrame) == frame and frame > 0 then
        return
    end
    RequestFooterViaBus({ reason = "crafting-updated" })
end

function Bridge.OnCultivationUpdated()
    if StockPiler.Perf and StockPiler.Perf.Begin then
        StockPiler.Perf.Begin("CultivationUpdated")
    end
    local plotNum = 0
    if GameData and GameData.Player and GameData.Player.Cultivation then
        plotNum = tonumber(GameData.Player.Cultivation.UpdatedIndex) or 0
    end
    -- Harvest macro op-lock: arm storm before Garden dirty fans out so
    -- OnGardenDirty / Watch flush cannot sync Planner.Build this frame.
    local Grow = StockPiler.Grow
    local Sch = StockPiler.Scheduler
    -- Always hold Watch paint on cult updates (plot storms pile RefreshWatch).
    if Sch and Sch.SkipUiThisFrame then
        Sch.SkipUiThisFrame()
    end
    if Grow and Grow.IsHarvestOpActive and Grow.IsHarvestOpActive() == true then
        if Sch and Sch.ArmHarvestStorm then
            Sch.ArmHarvestStorm()
        end
        if Sch and Sch.SkipPlanThisFrame then
            Sch.SkipPlanThisFrame()
        end
    end
    if StockPiler.Garden and StockPiler.Garden.OnCultivationUpdated then
        StockPiler.Garden.OnCultivationUpdated(plotNum)
    elseif StockPiler.Garden and StockPiler.Garden.SyncAll then
        StockPiler.Garden.SyncAll()
    end
    if StockPiler.Grow and StockPiler.Grow.OnCultivationUpdated then
        StockPiler.Grow.OnCultivationUpdated(plotNum)
    end
    if StockPiler.LearnBridge and StockPiler.LearnBridge.OnCultivationUpdated then
        StockPiler.LearnBridge.OnCultivationUpdated()
    end
    -- Footer via coalesced flush only - never SyncActionReadiness per plot.
    local suppressed = Sch and Sch.IsSuppressed and Sch.IsSuppressed() == true
    local settling = Sch and Sch.IsSessionSettling and Sch.IsSessionSettling() == true
    if not suppressed and not settling then
        RequestFooterViaBus({ reason = "cultivation-updated" })
    end
    if Grow and Grow.NeedsCurrentStageAdditive and Grow.NeedsCurrentStageAdditive()
        and Sch and Sch.WakeAutoGrow
        and not suppressed
    then
        Sch.WakeAutoGrow()
    end
    if StockPiler.Perf and StockPiler.Perf.End then
        StockPiler.Perf.End("CultivationUpdated")
    end
end

function Bridge.OnTradeSkillUpdated()
    local Caps = StockPiler.TradeSkillCaps
    -- Pulse clears _pendingLoadRefresh; capture before so CORE-3 reset can fire (#34).
    local pendingAtPulse = Caps and Caps._pendingLoadRefresh == true
    if Caps and Caps.OnTradeSkillPulse then
        Caps.OnTradeSkillPulse()
    elseif Caps and Caps.MarkTradeSkillsReady then
        Caps.MarkTradeSkillsReady()
    end
    local cult = Caps and Caps.GetCultSkill and Caps.GetCultSkill() or 0
    local apo = Caps and Caps.GetApoSkill and Caps.GetApoSkill() or 0
    local levelsHash = Caps and Caps.LevelsHash and Caps.LevelsHash()
        or (tostring(cult) .. ":" .. tostring(apo))
    local prevHash = Bridge._skillLevelsHash
    local hashChanged = prevHash ~= levelsHash
    local firstSkillsReady = Bridge._skillsWereReady ~= true
        and (cult > 0 or apo > 0)
    Bridge._skillLevelsHash = levelsHash
    if cult > 0 or apo > 0 then
        Bridge._skillsWereReady = true
    end
    -- Cult often arrives one TRADE_SKILL_UPDATED before Apo. Scrubbing potion
    -- watches while apo still reads 0 was wiping every marked L1-L200 watch.
    if apo > 0 then
        Bridge._apoSkillSeen = true
    end
    if cult > 0 then
        Bridge._cultSkillSeen = true
    end

    local function RunSkillDropReset(detail)
        if Caps and Caps.ResetTradeSkillsReady then
            Caps.ResetTradeSkillsReady()
        end
        Bridge._skillsWereReady = false
        Bridge._apoSkillSeen = false
        Bridge._cultSkillSeen = false
        Bridge._skillLevelsHash = nil
        Bridge._skillPrev = nil
        Bridge._skillPrevAtLoad = nil
        if StockPiler.Debug and StockPiler.Debug.LogOp then
            StockPiler.Debug.LogOp("caps", "skill-drop-reset " .. tostring(detail or ""))
        end
    end

    -- Live readers return level, explicit. An empty/unknown 0 is not a drop:
    -- cult often arrives one pulse before apo on a normal zone load (#50 L14).
    -- Explicit 0 still counts, including a single-source 0 sticky refuses (#47).
    local function ReadLiveSkill(reader, fallback)
        if type(reader) == "function" then
            local level, explicit = reader()
            return tonumber(level) or 0, explicit == true
        end
        return tonumber(fallback) or 0, false
    end

    local function LiveZeroIsDrop(level, explicit, prevLevel)
        return explicit == true and level <= 0 and (tonumber(prevLevel) or 0) >= 5
    end

    local prev = Bridge._skillPrev
    if type(prev) ~= "table" then
        -- First sample after load: compare against the pre-load sample when a
        -- pending refresh drop is live (#34). Sticky may still hold the old
        -- level on the first explicit 0, so drop deltas use live reads (#47).
        local atLoad = Bridge._skillPrevAtLoad
        if pendingAtPulse and type(atLoad) == "table" then
            local prevCult = tonumber(atLoad.cult) or 0
            local prevApo = tonumber(atLoad.apo) or 0
            local liveCult, cultExplicit = ReadLiveSkill(Caps and Caps.ReadCultSkillLive, cult)
            local liveApo, apoExplicit = ReadLiveSkill(Caps and Caps.ReadApoSkillLive, apo)
            local dropCult = liveCult - prevCult
            local dropApo = liveApo - prevApo
            local liveDrop = LiveZeroIsDrop(liveCult, cultExplicit, prevCult)
                or LiveZeroIsDrop(liveApo, apoExplicit, prevApo)
            if (dropCult <= -5 or dropApo <= -5) and liveDrop then
                RunSkillDropReset(string.format(
                    "at-load cult=%d->%d explicit=%s apo=%d->%d explicit=%s",
                    prevCult, liveCult, tostring(cultExplicit),
                    prevApo, liveApo, tostring(apoExplicit)
                ))
                return
            end
        end
        Bridge._skillPrev = { cult = cult, apo = apo }
        Bridge._skillPrevAtLoad = nil
        hashChanged = true
    else
        -- Read the previous sample before overwriting it. liveDrop used to see
        -- the new value, so a real drop (200 -> 0) was missed and the next
        -- pulse recorded a +200 skill-up (CORE-3).
        local prevCult = tonumber(prev.cult) or cult
        local prevApo = tonumber(prev.apo) or apo
        local dCult = cult - prevCult
        local dApo = apo - prevApo
        prev.cult = cult
        prev.apo = apo
        -- Logout / char switch: ignore large negative jumps.
        -- Use live reads so sticky cache cannot hide a real char swap (#47).
        local liveCult, cultExplicit = ReadLiveSkill(Caps and Caps.ReadCultSkillLive, cult)
        local liveApo, apoExplicit = ReadLiveSkill(Caps and Caps.ReadApoSkillLive, apo)
        local liveDrop = LiveZeroIsDrop(liveCult, cultExplicit, prevCult)
            or LiveZeroIsDrop(liveApo, apoExplicit, prevApo)
        local dropCult = (pendingAtPulse and liveCult or cult) - prevCult
        local dropApo = (pendingAtPulse and liveApo or apo) - prevApo
        if (dropCult <= -5 or dropApo <= -5) and liveDrop and pendingAtPulse then
            RunSkillDropReset(string.format(
                "pending cult=%d->%d explicit=%s apo=%d->%d explicit=%s",
                prevCult, liveCult, tostring(cultExplicit),
                prevApo, liveApo, tostring(apoExplicit)
            ))
            return
        end
        -- Positive skill-up deltas stay on sticky values so a char-switch
        -- upward cannot record a live-read skill-up.
        local SkillUp = StockPiler.SkillUp
        if dCult > 0 and SkillUp and SkillUp.OnCultSkillDelta then
            SkillUp.OnCultSkillDelta(dCult)
        end
        if dApo > 0 and SkillUp and SkillUp.OnApoSkillDelta then
            SkillUp.OnApoSkillDelta(dApo)
        end
    end

    if hashChanged or firstSkillsReady then
        -- Defer over-skill scrub until the skill we need has been observed.
        -- DisableOverSkillWatches itself also no-ops potion/plant sides at 0.
        local canScrub = (Bridge._apoSkillSeen == true) or (Bridge._cultSkillSeen == true)
        if canScrub and StockPiler.Watch and StockPiler.Watch.DisableOverSkillWatches then
            StockPiler.Watch.DisableOverSkillWatches({ notify = firstSkillsReady and apo > 0 })
        end
        -- Skill tier floors change refine eligibility without bag deltas; bust
        -- sticky empty CollectIntents latch (issue #11 / 0.3.256 regression).
        local Refine = StockPiler.Refine
        if Refine and Refine.InvalidateIntentCache then
            Refine.InvalidateIntentCache()
        end
        if Refine and Refine.MarkRefineDue then
            Refine.MarkRefineDue("skill")
        end
        local SkillUp = StockPiler.SkillUp
        if SkillUp and SkillUp.DropToggleIfUnlearned then
            SkillUp.DropToggleIfUnlearned()
        end
        if SkillUp and SkillUp.AdoptReadySkills then
            SkillUp.AdoptReadySkills()
        end
        if StockPiler.Scheduler and StockPiler.Scheduler.EnqueuePlanRebuild then
            StockPiler.Scheduler.EnqueuePlanRebuild()
        end
        -- Cached rows keep need_skill until a watched threshold is crossed.
        -- This does not BuildFull on an unrelated +1 skill point.
        if StockPiler.Planner and StockPiler.Planner.RefreshSkillGateStatuses then
            StockPiler.Planner.RefreshSkillGateStatuses()
        end
        if StockPiler.Ui and StockPiler.Ui.InvalidateSkillGates then
            StockPiler.Ui.InvalidateSkillGates()
        end
        if StockPiler.Ui and StockPiler.Ui.RefreshCatalogRows then
            StockPiler.Ui.RefreshCatalogRows()
        end
        RequestFooterViaBus({ reason = "trade-skills" })
        if firstSkillsReady and cult > 0
            and StockPiler.Scheduler and StockPiler.Scheduler.WakeAutoGrow
        then
            StockPiler.Scheduler.WakeAutoGrow()
        end
        if StockPiler.Debug and StockPiler.Debug.LogOp then
            local liveCult = Caps and Caps.ReadCultSkillLive and Caps.ReadCultSkillLive() or cult
            local liveApo = Caps and Caps.ReadApoSkillLive and Caps.ReadApoSkillLive() or apo
            StockPiler.Debug.LogOp("caps", string.format(
                "trade-skill-updated cult=%d apo=%d live=%d/%d first=%s",
                cult, apo, liveCult, liveApo, tostring(firstSkillsReady)
            ))
        end
    end
end

--- Trainer / interact closed: GameData may update a tick after TRADE_SKILL_UPDATED.
function Bridge.OnInteractDone()
    Bridge.OnTradeSkillUpdated()
    local VA = StockPiler.VendorAdapter
    local storeOpen = VA and VA.IsStoreOpen and VA.IsStoreOpen() == true
    local interactionOpen = VA and VA.IsNonStoreInteractionOpen and VA.IsNonStoreInteractionOpen() == true
    if storeOpen ~= true and interactionOpen ~= true then
        if StockPiler.Refine and StockPiler.Refine.MarkRefineDue then
            StockPiler.Refine.MarkRefineDue("interaction-closed")
        end
        if StockPiler.Scheduler and StockPiler.Scheduler.WakeAutoGrow then
            StockPiler.Scheduler.WakeAutoGrow()
        end
    end
end

function Bridge.OnStoreShow()
    if StockPiler.VendorAdapter then
        if StockPiler.VendorAdapter.EnsureStoreHook then
            StockPiler.VendorAdapter.EnsureStoreHook()
        end
        if StockPiler.VendorAdapter.OnStoreShow then
            StockPiler.VendorAdapter.OnStoreShow()
        end
    end
    if StockPiler.Buy and StockPiler.Buy.OnStoreShow then
        StockPiler.Buy.OnStoreShow()
    end
    if StockPiler.Scheduler and StockPiler.Scheduler.WakeAutoBuy then
        StockPiler.Scheduler.WakeAutoBuy()
    end
end

function Bridge.OnLoadingEnd()
    Bridge._loadingEndSeen = true
    local Caps = StockPiler.TradeSkillCaps
    if Caps and Caps.BeginLoadSkillRefresh then
        Caps.BeginLoadSkillRefresh()
    end
    if Caps and Caps.ResetTradeSkillsReady then
        Caps.ResetTradeSkillsReady()
    end
    -- Keep the last sample so the first post-load pulse can detect a real drop (#34).
    local prev = Bridge._skillPrev
    if type(prev) == "table" then
        Bridge._skillPrevAtLoad = {
            cult = tonumber(prev.cult) or 0,
            apo = tonumber(prev.apo) or 0,
        }
    else
        Bridge._skillPrevAtLoad = nil
    end
    Bridge._skillLevelsHash = nil
    Bridge._skillPrev = nil
    Bridge._skillsWereReady = false
    Bridge._apoSkillSeen = false
    Bridge._cultSkillSeen = false
    local Sch = StockPiler.Scheduler
    -- Defer SyncAll + skip plan/UI this frame so SESSION_LOADED cannot pile
    -- CultivationUpdated x4 with Planner.Build / RefreshWatch (10s hitch).
    if Sch and Sch.SkipPlanThisFrame then
        Sch.SkipPlanThisFrame()
    end
    if Sch and Sch.SkipUiThisFrame then
        Sch.SkipUiThisFrame()
    end
    if StockPiler.Garden then
        if StockPiler.Garden.MarkSyncAllDue then
            StockPiler.Garden.MarkSyncAllDue()
        elseif StockPiler.Garden.SyncAll then
            StockPiler.Garden.SyncAll()
        end
    end
    if StockPiler.Inventory and StockPiler.Inventory.ForceFullRefresh then
        StockPiler.Inventory.ForceFullRefresh()
    elseif StockPiler.Inventory and StockPiler.Inventory.MarkDirty then
        StockPiler.Inventory.MarkDirty({ reason = "loading-end", full = true })
    end
    local E = StockPiler.Events
    if E and E.SESSION_LOADED then
        BusFire(E.SESSION_LOADED, { reason = "loading-end" })
    end
    -- Hotbars may be empty until this event. Warn only once buttons exist.
    if StockPiler.Macro and StockPiler.Macro.WarnIfCraftUnplaced then
        pcall(StockPiler.Macro.WarnIfCraftUnplaced)
    end
end

function Bridge.OnCombatFlagUpdated()
    -- Light: combat pause is consulted on Orch plant path; dirty footer readiness only.
    RequestFooterViaBus({ reason = "combat-flag" })
end

local STAGE_FAIL_WARN = 30

local function RunStage(name, fn)
    local Util = StockPiler.Util
    local ok = false
    if Util and Util.TryCallQuiet then
        ok = Util.TryCallQuiet(name, fn) == true
    else
        ok = pcall(fn) == true
    end
    Bridge._stageFailStreak = Bridge._stageFailStreak or {}
    if ok then
        Bridge._stageFailStreak[name] = 0
        return
    end
    local n = (tonumber(Bridge._stageFailStreak[name]) or 0) + 1
    Bridge._stageFailStreak[name] = n
    if n >= STAGE_FAIL_WARN and Bridge._stageFailChatWarned ~= true then
        Bridge._stageFailChatWarned = true
        local Debug = StockPiler.Debug
        if Debug and Debug.Reply then
            local msg = StockPiler.T and StockPiler.T("boot.stage_skipped") or nil
            if msg ~= nil then
                Debug.Reply(msg)
            end
        end
    end
end

local function RunUpdateProcessed(timeElapsed)
    StockPiler.FrameCounter = (tonumber(StockPiler.FrameCounter) or 0) + 1

    -- Each stage is isolated. One throw must not stop later automation.
    RunStage("perf", function()
        local Perf = StockPiler.Perf
        if Perf and Perf.OnFrame and Perf.Available ~= true then
            Perf.OnFrame(timeElapsed)
        end
    end)

    RunStage("garden", function()
        if StockPiler.Garden and StockPiler.Garden.FlushPendingSyncAll then
            StockPiler.Garden.FlushPendingSyncAll()
        end
    end)

    RunStage("slots", function()
        Bridge.FlushPendingMainSlots()
        Bridge.FlushPendingCraftSlots()
    end)

    RunStage("snapshot", function()
        if StockPiler.Inventory and StockPiler.Inventory.FlushPendingSnapGen then
            StockPiler.Inventory.FlushPendingSnapGen()
        end
    end)

    RunStage("learn", function()
        if StockPiler.LearnBridge and StockPiler.LearnBridge.OnUpdateProcessed then
            StockPiler.LearnBridge.OnUpdateProcessed()
        end
    end)

    RunStage("refine", function()
        if StockPiler.Refine and StockPiler.Refine.OnUpdateProcessed then
            StockPiler.Refine.OnUpdateProcessed(timeElapsed)
        elseif StockPiler.Refine and StockPiler.Refine.OnUpdate then
            StockPiler.Refine.OnUpdate(timeElapsed)
        end
    end)

    RunStage("scheduler", function()
        if StockPiler.Scheduler and StockPiler.Scheduler.OnUpdate then
            StockPiler.Scheduler.OnUpdate(timeElapsed)
        end
    end)

    RunStage("open-paint", function()
        if StockPilerWindow and StockPilerWindow.FlushOpenPaint then
            StockPilerWindow.FlushOpenPaint()
        end
        if StockPilerTabWatch and StockPilerTabWatch.FlushChromeRepaint then
            StockPilerTabWatch.FlushChromeRepaint()
        end
    end)

    RunStage("macro", function()
        if StockPiler.Macro and StockPiler.Macro.DrainEnabledSync then
            StockPiler.Macro.DrainEnabledSync()
        end
        if StockPiler.Macro and StockPiler.Macro.DrainEnableReassert then
            StockPiler.Macro.DrainEnableReassert()
        end
    end)

    RunStage("harvest-timer", function()
        if StockPiler.CraftHarvestTimer and StockPiler.CraftHarvestTimer.OnUpdate then
            StockPiler.CraftHarvestTimer.OnUpdate(timeElapsed)
        end
    end)

    RunStage("footer", function()
        local Sch = StockPiler.Scheduler
        local holdFooter = Sch and Sch.SkipUiHoldFooter and Sch.SkipUiHoldFooter() == true
        if not holdFooter and StockPilerWindow and StockPilerWindow.FlushPendingFooterRefresh then
            StockPilerWindow.FlushPendingFooterRefresh()
        end
        if Sch and Sch.ClearSkipUiHoldFooter then
            Sch.ClearSkipUiHoldFooter()
        end
    end)

    RunStage("list", function()
        if StockPilerWindow and StockPilerWindow.FlushPendingListRepopulate
            and StockPilerWindow._repopulatePending == true
        then
            StockPilerWindow.FlushPendingListRepopulate()
        end
    end)
end

function Bridge.OnUpdateProcessed(timeElapsed)
    if Bridge._inUpdate == true then
        return
    end
    Bridge._inUpdate = true
    local ok, err = pcall(RunUpdateProcessed, timeElapsed)
    Bridge._inUpdate = false
    if ok ~= true and StockPiler.Debug and StockPiler.Debug.ReportProtectedCallFailure then
        StockPiler.Debug.ReportProtectedCallFailure("Bridge.OnUpdateProcessed", err, true)
    end
end

local function RegisterOne(ev, eventKey, handlerName)
    local eventId = ev[eventKey]
    if eventId == nil then
        if StockPiler.Debug and StockPiler.Debug.LogAlways then
            StockPiler.Debug.LogAlways("engine bridge skip missing event " .. tostring(eventKey))
        end
        return false
    end
    local host = HostWindow()
    if type(WindowRegisterEventHandler) == "function" then
        WindowRegisterEventHandler(host, eventId, handlerName)
        TrackHandler(eventId, handlerName)
    elseif type(RegisterEventHandler) == "function" then
        RegisterEventHandler(eventId, handlerName)
        TrackHandler(eventId, handlerName)
    else
        return false
    end
    return true
end

function Bridge.Register()
    if Bridge._registered == true then
        return
    end
    local ev = Events()
    if type(ev) ~= "table" then
        return
    end
    Bridge._handlers = {}
    local prefix = "StockPiler.EngineEventBridge."
    -- Parity with EA_Window_Backpack + DataUtils:
    --   PLAYER_INVENTORY_SLOT_UPDATED -> main bag
    --   PLAYER_CRAFTING_SLOT_UPDATED  -> craft bag (apo mats)
    --   PLAYER_CRAFTING_INVENTORY_UPDATED -> craft bag capacity / full rebuild
    RegisterOne(ev, "PLAYER_INVENTORY_SLOT_UPDATED", prefix .. "OnInventoryUpdated")
    RegisterOne(ev, "PLAYER_CRAFTING_SLOT_UPDATED", prefix .. "OnCraftingSlotUpdated")
    RegisterOne(ev, "PLAYER_CRAFTING_INVENTORY_UPDATED", prefix .. "OnCraftingInventoryUpdated")
    RegisterOne(ev, "PLAYER_CRAFTING_UPDATED", prefix .. "OnCraftingUpdated")
    RegisterOne(ev, "PLAYER_CULTIVATION_UPDATED", prefix .. "OnCultivationUpdated")
    RegisterOne(ev, "TRADE_SKILL_UPDATED", prefix .. "OnTradeSkillUpdated")
    RegisterOne(ev, "INTERACT_DONE", prefix .. "OnInteractDone")
    RegisterOne(ev, "LOADING_END", prefix .. "OnLoadingEnd")
    RegisterOne(ev, "INTERACT_SHOW_STORE", prefix .. "OnStoreShow")
    RegisterOne(ev, "UPDATE_PROCESSED", prefix .. "OnUpdateProcessed")
    RegisterOne(ev, "PLAYER_COMBAT_FLAG_UPDATED", prefix .. "OnCombatFlagUpdated")
    Bridge._registered = true
    if StockPiler.Debug and StockPiler.Debug.LogAlways then
        StockPiler.Debug.LogAlways("init engine event bridge registered")
    end
end

local function LoadingScreenShowing()
    local names = { "EA_Window_LoadingScreen", "LoadingScreen" }
    for i = 1, #names do
        local n = names[i]
        if type(DoesWindowExist) == "function" and DoesWindowExist(n)
            and type(WindowGetShowing) == "function" and WindowGetShowing(n) == true
        then
            return true
        end
    end
    return false
end

--- /reload often fires LOADING_END before this bridge registers; synthesize it
--- once the loading screen is already gone so AutoGrow is not stuck settling.
function Bridge.MaybeCatchUpLoadingEnd()
    if Bridge._loadingEndSeen == true then
        return
    end
    if LoadingScreenShowing() then
        return
    end
    if StockPiler.Debug and StockPiler.Debug.LogAlways then
        StockPiler.Debug.LogAlways("session catch-up loading-end (event missed)")
    end
    Bridge.OnLoadingEnd()
end

function Bridge.Unregister()
    if Bridge._registered ~= true then
        return
    end
    local host = HostWindow()
    local handlers = Bridge._handlers
    if type(handlers) == "table" then
        for i = 1, #handlers do
            local entry = handlers[i]
            if type(entry) == "table" and entry.event ~= nil and entry.handler then
                if type(WindowUnregisterEventHandler) == "function" then
                    WindowUnregisterEventHandler(host, entry.event)
                elseif type(UnregisterEventHandler) == "function" then
                    UnregisterEventHandler(entry.event, entry.handler)
                end
            end
        end
    end
    Bridge._handlers = {}
    Bridge._registered = false
    Bridge._pendingMainApply = false
    Bridge._pendingCraftApply = false
    Bridge._pendingMainSlots = nil
    Bridge._pendingCraftSlots = nil
    Bridge._pendingMainSlotSet = nil
    Bridge._pendingCraftSlotSet = nil
    Bridge._loadingEndSeen = false
end

function Bridge.Initialize()
    Bridge.Register()
end

function Bridge.Shutdown()
    Bridge.Unregister()
end
