-- Skill-up seen flags survive the next character-bucket load.
-- Run: lua5.1 tests/settings_skillup_seen.lua

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
function WStringToString(s)
    return tostring(s)
end
GameData = { Player = { name = "Hero^M" } }

local function new_session(savedSettings)
    StockPiler = { Util = { TryCallQuiet = function(_, f, ...) return pcall(f, ...) end } }
    load_module("Source/Core/Util.lua")
    load_module("Source/Persistence/Settings.lua")
    StockPiler.Settings = savedSettings
    return StockPiler.Persistence
end

local P = new_session(nil)
local row = P.GetCharacterBucket(true)
row.lastCultSkill = 200
row.skillUpCultSeen = true
row.skillUpApoSeen = true
row.skillUpSeenBackfill = true
row.futureNote = "keep-me"
local saved = StockPiler.Settings

P = new_session(saved)
local row2 = P.GetCharacterBucket(false)
eq(row2.skillUpCultSeen, true, "cultivation seen flag survives reload")
eq(row2.skillUpApoSeen, true, "apothecary seen flag survives reload")
eq(row2.skillUpSeenBackfill, true, "backfill flag survives reload")
eq(row2.lastCultSkill, 200, "last cultivation skill survives reload")
eq(row2.futureNote, "keep-me", "unknown character fields are kept")

if failures > 0 then
    io.stderr:write(string.format("%d/%d checks failed\n", failures, checks))
    os.exit(1)
end
print(string.format("settings_skillup_seen: %d checks passed", checks))
