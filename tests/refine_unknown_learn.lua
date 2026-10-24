-- Lua 5.1 harness for unknown-plant refine learning.
-- Run from the repo root: lua5.1 tests/refine_unknown_learn.lua
--
-- Loads the real SeedMap, LearnBridge, Items, and Catalog modules.

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
    local fh, openErr = io.open(path, "rb")
    if not fh then
        error("open " .. path .. ": " .. tostring(openErr))
    end
    local text = fh:read("*a")
    fh:close()
    -- WAR wstring literals are not Lua 5.1. Same rewrite the release workflow uses.
    text = text:gsub('L"([^"]*)"', '"%1"')
    local chunk, err = loadstring(text, "@" .. path)
    if not chunk then
        error(err)
    end
    chunk()
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

GameData = {
    CultivationTypes = { NONE = 0, SEED = 1, SPORE = 5 },
    ItemTypes = { CRAFTING = 34, POTION = 31 },
    TradeSkills = { APOTHECARY = 4, CULTIVATION = 7 },
}

local now = 10000
function GetGameTime()
    return now
end

StockPiler = {}
StockPiler.Persistence = {}
StockPiler.Account = {
    items = {},
    grows = {},
    refines = {},
    recipes = {},
    potions = {},
    skillUpRates = {},
}

load_module("Source/Core/Util.lua")
load_module("Source/Stores/KnowledgeStore.lua")
load_module("Source/Knowledge/Items.lua")
load_module("Source/Knowledge/SeedMap.lua")
load_module("Source/Knowledge/LearnBridge.lua")
load_module("Source/View/Catalog.lua")

local SM = StockPiler.SeedMap
local LB = StockPiler.LearnBridge
local PLANT = 83534
local SEED = 84035
local SPORE = 84036
local DUSTY = 85001
local MOSS = 86001
local PACKET = 87001

local snapGen = 1
local slots = { main = {}, craft = {} }

local function eachSlot(fn)
    for bag, list in pairs(slots) do
        for slot, item in pairs(list) do
            if type(item) == "table" and (tonumber(item.stackCount) or 0) > 0 then
                fn(item, bag, slot)
            end
        end
    end
end

local function countUid(uid)
    uid = tonumber(uid) or 0
    local n = 0
    eachSlot(function(item)
        if (tonumber(item.uniqueID) or 0) == uid then
            n = n + (tonumber(item.stackCount) or 0)
        end
    end)
    return n
end

StockPiler.Inventory = {
    GetSnapGen = function()
        return snapGen
    end,
    CountByUid = function(uid)
        return countUid(uid)
    end,
    GetSample = function(uid)
        uid = tonumber(uid) or 0
        local found = nil
        eachSlot(function(item)
            if found == nil and (tonumber(item.uniqueID) or 0) == uid then
                found = item
            end
        end)
        return found
    end,
    ForEachItem = function(fn)
        eachSlot(fn)
    end,
}

local function bump()
    snapGen = snapGen + 1
end

local function makeItem(uid, name, qty, cult, extra)
    local row = {
        uniqueID = uid,
        name = name,
        stackCount = qty,
        cultivationType = cult or 0,
        type = 34,
        itemType = 34,
        iconNum = 10,
    }
    if type(extra) == "table" then
        for k, v in pairs(extra) do
            row[k] = v
        end
    end
    return row
end

local function plantItem(qty)
    return makeItem(PLANT, "Bitter Grumpleaf", qty or 1, 0, {
        isRefinable = true,
        craftingBonus = {
            { bonusReference = 8, bonusValue = 2 },
            { bonusReference = 9, bonusValue = 200 },
            { bonusReference = 2, bonusValue = 15 },
        },
    })
end

local function reset()
    slots.main = {}
    slots.craft = {}
    snapGen = snapGen + 1
    now = now + 10
    StockPiler.Account = {
        items = {},
        grows = {},
        refines = {},
        recipes = {},
        potions = {},
        skillUpRates = {},
    }
    SM._pendingRefine = nil
    SM._pendingHarvest = {}
    SM._refineConvertFailed = {}
    SM._refineConvertFailedUntil = {}
    LB._harvestCompletePending = false
    LB._harvestCompleteSeenUpdate = false
end

local function refineRow()
    return StockPiler.Knowledge.Refines()[tostring(PLANT)]
end

local function growsEmpty()
    local grows = StockPiler.Knowledge.Grows()
    return next(grows) == nil
end

local function savedEmpty()
    local row = refineRow()
    if type(row) == "table" then
        return false
    end
    return growsEmpty()
