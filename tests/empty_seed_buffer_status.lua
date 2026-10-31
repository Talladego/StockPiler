-- Empty potion seed lines paint red Buy seeds, not Seed buffer or climb text.
-- A partial cushion stays Seed buffer when no climb is waiting on a purchase.
-- Run: lua5.1 tests/empty_seed_buffer_status.lua

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

local SEED = 3010200
local SEED_PARTIAL = 3010201
local POTION = 9001
local POTION_PARTIAL = 9002
local creditByUid = {}
local canGrow = true
local climbs = {}

StockPiler = {}
StockPiler.FrameCounter = 1
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
    T = function(k)
        return tostring(k)
    end,
}
StockPiler.TradeSkillCaps = {
    CanAutoGrow = function()
        return canGrow == true
    end,
    CanBrewPotions = function()
        return true
    end,
    GetCultSkill = function()
        return 200
    end,
    GetApoSkill = function()
        return 200
    end,
}
StockPiler.Inventory = {
    _ready = true,
    GetSnapGen = function()
        return 1
    end,
    CountByUid = function(uid)
        uid = tonumber(uid) or 0
        if uid == POTION or uid == POTION_PARTIAL then
            return 40
        end
        return 0
    end,
    ForEachItem = function() end,
    CanUseCraftingItem = function()
        return true
    end,
}
StockPiler.MaterialSpec = {
    Key = function(spec)
        return spec and spec.key
    end,
    ProductKey = function(spec)
        return spec and (spec.pk or spec.key) or ""
    end,
}
StockPiler.Items = {
    GetByUid = function(uid)
        uid = tonumber(uid) or 0
        if uid <= 0 then
            return nil
        end
        return { uniqueID = uid, name = "Goldweed" }
    end,
}
StockPiler.SeedMap = {
    IsGrowableSpec = function()
        return true
    end,
    IsHarvestByproduct = function()
        return false
    end,
    GenusKeyFromName = function()
        return "goldweed"
    end,
}
StockPiler.RecipeSpec = {
    HydrateRecipeSlots = function() end,
    ShouldAutoGrowPotion = function()
        return true
    end,
    WatchHasSeedBufferShort = function()
        return true
    end,
    CountCraftsPossible = function()
        return 0
    end,
    StableCraftYield = function()
        return 1
    end,
    CountPotionsCraftable = function()
        return 0
    end,
    GetRecipeStatsGen = function()
        return 1
    end,
}
StockPiler.Watch = {
    GetGen = function()
        return 1
    end,
    GetWatches = function()
        return {
            ["uid:9001"] = { enabled = true, autoGrow = true, targetStock = 40 },
        }
    end,
    IsAutoGrowEnabled = function()
        return true
    end,
    IsAutoBuyEnabled = function()
        return true
    end,
    IsSeedBufferEnabled = function()
        return true
    end,
    GetSeedBufferMin = function()
        return 5
    end,
    IsOptimisticOutcomeEstimate = function()
        return true
    end,
    ResolveWatchEntry = function(key)
        return { enabled = true, autoGrow = true, targetStock = 40 }, key
    end,
}
StockPiler.Refine = {
    GetSeedBudget = function(uid)
        uid = tonumber(uid) or 0
        local n = tonumber(creditByUid[uid]) or 0
        return {
            live = n,
            ground = 0,
            outstanding = 0,
            credit = n,
            headroom = math.max(0, 5 - n),
            bufferMin = 5,
        }
    end,
}
StockPiler.UpgradeSeed = {
    IsEnabled = function()
        return true
    end,
    ListClimbStatuses = function()
        return climbs
    end,
}

load_module("Source/Planner/Planner.lua")
local P = StockPiler.Planner

local function rowFor(seedCredit, seedUid, potionUid)
    seedUid = seedUid or SEED
    potionUid = potionUid or POTION
    creditByUid[seedUid] = seedCredit
    return {
        kind = "potion",
        id = "uid:" .. tostring(potionUid),
        potionKey = "uid:" .. tostring(potionUid),
        uniqueID = potionUid,
        potionMin = 40,
        potionHave = 40,
        potionDeficit = 0,
        craftable = 0,
        statusKey = "potion_stocked",
        statusText = "plan.status.potion_stocked",
        autoGrow = true,
        recipe = { slots = {}, outputUid = potionUid },
        seedBufferSeedUids = { seedUid },
        seedBufferPlantUids = {},
        _seedBufferUidSnapGen = 1,
        _craftableSnapGen = 1,
        _craftableStructKey = "keep",
    }
end

climbs = {
    {
        why = "need_buy",
        seedUid = SEED,
        plantUid = 4010200,
        haveReq = 0,
        needReq = 200,
        climbCap = 200,
    },
}
local empty = rowFor(0)
P.PatchWatchRowsLiveCounts({ empty }, { syncSnapshot = false })
eq(empty.statusKey, "buy_ingredients", "an empty seed line paints Buy seeds, not Seed buffer")
eq(empty.statusText, "watch.note.buy_seeds", "that paint uses the Buy seeds label")
check(empty.statusKey ~= "need_seeds", "an empty seed line is not Seed buffer")
check(empty.statusKey ~= "upgrading_seed", "a need_buy climb does not hide Buy seeds")
check(empty.statusKey ~= "restocking", "an empty seed line is not Restocking")
eq(empty.seedBufferShort, true, "an empty seed line still marks the buffer short")

-- No climb is raised for a partial line (see upgrade_cult_floor). Status stays Seed buffer.
climbs = {}
local partial = rowFor(3)
P.PatchWatchRowsLiveCounts({ partial }, { syncSnapshot = false })
eq(partial.statusKey, "need_seeds", "a partial cushion stays Seed buffer")
eq(partial.statusText, "plan.status.need_seeds", "partial cushion text is Seed buffer")

canGrow = false
local buy = rowFor(0)
P.PatchWatchRowsLiveCounts({ buy }, { syncSnapshot = false })
eq(buy.statusKey, "buy_ingredients", "an empty line with no cultivation paints Buy seeds")
eq(buy.statusText, "watch.note.buy_seeds", "that paint uses the Buy seeds label")

-- Same family, one empty line and one partial cushion, one purchase climb.
canGrow = true
creditByUid[SEED] = 0
creditByUid[SEED_PARTIAL] = 3
climbs = {
    {
        why = "need_buy",
        genus = "goldweed",
        seedUid = 0,
        plantUid = 0,
        haveReq = 0,
        needReq = 200,
        climbCap = 200,
    },
}
local emptyFamily = rowFor(0, SEED, POTION)
local partialFamily = rowFor(3, SEED_PARTIAL, POTION_PARTIAL)
P.PatchWatchRowsLiveCounts({ emptyFamily, partialFamily }, { syncSnapshot = false })
eq(emptyFamily.statusKey, "buy_ingredients", "the empty family line shows Buy seeds")
eq(emptyFamily.statusText, "watch.note.buy_seeds", "the empty family line uses the Buy seeds label")
eq(partialFamily.statusKey, "need_seeds", "the partial family line stays Seed buffer")
eq(partialFamily.statusText, "plan.status.need_seeds", "the partial family line does not turn red")

if failures > 0 then
    io.stderr:write(string.format("%d/%d checks failed\n", failures, checks))
    os.exit(1)
end
print(string.format("empty_seed_buffer_status: %d checks passed", checks))
