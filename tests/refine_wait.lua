-- Refine wait ticks count scheduler ticks, not frames.
-- Run: lua5.1 tests/refine_wait.lua

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

function towstring(s)
    return tostring(s)
end

StockPiler = { FrameCounter = 1 }
StockPiler.Inventory = { GetSnapGen = function() return 1 end }
load_module("Source/Refine.lua")
local Refine = StockPiler.Refine
Refine._refineWaitTicks = 5
for _ = 1, 8 do
    StockPiler.FrameCounter = StockPiler.FrameCounter + 1
    Refine.OnUpdateProcessed(1 / 60)
end
eq(Refine._refineWaitTicks, 5, "frame updates leave the refine wait in place")
Refine.DecayRefineWaitTicks()
eq(Refine._refineWaitTicks, 4, "a scheduler tick decrements the wait once")

if failures > 0 then
    io.stderr:write(string.format("%d/%d checks failed\n", failures, checks))
    os.exit(1)
end
print(string.format("refine_wait: %d checks passed", checks))
