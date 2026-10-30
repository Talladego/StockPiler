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
            if fn(it) == false then
                return
            end
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
    P._memoSettingsHash = nil
    P._memoSettingsHashClock = nil
    P._memoSettingsHashToken = nil
    if StockPiler.PlanSnapshot then
        StockPiler.PlanSnapshot._plan = nil
        StockPiler.PlanSnapshot._cacheKey = nil
    end
    P._warmHaveSlice = nil
    P._buildSliceCo = nil
    P._buildSliceToken = nil
    P._buildSliceAbort = nil
    P._buildYield = nil
    P._buildSliceSuspended = nil
    P._buildSliceRestarts = nil
    P._buildSliceArmedAt = nil
    P._buildSliceErrorLogged = nil
    P._buildSliceRetryAt = nil
    P._lazyWatchTips = nil
    P.WARM_HAVE_ITEMS_PER_PUMP = nil
    P.BUILD_ROWS_PER_PUMP = nil
    P.BUILD_SLICE_RESTART_CAP = nil
    P.BUILD_SLICE_BUDGET_SEC = nil
    P.BUILD_SLICE_ERROR_BACKOFF_SEC = nil
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

local function testSkillPointKeepsCacheKey()
    local cult, apo = 200, 200
    StockPiler.TradeSkillCaps.GetCultSkill = function()
        return cult
    end
    StockPiler.TradeSkillCaps.GetApoSkill = function()
        return apo
    end
    StockPiler.TradeSkillCaps.CanAutoGrow = function()
        return cult > 0
    end
    StockPiler.TradeSkillCaps.CanBrewPotions = function()
        return apo > 0
    end
    P.OnTradeSkillsChanged()
    local before = P.CacheKeyFromGens()
    cult = 201
    apo = 201
    eq(P.CacheKeyFromGens(), before, "one skill point keeps the plan cache key")
    cult = 0
    -- Same game tick: the live getter changed, and the skill pulse drops the memo.
    P.OnTradeSkillsChanged()
    check(P.CacheKeyFromGens() ~= before, "losing cultivation changes the plan cache key")
    cult = 200
    P.OnTradeSkillsChanged()
end

local function testBuildFlagsClearOnError()
    H.watches = {
        ["uid:1"] = { enabled = true, autoGrow = true, targetStock = 10 },
    }
    H.recipes = {
        ["uid:1"] = {
            recipeKey = "rA", recipeYield = 1, out = 1,
            slots = { { spec = { key = "m", role = "main" }, perCraft = 1, role = "main" } },
        },
    }
    reset()
    local orig = StockPiler.RecipeSpec.HydrateRecipeSlots
    local hydrates = 0
    StockPiler.RecipeSpec.HydrateRecipeSlots = function(...)
        hydrates = hydrates + 1
        if hydrates > 1 then
            error("status-boom")
        end
        return orig(...)
    end
    P._buildRows = { "stuck" }
    P._demandDeferStore = true
    P._demandNeedScratch = { stuck = true }
    local plan = P.Build({ force = true })
    StockPiler.RecipeSpec.HydrateRecipeSlots = orig
    eq(plan, nil, "a failed watch build does not publish")
    eq(P._buildRows, nil, "build rows flag is cleared after an error")
    eq(P._demandDeferStore, nil, "demand defer flag is cleared after an error")
    eq(P._demandNeedScratch, nil, "demand scratch is cleared after an error")
end

local function testNeedSkillClearsWhenApoCrosses()
    local apo = 40
    StockPiler.TradeSkillCaps.GetApoSkill = function()
        return apo
    end
    StockPiler.TradeSkillCaps.GetCultSkill = function()
        return 200
    end
    StockPiler.TradeSkillCaps.CanAutoGrow = function()
        return true
    end
    StockPiler.TradeSkillCaps.CanBrewPotions = function()
        return apo > 0
    end
    StockPiler.RecipeSpec.RecipeSkillRequirements = function(recipe)
        local need = tonumber(recipe and recipe.apoNeed) or 0
        if need <= 0 then
            return nil
        end
        return { apothecary = need, apo = need }
    end
    local mat = { key = "herbGate", role = "main" }
    H.items = { { uniqueID = 42, stackCount = 10, matches = { herbGate = true } } }
    H.watches = {
        ["uid:9"] = { enabled = true, autoGrow = true, targetStock = 4, priorityTier = 1 },
    }
    H.recipes = {
        ["uid:9"] = {
            recipeKey = "r9",
            recipeYield = 1,
            out = 9,
            apoNeed = 75,
            slots = { { spec = mat, perCraft = 1, role = "main" } },
        },
    }
    reset()
    local plan = P.Build({ force = true })
    check(type(plan) == "table" and type(plan.rows) == "table", "plan builds below the recipe skill")
    local row = plan and plan.rows and plan.rows[1]
    eq(row and row.statusKey, "need_skill", "watch is need_skill below the apothecary requirement")
    local gen = plan and plan.planGen
    local key = P.CacheKeyFromGens()
    apo = 41
    local held = P.Build()
    eq(held, plan, "an unrelated skill point reuses the cached plan")
    eq(held and held.planGen, gen, "an unrelated skill point does not rebuild")
    eq(P.CacheKeyFromGens(), key, "an unrelated skill point keeps the cache key")
    eq(held and held.rows[1].statusKey, "need_skill", "need_skill stays until the requirement is met")
    apo = 75
    local crossed = P.Build()
    eq(crossed, plan, "crossing the requirement does not build a new plan")
    eq(crossed and crossed.planGen, gen, "crossing the requirement does not full-rebuild")
    eq(crossed and crossed.rows[1].statusKey, "ready_to_craft",
        "the watch leaves need_skill after the skill-up")
