----------------------------------------------------------------
-- StockPiler Adapters/VendorAdapter - NPC store + AutoBuy match index
----------------------------------------------------------------

StockPiler = StockPiler or {}
StockPiler.VendorAdapter = StockPiler.VendorAdapter or {}
local VA = StockPiler.VendorAdapter

local STORE_WIN = "EA_Window_InteractionStore"
VA._storeHooked = false
VA._matchIndex = nil
VA._matchIndexGen = 0
VA._storeRefreshDue = false

local function TryQuiet(context, fn, ...)
    return StockPiler.Util.TryCallQuiet(context, fn, ...)
end

local function TryCall(context, fn, ...)
    return StockPiler.Util.TryCall(context, fn, ...)
end

--- Persist new store rows only (Touch once per new uid batch - no per-page spam).
--- Only Cultivation / Apothecary craft mats - never mounts, dyes, junk.
local function ApothecarySkillId()
    local Caps = StockPiler.TradeSkillCaps
    if Caps and Caps.ApothecaryId then
        return Caps.ApothecaryId()
    end
    return 4
end

local function CultivationSkillId()
    local Caps = StockPiler.TradeSkillCaps
    if Caps and Caps.CultivationId then
        return Caps.CultivationId()
    end
    return 3
end

local function CraftingFamilyBonus(item)
    if type(item) ~= "table" then
        return 0
    end
    local bonuses = item.craftingBonus or item.bonuses
    if type(bonuses) ~= "table" then
        return 0
    end
    for _, b in pairs(bonuses) do
        if type(b) == "table" then
            local ref = tonumber(b.bonusReference) or tonumber(b.reference) or 0
            -- CRAFTING_FAMILY / trade skill family is bonus 5 in WAR apo tooling.
            if ref == 5 then
                return tonumber(b.bonusValue) or tonumber(b.value) or 0
            end
        end
    end
    if bonuses[5] ~= nil then
        return tonumber(bonuses[5]) or 0
    end
    return 0
end

local function IsCraftRelevantVendorItem(item)
    if type(item) ~= "table" then
        return false
    end
    local cult = tonumber(item.cultivationType) or 0
    if cult ~= 0 then
        return true
    end
    local apo = ApothecarySkillId()
    local cultSkill = CultivationSkillId()
    local ts = tonumber(item.tradeSkill) or 0
    if ts == apo or ts == cultSkill then
        return true
    end
    local family = CraftingFamilyBonus(item)
    if family == apo or family == cultSkill then
        return true
    end
    local uid = tonumber(item.uniqueID) or tonumber(item.id) or 0
    if uid > 0 and StockPiler.Items and StockPiler.Items.GetByUid then
        local row = StockPiler.Items.GetByUid(uid)
        if type(row) == "table" then
            if (tonumber(row.cultivationType) or 0) ~= 0 then
                return true
            end
            local rts = tonumber(row.tradeSkill) or 0
            if rts == apo or rts == cultSkill then
                return true
            end
        end
    end
    local MS = StockPiler.MaterialSpec
    if MS and MS.FromItemData then
        local ok, spec = pcall(MS.FromItemData, item)
        if ok == true and type(spec) == "table" then
            if (tonumber(spec.cultivationType) or 0) ~= 0 then
                return true
            end
            local sts = tonumber(spec.tradeSkill) or 0
            if sts == apo or sts == cultSkill then
                return true
            end
        end
    end
    return false
end

local function LearnVendorRows(list)
    if type(list) ~= "table" then
        return 0
    end
    local Know = StockPiler.Knowledge
    local vendorItems = Know and Know.VendorItems and Know.VendorItems()
    if type(vendorItems) ~= "table" then
        return 0
    end
    local added = 0
    local function consider(item)
        if type(item) ~= "table" then
            return
        end
        local uid = tonumber(item.uniqueID) or tonumber(item.id) or 0
        if uid <= 0 then
            return
        end
        if not IsCraftRelevantVendorItem(item) then
            return
        end
        -- Seed Items DB so fingerprint Matches can enrich thin store rows (flasks).
        if StockPiler.Items and StockPiler.Items.StoreItem then
            StockPiler.Items.StoreItem(item, "vendor")
        end
        local key = tostring(uid)
        local cost = tonumber(item.cost) or tonumber(item.price) or tonumber(item.sellPrice) or 0
        if cost < 0 then
            cost = 0
        end
        local existing = vendorItems[key]
        if type(existing) == "table" then
            -- Refresh cost/name on revisit so tip/queue use current prices.
            if cost > 0 and (tonumber(existing.cost) or 0) ~= cost then
                existing.cost = cost
                added = added + 1
            end
            if item.name ~= nil and (existing.name == nil or existing.name == L"" or existing.name == "") then
                existing.name = item.name
            end
            if (tonumber(item.iconNum) or 0) > 0 then
                existing.iconNum = tonumber(item.iconNum) or existing.iconNum
            end
        else
            vendorItems[key] = {
                uniqueID = uid,
                name = item.name,
                iconNum = tonumber(item.iconNum) or 0,
                cost = cost,
                cultivationType = tonumber(item.cultivationType) or 0,
                tradeSkill = tonumber(item.tradeSkill) or CraftingFamilyBonus(item) or 0,
            }
            added = added + 1
        end
        if cost > 0 and StockPiler.Knowledge and StockPiler.Knowledge.RememberVendorCost then
            StockPiler.Knowledge.RememberVendorCost(uid, cost)
        end
    end
    local n = 0
    for _, item in ipairs(list) do
        consider(item)
        n = n + 1
    end
    if n == 0 then
        for _, item in pairs(list) do
            consider(item)
        end
    end
    if added > 0 and Know.Touch then
        Know.Touch("vendor")
    end
    return added
