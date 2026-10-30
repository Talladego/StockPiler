-- Upgrade Seeds must not buy the basic vendor seed once a higher rung is on hand.
-- The queue line must name that seed when it is not in the bags.
-- Run: lua5.1 tests/upgrade_seed_autobuy.lua

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
function WStringToString(s)
    return tostring(s)
end

wstring = { gsub = string.gsub }

SystemData = {
    Settings = {
        Language = { ENGLISH = 1, active = 1 },
    },
}

local L1_SEED = 3010040
local L1_PLANT = 3020001
local L50_SEED = 3010050
local L50_PLANT = 3020050
local L200_SEED = 84234
local L200_PLANT = 3020048
local ORPHAN_PLANT = 3020099

local cultSkill = 200
local snap = 1
local watchGen = 1
local counts = {}
local ground = {}
local bufferMin = 5
local bufferOn = true
local emptyPlots = 0
local plantHave = 0
local watches = {}
local growPlant = true
local activeLadder = nil
local catalog = {}
local db = {}

local function countOf(uid)
    return tonumber(counts[tonumber(uid) or 0]) or 0
end

local function rung(req, seedUid, plantUid)
    return { skillReq = req, seedUid = seedUid, plantUid = plantUid }
end

local function goldweedLadder()
    return {
        key = "goldweed|main|0",
        genus = "goldweed",
        role = "main",
        rungs = {
            rung(1, L1_SEED, L1_PLANT),
            rung(50, L50_SEED, L50_PLANT),
            rung(200, L200_SEED, L200_PLANT),
            rung(175, 0, ORPHAN_PLANT),
        },
    }
end

StockPiler = {
    FrameCounter = 1,
    Util = {
        ToNarrow = function(v) return tostring(v or "") end,
        NowSec = function() return 1000 end,
        T = function(k) return k end,
        CharacterRow = function()
            return { upgradeSeedsEnabled = true }
        end,
    },
    TradeSkillCaps = {
        CanAutoGrow = function() return true end,
        CanAutoBuy = function() return true end,
        GetCultSkill = function() return cultSkill end,
        LevelsHash = function() return "cult" end,
    },
    SeedEconomy = {
        FloorCultTier = function(c)
            local best = 1
            for _, tier in ipairs({ 1, 25, 50, 75, 100, 125, 150, 175, 200 }) do
                if (tonumber(c) or 0) >= tier then
                    best = tier
                end
            end
            return best
        end,
        SeedBuyJob = function(opts)
            opts = type(opts) == "table" and opts or {}
            return {
                uid = tonumber(opts.seedUid) or 0,
                seedUid = tonumber(opts.seedUid) or 0,
                deficit = tonumber(opts.deficit) or 0,
                upgradeSeed = opts.upgradeSeed == true,
                skillReq = tonumber(opts.skillReq) or 0,
            }
        end,
    },
    Inventory = {
        GetSnapGen = function() return snap end,
        CountByUid = function(uid) return countOf(uid) end,
        GetSample = function(uid)
            uid = tonumber(uid) or 0
            if countOf(uid) < 1 then
                return nil
            end
            return { uniqueID = uid, name = "In Bags", craftingSkillRequirement = 1 }
        end,
        ForEachItem = function() end,
    },
    Items = {
        ToSpec = function(uid)
            uid = tonumber(uid) or 0
            local level = 1
            if uid == L50_PLANT or uid == L50_SEED then
                level = 50
            elseif uid == L200_PLANT or uid == L200_SEED then
                level = 200
            end
            return { skillLevel = level, name = "Goldweed", role = "main" }
        end,
        GetByUid = function(uid)
            return catalog[tonumber(uid) or 0]
        end,
    },
    Catalog = {
        PlantHave = function(uid)
            if uid == L200_PLANT then
                return plantHave
            end
            return countOf(uid)
        end,
    },
    Grow = {
        CountEmptyPlots = function() return emptyPlots end,
        CountSeedPlotCredit = function(uid)
            return tonumber(ground[tonumber(uid) or 0]) or 0
        end,
    },
    Refine = {
        GetSeedBudget = function(uid)
            uid = tonumber(uid) or 0
            local live = countOf(uid)
            return {
                live = live,
                ground = 0,
                outstanding = 0,
                credit = live,
                headroom = 0,
                bufferMin = bufferOn and bufferMin or 0,
            }
        end,
        CountRefinablePlants = function() return 0 end,
    },
    Watch = {
        GetGen = function() return watchGen end,
        IsAutoGrowEnabled = function() return true end,
        IsAutoBuyEnabled = function() return true end,
        IsSeedBufferEnabled = function() return bufferOn == true end,
        GetSeedBufferMin = function() return bufferMin end,
        GetAutoBuyReserveGold = function() return 0 end,
        GetAutoBuyBudgetGold = function() return 50 end,
        GetAutoBuySpentBrass = function() return 0 end,
        GetPlantWatches = function() return watches end,
        GetPlantWatch = function(key) return watches[key] end,
        PlantKeyFromUid = function(uid) return "plant:" .. tostring(uid) end,
        ParsePlantKey = function(key)
            return tonumber(tostring(key):match("(%d+)")) or 0
        end,
        ShouldAutoGrowPlant = function() return growPlant == true end,
    },
    VendorAdapter = { IsStoreOpen = function() return false end },
    SeedMap = {
        LowestBuySeedOnLadder = function(ladder)
            if type(ladder) ~= "table" or type(ladder.rungs) ~= "table" then
                return nil
            end
            for i = 1, #ladder.rungs do
                local row = ladder.rungs[i]
                local seedUid = tonumber(row.seedUid) or 0
                local req = tonumber(row.skillReq) or 0
                if seedUid > 0 and req >= 1 then
                    return {
                        seedUid = seedUid,
                        plantUid = tonumber(row.plantUid) or 0,
                        skillReq = req,
                        familyKey = ladder.key,
                    }
                end
            end
            return nil
        end,
        BestOwnedSeedOnLadder = function(ladder, cap)
            cap = tonumber(cap) or 0
            if type(ladder) ~= "table" or type(ladder.rungs) ~= "table" then
                return nil
            end
            local best = nil
            for i = 1, #ladder.rungs do
                local row = ladder.rungs[i]
                local req = tonumber(row.skillReq) or 0
                local seedUid = tonumber(row.seedUid) or 0
                if req >= 1 and req <= cap and seedUid > 0 and countOf(seedUid) >= 1 then
                    if best == nil or req > best.skillReq then
                        best = {
                            seedUid = seedUid,
                            plantUid = tonumber(row.plantUid) or 0,
                            skillReq = req,
                            count = countOf(seedUid),
                        }
                    end
                end
            end
            return best
        end,
        GetGenusLadderForSpec = function()
            return activeLadder
        end,
    },
}

