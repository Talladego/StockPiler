----------------------------------------------------------------
-- StockPilerNotify - CustomUI-style chat status messages
----------------------------------------------------------------

local PREFIX_TEXT = "StockPiler"
local PREFIX_COLOR = { 170, 220, 170 }

local function ToNarrow(text)
    return StockPiler.ToNarrow(text)
end

local function AsWString(text)
    if type(text) == "wstring" then
        return text
    end
    if type(text) == "string" then
        return towstring(text)
    end
    if text == nil then
        return L""
    end
    return towstring(tostring(text))
end

local function GetSettings()
    if StockPiler.EnsureSettings then
        return StockPiler.EnsureSettings()
    end
    return StockPiler.Settings
end

function StockPiler.StatusChatMode()
    local s = GetSettings()
    local mode = s and s.statusChat
    if mode == "all" or mode == "quiet" or mode == "off" then
        return mode
    end
    if s and s.statusMessages == false then
        return "off"
    end
    return "all"
end

--- Any automatic status chat (all or quiet). Slash Print() always works.
function StockPiler.StatusMessagesEnabled()
    return StockPiler.StatusChatMode() ~= "off"
end

--- Plant / harvest / stage / learn spam (all only).
function StockPiler.StatusMessagesVerbose()
    return StockPiler.StatusChatMode() == "all"
end

--- Manual toggles (enable AutoGrow, additives, AutoBuy) — all and quiet.
function StockPiler.StatusMessagesManual()
    local mode = StockPiler.StatusChatMode()
    return mode == "all" or mode == "quiet"
end

local function ChatPrefix(includeSpace)
    local coloredPartRaw = string.format(
        "<LINK data=\"0\" color=\"%d,%d,%d\" text=\"%s\">",
        PREFIX_COLOR[1],
        PREFIX_COLOR[2],
        PREFIX_COLOR[3],
        PREFIX_TEXT
    )
    local prefix = L"[" .. towstring(coloredPartRaw) .. L"]"
    if includeSpace then
        prefix = prefix .. L" "
    end
    return prefix
end

local function EmitChat(message)
    if type(message) == "string" then
        message = towstring(message)
    end
    if type(message) ~= "wstring" then
        return
    end

    local output = ChatPrefix(true) .. message
    if EA_ChatWindow and EA_ChatWindow.Print then
        local filter = SystemData and SystemData.SystemLogFilters and SystemData.SystemLogFilters.GENERAL or 0
        EA_ChatWindow.Print(output, filter)
        return
    end
    if TextLogAddEntry then
        TextLogAddEntry("System", 0, output)
    end
end

function StockPiler.Notify(message)
    if not StockPiler.StatusMessagesVerbose() then
        return
    end
    EmitChat(AsWString(message))
end

function StockPiler.NotifyFeature(featureName, message)
    if not StockPiler.StatusMessagesVerbose() then
        return
    end
    featureName = AsWString(featureName)
    message = AsWString(message)
    if featureName == L"" then
        EmitChat(message)
        return
    end
    if message == L"" then
        EmitChat(featureName)
        return
    end
    EmitChat(featureName .. L": " .. message)
end

--- Manual feature toggles (AutoGrow/Additives/AutoBuy on/off). Shown in quiet mode.
function StockPiler.NotifyManual(featureName, message)
    if not StockPiler.StatusMessagesManual() then
        return
    end
    featureName = AsWString(featureName)
    message = AsWString(message)
    if featureName == L"" then
        EmitChat(message)
        return
    end
    if message == L"" then
        EmitChat(featureName)
        return
    end
    EmitChat(featureName .. L": " .. message)
end

function StockPiler.ItemDisplayName(uniqueID, fallback)
    uniqueID = tonumber(uniqueID) or 0
    if uniqueID > 0 and StockPiler.Inventory and StockPiler.Inventory.CountByUniqueId then
        local _, sample = StockPiler.Inventory.CountByUniqueId(uniqueID)
        if type(sample) == "table" and sample.name and sample.name ~= L"" then
            return sample.name
        end
    end
    if uniqueID > 0 then
        if StockPiler.Items and StockPiler.Items.AsItemData then
            local data = StockPiler.Items.AsItemData(uniqueID)
            if type(data) == "table" and data.name and data.name ~= L"" then
                return data.name
            end
        end
        local s = GetSettings()
        local potions = type(s) == "table" and (s.potions or s.knownPotions) or nil
        if type(potions) == "table" then
            local pot = potions["uid:" .. tostring(uniqueID)]
            if type(pot) == "table" and pot.name and pot.name ~= L"" then
                return pot.name
            end
        end
        if GetDatabaseItemData then
            local ok, data = StockPiler.TryCallQuiet("GetDatabaseItemData", GetDatabaseItemData, uniqueID)
            if ok and type(data) == "table" and data.name and data.name ~= L"" then
                return data.name
            end
        end
    end
    if fallback ~= nil then
        return AsWString(fallback)
    end
    if uniqueID > 0 then
        return towstring(tostring(uniqueID))
    end
    return L"item"
