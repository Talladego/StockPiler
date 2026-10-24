-- One throwing update stage does not stop the stages after it.
-- Run: lua5.1 tests/update_stage_isolation.lua

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

local chat = {}
StockPiler = {
    T = function(key)
        if key == "boot.stage_skipped" then
            return "skipped"
        end
        return tostring(key)
    end,
    Util = {
        TryCallQuiet = function(_, fn)
            return pcall(fn)
        end,
    },
    Debug = {
        Reply = function(msg)
            chat[#chat + 1] = tostring(msg)
        end,
        ReportProtectedCallFailure = function() end,
    },
}

load_module("Source/Core/EngineEventBridge.lua")
load_module("Source/Core/Scheduler.lua")
load_module("Source/Core/Orchestrator.lua")

local schedRuns = 0
local tickRuns = 0
local timerRuns = 0
local growRuns = 0
StockPiler.LearnBridge = {
    OnUpdateProcessed = function()
        error("learn broke")
    end,
}
StockPiler.Scheduler.OnUpdate = function()
    schedRuns = schedRuns + 1
end
StockPiler.Orchestrator.Tick = function()
    tickRuns = tickRuns + 1
    error("tick broke")
end
StockPiler.CraftHarvestTimer = {
    OnUpdate = function()
        timerRuns = timerRuns + 1
    end,
}
StockPiler.Grow = {
    ExpireStalePending = function()
        growRuns = growRuns + 1
    end,
}
StockPiler.Buy = {
    PollStorePresence = function()
        error("buy poll broke")
    end,
}
StockPiler.Brew = {
    OnUpdate = function()
        error("brew update broke")
    end,
}

local Bridge = StockPiler.EngineEventBridge
for _ = 1, 40 do
    Bridge.OnUpdateProcessed(1 / 60)
end
eq(schedRuns, 40, "scheduler still runs after learn throws")
eq(timerRuns, 40, "harvest timer still runs after learn throws")
eq(Bridge._stageFailStreak.learn, 40, "learn failures are counted")
eq(#chat, 1, "a repeated stage failure warns once")
eq(chat[1], "skipped", "the warning is the player stage message")

local lines = {}
StockPiler.Orchestrator.DumpState(function(msg)
    lines[#lines + 1] = msg
end)
local saw = false
for i = 1, #lines do
    if lines[i] == "stageFail learn=40" then
        saw = true
    end
end
check(saw, "state lists the failing stage")

-- Real scheduler: a throwing poll and a throwing tick do not escape OnUpdate.
StockPiler.Scheduler = nil
load_module("Source/Core/Scheduler.lua")
local Sch = StockPiler.Scheduler
Sch._autoAccum = 10
Sch._pollAt = 0
local ok = pcall(Sch.OnUpdate, 1)
check(ok, "scheduler update survives a throwing buy poll and tick")
eq(growRuns > 0, true, "grow expiry still runs when the buy poll throws")
eq(tickRuns, 1, "orchestrator tick still runs")

if failures > 0 then
    io.stderr:write(string.format("%d/%d checks failed\n", failures, checks))
    os.exit(1)
end
print(string.format("update_stage_isolation: %d checks passed", checks))
