-- 1.1.7 batch: name sort, refine-outstanding, money text, purchase chat,
-- brew yield, Watch paint cap, hotbar macro checks, buy failure cooldown,
-- and the refine seed baseline.
-- Run: lua5.1 tests/release_117_batch.lua

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
    local fh = assert(io.open(path, "rb"))
    local text = fh:read("*a")
    fh:close()
    text = text:gsub('L"([^"]*)"', '"%1"')
    assert(loadstring(text, "@" .. path))()
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

local function names_of(rows)
    local out = {}
    for i = 1, #rows do
        out[i] = tostring(rows[i].name) .. "#" .. tostring(rows[i].plantUid)
    end
    return table.concat(out, ",")
end

----------------------------------------------------------------
-- Plants: descending Name goes through the same invert as other columns.
----------------------------------------------------------------

StockPiler = {
    Util = {
        T = function()
            return ""
        end,
        ToNarrow = function(v)
            return tostring(v or "")
        end,
    },
    Settings = {
        plantSortColumn = "name",
        plantSortAscending = true,
        plantNameFilter = "",
        plantEffectFilter = "",
        plantLevelFilter = 0,
    },
    ViewList = {
        ItemRarityNameColor = function()
            return 255, 255, 255
        end,
        FormatSignedStat = function()
            return ""
        end,
        FormatPercentStat = function()
            return ""
        end,
        EffectTextForRow = function()
            return ""
        end,
        EffectFilterSignature = function()
            return "sig"
        end,
        EffectFilterCycle = function()
            return { "" }
        end,
        UpdateSortArrows = function() end,
        PaintClearButton = function() end,
        InitEffectCombo = function() end,
    },
    Knowledge = { GetGen = function() return 1 end },
    Watch = { GetGen = function() return 1 end },
}
local plantEntries = {
    { plantKey = "g", plantUid = 3, name = "Gamma", apoLevel = 1, have = 1 },
    { plantKey = "a", plantUid = 1, name = "alpha", apoLevel = 2, have = 1 },
    { plantKey = "b2", plantUid = 9, name = "Beta", apoLevel = 1, have = 1 },
    { plantKey = "b1", plantUid = 2, name = "Beta", apoLevel = 1, have = 1 },
}
StockPiler.Catalog = {
    ListPlantEntries = function()
        return plantEntries
    end,
    GetPlantWatch = function()
        return { enabled = false }
    end,
}
function DoesWindowExist()
    return false
end

load_module("Source/View/StockPilerTabPlants.lua")
StockPilerTabPlants.Refresh()
eq(names_of(StockPilerTabPlants.listData), "alpha#1,Beta#2,Beta#9,Gamma#3",
    "ascending name keeps A to Z and a stable tie")
StockPiler.Settings.plantSortAscending = false
StockPilerTabPlants.Refresh()
eq(names_of(StockPilerTabPlants.listData), "Gamma#3,Beta#2,Beta#9,alpha#1",
    "descending name reverses A to Z and keeps the tie")
StockPiler.Settings.plantSortColumn = "level"
StockPiler.Settings.plantSortAscending = false
StockPilerTabPlants._builtKey = nil
StockPilerTabPlants.Refresh()
eq(StockPilerTabPlants.listData[1].plantUid, 1,
    "descending level still puts the higher level first")
StockPiler.Settings.plantSortAscending = true
StockPilerTabPlants.Refresh()
eq(names_of(StockPilerTabPlants.listData), "Beta#2,Beta#9,Gamma#3,alpha#1",
    "ascending level still puts the lower level first")

----------------------------------------------------------------
-- Craft timer: outstanding refines come from the pipeline, and the
-- hotbar walks macros only when the button is a macro.
----------------------------------------------------------------

local nowCraft = 1000
local refineCalls = 0
local pipelineCalls = 0
local pipelineOutstanding = false
StockPiler = {
    Util = { NowSec = function() return nowCraft end },
    UpgradeSeed = {
        _stallLatch = "need_buy",
        _active = { seedUid = 5, why = "need_buy" },
    },
    Refine = {
        HasOutstanding = function()
            refineCalls = refineCalls + 1
            return true
        end,
        GetSeedBudget = function()
            return { credit = 0 }
        end,
    },
    RefinePipeline = {
        HasOutstanding = function()
            pipelineCalls = pipelineCalls + 1
            return pipelineOutstanding == true
        end,
    },
}
load_module("Source/Macro/CraftHarvestTimer.lua")
local Timer = StockPiler.CraftHarvestTimer
Timer._refreshSnap = nil