end

local function NotifyStoreUpdated()
    VA.InvalidateMatchIndex()
    local index = VA.RefreshMatchIndex()
    local list = VA.GetStoreItems()
    LearnVendorRows(list)
    local B = StockPiler.EventBus
    local E = StockPiler.Events
    if B and E and E.VENDOR_UPDATED then
        B.Fire(E.VENDOR_UPDATED, { gen = VA._matchIndexGen, refreshLists = true })
    end
    if StockPiler.Scheduler and StockPiler.Scheduler.WakeAutoBuy then
        StockPiler.Scheduler.WakeAutoBuy()
    end
    return index
end

--- Coalesce ShowStore / UpdateStoreList storms into one refresh (Scheduler / Poll).
function VA.RequestStoreRefresh()
    VA._storeRefreshDue = true
end

function VA.FlushPendingStoreRefresh()
    if VA._storeRefreshDue ~= true then
        return false
    end
    VA._storeRefreshDue = false
    NotifyStoreUpdated()
    return true
end

function VA.IsStoreOpen()
    if type(DoesWindowExist) ~= "function" or type(WindowGetShowing) ~= "function" then
        return false
    end
    if not DoesWindowExist(STORE_WIN) then
        return false
    end
    return WindowGetShowing(STORE_WIN) == true
end

-- Service windows that are not named EA_Window_Interaction*.
local SERVICE_WINDOWS = {
    BankWindow = true,
    GuildVaultWindow = true,
    MailWindow = true,
    AuctionWindow = true,
    BarberWindow = true,
    EA_Window_EquipmentUpgrade = true,
    EA_Window_GuildVault = true,
    EA_Window_Mail = true,
    EA_Window_Auction = true,
    EA_Window_Barber = true,
    EA_Window_Bank = true,
}

-- Showing-poll when openWindowList is empty/desynced. Never includes the merchant
-- store (AutoBuy needs that window open; refine uses IsStoreOpen separately).
local FALLBACK_INTERACTION_WINDOWS = {
    "EA_Window_InteractionBase",
    "EA_Window_InteractionQuest",
    "EA_Window_InteractionHealer",
    "EA_Window_InteractionTraining",
    "EA_Window_InteractionCoreTraining",
    "EA_Window_InteractionSpecialtyTraining",
    "EA_Window_InteractionTomeTraining",
    "EA_Window_InteractionRenownTraining",
    "EA_Window_InteractionCareerMaster",
    "EA_Window_InteractionGuild",
    "EA_Window_InteractionKeepUpgrades",
    "EA_Window_InteractionInfluenceRewards",
    "EA_Window_InteractionEventRewards",
    "EA_Window_InteractionAltar",
    "EA_Window_InteractionLastName",
    "EA_Window_InteractionHeraldry",
    "EA_Window_InteractionLibrarianStore",
    "EA_InteractionFlightMasterWindow",
    "InteractionWindowGuildCreateForm",
    "InteractionWindowGuildRename",
    "BankWindow",
    "GuildVaultWindow",
    "MailWindow",
    "AuctionWindow",
    "BarberWindow",
    "EA_Window_EquipmentUpgrade",
    "EA_Window_GuildVault",
    "EA_Window_Mail",
    "EA_Window_Auction",
    "EA_Window_Barber",
    "EA_Window_Bank",
}

local function WindowEntryName(entry)
    if type(entry) == "string" and entry ~= "" then
        return entry
    end
    if type(entry) == "table" then
        if type(entry.name) == "string" and entry.name ~= "" then
            return entry.name
        end
        if type(entry.windowName) == "string" and entry.windowName ~= "" then
            return entry.windowName
        end
    end
    return nil
