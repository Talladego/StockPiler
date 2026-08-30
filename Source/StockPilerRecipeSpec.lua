----------------------------------------------------------------
-- Recipe spec storage, known potions, spec matching
----------------------------------------------------------------

StockPiler.RecipeSpec = StockPiler.RecipeSpec or {}

local RS = StockPiler.RecipeSpec
local MS = StockPiler.MaterialSpec

local function ToNarrow(text)
    if text == nil then
        return ""
    end
    if type(text) == "wstring" then
        local ok, s = pcall(WStringToString, text)
        if ok and s then
            return s
        end
        return ""
    end
    return tostring(text)
end

local function EnsureSettings()
    if StockPiler.EnsureSettings then
        return StockPiler.EnsureSettings()
    end
    return StockPiler.Settings
end

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

function RS.PotionKeyFromUid(uid)
    uid = tonumber(uid) or 0
    if uid <= 0 then
        return nil
    end
    return "uid:" .. tostring(uid)
end

function RS.MaterialsToSpecSlots(materials)
    local slots = {}
    if type(materials) ~= "table" or not MS or not MS.FromItemData then
        return slots
    end
    for i = 1, #materials do
        local mat = materials[i]
        local itemData = mat.itemData
        if type(itemData) ~= "table" and StockPiler.Inventory then
            local uid = tonumber(mat.uniqueID) or 0
            if uid > 0 then
                local _, sample = StockPiler.Inventory.CountByUniqueId(uid)
                itemData = sample
            end
        end
        local spec = MS.FromItemData(itemData, mat.role)
        if spec then
            slots[#slots + 1] = {
                role = mat.role or spec.role,
                spec = MS.Copy(spec),
                perCraft = tonumber(mat.perCraft) or 1,
            }
            if StockPiler.SeedMap and StockPiler.SeedMap.RegisterFromItem then
                pcall(StockPiler.SeedMap.RegisterFromItem, itemData)
            end
            if StockPiler.SeedMap and StockPiler.SeedMap.MaybeLearnHarvestByproduct then
                pcall(StockPiler.SeedMap.MaybeLearnHarvestByproduct, itemData, spec)
            end
        end
    end
    table.sort(slots, function(a, b)
        return (ROLE_ORDER[a.role] or 99) < (ROLE_ORDER[b.role] or 99)
    end)
    return slots
end

