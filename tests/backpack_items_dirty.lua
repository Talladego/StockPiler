-- Zoning during cultivation must not leave the shared backpack cache empty.
-- Run: lua5.1 tests/backpack_items_dirty.lua

local function script_dir()
    local src = debug.getinfo(1, "S").source
    if type(src) == "string" and src:sub(1, 1) == "@" then
        src = src:sub(2)
    end
    return (src:match("^(.*)[/\\]") or ".")
end

local ROOT = script_dir() .. "/.."

local function load_module(rel)
    local path = ROOT .. "/" .. rel
    local fh = assert(io.open(path, "rb"))
    local text = fh:read("*a")
    fh:close()
    text = text:gsub('L"([^"]*)"', '"%1"')
    assert(loadstring(text, "@" .. path))()
end

local failures = 0
local checks = 0

local function eq(actual, expected, msg)
    checks = checks + 1
    if actual ~= expected then
        failures = failures + 1
        io.stderr:write(
            "FAIL ", msg,
            " expected=", tostring(expected),
            " got=", tostring(actual), "\n"
        )
    end
end

function towstring(s)
    return tostring(s)
end

StockPiler = StockPiler or {}
load_module("Source/Core/Util.lua")
load_module("Source/Adapters/BagAdapter.lua")
load_module("Source/Knowledge/Additives.lua")
load_module("Source/Adapters/ApothecaryAdapter.lua")

local BA = StockPiler.BagAdapter
local AD = StockPiler.Additives
local AA = StockPiler.ApothecaryAdapter

local cachedMain
local nativePayload
local nativeMainReads
local getItemsCalls

local function installDefaultGetItems()
    DataUtils.GetItems = function()
        getItemsCalls = getItemsCalls + 1
        if GameData.Player.itemsDirty == true then
            local data = GetInventoryItemData()
            cachedMain = data
            GameData.Player.itemsDirty = false
        end
        return cachedMain
    end
end

function GetInventoryItemData()
    nativeMainReads = nativeMainReads + 1
    return nativePayload
end

local function resetPlayer(dirty)
    GameData = {
        Player = {
            itemsDirty = dirty == true,
            craftingItemsDirty = true,
            numBackpackSlots = 80,
        },
        ItemLocs = {
            CRAFTING_ITEM = 3,
            INVENTORY = 1,
        },
    }
    cachedMain = {}
    nativePayload = { [1] = { uniqueID = 9001, stackCount = 1 } }
    nativeMainReads = 0
    getItemsCalls = 0
    DataUtils = DataUtils or {}
    DataUtils.GetCraftingItems = nil
    DataUtils.GetItemData = nil
    installDefaultGetItems()
    DataUtils.FindItem = function(uid)
        local items = DataUtils.GetItems()
        if type(items) ~= "table" then
            return nil
        end
        uid = tonumber(uid) or 0
        for _, item in pairs(items) do
            if type(item) == "table" and (tonumber(item.uniqueID) or 0) == uid then
                return item
            end
        end
        return nil
    end
    GetCraftingItemData = nil
    EA_Window_Backpack = nil
    StockPiler.Inventory = nil
end

local function clientBug(mode)
    if mode == "raise" then
        GameData.Player.itemsDirty = true
        return { [1] = { uniqueID = 3, stackCount = 1 } }
    end
    if mode == "reraise" then
        GameData.Player.itemsDirty = false
        GameData.Player.itemsDirty = true
        return { [1] = { uniqueID = 3, stackCount = 1 } }
    end
    GameData.Player.itemsDirty = false
    GameData.Player.craftingItemsDirty = false
    if mode == "err" then
        error("craft read failed")
    end
    if mode == "nil" then
        return nil
    end
    return { [1] = { uniqueID = 3, stackCount = 1 } }
end

