----------------------------------------------------------------
-- StockPiler Buy -- AutoBuy at vendor (independent of AutoGrow)
-- Policy + IssueOne purchase. Callees above callers.
----------------------------------------------------------------

StockPiler = StockPiler or {}
StockPiler.Buy = StockPiler.Buy or {}
local Buy = StockPiler.Buy

Buy.BRASS_PER_GOLD = 10000
Buy.BRASS_PER_SILVER = 100
Buy.MAX_PURCHASES_PER_VISIT = 80
-- Must exceed Scheduler bag coalesce (~2s) or pending buys false no-spend before L0/snap.
Buy.PENDING_BUY_TIMEOUT_SEC = 3.5
Buy.NO_SPEND_COOLDOWN_SEC = 0.75
-- After a false no-spend, still accept bag/money confirm for chat/accounting.
Buy.LATE_CONFIRM_GRACE_SEC = 6.0
-- Brief settle after a confirmed buy before the next BuyItem (back-to-back can no-op).
Buy.POST_BUY_GAP_SEC = 0.35

Buy._jobsCache = nil
Buy._jobsCacheKey = nil
Buy._storeWasOpen = false
Buy._visitPurchases = 0
Buy._visitSpentBrass = 0
Buy._visitMoneyBrass = 0
Buy._visitBought = 0
Buy._visitStopReason = nil
Buy._visitAcquired = Buy._visitAcquired or {}
Buy._fillChatPending = Buy._fillChatPending or {}
Buy._allowPlantBuys = false
Buy._planArmedAfterFill = false
Buy._pendingBuy = nil
Buy._issueSeq = 0
Buy._noSpendCooldownUntil = Buy._noSpendCooldownUntil or {}
Buy._lateBuyAttempts = Buy._lateBuyAttempts or {}
Buy._nextBuyAfter = 0

----------------------------------------------------------------
-- Helpers
----------------------------------------------------------------

local function LogBuy(msg)
    if StockPiler.Debug and StockPiler.Debug.LogOp then
        StockPiler.Debug.LogOp("buy", msg)
    end
end

local function Emit(msg, force)
    local line = tostring(msg or "")
    if StockPiler.Debug and StockPiler.Debug.LogAlways then
        StockPiler.Debug.LogAlways(line)
    elseif StockPiler.Debug and StockPiler.Debug.LogOp then
        StockPiler.Debug.LogOp("buy", line)
    end
end

local function PlayerMoneyBrass()
    local VA = StockPiler.VendorAdapter
    if VA and VA.GetPlayerMoneyBrass then
        return tonumber(VA.GetPlayerMoneyBrass()) or 0
    end
    return 0
end

local function NowSec()
    return StockPiler.Util and StockPiler.Util.NowSec and StockPiler.Util.NowSec() or 0
end

local function BagCountUid(uid)
    uid = tonumber(uid) or 0
    if uid <= 0 then
        return 0
    end
    local Inv = StockPiler.Inventory
    if Inv and Inv.CountByUid then
        return tonumber(Inv.CountByUid(uid)) or 0
    end
    return 0
end

local function IsUidOnCooldown(uid)
    uid = tonumber(uid) or 0
    if uid <= 0 then
        return false
    end
    local untilT = tonumber(Buy._noSpendCooldownUntil[uid]) or 0
    if untilT <= 0 then
        return false
    end
    local now = NowSec()
    if now <= 0 then
        return false
    end
    if now >= untilT then
        Buy._noSpendCooldownUntil[uid] = nil
        return false
    end
    return true
end

local function ArmNoSpendCooldown(uid, durationSec)
    uid = tonumber(uid) or 0
    if uid <= 0 then
        return
    end
    local now = NowSec()
    if now <= 0 then
        return
    end
    local dur = tonumber(durationSec)
    if dur == nil or dur <= 0 then
        dur = tonumber(Buy.NO_SPEND_COOLDOWN_SEC) or 2
    end
    Buy._noSpendCooldownUntil[uid] = now + dur
end

local function ClearNoSpendCooldown(uid)
    uid = tonumber(uid) or 0
    if uid > 0 then
        Buy._noSpendCooldownUntil[uid] = nil
    end
end

