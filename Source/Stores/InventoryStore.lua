----------------------------------------------------------------
-- StockPiler Stores/InventoryStore - L0 counts + Flatten snapshot
----------------------------------------------------------------

StockPiler = StockPiler or {}
StockPiler.Inventory = StockPiler.Inventory or {}
local Inv = StockPiler.Inventory

Inv._snapGen = 0
Inv._ready = false
Inv._countByUid = {}
Inv._slotIndex = { main = {}, craft = {} }
Inv._itemBySlot = { main = {}, craft = {} }
Inv._sampleByUid = {}
-- MaterialSpec parse cache: cleared on snap bump.
Inv._specParseCache = {}
Inv._dirty = false
Inv._dirtyFull = false
Inv._needQueue = false
Inv._snapPending = false
Inv._snapPendingReason = nil

function Inv.IsSnapshotPending()
    return Inv._snapPending == true
end
Inv._pendingUidDelta = nil
Inv._lastNetUidDelta = nil
Inv._dirtyEngine = false

local function Bus()
    return StockPiler.EventBus
end

local function Events()
    return StockPiler.Events
end

local function SetSample(uid, item)
    uid = tonumber(uid) or 0
    if uid <= 0 then
        return
    end
    if type(item) == "table" then
        Inv._sampleByUid[uid] = item
    end
end

local function ClearSampleIfUnused(uid)
    uid = tonumber(uid) or 0
    if uid <= 0 then
        return
    end
    if (tonumber(Inv._countByUid[uid]) or 0) <= 0 then
        Inv._sampleByUid[uid] = nil
    end
end

local function BumpGenImmediate(reason, opts)
    opts = type(opts) == "table" and opts or {}
    Inv._snapGen = (tonumber(Inv._snapGen) or 0) + 1
    Inv._snapPending = false
    Inv._snapPendingReason = nil
    Inv._pendingUidDelta = nil
    if opts.keepLastNetDelta ~= true then
        Inv._lastNetUidDelta = nil
    end
    Inv._specParseCache = {}
    if StockPiler.BagAdapter and StockPiler.BagAdapter.InvalidateCache then
        StockPiler.BagAdapter.InvalidateCache()
    end
    local E = Events()
    local B = Bus()
    if B and E and E.INVENTORY_SNAPSHOT then
        B.Fire(E.INVENTORY_SNAPSHOT, { snapGen = Inv._snapGen, reason = reason })
    end
end

local function BumpGenDeferred(reason)
    Inv._snapPending = true
    if Inv._snapPendingReason == nil then
        Inv._snapPendingReason = reason
    end
end

local function RebuildFromBags(forceRefresh)
    local BA = StockPiler.BagAdapter
    if not BA then
        return false
    end
    local bags = forceRefresh and BA.FetchForce() or BA.FetchLight()
    local counts = {}
    local slotIndex = { main = {}, craft = {} }
    local itemBySlot = { main = {}, craft = {} }
    local sampleByUid = {}
    for i = 1, #bags do
        local entry = bags[i]
        BA.IterateSlots(entry, function(bagType, slot, item)
            local uid, qty = BA.SlotQty(item)
            if uid > 0 and qty > 0 then
                counts[uid] = (counts[uid] or 0) + qty
                local bagSlots = slotIndex[bagType]
                if type(bagSlots) ~= "table" then
                    bagSlots = {}
                    slotIndex[bagType] = bagSlots
                end
                bagSlots[slot] = { uid = uid, qty = qty }
                local items = itemBySlot[bagType]
                if type(items) ~= "table" then
                    items = {}
                    itemBySlot[bagType] = items
                end
                items[slot] = item
                if sampleByUid[uid] == nil then
                    sampleByUid[uid] = item
                end
            end
        end)
    end
    Inv._countByUid = counts
    Inv._slotIndex = slotIndex
    Inv._itemBySlot = itemBySlot
    Inv._sampleByUid = sampleByUid
    Inv._specParseCache = {}
    Inv._ready = true
    Inv._dirty = false
    Inv._dirtyFull = false
    BumpGenImmediate(forceRefresh and "L3-full" or "L2-light")
    return true
end

