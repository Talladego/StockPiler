-- Lua 5.1 harness for Craft macro removal, hotbar id caching, and cooldown hooks.
-- Run from the repo root: lua5.1 tests/craft_macro.lua

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

StockPiler = { Util = {
    T = function(key)
        return tostring(key)
    end,
    TryCall = function(_, fn, ...)
        return pcall(fn, ...)
    end,
} }
StockPiler.Settings = { craftMacroEnabled = true }
GameData = { PlayerActions = { DO_MACRO = 12 } }

local macros = {}
for i = 1, 48 do
    macros[i] = { name = "", text = "", iconNum = 0 }
end
macros[3] = {
    name = "StockPiler Craft",
    text = "/script StockPiler.Macro.CraftClick()",
    iconNum = 2486,
}
local reads = 0
function GetMacrosData()
    reads = reads + 1
    local copy = {}
    for i = 1, 48 do
        copy[i] = {
            name = macros[i].name,
            text = macros[i].text,
            iconNum = macros[i].iconNum,
        }
    end
    return copy
end
local setMacroCalls, hotbarClears = {}, {}
function SetMacroData(name, text, icon, slot)
    setMacroCalls[#setMacroCalls + 1] = slot
    macros[slot] = { name = name, text = text, iconNum = icon }
end
function SetHotbarData(slot, _, _)
    hotbarClears[#hotbarClears + 1] = slot
end
function DoesWindowExist()
    return true
end
function WindowSetGameActionData()
end
function ButtonSetDisabledFlag()
end

local bar = { m_Buttons = {} }
for i = 1, 72 do
    bar.m_Buttons[i] = {
        m_Name = "B" .. i,
        m_HotBarSlot = i,
        m_ActionType = 12,
        m_ActionId = (i <= 2) and 3 or 40 + (i % 5),
        m_Windows = {},
        GetName = function()
            return "B" .. i
        end,
    }
end
ActionBars = { m_Bars = { bar } }

load_module("Source/Macro/Macro.lua")
local Macro = StockPiler.Macro

local function restoreCraft()
    macros[3] = {
        name = "StockPiler Craft",
        text = "/script StockPiler.Macro.CraftClick()",
        iconNum = 2486,
    }
    StockPiler.Settings.craftMacroEnabled = true
    Macro.CraftMacroId = 3
end

eq(Macro.GetCraftMacroId(), 3, "craft macro id is slot 3")
hotbarClears = {}
setMacroCalls = {}
local ok, err = pcall(Macro.RemoveCraftMacro)
check(ok == true, "RemoveCraftMacro does not throw: " .. tostring(err))
eq(tonumber(Macro.CraftMacroId) or 0, 0, "RemoveCraftMacro clears the cached id")
eq(macros[3].text, "", "RemoveCraftMacro wipes the macro text")
check(hotbarClears[1] == 1 and hotbarClears[2] == 2, "RemoveCraftMacro clears the placed slots")
eq(setMacroCalls[#setMacroCalls], 3, "RemoveCraftMacro writes the macro slot")
eq(Macro.CraftMacroWarningState.missing, false, "RemoveCraftMacro clears the missing warning")
eq(Macro.CraftMacroWarningState.full, false, "RemoveCraftMacro clears the full warning")
eq(Macro._craftIconApplied, nil, "RemoveCraftMacro clears the icon latch")

restoreCraft()
ok, err = pcall(Macro.SetCraftMacroEnabled, false)
check(ok == true, "SetCraftMacroEnabled(false) does not throw: " .. tostring(err))
eq(StockPiler.Settings.craftMacroEnabled, false, "Craft macro setting is off")
eq(tonumber(Macro.CraftMacroId) or 0, 0, "disabling Craft macro clears the cached id")
eq(macros[3].name, "", "disabling Craft macro deletes the macro")

ok, err = pcall(Macro.SetCraftMacroEnabled, true)
check(ok == true, "SetCraftMacroEnabled(true) does not throw: " .. tostring(err))
eq(StockPiler.Settings.craftMacroEnabled, true, "Craft macro setting is on again")
check(tonumber(Macro.GetCraftMacroId()) ~= nil and Macro.GetCraftMacroId() > 0,
    "turning Craft macro back on creates it")
ok, err = pcall(Macro.SetCraftMacroEnabled, false)
check(ok == true, "turning Craft macro off again does not throw: " .. tostring(err))
eq(tonumber(Macro.CraftMacroId) or 0, 0, "second disable clears the cached id")

restoreCraft()
Macro.CraftMacroId = 0
Macro._lastAppearanceKey = nil
reads = 0
Macro.RefreshMacroButtonAppearance({ canHarvest = false, canBrew = false })
check(reads > 0 and reads <= 12, "first refresh reads the macro table a bounded number of times, got " .. tostring(reads))
Macro._alignCraftFrame = nil
Macro._alignCraftKey = nil
reads = 0
Macro.RefreshMacroButtonAppearance({ canHarvest = false, canBrew = false })
check(reads > 0 and reads <= 8, "steady refresh reads the macro table a bounded number of times, got " .. tostring(reads))
reads = 0
Macro._alignCraftFrame = nil
Macro.ReapplyCraftEnable()
check(reads > 0 and reads <= 4, "ReapplyCraftEnable reads the macro table a bounded number of times, got " .. tostring(reads))

-- A rewritten slot must not keep the cached id.
macros[3].name = "Assist"
macros[3].text = "/assist"
eq(Macro.GetCraftMacroId(), nil, "a rewritten slot is not the Craft macro")
eq(Macro.IsCraftMacroButton(bar.m_Buttons[1]), false, "a rewritten slot fails ownership")

local function testTimerOwnershipAndWrappers()
    local owned, calls = true, 0
    local function stockCd()
        calls = calls + 1
        return "cd"
    end
    local stockInvCalls = 0
    local function stockInv()
        stockInvCalls = stockInvCalls + 1
        return "inv"
    end
    GameData.PlayerActions.DO_MACRO = 1
    ActionButton = {
        UpdateInventory = stockInv,
        UpdateCooldownAnimation = stockCd,
    }
    StockPiler.Macro = {
        CraftMacroId = 1,
        GetCraftMacroId = function()
            if owned then
                return 1
            end
            return nil
        end,
    }
    load_module("Source/Macro/CraftHarvestTimer.lua")
    local timer = StockPiler.CraftHarvestTimer
    timer._hooked = false
    timer._cdHooked = false
    timer.Install()
    timer._cdArmed = true
    timer._cdRemain = 10
    owned = false
    local result = ActionButton.UpdateCooldownAnimation(
        { m_ActionType = 1, m_ActionId = 1, m_Windows = {} },
        0.1,
        true
    )
    eq(calls, 1, "reused macro slot does not suppress the native cooldown")
    eq(result, "cd", "native cooldown return value is preserved")

    local captured = ActionButton.UpdateCooldownAnimation
    local laterCalls = 0
    local function later(...)
        laterCalls = laterCalls + 1
        return captured(...)
    end
    ActionButton.UpdateCooldownAnimation = later
    timer.Shutdown()
    eq(ActionButton.UpdateCooldownAnimation, later, "shutdown leaves a later cooldown wrapper")
    calls = 0
    laterCalls = 0
    ActionButton.UpdateCooldownAnimation({ m_ActionType = 1, m_ActionId = 1 }, 0.1, true)
    eq(laterCalls, 1, "later cooldown wrapper still runs")
    eq(calls, 1, "later cooldown wrapper forwards to stock after shutdown")

    calls = 0
    laterCalls = 0
    owned = true
    timer.Install()
    check(ActionButton.UpdateCooldownAnimation ~= later, "re-init wraps the later cooldown handler")
    owned = false
    ActionButton.UpdateCooldownAnimation("not-a-button", 0, false)
    eq(laterCalls, 1, "re-init cooldown hook calls the later wrapper")
    eq(calls, 1, "re-init cooldown hook still reaches stock")
    timer.Shutdown()
    eq(ActionButton.UpdateCooldownAnimation, later, "second cooldown shutdown restores the later wrapper")

    calls = 0
    local otherCalls = 0
    local function other(...)
        otherCalls = otherCalls + 1
        return stockCd(...)
    end
    ActionButton.UpdateCooldownAnimation = other
    ActionButton.UpdateInventory = stockInv
    timer._hooked = false
    timer._cdHooked = false
    timer.Install()
    owned = true
    timer._cdArmed = true
    timer._cdRemain = 10
    calls = 0
    otherCalls = 0
    ActionButton.UpdateCooldownAnimation(
        { m_ActionType = 1, m_ActionId = 1, m_Windows = {} },
        0.1,
        true
    )
    eq(calls, 0, "owned craft slot still suppresses the native cooldown")
    eq(otherCalls, 0, "owned craft slot does not call the earlier addon")
    owned = false
    ActionButton.UpdateCooldownAnimation(
        { m_ActionType = 1, m_ActionId = 1, m_Windows = {} },
        0.1,
        true
    )
    eq(otherCalls, 1, "unowned slot forwards to the earlier cooldown addon")
    eq(calls, 1, "earlier cooldown addon reaches stock")
    timer.Shutdown()
    eq(ActionButton.UpdateCooldownAnimation, other, "shutdown restores the earlier cooldown addon")

    ActionButton.UpdateInventory = stockInv
    ActionButton.UpdateCooldownAnimation = stockCd
    timer._hooked = false
    timer._cdHooked = false
    timer.Install()
    local capturedInv = ActionButton.UpdateInventory
    local function laterInv(...)
        return capturedInv(...)
    end
    ActionButton.UpdateInventory = laterInv
    timer.Shutdown()
    eq(ActionButton.UpdateInventory, laterInv, "shutdown leaves a later inventory wrapper")
    stockInvCalls = 0
    local invResult = ActionButton.UpdateInventory({ m_ActionType = 1, m_ActionId = 1 })
    eq(stockInvCalls, 1, "later inventory wrapper forwards after shutdown")
    eq(invResult, "inv", "inventory return value survives shutdown")
end

testTimerOwnershipAndWrappers()

if failures > 0 then
    io.stderr:write(string.format("%d/%d checks failed\n", failures, checks))
    os.exit(1)
end
print(string.format("craft_macro: %d checks passed", checks))
