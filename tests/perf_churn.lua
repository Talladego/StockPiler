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
eq(resetRow.retiredJunk, true, "reset keeps a character field that is not retired")
local replaced = { retiredJunk = 1 }
StockPiler.Settings.characters[P.GetCharacterKey()] = replaced
local shaped = P.GetCharacterBucket(true)
eq(shaped, replaced, "a replaced bucket is the stored table")
eq(shapes, 3, "a replaced bucket is normalised")
eq(shaped.retiredJunk, 1, "a replaced bucket keeps unknown fields")
eq(type(shaped.watches), "table", "a replaced bucket receives defaults")
local quiet = P.GetCharacterBucket(true)
eq(quiet, shaped, "the replaced bucket is cached")
eq(shapes, 3, "the cached replacement is not normalised again")
StockPiler.RetiredCharacterSettingKeys = { "goneKey" }
local retiredRow = { goneKey = true, keptNote = "stay" }
StockPiler.Settings.characters[P.GetCharacterKey()] = retiredRow
local dropped = P.GetCharacterBucket(true)
eq(dropped.goneKey, nil, "a listed retired key is dropped")
eq(dropped.keptNote, "stay", "a field outside the retired list is kept")
eq(shapes, 4, "a retired-key bucket is normalised once")
StockPiler.RetiredCharacterSettingKeys = nil

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
-- One shared cultivator walk fills every plot field.
eq(plotReads, 4, "a steady refresh shares one plot snapshot")
eq(textWrites, 4, "only the craft copies clear their label")
eq(showWrites, 4, "only the craft copies update label visibility")
eq(buttons[5].label.last, nil, "a non-craft button is not painted")

slot1.name = "Assist"
slot1.text = "/assist"
plotReads = 0
Timer.Refresh()
eq(plotReads, 0, "a missing craft macro skips plot reads")
eq(Timer._refreshSnap, nil, "a missing craft macro clears the snapshot")
slot1.name = "StockPiler Craft"
slot1.text = "/script StockPiler.Macro.CraftClick()"

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

plots[1].stage = 1
plots[1].totalTimer = 20
buttons[1].label.SetText = function()
    error("boom")
end
Timer.Refresh()
eq(Timer._refreshSnap, nil, "a paint error still clears the snapshot")

-- Read-only plan lookups must not repeat live trade-skill reads (issue 47).
StockPiler.Util.CharacterRow = function(create)
    return StockPiler.Persistence.GetCharacterBucket(create ~= false)
end
GameData.TradeSkills = { CULTIVATION = 3, APOTHECARY = 4 }
GameData.TradeSkillLevels = { [3] = 200, [4] = 200 }
local planTick = 500
local planFrame = 4
function GetGameTime()
    return planTick
end
StockPiler.FrameCounter = planFrame
local liveReads = 0
local skillLevel = 200
function GetTradeSkillLevel()
    liveReads = liveReads + 1
    return skillLevel
end
load_module("Source/Adapters/TradeSkillCaps.lua")
load_module("Source/Stores/WatchStore.lua")
load_module("Source/Stores/PlanSnapshotStore.lua")
load_module("Source/Planner/Planner.lua")
local P = StockPiler.Planner
local Caps = StockPiler.TradeSkillCaps
local Watch = StockPiler.Watch
local PS = StockPiler.PlanSnapshot
local Bus = StockPiler.EventBus
Bus.Subscribe(StockPiler.Events.TRADE_SKILLS_CHANGED, P.OnTradeSkillsChanged)
local row = StockPiler.Persistence.GetCharacterBucket(true)
row.autoGrowEnabled = false
row.autoBuyEnabled = false
row.growSeedBufferMin = 5
row.growSeedBufferEnabled = true
Caps._lastCult = 0
Caps._lastApo = 0
Caps._persistedHydrated = false
Caps._skillsReady = false
Caps._cultZeroPulses = 0
Caps._apoZeroPulses = 0
P.InvalidateSettingsHashMemo()
Sch._planDue = false
liveReads = 0
local coldKey = P.CacheKeyFromGens()
eq(liveReads, 5, "a cold cache key performs five trade-skill reads")
check(P._memoSettingsHash ~= nil, "a cold cache key stores the settings hash")
check(P._memoSettingsHashClock == "4:500", "the memo clock is the frame and game tick")
local coldReads = liveReads
local coldStable = true
for _ = 1, 40 do
    if P.CacheKeyFromGens() ~= coldKey then
        coldStable = false
    end
end
check(coldStable, "repeat cache keys stay stable for the tick")
eq(liveReads, coldReads, "repeat cache keys in the same tick add no skill reads")

