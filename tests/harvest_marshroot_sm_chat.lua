-- Special Moment Marsh Root plants must count as harvest products of Marshroot seeds.
-- Run: lua5.1 tests/harvest_marshroot_sm_chat.lua

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

local LIVID_SEED = 84601
local LIVID_PLANT = 84346
local ANGRY_PLANT = 84347

local now = 1000
local snap = 1
local bag = {
    [LIVID_SEED] = {
        uniqueID = LIVID_SEED,
        name = "Livid Marshroot Seed",
        cultivationType = 1,
        craftingSkillRequirement = 150,
        stackCount = 1,
    },
}

local outcomes = {}

StockPiler = {
    Util = {
        ToNarrow = function(v) return tostring(v or "") end,
        NowSec = function() return now end,
        T = function(key, tokens)
            tokens = tokens or {}
            if key == "grow.harvest_outcome" then
                return string.format("harvested %s x%s", tostring(tokens.name), tostring(tokens.count))
            end
            if key == "grow.harvest_special_moment" then
                return string.format("Special Moment -> %s", tostring(tokens.name))
            end
            return key
        end,
    },
    Knowledge = {
        GetGen = function() return 1 end,
        Grows = function()
            StockPiler._grows = StockPiler._grows or {}
            return StockPiler._grows
        end,
        Refines = function() return {} end,
        Touch = function() end,
    },
    Inventory = {
        GetSnapGen = function() return snap end,
        GetSample = function(uid)
            return bag[tonumber(uid)]
        end,
        CountByUid = function(uid)
            local it = bag[tonumber(uid)]
            return it and (tonumber(it.stackCount) or 1) or 0
        end,
        ForEachItem = function(fn)
            for _, it in pairs(bag) do
                fn(it)
            end
        end,
    },
    Items = {
        StoreItem = function() end,
        GetByUid = function() return nil end,
        ToSpec = function() return nil end,
    },
    Grow = {
        NotifyHarvestOutcome = function(plotNum, opts)
            outcomes[#outcomes + 1] = {
                plot = plotNum,
                name = opts and opts.name,
                count = opts and opts.count,
                uid = opts and opts.uniqueID,
                sm = opts and opts.specialMoment == true,
            }
        end,
    },
}

load_module("Source/Knowledge/SeedMap.lua")
local SM = StockPiler.SeedMap

eq(SM.GenusKeyFromName("Angry Marsh Root"), "marshroot",
    "an older Marsh Root spelling still resolves to marshroot")
eq(SM.GenusKeyFromName("Angry Marshroot"), SM.GenusKeyFromName("Angry Marsh Root"),
    "both spellings share one genus key")

SM.BeginPendingHarvest(1, LIVID_SEED)
local pending = SM.PendingHarvestMap()[1]
check(type(pending) == "table", "pending harvest armed")
pending.chatSpecialMoment = true
pending.chatCriticalSuccess = true
bag[LIVID_PLANT] = {
    uniqueID = LIVID_PLANT,
    name = "Livid Marsh Root",
    craftingSkillRequirement = 150,
    stackCount = 1,
}
bag[ANGRY_PLANT] = {
    uniqueID = ANGRY_PLANT,
    name = "Angry Marsh Root",
    craftingSkillRequirement = 175,
    stackCount = 1,
}
snap = snap + 1
SM.MarkHarvestLootDirty()
outcomes = {}
check(SM.TryCompletePendingHarvest(true) == true, "SM harvest completes with Marsh Root plants")

local sawLivid, sawAngry, smAngry = false, false, false
for i = 1, #outcomes do
    local o = outcomes[i]
    if o.uid == LIVID_PLANT then
        sawLivid = true
    end
    if o.uid == ANGRY_PLANT then
        sawAngry = true
        if o.sm == true then
            smAngry = true
        end
    end
end
check(sawLivid, "chat reports Livid Marsh Root harvest")
check(sawAngry, "chat reports Angry Marsh Root harvest")
check(smAngry, "Special Moment arrow points at Angry (higher skillReq)")

local grows = StockPiler.Knowledge.Grows()[tostring(LIVID_SEED)]
check(type(grows) == "table"
    and type(grows.products) == "table"
    and type(grows.products[tostring(ANGRY_PLANT)]) == "table",
    "Angry is recorded as a Livid-seed harvest product")

if failures > 0 then
    io.stderr:write(string.format("%d/%d checks failed\n", failures, checks))
    os.exit(1)
end
print(string.format("harvest_marshroot_sm_chat: %d checks passed", checks))
