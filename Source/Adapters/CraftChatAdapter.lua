----------------------------------------------------------------
-- StockPiler Adapters/CraftChatAdapter - chat print + soil confirm
----------------------------------------------------------------

StockPiler = StockPiler or {}
StockPiler.CraftChatAdapter = StockPiler.CraftChatAdapter or {}
local CC = StockPiler.CraftChatAdapter

-- Pending plant meta awaiting soil confirm (plot leaves EMPTY).
CC._soilPending = CC._soilPending or {}
CC._soilChatMeta = CC._soilChatMeta or {}

local PLANT_CHAT_META_TTL_SEC = 30
local PENDING_EMPTY_GRACE_SEC = 5.0

local function NowSec()
    return StockPiler.Util and StockPiler.Util.NowSec and StockPiler.Util.NowSec() or 0
end

local function TryQuiet(label, fn, ...)
    return StockPiler.Util.TryCallQuiet(label, fn, ...)
end

local function ToWString(value)
    if type(value) == "wstring" then
        return value
    end
    if value == nil then
        return L""
    end
    return towstring(tostring(value))
end

local function StageEmpty()
    return StockPiler.CultivatorAdapter.StageEmpty()
end

local function ResolveItemData(uid)
    uid = tonumber(uid) or 0
    if uid <= 0 then
        return nil
    end
    if StockPiler.Inventory and StockPiler.Inventory.GetSample then
        local sample = StockPiler.Inventory.GetSample(uid)
        if type(sample) == "table" then
            return sample
        end
    end
    if type(GetDatabaseItemData) == "function" then
        local ok, data = TryQuiet("GetDatabaseItemData", GetDatabaseItemData, uid)
        if ok and type(data) == "table" then
            return data
        end
    end
    return nil
end

--- Clickable ITEM:uid hyperlink (same shape as EA_ChatWindow.InsertItemLink).
function CC.ItemLink(uid, fallbackName)
    uid = tonumber(uid) or 0
    local itemData = ResolveItemData(uid)
    local name = nil
    if type(itemData) == "table" and itemData.name ~= nil and itemData.name ~= L"" then
        name = itemData.name
    elseif fallbackName ~= nil and fallbackName ~= L"" and fallbackName ~= "" then
        name = ToWString(fallbackName)
    else
        name = L"item"
    end
    local text = L"[" .. name .. L"]"
    if uid <= 0 or type(CreateHyperLink) ~= "function" then
        return text
    end
    local r, g, b = 255, 255, 255
    if type(itemData) == "table" and DataUtils and DataUtils.GetItemRarityColor then
        local ok, color = TryQuiet("DataUtils.GetItemRarityColor", DataUtils.GetItemRarityColor, itemData)
        if ok and type(color) == "table" then
            r = tonumber(color.r) or r
            g = tonumber(color.g) or g
            b = tonumber(color.b) or b
        end
    end
    local data = L"ITEM:" .. uid
    local ok, link = TryQuiet("CreateHyperLink", CreateHyperLink, data, text, { r, g, b }, {})
    if ok and link ~= nil then
        if type(link) == "wstring" then
            return link
        end
        return towstring(link)
    end
    return text
end

local function IconMarkup(iconNum)
    iconNum = tonumber(iconNum) or 0
    if iconNum <= 0 then
        return L""
    end
    return towstring(string.format("<icon%05d> ", iconNum))
end

--- Item icon markup for chat, placed beside a name. Empty when unknown.
function CC.ItemIconMarkup(uid, fallbackIcon)
    uid = tonumber(uid) or 0
    local icon = 0
    if uid > 0 then
        local itemData = ResolveItemData(uid)
        if type(itemData) == "table" then
            icon = tonumber(itemData.iconNum) or 0
        end
        if icon <= 0 and StockPiler.Items and StockPiler.Items.GetByUid then
            local row = StockPiler.Items.GetByUid(uid)
            if type(row) == "table" then
                icon = tonumber(row.iconNum) or 0
            end
        end
    end
    if icon <= 0 then
        icon = tonumber(fallbackIcon) or 0
    end
    return IconMarkup(icon)
end

--- Item icon, then the clickable name. Leading harvest/brew icons stay in the phrase.
function CC.NamedItem(uid, fallbackName, fallbackIcon)
    return CC.ItemIconMarkup(uid, fallbackIcon) .. CC.ItemLink(uid, fallbackName)
