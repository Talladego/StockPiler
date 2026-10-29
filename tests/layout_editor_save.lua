-- Layout Editor save/exit with the Craft button registered.
-- Stock Yes and No run SaveExit/ResetExit before the prompt closes. Both call
-- LayoutEditor.End, which runs edit callbacks with no pcall. In 1.1.3 that
-- callback did tonumber(width, height) and threw "base out of range" at the
-- default 92x92, so DialogManager never reached ReleaseDialog. Cancel's
-- callback is nil, so it still closed. The raw Button methods stay unwrapped.
-- Run: lua5.1 tests/layout_editor_save.lua

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

local baseOk, baseErr = pcall(tonumber, 92, 92)
eq(baseOk, false, "height 92 is an illegal tonumber base")
check(
    string.find(tostring(baseErr), "base out of range", 1, true) ~= nil,
    "1.1.3 dimension read raised base out of range"
)

local WIN = "StockPilerCraftButton"
local settings = {}
local dims = { w = 92, h = 92 }
local winScale = 1
local uiScale = 1
local alive = {}
local logs = {}
local registeredResize = nil
local registeredMove = nil

function d(text)
    logs[#logs + 1] = tostring(text)
end

function DoesWindowExist(name)
    return alive[name] == true
end

function CreateWindow(name)
    alive[name] = true
end

function WindowGetShowing()
    return false
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
        dims.w = w
        dims.h = h
    end
end

function WindowSetScale(name, scale)
    if name == WIN then
        winScale = scale
    end
end

InterfaceCore = {
    GetScale = function()
        return uiScale
    end,
}

-- Enough of the stock editor to register the button and run save/exit.
LayoutEditor = {
    windowsList = {},
    EventHandlers = {},
    EDITING_BEGIN = 1,
    EDITING_END = 2,
    isActive = false,
    Settings = {},
}

function LayoutEditor.RegisterWindow(name, _, _, _, _, _, hiddenCb, _, _, _, resizeCb, moveCb)
    eq(hiddenCb, nil, "the craft button does not register a hide callback")
    registeredResize = resizeCb
    registeredMove = moveCb
    LayoutEditor.windowsList[name] = { windowName = name }
end

function LayoutEditor.RegisterEditCallback(fn)
    table.insert(LayoutEditor.EventHandlers, fn)
end

function LayoutEditor.UnregisterWindow(name)
    LayoutEditor.windowsList[name] = nil
end

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
Button.Initialize()

check(type(registeredResize) == "function", "resize end is registered")
check(type(registeredMove) == "function", "move end is registered")
eq(#LayoutEditor.EventHandlers, 1, "one edit callback is registered")

local committed = { w = 92, h = 92, ui = 1, scale = 1 }
local dialogReleased = false
local settingsFlushes = 0

local function applySize(w, h, ui, scale)
    dims.w = w
    dims.h = h
    uiScale = ui
    winScale = scale
end

-- LayoutEditor.End sets isActive false, then calls edit callbacks with no pcall.
local function endEditing()
    LayoutEditor.isActive = false
    for _, fn in pairs(LayoutEditor.EventHandlers) do
        fn(LayoutEditor.EDITING_END)
    end
end

-- SaveExit keeps the edited size, then End, then ModulesSaveSettings.
local function saveExit()
    endEditing()
    settingsFlushes = settingsFlushes + 1
end

-- ResetExit restores the size from when editing began, then End. No disk flush.
local function resetExit()
    applySize(committed.w, committed.h, committed.ui, committed.scale)
    endEditing()
end

-- DialogManager runs the button callback, then ReleaseDialog.
-- A throw skips ReleaseDialog. Cancel's callback is nil.
local function pressDialog(button)
    local cb = nil
    if button == 1 then
        cb = saveExit
    elseif button == 2 then
        cb = resetExit
    end
    if cb ~= nil then
        cb()
    end
    dialogReleased = true
end

local function press(button)
    dialogReleased = false
    local ok, err = pcall(pressDialog, button)
    return ok, err, dialogReleased
end

local function editorSize(w, h, ui, scale)
    committed.w = w
    committed.h = h
    committed.ui = ui
    committed.scale = scale
    applySize(w, h, ui, scale)
end

local okBegin, errBegin = pcall(function()
    LayoutEditor.EventHandlers[1](LayoutEditor.EDITING_BEGIN)
end)
check(okBegin, "editing begin does not throw: " .. tostring(errBegin))
eq(settings.craftButtonScale, nil, "editing begin does not write a scale")

editorSize(92, 92, 1, 1)
local okResize, errResize = pcall(registeredResize)
check(okResize, "registered resize at 92x92 does not throw: " .. tostring(errResize))
eq(settings.craftButtonScale, 1, "a 92x92 resize saves scale 1")

-- The resize callback squares the window. Put the editor size back, then save.
editorSize(92, 92, 1, 1)
local ok, err, released = press(1)
check(ok, "Yes at 92x92 does not throw: " .. tostring(err))
check(released, "Yes at 92x92 closes the prompt")
eq(settingsFlushes, 1, "Yes reaches the settings flush")
eq(settings.craftButtonScale, 1, "Yes at 92x92 saves scale 1")

editorSize(138, 92, 1.25, 1.25)
okResize, errResize = pcall(registeredResize)
check(okResize, "registered resize at 138x92 does not throw: " .. tostring(errResize))
eq(settings.craftButtonScale, 1.5, "a resized button saves the width-based scale")

editorSize(138, 92, 1.25, 1.25)
ok, err, released = press(1)
check(ok, "Yes at the resized size does not throw: " .. tostring(err))
check(released, "Yes at the resized size closes the prompt")
eq(settingsFlushes, 2, "a second Yes still flushes settings")
eq(settings.craftButtonScale, 1.5, "Yes at the resized size saves scale 1.5")

-- Height 16 is a legal tonumber base. The 1.1.3 call would read width in base 16.
editorSize(138, 16, 1, 1)
ok, err, released = press(1)
check(ok, "Yes at 138x16 does not throw: " .. tostring(err))
check(released, "Yes at 138x16 closes the prompt")
eq(settings.craftButtonScale, 1.5, "save uses width, not height as a tonumber base")

applySize(184, 92, 1, 1)
ok, err, released = press(3)
check(ok, "Cancel does not throw: " .. tostring(err))
check(released, "Cancel closes the prompt")
eq(settings.craftButtonScale, 1.5, "Cancel does not write the unsaved size")
eq(settingsFlushes, 3, "Cancel does not flush settings")

local seen = nil
local realEnd = Button.OnLayoutEditingEnd
Button.OnLayoutEditingEnd = function()
    seen = { w = dims.w, h = dims.h, ui = uiScale, scale = winScale }
    return realEnd()
end
applySize(184, 92, 1, 1)
ok, err, released = press(2)
Button.OnLayoutEditingEnd = realEnd
check(ok, "No does not throw: " .. tostring(err))
check(released, "No closes the prompt")
eq(seen and seen.w, 138, "No restores the committed width before the callback")
eq(seen and seen.h, 16, "No restores the committed height before the callback")
eq(seen and seen.ui, 1, "No restores the committed interface scale")
eq(seen and seen.scale, 1, "No restores the committed window scale")
eq(settings.craftButtonScale, 1.5, "No saves the restored size, not the discarded one")
eq(settingsFlushes, 3, "No does not flush settings")

-- The raw method still raises. The registered callback must not abort the prompt.
local realEnd = Button.OnLayoutEditingEnd
Button.OnLayoutEditingEnd = function()
    error("layout save blew up")
end
local rawOk, rawErr = pcall(Button.OnLayoutEditingEnd)
eq(rawOk, false, "a raw layout callback still raises in tests")
check(
    string.find(tostring(rawErr), "layout save blew up", 1, true) ~= nil,
    "the raw error text is visible to tests"
)

applySize(184, 92, 1, 1)
ok, err, released = press(1)
check(ok, "Yes still returns when our callback errors: " .. tostring(err))
check(released, "Yes still closes the prompt when our callback errors")
eq(settingsFlushes, 4, "the settings flush still runs when our callback errors")
eq(settings.craftButtonScale, 1.5, "a thrown callback does not write a new scale")
eq(#logs, 1, "the layout callback error is logged once")
check(
    string.find(logs[1], "CraftButton.OnLayoutEditingEnd", 1, true) ~= nil,
    "the log names the edit callback"
)
check(
    string.find(logs[1], "layout save blew up", 1, true) ~= nil,
    "the log includes the error"
)

ok, err, released = press(1)
check(ok, "a second Yes still returns: " .. tostring(err))
check(released, "a second Yes still closes the prompt")
eq(#logs, 1, "a repeated layout callback error is not logged again")

Button.OnLayoutEditingEnd = realEnd
applySize(92, 92, 1, 1)
ok, err, released = press(1)
check(ok, "Yes works again after the callback is restored: " .. tostring(err))
check(released, "the restored callback still closes the prompt")
eq(settings.craftButtonScale, 1, "the restored callback saves scale 1")

LayoutEditor.isActive = true
local okMove, errMove = pcall(registeredMove)
check(okMove, "move end during editing does not throw: " .. tostring(errMove))
LayoutEditor.isActive = false

if failures > 0 then
    io.stderr:write(string.format("%d/%d checks failed\n", failures, checks))
    os.exit(1)
end
print(string.format("layout_editor_save: %d checks passed", checks))
