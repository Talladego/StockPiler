----------------------------------------------------------------
-- StockPiler View/Catalog -- potion list + forget helpers
----------------------------------------------------------------

StockPiler = StockPiler or {}
StockPiler.Catalog = StockPiler.Catalog or {}
local Catalog = StockPiler.Catalog

local function ToNarrow(value)
    return StockPiler.Util.ToNarrow(value)
end

local function PotionRecipeKeys(potion)
    if type(potion) ~= "table" then
        return {}
    end
    local keys = potion.recipeKeys
    if type(keys) == "table" and #keys > 0 then
        return keys
    end
    local active = potion.activeRecipeKey or potion.activeRecipeSpecKey or potion.recipeSpecKey
    if type(active) == "string" and active ~= "" then
        return { active }
    end
    return {}
end

local function ListEntriesFromKnowledge()
    local out = {}
    local Know = StockPiler.Knowledge
    local RS = StockPiler.RecipeSpec
    local potions = Know and Know.Potions and Know.Potions() or Know and Know.GetTable and Know.GetTable("potions")
    local recipes = Know and Know.Recipes and Know.Recipes() or Know and Know.GetTable and Know.GetTable("recipes")
    if type(potions) ~= "table" then
        return out
    end
    for _, potion in pairs(potions) do
        if type(potion) == "table" then
            local uid = tonumber(potion.outputUid) or 0
            if uid > 0 then
                local keys = PotionRecipeKeys(potion)
                local seen = {}
                for i = 1, #keys do
                    local recipeKey = keys[i]
                    if type(recipeKey) == "string" and recipeKey ~= "" and seen[recipeKey] ~= true then
                        seen[recipeKey] = true
                        local recipe = type(recipes) == "table" and recipes[recipeKey] or nil
                        if type(recipe) == "table" then
                            -- Membership is potion.recipeKeys. Outcomes are brew samples and
                            -- may only exist for a sibling product that shares this fingerprint
                            -- (link relearn after Forget must still list the restored potion).
                            if RS and RS.HydrateRecipeSlots then
                                RS.HydrateRecipeSlots(recipe)
                            end
                            local prKey = RS and RS.PotionRecipeKey and RS.PotionRecipeKey(uid, recipeKey)
                                or ("uid:" .. tostring(uid) .. "|rk:" .. recipeKey)
                            local stats = { power = 0, stability = 0, multiplier = 0, superCrit = 0, yield = 0 }
                            if RS and RS.RecipeFingerprintStats then
                                stats = RS.RecipeFingerprintStats(recipe, uid) or stats
                            end
                            out[#out + 1] = {
                                potionRecipeKey = prKey,
                                potionKey = potion.potionKey or (RS and RS.PotionKeyFromUid and RS.PotionKeyFromUid(uid)),
                                outputUid = uid,
                                recipeSpecKey = recipeKey,
                                name = potion.name,
                                iconNum = tonumber(potion.iconNum) or 0,
                                effectKey = potion.effectKey,
                                recipeLabel = potion.recipeLabel or L"",
                                power = tonumber(stats.power) or 0,
                                stability = tonumber(stats.stability) or 0,
                                multiplier = tonumber(stats.multiplier) or 0,
                                superCrit = tonumber(stats.superCrit) or 0,
                                yield = tonumber(stats.yield) or 0,
                                skillUpOrigin = potion.skillUpOrigin == true
                                    or (type(recipe) == "table" and recipe.skillUpOrigin == true),
                                potion = potion,
                                recipe = recipe,
                            }
                        end
                    end
                end
            end
        end
    end
    table.sort(out, function(a, b)
        local na = string.lower(ToNarrow(a.name))
        local nb = string.lower(ToNarrow(b.name))
        if na == nb then
            return ToNarrow(a.recipeLabel) < ToNarrow(b.recipeLabel)
        end
        return na < nb
    end)
    return out
end

function Catalog.ListPotionRecipeEntries()
    local RS = StockPiler.RecipeSpec
    if RS and RS.ListPotionRecipeEntries then
        return RS.ListPotionRecipeEntries()
    end
    return ListEntriesFromKnowledge()
end

--- Peek only - listing potions must not create disabled SV stubs.
function Catalog.GetWatch(potionKey)
    if StockPiler.Watch and StockPiler.Watch.GetWatch then
        return StockPiler.Watch.GetWatch(potionKey)
    end
    return { enabled = false, targetStock = 40, autoGrow = false }
