----------------------------------------------------------------
-- StockPiler RecipeLink -- NB-style chat share / import for potions
-- Plain payload (paste-safe), preferred order:
--   POTION;uid=<n>;icon=<n>;n=<name>;slots=<encoded>;rk=<fingerprint>
-- slots before rk so chat truncation keeps materials. Slot rows are
--   role:uid:perCraft:power:stability:duration:tradeSkill:skillLevel:cult:slotType
-- joined with ^ .
-- Hyperlink linkData: StockPiler: + plain payload
-- Click: import into Known Potions only when the recipe is not already known.
----------------------------------------------------------------

StockPiler = StockPiler or {}
StockPiler.RecipeLink = StockPiler.RecipeLink or {}
local RL = StockPiler.RecipeLink

RL.LINK_PREFIX = L"StockPiler:"
RL.LINK_COLOR = { 80, 200, 255 }
RL.LINK_MAX_DATA = 3500

RL._lastShareKey = nil
RL._hyperlinkHooked = false
RL._prevOnHyperLinkLButtonUp = nil
RL._contextFields = nil

local function T(key, tokens)
    return StockPiler.Util.T(key, tokens)
end

local function Print(msg)
    if StockPiler.Debug and StockPiler.Debug.Reply then
        StockPiler.Debug.Reply(msg)
    elseif StockPiler.Debug and StockPiler.Debug.Print then
        StockPiler.Debug.Print(msg, "user")
    end
end

local function ToNarrow(v)
    if StockPiler.Util and StockPiler.Util.ToNarrow then
        return StockPiler.Util.ToNarrow(v)
    end
    if type(v) == "wstring" and type(WStringToString) == "function" then
        return WStringToString(v) or ""
    end
    return tostring(v or "")
end

local function ToW(v)
    if type(v) == "wstring" then
        return v
    end
    if v == nil then
        return L""
    end
    return towstring(tostring(v))
end

local function SanitizeName(name)
    name = ToNarrow(name)
    name = string.gsub(name, "[;%[%]]", "")
    name = string.gsub(name, "%s+", " ")
    name = string.gsub(name, "^%s+", "")
    name = string.gsub(name, "%s+$", "")
    if string.len(name) > 48 then
        name = string.sub(name, 1, 48)
    end
    return name
end

function RL.DisplayName(fields)
    local name = fields and fields.name
    local narrow = SanitizeName(name)
    if narrow ~= "" then
        return ToW(narrow)
    end
    local uid = tonumber(fields and fields.uid) or 0
    return towstring("uid:" .. tostring(uid))
end

--- Build composite or plain watch/potion key from parsed fields.
function RL.WatchKeyFromFields(fields)
    if type(fields) ~= "table" then
        return nil
    end
    local uid = tonumber(fields.uid) or 0
    local rk = tostring(fields.rk or "")
    if uid <= 0 then
        return nil
    end
    local RS = StockPiler.RecipeSpec
    if rk ~= "" and RS and RS.PotionRecipeKey then
        return RS.PotionRecipeKey(uid, rk)
    end
    if RS and RS.PotionKeyFromUid then
        return RS.PotionKeyFromUid(uid)
    end
    return "uid:" .. tostring(math.floor(uid))
end

--- Encode slim recipe slots for the link payload.
function RL.EncodeSlots(slots)
    if type(slots) ~= "table" or #slots < 1 then
        return ""
    end
    local parts = {}
    for i = 1, #slots do
        local slot = slots[i]
        if type(slot) == "table" then
            local spec = type(slot.spec) == "table" and slot.spec or slot
            local role = tostring(slot.role or spec.role or "main")
            role = string.gsub(role, "[^%w_]", "")
            if role == "" then
                role = "main"
            end
            parts[#parts + 1] = table.concat({
                role,
                tostring(math.floor(tonumber(slot.uid) or tonumber(spec.uid) or 0)),
                tostring(math.max(1, math.floor(tonumber(slot.perCraft) or 1))),
                tostring(math.floor(tonumber(spec.power) or 0)),
                tostring(math.floor(tonumber(spec.stability) or 0)),
                tostring(math.floor(tonumber(spec.duration) or 0)),
                tostring(math.floor(tonumber(spec.tradeSkill) or 0)),
                tostring(math.floor(tonumber(spec.skillLevel) or 0)),
                tostring(math.floor(tonumber(spec.cultivationType) or 0)),
                tostring(math.floor(tonumber(spec.slotType) or 0)),
            }, ":")
        end
    end
    return table.concat(parts, "^")
