----------------------------------------------------------------
-- StockPiler Knowledge/MaterialExceptions - data overrides for
-- engine quirks (false isRefinable, identity bonus ignore, ...).
-- Prefer uid / learned sticky flags; name/desc rules as fallback.
----------------------------------------------------------------

StockPiler = StockPiler or {}
StockPiler.MaterialExceptions = StockPiler.MaterialExceptions or {}
local ME = StockPiler.MaterialExceptions

local function ToNarrow(value)
    return StockPiler.Util.ToNarrow(value)
end

----------------------------------------------------------------
-- Built-in: engine marks these isRefinable but convert never yields seeds.
-- Uids from bag dump 2026-09-16 (Whole Lotta / Special Squig Bits).
----------------------------------------------------------------

ME.FORCE_NOT_REFINABLE_UID = {
    [3030247] = true, -- Whole Lotta Squig Bits (175 multiplier)
    [3030248] = true, -- Special Squig Bits (200 multiplier)
}

----------------------------------------------------------------
-- Hybrid / liniment-ingredient mains ("very special ingredient").
-- From waremu GraphQL probe 2026-09-16 (tools/waremu_special_mats_probe.py).
----------------------------------------------------------------

ME.SPECIAL_APO_MAIN_UID = {
    [100291] = true, -- Kurnous' Sapling Essence
    [199851] = true, [199852] = true, [199853] = true, [199854] = true,
    [199855] = true, [199856] = true, [199857] = true, [199858] = true,
    [199859] = true, [199860] = true, [199861] = true, [199862] = true,
    [1000275] = true, [1000276] = true, [1000278] = true, [1000279] = true,
    [1000280] = true, [1000281] = true, [1000282] = true, [1000283] = true,
    [1000284] = true, [1000285] = true,
    [1000286] = true, [1000287] = true, [1000288] = true, [1000289] = true,
    [1000290] = true, [1000291] = true, [1000292] = true,
    [1000293] = true, [1000294] = true, [1000295] = true, [1000296] = true,
    [1000297] = true,
    [1000300] = true, [1000301] = true, [1000302] = true, [1000303] = true,
    [1000305] = true, [1000306] = true,
    [1000307] = true, [1000308] = true, [1000309] = true, [1000310] = true,
    [1000311] = true, [1000312] = true,
}

--- Identity: omit these craftingBonus refs from MS.Key so Fabricated vs
--- Artisan's Glass Vial (DESTROY_ON_FAIL / br=15) share demand/buy keys, and
--- so board snapshots that include TYPE/CRAFTING_FAMILY match FromItemData keys
--- (those refs are already stripped when parsing bag/learned items).
local identityIgnoreBonusRefs
function ME.IdentityIgnoreBonusRefs()
    if type(identityIgnoreBonusRefs) == "table" then
        return identityIgnoreBonusRefs
    end
    local B = StockPiler.MaterialSpec and StockPiler.MaterialSpec.CraftBonusRefs
        and StockPiler.MaterialSpec.CraftBonusRefs()
    local destroy = (B and B.DESTROY_ON_FAIL) or 15
    local family = (B and B.CRAFTING_FAMILY) or 5
    local typ = (B and B.TYPE) or 8
    identityIgnoreBonusRefs = { [destroy] = true, [family] = true, [typ] = true }
    return identityIgnoreBonusRefs
end

--- Name fallback only when uid unknown - Squig Bits butcher family.
function ME.NameLooksForceNotRefinable(name)
    local n = string.lower(ToNarrow(name))
    if n == "" then
        return false
    end
    return string.find(n, "squig bits", 1, true) ~= nil
        or string.find(n, "special squig", 1, true) ~= nil
end

--- Description: hybrid / liniment special apo mains (waremu "very special ingredient").
function ME.DescLooksSpecialApoMain(description)
    local d = string.lower(ToNarrow(description))
    if d == "" then
        return false
    end
    if string.find(d, "very special ingredient", 1, true) then
        return true
    end
    if string.find(d, "create liniment", 1, true)
        or string.find(d, "create a liniment", 1, true)
        or string.find(d, "create hybrid potion", 1, true)
    then
        return true
    end
    return false
end

--- Liniment-ingredient (not hybrid) - used to tag learned potions.
function ME.DescLooksLinimentIngredient(description)
    local d = string.lower(ToNarrow(description))
    if d == "" then
        return false
    end
    return string.find(d, "liniment", 1, true) ~= nil
        and (
            string.find(d, "very special ingredient", 1, true)
            or string.find(d, "create", 1, true)
        )
end

--- Name fallback when description unavailable (Daemonic / Vale / Primal / Grace).
function ME.NameLooksSpecialApoMain(name)
    local n = string.lower(ToNarrow(name))
    if n == "" then
        return false
    end
    if string.find(n, "khornish", 1, true) or string.find(n, "daemonic", 1, true) then
        return true
    end
    if string.find(n, "vale's", 1, true)
        or string.find(n, "grace of the vale", 1, true)
        or string.find(n, "kurnous", 1, true)
    then
        return true
    end
    -- Primal * hybrid mains (not Primal Zoic Gore stabilizer / debris).
    if string.find(n, "primal ", 1, true) then
        if string.find(n, "zoic", 1, true)
            or string.find(n, "debris", 1, true)
            or string.find(n, "slag", 1, true)
            or string.find(n, "ash", 1, true)
        then
            return false
        end
        return string.find(n, "affinity", 1, true)
            or string.find(n, "defence", 1, true)
            or string.find(n, "defense", 1, true)
            or string.find(n, "strength", 1, true)
            or string.find(n, "vision", 1, true)
            or string.find(n, "hunger", 1, true)
            or string.find(n, "grace", 1, true)
            or string.find(n, "alacrity", 1, true)
            or string.find(n, "nature", 1, true)
            or string.find(n, "frenzy", 1, true)
            or string.find(n, "calling", 1, true)
    end
    if string.find(n, " powder", 1, true) or string.match(n, "powder$") then
        -- Blood liniment powders (not Powdery Gold Dust talisman mats).
        if string.find(n, "gold dust", 1, true) then
            return false
        end
        return true
    end
    return false
