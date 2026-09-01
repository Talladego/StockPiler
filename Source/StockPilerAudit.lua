----------------------------------------------------------------
-- StockPilerAudit — saved-data health report (/stp audit)
----------------------------------------------------------------

StockPiler.Audit = StockPiler.Audit or {}

local function AccountTable(key)
    local a = StockPiler.Account
    if type(a) ~= "table" then
        return {}
    end
    if type(a[key]) ~= "table" then
        a[key] = {}
    end
    return a[key]
end

local function TableSize(t)
    local n = 0
    if type(t) ~= "table" then
        return 0
    end
    for _ in pairs(t) do
        n = n + 1
    end
    return n
end

local function CountEnabledWatches(s)
    local n = 0
    if type(s) ~= "table" or type(s.watches) ~= "table" then
        return 0
    end
    for _, watch in pairs(s.watches) do
        if type(watch) == "table" and watch.enabled == true then
            n = n + 1
        end
    end
    return n
end

local function LookupItemName(uid)
    uid = tonumber(uid) or 0
    if uid <= 0 then
        return nil, nil
    end
    if StockPiler.Items and StockPiler.Items.Get then
        local row = StockPiler.Items.Get(uid)
        if type(row) == "table" then
            return row.name, row.nameNarrow
        end
    end
    if type(GetDatabaseItemData) == "function" then
        local ok, data = StockPiler.TryCallQuiet("GetDatabaseItemData", GetDatabaseItemData, uid)
        if ok and type(data) == "table" then
            return data.name, nil
        end
    end
    return nil, nil
end

local function ByproductLooksInvalid(plantUid, uid, row)
    local samples = type(row) == "table" and (tonumber(row.samples) or 0) or 0
    local countSum = type(row) == "table" and (tonumber(row.countSum) or 0) or 0
    if samples <= 0 and countSum <= 0 then
        return true
    end
    if StockPiler.SeedMap and StockPiler.SeedMap.GrowNamesRelated then
        local plantName = LookupItemName(plantUid)
        local seedName = LookupItemName(uid)
        if plantName and seedName then
            return not StockPiler.SeedMap.GrowNamesRelated(plantName, seedName)
        end
    end
    return false
end

local function CountOrphanRefineByproducts()
    local refines = AccountTable("refines")
    local orphans = 0
    for plantKey, entry in pairs(refines) do
        if type(entry) == "table" and type(entry.byproducts) == "table" then
            local plantUid = tonumber(plantKey) or 0
            for uidKey, row in pairs(entry.byproducts) do
                local uid = tonumber(uidKey) or 0
                if uid > 0 and ByproductLooksInvalid(plantUid, uid, row) then
                    orphans = orphans + 1
                end
            end
        end
    end
    return orphans
end

function StockPiler.Audit.Run(opts)
    opts = opts or {}
    local fix = opts.fix == true
    local lines = {}

    local s = StockPiler.EnsureSettings and StockPiler.EnsureSettings() or StockPiler.Settings
    local enabledWatches = CountEnabledWatches(s)
    local autoGrow = type(s) == "table" and s.autoGrowEnabled == true
    local windowOpen = DoesWindowExist("StockPilerWindow") and WindowGetShowing("StockPilerWindow")
    local snapGen = StockPiler.Inventory and tonumber(StockPiler.Inventory._snapshotGen) or 0
    local queueDirty = StockPiler.AutoGrow and StockPiler.AutoGrow._plantQueueDirty == true

    lines[#lines + 1] = string.format(
        "character watches=%d autoGrow=%s window=%s snap=%d queueDirty=%s",
        enabledWatches,
        tostring(autoGrow),
        windowOpen and "open" or "closed",
        snapGen,
        tostring(queueDirty)
    )

    local items = AccountTable("items")
    local grows = AccountTable("grows")
    local refines = AccountTable("refines")
    lines[#lines + 1] = string.format(
        "account items=%d grows=%d refines=%d",
        TableSize(items),
        TableSize(grows),
        TableSize(refines)
    )

    local orphans = CountOrphanRefineByproducts()
    if fix then
        local pruned = 0
        if StockPiler.SeedMap and StockPiler.SeedMap.PruneOrphanRefineByproducts then
            pruned = tonumber(StockPiler.SeedMap.PruneOrphanRefineByproducts()) or 0
        end
        lines[#lines + 1] = string.format("orphanRefineByproducts pruned=%d (had %d)", pruned, orphans)
        if StockPiler.Planner and StockPiler.Planner.InvalidatePlanCache then
            StockPiler.Planner.InvalidatePlanCache()
        end
        if StockPiler.AutoGrow then
            StockPiler.AutoGrow._watchUiLastKey = nil
        end
    else
        lines[#lines + 1] = string.format("orphanRefineByproducts=%d (/stp audit fix to prune)", orphans)
    end

    if StockPiler.RecipeSpec then
        local RS = StockPiler.RecipeSpec
        if RS.RepairDuplicateRecipeFingerprints then
            local deduped = tonumber(RS.RepairDuplicateRecipeFingerprints()) or 0
            if deduped > 0 then
                lines[#lines + 1] = "repaired duplicate recipe fingerprints=" .. tostring(deduped)
            end
        end
        if RS.RepairIncompleteMainSpecs then
            local repaired = tonumber(RS.RepairIncompleteMainSpecs()) or 0
            if repaired > 0 then
                lines[#lines + 1] = "repaired incomplete main specs=" .. tostring(repaired)
            end
        end
    end

    for i = 1, #lines do
        if StockPiler.D then
            StockPiler.D("Audit| " .. lines[i])
        end
        if StockPiler.Print then
            StockPiler.Print(L"Audit: " .. towstring(lines[i]))
        end
    end
    return lines
end
