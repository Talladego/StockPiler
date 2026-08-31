----------------------------------------------------------------
-- StockPilerPerf — frametime spike breadcrumbs for uilog.log
--
-- Off by default. /stp perf toggles logging. Only frames >= 400ms that
-- include StockPiler work are written. Trail names are collapsed (name xN).
----------------------------------------------------------------

StockPiler.Perf = StockPiler.Perf or {}
StockPiler.Perf.Enabled = false

local FRAME_MS = 400
local SECTION_MS = 200
local MAX_NAMES = 16

local counts = {}
local order = {}
local orderN = 0
local starts = {}
local lastSpike = nil

local function NowSec()
    if type(GetGameTime) == "function" then
        return tonumber(GetGameTime()) or 0
    end
    return 0
end

local function Emit(msg)
    if StockPiler._EmitLog and StockPiler._LogText then
        StockPiler._EmitLog("StockPiler| Perf| " .. StockPiler._LogText(msg))
    elseif type(d) == "function" then
        d("StockPiler| Perf| " .. tostring(msg))
    end
end

local function ClearTrail()
    for i = 1, orderN do
        local name = order[i]
        counts[name] = nil
        order[i] = nil
    end
    orderN = 0
end

local function TrailText()
    if orderN <= 0 then
        return ""
    end
    local parts = {}
    local n = orderN
    if n > MAX_NAMES then
        n = MAX_NAMES
    end
    for i = 1, n do
        local name = order[i]
        local c = counts[name] or 1
        if c > 1 then
            parts[i] = name .. " x" .. tostring(c)
        else
            parts[i] = name
        end
    end
    local text = table.concat(parts, ", ")
    if orderN > MAX_NAMES then
        text = text .. " +" .. tostring(orderN - MAX_NAMES) .. " names"
    end
    return text
end

function StockPiler.Perf.Mark(name)
    if StockPiler.Perf.Enabled ~= true then
        return
    end
    name = tostring(name or "?")
    if counts[name] == nil then
        orderN = orderN + 1
        order[orderN] = name
        counts[name] = 1
    else
        counts[name] = counts[name] + 1
    end
end

function StockPiler.Perf.Begin(name)
    if StockPiler.Perf.Enabled ~= true then
        return
    end
    name = tostring(name or "?")
    StockPiler.Perf.Mark(name)
    starts[name] = NowSec()
end

function StockPiler.Perf.End(name)
    if StockPiler.Perf.Enabled ~= true then
        return
    end
    name = tostring(name or "?")
    local t0 = starts[name]
    starts[name] = nil
    if t0 == nil then
        return
    end
    local dtMs = (NowSec() - t0) * 1000
    if dtMs >= SECTION_MS then
        Emit(string.format("section %s %.0fms", name, dtMs))
    end
end

--- Call at the start of OnUpdate. timeElapsed is the previous frame.
function StockPiler.Perf.OnFrame(timeElapsed)
    if StockPiler.Perf.Enabled ~= true then
        return
    end
    local ms = (tonumber(timeElapsed) or 0) * 1000
    if ms >= FRAME_MS and orderN > 0 then
        local line = string.format("FRAME %.0fms trail=%s", ms, TrailText())
        lastSpike = line
        Emit(line)
    end
    ClearTrail()
end

function StockPiler.Perf.SetEnabled(enabled)
    StockPiler.Perf.Enabled = enabled == true
    if StockPiler.Perf.Enabled ~= true then
        ClearTrail()
    end
    return StockPiler.Perf.Enabled
end

function StockPiler.Perf.PrintLast()
    if lastSpike == nil then
        if StockPiler.Print then
            StockPiler.Print(L"No StockPiler hitch (>=400ms) recorded. Enable with /stp perf, harvest, then /stp perf again.")
        end
        return
    end
    if StockPiler.Print then
        StockPiler.Print(L"Last hitch: " .. towstring(lastSpike))
    end
end