local function expectRebuilt(label)
    eq(GameData.Player.itemsDirty, true, label .. " leaves itemsDirty pending")
    local items = DataUtils.GetItems()
    eq(nativeMainReads, 1, label .. " rebuilds the shared cache with one native read")
    eq(items[1].uniqueID, 9001, label .. " GetItems returns the populated backpack")
    eq(GameData.Player.itemsDirty, false, label .. " native fill clears itemsDirty")
    local found = DataUtils.FindItem(9001)
    eq(found and found.uniqueID, 9001, label .. " FindItem sees the repaired cache")
    eq(nativeMainReads, 1, label .. " FindItem does not read native inventory again")
end

-- Main bag: ordinary empty slots are a real cache, not a broken one.
resetPlayer(false)
cachedMain = { [1] = { uniqueID = 0, name = "" }, [2] = {} }
local ordinary = BA.GetBagTable("main")
eq(ordinary[1].uniqueID, 0, "ordinary empty slot is returned")
eq(next(ordinary) ~= nil, true, "ordinary empty slots are not a zero-entry cache")
eq(nativeMainReads, 0, "ordinary empty slots do not read native inventory")
eq(GameData.Player.itemsDirty, false, "ordinary empty slots leave itemsDirty clear")

-- Healthy cache: repeated reads stay on the shared table.
resetPlayer(false)
cachedMain = { [1] = { uniqueID = 9001, stackCount = 1 } }
local healthy = BA.GetBagTable("main")
local healthyAgain = BA.GetBagTable("main")
eq(healthy[1].uniqueID, 9001, "healthy cache returns the stacked item")
eq(healthyAgain[1].stackCount, 1, "a second main read returns the same cache")
eq(nativeMainReads, 0, "repeated healthy reads do no native inventory reads")
eq(getItemsCalls, 2, "repeated healthy reads still call GetItems")
eq(GameData.Player.itemsDirty, false, "healthy reads leave itemsDirty clear")

-- Zero-entry cache with a known backpack: one native retry repairs it.
resetPlayer(false)
cachedMain = {}
nativePayload = { [1] = { uniqueID = 9001, stackCount = 1 } }
local repaired = BA.GetBagTable("main")
eq(nativeMainReads, 1, "empty shared cache retries GetItems once")
eq(getItemsCalls, 2, "the retry is the second GetItems call")
eq(repaired[1].uniqueID, 9001, "GetBagTable returns the repaired backpack")
eq(GameData.Player.itemsDirty, false, "a successful repair leaves the client flag clear")
eq(DataUtils.GetItems()[1].uniqueID, 9001, "later GetItems serves the repaired cache")
eq(DataUtils.FindItem(9001).uniqueID, 9001, "FindItem works after the in-place repair")
eq(nativeMainReads, 1, "later reads of the repaired cache do no further native reads")

-- Retry still empty: stay dirty, and do not fetch native inventory twice.
resetPlayer(false)
cachedMain = {}
nativePayload = {}
local stillEmpty = BA.GetBagTable("main")
eq(type(stillEmpty), "table", "an empty retry still returns the table")
eq(next(stillEmpty) == nil, true, "an empty retry stays a zero-entry cache")
eq(nativeMainReads, 1, "an empty retry is bounded to one native read")
eq(GameData.Player.itemsDirty, true, "an empty retry leaves itemsDirty set")

-- First GetItems already read native inventory and it was empty: no second fetch.
resetPlayer(true)
cachedMain = {}
nativePayload = {}
local startedDirty = BA.GetBagTable("main")
eq(type(startedDirty), "table", "a dirty empty read returns the table")
eq(next(startedDirty) == nil, true, "a dirty empty read stays a zero-entry cache")
eq(nativeMainReads, 1, "a dirty empty read does not fetch native inventory twice")
eq(getItemsCalls, 1, "a dirty empty read does not call GetItems again")
eq(GameData.Player.itemsDirty, true, "a dirty empty read leaves itemsDirty set")

-- GetItems fails before any native read: one retry, then leave the flag set.
resetPlayer(false)
cachedMain = {}
local failedOnce = true
DataUtils.GetItems = function()
    getItemsCalls = getItemsCalls + 1
    if failedOnce then
        failedOnce = false
        error("get items failed")
    end
    if GameData.Player.itemsDirty == true then
        cachedMain = GetInventoryItemData()
        GameData.Player.itemsDirty = false
    end
    return cachedMain
