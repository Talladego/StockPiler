----------------------------------------------------------------
-- MaterialSpec — stat fingerprint for apothecary / cultivation mats
----------------------------------------------------------------

StockPiler.MaterialSpec = StockPiler.MaterialSpec or {}

local MS = StockPiler.MaterialSpec

local function ToNarrow(text)
    return StockPiler.ToNarrow(text)
end

local function SignedBonus(val)
    val = tonumber(val) or 0
    if val > 32767 then
        return val - 65536
    end
    return val
end

local function CraftBonusRefs()
    if StockPiler.Inventory and StockPiler.Inventory.CraftBonus then
        return StockPiler.Inventory.CraftBonus
    end
    return {
        STABILITY = 1,
        POWER = 2,
        DURATION = 3,
        MULTIPLIER = 4,
        CRAFTING_FAMILY = 5,
        EFFECT = 6,
        TYPE = 8,
        CRAFTING_LEVEL = 9,
        GROW_TIME = 10,
        YIELD = 11,
        CRITICAL_CHANCE = 12,
        FAIL_CHANCE = 13,
        SPECIAL_CHANCE = 14,
        DESTROY_ON_FAIL = 15,
    }
end

local function ApothecarySkill()
    return (GameData and GameData.TradeSkills and GameData.TradeSkills.APOTHECARY) or 4
end

local function CultivationSkill()
    return (GameData and GameData.TradeSkills and GameData.TradeSkills.CULTIVATION) or 3
end

local function SlotTypeConstants()
    if GameData and GameData.CraftingItemType then
        return GameData.CraftingItemType
    end
    return {
        STABILIZER = 1,
        MAIN_INGREDIENT = 2,
        EXTENDER = 3,
        MULTIPLIER = 4,
        CONTAINER = 5,
        CONTAINER_DYE = 6,
        CONTAINER_ESSENCE = 7,
        GOLDWEED = 10,
        STIMULANT = 18,
    }
end

