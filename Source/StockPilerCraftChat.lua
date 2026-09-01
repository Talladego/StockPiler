-- StockPilerCraftChat - supplemental Crafting-channel cues for brew/harvest
-- Bag deltas remain source of truth for what/how many; chat refines Critical flags.

StockPiler = StockPiler or {}
StockPiler.CraftChat = StockPiler.CraftChat or {}

local CC = StockPiler.CraftChat
local RING_MAX = 20
local CUE_TTL_SEC = 5

local _registered = false
local _ring = {}
local _cues = {
    criticalSuccess = false,
    criticalFailure = false,
    createdName = nil,
    harvestedCount = nil,
    harvestedName = nil,
    at = 0,
}

local function NowSec()
    if type(GetGameTime) == "function" then
        return tonumber(GetGameTime()) or 0
    end
    return 0
end

local function ToNarrow(value)
    if StockPiler.ToNarrow then
        return StockPiler.ToNarrow(value) or ""
    end
    if type(value) == "string" then
        return value
    end
    if type(value) == "wstring" and type(WStringToString) == "function" then
        local ok, text = pcall(WStringToString, value)
        if ok and type(text) == "string" then
            return text
        end
    end
    return tostring(value or "")
end

local function StripMarkup(s)
    if type(s) ~= "string" then
        return ""
    end
    s = string.gsub(s, "<LINK[^>]*>", "")
    s = string.gsub(s, "</LINK>", "")
    s = string.gsub(s, "<[^>]+>", "")
    return s
end

local function Normalize(text)
    local s = StripMarkup(ToNarrow(text))
    s = string.gsub(s, "^%s+", "")
    s = string.gsub(s, "%s+$", "")
    return s
end

local function Log(msg)
    if StockPiler.DebugEnabled ~= true then
        return
    end
    if StockPiler._EmitLog and StockPiler._LogText then
        StockPiler._EmitLog("StockPiler| CraftChat| " .. StockPiler._LogText(msg))
    elseif type(d) == "function" then
        d("StockPiler| CraftChat| " .. tostring(msg))
    end
end

