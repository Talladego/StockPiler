-- Prefer cultivable twins over butcher/vendor when sharing and learning recipes.
-- Run from the repo root: lua5.1 tests/prefer_growable_share.lua

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

local BUTCHER = 3030238
local PLANT = 3020048
local VIAL = 2001
local MAIN = 1001

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
StockPiler.T = function(key, tokens)
    local s = tostring(key)
    if type(tokens) == "table" then
        for k, v in pairs(tokens) do
            s = s .. "{" .. tostring(k) .. "=" .. tostring(v) .. "}"
        end
    end
    return s
end

load_module("Source/Core/Util.lua")
load_module("Source/Stores/KnowledgeStore.lua")
load_module("Source/Knowledge/MaterialSpec.lua")
load_module("Source/Knowledge/MaterialExceptions.lua")
load_module("Source/Knowledge/Items.lua")
load_module("Source/Knowledge/RecipeSpec.lua")
load_module("Source/View/RecipeLink.lua")
load_module("Source/View/RecipeShare.lua")

local RL = StockPiler.RecipeLink
local Spec = StockPiler.RecipeSpec
local Share = StockPiler.RecipeShare

local twinMap = {
    [BUTCHER] = PLANT,
    [PLANT] = PLANT,
}

StockPiler.SeedMap = {
    FindGrowableTwinUid = function(spec)
        local uid = tonumber(spec and (spec.uid or spec.uniqueID or spec.boundUid)) or 0
        return tonumber(twinMap[uid]) or 0
    end,
    IsGrowableSpec = function(spec)
        local uid = tonumber(spec and (spec.uid or spec.uniqueID)) or 0
        return uid == PLANT
    end,
    IsHarvestByproduct = function()
        return false
    end,
}

local itemRows = {
    [PLANT] = {
        uniqueID = PLANT,
        name = "Majestic Goldweed",
        iconNum = 42,
        kind = "plant",
        isRefinable = true,
    },
    [BUTCHER] = {
        uniqueID = BUTCHER,
        name = "Brutal Zoic Gore",
        iconNum = 55,
        kind = "mat",
        isRefinable = false,
    },
    [VIAL] = {
        uniqueID = VIAL,
        name = "Artisan's Glass Vial",
        iconNum = 12,
    },
    [MAIN] = {
        uniqueID = MAIN,
        name = "Bitter Grumpleaf",
        iconNum = 7,
        kind = "plant",
        isRefinable = true,
    },
}

StockPiler.Items.AsItemData = function(uid)
    uid = tonumber(uid) or 0
    local row = itemRows[uid]
    if type(row) ~= "table" then
        return nil
    end
    local copy = {}
    for k, v in pairs(row) do
        copy[k] = v
    end
    return copy
end
StockPiler.Items.GetByUid = function(uid)
    return itemRows[tonumber(uid) or 0]
end
local origStore = StockPiler.Items.StoreItem
StockPiler.Items.StoreItem = function(data, kind)
    local uid = tonumber(data and data.uniqueID) or 0
    if uid > 0 then
        StockPiler.Account.items[tostring(uid)] = {
            uniqueID = uid,
            name = data.name,
            iconNum = data.iconNum,
            kind = kind or "mat",
        }
        itemRows[uid] = itemRows[uid] or {
            uniqueID = uid,
            name = data.name,
            iconNum = data.iconNum,
            kind = kind or "mat",
        }
    end
    if origStore then
        return origStore(data, kind)
    end
end

local function stabSlot(role, uid, name, bonuses)
    return {
        role = role,
        uid = uid,
        perCraft = role == "stabilizer" and 2 or 1,
        name = name,
        iconNum = (itemRows[uid] and itemRows[uid].iconNum) or 0,
        spec = {
            uid = uid,
            role = role,
            name = name,
            iconNum = (itemRows[uid] and itemRows[uid].iconNum) or 0,
            power = tonumber(bonuses and bonuses[2]) or 0,
            stability = tonumber(bonuses and bonuses[1]) or 0,
            duration = tonumber(bonuses and bonuses[3]) or 0,
            tradeSkill = 4,
            skillLevel = 200,
            cultivationType = 0,
            slotType = 1,
            effectId = 0,
            bonuses = bonuses or {},
        },
    }
end

local function disciplineSlots(stabUid, stabName)
    return {
        stabSlot("container", VIAL, "Artisan's Glass Vial", { [1] = 2, [2] = 1 }),
        stabSlot("main", MAIN, "Bitter Grumpleaf", { [1] = -22, [2] = 17, [6] = 35 }),
        stabSlot("stabilizer", stabUid, stabName, { [1] = 10, [4] = 1 }),
        stabSlot("extender", 3001, "Taut Gobswort", { [3] = 16, [14] = 1 }),
    }