end

local function testColdDemandPlantAndPotion()
    load_module("Source/Grow.lua")
    local Grow = StockPiler.Grow
    local Watch = StockPiler.Watch
    local prevCount = StockPiler.Inventory.CountByUid
    StockPiler.Inventory.CountByUid = function(uid)
        if uid == 3010048 then
            return 5
        end
        return prevCount(uid)
    end
    StockPiler.Inventory.IsReady = function()
        return true
    end
    StockPiler.Items = StockPiler.Items or {}
    StockPiler.Items.ToSpec = function(uid)
        return {
            key = "plant:" .. tostring(uid),
            uid = uid,
            growable = true,
            seedUid = 3010048,
            plantUid = uid,
            role = "ingredient",
        }
    end
    StockPiler.SeedMap.ResolveSeedUidForPlant = function()
        return 3010048
    end
    StockPiler.RecipeSpec.BuildBalancedSpecDemand = function(opts)
        if type(opts) == "table" and opts.cacheOnly == true then
            if type(P._demandCache) == "table" then
                return P._demandCache
            end
            return nil
        end
        return P.BuildBalancedSpecDemand(opts)
    end
    local prewarms = 0
    local demandQueued = false
    StockPiler.FrameWork = {
        EnqueueDemand = function()
            demandQueued = true
        end,
        IsActive = function(id)
            return id == "prewarm-demand" and demandQueued == true
        end,
    }
    StockPiler.Scheduler = {
        RequestCachePrewarm = function()
            prewarms = prewarms + 1
            StockPiler.FrameWork.EnqueueDemand("snap")
        end,
    }
    if StockPiler.PlanSnapshot then
        StockPiler.PlanSnapshot._plan = nil
    end
    P._demandCache = nil
    P._demandCacheKey = nil
    Watch.EnabledPotionWatchesNeedCultGrow = function()
        return false
    end
    Watch.CountEnabledPlantWatches = function()
        return 1
    end
    Watch.ParsePlantKey = function()
        return 3020048
    end
    Watch.GetPlantWatches = function()
        return {
            ["plant:3020048"] = { enabled = true, targetStock = 10 },
        }
    end
    StockPiler.Garden = {
        GetPlots = function()
            return { [1] = { plotNum = 1, stage = 0, seedUid = 0, locked = false } }
        end,
        GetPlot = function()
            return { plotNum = 1, stage = 0, seedUid = 0, locked = false }
        end,
    }
    Grow.InvalidatePlantQueue({ reason = "test" })
    local builds = 0
    local realBuild = P.Build
    P.Build = function(...)
        builds = builds + 1
        return realBuild(...)
    end
    local plantJob = Grow.GetPlantJob()
    eq(plantJob and plantJob.plantReason, "plant_stock",
        "a cold demand cache still returns a plant_stock job")
    eq(plantJob and plantJob.seedUid, 3010048, "plant_stock uses the bag seed")
    eq(builds, 0, "plant_stock does not need a full Planner.Build")

    -- Potion watch only: cold demand returns nil and must not stick on planGen.
    Watch.GetPlantWatches = function()
        return {}
    end
    Watch.CountEnabledPlantWatches = function()
        return 0
    end
    H.watches["uid:9"] = { enabled = true, autoGrow = true, targetStock = 4 }
    local spec = {
        key = "herb",
        growable = true,
        seedUid = 3010048,
        plantUid = 3020048,
        role = "main",
    }
    local recipe = {
        slots = { { role = "main", perCraft = 1, spec = spec } },
        recipeYield = 1,
    }
    local planGen = 46
    StockPiler.PlanSnapshot._plan = {
        planGen = planGen,
        rows = {
            {
                potionKey = "uid:9",
                name = "Tonic",
                potionMin = 4,
                potionHave = 0,
                potionDeficit = 4,
                craftable = 0,
                bottleGap = 4,
                recipe = recipe,
                priorityTier = 1,
            },
        },
    }
    P._demandCache = nil
    Grow.InvalidatePlantQueue({ reason = "test-cold" })
    local cold = Grow.GetPlantJob()
    eq(cold, nil, "a potion watch returns nil while demand is cold")
    check(Grow._plantJobProbed ~= true, "a cold nil is not cached")
    check(Grow._plantNilPlanGen ~= planGen, "a cold nil does not stick across planGen")
    local coldAgain = Grow.GetPlantJob()
    eq(coldAgain, nil, "a second cold probe is still nil")
    check(Grow._plantNilPlanGen ~= planGen, "the second cold nil still does not stick")
    local before = prewarms
    P._demandPrewarmDue = nil
    demandQueued = false
    P.InvalidateFocusCaches()
    check(prewarms > before, "InvalidateFocusCaches schedules demand prewarm")
    check(P._demandPrewarmDue == true, "InvalidateFocusCaches marks demand prewarm due")
    check(P._demandCache == nil, "InvalidateFocusCaches still clears the demand cache")
    P._demandCache = {
        herb = {
            spec = spec,
            specKey = "herb",
            absolute = 4,
            seedUid = 3010048,
            plantUid = 3020048,
            deficit = 4,
            craftsShort = 4,
        },
    }
    local lifted = Grow.GetPlantJob()
    eq(lifted and lifted.plantReason, "potion_stock",
        "a warmed demand cache returns the potion plant job")
    eq(lifted and lifted.seedUid, 3010048, "the potion plant job uses the bag seed")
    eq(StockPiler.PlanSnapshot.Get().planGen, planGen,
        "potion lift does not need a planGen bump")
    eq(builds, 0, "warming demand does not full-build")
    P.Build = realBuild