--- Publish one snapGen for all L0 AdjustUid since last flush.
--- Zero-net rearrange/swap skips snapGen + INVENTORY_SNAPSHOT.
function Inv.FlushPendingSnapGen()
    if Inv._snapPending ~= true then
        return false
    end
    local pend = Inv._pendingUidDelta
    Inv._pendingUidDelta = nil
    if type(pend) == "table" then
        local net = {}
        local anyNet = false
        for uid, d in pairs(pend) do
            uid = tonumber(uid) or 0
            d = tonumber(d) or 0
            if uid > 0 and d ~= 0 then
                net[uid] = d
                anyNet = true
            end
        end
        if not anyNet then
            Inv._snapPending = false
            Inv._snapPendingReason = nil
            Inv._lastNetUidDelta = nil
            return false
        end
        Inv._lastNetUidDelta = net
        BumpGenImmediate(Inv._snapPendingReason or "L0-batch", { keepLastNetDelta = true })
        return true
    end
    Inv._lastNetUidDelta = nil
    BumpGenImmediate(Inv._snapPendingReason or "L0-batch")
    return true
end

--- Net uid deltas from the last L0 snap flush (nil = unknown / full rebuild).
function Inv.GetLastNetUidDelta()
    return Inv._lastNetUidDelta
end

function Inv.GetSnapGen()
    return tonumber(Inv._snapGen) or 0
end

function Inv.IsReady()
    return Inv._ready == true
end

function Inv.CountByUid(uid)
    uid = tonumber(uid) or 0
    if uid <= 0 or Inv._ready ~= true then
        return 0
    end
    return tonumber(Inv._countByUid[uid]) or 0
end

function Inv.AdjustUid(uid, delta, reason)
    uid = tonumber(uid) or 0
    delta = tonumber(delta) or 0
    if uid <= 0 or delta == 0 or Inv._ready ~= true then
        return false
    end
    local nextCount = (tonumber(Inv._countByUid[uid]) or 0) + delta
    if nextCount < 0 then
        nextCount = 0
        -- Underflow means the slot index and the bag disagree. Queue a full
        -- flush; setting the flag alone left it until some later MarkDirty (PLN-9).
        Inv.MarkDirty({ full = true, reason = reason or "underflow" })
    end
    if nextCount == 0 then
        Inv._countByUid[uid] = nil
        Inv._sampleByUid[uid] = nil
    else
        Inv._countByUid[uid] = nextCount
    end
    local pend = Inv._pendingUidDelta
    if type(pend) ~= "table" then
        pend = {}
        Inv._pendingUidDelta = pend
    end
    pend[uid] = (tonumber(pend[uid]) or 0) + delta
    BumpGenDeferred(reason or "adjust")
    return true
end

function Inv.MarkDirty(opts)
    opts = type(opts) == "table" and opts or {}
    Inv._dirty = true
    if opts.full == true then
        Inv._dirtyFull = true
    end
    if opts.needQueue == true then
        Inv._needQueue = true
    end
    local E = Events()
    local B = Bus()
    if B and E and E.INVENTORY_DIRTY then
        B.Fire(E.INVENTORY_DIRTY, {
            reason = tostring(opts.reason or "unknown"),
            needQueue = Inv._needQueue == true,
        })
    end
    if StockPiler.Scheduler and StockPiler.Scheduler.EnqueueBagFlush then
        StockPiler.Scheduler.EnqueueBagFlush(opts.needQueue == true)
    end
end

