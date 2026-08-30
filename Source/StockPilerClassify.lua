----------------------------------------------------------------
-- Classify potions by effect (PotionBar-compatible).
-- Prefer PotionBar.getValues when that addon is loaded; otherwise mirror
-- PotionBar's English ability-description rules for the families we track.
----------------------------------------------------------------

StockPiler.Classify = StockPiler.Classify or {}

-- StockPiler effectKey <-> PotionBar.Type.Name
local EFFECT_TO_PB = {
    str = "STRENGTH",
    int = "INTELLIGENCE",
    wp = "WILLPOWER",
    bs = "BALLISTIC",
    tou = "TOUGHNESS",
    armor = "ARMOR",
    absorb = "SHIELD",
    heal = "HEAL",
    hot = "REGEN",
    ap = "AP",
}

local PB_TO_EFFECT = {}
for effectKey, pbName in pairs(EFFECT_TO_PB) do
    PB_TO_EFFECT[pbName] = effectKey
end

local function ToNarrow(name)
    if name == nil then
        return ""
    end
    if type(name) == "wstring" then
        local ok, s = pcall(WStringToString, name)
        if ok and s then
            return s
        end
        return ""
    end
    return tostring(name)
end

local function GetNumbers(aString, count)
    if not count or type(aString) ~= "string" then
        return
    end
    local y = 0
    local results = {}
    for i = 1, count do
        if i > 1 then
            y = y + 1
        end
        local x
        x, y = string.find(aString, "%d+", y)
        if not x then
            return
        end
        results[i] = tonumber(string.sub(aString, x, y))
    end
    return unpack(results)
end

--- Local EN classifier (same idea as PotionBar.getValuesEN).
local function ClassifyFromDescription(name, description)
    if type(description) ~= "string" or description == "" then
        return nil
    end
    name = name or ""

    if string.find(description, "Instantly restores %d+") then
        if string.find(description, "Action Points") then
            return "ap"
        end
        if string.find(description, "health") then
            return "heal"
        end
    end
    if string.find(description, "Heals for %d+ every %d+ seconds, for %d+ seconds.")
        or string.find(description, "Gradually restores %d+ health over %d+ seconds.")
    then
        return "hot"
    end
    if string.find(description, "Absorbs %d+ damage over the next %d+ seconds.")
        or string.find(description, "Surrounds you with a magical barrier for up to %d+ seconds which will absorb up to %d+ damage.")
    then
        return "absorb"
    end
    if string.find(description, "Increases [%a%s]+ by %d+ for %d+ minutes.") then
        if string.find(description, "Strength") then
            return "str"
        end
        if string.find(description, "Intelligence") then
            return "int"
        end
        if string.find(description, "Ballistic Skill") then
            return "bs"
        end
        if string.find(description, "Willpower") then
            return "wp"
        end
        if string.find(description, "Toughness") then
            return "tou"
        end
        if string.find(description, "Armor") then
            return "armor"
        end
    end
    return nil
end

local function AbilityIdFromItem(itemData)
    if type(itemData) ~= "table" or type(itemData.bonus) ~= "table" then
        return nil
    end
    local b1 = itemData.bonus[1]
    if type(b1) == "table" and b1.reference then
        return b1.reference
    end
    for _, bonusData in ipairs(itemData.bonus) do
        if type(bonusData) == "table" and bonusData.reference then
            if GameDefs and GameDefs.ITEMBONUS_USE and bonusData.type == GameDefs.ITEMBONUS_USE then
                return bonusData.reference
            end
            if bonusData.type == 3 then
                return bonusData.reference
            end
        end
    end
    return nil
end

function StockPiler.Classify.IsPotionItem(itemData)
    if type(itemData) ~= "table" then
        return false
    end
    if GameData and GameData.ItemTypes and GameData.ItemTypes.POTION then
        return itemData.type == GameData.ItemTypes.POTION
    end
    -- Fallback: name heuristics
    local n = string.lower(ToNarrow(itemData.name))
    return string.find(n, "potion", 1, true)
        or string.find(n, "draught", 1, true)
        or string.find(n, "elixir", 1, true)
        or string.find(n, "unguent", 1, true)
        or string.find(n, "liniment", 1, true)
        or string.find(n, "liquid", 1, true)
end