local lookups = 0
local origKey = P.CacheKeyFromGens
P.CacheKeyFromGens = function(...)
    lookups = lookups + 1
    return origKey(...)
end
local nudges = 0
local prevEnqueue = Sch.EnqueuePlanRebuild
Sch.EnqueuePlanRebuild = function(opts, ...)
    if type(opts) == "table" and opts.nudge == true then
        nudges = nudges + 1
    end
    return prevEnqueue(opts, ...)
end
Sch._planDue = false
PS.Set({ rows = {} }, origKey())
lookups = 0
local budgetReads = liveReads
for _ = 1, 1000 do
    PS.GetOrBuild(false)
end
eq(lookups, 1000, "each read-only lookup checks the plan key")
eq(liveReads, budgetReads, "repeated read-only plan lookups do not read trade skills")
eq(nudges, 0, "an unchanged plan does not nudge a rebuild")
P.CacheKeyFromGens = origKey
Sch.EnqueuePlanRebuild = prevEnqueue

local heldKey = P.CacheKeyFromGens()
local beforeDirect = liveReads
eq(Caps.GetCultSkill(), 200, "a positive cultivation getter still reads the engine")
check(liveReads > beforeDirect, "GetCultSkill still queries the trade-skill API")
beforeDirect = liveReads
eq(Caps.GetApoSkill(), 200, "a positive apothecary getter still reads the engine")
check(liveReads > beforeDirect, "GetApoSkill still queries the trade-skill API")
beforeDirect = liveReads
local cultLive = Caps.ReadCultSkillLive()
local apoLive = Caps.ReadApoSkillLive()
eq(cultLive, 200, "the direct cultivation reader returns the live level")
eq(apoLive, 200, "the direct apothecary reader returns the live level")
check(liveReads >= beforeDirect + 2, "direct live readers still query the trade-skill API")
local afterDirect = liveReads
eq(P.CacheKeyFromGens(), heldKey, "direct skill reads do not change the plan cache key")
eq(liveReads, afterDirect, "direct skill reads do not force another settings-hash read")

skillLevel = 0
eq(Caps.GetCultSkill(), 200, "one explicit zero keeps the sticky cultivation level")
local zeroReads = liveReads
eq(P.CacheKeyFromGens(), heldKey, "a zero reading keeps the plan cache key")
eq(liveReads, zeroReads, "a zero reading does not reread skills for the plan key")
skillLevel = 200
eq(Caps.GetCultSkill(), 200, "cultivation recovers from the zero reading")
eq(Caps.GetApoSkill(), 200, "apothecary stays available through the zero reading")
eq(P.CacheKeyFromGens(), heldKey, "recovery keeps the plan cache key")
eq(planTick, 500, "zero-reading recovery stays on the same game tick")
eq(StockPiler.FrameCounter, planFrame, "zero-reading recovery stays on the same frame")

P.CacheKeyFromGens()
check(P._memoSettingsHash ~= nil, "the settings hash is memoized before a watch edit")
eq(Watch.SetCharacterField("growSeedBufferMin", 12), true, "the seed buffer minimum is stored")
eq(P._memoSettingsHash, nil, "a watch setting clears the memoized settings hash")
eq(P._memoSettingsHashClock, nil, "a watch setting clears the memo clock")
eq(planTick, 500, "the watch setting does not move the game tick")
eq(StockPiler.FrameCounter, planFrame, "the watch setting does not move the frame")
local seeded = P.CacheKeyFromGens()
check(seeded ~= heldKey, "a watch setting changes the cache key on the same tick")
row.autoBuyEnabled = true
local bought = P.CacheKeyFromGens()
check(bought ~= seeded, "a raw watch setting changes the cache key on the same tick")
eq(planTick, 500, "the raw watch setting stays on the same game tick")
row.autoBuyEnabled = false

P.CacheKeyFromGens()
P.InvalidateFocusCaches()
eq(P._memoSettingsHash, nil, "InvalidateFocusCaches clears the memoized settings hash")
eq(P._memoSettingsHashClock, nil, "InvalidateFocusCaches clears the memo clock")