end

function StockPiler.NotifySeedLearned(plantUid, seedUid, source)
    if not StockPiler.StatusMessagesVerbose() then
        return
    end
    local plantName = StockPiler.ItemDisplayName(plantUid, nil)
    local seedName = StockPiler.ItemDisplayName(seedUid, nil)
    local detail = plantName .. L" -> " .. seedName
    if source == "refine" then
        StockPiler.NotifyFeature(L"Learned", L"Converted " .. detail .. L".")
    else
        StockPiler.NotifyFeature(L"Learned", L"Seed map " .. detail .. L".")
    end
end

function StockPiler.NotifyAdditiveLearned(itemData, info)
    if not StockPiler.StatusMessagesVerbose() or type(itemData) ~= "table" then
        return
    end
    local name = itemData.name
    if name == nil or name == L"" then
        name = StockPiler.ItemDisplayName(itemData.uniqueID, itemData.name)
    end
    local role = L"additive"
    if StockPiler.Additives and StockPiler.Additives.RoleLabel then
        role = StockPiler.Additives.RoleLabel(info and info.role)
    end
    StockPiler.NotifyFeature(L"Learned", role .. L" " .. AsWString(name) .. L".")
end

function StockPiler.NotifyAutoGrowAdditive(plotNum, item, info)
    if not StockPiler.StatusMessagesVerbose() then
        return
    end
    local name = item and item.name or L"additive"
    local role = L""
    if StockPiler.Additives and StockPiler.Additives.RoleLabel and info then
        role = StockPiler.Additives.RoleLabel(info.role) .. L" "
    end
    StockPiler.NotifyFeature(
        L"AutoGrow",
        L"Plot " .. towstring(tostring(plotNum)) .. L": added " .. role .. AsWString(name) .. L"."
    )
end

function StockPiler.NotifyRecipeLearned(output)
    if not StockPiler.StatusMessagesVerbose() or type(output) ~= "table" then
        return
    end
    local name = output.name
    if name == nil or name == L"" then
        name = StockPiler.ItemDisplayName(output.uniqueID, output.nameNarrow)
    end
    StockPiler.NotifyFeature(L"Learned", L"Recipe for " .. AsWString(name) .. L".")
end

local COLLECT_SKIP_SOURCES = {
    tooltip = true,
    auction = true,
    guildvault = true,
    ["guildvault-open"] = true,
    bank = true,
    store = true,
    ["craft-slot"] = true,
    ["refine-plant"] = true,
    ["refine-seed"] = true,
    scan = true,
    ["debugscan"] = true,
}

function StockPiler.ShouldNotifyCollection(source)
    if not StockPiler.StatusMessagesVerbose() then
        return false
    end
    if source == nil or source == "" then
        return true
    end
    return COLLECT_SKIP_SOURCES[source] ~= true
end

function StockPiler.NotifyItemCollected(record, bucket, source)
    if not StockPiler.ShouldNotifyCollection(source) or type(record) ~= "table" then
        return
    end
    local name = record.name
    if name == nil or name == L"" then
        name = StockPiler.ItemDisplayName(record.uniqueID, record.nameNarrow)
    else
        name = AsWString(name)
    end
    if bucket == "observedPotions" or bucket == "potions" or bucket == "potion" then
        StockPiler.NotifyFeature(L"Collected", L"Potion " .. name .. L".")
    else
        StockPiler.NotifyFeature(L"Collected", L"Material " .. name .. L".")
    end
end