local stay = Timer.UserStayInfo()
eq(refineCalls, 0, "the craft timer does not call Refine.HasOutstanding")
check(pipelineCalls >= 1, "the craft timer asks the refine pipeline")
eq(type(stay) == "table" and stay.key or nil, "need_buy",
    "no outstanding refine still shows the buy stall")

pipelineOutstanding = true
pipelineCalls = 0
eq(Timer.UserStayInfo(), nil, "an outstanding refine is still active work")
check(pipelineCalls >= 1, "the outstanding check reads the pipeline")

StockPiler.RefinePipeline = nil
local stayNil = Timer.UserStayInfo()
eq(type(stayNil) == "table" and stayNil.key or nil, "need_buy",
    "a missing refine pipeline does not error and is not active work")

local walks = 0
StockPiler.Macro = {
    GetCraftMacroId = function()
        walks = walks + 1
        return 4
    end,
}
GameData = { PlayerActions = { DO_MACRO = 5 } }
ActionButton = {
    UpdateCooldownAnimation = function() end,
    UpdateInventory = function() end,
}
Timer._cdHooked = false
Timer._hooked = false
Timer._cdArmed = true
Timer._cdRemain = 5
Timer._cdMax = 5
Timer.Install()

local plain = { m_ActionType = 1, m_ActionId = 4 }
local macro = { m_ActionType = 5, m_ActionId = 9 }
walks = 0
for _ = 1, 40 do
    ActionButton.UpdateCooldownAnimation(plain)
    ActionButton.UpdateInventory(plain)
end
eq(walks, 0, "plain hotbar ticks do not walk macros")
ActionButton.UpdateCooldownAnimation(macro)
ActionButton.UpdateInventory(macro)
eq(walks, 2, "a macro button still checks the craft macro")
local walked = walks
for _ = 1, 40 do
    ActionButton.UpdateCooldownAnimation(plain)
    ActionButton.UpdateInventory(plain)
end
eq(walks, walked, "later plain ticks keep the macro walk count unchanged")

----------------------------------------------------------------
-- Buy: wide money text, PrintParts guard, per-uid failure cooldown.
----------------------------------------------------------------

