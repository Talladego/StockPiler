----------------------------------------------------------------
-- StockPiler Stores/KnowledgeStore - account learned-data facade
----------------------------------------------------------------

StockPiler = StockPiler or {}
StockPiler.Knowledge = StockPiler.Knowledge or {}
local Know = StockPiler.Knowledge

-- Same list Persistence allows through shutdown. Includes skillUpRates so
-- Ensure creates the table when a fresh account has not filled it yet.
local ACCOUNT_TABLES = StockPiler.Persistence.ACCOUNT_TABLES
    or { "items", "grows", "refines", "recipes", "potions", "skillUpRates" }

Know._gen = 0
Know._ensuring = false
-- Seen craft-relevant vendor uids this session only (not SavedVariables).
Know._sessionVendorItems = Know._sessionVendorItems or {}

local function IsAllowedTable(name)
    for i = 1, #ACCOUNT_TABLES do
        if ACCOUNT_TABLES[i] == name then
            return true
        end
    end
    return false
end

local function EnsureAccountTables(acct)
    if type(acct) ~= "table" then
        return false
    end
    for i = 1, #ACCOUNT_TABLES do
        local k = ACCOUNT_TABLES[i]
        if type(acct[k]) ~= "table" then
            acct[k] = {}
        end
    end
    return true
end

function Know.GetGen()
    return tonumber(Know._gen) or 0
end

--- Shape Account knowledge tables. Does not call Persistence.EnsureAccount
--- (that would recurse via GetAccount/Recipes during migrate).
function Know.Ensure()
    if Know._ensuring == true then
        return type(StockPiler.Account) == "table"
    end
    Know._ensuring = true
    local ok = false
    local acct = StockPiler.Account
    if type(acct) ~= "table" then
        -- Caller (Bootstrap / Persistence) must create Account first.
        Know._ensuring = false
        return false
    end
    ok = EnsureAccountTables(acct)
    Know._ensuring = false
    return ok
end

