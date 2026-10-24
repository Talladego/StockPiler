-- After a brew, an unknown or unchanged bag waits instead of inventing a count.
-- Run: lua5.1 tests/brew_post.lua

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
local now = 5000
function GetGameTime()
    return now
end

StockPiler = {
    Util = { NowSec = function() return now end, ToNarrow = function(v) return tostring(v or "") end },
}
local snapPending = true
local bagCount = 7
StockPiler.Inventory = {
    IsReady = function() return true end,
    _snapPending = true,
    CountByUid = function()
        if snapPending then
            return 0
        end
        return bagCount
    end,
}

load_module("Source/Brew.lua")
local Brew = StockPiler.Brew

local function session(extra)
    local s = {
        phase = "loaded",
        uniqueID = 9,
        potionKey = "uid:9",
        potionMin = 10,
        target = 10,
        potionHave = 7,
        potionDeficit = 3,
        craftable = 4,
    }
    if type(extra) == "table" then
        for k, v in pairs(extra) do
            s[k] = v
        end
    end
    Brew._session = s
    return s
end

snapPending = true
StockPiler.Inventory._snapPending = true
Brew._postBrewClearArmed = false
Brew._brewHaveBefore = 7
local s = session()
Brew.RefreshSessionAfterBrew()
eq(Brew._postBrewClearArmed, true, "unknown bag count arms a post-brew recheck")
eq(s.phase, "loaded", "unknown bag count does not unload the board")
eq(s.potionHave, 7, "unknown bag count does not replace the session count")

snapPending = false
StockPiler.Inventory._snapPending = false
bagCount = 7
Brew._postBrewClearArmed = false
Brew._brewHaveBefore = 7
s = session()
Brew.RefreshSessionAfterBrew()
eq(Brew._postBrewClearArmed, true, "an unchanged bag arms a post-brew recheck")
eq(Brew._brewHaveBefore, 7, "the before-count is kept until the bag moves")
eq(s.phase, "loaded", "an unchanged bag does not treat the target as met")

now = 8000
Brew._lastPerformAt = 7998
eq(Brew.PerformedWithin(5), true, "a brew a moment ago is recent")
Brew._lastPerformAt = 7900
eq(Brew.PerformedWithin(5), false, "an older brew is not recent")

if failures > 0 then
    io.stderr:write(string.format("%d/%d checks failed\n", failures, checks))
    os.exit(1)
end
print(string.format("brew_post: %d checks passed", checks))
