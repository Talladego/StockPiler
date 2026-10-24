-- Forget and Clear Watches confirm the dialog that was answered.
-- Run: lua5.1 tests/confirm_dialogs.lua

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
function WStringToString(s)
    return tostring(s)
end

StockPiler = { Settings = {} }
StockPiler.T = function(key, tokens)
    local s = tostring(key)
    if type(tokens) == "table" then
        if tokens.name then
            s = s .. ":" .. tostring(tokens.name)
        end
        if tokens.count then
            s = s .. ":" .. tostring(tokens.count)
        end
    end
    return s
end
StockPiler.Util = {
    T = StockPiler.T,
    ToNarrow = function(v) return tostring(v or "") end,
}
StockPiler.Ui = { Print = function() end }

load_module("Source/View/ViewList.lua")

local dialogs = {}
DialogManager = {
    MakeTwoButtonDialog = function(text, yes, cb1)
        dialogs[#dialogs + 1] = { text = text, yes = cb1 }
        return true
    end,
}
GetString = function() return "Yes" end
StringTables = { Default = {} }
function DoesWindowExist()
    return true
end
function ButtonSetPressedFlag()
end
function ButtonSetDisabledFlag()
end
function WindowSetShowing()
end
function WindowSetAlpha()
end
function WindowGetParent()
    return nil
end
local activeRow = 1
function WindowGetId()
    return activeRow
end
function ListBoxGetDataIndex(_, rowIndex)
    return rowIndex
end
SystemData = { ActiveWindow = { name = "SPTabPotionsListRow1Forget" } }

local forgotten = {}
StockPiler.Catalog = {
    ForgetPotionRecipeLink = function(uid, rk)
        forgotten[#forgotten + 1] = tostring(uid) .. "/" .. tostring(rk)
        return true
    end,
}

load_module("Source/View/StockPilerTabPotions.lua")
StockPilerTabPotions.Refresh = function() end
StockPilerTabPotions.listData = {
    { uniqueID = 111, recipeSpecKey = "rkA", potionKey = "uid:111|rk:rkA", name = "Potion A", hasRecipe = true },
    { uniqueID = 222, recipeSpecKey = "rkB", potionKey = "uid:222|rk:rkB", name = "Potion B", hasRecipe = true },
}
activeRow = 1
StockPilerTabPotions.OnForgetRow()
activeRow = 2
StockPilerTabPotions.OnForgetRow()
dialogs[1].yes()
eq(forgotten[1], "111/rkA", "Yes on the first Forget dialog forgets potion A")
dialogs[2].yes()
eq(forgotten[2], "222/rkB", "Yes on the second Forget dialog forgets potion B")
eq(#forgotten, 2, "each Forget dialog forgets once")

local plants = {}
StockPiler.Catalog.ForgetPlant = function(uid)
    plants[#plants + 1] = uid
end
load_module("Source/View/StockPilerTabPlants.lua")
StockPilerTabPlants.Refresh = function() end
StockPilerTabPlants.listData = {
    { plantUid = 11, name = "Plant A" },
    { plantUid = 22, name = "Plant B" },
}
SystemData.ActiveWindow.name = "SPTabPlantsListRow1Forget"
activeRow = 1
StockPilerTabPlants.OnForgetRow()
activeRow = 2
StockPilerTabPlants.OnForgetRow()
local plantDialogs = { dialogs[#dialogs - 1], dialogs[#dialogs] }
plantDialogs[1].yes()
eq(plants[1], 11, "Yes on the first plant dialog forgets plant A")
plantDialogs[2].yes()
eq(plants[2], 22, "Yes on the second plant dialog forgets plant B")

local cleared = {}
StockPiler.Watch = {
    CountEnabledPlantWatches = function() return 2 end,
    CountEnabled = function() return 3 end,
}
StockPiler.Catalog.ClearPlantWatchList = function()
    cleared[#cleared + 1] = "plant"
    return 2
end
StockPiler.Catalog.ClearWatchList = function()
    cleared[#cleared + 1] = "potion"
    return 3
end
load_module("Source/View/StockPilerWindow.lua")
StockPilerWindow.RefreshFooterButtons = function() end
StockPilerWindow.SyncActionReadiness = function() end
StockPilerWindow.EnsureSelectedTabShowing = function() end
StockPilerTabPlants.Refresh = function() end
StockPilerTabPotions.Refresh = function() end

StockPilerWindow.SelectedTab = StockPilerWindow.TABS_PLANTS
StockPilerWindow.OnClearWatches()
StockPilerWindow.SelectedTab = StockPilerWindow.TABS_POTIONS
StockPilerWindow.OnClearWatches()
local clearDialogs = { dialogs[#dialogs - 1], dialogs[#dialogs] }
clearDialogs[1].yes()
eq(cleared[1], "plant", "Yes on the plant clear dialog clears plants")
clearDialogs[2].yes()
eq(cleared[2], "potion", "Yes on the potion clear dialog clears potions")
eq(#cleared, 2, "each clear dialog runs once")

if failures > 0 then
    io.stderr:write(string.format("%d/%d checks failed\n", failures, checks))
    os.exit(1)
end
print(string.format("confirm_dialogs: %d checks passed", checks))
