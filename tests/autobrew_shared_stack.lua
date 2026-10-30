-- Two ingredient slots must not treat one short stack as ready.
-- Run: lua5.1 tests/autobrew_shared_stack.lua

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

local function check(cond, msg)
    checks = checks + 1
    if cond ~= true then
        failures = failures + 1
        io.stderr:write("FAIL ", msg, "\n")
    end
end

function towstring(s)
    return tostring(s)
end

function DoesWindowExist()
    return false
end

function WindowGetShowing()
    return false
end

local now = 5000
function GetGameTime()
    return now
end

local performs = 0
function PerformCrafting()
    performs = performs + 1
    return true
end

local CRAFT = 4
local bags = {}
local craftSlots = {}

EA_Window_Backpack = {
    TYPE_CRAFTING = CRAFT,
    GetItemsFromBackpack = function(backpack)
        return bags[tonumber(backpack) or 0]
    end,
}

function GetCraftingBackPackSlots()
    return craftSlots
end

function RemoveCraftingItem(_, slot, backpack)
    for craftSlot, entry in pairs(craftSlots) do
        if type(entry) == "table"
            and entry.slot == slot
            and entry.backpack == backpack
        then
            craftSlots[craftSlot] = nil
        end
    end
end

GameData = {
    CraftingStates = {
        VALID_RECIPE = 5,
        PERFORMING = 9,
    },
    CraftingSuccessChance = {
        INVALID = 0,
        LOW = 1,
        MEDIUM = 2,
        HIGH = 3,
    },
    CraftingStatus = {
        State = 5,
        SkillType = 4,
        SuccessChance = 3,
    },
    Player = {},
}

StockPiler = {
    FrameCounter = 1,
    Util = {
        NowSec = function() return now end,
        ToNarrow = function(v) return tostring(v or "") end,
        TryCall = function(_, fn, ...)
            return pcall(fn, ...)
        end,
        TryCallQuiet = function(_, fn, ...)
            return pcall(fn, ...)
        end,
    },
}

load_module("Source/Adapters/ApothecaryAdapter.lua")
load_module("Source/Brew.lua")

local AA = StockPiler.ApothecaryAdapter
local Brew = StockPiler.Brew

local function item(uid, count)
    return { uniqueID = uid, stackCount = count }
end

local function refresh()
    StockPiler.FrameCounter = (tonumber(StockPiler.FrameCounter) or 0) + 1
    AA.InvalidateCraftSlotCache()
end

local function recipe()
    return {
        slots = {
            { role = "container", uniqueID = 10, perCraft = 1 },
            { role = "main", uniqueID = 20, perCraft = 1 },
            { role = "stabilizer", uniqueID = 900, perCraft = 2 },
        },
    }
end

local function arm(source)
    performs = 0
    Brew._job = nil
    Brew._loadSource = source or "auto"
    Brew._loadSettleUntil = 0
    Brew._lastPerformBlockWhy = nil
    Brew._session = {
        phase = "loaded",
        uniqueID = 9,
        potionKey = "uid:9",
        recipe = recipe(),
        _brewOwnedSession = true,
        _brewPlacedOnBoard = true,
    }
end

local function slot(craftSlot, bagSlot, backpack)
    craftSlots[craftSlot] = {
        slot = bagSlot,
        backpack = backpack or CRAFT,
    }
end

local function standardBoard()
    bags = {
        [CRAFT] = {
            [1] = item(10, 5),
            [2] = item(20, 5),
            [3] = item(900, 1),
            [4] = item(900, 50),
        },
    }
    craftSlots = {}
    slot(0, 1, CRAFT)
    slot(1, 2, CRAFT)
    slot(2, 3, CRAFT)
    slot(3, 3, CRAFT)
    ApothecaryWindow = nil
    refresh()
end

standardBoard()
local shared, sharedBag, sharedSlot = AA.GetSlottedItem(2)
eq(shared and shared.uniqueID, 900, "native slot returns the stabilizer")
eq(sharedBag, CRAFT, "native slot returns the backpack")
eq(sharedSlot, 3, "native slot returns the source slot")
local again = AA.GetSlottedItem(3)
eq(again and again.stackCount, 1, "the other ingredient slot reads the same stack")

