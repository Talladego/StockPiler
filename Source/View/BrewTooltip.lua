----------------------------------------------------------------
-- StockPiler BrewTooltip -- footer Ready tip (live while hovered)
----------------------------------------------------------------

StockPiler = StockPiler or {}
StockPiler.BrewTooltip = StockPiler.BrewTooltip or {}
local BrewTooltip = StockPiler.BrewTooltip

local function T(key, tokens)
    return StockPiler.Util.T(key, tokens)
end

local function SessionBrewName(session)
    if type(session) ~= "table" then
        return nil
    end
    local phase = tostring(session.phase or "idle")
    if phase ~= "loading" and phase ~= "loaded" then
        return nil
    end
    if session.name ~= nil and session.name ~= L"" then
        return session.name
    end
    return nil
end

local function ReadyName()
    local Brew = StockPiler.Brew
    local session = Brew and Brew.GetSession and Brew.GetSession()
    local loadedName = SessionBrewName(session)
    if loadedName ~= nil then
        return loadedName
    end
    if Brew and Brew.PickReadyWatch then
        local row = Brew.PickReadyWatch()
        if type(row) == "table" and row.name ~= nil and row.name ~= L"" then
            return row.name
        end
    end
    return T("brew.potion_fallback")
end

local function BuildTipText()
    local Brew = StockPiler.Brew
    local session = Brew and Brew.GetSession and Brew.GetSession()
    local loadedName = SessionBrewName(session)
    local can = Brew and Brew.CanBrewNow and Brew.CanBrewNow() == true

    -- Loaded board: always name the recipe on the board (not PickReadyWatch).
    if loadedName ~= nil then
        if can then
            return T("brew.ready", { name = loadedName })
        end
        return T("brew.load_recipe", { name = loadedName })
    end

    if can then
        return T("brew.ready", { name = ReadyName() })
    end
    local why = Brew and Brew.AutoBrewBlockedReason and Brew.AutoBrewBlockedReason()
    if why == "buffer" then
        return T("brew.blocked_buffer")
    elseif why == "pending-plant" then
        return T("brew.blocked_plant")
    elseif why == "refine" then
        return T("brew.blocked_refine")
    elseif why == "harvest" then
        return T("brew.blocked_harvest")
    end
    if Brew and Brew.HasReadyToCraft and Brew.HasReadyToCraft() == true then
        return T("brew.blocked_other")
    end
    return T("brew.none_ready")
end

local function Fingerprint()
    local Brew = StockPiler.Brew
    local can = Brew and Brew.CanBrewNow and Brew.CanBrewNow() == true
    local session = Brew and Brew.GetSession and Brew.GetSession()
    local phase = "idle"
    local key = ""
    local nameKey = ""
    if type(session) == "table" then
        phase = tostring(session.phase or "idle")
        key = tostring(session.potionKey or session.rowId or "")
        local loadedName = SessionBrewName(session)
        if loadedName ~= nil then
            if type(loadedName) == "wstring" and type(WStringToString) == "function" then
                nameKey = WStringToString(loadedName) or ""
            else
                nameKey = tostring(loadedName)
            end
        end
    end
    if nameKey == "" then
        local n = ReadyName()
        if type(n) == "wstring" and type(WStringToString) == "function" then
            nameKey = WStringToString(n) or ""
        else
            nameKey = tostring(n or "")
        end
    end
    return tostring(can) .. ":" .. phase .. ":" .. key .. ":" .. nameKey
end

function BrewTooltip.Show(mouseoverWindow, anchor)
    StockPiler.ViewList.LiveTipShow(
        BrewTooltip,
        BuildTipText,
        Fingerprint,
        mouseoverWindow,
        anchor,
        Tooltips and Tooltips.ANCHOR_WINDOW_TOP
    )
end

local function RowCraftableGreen(row)
    local Brew = StockPiler.Brew
    if Brew and Brew.RowCraftableGreen then
        return Brew.RowCraftableGreen(row)
    end
    return false
end

local function RowSessionPhase(row)
    if type(row) ~= "table" then
        return "idle"
    end
    local Brew = StockPiler.Brew
    local session = Brew and Brew.GetSession and Brew.GetSession()
    if type(session) ~= "table" then
        return "idle"
    end
    local phase = tostring(session.phase or "idle")
    if phase == "idle" then
        return "idle"
    end
    local rowKey = tostring(row.potionRecipeKey or row.id or row.potionKey or "")
    local sessKey = tostring(session.potionRecipeKey or session.potionKey or session.rowId or "")
    if rowKey ~= "" and sessKey ~= "" and rowKey == sessKey then
        if phase == "loading" then
            return "loading"
        end
        if phase == "loaded" then
            return "brew"
        end
    end
    return "idle"
end

function BrewTooltip.ShowRow(mouseoverWindow, row, anchor)
    mouseoverWindow = mouseoverWindow or (SystemData and SystemData.ActiveWindow and SystemData.ActiveWindow.name)
    if mouseoverWindow == nil or mouseoverWindow == "" then
        return
    end
    local name = (type(row) == "table" and row.name) or T("brew.potion_fallback")
    local tip
    local phase = RowSessionPhase(row)
    if phase == "brew" then
        tip = T("watch.tip_brew", { name = name })
    elseif phase == "loading" then
        tip = T("watch.tip_loading", { name = name })
    elseif RowCraftableGreen(row) then
        tip = T("watch.tip_brew", { name = name })
    elseif type(row) == "table" and (tonumber(row.craftable) or 0) > 0 and row.seedBufferShort == true then
        tip = T("brew.blocked_buffer")
    elseif type(row) == "table" and (tonumber(row.craftable) or 0) <= 0 then
        tip = T("brew.nothing_craftable")
    elseif type(row) == "table" and row.craftableShared == true then
        tip = T("brew.blocked_shared")
    else
        tip = T("brew.not_ready")
    end
    Tooltips.CreateTextOnlyTooltip(mouseoverWindow, tip)
    Tooltips.AnchorTooltip(anchor or Tooltips.ANCHOR_WINDOW_TOP)
end

function BrewTooltip.MaybeRefresh()
    StockPiler.ViewList.LiveTipMaybeRefresh(
        BrewTooltip,
        BuildTipText,
        Fingerprint,
        BrewTooltip.Show
    )
end

function BrewTooltip.TickLive()
    BrewTooltip.MaybeRefresh()
end
