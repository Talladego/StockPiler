----------------------------------------------------------------
-- StockPiler Stores/GardenStore - plot cache (soft dirty vs planGen)
----------------------------------------------------------------

StockPiler = StockPiler or {}
StockPiler.Garden = StockPiler.Garden or {}
local Garden = StockPiler.Garden

Garden._gen = 0
Garden._planGen = 0
Garden._plots = {}
Garden._syncAllDue = false
Garden._syncAllFrame = 0
Garden._lastFiredGen = 0
Garden._syncDepth = 0

local function IsPlotEmptyStage(stage)
    if GameData and GameData.CultivationStage then
        return (tonumber(stage) or 0) == (GameData.CultivationStage.EMPTY or 0)
    end
    return (tonumber(stage) or 0) == 0
end

--- Plant/empty/lock/seed changes invalidate plan; stage-timer pulses do not.
local function ActionablePlotChange(prev, row)
    if type(prev) ~= "table" then
        return true
    end
    if (tonumber(prev.seedUid) or 0) ~= (tonumber(row.seedUid) or 0) then
        return true
    end
    if (tonumber(prev.plantUid) or 0) ~= (tonumber(row.plantUid) or 0) then
        return true
    end
    if (prev.locked == true) ~= (row.locked == true) then
        return true
    end
    if IsPlotEmptyStage(prev.stage) ~= IsPlotEmptyStage(row.stage) then
        return true
    end
    return false
end

