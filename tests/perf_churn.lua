-- Lua 5.1 harness for idle scheduling and Craft hotbar refresh.
-- Run from the repo root: lua5.1 tests/perf_churn.lua

local function script_dir()
    local src = debug.getinfo(1, "S").source
    if type(src) == "string" and src:sub(1, 1) == "@" then
        src = src:sub(2)
    end
    return (src:match("^(.*)[/\\]") or ".")
end

local ROOT = script_dir() .. "/.."

local function load_module(rel)
    local path = ROOT .. "/" .. rel
    local fh, openErr = io.open(path, "rb")
    if not fh then
        error("open " .. path .. ": " .. tostring(openErr))
    end
    local text = fh:read("*a")
    fh:close()
    text = text:gsub('L"([^"]*)"', '"%1"')
    local chunk, err = loadstring(text, "@" .. path)
    if not chunk then
        error(err)
    end
    chunk()
end

local failures = 0
local checks = 0

local function check(cond, msg)
    checks = checks + 1
    if cond ~= true then
        failures = failures + 1
        io.stderr:write("FAIL ", msg, "\n")
    end
end

local function eq(actual, expected, msg)
    checks = checks + 1
    if actual ~= expected then
        failures = failures + 1
        io.stderr:write(
            "FAIL ", msg,
            " expected=", tostring(expected),
            " got=", tostring(actual), "\n"
        )
    end
end

function towstring(s)
    return tostring(s)
end
function WStringToString(s)
    return tostring(s)
end

local skills = 0
function GetTradeSkillLevel()
    skills = skills + 1
    return 1
end

local clocks = 0
StockPiler = {}
StockPiler.Util = {
    T = function(key)
        return tostring(key)
    end,
    ToNarrow = function(v)
        return tostring(v or "")
    end,
    NowSec = function()
        clocks = clocks + 1
        return 1000
    end,
    TryCallQuiet = function(_, fn, ...)
        return pcall(fn, ...)
    end,
}

load_module("Source/Core/EventBus.lua")
load_module("Source/Core/FrameWork.lua")
load_module("Source/Stores/RefinePipelineStore.lua")
load_module("Source/Persistence/Settings.lua")
load_module("Source/Core/Scheduler.lua")
load_module("Source/View/Ui.lua")

