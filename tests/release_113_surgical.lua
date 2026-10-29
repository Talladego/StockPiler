-- Surgical 1.1.3 fixes: knowGen on incomplete items, lowest plant uid,
-- shared-import flags, recipe-tip cache, and bag sample misses.
-- Run: lua5.1 tests/release_113_surgical.lua

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
function WStringToString(s)
    return tostring(s)
end

GameData = {
    CultivationTypes = { NONE = 0, SEED = 1, SOIL = 2, WATERCAN = 3, NUTRIENT = 4, SPORE = 5 },
    ItemTypes = { CRAFTING = 34, POTION = 31 },
    TradeSkills = { APOTHECARY = 4, CULTIVATION = 7 },
}

function GetGameTime()
    return 10000
end

StockPiler = {}
StockPiler.Account = {
    items = {},
    grows = {},
    refines = {},
    recipes = {},
    potions = {},
    skillUpRates = {},
}
StockPiler.Settings = { characters = {} }
StockPiler.Persistence = {}
StockPiler.T = function(key)
    return tostring(key)
end

load_module("Source/Core/Util.lua")
load_module("Source/Stores/KnowledgeStore.lua")
load_module("Source/Knowledge/MaterialSpec.lua")
load_module("Source/Knowledge/MaterialExceptions.lua")
load_module("Source/Knowledge/Items.lua")
load_module("Source/Knowledge/Additives.lua")

local Know = StockPiler.Knowledge
local Items = StockPiler.Items
local AD = StockPiler.Additives

eq(Know.Additives, nil, "additives are not an account table")
local beforeTouch = Know.GetGen()
eq(AD.LearnFromItemData({
    uniqueID = 9,
    cultivationType = 2,
    name = "Soil",
}, "bag"), false, "learning an additive is a no-op")
eq(AD.LearnFromPlotRow({
    additives = { [2] = { item = { uniqueID = 9, cultivationType = 2 } } },
}), false, "learning plot additives is a no-op")
eq(Know.GetGen(), beforeTouch, "additive learning does not touch knowledge")
eq(StockPiler.Account.items["9"], nil, "additive learning does not store an item")
eq(StockPiler.Account.additives, nil, "additive learning does not create an additives table")
check(type(AD.Classify({ cultivationType = 2, name = "Soil" })) == "table", "classify still recognizes soil")

local stub = {
    uniqueID = 42,
    name = "Stable Leaf",
    role = "stabilizer",
    skillReq = 25,
    skillLevel = 25,
    incomplete = true,
    itemType = 34,
    kind = "plant",
    bonuses = { [1] = 5, [9] = 25 },
}
StockPiler.Account.items["42"] = stub
local genBefore = Know.GetGen()
local row, isNew = Items.StoreItem({
    uniqueID = 42,
    name = "Stable Leaf",
    role = "stabilizer",
    itemType = 34,
    craftingSkillRequirement = 25,
    craftingBonus = {
        { bonusReference = 1, bonusValue = 5 },
        { bonusReference = 9, bonusValue = 25 },
    },
}, "plant")
check(type(row) == "table", "completing a stub stores the row")
eq(isNew, false, "the stub row is updated in place")
eq(row.incomplete, false, "bonuses clear the incomplete flag")
eq(Know.GetGen(), genBefore + 1, "incomplete to complete bumps knowledge gen")
local genAfter = Know.GetGen()
Items.StoreItem({
    uniqueID = 42,
    name = "Stable Leaf",
    role = "stabilizer",
    itemType = 34,
    craftingSkillRequirement = 25,
    craftingBonus = {
        { bonusReference = 1, bonusValue = 5 },
        { bonusReference = 9, bonusValue = 25 },
    },
}, "plant")
eq(Know.GetGen(), genAfter, "storing the same complete row does not bump gen again")

load_module("Source/Knowledge/RecipeSpec.lua")
local RS = StockPiler.RecipeSpec

local function brewSlots()
    return {
        {
            role = "container",
            uid = 2001,
            perCraft = 1,
            spec = {
                role = "container",
                uid = 2001,
                tradeSkill = 4,
                skillLevel = 1,
                cultivationType = 0,
                slotType = 5,
                bonuses = { [8] = 5 },
            },
        },
        {
            role = "main",
            uid = 1001,
            perCraft = 1,
            spec = {
                role = "main",
                uid = 1001,
                tradeSkill = 4,
                skillLevel = 25,
                cultivationType = 0,
                slotType = 2,
                effectId = 35,
                incomplete = false,
                bonuses = { [1] = 4, [2] = 8, [6] = 35 },
            },
        },
    }