end

local function rowSig(plan)
    local parts = {}
    local rows = plan and plan.rows or {}
    for i = 1, #rows do
        local row = rows[i]
        if type(row) == "table" then
            parts[#parts + 1] = table.concat({
                tostring(row.potionKey or row.id or ""),
                tostring(row.statusKey or ""),
                tostring(row.craftable or ""),
                tostring(row.potionHave or ""),
                tostring(row.potionDeficit or ""),
            }, "|")
        end
    end
    table.sort(parts)
    return table.concat(parts, ";")
end

local function testWarmHaveSliceMatchesSync()
    local specA = { key = "sliceA", role = "main", slotType = 2, skillLevel = 10 }
    local specB = { key = "sliceB", role = "container", slotType = 5, skillLevel = 10 }
    H.items = {
        { uniqueID = 1, stackCount = 4, pk = "ts:4|st:2|lv:10|role:main", matches = { sliceA = true } },
        { uniqueID = 2, stackCount = 1, pk = "ts:4|st:2|lv:10|role:main", matches = { sliceA = true } },
        { uniqueID = 3, stackCount = 7, pk = "ts:4|st:5|lv:10|role:container", matches = { sliceB = true } },
        { uniqueID = 4, stackCount = 3, pk = "ts:4|st:9|lv:10|role:other", matches = {} },
    }
    H.watches = {
        ["uid:1"] = { enabled = true, autoGrow = true, targetStock = 4 },
    }
    H.recipes = {
        ["uid:1"] = {
            recipeKey = "rSlice", recipeYield = 1, out = 1,
            slots = {
                { spec = specA, perCraft = 1, role = "main" },
                { spec = specB, perCraft = 1, role = "container" },
            },
        },
    }
    reset()
    P.WarmSpecHaveCacheForWatches()
    eq(P.CountItemsMatchingSpec(specA), 5, "sync warm counts both main stacks")
    eq(P.CountItemsMatchingSpec(specB), 7, "sync warm counts the container")
    local syncA = P.CountItemsMatchingSpec(specA)
    local syncB = P.CountItemsMatchingSpec(specB)

    reset()
    P.WARM_HAVE_ITEMS_PER_PUMP = 1
    eq(P.BeginWarmHaveSlice(), "continue", "bag slice has pending specs")
    local steps = 0
    local sawContinue = false
    while steps < 12 do
        steps = steps + 1
        local result = P.FinishWarmHaveSlice()
        if result == "continue" then
            sawContinue = true
            eq(P.IsHaveCacheWarmForSnap(), false, "warm stays cold until the cursor finishes")
        else
            eq(result, "done", "bag slice ends on done")
            break
        end
    end
    check(sawContinue == true, "one item per pump does not finish on the first bag pump")
    eq(P.IsHaveCacheWarmForSnap(), true, "finished slice marks the snap warm")
    eq(P.CountItemsMatchingSpec(specA), syncA, "sliced main total matches the sync walk")
    eq(P.CountItemsMatchingSpec(specB), syncB, "sliced container total matches the sync walk")
