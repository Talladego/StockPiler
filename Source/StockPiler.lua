----------------------------------------------------------------
-- StockPiler — core
----------------------------------------------------------------

StockPiler = StockPiler or {}
StockPiler.Version = L"0.9.48"
-- Writes to user/logs/uilog.log via engine d(). Toggle with /stockpiler debug
StockPiler.DebugEnabled = false

-- Profile file (SharedProfile/.../StockPiler/SavedVariables.lua):
-- UI prefs + characters[name] watches/toggles. Character aliases are session-only.
StockPiler.DefaultSettings = {
    settingsVersion = 9,
    charactersVersion = 1,
    characters = {}, -- [characterName] = DefaultCharacterSettings
    potionNameFilter = "",
    potionEffectFilter = "",
    potionKnownRecipeOnly = false,
    potionSortColumn = "rank",
    potionSortAscending = true,
    -- Chat verbosity: "all" (default) | "quiet" (manual toggles only) | "off"
    statusChat = "all",
    statusMessages = true, -- compat: false when statusChat == "off"
    blockInvalidApothecaryBrew = true,
}

-- Account file (GLOBAL/StockPiler/SavedVariables.lua): shared knowledge.
-- Learn-only: brew / plant / harvest / refine / plot additives. No CVT / bag observe.
-- EnsureSettings aliases these onto StockPiler.Settings for existing code paths.
StockPiler.ACCOUNT_VERSION = 2

StockPiler.DefaultAccount = {
    accountVersion = 2,
    -- One row per item learned via brew/grow/refine/additive use
    items = {},
    -- seedUid -> { [plantUid] = { samples, countSum, last } }
    grows = {},
    -- plantUid -> { seedUid, seedKind, byproducts = { [resinUid] = stats } }
    refines = {},
    -- fingerprint -> recipe (slots by uid, outcomes by potion uid)
    recipes = {},
    -- "uid:N" -> potion (links back to recipe fingerprints)
    potions = {},
    -- tostring(uid) -> soil/water/nutrient record
    additives = {},
}

local ACCOUNT_TABLE_KEYS = {
    "items",
    "grows",
    "refines",
    "recipes",
    "potions",
    "additives",
}

-- Legacy Settings field names → Account table (same table reference).
local ACCOUNT_COMPAT_ALIASES = {
    knownPotions = "potions",
    learnedRecipeSpecs = "recipes",
    learnedAdditives = "additives",
}

