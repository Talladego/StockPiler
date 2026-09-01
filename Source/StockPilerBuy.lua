----------------------------------------------------------------
-- StockPilerBuy - Watch-tab AutoBuy from NPC interaction stores
----------------------------------------------------------------

StockPiler.Buy = StockPiler.Buy or {}

local BRASS_PER_GOLD = 10000
local STORE_WIN = "EA_Window_InteractionStore"
local RESERVE_MIN = 1
local RESERVE_MAX = 99
local BUDGET_MIN = 1
local BUDGET_MAX = 999
local DEFAULT_RESERVE = 10
local DEFAULT_BUDGET = 50
-- Hard cap: one BuyItem per tick, but never more than this many
-- successful purchases per store visit (runaway / failed-accounting guard).
local MAX_PURCHASES_PER_VISIT = 80

local function D(msg)
    if StockPiler and StockPiler.D then
        StockPiler.D(msg)
    end
end

local function LogBuyOp(msg)
    if StockPiler.LogOp then
        StockPiler.LogOp("buy", msg)
    else
        D("AutoBuy " .. tostring(msg))
    end
end

--- AutoBuy uilog line. force=true for one-shot dumps (/stp buyplan).
local function EmitBuyTrace(msg, force)
    if force ~= true and StockPiler.DebugEnabled ~= true then
        return
    end
    local text = "buy| " .. tostring(msg)
    if StockPiler._EmitLog and StockPiler._LogText then
        StockPiler._EmitLog("StockPiler| " .. StockPiler._LogText(text))
    elseif type(d) == "function" then
        d("StockPiler| " .. text)
    end
end

local function ToNarrow(text)
    if StockPiler.ToNarrow then
        return StockPiler.ToNarrow(text)
    end
    return tostring(text or "")
end

