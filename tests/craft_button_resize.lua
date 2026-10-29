-- Layout Editor resize must read width only. Height is not a tonumber base.
-- Run: lua5.1 tests/craft_button_resize.lua

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

local WIN = "StockPilerCraftButton"
local settings = {}
local dims = { w = 92, h = 92 }
local winScale = 1
local uiScale = 1
local setDims = nil
local setScale = nil

function DoesWindowExist(name)
    return name == WIN
end

function WindowGetDimensions(name)
    if name == WIN then
        return dims.w, dims.h
    end
    return 0, 0
end

function WindowGetScale(name)
    if name == WIN then
        return winScale
    end
    return 1
end

function WindowSetDimensions(name, w, h)
    if name == WIN then
        setDims = { w = w, h = h }
    end
end

function WindowSetScale(name, scale)
    if name == WIN then
        setScale = scale
    end
end

InterfaceCore = {
    GetScale = function()
        return uiScale
    end,
}

StockPiler = {
    Util = { ToNarrow = function(v) return tostring(v or "") end },
    Persistence = {
        EnsureSettings = function()
            return settings
        end,
    },
}

load_module("Source/View/CraftButton.lua")
local Button = StockPiler.CraftButton

local function resize(w, h, ui, scale, fn)
    dims.w = w
    dims.h = h
    uiScale = ui
    winScale = scale
    setDims = nil
    setScale = nil
    settings.craftButtonScale = nil
    local ok, err = pcall(fn)
    return ok, err
end

local ok, err = resize(92, 92, 1, 1, Button.OnLayoutResizeEnd)
check(ok, "square resize does not throw: " .. tostring(err))
eq(settings.craftButtonScale, 1, "a 92x92 button saves scale 1")
eq(setDims and setDims.w, 92, "resize restores width")
eq(setDims and setDims.h, 92, "resize restores height")
eq(setScale, 1, "square resize keeps window scale at the interface scale")

-- Edge drag: width changes, height stays 92. Height 92 used to be tonumber's base.
ok, err = resize(138, 92, 1.25, 1.25, Button.OnLayoutResizeEnd)
check(ok, "edge resize does not throw: " .. tostring(err))
eq(settings.craftButtonScale, 1.5, "edge resize saves the width-based scale")
eq(setDims and setDims.w, 92, "edge resize restores a square width")
eq(setDims and setDims.h, 92, "edge resize restores a square height")
eq(setScale, 1.5 * 1.25, "edge resize writes scale times the interface scale")

-- Corner drag writes an absolute window scale and leaves the 92x92 frame.
ok, err = resize(92, 92, 1.25, 2, Button.OnLayoutResizeEnd)
check(ok, "corner resize does not throw: " .. tostring(err))
eq(settings.craftButtonScale, 1.6, "corner resize divides out the interface scale")
eq(setScale, 2, "corner resize keeps the absolute window scale")

-- Height 16 is a legal tonumber base. The old call would read 138 as base 16.
ok, err = resize(138, 16, 1, 1, Button.OnLayoutResizeEnd)
check(ok, "non-square resize does not throw: " .. tostring(err))
eq(settings.craftButtonScale, 1.5, "height is not used as tonumber base")

ok, err = resize(138, 92, 1.25, 1.25, Button.OnLayoutEditingEnd)
check(ok, "editor close does not throw: " .. tostring(err))
eq(settings.craftButtonScale, 1.5, "editor close saves the same width-based scale")

if failures > 0 then
    io.stderr:write(string.format("%d/%d checks failed\n", failures, checks))
    os.exit(1)
end
print(string.format("craft_button_resize: %d checks passed", checks))