function StockPiler.NotifyAutoGrowState(enabled, queue)
    if not StockPiler.StatusMessagesManual() then
        return
    end
    if enabled ~= true then
        StockPiler.NotifyManual(L"AutoGrow", L"disabled.")
        return
    end

    if StockPiler.Planner and StockPiler.Planner.FormatGrowQueueText then
        local summary = StockPiler.Planner.FormatGrowQueueText(queue, 3)
        if summary and summary ~= L"" then
            StockPiler.NotifyManual(L"AutoGrow", L"enabled. " .. summary)
            return
        end
    end

    StockPiler.NotifyManual(L"AutoGrow", L"enabled. No plantable seeds in the current plan.")
end

function StockPiler.NotifyAutoGrowStage(plotNum, plantName, stageLabel, readyToHarvest)
    if not StockPiler.StatusMessagesVerbose() then
        return
    end
    if readyToHarvest ~= true then
        return
    end
    plantName = AsWString(plantName)
    local detail = L"Plot " .. towstring(tostring(plotNum)) .. L" " .. plantName .. L": Ready to harvest."
    StockPiler.NotifyFeature(L"AutoGrow", detail)
end

function StockPiler.NotifyAutoGrowRefined(plantUid, seedUid)
    if not StockPiler.StatusMessagesVerbose() then
        return
    end
    local plantName = StockPiler.ItemDisplayName(plantUid, nil)
    local seedName = StockPiler.ItemDisplayName(seedUid, nil)
    StockPiler.NotifyFeature(L"AutoGrow", L"Converted " .. plantName .. L" -> " .. seedName .. L".")
end

function StockPiler.NotifyAutoGrowHarvested(plotNum, plantName, manual)
    if not StockPiler.StatusMessagesVerbose() then
        return
    end
    plantName = AsWString(plantName)
    local detail = L"Harvested plot " .. towstring(tostring(plotNum)) .. L" (" .. plantName .. L")."
    StockPiler.NotifyFeature(L"AutoGrow", detail)
end