end

local function testWarmHaveSliceRestartsOnSnap()
    local specA = { key = "snapA", role = "main", slotType = 2 }
    H.items = {
        { uniqueID = 11, stackCount = 4, pk = "ts:4|st:2|lv:1", matches = { snapA = true } },
        { uniqueID = 12, stackCount = 4, pk = "ts:4|st:2|lv:1", matches = { snapA = true } },
    }
    H.watches = {
        ["uid:1"] = { enabled = true, autoGrow = true, targetStock = 4 },
    }
    H.recipes = {
        ["uid:1"] = {
            recipeKey = "rSnap", recipeYield = 1, out = 1,
            slots = { { spec = specA, perCraft = 1, role = "main" } },
        },
    }
    reset()
    P.WARM_HAVE_ITEMS_PER_PUMP = 1
    eq(P.BeginWarmHaveSlice(), "continue", "snap test starts a bag slice")
    eq(P.FinishWarmHaveSlice(), "continue", "first stack does not commit")
    H.snap = H.snap + 1
    eq(P.FinishWarmHaveSlice(), "done", "a new snap ends the slice")
    eq(P.IsHaveCacheWarmForSnap(), false, "a new snap does not keep a partial warm")
    eq(P.CountItemsMatchingSpec(specA, { cacheOnly = true }), nil, "partial totals are not published")
    eq(P.BeginWarmHaveSlice(), "continue", "the new snap starts a fresh slice")
    local guard = 0
    local result = "continue"
    while result == "continue" and guard < 8 do
        guard = guard + 1
        result = P.FinishWarmHaveSlice()
    end
    eq(result, "done", "the restarted slice finishes")
    eq(P.CountItemsMatchingSpec(specA), 8, "restarted slice counts the whole bag")
end

local function testWarmHaveSlotFilter()
    local main = { key = "filtMain", role = "main", slotType = 2, skillLevel = 20 }
    local vial = { key = "filtVial", role = "container", slotType = 5, skillLevel = 20 }
    local stab = { key = "filtStab", role = "stabilizer", slotType = 1, skillLevel = 20 }
    local openSpec = { key = "filtOpen", role = "ingredient", slotType = 0, skillLevel = 20 }
    local calls = {}
    local prev = StockPiler.MaterialSpec.ProductMatches
    StockPiler.MaterialSpec.ProductMatches = function(item, spec)
        local key = spec and spec.key or "?"
        calls[key] = (calls[key] or 0) + 1
        return prev(item, spec)
    end
    H.items = {
        {
            uniqueID = 21,
            stackCount = 2,
            pk = "ts:4|st:2|lv:20|role:main",
            matches = { filtMain = true, filtVial = true, filtStab = true },
        },
        {
            uniqueID = 22,
            stackCount = 9,
            pk = "ts:4|st:10|lv:20|role:goldweed",
            matches = { filtStab = true, filtMain = true },
        },
    }
    H.watches = {
        ["uid:1"] = { enabled = true, autoGrow = true, targetStock = 1 },
    }
    H.recipes = {
        ["uid:1"] = {
            recipeKey = "rFilt", recipeYield = 1, out = 1,
            slots = {
                { spec = main, perCraft = 1, role = "main" },
                { spec = vial, perCraft = 1, role = "container" },
                { spec = openSpec, perCraft = 1, role = "ingredient" },
                { spec = stab, perCraft = 1, role = "stabilizer" },
            },
        },
    }
    reset()
    P.WarmSpecHaveCacheForWatches()
    StockPiler.MaterialSpec.ProductMatches = prev
    eq(P.CountItemsMatchingSpec(main), 2, "slot filter still counts the main")
    eq(P.CountItemsMatchingSpec(vial), 0, "a main stack is not credited to a vial")
    eq(P.CountItemsMatchingSpec(stab), 9, "goldweed still credits a stabilizer spec")
    eq(calls.filtVial or 0, 0, "vial spec is not tested against other slots")
    check((calls.filtOpen or 0) >= 1, "a slot 0 spec is not dropped from the walk")
    check((calls.filtMain or 0) >= 1, "main spec is tested against its slot")
    check((calls.filtStab or 0) >= 1, "stabilizer spec is tested against goldweed")
