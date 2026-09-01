----------------------------------------------------------------
-- StockPilerCharacter - per-character settings on shared profiles
-- Watches / AutoGrow / AutoBuy live in Settings.characters[characterName].
-- Shared knowledge (recipes, harvest/refine maps) lives in StockPiler.Account.
----------------------------------------------------------------

local function ClampInt(n, lo, hi, default)
    n = tonumber(n)
    if n == nil then
        return default
    end
    n = math.floor(n)
    if n < lo then
        return lo
    end
    if n > hi then
        return hi
    end
    return n
end

StockPiler.DefaultCharacterSettings = {
    watches = {}, -- [potionRecipeKey] = { enabled, autoGrow, targetStock }  (legacy uid:N migrated on bind)
    autoGrowEnabled = false,
    autoGrowAdditives = false,
    autoBuyEnabled = false,
    autoBuyReserveGold = 10,
    autoBuyBudgetGold = 50,
    growSeedBufferMin = 4,
    brewMacroEnabled = true, -- one-click Brew hotbar (Ctrl-click toggles)
    brewRespectGrowReserve = true, -- strict: do not brew plants reserved for AutoGrow refine
}

function StockPiler.GetCharacterKey()
    if GameData and GameData.Player and GameData.Player.name then
        local name = GameData.Player.name
        if type(name) == "wstring" then
            local narrow = StockPiler.ToNarrow(name)
            if type(narrow) == "string" and narrow ~= "" then
                if string.len(narrow) >= 2 and string.sub(narrow, -2, -2) == "^" then
                    narrow = string.sub(narrow, 1, -3)
                end
                narrow = string.gsub(narrow, "^%s+", "")
                narrow = string.gsub(narrow, "%s+$", "")
                if narrow ~= "" then
                    return narrow
                end
            end
        end
    end
    return "_default"
end

function StockPiler.EnsureCharacterBucketShape(char)
    if type(char) ~= "table" then
        char = {}
    end
    for k, v in pairs(StockPiler.DefaultCharacterSettings) do
        if char[k] == nil then
            if type(v) == "table" then
                char[k] = {}
            else
                char[k] = v
            end
        end
    end
    if type(char.watches) ~= "table" then
        char.watches = {}
    end
    char.autoGrowEnabled = char.autoGrowEnabled == true
    char.autoGrowAdditives = char.autoGrowAdditives == true
    char.autoBuyEnabled = char.autoBuyEnabled == true
    char.brewMacroEnabled = char.brewMacroEnabled ~= false
    char.brewRespectGrowReserve = char.brewRespectGrowReserve ~= false
    char.autoBuyReserveGold = ClampInt(char.autoBuyReserveGold, 1, 99, 10)
    char.autoBuyBudgetGold = ClampInt(char.autoBuyBudgetGold, 1, 999, 50)
    char.growSeedBufferMin = ClampInt(char.growSeedBufferMin, 4, 20, 4)
    return char
end

local function DeepCopy(value)
    if type(value) ~= "table" then
        return value
    end
    local copy = {}
    for k, v in pairs(value) do
        if type(v) == "table" then
            local inner = {}
            for ik, iv in pairs(v) do
                inner[ik] = iv
            end
            copy[k] = inner
        else
            copy[k] = v
        end
    end
    return copy
end

function StockPiler.PersistActiveCharacterSettings(s)
    -- Mid-bind re-entry (e.g. MigrateWatches → EnsureSettings) must not write:
    -- session aliases may still be nil and would wipe the character bucket to defaults.
    if StockPiler._bindingCharacter == true then
        return
    end
    local bucket = StockPiler._charBucket
    if type(s) ~= "table" or type(bucket) ~= "table" then
        return
    end
    -- Only copy aliases that are present. nil means "not bound yet", not "false".
    if s.autoGrowEnabled ~= nil then
        bucket.autoGrowEnabled = s.autoGrowEnabled == true
    end
    if s.autoGrowAdditives ~= nil then
        bucket.autoGrowAdditives = s.autoGrowAdditives == true
    end
    if s.autoBuyEnabled ~= nil then
        bucket.autoBuyEnabled = s.autoBuyEnabled == true
    end
    if s.brewMacroEnabled ~= nil then
        bucket.brewMacroEnabled = s.brewMacroEnabled ~= false
    end
    if s.brewRespectGrowReserve ~= nil then
        bucket.brewRespectGrowReserve = s.brewRespectGrowReserve ~= false
    end
    if s.autoBuyReserveGold ~= nil then
        bucket.autoBuyReserveGold = ClampInt(s.autoBuyReserveGold, 1, 99, 10)
    end
    if s.autoBuyBudgetGold ~= nil then
        bucket.autoBuyBudgetGold = ClampInt(s.autoBuyBudgetGold, 1, 999, 50)
    end
    if s.growSeedBufferMin ~= nil then
        bucket.growSeedBufferMin = ClampInt(s.growSeedBufferMin, 4, 20, 4)
    end
    if type(s.watches) == "table" then
        bucket.watches = s.watches
    end
    s._charBucket = nil
end

local function ApplyCharacterAliases(s, char)
    s.watches = char.watches
    s.autoGrowEnabled = char.autoGrowEnabled == true
    s.autoGrowAdditives = char.autoGrowAdditives == true
    s.autoBuyEnabled = char.autoBuyEnabled == true
    s.brewMacroEnabled = char.brewMacroEnabled ~= false
    s.brewRespectGrowReserve = char.brewRespectGrowReserve ~= false
    s.autoBuyReserveGold = ClampInt(char.autoBuyReserveGold, 1, 99, 10)
    s.autoBuyBudgetGold = ClampInt(char.autoBuyBudgetGold, 1, 999, 50)
    s.growSeedBufferMin = ClampInt(char.growSeedBufferMin, 4, 20, 4)
