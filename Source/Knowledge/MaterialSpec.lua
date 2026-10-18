----------------------------------------------------------------
-- StockPiler Knowledge/MaterialSpec - role fingerprints for bag/vendor/brew
-- Match by craft stats (not exact uid/name). Containers share skill+slot
-- (Fabricated vs normal vials). Incomplete mains prefer boundUid, then
-- completed Items.ToSpec / slot+skill+stab+power twins (butcher preserved).
--
-- Potions-tab columns (Lvl/Effect/Pwr/Stab/Mult/SCrit) mirror the stats we
-- sum for recipe identity. SCrit = SPECIAL_CHANCE (Super-Critical): may later
-- be omitted from Matches/Key - it yields a higher-tier potion uid (e.g. Potent
-- ...) that is a separate watch target, so it does not advance the stocked line.
----------------------------------------------------------------

StockPiler = StockPiler or {}
StockPiler.MaterialSpec = StockPiler.MaterialSpec or {}
local MS = StockPiler.MaterialSpec

local function T(key, tokens)
    return StockPiler.Util.T(key, tokens)
end

local function CultivationTypes()
    if GameData and GameData.CultivationTypes then
        return GameData.CultivationTypes
    end
    return { NONE = 0, SEED = 1, SOIL = 2, WATERCAN = 3, NUTRIENT = 4, SPORE = 5 }
end

--- Soil / Water / Nutrient plot additives - never apo recipe mats.
local function CultivationTypeIsAdditive(cultType)
    cultType = tonumber(cultType) or 0
    if cultType <= 0 then
        return false
    end
    local types = CultivationTypes()
    local soil = tonumber(types.SOIL) or 2
    local water = tonumber(types.WATERCAN) or 3
    local nutrient = tonumber(types.NUTRIENT) or 4
    return cultType == soil or cultType == water or cultType == nutrient
end

local function Inv()
    return StockPiler.Inventory
end

local function CraftBonusRefs()
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

-- Built-in apothecary effect id -> StockPiler key (and CVT-compatible aliases).
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
    [39] = "hywsnocrit",
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

-- Reverse lookup: StockPiler keys + legacy CVT names -> effect id.
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
    hywsnocrit = 39,
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

function MS.EffectKeyFromEffectId(effectId)
    effectId = tonumber(effectId) or 0
    if effectId <= 0 then
        return nil
    end
    return EFFECT_ID_TO_KEY[effectId]
end

function MS.EffectIdFromKey(key)
    if type(key) ~= "string" or key == "" then
        return nil
    end
    return EFFECT_KEY_TO_ID[string.lower(key)]
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

local function SignedBonus(val)
    val = tonumber(val) or 0
    if val > 32767 then
        return val - 65536
    end
    return val
end