local function ClearLateAttemptsForUid(uid)
    uid = tonumber(uid) or 0
    if uid <= 0 then
        return
    end
    local list = Buy._lateBuyAttempts
    if type(list) ~= "table" or #list < 1 then
        return
    end
    local keep = {}
    for i = 1, #list do
        local pending = list[i]
        if type(pending) == "table" and (tonumber(pending.uid) or 0) ~= uid then
            keep[#keep + 1] = pending
        end
    end
    Buy._lateBuyAttempts = keep
end

--- Qty still open in late-confirm grace for this uid (0 if none / expired).
--- Blocks IssueOne from rebuying the same uid while bag/money may still catch up (#9).
local function OpenLateQtyForUid(uid)
    uid = tonumber(uid) or 0
    if uid <= 0 then
        return 0
    end
    local list = Buy._lateBuyAttempts
    if type(list) ~= "table" or #list < 1 then
        return 0
    end
    local now = NowSec()
    local total = 0
    for i = 1, #list do
        local pending = list[i]
        if type(pending) == "table" and (tonumber(pending.uid) or 0) == uid then
            local expires = tonumber(pending.expiresAt) or 0
            if expires <= 0 or now <= 0 or now < expires then
                total = total + math.max(1, tonumber(pending.qty) or 1)
            end
        end
    end
    return total
end

--- Brass reserved / budgeted by unexpired late attempts plus any in-flight pending buy.
--- Returns reserveLate, budgetLate (EXE-2).
--- budgetLate sums every unexpired late cost (plus pending) with no skip: GetSpentBrass
--- does not include these until confirm (#46).
--- reserveLate skips late attempts whose money drop already matches their cost so the
--- same brass is not reserved twice while waiting for bag evidence (#26 L2). The skip
--- is window-aware: before testing P, subtract costs of already-skipped attempts S whose
--- drop falls inside P's window (same gate as #45), so an equal-cost pair with one real
--- drop only skips one row (L11).
local function OpenLateCostBrass()
    local now = NowSec()
    local live = PlayerMoneyBrass()
    local reserveLate = 0
    local budgetLate = 0
    local skipped = {}
    local list = Buy._lateBuyAttempts
    if type(list) == "table" then
        for i = 1, #list do
            local pending = list[i]
            if type(pending) == "table" then
                local expires = tonumber(pending.expiresAt) or 0
                if expires <= 0 or now <= 0 or now < expires then
                    local cost = math.max(0, tonumber(pending.costTotal) or 0)
                    local before = tonumber(pending.beforeMoney) or 0
                    local foreign = tonumber(pending.foreignSpend) or 0
                    budgetLate = budgetLate + cost
                    local alreadyDropped = false
                    if live > 0 and before > 0 and cost > 0 then
                        local unexplained = (before - live) - foreign
                        for s = 1, #skipped do
                            local S = skipped[s]
                            local sBefore = tonumber(S.beforeMoney) or 0
                            local sForeign = tonumber(S.foreignSpend) or 0
                            local sCost = math.max(0, tonumber(S.costTotal) or 0)
                            -- S's drop is inside P's window when P.before still
                            -- included it (same threshold shape as #45).
                            if before > (sBefore - sForeign - sCost + 1) then
                                unexplained = unexplained - sCost
                            end
                        end
                        alreadyDropped = unexplained + 1 >= cost and unexplained <= cost + 1
                    end
                    if alreadyDropped == true then
                        skipped[#skipped + 1] = pending
                    else
                        reserveLate = reserveLate + cost
                    end
                end
            end
        end
    end
    local openPending = Buy._pendingBuy
    if type(openPending) == "table" then
        local pendingCost = math.max(0, tonumber(openPending.costTotal) or 0)
        reserveLate = reserveLate + pendingCost
        budgetLate = budgetLate + pendingCost
    end
    return reserveLate, budgetLate
end

--- Credit confirmed cost onto other open attempts whose wallet snapshot still
--- included that drop. Attempts issued after the money already left must not
--- get foreignSpend (#31). Visit spent clears on reopen, so the amount lives
--- on the attempt itself (EXE-1, EXE-3). Threshold subtracts the confirmed
--- attempt's own foreignSpend so equal-cost late buys stay credited (#45).
local function NoteForeignSpend(confirmed)
    if type(confirmed) ~= "table" then
        return
    end
    local costTotal = math.max(0, tonumber(confirmed.costTotal) or 0)
    if costTotal <= 0 then
        return
    end
    local exceptUid = tonumber(confirmed.uid) or 0
    local confirmedSeq = tonumber(confirmed.issueSeq) or 0
    local confirmedBefore = tonumber(confirmed.beforeMoney) or 0
    local confirmedForeign = math.max(0, tonumber(confirmed.foreignSpend) or 0)
    local function add(pending)
        if type(pending) ~= "table" then
            return
        end
        if exceptUid > 0 and (tonumber(pending.uid) or 0) == exceptUid then
            return
        end
        local pSeq = tonumber(pending.issueSeq) or 0
        local pBefore = tonumber(pending.beforeMoney) or 0
        if pSeq > confirmedSeq
            and confirmedBefore > 0
            and pBefore <= (confirmedBefore - confirmedForeign - costTotal + 1)
        then
            return
        end
        pending.foreignSpend = (tonumber(pending.foreignSpend) or 0) + costTotal
    end
    local list = Buy._lateBuyAttempts
    if type(list) == "table" then
        for i = 1, #list do
            add(list[i])
        end
    end
    add(Buy._pendingBuy)
end

local function ArmPostBuyGap()
    local now = NowSec()
    local gap = tonumber(Buy.POST_BUY_GAP_SEC) or 0.35
    if now > 0 and gap > 0 then
        Buy._nextBuyAfter = now + gap
    end
end

local function IsGrowableStoreItem(item)
    if type(item) ~= "table" then
        return false
    end
    local cult = tonumber(item.cultivationType) or 0
    local seed = (GameData and GameData.CultivationTypes and GameData.CultivationTypes.SEED) or 1
    local spore = (GameData and GameData.CultivationTypes and GameData.CultivationTypes.SPORE) or 5
    return cult == seed or cult == spore
end

--- Soil / Water / Nutrient - never AutoBuy as recipe mats (same skill tier != match).
local function IsCultivationAdditiveStoreItem(item)
    if type(item) ~= "table" then
        return false
    end
    local MS = StockPiler.MaterialSpec
    if MS and MS.IsCultivationAdditive then
        return MS.IsCultivationAdditive(item) == true
    end
    local cult = tonumber(item.cultivationType) or 0
    local soil = (GameData and GameData.CultivationTypes and GameData.CultivationTypes.SOIL) or 2
    local water = (GameData and GameData.CultivationTypes and GameData.CultivationTypes.WATERCAN) or 3
    local nutrient = (GameData and GameData.CultivationTypes and GameData.CultivationTypes.NUTRIENT) or 4
    return cult == soil or cult == water or cult == nutrient
end

local function StoreItemRejectedForBuy(item, job)
    if IsCultivationAdditiveStoreItem(item) then
        return true
    end
    if type(job) == "table" and (job.skillUp == true or job.upgradeSeed == true) then
        return false
    end
    if Buy._allowPlantBuys ~= true and IsGrowableStoreItem(item) then
        return true
    end
    return false
end

local function HasAltCurrency(item)
    local alt = item and item.altCurrency
    if type(alt) ~= "table" then
        return false
    end
    if #alt > 0 then
        return true
    end
    for _ in pairs(alt) do
        return true
    end
    return false
end

local function VisitAcquired(key)
    if key == nil then
        return 0
    end
    return tonumber(Buy._visitAcquired[key]) or 0
end

local function AddVisitAcquired(key, n)
    if key == nil then
        return
    end
    Buy._visitAcquired[key] = VisitAcquired(key) + (tonumber(n) or 0)
end

local function JobAcquireKey(job, item)
    if type(job) == "table" and job.acquireKey ~= nil then
        return tostring(job.acquireKey)
    end
    local uid = 0
    if type(item) == "table" then
        uid = tonumber(item.uniqueID) or tonumber(item.id) or 0
    end
    if uid <= 0 and type(job) == "table" then
        uid = tonumber(job.uid) or tonumber(job.uniqueID) or 0
    end
    if uid > 0 then
        return "uid:" .. tostring(uid)
    end
    if type(job) == "table" and job.specKey ~= nil then
        return "sk:" .. tostring(job.specKey)
    end
    return nil
end

--- Brass -> compact g/s/b (WAR: 1g = 100s = 10000b). Avoids "0g" for sub-gold spends.
function Buy.FormatMoneyBrass(brass)
    brass = math.max(0, math.floor((tonumber(brass) or 0) + 1e-9))
    local perGold = Buy.BRASS_PER_GOLD or 10000
    local perSilver = Buy.BRASS_PER_SILVER or 100
    local g = math.floor(brass / perGold)
    local rem = brass - (g * perGold)
    local s = math.floor(rem / perSilver)
    local b = rem - (s * perSilver)
    if g > 0 then
        if s > 0 and b > 0 then
            return string.format("%dg %ds %db", g, s, b)
        end
        if s > 0 then
            return string.format("%dg %ds", g, s)
        end
        if b > 0 then
            return string.format("%dg %db", g, b)
        end
        return string.format("%dg", g)
    end
    if s > 0 then
        if b > 0 then
            return string.format("%ds %db", s, b)
        end
        return string.format("%ds", s)
    end
    return string.format("%db", b)
end

local function FormatSpentLabel(brass)
    return Buy.FormatMoneyBrass(brass)
end

local function ChatMaterialFill(uid, name, count, spentBrass)
    local CC = StockPiler.CraftChatAdapter
    local spentLabel = FormatSpentLabel(spentBrass)
    if CC and CC.PrintWithItem then
        CC.PrintWithItem(
            "AutoBuy: " .. tostring(count) .. "x ",
            uid,
            name,
            " (spent " .. spentLabel .. ")"
        )
    elseif CC and CC.Print then
        CC.Print("AutoBuy: " .. tostring(count) .. "x " .. tostring(name or "?")
            .. " (spent " .. spentLabel .. ")")
    end
end

local function FlushFillChat()
    for key, row in pairs(Buy._fillChatPending) do
        if type(row) == "table" and (tonumber(row.count) or 0) > 0 then
            ChatMaterialFill(row.uid, row.name, row.count, row.spent)
        end
        Buy._fillChatPending[key] = nil
    end
end

local function NoteFillProgress(job, item, bought, unitCost)
    local key = JobAcquireKey(job, item) or "?"
    local row = Buy._fillChatPending[key]
    if type(row) ~= "table" then
        row = {
            uid = tonumber(item and item.uniqueID) or tonumber(job and job.uid) or 0,
            name = (item and item.name) or (job and job.name),
            count = 0,
            spent = 0,
            need = tonumber(job and job.deficit) or 0,
        }
        Buy._fillChatPending[key] = row
    end
    bought = tonumber(bought) or 0
    unitCost = tonumber(unitCost) or 0
    row.count = (tonumber(row.count) or 0) + bought
    row.spent = (tonumber(row.spent) or 0) + unitCost * bought
    local need = tonumber(row.need) or 0
    local acquired = VisitAcquired(key)
    -- Print when this material's need is filled, or immediately if visit already stopped
    -- (pending buy confirmed after store close - FlushFillChat already ran).
    if (need > 0 and acquired >= need) or Buy._visitStopReason ~= nil then
        ChatMaterialFill(row.uid, row.name, row.count, row.spent)
        Buy._fillChatPending[key] = nil
    end
end

--- Apply confirmed spend only (money/bag moved).
local function AccountConfirmedBuy(pending, liveMoney)
    if type(pending) ~= "table" then
        return
    end
    local qty = math.max(1, tonumber(pending.qty) or 1)
    local unitCost = tonumber(pending.unitCost) or 0
    local costTotal = tonumber(pending.costTotal) or (unitCost * qty)
    -- Count this spend against other open attempts before dropping same-uid rows.
    NoteForeignSpend(pending)
    -- A live confirm owns this uid - do not also late-confirm the same bag gain.
    ClearLateAttemptsForUid(pending.uid)
    ClearNoSpendCooldown(pending.uid)
    local key = pending.key
    Buy._visitPurchases = (tonumber(Buy._visitPurchases) or 0) + 1
    Buy._visitSpentBrass = (tonumber(Buy._visitSpentBrass) or 0) + costTotal
    Buy._visitBought = (tonumber(Buy._visitBought) or 0) + qty
    Buy._visitMoneyBrass = tonumber(liveMoney) or PlayerMoneyBrass()
    ArmPostBuyGap()
    local Watch = StockPiler.Watch
    if Watch and Watch.AddAutoBuySpentBrass then
        Watch.AddAutoBuySpentBrass(costTotal)
    end
    local Bus = StockPiler.EventBus
    if Bus and Bus.FireWatchUiDirty then
        Bus.FireWatchUiDirty({ reason = "autobuy-spent" })
    end
    if StockPilerTabWatch and StockPilerTabWatch.RefreshAutoBuyMoneyUi then
        StockPilerTabWatch.RefreshAutoBuyMoneyUi()
    end
    AddVisitAcquired(key, qty)
    if type(pending.job) == "table" and type(pending.item) == "table" then
        NoteFillProgress(pending.job, pending.item, qty, unitCost)
    elseif (tonumber(pending.uid) or 0) > 0 then
        -- Still announce when job/item tables were dropped but uid is known.
        NoteFillProgress(
            { uid = pending.uid, deficit = qty, acquireKey = pending.key },
            { uniqueID = pending.uid, name = pending.name },
            qty,
            unitCost
        )
    end
    LogBuy(string.format(
        "purchase uid=%s qty=%d cost=%d spent=%d moneyLeft=%d remainingWas=%d",
        tostring(pending.uid or 0),
        qty,
        costTotal,
        tonumber(Buy._visitSpentBrass) or 0,
        tonumber(Buy._visitMoneyBrass) or 0,
        tonumber(pending.remainingWas) or 0
    ))
end

--- Money drop not already accounted to other confirmed purchases.
--- nil when the money read is missing (live/before 0), so a failed read
--- cannot confirm a buy.
local function UnexplainedMoneyDrop(pending, live)
    if type(pending) ~= "table" then
        return nil
    end
    local before = tonumber(pending.beforeMoney) or 0
    live = tonumber(live) or 0
    if live <= 0 or before <= 0 then
        return nil
    end
    return (before - live) - (tonumber(pending.foreignSpend) or 0)
end

--- 1 brass tolerance, same window as the old `before - cost + 1` bound.
--- The upper bound is required: a larger drop belongs to a different purchase.
local function CostsMatchDrop(sumCost, unexplained)
    sumCost = tonumber(sumCost) or 0
    if unexplained == nil or sumCost <= 0 then
        return false
    end
    return unexplained + 1 >= sumCost and unexplained <= sumCost + 1
end

local function BagEvidenceOk(pending, bagNow)
    if type(pending) ~= "table" then
        return false
    end
    local uid = tonumber(pending.uid) or 0
    local qty = math.max(1, tonumber(pending.qty) or 1)
    bagNow = tonumber(bagNow)
    if bagNow == nil then
        bagNow = BagCountUid(uid)
    end
    local bagBefore = tonumber(pending.bagBefore) or 0
    return uid > 0 and bagNow >= (bagBefore + qty)
end

local function MaskHasBit(mask, index)
    local bit = 2 ^ (index - 1)
    return math.floor(mask / bit) % 2 >= 1
end

--- Unique subset of attempts whose costs explain each member's money drop.
--- Two different subsets that both fit means the drop is ambiguous: return nil
--- and wait for a bag count instead of crediting the wrong item.
local function UniqueMoneySubset(attempts, live)
    local n = #attempts
    if n < 1 or n > 8 then
        return nil
    end
    local found = nil
    local limit = (2 ^ n) - 1
    for mask = 1, limit do
        local sumCost = 0
        local members = {}
        for i = 1, n do
            if MaskHasBit(mask, i) then
                local pending = attempts[i]
                sumCost = sumCost + math.max(0, tonumber(pending.costTotal) or 0)
                members[#members + 1] = pending
            end
        end
        local consistent = sumCost > 0
        for i = 1, #members do
            if not CostsMatchDrop(sumCost, UnexplainedMoneyDrop(members[i], live)) then
                consistent = false
                break
            end
        end
        if consistent then
            if found ~= nil then
                return nil
            end
            found = members
        end
    end
    return found
end

--- Late attempts plus the in-flight pending buy (one row per uid).
--- Equal-cost drops must see both so UniqueMoneySubset can stay ambiguous (#30).
local function MoneyCandidates()
    local open = {}
    local seen = {}
    local rows = Buy._lateBuyAttempts
    if type(rows) == "table" then
        for i = 1, #rows do
            local pending = rows[i]
            if type(pending) == "table" then
                local uid = tonumber(pending.uid) or 0
                if uid > 0 and seen[uid] ~= true then
                    seen[uid] = true
                    open[#open + 1] = pending
                end
            end
        end
    end
    local pending = Buy._pendingBuy
    if type(pending) == "table" then
        local uid = tonumber(pending.uid) or 0
        if uid > 0 and seen[uid] ~= true then
            open[#open + 1] = pending
        end
    end
    return open
end

--- Keep a timed-out pending buy so a late bag/money snap can still chat.
local function StashLateBuyAttempt(pending)
    if type(pending) ~= "table" then
        return
    end
    local now = NowSec()
    local grace = tonumber(Buy.LATE_CONFIRM_GRACE_SEC) or 6
    local list = Buy._lateBuyAttempts
    if type(list) ~= "table" then
        list = {}
        Buy._lateBuyAttempts = list
    end
    list[#list + 1] = {
        beforeMoney = tonumber(pending.beforeMoney) or 0,
        bagBefore = tonumber(pending.bagBefore) or 0,
        unitCost = tonumber(pending.unitCost) or 0,
        costTotal = tonumber(pending.costTotal) or 0,
        qty = math.max(1, tonumber(pending.qty) or 1),
        key = pending.key,
        uid = tonumber(pending.uid) or 0,
        name = pending.name,
        at = tonumber(pending.at) or now,
        expiresAt = now + grace,
        job = pending.job,
        item = pending.item,
        remainingWas = pending.remainingWas,
        foreignSpend = tonumber(pending.foreignSpend) or 0,
        issueSeq = tonumber(pending.issueSeq) or 0,
        late = true,
    }
end

--- Bag evidence, or money evidence when the pending buy is in the unique
--- money subset of MoneyCandidates (late + pending). Equal-cost ambiguity
--- falls through to bag (#30 / L12).
local function PendingConfirmable(pending, live, bagNow)
    if type(pending) ~= "table" then
        return false
    end
    live = tonumber(live) or PlayerMoneyBrass()
    if BagEvidenceOk(pending, bagNow) then
        return true
    end
    local costTotal = tonumber(pending.costTotal) or 0
    if not CostsMatchDrop(costTotal, UnexplainedMoneyDrop(pending, live)) then
        return false
    end
    local subset = UniqueMoneySubset(MoneyCandidates(), live)
    if type(subset) ~= "table" then
        return false
    end
    for i = 1, #subset do
        if subset[i] == pending then
            return true
        end
    end
    return false
end

--- Confirm buys that timed out as no-spend before inventory/money caught up.
--- Bag evidence is per uid. Money evidence must be a unique subset of late
--- attempts plus the in-flight pending buy, so one purchase cannot confirm a
--- different item (EXE-1 / #30). Only late members are confirmed here; the
--- pending buy is left to ResolvePendingBuy.
local function TryLateConfirmBuys()
    local list = Buy._lateBuyAttempts
    if type(list) ~= "table" or #list < 1 then
        return false
    end
    local now = NowSec()
    local any = false
    local live = PlayerMoneyBrass()

    local function activeLateAttempts()
        local open = {}
        local seen = {}
        local rows = Buy._lateBuyAttempts
        if type(rows) ~= "table" then
            return open
        end
        for i = 1, #rows do
            local pending = rows[i]
            if type(pending) == "table" then
                local uid = tonumber(pending.uid) or 0
                if uid > 0 and seen[uid] ~= true then
                    seen[uid] = true
                    open[#open + 1] = pending
                end
            end
        end
        return open
    end

    local function confirm(pending, how)
        local uid = tonumber(pending.uid) or 0
        if uid <= 0 then
            return false
        end
        ClearNoSpendCooldown(uid)
        AccountConfirmedBuy(pending, live)
        LogBuy(string.format(
            "late-confirm uid=%s qty=%d bag=%d->%d via=%s",
            tostring(uid),
            math.max(1, tonumber(pending.qty) or 1),
            tonumber(pending.bagBefore) or 0,
            BagCountUid(uid),
            tostring(how)
        ))
        any = true
        return true
    end

    local open = activeLateAttempts()
    for i = 1, #open do
        local pending = open[i]
        if BagEvidenceOk(pending) then
            confirm(pending, "bag")
            live = PlayerMoneyBrass()
        end
    end

    local guard = 0
    while guard < 8 do
        guard = guard + 1
        local beforeCount = type(Buy._lateBuyAttempts) == "table" and #Buy._lateBuyAttempts or 0
        local subset = UniqueMoneySubset(MoneyCandidates(), live)
        if type(subset) ~= "table" or #subset < 1 then
            break
        end
        local confirmedAny = false
        for i = 1, #subset do
            if subset[i].late == true then
                confirm(subset[i], "money")
                confirmedAny = true
            end
        end
        local afterCount = type(Buy._lateBuyAttempts) == "table" and #Buy._lateBuyAttempts or 0
        if confirmedAny ~= true or afterCount >= beforeCount then
            break
        end
        live = PlayerMoneyBrass()
    end

    local keep = {}
    local rows = Buy._lateBuyAttempts
    if type(rows) == "table" then
        for i = 1, #rows do
            local pending = rows[i]
            if type(pending) == "table" then
                local uid = tonumber(pending.uid) or 0
                local expires = tonumber(pending.expiresAt) or 0
                if expires > 0 and now > 0 and now >= expires then
                    LogBuy(string.format(
                        "late-confirm-expire uid=%s qty=%d",
                        tostring(uid),
                        math.max(1, tonumber(pending.qty) or 1)
                    ))
                    if uid > 0 then
                        ClearNoSpendCooldown(uid)
                    end
                else
                    keep[#keep + 1] = pending
                end
            end
        end
    end
    Buy._lateBuyAttempts = keep
    return any
end

--- Resolve open pending buy: confirm spend, timeout no-spend, or still waiting.
--- Money alone confirms only when the pending buy is in the unique money
--- subset of MoneyCandidates (late + pending). Equal-cost ambiguity falls
--- through to bag evidence (#30).
--- @return "confirmed"|"waiting"|"no-spend"|nil
local function ResolvePendingBuy()
    local pending = Buy._pendingBuy
    if type(pending) ~= "table" then
        return nil
    end
    local live = PlayerMoneyBrass()
    local before = tonumber(pending.beforeMoney) or 0
    local costTotal = tonumber(pending.costTotal) or 0
    local qty = math.max(1, tonumber(pending.qty) or 1)
    local uid = tonumber(pending.uid) or 0
    local bagNow = BagCountUid(uid)
    local bagBefore = tonumber(pending.bagBefore) or 0
    if PendingConfirmable(pending, live, bagNow) then
        AccountConfirmedBuy(pending, live > 0 and live or before)
        Buy._pendingBuy = nil
        return "confirmed"
    end
    local at = tonumber(pending.at) or 0
    local now = NowSec()
    local timeout = tonumber(Buy.PENDING_BUY_TIMEOUT_SEC) or 3.5
    if at > 0 and now > 0 and (now - at) >= timeout then
        if live <= 0 or live >= before then
            LogBuy(string.format(
                "buy-no-spend uid=%s qty=%d cost=%d before=%d live=%d bag=%d->%d",
                tostring(uid),
                qty,
                costTotal,
                before,
                live,
                bagBefore,
                bagNow
            ))
            StashLateBuyAttempt(pending)
            -- Hold the uid for the full late-confirm grace (not the short chill),
            -- so IssueOne cannot rebuy while bag/money may still land (#9).
            ArmNoSpendCooldown(uid, Buy.LATE_CONFIRM_GRACE_SEC)
            Buy._pendingBuy = nil
            return "no-spend"
        end
        -- Money dropped some but not full cost yet - keep waiting briefly.
        if (now - at) < (timeout + 1) then
            return "waiting"
        end
        LogBuy(string.format(
            "buy-no-spend uid=%s partial before=%d live=%d",
            tostring(uid),
            before,
            live
        ))
        StashLateBuyAttempt(pending)
        ArmNoSpendCooldown(uid, Buy.LATE_CONFIRM_GRACE_SEC)
        Buy._pendingBuy = nil
        return "no-spend"
    end
    return "waiting"
end

--- Confirm or drop open pending before visit-stop chat (store often closes mid-confirm).
--- After ResolvePendingBuy returns "waiting", inputs are unchanged this frame, so
--- re-evaluating cannot succeed; stash for late confirm instead (L12).
local function FinalizePendingBuyForStop()
    local pending = Buy._pendingBuy
    if type(pending) ~= "table" then
        return
    end
    local state = ResolvePendingBuy()
    if state == "confirmed" or state == "no-spend" then
        return
    end
    local uid = tonumber(pending.uid) or 0
    local live = PlayerMoneyBrass()
    local bagNow = BagCountUid(uid)
    local bagBefore = tonumber(pending.bagBefore) or 0
    local qty = math.max(1, tonumber(pending.qty) or 1)
    local before = tonumber(pending.beforeMoney) or 0
    LogBuy(string.format(
        "pending-drop-on-stop uid=%s qty=%d bag=%d->%d money=%d->%d",
        tostring(uid),
        qty,
        bagBefore,
        bagNow,
        before,
        live
    ))
    -- Store often closes before bag/money catch up - keep grace for chat.
    StashLateBuyAttempt(pending)
    Buy._pendingBuy = nil
end

local function ChatVisitStop(reason)
    if Buy._visitStopReason ~= nil then
        return
    end
    TryLateConfirmBuys()
    FinalizePendingBuyForStop()
    Buy._visitStopReason = tostring(reason or "stop")
    FlushFillChat()
    local bought = tonumber(Buy._visitBought) or 0
    local spent = tonumber(Buy._visitSpentBrass) or 0
    local CC = StockPiler.CraftChatAdapter
    if CC and CC.Print and bought > 0 then
        CC.Print("AutoBuy: visit stop (" .. Buy._visitStopReason
            .. ") bought=" .. tostring(bought)
            .. " spent=" .. FormatSpentLabel(spent))
    end
    LogBuy("visit-stop " .. Buy._visitStopReason
        .. " bought=" .. tostring(bought) .. " spent=" .. tostring(spent))
end

local function WakeBrewAfterBuyFill(reason)
    reason = tostring(reason or "buy-fill")
    local Planner = StockPiler.Planner
    if Planner and Planner.InvalidateHaveWarm then
        Planner.InvalidateHaveWarm()
    end
    local PS = StockPiler.PlanSnapshot
    local plan = PS and PS.Get and PS.Get()
    local planRows = type(plan) == "table" and plan.rows or nil
    if not (type(planRows) == "table" and #planRows > 0)
        and Planner and Planner.SyncLiveStatusClosedWindow
    then
        Planner.SyncLiveStatusClosedWindow()
    end
    if Planner and Planner.LiveRecount then
        Planner.LiveRecount({
            clearClosedSnap = true,
            invalidateStamps = true,
            allowWarmHave = true,
            syncSnapshot = true,
        })
    end
    local Brew = StockPiler.Brew
    if Brew and Brew.InvalidateCanBrewCache then
        Brew.InvalidateCanBrewCache()
    end
    if Brew and Brew.MaybeNotifyBrewReady then
        Brew.MaybeNotifyBrewReady()
    end
    local Bus = StockPiler.EventBus
    if Bus and Bus.FireFooterDirty then
        Bus.FireFooterDirty({ reason = "buy-fill" })
    end
    if StockPiler.Ui and StockPiler.Ui.BypassWatchThrottle then
        StockPiler.Ui.BypassWatchThrottle()
    end
    if Bus and Bus.FireWatchUiDirty then
        Bus.FireWatchUiDirty({ immediate = true, recount = true, reason = "buy-fill" })
    end
    -- Do not wait for store-close / coalesced flush - visit often stays open.
    if StockPilerTabWatch and StockPilerTabWatch.UpdateRows then
        StockPilerTabWatch.UpdateRows({ keepVisible = true })
    end
    LogBuy("wake-brew-after-fill reason=" .. reason)
end

local function ArmPlanAfterBuyFill(reason)
    if Buy._planArmedAfterFill == true then
        return
    end
    if (tonumber(Buy._visitBought) or 0) <= 0 then
        return
    end
    Buy._planArmedAfterFill = true
    -- Batch invalidate after visit - no per-purchase Flatten.
    if StockPiler.PlanSnapshot and StockPiler.PlanSnapshot.Invalidate then
        StockPiler.PlanSnapshot.Invalidate()
    end
    if StockPiler.Scheduler and StockPiler.Scheduler.EnqueuePlanRebuild then
        StockPiler.Scheduler.EnqueuePlanRebuild({ reason = reason or "buy-fill" })
    end
    -- Do not wait for coalesced rebuild / vendor-open Watch defer - wake Brew now.
    WakeBrewAfterBuyFill(reason or "buy-fill")
end

local function ResetVisit()
    -- Vendor reopen used to drop unconfirmed buys before their bag/money
    -- evidence arrived (EXE-3). Confirm what we can, stash the in-flight
    -- broadcast, and let the rest expire by time only.
    local lateConfirmed = TryLateConfirmBuys() == true
    local pendingConfirmed = false
    if type(Buy._pendingBuy) == "table" then
        local state = ResolvePendingBuy()
        if state == "confirmed" then
            pendingConfirmed = true
        elseif type(Buy._pendingBuy) == "table" then
            StashLateBuyAttempt(Buy._pendingBuy)
            Buy._pendingBuy = nil
        end
    end
    -- Only re-arm when this reopen actually confirmed something. Store-close
    -- may have already armed; clearing the latch lets late confirms wake Brew
    -- without an extra rebuild on every reopen (L10 / #26 L3).
    if lateConfirmed or pendingConfirmed then
        Buy._planArmedAfterFill = false
        ArmPlanAfterBuyFill("visit-reset")
    end
    Buy._visitPurchases = 0
    Buy._visitSpentBrass = 0
    Buy._visitMoneyBrass = PlayerMoneyBrass()
    Buy._visitBought = 0
    Buy._visitStopReason = nil
    Buy._visitAcquired = {}
    Buy._fillChatPending = {}
    Buy._planArmedAfterFill = false
    Buy._pendingBuy = nil
    Buy._noSpendCooldownUntil = {}
    Buy._nextBuyAfter = 0
    Buy.InvalidateJobsCache()
end

local function BeginVisitIfNeeded()
    local VA = StockPiler.VendorAdapter
    local open = VA and VA.IsStoreOpen and VA.IsStoreOpen() == true
    if open and Buy._storeWasOpen ~= true then
        ResetVisit()
        local Caps = StockPiler.TradeSkillCaps
        Buy._allowPlantBuys = not (Caps and Caps.CanAutoGrow and Caps.CanAutoGrow() == true)
        if VA.RefreshMatchIndex then
            VA.RefreshMatchIndex()
        end
        if StockPiler.Scheduler and StockPiler.Scheduler.WakeAutoBuy then
            StockPiler.Scheduler.WakeAutoBuy()
        end
        LogBuy("visit-open allowPlantBuys=" .. tostring(Buy._allowPlantBuys))
    elseif not open and Buy._storeWasOpen == true then
        ChatVisitStop("close")
        ArmPlanAfterBuyFill("store-close")
        -- idle-no-jobs may have armed already; still paint Watch now that the store is gone.
        if (tonumber(Buy._visitBought) or 0) > 0 then
            WakeBrewAfterBuyFill("store-close")
        end
        Buy.InvalidateJobsCache()
        -- Refine was deferred while the store was open (SendUseItem closes vendor).
        if StockPiler.Refine and StockPiler.Refine.MarkRefineDue then
            StockPiler.Refine.MarkRefineDue("store-close")
        end
        if StockPiler.Scheduler and StockPiler.Scheduler.WakeAutoGrow then
            StockPiler.Scheduler.WakeAutoGrow()
        end
    end
    Buy._storeWasOpen = open == true
    return open == true
end

----------------------------------------------------------------
-- Public settings / cache
----------------------------------------------------------------

function Buy.IsEnabled()
    local Watch = StockPiler.Watch
    if not Watch or not Watch.IsAutoBuyEnabled or Watch.IsAutoBuyEnabled() ~= true then
        return false
    end
    local Caps = StockPiler.TradeSkillCaps
    if Caps and Caps.CanAutoBuy and Caps.CanAutoBuy() ~= true then
        return false
    end
    return true
end

--- Hold Watch rebind only while this visit is still purchasing. After fill/stop,
--- Watch must paint Buy flasks/materials -> Ready even if the store stays open.
function Buy.ShouldDeferWatchPaint()
    if Buy.IsEnabled() ~= true then
        return false
    end
    local VA = StockPiler.VendorAdapter
    if not VA or not VA.IsStoreOpen or VA.IsStoreOpen() ~= true then
        return false
    end
    return Buy._visitStopReason == nil
end

function Buy.GetReserveGold()
    local Watch = StockPiler.Watch
    if Watch and Watch.GetAutoBuyReserveGold then
        return Watch.GetAutoBuyReserveGold()
    end
    return 10
end

function Buy.GetBudgetGold()
    local Watch = StockPiler.Watch
    if Watch and Watch.GetAutoBuyBudgetGold then
        return Watch.GetAutoBuyBudgetGold()
    end
    return 50
end

--- Lifetime AutoBuy spend against the hard allowance (persisted).
function Buy.GetSpentBrass()
    local Watch = StockPiler.Watch
    if Watch and Watch.GetAutoBuySpentBrass then
        return Watch.GetAutoBuySpentBrass()
    end
    return 0
end

function Buy.GetAllowanceRemainingBrass()
    local budget = Buy.GetBudgetGold() * (Buy.BRASS_PER_GOLD or 10000)
    return math.max(0, budget - Buy.GetSpentBrass())
end

function Buy.IsAllowanceExhausted()
    return Buy.GetAllowanceRemainingBrass() <= 0
end

function Buy.InvalidateJobsCache()
    Buy._jobsCache = nil
    Buy._jobsCacheKey = nil
end

--- Clear visit money-gate stop when allowance/reserve again permits buying.
--- Does not wipe lifetime spent (use ResetAllowanceSpent for that).
function Buy.ClearMoneyGateStop(via)
    if Buy._visitStopReason ~= "reserve" and Buy._visitStopReason ~= "budget" then
        return false
    end
    local was = Buy._visitStopReason
    via = tostring(via or "?")
    if was == "budget" and via ~= "reset-spent" then
        if Buy.IsAllowanceExhausted() then
            return false
        end
    end
    Buy._visitStopReason = nil
    Buy._pendingBuy = nil
    Buy._noSpendCooldownUntil = {}
    Buy._visitMoneyBrass = PlayerMoneyBrass()
    Buy.InvalidateJobsCache()
    LogBuy(string.format(
        "resume clear-stop was=%s via=%s money=%d spentBrass=%d reserveGold=%d budgetGold=%d",
        tostring(was),
        via,
        tonumber(Buy._visitMoneyBrass) or 0,
        Buy.GetSpentBrass(),
        Buy.GetReserveGold(),
        Buy.GetBudgetGold()
    ))
    if StockPiler.Scheduler and StockPiler.Scheduler.WakeAutoBuy then
        StockPiler.Scheduler.WakeAutoBuy()
    end
    return true
end

function Buy.ResetAllowanceSpent()
    local Watch = StockPiler.Watch
    if Watch and Watch.ResetAutoBuySpentBrass then
        Watch.ResetAutoBuySpentBrass()
    end
    Buy.ClearMoneyGateStop("reset-spent")
    Buy.InvalidateJobsCache()
    LogBuy("allowance-spent-reset")
    local Bus = StockPiler.EventBus
    if Bus and Bus.FireWatchUiDirty then
        Bus.FireWatchUiDirty({ immediate = true, reason = "allowance-reset" })
    end
    local VA = StockPiler.VendorAdapter
    if VA and VA.IsStoreOpen and VA.IsStoreOpen() == true then
        if StockPiler.Scheduler and StockPiler.Scheduler.WakeAutoBuy then
            StockPiler.Scheduler.WakeAutoBuy()
        end
    end
    return true
end

function Buy.OnMoneySettingsChanged()
    -- Raising allowance (or lowering reserve) can unblock; never wipe spent here.
    Buy.ClearMoneyGateStop("money-chip")
    Buy.InvalidateJobsCache()
    local VA = StockPiler.VendorAdapter
    if VA and VA.IsStoreOpen and VA.IsStoreOpen() == true then
        if StockPiler.Scheduler and StockPiler.Scheduler.WakeAutoBuy then
            StockPiler.Scheduler.WakeAutoBuy()
        end
    end
end

function Buy.OnStoreShow()
    local SU = StockPiler.SkillUp
    if SU then
        -- Last visit's empty vial shelf does not apply to this one.
        SU._apoNoVendorContainer = nil
    end
    local VA = StockPiler.VendorAdapter
    if VA and VA.EnsureStoreHook then
        VA.EnsureStoreHook()
    end
    if VA and VA.FlushPendingStoreRefresh then
        VA.FlushPendingStoreRefresh()
    end
    BeginVisitIfNeeded()
    if StockPiler.Scheduler and StockPiler.Scheduler.WakeAutoBuy then
        StockPiler.Scheduler.WakeAutoBuy()
    end
end

----------------------------------------------------------------
-- Jobs (fair max bottle-gap focus)
----------------------------------------------------------------

function Buy.CollectBuyJobs()
    local Inv = StockPiler.Inventory
    local snapGen = Inv and Inv.GetSnapGen and Inv.GetSnapGen() or 0
    local Caps = StockPiler.TradeSkillCaps
    local skillHash = Caps and Caps.LevelsHash and Caps.LevelsHash() or ""
    local watchGen = StockPiler.Watch and StockPiler.Watch.GetGen and StockPiler.Watch.GetGen() or 0
    local skillUpHash = "0"
    local SkillUp = StockPiler.SkillUp
    if SkillUp then
        local parts = {}
        if SkillUp.IsCultEnabled and SkillUp.IsCultEnabled() == true then
            parts[#parts + 1] = "c:" .. tostring(SkillUp.TargetMaxSkill and SkillUp.TargetMaxSkill() or 0)
        end
        if SkillUp.IsApoEnabled and SkillUp.IsApoEnabled() == true then
            parts[#parts + 1] = "a:" .. tostring(SkillUp.ApoTargetTier and SkillUp.ApoTargetTier() or 0)
                .. "/" .. tostring(SkillUp.ApoContainerBuyTarget and SkillUp.ApoContainerBuyTarget() or 0)
                .. "/" .. tostring(SkillUp.CountApoContainers and SkillUp.CountApoContainers() or 0)
        end
        if #parts > 0 then
            skillUpHash = table.concat(parts, "|")
        end
    end
    local UpgradeSeed = StockPiler.UpgradeSeed
    local upgradeHash = "0"
    if UpgradeSeed and UpgradeSeed.IsEnabled and UpgradeSeed.IsEnabled() == true then
        upgradeHash = "1"
    end
    local cacheKey = tostring(snapGen) .. ":" .. tostring(watchGen) .. ":" .. tostring(skillHash)
        .. ":" .. tostring(Buy._allowPlantBuys and 1 or 0) .. ":" .. skillUpHash .. ":" .. upgradeHash
    if type(Buy._jobsCache) == "table" and Buy._jobsCacheKey == cacheKey then
        return Buy._jobsCache
    end

    local jobs = {}
    local Planner = StockPiler.Planner
    if Planner and Planner.CollectVendorBuyJobs then
        jobs = Planner.CollectVendorBuyJobs({
            allowPlantBuys = Buy._allowPlantBuys == true,
        }) or {}
    end

    -- Reject growables when CanAutoGrow (allowPlantBuys false).
    if Buy._allowPlantBuys ~= true and type(jobs) == "table" then
        local filtered = {}
        for i = 1, #jobs do
            local job = jobs[i]
            local growable = job and (job.growable == true or job.isGrowable == true)
            if not growable or (job and (job.skillUp == true or job.upgradeSeed == true)) then
                filtered[#filtered + 1] = job
            end
        end
        jobs = filtered
    end

    -- SkillUp Cult: buy matching main seeds when idle and bags are empty.
    local SkillUp = StockPiler.SkillUp
    if SkillUp and SkillUp.CollectBuyJobs then
        local skillJobs = SkillUp.CollectBuyJobs() or {}
        for i = 1, #skillJobs do
            jobs[#jobs + 1] = skillJobs[i]
        end
    end

    -- Upgrade Seed: buy lowest family rung / top up climb seed.
    local UpgradeSeed = StockPiler.UpgradeSeed
    if UpgradeSeed and UpgradeSeed.CollectBuyJobs then
        local upJobs = UpgradeSeed.CollectBuyJobs() or {}
        for i = 1, #upJobs do
            jobs[#jobs + 1] = upJobs[i]
        end
    end

    Buy._jobsCache = jobs
    Buy._jobsCacheKey = cacheKey
    return jobs
end

function Buy.FindStoreMatch(job)
    if type(job) ~= "table" then
        return nil, 0
    end
    local VA = StockPiler.VendorAdapter
    if not VA then
        return nil, 0
    end
    local MS = StockPiler.MaterialSpec
    local uid = tonumber(job.uid) or tonumber(job.uniqueID) or 0
    local spec = job.spec

    local function RowCost(row, item)
        local cost = tonumber(row and row.cost) or tonumber(item and item.cost) or 0
        if cost <= 0 and type(item) == "table" then
            cost = tonumber(item.price) or tonumber(item.sellPrice) or 0
        end
        return cost
    end

    -- Prefer fingerprint match across store (Artisan's vs Fabricated vials,
    -- incomplete main stubs vs preserved butcher twins, etc.).
    local index = VA.GetMatchIndex and VA.GetMatchIndex()
    if type(spec) == "table" and type(index) == "table" and type(index.rows) == "table"
        and MS and MS.Matches
    then
        local bestItem, bestCost = nil, nil
        for i = 1, #index.rows do
            local row = index.rows[i]
            local item = row and row.item
            if type(item) == "table" and not HasAltCurrency(item) then
                if row.canbuy == false then
                    -- skip sold-out / gated rows
                elseif StoreItemRejectedForBuy(item, job) then
                    -- skip cult additives / growables
                elseif MS.Matches(item, spec) == true
                    or (MS.ProductMatches and MS.ProductMatches(item, spec) == true)
                then
                    local cost = RowCost(row, item)
                    if bestItem == nil or (cost > 0 and cost < (bestCost or math.huge))
                        or (bestCost == 0 and cost > 0)
                    then
                        bestItem = item
                        bestCost = cost
                    end
                    -- Exact uid hit wins immediately.
                    if uid > 0 and (tonumber(item.uniqueID) or 0) == uid then
                        return item, cost
                    end
                end
            end
        end
        if bestItem ~= nil then
            return bestItem, bestCost or 0
        end
    end

    -- Container fallback: bag twins share icon with vendor Artisan's/Fabricated vials
    -- when store rows lack craftingSkillRequirement / bonuses (fingerprint miss).
    if type(spec) == "table"
        and tostring(spec.role or job.role or "") == "container"
        and type(index) == "table"
        and type(index.rows) == "table"
    then
        local Inv = StockPiler.Inventory
        local iconSet = {}
        local bagUids = {}
        if Inv and Inv.ForEachItem and MS then
            Inv.ForEachItem(function(bagItem)
                if type(bagItem) ~= "table" then
                    return
                end
                local ok = false
                if MS.ProductMatches and MS.ProductMatches(bagItem, spec) == true then
                    ok = true
                elseif MS.Matches and MS.Matches(bagItem, spec) == true then
                    ok = true
                end
                if ok then
                    local icon = tonumber(bagItem.iconNum) or 0
                    if icon > 0 then
                        iconSet[icon] = true
                    end
                    local bUid = tonumber(bagItem.uniqueID) or tonumber(bagItem.id) or 0
                    if bUid > 0 then
                        bagUids[bUid] = true
                    end
                end
            end)
        end
        local bestItem, bestCost = nil, nil
        for i = 1, #index.rows do
            local row = index.rows[i]
            local item = row and row.item
            if type(item) == "table" and not HasAltCurrency(item) and row.canbuy ~= false then
                if StoreItemRejectedForBuy(item, job) then
                    -- skip
                else
                    local sUid = tonumber(item.uniqueID) or tonumber(item.id) or 0
                    local icon = tonumber(item.iconNum) or 0
                    local twin = (sUid > 0 and bagUids[sUid] == true)
                        or (icon > 0 and iconSet[icon] == true)
                    if twin then
                        local cost = RowCost(row, item)
                        if bestItem == nil or (cost > 0 and cost < (bestCost or math.huge))
                            or (bestCost == 0 and cost > 0)
                        then
                            bestItem = item
                            bestCost = cost
                        end
                    end
                end
            end
        end
        if bestItem ~= nil then
            return bestItem, bestCost or 0
        end
    end

    -- Fallback: exact uid rows when no spec match.
    if uid > 0 and VA.FindStoreRowsByUid then
        local rows = VA.FindStoreRowsByUid(uid)
        if type(rows) == "table" then
            for i = 1, #rows do
                local row = rows[i]
                local item = row and row.item or row
                if type(item) == "table" and not HasAltCurrency(item) then
                    if StoreItemRejectedForBuy(item, job) then
                        -- skip
                    else
                        return item, RowCost(row, item)
                    end
                end
            end
        end
    end
    return nil, 0
end

----------------------------------------------------------------
-- IssueOne / tick
----------------------------------------------------------------

function Buy.IssueOne(opId)
    if Buy._visitStopReason ~= nil then
        return false
    end
    if not Buy.IsEnabled() then
        return false
    end
    local VA = StockPiler.VendorAdapter
    if not VA or not VA.IsStoreOpen or VA.IsStoreOpen() ~= true then
        return false
    end
    if VA.IsBuybackView and VA.IsBuybackView() == true then
        return false
    end

    local Perf = StockPiler.Perf
    if Perf and Perf.Begin then
        Perf.Begin("Buy.IssueOne")
    end
    local function done(ok)
        if Perf and Perf.End then
            Perf.End("Buy.IssueOne")
        end
        return ok == true
    end

    -- Late bag/money after a false no-spend still counts + chats.
    if TryLateConfirmBuys() then
        if StockPiler.Scheduler and StockPiler.Scheduler.WakeAutoBuy then
            StockPiler.Scheduler.WakeAutoBuy()
        end
        return done(true)
    end

    -- Confirm or wait on in-flight broadcast before starting another buy.
    -- Waiting must return true so Orch keeps the buy tick (refine must not steal
    -- and refine SendUseItem that closes the vendor).
    local pendingState = ResolvePendingBuy()
    if pendingState == "waiting" then
        if StockPiler.Scheduler and StockPiler.Scheduler.WakeAutoBuy then
            StockPiler.Scheduler.WakeAutoBuy()
        end
        return done(true)
    end
    if pendingState == "confirmed" then
        if StockPiler.Scheduler and StockPiler.Scheduler.WakeAutoBuy then
            StockPiler.Scheduler.WakeAutoBuy()
        end
        return done(true)
    end
    -- "no-spend" or nil -> continue to next purchase attempt.

    local nowGate = NowSec()
    local nextBuyAfter = tonumber(Buy._nextBuyAfter) or 0
    if nextBuyAfter > 0 and nowGate > 0 and nowGate < nextBuyAfter then
        if StockPiler.Scheduler and StockPiler.Scheduler.WakeAutoBuy then
            StockPiler.Scheduler.WakeAutoBuy()
        end
        return done(true)
    end

    local purchases = tonumber(Buy._visitPurchases) or 0
    if purchases >= (Buy.MAX_PURCHASES_PER_VISIT or 80) then
        ChatVisitStop("cap")
        ArmPlanAfterBuyFill("cap")
        return done(false)
    end

    local jobs = Buy.CollectBuyJobs()
    if type(jobs) ~= "table" or #jobs == 0 then
        -- After a successful fill, stop the visit so Orch does not re-IssueOne
        -- every tick (was spamming idle-no-jobs while the store stayed open).
        if (tonumber(Buy._visitBought) or 0) > 0 and Buy._visitStopReason == nil then
            local meta = StockPiler.Planner and StockPiler.Planner._vendorBuyJobsMeta
            if type(meta) == "table" then
                LogBuy(string.format(
                    "idle-no-jobs source=%s maxBottleGap=%s focusWatches=%s",
                    tostring(meta.source),
                    tostring(meta.maxBottleGap),
                    tostring(meta.focusWatchCount)
                ))
            end
            -- Stop tick spam while store stays open; OnPlanUpdated resumes
            -- when brew/potent results create fresh flask/mat deficits.
            ChatVisitStop("idle-no-jobs")
            ArmPlanAfterBuyFill("idle-no-jobs")
        end
        return done(false)
    end

    -- Gate reserve on live gold; allowance on persisted lifetime spent.
    local money = PlayerMoneyBrass()
    Buy._visitMoneyBrass = money
    local reserve = Buy.GetReserveGold() * (Buy.BRASS_PER_GOLD or 10000)
    local budget = Buy.GetBudgetGold() * (Buy.BRASS_PER_GOLD or 10000)
    local spent = Buy.GetSpentBrass()
    local reserveBlock = false
    local budgetBlock = false

    local matched = 0
    local zeroCost = 0
    local noMatch = 0
    local cooldownBlocked = false
    local containerMatched = false
    for i = 1, #jobs do
        local job = jobs[i]
        local item, unitCost = Buy.FindStoreMatch(job)
        unitCost = tonumber(unitCost) or 0
        if job.skillUp == true and tostring(job.role or "") == "container" then
            local SU = StockPiler.SkillUp
            if type(item) == "table" then
                containerMatched = true
                if SU then
                    SU._apoNoVendorContainer = nil
                end
            elseif containerMatched ~= true and SU then
                SU._apoNoVendorContainer = true
            end
        end
        if type(item) ~= "table" then
            noMatch = noMatch + 1
        elseif unitCost <= 0 then
            zeroCost = zeroCost + 1
            LogBuy(string.format(
                "skip zero-cost uid=%s slot=%s key=%s",
                tostring(tonumber(item.uniqueID) or job.uid or 0),
                tostring(item.slotNum),
                tostring(job.specKey or job.uid or i)
            ))
        elseif type(item) == "table" and unitCost > 0 then
            matched = matched + 1
            local key = JobAcquireKey(job, item)
            local slotNum = tonumber(item.slotNum)
            local uid = tonumber(item.uniqueID) or tonumber(item.id) or tonumber(job.uid) or 0
            if key == nil or slotNum == nil then
                LogBuy("skip bad-slot-or-key job=" .. tostring(job.specKey or job.uid or i))
            elseif IsUidOnCooldown(uid) or OpenLateQtyForUid(uid) > 0 then
                -- Recent buy-no-spend / open late-confirm for this uid - stay armed (#9).
                cooldownBlocked = true
            else
                local deficit = tonumber(job.deficit) or 0
                local lateQty = OpenLateQtyForUid(uid)
                local remaining = math.max(0, deficit - VisitAcquired(key) - lateQty)
                if remaining >= 1 then
                    local vendorMax = 100
                    local stackCount = tonumber(item.stackCount) or 1
                    if stackCount > 1 then
                        vendorMax = stackCount
                    end
                    local reserveLate, budgetLate = OpenLateCostBrass()
                    local maxByReserve = math.floor((money - reserve - reserveLate) / unitCost)
                    local maxByBudget = math.floor((budget - spent - budgetLate) / unitCost)
                    local qty = math.min(remaining, vendorMax, maxByReserve, maxByBudget)
                    if qty < 1 then
                        if maxByReserve < 1 then
                            reserveBlock = true
                        elseif maxByBudget < 1 then
                            budgetBlock = true
                        end
                    else
                        local costTotal = unitCost * qty
                        if money - reserveLate - costTotal < reserve then
                            reserveBlock = true
                        else
                            local beforeMoney = money
                            local bagBefore = BagCountUid(uid)
                            local ok, err = VA.BuyItem(item, qty)
                            if ok ~= true then
                                LogBuy(string.format(
                                    "fail BuyItem slot=%d qty=%d err=%s",
                                    slotNum,
                                    qty,
                                    tostring(err)
                                ))
                                return done(false)
                            end
                            -- No open late stash for this uid (blocked above); clear any stale.
                            ClearLateAttemptsForUid(uid)
                            -- Broadcast only - confirm on money/bag movement next tick.
                            Buy._issueSeq = (tonumber(Buy._issueSeq) or 0) + 1
                            Buy._pendingBuy = {
                                beforeMoney = beforeMoney,
                                bagBefore = bagBefore,
                                unitCost = unitCost,
                                costTotal = costTotal,
                                qty = qty,
                                key = key,
                                uid = uid,
                                name = item.name or job.name,
                                at = NowSec(),
                                job = job,
                                item = item,
                                remainingWas = remaining,
                                foreignSpend = 0,
                                issueSeq = Buy._issueSeq,
                            }
                            LogBuy(string.format(
                                "buy-pending uid=%s slot=%d qty=%d cost=%d before=%d opId=%s",
                                tostring(uid),
                                slotNum,
                                qty,
                                costTotal,
                                beforeMoney,
                                tostring(opId or "?")
                            ))
                            if StockPiler.Scheduler and StockPiler.Scheduler.WakeAutoBuy then
                                StockPiler.Scheduler.WakeAutoBuy()
                            end
                            -- Same-frame confirm if money already moved.
                            local immediate = ResolvePendingBuy()
                            if immediate == "confirmed" then
                                return done(true)
                            end
                            if immediate == "no-spend" then
                                return done(false)
                            end
                            return done(true)
                        end
                    end
                end
            end
        end
    end

    if reserveBlock then
        ChatVisitStop("reserve")
        ArmPlanAfterBuyFill("reserve")
        return done(false)
    end
    if budgetBlock then
        ChatVisitStop("budget")
        ArmPlanAfterBuyFill("budget")
        return done(false)
    end
    -- Jobs remain but uid is on short no-spend cooldown - keep buying phase alive.
    if cooldownBlocked and Buy._visitStopReason == nil then
        if StockPiler.Scheduler and StockPiler.Scheduler.WakeAutoBuy then
            StockPiler.Scheduler.WakeAutoBuy()
        end
        return done(true)
    end
    if #jobs > 0 and matched <= 0 then
        local indexRows = 0
        local index = VA.GetMatchIndex and VA.GetMatchIndex()
        if type(index) == "table" and type(index.rows) == "table" then
            indexRows = #index.rows
        end
        local now = NowSec()
        local last = tonumber(Buy._lastNoMatchLogAt) or 0
        if now <= 0 or (now - last) >= 3 then
            Buy._lastNoMatchLogAt = now
            LogBuy(string.format(
                "no-store-match jobs=%d noMatch=%d zeroCost=%d indexRows=%s buyback=%s",
                #jobs,
                noMatch,
                zeroCost,
                tostring(indexRows),
                tostring(VA.IsBuybackView and VA.IsBuybackView() == true)
            ))
        end
    end
    return done(false)
end

function Buy.NeedsTick()
    if not Buy.IsEnabled() then
        return false
    end
    local VA = StockPiler.VendorAdapter
    if not VA or not VA.IsStoreOpen or VA.IsStoreOpen() ~= true then
        return false
    end
    if Buy._visitStopReason ~= nil then
        return false
    end
    return true
end

function Buy.PollStorePresence()
    local VA = StockPiler.VendorAdapter
    if VA and VA.FlushPendingStoreRefresh then
        VA.FlushPendingStoreRefresh()
    end
    BeginVisitIfNeeded()
end

function Buy.OnStoreUpdated(opts)
    opts = type(opts) == "table" and opts or {}
    Buy.InvalidateJobsCache()
    if StockPiler.Scheduler and StockPiler.Scheduler.WakeAutoBuy then
        StockPiler.Scheduler.WakeAutoBuy()
    end
end

--- After idle-no-jobs, resume the same open store when plan shows new deficits
--- (e.g. Potent brew missed stock target and flasks are short again).
local function TryResumeIdleStop(via)
    if Buy._visitStopReason ~= "idle-no-jobs" then
        return false
    end
    if not Buy.IsEnabled() then
        return false
    end
    local VA = StockPiler.VendorAdapter
    if not VA or not VA.IsStoreOpen or VA.IsStoreOpen() ~= true then
        return false
    end
    Buy.InvalidateJobsCache()
    local jobs = Buy.CollectBuyJobs()
    if type(jobs) ~= "table" or #jobs == 0 then
        return false
    end
    local was = Buy._visitStopReason
    Buy._visitStopReason = nil
    -- Allow the next fill to re-arm plan/brew wake for this open visit.
    Buy._planArmedAfterFill = false
    Buy._pendingBuy = nil
    LogBuy(string.format(
        "resume clear-stop was=%s via=%s jobs=%d",
        tostring(was),
        tostring(via or "?"),
        #jobs
    ))
    if StockPiler.Scheduler and StockPiler.Scheduler.WakeAutoBuy then
        StockPiler.Scheduler.WakeAutoBuy()
    end
    return true
end

function Buy.OnPlanUpdated()
    local VA = StockPiler.VendorAdapter
    if not VA or not VA.IsStoreOpen or VA.IsStoreOpen() ~= true then
        return
    end
    if not Buy.IsEnabled() then
        return
    end
    Buy.InvalidateJobsCache()
    if TryResumeIdleStop("plan-updated") then
        return
    end
    if Buy._visitStopReason == nil and StockPiler.Scheduler and StockPiler.Scheduler.WakeAutoBuy then
        StockPiler.Scheduler.WakeAutoBuy()
    end
end

function Buy.OnInventorySnapshot()
    -- Do not Flatten here; jobs rebuild on next Collect via snapGen key.
    Buy.InvalidateJobsCache()
    -- Bag deficit is truth: drop optimistic visit-acquired while store is open.
    if Buy._storeWasOpen == true then
        Buy._visitAcquired = {}
    end
    local woke = false
    -- Inventory may confirm a pending buy via bag gain.
    if type(Buy._pendingBuy) == "table" then
        local state = ResolvePendingBuy()
        if state == "confirmed" then
            woke = true
        end
    end
    -- Bag often arrives after PENDING_BUY_TIMEOUT marked no-spend - still chat.
    local lateConfirmed = TryLateConfirmBuys() == true
    if lateConfirmed then
        woke = true
        -- After store close, plan rebuilds from the bag flush; still wake Brew
        -- so Watch/footer see the late fill (L10).
        if Buy._storeWasOpen ~= true then
            WakeBrewAfterBuyFill("late-confirm")
        end
    end
    if woke and StockPiler.Scheduler and StockPiler.Scheduler.WakeAutoBuy then
        StockPiler.Scheduler.WakeAutoBuy()
    end
end

function Buy.DumpBuyPlan(opts)
    opts = type(opts) == "table" and opts or {}
    local force = opts.force == true
    if force and StockPiler.Inventory and StockPiler.Inventory.RefreshAllIfNeeded then
        StockPiler.Inventory.RefreshAllIfNeeded({ force = true })
    end
    Buy.InvalidateJobsCache()
    BeginVisitIfNeeded()
    local jobs = Buy.CollectBuyJobs()
    Emit("=== buy plan ===", force)
    Emit(string.format(
        "enabled=%s reserveGold=%d budgetGold=%d spentBrass=%d remainBrass=%d storeOpen=%s allowPlantBuys=%s",
        tostring(Buy.IsEnabled()),
        Buy.GetReserveGold(),
        Buy.GetBudgetGold(),
        Buy.GetSpentBrass(),
        Buy.GetAllowanceRemainingBrass(),
        tostring(StockPiler.VendorAdapter and StockPiler.VendorAdapter.IsStoreOpen
            and StockPiler.VendorAdapter.IsStoreOpen()),
        tostring(Buy._allowPlantBuys)
    ), force)
    Emit(string.format(
        "visit purchases=%d bought=%d visitSpentBrass=%d stop=%s pending=%s money=%d",
        tonumber(Buy._visitPurchases) or 0,
        tonumber(Buy._visitBought) or 0,
        tonumber(Buy._visitSpentBrass) or 0,
        tostring(Buy._visitStopReason),
        tostring(type(Buy._pendingBuy) == "table"),
        PlayerMoneyBrass()
    ), force)
    Emit("--- jobs (" .. tostring(#jobs) .. ") ---", force)
    local meta = StockPiler.Planner and StockPiler.Planner._vendorBuyJobsMeta
    if type(meta) == "table" then
        Emit(string.format(
            "jobsMeta source=%s focusWatches=%s maxBottleGap=%s",
            tostring(meta.source),
            tostring(meta.focusWatchCount),
            tostring(meta.maxBottleGap)
        ), force)
    end
    for i = 1, math.min(#jobs, 40) do
        local j = jobs[i]
        local role = tostring(j.role or "")
        local incomplete = type(j.spec) == "table" and j.spec.incomplete == true
        local item, cost = Buy.FindStoreMatch(j)
        local matchUid = type(item) == "table" and (tonumber(item.uniqueID) or tonumber(item.id) or 0) or 0
        local matchSlot = type(item) == "table" and tonumber(item.slotNum) or nil
        Emit(string.format(
            "  [%d] uid=%s deficit=%s role=%s incomplete=%s key=%s match=%s cost=%s slot=%s",
            i,
            tostring(j.uid or j.uniqueID),
            tostring(j.deficit),
            role,
            tostring(incomplete),
            tostring(j.specKey or j.acquireKey),
            matchUid > 0 and tostring(matchUid) or "nil",
            tostring(cost),
            tostring(matchSlot)
        ), force)
    end
    local VA = StockPiler.VendorAdapter
    if VA and VA.RefreshMatchIndex then
        VA.RefreshMatchIndex()
    end
    local index = VA and VA.GetMatchIndex and VA.GetMatchIndex()
    local indexRows = type(index) == "table" and type(index.rows) == "table" and #index.rows or 0
    Emit(string.format(
        "store indexRows=%s buyback=%s",
        tostring(indexRows),
        tostring(VA and VA.IsBuybackView and VA.IsBuybackView() == true)
    ), force)
    -- Dump store rows so no-store-match is diagnosable without a second command.
    local MS = StockPiler.MaterialSpec
    local job0 = jobs[1]
    local spec0 = type(job0) == "table" and job0.spec or nil
    if type(index) == "table" and type(index.rows) == "table" then
        local maxLines = math.min(#index.rows, 25)
        Emit("--- store rows (" .. tostring(#index.rows) .. ") ---", force)
        for i = 1, maxLines do
            local row = index.rows[i]
            local item = row and row.item
            if type(item) == "table" then
                local parsed = MS and MS.FromItemData and MS.FromItemData(item, nil)
                local req = tonumber(item.craftingSkillRequirement) or 0
                local pSkill = tonumber(parsed and parsed.skillLevel) or 0
                local pSlot = tonumber(parsed and parsed.slotType) or 0
                local pRole = tostring(parsed and parsed.role or "")
                local cult = tonumber(item.cultivationType) or 0
                local why = "ok"
                if HasAltCurrency(item) then
                    why = "alt"
                elseif row.canbuy == false then
                    why = "canbuy"
                elseif StoreItemRejectedForBuy(item) then
                    if IsCultivationAdditiveStoreItem(item) then
                        why = "additive"
                    else
                        why = "growable"
                    end
                elseif type(spec0) == "table" and MS and MS.Matches then
                    if MS.Matches(item, spec0) == true
                        or (MS.ProductMatches and MS.ProductMatches(item, spec0) == true)
                    then
                        why = "MATCH"
                    else
                        why = "nomatch"
                        if pSkill ~= (tonumber(spec0.skillLevel) or 0) then
                            why = "skill"
                        elseif tonumber(parsed and parsed.tradeSkill) ~= tonumber(spec0.tradeSkill) then
                            why = "ts"
                        elseif IsCultivationAdditiveStoreItem(item) then
                            why = "additive"
                        end
                    end
                end
                local name = "?"
                if type(item.name) == "wstring" and type(WStringToString) == "function" then
                    name = WStringToString(item.name) or "?"
                elseif item.name ~= nil then
                    name = tostring(item.name)
                end
                Emit(string.format(
                    "  #%d slot=%s uid=%s cost=%s req=%s pSkill=%s pSlot=%s pRole=%s ct=%s why=%s name=%s",
                    i,
                    tostring(tonumber(item.slotNum) or 0),
                    tostring(tonumber(item.uniqueID) or tonumber(item.id) or 0),
                    tostring(tonumber(row.cost) or tonumber(item.cost) or 0),
                    tostring(req),
                    tostring(pSkill),
                    tostring(pSlot),
                    pRole,
                    tostring(cult),
                    why,
                    name
                ), force)
            end
        end
    end
    Emit("=== end buy plan ===", force)
end
