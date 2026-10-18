----------------------------------------------------------------
-- StockPiler Knowledge/Classify - potion effect / level / rarity helpers
----------------------------------------------------------------

StockPiler = StockPiler or {}
StockPiler.Classify = StockPiler.Classify or {}
local Classify = StockPiler.Classify

-- Main-ingredient effects shared by potions and plants, plus plant-only roles.
-- Includes effects the game no longer uses.
Classify.EFFECT_KEYS = {
    "str", "int", "wp", "bs", "tou", "armor", "absorb", "heal", "hot", "ap",
    "rcorp", "rele", "rspi", "snare", "dmg", "dmgaoe", "dmgcone", "shdmg",
    "hytoucrit", "hystrmelee", "hywillheal", "hystrheal", "hyintmcrit",
    "hyaccrcrit", "hywoumelee", "hywoucrit", "hywoumcrit", "hywourcrit",
    "hywouheal", "hywoustr", "hyresist", "hywouarmpen", "hywouinit",
    "hytounocrit", "hyhpregencritdmg", "hywsarmpen", "hywsnocrit",
    "trapoth", "trcult", "trsalv", "trtal", "rez", "morale",
    "autoheal", "freecast", "pet", "movespeed",
}

-- Non-main plant roles. Plants filter only; potions do not have these effects.
Classify.PLANT_ROLE_KEYS = {
    "stabilizer", "extender", "multiplier", "stimulant",
}

local EFFECT_SHORT = {
    str = "Str",
    int = "Int",
    wp = "WP",
    bs = "BS",
    tou = "Tou",
    armor = "Armor",
    absorb = "Absorb",
    heal = "Heal",
    hot = "HoT",
    ap = "AP",
    snare = "Snare",
    dmg = "Napalm",
    dmgaoe = "Molotov",
    dmgcone = "Flame",
    shdmg = "ShDmg",
    trapoth = "Apo",
    trcult = "Cult",
    trsalv = "Salv",
    trtal = "Tal",
    rez = "Rez",
    morale = "Morale",
    autoheal = "AutoHeal",
    freecast = "FreeCast",
    pet = "Pet",
    movespeed = "Speed",
    rcorp = "Corp",
    rele = "Ele",
    rspi = "Spi",
    hytoucrit = "Tou+Crit",
    hystrmelee = "Str+Melee",
    hywillheal = "Will+Heal",
    hystrheal = "Str+Heal",
    hyintmcrit = "Int+MCrit",
    hyaccrcrit = "BS+RCrit",
    hywoumelee = "Wou+Melee",
    hywoucrit = "Wou+Crit",
    hywoumcrit = "Wou+MCrit",
    hywourcrit = "Wou+RCrit",
    hywouheal = "Wou+Heal",
    hywoustr = "Wou+Str",
    hyresist = "Resist",
    hywouarmpen = "Wou+APen",
    hywouinit = "Wou+Init",
    hytounocrit = "Tou-Crit",
    hyhpregencritdmg = "Regen+CritD",
    hywsarmpen = "WS+APen",
    hywsnocrit = "WS-Crit",
    stabilizer = "Stab",
    extender = "Ext",
    multiplier = "Mult",
    stimulant = "Stim",
}

-- Memoize short labels (finite key set).
local EFFECT_SHORT_WS = {}
local EFFECT_FULL_WS = {}

local function ToNarrow(value)
    return StockPiler.Util.ToNarrow(value)
end

local function T(key)
    if StockPiler.T then
        return StockPiler.T(key)
    end
    local short = EFFECT_SHORT[key]
    if short then
        return towstring(short)
    end
    return towstring(tostring(key or ""))
end

function Classify.EffectShortLabel(effectKey)
    effectKey = tostring(effectKey or "")
    if effectKey == "" then
        return L""
    end
    local cached = EFFECT_SHORT_WS[effectKey]
    if cached ~= nil then
        return cached
    end
    local labeled = nil
    local localeKey = "effect.short." .. effectKey
    if StockPiler.Locale and StockPiler.Locale.ResolveTemplate then
        local template = StockPiler.Locale.ResolveTemplate(localeKey)
        if type(template) == "wstring" then
            labeled = template
        end
    elseif StockPiler.T then
        local t = StockPiler.T(localeKey)
        local narrow = ToNarrow(t)
        if narrow ~= "" and narrow ~= localeKey and string.sub(narrow, 1, 1) ~= "[" then
            labeled = t
        end
    end
    if labeled == nil and EFFECT_SHORT[effectKey] then
        labeled = towstring(EFFECT_SHORT[effectKey])
    end
    if labeled == nil then
        labeled = towstring(string.upper(effectKey))
    end
    EFFECT_SHORT_WS[effectKey] = labeled
    return labeled
