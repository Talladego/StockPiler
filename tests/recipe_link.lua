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

local state = { storeCalls = 0 }

StockPiler.Items = {
    rows = {},
    StoreItem = function(data, kind)
        state.storeCalls = state.storeCalls + 1
        local uid = data and (data.uniqueID or data.uniqueId)
        StockPiler.Items.rows[tostring(uid)] = {
            name = data and data.name,
            iconNum = data and data.iconNum,
            kind = kind,
        }
    end,
}

local function recipeKey(slots)
    if type(slots) ~= "table" or #slots < 1 then
        return ""
    end
    local parts = {}
    for i = 1, #slots do
        local s = slots[i]
        if type(s) ~= "table" then
            return ""
        end
        local spec = type(s.spec) == "table" and s.spec or {}
        local fx = tonumber(spec.effectId) or 0
        parts[#parts + 1] = tostring(s.role)
            .. "x" .. tostring(s.perCraft or 1)
            .. ":u" .. tostring(s.uid)
            .. ":fx" .. tostring(fx)
    end
    return table.concat(parts, "|")
end

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
    RegisterKnownPotion = function(uid, out, rk, quality, opts)
        opts = type(opts) == "table" and opts or {}
        local pk = "uid:" .. tostring(uid)
        local existing = potions[pk]
        local isNew = type(existing) ~= "table"
        if isNew then
            existing = {
                potionKey = pk,
                outputUid = uid,
                recipeKeys = {},
                name = nil,
                iconNum = 0,
            }
        end
        if opts.linkImport == true then
            if isNew then
                existing.name = out and out.name or existing.name
                if out and tonumber(out.iconNum) and tonumber(out.iconNum) > 0 then
                    existing.iconNum = tonumber(out.iconNum)
                end
            end
            local keys = {}
            if type(existing.recipeKeys) == "table" then
                for i = 1, #existing.recipeKeys do
                    keys[#keys + 1] = existing.recipeKeys[i]
                end
            end
            if tostring(existing.activeRecipeKey or "") ~= "" then
                local seenActive = false
                for i = 1, #keys do
                    if keys[i] == existing.activeRecipeKey then
                        seenActive = true
                        break
                    end
                end
                if not seenActive then
                    keys[#keys + 1] = existing.activeRecipeKey
                end
            end
            local seen = false
            for i = 1, #keys do
                if keys[i] == rk then
                    seen = true
                    break
                end
            end
            if not seen then
                keys[#keys + 1] = rk
            end
            existing.recipeKeys = keys
            if tostring(existing.activeRecipeKey or "") == "" then
                existing.activeRecipeKey = rk
            end
        else
            StockPiler.Items.StoreItem(out or { uniqueID = uid }, "potion")
            existing.name = out and out.name
            existing.iconNum = out and out.iconNum
            existing.recipeKeys = { rk }
            existing.activeRecipeKey = rk
        end
        potions[pk] = existing
        registered[#registered + 1] = {
            uid = uid,
            rk = rk,
            quality = quality,
            linkImport = opts.linkImport == true,
        }
        return existing, isNew, true, false
    end,
    RecipeSpecKey = recipeKey,
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
    check(string.find(plain, "rk=", 1, true) == nil, "new share omits rk")
    local parsed = RL.ParsePlain(plain)
    check(type(parsed) == "table", "parse returns table")
    eq(tonumber(parsed.uid), 3012345, "uid round-trip")
    eq(parsed.rk, nil, "parsed share has no rk")
    eq(tostring(parsed.name), "Bitter Example", "name round-trip")
    eq(tonumber(parsed.icon), 123, "icon round-trip")
    check(type(parsed.slots) == "table" and #parsed.slots == 2, "slots round-trip")
    eq(tonumber(parsed.slots[1].spec.effectId), nil, "absent effect stays absent")
end

local function testEffectBonusRoundTrip()
    local slots = {
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
                effectId = 4,
                bonuses = { [4] = 2, [6] = 4, [12] = 15 },
            },
        },
    }
    local enc = RL.EncodeSlots(slots)
    check(string.find(enc, ":4:4=2,6=4,12=15", 1, true) ~= nil, "effect and bonuses encoded")
    local decoded = RL.DecodeSlots(enc)
    eq(tonumber(decoded[1].spec.effectId), 4, "effect round-trip")
    eq(tonumber(decoded[1].spec.bonuses[4]), 2, "multiplier bonus")
    eq(tonumber(decoded[1].spec.bonuses[12]), 15, "crit bonus")
    eq(tonumber(decoded[1].spec.bonuses[6]), 4, "effect bonus")
end

local function testTruncatedKeepsSlots()
    local fields = {
        uid = 9,
        rk = "mainx1:verylongfingerprint",
        name = "Cut",
        slots = sampleSlots,
    }
    local plain = RL.SerializePlain(fields)
    check(string.find(plain, ";rk=", 1, true) == nil, "share has no rk to cut")
    local legacy = plain .. ";rk=mainx1:verylongfingerprint"
    local cut = string.match(legacy, "^(.-);rk=")
    check(cut ~= nil, "can strip a legacy rk")
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

local function testGrammarSuffixStrippedFromName()
    local fields = {
        uid = 1,
        name = "Elixir of X^n",
        icon = 4,
        slots = sampleSlots,
    }
    eq(tostring(RL.DisplayName(fields)), "Elixir of X", "grammar suffix leaves the label")
    local plain = RL.SerializePlain(fields)
    check(type(plain) == "string", "suffix name still serializes")
    check(string.find(plain, "Elixir of Xn", 1, true) == nil, "suffix letters are not kept")
    check(string.find(plain, "n=Elixir of X", 1, true) ~= nil, "name keeps the words before the suffix")
    local parsed = RL.ParsePlain(plain)
    eq(tostring(parsed.name), "Elixir of X", "imported name has no suffix letters")
end

local function resetKnowledge()
    recipes = {}
    potions = {}
    registered = {}
    state.storeCalls = 0
    StockPiler.Items.rows = {}
    StockPiler.Knowledge.Recipes = function()
        return recipes
    end
end

local function testImportKnownSkips()
    resetKnowledge()
    local rk = recipeKey(sampleSlots)
    recipes[rk] = { recipeSpecKey = rk, slots = sampleSlots, sentinel = "row" }
    -- Fingerprint alone must NOT count as known (Forget leaves recipes rows).
    local orphan = RL.ImportKnownPotion({
        uid = 55,
        rk = "mainx1:lie",
        name = "Orphan",
        slots = sampleSlots,
    })
    eq(orphan, "imported", "orphan fingerprint re-links potion")
    eq(recipes[rk].sentinel, "row", "existing recipe not replaced")
    potions["uid:55"] = {
        potionKey = "uid:55",
        outputUid = 55,
        recipeKeys = { rk },
        activeRecipeKey = rk,
        name = "English",
        iconNum = 10,
    }
    registered = {}
    local result = RL.ImportKnownPotion({
        uid = 55,
        rk = rk,
        name = "Known",
        icon = 99,
        slots = sampleSlots,
    })
    eq(result, "known", "skip when potion still linked")
    eq(#registered, 0, "known import does not register again")
    eq(potions["uid:55"].name, "English", "known import keeps name")
    eq(potions["uid:55"].iconNum, 10, "known import keeps icon")
end

local function testImportAfterForget()
    resetKnowledge()
    local rk = recipeKey(sampleSlots)
    local keptSlots = sampleSlots
    recipes[rk] = {
        recipeSpecKey = rk,
        slots = keptSlots,
        outcomes = { ["66"] = { uid = 66, samples = 3, qtySum = 8, quality = "good" } },
        sentinel = "forgot",
    }
    eq(RL.RecipeIsKnown({ uid = 66, slots = sampleSlots }), false, "forgotten potion not known")
    local result = RL.ImportKnownPotion({
        uid = 66,
        rk = rk,
        name = "Readd",
        slots = sampleSlots,
    })
    eq(result, "imported", "reimport after forget")
    check(type(potions["uid:66"]) == "table", "potion restored")
    eq(recipes[rk].sentinel, "forgot", "forget row kept")
    eq(recipes[rk].slots, keptSlots, "forget slots not replaced")
    eq(recipes[rk].outcomes["66"].samples, 3, "forget outcomes not replaced")
    eq(potions["uid:66"].name, "Readd", "new potion gets link name")
end

local function testImportAdds()
    resetKnowledge()
    local rk = recipeKey(sampleSlots)
    local result = RL.ImportKnownPotion({
        uid = 77,
        rk = "mainx1:newfp",
        name = "Fresh",
        icon = 9,
        slots = sampleSlots,
    })
    eq(result, "imported", "import unknown")
    check(type(recipes[rk]) == "table", "recipe stored under recomputed key")
    eq(recipes["mainx1:newfp"], nil, "mismatched link rk is not a recipe key")
    check(type(potions["uid:77"]) == "table", "potion registered")
    eq(#registered, 1, "RegisterKnownPotion called")
    eq(registered[1].linkImport, true, "import passes linkImport")
    eq(recipes[rk].outcomes["77"], nil, "no synthetic outcome")
    eq(recipes[rk].sharedImport, true, "import marked shared")
    eq(recipes[rk].unverified, true, "import marked unverified")
    eq(state.storeCalls, 0, "import does not store item")
    eq(potions["uid:77"].name, "Fresh", "new potion name")
    eq(potions["uid:77"].iconNum, 9, "new potion icon")
    eq(potions["uid:77"].activeRecipeKey, rk, "new potion active is recomputed key")
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

local function altSlots()
    return {
        {
            role = "main",
            uid = 7777,
            perCraft = 1,
            spec = {
                uid = 7777,
                role = "main",
                power = 3,
                stability = -2,
                duration = 1,
                tradeSkill = 4,
                skillLevel = 20,
                cultivationType = 0,
                slotType = 1,
                effectId = 9,
            },
        },
        {
            role = "container",
            uid = 8888,
            perCraft = 1,
            spec = {
                uid = 8888,
                role = "container",
                power = 0,
                stability = 8,
                duration = 0,
                tradeSkill = 4,
                skillLevel = 1,
                cultivationType = 0,
                slotType = 2,
            },
        },
    }
end

local function testH2LeavesExistingUntouched()
    resetKnowledge()
    local oldKey = recipeKey(sampleSlots)
    local keptSlots = sampleSlots
    local keptOutcomes = { ["55"] = { uid = 55, samples = 4, qtySum = 9, quality = "good" } }
    recipes[oldKey] = {
        recipeSpecKey = oldKey,
        slots = keptSlots,
        outcomes = keptOutcomes,
        sentinel = "orig",
        sharedImport = nil,
    }
    potions["uid:55"] = {
        potionKey = "uid:55",
        outputUid = 55,
        name = "English",
        iconNum = 10,
        recipeKeys = { oldKey },
        activeRecipeKey = oldKey,
    }
    StockPiler.Items.rows["55"] = { name = "English", iconNum = 10 }
    local fresh = altSlots()
    local newKey = recipeKey(fresh)
    check(newKey ~= oldKey, "alt recipe key differs")
    local result = RL.ImportKnownPotion({
        uid = 55,
        rk = oldKey,
        name = "Potion francaise",
        icon = 99,
        slots = fresh,
    })
    eq(result, "imported", "h2 different recipe imports as alternative")
    eq(recipes[oldKey], recipes[oldKey], "h2 old recipe still present")
    eq(recipes[oldKey].sentinel, "orig", "h2 old recipe identity")
    eq(recipes[oldKey].slots, keptSlots, "h2 old slots untouched")
    eq(recipes[oldKey].outcomes, keptOutcomes, "h2 old outcomes untouched")
    eq(recipes[oldKey].outcomes["55"].samples, 4, "h2 no rewritten sample count")
    eq(potions["uid:55"].name, "English", "h2 potion name untouched")
    eq(potions["uid:55"].iconNum, 10, "h2 potion icon untouched")
    eq(potions["uid:55"].activeRecipeKey, oldKey, "h2 active recipe untouched")
    eq(StockPiler.Items.rows["55"].name, "English", "h2 item cache untouched")
    eq(state.storeCalls, 0, "h2 store item not called")
    check(type(recipes[newKey]) == "table", "h2 new fingerprint stored")
    eq(recipes[newKey].outcomes["55"], nil, "h2 new recipe has no fake outcome")
    eq(recipes[newKey].sharedImport, true, "h2 new recipe unverified marker")
    local foundNew = false
    local foundOld = false
    for i = 1, #potions["uid:55"].recipeKeys do
        if potions["uid:55"].recipeKeys[i] == newKey then
            foundNew = true
        end
        if potions["uid:55"].recipeKeys[i] == oldKey then
            foundOld = true
        end
    end
    check(foundOld, "h2 keeps previous key")
    check(foundNew, "h2 adds alternative key")
    eq(registered[#registered].linkImport, true, "h2 linkImport set")
    eq(registered[#registered].rk, newKey, "h2 registers recomputed key")
end

local function testH2KnownRecipeNotRewritten()
    resetKnowledge()
    local rk = recipeKey(sampleSlots)
    local outcomes = { ["55"] = { uid = 55, samples = 2, quality = "good" } }
    recipes[rk] = {
        recipeSpecKey = rk,
        slots = sampleSlots,
        outcomes = outcomes,
        sentinel = "same",
    }
    potions["uid:55"] = {
        potionKey = "uid:55",
        name = "English",
        iconNum = 10,
        recipeKeys = { rk },
        activeRecipeKey = rk,
    }
    local result = RL.ImportKnownPotion({
        uid = 55,
        rk = "not-the-real-key",
        name = "Other",
        icon = 1,
        slots = sampleSlots,
    })
    eq(result, "known", "h2 matching slots are already known")
    eq(recipes[rk].sentinel, "same", "h2 known recipe not rewritten")
    eq(recipes[rk].outcomes, outcomes, "h2 known outcomes untouched")
    eq(recipes["not-the-real-key"], nil, "h2 ignored link rk stored nowhere")
    eq(#registered, 0, "h2 known path does not register")
    eq(state.storeCalls, 0, "h2 known path does not store")
end

local function countTables()
    local nr, np = 0, 0
    for _ in pairs(recipes) do
        nr = nr + 1
    end
    for _ in pairs(potions) do
        np = np + 1
    end
    return nr, np
end

local function testH3RejectsBadPayloads()
    resetKnowledge()
    local good = "main:1001:1:10:5:0:4:50:0:1"
    local nine = {}
    for i = 1, 9 do
        nine[i] = "main:" .. tostring(1000 + i) .. ":1:1:1:0:4:1:0:1"
    end
    local huge = string.rep("9", 400)
    local bad = {
        "POTION;uid=inf;slots=" .. good,
        "POTION;uid=nan;slots=" .. good,
        "POTION;uid=0x10;slots=" .. good,
        "POTION;uid=1e999;slots=" .. good,
        "POTION;uid=12345678901;slots=" .. good,
        "POTION;uid=5;slots=main:1:" .. huge .. ":0:0:0:4:1:0:1",
        "POTION;uid=5;slots=" .. table.concat(nine, "^"),
        "POTION;uid=5;slots=nope:1001:1:0:0:0:4:1:0:1",
        "POTION;uid=5;slots=main:0x10:1:0:0:0:4:1:0:1",
        "POTION;uid=5;slots=main:1001:1:nan:0:0:4:1:0:1",
        "POTION;uid=5;slots=main:1001:1:1e99:0:0:4:1:0:1",
        'POTION;uid=5;n=Evil"><LINK data=x;slots=' .. good,
        "POTION;uid=5;rk=bad rk;slots=" .. good,
        "POTION;uid=5;rk=" .. string.rep("a", 1100) .. ";slots=" .. good,
    }
    for i = 1, #bad do
        eq(RL.ParsePlain(bad[i]), nil, "h3 reject payload " .. tostring(i))
        eq(RL.ParseLinkData("StockPiler:" .. bad[i]), nil, "h3 reject link " .. tostring(i))
    end
    local direct = {
        { uid = "inf", slots = sampleSlots },
        { uid = "0x10", slots = sampleSlots },
        { uid = "1e999", slots = sampleSlots },
        { uid = 0 / 0, slots = sampleSlots },
        {
            uid = 5,
            slots = {
                {
                    role = "main",
                    uid = "0x10",
                    perCraft = 1,
                    spec = { power = 1, stability = 0, duration = 0, tradeSkill = 4, skillLevel = 1, cultivationType = 0, slotType = 1 },
                },
            },
        },
        {
            uid = 5,
            name = 'Evil"><LINK',
            slots = sampleSlots,
        },
    }
    for i = 1, #direct do
        eq(RL.ImportKnownPotion(direct[i]), "failed", "h3 import reject " .. tostring(i))
    end
    local nr, np = countTables()
    eq(nr, 0, "h3 recipes unchanged")
    eq(np, 0, "h3 potions unchanged")
    eq(#registered, 0, "h3 nothing registered")
    eq(state.storeCalls, 0, "h3 nothing stored")
    local container = "container:2002:1:0:20:0:4:1:0:2"
    local ok = RL.ParsePlain("POTION;uid=5;n=Fine;slots=" .. good .. "^" .. container)
    check(type(ok) == "table" and tonumber(ok.uid) == 5, "h3 still accepts a clean link")
    check(type(ok.slots) == "table" and #ok.slots == 2, "h3 clean link has main and container")
    check(type(RL.DecodeSlots(good)) == "table", "h3 legacy ten-field slot still decodes")
end

local function testKnownWithoutRk()
    resetKnowledge()
    local rk = recipeKey(sampleSlots)
    potions["uid:55"] = {
        recipeKeys = { rk },
        activeRecipeKey = rk,
    }
    eq(RL.RecipeIsKnown({ uid = 55, slots = sampleSlots }), true, "l1 recomputed key counts as known")
    eq(RL.RecipeIsKnown({ uid = 55, rk = "", slots = sampleSlots }), true, "l1 empty rk still resolves")
end

local function testMenuDoesNotArmLink()
    resetKnowledge()
    RL._lastShareKey = "old"
    EA_Window_ContextMenu = {
        CreateContextMenu = function() end,
        AddMenuItem = function() end,
        Finalize = function() end,
    }
    local opened = false
    RL.ShowContextMenuForRow({
        uniqueID = 1001,
        recipeSpecKey = recipeKey(sampleSlots),
        name = "Heal",
        iconNum = 1,
    })
    eq(RL._lastShareKey, "old", "l3 menu open does not set last share")
    eq(opened, false, "l3 menu does not share")
end

local function testOpenOnlyAfterSuccess()
    resetKnowledge()
    local opened = 0
    StockPiler.Ui = {
        ShowWindow = function()
            opened = opened + 1
        end,
    }
    RL.OpenLinkedRecipe(nil)
    eq(opened, 0, "l6 nil payload does not open")
    RL.OpenLinkedRecipe({ uid = 5, name = "X" })
    eq(opened, 0, "l6 noslots does not open")
    RL.OpenLinkedRecipe({ uid = "inf", slots = sampleSlots })
    eq(opened, 0, "l6 bad payload does not open")
    local rk = recipeKey(sampleSlots)
    RL.OpenLinkedRecipe({ uid = 55, name = "New", slots = sampleSlots })
    eq(opened, 1, "l6 import opens")
    RL.OpenLinkedRecipe({ uid = 55, slots = sampleSlots })
    eq(opened, 2, "l6 known opens")
    eq(potions["uid:55"].activeRecipeKey, rk, "l6 import used recomputed key")
end

local function testHookLeavesLaterAddon()
    local prev = function() end
    local later = function() end
    EA_ChatWindow = { OnHyperLinkLButtonUp = prev, InsertText = function() end }
    RL._hyperlinkHooked = false
    RL._prevOnHyperLinkLButtonUp = nil
    RL.InstallHyperlinkHook()
    check(EA_ChatWindow.OnHyperLinkLButtonUp ~= prev, "hook installed")
    EA_ChatWindow.OnHyperLinkLButtonUp = later
    RL.UninstallHyperlinkHook()
    eq(EA_ChatWindow.OnHyperLinkLButtonUp, later, "l5 shutdown leaves a later hook")
end

local function testZeroBonusKept()
    local slots = {
        {
            role = "stimulant",
            uid = 5,
            perCraft = 1,
            spec = {
                uid = 5,
                role = "stimulant",
                power = 0,
                stability = 0,
                duration = 0,
                tradeSkill = 4,
                skillLevel = 10,
                cultivationType = 0,
                slotType = 1,
                bonuses = { [1] = 0, [4] = 2 },
            },
        },
    }
    local enc = RL.EncodeSlots(slots)
    check(string.find(enc, "1=0", 1, true) ~= nil, "present zero bonus is encoded")
    local decoded = RL.DecodeSlots(enc)
    eq(decoded[1].spec.bonuses[1], 0, "decoder keeps stability 0")
    eq(decoded[1].spec.bonuses[4], 2, "decoder keeps other bonus")
end

local function testChatCountsExistingText()
    local inserted = nil
    TextEditBoxSetMaxChars = function(_, n)
        eq(n, 4096, "chat max raised before insert")
    end
    TextEditBoxGetText = function(name)
        eq(name, "EA_TextEntryGroupEntryBoxTextInput", "existing text read from chat box")
        return string.rep("x", 4000)
    end
    CreateHyperLink = function(data, text)
        return "<LINK data=\"" .. tostring(data) .. "\" text=\"" .. tostring(text) .. "\">"
    end
    EA_ChatWindow = {
        InsertText = function(text)
            inserted = text
        end,
    }
    local fields = {
        uid = 1001,
        rk = "mainx1:abc",
        name = "Heal",
        icon = 1,
        slots = sampleSlots,
    }
    eq(RL.ShareFields(fields), false, "full box plus link does not fit")
    eq(inserted, nil, "over-cap link is not inserted")
    TextEditBoxGetText = function()
        return ""
    end
    eq(RL.ShareFields(fields), true, "empty box accepts the link")
    check(inserted ~= nil, "link inserted when the box has room")
end

local function testChatKeepsMultiSlotLink()
    local fields = {
        uid = 3012345,
        name = "Multi",
        icon = 3,
        slots = sampleSlots,
    }
    local link = tostring(RL.BuildLinkData(fields))
    check(string.find(link, "~", 1, true) ~= nil, "new link joins slots with tilde")
    check(string.find(link, "^", 1, true) == nil, "new link has no caret")
    -- WAR chat strips caret-prefixed words on send and on click.
    local stripped = string.gsub(link, "%^%a+", "")
    local parsed = RL.ParseLinkData(stripped)
    check(type(parsed) == "table" and type(parsed.slots) == "table", "stripped link parses")
    eq(#parsed.slots, 2, "stripped link keeps every slot")
    eq(parsed.slots[1].role, "main", "stripped first role")
    eq(tonumber(parsed.slots[1].uid), 1001, "stripped first uid")
    eq(parsed.slots[2].role, "container", "stripped second role")
    eq(tonumber(parsed.slots[2].uid), 2002, "stripped second uid")

    -- The tilde link above has no caret, so the strip is only a guard.
    -- A legacy caret link is damaged by the same strip, and by a cut at the first caret.
    local mainSlot = "main:1001:1:10:5:0:4:50:0:1:0:"
    local containerSlot = "container:2002:1:0:20:0:4:1:0:2:0:"
    local stabSlot = "stabilizer:3003:1:0:4:0:4:10:0:1:0:"
    local legacySlots = mainSlot .. "^" .. containerSlot .. "^" .. stabSlot
    local legacy = "StockPiler:POTION;uid=3012345;n=Legacy;slots=" .. legacySlots
    local wordStripped = string.gsub(legacy, "%^%a+", "")
    check(wordStripped ~= legacy, "legacy caret link actually loses caret words")
    eq(RL.ParseLinkData(wordStripped), nil, "caret-word stripped legacy link rejected")
    local cutAt = string.find(legacySlots, "^", 1, true)
    local cutSlots = string.sub(legacySlots, 1, cutAt - 1)
    local cut = "StockPiler:POTION;uid=3012345;n=Legacy;slots=" .. cutSlots
    eq(RL.ParseLinkData(cut), nil, "legacy link cut at first caret rejected")
    eq(RL.ImportKnownPotion({ uid = 3012345, slotsEncoded = cutSlots }), "failed", "cut link does not import")
end

local function testNeedsMainAndContainer()
    resetKnowledge()
    local mainOnly = "main:1001:1:10:5:0:4:50:0:1:0:"
    local containerOnly = "container:2002:1:0:20:0:4:1:0:2:0:"
    eq(RL.ParsePlain("POTION;uid=5;slots=" .. mainOnly), nil, "main-only link rejected")
    eq(RL.ParsePlain("POTION;uid=5;slots=" .. containerOnly), nil, "container-only link rejected")
    eq(RL.ParseLinkData("StockPiler:POTION;uid=5;slots=" .. mainOnly), nil, "main-only hyperlink rejected")
    eq(RL.ImportKnownPotion({ uid = 5, slots = { sampleSlots[1] } }), "failed", "main-only import rejected")
    eq(RL.ImportKnownPotion({ uid = 5, slots = { sampleSlots[2] } }), "failed", "container-only import rejected")
    eq(RL.ImportKnownPotion({ uid = 5, slotsEncoded = mainOnly }), "failed", "main-only encoded import rejected")
    local nr, np = countTables()
    eq(nr, 0, "incomplete link stores no recipe")
    eq(np, 0, "incomplete link stores no potion")
    -- Two different stabilizers share the ingredient slots. Saved recipes already do this.
    local slots = {
        sampleSlots[1],
        sampleSlots[2],
        {
            role = "stabilizer",
            uid = 3003,
            perCraft = 1,
            spec = {
                uid = 3003,
                role = "stabilizer",
                power = 0,
                stability = 4,
                duration = 0,
                tradeSkill = 4,
                skillLevel = 10,
                cultivationType = 0,
                slotType = 1,
            },
        },
        {
            role = "stabilizer",
            uid = 3004,
            perCraft = 1,
            spec = {
                uid = 3004,
                role = "stabilizer",
                power = 0,
                stability = 6,
                duration = 0,
                tradeSkill = 4,
                skillLevel = 12,
                cultivationType = 0,
                slotType = 1,
            },
        },
    }
    eq(RL.ImportKnownPotion({ uid = 8, name = "TwinStab", slots = slots }), "imported", "repeated stabilizer roles still import")
    eq(#recipes[recipeKey(slots)].slots, 4, "both stabilizers kept")
end

local function testLegacyCaretAndBadSeparators()
    local mainSlot = "main:1001:1:10:5:0:4:50:0:1:0:"
    local containerSlot = "container:2002:1:0:20:0:4:1:0:2:0:"
    local stabSlot = "stabilizer:3003:1:0:4:0:4:10:0:1:0:"
    local legacy = mainSlot .. "^" .. containerSlot .. "^" .. stabSlot
    local modern = string.gsub(legacy, "%^", "~")
    check(string.find(modern, "~", 1, true) ~= nil, "tilde fixture uses tilde")
    local fromCaret = RL.DecodeSlots(legacy)
    local fromTilde = RL.DecodeSlots(modern)
    eq(#fromCaret, 3, "legacy caret link decodes")
    eq(#fromTilde, 3, "tilde link decodes")
    eq(fromCaret[1].role, fromTilde[1].role, "caret and tilde share role 1")
    eq(fromCaret[2].uid, fromTilde[2].uid, "caret and tilde share uid 2")
    eq(fromCaret[3].role, "stabilizer", "legacy third role")
    local plain = RL.SerializePlain({ uid = 7, slotsEncoded = legacy })
    check(type(plain) == "string", "legacy slots re-encode")
    check(string.find(plain, "~", 1, true) ~= nil, "re-emitted join is tilde")
    check(string.find(plain, "^", 1, true) == nil, "re-emitted payload has no caret")
    eq(RL.DecodeSlots("^" .. mainSlot), nil, "leading caret rejected")
    eq(RL.DecodeSlots(mainSlot .. "^"), nil, "trailing caret rejected")
    eq(RL.DecodeSlots(mainSlot .. "^^" .. containerSlot), nil, "doubled caret rejected")
    eq(RL.DecodeSlots("~" .. mainSlot), nil, "leading tilde rejected")
    eq(RL.DecodeSlots(mainSlot .. "~"), nil, "trailing tilde rejected")
    eq(RL.DecodeSlots(mainSlot .. "~~" .. containerSlot), nil, "doubled tilde rejected")
    eq(RL.DecodeSlots(mainSlot .. "~^" .. containerSlot), nil, "mixed ~^ rejected")
    eq(RL.DecodeSlots(mainSlot .. "^~" .. containerSlot), nil, "mixed ^~ rejected")
end

local function testShareRequiresMainAndContainer()
    resetKnowledge()
    local printed = {}
    StockPiler.Debug = {
        Reply = function(msg)
            printed[#printed + 1] = tostring(msg)
        end,
    }
    local inserted = nil
    TextEditBoxSetMaxChars = function() end
    TextEditBoxGetText = function()
        return ""
    end
    CreateHyperLink = function(data, text)
        return "<LINK data=\"" .. tostring(data) .. "\" text=\"" .. tostring(text) .. "\">"
    end
    EA_ChatWindow = {
        InsertText = function(text)
            inserted = tostring(text)
        end,
    }
    local function lastPrint()
        return printed[#printed]
    end
    local mainOnly = { sampleSlots[1] }
    local fields = {
        uid = 55,
        name = "MainOnly",
        icon = 1,
        slots = mainOnly,
    }
    RL._lastShareKey = "keep"
    eq(RL.ShareFields(fields), false, "link in chat refuses a main-only recipe")
    eq(inserted, nil, "link in chat inserts nothing")
    eq(RL._lastShareKey, "keep", "refused link does not arm /stp link")
    eq(lastPrint(), "link.share_need_both", "link in chat explains the missing container")

    printed = {}
    eq(RL.CopyFields(fields), false, "copy string refuses a main-only recipe")
    eq(inserted, nil, "copy string inserts nothing")
    eq(lastPrint(), "link.share_need_both", "copy string explains the missing container")

    local containerOnly = {
        uid = 55,
        name = "Vial",
        icon = 1,
        slots = { sampleSlots[2] },
    }
    printed = {}
    eq(RL.ShareFields(containerOnly), false, "link in chat refuses a container-only recipe")
    eq(lastPrint(), "link.share_need_both", "container-only uses the same message")

    local rk = recipeKey(mainOnly)
    recipes[rk] = { recipeSpecKey = rk, slots = mainOnly }
    potions["uid:55"] = {
        name = "MainOnly",
        iconNum = 1,
        recipeKeys = { rk },
        activeRecipeKey = rk,
    }
    printed = {}
    inserted = nil
    eq(RL.ShareWatchKey("uid:55|rk:" .. rk), false, "/stp link refuses a saved main-only recipe")
    eq(inserted, nil, "/stp link inserts nothing")
    eq(lastPrint(), "link.share_need_both", "/stp link explains the missing container")

    RL._contextFields = fields
    printed = {}
    RL.OnContextLinkInChat()
    eq(inserted, nil, "menu Link in chat inserts nothing")
    eq(lastPrint(), "link.share_need_both", "menu Link in chat explains the missing container")
    RL._contextFields = fields
    printed = {}
    RL.OnContextCopyString()
    eq(inserted, nil, "menu Copy string inserts nothing")
    eq(lastPrint(), "link.share_need_both", "menu Copy string explains the missing container")

    local fullKey = recipeKey(sampleSlots)
    recipes[fullKey] = { recipeSpecKey = fullKey, slots = sampleSlots }
    printed = {}
    inserted = nil
    eq(RL.ShareWatchKey("uid:55|rk:" .. fullKey), true, "/stp link still shares a full recipe")
    check(type(inserted) == "string" and string.find(inserted, "~", 1, true) ~= nil, "full recipe link was inserted")
    eq(#printed, 0, "full recipe prints no refusal")
    eq(RL.CopyFields({
        uid = 55,
        name = "Full",
        icon = 1,
        slots = sampleSlots,
    }), true, "copy string still shares a full recipe")
    StockPiler.Debug = nil
end

testSlotRoundTrip()
testRoundTrip()
testEffectBonusRoundTrip()
testTruncatedKeepsSlots()
testLegacyRkThenSlots()
testLinkLabelFields()
testGrammarSuffixStrippedFromName()
testImportKnownSkips()
testImportAfterForget()
testImportAdds()
testImportNoSlots()
testRejects()
testPlantRejected()
testH2LeavesExistingUntouched()
testH2KnownRecipeNotRewritten()
testH3RejectsBadPayloads()
testKnownWithoutRk()
testMenuDoesNotArmLink()
testOpenOnlyAfterSuccess()
testHookLeavesLaterAddon()
testZeroBonusKept()
testChatCountsExistingText()
testChatKeepsMultiSlotLink()
testNeedsMainAndContainer()
local function testItemDetailsRoundTrip()
    local fields = {
        uid = 3012345,
        name = "Bitter Example",
        icon = 123,
        slots = sampleSlots,
    }
    local plain = RL.SerializePlain(fields)
    check(type(plain) == "string", "details serialize")
    check(string.find(plain, "d=", 1, true) ~= nil, "share carries item details")
    check(string.find(plain, "^", 1, true) == nil, "details payload has no caret")
    local parsed = RL.ParsePlain(plain)
    check(type(parsed) == "table" and type(parsed.details) == "table", "details parse")
    eq(parsed.details[3012345].name, "Bitter Example", "potion name carried")
    eq(parsed.details[3012345].icon, 123, "potion icon carried")
    eq(parsed.details[1001].name, "", "unknown slot name stays empty")
    local slotsEnc = RL.EncodeSlots(sampleSlots)
    eq(RL.ParsePlain("POTION;uid=3012345;d=3012345,123,Bad^n;slots=" .. slotsEnc), nil, "caret in details rejects the link")
    eq(RL.ParsePlain("POTION;uid=3012345;d=~~;slots=" .. slotsEnc), nil, "bad details reject the link")
    eq(RL.ParsePlain("POTION;uid=3012345;d=3012345,123,Name~~1001,1,Herb;slots=" .. slotsEnc), nil, "doubled detail separator rejects the link")
    local legacy = RL.ParsePlain("POTION;uid=3012345;n=Bitter Example;slots=" .. slotsEnc)
    check(type(legacy) == "table" and legacy.details == nil, "links without details still parse")
end

local function testPresentDoesNotImport()
    resetKnowledge()
    local shown = nil
    local showCalls = 0
    StockPiler.RecipeShare = {
        Show = function(fields)
            shown = fields
            showCalls = showCalls + 1
            return true
        end,
        ShowFromPlain = function(text)
            shown = text
            showCalls = showCalls + 1
            return true
        end,
    }
    local fields = {
        uid = 3012345,
        name = "Bitter Example",
        icon = 123,
        slots = sampleSlots,
    }
    eq(RL.PresentLinkedRecipe(fields), true, "present opens preview")
    eq(shown, fields, "present passes fields")
    eq(#registered, 0, "present does not import")
    local plain = RL.SerializePlain(fields)
    eq(RL.OpenApply(plain), true, "apply opens preview")
    eq(type(shown), "string", "apply passes the plain string")
    eq(#registered, 0, "apply does not import")
    EA_ChatWindow = { OnHyperLinkLButtonUp = function() end }
    RL._hyperlinkHooked = false
    RL._prevOnHyperLinkLButtonUp = nil
    RL.InstallHyperlinkHook()
    local beforeShows = showCalls
    EA_ChatWindow.OnHyperLinkLButtonUp("StockPiler:" .. plain, 0, 0, 0)
    eq(showCalls, beforeShows + 1, "chat click opens preview")
    eq(#registered, 0, "chat click does not import")
    StockPiler.RecipeShare = nil
    StockPiler.Ui = {
        ShowWindow = function() end,
    }
    eq(RL.OpenApply(plain), true, "apply without preview still imports")
    eq(#registered, 1, "fallback import registered one recipe")
    RL.UninstallHyperlinkHook()
end

testShareRequiresMainAndContainer()
testLegacyCaretAndBadSeparators()
testItemDetailsRoundTrip()
testPresentDoesNotImport()

if failures > 0 then
    io.stderr:write(string.format("%d/%d checks failed\n", failures, checks))
    os.exit(1)
end
print(string.format("recipe_link: %d checks passed", checks))
