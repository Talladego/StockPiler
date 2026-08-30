----------------------------------------------------------------
-- StockPilerCharacter - per-character settings on shared profiles
----------------------------------------------------------------

StockPiler.DefaultCharacterSettings = {
    watches = {}, -- [potionKey] = { enabled, autoGrow, targetStock }
    autoGrowEnabled = false,
    autoGrowAdditives = false,
}

function StockPiler.GetCharacterKey()
    if GameData and GameData.Player and GameData.Player.name then
        local name = GameData.Player.name
        if type(name) == "wstring" then
            local ok, narrow = pcall(WStringToString, name)
            if ok and type(narrow) == "string" and narrow ~= "" then
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
        for k, v in pairs(StockPiler.DefaultCharacterSettings) do
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
    if char.autoGrowEnabled == nil then
        char.autoGrowEnabled = false
    end
    if char.autoGrowAdditives == nil then
        char.autoGrowAdditives = false
    end
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

function StockPiler.MigrateCharacterSettings(s)
    if type(s) ~= "table" then
        return
    end
    if s.charactersVersion == 1 then
        return
    end

    if type(s.characters) ~= "table" then
        s.characters = {}
    end

    local key = StockPiler.GetCharacterKey()
    if type(s.characters[key]) ~= "table" then
        s.characters[key] = DeepCopy(StockPiler.DefaultCharacterSettings)
    end
    local char = StockPiler.EnsureCharacterBucketShape(s.characters[key])

    if type(s.watches) == "table" and next(s.watches) ~= nil then
        for pk, watch in pairs(s.watches) do
            if char.watches[pk] == nil and type(watch) == "table" then
                char.watches[pk] = DeepCopy(watch)
            end
        end
    end
    if s.autoGrowEnabled ~= nil and char.autoGrowEnabled == false then
        char.autoGrowEnabled = s.autoGrowEnabled == true
    end

    s.charactersVersion = 1
    if StockPiler.D then
        StockPiler.D("Migrated planner settings to per-character bucket key=" .. tostring(key))
    end
end

function StockPiler.PersistActiveCharacterSettings(s)
    local bucket = StockPiler._charBucket
    if type(s) ~= "table" or type(bucket) ~= "table" then
        return
    end
    bucket.autoGrowEnabled = s.autoGrowEnabled == true
    bucket.autoGrowAdditives = s.autoGrowAdditives == true
    if type(s.watches) == "table" then
        bucket.watches = s.watches
    end
    s._charBucket = nil
end

function StockPiler.BindActiveCharacterSettings(s)
    if type(s) ~= "table" then
        return nil
    end

    StockPiler.MigrateCharacterSettings(s)

    local prevEnabled = s.autoGrowEnabled == true
    local prevKey = s._characterKey
    local key = StockPiler.GetCharacterKey()
    local keyChanged = prevKey ~= nil and prevKey ~= key
    if keyChanged then
        StockPiler.PersistActiveCharacterSettings(s)
    end

    if type(s.characters) ~= "table" then
        s.characters = {}
    end
    if type(s.characters[key]) ~= "table" then
        local copy = DeepCopy(StockPiler.DefaultCharacterSettings)
        s.characters[key] = copy
    end

    local char = StockPiler.EnsureCharacterBucketShape(s.characters[key])
    s._characterKey = key
    StockPiler._charBucket = char
    s._charBucket = nil
    s.watches = char.watches
    s.autoGrowEnabled = char.autoGrowEnabled == true
    s.autoGrowAdditives = char.autoGrowAdditives == true
    if StockPiler.Inventory and StockPiler.Inventory.EnforceProfessionGates then
        pcall(StockPiler.Inventory.EnforceProfessionGates)
    end
    local newEnabled = s.autoGrowEnabled == true
    if keyChanged or prevEnabled ~= newEnabled then
        if StockPiler.Planner and StockPiler.Planner.InvalidatePlanCache then
            pcall(StockPiler.Planner.InvalidatePlanCache)
        end
        if StockPiler.AutoGrow and StockPiler.AutoGrow.InvalidatePlantQueue then
            pcall(StockPiler.AutoGrow.InvalidatePlantQueue)
        end
    end
    if StockPiler.AutoGrow and StockPiler.AutoGrow.SyncEnabledFromSettings then
        pcall(StockPiler.AutoGrow.SyncEnabledFromSettings, prevEnabled, newEnabled, keyChanged)
    end
    return char
end

function StockPiler.OnCharacterSettingsReload()
    local prevKey = type(StockPiler.Settings) == "table" and StockPiler.Settings._characterKey or nil
    local prevEnabled = type(StockPiler.Settings) == "table" and StockPiler.Settings.autoGrowEnabled == true
    StockPiler.EnsureSettings()
    if StockPiler.SeedMap and StockPiler.SeedMap.ApplyPendingMapReset then
        pcall(StockPiler.SeedMap.ApplyPendingMapReset)
    end
    if StockPiler.RecipeSpec and StockPiler.RecipeSpec.RepairIncompleteMainSpecs then
        pcall(StockPiler.RecipeSpec.RepairIncompleteMainSpecs)
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
