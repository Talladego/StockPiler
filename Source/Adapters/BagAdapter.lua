----------------------------------------------------------------
-- StockPiler Adapters/BagAdapter - backpack + craft bag I/O
----------------------------------------------------------------

StockPiler = StockPiler or {}
StockPiler.BagAdapter = StockPiler.BagAdapter or {}
local BA = StockPiler.BagAdapter

local BAG_MAIN = "main"
local BAG_CRAFT = "craft"

BA._seedSlotCache = BA._seedSlotCache or {}
BA._warmMain = nil
BA._warmCraft = nil

local function TryQuiet(label, fn, ...)
    return StockPiler.Util.TryCallQuiet(label, fn, ...)
end

--- Mythic GetCraftingItems clears GameData.Player.itemsDirty (the normal
--- backpack flag) instead of craftingItemsDirty. Capture the pending flag
--- and put it back when a craft read drops it. A flag raised during the
--- call stays set; a flag that was already clear is left alone.
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

local function CallCraftingRead(label, fn, ...)
    local hadItemsDirty = CaptureItemsDirty()
    local ok, data = TryQuiet(label, fn, ...)
    RestorePendingItemsDirty(hadItemsDirty)
    return ok, data
end

local function KnownMainBackpackCapacity()
    local player = _G.GameData and _G.GameData.Player
    if type(player) ~= "table" then
        player = nil
    end
    local slots = (tonumber(player and player.numBackpackSlots)
        or tonumber(player and player.backpackSlots)
        or tonumber(player and player.maxBackpackSlots)
        or 0)
    if slots > 0 then
        return true
    end
    local bp = _G.EA_Window_Backpack
    if type(bp) == "table" and type(bp.numberOfSlots) == "table" then
        local key = bp.TYPE_INVENTORY or 1
        if (tonumber(bp.numberOfSlots[key]) or 0) > 0 then
            return true
        end
    end
    return false
end

local function ItemPresent(item)
    if type(item) ~= "table" then
        return false
    end
    local uid = tonumber(item.uniqueID) or 0
    if uid > 0 then
        return true
    end
    local n = tonumber(item.stackCount) or tonumber(item.Count) or 0
    return n > 0
end

local function ItemLabel(item)
    if type(item) ~= "table" then
        return "?"
    end
    local name = item.name
    if type(name) == "wstring" and type(WStringToString) == "function" then
        local ok, text = pcall(WStringToString, name)
        if ok and type(text) == "string" and text ~= "" then
            return text
        end
    end
    if type(name) == "string" and name ~= "" then
        return name
    end
    return "?"
end

local function NarrowField(value)
    if value == nil then
        return ""
    end
    if type(value) == "wstring" and type(WStringToString) == "function" then
        local ok, text = pcall(WStringToString, value)
        if ok and type(text) == "string" then
            return text
        end
    end
    if type(value) == "string" then
        return value
    end
    return tostring(value)
end

local function FormatBonusArray(label, list)
    if type(list) ~= "table" then
        return label .. "=nil"
    end
    local parts = {}
    for i, bonus in ipairs(list) do
        if type(bonus) == "table" then
            -- Potion Use: line uses type=ITEMBONUS_USE(3), reference=abilityId.
            -- Crafting EFFECT uses craftingBonus.bonusReference=6.
            parts[#parts + 1] = string.format(
                "[%d]{type=%s ref=%s val=%s dur=%s br=%s bv=%s}",
                i,
                tostring(bonus.type),
                tostring(bonus.reference),
                tostring(bonus.value),
                tostring(bonus.duration),
                tostring(bonus.bonusReference),
                tostring(bonus.bonusValue)
            )
        end
    end
    if #parts == 0 then
        -- Sparse / non-ipairs tables (some engine shapes).
        for k, bonus in pairs(list) do
            if type(bonus) == "table" then
                parts[#parts + 1] = string.format(
                    "[%s]{type=%s ref=%s val=%s br=%s bv=%s}",
                    tostring(k),
                    tostring(bonus.type),
                    tostring(bonus.reference),
                    tostring(bonus.value),
                    tostring(bonus.bonusReference),
                    tostring(bonus.bonusValue)
                )
            end
        end
    end
    if #parts == 0 then
        return label .. "=[]"
    end
    return label .. "={" .. table.concat(parts, ", ") .. "}"
