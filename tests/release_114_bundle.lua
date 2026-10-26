-- 1.1.4: issue-burst cap, AutoGrow twins stay yellow, cold have stays cached.
-- Run: lua5.1 tests/release_114_bundle.lua

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

----------------------------------------------------------------
-- Scheduler: burst is real issue activity, and it expires.
----------------------------------------------------------------

local now = 1000
function GetGameTime()
    return now
end

local builds = 0
local flushes = 0
StockPiler = {
    FrameCounter = 1,
    Planner = {
        IsHaveCacheWarmForSnap = function()
            return true
        end,
        GetOrBuild = function()
            builds = builds + 1
            return {}
        end,
    },
    Ui = {
        FlushWatchUiIfDirty = function()
            flushes = flushes + 1
            return true
        end,
    },
    Refine = {
        _refineWaitTicks = 5,
        _refineDirty = true,
        PeekCachedBufferPending = function()
            return true
        end,
        DecayRefineWaitTicks = function() end,
    },
    RefinePipeline = {
        HasOutstanding = function()
            return false
        end,
    },
    Watch = {
        IsAutoGrowEnabled = function()
            return true
        end,
    },
    VendorAdapter = {
        IsStoreOpen = function()
            return false
        end,
    },
}

load_module("Source/Core/Scheduler.lua")
local Sch = StockPiler.Scheduler
Sch._autoGrowFast = false
Sch._awaitingSessionLoad = false
Sch._plantQuietUntil = 0
Sch._harvestStormUntil = 0
Sch._lastPlantQuietArmAt = 0
Sch._burstHoldStartedAt = 0
Sch._planAt = 0
Sch._bagDue = false

local function armPlan()
    builds = 0
    flushes = 0
    Sch._planDue = true
    Sch._planAt = 0
    Sch._skipPlanThisFrame = false
    Sch._skipUiThisFrame = false
end

armPlan()
eq(Sch.IsAutoGrowIssueBurstActive(), false, "idle refine wait is not an issue burst")
Sch.OnUpdate(0)
eq(builds, 1, "idle AutoGrow still rebuilds the plan")
eq(Sch.FlushWatchUiIfDue(false), true, "idle AutoGrow still flushes Watch")

StockPiler.VendorAdapter.IsStoreOpen = function()
    return true
end
StockPiler.Refine._refineDirty = true
StockPiler.Refine.PeekCachedBufferPending = function()
    return true
end
armPlan()
eq(Sch.IsAutoGrowIssueBurstActive(), false, "vendor-open dirty buffer is not an issue burst")
Sch.OnUpdate(0)
eq(builds, 1, "vendor-open dirty buffer does not hold the plan")
eq(Sch.FlushWatchUiIfDue(false), true, "vendor-open dirty buffer does not hold Watch")

StockPiler.Watch.IsAutoGrowEnabled = function()
    return false
end
armPlan()
eq(Sch.IsAutoGrowIssueBurstActive(), false, "AutoGrow off does not invent a burst")
Sch.OnUpdate(0)
eq(builds, 1, "AutoGrow off still rebuilds the plan")
eq(Sch.FlushWatchUiIfDue(false), true, "AutoGrow off still flushes Watch")
StockPiler.Watch.IsAutoGrowEnabled = function()
    return true
end
StockPiler.VendorAdapter.IsStoreOpen = function()
    return false
end

now = 2000
Sch._plantQuietUntil = 0
Sch._lastPlantQuietArmAt = now - 1
Sch._burstHoldStartedAt = 0
StockPiler.RefinePipeline.HasOutstanding = function()
    return false
end
armPlan()
eq(Sch.IsAutoGrowIssueBurstActive(), true, "a recent plant arm holds the burst")
Sch.OnUpdate(0)
eq(builds, 0, "a recent plant arm holds the plan")
eq(Sch.FlushWatchUiIfDue(false), false, "a recent plant arm holds Watch")
check((tonumber(Sch._plantQuietUntil) or 0) == 0, "the burst test does not set plant quiet")

StockPiler.RefinePipeline.HasOutstanding = function()
    return true
