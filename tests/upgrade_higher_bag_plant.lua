-- Higher bag plants (Cross) beat lower planted seeds (Fretting) for upgrade scan.
-- Run: lua5.1 tests/upgrade_higher_bag_plant.lua

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

local bag = {
    {
        uniqueID = 84342,
        name = "Cross Marsh Root",
        craftingSkillRequirement = 50,
        isRefinable = true,
        count = 4,
    },
}
local snap = 1
local walks = 0

StockPiler = {
    Util = {
        ToNarrow = function(v) return tostring(v or "") end,
        CharacterRow = function() return {} end,
    },
    Knowledge = {
        GetGen = function() return 1 end,
        Grows = function() return {} end,
        Refines = function() return {} end,
    },
    Inventory = {
        GetSnapGen = function() return snap end,
        GetSample = function(uid)
            for i = 1, #bag do
                if bag[i].uniqueID == uid then
                    return bag[i]
                end
            end
            return nil
        end,
        CountByUid = function(uid)
            for i = 1, #bag do
                if bag[i].uniqueID == uid then
                    return bag[i].count
                end
            end
            return 0
        end,
        ForEachItem = function(fn)
            walks = walks + 1
            for i = 1, #bag do
                fn(bag[i])
            end
        end,
    },
    Refine = {
        CountRefinablePlants = function(plantUid)
            for i = 1, #bag do
                if bag[i].uniqueID == plantUid then
                    return bag[i].count
                end
            end
            return 0
        end,
    },
    Items = {
        ToSpec = function(uid)
            for i = 1, #bag do
                if bag[i].uniqueID == uid then
                    return {
                        name = bag[i].name,
                        skillLevel = bag[i].craftingSkillRequirement,
                        role = "stimulant",
                    }
                end
            end
            return nil
        end,
        GetByUid = function() return nil end,
    },
}

load_module("Source/Knowledge/WaremuPlantSeeds.lua")
load_module("Source/Knowledge/SeedMap.lua")
load_module("Source/UpgradeSeed.lua")
local SM = StockPiler.SeedMap
local US = StockPiler.UpgradeSeed

-- Ladder only knows Fretting so far (crit Cross not linked on a rung yet).
local ladder = {
    key = "marshroot|*|0",
    genus = "marshroot",
    role = "stimulant",
    rungs = {
        { skillReq = 1, seedUid = 84595, plantUid = 84340, name = "Sullen" },
        { skillReq = 25, seedUid = 84596, plantUid = 84341, name = "Fretting" },
    },
}

local up = SM.BestUpgradePlantOnLadder(ladder, 200, 25, {})
check(type(up) == "table", "bag Cross is found as an upgrade plant")
eq(up and up.plantUid, 84342, "upgrade plant is Cross Marsh Root")
eq(up and up.skillReq, 50, "upgrade plant skill is 50")
eq(up and up.seedUid, 84597, "catalog supplies Cross Marshroot Seed")

local none = SM.BestUpgradePlantOnLadder(ladder, 200, 50, {})
eq(none, nil, "owned Cross seed tier does not re-pick Cross plants")
eq(US.BestOwnedReqOnLadder(ladder, 200), 50, "bag Cross counts toward the owned tier")
eq(SM._bagPlantScanCount, 1, "status and climb share one bag walk")

SM.BestUpgradePlantOnLadder(ladder, 200, 25, {})
eq(SM._bagPlantScanCount, 1, "the same inventory does not scan bags again")

snap = 2
SM.BestUpgradePlantOnLadder(ladder, 200, 25, {})
eq(SM._bagPlantScanCount, 2, "a new inventory generation scans once")

bag[#bag + 1] = {
    uniqueID = 900001,
    name = "Lost Marsh Root",
    craftingSkillRequirement = 100,
    isRefinable = true,
    count = 2,
}
snap = 3
eq(US.BestOwnedReqOnLadder(ladder, 200), 50,
    "a same-family bag plant with no seed does not raise the owned tier")

bag = {
    {
        uniqueID = 900001,
        name = "Lost Marsh Root",
        craftingSkillRequirement = 100,
        isRefinable = true,
        count = 2,
    },
}
snap = 4
eq(US.BestOwnedReqOnLadder(ladder, 200), 0,
    "only an unlinked bag plant does not count as an owned tier")

if failures > 0 then
    io.stderr:write(string.format("%d/%d checks failed\n", failures, checks))
    os.exit(1)
end
print(string.format("upgrade_higher_bag_plant: %d checks passed", checks))