end

local function catalogPlant()
    local list = StockPiler.Catalog.ListPlantEntries()
    for i = 1, #list do
        if (tonumber(list[i].plantUid) or 0) == PLANT then
            return list[i]
        end
    end
    return nil
end

local function noBlacklist()
    return SM.IsRefineConvertFailed(PLANT) ~= true
end

local function begin(item)
    local ok = SM.BeginPendingRefine(item)
    check(ok == true, "BeginPendingRefine")
    return ok
end

-- Last plant, split seed stacks, and a same-genus seed that must not be guessed.
local function armUnknown()
    reset()
    local plant = plantItem(1)
    slots.main[1] = plant
    slots.main[2] = makeItem(SEED, "Bitter Grumpleaf Seed", 2, 1)
    slots.craft[1] = makeItem(SEED, "Bitter Grumpleaf Seed", 3, 1)
    slots.craft[2] = makeItem(DUSTY, "Dusty Grumpleaf Seed", 4, 1)
    begin(plant)
    -- Live slot is wiped the way a consumed stack is. The pending copy must keep it.
    plant.name = nil
    plant.craftingBonus = nil
    plant.isRefinable = nil
    eq(SM._pendingRefine and SM._pendingRefine.expectedSeedUid, 0, "unknown does not pre-pick a seed")
    eq(countUid(SEED), 5, "split seed total before convert")
    return plant
end

local function applyUnknownConvert()
    slots.main[1] = nil
    slots.craft[1].stackCount = 4
    bump()
end

local function assertLearned(label)
    local row = refineRow()
    check(type(row) == "table", label .. " refine row")
    eq(tonumber(row and row.seedUid), SEED, label .. " seed uid")
    eq(tonumber(row and row.refineAttempts), 1, label .. " attempts")
    local out = row and row.seedOut and row.seedOut[tostring(SEED)]
    eq(tonumber(out and out.samples), 1, label .. " samples")
    eq(tonumber(out and out.qtySum), 1, label .. " delta ignores the pre-existing stacks")
    check(row.seedOut[tostring(DUSTY)] == nil, label .. " does not save the genus guess")
    eq(SM._pendingRefine, nil, label .. " pending cleared")
    local plantRow = StockPiler.Items.GetByUid(PLANT)
    local seedRow = StockPiler.Items.GetByUid(SEED)
    check(type(plantRow) == "table" and plantRow.name == "Bitter Grumpleaf", label .. " stores the plant")
    check(type(seedRow) == "table" and seedRow.name == "Bitter Grumpleaf Seed", label .. " stores the seed")
    eq(countUid(PLANT), 0, label .. " last plant consumed")
    eq(StockPiler.Inventory.GetSample(PLANT), nil, label .. " bag sample gone")
    local listed = catalogPlant()
    check(type(listed) == "table", label .. " Known plants lists the plant")
    eq(listed and listed.name, "Bitter Grumpleaf", label .. " catalog name")
    eq(tonumber(listed and listed.seedUid), SEED, label .. " catalog seed")
end

local function testUnknownCraftingBeforeBags()
    armUnknown()
    LB.OnCraftingUpdated()
    check(savedEmpty(), "crafting-before-bags does not learn early")
    check(type(SM._pendingRefine) == "table", "crafting-before-bags keeps the pending")
    check(noBlacklist(), "crafting-before-bags does not convert-fail")
    applyUnknownConvert()
    LB.OnUpdateProcessed()
    assertLearned("crafting-before-bags")
    local attempts = tonumber(refineRow().refineAttempts)
    LB.OnUpdateProcessed()
    LB.OnCraftingUpdated()
    eq(tonumber(refineRow().refineAttempts), attempts, "crafting-before-bags does not double-count")
end

local function testUnknownBagOnly()
    armUnknown()
    applyUnknownConvert()
    LB.OnUpdateProcessed()
    assertLearned("bag-only")
end

local function testUnknownCraftingAfterBags()
    armUnknown()
    applyUnknownConvert()
    LB.OnCraftingUpdated()
    assertLearned("crafting-after-bags")
end