end

function StockPiler.BindActiveCharacterSettings(s)
    if type(s) ~= "table" then
        return nil
    end
    -- Tab OnInitialize calls EnsureSettings before trade skills exist.
    -- EnforceProfessionGates used to call EnsureSettings again (C stack overflow).
    if StockPiler._bindingCharacter == true then
        return StockPiler._charBucket
    end
    StockPiler._bindingCharacter = true

    local prevEnabled = s.autoGrowEnabled == true
    local prevKey = s._characterKey
    local key = StockPiler.GetCharacterKey()
    local keyChanged = prevKey ~= nil and prevKey ~= key
    if keyChanged then
        -- Flush the previous character's aliases into its bucket before switching.
        local prevBucket = StockPiler._charBucket
        if type(prevBucket) == "table" then
            StockPiler._bindingCharacter = false
            StockPiler.PersistActiveCharacterSettings(s)
            StockPiler._bindingCharacter = true
        end
    end

    if type(s.characters) ~= "table" then
        s.characters = {}
    end
    if type(s.characters[key]) ~= "table" then
        s.characters[key] = DeepCopy(StockPiler.DefaultCharacterSettings)
    end

    local char = StockPiler.EnsureCharacterBucketShape(s.characters[key])
    s._characterKey = key
    StockPiler._charBucket = char
    s._charBucket = nil
    -- Apply aliases BEFORE MigrateWatches / anything that re-enters EnsureSettings.
    -- Watches are a shared table (mutations stick); toggles are scalars and were
    -- previously wiped when Persist ran mid-bind with nil aliases.
    ApplyCharacterAliases(s, char)
    if StockPiler.RecipeSpec and StockPiler.RecipeSpec.MigrateWatchesToPotionRecipeKeys then
        StockPiler.RecipeSpec.MigrateWatchesToPotionRecipeKeys()
    end
    local newEnabled = s.autoGrowEnabled == true
    if keyChanged or prevEnabled ~= newEnabled then
        if StockPiler.Planner and StockPiler.Planner.InvalidatePlanCache then
            StockPiler.Planner.InvalidatePlanCache()
        end
        if StockPiler.AutoGrow and StockPiler.AutoGrow.InvalidatePlantQueue then
            StockPiler.AutoGrow.InvalidatePlantQueue()
        end
    end
    -- Defer gates + AutoGrow enable until AutoGrow.Initialize. CreateWindow
    -- OnInitialize runs first and must not BuildPlan / GetCultivationInfo.
    if StockPiler.AutoGrow and StockPiler.AutoGrow._initialized == true then
        if StockPiler.Inventory and StockPiler.Inventory.EnforceProfessionGates then
            StockPiler.Inventory.EnforceProfessionGates()
        end
        if StockPiler.AutoGrow.SyncEnabledFromSettings then
            StockPiler.AutoGrow.SyncEnabledFromSettings(prevEnabled, newEnabled, keyChanged)
        end
    end
    StockPiler._bindingCharacter = false
    return char
end

function StockPiler.OnCharacterSettingsReload()
    local prevKey = type(StockPiler.Settings) == "table" and StockPiler.Settings._characterKey or nil
    local prevEnabled = type(StockPiler.Settings) == "table" and StockPiler.Settings.autoGrowEnabled == true
    StockPiler.EnsureSettings()
    if StockPiler.Inventory and StockPiler.Inventory.RefreshAllIfNeeded then
        StockPiler.Inventory.RefreshAllIfNeeded({ force = true })
    end
    StockPiler._bagCountsStale = false
    if StockPiler.Planner and StockPiler.Planner.InvalidatePlanCache then
        StockPiler.Planner.InvalidatePlanCache()
    end
    if StockPiler.ScheduleBagWork then
        StockPiler.ScheduleBagWork(false)
    end
    if StockPiler.SeedMap and StockPiler.SeedMap.ApplyPendingMapReset then
        StockPiler.SeedMap.ApplyPendingMapReset()
    end
    if StockPiler.RecipeSpec and StockPiler.RecipeSpec.RepairDuplicateRecipeFingerprints then
        StockPiler.RecipeSpec.RepairDuplicateRecipeFingerprints()
    end
    if StockPiler.RecipeSpec and StockPiler.RecipeSpec.RepairIncompleteMainSpecs then
        StockPiler.RecipeSpec.RepairIncompleteMainSpecs()
    end
    local newKey = type(StockPiler.Settings) == "table" and StockPiler.Settings._characterKey or nil
    local newEnabled = type(StockPiler.Settings) == "table" and StockPiler.Settings.autoGrowEnabled == true
    if prevKey ~= newKey or prevEnabled ~= newEnabled then
        if DoesWindowExist("StockPilerWindow") and WindowGetShowing("StockPilerWindow") then
            if StockPilerWindow and StockPilerWindow.RefreshActiveTab then
                StockPilerWindow.RefreshActiveTab()
            end
        end
        if StockPiler.D then
            StockPiler.D("Character settings bound key=" .. tostring(newKey)
                .. " autoGrow=" .. tostring(newEnabled))
        end
    end
end
