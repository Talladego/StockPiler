-- Merchant left open must say so once when refine work is waiting (issue 50).
-- Run: lua5.1 tests/refine_vendor_block.lua

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

local storeOpen = true
local snap = 1
local items = {}
local shouldBrew = true
local brewWhy = "need_resin"
local brewRecipe = nil
local surplus = 3
local wakes = 0
local prints = {}

StockPiler = {
    Util = {
        NowSec = function()
            return 1000
        end,
        T = function(key)
            return tostring(key)
        end,
    },
    Debug = {
        Print = function(msg)
            prints[#prints + 1] = tostring(msg)
        end,
    },
    Scheduler = {
        WakeAutoGrow = function()
            wakes = wakes + 1
        end,
    },
    VendorAdapter = {
        IsStoreOpen = function()
            return storeOpen == true
        end,
    },
    Grow = {
        IsEnabled = function()
            return true
        end,
        HasEmptyPlot = function()
            return false
        end,
        HasPendingBufferRefine = function()
            return false
        end,
        IsFillBlocked = function()
            return false
        end,
    },
    Watch = {
        IsAutoGrowEnabled = function()
            return true
        end,
        IsSeedBufferEnabled = function()
            return false
        end,
        GetGen = function()
            return 1
        end,
    },
    Inventory = {
        GetSnapGen = function()
            return snap
        end,
        CountByUid = function(uid)
            uid = tonumber(uid) or 0
            if uid == 42 or uid == 7 then
                return 4
            end
            return 0
        end,
        CanUseCraftingItem = function()
            return true
        end,
        ForEachItem = function(fn)
            for i = 1, #items do
                fn(items[i].item, items[i].bag, items[i].slot)
            end
        end,
    },
    SeedMap = {
        IsGrowableSpec = function()
            return true
        end,
        IsBagSeedOrSpore = function()
            return false
        end,
    },
    MaterialSpec = {
        FromItemData = function(item)
            return {
                role = "main",
                skillLevel = tonumber(item and item.skillLevel) or 25,
            }
        end,
    },
}

load_module("Source/Locale/Locale.lua")
load_module("Source/Locale/enUS.lua")
StockPiler.Locale.SetLanguage(1)

load_module("Source/SkillUp.lua")
local SkillUp = StockPiler.SkillUp
SkillUp.ShouldApoBrew = function()
    return shouldBrew == true
end
SkillUp.BuildApoBrewRecipe = function()
    if brewRecipe ~= nil then
        return brewRecipe, nil
    end
    return nil, brewWhy
end
SkillUp.ApoTargetTier = function()
    return 50
end
SkillUp.ListApoBagMaterials = function(role)
    if role ~= "main" then
        return {}
    end
    return {
        {
            uid = 42,
            seedUid = 43,
            count = 4,
            bagCount = 4,
            spec = { role = "main", key = "leaf" },
        },
    }
end
SkillUp.PlantBrewSurplus = function()
    return surplus
end

load_module("Source/Refine.lua")
load_module("Source/Core/Orchestrator.lua")
load_module("Source/Buy.lua")

local Refine = StockPiler.Refine
local Orch = StockPiler.Orchestrator
local Buy = StockPiler.Buy
local TIP = "<icon02486> Refine stalled - close the merchant window to continue."

eq(StockPiler.T("refine.blocked.vendor_open"), TIP, "vendor-open refine tip is the locale line")

local function plantItem(uid, skill)
    return {
        item = {
            uniqueID = uid,
            stackCount = 4,
            isRefinable = true,
            slot = 3,
            skillLevel = skill,
            name = "Leaf",
        },
        bag = "craft",
        slot = 3,
    }
end

local function resetNotify()
    prints = {}
    Refine.ClearBlockedNotify()
    Refine.InvalidateIntentCache()
    snap = snap + 1
    Refine._bagIndexGen = -1
    Refine._refineDirty = false
    Refine._refineDirtyReason = nil
end

-- No refine work: merchant open must not chat.
shouldBrew = false
items = {}
storeOpen = true
resetNotify()
eq(SkillUp.HasApoResinRefinePlant(), false, "apo resin refine is off when ShouldApoBrew is false")
eq(Refine.MaybeNotifyBlocked(), false, "no refine work does not notify")
eq(#prints, 0, "no refine work does not print")
eq(Refine._blockedVendorNotified, false, "a false alarm does not latch the tip")

local allowProbe, whyProbe = Refine.ShouldAllowRefineNow({ ignoreVendor = true })
check(whyProbe ~= "vendor-open", "ignoreVendor does not report vendor-open")
-- Plots are full here, so the probe gate is not the reason. Flip to an empty
-- unprobed plot and confirm ignoreVendor still looks for intents.
StockPiler.Grow.HasEmptyPlot = function()
    return true
end
StockPiler.Grow.PeekSeedsForNextPlant = function()
    return false, "unprobed"
end
eq(select(2, Refine.ShouldAllowRefineNow()), "vendor-open", "an open merchant blocks refine")
local probedAllow, probedWhy = Refine.ShouldAllowRefineNow({ ignoreVendor = true })
check(probedWhy ~= "vendor-open", "ignoreVendor skips the merchant block")
check(probedWhy ~= "plant-probe-pending", "ignoreVendor does not wait on a plant probe")
check(probedAllow == true or probedWhy == "pre-plant" or probedWhy == "idle-grow",
    "ignoreVendor still returns a refine decision")
StockPiler.Grow.HasEmptyPlot = function()
    return false
end
StockPiler.Grow.PeekSeedsForNextPlant = nil

-- Brew-main surplus is refinable while the recipe is resin-short.
shouldBrew = true
brewRecipe = nil
brewWhy = "need_resin"
surplus = 3
items = { plantItem(42, 50) }
storeOpen = true
resetNotify()
eq(SkillUp.HasApoResinRefinePlant(), true, "a growable brew main counts as apo resin refine")
local resinAllow, resinWhy = Refine.ShouldAllowRefineNow({ ignoreVendor = true })
eq(resinAllow, true, "apo resin refine is allowed when the merchant is ignored")
eq(resinWhy, "skill-up-resin", "the allow reason is skill-up resin")
local intents = Refine.CollectIntents({ ignoreVendor = true })
check(type(intents) == "table" and #intents > 0, "apo resin refine produces a refine intent")
eq(Refine.MaybeNotifyBlocked(), true, "the first vendor block with work notifies")
eq(#prints, 1, "the tip is printed once")
eq(prints[1], TIP, "the tip text matches the locale line")
eq(Refine._blockedVendorNotified, true, "the tip latches after the first print")
eq(Refine.MaybeNotifyBlocked(), false, "the same open merchant does not notify again")
eq(#prints, 1, "the second check does not print")

-- Leftover lower-tier main, no current brew main.
SkillUp.ListApoBagMaterials = function()
    return {}
end
items = { plantItem(7, 25) }
brewWhy = "unstable"
resetNotify()
eq(SkillUp.HasApoResinRefinePlant(), true, "a leftover lower-tier main counts as apo resin refine")

-- Uses below 1 is not work, so the open merchant stays quiet.
surplus = 0
SkillUp.ListApoBagMaterials = function(role)
    if role ~= "main" then
        return {}
    end
    return {
        {
            uid = 42,
            seedUid = 43,
            count = 4,
            bagCount = 4,
            spec = { role = "main" },
        },
    }
end
items = {}
resetNotify()
eq(SkillUp.HasApoResinRefinePlant(), false, "zero refinable uses is not apo resin refine")
eq(Refine.MaybeNotifyBlocked(), false, "zero intents do not notify")
eq(#prints, 0, "zero intents do not print")

-- Real work again, then closing the merchant clears the latch and wakes AutoGrow.
surplus = 3
items = { plantItem(42, 50) }
resetNotify()
eq(Refine.MaybeNotifyBlocked(), true, "work notifies before the merchant closes")
eq(Refine._blockedVendorNotified, true, "the latch is set before close")
local wakesBefore = wakes
Buy.OnVendorClosed()
eq(Refine._blockedVendorNotified, false, "OnVendorClosed clears the refine tip latch")
eq(wakes, wakesBefore + 1, "OnVendorClosed wakes AutoGrow")
storeOpen = false
eq(Refine.MaybeNotifyBlocked(), false, "a closed merchant does not keep the vendor tip")
storeOpen = true
eq(Refine.MaybeNotifyBlocked(), true, "reopening with work can notify again")

-- Plots full and refine dirty cleared still counts as AutoGrow work.
Refine._refineDirty = false
Orch._fillBlocked = true
eq(Orch.HasAutoGrowWork({
    respectFillBlock = true,
    emptyPlot = true,
    refineDirty = true,
}), true, "apo resin refine keeps AutoGrow awake when plots are full")

shouldBrew = false
eq(Orch.HasAutoGrowWork({
    respectFillBlock = true,
    emptyPlot = true,
    refineDirty = true,
}), false, "without apo resin refine a full quiet garden is not work")

if failures > 0 then
    io.stderr:write(string.format("%d/%d checks failed\n", failures, checks))
    os.exit(1)
end
print(string.format("refine_vendor_block: %d checks passed", checks))
