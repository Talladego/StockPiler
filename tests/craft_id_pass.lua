-- Appearance, align, and reapply resolve the Craft macro once per pass.
-- Run: lua5.1 tests/craft_id_pass.lua

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

function towstring(s)
    return tostring(s)
end
function WStringToString(s)
    return tostring(s)
end
function DoesWindowExist()
    return true
end
function WindowSetGameActionData()
end
function ButtonSetDisabledFlag()
end
function ButtonSetTextColor()
end
function DynamicImageSetTexture()
end

StockPiler = { Util = {
    T = function(key) return tostring(key) end,
    TryCall = function(_, fn, ...) return pcall(fn, ...) end,
} }
StockPiler.Settings = { craftMacroEnabled = true }
StockPiler.FrameCounter = 1
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

local bar = { m_Buttons = {} }
for i = 1, 72 do
    bar.m_Buttons[i] = {
        m_Name = "B" .. i,
        m_HotBarSlot = i,
        m_ActionType = 12,
        m_ActionId = (i <= 2) and 3 or (100 + i),
        m_Windows = {},
        GetName = function() return "B" .. i end,
    }
end
ActionBars = { m_Bars = { bar } }

local hookCalls = 0
ActionButton = {
    UpdateEnabledState = function(self)
        hookCalls = hookCalls + 1
        if StockPiler.Macro and StockPiler.Macro.IsCraftMacroButton then
            StockPiler.Macro.IsCraftMacroButton(self)
        end
    end,
    SetActionData = function() end,
    UpdateIcon = function() end,
    OnLButtonUp = function() end,
}

load_module("Source/Macro/Macro.lua")
local Macro = StockPiler.Macro
Macro.CraftMacroId = 3

local function passReads(fn)
    reads = 0
    hookCalls = 0
    fn()
    return reads
end

Macro._lastAppearanceKey = nil
Macro._alignCraftFrame = nil
Macro._alignCraftKey = nil
local n = passReads(function()
    Macro.RefreshMacroButtonAppearance({ canHarvest = false, canBrew = false })
end)
check(n >= 1 and n <= 8, "appearance pass reads macros a few times, got " .. tostring(n))

StockPiler.FrameCounter = 2
Macro._alignCraftFrame = nil
Macro._alignCraftKey = nil
n = passReads(function()
    Macro.AlignCraftEnable(false, false)
end)
check(n >= 1 and n <= 8, "align pass reads macros a few times, got " .. tostring(n))

n = passReads(function()
    Macro.ReapplyCraftEnable()
end)
check(n >= 1 and n <= 3, "reapply pass reads macros a few times, got " .. tostring(n))

if failures > 0 then
    io.stderr:write(string.format("%d/%d checks failed\n", failures, checks))
    os.exit(1)
end
print(string.format("craft_id_pass: %d checks passed", checks))
