-- Shared-output watches, covered-plant reserve, have-cache, resin inflation.
-- Run: lua5.1 tests/planner_watches.lua

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
function GetGameTime()
    return 1000
end

local H = {}
H.items = {}
H.watches = {}
H.recipes = {}
H.snap = 1

StockPiler = {}
StockPiler.T = function(k)
    return tostring(k)
end
StockPiler.Util = {
    ToNarrow = function(v)
        return tostring(v or "")
    end,
    CharacterRow = function()
        return {}
    end,
}
StockPiler.TradeSkillCaps = {
    CanAutoGrow = function() return true end,
    CanBrewPotions = function() return true end,
    GetCultSkill = function() return 200 end,
    GetApoSkill = function() return 200 end,
}

local function bagCount(spec)
    local n = 0
    for _, it in ipairs(H.items) do
        if it.matches and it.matches[spec.key] then
            n = n + it.stackCount
        end
    end
    return n
end

local function craftsPossible(recipe)
    local best = math.huge
    for _, s in ipairs(recipe.slots) do
        best = math.min(best, math.floor(bagCount(s.spec) / s.perCraft))
    end
    if best == math.huge then
        return 0
    end
    return best
end

StockPiler.Inventory = {
    _ready = true,
    GetSnapGen = function() return H.snap end,
    ForEachItem = function(fn)
        for _, it in ipairs(H.items) do
            fn(it)
        end
    end,
    CanUseCraftingItem = function() return true end,
    CountByUid = function(uid)
        local n = 0
        for _, it in ipairs(H.items) do
            if it.uniqueID == uid then
                n = n + it.stackCount
            end
        end
        return n
    end,
}

StockPiler.MaterialSpec = {
    Key = function(spec) return spec.key end,
    ProductKey = function(x) return x.pk or x.key or "" end,
    ProductMatches = function(item, spec)
        return item.matches ~= nil and item.matches[spec.key] == true
    end,
    IsSeedOrSpore = function() return false end,
    Label = function(spec) return spec.key end,
}

StockPiler.SeedMap = {
    IsGrowableSpec = function(spec) return spec.growable == true end,
    IsHarvestByproduct = function(spec) return spec.byproduct == true end,
    FindPlantUidForSpec = function(spec) return spec.plantUid or 0 end,
    ResolveSeedForSpec = function(spec)
        if (spec.seedUid or 0) > 0 then
            return { uniqueID = spec.seedUid, plantUid = spec.plantUid }
        end
        return nil
    end,
}

StockPiler.RecipeSpec = {
    RecipeSpecForPotion = function(k) return H.recipes[k] end,
    HydrateRecipeSlots = function() end,
    CountItemsMatchingSpec = function(spec) return bagCount(spec) end,
    CountCraftsPossible = function(recipe) return craftsPossible(recipe) end,
    StableCraftYield = function(recipe) return recipe.recipeYield end,
    CraftsNeededForDeficit = function(d, recipe) return math.ceil(d / recipe.recipeYield) end,
    EffectiveSpecPerCraft = function(slot) return slot.perCraft end,
    ResolveWatchPotion = function(k)
        local r = H.recipes[k]
        if not r then
            return nil
        end
        return {
            potion = { name = k, outputUid = r.out },
            outputUid = r.out,
            potionKey = "uid:" .. r.out,
        }
    end,
    ShouldAutoGrowPotion = function(k, w)
        w = w or H.watches[k]
        return type(w) == "table" and w.enabled == true and w.autoGrow == true
    end,
}

StockPiler.Watch = {
    GetWatches = function() return H.watches end,
    GetGen = function() return 1 end,
    IsAutoGrowEnabled = function() return true end,
    IsAutoBuyEnabled = function() return true end,
    IsSeedBufferEnabled = function() return false end,
    IsOptimisticOutcomeEstimate = function() return true end,
    ResolveWatchEntry = function(k) return H.watches[k], k end,
    GetPriorityTier = function(k)
        local w = H.watches[k]
        return w and w.priorityTier or 1
    end,
}

