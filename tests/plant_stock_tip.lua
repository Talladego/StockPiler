-- Lua 5.1 harness for the plant-row Stock tooltip.
-- Run from the repo root: lua5.1 tests/plant_stock_tip.lua

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
    local fh, openErr = io.open(path, "rb")
    if not fh then
        error("open " .. path .. ": " .. tostring(openErr))
    end
    local text = fh:read("*a")
    fh:close()
    text = text:gsub('L"([^"]*)"', '"%1"')
    local chunk, err = loadstring(text, "@" .. path)
    if not chunk then
        error(err)
    end
    chunk()
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

local function has(text, needle, msg)
    checks = checks + 1
    if type(text) ~= "string" or string.find(text, needle, 1, true) == nil then
        failures = failures + 1
        io.stderr:write("FAIL ", msg, " text=", tostring(text), "\n")
    end
end

function towstring(s)
    return tostring(s)
end
function WStringToString(s)
    return tostring(s)
end

StockPiler = {}
StockPiler.T = function(key, tokens)
    local s = tostring(key)
    if type(tokens) == "table" then
        for k, v in pairs(tokens) do
            s = s .. "{" .. tostring(k) .. "=" .. tostring(v) .. "}"
        end
    end
    return s
end
StockPiler.Util = {
    T = function(key, tokens)
        return StockPiler.T(key, tokens)
    end,
    ToNarrow = function(v)
        if v == nil then
            return ""
        end
        return tostring(v)
    end,
}
StockPiler.ViewList = {
    OnRowChildMouseOver = function() end,
}

local resolveCalls = 0
StockPiler.SeedMap = {
    GetSeedUidsForPlant = function()
        return {}
    end,
    ResolveSeedUidForPlant = function()
        resolveCalls = resolveCalls + 1
        error("plant tip must not walk bags for a seed")
    end,
}
local counts = {}
StockPiler.Inventory = {
    CountByUid = function(uid)
        return counts[tonumber(uid) or 0] or 0
    end,
}

load_module("Source/View/StockPilerTabWatch.lua")

local tip = StockPilerTabWatch.PlantStockTipText({
    kind = "plant",
    potionHave = 0,
    target = 40,
    seedUid = 501,
})
counts[501] = 5
tip = StockPilerTabWatch.PlantStockTipText({
    kind = "plant",
    potionHave = 0,
    target = 40,
    seedUid = 501,
})
has(tip, "tip.watch.plants_harvested", "harvested line uses the target form")
has(tip, "have=0", "harvested count is the plant count")
has(tip, "target=40", "target is included")
has(tip, "tip.watch.seeds_in_bags", "seeds are a separate line")
has(tip, "count=5", "seed count comes from the cached uid")
check(string.find(tip, "tip.watch.plants_harvested_plain", 1, true) == nil, "a target keeps the target line")
eq = function(actual, expected, msg)
    checks = checks + 1
    if actual ~= expected then
        failures = failures + 1
        io.stderr:write("FAIL ", msg, " expected=", tostring(expected), " got=", tostring(actual), "\n")
    end
end
eq(resolveCalls, 0, "known seed uid does not resolve through bags")

local plain = StockPilerTabWatch.PlantStockTipText({
    kind = "plant",
    potionHave = 3,
    plantUid = 80,
})
has(plain, "tip.watch.plants_harvested_plain", "missing target omits the target")
has(plain, "have=3", "plain harvested count")
has(plain, "tip.watch.seed_link_unknown", "empty seed link is unknown")
check(string.find(plain, "tip.watch.seeds_in_bags", 1, true) == nil, "unknown seed link is not zero seeds")
eq(resolveCalls, 0, "unknown seed link does not walk bags")

StockPiler.SeedMap.GetSeedUidsForPlant = function(plantUid)
    if plantUid == 80 then
        return { 11, 12 }
    end
    return {}
end
counts[11] = 2
counts[12] = 4
local summed = StockPilerTabWatch.PlantStockTipText({
    kind = "plant",
    isPlantWatch = true,
    potionHave = 1,
    potionMin = 8,
    plantUid = 80,
})
has(summed, "target=8", "potionMin is the target when target is absent")
has(summed, "count=6", "linked seeds are summed from the cache")
eq(resolveCalls, 0, "seed list does not walk bags")

local preset = StockPilerTabWatch.PlantStockTipText({
    kind = "plant",
    potionHave = 2,
    target = 9,
    seedHave = 0,
    plantUid = 80,
})
has(preset, "count=0", "a stored seed count of zero is a real zero")
eq(resolveCalls, 0, "stored seed count does not look up seeds")

local shownTip = nil
Tooltips = {
    ANCHOR_WINDOW_RIGHT = 1,
    CreateTextOnlyTooltip = function(_, text)
        shownTip = tostring(text)
    end,
    AnchorTooltip = function() end,
}
SystemData = { ActiveWindow = { name = "StockPilerWatchRowStock" } }
function DoesWindowExist(name)
    return name == "SPTabWatchList"
end
function WindowGetId()
    return 1
end
function ListBoxGetDataIndex()
    return 1
end
StockPilerTabWatch.listData = {
    {
        kind = "plant",
        potionHave = 0,
        target = 40,
        seedUid = 501,
    },
}
StockPilerTabWatch.OnMouseOverStock()
has(shownTip, "tip.watch.plants_harvested", "stock hover uses the plant breakdown")
has(shownTip, "count=5", "stock hover uses the cached seed count")

StockPilerTabWatch.listData = {
    { potionHave = 6, target = 10 },
}
shownTip = nil
StockPilerTabWatch.OnMouseOverStock()
has(shownTip, "tip.watch.have_target", "potion stock hover keeps the old tip")
check(string.find(tostring(shownTip), "tip.watch.seeds_in_bags", 1, true) == nil, "potion stock hover does not list seeds")

if failures > 0 then
    io.stderr:write(string.format("%d/%d checks failed\n", failures, checks))
    os.exit(1)
end
print(string.format("plant_stock_tip: %d checks passed", checks))
