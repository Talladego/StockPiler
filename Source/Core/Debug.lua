----------------------------------------------------------------
-- StockPiler Core/Debug - logging, TryCall, event trace ring
----------------------------------------------------------------

StockPiler = StockPiler or {}
StockPiler.Debug = StockPiler.Debug or {}

local D = StockPiler.Debug
D.Enabled = false
D.EventTrace = false
-- on: every chat line. quiet: setting changes, harvest/brew results, and
-- ready alerts (the moment Harvest or Brew becomes usable).
-- off: no chat. Ready sounds still play. The chat-mode confirmation uses kind "force".
D.ChatMode = "on"

function D.NormalizeChatMode(mode)
    mode = string.lower(tostring(mode or ""))
    if mode == "quiet" then
        return "quiet"
    end
    if mode == "off" or mode == "silent" or mode == "none" then
        return "off"
    end
    return "on"
end

--- kind: "status" (automatic), "user" (slash / setting change), "action"
--- (harvest or brew result), "force" (always, including chat off).
function D.AllowsChat(kind)
    kind = tostring(kind or "status")
    if kind == "force" then
        return true
    end
    local mode = D.ChatMode or "on"
    if mode == "off" then
        return false
    end
    if mode == "quiet" then
        return kind == "user" or kind == "action"
    end
    return true
end

local RING_MAX = 200
local ring = {}
local ringN = 0
local ringHead = 0
local _opId = 0

function D.NextOpId()
    _opId = _opId + 1
    return _opId
end

function D.LogText(msg)
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

function D.EmitLog(text)
    if type(d) == "function" then
        d(text)
    end
end

function D.LogAlways(msg)
    D.EmitLog("StockPiler| " .. D.LogText(msg))
end

function D.D(msg)
    if D.Enabled ~= true then
        return
    end
    D.EmitLog("StockPiler| " .. D.LogText(msg))
end

function D.LogOp(kind, msg)
    if D.Enabled ~= true then
        return
    end
    kind = tostring(kind or "op")
    D.EmitLog("StockPiler| " .. D.LogText(kind .. "| " .. tostring(msg)))
end

local _reporting = false
local _seenErr = {}
local _chatErrOnce = false
function D.ReportProtectedCallFailure(context, err, quiet)
    if _reporting == true then
        return
    end
    _reporting = true
    local msg = tostring(context or "unknown") .. ": " .. tostring(err or "unknown error")
    local key = msg
    local first = _seenErr[key] ~= true
    if first then
        _seenErr[key] = true
    end
    pcall(function()
        if quiet == true then
            if first or D.Enabled == true then
                D.EmitLog("StockPiler| TryCallQuiet " .. msg)
            end
            if first and _chatErrOnce ~= true then
                _chatErrOnce = true
                D.Reply(L"An error was logged once. /stp debug for details.")
            end
            return
        end
        D.EmitLog("StockPiler| TryCall " .. msg)
        if type(LogLuaMessage) == "function" and SystemData and SystemData.UiLogFilters then
            LogLuaMessage("Lua", SystemData.UiLogFilters.WARNING, towstring("[StockPiler] " .. msg))
        end
        if first and _chatErrOnce ~= true then
            _chatErrOnce = true
            D.Reply(L"An error was logged once. /stp debug for details.")
        end
    end)
    _reporting = false
end

function D.TryCall(context, fn, ...)
    if type(fn) ~= "function" then
        D.ReportProtectedCallFailure(context, "expected function, got " .. type(fn))
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
    D.ReportProtectedCallFailure(context, results[1])
    return false
end

function D.TryCallQuiet(context, fn, ...)
    if type(fn) ~= "function" then
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
    D.ReportProtectedCallFailure(context, results[1], true)
    return false
end

function D.RingPush(line)
    ringHead = ringHead + 1
    if ringHead > RING_MAX then
        ringHead = 1
    end
    ring[ringHead] = line
    if ringN < RING_MAX then
        ringN = ringN + 1
    end
end

function D.EventTraceNote(eventName, summary, subs)
    if D.EventTrace ~= true then
        return
    end
    local line = string.format(
        "event| %s subs=%s %s",
        tostring(eventName),
        tostring(subs or 0),
        tostring(summary or "")
    )
    D.LogOp("event", string.sub(line, 7))
    D.RingPush(line)
end

function D.DumpEventRing(emit)
    emit = type(emit) == "function" and emit or D.LogAlways
    emit("--- event ring (" .. tostring(ringN) .. " entries) ---")
    if ringN <= 0 then
        emit("  (empty)")
        return
    end
    local start = ringHead - ringN + 1
    if start < 1 then
        start = start + RING_MAX
    end
    for i = 0, ringN - 1 do
        local idx = start + i
        if idx > RING_MAX then
            idx = idx - RING_MAX
        end
        emit("  " .. tostring(ring[idx] or ""))
    end