end

eq(RS.ImportSharedRecipe(9001, brewSlots(), { skipRegister = true }), "imported", "a new shared recipe imports")
local imported = nil
for _, recipe in pairs(StockPiler.Account.recipes) do
    if type(recipe) == "table" and tonumber(recipe.outputUid) == 9001 then
        imported = recipe
    end
end
check(type(imported) == "table", "the shared recipe is stored")
eq(imported.sharedImport, true, "a new shared recipe starts unverified")
eq(imported.unverified, true, "a new shared recipe is marked unverified")
imported.brewAttempts = 4
imported.brewSuccesses = 2
imported.sharedImport = true
imported.unverified = true
eq(RS.ImportSharedRecipe(9001, brewSlots(), { skipRegister = true }), "imported", "reimport of a brewed recipe still refreshes")
eq(imported.sharedImport, nil, "a brewed recipe drops the shared-import flag")
eq(imported.unverified, nil, "a brewed recipe stays verified")
imported.brewAttempts = 3
imported.brewSuccesses = 0
imported.sharedImport = nil
imported.unverified = nil
eq(RS.ImportSharedRecipe(9001, brewSlots(), { skipRegister = true }), "imported", "reimport with attempts and no success still runs")
eq(imported.sharedImport, nil, "attempts without a success do not mark the recipe shared")
eq(imported.unverified, nil, "attempts without a success do not mark the recipe unverified")

local effectCalls = 0
local origEffect = StockPiler.MaterialSpec.ResolveMainEffectId
StockPiler.MaterialSpec.ResolveMainEffectId = function(...)
    effectCalls = effectCalls + 1
    return origEffect(...)
end
local rk = nil
for key, recipe in pairs(StockPiler.Account.recipes) do
    if recipe == imported then
        rk = key
    end
end
effectCalls = 0
local hydrated = RS.GetRecipe(rk)
check(type(hydrated) == "table", "get recipe hydrates a stored row")
eq(effectCalls, 0, "a complete main does not resolve an effect")
-- ResolveSlotSpec prefers a stored complete item over the slot stub.
StockPiler.Account.items["1001"] = nil
hydrated.slots[2].spec.effectId = 0
hydrated.slots[2].spec.incomplete = true
effectCalls = 0
RS.GetRecipe(rk)
check(effectCalls >= 1, "an incomplete main still resolves an effect")

load_module("Source/Knowledge/SeedMap.lua")
local SM = StockPiler.SeedMap
local bagScans = 0
local bagItems = {}
StockPiler.Inventory = {
    GetSnapGen = function()
        return 3
    end,
    ForEachItem = function(fn)
        bagScans = bagScans + 1
        for i = 1, #bagItems do
            fn(bagItems[i])
        end
    end,
}
local origMatch = StockPiler.MaterialSpec.ProductMatches
local origKey = StockPiler.MaterialSpec.ProductKey
StockPiler.MaterialSpec.ProductKey = function(spec)
    return tostring(spec and spec.cacheKey or "")
end
StockPiler.MaterialSpec.ProductMatches = function(item)
    local uid = tonumber(item and (item.uniqueID or item.uid)) or 0
    return uid == 10 or uid == 50
end

local function finger(cacheKey)
    return {
        role = "stabilizer",
        cacheKey = cacheKey,
        tradeSkill = 4,
        skillLevel = 25,
        cultivationType = 0,
        slotType = 1,
        bonuses = { [1] = 1 },
    }
end

bagItems = {
    { uniqueID = 50, name = "Leaf High" },
    { uniqueID = 10, name = "Leaf Low" },
}
StockPiler.Account.items = {}
StockPiler.Account.grows = {}
SM._plantUidCache = nil
SM._plantUidCacheSnap = nil
bagScans = 0
eq(SM.FindPlantUidForSpec(finger("bags")), 10, "bag twins resolve to the lowest uid")
eq(bagScans, 1, "the bag tier is scanned once")
eq(SM.FindPlantUidForSpec(finger("bags")), 10, "the bag result is cached")
eq(bagScans, 1, "a cached plant uid does not scan bags again")

bagItems = {}
StockPiler.Account.items = {
    ["50"] = { uniqueID = 50, name = "Leaf High", kind = "plant" },
    ["10"] = { uniqueID = 10, name = "Leaf Low", kind = "plant" },
}
bagScans = 0
eq(SM.FindPlantUidForSpec(finger("learned")), 10, "learned twins resolve to the lowest uid")

