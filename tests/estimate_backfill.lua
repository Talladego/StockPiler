-- Optimistic empty-plot estimate backfill.
-- Run: lua5.1 tests/estimate_backfill.lua

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

local SEED_UID = 9001
local PLANT_UID = 8001
local POTION_UID = 7001
local optimisticOn = true
local outcomeRate = 0.5
local bagSeeds = 20
local bagPlants = 10
local emptyPlot = true
local snapGen = 1
local planGen = 1
local statsGen = 1
local harvestGen = 0
local bufferShort = false
local bufferPending = false
local clock = 1000
local upgradeEnabled = false
local holdRefine = false
local holdPlots = false
local craftShared = false

StockPiler = {}
StockPiler.Util = {
    NowSec = function() return clock end,
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
    GetSnapGen = function() return snapGen end,
    CountByUid = function(uid)
        uid = tonumber(uid) or 0
        if uid == SEED_UID then
            return bagSeeds
        end
        if uid == PLANT_UID then
            return bagPlants
        end
        return 0
    end,
    GetSample = function()
        return { uniqueID = SEED_UID, name = "Test Seed", craftingSkillRequirement = 1 }
    end,
    CanUseCraftingItem = function() return true end,
}
StockPiler.Watch = {
    IsOptimisticOutcomeEstimate = function()
        return optimisticOn == true
    end,
    IsSeedBufferEnabled = function() return false end,
    GetSeedBufferMin = function() return 5 end,
    IsAutoGrowEnabled = function() return true end,
    CountEnabledPlantWatches = function() return 0 end,
    GetPriorityTier = function() return 1 end,
    EnabledPotionWatchesNeedCultGrow = function() return false end,
    AllEnabledPotionWatchesStocked = function() return true end,
    GetPlantWatches = function() return {} end,
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
StockPiler.Refine = {
    HasAnyBufferShort = function() return bufferShort == true end,
    HasPendingBufferRefine = function() return bufferPending == true end,
}
StockPiler.SkillUp = {
    ShouldCultPlant = function() return false end,
}
StockPiler.PlanSnapshot = {
    Get = function()
        return {
            planGen = planGen,
            rows = {
                {
                    kind = "potion",
                    potionKey = "potion:test",
                    name = "Test Potion",
                    potionMin = 20,
                    potionHave = 0,
                    potionDeficit = 20,
                    craftable = 20,
                    craftableShared = craftShared == true,
                    bottleGap = 0,
                    recipe = {
                        outputUid = POTION_UID,
                        slots = {
                            {
                                perCraft = 1,
                                spec = {
                                    role = "main",
                                    growable = true,
                                    boundUid = PLANT_UID,
                                },
                            },
                        },
                    },
                },
            },
        }
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
    GetRecipeStatsGen = function()
        return statsGen
    end,
    GetHarvestStatsGen = function()
        return harvestGen
    end,
    CraftsNeededForDeficit = function(deficit)
        deficit = math.max(0, tonumber(deficit) or 0)
        return deficit
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
    CountItemsMatchingSpec = function()
        return bagPlants
    end,
    BuildBalancedSpecDemand = function()
        return {}
    end,
    CollectAutoGrowSeedLines = function()
        return {}
    end,
}
StockPiler.SeedMap = {
    GetHarvestStatsGen = function()
        return harvestGen
    end,
    IsGrowableSpec = function() return true end,
    IsHarvestByproduct = function() return false end,
    ResolveSeedForSpec = function()
        return { uniqueID = SEED_UID, plantUid = PLANT_UID }
    end,
    FindPlantUidForSpec = function()
        return PLANT_UID
    end,
    ResolveSeedUidForPlant = function()
        return SEED_UID
    end,
    PlantingsForExpectedPlants = function(seedUid, plantsNeeded, opts)
        plantsNeeded = math.max(0, tonumber(plantsNeeded) or 0)
        opts = type(opts) == "table" and opts or {}
        if opts.force == true and plantsNeeded > 0 then
            return plantsNeeded * 2
        end
        return plantsNeeded
    end,
    EffectiveSeedCredit = function(_, bag)
        return bag
    end,
}
StockPiler.Garden = {
    GetPlots = function()
        if emptyPlot then
            return {
                [1] = { plotNum = 1, stage = 0, seedUid = 0, locked = false },
            }
        end
        return {
            [1] = { plotNum = 1, stage = 2, seedUid = SEED_UID, locked = false },
        }
    end,
    GetPlot = function(n)
        return StockPiler.Garden.GetPlots()[n]
    end,
}
StockPiler.CultivatorAdapter = {
    NumPlots = function() return 1 end,
    StageEmpty = function() return 0 end,
}

load_module("Source/Grow.lua")
local Grow = StockPiler.Grow

-- Helper: measured rate below 1 yields extra crafts; unknown rate does not.
local extraCrafts, expectedCrafts = Grow.EstimateBackfillCraftsExtra(
    { outputUid = POTION_UID }, POTION_UID, 20
)
eq(extraCrafts, 20, "rate 0.5 doubles crafts vs optimistic")
eq(expectedCrafts, 40, "expected crafts is the measured total")
outcomeRate = nil
eq(Grow.EstimateBackfillCraftsExtra({ outputUid = POTION_UID }, POTION_UID, 20), 0,
    "unknown rate yields no speculative extra")
outcomeRate = 1.0
eq(Grow.EstimateBackfillCraftsExtra({ outputUid = POTION_UID }, POTION_UID, 20), 0,
    "perfect rate needs no backfill crafts")
outcomeRate = 0.5

-- Early stocked-plan path: bottleGap 0 + empty plot + Optimistic ON -> backfill.
local job = Grow.PickPlantCandidate()
check(type(job) == "table", "optimistic stocked plan still picks a backfill job")
eq(job and job.plantReason, "estimate_backfill", "plantReason is estimate_backfill")
eq(job and tonumber(job.seedUid), SEED_UID, "backfill uses the growable seed")
eq(job and job.pickMode, "estimate_backfill", "pickMode is estimate_backfill")

-- No brew samples: measured backfill stays idle. Spare seeds still fill one plot.
outcomeRate = nil
job = Grow.PickPlantCandidate()
eq(job and job.plantReason, "fill_all", "unknown rate does not measure-backfill; spare seeds still fill a plot")
eq(job and job.plantable, 1, "fill-all asks for one plot")
outcomeRate = 0.5

-- Optimistic Off: measured backfill stays idle. Spare seeds still fill one plot.
optimisticOn = false
job = Grow.PickPlantCandidate()
eq(job and job.plantReason, "fill_all", "Optimistic Off fills spare plots and does not measure-backfill")
eq(job and job.plantable, 1, "Optimistic Off fill-all asks for one plot")
optimisticOn = true

-- No empty plot: no backfill.
emptyPlot = false
job = Grow.PickPlantCandidate()
eq(job, nil, "full plots skip estimate backfill")
emptyPlot = true

-- No free seeds: do not scan spec item counts.
local specScans = 0
local prevCountSpec = StockPiler.RecipeSpec.CountItemsMatchingSpec
StockPiler.RecipeSpec.CountItemsMatchingSpec = function(...)
    specScans = specScans + 1
    return prevCountSpec(...)
end
bagSeeds = 0
job = Grow.PickPlantCandidate()
eq(job, nil, "no free seeds does not backfill")
eq(specScans, 0, "no free seeds skips the spec item count")
bagSeeds = 20
specScans = 0
job = Grow.PickPlantCandidate()
eq(job and job.plantReason, "estimate_backfill", "free seeds still backfill")
check(specScans >= 1, "free seeds still count matching items")
StockPiler.RecipeSpec.CountItemsMatchingSpec = prevCountSpec

-- Missing cultivator adapter still reports an empty plot.
local savedAdapter = StockPiler.CultivatorAdapter
StockPiler.CultivatorAdapter = nil
eq(Grow.HasEmptyPlot(), true, "HasEmptyPlot works without CultivatorAdapter")
StockPiler.CultivatorAdapter = savedAdapter

-- Upgrade Seed hold blocks the early stocked-plan path and the late path.
upgradeEnabled = true
holdRefine = true
job = Grow.PickPlantCandidate()
eq(job, nil, "NeedsRefineFirst blocks early estimate backfill")
holdRefine = false
holdPlots = true
job = Grow.PickPlantCandidate()
eq(job, nil, "ShouldHoldEmptyPlots blocks early estimate backfill")
holdPlots = false
craftShared = true
holdRefine = true
job = Grow.PickPlantCandidate()
eq(job, nil, "NeedsRefineFirst blocks late estimate backfill")
holdRefine = false
holdPlots = true
job = Grow.PickPlantCandidate()
eq(job, nil, "ShouldHoldEmptyPlots blocks late estimate backfill")
holdPlots = false
job = Grow.PickPlantCandidate()
eq(job and job.plantReason, "estimate_backfill", "late path backfills when the climb is not holding")
upgradeEnabled = false
craftShared = false

-- Nil plant-job cache re-probes only when backfill inputs change.
-- No bag seeds, so fill-all is idle too and the answer stays nil.
outcomeRate = nil
bagSeeds = 0
Grow.InvalidatePlantQueue({ reason = "test" })
local picks = 0
local realPick = Grow.PickPlantCandidate
Grow.PickPlantCandidate = function(...)
    picks = picks + 1
    return realPick(...)
end
eq(Grow.GetPlantJob(), nil, "unknown rate caches a nil plant job")
eq(picks, 1, "the first nil probe runs PickPlantCandidate")
clock = 1005
eq(Grow.GetPlantJob(), nil, "an unchanged nil stays cached")
eq(picks, 1, "two seconds later does not re-probe unchanged inputs")
snapGen = 2
clock = 1006
eq(Grow.GetPlantJob(), nil, "a snap change still has no backfill job")
eq(picks, 2, "a snap change re-probes once")
statsGen = 4
clock = 1007
eq(Grow.GetPlantJob(), nil, "a stats change inside the cooldown stays cached")
eq(picks, 2, "the cooldown holds a second input change")
clock = 1009
eq(Grow.GetPlantJob(), nil, "after the cooldown the new stats gen is probed")
eq(picks, 3, "recipeStatsGen re-probes once the cooldown ends")
planGen = 2
clock = 1012
eq(Grow.GetPlantJob(), nil, "a new plan is probed")
eq(picks, 4, "planGen re-probes once")
harvestGen = 2
clock = 1015
eq(Grow.GetPlantJob(), nil, "a harvest stats change is probed")
eq(picks, 5, "harvest stats gen re-probes once")
bufferShort = true
clock = 1018
eq(Grow.GetPlantJob(), nil, "a buffer-short change is probed")
eq(picks, 6, "buffer state re-probes once")
clock = 1022
eq(Grow.GetPlantJob(), nil, "the same buffer state does not re-probe")
eq(picks, 6, "unchanged inputs stay cached after a re-probe")
emptyPlot = false
Grow.InvalidatePlantQueue({ reason = "plots" })
eq(Grow.GetPlantJob(), nil, "a full garden caches nil")
eq(picks, 7, "a full garden probe runs once")
clock = 1026
eq(Grow.GetPlantJob(), nil, "a full garden does not re-probe")
eq(picks, 7, "no empty plot does not re-probe")
emptyPlot = true
clock = 1029
eq(Grow.GetPlantJob(), nil, "an empty plot after a full garden is probed")
eq(picks, 8, "plot state re-probes once")
Grow.PickPlantCandidate = realPick
outcomeRate = 0.5
bufferShort = false

if failures > 0 then
    io.stderr:write(string.format("%d/%d checks failed\n", failures, checks))
    os.exit(1)
end
print(string.format("estimate_backfill: %d checks passed", checks))
