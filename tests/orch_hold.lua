-- Orch decision hold busts Have only when the bag moved or cached counts were served.
-- Run: lua5.1 tests/orch_hold.lua

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

local now = 10
local snap = 3
local invalidated = 0
local prewarms = 0
local held = false

function towstring(s)
    return tostring(s)
end

StockPiler = {
    FrameCounter = 1,
    Util = { NowSec = function() return now end },
    Inventory = { GetSnapGen = function() return snap end },
    Planner = {
        InvalidateHaveWarm = function()
            invalidated = invalidated + 1
        end,
        ConsumedHeldCounts = function()
            local used = held
            held = false
            return used
        end,
    },
    FrameWork = {
        EnqueueWarmHave = function()
            prewarms = prewarms + 1
        end,
        EnqueueDemand = function() end,
        StartOnce = function() end,
    },
}

load_module("Source/Core/Scheduler.lua")
local Sch = StockPiler.Scheduler

local function expire()
    Sch.OnUpdate(0)
end

Sch.ArmOrchDecisionHold(1)
eq(Sch._orchHoldSnapGen, 3, "hold records the bag generation")
expire()
local plans = 0
local enqueue = Sch.EnqueuePlanRebuild
Sch.EnqueuePlanRebuild = function(...)
    plans = plans + 1
    return enqueue(...)
end

eq(invalidated, 0, "unchanged bag does not bust Have")
eq(Sch._pendingPrewarmAfterQuiet == true, false, "hold end does not arm the quiet prewarm")
eq(prewarms, 0, "unchanged bag does not prewarm")
eq(plans, 0, "unchanged bag does not queue a rebuild")

snap = 3
held = false
Sch.ArmOrchDecisionHold(1)
snap = 4
expire()
eq(invalidated, 1, "a bag move busts Have")
eq(prewarms, 1, "a bag move prewarms directly")
eq(Sch._pendingPrewarmAfterQuiet == true, false, "a bag move does not use the quiet flag")
eq(plans, 1, "a bag move queues one rebuild")

Sch._pendingPlanAfterPrewarm = false
prewarms = 0
invalidated = 0
snap = 5
Sch.ArmOrchDecisionHold(1)
held = true
expire()
eq(invalidated, 1, "served cached counts bust Have")
eq(prewarms, 1, "served cached counts prewarm")
eq(held, false, "the served-counts flag is consumed")

if failures > 0 then
    io.stderr:write(string.format("%d/%d checks failed\n", failures, checks))
    os.exit(1)
end
print(string.format("orch_hold: %d checks passed", checks))
