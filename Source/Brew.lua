----------------------------------------------------------------
-- StockPiler Brew -- session FSM + load job + IssueOne perform
-- Phases idle -> loading -> loaded. Load: reset -> open -> clear -> load.
-- Callees above callers.
----------------------------------------------------------------

StockPiler = StockPiler or {}
StockPiler.Brew = StockPiler.Brew or {}
local Brew = StockPiler.Brew

Brew.ADOPT_BLOCK_SEC = 1.5
Brew.BREW_OP_LOCK_SEC = 1.25
-- After load-done, engine SuccessChance / GetSlottedItem can lag a few frames.
-- Unloading immediately loops load->unload while the footer stays lit.
Brew.LOAD_SETTLE_SEC = 1.25
Brew.LOAD_ABORT_BACKOFF_SEC = 4
Brew.LOAD_STEP_WAIT_TICKS = 60
Brew.LOAD_VERIFY_TICKS = 12
-- A manual board left in phase "loaded" keeps Orch.IsBrewSessionActive true,
-- so AutoGrow never plants. Unload after this long with no perform or bag move.
Brew.MANUAL_LOADED_IDLE_SEC = 60
-- Probe interval for auto-loaded boards that never get another crafting-updated
-- (settle hold then silence). Stuck loaded blocks AutoGrow + plan rebuild.
Brew.STUCK_PROBE_SEC = 0.5
-- Open phase: call OpenWindow every OPEN_RETRY_TICKS (not every frame).
-- Per-tick SendInitCrafting buzzes audio when apo skill stays 0.
Brew.OPEN_RETRY_TICKS = 20
-- After open-timeout, latch until zone load / manual Load / apo session up.

Brew._session = Brew._session or { phase = "idle" }
Brew._job = nil
Brew._loadSource = nil -- "auto" | "manual"
-- Row Brew click: load then Perform once settle clears (one-click load+brew).
Brew._performAfterManualLoad = false
-- Honour deferred Perform even if the board was auto-loaded (click on loaded row).
Brew._performAfterLoadIgnoreSource = false
-- Absolute game-time expiry for deferred Perform (settle + TTL).
Brew._performAfterLoadUntil = 0
Brew.PERFORM_AFTER_LOAD_TTL_SEC = 5
Brew._brewOpLockUntil = 0
Brew._adoptBlockUntil = 0
Brew._openFailLatched = false
Brew._loadSettleUntil = 0
Brew._stuckProbeAt = 0
Brew._canBrewCache = nil
Brew._canBrewCacheKey = nil
Brew._brewReadyLatched = false
Brew._readyNotifyKeys = nil -- nil = uninitialized (seed on first observe)
Brew._brewEnableAnnounced = nil -- potion key last chimed for a lit Brew button
Brew._lastHasReady = nil
Brew._wasBusy = false
Brew._awaitingBrewComplete = false
Brew._busTokens = nil
Brew._eventHandlers = nil

local ROLE_LOAD_ORDER = {
    container = 1,
    main = 2,
    stabilizer = 3,
    goldweed = 3,
    extender = 4,
    multiplier = 5,
    stimulant = 5,
    ingredient = 6,
}

----------------------------------------------------------------
-- Helpers
----------------------------------------------------------------

local function NowSec()
    return StockPiler.Util and StockPiler.Util.NowSec and StockPiler.Util.NowSec() or 0
end

local function LogBrew(msg)
    if StockPiler.Debug and StockPiler.Debug.LogOp then
        StockPiler.Debug.LogOp("brew", msg)
    end
end

local function AA()
    return StockPiler.ApothecaryAdapter
end

local function GetSession()
    if type(Brew._session) ~= "table" then
        Brew._session = { phase = "idle" }
    end
    return Brew._session
end

local function SetSessionPhase(phase, reason)
    local session = GetSession()
    local prev = tostring(session.phase or "idle")
    phase = tostring(phase or "idle")
    session.phase = phase
    local Orch = StockPiler.Orchestrator
    if Orch and Orch.SetBrewPhase then
        Orch.SetBrewPhase(phase == "idle" and nil or phase)
    end
    if phase == "loaded" or phase == "loading" then
        if Brew._loadSource == "manual" then
            Brew._manualLoadedActivityAt = NowSec()
        end
    else
        Brew._manualLoadedActivityAt = 0
    end
    if prev ~= phase then
        LogBrew("session " .. prev .. "->" .. phase .. " reason=" .. tostring(reason or "?"))
        local Bus = StockPiler.EventBus
        if Bus and Bus.FireBrewSessionChanged then
            Bus.FireBrewSessionChanged({
                phase = phase,
                prev = prev,
                reason = tostring(reason or ""),
                loadSource = Brew._loadSource,
            })
        end
    end
end

local function CurrentPlan()
    if StockPiler.PlanSnapshot and StockPiler.PlanSnapshot.GetOrBuild then
        return StockPiler.PlanSnapshot.GetOrBuild({ refresh = false })
    end
    if StockPiler.Planner and StockPiler.Planner.GetOrBuild then
        return StockPiler.Planner.GetOrBuild({ refresh = false })
    end
    return StockPiler.PlanSnapshot and StockPiler.PlanSnapshot.Get and StockPiler.PlanSnapshot.Get()
end

local function PotionOutputUid(rowOrSession)
    if type(rowOrSession) ~= "table" then
        return 0
    end
    local uid = tonumber(rowOrSession.uniqueID)
        or tonumber(rowOrSession.outputUid)
        or tonumber(rowOrSession.potionUid)
        or 0
    if uid <= 0 and type(rowOrSession.potionKey) == "string" then
        local m = string.match(rowOrSession.potionKey, "uid:(%d+)")
        uid = tonumber(m) or 0
    end
    if uid <= 0 and type(rowOrSession.potionRecipeKey) == "string" then
        local m = string.match(rowOrSession.potionRecipeKey, "uid:(%d+)")
        uid = tonumber(m) or 0
    end
    if uid <= 0 and type(rowOrSession.potionBaseKey) == "string" then
        local m = string.match(rowOrSession.potionBaseKey, "uid:(%d+)")
        uid = tonumber(m) or 0
    end
    return uid
end

--- Live bag count for the watch potion (nil if uid unknown / inventory not ready).
--- CountByUid returns 0 while Inv is not ready - that must not look like "0 stock"
--- or PickReadyWatch / auto-load will brew already-stocked watches mid bag-flush.
local function LivePotionHave(rowOrSession)
    local uid = PotionOutputUid(rowOrSession)
    if uid <= 0 then
        return nil
    end
    local Inv = StockPiler.Inventory
    if not Inv then
        return nil
    end
    if Inv.IsReady and Inv.IsReady() ~= true then
        return nil
    end
    local snapPending = false
    if Inv.IsSnapshotPending then
        snapPending = Inv.IsSnapshotPending() == true
    else
        snapPending = Inv._snapPending == true
    end
    if snapPending then
        return nil
    end
    if Inv.CountByUid then
        return tonumber(Inv.CountByUid(uid)) or 0
    end
    return nil
end

local function PotionTargetMin(rowOrSession)
    if type(rowOrSession) ~= "table" then
        return 0
    end
    return tonumber(rowOrSession.potionMin) or tonumber(rowOrSession.target) or 0
end

--- True while bag stock is still below the watch target (live bags preferred).
local function RowNeedsMorePotions(rowOrSession)
    if type(rowOrSession) ~= "table" then
        return false
    end
    local min = PotionTargetMin(rowOrSession)
    if min <= 0 then
        return false
    end
    local live = LivePotionHave(rowOrSession)
    -- Nil means the bag count is not ready. Do not substitute the cached plan count.
    if live == nil then
        return nil
    end
    return live < min
end

local function RowIsReadyToCraft(row)
    if type(row) ~= "table" then
        return false
    end
    if row.kind == "plant" or row.isPlantWatch == true then
        return false
    end
    -- SkillUp Apo synthetic row: bags can craft; no watch / AutoGrow arm required.
    if row.skillUp == true then
        local SkillUp = StockPiler.SkillUp
        -- Apo at max (or toggle off) must not stay Ready from a stale plan row.
        if not SkillUp or SkillUp.ShouldApoBrew == nil or SkillUp.ShouldApoBrew() ~= true then
            return false
        end
        if (tonumber(row.craftable) or 0) <= 0 then
            return false
        end
        if tostring(row.statusKey or "") == "craft_bag_full" then
            return false
        end
        -- Synthetic apo brew has no potion uid. LivePotionHave is nil then, so
        -- RowNeedsMorePotions stays false and auto-load never starts.
        if PotionOutputUid(row) <= 0 then
            return true
        end
        return RowNeedsMorePotions(row) == true
    end
    -- Live bags win over stale plan deficit (prevents over-brew after target met).
    if not RowNeedsMorePotions(row) then
        return false
    end
    if (tonumber(row.potionDeficit) or 0) <= 0 then
        return false
    end
    if row.statusKey ~= "ready_to_craft" then
        return false
    end
    -- Cultivators: AutoBrew only for AutoGrow-armed watches.
    -- Apo/Butcher-only: Ready status is enough (no Cultivation to arm).
    local Caps = StockPiler.TradeSkillCaps
    local canGrow = Caps and Caps.CanAutoGrow and Caps.CanAutoGrow() == true
    if canGrow then
        local pk = row.potionKey or row.potionRecipeKey or row.id
        local Watch = StockPiler.Watch
        local RS = StockPiler.RecipeSpec
        if RS and RS.ShouldAutoGrowPotion then
            if RS.ShouldAutoGrowPotion(pk, nil) ~= true then
                return false
            end
        elseif Watch and Watch.IsAutoGrowEnabled and Watch.IsAutoGrowEnabled() ~= true then
            return false
        elseif row.autoGrow ~= true then
            return false
        end
    end
    local craftable = tonumber(row.craftable) or 0
    if craftable <= 0 then
        return false
    end
    if row.craftableShared == true then
        return false
    end
    -- Wait until bags+craftable cover the watch target (partial mats -> AutoGrow first).
    local have = tonumber(row.potionHave) or 0
    local target = tonumber(row.potionMin) or tonumber(row.target) or 0
    if target > 0 and (have + craftable) < target then
        return false
    end
    return true
end

local function RowCanPrematureLoad(row)
    -- Manual load follows the green Craftable column (Ready, target covered).
    if type(row) ~= "table" then
        return false
    end
    if row.craftableSafe == true then
        return true
    end
    if row.craftableSafe == false then
        return false
    end
    if (tonumber(row.craftable) or 0) <= 0 then
        return false
    end
    return row.seedBufferShort ~= true
end

local function CompareReadyWatch(a, b)
    local da = tonumber(a.potionDeficit) or 0
    local db = tonumber(b.potionDeficit) or 0
    if da ~= db then
        return da > db
    end
    return tostring(a.name or "") < tostring(b.name or "")
end

local function FindSessionRow()
    local session = GetSession()
    if session.phase == "idle" and session.potionKey == nil and session.rowId == nil then
        return nil
    end
    if session.skillUp == true then
        local SkillUp = StockPiler.SkillUp
        local row = SkillUp and SkillUp.GetApoBrewRow and SkillUp.GetApoBrewRow()
        if type(row) == "table" then
            return row
        end
        if type(Brew._skillUpRow) == "table" then
            return Brew._skillUpRow
        end
        -- Fall back to session fields so Ready checks still work mid-brew.
        return session
    end
    local plan = CurrentPlan()
    local rows = plan and plan.rows
    if type(rows) ~= "table" then
        return nil
    end
    for i = 1, #rows do
        local row = rows[i]
        if type(row) == "table" then
            if session.rowId ~= nil and row.id == session.rowId then
                return row
            end
            if session.potionKey ~= nil and row.potionKey == session.potionKey then
                return row
            end
        end
    end
    return nil
end

local function SyncSessionStockFromBags(session)
    if type(session) ~= "table" then
        return
    end
    local live = LivePotionHave(session)
    if live == nil then
        local row = FindSessionRow()
        if type(row) == "table" then
            live = LivePotionHave(row)
            if (tonumber(session.uniqueID) or 0) <= 0 then
                session.uniqueID = PotionOutputUid(row)
            end
            if session.potionMin == nil then
                session.potionMin = PotionTargetMin(row)
            end
        end
    end
    if live == nil then
        return
    end
    session.potionHave = live
    local min = PotionTargetMin(session)
    if min > 0 then
        session.potionDeficit = math.max(0, min - live)
    end
end

