-- Lua 5.1 harness for the recipe preview, Learn, and Shift+left-click.
-- Run from the repo root: lua5.1 tests/recipe_share.lua

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

GameData = {
    CultivationTypes = { NONE = 0, SEED = 1, SPORE = 5 },
    ItemTypes = { CRAFTING = 34, POTION = 31 },
    TradeSkills = { APOTHECARY = 4, CULTIVATION = 7 },
}

function GetGameTime()
    return 10000
end

StockPiler = {}
StockPiler.Persistence = {}
StockPiler.Account = {
    items = {},
    grows = {},
    refines = {},
    recipes = {},
    potions = {},
    skillUpRates = {},
}
StockPiler.Settings = { characters = {} }
StockPiler.T = function(key, tokens)
    local s = tostring(key)
    if type(tokens) == "table" then
        for k, v in pairs(tokens) do
            s = s .. "{" .. tostring(k) .. "=" .. tostring(v) .. "}"
        end
    end
    return s
end

load_module("Source/Core/Util.lua")
load_module("Source/Stores/KnowledgeStore.lua")
load_module("Source/Knowledge/MaterialSpec.lua")
load_module("Source/Knowledge/MaterialExceptions.lua")
load_module("Source/Knowledge/Items.lua")
load_module("Source/Knowledge/RecipeSpec.lua")
load_module("Source/View/RecipeLink.lua")
load_module("Source/View/RecipeShare.lua")

local RL = StockPiler.RecipeLink
local Share = StockPiler.RecipeShare
local recipes = StockPiler.Account.recipes
local potions = StockPiler.Account.potions

local labels = {}
local disabled = {}
local shown = {}
local openList = {}
local tips = {}

function LabelSetText(win, text)
    labels[win] = tostring(text)
end
function ButtonSetText(win, text)
    labels[win] = tostring(text)
end
function ButtonSetDisabledFlag(win, flag)
    disabled[win] = flag == true
end
function WindowSetShowing(win, flag)
    shown[win] = flag == true
end
local iconTextures = {}
local iconScales = {}
local iconDataCalls = 0
function GetIconData(icon)
    iconDataCalls = iconDataCalls + 1
    return "tex-share", 3, 4
end
function DynamicImageSetTexture(win, texture, x, y)
    iconTextures[#iconTextures + 1] = {
        win = win,
        texture = texture,
        x = x,
        y = y,
    }
