-- Unlinked special ingredients must not recurse between growability and seeds.
-- Run: lua5.1 tests/special_growable_cycle.lua

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

local KURNOUS = 100291
local LINKED_SPECIAL = 1000275
local LINKED_SEED = 4242
local POWDER = 88001
local BLOOD = 88002
local MATCH_SPECIAL = 88011
local MATCH_PLANT = 77001
local MATCH_SEED = 77002
local GOLD = 4001
local GOLD_SEED = 5001
local GORE = 3030238

local snap = 1
local know = 3
local bagWalks = 0

local items = {
    [KURNOUS] = {
        uniqueID = KURNOUS,
        name = "Kurnous' Sapling Essence",
        kind = "mat",
    },
    [LINKED_SPECIAL] = {
        uniqueID = LINKED_SPECIAL,
        name = "Linked Special Leaf",
        kind = "plant",
    },
    [POWDER] = {
        uniqueID = POWDER,
        name = "Red Foxglove Powder",
        kind = "mat",
    },
    [BLOOD] = {
        uniqueID = BLOOD,
        name = "Red Foxglove Bloodseed",
        kind = "seed",
        cultivationType = 1,
    },
    [MATCH_PLANT] = {
        uniqueID = MATCH_PLANT,
        name = "Plain Leaf",
        kind = "plant",
        family = "special",
    },
    [MATCH_SEED] = {
        uniqueID = MATCH_SEED,
        name = "Plain Leaf Seed",
        kind = "seed",
        cultivationType = 1,
    },
    [GOLD] = {
        uniqueID = GOLD,
        name = "Majestic Goldweed",
        kind = "plant",
        family = "stab",
    },
    [GORE] = {
        uniqueID = GORE,
        name = "Brutal Zoic Gore",
        kind = "mat",
        family = "stab",
        isRefinable = false,
    },
}

local grows = {
    [tostring(LINKED_SEED)] = {
        products = { [tostring(LINKED_SPECIAL)] = { uid = LINKED_SPECIAL, samples = 1 } },
    },
    [tostring(MATCH_SEED)] = {
        products = { [tostring(MATCH_PLANT)] = { uid = MATCH_PLANT, samples = 1 } },
    },
    [tostring(GOLD_SEED)] = {
        products = { [tostring(GOLD)] = { uid = GOLD, samples = 2 } },
    },
}

StockPiler = {
    Account = { items = items },
    Knowledge = {
        GetGen = function()
            return know
        end,
        Grows = function()
            return grows
        end,
        Refines = function()
            return {}
        end,
    },
    Items = {
        GetByUid = function(uid)
            return items[tonumber(uid) or 0]
        end,
        AsItemData = function(uid)
            return items[tonumber(uid) or 0]
        end,
    },
    Inventory = {
        GetSnapGen = function()
            return snap
        end,
        GetSample = function(uid)
            return items[tonumber(uid) or 0]
        end,
        ForEachItem = function()
            bagWalks = bagWalks + 1
        end,
    },
    MaterialSpec = {
        ProductMatches = function(item, spec)
            if type(item) ~= "table" or type(spec) ~= "table" then
                return false
            end
            local fam = item.family
            return fam ~= nil and fam == spec.family
        end,
    },
}

load_module("Source/Core/Util.lua")
load_module("Source/Knowledge/MaterialExceptions.lua")
load_module("Source/Knowledge/SeedMap.lua")

local SM = StockPiler.SeedMap

local function seedUidOf(seed)
    if type(seed) ~= "table" then
        return 0
    end
    return tonumber(seed.uniqueID) or tonumber(seed.uid) or 0
end

local function grewBags(fn)
    local before = bagWalks
    local ok, result = pcall(fn)
    return ok, result, bagWalks - before
end

local kurnous = { uid = KURNOUS, role = "main", name = "Kurnous' Sapling Essence" }
local ok, growable, walked = grewBags(function()
    return SM.IsGrowableSpec(kurnous)
end)
check(ok, "unlinked special does not overflow")
eq(growable, false, "unlinked special with no seed is not growable")
eq(walked, 0, "unlinked special growability does not walk the bag")