end
Sch._lastPlantQuietArmAt = now
now = 2000 + Sch.ISSUE_BURST_MAX_SEC
armPlan()
eq(Sch.IsAutoGrowIssueBurstActive(), false, "a lingering outstanding expires the burst")
Sch.OnUpdate(0)
eq(builds, 1, "plan rebuilds after the burst cap")
eq(Sch.FlushWatchUiIfDue(false), true, "Watch flushes after the burst cap")

Sch._lastPlantQuietArmAt = 0
StockPiler.RefinePipeline.HasOutstanding = function()
    return false
end
eq(Sch.IsAutoGrowIssueBurstActive(), false, "a cleared burst drops")
eq(tonumber(Sch._burstHoldStartedAt) or 0, 0, "a cleared burst resets its start")

local savedNow = now
now = 0
Sch._lastPlantQuietArmAt = 50
StockPiler.RefinePipeline.HasOutstanding = function()
    return true
end
eq(Sch.IsAutoGrowIssueBurstActive(), false, "now<=0 does not hold the burst forever")
now = savedNow
StockPiler.RefinePipeline.HasOutstanding = function()
    return false
end

----------------------------------------------------------------
-- Planner: butcher twins stay yellow; flasks wait on plants.
----------------------------------------------------------------

local GORE = 3030238
local GOLDWEED = 3020048
local TOOTH = 3030301
local GRUMP = 3020111
local VIAL = 2001
local VENDOR = 8088

local H = { items = {}, watches = {}, recipes = {}, snap = 1 }
local scanKeys = {}

StockPiler.T = function(k, tokens)
    local s = tostring(k)
    if type(tokens) == "table" and tokens.note ~= nil then
        s = s .. " " .. tostring(tokens.note)
    end
    return s
end
StockPiler.Util = {
    ToNarrow = function(v)
        return tostring(v or "")
    end,
    T = function(k, tokens)
        return StockPiler.T(k, tokens)
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
                n = n + (it.stackCount or 0)
            end
        end
        return n
    end,
}
StockPiler.MaterialSpec = {
    Key = function(spec) return spec.key end,
    ProductKey = function(spec) return spec.key or "" end,
    ProductMatches = function(item, spec)
        return item.matches ~= nil and item.matches[spec.key] == true
    end,
    IsSeedOrSpore = function() return false end,
    Label = function(spec) return spec.key end,
}
local function twinOf(spec)
    local uid = tonumber(spec and (spec.uid or spec.uniqueID or spec.boundUid)) or 0
    if uid == GORE then
        return GOLDWEED
    end
    if uid == TOOTH then
        return GRUMP
    end
    if uid == GOLDWEED or uid == GRUMP then
        return uid
    end
    return 0
