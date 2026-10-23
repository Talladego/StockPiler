----------------------------------------------------------------
-- StockPiler Persistence/Settings - profile + account ensure
----------------------------------------------------------------

StockPiler = StockPiler or {}
StockPiler.Persistence = StockPiler.Persistence or {}
local P = StockPiler.Persistence

-- vendorItems is session-only (see Knowledge.VendorItems); do not persist.
local ACCOUNT_TABLES = { "items", "grows", "refines", "recipes", "potions", "skillUpRates" }
P.ACCOUNT_TABLES = ACCOUNT_TABLES

-- Historical leak keys (settings flags written onto Account). Strip on load.
local ACCOUNT_LEAKED_SETTINGS_KEYS = {
    "growPlantSurplusSeeds",
    "autoGrowAdditives",
    "autoGrowEnabled",
    "autoBuyEnabled",
    "autoBrewEnabled",
    "autoBuyReserveGold",
    "autoBuyBudgetGold",
    "autoBuySpentBrass",
    "growSeedBufferMin",
    "growSeedBufferEnabled",
    "autoGrowPauseCombat",
    "watchOptimisticOutcomeEstimate",
    "brewMacroEnabled",
    "brewRespectGrowReserve",
    "brewPreferNonGrowableFirst",
    "watches",
    "characters",
    "debugEnabled",
    "eventTrace",
    "chatMode",
    "perfEnabled",
    "perfThresholdMs",
    "potionKnownRecipeOnly",
}

-- Must include every ACCOUNT_TABLES key or Shutdown StripUnexpectedAccountKeys
-- will delete them before SavedVariables write (wiped skillUpRates each reload).
-- accountVersion and the migrate latches stay so old saves still validate.
-- Nothing reads them to choose behavior.
local ACCOUNT_ALLOWED = {
    accountVersion = true,
    sp1Schema = true,
    recipeFingerprintMigrateV2 = true,
    recipeFingerprintMigrateV3 = true,
    recipeFingerprintMigrateV4 = true,
    recipeYieldIntegerMigrateV1 = true,
    plantEffectFromSeedMigrateV2 = true,
}
for i = 1, #ACCOUNT_TABLES do
    ACCOUNT_ALLOWED[ACCOUNT_TABLES[i]] = true
end

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

function P.CopyTable(value)
    if type(value) ~= "table" then
        return value
    end
    local copy = {}
    for k, v in pairs(value) do
        copy[k] = P.CopyTable(v)
    end
    return copy
end

-- NO potionKnownRecipeOnly - known-recipe filter omitted in SP.
StockPiler.DefaultSettings = {
    sp1Schema = 1,
    settingsVersion = 1,
    charactersVersion = 1,
    characters = {},
    debugEnabled = false,
    eventTrace = false,
    -- on | quiet | off. on keeps stall/ready lines; quiet is changes and harvest/brew.
    chatMode = "on",
    -- Craft button display scale (0.50–2.0). Default 1.0. /stp button / Watch chip.
    craftButtonScale = 1.0,
    -- Floating craft button: centered grow countdown. Default on.
    craftButtonShowTimer = true,
    -- Floating craft HUD visible (Watch tab: HUD Button). Default on.
    craftButtonVisible = true,
    -- Create/maintain StockPiler Craft macro (Watch: Craft Macro). Default on.
    -- Player places it on a hotbar; disable clears bars + deletes the macro.
    craftMacroEnabled = true,
    -- Lock lives in LayoutEditor.Settings[window].locked (Shift+LMB on HUD / HUD Editor).
    language = 0,
    selectedTab = 1,
    potionNameFilter = "",
    potionEffectFilter = "",
    potionSortColumn = "name",
    potionSortAscending = true,
    watchSortColumn = "name",
    watchSortAscending = true,
    plantSortColumn = "name",
    plantSortAscending = true,
    plantNameFilter = "",
    plantEffectFilter = "",
    plantLevelFilter = 0,
}

StockPiler.DefaultCharacterSettings = {
    watches = {},
    autoGrowEnabled = false,
    autoGrowAdditives = false,
    autoBuyEnabled = false,
    autoBrewEnabled = false,
    autoBuyReserveGold = 10,
    autoBuyBudgetGold = 50,
    autoBuySpentBrass = 0,
    growSeedBufferMin = 5,
    growSeedBufferEnabled = true,
    -- Hidden/legacy: no Watch UI. Off by default (was on).
    autoGrowPauseCombat = false,
    -- Watch: assume every brew yields the watched potion (off = rate-based).
    watchOptimisticOutcomeEstimate = true,
    brewMacroEnabled = false,
    brewRespectGrowReserve = true,
    -- Brew load: spend butcher/vendor twins before cult plants. Future UI toggle.
    brewPreferNonGrowableFirst = true,
    skillUpCultEnabled = false,
    skillUpApoEnabled = false,
    lastCultSkill = 0,
    lastApoSkill = 0,
    upgradeSeedsEnabled = false,
    plantWatches = {},
    -- false until Watch.MigratePriorityTiersIfNeeded assigns tiers.
    watchPriorityTiersMigrated = false,
}