end

local function DumpItemFields(emit, item)
    if type(emit) ~= "function" or type(item) ~= "table" then
        return
    end
    local desc = NarrowField(item.description or item.desc)
    if #desc > 120 then
        desc = string.sub(desc, 1, 117) .. "..."
    end
    emit(string.format(
        "    fields type=%s itemType=%s iLevel=%s level=%s rarity=%s skillReq=%s tradeSkill=%s cultType=%s slotType=%s equipSlot=%s",
        tostring(item.type),
        tostring(item.itemType),
        tostring(item.iLevel),
        tostring(item.level),
        tostring(item.rarity),
        tostring(item.craftingSkillRequirement or item.skillReq),
        tostring(item.tradeSkill),
        tostring(item.cultivationType),
        tostring(item.slotType),
        tostring(item.equipSlot)
    ))
    emit(string.format(
        "    flags isStackable=%s unbound=%s broken=%s currCharges=%s iconNum=%s isRefinable=%s",
        tostring(item.isStackable),
        tostring(item.unbound),
        tostring(item.broken),
        tostring(item.currChargesRemaining),
        tostring(item.iconNum),
        tostring(item.isRefinable)
    ))
    do
        local ME = StockPiler.MaterialExceptions
        local SM = StockPiler.SeedMap
        local uid = tonumber(item.uniqueID) or 0
        local special = ME and ME.LooksSpecialApoMain and ME.LooksSpecialApoMain(item) == true
        local force = ME and ME.IsForceNotRefinable and ME.IsForceNotRefinable(item) == true
        local oneWay = SM and SM.IsOneWayHarvestSpec and SM.IsOneWayHarvestSpec(item) == true
        local infertile = SM and SM.IsInfertileSeed and SM.IsInfertileSeed(uid, item.name) == true
        local eternal = SM and SM.IsEternalSeed and SM.IsEternalSeed(uid, item.name) == true
        local exceptional = SM and SM.IsExceptionalSeed and SM.IsExceptionalSeed(uid, item.name) == true
        emit(string.format(
            "    classify specialApoMain=%s forceNotRefinable=%s oneWay=%s infertileSeed=%s eternal=%s exceptional=%s",
            tostring(special),
            tostring(force),
            tostring(oneWay),
            tostring(infertile),
            tostring(eternal),
            tostring(exceptional)
        ))
    end
    if desc ~= "" then
        emit("    description=" .. desc)
    else
        emit("    description=(empty)")
    end
    -- Tooltip Use: comes from bonus[] type=3 + GetAbilityDesc(reference, iLevel).
    emit("    " .. FormatBonusArray("bonus", item.bonus))
    emit("    " .. FormatBonusArray("craftingBonus", item.craftingBonus))
    if type(GetAbilityDesc) == "function" and type(item.bonus) == "table" then
        for i, bonus in ipairs(item.bonus) do
            if type(bonus) == "table" and tonumber(bonus.type) == 3 and (tonumber(bonus.reference) or 0) > 0 then
                local ok, abilityText = pcall(GetAbilityDesc, bonus.reference, item.iLevel or 0)
                local narrow = ""
                if ok then
                    narrow = NarrowField(abilityText)
                end
                if #narrow > 160 then
                    narrow = string.sub(narrow, 1, 157) .. "..."
                end
                emit(string.format(
                    "    useAbility[%d] abilityId=%s iLevel=%s text=%s",
                    i,
                    tostring(bonus.reference),
                    tostring(item.iLevel),
                    narrow ~= "" and narrow or "(empty)"
                ))
            end
        end
    end
end