function RS.BuildRecipeSpecKey(slots, outputUid)
    local parts = { "o:" .. tostring(tonumber(outputUid) or 0) }
    for i = 1, #slots do
        local slot = slots[i]
        if type(slot.spec) == "table" then
            parts[#parts + 1] = tostring(slot.role or "")
                .. "x" .. tostring(slot.perCraft or 1)
                .. ":" .. MS.Key(slot.spec)
        end
    end
    return table.concat(parts, "|")
end

function RS.OutputQuality(out)
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

function RS.RegisterKnownPotion(outputUid, out, recipeSpecKey, quality)
    outputUid = tonumber(outputUid) or 0
    if outputUid <= 0 then
        return nil
    end
    local s = EnsureSettings()
    if type(s.knownPotions) ~= "table" then
        s.knownPotions = {}
    end
    local potionKey = RS.PotionKeyFromUid(outputUid)
    local existing = s.knownPotions[potionKey]
    if type(existing) ~= "table" then
        existing = {
            potionKey = potionKey,
            outputUid = outputUid,
            alternateRecipeSpecKeys = {},
        }
    end
    existing.name = out and out.name or existing.name
    existing.nameNarrow = out and (out.nameNarrow or ToNarrow(out.name)) or existing.nameNarrow
    existing.iconNum = out and tonumber(out.iconNum) or existing.iconNum or 0
    if out and out.itemData and StockPiler.Classify and StockPiler.Classify.GetEffectKey then
        existing.effectKey = StockPiler.Classify.GetEffectKey(out.itemData)
    end
    if quality == "good" then
        local recipe = s.learnedRecipeSpecs and s.learnedRecipeSpecs[recipeSpecKey]
        local crafts = recipe and tonumber(recipe.crafts) or 0
        local active = s.learnedRecipeSpecs and existing.activeRecipeSpecKey
            and s.learnedRecipeSpecs[existing.activeRecipeSpecKey]
        local activeCrafts = active and tonumber(active.crafts) or 0
        if existing.activeRecipeSpecKey == nil or crafts >= activeCrafts then
            if existing.activeRecipeSpecKey and existing.activeRecipeSpecKey ~= recipeSpecKey then
                local alts = existing.alternateRecipeSpecKeys or {}
                local seen = {}
                for i = 1, #alts do
                    seen[alts[i]] = true
                end
                if not seen[existing.activeRecipeSpecKey] then
                    alts[#alts + 1] = existing.activeRecipeSpecKey
                end
                existing.alternateRecipeSpecKeys = alts
            end
            existing.activeRecipeSpecKey = recipeSpecKey
        else
            local alts = existing.alternateRecipeSpecKeys or {}
            local found = false
            for i = 1, #alts do
                if alts[i] == recipeSpecKey then
                    found = true
                    break
                end
            end
            if not found then
                alts[#alts + 1] = recipeSpecKey
            end
            existing.alternateRecipeSpecKeys = alts
        end
    end
    s.knownPotions[potionKey] = existing
    return existing
end

function RS.StoreLearnedRecipeSpec(materials, outputs, craftQuality)
    if type(materials) ~= "table" or #materials == 0 or type(outputs) ~= "table" or #outputs == 0 then
        return false
    end
    if not MS then
        return false
    end
    local s = EnsureSettings()
    if type(s.learnedRecipeSpecs) ~= "table" then
        s.learnedRecipeSpecs = {}
    end
    local slots = RS.MaterialsToSpecSlots(materials)
    if #slots == 0 then
        return false
    end
    local stored = false
    for i = 1, #outputs do
        local out = outputs[i]
        local uid = tonumber(out.uniqueID) or 0
        if uid > 0 then
            local quality = craftQuality or RS.OutputQuality(out)
            if quality == "potent" then
                quality = "good"
            end
            local key = RS.BuildRecipeSpecKey(slots, uid)
            local existing = s.learnedRecipeSpecs[key]
            local isNew = type(existing) ~= "table"
            if isNew then
                existing = {
                    recipeSpecKey = key,
                    outputUid = uid,
                    slots = slots,
                    quality = quality,
                    recipeYield = 2,
                    crafts = 0,
                }
            else
                existing.slots = slots
            end
            if quality == "good" or existing.quality == nil then
                existing.quality = quality
            end
            local delta = tonumber(out.lastDelta) or tonumber(out.crafts) or 1
            if quality == "good" then
                existing.recipeYield = delta
            end
            existing.crafts = (tonumber(existing.crafts) or 0) + 1
            if quality == "good" and type(out.name) == "wstring" and string.find(string.lower(ToNarrow(out.name)), "potent", 1, true) then
                existing.outputsPotentUid = uid
            end
            s.learnedRecipeSpecs[key] = existing
            if quality == "good" then
                RS.RegisterKnownPotion(uid, out, key, quality)
            end
            if StockPiler.Trace then
                local slotParts = {}
                for j = 1, #slots do
                    local slot = slots[j]
                    local spec = slot.spec
                    local fx = spec and spec.effectId or "?"
                    slotParts[#slotParts + 1] = tostring(slot.role or "?")
                        .. " fx=" .. tostring(fx)
                        .. " x" .. tostring(slot.perCraft or 1)
                end
                StockPiler.Trace("Spec recipe " .. (isNew and "new" or "update")
                    .. " uid=" .. tostring(uid)
                    .. " yield=" .. tostring(existing.recipeYield)
                    .. " slots=" .. table.concat(slotParts, ", "))
                if StockPiler.DebugEnabled == true and MS.Key then
                    StockPiler.D("Spec recipe key=" .. key)
                end
            end
            if StockPiler.Inventory and StockPiler.Inventory.InvalidateRecipeCaches then
                StockPiler.Inventory.InvalidateRecipeCaches()
            end
            if isNew and quality == "good" and StockPiler.NotifyRecipeLearned then
                StockPiler.NotifyRecipeLearned(out)
            end
            stored = true
        end
    end
    if stored and StockPiler.Planner and StockPiler.Planner.InvalidatePlanCache then
        pcall(StockPiler.Planner.InvalidatePlanCache)
    end
    return stored
end

function RS.ForgetLearnedRecipeSpec(recipeSpecKey)
    recipeSpecKey = tostring(recipeSpecKey or "")
    if recipeSpecKey == "" then
        return false
    end
    local s = EnsureSettings()
    if type(s.learnedRecipeSpecs) ~= "table" or s.learnedRecipeSpecs[recipeSpecKey] == nil then
        return false
    end
    local recipe = s.learnedRecipeSpecs[recipeSpecKey]
    s.learnedRecipeSpecs[recipeSpecKey] = nil
    local uid = tonumber(recipe.outputUid) or 0
    local potionKey = RS.PotionKeyFromUid(uid)
    if potionKey and type(s.knownPotions) == "table" then
        local potion = s.knownPotions[potionKey]
        if type(potion) == "table" then
            if potion.activeRecipeSpecKey == recipeSpecKey then
                potion.activeRecipeSpecKey = nil
                if type(potion.alternateRecipeSpecKeys) == "table" then
                    for j = 1, #potion.alternateRecipeSpecKeys do
                        local alt = potion.alternateRecipeSpecKeys[j]
                        if s.learnedRecipeSpecs[alt] and s.learnedRecipeSpecs[alt].quality == "good" then
                            potion.activeRecipeSpecKey = alt
                            break
                        end
                    end
                end
            end
        end
    end
    if StockPiler.Inventory and StockPiler.Inventory.InvalidateRecipeCaches then
        StockPiler.Inventory.InvalidateRecipeCaches()
    end
    if StockPiler.Planner and StockPiler.Planner.InvalidatePlanCache then
        pcall(StockPiler.Planner.InvalidatePlanCache)
    end
    return true
end

function RS.GetKnownPotionList()
    local s = EnsureSettings()
    local list = {}
    if type(s.knownPotions) ~= "table" then
        return list
    end
    for _, potion in pairs(s.knownPotions) do
        if type(potion) == "table" and potion.outputUid then
            list[#list + 1] = potion
        end
    end
    table.sort(list, function(a, b)
        return ToNarrow(a.name) < ToNarrow(b.name)
    end)
    return list
end

function RS.GetRecipeSpecList()
    local s = EnsureSettings()
    local list = {}
    if type(s.learnedRecipeSpecs) ~= "table" then
        return list
    end
    for key, recipe in pairs(s.learnedRecipeSpecs) do
        if type(recipe) == "table" then
            local uid = tonumber(recipe.outputUid) or 0
            local potion = s.knownPotions and s.knownPotions[RS.PotionKeyFromUid(uid)]
            list[#list + 1] = {
                recipeSpecKey = recipe.recipeSpecKey or key,
                outputUid = uid,
                slots = recipe.slots,
                quality = recipe.quality or "good",
                recipeYield = tonumber(recipe.recipeYield) or 2,
                crafts = tonumber(recipe.crafts) or 0,
                potionName = potion and potion.name,
                potionIcon = potion and potion.iconNum or 0,
            }
        end
    end
    table.sort(list, function(a, b)
        return ToNarrow(a.potionName) < ToNarrow(b.potionName)
    end)
    return list
end

function RS.RecipeSpecForPotion(potionKey)
    local s = EnsureSettings()
    if type(s.knownPotions) ~= "table" then
        return nil
    end
    local potion = s.knownPotions[potionKey]
    if type(potion) ~= "table" or not potion.activeRecipeSpecKey then
        return nil
    end
    if type(s.learnedRecipeSpecs) ~= "table" then
        return nil
    end
    local recipe = s.learnedRecipeSpecs[potion.activeRecipeSpecKey]
    if type(recipe) ~= "table" or recipe.quality ~= "good" then
        return nil
    end
    return recipe
end

function RS.ClearCountCaches()
    RS._specHaveCache = nil
    RS._demandCache = nil
    RS._demandSnapGen = nil
end

function RS.CountItemsMatchingSpec(spec)
    if type(spec) ~= "table" or not MS or not MS.Matches then
        return 0
    end
    local specKey = MS.Key and MS.Key(spec) or nil
    local cache = RS._specHaveCache
    if type(cache) == "table" and specKey ~= nil and cache[specKey] ~= nil then
        return cache[specKey]
    end
    local total = 0
    if StockPiler.Inventory and StockPiler.Inventory.ForEachItem then
        StockPiler.Inventory.ForEachItem(function(item)
            if StockPiler.Inventory.CanUseCraftingItem
                and not StockPiler.Inventory.CanUseCraftingItem(item)
            then
                return
            end
            if MS.Matches(item, spec) then
                local n = tonumber(item.stackCount) or tonumber(item.StackCount) or 1
                total = total + math.max(1, n)
            end
        end)
    end
    if type(cache) == "table" and specKey ~= nil then
        cache[specKey] = total
    end
    return total
end

function RS.SpecStabilityTotal(slots)
    local total = 0
    if type(slots) ~= "table" or not MS then
        return total
    end
    for i = 1, #slots do
        local slot = slots[i]
        local role = slot.role or ""
        if role ~= "extender" and role ~= "multiplier" and role ~= "stimulant" then
            local per = tonumber(slot.perCraft) or 1
            total = total + MS.Stability(slot.spec) * per
        end
    end
    return total
end

function RS.EffectiveSpecPerCraft(slot, slots)
    local perCraft = tonumber(slot.perCraft) or 1
    if type(slot) ~= "table" or type(slots) ~= "table" or not MS then
        return perCraft
    end
    local role = slot.role or ""
    if role ~= "stabilizer" and role ~= "goldweed" then
        return perCraft
    end
    local total = RS.SpecStabilityTotal(slots)
    if total >= 0 then
        return perCraft
    end
    local stab = MS.Stability(slot.spec)
    if stab <= 0 then
        return perCraft
    end
    return perCraft + math.ceil(-total / stab)
end

--- How many full crafts current bags can support (min over every slot).
function RS.CountCraftsPossible(recipe)
    if type(recipe) ~= "table" then
        return 0
    end
    local slots = recipe.slots
    if type(slots) ~= "table" or #slots == 0 then
        return 0
    end
    local possible = nil
    for i = 1, #slots do
        local slot = slots[i]
        if type(slot) == "table" and type(slot.spec) == "table" then
            local perCraft = RS.EffectiveSpecPerCraft(slot, slots)
            if perCraft < 1 then
                perCraft = 1
            end
            local have = RS.CountItemsMatchingSpec(slot.spec)
            local craftsHave = math.floor(have / perCraft)
            if possible == nil or craftsHave < possible then
                possible = craftsHave
            end
        end
    end
    return possible or 0
end

--- Best-case potions per brew from the learned recipe (often 2).
function RS.RecipeOutputYield(recipe)
    local yield = tonumber(recipe and recipe.recipeYield) or 2
    if yield < 1 then
        yield = 1
    end
    return yield
end

-- Watched stock is exact output uniqueID. A Lasting brew that produces
-- Potent does not raise this watch (treat that as a miss for this target).
-- Material / grow need still assumes recipe yield; if Potent leaves a
-- deficit, the next plan rebuild asks for more.
function RS.WatchStockYield(recipe)
    return RS.RecipeOutputYield(recipe)
end

--- Stock + best-case Craftable* already reaches Target#. AutoGrow should
--- not plant more for this watch.
function RS.WatchCoveredByBagsAndCraftable(potion, recipe, target)
    target = tonumber(target) or 0
    if target <= 0 then
        return true
    end
    local have = RS.PotionHaveCombined(potion)
    if have >= target then
        return true
    end
    if type(recipe) ~= "table" or not RS.CountPotionsCraftable then
        return false
    end
    return have + RS.CountPotionsCraftable(recipe) >= target
end

--- Crafts to cover a potion deficit at recipe yield (often 2). Potent crits
--- do not count toward this watch; they are a bonus, not extra material need.
function RS.CraftsNeededForDeficit(deficit, recipe)
    deficit = math.max(0, tonumber(deficit) or 0)
    if deficit <= 0 then
        return 0
    end
    local yield = RS.RecipeOutputYield(recipe)
    if yield < 1 then
        yield = 1
    end
    return math.max(1, math.ceil(deficit / yield))
end

--- Potion count those crafts would yield (crafts × recipe yield).
--- Best case: every output is this potion, not a Potent / other rarity.
function RS.CountPotionsCraftable(recipe)
    local crafts = RS.CountCraftsPossible(recipe)
    return crafts * RS.RecipeOutputYield(recipe)
end

--- Stock count for a watched potion is exact uniqueID only.
--- Potent / regular / other rarities are separate potions; watch each to target it.
function RS.PotionHaveCombined(potion)
    if type(potion) ~= "table" or not StockPiler.Inventory then
        return 0
    end
    local uid = tonumber(potion.outputUid) or 0
    if uid <= 0 or not StockPiler.Inventory.CountByUniqueId then
        return 0
    end
    local count = StockPiler.Inventory.CountByUniqueId(uid)
    return tonumber(count) or 0
end

function RS.EnsureWatch(potionKey)
    local s = EnsureSettings()
    if type(s.watches) ~= "table" then
        s.watches = {}
    end
    if type(s.watches[potionKey]) ~= "table" then
        s.watches[potionKey] = {
            enabled = false,
            autoGrow = true,
            targetStock = 40,
        }
    end
    if s.watches[potionKey].autoGrow == nil then
        s.watches[potionKey].autoGrow = true
    end
    return s.watches[potionKey]
end

-- Per-potion AutoGrow preference only (Watch-tab checkbox). Independent of global.
function RS.WatchWantsAutoGrow(watch)
    return type(watch) == "table" and watch.autoGrow ~= false
end

-- Watch is on the grow-demand list (enabled + AutoG). Independent of the global switch
-- so the plot plan can be built before Enable, and reused when the switch flips on.
function RS.WatchContributesGrowDemand(potionKey, watch)
    local s = EnsureSettings()
    if type(watch) ~= "table" then
        watch = type(s.watches) == "table" and s.watches[potionKey] or nil
    end
    return type(watch) == "table"
        and watch.enabled == true
        and RS.WatchWantsAutoGrow(watch)
end

-- AutoGrow watches still below target, with the lowest Craftable count.
-- Plot assignment uses only these recipes so a 0-craftable watch is not
-- starved by another watch's Goldweed (or any other extra plant).
function RS.CollectAutoGrowFocus()
    local s = EnsureSettings()
    local focus = {
        minCraftable = nil,
        watches = {},
    }
    if type(s.watches) ~= "table" or type(s.knownPotions) ~= "table" then
        return focus
    end
    local candidates = {}
    for potionKey, watch in pairs(s.watches) do
        if RS.WatchContributesGrowDemand(potionKey, watch) then
            local potion = s.knownPotions[potionKey]
            local recipe = RS.RecipeSpecForPotion(potionKey)
            if type(potion) == "table" and type(recipe) == "table" and recipe.quality == "good" then
                local target = tonumber(watch.targetStock) or 0
                local have = RS.PotionHaveCombined(potion)
                local deficit = math.max(0, target - have)
                if deficit > 0 and target > 0
                    and not RS.WatchCoveredByBagsAndCraftable(potion, recipe, target)
                then
                    local craftable = RS.CountPotionsCraftable(recipe)
                    candidates[#candidates + 1] = {
                        potionKey = potionKey,
                        name = potion.name or L"",
                        nameNarrow = potion.nameNarrow or ToNarrow(potion.name),
                        craftable = craftable,
                        recipe = recipe,
                    }
                    if focus.minCraftable == nil or craftable < focus.minCraftable then
                        focus.minCraftable = craftable
                    end
                end
            end
        end
    end
    for i = 1, #candidates do
        if candidates[i].craftable == focus.minCraftable then
            focus.watches[#focus.watches + 1] = candidates[i]
        end
    end
    return focus
end

function RS.FocusSpecKeys(focus)
    local keys = {}
    if type(focus) ~= "table" or type(focus.watches) ~= "table" or not MS or not MS.Key then
        return keys
    end
    for i = 1, #focus.watches do
        local slots = focus.watches[i].recipe and focus.watches[i].recipe.slots
        if type(slots) == "table" then
            for j = 1, #slots do
                local spec = slots[j] and slots[j].spec
                if type(spec) == "table" then
                    keys[MS.Key(spec)] = true
                end
            end
        end
    end
    return keys
end

function RS.FocusWatchNames(focus)
    if type(focus) ~= "table" or type(focus.watches) ~= "table" or #focus.watches == 0 then
        return L""
    end
    local text = L""
    for i = 1, #focus.watches do
        if i > 1 then
            text = text .. L", "
        end
        text = text .. (focus.watches[i].name or L"?")
    end
    return text
end

-- Plant/refine only when BOTH the global switch and this potion's AutoGrow are on.
function RS.ShouldAutoGrowPotion(potionKey, watch)
    local s = EnsureSettings()
    if type(s) ~= "table" or s.autoGrowEnabled ~= true then
        return false
    end
    return RS.WatchContributesGrowDemand(potionKey, watch)
end

-- Sum ingredient need across every watched potion that should AutoGrow.
-- Shared specs share one bag count; deficit = total need − have.
function RS.BuildBalancedSpecDemand()
    local snapGen = StockPiler.Inventory and tonumber(StockPiler.Inventory._snapshotGen) or 0
    if type(RS._demandCache) == "table" and RS._demandSnapGen == snapGen then
        return RS._demandCache
    end
    RS._specHaveCache = {}
    local s = EnsureSettings()
    local demand = {}
    if type(s.watches) ~= "table" or type(s.knownPotions) ~= "table" then
        RS._demandCache = demand
        RS._demandSnapGen = snapGen
        return demand
    end
    local watchPass = {}
    for potionKey, watch in pairs(s.watches) do
        if RS.WatchContributesGrowDemand(potionKey, watch) then
            local potion = s.knownPotions[potionKey]
            local recipe = RS.RecipeSpecForPotion(potionKey)
            if type(potion) == "table" and type(recipe) == "table" and recipe.quality == "good" then
                local target = tonumber(watch.targetStock) or 0
                local have = RS.PotionHaveCombined(potion)
                local deficit = math.max(0, target - have)
                if deficit > 0 and target > 0
                    and not RS.WatchCoveredByBagsAndCraftable(potion, recipe, target)
                then
                    local weight = deficit / target
                    local yield = RS.RecipeOutputYield(recipe)
                    local craftsNeeded = RS.CraftsNeededForDeficit(deficit, recipe)
                    local slots = recipe.slots or {}
                    watchPass[#watchPass + 1] = {
                        recipe = recipe,
                        yield = yield,
                        slots = slots,
                    }
                    for j = 1, #slots do
                        local slot = slots[j]
                        local spec = slot.spec
                        if type(spec) == "table" then
                            local specKey = MS.Key(spec)
                            local perCraft = RS.EffectiveSpecPerCraft(slot, slots)
                            local absNeed = craftsNeeded * perCraft
                            local row = demand[specKey]
                            if row == nil then
                                row = {
                                    spec = spec,
                                    specKey = specKey,
                                    role = slot.role,
                                    perCraft = perCraft,
                                    absolute = 0,
                                    weighted = 0,
                                    watchNames = {},
                                    watchDetails = {},
                                }
                                demand[specKey] = row
                            end
                            if perCraft > (row.perCraft or 0) then
                                row.perCraft = perCraft
                            end
                            row.absolute = row.absolute + absNeed
                            row.weighted = row.weighted + (weight * perCraft)
                            local watchName = potion.name or potionKey
                            local already = false
                            for w = 1, #(row.watchDetails) do
                                if row.watchDetails[w].potionKey == potionKey then
                                    already = true
                                    break
                                end
                            end
                            if already ~= true then
                                row.watchNames[#row.watchNames + 1] = watchName
                                row.watchDetails[#row.watchDetails + 1] = {
                                    potionKey = potionKey,
                                    name = watchName,
                                    have = have,
                                    target = target,
                                    deficit = deficit,
                                }
                            end
                        end
                    end
                end
            end
        end
    end
    for _, row in pairs(demand) do
        row.have = RS.CountItemsMatchingSpec(row.spec)
        row.deficit = math.max(0, row.absolute - row.have)
        local pc = tonumber(row.perCraft) or 1
        if pc < 1 then
            pc = 1
        end
        row.perCraft = pc
        row.craftsHave = math.floor((row.have or 0) / pc)
        row.craftsNeeded = math.ceil((row.absolute or 0) / pc)
        row.craftsShort = math.max(0, row.craftsNeeded - row.craftsHave)
    end
    for i = 1, #watchPass do
        local rec = watchPass[i]
        local craftsPossible = RS.CountCraftsPossible(rec.recipe)
        local watchCraftable = craftsPossible * rec.yield
        local slots = rec.slots or {}
        for j = 1, #slots do
            local slot = slots[j]
            local spec = slot.spec
            if type(spec) == "table" then
                local specKey = MS.Key(spec)
                local row = demand[specKey]
                if type(row) == "table" then
                    local pc = RS.EffectiveSpecPerCraft(slot, slots)
                    if pc < 1 then
                        pc = 1
                    end
                    local slotCrafts = math.floor((tonumber(row.have) or 0) / pc)
                    if slotCrafts <= craftsPossible then
                        local prev = tonumber(row.minWatchCraftable)
                        if prev == nil or watchCraftable < prev then
                            row.minWatchCraftable = watchCraftable
                        end
                    end
                end
            end
        end
    end
    RS._demandCache = demand
    RS._demandSnapGen = snapGen
    return demand
end

local function MainUidFromLegacyRecipes(outputUid)
    outputUid = tonumber(outputUid) or 0
    if outputUid <= 0 then
        return nil
    end
    local s = EnsureSettings()
    if type(s.learnedRecipes) ~= "table" then
        return nil
    end
    for _, recipe in pairs(s.learnedRecipes) do
        if type(recipe) == "table" and tonumber(recipe.outputUid) == outputUid then
            local materials = recipe.materials
            if type(materials) == "table" then
                for i = 1, #materials do
                    local mat = materials[i]
                    if type(mat) == "table" and mat.role == "main" then
                        local uid = tonumber(mat.uniqueID) or 0
                        if uid > 0 then
                            return uid
                        end
                    end
                end
            end
        end
    end
    return nil
end

local function RemapRecipeSpecKey(s, oldKey, newKey, recipe)
    if oldKey == newKey or oldKey == "" or newKey == "" then
        return
    end
    recipe.recipeSpecKey = newKey
    s.learnedRecipeSpecs[newKey] = recipe
    if s.learnedRecipeSpecs[oldKey] == recipe then
        s.learnedRecipeSpecs[oldKey] = nil
    end
    if type(s.knownPotions) == "table" then
        for _, potion in pairs(s.knownPotions) do
            if type(potion) == "table" then
                if potion.activeRecipeSpecKey == oldKey then
                    potion.activeRecipeSpecKey = newKey
                end
                if type(potion.alternateRecipeSpecKeys) == "table" then
                    for i = 1, #potion.alternateRecipeSpecKeys do
                        if potion.alternateRecipeSpecKeys[i] == oldKey then
                            potion.alternateRecipeSpecKeys[i] = newKey
                        end
                    end
                end
            end
        end
    end
end

local function RemapGrowProducerKey(s, oldKey, newKey, prod)
    if oldKey == newKey or oldKey == "" or newKey == "" then
        return
    end
    local existing = s.growProducers[newKey]
    if type(existing) == "table" then
        if type(prod.seedSpecKeys) == "table" then
            local seen = {}
            if type(existing.seedSpecKeys) == "table" then
                for i = 1, #existing.seedSpecKeys do
                    seen[existing.seedSpecKeys[i]] = true
                end
            else
                existing.seedSpecKeys = {}
            end
            for i = 1, #prod.seedSpecKeys do
                local seedKey = prod.seedSpecKeys[i]
                if not seen[seedKey] then
                    existing.seedSpecKeys[#existing.seedSpecKeys + 1] = seedKey
                    seen[seedKey] = true
                end
            end
        end
        if type(prod.sources) == "table" then
            if type(existing.sources) ~= "table" then
                existing.sources = {}
            end
            for source, enabled in pairs(prod.sources) do
                existing.sources[source] = enabled
            end
        end
    else
        s.growProducers[newKey] = prod
    end
    if s.growProducers[oldKey] == prod then
        s.growProducers[oldKey] = nil
    end
end

function RS.RepairIncompleteMainSpecs()
    if not MS or not MS.RepairMainSpec or not MS.Key then
        return 0
    end
    local s = EnsureSettings()
    local fixed = 0
    local recipeMigrates = {}

    if type(s.learnedRecipeSpecs) == "table" then
        for key, recipe in pairs(s.learnedRecipeSpecs) do
            if type(recipe) == "table" and type(recipe.slots) == "table" then
                local changed = false
                local mainUid = MainUidFromLegacyRecipes(recipe.outputUid)
                for i = 1, #recipe.slots do
                    local slot = recipe.slots[i]
                    if type(slot) == "table" and slot.role == "main" and type(slot.spec) == "table" then
                        if MS.RepairMainSpec(slot.spec, mainUid) then
                            changed = true
                            fixed = fixed + 1
                        end
                    end
                end
                if changed then
                    local newKey = RS.BuildRecipeSpecKey(recipe.slots, recipe.outputUid)
                    if newKey ~= key then
                        recipeMigrates[#recipeMigrates + 1] = {
                            oldKey = key,
                            newKey = newKey,
                            recipe = recipe,
                        }
                    end
                end
            end
        end
    end

    for i = 1, #recipeMigrates do
        local migrate = recipeMigrates[i]
        RemapRecipeSpecKey(s, migrate.oldKey, migrate.newKey, migrate.recipe)
    end

    if type(s.seedMap) == "table" then
        for _, entry in pairs(s.seedMap) do
            if type(entry) == "table" and type(entry.plantSpec) == "table" then
                local plantSpec = entry.plantSpec
                if plantSpec.role == "main" and plantSpec.incomplete == true then
                    local uid = entry.plantUidCache
                    if MS.RepairMainSpec(plantSpec, uid) then
                        fixed = fixed + 1
                        local oldPlantKey = entry.plantSpecKey
                        local newPlantKey = MS.Key(plantSpec)
                        entry.plantSpecKey = newPlantKey
                        if type(s.growProducers) == "table" and oldPlantKey and oldPlantKey ~= newPlantKey then
                            local prod = s.growProducers[oldPlantKey]
                            if type(prod) == "table" then
                                RemapGrowProducerKey(s, oldPlantKey, newPlantKey, prod)
                            end
                        end
                    end
                end
            end
        end
    end

    if fixed > 0 and StockPiler.Inventory and StockPiler.Inventory.InvalidateRecipeCaches then
        StockPiler.Inventory.InvalidateRecipeCaches()
    end
    return fixed
end
