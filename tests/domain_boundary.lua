-- Views do not own recipe storage, and tooltip shutdown restores stock clear.
-- Run: lua5.1 tests/domain_boundary.lua

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

local recipes = {}
local registered = 0
StockPiler = {
    Util = { T = function(k) return tostring(k) end },
    Knowledge = { Recipes = function() return recipes end },
    RecipeSpec = {},
}
local RS = StockPiler.RecipeSpec
function RS.RecipeSpecKey(slots)
    return "rk:" .. tostring(slots[1].uid)
end
function RS.RegisterKnownPotion()
    registered = registered + 1
end
function RS.SlimRecipeForStorage()
end

load_module("Source/Knowledge/RecipeSpec.lua")
StockPiler.Knowledge.Recipes = function()
    return recipes
end
StockPiler.RecipeSpec.RecipeSpecKey = function(slots)
    return "rk:" .. tostring(slots[1].uid)
end
StockPiler.RecipeSpec.RegisterKnownPotion = function()
    registered = registered + 1
end
StockPiler.RecipeSpec.SlimRecipeForStorage = function() end

local result = StockPiler.RecipeSpec.ImportSharedRecipe(9, {
    { uid = 3, role = "main" },
    { uid = 4, role = "container" },
}, { out = { uniqueID = 9, name = "Heal" }, quality = "good" })
eq(result, "imported", "shared import stores a recipe")
eq(type(recipes["rk:3"]), "table", "the recipe row lives in knowledge")
eq(recipes["rk:3"].sharedImport, true, "the row is marked as a shared import")
eq(registered, 1, "import registers the potion")
eq(StockPiler.RecipeSpec.ImportSharedRecipe(0, {}, {}), "failed", "a bad import fails")

local stockClear = function() end
Tooltips = {
    NUM_ROWS = 17,
    ANCHOR_WINDOW_RIGHT = 1,
    ClearTooltip = stockClear,
    CreateTextOnlyTooltip = function() end,
    SetTooltipText = function() end,
    Finalize = function() end,
    AnchorTooltip = function() end,
}
load_module("Source/View/RecipeTooltip.lua")
StockPiler.RecipeTooltip.ShowColoredRows("anchor", {
    { text = "one", kind = "body" },
}, nil, 40)
eq(Tooltips.ClearTooltip ~= stockClear, true, "recipe tips wrap clear")
StockPiler.RecipeTooltip.Shutdown()
eq(Tooltips.ClearTooltip, stockClear, "shutdown restores clear")
eq(Tooltips.NUM_ROWS, 17, "shutdown restores the stock row count")

local pending = false
StockPiler.Inventory = StockPiler.Inventory or {}
load_module("Source/Stores/InventoryStore.lua")
StockPiler.Inventory._snapPending = true
eq(StockPiler.Inventory.IsSnapshotPending(), true, "pending snapshot is visible")
StockPiler.Inventory._snapPending = false
eq(StockPiler.Inventory.IsSnapshotPending(), false, "a settled snapshot is not pending")

if failures > 0 then
    io.stderr:write(string.format("%d/%d checks failed\n", failures, checks))
    os.exit(1)
end
print(string.format("domain_boundary: %d checks passed", checks))