end

itemRows[3001] = {
    uniqueID = 3001,
    name = "Taut Gobswort",
    iconNum = 8,
    kind = "plant",
    isRefinable = true,
}

-- Sender knows the Goldweed twin: PreferGrowable rewrites the butcher exemplar.
do
    local slots = disciplineSlots(BUTCHER, "Brutal Zoic Gore")
    Spec.PreferGrowableSlotExemplars(slots)
    local stab = nil
    for i = 1, #slots do
        if tostring(slots[i].role) == "stabilizer" then
            stab = slots[i]
            break
        end
    end
    eq(stab and tonumber(stab.uid), PLANT, "sender prefer rewrites stabilizer to plant uid")
    eq(stab and tostring(stab.name), "Majestic Goldweed", "sender prefer renames stabilizer to plant")
    local plain = RL.SerializePlain({
        uid = 9001,
        name = "Lasting Potion of Discipline",
        icon = 1,
        slots = slots,
    })
    check(type(plain) == "string" and plain ~= "", "serialize after prefer")
    check(string.find(plain, "slots=", 1, true) ~= nil, "plain carries slots")
    check(string.find(plain, tostring(PLANT), 1, true) ~= nil, "plain encodes plant uid")
    check(string.find(plain, tostring(BUTCHER), 1, true) == nil, "plain omits butcher uid")
    check(string.find(plain, "Majestic Goldweed", 1, true) ~= nil, "plain d= carries plant name")
end

-- Cold receiver: empty Account.items; link already has plant from sender.
do
    StockPiler.Account.items = {}
    twinMap[BUTCHER] = nil
    twinMap[PLANT] = nil
    local slots = disciplineSlots(PLANT, "Majestic Goldweed")
    local fields = {
        uid = 9002,
        name = "Lasting Potion of Discipline",
        icon = 1,
        slots = slots,
        details = {
            [PLANT] = { uid = PLANT, icon = 42, name = "Majestic Goldweed" },
            [VIAL] = { uid = VIAL, icon = 12, name = "Artisan's Glass Vial" },
            [MAIN] = { uid = MAIN, icon = 7, name = "Bitter Grumpleaf" },
            [3001] = { uid = 3001, icon = 8, name = "Taut Gobswort" },
        },
    }
    local described = Share.DescribeSlot(slots[3], fields)
    eq(described.uid, PLANT, "cold preview keeps plant uid from the link")
    eq(tostring(described.name), "Majestic Goldweed", "cold preview uses d= plant name")
    local imported = Spec.ImportSharedRecipe(9002, slots, {
        out = { uniqueID = 9002, name = "Lasting Potion of Discipline", iconNum = 1 },
        quality = "good",
    })
    eq(imported, "imported", "cold Learn imports the plant exemplar recipe")
    local stored = StockPiler.Account.items[tostring(PLANT)]
    check(type(stored) == "table", "Learn stores the plant mat for a cold receiver")
    eq(stored and tostring(stored.name), "Majestic Goldweed", "stored mat keeps the plant name")
end

-- Butcher-only: no twin known on sender or receiver.
do
    twinMap[BUTCHER] = nil
    twinMap[PLANT] = nil
    StockPiler.Account.items = {}
    local slots = disciplineSlots(BUTCHER, "Brutal Zoic Gore")
    Spec.PreferGrowableSlotExemplars(slots)
    local stab = nil
    for i = 1, #slots do
        if tostring(slots[i].role) == "stabilizer" then
            stab = slots[i]
            break
        end
    end
    eq(stab and tonumber(stab.uid), BUTCHER, "butcher-only prefer keeps butcher uid")
    eq(stab and tostring(stab.name), "Brutal Zoic Gore", "butcher-only prefer keeps butcher name")
    local described = Share.DescribeSlot(stab, {
        details = {
            [BUTCHER] = { uid = BUTCHER, icon = 55, name = "Brutal Zoic Gore" },
        },
    })
    eq(described.uid, BUTCHER, "butcher-only preview keeps butcher")
    eq(tostring(described.name), "Brutal Zoic Gore", "butcher-only preview shows butcher name")
end