end

function CC.Print(msg, kind)
    if msg == nil then
        return
    end
    if StockPiler.Debug and StockPiler.Debug.Print then
        StockPiler.Debug.Print(msg, kind)
        return
    end
    if type(EA_ChatWindow) == "table" and type(EA_ChatWindow.Print) == "function" then
        if type(msg) == "wstring" then
            EA_ChatWindow.Print(msg)
        else
            EA_ChatWindow.Print(towstring(tostring(msg)))
        end
    end
end

--- Print a line that may include ITEM links (wstring parts joined).
function CC.PrintParts(...)
    local parts = { ... }
    local out = L""
    for i = 1, #parts do
        local p = parts[i]
        if p ~= nil then
            out = out .. ToWString(p)
        end
    end
    if out ~= L"" then
        CC.Print(out)
    end
end

function CC.PrintWithItem(prefix, uid, fallbackName, suffix)
    local link = CC.ItemLink(uid, fallbackName)
    CC.PrintParts(prefix or "", link, suffix or "")
end

--- Stash plant meta until soil leaves EMPTY (chat once on confirm).
function CC.StashSoilPending(plotNum, meta)
    plotNum = tonumber(plotNum) or 0
    if plotNum <= 0 or type(meta) ~= "table" then
        return
    end
    local newSeed = tonumber(meta.seedUid) or 0
    local existing = CC._soilPending[plotNum]
    if type(existing) ~= "table" then
        existing = CC._soilChatMeta[plotNum]
    end
    if type(existing) == "table" and existing.chatted ~= true then
        local oldSeed = tonumber(existing.seedUid) or 0
        if oldSeed > 0 and newSeed > 0 and oldSeed ~= newSeed then
            -- Do not clobber an in-flight plant announce with a different seed.
            return
        end
        -- Same seed (or unknown): refresh timestamp only.
        existing.at = NowSec()
        existing.reason = tostring(meta.reason or existing.reason or "potion_stock")
        if meta.name ~= nil then
            existing.name = meta.name
        end
        if newSeed > 0 then
            existing.seedUid = newSeed
        end
        CC._soilPending[plotNum] = existing
        CC._soilChatMeta[plotNum] = {
            reason = existing.reason,
            name = existing.name,
            seedUid = existing.seedUid,
            at = existing.at,
            chatted = false,
        }
        return
    end
    local row = {
        reason = tostring(meta.reason or "potion_stock"),
        name = meta.name,
        seedUid = newSeed,
        at = NowSec(),
        chatted = false,
    }
    CC._soilPending[plotNum] = row
    CC._soilChatMeta[plotNum] = {
        reason = row.reason,
        name = row.name,
        seedUid = row.seedUid,
        at = row.at,
        chatted = false,
    }
end

function CC.ClearSoilPending(plotNum)
    plotNum = tonumber(plotNum) or 0
    if plotNum <= 0 then
        return
    end
    CC._soilPending[plotNum] = nil
end

local function EmitPlantedChat(plotNum, meta)
    plotNum = tonumber(plotNum) or 0
    if plotNum <= 0 or type(meta) ~= "table" then
        return
    end
    if meta.chatted == true then
        return
    end
    meta.chatted = true
    local stash = CC._soilChatMeta[plotNum]
    if type(stash) == "table" then
        stash.chatted = true
    end
    local seedUid = tonumber(meta.seedUid) or 0
    local namePart = meta.name
    if seedUid > 0 then
        namePart = CC.NamedItem(seedUid, meta.name, meta.seedIconNum)
    else
        namePart = ToWString(meta.name or "seed")
    end
    local reason = tostring(meta.reason or "potion_stock")
    local msg = nil
    if StockPiler.T then
        msg = StockPiler.T("grow.planted", {
            plot = tostring(plotNum),
            name = namePart,
            reason = towstring(reason),
        })
    end
    if msg == nil then
        msg = L"<icon02486> Plot " .. towstring(tostring(plotNum))
            .. L" planted " .. ToWString(namePart)
            .. L" (" .. towstring(reason) .. L")."
    end
    CC.Print(msg)
end

