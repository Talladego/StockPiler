----------------------------------------------------------------
-- StockPiler BrewChrome -- footer / row brew paint requests
----------------------------------------------------------------

StockPiler = StockPiler or {}
StockPiler.BrewChrome = StockPiler.BrewChrome or {}
local BrewChrome = StockPiler.BrewChrome

function BrewChrome.RefreshBrewUi()
    local Brew = StockPiler.Brew
    if Brew and Brew._suppressBrewUi == true then
        return
    end
    if Brew and Brew.InvalidateCanBrewCache then
        Brew.InvalidateCanBrewCache()
    end
    if StockPiler.Perf and StockPiler.Perf.Begin then
        StockPiler.Perf.Begin("BrewUi")
    end
    local Bus = StockPiler.EventBus
    if Bus and Bus.FireFooterDirty then
        Bus.FireFooterDirty({ immediate = true, syncMacro = true, reason = "brew-chrome" })
    end
    if Bus and Bus.FireBrewSessionChanged then
        Bus.FireBrewSessionChanged({ reason = "brew-chrome" })
    end
    if Brew and Brew.MaybeNotifyBrewReady then
        Brew.MaybeNotifyBrewReady()
    end
    if StockPiler.Perf and StockPiler.Perf.End then
        StockPiler.Perf.End("BrewUi")
    end
end