load_module("Source/Stores/PlanSnapshotStore.lua")
load_module("Source/Planner/Planner.lua")
local P = StockPiler.Planner

local function reset()
    P._specHaveCache = nil
    P._specHaveSnapGen = nil
    P._specHaveWarmedSnap = nil
    P._demandCache = nil
    P._demandCacheKey = nil
    P._autoBuyFocusCache = nil
    P._autoBuyFocusKey = nil
    P._autoGrowFocusCache = nil
    P._autoGrowFocusKey = nil
    P._fullCacheBase = nil
    if StockPiler.PlanSnapshot then
        StockPiler.PlanSnapshot._plan = nil
        StockPiler.PlanSnapshot._cacheKey = nil
    end
    H.snap = H.snap + 1
end

local function jobByKey(jobs)
    local map = {}
    for _, j in ipairs(jobs) do
        map[j.specKey] = j
    end
    return map
end

local function testSameOutput()
    local flask = { key = "flask", role = "container" }
    local herbA = { key = "herbA", role = "main", growable = true }
    local herbB = { key = "herbB", role = "main", growable = true }
    H.items = {}
    H.watches = {
        ["uid:7|rk:a"] = { enabled = true, autoGrow = true, targetStock = 40, priorityTier = 1 },
        ["uid:7|rk:b"] = { enabled = true, autoGrow = true, targetStock = 40, priorityTier = 2 },
    }
    H.recipes = {
        ["uid:7|rk:a"] = {
            recipeKey = "ra", recipeYield = 5, out = 7,
            slots = {
                { spec = herbA, perCraft = 1, role = "main" },
                { spec = flask, perCraft = 1, role = "container" },
            },
        },
        ["uid:7|rk:b"] = {
            recipeKey = "rb", recipeYield = 5, out = 7,
            slots = {
                { spec = herbB, perCraft = 1, role = "main" },
                { spec = flask, perCraft = 1, role = "container" },
            },
        },
    }
    reset()
    local d = P.BuildBalancedSpecDemand()
    eq(d.flask and d.flask.absolute, 8, "one flask target for the shared potion")
    eq(d.herbA and d.herbA.absolute, 8, "higher-priority herb is grown")
    eq(d.herbB, nil, "lower-priority recipe is not grown")
    local jobs = jobByKey(P.CollectVendorBuyJobs({ allowPlantBuys = true }))
    eq(jobs.flask and jobs.flask.need, 8, "flask is bought once")
    eq(jobs.herbA and jobs.herbA.need, 8, "priority herb is bought")
    eq(jobs.herbB, nil, "other recipe herb is not bought")
end

local function testCoveredReserve()
    local plant = {
        key = "plantP", role = "main", growable = true,
        plantUid = 500, seedUid = 501, skillLevel = 100,
    }
    local resin = { key = "resinR", role = "stabilizer", byproduct = true, skillLevel = 100 }
    H.items = { { uniqueID = 500, stackCount = 12, matches = { plantP = true } } }
    H.watches = {
        ["uid:1"] = { enabled = true, autoGrow = true, targetStock = 5, priorityTier = 1 },
        ["uid:2"] = { enabled = true, autoGrow = true, targetStock = 10, priorityTier = 2 },
    }
    H.recipes = {
        ["uid:1"] = {
            recipeKey = "rA", recipeYield = 1, out = 1,
            slots = {
                { spec = plant, perCraft = 1, role = "main" },
                { spec = resin, perCraft = 1, role = "stabilizer" },
            },
        },
        ["uid:2"] = {
            recipeKey = "rB", recipeYield = 1, out = 2,
            slots = { { spec = plant, perCraft = 1, role = "main" } },
        },
    }
    reset()
    local d = P.BuildBalancedSpecDemand()
    local r = d.plantP
    check(type(r) == "table", "plant demand exists")
    eq(r.absolute, 10, "grow absolute is the short watch plus resin convert")
    eq(r.brewAbsolute, 15, "covered watch still reserves its plants")
    eq(r.have, 12, "bag plants are counted")
    eq(r.deficit, 0, "grow deficit follows absolute")
    check((r.have - r.brewAbsolute) <= 0, "reserved plants are not surplus")
    eq(d._resinFeedstock, false, "covered plants are not resin feedstock")
