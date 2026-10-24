----------------------------------------------------------------
-- StockPiler Stores/RefinePipelineStore - in-flight refine ledger
----------------------------------------------------------------

StockPiler = StockPiler or {}
StockPiler.RefinePipeline = StockPiler.RefinePipeline or {}
local RP = StockPiler.RefinePipeline

RP.MAX_OUTSTANDING = 6
RP.OUTSTANDING_TTL_SEC = 30
-- Soft clear only marks the bag dirty. Hard-clear after this, not on the
-- next frame (ExpireStuck runs every frame, so a boolean grace never waited).
RP.SOFT_GRACE_SEC = 3

RP._gen = 0
RP._dirty = false
-- [seedUid] = { count, plantUid, at, softTried }
RP._outstanding = {}

local function NowSec()
    return StockPiler.Util and StockPiler.Util.NowSec and StockPiler.Util.NowSec() or 0
end

local function FireOutstanding()
    local B = StockPiler.EventBus
    local E = StockPiler.Events
    if B and E and E.REFINE_OUTSTANDING then
        B.Fire(E.REFINE_OUTSTANDING, {
            gen = RP.GetGen(),
            sum = RP.GetOutstandingSum(),
        })
    end
end

function RP.GetGen()
    return tonumber(RP._gen) or 0
end

function RP.MarkDirty(reason)
    RP._dirty = true
    RP._gen = (tonumber(RP._gen) or 0) + 1
    FireOutstanding()
    return reason
end

function RP.GetOutstanding(seedUid)
    seedUid = tonumber(seedUid) or 0
    if seedUid <= 0 then
        return 0
    end
    local row = RP._outstanding[seedUid]
    if type(row) ~= "table" then
        return tonumber(RP._outstanding[seedUid]) or 0
    end
    return tonumber(row.count) or 0
end

function RP.GetOutstandingSum()
    local sum = 0
    for _, row in pairs(RP._outstanding) do
        if type(row) == "table" then
            sum = sum + (tonumber(row.count) or 0)
        else
            sum = sum + (tonumber(row) or 0)
        end
    end
    return sum
end

function RP.HasOutstanding()
    return RP.GetOutstandingSum() > 0
end

function RP.CanMarkPending()
    return RP.GetOutstandingSum() < (tonumber(RP.MAX_OUTSTANDING) or 6)
end

--- Register one in-flight refine (seed/plant). Caps at MAX_OUTSTANDING (~6).
function RP.MarkPending(seedUid, plantUid)
    seedUid = tonumber(seedUid) or 0
    plantUid = tonumber(plantUid) or 0
    if seedUid <= 0 then
        return false
    end
    if not RP.CanMarkPending() then
        return false, "max-outstanding"
    end
    local row = RP._outstanding[seedUid]
    if type(row) ~= "table" then
        row = { count = 0, plantUid = plantUid, at = NowSec(), softTried = false }
        RP._outstanding[seedUid] = row
    end
    row.count = (tonumber(row.count) or 0) + 1
    if plantUid > 0 then
        row.plantUid = plantUid
    end
    -- Later refines of the same seed restart the stuck clock.
    row.at = NowSec()
    row.softAt = nil
    row.softTried = false
    RP.MarkDirty("mark-pending")
    return true
end

-- Alias
function RP.Register(seedUid, plantUid)
    return RP.MarkPending(seedUid, plantUid)
end

function RP.Reconcile(seedUid, delivered)
    seedUid = tonumber(seedUid) or 0
    delivered = tonumber(delivered) or 1
    if seedUid <= 0 then
        return false
    end
    local row = RP._outstanding[seedUid]
    local n = 0
    if type(row) == "table" then
        n = (tonumber(row.count) or 0) - delivered
        if n <= 0 then
            RP._outstanding[seedUid] = nil
        else
            row.count = n
        end
    else
        n = (tonumber(RP._outstanding[seedUid]) or 0) - delivered
        if n <= 0 then
            RP._outstanding[seedUid] = nil
        else
            RP._outstanding[seedUid] = n
        end
    end
    RP.MarkDirty("reconcile")
    return true
end

function RP.Snapshot()
    local out = {}
    for uid, row in pairs(RP._outstanding) do
        if type(row) == "table" then
            out[uid] = tonumber(row.count) or 0
        else
            out[uid] = tonumber(row) or 0
        end
    end
    return out
end

--- Soft expire (~30s): MarkDirty inventory once; next pass force-clears remaining.
function RP.ExpireStuck()
    if next(RP._outstanding) == nil then
        return false
    end
    local now = NowSec()
    local ttl = tonumber(RP.OUTSTANDING_TTL_SEC) or 30
    local changed = false
    for seedUid, row in pairs(RP._outstanding) do
        seedUid = tonumber(seedUid) or 0
        if seedUid > 0 then
            if type(row) ~= "table" then
                row = { count = tonumber(row) or 0, at = now, softTried = false }
                RP._outstanding[seedUid] = row
            end
            local n = tonumber(row.count) or 0
            if n > 0 then
                local at = tonumber(row.at) or 0
                if at <= 0 then
                    row.at = now
                elseif (now - at) >= ttl then
                    local softAt = tonumber(row.softAt) or 0
                    local grace = tonumber(RP.SOFT_GRACE_SEC) or 3
                    if softAt <= 0 then
                        row.softAt = now
                        row.softTried = true
                        if StockPiler.Inventory and StockPiler.Inventory.MarkDirty then
                            StockPiler.Inventory.MarkDirty({ reason = "refine-expire" })
                        end
                        changed = true
                    elseif (now - softAt) >= grace then
                        RP._outstanding[seedUid] = nil
                        changed = true
                    end
                end
            end
        end
    end
    if changed then
        RP.MarkDirty("expire-stuck")
    end
    return changed
end
