-- Captured cultivable twins must not make AutoBrew spend the plant first.
-- Run: lua5.1 tests/watch_status_tips.lua

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

local function check(cond, msg)
    checks = checks + 1
    if cond ~= true then
        failures = failures + 1
        io.stderr:write("FAIL ", msg, "\n")
    end
end

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
function WStringToString(s)
    return tostring(s)
end

GameData = {
    CultivationTypes = { NONE = 0, SEED = 1, SPORE = 5 },
    ItemTypes = { CRAFTING = 34, POTION = 31 },
    TradeSkills = { APOTHECARY = 4, CULTIVATION = 7 },
}

local BUTCHER = 3030238
local PLANT = 3020048
local BUTCHER_SLOT = 9
local PLANT_SLOT = 3
local bagScans = 0
local bagItems = {}

StockPiler = {
    FrameCounter = 3,
    Account = { items = {}, grows = {}, refines = {}, recipes = {}, potions = {} },
    Settings = { characters = {} },
    Persistence = {
        GetCharacterBucket = function()
            return {}
        end,
    },
    Util = {
        ToNarrow = function(v)
            return tostring(v or "")
        end,
        T = function(k)
            return tostring(k)
        end,
        NowSec = function()
            return 1000
        end,
    },
    T = function(k)
        return tostring(k)
    end,
    Inventory = {
        GetSnapGen = function()
            return 1
        end,
        ForEachItem = function(fn)
            bagScans = bagScans + 1
            for i = 1, #bagItems do
                fn(bagItems[i])
            end
        end,
    },
}

load_module("Source/Core/Util.lua")
load_module("Source/Stores/KnowledgeStore.lua")
load_module("Source/Knowledge/MaterialSpec.lua")
load_module("Source/Knowledge/MaterialExceptions.lua")
load_module("Source/Knowledge/Items.lua")
load_module("Source/Knowledge/SeedMap.lua")
load_module("Source/Knowledge/RecipeSpec.lua")
load_module("Source/Brew.lua")
load_module("Source/Core/Perf.lua")

local SM = StockPiler.SeedMap
local RS = StockPiler.RecipeSpec
local Brew = StockPiler.Brew
local Perf = StockPiler.Perf

local function butcherSpec()
    return {
        uid = BUTCHER,
        uniqueID = BUTCHER,
        name = "Brutal Zoic Gore",
        role = "stabilizer",
        tradeSkill = 4,
        skillLevel = 200,
        cultivationType = 0,
        slotType = 1,
        bonuses = { [1] = 10, [4] = 1 },
        isRefinable = false,
    }
end

local function plantRow()
    return {
        uniqueID = PLANT,
        name = "Majestic Goldweed",
        iconNum = 42,
        kind = "plant",
        isRefinable = true,
        itemType = 34,
        tradeSkill = 4,
        skillLevel = 200,
        skillReq = 200,
        cultivationType = 0,
        slotType = 1,
        role = "stabilizer",
        bonuses = { [1] = 10, [4] = 1 },
        stability = 10,
    }
end

local function clearTwinCache()
    SM._growTwinCache = {}
    SM._growTwinCacheSnap = nil
    SM._plantUidCache = {}
    SM._plantUidCacheSnap = nil
end

-- Known catalog answers a hover lookup without walking bags.
StockPiler.Account.items = { [tostring(PLANT)] = plantRow() }
bagItems = {}
bagScans = 0
clearTwinCache()
eq(SM.FindGrowableTwinUid(butcherSpec(), { cacheOnly = true }), PLANT,
    "cacheOnly resolves a known cultivable twin")
eq(bagScans, 0, "cacheOnly does not scan bags for a known twin")

-- A twin that exists only in bags waits for an explicit full search.
StockPiler.Account.items = {}
bagItems = { { uniqueID = PLANT, name = "Majestic Goldweed", stackCount = 1 } }
local origBagMatch = StockPiler.MaterialSpec.ProductMatches
StockPiler.MaterialSpec.ProductMatches = function(item)
    return tonumber(item and (item.uniqueID or item.uid)) == PLANT
