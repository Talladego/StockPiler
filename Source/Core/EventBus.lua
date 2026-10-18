----------------------------------------------------------------
-- StockPiler Core/EventBus - internal pub/sub
----------------------------------------------------------------

StockPiler = StockPiler or {}
StockPiler.EventBus = StockPiler.EventBus or {}

local Bus = StockPiler.EventBus
local subs = {}
local nextToken = 0

StockPiler.Events = StockPiler.Events or {}
local Edef = StockPiler.Events
Edef.INVENTORY_DIRTY = Edef.INVENTORY_DIRTY or "sp.inventory.dirty"
Edef.INVENTORY_SNAPSHOT = Edef.INVENTORY_SNAPSHOT or "sp.inventory.snapshot"
Edef.GARDEN_DIRTY = Edef.GARDEN_DIRTY or "sp.garden.dirty"
Edef.GARDEN_SNAPSHOT = Edef.GARDEN_SNAPSHOT or "sp.garden.snapshot"
Edef.PLAN_INVALIDATED = Edef.PLAN_INVALIDATED or "sp.plan.invalidated"
Edef.PLAN_UPDATED = Edef.PLAN_UPDATED or "sp.plan.updated"
Edef.PHASE_CHANGED = Edef.PHASE_CHANGED or "sp.phase.changed"
Edef.CMD_HARVEST = Edef.CMD_HARVEST or "sp.cmd.harvest"
Edef.SESSION_LOADED = Edef.SESSION_LOADED or "sp.session.loaded"
Edef.KNOWLEDGE_UPDATED = Edef.KNOWLEDGE_UPDATED or "sp.knowledge.updated"
Edef.REFINE_OUTSTANDING = Edef.REFINE_OUTSTANDING or "sp.refine.outstanding"
Edef.VENDOR_UPDATED = Edef.VENDOR_UPDATED or "sp.vendor.updated"
Edef.TRADE_SKILLS_CHANGED = Edef.TRADE_SKILLS_CHANGED or "sp.trade.skills.changed"
Edef.CRAFT_CHAT = Edef.CRAFT_CHAT or "sp.craft.chat"
Edef.SESSION_SETTLED = Edef.SESSION_SETTLED or "sp.session.settled"
-- View-facing: domain publishes; Ui owns flush/paint.
Edef.CRAFT_READY_CHANGED = Edef.CRAFT_READY_CHANGED or "sp.craft.ready"
Edef.FOOTER_DIRTY = Edef.FOOTER_DIRTY or "sp.footer.dirty"
Edef.WATCH_UI_DIRTY = Edef.WATCH_UI_DIRTY or "sp.watch.ui.dirty"
Edef.BREW_SESSION_CHANGED = Edef.BREW_SESSION_CHANGED or "sp.brew.session"

--- Domain modules publish footer readiness via EventBus (View owns flush).
function Bus.FireFooterDirty(payload)
    local E = StockPiler.Events
    if E and E.FOOTER_DIRTY then
        Bus.Fire(E.FOOTER_DIRTY, type(payload) == "table" and payload or {})
    end
end

--- Domain modules mark Watch paint dirty via EventBus (View owns flush).
function Bus.FireWatchUiDirty(payload)
    local E = StockPiler.Events
    if E and E.WATCH_UI_DIRTY then
        Bus.Fire(E.WATCH_UI_DIRTY, type(payload) == "table" and payload or {})
    end
end

--- Brew session phase / load-source chrome (Load→Brew chips, row state).
function Bus.FireBrewSessionChanged(payload)
    local E = StockPiler.Events
    if E and E.BREW_SESSION_CHANGED then
        Bus.Fire(E.BREW_SESSION_CHANGED, type(payload) == "table" and payload or {})
    end
end

function Bus.Subscribe(eventName, fn)
    eventName = tostring(eventName or "")
    if eventName == "" or type(fn) ~= "function" then
        return false
    end
    local list = subs[eventName]
    if list == nil then
        list = {}
        subs[eventName] = list
    end
    for i = 1, #list do
        local entry = list[i]
        if type(entry) == "table" and entry.fn == fn then
            return entry.token
        end
    end
    nextToken = nextToken + 1
    local token = nextToken
    list[#list + 1] = { token = token, fn = fn }
    return token
end

function Bus.Unsubscribe(token)
    token = tonumber(token)
    if token == nil then
        return false
    end
    for eventName, list in pairs(subs) do
        if type(list) == "table" then
            for i = #list, 1, -1 do
                local entry = list[i]
                if type(entry) == "table" and entry.token == token then
                    table.remove(list, i)
                    if #list == 0 then
                        subs[eventName] = nil
                    end
                    return true
                end
            end
        end
    end
    return false
end

function Bus.Fire(eventName, payload)
    eventName = tostring(eventName or "")
    local list = subs[eventName]
    local n = type(list) == "table" and #list or 0
    if StockPiler.Debug and StockPiler.Debug.EventTrace == true
        and StockPiler.Debug.EventTraceNote
    then
        local summary = ""
        if type(payload) == "table" then
            if payload.snapGen then
                summary = summary .. "snapGen=" .. tostring(payload.snapGen) .. " "
            end
            if payload.reason then
                summary = summary .. "reason=" .. tostring(payload.reason) .. " "
            end
            if payload.phase then
                summary = summary .. "phase=" .. tostring(payload.phase) .. " "
            end
        end
        StockPiler.Debug.EventTraceNote(eventName, summary, n)
    end
    if n <= 0 then
        return
    end
    local handlers = {}
    for i = 1, n do
        local entry = list[i]
        local fn = type(entry) == "table" and entry.fn or entry
        if type(fn) == "function" then
            handlers[#handlers + 1] = fn
        end
    end
    for i = 1, #handlers do
        if StockPiler.Debug and StockPiler.Debug.TryCallQuiet then
            StockPiler.Debug.TryCallQuiet("EventBus." .. eventName, handlers[i], payload)
        else
            pcall(handlers[i], payload)
        end
    end
end