--- Mark plan row stocked immediately so PickReadyWatch cannot re-arm from a stale plan.
local function PatchPlanRowTargetMet(session, liveHave)
    local plan = CurrentPlan()
    local rows = plan and plan.rows
    if type(rows) ~= "table" or type(session) ~= "table" then
        return
    end
    local key = tostring(session.potionKey or session.rowId or "")
    local uid = PotionOutputUid(session)
    local have = tonumber(liveHave) or tonumber(session.potionHave) or 0
    local min = PotionTargetMin(session)
    for i = 1, #rows do
        local row = rows[i]
        if type(row) == "table" then
            local rowKey = tostring(row.potionKey or row.id or row.potionRecipeKey or "")
            local rowUid = PotionOutputUid(row)
            if (key ~= "" and rowKey == key) or (uid > 0 and rowUid == uid) then
                row.potionHave = have
                row.potionDeficit = math.max(0, min - have)
                if row.potionDeficit <= 0 then
                    local recipe = row.recipe
                    local bufferShort = false
                    local Watch = StockPiler.Watch
                    local RS = StockPiler.RecipeSpec
                    if Watch and Watch.IsSeedBufferEnabled and Watch.IsSeedBufferEnabled() == true
                        and RS and RS.WatchHasSeedBufferShort and type(recipe) == "table"
                        and RS.ShouldAutoGrowPotion
                        and RS.ShouldAutoGrowPotion(row.potionKey or row.potionRecipeKey or row.id, nil) == true
                    then
                        local seedUids = row.seedBufferSeedUids
                        local plantUids = row.seedBufferPlantUids
                        if type(seedUids) ~= "table" or #seedUids == 0 then
                            seedUids = {}
                            plantUids = type(plantUids) == "table" and plantUids or {}
                            local tips = row.statusTipSlots
                            if type(tips) == "table" then
                                local seen = {}
                                local seenPlant = {}
                                for t = 1, #tips do
                                    local tip = tips[t]
                                    local uid = tonumber(tip and tip.seedUid) or 0
                                    local pUid = tonumber(tip and tip.plantUid) or 0
                                    if uid > 0 and seen[uid] ~= true then
                                        seen[uid] = true
                                        seedUids[#seedUids + 1] = uid
                                    elseif uid <= 0 and pUid > 0 and seenPlant[pUid] ~= true then
                                        seenPlant[pUid] = true
                                        plantUids[#plantUids + 1] = pUid
                                    end
                                end
                            end
                        end
                        bufferShort = RS.WatchHasSeedBufferShort(recipe, {
                            seedUids = seedUids,
                            plantUids = plantUids,
                        }) == true
                    end
                    if bufferShort then
                        row.statusKey = "need_seeds"
                        if StockPiler.T then
                            row.statusText = StockPiler.T("plan.status.need_seeds")
                        else
                            row.statusText = L"Seed buffer"
                        end
                    else
                        row.statusKey = "potion_stocked"
                        if StockPiler.T then
                            row.statusText = StockPiler.T("plan.status.potion_stocked")
                        else
                            row.statusText = L"Potions stocked"
                        end
                    end
                    row.craftable = 0
                end
                return
            end
        end
    end
end

local function RoleLoadRank(role)
    return ROLE_LOAD_ORDER[tostring(role or "")] or 99
end

local function AssignCraftingSlot(role, supplementSlot)
    role = tostring(role or "")
    if role == "container" then
        return (ApothecaryWindow and ApothecaryWindow.SLOT_CONTAINER) or 0, supplementSlot
    end
    if role == "main" then
        return (ApothecaryWindow and ApothecaryWindow.SLOT_DETERMINENT) or 1, supplementSlot
    end
    local maxSlot = (ApothecaryWindow and ApothecaryWindow.SLOT_INGREDIENT3) or 4
    if supplementSlot > maxSlot then
        return nil, supplementSlot
    end
    return supplementSlot, supplementSlot + 1
end

--- Expand saved recipe slots into apo craft-slot steps.
--- Phase 1: every fingerprint role at learned perCraft (exact recipe - no skipped modifiers).
--- Phase 2: stabilizer top-ups into leftover slots only (does not drop phase-1 roles).
--- Returns steps, ok - ok=false if a saved role cannot be placed (refuse incomplete load).
local function BuildLoadSteps(recipe)
    local steps = {}
    if type(recipe) ~= "table" or type(recipe.slots) ~= "table" then
        return steps, false
    end
    local RS = StockPiler.RecipeSpec
    if RS and RS.HydrateRecipeSlots then
        RS.HydrateRecipeSlots(recipe)
    end
    local sorted = {}
    for i = 1, #recipe.slots do
        local slot = recipe.slots[i]
        if type(slot) == "table" and RS and RS.ResolveSlotSpec then
            RS.ResolveSlotSpec(slot)
        end
        sorted[#sorted + 1] = slot
    end
    table.sort(sorted, function(a, b)
        local ra = RoleLoadRank(a and (a.role or a.materialRole))
        local rb = RoleLoadRank(b and (b.role or b.materialRole))
        if ra ~= rb then
            return ra < rb
        end
        return (tonumber(a and a.index) or 0) < (tonumber(b and b.index) or 0)
    end)

    local function slotUid(slot)
        local uid = tonumber(slot.uniqueID) or tonumber(slot.uid) or 0
        if uid <= 0 and type(slot.spec) == "table" then
            uid = tonumber(slot.spec.uid) or tonumber(slot.spec.uniqueID) or 0
        end
        return uid
    end

    local function appendStep(slot, role, uid, craftingSlot, perCraft)
        steps[#steps + 1] = {
            craftingSlot = craftingSlot,
            uniqueID = uid,
            uid = uid,
            role = role,
            optional = false,
            spec = slot.spec,
            perCraft = perCraft,
        }
    end

    local supplementSlot = (ApothecaryWindow and ApothecaryWindow.SLOT_INGREDIENT1) or 2
    local placedStab = {}

    for i = 1, #sorted do
        local slot = sorted[i]
        if type(slot) == "table" then
            local perCraft = math.max(1, tonumber(slot.perCraft) or 1)
            local uid = slotUid(slot)
            local role = tostring(slot.role or slot.materialRole or "")
            for _ = 1, perCraft do
                local craftingSlot
                craftingSlot, supplementSlot = AssignCraftingSlot(role, supplementSlot)
                if craftingSlot == nil then
                    LogBrew(string.format(
                        "load phase1 fail role=%s uid=%s (no craft slot) - refuse incomplete recipe load",
                        role, tostring(uid)
                    ))
                    return steps, false
                end
                appendStep(slot, role, uid, craftingSlot, perCraft)
                if role == "stabilizer" or role == "goldweed" then
                    placedStab[slot] = (placedStab[slot] or 0) + 1
                end
            end
        end
    end

    for i = 1, #sorted do
        local slot = sorted[i]
        if type(slot) == "table" then
            local role = tostring(slot.role or slot.materialRole or "")
            if role == "stabilizer" or role == "goldweed" then
                local want = math.max(1, tonumber(slot.perCraft) or 1)
                if RS and RS.EffectiveSpecPerCraft then
                    want = tonumber(RS.EffectiveSpecPerCraft(slot, recipe.slots)) or want
                end
                local have = placedStab[slot] or 0
                local uid = slotUid(slot)
                while have < want do
                    local craftingSlot
                    craftingSlot, supplementSlot = AssignCraftingSlot(role, supplementSlot)
                    if craftingSlot == nil then
                        LogBrew(string.format(
                            "load stab top-up capped have=%d want=%d uid=%s",
                            have, want, tostring(uid)
                        ))
                        break
                    end
                    appendStep(slot, role, uid, craftingSlot, want)
                    have = have + 1
                    placedStab[slot] = have
                end
            end
        end
    end
    return steps, true
end

local function BrewRespectGrowReserve()
    local Caps = StockPiler.TradeSkillCaps
    if Caps and Caps.CanAutoGrow and Caps.CanAutoGrow() ~= true then
        return false
    end
    local P = StockPiler.Persistence
    if P and P.GetCharacterBucket then
        local row = P.GetCharacterBucket(false)
        if type(row) == "table" and row.brewRespectGrowReserve == false then
            return false
        end
    end
    return true
end

--- Same slot gate as a manual Apothecary drop. Bonus-thin copies stay eligible.
local function WindowAcceptsBrewItem(item, wantSpec)
    local AA = StockPiler.ApothecaryAdapter
    if not (AA and AA.ItemIsAllowedInSlot) or type(item) ~= "table" then
        return true
    end
    local role = type(wantSpec) == "table" and tostring(wantSpec.role or "") or ""
    local slotType = type(wantSpec) == "table" and tonumber(wantSpec.slotType) or 0
    local craftSlot = 2
    if role == "container" or slotType == 5 or slotType == 6 then
        craftSlot = 0
    elseif role == "main" or slotType == 2 then
        craftSlot = 1
    end
    return AA.ItemIsAllowedInSlot(item, craftSlot) == true
end

--- Find bag item matching recipe slot spec. Prefer non-growable (butcher twins)
--- over cult plants, then craft bag, then smaller stacks.
--- Incomplete mains: prefer boundUid, else ProductMatches twins. Rejects seeds.
--- `reserved` tracks qty already claimed by earlier load steps (same bag slot).
--- Future UI toggle: Persistence brewPreferNonGrowableFirst (default on).
local function FindCraftingBagItemBySpec(wantSpec, exemplarUid, reserved)
    local MS = StockPiler.MaterialSpec
    local SM = StockPiler.SeedMap
    local BA = StockPiler.BagAdapter
    local craftType = (EA_Window_Backpack and EA_Window_Backpack.TYPE_CRAFTING) or 4
    local invType = (EA_Window_Backpack and EA_Window_Backpack.TYPE_INVENTORY) or 2
    reserved = type(reserved) == "table" and reserved or nil

    local preferNonGrowable = true
    local P = StockPiler.Persistence
    if P and P.GetCharacterBucket then
        local row = P.GetCharacterBucket(false)
        -- Default on; set brewPreferNonGrowableFirst=false to spend cult plants first.
        if type(row) == "table" and row.brewPreferNonGrowableFirst == false then
            preferNonGrowable = false
        end
    end

    local function reserveKey(bagType, bagSlot)
        return tostring(bagType or 0) .. ":" .. tostring(bagSlot or 0)
    end

    local function availQty(bagType, bagSlot, liveQty)
        local qty = tonumber(liveQty) or 1
        if qty < 1 then
            qty = 1
        end
        if not reserved then
            return qty
        end
        local used = tonumber(reserved[reserveKey(bagType, bagSlot)]) or 0
        return qty - used
    end

    --- Butcher / vendor twins are non-growable; cult plants are growable.
    local function itemIsGrowable(item)
        if type(item) ~= "table" or not (SM and SM.IsGrowableSpec) then
            return false
        end
        local probe = item
        local parseItem = MS and (MS.FromItemDataCached or MS.FromItemData)
        if parseItem then
            local spec = parseItem(item, nil)
            if type(spec) == "table" then
                if spec.name == nil then
                    spec.name = item.name
                end
                probe = spec
            end
        end
        return SM.IsGrowableSpec(probe) == true
    end

    -- Incomplete mains: keep the learned exemplar as a fallback. Do not return
    -- it yet; a player-bound fingerprint twin must win over an unbound one.
    local fallbackSlot, fallbackItem, fallbackType, fallbackUid = 0, nil, nil, 0
    if type(wantSpec) == "table" and wantSpec.incomplete == true then
        local bound = tonumber(wantSpec.boundUid) or tonumber(exemplarUid) or tonumber(wantSpec.uid) or 0
        if bound > 0 and BA and BA.FindSeedSlot then
            local bagSlot, item, bagType = BA.FindSeedSlot(bound)
            bagType = bagType or craftType
            if bagSlot and bagSlot > 0 then
                local live = tonumber(item and (item.stackCount or item.stackcount)) or 1
                if availQty(bagType, bagSlot, live) >= 1
                    and WindowAcceptsBrewItem(item, wantSpec)
                then
                    fallbackSlot, fallbackItem, fallbackType, fallbackUid = bagSlot, item, bagType, bound
                end
            end
        end
    end

    local bestSlot, bestItem, bestType, bestUid = 0, nil, nil, 0
    local bestQty = nil
    local bestIsCraft = false
    local bestIsGrowable = false
    local bestIsPlayerBound = false

    local function consider(bagSlot, item, bagType, isCraft)
        if type(item) ~= "table" or (tonumber(bagSlot) or 0) <= 0 then
            return
        end
        if MS and MS.IsSeedOrSpore and MS.IsSeedOrSpore(item) == true then
            return
        end
        local match = false
        if type(wantSpec) == "table" and MS then
            if MS.ProductMatches then
                match = MS.ProductMatches(item, wantSpec) == true
            end
            if not match and MS.Matches then
                match = MS.Matches(item, wantSpec) == true
            end
            -- Bag AsItemData is often bonus-thin; enrich from learned Items.
            if not match and StockPiler.Items and StockPiler.Items.ToSpec then
                local iuid = tonumber(item.uniqueID) or 0
                if iuid > 0 then
                    local learned = StockPiler.Items.ToSpec(iuid)
                    if type(learned) == "table" then
                        if MS.ProductMatches then
                            match = MS.ProductMatches(learned, wantSpec) == true
                        end
                        if not match and MS.Matches then
                            match = MS.Matches(learned, wantSpec) == true
                        end
                    end
                end
            end
        end
        if not match then
            return
        end
        local liveQty = tonumber(item.stackCount) or tonumber(item.stackcount) or 1
        local qty = availQty(bagType, bagSlot, liveQty)
        if qty < 1 then
            return
        end
        local uid = tonumber(item.uniqueID) or 0
        if uid > 0 and Brew.IsRejectedCraftUid and Brew.IsRejectedCraftUid(uid) == true then
            return
        end
        if WindowAcceptsBrewItem(item, wantSpec) ~= true then
            return
        end
        local growable = itemIsGrowable(item)
        -- Bound to Player (boundToPlayer). Spend that stack before an unbound twin.
        local playerBound = item.boundToPlayer == true
        local take = false
        if bestSlot <= 0 then
            take = true
        elseif playerBound and not bestIsPlayerBound then
            take = true
        elseif (not playerBound) and bestIsPlayerBound then
            take = false
        elseif preferNonGrowable and (not growable) and bestIsGrowable then
            -- Spend butcher/vendor twins before cult plants (bonus stock).
            take = true
        elseif preferNonGrowable and growable and not bestIsGrowable then
            take = false
        elseif isCraft and not bestIsCraft then
            take = true
        elseif (not isCraft) and bestIsCraft then
            take = false
        elseif isCraft == bestIsCraft and qty < (bestQty or 999999) then
            take = true
        end
        if take then
            bestSlot = bagSlot
            bestItem = item
            bestType = bagType
            bestUid = uid
            bestQty = qty
            bestIsCraft = isCraft == true
            bestIsGrowable = growable == true
            bestIsPlayerBound = playerBound == true
        end
    end

    if BA and BA.IterateSlots and (BA.FetchForce or BA.FetchLight) then
        -- One bag snapshot per job phase and frame. A rejected add clears it
        -- so the retry still force-fetches.
        local phase = tostring(Brew._job and Brew._job.phase or "")
        local frame = tonumber(StockPiler.FrameCounter) or 0
        local snapKey = phase .. ":" .. tostring(frame)
        local bags
        local usedCache = type(Brew._bagSnap) == "table" and Brew._bagSnapKey == snapKey
        if usedCache then
            bags = Brew._bagSnap
        elseif BA.FetchLight then
            -- Light read first so a load step does not mark both bags dirty.
            bags = BA.FetchLight()
        end
        local craftBagType = "craft"
        local function scanBags(list)
            if type(list) ~= "table" then
                return
            end
            for i = 1, #list do
                local bag = list[i]
                if bag and tostring(bag.bagType or "") == craftBagType then
                    BA.IterateSlots(bag, function(_bt, slotNum, item)
                        consider(slotNum, item, craftType, true)
                    end)
                end
            end
            for i = 1, #list do
                local bag = list[i]
                if bag and tostring(bag.bagType or "") ~= craftBagType then
                    BA.IterateSlots(bag, function(_bt, slotNum, item)
                        consider(slotNum, item, invType, false)
                    end)
                end
            end
        end
        scanBags(bags)
        if usedCache ~= true and bestSlot <= 0 and BA.FetchForce then
            bags = BA.FetchForce()
            scanBags(bags)
        end
        if usedCache ~= true and type(bags) == "table" then
            Brew._bagSnap = bags
            Brew._bagSnapKey = snapKey
        end
    end

    -- Fallback: Inventory.ForEachItem (no bag slot numbers - try FindSeedSlot on matched uid).
    if bestSlot <= 0 and StockPiler.Inventory and StockPiler.Inventory.ForEachItem then
        StockPiler.Inventory.ForEachItem(function(item)
            if type(item) ~= "table" then
                return
            end
            if MS and MS.IsSeedOrSpore and MS.IsSeedOrSpore(item) == true then
                return
            end
            local match = false
            if type(wantSpec) == "table" and MS then
                if MS.ProductMatches then
                    match = MS.ProductMatches(item, wantSpec) == true
                end
                if not match and MS.Matches then
                    match = MS.Matches(item, wantSpec) == true
                end
            end
            if match then
                local uid = tonumber(item.uniqueID) or 0
                if uid > 0 and BA and BA.FindSeedSlot then
                    local s, it, bt = BA.FindSeedSlot(uid)
                    if s and s > 0 then
                        consider(s, it or item, bt or craftType, bt == craftType)
                    end
                end
            elseif type(wantSpec) == "table" and MS and StockPiler.Items and StockPiler.Items.ToSpec then
                local iuid = tonumber(item.uniqueID) or 0
                if iuid > 0 then
                    local learned = StockPiler.Items.ToSpec(iuid)
                    local learnedMatch = false
                    if type(learned) == "table" then
                        if MS.ProductMatches then
                            learnedMatch = MS.ProductMatches(learned, wantSpec) == true
                        end
                        if not learnedMatch and MS.Matches then
                            learnedMatch = MS.Matches(learned, wantSpec) == true
                        end
                    end
                    if learnedMatch and BA and BA.FindSeedSlot then
                        local s, it, bt = BA.FindSeedSlot(iuid)
                        if s and s > 0 then
                            consider(s, it or item, bt or craftType, bt == craftType)
                        end
                    end
                end
            end
        end)
    end

    if bestSlot > 0 then
        return bestSlot, bestItem, bestType, bestUid
    end
    if fallbackSlot > 0 then
        return fallbackSlot, fallbackItem, fallbackType, fallbackUid
    end
    return bestSlot, bestItem, bestType, bestUid
end

Brew.FindCraftingBagItemBySpec = FindCraftingBagItemBySpec

function Brew.InvalidateBagSnapshot()
    Brew._bagSnap = nil
    Brew._bagSnapKey = nil
end

--- Auto holds that pause Ready brew (plant/refine/harvest). Seed buffer is per-watch
--- (Ready already means that watch's cushion is met); unrelated shorts must not block.
local function AutoBrewBlocked()
    local Grow = StockPiler.Grow
    if Grow and Grow.HasPendingPlant and Grow.HasPendingPlant() == true then
        return true, "pending-plant"
    end
    local RP = StockPiler.RefinePipeline
    if RP and RP.HasOutstanding and RP.HasOutstanding() == true then
        return true, "refine"
    end
    if Grow and Grow.IsHarvestOpActive and Grow.IsHarvestOpActive() == true then
        return true, "harvest"
    end
    return false, nil
end

--- Same gate as manual premature load: green Craftable, shared mats allowed.
local RowCraftableGreen = RowCanPrematureLoad
function Brew.RowCraftableGreen(row)
    return RowCanPrematureLoad(row)
end

local function NonemptyKey(v)
    local s = tostring(v or "")
    if s == "" then
        return nil
    end
    return s
end

local function RowMatchesSession(row, session)
    if type(row) ~= "table" or type(session) ~= "table" then
        return false
    end
    local rowKeys = {
        NonemptyKey(row.potionRecipeKey),
        NonemptyKey(row.id),
        NonemptyKey(row.potionKey),
    }
    local sessKeys = {
        NonemptyKey(session.potionRecipeKey),
        NonemptyKey(session.potionKey),
        NonemptyKey(session.rowId),
    }
    for i = 1, #rowKeys do
        local rk = rowKeys[i]
        if rk ~= nil then
            for j = 1, #sessKeys do
                if sessKeys[j] ~= nil and rk == sessKeys[j] then
                    return true
                end
            end
        end
    end
    return false
end

local function TBrew(key, tokens)
    if StockPiler.T then
        return StockPiler.T(key, tokens)
    end
    return towstring(tostring(key or ""))
end

local function ChatBrewBlocked(why)
    why = tostring(why or "")
    local CC = StockPiler.CraftChatAdapter
    if not (CC and CC.Print) then
        return
    end
    local msg
    if why == "buffer" then
        msg = TBrew("brew.blocked_buffer")
    elseif why == "shared" then
        msg = TBrew("brew.blocked_shared")
    elseif why == "nothing" then
        msg = TBrew("brew.nothing_craftable")
    elseif why == "not_ready" then
        msg = TBrew("brew.not_ready")
    elseif why ~= "" then
        msg = TBrew("brew.blocked_engine", { why = why })
    else
        return
    end
    CC.Print(msg, "action")
end

function Brew.AutoBrewBlockedReason()
    local blocked, why = AutoBrewBlocked()
    if blocked then
        return tostring(why or "blocked")
    end
    return nil
end

local function RequestFooterRefresh(payload)
    local Bus = StockPiler.EventBus
    if Bus and Bus.FireFooterDirty then
        Bus.FireFooterDirty(type(payload) == "table" and payload or {})
    end
end

--- Force footer + macro tint even when CanBrewNow is unchanged (mid-craft greying).
--- Publishes FOOTER_DIRTY / WATCH_UI_DIRTY / BREW_SESSION_CHANGED so View listeners
--- react; keeps a same-frame paint fallback for chrome during load storms.
--- opts.rows == false: Footer/Macro only (no Watch list paint).
local function ForceBrewUiRefresh(opts)
    opts = type(opts) == "table" and opts or {}
    Brew.InvalidateCanBrewCache()
    local frame = tonumber(StockPiler.FrameCounter) or 0
    Brew._brewUiForcedFrame = frame
    local Bus = StockPiler.EventBus
    RequestFooterRefresh({ immediate = true, syncMacro = true })
    local wantRows = opts.rows ~= false
    -- Load-job slot ticks: Footer/Macro only. Paint rows when _job clears (loaded).
    if wantRows and type(Brew._job) == "table" then
        wantRows = false
    end
    -- Greying after Perform: Footer/Macro only; full rows after brew completes.
    if wantRows and Brew._awaitingBrewComplete == true and opts.rows ~= true then
        wantRows = false
    end
    if wantRows then
        Brew.ArmWatchUiHold()
    end
    if Bus and Bus.FireBrewSessionChanged then
        Bus.FireBrewSessionChanged({
            phase = tostring(GetSession().phase or "idle"),
            loadSource = Brew._loadSource,
            rows = wantRows,
            recount = opts.recount == true,
            reason = tostring(opts.reason or "force-ui"),
        })
    end
    -- Same-frame fallback chrome (Ui listeners may coalesce under plant quiet).
    if StockPilerTabWatch and StockPilerTabWatch.InvalidateBrewChrome then
        StockPilerTabWatch.InvalidateBrewChrome()
    end
    if wantRows
        and DoesWindowExist("StockPilerWindow")
        and WindowGetShowing("StockPilerWindow") == true
        and StockPilerTabWatch
        and StockPilerTabWatch.UpdateRows
        and Brew._brewRowsPaintFrame ~= frame
    then
        Brew._brewRowsPaintFrame = frame
        StockPilerTabWatch.UpdateRows({ keepVisible = true })
    end
    if StockPilerWindow and StockPilerWindow.SyncActionReadiness then
        StockPilerWindow.SyncActionReadiness({ immediate = true })
    elseif StockPiler.Macro and StockPiler.Macro.RefreshMacroButtonAppearance then
        local canHarvest = StockPiler.Grow and StockPiler.Grow.CanHarvestNow
            and StockPiler.Grow.CanHarvestNow() == true
        if StockPiler.Macro.CancelPendingEnabledSync then
            StockPiler.Macro.CancelPendingEnabledSync()
        end
        StockPiler.Macro.RefreshMacroButtonAppearance({
            canHarvest = canHarvest,
            canBrew = Brew.CanBrewNow() == true,
        })
    end
    if StockPiler.Macro and StockPiler.Macro.ArmEnableReassert then
        StockPiler.Macro.ArmEnableReassert()
    end
end

--- Hold Watch ListBox rebinds across inter-craft idle (after-brew clears session
--- before the next BeginForRow). Full Refresh -> ListBoxSetDisplayOrder blanks rows.
Brew.WATCH_UI_HOLD_SEC = 6.0

function Brew.ArmWatchUiHold(sec)
    sec = tonumber(sec) or tonumber(Brew.WATCH_UI_HOLD_SEC) or 3.0
    if sec < 0 then
        sec = 0
    end
    local untilT = NowSec() + sec
    local cur = tonumber(Brew._watchUiHoldUntil) or 0
    if untilT > cur then
        Brew._watchUiHoldUntil = untilT
    end
end

function Brew.IsWatchUiHold()
    local Orch = StockPiler.Orchestrator
    if Orch and Orch.IsBrewSessionActive and Orch.IsBrewSessionActive() == true then
        return true
    end
    -- Timed hold across inter-craft idle only. Do not key off CanBrewNow(): that
    -- stayed true for the whole AutoBrew run and permanently skipped ListBox
    -- rebinds after PopulatorIndices cleared (Target chips died).
    local untilT = tonumber(Brew._watchUiHoldUntil) or 0
    if untilT <= 0 then
        return false
    end
    if NowSec() < untilT then
        return true
    end
    Brew._watchUiHoldUntil = 0
    -- Hold just expired: one deferred ListBox rebind if keepVisible left indices empty.
    if StockPilerTabWatch then
        StockPilerTabWatch._pendingListRebind = true
    end
    return false
end

local function ClearSession(opts)
    opts = type(opts) == "table" and opts or {}
    Brew._job = nil
    Brew._loadSource = nil
    Brew._performAfterManualLoad = false
    Brew._performAfterLoadIgnoreSource = false
    Brew._performAfterLoadUntil = 0
    Brew._awaitingBrewComplete = false
    Brew._postBrewClearArmed = false
    Brew._brewHaveBefore = nil
    Brew._loadSettleUntil = 0
    local session = GetSession()
    session.potionKey = nil
    session.rowId = nil
    session.name = nil
    session.potionDeficit = nil
    session.craftable = nil
    session.potionHave = nil
    session.potionMin = nil
    session.recipeYield = nil
    session.recipe = nil
    session.recipeSpecKey = nil
    session.potionRecipeKey = nil
    session.uniqueID = nil
    session.skillUp = nil
    Brew._skillUpRow = nil
    -- Set phase only via SetSessionPhase so loading->idle is logged.
    SetSessionPhase("idle", opts.reason or "clear")
    if opts.adoptBlock == true then
        Brew._adoptBlockUntil = NowSec() + (tonumber(Brew.ADOPT_BLOCK_SEC) or 1.5)
    end
    Brew.InvalidateCanBrewCache()
end

local function OpenFailBlocked()
    if Brew._openFailLatched == true then
        -- Clear if apo craft session became active (player opened Apo, etc.).
        local a = AA()
        if a and a.IsCraftingSessionActive and a.IsCraftingSessionActive() == true then
            Brew._openFailLatched = false
            return false
        end
        return true
    end
    return false
end

local function NoteOpenFail(skillType)
    -- Latch: do not time-retry (that re-failed every ~21s and held CanBrewNow false).
    Brew._openFailLatched = true
    LogBrew(string.format(
        "open-fail latched skill=%s (manual Load or /reload to retry)",
        tostring(skillType)
    ))
end

function Brew.ClearOpenFailBackoff()
    Brew._openFailLatched = false
end

local function InLoadSettle()
    local untilT = tonumber(Brew._loadSettleUntil) or 0
    if untilT <= 0 then
        return false
    end
    local now = NowSec()
    if now <= 0 then
        return false
    end
    if now >= untilT then
        Brew._loadSettleUntil = 0
        return false
    end
    return true
end

--- Auto-unload on engine/board reasons only after post-load settle (and not mid-load).
--- board-incomplete must wait settle too - GetSlottedItem lags after AddCraftingItem.
local function ShouldAutoUnloadForEngine(why)
    why = tostring(why or "")
    -- bad-craft-state often fires before missing-container-or-main when only a
    -- vial is slotted (partial auto-load). Without unloading, phase stays loaded
    -- forever and AutoBrew never retries the rest of the recipe.
    local gated = why == "board-incomplete"
        or why == "missing-container-or-main"
        or why == "empty-board"
        or string.find(why, "bad%-craft%-state", 1, false) == 1
        or string.find(why, "engine%-", 1, false) == 1
    if not gated then
        return false
    end
    if InLoadSettle() then
        return false
    end
    return true
end

----------------------------------------------------------------
-- Session / busy
----------------------------------------------------------------

function Brew.GetSession()
    return GetSession()
end

function Brew.SetApoSessionFlags(session, flags)
    if type(session) ~= "table" or type(flags) ~= "table" then
        return
    end
    if flags.idleForceClosed ~= nil then
        session._idleForceClosed = flags.idleForceClosed == true
    end
    if flags.owned ~= nil then
        session._brewOwnedSession = flags.owned == true
    end
    if flags.stealth ~= nil then
        session._brewApoStealth = flags.stealth == true
    end
    if flags.openedApo ~= nil then
        session._brewOpenedApo = flags.openedApo == true
    end
    if flags.openedBackpack ~= nil then
        session._brewOpenedBackpack = flags.openedBackpack == true
    end
    if flags.placedOnBoard ~= nil then
        session._brewPlacedOnBoard = flags.placedOnBoard == true
    end
end

function Brew.OnCraftChat(payload)
    if type(payload) == "table" and payload.kind == "bad_seed" then
        Brew.OnCraftServerReject()
    end
end

function Brew.ArmBrewOpLock(seconds)
    seconds = tonumber(seconds) or Brew.BREW_OP_LOCK_SEC
    if seconds < 0.4 then
        seconds = 0.4
    end
    local untilT = NowSec() + seconds
    local cur = tonumber(Brew._brewOpLockUntil) or 0
    if untilT > cur then
        Brew._brewOpLockUntil = untilT
    end
end

function Brew.IsBusy()
    if type(Brew._job) == "table" then
        return true
    end
    local a = AA()
    if a and a.IsPerforming and a.IsPerforming() == true then
        return true
    end
    local lockUntil = tonumber(Brew._brewOpLockUntil) or 0
    if lockUntil > 0 then
        if NowSec() < lockUntil then
            return true
        end
        Brew._brewOpLockUntil = 0
    end
    return false
end

function Brew.BlocksHarvest()
    if type(Brew._job) == "table" then
        return true
    end
    local a = AA()
    if a and a.IsPerforming and a.IsPerforming() == true then
        return true
    end
    -- Only block while the board is mid-load. A sitting "loaded" recipe must not
    -- grey Harvest for minutes until a plan rebuild clears the session (watchplan).
    local phase = tostring(GetSession().phase or "idle")
    return phase == "loading"
end

----------------------------------------------------------------
-- Ready pick / CanBrewNow
----------------------------------------------------------------

function Brew.PickReadyWatch()
    local Caps = StockPiler.TradeSkillCaps
    if Caps and Caps.CanBrewPotions and Caps.CanBrewPotions() ~= true then
        return nil
    end
    local plan = CurrentPlan()
    local rows = plan and plan.rows
    if type(rows) == "table" then
        local best = nil
        for i = 1, #rows do
            local row = rows[i]
            if RowIsReadyToCraft(row) then
                if best == nil or CompareReadyWatch(row, best) then
                    best = row
                end
            end
        end
        if best ~= nil then
            return best
        end
    end
    -- Idle SkillUp Apo: invent a stable board from surplus mats.
    local SkillUp = StockPiler.SkillUp
    if SkillUp and SkillUp.ShouldApoBrew and SkillUp.ShouldApoBrew() == true
        and SkillUp.BuildApoBrewRow
    then
        local skillRow = SkillUp.BuildApoBrewRow()
        if RowIsReadyToCraft(skillRow) then
            return skillRow
        end
    end
    return nil
end

function Brew.HasReadyToCraft()
    return type(Brew.PickReadyWatch()) == "table"
end

function Brew.InvalidateCanBrewCache()
    Brew._canBrewCache = nil
    Brew._canBrewCacheKey = nil
end

--- True when an auto-loaded Ready (or SkillUp) board can Perform. Used by
--- AutoBrew; user-facing CanBrewNow stays false while AutoBrew is on.
local function BoardReadyToAutoPerform()
    local Caps = StockPiler.TradeSkillCaps
    if Caps and Caps.CanBrewPotions and Caps.CanBrewPotions() ~= true then
        return false
    end
    if Brew.IsBusy() then
        return false
    end
    if OpenFailBlocked() then
        return false
    end
    if Brew._loadSource ~= "auto" then
        return false
    end
    local session = GetSession()
    local phase = tostring(session.phase or "idle")
    if phase ~= "loaded" then
        return false
    end
    if session.skillUp == true then
        return Brew.ValidateApothecaryPerform() == true
            and (tonumber(session.craftable) or 0) > 0
    end
    if not RowNeedsMorePotions(session) then
        return false
    end
    if (tonumber(session.potionDeficit) or 0) <= 0 then
        return false
    end
    local row = FindSessionRow()
    if not RowIsReadyToCraft(row) then
        return false
    end
    return Brew.ValidateApothecaryPerform() == true
end

function Brew.CanBrewNow()
    -- AutoBrew owns perform: keep footer Brew and Craft-macro brew path dark.
    local Watch = StockPiler.Watch
    if Watch and Watch.IsAutoBrewEnabled and Watch.IsAutoBrewEnabled() == true then
        return false
    end
    local Caps = StockPiler.TradeSkillCaps
    if Caps and Caps.CanBrewPotions and Caps.CanBrewPotions() ~= true then
        return false
    end
    if Brew.IsBusy() then
        return false
    end
    -- Apo craft session failed to open recently (scenario / skill=0): keep macros dark.
    if OpenFailBlocked() then
        return false
    end
    -- Manual row loads: footer not lit for perform.
    if Brew._loadSource == "manual" then
        return false
    end

    local session = GetSession()
    local phase = tostring(session.phase or "idle")
    -- Idle Ready only starts a load (TryBrewClick returns "blocked"). Never light
    -- Craft/Brew until the board is loaded and a click would actually Perform.
    if phase ~= "loaded" then
        return false
    end

    -- SkillUp Apo: keep footer lit while the board can still perform.
    if session.skillUp == true then
        return Brew.ValidateApothecaryPerform() == true
            and (tonumber(session.craftable) or 0) > 0
    end
    -- Target met while still loaded: do not fall through to another watch.
    if not RowNeedsMorePotions(session) then
        return false
    end
    if (tonumber(session.potionDeficit) or 0) <= 0 then
        return false
    end
    local row = FindSessionRow()
    if not RowIsReadyToCraft(row) then
        return false
    end
    -- Match TryBrewClick "go": Ready plan row is not enough if the board cannot Perform.
    return Brew.ValidateApothecaryPerform() == true
end

--- Chat + sound when Brew becomes usable (same boolean as the footer and macros).
--- Busy mid-craft keeps the latch so each perform does not chime again. A
--- different loaded recipe still chimes when the button lights for it.
function Brew.AnnounceBrewEnabled(canBrew)
    local Sch = StockPiler.Scheduler
    if Sch and Sch.IsSessionSettling and Sch.IsSessionSettling() == true then
        return
    end
    if Brew.IsBusy() == true then
        return
    end
    if canBrew ~= true then
        Brew._brewEnableAnnounced = nil
        return
    end
    local session = GetSession()
    local key = tostring(session.potionRecipeKey or session.potionKey or session.rowId or "")
    if key == "" then
        key = "?"
    end
    if Brew._brewEnableAnnounced == key then
        return
    end
    Brew._brewEnableAnnounced = key
    local name = session.name
    if name == nil or name == L"" or name == "" then
        local row = Brew.PickReadyWatch and Brew.PickReadyWatch()
        name = type(row) == "table" and row.name or nil
    end
    if name == nil or name == L"" or name == "" then
        if StockPiler.T then
            name = StockPiler.T("brew.potion_fallback")
        else
            name = L"potion"
        end
    elseif type(name) ~= "wstring" then
        name = towstring(tostring(name))
    end
    local msg = L"<icon10985> Ready - " .. name .. L"."
    if StockPiler.T then
        msg = StockPiler.T("brew.ready", { name = name })
    end
    LogBrew("brew-ready announce key=" .. key)
    local soundId = GameData and GameData.Sound and GameData.Sound.HELP_TIPS_HIGHTLIGHT_WINDOW
    if StockPiler.Debug and StockPiler.Debug.AnnounceReady then
        StockPiler.Debug.AnnounceReady(msg, soundId)
    elseif StockPiler.Debug and StockPiler.Debug.Notify then
        StockPiler.Debug.Notify(msg)
        if soundId and Sound and Sound.Play then
            Sound.Play(soundId)
        end
    end
end

--- Footer refresh when a plan row becomes ready to craft. The ready chime
--- follows CanBrewNow (AnnounceBrewEnabled), not the plan row.
function Brew.MaybeNotifyBrewReady()
    local plan = CurrentPlan()
    local rows = plan and plan.rows
    local nowReady = {}
    if type(rows) == "table" then
        for i = 1, #rows do
            local row = rows[i]
            if RowIsReadyToCraft(row) then
                local key = tostring(row.potionKey or row.potionRecipeKey or row.id or "")
                if key ~= "" then
                    nowReady[key] = row
                end
            end
        end
    end

    local any = next(nowReady) ~= nil
    local wasLatched = Brew._brewReadyLatched == true
    Brew._brewReadyLatched = any

    -- First observe after load: seed latches without chat/sound.
    if Brew._readyNotifyKeys == nil then
        local seeded = {}
        for key, _ in pairs(nowReady) do
            seeded[key] = true
        end
        Brew._readyNotifyKeys = seeded
        if wasLatched ~= any and StockPilerWindow and StockPilerWindow.RequestFooterRefresh then
            StockPilerWindow.RequestFooterRefresh()
        end
        return
    end

    local prev = Brew._readyNotifyKeys
    local newly = {}
    for key, row in pairs(nowReady) do
        if prev[key] ~= true then
            newly[#newly + 1] = row
        end
    end

    local nextKeys = {}
    for key, _ in pairs(nowReady) do
        nextKeys[key] = true
    end
    Brew._readyNotifyKeys = nextKeys

    if wasLatched ~= any and StockPilerWindow and StockPilerWindow.RequestFooterRefresh then
        StockPilerWindow.RequestFooterRefresh()
    end

    if #newly == 0 then
        return
    end
    if StockPilerWindow and StockPilerWindow.RequestFooterRefresh then
        StockPilerWindow.RequestFooterRefresh()
    end
end

----------------------------------------------------------------
-- Load job FSM
----------------------------------------------------------------

local function BeginLoadJob(row, source)
    if type(row) ~= "table" then
        return false
    end
    -- Auto/macro after open-timeout: latched until manual Load / zone / apo up.
    if source ~= "manual" and OpenFailBlocked() then
        return false
    end
    if source == "manual" then
        Brew.ClearOpenFailBackoff()
    end
    -- Auto: refuse when craft bag has no free slot for inventory pulls.
    -- (Potion output goes to the main bag - craft free is only for AddCraftingItem.)
    if source ~= "manual" then
        local backoffUntil = tonumber(Brew._autoLoadBackoffUntil) or 0
        if backoffUntil > 0 and NowSec() < backoffUntil then
            return false
        end
        local BA = StockPiler.BagAdapter
        local free = BA and BA.CraftBagFreeSlots and BA.CraftBagFreeSlots()
        if type(free) == "number" and free < 1 then
            LogBrew("load skip craft-bag-space free=" .. tostring(free))
            return false
        end
    end
    -- Never stomp an in-flight or already-loaded board (Validate-fail used to
    -- fall through TryBrewClick into a second BeginLoadJob).
    -- Manual Load on a *different* watch: unload then load that recipe.
    local session = GetSession()
    local curPhase = tostring(session.phase or "idle")
    local sameRow = RowMatchesSession(row, session)
    if type(Brew._job) == "table" then
        if source ~= "manual" or sameRow then
            LogBrew("load skip job-active")
            return false
        end
        LogBrew("load abort job for switch")
        Brew._job = nil
    end
    if curPhase == "loading" or curPhase == "loaded" then
        if source ~= "manual" or sameRow then
            LogBrew("load skip already-" .. curPhase)
            return false
        end
        LogBrew("load switch from " .. tostring(session.potionRecipeKey or session.rowId or "?"))
        Brew.ClearLoadedSession({ reason = "switch-row" })
        session = GetSession()
    end
    local recipe = row.recipe
    -- SkillUp: never trust a stale plan recipe after Apo max / toggle off.
    -- Always rebuild (or abort) so post-200 bag flush cannot re-load the board.
    if row.skillUp == true then
        local SkillUp = StockPiler.SkillUp
        if not SkillUp or SkillUp.ShouldApoBrew == nil or SkillUp.ShouldApoBrew() ~= true then
            LogBrew("load skip skillup-disabled")
            return false
        end
        if SkillUp.BuildApoBrewRow then
            local skillRow = SkillUp.BuildApoBrewRow({ quiet = true })
            if type(skillRow) == "table" and type(skillRow.recipe) == "table" then
                recipe = skillRow.recipe
                row.recipe = recipe
                row.craftable = skillRow.craftable
                row.mainUid = skillRow.mainUid
                row.recipeYield = skillRow.recipeYield
            else
                LogBrew("load skip skillup-no-board")
                return false
            end
        end
    end
    if type(recipe) ~= "table" then
        local RS = StockPiler.RecipeSpec
        local key = row.potionRecipeKey or row.potionKey or row.id
        if RS and RS.RecipeSpecForPotion and key ~= nil then
            recipe = RS.RecipeSpecForPotion(key)
        elseif RS and RS.GetRecipeForWatch then
            recipe = RS.GetRecipeForWatch(row)
        elseif RS and RS.GetRecipe and row.recipeSpecKey then
            recipe = RS.GetRecipe(row.recipeSpecKey)
        end
    end
    if type(recipe) ~= "table" then
        LogBrew("load skip no-recipe")
        return false
    end
    if StockPiler.RecipeSpec and StockPiler.RecipeSpec.HydrateRecipeSlots then
        StockPiler.RecipeSpec.HydrateRecipeSlots(recipe)
    end
    row.recipe = recipe
    Brew._loadSource = source or "auto"
    local steps, stepsOk = BuildLoadSteps(recipe)
    if stepsOk ~= true or type(steps) ~= "table" or #steps <= 0 then
        LogBrew("load skip incomplete-steps")
        return false
    end
    local recipeSpecKey = tostring(recipe.recipeSpecKey or recipe.key or "")
    if recipeSpecKey == "" and StockPiler.RecipeSpec and StockPiler.RecipeSpec.SlotsFingerprint then
        recipeSpecKey = tostring(StockPiler.RecipeSpec.SlotsFingerprint(recipe.slots) or "")
    end
    local stab = 0
    local RS = StockPiler.RecipeSpec
    if RS and RS.SpecStabilityTotal then
        stab = tonumber(RS.SpecStabilityTotal(recipe.slots)) or 0
    end
    -- Bonus-sum is diagnostic only; perform gate uses engine SuccessChance.
    LogBrew(string.format(
        "load steps=%d bonusStabilitySum=%s recipeKey=%s",
        #steps, tostring(stab), recipeSpecKey
    ))
    for i = 1, #steps do
        local s = steps[i]
        LogBrew(string.format(
            "  step[%d] role=%s uid=%s craftSlot=%s",
            i, tostring(s.role), tostring(s.uid or s.uniqueID), tostring(s.craftingSlot)
        ))
    end
    Brew._job = {
        phase = "reset",
        row = row,
        recipe = recipe,
        recipeSpecKey = recipeSpecKey,
        slots = steps,
        index = 1,
        reserved = {}, -- bagType:bagSlot -> qty claimed by prior steps
        at = NowSec(),
    }
    local session = GetSession()
    session.potionKey = row.potionKey
    session.rowId = row.id
    session.name = row.name
    session.uniqueID = PotionOutputUid(row)
    session.potionDeficit = row.potionDeficit
    session.craftable = row.craftable
    session.potionHave = row.potionHave
    session.potionMin = row.potionMin or row.target
    session.recipeYield = row.recipeYield
        or (row.recipe and row.recipe.recipeYield)
        or 5
    session.recipe = recipe
    session.recipeSpecKey = recipeSpecKey
    session.potionRecipeKey = row.potionRecipeKey or row.id
    session.skillUp = row.skillUp == true
    if session.skillUp == true then
        Brew._skillUpRow = row
        -- Unknown output uid: do not abort on LivePotionHave; keep brewing surplus.
        session.uniqueID = 0
        session.potionHave = 0
        session.potionMin = tonumber(row.potionMin) or 9999
        session.potionDeficit = tonumber(row.potionDeficit) or session.potionMin
    else
        Brew._skillUpRow = nil
        SyncSessionStockFromBags(session)
        local needsMore = RowNeedsMorePotions(session)
        if needsMore ~= true then
            if needsMore == nil then
                LogBrew("load wait bag count unknown")
                ClearSession({ reason = "have-unknown" })
                return false
            end
            -- Auto must not overstock once the watch target is met.
            -- Manual Load/Brew: allow one more craft when Craftable is green (buffer-safe).
            if source == "manual" and RowCanPrematureLoad(row) then
                LogBrew("load allow manual over-target have="
                    .. tostring(session.potionHave) .. "/" .. tostring(session.potionMin)
                    .. " craftable=" .. tostring(session.craftable))
            else
                LogBrew("load abort target already met have="
                    .. tostring(session.potionHave) .. "/" .. tostring(session.potionMin))
                ClearSession({ reason = "target-already-met" })
                return false
            end
        end
    end
    SetSessionPhase("loading", "begin-load")
    Brew.InvalidateCanBrewCache()
    -- Grey macros while load runs (IsBusy -> CanBrewNow false). First click only
    -- starts the load; without this the button stayed lit and felt dead.
    ForceBrewUiRefresh({ rows = false })
    return true
end

-- Headless OpenWindow parks Apo; wait for SkillType / session before clear/load.
local OPEN_WAIT_TICKS = 180
local CLEAR_WAIT_TICKS = 90

--- Every saved recipe step must still be present on the apo board.
local function BoardCoversRecipe(recipe)
    if type(recipe) ~= "table" then
        return true
    end
    local a = AA()
    if not (a and a.GetSlottedItem) then
        return false
    end
    local steps = BuildLoadSteps(recipe)
    for i = 1, #steps do
        local step = steps[i]
        if type(step) == "table" then
            local craftSlot = tonumber(step.craftingSlot)
            if craftSlot == nil or a.GetSlottedItem(craftSlot) == nil then
                return false
            end
        end
    end
    return true
end

local function AbortIncompleteLoad(reason)
    reason = tostring(reason or "load-incomplete")
    LogBrew("load abort " .. reason)
    Brew._job = nil
    local a = AA()
    local session = GetSession()
    -- CloseWindow ends the stealth apo session; ClearSlots alone leaves SkillType
    -- stuck and AutoBrew clear-phase retries looping on not-addcontainer.
    if a and a.CloseWindow then
        a.CloseWindow(session)
    elseif a and a.ClearSlots then
        a.ClearSlots()
    end
    ClearSession({ reason = reason })
    -- Stop AutoBrew clear->flask->fail->clear thrash when a step cannot land.
    Brew._autoLoadBackoffUntil = NowSec() + (tonumber(Brew.LOAD_ABORT_BACKOFF_SEC) or 4)
    -- Session is idle now. Ask Watch to recount craftable (craft-chat reject
    -- spends a mat). A FrameWork job queued while the session was active never
    -- pumped, and the snap can already be marked done.
    ForceBrewUiRefresh({ recount = true, reason = reason })
end

function Brew.IsRejectedCraftUid(uid)
    uid = tonumber(uid) or 0
    local rejected = Brew._rejectedCraftUids
    return uid > 0 and type(rejected) == "table" and rejected[uid] == true
end

--- Crafting chat: "Bad seed data... it has been lost" / "add main ingredient
--- before other ingredients". The server destroyed the item just sent.
--- Blacklist that main uid (stat twin the server will not slot) and stop.
function Brew.OnCraftServerReject()
    local uid = tonumber(Brew._lastIssuedUid) or 0
    local role = tostring(Brew._lastIssuedRole or "")
    local job = Brew._job
    if type(job) == "table" and type(job.slots) == "table" then
        local slot = job.slots[tonumber(job.index) or 1]
        if type(slot) == "table" and slot.loadIssued == true then
            uid = tonumber(slot.matchedUid) or uid
            role = tostring(slot.role or role)
            -- Stabilizer added before the main stuck: the broken item is the main.
            if role ~= "main" then
                for i = 1, #job.slots do
                    local step = job.slots[i]
                    if type(step) == "table" and tostring(step.role or "") == "main" then
                        uid = tonumber(step.matchedUid) or uid
                        role = "main"
                        break
                    end
                end
            end
        end
    end
    local newly = false
    if role == "main" and uid > 0 then
        Brew._rejectedCraftUids = Brew._rejectedCraftUids or {}
        if Brew._rejectedCraftUids[uid] ~= true then
            Brew._rejectedCraftUids[uid] = true
            newly = true
            Brew.InvalidateBagSnapshot()
            LogBrew("craft chat rejected main uid=" .. tostring(uid))
        end
    end
    if newly then
        local Planner = StockPiler.Planner
        if Planner and Planner.InvalidateHaveCacheAfterQuiet then
            Planner.InvalidateHaveCacheAfterQuiet()
        elseif Planner and Planner.InvalidateHaveWarm then
            Planner.InvalidateHaveWarm()
        end
    end
    if type(Brew._job) == "table" then
        AbortIncompleteLoad("craft-chat-bad-seed")
    end
end

local function AdvanceLoadJob()
    local job = Brew._job
    if type(job) ~= "table" then
        return false
    end
    local a = AA()
    if not a then
        ClearSession({ reason = "no-apo" })
        return false
    end
    local phase = tostring(job.phase or "reset")

    if phase == "reset" then
        job.phase = "open"
        job.waitTicks = 0
        return true
    end
    if phase == "open" then
        -- Gate on IsCraftingSessionActive, then enforce stealth park.
        job.waitTicks = (tonumber(job.waitTicks) or 0) + 1
        local sessionReady = a.IsCraftingSessionActive and a.IsCraftingSessionActive() == true
        if sessionReady then
            -- Session came up - clear any prior open-fail latch.
            Brew.ClearOpenFailBackoff()
            -- Keep apo UI parked off-screen while SP owns the session.
            local session = GetSession()
            if a.EnforceStealthHide then
                a.EnforceStealthHide(session)
            elseif a.HideWindowOnly and session and session._brewOwnedSession == true
                and a.IsWindowOpen and a.IsWindowOpen() then
                a.HideWindowOnly()
                session._brewApoStealth = true
            end
            if a.SetSoftLocks then
                a.SetSoftLocks(false)
            end
            -- Leave the show-suppress TTL in place. Clearing it here let the
            -- first SendInitCrafting echo after login pop the window on screen.
            job.phase = "clear"
            job.waitTicks = 0
            return true
        end
        -- Throttle OpenWindow: every-tick SendInitCrafting buzzes audio
        -- when CraftingStatus.SkillType stays 0 (scenario / craft blocked).
        local retryEvery = tonumber(Brew.OPEN_RETRY_TICKS) or 20
        if retryEvery < 5 then
            retryEvery = 5
        end
        if job.waitTicks == 1 or (job.waitTicks % retryEvery) == 0 then
            if a.OpenWindow then
                a.OpenWindow(GetSession())
            end
        end
        if job.waitTicks > OPEN_WAIT_TICKS then
            local skillType = a.CraftingSkillType and a.CraftingSkillType()
            LogBrew("load abort open-timeout skill=" .. tostring(skillType))
            NoteOpenFail(skillType)
            if a.CloseWindow then
                a.CloseWindow(GetSession())
            end
            ClearSession({ reason = "open-timeout" })
            ForceBrewUiRefresh()
            return false
        end
        return true
    end
    if phase == "clear" then
        job.waitTicks = (tonumber(job.waitTicks) or 0) + 1
        if a.ServerHasItems and a.ServerHasItems() == true then
            if a.ClearSlots then
                a.ClearSlots()
            end
            if job.waitTicks > CLEAR_WAIT_TICKS then
                LogBrew("load abort clear-timeout")
                if a.CloseWindow then
                    a.CloseWindow(GetSession())
                end
                ClearSession({ reason = "clear-timeout" })
                Brew._autoLoadBackoffUntil = NowSec() + (tonumber(Brew.LOAD_ABORT_BACKOFF_SEC) or 4)
                return false
            end
            return true
        end
        -- Only start load from ADDCONTAINER. Loading into leftover VALID_RECIPE
        -- rejects later AddCraftingItem after the flask (SP1 SessionReadyToFill).
        -- Do not spam ClearSlots here when the board is already empty - that
        -- fights a concurrent AutoBrew restart and flickers the flask.
        local cs = GameData and GameData.CraftingStates
        local st = a.CraftingState and a.CraftingState()
        if cs and st ~= nil and st ~= cs.ADDCONTAINER then
            if job.waitTicks > CLEAR_WAIT_TICKS then
                LogBrew("load abort not-addcontainer state=" .. tostring(st))
                if a.CloseWindow then
                    a.CloseWindow(GetSession())
                end
                ClearSession({ reason = "not-addcontainer" })
                Brew._autoLoadBackoffUntil = NowSec() + (tonumber(Brew.LOAD_ABORT_BACKOFF_SEC) or 4)
                return false
            end
            return true
        end
        job.phase = "load"
        job.index = 1
        job.waitTicks = 0
        job.reserved = {}
        if a.SetSoftLocks then
            a.SetSoftLocks(false)
        end
        return true
    end
    if phase == "load" then
        local STEP_WAIT = tonumber(Brew.LOAD_STEP_WAIT_TICKS) or 60
        local slots = job.slots
        local idx = tonumber(job.index) or 1
        if type(slots) ~= "table" or idx > #slots then
            job.phase = "verify"
            job.waitTicks = 0
            return true
        end
        -- First load tick: dry-run every step so a mid-recipe miss never partial-fills.
        if idx == 1 and job.preflightDone ~= true then
            job.preflightDone = true
            if a.SetSoftLocks then
                a.SetSoftLocks(false)
            end
            local reserved = {}
            local needFromInv = 0
            local craftType = (EA_Window_Backpack and EA_Window_Backpack.TYPE_CRAFTING) or 4
            for i = 1, #slots do
                local pre = slots[i]
                if type(pre) == "table" then
                    local exemplarUid = tonumber(pre.uniqueID) or tonumber(pre.uid) or 0
                    local want = pre.spec
                    if type(want) ~= "table" and StockPiler.RecipeSpec
                        and StockPiler.RecipeSpec.ResolveSlotSpec
                    then
                        want = StockPiler.RecipeSpec.ResolveSlotSpec(pre)
                    end
                    local bagSlot, _, bagType = FindCraftingBagItemBySpec(want, exemplarUid, reserved)
                    if not (bagSlot > 0) then
                        LogBrew(string.format(
                            "load preflight-miss role=%s exemplar=%s - abort before AddItem",
                            tostring(pre.role), tostring(exemplarUid)
                        ))
                        AbortIncompleteLoad("preflight-miss-" .. tostring(pre.role or "?"))
                        return false
                    end
                    if (tonumber(bagType) or craftType) ~= craftType then
                        needFromInv = needFromInv + 1
                    end
                    local rkey = tostring(bagType or 0) .. ":" .. tostring(bagSlot)
                    reserved[rkey] = (tonumber(reserved[rkey]) or 0) + 1
                end
            end
            local BA = StockPiler.BagAdapter
            local free = BA and BA.CraftBagFreeSlots and BA.CraftBagFreeSlots()
            if type(free) == "number" and needFromInv > free then
                LogBrew(string.format(
                    "load preflight craft-bag-space need=%s free=%s - abort",
                    tostring(needFromInv), tostring(free)
                ))
                AbortIncompleteLoad("craft-bag-space")
                return false
            end
        end

        local slot = slots[idx]
        if type(slot) ~= "table" then
            job.index = idx + 1
            return true
        end

        local function StepCraftSlot(step)
            local craftSlot = tonumber(step.craftingSlot)
            if craftSlot == nil then
                craftSlot = tonumber(step.craftSlot) or tonumber(step.index)
            end
            if craftSlot == nil and step.role == "container" then
                craftSlot = 0
            end
            return craftSlot
        end

        local function UnreserveStep(step)
            if type(step) ~= "table" or type(job.reserved) ~= "table" then
                return
            end
            local bagSlot = tonumber(step.bagSlot) or 0
            local bagType = tonumber(step.bagType)
            if bagSlot <= 0 or bagType == nil then
                return
            end
            local rkey = tostring(bagType) .. ":" .. tostring(bagSlot)
            local used = tonumber(job.reserved[rkey]) or 0
            if used <= 1 then
                job.reserved[rkey] = nil
            else
                job.reserved[rkey] = used - 1
            end
            step.bagSlot = nil
            step.bagType = nil
        end

        -- Confirm prior issued add landed before advancing (SP1 StepSatisfied).
        -- Firing the next AddCraftingItem before the server accepts the previous
        -- one is silently rejected - board stuck with vial-only.
        local function StepLanded(step)
            if type(step) ~= "table" then
                return false
            end
            local craftSlot = StepCraftSlot(step)
            if craftSlot ~= nil and a.GetSlottedItem and a.GetSlottedItem(craftSlot) ~= nil then
                return true
            end
            -- Only trust crafting-state shortcuts after this job issued the add
            -- (SP1); leftover VALID_RECIPE must not skip a real slot fill.
            if step.loadIssued ~= true then
                return false
            end
            local cs = GameData and GameData.CraftingStates
            local st = a.CraftingState and a.CraftingState()
            if cs == nil or st == nil then
                return false
            end
            local role = tostring(step.role or "")
            if role == "container" and st >= (cs.ADDDETERMINENT or 1) then
                return true
            end
            if role == "main" and st >= (cs.ADDINGREDIENT or 2) then
                return true
            end
            return false
        end

        if slot.loadIssued == true then
            if StepLanded(slot) then
                -- Reserve bag qty only once the engine accepted the pull.
                if type(job.reserved) ~= "table" then
                    job.reserved = {}
                end
                local bagSlot = tonumber(slot.bagSlot) or 0
                local bagType = tonumber(slot.bagType)
                if bagSlot > 0 and bagType ~= nil and slot.reservedOk ~= true then
                    local rkey = tostring(bagType) .. ":" .. tostring(bagSlot)
                    job.reserved[rkey] = (tonumber(job.reserved[rkey]) or 0) + 1
                    slot.reservedOk = true
                end
                -- SP placed items on this board (player-open Apo may not be "owned").
                local sess = GetSession()
                if type(sess) == "table" then
                    sess._brewPlacedOnBoard = true
                end
                LogBrew(string.format(
                    "load confirmed role=%s craftSlot=%s",
                    tostring(slot.role), tostring(StepCraftSlot(slot))
                ))
                job.index = idx + 1
                job.waitTicks = 0
                slot.retryCount = 0
                return true
            end
            job.waitTicks = (tonumber(job.waitTicks) or 0) + 1
            if job.waitTicks > 0 and (job.waitTicks % 15) == 0 and job.waitTicks < STEP_WAIT then
                local retries = (tonumber(slot.retryCount) or 0) + 1
                slot.retryCount = retries
                if retries > 4 then
                    AbortIncompleteLoad("load-step-timeout-" .. tostring(slot.role or "?"))
                    return false
                end
                LogBrew(string.format(
                    "load retry role=%s retry=%s state=%s bagWas=%s:%s",
                    tostring(slot.role), tostring(retries),
                    tostring(a.CraftingState and a.CraftingState()),
                    tostring(slot.bagType), tostring(slot.bagSlot)
                ))
                -- Free the pending claim so craft-bag stacks stay eligible
                -- (reserving before land forced inventory retries that no-op).
                UnreserveStep(slot)
                slot.loadIssued = false
                slot.reservedOk = false
                if type(ApothecaryWindow) == "table" and type(ApothecaryWindow.clientSlotList) == "table" then
                    local cs = StepCraftSlot(slot)
                    if cs ~= nil then
                        ApothecaryWindow.clientSlotList[cs] = nil
                    end
                end
            end
            if job.waitTicks > STEP_WAIT then
                AbortIncompleteLoad("load-step-timeout-" .. tostring(slot.role or "?"))
                return false
            end
            return true
        end

        -- Soft locks down for the pull; do not ReleaseAllLocks (can disturb board).
        if a.SetSoftLocks then
            a.SetSoftLocks(false)
        end

        local role = tostring(slot.role or "")
        local exemplarUid = tonumber(slot.uniqueID) or tonumber(slot.uid) or 0
        local want = slot.spec
        if type(want) ~= "table" and StockPiler.RecipeSpec and StockPiler.RecipeSpec.ResolveSlotSpec then
            want = StockPiler.RecipeSpec.ResolveSlotSpec(slot)
        end
        if type(job.reserved) ~= "table" then
            job.reserved = {}
        end
        local bagSlot, item, bagType, matchedUid = FindCraftingBagItemBySpec(want, exemplarUid, job.reserved)
        if bagSlot > 0 and a.AddItemToCrafting then
            local craftSlot = StepCraftSlot(slot)
            local added = a.AddItemToCrafting(craftSlot, bagSlot, bagType, item)
            if added ~= true then
                LogBrew(string.format(
                    "load add-fail role=%s exemplar=%s bag=%s craftSlot=%s - abort",
                    tostring(slot.role), tostring(exemplarUid), tostring(bagSlot), tostring(craftSlot)
                ))
                AbortIncompleteLoad("load-add-fail-" .. tostring(slot.role or "?"))
                return false
            end
            slot.loadIssued = true
            slot.bagSlot = bagSlot
            slot.bagType = bagType
            slot.matchedUid = tonumber(matchedUid) or tonumber(item and item.uniqueID) or 0
            slot.reservedOk = false
            Brew._lastIssuedUid = slot.matchedUid
            Brew._lastIssuedRole = role
            -- Do not reserve until StepLanded - a failed land must not block
            -- the craft-bag stack and force a doomed inventory retry.
            job.waitTicks = 0
            LogBrew(string.format(
                "load issued role=%s exemplar=%s matchedUid=%s bag=%s bagType=%s craftSlot=%s",
                role,
                tostring(exemplarUid),
                tostring(matchedUid or (item and item.uniqueID) or 0),
                tostring(bagSlot),
                tostring(bagType),
                tostring(craftSlot)
            ))
        else
            LogBrew(string.format(
                "load miss role=%s exemplar=%s - abort exact recipe load",
                tostring(slot.role), tostring(exemplarUid)
            ))
            AbortIncompleteLoad("load-miss-" .. tostring(slot.role or "?"))
            return false
        end
        return true
    end
    if phase == "verify" then
        local VERIFY_WAIT_TICKS = tonumber(Brew.LOAD_VERIFY_TICKS) or 12
        job.waitTicks = (tonumber(job.waitTicks) or 0) + 1
        local recipe = job.recipe
        if BoardCoversRecipe(recipe) == true then
            Brew._job = nil
            if a.SetSoftLocks then
                a.SetSoftLocks(true)
            end
            SetSessionPhase("loaded", "load-verified")
            local session = GetSession()
            session.phase = "loaded"
            Brew._loadSettleUntil = NowSec() + (tonumber(Brew.LOAD_SETTLE_SEC) or 1.25)
            ForceBrewUiRefresh()
            return true
        end
        if job.waitTicks > VERIFY_WAIT_TICKS then
            LogBrew("load verify fail board-incomplete after "
                .. tostring(job.waitTicks) .. " ticks")
            AbortIncompleteLoad("load-board-incomplete")
            return false
        end
        return true
    end
    return false
end

local function KickLoadJob()
    -- Only nudge open/clear; never double-issue AddCraftingItem in one frame.
    AdvanceLoadJob()
    local job = Brew._job
    if type(job) == "table" and tostring(job.phase or "") ~= "load" then
        AdvanceLoadJob()
    end
end

----------------------------------------------------------------
-- Public load / clear / perform
----------------------------------------------------------------

function Brew.BeginForRow(row, opts)
    opts = type(opts) == "table" and opts or {}
    local source = opts.manual == true and "manual" or "auto"
    -- Auto holds: plant/refine/harvest. Seed buffer is per-watch Ready status.
    if source == "auto" then
        if OpenFailBlocked() then
            return false
        end
        local blocked, why = AutoBrewBlocked()
        if blocked then
            LogBrew("auto load blocked " .. tostring(why))
            return false
        end
    end
    -- Manual skips AutoGrow holds (plant/harvest/refine); clears open-fail backoff.
    if BeginLoadJob(row, source) then
        if opts.performAfter == true and source == "manual" then
            Brew._performAfterManualLoad = true
            Brew._performAfterLoadIgnoreSource = false
            Brew._performAfterLoadUntil = NowSec() + (tonumber(Brew.PERFORM_AFTER_LOAD_TTL_SEC) or 5)
        end
        Brew.ArmWatchUiHold()
        KickLoadJob()
        return true
    end
    return false
end

function Brew.ClearLoadedSession(opts)
    opts = type(opts) == "table" and opts or {}
    local session = GetSession()
    local a = AA()
    -- Pass the brew session so CloseWindow honors _brewOwnedSession / stealth and
    -- actually ends the apo crafting session (passing `true` was treated as nil).
    if a and a.CloseWindow then
        a.CloseWindow(session)
    elseif a and a.ClearSlots then
        a.ClearSlots()
    end
    Brew._postBrewClearArmed = false
    local reason = tostring(opts.reason or "clear")
    -- Inter-craft idle: session goes idle before the next load; hold Watch rebinds
    -- so planGen churn does not ListBoxSetDisplayOrder (blank rows).
    if string.find(reason, "after-brew", 1, true)
        or reason == "clear"
        or reason == "plan-updated"
        or reason == "cannot-continue"
    then
        Brew.ArmWatchUiHold()
    end
    ClearSession({ reason = opts.reason or "clear", adoptBlock = opts.adoptBlock == true })
    ForceBrewUiRefresh()
end

function Brew.OnRowCraftRightClick(row)
    -- R-click clear + 1.5s adopt block.
    Brew.ClearLoadedSession({ reason = "row-rclear", adoptBlock = true })
    return true
end

function Brew.OnRowCraftClick(row)
    if type(row) ~= "table" then
        return false
    end
    if row.kind == "plant" or row.isPlantWatch == true then
        return false
    end
    local session = GetSession()
    local sameRow = RowMatchesSession(row, session)
    -- Already loaded for this row: Perform on this click (any load source).
    if tostring(session.phase or "") == "loaded" and sameRow then
        if InLoadSettle() then
            Brew._performAfterManualLoad = true
            -- Click on an auto-loaded board must still Perform after settle.
            Brew._performAfterLoadIgnoreSource = true
            Brew._performAfterLoadUntil = NowSec() + (tonumber(Brew.PERFORM_AFTER_LOAD_TTL_SEC) or 5)
            return true
        end
        local ok = Brew.TryPerform(nil)
        if ok ~= true then
            ChatBrewBlocked(Brew._lastPerformBlockWhy or "not_ready")
        end
        return ok == true
    end
    if not RowCraftableGreen(row) then
        if (tonumber(row.craftable) or 0) > 0 and row.seedBufferShort == true then
            ChatBrewBlocked("buffer")
        elseif (tonumber(row.craftable) or 0) <= 0 then
            ChatBrewBlocked("nothing")
        else
            ChatBrewBlocked("not_ready")
        end
        return false
    end
    -- One click: load this recipe, then Perform after settle.
    local ok = Brew.BeginForRow(row, { manual = true, performAfter = true })
    if ok ~= true then
        ChatBrewBlocked("not_ready")
    end
    return ok == true
end

local function BoardHasContainerAndMain()
    local a = AA()
    if not (a and a.GetSlottedItem) then
        return false
    end
    local containerSlot = (ApothecaryWindow and ApothecaryWindow.SLOT_CONTAINER) or 0
    local mainSlot = (ApothecaryWindow and ApothecaryWindow.SLOT_DETERMINENT) or 1
    return a.GetSlottedItem(containerSlot) ~= nil and a.GetSlottedItem(mainSlot) ~= nil
end

--- Why perform is unsafe right now (or nil if ok). Bypasses stock UI stability cache.
local function PerformBlockReason()
    local a = AA()
    if not a then
        return "no-adapter"
    end
    if a.IsPerforming and a.IsPerforming() == true then
        return "performing"
    end
    if a.ServerHasItems and a.ServerHasItems() ~= true then
        return "empty-board"
    end
    -- Prefer concrete board gaps over generic craft-state (partial loads often
    -- report not-brewable while only the container is present).
    if not BoardHasContainerAndMain() then
        return "missing-container-or-main"
    end
    if a.IsBrewableCraftState and a.IsBrewableCraftState() ~= true then
        return "bad-craft-state:" .. tostring(a.CraftingState and a.CraftingState() or "?")
    end
    -- Read GameData directly (not ApothecaryWindow.stabilityCurrentState).
    -- Stock SetStabilityState ignores INVALID(0), so the green hint can stick while
    -- SuccessChance is already INVALID after a mat change / depleting mid-brew.
    if a.SuccessChanceAllowsPerform and a.SuccessChanceAllowsPerform() ~= true then
        local chance = a.SuccessChance and a.SuccessChance() or "?"
        if a.WillDefinitelyFail and a.WillDefinitelyFail() == true then
            return "engine-will-fail:" .. tostring(chance)
        end
        return "engine-chance-unusable:" .. tostring(chance)
    end
    local session = GetSession()
    local recipe = session and session.recipe
    if type(recipe) ~= "table" and type(Brew._job) == "table" then
        recipe = Brew._job.recipe
    end
    if type(recipe) == "table" and BoardCoversRecipe(recipe) ~= true then
        return "board-incomplete"
    end
    return nil
end

function Brew.ValidateApothecaryPerform()
    return PerformBlockReason() == nil
end

function Brew.TryPerform(opId)
    if Brew._loadSource == "manual" then
        Brew._manualLoadedActivityAt = NowSec()
    end
    local a = AA()
    Brew._lastPerformBlockWhy = nil
    -- Seed buffer is enforced via Ready status (and shared demotion); not a global perform gate.
    local why = PerformBlockReason()
    if why ~= nil then
        Brew._lastPerformBlockWhy = why
        LogBrew("perform blocked " .. tostring(why)
            .. " SuccessChance=" .. tostring(a and a.SuccessChance and a.SuccessChance() or "?")
            .. " uiDesync=" .. tostring(a and a.UiStabilityDesync and a.UiStabilityDesync()))
        -- Auto loads must not sit forever on a red / incomplete / INVALID board.
        if Brew._loadSource == "auto" and GetSession().phase == "loaded"
            and ShouldAutoUnloadForEngine(why)
        then
            Brew.ClearLoadedSession({ reason = why })
            ForceBrewUiRefresh()
        end
        return false
    end
    local Perf = StockPiler.Perf
    if Perf and Perf.Begin then
        Perf.Begin("Brew.TryPerform")
    end
    Brew.ArmBrewOpLock(Brew.BREW_OP_LOCK_SEC)
    local ok = a and a.Perform and a.Perform() == true
    if ok then
        Brew._awaitingBrewComplete = true
        Brew._lastPerformAt = NowSec()
        Brew._postBrewClearArmed = false
        Brew._brewHaveBefore = LivePotionHave(GetSession())
        LogBrew("perform opId=" .. tostring(opId or "?")
            .. " haveBefore=" .. tostring(Brew._brewHaveBefore))
        local SkillUp = StockPiler.SkillUp
        if SkillUp and SkillUp.NoteApoAttempt then
            local session = GetSession()
            SkillUp.NoteApoAttempt({ skillUp = session and session.skillUp == true })
        end
        -- Do not EnqueueBagFlush here. The craft already emits inventory slot
        -- events; a coalesced flush landed ~2s later on the next brew and ran
        -- a second WarmHave + craftable recount on the perform frame.
        -- Grey immediately; ForceBrewUiRefresh re-lits when busy clears.
        ForceBrewUiRefresh()
    end
    if Perf and Perf.End then
        Perf.End("Brew.TryPerform")
    end
    return ok == true
end

--- True when a brew Perform happened within the last few seconds.
function Brew.PerformedWithin(sec)
    local at = tonumber(Brew._lastPerformAt) or 0
    if at <= 0 then
        return false
    end
    local now = NowSec()
    sec = tonumber(sec) or 5
    if now <= 0 then
        return false
    end
    return (now - at) >= 0 and (now - at) <= sec
end

--- Returns "go" | "blocked"
function Brew.TryBrewClick()
    local Caps = StockPiler.TradeSkillCaps
    if Caps and Caps.CanBrewPotions and Caps.CanBrewPotions() ~= true then
        return "blocked"
    end
    if Brew.IsBusy() then
        return "blocked"
    end
    if OpenFailBlocked() then
        return "blocked"
    end
    local session = GetSession()
    local phase = tostring(session.phase or "idle")

    if phase == "loaded" then
        if Brew._loadSource == "manual" then
            return "blocked"
        end
        if session.skillUp == true then
            if Brew.ValidateApothecaryPerform() == true then
                return "go"
            end
            local why = PerformBlockReason() or "click-perform-blocked"
            LogBrew("click unload skillup perform-blocked reason=" .. tostring(why))
            Brew.ClearLoadedSession({ reason = why })
            ForceBrewUiRefresh()
            return "blocked"
        end
        SyncSessionStockFromBags(session)
        if RowNeedsMorePotions(session) == false then
            PatchPlanRowTargetMet(session, session.potionHave)
            Brew.ClearLoadedSession({ reason = "click-target-met" })
            ForceBrewUiRefresh()
            return "blocked"
        end
        local deficitOk = (tonumber(session.potionDeficit) or 0) > 0
        local row = FindSessionRow()
        if deficitOk and RowNeedsMorePotions(session) and RowIsReadyToCraft(row) then
            if Brew.ValidateApothecaryPerform() == true then
                return "go"
            end
            -- Ready on plan but board/engine unsafe - unload so the next click
            -- can reload. Do not fall through into BeginLoadJob while loaded.
            local why = PerformBlockReason() or "click-perform-blocked"
            LogBrew("click unload perform-blocked reason=" .. tostring(why))
            Brew.ClearLoadedSession({ reason = why })
            ForceBrewUiRefresh()
            return "blocked"
        end
        if not RowIsReadyToCraft(row) then
            Brew.ClearLoadedSession({ reason = "click-not-ready" })
            ForceBrewUiRefresh()
            return "blocked"
        end
        local have = tonumber(session.potionHave) or 0
        local min = tonumber(session.potionMin) or 0
        local covered = min <= 0 or (have + (tonumber(session.craftable) or 0)) >= min
        if not covered then
            Brew.ClearLoadedSession({ reason = "uncovered-wait-grow" })
            ForceBrewUiRefresh()
            return "blocked"
        end
        -- Still loaded + Ready + covered but didn't return "go" - stay blocked
        -- without starting another load on top of this board.
        return "blocked"
    end

    if NowSec() < (tonumber(Brew._adoptBlockUntil) or 0) then
        return "blocked"
    end

    local nextRow = Brew.PickReadyWatch()
    if type(nextRow) == "table" then
        if BeginLoadJob(nextRow, "auto") then
            KickLoadJob()
            return "blocked" -- load started; perform next click
        end
    end
    return "blocked"
end

function Brew.BrewClick()
    local result = Brew.TryBrewClick()
    if result == "go" then
        return Brew.TryPerform(nil)
    end
    return false
end

function Brew.FirePerform()
    return Brew.TryPerform(nil)
end

--- Manual Load leaves the board up on purpose. After MANUAL_LOADED_IDLE_SEC
--- with no perform or phase change, unload so AutoGrow can plant.
--- Only TryPerform and phase changes reset _manualLoadedActivityAt; crafting
--- updates and bag snaps do not (#35 L9).
function Brew.ExpireManualLoadedIdle()
    if Brew._loadSource ~= "manual" then
        return false
    end
    if Brew.IsLoadJobActive and Brew.IsLoadJobActive() == true then
        Brew._manualLoadedActivityAt = NowSec()
        return false
    end
    local session = GetSession()
    if tostring(session.phase or "") ~= "loaded" then
        return false
    end
    local idleSec = tonumber(Brew.MANUAL_LOADED_IDLE_SEC) or 60
    local at = tonumber(Brew._manualLoadedActivityAt) or 0
    local now = NowSec()
    if at <= 0 then
        Brew._manualLoadedActivityAt = now
        return false
    end
    if now <= 0 or (now - at) < idleSec then
        return false
    end
    LogBrew("manual loaded idle timeout")
    Brew.ClearLoadedSession({ reason = "manual-idle" })
    return true
end

----------------------------------------------------------------
-- Tick / closed-window sync
----------------------------------------------------------------

function Brew.IsLoadJobActive()
    return type(Brew._job) == "table"
end

function Brew.Tick()
    if Brew.IsLoadJobActive() then
        local Perf = StockPiler.Perf
        if Perf and Perf.Begin then
            Perf.Begin("Brew.LoadJob")
        end
        AdvanceLoadJob()
        if Perf and Perf.End then
            Perf.End("Brew.LoadJob")
        end
        return true
    end
    return false
end

--- Auto-load the top Ready row (SkillUp or watch) while idle so Craft/Brew only
--- light when a click would Perform - not for the silent "start load" click.
function Brew.MaybeAutoLoadReady()
    if type(Brew._job) == "table" then
        return false
    end
    local session = GetSession()
    if tostring(session.phase or "idle") ~= "idle" then
        return false
    end
    if NowSec() < (tonumber(Brew._adoptBlockUntil) or 0) then
        return false
    end
    if OpenFailBlocked() then
        return false
    end
    local blocked = AutoBrewBlocked()
    if blocked then
        return false
    end
    local row = Brew.PickReadyWatch()
    if type(row) ~= "table" then
        return false
    end
    if BeginLoadJob(row, "auto") then
        KickLoadJob()
        LogBrew("auto-load ready key=" .. tostring(row.potionKey or row.id or "?"))
        return true
    end
    return false
end

--- Back-compat alias (SkillUp used to be the only auto-load path).
function Brew.MaybeAutoLoadSkillUp()
    return Brew.MaybeAutoLoadReady()
end

--- Clear auto-loaded sessions that cannot perform after settle.
--- Without this, settle-hold + no further crafting-updated parks phase=loaded,
--- Orchestrator skips grow, and Scheduler skips plan rebuild until watchplan.
function Brew.ProbeStuckAutoLoaded(reason)
    local session = GetSession()
    if tostring(session.phase or "") ~= "loaded" then
        return false
    end
    if Brew._loadSource ~= "auto" then
        return false
    end
    if type(Brew._job) == "table" then
        return false
    end
    if InLoadSettle() then
        return false
    end
    local why = PerformBlockReason()
    if why ~= nil and ShouldAutoUnloadForEngine(why) then
        LogBrew("stuck-probe unload reason=" .. tostring(why)
            .. " via=" .. tostring(reason or "?"))
        Brew.ClearLoadedSession({ reason = why })
        ForceBrewUiRefresh()
        return true
    end
    return Brew.MaybeClearLoadedIfCannotContinue(reason or "stuck-probe") == true
end

--- AutoBrew: perform an auto-loaded Ready board when the master toggle is on.
--- Silent MaybeAutoLoadReady still runs without AutoBrew; this only fires Perform.
--- Does not use CanBrewNow (that stays false while AutoBrew is on for footer/macro).
function Brew.MaybeAutoPerformReady()
    local Watch = StockPiler.Watch
    if not (Watch and Watch.IsAutoBrewEnabled and Watch.IsAutoBrewEnabled() == true) then
        return false
    end
    if type(Brew._job) == "table" then
        return false
    end
    if InLoadSettle() then
        return false
    end
    local blocked = AutoBrewBlocked()
    if blocked then
        return false
    end
    if BoardReadyToAutoPerform() ~= true then
        return false
    end
    local ok = Brew.TryPerform(nil)
    if ok == true then
        LogBrew("auto-perform ready")
    end
    return ok == true
end

--- Row Brew button: after load settles, Perform once (one-click load+brew).
--- BoardReadyToAutoPerform is auto-source only; use PerformBlockReason here.
function Brew.MaybePerformAfterManualLoad()
    if Brew._performAfterManualLoad ~= true then
        return false
    end
    local now = NowSec()
    local untilT = tonumber(Brew._performAfterLoadUntil) or 0
    if untilT > 0 and now > untilT then
        Brew._performAfterManualLoad = false
        Brew._performAfterLoadIgnoreSource = false
        Brew._performAfterLoadUntil = 0
        return false
    end
    if type(Brew._job) == "table" then
        return false
    end
    if InLoadSettle() then
        return false
    end
    local session = GetSession()
    if tostring(session.phase or "") ~= "loaded" then
        return false
    end
    if Brew._loadSource ~= "manual" and Brew._performAfterLoadIgnoreSource ~= true then
        Brew._performAfterManualLoad = false
        Brew._performAfterLoadIgnoreSource = false
        Brew._performAfterLoadUntil = 0
        return false
    end
    if Brew.IsBusy() then
        return false
    end
    local why = PerformBlockReason()
    if why ~= nil then
        if ShouldAutoUnloadForEngine(why) then
            LogBrew("manual-perform-after unload reason=" .. tostring(why))
            Brew.ClearLoadedSession({ reason = why })
            ForceBrewUiRefresh()
        end
        -- Non-unload blocks (performing / empty-board / ...): keep armed until TTL.
        return false
    end
    Brew._performAfterManualLoad = false
    Brew._performAfterLoadIgnoreSource = false
    Brew._performAfterLoadUntil = 0
    local ok = Brew.TryPerform(nil)
    if ok == true then
        LogBrew("manual-perform-after-load")
    else
        ChatBrewBlocked(Brew._lastPerformBlockWhy or "not_ready")
    end
    return ok == true
end

function Brew.OnUpdate(timeElapsed)
    if type(Brew._job) == "table" then
        Brew.Tick()
    end
    local lockUntil = tonumber(Brew._brewOpLockUntil) or 0
    if lockUntil > 0 and NowSec() >= lockUntil then
        Brew._brewOpLockUntil = 0
        ForceBrewUiRefresh()
    end
    local busy = Brew.IsBusy() == true
    if Brew._wasBusy == true and busy ~= true then
        if Brew._awaitingBrewComplete == true then
            Brew._awaitingBrewComplete = false
            Brew.RefreshSessionAfterBrew()
        else
            ForceBrewUiRefresh()
        end
    end
    Brew._wasBusy = busy

    if StockPiler.Macro and StockPiler.Macro.ExpireBrewFiredGuard then
        StockPiler.Macro.ExpireBrewFiredGuard()
    end
    Brew.ExpireManualLoadedIdle()

    local now = NowSec()
    local interval = tonumber(Brew.STUCK_PROBE_SEC) or 0.5
    if interval < 0.25 then
        interval = 0.25
    end
    local due = (tonumber(Brew._stuckProbeAt) or 0) + interval
    if now > 0 and now >= due then
        Brew._stuckProbeAt = now
        Brew.ProbeStuckAutoLoaded("onupdate")
        if Brew.MaybePerformAfterManualLoad then
            Brew.MaybePerformAfterManualLoad()
        end
        if Brew.MaybeAutoPerformReady then
            Brew.MaybeAutoPerformReady()
        end
        if Brew.MaybeAutoLoadSkillUp then
            Brew.MaybeAutoLoadSkillUp()
        end
    end
end

--- Closed-window: live-patch Status; RequestFooterRefresh only when HasReadyToCraft flips.
function Brew.SyncLiveStatusClosedWindow()
    local had = Brew._lastHasReady
    local has = Brew.HasReadyToCraft()
    Brew._lastHasReady = has
    Brew.InvalidateCanBrewCache()
    if had ~= nil and had ~= has then
        RequestFooterRefresh()
    end
    Brew.MaybeNotifyBrewReady()
    return has
end

function Brew.OnCraftingUpdated()
    -- Stock SetStateData tries to show apo children; swallow those shows while we own apo.
    local a = AA()
    if a and a.EnforceStealthHide then
        a.EnforceStealthHide(GetSession())
    end
    if GetSession().phase == "loaded" or GetSession().phase == "loading" then
        Brew.InvalidateCanBrewCache()
    end
    if Brew._awaitingBrewComplete == true then
        local a = AA()
        if not (a and a.IsPerforming and a.IsPerforming() == true) then
            Brew._awaitingBrewComplete = false
            Brew.RefreshSessionAfterBrew()
            return
        end
        return
    end
    -- Skip mid-load slot storms; re-tint after busy clears / lock expiry instead.
    if type(Brew._job) == "table" then
        return
    end
    -- Engine chance / incomplete board after mat change: unload auto (stock UI may still show green).
    if GetSession().phase == "loaded" and Brew._loadSource == "auto" then
        local why = PerformBlockReason()
        if why ~= nil and ShouldAutoUnloadForEngine(why) then
            local a = AA()
            LogBrew("crafting-updated unload auto reason=" .. tostring(why)
                .. " uiDesync=" .. tostring(a and a.UiStabilityDesync and a.UiStabilityDesync()))
            Brew.ClearLoadedSession({ reason = why })
            ForceBrewUiRefresh()
            return
        elseif why ~= nil and InLoadSettle() then
            local a = AA()
            LogBrew("crafting-updated settle hold reason=" .. tostring(why)
                .. " SuccessChance=" .. tostring(a and a.SuccessChance and a.SuccessChance() or "?"))
            -- Do not ForceBrew here - settle fires 3-5 CraftingUpdateds per load
            -- (empty-board / bad-craft-state / engine-will-fail) and each paint
            -- stacked Footer + WatchRows on SkillUp brew spikes.
            return
        end
    end
    -- Re-tint macros: engine greys ActionButtons during craft even when CanBrewNow
    -- stays true, and SyncActionReadiness would otherwise skip as "unchanged".
    -- Footer/Macro only - WatchRows wait for idle/after-brew refresh.
    ForceBrewUiRefresh({ rows = false })
end

--- Bust craftable stamps + recount Stock/Status/Craftable on plan + Watch listData.
--- Manual brew keeps phase=loaded (normally blocks WarmHave recount).
--- A BagFlush frame just walked both bags. Do not stack a cold WarmHave on it.
local function SyncWatchLiveCountsAfterBrew()
    local Planner = StockPiler.Planner
    if not Planner then
        return
    end
    local Sch = StockPiler.Scheduler
    local deferBag = Sch and Sch.ShouldDeferWarmHaveBag and Sch.ShouldDeferWarmHaveBag() == true
    local haveWarm = Planner.IsHaveCacheWarmForSnap and Planner.IsHaveCacheWarmForSnap() == true
    local allowWarmHave = true
    local forceRecountCraftable = true
    if deferBag and haveWarm ~= true then
        allowWarmHave = false
        forceRecountCraftable = false
        if Sch.RequestCachePrewarm then
            Sch.RequestCachePrewarm("after-brew-counts")
        end
    end
    if Planner.LiveRecount then
        Planner.LiveRecount({
            syncSnapshot = true,
            allowWarmHave = allowWarmHave,
            forceRecountCraftable = forceRecountCraftable,
        })
    end
    -- Optimistic craftable on the session row when bags have not snapped yet.
    local session = GetSession()
    local row = FindSessionRow()
    if type(row) == "table" and session.craftable ~= nil then
        local c = math.max(0, tonumber(session.craftable) or 0)
        if (tonumber(row.craftable) or 0) > c then
            row.craftable = c
            row.craftableText = towstring(tostring(c))
        end
    end
    -- LiveRecount already patched counts. A recount flag here queues a second pass.
    local Bus = StockPiler.EventBus
    if Bus and Bus.FireWatchUiDirty then
        Bus.FireWatchUiDirty({ immediate = true, reason = "after-brew-counts" })
    end
end

--- After a brew completes: sync live stock; unload when target met or no longer Ready.
function Brew.RefreshSessionAfterBrew()
    local session = GetSession()
    if tostring(session.phase or "") ~= "loaded" then
        Brew._postBrewClearArmed = false
        Brew._brewHaveBefore = nil
        ForceBrewUiRefresh()
        return
    end

    -- SkillUp Apo: always unload after a completed brew (any load trigger).
    -- Auto re-arms via bag flush only while ShouldApoBrew is still true.
    if session.skillUp == true then
        Brew._brewHaveBefore = nil
        if session.craftable ~= nil then
            session.craftable = math.max(0, (tonumber(session.craftable) or 0) - 1)
        end
        local stillValid = Brew.ValidateApothecaryPerform() == true
        local craftLeft = tonumber(session.craftable) or 0
        LogBrew(string.format(
            "after-brew skillup craftable=%s valid=%s",
            tostring(craftLeft), tostring(stillValid)
        ))
        Brew.ClearLoadedSession({ reason = "after-brew-skillup-done" })
        local SkillUp = StockPiler.SkillUp
        if SkillUp and SkillUp.ShouldApoBrew and SkillUp.ShouldApoBrew() == true
            and StockPiler.Scheduler and StockPiler.Scheduler.EnqueueBagFlush
        then
            StockPiler.Scheduler.EnqueueBagFlush(true)
        end
        SyncWatchLiveCountsAfterBrew()
        return
    end

    local haveBefore = Brew._brewHaveBefore
    -- Prefer live bag count (yield estimates under/over-count crits and lag).
    SyncSessionStockFromBags(session)
    local haveAfter = LivePotionHave(session)
    if haveAfter == nil then
        -- Bag snapshot has not landed. Wait; do not invent a count from the plan.
        Brew._postBrewClearArmed = true
        LogBrew("after-brew have unknown; waiting for bags")
        return
    end
    Brew._brewHaveBefore = nil
    if session.craftable ~= nil then
        session.craftable = math.max(0, (tonumber(session.craftable) or 0) - 1)
    end
    -- Live-patch Watch rows (stock/status/craftable) before unload gate.
    SyncWatchLiveCountsAfterBrew()
    if not (StockPiler.Planner and StockPiler.Planner.LiveRecount)
        and StockPiler.Scheduler and StockPiler.Scheduler.EnqueuePlanRebuild
    then
        StockPiler.Scheduler.EnqueuePlanRebuild()
    end
    local stillValid = Brew.ValidateApothecaryPerform() == true
    local deficit = tonumber(session.potionDeficit)
    if deficit == nil and PotionTargetMin(session) > 0 then
        deficit = math.max(0, PotionTargetMin(session) - (tonumber(session.potionHave) or 0))
        session.potionDeficit = deficit
    end
    deficit = tonumber(deficit) or 0
    -- Live bags are SoT: treat target-met even if deficit field lagged.
    -- Unknown (nil) is not target-met; the post-brew bag recheck decides later.
    if RowNeedsMorePotions(session) == false then
        deficit = 0
        session.potionDeficit = 0
    end

    local advanced = nil
    if haveBefore ~= nil and haveAfter ~= nil then
        advanced = haveAfter > haveBefore
    end
    if advanced == false then
        Brew._postBrewClearArmed = true
        Brew._brewHaveBefore = haveBefore
        LogBrew("after-brew bag has not advanced; waiting for bags")
        return
    end

    LogBrew(string.format(
        "after-brew have=%s/%s deficit=%s craftable=%s phase=%s valid=%s advanced=%s",
        tostring(session.potionHave),
        tostring(session.potionMin),
        tostring(deficit),
        tostring(session.craftable),
        tostring(session.phase),
        tostring(stillValid),
        tostring(advanced)
    ))

    if deficit <= 0 then
        -- Manual: keep Brew while the board can still perform (same loadout).
        if Brew._loadSource == "manual" and stillValid == true then
            ForceBrewUiRefresh()
            return
        end
        PatchPlanRowTargetMet(session, session.potionHave)
        LogBrew("target met - unload have=" .. tostring(session.potionHave)
            .. "/" .. tostring(session.potionMin))
        Brew.ClearLoadedSession({ reason = "after-brew-target-met" })
        return
    end
    if Brew._loadSource == "manual" then
        if stillValid == true then
            ForceBrewUiRefresh()
            return
        end
        LogBrew("after-brew manual unload valid=false")
        Brew.ClearLoadedSession({ reason = "after-brew-manual-invalid" })
        return
    end
    -- Auto: unload after a completed brew; re-arm via bag flush when still Ready.
    local row = FindSessionRow()
    local wantContinue = stillValid == true
        and Brew._loadSource ~= "manual"
        and RowIsReadyToCraft(row) == true
    Brew.ClearLoadedSession({ reason = "after-brew-done" })
    if wantContinue == true
        and StockPiler.Scheduler and StockPiler.Scheduler.EnqueueBagFlush
    then
        StockPiler.Scheduler.EnqueueBagFlush(true)
    end
end

--- Bag snap after brew: unload if target met, no longer Ready, or watch uid did not advance.
function Brew.OnInventorySnapshot()
    if Brew._postBrewClearArmed ~= true then
        return
    end
    local session = GetSession()
    if tostring(session.phase or "") ~= "loaded" then
        Brew._postBrewClearArmed = false
        Brew._brewHaveBefore = nil
        return
    end
    SyncSessionStockFromBags(session)
    -- Bags just snapped: refresh Watch stock/status/craftable for manual + auto.
    SyncWatchLiveCountsAfterBrew()
    if RowNeedsMorePotions(session) == false then
        if Brew._loadSource == "manual" and Brew.ValidateApothecaryPerform() == true then
            Brew._postBrewClearArmed = false
            Brew._brewHaveBefore = nil
            ForceBrewUiRefresh()
            return
        end
        PatchPlanRowTargetMet(session, session.potionHave)
        LogBrew("post-brew bag sync - unload have="
            .. tostring(session.potionHave) .. "/" .. tostring(session.potionMin))
        Brew.ClearLoadedSession({ reason = "after-brew-bags" })
        return
    end
    if Brew._loadSource ~= "manual" then
        local row = FindSessionRow()
        if not RowIsReadyToCraft(row) then
            Brew.ClearLoadedSession({ reason = "after-brew-inv-not-ready" })
            return
        end
        local haveBefore = Brew._brewHaveBefore
        local haveAfter = LivePotionHave(session)
        if haveBefore ~= nil and haveAfter ~= nil and haveAfter <= haveBefore then
            Brew.ClearLoadedSession({ reason = "after-brew-no-advance" })
            return
        end
    else
        ForceBrewUiRefresh()
    end
    if Brew.MaybeClearLoadedIfCannotContinue("after-brew-inv") then
        return
    end
    Brew._postBrewClearArmed = false
    Brew._brewHaveBefore = nil
end

function Brew.MaybeClearLoadedIfCannotContinue(reason)
    local session = GetSession()
    if tostring(session.phase or "") ~= "loaded" then
        return false
    end
    if Brew._loadSource == "manual" then
        return false
    end
    -- Post-load settle: board/chance lag looks like not-Ready; wait before unloading.
    if InLoadSettle() then
        return false
    end
    SyncSessionStockFromBags(session)
    local deficit = tonumber(session.potionDeficit) or 0
    local row = FindSessionRow()
    -- Unload when target met, or when this watch is no longer uncontested Ready
    -- (mats short / shared / buy / restocking - AutoGrow/AutoBuy must refill first).
    if deficit <= 0 or RowNeedsMorePotions(session) == false or not RowIsReadyToCraft(row) then
        if deficit <= 0 or RowNeedsMorePotions(session) == false then
            PatchPlanRowTargetMet(session, session.potionHave)
        end
        Brew.ClearLoadedSession({ reason = reason or "cannot-continue" })
        return true
    end
    return false
end

----------------------------------------------------------------
-- Events
----------------------------------------------------------------

function Brew.RegisterEventHandlers()
    if Brew._eventHandlers == true then
        return
    end
    Brew._eventHandlers = true
    local B = StockPiler.EventBus
    local E = StockPiler.Events
    Brew._busTokens = Brew._busTokens or {}
    if B and E then
        if E.PLAN_UPDATED then
            Brew._busTokens[#Brew._busTokens + 1] = B.Subscribe(E.PLAN_UPDATED, function()
                Brew.InvalidateCanBrewCache()
                Brew.MaybeClearLoadedIfCannotContinue("plan-updated")
            end)
        end
        if E.SESSION_LOADED then
            Brew._busTokens[#Brew._busTokens + 1] = B.Subscribe(E.SESSION_LOADED, function()
                Brew._readyNotifyKeys = nil
                Brew._brewReadyLatched = false
                Brew._brewEnableAnnounced = nil
                if StockPiler.Grow and StockPiler.Grow.ResetHarvestEnableAnnounced then
                    StockPiler.Grow.ResetHarvestEnableAnnounced()
                end
                Brew.ClearOpenFailBackoff()
                Brew.InvalidateCanBrewCache()
                -- Scenario/zone load leaves apo board invalid; a stuck loaded session
                -- also holds Watch UI in mid-brew catchup (SkillUp rows never rebind).
                -- ClearSession alone does not CloseWindow, so _suppressEngineShow
                -- stays latched and the Apothecary ability no-ops until /reload.
                local session = GetSession()
                local phase = type(session) == "table" and tostring(session.phase or "idle") or "idle"
                local a = AA()
                local owned = type(session) == "table" and (
                    session._brewOwnedSession == true
                    or session._brewApoStealth == true
                    or session._brewOpenedApo == true
                )
                if phase == "loading" or phase == "loaded" or owned == true then
                    if a and a.CloseWindow then
                        a.CloseWindow(session)
                    elseif a and a.ClearEngineShowSuppress then
                        a.ClearEngineShowSuppress()
                        if a.EndStealthUi then
                            a.EndStealthUi()
                        end
                    end
                elseif a and a.ClearEngineShowSuppress then
                    a.ClearEngineShowSuppress()
                end
                if phase == "loading" or phase == "loaded" then
                    ClearSession({ reason = "loading-end" })
                    ForceBrewUiRefresh()
                end
            end)
        end
        if E.INVENTORY_SNAPSHOT then
            Brew._busTokens[#Brew._busTokens + 1] = B.Subscribe(E.INVENTORY_SNAPSHOT, function()
                if Brew.OnInventorySnapshot then
                    Brew.OnInventorySnapshot()
                end
            end)
        end
    end
end

function Brew.UnregisterEventHandlers()
    local B = StockPiler.EventBus
    local tokens = Brew._busTokens
    if B and B.Unsubscribe and type(tokens) == "table" then
        for i = 1, #tokens do
            B.Unsubscribe(tokens[i])
        end
    end
    Brew._busTokens = nil
    Brew._eventHandlers = nil
end

function Brew.DumpSession(emit)
    emit = type(emit) == "function" and emit or function(msg)
        if StockPiler.Debug and StockPiler.Debug.Print then
            StockPiler.Debug.Print(msg)
        end
    end
    local session = GetSession()
    local aStat = AA()
    local engChance = aStat and aStat.SuccessChance and aStat.SuccessChance() or "?"
    local willFail = aStat and aStat.WillDefinitelyFail and aStat.WillDefinitelyFail() == true
    local allows = aStat and aStat.SuccessChanceAllowsPerform and aStat.SuccessChanceAllowsPerform() == true
    local uiDesync = aStat and aStat.UiStabilityDesync and aStat.UiStabilityDesync() == true
    local painted = (type(ApothecaryWindow) == "table") and tostring(ApothecaryWindow.stabilityCurrentState) or "?"
    emit(string.format(
        "  session phase=%s source=%s busy=%s canBrew=%s engChance=%s allows=%s willFail=%s uiDesync=%s painted=%s name=%s",
        tostring(session.phase),
        tostring(Brew._loadSource),
        tostring(Brew.IsBusy()),
        tostring(Brew.CanBrewNow()),
        tostring(engChance),
        tostring(allows),
        tostring(willFail),
        tostring(uiDesync),
        painted,
        tostring(session.name)
    ))
    local recipe = session.recipe
    if type(recipe) ~= "table" then
        recipe = Brew._job and Brew._job.recipe
    end
    if type(recipe) == "table" and type(recipe.slots) == "table" then
        local RS = StockPiler.RecipeSpec
        if RS and RS.HydrateRecipeSlots then
            RS.HydrateRecipeSlots(recipe)
        end
        local stab = RS and RS.SpecStabilityTotal and RS.SpecStabilityTotal(recipe.slots) or "?"
        emit(string.format(
            "  recipe key=%s slots=%d bonusStabilitySum=%s",
            tostring(recipe.specKey or recipe.recipeSpecKey or recipe.key or ""),
            #recipe.slots,
            tostring(stab)
        ))
        for i = 1, #recipe.slots do
            local slot = recipe.slots[i]
            if type(slot) == "table" then
                local uid = tonumber(slot.uid) or 0
                if uid <= 0 and type(slot.spec) == "table" then
                    uid = tonumber(slot.spec.uid) or tonumber(slot.spec.uniqueID) or 0
                end
                local per = tonumber(slot.perCraft) or 1
                local eff = per
                if RS and RS.EffectiveSpecPerCraft then
                    eff = tonumber(RS.EffectiveSpecPerCraft(slot, recipe.slots)) or per
                end
                local stabSlot = 0
                if RS and RS.ResolveSlotSpec then
                    local spec = RS.ResolveSlotSpec(slot)
                    stabSlot = tonumber(spec and spec.stability) or 0
                elseif type(slot.spec) == "table" then
                    stabSlot = tonumber(slot.spec.stability) or 0
                end
                emit(string.format(
                    "    slot role=%s uid=%s per=%s eff=%s stab=%s key=%s",
                    tostring(slot.role), tostring(uid), tostring(per), tostring(eff), tostring(stabSlot),
                    (StockPiler.MaterialSpec and StockPiler.MaterialSpec.Key
                        and StockPiler.MaterialSpec.Key(
                            (RS and RS.ResolveSlotSpec and RS.ResolveSlotSpec(slot)) or slot.spec
                        )) or "?"
                ))
            end
        end
        local steps = BuildLoadSteps(recipe)
        emit(string.format("  loadSteps=%d", type(steps) == "table" and #steps or 0))
        if type(steps) == "table" then
            for i = 1, #steps do
                local s = steps[i]
                emit(string.format(
                    "    step[%d] role=%s uid=%s craftSlot=%s",
                    i, tostring(s.role), tostring(s.uid or s.uniqueID), tostring(s.craftingSlot)
                ))
            end
        end
    end
    if type(Brew._job) == "table" then
        emit(string.format(
            "  loadJob phase=%s index=%s/#%s",
            tostring(Brew._job.phase),
            tostring(Brew._job.index),
            type(Brew._job.slots) == "table" and tostring(#Brew._job.slots) or "?"
        ))
    end
end

function Brew.DumpPlan(emit)
    emit = type(emit) == "function" and emit or function(msg)
        if StockPiler.Debug and StockPiler.Debug.Print then
            StockPiler.Debug.Print(msg)
        end
    end
    local session = GetSession()
    local blockedWhy = Brew.AutoBrewBlockedReason and Brew.AutoBrewBlockedReason() or nil
    emit("=== brew plan ===")
    emit("phase=" .. tostring(session.phase)
        .. " source=" .. tostring(Brew._loadSource)
        .. " busy=" .. tostring(Brew.IsBusy())
        .. " canBrew=" .. tostring(Brew.CanBrewNow())
        .. " autoBlocked=" .. tostring(blockedWhy or "no"))
    local Grow = StockPiler.Grow
    local Refine = StockPiler.Refine
    emit(string.format(
        "  bufferSatisfied=%s bufferShort=%s pendingRefine=%s pendingPlant=%s refineOut=%s",
        tostring(Grow and Grow.IsSeedBufferSatisfied and Grow.IsSeedBufferSatisfied()),
        tostring(Grow and Grow.HasAnyBufferShort and Grow.HasAnyBufferShort()),
        tostring(Grow and Grow.HasPendingBufferRefine and Grow.HasPendingBufferRefine()),
        tostring(Grow and Grow.HasPendingPlant and Grow.HasPendingPlant()),
        tostring(StockPiler.RefinePipeline and StockPiler.RefinePipeline.HasOutstanding
            and StockPiler.RefinePipeline.HasOutstanding())
    ))
    emit("respectGrowReserve=" .. tostring(BrewRespectGrowReserve()))
    emit("hasReady=" .. tostring(Brew.HasReadyToCraft())
        .. " openFailBlocked=" .. tostring(OpenFailBlocked()))
    local ready = Brew.PickReadyWatch()
    if type(ready) == "table" then
        emit(string.format(
            "ready name=%s deficit=%s craftable=%s autoGrow=%s",
            tostring(ready.name), tostring(ready.potionDeficit), tostring(ready.craftable),
            tostring(ready.autoGrow == true)
        ))
    end
    Brew.DumpSession(emit)
    emit("=== end brew plan ===")
end