local function PushRing(entry)
    _ring[#_ring + 1] = entry
    while #_ring > RING_MAX do
        table.remove(_ring, 1)
    end
end

local function TouchCues()
    _cues.at = NowSec()
end

local function CuesFresh()
    local at = tonumber(_cues.at) or 0
    if at <= 0 then
        return false
    end
    local age = NowSec() - at
    return age >= 0 and age <= CUE_TTL_SEC
end

local function ClearCues()
    _cues.criticalSuccess = false
    _cues.criticalFailure = false
    _cues.createdName = nil
    _cues.harvestedCount = nil
    _cues.harvestedName = nil
    _cues.at = 0
end

local function SnapshotCues()
    if not CuesFresh() then
        return {
            criticalSuccess = false,
            criticalFailure = false,
            createdName = nil,
            harvestedCount = nil,
            harvestedName = nil,
            fresh = false,
        }
    end
    return {
        criticalSuccess = _cues.criticalSuccess == true,
        criticalFailure = _cues.criticalFailure == true,
        createdName = _cues.createdName,
        harvestedCount = _cues.harvestedCount,
        harvestedName = _cues.harvestedName,
        fresh = true,
    }
end

local function HasPendingBrew()
    return type(StockPiler.Inventory) == "table"
        and type(StockPiler.Inventory._pendingCraft) == "table"
end

local function HasPendingHarvest()
    return type(StockPiler.SeedMap) == "table"
        and type(StockPiler.SeedMap._pendingHarvest) == "table"
end

local function ApplyCueToPending(kind)
    if HasPendingBrew() then
        local pending = StockPiler.Inventory._pendingCraft
        if kind == "critical_success" then
            pending.chatCriticalSuccess = true
        elseif kind == "critical_failure" then
            pending.chatCriticalFailure = true
        elseif kind == "created" then
            pending.chatCreatedName = _cues.createdName
        end
    end
    if HasPendingHarvest() then
        local pending = StockPiler.SeedMap._pendingHarvest
        if kind == "critical_success" then
            pending.chatCriticalSuccess = true
        elseif kind == "critical_failure" then
            pending.chatCriticalFailure = true
        elseif kind == "harvested" then
            pending.chatHarvestedCount = _cues.harvestedCount
            pending.chatHarvestedName = _cues.harvestedName
        end
        if kind == "critical_failure"
            and pending.locked == true
            and StockPiler.SeedMap.CompletePendingHarvestFromChat
        then
            StockPiler.SeedMap.CompletePendingHarvestFromChat(SnapshotCues())
        end
    end
end

local function IsIgnoredNoise(text)
    local lower = string.lower(text)
    if string.find(lower, "cultivation plot advanced", 1, true) then
        return true
    end
    if string.find(lower, "cultivation plot flowering completed", 1, true) then
        return true
    end
    -- Login after aborted grow (logout mid-cycle): seeds returned to bags.
    if string.find(lower, "your seeds were restored", 1, true) then
        return true
    end
    if string.find(lower, "unfortunate event", 1, true) then
        return true
    end
    return false
end

local function ParseCraftingLine(text)
    if text == "" then
        return nil
    end
    if IsIgnoredNoise(text) then
        return { kind = "ignore", text = text }
    end

    local lower = string.lower(text)
    if string.find(lower, "critical success", 1, true) == 1
        or lower == "critical success."
        or string.find(lower, "^critical success%.?")
    then
        return { kind = "critical_success", text = text }
    end
    -- Harvest seed-loss uses this line; brew may still say Critical Failure.
    if string.find(lower, "your creation failed", 1, true) == 1
        or string.find(lower, "critical failure", 1, true) == 1
        or lower == "critical failure."
        or string.find(lower, "^critical failure%.?")
    then
        return { kind = "critical_failure", text = text }
    end

    local qty, name = string.match(text, "^You have harvested (%d+) (.+)%.?$")
    if qty and name then
        name = string.gsub(name, "%.$", "")
        return {
            kind = "harvested",
            text = text,
            count = tonumber(qty) or 0,
            name = name,
        }
    end

    local created = string.match(text, "^You created (.+)%.?$")
    if created then
        created = string.gsub(created, "%.$", "")
        return { kind = "created", text = text, name = created }
    end

    return { kind = "unhandled", text = text }
end

function CC.OnChatTextArrived()
    if not GameData or not GameData.ChatData then
        return
    end
    local filters = SystemData and SystemData.ChatLogFilters
    local craftFilter = filters and filters.CRAFTING
    local msgType = tonumber(GameData.ChatData.type)
    if craftFilter ~= nil and msgType ~= tonumber(craftFilter) then
        return
    end

    local text = Normalize(GameData.ChatData.text)
    if text == "" then
        return
    end

    local parsed = ParseCraftingLine(text)
    if type(parsed) ~= "table" then
        return
    end

    PushRing({
        at = NowSec(),
        kind = parsed.kind,
        text = parsed.text,
    })

    if parsed.kind == "ignore" then
        return
    end
    if parsed.kind == "unhandled" then
        Log("unhandled " .. tostring(parsed.text))
        return
    end

    TouchCues()
    if parsed.kind == "critical_success" then
        _cues.criticalSuccess = true
        Log("critical_success")
        ApplyCueToPending("critical_success")
    elseif parsed.kind == "critical_failure" then
        _cues.criticalFailure = true
        Log("critical_failure")
        ApplyCueToPending("critical_failure")
    elseif parsed.kind == "created" then
        _cues.createdName = parsed.name
        Log("created name=" .. tostring(parsed.name))
        ApplyCueToPending("created")
    elseif parsed.kind == "harvested" then
        _cues.harvestedCount = parsed.count
        _cues.harvestedName = parsed.name
        Log("harvested count=" .. tostring(parsed.count) .. " name=" .. tostring(parsed.name))
        ApplyCueToPending("harvested")
    end
end

--- Snapshot of recent Crafting cues (TTL). Does not clear.
function CC.PeekCues()
    return SnapshotCues()
end

--- Snapshot then clear sticky cues (after a brew/harvest learn completes).
function CC.TakeCues()
    local snap = SnapshotCues()
    ClearCues()
    return snap
end

function CC.GetRing()
    return _ring
end

function CC.Initialize()
    if _registered then
        return
    end
    if not SystemData or not SystemData.Events or not SystemData.Events.CHAT_TEXT_ARRIVED then
        return
    end
    RegisterEventHandler(SystemData.Events.CHAT_TEXT_ARRIVED, "StockPiler.CraftChat.OnChatTextArrived")
    _registered = true
    Log("initialized")
end

function CC.Shutdown()
    if not _registered then
        return
    end
    if SystemData and SystemData.Events and SystemData.Events.CHAT_TEXT_ARRIVED then
        UnregisterEventHandler(SystemData.Events.CHAT_TEXT_ARRIVED, "StockPiler.CraftChat.OnChatTextArrived")
    end
    _registered = false
    ClearCues()
    _ring = {}
end