--- Returns StockPiler effectKey (str/int/armor/...) or nil.
function StockPiler.Classify.GetEffectKey(itemData)
    if type(itemData) ~= "table" then
        return nil
    end

    -- Prefer PotionBar when present (handles more edge cases / languages)
    if PotionBar and type(PotionBar.getValues) == "function" then
        local abilityId = AbilityIdFromItem(itemData)
        if abilityId then
            local ok, _value, _dur, pbType = pcall(
                PotionBar.getValues,
                abilityId,
                itemData.iLevel or itemData.level or 1,
                itemData.name,
                itemData.uniqueID
            )
            if ok and pbType and pbType ~= 0 then
                local pbName = nil
                if PotionBar.Type and type(PotionBar.Type[pbType]) == "table" then
                    pbName = PotionBar.Type[pbType].Name
                end
                if pbName and PB_TO_EFFECT[pbName] then
                    return PB_TO_EFFECT[pbName]
                end
            end
        end
    end

    local abilityId = AbilityIdFromItem(itemData)
    local description = ""
    if abilityId and type(GetAbilityDescription) == "function" then
        local ok, desc = pcall(GetAbilityDescription, abilityId, itemData.iLevel or itemData.level or 1)
        if ok and desc then
            description = ToNarrow(desc)
        end
    end
    if description == "" and itemData.description then
        description = ToNarrow(itemData.description)
    end

    return ClassifyFromDescription(ToNarrow(itemData.name), description)
end

local function ParseStatsFromDescription(description)
    if type(description) ~= "string" or description == "" then
        return 0, 0, false
    end
    local value, duration = 0, 0
    local instant = false

    if string.find(description, "Instantly restores %d+") then
        value = GetNumbers(description, 1) or 0
        instant = true
        return value, 0, instant
    end
    if string.find(description, "Heals for %d+ every %d+ seconds, for %d+ seconds.") then
        local tick, interval, total = GetNumbers(description, 3)
        if tick and interval and total and interval > 0 then
            value = tick * (total / interval)
            duration = total
        end
        return value or 0, duration, false
    end
    if string.find(description, "Gradually restores %d+ health over %d+ seconds.") then
        value, duration = GetNumbers(description, 2)
        return value or 0, duration or 0, false
    end
    if string.find(description, "Absorbs %d+ damage over the next %d+ seconds.") then
        value, duration = GetNumbers(description, 2)
        return value or 0, duration or 0, false
    end
    if string.find(description, "Surrounds you with a magical barrier for up to %d+ seconds which will absorb up to %d+ damage.") then
        duration, value = GetNumbers(description, 2)
        return value or 0, duration or 0, false
    end
    if string.find(description, "Increases [%a%s]+ by %d+ for %d+ minutes.") then
        value, duration = GetNumbers(description, 2)
        if duration then
            duration = duration * 60
        end
        return value or 0, duration or 0, false
    end
    return 0, 0, false
end

--- Minimum rank (iLevel), buff magnitude, duration seconds, instant flag.
function StockPiler.Classify.GetPotionStats(itemData, catalogEntry)
    if type(itemData) ~= "table" then
        return 0, 0, 0, false
    end

    local minRank = tonumber(itemData.iLevel) or 0
    if minRank <= 0 then
        minRank = tonumber(itemData.level) or 0
    end

    local abilityId = AbilityIdFromItem(itemData)
    local level = itemData.iLevel or itemData.level or 1
    if level <= 0 then
        level = 1
    end
    local name = itemData.name
    local uniqueID = itemData.uniqueID

    if PotionBar and type(PotionBar.getValues) == "function" and abilityId then
        local ok, potionV, potionD = pcall(
            PotionBar.getValues,
            abilityId,
            level,
            name,
            uniqueID
        )
        if ok then
            local buffValue = tonumber(potionV) or 0
            local durationSec = tonumber(potionD) or 0
            local description = ""
            if type(GetAbilityDescription) == "function" then
                local descOk, desc = pcall(GetAbilityDescription, abilityId, level)
                if descOk and desc then
                    description = ToNarrow(desc)
                end
            end
            local instant = string.find(description, "Instantly restores", 1, true) ~= nil
            return minRank, buffValue, durationSec, instant
        end
    end

    local description = ""
    if abilityId and type(GetAbilityDescription) == "function" then
        local ok, desc = pcall(GetAbilityDescription, abilityId, level)
        if ok and desc then
            description = ToNarrow(desc)
        end
    end
    if description == "" and itemData.description then
        description = ToNarrow(itemData.description)
    end

    local buffValue, durationSec, instant = ParseStatsFromDescription(description)
    return minRank, buffValue, durationSec, instant
end

function StockPiler.Classify.FormatDuration(seconds)
    seconds = tonumber(seconds) or 0
    if seconds <= 0 then
        return L""
    end
    if seconds >= 60 and seconds % 60 == 0 then
        return towstring(tostring(seconds / 60)) .. L"m"
    end
    return towstring(tostring(seconds)) .. L"s"
end

function StockPiler.Classify.EffectKeyToPotionBarName(effectKey)
    return EFFECT_TO_PB[effectKey]
end

function StockPiler.Classify.PotionBarAvailable()
    return PotionBar ~= nil and type(PotionBar.getValues) == "function"
end