StockPiler.DefaultAccount = {
    sp1Schema = 1,
    accountVersion = 3,
    items = {},
    grows = {},
    refines = {},
    recipes = {},
    potions = {},
    skillUpRates = { v = 3, cult = {}, apo = {} },
}

function P.ToNarrow(value)
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
        local ok, text
        if StockPiler.Debug and StockPiler.Debug.TryCallQuiet then
            ok, text = StockPiler.Debug.TryCallQuiet("ToNarrow", WStringToString, value)
        else
            ok, text = pcall(WStringToString, value)
        end
        if ok and type(text) == "string" then
            return text
        end
        return ""
    end
    return tostring(value)
end

--- Character key = player name with trailing ^realm markup stripped.
function P.GetCharacterKey()
    if GameData and GameData.Player and GameData.Player.name then
        local name = GameData.Player.name
        if type(name) == "wstring" then
            local narrow = P.ToNarrow(name)
            if type(narrow) == "string" and narrow ~= "" then
                if string.len(narrow) >= 2 and string.sub(narrow, -2, -2) == "^" then
                    narrow = string.sub(narrow, 1, -3)
                end
                narrow = string.gsub(narrow, "%^.*$", "")
                narrow = string.gsub(narrow, "^%s+", "")
                narrow = string.gsub(narrow, "%s+$", "")
                if narrow ~= "" then
                    return narrow
                end
            end
        elseif type(name) == "string" and name ~= "" then
            local narrow = name
            if string.len(narrow) >= 2 and string.sub(narrow, -2, -2) == "^" then
                narrow = string.sub(narrow, 1, -3)
            end
            narrow = string.gsub(narrow, "%^.*$", "")
            if narrow ~= "" then
                return narrow
            end
        end
    end
    return "_default"
end

function P.EnsureSettings()
    local s = StockPiler.Settings
    if type(s) ~= "table" or (s.sp1Schema ~= 1 and s.settingsVersion ~= 1) then
        s = P.CopyTable(StockPiler.DefaultSettings)
        StockPiler.Settings = s
    end
    s.sp1Schema = 1
    -- Kept on the save. Not used to choose behavior.
    if s.settingsVersion == nil then
        s.settingsVersion = 1
    end
    if s.charactersVersion == nil then
        s.charactersVersion = 1
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
    if s.potionSortColumn == nil then
        s.potionSortColumn = "name"
    end
    if s.potionSortAscending == nil then
        s.potionSortAscending = true
    end
    if s.watchSortColumn == nil or (s.watchSortUserSet ~= true and s.watchSortColumn == "prio") then
        s.watchSortColumn = "name"
    end
    if s.watchSortAscending == nil then
        s.watchSortAscending = true
    end
    if s.plantSortColumn == nil then
        s.plantSortColumn = "name"
    end
    if s.plantSortAscending == nil then
        s.plantSortAscending = true
    end
    if s.plantNameFilter == nil then
        s.plantNameFilter = ""
    end
    if s.plantEffectFilter == nil then
        s.plantEffectFilter = ""
    end
    if s.plantLevelFilter == nil then
        s.plantLevelFilter = 0
    end
    if s.selectedTab == nil then
        s.selectedTab = 1
    end
    if s.language == nil then
        s.language = 0
    end
    -- Explicitly drop known-filter if somehow present in old SV.
    if s.potionKnownRecipeOnly ~= nil then
        s.potionKnownRecipeOnly = nil
    end
    -- Removed UI: SkillUp Apo no longer learns potions.
    if s.potionHideSkillUp ~= nil then
        s.potionHideSkillUp = nil
    end
    if s.perfEnabled ~= nil then
        s.perfEnabled = nil
    end
    if s.perfThresholdMs ~= nil then
        s.perfThresholdMs = nil
    end
    if s.chatMode ~= "on" and s.chatMode ~= "quiet" and s.chatMode ~= "off" then
        s.chatMode = "on"
    end
    do
        -- Migrate former craftBadgeScale key.
        if s.craftButtonScale == nil and s.craftBadgeScale ~= nil then
            s.craftButtonScale = s.craftBadgeScale
        end
        s.craftBadgeScale = nil
        local scale = tonumber(s.craftButtonScale)
        if scale == nil then
            scale = 1.0
        end
        if scale < 0.5 then
            scale = 0.5
        elseif scale > 2 then
            scale = 2
        end
        s.craftButtonScale = scale
    end
    -- Migrate brief craftMacroTimerCenter key (was wrongly applied to macros).
    if s.craftButtonShowTimer == nil and s.craftMacroTimerCenter ~= nil then
        s.craftButtonShowTimer = s.craftMacroTimerCenter == true
    end
    s.craftMacroTimerCenter = nil
    if s.craftButtonShowTimer == nil then
        s.craftButtonShowTimer = true
    end
    s.craftButtonShowTimer = s.craftButtonShowTimer == true
    if s.craftButtonVisible == nil then
        s.craftButtonVisible = true
    end
    s.craftButtonVisible = s.craftButtonVisible ~= false
    if s.craftMacroEnabled == nil then
        s.craftMacroEnabled = true
    end
    s.craftMacroEnabled = s.craftMacroEnabled ~= false
    -- Legacy lock flag. Do not copy it into Layout Editor: upgrades stay unlocked
    -- until the player locks the button (Shift+click or the editor).
    s.craftButtonLockPosition = nil
    if StockPiler.Debug then
        StockPiler.Debug.Enabled = s.debugEnabled == true
        StockPiler.Debug.EventTrace = s.eventTrace == true
        StockPiler.Debug.ChatMode = s.chatMode
    end
    return s