end
local afterFail = BA.GetBagTable("main")
eq(afterFail[1].uniqueID, 9001, "a failed GetItems retries once and repairs the cache")
eq(nativeMainReads, 1, "a failed GetItems does one native read on the retry")
eq(GameData.Player.itemsDirty, false, "a repaired retry leaves the client flag clear")

-- GetItems fails and the retry is not a table: leave itemsDirty set, no second native read.
resetPlayer(false)
DataUtils.GetItems = function()
    getItemsCalls = getItemsCalls + 1
    return nil
end
local missing = BA.GetBagTable("main")
eq(missing, nil, "a non-table GetItems result stays nil when the retry is also nil")
eq(getItemsCalls, 2, "a non-table GetItems result is retried once")
eq(nativeMainReads, 0, "a nil GetItems result does not invent a native read")
eq(GameData.Player.itemsDirty, true, "a failed retry leaves itemsDirty set")

-- Already dirty, and the native read errors: one attempt, flag stays set.
resetPlayer(true)
DataUtils.GetItems = function()
    getItemsCalls = getItemsCalls + 1
    nativeMainReads = nativeMainReads + 1
    GameData.Player.itemsDirty = false
    error("native read failed")
end
local dirtyFail = BA.GetBagTable("main")
eq(dirtyFail, nil, "a failed dirty read does not return a bag")
eq(nativeMainReads, 1, "a failed dirty read does not fetch native inventory twice")
eq(getItemsCalls, 1, "a failed dirty read does not retry GetItems")
eq(GameData.Player.itemsDirty, true, "a failed dirty read leaves itemsDirty set")

-- No known backpack capacity: an empty cache is not treated as broken.
resetPlayer(false)
GameData.Player.numBackpackSlots = nil
cachedMain = {}
local unknownCap = BA.GetBagTable("main")
eq(next(unknownCap) == nil, true, "unknown capacity returns the empty cache")
eq(nativeMainReads, 0, "unknown capacity does not read native inventory")
eq(GameData.Player.itemsDirty, false, "unknown capacity does not mark itemsDirty")

-- Capacity from the backpack window is enough to repair.
resetPlayer(false)
GameData.Player.numBackpackSlots = nil
GameData.Player.backpackSlots = nil
GameData.Player.maxBackpackSlots = nil
cachedMain = {}
nativePayload = { [1] = { uniqueID = 9001, stackCount = 1 } }
EA_Window_Backpack = {
    TYPE_INVENTORY = 2,
    numberOfSlots = { [2] = 80 },
}
local fromWindow = BA.GetBagTable("main")
eq(fromWindow[1].uniqueID, 9001, "window slot count repairs an empty shared cache")
eq(nativeMainReads, 1, "window slot count retries GetItems once")

-- Force path returns whatever native inventory returns and does not retry.
resetPlayer(false)
nativePayload = {}
local forced = BA.GetBagTable("main", { force = true })
eq(type(forced), "table", "force returns the native table")
eq(next(forced) == nil, true, "force can return a zero-entry table")
eq(nativeMainReads, 1, "force reads native inventory once")
eq(GameData.Player.itemsDirty, false, "force does not mark a clear itemsDirty flag")

local function craftGetter(mode)
    return function()
        return clientBug(mode)
    end
end

local function expectCraftPreserved(label, arm, run)
    resetPlayer(true)
    arm("ok")
    run()
    expectRebuilt(label .. " normal return")

    resetPlayer(true)
    arm("err")
    run()
    expectRebuilt(label .. " error")

    resetPlayer(true)
    arm("nil")
    run()
    expectRebuilt(label .. " nil")

    resetPlayer(true)
    arm("reraise")
    run()
    expectRebuilt(label .. " re-raised flag")

    resetPlayer(false)
    arm("raise")
    run()
    expectRebuilt(label .. " newly raised flag")

    resetPlayer(false)
    arm("ok")
    run()
    eq(GameData.Player.itemsDirty, false, label .. " does not set itemsDirty when it was clear")
    DataUtils.GetItems()
    eq(nativeMainReads, 0, label .. " clear flag does not read native inventory")
