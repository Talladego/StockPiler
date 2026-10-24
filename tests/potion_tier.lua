-- Lua 5.1 harness for potion rarity/iLevel migrate and RegisterKnownPotion stamps.
-- Run from the repo root: lua5.1 tests/potion_tier.lua

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
}

function GetGameTime()
    return 10000
end

StockPiler = {}
StockPiler.Persistence = {}
StockPiler.Account = {
    items = {},
    grows = {},
    refines = {},
    recipes = {},
    potions = {},
    skillUpRates = {},
}
StockPiler.Settings = { characters = {} }
StockPiler.T = function(key)
    return tostring(key)
end

load_module("Source/Core/Util.lua")
load_module("Source/Stores/KnowledgeStore.lua")
load_module("Source/Knowledge/MaterialSpec.lua")
load_module("Source/Knowledge/MaterialExceptions.lua")
load_module("Source/Knowledge/Items.lua")
load_module("Source/Knowledge/RecipeSpec.lua")

local RS = StockPiler.RecipeSpec
local potions = StockPiler.Account.potions
local items = StockPiler.Account.items

-- Seed Items cache the way StoreItem would.
items["9001"] = {
    uniqueID = 9001,
    name = "Lasting Sample",
    rarity = 2,
    iLevel = 40,
    iconNum = 11,
}
items["9002"] = {
    uniqueID = 9002,
    name = "Already Set",
    rarity = 4,
    iLevel = 55,
    iconNum = 12,
}

potions["uid:9001"] = {
    potionKey = "uid:9001",
    outputUid = 9001,
    recipeKeys = { "rk:a" },
    activeRecipeKey = "rk:a",
    name = "Lasting Sample",
    iconNum = 11,
}
potions["uid:9002"] = {
    potionKey = "uid:9002",
    outputUid = 9002,
    recipeKeys = { "rk:b" },
    activeRecipeKey = "rk:b",
    name = "Already Set",
    iconNum = 12,
    rarity = 9,
    iLevel = 99,
}
potions["uid:9003"] = {
    potionKey = "uid:9003",
    outputUid = 9003,
    recipeKeys = { "rk:c" },
    activeRecipeKey = "rk:c",
    name = "No Items",
    iconNum = 13,
}

StockPiler.Account.potionTierMigrateV1 = nil
check(RS.MigratePotionTierFromItems() == true, "migrate stamps from Items")
eq(tonumber(potions["uid:9001"].rarity), 2, "migrate fills rarity")
eq(tonumber(potions["uid:9001"].iLevel), 40, "migrate fills iLevel")
eq(tonumber(potions["uid:9002"].rarity), 9, "migrate leaves existing rarity")
eq(tonumber(potions["uid:9002"].iLevel), 99, "migrate leaves existing iLevel")
eq(potions["uid:9003"].rarity, nil, "migrate does not invent rarity")
eq(StockPiler.Account.potionTierMigrateV1, true, "migrate latch set")
check(RS.MigratePotionTierFromItems() == false, "migrate latch prevents re-run")
eq(tonumber(potions["uid:9001"].rarity), 2, "latched migrate leaves stamps")

-- Brew-style register stamps rarity/iLevel from out.itemData.
local potion, isNew = RS.RegisterKnownPotion(
    9100,
    {
        uniqueID = 9100,
        name = "Brewed Blue",
        iconNum = 20,
        itemData = { uniqueID = 9100, rarity = 3, iLevel = 50, name = "Brewed Blue" },
    },
    "rk:brew",
    "good",
    nil
)
check(type(potion) == "table", "brew register returns potion")
check(isNew == true, "brew register is new")
eq(tonumber(potions["uid:9100"].rarity), 3, "brew stamps rarity")
eq(tonumber(potions["uid:9100"].iLevel), 50, "brew stamps iLevel")

-- Link import fills gaps only.
RS.RegisterKnownPotion(
    9100,
    { uniqueID = 9100, name = "Ignored", rarity = 1, iLevel = 10 },
    "rk:alt",
    "potent",
    { linkImport = true }
)
eq(tonumber(potions["uid:9100"].rarity), 3, "link does not clobber brew rarity")
eq(tonumber(potions["uid:9100"].iLevel), 50, "link does not clobber brew iLevel")
eq(potions["uid:9100"].name, "Brewed Blue", "link does not rename existing")

local fresh = RS.RegisterKnownPotion(
    9200,
    { uniqueID = 9200, name = "Linked Potent", rarity = 3, iLevel = 45 },
    "rk:link",
    "potent",
    { linkImport = true }
)
check(type(fresh) == "table", "link register new potion")
eq(tonumber(potions["uid:9200"].rarity), 3, "link stamps rarity on new")
eq(tonumber(potions["uid:9200"].iLevel), 45, "link stamps iLevel on new")
eq(RS.OutputQuality({ name = "Potent Draught" }), "potent", "OutputQuality potent")
eq(RS.OutputQuality({ name = "Draught" }), "good", "OutputQuality good")

load_module("Source/View/RecipeLink.lua")
local RL = StockPiler.RecipeLink
local fromComposite = RL.FieldsFromRow({
    potionRecipeKey = "uid:9002|rk:rk:b",
    uniqueID = 9002,
})
check(type(fromComposite) == "table", "composite watch key builds share fields")
eq(fromComposite and fromComposite.name, "Already Set", "composite key resolves the saved potion by uid")
eq(tonumber(fromComposite and fromComposite.rarity), 9, "composite key keeps the saved rarity")
eq(tonumber(fromComposite and fromComposite.iLevel), 99, "composite key keeps the saved level")
eq(tonumber(fromComposite and fromComposite.icon), 12, "composite key keeps the saved icon")

if failures > 0 then
    io.stderr:write(string.format("%d/%d checks failed\n", failures, checks))
    os.exit(1)
end
print(string.format("potion_tier: %d checks passed", checks))
