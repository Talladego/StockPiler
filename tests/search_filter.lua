-- Typing in a list filter does not rebuild the catalog. Uid-less specs are memoized.
-- Run: lua5.1 tests/search_filter.lua

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
function DoesWindowExist(name)
    return name == "SPTabPotions" or name == "SPTabPlants"
end
function LabelSetText()
end
function ButtonSetText()
end
function WindowSetShowing()
end
function TextEditBoxSetText()
end
function DynamicImageSetTexture()
end

local potionLists = 0
local plantLists = 0
local scans = 0
local settings = {
    potionNameFilter = "",
    potionEffectFilter = "",
    potionSortColumn = "name",
    potionSortAscending = true,
    plantNameFilter = "",
    plantEffectFilter = "",
    plantLevelFilter = 0,
    plantSortColumn = "name",
    plantSortAscending = true,
}

StockPiler = {
    Util = {
        T = function(k) return tostring(k) end,
        ToNarrow = function(v) return tostring(v or "") end,
    },
    ViewList = {
        EffectFilterSignature = function() return "all" end,
        SetIconTexture = function() end,
        UpdateSortArrows = function() end,
        EffectTextForRow = function() return "" end,
        ItemRarityNameColor = function() return 255, 255, 255 end,
        FormatSignedStat = function() return "0" end,
        FormatPercentStat = function() return "0" end,
        FormatYieldStat = function() return "0" end,
        InitEffectCombo = function() end,
        SyncEffectCombo = function() end,
        PaintClearButton = function() end,
        EffectFilterCycle = function() return { "" } end,
    },
    Knowledge = { GetGen = function() return 1 end },
    Watch = { GetGen = function() return 1 end },
    Inventory = { GetSnapGen = function() return 1 end },
    Catalog = {
        ListPotionRecipeEntries = function()
            potionLists = potionLists + 1
            return {
                { potionRecipeKey = "a", name = "Heal", outputUid = 1, power = 1 },
                { potionRecipeKey = "b", name = "Ward", outputUid = 2, power = 2 },
            }
        end,
        GetWatch = function()
            return { enabled = false, targetStock = 40 }
        end,
        PotionHaveCombined = function() return 0 end,
        ListPlantEntries = function()
            plantLists = plantLists + 1
            return {
                { plantKey = "p1", name = "Goldweed", plantUid = 3, apoLevel = 1, effectKey = "heal" },
                { plantKey = "p2", name = "Graveroot", plantUid = 4, apoLevel = 2, effectKey = "ward" },
            }
        end,
        GetPlantWatch = function()
            return { enabled = false, targetStock = 40 }
        end,
        PlantHave = function() return 0 end,
    },
    Account = {
        items = {
            ["9"] = { uniqueID = 9, name = "Beast Scales", isRefinable = false },
        },
    },
    Items = {
        AsItemData = function()
            scans = scans + 1
            return { uniqueID = 9, name = "Beast Scales", isRefinable = false }
        end,
    },
    MaterialSpec = {
        ProductKey = function(spec) return tostring(spec.key or "") end,
        ProductMatches = function(item, spec)
            return spec.key == "scales" and item.uniqueID == 9
        end,
    },
}
StockPiler.Settings = settings
function GetSettings()
    return settings
end

load_module("Source/View/StockPilerTabPotions.lua")
load_module("Source/View/StockPilerTabPlants.lua")

-- The tabs read settings from their own helper. Point filters through the table
-- they close over if GetSettings is local. Refresh uses that local, so set the
-- filter by the public search handler when the edit box is stubbed.
function TextEditBoxGetText(name)
    if tostring(name):find("Plants", 1, true) then
        return settings.plantNameFilter
    end
    return settings.potionNameFilter
end

StockPilerTabPotions.Refresh()
potionLists = 0
settings.potionNameFilter = "hea"
StockPilerTabPotions.OnSearchChanged()
settings.potionNameFilter = "war"
StockPilerTabPotions.OnSearchChanged()
eq(potionLists, 0, "potion search does not rebuild the catalog")

StockPilerTabPlants.Refresh()
plantLists = 0
settings.plantNameFilter = "gold"
StockPilerTabPlants.OnSearchChanged()
settings.plantNameFilter = "grave"
StockPilerTabPlants.OnSearchChanged()
eq(plantLists, 0, "plant search does not rebuild the catalog")

load_module("Source/Knowledge/SeedMap.lua")
local spec = { key = "scales", role = "main", name = "" }
scans = 0
StockPiler.SeedMap.IsGrowableSpec(spec)
local first = scans
StockPiler.SeedMap.IsGrowableSpec(spec)
eq(scans, first, "a uid-less spec scans items once per generation")

if failures > 0 then
    io.stderr:write(string.format("%d/%d checks failed\n", failures, checks))
    os.exit(1)
end
print(string.format("search_filter: %d checks passed", checks))