end

local function testBuildSliceMatchesSync()
    local spec = { key = "buildLeaf", role = "main", slotType = 2, skillLevel = 15 }
    H.items = {
        { uniqueID = 31, stackCount = 6, pk = "ts:4|st:2|lv:15", matches = { buildLeaf = true } },
        { uniqueID = 32, stackCount = 1, pk = "ts:4|st:5|lv:15", matches = {} },
    }
    H.watches = {
        ["uid:41"] = { enabled = true, autoGrow = true, targetStock = 3, priorityTier = 1 },
        ["uid:42"] = { enabled = true, autoGrow = true, targetStock = 3, priorityTier = 2 },
    }
    local recipe = {
        recipeKey = "rBuild", recipeYield = 1, out = 41,
        slots = { { spec = spec, perCraft = 1, role = "main" } },
    }
    H.recipes = {
        ["uid:41"] = recipe,
        ["uid:42"] = {
            recipeKey = "rBuildB", recipeYield = 1, out = 42,
            slots = { { spec = spec, perCraft = 1, role = "main" } },
        },
    }
    reset()
    P._lazyWatchTips = true
    local syncPlan = P.Build({ force = true })
    local syncRows = rowSig(syncPlan)
    check(type(syncPlan) == "table", "sync build publishes a plan")

    reset()
    P.BUILD_ROWS_PER_PUMP = 1
    P.WARM_HAVE_ITEMS_PER_PUMP = 1
    eq(P.BeginBuildSlice(), "continue", "full rebuild starts a slice")
    local pumps = 0
    local sawContinue = false
    local result = "continue"
    while result == "continue" and pumps < 30 do
        pumps = pumps + 1
        result = P.PumpBuildSlice()
        if result == "continue" then
            sawContinue = true
            eq(StockPiler.PlanSnapshot.Get(), nil, "a partial rebuild is not published")
        end
    end
    eq(result, "done", "sliced rebuild finishes")
    check(sawContinue == true, "row budget 1 takes more than one pump")
    local sliced = StockPiler.PlanSnapshot.Get()
    eq(rowSig(sliced), syncRows, "sliced rebuild matches the sync plan")

    reset()
    P.BUILD_ROWS_PER_PUMP = 1
    P.WARM_HAVE_ITEMS_PER_PUMP = 1
    eq(P.BeginBuildSlice(), "continue", "stale test starts a slice")
    eq(P.PumpBuildSlice(), "continue", "stale test gets a partial pump")
    H.snap = H.snap + 1
    eq(P.PumpBuildSlice(), "restart", "a snap change abandons the partial plan")
    eq(StockPiler.PlanSnapshot.Get(), nil, "an abandoned rebuild does not publish")
    eq(P._buildRows, nil, "an abandoned rebuild clears partial rows")
end

local function testFrameWorkBagPumps()
    StockPiler.Util.TryCallQuiet = function(_, fn, ...)
        return pcall(fn, ...)
    end
    load_module("Source/Core/FrameWork.lua")
    local spec = { key = "fwLeaf", role = "main" }
    H.items = {
        { uniqueID = 51, stackCount = 1, matches = { fwLeaf = true } },
        { uniqueID = 52, stackCount = 2, matches = { fwLeaf = true } },
        { uniqueID = 53, stackCount = 3, matches = { fwLeaf = true } },
    }
    H.watches = {
        ["uid:1"] = { enabled = true, autoGrow = true, targetStock = 1 },
    }
    H.recipes = {
        ["uid:1"] = {
            recipeKey = "rFw", recipeYield = 1, out = 1,
            slots = { { spec = spec, perCraft = 1, role = "main" } },
        },
    }
    reset()
    P.WARM_HAVE_ITEMS_PER_PUMP = 1
    local FW = StockPiler.FrameWork
    FW._jobs = {}
    FW._order = {}
    eq(FW.EnqueueWarmHave("snap"), true, "warm have enqueues")
    local pumps = 0
    while FW.IsActive("prewarm-warm-have") and pumps < 12 do
        pumps = pumps + 1
        FW.Pump()
    end
    check(pumps >= 4, "collect plus one stack per pump takes several frames")
    eq(FW.IsActive("prewarm-warm-have"), false, "warm have job finishes")
    eq(P.CountItemsMatchingSpec(spec), 6, "framework slice counts every stack")
    StockPiler.Orchestrator = {
        IsBrewSessionActive = function()
            return true
        end,
    }
    reset()
    P.WARM_HAVE_ITEMS_PER_PUMP = 1
    FW._jobs = {}
    FW._order = {}
    eq(FW.EnqueueWarmHave("brew"), true, "a recount enqueued before a brew stays queued")
    eq(FW.Pump(), true, "a brew does not freeze the recount pump")
    eq(FW.IsActive("prewarm-warm-have"), true, "one brew frame does not finish the whole recount")
    StockPiler.Orchestrator = nil
