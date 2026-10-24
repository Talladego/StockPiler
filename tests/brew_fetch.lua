-- Craft-bag lookup is one fetch per phase and frame. Inventory events stay dirty flags.
-- Run: lua5.1 tests/brew_fetch.lua

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

local fetches = 0
local reloads = 0
StockPiler = {
    FrameCounter = 1,
    Util = { ToNarrow = function(v) return tostring(v or "") end },
    BagAdapter = {
        FetchForce = function()
            fetches = fetches + 1
            return {
                { bagType = "craft", slots = {} },
            }
        end,
        IterateSlots = function() end,
    },
}
DataUtils = {
    ReloadItems = function()
        reloads = reloads + 1
    end,
    ReloadCraftingItems = function()
        reloads = reloads + 1
    end,
}
GameData = { Player = {} }

load_module("Source/Brew.lua")
local Brew = StockPiler.Brew
Brew._job = { phase = "load" }
local spec = { role = "main" }
Brew.FindCraftingBagItemBySpec(spec)
Brew.FindCraftingBagItemBySpec(spec)
eq(fetches, 1, "same phase and frame fetches the craft bag once")
StockPiler.FrameCounter = 2
Brew.FindCraftingBagItemBySpec(spec)
eq(fetches, 2, "the next frame fetches again")
Brew.InvalidateBagSnapshot()
Brew.FindCraftingBagItemBySpec(spec)
eq(fetches, 3, "a cleared snapshot fetches again")

load_module("Source/Core/EngineEventBridge.lua")
local Bridge = StockPiler.EngineEventBridge
Bridge.OnInventoryUpdated({ 1 })
Bridge.OnCraftingSlotUpdated({ 2 })
Bridge.OnCraftingInventoryUpdated()
eq(reloads, 0, "inventory events do not reload items")
eq(GameData.Player.itemsDirty, true, "main bag stays marked dirty")
eq(GameData.Player.craftingItemsDirty, true, "craft bag stays marked dirty")

if failures > 0 then
    io.stderr:write(string.format("%d/%d checks failed\n", failures, checks))
    os.exit(1)
end
print(string.format("brew_fetch: %d checks passed", checks))