local function testUnrelatedAndPacket()
    reset()
    local plant = plantItem(2)
    slots.main[1] = plant
    slots.main[2] = makeItem(MOSS, "Healing Moss Seed", 1, 1)
    begin(plant)
    slots.main[1].stackCount = 1
    slots.main[2].stackCount = 2
    bump()
    LB.OnUpdateProcessed()
    check(savedEmpty(), "unrelated gain writes no row")
    eq(SM._pendingRefine, nil, "unrelated gain clears pending")
    check(noBlacklist(), "unrelated gain does not convert-fail")

    reset()
    plant = plantItem(1)
    slots.main[1] = plant
    slots.craft[1] = makeItem(PACKET, "Bitter Grumpleaf Seed Packet", 1, 1)
    begin(plant)
    slots.main[1] = nil
    slots.craft[1].stackCount = 2
    bump()
    LB.OnUpdateProcessed()
    check(savedEmpty(), "seed packet writes no row")
    eq(SM._pendingRefine, nil, "seed packet clears pending")
    check(noBlacklist(), "seed packet does not convert-fail")

    -- A real matching seed plus an unrelated gain is still ambiguous.
    reset()
    plant = plantItem(1)
    slots.main[1] = plant
    slots.main[2] = makeItem(SEED, "Bitter Grumpleaf Seed", 1, 1)
    slots.craft[1] = makeItem(MOSS, "Healing Moss Seed", 1, 1)
    begin(plant)
    slots.main[1] = nil
    slots.main[2].stackCount = 2
    slots.craft[1].stackCount = 2
    bump()
    LB.OnUpdateProcessed()
    check(savedEmpty(), "related plus unrelated gain writes no row")
    eq(SM._pendingRefine, nil, "related plus unrelated gain clears pending")
    check(noBlacklist(), "related plus unrelated gain does not convert-fail")
end

local function testMultipleOutputs()
    reset()
    local plant = plantItem(1)
    slots.main[1] = plant
    slots.main[2] = makeItem(SEED, "Bitter Grumpleaf Seed", 1, 1)
    slots.craft[1] = makeItem(SPORE, "Bitter Grumpleaf Spore", 1, 5)
    begin(plant)
    slots.main[1] = nil
    slots.main[2].stackCount = 2
    slots.craft[1].stackCount = 2
    bump()
    LB.OnUpdateProcessed()
    check(savedEmpty(), "multiple outputs write no row")
    eq(SM._pendingRefine, nil, "multiple outputs clear pending")
    check(noBlacklist(), "multiple outputs do not convert-fail")
    eq(StockPiler.Items.GetByUid(PLANT), nil, "multiple outputs do not store the plant")
end

local function testStackMove()
    reset()
    local plant = plantItem(2)
    slots.main[1] = plant
    slots.main[2] = makeItem(SEED, "Bitter Grumpleaf Seed", 2, 1)
    slots.craft[1] = makeItem(SEED, "Bitter Grumpleaf Seed", 3, 1)
    begin(plant)
    -- Same uid leaves main and lands in craft. Totals stay 5.
    slots.main[2] = nil
    slots.craft[1].stackCount = 5
    bump()
    LB.OnUpdateProcessed()
    check(savedEmpty(), "stack move writes no row")
    check(type(SM._pendingRefine) == "table", "stack move stays pending until the plant is used")
    -- Plant is used, but the seed total never rose.
    slots.main[1].stackCount = 1
    bump()
    LB.OnUpdateProcessed()
    check(savedEmpty(), "consumed plant plus a stack move writes no row")
    check(type(SM._pendingRefine) == "table", "net-zero seed stays pending")
    now = now + 2
    LB.OnUpdateProcessed()
    check(savedEmpty(), "stack move expiry writes no row")
    eq(SM._pendingRefine, nil, "stack move expiry clears pending")
    check(noBlacklist(), "stack move does not convert-fail")
end

local function testExpiredPending()
    reset()
    local plant = plantItem(1)
    slots.main[1] = plant
    begin(plant)
    LB.OnUpdateProcessed()
    LB.OnUpdateProcessed()
    check(type(SM._pendingRefine) == "table", "update frames before the timeout keep the pending")
    check(savedEmpty(), "update frames write no row")
    now = now + 2
    LB.OnUpdateProcessed()
    check(savedEmpty(), "expired pending writes no row")
    eq(SM._pendingRefine, nil, "expired pending is cleared")
    check(noBlacklist(), "expired unknown output does not convert-fail")
    eq(StockPiler.Items.GetByUid(PLANT), nil, "expired pending stores no item")
end

