----------------------------------------------------------------
-- StockPilerPlanner - cultivation grow plan from watched potion targets
----------------------------------------------------------------

StockPiler.Planner = StockPiler.Planner or {}

local PRIORITY_DEFAULT = 3
local SEED_BUFFER_MIN = 4
local SEED_BUFFER_MAX = 99
local SEED_BUFFER_DEFAULT = 4

local BUTCHER_HINTS = {
    "scale",
    "fragment",
    "hide",
    "claw",
    "fang",
    "horn",
    "bone",
    "gland",
    "organ",
    "blood",
    "ichor",
    "gobswort",
    "wort",
    "venom",
    "wing",
    "meat",
    "liver",
}

local function ToNarrow(text)
    return StockPiler.ToNarrow(text)
end

local function GetSettings()
    if type(StockPiler.Settings) == "table" then
        return StockPiler.Settings
    end
    if StockPiler.EnsureSettings then
        return StockPiler.EnsureSettings()
    end
    return StockPiler.Settings
end

local function CatalogPotions()
    return (StockPiler.Catalog and StockPiler.Catalog.Potions)
        or (StockPiler.Mock and StockPiler.Mock.Potions)
        or {}
end

local function CultivationSeedType()
    if GameData and GameData.CultivationTypes then
        return GameData.CultivationTypes.SEED
    end
    return 1
end

local function CultivationSporeType()
    if GameData and GameData.CultivationTypes then
        return GameData.CultivationTypes.SPORE
    end
    return 5
end

local function NormalizeGrowName(nameNarrow)
    local s = string.lower(nameNarrow or "")
    s = string.gsub(s, "%s+seed$", "")
    s = string.gsub(s, "%s+spore$", "")
    s = string.gsub(s, "%s+", " ")
    s = string.gsub(s, "^%s+", "")
    s = string.gsub(s, "%s+$", "")
    return s
end

local function LooksButchering(nameNarrow)
    local s = string.lower(nameNarrow or "")
    for i = 1, #BUTCHER_HINTS do
        if string.find(s, BUTCHER_HINTS[i], 1, true) then
            return true
        end
    end
    return false
end

local function GrowOrderList()
    local s = GetSettings()
    if type(s.growOrder) ~= "table" then
        s.growOrder = {}
    end
    return s.growOrder
end

local function GrowOrderIndex(potionId)
    local order = GrowOrderList()
    for i = 1, #order do
        if order[i] == potionId then
            return i
        end
    end
    return nil
end