--- Call when a plot leaves EMPTY after PlantSeed. Returns true if chat fired.
function CC.OnSoilConfirmed(plotNum, plotInfo)
    plotNum = tonumber(plotNum) or 0
    if plotNum <= 0 then
        return false
    end
    local pending = CC._soilPending[plotNum]
    local stash = CC._soilChatMeta[plotNum]
    local meta = pending
    if type(meta) ~= "table" then
        meta = stash
    end
    if type(meta) ~= "table" then
        return false
    end
    if meta.chatted == true or (type(stash) == "table" and stash.chatted == true) then
        CC._soilPending[plotNum] = nil
        return false
    end
    if type(plotInfo) == "table" then
        local plotSeed = tonumber(plotInfo.seedUid) or 0
        local metaSeed = tonumber(meta.seedUid) or 0
        local seedIcon = tonumber(plotInfo.seedIconNum) or 0
        if plotSeed > 0 and metaSeed > 0 and plotSeed ~= metaSeed then
            -- Prefer what actually grew; still announce instead of silent drop.
            meta = {
                reason = tostring(meta.reason or "potion_stock"),
                name = meta.name,
                seedUid = plotSeed,
                seedIconNum = seedIcon,
                at = meta.at,
                chatted = false,
            }
        elseif seedIcon > 0 then
            meta.seedIconNum = seedIcon
        end
    end
    EmitPlantedChat(plotNum, meta)
    CC._soilPending[plotNum] = nil
    return true
end

--- Handle empty-while-pending (grace before drop). keepChatMeta for late soil.
function CC.OnSoilStillEmpty(plotNum, opts)
    plotNum = tonumber(plotNum) or 0
    opts = type(opts) == "table" and opts or {}
    local pending = CC._soilPending[plotNum]
    if type(pending) ~= "table" then
        return false
    end
    local at = tonumber(pending.at) or 0
    local now = NowSec()
    local grace = tonumber(opts.graceSec) or PENDING_EMPTY_GRACE_SEC
    if at > 0 and now > 0 and (now - at) < grace then
        return false
    end
    if opts.keepChatMeta ~= true then
        CC._soilChatMeta[plotNum] = nil
    end
    CC._soilPending[plotNum] = nil
    return true
end

--- Sync helper: confirm from plot snapshot (stage != EMPTY).
function CC.TryConfirmFromPlot(plotNum, plotInfo)
    plotNum = tonumber(plotNum) or 0
    if plotNum <= 0 or type(plotInfo) ~= "table" then
        return false
    end
    local stage = tonumber(plotInfo.stage) or 0
    if stage == StageEmpty() then
        CC.OnSoilStillEmpty(plotNum, { keepChatMeta = true })
        return false
    end
    return CC.OnSoilConfirmed(plotNum, plotInfo)
end

function CC.ExpireStaleChatMeta()
    local now = NowSec()
    if now <= 0 then
        return
    end
    for plotNum, meta in pairs(CC._soilChatMeta) do
        if type(meta) == "table" then
            local at = tonumber(meta.at) or 0
            if at > 0 and (now - at) > PLANT_CHAT_META_TTL_SEC then
                CC._soilChatMeta[plotNum] = nil
            end
        end
    end
end

function CC.HasSoilPending(plotNum)
    plotNum = tonumber(plotNum) or 0
    if plotNum <= 0 then
        return false
    end
    return type(CC._soilPending[plotNum]) == "table"
end

----------------------------------------------------------------
-- Crafting-channel harvest cues ("Your creation failed.", Critical Success, ...)
-- Chat arrives before plot-empty often; sticky cues bridge until BeginPendingHarvest.
----------------------------------------------------------------

local HARVEST_CUE_STICKY_SEC = 5
CC._harvestFailStickyAt = 0
CC._harvestOkStickyAt = 0
CC._harvestSpecialMomentStickyAt = 0
CC._chatRegistered = false

local function ToNarrow(value)
    return StockPiler.Util.ToNarrow(value)
end

local function NormalizeChat(text)
    local s = ToNarrow(text)
    s = string.gsub(s, "<LINK[^>]*>", "")
    s = string.gsub(s, "</LINK>", "")
    s = string.gsub(s, "<[^>]+>", "")
    s = string.gsub(s, "^%s+", "")
    s = string.gsub(s, "%s+$", "")
    return s