local Bus = StockPiler.EventBus
local log = {}
local tokenB
local function handlerB()
    log[#log + 1] = "b"
end
local function handlerA(payload)
    log[#log + 1] = "a"
    if type(payload) == "table" and payload.nest == true then
        Bus.Unsubscribe(tokenB)
        Bus.Subscribe("ev.perf", function()
            log[#log + 1] = "c"
        end)
        Bus.Fire("ev.perf", {})
    end
end
Bus.Subscribe("ev.perf", handlerA)
tokenB = Bus.Subscribe("ev.perf", handlerB)
Bus.Fire("ev.perf", { nest = true })
eq(table.concat(log, ","), "a,a,c,b", "outer fire keeps its snapshot while the nested fire sees the new subscriber")
log = {}
Bus.Fire("ev.perf", {})
eq(table.concat(log, ","), "a,c", "the next fire uses the subscriptions after the nested change")
local fires = 0
local function once()
    fires = fires + 1
end
local token = Bus.Subscribe("ev.once", once)
eq(Bus.Subscribe("ev.once", once), token, "subscribing the same handler again keeps the token")
Bus.Fire("ev.once")
eq(fires, 1, "a duplicate subscription does not run twice")

local FW = StockPiler.FrameWork
local gates = 0
StockPiler.Scheduler.SkipPlanThisFrameActive = function()
    gates = gates + 1
    return false
end
FW._order = {}
eq(FW.Pump(), false, "empty framework pump does no work")
eq(gates, 0, "empty framework pump does not check the pump gate")

local RP = StockPiler.RefinePipeline
RP._outstanding = {}
clocks = 0
eq(RP.ExpireStuck(), false, "empty refine queue expires nothing")
eq(clocks, 0, "empty refine expiry does not read the clock")
local dirty = 0
StockPiler.Inventory = {
    MarkDirty = function()
        dirty = dirty + 1
    end,
}
RP._outstanding[5] = { count = 1, plantUid = 9, at = 1000 - 40, softTried = false }
eq(RP.ExpireStuck(), true, "a stuck refine soft-expires")
eq(RP._outstanding[5].softTried, true, "soft expiry marks the row")
eq(dirty, 1, "soft expiry marks inventory dirty")
RP._outstanding[5].softAt = 1000 - 10
eq(RP.ExpireStuck(), true, "grace expiry clears the row")
eq(RP._outstanding[5], nil, "stuck refine is removed after the grace")

local P = StockPiler.Persistence
GameData = { Player = { name = "Hero" } }
local shapes = 0
local origShape = P.EnsureCharacterBucketShape
P.EnsureCharacterBucketShape = function(char)
    shapes = shapes + 1
    return origShape(char)
end
StockPiler.Settings = nil
local row = P.GetCharacterBucket(true)
eq(shapes, 1, "a new character bucket is normalised once")
eq(type(row.watches), "table", "a new bucket receives default watches")
row.retiredJunk = true
row.autoGrowEnabled = true
local again = P.GetCharacterBucket(true)
eq(again, row, "hot lookup returns the same bucket")
eq(shapes, 1, "hot lookup does not normalise again")
eq(again.retiredJunk, true, "hot lookup does not rescan retired keys")
eq(again.autoGrowEnabled, true, "hot lookup keeps caller edits")
P.ResetSettingsToDefaults()
local resetRow = P.GetCharacterBucket(true)
eq(shapes, 2, "reset invalidates the bucket cache")
eq(resetRow.autoGrowEnabled, false, "reset restores the auto-grow default")
eq(resetRow.retiredJunk, nil, "reset drops a retired key on the next lookup")
local replaced = { retiredJunk = 1 }
StockPiler.Settings.characters[P.GetCharacterKey()] = replaced
local shaped = P.GetCharacterBucket(true)
eq(shaped, replaced, "a replaced bucket is the stored table")
eq(shapes, 3, "a replaced bucket is normalised")
eq(shaped.retiredJunk, nil, "a replaced bucket drops retired keys")
eq(type(shaped.watches), "table", "a replaced bucket receives defaults")
local quiet = P.GetCharacterBucket(true)
eq(quiet, shaped, "the replaced bucket is cached")
eq(shapes, 3, "the cached replacement is not normalised again")

local Sch = StockPiler.Scheduler
local Ui = StockPiler.Ui
StockPiler.Watch = {
    IsAutoGrowEnabled = function()
        GetTradeSkillLevel()
        return true
    end,
}
StockPiler.Buy = {
    NeedsTick = function()
        GetTradeSkillLevel()
        return true
    end,
}
StockPiler.SkillUp = {
    ShouldShowWatchStatus = function()
        GetTradeSkillLevel()
        return true
    end,
}
skills = 0
Sch._autoGrowFast = true
local fastOk = true
for _ = 1, 40 do
    if Sch.AutoTickIntervalSec() ~= Sch.AUTO_TICK_SEC then
        fastOk = false
    end
end
check(fastOk, "fast auto-grow stays on the fast interval")
eq(skills, 0, "fast interval does not read skills")
eq(Sch.CurrentAutoTickSec(), 1, "current tick matches the fast interval")
eq(skills, 0, "current tick does not read skills while fast")

function DoesWindowExist()
    return false
end
function WindowGetShowing()
    return false
end
Ui._watchUiDirty = true
skills = 0
Ui.FlushWatchUiIfDirty()
eq(skills, 0, "closed dirty flush does not read skills")
eq(Ui._watchUiDirty, true, "closed flush keeps the dirty flag")
Sch._skipUiThisFrame = false
Sch._openPaintPending = false
skills = 0
Sch.FlushWatchUiIfDue(false)
eq(skills, 0, "closed due flush does not read skills")
eq(Ui._watchUiDirty, true, "closed due flush keeps the dirty flag")

Ui._watchUiDirty = false
skills = 0
function DoesWindowExist()
    return true
end
function WindowGetShowing()
    return true
end
Sch.FlushWatchUiIfDue(false)
eq(skills, 0, "a clean watch skips the skill-up paint check")
eq(Ui._watchUiDirty, false, "a clean watch stays clean")

local refreshed = 0
StockPilerWindow = {
    SelectedTab = 3,
    TABS_WATCH = 3,
    TABS_POTIONS = 1,
    TABS_PLANTS = 2,
    RefreshActiveTab = function()
        refreshed = refreshed + 1
    end,
}
Ui._watchUiDirty = true
Ui._watchUiLastKey = nil
Ui._watchUiFlushedAt = 0
StockPiler.SkillUp.ShouldShowWatchStatus = function()
    return false
end
StockPiler.Watch.IsAutoGrowEnabled = function()
    return false
end
Ui.FlushWatchUiIfDirty()
eq(refreshed, 1, "opening watch after a hidden update flushes")
eq(Ui._watchUiDirty, false, "the open flush clears the dirty flag")

load_module("Source/Macro/Macro.lua")
load_module("Source/Macro/CraftHarvestTimer.lua")

local macroReads = 0
local slot1 = {
    name = "StockPiler Craft",
    text = "/script StockPiler.Macro.CraftClick()",
    icon = 2486,
}
function GetMacrosData()
    macroReads = macroReads + 1
    local macros = {}
    for i = 1, 48 do
        macros[i] = { name = "Other", text = "/wave", icon = 1 }
    end
    macros[1] = slot1
    return macros
end

local plotReads = 0
local plots = {}
for i = 1, 4 do
    plots[i] = { stage = 1, seedUid = 10, totalTimer = 20, seedIconNum = 5 }
end
StockPiler.CultivatorAdapter = {
    MaxPlotSlots = function()
        return 4
    end,
    GetPlotInfo = function(n)
        plotReads = plotReads + 1
        return plots[n]
    end,
}
GameData.PlayerActions = { DO_MACRO = 12 }
GameData.CultivationStage = { EMPTY = 0, GROWN = 4, HARVESTING = 5 }

local textWrites = 0
local showWrites = 0
local buttons = {}
local barButtons = {}
for i = 1, 72 do
    local label = {}
    label.SetText = function(_, text)
        textWrites = textWrites + 1
        label.last = tostring(text)
    end
    label.Show = function(_, showing)
        showWrites = showWrites + 1
        label.showing = showing == true
    end
    label.GetName = function()
        return "Count" .. tostring(i)
    end
    buttons[i] = {
        m_ActionType = 12,
        m_ActionId = (i <= 4) and 1 or 2,
        m_Windows = { [7] = label },
        GetName = function()
            return "Button" .. tostring(i)
        end,
        label = label,
    }
    barButtons[i] = buttons[i]
end
ActionBars = { m_Bars = { { m_Buttons = barButtons } } }

local Timer = StockPiler.CraftHarvestTimer
macroReads = 0
plotReads = 0
Timer.Refresh()
check(macroReads >= 1 and macroReads < 20, "first refresh verifies the craft macro without a read per button, got " .. tostring(macroReads))
check(plotReads >= 4 and plotReads <= 32, "first refresh reads plots once for the snapshot, got " .. tostring(plotReads))
eq(Timer._refreshSnap, nil, "refresh does not leave the snapshot armed")
macroReads = 0
plotReads = 0
textWrites = 0
showWrites = 0
Timer.Refresh()
eq(macroReads, 1, "a steady refresh reads the craft macro once")
-- Four plot walks for the overlay plus one for the user-stay check.
-- Not one walk per hotbar button.
eq(plotReads, 20, "a steady refresh shares one plot snapshot")
eq(textWrites, 4, "only the craft copies clear their label")
eq(showWrites, 4, "only the craft copies update label visibility")
eq(buttons[5].label.last, nil, "a non-craft button is not painted")

plots[1].totalTimer = 7
local plotsBefore = plotReads
macroReads = 0
ActionButton = { UpdateInventory = function() end }
Timer._hooked = false
Timer.Install()
ActionButton.UpdateInventory(buttons[1])
check(plotReads > plotsBefore, "inventory paint reads live plots")
check(macroReads >= 1, "inventory paint rechecks macro ownership")
eq(Timer._refreshSnap, nil, "inventory paint does not arm the refresh snapshot")

plots[1].stage = 4
plots[1].totalTimer = 0
Timer.Paint(buttons[1])
check(buttons[1].label.last ~= nil and buttons[1].label.last ~= "", "a ready craft button paints an icon")
slot1.name = "Assist"
slot1.text = "/assist"
buttons[1].label.last = "STALE"
ActionButton.UpdateInventory(buttons[1])
eq(buttons[1].label.last, "", "a rewritten macro slot clears the craft label")
eq(StockPiler.Macro.IsCraftMacroButton(buttons[1]), false, "a rewritten slot fails ownership")
buttons[1].m_ActionId = 0
eq(StockPiler.Macro.IsCraftMacroButton(buttons[1]), false, "a zero action id fails ownership")
buttons[1].m_ActionId = 1
Timer._refreshSnap = { craftId = 0, harvestReady = false }
eq(StockPiler.Macro.IsCraftMacroButton(buttons[1]), false, "a zero snap id fails ownership")
buttons[2].m_ActionId = 0
Timer._refreshSnap = { craftId = 1, harvestReady = false }
eq(StockPiler.Macro.IsCraftMacroButton(buttons[2]), false, "a zero button fails during a live snapshot")
Timer._refreshSnap = nil
slot1.name = "StockPiler Craft"
slot1.text = "/script StockPiler.Macro.CraftClick()"
buttons[5].m_ActionId = 99
StockPiler.Macro.CraftMacroId = 99
eq(StockPiler.Macro.IsCraftMacroButton(buttons[5]), false, "a stale cached id does not pass on a reused slot")
StockPiler.Macro.CraftMacroId = 0
eq(StockPiler.Macro.GetCraftMacroId(), 1, "a fresh lookup finds the restored craft macro")
eq(StockPiler.Macro.IsCraftMacroButton(buttons[1]), true, "the restored slot matches the craft button")

if failures > 0 then
    io.stderr:write(string.format("%d/%d checks failed\n", failures, checks))
    os.exit(1)
end
print(string.format("perf_churn: %d checks passed", checks))