end
function DynamicImageSetTextureScale(win, scale)
    iconScales[#iconScales + 1] = { win = win, scale = scale }
end
WindowUtils = {
    Cascade = { MODE_AUTOMATIC = "auto" },
    AddToOpenList = function(name, fn)
        openList[name] = fn
    end,
    RemoveFromOpenList = function(name)
        openList[name] = nil
    end,
}
Tooltips = {
    ANCHOR_WINDOW_RIGHT = 1,
    CreateTextOnlyTooltip = function(win, text)
        tips[win] = tostring(text)
    end,
    AnchorTooltip = function() end,
    ClearTooltip = function() end,
}
SystemData = SystemData or {}
SystemData.ButtonFlags = { SHIFT = 4 }
bit = {
    band = function(a, b)
        local result = 0
        local bitv = 1
        a = tonumber(a) or 0
        b = tonumber(b) or 0
        while a > 0 or b > 0 do
            if a % 2 == 1 and b % 2 == 1 then
                result = result + bitv
            end
            a = math.floor(a / 2)
            b = math.floor(b / 2)
            bitv = bitv * 2
        end
        return result
    end,
}
SystemData.ActiveWindow = { name = "StockPilerRecipeShareWindowIngredient1" }

local function slot(role, uid, power, bonuses)
    return {
        role = role,
        uid = uid,
        perCraft = 2,
        spec = {
            uid = uid,
            role = role,
            name = role .. " Herb",
            iconNum = 4000 + uid,
            power = power,
            stability = 3,
            duration = 0,
            tradeSkill = 4,
            skillLevel = 20,
            cultivationType = 0,
            slotType = 1,
            effectId = 77,
            bonuses = bonuses or { [1] = 0, [4] = 2, [12] = 5, [14] = 1 },
        },
    }
end

local function sampleSlots()
    return {
        slot("main", 1001, 10),
        slot("container", 2002, 0),
    }
end

local function wipe()
    for k in pairs(recipes) do
        recipes[k] = nil
    end
    for k in pairs(potions) do
        potions[k] = nil
    end
    for k in pairs(labels) do
        labels[k] = nil
    end
    for k in pairs(disabled) do
        disabled[k] = nil
    end
    for k in pairs(shown) do
        shown[k] = nil
    end
    for k in pairs(openList) do
        openList[k] = nil
    end
end

local WIN = "StockPilerRecipeShareWindow"

local function fieldsFor(uid, name, slots)
    return {
        uid = uid,
        name = name,
        icon = 55,
        slots = slots,
    }
end

wipe()
local slots = sampleSlots()
local plain = RL.SerializePlain(fieldsFor(9001, "Preview Potion", slots))
check(string.find(plain, "^", 1, true) == nil, "preview payload has no caret")
check(string.find(plain, "d=", 1, true) ~= nil, "preview payload carries names")
eq(Share.ShowFromPlain(plain), true, "plain link opens the preview")
eq(shown[WIN], true, "preview window is shown")
eq(labels[WIN .. "Status"], "share.status_new", "new link says Not learned")
eq(labels[WIN .. "TitleText"], "share.title", "preview title")
eq(labels[WIN .. "Learn"], "share.learn", "learn button text")
eq(labels[WIN .. "Cancel"], "share.cancel", "cancel button text")
eq(disabled[WIN .. "Learn"], false, "learn is enabled for a new recipe")
check(type(openList[WIN]) == "function", "escape is registered")
check(string.find(labels[WIN .. "Ingredient1"] or "", "Herb", 1, true) ~= nil, "ingredient name is shown")
check(string.find(labels[WIN .. "Ingredient1"] or "", "2", 1, true) ~= nil, "ingredient quantity is shown")
local described = Share._rows[1]
check(type(described) == "table", "preview row stored")
check(string.find(tostring(described.tip), "material.bonus.stability", 1, true) ~= nil
    or string.find(tostring(described.tip), "0", 1, true) ~= nil, "zero bonus is listed")
check(string.find(tostring(described.tip), "77", 1, true) ~= nil
    or string.find(tostring(described.tip), "share.effect", 1, true) ~= nil, "effect is listed")
local rowLabel = labels[WIN .. "Ingredient1"] or ""
check(string.find(rowLabel, "share.bonus_sep", 1, true) ~= nil
    or string.find(rowLabel, " | ", 1, true) ~= nil, "ingredient row shows a bonus summary")
check(string.find(rowLabel, "material.bonus.flat_plus", 1, true) ~= nil, "positive flat bonuses use FormatBonusLine")
check(string.find(rowLabel, "material.bonus.pct_plus", 1, true) ~= nil, "percent bonuses use FormatBonusLine")
check(string.find(rowLabel, "material.bonus.critical", 1, true) ~= nil, "critical chance is named critical")
check(string.find(rowLabel, "value=0", 1, true) ~= nil, "an explicit zero bonus is visible")
local zeroCrit = Share.DescribeSlot(slot("main", 1001, 10, { [12] = 0, [4] = 3 }), {})
check(string.find(tostring(zeroCrit.label), "material.bonus.pct", 1, true) ~= nil, "a zero percent bonus uses pct")
check(string.find(tostring(zeroCrit.label), "value=0", 1, true) ~= nil, "a zero percent bonus stays visible")
local resolvedIcon = false
for i = 1, #iconTextures do
    local row = iconTextures[i]
    check(type(row.texture) == "string", "ingredient texture comes from GetIconData")
    if row.texture == "tex-share" and row.x == 3 and row.y == 4 then
        resolvedIcon = true
    end
end
check(resolvedIcon, "GetIconData resolves texture, x, and y")
check(iconDataCalls > 0, "the fallback path calls GetIconData")
local scaled = false
for i = 1, #iconScales do
    if math.abs((iconScales[i].scale or 0) - (28 / 64)) < 0.0001 then
        scaled = true
    end
end
check(scaled, "ingredient icons scale to 28/64")

local recipeCount = 0
for _ in pairs(recipes) do
    recipeCount = recipeCount + 1
end
eq(recipeCount, 0, "opening the preview does not save a recipe")
Share.OnClose()
eq(shown[WIN], false, "cancel hides the preview")
eq(openList[WIN], nil, "cancel leaves the escape list")
recipeCount = 0
for _ in pairs(recipes) do
    recipeCount = recipeCount + 1
end
eq(recipeCount, 0, "cancel does not save a recipe")

eq(Share.ShowFromPlain(plain), true, "preview opens again")
openList[WIN]()
eq(shown[WIN], false, "escape closes the preview")
recipeCount = 0
for _ in pairs(recipes) do
    recipeCount = recipeCount + 1
end
eq(recipeCount, 0, "escape does not save a recipe")

eq(Share.ShowFromPlain(plain), true, "preview opens for learn")
eq(Share.OnLearn(), true, "learn imports")
eq(labels[WIN .. "Status"], "share.status_learned", "learn says Recipe learned")
eq(disabled[WIN .. "Learn"], true, "learn is disabled after import")
local learnedKey = nil
local learned = nil
for key, row in pairs(recipes) do
    learnedKey = key
    learned = row
end
check(type(learned) == "table", "learn stored a recipe")
eq(learned.sharedImport, true, "import stays unverified until a real brew")
eq(learned.unverified, true, "import is marked unverified")
eq(tonumber(learned.brewSuccesses) or 0, 0, "learn adds no brew history")
check(type(learned.outcomes) ~= "table" or next(learned.outcomes) == nil, "learn adds no outcome samples")
local potion = potions["uid:9001"]
check(type(potion) == "table", "learn adds the potion")
eq(tostring(potion.activeRecipeKey or ""), tostring(learnedKey), "new potion uses the learned recipe")
local learnedMain = nil
for i = 1, #(learned.slots or {}) do
    if learned.slots[i].role == "main" then
        learnedMain = learned.slots[i]
    end
end
check(StockPiler.Account.items[1001] == nil and StockPiler.Account.items["1001"] == nil, "the ingredient is not in Account.items")
check(type(learnedMain) == "table" and string.find(tostring(learnedMain.name), "Herb", 1, true) ~= nil, "a learned slot keeps the carried name")
eq(tonumber(learnedMain and learnedMain.iconNum), 5001, "a learned slot keeps the carried icon")
local reshare = RL.SerializePlain({
    uid = 9001,
    name = "Preview Potion",
    icon = 55,
    slots = learned.slots,
})
local reshared = RL.ParsePlain(reshare)
check(type(reshared) == "table" and type(reshared.details) == "table"
    and string.find(tostring(reshared.details[1001] and reshared.details[1001].name), "Herb", 1, true) ~= nil,
    "re-share keeps an unowned ingredient name")
eq(reshared and reshared.details and reshared.details[1001] and reshared.details[1001].icon, 5001, "re-share keeps an unowned ingredient icon")
load_module("Source/View/RecipeTooltip.lua")
local hoverRows = StockPiler.RecipeTooltip.BuildRows({
    name = "Preview Potion",
    recipe = learned,
})
local hoverText = ""
for i = 1, #hoverRows do
    hoverText = hoverText .. tostring(hoverRows[i].text)
end
check(string.find(hoverText, "Herb", 1, true) ~= nil, "hover shows a learned ingredient that is not in Account.items")

learned.brewSuccesses = 4
learned.outcomes = { ["9001"] = { samples = 3 } }
local activeBefore = potion.activeRecipeKey
eq(Share.ShowFromPlain(plain), true, "known recipe opens the preview")
eq(labels[WIN .. "Status"], "share.status_known", "known recipe says Already learned")
eq(disabled[WIN .. "Learn"], true, "learn stays off when already learned")
eq(Share.OnLearn(), false, "learn does not import a known recipe again")
eq(learned.brewSuccesses, 4, "already-learned leaves brew history")
eq(learned.outcomes["9001"].samples, 3, "already-learned leaves outcome samples")
eq(potion.activeRecipeKey, activeBefore, "already-learned leaves the active recipe")

local alt = {
    slot("main", 1001, 40),
    slot("container", 2002, 0),
}
local altPlain = RL.SerializePlain(fieldsFor(9001, "Preview Potion", alt))
eq(Share.ShowFromPlain(altPlain), true, "alternative opens the preview")
eq(labels[WIN .. "Status"], "share.status_new", "alternative is not learned yet")
eq(Share.OnLearn(), true, "learn adds the alternative")
eq(potion.activeRecipeKey, activeBefore, "alternative does not replace the active recipe")
eq(learned.brewSuccesses, 4, "alternative does not rewrite the first recipe history")
eq(learned.outcomes["9001"].samples, 3, "alternative does not rewrite the first outcomes")
local altRow = nil
for key, row in pairs(recipes) do
    if key ~= learnedKey then
        altRow = row
    end
end
check(type(altRow) == "table", "alternative recipe was stored")
check(type(altRow.outcomes) ~= "table" or next(altRow.outcomes) == nil, "alternative has no outcome samples")
eq(tonumber(altRow.brewSuccesses) or 0, 0, "alternative has no brew history")

wipe()
eq(Share.Show({ uid = 1, name = "Bad", slots = { slot("main", 1001, 1) } }), false, "main-only link is rejected")
eq(shown[WIN], nil, "rejected link does not show the window")
eq(Share.ShowFromPlain("not a potion"), false, "garbage apply is rejected")
eq(RL.ParsePlain("POTION;uid=1;d=1,1,Bad^n;slots=main:1:1:1:0:0:4:1:0:1:0:"), nil, "caret details never import")

local carried = RL.ParsePlain(RL.SerializePlain(fieldsFor(42, "Carried Potion", {
    slot("container", 7, 0, { [1] = 0 }),
    slot("main", 8, 9, { [1] = 0, [6] = 15 }),
})))
StockPiler.Items.GetByUid = function()
    return nil
end
eq(Share.Show(carried), true, "unknown items still preview from the payload")
local foundName = false
for i = 1, 5 do
    local text = labels[WIN .. "Ingredient" .. tostring(i)]
    if type(text) == "string" and string.find(text, "Herb", 1, true) then
        foundName = true
    end
end
check(foundName, "carried ingredient name is shown without client data")
eq(labels[WIN .. "PotionName"], "Carried Potion", "carried potion name is shown")

local inserted = nil
TextEditBoxSetMaxChars = function() end
TextEditBoxGetText = function()
    return ""
end
CreateHyperLink = function(data, text)
    return "<" .. tostring(data) .. "|" .. tostring(text) .. ">"
end
EA_ChatWindow = {
    InsertText = function(text)
        inserted = tostring(text)
    end,
    OnHyperLinkLButtonUp = function() end,
}
local shareRow = {
    uniqueID = 9001,
    name = "Preview Potion",
    iconNum = 55,
    potionKey = "uid:9001",
    recipeSpecKey = learnedKey,
}
-- Re-learn so the row's recipe exists after wipe.
wipe()
local fresh = fieldsFor(9001, "Preview Potion", sampleSlots())
eq(Share.Show(fresh), true, "row fixture preview")
eq(Share.OnLearn(), true, "row fixture learn")
local rowKey = nil
for key in pairs(recipes) do
    rowKey = key
end
shareRow.recipeSpecKey = rowKey
eq(RL.ShareRowIfShift(shareRow, 0), false, "ordinary click does not link")
eq(inserted, nil, "ordinary click inserts nothing")
eq(RL.ShareRowIfShift({ kind = "plant", uniqueID = 1 }, 4), false, "plant row does not link")
eq(RL.ShareRowIfShift({ skillUp = true, uniqueID = 1 }, 4), false, "skill-up row does not link")
eq(RL.ShareRowIfShift(shareRow, 4), true, "shift click links")
check(type(inserted) == "string" and string.find(inserted, "StockPiler", 1, true) ~= nil, "shift click inserts the chat link")
inserted = nil
eq(RL.ShareRowIfShift(shareRow, 5), true, "shift bit in combined flags links")

local viewListIcons = {}
StockPiler.ViewList = {
    OnRowChildMouseOver = function() end,
    OnRowChildMouseOverEnd = function() end,
    ConfirmTwoButton = function() end,
    SetIconTexture = function(win, icon, scale)
        viewListIcons[#viewListIcons + 1] = { win = win, icon = icon, scale = scale }
    end,
    ShowTextTip = function() end,
}
function DoesWindowExist(name)
    return name == "SPTabPotionsList" or name == "SPTabWatchList"
end
function WindowGetId()
    return 1
end
function ListBoxGetDataIndex()
    return 1
end
function WindowGetParent()
    return nil
end
load_module("Source/View/StockPilerTabPotions.lua")
load_module("Source/View/StockPilerTabWatch.lua")
StockPilerTabPotions.listData = { shareRow }
SystemData.ActiveWindow = { name = "StockPilerPotionRow" }
inserted = nil
StockPilerTabPotions.OnLinkClick(0)
eq(inserted, nil, "potion row ordinary click inserts nothing")
StockPilerTabPotions.OnLinkClick(4)
check(type(inserted) == "string", "potion row shift click inserts the link")
inserted = nil
StockPilerTabWatch.listData = {
    { kind = "plant", isPlantWatch = true, uniqueID = 3, plantUid = 3 },
}
SystemData.ActiveWindow = { name = "StockPilerWatchRow" }
StockPilerTabWatch.OnLinkClick(4)
eq(inserted, nil, "watch plant shift click inserts nothing")
StockPilerTabWatch.listData = { shareRow }
StockPilerTabWatch.OnLinkClick(0)
eq(inserted, nil, "watch potion ordinary click inserts nothing")
StockPilerTabWatch.OnLinkClick(4)
check(type(inserted) == "string", "watch potion shift click inserts the link")

local xml = io.open(ROOT .. "/Source/View/StockPilerTemplates.xml", "rb")
local xmlText = xml:read("*a")
xml:close()
local function count(text, needle)
    local n = 0
    local from = 1
    while true do
        local at = string.find(text, needle, from, true)
        if at == nil then
            return n
        end
        n = n + 1
        from = at + 1
    end
end
eq(count(xmlText, "StockPilerTabPotions.OnLinkClick"), 3, "potion row, icon, and name link on shift click")
eq(count(xmlText, "StockPilerTabWatch.OnLinkClick"), 3, "watch row, icon, and name link on shift click")
check(string.find(xmlText, "OnPrioLButtonUp", 1, true) ~= nil, "priority clicks stay on the priority control")
check(string.find(xmlText, "OnTargetLButtonUp", 1, true) ~= nil, "target clicks stay on the target control")
check(string.find(xmlText, "OnLoadRow", 1, true) ~= nil, "load clicks stay on the load control")

local shareXmlFile = io.open(ROOT .. "/Source/View/RecipeShare.xml", "rb")
local shareXml = shareXmlFile:read("*a")
shareXmlFile:close()
check(string.find(shareXml, 'name="$parentLearn" inherits="EA_Button_DefaultResizeable"', 1, true) ~= nil, "Learn uses the skinned resizeable button")
check(string.find(shareXml, 'name="$parentCancel" inherits="EA_Button_DefaultResizeable"', 1, true) ~= nil, "Cancel uses the skinned resizeable button")
check(string.find(shareXml, 'inherits="EA_Button_Default"', 1, true) == nil, "preview buttons are not the unskinned base template")
check(string.find(shareXml, 'name="$parentButtonBackground"', 1, true) ~= nil, "buttons sit in the bottom bar")
check(string.find(shareXml, '<Anchor point="bottom" relativePoint="bottomright" relativeTo="$parentButtonBackground">', 1, true) ~= nil, "Learn anchors its right edge to the bar center")
check(string.find(shareXml, '<Anchor point="bottom" relativePoint="bottomleft" relativeTo="$parentButtonBackground">', 1, true) ~= nil, "Cancel anchors its left edge to the bar center")
check(string.find(shareXml, 'point="bottomleft" relativePoint="bottom"', 1, true) == nil, "button anchors do not reverse point and relativePoint")
check(string.find(shareXml, 'point="bottomright" relativePoint="bottom"', 1, true) == nil, "button anchors do not hang off the window edges")

local iconsBefore = iconDataCalls
local texturesBefore = #iconTextures
local viewBefore = #viewListIcons
eq(Share.Show(fieldsFor(9001, "Preview Potion", sampleSlots())), true, "preview with ViewList loaded")
eq(iconDataCalls, iconsBefore, "ViewList.SetIconTexture resolves icons")
eq(#iconTextures, texturesBefore, "the ViewList path does not pass a raw icon id")
check(#viewListIcons > viewBefore, "preview delegates ingredient icons to ViewList")
local delegatedScale = false
for i = viewBefore + 1, #viewListIcons do
    if math.abs((viewListIcons[i].scale or 0) - (28 / 64)) < 0.0001 then
        delegatedScale = true
    end
end
check(delegatedScale, "ViewList icons use the 28/64 scale")

StockPiler.Inventory = {
    GetSample = function(uid)
        if tonumber(uid) == 1001 then
            return { uniqueID = 1001, name = "Bag Sample", iconNum = 77 }
        end
        return nil
    end,
}
function GetDatabaseItemData(uid)
    if tonumber(uid) == 2002 then
        return { uniqueID = 2002, name = "Database Herb", iconNum = 88 }
    end
    return nil
end
local fromSample = RL.KnownItemRow(1001)
eq(fromSample and fromSample.name, "Bag Sample", "KnownItemRow checks Inventory.GetSample")
local fromDb = RL.KnownItemRow(2002)
eq(fromDb and fromDb.name, "Database Herb", "KnownItemRow checks GetDatabaseItemData")
local bagSlot = Share.DescribeSlot(slot("main", 1001, 10), {})
eq(bagSlot.name, "Bag Sample", "a bag sample names the ingredient row")
local dbSlot = Share.DescribeSlot(slot("container", 2002, 0), {})
eq(dbSlot.name, "Database Herb", "database data names an ingredient the bags do not have")

CraftItemInfo = {
    FormatBonus = function(ref, value)
        local labels = {
            [1] = "+2 Stability",
            [2] = "+1 Power",
            [5] = "Tradeskill Apothecary",
            [6] = "Effect Heal",
            [8] = "Type Vial",
            [9] = "Requires Level 20",
            [10] = "Grow Time 10",
            [11] = "Yield +1",
            [15] = "Destroy on Fail",
        }
        return labels[tonumber(ref) or 0] or ("bonus " .. tostring(ref) .. "=" .. tostring(value))
    end,
}
local metaSlot = Share.DescribeSlot({
    role = "container",
    uid = 2002,
    perCraft = 1,
    spec = {
        uid = 2002,
        role = "container",
        name = "Artisan's Glass Vial",
        iconNum = 12,
        effectId = 0,
        bonuses = {
            [1] = 2,
            [2] = 1,
            [5] = 4,
            [6] = 15,
            [8] = 1,
            [9] = 20,
            [10] = 10,
            [11] = 1,
            [15] = 1,
        },
    },
}, {})
local metaText = tostring(metaSlot.label) .. "\n" .. tostring(metaSlot.tip)
check(string.find(metaText, "+2 Stability", 1, true) ~= nil, "stability still shows when metadata is present")
check(string.find(metaText, "+1 Power", 1, true) ~= nil, "power still shows when metadata is present")
check(string.find(metaText, "Yield +1", 1, true) ~= nil, "yield still shows")
check(string.find(metaText, "Tradeskill Apothecary", 1, true) == nil, "tradeskill family is not a row bonus")
check(string.find(metaText, "Type Vial", 1, true) == nil, "bonus type is not a row bonus")
check(string.find(metaText, "Requires Level", 1, true) == nil, "crafting level is not a row bonus")
check(string.find(metaText, "Grow Time", 1, true) == nil, "grow time is not a row bonus")
check(string.find(metaText, "Destroy on Fail", 1, true) == nil, "destroy-on-fail is not a row bonus")
check(string.find(metaText, "Effect Heal", 1, true) == nil, "the effect ref is not formatted as a bonus line")

local nameColors = {}
function LabelSetTextColor(win, r, g, b)
    nameColors[win] = { r = r, g = g, b = b }
end
StockPiler.ViewList.ItemRarityNameColor = function(item)
    if tonumber(item and item.rarity) == 3 then
        return 40, 80, 200
    end
    return 255, 255, 255
end
StockPiler.Account.potions["uid:4242"] = {
    potionKey = "uid:4242",
    outputUid = 4242,
    name = "Saved Blue",
    iconNum = 77,
    rarity = 3,
    iLevel = 36,
}
local legacyPlain = RL.SerializePlain(fieldsFor(4242, "Legacy Name", sampleSlots()))
check(type(legacyPlain) == "string" and string.find(legacyPlain, "rar=", 1, true) == nil, "legacy share omits rarity")
check(type(legacyPlain) == "string" and string.find(legacyPlain, "lv=", 1, true) == nil, "legacy share omits level")
eq(Share.ShowFromPlain(legacyPlain), true, "legacy link opens the preview")
local painted = nameColors[WIN .. "PotionName"]
eq(painted and painted.r, 40, "saved rarity tints the potion name")
eq(painted and painted.g, 80, "saved rarity green channel")
eq(painted and painted.b, 200, "saved rarity is not white")
eq(labels[WIN .. "PotionName"], "Legacy Name", "the link name stays when a saved potion exists")
local presentedName, presentedIcon, presentedRarity, presentedLevel = Share.PotionPresentation({
    uid = 4242,
    slots = sampleSlots(),
})
eq(presentedName, "Saved Blue", "a nameless link uses the saved potion name")
eq(presentedIcon, 77, "a nameless link uses the saved potion icon")
eq(presentedRarity, 3, "presentation uses the saved rarity")
eq(presentedLevel, 36, "presentation uses the saved level")

local fields = fieldsFor(998812, "Cancel Probe", sampleSlots())
eq(Share.Show(fields), true, "preview opens")
Share.OnClose()
eq(Share.OnLearn(), false, "closed preview cannot learn")
eq(StockPiler.Account.potions["uid:998812"], nil,
    "dismissed recipe stays unlearned")
eq(Share._open, false, "cancel marks the preview closed")
eq(Share._fields, nil, "cancel clears the pending recipe")

eq(Share.Show(fields), true, "close button reopens the preview")
Share.OnClose()
eq(Share._fields, nil, "close button clears the pending recipe")
eq(Share.OnLearn(), false, "close button leaves the recipe unlearned")
eq(StockPiler.Account.potions["uid:998812"], nil, "close button does not import")

eq(Share.Show(fields), true, "escape reopens the preview")
local escape = openList[WIN]
check(type(escape) == "function", "escape handler is registered")
escape()
eq(shown[WIN], false, "escape hides the preview")
eq(Share._open, false, "escape marks the preview closed")
eq(Share._fields, nil, "escape clears the pending recipe")
eq(Share.OnLearn(), false, "escape leaves the recipe unlearned")

eq(Share.Show(fields), true, "direct hide reopens the preview")
Share.OnHidden()
eq(Share._open, false, "direct hide marks the preview closed")
eq(Share._fields, nil, "direct hide clears the pending recipe")
eq(Share.OnLearn(), false, "hidden preview cannot learn")
eq(StockPiler.Account.potions["uid:998812"], nil, "direct hide does not import")

eq(Share.Show(fields), true, "reopening a link allows learn")
eq(Share._open, true, "reopened preview is open")
check(type(Share._fields) == "table", "reopened preview keeps the recipe")
eq(Share.OnLearn(), true, "learn works after the preview is opened again")
check(type(StockPiler.Account.potions["uid:998812"]) == "table", "reopened learn saves the potion")

wstring = {
    -- Game client: optional 4th arg n, and both return values (result, count).
    gsub = function(s, pat, repl, n)
        return string.gsub(tostring(s or ""), tostring(pat or ""), repl, n)
    end,
}
load_module("Source/Locale/Locale.lua")
load_module("Source/Locale/enUS.lua")
local okPercent, imported = pcall(StockPiler.T, "link.imported", { name = "Bad %2" })
check(okPercent == true, "a percent token does not throw")
eq(imported, "Added Bad %2 to Known Potions.", "percent name is kept in the imported line")
local okTrail, forgetLine = pcall(StockPiler.T, "potions.forget_confirm", { name = "Elixir 100%" })
check(okTrail == true, "a trailing percent does not throw")
eq(forgetLine, "Forget this learned potion recipe?\nElixir 100%",
    "trailing percent is kept in the forget line")
local okSlot, slotLine = pcall(StockPiler.T, "share.slot_line", {
    qty = "1",
    role = "main",
    name = "Root %2",
})
check(okSlot == true, "an ingredient percent does not throw")
eq(slotLine, "1x main: Root %2", "ingredient percent is kept in the slot line")
eq(StockPiler.T("ui.title_version", { version = "1.1.1" }), "StockPiler v1.1.1",
    "a version token with no percent is replaced")
eq(StockPiler.T("tip.watch.have_target", { have = 3, target = 10 }), "Have 3 / Target 10",
    "every token in a multi-token line is replaced")
StockPiler.Locale.Packs[1]["test.repeat_name"] = "{name} and {name}"
eq(StockPiler.T("test.repeat_name", { name = "Potion" }), "Potion and Potion",
    "a repeated token with no percent is replaced every time")
eq(StockPiler.T("test.repeat_name", { name = "A%B" }), "A%B and A%B",
    "a repeated token with one percent is replaced every time")

if failures > 0 then
    io.stderr:write(string.format("%d/%d checks failed\n", failures, checks))
    os.exit(1)
end
print(string.format("recipe_share: %d checks passed", checks))