end

local function StickyFresh(at)
    at = tonumber(at) or 0
    if at <= 0 then
        return false
    end
    local age = NowSec() - at
    return age >= 0 and age <= HARVEST_CUE_STICKY_SEC
end

function CC.ConsumeHarvestCriticalFailureSticky()
    local at = CC._harvestFailStickyAt
    CC._harvestFailStickyAt = 0
    return StickyFresh(at)
end

function CC.ConsumeHarvestCriticalSuccessSticky()
    local at = CC._harvestOkStickyAt
    CC._harvestOkStickyAt = 0
    return StickyFresh(at)
end

function CC.ConsumeHarvestSpecialMomentSticky()
    local at = CC._harvestSpecialMomentStickyAt
    CC._harvestSpecialMomentStickyAt = 0
    return StickyFresh(at)
end

function CC.ArmHarvestFailSticky()
    CC._harvestFailStickyAt = NowSec()
end

function CC.ArmHarvestSuccessSticky()
    CC._harvestOkStickyAt = NowSec()
end

function CC.ArmHarvestSpecialMomentSticky()
    local now = NowSec()
    CC._harvestOkStickyAt = now
    CC._harvestSpecialMomentStickyAt = now
end

local CRAFT_PHRASE_FALLBACK = {
    ["craft.fail"] = "your creation failed",
    ["craft.critical_failure"] = "critical failure",
    ["craft.critical_success"] = "critical success",
    ["craft.special_moment"] = "special moment",
    ["craft.harvested"] = "You have harvested {count} {name}",
    ["craft.created"] = "You created {name}",
    ["craft.bad_seed"] = "bad seed data",
    ["craft.bad_seed_generate"] = "seed could not be generated",
    ["craft.bad_seed_generate_alt"] = "seed couldn't be generated",
    ["craft.add_main"] = "add main ingredient before",
}

local function NarrowTemplate(key)
    local template = nil
    local Locale = StockPiler.Locale
    if Locale and Locale.ResolveTemplate then
        template = Locale.ResolveTemplate(key)
    end
    local narrow = nil
    if template ~= nil and StockPiler.Util and StockPiler.Util.ToNarrow then
        narrow = StockPiler.Util.ToNarrow(template)
    elseif type(template) == "string" then
        narrow = template
    end
    if type(narrow) ~= "string" or narrow == "" or string.sub(narrow, 1, 1) == "[" then
        narrow = CRAFT_PHRASE_FALLBACK[key]
    end
    return narrow
end