end

local function testThinContainerProductKey()
    local saved = {}
    local fields = { "Key", "ProductKey", "ProductMatches", "IsSeedOrSpore", "Label", "FromItemData", "Matches" }
    for i = 1, #fields do
        saved[fields[i]] = StockPiler.MaterialSpec[fields[i]]
    end
    if StockPiler.Util.T == nil then
        StockPiler.Util.T = function(key)
            return tostring(key)
        end
    end
    load_module("Source/Knowledge/MaterialSpec.lua")
    local MS = StockPiler.MaterialSpec
    local learned = {
        role = "container",
        tradeSkill = 4,
        slotType = 5,
        skillLevel = 200,
        cultivationType = 0,
        bonuses = {},
        uid = 777,
    }
    StockPiler.Items = {
        ToSpec = function(uid)
            if tonumber(uid) == 777 then
                return learned
            end
            return nil
        end,
    }
    local thin = { uniqueID = 777, craftingSkillRequirement = 200, stackCount = 3 }
    local other = { uniqueID = 778, craftingSkillRequirement = 200, stackCount = 9, slotType = 2 }
    local pk = MS.ProductKey(thin)
    eq(pk, "ts:4|st:0|lv:200|ct:0|role:ingredient", "a thin container keys as slot 0")
    local vial = {
        role = "container",
        tradeSkill = 4,
        slotType = 5,
        skillLevel = 200,
        cultivationType = 0,
        bonuses = {},
    }
    eq(MS.ProductMatches(thin, vial), true, "ProductMatches enriches the thin container")
    eq(MS.ProductMatches(other, vial), false, "a slotted stack does not match the vial")
    H.items = { thin, other }
    H.watches = {
        ["uid:1"] = { enabled = true, autoGrow = true, targetStock = 1 },
    }
    H.recipes = {
        ["uid:1"] = {
            recipeKey = "rThin", recipeYield = 1, out = 1,
            slots = { { spec = vial, perCraft = 1, role = "container" } },
        },
    }
    reset()
    P.WarmSpecHaveCacheForWatches()
    eq(P.CountItemsMatchingSpec(vial), 3, "sync warm counts the thin container")
    reset()
    P.WARM_HAVE_ITEMS_PER_PUMP = 1
    eq(P.BeginWarmHaveSlice(), "continue", "thin container slice starts")
    local guard = 0
    local result = "continue"
    while result == "continue" and guard < 8 do
        guard = guard + 1
        result = P.FinishWarmHaveSlice()
    end
    eq(result, "done", "thin container slice finishes")
    eq(P.CountItemsMatchingSpec(vial), 3, "sliced warm counts the thin container")
    for i = 1, #fields do
        StockPiler.MaterialSpec[fields[i]] = saved[fields[i]]
    end
    StockPiler.Items = nil
    if StockPiler.Inventory then
        StockPiler.Inventory._specParseCache = nil
    end
end