--- Planted plot lines. Verbose chat only (was always Print).
function StockPiler.NotifyAutoGrowPlanted(plotNum, entry, reason)
    if not StockPiler.StatusMessagesVerbose() then
        return
    end
    plotNum = tonumber(plotNum) or 0
    local seedName = L"seed"
    if type(entry) == "table" then
        if entry.seedName and entry.seedName ~= L"" then
            seedName = AsWString(entry.seedName)
        elseif entry.seedKey and entry.seedKey ~= "" then
            seedName = AsWString(entry.seedKey)
        end
    end
    local why = L"for watched potion stock"
    if type(entry) == "table" and (entry.bufferGrow == true or entry.plantReason == "seed_buffer") then
        local have = tonumber(entry.seedHave) or 0
        local buf = 4
        if StockPiler.Planner and StockPiler.Planner.GetSeedBufferMin then
            buf = StockPiler.Planner.GetSeedBufferMin()
        end
        why = L"to refill the seed buffer ("
            .. towstring(tostring(have))
            .. L"/"
            .. towstring(tostring(buf))
            .. L")"
    elseif type(entry) == "table" then
        local details = entry.watchDetails
        local parts = {}
        if type(details) == "table" then
            table.sort(details, function(a, b)
                return (tonumber(a.deficit) or 0) > (tonumber(b.deficit) or 0)
            end)
            local n = #details
            if n > 2 then
                n = 2
            end
            for i = 1, n do
                local d = details[i]
                local name = AsWString(d.name or L"potion")
                local have = tonumber(d.have) or 0
                local target = tonumber(d.target) or 0
                parts[#parts + 1] = name
                    .. L" ("
                    .. towstring(tostring(have))
                    .. L"/"
                    .. towstring(tostring(target))
                    .. L")"
            end
            if #details > 2 then
                parts[#parts + 1] = L"and others"
            end
        elseif type(entry.watchNames) == "table" then
            local n = #entry.watchNames
            if n > 2 then
                n = 2
            end
            for i = 1, n do
                parts[#parts + 1] = AsWString(entry.watchNames[i])
            end
            if #entry.watchNames > 2 then
                parts[#parts + 1] = L"and others"
            end
        end
        if #parts > 0 then
            local joined = parts[1]
            for i = 2, #parts do
                if parts[i] == L"and others" then
                    joined = joined .. L" " .. parts[i]
                else
                    joined = joined .. L", " .. parts[i]
                end
            end
            why = L"for " .. joined
        elseif tonumber(entry.matNeed) and tonumber(entry.matNeed) > 0 then
            why = L"for watched potion stock ("
                .. towstring(tostring(entry.matHave or 0))
                .. L"/"
                .. towstring(tostring(entry.matNeed))
                .. L" plants)"
        end
    end
    if reason == "harvest" then
        why = why .. L" after harvest"
    end
    EmitChat(
        L"AutoGrow: planted "
            .. seedName
            .. L" on plot "
            .. towstring(tostring(plotNum))
            .. L" "
            .. why
            .. L"."
    )
end

local function FlattenBlockers(blockers)
    local items = {}
    local seen = {}
    local function take(list)
        if type(list) ~= "table" then
            return
        end
        for i = 1, #list do
            local item = list[i]
            if type(item) == "table" then
                local name = AsWString(item.name or L"")
                local id = string.lower(ToNarrow(name))
                if id ~= "" and seen[id] ~= true then
                    seen[id] = true
                    local have = tonumber(item.have) or 0
                    local need = tonumber(item.need) or 0
                    local short = need - have
                    if short < 1 then
                        short = 1
                    end
                    items[#items + 1] = {
                        name = name,
                        short = short,
                    }
                end
            end
        end
    end
    take(blockers.seeds)
    take(blockers.flasks)
    take(blockers.butcher)
    take(blockers.other)
    return items
end

--- Same chat list AutoBuy uses: recipe-stat lines, yield-correct counts.
function StockPiler.PrintMaterialsToBuy(jobs, opts)
    opts = type(opts) == "table" and opts or {}
    if type(jobs) ~= "table" then
        jobs = {}
    end
    if opts.dedupe == true then
        local sigParts = {}
        for i = 1, #jobs do
            local job = jobs[i]
            local id = tostring(job and (job.specKey or job.name) or "")
            sigParts[#sigParts + 1] = id .. "=" .. tostring(job and job.deficit or 0)
        end
        table.sort(sigParts)
        local sig = table.concat(sigParts, "|")
        if sig == StockPiler._lastProgressBlockSig then
            return false
        end
        StockPiler._lastProgressBlockSig = sig
        if #jobs == 0 then
            return false
        end
    end
    if #jobs == 0 then
        StockPiler.Print(L"Materials to buy: none.")
        return false
    end
    StockPiler.Print(L"Materials to buy:")
    for i = 1, #jobs do
        local job = jobs[i]
        local n = tonumber(job and job.deficit) or 0
        local label = (job and (job.label or job.name)) or L"material"
        StockPiler.Print(towstring(tostring(n)) .. L"x " .. AsWString(label))
    end
    return true
end

--- One chat line per missing recipe slot. Deduped; repeats only if the set changes.
function StockPiler.NotifyProgressBlocked(blockers)
    if not StockPiler.StatusMessagesVerbose() then
        return false
    end
    if type(blockers) ~= "table" then
        StockPiler._lastProgressBlockSig = ""
        return false
    end
    local items = FlattenBlockers(blockers)
    if #items == 0 then
        StockPiler._lastProgressBlockSig = ""
        return false
    end
    local sigParts = {}
    for i = 1, #items do
        sigParts[#sigParts + 1] = ToNarrow(items[i].name) .. "=" .. tostring(items[i].short)
    end
    table.sort(sigParts)
    local sig = table.concat(sigParts, "|")
    if sig == StockPiler._lastProgressBlockSig then
        return false
    end
    StockPiler._lastProgressBlockSig = sig

    for i = 1, #items do
        local item = items[i]
        StockPiler.Print(
            L"Blocked: need "
                .. towstring(tostring(item.short))
                .. L" of "
                .. item.name
                .. L"."
        )
    end
    return true
end

function StockPiler.NotifyAutoGrowLastSeeds(seedName, remaining)
    if not StockPiler.StatusMessagesVerbose() then
        return
    end
    remaining = tonumber(remaining) or 0
    seedName = AsWString(seedName)
    if remaining < 1 then
        remaining = 1
    end
    local msg = L"Warning: AutoGrow is planting all remaining "
        .. seedName
        .. L" ("
        .. towstring(tostring(remaining))
        .. L"). A failed harvest can lose this seed line."
    EmitChat(msg)
end

--- Slash/load banner; always prints (ignores statusMessages toggle).
function StockPiler.Print(msg)
    EmitChat(AsWString(msg))
end