function Inv.OnSlotUpdated(bagType, slot, bagTable)
    bagType = tostring(bagType or "main")
    slot = tonumber(slot) or 0
    if slot <= 0 then
        Inv.MarkDirty({ reason = "slot-unknown", full = true })
        return false
    end
    if Inv._ready ~= true or Inv._dirtyFull == true then
        Inv.MarkDirty({ reason = "slot-not-ready" })
        return false
    end
    local BA = StockPiler.BagAdapter
    if not BA then
        Inv.MarkDirty({ reason = "no-adapter", full = true })
        return false
    end
    local bagSlots = Inv._slotIndex[bagType]
    if type(bagSlots) ~= "table" then
        bagSlots = {}
        Inv._slotIndex[bagType] = bagSlots
    end
    local itemSlots = Inv._itemBySlot[bagType]
    if type(itemSlots) ~= "table" then
        itemSlots = {}
        Inv._itemBySlot[bagType] = itemSlots
    end
    local old = bagSlots[slot]
    if type(old) ~= "table" then
        old = { uid = 0, qty = 0 }
    end
    local newUid, newQty, item
    if type(bagTable) == "table" and BA.ApplySlot then
        newUid, newQty, item = BA.ApplySlot(bagType, slot, bagTable)
    elseif type(bagTable) == "table" and BA.ReadSlotFromTable then
        newUid, newQty, item = BA.ReadSlotFromTable(bagTable, slot)
    else
        newUid, newQty, item = BA.ReadSlot(bagType, slot)
    end
    newUid = tonumber(newUid) or 0
    newQty = tonumber(newQty) or 0
    if old.uid == newUid then
        local delta = newQty - (tonumber(old.qty) or 0)
        if delta ~= 0 then
            Inv.AdjustUid(newUid, delta, "L0-slot")
        end
    else
        if (tonumber(old.uid) or 0) > 0 then
            Inv.AdjustUid(old.uid, -(tonumber(old.qty) or 0), "L0-slot-clear")
            ClearSampleIfUnused(old.uid)
        end
        if newUid > 0 then
            Inv.AdjustUid(newUid, newQty, "L0-slot-set")
        end
    end
    if newUid > 0 and newQty > 0 then
        bagSlots[slot] = { uid = newUid, qty = newQty }
        itemSlots[slot] = item
        SetSample(newUid, item)
    else
        bagSlots[slot] = nil
        itemSlots[slot] = nil
    end
    -- Leave Inv._dirty. Clearing it here dropped a rebuild that a different
    -- slot or caller had already requested (PLN-8).
    return true
end

function Inv.ForceFullRefresh(opts)
    opts = type(opts) == "table" and opts or {}
    Inv._dirtyFull = true
    if opts.forceEngine == true then
        Inv._dirtyEngine = true
    end
    Inv.MarkDirty({
        full = true,
        reason = opts.reason or "force",
        needQueue = opts.needQueue == true,
    })
end

function Inv.ApplySlotUpdates(bagType, updatedSlots, reason)
    bagType = tostring(bagType or "main")
    reason = tostring(reason or "slot-updates")
    if type(updatedSlots) ~= "table" then
        Inv.MarkDirty({ reason = reason .. "-noslots", full = true })
        return false
    end
    local slots = {}
    local n = 0
    for i, v in ipairs(updatedSlots) do
        local slot = tonumber(v) or 0
        if slot > 0 then
            n = n + 1
            slots[n] = slot
        end
    end
    if n == 0 then
        for k, v in pairs(updatedSlots) do
            local slot = tonumber(k)
            if slot == nil or slot <= 0 then
                slot = tonumber(v) or 0
            end
            if slot > 0 then
                n = n + 1
                slots[n] = slot
            end
        end
    end
    if n == 0 then
        Inv.MarkDirty({ reason = reason .. "-empty", full = true })
        return false
    end
    local BA = StockPiler.BagAdapter
    -- Force engine reread: slot events are coalesced to UPDATE_PROCESSED, and a
    -- stale DataUtils table makes put-back look empty (no L0-slot-set / no snap).
    local bagTable = nil
    if BA and BA.FetchBag then
        local entry = BA.FetchBag(bagType, true)
        if type(entry) == "table" then
            bagTable = entry.data
        end
    elseif BA and BA.GetBagTable then
        if GameData and GameData.Player then
            if bagType == "craft" then
                GameData.Player.craftingItemsDirty = true
            else
                GameData.Player.itemsDirty = true
            end
        end
        bagTable = BA.GetBagTable(bagType)
    end
    if type(bagTable) ~= "table" and Inv._ready == true then
        Inv.MarkDirty({ reason = reason .. "-nobag" })
        return false
    end
    local pendingBefore = Inv._snapPending == true
    for i = 1, n do
        if Inv.OnSlotUpdated(bagType, slots[i], bagTable) ~= true then
            return false
        end
    end
    -- Engine said slots changed but L0 saw no net delta (stale empty read on
    -- restore). Flatten from engine so Watch craftable can follow.
    if Inv._ready == true and pendingBefore ~= true and Inv._snapPending ~= true then
        Inv.ForceFullRefresh({
            forceEngine = true,
            needQueue = true,
            reason = reason .. "-stale",
        })
    end
    return true
end

