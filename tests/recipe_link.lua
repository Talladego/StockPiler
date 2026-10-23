-- Lua 5.1 harness for RecipeLink serialize / parse / known-potion import.
-- Run from the repo root: lua5.1 tests/recipe_link.lua

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

StockPiler = {}
StockPiler.Util = {
    T = function(key, tokens)
        local s = tostring(key)
        if type(tokens) == "table" and tokens.name then
            s = s .. ":" .. tostring(tokens.name)
        end
        return s
    end,
    ToNarrow = function(v)
        if v == nil then
            return ""
        end
        return tostring(v)
    end,
}

local recipes = {}
local potions = {}
local registered = {}

StockPiler.Knowledge = {
    Recipes = function()
        return recipes
    end,
    Potions = function()
        return potions
    end,
    Touch = function() end,
}

StockPiler.RecipeSpec = {
    PotionRecipeKey = function(uid, rk)
        return "uid:" .. tostring(uid) .. "|rk:" .. tostring(rk)
    end,
    PotionKeyFromUid = function(uid)
        return "uid:" .. tostring(uid)
    end,
    ParsePotionRecipeKey = function(key)
        local uidStr, rk = string.match(tostring(key or ""), "^uid:(%d+)|rk:(.+)$")
        if uidStr then
            return {
                outputUid = tonumber(uidStr),
                recipeSpecKey = rk,
                potionKey = "uid:" .. uidStr,
                isComposite = true,
            }
        end
        return nil
    end,
    GetRecipe = function(rk)
        return recipes[tostring(rk or "")]
    end,
    GetPotion = function(key)
        return potions[tostring(key or "")]
    end,
    RegisterKnownPotion = function(uid, out, rk, quality)
        local pk = "uid:" .. tostring(uid)
        potions[pk] = {
            potionKey = pk,
            outputUid = uid,
            name = out and out.name,
            iconNum = out and out.iconNum,
            recipeKeys = { rk },
            activeRecipeKey = rk,
        }
        registered[#registered + 1] = { uid = uid, rk = rk, quality = quality }
        return potions[pk], true, true, false
    end,
    RecipeSpecKey = function()
        return ""
    end,
}

load_module("Source/View/RecipeLink.lua")

local RL = StockPiler.RecipeLink

local sampleSlots = {
    {
        role = "main",
        uid = 1001,
        perCraft = 1,
        spec = {
            uid = 1001,
            role = "main",
            power = 10,
            stability = 5,
            duration = 0,
            tradeSkill = 4,
            skillLevel = 50,
            cultivationType = 0,
            slotType = 1,
        },
    },
    {
        role = "container",
        uid = 2002,
        perCraft = 1,
        spec = {
            uid = 2002,
            role = "container",
            power = 0,
            stability = 20,
            duration = 0,
            tradeSkill = 4,
            skillLevel = 1,
            cultivationType = 0,
            slotType = 2,
        },
    },
}

local function testSlotRoundTrip()
    local enc = RL.EncodeSlots(sampleSlots)
    check(type(enc) == "string" and enc ~= "", "encode slots")
    local decoded = RL.DecodeSlots(enc)
    check(type(decoded) == "table", "decode slots table")
    eq(#decoded, 2, "decode slot count")
    eq(decoded[1].role, "main", "slot1 role")
    eq(tonumber(decoded[1].uid), 1001, "slot1 uid")
    eq(tonumber(decoded[1].spec.power), 10, "slot1 power")
    eq(decoded[2].role, "container", "slot2 role")
end

local function testRoundTrip()
    local fields = {
        uid = 3012345,
        rk = "mainx1:abc|containerx1:def",
        name = "Bitter Example",
        icon = 123,
        slots = sampleSlots,
    }
    local plain = RL.SerializePlain(fields)
    check(type(plain) == "string", "serialize returns string")
    check(string.find(plain, "slots=", 1, true) ~= nil, "has slots")
    check(string.find(plain, "rk=mainx1:abc|containerx1:def", 1, true) ~= nil, "rk kept")
    -- slots must appear before rk so chat truncation keeps materials.
    local slotsAt = string.find(plain, "slots=", 1, true) or 0
    local rkAt = string.find(plain, ";rk=", 1, true) or 0
    check(slotsAt > 0 and rkAt > slotsAt, "slots before rk")
    local parsed = RL.ParsePlain(plain)
    check(type(parsed) == "table", "parse returns table")
    eq(tonumber(parsed.uid), 3012345, "uid round-trip")
    eq(tostring(parsed.rk), "mainx1:abc|containerx1:def", "rk round-trip")
    eq(tostring(parsed.name), "Bitter Example", "name round-trip")
    eq(tonumber(parsed.icon), 123, "icon round-trip")
    check(type(parsed.slots) == "table" and #parsed.slots == 2, "slots round-trip")
end

local function testTruncatedKeepsSlots()
    -- Simulate chat cutting the trailing fingerprint.
    local fields = {
        uid = 9,
        rk = "mainx1:verylongfingerprint",
        name = "Cut",
        slots = sampleSlots,
    }
    local plain = RL.SerializePlain(fields)
    local cut = string.match(plain, "^(.-);rk=")
    check(cut ~= nil, "can strip rk")
    local parsed = RL.ParsePlain(cut)
    check(type(parsed.slots) == "table" and #parsed.slots == 2, "truncated link keeps slots")
    eq(tonumber(parsed.uid), 9, "truncated uid")
end

local function testLegacyRkThenSlots()
    local enc = RL.EncodeSlots(sampleSlots)
    local legacy = "POTION;uid=42;n=Legacy;rk=mainx1:oldfp;slots=" .. enc
    local parsed = RL.ParsePlain(legacy)
    eq(tonumber(parsed.uid), 42, "legacy uid")
    eq(tostring(parsed.rk), "mainx1:oldfp", "legacy rk")
    check(type(parsed.slots) == "table" and #parsed.slots == 2, "legacy slots")
end

local function testLinkLabelFields()
    local fields = { uid = 1, rk = "mainx1:a", name = "Heal Potion", slots = sampleSlots }
    local link = RL.BuildLinkData(fields)
    check(string.sub(tostring(link), 1, 11) == "StockPiler:", "link prefix")
    local parsed = RL.ParseLinkData(link)
    eq(tostring(parsed.name), "Heal Potion", "link name")
    eq(tostring(RL.DisplayName(fields)), "Heal Potion", "display name")
end

local function testImportKnownSkips()
    recipes = {}
    potions = {}
    StockPiler.Knowledge.Recipes = function()
        return recipes
    end
    local rk = "mainx1:known"
    recipes[rk] = { recipeSpecKey = rk, slots = sampleSlots }
    -- Fingerprint alone must NOT count as known (Forget leaves recipes rows).
    local orphan = RL.ImportKnownPotion({
        uid = 55,
        rk = rk,
        name = "Orphan",
        slots = sampleSlots,
    })
    eq(orphan, "imported", "orphan fingerprint re-links potion")
    potions["uid:55"] = {
        potionKey = "uid:55",
        outputUid = 55,
        recipeKeys = { rk },
        activeRecipeKey = rk,
    }
    local result = RL.ImportKnownPotion({
        uid = 55,
        rk = rk,
        name = "Known",
        slots = sampleSlots,
    })
    eq(result, "known", "skip when potion still linked")
end

local function testImportAfterForget()
    recipes = {}
    potions = {}
    StockPiler.Knowledge.Recipes = function()
        return recipes
    end
    local rk = "mainx1:forgot"
    recipes[rk] = {
        recipeSpecKey = rk,
        slots = sampleSlots,
        outcomes = {},
    }
    -- Simulate Forget: potion gone, fingerprint may remain.
    eq(RL.RecipeIsKnown({ uid = 66, rk = rk }), false, "forgotten potion not known")
    local result = RL.ImportKnownPotion({
        uid = 66,
        rk = rk,
        name = "Readd",
        slots = sampleSlots,
    })
    eq(result, "imported", "reimport after forget")
    check(type(potions["uid:66"]) == "table", "potion restored")
end

local function testImportAdds()
    recipes = {}
    potions = {}
    registered = {}
    StockPiler.Knowledge.Recipes = function()
        return recipes
    end
    local rk = "mainx1:newfp"
    local result = RL.ImportKnownPotion({
        uid = 77,
        rk = rk,
        name = "Fresh",
        icon = 9,
        slots = sampleSlots,
    })
    eq(result, "imported", "import unknown")
    check(type(recipes[rk]) == "table", "recipe stored")
    check(type(potions["uid:77"]) == "table", "potion registered")
    eq(#registered, 1, "RegisterKnownPotion called")
end

local function testImportNoSlots()
    recipes = {}
    potions = {}
    local result = RL.ImportKnownPotion({
        uid = 88,
        rk = "mainx1:orphan",
        name = "NoSlots",
    })
    eq(result, "noslots", "reject without slots")
end

local function testRejects()
    eq(RL.ParsePlain(nil), nil, "nil plain")
    eq(RL.ParsePlain("ABILITY:1"), nil, "foreign payload")
    eq(RL.ParsePlain("POTION;n=x"), nil, "missing uid")
    eq(RL.SerializePlain({ rk = "x" }), nil, "serialize without uid")
end

local function testPlantRejected()
    eq(RL.FieldsFromRow({ kind = "plant", uniqueID = 1 }), nil, "plant row rejected")
end

testSlotRoundTrip()
testRoundTrip()
testTruncatedKeepsSlots()
testLegacyRkThenSlots()
testLinkLabelFields()
testImportKnownSkips()
testImportAfterForget()
testImportAdds()
testImportNoSlots()
testRejects()
testPlantRejected()

if failures > 0 then
    io.stderr:write(string.format("%d/%d checks failed\n", failures, checks))
    os.exit(1)
end
print(string.format("recipe_link: %d checks passed", checks))