bagItems = { { uniqueID = 77, name = "Other" } }
StockPiler.Account.items = {}
SM._plantUidCache = nil
SM._plantUidCacheSnap = nil
bagScans = 0
eq(SM.FindPlantUidForSpec(finger("miss")), 0, "a miss returns zero")
eq(SM._plantUidCache["miss"], 0, "a miss stays negatively cached")
eq(SM.FindPlantUidForSpec(finger("miss")), 0, "a cached miss returns zero")
eq(bagScans, 1, "a cached miss does not scan bags again")
StockPiler.MaterialSpec.ProductMatches = origMatch
StockPiler.MaterialSpec.ProductKey = origKey

local dbReads = 0
GetDatabaseItemData = function()
    dbReads = dbReads + 1
    return nil
end
dbReads = 0
local unknown = { uid = 70000001, role = "main", incomplete = true }
eq(SM.IsGrowableSpec(unknown), true, "an unknown main still uses the cult-role guess")
eq(dbReads, 1, "an unknown uid reads the item database once")

StockPiler.Knowledge.GetGen = function()
    return 4
end
StockPiler.Inventory.GetSnapGen = function()
    return 8
end
local tipScans = 0
StockPiler.Inventory.ForEachItem = function(fn)
    tipScans = tipScans + 1
    if type(fn) == "function" then
        fn({ uniqueID = 1, name = "Leaf" })
    end
end
StockPiler.Account.items = {}
local realKey = RS.RecipeSpecKey
RS.RecipeSpecKey = function(materials)
    return tostring(materials and materials._fp or "")
end
load_module("Source/View/RecipeTooltip.lua")

local function tipMats(fp, uid)
    local slots = {
        {
            role = "main",
            uid = uid,
            perCraft = 1,
            spec = { role = "main", uid = uid, skillLevel = 0, bonuses = {} },
            _fp = fp,
        },
    }
    slots._fp = fp
    return slots
end

tipScans = 0
StockPiler.RecipeTooltip.BuildRows({ name = "A", recipe = { slots = tipMats("fp-a", 0) } })
eq(tipScans, 1, "the first recipe hover scans bags")
StockPiler.RecipeTooltip.BuildRows({ name = "A", recipe = { slots = tipMats("fp-a", 0) } })
eq(tipScans, 1, "the same fingerprint does not scan again")
StockPiler.RecipeTooltip.BuildRows({ name = "B", recipe = { slots = tipMats("fp-b", 0) } })
eq(tipScans, 2, "a second fingerprint scans once")
StockPiler.RecipeTooltip.BuildRows({ name = "C", recipe = { slots = tipMats("fp-c", 4242) } })
eq(tipScans, 3, "an uncacheable fingerprint still scans")
StockPiler.RecipeTooltip.BuildRows({ name = "A", recipe = { slots = tipMats("fp-a", 0) } })
eq(tipScans, 3, "an uncacheable hover does not drop the other fingerprint")
RS.RecipeSpecKey = realKey

load_module("Source/Stores/InventoryStore.lua")
local Inv = StockPiler.Inventory
Inv._ready = true
Inv._countByUid = { [7] = 0 }
Inv._sampleByUid = {}
Inv._itemBySlot = {
    main = {
        [1] = { uniqueID = 7, name = "Hidden" },
    },
}
eq(Inv.GetSample(7), nil, "a ready uid with no count skips the slot scan")
Inv._sampleByUid[7] = { uniqueID = 7, name = "Cached" }
eq(Inv.GetSample(7).name, "Cached", "a cached sample is returned before the count check")
Inv._sampleByUid = {}
Inv._countByUid[7] = 1
eq(Inv.GetSample(7).name, "Hidden", "a positive count still scans slots")
Inv._ready = false
Inv._sampleByUid = {}
Inv._countByUid[7] = 0
eq(Inv.GetSample(7).name, "Hidden", "an unready snapshot still scans slots")

load_module("Source/Core/Scheduler.lua")
local Sch = StockPiler.Scheduler
Sch._autoGrowFast = false
StockPiler.Buy = { NeedsTick = function() return false end }
StockPiler.Watch = { IsAutoGrowEnabled = function() return true end }
eq(Sch.AutoTickIntervalSec(), Sch.AUTO_TICK_IDLE_SEC, "auto-grow uses the idle interval")
Sch._autoGrowFast = true
eq(Sch.AutoTickIntervalSec(), Sch.AUTO_TICK_SEC, "fast auto-grow still uses the fast interval")

