----------------------------------------------------------------
-- StockPilerPerf — frametime spike breadcrumbs for uilog.log
--
-- Off by default. /stp perf [on|off|<ms>] toggles logging. Frames >= threshold ms
-- are written even with an empty trail (engine-only hitch). Default threshold 400ms.
-- /stp perf baseline — start collecting frame stats; run again to print summary.
-- /stp perf summary — top hitch trails since perf was enabled or last summary reset.
----------------------------------------------------------------

StockPiler.Perf = StockPiler.Perf or {}
StockPiler.Perf.Enabled = false
StockPiler.Perf.FrameThresholdMs = 400

local SECTION_MS = 50
local MAX_NAMES = 16
local TRAIL_IDLE_CLEAR_SEC = 0.1
local SUMMARY_MAX_ENTRIES = 12

local counts = {}
local order = {}
local orderN = 0
local starts = {}
local lastSpike = nil
local trailIdleSec = 0

local spikeStats = {}

local baseline = {
    collecting = false,
    count = 0,
    sum = 0,
    min = nil,
    max = 0,
    emptyTrail = 0,
    geThreshold = 0,
    thresholdMs = 50,
}

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
    trailIdleSec = 0
end

local function TrailText()
    if orderN <= 0 then
        return "(none)"
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

local function RecordSpikeSummary(ms, trail)
    trail = trail or "(none)"
    local entry = spikeStats[trail]
    if type(entry) ~= "table" then
        entry = { count = 0, maxMs = 0 }
        spikeStats[trail] = entry
    end
    entry.count = entry.count + 1
    if ms > entry.maxMs then
        entry.maxMs = ms
    end
end

local function RecordBaseline(ms, trailEmpty)
    if baseline.collecting ~= true then
        return
    end
    baseline.count = baseline.count + 1
    baseline.sum = baseline.sum + ms
    if baseline.min == nil or ms < baseline.min then
        baseline.min = ms
    end
    if ms > baseline.max then
        baseline.max = ms
    end
    if trailEmpty then
        baseline.emptyTrail = baseline.emptyTrail + 1
    end
    if ms >= baseline.thresholdMs then
        baseline.geThreshold = baseline.geThreshold + 1
    end
end

function StockPiler.Perf.Mark(name)
    if StockPiler.Perf.Enabled ~= true then
        return
    end
    name = tostring(name or "?")
    trailIdleSec = 0
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
    local trailEmpty = orderN <= 0
    RecordBaseline(ms, trailEmpty)
    local threshold = tonumber(StockPiler.Perf.FrameThresholdMs) or 400
    if ms >= threshold then
        local trail = TrailText()
        local line = string.format("FRAME %.0fms trail=%s", ms, trail)
        lastSpike = line
        RecordSpikeSummary(ms, trail)
        Emit(line)
    end
    if orderN > 0 then
        trailIdleSec = trailIdleSec + (tonumber(timeElapsed) or 0)
        if trailIdleSec >= TRAIL_IDLE_CLEAR_SEC then
            ClearTrail()
        end
    else
        trailIdleSec = 0
    end
end

function StockPiler.Perf.SetFrameThreshold(ms)
    ms = tonumber(ms)
    if ms == nil or ms < 1 then
        return tonumber(StockPiler.Perf.FrameThresholdMs) or 400
    end
    if ms > 10000 then
        ms = 10000
    end
    StockPiler.Perf.FrameThresholdMs = ms
    return ms
end

function StockPiler.Perf.GetFrameThreshold()
    return tonumber(StockPiler.Perf.FrameThresholdMs) or 400
end

function StockPiler.Perf.SetEnabled(enabled)
    StockPiler.Perf.Enabled = enabled == true
    if StockPiler.Perf.Enabled ~= true then
        ClearTrail()
    end
    return StockPiler.Perf.Enabled
end

function StockPiler.Perf.ResetSummary()
    spikeStats = {}
end