function Inv.Flush(opts)
    opts = type(opts) == "table" and opts or {}
    local forceEngine = opts.forceEngine == true or Inv._dirtyEngine == true
    Inv._dirtyEngine = false
    local force = opts.force == true or Inv._dirtyFull == true or Inv._ready ~= true or forceEngine
    if force then
        RebuildFromBags(forceEngine)
    elseif Inv._dirty == true then
        RebuildFromBags(false)
    end
    local needQueue = Inv._needQueue == true
    Inv._needQueue = false
    return needQueue
end

function Inv.RefreshAllIfNeeded(opts)
    opts = type(opts) == "table" and opts or {}
    if opts.force == true or Inv._ready ~= true or Inv._dirtyFull == true then
        Inv.Flush({ force = true, forceEngine = opts.force == true })
        return true
    end
    if Inv._dirty == true then
        if StockPiler.Scheduler and StockPiler.Scheduler.EnqueueBagFlush then
            StockPiler.Scheduler.EnqueueBagFlush(false)
        else
            Inv.Flush({ force = false })
        end
        return true
    end
    return false
end

function Inv.GetSample(uid)
    uid = tonumber(uid) or 0
    if uid <= 0 then
        return nil
    end
    local sample = Inv._sampleByUid[uid]
    if type(sample) == "table" then
        return sample
    end
    if Inv._ready == true and (tonumber(Inv._countByUid[uid]) or 0) <= 0 then
        return nil
    end
    if type(Inv._itemBySlot) == "table" then
        for _, slots in pairs(Inv._itemBySlot) do
            if type(slots) == "table" then
                for _, item in pairs(slots) do
                    if type(item) == "table" and (tonumber(item.uniqueID) or 0) == uid then
                        Inv._sampleByUid[uid] = item
                        return item
                    end
                end
            end
        end
    end
    return nil
end

--- fn(item [, bagKey, slot]). Extra args are optional (Lua ignores unused params).
function Inv.ForEachItem(fn)
    if type(fn) ~= "function" then
        return
    end
    if Inv._ready ~= true then
        Inv.Flush({ force = true, forceEngine = false })
    end
    if Inv._ready == true and type(Inv._itemBySlot) == "table" then
        for bagKey, slots in pairs(Inv._itemBySlot) do
            if type(slots) == "table" then
                for slot, item in pairs(slots) do
                    if type(item) == "table" then
                        fn(item, bagKey, tonumber(slot) or 0)
                    end
                end
            end
        end
        return
    end
    local BA = StockPiler.BagAdapter
    if not BA then
        return
    end
    local bags = BA.FetchLight()
    for i = 1, #bags do
        local bag = bags[i]
        local defaultKey = type(bag) == "table" and tostring(bag.bagType or bag.bagKey or "craft") or "craft"
        BA.IterateSlots(bag, function(bagType, slot, item)
            if type(item) == "table" then
                fn(item, tostring(bagType or defaultKey), tonumber(slot) or 0)
            end
        end)
    end
end

function Inv.CanUseCraftingItem(item)
    if type(item) ~= "table" then
        return false
    end
    -- DataUtils indexes CultivationWindow / CraftingSystem; skip until those mods exist.
    if DataUtils and type(DataUtils.PlayerTradeSkillLevelIsEnoughForItem) == "function"
        and CultivationWindow ~= nil and CraftingSystem ~= nil
    then
        local ok, enough
        if StockPiler.Debug and StockPiler.Debug.TryCallQuiet then
            ok, enough = StockPiler.Debug.TryCallQuiet(
                "DataUtils.PlayerTradeSkillLevelIsEnoughForItem",
                DataUtils.PlayerTradeSkillLevelIsEnoughForItem,
                item
            )
        else
            ok, enough = pcall(DataUtils.PlayerTradeSkillLevelIsEnoughForItem, item)
        end
        if ok then
            return enough == true
        end
    end
    local req = tonumber(item.craftingSkillRequirement) or 0
    if req <= 0 then
        return true
    end
    local cultType = tonumber(item.cultivationType) or 0
    local Caps = StockPiler.TradeSkillCaps
    local level = 0
    if cultType ~= 0 then
        level = Caps and Caps.GetCultSkill and Caps.GetCultSkill() or 0
    else
        level = Caps and Caps.GetApoSkill and Caps.GetApoSkill() or 0
    end
    return level >= req
end

function Inv.IsDirty()
    return Inv._dirty == true or Inv._dirtyFull == true