end

local function IsDyeMerchantCharacter()
    local cw = CharacterWindow
    if type(cw) ~= "table" then
        return false
    end
    local modeConst = cw.MODE_DYE_MERCHANT
    if modeConst ~= nil and cw.mode == modeConst then
        return true
    end
    if modeConst == nil and tonumber(cw.mode) == 3 then
        return true
    end
    return false
end

local function IsNonStoreInteractionName(name)
    if type(name) ~= "string" or name == "" or name == STORE_WIN then
        return false
    end
    if name == "CharacterWindow" then
        return IsDyeMerchantCharacter()
    end
    if SERVICE_WINDOWS[name] == true then
        return true
    end
    -- EA_Window_Interaction* except the merchant store (handled by IsStoreOpen).
    if name:sub(1, 21) == "EA_Window_Interaction" then
        return true
    end
    -- EA_InteractionFlightMasterWindow and other EA_Interaction* dialogs.
    if name:sub(1, 14) == "EA_Interaction" then
        return true
    end
    -- Guild create / rename (InteractionWindowGuildCreateForm, ...).
    if name:sub(1, 17) == "InteractionWindow" then
        return true
    end
    return false
end

--- Listed openWindowList entry still blocks unless it is known to exist and is
--- already hidden (same-frame hide). A stale list name with DoesWindowExist
--- false still counts as open until OnHidden removes it.
local function ListedWindowCountsAsOpen(name)
    local existsFn = type(DoesWindowExist) == "function"
    local showingFn = type(WindowGetShowing) == "function"
    if existsFn and DoesWindowExist(name) == true and showingFn and WindowGetShowing(name) == false then
        return false
    end
    if not existsFn and showingFn and WindowGetShowing(name) == false then
        return false
    end
    return true
end

local function ShowingTrue(name)
    -- DoesWindowExist first: WindowGetShowing on a never-created name errors in client.
    if type(DoesWindowExist) == "function" and DoesWindowExist(name) ~= true then
        return false
    end
    if type(WindowGetShowing) ~= "function" or WindowGetShowing(name) ~= true then
        return false
    end
    return true
end

local function FallbackShowingOpen()
    for i = 1, #FALLBACK_INTERACTION_WINDOWS do
        if ShowingTrue(FALLBACK_INTERACTION_WINDOWS[i]) then
            return true
        end
    end
    if IsDyeMerchantCharacter() and ShowingTrue("CharacterWindow") then
        return true
    end
    return false
end

local function OpenListHasBlockingWindow(list)
    if #list > 0 then
        for i = 1, #list do
            local name = WindowEntryName(list[i])
            if name and IsNonStoreInteractionName(name) and ListedWindowCountsAsOpen(name) then
                return true
            end
        end
        return false
    end
    for key, value in pairs(list) do
        local name = nil
        if type(key) == "string" and key ~= "" and (value == true or type(value) == "table") then
            name = WindowEntryName(value) or key
        else
            name = WindowEntryName(value)
        end
        if name and IsNonStoreInteractionName(name) and ListedWindowCountsAsOpen(name) then
            return true
        end
    end
    return false
end

--- Quest, trainer, flight master, bank, and other NPC windows.
--- Prefer openWindowList; also poll known windows so an empty/desynced list
--- cannot miss EA_Window_InteractionBase (SendUseItem closes those).
function VA.IsNonStoreInteractionOpen()
    local utils = WindowUtils
    local list = type(utils) == "table" and utils.openWindowList or nil
    if type(list) == "table" and OpenListHasBlockingWindow(list) == true then
        return true
    end
    return FallbackShowingOpen() == true
end

--- opts.includeStore also treats the merchant store as an interaction.
function VA.IsInteractionOpen(opts)
    if type(opts) == "table" and opts.includeStore == true and VA.IsStoreOpen() == true then
        return true
    end
    return VA.IsNonStoreInteractionOpen() == true
end

function VA.IsBuybackView()
    local store = EA_Window_InteractionStore
    if type(store) ~= "table" then
        return false
    end
    return store.displayData ~= nil and store.displayData == store.buyBackData
end

--- Visible store listing (not buyback). Pages arrive over time.
function VA.GetStoreItems()
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
        local ok, data = TryQuiet("GetStoreData", GetStoreData)
        if ok then
            list = data
        end
    end
    if type(list) ~= "table" then
        return nil
    end
    return list
end

function VA.GetPlayerMoneyBrass()
    if type(Player) ~= "table" or type(Player.GetMoney) ~= "function" then
        return 0
    end
    local ok, value = TryQuiet("Player.GetMoney", Player.GetMoney)
    if not ok then
        return 0
    end
    return tonumber(value) or 0