end

--- Decode slots= payload into slim slot tables.
function RL.DecodeSlots(encoded)
    encoded = ToNarrow(encoded)
    if encoded == "" then
        return nil
    end
    local slots = {}
    for piece in string.gmatch(encoded, "[^%^]+") do
        local role, uid, perCraft, power, stab, dur, ts, sl, cult, slotType =
            string.match(piece, "^([^:]+):(%-?%d+):(%-?%d+):(%-?%d+):(%-?%d+):(%-?%d+):(%-?%d+):(%-?%d+):(%-?%d+):(%-?%d+)$")
        if role and uid then
            local u = tonumber(uid) or 0
            local pc = math.max(1, tonumber(perCraft) or 1)
            local entry = {
                role = role,
                uid = u > 0 and u or nil,
                perCraft = pc,
                spec = {
                    uid = u > 0 and u or nil,
                    role = role,
                    power = tonumber(power) or 0,
                    stability = tonumber(stab) or 0,
                    duration = tonumber(dur) or 0,
                    tradeSkill = tonumber(ts) or 0,
                    skillLevel = tonumber(sl) or 0,
                    cultivationType = tonumber(cult) or 0,
                    slotType = tonumber(slotType) or 0,
                },
            }
            slots[#slots + 1] = entry
        end
    end
    if #slots < 1 then
        return nil
    end
    return slots
end

local function RecipeSlotsByKey(rk)
    rk = tostring(rk or "")
    if rk == "" then
        return nil
    end
    local RS = StockPiler.RecipeSpec
    if RS and RS.GetRecipe then
        local recipe = RS.GetRecipe(rk)
        if type(recipe) == "table" and type(recipe.slots) == "table" and #recipe.slots > 0 then
            return recipe.slots
        end
    end
    -- Direct Account table (avoids GetRecipe edge cases after partial forget).
    local recipes = StockPiler.Account and StockPiler.Account.recipes
    local row = type(recipes) == "table" and recipes[rk] or nil
    if type(row) == "table" and type(row.slots) == "table" and #row.slots > 0 then
        return row.slots
    end
    return nil
end

local function AttachSlotsFromKnowledge(fields)
    if type(fields) ~= "table" then
        return fields
    end
    if type(fields.slots) == "table" and #fields.slots > 0 then
        return fields
    end
    local slots = RecipeSlotsByKey(fields.rk)
    if type(slots) == "table" then
        fields.slots = slots
    end
    return fields
end

--- Serialize a potion share. fields: uid, rk, name, icon, slots?
--- Order: uid/icon/name/slots then optional rk. Chat truncates from the end, so
--- materials (slots) must come before the long fingerprint.
function RL.SerializePlain(fields)
    if type(fields) ~= "table" then
        return nil
    end
    local uid = tonumber(fields.uid) or 0
    if uid <= 0 then
        return nil
    end
    fields = AttachSlotsFromKnowledge(fields)
    local rk = tostring(fields.rk or "")
    local icon = math.floor(tonumber(fields.icon) or tonumber(fields.iconNum) or 0)
    local name = SanitizeName(fields.name)
    local slotsEnc = ""
    if type(fields.slots) == "table" then
        slotsEnc = RL.EncodeSlots(fields.slots)
    elseif type(fields.slotsEncoded) == "string" then
        slotsEnc = fields.slotsEncoded
    end

    local function build(includeName, includeRk)
        local parts = {
            "POTION",
            "uid=" .. tostring(math.floor(uid)),
        }
        if icon > 0 then
            parts[#parts + 1] = "icon=" .. tostring(icon)
        end
        if includeName and name ~= "" then
            parts[#parts + 1] = "n=" .. name
        end
        if slotsEnc ~= "" then
            parts[#parts + 1] = "slots=" .. slotsEnc
        end
        -- rk last (and optional): safe to drop when slots can rebuild identity.
        if includeRk and rk ~= "" then
            parts[#parts + 1] = "rk=" .. rk
        end
        return table.concat(parts, ";")
    end

    local plain = build(true, true)
    -- Prefer keeping slots over rk/name when over the chat budget.
    if string.len("StockPiler:" .. plain) > RL.LINK_MAX_DATA then
        plain = build(true, false)
    end
    if string.len("StockPiler:" .. plain) > RL.LINK_MAX_DATA then
        plain = build(false, false)
    end
    return plain
end

--- Parse plain POTION;… payload (string). Returns fields table or nil.
function RL.ParsePlain(plain)
    plain = ToNarrow(plain)
    plain = string.gsub(plain, "^%s+", "")
    plain = string.gsub(plain, "%s+$", "")
    if plain == "" then
        return nil
    end
    local viaApply = string.match(plain, "^/stp%s+apply%s+(.+)$")
    if viaApply then
        plain = viaApply
        plain = string.gsub(plain, "^%s+", "")
    end
    if string.sub(string.upper(plain), 1, 6) ~= "POTION" then
        return nil
    end
    local body = plain
    if string.sub(string.upper(body), 1, 7) == "POTION;" then
        body = string.sub(body, 8)
    elseif string.sub(string.upper(body), 1, 6) == "POTION" then
        body = string.sub(body, 7)
        body = string.gsub(body, "^;", "")
    end
    if body == "" then
        return nil
    end

    local fields = {}
    -- Peel trailing slots= / rk= in either order (current: slots then rk; legacy: rk then slots).
    local function peelSuffix(tag)
        local needle = ";" .. tag .. "="
        local at = string.find(body, needle, 1, true)
        if at ~= nil then
            local val = string.sub(body, at + #needle)
            body = string.sub(body, 1, at - 1)
            return val
        end
        local prefix = tag .. "="
        if string.sub(body, 1, #prefix) == prefix then
            local val = string.sub(body, #prefix + 1)
            body = ""
            return val
        end
        return nil
    end
    -- Prefer peeling whichever suffix is present last in the string.
    local lastSlots = select(1, string.find(body, ";slots=", 1, true)) or (string.sub(body, 1, 6) == "slots=" and 1) or 0
    local lastRk = select(1, string.find(body, ";rk=", 1, true)) or (string.sub(body, 1, 3) == "rk=" and 1) or 0
    if lastSlots > 0 or lastRk > 0 then
        if lastSlots >= lastRk then
            fields.slotsEncoded = peelSuffix("slots")
            fields.rk = peelSuffix("rk") or fields.rk
        else
            fields.rk = peelSuffix("rk")
            fields.slotsEncoded = peelSuffix("slots") or fields.slotsEncoded
        end
    end

    for piece in string.gmatch(body, "[^;]+") do
        local key, val = string.match(piece, "^([^=]+)=(.*)$")
        if key and val then
            key = string.lower(key)
            if key == "uid" then
                fields.uid = tonumber(val)
            elseif key == "icon" then
                fields.icon = tonumber(val)
            elseif key == "n" or key == "name" then
                fields.name = val
            elseif key == "rk" then
                fields.rk = val
            elseif key == "slots" then
                fields.slotsEncoded = val
            end
        end
    end

    if (tonumber(fields.uid) or 0) <= 0 then
        return nil
    end
    if fields.slotsEncoded and fields.slotsEncoded ~= "" then
        fields.slots = RL.DecodeSlots(fields.slotsEncoded)
    end
    return fields
end

function RL.ParseLinkData(linkData)
    if linkData == nil then
        return nil
    end
    local data = ToNarrow(linkData)
    local payload = string.match(data, "^StockPiler:%s*(.+)$")
    if payload == nil and type(linkData) == "wstring" then
        local wpayload = linkData:match(L"^StockPiler:%s*(.+)$")
        if wpayload ~= nil then
            payload = ToNarrow(wpayload)
        end
    end
    if payload == nil then
        return nil
    end
    return RL.ParsePlain(payload)
end

function RL.BuildLinkData(fields)
    local plain = RL.SerializePlain(fields)
    if plain == nil or plain == "" then
        return nil
    end
    return ToW("StockPiler:" .. plain)
end

--- True when this potion+fingerprint is still on Known Potions.
--- Do not use Account.recipes alone: Forget unlinks the potion but may leave the
--- fingerprint row, which used to block re-import from a chat link.
function RL.RecipeIsKnown(fields)
    local rk = tostring(fields and fields.rk or "")
    local uid = tonumber(fields and fields.uid) or 0
    if uid <= 0 or rk == "" then
        return false
    end
    local RS = StockPiler.RecipeSpec
    if not (RS and RS.GetPotion) then
        return false
    end
    local potionKey = RS.PotionKeyFromUid and RS.PotionKeyFromUid(uid) or ("uid:" .. tostring(uid))
    local potion = RS.GetPotion(potionKey)
    if type(potion) ~= "table" then
        return false
    end
    if tostring(potion.activeRecipeKey or "") == rk
        or tostring(potion.activeRecipeSpecKey or "") == rk
        or tostring(potion.recipeSpecKey or "") == rk
    then
        return true
    end
    if type(potion.recipeKeys) == "table" then
        for i = 1, #potion.recipeKeys do
            if tostring(potion.recipeKeys[i]) == rk then
                return true
            end
        end
    end
    return false
end

--- Collect share fields from a Potions or Watch list row.
function RL.FieldsFromRow(data)
    if type(data) ~= "table" then
        return nil
    end
    if data.kind == "plant" or data.isPlantWatch == true then
        return nil
    end
    if data.skillUp == true or data.upgradeWatch == true or data.addonOwned == true then
        return nil
    end
    local uid = tonumber(data.uniqueID) or tonumber(data.outputUid) or 0
    local watchKey = tostring(data.potionRecipeKey or data.potionKey or data.id or "")
    local rk = tostring(data.recipeSpecKey or "")
    local RS = StockPiler.RecipeSpec
    if watchKey ~= "" and RS and RS.ParsePotionRecipeKey then
        local parsed = RS.ParsePotionRecipeKey(watchKey)
        if type(parsed) == "table" then
            if uid <= 0 then
                uid = tonumber(parsed.outputUid) or 0
            end
            if rk == "" and parsed.recipeSpecKey then
                rk = tostring(parsed.recipeSpecKey)
            end
        end
    end
    if uid <= 0 then
        return nil
    end

    local name = data.baseName or data.name
    local icon = tonumber(data.iconNum) or 0
    if icon <= 0 and RS and RS.GetPotion then
        local potion = RS.GetPotion(watchKey)
        if type(potion) == "table" then
            if name == nil or ToNarrow(name) == "" then
                name = potion.name
            end
            icon = tonumber(potion.iconNum) or icon
        end
    end

    local fields = {
        uid = uid,
        rk = rk,
        name = name,
        icon = icon,
    }
    return AttachSlotsFromKnowledge(fields)
end

function RL.ShareFields(fields)
    fields = type(fields) == "table" and fields or nil
    if fields == nil then
        Print(T("link.empty"))
        return false
    end
    fields = AttachSlotsFromKnowledge(fields)
    local slotsEnc = ""
    if type(fields.slots) == "table" then
        slotsEnc = RL.EncodeSlots(fields.slots)
    end
    if slotsEnc == "" then
        Print(T("link.share_no_slots"))
        return false
    end
    local linkData = RL.BuildLinkData(fields)
    if linkData == nil then
        Print(T("link.empty"))
        return false
    end
    local narrow = ToNarrow(linkData)
    if string.len(narrow) > RL.LINK_MAX_DATA then
        Print(T("link.too_long"))
        return false
    end
    -- Refuse truncated shares that lost materials (should not happen after reorder).
    if string.find(narrow, "slots=", 1, true) == nil then
        Print(T("link.share_no_slots"))
        return false
    end
    if type(CreateHyperLink) ~= "function" or type(EA_ChatWindow) ~= "table"
        or type(EA_ChatWindow.InsertText) ~= "function"
    then
        Print(T("link.no_chat"))
        return false
    end
    local linkText = T("link.chat_label_named", { name = RL.DisplayName(fields) })
    local doneLink = CreateHyperLink(linkData, linkText, RL.LINK_COLOR, {})
    EA_ChatWindow.InsertText(doneLink)
    local key = RL.WatchKeyFromFields(fields)
    if key then
        RL._lastShareKey = key
    end
    return true
end

function RL.ShareFromRow(data)
    local fields = RL.FieldsFromRow(data)
    if fields == nil then
        Print(T("link.empty"))
        return false
    end
    return RL.ShareFields(fields)
end

function RL.ShareWatchKey(watchKey)
    watchKey = tostring(watchKey or "")
    if watchKey == "" then
        Print(T("link.empty"))
        return false
    end
    local RS = StockPiler.RecipeSpec
    local parsed = RS and RS.ParsePotionRecipeKey and RS.ParsePotionRecipeKey(watchKey) or nil
    local uid = type(parsed) == "table" and tonumber(parsed.outputUid) or 0
    local rk = type(parsed) == "table" and tostring(parsed.recipeSpecKey or "") or ""
    if uid <= 0 then
        Print(T("link.empty"))
        return false
    end
    local name = nil
    local icon = 0
    if RS and RS.GetPotion then
        local potion = RS.GetPotion(parsed.potionKey or watchKey)
        if type(potion) == "table" then
            name = potion.name
            icon = tonumber(potion.iconNum) or 0
        end
    end
    local fakeRow = {
        potionRecipeKey = watchKey,
        uniqueID = uid,
        recipeSpecKey = rk,
        name = name,
        iconNum = icon,
    }
    return RL.ShareFromRow(fakeRow)
end

local function AfterPotionImport()
    if StockPiler.Knowledge and StockPiler.Knowledge.Touch then
        pcall(StockPiler.Knowledge.Touch, "recipe-link")
    end
    if StockPiler.PlanSnapshot and StockPiler.PlanSnapshot.Invalidate then
        pcall(StockPiler.PlanSnapshot.Invalidate)
    end
    local Sch = StockPiler.Scheduler
    if Sch and Sch.EnqueuePlanRebuild then
        pcall(Sch.EnqueuePlanRebuild, { nudge = true })
    end
    if StockPiler.Ui and StockPiler.Ui.RefreshCatalogRows then
        pcall(StockPiler.Ui.RefreshCatalogRows)
    end
    if StockPilerTabPotions and StockPilerTabPotions.Refresh then
        pcall(StockPilerTabPotions.Refresh)
    end
    if StockPilerTabWatch and StockPilerTabWatch.Refresh then
        pcall(StockPilerTabWatch.Refresh)
    end
end

local function ShowPotionsTab()
    if StockPiler.Ui and StockPiler.Ui.ShowWindow then
        local tab = StockPilerWindow and StockPilerWindow.TABS_POTIONS or 1
        StockPiler.Ui.ShowWindow(tab)
    end
end

--- Import linked recipe into Known Potions when not already known.
--- Returns: "known" | "imported" | "noslots" | "failed"
function RL.ImportKnownPotion(fields)
    fields = type(fields) == "table" and fields or nil
    if fields == nil then
        return "failed"
    end
    local uid = tonumber(fields.uid) or 0
    if uid <= 0 then
        return "failed"
    end
    if RL.RecipeIsKnown(fields) then
        return "known"
    end

    local slots = fields.slots
    if type(slots) ~= "table" or #slots < 1 then
        if fields.slotsEncoded then
            slots = RL.DecodeSlots(fields.slotsEncoded)
        end
    end
    -- Legacy / truncated links: reuse local fingerprint slots if Forget left them.
    if (type(slots) ~= "table" or #slots < 1) and tostring(fields.rk or "") ~= "" then
        slots = RecipeSlotsByKey(fields.rk)
        if type(slots) == "table" then
            fields.slots = slots
        end
    end
    if type(slots) ~= "table" or #slots < 1 then
        return "noslots"
    end

    local rk = tostring(fields.rk or "")
    local RS = StockPiler.RecipeSpec
    -- Prefer fingerprint from payload; else rebuild from slots when RecipeSpec can.
    if rk == "" and RS and RS.RecipeSpecKey then
        rk = tostring(RS.RecipeSpecKey(slots) or "")
        fields.rk = rk
    end
    if rk == "" then
        return "failed"
    end

    local Know = StockPiler.Knowledge
    local recipes = Know and Know.Recipes and Know.Recipes() or nil
    if type(recipes) ~= "table" then
        return "failed"
    end

    local recipe = recipes[rk]
    if type(recipe) ~= "table" then
        recipe = {
            recipeSpecKey = rk,
            slots = slots,
            outcomes = {},
            brewAttempts = 0,
            brewSuccesses = 0,
            brewCrits = 0,
            brewSuperCrits = 0,
            brewFailures = 0,
            brewVolatiles = 0,
            yieldProductSum = 0,
            yieldSamples = 0,
            crafts = 0,
            quality = "good",
            activeOutcomeUid = uid,
            outputUid = uid,
            sharedImport = true,
        }
        recipes[rk] = recipe
    else
        -- Re-import after Forget: refresh slots from the link when present.
        if type(slots) == "table" and #slots > 0 then
            recipe.slots = slots
        end
    end
    if type(recipe.outcomes) ~= "table" then
        recipe.outcomes = {}
    end
    local ocKey = tostring(uid)
    if type(recipe.outcomes[ocKey]) ~= "table" then
        recipe.outcomes[ocKey] = { uid = uid, samples = 1, qtySum = 1, quality = "good" }
    end
    recipe.activeOutcomeUid = tonumber(recipe.activeOutcomeUid) or uid
    recipe.outputUid = tonumber(recipe.outputUid) or uid

    local out = {
        uniqueID = uid,
        name = fields.name and ToW(SanitizeName(fields.name)) or nil,
        iconNum = tonumber(fields.icon) or 0,
    }
    if RS and RS.RegisterKnownPotion then
        RS.RegisterKnownPotion(uid, out, rk, "good", nil)
    else
        return "failed"
    end
    if RS and RS.SlimRecipeForStorage and type(recipes[rk]) == "table" then
        pcall(RS.SlimRecipeForStorage, recipes[rk])
    end
    AfterPotionImport()
    return "imported"
end

--- Click /stp apply: import to Known Potions only (no watch create).
function RL.OpenLinkedRecipe(fields)
    fields = type(fields) == "table" and fields or nil
    if fields == nil then
        Print(T("link.bad_payload"))
        return false
    end
    local name = RL.DisplayName(fields)
    local result = RL.ImportKnownPotion(fields)
    ShowPotionsTab()
    if result == "known" then
        Print(T("link.already_known", { name = name }))
        return true
    end
    if result == "imported" then
        Print(T("link.imported", { name = name }))
        return true
    end
    if result == "noslots" then
        Print(T("link.need_slots", { name = name }))
        return false
    end
    Print(T("link.import_failed", { name = name }))
    return false
end

function RL.ShowContextMenuForRow(data)
    data = type(data) == "table" and data or nil
    local fields = RL.FieldsFromRow(data)
    if fields == nil then
        return false
    end
    local key = RL.WatchKeyFromFields(fields)
    if key then
        RL._lastShareKey = key
    end
    RL._contextFields = fields
    if type(EA_Window_ContextMenu) ~= "table"
        or type(EA_Window_ContextMenu.CreateContextMenu) ~= "function"
    then
        return RL.ShareFields(fields)
    end
    local anchor = SystemData and SystemData.ActiveWindow and SystemData.ActiveWindow.name
    EA_Window_ContextMenu.CreateContextMenu(anchor or "StockPilerWindow")
    EA_Window_ContextMenu.AddMenuItem(
        T("link.menu_link"),
        RL.OnContextLinkInChat,
        false,
        true
    )
    EA_Window_ContextMenu.Finalize()
    return true
end

function RL.OnContextLinkInChat()
    local fields = RL._contextFields
    RL._contextFields = nil
    if type(fields) ~= "table" then
        Print(T("link.empty"))
        return
    end
    RL.ShareFields(fields)
end

local function OnHyperLinkLButtonUp(linkData, flags, x, y)
    local parsed = RL.ParseLinkData(linkData)
    if parsed ~= nil then
        RL.OpenLinkedRecipe(parsed)
        return
    end
    if RL._prevOnHyperLinkLButtonUp then
        RL._prevOnHyperLinkLButtonUp(linkData, flags, x, y)
    end
end

function RL.InstallHyperlinkHook()
    if RL._hyperlinkHooked then
        return
    end
    if type(EA_ChatWindow) ~= "table" or type(EA_ChatWindow.OnHyperLinkLButtonUp) ~= "function" then
        return
    end
    RL._prevOnHyperLinkLButtonUp = EA_ChatWindow.OnHyperLinkLButtonUp
    EA_ChatWindow.OnHyperLinkLButtonUp = OnHyperLinkLButtonUp
    RL._hyperlinkHooked = true
end

function RL.UninstallHyperlinkHook()
    if not RL._hyperlinkHooked then
        return
    end
    if type(EA_ChatWindow) == "table" and RL._prevOnHyperLinkLButtonUp ~= nil then
        EA_ChatWindow.OnHyperLinkLButtonUp = RL._prevOnHyperLinkLButtonUp
    end
    RL._prevOnHyperLinkLButtonUp = nil
    RL._hyperlinkHooked = false
end

function RL.Initialize()
    RL.InstallHyperlinkHook()
end

function RL.Shutdown()
    RL.UninstallHyperlinkHook()
    RL._contextFields = nil
end
