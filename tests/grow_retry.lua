-- Unconfirmed plants back off and stop. Practice plots take a basic additive.
-- Run: lua5.1 tests/grow_retry.lua

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
    CultivationTypes = { NONE = 0, SEED = 1, SOIL = 2, WATERCAN = 3, NUTRIENT = 4, SPORE = 5 },
}

local now = 1000
local notes = 0
StockPiler = {}
StockPiler.FrameCounter = 1
StockPiler.Util = {
    NowSec = function() return now end,
    ToNarrow = function(v) return tostring(v or "") end,
    T = function(k) return k end,
}
StockPiler.T = function(key, tokens)
    if key == "grow.plant_stalled" then
        return "stalled " .. tostring(tokens and tokens.plot)
    end
    return tostring(key)
end
StockPiler.Watch = {
    IsAutoGrowEnabled = function() return true end,
    IsAutoGrowAdditivesEnabled = function() return true end,
}
StockPiler.TradeSkillCaps = {
    CanAutoGrow = function() return true end,
    GetCultSkill = function() return 30 end,
}
StockPiler.Scheduler = { _armedPlantDue = true }
StockPiler.Orchestrator = {
    SetFillBlocked = function() end,
    ClearFillBlocked = function() end,
}
StockPiler.SkillUp = {
    IsCultEnabled = function() return true end,
    NoteCultAttempt = function()
        notes = notes + 1
    end,
}
StockPiler.Ui = { Print = function() end }

local plot = { plotNum = 1, stage = 0, seedUid = 0, additives = {}, locked = false }
StockPiler.Garden = {
    GetPlot = function(n) return n == 1 and plot or nil end,
    GetPlots = function() return { [1] = plot } end,
}
local plantCalls = {}
load_module("Source/Adapters/CultivatorAdapter.lua")
local CA = StockPiler.CultivatorAdapter
CA.NumPlots = function() return 1 end
CA.ReadPlot = function() return plot end
CA.SetCurrentPlot = function() return true end
CA.PlantSeed = function(p, slot)
    plantCalls[#plantCalls + 1] = { t = now, plot = p, slot = slot }
    return true
end
StockPiler.BagAdapter = {
    FindSeedSlot = function()
        return 12, { name = "Dusty Seed" }, 4
    end,
}

load_module("Source/Grow.lua")
load_module("Source/Knowledge/Additives.lua")
local Grow = StockPiler.Grow
Grow.PickPlantCandidate = function()
    return { seedUid = 84235, plantReason = "skill_up", role = "main" }
end
Grow.ShouldHoldPlantForReadyHarvest = function()
    return false
end

for t = 1000, 1600 do
    now = t
    Grow.ExpireStalePending()
    Grow.IssuePlantOne("op")
end
check(#plantCalls <= 4, "a rejected seed is not replanted forever")
check(#plantCalls >= 1, "the first plant is still attempted")
eq(Grow._plantStallReason[1], "unconfirmed", "the plot stops after repeated rejects")
eq(Grow.PlotPlantBlocked(1), true, "the stall is honored by the next empty-plot search")
eq(notes, 0, "an unconfirmed skill-up plant is not counted as an attempt")
eq(tonumber(Grow._plantQuietUntil) or 0, 0, "one plot does not quiet every plot")

plot.stage = 1
plot.seedUid = 84235
Grow._pendingPlant[1] = 1
Grow._pendingSeedUid[1] = 84235
Grow._plotReason[1] = "skill_up"
Grow.OnCultivationUpdated(1)
eq(notes, 1, "a confirmed skill-up plant records one attempt")

StockPiler.Inventory = {
    _ready = true,
    _itemBySlot = { craft = {
        [3] = {
            uniqueID = 7001, name = "Common Soil", cultivationType = 2,
            craftingSkillRequirement = 1,
            craftingBonus = {
                { bonusReference = 10, bonusValue = 65536 - 10 },
                { bonusReference = 12, bonusValue = 5 },
            },
        },
        [4] = {
            uniqueID = 7002, name = "Rare Soil of Plenty", cultivationType = 2,
            craftingSkillRequirement = 25,
            craftingBonus = {
                { bonusReference = 10, bonusValue = 65536 - 20 },
                { bonusReference = 14, bonusValue = 10 },
            },
        },
    } },
    CanUseCraftingItem = function() return true end,
}
plot.stage = 1
plot.seedUid = 84235
plot.additives = {}
Grow._plotReason[1] = "skill_up"
Grow._pendingAdditive = {}
Grow._pendingAdditiveAt = {}
Grow._additiveStall = {}
Grow._additiveAttempts = {}
local AD = StockPiler.Additives
local cheap = AD.PickNext({ plotReason = Grow._plotReason })
eq(cheap and cheap.uniqueID, 7001, "a practice plot uses the basic additive")

Grow._plotReason[1] = "watch"
local best = AD.PickNext({})
eq(best and best.uniqueID, 7002, "a watch plot uses the strongest additive")

local adds = 0
CA.AddAdditive = function()
    adds = adds + 1
    return true
end
Grow._plotReason[1] = "surplus"
eq(Grow.TryAdditive("op"), true, "the first additive apply is sent")
eq(adds, 1, "one additive is sent")
eq(Grow.NeedsCurrentStageAdditive(), false, "an in-flight additive is not still due")
eq(Grow.TryAdditive("op"), false, "a second apply waits for the first")
eq(adds, 1, "the in-flight apply is not repeated")

now = now + 11
eq(Grow.TryAdditive("op"), true, "a timed-out apply can retry")
now = now + 11
eq(Grow.TryAdditive("op"), true, "a second retry is allowed")
now = now + 11
eq(Grow.TryAdditive("op"), false, "retries stop at the cap")
eq(adds, 3, "the additive is not applied forever")
eq(Grow._additiveStall[1], true, "the plot is marked stalled")

if failures > 0 then
    io.stderr:write(string.format("%d/%d checks failed\n", failures, checks))
    os.exit(1)
end
print(string.format("grow_retry: %d checks passed", checks))