end

function VA.BuyItem(itemData, buyCount)
    buyCount = tonumber(buyCount) or 0
    if type(itemData) ~= "table" or buyCount < 1 then
        return false, "invalid-args"
    end
    if VA.IsBuybackView() == true then
        return false, "buyback"
    end
    local store = EA_Window_InteractionStore
    if type(store) ~= "table" or type(store.BuyItem) ~= "function" then
        return false, "no-api"
    end
    local ok, err = TryCall("VendorAdapter.BuyItem", store.BuyItem, itemData, buyCount)
    if not ok then
        return false, err or "pcall-failed"
    end
    return true
end

function VA.InvalidateMatchIndex()
    VA._matchIndex = nil
end

--- Rebuild AutoBuy match index from current store page (uid -> row).
function VA.RefreshMatchIndex()
    local list = VA.GetStoreItems()
    local index = {
        byUid = {},
        rows = {},
    }
    if type(list) ~= "table" then
        VA._matchIndex = index
        VA._matchIndexGen = (tonumber(VA._matchIndexGen) or 0) + 1
        return index
    end

    local function addRow(item)
        if type(item) ~= "table" then
            return
        end
        local uid = tonumber(item.uniqueID) or tonumber(item.id) or 0
        local slotNum = tonumber(item.slotNum)
        if slotNum == nil and uid <= 0 then
            return
        end
        local cost = tonumber(item.cost) or 0
        local row = {
            item = item,
            uid = uid,
            cost = cost,
            slotNum = slotNum,
            canbuy = item.canbuy ~= false,
        }
        index.rows[#index.rows + 1] = row
        if uid > 0 then
            local bucket = index.byUid[uid]
            if type(bucket) ~= "table" then
                bucket = {}
                index.byUid[uid] = bucket
            end
            bucket[#bucket + 1] = row
        end
    end

    local n = 0
    for _, item in ipairs(list) do
        addRow(item)
        n = n + 1
    end
    if n == 0 then
        for _, item in pairs(list) do
            addRow(item)
        end
    end

    VA._matchIndex = index
    VA._matchIndexGen = (tonumber(VA._matchIndexGen) or 0) + 1
    return index
end

function VA.GetMatchIndex()
    if type(VA._matchIndex) ~= "table" then
        return VA.RefreshMatchIndex()
    end
    return VA._matchIndex
end

function VA.FindStoreRowsByUid(uid)
    uid = tonumber(uid) or 0
    if uid <= 0 then
        return nil
    end
    local index = VA.GetMatchIndex()
    if type(index) ~= "table" or type(index.byUid) ~= "table" then
        return nil
    end
    return index.byUid[uid]
end

function VA.OnStoreShow()
    VA.EnsureStoreHook()
    -- Immediate refresh on show; page updates coalesce via RequestStoreRefresh.
    NotifyStoreUpdated()
end

--- Wrap store UI updates so late pages refresh AutoBuy match index (coalesced).
function VA.EnsureStoreHook()
    if VA._storeHooked == true then
        return true
    end
    local store = EA_Window_InteractionStore
    if type(store) ~= "table" then
        return false
    end
    local function afterStoreUi()
        VA.RequestStoreRefresh()
        if StockPiler.Scheduler and StockPiler.Scheduler.WakeAutoBuy then
            StockPiler.Scheduler.WakeAutoBuy()
        end
    end
    if type(store.ShowStore) == "function" and store._spShowStoreWrapped ~= true then
        local orig = store.ShowStore
        store.ShowStore = function(...)
            local a, b, c = orig(...)
            TryCall("VendorAdapter.ShowStore", afterStoreUi)
            return a, b, c
        end
        store._spShowStoreWrapped = true
    end
    if type(store.UpdateStoreList) == "function" and store._spUpdateStoreWrapped ~= true then
        local orig = store.UpdateStoreList
        store.UpdateStoreList = function(...)
            local a, b, c = orig(...)
            TryCall("VendorAdapter.UpdateStoreList", afterStoreUi)
            return a, b, c
        end
        store._spUpdateStoreWrapped = true
    end
    if type(store.UpdateBuyBackList) == "function" and store._spUpdateBuyBackWrapped ~= true then
        local orig = store.UpdateBuyBackList
        store.UpdateBuyBackList = function(...)
            local a, b, c = orig(...)
            TryCall("VendorAdapter.UpdateBuyBackList", afterStoreUi)
            return a, b, c
        end
        store._spUpdateBuyBackWrapped = true
    end
    VA._storeHooked = true
    return true
end