end

expectCraftPreserved(
    "GetBagTable craft",
    function(mode)
        DataUtils.GetCraftingItems = craftGetter(mode)
    end,
    function()
        BA.GetBagTable("craft")
    end
)

expectCraftPreserved(
    "GetBagTable craft force",
    function(mode)
        GetCraftingItemData = craftGetter(mode)
        DataUtils.GetCraftingItems = nil
    end,
    function()
        BA.GetBagTable("craft", { force = true })
    end
)

expectCraftPreserved(
    "GetBagTable craft fallback",
    function(mode)
        DataUtils.GetCraftingItems = nil
        GetCraftingItemData = craftGetter(mode)
    end,
    function()
        BA.GetBagTable("craft")
    end
)

expectCraftPreserved(
    "ReadSlot craft",
    function(mode)
        DataUtils.GetCraftingItems = nil
        GetCraftingItemData = nil
        DataUtils.GetItemData = function(loc, slot)
            eq(loc, GameData.ItemLocs.CRAFTING_ITEM, "ReadSlot craft uses the crafting item loc")
            eq(slot, 4, "ReadSlot craft passes the slot")
            return clientBug(mode)
        end
    end,
    function()
        BA.ReadSlot("craft", 4)
    end
)

expectCraftPreserved(
    "FindBestInCraftBag",
    function(mode)
        DataUtils.GetCraftingItems = craftGetter(mode)
    end,
    function()
        AD.FindBestInCraftBag(2)
    end
)

function AddCraftingItem()
    return true
end

local function armBackpack(mode, bagType)
    EA_Window_Backpack = {
        TYPE_CRAFTING = 4,
        TYPE_INVENTORY = 2,
        GetItemsFromBackpack = function(got)
            eq(got, bagType, "backpack read uses the requested bag type")
            if mode == "raise" or mode == "reraise" or mode == "ok" then
                local rows = clientBug(mode)
                if type(rows) ~= "table" then
                    return rows
                end
                return { [1] = { uniqueID = 42, stackCount = 1 } }
            end
            return clientBug(mode)
        end,
    }
end

expectCraftPreserved(
    "AddItemToCrafting",
    function(mode)
        armBackpack(mode, 4)
    end,
    function()
        AA.AddItemToCrafting(1, 1, 4)
    end
)

expectCraftPreserved(
    "GetSlottedItem craft slots",
    function(mode)
        armBackpack(mode, 4)
        GetCraftingBackPackSlots = function()
            return { [1] = { slot = 1, backpack = 4 } }
        end
        ApothecaryWindow = nil
    end,
    function()
        AA.GetSlottedItem(1)
    end
)

expectCraftPreserved(
    "GetSlottedItem craftingData",
    function(mode)
        armBackpack(mode, 4)
        GetCraftingBackPackSlots = function()
            return {}
        end
        ApothecaryWindow = {
            craftingData = {
                [0] = { sourceSlot = 1, sourceBackpack = 4 },
            },
        }
    end,
    function()
        AA.GetSlottedItem(0)
    end
)

-- Inventory backpack reads must not restore a flag the read cleared.
resetPlayer(true)
armBackpack("ok", 2)
AA.AddItemToCrafting(1, 1, 2)
eq(GameData.Player.itemsDirty, false, "inventory AddItemToCrafting does not restore itemsDirty")

resetPlayer(true)
armBackpack("ok", 2)
GetCraftingBackPackSlots = function()
    return { [1] = { slot = 1, backpack = 2 } }
end
ApothecaryWindow = nil
AA.GetSlottedItem(1)
eq(GameData.Player.itemsDirty, false, "inventory GetSlottedItem does not restore itemsDirty")

if failures > 0 then
    io.stderr:write(string.format("%d/%d checks failed\n", failures, checks))
    os.exit(1)
end
print(string.format("backpack_items_dirty: %d checks passed", checks))