local function AdditiveFillKey(row)
    if type(row) ~= "table" or type(row.additives) ~= "table" then
        return ""
    end
    local parts = {}
    for cultType, slot in pairs(row.additives) do
        if type(slot) == "table" and (slot.filled == true or (tonumber(slot.id) or 0) ~= 0) then
            parts[#parts + 1] = tostring(cultType) .. ":"
                .. tostring(tonumber(slot.uniqueID) or tonumber(slot.id) or 0)
        end
    end
    table.sort(parts)
    return table.concat(parts, ",")
end

local function ApplyPlotRow(plotNum, row)
    local prev = Garden._plots[plotNum]
    -- Match SP2: plant/empty/lock/additive fill - not stageTimer pulses (those storm DIRTY).
    local anyChange = type(prev) ~= "table" or prev.stage ~= row.stage
        or prev.seedUid ~= row.seedUid or prev.plantUid ~= row.plantUid
        or (prev.locked == true) ~= (row.locked == true)
        or AdditiveFillKey(prev) ~= AdditiveFillKey(row)
    local planChange = ActionablePlotChange(prev, row)
    Garden._plots[plotNum] = row
    if StockPiler.Grow and StockPiler.Grow.ClearPendingAdditiveIfFilled then
        StockPiler.Grow.ClearPendingAdditiveIfFilled(plotNum, row)
    end
    return anyChange, planChange
end

local function FireGardenChanged(gardenGen, plotNum, soft)
    gardenGen = tonumber(gardenGen) or 0
    if gardenGen <= 0 then
        return
    end
    if (tonumber(Garden._lastFiredGen) or 0) == gardenGen then
        return
    end
    Garden._lastFiredGen = gardenGen
    local B = StockPiler.EventBus
    local E = StockPiler.Events
    if not (B and E) then
        return
    end
    if E.GARDEN_SNAPSHOT then
        B.Fire(E.GARDEN_SNAPSHOT, { gardenGen = gardenGen, soft = soft == true })
    end
    if E.GARDEN_DIRTY then
        B.Fire(E.GARDEN_DIRTY, {
            gardenGen = gardenGen,
            plotNum = plotNum,
            soft = soft == true,
            planGen = Garden.GetPlanGen(),
        })
    end
end

function Garden.GetGen()
    return tonumber(Garden._gen) or 0
end

function Garden.GetPlanGen()
    return tonumber(Garden._planGen) or 0
end

function Garden.GetPlots()
    local src = Garden._plots
    if type(src) ~= "table" then
        return {}
    end
    local out = {}
    for k, v in pairs(src) do
        out[k] = v
    end
    return out
end

--- Alias for LearnBridge / SP2 call sites.
function Garden.GetPlotsCopy()
    return Garden.GetPlots()
end

function Garden.GetPlot(plotNum)
    plotNum = tonumber(plotNum) or 0
    if plotNum <= 0 then
        return nil
    end
    return Garden._plots[plotNum]
end

function Garden.SyncAll()
    if (tonumber(Garden._syncDepth) or 0) > 0 then
        Garden._syncAllDue = true
        return
    end
    local frame = tonumber(StockPiler.FrameCounter) or 0
    if frame > 0 and Garden._syncAllFrame == frame then
        return
    end
    Garden._syncAllFrame = frame
    Garden._syncAllDue = false
    local CA = StockPiler.CultivatorAdapter
    if not CA then
        return
    end
    Garden._syncDepth = (tonumber(Garden._syncDepth) or 0) + 1
    local changed = false
    local planChanged = false
    local ok, err = pcall(function()
        local n = CA.MaxPlotSlots and CA.MaxPlotSlots() or CA.NumPlots()
        for plotNum = 1, n do
            local row = CA.GetPlotInfo and CA.GetPlotInfo(plotNum) or CA.ReadPlot(plotNum)
            local anyChange, plotPlanChange = ApplyPlotRow(plotNum, row)
            if anyChange then
                changed = true
            end
            if plotPlanChange then
                planChanged = true
            end
            if StockPiler.CraftChatAdapter and StockPiler.CraftChatAdapter.TryConfirmFromPlot then
                StockPiler.CraftChatAdapter.TryConfirmFromPlot(plotNum, row)
            end
        end
        if changed then
            Garden._gen = (tonumber(Garden._gen) or 0) + 1
            if planChanged then
                Garden._planGen = (tonumber(Garden._planGen) or 0) + 1
            end
            -- Soft dirty: stage-only pulse still bumps gardenGen but planGen may stay.
            FireGardenChanged(Garden._gen, 0, planChanged ~= true)
        end
    end)
    Garden._syncDepth = math.max(0, (tonumber(Garden._syncDepth) or 1) - 1)
    if ok ~= true and StockPiler.Debug and StockPiler.Debug.ReportProtectedCallFailure then
        StockPiler.Debug.ReportProtectedCallFailure("Garden.SyncAll", err, true)
    end
end

function Garden.SyncPlot(plotNum)
    plotNum = tonumber(plotNum) or 0
    local CA = StockPiler.CultivatorAdapter
    if plotNum <= 0 or not CA then
        return
    end
    if (tonumber(Garden._syncDepth) or 0) > 0 then
        Garden._syncAllDue = true
        return
    end
    Garden._syncDepth = (tonumber(Garden._syncDepth) or 0) + 1
    local ok, err = pcall(function()
        local genBefore = tonumber(Garden._gen) or 0
        local planGenBefore = tonumber(Garden._planGen) or 0
        local row = CA.GetPlotInfo and CA.GetPlotInfo(plotNum) or CA.ReadPlot(plotNum)
        local anyChange, planChange = ApplyPlotRow(plotNum, row)
        if StockPiler.CraftChatAdapter and StockPiler.CraftChatAdapter.TryConfirmFromPlot then
            StockPiler.CraftChatAdapter.TryConfirmFromPlot(plotNum, row)
        end
        if anyChange then
            Garden._gen = genBefore + 1
        end
        if planChange then
            Garden._planGen = planGenBefore + 1
        end
        if (tonumber(Garden._gen) or 0) > genBefore then
            FireGardenChanged(Garden._gen, plotNum, planChange ~= true)
        end
    end)
    Garden._syncDepth = math.max(0, (tonumber(Garden._syncDepth) or 1) - 1)
    if ok ~= true and StockPiler.Debug and StockPiler.Debug.ReportProtectedCallFailure then
        StockPiler.Debug.ReportProtectedCallFailure("Garden.SyncPlot", err, true)
    end
end

function Garden.FlushPendingSyncAll()
    if Garden._syncAllDue ~= true then
        return
    end
    Garden.SyncAll()
end

--- Queue SyncAll for next OnUpdateProcessed (loading-end / coalesced paths).
function Garden.MarkSyncAllDue()
    Garden._syncAllDue = true
end

function Garden.OnCultivationUpdated()
    local plotNum = 0
    if GameData and GameData.Player and GameData.Player.Cultivation then
        plotNum = tonumber(GameData.Player.Cultivation.UpdatedIndex) or 0
    end
    if plotNum > 0 then
        Garden.SyncPlot(plotNum)
    else
        Garden._syncAllDue = true
    end
end
