-- Garden fill-all: spare seeds fill every free plot for watched recipes.
-- Run: lua5.1 tests/garden_fill_all.lua

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
    CultivationStage = { EMPTY = 0, GROWN = 4 },
    CultivationTypes = { NONE = 0, SEED = 1 },
}

local SEED_A = 100
local SEED_B = 200
local PLANT_A = 10
local PLANT_B = 20

local seeds = {}
local plantBags = {}
local variants = {}
local plots = {}
local rows = {}
local outcomeRate = 0.5
local harvestRate = nil
local bufferOn = false
local bufferMin = 5
local optimisticOn = true
local upgradeEnabled = false
local holdRefine = false
local holdPlots = false
local skillOn = false
local buyCalls = 0
local specScans = 0

local function setPlots(n, groundUid, groundN)
    plots = {}
    groundN = tonumber(groundN) or 0
    local total = n + groundN
    local idx = 1
    for _ = 1, groundN do
        plots[idx] = {
            plotNum = idx,
            stage = 2,
            seedUid = groundUid,
            locked = false,
        }
        idx = idx + 1
    end
    for _ = 1, n do
        plots[idx] = {
            plotNum = idx,
            stage = 0,
            seedUid = 0,
            locked = false,
        }
        idx = idx + 1
    end
    return total
end

local function potionRow(key, name, plantUid, seedUid, deficit, gap)
    return {
        kind = "potion",
        potionKey = key,
        name = name,
        potionMin = deficit,
        potionHave = 0,
        potionDeficit = deficit,
        craftable = deficit,
        bottleGap = gap or 0,
        priorityTier = 1,
        recipe = {
            outputUid = 7000 + plantUid,
            slots = {
                {
                    perCraft = 1,
                    spec = {
                        role = "main",
                        growable = true,
                        boundUid = plantUid,
                        plantUid = plantUid,
                        seedUid = seedUid,
                    },
                },
            },
        },
    }
end

StockPiler = {}
StockPiler.FrameCounter = 1
StockPiler.Util = {
    NowSec = function() return 1000 end,
    ToNarrow = function(v) return tostring(v or "") end,
}
StockPiler.T = function(k) return tostring(k) end
StockPiler.Debug = { LogOp = function() end }
StockPiler.Scheduler = {
    IsSessionSettling = function() return false end,
    RequestCachePrewarm = function() end,
}
StockPiler.Inventory = {
    IsReady = function() return true end,
    GetSnapGen = function() return 1 end,
    CountByUid = function(uid)
        return tonumber(seeds[tonumber(uid) or 0]) or 0
    end,
    GetSample = function(uid)
        return { uniqueID = uid, name = "Seed", craftingSkillRequirement = 1 }
    end,
    CanUseCraftingItem = function() return true end,
}
StockPiler.Watch = {
    IsOptimisticOutcomeEstimate = function()
        return optimisticOn == true
    end,
    IsSeedBufferEnabled = function()
        return bufferOn == true
    end,
    GetSeedBufferMin = function()
        return bufferMin
    end,
    IsAutoGrowEnabled = function() return true end,
    CountEnabledPlantWatches = function() return 0 end,
    GetPriorityTier = function() return 1 end,
    EnabledPotionWatchesNeedCultGrow = function() return false end,
    AllEnabledPotionWatchesStocked = function() return true end,
    GetPlantWatches = function() return {} end,
    ShouldAutoGrowPotion = function() return true end,
}
StockPiler.UpgradeSeed = {
    IsEnabled = function() return upgradeEnabled == true end,
    NeedsRefineFirst = function() return holdRefine == true end,
    ShouldHoldEmptyPlots = function() return holdPlots == true end,
    StatusForWatch = function()
        return { why = "need_cult" }
    end,
    GetActiveStatus = function()
        return { why = "need_cult" }
    end,
    FreshTargetsPending = function() return false end,
}
local function groundPlots(uid)
    local n = 0
    uid = tonumber(uid) or 0
    for i = 1, #plots do
        local row = plots[i]
        if type(row) == "table" and (tonumber(row.seedUid) or 0) == uid and row.stage ~= 0 then
            n = n + 1
        end
    end
    return n
end