local armed = P.CacheKeyFromGens()
check(P._memoSettingsHash ~= nil, "the hash is memoized before the profession loss")
skillLevel = 0
GameData.TradeSkillLevels[3] = 0
GameData.TradeSkillLevels[4] = 0
Caps.OnTradeSkillPulse()
eq(P._memoSettingsHash, nil, "losing a profession clears the memoized settings hash")
eq(P._memoSettingsHashClock, nil, "losing a profession clears the memo clock")
eq(planTick, 500, "profession loss stays on the same game tick")
local lost = P.CacheKeyFromGens()
check(lost ~= armed, "losing cultivation and apothecary changes the plan cache key")
eq((tonumber(Caps._lastCult) or 0), 0, "confirmed zeros clear the sticky cultivation level")
eq((tonumber(Caps._lastApo) or 0), 0, "confirmed zeros clear the sticky apothecary level")

skillLevel = 200
GameData.TradeSkillLevels[3] = 200
GameData.TradeSkillLevels[4] = 200
Caps.OnTradeSkillPulse()
eq(P._memoSettingsHash, nil, "learning a profession clears the memoized settings hash")
eq(P._memoSettingsHashClock, nil, "learning a profession clears the memo clock")
local learned = P.CacheKeyFromGens()
check(learned ~= lost, "learning a profession changes the plan cache key on the same tick")
check((tonumber(Caps.GetCultSkill()) or 0) > 0, "learning restores the cultivation getter")
check((tonumber(Caps.GetApoSkill()) or 0) > 0, "learning restores the apothecary getter")

local fracReads = liveReads
planTick = 500.9
eq(P.CacheKeyFromGens(), learned, "a fractional tick inside the same second keeps the cache key")
eq(liveReads, fracReads, "a fractional tick inside the same second does not reread skills")
local tickReads = liveReads
planTick = 501
P.CacheKeyFromGens()
check(liveReads > tickReads, "a new game tick reads trade skills again")
planTick = 500

----------------------------------------------------------------
-- Brew frametime: defer cold WarmHave, skip repeat relink, cache slots.
----------------------------------------------------------------

StockPiler.Util.TryCall = StockPiler.Util.TryCall or function(_, fn, ...)
    local ok, a, b = pcall(fn, ...)
    if ok then
        return a, b
    end
    return false
end

GameData.Player = GameData.Player or {}
GameData.Player.itemsDirty = false
GameData.Player.craftingItemsDirty = false
load_module("Source/Adapters/BagAdapter.lua")
local BA = StockPiler.BagAdapter
GameData.Player.itemsDirty = false
GameData.Player.craftingItemsDirty = false
BA.FetchForce()
eq(GameData.Player.itemsDirty, false, "FetchForce does not leave itemsDirty set")
eq(GameData.Player.craftingItemsDirty, false, "FetchForce does not leave craftingItemsDirty set")

load_module("Source/Adapters/ApothecaryAdapter.lua")
local AA = StockPiler.ApothecaryAdapter
local slotReads = 0
local backpackReads = 0
StockPiler.FrameCounter = 4
GetCraftingBackPackSlots = function()
    slotReads = slotReads + 1
    return { [0] = { slot = 1, backpack = 2 } }
end
EA_Window_Backpack = {
    TYPE_INVENTORY = 2,
    TYPE_CRAFTING = 4,
    GetItemsFromBackpack = function()
        backpackReads = backpackReads + 1
        return { [1] = { uniqueID = 42, stackCount = 3 } }
    end,
}
AA.TradeSkill = function()
    return 4
end
AA.CraftingBackpackType = function()
    return 4
end
eq(AA.GetSlottedItem(0) ~= nil, true, "a slotted item resolves from the backpack")
eq(AA.GetSlottedItem(0) ~= nil, true, "the same frame resolves the slotted item again")
eq(slotReads, 1, "GetCraftingBackPackSlots is cached for the frame")
eq(backpackReads, 1, "GetItemsFromBackpack is cached for the frame")
AA.InvalidateCraftSlotCache()
eq(AA.GetSlottedItem(0) ~= nil, true, "an invalidated cache reads the slot again")
eq(slotReads, 2, "invalidating the slot cache reads slots again")

local walks = 0
StockPiler.Inventory.ForEachItem = function(fn)
    walks = walks + 1
    fn({ uniqueID = 77, stackCount = 2, type = 31 })
end
StockPiler.Inventory.IsReady = function()
    return true
end
StockPiler.Brew = {
    GetSession = function()
        return {
            recipe = {
                slots = {
                    { role = "container", uniqueID = 1, perCraft = 1 },
                    { role = "main", uniqueID = 2, perCraft = 1 },
                },
            },
            recipeSpecKey = "brew-test",
        }
    end,
}
load_module("Source/Knowledge/BrewLearn.lua")
local BL = StockPiler.BrewLearn
StockPiler.FrameCounter = 6
eq(BL.BeginPendingCraft(), true, "the first perform captures the pending craft")
eq(walks, 1, "the first capture snapshots potion counts")
eq(BL.HasFreshPendingCraftForFrame(4), true, "the pending craft is fresh this frame")
eq(BL.BeginPendingCraft(), true, "a second capture on the same frame is skipped")
eq(walks, 1, "the same-frame capture does not walk bags again")