end

function Catalog.EnsureWatch(potionKey)
    if StockPiler.Watch and StockPiler.Watch.EnsureWatch then
        return StockPiler.Watch.EnsureWatch(potionKey)
    end
    return { enabled = false, targetStock = 40, autoGrow = false }
end

function Catalog.ClearWatchList()
    if StockPiler.Watch and StockPiler.Watch.ClearAll then
        return StockPiler.Watch.ClearAll()
    end
    return 0
end

function Catalog.ClearPlantWatchList()
    if StockPiler.Watch and StockPiler.Watch.ClearAllPlantWatches then
        return StockPiler.Watch.ClearAllPlantWatches()
    end
    return 0
end

function Catalog.PotionHaveCombined(potion)
    if type(potion) ~= "table" then
        return 0
    end
    local uid = tonumber(potion.outputUid) or 0
    if uid <= 0 or not StockPiler.Inventory or not StockPiler.Inventory.CountByUid then
        return 0
    end
    return tonumber(StockPiler.Inventory.CountByUid(uid)) or 0
end


--- Unlink one potion fingerprint from its learned recipe. Shared recipes stay if other potions remain.
function Catalog.ForgetPotionRecipeLink(outputUid, recipeSpecKey)
    local RS = StockPiler.RecipeSpec
    local removed = false
    if RS and RS.ForgetPotionRecipeLink then
        removed = RS.ForgetPotionRecipeLink(outputUid, recipeSpecKey) == true
        if removed and StockPiler.Knowledge and StockPiler.Knowledge.Touch then
            StockPiler.Knowledge.Touch()
        end
    end
    if removed == true then
        outputUid = tonumber(outputUid) or 0
        local potionKey = RS and RS.PotionKeyFromUid and RS.PotionKeyFromUid(outputUid)
            or ("uid:" .. tostring(outputUid))
        local potions = StockPiler.Knowledge and StockPiler.Knowledge.Potions and StockPiler.Knowledge.Potions()
        if outputUid > 0 and (type(potions) ~= "table" or potions[potionKey] == nil) then
            if StockPiler.Items and StockPiler.Items.RemoveByUid then
                StockPiler.Items.RemoveByUid(outputUid)
            end
        end
        local Watch = StockPiler.Watch
        if Watch and Watch.ScrubPotionRecipeWatch then
            Watch.ScrubPotionRecipeWatch(outputUid, recipeSpecKey)
        end
    end
    return removed
end

----------------------------------------------------------------
-- Plants catalog (refinable plants learned by harvest or by refining)
----------------------------------------------------------------

local function PlantBonusValue(bonuses, ref)
    if type(bonuses) ~= "table" then
        return 0
    end
    local v = bonuses[ref]
    if type(v) == "table" then
        return tonumber(v[1] or v.bonusValue) or 0
    end
    return tonumber(v) or 0
end

--- Apo plant craftingBonus map. isApo when family=Apothecary or TYPE slot present.
local function PlantApoCraftingBonusMap(itemData)
    local map = {}
    local isApo = false
    if type(itemData) ~= "table" or type(itemData.craftingBonus) ~= "table" then
        return map, false
    end
    local apoFamily = (GameData and GameData.TradeSkills and GameData.TradeSkills.APOTHECARY) or 4
    for _, bonus in pairs(itemData.craftingBonus) do
        if type(bonus) == "table" then
            local ref = tonumber(bonus.bonusReference) or 0
            local val = tonumber(bonus.bonusValue) or 0
            if val > 32767 then
                val = val - 65536
            end
            if ref > 0 then
                map[ref] = val
            end
            if ref == 5 and val == apoFamily then
                isApo = true
            end
            if ref == 8 and val > 0 then
                isApo = true
            end
        end
    end
    return map, isApo
end

