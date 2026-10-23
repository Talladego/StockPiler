----------------------------------------------------------------
-- StockPiler Knowledge/RecipeSpec - learned brew fingerprints + craft counts
-- Callees above callers (RoR Lua has no local hoist).
----------------------------------------------------------------

StockPiler = StockPiler or {}
StockPiler.RecipeSpec = StockPiler.RecipeSpec or {}
local RS = StockPiler.RecipeSpec

local ROLE_ORDER = {
    container = 1,
    main = 2,
    stabilizer = 3,
    goldweed = 3,
    extender = 4,
    multiplier = 5,
    stimulant = 5,
    ingredient = 6,
}

local CRAFT_BONUS = {
    STABILITY = 1,
    POWER = 2,
    DURATION = 3,
    MULTIPLIER = 4,
    SPECIAL_CHANCE = 14,
}

----------------------------------------------------------------
-- Account / narrow helpers
----------------------------------------------------------------

local function ToNarrow(text)
    return StockPiler.Util.ToNarrow(text)
end

--- Prefer Account tables directly so migrate/hydrate never re-enter EnsureAccount.
local function RecipesTable()
    local acct = StockPiler.Account
    if type(acct) == "table" then
        if type(acct.recipes) ~= "table" then
            acct.recipes = {}
        end
        return acct.recipes
    end
    if StockPiler.Knowledge and StockPiler.Knowledge.Recipes then
        return StockPiler.Knowledge.Recipes()
    end
    return nil
end

local function PotionsTable()
    local acct = StockPiler.Account
    if type(acct) == "table" then
        if type(acct.potions) ~= "table" then
            acct.potions = {}
        end
        return acct.potions
    end
    if StockPiler.Knowledge and StockPiler.Knowledge.Potions then
        return StockPiler.Knowledge.Potions()
    end
    return nil
end

local function CharacterRow()
    return StockPiler.Util.CharacterRow(false)
end

local function MS()
    return StockPiler.MaterialSpec
end

local function SpecFingerprint(spec, boundUid)
    if type(spec) ~= "table" then
        return ""
    end
    local M = MS()
    -- Recipe storage identity is UID-agnostic (Scale/Chitin twins, TYPE/FAMILY noise).
    if M and M.RecipeIdentityKey then
        local key = M.RecipeIdentityKey(spec, boundUid)
        if key ~= nil and key ~= "" then
            return key
        end
    end
    local uid = tonumber(boundUid) or tonumber(spec.boundUid) or 0
    if spec.incomplete == true then
        if uid <= 0 then
            uid = tonumber(spec.uid) or 0
        end
        if M and M.Key then
            return M.Key(spec, uid, { omitUid = true })
        end
        if uid > 0 then
            return "uid:" .. tostring(uid)
        end
    end
    if M and M.Key then
        return M.Key(spec, nil)
    end
    if M and M.ProductKey then
        return M.ProductKey(spec) or ""
    end
    return string.format(
        "r:%s|p:%d|s:%d",
        tostring(spec.role or "?"),
        tonumber(spec.power) or 0,
        tonumber(spec.stability) or 0
    )
end

local function BonusValue(spec, ref)
    if type(spec) ~= "table" then
        return 0
    end
    if type(spec.bonuses) == "table" then
        local v = spec.bonuses[ref]
        if type(v) == "table" then
            return tonumber(v[1]) or 0
        end
        return tonumber(v) or 0
    end
    if ref == CRAFT_BONUS.POWER then
        return tonumber(spec.power) or 0
    end
    if ref == CRAFT_BONUS.STABILITY then
        return tonumber(spec.stability) or 0
    end
    if ref == CRAFT_BONUS.DURATION then
        return tonumber(spec.duration) or 0
    end
    return 0
end

local function StabilityOf(spec)
    return BonusValue(spec, CRAFT_BONUS.STABILITY)
end

----------------------------------------------------------------
-- Slot hydrate / slim (callees first)
----------------------------------------------------------------

local function SpecShowsBonus(spec)
    local MS = MS()
    if MS and MS.SpecShowsBonus then
        return MS.SpecShowsBonus(spec) == true
    end
    return false
end

local function UpgradeSlotFromBag(uid)
    uid = tonumber(uid) or 0
    if uid <= 0 or not (StockPiler.Items and StockPiler.Items.StoreItem and StockPiler.Items.ToSpec) then
        return nil
    end
    local Inv = StockPiler.Inventory
    local sample = Inv and Inv.GetSample and Inv.GetSample(uid) or nil
    if type(sample) ~= "table" or type(sample.craftingBonus) ~= "table" then
        return nil
    end
    if next(sample.craftingBonus) == nil then
        return nil
    end
    StockPiler.Items.StoreItem(sample, "mat")
    return StockPiler.Items.ToSpec(uid)
end

local function ResolveSlotSpec(slot)
    if type(slot) ~= "table" then
        return nil
    end
    local uid = tonumber(slot.uid) or 0
    if type(slot.spec) == "table" then
        uid = uid > 0 and uid or (tonumber(slot.spec.uid) or tonumber(slot.spec.uniqueID) or 0)
    end
    -- Prefer live Items.ToSpec so incomplete/zero brew-learn stubs get real bonuses.
    if uid > 0 and StockPiler.Items and StockPiler.Items.ToSpec then
        local live = StockPiler.Items.ToSpec(uid)
        if type(live) ~= "table" or not SpecShowsBonus(live) then
            live = UpgradeSlotFromBag(uid) or live
        end
        if type(live) == "table" then
            if type(slot.spec) == "table" and slot.spec.role and (not live.role or live.role == "ingredient") then
                live.role = slot.spec.role or slot.role or live.role
            elseif slot.role and (not live.role or live.role == "ingredient") then
                live.role = slot.role
            end
            if live.incomplete == true then
                live.boundUid = tonumber(slot.uid) or tonumber(live.boundUid) or uid
            end
            -- Prefer recipe-slot role over classifier guess.
            if slot.role then
                live.role = slot.role
            end
            slot.spec = live
            return live
        end
    end
    if type(slot.spec) == "table" then
        if slot.spec.incomplete == true and (tonumber(slot.spec.boundUid) or 0) <= 0 then
            slot.spec.boundUid = tonumber(slot.uid) or tonumber(slot.spec.uid) or nil
        end
        return slot.spec
    end
    return nil
end

local function CollectSlotBuckets(slots)
    local buckets = {}
    local index = {}
    if type(slots) ~= "table" then
        return buckets
    end
    for i = 1, #slots do
        local slot = slots[i]
        if type(slot) == "table" then
            local spec = ResolveSlotSpec(slot)
            if type(spec) == "table" then
                local role = tostring(slot.role or spec.role or "")
                local boundUid = 0
                if spec.incomplete == true then
                    boundUid = tonumber(slot.uid)
                        or tonumber(slot.boundUid)
                        or tonumber(spec.boundUid)
                        or tonumber(spec.uid)
                        or 0
                end
                local fp = SpecFingerprint(spec, boundUid)
                local k = role .. "\0" .. fp
                local idx = index[k]
                local per = math.max(1, tonumber(slot.perCraft) or 1)
                if idx then
                    buckets[idx].perCraft = (tonumber(buckets[idx].perCraft) or 0) + per
                    -- Prefer an incomplete exemplar with a bound uid.
                    if buckets[idx].boundUid <= 0 and boundUid > 0 then
                        buckets[idx].boundUid = boundUid
                        buckets[idx].slot = slot
                        buckets[idx].spec = spec
                    end
                else
                    buckets[#buckets + 1] = {
                        role = role,
                        fp = fp,
                        perCraft = per,
                        boundUid = boundUid,
                        slot = slot,
                        spec = spec,
                    }
                    index[k] = #buckets
                end
            end
        end
    end
    table.sort(buckets, function(a, b)
        local oa = ROLE_ORDER[a.role] or 99
        local ob = ROLE_ORDER[b.role] or 99
        if oa ~= ob then
            return oa < ob
        end
        return tostring(a.fp) < tostring(b.fp)
    end)
    return buckets
end

