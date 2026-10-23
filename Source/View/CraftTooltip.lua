----------------------------------------------------------------
-- StockPiler CraftTooltip -- dual Craft macro tip (live while hovered)
-- Primary line = what this click does; optional follow-up = queued next.
-- Then one section per planted plot: seed (icon + tier color), full time
-- left (TotalTimer), and applied additives.
-- While the tip is open the engine calls OnTooltipUpdate each frame.
-- That path only rewrites the time lines, about once a second.
----------------------------------------------------------------

StockPiler = StockPiler or {}
StockPiler.CraftTooltip = StockPiler.CraftTooltip or {}
local CraftTooltip = StockPiler.CraftTooltip

local function T(key, tokens)
    return StockPiler.Util.T(key, tokens)
end

local function WName(name)
    if name == nil or name == L"" then
        return nil
    end
    return name
end

local function SessionBrewName(session)
    if type(session) ~= "table" then
        return nil
    end
    local phase = tostring(session.phase or "idle")
    if phase ~= "loading" and phase ~= "loaded" then
        return nil
    end
    return WName(session.name)
end

local function ReadyBrewName()
    local Brew = StockPiler.Brew
    local session = Brew and Brew.GetSession and Brew.GetSession()
    local loaded = SessionBrewName(session)
    if loaded ~= nil then
        return loaded
    end
    if Brew and Brew.PickReadyWatch then
        local row = Brew.PickReadyWatch()
        if type(row) == "table" then
            return WName(row.name)
        end
    end
    return T("brew.potion_fallback")
end

local function NameKey(name)
    if name == nil then
        return ""
    end
    if type(name) == "wstring" and type(WStringToString) == "function" then
        return WStringToString(name) or ""
    end
    return tostring(name)
end

local function SoftReadyCount()
    local Grow = StockPiler.Grow
    if Grow and Grow.GetReadyHarvestPlots then
        local plots = Grow.GetReadyHarvestPlots()
        if type(plots) == "table" then
            return #plots
        end
    end
    return 0
end

local function StageEmpty()
    return StockPiler.CultivatorAdapter.StageEmpty()
end

local function StageGrown()
    if GameData and GameData.CultivationStage then
        return GameData.CultivationStage.GROWN or 4
    end
    return 4
end

local function StageHarvesting()
    if GameData and GameData.CultivationStage then
        return GameData.CultivationStage.HARVESTING or 5
    end
    return 5
end

local function IconMarkup(iconNum)
    iconNum = tonumber(iconNum) or 0
    if iconNum <= 0 then
        return L""
    end
    return towstring(string.format("<icon%05d> ", iconNum))
end

local function FormatTotalTime(seconds)
    seconds = tonumber(seconds) or 0
    if seconds < 0 then
        seconds = 0
    end
    if seconds > 0 and TimeUtils and TimeUtils.FormatTime then
        local ok, text = pcall(TimeUtils.FormatTime, seconds)
        if ok and text ~= nil and text ~= L"" then
            return text
        end
    end
    local s = math.floor(seconds + 0.5)
    local m = math.floor(s / 60)
    s = s - m * 60
    local h = math.floor(m / 60)
    m = m - h * 60
    if h > 0 then
        return towstring(string.format("%d:%02d:%02d", h, m, s))
    end
    return towstring(string.format("%d:%02d", m, s))
end

local function AdditiveCultOrder()
    local types = GameData and GameData.CultivationTypes
    if type(types) == "table" then
        return {
            tonumber(types.SOIL) or 2,
            tonumber(types.WATERCAN) or 3,
            tonumber(types.NUTRIENT) or 4,
        }
    end
    return { 2, 3, 4 }
end

local function SeedItemData(plot)
    if type(plot) ~= "table" then
        return nil
    end
    local seed = plot.seed
    if type(seed) == "table" then
        return seed
    end
    local uid = tonumber(plot.seedUid) or 0
    if uid <= 0 then
        return nil
    end
    local Items = StockPiler.Items
    if Items and Items.Get then
        local item = Items.Get(uid)
        if type(item) == "table" then
            return item
        end
    end
    return {
        uniqueID = uid,
        name = plot.seedName,
        iconNum = tonumber(plot.seedIconNum) or 0,
    }
end

local function SeedRarityColor(itemData)
    local VL = StockPiler.ViewList
    if VL and VL.ItemRarityNameColor then
        local r, g, b = VL.ItemRarityNameColor(itemData)
        return { r = r, g = g, b = b }
    end
    return nil