--- Prefer non-zero craft fingerprint fields from learned Account.items over thin bag shells.
local function MergePlantSpec(preferred, fallback)
    if type(preferred) ~= "table" then
        return fallback
    end
    if type(fallback) ~= "table" then
        return preferred
    end
    local out = {}
    for k, v in pairs(fallback) do
        out[k] = v
    end
    for k, v in pairs(preferred) do
        out[k] = v
    end
    local pb = type(preferred.bonuses) == "table" and preferred.bonuses or {}
    local fb = type(fallback.bonuses) == "table" and fallback.bonuses or {}
    local bonuses = {}
    for ref, val in pairs(fb) do
        bonuses[ref] = val
    end
    for ref, val in pairs(pb) do
        local n = tonumber(val)
        if n == nil or n ~= 0 or bonuses[ref] == nil then
            bonuses[ref] = val
        end
    end
    out.bonuses = bonuses
    local function pickNum(a, b)
        a = tonumber(a) or 0
        b = tonumber(b) or 0
        if a ~= 0 then
            return a
        end
        return b
    end
    out.power = pickNum(preferred.power, fallback.power)
    out.stability = pickNum(preferred.stability, fallback.stability)
    out.duration = pickNum(preferred.duration, fallback.duration)
    out.skillLevel = pickNum(preferred.skillLevel, fallback.skillLevel)
    out.effectId = pickNum(preferred.effectId, fallback.effectId)
    out.slotType = pickNum(preferred.slotType, fallback.slotType)
    out.tradeSkill = pickNum(preferred.tradeSkill, fallback.tradeSkill)
    if preferred.role ~= nil and preferred.role ~= "" then
        out.role = preferred.role
    elseif fallback.role ~= nil then
        out.role = fallback.role
    end
    if preferred.incomplete == false or fallback.incomplete == false then
        out.incomplete = false
    else
        out.incomplete = preferred.incomplete == true or fallback.incomplete == true
    end
    return out
end

local function ItemDataHasCraftBonuses(itemData)
    if type(itemData) ~= "table" or type(itemData.craftingBonus) ~= "table" then
        return false
    end
    for _, bonus in pairs(itemData.craftingBonus) do
        if type(bonus) == "table" and (tonumber(bonus.bonusReference) or 0) > 0 then
            return true
        end
    end
    return false
end

local _plantRecipeIndex = nil
local _plantRecipeIndexGen = nil