StockPiler.Refine = {
    HasAnyBufferShort = function() return false end,
    HasPendingBufferRefine = function() return false end,
    PeekFreshBufferPending = function() return false end,
    -- Same meaning as Refine.GetSeedBudget: headroom is seeds still missing.
    GetSeedBudget = function(seedUid)
        seedUid = tonumber(seedUid) or 0
        local live = tonumber(seeds[seedUid]) or 0
        local ground = groundPlots(seedUid)
        local floor = 0
        if bufferOn == true then
            floor = tonumber(bufferMin) or 5
        end
        local credit = live + ground
        return {
            live = live,
            ground = ground,
            credit = credit,
            bufferMin = floor,
            headroom = math.max(0, floor - credit),
        }
    end,
}
StockPiler.SkillUp = {
    ShouldCultPlant = function()
        return skillOn == true
    end,
    PickPlantJob = function()
        if skillOn == true then
            return { seedUid = 55, plantReason = "skill_up", plantable = 1 }
        end
        return nil
    end,
}
StockPiler.PlanSnapshot = {
    Get = function()
        return { planGen = 1, rows = rows }
    end,
}
StockPiler.MaterialSpec = {
    Key = function(spec)
        return "main:" .. tostring(spec and spec.boundUid or 0)
    end,
    ProductKey = function(spec)
        return "main:" .. tostring(spec and spec.boundUid or 0)
    end,
}
StockPiler.RecipeSpec = {
    ShouldAutoGrowPotion = function() return true end,
    HydrateRecipeSlots = function() end,
    OutcomeSuccessRate = function()
        return outcomeRate
    end,
    GetRecipeStatsGen = function() return 1 end,
    CraftsNeededForDeficit = function(deficit)
        return math.max(0, tonumber(deficit) or 0)
    end,
    ExpectedCraftsForDeficit = function(deficit)
        deficit = math.max(0, tonumber(deficit) or 0)
        if outcomeRate == nil then
            return deficit, nil
        end
        local rate = tonumber(outcomeRate) or 1
        if rate <= 0 then
            rate = 0.01
        end
        return math.max(1, math.ceil(deficit / rate)), rate
    end,
    CountItemsMatchingSpec = function(spec)
        specScans = specScans + 1
        local uid = spec and (tonumber(spec.boundUid) or tonumber(spec.plantUid)) or 0
        return tonumber(plantBags[uid]) or 0
    end,
    BuildBalancedSpecDemand = function()
        return {}
    end,
    CollectAutoGrowSeedLines = function()
        return {}
    end,
    EffectiveSpecPerCraft = function(slot)
        return math.max(1, tonumber(slot and slot.perCraft) or 1)
    end,
}
StockPiler.SeedMap = {
    GetHarvestStatsGen = function() return 1 end,
    IsGrowableSpec = function() return true end,
    IsHarvestByproduct = function() return false end,
    FindPlantUidForSpec = function(spec)
        return tonumber(spec and spec.plantUid) or 0
    end,
    ResolveSeedUidForPlant = function(_, spec)
        return tonumber(spec and spec.seedUid) or 0
    end,
    ResolveSeedForSpec = function(spec)
        local uid = tonumber(spec and spec.seedUid) or 0
        if uid <= 0 then
            return nil
        end
        return { uniqueID = uid, plantUid = tonumber(spec.plantUid) or 0 }
    end,
    GetSeedUidsForPlant = function(plantUid)
        local list = variants[tonumber(plantUid) or 0]
        if type(list) == "table" then
            return list
        end
        return {}
    end,
    HarvestSuccessRate = function()
        return harvestRate
    end,
}
StockPiler.Garden = {
    GetPlots = function()
        return plots
    end,
    GetPlot = function(n)
        return plots[tonumber(n) or 0]
    end,
}
StockPiler.CultivatorAdapter = {
    NumPlots = function()
        return #plots
    end,
    StageEmpty = function() return 0 end,
}
StockPiler.Buy = {
    CollectIntents = function()
        buyCalls = buyCalls + 1
    end,
}

load_module("Source/Grow.lua")
local Grow = StockPiler.Grow

local function resetCursor()
    Grow._fillAllCredit = nil
    Grow._fillAllFp = nil
    Grow._bfScratch = nil
    Grow._bfScratchWatch = nil
    Grow.InvalidatePlantQueue({ reason = "test" })
end

local function occupy(seedUid)
    seedUid = tonumber(seedUid) or 0
    for i = 1, #plots do
        local row = plots[i]
        if type(row) == "table" and row.stage == 0 and row.locked ~= true then
            row.stage = 2
            row.seedUid = seedUid
            seeds[seedUid] = (tonumber(seeds[seedUid]) or 0) - 1
            return true
        end
    end
    return false