end

--- CreateItemTooltip assumes bag-shaped fields; pad thin shells (DB/learned) so stock UI does not nil-index.
local function TooltipWString(value)
    if type(value) == "wstring" then
        return value
    end
    if value == nil or type(towstring) ~= "function" then
        return L""
    end
    return towstring(tostring(value))
end

function Inv.NormalizeItemDataForTooltip(itemData)
    if type(itemData) ~= "table" then
        return nil
    end
    local data = {}
    for k, v in pairs(itemData) do
        data[k] = v
    end
    if data.timeLeftBeforeDecay == nil then
        data.timeLeftBeforeDecay = 0
    end
    if data.equipSlot == nil then
        data.equipSlot = 0
    end
    local stacks = tonumber(data.stackCount) or 0
    if stacks < 1 then
        data.stackCount = 1
    end
    if type(data.bonus) ~= "table" then
        data.bonus = {}
    end
    if type(data.flags) ~= "table" then
        data.flags = {}
    end
    if type(data.craftingBonus) ~= "table" then
        data.craftingBonus = {}
    end
    -- SetReqsWithLookup ipairses these; thin DB/learned shells often omit them.
    if type(data.careers) ~= "table" then
        data.careers = {}
    end
    if type(data.races) ~= "table" then
        data.races = {}
    end
    if type(data.slots) ~= "table" then
        data.slots = {}
    end
    if type(data.skills) ~= "table" then
        data.skills = {}
    end
    if data.broken == nil then
        data.broken = false
    end
    if data.sellPrice == nil then
        data.sellPrice = 0
    end
    if data.repairPrice == nil then
        data.repairPrice = 0
    end
    if data.armor == nil then
        data.armor = 0
    end
    if data.dps == nil then
        data.dps = 0
    end
    if data.speed == nil then
        data.speed = 0
    end
    if data.blockRating == nil then
        data.blockRating = 0
    end
    if data.maxEquip == nil then
        data.maxEquip = 0
    end
    if tonumber(data.iLevel) == nil then
        data.iLevel = 0
    end
    -- Character rank requirement for LABEL_MINIMUM_RANK_X. Never invent from iLevel
    -- (crafting mats use iLevel/skillReq = 200; bag tooltips keep level=0).
    if tonumber(data.level) == nil then
        data.level = 0
    end
    -- Undo prior EnrichFromLearned that copied skill/iLevel into level (false red Rank).
    local csr = tonumber(data.craftingSkillRequirement) or 0
    local il = tonumber(data.iLevel) or 0
    local lv = tonumber(data.level) or 0
    if csr > 0 and lv > 0 and (lv == il or lv == csr) then
        data.level = 0
    end
    if tonumber(data.renown) == nil then
        data.renown = 0
    end
    if tonumber(data.itemSet) == nil then
        data.itemSet = 0
    end
    if data.name == nil or type(data.name) ~= "wstring" then
        data.name = TooltipWString(data.name)
    end
    -- LabelSetText(ItemTooltipDescription, ...) rejects nil and narrow strings.
    -- Learned rows keep the text in descriptionNarrow.
    if data.description == nil or type(data.description) ~= "wstring" then
        data.description = TooltipWString(data.description ~= nil and data.description or data.descriptionNarrow)
    end
    if data.iconNum == nil then
        data.iconNum = 0
    end
    if data.type == nil then
        data.type = tonumber(data.itemType) or 0
    end
    if data.craftingSkillRequirement == nil then
        data.craftingSkillRequirement = 0
    end
    if data.rarity == nil then
        data.rarity = 0
    end
    if data.dyeTintA == nil then
        data.dyeTintA = 0
    end
    if data.dyeTintB == nil then
        data.dyeTintB = 0
    end
    if data.tintA == nil then
        data.tintA = 0
    end
    if data.tintB == nil then
        data.tintB = 0
    end
    if data.isTwoHanded == nil then
        data.isTwoHanded = false
    end
    if data.numEnhancementSlots == nil then
        data.numEnhancementSlots = 0
    end
    if type(data.enhSlot) ~= "table" then
        data.enhSlot = {}
    end
    -- Engine: `customizedIconNum ~= 0` is true when the field is nil; then
    -- AppearanceName gets customizedIconName (also nil) and LabelSetText errors.
    if tonumber(data.customizedIconNum) == nil then
        data.customizedIconNum = 0
    end
    if data.customizedIconName == nil or type(data.customizedIconName) ~= "wstring" then
        data.customizedIconName = TooltipWString(data.customizedIconName)
    end
    return data