load_module("Source/UpgradeSeed.lua")
local US = StockPiler.UpgradeSeed

local function pinEmpty()
    local cult = math.floor((tonumber(cultSkill) or 0) / 25)
    US._upgradeTargetsCache = {}
    US._upgradeTargetsKey = tostring(snap) .. ":" .. tostring(watchGen) .. ":"
        .. tostring(cult) .. ":true"
    US._ownedSeedByKey = nil
end

local function nextFrame()
    StockPiler.FrameCounter = (tonumber(StockPiler.FrameCounter) or 0) + 1
    snap = snap + 1
    US._ownedSeedByKey = nil
    US._active = nil
end

local function clearOwned()
    counts = {}
    ground = {}
    plantHave = 0
end

local function watchMajestic()
    watches = {
        ["plant:3020048"] = {
            enabled = true,
            targetStock = 50,
        },
    }
end

local function jobs()
    pinEmpty()
    return US.CollectBuyJobs()
end

cultSkill = 200
bufferOn = true
bufferMin = 5
emptyPlots = 0
growPlant = true
activeLadder = goldweedLadder()
clearOwned()
counts[L200_PLANT] = 31
plantHave = 31
watchMajestic()
nextFrame()
local described = US.DescribePlantWatchClimb(L200_PLANT)
eq(described.watchedReq, 200, "the watch is the top Goldweed tier")
eq(described.arriveNeeded, false, "plants of that tier already arrived")
eq(described.pending, false, "arrival is not a pending climb")
local held = jobs()
eq(#held, 0, "top-tier plants do not queue the basic vendor seed")

nextFrame()
clearOwned()
watchMajestic()
local fresh = jobs()
eq(#fresh, 1, "a family with nothing owned still buys the basic seed")
eq(fresh[1] and fresh[1].seedUid, L1_SEED, "that buy is the vendor seed")
eq(fresh[1] and fresh[1].deficit, 5, "the buy fills the seed buffer")
eq(fresh[1] and fresh[1].upgradeSeed, true, "the buy is an upgrade seed")

nextFrame()
clearOwned()
counts[L50_PLANT] = 4
watchMajestic()
eq(#jobs(), 0, "a mid-tier plant is already past the vendor seed")

nextFrame()
clearOwned()
counts[L1_PLANT] = 6
watchMajestic()
local atVendor = jobs()
eq(#atVendor, 1, "plants of the vendor tier still top up that seed")
eq(atVendor[1] and atVendor[1].seedUid, L1_SEED, "the top-up is still the vendor seed")

nextFrame()
clearOwned()
counts[L1_SEED] = 2
watchMajestic()
local topUp = jobs()
eq(#topUp, 1, "a short stack of the vendor seed is still bought")
eq(topUp[1] and topUp[1].deficit, 3, "the buy is only the seeds still missing")

nextFrame()
clearOwned()
ground[L200_SEED] = 1
watchMajestic()
eq(#jobs(), 0, "an in-ground higher seed does not buy the vendor seed")

nextFrame()
clearOwned()
counts[L200_SEED] = 1
watchMajestic()
eq(#jobs(), 0, "a higher seed in bags does not buy the vendor seed")

nextFrame()
clearOwned()
counts[ORPHAN_PLANT] = 10
watchMajestic()
local orphan = jobs()
eq(#orphan, 1, "a plant with no known seed does not block the vendor seed")
eq(orphan[1] and orphan[1].seedUid, L1_SEED, "that family can still buy the basic seed")

----------------------------------------------------------------
-- Queue chat names a seed that is not in the bags.
----------------------------------------------------------------

local chat = {}
function GetDatabaseItemData(uid)
    return db[tonumber(uid) or 0]
end

StockPiler.Debug = {
    Print = function(msg)
        chat[#chat + 1] = tostring(msg)
    end,
}
StockPiler.Knowledge = {
    GetVendorCost = function()
        return 125
    end,
}
StockPiler.Planner = {
    CollectVendorBuyJobs = function()
        return {}
    end,
    GetPlanGen = function()
        return 1
    end,
}
StockPiler.SkillUp = {
    CollectBuyJobs = function()
        return {}
    end,
}
StockPiler.UpgradeSeed = US

load_module("Source/Locale/Locale.lua")
load_module("Source/Locale/enUS.lua")
load_module("Source/Core/Util.lua")
StockPiler.Locale.SetLanguage(1)
load_module("Source/Core/SeedEconomy.lua")
load_module("Source/Adapters/CraftChatAdapter.lua")
load_module("Source/Buy.lua")

local Buy = StockPiler.Buy
local SE = StockPiler.SeedEconomy

catalog[L1_SEED] = { name = "Prickly Goldweed Seed" }
local named = SE.SeedBuyJob({
    seedUid = L1_SEED,
    deficit = 5,
    upgradeSeed = true,
    skillReq = 1,
})
eq(named.name, "Prickly Goldweed Seed", "a seed buy job keeps the catalog name")
eq(named.uid, L1_SEED, "the job still carries the item id")

local function announce(list)
    chat = {}
    Buy._queueAnnounceKey = nil
    Buy._jobsCache = nil
    Buy._jobsCacheKey = nil
    StockPiler.UpgradeSeed.CollectBuyJobs = function()
        return list
    end
    Buy.NotifyQueueMaybeChanged()
    return chat[#chat] or ""
end

local line = announce({ named })
check(string.find(line, "Prickly Goldweed Seed", 1, true) ~= nil,
    "the queue line names the seed")
check(string.find(line, "[Prickly Goldweed Seed]", 1, true) ~= nil,
    "the queue line links the seed the way a purchase line does")
check(string.find(line, "3010040", 1, true) == nil,
    "the queue line does not print the bare item id")
check(string.find(line, "x5", 1, true) ~= nil, "the queue line keeps the quantity")
check(string.find(line, "6s 25b", 1, true) ~= nil, "the queue line keeps the cost")

catalog[L1_SEED] = nil
db[L1_SEED] = { name = "Database Goldweed Seed" }
local fromDb = SE.SeedBuyJob({ seedUid = L1_SEED, deficit = 5, upgradeSeed = true })
eq(fromDb.name, "Database Goldweed Seed", "a missing catalog row uses the item database")
local dbLine = announce({ { uid = L1_SEED, deficit = 5, upgradeSeed = true } })
check(string.find(dbLine, "Database Goldweed Seed", 1, true) ~= nil,
    "a nameless job still prints the database name")
check(string.find(dbLine, "3010040", 1, true) == nil,
    "a database-backed queue line does not print the bare item id")

if failures > 0 then
    io.stderr:write(string.format("%d/%d checks failed\n", failures, checks))
    os.exit(1)
end
print(string.format("upgrade_seed_autobuy: %d checks passed", checks))