local function LogBuyJobLines(jobs, force)
    jobs = type(jobs) == "table" and jobs or {}
    for i = 1, math.min(#jobs, 20) do
        local job = jobs[i]
        if type(job) == "table" then
            EmitBuyTrace(string.format(
                "  job #%d kind=%s specKey=%s have=%d need=%d deficit=%d seedUid=%s name=%s",
                i,
                tostring(job.kind or "buy"),
                tostring(job.specKey or "?"),
                tonumber(job.have) or 0,
                tonumber(job.need) or 0,
                tonumber(job.deficit) or 0,
                tostring(tonumber(job.seedUid) or 0),
                ToNarrow(job.label or job.name or "?")
            ), force)
        end
    end
    if #jobs > 20 then
        EmitBuyTrace("  ... +" .. tostring(#jobs - 20) .. " more jobs", force)
    end
end

local function GetSettings()
    if StockPiler.EnsureSettings then
        return StockPiler.EnsureSettings()
    end
    return StockPiler.Settings
end

local function ClampInt(n, lo, hi, default)
    n = tonumber(n)
    if n == nil then
        return default
    end
    n = math.floor(n)
    if n < lo then
        return lo
    end
    if n > hi then
        return hi
    end
    return n
end

function StockPiler.Buy.ClampReserveGold(n)
    return ClampInt(n, RESERVE_MIN, RESERVE_MAX, DEFAULT_RESERVE)
end

function StockPiler.Buy.ClampBudgetGold(n)
    return ClampInt(n, BUDGET_MIN, BUDGET_MAX, DEFAULT_BUDGET)
end

function StockPiler.Buy.GetReserveGold()
    local s = GetSettings()
    return StockPiler.Buy.ClampReserveGold(s and s.autoBuyReserveGold)
end

function StockPiler.Buy.GetBudgetGold()
    local s = GetSettings()
    return StockPiler.Buy.ClampBudgetGold(s and s.autoBuyBudgetGold)
end

--- Write the same table we just mutated. Do not call EnsureSettings here:
--- BindActiveCharacterSettings would copy the old character bucket back over
--- autoBuyEnabled / reserve / budget before Persist sees the new values.
local function PersistSettings(s)
    if type(s) ~= "table" then
        s = StockPiler.Settings
    end
    if type(s) == "table" and StockPiler.PersistActiveCharacterSettings then
        StockPiler.PersistActiveCharacterSettings(s)
    end
end

function StockPiler.Buy.AdjustReserve(increase, amount)
    local s = GetSettings()
    if type(s) ~= "table" then
        return DEFAULT_RESERVE
    end
    local cur = StockPiler.Buy.ClampReserveGold(s.autoBuyReserveGold)
    amount = tonumber(amount) or 1
    if amount < 1 then
        amount = 1
    end
    if increase then
        cur = cur + amount
    else
        cur = cur - amount
    end
    s.autoBuyReserveGold = StockPiler.Buy.ClampReserveGold(cur)
    PersistSettings(s)
    if StockPiler.LogOp then
        StockPiler.LogOp("settings", "AutoBuy reserveGold=" .. tostring(s.autoBuyReserveGold))
    end
    return s.autoBuyReserveGold
end

function StockPiler.Buy.AdjustBudget(increase, amount)
    local s = GetSettings()
    if type(s) ~= "table" then
        return DEFAULT_BUDGET
    end
    local cur = StockPiler.Buy.ClampBudgetGold(s.autoBuyBudgetGold)
    amount = tonumber(amount) or 1
    if amount < 1 then
        amount = 1
    end
    if increase then
        cur = cur + amount
    else
        cur = cur - amount
    end
    s.autoBuyBudgetGold = StockPiler.Buy.ClampBudgetGold(cur)
    PersistSettings(s)
    if StockPiler.LogOp then
        StockPiler.LogOp("settings", "AutoBuy budgetGold=" .. tostring(s.autoBuyBudgetGold))
    end
    return s.autoBuyBudgetGold
end

function StockPiler.Buy.IsEnabled()
    local s = GetSettings()
    return type(s) == "table" and s.autoBuyEnabled == true
end

function StockPiler.Buy.SetEnabled(enabled)
    local s = GetSettings()
    if type(s) ~= "table" then
        return false
    end
    enabled = enabled == true
    local changed = s.autoBuyEnabled ~= enabled
    s.autoBuyEnabled = enabled
    PersistSettings(s)
    if changed then
        if StockPiler.LogOp then
            StockPiler.LogOp("settings", "AutoBuy enabled=" .. tostring(enabled))
        end
        if enabled then
            StockPiler.Buy.InvalidateJobsCache()
            if StockPiler.PrintMaterialsToBuy then
                StockPiler.PrintMaterialsToBuy(StockPiler.Buy.CollectBuyJobs())
            end
        elseif StockPiler.NotifyManual then
            StockPiler.NotifyManual(L"AutoBuy", L"Off.")
        end
    end
    return enabled
end

local function StoreIsShowing()
    if type(DoesWindowExist) ~= "function" or type(WindowGetShowing) ~= "function" then
        return false
    end
    if not DoesWindowExist(STORE_WIN) then
        return false
    end
    return WindowGetShowing(STORE_WIN) == true
end

local function IsBuybackView()
    local store = EA_Window_InteractionStore
    if type(store) ~= "table" then
        return false
    end
    return store.displayData ~= nil and store.displayData == store.buyBackData
end

local function HasAltCurrency(item)
    local alt = item and item.altCurrency
    if type(alt) ~= "table" then
        return false
    end
    if #alt > 0 then
        return true
    end
    for _ in pairs(alt) do
        return true
    end
    return false
end

local function PlayerMoneyBrass()
    if type(Player) ~= "table" or type(Player.GetMoney) ~= "function" then
        return 0
    end
    local ok, value = StockPiler.TryCallQuiet("Player.GetMoney", Player.GetMoney)
    if not ok then
        return 0
    end
    return tonumber(value) or 0
end

local function ItemUnitCost(item)
    return tonumber(item and item.cost) or 0
end

local function PlayerCanUseStoreItem(item)
    if type(DataUtils) ~= "table" or type(DataUtils.PlayerCanUseItem) ~= "function" then
        return true
    end
    local ok, canUse = StockPiler.TryCallQuiet("DataUtils.PlayerCanUseItem", DataUtils.PlayerCanUseItem, item)
    if not ok then
        return false
    end
    return canUse == true
end

local function IsGrowablePlantItem(item)
    if type(item) ~= "table" then
        return false
    end
    if StockPiler.Inventory
        and StockPiler.Inventory.IsSeedOrSporeItem
        and StockPiler.Inventory.IsSeedOrSporeItem(item)
    then
        return false
    end
    local MS = StockPiler.MaterialSpec
    if not (MS and MS.FromItemDataCached and MS.IsGrowable) then
        return false
    end
    local spec = MS.FromItemDataCached(item, nil)
    return type(spec) == "table" and MS.IsGrowable(spec) == true
end

local function IsHarvestByproductItem(item)
    local MS = StockPiler.MaterialSpec
    if not (MS and MS.FromItemDataCached) then
        return false
    end
    if not (StockPiler.SeedMap and StockPiler.SeedMap.IsHarvestByproduct) then
        return false
    end
    local spec = MS.FromItemDataCached(item, nil)
    return type(spec) == "table" and StockPiler.SeedMap.IsHarvestByproduct(spec) == true
end

local function StoreRows()
    local store = EA_Window_InteractionStore
    if type(store) ~= "table" then
        return nil
    end
    if store.displayData ~= nil and store.displayData == store.buyBackData then
        return nil
    end
    local list = store.displayData
    if type(list) ~= "table" then
        list = store.storedata
    end
    if type(list) ~= "table" and type(GetStoreData) == "function" then
        local ok, data = StockPiler.TryCallQuiet("GetStoreData", GetStoreData)
        if ok then
            list = data
        end
    end
    if type(list) ~= "table" then
        return nil
    end
    return list
end

--- True when brewing / bag settle / harvest would race AutoBuy bag accounting.
local function BuyBlockedReason()
    if StockPiler.BagWorkPending and StockPiler.BagWorkPending() then
        return "bag-work"
    end
    if StockPiler.Brew and StockPiler.Brew.IsBusy and StockPiler.Brew.IsBusy() then
        return "brew-busy"
    end
    if StockPiler.AutoGrow and StockPiler.AutoGrow.IsHarvestCycleBusy
        and StockPiler.AutoGrow.IsHarvestCycleBusy()
    then
        return "harvest-busy"
    end
    if StockPiler.AutoGrow and StockPiler.AutoGrow.HasPlantInProgress
        and StockPiler.AutoGrow.HasPlantInProgress()
    then
        return "plant-busy"
    end
    return nil
end

function StockPiler.Buy.InvalidateJobsCache()
    StockPiler.Buy._jobsCache = nil
    StockPiler.Buy._jobsSnapGen = nil
end

function StockPiler.Buy.DumpBuyPlan(opts)
    opts = type(opts) == "table" and opts or {}
    local force = opts.force == true
    local snapDone = StockPiler.Inventory and StockPiler.Inventory._snapshotDone == true
    local snapGen = StockPiler.Inventory and tonumber(StockPiler.Inventory._snapshotGen) or 0
    if force and StockPiler.Inventory and StockPiler.Inventory.RefreshAllIfNeeded then
        StockPiler.Inventory.RefreshAllIfNeeded()
        snapDone = StockPiler.Inventory._snapshotDone == true
        snapGen = tonumber(StockPiler.Inventory._snapshotGen) or snapGen
    end
    StockPiler.Buy.InvalidateJobsCache()
    local jobs = StockPiler.Buy.CollectBuyJobs()
    EmitBuyTrace("=== buy plan ===", force)
    EmitBuyTrace(string.format(
        "enabled=%s reserveGold=%d budgetGold=%d snapshotDone=%s snapGen=%d",
        tostring(StockPiler.Buy.IsEnabled()),
        StockPiler.Buy.GetReserveGold(),
        StockPiler.Buy.GetBudgetGold(),
        tostring(snapDone),
        snapGen
    ), force)
    EmitBuyTrace("--- jobs (" .. tostring(#jobs) .. ") ---", force)
    if not snapDone then
        EmitBuyTrace("  (snapshot not ready — job list may be empty)", force)
    elseif #jobs == 0 then
        EmitBuyTrace("  (no vendor buy jobs)", force)
    else
        LogBuyJobLines(jobs, force)
    end
    EmitBuyTrace("=== end buy plan ===", force)
end

function StockPiler.Buy.CollectBuyJobs()
    local snapGen = StockPiler.Inventory and tonumber(StockPiler.Inventory._snapshotGen) or 0
    if type(StockPiler.Buy._jobsCache) == "table"
        and StockPiler.Buy._jobsSnapGen == snapGen
    then
        return StockPiler.Buy._jobsCache
    end
    local jobs = {}
    if StockPiler.Planner and StockPiler.Planner.CollectVendorBuyJobs then
        jobs = StockPiler.Planner.CollectVendorBuyJobs() or {}
    end
    StockPiler.Buy._jobsCache = jobs
    StockPiler.Buy._jobsSnapGen = snapGen
    return jobs
end

local function ItemMatchesJob(item, job)
    if type(item) ~= "table" or type(job) ~= "table" then
        return false
    end
    if job.kind == "seed" then
        local seedUid = tonumber(job.seedUid) or 0
        local itemUid = tonumber(item.uniqueID) or tonumber(item.id) or 0
        return seedUid > 0 and itemUid == seedUid
    end
    -- Never buy growable plants or refine byproducts from vendors.
    if IsGrowablePlantItem(item) or IsHarvestByproductItem(item) then
        return false
    end
    if type(job.spec) ~= "table" or not (StockPiler.MaterialSpec and StockPiler.MaterialSpec.Matches) then
        return false
    end
    return StockPiler.MaterialSpec.Matches(item, job.spec) == true
end

function StockPiler.Buy.FindStoreMatch(job)
    local list = StoreRows()
    if type(list) ~= "table" or type(job) ~= "table" then
        return nil
    end
    for _, item in ipairs(list) do
        if type(item) == "table"
            and tonumber(item.slotNum)
            and item.canbuy ~= false
            and not HasAltCurrency(item)
            and ItemUnitCost(item) > 0
            and PlayerCanUseStoreItem(item)
            and ItemMatchesJob(item, job)
        then
            return item, ItemUnitCost(item)
        end
    end
    for _, item in pairs(list) do
        if type(item) == "table"
            and tonumber(item.slotNum)
            and item.canbuy ~= false
            and not HasAltCurrency(item)
            and ItemUnitCost(item) > 0
            and PlayerCanUseStoreItem(item)
            and ItemMatchesJob(item, job)
        then
            return item, ItemUnitCost(item)
        end
    end
    return nil
end

local function ChatVisitStop(reason)
    local buy = StockPiler.Buy
    if buy._visitChatted == true then
        return
    end
    buy._visitChatted = true
    if reason ~= "nothing" then
        buy._visitStopReason = reason
    end
    local bought = tonumber(buy._visitBought) or 0
    local spent = tonumber(buy._visitSpentBrass) or 0
    local noMatch = 0
    if type(buy._visitNoMatchKeys) == "table" then
        for _ in pairs(buy._visitNoMatchKeys) do
            noMatch = noMatch + 1
        end
    end
    local stopMsg = string.format(
        "stop reason=%s bought=%d spentBrass=%d",
        tostring(reason),
        bought,
        spent
    )
    if reason == "nothing" and noMatch > 0 then
        stopMsg = stopMsg .. " noMatch=" .. tostring(noMatch)
    end
    LogBuyOp(stopMsg)
    if not StockPiler.StatusMessagesVerbose() then
        return
    end
    local msg
    if reason == "reserved" then
        if bought > 0 then
            msg = L"Stopped at reserve (bought " .. towstring(tostring(bought)) .. L")."
        else
            msg = L"Stopped at reserve."
        end
    elseif reason == "budget" then
        if bought > 0 then
            msg = L"Stopped at visit budget (bought " .. towstring(tostring(bought)) .. L")."
        else
            msg = L"Stopped at visit budget."
        end
    elseif reason == "cap" then
        msg = L"Stopped at purchase cap (bought " .. towstring(tostring(bought)) .. L")."
    elseif reason == "nothing" then
        if bought > 0 then
            return
        end
        msg = L"Nothing to buy in this store."
    else
        if bought > 0 then
            msg = L"Bought " .. towstring(tostring(bought)) .. L" this visit."
        else
            return
        end
    end
    StockPiler.NotifyFeature(L"AutoBuy", msg)
end

local function ResetVisit()
    StockPiler.Buy._visitSpentBrass = 0
    StockPiler.Buy._visitBought = 0
    StockPiler.Buy._visitPurchases = 0
    StockPiler.Buy._visitStopReason = nil
    StockPiler.Buy._visitChatted = false
    StockPiler.Buy._visitSawMatch = false
    StockPiler.Buy._visitHadJobs = false
    StockPiler.Buy._visitAcquiredByKey = {}
    StockPiler.Buy._visitNoMatchKeys = {}
    StockPiler.Buy._visitSkipLogged = {}
    StockPiler.Buy._visitSnapshotSkipLogged = false
    StockPiler.Buy._visitBuybackSkipLogged = false
    StockPiler.Buy._visitMoneyBrass = PlayerMoneyBrass()
    StockPiler.Buy.InvalidateJobsCache()
end

local function LogVisitSkipOnce(key, msg)
    local logged = StockPiler.Buy._visitSkipLogged
    if type(logged) ~= "table" then
        logged = {}
        StockPiler.Buy._visitSkipLogged = logged
    end
    if logged[key] == true then
        return
    end
    logged[key] = true
    LogBuyOp("skip " .. msg)
end

local function JobAcquireKey(job, item)
    if type(job) ~= "table" then
        return nil
    end
    if job.kind == "seed" then
        local uid = tonumber(job.seedUid) or 0
        if uid > 0 then
            return "seed:" .. tostring(uid)
        end
    end
    local key = job.specKey
    if type(key) == "string" and key ~= "" then
        return key
    end
    -- Fallback so VisitAcquired cannot stay 0 forever (rebuy loop).
    local uid = tonumber(item and (item.uniqueID or item.id)) or 0
    if uid > 0 then
        return "uid:" .. tostring(uid)
    end
    local name = ToNarrow(job.name or job.label or "")
    if name ~= "" then
        return "name:" .. name
    end
    return nil
end

local function VisitAcquired(key)
    if key == nil then
        return 0
    end
    local map = StockPiler.Buy._visitAcquiredByKey
    if type(map) ~= "table" then
        return 0
    end
    return tonumber(map[key]) or 0
end

local function NoteVisitAcquired(key, qty)
    qty = tonumber(qty) or 0
    if key == nil or qty <= 0 then
        return
    end
    local map = StockPiler.Buy._visitAcquiredByKey
    if type(map) ~= "table" then
        map = {}
        StockPiler.Buy._visitAcquiredByKey = map
    end
    map[key] = VisitAcquired(key) + qty
end

local function VisitMoneyBrass()
    local live = PlayerMoneyBrass()
    local tracked = tonumber(StockPiler.Buy._visitMoneyBrass)
    if tracked == nil then
        StockPiler.Buy._visitMoneyBrass = live
        return live
    end
    -- Prefer the lower figure so delayed Player.GetMoney cannot breach reserve.
    if live > 0 and live < tracked then
        StockPiler.Buy._visitMoneyBrass = live
        return live
    end
    return tracked
end

function StockPiler.Buy.OnStoreUpdated()
    local showing = StoreIsShowing()
    if showing and StockPiler.Buy._visitStoreOpen ~= true then
        StockPiler.Buy._visitStoreOpen = true
        ResetVisit()
        local jobs = StockPiler.Buy.IsEnabled() and StockPiler.Buy.CollectBuyJobs() or {}
        LogBuyOp(string.format(
            "visit-start enabled=%s jobs=%d money=%d reserveGold=%d budgetGold=%d",
            tostring(StockPiler.Buy.IsEnabled()),
            type(jobs) == "table" and #jobs or 0,
            tonumber(StockPiler.Buy._visitMoneyBrass) or 0,
            StockPiler.Buy.GetReserveGold(),
            StockPiler.Buy.GetBudgetGold()
        ))
        if StockPiler.Buy.IsEnabled() and type(jobs) == "table" and #jobs > 0 then
            LogBuyJobLines(jobs, false)
        end
    elseif not showing and StockPiler.Buy._visitStoreOpen == true then
        StockPiler.Buy._visitStoreOpen = false
        if (tonumber(StockPiler.Buy._visitBought) or 0) > 0 then
            ChatVisitStop("bought")
        elseif StockPiler.Buy._visitHadJobs == true and StockPiler.Buy._visitSawMatch ~= true then
            ChatVisitStop("nothing")
        else
            LogBuyOp(string.format(
                "visit-end bought=%d spentBrass=%d",
                tonumber(StockPiler.Buy._visitBought) or 0,
                tonumber(StockPiler.Buy._visitSpentBrass) or 0
            ))
        end
        StockPiler.Buy.InvalidateJobsCache()
    end
end

local function AfterPurchaseRefresh()
    StockPiler.Buy.InvalidateJobsCache()
    if StockPiler.RecipeSpec and StockPiler.RecipeSpec.ClearCountCaches then
        StockPiler.RecipeSpec.ClearCountCaches()
    end
    if StockPiler.Inventory and StockPiler.Inventory.InvalidateSnapshot then
        StockPiler.Inventory.InvalidateSnapshot()
    end
    if StockPiler.Inventory and StockPiler.Inventory.RefreshAll then
        StockPiler.Inventory.RefreshAll(true)
    end
end

function StockPiler.Buy.TryBuyNext()
    if StockPiler.Buy._visitStopReason ~= nil then
        return false
    end
    if not StockPiler.Buy.IsEnabled() then
        return false
    end
    if not StoreIsShowing() then
        return false
    end
    if IsBuybackView() then
        if StockPiler.Buy._visitBuybackSkipLogged ~= true then
            StockPiler.Buy._visitBuybackSkipLogged = true
            LogBuyOp("skip buyback-view")
        end
        return false
    end
    local busy = BuyBlockedReason()
    if busy ~= nil then
        if StockPiler.Buy._lastBusyLog ~= busy then
            StockPiler.Buy._lastBusyLog = busy
            LogBuyOp("wait " .. busy)
        end
        return false
    end
    StockPiler.Buy._lastBusyLog = nil

    local purchases = tonumber(StockPiler.Buy._visitPurchases) or 0
    if purchases >= MAX_PURCHASES_PER_VISIT then
        ChatVisitStop("cap")
        return false
    end

    local store = EA_Window_InteractionStore
    if type(store) ~= "table" or type(store.BuyItem) ~= "function" then
        return false
    end

    local jobs = StockPiler.Buy.CollectBuyJobs()
    if type(jobs) ~= "table" or #jobs == 0 then
        if StockPiler.Inventory and StockPiler.Inventory._snapshotDone ~= true then
            if StockPiler.Buy._visitSnapshotSkipLogged ~= true then
                StockPiler.Buy._visitSnapshotSkipLogged = true
                LogBuyOp("skip snapshot-not-ready")
            end
        end
        if (tonumber(StockPiler.Buy._visitBought) or 0) > 0 then
            ChatVisitStop("bought")
        end
        return false
    end
    StockPiler.Buy._visitHadJobs = true

    local money = VisitMoneyBrass()
    local liveMoney = PlayerMoneyBrass()
    if liveMoney > 0 and liveMoney < money then
        money = liveMoney
        StockPiler.Buy._visitMoneyBrass = liveMoney
    end
    local reserve = StockPiler.Buy.GetReserveGold() * BRASS_PER_GOLD
    local budget = StockPiler.Buy.GetBudgetGold() * BRASS_PER_GOLD
    local spent = tonumber(StockPiler.Buy._visitSpentBrass) or 0
    local reserveBlock = false
    local budgetBlock = false

    for i = 1, #jobs do
        local job = jobs[i]
        local item, cost = StockPiler.Buy.FindStoreMatch(job)
        local acquireKey = JobAcquireKey(job, item)
        local bagDeficit = tonumber(job.deficit) or 0
        local remaining = math.max(0, bagDeficit - VisitAcquired(acquireKey))
        if remaining < 1 then
            if acquireKey ~= nil then
                LogVisitSkipOnce(
                    "acquired:" .. tostring(acquireKey),
                    string.format(
                        "acquired key=%s acquired=%d deficit=%d",
                        tostring(acquireKey),
                        VisitAcquired(acquireKey),
                        bagDeficit
                    )
                )
            end
        elseif type(item) ~= "table" and bagDeficit > 0 then
            local jobKey = tostring(job.specKey or job.kind or i)
            if type(StockPiler.Buy._visitNoMatchKeys) ~= "table" then
                StockPiler.Buy._visitNoMatchKeys = {}
            end
            StockPiler.Buy._visitNoMatchKeys[jobKey] = true
            LogVisitSkipOnce(
                "nomatch:" .. jobKey,
                string.format(
                    "no-match job=%s kind=%s deficit=%d",
                    ToNarrow(job.name or job.label or jobKey),
                    tostring(job.kind or "buy"),
                    bagDeficit
                )
            )
        elseif type(item) == "table" and (tonumber(cost) or 0) > 0 then
            StockPiler.Buy._visitSawMatch = true
            -- Same cap as ItemStackingWindow for merchant buy-N (stackCount <= 1).
            local vendorMax = 100
            local stackCount = tonumber(item.stackCount) or 1
            if stackCount > 1 then
                vendorMax = stackCount
            end
            local maxByReserve = math.floor((money - reserve) / cost)
            local maxByBudget = math.floor((budget - spent) / cost)
            local qty = math.min(remaining, vendorMax, maxByReserve, maxByBudget)
            if qty < 1 then
                if maxByReserve < 1 then
                    reserveBlock = true
                elseif maxByBudget < 1 then
                    budgetBlock = true
                end
            else
                local costTotal = cost * qty
                -- Final live check: never spend into the reserve.
                if money - costTotal < reserve then
                    reserveBlock = true
                else
                    local slotNum = tonumber(item.slotNum)
                    if slotNum == nil then
                        LogBuyOp("skip no-slotNum job=" .. ToNarrow(job.name or job.kind))
                        return false
                    end
                    if acquireKey == nil then
                        LogBuyOp("skip no-acquireKey job=" .. ToNarrow(job.name or job.kind))
                        return false
                    end
                    -- ConfirmThenBuyItem is UI-only (WARN_BUY dialog). Never call it.
                    -- BuyItem sets NumItems = buyCount (one vendor purchase of N).
                    local ok = StockPiler.TryCall(
                        "StockPiler.Buy.BuyItem",
                        store.BuyItem,
                        item,
                        qty
                    )
                    if not ok then
                        LogBuyOp(string.format(
                            "fail BuyItem slot=%d qty=%d job=%s",
                            slotNum,
                            qty,
                            ToNarrow(job.name or job.kind)
                        ))
                        return false
                    end
                    StockPiler.Buy._visitSpentBrass = spent + costTotal
                    StockPiler.Buy._visitBought = (tonumber(StockPiler.Buy._visitBought) or 0) + qty
                    StockPiler.Buy._visitPurchases = purchases + 1
                    StockPiler.Buy._visitMoneyBrass = math.max(0, money - costTotal)
                    NoteVisitAcquired(acquireKey, qty)
                    AfterPurchaseRefresh()
                    LogBuyOp(string.format(
                        "purchase slot=%d qty=%d cost=%d kind=%s name=%s remainingWas=%d acquired=%d spent=%d budget=%d moneyLeft=%d",
                        slotNum,
                        qty,
                        costTotal,
                        tostring(job.kind or "buy"),
                        ToNarrow(item.name or job.name or ""),
                        remaining,
                        VisitAcquired(acquireKey),
                        tonumber(StockPiler.Buy._visitSpentBrass) or 0,
                        budget,
                        tonumber(StockPiler.Buy._visitMoneyBrass) or 0
                    ))
                    if StockPiler.ScheduleBagWork then
                        StockPiler.ScheduleBagWork(false)
                    end
                    return true
                end
            end
        end
    end

    -- Empty listing this tick is not a visit stop: store pages arrive over time.
    if reserveBlock then
        ChatVisitStop("reserved")
    elseif budgetBlock then
        ChatVisitStop("budget")
    end
    return false
end

function StockPiler.Buy.OnTick()
    StockPiler.Buy.OnStoreUpdated()
    if StoreIsShowing() and StockPiler.Buy.IsEnabled() then
        StockPiler.Buy.TryBuyNext()
    end
end