end

local function UidFrom(specOrItem)
    if type(specOrItem) == "number" then
        return tonumber(specOrItem) or 0
    end
    if type(specOrItem) ~= "table" then
        return 0
    end
    return tonumber(specOrItem.uniqueID)
        or tonumber(specOrItem.uid)
        or tonumber(specOrItem.boundUid)
        or tonumber(specOrItem.id)
        or 0
end

local function NameFrom(specOrItem)
    if type(specOrItem) ~= "table" then
        return ""
    end
    local n = specOrItem.name
    if n ~= nil and ToNarrow(n) ~= "" then
        return n
    end
    local uid = UidFrom(specOrItem)
    if uid > 0 and StockPiler.Items and StockPiler.Items.GetByUid then
        local row = StockPiler.Items.GetByUid(uid)
        if type(row) == "table" then
            return row.name
        end
    end
    return ""
end

local function DescriptionFrom(specOrItem)
    if type(specOrItem) ~= "table" then
        return ""
    end
    local desc = specOrItem.description or specOrItem.desc or specOrItem.descriptionNarrow
    if desc ~= nil and ToNarrow(desc) ~= "" then
        return desc
    end
    local uid = UidFrom(specOrItem)
    if uid > 0 and StockPiler.Items and StockPiler.Items.GetByUid then
        local row = StockPiler.Items.GetByUid(uid)
        if type(row) == "table" then
            local rd = row.description or row.descriptionNarrow
            if rd ~= nil and ToNarrow(rd) ~= "" then
                return rd
            end
        end
    end
    if uid > 0 and type(GetDatabaseItemData) == "function" then
        local ok, data = pcall(GetDatabaseItemData, uid)
        if ok and type(data) == "table" and data.description ~= nil then
            return data.description
        end
    end
    return ""
end

--- True for hybrid / liniment special apo mains (uid catalog, description, or name).
function ME.LooksSpecialApoMain(specOrItem)
    local uid = UidFrom(specOrItem)
    if uid > 0 and ME.SPECIAL_APO_MAIN_UID[uid] == true then
        return true
    end
    if ME.DescLooksSpecialApoMain(DescriptionFrom(specOrItem)) then
        return true
    end
    return ME.NameLooksSpecialApoMain(NameFrom(specOrItem))
end

function ME.LooksLinimentIngredient(specOrItem)
    local uid = UidFrom(specOrItem)
    if uid > 0 and ME.SPECIAL_APO_MAIN_UID[uid] == true then
        if ME.DescLooksLinimentIngredient(DescriptionFrom(specOrItem)) then
            return true
        end
        -- Catalog liniment mains: powders / Vale / Daemonic / Kurnous / Grace (not hybrid plants).
        local n = string.lower(ToNarrow(NameFrom(specOrItem)))
        if string.find(n, "powder", 1, true)
            or string.find(n, "vale", 1, true)
            or string.find(n, "kurnous", 1, true)
            or string.find(n, "grace", 1, true)
            or string.find(n, "daemonic", 1, true)
            or string.find(n, "khornish", 1, true)
        then
            return true
        end
        return false
    end
    return ME.DescLooksLinimentIngredient(DescriptionFrom(specOrItem))
end

--- Sticky Account override after observed failed convert (or built-in seed).
function ME.MarkForceNotRefinable(uid, reason)
    uid = tonumber(uid) or 0
    if uid <= 0 then
        return
    end
    ME.FORCE_NOT_REFINABLE_UID[uid] = true
    if StockPiler.Items and StockPiler.Items.GetByUid then
        local row = StockPiler.Items.GetByUid(uid)
        if type(row) == "table" then
            row.forceNotRefinable = true
            row.isRefinable = false
            if reason then
                row.forceNotRefinableReason = tostring(reason)
            end
        end
    end
end

--- True when engine isRefinable must be ignored (not a plant->seed convert).
function ME.IsForceNotRefinable(specOrItem)
    local uid = UidFrom(specOrItem)
    if uid > 0 then
        if ME.FORCE_NOT_REFINABLE_UID[uid] == true then
            return true
        end
        if ME.SPECIAL_APO_MAIN_UID[uid] == true then
            return true
        end
        if StockPiler.Items and StockPiler.Items.GetByUid then
            local row = StockPiler.Items.GetByUid(uid)
            if type(row) == "table" and row.forceNotRefinable == true then
                return true
            end
            -- Legacy sticky from refine-fail path.
            if type(row) == "table" and row.refineConvertFailed == true then
                local n = string.lower(ToNarrow(row.name))
                if ME.NameLooksForceNotRefinable(n) or ME.FORCE_NOT_REFINABLE_UID[uid] then
                    return true
                end
            end
        end
    end
    if ME.LooksSpecialApoMain(specOrItem) then
        return true
    end
    return ME.NameLooksForceNotRefinable(NameFrom(specOrItem))
end

function ME.ShouldIgnoreBonusRef(ref)
    ref = tonumber(ref) or 0
    if ref <= 0 then
        return false
    end
    local ignore = ME.IdentityIgnoreBonusRefs()
    return type(ignore) == "table" and ignore[ref] == true
end