end

local function ItemDataHasUseBonus(itemData)
    if type(itemData) ~= "table" or type(itemData.bonus) ~= "table" then
        return false
    end
    local useType = 3
    if GameDefs and GameDefs.ITEMBONUS_USE then
        useType = GameDefs.ITEMBONUS_USE
    end
    for _, bonus in pairs(itemData.bonus) do
        if type(bonus) == "table" and tonumber(bonus.type) == useType and (tonumber(bonus.reference) or 0) > 0 then
            return true
        end
    end
    return false
end

local function PreferRicherItemData(a, b)
    if a == nil then
        return b
    end
    if b == nil then
        return a
    end
    local aUse = ItemDataHasUseBonus(a)
    local bUse = ItemDataHasUseBonus(b)
    if aUse and not bUse then
        return a
    end
    if bUse and not aUse then
        return b
    end
    local aR = tonumber(a.rarity) or 0
    local bR = tonumber(b.rarity) or 0
    if bR > aR then
        return b
    end
    return a
end

--- Overlay iLevel/rarity/skillReq/craftingBonus from Account.items when bag/DB shells omit them.
local function EnrichFromLearned(uid, item)
    if type(item) ~= "table" then
        return item
    end
    local Items = StockPiler.Items
    local learned = Items and Items.AsItemData and Items.AsItemData(uid) or nil
    if type(learned) ~= "table" then
        return item
    end
    local lvl = tonumber(item.iLevel) or 0
    local learnedLvl = tonumber(learned.iLevel) or 0
    if lvl <= 0 and learnedLvl > 0 then
        item.iLevel = learnedLvl
    end
    local req = tonumber(item.craftingSkillRequirement) or tonumber(item.skillReq) or 0
    local learnedReq = tonumber(learned.craftingSkillRequirement) or tonumber(learned.skillReq) or 0
    if req <= 0 and learnedReq > 0 then
        item.craftingSkillRequirement = learnedReq
        item.skillReq = learnedReq
        item.skillLevel = learnedReq
    end
    -- Potion Lvl column uses iLevel; do not write item.level (that is character rank
    -- for Minimum Rank on CreateItemTooltip - bag keeps level=0 on mats).
    if (tonumber(item.iLevel) or 0) <= 0 and learnedReq > 0 then
        item.iLevel = learnedReq
    end
    if (tonumber(item.rarity) or 0) <= 0 and (tonumber(learned.rarity) or 0) > 0 then
        item.rarity = learned.rarity
    end
    if (item.name == nil or item.name == L"") and learned.name ~= nil then
        item.name = learned.name
    end
    if (tonumber(item.iconNum) or 0) <= 0 and (tonumber(learned.iconNum) or 0) > 0 then
        item.iconNum = learned.iconNum
    end
    local function HasCraftBonus(data)
        if type(data) ~= "table" or type(data.craftingBonus) ~= "table" then
            return false
        end
        for _, bonus in pairs(data.craftingBonus) do
            if type(bonus) == "table" and (tonumber(bonus.bonusReference) or 0) > 0 then
                return true
            end
        end
        return false
    end
    if not HasCraftBonus(item) and HasCraftBonus(learned) then
        item.craftingBonus = learned.craftingBonus
    end
    return item
end

--- Overlay rarity/iLevel/name/icon from Account.potions when Items/bags are thin.
local function EnrichFromKnownPotion(uid, item)
    local RS = StockPiler.RecipeSpec
    local potion = nil
    if RS and RS.GetPotion then
        potion = RS.GetPotion(uid)
    end
    if type(potion) ~= "table" then
        return item
    end
    if type(item) ~= "table" then
        item = {
            uniqueID = uid,
            name = potion.name,
            iconNum = tonumber(potion.iconNum) or 0,
            rarity = tonumber(potion.rarity),
            iLevel = tonumber(potion.iLevel) or 0,
            itemSet = 0,
        }
        return item
    end
    if (tonumber(item.rarity) or 0) <= 0 and (tonumber(potion.rarity) or 0) > 0 then
        item.rarity = potion.rarity
    end
    if (tonumber(item.iLevel) or 0) <= 0 and (tonumber(potion.iLevel) or 0) > 0 then
        item.iLevel = potion.iLevel
    end
    if (item.name == nil or item.name == L"") and potion.name ~= nil then
        item.name = potion.name
    end
    if (tonumber(item.iconNum) or 0) <= 0 and (tonumber(potion.iconNum) or 0) > 0 then
        item.iconNum = potion.iconNum
    end
    if item.itemSet == nil and item.rarity ~= nil then
        item.itemSet = 0
    end
    return item