local nowBuy = 4000
local buyCalls = {}
local function buy_env()
    buyCalls = {}
    StockPiler = {
        Util = { NowSec = function() return nowBuy end },
        Inventory = {
            CountByUid = function() return 0 end,
            GetSnapGen = function() return 1 end,
        },
        Watch = {
            IsAutoBuyEnabled = function() return true end,
            GetAutoBuyReserveGold = function() return 0 end,
            GetAutoBuyBudgetGold = function() return 100 end,
            GetAutoBuySpentBrass = function() return 0 end,
            GetGen = function() return 1 end,
        },
        TradeSkillCaps = {
            CanAutoBuy = function() return true end,
            LevelsHash = function() return "1" end,
        },
        MaterialSpec = {
            Matches = function(item, spec)
                local iu = tonumber(item and item.uniqueID) or 0
                local su = tonumber(spec and spec.uid) or 0
                return iu > 0 and iu == su
            end,
        },
        VendorAdapter = {
            IsStoreOpen = function() return true end,
            GetPlayerMoneyBrass = function() return 500000 end,
            BuyItem = function(item)
                local uid = tonumber(item and item.uniqueID) or 0
                buyCalls[#buyCalls + 1] = uid
                if uid == 11 then
                    return false, "refused"
                end
                return true
            end,
            GetMatchIndex = function()
                return {
                    rows = {
                        {
                            canbuy = true,
                            cost = 10,
                            item = { uniqueID = 11, slotNum = 1, stackCount = 1, cost = 10, name = "Vial" },
                        },
                        {
                            canbuy = true,
                            cost = 10,
                            item = { uniqueID = 22, slotNum = 2, stackCount = 1, cost = 10, name = "Seed" },
                        },
                    },
                }
            end,
        },
        Planner = {
            CollectVendorBuyJobs = function()
                return {
                    { uid = 11, deficit = 1, specKey = "a", spec = { uid = 11 }, name = "Vial" },
                    { uid = 22, deficit = 1, specKey = "b", spec = { uid = 22 }, name = "Seed" },
                }
            end,
        },
        Scheduler = { WakeAutoBuy = function() end },
        Debug = { Print = function() end, LogOp = function() end },
    }
end

buy_env()
load_module("Source/Buy.lua")
local Buy = StockPiler.Buy

local widened = {}
function towstring(s)
    local text = tostring(s)
    widened[#widened + 1] = text
    return text
end
MoneyFrame = nil
local function saw_wide(text)
    for i = 1, #widened do
        if widened[i] == text then
            return true
        end
    end
    return false
end
widened = {}
eq(Buy.FormatMoneyBrass(1 * 10000 + 2 * 100 + 3), "1g 2s 3b",
    "gold silver and brass text is unchanged")
check(saw_wide("1g 2s 3b"), "gold silver and brass text is wide")
eq(Buy.FormatMoneyBrass(10000), "1g", "whole gold text is unchanged")
eq(Buy.FormatMoneyBrass(250), "2s 50b", "silver and brass text is unchanged")
eq(Buy.FormatMoneyBrass(7), "7b", "brass-only text is unchanged")
eq(Buy.FormatMoneyBrass(10500), "1g 5s", "gold and silver text is unchanged")
local joined = "Cost " .. Buy.FormatMoneyBrass(10000) .. " left"
eq(joined, "Cost 1g left", "wide money still reads as the same coins in a sentence")
local seenBefore = #widened
MoneyFrame = {
    FormatMoneyString = function()
        return "<icon>1g"
    end,
}
eq(Buy.FormatMoneyBrass(10000), "<icon>1g", "icon money text is unchanged")
eq(#widened, seenBefore, "icon money is not rewritten")
MoneyFrame = nil

local printed = {}
StockPiler.Debug.Print = function(msg)
    printed[#printed + 1] = tostring(msg)
end
StockPiler.Util.T = nil
StockPiler.T = nil
Buy._queueAnnounceKey = nil
Buy._jobsCache = nil
Buy.NotifyQueueMaybeChanged()
local queueLine = table.concat(printed, "\n")
check(string.find(queueLine, "AutoBuy queue", 1, true) ~= nil,
    "the queue line was built: " .. queueLine)
check(string.find(queueLine, "20b", 1, true) ~= nil,
    "the queue line includes coin text: " .. queueLine)

local partsArgs = nil
local printCalls = 0
StockPiler.CraftChatAdapter = {
    PrintParts = function(...)
        partsArgs = { ... }
    end,
}
Buy._visitStopReason = nil
Buy._pendingBuy = nil
Buy._fillChatPending = {
    vial = { uid = 11, name = "Vial", count = 2, spent = 10203 },
}
StockPiler.Watch.GetAutoBuyReserveGold = function()
    return 1
end
StockPiler.VendorAdapter.GetPlayerMoneyBrass = function()
    return 0
end
Buy._jobsCache = nil
Buy._storeMatchCache = nil
Buy.IssueOne("reserve")
eq(type(partsArgs) == "table" and partsArgs[2] or nil, "1g 2s 3b",
    "a purchase line uses wide coin text when no item link is available")

StockPiler.CraftChatAdapter = {
    Print = function()
        printCalls = printCalls + 1
    end,
}
Buy._visitStopReason = nil
Buy._pendingBuy = nil
Buy._fillChatPending = {
    vial = { uid = 11, name = "Vial", count = 1, spent = 100 },
}
local fillOk = pcall(function()
    Buy.IssueOne("print-only")
end)
eq(fillOk, true, "a purchase line does not call a missing PrintParts")
eq(printCalls >= 1, true, "chat print still receives the visit message")

StockPiler.Watch.GetAutoBuyReserveGold = function()
    return 0
end
StockPiler.VendorAdapter.GetPlayerMoneyBrass = function()
    return 500000
end
StockPiler.CraftChatAdapter = nil
Buy._visitStopReason = nil
Buy._pendingBuy = nil
Buy._noSpendCooldownUntil = {}
Buy._lateBuyAttempts = {}
Buy._nextBuyAfter = 0
Buy._nextBuyIsCooldown = false
Buy._jobsCache = nil
Buy._storeMatchCache = nil
Buy._fillChatPending = {}
buyCalls = {}
check(Buy.IssueOne("fail-first") == true, "a later item still buys after one refusal")
eq(buyCalls[1], 11, "the refused item is attempted first")
eq(buyCalls[2], 22, "the next item proceeds in the same pass")
eq(#buyCalls, 2, "the refusal does not stop the pass")
check((tonumber(Buy._noSpendCooldownUntil[11]) or 0) > nowBuy,
    "the refused item is cooled down")
Buy._pendingBuy = nil
Buy._nextBuyAfter = 0
Buy._nextBuyIsCooldown = false
buyCalls = {}
Buy.IssueOne("while-cool")
eq(buyCalls[1], 22, "the cooled item is skipped")
local saw11 = false
for i = 1, #buyCalls do
    if buyCalls[i] == 11 then
        saw11 = true
    end
end
eq(saw11, false, "the refused item is not retried during its cooldown")
Buy._pendingBuy = nil
Buy._nextBuyAfter = 0
Buy._nextBuyIsCooldown = false
nowBuy = nowBuy + 2
buyCalls = {}
Buy.IssueOne("after-cool")
eq(buyCalls[1], 11, "the refused item is retried after the cooldown")

----------------------------------------------------------------
-- Brew: one craft subtracts the recipe yield.
----------------------------------------------------------------

local nowBrew = 5000
StockPiler = {
    Util = {
        NowSec = function() return nowBrew end,
        ToNarrow = function(v) return tostring(v or "") end,
    },
    Inventory = {
        IsReady = function() return true end,
        _snapPending = false,
        CountByUid = function() return 7 end,
    },
}
load_module("Source/Brew.lua")
local Brew = StockPiler.Brew

local function brew_session(extra)
    local s = {
        phase = "loaded",
        uniqueID = 9,
        potionKey = "uid:9",
        potionMin = 10,
        target = 10,
        potionHave = 7,
        potionDeficit = 3,
        craftable = 10,
    }
    if type(extra) == "table" then
        for k, v in pairs(extra) do
            s[k] = v
        end
    end
    Brew._session = s
    Brew._brewHaveBefore = 7
    Brew._postBrewClearArmed = false
    Brew._loadSource = nil
    return s
end

local yielded = brew_session({ recipeYield = 4 })
Brew.RefreshSessionAfterBrew()
eq(yielded.craftable, 6, "a brew subtracts a yield above 1")
eq(yielded.phase, "loaded", "an unchanged bag keeps the board")

local unknown = brew_session({ recipeYield = nil })
Brew.RefreshSessionAfterBrew()
eq(unknown.craftable, 9, "an unknown yield subtracts one")

local zero = brew_session({ recipeYield = 0 })
Brew.RefreshSessionAfterBrew()
eq(zero.craftable, 9, "a non-positive yield subtracts one")

local seenCraftable = nil
StockPiler.ApothecaryAdapter = {
    CloseWindow = function(session)
        seenCraftable = session and session.craftable
    end,
}
brew_session({ skillUp = true, craftable = 9, recipeYield = 3 })
Brew.RefreshSessionAfterBrew()
eq(seenCraftable, 6, "a practice brew subtracts the recipe yield")

----------------------------------------------------------------
-- Watch open paint: a failing flush stops after the attempt cap.
----------------------------------------------------------------

StockPiler = {
    FrameCounter = 10,
    Util = { T = function() return "" end },
    Watch = { CountEnabled = function() return 1 end },
}
function DoesWindowExist()
    return true
end
function WindowGetShowing(name)
    if name == "StockPilerWindow" then
        return true
    end
    return false
end
load_module("Source/View/StockPilerWindow.lua")
local kicks = 0
StockPilerTabWatch = {
    listData = {},
    KickListBoxLayout = function()
        kicks = kicks + 1
        StockPilerTabWatch.listData = { { statusKey = "ready_to_craft" } }
        StockPilerWindow._openPaintDidRefresh = true
        StockPilerWindow._openPaintChromePending = true
    end,
    UpdateRows = function()
        StockPilerTabWatch.listData = {}
    end,
    Refresh = function() end,
}
StockPilerWindow.SelectedTab = StockPilerWindow.TABS_WATCH
StockPilerWindow._openPaintPending = true
StockPilerWindow._openPaintGaveUp = false
StockPilerWindow._openPaintAttempts = 0
StockPilerWindow._openPaintDidRefresh = true
StockPilerWindow._openPaintChromePending = true
StockPilerWindow._openPaintNeedKick = true
StockPilerWindow._openPaintShownFrame = 0
for _ = 1, 350 do
    StockPilerWindow.FlushOpenPaint()
end
eq(kicks, 300, "repeated failing flushes stop after the cap")
eq(StockPilerWindow._openPaintGaveUp, true, "the paint cap gives up")
eq(StockPilerWindow._openPaintPending, false, "a capped paint is not pending")
local kicksBefore = kicks
StockPiler.FrameCounter = 20
StockPilerWindow.BeginOpenPaint()
eq(StockPilerWindow._openPaintAttempts, 0, "a new open resets the paint cap")
eq(StockPilerWindow._openPaintGaveUp, false, "a new open clears the give-up")
StockPiler.FrameCounter = 22
StockPilerWindow.FlushOpenPaint()
eq(kicks, kicksBefore + 1, "a new open can kick the list again")

----------------------------------------------------------------
-- Refine: live-seed baseline is taken before SendUseItem.
----------------------------------------------------------------

local liveSeeds = 4
local refineOrder = {}
StockPiler = {
    FrameCounter = 3,
    Inventory = {
        GetSnapGen = function() return 1 end,
        CountByUid = function(uid)
            if tonumber(uid) == 70 then
                return liveSeeds
            end
            return 0
        end,
        ForEachItem = function(fn)
            fn({
                uniqueID = 50,
                stackCount = 1,
                isRefinable = true,
                slot = 4,
            }, "craft", 4)
        end,
    },
    SeedMap = {
        BeginPendingRefine = function()
            refineOrder[#refineOrder + 1] = "begin"
        end,
    },
}
function SendUseItem()
    refineOrder[#refineOrder + 1] = "send:" .. tostring(liveSeeds)
    liveSeeds = liveSeeds + 3
    return true
end
EA_Window_Backpack = {
    GetCursorForBackpack = function()
        return 1
    end,
    TYPE_CRAFTING = 4,
}
load_module("Source/Refine.lua")
local Refine = StockPiler.Refine
local origTrack = Refine.TrackLiveSeed
Refine.TrackLiveSeed = function(uid)
    refineOrder[#refineOrder + 1] = "baseline:" .. tostring(StockPiler.Inventory.CountByUid(uid))
    return origTrack(uid)
end
Refine._engineIssueFrame = 0
Refine._issuedSeedThisTick = nil
Refine._pendingByPlant = {}
Refine._liveSeedBaseline = {}
local intent = {
    seedUid = 70,
    plantUid = 50,
    slot = 4,
    uses = 1,
    reason = "plant-need",
    item = { uniqueID = 50, stackCount = 1, isRefinable = true },
}
eq(Refine.IssueOne(intent, "op"), true, "the refine sends")
eq(table.concat(refineOrder, ","), "begin,baseline:4,send:4",
    "the live-seed baseline is taken before SendUseItem")
eq(Refine._liveSeedBaseline[70], 4, "the baseline is the pre-send seed count")

function SendUseItem()
    error("refuse")
end
StockPiler.FrameCounter = 4
Refine._engineIssueFrame = 0
Refine._issuedSeedThisTick = nil
intent.seedUid = 71
Refine._liveSeedBaseline[71] = nil
eq(Refine.IssueOne(intent, "op"), false, "a refused send does not count as issued")
eq(Refine._liveSeedBaseline[71], nil, "a refused send does not keep a new baseline")
Refine._liveSeedBaseline[71] = 2
StockPiler.FrameCounter = 5
Refine._engineIssueFrame = 0
Refine._issuedSeedThisTick = nil
eq(Refine.IssueOne(intent, "op"), false, "a second refused send does not count")
eq(Refine._liveSeedBaseline[71], 2, "a refused send restores the previous baseline")

if failures > 0 then
    io.stderr:write(string.format("%d/%d checks failed\n", failures, checks))
    os.exit(1)
end
print(string.format("release_117_batch: %d checks passed", checks))