local function CollectWatchedIds()
    local s = GetSettings()
    local ids = {}
    local seen = {}

    local function add(id)
        if id and id ~= "" and s.watchlist[id] == true and not seen[id] then
            seen[id] = true
            ids[#ids + 1] = id
        end
    end

    for _, entry in ipairs(CatalogPotions()) do
        add(entry.id)
    end

    local list = (StockPiler.Inventory and StockPiler.Inventory.GetObservedList)
        and StockPiler.Inventory.GetObservedList()
        or {}
    for i = 1, #list do
        add(list[i].id)
    end

    return ids
end

function StockPiler.Planner.EnsureGrowOrder()
    local s = GetSettings()
    local watched = CollectWatchedIds()
    local order = GrowOrderList()
    local cleaned = {}
    local seen = {}

    for i = 1, #order do
        local id = order[i]
        if s.watchlist[id] == true and not seen[id] then
            cleaned[#cleaned + 1] = id
            seen[id] = true
        end
    end

    local newcomers = {}
    for i = 1, #watched do
        local id = watched[i]
        if not seen[id] then
            newcomers[#newcomers + 1] = id
        end
    end

    table.sort(newcomers, function(a, b)
        local pa = tonumber(s.growPriorities and s.growPriorities[a]) or PRIORITY_DEFAULT
        local pb = tonumber(s.growPriorities and s.growPriorities[b]) or PRIORITY_DEFAULT
        if pa ~= pb then
            return pa < pb
        end
        return ToNarrow(a) < ToNarrow(b)
    end)

    for i = 1, #newcomers do
        cleaned[#cleaned + 1] = newcomers[i]
    end

    s.growOrder = cleaned
    return cleaned
end

local function GetGrowRank(potionId)
    StockPiler.Planner.EnsureGrowOrder()
    local idx = GrowOrderIndex(potionId)
    if idx == nil then
        return 9999
    end
    return idx
end

function StockPiler.Planner.MovePriorityUp(potionId)
    StockPiler.Planner.EnsureGrowOrder()
    local order = GrowOrderList()
    local idx = GrowOrderIndex(potionId)
    if idx == nil or idx <= 1 then
        return false
    end
    order[idx], order[idx - 1] = order[idx - 1], order[idx]
    return true
end

function StockPiler.Planner.MovePriorityDown(potionId)
    StockPiler.Planner.EnsureGrowOrder()
    local order = GrowOrderList()
    local idx = GrowOrderIndex(potionId)
    if idx == nil or idx >= #order then
        return false
    end
    order[idx], order[idx + 1] = order[idx + 1], order[idx]
    return true
end

function StockPiler.Planner.GetSeedBufferMin()
    local s = GetSettings()
    local buf = tonumber(s.growSeedBufferMin) or SEED_BUFFER_DEFAULT
    if buf < SEED_BUFFER_MIN then
        buf = SEED_BUFFER_MIN
        s.growSeedBufferMin = buf
    elseif buf > SEED_BUFFER_MAX then
        buf = SEED_BUFFER_MAX
        s.growSeedBufferMin = buf
    end
    return buf
end

--- How many seeds may be planted for a remaining plant shortfall.
--- Buffer is a refine target, not a plant reserve: planting may use every seed.
--- Omit `plantsShort` at plant time to use the full seed stack.
function StockPiler.Planner.ComputeSeedPlantable(seedHave, seedBuffer, matHave, plantsShort)
    seedHave = tonumber(seedHave) or 0
    if seedHave < 0 then
        seedHave = 0
    end
    if plantsShort == nil then
        return seedHave
    end
    plantsShort = tonumber(plantsShort) or 0
    if plantsShort < 0 then
        plantsShort = 0
    end
    if plantsShort <= 0 then
        return 0
    end
    if seedHave >= plantsShort then
        return plantsShort
    end
    return seedHave
end

function StockPiler.Planner.NeedsSeedConversion(seedHave, seedBuffer)
    seedHave = tonumber(seedHave) or 0
    seedBuffer = tonumber(seedBuffer) or SEED_BUFFER_DEFAULT
    return seedHave < seedBuffer
end

function StockPiler.Planner.AdjustSeedBuffer(increase)
    local s = GetSettings()
    local cur = StockPiler.Planner.GetSeedBufferMin()
    if increase then
        cur = cur + 1
        if cur > SEED_BUFFER_MAX then
            cur = SEED_BUFFER_MAX
        end
    else
        cur = cur - 1
        if cur < SEED_BUFFER_MIN then
            cur = SEED_BUFFER_MIN
        end
    end
    s.growSeedBufferMin = cur
    return cur
end

local function IsGrowableMaterial(mat)
    if StockPiler.SeedMap and StockPiler.SeedMap.IsGrowableMaterial then
        return StockPiler.SeedMap.IsGrowableMaterial(mat)
    end
    return false
end

local function ResolveSeedForMaterial(mat, catalogEntry)
    if StockPiler.SeedMap and StockPiler.SeedMap.ResolveSeedForMaterial then
        return StockPiler.SeedMap.ResolveSeedForMaterial(mat, catalogEntry)
    end
    return nil
end

local function IsGrowableMainMat(mat)
    if type(mat) ~= "table" then
        return false
    end
    if mat.role and mat.role ~= "main" then
        return false
    end
    local nameNarrow = mat.nameNarrow or ToNarrow(mat.name) or ToNarrow(mat.match)
    if nameNarrow == "" then
        return false
    end
    if LooksButchering(nameNarrow) then
        return false
    end
    if mat.matKind == "cultivation" then
        local cultType = tonumber(mat.cultivationType) or 0
        if cultType == CultivationSeedType() or cultType == CultivationSporeType() then
            return true
        end
    end
    if string.find(string.lower(nameNarrow), "goldweed", 1, true) then
        return true
    end
    if string.find(string.lower(nameNarrow), "nettle", 1, true)
        or string.find(string.lower(nameNarrow), "beardweed", 1, true)
        or string.find(string.lower(nameNarrow), "gobswort", 1, true)
        or string.find(string.lower(nameNarrow), "weed", 1, true)
        or string.find(string.lower(nameNarrow), "fungus", 1, true)
        or string.find(string.lower(nameNarrow), "leaf", 1, true)
    then
        return true
    end
    return not LooksButchering(nameNarrow)
end

local function MatDisplayName(mat)
    if type(mat) ~= "table" then
        return L"material"
    end
    if mat.name and mat.name ~= L"" then
        return mat.name
    end
    if mat.nameNarrow and mat.nameNarrow ~= "" then
        return towstring(mat.nameNarrow)
    end
    if mat.match and mat.match ~= "" then
        return towstring(mat.match)
    end
    return L"material"
end

local function IsContainerMat(mat)
    if type(mat) ~= "table" then
        return false
    end
    if mat.role == "container" then
        return true
    end
    local name = string.lower(mat.nameNarrow or ToNarrow(mat.name) or ToNarrow(mat.match) or "")
    return string.find(name, "flask", 1, true) ~= nil
        or string.find(name, "vial", 1, true) ~= nil
        or string.find(name, "container", 1, true) ~= nil
end

local function IsButcheringMat(mat)
    if type(mat) ~= "table" then
        return false
    end
    if mat.role ~= "main" then
        return false
    end
    local nameNarrow = mat.nameNarrow or ToNarrow(mat.name) or ToNarrow(mat.match)
    return LooksButchering(nameNarrow)
end

local function ShortFarmLabel(mat)
    local name = ToNarrow(MatDisplayName(mat))
    local lower = string.lower(name)
    if string.find(lower, "scale", 1, true) then
        return L"Farm scales"
    end
    if string.find(lower, "venom", 1, true) then
        return L"Farm venom"
    end
    if string.find(lower, "wing", 1, true) then
        return L"Farm wings"
    end
    if string.find(lower, "hide", 1, true) then
        return L"Farm hides"
    end
    if string.find(lower, "claw", 1, true) or string.find(lower, "fang", 1, true) then
        return L"Farm drops"
    end
    return towstring("Farm " .. name)
end

local function MatDeficitLine(mat, have, need, totalNeed)
    local line = ToNarrow(MatDisplayName(mat)) .. ": " .. tostring(have) .. " / " .. tostring(need)
    totalNeed = tonumber(totalNeed) or 0
    need = tonumber(need) or 0
    if totalNeed > need then
        line = line .. " (" .. tostring(totalNeed) .. " total watched)"
    end
    return line
end

local function MaterialKey(mat)
    if type(mat) ~= "table" then
        return ""
    end
    local uid = tonumber(mat.uniqueID) or 0
    if uid > 0 then
        return "uid:" .. tostring(uid)
    end
    local match = mat.match or mat.nameNarrow or ToNarrow(mat.name) or ""
    match = string.lower(match)
    if match ~= "" then
        return "name:" .. match
    end
    return ""
end

local function CountMaterial(mat)
    if type(mat) ~= "table" then
        return 0
    end
    local uid = tonumber(mat.uniqueID) or 0
    local match = mat.match or mat.nameNarrow or ToNarrow(mat.name)
    if match and match ~= "" and StockPiler.Inventory then
        if StockPiler.Inventory.CountRecipeMaterialByName then
            local count = StockPiler.Inventory.CountRecipeMaterialByName(match, uid)
            if count > 0 or uid == 0 then
                return count
            end
        end
        if StockPiler.Inventory.CountByName then
            return StockPiler.Inventory.CountByName(match)
        end
    end
    if uid > 0 and StockPiler.Inventory and StockPiler.Inventory.CountByUniqueId then
        local count = StockPiler.Inventory.CountByUniqueId(uid)
        return tonumber(count) or 0
    end
    return 0
end

local function PoolCount(pool, mat)
    local key = MaterialKey(mat)
    if key == "" then
        return CountMaterial(mat)
    end
    if pool[key] == nil then
        pool[key] = CountMaterial(mat)
    end
    return pool[key]
end

local function AllocateFromPool(pool, mat, need)
    need = tonumber(need) or 0
    if need <= 0 then
        return 0, 0
    end
    local key = MaterialKey(mat)
    local available = PoolCount(pool, mat)
    local allocated = math.min(need, available)
    if key ~= "" then
        pool[key] = available - allocated
    end
    return allocated, need - allocated
end

local function PotionYield(entry, recipe)
    if type(recipe) == "table" and StockPiler.Inventory and StockPiler.Inventory.RecipeYield then
        local learned = StockPiler.Inventory.RecipeYield(recipe)
        if learned and learned > 0 then
            return learned
        end
    end
    if type(entry) == "table" and tonumber(entry.recipeYield) and tonumber(entry.recipeYield) > 0 then
        return tonumber(entry.recipeYield)
    end
    return 2
end

local function GrowBalanceUnits(mat, perCraft)
    perCraft = tonumber(perCraft) or 1
    if perCraft < 1 then
        perCraft = 1
    end
    return CountMaterial(mat) / perCraft
end

local function PickBottleneckGrowSlot(growAll)
    if type(growAll) ~= "table" or #growAll == 0 then
        return nil
    end
    local best = growAll[1]
    local bestUnits = GrowBalanceUnits(best.mat, best.perCraft)
    for i = 2, #growAll do
        local slot = growAll[i]
        local units = GrowBalanceUnits(slot.mat, slot.perCraft)
        if units < bestUnits then
            best = slot
            bestUnits = units
        end
    end
    return best
end

local function AnalyzeRecipeDeficits(recipe, craftsNeeded, pool)
    local out = {
        flask = nil,
        butcher = nil,
        grow = nil,
        growAll = {},
        other = {},
    }
    if type(recipe) ~= "table" or type(recipe.materials) ~= "table" or craftsNeeded <= 0 then
        return out
    end
    for i = 1, #recipe.materials do
        local mat = recipe.materials[i]
        local perCraft = tonumber(mat.perCraft) or 1
        local need = craftsNeeded * perCraft
        local have
        local deficit
        if type(pool) == "table" then
            have, deficit = AllocateFromPool(pool, mat, need)
        else
            have = CountMaterial(mat)
            deficit = math.max(0, need - have)
        end
        if deficit > 0 then
            local slot = { mat = mat, have = have, need = need, deficit = deficit, perCraft = perCraft }
            if IsContainerMat(mat) then
                if out.flask == nil or deficit > out.flask.deficit then
                    out.flask = slot
                end
            elseif IsButcheringMat(mat) then
                if out.butcher == nil or deficit > out.butcher.deficit then
                    out.butcher = slot
                end
            elseif IsGrowableMaterial(mat) then
                out.growAll[#out.growAll + 1] = slot
            else
                out.other[#out.other + 1] = slot
            end
        end
    end
    out.grow = PickBottleneckGrowSlot(out.growAll)
    return out
end

local function SeedShortageLabels(seed)
    if type(seed) == "table" and seed.isSpore == true then
        return L"Buy spore", L"need_spore", L"Spores", L"spore"
    end
    return L"Buy seed", L"need_seed", L"Seeds", L"seed"
end

local function ApplyCultivationDeficitStatus(row, slot, entry, s, demandTotals)
    local mat = slot.mat
    local matKey = MaterialKey(mat)
    local shared = type(demandTotals) == "table" and demandTotals[matKey] or nil
    local sharedHave = shared and shared.have or CountMaterial(mat)
    local sharedNeed = shared and shared.totalNeed or slot.need
    local sharedDeficit = shared and shared.totalDeficit or slot.deficit

    row.matHave = sharedHave
    row.matNeed = slot.need
    row.matDeficit = slot.deficit
    row.matSharedNeed = sharedNeed
    row.matSharedDeficit = sharedDeficit

    local seed = ResolveSeedForMaterial(mat, entry)
    local seedHave = seed and (seed.count or 0) or 0
    local seedBuffer = StockPiler.Planner.GetSeedBufferMin()
    local plantsShort = math.max(0, (tonumber(sharedNeed) or 0) - (tonumber(sharedHave) or 0))
    local seedPlantable = StockPiler.Planner.ComputeSeedPlantable(seedHave, seedBuffer, sharedHave, plantsShort)
    row.seedHave = seedHave
    row.seedPlantable = seedPlantable
    row.seedKey = seed and (seed.nameNarrow or seed.match or ToNarrow(seed.name)) or ""
    row.seedName = seed and seed.name or L""
    row.seedUid = seed and (tonumber(seed.uniqueID) or 0) or 0
    row.plantUid = tonumber(mat.uniqueID) or (seed and tonumber(seed.plantUid)) or 0
    if (row.seedUid or 0) <= 0 and StockPiler.AutoGrow and StockPiler.AutoGrow.ResolveSeedUid then
        row.seedUid = StockPiler.AutoGrow.ResolveSeedUid({
            seedKey = row.seedKey,
            seedName = row.seedName,
        })
    end

    local buyLabel, needKey, unitPlural, unitSingular = SeedShortageLabels(seed)

    if seed == nil or row.seedKey == "" then
        local wantsGrow = StockPiler.RecipeSpec
            and StockPiler.RecipeSpec.ShouldAutoGrowPotion
            and StockPiler.RecipeSpec.ShouldAutoGrowPotion(row.potionKey or row.id, nil) == true
        if wantsGrow then
            row.statusKey = "restocking"
            row.statusText = L"Restocking materials"
        else
            row.statusKey = "need_materials"
            row.statusText = L"Need materials"
        end
        row.statusDetail = L"Need "
            .. towstring(tostring(slot.deficit))
            .. L" more "
            .. MatDisplayName(mat)
            .. L" ("
            .. towstring(MatDeficitLine(mat, sharedHave, slot.need, sharedNeed))
            .. L"). No seed mapped yet."
        return
    end

    local potionAutoGrow = StockPiler.RecipeSpec
        and StockPiler.RecipeSpec.ShouldAutoGrowPotion
        and StockPiler.RecipeSpec.ShouldAutoGrowPotion(row.potionKey or row.id, nil) == true
    local needsGrow = sharedDeficit > 0
    local needsConvert = needsGrow
        and potionAutoGrow
        and row.plantUid
        and row.plantUid > 0
        and StockPiler.AutoGrow
        and StockPiler.AutoGrow.HasPendingRefine
        and StockPiler.AutoGrow.HasPendingRefine(row.plantUid)

    if needsConvert then
        row.growable = true
        row.needsSeedConversion = true
        row.statusKey = "converting_material"
        row.statusText = L"Converting material"
        row.statusDetail = L"AutoGrow is converting plants to seeds (a few seconds)."
        return
    end

    if seedPlantable <= 0 then
        row.statusKey = needKey
        row.statusText = buyLabel
        row.statusDetail = L"Need "
            .. towstring(tostring(slot.deficit))
            .. L" more "
            .. MatDisplayName(mat)
            .. L". "
            .. unitPlural
            .. L" "
            .. towstring(tostring(seedHave))
            .. L" / buffer "
            .. towstring(tostring(seedBuffer))
            .. L" ("
            .. towstring(row.seedKey)
            .. L"). "
            .. towstring(MatDeficitLine(mat, sharedHave, slot.need, sharedNeed))
            .. L"."
        return
    end

    row.growable = potionAutoGrow == true
    if potionAutoGrow then
        row.statusKey = "restocking"
        row.statusText = L"Restocking materials"
        local craftHint = L""
        if (row.craftsNeeded or 0) > 0 and (row.recipeYield or 0) > 0 then
            craftHint = L" ("
                .. towstring(tostring(row.craftsNeeded))
                .. L" brews x "
                .. towstring(tostring(row.recipeYield))
                .. L" potions)"
        end
        row.statusDetail = L"AutoGrow enabled. One brew recipe slot per plot; fully-stocked slots use highest-deficit ingredient. "
            .. (seed.name or unitSingular)
            .. L" - "
            .. towstring(MatDeficitLine(mat, sharedHave, slot.need, sharedNeed))
            .. craftHint
            .. L"."
    else
        row.statusKey = "need_materials"
        row.statusText = L"Need materials"
        row.statusDetail = L"Need "
            .. towstring(tostring(slot.deficit))
            .. L" more "
            .. MatDisplayName(mat)
            .. L" ("
            .. towstring(MatDeficitLine(mat, sharedHave, slot.need, sharedNeed))
            .. L"). Enable AutoGrow or plant manually."
    end
end

local function ApplyPlanStatus(row, target, recipe, entry, alloc, demandTotals)
    local s = GetSettings()
    row.statusDetail = L""

    if target.min <= 0 then
        row.statusKey = "no_target"
        row.statusText = L"Set target"
        row.statusDetail = L"Set Target# to plan how many finished potions to keep in bags."
        return
    end

    if recipe == nil then
        row.statusKey = "no_recipe"
        row.statusText = L"Learn recipe"
        row.statusDetail = L"Craft this potion once at an Apothecary to learn the recipe."
        return
    end

    if target.deficit <= 0 then
        row.statusKey = "potion_stocked"
        row.statusText = L"Potions stocked"
        row.statusDetail = L"Have "
            .. towstring(tostring(target.have))
            .. L" / Target "
            .. towstring(tostring(target.min))
            .. L". Target met."
        return
    end

    local yield = PotionYield(entry, recipe)
    local craftsNeeded = math.ceil(target.deficit / yield)
    if craftsNeeded < 1 then
        craftsNeeded = 1
    end
    row.recipeYield = yield
    row.craftsNeeded = craftsNeeded

    local deficits
    if type(alloc) == "table" and type(alloc.deficits) == "table" then
        deficits = alloc.deficits
        if (tonumber(alloc.craftsNeeded) or 0) > 0 then
            row.craftsNeeded = tonumber(alloc.craftsNeeded) or craftsNeeded
        end
        if (tonumber(alloc.yield) or 0) > 0 then
            row.recipeYield = tonumber(alloc.yield) or yield
        end
    else
        deficits = AnalyzeRecipeDeficits(recipe, craftsNeeded)
    end

    if deficits.flask == nil and deficits.butcher == nil and deficits.grow == nil and #deficits.other == 0 then
        local craftingBagReady = false
        if StockPiler.Brew and StockPiler.Brew.MaterialsReadyInCraftingBag then
            craftingBagReady = StockPiler.Brew.MaterialsReadyInCraftingBag(recipe) == true
        else
            craftingBagReady = true
        end
        if craftingBagReady then
            row.statusKey = "ready_to_craft"
            row.statusText = L"Ready to craft"
            row.statusDetail = L"All materials in the crafting bag for "
                .. towstring(tostring(craftsNeeded))
                .. L" craft(s) ("
                .. towstring(tostring(yield))
                .. L" potions each). Click Load, then Brew in the Apothecary."
        else
            row.statusKey = "need_crafting_bag"
            row.statusText = L"Move to craft bag"
            row.statusDetail = L"Materials are stocked but not all in the crafting bag. Move them there, then click Load."
        end
        return
    end

    -- Cultivation first: longest lead time; surface plant/spore actions before flasks.
    if deficits.grow ~= nil then
        row.growIngredientCount = type(deficits.growAll) == "table" and #deficits.growAll or 1
        ApplyCultivationDeficitStatus(row, deficits.grow, entry, s, demandTotals)
        return
    end

    if deficits.butcher ~= nil then
        local slot = deficits.butcher
        local matKey = MaterialKey(slot.mat)
        local shared = type(demandTotals) == "table" and demandTotals[matKey] or nil
        row.statusKey = "farm_butchering"
        row.statusText = ShortFarmLabel(slot.mat)
        row.statusDetail = L"Butchering material short. "
            .. towstring(MatDeficitLine(
                slot.mat,
                shared and shared.have or slot.have,
                slot.need,
                shared and shared.totalNeed or nil
            ))
            .. L". Buy from AH or farm from mobs."
        return
    end

    if deficits.flask ~= nil then
        local slot = deficits.flask
        local matKey = MaterialKey(slot.mat)
        local shared = type(demandTotals) == "table" and demandTotals[matKey] or nil
        row.statusKey = "buy_flasks"
        row.statusText = L"Buy flasks"
        row.statusDetail = L"Need empty flasks/vials. "
            .. towstring(MatDeficitLine(
                slot.mat,
                shared and shared.have or slot.have,
                slot.need,
                shared and shared.totalNeed or nil
            ))
            .. L"."
        return
    end

    if #deficits.other > 0 then
        local lines = {}
        for i = 1, #deficits.other do
            local slot = deficits.other[i]
            local matKey = MaterialKey(slot.mat)
            local shared = type(demandTotals) == "table" and demandTotals[matKey] or nil
            lines[#lines + 1] = MatDeficitLine(
                slot.mat,
                shared and shared.have or slot.have,
                slot.need,
                shared and shared.totalNeed or nil
            )
        end
        row.statusKey = "buy_ingredients"
        row.statusText = L"Buy ingredients"
        row.statusDetail = towstring(table.concat(lines, "; ") .. ".")
        return
    end
end

local function MainGrowMaterial(recipe)
    if type(recipe) ~= "table" or type(recipe.materials) ~= "table" then
        return nil
    end
    for i = 1, #recipe.materials do
        local mat = recipe.materials[i]
        if mat.role == "main" and IsGrowableMainMat(mat) then
            return mat
        end
    end
    for i = 1, #recipe.materials do
        local mat = recipe.materials[i]
        if IsGrowableMainMat(mat) then
            return mat
        end
    end
    return nil
end

local function MatUsesButchering(mat)
    if type(mat) ~= "table" then
        return false
    end
    if IsButcheringMat(mat) then
        return true
    end
    local nameNarrow = mat.nameNarrow or ToNarrow(mat.name) or ToNarrow(mat.match)
    return LooksButchering(nameNarrow)
end

local function RecipeUsesButchering(recipe)
    if type(recipe) ~= "table" or type(recipe.materials) ~= "table" then
        return false
    end
    for i = 1, #recipe.materials do
        if MatUsesButchering(recipe.materials[i]) then
            return true
        end
    end
    return false
end

local function RecipePreferenceScore(recipe, entry)
    local score = 0
    if not RecipeUsesButchering(recipe) then
        score = score + 10000
    end
    if type(entry) == "table" and entry.seedMatch and entry.seedMatch ~= "" then
        local main = MainGrowMaterial(recipe)
        if main then
            local mainName = string.lower(main.nameNarrow or ToNarrow(main.name) or "")
            local seedName = string.lower(tostring(entry.seedMatch))
            if mainName ~= ""
                and (string.find(seedName, mainName, 1, true)
                    or string.find(mainName, string.gsub(seedName, " seed", ""), 1, true))
            then
                score = score + 1000
            end
        end
    end
    score = score + (tonumber(recipe.crafts) or 0)
    return score
end

local function RecipeForPotion(entry, uniqueID)
    if not (StockPiler.Inventory and StockPiler.Inventory.GetRecipeList) then
        return nil
    end
    local uid = tonumber(uniqueID) or 0
    local list = StockPiler.Inventory.GetRecipeList()
    local candidates = {}
    for i = 1, #list do
        local recipe = list[i]
        if type(entry) == "table" and type(recipe.catalogEntry) == "table" and recipe.catalogEntry.id == entry.id then
            candidates[#candidates + 1] = recipe
        elseif uid > 0 and tonumber(recipe.potionUid) == uid then
            candidates[#candidates + 1] = recipe
        end
    end
    if #candidates == 0 then
        return nil
    end
    if #candidates == 1 then
        return candidates[1]
    end
    local growable = {}
    for i = 1, #candidates do
        if MainGrowMaterial(candidates[i]) ~= nil then
            growable[#growable + 1] = candidates[i]
        end
    end
    local pool = #growable > 0 and growable or candidates
    table.sort(pool, function(a, b)
        local sa = RecipePreferenceScore(a, entry)
        local sb = RecipePreferenceScore(b, entry)
        if sa ~= sb then
            return sa > sb
        end
        return ToNarrow(a.name) < ToNarrow(b.name)
    end)
    return pool[1]
end

local function BuildMaterialDemandTotals(targets)
    local totals = {}
    for i = 1, #targets do
        local target = targets[i]
        if target.min > 0 and target.deficit > 0 then
            local entry = target.entry
            local recipe = RecipeForPotion(entry, target.uniqueID)
            if type(recipe) == "table" and type(recipe.materials) == "table" then
                local yield = PotionYield(entry, recipe)
                local craftsNeeded = math.ceil(target.deficit / yield)
                if craftsNeeded < 1 then
                    craftsNeeded = 1
                end
                for j = 1, #recipe.materials do
                    local mat = recipe.materials[j]
                    local key = MaterialKey(mat)
                    if key ~= "" then
                        local perCraft = tonumber(mat.perCraft) or 1
                        if StockPiler.Inventory and StockPiler.Inventory.EffectiveMaterialPerCraft then
                            perCraft = StockPiler.Inventory.EffectiveMaterialPerCraft(mat, recipe.materials)
                        end
                        local need = craftsNeeded * perCraft
                        local slot = totals[key]
                        if slot == nil then
                            slot = {
                                mat = mat,
                                totalNeed = 0,
                                totalDeficit = 0,
                                have = 0,
                            }
                            totals[key] = slot
                        end
                        slot.totalNeed = slot.totalNeed + need
                    end
                end
            end
        end
    end
    for _, slot in pairs(totals) do
        slot.have = CountMaterial(slot.mat)
        slot.totalDeficit = math.max(0, slot.totalNeed - slot.have)
    end
    return totals
end

local function BuildTargetAllocations(targets)
    local sorted = {}
    for i = 1, #targets do
        sorted[i] = targets[i]
    end
    table.sort(sorted, function(a, b)
        return GetGrowRank(a.id) < GetGrowRank(b.id)
    end)

    local pool = {}
    local allocById = {}
    for i = 1, #sorted do
        local target = sorted[i]
        local entry = target.entry
        local recipe = RecipeForPotion(entry, target.uniqueID)
        local alloc = {
            recipe = recipe,
            craftsNeeded = 0,
            yield = 2,
            deficits = {
                flask = nil,
                butcher = nil,
                grow = nil,
                other = {},
            },
        }
        if target.min > 0 and target.deficit > 0 and type(recipe) == "table" then
            local yield = PotionYield(entry, recipe)
            local craftsNeeded = math.ceil(target.deficit / yield)
            if craftsNeeded < 1 then
                craftsNeeded = 1
            end
            alloc.craftsNeeded = craftsNeeded
            alloc.yield = yield
            alloc.deficits = AnalyzeRecipeDeficits(recipe, craftsNeeded, pool)
        end
        allocById[target.id] = alloc
    end
    return allocById
end

local function BuildWatchedTargets()
    local s = GetSettings()
    local targets = {}

    local function addTarget(id, entry, inv)
        local min = tonumber(s.mins[id]) or 0
        local have = tonumber(inv.count) or 0
        targets[#targets + 1] = {
            id = id,
            entry = entry,
            uniqueID = inv.uniqueID or (entry and entry.uniqueID),
            name = (entry and entry.name) or inv.name,
            iconNum = tonumber(inv.iconNum) or 0,
            itemData = inv.itemData,
            have = have,
            min = min,
            deficit = math.max(0, min - have),
        }
    end

    for _, entry in ipairs(CatalogPotions()) do
        if s.watchlist[entry.id] == true then
            local inv = (StockPiler.Inventory and StockPiler.Inventory.byPotion and StockPiler.Inventory.byPotion[entry.id])
                or { count = 0, iconNum = 0, itemData = nil }
            addTarget(entry.id, entry, inv)
        end
    end

    local list = (StockPiler.Inventory and StockPiler.Inventory.GetObservedList)
        and StockPiler.Inventory.GetObservedList()
        or {}
    for i = 1, #list do
        local inv = list[i]
        if s.watchlist[inv.id] == true then
            addTarget(inv.id, nil, inv)
        end
    end

    return targets
end

function StockPiler.Planner.BuildGrowQueue()
    return StockPiler.Planner.BuildPlan().queue
end

function StockPiler.Planner.FormatGrowQueueText(queue, maxItems)
    maxItems = maxItems or 4
    if type(queue) ~= "table" then
        return L"No grow queue (set Target#, known recipes, material need, and spare seeds)."
    end
    local parts = {}
    local plotCount = 4
    if StockPiler.Planner.GetGrowPlotCount then
        plotCount = StockPiler.Planner.GetGrowPlotCount()
    else
        plotCount = StockPiler.Planner.GROW_PLOT_COUNT or 4
    end
    local limit = math.min(maxItems, math.max(0, plotCount))
    local count = 0
    for plotNum = 1, limit do
        local entry = queue[plotNum]
        if type(entry) == "table" then
            parts[#parts + 1] = "P" .. tostring(plotNum) .. " " .. ToNarrow(entry.seedName)
            count = count + 1
        end
    end
    if count > 0 then
        return L"Next: " .. towstring(table.concat(parts, ", "))
    end
    local upcoming = queue.nextAfterHarvest
    if type(upcoming) == "table" and #upcoming > 0 then
        return L"Next after harvest: " .. towstring(table.concat(upcoming, ", "))
    end
    if type(queue.emptyReason) == "wstring" or type(queue.emptyReason) == "string" then
        if type(queue.emptyReason) == "string" then
            return towstring(queue.emptyReason)
        end
        return queue.emptyReason
    end
    return L"No grow queue (enable watches, set targets, learn recipes, spare seeds)."
end

local function BuildWatchedTargetsV6()
    local s = GetSettings()
    local RS = StockPiler.RecipeSpec
    local targets = {}
    if not RS or type(s.watches) ~= "table" then
        return targets
    end
    if RS.MigrateWatchesToPotionRecipeKeys then
        RS.MigrateWatchesToPotionRecipeKeys()
    end
    for watchKey, watch in pairs(s.watches) do
        if type(watch) == "table" and watch.enabled == true then
            local resolved = RS.ResolveWatchPotion and RS.ResolveWatchPotion(watchKey)
            local potion = resolved and resolved.potion
            if type(potion) == "table" then
                local have = RS.PotionHaveCombined(potion)
                local min = tonumber(watch.targetStock) or 0
                local recipeLabel = L""
                if resolved.recipeSpecKey and RS.RecipeLabelForKey then
                    recipeLabel = RS.RecipeLabelForKey(resolved.recipeSpecKey, potion.outputUid) or L""
                end
                targets[#targets + 1] = {
                    id = watchKey,
                    potionKey = watchKey,
                    potionBaseKey = resolved.potionKey,
                    recipeSpecKey = resolved.recipeSpecKey,
                    recipeLabel = recipeLabel,
                    entry = potion,
                    uniqueID = potion.outputUid,
                    name = potion.name or towstring(tostring(potion.outputUid)),
                    iconNum = tonumber(potion.iconNum) or 0,
                    itemData = nil,
                    have = have,
                    min = min,
                    deficit = math.max(0, min - have),
                    autoGrow = RS.WatchWantsAutoGrow(watch),
                }
            end
        end
    end
    -- Name then recipe label. Deficit sort jumped rows when Target# crossed Stock.
    table.sort(targets, function(a, b)
        local na = ToNarrow(a.name)
        local nb = ToNarrow(b.name)
        if na ~= nb then
            return na < nb
        end
        return ToNarrow(a.recipeLabel) < ToNarrow(b.recipeLabel)
    end)
    return targets
end

-- Watches that cannot brew yet (Craftable 0) outrank watches that already can.
-- Specs that are not a limiting slot for any short watch sort last.
local function WatchUnblockScore(row)
    local v = tonumber(row and row.minWatchCraftable)
    if v == nil then
        return 1000000
    end
    return v
end

-- Among watches this mat unblocks, prefer the one with lowest potion bag Stock.
local function WatchStockScore(row)
    local v = tonumber(row and row.minWatchStock)
    if v == nil then
        return 1000000
    end
    return v
end

--- Lowest Craftable watch first, then lowest potion Stock, then plant craftsHave.
local function CompareGrowPriority(a, b)
    local ua = WatchUnblockScore(a)
    local ub = WatchUnblockScore(b)
    if ua ~= ub then
        return ua < ub
    end
    local sa = WatchStockScore(a)
    local sb = WatchStockScore(b)
    if sa ~= sb then
        return sa < sb
    end
    local ca = tonumber(a.craftsHave) or 0
    local cb = tonumber(b.craftsHave) or 0
    if ca ~= cb then
        return ca < cb
    end
    local as = tonumber(a.craftsShort) or 0
    local bs = tonumber(b.craftsShort) or 0
    if as ~= bs then
        return as > bs
    end
    local da = tonumber(a.deficit) or 0
    local db = tonumber(b.deficit) or 0
    if da ~= db then
        return da > db
    end
    return tostring(a.specKey or "") < tostring(b.specKey or "")
end

StockPiler.Planner.CompareGrowPriority = CompareGrowPriority

local function FormatGrowPriorityFields(row)
    return string.format(
        "minWatch=%s stock=%s craftsHave=%d craftsShort=%d deficit=%d",
        tostring(row and row.minWatchCraftable),
        tostring(row and row.minWatchStock),
        tonumber(row and row.craftsHave) or 0,
        tonumber(row and row.craftsShort) or 0,
        tonumber(row and row.deficit) or 0
    )
end

local function GrowTraceSpecLabel(row)
    if type(row) ~= "table" then
        return "?"
    end
    if type(row.spec) == "table" and StockPiler.MaterialSpec and StockPiler.MaterialSpec.Label then
        local label = ToNarrow(StockPiler.MaterialSpec.Label(row.spec))
        return label .. " [" .. tostring(row.specKey or "?") .. "]"
    end
    return tostring(row.specKey or "?")
end

local function SetMaterialsShortStatus(row, growable, detail)
    if growable == true then
        row.statusKey = "restocking"
        row.statusText = L"Restocking materials"
    else
        row.statusKey = "need_materials"
        row.statusText = L"Need materials"
    end
    if detail ~= nil then
        row.statusDetail = detail
    end
end

local function ApplySpecPlanStatus(row, target, recipe, demand)
    local RS = StockPiler.RecipeSpec
    row.statusDetail = L""
    row.statusLines = nil
    if target.min <= 0 then
        row.statusKey = "no_target"
        row.statusText = L"Set target"
        row.statusLines = { L"Set a Target# for this potion." }
        return
    end
    if recipe == nil then
        row.statusKey = "no_recipe"
        row.statusText = L"Learn recipe"
        row.statusLines = { L"Learn this recipe at the Apothecary, then brew it once so StockPiler can store the slots." }
        return
    end
    if target.deficit <= 0 then
        row.statusKey = "potion_stocked"
        row.statusText = L"Potions stocked"
        row.statusLines = { L"Bag count is at or above the target." }
        return
    end
    if RS.WatchCoveredByBagsAndCraftable
        and RS.WatchCoveredByBagsAndCraftable(target.entry, recipe, target.min)
    then
        local craftingBagReady = true
        if StockPiler.Brew and StockPiler.Brew.MaterialsReadyInCraftingBag then
            craftingBagReady = StockPiler.Brew.MaterialsReadyInCraftingBag(recipe) == true
        end
        if craftingBagReady then
            row.statusKey = "ready_to_craft"
            row.statusText = L"Ready to craft"
            row.statusLines = {
                L"Stock + Craftable* covers the target. Click Load, then Brew.",
                L"Potent / other rarities do not count. Growing resumes if stock is still short after brewing.",
            }
        else
            row.statusKey = "need_crafting_bag"
            row.statusText = L"Move to craft bag"
            row.statusLines = {
                L"Stock + Craftable* covers the target. Move materials to the crafting bag, then click Load.",
            }
        end
        return
    end
    local yield = RS.RecipeOutputYield and RS.RecipeOutputYield(recipe) or (tonumber(recipe.recipeYield) or 2)
    local craftsNeeded = RS.CraftsNeededForDeficit and RS.CraftsNeededForDeficit(target.deficit, recipe)
        or math.ceil(target.deficit / math.max(1, yield))
    row.recipeYield = yield
    row.stockYield = RS.WatchStockYield and RS.WatchStockYield(recipe) or 1
    row.craftsNeeded = craftsNeeded
    local wantsGrow = RS and RS.ShouldAutoGrowPotion and RS.ShouldAutoGrowPotion(target.potionKey, nil) == true
    local slots = recipe.slots or {}
    local limiting = nil
    local containerShort = nil
    local vendorShort = nil
    local byproductShort = nil
    local plantShort = {}
    local convertShort = {}
    local buyShort = {}
    local statusSlots = {}
    for i = 1, #slots do
        local slot = slots[i]
        local spec = slot.spec
        if type(spec) == "table" and RS then
            local specKey = StockPiler.MaterialSpec.Key(spec)
            local perCraft = RS.EffectiveSpecPerCraft(slot, slots)
            local potionNeed = craftsNeeded * perCraft
            local have = RS.CountItemsMatchingSpec(spec)
            local demandRow = type(demand) == "table" and demand[specKey] or nil
            if type(demandRow) == "table" then
                have = tonumber(demandRow.have) or have
            end
            local deficit = math.max(0, potionNeed - have)
            if deficit > 0 then
                if StockPiler.SeedMap and StockPiler.SeedMap.MaybeLearnHarvestByproduct then
                    StockPiler.SeedMap.MaybeLearnHarvestByproduct(nil, spec)
                end
                local byproduct = StockPiler.SeedMap
                    and StockPiler.SeedMap.IsHarvestByproduct
                    and StockPiler.SeedMap.IsHarvestByproduct(spec) == true
                local growable = (not byproduct)
                    and StockPiler.MaterialSpec
                    and StockPiler.MaterialSpec.IsGrowable(spec)
                local craftsHave = math.floor(have / perCraft)
                local entry = {
                    spec = spec,
                    specKey = specKey,
                    have = have,
                    need = potionNeed,
                    deficit = deficit,
                    role = slot.role,
                    perCraft = perCraft,
                    craftsHave = craftsHave,
                    craftsShort = math.max(0, craftsNeeded - craftsHave),
                }
                if slot.role == "container" then
                    containerShort = entry
                    entry.kind = "buy"
                    buyShort[#buyShort + 1] = entry
                elseif byproduct then
                    entry.kind = "convert"
                    if byproductShort == nil or craftsHave < (byproductShort.craftsHave or 0) then
                        byproductShort = entry
                    end
                    convertShort[#convertShort + 1] = entry
                elseif growable then
                    entry.kind = "plant"
                    if limiting == nil or CompareGrowPriority(entry, limiting) then
                        limiting = entry
                    end
                    plantShort[#plantShort + 1] = entry
                else
                    entry.kind = "buy"
                    if vendorShort == nil or deficit > vendorShort.deficit then
                        vendorShort = entry
                    end
                    buyShort[#buyShort + 1] = entry
                end
            end
        end
    end

    for i = 1, #plantShort do
        statusSlots[#statusSlots + 1] = plantShort[i]
    end
    for i = 1, #convertShort do
        statusSlots[#statusSlots + 1] = convertShort[i]
    end
    for i = 1, #buyShort do
        statusSlots[#statusSlots + 1] = buyShort[i]
    end
    row.statusSlots = statusSlots

    local function haveNeed(entry)
        return towstring(tostring(entry.have)) .. L"/" .. towstring(tostring(entry.need))
    end
    local function matName(entry)
        if StockPiler.MaterialSpec.NeedLabel then
            return StockPiler.MaterialSpec.NeedLabel(entry.spec)
        end
        return StockPiler.MaterialSpec.Label(entry.spec)
    end
    local lines = {
        L"Need " .. towstring(tostring(craftsNeeded)) .. L" crafts for "
            .. towstring(tostring(target.deficit)) .. L" more of this potion."
            .. L" Recipe yield "
            .. towstring(tostring(yield))
            .. L" is a best case; Potent / other rarities do not count.",
    }
    if wantsGrow ~= true then
        lines[#lines + 1] = L"AutoGrow is off for this watch - materials will not be planted."
    end
    for i = 1, #plantShort do
        local entry = plantShort[i]
        local line = L"Plant " .. matName(entry) .. L" (" .. haveNeed(entry) .. L")"
        if StockPiler.AutoGrow and StockPiler.AutoGrow.GrowingNotesForSpec then
            local notes = StockPiler.AutoGrow.GrowingNotesForSpec(entry.spec)
            if notes and notes ~= L"" then
                line = line .. L" -- " .. notes
            end
        end
        lines[#lines + 1] = line
    end
    for i = 1, #convertShort do
        local entry = convertShort[i]
        lines[#lines + 1] = L"Grow recipe plants, then convert surplus for "
            .. matName(entry) .. L" (" .. haveNeed(entry) .. L")"
    end
    for i = 1, #buyShort do
        local entry = buyShort[i]
        local verb = L"Buy "
        if entry.role == "container" then
            verb = L"Buy flasks: "
        end
        lines[#lines + 1] = verb .. matName(entry) .. L" (" .. haveNeed(entry) .. L")"
    end
    if #plantShort + #convertShort + #buyShort == 0 then
        lines[#lines + 1] = L"Materials look sufficient for this potion."
    end
    row.statusLines = lines
    row.statusNeedLine = lines[1]

    if byproductShort ~= nil
        and (limiting == nil or (byproductShort.craftsHave or 0) <= (limiting.craftsHave or 0))
    then
        row.growable = wantsGrow
        SetMaterialsShortStatus(row, wantsGrow, lines[2] or lines[1])
        row.specDeficit = byproductShort
        return
    end
    if limiting ~= nil then
        row.growable = wantsGrow
        row.specDeficit = limiting
        local converting = false
        if wantsGrow == true
            and StockPiler.AutoGrow
            and StockPiler.AutoGrow.HasPendingRefine
            and StockPiler.SeedMap
        then
            local plantUid = 0
            if StockPiler.SeedMap.ResolveSeedForSpec then
                local seed = StockPiler.SeedMap.ResolveSeedForSpec(limiting.spec)
                if type(seed) == "table" then
                    plantUid = tonumber(seed.plantUid) or 0
                    local seedUid = tonumber(seed.uniqueID) or 0
                    if plantUid <= 0 and seedUid > 0 and StockPiler.SeedMap.GetPlantUidForSeed then
                        plantUid = tonumber(StockPiler.SeedMap.GetPlantUidForSeed(seedUid)) or 0
                    end
                end
            end
            if plantUid <= 0 and StockPiler.SeedMap.FindPlantUidForSpec then
                plantUid = tonumber(StockPiler.SeedMap.FindPlantUidForSpec(limiting.spec)) or 0
            end
            if plantUid > 0 and StockPiler.AutoGrow.HasPendingRefine(plantUid) then
                converting = true
                row.needsSeedConversion = true
                row.statusKey = "converting_material"
                row.statusText = L"Converting material"
                row.statusDetail = L"AutoGrow is converting plants to seeds (a few seconds)."
            end
        end
        if converting ~= true then
            SetMaterialsShortStatus(row, wantsGrow, lines[2] or lines[1])
        end
        return
    end
    if containerShort ~= nil then
        row.statusKey = "buy_flasks"
        row.statusText = L"Buy flasks"
        row.statusDetail = lines[2] or lines[1]
        return
    end
    if vendorShort ~= nil then
        row.statusKey = "buy_ingredients"
        row.statusText = L"Buy materials"
        row.statusDetail = lines[2] or lines[1]
        return
    end
    local craftingBagReady = true
    if StockPiler.Brew and StockPiler.Brew.MaterialsReadyInCraftingBag then
        craftingBagReady = StockPiler.Brew.MaterialsReadyInCraftingBag(recipe) == true
    end
    if craftingBagReady then
        row.statusKey = "ready_to_craft"
        row.statusText = L"Ready to craft"
        row.statusSlots = nil
        row.statusLines = { L"Ready to craft. Click Load in Craft, then Brew in the Apothecary." }
    else
        row.statusKey = "need_crafting_bag"
        row.statusText = L"Move to craft bag"
        row.statusSlots = nil
        row.statusLines = { L"Materials are stocked but not all in the crafting bag. Move them there, then click Load." }
    end
end

--- Per watched recipe: how many crafts bags can support now (min over every slot).
local function CollectWatchedRecipeGrowStates()
    local RS = StockPiler.RecipeSpec
    local MS = StockPiler.MaterialSpec
    local s = GetSettings()
    local recipes = {}
    if not RS or not MS or type(s.watches) ~= "table" then
        return recipes
    end
    for watchKey, watch in pairs(s.watches) do
        if RS.WatchContributesGrowDemand
            and RS.WatchContributesGrowDemand(watchKey, watch)
        then
            local resolved = RS.ResolveWatchPotion and RS.ResolveWatchPotion(watchKey)
            local potion = resolved and resolved.potion
            local recipe = RS.RecipeSpecForPotion(watchKey)
            if type(potion) == "table" and type(recipe) == "table"
                and (not RS.RecipeEligibleForGrow or RS.RecipeEligibleForGrow(recipe))
            then
                local target = tonumber(watch.targetStock) or 0
                local havePot = RS.PotionHaveCombined(potion)
                local deficit = math.max(0, target - havePot)
                if deficit > 0 and target > 0
                    and not (RS.WatchCoveredByBagsAndCraftable
                        and RS.WatchCoveredByBagsAndCraftable(potion, recipe, target))
                then
                    local yield = RS.RecipeOutputYield and RS.RecipeOutputYield(recipe)
                        or (tonumber(recipe.recipeYield) or 2)
                    local craftsNeeded = RS.CraftsNeededForDeficit and RS.CraftsNeededForDeficit(deficit, recipe)
                        or math.max(1, math.ceil(deficit / math.max(1, yield)))
                    local recSlots = recipe.slots or {}
                    local slots = {}
                    local possible = nil
                    for j = 1, #recSlots do
                        local slot = recSlots[j]
                        local spec = slot.spec
                        if type(spec) == "table" then
                            local perCraft = RS.EffectiveSpecPerCraft(slot, recSlots)
                            if perCraft < 1 then
                                perCraft = 1
                            end
                            local have = RS.CountItemsMatchingSpec(spec)
                            local craftsHave = math.floor(have / perCraft)
                            if possible == nil or craftsHave < possible then
                                possible = craftsHave
                            end
                            if StockPiler.SeedMap and StockPiler.SeedMap.MaybeLearnHarvestByproduct then
                                StockPiler.SeedMap.MaybeLearnHarvestByproduct(nil, spec)
                            end
                            local byproduct = StockPiler.SeedMap
                                and StockPiler.SeedMap.IsHarvestByproduct
                                and StockPiler.SeedMap.IsHarvestByproduct(spec) == true
                            slots[#slots + 1] = {
                                spec = spec,
                                specKey = MS.Key(spec),
                                role = slot.role,
                                perCraft = perCraft,
                                have = have,
                                craftsHave = craftsHave,
                                craftsNeeded = craftsNeeded,
                                craftsShort = math.max(0, craftsNeeded - craftsHave),
                                deficit = math.max(0, craftsNeeded * perCraft - have),
                                harvestByproduct = byproduct,
                                growable = (not byproduct) and MS.IsGrowable(spec) == true,
                            }
                        end
                    end
                    recipes[#recipes + 1] = {
                        potionKey = watchKey,
                        name = potion.name or watchKey,
                        craftsNeeded = craftsNeeded,
                        craftsPossible = possible or 0,
                        slots = slots,
                    }
                end
            end
        end
    end
    return recipes
end

local function SpecIsGrowablePlant(spec)
    if type(spec) ~= "table"
        or not StockPiler.MaterialSpec
        or StockPiler.MaterialSpec.IsGrowable(spec) ~= true
    then
        return false
    end
    if StockPiler.SeedMap
        and StockPiler.SeedMap.IsHarvestByproduct
        and StockPiler.SeedMap.IsHarvestByproduct(spec) == true
    then
        return false
    end
    return true
end

local function PooledSpecDemand()
    local cached = StockPiler.Planner._planCache
    if type(cached) == "table" and type(cached.specDemand) == "table" then
        return cached.specDemand
    end
    local RS = StockPiler.RecipeSpec
    if type(RS) == "table" and type(RS._demandCache) == "table" then
        return RS._demandCache
    end
    if RS and RS.BuildBalancedSpecDemand then
        return RS.BuildBalancedSpecDemand() or {}
    end
    return {}
end

--- Crafts still needed for refine-byproduct slots (e.g. Arboreal Resin) across all AutoGrow watches.
function StockPiler.Planner.RefineByproductCraftsShort()
    local demand = PooledSpecDemand()
    local short = 0
    for _, row in pairs(demand) do
        if type(row) == "table"
            and type(row.spec) == "table"
            and StockPiler.SeedMap
            and StockPiler.SeedMap.IsHarvestByproduct
            and StockPiler.SeedMap.IsHarvestByproduct(row.spec) == true
        then
            local n = tonumber(row.craftsShort) or 0
            if n > short then
                short = n
            end
        end
    end
    return short
end

local function PlantUidForGrowSpec(spec)
    if type(spec) ~= "table" or not StockPiler.SeedMap then
        return 0
    end
    local seed = StockPiler.SeedMap.ResolveSeedForSpec and StockPiler.SeedMap.ResolveSeedForSpec(spec)
    local plantUid = 0
    if type(seed) == "table" then
        plantUid = tonumber(seed.plantUid) or 0
        if plantUid <= 0 and StockPiler.SeedMap.GetPlantUidForSeed then
            plantUid = tonumber(StockPiler.SeedMap.GetPlantUidForSeed(seed.uniqueID)) or 0
        end
    end
    if plantUid <= 0 and StockPiler.SeedMap.FindPlantUidForSpec then
        plantUid = tonumber(StockPiler.SeedMap.FindPlantUidForSpec(spec)) or 0
    end
    return plantUid
end

--- How many of this plant are extra beyond brew demand (not including extras
--- grown only to convert for resin / refine byproducts). 0 means do not convert
--- — those stacks are still needed for brewing. Unwatched plants return a large surplus.
function StockPiler.Planner.WatchedPlantCraftSurplus(plantUid)
    plantUid = tonumber(plantUid) or 0
    if plantUid <= 0 then
        return 0
    end
    local demand = PooledSpecDemand()
    local surplus = nil
    for _, row in pairs(demand) do
        if type(row) == "table"
            and SpecIsGrowablePlant(row.spec)
            and PlantUidForGrowSpec(row.spec) == plantUid
        then
            local brewNeed = tonumber(row.brewAbsolute)
            if brewNeed == nil then
                brewNeed = tonumber(row.absolute) or 0
            end
            local extra = (tonumber(row.have) or 0) - brewNeed
            if surplus == nil or extra < surplus then
                surplus = extra
            end
        end
    end
    if surplus == nil then
        return 9999
    end
    if surplus < 0 then
        return 0
    end
    return surplus
end

local function CountPlantInBags(plantUid)
    plantUid = tonumber(plantUid) or 0
    if plantUid <= 0 or not StockPiler.Inventory or not StockPiler.Inventory.CountByUniqueId then
        return 0
    end
    local count = StockPiler.Inventory.CountByUniqueId(plantUid)
    return tonumber(count) or 0
end

local function CountSeedInBags(seedUid)
    seedUid = tonumber(seedUid) or 0
    if seedUid <= 0 then
        return 0
    end
    if StockPiler.AutoGrow and StockPiler.AutoGrow.GetRawSeedCount then
        return tonumber(StockPiler.AutoGrow.GetRawSeedCount(seedUid)) or 0
    end
    return CountPlantInBags(seedUid)
end

local function SeedRecordForUid(seedUid, plantUid)
    seedUid = tonumber(seedUid) or 0
    if seedUid <= 0 then
        return nil
    end
    if StockPiler.SeedMap and StockPiler.SeedMap.ResolveSeedForPlantUid then
        local resolved = StockPiler.SeedMap.ResolveSeedForPlantUid(tonumber(plantUid) or 0)
        if type(resolved) == "table" and (tonumber(resolved.uniqueID) or 0) == seedUid then
            return resolved
        end
    end
    local sample = nil
    if StockPiler.Inventory and StockPiler.Inventory.CountByUniqueId then
        local _, item = StockPiler.Inventory.CountByUniqueId(seedUid)
        sample = item
    end
    if type(sample) ~= "table" and type(GetDatabaseItemData) == "function" then
        local ok, data = StockPiler.TryCallQuiet("GetDatabaseItemData", GetDatabaseItemData, seedUid)
        if ok and type(data) == "table" then
            sample = data
        end
    end
    if type(sample) ~= "table" then
        return {
            uniqueID = seedUid,
            plantUid = tonumber(plantUid) or 0,
            name = L"seed",
            nameNarrow = "seed",
            count = CountSeedInBags(seedUid),
        }
    end
    return {
        uniqueID = seedUid,
        plantUid = tonumber(plantUid) or 0,
        name = sample.name or L"seed",
        nameNarrow = ToNarrow(sample.name or sample.nameNarrow),
        count = CountSeedInBags(seedUid),
    }
end

local function ForEachKnownSeedPlantPair(fn)
    if type(fn) ~= "function" then
        return
    end
    local seen = {}
    local function emit(plantUid, seedUid)
        plantUid = tonumber(plantUid) or 0
        seedUid = tonumber(seedUid) or 0
        if plantUid <= 0 or seen[plantUid] == true then
            return
        end
        if seedUid <= 0 and StockPiler.SeedMap and StockPiler.SeedMap.ResolveSeedForPlantUid then
            local seed = StockPiler.SeedMap.ResolveSeedForPlantUid(plantUid)
            if type(seed) == "table" then
                seedUid = tonumber(seed.uniqueID) or 0
            end
        end
        if seedUid <= 0 then
            return
        end
        seen[plantUid] = true
        fn(plantUid, seedUid)
    end
    local s = GetSettings()
    local refines = type(s.refines) == "table" and s.refines or nil
    if type(refines) == "table" then
        for plantKey, entry in pairs(refines) do
            if type(entry) == "table" then
                emit(tonumber(plantKey), entry.seedUid)
            end
        end
    end
    local grows = type(s.grows) == "table" and s.grows or nil
    if type(grows) == "table" then
        for seedKey, plants in pairs(grows) do
            local seedUid = tonumber(seedKey) or 0
            if type(plants) == "table" then
                for plantKey in pairs(plants) do
                    emit(tonumber(plantKey), seedUid)
                end
            end
        end
    end
    local demand = PooledSpecDemand()
    for _, row in pairs(demand) do
        if type(row) == "table" and SpecIsGrowablePlant(row.spec) then
            local seed = StockPiler.SeedMap and StockPiler.SeedMap.ResolveSeedForSpec
                and StockPiler.SeedMap.ResolveSeedForSpec(row.spec)
            local seedUid = type(seed) == "table" and (tonumber(seed.uniqueID) or 0) or 0
            local plantUid = type(seed) == "table" and (tonumber(seed.plantUid) or 0) or 0
            if plantUid <= 0 then
                plantUid = PlantUidForGrowSpec(row.spec)
            end
            emit(plantUid, seedUid)
        end
    end
end

--- Plants in bags whose seed/spore stack is below the buffer.
--- Only converts surplus above watched brew demand so Load stays possible.
function StockPiler.Planner.CollectSeedBufferRefills()
    local buffer = StockPiler.Planner.GetSeedBufferMin()
    local jobs = {}
    ForEachKnownSeedPlantPair(function(plantUid, seedUid)
        local seedHave = CountSeedInBags(seedUid)
        if seedHave >= buffer then
            return
        end
        local plantHave = CountPlantInBags(plantUid)
        local surplus = plantHave
        if StockPiler.Planner.WatchedPlantCraftSurplus then
            surplus = tonumber(StockPiler.Planner.WatchedPlantCraftSurplus(plantUid)) or 0
        end
        local uses = buffer - seedHave
        if plantHave < uses then
            uses = plantHave
        end
        if surplus < uses then
            uses = surplus
        end
        if uses > 0 then
            jobs[#jobs + 1] = {
                plantUid = plantUid,
                seedUid = seedUid,
                seedHave = seedHave,
                surplus = surplus,
                uses = uses,
            }
        end
    end)
    return jobs
end

--- Seeds below the buffer with no plants left to refine. Low-priority grow
--- so harvest + refine can refill the seed stack. Potion-target demand
--- must take empty plots first.
function StockPiler.Planner.CollectSeedBufferGrowJobs()
    local buffer = StockPiler.Planner.GetSeedBufferMin()
    local jobs = {}
    local seenSeed = {}
    ForEachKnownSeedPlantPair(function(plantUid, seedUid)
        if seenSeed[seedUid] == true then
            return
        end
        local seedHave = 0
        if StockPiler.AutoGrow and StockPiler.AutoGrow.GetEffectiveSeedCount then
            seedHave = tonumber(StockPiler.AutoGrow.GetEffectiveSeedCount(seedUid)) or 0
        end
        local plantHave = CountPlantInBags(plantUid)
        if seedHave <= 0 or seedHave >= buffer or plantHave > 0 then
            return
        end
        seenSeed[seedUid] = true
        local want = buffer - seedHave
        local plantable = StockPiler.Planner.ComputeSeedPlantable(seedHave, buffer, 0, want)
        if plantable <= 0 then
            return
        end
        if StockPiler.Inventory and StockPiler.Inventory.CanUseUniqueId
            and not StockPiler.Inventory.CanUseUniqueId(seedUid)
        then
            return
        end
        jobs[#jobs + 1] = {
            specKey = "buffer:" .. tostring(seedUid),
            plantUid = plantUid,
            seedUid = seedUid,
            seedHave = seedHave,
            plantHave = plantHave,
            want = want,
            plantable = plantable,
            seed = SeedRecordForUid(seedUid, plantUid),
        }
    end)
    table.sort(jobs, function(a, b)
        local sa = tonumber(a.want) or 0
        local sb = tonumber(b.want) or 0
        if sa ~= sb then
            return sa > sb
        end
        return (tonumber(a.seedUid) or 0) < (tonumber(b.seedUid) or 0)
    end)
    return jobs
end

local function EffectiveSeedCount(seedUid)
    seedUid = tonumber(seedUid) or 0
    if seedUid <= 0 then
        return 0
    end
    if StockPiler.AutoGrow and StockPiler.AutoGrow.GetEffectiveSeedCount then
        return tonumber(StockPiler.AutoGrow.GetEffectiveSeedCount(seedUid)) or 0
    end
    return 0
end

--- Convert plants to seeds up to the seed buffer, or enough to fill
--- empty / soon-empty plots, whichever is larger. Do this before planting
--- so a 1-seed + 2-plant bag becomes 3 seeds (buffer 4) then a plant wave.
function StockPiler.Planner.CollectGrowCycleRefineJobs(emptyPlots)
    emptyPlots = tonumber(emptyPlots) or 0
    if emptyPlots < 0 then
        emptyPlots = 0
    end
    local buffer = StockPiler.Planner.GetSeedBufferMin()
    local demand = nil
    local cached = StockPiler.Planner._planCache
    if type(cached) == "table" and type(cached.specDemand) == "table" then
        demand = cached.specDemand
    else
        demand = PooledSpecDemand()
    end
    local bySeed = {}
    for _, row in pairs(demand) do
        if type(row) == "table"
            and type(row.spec) == "table"
            and SpecIsGrowablePlant(row.spec)
            and (tonumber(row.deficit) or 0) > 0
        then
            local seed = nil
            if StockPiler.SeedMap and StockPiler.SeedMap.ResolveSeedForSpec then
                seed = StockPiler.SeedMap.ResolveSeedForSpec(row.spec)
            end
            if type(seed) == "table" then
                local seedUid = tonumber(seed.uniqueID) or 0
                local plantUid = tonumber(seed.plantUid) or 0
                if plantUid <= 0 then
                    plantUid = PlantUidForGrowSpec(row.spec)
                end
                if seedUid > 0 then
                    local deficit = tonumber(row.deficit) or 0
                    local wantSeeds = emptyPlots
                    if buffer > wantSeeds then
                        wantSeeds = buffer
                    end
                    if wantSeeds > deficit then
                        wantSeeds = deficit
                    end
                    local existing = bySeed[seedUid]
                    if existing == nil then
                        bySeed[seedUid] = {
                            plantUid = plantUid,
                            seedUid = seedUid,
                            wantSeeds = wantSeeds,
                            deficit = deficit,
                        }
                    else
                        if wantSeeds > (existing.wantSeeds or 0) then
                            existing.wantSeeds = wantSeeds
                        end
                        if deficit > (existing.deficit or 0) then
                            existing.deficit = deficit
                        end
                    end
                end
            end
        end
    end
    local jobs = {}
    for _, job in pairs(bySeed) do
        local seedHave = EffectiveSeedCount(job.seedUid)
        local uses = (tonumber(job.wantSeeds) or 0) - seedHave
        if uses > 0 then
            job.uses = uses
            job.seedHave = seedHave
            jobs[#jobs + 1] = job
        end
    end
    table.sort(jobs, function(a, b)
        local da = tonumber(a.deficit) or 0
        local db = tonumber(b.deficit) or 0
        if da ~= db then
            return da > db
        end
        return (tonumber(a.seedUid) or 0) < (tonumber(b.seedUid) or 0)
    end)
    return jobs
end

local function PlotStageIsEmpty(plotNum)
    local empty = 0
    if GameData and GameData.CultivationStage then
        empty = GameData.CultivationStage.EMPTY or 0
    end
    local cache = StockPiler.AutoGrow and StockPiler.AutoGrow._plotCache
    if type(cache) ~= "table" then
        return true
    end
    local plotData = cache[plotNum]
    if type(plotData) ~= "table" then
        return true
    end
    local stage = tonumber(plotData.StageNum) or 0
    if stage == 255 then
        stage = empty
    end
    return stage == empty
end

-- Only empty plots get a queue slot. Occupied plots already have a crop;
-- assigning them Goldweed made the harvest tooltip disagree with Growing.
local function EmptyFirstPlotOrder(plotCount)
    plotCount = tonumber(plotCount) or 4
    local order = {}
    for plotNum = 1, plotCount do
        if PlotStageIsEmpty(plotNum) then
            order[#order + 1] = plotNum
        end
    end
    return order
end

function StockPiler.Planner.BuildGrowQueueFromSpecDeficits(specDemand, traceOut)
    local queue = {}
    local plotCount = StockPiler.Planner.GetGrowPlotCount and StockPiler.Planner.GetGrowPlotCount()
        or StockPiler.Planner.GROW_PLOT_COUNT or 4
    local plotOrder = EmptyFirstPlotOrder(plotCount)
    local seedBuffer = StockPiler.Planner.GetSeedBufferMin()
    if type(traceOut) == "table" then
        traceOut[#traceOut + 1] = "seedBuffer=" .. tostring(seedBuffer)
    end

    local function resolveGrow(spec, matHave, plantsShort)
        local seed = StockPiler.SeedMap and StockPiler.SeedMap.ResolveSeedForSpec(spec)
        if type(seed) ~= "table" then
            return nil, "no seed map"
        end
        local seedUid = tonumber(seed.uniqueID) or 0
        local plantUid = tonumber(seed.plantUid) or 0
        if plantUid <= 0 and seedUid > 0 and StockPiler.SeedMap.GetPlantUidForSeed then
            plantUid = StockPiler.SeedMap.GetPlantUidForSeed(seedUid) or 0
        end
        if plantUid <= 0 and StockPiler.SeedMap.FindPlantUidForSpec then
            plantUid = StockPiler.SeedMap.FindPlantUidForSpec(spec) or 0
        end
        -- Effective count only (live minus in-flight plants). Do not fall
        -- back to raw bag count: that reassigned a seed already committed.
        local seedHave = 0
        if seedUid > 0 and StockPiler.AutoGrow and StockPiler.AutoGrow.GetEffectiveSeedCount then
            seedHave = tonumber(StockPiler.AutoGrow.GetEffectiveSeedCount(seedUid)) or 0
        end
        matHave = tonumber(matHave) or 0
        plantsShort = tonumber(plantsShort) or 0
        local plantable = StockPiler.Planner.ComputeSeedPlantable(seedHave, seedBuffer, matHave, plantsShort)
        if plantable <= 0 then
            if plantsShort <= 0 then
                return nil, "stocked"
            end
            if seedHave <= 0 then
                return nil, "no_seeds"
            end
            return nil, "not plantable seedUid=" .. tostring(seedUid)
                .. " seedHave=" .. tostring(seedHave)
                .. " plantsShort=" .. tostring(plantsShort)
        end
        if seedUid > 0 and StockPiler.Inventory and StockPiler.Inventory.CanUseUniqueId
            and not StockPiler.Inventory.CanUseUniqueId(seedUid)
        then
            return nil, "skill seedUid=" .. tostring(seedUid)
        end
        return {
            seed = seed,
            seedUid = seedUid,
            plantUid = plantUid,
            seedHave = seedHave,
            matHave = matHave,
            plantable = plantable,
            needsRefine = false,
        }
    end

    local function assignLimit(info)
        return tonumber(info.plantable) or 0
    end

    local infoByKey = {}
    local virtualHave = {}
    local used = {}

    local function remainingHarvestNames(rows)
        local names = {}
        local seen = {}
        if type(rows) ~= "table" then
            return names
        end
        for i = 1, #rows do
            local row = rows[i]
            local info = row and infoByKey[row.specKey]
            if info then
                local n = used[row.specKey] or 0
                local have = virtualHave[row.specKey] or 0
                local need = tonumber(row.absolute) or tonumber(row.need) or 0
                if n < assignLimit(info) and have < need then
                    local name = ToNarrow(info.seed and info.seed.name or L"")
                    if name ~= "" and seen[name] ~= true then
                        seen[name] = true
                        names[#names + 1] = name
                    end
                end
            end
        end
        return names
    end

    local function queueHasSlot()
        for plotNum = 1, plotCount do
            if type(queue[plotNum]) == "table" then
                return true
            end
        end
        return false
    end

    local function queueEntry(plotNum, info, specKey)
        local demandRow = type(specDemand) == "table" and specDemand[specKey] or nil
        local entry = {
            seedKey = info.seed.nameNarrow or "",
            seedName = info.seed.name or L"",
            seedUid = info.seedUid,
            plantUid = info.plantUid,
            seedHave = info.seedHave,
            seedPlantable = info.plantable,
            matHave = info.matHave,
            specKey = specKey,
            plotNum = plotNum,
            refineFirst = info.needsRefine == true,
            plantReason = "potion_stock",
        }
        if type(demandRow) == "table" then
            entry.matNeed = tonumber(demandRow.absolute) or 0
            entry.watchNames = demandRow.watchNames
            entry.watchDetails = demandRow.watchDetails
        end
        return entry
    end

    -- Potion-target plots first. Leftover empty plots may grow a seed-buffer
    -- shortage (no plants to refine) at lowest priority.
    local assignedSeedUids = {}

    local function fillBufferGrowPlots()
        local jobs = StockPiler.Planner.CollectSeedBufferGrowJobs()
        if type(jobs) ~= "table" or #jobs == 0 then
            return
        end
        local usedBuf = {}
        for oi = 1, #plotOrder do
            local plotNum = plotOrder[oi]
            if type(queue[plotNum]) ~= "table" then
                local best = nil
                for i = 1, #jobs do
                    local job = jobs[i]
                    local seedUid = tonumber(job.seedUid) or 0
                    if assignedSeedUids[seedUid] ~= true then
                        local n = usedBuf[seedUid] or 0
                        if n < (tonumber(job.plantable) or 0) then
                            best = job
                            break
                        end
                    end
                end
                if best == nil then
                    break
                end
                local seedUid = tonumber(best.seedUid) or 0
                usedBuf[seedUid] = (usedBuf[seedUid] or 0) + 1
                local info = {
                    seed = best.seed,
                    seedUid = seedUid,
                    plantUid = best.plantUid,
                    seedHave = best.seedHave,
                    matHave = best.plantHave or 0,
                    plantable = best.plantable,
                    needsRefine = false,
                }
                if type(info.seed) ~= "table" then
                    info.seed = {
                        name = L"seed",
                        nameNarrow = "seed",
                        uniqueID = seedUid,
                    }
                end
                queue[plotNum] = queueEntry(plotNum, info, best.specKey)
                queue[plotNum].bufferGrow = true
                queue[plotNum].plantReason = "seed_buffer"
                queue[plotNum].bufferWant = best.want
                queue[plotNum].watchNames = nil
                queue[plotNum].watchDetails = nil
                if type(traceOut) == "table" then
                    traceOut[#traceOut + 1] = string.format(
                        "ASSIGN P%d buffer-grow seedUid=%d have=%d want=%d plantable=%d",
                        plotNum,
                        seedUid,
                        tonumber(best.seedHave) or 0,
                        tonumber(best.want) or 0,
                        tonumber(best.plantable) or 0
                    )
                end
            end
        end
    end

    -- Pooled demand is the source of truth: each AutoGrow-enabled watch adds its
    -- ingredient need, then bags are subtracted once. Per-recipe have/need would
    -- stop at the largest single potion instead of the combined shortfall.
    local hasPooledDemand = false
    local sorted = {}
    if type(specDemand) == "table" then
        for _, row in pairs(specDemand) do
            hasPooledDemand = true
            if type(row) == "table"
                and (tonumber(row.deficit) or 0) > 0
                and SpecIsGrowablePlant(row.spec)
            then
                sorted[#sorted + 1] = row
            end
        end
    end
    table.sort(sorted, CompareGrowPriority)

    if hasPooledDemand then
        if type(traceOut) == "table" then
            if #sorted == 0 then
                traceOut[#traceOut + 1] = "mode=pooled spec demand (no growable deficit)"
            else
                traceOut[#traceOut + 1] = "mode=pooled spec demand (all AutoGrow watches)"
                traceOut[#traceOut + 1] = "priority=minWatchCraftable asc, minWatchStock asc, craftsHave asc, craftsShort desc, deficit desc"
            end
            for i = 1, #sorted do
                local row = sorted[i]
                traceOut[#traceOut + 1] = string.format(
                    "  RANKED #%d %s have=%d need=%d %s",
                    i,
                    GrowTraceSpecLabel(row),
                    tonumber(row.have) or 0,
                    tonumber(row.absolute) or 0,
                    FormatGrowPriorityFields(row)
                )
            end
        end
        local skipNoSeeds = false
        for i = 1, #sorted do
            local row = sorted[i]
            local info, reason = resolveGrow(row.spec, row.have, tonumber(row.deficit) or 0)
            if info then
                infoByKey[row.specKey] = info
                virtualHave[row.specKey] = tonumber(row.have) or 0
                if type(traceOut) == "table" then
                    traceOut[#traceOut + 1] = string.format(
                        "  READY #%d %s seedUid=%d plantUid=%d plantable=%d seedHave=%d",
                        i,
                        GrowTraceSpecLabel(row),
                        tonumber(info.seedUid) or 0,
                        tonumber(info.plantUid) or 0,
                        tonumber(info.plantable) or 0,
                        tonumber(info.seedHave) or 0
                    )
                end
            else
                if reason == "no_seeds" then
                    skipNoSeeds = true
                end
                if type(traceOut) == "table" then
                    traceOut[#traceOut + 1] = string.format(
                        "  SKIP #%d %s reason=%s have=%d deficit=%d %s",
                        i,
                        GrowTraceSpecLabel(row),
                        tostring(reason),
                        tonumber(row.have) or 0,
                        tonumber(row.deficit) or 0,
                        FormatGrowPriorityFields(row)
                    )
                end
            end
        end
        -- Honor CompareGrowPriority: first plantable spec in sorted order.
        -- Lowest bag have used to steal every plot for Goldweed even when
        -- another watch was at Craftable 0 on a different plant.
        for oi = 1, #plotOrder do
            local plotNum = plotOrder[oi]
            local best = nil
            local bestRank = 0
            local runner = nil
            local runnerRank = 0
            for i = 1, #sorted do
                local row = sorted[i]
                local info = infoByKey[row.specKey]
                if info ~= nil then
                    local n = used[row.specKey] or 0
                    local have = virtualHave[row.specKey] or 0
                    local need = tonumber(row.absolute) or 0
                    if n < assignLimit(info) and have < need then
                        if best == nil then
                            best = row
                            bestRank = i
                        elseif runner == nil then
                            runner = row
                            runnerRank = i
                            break
                        end
                    end
                end
            end
            if best == nil then
                if type(traceOut) == "table" then
                    traceOut[#traceOut + 1] = "ASSIGN P" .. tostring(plotNum)
                        .. " empty (no eligible seed among ranked ready)"
                end
                break
            end
            local info = infoByKey[best.specKey]
            used[best.specKey] = (used[best.specKey] or 0) + 1
            virtualHave[best.specKey] = (virtualHave[best.specKey] or 0) + 1
            assignedSeedUids[tonumber(info.seedUid) or 0] = true
            if type(traceOut) == "table" then
                local line = string.format(
                    "ASSIGN P%d #%d %s seedUid=%d plantable=%d afterHave=%d need=%d %s",
                    plotNum,
                    bestRank,
                    GrowTraceSpecLabel(best),
                    tonumber(info.seedUid) or 0,
                    tonumber(info.plantable) or 0,
                    virtualHave[best.specKey] or 0,
                    tonumber(best.absolute) or 0,
                    FormatGrowPriorityFields(best)
                )
                if runner ~= nil then
                    line = line .. string.format(
                        " | runnerUp=#%d %s %s",
                        runnerRank,
                        GrowTraceSpecLabel(runner),
                        FormatGrowPriorityFields(runner)
                    )
                end
                traceOut[#traceOut + 1] = line
            end
            queue[plotNum] = queueEntry(plotNum, info, best.specKey)
        end
        fillBufferGrowPlots()
        queue.nextAfterHarvest = remainingHarvestNames(sorted)
        if not queueHasSlot() and #(queue.nextAfterHarvest) == 0 then
            if #sorted == 0 then
                queue.emptyReason = L"No plot plan: short mats are flasks or vendor items, not growable plants."
            elseif skipNoSeeds then
                queue.emptyReason = L"No plot plan: need plants but have no seeds in bags. AutoGrow will convert refinable plants up to the seed buffer, then plant."
            else
                queue.emptyReason = L"No plot plan: growable mats are short but nothing is plantable right now."
            end
        end
        return queue
    end

    -- Fallback when spec demand was not built: sum growable slots across recipes.
    local recipes = CollectWatchedRecipeGrowStates()
    if #recipes == 0 then
        fillBufferGrowPlots()
        return queue
    end

    local function slotHave(slot)
        if slot.growable == true then
            return virtualHave[slot.specKey] or slot.have or 0
        end
        return slot.have or 0
    end

    local function slotCrafts(slot)
        local pc = tonumber(slot.perCraft) or 1
        if pc < 1 then
            pc = 1
        end
        return math.floor(slotHave(slot) / pc)
    end

    local function recipePossible(rec)
        local minC = nil
        for i = 1, #rec.slots do
            local slot = rec.slots[i]
            if slot.growable == true and infoByKey[slot.specKey] ~= nil then
                local c = slotCrafts(slot)
                if minC == nil or c < minC then
                    minC = c
                end
            end
        end
        return minC or 0
    end

    local pooledNeedByKey = {}
    for r = 1, #recipes do
        local rec = recipes[r]
        local slots = rec.slots or {}
        for i = 1, #slots do
            local slot = slots[i]
            if slot.growable == true and slot.specKey then
                local add = (tonumber(rec.craftsNeeded) or 0) * (tonumber(slot.perCraft) or 1)
                pooledNeedByKey[slot.specKey] = (pooledNeedByKey[slot.specKey] or 0) + add
            end
        end
    end

    if type(traceOut) == "table" then
        traceOut[#traceOut + 1] = "mode=raise recipe craftable (pooled slot need)"
    end
    for r = 1, #recipes do
        local rec = recipes[r]
        if type(traceOut) == "table" then
            traceOut[#traceOut + 1] = string.format(
                "recipe %s craftsPossible=%d craftsNeeded=%d",
                ToNarrow(rec.name),
                rec.craftsPossible or 0,
                rec.craftsNeeded or 0
            )
        end
        for i = 1, #rec.slots do
            local slot = rec.slots[i]
            if type(traceOut) == "table" then
                traceOut[#traceOut + 1] = string.format(
                    "  slot %s role=%s have=%d perCraft=%d craftsHave=%d growable=%s byproduct=%s pooledNeed=%d",
                    tostring(slot.specKey),
                    tostring(slot.role or "?"),
                    slot.have or 0,
                    slot.perCraft or 1,
                    slot.craftsHave or 0,
                    tostring(slot.growable == true),
                    tostring(slot.harvestByproduct == true),
                    tonumber(pooledNeedByKey[slot.specKey]) or 0
                )
            end
            if slot.growable == true and infoByKey[slot.specKey] == nil then
                virtualHave[slot.specKey] = slot.have or 0
                local plantsNeed = tonumber(pooledNeedByKey[slot.specKey]) or 0
                local plantsShort = math.max(0, plantsNeed - (tonumber(slot.have) or 0))
                local info, reason = resolveGrow(slot.spec, slot.have, plantsShort)
                if info then
                    infoByKey[slot.specKey] = info
                elseif type(traceOut) == "table" then
                    traceOut[#traceOut + 1] = string.format(
                        "  SKIP %s reason=%s",
                        tostring(slot.specKey),
                        tostring(reason)
                    )
                end
            end
        end
    end

    for oi = 1, #plotOrder do
        local plotNum = plotOrder[oi]
        local bestSlot = nil
        local bestPossible = nil
        local bestCrafts = nil
        local bestUsed = nil
        for r = 1, #recipes do
            local rec = recipes[r]
            local possible = recipePossible(rec)
            local pooledStillNeeds = false
            for i = 1, #rec.slots do
                local slot = rec.slots[i]
                if slot.growable == true then
                    local vHave = virtualHave[slot.specKey] or slot.have or 0
                    if vHave < (tonumber(pooledNeedByKey[slot.specKey]) or 0) then
                        pooledStillNeeds = true
                        break
                    end
                end
            end
            if possible < (rec.craftsNeeded or 0) or pooledStillNeeds then
                for i = 1, #rec.slots do
                    local slot = rec.slots[i]
                    local info = infoByKey[slot.specKey]
                    if slot.growable == true and info ~= nil then
                        local n = used[slot.specKey] or 0
                        local vCrafts = slotCrafts(slot)
                        local vHave = virtualHave[slot.specKey] or slot.have or 0
                        local pooledNeed = tonumber(pooledNeedByKey[slot.specKey]) or 0
                        local eligible = n < assignLimit(info)
                            and vHave < pooledNeed
                            and vCrafts <= possible
                        if eligible then
                            if bestSlot == nil
                                or possible < bestPossible
                                or (possible == bestPossible and vCrafts < bestCrafts)
                                or (possible == bestPossible and vCrafts == bestCrafts and n < bestUsed)
                            then
                                bestSlot = slot
                                bestPossible = possible
                                bestCrafts = vCrafts
                                bestUsed = n
                            end
                        end
                    end
                end
            end
        end
        if bestSlot == nil then
            if type(traceOut) == "table" then
                traceOut[#traceOut + 1] = "P" .. tostring(plotNum) .. " empty (no eligible seed)"
            end
            break
        end
        local info = infoByKey[bestSlot.specKey]
        used[bestSlot.specKey] = (used[bestSlot.specKey] or 0) + 1
        virtualHave[bestSlot.specKey] = (virtualHave[bestSlot.specKey] or 0) + 1
        assignedSeedUids[tonumber(info.seedUid) or 0] = true
        if type(traceOut) == "table" then
            traceOut[#traceOut + 1] = string.format(
                "ASSIGN P%d %s seedUid=%d plantUid=%d seedHave=%d matHave=%d plantable=%d role=%s craftsHave=%d after=%d",
                plotNum,
                tostring(bestSlot.specKey),
                info.seedUid,
                info.plantUid,
                info.seedHave,
                info.matHave,
                info.plantable,
                tostring(bestSlot.role or "?"),
                bestSlot.craftsHave or 0,
                slotCrafts(bestSlot)
            )
        end
        queue[plotNum] = queueEntry(plotNum, info, bestSlot.specKey)
    end
    fillBufferGrowPlots()
    local leftover = {}
    for specKey, _ in pairs(infoByKey) do
        leftover[#leftover + 1] = {
            specKey = specKey,
            absolute = tonumber(pooledNeedByKey[specKey]) or 0,
        }
    end
    queue.nextAfterHarvest = remainingHarvestNames(leftover)
    return queue
end

function StockPiler.Planner.InvalidatePlanCache()
    StockPiler.Planner._planCache = nil
    StockPiler.Planner._planSnapshotGen = nil
    StockPiler.Planner._planAutoGrowEnabled = nil
    local RS = StockPiler.RecipeSpec
    if RS and RS.ClearCountCaches then
        RS.ClearCountCaches()
    end
end

function StockPiler.Planner.BuildPlanV6(opts)
    opts = opts or {}
    local needSnap = opts.refresh ~= false
        or (StockPiler.Inventory and StockPiler.Inventory._snapshotDone ~= true)
    if needSnap and StockPiler.Inventory and StockPiler.Inventory.RefreshAllIfNeeded then
        StockPiler.Inventory.RefreshAllIfNeeded()
    end
    local snapGen = StockPiler.Inventory and tonumber(StockPiler.Inventory._snapshotGen) or 0
    local s = GetSettings()
    local autoGrowOn = type(s) == "table" and s.autoGrowEnabled == true
    if opts.reuse ~= false
        and type(StockPiler.Planner._planCache) == "table"
        and StockPiler.Planner._planSnapshotGen == snapGen
        and StockPiler.Planner._planAutoGrowEnabled == autoGrowOn
    then
        return StockPiler.Planner._planCache
    end
    if StockPiler.Perf and StockPiler.Perf.Begin then
        StockPiler.Perf.Begin("BuildPlan")
    end
    local function PlanLog(msg)
        if StockPiler.DebugEnabled ~= true then
            return
        end
        if StockPiler._EmitLog and StockPiler._LogText then
            StockPiler._EmitLog("StockPiler| [Plan] " .. StockPiler._LogText(msg))
        elseif type(d) == "function" then
            d("StockPiler| [Plan] " .. tostring(msg))
        end
    end
    local RS = StockPiler.RecipeSpec
    local targets = BuildWatchedTargetsV6()
    local specDemand = RS and RS.BuildBalancedSpecDemand() or {}
    local rows = {}
    for i = 1, #targets do
        local target = targets[i]
        local recipe = RS and RS.RecipeSpecForPotion(target.potionKey)
        local row = {
            id = target.id,
            potionKey = target.potionKey,
            name = target.name,
            iconNum = target.iconNum,
            uniqueID = target.uniqueID,
            potionHave = target.have,
            stockText = towstring(tostring(target.have)),
            potionMin = target.min,
            target = target.min,
            targetText = towstring(tostring(target.min)),
            potionDeficit = target.deficit,
            growable = false,
            canMoveUp = false,
            canMoveDown = false,
            recipe = recipe,
            specRecipe = recipe,
        }
        ApplySpecPlanStatus(row, target, recipe, specDemand)
        row.autoGrow = target.autoGrow == true -- per-potion checkbox; planting also requires global autoGrowEnabled
        row.recipeLabel = target.recipeLabel
        row.recipeSpecKey = target.recipeSpecKey
        row.potionBaseKey = target.potionBaseKey
        row.displayName = target.name
        local craftable = 0
        if recipe and RS.CountPotionsCraftable then
            craftable = RS.CountPotionsCraftable(recipe)
            row.craftableText = towstring(tostring(craftable)) .. L"*"
        else
            row.craftableText = L"-"
        end
        row.craftable = craftable
        row.hasRecipe = type(recipe) == "table"
        local canApo = true
        if StockPiler.Inventory and StockPiler.Inventory.IsApothecary then
            canApo = StockPiler.Inventory.IsApothecary() == true
        end
        -- Craftable already excludes seeds. Load click still checks the live
        -- crafting bag. Do not scan the bag once per watch here (1s+ hitch).
        row.canLoad = canApo and row.hasRecipe == true and craftable > 0
        row.canBrew = row.canLoad
        rows[#rows + 1] = row
    end
    local queueTrace = {}
    local queue = StockPiler.Planner.BuildGrowQueueFromSpecDeficits(specDemand, queueTrace)
    local plan = { rows = rows, queue = queue, specDemand = specDemand, queueTrace = queueTrace }
    StockPiler.Planner._lastQueueTrace = queueTrace
    StockPiler.Planner._planCache = plan
    StockPiler.Planner._planSnapshotGen = snapGen
    StockPiler.Planner._planAutoGrowEnabled = autoGrowOn
    PlanLog("rebuild snap=" .. tostring(snapGen)
        .. " autoGrow=" .. tostring(autoGrowOn)
        .. " watches=" .. tostring(#rows))
    for i = 1, #rows do
        local row = rows[i]
        PlanLog(string.format(
            "  watch %s have=%s target=%s def=%s yield=%s stockY=%s craftsNeed=%s craftable=%s status=%s",
            ToNarrow(row.name),
            tostring(row.potionHave),
            tostring(row.potionMin),
            tostring(row.potionDeficit),
            tostring(row.recipeYield),
            tostring(row.stockYield),
            tostring(row.craftsNeeded),
            tostring(row.craftable),
            ToNarrow(row.statusText or row.statusKey)
        ))
    end
    if type(specDemand) == "table" then
        for specKey, drow in pairs(specDemand) do
            if type(drow) == "table" then
                local label = specKey
                if StockPiler.MaterialSpec and StockPiler.MaterialSpec.Label and drow.spec then
                    label = ToNarrow(StockPiler.MaterialSpec.Label(drow.spec))
                end
                PlanLog(string.format(
                    "  spec %s have=%s need=%s def=%s perCraft=%s",
                    tostring(label),
                    tostring(drow.have),
                    tostring(drow.absolute or drow.need),
                    tostring(drow.deficit),
                    tostring(drow.perCraft)
                ))
            end
        end
    end
    if StockPiler.Planner.MaybeNotifyProgressBlockers then
        StockPiler.Planner.MaybeNotifyProgressBlockers(plan)
    end
    if StockPiler.Perf and StockPiler.Perf.End then
        StockPiler.Perf.End("BuildPlan")
    end
    return plan
end

function StockPiler.Planner.BuildPlan(opts)
    local s = GetSettings()
    if (tonumber(s.settingsVersion) or 0) >= 6 and StockPiler.RecipeSpec then
        return StockPiler.Planner.BuildPlanV6(opts)
    end
    opts = opts or {}
    if opts.refresh ~= false then
        if StockPiler.Inventory and StockPiler.Inventory.RefreshAllIfNeeded then
            StockPiler.Inventory.RefreshAllIfNeeded()
        end
    end

    StockPiler.Planner.EnsureGrowOrder()

    local targets = BuildWatchedTargets()
    local demandTotals = BuildMaterialDemandTotals(targets)
    local allocById = BuildTargetAllocations(targets)

    local rows = {}

    for i = 1, #targets do
        local target = targets[i]
        local entry = target.entry
        local alloc = allocById[target.id]
        local recipe = alloc and alloc.recipe or RecipeForPotion(entry, target.uniqueID)
        local growRank = GetGrowRank(target.id)
        local row = {
            id = target.id,
            name = target.name,
            iconNum = target.iconNum,
            itemData = target.itemData,
            entry = entry,
            uniqueID = target.uniqueID,
            growRank = growRank,
            potionHave = target.have,
            stockText = towstring(tostring(target.have)),
            potionMin = target.min,
            target = target.min,
            targetText = towstring(tostring(target.min)),
            potionDeficit = target.deficit,
            growable = false,
            matHave = 0,
            matNeed = 0,
            matDeficit = 0,
            seedHave = 0,
            seedPlantable = 0,
            seedKey = "",
            seedUid = 0,
            canMoveUp = growRank > 1,
            canMoveDown = false,
            statusKey = "no_target",
            statusText = L"Set target",
            statusDetail = L"",
        }

        ApplyPlanStatus(row, target, recipe, entry, alloc, demandTotals)
        row.recipe = recipe
        local canApo = true
        if StockPiler.Inventory and StockPiler.Inventory.IsApothecary then
            canApo = StockPiler.Inventory.IsApothecary() == true
        end
        row.canLoad = canApo and row.statusKey == "ready_to_craft" and type(recipe) == "table"
        row.canBrew = row.canLoad
        rows[#rows + 1] = row
    end

    table.sort(rows, function(a, b)
        if (a.growRank or 9999) ~= (b.growRank or 9999) then
            return (a.growRank or 9999) < (b.growRank or 9999)
        end
        return ToNarrow(a.name) < ToNarrow(b.name)
    end)

    for i = 1, #rows do
        rows[i].canMoveUp = i > 1
        rows[i].canMoveDown = i < #rows
    end

    local queue = StockPiler.Planner.BuildGrowQueueFromRows(rows, demandTotals, allocById)
    local plan = {
        rows = rows,
        queue = queue,
    }
    if StockPiler.Planner.MaybeNotifyProgressBlockers then
        StockPiler.Planner.MaybeNotifyProgressBlockers(plan)
    end
    return plan
end

StockPiler.Planner.GROW_PLOT_COUNT = 4

function StockPiler.Planner.GetGrowPlotCount()
    if StockPiler.AutoGrow and StockPiler.AutoGrow.NumPlots then
        return math.max(0, tonumber(StockPiler.AutoGrow.NumPlots()) or 0)
    end
    if StockPiler.Inventory and StockPiler.Inventory.GetLocalCultivator then
        local info = StockPiler.Inventory.GetLocalCultivator()
        return math.max(0, tonumber(info and info.plots) or 0)
    end
    return 0
end

local function SpecLabel(spec)
    if StockPiler.MaterialSpec and StockPiler.MaterialSpec.Label then
        return ToNarrow(StockPiler.MaterialSpec.Label(spec))
    end
    return ToNarrow(spec and spec.name)
end

local function SpecNeedLabel(spec, context)
    if StockPiler.MaterialSpec and StockPiler.MaterialSpec.NeedLabel then
        return ToNarrow(StockPiler.MaterialSpec.NeedLabel(spec, context))
    end
    return SpecLabel(spec)
end

local function SpecIsFlask(spec, role)
    role = role or (spec and spec.role) or ""
    if role == "container" then
        return true
    end
    if StockPiler.MaterialSpec and StockPiler.MaterialSpec.IsPurchasable
        and StockPiler.MaterialSpec.IsPurchasable(spec)
    then
        return true
    end
    local name = string.lower(SpecLabel(spec))
    return string.find(name, "flask", 1, true) ~= nil
        or string.find(name, "vial", 1, true) ~= nil
        or string.find(name, "ampoule", 1, true) ~= nil
        or string.find(name, "phial", 1, true) ~= nil
end

local function SpecSeedGrowing(spec, seedUid)
    seedUid = tonumber(seedUid) or 0
    local cache = StockPiler.AutoGrow and StockPiler.AutoGrow._plotCache
    if type(cache) ~= "table" then
        return false
    end
    local plots = StockPiler.Planner.GetGrowPlotCount()
    local empty = 0
    if GameData and GameData.CultivationStage then
        empty = GameData.CultivationStage.EMPTY or 0
    end
    for plotNum = 1, plots do
        local plotData = cache[plotNum]
        if type(plotData) == "table" then
            local stage = tonumber(plotData.StageNum) or 0
            if stage == 255 then
                stage = empty
            end
            if stage ~= empty and type(plotData.Seed) == "table" then
                local plotSeed = tonumber(plotData.Seed.uniqueID) or 0
                if seedUid > 0 and plotSeed == seedUid then
                    return true
                end
            end
        end
    end
    return false
end

local function PlotCacheReady()
    local cache = StockPiler.AutoGrow and StockPiler.AutoGrow._plotCache
    if type(cache) ~= "table" then
        return false
    end
    local plots = StockPiler.Planner.GetGrowPlotCount()
    if plots <= 0 then
        return true
    end
    for plotNum = 1, plots do
        if type(cache[plotNum]) == "table" then
            return true
        end
    end
    return false
end

--- Missing seeds / flasks / butchering mats that stop a watched potion.
function StockPiler.Planner.CollectProgressBlockers(plan)
    local blockers = {
        seeds = {},
        flasks = {},
        butcher = {},
        other = {},
    }
    if type(plan) ~= "table" then
        return blockers
    end
    if StockPiler.Inventory and StockPiler.Inventory._snapshotDone ~= true then
        return blockers
    end

    local seen = {}
    local function add(kind, key, name, have, need)
        name = tostring(name or key or "")
        if name == "" then
            return
        end
        have = tonumber(have) or 0
        need = tonumber(need) or 0
        local id = string.lower(name)
        local prev = seen[id]
        if type(prev) == "table" then
            if have < prev.have then
                prev.have = have
            end
            if need > prev.need then
                prev.need = need
            end
            return
        end
        local list = blockers[kind]
        if type(list) ~= "table" then
            return
        end
        local entry = {
            name = name,
            have = have,
            need = need,
        }
        seen[id] = entry
        list[#list + 1] = entry
    end

    local autoGrowOn = StockPiler.AutoGrow
        and StockPiler.AutoGrow.IsEnabled
        and StockPiler.AutoGrow.IsEnabled() == true
    local plotsReady = PlotCacheReady()
    local canGrow = StockPiler.Inventory
        and StockPiler.Inventory.IsCultivator
        and StockPiler.Inventory.IsCultivator() == true

    local function considerSpec(spec, role, have, need, deficit)
        if type(spec) ~= "table" then
            return
        end
        deficit = tonumber(deficit) or 0
        if deficit <= 0 then
            return
        end
        have = tonumber(have) or 0
        need = tonumber(need) or 0
        role = role or spec.role or ""
        local specKey = ""
        if StockPiler.MaterialSpec and StockPiler.MaterialSpec.Key then
            specKey = tostring(StockPiler.MaterialSpec.Key(spec) or "")
        end
        if specKey == "" then
            specKey = SpecNeedLabel(spec)
        end
        if StockPiler.SeedMap and StockPiler.SeedMap.IsHarvestByproduct
            and StockPiler.SeedMap.IsHarvestByproduct(spec) == true
        then
            if canGrow ~= true then
                add("other", specKey, SpecNeedLabel(spec), have, need)
            end
            return
        end
        if SpecIsFlask(spec, role) then
            add("flasks", specKey, SpecNeedLabel(spec), have, need)
            return
        end
        if SpecIsGrowablePlant(spec) then
            if canGrow ~= true then
                add("other", specKey, SpecNeedLabel(spec), have, need)
                return
            end
            if autoGrowOn ~= true or plotsReady ~= true then
                return
            end
            local seed = nil
            if StockPiler.SeedMap and StockPiler.SeedMap.ResolveSeedForSpec then
                seed = StockPiler.SeedMap.ResolveSeedForSpec(spec)
            end
            local seedUid = type(seed) == "table" and (tonumber(seed.uniqueID) or 0) or 0
            local plantUid = type(seed) == "table" and (tonumber(seed.plantUid) or 0) or 0
            if plantUid <= 0 and seedUid > 0 and StockPiler.SeedMap and StockPiler.SeedMap.GetPlantUidForSeed then
                plantUid = tonumber(StockPiler.SeedMap.GetPlantUidForSeed(seedUid)) or 0
            end
            local seedHave = 0
            if seedUid > 0 then
                if StockPiler.AutoGrow and StockPiler.AutoGrow.GetEffectiveSeedCount then
                    seedHave = tonumber(StockPiler.AutoGrow.GetEffectiveSeedCount(seedUid)) or 0
                end
                if seedHave <= 0 then
                    seedHave = CountSeedInBags(seedUid)
                end
            end
            local plantHave = 0
            if plantUid > 0 then
                plantHave = CountPlantInBags(plantUid)
            end
            if seedHave > 0 or plantHave > 0 or SpecSeedGrowing(spec, seedUid) then
                return
            end
            if StockPiler.AutoGrow and StockPiler.AutoGrow.HasPendingRefine
                and plantUid > 0
                and StockPiler.AutoGrow.HasPendingRefine(plantUid)
            then
                return
            end
            local buffer = 4
            if StockPiler.Planner.GetSeedBufferMin then
                buffer = StockPiler.Planner.GetSeedBufferMin()
            end
            add("seeds", specKey, SpecNeedLabel(spec, { asSeed = true, seed = seed }), seedHave, buffer)
            return
        end
        local needLabel = SpecNeedLabel(spec)
        if LooksButchering(SpecLabel(spec)) or role == "main" then
            add("butcher", specKey, needLabel, have, need)
            return
        end
        add("other", specKey, needLabel, have, need)
    end

    local demand = plan.specDemand
    if type(demand) == "table" then
        for _, row in pairs(demand) do
            if type(row) == "table" then
                considerSpec(
                    row.spec,
                    row.role,
                    row.have,
                    row.absolute or row.need,
                    row.deficit
                )
            end
        end
    end
    local rows = plan.rows
    if type(rows) == "table" then
        for i = 1, #rows do
            local row = rows[i]
            if type(row) == "table" and (tonumber(row.potionDeficit) or 0) > 0 then
                local slots = row.statusSlots
                if type(slots) == "table" then
                    for j = 1, #slots do
                        local slot = slots[j]
                        if type(slot) == "table" then
                            considerSpec(
                                slot.spec,
                                slot.role,
                                slot.have,
                                slot.need,
                                slot.deficit
                            )
                        end
                    end
                end
            end
        end
    end
    return blockers
end

local function SpecJobLabel(spec, context)
    if StockPiler.MaterialSpec and StockPiler.MaterialSpec.NeedLabel then
        return StockPiler.MaterialSpec.NeedLabel(spec, context)
    end
    return L"material"
end

local function ClassifyBuyKind(spec)
    if StockPiler.SeedMap
        and StockPiler.SeedMap.IsHarvestByproduct
        and StockPiler.SeedMap.IsHarvestByproduct(spec) == true
    then
        return "convert"
    end
    if SpecIsGrowablePlant(spec) then
        return "plant"
    end
    return "buy"
end

--- Vendor / chat buy list for every enabled watch below target.
--- Count = ceil(potionDeficit / recipeYield) * perCraft, then minus bags.
--- Perfect-brew yield only; Potent / other rarities do not add extra need.
--- Shared specs pool need first, then subtract one bag count (do not sum deficits).
--- Never plants or refine byproducts. Seeds only when bags have none.
function StockPiler.Planner.CollectVendorBuyJobs()
    local jobs = {}
    if StockPiler.Inventory and StockPiler.Inventory._snapshotDone ~= true then
        return jobs
    end
    local RS = StockPiler.RecipeSpec
    local s = GetSettings()
    if type(RS) ~= "table" or type(s) ~= "table" or type(s.watches) ~= "table" then
        return jobs
    end

    local buyPool = {}
    local seedSeen = {}

    local function addSeedJob(spec, role)
        if type(spec) ~= "table" or not (StockPiler.SeedMap and StockPiler.SeedMap.ResolveSeedForSpec) then
            return
        end
        local seed = StockPiler.SeedMap.ResolveSeedForSpec(spec)
        local seedUid = type(seed) == "table" and (tonumber(seed.uniqueID) or 0) or 0
        if seedUid <= 0 or seedSeen[seedUid] then
            return
        end
        seedSeen[seedUid] = true
        local seedHave = CountSeedInBags(seedUid)
        if seedHave > 0 then
            return
        end
        local buffer = StockPiler.Planner.GetSeedBufferMin and StockPiler.Planner.GetSeedBufferMin() or 4
        local label = SpecJobLabel(spec, { asSeed = true, seed = seed })
        jobs[#jobs + 1] = {
            kind = "seed",
            spec = spec,
            role = role or spec.role,
            seed = seed,
            seedUid = seedUid,
            have = seedHave,
            need = buffer,
            deficit = math.max(1, buffer - seedHave),
            specKey = "seed:" .. tostring(seedUid),
            label = label,
            name = label,
        }
    end

    for watchKey, watch in pairs(s.watches) do
        if type(watch) == "table" and watch.enabled == true then
            local resolved = RS.ResolveWatchPotion and RS.ResolveWatchPotion(watchKey)
            local potion = resolved and resolved.potion
            local recipe = RS.RecipeSpecForPotion and RS.RecipeSpecForPotion(watchKey) or nil
            if type(potion) == "table" and type(recipe) == "table" then
                local target = tonumber(watch.targetStock) or 0
                local havePot = RS.PotionHaveCombined and RS.PotionHaveCombined(potion) or 0
                local potDeficit = math.max(0, target - havePot)
                if potDeficit > 0
                    and target > 0
                    and not (RS.WatchCoveredByBagsAndCraftable
                        and RS.WatchCoveredByBagsAndCraftable(potion, recipe, target))
                then
                    local craftsNeeded = RS.CraftsNeededForDeficit
                        and RS.CraftsNeededForDeficit(potDeficit, recipe)
                        or math.ceil(potDeficit / math.max(1, RS.RecipeOutputYield and RS.RecipeOutputYield(recipe) or 2))
                    local slots = recipe.slots or {}
                    for j = 1, #slots do
                        local slot = slots[j]
                        local spec = type(slot) == "table" and slot.spec or nil
                        if type(spec) == "table" then
                            local kind = ClassifyBuyKind(spec)
                            if kind == "buy" then
                                local specKey = ""
                                if StockPiler.MaterialSpec and StockPiler.MaterialSpec.Key then
                                    specKey = tostring(StockPiler.MaterialSpec.Key(spec) or "")
                                end
                                if specKey == "" then
                                    specKey = ToNarrow(SpecJobLabel(spec))
                                end
                                local perCraft = 1
                                if RS.EffectiveSpecPerCraft then
                                    perCraft = tonumber(RS.EffectiveSpecPerCraft(slot, slots)) or 1
                                end
                                if perCraft < 1 then
                                    perCraft = 1
                                end
                                local row = buyPool[specKey]
                                if row == nil then
                                    row = {
                                        spec = spec,
                                        role = slot.role or spec.role,
                                        specKey = specKey,
                                        absolute = 0,
                                        label = SpecJobLabel(spec),
                                    }
                                    buyPool[specKey] = row
                                end
                                row.absolute = row.absolute + (craftsNeeded * perCraft)
                            elseif kind == "plant" then
                                addSeedJob(spec, slot.role or spec.role)
                            end
                        end
                    end
                end
            end
        end
    end

    for specKey, row in pairs(buyPool) do
        local have = 0
        if RS.CountItemsMatchingSpec then
            have = tonumber(RS.CountItemsMatchingSpec(row.spec)) or 0
        end
        local deficit = math.max(0, (tonumber(row.absolute) or 0) - have)
        if deficit > 0 then
            jobs[#jobs + 1] = {
                kind = "buy",
                spec = row.spec,
                role = row.role,
                have = have,
                need = row.absolute,
                deficit = deficit,
                specKey = specKey,
                label = row.label,
                name = row.label,
            }
        end
    end

    table.sort(jobs, function(a, b)
        local ar = (a and a.role) or ""
        local br = (b and b.role) or ""
        if ar == "container" and br ~= "container" then
            return true
        end
        if br == "container" and ar ~= "container" then
            return false
        end
        local al = ToNarrow(a and (a.label or a.name))
        local bl = ToNarrow(b and (b.label or b.name))
        if al ~= bl then
            return al < bl
        end
        return (tonumber(a and a.deficit) or 0) > (tonumber(b and b.deficit) or 0)
    end)
    return jobs
end

function StockPiler.Planner.ProgressBlockerSignature(blockers)
    if type(blockers) ~= "table" then
        return ""
    end
    local parts = {}
    local function addKind(kind)
        local list = blockers[kind]
        if type(list) ~= "table" or #list == 0 then
            return
        end
        local names = {}
        for i = 1, #list do
            names[#names + 1] = string.lower(tostring(list[i].name or ""))
        end
        table.sort(names)
        parts[#parts + 1] = kind .. "=" .. table.concat(names, ",")
    end
    addKind("seeds")
    addKind("flasks")
    addKind("butcher")
    addKind("other")
    return table.concat(parts, "|")
end

function StockPiler.Planner.MaybeNotifyProgressBlockers(plan)
    if StockPiler.Brew and StockPiler.Brew.IsBusy and StockPiler.Brew.IsBusy() then
        return false
    end
    if type(plan) ~= "table" then
        plan = StockPiler.Planner._planCache
    end
    if type(plan) ~= "table" then
        return false
    end
    if StockPiler.PrintMaterialsToBuy then
        return StockPiler.PrintMaterialsToBuy(StockPiler.Planner.CollectVendorBuyJobs(), { dedupe = true }) == true
    end
    if StockPiler.NotifyProgressBlocked then
        return StockPiler.NotifyProgressBlocked(StockPiler.Planner.CollectProgressBlockers(plan)) == true
    end
    return false
end

function StockPiler.Planner.BuildGrowQueueFromRows(rows, demandTotals, allocById)
    local seedBuffer = StockPiler.Planner.GetSeedBufferMin()
    local queue = {}
    local catalogByMatKey = {}
    local plotCount = StockPiler.Planner.GetGrowPlotCount and StockPiler.Planner.GetGrowPlotCount()
        or StockPiler.Planner.GROW_PLOT_COUNT or 4

    for i = 1, #rows do
        local row = rows[i]
        local recipe = row.recipe
        local catalogEntry = row.entry
        if type(recipe) == "table" and type(recipe.materials) == "table" and type(catalogEntry) == "table" then
            for j = 1, #recipe.materials do
                local mat = recipe.materials[j]
                local key = MaterialKey(mat)
                if key ~= "" then
                    catalogByMatKey[key] = catalogEntry
                end
            end
        end
    end

    local function buildSeedQueueEntry(mat, catalogEntry, matDeficit)
        if type(mat) ~= "table" then
            return nil
        end
        local matHave = CountMaterial(mat)
        local seed = ResolveSeedForMaterial(mat, catalogEntry)
        if type(seed) ~= "table" then
            return nil
        end
        local seedKey = seed.nameNarrow or seed.match or ToNarrow(seed.name) or ""
        if seedKey == "" then
            return nil
        end
        local seedUid = tonumber(seed.uniqueID) or 0
        local plantUid = tonumber(mat.uniqueID) or tonumber(seed.plantUid) or 0
        if seedUid <= 0 and StockPiler.AutoGrow and StockPiler.AutoGrow.ResolveSeedUid then
            seedUid = StockPiler.AutoGrow.ResolveSeedUid({
                seedKey = seedKey,
                seedName = seed.name,
            })
        end
        local seedHave = 0
        if seedUid > 0 and StockPiler.AutoGrow and StockPiler.AutoGrow.GetEffectiveSeedCount then
            seedHave = tonumber(StockPiler.AutoGrow.GetEffectiveSeedCount(seedUid)) or 0
        end
        local plantable = StockPiler.Planner.ComputeSeedPlantable(seedHave, seedBuffer, matHave, tonumber(matDeficit) or 0)
        if plantable <= 0 then
            return nil
        end
        return {
            seedKey = seedKey,
            seedName = seed.name or L"",
            seedUid = seedUid,
            plantUid = plantUid,
            seedHave = seedHave,
            seedPlantable = plantable,
            seedBuffer = seedBuffer,
            needsSeedConversion = false,
            matHave = matHave,
            matNeed = tonumber(matDeficit) or 0,
            score = 0,
        }
    end

    if type(demandTotals) == "table" then
        for _, total in pairs(demandTotals) do
            if (total.totalDeficit or 0) > 0 and IsGrowableMaterial(total.mat) then
                local matKey = MaterialKey(total.mat)
                local catalogEntry = catalogByMatKey[matKey]
                local entry = buildSeedQueueEntry(total.mat, catalogEntry, total.totalDeficit)
                if entry and entry.needsSeedConversion then
                    queue[#queue + 1] = entry
                end
            end
        end
    end

    local sortedRows = {}
    for i = 1, #rows do
        if (rows[i].potionDeficit or 0) > 0 then
            sortedRows[#sortedRows + 1] = rows[i]
        end
    end
    table.sort(sortedRows, function(a, b)
        if (a.growRank or 9999) ~= (b.growRank or 9999) then
            return (a.growRank or 9999) < (b.growRank or 9999)
        end
        return ToNarrow(a.name) < ToNarrow(b.name)
    end)

    local function materialDistance(mat)
        local key = MaterialKey(mat)
        if key == "" or type(demandTotals) ~= "table" then
            return 0
        end
        local total = demandTotals[key]
        if type(total) == "table" then
            return tonumber(total.totalDeficit) or 0
        end
        return 0
    end

    local function buildBrewSlots(recipe)
        if StockPiler.Inventory and StockPiler.Inventory.BuildGrowableBrewSlots then
            return StockPiler.Inventory.BuildGrowableBrewSlots(recipe)
        end
        return {}
    end

    local function buildSortedRecipeList(recipe, catalogEntry)
        local list = {}
        local seen = {}
        if type(recipe) ~= "table" or type(recipe.materials) ~= "table" then
            return list
        end
        for j = 1, #recipe.materials do
            local mat = recipe.materials[j]
            if IsGrowableMaterial(mat) then
                local key = MaterialKey(mat)
                if key ~= "" and seen[key] ~= true then
                    seen[key] = true
                    local totalNeed = 0
                    if type(demandTotals) == "table" and type(demandTotals[key]) == "table" then
                        totalNeed = tonumber(demandTotals[key].totalNeed) or 0
                    end
                    list[#list + 1] = {
                        mat = mat,
                        key = key,
                        distance = materialDistance(mat),
                        totalNeed = totalNeed,
                        catalogEntry = catalogEntry,
                    }
                end
            end
        end
        table.sort(list, function(a, b)
            if a.distance ~= b.distance then
                return a.distance > b.distance
            end
            if a.totalNeed ~= b.totalNeed then
                return a.totalNeed > b.totalNeed
            end
            return a.key < b.key
        end)
        return list
    end

    local primaryRow = sortedRows[1]
    if type(primaryRow) == "table" and type(primaryRow.recipe) == "table" then
        local recipe = primaryRow.recipe
        local catalogEntry = primaryRow.entry
        local brewSlots = buildBrewSlots(recipe)
        local recipeList = buildSortedRecipeList(recipe, catalogEntry)
        local topReplacement = recipeList[1]

        local plotMats = {}
        for plotNum = 1, plotCount do
            plotMats[plotNum] = brewSlots[plotNum]
        end

        for plotNum = 1, plotCount do
            local mat = plotMats[plotNum]
            if type(mat) == "table" and materialDistance(mat) < 1 and type(topReplacement) == "table" then
                mat = topReplacement.mat
            end
            plotMats[plotNum] = mat
        end

        for plotNum = 1, plotCount do
            local mat = plotMats[plotNum]
            if type(mat) == "table" and materialDistance(mat) >= 1 then
                local matKey = MaterialKey(mat)
                local entryCatalog = catalogByMatKey[matKey] or catalogEntry
                local entry = buildSeedQueueEntry(mat, entryCatalog, materialDistance(mat))
                if entry ~= nil and not entry.needsSeedConversion then
                    entry.plotNum = plotNum
                    queue[plotNum] = entry
                end
            end
        end
    end

    return queue
end