function BA.Dump(emit, opts)
    emit = type(emit) == "function" and emit or function() end
    opts = type(opts) == "table" and opts or {}
    if StockPiler.Inventory and StockPiler.Inventory.RefreshAllIfNeeded then
        StockPiler.Inventory.RefreshAllIfNeeded({ force = opts.force == true })
    end
    local bags = opts.force == true and BA.FetchForce() or BA.FetchLight()
    emit("=== StockPiler bags ===")
    emit("  note: tooltip Use: = bonus[type=3].reference -> GetAbilityDesc(abilityId, iLevel)")
    emit("  note: apo EFFECT id = craftingBonus[bonusReference=6].bonusValue (mains), not potion Use:")
    if #bags == 0 then
        emit("  (no bag data)")
        emit("=== end bags ===")
        return
    end
    for i = 1, #bags do
        local entry = bags[i]
        local bagType = tostring(entry.bagType or "?")
        local slotCount = 0
        emit("--- " .. bagType .. " bag ---")
        BA.IterateSlots(entry, function(_, slot, item)
            slotCount = slotCount + 1
            local id, qty = BA.SlotQty(item)
            emit(string.format(
                "  slot=%d uid=%d qty=%d name=%s cultType=%s",
                slot,
                id,
                qty,
                ItemLabel(item),
                tostring(item and item.cultivationType or "?")
            ))
            DumpItemFields(emit, item)
        end)
        if slotCount == 0 then
            emit("  (empty)")
        end
    end
    emit("=== end bags ===")
end

local function BackpackTypeForBagKey(bagKey)
    if bagKey == BAG_CRAFT then
        if EA_Window_Backpack and EA_Window_Backpack.TYPE_CRAFTING then
            return EA_Window_Backpack.TYPE_CRAFTING
        end
        return 4
    end
    if EA_Window_Backpack and EA_Window_Backpack.TYPE_INVENTORY then
        return EA_Window_Backpack.TYPE_INVENTORY
    end
    return 2
end

local function CanUseCraftingItem(item)
    if type(item) ~= "table" then
        return false
    end
    if StockPiler.Inventory and StockPiler.Inventory.CanUseCraftingItem then
        return StockPiler.Inventory.CanUseCraftingItem(item) == true
    end
    return true
end

function BA.InvalidateCache()
    BA._seedSlotCache = {}
    BA._warmMain = nil
    BA._warmCraft = nil
end

--- Thin DataUtils / engine wrappers. Trusts dirty gate unless forceRefresh.
--- Force path calls GetCraftingItemData / GetInventoryItemData directly.
--- Stock DataUtils.GetCraftingItems never clears craftingItemsDirty (it wrongly
--- clears itemsDirty instead). Preserve a pending itemsDirty across craft reads
--- so the next GetItems can still fill the shared backpack cache. A zero-entry
--- main cache with known backpack capacity is marked dirty and retried once
--- when that first GetItems did not already read native inventory.
--- Do NOT clear craftingItemsDirty/itemsDirty here: clearing made DataUtils
--- serve a stale table on the next slot event (after the first move).
function BA.GetBagTable(bagType, opts)
    opts = type(opts) == "table" and opts or {}
    local force = opts.force == true
    bagType = tostring(bagType or BAG_MAIN)
    if bagType == BAG_CRAFT then
        if force == true and type(GetCraftingItemData) == "function" then
            local ok, data = CallCraftingRead("BagAdapter.GetCraftingItemData.force", GetCraftingItemData)
            if ok and type(data) == "table" then
                BA._warmCraft = data
                return data
            end
        end
        if DataUtils and type(DataUtils.GetCraftingItems) == "function" then
            local ok, data = CallCraftingRead("BagAdapter.GetCraftingItems", DataUtils.GetCraftingItems)
            if ok and type(data) == "table" then
                BA._warmCraft = data
                return data
            end
        elseif type(GetCraftingItemData) == "function" then
            local ok, data = CallCraftingRead("BagAdapter.GetCraftingItemData", GetCraftingItemData)
            if ok and type(data) == "table" then
                BA._warmCraft = data
                return data
            end
        end
        return nil
    end
    if force == true and type(GetInventoryItemData) == "function" then
        local ok, data = TryQuiet("BagAdapter.GetInventoryItemData.force", GetInventoryItemData)
        if ok and type(data) == "table" then
            BA._warmMain = data
            return data
        end
    end
    if DataUtils and type(DataUtils.GetItems) == "function" then
        local player = _G.GameData and _G.GameData.Player
        local startedItemsDirty = type(player) == "table" and player.itemsDirty == true
        local ok, data = TryQuiet("BagAdapter.GetItems", DataUtils.GetItems)
        local failed = ok ~= true or type(data) ~= "table"
        local empty = ok == true and type(data) == "table" and next(data) == nil
        if (failed or empty) and KnownMainBackpackCapacity() then
            if type(_G.GameData) == "table" and type(_G.GameData.Player) == "table" then
                _G.GameData.Player.itemsDirty = true
            end
            if startedItemsDirty ~= true then
                local retryOk, retryData = TryQuiet("BagAdapter.GetItems.retry", DataUtils.GetItems)
                if retryOk == true and type(retryData) == "table" and next(retryData) ~= nil then
                    BA._warmMain = retryData
                    return retryData
                end
                if type(_G.GameData) == "table" and type(_G.GameData.Player) == "table" then
                    _G.GameData.Player.itemsDirty = true
                end
                if retryOk == true and type(retryData) == "table" then
                    BA._warmMain = retryData
                    return retryData
                end
            elseif ok == true and type(data) == "table" then
                BA._warmMain = data
                return data
            end
        elseif ok == true and type(data) == "table" then
            BA._warmMain = data
            return data
        end
    elseif type(GetInventoryItemData) == "function" then
        local ok, data = TryQuiet("BagAdapter.GetInventoryItemData", GetInventoryItemData)
        if ok and type(data) == "table" then
            BA._warmMain = data
            return data
        end
    end
    return nil