end

function Inv.ItemDataHasUseBonus(itemData)
    return ItemDataHasUseBonus(itemData)
end

--- Prefer bag/sample with Use-bonus; enrich rarity/iLevel from Items then Known Potions.
function Inv.ResolvePotionItemData(potionKey, uid, existing)
    uid = tonumber(uid) or 0
    if uid <= 0 and type(potionKey) == "string" then
        local fromKey = string.match(potionKey, "^uid:(%d+)")
        uid = tonumber(fromKey) or 0
    end
    if uid <= 0 then
        return existing
    end

    local best = type(existing) == "table" and existing or nil
    local sample = Inv.GetSample(uid)
    if type(sample) == "table" then
        best = PreferRicherItemData(best, sample)
    end
    if (not ItemDataHasUseBonus(best)) and type(GetDatabaseItemData) == "function" then
        local ok, data = pcall(GetDatabaseItemData, uid)
        if ok and type(data) == "table" then
            best = PreferRicherItemData(best, data)
        end
    end
    if type(best) ~= "table" and StockPiler.Items and StockPiler.Items.AsItemData then
        best = StockPiler.Items.AsItemData(uid)
    end
    if type(best) == "table" then
        best = EnrichFromLearned(uid, best)
        best = EnrichFromKnownPotion(uid, best)
        if (tonumber(best.uniqueID) or 0) <= 0 then
            best.uniqueID = uid
        end
    else
        best = EnrichFromKnownPotion(uid, nil)
    end
    return best or existing
end

--- Same screen-edge placement bags use (CreateItemTooltip -> ANCHOR_WINDOW_VARIABLE).
function Inv.AnchorLikeBagItemTooltip()
    if not (Tooltips and type(Tooltips.AnchorTooltip) == "function") then
        return
    end
    -- ignoreStaticPlacementOption=true matches CreateItemTooltip / backpack slots.
    Tooltips.AnchorTooltip(Tooltips.ANCHOR_WINDOW_VARIABLE, true)
end

--- Full stock item tooltip. opts.allowWithoutUse: materials/plants (no Use bonus).
--- Anchors like EA_Window_Backpack.MouseOverEquipmentSlot (CreateItemTooltip).
function Inv.ShowItemTooltip(itemData, anchorWindow, opts)
    if type(itemData) ~= "table" or type(Tooltips) ~= "table"
        or type(Tooltips.CreateItemTooltip) ~= "function"
    then
        return false
    end
    opts = type(opts) == "table" and opts or {}
    if opts.allowWithoutUse ~= true and not ItemDataHasUseBonus(itemData) then
        return false
    end
    local data = Inv.NormalizeItemDataForTooltip(itemData)
    if type(data) ~= "table" then
        return false
    end
    local win = anchorWindow or (SystemData and SystemData.ActiveWindow and SystemData.ActiveWindow.name)
    -- Same args as backpackutils: RIGHT + ENABLE_COMPARISON; CreateItemTooltip then
    -- rewrites the anchor to ANCHOR_WINDOW_VARIABLE (quadrant-aware).
    local disableComparison = Tooltips.ENABLE_COMPARISON
    if disableComparison == nil then
        disableComparison = false
    end
    local ok
    if StockPiler.Debug and StockPiler.Debug.TryCallQuiet then
        ok = StockPiler.Debug.TryCallQuiet(
            "Tooltips.CreateItemTooltip",
            Tooltips.CreateItemTooltip,
            data,
            win,
            Tooltips.ANCHOR_WINDOW_RIGHT,
            disableComparison,
            nil,
            nil,
            false
        )
    else
        ok = pcall(
            Tooltips.CreateItemTooltip,
            data,
            win,
            Tooltips.ANCHOR_WINDOW_RIGHT,
            disableComparison,
            nil,
            nil,
            false
        )
    end
    return ok == true
end
