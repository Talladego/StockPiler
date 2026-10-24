-- AutoBuy keeps credit for a money-confirmed buy when an earlier bag update lands.
-- Run: lua5.1 tests/buy_acquired.lua

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

local now = 100
local money = 1000000
local bag = {}
local snapGen = 1
local buys = {}
local spent = 0

function towstring(s)
    return tostring(s)
end

StockPiler = {
    Util = { NowSec = function() return now end },
    Inventory = {
        CountByUid = function(uid) return bag[uid] or 0 end,
        GetSnapGen = function() return snapGen end,
        ForEachItem = function() end,
    },
    Watch = {
        IsAutoBuyEnabled = function() return true end,
        GetAutoBuyReserveGold = function() return 0 end,
        GetAutoBuyBudgetGold = function() return 1000 end,
        GetAutoBuySpentBrass = function() return spent end,
        AddAutoBuySpentBrass = function(n) spent = spent + n end,
        GetGen = function() return 1 end,
    },
    TradeSkillCaps = {
        CanAutoBuy = function() return true end,
        CanAutoGrow = function() return true end,
        LevelsHash = function() return "x" end,
    },
    MaterialSpec = {
        Matches = function(item, spec) return item.uniqueID == spec.uid end,
    },
}

local store = {
    { uniqueID = 1001, slotNum = 1, cost = 100, stackCount = 1, name = "Vial A" },
    { uniqueID = 1002, slotNum = 2, cost = 200, stackCount = 1, name = "Mat B" },
}
local rows = {}
for i, it in ipairs(store) do
    rows[i] = { item = it, uid = it.uniqueID, cost = it.cost, canbuy = true }
end

StockPiler.VendorAdapter = {
    IsStoreOpen = function() return true end,
    IsBuybackView = function() return false end,
    GetPlayerMoneyBrass = function() return money end,
    GetMatchIndex = function() return { rows = rows } end,
    BuyItem = function(item, qty)
        buys[#buys + 1] = { uid = item.uniqueID, qty = qty, at = now }
        return true
    end,
}

local need = { [1001] = 5, [1002] = 5 }
StockPiler.Planner = {
    CollectVendorBuyJobs = function()
        local jobs = {}
        for _, uid in ipairs({ 1001, 1002 }) do
            local d = need[uid] - (bag[uid] or 0)
            if d > 0 then
                jobs[#jobs + 1] = {
                    uid = uid,
                    spec = { uid = uid },
                    deficit = d,
                    acquireKey = "sk:" .. uid,
                    specKey = uid,
                }
            end
        end
        return jobs
    end,
}

load_module("Source/Buy.lua")
local Buy = StockPiler.Buy
Buy._storeWasOpen = true

local function step()
    return Buy.IssueOne("probe")
end

step()
eq(#buys, 1, "first issue buys A")
eq(buys[1].uid, 1001, "first buy is A")
eq(buys[1].qty, 5, "A quantity is the deficit")

now = 100.10
money = money - 500
step()
eq(Buy._pendingBuy, nil, "A money drop confirms the pending buy")
eq(tostring(Buy._visitAcquired["sk:1001"]), "5", "A credit is a number")

now = 100.50
step()
eq(#buys, 2, "gap elapsed, B is bought once")
eq(buys[2].uid, 1002, "second buy is B")
eq(buys[2].qty, 5, "B quantity is the deficit")

now = 100.60
money = money - 1000
step()
eq(Buy._pendingBuy, nil, "B money drop confirms")
eq(tostring(Buy._visitAcquired["sk:1002"]), "5", "B credit stays a number")

now = 100.70
bag[1001] = 5
snapGen = snapGen + 1
Buy.OnInventorySnapshot()
eq(tostring(Buy._visitAcquired["sk:1002"]), "5", "A bag update does not clear B")
eq(Buy._visitAcquired["sk:1001"], nil, "A credit clears once A is in the bag")

now = 101.10
step()
eq(#buys, 2, "next tick does not buy B again")
eq(tostring(Buy._visitAcquired["sk:1002"]), "5", "B credit remains until B reaches the bag")

if failures > 0 then
    io.stderr:write(string.format("%d/%d checks failed\n", failures, checks))
    os.exit(1)
end
print(string.format("buy_acquired: %d checks passed", checks))