end

local function testWarmHave()
    local complete = { key = "ts:4|st:1|lv:100|role:main|fx:55", role = "main" }
    local incomplete = {
        key = "ts:4|st:1|lv:100|role:main|uid:3030027",
        role = "main",
        incomplete = true,
        boundUid = 3030027,
    }
    H.items = {
        {
            uniqueID = 3030099,
            stackCount = 10,
            pk = complete.key,
            matches = { [complete.key] = true, [incomplete.key] = true },
        },
    }
    H.watches = {
        ["uid:1"] = { enabled = true, autoGrow = true, targetStock = 10 },
        ["uid:2"] = { enabled = true, autoGrow = true, targetStock = 10 },
    }
    H.recipes = {
        ["uid:1"] = {
            recipeKey = "rA", recipeYield = 1, out = 1,
            slots = { { spec = complete, perCraft = 1, role = "main" } },
        },
        ["uid:2"] = {
            recipeKey = "rB", recipeYield = 1, out = 2,
            slots = { { spec = incomplete, perCraft = 1, role = "main" } },
        },
    }
    reset()
    P.WarmSpecHaveCacheForWatches()
    eq(P.CountItemsMatchingSpec(complete), 10, "complete spec is warmed")
    eq(P.CountItemsMatchingSpec(incomplete), 10, "matching stub is warmed too")
end

local function testResinInflation()
    local plant = {
        key = "plantP", role = "main", growable = true,
        plantUid = 500, seedUid = 501, skillLevel = 100,
    }
    local resin = { key = "resinR", role = "stabilizer", byproduct = true, skillLevel = 100 }
    local flask = { key = "flask", role = "container" }
    local function recipe(rk, out)
        return {
            recipeKey = rk, recipeYield = 1, out = out,
            slots = {
                { spec = plant, perCraft = 1, role = "main" },
                { spec = resin, perCraft = 1, role = "stabilizer" },
                { spec = flask, perCraft = 1, role = "container" },
            },
        }
    end
    H.items = { { uniqueID = 600, stackCount = 15, matches = { resinR = true } } }
    H.watches = {
        ["uid:1"] = { enabled = true, autoGrow = true, targetStock = 10 },
        ["uid:2"] = { enabled = true, autoGrow = true, targetStock = 10 },
    }
    H.recipes = { ["uid:1"] = recipe("rA", 1), ["uid:2"] = recipe("rB", 2) }
    reset()
    local d = P.BuildBalancedSpecDemand()
    eq(d.resinR.deficit, 5, "pooled resin short is 5")
    eq(d.plantP.byproductConvertExtra, 5, "plant convert uses the pooled short once")
    eq(d.plantP.absolute, 25, "convert is added to the grow target")
    eq(d.plantP.brewAbsolute, 20, "convert does not raise the brew reserve")

    H.items = {}
    H.watches = {
        ["uid:7|rk:a"] = { enabled = true, autoGrow = true, targetStock = 10, priorityTier = 1 },
        ["uid:7|rk:b"] = { enabled = true, autoGrow = true, targetStock = 10, priorityTier = 2 },
    }
    H.recipes = { ["uid:7|rk:a"] = recipe("ra", 7), ["uid:7|rk:b"] = recipe("rb", 7) }
    reset()
    d = P.BuildBalancedSpecDemand()
    eq(d.resinR.absolute, 10, "same potion resin is grouped")
    eq(d.resinR.deficit, 10, "grouped resin short is one target")
    eq(d.plantP.byproductConvertExtra, 10, "convert runs once for the group")
    eq(d.plantP.absolute, 20, "plant target is one recipe plus one convert")
    eq(d.plantP.brewAbsolute, 10, "brew reserve stays the grouped craft need")
end

testSameOutput()
testCoveredReserve()
testWarmHave()
testResinInflation()

if failures > 0 then
    io.stderr:write(string.format("%d/%d checks failed\n", failures, checks))
    os.exit(1)
end
print(string.format("planner_watches: %d checks passed", checks))