local function armKnown()
    reset()
    local plant = plantItem(3)
    local seed = makeItem(SEED, "Bitter Grumpleaf Seed", 2, 1)
    slots.main[1] = plant
    slots.main[2] = seed
    slots.craft[1] = makeItem(SEED, "Bitter Grumpleaf Seed", 2, 1)
    StockPiler.Knowledge.Refines()[tostring(PLANT)] = {
        plantUid = PLANT,
        refineAttempts = 1,
        seedUid = SEED,
        seedOut = { [tostring(SEED)] = { samples = 1, qtySum = 1 } },
    }
    StockPiler.Knowledge.Grows()[tostring(SEED)] = {
        seedUid = SEED,
        products = { [tostring(PLANT)] = { uid = PLANT, samples = 1, qtySum = 1 } },
    }
    StockPiler.Items.StoreItem(plant, "plant")
    StockPiler.Items.StoreItem(seed, "seed")
    begin(plant)
    eq(SM._pendingRefine and SM._pendingRefine.expectedSeedUid, SEED, "known conversion watches the learned seed")
    eq(SM._pendingRefine and SM._pendingRefine.beforeSeed, 4, "known before-count includes both bags")
end

local function testKnownBagOnly()
    armKnown()
    slots.main[1].stackCount = 2
    slots.craft[1].stackCount = 3
    bump()
    LB.OnUpdateProcessed()
    local row = refineRow()
    eq(tonumber(row and row.refineAttempts), 2, "known bag-only records the second convert")
    eq(tonumber(row and row.seedUid), SEED, "known bag-only keeps the learned seed")
    eq(SM._pendingRefine, nil, "known bag-only clears pending")
    local listed = catalogPlant()
    check(type(listed) == "table", "known plant stays on Known plants")
end

local function testKnownCraftingBeforeBags()
    armKnown()
    LB.OnCraftingUpdated()
    eq(tonumber(refineRow().refineAttempts), 1, "known crafting-before-bags does not count early")
    check(type(SM._pendingRefine) == "table", "known crafting-before-bags keeps pending")
    slots.main[1].stackCount = 2
    slots.main[2].stackCount = 3
    bump()
    LB.OnUpdateProcessed()
    eq(tonumber(refineRow().refineAttempts), 2, "known crafting-before-bags records once")
    LB.OnCraftingUpdated()
    eq(tonumber(refineRow().refineAttempts), 2, "known crafting-before-bags does not double-count")
end

testUnknownCraftingBeforeBags()
testUnknownBagOnly()
testUnknownCraftingAfterBags()
testUnrelatedAndPacket()
testMultipleOutputs()
testStackMove()
testExpiredPending()
testKnownBagOnly()
testKnownCraftingBeforeBags()

armUnknown()
now = now + 2 -- beyond the default 1.5s lifetime
applyUnknownConvert()
LB.OnUpdateProcessed()
check(savedEmpty(), "expired unknown attempt cannot learn from a later delta")

armUnknown()
LB.Shutdown()
eq(SM._pendingRefine, nil, "shutdown cancels pending conversion")

local P2 = 83600
local S2 = 84100

local function listHas(list, uid)
    if type(list) ~= "table" then
        return false
    end
    for i = 1, #list do
        if tonumber(list[i]) == uid then
            return true
        end
    end
    return false
end