end
StockPiler.SeedMap = {
    IsGrowableSpec = function(spec)
        return spec and spec.growable == true
    end,
    IsHarvestByproduct = function(spec)
        return spec and spec.byproduct == true
    end,
    FindGrowableTwinUid = function(spec)
        return twinOf(spec)
    end,
    FindPlantUidForSpec = function(spec)
        if spec and spec.growable == true then
            return tonumber(spec.plantUid or spec.uid) or 0
        end
        return 0
    end,
    ResolveSeedForSpec = function(spec)
        local plant = twinOf(spec)
        if plant <= 0 and spec and spec.growable == true then
            plant = tonumber(spec.plantUid or spec.uid) or 0
        end
        if plant <= 0 then
            return nil
        end
        return { uniqueID = plant + 1000, uid = plant + 1000, plantUid = plant }
    end,
}
StockPiler.RecipeSpec = {
    RecipeSpecForPotion = function(k) return H.recipes[k] end,
    HydrateRecipeSlots = function() end,
    CountItemsMatchingSpec = function(spec)
        scanKeys[#scanKeys + 1] = spec and spec.key or "?"
        local n = 0
        for _, it in ipairs(H.items) do
            if it.matches and it.matches[spec.key] then
                n = n + it.stackCount
            end
        end
        return n
    end,
    CountCraftsPossible = function() return 0 end,
    StableCraftYield = function(recipe) return recipe.recipeYield end,
    CraftsNeededForDeficit = function(d, recipe)
        local y = tonumber(recipe and recipe.recipeYield) or 1
        if y < 1 then
            y = 1
        end
        return math.ceil((tonumber(d) or 0) / y)
    end,
    EffectiveSpecPerCraft = function(slot) return slot.perCraft or 1 end,
    ResolveWatchPotion = function(k)
        local r = H.recipes[k]
        if not r then
            return nil
        end
        return {
            potion = { name = k, outputUid = r.out },
            outputUid = r.out,
            potionKey = k,
        }
    end,
    ShouldAutoGrowPotion = function()
        return true
    end,
}
StockPiler.Watch = {
    GetWatches = function() return H.watches end,
    GetGen = function() return 1 end,
    IsAutoGrowEnabled = function() return true end,
    IsAutoBuyEnabled = function() return true end,
    IsSeedBufferEnabled = function() return false end,
    IsOptimisticOutcomeEstimate = function() return true end,
    ResolveWatchEntry = function(k)
        return H.watches[k] or { enabled = true, autoGrow = true }, k
    end,
    GetPriorityTier = function(k)
        local w = H.watches[k]
        return w and w.priorityTier or 1
    end,
}
StockPiler.Scheduler = Sch

load_module("Source/Stores/PlanSnapshotStore.lua")
load_module("Source/Planner/Planner.lua")
local P = StockPiler.Planner

local function resetPlan()
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
    scanKeys = {}
    H.snap = H.snap + 1
    if StockPiler.PlanSnapshot then
        StockPiler.PlanSnapshot._plan = nil
        StockPiler.PlanSnapshot._cacheKey = nil
    end
end

local gore = {
    key = "gore",
    role = "stabilizer",
    uid = GORE,
    name = "Brutal Zoic Gore",
    growable = false,
}
local tooth = {
    key = "tooth",
    role = "main",
    uid = TOOTH,
    name = "Special Canine Tooth",
    growable = false,
}
local flask = { key = "flask", role = "container", uid = VIAL }
local vendor = {
    key = "vendor",
    role = "main",
    uid = VENDOR,
    name = "Vendor Dust",
    growable = false,
}

H.items = {}
H.watches = {
    ["uid:11"] = { enabled = true, autoGrow = true, targetStock = 4, priorityTier = 1 },
}
H.recipes = {
    ["uid:11"] = {
        recipeKey = "gore-brew",
        recipeYield = 1,
        out = 11,
        slots = {
            { spec = gore, perCraft = 1, role = "stabilizer" },
            { spec = flask, perCraft = 1, role = "container" },
        },
    },
}
resetPlan()
local demand = P.BuildBalancedSpecDemand()
eq(demand.gore and demand.gore.plantUid, GOLDWEED, "butcher demand resolves the cultivable twin")
eq((demand.gore and demand.gore.seedUid) or 0, GOLDWEED + 1000, "butcher demand resolves the twin seed")

local jobs = P.CollectVendorBuyJobs()
local jobKeys = {}
for i = 1, #jobs do
    jobKeys[jobs[i].specKey] = true
end
eq(jobKeys.gore, nil, "AutoBuy does not buy a butcher exemplar AutoGrow can plant")
eq(jobKeys.flask, true, "AutoBuy still buys flasks")

resetPlan()
local plan = P.Build({ force = true })
local row = plan and plan.rows and plan.rows[1]
eq(row and row.statusKey, "restocking", "a short butcher twin is Restocking")
check(row and row.statusKey ~= "buy_ingredients", "a short butcher twin is not Buy materials")
local goreTip = nil
local tips = row and row.statusTipSlots or {}
for i = 1, #tips do
    if tips[i].spec and tips[i].spec.key == "gore" then
        goreTip = tips[i]
    end
end
eq(goreTip and goreTip.kind, "plant", "the butcher slot is classified as a plant")
eq(goreTip and goreTip.plantUid, GOLDWEED, "the butcher slot plants Majestic Goldweed")

H.watches = {
    ["uid:12"] = { enabled = true, autoGrow = true, targetStock = 3, priorityTier = 1 },
}
H.recipes = {
    ["uid:12"] = {
        recipeKey = "tooth-brew",
        recipeYield = 1,
        out = 12,
        slots = { { spec = tooth, perCraft = 1, role = "main" } },
    },
}
resetPlan()
plan = P.Build({ force = true })
row = plan and plan.rows and plan.rows[1]
eq(row and row.statusKey, "restocking", "a short canine tooth twin is Restocking")
check(row and row.statusKey ~= "buy_ingredients", "a short canine tooth twin is not Buy materials")

H.watches = {
    ["uid:13"] = { enabled = true, autoGrow = true, targetStock = 2, priorityTier = 1 },
}
H.recipes = {
    ["uid:13"] = {
        recipeKey = "vendor-brew",
        recipeYield = 1,
        out = 13,
        slots = { { spec = vendor, perCraft = 1, role = "main" } },
    },
}
resetPlan()
plan = P.Build({ force = true })
row = plan and plan.rows and plan.rows[1]
eq(row and row.statusKey, "buy_ingredients", "a vendor-only material with no twin is Buy materials")

local function contestRow(id, slots, tipSlots)
    return {
        id = id,
        potionKey = id,
        potionRecipeKey = id,
        uniqueID = 1,
        name = id,
        autoGrow = true,
        statusKey = "ready_to_craft",
        statusText = "plan.status.ready_to_craft",
        potionHave = 0,
        potionMin = 4,
        target = 4,
        potionDeficit = 4,
        craftable = 4,
        craftsPossible = 2,
        craftsNeeded = 2,
        recipe = { recipeYield = 1, slots = slots },
        statusTipSlots = tipSlots,
    }
end

local function runContest(rows)
    scanKeys = {}
    P._specHaveCache = nil
    P._specHaveWarmedSnap = nil
    P.AfterPrioritySoftChange(rows)
    return rows
end

local plantTip = {
    spec = gore,
    specKey = "gore",
    role = "stabilizer",
    have = 0,
    need = 2,
    deficit = 2,
    kind = "plant",
}
local flaskTipShort = {
    spec = flask,
    specKey = "flask",
    role = "container",
    have = 0,
    need = 2,
    deficit = 2,
    kind = "buy",
}
local rows = runContest({
    contestRow("a", {
        { spec = gore, perCraft = 1, role = "stabilizer" },
        { spec = flask, perCraft = 1, role = "container" },
    }, { plantTip, flaskTipShort }),
    contestRow("b", {
        { spec = flask, perCraft = 1, role = "container" },
    }, { flaskTipShort }),
})
eq(rows[1].statusKey, "restocking", "contested flasks stay yellow while the twin is short")
check(rows[1].statusKey ~= "buy_ingredients", "contested flasks are not Buy flasks while a twin is short")
eq(rows[2].statusKey, "buy_ingredients", "the other watch can still say Buy flasks once it has nothing to grow")
local sawGore = false
for i = 1, #scanKeys do
    if scanKeys[i] == "gore" then
        sawGore = true
    end
end
check(sawGore ~= true, "the growable shortfall does not cold-scan bags")

plantTip.have = 4
plantTip.need = 2
plantTip.deficit = 0
rows = runContest({
    contestRow("a", {
        { spec = gore, perCraft = 1, role = "stabilizer" },
        { spec = flask, perCraft = 1, role = "container" },
    }, { plantTip, flaskTipShort }),
    contestRow("b", {
        { spec = flask, perCraft = 1, role = "container" },
    }, { flaskTipShort }),
})
eq(rows[1].statusKey, "buy_ingredients", "flasks paint Buy once the growable twin is covered")
check(tostring(rows[1].statusText):find("buy_flasks", 1, true) ~= nil, "covered plants leave Buy flasks")

local vendorTip = {
    spec = vendor,
    specKey = "vendor",
    role = "main",
    have = 0,
    need = 2,
    deficit = 2,
    kind = "buy",
}
rows = runContest({
    contestRow("c", {
        { spec = vendor, perCraft = 1, role = "main" },
    }, { vendorTip }),
    contestRow("d", {
        { spec = vendor, perCraft = 1, role = "main" },
    }, { vendorTip }),
})
eq(rows[1].statusKey, "buy_ingredients", "a contested vendor-only material stays Buy materials")
eq(rows[1].statusText, "plan.status.buy_ingredients", "vendor-only contested text is Buy materials")

----------------------------------------------------------------
-- Watch tips soften flask lines while a twin is short.
----------------------------------------------------------------

StockPiler.ViewList = { OnRowChildMouseOver = function() end }
load_module("Source/View/StockPilerTabWatch.lua")

local shown = nil
Tooltips = {
    ANCHOR_WINDOW_TOP = 1,
    COLOR_HEADING = { r = 255, g = 255, b = 255 },
    CreateTextOnlyTooltip = function() end,
    AnchorTooltip = function() end,
}
SystemData = { ActiveWindow = { name = "StockPilerWatchRowStatus" } }
function DoesWindowExist(name)
    return name == "SPTabWatchList"
end
function WindowGetId()
    return 1
end
function ListBoxGetDataIndex()
    return 1
end
StockPiler.RecipeTooltip = {
    SEP_LINE = "--",
    EnsureRows = function() return 17 end,
    AppendSeparator = function(rows)
        rows[#rows + 1] = { text = "--", kind = "separator" }
    end,
    ShowColoredRows = function(_, rows)
        shown = rows
    end,
}

local function slotColor(role)
    shown = nil
    StockPilerTabWatch._statusTipCache = nil
    StockPilerTabWatch.OnMouseOverStatus()
    if type(shown) ~= "table" then
        return nil
    end
    for i = 1, #shown do
        local r = shown[i]
        if r.kind == "warning" or r.kind == "block" or r.kind == "stocked" then
            local text = tostring(r.text or "")
            if role == "flask" and text:find("buy_flasks", 1, true) then
                return r.color
            end
            if role == "vendor" and text:find("buy_materials", 1, true) then
                return r.color
            end
        end
    end
    return nil
end

local function isWarn(color)
    return type(color) == "table" and color.r == 220 and color.g == 180 and color.b == 60
end
local function isBlock(color)
    return type(color) == "table" and color.r == 220 and color.g == 70 and color.b == 70
end

StockPilerTabWatch.listData = {
    {
        potionKey = "tip-a",
        autoGrow = true,
        statusKey = "buy_ingredients",
        statusText = "watch.note.buy_flasks",
        craftsNeeded = 2,
        potionDeficit = 2,
        tipCraftsNeeded = 2,
        tipDeficit = 2,
        craftableShared = true,
        contestedSpecKeys = { flask = true },
        statusTipSlots = {
            {
                spec = gore, specKey = "gore", role = "stabilizer",
                have = 0, need = 2, deficit = 2, kind = "plant",
            },
            {
                spec = flask, specKey = "flask", role = "container",
                have = 0, need = 2, deficit = 2, kind = "buy",
            },
        },
    },
}
check(isWarn(slotColor("flask")), "a short twin softens Buy flasks to yellow")

StockPilerTabWatch.listData[1].statusTipSlots[1].have = 5
StockPilerTabWatch.listData[1].statusTipSlots[1].deficit = 0
check(isBlock(slotColor("flask")), "covered plants leave Buy flasks red")

StockPilerTabWatch.listData = {
    {
        potionKey = "tip-b",
        autoGrow = true,
        statusKey = "buy_ingredients",
        statusText = "plan.status.buy_ingredients",
        craftsNeeded = 1,
        potionDeficit = 1,
        tipCraftsNeeded = 1,
        tipDeficit = 1,
        statusTipSlots = {
            {
                spec = vendor, specKey = "vendor", role = "main",
                have = 0, need = 1, deficit = 1, kind = "buy",
            },
        },
    },
}
check(isBlock(slotColor("vendor")), "a vendor-only tip stays red")

StockPilerTabWatch.listData = {
    {
        potionKey = "tip-c",
        autoGrow = true,
        statusKey = "buy_ingredients",
        statusText = "watch.note.buy_flasks",
        craftsNeeded = 2,
        potionDeficit = 2,
        tipCraftsNeeded = 2,
        tipDeficit = 2,
        craftableShared = true,
        contestedSpecKeys = { flask = true },
        statusTipSlots = {
            {
                spec = gore, specKey = "gore", role = "stabilizer",
                have = 0, need = 2, deficit = 2, kind = "buy",
            },
            {
                spec = flask, specKey = "flask", role = "container",
                have = 2, need = 2, deficit = 0, kind = "buy",
                noteKind = "shared",
            },
        },
    },
}
check(isWarn(slotColor("flask")), "a stocked contested flask stays yellow while the twin is short")

----------------------------------------------------------------
-- AutoBrew still spends the butcher stack before the cult plant.
----------------------------------------------------------------

local BUTCHER_SLOT = 9
local PLANT_SLOT = 3
StockPiler.FrameCounter = 7
StockPiler.Persistence = {
    GetCharacterBucket = function()
        return {}
    end,
}
StockPiler.BagAdapter = {
    FetchForce = function()
        return {
            { bagType = "craft", slots = {} },
            { bagType = "inv", slots = {} },
        }
    end,
    IterateSlots = function(bag, fn)
        if bag.bagType == "craft" then
            fn("craft", PLANT_SLOT, {
                uniqueID = GOLDWEED,
                stackCount = 1,
                name = "Majestic Goldweed",
                growable = true,
            })
        else
            fn("inv", BUTCHER_SLOT, {
                uniqueID = GORE,
                stackCount = 8,
                name = "Brutal Zoic Gore",
                growable = false,
            })
        end
    end,
}
StockPiler.SeedMap.IsGrowableSpec = function(spec)
    local uid = tonumber(spec and (spec.uid or spec.uniqueID)) or 0
    if uid == GOLDWEED or (spec and spec.growable == true) then
        return true
    end
    return false
end
StockPiler.MaterialSpec.ProductMatches = function(item, spec)
    return spec and spec.key == "gore"
end
StockPiler.MaterialSpec.IsSeedOrSpore = function()
    return false
end

load_module("Source/Brew.lua")
local Brew = StockPiler.Brew
Brew._job = { phase = "load" }
Brew._bagSnap = nil
local bagSlot, _, _, matched = Brew.FindCraftingBagItemBySpec({
    key = "gore",
    role = "stabilizer",
    uid = GORE,
}, GORE, nil)
eq(bagSlot, BUTCHER_SLOT, "AutoBrew spends the butcher stack first")
eq(matched, GORE, "the chosen stack is the butcher exemplar")

----------------------------------------------------------------
-- Refine: defer only a cold rebuild; quiet only after a real send.
----------------------------------------------------------------

local quietArms = 0
local tracks = 0
local begins = 0
local sends = 0
local sendOk = true
Sch.ArmPlantQuiet = function()
    quietArms = quietArms + 1
end
Sch.SkipPlanThisFrame = function() end
Sch.SkipUiThisFrame = function() end
Sch.SuppressInventorySideEffects = function() end
Sch.WakeAutoGrow = function() end
Sch.EnqueueBagFlush = function() end
StockPiler.Scheduler = Sch
StockPiler.Grow = {
    IsEnabled = function() return true end,
    HasEmptyPlot = function() return false end,
    HasPendingBufferRefine = function() return false end,
    InvalidatePlantQueue = function() end,
}
StockPiler.VendorAdapter.IsStoreOpen = function()
    return false
end
StockPiler.SeedMap.BeginPendingRefine = function()
    begins = begins + 1
    return true
end
StockPiler.Inventory.ForEachItem = function(fn)
    fn({
        uniqueID = 50,
        stackCount = 1,
        isRefinable = true,
        slot = 4,
    }, "craft", 4)
end
StockPiler.Inventory.CountByUid = function()
    return 1
end
function SendUseItem()
    sends = sends + 1
    if sendOk ~= true then
        error("refuse")
    end
    return true
end
EA_Window_Backpack = {
    GetCursorForBackpack = function()
        return 1
    end,
    TYPE_CRAFTING = 4,
}

load_module("Source/Refine.lua")
local Refine = StockPiler.Refine
StockPiler.FrameCounter = 4
Refine._refineDirty = true
Refine._deferIssueFrame = 0
local cold = Refine.CollectIntents()
eq(type(cold), "table", "a cold collect returns intents")
eq(Refine.CollectedThisFrame(), true, "a cache miss is a cold rebuild")
eq(Refine.ShouldDeferIssue(), true, "a cold rebuild defers the issue")
local warm = Refine.CollectIntents()
eq(type(warm), "table", "a warm collect returns the cache")
eq(Refine.CollectedThisFrame(), false, "a warm collect clears the cold-rebuild flag")
eq(Refine.ShouldDeferIssue(), false, "a warm collect does not defer")

quietArms = 0
tracks = 0
begins = 0
sends = 0
sendOk = true
Refine._engineIssueFrame = 0
Refine._pendingByPlant = {}
Refine._pendingSeedByPlant = {}
Refine._liveSeedBaseline = {}
Refine._bagIndex = nil
StockPiler.FrameCounter = 8
local intent = {
    seedUid = 70,
    plantUid = 50,
    slot = 4,
    uses = 1,
    reason = "plant-need",
    item = { uniqueID = 50, stackCount = 1, isRefinable = true },
}
eq(Refine.IssueOne(intent, "op"), true, "the first refine sends")
eq(sends, 1, "SendUseItem ran once")
eq(begins, 1, "bag counts are snapshotted before the send")
eq(quietArms, 1, "quiet arms after the send")
eq(Refine._liveSeedBaseline[70] ~= nil, true, "the live seed is recorded after the send")
quietArms = 0
begins = 0
eq(Refine.IssueOne(intent, "op"), false, "the same frame does not refine again")
eq(sends, 1, "the same frame does not SendUseItem again")
eq(begins, 0, "the same-frame refusal does not snapshot again")
eq(quietArms, 0, "the same-frame refusal does not arm quiet")

StockPiler.FrameCounter = 9
Refine._engineIssueFrame = 0
sendOk = false
quietArms = 0
begins = 0
Refine._liveSeedBaseline[71] = nil
intent.seedUid = 71
eq(Refine.IssueOne(intent, "op"), false, "a refused SendUseItem does not count as issued")
eq(quietArms, 0, "a refused SendUseItem does not arm quiet")
eq(Refine._liveSeedBaseline[71], nil, "a refused SendUseItem does not record a live seed")
eq(begins, 1, "the snapshot still happens before a refused send")

----------------------------------------------------------------
-- LibPerf: saved threshold survives; a fresh player stays off.
----------------------------------------------------------------

load_module("Source/Bootstrap.lua")
StockPiler.Persistence = {
    EnsureSettings = function()
        StockPiler.Settings = StockPiler.Settings or {}
        return StockPiler.Settings
    end,
    EnsureAccount = function()
        return {}
    end,
    StripUnexpectedAccountKeys = function() end,
}
StockPiler.Settings = {}
local toggles = 0
StockPiler.Perf = {
    Available = true,
    Enabled = true,
    SetEnabled = function(on)
        toggles = toggles + 1
        StockPiler.Perf.Enabled = on == true
    end,
}
LibPerf = { Settings = { StockPiler = { threshold = 50 } } }
StockPiler.Initialize()
eq(toggles, 0, "a saved LibPerf scope is left alone")
eq(StockPiler.Perf.Enabled, true, "a saved threshold stays enabled")

toggles = 0
StockPiler.Perf.Enabled = true
LibPerf.Settings.StockPiler = nil
StockPiler.Initialize()
eq(toggles, 1, "a fresh LibPerf scope is forced off")
eq(StockPiler.Perf.Enabled, false, "a fresh player does not start profiling")

if failures > 0 then
    io.stderr:write(string.format("%d/%d checks failed\n", failures, checks))
    os.exit(1)
end
print(string.format("release_114_bundle: %d checks passed", checks))
