-- Lua 5.1 harness that loads the real recipe modules (not a RecipeSpec fake).
-- Run from the repo root: lua5.1 tests/recipe_link_real.lua
--
-- Covers link import, unverified-marker cleanup after a merge, and
-- 5- and 8-slot fingerprint round trips that include a zero bonus.

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

load_module("Source/Core/Util.lua")
load_module("Source/Stores/KnowledgeStore.lua")
load_module("Source/Knowledge/MaterialSpec.lua")
load_module("Source/Knowledge/MaterialExceptions.lua")
load_module("Source/Knowledge/Items.lua")
load_module("Source/Knowledge/RecipeSpec.lua")
load_module("Source/View/RecipeLink.lua")

local RS = StockPiler.RecipeSpec
local RL = StockPiler.RecipeLink

local ROLES5 = { "container", "main", "stabilizer", "extender", "stimulant" }
local ROLES8 = {
    "container", "main", "stabilizer", "goldweed",
    "extender", "multiplier", "stimulant", "ingredient",
}

local function makeSlots(count, uidBase)
    local roles = count >= 8 and ROLES8 or ROLES5
    local slots = {}
    for i = 1, count do
        local role = roles[i]
        local uid = uidBase + i
        local bonuses = {
            [2] = uidBase + i,
            [4] = 0,
            [12] = 5,
        }
        local stability = i * 3
        if role == "stimulant" then
            stability = 0
            bonuses[5] = 7
            bonuses[8] = 8
            bonuses[15] = 9
        end
        bonuses[1] = stability
        if role == "main" then
            bonuses[6] = 4
        end
        slots[i] = {
            role = role,
            uid = uid,
            perCraft = 1,
            spec = {
                uid = uid,
                role = role,
                power = bonuses[2],
                stability = stability,
                duration = 0,
                tradeSkill = 4,
                skillLevel = 20 + i,
                cultivationType = 0,
                slotType = i,
                effectId = (role == "main") and 4 or nil,
                bonuses = bonuses,
            },
        }
    end
    return slots
end

local function resetAccount()
    StockPiler.Account.items = {}
    StockPiler.Account.grows = {}
    StockPiler.Account.refines = {}
    StockPiler.Account.recipes = {}
    StockPiler.Account.potions = {}
    StockPiler.Account.skillUpRates = {}
    StockPiler.Settings = { characters = {} }
end