local function testWarmHaveSliceDoesNotScanWholeBag()
    local spec = { key = "scanA", role = "main", slotType = 2 }
    H.items = {
        { uniqueID = 61, stackCount = 4, pk = "ts:4|st:2|lv:1", matches = { scanA = true } },
        { uniqueID = 62, stackCount = 5, pk = "ts:4|st:2|lv:1", matches = { scanA = true } },
        { uniqueID = 63, stackCount = 6, pk = "ts:4|st:2|lv:1", matches = { scanA = true } },
    }
    H.watches = {
        ["uid:1"] = { enabled = true, autoGrow = true, targetStock = 1 },
    }
    H.recipes = {
        ["uid:1"] = {
            recipeKey = "rScan", recipeYield = 1, out = 1,
            slots = { { spec = spec, perCraft = 1, role = "main" } },
        },
    }
    reset()
    P.WARM_HAVE_ITEMS_PER_PUMP = 1
    eq(P.BeginWarmHaveSlice(), "continue", "scan slice starts")
    local visits = 0
    local orig = StockPiler.Inventory.ForEachItem
    StockPiler.Inventory.ForEachItem = function(fn)
        orig(function(item)
            visits = visits + 1
            return fn(item)
        end)
    end
    eq(P.FinishWarmHaveSlice(), "continue", "first bag pump does not commit")
    StockPiler.Inventory.ForEachItem = orig
    eq(visits, 1, "the first bag pump does not walk the whole bag")
    H.items[1].stackCount = 20
    eq(P.FinishWarmHaveSlice(), "done", "an in-place count change drops the partial")
    eq(P.IsHaveCacheWarmForSnap(), false, "a mixed count is not published")
    eq(P.CountItemsMatchingSpec(spec, { cacheOnly = true }), nil, "partial totals stay private")
    eq(P.BeginWarmHaveSlice(), "continue", "the next slice starts clean")
    local guard = 0
    local result = "continue"
    while result == "continue" and guard < 8 do
        guard = guard + 1
        result = P.FinishWarmHaveSlice()
    end
    eq(result, "done", "a stable slice publishes")
    eq(P.CountItemsMatchingSpec(spec), 31, "the retry counts the stacks it actually read")
end

