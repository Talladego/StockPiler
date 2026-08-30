----------------------------------------------------------------
-- StockPiler — core
----------------------------------------------------------------

StockPiler = StockPiler or {}
StockPiler.Version = L"0.8.75"
-- Writes to user/logs/uilog.log via engine d(). Toggle with /stockpiler debug
StockPiler.DebugEnabled = false

StockPiler.DefaultSettings = {
    potionNameFilter = "",
    potionEffectFilter = "", -- effectKey or "" for all
    potionKnownRecipeOnly = false,
    potionSortColumn = "rank", -- watch | name | effect | rank | buff | duration | have
    potionSortAscending = true,
    -- Slim identity records only (no itemData). Session tooltips live in Inventory._learned*.
    observedPotions = {}, -- [uidKey] = { uniqueID, iconNum, name, nameNarrow, source }
    observedMats = {}, -- [uidKey] = Apothecary + Cultivation mats only
    settingsVersion = 8,
    learnedRecipeSpecs = {}, -- [recipeSpecKey] = LearnedRecipeSpec
    knownPotions = {}, -- [potionKey] = KnownPotion
    watches = {}, -- [potionKey] = { enabled, autoGrow, targetStock } — aliased from characters[name]
    seedMap = {}, -- [seedSpecKey] = { plantSpecKey, plantSpec, seedUidCache, plantUidCache, source }
    growProducers = {}, -- [plantSpecKey] = { seedSpecKeys = {}, sources = {} }
    harvestByproducts = {}, -- [specKey] = { source=, uniqueID= } convert extras (e.g. Arboreal Resin)
    learnedAdditives = {}, -- [uidKey] = slim Soil/Watering/Nutrient stats
    characters = {}, -- [characterName] = { watches, autoGrowEnabled, autoGrowAdditives }
    charactersVersion = 1,
    growSeedBufferMin = 4, -- convert plants up to this many seeds; planting uses any remaining seed
    learnedSeedMap = {}, -- [plantUidKey] = { seedUid=, source= }
    statusMessages = true, -- CustomUI-style chat notifications
    blockInvalidApothecaryBrew = true, -- block Apothecary Brew when recipe is unstable or incomplete
}

local function DeepCopy(value)
    if type(value) ~= "table" then
        return value
    end
    local copy = {}
    for k, v in pairs(value) do
        copy[k] = DeepCopy(v)
    end
    return copy
end

--- Debug dump to uilog.log (engine d()). Gated by /stockpiler debug.
function StockPiler.D(msg)
    if StockPiler.DebugEnabled ~= true then
        return
    end
    StockPiler._EmitLog("StockPiler| " .. StockPiler._LogText(msg))
end

--- Lifecycle logging (brew learn, spec repair). Same gate as /stp debug.
function StockPiler.Trace(msg)
    if StockPiler.DebugEnabled ~= true then
        return
    end
    StockPiler._EmitLog("StockPiler| " .. StockPiler._LogText(msg))
end

function StockPiler._LogText(msg)
    local text = msg
    if type(text) == "wstring" then
        local ok, s = pcall(WStringToString, text)
        if ok and s then
            text = s
        else
            text = "wstring"
        end
    elseif type(text) ~= "string" then
        text = tostring(text)
    end
    return text
end

function StockPiler._EmitLog(text)
    if type(d) == "function" then
        d(text)
    end
end

