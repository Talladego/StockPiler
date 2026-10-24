-- A loaded Apothecary board is not a brew. A later potion gain is not a recipe.
-- Run: lua5.1 tests/brew_learn_board.lua

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

GameData = {
    CultivationTypes = { NONE = 0, SEED = 1, SPORE = 5 },
    ItemTypes = { CRAFTING = 34, POTION = 31 },
    TradeSkills = { APOTHECARY = 4, CULTIVATION = 7 },
    CraftingItemType = {
        CONTAINER = 1, MAIN_INGREDIENT = 2, STABILIZER = 3, EXTENDER = 4,
        MULTIPLIER = 5, STIMULANT = 6, GOLDWEED = 7, PIGMENT = 8, CONTAINER_DYE = 9,
    },
    CraftingStates = {
        VALID_RECIPE = 1, PERFORMING = 2, SUCCESS = 3, FAIL = 4,
        DONE = 5, SUCCESS_REPEAT = 6, IDLE = 0,
    },
    CraftingSuccessChance = { HIGH = 3, MEDIUM = 2, LOW = 1 },
    Player = { name = "Hero^M" },
}

local now = 10000
function GetGameTime()
    return now
end

StockPiler = { Persistence = {}, Settings = { characters = {} } }
StockPiler.Account = {
    items = {}, grows = {}, refines = {}, recipes = {}, potions = {}, skillUpRates = {},
}
StockPiler.T = function(k)
    return tostring(k)
end

load_module("Source/Core/Util.lua")
load_module("Source/Stores/KnowledgeStore.lua")
load_module("Source/Knowledge/MaterialSpec.lua")
load_module("Source/Knowledge/MaterialExceptions.lua")
load_module("Source/Knowledge/Items.lua")
load_module("Source/Knowledge/RecipeSpec.lua")
load_module("Source/Knowledge/BrewLearn.lua")
load_module("Source/Knowledge/LearnBridge.lua")

local BL = StockPiler.BrewLearn
local LB = StockPiler.LearnBridge

local function crafting(uid, name, ref8, extra)
    local b = {
        { bonusReference = 8, bonusValue = ref8 },
        { bonusReference = 9, bonusValue = 1 },
    }
    for _, e in ipairs(extra or {}) do
        b[#b + 1] = e
    end
    return {
        uniqueID = uid, name = name, type = 34, itemType = 34,
        stackCount = 5, iconNum = 1, cultivationType = 0, craftingBonus = b,
    }
end

local CIT = GameData.CraftingItemType
local board = {
    [0] = crafting(1001, "Clear Vial", CIT.CONTAINER),
    [1] = crafting(1002, "Bitter Grumpleaf", CIT.MAIN_INGREDIENT, {
        { bonusReference = 6, bonusValue = 7 },
    }),
    [2] = crafting(1003, "Goldweed", CIT.STABILIZER, {
        { bonusReference = 1, bonusValue = 2 },
    }),
}
local state = GameData.CraftingStates.VALID_RECIPE
StockPiler.ApothecaryAdapter = {
    ReadBoard = function() return board end,
    CraftingState = function() return state end,
    SuccessChance = function() return 3 end,
}
CraftingSystem = {
    GetCraftingData = function(item)
        for _, b in ipairs(item.craftingBonus or {}) do
            if b.bonusReference == 8 then
                return nil, b.bonusValue
            end
        end
        return nil, 0
    end,
}

local bag = {}
StockPiler.Inventory = {
    ForEachItem = function(fn)
        for _, it in pairs(bag) do
            fn(it)
        end
    end,
    GetSample = function(uid)
        for _, it in pairs(bag) do
            if it.uniqueID == uid then
                return it
            end
        end
    end,
    CountByUid = function(uid)
        local n = 0
        for _, it in pairs(bag) do
            if it.uniqueID == uid then
                n = n + it.stackCount
            end
        end
        return n
    end,
}

LB.OnCraftingUpdated()
eq(BL._lastBoardFromPerform == true, false, "a valid board is not a perform")
eq(type(BL._pendingCraft), "nil", "a valid board does not open a pending learn")

state = GameData.CraftingStates.IDLE
LB.OnCraftingUpdated()
now = now + 20
bag[1] = {
    uniqueID = 5555, name = "Healing Draught", type = 31, itemType = 31, stackCount = 1,
}
LB.OnInventoryUpdated()
LB.OnUpdateProcessed()

local recipeCount = 0
local recipes = StockPiler.Account and StockPiler.Account.recipes
if type(recipes) == "table" then
    for _ in pairs(recipes) do
        recipeCount = recipeCount + 1
    end
end
local RS = StockPiler.RecipeSpec
if RS and RS.GetLearnedRecipeCount then
    recipeCount = RS.GetLearnedRecipeCount()
elseif RS and RS.ListLearnedRecipes then
    local list = RS.ListLearnedRecipes()
    if type(list) == "table" then
        recipeCount = #list
    end
end
eq(recipeCount, 0, "a bought potion does not store a recipe")
eq(type(BL._pendingCraft), "nil", "bag gain does not arm a learn from the board")

if failures > 0 then
    io.stderr:write(string.format("%d/%d checks failed\n", failures, checks))
    os.exit(1)
end
print(string.format("brew_learn_board: %d checks passed", checks))
