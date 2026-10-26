-- NPC quest / trainer / service windows must survive post-harvest refine and plant.
-- Run: lua5.1 tests/npc_interaction_windows.lua

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

local now = 5000
local sends = 0
local wakes = 0
local arms = 0
local pendingSnaps = 0
local prints = {}
local showing = {}
local exists = {}
local closeCalls = {}

local function resetWindows()
    showing = {}
    exists = {}
    closeCalls = {}
    WindowUtils = {
        openWindowList = {},
        Cascade = {
            List = {},
            Resolve = function()
                local list = WindowUtils.Cascade.List
                for i = 1, #list do
                    local entry = list[i]
                    if type(entry) == "table" and type(entry.closeFunction) == "function" then
                        entry.closeFunction()
                    end
                    if type(entry) == "table" and type(entry.name) == "string" then
                        WindowSetShowing(entry.name, false)
                    end
                end
            end,
        },
    }
end

function DoesWindowExist(name)
    return exists[name] == true
end

function WindowGetShowing(name)
    return showing[name] == true
end

function WindowSetShowing(name, on)
    showing[name] = on == true
end

local function setOpen(name, isOpen)
    exists[name] = true
    showing[name] = isOpen == true
end

local function pushOpen(name)
    setOpen(name, true)
    local list = WindowUtils.openWindowList
    list[#list + 1] = name
end

local function removeOpen(name)
    local list = WindowUtils.openWindowList
    local kept = {}
    for i = 1, #list do
        local entry = list[i]
        local entryName = entry
        if type(entry) == "table" then
            entryName = entry.name
        end
        if entryName ~= name then
            kept[#kept + 1] = entry
        end
    end
    WindowUtils.openWindowList = kept
end

local function playerClose(name)
    showing[name] = false
    removeOpen(name)
end

resetWindows()

StockPiler = {
    FrameCounter = 7,
    Util = {
        NowSec = function()
            return now
        end,
        TryCall = function(_, fn, ...)
            if type(fn) ~= "function" then
                return false
            end
            return pcall(fn, ...)
        end,
        T = function(key)
            return tostring(key)
        end,
    },
    T = function(key)
        if key == "refine.blocked.vendor_open" then
            return "Refine stalled - close the merchant window to continue."
        end
        return tostring(key)
    end,
    Debug = {
        Print = function(msg)
            prints[#prints + 1] = tostring(msg)
        end,
    },
    Scheduler = {
        WakeAutoGrow = function()
            wakes = wakes + 1
        end,
        ArmPlantQuiet = function()
            arms = arms + 1
        end,
    },
    Grow = {
        IsEnabled = function()
            return true
        end,
        HasEmptyPlot = function()
            return false
        end,
        HasPendingBufferRefine = function()
            return false
        end,
    },
    Watch = {
        IsAutoGrowEnabled = function()
            return true
        end,
        IsSeedBufferEnabled = function()
            return false
        end,
        GetGen = function()
            return 1
        end,
    },
    SeedMap = {
        BeginPendingRefine = function()
            pendingSnaps = pendingSnaps + 1
        end,
    },
}

function SendUseItem()
    sends = sends + 1
end

EA_Window_Backpack = {
    windowName = "EA_Window_Backpack",
    GetCursorForBackpack = function()
        return 1
    end,
}

function AddCraftingItem()
    return true
end

load_module("Source/Adapters/VendorAdapter.lua")
load_module("Source/Refine.lua")
load_module("Source/Buy.lua")
load_module("Source/Core/EngineEventBridge.lua")
load_module("Source/Adapters/CultivatorAdapter.lua")

local VA = StockPiler.VendorAdapter
local Refine = StockPiler.Refine
local Buy = StockPiler.Buy
local Bridge = StockPiler.EngineEventBridge
local CA = StockPiler.CultivatorAdapter

local STORE = "EA_Window_InteractionStore"
local TIP = "Refine stalled - close the merchant window to continue."

local function allowPair()
    return Refine.ShouldAllowRefineNow()
end

local function intent()
    return {
        slot = 3,
        uses = 1,
        seedUid = 43,
        plantUid = 42,
        reason = "plant-need",
        item = { uniqueID = 42, stackCount = 4 },
    }
end

local function resetRefine()
    Refine._refineDirty = true
    Refine._refineDirtyReason = "generic"
    Refine._engineIssueFrame = 0
    Refine._issuedSeedThisTick = nil
    Refine._pendingByPlant = {}
    Refine.InvalidateIntentCache()
    StockPiler.FrameCounter = StockPiler.FrameCounter + 1
end

local blockers = {
    "EA_Window_InteractionQuest",
    "EA_Window_InteractionTraining",
    "EA_Window_InteractionRenownTraining",
    "BankWindow",
    "GuildVaultWindow",
    "MailWindow",
    "AuctionWindow",
    "BarberWindow",
    "EA_Window_EquipmentUpgrade",
    "EA_InteractionFlightMasterWindow",
}

for i = 1, #blockers do
    local name = blockers[i]
    resetWindows()
    resetRefine()
    pushOpen(name)
    local okAllow, why = allowPair()
    eq(okAllow, false, name .. " blocks ShouldAllowRefineNow")
    eq(why, "interaction-open", name .. " reason is interaction-open")
    local sendsBefore = sends
    local armsBefore = arms
    local snapsBefore = pendingSnaps
    local frameBefore = Refine._engineIssueFrame
    eq(Refine.IssueOne(intent()), false, name .. " blocks IssueOne")
    eq(sends, sendsBefore, name .. " does not SendUseItem")
    eq(arms, armsBefore, name .. " does not arm plant quiet")
    eq(pendingSnaps, snapsBefore, name .. " does not snapshot a pending refine")
    eq(Refine._engineIssueFrame, frameBefore, name .. " does not stamp IssuedThisFrame")
    eq(Refine._pendingByPlant[42], nil, name .. " does not track a live refine")
end

-- Alias service names and a {name=} open-list entry.
resetWindows()
resetRefine()
exists["EA_Window_Mail"] = true
showing["EA_Window_Mail"] = true
WindowUtils.openWindowList = { { name = "EA_Window_Mail" } }
eq(select(2, allowPair()), "interaction-open", "EA_Window_Mail alias blocks refine")

resetWindows()
resetRefine()
WindowUtils.openWindowList = { EA_Window_InteractionTraining = true }
setOpen("EA_Window_InteractionTraining", true)
eq(VA.IsNonStoreInteractionOpen(), true, "string-key openWindowList still blocks")

-- Merchant store keeps the vendor-open notice. ignoreVendor still sees a quest.
resetWindows()
resetRefine()
setOpen(STORE, true)
local storeAllow, storeWhy = allowPair()
eq(storeAllow, false, "an open merchant blocks refine")
eq(storeWhy, "vendor-open", "merchant reason stays vendor-open")
local ignoreAllow, ignoreWhy = Refine.ShouldAllowRefineNow({ ignoreVendor = true })
eq(ignoreAllow, true, "ignoreVendor allows refine when only the store is open")
eq(ignoreWhy, "post-harvest", "store-only ignoreVendor is post-harvest")
eq(VA.IsInteractionOpen({ includeStore = true }), true, "includeStore sees the merchant")
eq(VA.IsNonStoreInteractionOpen(), false, "the store alone is not a non-store interaction")

prints = {}
Refine.ClearBlockedNotify()
Refine.CollectIntents({ ignoreVendor = true })
Refine._intentCache = { { reason = "plant-need", slot = 3, uses = 1 } }
eq(Refine.MaybeNotifyBlocked(), true, "store-only refine work still notifies")
eq(#prints, 1, "the merchant tip prints once")
eq(prints[1], TIP, "the merchant tip text is unchanged")

Refine.ClearBlockedNotify()
pushOpen("EA_Window_InteractionQuest")
local bothAllow, bothWhy = Refine.ShouldAllowRefineNow({ ignoreVendor = true })
eq(bothAllow, false, "ignoreVendor still blocks when a quest is also open")
eq(bothWhy, "interaction-open", "store plus quest is interaction-open")
eq(select(2, allowPair()), "vendor-open", "default opts still prefer vendor-open")
eq(Refine.MaybeNotifyBlocked(), false, "a quest beside the store does not use the merchant tip")
eq(#prints, 1, "the quest does not print another merchant tip")

-- Dialog opens after intents were collected. Same-frame hide does not block.
resetWindows()
resetRefine()
local collected = Refine.CollectIntents()
check(type(collected) == "table", "CollectIntents returns a list while no dialog is open")
pushOpen("EA_Window_InteractionQuest")
local sendsBefore = sends
eq(Refine.IssueOne(intent()), false, "a dialog opened before IssueOne blocks the send")
eq(sends, sendsBefore, "that IssueOne does not SendUseItem")

showing["EA_Window_InteractionQuest"] = false
exists["EA_Window_InteractionQuest"] = true
local hiddenAllow, hiddenWhy = allowPair()
eq(hiddenAllow, true, "same-frame hide does not block refine")
eq(hiddenWhy, "post-harvest", "a hidden quest still listed is not interaction-open")
showing["EA_Window_InteractionQuest"] = true
eq(select(2, allowPair()), "interaction-open", "reopening the quest blocks refine again")

-- DoesWindowExist missing: WindowGetShowing false still means closed.
local savedExists = DoesWindowExist
DoesWindowExist = nil
showing["EA_Window_InteractionQuest"] = false
eq(VA.IsNonStoreInteractionOpen(), false, "showing false without DoesWindowExist is closed")
showing["EA_Window_InteractionQuest"] = true
eq(VA.IsNonStoreInteractionOpen(), true, "showing true without DoesWindowExist stays open")
DoesWindowExist = savedExists

-- Stale list entry whose window no longer exists still counts (until OnHidden).
exists["EA_Window_InteractionQuest"] = false
showing["EA_Window_InteractionQuest"] = false
eq(VA.IsNonStoreInteractionOpen(), true, "listed window with DoesWindowExist false still counts")

-- Empty open list does not scan WindowGetShowing. A missing list does.
resetWindows()
resetRefine()
setOpen("EA_Window_InteractionQuest", true)
WindowUtils.openWindowList = {}
eq(VA.IsNonStoreInteractionOpen(), false, "an empty open list does not poll WindowGetShowing")
local savedUtils = WindowUtils
WindowUtils = nil
eq(VA.IsNonStoreInteractionOpen(), true, "a missing open list falls back to known windows")
WindowUtils = savedUtils
eq(VA.IsNonStoreInteractionOpen(), false, "restoring an empty open list stops the fallback")

-- Ordinary windows, including gear CharacterWindow, do not block.
resetWindows()
resetRefine()
CharacterWindow = { mode = 1, MODE_DYE_MERCHANT = 3 }
pushOpen("CharacterWindow")
pushOpen("EA_Window_Backpack")
pushOpen("CultivationWindow")
pushOpen("ApothecaryWindow")
pushOpen("StockPilerWindow")
local plainAllow, plainWhy = allowPair()
eq(plainAllow, true, "ordinary character and crafting windows allow refine")
eq(plainWhy, "post-harvest", "those windows are not interaction-open")

CharacterWindow.mode = CharacterWindow.MODE_DYE_MERCHANT
eq(select(2, allowPair()), "interaction-open", "dye merchant mode blocks refine")

CharacterWindow = { mode = 3 }
eq(select(2, allowPair()), "interaction-open", "mode 3 blocks refine when the dye constant is absent")
CharacterWindow = { mode = 1 }
eq(select(2, allowPair()), "post-harvest", "mode 1 is not a dye merchant")
CharacterWindow = nil

-- Closing the dialog resumes refine.
resetWindows()
resetRefine()
Refine._refineDirty = false
Refine._refineDirtyReason = nil
local wakesBefore = wakes
pushOpen("EA_Window_InteractionQuest")
Buy.PollStorePresence()
eq(Buy._lastInteractionOpen, true, "the first poll records the open dialog")
eq(Refine._refineDirty, false, "opening does not mark refine due")
eq(wakes, wakesBefore, "the first open poll does not wake")
playerClose("EA_Window_InteractionQuest")
Buy.PollStorePresence()
eq(Refine._refineDirty, true, "closing the dialog marks refine due")
eq(Refine._refineDirtyReason, "interaction-closed", "the resume reason is interaction-closed")
eq(wakes, wakesBefore + 1, "closing the dialog wakes AutoGrow")
eq(Buy._lastInteractionOpen, false, "the poll records the dialog closed")
Buy.PollStorePresence()
eq(wakes, wakesBefore + 1, "a second closed poll does not wake again")

Bridge._skillLevelsHash = "0:0"
Bridge._skillsWereReady = true
Bridge._skillPrev = { cult = 0, apo = 0 }
Refine._refineDirty = false
Refine._refineDirtyReason = nil
pushOpen("BankWindow")
local wakesOpen = wakes
Bridge.OnInteractDone()
eq(Refine._refineDirty, false, "interact-done leaves refine idle while a service window is open")
eq(wakes, wakesOpen, "interact-done does not wake while a service window is open")
playerClose("BankWindow")
Bridge.OnInteractDone()
eq(Refine._refineDirtyReason, "interaction-closed", "interact-done resumes refine when nothing is open")
eq(wakes, wakesOpen + 1, "interact-done wakes AutoGrow when the dialog is gone")

setOpen(STORE, true)
Refine._refineDirty = false
Refine._refineDirtyReason = nil
local wakesStore = wakes
Bridge.OnInteractDone()
eq(Refine._refineDirty, false, "interact-done does not resume refine while the merchant is open")
eq(wakes, wakesStore, "interact-done does not wake while the merchant is open")
setOpen(STORE, false)

-- Delayed cultivation layout keeps pre-open windows, except ones the player closed.
resetWindows()
resetRefine()
local function trackClose(name)
    return function()
        closeCalls[name] = (closeCalls[name] or 0) + 1
        showing[name] = false
    end
end

pushOpen("EA_Window_InteractionQuest")
pushOpen("EA_Window_Backpack")
setOpen("EA_InteractionFlightMasterWindow", true)
setOpen("BankWindow", true)
WindowUtils.Cascade.List = {
    { name = "EA_Window_InteractionQuest", closeFunction = trackClose("EA_Window_InteractionQuest") },
    { name = "EA_InteractionFlightMasterWindow", closeFunction = trackClose("EA_InteractionFlightMasterWindow") },
    { name = "EA_Window_Backpack", closeFunction = trackClose("EA_Window_Backpack") },
    { name = "BankWindow", closeFunction = trackClose("BankWindow") },
    { name = "CultivationWindow", closeFunction = trackClose("CultivationWindow") },
}
pushOpen("CultivationWindow")

eq(CA.PlantSeed(1, 4, 3), true, "PlantSeed issues while NPC windows are open")
local keep = CA._keepOpenAfterPlant and CA._keepOpenAfterPlant.shown or {}
eq(keep["EA_Window_InteractionQuest"], true, "plant snapshots the quest window")
eq(keep["EA_InteractionFlightMasterWindow"], true, "plant snapshots the flight master")
eq(keep["EA_Window_Backpack"], true, "plant snapshots the backpack")
eq(keep["BankWindow"], true, "plant snapshots the bank")
eq(keep["CultivationWindow"], nil, "plant does not try to keep CultivationWindow")

playerClose("EA_Window_InteractionQuest")
WindowUtils.openWindowList[#WindowUtils.openWindowList + 1] = "CultivationWindow"
WindowUtils.Cascade.Resolve()

eq(showing["EA_Window_InteractionQuest"], false, "a quest closed before the show stays closed")
eq(closeCalls["EA_Window_InteractionQuest"], 1, "the closed quest is not protected from cascade")
eq(showing["EA_InteractionFlightMasterWindow"], true, "flight master stays open through cascade")
eq(closeCalls["EA_InteractionFlightMasterWindow"] or 0, 0, "flight master close is stubbed")
eq(showing["EA_Window_Backpack"], true, "backpack stays open through cascade")
eq(showing["BankWindow"], true, "bank stays open through cascade")
eq(keep["EA_Window_InteractionQuest"], nil, "the manual close is dropped from the keep set")

-- Back-to-back plant merges still-open windows and drops ones closed since.
playerClose("BankWindow")
pushOpen("MailWindow")
WindowUtils.Cascade.List[#WindowUtils.Cascade.List + 1] = {
    name = "MailWindow",
    closeFunction = trackClose("MailWindow"),
}
eq(CA.AddAdditive(1, 5, 3), true, "a second plant merges the keep set")
local merged = CA._keepOpenAfterPlant and CA._keepOpenAfterPlant.shown or {}
eq(merged["EA_InteractionFlightMasterWindow"], true, "a still-open flight master stays in the merge")
eq(merged["MailWindow"], true, "a newly opened mail window joins the merge")
eq(merged["BankWindow"], nil, "a bank closed between plants is not reopened")
eq(merged["EA_Window_InteractionQuest"], nil, "the closed quest is not merged back")
WindowUtils.Cascade.Resolve()
eq(showing["MailWindow"], true, "merged mail stays open")
eq(showing["BankWindow"], false, "the closed bank stays closed")
eq(showing["EA_InteractionFlightMasterWindow"], true, "merged flight master stays open")

if failures > 0 then
    io.stderr:write(string.format("%d/%d checks failed\n", failures, checks))
    os.exit(1)
end
print(string.format("npc_interaction_windows: %d checks passed", checks))
