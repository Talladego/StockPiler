-- Upgrade Seeds at the Cult floor: SkillUp yield, buffer planting, and L1 buy.
-- Run: lua5.1 tests/upgrade_cult_floor.lua

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

local function check(ok, msg)
    checks = checks + 1
    if not ok then
        failures = failures + 1
        io.stderr:write("FAIL ", msg, "\n")
    end
end

function towstring(s)
    return tostring(s)
end

local cultSkill = 25
local snap = 1
local watchGen = 1
local counts = {}
local credit = {}
local headroom = {}
local bufferMin = 5
local bufferOn = true
local emptyPlots = 3
local refinable = 0
local plantHave = 40
local watches = {}
local growPlant = true
local activeLadder = nil
local groundCredit = {}

local L1_SEED = 3010001
local L1_PLANT = 4010001
local L25_SEED = 3010025
local L25_PLANT = 4010025
local L200_SEED = 3010200
local L200_PLANT = 4010200

local function rung(req, seedUid, plantUid)
    return { skillReq = req, seedUid = seedUid, plantUid = plantUid }
end

local function floorLadder()
    return {
        key = "goldweed|main|0",
        genus = "goldweed",
        role = "main",
        rungs = {
            rung(1, L1_SEED, L1_PLANT),
            rung(25, L25_SEED, L25_PLANT),
        },
    }
end

local function sparseLadder()
    return {
        key = "goldweed|main|0",
        genus = "goldweed",
        role = "main",
        rungs = {
            rung(1, L1_SEED, L1_PLANT),
            rung(200, L200_SEED, L200_PLANT),
        },
    }
end