local function AddBonusValue(bonuses, ref, val)
    ref = tonumber(ref) or 0
    if ref <= 0 or val == nil then
        return
    end
    if bonuses[ref] == nil then
        bonuses[ref] = {}
    end
    bonuses[ref][#bonuses[ref] + 1] = SignedBonus(val)
end

local function ParseBonuses(itemData)
    local bonuses = {}
    if type(itemData) ~= "table" then
        return bonuses
    end
    if type(itemData.craftingBonus) == "table" then
        for _, bonus in ipairs(itemData.craftingBonus) do
            if type(bonus) == "table" then
                AddBonusValue(bonuses, bonus.bonusReference, bonus.bonusValue)
            end
        end
        -- Also accept map-style craftingBonus[ref]=value
        if next(bonuses) == nil then
            for ref, val in pairs(itemData.craftingBonus) do
                local nref = tonumber(ref) or 0
                if nref > 0 and type(val) ~= "table" then
                    AddBonusValue(bonuses, nref, val)
                elseif nref > 0 and type(val) == "table" and val.bonusValue ~= nil then
                    AddBonusValue(bonuses, nref, val.bonusValue)
                end
            end
        end
    end
    if type(itemData.CraftItemInfo) == "table" then
        for ref, vals in pairs(itemData.CraftItemInfo) do
            local nref = tonumber(ref) or 0
            if nref > 0 and bonuses[nref] == nil then
                if type(vals) == "table" then
                    AddBonusValue(bonuses, nref, vals[1])
                else
                    AddBonusValue(bonuses, nref, vals)
                end
            end
        end
    end
    -- Seeds often ship cult-only craftingBonus (family/level/fail). Fill missing apo
    -- refs (TYPE / STAB / DURATION / MULTIPLIER / SPECIAL_CHANCE / EFFECT) from the
    -- engine CraftItemInfo table even when craftingBonus is non-empty.
    if type(CraftItemInfo) == "table"
        and type(CraftItemInfo.GetItemBonuses) == "function"
    then
        local ok, vData = pcall(CraftItemInfo.GetItemBonuses, itemData)
        if ok and type(vData) == "table" then
            for ref, vals in pairs(vData) do
                local nref = tonumber(ref) or 0
                if nref > 0 and bonuses[nref] == nil then
                    if type(vals) == "table" then
                        AddBonusValue(bonuses, nref, vals[1])
                    else
                        AddBonusValue(bonuses, nref, vals)
                    end
                end
            end
        end
    end
    -- Flat learned Items.ToSpec / stored bonuses map (fill gaps only).
    if type(itemData.bonuses) == "table" then
        for ref, val in pairs(itemData.bonuses) do
            local nref = tonumber(ref) or 0
            if nref > 0 and bonuses[nref] == nil then
                if type(val) == "table" then
                    AddBonusValue(bonuses, nref, val[1])
                else
                    AddBonusValue(bonuses, nref, val)
                end
            end
        end
    end
    return bonuses
end

local function NormalizeBonusKeys(bonuses)
    if type(bonuses) ~= "table" then
        return {}
    end
    local out = {}
    for k, v in pairs(bonuses) do
        local nref = tonumber(k)
        if nref and nref > 0 and v ~= nil then
            if type(v) == "table" then
                out[nref] = tonumber(v[1]) or v[1]
            else
                out[nref] = v
            end
        end
    end
    return out
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
    if type(itemData) == "table" then
        local hinted = tostring(itemData.craftingRole or itemData.role or "")
        if hinted ~= "" and hinted ~= "ingredient" then
            return hinted
        end
    end
    local bonuses = ParseBonuses(itemData)
    local B = CraftBonusRefs()
    local slotType = FirstBonus(bonuses, B.TYPE) or 0
    return RoleFromSlotType(slotType)
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

local function ToNarrow(text)
    return StockPiler.Util.ToNarrow(text)
end

-- Infer EFFECT when craftingBonus omits ref 6 (common on heal/stat mains).
-- Order matters: "willpower potions" contains the substring "power potion".
local DESC_EFFECT_PATTERNS = {
    -- Resist families before generic "armor" / "resist" substrings.
    { "spirit resistance", "rspi" },
    { "spirit resist", "rspi" },
    { "corporeal resistance", "rcorp" },
    { "corporeal resist", "rcorp" },
    { "elemental resistance", "rele" },
    { "elemental resist", "rele" },
    { "intelligence", "int" },
    { "willpower", "wil" },
    { "strength", "str" },
    { "power potion", "str" },
    { "toughness", "tou" },
    { "ballistic skill", "rskill" },
    { "ballistic", "rskill" },
    { "healing", "heal" },
    { "restoration", "regen" },
    { "regenerat", "regen" },
    { "action point", "ap" },
    { "invigor", "ap" },
    { "energy", "ap" },
    { "armor", "arm" },
    { "armour", "arm" },
    { "absorb", "shabs" },
    { "barrier", "shabs" },
    { "molotov", "dmgaoe" },
    { "napalm", "dmg" },
    { "flame breath", "dmgcone" },
    { "shield damage", "shdmg" },
    { "glue bomb", "snare" },
    { "slows targets", "snare" },
    { "slow targets", "snare" },
    { "snare", "snare" },
    { "movement speed", "movespeed" },
    { "move speed", "movespeed" },
    { "pyrewind", "dmgcone" },
}

local function EffectIdFromDescription(description)
    local desc = string.lower(ToNarrow(description))
    if desc == "" then
        return nil
    end
    for i = 1, #DESC_EFFECT_PATTERNS do
        local needle, effectKey = DESC_EFFECT_PATTERNS[i][1], DESC_EFFECT_PATTERNS[i][2]
        if string.find(desc, needle, 1, true) then
            return EFFECT_KEY_TO_ID[effectKey]
        end
    end
    return nil
end

local function LookupItemDescription(itemData)
    if type(itemData) ~= "table" then
        return nil
    end
    local desc = itemData.description or itemData.desc or itemData.descriptionNarrow
    if desc ~= nil and ToNarrow(desc) ~= "" then
        return desc
    end
    local uid = tonumber(itemData.uniqueID or itemData.uniqueId or itemData.uid) or 0
    if uid > 0 and StockPiler.Items and StockPiler.Items.GetByUid then
        local learned = StockPiler.Items.GetByUid(uid)
        if type(learned) == "table" then
            local learnedDesc = learned.description or learned.desc or learned.descriptionNarrow
            if learnedDesc ~= nil and ToNarrow(learnedDesc) ~= "" then
                return learnedDesc
            end
        end
    end
    if uid > 0 and type(GetDatabaseItemData) == "function" then
        local ok, data = pcall(GetDatabaseItemData, uid)
        if ok and type(data) == "table" and data.description ~= nil then
            return data.description
        end
    end
    return nil
end

--- Main-ingredient EFFECT: craftingBonus -> CraftItemInfo -> item description.
local function ResolveMainEffectId(itemData, bonuses)
    local B = CraftBonusRefs()
    local effectId = FirstBonus(bonuses, B.EFFECT)
    if effectId and effectId > 0 then
        return effectId
    end
    effectId = tonumber(itemData and itemData.effectId)
    if effectId and effectId > 0 then
        return effectId
    end
    if type(CraftItemInfo) == "table" and type(CraftItemInfo.GetItemBonuses) == "function"
        and type(itemData) == "table"
    then
        local ok, vData = pcall(CraftItemInfo.GetItemBonuses, itemData)
        if ok and type(vData) == "table" and type(vData[B.EFFECT]) == "table" then
            effectId = tonumber(vData[B.EFFECT][1]) or 0
            if effectId > 0 then
                return effectId
            end
        end
    end
    local desc = LookupItemDescription(itemData)
    if desc ~= nil then
        return EffectIdFromDescription(desc)
    end
    return nil
end

--- Public: resolve EFFECT for a main (bonuses / CraftItemInfo / description).
function MS.ResolveMainEffectId(itemData, bonuses)
    return ResolveMainEffectId(itemData, type(bonuses) == "table" and bonuses or nil)
end

function MS.CraftBonusRefs()
    return CraftBonusRefs()
end

--- Build a comparable material fingerprint from itemData or a learned ToSpec table.
function MS.FromItemData(itemData, roleHint)
    if type(itemData) ~= "table" then
        return nil
    end
    -- Already a MaterialSpec-shaped table (hydrated slot.spec / ToSpec).
    if IsMaterialSpec(itemData) and (itemData.slotType ~= nil or itemData.tradeSkill ~= nil) then
        local copy = MS.Copy(itemData)
        if roleHint and roleHint ~= "" and copy then
            copy.role = roleHint
        end
        return copy
    end

    local uid = tonumber(itemData.uniqueID or itemData.uniqueId or itemData.uid) or 0
    local bonuses = ParseBonuses(itemData)
    local B = CraftBonusRefs()
    local tradeSkill = FirstBonus(bonuses, B.CRAFTING_FAMILY)
        or tonumber(itemData.tradeSkill) or 0
    local slotType = FirstBonus(bonuses, B.TYPE)
        or tonumber(itemData.slotType) or 0
    local skillLevel = FirstBonus(bonuses, B.CRAFTING_LEVEL)
    if skillLevel == nil or skillLevel <= 0 then
        skillLevel = tonumber(itemData.craftingSkillRequirement)
            or tonumber(itemData.skillLevel)
            or tonumber(itemData.skillReq)
            or 0
    end
    local cultType = tonumber(itemData.cultivationType) or 0
    if cultType ~= 0 then
        tradeSkill = CultivationSkill()
    elseif tradeSkill == 0 then
        tradeSkill = ApothecarySkill()
    end
    local role = RoleFromItemData(itemData, roleHint)
    local effectId = nil
    if role == "main" then
        effectId = ResolveMainEffectId(itemData, bonuses)
    else
        effectId = FirstBonus(bonuses, B.EFFECT) or tonumber(itemData.effectId)
    end
    local specBonuses = {}
    for ref = 1, 15 do
        if bonuses[ref] and ref ~= B.CRAFTING_FAMILY and ref ~= B.TYPE and ref ~= B.EFFECT then
            specBonuses[ref] = bonuses[ref][1]
        end
    end
    -- Flat power/stability fallbacks from thin ToSpec rows.
    if specBonuses[B.STABILITY] == nil and itemData.stability ~= nil then
        specBonuses[B.STABILITY] = SignedBonus(itemData.stability)
    end
    if specBonuses[B.POWER] == nil and itemData.power ~= nil then
        specBonuses[B.POWER] = SignedBonus(itemData.power)
    end
    if specBonuses[B.DURATION] == nil and itemData.duration ~= nil then
        specBonuses[B.DURATION] = SignedBonus(itemData.duration)
    end
    if effectId ~= nil and effectId > 0 then
        specBonuses[B.EFFECT] = effectId
    end
    local incomplete = false
    if role == "main" and (effectId == nil or tonumber(effectId) <= 0) then
        incomplete = true
    end
    if itemData.incomplete == true then
        incomplete = true
    end
    local out = {
        uid = uid > 0 and uid or nil,
        tradeSkill = tradeSkill or 0,
        slotType = slotType,
        skillLevel = skillLevel or 0,
        cultivationType = cultType,
        effectId = effectId,
        bonuses = specBonuses,
        role = role,
        incomplete = incomplete,
        boundUid = tonumber(itemData.boundUid) or (incomplete and uid > 0 and uid or nil),
        power = tonumber(specBonuses[B.POWER]) or 0,
        stability = tonumber(specBonuses[B.STABILITY]) or 0,
        duration = tonumber(specBonuses[B.DURATION]) or 0,
        name = itemData.name,
        rarity = itemData.rarity,
    }
    -- Engine apo field: true/false when known; omit when unknown.
    if itemData.isRefinable ~= nil then
        out.isRefinable = itemData.isRefinable == true
    elseif uid > 0 and StockPiler.Items and StockPiler.Items.GetByUid then
        local learned = StockPiler.Items.GetByUid(uid)
        if type(learned) == "table" and learned.isRefinable ~= nil then
            out.isRefinable = learned.isRefinable == true
        end
    end
    return out
end

--- Cached by uid; parse without role hint so one entry serves all Matches calls.
function MS.FromItemDataCached(itemData, roleHint)
    if type(itemData) ~= "table" then
        return nil
    end
    if IsMaterialSpec(itemData) then
        return MS.FromItemData(itemData, roleHint)
    end
    local uid = tonumber(itemData.uniqueID or itemData.uniqueId) or 0
    if uid <= 0 then
        return MS.FromItemData(itemData, roleHint)
    end
    local I = Inv()
    local cache = I and I._specParseCache
    if type(cache) ~= "table" then
        cache = {}
        if I then
            I._specParseCache = cache
        end
    end
    local hit = cache[uid]
    if hit == false then
        return nil
    end
    if type(hit) == "table" then
        -- Re-parse incomplete mains so description EFFECT can upgrade the cache.
        -- A skill level with no stability/power/multiplier is a thin first read.
        -- Do not keep it; the next bag sample often has CraftItemInfo.
        if hit.incomplete ~= true and MS.SpecShowsBonus(hit) then
            if roleHint and roleHint ~= "" and hit.role ~= roleHint then
                local copy = MS.Copy(hit)
                if copy then
                    copy.role = roleHint
                end
                return copy
            end
            return hit
        end
    end
    local spec = MS.FromItemData(itemData, nil)
    if spec == nil then
        cache[uid] = false
        return nil
    end
    -- Do not cache thin parses (bag AsItemData often lacks CraftItemInfo once).
    -- Skill level alone still paints "200 Apothecary - Stabilizer" with no stats.
    if MS.SpecShowsBonus(spec) then
        cache[uid] = spec
    else
        cache[uid] = nil
    end
    if roleHint and roleHint ~= "" and spec.role ~= roleHint then
        local copy = MS.Copy(spec)
        if copy then
            copy.role = roleHint
        end
        return copy
    end
    return spec
end

function MS.Copy(spec)
    if type(spec) ~= "table" then
        return nil
    end
    local bonuses = NormalizeBonusKeys(spec.bonuses)
    local out = {
        uid = tonumber(spec.uid) or nil,
        tradeSkill = spec.tradeSkill or 0,
        slotType = spec.slotType or 0,
        skillLevel = spec.skillLevel or 0,
        cultivationType = spec.cultivationType or 0,
        effectId = spec.effectId,
        bonuses = bonuses,
        role = spec.role or "ingredient",
        incomplete = spec.incomplete == true,
        boundUid = tonumber(spec.boundUid) or nil,
        power = tonumber(spec.power) or tonumber(bonuses[2]) or 0,
        stability = tonumber(spec.stability) or tonumber(bonuses[1]) or 0,
        duration = tonumber(spec.duration) or tonumber(bonuses[3]) or 0,
        name = spec.name,
        rarity = spec.rarity,
    }
    if spec.isRefinable ~= nil then
        out.isRefinable = spec.isRefinable == true
    end
    return out
end

local function SpecLooksThin(spec)
    if type(spec) ~= "table" then
        return true
    end
    if spec.incomplete == true then
        return true
    end
    return (tonumber(spec.slotType) or 0) <= 0
        and (tonumber(spec.skillLevel) or 0) <= 0
end

--- Soil / Water / Nutrient (and Classify heuristics). Never AutoBuy / ProductMatches as apo mats.
function MS.IsCultivationAdditive(itemOrSpec)
    if type(itemOrSpec) ~= "table" then
        return false
    end
    if CultivationTypeIsAdditive(itemOrSpec.cultivationType) then
        return true
    end
    local AD = StockPiler.Additives
    if AD and AD.Classify and not IsMaterialSpec(itemOrSpec) then
        local info = AD.Classify(itemOrSpec)
        if type(info) == "table" and CultivationTypeIsAdditive(info.cultType) then
            return true
        end
    end
    return false
end

local function EnrichFromLearnedItems(other, itemData, roleHint)
    if type(other) ~= "table" or not SpecLooksThin(other) then
        return other
    end
    if not (StockPiler.Items and StockPiler.Items.ToSpec) then
        return other
    end
    local uid = tonumber(other.uid) or 0
    if uid <= 0 and type(itemData) == "table" then
        uid = tonumber(itemData.uniqueID) or tonumber(itemData.uid) or 0
    end
    if uid <= 0 then
        return other
    end
    local learned = StockPiler.Items.ToSpec(uid)
    if type(learned) ~= "table" or SpecLooksThin(learned) then
        return other
    end
    local enriched = MS.AsApothecaryProduct(learned, roleHint or other.role)
    return type(enriched) == "table" and enriched or other
end

--- Incomplete recipe mains are uid-bound at learn time (board omitted EFFECT).
--- Once Items.ToSpec(boundUid) is complete, return that product so butcher /
--- preserved twins (Supple Scale vs Preserved Glossy Chitin) can ProductMatch.
local function CompleteTargetFromIncomplete(spec)
    if type(spec) ~= "table" or spec.incomplete ~= true then
        return nil
    end
    local boundUid = tonumber(spec.boundUid) or tonumber(spec.uid) or 0
    if boundUid <= 0 or not (StockPiler.Items and StockPiler.Items.ToSpec) then
        return nil
    end
    local learned = StockPiler.Items.ToSpec(boundUid)
    if type(learned) ~= "table" or learned.incomplete == true then
        return nil
    end
    if MS.IsCultivationAdditive(learned) then
        return nil
    end
    local complete = MS.AsApothecaryProduct(learned, spec.role or learned.role)
    if type(complete) ~= "table" or complete.incomplete == true then
        return nil
    end
    return complete
end

--- When Items has not completed the bound uid yet, still accept a bag main that
--- shares slot/skill/stab/power with the incomplete stub (twin preserved forms).
--- EFFECT must also agree when either side knows it — otherwise L175 stab/power
--- twins (WP / armor / snare) collide on the same incomplete fingerprint.
local function IncompleteMainStatsMatch(itemData, spec)
    if type(itemData) ~= "table" or type(spec) ~= "table" then
        return false
    end
    if tostring(spec.role or "") ~= "main" then
        return false
    end
    local product = MS.AsApothecaryProduct(itemData, "main")
    if type(product) ~= "table" or product.incomplete == true then
        return false
    end
    if (tonumber(product.slotType) or 0) ~= (tonumber(spec.slotType) or 0) then
        return false
    end
    if (tonumber(product.skillLevel) or 0) ~= (tonumber(spec.skillLevel) or 0) then
        return false
    end
    if (tonumber(product.tradeSkill) or 0) ~= (tonumber(spec.tradeSkill) or 0) then
        return false
    end
    local B = CraftBonusRefs()
    local otherBonuses = NormalizeBonusKeys(product.bonuses)
    local specBonuses = NormalizeBonusKeys(spec.bonuses)
    if not BonusMatch(otherBonuses, specBonuses, B.STABILITY) then
        return false
    end
    if not BonusMatch(otherBonuses, specBonuses, B.POWER) then
        return false
    end
    local productEffect = tonumber(FirstBonus(otherBonuses, B.EFFECT)) or tonumber(product.effectId) or 0
    if productEffect <= 0 then
        productEffect = tonumber(ResolveMainEffectId(itemData, otherBonuses)) or 0
    end
    local specEffect = tonumber(FirstBonus(specBonuses, B.EFFECT)) or tonumber(spec.effectId) or 0
    if specEffect <= 0 then
        local boundUid = tonumber(spec.boundUid) or tonumber(spec.uid) or 0
        local probe = nil
        if boundUid > 0 and StockPiler.Items and StockPiler.Items.GetByUid then
            probe = StockPiler.Items.GetByUid(boundUid)
        end
        if type(probe) ~= "table" then
            probe = {
                uniqueID = boundUid,
                description = spec.description or spec.descriptionNarrow,
                descriptionNarrow = spec.descriptionNarrow,
            }
        end
        specEffect = tonumber(ResolveMainEffectId(probe, specBonuses)) or 0
    end
    if productEffect > 0 and specEffect > 0 then
        return productEffect == specEffect
    end
    -- Spec still effect-blind: do not accept a complete main that already has
    -- EFFECT (would teach WP/armor onto a snare stub). Bound-uid equality is
    -- handled before this helper in Matches / ProductMatches.
    if productEffect > 0 and specEffect <= 0 then
        return false
    end
    return true
end

--- itemData may be raw bag item or an already-built MaterialSpec.
function MS.Matches(itemData, spec)
    if type(itemData) ~= "table" or type(spec) ~= "table" then
        return false
    end
    local boundUid = tonumber(spec.boundUid) or 0
    if spec.incomplete == true then
        if boundUid <= 0 then
            boundUid = tonumber(spec.uid) or 0
        end
        if boundUid <= 0 then
            return false
        end
        local itemUid = tonumber(itemData.uniqueID) or tonumber(itemData.uid) or 0
        if itemUid <= 0 and IsMaterialSpec(itemData) then
            itemUid = tonumber(itemData.boundUid) or tonumber(itemData.uid) or 0
        end
        if itemUid == boundUid then
            return true
        end
        local complete = CompleteTargetFromIncomplete(spec)
        if type(complete) == "table" then
            return MS.Matches(itemData, complete)
        end
        return IncompleteMainStatsMatch(itemData, spec)
    end

    local other = itemData
    if not IsMaterialSpec(itemData) then
        other = MS.FromItemDataCached(itemData, nil)
    end
    if other == nil then
        return false
    end
    -- Thin bag parses: prefer learned Items fingerprint (Artisan's vials, etc.).
    other = EnrichFromLearnedItems(other, itemData, spec.role)
    if other == nil then
        return false
    end
    local role = spec.role or other.role or "ingredient"
    -- Incomplete mains stay uid-bound; incomplete containers need slot enrich.
    if other.incomplete == true and role ~= "container" then
        return false
    end
    -- Plot additives never match apo recipe slots (even if skill tiers coincide).
    if role ~= "" and role ~= "ingredient"
        and (MS.IsCultivationAdditive(other) or MS.IsCultivationAdditive(itemData))
        and (tonumber(spec.cultivationType) or 0) == 0
    then
        return false
    end
    -- Same uid always matches (fast path for exact stack).
    local aUid = tonumber(other.uid) or 0
    local bUid = tonumber(spec.uid) or 0
    if aUid > 0 and aUid == bUid then
        return true
    end

    local otherBonuses = NormalizeBonusKeys(other.bonuses)
    local specBonuses = NormalizeBonusKeys(spec.bonuses)
    if tonumber(other.tradeSkill) ~= tonumber(spec.tradeSkill) then
        return false
    end
    if (tonumber(other.cultivationType) or 0) ~= (tonumber(spec.cultivationType) or 0) then
        return false
    end
    local otherSkill = tonumber(other.skillLevel) or 0
    if otherSkill <= 0 and type(itemData) == "table" then
        otherSkill = tonumber(itemData.craftingSkillRequirement)
            or tonumber(itemData.skillLevel)
            or tonumber(itemData.skillReq)
            or 0
    end
    if otherSkill ~= (tonumber(spec.skillLevel) or 0) then
        return false
    end
    if role == "main" then
        if tonumber(other.slotType) ~= tonumber(spec.slotType) then
            return false
        end
        if tonumber(other.effectId) ~= tonumber(spec.effectId) then
            return false
        end
        local B = CraftBonusRefs()
        if not BonusMatch(otherBonuses, specBonuses, B.STABILITY) then
            return false
        end
        if not BonusMatch(otherBonuses, specBonuses, B.POWER) then
            return false
        end
        return true
    end
    if role == "container" then
        -- Require slot + skill (SP2). Skill-only matched Fertile Soil (150 Cult Soil)
        -- after ProductMatches stripped cultivationType.
        local oSlot = tonumber(other.slotType) or 0
        local sSlot = tonumber(spec.slotType) or 0
        if oSlot <= 0 and type(itemData) == "table" then
            oSlot = tonumber(itemData.slotType) or 0
        end
        if oSlot <= 0 or sSlot <= 0 then
            return false
        end
        return oSlot == sSlot and otherSkill == (tonumber(spec.skillLevel) or 0)
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
        if not BonusMatch(otherBonuses, specBonuses, B.STABILITY) then
            return false
        end
        if not BonusMatch(otherBonuses, specBonuses, B.MULTIPLIER) then
            return false
        end
        return true
    end
    if role == "extender" or role == "multiplier" or role == "stimulant" then
        if tonumber(other.slotType) ~= tonumber(spec.slotType) then
            return false
        end
        local B = CraftBonusRefs()
        if role == "extender" and not BonusMatch(otherBonuses, specBonuses, B.DURATION) then
            return false
        end
        if (role == "multiplier" or role == "stimulant")
            and not BonusMatch(otherBonuses, specBonuses, B.MULTIPLIER)
        then
            return false
        end
        -- Potions-tab Mult + SCrit (SPECIAL_CHANCE / Super-Critical).
        -- Squig Bits vs Majestic Fusk share +16 mult but differ on SCrit.
        -- Future: may drop SPECIAL_CHANCE from matching - Super-Critical only
        -- produces a different potion uid (Potent ...), not progress on the
        -- watched stock target. Treat like DESTROY_ON_FAIL if that lands.
        if role == "multiplier"
            and not BonusMatch(otherBonuses, specBonuses, B.SPECIAL_CHANCE)
        then
            return false
        end
        if role == "multiplier"
            and not BonusMatch(otherBonuses, specBonuses, B.CRITICAL_CHANCE)
        then
            return false
        end
        return true
    end
    return tonumber(other.slotType) == tonumber(spec.slotType)
end

--- Recipe / demand identity. Omits DESTROY_ON_FAIL (via MaterialExceptions) so
--- Fabricated vs Artisan's Glass Vial share keys despite differing on that bonus.
--- opts.omitUid: never embed uid: (recipe storage — Scale/Chitin twins share a key).
function MS.Key(spec, boundUid, opts)
    if type(spec) ~= "table" then
        return ""
    end
    opts = type(opts) == "table" and opts or {}
    local parts = {
        "ts:" .. tostring(spec.tradeSkill or 0),
        "st:" .. tostring(spec.slotType or 0),
        "lv:" .. tostring(spec.skillLevel or 0),
        "ct:" .. tostring(spec.cultivationType or 0),
        "role:" .. tostring(spec.role or ""),
    }
    if spec.incomplete ~= true and spec.effectId ~= nil then
        parts[#parts + 1] = "fx:" .. tostring(spec.effectId)
    end
    local uid = tonumber(boundUid) or tonumber(spec.boundUid) or 0
    if opts.omitUid ~= true and spec.incomplete == true and uid > 0 then
        parts[#parts + 1] = "uid:" .. tostring(uid)
    end
    if type(spec.bonuses) == "table" then
        local ME = StockPiler.MaterialExceptions
        local refs = {}
        for ref, val in pairs(NormalizeBonusKeys(spec.bonuses)) do
            local nref = tonumber(ref) or 0
            local skip = ME and ME.ShouldIgnoreBonusRef and ME.ShouldIgnoreBonusRef(nref) == true
            if not skip then
                refs[#refs + 1] = tostring(nref) .. "=" .. tostring(val)
            end
        end
        table.sort(refs)
        if #refs > 0 then
            parts[#parts + 1] = "b:" .. table.concat(refs, ",")
        end
    end
    return table.concat(parts, "|")
end

--- UID-agnostic mat identity for Account.recipes fingerprints.
--- Prefer completed Items.ToSpec when an incomplete stub can be upgraded; otherwise
--- Key without uid: so butcher twins (Supple Scale / Preserved Glossy Chitin) collide.
function MS.RecipeIdentityKey(spec, boundUid)
    if type(spec) ~= "table" then
        return ""
    end
    if spec.incomplete == true then
        local complete = CompleteTargetFromIncomplete(spec)
        if type(complete) == "table" then
            return MS.Key(complete, nil)
        end
        return MS.Key(spec, boundUid, { omitUid = true })
    end
    return MS.Key(spec, nil)
end

--- Normalize seed/plant forms to apo recipe context (ct:0) for planner have.
--- Never convert Soil/Water/Nutrient additives into apo products (AutoBuy false hits).
function MS.AsApothecaryProduct(specOrItem, roleHint)
    if type(specOrItem) ~= "table" then
        return nil
    end
    if MS.IsCultivationAdditive(specOrItem) then
        return nil
    end
    local spec
    if IsMaterialSpec(specOrItem) then
        spec = MS.Copy(specOrItem)
    else
        spec = MS.Copy(MS.FromItemDataCached(specOrItem, roleHint))
    end
    if type(spec) ~= "table" then
        return nil
    end
    if CultivationTypeIsAdditive(spec.cultivationType) then
        return nil
    end
    if roleHint and roleHint ~= "" then
        spec.role = roleHint
    end
    spec.cultivationType = 0
    spec.tradeSkill = ApothecarySkill()
    return spec
end

function MS.ProductKey(specOrItem, roleHint)
    local product = MS.AsApothecaryProduct(specOrItem, roleHint)
    if type(product) ~= "table" then
        return ""
    end
    return MS.Key(product)
end

--- Stat-equivalent match across uid variants and cultivation->apo product forms.
function MS.ProductMatches(itemData, spec)
    if type(itemData) ~= "table" or type(spec) ~= "table" then
        return false
    end
    -- Plot additives are never recipe mats (even after skill-tier coincidence).
    if MS.IsCultivationAdditive(itemData) then
        return false
    end
    if MS.IsCultivationAdditive(spec) then
        return false
    end
    -- Server chat "Bad seed data / it has been lost" for this uid. Stat twins
    -- can still match the fingerprint; this one cannot be slotted.
    local itemUid = tonumber(itemData.uniqueID) or tonumber(itemData.uid) or 0
    if itemUid > 0 then
        local Brew = StockPiler.Brew
        if Brew and Brew.IsRejectedCraftUid and Brew.IsRejectedCraftUid(itemUid) == true then
            return false
        end
    end
    if spec.incomplete == true then
        local boundUid = tonumber(spec.boundUid) or tonumber(spec.uid) or 0
        if boundUid <= 0 then
            return false
        end
        local itemUid = tonumber(itemData.uniqueID) or tonumber(itemData.uid) or 0
        if itemUid == boundUid then
            return true
        end
        -- Board-learned incomplete main (e.g. Supple Scale uid:3030027): allow
        -- fingerprint twins once Items knows the complete form, or when the bag
        -- main shares slot/skill/stab/power (Preserved Glossy Chitin Shard).
        local complete = CompleteTargetFromIncomplete(spec)
        if type(complete) == "table" then
            return MS.ProductMatches(itemData, complete)
        end
        return IncompleteMainStatsMatch(itemData, spec)
    end
    local role = spec.role or nil
    local product = MS.AsApothecaryProduct(itemData, role)
    local target = MS.AsApothecaryProduct(spec, role)
    if type(product) ~= "table" or type(target) ~= "table" or target.incomplete == true then
        return false
    end
    -- Enrich thin bag items from learned Items (containers often lack CraftItemInfo).
    local uid = tonumber(itemData.uniqueID) or tonumber(itemData.uid) or 0
    local needsEnrich = (tonumber(product.slotType) or 0) <= 0
        or (tonumber(product.skillLevel) or 0) <= 0
        or (product.role == "main" and (product.incomplete == true or (tonumber(product.effectId) or 0) <= 0))
    if needsEnrich and uid > 0 and StockPiler.Items and StockPiler.Items.ToSpec then
        local learned = StockPiler.Items.ToSpec(uid)
        if type(learned) == "table" and learned.incomplete ~= true
            and not MS.IsCultivationAdditive(learned)
        then
            product = MS.AsApothecaryProduct(learned, role) or product
        end
    end
    if product.incomplete == true then
        return false
    end
    return MS.Matches(product, target)
end

function MS.Label(spec)
    if type(spec) ~= "table" then
        return ""
    end
    if spec.name ~= nil then
        return ToNarrow(spec.name)
    end
    local uid = tonumber(spec.uid) or tonumber(spec.boundUid) or 0
    if uid > 0 and StockPiler.Items and StockPiler.Items.GetByUid then
        local row = StockPiler.Items.GetByUid(uid)
        if type(row) == "table" and row.name ~= nil then
            return ToNarrow(row.name)
        end
    end
    return tostring(spec.role or "mat")
end

local ROLE_LOC_KEYS = {
    container = "material.role.container",
    main = "material.role.main",
    stabilizer = "material.role.stabilizer",
    goldweed = "material.role.goldweed",
    extender = "material.role.extender",
    multiplier = "material.role.multiplier",
    stimulant = "material.role.stimulant",
    ingredient = "material.role.ingredient",
}

function MS.RoleTitle(role)
    role = role or ""
    local key = ROLE_LOC_KEYS[role]
    if key then
        return T(key)
    end
    if role ~= "" then
        return towstring(role)
    end
    return T("material.role.material")
end

function MS.TradeSkillDisplayName(spec)
    local ts = type(spec) == "table" and tonumber(spec.tradeSkill) or 0
    if GameData and GameData.TradeSkills then
        local g = GameData.TradeSkills
        if ts == g.APOTHECARY then
            return T("material.trade.apothecary")
        end
        if ts == g.CULTIVATION then
            return T("material.trade.cultivation")
        end
        if ts == g.TALISMAN then
            return T("material.trade.talisman")
        end
    end
    if type(spec) == "table" and (tonumber(spec.cultivationType) or 0) ~= 0 then
        return T("material.trade.cultivation")
    end
    return T("material.trade.apothecary")
end

local function EffectPhrase(key)
    if not key or key == "" then
        return nil
    end
    key = tostring(key)
    local function FromLocale(localeKey)
        if StockPiler.Locale and StockPiler.Locale.ResolveTemplate then
            local template = StockPiler.Locale.ResolveTemplate(localeKey)
            if template ~= nil and template ~= L"" then
                return template
            end
        end
        return nil
    end
    local phrase = FromLocale("effect.full." .. key)
    if phrase then
        return phrase
    end
    -- Tip-friendly fallback when full name is missing (hybrids historically short-only).
    phrase = FromLocale("effect.short." .. key)
    if phrase then
        return phrase
    end
    return towstring(key)
end

--- When craftingBonus EFFECT is missing (incomplete mains), try item/DB description.
local function EnrichSpecEffectId(spec)
    if type(spec) ~= "table" then
        return nil
    end
    local existing = tonumber(spec.effectId) or 0
    if existing > 0 then
        return existing
    end
    local uid = tonumber(spec.boundUid) or tonumber(spec.uid) or tonumber(spec.uniqueID) or 0
    if uid <= 0 then
        return nil
    end
    local itemData = nil
    if StockPiler.Items and StockPiler.Items.AsItemData then
        itemData = StockPiler.Items.AsItemData(uid)
    end
    local hasDesc = type(itemData) == "table"
        and (itemData.description ~= nil or itemData.desc ~= nil or itemData.descriptionNarrow ~= nil)
    if (not hasDesc) and type(GetDatabaseItemData) == "function" then
        local ok, data = pcall(GetDatabaseItemData, uid)
        if ok and type(data) == "table" then
            itemData = data
        end
    end
    if type(itemData) ~= "table" then
        itemData = { uniqueID = uid }
    end
    local bonuses = ParseBonuses(itemData)
    local effectId = ResolveMainEffectId(itemData, bonuses)
    effectId = tonumber(effectId) or 0
    if effectId > 0 then
        -- Stamp for display; leave incomplete so Key stays uid-bound (no fx:).
        spec.effectId = effectId
        return effectId
    end
    return nil
end

function MS.EffectDisplayName(spec)
    if type(spec) ~= "table" then
        return nil
    end
    local effectId = tonumber(spec.effectId) or 0
    if effectId <= 0 then
        effectId = EnrichSpecEffectId(spec) or 0
    end
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
    return T("material.tip.effect_id", { id = tostring(effectId) })
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
                [1] = T("material.bonus.stability"),
                [2] = T("material.bonus.power"),
                [3] = T("material.bonus.duration"),
                [4] = T("material.bonus.multiplier"),
                [12] = T("material.bonus.supercrit"),
                [13] = T("material.bonus.fail"),
                [14] = T("material.bonus.supercrit"),
            }
            name = fallback[ref] or T("material.bonus.generic")
        end
        local percentRefs = { [12] = true, [13] = true, [14] = true }
        local valueStr = tostring(value)
        if percentRefs[ref] then
            if value < 0 then
                text = T("material.bonus.pct", { value = valueStr, name = name })
            else
                text = T("material.bonus.pct_plus", { value = valueStr, name = name })
            end
        elseif value < 0 then
            text = T("material.bonus.flat", { value = valueStr, name = name })
        else
            text = T("material.bonus.flat_plus", { value = valueStr, name = name })
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

local function CultivationTypeName(cultType)
    cultType = tonumber(cultType) or 0
    local types = GameData and GameData.CultivationTypes
    local spore = (types and types.SPORE) or 5
    local seed = (types and types.SEED) or 1
    if cultType == spore then
        return T("material.cult.spore")
    end
    if cultType == seed or cultType == 0 then
        return T("material.cult.seed")
    end
    if cultType == ((types and types.SOIL) or 2) then
        return T("material.cult.soil")
    end
    if cultType == ((types and types.WATERCAN) or 3) then
        return T("material.cult.watering_can")
    end
    if cultType == ((types and types.NUTRIENT) or 4) then
        return T("material.cult.nutrient")
    end
    return T("material.cult.seed")
end

local function ResolveSeedItem(seed)
    if type(seed) ~= "table" then
        return nil
    end
    if (tonumber(seed.cultivationType) or 0) ~= 0 and type(seed.craftingBonus) == "table" then
        return seed
    end
    local uid = tonumber(seed.uniqueID) or tonumber(seed.uid) or 0
    if uid <= 0 then
        return nil
    end
    local Inv = StockPiler.Inventory
    if Inv and Inv.ForEachItem then
        local found = nil
        Inv.ForEachItem(function(item)
            if found == nil and (tonumber(item and item.uniqueID) or 0) == uid then
                found = item
            end
        end)
        if type(found) == "table" then
            return found
        end
    end
    if type(GetDatabaseItemData) == "function" then
        local ok, data = pcall(GetDatabaseItemData, uid)
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
            return T("material.tip.grows", { name = effectName })
        end
        return T("material.tip.grows_main")
    end
    if role ~= "" and role ~= "mat" and role ~= "ingredient" then
        return T("material.tip.grows", { name = MS.RoleTitle(role) })
    end
    return nil
end

--- True when the tip has a yellow stat (stability, power, multiplier, and the rest).
function MS.SpecShowsBonus(spec)
    if type(spec) ~= "table" or type(spec.bonuses) ~= "table" then
        return false
    end
    local B = CraftBonusRefs()
    local refs = {
        B.STABILITY,
        B.POWER,
        B.MULTIPLIER,
        B.DURATION,
        B.CRITICAL_CHANCE,
        B.SPECIAL_CHANCE,
        B.FAIL_CHANCE,
        B.YIELD,
    }
    for i = 1, #refs do
        local val = tonumber(spec.bonuses[refs[i]])
        if val ~= nil and val ~= 0 then
            return true
        end
    end
    return false
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

--- Split NeedLabel into header + parenthetical detail (no outer parens).
function MS.NeedLabelParts(spec, context)
    if type(spec) ~= "table" then
        return { header = T("material.tip.fallback_material"), detail = L"" }
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
    local trade = T("material.trade.apothecary")
    local slot = MS.RoleTitle(plantSpec.role or lineSpec.role or "mat")
    if asSeed then
        trade = T("material.trade.cultivating")
        slot = CultivationTypeName(cultType)
        if lv <= 0 then
            lv = tonumber(plantSpec.skillLevel) or 0
        end
    elseif (tonumber(lineSpec.cultivationType) or 0) ~= 0 then
        trade = T("material.trade.cultivating")
        slot = CultivationTypeName(lineSpec.cultivationType)
    else
        trade = MS.TradeSkillDisplayName(lineSpec)
        if lineSpec.role == "container" then
            local cit = SlotTypeConstants()
            local st = tonumber(lineSpec.slotType) or 0
            if st == (tonumber(cit.CONTAINER_ESSENCE) or 7) then
                slot = T("material.slot.essence_container")
            elseif st == (tonumber(cit.CONTAINER_DYE) or 6) then
                slot = T("material.slot.dye_container")
            else
                slot = T("material.slot.container")
            end
        end
    end

    local header = T("material.tip.header", {
        lv = tostring(lv),
        trade = trade,
        role = slot,
    })
    local paren = {}
    if asSeed then
        local grows = MS.GrowsPhrase(plantSpec)
        if grows then
            paren[#paren + 1] = grows
        end
    elseif (plantSpec.role or "") == "main" then
        local effectName = MS.EffectDisplayName(plantSpec)
        -- Learned incomplete mains often omit EFFECT; recipe/potion effectKey fills the tip.
        if (effectName == nil or effectName == L"") and type(context.effectKey) == "string"
            and context.effectKey ~= ""
        then
            effectName = EffectPhrase(context.effectKey)
        end
        if (effectName == nil or effectName == L"") and (tonumber(context.effectId) or 0) > 0 then
            effectName = MS.EffectDisplayName({ effectId = tonumber(context.effectId) })
        end
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
    return {
        header = header,
        detail = JoinNeedParts(paren),
    }
end

--- Recipe-style slot line (header + optional detail parens).
function MS.NeedLabel(spec, context)
    local parts = MS.NeedLabelParts(spec, context)
    if parts.detail ~= nil and parts.detail ~= L"" then
        return T("material.tip.need_parens", {
            header = parts.header,
            detail = parts.detail,
        })
    end
    return parts.header
end

--- True if item is a seed/spore (must not fill apo brew slots).
function MS.IsSeedOrSpore(itemOrSpec)
    local ct = 0
    if type(itemOrSpec) == "table" then
        ct = tonumber(itemOrSpec.cultivationType) or 0
        if ct == 0 and not IsMaterialSpec(itemOrSpec) then
            local parsed = MS.FromItemDataCached(itemOrSpec, nil)
            ct = parsed and tonumber(parsed.cultivationType) or 0
        end
    end
    return ct == 1 or ct == 5
end

local function ResolveItemOrSpec(uidOrSpec)
    if type(uidOrSpec) == "table" then
        return uidOrSpec
    end
    local uid = tonumber(uidOrSpec) or 0
    if uid <= 0 then
        return nil
    end
    if StockPiler.Inventory and StockPiler.Inventory.ForEachItem then
        local found = nil
        StockPiler.Inventory.ForEachItem(function(item)
            if found == nil and (tonumber(item and item.uniqueID) or 0) == uid then
                found = item
            end
        end)
        if type(found) == "table" then
            return found
        end
    end
    if StockPiler.Items and StockPiler.Items.AsItemData then
        return StockPiler.Items.AsItemData(uid)
    end
    if StockPiler.Items and StockPiler.Items.ToSpec then
        return StockPiler.Items.ToSpec(uid)
    end
    return nil
end

--- Dump apo ProductKey + Matches for one or two bag/learned uids (butcher twin check).
function MS.DumpFingerprintCompare(uidA, uidB, emit)
    emit = type(emit) == "function" and emit or function() end
    emit("=== StockPiler fingerprint ===")
    local a = ResolveItemOrSpec(uidA)
    local b = (uidB ~= nil and tostring(uidB) ~= "") and ResolveItemOrSpec(uidB) or nil
    if type(a) ~= "table" then
        emit("  A missing uid=" .. tostring(uidA))
        emit("=== end fingerprint ===")
        return
    end
    local productA = MS.AsApothecaryProduct(a, nil)
    local keyA = type(productA) == "table" and MS.Key(productA) or ""
    emit(string.format(
        "  A uid=%s name=%s key=%s",
        tostring(tonumber(a.uniqueID) or tonumber(a.uid) or uidA),
        MS.Label(productA or a),
        keyA
    ))
    if type(b) ~= "table" then
        emit("=== end fingerprint ===")
        return
    end
    local productB = MS.AsApothecaryProduct(b, nil)
    local keyB = type(productB) == "table" and MS.Key(productB) or ""
    emit(string.format(
        "  B uid=%s name=%s key=%s",
        tostring(tonumber(b.uniqueID) or tonumber(b.uid) or uidB),
        MS.Label(productB or b),
        keyB
    ))
    local matches = MS.ProductMatches(a, productB or b) == true
        or MS.ProductMatches(b, productA or a) == true
    emit(string.format(
        "  ProductMatches=%s sameKey=%s",
        tostring(matches),
        tostring(keyA ~= "" and keyA == keyB)
    ))
    emit("=== end fingerprint ===")
end