load_module("Source/Core/Debug.lua")
local logs = 0
d = function()
    logs = logs + 1
end
SystemData = { SystemLogFilters = { GENERAL = 0 } }
EA_ChatWindow = { Print = function() end }
StockPiler.Debug.Enabled = false
for i = 1, 200 do
    StockPiler.Debug.ReportProtectedCallFailure("cap", "e" .. tostring(i), true)
end
eq(logs, 200, "the first 200 unique errors are logged")
local mid = logs
StockPiler.Debug.ReportProtectedCallFailure("cap", "e1", true)
eq(logs, mid, "a repeated error inside the cap is not logged again")
StockPiler.Debug.ReportProtectedCallFailure("cap", "e201", true)
eq(logs, mid + 1, "the 201st unique error is logged")
StockPiler.Debug.ReportProtectedCallFailure("cap", "e1", true)
eq(logs, mid + 2, "rotating the cap allows an old error to log once more")

load_module("Source/Core/EventBus.lua")
load_module("Source/Bootstrap.lua")
StockPiler.Persistence.EnsureSettings = function()
    return StockPiler.Settings
end
StockPiler.Persistence.EnsureAccount = function()
    return StockPiler.Account
end
StockPiler.Persistence.StripUnexpectedAccountKeys = function() end
StockPiler.Events = { VENDOR_UPDATED = "vendor-updated" }
local vendorCalls = 0
StockPiler.Buy.OnStoreUpdated = function()
    vendorCalls = vendorCalls + 1
end
StockPiler.Initialize()
StockPiler.Initialize()
StockPiler.EventBus.Fire("vendor-updated", {})
eq(vendorCalls, 1, "re-init keeps a single vendor listener")
StockPiler.Shutdown()
StockPiler.EventBus.Fire("vendor-updated", {})
eq(vendorCalls, 1, "shutdown removes the vendor listener")
StockPiler.Initialize()
StockPiler.EventBus.Fire("vendor-updated", {})
eq(vendorCalls, 2, "init after shutdown listens again")

load_module("Source/Adapters/BagAdapter.lua")
local BA = StockPiler.BagAdapter
GetCraftingItemData = function()
    return {
        [1] = { uniqueID = 9, stackCount = 10, capacity = 40 },
        [2] = { uniqueID = 1, stackCount = 1 },
        [3] = { uniqueID = 2, stackCount = 1 },
        [4] = {},
    }
end
eq(BA.CraftBagBuyRoom(9, 40), 30, "a partial stack still has craft-bag room after the free slot")
GetCraftingItemData = function()
    return {
        [1] = { uniqueID = 1, stackCount = 1 },
        [2] = { uniqueID = 2, stackCount = 1 },
    }
end
eq(BA.CraftBagBuyRoom(8, 40), 0, "a full craft bag leaves no buy room")
GetCraftingItemData = nil
DataUtils = nil
eq(BA.CraftBagBuyRoom(8, 40), nil, "unknown craft-bag occupancy does not invent a room")

load_module("Source/Buy.lua")
local Buy = StockPiler.Buy
StockPiler.Watch = StockPiler.Watch or {}
StockPiler.Watch.IsAutoBuyEnabled = function()
    return true
end
if StockPiler.TradeSkillCaps then
    StockPiler.TradeSkillCaps.CanAutoBuy = function()
        return true
    end
end
StockPiler.VendorAdapter = {
    IsStoreOpen = function()
        return true
    end,
    IsBuybackView = function()
        return false
    end,
    GetPlayerMoneyBrass = function()
        return 1000000
    end,
}
local budgetLine = nil
StockPiler.T = function(key, tokens)
    if key == "buy.blocked.budget" and type(tokens) == "table" then
        budgetLine = tostring(tokens.spent) .. "/" .. tostring(tokens.gold)
        return budgetLine
    end
    return tostring(key)