end

function P.EnsureCharacterBucketShape(char)
    if type(char) ~= "table" then
        char = {}
    end
    local defaults = StockPiler.DefaultCharacterSettings
    for k, v in pairs(defaults) do
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
    char.autoBrewEnabled = char.autoBrewEnabled == true
    char.brewMacroEnabled = char.brewMacroEnabled == true
    char.brewRespectGrowReserve = char.brewRespectGrowReserve ~= false
    char.brewPreferNonGrowableFirst = char.brewPreferNonGrowableFirst ~= false
    char.growSeedBufferEnabled = char.growSeedBufferEnabled ~= false
    char.autoGrowPauseCombat = char.autoGrowPauseCombat == true
    char.watchOptimisticOutcomeEstimate = char.watchOptimisticOutcomeEstimate ~= false
    char.skillUpCultEnabled = char.skillUpCultEnabled == true
    char.skillUpApoEnabled = char.skillUpApoEnabled == true
    char.lastCultSkill = math.max(0, math.floor(tonumber(char.lastCultSkill) or 0))
    char.lastApoSkill = math.max(0, math.floor(tonumber(char.lastApoSkill) or 0))
    char.upgradeSeedsEnabled = char.upgradeSeedsEnabled == true
    char.autoBuyReserveGold = ClampInt(char.autoBuyReserveGold, 1, 99, 10)
    char.autoBuyBudgetGold = ClampInt(char.autoBuyBudgetGold, 1, 999, 50)
    do
        local spent = tonumber(char.autoBuySpentBrass)
        if spent == nil or spent < 0 then
            char.autoBuySpentBrass = 0
        else
            char.autoBuySpentBrass = math.floor(spent)
        end
    end
    char.growSeedBufferMin = ClampInt(char.growSeedBufferMin, 4, 20, 5)
    if type(char.plantWatches) ~= "table" then
        char.plantWatches = {}
    end
    char.watchPriorityTiersMigrated = char.watchPriorityTiersMigrated == true
    local retired = {}
    for k in pairs(char) do
        if defaults[k] == nil then
            retired[#retired + 1] = k
        end
    end
    for i = 1, #retired do
        char[retired[i]] = nil
    end
    return char
end

function P.GetCharacterBucket(create)
    local settings = P.EnsureSettings()
    settings.characters = type(settings.characters) == "table" and settings.characters or {}
    local key = P.GetCharacterKey()
    local row = settings.characters[key]
    if type(row) ~= "table" then
        if create == false then
            return nil, key
        end
        row = P.CopyTable(StockPiler.DefaultCharacterSettings)
        settings.characters[key] = row
    end
    return P.EnsureCharacterBucketShape(row), key
end

-- Window controls only. Slash-only prefs (debug, chat, event trace, language)
-- and schema versions stay. Watches include each row's checked/enabled state.
local UI_GLOBAL_KEYS = {
    "craftButtonScale",
    "craftButtonShowTimer",
    "craftButtonVisible",
    "craftMacroEnabled",
    "selectedTab",
    "potionNameFilter",
    "potionEffectFilter",
    "potionSortColumn",
    "potionSortAscending",
    "watchSortColumn",
    "watchSortAscending",
    "plantSortColumn",
    "plantSortAscending",
    "plantNameFilter",
    "plantEffectFilter",
    "plantLevelFilter",
}

-- Watch-tab toggles and the two watch lists. Not stats, spend history, or
-- hidden planner flags (see the comment on ResetSettingsToDefaults).
local UI_CHARACTER_KEYS = {
    "watches",
    "plantWatches",
    "autoGrowEnabled",
    "autoGrowAdditives",
    "autoBuyEnabled",
    "autoBrewEnabled",
    "autoBuyReserveGold",
    "autoBuyBudgetGold",
    "growSeedBufferMin",
    "growSeedBufferEnabled",
    "watchOptimisticOutcomeEstimate",
    "skillUpCultEnabled",
    "skillUpApoEnabled",
    "upgradeSeedsEnabled",
}

--- Reset settings the window shows, plus watches (checked state included).
--- Does not replace the settings table.
--- Preserves Account (items, grows, refines, recipes, potions, skillUpRates
--- and migrate latches), other characters, and on this character:
--- lastCultSkill, lastApoSkill, autoBuySpentBrass, watchPriorityTiersMigrated,
--- autoGrowPauseCombat, brewPreferNonGrowableFirst, brewMacroEnabled,
--- brewRespectGrowReserve.
--- Also preserves debugEnabled, eventTrace, chatMode, and language.
function P.ResetSettingsToDefaults()
    local s = P.EnsureSettings()
    local defaults = StockPiler.DefaultSettings
    for i = 1, #UI_GLOBAL_KEYS do
        local key = UI_GLOBAL_KEYS[i]
        s[key] = P.CopyTable(defaults[key])
    end
    s.craftButtonLockPosition = nil
    s.craftBadgeScale = nil
    s.craftMacroTimerCenter = nil
    local char = P.GetCharacterBucket(true)
    local cdef = StockPiler.DefaultCharacterSettings
    if type(char) == "table" and type(cdef) == "table" then
        for i = 1, #UI_CHARACTER_KEYS do
            local key = UI_CHARACTER_KEYS[i]
            char[key] = P.CopyTable(cdef[key])
        end
    end
    return P.EnsureSettings()
end

function P.EnsureAccount()
    local a = StockPiler.Account
    if type(a) ~= "table" or (a.sp1Schema ~= 1 and a.accountVersion ~= 3) then
        a = P.CopyTable(StockPiler.DefaultAccount)
        StockPiler.Account = a
    end
    a.sp1Schema = 1
    if a.accountVersion == nil then
        a.accountVersion = 3
    end
    for i = 1, #ACCOUNT_TABLES do
        local k = ACCOUNT_TABLES[i]
        if type(a[k]) ~= "table" then
            a[k] = {}
        end
    end
    for i = 1, #ACCOUNT_LEAKED_SETTINGS_KEYS do
        local k = ACCOUNT_LEAKED_SETTINGS_KEYS[i]
        if a[k] ~= nil then
            a[k] = nil
        end
    end
    -- Drop legacy persisted vendor catalog (session-only now; AutoBuy uses live store).
    if a.vendorItems ~= nil then
        a.vendorItems = nil
    end
    -- Plot additives live on the cultivator. Nothing reads Account.additives.
    if a.additives ~= nil then
        a.additives = nil
    end
    -- Only shape knowledge tables here - never migrate (would recurse via
    -- Recipes->GetAccount->EnsureAccount). Bootstrap calls MigrateFingerprints after.
    if StockPiler.Knowledge and StockPiler.Knowledge.Ensure then
        StockPiler.Knowledge.Ensure()
    end
    return a
end

--- Report unexpected Account top-level keys (for /stp audit).
function P.AuditAccountKeys()
    local a = StockPiler.Account
    local unexpected = {}
    if type(a) ~= "table" then
        return unexpected
    end
    for k, _ in pairs(a) do
        if ACCOUNT_ALLOWED[k] ~= true then
            unexpected[#unexpected + 1] = tostring(k)
        end
    end
    table.sort(unexpected)
    return unexpected
end

function P.StripUnexpectedAccountKeys()
    local a = StockPiler.Account
    if type(a) ~= "table" then
        return 0
    end
    local n = 0
    local removed = {}
    for k, _ in pairs(a) do
        if ACCOUNT_ALLOWED[k] ~= true then
            removed[#removed + 1] = tostring(k)
            a[k] = nil
            n = n + 1
        end
    end
    if n > 0 and StockPiler.Debug and StockPiler.Debug.LogOp then
        StockPiler.Debug.LogOp("persist", "strip-account-keys n=" .. tostring(n)
            .. " keys=" .. table.concat(removed, ","))
    end
    return n
end