local function StartsWithPhrase(lower, phrase)
    phrase = string.lower(tostring(phrase or ""))
    if phrase == "" then
        return false
    end
    if string.sub(lower, 1, #phrase) ~= phrase then
        return false
    end
    local nextCh = string.sub(lower, #phrase + 1, #phrase + 1)
    return nextCh == "" or nextCh == "." or nextCh == "!" or nextCh == " "
end

local function MatchCraftTemplate(text, template)
    template = tostring(template or "")
    if template == "" then
        return nil
    end
    local countPos = string.find(template, "{count}", 1, true)
    local namePos = string.find(template, "{name}", 1, true)
    if countPos == nil and namePos == nil then
        return nil
    end
    local pattern = "^"
    local function esc(s)
        return (string.gsub(s, "([%%%(%)%.%+%-%*%?%[%]%^%$])", "%%%1"))
    end
    local cursor = 1
    local tokens = {}
    while true do
        local cPos = string.find(template, "{count}", cursor, true)
        local nPos = string.find(template, "{name}", cursor, true)
        local pos, kind, skip = nil, nil, 0
        if cPos ~= nil and (nPos == nil or cPos <= nPos) then
            pos, kind, skip = cPos, "count", 7
        elseif nPos ~= nil then
            pos, kind, skip = nPos, "name", 6
        else
            break
        end
        pattern = pattern .. esc(string.sub(template, cursor, pos - 1))
        if kind == "count" then
            pattern = pattern .. "(%d+)"
        else
            pattern = pattern .. "(.+)"
        end
        tokens[#tokens + 1] = kind
        cursor = pos + skip
    end
    pattern = pattern .. esc(string.sub(template, cursor)) .. "%.?$"
    local a, b = string.match(text, pattern)
    if a == nil then
        return nil
    end
    local out = {}
    if tokens[1] ~= nil then
        out[tokens[1]] = a
    end
    if tokens[2] ~= nil then
        out[tokens[2]] = b
    end
    return out
end

local function ParseCraftingLine(text)
    if text == "" then
        return nil
    end
    local lower = string.lower(text)
    if StartsWithPhrase(lower, NarrowTemplate("craft.fail"))
        or StartsWithPhrase(lower, NarrowTemplate("craft.critical_failure"))
    then
        return { kind = "critical_failure" }
    end
    if StartsWithPhrase(lower, NarrowTemplate("craft.critical_success")) then
        return { kind = "critical_success" }
    end
    -- Cultivation Special Moment (super-crit) - same cue family as critical success.
    if StartsWithPhrase(lower, NarrowTemplate("craft.special_moment")) then
        return { kind = "special_moment" }
    end
    local harvested = MatchCraftTemplate(text, NarrowTemplate("craft.harvested"))
    if type(harvested) == "table" and harvested.count ~= nil and harvested.name ~= nil then
        local plant = string.gsub(harvested.name, "%.$", "")
        return { kind = "harvested", count = tonumber(harvested.count), name = plant }
    end
    local created = MatchCraftTemplate(text, NarrowTemplate("craft.created"))
    if type(created) == "table" and created.name ~= nil then
        local name = string.gsub(created.name, "%.$", "")
        return { kind = "created", name = name }
    end
    -- Server destroys the item it just refused ("it has been lost") and tells
    -- you the main never landed. One line is enough to stop the load.
    if string.find(lower, string.lower(NarrowTemplate("craft.bad_seed")), 1, true)
        or string.find(lower, string.lower(NarrowTemplate("craft.bad_seed_generate_alt")), 1, true)
        or string.find(lower, string.lower(NarrowTemplate("craft.bad_seed_generate")), 1, true)
        or string.find(lower, string.lower(NarrowTemplate("craft.add_main")), 1, true)
    then
        return { kind = "bad_seed" }
    end
    return nil
end

function CC.OnChatTextArrived()
    if not GameData or not GameData.ChatData then
        return
    end
    local filters = SystemData and SystemData.ChatLogFilters
    local craftFilter = filters and filters.CRAFTING
    local msgType = tonumber(GameData.ChatData.type)
    -- Missing filter id used to accept every channel (ADP-16).
    if craftFilter == nil then
        if CC._loggedMissingCraftFilter ~= true then
            CC._loggedMissingCraftFilter = true
            if StockPiler.Debug and StockPiler.Debug.LogAlways then
                StockPiler.Debug.LogAlways(
                    "craft-chat| SystemData.ChatLogFilters.CRAFTING is nil; ignoring all chat"
                )
            end
        end
        return
    end
    if msgType ~= tonumber(craftFilter) then
        return
    end
    local text = NormalizeChat(GameData.ChatData.text)
    local parsed = ParseCraftingLine(text)
    if type(parsed) ~= "table" then
        return
    end
    local Bus = StockPiler.EventBus
    local E = StockPiler.Events
    if Bus and E and E.CRAFT_CHAT then
        Bus.Fire(E.CRAFT_CHAT, parsed)
    end
end

function CC.RegisterChat()
    if CC._chatRegistered == true then
        return
    end
    local ev = SystemData and SystemData.Events and SystemData.Events.CHAT_TEXT_ARRIVED
    if ev == nil then
        return
    end
    if type(RegisterEventHandler) == "function" then
        RegisterEventHandler(ev, "StockPiler.CraftChatAdapter.OnChatTextArrived")
        CC._chatRegistered = true
    end
end

function CC.UnregisterChat()
    if CC._chatRegistered ~= true then
        return
    end
    local ev = SystemData and SystemData.Events and SystemData.Events.CHAT_TEXT_ARRIVED
    if ev ~= nil and type(UnregisterEventHandler) == "function" then
        UnregisterEventHandler(ev, "StockPiler.CraftChatAdapter.OnChatTextArrived")
    end
    CC._chatRegistered = false
    CC._harvestFailStickyAt = 0
    CC._harvestOkStickyAt = 0
    CC._harvestSpecialMomentStickyAt = 0
end