end

local function FetchBags(forceRefresh)
    local forceOpts = forceRefresh == true and { force = true } or nil
    if forceRefresh == true and GameData and GameData.Player then
        GameData.Player.itemsDirty = true
        GameData.Player.craftingItemsDirty = true
    end
    local bags = {}
    local main = BA.GetBagTable(BAG_MAIN, forceOpts)
    if type(main) == "table" then
        bags[#bags + 1] = { bagType = BAG_MAIN, data = main }
    end
    if forceRefresh == true and GameData and GameData.Player then
        GameData.Player.craftingItemsDirty = true
    end
    local craft = BA.GetBagTable(BAG_CRAFT, forceOpts)
    if type(craft) == "table" then
        bags[#bags + 1] = { bagType = BAG_CRAFT, data = craft }
    end
    return bags
end

function BA.FetchLight()
    return FetchBags(false)
end

function BA.InvalidateCraftFreeCache()
    BA._craftFreeSnap = nil
    BA._craftFreeVal = nil
    BA._craftFetchGen = (tonumber(BA._craftFetchGen) or 0) + 1
end

function BA.GetCraftFetchGen()
    return tonumber(BA._craftFetchGen) or 0
end

function BA.FetchForce()
    BA.InvalidateCraftFreeCache()
    local player = GameData and GameData.Player
    local prevItems, prevCraft
    if type(player) == "table" then
        prevItems = player.itemsDirty == true
        prevCraft = player.craftingItemsDirty == true
    end
    local bags = FetchBags(true)
    if type(player) == "table" then
        player.itemsDirty = prevItems == true
        player.craftingItemsDirty = prevCraft == true
    end
    return bags
end

function BA.FetchBag(bagType, forceRefresh)
    bagType = tostring(bagType or BAG_MAIN)
    local forceOpts = nil
    if forceRefresh == true then
        forceOpts = { force = true }
        if GameData and GameData.Player then
            if bagType == BAG_CRAFT then
                GameData.Player.craftingItemsDirty = true
            else
                GameData.Player.itemsDirty = true
            end
        end
    end
    local data = BA.GetBagTable(bagType, forceOpts)
    if type(data) == "table" then
        return { bagType = bagType == BAG_CRAFT and BAG_CRAFT or BAG_MAIN, data = data }
    end
    return nil
end

function BA.SlotQty(item)
    if type(item) ~= "table" then
        return 0, 0
    end
    local uid = tonumber(item.uniqueID) or 0
    local qty = tonumber(item.stackCount) or tonumber(item.Count) or 0
    if uid > 0 and qty <= 0 then
        qty = 1
    end
    return uid, qty
end

function BA.IterateSlots(bagEntry, fn)
    if type(bagEntry) ~= "table" or type(fn) ~= "function" then
        return
    end
    local bag = bagEntry.data
    local bagType = bagEntry.bagType or BAG_MAIN
    if type(bag) ~= "table" then
        return
    end
    local n = #bag
    if n > 0 then
        for slot = 1, n do
            local item = bag[slot]
            if ItemPresent(item) then
                fn(bagType, slot, item)
            end
        end
        return
    end
    for slot, item in pairs(bag) do
        if type(slot) == "number" and ItemPresent(item) then
            fn(bagType, slot, item)
        end
    end
end

function BA.ReadSlotFromTable(bagTable, slot)
    slot = tonumber(slot) or 0
    if slot <= 0 or type(bagTable) ~= "table" then
        return 0, 0, nil
    end
    local item = bagTable[slot]
    local uid, qty = BA.SlotQty(item)
    return uid, qty, item
end

function BA.ReadSlot(bagType, slot)
    bagType = tostring(bagType or BAG_MAIN)
    slot = tonumber(slot) or 0
    if slot <= 0 then
        return 0, 0, nil
    end
    local bag = BA.GetBagTable(bagType)
    if type(bag) == "table" then
        return BA.ReadSlotFromTable(bag, slot)
    end
    if DataUtils and type(DataUtils.GetItemData) == "function" and GameData and GameData.ItemLocs then
        local itemLoc = bagType == BAG_CRAFT and GameData.ItemLocs.CRAFTING_ITEM
            or GameData.ItemLocs.INVENTORY
        if itemLoc ~= nil then
            local ok, item
            if bagType == BAG_CRAFT then
                ok, item = CallCraftingRead("BagAdapter.GetItemData", DataUtils.GetItemData, itemLoc, slot)
            else
                ok, item = TryQuiet("BagAdapter.GetItemData", DataUtils.GetItemData, itemLoc, slot)
            end
            if ok then
                local uid, qty = BA.SlotQty(item)
                return uid, qty, item
            end
        end
    end
    return 0, 0, nil
end

--- Apply one slot read against a pre-warmed bag table (Inventory L0 path).
function BA.ApplySlot(bagType, slot, bagTable)
    bagType = tostring(bagType or BAG_MAIN)
    slot = tonumber(slot) or 0
    if slot <= 0 then
        return 0, 0, nil
    end
    if type(bagTable) == "table" then
        return BA.ReadSlotFromTable(bagTable, slot)
    end
    return BA.ReadSlot(bagType, slot)
end

--- Filled + capacity for a bag table (#bag is capacity when dense).
--- Returns nil,nil when the bag table is unavailable.
function BA.CountBagOccupancy(bagType)
    local bag = BA.GetBagTable(bagType)
    if type(bag) ~= "table" then
        return nil, nil
    end
    local capacity = #bag
    local filled = 0
    if capacity > 0 then
        for slot = 1, capacity do
            if ItemPresent(bag[slot]) then
                filled = filled + 1
            end
        end
        return filled, capacity
    end
    for slot, item in pairs(bag) do
        if type(slot) == "number" and ItemPresent(item) then
            filled = filled + 1
            if slot > capacity then
                capacity = slot
            end
        end
    end
    if capacity <= 0 then
        return nil, nil
    end
    return filled, capacity
end

--- True when every craft-bag slot is occupied (no free slot for brew/harvest).
function BA.IsCraftBagFull()
    local filled, capacity = BA.CountBagOccupancy(BAG_CRAFT)
    if filled == nil or capacity == nil or capacity <= 0 then
        return false
    end
    return filled >= capacity
end

--- Free craft-bag slots (nil if occupancy unknown).
function BA.CraftBagFreeSlots()
    local Inv = StockPiler.Inventory
    local snap = Inv and Inv.GetSnapGen and tonumber(Inv.GetSnapGen()) or 0
    local dirty = GameData and GameData.Player and GameData.Player.craftingItemsDirty == true
    if snap > 0 and dirty ~= true and BA._craftFreeSnap == snap and BA._craftFreeVal ~= nil then
        return BA._craftFreeVal
    end
    local filled, capacity = BA.CountBagOccupancy(BAG_CRAFT)
    if filled == nil or capacity == nil or capacity <= 0 then
        BA._craftFreeSnap = nil
        BA._craftFreeVal = nil
        return nil
    end
    local free = capacity - filled
    if free < 0 then
        free = 0
    end
    if snap > 0 and dirty ~= true then
        BA._craftFreeSnap = snap
        BA._craftFreeVal = free
    else
        BA._craftFreeSnap = nil
        BA._craftFreeVal = nil
    end
    return free
end

--- Default max stack for Apo vials when item.capacity is missing.
BA.DEFAULT_VIAL_STACK = 40
--- Always leave at least this many empty craft-bag slots for brew/harvest.
BA.CRAFT_BAG_KEEP_FREE = 1

--- Max units per stack from item data (item.capacity). fallback when unknown.
function BA.ItemStackCapacity(item, fallback)
    local cap = tonumber(item and item.capacity) or 0
    if cap >= 1 then
        return cap
    end
    return tonumber(fallback) or 1
end

--- How many more units of uid fit in the craft bag without using the last
--- keepFree empty slots. Uses stackCap per stack (bag capacity, else caller
--- default). Returns nil when craft-bag occupancy is unknown.
function BA.CraftBagBuyRoom(uid, stackCap, opts)
    uid = tonumber(uid) or 0
    stackCap = tonumber(stackCap) or 0
    if stackCap < 1 then
        stackCap = 1
    end
    local keepFree = tonumber(opts and opts.keepFree)
    if keepFree == nil then
        keepFree = tonumber(BA.CRAFT_BAG_KEEP_FREE) or 1
    end
    if keepFree < 0 then
        keepFree = 0
    end
    local free = BA.CraftBagFreeSlots()
    if free == nil then
        return nil
    end
    local partial = 0
    if uid > 0 then
        local bag = BA.GetBagTable(BAG_CRAFT)
        if type(bag) == "table" then
            for _, item in pairs(bag) do
                if type(item) == "table" and (tonumber(item.uniqueID) or 0) == uid then
                    local have = tonumber(item.stackCount) or tonumber(item.Count) or 0
                    local cap = BA.ItemStackCapacity(item, stackCap)
                    if have < cap then
                        partial = partial + (cap - have)
                    end
                end
            end
        end
    end
    local newSlots = free - keepFree
    if newSlots < 0 then
        newSlots = 0
    end
    return partial + (newSlots * stackCap)
end

--- Find a bag slot holding seedUid. Cached by Inventory snapGen; InvalidateCache on structure change.
function BA.FindSeedSlot(uid)
    uid = tonumber(uid) or 0
    if uid <= 0 then
        return 0, nil, BackpackTypeForBagKey(BAG_CRAFT)
    end

    local Inv = StockPiler.Inventory
    local snapGen = Inv and Inv.GetSnapGen and Inv.GetSnapGen() or 0
    local cached = BA._seedSlotCache[uid]
    if type(cached) == "table" and (tonumber(cached.snapGen) or 0) == snapGen then
        local slot = tonumber(cached.slot) or 0
        local bagKey = cached.bagKey
        local item = nil
        if slot > 0 and Inv and Inv._ready == true and type(Inv._itemBySlot) == "table"
            and type(Inv._itemBySlot[bagKey]) == "table"
        then
            item = Inv._itemBySlot[bagKey][slot]
        end
        if type(item) == "table" and (tonumber(item.uniqueID) or 0) == uid then
            local stack = tonumber(item.stackCount) or tonumber(item.StackCount) or 1
            if stack > 0 and CanUseCraftingItem(item) then
                return slot, item, BackpackTypeForBagKey(bagKey)
            end
        end
        BA._seedSlotCache[uid] = nil
    end

    local bestSlot = 0
    local bestItem = nil
    local bestBagKey = nil
    local bestStack = 10000

    local function consider(bagKey, slot, item)
        if type(item) ~= "table" then
            return
        end
        if (tonumber(item.uniqueID) or 0) ~= uid then
            return
        end
        if not CanUseCraftingItem(item) then
            return
        end
        local stack = tonumber(item.stackCount) or tonumber(item.StackCount) or 1
        if stack > 0 and stack < bestStack then
            bestSlot = slot
            bestStack = stack
            bestItem = item
            bestBagKey = bagKey
        end
    end

    if Inv and Inv._ready == true and type(Inv._itemBySlot) == "table" then
        for bagKey, slots in pairs(Inv._itemBySlot) do
            if type(slots) == "table" then
                for slot, item in pairs(slots) do
                    consider(bagKey, tonumber(slot) or 0, item)
                end
            end
        end
    else
        local bags = BA.FetchLight()
        for i = 1, #bags do
            BA.IterateSlots(bags[i], consider)
        end
    end

    if bestSlot > 0 then
        BA._seedSlotCache[uid] = {
            snapGen = snapGen,
            slot = bestSlot,
            bagKey = bestBagKey,
        }
        return bestSlot, bestItem, BackpackTypeForBagKey(bestBagKey)
    end
    return 0, nil, BackpackTypeForBagKey(BAG_CRAFT)
end
