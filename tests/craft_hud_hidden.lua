-- Hidden Craft HUD skips readiness and plot work. Showing it paints immediately.
-- Run: lua5.1 tests/craft_hud_hidden.lua

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

local showing = {}
function DoesWindowExist()
    return true
end
function WindowGetShowing(name)
    return showing[name] == true
end
function WindowSetShowing(name, on)
    showing[name] = on == true
end

local reads = { mode = 0, ready = 0, short = 0, stay = 0 }
local paints = 0
local align = 0
local craftId = 0
local owned = false
local prevInv = 0
local prevCd = 0

StockPiler = {
    Util = { ToNarrow = function(v) return tostring(v or "") end },
    Persistence = { EnsureSettings = function() return { craftButtonVisible = true } end },
    Macro = {
        GetCraftMacroId = function() return craftId end,
        IsCraftMacroButton = function(button) return owned and button._craft == true end,
        ResolveCraftMode = function()
            reads.mode = reads.mode + 1
            return { iconMode = "harvest", craftCanUse = false, mode = "idle" }
        end,
        AlignCraftEnable = function()
            align = align + 1
        end,
    },
}

load_module("Source/View/CraftButton.lua")
load_module("Source/Macro/CraftHarvestTimer.lua")

local Button = StockPiler.CraftButton
local Timer = StockPiler.CraftHarvestTimer
Timer.HasHarvestReady = function()
    reads.ready = reads.ready + 1
    return false
end
Timer.ShortestSeconds = function()
    reads.short = reads.short + 1
    return nil
end
Timer.NeedsUserStay = function()
    reads.stay = reads.stay + 1
    return false
end
Timer.Paint = function()
    paints = paints + 1
end

local function readsTotal()
    return reads.mode + reads.ready + reads.short + reads.stay
end

showing["StockPilerCraftButton"] = false
craftId = 0
owned = false
ActionBars = nil

Button.TickGrowVisuals()
Button.SyncAppearance()
Timer.Refresh()
eq(readsTotal(), 0, "hidden HUD with no Craft copy does no readiness work")
eq(paints, 0, "hidden HUD does not paint a hotbar button")

craftId = 77
ActionBars = { m_Bars = { { m_Buttons = { { _craft = false } } } } }
Timer.Refresh()
eq(readsTotal(), 0, "timer refresh with no visible Craft copy skips plot reads")
eq(paints, 0, "unrelated hotbar buttons are not painted")

owned = true
ActionBars = { m_Bars = { { m_Buttons = { { _craft = true } } } } }
local paintsBefore = paints
local readyBefore = reads.ready
Timer._acc = 0
Timer.OnUpdate(0.4)
Timer.OnUpdate(0.4)
eq(paints, paintsBefore, "visible Craft button waits a full second between refreshes")
Timer.OnUpdate(0.3)
check(paints > paintsBefore, "visible Craft button refreshes on the one-second timer")
check(reads.ready > readyBefore, "a visible Craft button still reads harvest readiness")

ActionButton = {
    UpdateInventory = function()
        prevInv = prevInv + 1
    end,
    UpdateCooldownAnimation = function()
        prevCd = prevCd + 1
    end,
}
Timer.Install()
ActionButton.UpdateInventory({ _craft = true })
ActionButton.UpdateCooldownAnimation({ _craft = false })
eq(prevInv, 1, "native inventory refresh still runs")
eq(prevCd, 1, "native cooldown refresh still runs")

local beforeShow = readsTotal()
showing["StockPilerCraftButton"] = false
Button.ApplyVisibility()
check(readsTotal() > beforeShow, "showing the HUD paints readiness immediately")
check(reads.mode > 0, "show path resolves the current craft mode")
check(reads.ready > readyBefore, "show path reads harvest readiness")
eq(showing["StockPilerCraftButton"], true, "show path leaves the HUD showing")

if failures > 0 then
    io.stderr:write(string.format("%d/%d checks failed\n", failures, checks))
    os.exit(1)
end
print(string.format("craft_hud_hidden: %d checks passed", checks))