local function BuildPlantRecipeIndex()
    local Know = StockPiler.Knowledge
    local gen = 0
    if Know and Know.GetGen then
        gen = tonumber(Know.GetGen()) or 0
    end
    if _plantRecipeIndex ~= nil and _plantRecipeIndexGen == gen then
        return _plantRecipeIndex
    end
    local byUid = {}
    local RS = StockPiler.RecipeSpec
    local SM = StockPiler.SeedMap
    local recipes = Know and Know.Recipes and Know.Recipes() or nil
    local potions = Know and Know.Potions and Know.Potions() or nil
    if type(recipes) ~= "table" then
        return byUid
    end
    local potionByOutcome = {}
    if type(potions) == "table" then
        for _, potion in pairs(potions) do
            if type(potion) == "table" then
                local uid = tonumber(potion.outputUid) or 0
                if uid > 0 then
                    potionByOutcome[tostring(uid)] = potion
                end
            end
        end
    end
    for recipeKey, recipe in pairs(recipes) do
        if type(recipe) == "table" then
            if RS and RS.HydrateRecipeSlots then
                RS.HydrateRecipeSlots(recipe)
            end
            local slots = recipe.slots or {}
            for i = 1, #slots do
                local slot = slots[i]
                if type(slot) == "table" and tostring(slot.role or "") ~= "container" then
                    local spec = slot.spec
                    if RS and RS.ResolveSlotSpec then
                        spec = RS.ResolveSlotSpec(slot) or spec
                    end
                    if not (SM and SM.IsHarvestByproduct and SM.IsHarvestByproduct(spec) == true) then
                        local plantUid = tonumber(slot.uid) or tonumber(slot.boundUid) or 0
                        if plantUid <= 0 and type(spec) == "table" then
                            plantUid = tonumber(spec.boundUid) or tonumber(spec.uid) or 0
                        end
                        if plantUid <= 0 and SM and SM.FindPlantUidForSpec and type(spec) == "table" then
                            plantUid = tonumber(SM.FindPlantUidForSpec(spec)) or 0
                        end
                        if plantUid > 0 then
                            local list = byUid[plantUid]
                            if list == nil then
                                list = {}
                                byUid[plantUid] = list
                            end
                            local potionEntries = {}
                            local names = {}
                            if type(recipe.outcomes) == "table" then
                                for ouid, _ in pairs(recipe.outcomes) do
                                    local pot = potionByOutcome[tostring(ouid)]
                                    local outUid = tonumber(ouid) or (type(pot) == "table" and tonumber(pot.outputUid)) or 0
                                    if type(pot) == "table" then
                                        local effectKey = pot.effectKey
                                        if (not effectKey or effectKey == "") and RS and RS.ResolveEffectKeyForPotion then
                                            effectKey = RS.ResolveEffectKeyForPotion(pot, {
                                                recipeKey = recipeKey,
                                                recipe = recipe,
                                                stamp = false,
                                            })
                                        end
                                        if type(effectKey) == "string" and effectKey ~= ""
                                            and RS and RS.NormalizeEffectKeyForUi
                                        then
                                            effectKey = RS.NormalizeEffectKeyForUi(effectKey) or effectKey
                                        end
                                        potionEntries[#potionEntries + 1] = {
                                            name = pot.name,
                                            outputUid = outUid,
                                            iconNum = tonumber(pot.iconNum) or 0,
                                            rarity = tonumber(pot.rarity) or 0,
                                            effectKey = effectKey,
                                            itemData = pot,
                                        }
                                        if pot.name ~= nil then
                                            names[#names + 1] = pot.name
                                        end
                                    end
                                end
                            end
                            list[#list + 1] = {
                                recipeKey = recipeKey,
                                role = slot.role or (spec and spec.role),
                                potions = potionEntries,
                                potionNames = names,
                            }
                        end
                    end
                end
            end
        end
    end
    _plantRecipeIndex = byUid
    _plantRecipeIndexGen = gen
    return byUid
end

--- Plants that refine back to a seed (excludes resin / one-way byproducts).
--- Harvest products and refine-learned plants both belong on Known plants.
function Catalog.ListPlantEntries()
    local out = {}
    local seen = {}
    local Know = StockPiler.Knowledge
    local SM = StockPiler.SeedMap
    local MS = StockPiler.MaterialSpec
    local Items = StockPiler.Items
    local Inv = StockPiler.Inventory
    local RS = StockPiler.RecipeSpec
    local recipeIndex = BuildPlantRecipeIndex()

    local function AddPlant(plantUid)
        plantUid = tonumber(plantUid) or 0
        if plantUid <= 0 or seen[plantUid] == true then
            return
        end
        local item = Items and Items.GetByUid and Items.GetByUid(plantUid) or nil
        -- Learned fingerprint first (bag AsItemData historically stripped craftingBonus).
        local learnedSpec = nil
        if Items and Items.ToSpec then
            learnedSpec = Items.ToSpec(plantUid)
        end
        local itemData = nil
        if Items and Items.AsItemData then
            itemData = Items.AsItemData(plantUid)
        end
        if type(itemData) ~= "table" and type(item) == "table" then
            if type(item.itemData) == "table" then
                itemData = item.itemData
            else
                itemData = item
            end
        end
        if Inv and Inv.GetSample then
            local sample = Inv.GetSample(plantUid)
            if type(sample) == "table" then
                -- Keep learned craftingBonus when bag sample is a thin shell.
                if ItemDataHasCraftBonuses(sample) or not ItemDataHasCraftBonuses(itemData) then
                    if type(itemData) ~= "table" then
                        itemData = sample
                    else
                        local merged = {}
                        for k, v in pairs(itemData) do
                            merged[k] = v
                        end
                        for k, v in pairs(sample) do
                            merged[k] = v
                        end
                        if ItemDataHasCraftBonuses(itemData) and not ItemDataHasCraftBonuses(sample) then
                            merged.craftingBonus = itemData.craftingBonus
                        end
                        itemData = merged
                    end
                else
                    -- Sample has no bonuses; keep learned itemData, overlay display fields.
                    if type(itemData) == "table" then
                        if sample.name ~= nil then
                            itemData.name = sample.name
                        end
                        if (tonumber(sample.iconNum) or 0) > 0 then
                            itemData.iconNum = sample.iconNum
                        end
                        if (tonumber(sample.rarity) or 0) > 0 then
                            itemData.rarity = sample.rarity
                        end
                    else
                        itemData = sample
                    end
                end
            end
        end
        -- Refine/grow can leave nameless uid stubs; try the item DB once.
        local needDb = type(itemData) ~= "table"
            or itemData.name == nil
            or itemData.name == L""
            or (tonumber(itemData.iconNum) or 0) <= 0
        if needDb and type(GetDatabaseItemData) == "function" then
            local ok, db = pcall(GetDatabaseItemData, plantUid)
            if ok and type(db) == "table" then
                if Items and Items.StoreItem then
                    local dbType = Items.ResolveItemType and Items.ResolveItemType(db) or 0
                    local typeOk = dbType == 0
                        or (Items.IsAllowedItemType and Items.IsAllowedItemType(dbType) == true)
                    if typeOk then
                        Items.StoreItem(db, "plant")
                    end
                    item = Items.GetByUid and Items.GetByUid(plantUid) or item
                    if Items.AsItemData then
                        itemData = Items.AsItemData(plantUid) or itemData
                    end
                end
                if type(itemData) ~= "table" then
                    itemData = db
                else
                    if (itemData.name == nil or itemData.name == L"") and db.name ~= nil then
                        itemData.name = db.name
                    end
                    if (tonumber(itemData.iconNum) or 0) <= 0 and (tonumber(db.iconNum) or 0) > 0 then
                        itemData.iconNum = db.iconNum
                    end
                    if not ItemDataHasCraftBonuses(itemData) and ItemDataHasCraftBonuses(db) then
                        itemData.craftingBonus = db.craftingBonus
                    end
                end
            end
        end
        if type(itemData) == "table" and Inv and Inv.ResolvePotionItemData then
            itemData = Inv.ResolvePotionItemData(nil, plantUid, itemData) or itemData
        end
        local liveSpec = nil
        if MS and MS.FromItemData and type(itemData) == "table" then
            liveSpec = MS.FromItemData(itemData)
        end
        if type(learnedSpec) ~= "table" and Items and Items.ToSpec then
            learnedSpec = Items.ToSpec(plantUid)
        end
        local spec = MergePlantSpec(learnedSpec, liveSpec)
        if type(spec) ~= "table" then
            return
        end
        -- Ghost refine stubs (uid only, never bag/DB name) stay off the Plants tab.
        local dispName = (item and item.name) or (itemData and itemData.name) or (spec and spec.name)
        if dispName == nil or dispName == L"" then
            return
        end
        if type(dispName) == "wstring" and type(WStringToString) == "function" then
            local narrow = WStringToString(dispName) or ""
            if narrow == "" or narrow == tostring(plantUid) then
                return
            end
        elseif tostring(dispName) == tostring(plantUid) then
            return
        end
        if SM and SM.IsHarvestByproduct and SM.IsHarvestByproduct(spec) == true then
            return
        end
        if SM and SM.IsOneWayHarvestSpec and SM.IsOneWayHarvestSpec(spec) == true then
            return
        end
        -- Must refine to a seed (or look like refinable plant with known seed link).
        local seedUid = 0
        if SM and SM.GetSeedUidsForPlant then
            local seeds = SM.GetSeedUidsForPlant(plantUid)
            if type(seeds) == "table" and #seeds > 0 then
                seedUid = tonumber(seeds[1]) or 0
            end
        end
        if seedUid <= 0 and SM and SM.ResolveSeedForSpec then
            local seed = SM.ResolveSeedForSpec(spec)
            if type(seed) == "table" then
                seedUid = tonumber(seed.uniqueID or seed.uid) or 0
            end
        end
        local refinable = true
        if SM and SM.ResolveIsRefinable then
            local r = SM.ResolveIsRefinable(spec)
            if r == false then
                refinable = false
            end
        elseif SM and SM.ItemLooksLikeRefinablePlant and type(itemData) == "table" then
            refinable = SM.ItemLooksLikeRefinablePlant(itemData) == true
        end
        if seedUid <= 0 and refinable ~= true then
            return
        end
        seen[plantUid] = true

        local bonuses = type(spec.bonuses) == "table" and spec.bonuses or {}
        local B = MS and MS.CraftBonusRefs and MS.CraftBonusRefs() or nil
        local power = tonumber(spec.power) or 0
        local stability = tonumber(spec.stability) or 0
        local duration = tonumber(spec.duration) or 0
        local multiplier = 0
        local superCrit = 0
        if type(bonuses) == "table" then
            -- bonus refs: STABILITY=1 POWER=2 DURATION=3 MULTIPLIER=4 SPECIAL_CHANCE=14
            power = power ~= 0 and power or PlantBonusValue(bonuses, 2)
            stability = stability ~= 0 and stability or PlantBonusValue(bonuses, 1)
            duration = duration ~= 0 and duration or PlantBonusValue(bonuses, 3)
            multiplier = PlantBonusValue(bonuses, 4)
            superCrit = PlantBonusValue(bonuses, 14)
        end
        if B then
            if power == 0 then
                power = PlantBonusValue(bonuses, B.POWER or 2)
            end
            if stability == 0 then
                stability = PlantBonusValue(bonuses, B.STABILITY or 1)
            end
            if duration == 0 then
                duration = PlantBonusValue(bonuses, B.DURATION or 3)
            end
            if multiplier == 0 then
                multiplier = PlantBonusValue(bonuses, B.MULTIPLIER or 4)
            end
            if superCrit == 0 then
                superCrit = PlantBonusValue(bonuses, B.SPECIAL_CHANCE or 14)
            end
        end
        -- Also read top-level fields on the learned Items row (StoreItem stamps these).
        if type(item) == "table" then
            if power == 0 then
                power = tonumber(item.power) or 0
            end
            if stability == 0 then
                stability = tonumber(item.stability) or 0
            end
            if duration == 0 then
                duration = tonumber(item.duration) or 0
            end
            if type(item.bonuses) == "table" then
                if multiplier == 0 then
                    multiplier = PlantBonusValue(item.bonuses, 4)
                end
                if superCrit == 0 then
                    superCrit = PlantBonusValue(item.bonuses, 14)
                end
            end
        end
        -- Live/DB apo plant craftingBonus is SoT for brew stats. Never use seed
        -- SPECIAL_CHANCE (cultivation Super-Crit / Fail Chance are unrelated).
        local liveMap, liveIsApo = PlantApoCraftingBonusMap(itemData)
        if liveIsApo then
            if liveMap[2] ~= nil then
                power = liveMap[2]
            end
            if liveMap[1] ~= nil then
                stability = liveMap[1]
            end
            if liveMap[3] ~= nil then
                duration = liveMap[3]
            end
            if liveMap[4] ~= nil then
                multiplier = liveMap[4]
            end
            -- Absent SPECIAL_CHANCE on apo plant => 0 (stabilizers have Mult instead).
            superCrit = liveMap[14] or 0
        elseif multiplier == 0 and type(itemData) == "table"
            and type(itemData.craftingBonus) == "table"
        then
            -- Non-apo fingerprints: may fill Mult gaps only. Never take SPECIAL_CHANCE
            -- here (could be cultivation seed Super-Crit).
            for _, bonus in pairs(itemData.craftingBonus) do
                if type(bonus) == "table" then
                    local ref = tonumber(bonus.bonusReference) or 0
                    local val = tonumber(bonus.bonusValue) or 0
                    if val > 32767 then
                        val = val - 65536
                    end
                    if ref == 4 then
                        multiplier = val
                    end
                end
            end
        end
        local role = tostring(spec.role or "")
        if role == "stabilizer" or role == "goldweed" then
            superCrit = 0
        end
        local apoLevel = tonumber(spec.skillLevel) or tonumber(spec.craftingSkillRequirement)
            or tonumber(item and item.skillLevel) or tonumber(item and item.skillReq)
            or tonumber(itemData and itemData.craftingSkillRequirement)
            or tonumber(itemData and itemData.skillLevel) or 0
        if apoLevel <= 0 and type(item) == "table" and type(item.bonuses) == "table" then
            apoLevel = tonumber(item.bonuses[9]) or 0
        end
        if apoLevel <= 0 then
            apoLevel = PlantBonusValue(bonuses, (B and B.CRAFTING_SKILL) or 9) or 0
        end
        if liveIsApo and liveMap[9] ~= nil then
            apoLevel = liveMap[9]
        end
        -- Prefer stamped learned effectId (from seed at harvest) over description matching.
        local effectId = 0
        if type(item) == "table" then
            effectId = tonumber(item.effectId) or 0
            if effectId <= 0 and type(item.bonuses) == "table" then
                effectId = tonumber(item.bonuses[6]) or 0
            end
        end
        if effectId <= 0 then
            effectId = tonumber(spec.effectId) or 0
        end
        if effectId <= 0 then
            effectId = PlantBonusValue(bonuses, (B and B.EFFECT) or 6) or 0
        end
        local effectKey = nil
        if effectId > 0 and MS and MS.EffectKeyFromEffectId then
            effectKey = MS.EffectKeyFromEffectId(effectId)
        end
        if type(effectKey) == "string" and effectKey ~= "" and RS and RS.NormalizeEffectKeyForUi then
            effectKey = RS.NormalizeEffectKeyForUi(effectKey) or effectKey
        end
        -- Live fallback: seed map link -> seed EFFECT (before recipe / description).
        if (not effectKey or effectKey == "") and SM and SM.ResolveSeedEffectId then
            local seedUids = SM.GetSeedUidsForPlant and SM.GetSeedUidsForPlant(plantUid) or nil
            local bestSeed = seedUid
            if bestSeed <= 0 and SM.PickBestSeedUid and type(seedUids) == "table" then
                bestSeed = tonumber(SM.PickBestSeedUid(plantUid, seedUids)) or 0
            end
            if bestSeed <= 0 and type(seedUids) == "table" and #seedUids > 0 then
                bestSeed = tonumber(seedUids[1]) or 0
            end
            if bestSeed > 0 then
                local fromSeed = tonumber(SM.ResolveSeedEffectId(bestSeed)) or 0
                if fromSeed > 0 then
                    effectId = fromSeed
                    if MS and MS.EffectKeyFromEffectId then
                        effectKey = MS.EffectKeyFromEffectId(fromSeed)
                    end
                    if type(effectKey) == "string" and effectKey ~= "" and RS and RS.NormalizeEffectKeyForUi then
                        effectKey = RS.NormalizeEffectKeyForUi(effectKey) or effectKey
                    end
                end
            end
        end
        local recipes = recipeIndex[plantUid] or {}
        if (not effectKey or effectKey == "") and type(recipes) == "table" then
            for ri = 1, #recipes do
                local r = recipes[ri]
                if type(r) == "table" and tostring(r.role or "") == "main" and type(r.potions) == "table" then
                    for pi = 1, #r.potions do
                        local p = r.potions[pi]
                        if type(p) == "table" and type(p.effectKey) == "string" and p.effectKey ~= "" then
                            effectKey = p.effectKey
                            break
                        end
                    end
                end
                if effectKey and effectKey ~= "" then
                    break
                end
            end
        end
        if (not effectKey or effectKey == "") and type(itemData) == "table"
            and StockPiler.Classify and StockPiler.Classify.GetEffectKey
        then
            effectKey = StockPiler.Classify.GetEffectKey(itemData)
            if type(effectKey) == "string" and effectKey ~= "" and RS and RS.NormalizeEffectKeyForUi then
                effectKey = RS.NormalizeEffectKeyForUi(effectKey) or effectKey
            end
        end
        -- Non-main plants have no apo EFFECT id; show stabilizer/extender/multiplier/stimulant.
        if (not effectKey or effectKey == "") then
            local role = tostring(spec.role or "")
            if role == "stabilizer" or role == "goldweed" then
                effectKey = "stabilizer"
            elseif role == "extender" then
                effectKey = "extender"
            elseif role == "stimulant" then
                effectKey = "stimulant"
            elseif role == "multiplier" then
                effectKey = "multiplier"
            end
        end
        local have = 0
        if StockPiler.Inventory and StockPiler.Inventory.CountByUid then
            have = tonumber(StockPiler.Inventory.CountByUid(plantUid)) or 0
        end
        local plantKey = StockPiler.Watch and StockPiler.Watch.PlantKeyFromUid
            and StockPiler.Watch.PlantKeyFromUid(plantUid)
            or ("plant:" .. tostring(plantUid))
        out[#out + 1] = {
            plantKey = plantKey,
            plantUid = plantUid,
            seedUid = seedUid,
            name = (item and item.name) or (itemData and itemData.name) or (spec and spec.name) or towstring(tostring(plantUid)),
            iconNum = tonumber(item and item.iconNum) or tonumber(itemData and itemData.iconNum) or 0,
            apoLevel = apoLevel,
            effectKey = effectKey,
            effectId = effectId,
            power = power,
            stability = stability,
            duration = duration,
            multiplier = multiplier,
            superCrit = superCrit,
            have = have,
            recipes = recipes,
            recipeCount = #recipes,
            spec = spec,
            itemData = itemData or item,
            role = spec.role,
            rarity = tonumber(itemData and itemData.rarity) or tonumber(item and item.rarity) or tonumber(spec.rarity) or 0,
        }
    end

    local grows = Know and Know.Grows and Know.Grows() or nil
    if type(grows) == "table" then
        for _, bucket in pairs(grows) do
            if type(bucket) == "table" and type(bucket.products) == "table" then
                for _, prod in pairs(bucket.products) do
                    if type(prod) == "table" then
                        AddPlant(prod.uid)
                    else
                        AddPlant(prod)
                    end
                end
            end
        end
    end
    -- A plant refined before it was ever harvested is only in Refines.
    local refines = Know and Know.Refines and Know.Refines() or nil
    if type(refines) == "table" then
        for plantUidStr, bucket in pairs(refines) do
            local uid = tonumber(plantUidStr) or (type(bucket) == "table" and tonumber(bucket.plantUid)) or 0
            if uid > 0 and type(bucket) == "table" then
                local hasSeed = (tonumber(bucket.seedUid) or 0) > 0
                if not hasSeed and type(bucket.seedOut) == "table" then
                    for _ in pairs(bucket.seedOut) do
                        hasSeed = true
                        break
                    end
                end
                if hasSeed then
                    AddPlant(uid)
                end
            end
        end
    end

    table.sort(out, function(a, b)
        local na = string.lower(ToNarrow(a.name))
        local nb = string.lower(ToNarrow(b.name))
        if na == nb then
            return (tonumber(a.plantUid) or 0) < (tonumber(b.plantUid) or 0)
        end
        return na < nb
    end)
    return out
end

function Catalog.GetPlantWatch(plantKey)
    if StockPiler.Watch and StockPiler.Watch.GetPlantWatch then
        return StockPiler.Watch.GetPlantWatch(plantKey)
    end
    return { enabled = false, targetStock = 40, autoGrow = true }
end

function Catalog.PlantHave(plantUid)
    plantUid = tonumber(plantUid) or 0
    if plantUid <= 0 or not StockPiler.Inventory or not StockPiler.Inventory.CountByUid then
        return 0
    end
    return tonumber(StockPiler.Inventory.CountByUid(plantUid)) or 0
end

--- Forget a learned plant: drop grows product + refine row + item; scrub plant watch.
function Catalog.ForgetPlant(plantUid)
    plantUid = tonumber(plantUid) or 0
    if plantUid <= 0 then
        return false
    end
    local Know = StockPiler.Knowledge
    local grows = Know and Know.Grows and Know.Grows() or nil
    local refines = Know and Know.Refines and Know.Refines() or nil
    local items = Know and Know.Items and Know.Items() or nil
    local removed = false
    if type(grows) == "table" then
        for _, bucket in pairs(grows) do
            if type(bucket) == "table" and type(bucket.products) == "table" then
                local key = tostring(plantUid)
                if bucket.products[key] ~= nil then
                    bucket.products[key] = nil
                    removed = true
                end
            end
        end
    end
    if type(refines) == "table" and refines[tostring(plantUid)] ~= nil then
        refines[tostring(plantUid)] = nil
        removed = true
    end
    if type(items) == "table" and items[tostring(plantUid)] ~= nil then
        if StockPiler.Items and StockPiler.Items.RemoveByUid then
            StockPiler.Items.RemoveByUid(plantUid)
        else
            items[tostring(plantUid)] = nil
        end
        removed = true
    end
    local plantKey = StockPiler.Watch and StockPiler.Watch.PlantKeyFromUid
        and StockPiler.Watch.PlantKeyFromUid(plantUid) or ("plant:" .. tostring(plantUid))
    local pw = StockPiler.Watch and StockPiler.Watch.GetPlantWatches and StockPiler.Watch.GetPlantWatches()
    if type(pw) == "table" and pw[plantKey] ~= nil then
        pw[plantKey] = nil
        if StockPiler.Watch.BumpGen then
            StockPiler.Watch.BumpGen()
        end
        removed = true
    end
    if removed and Know and Know.Touch then
        Know.Touch("forget-plant")
    end
    return removed
end