function StockPiler.DumpTableKeys(label, tbl, maxKeys)
    if StockPiler.DebugEnabled ~= true or type(tbl) ~= "table" then
        return
    end
    maxKeys = maxKeys or 40
    local keys = {}
    for k, v in pairs(tbl) do
        keys[#keys + 1] = tostring(k) .. "=" .. type(v)
        if #keys >= maxKeys then
            break
        end
    end
    StockPiler.D((label or "table") .. " keys: " .. table.concat(keys, ", "))
end

local SETTINGS_V8_DROP = {
    "mins", "watchlist", "growOrder", "growPriorities",
    "recipeFilter", "recipeSortAscending", "potionFilter",
    "matFilter", "matNameFilter", "matTypeFilter", "matSortColumn", "matSortAscending",
    "learnedRecipes", "itemDataCache", "iconCache", "matDataCache", "matIconCache",
    "recipeKeyVersion", "growOrderVersion", "catalogCacheVersion", "iconCacheVersion",
    "_charBucket",
}

local function KnownPotionUidSet(s)
    local uids = {}
    if type(s) ~= "table" or type(s.knownPotions) ~= "table" then
        return uids
    end
    for key, potion in pairs(s.knownPotions) do
        local uid = 0
        if type(potion) == "table" then
            uid = tonumber(potion.outputUid) or 0
        end
        if uid <= 0 and type(key) == "string" then
            uid = tonumber(string.match(key, "^uid:(%d+)$")) or 0
        end
        if uid > 0 then
            uids[uid] = true
        end
    end
    return uids
end

local function SlimObservedTable(tbl, pruneUnskilled, knownUids)
    if type(tbl) ~= "table" then
        return 0, 0
    end
    local slimmed = 0
    local dropped = 0
    local kept = {}
    for key, obs in pairs(tbl) do
        if type(obs) == "table" then
            local uid = tonumber(obs.uniqueID) or 0
            local skill = tonumber(obs.craftingSkillRequirement) or 0
            if pruneUnskilled and skill <= 0 and (knownUids == nil or knownUids[uid] ~= true) then
                dropped = dropped + 1
            else
                if obs.itemData ~= nil then
                    obs.itemData = nil
                    slimmed = slimmed + 1
                end
                kept[key] = obs
            end
        end
    end
    for key in pairs(tbl) do
        tbl[key] = nil
    end
    for key, obs in pairs(kept) do
        tbl[key] = obs
    end
    return slimmed, dropped
end

local function CleanCharacterBuckets(s)
    if type(s) ~= "table" or type(s.characters) ~= "table" then
        return
    end
    for _, char in pairs(s.characters) do
        if type(char) == "table" then
            for key in pairs(char) do
                if key ~= "watches" and key ~= "autoGrowEnabled" and key ~= "autoGrowAdditives" then
                    char[key] = nil
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
        end
    end
end

-- v8: drop v5 planner keys, UID recipe store, full itemData caches; slim observed tables.
function StockPiler.ApplySettingsV8(s)
    if type(s) ~= "table" then
        return false
    end
    s._charBucket = nil
    if (tonumber(s.settingsVersion) or 0) >= 8 then
        return false
    end
    for i = 1, #SETTINGS_V8_DROP do
        s[SETTINGS_V8_DROP[i]] = nil
    end
    local knownUids = KnownPotionUidSet(s)
    SlimObservedTable(s.observedPotions, true, knownUids)
    SlimObservedTable(s.observedMats, false, nil)
    CleanCharacterBuckets(s)
    s.settingsVersion = 8
    s._charBucket = nil
    return true
end

-- Safe to call during CreateWindow OnInitialize (before StockPiler.Initialize).
function StockPiler.EnsureSettings()
    if type(StockPiler.Settings) ~= "table" then
        StockPiler.Settings = DeepCopy(StockPiler.DefaultSettings)
    end
    local s = StockPiler.Settings
    if StockPiler.BindActiveCharacterSettings then
        StockPiler.BindActiveCharacterSettings(s)
    end
    if type(s.characters) ~= "table" then
        s.characters = {}
    end
    if s.potionNameFilter == nil then
        s.potionNameFilter = ""
    end
    if s.potionEffectFilter == nil then
        s.potionEffectFilter = ""
    end
    if s.potionKnownRecipeOnly == nil then
        s.potionKnownRecipeOnly = false
    end
    if s.potionSortColumn == nil then
        s.potionSortColumn = "rank"
    end
    if s.potionSortAscending == nil then
        s.potionSortAscending = true
    end
    if s.potionSortColumn == "recipe" then
        s.potionSortColumn = "rank"
    end
    if type(s.observedPotions) ~= "table" then
        s.observedPotions = {}
    end
    if type(s.observedMats) ~= "table" then
        s.observedMats = {}
    end
    if s.settingsVersion == nil then
        s.settingsVersion = 1
    end
    if type(s.learnedRecipeSpecs) ~= "table" then
        s.learnedRecipeSpecs = {}
    end
    if type(s.knownPotions) ~= "table" then
        s.knownPotions = {}
    end
    if type(s.watches) ~= "table" then
        s.watches = {}
    end
    if type(s.seedMap) ~= "table" then
        s.seedMap = {}
    end
    if type(s.growProducers) ~= "table" then
        s.growProducers = {}
    end
    if type(s.harvestByproducts) ~= "table" then
        s.harvestByproducts = {}
    end
    if s.settingsVersion < 6 then
        s.learnedRecipeSpecs = {}
        s.knownPotions = {}
        s.watches = {}
        s.seedMap = {}
        s.growProducers = {}
        s.settingsVersion = 6
        if StockPiler.Print then
            pcall(StockPiler.Print, L"v0.8: spec-based recipes. Brew potions to re-learn; watches reset.")
        end
    end
    if s.settingsVersion < 7 then
        s.seedMap = {}
        s.growProducers = {}
        s.settingsVersion = 7
        s._seedMapResetPending = true
        if StockPiler.Print then
            pcall(StockPiler.Print, L"v0.8.5: seed/grow maps reset; CVT bootstrap on load.")
        end
    end
    if s.autoGrowEnabled == nil then
        s.autoGrowEnabled = false
    end
    if s.autoGrowAdditives == nil then
        s.autoGrowAdditives = false
    end
    if type(s.learnedAdditives) ~= "table" then
        s.learnedAdditives = {}
    end
    if s.growSeedBufferMin == nil then
        s.growSeedBufferMin = 4
    else
        local buf = tonumber(s.growSeedBufferMin) or 4
        if buf < 4 then
            s.growSeedBufferMin = 4
        end
    end
    if type(s.learnedSeedMap) ~= "table" then
        s.learnedSeedMap = {}
    end
    if s.statusMessages == nil then
        s.statusMessages = true
    end
    if s.blockInvalidApothecaryBrew == nil then
        s.blockInvalidApothecaryBrew = true
    end
    -- 0.1.16: keep only Apothecary + Cultivation mats (drop Talisman / other crafting)
    if s.matScopeVersion ~= 1 then
        local kept = {}
        local dropped = 0
        for key, obs in pairs(s.observedMats) do
            local inScope = false
            if StockPiler.Inventory and StockPiler.Inventory.IsObservedMatInScope then
                inScope = StockPiler.Inventory.IsObservedMatInScope(obs)
            elseif type(obs) == "table" and tonumber(obs.cultivationType) and tonumber(obs.cultivationType) ~= 0 then
                inScope = true
            end
            if inScope then
                kept[key] = obs
            else
                dropped = dropped + 1
            end
        end
        s.observedMats = kept
        s.matScopeVersion = 1
        if StockPiler.D then
            StockPiler.D("Pruned observedMats (Apo/Cult only), dropped=" .. tostring(dropped))
        end
    end

    if StockPiler.ApplySettingsV8(s) and StockPiler.Print then
        pcall(StockPiler.Print, L"v0.8.31: cleared stale saved data (watches and recipes kept).")
    end

    -- Hydrate session tooltip copies from leftover itemData (pre-v8 profiles / mid-session).
    if StockPiler.Inventory then
        if type(StockPiler.Inventory._learnedItemData) ~= "table" then
            StockPiler.Inventory._learnedItemData = {}
        end
        if type(StockPiler.Inventory._learnedMatData) ~= "table" then
            StockPiler.Inventory._learnedMatData = {}
        end
        if type(s.observedPotions) == "table" then
            for key, obs in pairs(s.observedPotions) do
                if type(obs) == "table" and type(obs.itemData) == "table"
                    and StockPiler.Inventory._learnedItemData[key] == nil
                then
                    StockPiler.Inventory._learnedItemData[key] = obs.itemData
                end
            end
        end
        if type(s.observedMats) == "table" then
            for key, obs in pairs(s.observedMats) do
                if type(obs) == "table" and type(obs.itemData) == "table"
                    and StockPiler.Inventory._learnedMatData[key] == nil
                then
                    StockPiler.Inventory._learnedMatData[key] = obs.itemData
                end
            end
        end
    end

    s._charBucket = nil
    StockPiler.PersistActiveCharacterSettings(s)
    return s
end

-- StockPiler.Print and StockPiler.Notify live in StockPilerNotify.lua

function StockPiler.Toggle()
    if DoesWindowExist("StockPilerWindow") then
        WindowUtils.ToggleShowing("StockPilerWindow")
    end
end

function StockPiler.Show(tabId)
    if not DoesWindowExist("StockPilerWindow") then
        return
    end
    WindowSetShowing("StockPilerWindow", true)
    if tabId and StockPilerWindow and StockPilerWindow.SelectTab then
        StockPilerWindow.SelectTab(tabId)
    end
end

function StockPiler.HandleSlash(input)
    local args = input
    if type(args) == "wstring" then
        args = WStringToString(args) or ""
    elseif type(args) ~= "string" then
        args = ""
    end
    args = string.lower(string.gsub(args, "^%s+", ""))

    if args == "" or args == "toggle" or args == "show" then
        StockPiler.Toggle()
        return
    end
    if args == "potions" or args == "p" then
        StockPiler.Show(1)
        return
    end
    if args == "recipes" or args == "r" or args == "recipe" then
        StockPiler.Show(2)
        return
    end
    if args == "watch" or args == "autogrow" or args == "grow" or args == "ag" then
        StockPiler.Show(2)
        return
    end
    if args == "help" then
        StockPiler.Print(L"/stockpiler (or /stp) - open  |  potions|watch  |  spec <uid>  |  growplan|growtrace  |  resetmaps  |  scan  |  debug")
        return
    end
    if args == "growplan" or args == "growdump" then
        if StockPiler.AutoGrow and StockPiler.AutoGrow.DumpGrowPlan then
            StockPiler.AutoGrow.DumpGrowPlan({ force = true })
            StockPiler.Print(L"Grow plan trace written to uilog.log")
        end
        return
    end
    if args == "growtrace" then
        if StockPiler.AutoGrow then
            StockPiler.AutoGrow.TraceEnabled = not (StockPiler.AutoGrow.TraceEnabled == true)
            local state = (StockPiler.AutoGrow.TraceEnabled == true) and L"ON" or L"OFF"
            StockPiler.Print(L"AutoGrow decision trace: " .. state .. L" (/stp debug also writes grow traces)")
            if StockPiler.AutoGrow.TraceEnabled == true and StockPiler.AutoGrow.DumpGrowPlan then
                StockPiler.AutoGrow.DumpGrowPlan({ force = true })
            end
        end
        return
    end
    if args == "resetmaps" or args == "resetseedmap" or args == "clearmaps" then
        if StockPiler.SeedMap and StockPiler.SeedMap.ResetSpecMaps then
            local bootstrapped, repaired = StockPiler.SeedMap.ResetSpecMaps()
            StockPiler.Print(L"Seed/grow maps reset. CVT=" .. towstring(tostring(bootstrapped or 0))
                .. L" learned=" .. towstring(tostring(repaired or 0)))
        end
        return
    end
    local specUid = string.match(args, "^spec%s+(%d+)$")
    if specUid and StockPiler.MaterialSpec and StockPiler.MaterialSpec.FromItemData then
        local id = tonumber(specUid)
        local itemData = nil
        if type(GetDatabaseItemData) == "function" then
            local ok, data = pcall(GetDatabaseItemData, id)
            if ok then
                itemData = data
            end
        end
        if type(itemData) ~= "table" and StockPiler.Inventory then
            local _, sample = StockPiler.Inventory.CountByUniqueId(id)
            itemData = sample
        end
        if type(itemData) == "table" then
            local spec = StockPiler.MaterialSpec.FromItemData(itemData)
            local key = StockPiler.MaterialSpec.Key(spec)
            local fx = spec.effectId and (L" fx=" .. towstring(tostring(spec.effectId))) or L""
            local inc = spec.incomplete and L" incomplete" or L""
            StockPiler.Print(StockPiler.MaterialSpec.Label(spec) .. fx .. inc .. L" key=" .. towstring(key))
            StockPiler.D("spec uid=" .. tostring(id) .. " key=" .. key .. " effectId=" .. tostring(spec.effectId))
        else
            StockPiler.Print(L"No item data for " .. towstring(specUid))
        end
        return
    end
    if args == "debug" then
        StockPiler.DebugEnabled = not (StockPiler.DebugEnabled == true)
        local state = (StockPiler.DebugEnabled == true) and L"ON" or L"OFF"
        StockPiler.Print(L"uilog d() debug: " .. state)
        StockPiler.D("debug toggled -> " .. ((StockPiler.DebugEnabled == true) and "ON" or "OFF"))
        return
    end
    if args == "scan" or args == "debugscan" then
        StockPiler.DebugEnabled = true
        if StockPiler.Inventory and StockPiler.Inventory.DebugScan then
            StockPiler.Inventory.DebugScan()
        end
        StockPiler.Print(L"Scan dumped to chat + uilog.log (d).")
        return
    end
    if args == "notify" or args == "messages" then
        local s = StockPiler.EnsureSettings()
        s.statusMessages = not (s.statusMessages ~= false)
        local state = (s.statusMessages ~= false) and L"ON" or L"OFF"
        StockPiler.Print(L"Status messages: " .. state)
        return
    end
    -- /stockpiler db <uniqueID>  -- test GetDatabaseItemData (chat item-link path)
    local dbId = string.match(args, "^db%s+(%d+)$")
    if dbId then
        StockPiler.DebugEnabled = true
        local id = tonumber(dbId)
        if type(GetDatabaseItemData) ~= "function" then
            StockPiler.Print(L"GetDatabaseItemData missing")
            StockPiler.D("GetDatabaseItemData type=" .. type(GetDatabaseItemData))
            return
        end
        local ok, data = pcall(GetDatabaseItemData, id)
        StockPiler.D("dbtest id=" .. tostring(id) .. " ok=" .. tostring(ok)
            .. " type=" .. type(data)
            .. (ok and type(data) == "table"
                and (" uid=" .. tostring(data.uniqueID) .. " icon=" .. tostring(data.iconNum)
                    .. " nameType=" .. type(data.name))
                or (" err=" .. tostring(data))))
        if ok and type(data) == "table" and type(Tooltips.CreateItemTooltip) == "function" then
            StockPiler.Print(L"DB ok for " .. towstring(tostring(id)) .. L" - showing tooltip")
            pcall(Tooltips.CreateItemTooltip, data, "Root", Tooltips.ANCHOR_CURSOR, true)
        else
            StockPiler.Print(L"DB miss/fail for " .. towstring(tostring(id)) .. L" (see uilog)")
        end
        return
    end
    StockPiler.Toggle()
end

local function RegisterSlash()
    if LibSlash and LibSlash.RegisterSlashCmd then
        -- /sp is reserved (Scenario Chat) — use /stockpiler or /stp
        LibSlash.RegisterSlashCmd("stockpiler", StockPiler.HandleSlash)
        LibSlash.RegisterSlashCmd("stp", StockPiler.HandleSlash)
        return true
    end
    return false
end

local m_tooltipHooked = false

local function HookItemTooltips()
    if m_tooltipHooked then
        return
    end
    if type(Tooltips) ~= "table" or type(Tooltips.CreateItemTooltip) ~= "function" then
        return
    end
    local original = Tooltips.CreateItemTooltip
    Tooltips.CreateItemTooltip = function(itemData, ...)
        if StockPiler.Inventory and StockPiler.Inventory.LearnFromItemData then
            pcall(StockPiler.Inventory.LearnFromItemData, itemData, "tooltip")
        end
        return original(itemData, ...)
    end
    m_tooltipHooked = true
end

local m_invRefreshPending = false
StockPiler._deferInvLearn = false
StockPiler._deferUiRefresh = false

local function RefreshUiIfOpen()
    if DoesWindowExist("StockPilerWindow") and WindowGetShowing("StockPilerWindow") then
        if StockPilerWindow and StockPilerWindow.RefreshActiveTab then
            StockPilerWindow.RefreshActiveTab()
        end
    end
end

function StockPiler.OnInventoryUpdated()
    if StockPiler.EnsureRefinementHook then
        StockPiler.EnsureRefinementHook()
    end
    if StockPiler.SeedMap and StockPiler.SeedMap.MaybeCompletePendingRefine then
        local refineResult = StockPiler.SeedMap.MaybeCompletePendingRefine()
        if type(refineResult) == "table" then
            if StockPiler.AutoGrow and StockPiler.AutoGrow.OnRefineComplete then
                pcall(StockPiler.AutoGrow.OnRefineComplete, refineResult.plantUid, refineResult.seedUid)
            end
            if StockPiler.SeedMap.RefreshHarvestWatchAfterBagChange then
                pcall(StockPiler.SeedMap.RefreshHarvestWatchAfterBagChange)
            end
            RefreshUiIfOpen()
        elseif StockPiler.AutoGrow then
            StockPiler.AutoGrow._autoRefinePending = nil
        end
    end
    if StockPiler.SeedMap and StockPiler.SeedMap.MaybeCompletePendingHarvest then
        pcall(StockPiler.SeedMap.MaybeCompletePendingHarvest)
    end
    if StockPiler.Inventory and StockPiler.Inventory.MaybeCompletePendingCraftFromInventory then
        local learned = StockPiler.Inventory.MaybeCompletePendingCraftFromInventory()
        if learned then
            RefreshUiIfOpen()
        end
    end
    if StockPiler.Inventory and StockPiler.Inventory.InvalidateSnapshot then
        StockPiler.Inventory.InvalidateSnapshot()
    end
    local suppress = StockPiler.AutoGrow
        and tonumber(StockPiler.AutoGrow._suppressInvTicks) and StockPiler.AutoGrow._suppressInvTicks > 0
    if StockPiler.AutoGrow and StockPiler.AutoGrow.InvalidatePlantQueue then
        pcall(StockPiler.AutoGrow.InvalidatePlantQueue)
    end
    -- Bags changed (brew, harvest, vendor). Empty plots that never left Empty
    -- never get _wantFill from OnPlotUpdated — mark them so AutoGrow plants.
    -- Skip while we just planted/applied; those ticks set _suppressInvTicks.
    if not suppress
        and StockPiler.AutoGrow
        and StockPiler.AutoGrow.IsEnabled
        and StockPiler.AutoGrow.IsEnabled()
        and StockPiler.AutoGrow.MarkAllPlotsWantFill
    then
        pcall(StockPiler.AutoGrow.MarkAllPlotsWantFill)
    end
    if not suppress then
        StockPiler._deferInvLearn = true
    end
    if StockPiler.AutoGrow and StockPiler.AutoGrow.OnCraftingSlotUpdated then
        StockPiler.AutoGrow.OnCraftingSlotUpdated()
    end
    if StockPiler.Brew and StockPiler.Brew.OnCraftingSlotUpdated then
        pcall(StockPiler.Brew.OnCraftingSlotUpdated)
    end
    if not DoesWindowExist("StockPilerWindow") or not WindowGetShowing("StockPilerWindow") then
        return
    end
    StockPiler._deferUiRefresh = true
end

function StockPiler.ProcessDeferredInventoryWork()
    local bagsChanged = StockPiler._deferInvLearn == true
    if StockPiler._deferInvLearn == true then
        StockPiler._deferInvLearn = false
        if StockPiler.Inventory and StockPiler.Inventory.LearnNewFromBags then
            pcall(StockPiler.Inventory.LearnNewFromBags, "bag-deferred")
        end
    end
    if bagsChanged and StockPiler.Brew and StockPiler.Brew.OnInventoryDeferred then
        pcall(StockPiler.Brew.OnInventoryDeferred)
    end
    if StockPiler._deferUiRefresh == true then
        StockPiler._deferUiRefresh = false
        if m_invRefreshPending then
            return
        end
        m_invRefreshPending = true
        if StockPilerWindow and StockPilerWindow.RefreshActiveTab then
            StockPilerWindow.RefreshActiveTab()
        end
        m_invRefreshPending = false
    end
end

function StockPiler.OnAuctionSearchResults(results)
    if StockPiler.Inventory and StockPiler.Inventory.LearnFromAuctionResults then
        StockPiler.Inventory.LearnFromAuctionResults(results)
    end
end

--- Guild vault open: learn icons/tooltips from vault blobs (Have stays bags-only).
function StockPiler.OnGuildVaultOpen(vaultDataTable)
    if type(vaultDataTable) ~= "table"
        and GuildVaultWindow
        and type(GuildVaultWindow.vaultDataTable) == "table"
    then
        vaultDataTable = GuildVaultWindow.vaultDataTable
    end
    local n = 0
    if StockPiler.Inventory and StockPiler.Inventory.LearnFromGuildVaultData then
        n = StockPiler.Inventory.LearnFromGuildVaultData(vaultDataTable, "guildvault-open")
    end
    if n > 0 then
        RefreshUiIfOpen()
    end
end

function StockPiler.OnGuildVaultItemsUpdated(vaultData)
    local n = 0
    if StockPiler.Inventory and StockPiler.Inventory.LearnFromGuildVaultData then
        n = StockPiler.Inventory.LearnFromGuildVaultData(vaultData, "guildvault-update")
    end
    -- Also re-read full UI cache if present (covers tabs not in the delta)
    if GuildVaultWindow and type(GuildVaultWindow.vaultDataTable) == "table"
        and StockPiler.Inventory and StockPiler.Inventory.LearnFromGuildVaultData
    then
        n = n + StockPiler.Inventory.LearnFromGuildVaultData(
            GuildVaultWindow.vaultDataTable,
            "guildvault-cache"
        )
    end
    if n > 0 then
        RefreshUiIfOpen()
    end
end

function StockPiler.OnBankOpen()
    local n = 0
    if StockPiler.Inventory and StockPiler.Inventory.LearnFromBankData then
        n = StockPiler.Inventory.LearnFromBankData("bank-open")
    end
    if n > 0 then
        RefreshUiIfOpen()
    end
end

function StockPiler.OnBankSlotUpdated()
    local n = 0
    if StockPiler.Inventory and StockPiler.Inventory.LearnFromBankData then
        n = StockPiler.Inventory.LearnFromBankData("bank-update")
    end
    if n > 0 then
        RefreshUiIfOpen()
    end
end

function StockPiler.OnStoreShow()
    local n = 0
    if StockPiler.Inventory and StockPiler.Inventory.LearnFromStoreData then
        n = StockPiler.Inventory.LearnFromStoreData("store")
    end
    if n > 0 then
        RefreshUiIfOpen()
    end
end

local function HookGuildVaultWindow()
    if type(GuildVaultWindow) ~= "table" then
        return
    end
    if GuildVaultWindow._StockPilerHooked then
        return
    end
    local origOpen = GuildVaultWindow.OnGuildVaultOpened
    if type(origOpen) == "function" then
        GuildVaultWindow.OnGuildVaultOpened = function(vaultDataTable)
            origOpen(vaultDataTable)
            pcall(StockPiler.OnGuildVaultOpen, vaultDataTable)
        end
    end
    local origUpdate = GuildVaultWindow.UpdateItemsInVault
    if type(origUpdate) == "function" then
        GuildVaultWindow.UpdateItemsInVault = function(vaultData)
            origUpdate(vaultData)
            pcall(StockPiler.OnGuildVaultItemsUpdated, vaultData)
        end
    end
    GuildVaultWindow._StockPilerHooked = true
end

local function HookBankWindow()
    if type(BankWindow) ~= "table" then
        return
    end
    if BankWindow._StockPilerHooked then
        return
    end
    local origOpen = BankWindow.OpenBank
    if type(origOpen) == "function" then
        BankWindow.OpenBank = function(...)
            origOpen(...)
            pcall(StockPiler.OnBankOpen)
        end
    end
    BankWindow._StockPilerHooked = true
end

local function HookStoreWindow()
    if type(EA_Window_InteractionStore) ~= "table" then
        return
    end
    if EA_Window_InteractionStore._StockPilerHooked then
        return
    end
    -- ShowStore fires as each store page arrives from the server
    local origShow = EA_Window_InteractionStore.ShowStore
    if type(origShow) == "function" then
        EA_Window_InteractionStore.ShowStore = function(...)
            origShow(...)
            pcall(StockPiler.OnStoreShow)
        end
    end
    local origUpdate = EA_Window_InteractionStore.UpdateStoreList
    if type(origUpdate) == "function" then
        EA_Window_InteractionStore.UpdateStoreList = function(...)
            origUpdate(...)
            pcall(StockPiler.OnStoreShow)
        end
    end
    local origBuyback = EA_Window_InteractionStore.UpdateBuyBackList
    if type(origBuyback) == "function" then
        EA_Window_InteractionStore.UpdateBuyBackList = function(...)
            origBuyback(...)
            pcall(StockPiler.OnStoreShow)
        end
    end
    EA_Window_InteractionStore._StockPilerHooked = true
end

local function HookCraftingSystem()
    if type(CraftingSystem) ~= "table" then
        return false
    end
    if CraftingSystem._StockPilerHooked then
        return true
    end
    local origUpdate = CraftingSystem.UpdateCraftingStatus
    if type(origUpdate) == "function" then
        CraftingSystem.UpdateCraftingStatus = function(updatedIngredients)
            origUpdate(updatedIngredients)
            pcall(StockPiler.OnCraftingUpdated)
        end
    end
    CraftingSystem._StockPilerHooked = true
    StockPiler.D("HookCraftingSystem ok")
    return true
end

local function HookRefinement()
    if type(EA_Window_Backpack) ~= "table" then
        return false
    end
    if EA_Window_Backpack._StockPilerRefineHooked then
        return true
    end
    local origRefine = EA_Window_Backpack.RefineItem
    if type(origRefine) ~= "function" then
        return false
    end
    EA_Window_Backpack.RefineItem = function()
        if EA_Window_Backpack.refineItemSlot and EA_Window_Backpack.refineBackpack then
            local inventory = EA_Window_Backpack.GetItemsFromBackpack(EA_Window_Backpack.refineBackpack)
            local itemData = inventory and inventory[EA_Window_Backpack.refineItemSlot]
            if type(itemData) == "table" and StockPiler.SeedMap and StockPiler.SeedMap.BeginPendingRefine then
                pcall(StockPiler.SeedMap.BeginPendingRefine, itemData)
            end
        end
        origRefine()
    end
    EA_Window_Backpack._StockPilerRefineHooked = true
    StockPiler.D("HookRefinement ok")
    return true
end

local function HookApothecaryWindow()
    if type(ApothecaryWindow) ~= "table" then
        return false
    end
    if ApothecaryWindow._StockPilerHooked then
        return true
    end
    local origPerform = ApothecaryWindow.Perform
    if type(origPerform) == "function" then
        ApothecaryWindow.Perform = function()
            local s = StockPiler.EnsureSettings and StockPiler.EnsureSettings()
            if s and s.blockInvalidApothecaryBrew ~= false
                and StockPiler.Brew and StockPiler.Brew.ValidateApothecaryPerform
            then
                local ok, msg = StockPiler.Brew.ValidateApothecaryPerform()
                if ok ~= true then
                    if StockPiler.Print and msg then
                        StockPiler.Print(msg)
                    end
                    return
                end
            end
            if StockPiler.Inventory and StockPiler.Inventory.BeginPendingCraft then
                pcall(StockPiler.Inventory.BeginPendingCraft)
            end
            origPerform()
        end
    end
    ApothecaryWindow._StockPilerHooked = true
    return true
end

function StockPiler.EnsureApothecaryHook()
    HookCraftingSystem()
    return HookApothecaryWindow()
end

function StockPiler.EnsureCraftingHook()
    return HookCraftingSystem()
end

function StockPiler.EnsureRefinementHook()
    return HookRefinement()
end

function StockPiler.OnTradeSkillUpdated()
    if StockPiler.Inventory and StockPiler.Inventory.EnforceProfessionGates then
        pcall(StockPiler.Inventory.EnforceProfessionGates)
    end
    if StockPiler.Planner and StockPiler.Planner.InvalidatePlanCache then
        pcall(StockPiler.Planner.InvalidatePlanCache)
    end
    if StockPiler.AutoGrow and StockPiler.AutoGrow.InvalidatePlantQueue then
        pcall(StockPiler.AutoGrow.InvalidatePlantQueue)
    end
    RefreshUiIfOpen()
    if StockPilerMacro and StockPilerMacro.RefreshMacroButtonAppearance then
        pcall(StockPilerMacro.RefreshMacroButtonAppearance)
    end
end

function StockPiler.OnCraftingUpdated()
    StockPiler.EnsureCraftingHook()
    if StockPiler.Brew and StockPiler.Brew.OnCraftingUpdated then
        pcall(StockPiler.Brew.OnCraftingUpdated)
    end
    if StockPiler.Inventory and StockPiler.Inventory.OnCraftingUpdated then
        local learned = StockPiler.Inventory.OnCraftingUpdated()
        if learned then
            RefreshUiIfOpen()
        end
    end
end

function StockPiler.Initialize()
    StockPiler.EnsureSettings()
    HookItemTooltips()
    HookGuildVaultWindow()
    HookBankWindow()
    HookStoreWindow()
    HookApothecaryWindow()
    HookCraftingSystem()
    HookRefinement()

    RegisterEventHandler(SystemData.Events.PLAYER_INVENTORY_SLOT_UPDATED, "StockPiler.OnInventoryUpdated")
    RegisterEventHandler(SystemData.Events.PLAYER_CRAFTING_SLOT_UPDATED, "StockPiler.OnInventoryUpdated")
    if SystemData.Events.PLAYER_CRAFTING_UPDATED then
        RegisterEventHandler(SystemData.Events.PLAYER_CRAFTING_UPDATED, "StockPiler.OnCraftingUpdated")
    end
    if SystemData.Events.AUCTION_SEARCH_RESULT_RECEIVED then
        RegisterEventHandler(SystemData.Events.AUCTION_SEARCH_RESULT_RECEIVED, "StockPiler.OnAuctionSearchResults")
    end
    if SystemData.Events.INTERACT_GUILD_VAULT_OPEN then
        RegisterEventHandler(SystemData.Events.INTERACT_GUILD_VAULT_OPEN, "StockPiler.OnGuildVaultOpen")
    end
    if SystemData.Events.GUILD_VAULT_ITEMS_UPDATED then
        RegisterEventHandler(SystemData.Events.GUILD_VAULT_ITEMS_UPDATED, "StockPiler.OnGuildVaultItemsUpdated")
    end
    if SystemData.Events.INTERACT_OPEN_BANK then
        RegisterEventHandler(SystemData.Events.INTERACT_OPEN_BANK, "StockPiler.OnBankOpen")
    end
    if SystemData.Events.PLAYER_BANK_SLOT_UPDATED then
        RegisterEventHandler(SystemData.Events.PLAYER_BANK_SLOT_UPDATED, "StockPiler.OnBankSlotUpdated")
    end
    if SystemData.Events.INTERACT_SHOW_STORE then
        RegisterEventHandler(SystemData.Events.INTERACT_SHOW_STORE, "StockPiler.OnStoreShow")
    end
    if SystemData.Events.LOADING_END then
        RegisterEventHandler(SystemData.Events.LOADING_END, "StockPiler.OnCharacterSettingsReload")
    end
    if SystemData.Events.TRADE_SKILL_UPDATED then
        RegisterEventHandler(SystemData.Events.TRADE_SKILL_UPDATED, "StockPiler.OnTradeSkillUpdated")
    end

    if StockPilerWindow and StockPilerWindow.Initialize then
        pcall(StockPilerWindow.Initialize)
    end

    if StockPiler.AutoGrow and StockPiler.AutoGrow.Initialize then
        pcall(StockPiler.AutoGrow.Initialize)
    end

    if StockPiler.Brew and StockPiler.Brew.Initialize then
        StockPiler.Brew.Initialize()
    end

    if StockPilerMacro and StockPilerMacro.Initialize then
        pcall(StockPilerMacro.Initialize)
    end

    if StockPiler.SeedMap and StockPiler.SeedMap.ApplyPendingMapReset then
        pcall(StockPiler.SeedMap.ApplyPendingMapReset)
    end

    if StockPiler.SeedMap and StockPiler.SeedMap.EnsureSpecBootstrap then
        pcall(StockPiler.SeedMap.EnsureSpecBootstrap)
    end

    if StockPiler.SeedMap and StockPiler.SeedMap.RepairFromLearnedRecipes
        and StockPiler.SeedMap._growRepairDone ~= true
    then
        StockPiler.SeedMap._growRepairDone = true
        local repaired = 0
        local ok, count = pcall(StockPiler.SeedMap.RepairFromLearnedRecipes)
        if ok then
            repaired = tonumber(count) or 0
        end
        if repaired > 0 and StockPiler.Trace then
            StockPiler.Trace("Grow map recipe repair entries=" .. tostring(repaired))
        end
        if StockPiler.AutoGrow and StockPiler.AutoGrow.InvalidatePlantQueue then
            pcall(StockPiler.AutoGrow.InvalidatePlantQueue)
        end
    end

    if StockPiler.RecipeSpec and StockPiler.RecipeSpec.RepairIncompleteMainSpecs then
        local repaired = 0
        local ok, count = pcall(StockPiler.RecipeSpec.RepairIncompleteMainSpecs)
        if ok then
            repaired = tonumber(count) or 0
        end
        if repaired > 0 and StockPiler.Trace then
            StockPiler.Trace("Repaired " .. tostring(repaired) .. " incomplete main spec(s)")
        end
    end

    if RegisterSlash() then
        local pb = (StockPiler.Classify and StockPiler.Classify.PotionBarAvailable and StockPiler.Classify.PotionBarAvailable()) and L"PotionBar=yes" or L"PotionBar=no"
        local cvt = (StockPiler.SeedMap and StockPiler.SeedMap.CvtAvailable and StockPiler.SeedMap.CvtAvailable()) and L"CVT=yes" or L"CVT=no"
        StockPiler.Print(L"v" .. StockPiler.Version .. L" loaded. /stockpiler | /stp growplan | /stp growtrace | /stp debug | " .. pb .. L" | " .. cvt)
        StockPiler.D("Initialize v" .. tostring(StockPiler.Version)
            .. " DebugEnabled=" .. tostring(StockPiler.DebugEnabled)
            .. " GrowTrace=" .. tostring(StockPiler.AutoGrow and StockPiler.AutoGrow.TraceEnabled)
            .. " PotionBar=" .. tostring(StockPiler.Classify and StockPiler.Classify.PotionBarAvailable and StockPiler.Classify.PotionBarAvailable()))
    else
        StockPiler.Print(L"v" .. StockPiler.Version .. L" loaded (no LibSlash - enable LibSlash for /stockpiler).")
    end
end

function StockPiler.Shutdown()
    if StockPiler.PersistActiveCharacterSettings and type(StockPiler.Settings) == "table" then
        StockPiler.PersistActiveCharacterSettings(StockPiler.Settings)
        StockPiler.Settings._charBucket = nil
    end
    if StockPiler.AutoGrow and StockPiler.AutoGrow.Shutdown then
        StockPiler.AutoGrow.Shutdown()
    end
    if StockPilerMacro and StockPilerMacro.Shutdown then
        StockPilerMacro.Shutdown()
    end
    UnregisterEventHandler(SystemData.Events.PLAYER_INVENTORY_SLOT_UPDATED, "StockPiler.OnInventoryUpdated")
    UnregisterEventHandler(SystemData.Events.PLAYER_CRAFTING_SLOT_UPDATED, "StockPiler.OnInventoryUpdated")
    if SystemData.Events.PLAYER_CRAFTING_UPDATED then
        UnregisterEventHandler(SystemData.Events.PLAYER_CRAFTING_UPDATED, "StockPiler.OnCraftingUpdated")
    end
    if SystemData.Events.AUCTION_SEARCH_RESULT_RECEIVED then
        UnregisterEventHandler(SystemData.Events.AUCTION_SEARCH_RESULT_RECEIVED, "StockPiler.OnAuctionSearchResults")
    end
    if SystemData.Events.INTERACT_GUILD_VAULT_OPEN then
        UnregisterEventHandler(SystemData.Events.INTERACT_GUILD_VAULT_OPEN, "StockPiler.OnGuildVaultOpen")
    end
    if SystemData.Events.GUILD_VAULT_ITEMS_UPDATED then
        UnregisterEventHandler(SystemData.Events.GUILD_VAULT_ITEMS_UPDATED, "StockPiler.OnGuildVaultItemsUpdated")
    end
    if SystemData.Events.INTERACT_OPEN_BANK then
        UnregisterEventHandler(SystemData.Events.INTERACT_OPEN_BANK, "StockPiler.OnBankOpen")
    end
    if SystemData.Events.PLAYER_BANK_SLOT_UPDATED then
        UnregisterEventHandler(SystemData.Events.PLAYER_BANK_SLOT_UPDATED, "StockPiler.OnBankSlotUpdated")
    end
    if SystemData.Events.INTERACT_SHOW_STORE then
        UnregisterEventHandler(SystemData.Events.INTERACT_SHOW_STORE, "StockPiler.OnStoreShow")
    end
    if SystemData.Events.LOADING_END then
        UnregisterEventHandler(SystemData.Events.LOADING_END, "StockPiler.OnCharacterSettingsReload")
    end
    if SystemData.Events.TRADE_SKILL_UPDATED then
        UnregisterEventHandler(SystemData.Events.TRADE_SKILL_UPDATED, "StockPiler.OnTradeSkillUpdated")
    end
end