local function testSiblingHarvestDoesNotStealRefine()
    reset()
    slots.main[1] = makeItem(SEED, "Bitter Grumpleaf Seed", 3, 1, {
        craftingSkillRequirement = 100,
    })
    SM.BeginPendingHarvest(1, SEED)
    slots.main[2] = makeItem(PLANT, "Bitter Grumpleaf", 2, 0, {
        craftingSkillRequirement = 100,
    })
    slots.main[3] = makeItem(P2, "Sweet Grumpleaf", 1, 0, {
        craftingSkillRequirement = 150,
    })
    bump()
    SM.MarkHarvestLootDirty()
    check(SM.TryCompletePendingHarvest(true) == true, "crit harvest learns both plants")
    local bucket = StockPiler.Knowledge.Grows()[tostring(SEED)]
    check(type(bucket) == "table" and type(bucket.products[tostring(P2)]) == "table",
        "sweet plant is a harvest product of the bitter seed")
    check(listHas(SM.GetHarvestSeedUidsForPlant(P2), SEED),
        "harvest index points the sweet plant at the bitter seed")
    eq(#SM.GetRefineSeedUidsForPlant(P2), 0, "harvest does not create a refine link")
    check(listHas(SM.GetHarvestSeedUidsForPlant(P2), SEED),
        "reverse harvest index stays accurate on the next lookup")
    now = now + 5
    check(SM.BeginPendingRefine(slots.main[3]) == true, "refine of the crit plant arms")
    eq(SM._pendingRefine and SM._pendingRefine.expectedSeedUid, 0,
        "harvest sibling is not the expected seed")
    slots.main[3] = nil
    slots.main[4] = makeItem(S2, "Sweet Grumpleaf Seed", 1, 1, {
        craftingSkillRequirement = 150,
    })
    bump()
    LB.OnUpdateProcessed()
    local row = StockPiler.Knowledge.Refines()[tostring(P2)]
    eq(tonumber(row and row.seedUid), S2, "refine learns the sweet seed")
    check(SM.IsRefineConvertFailed(P2) ~= true, "a refine that worked is not on cooldown")
    check(listHas(SM.GetRefineSeedUidsForPlant(P2), S2), "refine index records the learned seed")
    check(listHas(SM.GetSeedUidsForPlant(P2), S2), "merged lookup includes the refine seed")
    check(listHas(SM.GetSeedUidsForPlant(P2), SEED), "merged lookup still includes the harvest seed")
end

local function testKnownPathAcceptsExactNameSeed()
    reset()
    local plant = makeItem(P2, "Sweet Grumpleaf", 1, 0, { craftingSkillRequirement = 150 })
    slots.main[1] = plant
    slots.main[2] = makeItem(SEED, "Bitter Grumpleaf Seed", 2, 1, {
        craftingSkillRequirement = 100,
    })
    StockPiler.Knowledge.Refines()[tostring(P2)] = {
        plantUid = P2,
        refineAttempts = 1,
        seedUid = SEED,
        seedOut = { [tostring(SEED)] = { samples = 1, qtySum = 1 } },
    }
    SM.InvalidatePlantSeedIndex()
    begin(plant)
    eq(SM._pendingRefine and SM._pendingRefine.expectedSeedUid, SEED,
        "known path watches the observed seed")
    slots.main[1] = nil
    slots.main[3] = makeItem(S2, "Sweet Grumpleaf Seed", 1, 1, {
        craftingSkillRequirement = 150,
    })
    bump()
    LB.OnUpdateProcessed()
    local row = StockPiler.Knowledge.Refines()[tostring(P2)]
    eq(tonumber(row and row.seedUid), S2, "exact-name seed replaces the expected seed")
    check(SM.IsRefineConvertFailed(P2) ~= true, "exact-name gain is not a failed convert")
    check(listHas(SM.GetRefineSeedUidsForPlant(P2), S2), "refine index follows the new seed")
end

local function testItemSkillReqTreatsZeroAsMissing()
    eq(SM.ItemSkillReq({ craftingSkillRequirement = 0, skillReq = 150 }), 150,
        "zero crafting requirement falls through to skillReq")
    eq(SM.ItemSkillReq({ craftingSkillRequirement = 0, bonuses = { [9] = 80 } }), 80,
        "zero requirement uses bonus 9")
    eq(SM.ItemSkillReq({ craftingSkillRequirement = 40, skillReq = 150 }), 40,
        "a positive requirement wins")
end

local function testPlantFeedstockUsesLearnedRequirement()
    load_module("Source/SkillUp.lua")
    local plant = P2
    local seed = S2
    reset()
    StockPiler.Account.items[tostring(plant)] = {
        uniqueID = plant,
        name = "Sweet Grumpleaf",
        craftingSkillRequirement = 150,
    }
    slots.main[1] = makeItem(seed, "Sweet Grumpleaf Seed", 1, 1, {
        craftingSkillRequirement = 0,
        skillReq = 100,
    })
    StockPiler.SeedEconomy = {
        GetSeedBudget = function()
            return { headroom = 7 }
        end,
    }
    StockPiler.Watch = {
        GetWatches = function()
            return {}
        end,
        GetGen = function()
            return 1
        end,
    }
    check(StockPiler.Inventory.GetByUid == nil, "inventory has no GetByUid")
    local reserve = StockPiler.SkillUp.PlantFeedstockReserve(seed, plant)
    eq(reserve, 0, "learned plant requirement rejects a lower seed cushion")
    StockPiler.Account.items[tostring(plant)].craftingSkillRequirement = 100
    StockPiler.SkillUp._watchReserveCache = nil
    reserve = StockPiler.SkillUp.PlantFeedstockReserve(seed, plant)
    eq(reserve, 7, "matching skill requirement keeps the seed cushion")
end

testSiblingHarvestDoesNotStealRefine()
testKnownPathAcceptsExactNameSeed()
testItemSkillReqTreatsZeroAsMissing()
testPlantFeedstockUsesLearnedRequirement()

if failures > 0 then
    io.stderr:write(string.format("%d/%d checks failed\n", failures, checks))
    os.exit(1)
end
print(string.format("refine_unknown_learn: %d checks passed", checks))