local function ParseBonuses(itemData)
    local bonuses = {}
    if type(itemData) ~= "table" or type(itemData.craftingBonus) ~= "table" then
        return bonuses
    end
    for _, bonus in ipairs(itemData.craftingBonus) do
        if type(bonus) == "table" then
            local ref = tonumber(bonus.bonusReference) or 0
            if ref > 0 then
                if bonuses[ref] == nil then
                    bonuses[ref] = {}
                end
                bonuses[ref][#bonuses[ref] + 1] = SignedBonus(bonus.bonusValue)
            end
        end
    end
    return bonuses
end

local function FirstBonus(bonuses, ref)
    if type(bonuses) ~= "table" or type(bonuses[ref]) ~= "table" then
        return nil
    end
    return bonuses[ref][1]
end

local function RoleFromSlotType(slotType)
    slotType = tonumber(slotType) or 0
    local cit = SlotTypeConstants()
    if slotType == cit.CONTAINER or slotType == cit.CONTAINER_DYE then
        return "container"
    end
    if slotType == cit.MAIN_INGREDIENT then
        return "main"
    end
    if slotType == cit.STABILIZER or slotType == cit.GOLDWEED then
        return "stabilizer"
    end
    if slotType == cit.EXTENDER then
        return "extender"
    end
    if slotType == cit.MULTIPLIER then
        return "multiplier"
    end
    if slotType == cit.STIMULANT then
        return "stimulant"
    end
    return "ingredient"
end

local function RoleFromItemData(itemData, roleHint)
    if roleHint and roleHint ~= "" then
        return roleHint
    end
    local bonuses = ParseBonuses(itemData)
    local B = CraftBonusRefs()
    local slotType = FirstBonus(bonuses, B.TYPE) or 0
    return RoleFromSlotType(slotType)
end

-- Built-in apothecary effect id → StockPiler key (and CVT-compatible aliases).
local EFFECT_ID_TO_KEY = {
    [1] = "heal",
    [2] = "hot",
    [3] = "ap",
    [4] = "str",
    [5] = "int",
    [6] = "wp",
    [7] = "tou",
    [8] = "bs",
    [9] = "absorb",
    [10] = "rcorp",
    [11] = "rele",
    [12] = "rspi",
    [13] = "armor",
    [14] = "shdmg",
    [15] = "dmg",
    [16] = "dmgaoe",
    [17] = "dmgcone",
    [18] = "snare",
    [21] = "hytoucrit",
    [22] = "hystrmelee",
    [23] = "hywillheal",
    [24] = "hystrheal",
    [25] = "hyintmcrit",
    [26] = "hyaccrcrit",
    [27] = "hywoumelee",
    [28] = "hywoucrit",
    [29] = "hywoumcrit",
    [30] = "hywourcrit",
    [31] = "hywouheal",
    [32] = "hywoustr",
    [33] = "hyresist",
    [34] = "hywouarmpen",
    [35] = "hywouinit",
    [36] = "hytounocrit",
    [37] = "hyhpregencritdmg",
    [38] = "hywsarmpen",
    [41] = "trapoth",
    [42] = "trcult",
    [43] = "trsalv",
    [44] = "trtal",
    [45] = "rez",
    [46] = "morale",
    [1101] = "autoheal",
    [1102] = "freecast",
    [1103] = "autoheal",
    [1104] = "freecast",
    [1105] = "autoheal",
    [1106] = "freecast",
    [1107] = "autoheal",
    [1108] = "freecast",
    [1109] = "pet",
    [1110] = "movespeed",
}

-- Reverse lookup: StockPiler keys + legacy CVT names → effect id.
local EFFECT_KEY_TO_ID = {
    heal = 1,
    regen = 2,
    hot = 2,
    ap = 3,
    str = 4,
    int = 5,
    wil = 6,
    wp = 6,
    tou = 7,
    rskill = 8,
    bs = 8,
    shabs = 9,
    absorb = 9,
    rcorp = 10,
    rele = 11,
    rspi = 12,
    arm = 13,
    armor = 13,
    shdmg = 14,
    dmg = 15,
    dmgaoe = 16,
    dmgcone = 17,
    snare = 18,
    hytoucrit = 21,
    hystrmelee = 22,
    hywillheal = 23,
    hystrheal = 24,
    hyintmcrit = 25,
    hyaccrcrit = 26,
    hywoumelee = 27,
    hywoucrit = 28,
    hywoumcrit = 29,
    hywourcrit = 30,
    hywouheal = 31,
    hywoustr = 32,
    hyresist = 33,
    hywouarmpen = 34,
    hywouinit = 35,
    hytounocrit = 36,
    hyhpregencritdmg = 37,
    hywsarmpen = 38,
    trapoth = 41,
    trcult = 42,
    trsalv = 43,
    trtal = 44,
    rez = 45,
    morale = 46,
    autoheal = 1101,
    freecast = 1102,
    pet = 1109,
    movespeed = 1110,
}

local EFFECT_ID_TO_NAME = {
    heal = L"Healing",
    regen = L"Restoration",
    hot = L"Restoration",
    ap = L"Energy",
    str = L"Strength",
    int = L"Intelligence",
    wil = L"Willpower",
    wp = L"Willpower",
    tou = L"Toughness",
    rskill = L"Ballistic Skill",
    bs = L"Ballistic Skill",
    shabs = L"Absorb Shield",
    absorb = L"Absorb Shield",
    arm = L"Armor",
    armor = L"Armor",
    rcorp = L"Corporeal Resist",
    rele = L"Elemental Resist",
    rspi = L"Spirit Resist",
    shdmg = L"Thorn Shield",
    dmg = L"Molotov",
    dmgaoe = L"Napalm",
    dmgcone = L"Flaming Breath",
    snare = L"Snare",
    hytoucrit = L"Toughness+Melee Crit",
    hystrmelee = L"Strength+Melee",
    hywillheal = L"Willpower+Healing",
    hystrheal = L"Strength+Healing",
    hyintmcrit = L"Intelligence+Magic Crit",
    hyaccrcrit = L"Ballistics+Ranged Crit",
    hywoumelee = L"Wounds+Melee",
    hywoucrit = L"Wounds+Melee Crit",
    hywoumcrit = L"Wounds+Magic Crit",
    hywourcrit = L"Wounds+Ranged Crit",
    hywouheal = L"Wounds+Healing",
    hywoustr = L"Wounds+Strength",
    hyresist = L"All resists",
    hywouarmpen = L"Wounds+Reduced armor pen.",
    hywouinit = L"Wounds+Initiative",
    hytounocrit = L"Toughness+Reduced chance to be Crit",
    hyhpregencritdmg = L"Healthregen+Reduced Crit Dmg",
    hywsarmpen = L"Weapon Skill+Reduced armor pen.",
    trapoth = L"Apothecary Skill",
    trcult = L"Cultivation Skill",
    trsalv = L"Magical Salvaging Skill",
    trtal = L"Talisman Making Skill",
    rez = L"Resurrection",
    morale = L"Morale Gain",
    autoheal = L"Reactive Heal",
    freecast = L"Free Cast Chance",
    pet = L"Summon Pet",
    movespeed = L"Move Speed",
}

local DESC_EFFECT_PATTERNS = {
    { "intelligence", "int" },
    { "strength", "str" },
    { "willpower", "wil" },
    { "toughness", "tou" },
    { "ballistic skill", "rskill" },
    { "ballistic", "rskill" },
    { "healing", "heal" },
    { "restoration", "regen" },
    { "regenerat", "regen" },
    -- AP / invigoration mains often omit EFFECT in craftingBonus; infer from text.
    { "action point", "ap" },
    { "invigor", "ap" },
    { "energy", "ap" },
    { "armor", "arm" },
    { "absorb", "shabs" },
    { "barrier", "shabs" },
    { "flame breath", "dmgcone" },
}

local function EffectIdFromKey(key)
    if type(key) ~= "string" or key == "" then
        return nil
    end
    return EFFECT_KEY_TO_ID[key]
end

function MS.EffectIdFromKey(key)
    return EffectIdFromKey(key)
end

--- Stamp a main-ingredient effect fingerprint onto an incomplete (or fx-less) spec.
function MS.ApplyMainEffectId(spec, effectId)
    effectId = tonumber(effectId) or 0
    if type(spec) ~= "table" or spec.role ~= "main" or effectId <= 0 then
        return false
    end
    if spec.incomplete ~= true
        and tonumber(spec.effectId)
        and tonumber(spec.effectId) > 0
        and tonumber(spec.effectId) == effectId
    then
        return false
    end
    spec.effectId = effectId
    spec.incomplete = false
    if type(spec.bonuses) ~= "table" then
        spec.bonuses = {}
    end
    spec.bonuses[CraftBonusRefs().EFFECT] = effectId
    return true
end

local function EffectIdFromDescription(description)
    local desc = string.lower(ToNarrow(description))
    if desc == "" then
        return nil
    end
    for i = 1, #DESC_EFFECT_PATTERNS do
        local needle, effectKey = DESC_EFFECT_PATTERNS[i][1], DESC_EFFECT_PATTERNS[i][2]
        if string.find(desc, needle, 1, true) then
            return EffectIdFromKey(effectKey)
        end
    end
    return nil
end

local function ResolveItemDataForUid(uid)
    uid = tonumber(uid) or 0
    if uid <= 0 then
        return nil
    end
    if StockPiler.Inventory then
        local _, sample = StockPiler.Inventory.CountByUniqueId(uid)
        if type(sample) == "table" then
            return sample
        end
    end
    if StockPiler.Items and StockPiler.Items.AsItemData then
        local cached = StockPiler.Items.AsItemData(uid)
        if type(cached) == "table" then
            return cached
        end
    end
    local s = StockPiler.Settings
    if type(s) == "table" and type(s.matDataCache) == "table" then
        local uidKey = "uid:" .. tostring(uid)
        local cached = s.matDataCache[uidKey]
        if type(cached) == "table" then
            if type(cached.itemData) == "table" then
                return cached.itemData
            end
            if cached.uniqueID ~= nil then
                return cached
            end
        end
        for _, entry in pairs(s.matDataCache) do
            if type(entry) == "table" then
                local data = entry.itemData or entry
                if type(data) == "table" and tonumber(data.uniqueID) == uid then
                    return data
                end
            end
        end
    end
    if type(GetDatabaseItemData) == "function" then
        local ok, data = StockPiler.TryCallQuiet("GetDatabaseItemData", GetDatabaseItemData, uid)
        if ok and type(data) == "table" then
            return data
        end
    end
    return nil
end

local function ResolveMainEffectId(itemData, bonuses)
    local B = CraftBonusRefs()
    local effectId = FirstBonus(bonuses, B.EFFECT)
    if effectId and effectId > 0 then
        return effectId
    end
    if type(CraftItemInfo) == "table" and type(CraftItemInfo.GetItemBonuses) == "function" and type(itemData) == "table" then
        local ok, vData = StockPiler.TryCallQuiet("CraftItemInfo.GetItemBonuses", CraftItemInfo.GetItemBonuses, itemData)
        if ok and type(vData) == "table" and type(vData[B.EFFECT]) == "table" then
            effectId = tonumber(vData[B.EFFECT][1]) or 0
            if effectId > 0 then
                return effectId
            end
        end
    end
    if type(itemData) == "table" then
        effectId = EffectIdFromDescription(itemData.description)
        if effectId then
            return effectId
        end
    end
    return nil
end

function MS.EffectKeyFromEffectId(effectId)
    effectId = tonumber(effectId) or 0
    if effectId <= 0 then
        return nil
    end
    return EFFECT_ID_TO_KEY[effectId]
end

--- Parse once per snapshot item + role. Matches used to call FromItemData
--- on every bag item for every recipe spec (~1s BuildPlan after harvest).
function MS.FromItemDataCached(itemData, roleHint)
    if type(itemData) ~= "table" then
        return nil
    end
    local inv = StockPiler.Inventory
    if type(inv) ~= "table" then
        return MS.FromItemData(itemData, roleHint)
    end
    local cache = inv._specParseCache
    if type(cache) ~= "table" then
        cache = {}
        inv._specParseCache = cache
    end
    local role = roleHint or ""
    local byRole = cache[itemData]
    if type(byRole) ~= "table" then
        byRole = {}
        cache[itemData] = byRole
    end
    local hit = byRole[role]
    if hit == false then
        return nil
    end
    if type(hit) == "table" then
        return hit
    end
    local spec = MS.FromItemData(itemData, roleHint)
    if type(spec) == "table" then
        byRole[role] = spec
        return spec
    end
    byRole[role] = false
    return nil
end

function MS.FromItemData(itemData, roleHint)
    if type(itemData) ~= "table" then
        return nil
    end
    local bonuses = ParseBonuses(itemData)
    local B = CraftBonusRefs()
    local tradeSkill = FirstBonus(bonuses, B.CRAFTING_FAMILY)
    local slotType = FirstBonus(bonuses, B.TYPE) or 0
    local skillLevel = FirstBonus(bonuses, B.CRAFTING_LEVEL)
    if skillLevel == nil or skillLevel <= 0 then
        skillLevel = tonumber(itemData.craftingSkillRequirement) or 0
    end
    local cultType = tonumber(itemData.cultivationType) or 0
    if cultType ~= 0 then
        tradeSkill = CultivationSkill()
    end
    local role = RoleFromItemData(itemData, roleHint)
    local effectId = nil
    if role == "main" then
        effectId = ResolveMainEffectId(itemData, bonuses)
    else
        effectId = FirstBonus(bonuses, B.EFFECT)
    end
    -- Keep DESTROY_ON_FAIL (15) on the mat profile for inspection (e.g. Fabricated
    -- vials). Recipe fingerprints omit it in MS.Key — containers Match by slotType.
    local specBonuses = {}
    for ref = 1, 15 do
        if bonuses[ref] and ref ~= B.CRAFTING_FAMILY and ref ~= B.TYPE and ref ~= B.EFFECT then
            specBonuses[ref] = bonuses[ref][1]
        end
    end
    if effectId ~= nil and effectId > 0 then
        specBonuses[B.EFFECT] = effectId
    end
    local incomplete = false
    if role == "main" and (effectId == nil or effectId <= 0) then
        incomplete = true
    end
    return {
        tradeSkill = tradeSkill or 0,
        slotType = slotType,
        skillLevel = skillLevel or 0,
        cultivationType = cultType,
        effectId = effectId,
        bonuses = specBonuses,
        role = role,
        incomplete = incomplete,
    }
end

function MS.Copy(spec)
    if type(spec) ~= "table" then
        return nil
    end
    local bonuses = {}
    if type(spec.bonuses) == "table" then
        for k, v in pairs(spec.bonuses) do
            bonuses[k] = v
        end
    end
    return {
        tradeSkill = spec.tradeSkill or 0,
        slotType = spec.slotType or 0,
        skillLevel = spec.skillLevel or 0,
        cultivationType = spec.cultivationType or 0,
        effectId = spec.effectId,
        bonuses = bonuses,
        role = spec.role or "ingredient",
        incomplete = spec.incomplete == true,
    }
end

local function BonusMatch(a, b, ref)
    local va = type(a) == "table" and a[ref] or nil
    local vb = type(b) == "table" and b[ref] or nil
    if va == nil and vb == nil then
        return true
    end
    if va == nil or vb == nil then
        return false
    end
    return tonumber(va) == tonumber(vb)
end

local function IsMaterialSpec(t)
    return type(t) == "table"
        and type(t.role) == "string"
        and type(t.bonuses) == "table"
        and t.craftingBonus == nil
        and t.uniqueID == nil
end

function MS.Matches(itemData, spec)
    if type(itemData) ~= "table" or type(spec) ~= "table" then
        return false
    end
    if spec.incomplete == true then
        return false
    end
    -- Callers sometimes pass an already-built spec. FromItemData on that
    -- table has no craftingBonus, so it parses empty and never matches.
    local other = itemData
    if not IsMaterialSpec(itemData) then
        -- Parse once per item (no role hint). Using spec.role here missed the
        -- snapshot cache and re-ran FromItemData / GetItemBonuses per spec.
        other = MS.FromItemDataCached(itemData, nil)
    end
    if other == nil or other.incomplete == true then
        return false
    end
    local role = spec.role or other.role or "ingredient"
    if tonumber(other.tradeSkill) ~= tonumber(spec.tradeSkill) then
        return false
    end
    -- Seeds/spores share bonus fingerprints with plants; apo recipes are ct:0.
    if (tonumber(other.cultivationType) or 0) ~= (tonumber(spec.cultivationType) or 0) then
        return false
    end
    if tonumber(other.skillLevel) ~= tonumber(spec.skillLevel) then
        return false
    end
    if role == "main" then
        if tonumber(other.slotType) ~= tonumber(spec.slotType) then
            return false
        end
        return tonumber(other.effectId) == tonumber(spec.effectId)
    end
    if role == "container" then
        return tonumber(other.slotType) == tonumber(spec.slotType)
    end
    if role == "stabilizer" or role == "goldweed" then
        local B = CraftBonusRefs()
        if tonumber(other.slotType) ~= tonumber(spec.slotType) then
            if not (RoleFromSlotType(other.slotType) == "stabilizer"
                and RoleFromSlotType(spec.slotType) == "stabilizer")
            then
                return false
            end
        end
        if not BonusMatch(other.bonuses, spec.bonuses, B.STABILITY) then
            return false
        end
        if not BonusMatch(other.bonuses, spec.bonuses, B.MULTIPLIER) then
            return false
        end
        return true
    end
    if role == "extender" or role == "multiplier" or role == "stimulant" then
        if tonumber(other.slotType) ~= tonumber(spec.slotType) then
            return false
        end
        local B = CraftBonusRefs()
        if role == "extender" and not BonusMatch(other.bonuses, spec.bonuses, B.DURATION) then
            return false
        end
        if role == "multiplier" and not BonusMatch(other.bonuses, spec.bonuses, B.MULTIPLIER) then
            return false
        end
        return true
    end
    if tonumber(other.slotType) ~= tonumber(spec.slotType) then
        return false
    end
    return true
end

function MS.Key(spec)
    if type(spec) ~= "table" then
        return ""
    end
    local parts = {
        "ts:" .. tostring(spec.tradeSkill or 0),
        "st:" .. tostring(spec.slotType or 0),
        "lv:" .. tostring(spec.skillLevel or 0),
        "ct:" .. tostring(spec.cultivationType or 0),
        "role:" .. tostring(spec.role or ""),
    }
    if spec.effectId ~= nil then
        parts[#parts + 1] = "fx:" .. tostring(spec.effectId)
    end
    -- Omit DESTROY_ON_FAIL from recipe identity; still stored on items/specs.
    if type(spec.bonuses) == "table" then
        local B = CraftBonusRefs()
        local destroyRef = B.DESTROY_ON_FAIL or 15
        local refs = {}
        for ref, val in pairs(spec.bonuses) do
            local nref = tonumber(ref) or 0
            if nref ~= destroyRef then
                refs[#refs + 1] = tostring(ref) .. "=" .. tostring(val)
            end
        end
        table.sort(refs)
        if #refs > 0 then
            parts[#parts + 1] = "b:" .. table.concat(refs, ",")
        end
    end
    return table.concat(parts, "|")
end

function MS.Stability(spec)
    if type(spec) ~= "table" or type(spec.bonuses) ~= "table" then
        return 0
    end
    local B = CraftBonusRefs()
    return tonumber(spec.bonuses[B.STABILITY]) or 0
end

function MS.IsPurchasable(spec)
    if type(spec) ~= "table" then
        return false
    end
    local role = spec.role or ""
    return role == "container"
end

function MS.IsGrowable(spec)
    if type(spec) ~= "table" then
        return false
    end
    if StockPiler.SeedMap and StockPiler.SeedMap.IsGrowableSpec then
        return StockPiler.SeedMap.IsGrowableSpec(spec) == true
    end
    local role = spec.role or ""
    if role == "container" then
        return false
    end
    return role == "main" or role == "stabilizer" or role == "goldweed"
        or role == "extender" or role == "multiplier" or role == "stimulant"
end

local ROLE_ABBR = {
    container = "Container",
    main = "Main",
    stabilizer = "Stabilizer",
    goldweed = "Goldweed",
    extender = "Extender",
    multiplier = "Multiplier",
    stimulant = "Stimulant",
}

function MS.RoleTitle(role)
    return ROLE_ABBR[role or ""] or role or "Material"
end

function MS.ShortLabel(spec)
    if type(spec) ~= "table" then
        return L"?"
    end
    local role = spec.role or "mat"
    local B = CraftBonusRefs()
    local lv = tonumber(spec.skillLevel) or 0
    if role == "main" and spec.effectId then
        local ek = MS.EffectKeyFromEffectId(spec.effectId)
        if ek then
            return towstring("M:" .. ek)
        end
        return towstring("M:fx" .. tostring(spec.effectId))
    end
    if role == "stabilizer" or role == "goldweed" then
        local stab = MS.Stability(spec)
        local tag = "S:" .. (stab >= 0 and "+" or "") .. tostring(stab)
        local mult = spec.bonuses and spec.bonuses[B.MULTIPLIER]
        if mult and tonumber(mult) ~= 0 then
            tag = tag .. "+M" .. tostring(mult)
        end
        return towstring(tag)
    end
    if role == "extender" then
        local dur = spec.bonuses and spec.bonuses[B.DURATION]
        if dur then
            return towstring("E:+" .. tostring(dur))
        end
    end
    if role == "multiplier" then
        local mult = spec.bonuses and spec.bonuses[B.MULTIPLIER]
        if mult then
            return towstring("X:x" .. tostring(mult))
        end
    end
    if role == "container" and lv > 0 then
        return towstring("C:L" .. tostring(lv))
    end
    if lv > 0 then
        return towstring(string.sub(role, 1, 1):upper() .. ":L" .. tostring(lv))
    end
    return towstring(string.sub(role, 1, 1):upper())
end

function MS.DescribeLines(spec, perCraft)
    local lines = {}
    if type(spec) ~= "table" then
        return lines
    end
    perCraft = tonumber(perCraft) or 1
    local title = ToNarrow(MS.Label(spec))
    if perCraft > 1 then
        title = title .. " x" .. tostring(perCraft)
    end
    lines[1] = towstring(title)
    if spec.incomplete == true then
        lines[#lines + 1] = L"Incomplete spec (missing effect fingerprint)"
    end
    local B = CraftBonusRefs()
    if spec.role == "main" and spec.effectId then
        lines[#lines + 1] = L"Effect id: " .. towstring(tostring(spec.effectId))
    end
    local stab = MS.Stability(spec)
    if stab ~= 0 then
        lines[#lines + 1] = L"Stability: " .. towstring((stab >= 0 and "+" or "") .. tostring(stab))
    end
    local mult = spec.bonuses and spec.bonuses[B.MULTIPLIER]
    if mult and mult ~= 0 then
        lines[#lines + 1] = L"Multiplier: x" .. towstring(tostring(mult))
    end
    local dur = spec.bonuses and spec.bonuses[B.DURATION]
    if dur and dur ~= 0 then
        lines[#lines + 1] = L"Duration: +" .. towstring(tostring(dur))
    end
    local lv = tonumber(spec.skillLevel) or 0
    if lv > 0 then
        lines[#lines + 1] = L"Skill: " .. towstring(tostring(lv))
    end
    return lines
end

local function EffectPhrase(key)
    if not key or key == "" then
        return nil
    end
    if EFFECT_ID_TO_NAME[key] then
        return EFFECT_ID_TO_NAME[key]
    end
    return towstring(key)
end

function MS.TradeSkillDisplayName(spec)
    local ts = type(spec) == "table" and tonumber(spec.tradeSkill) or 0
    if GameData and GameData.TradeSkills then
        local g = GameData.TradeSkills
        if ts == g.APOTHECARY then
            return L"Apothecary"
        end
        if ts == g.CULTIVATION then
            return L"Cultivation"
        end
        if ts == g.TALISMAN then
            return L"Talisman Making"
        end
    end
    if type(spec) == "table" and tonumber(spec.cultivationType) or 0 ~= 0 then
        return L"Cultivation"
    end
    return L"Apothecary"
end

function MS.EffectDisplayName(spec)
    if type(spec) ~= "table" then
        return nil
    end
    local effectId = tonumber(spec.effectId) or 0
    if effectId <= 0 then
        return nil
    end
    local ek = MS.EffectKeyFromEffectId(effectId)
    if ek then
        local phrase = EffectPhrase(ek)
        if phrase and phrase ~= L"" then
            return phrase
        end
    end
    return L"Effect id: " .. towstring(tostring(effectId))
end

function MS.FormatBonusLine(ref, value)
    ref = tonumber(ref) or 0
    value = tonumber(value) or 0
    if ref <= 0 or value == 0 then
        return nil
    end
    local B = CraftBonusRefs()
    local destroyRef = B.DESTROY_ON_FAIL or 15
    if ref == destroyRef then
        return nil
    end
    local text
    if type(CraftItemInfo) == "table" and type(CraftItemInfo.FormatBonus) == "function" then
        text = CraftItemInfo.FormatBonus(ref, value)
    end
    if text == nil or text == L"" then
        local name
        if type(CraftItemInfo) == "table" and type(CraftItemInfo.GetBonusName) == "function" then
            name = CraftItemInfo.GetBonusName(ref)
        end
        if name == nil or name == L"" then
            local fallback = {
                [1] = L"Stability",
                [2] = L"Power",
                [3] = L"Duration",
                [4] = L"Multiplier",
                [12] = L"Super-Critical Chance",
                [13] = L"Fail Chance",
                [14] = L"Super-Critical Chance",
            }
            name = fallback[ref] or L"Bonus"
        end
        local percentRefs = { [12] = true, [13] = true, [14] = true }
        if percentRefs[ref] then
            if value < 0 then
                text = towstring(tostring(value)) .. L"% " .. name
            else
                text = L"+" .. towstring(tostring(value)) .. L"% " .. name
            end
        elseif value < 0 then
            text = towstring(tostring(value)) .. L" " .. name
        else
            text = L"+" .. towstring(tostring(value)) .. L" " .. name
        end
    end
    local kind = "positive"
    if value < 0 then
        kind = "negative"
    elseif ref == 3 or ref == 4 or ref == 12 or ref == 14 then
        kind = "bonus"
    end
    return { text = text, kind = kind }
end

function MS.IngredientHeaderText(spec)
    if type(spec) ~= "table" then
        return L"?"
    end
    local role = spec.role or "mat"
    local lv = tonumber(spec.skillLevel) or 0
    return towstring(tostring(lv)) .. L" " .. MS.TradeSkillDisplayName(spec)
        .. L" - " .. towstring(MS.RoleTitle(role))
end

function MS.DescribeTooltipRows(spec, _perCraft)
    local rows = {}
    if type(spec) ~= "table" then
        return rows
    end

    local role = spec.role or "mat"
    rows[#rows + 1] = {
        text = MS.IngredientHeaderText(spec),
        kind = "ingredient",
        role = role,
    }

    if spec.incomplete == true then
        rows[#rows + 1] = { text = L"Incomplete spec (missing effect fingerprint)", kind = "warning" }
    end

    if role == "main" then
        local effectName = MS.EffectDisplayName(spec)
        if effectName and effectName ~= L"" then
            rows[#rows + 1] = { text = effectName, kind = "effect", role = role }
        end
    end

    local B = CraftBonusRefs()
    local skip = {
        [B.CRAFTING_FAMILY] = true,
        [B.EFFECT] = true,
        [B.TYPE] = true,
        [B.CRAFTING_LEVEL] = true,
        [B.GROW_TIME] = true,
        [B.DESTROY_ON_FAIL] = true,
    }
    local order = {
        B.STABILITY,
        B.POWER,
        B.MULTIPLIER,
        B.DURATION,
        B.CRITICAL_CHANCE,
        B.SPECIAL_CHANCE,
        B.FAIL_CHANCE,
        B.YIELD,
    }

    for i = 1, #order do
        local ref = order[i]
        if not skip[ref] then
            local val = spec.bonuses and spec.bonuses[ref]
            if val and tonumber(val) ~= 0 then
                local line = MS.FormatBonusLine(ref, val)
                if line then
                    rows[#rows + 1] = line
                end
            end
        end
    end

    return rows
end

local function CultivationTypeName(cultType)
    cultType = tonumber(cultType) or 0
    local types = GameData and GameData.CultivationTypes
    local spore = (types and types.SPORE) or 5
    local seed = (types and types.SEED) or 1
    if cultType == spore then
        return L"Spore"
    end
    if cultType == seed or cultType == 0 then
        return L"Seed"
    end
    if cultType == ((types and types.SOIL) or 2) then
        return L"Soil"
    end
    if cultType == ((types and types.WATERCAN) or 3) then
        return L"Watering Can"
    end
    if cultType == ((types and types.NUTRIENT) or 4) then
        return L"Nutrient"
    end
    return L"Seed"
end

local function ResolveSeedItem(seed)
    if type(seed) ~= "table" then
        return nil
    end
    if (tonumber(seed.cultivationType) or 0) ~= 0 and type(seed.craftingBonus) == "table" then
        return seed
    end
    local uid = tonumber(seed.uniqueID) or 0
    if uid <= 0 then
        return nil
    end
    if StockPiler.Inventory and StockPiler.Inventory.CountByUniqueId then
        local _, sample = StockPiler.Inventory.CountByUniqueId(uid)
        if type(sample) == "table" then
            return sample
        end
    end
    if type(GetDatabaseItemData) == "function" then
        local ok, data = StockPiler.TryCallQuiet("GetDatabaseItemData", GetDatabaseItemData, uid)
        if ok and type(data) == "table" then
            return data
        end
    end
    return nil
end

function MS.GrowsPhrase(spec)
    if type(spec) ~= "table" then
        return nil
    end
    local role = spec.role or ""
    if role == "main" then
        local effectName = MS.EffectDisplayName(spec)
        if effectName and effectName ~= L"" then
            return L"Grows " .. effectName
        end
        return L"Grows Main"
    end
    if role ~= "" and role ~= "mat" and role ~= "ingredient" then
        return L"Grows " .. towstring(MS.RoleTitle(role))
    end
    return nil
end

local function NeedBonusParts(spec)
    local parts = {}
    if type(spec) ~= "table" then
        return parts
    end
    local B = CraftBonusRefs()
    local skip = {
        [B.CRAFTING_FAMILY] = true,
        [B.EFFECT] = true,
        [B.TYPE] = true,
        [B.CRAFTING_LEVEL] = true,
        [B.GROW_TIME] = true,
        [B.DESTROY_ON_FAIL] = true,
        [B.SLOTS] = true,
    }
    local order = {
        B.STABILITY,
        B.POWER,
        B.MULTIPLIER,
        B.DURATION,
        B.CRITICAL_CHANCE,
        B.SPECIAL_CHANCE,
        B.FAIL_CHANCE,
        B.YIELD,
    }
    for i = 1, #order do
        local ref = order[i]
        if ref and not skip[ref] then
            local val = spec.bonuses and spec.bonuses[ref]
            if val and tonumber(val) ~= 0 then
                local line = MS.FormatBonusLine(ref, val)
                if line and line.text and line.text ~= L"" then
                    parts[#parts + 1] = line.text
                end
            end
        end
    end
    return parts
end

local function JoinNeedParts(parts)
    if #parts == 0 then
        return L""
    end
    local text = parts[1]
    for i = 2, #parts do
        text = text .. L", " .. parts[i]
    end
    return text
end

--- Recipe-style slot line, not a bag item name.
--- Flask: "150 Apothecary - Container (+2 Stability, +1 Power)"
--- Main:  "175 Apothecary - Main (Armor, -19 Stability, +15 Power)"
--- Seed:  "200 Cultivating - Seed (Grows Healing, +20% Fail Chance)"
function MS.NeedLabel(spec, context)
    if type(spec) ~= "table" then
        return L"material"
    end
    context = type(context) == "table" and context or {}
    local asSeed = context.asSeed == true or type(context.seed) == "table"
    local plantSpec = spec
    local lineSpec = spec
    local cultType = tonumber(spec.cultivationType) or 0
    if asSeed then
        local seedItem = ResolveSeedItem(context.seed)
        if type(seedItem) == "table" then
            local seedSpec = MS.FromItemData(seedItem)
            if type(seedSpec) == "table" then
                lineSpec = seedSpec
                cultType = tonumber(seedSpec.cultivationType) or tonumber(seedItem.cultivationType) or cultType
            else
                cultType = tonumber(seedItem.cultivationType) or cultType
            end
        elseif (tonumber(context.cultType) or 0) > 0 then
            cultType = tonumber(context.cultType)
        end
        if cultType <= 0 then
            cultType = (GameData and GameData.CultivationTypes and GameData.CultivationTypes.SEED) or 1
        end
    end

    local lv = tonumber(lineSpec.skillLevel) or tonumber(plantSpec.skillLevel) or 0
    local trade = L"Apothecary"
    local slot = towstring(MS.RoleTitle(plantSpec.role or lineSpec.role or "mat"))
    if asSeed then
        trade = L"Cultivating"
        slot = CultivationTypeName(cultType)
        if lv <= 0 then
            lv = tonumber(plantSpec.skillLevel) or 0
        end
    elseif (tonumber(lineSpec.cultivationType) or 0) ~= 0 then
        trade = L"Cultivating"
        slot = CultivationTypeName(lineSpec.cultivationType)
    else
        trade = MS.TradeSkillDisplayName(lineSpec)
        if lineSpec.role == "container" then
            local cit = SlotTypeConstants()
            local st = tonumber(lineSpec.slotType) or 0
            if st == (tonumber(cit.CONTAINER_ESSENCE) or 7) then
                slot = L"Essence Container"
            elseif st == (tonumber(cit.CONTAINER_DYE) or 6) then
                slot = L"Dye Container"
            else
                slot = L"Container"
            end
        end
    end

    local header = towstring(tostring(lv)) .. L" " .. trade .. L" - " .. slot
    local paren = {}
    if asSeed then
        local grows = MS.GrowsPhrase(plantSpec)
        if grows then
            paren[#paren + 1] = grows
        end
    elseif (plantSpec.role or "") == "main" then
        local effectName = MS.EffectDisplayName(plantSpec)
        if effectName and effectName ~= L"" then
            paren[#paren + 1] = effectName
        end
    end
    local bonusSpec = lineSpec
    if asSeed and type(lineSpec.bonuses) ~= "table" then
        bonusSpec = plantSpec
    end
    local bonusParts = NeedBonusParts(bonusSpec)
    for i = 1, #bonusParts do
        paren[#paren + 1] = bonusParts[i]
    end
    local extra = JoinNeedParts(paren)
    if extra ~= L"" then
        return header .. L" (" .. extra .. L")"
    end
    return header
end

function MS.Label(spec)
    if type(spec) ~= "table" then
        return L"?"
    end
    local role = spec.role or "mat"
    local lv = tonumber(spec.skillLevel) or 0
    local parts = {}
    if lv > 0 then
        parts[#parts + 1] = "L" .. tostring(lv)
    end
    parts[#parts + 1] = role
    if spec.role == "main" and spec.effectId then
        local ek = MS.EffectKeyFromEffectId(spec.effectId)
        if ek then
            parts[#parts + 1] = ek
        else
            parts[#parts + 1] = "fx" .. tostring(spec.effectId)
        end
    end
    local stab = MS.Stability(spec)
    if stab ~= 0 then
        parts[#parts + 1] = (stab >= 0 and "+" or "") .. tostring(stab) .. " stab"
    end
    local B = CraftBonusRefs()
    local mult = spec.bonuses and spec.bonuses[B.MULTIPLIER]
    if mult and mult ~= 0 then
        parts[#parts + 1] = "x" .. tostring(mult)
    end
    return towstring(table.concat(parts, " "))
end

function MS.SpecFromRoleAndItem(itemData, role, perCraft)
    local spec = MS.FromItemData(itemData, role)
    if spec == nil then
        return nil
    end
    return {
        role = role or spec.role,
        spec = spec,
        perCraft = tonumber(perCraft) or 1,
    }
end

--- Repair incomplete main specs.
--- opts.effectId / opts.effectKey: fallback when item bonuses/description lack EFFECT
--- (common for invigoration/AP mains; brew output / potion.effectKey is authoritative).
function MS.RepairMainSpec(spec, itemDataOrUid, opts)
    if type(spec) ~= "table" or spec.role ~= "main" then
        return false
    end
    if spec.incomplete ~= true and tonumber(spec.effectId) and tonumber(spec.effectId) > 0 then
        return false
    end
    opts = type(opts) == "table" and opts or nil
    local itemData = nil
    if type(itemDataOrUid) == "table" then
        itemData = itemDataOrUid
    else
        itemData = ResolveItemDataForUid(itemDataOrUid)
    end
    local refreshed = type(itemData) == "table" and MS.FromItemData(itemData, "main") or nil
    if refreshed == nil or refreshed.incomplete == true then
        local effectId = nil
        if type(itemData) == "table" then
            effectId = EffectIdFromDescription(itemData.description)
        end
        if (not effectId or effectId <= 0) and opts then
            effectId = tonumber(opts.effectId) or 0
            if effectId <= 0 and type(opts.effectKey) == "string" then
                effectId = EffectIdFromKey(opts.effectKey) or 0
            end
        end
        if not effectId or effectId <= 0 then
            return false
        end
        return MS.ApplyMainEffectId(spec, effectId)
    end
    spec.tradeSkill = refreshed.tradeSkill
    spec.slotType = refreshed.slotType
    spec.skillLevel = refreshed.skillLevel
    spec.cultivationType = refreshed.cultivationType
    spec.effectId = refreshed.effectId
    spec.bonuses = {}
    if type(refreshed.bonuses) == "table" then
        for k, v in pairs(refreshed.bonuses) do
            spec.bonuses[k] = v
        end
    end
    spec.incomplete = false
    return true
end