load_module("Source/Knowledge/MaterialSpec.lua")
load_module("Source/Knowledge/RecipeSpec.lua")
local RS = StockPiler.RecipeSpec
StockPiler.Account = { recipes = {}, potions = {}, items = {} }
local relinks = 0
local origRelink = RS.RelinkPotionRecipeKeysFromOutcomes
RS.RelinkPotionRecipeKeysFromOutcomes = function()
    relinks = relinks + 1
    return origRelink()
end
local uidRelinks = 0
local origUidRelink = RS.RelinkPotionUid
RS.RelinkPotionUid = function(uid)
    uidRelinks = uidRelinks + 1
    return origUidRelink(uid)
end
local function brewOnce()
    return RS.StoreLearnedRecipeSpec({
        {
            uniqueID = 11,
            role = "container",
            itemData = { uniqueID = 11, name = "Vial" },
        },
        {
            uniqueID = 12,
            role = "main",
            itemData = { uniqueID = 12, name = "Leaf", stability = 1 },
        },
    }, {
        { uniqueID = 77, name = "Tonic", lastDelta = 1 },
    })
end
local genBefore = RS.GetRecipeStatsGen()
eq(brewOnce(), true, "the first brew of a recipe is stored")
check(RS.GetRecipeStatsGen() > genBefore, "a new recipe bumps recipe stats")
check(relinks >= 1 or uidRelinks >= 1, "a new recipe relinks potion keys")
local genMid = RS.GetRecipeStatsGen()
local relinksMid = relinks
eq(brewOnce(), true, "a repeat brew of the same recipe is stored")
eq(relinks, relinksMid, "a repeat single-outcome brew does not relink keys")
-- Yield may still be settling across the first samples, so only require that
-- a later identical 1x brew stops moving the stats generation.
for _ = 1, 6 do
    brewOnce()
end
local genSettled = RS.GetRecipeStatsGen()
local relinksSettled = relinks
eq(brewOnce(), true, "another identical brew is stored")
eq(RS.GetRecipeStatsGen(), genSettled, "a settled 1x brew does not bump recipe stats")
eq(relinks, relinksSettled, "a settled 1x brew does not relink keys")

local learnedRecipe = nil
for _, row in pairs(StockPiler.Account.recipes) do
    learnedRecipe = row
end
local displayBefore = RS.GetRecipeDisplayGen()
local attemptsBefore = RS.OutcomeSuccessStats(learnedRecipe, 77).brewAttempts
eq(brewOnce(), true, "one more settled brew is stored")
eq(RS.GetRecipeStatsGen(), genSettled, "the extra settled brew still does not bump recipe stats")
check(RS.GetRecipeDisplayGen() > displayBefore, "the Potions tab display generation moves")
local attemptsAfter = RS.OutcomeSuccessStats(learnedRecipe, 77).brewAttempts
check(attemptsAfter > attemptsBefore, "the live recipe attempt count moves")
load_module("Source/View/RecipeTooltip.lua")
local prevTipT = StockPiler.Util.T
StockPiler.Util.T = function(key, tokens)
    local s = tostring(key)
    if key == "recipe.success" then
        s = "Success: {pct}% ({ok}/{att})"
    end
    if type(tokens) == "table" then
        for k, v in pairs(tokens) do
            s = string.gsub(s, "{" .. tostring(k) .. "}", tostring(v))
        end
    end
    return s
end
local tipRows = StockPiler.RecipeTooltip.BuildRows({
    name = "Tonic",
    potionUid = 77,
    recipe = learnedRecipe,
    recipeYield = 1,
    brewAttempts = 1,
    brewSuccesses = 1,
    successRate = 1,
})
StockPiler.Util.T = prevTipT
local tipLine = ""
for i = 1, #tipRows do
    local text = tostring(tipRows[i].text or "")
    if string.find(text, "Success:", 1, true) ~= nil then
        tipLine = text
    end
end
check(attemptsAfter > 1, "the live attempt count is past the stale snapshot")
local showsLive = string.find(tipLine, tostring(attemptsAfter), 1, true) ~= nil
check(showsLive == true, "the recipe tooltip shows the live attempt count")