-- Receiver with a local twin upgrades an older butcher link on Learn.
do
    twinMap[BUTCHER] = PLANT
    twinMap[PLANT] = PLANT
    StockPiler.Account.items = {
        [tostring(PLANT)] = itemRows[PLANT],
    }
    local slots = disciplineSlots(BUTCHER, "Brutal Zoic Gore")
    local imported = Spec.ImportSharedRecipe(9003, slots, {
        out = { uniqueID = 9003, name = "Lasting Potion of Discipline", iconNum = 1 },
        quality = "good",
        skipRegister = false,
    })
    eq(imported, "imported", "Learn upgrades butcher link when a plant twin is known")
    local stabUid = nil
    for _, recipe in pairs(StockPiler.Account.recipes) do
        if type(recipe) == "table" and type(recipe.slots) == "table" then
            for i = 1, #recipe.slots do
                if tostring(recipe.slots[i].role) == "stabilizer" then
                    stabUid = tonumber(recipe.slots[i].uid)
                end
            end
        end
    end
    eq(stabUid, PLANT, "stored recipe stabilizer becomes the plant twin")
end

-- Real SeedMap: a nameless preview must not pin the butcher uid as growable
-- when the receiver knows Majestic Goldweed and has never looted the gore.
do
    load_module("Source/Knowledge/Items.lua")
    load_module("Source/Knowledge/SeedMap.lua")
    local SM = StockPiler.SeedMap
    StockPiler.Account.items = {
        [tostring(PLANT)] = {
            uniqueID = PLANT,
            name = "Majestic Goldweed",
            iconNum = 42,
            kind = "plant",
            isRefinable = true,
            itemType = 34,
            tradeSkill = 4,
            skillLevel = 200,
            skillReq = 200,
            cultivationType = 0,
            slotType = 1,
            role = "stabilizer",
            bonuses = { [1] = 10, [4] = 1 },
            stability = 10,
        },
    }
    StockPiler.Account.recipes = {}
    StockPiler.Account.potions = {}
    local nameless = {
        uid = BUTCHER,
        role = "stabilizer",
        tradeSkill = 4,
        skillLevel = 200,
        cultivationType = 0,
        slotType = 1,
        bonuses = { [1] = 10, [4] = 1 },
    }
    eq(SM.IsGrowableSpec(nameless), true, "nameless unknown butcher uid still guesses growable")
    local named = {
        uid = BUTCHER,
        role = "stabilizer",
        name = "Brutal Zoic Gore",
        tradeSkill = 4,
        skillLevel = 200,
        cultivationType = 0,
        slotType = 1,
        bonuses = { [1] = 10, [4] = 1 },
    }
    eq(SM.IsGrowableSpec(named), false, "named butcher is not growable after the nameless probe")
    eq(SM.FindGrowableTwinUid(named), PLANT, "named butcher resolves Majestic Goldweed")

    local plain = RL.SerializePlain({
        uid = 9004,
        name = "Lasting Potion of Discipline",
        icon = 1,
        slots = disciplineSlots(BUTCHER, "Brutal Zoic Gore"),
    })
    local fields = RL.ParsePlain(plain)
    check(type(fields) == "table" and type(fields.slots) == "table", "butcher link parses")
    local stab = nil
    for i = 1, #(fields and fields.slots or {}) do
        if tostring(fields.slots[i].role) == "stabilizer" then
            stab = fields.slots[i]
            break
        end
    end
    eq(stab and stab.spec and tostring(stab.spec.name), "Brutal Zoic Gore", "ParsePlain copies the link name onto the slot")
    eq(tonumber(stab and stab.spec and stab.spec.iconNum), 55, "ParsePlain copies the link icon onto the slot")
    eq(tostring(stab and stab.name), "Brutal Zoic Gore", "ParsePlain copies the link name onto the slot row")

    SM.IsGrowableSpec(nameless)
    stab.name = nil
    stab.spec.name = nil
    local described = Share.DescribeSlot(stab, fields)
    eq(described.uid, PLANT, "preview swaps the unlooted butcher ingredient to the known plant")
    eq(tostring(described.name), "Majestic Goldweed", "preview shows the known plant")

    eq(RL.ImportKnownPotion(fields), "imported", "Learn imports after the preview")
    local learnedUid = nil
    for _, recipe in pairs(StockPiler.Account.recipes) do
        if type(recipe) == "table" and tonumber(recipe.outputUid) == 9004
            and type(recipe.slots) == "table"
        then
            for i = 1, #recipe.slots do
                if tostring(recipe.slots[i].role) == "stabilizer" then
                    learnedUid = tonumber(recipe.slots[i].uid)
                end
            end
        end
    end
    eq(learnedUid, PLANT, "Learn stores the known plant instead of the butcher ingredient")
    eq(StockPiler.Account.items[tostring(BUTCHER)], nil, "Learn does not store the unlooted butcher item")
end

if failures > 0 then
    io.stderr:write(string.format("%d/%d checks failed\n", failures, checks))
    os.exit(1)
end
print(string.format("prefer_growable_share: %d checks passed", checks))