local function testDemandPrivateDuringRebuild()
    local spec = { key = "demLeaf", role = "main", slotType = 2, skillLevel = 15 }
    H.items = {
        { uniqueID = 71, stackCount = 2, pk = "ts:4|st:2|lv:15", matches = { demLeaf = true } },
    }
    H.watches = {
        ["uid:81"] = { enabled = true, autoGrow = true, targetStock = 3, priorityTier = 1 },
        ["uid:82"] = { enabled = true, autoGrow = true, targetStock = 3, priorityTier = 2 },
    }
    H.recipes = {
        ["uid:81"] = {
            recipeKey = "rDemA", recipeYield = 1, out = 81,
            slots = { { spec = spec, perCraft = 1, role = "main" } },
        },
        ["uid:82"] = {
            recipeKey = "rDemB", recipeYield = 1, out = 82,
            slots = { { spec = spec, perCraft = 1, role = "main" } },
        },
    }
    reset()
    P._lazyWatchTips = true
    local syncPlan = P.Build({ force = true })
    local syncRows = rowSig(syncPlan)
    reset()
    P.BUILD_ROWS_PER_PUMP = 1
    P.WARM_HAVE_ITEMS_PER_PUMP = 50
    P._lazyWatchTips = true
    eq(P.BeginBuildSlice(), "continue", "demand leak test starts a slice")
    local pumps = 0
    local parked = false
    while pumps < 12 do
        pumps = pumps + 1
        local result = P.PumpBuildSlice()
        if result ~= "continue" then
            break
        end
        if P._buildSliceSuspended == true and type(P._buildRows) == "table"
            and #P._buildRows >= 1 and #P._buildRows < 2
        then
            parked = true
            break
        end
    end
    check(parked == true, "the slice is parked on a partial row list")
    local buildGen = tostring(P._buildPlanGen)
    P._demandCache = nil
    P._demandCacheKey = nil
    P._demandNeedScratch = { sentinel = true }
    P._demandDeferStore = true
    P.WarmDemand()
    eq(P._demandNeedScratch.sentinel, true, "prewarm does not write the rebuild scratch")
    eq(P._demandNeedScratch["uid:81"], nil, "prewarm does not record the partial grow answer")
    local suffix = "|demand:" .. buildGen
    local key = tostring(P._demandCacheKey or "")
    check(key:sub(-#suffix) ~= suffix, "prewarm does not cache under the in-progress plan gen")
    check(type(P._demandCache) == "table", "prewarm still stores demand for the published plan")
    P._demandCache._probe = "prewarm"
    P._demandDeferStore = nil
    local guard = 0
    local result = "continue"
    while result == "continue" and guard < 20 do
        guard = guard + 1
        result = P.PumpBuildSlice()
    end
    eq(result, "done", "the slice finishes after the prewarm")
    local sliced = StockPiler.PlanSnapshot.Get()
    eq(rowSig(sliced), syncRows, "prewarm does not publish demand from partial rows")
    check(P._lastDemand == nil or P._lastDemand._probe ~= "prewarm", "the rebuild demand is not the prewarm table")
end

local function testBuildSliceRestartCap()
    local spec = { key = "capLeaf", role = "main", slotType = 2, skillLevel = 15 }
    H.items = {
        { uniqueID = 91, stackCount = 4, pk = "ts:4|st:2|lv:15", matches = { capLeaf = true } },
    }
    H.watches = {
        ["uid:91"] = { enabled = true, autoGrow = true, targetStock = 2, priorityTier = 1 },
        ["uid:92"] = { enabled = true, autoGrow = true, targetStock = 2, priorityTier = 2 },
    }
    H.recipes = {
        ["uid:91"] = {
            recipeKey = "rCapA", recipeYield = 1, out = 91,
            slots = { { spec = spec, perCraft = 1, role = "main" } },
        },
        ["uid:92"] = {
            recipeKey = "rCapB", recipeYield = 1, out = 92,
            slots = { { spec = spec, perCraft = 1, role = "main" } },
        },
    }
    reset()
    P.BUILD_ROWS_PER_PUMP = 1
    P.WARM_HAVE_ITEMS_PER_PUMP = 50
    P.BUILD_SLICE_RESTART_CAP = 2
    P._lazyWatchTips = true
    eq(P.BeginBuildSlice(), "continue", "cap test starts a slice")
    eq(P.PumpBuildSlice(), "continue", "cap test gets a partial pump")
    H.snap = H.snap + 1
    eq(P.PumpBuildSlice(), "restart", "the first stale pump still restarts")
    eq(StockPiler.PlanSnapshot.Get(), nil, "the first restart does not publish")
    eq(P.BeginBuildSlice(), "continue", "the second attempt starts")
    eq(P.PumpBuildSlice(), "continue", "the second attempt gets a partial pump")
    H.snap = H.snap + 1
    eq(P.PumpBuildSlice(), "done", "the cap finishes the rebuild in one call")
    check(type(StockPiler.PlanSnapshot.Get()) == "table", "the capped rebuild publishes a plan")

    reset()
    P.BUILD_ROWS_PER_PUMP = 1
    P.WARM_HAVE_ITEMS_PER_PUMP = 50
    P.BUILD_SLICE_RESTART_CAP = 50
    P.BUILD_SLICE_BUDGET_SEC = 5
    P._lazyWatchTips = true
    local prevClock = GetGameTime
    local now = 2000
    GetGameTime = function()
        return now
    end
    eq(P.BeginBuildSlice(), "continue", "budget test starts a slice")
    eq(P.PumpBuildSlice(), "continue", "budget test gets a partial pump")
    now = 2006
    H.snap = H.snap + 1
    eq(P.PumpBuildSlice(), "done", "the time budget finishes the rebuild in one call")
    check(type(StockPiler.PlanSnapshot.Get()) == "table", "the timed rebuild publishes a plan")
    GetGameTime = prevClock

    reset()
    P.BUILD_ROWS_PER_PUMP = 1
    P.WARM_HAVE_ITEMS_PER_PUMP = 50
    P._lazyWatchTips = true
    local logs = 0
    StockPiler.Debug = {
        ReportProtectedCallFailure = function()
            logs = logs + 1
        end,
    }
    local orig = StockPiler.RecipeSpec.HydrateRecipeSlots
    StockPiler.RecipeSpec.HydrateRecipeSlots = function()
        error("slice-boom")
    end
    eq(P.BeginBuildSlice(), "continue", "error test starts a slice")
    eq(P.PumpBuildSlice(), "retry", "a slice error keeps the rebuild pending")
    eq(logs, 1, "the slice error is logged once")
    local retryAt = tonumber(P._buildSliceRetryAt) or 0
    check(retryAt > GetGameTime(), "the slice error waits before the next attempt")
    eq(P.BeginBuildSlice(), "continue", "the retry starts another slice")
    eq(P.PumpBuildSlice(), "retry", "the second error still asks for a retry")
    eq(logs, 1, "the second error does not log again")
    eq(StockPiler.PlanSnapshot.Get(), nil, "a failed slice does not publish")
    StockPiler.RecipeSpec.HydrateRecipeSlots = orig
    StockPiler.Debug = nil
end

testSameOutput()
testCoveredReserve()
testWarmHave()
testResinInflation()
testSkillPointKeepsCacheKey()
testBuildFlagsClearOnError()
testNeedSkillClearsWhenApoCrosses()
testColdDemandPlantAndPotion()
testWarmHaveSliceMatchesSync()
testWarmHaveSliceRestartsOnSnap()
testWarmHaveSlotFilter()
testThinContainerProductKey()
testWarmHaveSliceDoesNotScanWholeBag()
testDemandPrivateDuringRebuild()
testBuildSliceRestartCap()
testBuildSliceMatchesSync()
testFrameWorkBagPumps()

if failures > 0 then
    io.stderr:write(string.format("%d/%d checks failed\n", failures, checks))
    os.exit(1)
end
print(string.format("planner_watches: %d checks passed", checks))
