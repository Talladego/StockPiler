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

StockPiler = {}
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
    IsEnabled = function() return false end,
}
StockPiler.Refine = {}
StockPiler.SkillUp = {
    ShouldCultPlant = function() return false end,
}
StockPiler.PlanSnapshot = {
    Get = function()
        return {
            planGen = 1,
            rows = {
                {
                    kind = "potion",
                    potionKey = "potion:test",
                    name = "Test Potion",
                    potionMin = 20,
                    potionHave = 0,
                    potionDeficit = 20,
                    craftable = 20,
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
eq(Grow.EstimateBackfillCraftsExtra({ outputUid = POTION_UID }, POTION_UID, 20), 20,
    "rate 0.5 doubles crafts vs optimistic")
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

-- No samples: no backfill.
outcomeRate = nil
job = Grow.PickPlantCandidate()
eq(job, nil, "unknown rate does not backfill empty plots")
outcomeRate = 0.5

-- Optimistic Off: no estimate backfill stage.
optimisticOn = false
job = Grow.PickPlantCandidate()
eq(job, nil, "Optimistic Off does not use estimate backfill")
optimisticOn = true

-- No empty plot: no backfill.
emptyPlot = false
job = Grow.PickPlantCandidate()
eq(job, nil, "full plots skip estimate backfill")
emptyPlot = true

if failures > 0 then
    io.stderr:write(string.format("%d/%d checks failed\n", failures, checks))
    os.exit(1)
end
print(string.format("estimate_backfill: %d checks passed", checks))