-- Session aliases from characters[name]; stripped from Settings before save.
local SETTINGS_CHARACTER_ALIASES = {
    "watches",
    "autoGrowEnabled",
    "autoGrowAdditives",
    "autoBuyEnabled",
    "autoBuyReserveGold",
    "autoBuyBudgetGold",
    "growSeedBufferMin",
    "brewMacroEnabled",
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

--- Log a protected-call failure. Quiet = uilog only when /stp debug is on.
local _reportingProtectedCall = false
function StockPiler.ReportProtectedCallFailure(context, err, quiet)
    if _reportingProtectedCall == true then
        return
    end
    _reportingProtectedCall = true
    local msg = tostring(context or "unknown") .. ": " .. tostring(err or "unknown error")
    pcall(function()
        if quiet == true then
            if StockPiler.DebugEnabled == true then
                StockPiler._EmitLog("StockPiler| TryCallQuiet " .. msg)
            end
            return
        end
        StockPiler._EmitLog("StockPiler| TryCall " .. msg)
        if type(LogLuaMessage) == "function" and SystemData and SystemData.UiLogFilters then
            LogLuaMessage("Lua", SystemData.UiLogFilters.WARNING, towstring("[StockPiler] " .. msg))
        end
    end)
    _reportingProtectedCall = false
end

--- User actions, hooks, init, snapshot builders. Logs every failure.
function StockPiler.TryCall(context, fn, ...)
    if type(fn) ~= "function" then
        StockPiler.ReportProtectedCallFailure(context, "expected function, got " .. type(fn))
        return false
    end
    local results = { pcall(fn, ...) }
    local ok = table.remove(results, 1)
    if ok then
        if #results == 0 then
            return true
        end
        return true, unpack(results)
    end
    StockPiler.ReportProtectedCallFailure(context, results[1])
    return false
end

--- Hot-path optional lookups. Logs only when /stp debug is on.
function StockPiler.TryCallQuiet(context, fn, ...)
    if type(fn) ~= "function" then
        StockPiler.ReportProtectedCallFailure(context, "expected function, got " .. type(fn), true)
        return false
    end
    local results = { pcall(fn, ...) }
    local ok = table.remove(results, 1)
    if ok then
        if #results == 0 then
            return true
        end
        return true, unpack(results)
    end
    StockPiler.ReportProtectedCallFailure(context, results[1], true)
    return false
end

function StockPiler.ToNarrow(value)
    if value == nil then
        return ""
    end
    if type(value) == "string" then
        return value
    end
    if type(value) == "wstring" then
        if type(WStringToString) ~= "function" then
            return ""
        end
        local ok, text = StockPiler.TryCallQuiet("ToNarrow", WStringToString, value)
        if ok and type(text) == "string" then
            return text
        end
        return ""
    end
    return tostring(value)
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

local function WipeTable(tbl)
    if type(tbl) ~= "table" then
        return
    end
    for k in pairs(tbl) do
        tbl[k] = nil
    end
end

local function CleanCharacterBuckets(s)
    if type(s) ~= "table" or type(s.characters) ~= "table" then
        return
    end
    for _, char in pairs(s.characters) do
        if type(char) == "table" and StockPiler.EnsureCharacterBucketShape then
            StockPiler.EnsureCharacterBucketShape(char)
            for key in pairs(char) do
                if StockPiler.DefaultCharacterSettings[key] == nil then
                    char[key] = nil
                end
            end
        end
    end
end

function StockPiler.EnsureAccount()
    if type(StockPiler.Account) ~= "table" then
        StockPiler.Account = DeepCopy(StockPiler.DefaultAccount)
    end
    local a = StockPiler.Account
    local ver = tonumber(a.accountVersion) or 0
    if ver < StockPiler.ACCOUNT_VERSION then
        -- Breaking knowledge model: flush and relearn (no migration).
        local notice = ver > 0
        StockPiler.Account = DeepCopy(StockPiler.DefaultAccount)
        a = StockPiler.Account
        if notice and StockPiler.Print then
            StockPiler.Print(L"Account knowledge reset for v"
                .. towstring(tostring(StockPiler.ACCOUNT_VERSION))
                .. L" - relearn by brewing, planting, harvesting, and refining.")
        end
    end
    for i = 1, #ACCOUNT_TABLE_KEYS do
        local key = ACCOUNT_TABLE_KEYS[i]
        if type(a[key]) ~= "table" then
            a[key] = {}
        end
    end
    -- Drop legacy tables if a partial/old save somehow remains.
    local legacy = {
        "harvestMap", "refineMap", "harvestByproducts", "seedMap", "growProducers",
        "learnedSeedMap", "learnedRecipeSpecs", "knownPotions", "observedPotions",
        "observedMats", "learnedAdditives", "matScopeVersion",
    }
    for i = 1, #legacy do
        a[legacy[i]] = nil
    end
    a.accountVersion = StockPiler.ACCOUNT_VERSION
    return a
end

--- Point Settings.<key> at Account.<key> so existing code keeps using StockPiler.Settings.
function StockPiler.BindAccountIntoSettings(s)
    local a = StockPiler.EnsureAccount()
    if type(s) ~= "table" then
        return a
    end
    for i = 1, #ACCOUNT_TABLE_KEYS do
        local key = ACCOUNT_TABLE_KEYS[i]
        s[key] = a[key]
    end
    for alias, canonical in pairs(ACCOUNT_COMPAT_ALIASES) do
        s[alias] = a[canonical]
    end
    return a
end

--- Drop account + character aliases from Settings so the profile file stays small.
function StockPiler.StripAccountFromSettings(s)
    if type(s) ~= "table" then
        return
    end
    for i = 1, #ACCOUNT_TABLE_KEYS do
        s[ACCOUNT_TABLE_KEYS[i]] = nil
    end
    for alias in pairs(ACCOUNT_COMPAT_ALIASES) do
        s[alias] = nil
    end
    -- Legacy names that must never leak into the profile file
    local stripExtra = {
        "harvestMap", "refineMap", "harvestByproducts", "seedMap", "growProducers",
        "learnedSeedMap", "observedPotions", "observedMats", "matScopeVersion",
    }
    for i = 1, #stripExtra do
        s[stripExtra[i]] = nil
    end
    for i = 1, #SETTINGS_CHARACTER_ALIASES do
        s[SETTINGS_CHARACTER_ALIASES[i]] = nil
    end
    s._characterKey = nil
    s._charBucket = nil
end

--- Clear an account table in place (keeps Settings alias intact).
function StockPiler.ClearAccountTable(key)
    local a = StockPiler.EnsureAccount()
    if type(a[key]) ~= "table" then
        a[key] = {}
    else
        WipeTable(a[key])
    end
    if type(StockPiler.Settings) == "table" then
        StockPiler.Settings[key] = a[key]
        for alias, canonical in pairs(ACCOUNT_COMPAT_ALIASES) do
            if canonical == key then
                StockPiler.Settings[alias] = a[key]
            end
        end
    end
    return a[key]
end

----------------------------------------------------------------
-- Account.items — single catalog for learned craft/grow items
----------------------------------------------------------------

StockPiler.Items = StockPiler.Items or {}

local function ItemsTable()
    local a = StockPiler.EnsureAccount()
    if type(a.items) ~= "table" then
        a.items = {}
    end
    if type(StockPiler.Settings) == "table" then
        StockPiler.Settings.items = a.items
    end
    return a.items
end

function StockPiler.Items.Get(uid)
    uid = tonumber(uid) or 0
    if uid <= 0 then
        return nil
    end
    local items = ItemsTable()
    local row = items[tostring(uid)]
    if type(row) == "table" then
        return row
    end
    return nil
end

local function TableEntryCount(t)
    local n = 0
    if type(t) == "table" then
        for _ in pairs(t) do
            n = n + 1
        end
    end
    return n
end

local function ItemDataHasCraftBonuses(itemData)
    return type(itemData) == "table"
        and type(itemData.craftingBonus) == "table"
        and next(itemData.craftingBonus) ~= nil
end

--- True when an existing items row has a richer craft profile than incoming fields.
--- Prevents refine/harvest lookups (no craftingBonus) from wiping brew-learned mats.
local function ExistingCraftProfileIsRicher(row, fields)
    if type(row) ~= "table" or type(fields) ~= "table" then
        return false
    end
    local existN = TableEntryCount(row.bonuses)
    local newN = TableEntryCount(fields.bonuses)
    local existTs = tonumber(row.tradeSkill) or 0
    local newTs = tonumber(fields.tradeSkill) or 0
    local existRole = tostring(row.role or "")
    local newRole = tostring(fields.role or "")
    local existCraftRole = existRole ~= "" and existRole ~= "ingredient"
    local newCraftRole = newRole ~= "" and newRole ~= "ingredient"

    if existN > newN then
        return true
    end
    if existTs > 0 and newTs == 0 then
        return true
    end
    if existCraftRole and not newCraftRole and existN >= newN then
        return true
    end
    if row.incomplete ~= true and fields.incomplete == true and existN >= newN then
        return true
    end
    -- Prefer completing a main (effect fingerprint) over keeping incomplete.
    if row.incomplete == true and fields.incomplete ~= true then
        return false
    end
    return false
end

local CRAFT_PROFILE_FIELDS = {
    "role", "bonuses", "effectId", "slotType", "skillLevel",
    "tradeSkill", "incomplete", "cultivationType",
}

--- Merge display + craft profile into items[uid]. Returns the row.
function StockPiler.Items.Upsert(uid, fields)
    uid = tonumber(uid) or 0
    if uid <= 0 or type(fields) ~= "table" then
        return nil
    end
    local items = ItemsTable()
    local key = tostring(uid)
    local row = items[key]
    if type(row) ~= "table" then
        row = { uniqueID = uid }
    end
    row.uniqueID = uid
    for k, v in pairs(fields) do
        if v ~= nil then
            -- Never clobber a known ItemTypes value with NONE/0.
            if k == "itemType" and (tonumber(v) or 0) == 0 and (tonumber(row.itemType) or 0) > 0 then
                -- keep existing
            else
                row[k] = v
            end
        end
    end
    items[key] = row
    return row
end

function StockPiler.Items.UpsertFromItemData(itemData, kindHint)
    if type(itemData) ~= "table" then
        return nil
    end
    local uid = tonumber(itemData.uniqueID) or tonumber(itemData.id) or 0
    if uid <= 0 then
        return nil
    end
    local fields = {
        kind = kindHint,
        name = itemData.name,
        nameNarrow = StockPiler.ToNarrow and StockPiler.ToNarrow(itemData.name) or nil,
        iconNum = tonumber(itemData.iconNum) or 0,
        skillReq = tonumber(itemData.craftingSkillRequirement) or 0,
        tradeSkill = tonumber(itemData.tradeSkill) or 0,
        cultivationType = tonumber(itemData.cultivationType) or 0,
        isRefinable = itemData.isRefinable == true,
        -- Live GameData uses .type (ItemTypes.*); keep itemType as the stored field name.
        itemType = tonumber(itemData.type) or tonumber(itemData.itemType) or 0,
        iLevel = tonumber(itemData.iLevel) or 0,
    }
    local hasLiveCraft = ItemDataHasCraftBonuses(itemData)
    if StockPiler.MaterialSpec and StockPiler.MaterialSpec.FromItemData then
        local spec = StockPiler.MaterialSpec.FromItemData(itemData)
        if type(spec) == "table" then
            local copied = StockPiler.MaterialSpec.Copy and StockPiler.MaterialSpec.Copy(spec) or spec
            fields.role = copied.role
            fields.skillLevel = copied.skillLevel
            fields.slotType = copied.slotType
            fields.effectId = copied.effectId
            fields.bonuses = copied.bonuses
            fields.tradeSkill = copied.tradeSkill or fields.tradeSkill
            fields.cultivationType = copied.cultivationType or fields.cultivationType
            fields.incomplete = copied.incomplete == true
            if not fields.kind then
                local role = copied.role or ""
                if role == "ingredient" and (fields.cultivationType == 1 or fields.cultivationType == 5) then
                    fields.kind = (fields.cultivationType == 5) and "spore" or "seed"
                elseif role ~= "" and role ~= "ingredient" then
                    fields.kind = "mat"
                end
            end
        end
    end
    if not fields.kind then
        fields.kind = "mat"
    end

    local existing = StockPiler.Items.Get(uid)
    if type(existing) == "table" and (not hasLiveCraft or ExistingCraftProfileIsRicher(existing, fields)) then
        -- Display / kind / flags only; keep brew-learned craft profile.
        for i = 1, #CRAFT_PROFILE_FIELDS do
            fields[CRAFT_PROFILE_FIELDS[i]] = nil
        end
        -- skillReq from DB is fine when existing is empty; don't zero a known req.
        if (tonumber(fields.skillReq) or 0) == 0 and (tonumber(existing.skillReq) or 0) > 0 then
            fields.skillReq = nil
        end
    end

    return StockPiler.Items.Upsert(uid, fields)
end

--- Rebuild a MaterialSpec-compatible table from a stored items row.
function StockPiler.Items.ToSpec(uid)
    local row = StockPiler.Items.Get(uid)
    if type(row) ~= "table" then
        return nil
    end
    return {
        tradeSkill = tonumber(row.tradeSkill) or 0,
        skillLevel = tonumber(row.skillLevel) or tonumber(row.skillReq) or 0,
        slotType = tonumber(row.slotType) or 0,
        effectId = row.effectId,
        bonuses = type(row.bonuses) == "table" and row.bonuses or {},
        cultivationType = tonumber(row.cultivationType) or 0,
        role = row.role,
        incomplete = row.incomplete == true,
    }
end

--- Thin itemData-like table for icon/name fallbacks when bags are empty.
function StockPiler.Items.AsItemData(uid)
    local row = StockPiler.Items.Get(uid)
    if type(row) ~= "table" then
        return nil
    end
    return {
        uniqueID = tonumber(row.uniqueID) or tonumber(uid) or 0,
        name = row.name,
        nameNarrow = row.nameNarrow,
        iconNum = tonumber(row.iconNum) or 0,
        craftingSkillRequirement = tonumber(row.skillReq) or 0,
        tradeSkill = tonumber(row.tradeSkill) or 0,
        cultivationType = tonumber(row.cultivationType) or 0,
        isRefinable = row.isRefinable == true,
        itemType = tonumber(row.itemType) or 0,
        type = tonumber(row.itemType) or 0,
        iLevel = tonumber(row.iLevel) or 0,
        craftingBonus = nil,
    }
end

-- Safe to call during CreateWindow OnInitialize (before StockPiler.Initialize).
function StockPiler.EnsureSettings()
    if type(StockPiler.Settings) ~= "table" then
        StockPiler.Settings = DeepCopy(StockPiler.DefaultSettings)
    end
    local s = StockPiler.Settings
    if type(s.characters) ~= "table" then
        s.characters = {}
    end
    s.settingsVersion = 9
    s.charactersVersion = 1
    if s.potionNameFilter == nil then
        s.potionNameFilter = ""
    end
    if s.potionEffectFilter == nil then
        s.potionEffectFilter = ""
    end
    if s.potionKnownRecipeOnly == nil then
        s.potionKnownRecipeOnly = false
    end
    if s.potionSortColumn == nil or s.potionSortColumn == "recipe" then
        s.potionSortColumn = "rank"
    end
    if s.potionSortAscending == nil then
        s.potionSortAscending = true
    end
    if s.statusChat ~= "all" and s.statusChat ~= "quiet" and s.statusChat ~= "off" then
        if s.statusMessages == false then
            s.statusChat = "off"
        else
            s.statusChat = "all"
        end
    end
    s.statusMessages = (s.statusChat ~= "off")
    if s.blockInvalidApothecaryBrew == nil then
        s.blockInvalidApothecaryBrew = true
    end

    StockPiler.BindAccountIntoSettings(s)
    CleanCharacterBuckets(s)
    if StockPiler.BindActiveCharacterSettings then
        StockPiler.BindActiveCharacterSettings(s)
    end

    if StockPiler.Inventory then
        if type(StockPiler.Inventory._learnedItemData) ~= "table" then
            StockPiler.Inventory._learnedItemData = {}
        end
        if type(StockPiler.Inventory._learnedMatData) ~= "table" then
            StockPiler.Inventory._learnedMatData = {}
        end
    end

    s._charBucket = nil
    if StockPiler.PersistActiveCharacterSettings then
        StockPiler.PersistActiveCharacterSettings(s)
    end
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
        StockPiler.Print(L"/stockpiler (or /stp) - open  |  potions|watch  |  quiet|chat  |  spec <uid>  |  seedmap|growplan|growwhy|growtrace  |  resetmaps  |  scan  |  debug  |  perf")
        return
    end
    if args == "seedmap" or args == "seeds" or args == "growmap" then
        if StockPiler.SeedMap and StockPiler.SeedMap.DumpToChat then
            StockPiler.SeedMap.DumpToChat()
        end
        return
    end
    if args == "growplan" or args == "growdump" then
        if StockPiler.AutoGrow and StockPiler.AutoGrow.DumpGrowPlan then
            StockPiler.AutoGrow.DumpGrowPlan({ force = true })
            StockPiler.Print(L"Grow plan trace written to uilog.log")
        end
        return
    end
    if args == "growwhy" or args == "why" then
        if StockPiler.AutoGrow and StockPiler.AutoGrow.DumpDecisionWhy then
            -- Refresh plan so queue decision is current before dump.
            if StockPiler.AutoGrow.DumpGrowPlan then
                StockPiler.AutoGrow.DumpGrowPlan({ force = true })
            end
            StockPiler.AutoGrow.DumpDecisionWhy({ force = true })
            StockPiler.Print(L"Grow decisions written to chat + uilog.log")
        end
        return
    end
    if args == "growtrace" then
        if StockPiler.AutoGrow then
            StockPiler.AutoGrow.TraceEnabled = not (StockPiler.AutoGrow.TraceEnabled == true)
            local state = (StockPiler.AutoGrow.TraceEnabled == true) and L"ON" or L"OFF"
            StockPiler.Print(L"AutoGrow decision trace: " .. state .. L" (/stp growwhy for last decisions)")
            if StockPiler.AutoGrow.TraceEnabled == true and StockPiler.AutoGrow.DumpGrowPlan then
                StockPiler.AutoGrow.DumpGrowPlan({ force = true })
            end
        end
        return
    end
    if args == "resetmaps" or args == "resetseedmap" or args == "clearmaps" then
        if StockPiler.SeedMap and StockPiler.SeedMap.ResetSpecMaps then
            local bootstrapped, repaired = StockPiler.SeedMap.ResetSpecMaps()
            StockPiler.Print(L"Seed/grow maps reset. Relearn by planting, harvesting, and refining."
                .. L" (cleared=" .. towstring(tostring(bootstrapped or 0))
                .. L" repaired=" .. towstring(tostring(repaired or 0)) .. L")")
        end
        return
    end
    local specUid = string.match(args, "^spec%s+(%d+)$")
    if specUid and StockPiler.MaterialSpec and StockPiler.MaterialSpec.FromItemData then
        local id = tonumber(specUid)
        local itemData = nil
        if type(GetDatabaseItemData) == "function" then
            local ok, data = StockPiler.TryCallQuiet("GetDatabaseItemData", GetDatabaseItemData, id)
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
    if args == "perf" then
        if StockPiler.Perf and StockPiler.Perf.SetEnabled then
            local on = StockPiler.Perf.SetEnabled(not (StockPiler.Perf.Enabled == true))
            local state = on and L"ON" or L"OFF"
            StockPiler.Print(L"Perf hitch log: " .. state .. L" (uilog only on frames >=400ms with StockPiler work)")
            if on ~= true and StockPiler.Perf.PrintLast then
                StockPiler.Perf.PrintLast()
            end
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
    local cmd, modeArg = string.match(args, "^(%S+)%s*(%S*)$")
    if cmd == "quiet" or cmd == "chat" or cmd == "notify" or cmd == "messages" then
        local s = StockPiler.EnsureSettings()
        modeArg = modeArg or ""
        local mode = s.statusChat
        if mode ~= "all" and mode ~= "quiet" and mode ~= "off" then
            mode = (s.statusMessages == false) and "off" or "all"
        end
        if modeArg == "all" or modeArg == "full" or modeArg == "on" then
            mode = "all"
        elseif modeArg == "quiet" or modeArg == "q" then
            mode = "quiet"
        elseif modeArg == "off" or modeArg == "none" then
            mode = "off"
        else
            -- Cycle: all -> quiet -> off -> all
            if mode == "all" then
                mode = "quiet"
            elseif mode == "quiet" then
                mode = "off"
            else
                mode = "all"
            end
        end
        s.statusChat = mode
        s.statusMessages = (mode ~= "off")
        local label = L"ALL (plant/harvest/learn)"
        if mode == "quiet" then
            label = L"QUIET (manual enable/disable only)"
        elseif mode == "off" then
            label = L"OFF"
        end
        StockPiler.Print(L"Chat status: " .. label .. L"  (/stp quiet | /stp quiet all|off)")
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
        local ok, data = StockPiler.TryCallQuiet("GetDatabaseItemData", GetDatabaseItemData, id)
        StockPiler.D("dbtest id=" .. tostring(id) .. " ok=" .. tostring(ok)
            .. " type=" .. type(data)
            .. (ok and type(data) == "table"
                and (" uid=" .. tostring(data.uniqueID) .. " icon=" .. tostring(data.iconNum)
                    .. " nameType=" .. type(data.name))
                or (" err=" .. tostring(data))))
        if ok and type(data) == "table" and type(Tooltips.CreateItemTooltip) == "function" then
            StockPiler.Print(L"DB ok for " .. towstring(tostring(id)) .. L" - showing tooltip")
            StockPiler.TryCall("Tooltips.CreateItemTooltip", Tooltips.CreateItemTooltip, data, "Root", Tooltips.ANCHOR_CURSOR, true)
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
            StockPiler.Inventory.LearnFromItemData(itemData, "tooltip")
        end
        return original(itemData, ...)
    end
    m_tooltipHooked = true
end

local m_invRefreshPending = false
StockPiler._deferInvLearn = false
StockPiler._deferUiRefresh = false
StockPiler._bagWorkDue = false
StockPiler._bagWorkAt = 0
StockPiler._bagNeedQueue = false
-- Harvest is one click per plot, typically ~1s apart. 0.4s flushed
-- between clicks and rebuilt the grow plan four times.
local BAG_WORK_COALESCE_SEC = 2.0

local function GameNow()
    if type(GetGameTime) == "function" then
        return tonumber(GetGameTime()) or 0
    end
    return 0
end

--- Debounce harvest/loot bag work. Each event pushes the flush out 2s.
--- needQueue: true after plots empty; false after refine/trade-skill bag noise.
function StockPiler.ScheduleBagWork(needQueue)
    StockPiler._bagWorkDue = true
    StockPiler._bagWorkAt = GameNow() + BAG_WORK_COALESCE_SEC
    StockPiler._deferInvLearn = true
    if needQueue ~= false then
        StockPiler._bagNeedQueue = true
    end
    if DoesWindowExist("StockPilerWindow") and WindowGetShowing("StockPilerWindow") then
        StockPiler._deferUiRefresh = true
    end
end

function StockPiler.BagWorkPending()
    return StockPiler._bagWorkDue == true
end

--- One snapshot after harvest clicks and harvest animations go quiet.
--- Plan rebuild waits for ProcessTick so we do not BuildPlan twice.
function StockPiler.FlushBagWorkIfDue()
    if StockPiler._bagWorkDue ~= true then
        return false
    end
    if StockPiler.AutoGrow
        and StockPiler.AutoGrow.HasHarvestInProgress
        and StockPiler.AutoGrow.HasHarvestInProgress()
    then
        StockPiler._bagWorkAt = GameNow() + BAG_WORK_COALESCE_SEC
        return false
    end
    if GameNow() < (tonumber(StockPiler._bagWorkAt) or 0) then
        return false
    end
    StockPiler._bagWorkDue = false
    if StockPiler.Perf and StockPiler.Perf.Begin then
        StockPiler.Perf.Begin("FlushBagWork")
    end
    if StockPiler.AutoGrow and StockPiler.AutoGrow.InvalidateBagCache then
        StockPiler.AutoGrow.InvalidateBagCache()
    end
    StockPiler._deferInvLearn = false
    if StockPiler.Inventory and StockPiler.Inventory.LearnNewFromBags then
        StockPiler.Inventory.LearnNewFromBags("bag-flush")
    end
    if StockPiler.Brew and StockPiler.Brew.OnInventoryDeferred then
        StockPiler.Brew.OnInventoryDeferred()
    end
    local needQueue = StockPiler._bagNeedQueue == true
    StockPiler._bagNeedQueue = false
    if needQueue and StockPiler.AutoGrow and StockPiler.AutoGrow.InvalidatePlantQueue then
        StockPiler.AutoGrow.InvalidatePlantQueue()
    end
    if StockPiler._deferUiRefresh == true then
        StockPiler._deferUiRefresh = false
        if StockPiler.AutoGrow then
            StockPiler.AutoGrow._watchUiDirty = true
        end
    end
    -- Snap-only flushes (refine/loot) must not re-arm refine; that rebuilt
    -- spec demand (~800ms) after the harvest plan was already built.
    if needQueue and StockPiler.AutoGrow and StockPiler.AutoGrow.MarkRefineDue then
        StockPiler.AutoGrow.MarkRefineDue()
    end
    if StockPiler.Perf and StockPiler.Perf.End then
        StockPiler.Perf.End("FlushBagWork")
    end
    return true
end

local function RefreshUiIfOpen()
    if DoesWindowExist("StockPilerWindow") and WindowGetShowing("StockPilerWindow") then
        if StockPilerWindow and StockPilerWindow.RefreshActiveTab then
            StockPilerWindow.RefreshActiveTab()
        end
    end
end

function StockPiler.OnInventoryUpdated()
    if StockPiler.Perf and StockPiler.Perf.Mark then
        StockPiler.Perf.Mark("OnInventoryUpdated")
    end
    if StockPiler.EnsureRefinementHook then
        StockPiler.EnsureRefinementHook()
    end
    if StockPiler.SeedMap and StockPiler.SeedMap.MaybeCompletePendingRefine then
        local refineResult = StockPiler.SeedMap.MaybeCompletePendingRefine()
        if type(refineResult) == "table" then
            if StockPiler.AutoGrow and StockPiler.AutoGrow.OnRefineComplete then
                StockPiler.AutoGrow.OnRefineComplete(refineResult.plantUid, refineResult.seedUid)
            end
            if StockPiler.SeedMap.RefreshHarvestWatchAfterBagChange then
                StockPiler.SeedMap.RefreshHarvestWatchAfterBagChange()
            end
            StockPiler.ScheduleBagWork(false)
        elseif StockPiler.AutoGrow then
            StockPiler.AutoGrow._autoRefinePending = nil
        end
    end
    local suppress = StockPiler.AutoGrow
        and tonumber(StockPiler.AutoGrow._suppressInvTicks) and StockPiler.AutoGrow._suppressInvTicks > 0
    if not suppress
        and StockPiler.SeedMap
        and StockPiler.SeedMap.MaybeCompletePendingHarvest
    then
        StockPiler.SeedMap.MaybeCompletePendingHarvest()
    end
    if StockPiler.Inventory and StockPiler.Inventory.MaybeCompletePendingCraftFromInventory then
        local learned = StockPiler.Inventory.MaybeCompletePendingCraftFromInventory()
        if learned then
            RefreshUiIfOpen()
        end
    end
    -- AutoGrow plant/refine sets suppress so bag noise does not rebuild the
    -- grow plan every second (that was a ~70ms hitch).
    if not suppress then
        if StockPiler.AutoGrow and StockPiler.AutoGrow.NeedsCurrentStageAdditive
            and StockPiler.AutoGrow.NeedsCurrentStageAdditive()
            and StockPiler.AutoGrow.MarkAdditiveDue
        then
            StockPiler.AutoGrow.MarkAdditiveDue()
        end
        -- Loot/vendor: resnap only. Plot-empty is what rebuilds the grow queue.
        StockPiler.ScheduleBagWork(false)
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
        StockPiler.AutoGrow.MarkAllPlotsWantFill()
    end
    if StockPiler.AutoGrow and StockPiler.AutoGrow.OnCraftingSlotUpdated then
        StockPiler.AutoGrow.OnCraftingSlotUpdated()
    end
    if StockPiler.Brew and StockPiler.Brew.OnCraftingSlotUpdated then
        StockPiler.Brew.OnCraftingSlotUpdated()
    end
end

function StockPiler.ProcessDeferredInventoryWork()
    if StockPiler.FlushBagWorkIfDue and StockPiler.FlushBagWorkIfDue() then
        return
    end
    if StockPiler.BagWorkPending and StockPiler.BagWorkPending() then
        return
    end
    if StockPiler._deferInvLearn ~= true and StockPiler._deferUiRefresh ~= true then
        return
    end
    if StockPiler.Perf and StockPiler.Perf.Begin then
        StockPiler.Perf.Begin("DeferredInv")
    end
    local bagsChanged = StockPiler._deferInvLearn == true
    if StockPiler._deferInvLearn == true then
        StockPiler._deferInvLearn = false
        if StockPiler.Inventory and StockPiler.Inventory.LearnNewFromBags then
            StockPiler.Inventory.LearnNewFromBags("bag-deferred")
        end
    end
    if bagsChanged and StockPiler.Brew and StockPiler.Brew.OnInventoryDeferred then
        StockPiler.Brew.OnInventoryDeferred()
    end
    if StockPiler._deferUiRefresh == true then
        StockPiler._deferUiRefresh = false
        if m_invRefreshPending then
            if StockPiler.Perf and StockPiler.Perf.End then
                StockPiler.Perf.End("DeferredInv")
            end
            return
        end
        m_invRefreshPending = true
        if StockPilerWindow and StockPilerWindow.RefreshActiveTab then
            StockPilerWindow.RefreshActiveTab()
        end
        m_invRefreshPending = false
    end
    if StockPiler.Perf and StockPiler.Perf.End then
        StockPiler.Perf.End("DeferredInv")
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
    if StockPiler.Buy and StockPiler.Buy.OnStoreUpdated then
        StockPiler.Buy.OnStoreUpdated()
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
            StockPiler.TryCall("StockPiler.OnGuildVaultOpen", StockPiler.OnGuildVaultOpen, vaultDataTable)
        end
    end
    local origUpdate = GuildVaultWindow.UpdateItemsInVault
    if type(origUpdate) == "function" then
        GuildVaultWindow.UpdateItemsInVault = function(vaultData)
            origUpdate(vaultData)
            StockPiler.TryCall("StockPiler.OnGuildVaultItemsUpdated", StockPiler.OnGuildVaultItemsUpdated, vaultData)
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
            StockPiler.TryCall("StockPiler.OnBankOpen", StockPiler.OnBankOpen)
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
            StockPiler.TryCall("StockPiler.OnStoreShow", StockPiler.OnStoreShow)
        end
    end
    local origUpdate = EA_Window_InteractionStore.UpdateStoreList
    if type(origUpdate) == "function" then
        EA_Window_InteractionStore.UpdateStoreList = function(...)
            origUpdate(...)
            StockPiler.TryCall("StockPiler.OnStoreShow", StockPiler.OnStoreShow)
        end
    end
    local origBuyback = EA_Window_InteractionStore.UpdateBuyBackList
    if type(origBuyback) == "function" then
        EA_Window_InteractionStore.UpdateBuyBackList = function(...)
            origBuyback(...)
            StockPiler.TryCall("StockPiler.OnStoreShow", StockPiler.OnStoreShow)
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
            StockPiler.TryCall("StockPiler.OnCraftingUpdated", StockPiler.OnCraftingUpdated)
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
                StockPiler.TryCall("StockPiler.SeedMap.BeginPendingRefine", StockPiler.SeedMap.BeginPendingRefine, itemData)
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
            -- Stock window Brew is never blocked. Unstable/incomplete
            -- checks apply only to the one-click brew macro.
            if StockPiler.Inventory and StockPiler.Inventory.BeginPendingCraft then
                StockPiler.TryCall("StockPiler.Inventory.BeginPendingCraft", StockPiler.Inventory.BeginPendingCraft)
            end
            origPerform()
        end
    end
    local origHide = ApothecaryWindow.Hide
    if type(origHide) == "function" then
        ApothecaryWindow.Hide = function(...)
            if StockPiler.Inventory and StockPiler.Inventory.CompletePendingCraftLearn
                and GameData and GameData.CraftingStatus and GameData.CraftingStates
                and tonumber(GameData.CraftingStatus.State) == GameData.CraftingStates.FAIL
            then
                StockPiler.TryCall("StockPiler.Inventory.CompletePendingCraftLearn",
                    StockPiler.Inventory.CompletePendingCraftLearn, { failed = true })
            end
            origHide(...)
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
        StockPiler.Inventory.EnforceProfessionGates()
    end
    local suppress = StockPiler.AutoGrow
        and tonumber(StockPiler.AutoGrow._suppressInvTicks)
        and StockPiler.AutoGrow._suppressInvTicks > 0
    -- Harvest/plant/refine fire this. Do not rebuild the grow plan here
    -- (that was a second 1s BuildPlan after FlushBagWork).
    if not suppress and StockPiler.ScheduleBagWork then
        StockPiler.ScheduleBagWork(false)
    end
end

function StockPiler.OnCraftingUpdated()
    StockPiler.EnsureCraftingHook()
    if StockPiler.Brew and StockPiler.Brew.OnCraftingUpdated then
        StockPiler.Brew.OnCraftingUpdated()
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
        StockPilerWindow.Initialize()
    end

    if StockPiler.AutoGrow and StockPiler.AutoGrow.Initialize then
        StockPiler.AutoGrow.Initialize()
    end

    if StockPiler.Brew and StockPiler.Brew.Initialize then
        StockPiler.Brew.Initialize()
    end

    if StockPiler.CraftChat and StockPiler.CraftChat.Initialize then
        StockPiler.CraftChat.Initialize()
    end

    if StockPilerMacro and StockPilerMacro.Initialize then
        StockPilerMacro.Initialize()
    end

    if StockPiler.SeedMap and StockPiler.SeedMap.ApplyPendingMapReset then
        StockPiler.SeedMap.ApplyPendingMapReset()
    end

    if StockPiler.SeedMap and StockPiler.SeedMap.EnsureSpecBootstrap then
        StockPiler.SeedMap.EnsureSpecBootstrap()
    end

    if StockPiler.SeedMap and StockPiler.SeedMap.RepairFromLearnedRecipes
        and StockPiler.SeedMap._growRepairDone ~= true
    then
        StockPiler.SeedMap._growRepairDone = true
        local repaired = tonumber(StockPiler.SeedMap.RepairFromLearnedRecipes()) or 0
        if repaired > 0 and StockPiler.Trace then
            StockPiler.Trace("Grow map recipe repair entries=" .. tostring(repaired))
        end
        if StockPiler.AutoGrow and StockPiler.AutoGrow.InvalidatePlantQueue then
            StockPiler.AutoGrow.InvalidatePlantQueue()
        end
    end

    if StockPiler.RecipeSpec and StockPiler.RecipeSpec.RepairIncompleteMainSpecs then
        local repaired = tonumber(StockPiler.RecipeSpec.RepairIncompleteMainSpecs()) or 0
        if repaired > 0 and StockPiler.Trace then
            StockPiler.Trace("Repaired " .. tostring(repaired) .. " incomplete main spec(s)")
        end
    end
    if StockPiler.RecipeSpec then
        if StockPiler.RecipeSpec.SlimAllRecipesForStorage then
            StockPiler.RecipeSpec.SlimAllRecipesForStorage()
        end
        if StockPiler.RecipeSpec.SlimAllPotionsForStorage then
            StockPiler.RecipeSpec.SlimAllPotionsForStorage()
        end
    end
    if StockPiler.RecipeSpec and StockPiler.RecipeSpec.ForgetKnownPotionsWithoutRecipe then
        local dropped = tonumber(StockPiler.RecipeSpec.ForgetKnownPotionsWithoutRecipe()) or 0
        if dropped > 0 and StockPiler.Trace then
            StockPiler.Trace("Dropped " .. tostring(dropped) .. " known potion(s) with no brewed recipe")
        end
    end
    if StockPiler.RecipeSpec and StockPiler.RecipeSpec.RepairRecipeYields then
        local fixed = tonumber(StockPiler.RecipeSpec.RepairRecipeYields()) or 0
        if fixed > 0 and StockPiler.Trace then
            StockPiler.Trace("Repaired " .. tostring(fixed) .. " recipe yield(s) from observed successes")
        end
    end

    if RegisterSlash() then
        local pb = (StockPiler.Classify and StockPiler.Classify.PotionBarAvailable and StockPiler.Classify.PotionBarAvailable()) and L"PotionBar=yes" or L"PotionBar=no"
        local pairsN = 0
        if StockPiler.SeedMap and StockPiler.SeedMap.CountLearnedGrowPairs then
            pairsN = StockPiler.SeedMap.CountLearnedGrowPairs() or 0
        end
        StockPiler.Print(L"v" .. StockPiler.Version .. L" loaded. /stockpiler | /stp seedmap | /stp growplan | /stp growwhy | /stp growtrace | /stp debug | /stp perf | "
            .. pb .. L" | grows=" .. towstring(tostring(pairsN)))
        StockPiler.D("Initialize v" .. tostring(StockPiler.Version)
            .. " DebugEnabled=" .. tostring(StockPiler.DebugEnabled)
            .. " GrowTrace=" .. tostring(StockPiler.AutoGrow and StockPiler.AutoGrow.TraceEnabled)
            .. " PotionBar=" .. tostring(StockPiler.Classify and StockPiler.Classify.PotionBarAvailable and StockPiler.Classify.PotionBarAvailable()))
    else
        StockPiler.Print(L"v" .. StockPiler.Version .. L" loaded (no LibSlash - enable LibSlash for /stockpiler).")
    end
end

function StockPiler.Shutdown()
    if StockPiler.RecipeSpec then
        if StockPiler.RecipeSpec.SlimAllRecipesForStorage then
            StockPiler.RecipeSpec.SlimAllRecipesForStorage()
        end
        if StockPiler.RecipeSpec.SlimAllPotionsForStorage then
            StockPiler.RecipeSpec.SlimAllPotionsForStorage()
        end
    end
    if type(StockPiler.Settings) == "table" then
        if StockPiler.PersistActiveCharacterSettings then
            StockPiler.PersistActiveCharacterSettings(StockPiler.Settings)
        end
        StockPiler.StripAccountFromSettings(StockPiler.Settings)
    end
    if StockPiler.AutoGrow and StockPiler.AutoGrow.Shutdown then
        StockPiler.AutoGrow.Shutdown()
    end
    if StockPiler.CraftChat and StockPiler.CraftChat.Shutdown then
        StockPiler.CraftChat.Shutdown()
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
