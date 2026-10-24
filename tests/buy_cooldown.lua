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
