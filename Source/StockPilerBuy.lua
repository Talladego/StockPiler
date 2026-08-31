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

local function D(msg)
    if StockPiler and StockPiler.D then
        StockPiler.D(msg)
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

function StockPiler.Buy.AdjustReserve(increase)
    local s = GetSettings()
    if type(s) ~= "table" then
        return DEFAULT_RESERVE
    end
    local cur = StockPiler.Buy.ClampReserveGold(s.autoBuyReserveGold)
    if increase then
        cur = cur + 1
    else
        cur = cur - 1
    end
    s.autoBuyReserveGold = StockPiler.Buy.ClampReserveGold(cur)
    PersistSettings(s)
    return s.autoBuyReserveGold
end

function StockPiler.Buy.AdjustBudget(increase)
    local s = GetSettings()
    if type(s) ~= "table" then
        return DEFAULT_BUDGET
    end
    local cur = StockPiler.Buy.ClampBudgetGold(s.autoBuyBudgetGold)
    if increase then
        cur = cur + 1
    else
        cur = cur - 1
    end
    s.autoBuyBudgetGold = StockPiler.Buy.ClampBudgetGold(cur)
    PersistSettings(s)
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
        if enabled then
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

function StockPiler.Buy.CollectBuyJobs()
    if StockPiler.Planner and StockPiler.Planner.CollectVendorBuyJobs then
        return StockPiler.Planner.CollectVendorBuyJobs()
    end
    return {}
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
    if not StockPiler.StatusMessagesVerbose() then
        return
    end
    local bought = tonumber(buy._visitBought) or 0
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
    StockPiler.Buy._visitStopReason = nil
    StockPiler.Buy._visitChatted = false
    StockPiler.Buy._visitSawMatch = false
    StockPiler.Buy._visitHadJobs = false
end

function StockPiler.Buy.OnStoreUpdated()
    local showing = StoreIsShowing()
    if showing and StockPiler.Buy._visitStoreOpen ~= true then
        StockPiler.Buy._visitStoreOpen = true
        ResetVisit()
        D("AutoBuy visit started")
    elseif not showing and StockPiler.Buy._visitStoreOpen == true then
        StockPiler.Buy._visitStoreOpen = false
        if (tonumber(StockPiler.Buy._visitBought) or 0) > 0 then
            ChatVisitStop("bought")
        elseif StockPiler.Buy._visitHadJobs == true and StockPiler.Buy._visitSawMatch ~= true then
            ChatVisitStop("nothing")
        end
    end
end

function StockPiler.Buy.TryBuyNext()
    if StockPiler.Buy._visitStopReason ~= nil then
        return false
    end
    if not StockPiler.Buy.IsEnabled() then
        return false
    end
    if not StoreIsShowing() or IsBuybackView() then
        return false
    end
    local store = EA_Window_InteractionStore
    if type(store) ~= "table" or type(store.BuyItem) ~= "function" then
        return false
    end

    local jobs = StockPiler.Buy.CollectBuyJobs()
    if type(jobs) ~= "table" or #jobs == 0 then
        if (tonumber(StockPiler.Buy._visitBought) or 0) > 0 then
            ChatVisitStop("bought")
        end
        return false
    end
    StockPiler.Buy._visitHadJobs = true

    local money = PlayerMoneyBrass()
    local reserve = StockPiler.Buy.GetReserveGold() * BRASS_PER_GOLD
    local budget = StockPiler.Buy.GetBudgetGold() * BRASS_PER_GOLD
    local spent = tonumber(StockPiler.Buy._visitSpentBrass) or 0
    local sawMatch = false
    local reserveBlock = false
    local budgetBlock = false

    for i = 1, #jobs do
        local job = jobs[i]
        local item, cost = StockPiler.Buy.FindStoreMatch(job)
        if type(item) == "table" and (tonumber(cost) or 0) > 0 then
            sawMatch = true
            StockPiler.Buy._visitSawMatch = true
            local deficit = tonumber(job.deficit) or 1
            if deficit < 1 then
                deficit = 1
            end
            -- Same cap as ItemStackingWindow for merchant buy-N (stackCount <= 1).
            local vendorMax = 100
            local stackCount = tonumber(item.stackCount) or 1
            if stackCount > 1 then
                vendorMax = stackCount
            end
            local maxByReserve = math.floor((money - reserve) / cost)
            local maxByBudget = math.floor((budget - spent) / cost)
            local qty = math.min(deficit, vendorMax, maxByReserve, maxByBudget)
            if qty < 1 then
                if maxByReserve < 1 then
                    reserveBlock = true
                else
                    budgetBlock = true
                end
            else
                local slotNum = tonumber(item.slotNum)
                if slotNum == nil then
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
                    return false
                end
                StockPiler.Buy._visitSpentBrass = spent + (cost * qty)
                StockPiler.Buy._visitBought = (tonumber(StockPiler.Buy._visitBought) or 0) + qty
                D("AutoBuy purchased slot=" .. tostring(slotNum)
                    .. " qty=" .. tostring(qty)
                    .. " cost=" .. tostring(cost * qty)
                    .. " job=" .. tostring(job.kind)
                    .. " name=" .. tostring(job.name or ""))
                if StockPiler.ScheduleBagWork then
                    StockPiler.ScheduleBagWork(false)
                end
                return true
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