function StockPiler.Perf.PrintSummary()
    local ranked = {}
    for trail, entry in pairs(spikeStats) do
        if type(entry) == "table" and (entry.count or 0) > 0 then
            ranked[#ranked + 1] = {
                trail = trail,
                count = entry.count or 0,
                maxMs = entry.maxMs or 0,
            }
        end
    end
    if #ranked <= 0 then
        local threshold = StockPiler.Perf.GetFrameThreshold()
        Emit("summary empty (no hitches >= " .. tostring(threshold) .. "ms recorded)")
        if StockPiler.Print then
            StockPiler.Print(L"Perf summary: no hitches recorded. /stp perf on 100 then reproduce.")
        end
        return
    end
    table.sort(ranked, function(a, b)
        if a.maxMs ~= b.maxMs then
            return a.maxMs > b.maxMs
        end
        if a.count ~= b.count then
            return a.count > b.count
        end
        return a.trail < b.trail
    end)
    local n = #ranked
    if n > SUMMARY_MAX_ENTRIES then
        n = SUMMARY_MAX_ENTRIES
    end
    Emit(string.format("summary top %d trails (threshold=%dms):", n, StockPiler.Perf.GetFrameThreshold()))
    if StockPiler.Print then
        StockPiler.Print(L"Perf summary (top " .. towstring(tostring(n)) .. L" trails):")
    end
    for i = 1, n do
        local row = ranked[i]
        local line = string.format("#%d count=%d max=%.0fms %s", i, row.count, row.maxMs, row.trail)
        Emit(line)
        if StockPiler.Print then
            StockPiler.Print(L"  " .. towstring(string.format("#%d x%d max=%.0fms %s",
                i, row.count, row.maxMs, row.trail)))
        end
    end
end

function StockPiler.Perf.IsBaselineCollecting()
    return baseline.collecting == true
end

function StockPiler.Perf.ResetBaseline()
    baseline.collecting = false
    baseline.count = 0
    baseline.sum = 0
    baseline.min = nil
    baseline.max = 0
    baseline.emptyTrail = 0
    baseline.geThreshold = 0
end

function StockPiler.Perf.StartBaseline(thresholdMs)
    thresholdMs = tonumber(thresholdMs) or 50
    if thresholdMs < 1 then
        thresholdMs = 50
    end
    baseline.thresholdMs = thresholdMs
    baseline.count = 0
    baseline.sum = 0
    baseline.min = nil
    baseline.max = 0
    baseline.emptyTrail = 0
    baseline.geThreshold = 0
    baseline.collecting = true
    StockPiler.Perf.SetFrameThreshold(thresholdMs)
    StockPiler.Perf.SetEnabled(true)
    StockPiler.Perf.ResetSummary()
    return thresholdMs
end

function StockPiler.Perf.PrintBaseline()
    if baseline.count <= 0 then
        local msg = "baseline empty (no frames recorded)"
        Emit(msg)
        if StockPiler.Print then
            StockPiler.Print(L"Perf baseline: no frames recorded yet.")
        end
        return
    end
    local avg = baseline.sum / baseline.count
    local emptyPct = (baseline.emptyTrail / baseline.count) * 100
    local gePct = (baseline.geThreshold / baseline.count) * 100
    local line = string.format(
        "baseline n=%d avg=%.0fms min=%.0fms max=%.0fms emptyTrail=%.0f%% ge%dms=%.0f%% threshold=%d",
        baseline.count,
        avg,
        baseline.min or 0,
        baseline.max,
        emptyPct,
        baseline.thresholdMs,
        gePct,
        baseline.thresholdMs
    )
    Emit(line)
    if StockPiler.Print then
        StockPiler.Print(L"Perf baseline: " .. towstring(string.format(
            "n=%d avg=%.0f min=%.0f max=%.0f emptyTrail=%.0f%% >=%dms=%.0f%%",
            baseline.count, avg, baseline.min or 0, baseline.max, emptyPct,
            baseline.thresholdMs, gePct
        )))
    end
    baseline.collecting = false
    StockPiler.Perf.PrintSummary()
end

function StockPiler.Perf.PrintLast()
    local threshold = StockPiler.Perf.GetFrameThreshold()
    if lastSpike == nil then
        if StockPiler.Print then
            StockPiler.Print(L"No hitch (>=" .. towstring(tostring(threshold)) .. L"ms) recorded. /stp perf on "
                .. towstring(tostring(threshold)) .. L" then reproduce, /stp perf off.")
        end
        return
    end
    if StockPiler.Print then
        StockPiler.Print(L"Last hitch: " .. towstring(lastSpike))
    end
end