end

function Classify.EffectFullLabel(effectKey)
    effectKey = tostring(effectKey or "")
    if effectKey == "" then
        return L""
    end
    local cached = EFFECT_FULL_WS[effectKey]
    if cached ~= nil then
        return cached
    end
    local labeled = nil
    local localeKey = "effect.full." .. effectKey
    if StockPiler.Locale and StockPiler.Locale.ResolveTemplate then
        local template = StockPiler.Locale.ResolveTemplate(localeKey)
        if type(template) == "wstring" then
            labeled = template
        end
    elseif StockPiler.T then
        local t = StockPiler.T(localeKey)
        local narrow = ToNarrow(t)
        if narrow ~= "" and narrow ~= localeKey and string.sub(narrow, 1, 1) ~= "[" then
            labeled = t
        end
    end
    if labeled == nil then
        labeled = Classify.EffectShortLabel(effectKey)
    end
    EFFECT_FULL_WS[effectKey] = labeled
    return labeled
end

--- kind "potion" is main-ingredient effects. kind "plant" adds stabilizer and the other roles.
function Classify.EffectFilterKeys(kind)
    local keys = {}
    for i = 1, #Classify.EFFECT_KEYS do
        keys[#keys + 1] = Classify.EFFECT_KEYS[i]
    end
    if kind == "plant" then
        local roles = Classify.PLANT_ROLE_KEYS
        for i = 1, #roles do
            keys[#keys + 1] = roles[i]
        end
    end
    return keys
end

local function ClassifyFromDescription(description)
    if type(description) ~= "string" or description == "" then
        return nil
    end
    local descLower = string.lower(description)
    if string.find(descLower, "wounds", 1, true) then
        if string.find(descLower, "ranged", 1, true)
            and (string.find(descLower, "crit", 1, true) or string.find(descLower, "critical", 1, true))
        then
            return "hywourcrit"
        end
        if string.find(descLower, "magic", 1, true)
            and (string.find(descLower, "crit", 1, true) or string.find(descLower, "critical", 1, true))
        then
            return "hywoumcrit"
        end
        if (string.find(descLower, "melee", 1, true) or string.find(descLower, "weapon", 1, true))
            and (string.find(descLower, "crit", 1, true) or string.find(descLower, "critical", 1, true))
        then
            return "hywoucrit"
        end
        if string.find(descLower, "initiative", 1, true) then
            return "hywouinit"
        end
        if string.find(descLower, "heal", 1, true) then
            return "hywouheal"
        end
        if string.find(descLower, "strength", 1, true) then
            return "hywoustr"
        end
        if string.find(descLower, "armor pen", 1, true) or string.find(descLower, "armour pen", 1, true) then
            return "hywouarmpen"
        end
        if string.find(descLower, "melee", 1, true) then
            return "hywoumelee"
        end
    end
    -- Potion Use: ability text (same strings as stock tooltips).
    if string.find(descLower, "instantly restores", 1, true) then
        if string.find(descLower, "action point", 1, true) then
            return "ap"
        end
        if string.find(descLower, "health", 1, true) then
            return "heal"
        end
    end
    if string.find(descLower, "gradually restores", 1, true)
        or string.find(descLower, "heals for", 1, true)
    then
        return "hot"
    end
    if string.find(descLower, "absorbs", 1, true) or string.find(descLower, "magical barrier", 1, true) then
        return "absorb"
    end
    -- Glue bomb / snare (Use: "more slowly", ingredient "glue bomb potions").
    if string.find(descLower, "movement speed", 1, true)
        or string.find(descLower, "move speed", 1, true)
        or string.find(descLower, "run speed", 1, true)
    then
        return "movespeed"
    end
    if string.find(descLower, "more slowly", 1, true)
        or string.find(descLower, "glue bomb", 1, true)
        or string.find(descLower, "slows targets", 1, true)
        or string.find(descLower, "slow targets", 1, true)
        or string.find(descLower, "snare", 1, true)
    then
        return "snare"
    end
    -- Resist potions / plant text (before generic "increases" / "armor").
    if string.find(descLower, "spirit resistance", 1, true)
        or string.find(descLower, "spirit resist", 1, true)
    then
        return "rspi"
    end
    if string.find(descLower, "corporeal resistance", 1, true)
        or string.find(descLower, "corporeal resist", 1, true)
    then
        return "rcorp"
    end
    if string.find(descLower, "elemental resistance", 1, true)
        or string.find(descLower, "elemental resist", 1, true)
    then
        return "rele"
    end
    if string.find(descLower, "increases", 1, true)
        or string.find(descLower, "create", 1, true)
        or string.find(descLower, "used to", 1, true)
        or string.find(descLower, "grows into", 1, true)
    then
        -- Non-main plant / seed text before stat mains.
        if string.find(descLower, "stabiliz", 1, true) or string.find(descLower, "stability", 1, true) then
            return "stabilizer"
        end
        if string.find(descLower, "extend", 1, true) or string.find(descLower, "duration", 1, true) then
            return "extender"
        end
        if string.find(descLower, "number of", 1, true)
            or string.find(descLower, "concoction", 1, true)
            or string.find(descLower, "multiplier", 1, true)
        then
            return "multiplier"
        end
        -- Willpower before strength/"power": "willpower potions" contains "power potion".
        if string.find(descLower, "willpower", 1, true) then return "wp" end
        if string.find(descLower, "intelligence", 1, true) then return "int" end
        if string.find(descLower, "ballistic skill", 1, true) then return "bs" end
        if string.find(descLower, "strength", 1, true) then return "str" end
        if string.find(descLower, "power potion", 1, true) then return "str" end
        if string.find(descLower, "toughness", 1, true) then return "tou" end
        if string.find(descLower, "armor", 1, true) or string.find(descLower, "armour", 1, true) then
            return "armor"
        end
        if string.find(descLower, "molotov", 1, true) then return "dmgaoe" end
        if string.find(descLower, "napalm", 1, true) then return "dmg" end
        if string.find(descLower, "flame breath", 1, true) or string.find(descLower, "pyrewind", 1, true) then
            return "dmgcone"
        end
        if string.find(descLower, "shield damage", 1, true) then return "shdmg" end
        if string.find(descLower, "movement speed", 1, true)
            or string.find(descLower, "move speed", 1, true)
        then
            return "movespeed"
        end
        if string.find(descLower, "glue bomb", 1, true)
            or string.find(descLower, "slows", 1, true)
            or string.find(descLower, "snare", 1, true)
        then
            return "snare"
        end
    end
    return nil
end

local function ClassifyFromName(name)
    local n = string.lower(ToNarrow(name))
    if n == "" then
        return nil
    end
    if string.find(n, "liniment", 1, true) or string.find(n, "war:", 1, true) then
        if string.find(n, "hunger", 1, true) then return "hywoustr" end
        if string.find(n, "mercy", 1, true) then return "hywouheal" end
        if string.find(n, "blood", 1, true) then return "hywoucrit" end
        if string.find(n, "demise", 1, true) then return "hywoumelee" end
        if string.find(n, "genius", 1, true) then return "hywoumcrit" end
        if string.find(n, "fervor", 1, true) then return "hywourcrit" end
    end
    -- Do not map potion product names (Recovery / Elixir / Draught) - Effect comes
    -- from Use: ability or the recipe main's EFFECT id, not the finished name.
    if string.find(n, "brilliance", 1, true) then return "int" end
    if string.find(n, "discipline", 1, true) then return "wp" end
    if string.find(n, "securing", 1, true) then return "armor" end
    if string.find(n, "strangulation", 1, true) or string.find(n, "glue", 1, true) then
        return "snare"
    end
    if string.find(n, "pyrewind", 1, true) then return "dmgcone" end
    if string.find(n, "spirit screen", 1, true) or string.find(n, "spirit resist", 1, true) then
        return "rspi"
    end
    if string.find(n, "corporeal", 1, true) then return "rcorp" end
    if string.find(n, "elemental", 1, true) and string.find(n, "resist", 1, true) then
        return "rele"
    end
    return nil
end

--- ITEMBONUS_USE = 3. Stock tooltip Use: line = GetAbilityDesc(bonus.reference, iLevel).
local ITEMBONUS_USE = 3
if GameDefs and GameDefs.ITEMBONUS_USE then
    ITEMBONUS_USE = GameDefs.ITEMBONUS_USE
end

local function FirstUseAbilityId(itemData)
    if type(itemData) ~= "table" or type(itemData.bonus) ~= "table" then
        return 0
    end
    for _, bonus in ipairs(itemData.bonus) do
        if type(bonus) == "table" and tonumber(bonus.type) == ITEMBONUS_USE then
            local ref = tonumber(bonus.reference) or 0
            if ref > 0 then
                return ref
            end
        end
    end
    for _, bonus in pairs(itemData.bonus) do
        if type(bonus) == "table" and tonumber(bonus.type) == ITEMBONUS_USE then
            local ref = tonumber(bonus.reference) or 0
            if ref > 0 then
                return ref
            end
        end
    end
    return 0
end

local function AbilityTextForUseBonus(itemData)
    local abilityId = FirstUseAbilityId(itemData)
    if abilityId <= 0 or type(GetAbilityDesc) ~= "function" then
        return nil, abilityId
    end
    local iLevel = tonumber(itemData.iLevel) or tonumber(itemData.level) or 0
    local ok, text = pcall(GetAbilityDesc, abilityId, iLevel)
    if not ok then
        return nil, abilityId
    end
    local narrow = ToNarrow(text)
    if narrow == "" then
        return nil, abilityId
    end
    return narrow, abilityId
end

--- Prefer potion Use: ability text (tooltip SoT) over plain description/name.
function Classify.GetEffectKeyFromPotionUse(itemData)
    if type(itemData) ~= "table" then
        return nil
    end
    local abilityText = AbilityTextForUseBonus(itemData)
    if abilityText then
        return ClassifyFromDescription(abilityText)
    end
    return nil
end

--- Ability id for the potion Use: bonus (ITEMBONUS_USE), or 0.
function Classify.GetPotionUseAbilityId(itemData)
    return FirstUseAbilityId(itemData)
end

function Classify.GetEffectKey(itemData)
    if type(itemData) ~= "table" then
        return nil
    end
    -- Finished potions: Use bonus -> ability text (matches stock tooltip). Never name-first.
    local fromUse = Classify.GetEffectKeyFromPotionUse(itemData)
    if fromUse then
        return fromUse
    end
    if itemData.effectKey and tostring(itemData.effectKey) ~= "" then
        return tostring(itemData.effectKey)
    end
    local desc = ToNarrow(itemData.description or itemData.desc or "")
    local key = ClassifyFromDescription(desc)
    if key then
        return key
    end
    return ClassifyFromName(itemData.name)
end

--- Level / rank from item (craftingSkillRequirement, iLevel, level).
function Classify.GetLevelRank(itemData)
    if type(itemData) ~= "table" then
        return 0, 0, L"-"
    end
    local rank = tonumber(itemData.craftingSkillRequirement)
        or tonumber(itemData.skillReq)
        or tonumber(itemData.skillLevel)
        or 0
    local level = tonumber(itemData.iLevel)
        or tonumber(itemData.level)
        or tonumber(itemData.rank)
        or rank
    local text = L"-"
    if level > 0 then
        text = towstring(tostring(level))
    elseif rank > 0 then
        text = towstring(tostring(rank))
    end
    return level, rank, text
end

function Classify.GetRarity(itemData)
    if type(itemData) ~= "table" then
        return 0
    end
    return tonumber(itemData.rarity) or 0
end

function Classify.GetPotionStats(itemData)
    local level, rank, levelText = Classify.GetLevelRank(itemData)
    local effectKey = Classify.GetEffectKey(itemData)
    return {
        effectKey = effectKey,
        effectText = Classify.EffectShortLabel(effectKey),
        level = level,
        rank = rank,
        levelText = levelText,
        rarity = Classify.GetRarity(itemData),
    }
end