arm("auto")
eq(Brew.ValidateApothecaryPerform(), false, "one item cannot cover two slots")
eq(Brew._lastPerformBlockWhy, nil, "validate does not record a block by itself")
eq(Brew.TryPerform("shared"), false, "an overcommitted board does not perform")
eq(Brew._lastPerformBlockWhy, "board-incomplete", "the block is an incomplete board")
eq(Brew.GetSession().phase, "idle", "an automatic board unloads")
eq(Brew.TryPerform("shared-2"), false, "a second attempt does not perform")
eq(Brew.TryPerform("shared-3"), false, "a third attempt does not perform")
eq(performs, 0, "three attempts send no Perform")

arm("manual")
standardBoard()
for _ = 1, 3 do
    eq(Brew.TryPerform("manual"), false, "a manual board does not perform either")
end
eq(performs, 0, "a manual board sends no Perform")
eq(Brew.GetSession().phase, "loaded", "a manual board stays loaded")
eq(Brew._lastPerformBlockWhy, "board-incomplete", "a manual board is still incomplete")

-- Exact quantity: two slots, two items on that stack.
standardBoard()
bags[CRAFT][3].stackCount = 2
refresh()
arm("auto")
eq(Brew.ValidateApothecaryPerform(), true, "a stack of two covers two slots")
eq(Brew.TryPerform("exact"), true, "that board performs once")
eq(performs, 1, "exact quantity sends one Perform")

-- Same item id, two physical stacks. Each slot has its own stack.
standardBoard()
slot(2, 3, CRAFT)
slot(3, 4, CRAFT)
refresh()
arm("auto")
eq(Brew.ValidateApothecaryPerform(), true, "separate stacks of the same item both count")

-- Same slot number in two backpacks.
standardBoard()
bags[7] = {
    [3] = item(900, 1),
}
slot(2, 3, CRAFT)
slot(3, 3, 7)
refresh()
arm("auto")
eq(Brew.ValidateApothecaryPerform(), true, "the same slot in another backpack is a different stack")

-- Previously enough, then the stack drops to one while both slots still point at it.
standardBoard()
bags[CRAFT][3].stackCount = 3
refresh()
arm("auto")
eq(Brew.ValidateApothecaryPerform(), true, "three items still cover two slots")
bags[CRAFT][3].stackCount = 1
refresh()
eq(Brew.ValidateApothecaryPerform(), false, "depleting that stack to one is no longer ready")
eq(Brew.TryPerform("depleted"), false, "a depleted shared stack does not perform")
eq(performs, 0, "depletion sends no Perform")

-- Crafting-data fallback still names the source stack.
standardBoard()
bags[CRAFT][3].stackCount = 1
GetCraftingBackPackSlots = function()
    return {}
end
ApothecaryWindow = {
    craftingData = {
        [0] = { sourceSlot = 1, sourceBackpack = CRAFT, objectId = 10 },
        [1] = { sourceSlot = 2, sourceBackpack = CRAFT, objectId = 20 },
        [2] = { sourceSlot = 3, sourceBackpack = CRAFT, objectId = 900 },
        [3] = { sourceSlot = 3, sourceBackpack = CRAFT, objectId = 900 },
    },
}
refresh()
local fromUi, uiBag, uiSlot = AA.GetSlottedItem(2)
eq(fromUi and fromUi.uniqueID, 900, "crafting data returns the bag item")
eq(uiBag, CRAFT, "crafting data returns the backpack")
eq(uiSlot, 3, "crafting data returns the source slot")
arm("auto")
eq(Brew.ValidateApothecaryPerform(), false, "crafting data rejects the same short stack")
eq(Brew.TryPerform("ui"), false, "crafting data does not perform")
eq(performs, 0, "crafting data sends no Perform")

-- No source identity: presence only, so this path does not invent a shortage.
GetCraftingBackPackSlots = function()
    return {}
end
ApothecaryWindow = {
    craftingData = {
        [0] = { objectId = 10, iconId = 1 },
        [1] = { objectId = 20, iconId = 2 },
        [2] = { objectId = 900, iconId = 3 },
        [3] = { objectId = 900, iconId = 3 },
    },
}
refresh()
local bare, bareBag, bareSlot = AA.GetSlottedItem(2)
eq(bare and bare.uniqueID, 900, "an object id still returns an item")
eq(bareBag, nil, "an object id has no backpack")
eq(bareSlot, nil, "an object id has no source slot")
arm("manual")
eq(Brew.ValidateApothecaryPerform(), true, "an unidentified stack is not treated as short")

if failures > 0 then
    io.stderr:write(string.format("%d/%d checks failed\n", failures, checks))
    os.exit(1)
end
print(string.format("autobrew_shared_stack: %d checks passed", checks))
