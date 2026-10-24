-- Upgrade Seeds keeps planting a family that can plant.
-- Run: lua5.1 tests/upgrade_seed_sibling.lua

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
function WStringToString(s)
    return tostring(s)
end

StockPiler = {}
StockPiler.FrameCounter = 1
StockPiler.Util = {
    ToNarrow = function(v) return tostring(v or "") end,
    NowSec = function() return 1000 end,
    T = function(k) return k end,
    CharacterRow = function() return { upgradeSeedsEnabled = true } end,
}
StockPiler.TradeSkillCaps = {
    CanAutoGrow = function() return true end,
    GetCultSkill = function() return 160 end,
}
StockPiler.SeedEconomy = {
    FloorCultTier = function(c)
        local best = 1
        for _, t in ipairs({ 1, 25, 50, 75, 100, 125, 150, 175, 200 }) do
            if c >= t then
                best = t
            end
        end
        return best
    end,
}

local bag = {
    { uniqueID = 104, name = "Cloudy Fusk Seed", cultivationType = 1, craftingSkillRequirement = 100, count = 10 },
}
StockPiler.Inventory = {
    GetSnapGen = function() return 7 end,
    CountByUid = function(uid)
        for _, it in ipairs(bag) do
            if it.uniqueID == uid then
                return it.count
            end
        end
        return 0
    end,
    GetSample = function(uid)
        for _, it in ipairs(bag) do
            if it.uniqueID == uid then
                return it
            end
        end
        return nil
    end,
    ForEachItem = function(fn)
        for _, it in ipairs(bag) do
            fn(it)
        end
    end,
}
StockPiler.Watch = {
    GetGen = function() return 3 end,
    IsAutoGrowEnabled = function() return true end,
    IsAutoBuyEnabled = function() return true end,
    IsSeedBufferEnabled = function() return false end,
    GetSeedBufferMin = function() return 0 end,
    GetPlantWatches = function() return {} end,
}
StockPiler.Refine = {
    GetSeedBudget = function(uid)
        local live = StockPiler.Inventory.CountByUid(uid)
        return { live = live, ground = 0, outstanding = 0, credit = live, headroom = 0, bufferMin = 0 }
    end,
    CountRefinablePlants = function() return 0 end,
    MarkRefineDue = function() end,
}
StockPiler.Grow = {
    CountEmptyPlots = function() return 3 end,
    CountSeedPlotCredit = function(uid)
        if uid == 104 then
            return 1
        end
        return 0
    end,
}
StockPiler.VendorAdapter = { IsStoreOpen = function() return false end }

load_module("Source/Knowledge/SeedMap.lua")
load_module("Source/UpgradeSeed.lua")
local US = StockPiler.UpgradeSeed

local fuskLadder = {
    key = "fusk|main|0", genus = "fusk", role = "main",
    rungs = {
        { skillReq = 1, seedUid = 101, plantUid = 201 },
        { skillReq = 25, seedUid = 102, plantUid = 202 },
        { skillReq = 50, seedUid = 103, plantUid = 203 },
        { skillReq = 100, seedUid = 104, plantUid = 204 },
        { skillReq = 150, seedUid = 106, plantUid = 206 },
    },
}
local fuskTarget = {
    spec = { name = "Fusk" }, needReq = 150, short = 10, ladder = fuskLadder,
    plantUid = 206, seedUid = 106, familyKey = fuskLadder.key, watchPlantUid = 0,
}
local orphanTarget = {
    spec = { name = "Mystery Root" }, needReq = 100, short = 3, ladder = nil,
    plantUid = 999, seedUid = 0, familyKey = nil, watchPlantUid = 0,
}

local function setTargets(list)
    local cult = 0
    if US.GetCultSkill then
        cult = math.floor((tonumber(US.GetCultSkill()) or 0) / 25)
    end
    local key = "7:3:" .. tostring(cult) .. ":" .. tostring(US.IsEnabled() == true)
    US._upgradeTargetsCache = list
    US._upgradeTargetsKey = key
end

setTargets({ fuskTarget })
local job = US.PickPlantJob()
eq(job and job.seedUid, 104, "fusk alone plants the seed in the bag")
eq(job and job.plantable, 3, "empty plots stay available")

setTargets({ fuskTarget, orphanTarget })
local job2 = US.PickPlantJob()
eq(job2 and job2.seedUid, 104, "an unplantable sibling does not stop fusk")
eq(job2 == nil, false, "a plant job is still returned")

if failures > 0 then
    io.stderr:write(string.format("%d/%d checks failed\n", failures, checks))
    os.exit(1)
end
print(string.format("upgrade_seed_sibling: %d checks passed", checks))
