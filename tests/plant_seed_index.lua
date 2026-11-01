-- Merged plant-to-seed lookup is cached. Harvest and refine lists stay separate.
-- Run: lua5.1 tests/plant_seed_index.lua

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

local packetChecks = 0
local grows = {
    ["11"] = { products = { ["21"] = { uid = 21, samples = 3 } } },
}
local refines = {
    ["21"] = { plantUid = 21, seedUid = 31, seedOut = { ["31"] = { samples = 2 } } },
}
StockPiler = {
    Util = { ToNarrow = function(v) return tostring(v or "") end },
    Knowledge = {
        GetGen = function() return 2 end,
        Grows = function() return grows end,
        Refines = function() return refines end,
    },
}

load_module("Source/Knowledge/SeedMap.lua")
local SM = StockPiler.SeedMap
local orig = SM.IsSeedPacketUid
SM.IsSeedPacketUid = function(uid)
    packetChecks = packetChecks + 1
    return orig(uid)
end

local function has(list, uid)
    for i = 1, #list do
        if list[i] == uid then
            return true
        end
    end
    return false
end

local harvest = SM.GetHarvestSeedUidsForPlant(21)
local refine = SM.GetRefineSeedUidsForPlant(21)
check(has(harvest, 11), "harvest index returns the seed that grew the plant")
check(has(refine, 31) and not has(refine, 11), "refine index does not include the harvest seed")
packetChecks = 0
local merged = SM.GetSeedUidsForPlant(21)
check(has(merged, 11) and has(merged, 31), "merged lookup still returns both seeds")
local first = packetChecks
SM.GetSeedUidsForPlant(21)
eq(packetChecks, first, "a second merged lookup does not rescan seeds")

load_module("Source/Knowledge/WaremuPlantSeeds.lua")
local W = StockPiler.WaremuPlantSeeds
local pairCount = 0
for plantUid, seedUid in pairs(W.SEED_FOR_PLANT) do
    pairCount = pairCount + 1
    check(type(plantUid) == "number" and plantUid > 0 and plantUid == math.floor(plantUid),
        "catalog plant id is a positive whole number")
    check(type(seedUid) == "number" and seedUid > 0 and seedUid == math.floor(seedUid),
        "catalog seed id is a positive whole number")
end
eq(pairCount, 107, "catalog lists 107 plant to seed links")
eq(W.SeedUidForPlant(84341), 84596, "Fretting Marsh Root maps to Fretting Marshroot Seed")
eq(W.SeedUidForPlant(0), 0, "a missing plant has no catalog seed")

local fretting = SM.GetSeedUidsForPlant(84341)
check(has(fretting, 84596), "catalog supplies the seed when no harvest link exists")
eq(SM.ResolveSeedUidForPlant(84341), 84596, "resolve uses the catalog seed for Fretting Marsh Root")

local knowGen = 3
StockPiler.Knowledge.GetGen = function()
    return knowGen
end
local snap = 1
StockPiler.Inventory = {
    GetSnapGen = function()
        return snap
    end,
    CountByUid = function(uid)
        if uid == 84341 then
            return 1
        end
        return 0
    end,
    GetSample = function()
        return nil
    end,
}
grows["77701"] = { products = { ["84341"] = { uid = 84341, samples = 1 } } }
knowGen = 4
snap = 2
SM.InvalidatePlantSeedIndex()
local linked = SM.GetSeedUidsForPlant(84341)
eq(linked[1], 77701, "a live harvest link stays ahead of the catalog seed")
check(has(linked, 84596), "the catalog seed remains available beside the live link")
eq(SM.ResolveSeedUidForPlant(84341), 77701, "resolve prefers the live harvest link")

StockPiler.Util.CharacterRow = function()
    return {}
end
load_module("Source/UpgradeSeed.lua")
local orphanLadder = {
    rungs = {
        { skillReq = 25, seedUid = 0, plantUid = 84341 },
    },
}
eq(StockPiler.UpgradeSeed.HaveTargetRung(orphanLadder, 25, 84341, 0), false,
    "a rung with no seed id does not count a plant in bags as arrived")

if failures > 0 then
    io.stderr:write(string.format("%d/%d checks failed\n", failures, checks))
    os.exit(1)
end
print(string.format("plant_seed_index: %d checks passed", checks))