end

-- WarTriage / SP2 style: colored [StockPiler] LINK prefix before chat body.
-- data=SP: so a hyperlink hook can open the addon window (stock data="0" is inert).
local CHAT_PREFIX_TEXT = "StockPiler"
local CHAT_PREFIX_COLOR = { 170, 220, 170 }
local CHAT_LINK_DATA = "SP:"
local CHAT_LINK_TAG = L"SP:"

local function ChatPrefix(includeSpace)
    local coloredPartRaw = string.format(
        "<LINK data=\"%s\" color=\"%d,%d,%d\" text=\"%s\">",
        CHAT_LINK_DATA,
        CHAT_PREFIX_COLOR[1],
        CHAT_PREFIX_COLOR[2],
        CHAT_PREFIX_COLOR[3],
        CHAT_PREFIX_TEXT
    )
    local prefix = L"[" .. towstring(coloredPartRaw) .. L"]"
    if includeSpace then
        prefix = prefix .. L" "
    end
    return prefix
end

function D.Print(msg, kind)
    if D.AllowsChat(kind) ~= true then
        return
    end
    local body = msg
    if type(body) == "string" then
        body = towstring(body)
    elseif type(body) ~= "wstring" then
        if body == nil then
            body = L""
        else
            body = towstring(tostring(body))
        end
    end
    if EA_ChatWindow and EA_ChatWindow.Print then
        local filter = SystemData and SystemData.SystemLogFilters and SystemData.SystemLogFilters.GENERAL or 0
        EA_ChatWindow.Print(ChatPrefix(true) .. body, filter)
    elseif type(d) == "function" then
        d("StockPiler| " .. D.LogText(body))
    end
end

--- Slash replies and setting changes. Shown in on and quiet.
function D.Reply(msg)
    D.Print(msg, "user")
end

--- Harvest / brew results. Shown in on and quiet.
function D.Notify(msg)
    D.Print(msg, "action")
end

--- Ready alert when Harvest or Brew becomes usable. Chat follows action
--- (on and quiet; hidden when chat is off). Sound always plays.
function D.AnnounceReady(msg, soundId)
    D.Notify(msg)
    if soundId ~= nil and Sound and Sound.Play then
        Sound.Play(soundId)
    end
end

local _prevOnHyperLinkLButtonUp = nil
local _chatLinkHooked = false

local function IsSp3ChatLink(linkData)
    if linkData == nil or type(wstring) ~= "table" or type(wstring.gsub) ~= "function" then
        return false
    end
    local data = linkData
    if type(data) ~= "wstring" then
        data = towstring(tostring(data))
    end
    local _, findCount = wstring.gsub(data, CHAT_LINK_TAG, L"")
    return (tonumber(findCount) or 0) > 0
end

local function OnSp3HyperLinkLButtonUp(linkData, flags, x, y)
    if IsSp3ChatLink(linkData) then
        if StockPiler.Ui and StockPiler.Ui.ToggleWindow then
            StockPiler.Ui.ToggleWindow()
        end
        return
    end
    if _prevOnHyperLinkLButtonUp then
        _prevOnHyperLinkLButtonUp(linkData, flags, x, y)
    end
end

--- Hook chat hyperlinks so clicking [StockPiler] toggles the window (/stp).
function D.InstallChatLinkHook()
    if _chatLinkHooked then
        return
    end
    if type(EA_ChatWindow) ~= "table" or type(EA_ChatWindow.OnHyperLinkLButtonUp) ~= "function" then
        return
    end
    _prevOnHyperLinkLButtonUp = EA_ChatWindow.OnHyperLinkLButtonUp
    EA_ChatWindow.OnHyperLinkLButtonUp = OnSp3HyperLinkLButtonUp
    _chatLinkHooked = true
end

function D.UninstallChatLinkHook()
    if not _chatLinkHooked then
        return
    end
    if type(EA_ChatWindow) == "table" and _prevOnHyperLinkLButtonUp ~= nil then
        EA_ChatWindow.OnHyperLinkLButtonUp = _prevOnHyperLinkLButtonUp
    end
    _prevOnHyperLinkLButtonUp = nil
    _chatLinkHooked = false
end

function D.SafeKeyCount(t, depth, seen)
    depth = tonumber(depth) or 0
    if depth > 2 or type(t) ~= "table" then
        return 0
    end
    seen = seen or {}
    if seen[t] then
        return 0
    end
    seen[t] = true
    local n = 0
    for _ in pairs(t) do
        n = n + 1
    end
    return n
end