end

local function plantAll(limit)
    local jobs = {}
    limit = tonumber(limit) or 8
    for _ = 1, limit do
        local job = Grow.PickPlantCandidate()
        if type(job) ~= "table" then
            break
        end
        jobs[#jobs + 1] = job
        if occupy(job.seedUid) ~= true then
            break
        end
    end
    return jobs
end

-- Perfect brew rate, no harvest samples, Optimistic on. Need 1 still fills 4 plots.
outcomeRate = 1
harvestRate = nil
bufferOn = true
bufferMin = 5
optimisticOn = true
skillOn = false
upgradeEnabled = false
seeds[SEED_A] = 9
seeds[SEED_B] = 0
plantBags[PLANT_A] = 0
plantBags[PLANT_B] = 0
variants[PLANT_A] = { SEED_A }
variants[PLANT_B] = { SEED_B }
rows = { potionRow("potion:a", "Alpha", PLANT_A, SEED_A, 1, 0) }
rows[1].buyQty = 4
setPlots(4, 0, 0)
resetCursor()
buyCalls = 0
local function planBuyQty()
    local n = buyCalls
    for i = 1, #rows do
        local row = rows[i]
        n = n + (tonumber(row.potionDeficit) or 0)
        n = n + (tonumber(row.bottleGap) or 0)
        n = n + (tonumber(row.buyQty) or 0)
    end
    return n
end
local buyBefore = planBuyQty()
local filled = plantAll(6)
eq(#filled, 4, "4 free plots with need 1 fills all 4")
for i = 1, #filled do
    eq(filled[i] and filled[i].plantReason, "fill_all", "plot " .. tostring(i) .. " is fill-all with no measured loss")
    eq(filled[i] and filled[i].seedUid, SEED_A, "plot " .. tostring(i) .. " uses the watched seed")
    eq(filled[i] and filled[i].plantable, 1, "plot " .. tostring(i) .. " plants one seed")
    eq(tonumber(filled[i] and filled[i].craftsShort), 0, "plot " .. tostring(i) .. " is not a buy quantity")
end
eq(seeds[SEED_A], bufferMin, "four plots stop at the seed buffer")
check((tonumber(seeds[SEED_A]) or 0) >= bufferMin, "bag count never drops below the buffer")
eq(buyCalls, 0, "fill-all does not call AutoBuy")
eq(planBuyQty(), buyBefore, "filling plots does not change the plan or buy quantity")
local again = Grow.PickPlantCandidate()
eq(again, nil, "a full garden does not ask for another seed")
eq(planBuyQty(), buyBefore, "a second pick after the fill leaves plan and buy unchanged")
eq(rows[1].buyQty, 4, "the plan buy quantity field is untouched")

-- Fill-all wins over SkillUp while spare seeds remain, and does not dip the buffer.
skillOn = false
outcomeRate = nil
harvestRate = 0.5
bufferOn = true
bufferMin = 5
seeds[SEED_A] = 7
plantBags[PLANT_A] = 4
rows = { potionRow("potion:a", "Alpha", PLANT_A, SEED_A, 4, 0) }
setPlots(6, 0, 0)
resetCursor()
local dipped = plantAll(8)
eq(#dipped, 2, "spare above the buffer fills two plots, not the cushion")
eq(dipped[1] and dipped[1].plantReason, "fill_all", "spare plots are fill-all ahead of SkillUp")
eq(dipped[2] and dipped[2].plantReason, "fill_all", "the second spare plot is fill-all")
eq(seeds[SEED_A], 5, "the seed buffer is left in the bag")
-- SkillUp is armed, but spare seeds still fill plots first.
skillOn = true
seeds[SEED_A] = 7
plantBags[PLANT_A] = 4
setPlots(6, 0, 0)
resetCursor()
local ahead = Grow.PickPlantCandidate()
eq(ahead and ahead.plantReason, "fill_all", "fill-all runs before SkillUp")
occupy(ahead.seedUid)
local second = Grow.PickPlantCandidate()
eq(second and second.plantReason, "fill_all", "the remaining spare seed is still fill-all")
occupy(second.seedUid)
local afterDip = Grow.PickPlantCandidate()
eq(afterDip and afterDip.plantReason, "skill_up", "SkillUp runs once spare seeds are gone")
skillOn = false

-- Harvest loss alone backfills. No brew samples, and a perfect brew rate still counts.
outcomeRate = nil
harvestRate = 0.5
bufferOn = false
seeds[SEED_A] = 10
plantBags[PLANT_A] = 0
rows = { potionRow("potion:a", "Alpha", PLANT_A, SEED_A, 4, 0) }
setPlots(4, 0, 0)
resetCursor()
local harvestJob = Grow.PickPlantCandidate()
eq(harvestJob and harvestJob.plantReason, "estimate_backfill",
    "harvest loss triggers backfill without brew samples")
eq(harvestJob and harvestJob.deficit, 8, "harvest rate converts the plain plant count into plots")

outcomeRate = 1
resetCursor()
harvestJob = Grow.PickPlantCandidate()
eq(harvestJob and harvestJob.plantReason, "estimate_backfill",
    "a perfect brew rate still backfills when harvest loss is known")
outcomeRate = 0.5
harvestRate = nil

-- Two watches on one plant sum need before bag stock is subtracted.
seeds[SEED_A] = 10
plantBags[PLANT_A] = 30
rows = {
    potionRow("potion:a", "Alpha", PLANT_A, SEED_A, 10, 0),
    potionRow("potion:b", "Beta", PLANT_A, SEED_A, 10, 0),
}
setPlots(4, 0, 0)
resetCursor()
local summed = Grow.PickPlantCandidate()
check(type(summed) == "table", "two watches sharing a plant sum need above bag stock")
eq(summed and summed.plantReason, "estimate_backfill", "the summed shortfall is measured backfill")
eq(summed and summed.deficit, 10, "bag stock is subtracted once from the summed need")

-- A bag seed that grows the same plant is accepted when the resolved seed is empty.
variants[PLANT_A] = { SEED_A, SEED_B }
seeds[SEED_A] = 0
seeds[SEED_B] = 8
plantBags[PLANT_A] = 0
harvestRate = nil
outcomeRate = 0.5
rows = { potionRow("potion:a", "Alpha", PLANT_A, SEED_A, 10, 0) }
setPlots(2, 0, 0)
resetCursor()
local variantJob = Grow.PickPlantCandidate()
eq(variantJob and variantJob.seedUid, SEED_B, "a seed variant in bags is accepted")
eq(variantJob and variantJob.plantReason, "estimate_backfill", "the variant covers measured backfill")

-- Plots of every variant count toward ground, so a covered plant is not short.
bufferOn = true
bufferMin = 5
seeds[SEED_A] = 5
seeds[SEED_B] = 0
plantBags[PLANT_A] = 0
outcomeRate = 0.5
harvestRate = nil
rows = { potionRow("potion:a", "Alpha", PLANT_A, SEED_A, 1, 0) }
setPlots(1, SEED_B, 2)
resetCursor()
eq(Grow.PickPlantCandidate(), nil, "variant plots cover the measured need")

-- In-ground plants are discounted by the harvest rate.
variants[PLANT_A] = { SEED_A }
seeds[SEED_A] = 4
bufferOn = true
bufferMin = 4
harvestRate = 0.5
outcomeRate = nil
plantBags[PLANT_A] = 0
rows = { potionRow("potion:a", "Alpha", PLANT_A, SEED_A, 10, 0) }
setPlots(1, SEED_A, 10)
resetCursor()
local discounted = Grow.PickPlantCandidate()
eq(discounted and discounted.plantReason, "estimate_backfill",
    "harvest rate discounts in-ground plants")

-- A short buffer blocks only that seed line.
outcomeRate = 0.5
harvestRate = nil
bufferOn = true
bufferMin = 5
variants[PLANT_A] = { SEED_A }
variants[PLANT_B] = { SEED_B }
seeds[SEED_A] = 2
seeds[SEED_B] = 12
plantBags[PLANT_A] = 20
plantBags[PLANT_B] = 20
rows = {
    potionRow("potion:a", "Alpha", PLANT_A, SEED_A, 10, 0),
    potionRow("potion:b", "Beta", PLANT_B, SEED_B, 10, 0),
}
setPlots(4, 0, 0)
resetCursor()
local shortBefore = seeds[SEED_A]
local lineJobs = plantAll(6)
eq(#lineJobs, 4, "the other buffer line still fills free plots")
local onlyB = true
for i = 1, #lineJobs do
    if lineJobs[i].seedUid ~= SEED_B or lineJobs[i].plantable ~= 1 then
        onlyB = false
    end
end
check(onlyB == true, "a short buffer line is not planted")
eq(seeds[SEED_A], shortBefore, "the short line's bag count is unchanged")
check((tonumber(seeds[SEED_B]) or 0) >= bufferMin, "the filled line stays at or above its buffer")
local budgetA = StockPiler.Refine.GetSeedBudget(SEED_A)
local budgetB = StockPiler.Refine.GetSeedBudget(SEED_B)
check((tonumber(budgetA and budgetA.headroom) or 0) > 0, "headroom > 0 means that line is still short")
check((tonumber(budgetB and budgetB.headroom) or 0) == 0, "the planted line is not short")

-- Spread by need: weight 3 and a satisfied watch (need 0, floor weight 1).
outcomeRate = nil
harvestRate = nil
bufferOn = false
seeds[SEED_A] = 10
seeds[SEED_B] = 10
plantBags[PLANT_A] = 3
plantBags[PLANT_B] = 8
rows = {
    potionRow("potion:a", "Alpha", PLANT_A, SEED_A, 3, 0),
    potionRow("potion:b", "Beta", PLANT_B, SEED_B, 0, 0),
}
setPlots(4, 0, 0)
resetCursor()
local spread = plantAll(6)
eq(#spread, 4, "two watched plants fill four plots")
eq(spread[1] and spread[1].seedUid, SEED_A, "spread pick 1 follows the heavier need")
eq(spread[2] and spread[2].seedUid, SEED_A, "spread pick 2 follows the heavier need")
eq(spread[3] and spread[3].seedUid, SEED_B, "spread pick 3 includes the lighter need")
eq(spread[4] and spread[4].seedUid, SEED_A, "spread pick 4 returns to the heavier need")
eq(spread[1] and spread[1].plantable, 1, "spread plants one plot per job")
eq(spread[3] and spread[3].plantable, 1, "the satisfied watch still gets one plot")

-- The same fill-all decision is cached until the queue is invalidated.
setPlots(4, 0, 0)
seeds[SEED_A] = 10
seeds[SEED_B] = 10
resetCursor()
local cached = Grow.GetPlantJob()
local cachedAgain = Grow.GetPlantJob()
eq(cached, cachedAgain, "GetPlantJob reuses the fill-all pick")
eq(cached and cached.seedUid, SEED_A, "the cached fill-all seed is the heavier need")
Grow.InvalidatePlantQueue({ reason = "plant" })
local nextJob = Grow.GetPlantJob()
eq(nextJob and nextJob.seedUid, SEED_A, "the next plant advances the spread once")

-- Demand path (bottle gap still open) reaches fill-all after lift has nothing to do.
rows = { potionRow("potion:a", "Alpha", PLANT_A, SEED_A, 3, 1) }
plantBags[PLANT_A] = 3
seeds[SEED_A] = 6
seeds[SEED_B] = 0
variants[PLANT_A] = { SEED_A }
setPlots(2, 0, 0)
resetCursor()
local demandJob = Grow.PickPlantCandidate()
eq(demandJob and demandJob.pickMode, "fill_all", "the demand path fills spare plots")
eq(demandJob and demandJob.craftsShort, 0, "demand-path fill-all is not a buy quantity")

-- Optimistic off and an Upgrade Seed hold do not fill plots.
optimisticOn = false
rows = { potionRow("potion:a", "Alpha", PLANT_A, SEED_A, 3, 0) }
resetCursor()
eq(Grow.PickPlantCandidate(), nil, "Optimistic off does not fill-all")
optimisticOn = true
upgradeEnabled = true
holdPlots = true
resetCursor()
eq(Grow.PickPlantCandidate(), nil, "an Upgrade Seed hold blocks fill-all")
holdPlots = false
upgradeEnabled = false

-- No plantable seed does not scan bag plants.
specScans = 0
seeds[SEED_A] = 0
outcomeRate = 0.5
harvestRate = nil
plantBags[PLANT_A] = 0
rows = { potionRow("potion:a", "Alpha", PLANT_A, SEED_A, 10, 0) }
setPlots(1, 0, 0)
resetCursor()
eq(Grow.PickPlantCandidate(), nil, "no free seeds does not backfill")
eq(specScans, 0, "no free seeds skips the bag plant count")

if failures > 0 then
    io.stderr:write(string.format("%d/%d checks failed\n", failures, checks))
    os.exit(1)
end
print(string.format("garden_fill_all: %d checks passed", checks))
