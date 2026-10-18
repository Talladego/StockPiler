----------------------------------------------------------------
-- StockPiler HarvestTooltip -- live plot readiness tip
----------------------------------------------------------------

StockPiler = StockPiler or {}
StockPiler.HarvestTooltip = StockPiler.HarvestTooltip or {}
local HarvestTooltip = StockPiler.HarvestTooltip

local function T(key, tokens)
    return StockPiler.Util.T(key, tokens)
end

local function ReadyCount()
    local Grow = StockPiler.Grow
    if Grow and Grow.GetReadyHarvestPlots then
        local plots = Grow.GetReadyHarvestPlots()
        if type(plots) == "table" then
            return #plots
        end
    end
    return 0
end

local function BuildTipText()
    local ready = ReadyCount()
    local can = StockPiler.Grow and StockPiler.Grow.CanHarvestNow
        and StockPiler.Grow.CanHarvestNow() == true
    if can and ready > 0 then
        return T("grow.harvest_ready", { count = tostring(ready) })
    end
    if ready > 0 then
        return T("ui.harvest_tip_ready", { count = tostring(ready) })
    end
    return T("ui.harvest_tip_none")
end

local function Fingerprint()
    local ready = ReadyCount()
    local can = StockPiler.Grow and StockPiler.Grow.CanHarvestNow
        and StockPiler.Grow.CanHarvestNow() == true
    return tostring(can) .. ":" .. tostring(ready)
end

function HarvestTooltip.Show(mouseoverWindow, anchor)
    StockPiler.ViewList.LiveTipShow(
        HarvestTooltip,
        BuildTipText,
        Fingerprint,
        mouseoverWindow,
        anchor,
        Tooltips and Tooltips.ANCHOR_WINDOW_TOP
    )
end

function HarvestTooltip.MaybeRefresh()
    StockPiler.ViewList.LiveTipMaybeRefresh(
        HarvestTooltip,
        BuildTipText,
        Fingerprint,
        HarvestTooltip.Show
    )
end

function HarvestTooltip.TickLive()
    HarvestTooltip.MaybeRefresh()
end