--- Idempotent: correct recoverable saved-data issues; drop irreparable rows.
--- Runs on load. /stp audit is report-only; /stp audit fix calls this.
function Know.ValidateAndRepairSavedData()
    local report = {
        itemsStamped = 0,
        recipesMerged = 0,
        recipesRemapped = 0,
        recipesDropped = 0,
        potionsDropped = 0,
        watchesDropped = 0,
        scrubbed = 0,
    }
    if StockPiler.Items and StockPiler.Items.ValidateAndRepairSavedItems then
        local ir = StockPiler.Items.ValidateAndRepairSavedItems()
        if type(ir) == "table" then
            report.itemsStamped = tonumber(ir.stamped) or 0
        end
    end
    local repairReport = nil
    if StockPiler.RecipeSpec and StockPiler.RecipeSpec.ValidateAndRepairSavedRecipes then
        repairReport = StockPiler.RecipeSpec.ValidateAndRepairSavedRecipes()
        if type(repairReport) == "table" then
            report.recipesMerged = tonumber(repairReport.merged) or 0
            report.recipesRemapped = tonumber(repairReport.remapped) or 0
            report.recipesDropped = tonumber(repairReport.dropped) or 0
            report.potionsDropped = tonumber(repairReport.potionsDropped) or 0
            report.watchesDropped = tonumber(repairReport.watchesDropped) or 0
            report.scrubbed = tonumber(repairReport.scrubbed) or 0
            report.droppedRecipeKeys = repairReport.droppedRecipeKeys
            report.droppedPotionKeys = repairReport.droppedPotionKeys
            report.droppedWatchKeys = repairReport.droppedWatchKeys
        end
    end
    local changed = (report.itemsStamped
        + report.recipesMerged
        + report.recipesRemapped
        + report.recipesDropped
        + report.potionsDropped
        + report.watchesDropped
        + report.scrubbed) > 0
    if changed and StockPiler.Knowledge.Touch then
        StockPiler.Knowledge.Touch("saved-data-repair")
    end
    if StockPiler.Debug and StockPiler.Debug.LogAlways then
        StockPiler.Debug.LogAlways(string.format(
            "validate| itemsStamped=%d recipesRemapped=%d merged=%d dropped=%d potionsDropped=%d watchesDropped=%d scrubbed=%d",
            report.itemsStamped,
            report.recipesRemapped,
            report.recipesMerged,
            report.recipesDropped,
            report.potionsDropped,
            report.watchesDropped,
            report.scrubbed
        ))
        local function logKeys(label, keys)
            if type(keys) ~= "table" or #keys == 0 then
                return
            end
            local n = math.min(#keys, 20)
            for i = 1, n do
                StockPiler.Debug.LogAlways(
                    string.format("validate| %s[%d]=%s", label, i, tostring(keys[i]))
                )
            end
            if #keys > n then
                StockPiler.Debug.LogAlways(
                    string.format("validate| %s ... +%d more (session RecipeSpec._repairQuarantine)", label, #keys - n)
                )
            end
        end
        logKeys("droppedRecipe", report.droppedRecipeKeys)
        logKeys("droppedPotion", report.droppedPotionKeys)
        logKeys("droppedWatch", report.droppedWatchKeys)
    end
    return report
end

--- Idempotent repair. Fingerprint V2-V4 and the plant-effect seed migrate are retired.
--- Their latches stay on old saves so validation still accepts them.
function Know.MigrateFingerprints()
    if StockPiler.RecipeSpec and StockPiler.RecipeSpec.FoldAlternateRecipeKeys then
        StockPiler.RecipeSpec.FoldAlternateRecipeKeys()
    end
    if StockPiler.RecipeSpec and StockPiler.RecipeSpec.MigrateFractionalRecipeYields then
        StockPiler.RecipeSpec.MigrateFractionalRecipeYields()
    end
    if StockPiler.RecipeSpec and StockPiler.RecipeSpec.MigratePotionTierFromItems then
        StockPiler.RecipeSpec.MigratePotionTierFromItems()
    end
    Know.ValidateAndRepairSavedData()
    if StockPiler.RecipeSpec and StockPiler.RecipeSpec.MigratePotionEffectKeys then
        StockPiler.RecipeSpec.MigratePotionEffectKeys()
    end
end

function Know.GetAccount()
    local acct = StockPiler.Account
    if type(acct) == "table" then
        EnsureAccountTables(acct)
        return acct
    end
    -- Create once; EnsureAccount must not re-enter GetAccount/Ensure migrate.
    if StockPiler.Persistence and StockPiler.Persistence.EnsureAccount then
        return StockPiler.Persistence.EnsureAccount()
    end
    return nil
end

function Know.GetTable(name)
    if type(name) ~= "string" or name == "" or not IsAllowedTable(name) then
        return nil
    end
    local acct = Know.GetAccount()
    if type(acct) ~= "table" then
        return nil
    end
    if type(acct[name]) ~= "table" then
        acct[name] = {}
    end
    return acct[name]
end

function Know.Items()
    return Know.GetTable("items")
end

function Know.Grows()
    return Know.GetTable("grows")
end

function Know.Refines()
    return Know.GetTable("refines")
end

function Know.Recipes()
    return Know.GetTable("recipes")
end

function Know.Potions()
    return Know.GetTable("potions")
end

--- Session-only vendor sightings. Persisting served no purpose: AutoBuy matches
--- the open store; Items.StoreItem already seeds Account.items for fingerprints.
function Know.VendorItems()
    if type(Know._sessionVendorItems) ~= "table" then
        Know._sessionVendorItems = {}
    end
    return Know._sessionVendorItems
end

function Know.Touch(reason)
    Know._gen = (tonumber(Know._gen) or 0) + 1
    if StockPiler.Debug and StockPiler.Debug.LogOp then
        StockPiler.Debug.LogOp("know", "touch gen=" .. tostring(Know._gen) .. " reason=" .. tostring(reason or ""))
    end
    local B = StockPiler.EventBus
    local E = StockPiler.Events
    if B and B.Fire and E and E.KNOWLEDGE_UPDATED then
        B.Fire(E.KNOWLEDGE_UPDATED, { reason = tostring(reason or ""), gen = Know._gen })
    end
end
