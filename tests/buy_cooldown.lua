-- A no-spend cooldown does not rescan the vendor every frame.
-- Run: lua5.1 tests/buy_cooldown.lua

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

local now = 1000
local matches = 0
local wakes = 0
local moneyUi = 0
local watchDirty = 0
local noContainer = nil

function towstring(s)
    return tostring(s)
end

StockPiler = {
    Util = { NowSec = function() return now end },
    Inventory = {
        CountByUid = function() return 0 end,
        GetSnapGen = function() return 1 end,
    },
    Watch = {
        IsAutoBuyEnabled = function() return true end,
        GetAutoBuyReserveGold = function() return 0 end,
        GetAutoBuyBudgetGold = function() return 100 end,
        GetAutoBuySpentBrass = function() return 0 end,
        GetGen = function() return 1 end,
    },
    TradeSkillCaps = {
        CanAutoBuy = function() return true end,
        CanAutoGrow = function() return false end,
        LevelsHash = function() return "1" end,
    },
    MaterialSpec = {
        Matches = function()
            matches = matches + 1
            return false
        end,
    },
    VendorAdapter = {
        IsStoreOpen = function() return true end,
        GetPlayerMoneyBrass = function() return 100000 end,
        BuyItem = function() return false, "skip" end,
        GetMatchIndex = function()
            local rows = {}
            for i = 1, 60 do
                rows[i] = { uniqueID = 1000 + i, slotNum = i, stackCount = 1 }
            end
            return { rows = rows }
        end,
    },
    Planner = {
        CollectVendorBuyJobs = function()
            local jobs = {}
            for i = 1, 6 do
                jobs[i] = { uid = 5000 + i, deficit = 2, specKey = "j" .. i }
            end
            return jobs
        end,
        GetVendorBuyMeta = function()
            return { source = "all", maxBottleGap = 1, focusWatchCount = 1 }
        end,
    },
    Scheduler = {
        WakeAutoBuy = function()
            wakes = wakes + 1
        end,
    },
    EventBus = {
        FireWatchUiDirty = function()
            watchDirty = watchDirty + 1
        end,
    },
    SkillUp = {
        SetNoVendorContainer = function(flag)
            noContainer = flag == true
        end,
    },
}
StockPilerTabWatch = {
    RefreshAutoBuyMoneyUi = function()
        moneyUi = moneyUi + 1
    end,
    UpdateRows = function()
        moneyUi = moneyUi + 1
    end,
}

load_module("Source/Buy.lua")
local Buy = StockPiler.Buy

for i = 1, 6 do
    Buy._noSpendCooldownUntil[5000 + i] = now + 6
end
matches = 0
wakes = 0
for _ = 1, 30 do
    Buy.IssueOne("t")
    now = now + 0.016
end
eq(matches, 0, "cooldown skips vendor matching")
eq(wakes, 0, "a long cooldown does not wake buy every frame")
check((tonumber(Buy._nextBuyAfter) or 0) > 1000, "the next buy waits for the cooldown")

-- Mixed probe: one timed-out uid among six jobs, only uid 1001 is in a 60-row store.
now = 3000
Buy._nextBuyAfter = 0
Buy._nextBuyIsCooldown = false
Buy._noSpendCooldownUntil = {}
Buy._lateBuyAttempts = {}
Buy._pendingBuy = nil
Buy._visitStopReason = nil
Buy._visitPurchases = 0
Buy._visitBought = 0
Buy._jobsCache = nil
Buy._storeMatchCache = nil
Buy._storeMatchCacheToken = nil
StockPiler.VendorAdapter._matchIndexGen = 1
StockPiler.Planner.CollectVendorBuyJobs = function()
    local jobs = {}
    for i = 1, 6 do
        local uid = 1000 + i
        jobs[i] = {
            uid = uid,
            deficit = 1,
            specKey = "j" .. uid,
            spec = { uid = uid },
        }
    end
    return jobs
end
StockPiler.VendorAdapter.GetMatchIndex = function()
    local rows = {}
    for i = 1, 60 do
        local uid = (i == 1) and 1001 or (3000 + i)
        rows[i] = {
            canbuy = true,
            cost = 10,
            item = {
                uniqueID = uid,
                slotNum = i,
                stackCount = 1,
                cost = 10,
                name = "Row " .. i,
            },
        }
    end
    return { rows = rows }
end
StockPiler.VendorAdapter.BuyItem = function()
    return true
end
StockPiler.MaterialSpec.Matches = function(item, spec)
    matches = matches + 1
    local iu = tonumber(item and item.uniqueID) or 0
    local su = tonumber(spec and spec.uid) or 0
    return iu > 0 and iu == su
end
matches = 0
check(Buy.IssueOne("buy") == true, "buying uid 1001 arms a pending purchase")
now = now + 3.6
local timedOut = Buy.IssueOne("timeout")
check(timedOut ~= true, "the 3.6s no-spend timeout does not keep buying")
matches = 0
wakes = 0
local trues = 0
local quietWakes = 0
local tailWakes = 0
local frames = 360
local gap = tonumber(Buy.POST_BUY_GAP_SEC) or 0.35
for _ = 1, frames do
    local wakesBefore = wakes
    if Buy.IssueOne("cool") == true then
        trues = trues + 1
    end
    local woke = wakes > wakesBefore
    local wait = (tonumber(Buy._nextBuyAfter) or 0) - now
    if woke then
        if wait > gap then
            quietWakes = quietWakes + 1
        else
            tailWakes = tailWakes + 1
        end
    end
    now = now + (1 / 60)
end
eq(trues, 0, "mixed cooldown does not return true across 6s at 60fps")
eq(matches, 0, "mixed cooldown does not rescan the store")
eq(quietWakes, 0, "a long mixed cooldown does not wake buy every frame")
check(tailWakes > 0 and tailWakes < 40, "AutoBuy wakes only inside the short resume gap")

now = 2000
Buy._nextBuyAfter = 0
Buy._noSpendCooldownUntil = {}
Buy._jobsCache = nil
StockPiler.Planner.CollectVendorBuyJobs = function()
    return {
        {
            uid = 9,
            deficit = 1,
            skillUp = true,
            role = "container",
            spec = { uid = 9, role = "container" },
            specKey = "vial",
        },
    }
end
StockPiler.VendorAdapter.FindStoreRowsByUid = function(uid)
    if uid == 9 then
        return {
            { item = { uniqueID = 9, slotNum = 1, cost = 10 }, cost = 10 },
        }
    end
    return {}
end
Buy._visitStopReason = nil
Buy.IssueOne("container")
eq(noContainer, false, "a matched container clears the no-vendor flag once")

if failures > 0 then
    io.stderr:write(string.format("%d/%d checks failed\n", failures, checks))
    os.exit(1)
end
print(string.format("buy_cooldown: %d checks passed", checks))