end

--- Live plot rows from the cultivator (not the soft Garden cache) so TotalTimer ticks.
local function CollectPlantedPlots()
    local CA = StockPiler.CultivatorAdapter
    if not CA then
        return {}
    end
    local n = 4
    if CA.MaxPlotSlots then
        n = tonumber(CA.MaxPlotSlots()) or n
    elseif CA.NumPlots then
        n = tonumber(CA.NumPlots()) or n
    end
    local empty = StageEmpty()
    local out = {}
    for plotNum = 1, n do
        local plot = CA.GetPlotInfo and CA.GetPlotInfo(plotNum) or nil
        if type(plot) == "table" then
            local stage = tonumber(plot.stage) or 0
            local seedUid = tonumber(plot.seedUid) or 0
            if stage ~= empty and stage ~= 255 and seedUid > 0 then
                out[#out + 1] = plot
            end
        end
    end
    return out
end

local function BuildActionRows()
    local Macro = StockPiler.Macro
    local snap = nil
    if Macro and Macro.ResolveCraftMode then
        snap = Macro.ResolveCraftMode({ readonly = true })
    end
    snap = type(snap) == "table" and snap or {}

    local mode = tostring(snap.mode or "idle")
    local ready = tonumber(snap.readyPlots) or SoftReadyCount()
    local canHarvest = snap.canHarvest == true
    local canBrew = snap.canBrew == true
    local brewPhase = tostring(snap.brewPhase or "idle")
    local brewName = snap.brewName
    if brewName == nil or brewName == L"" then
        if mode == "brew" or canBrew or brewPhase == "loading" or brewPhase == "loaded" then
            brewName = ReadyBrewName()
        end
    end
    if brewName == nil or brewName == L"" then
        brewName = T("brew.potion_fallback")
    end

    local rows = {}
    local function push(text, kind)
        if text == nil or text == L"" then
            return
        end
        rows[#rows + 1] = { text = text, kind = kind or "body" }
    end

    local showedIdle = false
    if mode == "harvest" then
        if canHarvest and ready > 0 then
            push(T("macro.craft_tip_harvest", { count = tostring(ready) }), "title")
        elseif ready > 0 then
            push(T("macro.craft_tip_harvest_wait", { count = tostring(ready) }), "title")
        else
            push(T("macro.craft_tip_idle"), "title")
            showedIdle = true
        end
        if ready > 1 then
            push(T("macro.craft_tip_then_harvest", { count = tostring(ready - 1) }), "meta")
        end
        if canBrew then
            push(T("macro.craft_tip_then_brew", { name = ReadyBrewName() }), "meta")
        end
    elseif mode == "brew" then
        if brewPhase == "loading" then
            push(T("macro.craft_tip_brew_loading", { name = brewName }), "title")
        elseif brewPhase == "loaded" then
            if canBrew then
                push(T("macro.craft_tip_brew", { name = brewName }), "title")
            else
                push(T("macro.craft_tip_brew_loading", { name = brewName }), "title")
            end
        elseif canBrew then
            push(T("macro.craft_tip_brew_load", { name = brewName }), "title")
            push(T("macro.craft_tip_then_brew", { name = brewName }), "meta")
        else
            push(T("macro.craft_tip_idle"), "title")
            showedIdle = true
        end
        if ready > 0 then
            push(T("macro.craft_tip_then_harvest_ready", { count = tostring(ready) }), "meta")
        end
    else
        push(T("macro.craft_tip_idle"), "title")
        showedIdle = true
        if ready > 0 then
            push(T("macro.craft_tip_then_harvest_ready", { count = tostring(ready) }), "meta")
        elseif canBrew then
            push(T("macro.craft_tip_then_brew", { name = brewName }), "meta")
        else
            local Brew = StockPiler.Brew
            local why = Brew and Brew.AutoBrewBlockedReason and Brew.AutoBrewBlockedReason()
            if why == "buffer" then
                push(T("brew.blocked_buffer"), "warning")
            elseif why == "pending-plant" then
                push(T("brew.blocked_plant"), "warning")
            elseif why == "refine" then
                push(T("brew.blocked_refine"), "warning")
            elseif why == "harvest" then
                push(T("brew.blocked_harvest"), "warning")
            end
        end
    end

    -- Idle + AutoGrow gaps: master off (all short watches), or master on with
    -- per-watch AutoGrow still off for short watches.
    if showedIdle == true then
        local Watch = StockPiler.Watch
        if Watch and Watch.IsAutoGrowEnabled then
            local masterOn = Watch.IsAutoGrowEnabled() == true
            local waiting = Watch.CollectShortEnabledWatches and Watch.CollectShortEnabledWatches() or nil
            if type(waiting) ~= "table" then
                waiting = {}
            end
            local show = {}
            if masterOn ~= true then
                push(T("macro.craft_tip_autogrow_off"), "warning")
                show = waiting
                if #show > 0 then
                    push(T("macro.craft_tip_autogrow_waiting", { count = tostring(#show) }), "warning")
                end
            else
                for i = 1, #waiting do
                    local entry = waiting[i]
                    if type(entry) == "table" and entry.perWatchOff == true then
                        show[#show + 1] = entry
                    end
                end
                if #show > 0 then
                    push(T("macro.craft_tip_autogrow_watch_off_n", { count = tostring(#show) }), "warning")
                end
            end
            local maxShow = 6
            for i = 1, math.min(#show, maxShow) do
                local entry = show[i]
                local name = entry and entry.name
                if name == nil or name == L"" then
                    name = T("watch.fallback")
                end
                if masterOn ~= true and entry and entry.perWatchOff == true then
                    push(T("macro.craft_tip_autogrow_watch_off", { name = name }), "meta")
                else
                    push(T("macro.craft_tip_autogrow_watch", { name = name }), "meta")
                end
            end
            if #show > maxShow then
                push(T("macro.craft_tip_autogrow_more", { count = tostring(#show - maxShow) }), "meta")
            end
        end
    end

    -- Stay overlay: show the same user-action reason in red under the title.
    local Timer = StockPiler.CraftHarvestTimer
    if Timer and Timer.NeedsUserStay and Timer.NeedsUserStay() == true
        and Timer.UserStayReasonText
    then
        local reason = Timer.UserStayReasonText()
        if reason ~= nil and reason ~= L"" then
            push(T("macro.craft_tip_stay", { reason = reason }), "warning")
        end
    end
    return rows
end

local PlotTimeRow

local function AppendPlotSections(rows, plots)
    if type(rows) ~= "table" or type(plots) ~= "table" or #plots == 0 then
        return
    end
    local RT = StockPiler.RecipeTooltip
    local grown = StageGrown()
    local harvesting = StageHarvesting()
    local order = AdditiveCultOrder()

    for i = 1, #plots do
        local plot = plots[i]
        if RT and RT.AppendSeparator then
            RT.AppendSeparator(rows)
        else
            rows[#rows + 1] = { text = T("recipe.sep"), kind = "separator" }
        end

        local plotNum = tonumber(plot.plotNum) or i
        rows[#rows + 1] = {
            text = T("macro.craft_tip_plot", { plot = tostring(plotNum) }),
            kind = "title",
        }

        local itemData = SeedItemData(plot)
        local iconNum = tonumber(plot.seedIconNum) or 0
        if iconNum <= 0 and type(itemData) == "table" then
            iconNum = tonumber(itemData.iconNum) or 0
        end
        local name = WName(plot.seedName)
        if name == nil and type(itemData) == "table" then
            name = WName(itemData.name)
        end
        if name == nil then
            name = T("macro.craft_tip_seed_fallback")
        end
        rows[#rows + 1] = {
            text = IconMarkup(iconNum) .. name,
            kind = "ingredient",
            color = SeedRarityColor(itemData),
        }

        rows[#rows + 1] = PlotTimeRow(plot, grown, harvesting)
        local timeRows = CraftTooltip._timeRows
        if type(timeRows) == "table" then
            timeRows[#timeRows + 1] = #rows
        end

        local additives = plot.additives
        local anyAdd = false
        if type(additives) == "table" then
            for oi = 1, #order do
                local ct = order[oi]
                local slot = additives[ct]
                if type(slot) == "table" and (slot.filled == true
                    or (tonumber(slot.uniqueID) or 0) > 0
                    or (tonumber(slot.id) or 0) ~= 0)
                then
                    anyAdd = true
                    local aIcon = tonumber(slot.iconNum) or 0
                    local aName = WName(slot.name) or T("macro.craft_tip_additive_fallback")
                    rows[#rows + 1] = {
                        text = IconMarkup(aIcon) .. aName,
                        kind = "body",
                        color = SeedRarityColor(slot),
                    }
                end
            end
        end
        if not anyAdd then
            rows[#rows + 1] = {
                text = T("macro.craft_tip_additives_none"),
                kind = "meta",
            }
        end
    end
end

function PlotTimeRow(plot, grown, harvesting)
    local stage = tonumber(plot.stage) or 0
    local total = tonumber(plot.totalTimer) or 0
    if stage == grown or stage == harvesting then
        return {
            text = T("macro.craft_tip_time_ready"),
            kind = "stocked",
        }
    end
    return {
        text = T("macro.craft_tip_time", { time = FormatTotalTime(total) }),
        kind = "meta",
    }
end

local function ResetTimeRows()
    local list = CraftTooltip._timeRows
    if type(list) ~= "table" then
        list = {}
        CraftTooltip._timeRows = list
        return
    end
    for i = #list, 1, -1 do
        list[i] = nil
    end
end

local function BuildTipRows()
    ResetTimeRows()
    local rows = BuildActionRows()
    AppendPlotSections(rows, CollectPlantedPlots())
    return rows
end

local function Fingerprint()
    local Macro = StockPiler.Macro
    local snap = nil
    if Macro and Macro.ResolveCraftMode then
        snap = Macro.ResolveCraftMode({ readonly = true })
    end
    snap = type(snap) == "table" and snap or {}
    local brewName = snap.brewName
    if (brewName == nil or brewName == L"") and (snap.mode == "brew" or snap.canBrew == true) then
        brewName = ReadyBrewName()
    end
    local blocked = ""
    if tostring(snap.mode or "idle") == "idle" then
        local Brew = StockPiler.Brew
        blocked = tostring(Brew and Brew.AutoBrewBlockedReason and Brew.AutoBrewBlockedReason() or "")
    end
    local stayKey = ""
    local Timer = StockPiler.CraftHarvestTimer
    if Timer and Timer.UserStayInfo then
        local stay = Timer.UserStayInfo()
        if type(stay) == "table" then
            stayKey = tostring(stay.key or "")
            if stay.text ~= nil then
                stayKey = stayKey .. ":" .. NameKey(stay.text)
            elseif Timer.UserStayReasonText then
                stayKey = stayKey .. ":" .. NameKey(Timer.UserStayReasonText())
            end
        end
    end
    -- Cheap key: master AG + planGen (watch list rebuild bumps planGen).
    local agKey = "ag1"
    local Watch = StockPiler.Watch
    if Watch and Watch.IsAutoGrowEnabled then
        local PS = StockPiler.PlanSnapshot
        local plan = PS and PS.Get and PS.Get()
        local planGen = type(plan) == "table" and (tonumber(plan.planGen) or 0) or 0
        if Watch.IsAutoGrowEnabled() ~= true then
            agKey = "ag0:" .. tostring(planGen)
        else
            agKey = "ag1:" .. tostring(planGen)
        end
    end

    local parts = {
        tostring(snap.mode or "idle"),
        tostring(snap.iconMode or ""),
        tostring(snap.readyPlots or 0),
        tostring(snap.canHarvest == true),
        tostring(snap.canBrew == true),
        tostring(snap.brewPhase or "idle"),
        NameKey(brewName),
        blocked,
        stayKey,
        agKey,
    }

    local plots = CollectPlantedPlots()
    parts[#parts + 1] = "n=" .. tostring(#plots)
    for i = 1, #plots do
        local p = plots[i]
        local addKey = ""
        if type(p.additives) == "table" then
            local bits = {}
            for ct, slot in pairs(p.additives) do
                if type(slot) == "table" and (slot.filled == true
                    or (tonumber(slot.uniqueID) or 0) > 0
                    or (tonumber(slot.id) or 0) ~= 0)
                then
                    bits[#bits + 1] = tostring(ct) .. ":"
                        .. tostring(tonumber(slot.uniqueID) or tonumber(slot.id) or 0)
                end
            end
            table.sort(bits)
            addKey = table.concat(bits, ",")
        end
        -- Stage and additives only. Seconds are patched in place while hovered.
        parts[#parts + 1] = table.concat({
            tostring(tonumber(p.plotNum) or i),
            tostring(tonumber(p.seedUid) or 0),
            tostring(tonumber(p.stage) or 0),
            addKey,
        }, "/")
    end
    return table.concat(parts, ":")
end

local function CraftButtonTipBlocked(mouseoverWindow)
    local CB = StockPiler.CraftButton
    local craftWin = CB and CB.WINDOW_NAME or "StockPilerCraftButton"
    if mouseoverWindow ~= craftWin then
        return false
    end
    if CB and CB.IsTipSuppressed and CB.IsTipSuppressed() == true then
        return true
    end
    if type(WindowGetMoving) == "function" and DoesWindowExist(craftWin)
        and WindowGetMoving(craftWin) == true
    then
        return true
    end
    return false
end

function CraftTooltip.Show(mouseoverWindow, anchor)
    mouseoverWindow = mouseoverWindow
        or (SystemData and SystemData.ActiveWindow and SystemData.ActiveWindow.name)
    if mouseoverWindow == nil or mouseoverWindow == "" then
        return
    end
    -- Floating button drag: TipAnchor would re-layout every frame and flicker.
    if CraftButtonTipBlocked(mouseoverWindow) then
        CraftTooltip.ClearLive()
        if Tooltips and type(Tooltips.ClearTooltip) == "function" then
            Tooltips.ClearTooltip()
        end
        return
    end
    CraftTooltip._liveWindow = mouseoverWindow
    -- Floating craft button: side+vertical tip from edge space each paint.
    local CB = StockPiler.CraftButton
    local craftWin = CB and CB.WINDOW_NAME or "StockPilerCraftButton"
    if CB and CB.TipAnchor and mouseoverWindow == craftWin then
        CraftTooltip._liveAnchor = CB.TipAnchor(mouseoverWindow)
    else
        CraftTooltip._liveAnchor = anchor
            or (Tooltips and Tooltips.ANCHOR_WINDOW_TOP)
            or nil
    end
    CraftTooltip._liveFp = Fingerprint()
    CraftTooltip._tipAcc = 0

    local rows = BuildTipRows()
    -- Floating craft button only: lock / drag / RMB. Keep these even if the tip is long.
    local footerN = 0
    if mouseoverWindow == craftWin then
        local RT = StockPiler.RecipeTooltip
        if RT and RT.AppendSeparator then
            RT.AppendSeparator(rows)
        else
            rows[#rows + 1] = { text = T("recipe.sep"), kind = "separator" }
        end
        -- Lock tip first so players always see Shift+LMB.
        rows[#rows + 1] = {
            text = T("button.craft_tip_lock"),
            kind = "meta",
        }
        footerN = footerN + 1
        if not (CB and CB.IsLocked and CB.IsLocked() == true) then
            rows[#rows + 1] = {
                text = T("button.craft_tip_drag"),
                kind = "meta",
            }
            footerN = footerN + 1
        end
        rows[#rows + 1] = {
            text = T("button.craft_tip_rmb"),
            kind = "meta",
        }
        footerN = footerN + 1
    end
    -- WarBoard chip: same craft status tip, plus left-click opens the window.
    local wbWin = StockPiler.WarBoardBridge and StockPiler.WarBoardBridge.WINDOW_NAME
    if wbWin ~= nil and mouseoverWindow == wbWin then
        local RT = StockPiler.RecipeTooltip
        if RT and RT.AppendSeparator then
            RT.AppendSeparator(rows)
        else
            rows[#rows + 1] = { text = T("recipe.sep"), kind = "separator" }
        end
        rows[#rows + 1] = {
            text = T("warboard.tip_click"),
            kind = "meta",
        }
        footerN = footerN + 1
    end
    local RT = StockPiler.RecipeTooltip
    if RT and RT.ShowColoredRows then
        local want = #rows
        local engineMax = want
        if RT.EnsureRows then
            engineMax = tonumber(RT.EnsureRows(want)) or want
        end
        -- Drop body/plot rows before the footer so Shift+lock is never clipped.
        while #rows > engineMax and #rows > footerN + 1 do
            local cut = #rows - footerN - 1
            if cut < 1 then
                break
            end
            table.remove(rows, cut)
        end
        RT.ShowColoredRows(mouseoverWindow, rows, CraftTooltip._liveAnchor, engineMax)
    else
        -- Fallback: flatten to a text tip.
        local chunks = {}
        for i = 1, #rows do
            local entry = rows[i]
            if type(entry) == "table" and entry.text ~= nil and entry.text ~= L"" then
                chunks[#chunks + 1] = entry.text
            end
        end
        local text = L""
        for i = 1, #chunks do
            if i > 1 then
                text = text .. L"\n"
            end
            text = text .. chunks[i]
        end
        if Tooltips and Tooltips.CreateTextOnlyTooltip then
            Tooltips.CreateTextOnlyTooltip(mouseoverWindow, text)
            Tooltips.AnchorTooltip(CraftTooltip._liveAnchor)
        end
    end
    -- CreateTextOnlyTooltip clears any previous callback. Arm after the paint.
    if Tooltips and Tooltips.SetUpdateCallback then
        Tooltips.SetUpdateCallback(CraftTooltip.OnTooltipUpdate)
    end
end

function CraftTooltip.ClearLive()
    CraftTooltip._liveWindow = nil
    CraftTooltip._liveFp = nil
    CraftTooltip._tipAcc = 0
end

--- Rewrite time lines on the open tip. Full rebuild only when the plots change.
local function PatchLiveTimes()
    local rows = CraftTooltip._timeRows
    if type(rows) ~= "table" or not Tooltips or type(Tooltips.SetTooltipText) ~= "function" then
        return false
    end
    local plots = CollectPlantedPlots()
    if #plots ~= #rows then
        return false
    end
    local grown = StageGrown()
    local harvesting = StageHarvesting()
    local changed = false
    for i = 1, #plots do
        local entry = PlotTimeRow(plots[i], grown, harvesting)
        local row = tonumber(rows[i]) or 0
        local text = entry.text or L""
        if row > 0 and Tooltips.GetTooltipText and Tooltips.GetTooltipText(row, 1) ~= text then
            Tooltips.SetTooltipText(row, 1, text, false)
            changed = true
        elseif row > 0 and not Tooltips.GetTooltipText then
            Tooltips.SetTooltipText(row, 1, text, false)
            changed = true
        end
    end
    if changed and Tooltips.Finalize then
        Tooltips.Finalize()
    end
    return true
end

function CraftTooltip.OnTooltipUpdate(timePassed)
    local win = CraftTooltip._liveWindow
    if win ~= nil and win ~= "" and CraftButtonTipBlocked(win) then
        CraftTooltip.ClearLive()
        if Tooltips and type(Tooltips.ClearTooltip) == "function" then
            Tooltips.ClearTooltip()
        end
        return
    end
    -- First frame after EnsureRows grew: re-Finalize so all rows get height.
    local RT = StockPiler.RecipeTooltip
    if RT and RT.TryRelayout and RT.TryRelayout() then
        return
    end
    local acc = (tonumber(CraftTooltip._tipAcc) or 0) + (tonumber(timePassed) or 0)
    if acc < 1 then
        CraftTooltip._tipAcc = acc
        return
    end
    CraftTooltip._tipAcc = 0
    if win == nil or win == "" then
        return
    end
    local mouseWin = SystemData and SystemData.MouseOverWindow and SystemData.MouseOverWindow.name
    if mouseWin ~= win then
        CraftTooltip.ClearLive()
        return
    end
    local fp = Fingerprint()
    if fp ~= CraftTooltip._liveFp or PatchLiveTimes() ~= true then
        CraftTooltip.Show(win, CraftTooltip._liveAnchor)
    end
end

function CraftTooltip.MaybeRefresh()
    local win = CraftTooltip._liveWindow
    if win == nil or win == "" then
        return
    end
    if CraftButtonTipBlocked(win) then
        CraftTooltip.ClearLive()
        if Tooltips and type(Tooltips.ClearTooltip) == "function" then
            Tooltips.ClearTooltip()
        end
        return
    end
    -- Engine clears the tip when mouse leaves; without this gate, Footer Sync
    -- TickLive re-Shows (plot timer / mode churn) and the tip flickers unhovered.
    local mouseWin = SystemData and SystemData.MouseOverWindow and SystemData.MouseOverWindow.name
    if mouseWin ~= win then
        CraftTooltip.ClearLive()
        return
    end
    local fp = Fingerprint()
    if fp == CraftTooltip._liveFp then
        return
    end
    CraftTooltip.Show(win, CraftTooltip._liveAnchor)
end

function CraftTooltip.TickLive()
    CraftTooltip.MaybeRefresh()
end