local function SlimSlotsForStorage(slots)
    local slim = {}
    if type(slots) ~= "table" then
        return slim
    end
    -- Canonical: merge same-role same-fingerprint, sort by role then fingerprint.
    local buckets = CollectSlotBuckets(slots)
    for i = 1, #buckets do
        local b = buckets[i]
        local slot = b.slot
        local spec = b.spec
        local entry = {
            role = b.role,
            uid = tonumber(slot and slot.uid) or (b.boundUid > 0 and b.boundUid) or nil,
            perCraft = math.max(1, tonumber(b.perCraft) or 1),
        }
        if type(spec) == "table" and spec.incomplete == true then
            entry.boundUid = b.boundUid > 0 and b.boundUid or entry.uid
        elseif b.boundUid > 0 then
            entry.boundUid = b.boundUid
        end
        if type(spec) == "table" then
            entry.spec = {
                uid = tonumber(spec.uid) or entry.uid,
                role = spec.role or entry.role,
                power = tonumber(spec.power) or 0,
                stability = tonumber(spec.stability) or 0,
                duration = tonumber(spec.duration) or 0,
                tradeSkill = tonumber(spec.tradeSkill) or 0,
                skillLevel = tonumber(spec.skillLevel) or 0,
                cultivationType = tonumber(spec.cultivationType) or 0,
                slotType = tonumber(spec.slotType) or 0,
                effectId = spec.effectId,
                bonuses = type(spec.bonuses) == "table" and spec.bonuses or nil,
                incomplete = spec.incomplete == true,
                boundUid = entry.boundUid,
            }
            if spec.isRefinable ~= nil then
                entry.spec.isRefinable = spec.isRefinable == true
            end
        end
        slim[#slim + 1] = entry
    end
    return slim
end

local function PotionEffectIdForUid(uid)
    uid = tonumber(uid) or 0
    if uid <= 0 then
        return 0
    end
    local MS = StockPiler.MaterialSpec
    local effectKey = nil
    if RS.GetPotion then
        local potion = RS.GetPotion(uid)
        if type(potion) == "table" and type(potion.effectKey) == "string" then
            effectKey = potion.effectKey
        end
    end
    if (type(effectKey) ~= "string" or effectKey == "") and StockPiler.Classify and StockPiler.Classify.GetEffectKey then
        local probe = nil
        if StockPiler.Items and StockPiler.Items.AsItemData then
            probe = StockPiler.Items.AsItemData(uid)
        end
        if type(probe) ~= "table" then
            probe = { uniqueID = uid }
        end
        effectKey = StockPiler.Classify.GetEffectKey(probe)
    end
    if type(effectKey) ~= "string" or effectKey == "" or not (MS and MS.EffectIdFromKey) then
        return 0
    end
    local norm = effectKey
    if RS.NormalizeEffectKeyForUi then
        norm = RS.NormalizeEffectKeyForUi(effectKey) or effectKey
    end
    return tonumber(MS.EffectIdFromKey(norm)) or 0
end

local function RecipeOutcomeEffectIdSet(recipe)
    local ids = {}
    local n = 0
    if type(recipe) ~= "table" or type(recipe.outcomes) ~= "table" then
        return ids, n
    end
    for uidKey in pairs(recipe.outcomes) do
        local eid = PotionEffectIdForUid(uidKey)
        if eid > 0 and ids[eid] ~= true then
            ids[eid] = true
            n = n + 1
        end
    end
    return ids, n
end

local function UnlinkPotionRecipeKey(potionUid, recipeKey)
    recipeKey = tostring(recipeKey or "")
    potionUid = tonumber(potionUid) or 0
    if potionUid <= 0 or recipeKey == "" or not RS.GetPotion then
        return
    end
    local potion = RS.GetPotion(potionUid)
    if type(potion) ~= "table" then
        return
    end
    local function scrubList(list)
        if type(list) ~= "table" then
            return
        end
        local nextList = {}
        for i = 1, #list do
            local k = tostring(list[i] or "")
            if k ~= "" and k ~= recipeKey then
                nextList[#nextList + 1] = k
            end
        end
        return nextList
    end
    if type(potion.recipeKeys) == "table" then
        potion.recipeKeys = scrubList(potion.recipeKeys)
    end
    for _, field in ipairs({ "activeRecipeKey", "activeRecipeSpecKey", "recipeSpecKey" }) do
        if tostring(potion[field] or "") == recipeKey then
            local keys = potion.recipeKeys
            potion[field] = (type(keys) == "table" and keys[1]) or nil
        end
    end
end

--- Drop outcomes whose potion EFFECT disagrees with the stamped main EFFECT.
--- Fixes incomplete-fingerprint pollution (WP Conviction / armor Unguent on snare).
local function PruneOutcomesMismatchedToMainEffect(recipe)
    if type(recipe) ~= "table" or type(recipe.outcomes) ~= "table" or type(recipe.slots) ~= "table" then
        return 0
    end
    local mainEffectId = 0
    for i = 1, #recipe.slots do
        local spec = ResolveSlotSpec(recipe.slots[i])
        if type(spec) == "table" and tostring(spec.role or "") == "main" then
            mainEffectId = tonumber(spec.effectId) or 0
            if mainEffectId <= 0 and type(spec.bonuses) == "table" then
                local MS = StockPiler.MaterialSpec
                local B = MS and MS.CraftBonusRefs and MS.CraftBonusRefs()
                local effectRef = (B and B.EFFECT) or 6
                mainEffectId = tonumber(spec.bonuses[effectRef]) or 0
            end
            if mainEffectId > 0 then
                break
            end
        end
    end
    if mainEffectId <= 0 then
        return 0
    end
    local recipeKey = tostring(recipe.recipeSpecKey or "")
    local pruned = 0
    local drop = {}
    for uidKey in pairs(recipe.outcomes) do
        local eid = PotionEffectIdForUid(uidKey)
        if eid > 0 and eid ~= mainEffectId then
            drop[#drop + 1] = uidKey
        end
    end
    for i = 1, #drop do
        local uidKey = drop[i]
        recipe.outcomes[uidKey] = nil
        UnlinkPotionRecipeKey(uidKey, recipeKey)
        pruned = pruned + 1
        local uidNum = tonumber(uidKey) or 0
        if uidNum > 0 then
            if tonumber(recipe.activeOutcomeUid) == uidNum then
                recipe.activeOutcomeUid = nil
            end
            if tonumber(recipe.outputUid) == uidNum then
                recipe.outputUid = nil
            end
        end
    end
    if recipe.activeOutcomeUid == nil or recipe.outputUid == nil then
        for uidKey, oc in pairs(recipe.outcomes) do
            if type(oc) == "table" then
                local uidNum = tonumber(uidKey) or 0
                if uidNum > 0 then
                    if recipe.activeOutcomeUid == nil then
                        recipe.activeOutcomeUid = uidNum
                    end
                    if recipe.outputUid == nil then
                        recipe.outputUid = uidNum
                    end
                    break
                end
            end
        end
    end
    return pruned
end

--- Stamp EFFECT onto incomplete main slots.
--- Prefer bound-main description (Viscous Rat Spittle → snare). Potion Use/name is
--- fallback only when outcomes are not multi-effect polluted.
local function StampIncompleteMainEffect(recipe)
    if type(recipe) ~= "table" or type(recipe.slots) ~= "table" then
        return
    end
    local MS = StockPiler.MaterialSpec
    local B = MS and MS.CraftBonusRefs and MS.CraftBonusRefs()
    local effectRef = (B and B.EFFECT) or 6
    local effectId = 0

    -- 1) Bound main item (description / Items) — authoritative for glue/snare stubs.
    if MS and MS.ResolveMainEffectId then
        for i = 1, #recipe.slots do
            local slot = recipe.slots[i]
            local spec = ResolveSlotSpec(slot)
            if type(spec) == "table" and tostring(spec.role or slot.role or "") == "main" then
                local boundUid = tonumber(spec.boundUid) or tonumber(spec.uid) or tonumber(slot and slot.uid) or 0
                local probe = nil
                if boundUid > 0 and StockPiler.Items then
                    if StockPiler.Items.GetByUid then
                        probe = StockPiler.Items.GetByUid(boundUid)
                    end
                    if type(probe) ~= "table" and StockPiler.Items.AsItemData then
                        probe = StockPiler.Items.AsItemData(boundUid)
                    end
                end
                if type(probe) ~= "table" and boundUid > 0 then
                    probe = { uniqueID = boundUid }
                end
                if type(probe) == "table" then
                    effectId = tonumber(MS.ResolveMainEffectId(probe, spec.bonuses)) or 0
                    if effectId > 0 then
                        break
                    end
                end
            end
        end
    end

    -- 2) Potion fallback — skip when outcomes disagree on EFFECT (collision fingerprint).
    if effectId <= 0 then
        local _, outcomeEffectCount = RecipeOutcomeEffectIdSet(recipe)
        local effectKey = recipe.effectKey
        if outcomeEffectCount <= 1 and (type(effectKey) ~= "string" or effectKey == "") then
            local outUid = tonumber(recipe.activeOutcomeUid) or tonumber(recipe.outputUid) or 0
            if outUid > 0 then
                effectId = PotionEffectIdForUid(outUid)
            end
        elseif outcomeEffectCount <= 1 and type(effectKey) == "string" and effectKey ~= "" and MS and MS.EffectIdFromKey then
            local norm = effectKey
            if RS.NormalizeEffectKeyForUi then
                norm = RS.NormalizeEffectKeyForUi(effectKey) or effectKey
            end
            effectId = tonumber(MS.EffectIdFromKey(norm)) or 0
        end
    end

    if effectId <= 0 then
        return
    end
    for i = 1, #recipe.slots do
        local slot = recipe.slots[i]
        local spec = ResolveSlotSpec(slot)
        if type(spec) == "table"
            and tostring(spec.role or slot.role or "") == "main"
            and (spec.incomplete == true or (tonumber(spec.effectId) or 0) <= 0)
        then
            local boundUid = tonumber(spec.boundUid) or tonumber(spec.uid) or tonumber(slot and slot.uid) or 0
            if boundUid > 0 and StockPiler.Items and StockPiler.Items.StoreItem then
                local skipKey = tostring(boundUid) .. ":" .. tostring(effectId)
                RS._effectFallbackSkip = RS._effectFallbackSkip or {}
                if RS._effectFallbackSkip[skipKey] == true then
                    ResolveSlotSpec(slot)
                else
                local notRefinable = spec.isRefinable == false
                if spec.isRefinable == nil then
                    -- Prefer learned vendor/butcher twin refinable flag at this fingerprint.
                    local items = StockPiler.Account and StockPiler.Account.items
                    if type(items) == "table" and MS and MS.ProductMatches then
                        for uidKey, row in pairs(items) do
                            if type(row) == "table" and row.isRefinable == false then
                                local rowUid = tonumber(row.uniqueID) or tonumber(uidKey) or 0
                                local probe = row
                                if rowUid > 0 and StockPiler.Items and StockPiler.Items.AsItemData then
                                    probe = StockPiler.Items.AsItemData(rowUid) or row
                                end
                                if MS.ProductMatches(probe, spec) == true then
                                    notRefinable = true
                                    break
                                end
                            end
                        end
                    end
                end
                local learned = StockPiler.Items.GetByUid and StockPiler.Items.GetByUid(boundUid) or nil
                local craftingBonus = {}
                local function pushBonus(ref, val)
                    ref = tonumber(ref) or 0
                    if ref > 0 and val ~= nil then
                        craftingBonus[#craftingBonus + 1] = {
                            bonusReference = ref,
                            bonusValue = val,
                        }
                    end
                end
                if type(learned) == "table" and type(learned.bonuses) == "table" then
                    for ref, val in pairs(learned.bonuses) do
                        if tonumber(ref) ~= effectRef then
                            pushBonus(ref, val)
                        end
                    end
                elseif type(spec.bonuses) == "table" then
                    for ref, val in pairs(spec.bonuses) do
                        if tonumber(ref) ~= effectRef then
                            pushBonus(ref, val)
                        end
                    end
                end
                pushBonus(effectRef, effectId)
                local itemType = 0
                if type(learned) == "table" then
                    itemType = tonumber(learned.itemType) or tonumber(learned.type) or 0
                end
                if itemType <= 0 and GameData and GameData.ItemTypes then
                    itemType = tonumber(GameData.ItemTypes.CRAFTING) or 0
                end
                if itemType <= 0 then
                    itemType = 34
                end
                local payload = {
                    uniqueID = boundUid,
                    name = (type(learned) == "table" and learned.name) or spec.name,
                    craftingBonus = craftingBonus,
                    craftingSkillRequirement = (type(learned) == "table" and learned.skillReq) or spec.skillLevel,
                    tradeSkill = (type(learned) == "table" and learned.tradeSkill) or spec.tradeSkill,
                    cultivationType = (type(learned) == "table" and learned.cultivationType) or spec.cultivationType,
                    itemType = itemType,
                }
                if notRefinable then
                    payload.isRefinable = false
                end
                local stored = StockPiler.Items.StoreItem(payload, "mat")
                if type(stored) ~= "table" then
                    RS._effectFallbackSkip[skipKey] = true
                end
                ResolveSlotSpec(slot)
                end
            end
        end
    end
end

local function HydrateRecipeSlots(recipe)
    if type(recipe) ~= "table" or type(recipe.slots) ~= "table" then
        return
    end
    for i = 1, #recipe.slots do
        ResolveSlotSpec(recipe.slots[i])
    end
    StampIncompleteMainEffect(recipe)
end

--- Order-independent recipe identity: multiset of (role, SpecFingerprint) with summed perCraft.
local function SlotsFingerprint(slots)
    local buckets = CollectSlotBuckets(slots)
    local parts = {}
    for i = 1, #buckets do
        local b = buckets[i]
        parts[#parts + 1] = tostring(b.role)
            .. "x" .. tostring(b.perCraft)
            .. ":" .. tostring(b.fp)
    end
    return table.concat(parts, "|")
end

--- Merge same-role same-fingerprint slots; stable role + fingerprint order.
local function MergeSlotsByFingerprint(slots)
    local buckets = CollectSlotBuckets(slots)
    local out = {}
    for i = 1, #buckets do
        local b = buckets[i]
        local slot = b.slot
        local uid = tonumber(slot and slot.uid) or 0
        if uid <= 0 and b.boundUid > 0 then
            uid = b.boundUid
        end
        out[#out + 1] = {
            role = b.role,
            uid = uid > 0 and uid or nil,
            boundUid = b.boundUid > 0 and b.boundUid or nil,
            perCraft = math.max(1, tonumber(b.perCraft) or 1),
            spec = b.spec,
        }
    end
    return out
end

local function MaterialsToSpecSlots(materials)
    local slots = {}
    local M = MS()
    if type(materials) ~= "table" or not M or not M.FromItemData then
        return slots
    end
    for i = 1, #materials do
        local mat = materials[i]
        if type(mat) == "table" then
            local itemData = mat.itemData
            local uid = tonumber(mat.uniqueID) or 0
            if type(itemData) ~= "table" and uid > 0 and StockPiler.Inventory and StockPiler.Inventory.GetSample then
                itemData = StockPiler.Inventory.GetSample(uid)
            end
            if uid <= 0 and type(itemData) == "table" then
                uid = tonumber(itemData.uniqueID) or 0
            end
            local spec = M.FromItemData(itemData, mat.role)
            if spec == nil and uid > 0 and StockPiler.Items and StockPiler.Items.ToSpec then
                spec = StockPiler.Items.ToSpec(uid)
            end
            if type(spec) == "table" then
                if uid > 0 and StockPiler.Items and StockPiler.Items.StoreItem then
                    StockPiler.Items.StoreItem(itemData or { uniqueID = uid }, "mat")
                end
                if mat.role then
                    spec.role = mat.role
                end
                if spec.incomplete == true and uid > 0 then
                    spec.boundUid = uid
                end
                slots[#slots + 1] = {
                    role = mat.role or spec.role or "ingredient",
                    uid = uid > 0 and uid or nil,
                    boundUid = spec.boundUid,
                    spec = spec,
                    perCraft = tonumber(mat.perCraft) or 1,
                }
            end
        end
    end
    return MergeSlotsByFingerprint(slots)
end

local function SpecStabilityTotal(slots)
    local total = 0
    if type(slots) ~= "table" then
        return total
    end
    for i = 1, #slots do
        local slot = slots[i]
        local role = slot.role or ""
        if role ~= "extender" and role ~= "multiplier" and role ~= "stimulant" then
            local per = tonumber(slot.perCraft) or 1
            total = total + StabilityOf(ResolveSlotSpec(slot)) * per
        end
    end
    return total
end

--- Apo has 3 shared ingredient slots (not container/main). Multiplier/extender/stimulant
--- consume that budget; stabilizer top-ups must not crowd them out of the load.
local function ApoIngredientSlotCount()
    local first = (ApothecaryWindow and ApothecaryWindow.SLOT_INGREDIENT1) or 2
    local last = (ApothecaryWindow and ApothecaryWindow.SLOT_INGREDIENT3) or 4
    return math.max(0, last - first + 1)
end

local function NonStabilizerIngredientUnits(slots)
    local used = 0
    if type(slots) ~= "table" then
        return used
    end
    for i = 1, #slots do
        local slot = slots[i]
        if type(slot) == "table" then
            local role = tostring(slot.role or "")
            if role ~= ""
                and role ~= "container"
                and role ~= "main"
                and role ~= "stabilizer"
                and role ~= "goldweed"
            then
                used = used + math.max(1, tonumber(slot.perCraft) or 1)
            end
        end
    end
    return used
end

local function StabilizerSlotBudget(slots)
    local budget = ApoIngredientSlotCount() - NonStabilizerIngredientUnits(slots)
    if budget < 0 then
        return 0
    end
    return budget
end

--- Cap a stabilizer/goldweed slot's count so all stab roles share the apo ingredient budget.
local function CapStabilizerPerCraft(slot, slots, want)
    want = math.max(1, tonumber(want) or 1)
    if type(slot) ~= "table" or type(slots) ~= "table" then
        return want
    end
    local budget = StabilizerSlotBudget(slots)
    if budget <= 0 then
        return math.min(want, math.max(1, tonumber(slot.perCraft) or 1))
    end
    local remaining = budget
    for i = 1, #slots do
        local other = slots[i]
        if type(other) == "table" then
            local role = tostring(other.role or "")
            if role == "stabilizer" or role == "goldweed" then
                local base = math.max(1, tonumber(other.perCraft) or 1)
                local otherWant = base
                if other == slot then
                    otherWant = want
                else
                    -- Sibling stabs keep learned perCraft for budget share (avoid recursive eff).
                    otherWant = base
                end
                local alloc = otherWant
                if alloc > remaining then
                    alloc = remaining
                end
                if alloc < 1 and remaining >= 1 and other == slot then
                    alloc = 1
                end
                remaining = remaining - alloc
                if other == slot then
                    if alloc < 1 then
                        return math.min(want, base)
                    end
                    return alloc
                end
            end
        end
    end
    return math.min(want, budget)
end

local function EffectiveSpecPerCraft(slot, slots)
    local perCraft = tonumber(slot and slot.perCraft) or 1
    if type(slot) ~= "table" then
        return perCraft
    end
    local role = slot.role or ""
    if role ~= "stabilizer" and role ~= "goldweed" then
        return perCraft
    end
    local total = SpecStabilityTotal(slots)
    local want = perCraft
    if total <= 0 then
        local stab = StabilityOf(ResolveSlotSpec(slot))
        if stab > 0 then
            -- Push past 0 so engine sees HIGH (total == 0 is MEDIUM).
            local extra = math.ceil((-total + 1) / stab)
            if extra < 1 then
                extra = 1
            end
            want = perCraft + extra
        end
    end
    return CapStabilizerPerCraft(slot, slots, want)
end

local function SumSlotBonus(slots, ref)
    local sum = 0
    if type(slots) ~= "table" then
        return sum
    end
    for i = 1, #slots do
        local slot = slots[i]
        local spec = ResolveSlotSpec(slot)
        local per = 1
        if type(slot) == "table" then
            per = math.max(1, tonumber(slot.perCraft) or 1)
        end
        sum = sum + BonusValue(spec, ref) * per
    end
    return sum
end

local function ObservedRecipeYield(recipe)
    if type(recipe) ~= "table" then
        return 0
    end
    local samples = tonumber(recipe.yieldSamples) or 0
    local sum = tonumber(recipe.yieldProductSum) or 0
    if samples > 0 then
        return sum / samples
    end
    return tonumber(recipe.recipeYield) or 0
end

local function PotionRecipeKeys(potion)
    if type(potion) ~= "table" then
        return nil
    end
    if type(potion.recipeKeys) == "table" then
        return potion.recipeKeys
    end
    return nil
end

local function EnsureBrewStats(recipe)
    if type(recipe) ~= "table" then
        return
    end
    recipe.brewAttempts = tonumber(recipe.brewAttempts) or 0
    recipe.brewSuccesses = tonumber(recipe.brewSuccesses) or 0
    recipe.brewCrits = tonumber(recipe.brewCrits) or 0
    recipe.brewSuperCrits = tonumber(recipe.brewSuperCrits) or 0
    recipe.brewFailures = tonumber(recipe.brewFailures) or 0
    recipe.brewVolatiles = tonumber(recipe.brewVolatiles) or 0
    recipe.yieldProductSum = tonumber(recipe.yieldProductSum) or 0
    recipe.yieldSamples = tonumber(recipe.yieldSamples) or 0
    recipe.crafts = tonumber(recipe.crafts) or 0
    if type(recipe.outcomes) ~= "table" then
        recipe.outcomes = {}
    end
end

local function OutputQuality(out)
    if type(out) ~= "table" then
        return "failed"
    end
    local name = string.lower(ToNarrow(out.name) or "")
    if string.find(name, "volatile", 1, true) then
        return "volatile"
    end
    if string.find(name, "potent", 1, true) then
        return "potent"
    end
    return "good"
end

--- Bag deltas are noisy (double craft, missed stack). Multiplier does not
--- determine yield: +1 yielded 1, +2 and +3 yielded 2, +16/+17/+18 yielded 5,
--- and Stability +10 did not raise yield. There is no bottle formula.
--- Trusted craftable yield is the repeated integer bottle count.
local YIELD_INTEGER_EPS = 0.05
local YIELD_MODE_MIN_HITS = 3

local function WholeBottleQty(qty)
    qty = tonumber(qty) or 0
    if qty < 1 then
        return nil
    end
    local nearest = math.floor(qty + 0.5)
    if nearest < 1 or math.abs(qty - nearest) > YIELD_INTEGER_EPS then
        return nil
    end
    return nearest
end

--- Integer with the most samples, once it has at least 3 hits and is
--- strictly ahead of the next integer. Nil until that lead exists.
--- Also returns bestN and secondN (0 when there are no counts) so a tie
--- can be told from "no mode yet".
local function ModeFromQtyCounts(counts)
    if type(counts) ~= "table" then
        return nil, 0, 0
    end
    local bestQty = nil
    local bestN = 0
    local secondN = 0
    for key, raw in pairs(counts) do
        local n = tonumber(raw) or 0
        local q = tonumber(key) or 0
        if q >= 1 and n > 0 then
            if n > bestN then
                secondN = bestN
                bestN = n
                bestQty = q
            elseif n > secondN then
                secondN = n
            end
        end
    end
    if bestQty ~= nil and bestN >= YIELD_MODE_MIN_HITS and bestN > secondN then
        return bestQty, bestN, secondN
    end
    return nil, bestN, secondN
end

local function ResolveOutcome(recipe, potionUid)
    if type(recipe) ~= "table" or type(recipe.outcomes) ~= "table" then
        return nil
    end
    local uid = tonumber(potionUid) or 0
    if uid <= 0 then
        uid = tonumber(recipe.outputUid) or tonumber(recipe.activeOutcomeUid) or 0
    end
    if uid <= 0 then
        return nil
    end
    local oc = recipe.outcomes[tostring(uid)]
    if oc == nil then
        oc = recipe.outcomes[uid]
    end
    if type(oc) ~= "table" then
        return nil
    end
    return oc
end

-- Session counter. A brew updates yield and success without a knowledge or bag
-- generation bump. Planner cache and craftable stamp keys include this.
RS._recipeStatsGen = tonumber(RS._recipeStatsGen) or 0

function RS.GetRecipeStatsGen()
    return tonumber(RS._recipeStatsGen) or 0
end

local function BumpRecipeStatsGen()
    RS._recipeStatsGen = (tonumber(RS._recipeStatsGen) or 0) + 1
end

--- Returns the bottle count added to yield totals, or nil when the delta is
--- ignored. Successes always increment: a bad delta must not lower the
--- success rate. Saved productSum / successes are not rewritten.
local function RecordOutcome(recipe, potionUid, quality, qty)
    potionUid = tonumber(potionUid) or 0
    qty = tonumber(qty) or 1
    if potionUid <= 0 or type(recipe) ~= "table" then
        return nil
    end
    EnsureBrewStats(recipe)
    local key = tostring(potionUid)
    local oc = recipe.outcomes[key]
    if type(oc) ~= "table" then
        oc = { successes = 0, productSum = 0, quality = quality }
        recipe.outcomes[key] = oc
    end
    -- Historical rows counted every success in productSum. Keep that
    -- denominator until a later reject splits yield samples from successes.
    if oc.yieldSamples == nil then
        oc.yieldSamples = tonumber(oc.successes) or 0
    end
    oc.successes = (tonumber(oc.successes) or 0) + 1
    oc.quality = quality or oc.quality
    local qtyInt = WholeBottleQty(qty)
    -- Count every whole quantity so a later integer can overtake the mode.
    -- productSum takes the current mode, any value before a mode exists, or
    -- a quantity tied for that lead. A trailing outlier during a tie is ignored.
    if qtyInt ~= nil then
        if type(oc.qtyCounts) ~= "table" then
            oc.qtyCounts = {}
        end
        local qk = tostring(qtyInt)
        oc.qtyCounts[qk] = (tonumber(oc.qtyCounts[qk]) or 0) + 1
    end
    local mode, bestN, secondN = ModeFromQtyCounts(oc.qtyCounts)
    local tiedLead = mode == nil
        and (tonumber(bestN) or 0) >= YIELD_MODE_MIN_HITS
        and bestN == secondN
    local acceptQty = nil
    if tiedLead then
        local leadN = 0
        if qtyInt ~= nil and type(oc.qtyCounts) == "table" then
            leadN = tonumber(oc.qtyCounts[tostring(qtyInt)]) or 0
        end
        if leadN > 0 and leadN == bestN then
            acceptQty = qtyInt
        end
    elseif mode ~= nil then
        if qtyInt ~= nil and qtyInt == mode then
            acceptQty = qtyInt
        end
    elseif qtyInt ~= nil then
        acceptQty = qtyInt
    elseif qty > 0 then
        acceptQty = qty
    end
    if acceptQty == nil then
        return nil
    end
    oc.productSum = (tonumber(oc.productSum) or 0) + acceptQty
    oc.yieldSamples = (tonumber(oc.yieldSamples) or 0) + 1
    if oc.yieldSamples > 0 then
        oc.yield = oc.productSum / oc.yieldSamples
    end
    return acceptQty
end

local function NameLooksLiniment(name)
    local n = string.lower(ToNarrow(name))
    return string.find(n, "liniment", 1, true) ~= nil
end

local function CountItemsMatchingSpec(spec)
    if type(spec) ~= "table" then
        return 0
    end
    local Inv = StockPiler.Inventory
    local M = MS()
    local total = 0
    local function accumulate(item)
        if type(item) ~= "table" then
            return
        end
        if M.IsSeedOrSpore and M.IsSeedOrSpore(item) == true then
            return
        end
        local ok = false
        if M.ProductMatches then
            ok = M.ProductMatches(item, spec) == true
        elseif M.Matches then
            ok = M.Matches(item, spec) == true
        end
        if ok then
            local stack = tonumber(item.stackCount) or tonumber(item.Count) or 1
            if stack < 1 then
                stack = 1
            end
            total = total + stack
        end
    end
    -- Incomplete mains included: ProductMatches accepts fingerprint twins
    -- (Supple Scale stub ↔ Preserved Glossy Chitin), not boundUid-only.
    if Inv and Inv.ForEachItem and M then
        Inv.ForEachItem(accumulate)
    end
    return total
end

--- Plants/seeds still needed for AutoGrow seed-buffer (0 when that seed's buffer
--- is full). Watch brew and SkillUp Apo both reserve headroom of the seed this
--- spec grows. skillUpActive keeps that reserve armed when AutoGrow is off.
--- Watched-line "buffer satisfied" does not cover SkillUp seeds (they are not
--- watch lines); those still reserve their own headroom.
local function GrowReserveForSpec(spec)
    local Caps = StockPiler.TradeSkillCaps
    -- Apo/Butcher-only: no Cultivation -> never reserve plants for grow/refine.
    if not (Caps and Caps.CanAutoGrow and Caps.CanAutoGrow() == true) then
        return 0
    end
    local Watch = StockPiler.Watch
    if Watch and Watch.IsSeedBufferEnabled and Watch.IsSeedBufferEnabled() ~= true then
        return 0
    end
    local char = CharacterRow()
    if type(char) ~= "table" or char.growSeedBufferEnabled == false then
        return 0
    end
    local minBuf = tonumber(char.growSeedBufferMin) or 5
    if minBuf <= 0 then
        return 0
    end
    -- Only reserve when AutoGrow / seed buffer is in play, or SkillUp may burn plants.
    local skillUpActive = false
    local SkillUpMod = StockPiler.SkillUp
    if SkillUpMod then
        if SkillUpMod.ShouldCultGrowForSkillUp and SkillUpMod.ShouldCultGrowForSkillUp() == true then
            skillUpActive = true
        elseif SkillUpMod.IsApoEnabled and SkillUpMod.IsApoEnabled() == true then
            skillUpActive = true
        elseif SkillUpMod.IsCultEnabled and SkillUpMod.IsCultEnabled() == true then
            skillUpActive = true
        end
    end
    if not skillUpActive then
        if Watch and Watch.HasAnyAutoGrow and Watch.HasAnyAutoGrow() ~= true then
            if Watch.IsAutoGrowEnabled and Watch.IsAutoGrowEnabled() ~= true then
                return 0
            end
            if char.autoGrowEnabled ~= true then
                return 0
            end
        end
    end

    -- Watched lines full: do not reserve unwatched lower-tier leftovers (that
    -- left craftable=0 with plantJob=nil and empty plots idle). SkillUp seeds
    -- are not watch lines, so a vacuous "satisfied" must not skip their headroom.
    local watchedBufferFull = false
    local RefineMod = StockPiler.Refine
    if RefineMod and RefineMod.IsSeedBufferSatisfied and RefineMod.IsSeedBufferSatisfied() == true then
        watchedBufferFull = true
        if not skillUpActive then
            return 0
        end
    end

    local SM = StockPiler.SeedMap
    local plantOrSeedUid = tonumber(spec and (spec.uid or spec.uniqueID or spec.boundUid)) or 0
    local seedUid = 0
    local isSeed = false
    if SM and SM.IsBagSeedOrSpore and SM.IsBagSeedOrSpore(spec) == true then
        isSeed = true
        seedUid = plantOrSeedUid
    elseif plantOrSeedUid > 0 and SM then
        -- Same-tier / refine-linked seed only - never L1 Eternal for a T25 plant.
        if SM.ResolveSeedUidForPlant then
            seedUid = tonumber(SM.ResolveSeedUidForPlant(plantOrSeedUid, spec)) or 0
        end
        if seedUid <= 0 and SM.PickBestSeedUid then
            seedUid = tonumber(SM.PickBestSeedUid(plantOrSeedUid)) or 0
        end
        if seedUid <= 0 and SM.GetSeedUidsForPlant then
            local uids = SM.GetSeedUidsForPlant(plantOrSeedUid)
            seedUid = type(uids) == "table" and (tonumber(uids[1]) or 0) or 0
        end
    end
    if seedUid <= 0 then
        -- Plant-only cushion (Cult-max s0, e.g. Savage Marshroot): hold bufferMin
        -- of the plant itself so brewRespectGrowReserve cannot burn the stack.
        -- Resin, vials, and butchered stabilizers have no seed and are not plants.
        -- Reserving them left SkillUp at seed_buffer with a full seed buffer (#79).
        if isSeed or plantOrSeedUid <= 0 then
            return 0
        end
        if not (SM and SM.IsGrowableSpec and SM.IsGrowableSpec(spec) == true) then
            return 0
        end
        local Inv = StockPiler.Inventory
        local have = Inv and Inv.CountByUid and tonumber(Inv.CountByUid(plantOrSeedUid)) or 0
        return math.max(0, minBuf - have)
    end

    -- Prefer Refine budget (live + ground + outstanding); else live seed count.
    local function headroomOf(uid)
        uid = tonumber(uid) or 0
        if uid <= 0 then
            return 0
        end
        local Refine = StockPiler.Refine
        if Refine and Refine.GetSeedBudget then
            local budget = Refine.GetSeedBudget(uid)
            local h = tonumber(budget and budget.headroom)
            if h ~= nil then
                return math.max(0, h)
            end
        end
        local live = 0
        local Inv = StockPiler.Inventory
        if Inv and Inv.CountByUid then
            live = tonumber(Inv.CountByUid(uid)) or 0
        end
        return math.max(0, minBuf - live)
    end
    local function seedSkillReq(uid)
        uid = tonumber(uid) or 0
        if uid <= 0 then
            return 0
        end
        local Inv = StockPiler.Inventory
        local sample = Inv and Inv.GetSample and Inv.GetSample(uid)
        if type(sample) ~= "table" and StockPiler.Items and StockPiler.Items.GetByUid then
            sample = StockPiler.Items.GetByUid(uid)
        end
        if type(sample) ~= "table" then
            return 0
        end
        local req = tonumber(sample.craftingSkillRequirement) or tonumber(sample.skillReq)
            or tonumber(sample.skillLevel) or 0
        if req <= 0 and type(sample.bonuses) == "table" then
            req = tonumber(sample.bonuses[9]) or 0
        end
        return req
    end
    local plantReq = 0
    if not isSeed and plantOrSeedUid > 0 then
        if type(spec) == "table" then
            plantReq = tonumber(spec.skillLevel) or tonumber(spec.craftingSkillRequirement)
                or tonumber(spec.skillReq) or 0
        end
        if plantReq <= 0 then
            local Inv = StockPiler.Inventory
            local sample = Inv and Inv.GetSample and Inv.GetSample(plantOrSeedUid)
            if type(sample) ~= "table" and StockPiler.Items and StockPiler.Items.GetByUid then
                sample = StockPiler.Items.GetByUid(plantOrSeedUid)
            end
            if type(sample) == "table" then
                plantReq = tonumber(sample.craftingSkillRequirement) or tonumber(sample.skillReq)
                    or tonumber(sample.skillLevel) or 0
                if plantReq <= 0 and type(sample.bonuses) == "table" then
                    plantReq = tonumber(sample.bonuses[9]) or 0
                end
            end
        end
    end
    if watchedBufferFull then
        -- Same planting tier as SkillUp's current seed (and same-tier siblings).
        -- Lower leftovers stay at reserve 0 once watched lines are full.
        local skillUpTier = 0
        if SkillUpMod and SkillUpMod.PickBestBagSeed then
            local best = SkillUpMod.PickBestBagSeed()
            if type(best) == "table" then
                skillUpTier = tonumber(best.skillReq) or 0
            end
        end
        if skillUpTier < 1 and SkillUpMod then
            skillUpTier = seedSkillReq(SkillUpMod._lastSeedUid)
        end
        if skillUpTier < 1 and SkillUpMod and SkillUpMod.TargetMaxSkill then
            skillUpTier = tonumber(SkillUpMod.TargetMaxSkill()) or 0
        end
        local owns = false
        if SkillUpMod and (tonumber(SkillUpMod._lastSeedUid) or 0) == seedUid and seedUid > 0 then
            owns = true
        elseif skillUpTier > 0 then
            local sReq = seedSkillReq(seedUid)
            if plantReq == skillUpTier or sReq == skillUpTier then
                owns = true
            end
        end
        if not owns then
            return 0
        end
    end
    -- Hold only the resolved seed (when same-tier / unknown) plus the genus
    -- ladder seed at this plant's skillReq. Never max over every grow/refine
    -- linked seed — lower-tier leftovers inflate reserve and block brew.
    local headroom = 0
    if isSeed then
        headroom = headroomOf(seedUid)
    else
        local sReq = seedSkillReq(seedUid)
        if plantReq <= 0 or sReq <= 0 or sReq == plantReq then
            headroom = headroomOf(seedUid)
        end
        if plantReq > 0 and SM and SM.GetGenusLadderForSpec then
            local ladder = SM.GetGenusLadderForSpec(spec or {
                uid = plantOrSeedUid,
                skillLevel = plantReq,
            })
            if type(ladder) == "table" and type(ladder.rungs) == "table" then
                for i = 1, #ladder.rungs do
                    local rung = ladder.rungs[i]
                    if (tonumber(rung.skillReq) or 0) == plantReq then
                        local h = headroomOf(rung.seedUid)
                        if h > headroom then
                            headroom = h
                        end
                        break
                    end
                end
            end
        end
    end
    if headroom <= 0 then
        return 0
    end
    -- Seeds: hold buffer headroom. Plants: hold feedstock to fill that headroom.
    return headroom
end

----------------------------------------------------------------
-- Public API
----------------------------------------------------------------

function RS.PotionKeyFromUid(uid)
    uid = tonumber(uid) or 0
    if uid <= 0 then
        return nil
    end
    return "uid:" .. tostring(uid)
end

--- Composite: uid:<outputUid>|rk:<recipeSpecKey>
function RS.PotionRecipeKey(outputUid, recipeSpecKey)
    local potionKey = RS.PotionKeyFromUid(outputUid)
    recipeSpecKey = tostring(recipeSpecKey or "")
    if potionKey == nil or recipeSpecKey == "" then
        return nil
    end
    return potionKey .. "|rk:" .. recipeSpecKey
end

function RS.ParsePotionRecipeKey(key)
    if type(key) ~= "string" or key == "" then
        return nil
    end
    local uidStr, recipeSpecKey = string.match(key, "^uid:(%d+)|rk:(.+)$")
    if uidStr and recipeSpecKey and recipeSpecKey ~= "" then
        local uid = tonumber(uidStr) or 0
        return {
            potionRecipeKey = key,
            outputUid = uid,
            potionKey = RS.PotionKeyFromUid(uid),
            recipeSpecKey = recipeSpecKey,
            isComposite = true,
        }
    end
    local plainUid = string.match(key, "^uid:(%d+)$")
    if plainUid then
        local uid = tonumber(plainUid) or 0
        return {
            potionRecipeKey = key,
            outputUid = uid,
            potionKey = RS.PotionKeyFromUid(uid),
            recipeSpecKey = nil,
            isComposite = false,
        }
    end
    return nil
end

--- RecipeSpecKey from main/container/extras (+ optional output uid ignored for identity).
function RS.BuildRecipeSpecKey(slots, _outputUid)
    return SlotsFingerprint(slots)
end

function RS.RecipeSpecKey(slotsOrMaterials, _outputUid)
    if type(slotsOrMaterials) ~= "table" then
        return ""
    end
    local first = slotsOrMaterials[1]
    if type(first) == "table" and (first.itemData ~= nil or (first.uniqueID ~= nil and first.spec == nil and first.uid == nil)) then
        return SlotsFingerprint(MaterialsToSpecSlots(slotsOrMaterials))
    end
    return SlotsFingerprint(slotsOrMaterials)
end

function RS.GetRecipe(recipeSpecKey)
    recipeSpecKey = tostring(recipeSpecKey or "")
    if recipeSpecKey == "" then
        return nil
    end
    local recipes = RecipesTable()
    if type(recipes) ~= "table" then
        return nil
    end
    local recipe = recipes[recipeSpecKey]
    if type(recipe) == "table" then
        HydrateRecipeSlots(recipe)
        return recipe
    end
    return nil
end

function RS.GetPotion(potionKeyOrUid)
    local potions = PotionsTable()
    if type(potions) ~= "table" then
        return nil
    end
    local key = potionKeyOrUid
    if type(key) == "number" then
        key = RS.PotionKeyFromUid(key)
    end
    key = tostring(key or "")
    if key == "" then
        return nil
    end
    local parsed = RS.ParsePotionRecipeKey(key)
    if type(parsed) == "table" and parsed.potionKey then
        key = parsed.potionKey
    end
    local potion = potions[key]
    if type(potion) == "table" then
        return potion
    end
    return nil
end

local function PotionActiveRecipeKey(potion)
    if type(potion) ~= "table" then
        return nil
    end
    local key = potion.activeRecipeKey or potion.activeRecipeSpecKey or potion.recipeSpecKey
    if type(key) == "string" and key ~= "" then
        return key
    end
    local keys = PotionRecipeKeys(potion)
    if type(keys) == "table" and type(keys[1]) == "string" and keys[1] ~= "" then
        return keys[1]
    end
    return nil
end

--- True when recipe outcomes include uid (or outcomes unknown).
local function RecipeProducesOutputUid(recipe, uid)
    uid = tonumber(uid) or 0
    if uid <= 0 or type(recipe) ~= "table" then
        return true
    end
    local outcomes = recipe.outcomes
    if type(outcomes) == "table" and next(outcomes) ~= nil then
        return outcomes[uid] == true or outcomes[tostring(uid)] ~= nil
    end
    local outUid = tonumber(recipe.outputUid) or tonumber(recipe.activeOutcomeUid) or 0
    return outUid <= 0 or outUid == uid
end

--- When watch rk was scrubbed, prefer any still-stored recipe that produces this potion.
local function HealRecipeForPotion(potion, preferKey, outputUid)
    if type(potion) ~= "table" then
        return nil
    end
    preferKey = tostring(preferKey or "")
    local uid = tonumber(outputUid) or tonumber(potion.outputUid) or 0
    local tryKeys = {}
    local seen = {}
    local function add(k)
        k = tostring(k or "")
        if k ~= "" and seen[k] ~= true then
            seen[k] = true
            tryKeys[#tryKeys + 1] = k
        end
    end
    add(preferKey)
    add(PotionActiveRecipeKey(potion))
    local keys = PotionRecipeKeys(potion)
    if type(keys) == "table" then
        for i = 1, #keys do
            add(keys[i])
        end
    end
    local recipes = RecipesTable()
    for i = 1, #tryKeys do
        local k = tryKeys[i]
        local recipe = type(recipes) == "table" and recipes[k] or nil
        -- Reject cross-potion links (e.g. Unguent fingerprint on a Power watch).
        if type(recipe) == "table" and RecipeProducesOutputUid(recipe, uid) ~= true then
            recipe = nil
        end
        if type(recipe) == "table" then
            -- Re-home under the watch fingerprint when scrub deleted that key only.
            if preferKey ~= "" and preferKey ~= k
                and type(recipes) == "table"
                and type(recipes[preferKey]) ~= "table"
            then
                recipes[preferKey] = recipe
            end
            HydrateRecipeSlots(recipe)
            if uid > 0 then
                recipe.outputUid = uid
            end
            return recipe
        end
    end
    return nil
end

--- Recipe for a composite potionRecipeKey (uid:N|rk:fingerprint).
function RS.RecipeSpecForPotionRecipe(potionRecipeKey)
    local parsed = RS.ParsePotionRecipeKey(potionRecipeKey)
    if type(parsed) ~= "table" or type(parsed.recipeSpecKey) ~= "string" then
        return nil
    end
    local recipe = RS.GetRecipe(parsed.recipeSpecKey)
    if type(recipe) ~= "table" then
        local potion = RS.GetPotion(parsed.potionKey)
            or (parsed.outputUid and RS.GetPotion(parsed.outputUid))
            or nil
        recipe = HealRecipeForPotion(potion, parsed.recipeSpecKey, parsed.outputUid)
        if type(recipe) ~= "table" then
            return nil
        end
        return recipe
    end
    local uid = tonumber(parsed.outputUid) or 0
    if uid > 0 then
        recipe.outputUid = uid
    end
    return recipe
end

--- Recipe for a watch/catalog key (composite uid:N|rk:... or plain uid:N).
function RS.RecipeSpecForPotion(potionKey)
    local parsed = RS.ParsePotionRecipeKey(potionKey)
    if type(parsed) == "table" and parsed.isComposite == true then
        return RS.RecipeSpecForPotionRecipe(potionKey)
    end
    local potion = RS.GetPotion(potionKey)
    if type(potion) ~= "table" then
        return nil
    end
    local key = PotionActiveRecipeKey(potion)
    local recipe = HealRecipeForPotion(potion, key, potion.outputUid)
    return recipe
end

--- Resolve watch/catalog key to potion row + recipeSpecKey (legacy uid:N or composite).
function RS.ResolveWatchPotion(watchKey)
    watchKey = tostring(watchKey or "")
    if watchKey == "" then
        return nil
    end
    local potions = PotionsTable()
    if type(potions) ~= "table" then
        return nil
    end
    local parsed = RS.ParsePotionRecipeKey(watchKey)
    if type(parsed) ~= "table" then
        local potion = potions[watchKey]
        if type(potion) ~= "table" then
            return nil
        end
        return {
            potion = potion,
            potionKey = potion.potionKey or watchKey,
            potionRecipeKey = watchKey,
            recipeSpecKey = PotionActiveRecipeKey(potion),
            outputUid = tonumber(potion.outputUid) or 0,
        }
    end
    local potion = potions[parsed.potionKey]
    if type(potion) ~= "table" then
        return nil
    end
    local recipeSpecKey = parsed.recipeSpecKey
    if recipeSpecKey == nil or recipeSpecKey == "" then
        recipeSpecKey = PotionActiveRecipeKey(potion)
    end
    local potionRecipeKey = parsed.isComposite and parsed.potionRecipeKey
        or RS.PotionRecipeKey(parsed.outputUid, recipeSpecKey)
    return {
        potion = potion,
        potionKey = parsed.potionKey,
        potionRecipeKey = potionRecipeKey,
        recipeSpecKey = recipeSpecKey,
        outputUid = parsed.outputUid,
    }
end

--- Apo skill needed to craft this recipe (max slot skillLevel; main preferred).
--- Returns { apothecary = N, apo = N } or nil when unknown.
function RS.RecipeSkillRequirements(recipe)
    if type(recipe) ~= "table" then
        return nil
    end
    HydrateRecipeSlots(recipe)
    local need = 0
    local mainNeed = 0
    local slots = recipe.slots
    if type(slots) == "table" then
        for i = 1, #slots do
            local slot = slots[i]
            if type(slot) == "table" then
                local spec = ResolveSlotSpec(slot)
                local lv = 0
                if type(spec) == "table" then
                    lv = tonumber(spec.skillLevel) or tonumber(spec.craftingSkillRequirement) or 0
                end
                if lv <= 0 then
                    local uid = tonumber(slot.uid)
                        or (type(spec) == "table" and (tonumber(spec.uid) or tonumber(spec.boundUid)))
                        or 0
                    if uid > 0 and StockPiler.Items and StockPiler.Items.GetByUid then
                        local row = StockPiler.Items.GetByUid(uid)
                        if type(row) == "table" then
                            lv = tonumber(row.skillReq) or tonumber(row.skillLevel)
                                or tonumber(row.craftingSkillRequirement) or 0
                        end
                    end
                end
                if lv > need then
                    need = lv
                end
                local role = tostring(slot.role or (type(spec) == "table" and spec.role) or "")
                if role == "main" and lv > mainNeed then
                    mainNeed = lv
                end
            end
        end
    end
    if mainNeed > 0 then
        need = mainNeed
    end
    local outUid = tonumber(recipe.outputUid) or tonumber(recipe.activeOutcomeUid) or 0
    if outUid > 0 and StockPiler.Items and StockPiler.Items.GetByUid then
        local row = StockPiler.Items.GetByUid(outUid)
        if type(row) == "table" then
            local outLv = tonumber(row.skillReq) or tonumber(row.skillLevel)
                or tonumber(row.craftingSkillRequirement) or 0
            if outLv > need then
                need = outLv
            end
        end
    end
    if need <= 0 then
        return nil
    end
    return { apothecary = need, apo = need }
end

function RS.RecipeFingerprintStats(recipe, potionUid)
    local stats = {
        power = 0,
        stability = 0,
        duration = 0,
        multiplier = 0,
        superCrit = 0,
        yield = 0,
    }
    if type(recipe) ~= "table" then
        return stats
    end
    HydrateRecipeSlots(recipe)
    stats.power = SumSlotBonus(recipe.slots, CRAFT_BONUS.POWER)
    stats.stability = SumSlotBonus(recipe.slots, CRAFT_BONUS.STABILITY)
    stats.duration = SumSlotBonus(recipe.slots, CRAFT_BONUS.DURATION)
    stats.multiplier = SumSlotBonus(recipe.slots, CRAFT_BONUS.MULTIPLIER)
    -- SCrit column: SPECIAL_CHANCE (Super-Critical). Display/fingerprint today;
    -- may stop counting for identity later - crit success is a different potion
    -- uid and does not fill the watched target stock.
    stats.superCrit = SumSlotBonus(recipe.slots, CRAFT_BONUS.SPECIAL_CHANCE)
    local yield = ObservedRecipeYield(recipe)
    potionUid = tonumber(potionUid) or 0
    if potionUid > 0 and type(recipe.outcomes) == "table" then
        local oc = recipe.outcomes[tostring(potionUid)]
        if type(oc) == "table" and (tonumber(oc.yield) or 0) > 0 then
            yield = tonumber(oc.yield)
        end
    end
    if yield <= 0 then
        yield = tonumber(recipe.recipeYield) or 0
    end
    stats.yield = yield
    return stats
end

--- Per-potion brew success for tip/UI: times this uid dropped / brewAttempts.
--- Shared fingerprints (good + potent) must not both show brewSuccesses/attempts.
--- Legacy recipes with no outcomes table fall back to fingerprint brewSuccesses.
function RS.OutcomeSuccessStats(recipe, potionUid)
    local attempts = 0
    local successes = 0
    if type(recipe) == "table" then
        attempts = tonumber(recipe.brewAttempts) or 0
        successes = tonumber(recipe.brewSuccesses) or 0
        potionUid = tonumber(potionUid) or 0
        if potionUid > 0 and type(recipe.outcomes) == "table" and next(recipe.outcomes) ~= nil then
            local oc = recipe.outcomes[tostring(potionUid)]
            if oc == nil then
                oc = recipe.outcomes[potionUid]
            end
            successes = (type(oc) == "table" and tonumber(oc.successes)) or 0
        end
    end
    local rate = nil
    if attempts > 0 then
        rate = successes / attempts
    end
    return {
        brewAttempts = attempts,
        brewSuccesses = successes,
        successRate = rate,
    }
end

--- Min brewAttempts before AutoGrow/craftable may trust outcome rates.
local OUTCOME_RATE_MIN_ATTEMPTS = 5

--- Observed bottles of this potion per brew (bag-diff average, may be fractional).
--- Optional potionUid selects a shared-recipe outcome (potent / good).
--- Returns yield, sampleCount. Potions-tab Yield keeps this average.
local function ObservedOutput(recipe, potionUid)
    potionUid = tonumber(potionUid) or 0
    if type(recipe) == "table" and type(recipe.outcomes) == "table" then
        local uid = potionUid
        if uid <= 0 then
            uid = tonumber(recipe.outputUid) or tonumber(recipe.activeOutcomeUid) or 0
        end
        if uid > 0 then
            local oc = recipe.outcomes[tostring(uid)]
            if oc == nil then
                oc = recipe.outcomes[uid]
            end
            if type(oc) == "table" then
                local successes = tonumber(oc.successes) or 0
                local productSum = tonumber(oc.productSum) or 0
                local denom = tonumber(oc.yieldSamples)
                if denom == nil or denom <= 0 then
                    denom = successes
                end
                if denom > 0 and productSum > 0 then
                    return productSum / denom, denom
                end
                local y = tonumber(oc.yield) or 0
                if y > 0 then
                    return y, denom
                end
            end
        end
    end
    local samples = 0
    if type(recipe) == "table" then
        samples = tonumber(recipe.yieldSamples) or 0
    end
    local observed = ObservedRecipeYield(recipe)
    if observed and observed > 0 then
        return observed, samples
    end
    local yield = tonumber(recipe and recipe.recipeYield) or 1
    if yield < 1 then
        yield = 1
    end
    return yield, samples
end

function RS.RecipeOutputYield(recipe, potionUid)
    local yield = ObservedOutput(recipe, potionUid)
    return yield
end

--- Integer bottles/craft for Watch craftable and crafts-needed.
--- Prefer the mode of per-brew bottle counts. Floor the observed mean only
--- until that mode exists, so 2.9 and 5.1 never multiply craftable.
--- Snap to the nearest integer only when samples >= OUTCOME_RATE_MIN_ATTEMPTS
--- and the average is within YIELD_INTEGER_EPS. Otherwise floor.
--- Rounding 2.9 up to 3 can paint Ready via have+craftable.
--- Floor stays at or below that mean. Deficit 0 is potion_stocked first.
--- No multiplier / stability yield formula: same Multiplier band yields 5,
--- and +1 / +2 / +3 do not share one step.
local function StableIntegerYield(value, samples)
    value = tonumber(value) or 0
    samples = tonumber(samples) or 0
    if value <= 0 then
        return nil
    end
    local nearest = math.floor(value + 0.5)
    if nearest >= 1
        and samples >= OUTCOME_RATE_MIN_ATTEMPTS
        and math.abs(value - nearest) <= YIELD_INTEGER_EPS
    then
        return nearest
    end
    local floored = math.floor(value)
    if floored < 1 then
        floored = 1
    end
    return floored
end

function RS.StableCraftYield(recipe, potionUid)
    local oc = ResolveOutcome(recipe, potionUid)
    local mode = ModeFromQtyCounts(oc and oc.qtyCounts)
    if mode ~= nil and mode >= 1 then
        return mode
    end
    local value, samples = ObservedOutput(recipe, potionUid)
    local stable = StableIntegerYield(value, samples)
    if stable == nil or stable < 1 then
        return 1
    end
    return stable
end

local function IsWholeNumber(value)
    value = tonumber(value)
    if value == nil then
        return true
    end
    return math.abs(value - math.floor(value + 1e-8)) <= 1e-6
end

--- Same integer StableCraftYield trusts, from a saved mean or qtyCounts mode.
local function TrustedIntegerFromStored(recipe, potionUid, oc)
    local mode = ModeFromQtyCounts(oc and oc.qtyCounts)
    if mode ~= nil and mode >= 1 then
        return mode
    end
    local value, samples = ObservedOutput(recipe, potionUid)
    if (tonumber(value) or 0) <= 0 and type(oc) == "table" then
        value = tonumber(oc.yield) or 0
        local denom = tonumber(oc.yieldSamples)
        if denom == nil or denom <= 0 then
            denom = tonumber(oc.successes) or 0
        end
        samples = denom
    end
    return StableIntegerYield(value, samples)
end

--- One-shot: snap fractional saved yields onto the trusted integer.
--- Rewrites product sums so the mean stays on that integer. Sample and
--- success counts are left alone. A later login does not run again.
function RS.MigrateFractionalRecipeYields()
    local acct = StockPiler.Account
    if type(acct) ~= "table" then
        return false
    end
    if acct.recipeYieldIntegerMigrateV1 == true then
        return false
    end
    local recipes = RecipesTable()
    if type(recipes) ~= "table" then
        acct.recipeYieldIntegerMigrateV1 = true
        return false
    end
    for _, recipe in pairs(recipes) do
        if type(recipe) == "table" then
            local goodUid = 0
            local goodOc = nil
            if type(recipe.outcomes) == "table" then
                local preferred = tonumber(recipe.activeOutcomeUid)
                    or tonumber(recipe.outputUid) or 0
                local function takeGood(uid)
                    uid = tonumber(uid) or 0
                    if uid <= 0 or goodOc ~= nil then
                        return
                    end
                    local oc = recipe.outcomes[tostring(uid)]
                    if oc == nil then
                        oc = recipe.outcomes[uid]
                    end
                    if type(oc) == "table" and oc.quality == "good" then
                        goodUid = uid
                        goodOc = oc
                    end
                end
                takeGood(preferred)
                if goodOc == nil then
                    for key, oc in pairs(recipe.outcomes) do
                        if type(oc) == "table" and oc.quality == "good" then
                            goodUid = tonumber(key) or 0
                            goodOc = oc
                            break
                        end
                    end
                end
                for key, oc in pairs(recipe.outcomes) do
                    if type(oc) == "table" then
                        local uid = tonumber(key) or 0
                        local value = ObservedOutput(recipe, uid)
                        local stored = tonumber(oc.yield)
                        local fractional = ((tonumber(value) or 0) > 0 and not IsWholeNumber(value))
                            or (stored ~= nil and stored > 0 and not IsWholeNumber(stored))
                        if fractional then
                            local trusted = TrustedIntegerFromStored(recipe, uid, oc)
                            if trusted ~= nil and trusted >= 1 then
                                local _, samples = ObservedOutput(recipe, uid)
                                if (tonumber(samples) or 0) <= 0 then
                                    samples = tonumber(oc.yieldSamples)
                                    if samples == nil or samples <= 0 then
                                        samples = tonumber(oc.successes) or 0
                                    end
                                end
                                oc.yield = trusted
                                if (tonumber(samples) or 0) > 0 then
                                    oc.productSum = trusted * samples
                                end
                            end
                        end
                    end
                end
            end
            local recipeValue = ObservedRecipeYield(recipe)
            local recipeStored = tonumber(recipe.recipeYield)
            local recipeFractional = ((tonumber(recipeValue) or 0) > 0
                    and not IsWholeNumber(recipeValue))
                or (recipeStored ~= nil and recipeStored > 0
                    and not IsWholeNumber(recipeStored))
            if recipeFractional then
                local trusted = nil
                if goodOc ~= nil then
                    trusted = TrustedIntegerFromStored(recipe, goodUid, goodOc)
                end
                if trusted == nil then
                    local samples = tonumber(recipe.yieldSamples) or 0
                    local value = recipeValue
                    if (tonumber(value) or 0) <= 0 then
                        value = recipeStored
                    end
                    trusted = StableIntegerYield(value, samples)
                end
                if trusted ~= nil and trusted >= 1 then
                    recipe.recipeYield = trusted
                    local samples = tonumber(recipe.yieldSamples) or 0
                    if samples > 0 then
                        recipe.yieldProductSum = trusted * samples
                    end
                end
            end
        end
    end
    acct.recipeYieldIntegerMigrateV1 = true
    if StockPiler.Knowledge and StockPiler.Knowledge.Touch then
        StockPiler.Knowledge.Touch("recipe-yield-integer-migrate-v1")
    end
    return true
end

--- Fraction of fingerprint brews that produced this potion uid.
--- Returns nil when sample size is below OUTCOME_RATE_MIN_ATTEMPTS.
function RS.OutcomeSuccessRate(recipe, potionUid)
    local stats = RS.OutcomeSuccessStats(recipe, potionUid)
    local attempts = tonumber(stats and stats.brewAttempts) or 0
    if attempts < OUTCOME_RATE_MIN_ATTEMPTS then
        return nil
    end
    local rate = stats and stats.successRate
    if rate == nil then
        return nil
    end
    if rate < 0 then
        rate = 0
    elseif rate > 1 then
        rate = 1
    end
    return rate, tonumber(stats.brewSuccesses) or 0, attempts
end

--- Crafts to cover a potion deficit at best-case yield (optimistic).
function RS.CraftsNeededForDeficit(deficit, recipe, potionUid)
    deficit = math.max(0, tonumber(deficit) or 0)
    if deficit <= 0 then
        return 0
    end
    local yield = RS.StableCraftYield(recipe, potionUid)
    if yield < 1 then
        yield = 1
    end
    return math.max(1, math.ceil(deficit / yield))
end

--- Best-case bottles from current materials (crafts × integer yield).
function RS.CountPotionsCraftable(recipe, opts, potionUid)
    local crafts = RS.CountCraftsPossible(recipe, opts)
    local bottles = crafts * RS.StableCraftYield(recipe, potionUid)
    return math.floor((tonumber(bottles) or 0) + 0.5)
end

--- Expected bottles of this potion from current materials using outcome rate.
--- Returns expected, rate, bestCase, crafts. expected is nil when rate unknown.
function RS.ExpectedCraftableBottles(recipe, potionUid, opts)
    potionUid = tonumber(potionUid) or tonumber(recipe and recipe.outputUid) or 0
    local crafts = RS.CountCraftsPossible(recipe, opts)
    local yield = RS.StableCraftYield(recipe, potionUid)
    if yield < 1 then
        yield = 1
    end
    local best = crafts * yield
    local rate = RS.OutcomeSuccessRate(recipe, potionUid)
    local expected = nil
    if rate ~= nil then
        if rate < 0 then
            rate = 0
        elseif rate > 1 then
            rate = 1
        end
        expected = best * rate
    end
    return expected, rate, best, crafts
end

--- Crafts expected to cover a deficit when only `rate` of brews produce this potion.
--- Falls back to optimistic CraftsNeededForDeficit when rate is unknown.
function RS.ExpectedCraftsForDeficit(deficit, recipe, potionUid)
    deficit = math.max(0, tonumber(deficit) or 0)
    if deficit <= 0 then
        return 0, nil
    end
    potionUid = tonumber(potionUid) or tonumber(recipe and recipe.outputUid) or 0
    local rate = RS.OutcomeSuccessRate(recipe, potionUid)
    local yield = RS.StableCraftYield(recipe, potionUid)
    if yield < 1 then
        yield = 1
    end
    if rate == nil or rate <= 0 then
        return RS.CraftsNeededForDeficit(deficit, recipe, potionUid), rate
    end
    if rate > 1 then
        rate = 1
    end
    local perCraft = yield * rate
    if perCraft <= 0 then
        return RS.CraftsNeededForDeficit(deficit, recipe, potionUid), rate
    end
    return math.max(1, math.ceil(deficit / perCraft)), rate
end

function RS.SlimRecipeForStorage(recipe)
    if type(recipe) ~= "table" then
        return recipe
    end
    if type(recipe.slots) == "table" then
        recipe.slots = SlimSlotsForStorage(recipe.slots)
    end
    return recipe
end

function RS.SlimAllRecipesForStorage()
    local recipes = RecipesTable()
    if type(recipes) ~= "table" then
        return 0
    end
    local n = 0
    for _, recipe in pairs(recipes) do
        if type(recipe) == "table" then
            RS.SlimRecipeForStorage(recipe)
            n = n + 1
        end
    end
    return n
end

function RS.IsLinimentClass(specOrItem)
    if type(specOrItem) ~= "table" then
        return false
    end
    if NameLooksLiniment(specOrItem.name) then
        return true
    end
    if specOrItem.linimentClass == true then
        return true
    end
    local uid = tonumber(specOrItem.uid) or tonumber(specOrItem.uniqueID) or 0
    if uid > 0 and StockPiler.Items and StockPiler.Items.GetByUid then
        local row = StockPiler.Items.GetByUid(uid)
        if type(row) == "table" then
            if NameLooksLiniment(row.name) or row.linimentClass == true then
                return true
            end
        end
    end
    if uid > 0 then
        local potions = PotionsTable()
        local pk = RS.PotionKeyFromUid and RS.PotionKeyFromUid(uid)
        local prow = type(potions) == "table" and pk and potions[pk]
        if type(prow) == "table" and (prow.linimentClass == true or NameLooksLiniment(prow.name)) then
            return true
        end
    end
    return false
end

local function CountFromPlannerWarmCache(spec)
    local P = StockPiler.Planner
    if not (P and P.IsHaveCacheWarmForSnap and P.IsHaveCacheWarmForSnap() == true) then
        return nil
    end
    if not P.CountItemsMatchingSpec then
        return nil
    end
    -- cacheOnly avoids Planner->RS recursion on miss.
    local n = P.CountItemsMatchingSpec(spec, { cacheOnly = true })
    if n == nil then
        return nil
    end
    return tonumber(n) or 0
end

function RS.BrewAvailableForSpec(spec)
    local have = CountFromPlannerWarmCache(spec)
    if have == nil then
        have = CountItemsMatchingSpec(spec)
    end
    local reserve = GrowReserveForSpec(spec)
    if reserve <= 0 then
        return have
    end
    local avail = have - reserve
    if avail < 0 then
        return 0
    end
    return avail
end

function RS.CountItemsMatchingSpec(spec, _opts)
    local have = CountFromPlannerWarmCache(spec)
    if have ~= nil then
        return have
    end
    return CountItemsMatchingSpec(spec)
end

--- How many full crafts bags support.
--- MUST honor brewRespectGrowReserve: opts.respectGrowReserve OR character flag -> BrewAvailableForSpec.
function RS.CountCraftsPossible(recipe, opts)
    if type(recipe) ~= "table" then
        return 0
    end
    opts = type(opts) == "table" and opts or {}
    -- Wire brewRespectGrowReserve: opts.respectGrowReserve OR character flag.
    -- Explicit opts.respectGrowReserve == false opts out (non-reserve craftable memo).
    local charRespect = true
    local Caps = StockPiler.TradeSkillCaps
    if Caps and Caps.CanAutoGrow and Caps.CanAutoGrow() ~= true then
        charRespect = false
    else
        local char = CharacterRow()
        if type(char) == "table" then
            charRespect = char.brewRespectGrowReserve ~= false
        end
    end
    local respect = (opts.respectGrowReserve == true) or charRespect
    if opts.respectGrowReserve == false then
        respect = false
    end
    if Caps and Caps.CanAutoGrow and Caps.CanAutoGrow() ~= true then
        respect = false
    end

    HydrateRecipeSlots(recipe)
    local slots = recipe.slots
    if type(slots) ~= "table" or #slots == 0 then
        return 0
    end
    local possible = nil
    for i = 1, #slots do
        local slot = slots[i]
        local spec = ResolveSlotSpec(slot)
        if type(slot) == "table" and type(spec) == "table" then
            local perCraft = EffectiveSpecPerCraft(slot, slots)
            if perCraft < 1 then
                perCraft = 1
            end
            local have
            if respect then
                have = RS.BrewAvailableForSpec(spec)
            else
                have = CountItemsMatchingSpec(spec)
            end
            local craftsHave = math.floor(have / perCraft)
            if craftsHave < 0 then
                craftsHave = 0
            end
            if possible == nil or craftsHave < possible then
                possible = craftsHave
            end
        end
    end
    return possible or 0
end

----------------------------------------------------------------
-- Potion Effect resolve (stored -> fx: -> main effectId -> Classify)
----------------------------------------------------------------

local EFFECT_KEY_UI_ALIASES = {
    rskill = "bs",
    wil = "wp",
    arm = "armor",
    shabs = "absorb",
    regen = "hot",
}

--- Map MaterialSpec / description aliases onto Potions-tab filter keys.
function RS.NormalizeEffectKeyForUi(effectKey)
    if type(effectKey) ~= "string" or effectKey == "" then
        return nil
    end
    local key = string.lower(effectKey)
    return EFFECT_KEY_UI_ALIASES[key] or key
end

local function EffectKeyFromFxInRecipeKey(recipeKey)
    recipeKey = tostring(recipeKey or "")
    if recipeKey == "" then
        return nil
    end
    local fx = string.match(recipeKey, "fx:(%d+)")
    local effectId = tonumber(fx) or 0
    if effectId <= 0 then
        return nil
    end
    local MS = StockPiler.MaterialSpec
    if not MS or not MS.EffectKeyFromEffectId then
        return nil
    end
    return RS.NormalizeEffectKeyForUi(MS.EffectKeyFromEffectId(effectId))
end

local function EffectKeyFromRecipeMain(recipe)
    if type(recipe) ~= "table" then
        return nil
    end
    HydrateRecipeSlots(recipe)
    local slots = recipe.slots or {}
    local MS = StockPiler.MaterialSpec
    local Items = StockPiler.Items
    for i = 1, #slots do
        local slot = slots[i]
        if type(slot) == "table" and (slot.role == "main" or (type(slot.spec) == "table" and slot.spec.role == "main")) then
            local spec = ResolveSlotSpec(slot)
            local effectId = type(spec) == "table" and tonumber(spec.effectId) or 0
            local uid = tonumber(slot.uid) or (type(spec) == "table" and tonumber(spec.uid)) or 0
            if effectId <= 0 and uid > 0 and Items and Items.GetByUid then
                local row = Items.GetByUid(uid)
                effectId = type(row) == "table" and tonumber(row.effectId) or 0
                -- Incomplete mains often omit craftingBonus EFFECT; enrich from item/DB.
                if effectId <= 0 and MS and MS.FromItemData then
                    local probe = row
                    if type(probe) ~= "table" then
                        probe = { uniqueID = uid }
                    end
                    local enriched = MS.FromItemData(probe, "main")
                    effectId = type(enriched) == "table" and tonumber(enriched.effectId) or 0
                    if effectId > 0 and type(row) == "table" then
                        row.effectId = effectId
                    end
                end
            end
            if effectId > 0 and MS and MS.EffectKeyFromEffectId then
                return RS.NormalizeEffectKeyForUi(MS.EffectKeyFromEffectId(effectId))
            end
        end
    end
    return nil
end

--- Resolve potion Effect column key from the potion / recipe - not the product name.
--- Order: Use: ability -> recipe fx: -> main EFFECT id -> stored.
--- opts.recipe / opts.recipeKey / opts.itemData optional.
--- opts.stamp ~= false stamps potion.effectKey when found.
--- opts.allowClassify == false skips bag/DB Use (fx:/main only).
function RS.ResolveEffectKeyForPotion(potion, opts)
    opts = type(opts) == "table" and opts or {}
    local key = nil
    local stored = nil
    if type(potion) == "table" and type(potion.effectKey) == "string" and potion.effectKey ~= "" then
        stored = RS.NormalizeEffectKeyForUi(potion.effectKey)
    end

    local function ResolveOutputItemData()
        local itemData = opts.itemData
        if type(itemData) ~= "table" and type(opts.out) == "table" then
            itemData = opts.out.itemData or opts.out
        end
        local uid = 0
        if type(potion) == "table" then
            uid = tonumber(potion.outputUid) or 0
        end
        if type(itemData) ~= "table" and uid > 0 and StockPiler.Inventory and StockPiler.Inventory.GetSample then
            itemData = StockPiler.Inventory.GetSample(uid)
        end
        local hasUse = false
        if type(itemData) == "table" and type(itemData.bonus) == "table" then
            for _, b in pairs(itemData.bonus) do
                if type(b) == "table" and tonumber(b.type) == 3 and (tonumber(b.reference) or 0) > 0 then
                    hasUse = true
                    break
                end
            end
        end
        if (not hasUse) and uid > 0 and type(GetDatabaseItemData) == "function" then
            local ok, data = pcall(GetDatabaseItemData, uid)
            if ok and type(data) == "table" then
                itemData = data
            end
        end
        return itemData
    end

    -- Finished potion Use: ability (engine tooltip SoT).
    if opts.allowClassify ~= false
        and StockPiler.Classify and StockPiler.Classify.GetEffectKeyFromPotionUse
    then
        local itemData = ResolveOutputItemData()
        if type(itemData) == "table" then
            key = RS.NormalizeEffectKeyForUi(StockPiler.Classify.GetEffectKeyFromPotionUse(itemData))
            if key and type(potion) == "table" and StockPiler.Classify.GetPotionUseAbilityId then
                local abilityId = StockPiler.Classify.GetPotionUseAbilityId(itemData)
                if (tonumber(abilityId) or 0) > 0 then
                    potion.useAbilityId = tonumber(abilityId)
                end
            end
        end
        -- Offline: replay stored Use ability id through GetAbilityDesc.
        if key == nil and type(potion) == "table" and (tonumber(potion.useAbilityId) or 0) > 0
            and type(GetAbilityDesc) == "function"
        then
            local iLevel = tonumber(potion.iLevel) or 0
            local ok, text = pcall(GetAbilityDesc, tonumber(potion.useAbilityId), iLevel)
            if ok and text ~= nil and StockPiler.Classify.GetEffectKeyFromPotionUse then
                key = RS.NormalizeEffectKeyForUi(
                    StockPiler.Classify.GetEffectKeyFromPotionUse({
                        bonus = { { type = 3, reference = tonumber(potion.useAbilityId) } },
                        iLevel = iLevel,
                    })
                )
            end
        end
    end

    local recipe = opts.recipe
    local recipeKey = tostring(opts.recipeKey or "")
    if key == nil then
        if recipeKey == "" and type(potion) == "table" then
            recipeKey = tostring(PotionActiveRecipeKey(potion) or "")
            if recipeKey == "" then
                local keys = PotionRecipeKeys(potion)
                if type(keys) == "table" and type(keys[1]) == "string" then
                    recipeKey = keys[1]
                end
            end
        end
        if recipeKey ~= "" then
            key = EffectKeyFromFxInRecipeKey(recipeKey)
        end
        if key == nil and type(potion) == "table" then
            local keys = PotionRecipeKeys(potion)
            if type(keys) == "table" then
                for i = 1, #keys do
                    key = EffectKeyFromFxInRecipeKey(keys[i])
                    if key then
                        break
                    end
                end
            end
        end
    end
    if key == nil then
        if type(recipe) ~= "table" and recipeKey ~= "" then
            local recipes = RecipesTable()
            recipe = type(recipes) == "table" and recipes[recipeKey] or nil
        end
        if type(recipe) ~= "table" and type(potion) == "table" then
            local pk = potion.potionKey or (potion.outputUid and RS.PotionKeyFromUid(potion.outputUid))
            if pk then
                recipe = RS.RecipeSpecForPotion(pk)
            end
        end
        key = EffectKeyFromRecipeMain(recipe)
    end
    if key == nil then
        key = stored
    end
    -- Product line name when Use text and the main slot never stamped an effect.
    -- Pyrewind is the flame-breath line, the same way Discipline is willpower.
    -- Also replace a movement-speed stamp; that name is not a speed potion.
    if type(potion) == "table" and StockPiler.Classify and StockPiler.Classify.GetEffectKey then
        local fromName = RS.NormalizeEffectKeyForUi(StockPiler.Classify.GetEffectKey({
            name = potion.name,
        }))
        if fromName == "dmgcone" and (key == nil or key == "movespeed") then
            key = fromName
        end
    end
    if key and type(potion) == "table" and opts.stamp ~= false then
        potion.effectKey = key
    end
    return key
end

--- Boot: fill / refresh effectKey from potion Use: or recipe main EFFECT (not product name).
function RS.MigratePotionEffectKeys()
    local potions = PotionsTable()
    if type(potions) ~= "table" then
        return 0
    end
    local stamped = 0
    for _, potion in pairs(potions) do
        if type(potion) == "table" then
            local before = potion.effectKey
            local key = RS.ResolveEffectKeyForPotion(potion, {
                stamp = true,
                allowClassify = true,
            })
            if key and key ~= before then
                stamped = stamped + 1
            elseif key and (type(before) ~= "string" or before == "") then
                stamped = stamped + 1
            else
                local norm = before and RS.NormalizeEffectKeyForUi(before) or nil
                if norm and norm ~= before then
                    potion.effectKey = norm
                    stamped = stamped + 1
                end
            end
        end
    end
    if stamped > 0 and StockPiler.Knowledge and StockPiler.Knowledge.Touch then
        StockPiler.Knowledge.Touch("potion-effect")
    end
    return stamped
end

--- Role names that open a fingerprint segment (`rolexN:spec...`). Spec payloads may
--- contain "|" so fingerprints cannot be split on "|" alone.
local FINGERPRINT_ROLE = {
    container = true,
    main = true,
    stabilizer = true,
    goldweed = true,
    extender = true,
    multiplier = true,
    stimulant = true,
    ingredient = true,
}

--- Split recipe fingerprint into role segments (`rolexN:spec...`).
local function FingerprintRoleParts(key)
    key = tostring(key or "")
    if key == "" then
        return {}
    end
    local starts = {}
    local pos = 1
    local n = string.len(key)
    while pos <= n do
        local s, e, role = string.find(key, "([%a]+)x%d+:", pos)
        if not s then
            break
        end
        if FINGERPRINT_ROLE[role] == true
            and (s == 1 or string.sub(key, s - 1, s - 1) == "|")
        then
            starts[#starts + 1] = s
        end
        pos = e + 1
    end
    local parts = {}
    for i = 1, #starts do
        local from = starts[i]
        local to = n
        if starts[i + 1] then
            to = starts[i + 1] - 2
        end
        if to >= from then
            parts[#parts + 1] = string.sub(key, from, to)
        end
    end
    return parts
end

--- True when shortKey's role segments are a proper subset of longKey's.
--- Covers missing trailing slots and mid-board omissions (e.g. no stabilizer).
local function IsStrictFingerprintSubset(shortKey, longKey)
    shortKey = tostring(shortKey or "")
    longKey = tostring(longKey or "")
    if shortKey == "" or longKey == "" or shortKey == longKey then
        return false
    end
    local shortParts = FingerprintRoleParts(shortKey)
    local longParts = FingerprintRoleParts(longKey)
    if #shortParts > 0 and #longParts > 0 then
        if #shortParts >= #longParts then
            return false
        end
        local longSet = {}
        for i = 1, #longParts do
            longSet[longParts[i]] = true
        end
        for i = 1, #shortParts do
            if longSet[shortParts[i]] ~= true then
                return false
            end
        end
        return true
    end
    -- Fallback: legacy trailing-prefix check (older fingerprints).
    if #shortKey >= #longKey then
        return false
    end
    if string.sub(longKey, 1, #shortKey) ~= shortKey then
        return false
    end
    return string.sub(longKey, #shortKey + 1, #shortKey + 1) == "|"
end

--- Incomplete main (`uid:N`) upgraded by a later EFFECT-stamped main (`fx:M`).
--- Same role count / non-main segments; only the main identity token differs.
local function IsIncompleteMainUpgrade(weakKey, strongKey)
    weakKey = tostring(weakKey or "")
    strongKey = tostring(strongKey or "")
    if weakKey == "" or strongKey == "" or weakKey == strongKey then
        return false
    end
    if not string.find(weakKey, "uid:", 1, true) then
        return false
    end
    if not string.find(strongKey, "fx:", 1, true) then
        return false
    end
    local weakParts = FingerprintRoleParts(weakKey)
    local strongParts = FingerprintRoleParts(strongKey)
    if #weakParts == 0 or #weakParts ~= #strongParts then
        return false
    end
    local function StripMainIdentity(seg)
        seg = tostring(seg or "")
        seg = string.gsub(seg, "|uid:%d+", "")
        seg = string.gsub(seg, "|fx:%d+", "")
        -- EFFECT bonus lands as b:...6=N... when stamped; drop lone 6= from bonus list noise.
        return seg
    end
    for i = 1, #weakParts do
        local w = weakParts[i]
        local s = strongParts[i]
        if w == s then
            -- exact role segment match
        elseif string.find(w, "^mainx", 1) and string.find(s, "^mainx", 1) then
            if StripMainIdentity(w) ~= StripMainIdentity(s) then
                -- Allow bonus list to gain EFFECT ref 6 on the strong side.
                local wNoB = string.gsub(StripMainIdentity(w), "|b:[^|]*", "")
                local sNoB = string.gsub(StripMainIdentity(s), "|b:[^|]*", "")
                if wNoB ~= sNoB then
                    return false
                end
            end
        else
            return false
        end
    end
    return true
end

local function IsWeakerFingerprint(weakKey, strongKey)
    return IsStrictFingerprintSubset(weakKey, strongKey)
        or IsIncompleteMainUpgrade(weakKey, strongKey)
end

--- recipeKeys plus the active pointers (deduped).
local function CollectPotionRecipeKeyList(potion)
    local seen = {}
    local out = {}
    local function add(k)
        k = tostring(k or "")
        if k ~= "" and seen[k] ~= true then
            seen[k] = true
            out[#out + 1] = k
        end
    end
    if type(potion) ~= "table" then
        return out
    end
    if type(potion.recipeKeys) == "table" then
        for i = 1, #potion.recipeKeys do
            add(potion.recipeKeys[i])
        end
    end
    add(potion.activeRecipeKey)
    add(potion.activeRecipeSpecKey)
    add(potion.recipeSpecKey)
    return out
end

local function RecipeOutcomeUidSet(recipe)
    local uids = {}
    if type(recipe) ~= "table" then
        return uids
    end
    if type(recipe.outcomes) == "table" then
        for uidStr, _ in pairs(recipe.outcomes) do
            local uid = tonumber(uidStr) or 0
            if uid > 0 then
                uids[uid] = true
            end
        end
    end
    local outUid = tonumber(recipe.outputUid) or tonumber(recipe.activeOutcomeUid) or 0
    if outUid > 0 then
        uids[outUid] = true
    end
    return uids
end

local function RecipeOutcomesOverlap(a, b)
    local ua = RecipeOutcomeUidSet(a)
    local ub = RecipeOutcomeUidSet(b)
    -- Empty outcomes must not match everything (scrub was deleting live recipes).
    if next(ua) == nil or next(ub) == nil then
        return false
    end
    for uid in pairs(ua) do
        if ub[uid] == true then
            return true
        end
    end
    return false
end

local function AddWatchRecipeKey(out, watchKey, watch)
    if type(watch) ~= "table" then
        return
    end
    local parsed = RS.ParsePotionRecipeKey(tostring(watchKey))
    if type(parsed) == "table" and type(parsed.recipeSpecKey) == "string" then
        out[parsed.recipeSpecKey] = true
    end
    local rk = watch.recipeSpecKey or watch.activeRecipeKey
    if type(rk) == "string" and rk ~= "" then
        out[rk] = true
    end
end

--- Recipe fingerprints pointed at by any character's potion watches.
--- Disabled watches are included. Scrubbing only the current character's
--- enabled set let a later pass delete other characters' watches (KNW-1).
--- Reads Settings directly: Watch.GetWatches() creates a character row.
local function WatchReferencedRecipeKeys()
    local out = {}
    local settings = StockPiler.Settings
    if type(settings) ~= "table" or type(settings.characters) ~= "table" then
        return out
    end
    for _, char in pairs(settings.characters) do
        if type(char) == "table" and type(char.watches) == "table" then
            for watchKey, watch in pairs(char.watches) do
                AddWatchRecipeKey(out, watchKey, watch)
            end
        end
    end
    return out
end

local function ApplyPotionRecipeKeyList(potion, kept)
    potion.recipeKeys = kept
    potion.alternateRecipeSpecKeys = nil
    local active = tostring(potion.activeRecipeKey or potion.activeRecipeSpecKey or "")
    local activeOk = false
    for i = 1, #kept do
        if kept[i] == active then
            activeOk = true
            break
        end
    end
    if not activeOk then
        local best = kept[1] or ""
        for i = 2, #kept do
            if #tostring(kept[i]) > #tostring(best) then
                best = kept[i]
            end
        end
        potion.activeRecipeKey = best ~= "" and best or nil
        potion.activeRecipeSpecKey = potion.activeRecipeKey
        if potion.activeRecipeKey then
            potion.recipeSpecKey = potion.activeRecipeKey
        end
    end
end

function RS.RegisterKnownPotion(outputUid, out, recipeSpecKey, quality, opts)
    outputUid = tonumber(outputUid) or 0
    if outputUid <= 0 then
        return nil, false, false
    end
    opts = type(opts) == "table" and opts or {}
    local potions = PotionsTable()
    if type(potions) ~= "table" then
        return nil, false, false
    end
    local potionKey = RS.PotionKeyFromUid(outputUid)
    local existing = potions[potionKey]
    local isNew = type(existing) ~= "table"
    if isNew then
        existing = {
            potionKey = potionKey,
            outputUid = outputUid,
            recipeKeys = {},
        }
        if opts.skillUpOrigin == true then
            existing.skillUpOrigin = true
        end
    end
    -- Chat-link imports must not rename a potion, switch its active recipe,
    -- drop a weaker key, or write the shared item cache.
    local linkImport = opts.linkImport == true
    if linkImport then
        if isNew then
            existing.name = (out and out.name) or existing.name
            existing.nameNarrow = (out and (out.nameNarrow or ToNarrow(out.name))) or existing.nameNarrow
            existing.iconNum = (out and tonumber(out.iconNum)) or existing.iconNum or 0
        end
    else
        existing.name = (out and out.name) or existing.name
        existing.nameNarrow = (out and (out.nameNarrow or ToNarrow(out.name))) or existing.nameNarrow
        existing.iconNum = (out and tonumber(out.iconNum)) or existing.iconNum or 0
    end
    if existing.linimentClass ~= true then
        if RS.IsLinimentClass({ name = existing.name, uid = outputUid }) then
            existing.linimentClass = true
        end
    end
    if not linkImport and StockPiler.Items and StockPiler.Items.StoreItem then
        StockPiler.Items.StoreItem(
            (out and type(out.itemData) == "table") and out.itemData or out or { uniqueID = outputUid },
            "potion"
        )
    end
    recipeSpecKey = tostring(recipeSpecKey or "")
    local recipeKeyAdded = false
    local replacedWeaker = false
    if linkImport and quality ~= "failed" and recipeSpecKey ~= "" then
        local keys = CollectPotionRecipeKeyList(existing)
        local seen = false
        for i = 1, #keys do
            if keys[i] == recipeSpecKey then
                seen = true
                break
            end
        end
        if not seen then
            keys[#keys + 1] = recipeSpecKey
            existing.recipeKeys = keys
            recipeKeyAdded = true
        end
        local active = tostring(existing.activeRecipeKey or existing.activeRecipeSpecKey or "")
        if active == "" then
            existing.activeRecipeKey = recipeSpecKey
            existing.activeRecipeSpecKey = recipeSpecKey
            existing.recipeSpecKey = recipeSpecKey
        end
        potions[potionKey] = existing
        return existing, isNew, recipeKeyAdded, false
    end
    if quality ~= "failed" and recipeSpecKey ~= "" then
        local keys = CollectPotionRecipeKeyList(existing)
        -- Incomplete board snapshots (missing mid/trailing slots) are subsets of the
        -- full fingerprint - do not register them as alternate recipes / active.
        local weaker = false
        for i = 1, #keys do
            local existingKey = tostring(keys[i] or "")
            if existingKey ~= "" and IsWeakerFingerprint(recipeSpecKey, existingKey) then
                weaker = true
                break
            end
        end
        if not weaker then
            local seen = false
            for i = 1, #keys do
                if keys[i] == recipeSpecKey then
                    seen = true
                    break
                end
            end
            if not seen then
                keys[#keys + 1] = recipeSpecKey
                recipeKeyAdded = true
            end
            -- Drop any previously linked keys that are strict subsets of this one.
            local kept = {}
            for i = 1, #keys do
                local k = tostring(keys[i] or "")
                if k ~= "" and not IsWeakerFingerprint(k, recipeSpecKey) then
                    kept[#kept + 1] = k
                elseif k ~= "" and k ~= recipeSpecKey then
                    replacedWeaker = true
                end
            end
            ApplyPotionRecipeKeyList(existing, kept)
            existing.activeRecipeKey = recipeSpecKey
            existing.activeRecipeSpecKey = recipeSpecKey
            existing.recipeSpecKey = recipeSpecKey
            RS.ResolveEffectKeyForPotion(existing, {
                recipeKey = recipeSpecKey,
                out = out,
                itemData = out and (out.itemData or out) or nil,
                stamp = true,
            })
        end
    end
    potions[potionKey] = existing
    return existing, isNew, recipeKeyAdded, replacedWeaker == true
end

--- An unverified chat import must not win a subset scrub over a recipe the player brewed.
local function RecipeCanDominate(recipe)
    if type(recipe) ~= "table" then
        return false
    end
    if recipe.sharedImport == true or recipe.unverified == true then
        return false
    end
    return true
end

--- Drop dangling / dominated alternate fingerprints on potions.
--- Removes keys missing from recipes, and role-subset keys of a richer sibling.
--- Never drop fingerprints still referenced by any character's watch.
function RS.ScrubSubsetPotionRecipeKeys()
    local potions = PotionsTable()
    local recipes = RecipesTable()
    if type(potions) ~= "table" then
        return 0
    end
    local watchKeys = WatchReferencedRecipeKeys()
    local removed = 0
    for _, potion in pairs(potions) do
        if type(potion) == "table" then
            local keys = CollectPotionRecipeKeyList(potion)
            if #keys > 0 then
                local kept = {}
                for i = 1, #keys do
                    local a = tostring(keys[i] or "")
                    local drop = false
                    if a == "" then
                        drop = true
                    elseif watchKeys[a] == true then
                        drop = false
                    elseif type(recipes) ~= "table" or type(recipes[a]) ~= "table" then
                        drop = true
                    else
                        for j = 1, #keys do
                            local b = tostring(keys[j] or "")
                            if a ~= b
                                and type(recipes[b]) == "table"
                                and RecipeCanDominate(recipes[b])
                                and IsWeakerFingerprint(a, b)
                            then
                                drop = true
                                break
                            end
                        end
                    end
                    if drop then
                        removed = removed + 1
                    else
                        kept[#kept + 1] = a
                    end
                end
                ApplyPotionRecipeKeyList(potion, kept)
            end
        end
    end
    return removed
end

--- Delete unreferenced recipes that are role-subsets of a richer recipe sharing outcomes.
--- Never delete fingerprints still referenced by any character's watch.
function RS.ScrubOrphanSubsetRecipes()
    local recipes = RecipesTable()
    local potions = PotionsTable()
    if type(recipes) ~= "table" then
        return 0
    end
    local referenced = {}
    if type(potions) == "table" then
        for _, potion in pairs(potions) do
            if type(potion) == "table" then
                local keys = CollectPotionRecipeKeyList(potion)
                for i = 1, #keys do
                    referenced[keys[i]] = true
                end
            end
        end
    end
    local watchKeys = WatchReferencedRecipeKeys()
    for k in pairs(watchKeys) do
        referenced[k] = true
    end
    local allKeys = {}
    for k, recipe in pairs(recipes) do
        if type(recipe) == "table" then
            allKeys[#allKeys + 1] = tostring(k)
        end
    end
    local removed = 0
    for i = 1, #allKeys do
        local a = allKeys[i]
        if referenced[a] ~= true and type(recipes[a]) == "table" then
            local drop = false
            for j = 1, #allKeys do
                local b = allKeys[j]
                if a ~= b
                    and type(recipes[b]) == "table"
                    and RecipeCanDominate(recipes[b])
                    and IsWeakerFingerprint(a, b)
                    and RecipeOutcomesOverlap(recipes[a], recipes[b])
                then
                    drop = true
                    break
                end
            end
            if drop then
                recipes[a] = nil
                removed = removed + 1
            end
        end
    end
    return removed
end

function RS.ForgetPotionRecipeLink(outputUid, recipeSpecKey)
    outputUid = tonumber(outputUid) or 0
    recipeSpecKey = tostring(recipeSpecKey or "")
    if outputUid <= 0 or recipeSpecKey == "" then
        return false
    end
    local potions = PotionsTable()
    local recipes = RecipesTable()
    if type(potions) ~= "table" or type(recipes) ~= "table" then
        return false
    end
    local potionKey = RS.PotionKeyFromUid(outputUid)
    local potion = potions[potionKey]
    local recipe = recipes[recipeSpecKey]
    local hadLink = false
    if type(potion) == "table" then
        local keys = CollectPotionRecipeKeyList(potion)
        for i = 1, #keys do
            if keys[i] == recipeSpecKey then
                hadLink = true
                break
            end
        end
    end
    if type(recipe) == "table" and type(recipe.outcomes) == "table"
        and type(recipe.outcomes[tostring(outputUid)]) == "table"
    then
        hadLink = true
    end
    if not hadLink then
        return false
    end

    local function drop(list)
        if type(list) ~= "table" then
            return nil
        end
        local trimmed = {}
        for i = 1, #list do
            if tostring(list[i] or "") ~= recipeSpecKey then
                trimmed[#trimmed + 1] = list[i]
            end
        end
        return trimmed
    end

    if type(potion) == "table" then
        if type(potion.recipeKeys) == "table" then
            potion.recipeKeys = drop(potion.recipeKeys)
        end
        if potion.activeRecipeKey == recipeSpecKey
            or potion.activeRecipeSpecKey == recipeSpecKey
            or potion.recipeSpecKey == recipeSpecKey
        then
            local nextKey = type(potion.recipeKeys) == "table" and potion.recipeKeys[1] or nil
            potion.activeRecipeKey = nextKey
            potion.activeRecipeSpecKey = nextKey
            potion.recipeSpecKey = nextKey
        end
        if #CollectPotionRecipeKeyList(potion) == 0 then
            potions[potionKey] = nil
        end
    end

    if type(recipe) == "table" and type(recipe.outcomes) == "table" then
        recipe.outcomes[tostring(outputUid)] = nil
        local remaining = false
        for _ in pairs(recipe.outcomes) do
            remaining = true
            break
        end
        if not remaining then
            local stillLinked = false
            for _, other in pairs(potions) do
                if type(other) == "table" then
                    local oks = CollectPotionRecipeKeyList(other)
                    for i = 1, #oks do
                        if oks[i] == recipeSpecKey then
                            stillLinked = true
                            break
                        end
                    end
                end
                if stillLinked then
                    break
                end
            end
            if not stillLinked then
                recipes[recipeSpecKey] = nil
            end
        end
    end
    return true
end

function RS.RelinkPotionRecipeKeysFromOutcomes()
    local recipes = RecipesTable()
    local potions = PotionsTable()
    if type(recipes) ~= "table" or type(potions) ~= "table" then
        return 0
    end
    local added = 0
    for recipeKey, recipe in pairs(recipes) do
        recipeKey = tostring(recipeKey or "")
        if recipeKey ~= "" and type(recipe) == "table" and type(recipe.outcomes) == "table" then
            for uidStr, oc in pairs(recipe.outcomes) do
                local uid = tonumber(uidStr) or 0
                if uid > 0 and type(oc) == "table" then
                    local potionKey = RS.PotionKeyFromUid(uid)
                    local potion = potions[potionKey]
                    if type(potion) ~= "table" then
                        potion = {
                            potionKey = potionKey,
                            outputUid = uid,
                            recipeKeys = {},
                        }
                        potions[potionKey] = potion
                    end
                    local keys = CollectPotionRecipeKeyList(potion)
                    local weaker = false
                    for i = 1, #keys do
                        if IsWeakerFingerprint(recipeKey, tostring(keys[i] or "")) then
                            weaker = true
                            break
                        end
                    end
                    if not weaker then
                        local seen = false
                        for i = 1, #keys do
                            if keys[i] == recipeKey then
                                seen = true
                                break
                            end
                        end
                        if not seen then
                            if type(potion.recipeKeys) ~= "table" then
                                potion.recipeKeys = {}
                            end
                            potion.recipeKeys[#potion.recipeKeys + 1] = recipeKey
                            added = added + 1
                        end
                    end
                end
            end
        end
    end
    RS.ScrubSubsetPotionRecipeKeys()
    RS.ScrubOrphanSubsetRecipes()
    return added
end

function RS.StoreLearnedRecipeSpec(materials, outputs, opts)
    if type(materials) ~= "table" or #materials == 0 then
        return false
    end
    if type(outputs) ~= "table" then
        outputs = {}
    end
    opts = type(opts) == "table" and opts or {}
    -- Defense: SkillUp learns must not enter Account.recipes / potions.
    if opts.skillUpOrigin == true then
        if StockPiler.Debug and StockPiler.Debug.LogOp then
            StockPiler.Debug.LogOp("recipe", "reject StoreLearned skillUpOrigin")
        end
        return false
    end
    local recipes = RecipesTable()
    if type(recipes) ~= "table" then
        return false
    end
    local slots = MaterialsToSpecSlots(materials)
    if #slots == 0 then
        return false
    end
    -- Engine LOW: stab < 0 cannot succeed. Do not stamp bogus 100% recipes
    -- from incomplete SkillUp/board snapshots.
    if opts.failed ~= true then
        local stab = SpecStabilityTotal(slots)
        if stab < 0 then
            if StockPiler.Debug and StockPiler.Debug.LogOp then
                StockPiler.Debug.LogOp(
                    "recipe",
                    "reject StoreLearned unstable stab=" .. tostring(stab)
                )
            end
            return false
        end
    end
    local fingerprint = SlotsFingerprint(slots)
    if fingerprint == "" then
        return false
    end

    local byUid = {}
    local goodUid = nil
    local betterCount = 0
    local volatileCount = 0
    for i = 1, #outputs do
        local out = outputs[i]
        local uid = tonumber(out and out.uniqueID) or 0
        local quality = OutputQuality(out)
        if uid > 0 and quality ~= "failed" then
            byUid[uid] = out
            if quality == "potent" then
                betterCount = betterCount + 1
            elseif quality == "volatile" then
                volatileCount = volatileCount + 1
            elseif quality == "good" and goodUid == nil then
                goodUid = uid
            end
        end
    end
    local producedAny = next(byUid) ~= nil
    local failed = not producedAny
    local mainConsumed = opts.mainConsumed
    if mainConsumed == nil then
        mainConsumed = true
    end

    local recipe = recipes[fingerprint]
    local isNew = type(recipe) ~= "table"
    local structuralChange = isNew
    if isNew then
        recipe = {
            recipeSpecKey = fingerprint,
            slots = SlimSlotsForStorage(slots),
            outcomes = {},
            brewAttempts = 0,
            brewSuccesses = 0,
            brewCrits = 0,
            brewSuperCrits = 0,
            brewFailures = 0,
            brewVolatiles = 0,
            yieldProductSum = 0,
            yieldSamples = 0,
            crafts = 0,
            quality = "good",
        }
    else
        EnsureBrewStats(recipe)
        recipe.slots = SlimSlotsForStorage(slots)
    end
    if opts.skillUpOrigin == true then
        recipe.skillUpOrigin = true
    end

    recipe.brewAttempts = (tonumber(recipe.brewAttempts) or 0) + 1
    if failed then
        recipe.brewFailures = (tonumber(recipe.brewFailures) or 0) + 1
    else
        recipe.brewSuccesses = (tonumber(recipe.brewSuccesses) or 0) + 1
        recipe.crafts = (tonumber(recipe.crafts) or 0) + 1
        -- A real craft replaces the unverified chat-import marker.
        recipe.sharedImport = nil
        recipe.unverified = nil
        local primaryQty = 0
        local skillUpOpts = opts.skillUpOrigin == true and { skillUpOrigin = true } or nil
        local learnName = nil
        local learnIsNew = false
        local learnRank = 0
        for uid, out in pairs(byUid) do
            local quality = OutputQuality(out)
            local qty = tonumber(out.lastDelta) or tonumber(out.crafts) or 1
            local acceptedQty = RecordOutcome(recipe, uid, quality, qty)
            local _, potionIsNew, recipeKeyAdded, replacedSubset = RS.RegisterKnownPotion(
                uid, out, fingerprint, quality, skillUpOpts
            )
            if potionIsNew == true or recipeKeyAdded == true then
                structuralChange = true
            end
            local announce = potionIsNew == true
                or (recipeKeyAdded == true and replacedSubset ~= true)
            if announce then
                local rank = quality == "good" and 2 or 1
                if learnName == nil or rank > learnRank then
                    local potionName = out and out.name
                    if type(potionName) ~= "wstring" then
                        potionName = towstring(tostring(potionName or uid))
                    end
                    learnName = potionName
                    learnIsNew = potionIsNew == true
                    learnRank = rank
                end
            end
            if quality == "good" and (tonumber(acceptedQty) or 0) > 0 then
                primaryQty = primaryQty + acceptedQty
            end
        end
        if learnName ~= nil and StockPiler.Debug and StockPiler.Debug.Notify then
            local Util = StockPiler.Util
            local msgKey = learnIsNew == true and "brew.learned" or "brew.learned_alt"
            local msg = Util and Util.T and Util.T(msgKey, { name = learnName }) or learnName
            StockPiler.Debug.Notify(msg)
        end
        if primaryQty > 0 then
            recipe.yieldProductSum = (tonumber(recipe.yieldProductSum) or 0) + primaryQty
            recipe.yieldSamples = (tonumber(recipe.yieldSamples) or 0) + 1
            recipe.recipeYield = recipe.yieldProductSum / recipe.yieldSamples
        end
        if betterCount > 0 and goodUid == nil then
            recipe.brewSuperCrits = (tonumber(recipe.brewSuperCrits) or 0) + 1
        end
        if volatileCount > 0 and betterCount == 0 and goodUid == nil then
            recipe.brewVolatiles = (tonumber(recipe.brewVolatiles) or 0) + 1
        end
        if mainConsumed == false then
            recipe.brewCrits = (tonumber(recipe.brewCrits) or 0) + 1
        end
        if goodUid then
            recipe.activeOutcomeUid = goodUid
            recipe.outputUid = goodUid
        elseif recipe.activeOutcomeUid == nil then
            for uid in pairs(byUid) do
                recipe.activeOutcomeUid = uid
                recipe.outputUid = uid
                break
            end
        end
    end

    recipes[fingerprint] = recipe
    -- Defensive: tag liniment-class when main is a special liniment ingredient.
    if recipe.linimentClass ~= true then
        local ME = StockPiler.MaterialExceptions
        for i = 1, #slots do
            local spec = slots[i] and slots[i].spec
            if type(spec) == "table" and tostring(spec.role or "") == "main" then
                if RS.IsLinimentClass(spec)
                    or (ME and ME.LooksLinimentIngredient and ME.LooksLinimentIngredient(spec))
                then
                    recipe.linimentClass = true
                    break
                end
            end
        end
    end
    if recipe.linimentClass == true then
        for uid in pairs(byUid) do
            local potions = PotionsTable()
            local row = type(potions) == "table" and potions[RS.PotionKeyFromUid(uid)]
            if type(row) == "table" then
                row.linimentClass = true
            end
        end
    end
    RS.SlimRecipeForStorage(recipe)
    BumpRecipeStatsGen()
    local relinked = tonumber(RS.RelinkPotionRecipeKeysFromOutcomes()) or 0
    if relinked > 0 then
        structuralChange = true
    end

    if structuralChange
        and StockPiler.Knowledge
        and StockPiler.Knowledge.Touch
    then
        StockPiler.Knowledge.Touch("recipe")
        if StockPiler.PlanSnapshot and StockPiler.PlanSnapshot.Invalidate then
            StockPiler.PlanSnapshot.Invalidate()
        end
        local Sch = StockPiler.Scheduler
        if Sch and Sch.EnqueuePlanRebuild then
            -- Nudge: coalesce with bag-flush rebuild after brew, not a second full build.
            Sch.EnqueuePlanRebuild({ nudge = true })
        end
    end
    return true
end

--- Fold alternateRecipeSpecKeys into recipeKeys and drop the duplicate list.
function RS.FoldAlternateRecipeKeys()
    local potions = PotionsTable()
    if type(potions) ~= "table" then
        return 0
    end
    local folded = 0
    for _, potion in pairs(potions) do
        if type(potion) == "table" and potion.alternateRecipeSpecKeys ~= nil then
            local seen = {}
            local keys = {}
            local function add(k)
                k = tostring(k or "")
                if k ~= "" and seen[k] ~= true then
                    seen[k] = true
                    keys[#keys + 1] = k
                end
            end
            if type(potion.recipeKeys) == "table" then
                for i = 1, #potion.recipeKeys do
                    add(potion.recipeKeys[i])
                end
            end
            if type(potion.alternateRecipeSpecKeys) == "table" then
                for i = 1, #potion.alternateRecipeSpecKeys do
                    add(potion.alternateRecipeSpecKeys[i])
                end
            end
            potion.recipeKeys = keys
            potion.alternateRecipeSpecKeys = nil
            folded = folded + 1
        end
    end
    return folded
end

--- One-time: rebuild recipe keys from MS.Key fingerprints; merge uid-bound duplicates;
--- relink potions + character watches. Retired: MigrateFingerprints no longer calls this.
function RS.MigrateRecipeFingerprintsV2()
    local acct = StockPiler.Account
    if type(acct) ~= "table" then
        return false
    end
    local recipes = RecipesTable()
    -- Re-run when flagged complete but recipes still use legacy uid: fingerprints.
    local needsRepair = false
    if type(recipes) == "table" then
        for key, _ in pairs(recipes) do
            if type(key) == "string" and string.find(key, ":uid:", 1, true) then
                needsRepair = true
                break
            end
        end
    end
    if acct.recipeFingerprintMigrateV2 == true and needsRepair ~= true then
        return false
    end
    if type(recipes) ~= "table" then
        acct.recipeFingerprintMigrateV2 = true
        return false
    end
    local keyMap = {} -- oldKey -> newKey
    local rebuilt = {}
    for oldKey, recipe in pairs(recipes) do
        if type(recipe) == "table" then
            HydrateRecipeSlots(recipe)
            local newKey = SlotsFingerprint(recipe.slots)
            if newKey == nil or newKey == "" then
                newKey = tostring(oldKey)
            end
            keyMap[tostring(oldKey)] = newKey
            local dest = rebuilt[newKey]
            if type(dest) ~= "table" then
                recipe.recipeSpecKey = newKey
                recipe.slots = SlimSlotsForStorage(recipe.slots)
                rebuilt[newKey] = recipe
            else
                -- Merge brew stats from duplicate (Fabricated vs normal key forms).
                local function addField(name)
                    dest[name] = (tonumber(dest[name]) or 0) + (tonumber(recipe[name]) or 0)
                end
                addField("brewAttempts")
                addField("brewSuccesses")
                addField("brewCrits")
                addField("brewSuperCrits")
                addField("brewFailures")
                addField("brewVolatiles")
                addField("yieldProductSum")
                addField("yieldSamples")
                addField("crafts")
                if type(recipe.outcomes) == "table" then
                    dest.outcomes = dest.outcomes or {}
                    for uid, row in pairs(recipe.outcomes) do
                        dest.outcomes[uid] = dest.outcomes[uid] or row
                    end
                end
                if (tonumber(dest.yieldSamples) or 0) > 0 then
                    dest.recipeYield = (tonumber(dest.yieldProductSum) or 0)
                        / (tonumber(dest.yieldSamples) or 1)
                end
            end
        end
    end
    -- Replace recipes table in place.
    for k in pairs(recipes) do
        recipes[k] = nil
    end
    for k, v in pairs(rebuilt) do
        recipes[k] = v
    end

    -- Relink potion recipeKeys.
    local potions = PotionsTable()
    if type(potions) == "table" then
        for _, potion in pairs(potions) do
            if type(potion) == "table" and type(potion.recipeKeys) == "table" then
                local seen = {}
                local nextKeys = {}
                for i = 1, #potion.recipeKeys do
                    local old = tostring(potion.recipeKeys[i] or "")
                    local neu = keyMap[old] or old
                    if neu ~= "" and seen[neu] ~= true then
                        seen[neu] = true
                        nextKeys[#nextKeys + 1] = neu
                    end
                end
                potion.recipeKeys = nextKeys
                potion.alternateRecipeSpecKeys = nil
            end
        end
    end

    -- Relink character watches (all characters in Settings).
    local settings = StockPiler.Settings
    if type(settings) == "table" and type(settings.characters) == "table" then
        for _, char in pairs(settings.characters) do
            if type(char) == "table" and type(char.watches) == "table" then
                local nextWatches = {}
                for watchKey, watch in pairs(char.watches) do
                    if type(watch) == "table" then
                        local parsed = RS.ParsePotionRecipeKey and RS.ParsePotionRecipeKey(watchKey)
                        local newWatchKey = watchKey
                        if type(parsed) == "table" and parsed.recipeSpecKey then
                            local neuRk = keyMap[tostring(parsed.recipeSpecKey)]
                                or tostring(parsed.recipeSpecKey)
                            local outUid = tonumber(parsed.outputUid) or 0
                            if RS.PotionRecipeKey and outUid > 0 then
                                newWatchKey = RS.PotionRecipeKey(outUid, neuRk)
                            end
                        end
                        if watch.recipeSpecKey then
                            watch.recipeSpecKey = keyMap[tostring(watch.recipeSpecKey)]
                                or watch.recipeSpecKey
                        end
                        if watch.potionKey == nil and type(parsed) == "table" then
                            watch.potionKey = parsed.potionKey
                        end
                        nextWatches[newWatchKey] = watch
                    end
                end
                char.watches = nextWatches
            end
        end
    end

    acct.recipeFingerprintMigrateV2 = true
    if StockPiler.Knowledge and StockPiler.Knowledge.Touch then
        StockPiler.Knowledge.Touch("recipe-fingerprint-migrate-v2")
    end
    return true
end

local function MergeRecipeStats(dest, recipe)
    local function addField(name)
        dest[name] = (tonumber(dest[name]) or 0) + (tonumber(recipe[name]) or 0)
    end
    addField("brewAttempts")
    addField("brewSuccesses")
    addField("brewCrits")
    addField("brewSuperCrits")
    addField("brewFailures")
    addField("brewVolatiles")
    addField("yieldProductSum")
    addField("yieldSamples")
    addField("crafts")
    if type(recipe.outcomes) == "table" then
        dest.outcomes = dest.outcomes or {}
        for uid, row in pairs(recipe.outcomes) do
            local existing = dest.outcomes[uid]
            if type(existing) ~= "table" then
                dest.outcomes[uid] = row
            elseif type(row) == "table" then
                local destYieldN = tonumber(existing.yieldSamples)
                if destYieldN == nil then
                    destYieldN = tonumber(existing.successes) or 0
                end
                local srcYieldN = tonumber(row.yieldSamples)
                if srcYieldN == nil then
                    srcYieldN = tonumber(row.successes) or 0
                end
                existing.successes = (tonumber(existing.successes) or 0)
                    + (tonumber(row.successes) or 0)
                existing.productSum = (tonumber(existing.productSum) or 0)
                    + (tonumber(row.productSum) or 0)
                existing.yieldSamples = destYieldN + srcYieldN
                if type(row.qtyCounts) == "table" then
                    if type(existing.qtyCounts) ~= "table" then
                        existing.qtyCounts = {}
                    end
                    for qk, qn in pairs(row.qtyCounts) do
                        local qkey = tostring(qk)
                        existing.qtyCounts[qkey] = (tonumber(existing.qtyCounts[qkey]) or 0)
                            + (tonumber(qn) or 0)
                    end
                end
                if (tonumber(row.yield) or 0) > (tonumber(existing.yield) or 0) then
                    existing.yield = row.yield
                end
            end
        end
    end
    if (tonumber(dest.yieldSamples) or 0) > 0 then
        dest.recipeYield = (tonumber(dest.yieldProductSum) or 0)
            / (tonumber(dest.yieldSamples) or 1)
    end
end

--- Session-only. Account._repairQuarantine is not on the shutdown allow-list,
--- so anything stored there was deleted on reload (KNW-2).
local function RepairQuarantine()
    if type(RS._repairQuarantine) ~= "table" then
        RS._repairQuarantine = { recipes = {}, potions = {}, watches = {} }
    end
    local q = RS._repairQuarantine
    if type(q.recipes) ~= "table" then
        q.recipes = {}
    end
    if type(q.potions) ~= "table" then
        q.potions = {}
    end
    if type(q.watches) ~= "table" then
        q.watches = {}
    end
    return q
end

--- Rematerialize Account.recipes under current SlotsFingerprint / RecipeIdentityKey.
--- Merges collisions, drops empty/irreparable recipes, remaps potion + watch keys.
--- Idempotent. Returns { keyMap, merged, dropped, remapped, watchesDropped, potionsDropped }.
local function RematerializeRecipeFingerprints()
    local report = {
        keyMap = {},
        merged = 0,
        dropped = 0,
        remapped = 0,
        outcomesPruned = 0,
        watchesDropped = 0,
        potionsDropped = 0,
        droppedRecipeKeys = {},
        droppedPotionKeys = {},
        droppedWatchKeys = {},
    }
    local recipes = RecipesTable()
    if type(recipes) ~= "table" then
        return report
    end
    local quarantine = RepairQuarantine()

    local keyMap = report.keyMap
    local rebuilt = {}
    for oldKey, recipe in pairs(recipes) do
        if type(recipe) ~= "table" then
            report.dropped = report.dropped + 1
            report.droppedRecipeKeys[#report.droppedRecipeKeys + 1] = tostring(oldKey)
        else
            HydrateRecipeSlots(recipe)
            local oldKeyStr = tostring(oldKey)
            -- Unlink polluted potion keys under the key they currently reference.
            recipe.recipeSpecKey = oldKeyStr
            report.outcomesPruned = (tonumber(report.outcomesPruned) or 0)
                + (PruneOutcomesMismatchedToMainEffect(recipe) or 0)
            local slots = recipe.slots
            local newKey = ""
            if type(slots) == "table" and #slots > 0 then
                newKey = tostring(SlotsFingerprint(slots) or "")
            end
            if newKey == "" then
                -- Irreparable: no usable slot fingerprint — quarantine then drop.
                report.dropped = report.dropped + 1
                report.droppedRecipeKeys[#report.droppedRecipeKeys + 1] = oldKeyStr
                if quarantine then
                    quarantine.recipes[oldKeyStr] = recipe
                end
            else
                keyMap[oldKeyStr] = newKey
                if newKey ~= oldKeyStr then
                    report.remapped = report.remapped + 1
                end
                recipe.recipeSpecKey = newKey
                local dest = rebuilt[newKey]
                if type(dest) ~= "table" then
                    recipe.slots = SlimSlotsForStorage(slots)
                    rebuilt[newKey] = recipe
                else
                    MergeRecipeStats(dest, recipe)
                    dest.recipeSpecKey = newKey
                    report.outcomesPruned = (tonumber(report.outcomesPruned) or 0)
                        + (PruneOutcomesMismatchedToMainEffect(dest) or 0)
                    report.merged = report.merged + 1
                end
            end
        end
    end
    for k in pairs(recipes) do
        recipes[k] = nil
    end
    for k, v in pairs(rebuilt) do
        recipes[k] = v
    end

    local potions = PotionsTable()
    if type(potions) == "table" then
        local dropPotionKeys = {}
        for pk, potion in pairs(potions) do
            if type(potion) ~= "table" then
                dropPotionKeys[#dropPotionKeys + 1] = pk
            else
                local oldActive = tostring(
                    potion.activeRecipeKey
                        or potion.activeRecipeSpecKey
                        or potion.recipeSpecKey
                        or ""
                )
                local keys = CollectPotionRecipeKeyList(potion)
                local seen = {}
                local nextKeys = {}
                for i = 1, #keys do
                    local old = tostring(keys[i] or "")
                    local neu = keyMap[old] or old
                    if neu ~= "" and type(recipes[neu]) == "table" and seen[neu] ~= true then
                        seen[neu] = true
                        nextKeys[#nextKeys + 1] = neu
                    end
                end
                if #nextKeys == 0 then
                    dropPotionKeys[#dropPotionKeys + 1] = pk
                else
                    ApplyPotionRecipeKeyList(potion, nextKeys)
                    local neuActive = keyMap[oldActive] or oldActive
                    if neuActive ~= "" and seen[neuActive] == true then
                        potion.activeRecipeKey = neuActive
                        potion.activeRecipeSpecKey = neuActive
                        potion.recipeSpecKey = neuActive
                    else
                        potion.activeRecipeKey = nextKeys[1]
                        potion.activeRecipeSpecKey = nextKeys[1]
                        potion.recipeSpecKey = nextKeys[1]
                    end
                end
            end
        end
        for i = 1, #dropPotionKeys do
            local pk = dropPotionKeys[i]
            if quarantine and type(potions[pk]) == "table" then
                quarantine.potions[tostring(pk)] = potions[pk]
            end
            potions[pk] = nil
            report.potionsDropped = report.potionsDropped + 1
            report.droppedPotionKeys[#report.droppedPotionKeys + 1] = tostring(pk)
        end
    end

    local settings = StockPiler.Settings
    if type(settings) == "table" and type(settings.characters) == "table" then
        for charKey, char in pairs(settings.characters) do
            if type(char) == "table" and type(char.watches) == "table" then
                local nextWatches = {}
                for watchKey, watch in pairs(char.watches) do
                    if type(watch) == "table" then
                        local parsed = RS.ParsePotionRecipeKey and RS.ParsePotionRecipeKey(watchKey)
                        local newWatchKey = watchKey
                        local keep = true
                        if type(parsed) == "table" and parsed.recipeSpecKey then
                            local oldRk = tostring(parsed.recipeSpecKey)
                            local neuRk = keyMap[oldRk] or oldRk
                            local outUid = tonumber(parsed.outputUid) or 0
                            if type(recipes[neuRk]) ~= "table" then
                                keep = false
                                report.watchesDropped = report.watchesDropped + 1
                                report.droppedWatchKeys[#report.droppedWatchKeys + 1] =
                                    tostring(charKey) .. "|" .. tostring(watchKey)
                                if quarantine then
                                    quarantine.watches[tostring(charKey) .. "|" .. tostring(watchKey)] = watch
                                end
                            elseif RS.PotionRecipeKey and outUid > 0 then
                                newWatchKey = RS.PotionRecipeKey(outUid, neuRk)
                            end
                        end
                        if keep then
                            if watch.recipeSpecKey then
                                local wrk = keyMap[tostring(watch.recipeSpecKey)]
                                    or watch.recipeSpecKey
                                if type(recipes[tostring(wrk)]) == "table" then
                                    watch.recipeSpecKey = wrk
                                end
                            end
                            if watch.potionKey == nil and type(parsed) == "table" then
                                watch.potionKey = parsed.potionKey
                            end
                            if type(nextWatches[newWatchKey]) ~= "table" then
                                nextWatches[newWatchKey] = watch
                            end
                        end
                    end
                end
                char.watches = nextWatches
            end
        end
    end

    return report
end

--- One-shot: canonicalize fingerprints (load-order independent); merge order-duplicate recipes.
function RS.MigrateRecipeFingerprintsV3()
    local acct = StockPiler.Account
    if type(acct) ~= "table" then
        return false
    end
    if acct.recipeFingerprintMigrateV3 == true then
        return false
    end
    local recipes = RecipesTable()
    if type(recipes) ~= "table" then
        acct.recipeFingerprintMigrateV3 = true
        return false
    end
    RematerializeRecipeFingerprints()
    acct.recipeFingerprintMigrateV3 = true
    if StockPiler.Knowledge and StockPiler.Knowledge.Touch then
        StockPiler.Knowledge.Touch("recipe-fingerprint-migrate-v3")
    end
    return true
end

--- Idempotent saved-data repair for recipes/potions/watches.
--- Corrects fingerprint twins (TYPE/FAMILY noise, uid: vs fx:); drops irreparable rows.
function RS.ValidateAndRepairSavedRecipes()
    local report = RematerializeRecipeFingerprints()
    local scrubbed = 0
    if RS.ScrubSubsetPotionRecipeKeys then
        scrubbed = scrubbed + (tonumber(RS.ScrubSubsetPotionRecipeKeys()) or 0)
    end
    if RS.ScrubOrphanSubsetRecipes then
        scrubbed = scrubbed + (tonumber(RS.ScrubOrphanSubsetRecipes()) or 0)
    end
    report.scrubbed = scrubbed
    return report
end

--- Re-fingerprint after EFFECT stamps (e.g. resist families): merge incomplete-uid
--- SkillUp recipes into fx:-stamped siblings so Potions tab stops showing duplicates.
function RS.MigrateRecipeFingerprintsV4()
    local acct = StockPiler.Account
    if type(acct) ~= "table" then
        return false
    end
    if acct.recipeFingerprintMigrateV4 == true then
        return false
    end
    -- Force a V3-style rebuild once; clear the latch so the merge path runs.
    acct.recipeFingerprintMigrateV3 = nil
    local ok = RS.MigrateRecipeFingerprintsV3()
    acct.recipeFingerprintMigrateV4 = true
    if RS.ScrubSubsetPotionRecipeKeys then
        RS.ScrubSubsetPotionRecipeKeys()
    end
    if RS.ScrubOrphanSubsetRecipes then
        RS.ScrubOrphanSubsetRecipes()
    end
    if StockPiler.Knowledge and StockPiler.Knowledge.Touch then
        StockPiler.Knowledge.Touch("recipe-fingerprint-migrate-v4")
    end
    return ok == true
end

-- Expose hydrate for planner
function RS.HydrateRecipeSlots(recipe)
    HydrateRecipeSlots(recipe)
end

function RS.ResolveSlotSpec(slot)
    return ResolveSlotSpec(slot)
end

function RS.SpecStabilityTotal(slots)
    return SpecStabilityTotal(slots)
end

--- Tops up stabilizer/goldweed when learned perCraft leaves stability <= 0 (MEDIUM/fail).
function RS.EffectiveSpecPerCraft(slot, slots)
    return EffectiveSpecPerCraft(slot, slots)
end

--- Engine HIGH (safe succeed) needs stability total > 0; == 0 is MEDIUM/risky.
function RS.RecipeIsStable(recipe)
    if type(recipe) ~= "table" then
        return false
    end
    HydrateRecipeSlots(recipe)
    return SpecStabilityTotal(recipe.slots) > 0
end

function RS.MaterialsToSpecSlots(materials)
    return MaterialsToSpecSlots(materials)
end

function RS.SlotsFingerprint(slots)
    return SlotsFingerprint(slots)
end

----------------------------------------------------------------
-- Planner shims. Grow, Refine, UpgradeSeed, Planner, and Brew call these.
-- The work lives on Planner.
----------------------------------------------------------------

local function PlannerMod()
    return StockPiler.Planner
end

function RS.BuildBalancedSpecDemand(opts)
    local P = PlannerMod()
    if P and P.BuildBalancedSpecDemand then
        return P.BuildBalancedSpecDemand(opts)
    end
    return {}
end

function RS.WatchStillNeedsGrow(potion, recipe, target, watchKey)
    local P = PlannerMod()
    if P and P.WatchStillNeedsGrow then
        return P.WatchStillNeedsGrow(potion, recipe, target, watchKey) == true
    end
    return false
end

function RS.CollectAutoGrowSeedLines()
    local P = PlannerMod()
    if P and P.CollectAutoGrowSeedLines then
        return P.CollectAutoGrowSeedLines()
    end
    return {}
end

--- True when Seed Buffer is on and any growable refinable recipe line for this watch
--- is below the buffer (bag + in-ground + outstanding). Memoized per bag snap +
--- garden planGen + refine outstanding (planting must invalidate without a bag move).
--- opts.seedUids: known seed uniqueIDs from plan tip / statusTipSlots.
--- opts.plantUids: plants with no known seed (Savage Marshroot s0) — plant bag
--- count is the cushion so stimulant lines are not skipped by the seed-only hot path.
function RS.WatchHasSeedBufferShort(recipe, opts)
    if not (StockPiler.Watch and StockPiler.Watch.IsSeedBufferEnabled
        and StockPiler.Watch.IsSeedBufferEnabled() == true)
    then
        return false
    end
    if type(recipe) ~= "table" then
        return false
    end
    opts = type(opts) == "table" and opts or {}
    local Inv = StockPiler.Inventory
    local snapGen = Inv and Inv.GetSnapGen and tonumber(Inv.GetSnapGen()) or 0
    local gardenGen = 0
    local Garden = StockPiler.Garden
    if Garden then
        gardenGen = tonumber(Garden.GetPlanGen and Garden.GetPlanGen()
            or Garden.GetGen and Garden.GetGen()) or 0
    end
    local outstanding = 0
    local RP = StockPiler.RefinePipeline
    if RP and RP.GetOutstandingSum then
        outstanding = tonumber(RP.GetOutstandingSum()) or 0
    end
    local recipeId = tostring(
        recipe.specKey or recipe.recipeSpecKey or recipe.key or recipe
    )
    local memo = RS._seedBufferShortMemo
    if type(memo) ~= "table"
        or tonumber(memo.snapGen) ~= snapGen
        or tonumber(memo.gardenGen) ~= gardenGen
        or tonumber(memo.outstanding) ~= outstanding
    then
        memo = {
            snapGen = snapGen,
            gardenGen = gardenGen,
            outstanding = outstanding,
            byRecipe = {},
        }
        RS._seedBufferShortMemo = memo
    end
    if memo.byRecipe[recipeId] ~= nil then
        return memo.byRecipe[recipeId] == true
    end

    local Refine = StockPiler.Refine
    local buffer = StockPiler.Watch.GetSeedBufferMin and StockPiler.Watch.GetSeedBufferMin() or 5

    local function CreditForSeed(seedUid)
        seedUid = tonumber(seedUid) or 0
        if seedUid <= 0 then
            return nil
        end
        if Refine and Refine.GetSeedBudget then
            local budget = Refine.GetSeedBudget(seedUid)
            return tonumber(budget and budget.credit) or 0
        end
        if Inv and Inv.CountByUid then
            return tonumber(Inv.CountByUid(seedUid)) or 0
        end
        return 0
    end

    local function CreditForPlant(plantUid)
        plantUid = tonumber(plantUid) or 0
        if plantUid <= 0 or not Inv or not Inv.CountByUid then
            return nil
        end
        return tonumber(Inv.CountByUid(plantUid)) or 0
    end

    local function AnyUidShort(uids, creditFn)
        if type(uids) ~= "table" or #uids == 0 then
            return nil
        end
        local any = false
        local checked = false
        for i = 1, #uids do
            local credit = creditFn(uids[i])
            if credit ~= nil then
                checked = true
                if credit < buffer then
                    any = true
                    break
                end
            end
        end
        if not checked then
            return nil
        end
        return any
    end

    -- Hot path: stamped seed + plant uids (do not skip plant-only stimulant lines).
    local seedShort = AnyUidShort(opts.seedUids, CreditForSeed)
    local plantShort = AnyUidShort(opts.plantUids, CreditForPlant)
    if seedShort == true or plantShort == true then
        memo.byRecipe[recipeId] = true
        return true
    end
    local hotChecked = (type(opts.seedUids) == "table" and #opts.seedUids > 0)
        or (type(opts.plantUids) == "table" and #opts.plantUids > 0)
    if hotChecked and seedShort ~= true and plantShort ~= true then
        memo.byRecipe[recipeId] = false
        return false
    end

    local SM = StockPiler.SeedMap
    if type(SM) ~= "table" or not SM.IsGrowableSpec then
        memo.byRecipe[recipeId] = false
        return false
    end
    if RS.HydrateRecipeSlots then
        RS.HydrateRecipeSlots(recipe)
    end

    -- Prefer snap-cached AutoGrow seed lines (one ResolveSeed storm per snap) over
    -- per-slot ResolveSeed inside this recipe walk.
    local lineByKey = nil
    local lines = RS.CollectAutoGrowSeedLines and RS.CollectAutoGrowSeedLines() or nil
    if type(lines) == "table" and #lines > 0 then
        lineByKey = {}
        for i = 1, #lines do
            local line = lines[i]
            local k = type(line) == "table" and tostring(line.specKey or "") or ""
            if k ~= "" then
                lineByKey[k] = line
            end
        end
    end

    local slots = recipe.slots or {}
    local seen = {}
    local short = false
    for i = 1, #slots do
        local slot = slots[i]
        local spec = slot and (slot.spec or (RS.ResolveSlotSpec and RS.ResolveSlotSpec(slot)))
        if type(spec) == "table" and SM.IsGrowableSpec(spec) then
            if SM.IsOneWayHarvestSpec and SM.IsOneWayHarvestSpec(spec) == true then
                -- One-way: ignore for buffer short.
            else
                local productKey = SpecFingerprint(spec)
                if type(productKey) ~= "string" or productKey == "" then
                    local M = MS()
                    productKey = (M and M.ProductKey and M.ProductKey(spec)) or tostring(i)
                end
                if seen[productKey] ~= true then
                    seen[productKey] = true
                    local seedUid = 0
                    local plantUid = 0
                    local line = lineByKey and lineByKey[productKey]
                    if type(line) ~= "table" then
                        local M = MS()
                        local pk = M and M.ProductKey and M.ProductKey(spec)
                        if type(pk) == "string" and pk ~= "" and lineByKey then
                            line = lineByKey[pk]
                        end
                    end
                    if type(line) == "table" then
                        seedUid = tonumber(line.seedUid) or 0
                        plantUid = tonumber(line.plantUid) or 0
                    end
                    -- Cold miss only: ResolveSeed when seed lines cache has no mapping.
                    if seedUid <= 0 then
                        local seed = SM.ResolveSeedForSpec and SM.ResolveSeedForSpec(spec)
                        if type(seed) == "table" then
                            seedUid = tonumber(seed.uniqueID) or 0
                        end
                    end
                    if seedUid > 0 then
                        local credit = CreditForSeed(seedUid) or 0
                        if credit < buffer then
                            short = true
                            break
                        end
                    else
                        -- Bound uid / tip plant only — FindPlantUidForSpec is a full
                        -- bag+Items ProductMatches walk (0.3.348 Watch hitch / crash).
                        if plantUid <= 0 then
                            plantUid = tonumber(spec.uid) or tonumber(spec.uniqueID)
                                or tonumber(spec.boundUid) or 0
                        end
                        local have = CreditForPlant(plantUid)
                        if have ~= nil and have < buffer then
                            short = true
                            break
                        end
                    end
                end
            end
        end
    end
    memo.byRecipe[recipeId] = short
    return short
end

function RS.ShouldAutoGrowPotion(potionKey, watch)
    local Caps = StockPiler.TradeSkillCaps
    if Caps and Caps.CanAutoGrow and Caps.CanAutoGrow() ~= true then
        return false
    end
    local Watch = StockPiler.Watch
    if Watch and Watch.IsAutoGrowEnabled and Watch.IsAutoGrowEnabled() ~= true then
        return false
    end
    if type(watch) ~= "table" then
        if Watch and Watch.ResolveWatchEntry then
            watch = select(1, Watch.ResolveWatchEntry(potionKey))
        else
            local watches = Watch and Watch.GetWatches and Watch.GetWatches() or {}
            watch = type(watches) == "table" and watches[tostring(potionKey or "")] or nil
        end
    end
    return type(watch) == "table" and watch.enabled == true and watch.autoGrow == true
end