load_module("Source/Brew.lua")
local Brew = StockPiler.Brew
local allows = {}
local prewarms = 0
local dirtyRecount = nil
StockPiler.Planner.LiveRecount = function(opts)
    allows[#allows + 1] = opts and opts.allowWarmHave
    return 1
end
StockPiler.Planner.IsHaveCacheWarmForSnap = function()
    return false
end
local origPrewarm = StockPiler.Scheduler.RequestCachePrewarm
StockPiler.Scheduler.RequestCachePrewarm = function(reason)
    prewarms = prewarms + 1
    return origPrewarm(reason)
end
local origDirty = StockPiler.EventBus.FireWatchUiDirty
StockPiler.EventBus.FireWatchUiDirty = function(payload)
    if payload and payload.reason == "after-brew-counts" then
        dirtyRecount = payload.recount
    end
    return origDirty(payload)
end
StockPiler.Inventory.IsSnapshotPending = function()
    return false
end
StockPiler.Inventory.CountByUid = function()
    return 5
end
StockPiler.Inventory._snapPending = false
StockPiler.FrameCounter = 8
StockPiler.Scheduler.NoteHeavyWork()
Brew._session = {
    phase = "loaded",
    uniqueID = 77,
    potionKey = "uid:77",
    potionMin = 10,
    potionHave = 4,
    potionDeficit = 6,
    craftable = 2,
}
Brew._brewHaveBefore = 5
Brew._postBrewClearArmed = false
Brew._loadSource = "auto"
Brew.RefreshSessionAfterBrew()
eq(allows[#allows], false, "a cold bag-flush frame does not WarmHave")
check(prewarms >= 1, "a cold bag-flush frame enqueues WarmHave")
eq(dirtyRecount, nil, "after-brew watch dirty does not request another recount")
allows = {}
prewarms = 0
StockPiler.FrameCounter = 9
Brew._session.phase = "loaded"
Brew._brewHaveBefore = 5
Brew._postBrewClearArmed = false
Brew.RefreshSessionAfterBrew()
eq(allows[#allows], true, "off the bag-flush frame a cold cache still WarmHaves")

local craftArgs = {}
PerformCrafting = function(a, b, c)
    craftArgs[#craftArgs + 1] = { a, b, c }
    return "crafted", b
end
load_module("Source/Knowledge/LearnBridge.lua")
local LB = StockPiler.LearnBridge
LB._performHooked = false
eq(LB.EnsurePerformCraftingHook(), true, "PerformCrafting is hooked")
AA.TradeSkill = function()
    error("trade skill down")
end
local craftResult, craftEcho = PerformCrafting(4, 9, "tail")
eq(craftResult, "crafted", "a throwing trade-skill prologue still crafts")
eq(craftEcho, 9, "the craft return value is forwarded")
eq(craftArgs[1][1], 4, "the trade skill argument is forwarded")
eq(craftArgs[1][2], 9, "the count argument is forwarded")
eq(craftArgs[1][3], "tail", "the extra argument is forwarded")
AA.TradeSkill = function()
    return 4
end
BL.HasFreshPendingCraftForFrame = function()
    error("fresh check down")
end
craftResult, craftEcho = PerformCrafting(4, 2, "more")
eq(craftResult, "crafted", "a throwing fresh-check prologue still crafts")
eq(craftEcho, 2, "the second craft return value is forwarded")
eq(#craftArgs, 2, "both crafts reached the original function")
eq(craftArgs[2][3], "more", "the second extra argument is forwarded")

-- Craft-bag free slots stay cached for a snap and drop after a forced fetch.
StockPiler.Inventory.GetSnapGen = function()
    return 3
end
GameData.Player.craftingItemsDirty = false
local freeReads = 0
local realCount = BA.CountBagOccupancy
BA.CountBagOccupancy = function(bagType)
    freeReads = freeReads + 1
    return 1, 4
end
BA.InvalidateCraftFreeCache()
eq(BA.CraftBagFreeSlots(), 3, "craft bag free slots are capacity minus filled")
eq(BA.CraftBagFreeSlots(), 3, "the same snap reuses the free-slot cache")
eq(freeReads, 1, "a cached free-slot check does not recount the craft bag")
BA.FetchForce()
eq(BA.CraftBagFreeSlots(), 3, "a forced fetch recounts free slots")
check(freeReads > 1, "FetchForce invalidates the free-slot cache")
BA.CountBagOccupancy = realCount

if failures > 0 then
    io.stderr:write(string.format("%d/%d checks failed\n", failures, checks))
    os.exit(1)
end
print(string.format("perf_churn: %d checks passed", checks))
