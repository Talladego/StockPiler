----------------------------------------------------------------
-- StockPiler Core/Perf - LibPerf.Scope bridge or in-addon hitch logger
----------------------------------------------------------------

StockPiler = StockPiler or {}

local CAPTURE_FLOOR_MS = 250
local Noop = function() end

local function MakeInAddonPerf()
    local Perf = {
        Enabled = false,
        FrameThresholdMs = 400,
        Available = false,
        _trail = {},
        _hold = false,
        _section = nil,
        _t0 = 0,
        _summary = { spikes = 0, emptyTrail = 0 },
        _emptyRate = 0,
    }

    function Perf.IsEnabled()
        return Perf.Enabled == true
    end

    function Perf.SetEnabled(on)
        Perf.Enabled = on == true
    end

    function Perf.Enable()
        Perf.SetEnabled(true)
    end

    function Perf.Disable()
        Perf.SetEnabled(false)
    end

    function Perf.SetFrameThreshold(ms)
        ms = tonumber(ms)
        if ms == nil or ms < 1 then
            return tonumber(Perf.FrameThresholdMs) or 400
        end
        if ms < CAPTURE_FLOOR_MS then
            ms = CAPTURE_FLOOR_MS
        end
        if ms > 10000 then
            ms = 10000
        end
        Perf.FrameThresholdMs = ms
        return ms
    end

    function Perf.GetFrameThreshold()
        return tonumber(Perf.FrameThresholdMs) or 400
    end

    Perf.SetThreshold = Perf.SetFrameThreshold
    Perf.GetThreshold = Perf.GetFrameThreshold

    function Perf.Begin(name)
        if Perf.Enabled ~= true then
            return
        end
        Perf._section = tostring(name or "?")
        Perf._t0 = (GetGameTime and GetGameTime()) or 0
        Perf._trail[#Perf._trail + 1] = ">" .. Perf._section
    end

    function Perf.End(name)
        if Perf.Enabled ~= true then
            return
        end
        name = tostring(name or Perf._section or "?")
        Perf._trail[#Perf._trail + 1] = "<" .. name
        Perf._section = nil
    end

    function Perf.Mark(name)
        if Perf.Enabled ~= true then
            return
        end
        Perf._trail[#Perf._trail + 1] = "*" .. tostring(name or "?")
    end

    function Perf.HoldTrail(on)
        Perf._hold = on == true
        if Perf._hold ~= true then
            Perf._trail = {}
        end
    end

    function Perf.ShouldHoldTrail()
        return Perf._hold == true
    end

    function Perf.ResetSummary()
        Perf._summary = { spikes = 0, emptyTrail = 0 }
    end

    function Perf.OnFrame(_timeElapsed)
        if Perf.Enabled ~= true then
            return
        end
        local now = (GetGameTime and GetGameTime()) or 0
        local dt = (now - (Perf._frameT0 or now)) * 1000
        Perf._frameT0 = now
        if dt < (tonumber(Perf.FrameThresholdMs) or 400) then
            if Perf._hold ~= true then
                Perf._trail = {}
            end
            return
        end
        Perf._summary.spikes = (Perf._summary.spikes or 0) + 1
        local trail = Perf._trail
        local empty = type(trail) ~= "table" or #trail == 0
        if empty then
            Perf._summary.emptyTrail = (Perf._summary.emptyTrail or 0) + 1
            Perf._emptyRate = (Perf._emptyRate or 0) + 1
            if Perf._emptyRate <= 3 or (Perf._emptyRate % 20) == 0 then
                StockPiler.Debug.LogAlways(string.format(
                    "perf| hitch %.0fms trail=(none) empty=%d spikes=%d",
                    dt, Perf._summary.emptyTrail, Perf._summary.spikes
                ))
            end
        else
            Perf._emptyRate = 0
            local parts = {}
            local n = #trail
            local start = math.max(1, n - 24)
            for i = start, n do
                parts[#parts + 1] = trail[i]
            end
            StockPiler.Debug.LogAlways(string.format(
                "perf| hitch %.0fms trail=%s",
                dt, table.concat(parts, " ")
            ))
        end
        if Perf._hold ~= true then
            Perf._trail = {}
        end
    end

    function Perf.PrintSummary()
        if StockPiler.Debug.Reply then
            StockPiler.Debug.Reply(towstring(string.format(
            "SP perf spikes=%d emptyTrail=%d thr=%dms enabled=%s",
            Perf._summary.spikes or 0,
            Perf._summary.emptyTrail or 0,
            Perf.GetFrameThreshold(),
            tostring(Perf.Enabled)
        )))
            return
        end
        StockPiler.Debug.Print(towstring(string.format(
            "SP perf spikes=%d emptyTrail=%d thr=%dms enabled=%s",
            Perf._summary.spikes or 0,
            Perf._summary.emptyTrail or 0,
            Perf.GetFrameThreshold(),
            tostring(Perf.Enabled)
        )))
    end

    Perf.DumpSummary = Perf.PrintSummary
    Perf.PrintBaseline = Noop
    function Perf.IsBaselineCollecting()
        return false
    end
    function Perf.StartBaseline()
        return 50
    end
    function Perf.GetLogPath()
        return "in-addon"
    end
    return Perf
end

if LibPerf and type(LibPerf.Scope) == "function" then
    local Perf = LibPerf.Scope("StockPiler")
    Perf.Available = true
    function Perf.OnFrame(_timeElapsed)
    end
    -- Do not raise a saved /libperf threshold. LibPerf persists it; a 250ms
    -- floor here overwrote /libperf StockPiler thr 50 on every reload.
    StockPiler.Perf = Perf
else
    StockPiler.Perf = MakeInAddonPerf()
end

-- Reason tallies for idle-loop / prewarm diagnostics (always available).
do
    local Perf = StockPiler.Perf
    Perf._reasonTally = Perf._reasonTally or {}

    function Perf.Tally(bucket, reason)
        bucket = tostring(bucket or "?")
        reason = tostring(reason or "?")
        local byBucket = Perf._reasonTally
        local map = byBucket[bucket]
        if type(map) ~= "table" then
            map = {}
            byBucket[bucket] = map
        end
        map[reason] = (tonumber(map[reason]) or 0) + 1
    end

    function Perf.ResetReasonTally()
        Perf._reasonTally = {}
    end

    function Perf.FormatReasonTally()
        local byBucket = Perf._reasonTally
        if type(byBucket) ~= "table" then
            return "tally=(empty)"
        end
        local parts = {}
        local buckets = {}
        for bucket in pairs(byBucket) do
            buckets[#buckets + 1] = bucket
        end
        table.sort(buckets)
        for bi = 1, #buckets do
            local bucket = buckets[bi]
            local map = byBucket[bucket]
            if type(map) == "table" then
                local keys = {}
                for reason in pairs(map) do
                    keys[#keys + 1] = reason
                end
                table.sort(keys)
                local rows = {}
                for ki = 1, #keys do
                    local reason = keys[ki]
                    rows[#rows + 1] = string.format("%s=%d", reason, tonumber(map[reason]) or 0)
                end
                if #rows > 0 then
                    parts[#parts + 1] = bucket .. "{" .. table.concat(rows, ",") .. "}"
                end
            end
        end
        if #parts == 0 then
            return "tally=(empty)"
        end
        return "tally=" .. table.concat(parts, " ")
    end

    local prevPrint = Perf.PrintSummary
    function Perf.PrintSummary()
        if type(prevPrint) == "function" then
            prevPrint()
        end
        local line = Perf.FormatReasonTally()
        if StockPiler.Debug and StockPiler.Debug.Reply then
            StockPiler.Debug.Reply(towstring("SP " .. line))
        elseif StockPiler.Debug and StockPiler.Debug.Print then
            StockPiler.Debug.Print(towstring("SP " .. line))
        elseif StockPiler.Debug and StockPiler.Debug.LogAlways then
            StockPiler.Debug.LogAlways("SP " .. line)
        end
    end
    Perf.DumpSummary = Perf.PrintSummary
end
