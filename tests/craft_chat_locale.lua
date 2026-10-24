-- Craft chat follows locale templates. A recent brew does not close a harvest.
-- Run: lua5.1 tests/craft_chat_locale.lua

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
local now = 9000
function GetGameTime()
    return now
end

SystemData = { ChatLogFilters = { CRAFTING = 42 }, Settings = { Language = { ENGLISH = 1 } } }
GameData = { ChatData = { type = 42, text = "" }, CultivationTypes = { SEED = 1, SPORE = 5 } }

StockPiler = {
    Util = {
        ToNarrow = function(v) return tostring(v or "") end,
        NowSec = function() return now end,
    },
    Events = { CRAFT_CHAT = "CRAFT_CHAT" },
}
local fired = {}
StockPiler.EventBus = {
    Fire = function(_, payload)
        fired[#fired + 1] = payload
    end,
}

load_module("Source/Locale/Locale.lua")
load_module("Source/Locale/enUS.lua")
load_module("Source/Adapters/CraftChatAdapter.lua")
load_module("Source/Knowledge/SeedMap.lua")

local CC = StockPiler.CraftChatAdapter
local function say(text)
    fired = {}
    GameData.ChatData.text = text
    GameData.ChatData.type = 42
    CC.OnChatTextArrived()
    return fired[1]
end

local created = say("You created Healing Draught.")
eq(created and created.kind, "created", "english created line parses")
eq(created and created.name, "Healing Draught", "created name is captured")

local harvested = say("You have harvested 3 Gravebloom.")
eq(harvested and harvested.kind, "harvested", "english harvest line parses")
eq(harvested and harvested.count, 3, "harvest count is captured")
eq(harvested and harvested.name, "Gravebloom", "harvest name is captured")

eq(say("Your creation failed.") and say("Your creation failed.").kind, "critical_failure", "failure line parses")
-- say() resets fired, so call once.
local failed = say("Your creation failed.")
eq(failed and failed.kind, "critical_failure", "english failure line parses")

StockPiler.Locale._pack = {
    ["craft.created"] = "Du hast {name} hergestellt",
    ["craft.fail"] = "Deine Herstellung schlug fehl",
}
local de = say("Du hast Heiltrank hergestellt")
eq(de and de.kind, "created", "client-language created line parses")
eq(de and de.name, "Heiltrank", "client-language name is captured")
local deFail = say("Deine Herstellung schlug fehl.")
eq(deFail and deFail.kind, "critical_failure", "client-language failure line parses")

local SM = StockPiler.SeedMap
SM._pendingHarvest = {
    [1] = { plotNum = 1, startedAt = now, seedUid = 10 },
}
local closed = 0
SM.CompletePendingHarvestAsCritFail = function()
    closed = closed + 1
end
StockPiler.Brew = {
    PerformedWithin = function() return true end,
}
SM.OnCraftChat({ kind = "critical_failure" })
eq(closed, 0, "a recent brew does not fail the harvest")
eq(SM._pendingHarvest[1].chatCriticalFailure, nil, "a recent brew leaves the harvest open")

StockPiler.Brew.PerformedWithin = function() return false end
SM.OnCraftChat({ kind = "critical_failure" })
eq(closed, 1, "a harvest failure still closes that harvest")
eq(SM._pendingHarvest[1].chatCriticalFailure, true, "a harvest failure marks the pending harvest")

if failures > 0 then
    io.stderr:write(string.format("%d/%d checks failed\n", failures, checks))
    os.exit(1)
end
print(string.format("craft_chat_locale: %d checks passed", checks))