end
bagScans = 0
clearTwinCache()
eq(SM.FindGrowableTwinUid(butcherSpec(), { cacheOnly = true }), 0,
    "cacheOnly misses a bag-only twin")
eq(bagScans, 0, "cacheOnly does not scan bags for a bag-only twin")
eq(SM.FindGrowableTwinUid(butcherSpec()), PLANT, "a full search finds the bag twin")
eq(bagScans, 1, "the full search scans bags once")
StockPiler.MaterialSpec.ProductMatches = origBagMatch

-- Capture rewrites the saved exemplar to the cultivable twin.
StockPiler.Account.items = { [tostring(PLANT)] = plantRow() }
clearTwinCache()
local slots = RS.MaterialsToSpecSlots({
    {
        role = "stabilizer",
        uniqueID = BUTCHER,
        perCraft = 1,
        itemData = butcherSpec(),
    },
})
eq(#slots, 1, "capture keeps the stabilizer slot")
eq(tonumber(slots[1].uid), PLANT, "capture stores the cultivable twin uid")
eq(tonumber(slots[1].spec and slots[1].spec.uid), PLANT, "capture stores the twin on the spec")
eq(slots[1].spec and slots[1].spec.boundUid, nil, "capture clears the butcher bound uid")
eq(slots[1].boundUid, nil, "capture does not keep a slot bound uid")

-- brewPreferNonGrowableFirst stays on (empty character row). Both stacks match.
StockPiler.BagAdapter = {
    FetchForce = function()
        return {
            { bagType = "craft" },
            { bagType = "inv" },
        }
    end,
    IterateSlots = function(bag, fn)
        if bag.bagType == "craft" then
            fn("craft", PLANT_SLOT, {
                uniqueID = PLANT,
                stackCount = 1,
                name = "Majestic Goldweed",
            })
        else
            fn("inv", BUTCHER_SLOT, {
                uniqueID = BUTCHER,
                stackCount = 8,
                name = "Brutal Zoic Gore",
            })
        end
    end,
}
StockPiler.MaterialSpec.IsSeedOrSpore = function()
    return false
end
local origMatch = StockPiler.MaterialSpec.ProductMatches
local origGrow = SM.IsGrowableSpec
StockPiler.MaterialSpec.ProductMatches = function(item)
    local uid = tonumber(item and (item.uniqueID or item.uid)) or 0
    return uid == BUTCHER or uid == PLANT
end
SM.IsGrowableSpec = function(spec)
    local uid = tonumber(spec and (spec.uid or spec.uniqueID)) or 0
    if uid == PLANT then
        return true
    end
    if uid == BUTCHER then
        return false
    end
    local name = string.lower(tostring(spec and spec.name or ""))
    if string.find(name, "goldweed", 1, true) then
        return true
    end
    if string.find(name, "gore", 1, true) or string.find(name, "zoic", 1, true) then
        return false
    end
    return origGrow(spec)
end
local want = slots[1].spec
local bagSlot, _, _, matched = Brew.FindCraftingBagItemBySpec(want, tonumber(slots[1].uid), nil)
StockPiler.MaterialSpec.ProductMatches = origMatch
SM.IsGrowableSpec = origGrow
eq(bagSlot, BUTCHER_SLOT, "AutoBrew spends the butcher stack before the cultivable plant")
eq(matched, BUTCHER, "the chosen stack is the butcher exemplar")

Perf.SetEnabled(false)
Perf.ResetReasonTally()
Perf.Tally("prewarm", "hover")
eq(Perf.FormatReasonTally(), "tally=(empty)", "tally is a no-op while profiling is off")
Perf.SetEnabled(true)
Perf.Tally("prewarm", "hover")
check(string.find(Perf.FormatReasonTally(), "prewarm{hover=1}", 1, true) ~= nil,
    "tally records while profiling is on")
Perf.SetEnabled(false)

if failures > 0 then
    io.stderr:write(string.format("%d/%d checks failed\n", failures, checks))
    os.exit(1)
end
print(string.format("watch_status_tips: %d checks passed", checks))