end
local chat = {}
StockPiler.CraftChatAdapter = {
    Print = function(msg)
        chat[#chat + 1] = tostring(msg)
    end,
}
Buy._visitStopReason = nil
Buy._visitSpentBrass = 0
Buy._visitBought = 0
Buy._visitPurchases = 0
Buy._pendingBuy = nil
Buy._lateBuyAttempts = {}
Buy._nextBuyAfter = 0
Buy._planArmedAfterFill = false
Buy.GetSpentBrass = function()
    return 500000
end
Buy.GetBudgetGold = function()
    return 50
end
Buy.GetReserveGold = function()
    return 10
end
Buy.CollectBuyJobs = function()
    return {
        {
            uid = 77,
            deficit = 2,
            role = "potion",
            acquireKey = "budget-job",
        },
    }
end
Buy.FindStoreMatch = function()
    return { uniqueID = 77, type = 1, slotNum = 3, name = "Herb" }, 100
end
eq(Buy.IssueOne("budget-probe"), false, "a spent lifetime budget stops the visit")
eq(Buy._visitStopReason, "budget", "the visit stops on budget")
eq(Buy._visitSpentBrass, 0, "this visit has not spent brass")
eq(budgetLine, "50g/50g", "the budget notice uses lifetime spend")
eq(chat[#chat], "50g/50g", "the budget chat line is the lifetime spend")

local resumeJobs = {}
local resumeWakes = 0
StockPiler.Scheduler = StockPiler.Scheduler or {}
StockPiler.Scheduler.WakeAutoBuy = function()
    resumeWakes = resumeWakes + 1
end
Buy.CollectBuyJobs = function()
    return resumeJobs
end
Buy.FindStoreMatch = function(job)
    if job.id == "other" then
        return nil, 0
    end
    if job.id == "done" then
        return { uniqueID = 11, type = 34, slotNum = 1, capacity = 40 }, 10
    end
    if job.id == "room" then
        return { uniqueID = 12, type = 34, slotNum = 2, capacity = 40 }, 10
    end
    return nil, 0
end
Buy._visitAcquired = { done = 2 }
Buy._visitCreditLedger = {}
Buy._visitBagSeen = {}
Buy._lateBuyAttempts = {}
resumeJobs = {
    { id = "other", uid = 99, deficit = 4, role = "container", acquireKey = "other" },
}
Buy._visitStopReason = "craft_bag"
eq(Buy.TryResumeCraftBagStop("snap"), false, "an unmatched vendor job does not resume")
eq(Buy._visitStopReason, "craft_bag", "an unmatched job leaves the craft-bag stop")
resumeJobs = {
    { id = "other", uid = 99, deficit = 4, role = "container", acquireKey = "other" },
    { id = "done", uid = 11, deficit = 2, role = "container", acquireKey = "done" },
}
eq(Buy.TryResumeCraftBagStop("snap"), false, "a visit-satisfied job does not resume")
eq(Buy._visitStopReason, "craft_bag", "a satisfied job leaves the craft-bag stop")
GetCraftingItemData = function()
    return {
        [1] = { uniqueID = 1, stackCount = 1 },
        [2] = { uniqueID = 2, stackCount = 1 },
    }
end
resumeJobs = {
    { id = "room", uid = 12, deficit = 3, role = "container", acquireKey = "room" },
}
eq(Buy.TryResumeCraftBagStop("snap"), false, "a full craft bag does not resume")
GetCraftingItemData = function()
    return {
        [1] = { uniqueID = 12, stackCount = 1, capacity = 40 },
        [2] = {},
        [3] = {},
    }
end
local wakesBefore = resumeWakes
eq(Buy.TryResumeCraftBagStop("snap"), true, "craft-bag room resumes the visit")
eq(Buy._visitStopReason, nil, "resume clears the craft-bag stop")
eq(resumeWakes, wakesBefore + 1, "resume wakes autobuy once")

load_module("Source/SkillUp.lua")
local SU = StockPiler.SkillUp
local apoOn = true
SU.ShouldApoBrew = function()
    return apoOn == true
end
SU.CountApoContainers = function()
    return 0
end
SU.ShouldApoBuyContainer = function()
    return false
end
local stallPrints = 0
StockPiler.Debug = StockPiler.Debug or {}
StockPiler.Debug.Print = function()
    stallPrints = stallPrints + 1
end
SU._apoStallLatch = nil
SU.MaybeNotifyApoStall("wait_cult")
eq(stallPrints, 1, "the first apo stall prints once")
eq(SU._apoStallLatch ~= nil, true, "the apo stall latches")
SU.MaybeNotifyApoStall("need_mats")
eq(stallPrints, 1, "a later stall reason does not print again")
apoOn = false
SU.MaybeNotifyApoStall("need_mats")
eq(SU._apoStallLatch, nil, "turning apo off clears the stall latch")
eq(stallPrints, 1, "clearing the latch does not print")
apoOn = true
SU.MaybeNotifyApoStall("wait_cult")
eq(stallPrints, 2, "a new stall episode prints once")

if failures > 0 then
    io.stderr:write(string.format("%d/%d checks failed\n", failures, checks))
    os.exit(1)
end
print(string.format("release_113_surgical: %d checks passed", checks))