local function countOf(uid)
    return tonumber(counts[tonumber(uid) or 0]) or 0
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
        GetCultSkill = function() return cultSkill end,
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
                seedUid = tonumber(opts.seedUid) or 0,
                deficit = tonumber(opts.deficit) or 0,
                upgradeSeed = opts.upgradeSeed == true,
                skillReq = tonumber(opts.skillReq) or 0,
                familyKey = opts.familyKey,
                spec = opts.spec,
            }
        end,
    },
    Inventory = {
        GetSnapGen = function() return snap end,
        CountByUid = function(uid) return countOf(uid) end,
        GetSample = function(uid)
            uid = tonumber(uid) or 0
            if countOf(uid) < 1 and uid ~= L1_PLANT then
                return nil
            end
            return { uniqueID = uid, name = "Goldweed", craftingSkillRequirement = 1 }
        end,
        ForEachItem = function() end,
    },
    Items = {
        ToSpec = function(uid)
            uid = tonumber(uid) or 0
            local level = 1
            if uid == L25_SEED or uid == L25_PLANT then
                level = 25
            elseif uid == L200_SEED or uid == L200_PLANT then
                level = 200
            end
            return { skillLevel = level, name = "Goldweed", role = "main" }
        end,
    },
    Catalog = {
        PlantHave = function() return plantHave end,
    },
    Grow = {
        CountEmptyPlots = function() return emptyPlots end,
        CountSeedPlotCredit = function(uid)
            return tonumber(groundCredit[tonumber(uid) or 0]) or 0
        end,
    },
    Refine = {
        GetSeedBudget = function(uid)
            uid = tonumber(uid) or 0
            local live = countOf(uid)
            local cred = credit[uid]
            if cred == nil then
                cred = live
            end
            return {
                live = live,
                ground = 0,
                outstanding = 0,
                credit = cred,
                headroom = tonumber(headroom[uid]) or 0,
                bufferMin = bufferMin,
            }
        end,
        CountRefinablePlants = function()
            return refinable
        end,
        MarkRefineDue = function() end,
    },
    Watch = {
        GetGen = function() return watchGen end,
        IsAutoGrowEnabled = function() return true end,
        IsAutoBuyEnabled = function() return true end,
        IsSeedBufferEnabled = function() return bufferOn == true end,
        GetSeedBufferMin = function() return bufferMin end,
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
        BestUpgradePlantOnLadder = function(ladder, cap, ownedSeedReq)
            cap = tonumber(cap) or 0
            ownedSeedReq = tonumber(ownedSeedReq) or 0
            if refinable < 1 or type(ladder) ~= "table" or type(ladder.rungs) ~= "table" then
                return nil
            end
            local best = nil
            for i = 1, #ladder.rungs do
                local row = ladder.rungs[i]
                local req = tonumber(row.skillReq) or 0
                local plantUid = tonumber(row.plantUid) or 0
                if req > ownedSeedReq and req <= cap and plantUid > 0 and countOf(plantUid) >= 1 then
                    best = {
                        seedUid = tonumber(row.seedUid) or 0,
                        plantUid = plantUid,
                        skillReq = req,
                        refinable = refinable,
                    }
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

local function cacheKey()
    local cult = math.floor((tonumber(cultSkill) or 0) / 25)
    return tostring(snap) .. ":" .. tostring(watchGen) .. ":" .. tostring(cult) .. ":true"
end

local function pinTargets(list)
    US._upgradeTargetsCache = list
    US._upgradeTargetsKey = cacheKey()
end

local function nextFrame()
    StockPiler.FrameCounter = (tonumber(StockPiler.FrameCounter) or 0) + 1
    snap = snap + 1
    US._ownedSeedByKey = nil
    US._scanPlantByKey = nil
    US._activelyClimbingFrame = nil
    US._activelyClimbingCached = nil
    US._active = nil
end

local function clearBags()
    counts = {}
    credit = {}
    headroom = {}
    groundCredit = {}
    refinable = 0
end

local function watchL1(enabled)
    watches = {
        ["plant:4010001"] = {
            enabled = enabled ~= false,
            targetStock = 40,
        },
    }
end

-- #51: a cached Cult-floor buffer fill does not block SkillUp.
cultSkill = 25
clearBags()
counts[L25_SEED] = 1
credit[L25_SEED] = 1
watches = {}
activeLadder = floorLadder()
nextFrame()
pinTargets({
    {
        needReq = 25,
        haveReq = 25,
        plantUid = L25_PLANT,
        seedUid = L25_SEED,
        ladder = activeLadder,
        familyKey = activeLadder.key,
        watchPlantUid = L1_PLANT,
    },
})
eq(US.IsActivelyClimbingPlantWatches(), false, "owned Cult-floor seed does not block SkillUp")

-- Next known rung above ClimbCap is not climb work either.
nextFrame()
pinTargets({
    {
        needReq = 200,
        haveReq = 1,
        ladder = sparseLadder(),
        plantUid = L1_PLANT,
        seedUid = L1_SEED,
    },
})
counts[L1_SEED] = 1
eq(US.IsActivelyClimbingPlantWatches(), false, "a need above ClimbCap does not block SkillUp")

-- A rung still below the cap does block SkillUp.
nextFrame()
clearBags()
counts[L1_SEED] = 2
activeLadder = floorLadder()
pinTargets({
    {
        needReq = 25,
        haveReq = 1,
        ladder = activeLadder,
        plantUid = L1_PLANT,
        seedUid = L1_SEED,
    },
})
eq(US.IsActivelyClimbingPlantWatches(), true, "an owned rung below ClimbCap still blocks SkillUp")

-- need_cult waits on skill and must not yield SkillUp.
nextFrame()
US._upgradeTargetsCache = nil
US._upgradeTargetsKey = nil
US._active = { why = "need_cult", needReq = 50, haveReq = 25 }
eq(US.IsActivelyClimbingPlantWatches(), false, "need_cult does not block SkillUp")

nextFrame()
US._upgradeTargetsCache = nil
US._active = { why = "climbing", needReq = 25, haveReq = 25 }
eq(US.IsActivelyClimbingPlantWatches(), false, "climbing already at ClimbCap does not block SkillUp")

nextFrame()
US._upgradeTargetsCache = nil
US._active = {
    why = "climbing",
    needReq = 25,
    haveReq = 1,
    ladder = floorLadder(),
}
counts[L1_SEED] = 1
counts[L25_SEED] = 0
eq(US.IsActivelyClimbingPlantWatches(), true, "climbing below ClimbCap still blocks SkillUp")

-- Sparse 1 -> 200 at Cult 25 keeps Phase B pending (do not clear via CultMaxNeedReq).
nextFrame()
cultSkill = 25
clearBags()
counts[L1_SEED] = 4
plantHave = 40
bufferOn = true
bufferMin = 5
credit[L1_SEED] = 4
activeLadder = sparseLadder()
watchL1(true)
US._upgradeTargetsCache = nil
US._active = nil
local sparse = US.DescribePlantWatchClimb(L1_PLANT)
eq(sparse.watchedReq, 1, "sparse watch stays on the L1 plant")
eq(sparse.climbNeedReq, 25, "sparse climb need is the Cult floor, not the known L1 rung")
eq(sparse.stocked, true, "sparse watch is stocked")
eq(sparse.pending, true, "sparse L1 climb stays pending until a Cult-floor buffer exists")
eq(US.IsActivelyClimbingPlantWatches(), true, "sparse climb with room under ClimbCap blocks SkillUp")

-- Buffer-only at the Cult floor stays pending for Upgrade Seeds but yields SkillUp.
nextFrame()
clearBags()
counts[L25_SEED] = 1
credit[L25_SEED] = 1
plantHave = 40
activeLadder = floorLadder()
watchL1(true)
US._upgradeTargetsCache = nil
US._active = nil
local floorWatch = US.DescribePlantWatchClimb(L1_PLANT)
eq(floorWatch.pending, true, "Cult-floor buffer stays pending until the seed cushion is full")
eq(floorWatch.arriveNeeded, false, "a stocked watch is not a Phase A arrive")
eq(US.IsActivelyClimbingPlantWatches(), false, "buffer-only at ClimbCap yields SkillUp")

-- #52: refinable destination plants block planting; a short buffer with none plants.
local function floorTarget()
    return {
        spec = { name = "Goldweed" },
        needReq = 25,
        short = 4,
        ladder = floorLadder(),
        plantUid = L25_PLANT,
        seedUid = L25_SEED,
        familyKey = "goldweed|main|0",
        watchPlantUid = L1_PLANT,
    }
end

nextFrame()
cultSkill = 25
clearBags()
counts[L25_SEED] = 2
counts[L25_PLANT] = 5
credit[L25_SEED] = 2
refinable = 5
bufferOn = true
bufferMin = 5
emptyPlots = 3
watches = {}
pinTargets({ floorTarget() })
local planted = US.PickPlantJob()
eq(planted, nil, "destination plants are refined before more destination seeds are planted")
eq(US._active and US._active.why, "refining", "refine is the climb while destination plants are in bags")
eq(US.ShouldHoldEmptyPlots({ why = "climbing" }), true, "empty plots stay held while those plants can refine")

nextFrame()
counts[L25_SEED] = 2
counts[L25_PLANT] = 0
credit[L25_SEED] = 2
refinable = 0
pinTargets({ floorTarget() })
local fill = US.PickPlantJob()
eq(fill and fill.seedUid, L25_SEED, "a short Cult-floor buffer plants when nothing can refine")
eq((fill and fill.plantable) >= 1, true, "that plant job uses an empty plot")
eq(US.ShouldHoldEmptyPlots({ why = "climbing" }), false, "plantable destination seeds release empty plots")

nextFrame()
counts[L25_SEED] = 5
credit[L25_SEED] = 5
refinable = 0
pinTargets({ floorTarget() })
eq(US.PickPlantJob(), nil, "a full Cult-floor buffer does not keep planting")
eq(US.ShouldHoldEmptyPlots({ why = "climbing" }), false, "a stuck full buffer does not hold empty plots")

nextFrame()
clearBags()
pinTargets({
    {
        spec = { name = "Mystery" },
        needReq = 25,
        ladder = { key = "x", genus = "x", rungs = {} },
        plantUid = 0,
        seedUid = 0,
        familyKey = "x",
        watchPlantUid = 0,
    },
})
eq(US.ShouldHoldEmptyPlots({ why = "climbing" }), false, "a climb with nothing plantable or refinable releases plots")
eq(US.ShouldHoldEmptyPlots({ why = "need_buy" }), false, "need_buy with no progress releases plots")
eq(US.ShouldHoldEmptyPlots({ why = "no_family" }), false, "no_family with no progress releases plots")
eq(US.ShouldHoldEmptyPlots({ why = "refining" }), true, "an armed refine still holds empty plots")
eq(US.ShouldHoldEmptyPlots({ why = "planting" }), false, "planting does not use the stuck-climb hold")

nextFrame()
counts[L25_SEED] = 2
credit[L25_SEED] = 2
refinable = 0
pinTargets({
    {
        spec = { name = "Mystery" },
        needReq = 25,
        ladder = nil,
        plantUid = 0,
        seedUid = 0,
        watchPlantUid = 0,
    },
    floorTarget(),
})
eq(US.ShouldHoldEmptyPlots({ why = "climbing" }), false, "a sibling that can plant releases empty plots")

-- Higher seed only in plots: fill leftover empties with L1 (same idea as SkillUp).
nextFrame()
cultSkill = 25
clearBags()
counts[L1_SEED] = 5
credit[L1_SEED] = 5
groundCredit[L25_SEED] = 1
emptyPlots = 2
refinable = 0
bufferOn = true
bufferMin = 5
watches = {}
pinTargets({ floorTarget() })
local fillLower = US.PickPlantJob()
eq(fillLower and fillLower.seedUid, L1_SEED, "in-ground L25 still fills empties with L1")
eq((fillLower and fillLower.plantable) >= 1, true, "L1 filler uses an empty plot")

-- #53: wiped L1 still buys from an enabled plant watch when climb targets are empty.
nextFrame()
cultSkill = 25
clearBags()
plantHave = 0
emptyPlots = 2
bufferOn = false
bufferMin = 0
activeLadder = floorLadder()
watchL1(true)
growPlant = true
pinTargets({})
local jobs = US.CollectBuyJobs()
eq(#jobs, 1, "an empty climb list still buys the wiped L1 seed")
eq(jobs[1] and jobs[1].seedUid, L1_SEED, "the buy is the vendor L1 seed")
eq(jobs[1] and jobs[1].upgradeSeed, true, "the buy is marked as an upgrade seed")
eq((jobs[1] and jobs[1].deficit) >= 1, true, "the buy covers the seed deficit")

nextFrame()
counts[L25_SEED] = 1
pinTargets({})
local skipped = US.CollectBuyJobs()
eq(#skipped, 0, "owning past the vendor rung does not buy L1")

nextFrame()
clearBags()
plantHave = 0
watchL1(false)
pinTargets({})
eq(#US.CollectBuyJobs(), 0, "a disabled plant watch does not buy L1")

nextFrame()
watchL1(true)
growPlant = false
pinTargets({})
eq(#US.CollectBuyJobs(), 0, "a plant watch AutoGrow skips does not buy L1")

nextFrame()
growPlant = true
clearBags()
plantHave = 0
emptyPlots = 2
bufferMin = 0
bufferOn = false
pinTargets({
    {
        spec = { name = "Goldweed" },
        needReq = 25,
        ladder = floorLadder(),
        plantUid = L1_PLANT,
        seedUid = L1_SEED,
    },
})
local once = US.CollectBuyJobs()
eq(#once, 1, "the climb target and the plant watch share one L1 buy")
eq(once[1] and once[1].seedUid, L1_SEED, "the shared buy is still the L1 seed")

nextFrame()
counts[L1_SEED] = 3
emptyPlots = 2
headroom[L1_SEED] = 0
bufferMin = 0
bufferOn = false
plantHave = 0
watchL1(true)
pinTargets({})
eq(#US.CollectBuyJobs(), 0, "a filled L1 stack with no headroom is not bought")

-- Empty potion seed-buffer line: climb/buy without SeedBufferOk idle gate.
nextFrame()
clearBags()
watches = {}
growPlant = true
bufferOn = true
bufferMin = 5
credit[L200_SEED] = 0
headroom[L200_SEED] = 5
emptyPlots = 2
activeLadder = sparseLadder()
cultSkill = 200
StockPiler.SeedEconomy.SeedBufferOk = function()
    return false
end
StockPiler.SkillUp = {
    WatchesDone = function()
        return false
    end,
    AllShortWatchesProgressBlocked = function()
        return false
    end,
}
StockPiler.Watch.AllEnabledPotionWatchesStocked = function()
    return true
end
StockPiler.RecipeSpec = {
    BuildBalancedSpecDemand = function()
        return {}
    end,
    CollectAutoGrowSeedLines = function()
        return {
            {
                spec = { name = "Goldweed", skillLevel = 200, role = "main" },
                plantUid = L200_PLANT,
                seedUid = L200_SEED,
            },
        }
    end,
}
StockPiler.SeedMap.IsGrowableSpec = function()
    return true
end
StockPiler.SeedMap.IsHarvestByproduct = function()
    return false
end
StockPiler.SeedMap.FindPlantUidForSpec = function()
    return L200_PLANT
end
StockPiler.SeedMap.ResolveSeedUidForPlant = function()
    return L200_SEED
end
US._upgradeTargetsCache = nil
US._upgradeTargetsKey = nil
local bufJobs = US.CollectBuyJobs()
eq(#bufJobs >= 1, true, "empty potion buffer line AutoBuys L1 while SeedBufferOk is false")
eq(bufJobs[1] and bufJobs[1].seedUid, L1_SEED, "that buy is the L1 vendor seed")

nextFrame()
clearBags()
counts[L1_SEED] = 5
credit[L1_SEED] = 5
headroom[L1_SEED] = 0
credit[L200_SEED] = 0
US._upgradeTargetsCache = nil
US._upgradeTargetsKey = nil
local bufPlant = US.PickPlantJob()
eq(bufPlant and bufPlant.seedUid, L1_SEED, "empty potion buffer climbs by planting owned L1")

-- Partial cushion is Seed buffer maintenance, not a climb or an L1 buy.
nextFrame()
clearBags()
counts[L200_SEED] = 3
credit[L200_SEED] = 3
headroom[L200_SEED] = 2
credit[L1_SEED] = 0
counts[L1_SEED] = 0
US._upgradeTargetsCache = nil
US._upgradeTargetsKey = nil
eq(#US.CollectBuyJobs(), 0, "a partial cult-max cushion does not AutoBuy L1")
eq(US.PickPlantJob(), nil, "a partial cult-max cushion does not start an upgrade plant")

-- Plant watches stay behind the idle gate even when their seed line is empty.
nextFrame()
clearBags()
credit[L200_SEED] = 0
headroom[L200_SEED] = 5
US._upgradeTargetsCache = nil
US._upgradeTargetsKey = nil
StockPiler.RecipeSpec.CollectAutoGrowSeedLines = function()
    return {
        {
            spec = { name = "Goldweed", skillLevel = 200, role = "main" },
            plantUid = L200_PLANT,
            seedUid = L200_SEED,
            plantStock = true,
        },
    }
end
eq(#US.CollectBuyJobs(), 0, "an empty plant-watch buffer line does not bypass the idle gate")
eq(US.PickPlantJob(), nil, "an empty plant-watch buffer line does not plant L1")

if failures > 0 then
    io.stderr:write(string.format("%d/%d checks failed\n", failures, checks))
    os.exit(1)
end
print(string.format("upgrade_cult_floor: %d checks passed", checks))