ok, growable, walked = grewBags(function()
    return SM.ResolveSeedForSpec(kurnous)
end)
check(ok, "resolving an unlinked special does not overflow")
eq(seedUidOf(growable), 0, "unlinked special with no seed resolves no seed")

local powder = { uid = POWDER, role = "main", name = "Red Foxglove Powder" }
ok, growable, walked = grewBags(function()
    return SM.IsGrowableSpec(powder)
end)
check(ok, "special with a learned bloodseed does not overflow")
eq(growable, true, "a related learned seed makes the special growable")
eq(walked, 0, "learned-seed evidence does not walk the bag")

local matched = {
    uid = MATCH_SPECIAL,
    role = "main",
    name = "Vale's Grace Extract",
    family = "special",
}
ok, growable, walked = grewBags(function()
    return SM.IsGrowableSpec(matched)
end)
check(ok, "special with a matching grow does not overflow")
eq(growable, true, "a matching grow seed makes the special growable")
eq(walked, 0, "matching-grow evidence does not walk the bag")
ok, growable = pcall(SM.ResolveSeedForSpec, matched)
check(ok, "resolving a matched special does not overflow")
eq(seedUidOf(growable), MATCH_SEED, "ordinary seed resolution still returns the matching seed")

local linked = { uid = LINKED_SPECIAL, role = "main", name = "Linked Special Leaf" }
ok, growable, walked = grewBags(function()
    return SM.IsGrowableSpec(linked)
end)
check(ok, "a linked special does not overflow")
eq(growable, true, "a linked special stays growable")
eq(walked, 0, "a linked special does not walk the bag")
ok, growable = pcall(SM.ResolveSeedForSpec, linked)
check(ok, "resolving a linked special does not overflow")
eq(seedUidOf(growable), LINKED_SEED, "a linked special still resolves its own seed")

local plant = { uid = GOLD, role = "stabilizer", name = "Majestic Goldweed", family = "stab" }
ok, growable, walked = grewBags(function()
    return SM.IsGrowableSpec(plant)
end)
eq(ok, true, "a linked plant check completes")
eq(growable, true, "a linked plant stays growable")
eq(walked, 0, "a linked plant does not walk the bag")

local butcher = { uid = GORE, role = "stabilizer", name = "Brutal Zoic Gore", family = "stab" }
ok, growable, walked = grewBags(function()
    return SM.IsGrowableSpec(butcher)
end)
eq(ok, true, "a butcher exemplar check completes")
eq(growable, false, "a butcher exemplar stays non-growable")
eq(walked, 0, "butcher growability does not walk the bag")
eq(SM.FindGrowableTwinUid(butcher), GOLD, "the butcher exemplar still finds its plant twin")
ok, growable = pcall(SM.ResolveSeedForSpec, butcher)
check(ok, "resolving a butcher twin does not overflow")
eq(seedUidOf(growable), GOLD_SEED, "a butcher exemplar still resolves the twin seed")

-- A seed lookup that asks growability again must stop, and must not stick.
snap = snap + 1
local origSeeds = SM.GetSeedUidsForPlant
local reentered = 0
SM.GetSeedUidsForPlant = function(uid)
    if uid == POWDER then
        reentered = reentered + 1
        local innerOk, inner = pcall(SM.IsGrowableSpec, powder)
        check(innerOk, "re-entering growability does not overflow")
        eq(inner, false, "an in-progress special is not growable yet")
    end
    return origSeeds(uid)
end
ok, growable, walked = grewBags(function()
    return SM.IsGrowableSpec(powder)
end)
SM.GetSeedUidsForPlant = origSeeds
check(ok, "a cyclic seed lookup does not overflow")
eq(reentered, 1, "the cycle was entered once")
eq(growable, true, "seed evidence still wins after the cycle break")
eq(walked, 0, "the cycle break does not walk the bag")
eq(SM.IsGrowableSpec(powder), true, "the cycle break is not cached as non-growable")

if failures > 0 then
    io.stderr:write(string.format("%d/%d checks failed\n", failures, checks))
    os.exit(1)
end
print(string.format("special_growable_cycle: %d checks passed", checks))
