-- SkillUp apo brew with output uid 0 must count as Ready (issue 49).
-- Run: lua5.1 tests/skillup_apo_ready.lua

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

local shouldBrew = true
local rows = {}

StockPiler = {
    T = function(key)
        return tostring(key)
    end,
    Util = {
        NowSec = function()
            return 1000
        end,
        T = function(key)
            return tostring(key)
        end,
    },
    TradeSkillCaps = {
        CanBrewPotions = function()
            return true
        end,
    },
    SkillUp = {
        ShouldApoBrew = function()
            return shouldBrew == true
        end,
    },
    PlanSnapshot = {
        Get = function()
            return { rows = rows }
        end,
    },
}

load_module("Source/Brew.lua")
local Brew = StockPiler.Brew

local function skillRow(overrides)
    local row = {
        skillUp = true,
        uniqueID = 0,
        outputUid = 0,
        craftable = 3,
        statusKey = "ready_to_craft",
        potionKey = "skill_up_apo",
    }
    if type(overrides) == "table" then
        for k, v in pairs(overrides) do
            row[k] = v
        end
    end
    return row
end

shouldBrew = true
rows = { skillRow() }
local ready = Brew.PickReadyWatch()
eq(ready, rows[1], "a craftable skill-up row with output uid 0 is Ready")
check(ready and ready.skillUp == true, "the Ready row is the skill-up brew")

rows = { skillRow({ craftable = 0 }) }
eq(Brew.PickReadyWatch(), nil, "skill-up with craftable 0 is not Ready")

rows = { skillRow({ craftable = -1 }) }
eq(Brew.PickReadyWatch(), nil, "skill-up with negative craftable is not Ready")

rows = { skillRow({ statusKey = "craft_bag_full" }) }
eq(Brew.PickReadyWatch(), nil, "skill-up craft_bag_full is not Ready")

shouldBrew = false
rows = { skillRow() }
eq(Brew.PickReadyWatch(), nil, "skill-up is not Ready when ShouldApoBrew is false")

shouldBrew = true
rows = { skillRow({ uniqueID = 99, outputUid = 99, potionMin = 5 }) }
eq(Brew.PickReadyWatch(), nil, "a known output uid still needs a live bag count below target")

if failures > 0 then
    io.stderr:write(string.format("%d/%d checks failed\n", failures, checks))
    os.exit(1)
end
print(string.format("skillup_apo_ready: %d checks passed", checks))