local function roundTrip(count, uidBase)
    local label = tostring(count) .. "-slot"
    local slots = makeSlots(count, uidBase)
    local before = RS.RecipeSpecKey(slots)
    check(type(before) == "string" and before ~= "", label .. " fingerprint")
    check(string.find(before, "1=0", 1, true) ~= nil, label .. " key includes stability 0")
    local withoutIgnored = makeSlots(count, uidBase)
    for i = 1, #withoutIgnored do
        local bonuses = withoutIgnored[i].spec.bonuses
        bonuses[5] = nil
        bonuses[8] = nil
        bonuses[15] = nil
    end
    eq(RS.RecipeSpecKey(withoutIgnored), before, label .. " fingerprint ignores refs 5, 8, 15")
    local enc = RL.EncodeSlots(slots)
    check(type(enc) == "string" and enc ~= "", label .. " encodes")
    check(string.find(enc, "1=0", 1, true) ~= nil, label .. " emits 1=0")
    check(string.find(enc, "4=0", 1, true) ~= nil, label .. " emits other present zero")
    check(string.find(enc, "5=7", 1, true) == nil, label .. " omits ref 5")
    check(string.find(enc, "8=8", 1, true) == nil, label .. " omits ref 8")
    check(string.find(enc, "15=9", 1, true) == nil, label .. " omits ref 15")
    local decoded = RL.DecodeSlots(enc)
    check(type(decoded) == "table" and #decoded == count, label .. " decodes")
    eq(RS.RecipeSpecKey(decoded), before, label .. " round trip")
    local kept = false
    for i = 1, #decoded do
        if decoded[i].role == "stimulant" then
            eq(decoded[i].spec.bonuses[1], 0, label .. " stimulant stability stays 0")
            eq(decoded[i].spec.bonuses[5], nil, label .. " ref 5 not restored")
            eq(decoded[i].spec.bonuses[8], nil, label .. " ref 8 not restored")
            eq(decoded[i].spec.bonuses[15], nil, label .. " ref 15 not restored")
            kept = true
        end
    end
    check(kept, label .. " stimulant present")
    return slots, before
end

local function testImportLeavesExistingAlone()
    resetAccount()
    local slots, key = roundTrip(5, 1000)
    local result = RL.ImportKnownPotion({
        uid = 9001,
        name = "Linked Heal",
        icon = 42,
        rk = "liar-key-not-a-fingerprint",
        slots = slots,
    })
    eq(result, "imported", "link import")
    local recipes = StockPiler.Account.recipes
    check(type(recipes[key]) == "table", "stored under recomputed key")
    eq(recipes["liar-key-not-a-fingerprint"], nil, "link rk is not a recipe key")
    eq(recipes[key].sharedImport, true, "import marked shared")
    eq(recipes[key].unverified, true, "import marked unverified")
    eq(next(recipes[key].outcomes), nil, "no synthetic outcome")
    eq(StockPiler.Account.items["9001"], nil, "import does not write the item cache")
    local potion = StockPiler.Account.potions["uid:9001"]
    check(type(potion) == "table", "potion created")
    eq(tostring(potion.name), "Linked Heal", "new potion name")
    eq(potion.iconNum, 42, "new potion icon")
    eq(potion.activeRecipeKey, key, "new potion active key")

    local other = makeSlots(5, 2000)
    local otherKey = RS.RecipeSpecKey(other)
    check(otherKey ~= key, "second recipe differs")
    local again = RL.ImportKnownPotion({
        uid = 9001,
        name = "Autre nom",
        icon = 99,
        slots = other,
    })
    eq(again, "imported", "different recipe is an alternative")
    eq(tostring(potion.name), "Linked Heal", "existing potion name stays")
    eq(potion.iconNum, 42, "existing potion icon stays")
    eq(potion.activeRecipeKey, key, "active recipe stays")
    local found = false
    for i = 1, #potion.recipeKeys do
        if potion.recipeKeys[i] == otherKey then
            found = true
        end
    end
    check(found, "alternative key added")

    recipes[key].sentinel = "keep"
    recipes[key].outcomes["9001"] = { uid = 9001, samples = 4, quality = "good" }
    eq(RL.ImportKnownPotion({
        uid = 9001,
        name = "Overwrite",
        icon = 1,
        slots = slots,
    }), "known", "already known")
    eq(recipes[key].sentinel, "keep", "known import leaves the recipe")
    eq(recipes[key].outcomes["9001"].samples, 4, "known import leaves outcomes")
end

local function recipeRow(slots, successes, imported)
    return {
        slots = RL.DecodeSlots(RL.EncodeSlots(slots)),
        outcomes = {},
        brewAttempts = successes,
        brewSuccesses = successes,
        sharedImport = imported and true or nil,
        unverified = imported and true or nil,
    }
end

local function testMergeClearsMarkerWhenBrewed()
    resetAccount()
    local slots = makeSlots(5, 3000)
    local key = RS.RecipeSpecKey(slots)
    StockPiler.Account.recipes = {
        ["legacy-a"] = recipeRow(slots, 0, true),
        ["legacy-b"] = recipeRow(slots, 3, false),
    }
    local report = RS.ValidateAndRepairSavedRecipes()
    eq(tonumber(report.merged), 1, "repair merges the duplicate")
    local row = StockPiler.Account.recipes[key]
    check(type(row) == "table", "merged recipe uses the real fingerprint")
    eq(tonumber(row.brewSuccesses), 3, "merged successes kept")
    eq(row.sharedImport, nil, "merge clears sharedImport after brews")
    eq(row.unverified, nil, "merge clears unverified after brews")
end

local function testMergeKeepsMarkerWithoutBrews()
    resetAccount()
    local slots = makeSlots(5, 4000)
    local key = RS.RecipeSpecKey(slots)
    StockPiler.Account.recipes = {
        ["legacy-a"] = recipeRow(slots, 0, true),
        ["legacy-b"] = recipeRow(slots, 0, true),
    }
    RS.ValidateAndRepairSavedRecipes()
    local row = StockPiler.Account.recipes[key]
    check(type(row) == "table", "unbrewed merge keeps a recipe")
    eq(tonumber(row.brewSuccesses) or 0, 0, "unbrewed merge has no successes")
    eq(row.sharedImport, true, "unbrewed merge keeps sharedImport")
    eq(row.unverified, true, "unbrewed merge keeps unverified")
end

local function testMigrateMergeClearsMarker()
    resetAccount()
    local slots = makeSlots(8, 5000)
    local key = RS.RecipeSpecKey(slots)
    StockPiler.Account.recipeFingerprintMigrateV2 = nil
    StockPiler.Account.recipes = {
        ["legacy-a"] = recipeRow(slots, 0, true),
        ["legacy-b"] = recipeRow(slots, 2, false),
    }
    local ran = RS.MigrateRecipeFingerprintsV2()
    eq(ran, true, "fingerprint migrate runs")
    local row = StockPiler.Account.recipes[key]
    check(type(row) == "table", "migrate stores the 8-slot fingerprint")
    eq(tonumber(row.brewSuccesses), 2, "migrate keeps successes")
    eq(row.sharedImport, nil, "migrate merge clears sharedImport")
    eq(row.unverified, nil, "migrate merge clears unverified")
end

roundTrip(5, 1000)
roundTrip(8, 8000)
testImportLeavesExistingAlone()
testMergeClearsMarkerWhenBrewed()
testMergeKeepsMarkerWithoutBrews()
testMigrateMergeClearsMarker()

if failures > 0 then
    io.stderr:write(string.format("%d/%d checks failed\n", failures, checks))
    os.exit(1)
end
print(string.format("recipe_link_real: %d checks passed", checks))
