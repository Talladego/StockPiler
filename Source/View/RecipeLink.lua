----------------------------------------------------------------
-- StockPiler RecipeLink -- chat share / import for known potions
-- Plain payload (paste-safe). New shares omit the fingerprint (rk);
-- import recomputes it from the slots. Order:
--   POTION;uid=<n>;icon=<n>;n=<name>;d=<details>;slots=<encoded>
-- d= is optional item names and icons (uid,icon,name rows joined with ~).
-- It is dropped first when the link is too long. Absent d= still imports.
-- Slot rows (legacy rows stop before effectId):
--   role:uid:perCraft:power:stability:duration:tradeSkill:skillLevel:cult:slotType:effectId:bonuses
-- joined with ~ . bonuses is ref=value pairs separated by commas,
-- including a present zero (1=0). Refs the fingerprint ignores are omitted.
-- Older links may join slots with ^; those still import when the carets survived.
-- A link is a recipe only when it has a main slot and a container slot.
-- Sharing refuses a saved recipe that lacks either one.
-- Other roles may repeat. The apothecary already loads more than one of those.
-- Hyperlink linkData: StockPiler: + plain payload
-- Click and /stp apply open a preview. Learn imports into Known Potions.
-- Existing recipes, potion names, and the active recipe are not modified.
----------------------------------------------------------------

StockPiler = StockPiler or {}
StockPiler.RecipeLink = StockPiler.RecipeLink or {}
local RL = StockPiler.RecipeLink

RL.LINK_PREFIX = L"StockPiler:"
RL.LINK_COLOR = { 80, 200, 255 }
RL.LINK_MAX_DATA = 3500
RL.CHAT_MAX_CHARS = 4096
RL.CHAT_EDIT_BOX = "EA_TextEntryGroupEntryBoxTextInput"
RL.MAX_SLOTS = 8
RL.RK_MAX = 1024

RL._lastShareKey = nil
RL._hyperlinkHooked = false
RL._prevOnHyperLinkLButtonUp = nil
RL._contextFields = nil

local ID_MAX = 9999999999
local STAT_ABS = 100000
local MAX_PER_CRAFT = 99
local MAX_SKILL = 300
local MAX_SMALL = 64
local MAX_BONUS_REF = 30
local MAX_BONUS_PAIRS = 16
local MAX_BONUS_TAIL = 480

local ROLE_OK = {
    container = true,
    main = true,
    stabilizer = true,
    goldweed = true,
    extender = true,
    multiplier = true,
    stimulant = true,
    ingredient = true,
}

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
    -- WAR appends a grammar suffix (^n and similar). Drop the whole suffix the
    -- same way character keys do, or only the caret is removed and the letters stay.
    if string.len(name) >= 2 and string.sub(name, -2, -2) == "^" then
        name = string.sub(name, 1, -3)
    end
    name = string.gsub(name, "%^.*$", "")
    name = string.gsub(name, '[<>"&;%[%]^=%c]', "")
    name = string.gsub(name, "%s+", " ")
    name = string.gsub(name, "^%s+", "")
    name = string.gsub(name, "%s+$", "")
    if string.len(name) > 48 then
        name = string.sub(name, 1, 48)
    end
    return name
end

--- Incoming names: reject markup and payload delimiters. Empty is allowed.
local function ValidName(name)
    name = ToNarrow(name)
    if name == "" then
        return ""
    end
    if string.len(name) > 48 then
        return nil
    end
    if string.match(name, '[<>"&;%[%]^=%c]') ~= nil then
        return nil
    end
    return name
end

--- Decimal integer only. Rejects hex, inf, nan, and exponent forms.
local function StrictInt(raw, minV, maxV, allowNeg)
    raw = ToNarrow(raw)
    if raw == "" then
        return nil
    end
    local neg = false
    local digits = raw
    if string.sub(raw, 1, 1) == "-" then
        if allowNeg ~= true then
            return nil
        end
        neg = true
        digits = string.sub(raw, 2)
    end
    if digits == "" or string.match(digits, "^%d+$") == nil then
        return nil
    end
    if string.len(digits) > 10 then
        return nil
    end
    local n = tonumber(digits)
    if n == nil or n ~= n or n == math.huge then
        return nil
    end
    if neg then
        n = -n
    end
    if n < minV or n > maxV then
        return nil
    end
    return n
end

local function AsInt(n)
    if type(n) == "string" then
        local body = n
        if string.sub(n, 1, 1) == "-" then
            body = string.sub(n, 2)
        end
        if body == "" or string.match(n, "^%-?%d+$") == nil or string.len(body) > 10 then
            return nil
        end
    elseif type(n) ~= "number" then
        return nil
    end
    n = tonumber(n)
    if n == nil or n ~= n or n == math.huge or n == -math.huge then
        return nil
    end
    if n ~= math.floor(n) then
        return nil
    end
    return n
end

local function ValidRk(rk)
    if rk == nil then
        return ""
    end
    rk = ToNarrow(rk)
    if rk == "" then
        return ""
    end
    if string.len(rk) > RL.RK_MAX then
        return nil
    end
    if string.match(rk, "^[%w|:,=_.%-]+$") == nil then
        return nil
    end
    return rk
end

local function SplitColon(piece)
    local parts = {}
    local startAt = 1
    local n = string.len(piece)
    for i = 1, n do
        if string.sub(piece, i, i) == ":" then
            parts[#parts + 1] = string.sub(piece, startAt, i - 1)
            startAt = i + 1
        end
    end
    parts[#parts + 1] = string.sub(piece, startAt)
    return parts
end

local function BonusNumber(spec, ref)
    if type(spec) ~= "table" or type(spec.bonuses) ~= "table" then
        return nil
    end
    local v = spec.bonuses[ref]
    if v == nil then
        v = spec.bonuses[tostring(ref)]
    end
    if type(v) == "table" then
        v = v[1]
    end
    return AsInt(v)
end

local function FieldInt(value, default, minV, maxV)
    if value == nil then
        return default
    end
    local n = AsInt(value)
    if n == nil or n < minV or n > maxV then
        return nil
    end
    return n
end

--- Prefer a bonus ref when it is present. A present but illegal value fails the share.
local function StatForEncode(spec, ref, field)
    if type(spec.bonuses) == "table" and (spec.bonuses[ref] ~= nil or spec.bonuses[tostring(ref)] ~= nil) then
        return BonusNumber(spec, ref)
    end
    if field == nil then
        return 0
    end
    return AsInt(field)
end

--- True when MS.Key omits this crafting-bonus ref (family, type, destroy-on-fail).
local function FingerprintIgnoresRef(ref)
    local ME = StockPiler.MaterialExceptions
    if ME and ME.ShouldIgnoreBonusRef then
        return ME.ShouldIgnoreBonusRef(ref) == true
    end
    return false
end

local function EncodeBonusTail(spec)
    if type(spec) ~= "table" or type(spec.bonuses) ~= "table" then
        return ""
    end
    local refs = {}
    local seen = {}
    for ref, val in pairs(spec.bonuses) do
        local nref = AsInt(ref)
        if nref == nil or nref < 1 or nref > MAX_BONUS_REF then
            return nil
        end
        if FingerprintIgnoresRef(nref) then
            -- Shorten the link. The recomputed fingerprint does not use this ref.
        elseif seen[nref] ~= true then
            local nval = val
            if type(nval) == "table" then
                nval = nval[1]
            end
            nval = AsInt(nval)
            if nval == nil or nval < -ID_MAX or nval > ID_MAX then
                return nil
            end
            -- A present zero (stability 0 on a stimulant) is part of the fingerprint.
            seen[nref] = true
            refs[#refs + 1] = nref
        end
    end
    table.sort(refs)
    if #refs > MAX_BONUS_PAIRS then
        return nil
    end
    local parts = {}
    for i = 1, #refs do
        local nref = refs[i]
        local nval = BonusNumber(spec, nref) or 0
        parts[#parts + 1] = tostring(nref) .. "=" .. tostring(nval)
    end
    return table.concat(parts, ",")
end

local function ParseBonusTail(tail)
    if tail == nil or tail == "" then
        return {}
    end
    if string.len(tail) > MAX_BONUS_TAIL then
        return nil
    end
    if string.sub(tail, 1, 1) == "," or string.sub(tail, -1) == "," or string.find(tail, ",,", 1, true) then
        return nil
    end
    local bonuses = {}
    local count = 0
    for pair in string.gmatch(tail, "[^,]+") do
        local rs, vs = string.match(pair, "^(%d+)=(%-?%d+)$")
        if rs == nil then
            return nil
        end
        local ref = StrictInt(rs, 1, MAX_BONUS_REF, false)
        local val = StrictInt(vs, -ID_MAX, ID_MAX, true)
        if ref == nil or val == nil or bonuses[ref] ~= nil then
            return nil
        end
        count = count + 1
        if count > MAX_BONUS_PAIRS then
            return nil
        end
        bonuses[ref] = val
    end
    return bonuses
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
--- Returns nil when a slot is not safe to share.
function RL.EncodeSlots(slots)
    if type(slots) ~= "table" or #slots < 1 then
        return ""
    end
    if #slots > RL.MAX_SLOTS then
        return nil
    end
    local parts = {}
    for i = 1, #slots do
        local slot = slots[i]
        if type(slot) ~= "table" then
            return nil
        end
        local spec = type(slot.spec) == "table" and slot.spec or slot
        local role = tostring(slot.role or spec.role or "")
        if ROLE_OK[role] ~= true then
            return nil
        end
        local uid = AsInt(slot.uid or spec.uid)
        if uid == nil or uid < 1 or uid > ID_MAX then
            return nil
        end
        local pcRaw = slot.perCraft
        if pcRaw == nil then
            pcRaw = 1
        end
        local pc = AsInt(pcRaw)
        if pc == nil or pc < 1 or pc > MAX_PER_CRAFT then
            return nil
        end
        local power = StatForEncode(spec, 2, spec.power)
        local stab = StatForEncode(spec, 1, spec.stability)
        local dur = StatForEncode(spec, 3, spec.duration)
        if power == nil or stab == nil or dur == nil
            or power < -STAT_ABS or power > STAT_ABS
            or stab < -STAT_ABS or stab > STAT_ABS
            or dur < -STAT_ABS or dur > STAT_ABS
        then
            return nil
        end
        local ts = FieldInt(spec.tradeSkill, 0, 0, MAX_SMALL)
        local sl = FieldInt(spec.skillLevel, 0, 0, MAX_SKILL)
        local cult = FieldInt(spec.cultivationType, 0, 0, MAX_SMALL)
        local slotType = FieldInt(spec.slotType, 0, 0, MAX_SMALL)
        if ts == nil or sl == nil or cult == nil or slotType == nil then
            return nil
        end
        local effect = AsInt(spec.effectId)
        if effect == nil then
            effect = BonusNumber(spec, 6) or 0
        end
        if effect < 0 or effect > ID_MAX then
            return nil
        end
        local tail = EncodeBonusTail(spec)
        if tail == nil then
            return nil
        end
        parts[#parts + 1] = table.concat({
            role,
            tostring(uid),
            tostring(pc),
            tostring(power),
            tostring(stab),
            tostring(dur),
            tostring(ts),
            tostring(sl),
            tostring(cult),
            tostring(slotType),
            tostring(effect),
            tail,
        }, ":")
    end
    -- "~" is safe in chat. "^" starts a grammar suffix and the client strips it.
    return table.concat(parts, "~")
end

local function DecodeOneSlot(piece)
    local parts = SplitColon(piece)
    local n = #parts
    if n ~= 10 and n ~= 11 and n ~= 12 then
        return nil
    end
    local role = parts[1]
    if ROLE_OK[role] ~= true then
        return nil
    end
    local uid = StrictInt(parts[2], 1, ID_MAX, false)
    local pc = StrictInt(parts[3], 1, MAX_PER_CRAFT, false)
    local power = StrictInt(parts[4], -STAT_ABS, STAT_ABS, true)
    local stab = StrictInt(parts[5], -STAT_ABS, STAT_ABS, true)
    local dur = StrictInt(parts[6], -STAT_ABS, STAT_ABS, true)
    local ts = StrictInt(parts[7], 0, MAX_SMALL, false)
    local sl = StrictInt(parts[8], 0, MAX_SKILL, false)
    local cult = StrictInt(parts[9], 0, MAX_SMALL, false)
    local slotType = StrictInt(parts[10], 0, MAX_SMALL, false)
    if uid == nil or pc == nil or power == nil or stab == nil or dur == nil
        or ts == nil or sl == nil or cult == nil or slotType == nil
    then
        return nil
    end
    local effect = 0
    if n >= 11 then
        effect = StrictInt(parts[11], 0, ID_MAX, false)
        if effect == nil then
            return nil
        end
    end
    local extra = {}
    if n >= 12 then
        extra = ParseBonusTail(parts[12])
        if extra == nil then
            return nil
        end
    end
    local bonuses = {}
    for ref, val in pairs(extra) do
        bonuses[ref] = val
    end
    -- Legacy rows have no bonus tail. A non-zero column is a present stat.
    -- Zero stays absent unless the tail carried it (1=0).
    if bonuses[2] == nil and power ~= 0 then
        bonuses[2] = power
    end
    if bonuses[1] == nil and stab ~= 0 then
        bonuses[1] = stab
    end
    if bonuses[3] == nil and dur ~= 0 then
        bonuses[3] = dur
    end
    local spec = {
        uid = uid,
        role = role,
        power = power,
        stability = stab,
        duration = dur,
        tradeSkill = ts,
        skillLevel = sl,
        cultivationType = cult,
        slotType = slotType,
    }
    if effect > 0 then
        spec.effectId = effect
    end
    if next(bonuses) ~= nil then
        spec.bonuses = bonuses
    end
    return {
        role = role,
        uid = uid,
        perCraft = pc,
        spec = spec,
    }
end

--- Decode slots= payload into slim slot tables.
--- Any bad slot rejects the whole payload.
function RL.DecodeSlots(encoded)
    encoded = ToNarrow(encoded)
    if encoded == "" then
        return nil
    end
    -- New shares use "~". Intact legacy links still use "^". Neither character
    -- appears inside a slot: fields are a role word, integers, or ref=value pairs.
    local function isSep(index)
        local ch = string.sub(encoded, index, index)
        return ch == "~" or ch == "^"
    end
    local n = string.len(encoded)
    if isSep(1) or isSep(n) then
        return nil
    end
    for i = 1, n - 1 do
        if isSep(i) and isSep(i + 1) then
            return nil
        end
    end
    local slots = {}
    local count = 0
    for piece in string.gmatch(encoded, "[^~%^]+") do
        count = count + 1
        if count > RL.MAX_SLOTS then
            return nil
        end
        local entry = DecodeOneSlot(piece)
        if entry == nil then
            return nil
        end
        slots[#slots + 1] = entry
    end
    if #slots < 1 then
        return nil
    end
    return slots
end

--- True when the slots are a brew: the container slot and the main slot.
--- Extra roles may repeat. Those share the ingredient slots, and saved recipes
--- already keep more than one of them. This does not add a uniqueness rule.
local function SlotsHaveMainAndContainer(slots)
    if type(slots) ~= "table" then
        return false
    end
    local mains = 0
    local containers = 0
    for i = 1, #slots do
        local slot = slots[i]
        local role = type(slot) == "table" and tostring(slot.role or "") or ""
        if role == "main" then
            mains = mains + 1
        elseif role == "container" then
            containers = containers + 1
        end
    end
    return mains >= 1 and containers >= 1
end

function RL.HasMainAndContainer(slots)
    return SlotsHaveMainAndContainer(slots) == true
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

local function KnownItemRow(uid)
    local Items = StockPiler.Items
    if not Items or uid == nil then
        return nil
    end
    if Items.GetByUid then
        local row = Items.GetByUid(uid)
        if type(row) == "table" then
            return row
        end
    end
    if Items.AsItemData then
        local row = Items.AsItemData(uid)
        if type(row) == "table" then
            return row
        end
    end
    return nil
end

local function ItemToken(uid, icon, name)
    uid = AsInt(uid)
    if uid == nil or uid < 1 or uid > ID_MAX then
        return nil
    end
    icon = AsInt(icon) or 0
    if icon < 0 or icon > ID_MAX then
        icon = 0
    end
    name = SanitizeName(name)
    name = string.gsub(name, "[:~|,]", " ")
    name = string.gsub(name, "%s+", " ")
    name = string.gsub(name, "^%s+", "")
    name = string.gsub(name, "%s+$", "")
    return tostring(uid) .. "," .. tostring(icon) .. "," .. name
end

--- Optional item names and icons. Slots already carry role, quantity, and bonuses.
--- "~" joins rows. "^" is never used; chat would strip it.
function RL.EncodeItemDetails(potionUid, potionIcon, potionName, slots)
    local seen = {}
    local parts = {}
    local function add(uid, icon, name)
        uid = AsInt(uid)
        if uid == nil or seen[uid] == true then
            return
        end
        local known = KnownItemRow(uid)
        if type(known) == "table" then
            if (icon == nil or icon == 0) and tonumber(known.iconNum) then
                icon = tonumber(known.iconNum)
            end
            if (name == nil or ToNarrow(name) == "") and known.name ~= nil then
                name = known.name
            end
        end
        local token = ItemToken(uid, icon, name)
        if token == nil then
            return
        end
        seen[uid] = true
        parts[#parts + 1] = token
    end
    add(potionUid, potionIcon, potionName)
    if type(slots) == "table" then
        for i = 1, #slots do
            local slot = slots[i]
            if type(slot) == "table" then
                local spec = type(slot.spec) == "table" and slot.spec or slot
                add(slot.uid or spec.uid, spec.iconNum or slot.iconNum, spec.name or slot.name)
            end
        end
    end
    return table.concat(parts, "~")
end

function RL.DecodeItemDetails(encoded)
    encoded = ToNarrow(encoded)
    if encoded == "" then
        return nil
    end
    if string.find(encoded, "^", 1, true) ~= nil then
        return nil
    end
    if string.sub(encoded, 1, 1) == "~" or string.sub(encoded, -1) == "~" then
        return nil
    end
    if string.find(encoded, "~~", 1, true) ~= nil then
        return nil
    end
    local details = {}
    local count = 0
    for piece in string.gmatch(encoded, "[^~]+") do
        count = count + 1
        if count > RL.MAX_SLOTS + 1 then
            return nil
        end
        local uidRaw, iconRaw, name = string.match(piece, "^(%d+),(%d+),(.*)$")
        local uid = StrictInt(uidRaw, 1, ID_MAX, false)
        local icon = StrictInt(iconRaw, 0, ID_MAX, false)
        if uid == nil or icon == nil or details[uid] ~= nil then
            return nil
        end
        name = ValidName(name)
        if name == nil then
            return nil
        end
        details[uid] = { uid = uid, icon = icon, name = name }
    end
    if count < 1 then
        return nil
    end
    return details
end

--- Serialize a potion share. fields: uid, name, icon, slots?
--- The fingerprint is not included; import recomputes it.
function RL.SerializePlain(fields)
    if type(fields) ~= "table" then
        return nil
    end
    local uid = AsInt(fields.uid)
    if uid == nil or uid < 1 or uid > ID_MAX then
        return nil
    end
    fields = AttachSlotsFromKnowledge(fields)
    local icon = AsInt(fields.icon or fields.iconNum) or 0
    if icon < 0 or icon > ID_MAX then
        icon = 0
    end
    local name = SanitizeName(fields.name)
    local slotsEnc = ""
    if type(fields.slots) == "table" then
        slotsEnc = RL.EncodeSlots(fields.slots)
        if slotsEnc == nil then
            return nil
        end
    elseif type(fields.slotsEncoded) == "string" and fields.slotsEncoded ~= "" then
        local decoded = RL.DecodeSlots(fields.slotsEncoded)
        if decoded == nil then
            return nil
        end
        fields.slots = decoded
        -- Re-emit so a legacy "^" payload is not copied into a new share.
        slotsEnc = RL.EncodeSlots(decoded)
        if slotsEnc == nil or slotsEnc == "" then
            return nil
        end
    end
    local detailsEnc = RL.EncodeItemDetails(uid, icon, name, fields.slots)

    local function build(includeName, includeIcon, includeDetails)
        local parts = {
            "POTION",
            "uid=" .. tostring(uid),
        }
        if includeIcon and icon > 0 then
            parts[#parts + 1] = "icon=" .. tostring(icon)
        end
        if includeName and name ~= "" then
            parts[#parts + 1] = "n=" .. name
        end
        if includeDetails and detailsEnc ~= "" then
            parts[#parts + 1] = "d=" .. detailsEnc
        end
        if slotsEnc ~= "" then
            parts[#parts + 1] = "slots=" .. slotsEnc
        end
        return table.concat(parts, ";")
    end

    local plain = build(true, true, true)
    if string.len("StockPiler:" .. plain) > RL.LINK_MAX_DATA then
        plain = build(true, true, false)
    end
    if string.len("StockPiler:" .. plain) > RL.LINK_MAX_DATA then
        plain = build(true, false, false)
    end
    if string.len("StockPiler:" .. plain) > RL.LINK_MAX_DATA then
        plain = build(false, false, false)
    end
    return plain
end

--- Parse plain POTION;… payload (string). Returns fields table or nil.
--- Any invalid field rejects the whole link.
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
                fields.uid = val
            elseif key == "icon" then
                fields.icon = val
            elseif key == "n" or key == "name" then
                fields.name = val
            elseif key == "rk" then
                fields.rk = val
            elseif key == "slots" then
                fields.slotsEncoded = val
            elseif key == "d" then
                fields.detailsEncoded = val
            end
        end
    end

    local uid = StrictInt(fields.uid, 1, ID_MAX, false)
    if uid == nil then
        return nil
    end
    fields.uid = uid
    if fields.icon ~= nil and tostring(fields.icon) ~= "" then
        local icon = StrictInt(fields.icon, 0, ID_MAX, false)
        if icon == nil then
            return nil
        end
        fields.icon = icon
    else
        fields.icon = nil
    end
    if fields.name ~= nil then
        local name = ValidName(fields.name)
        if name == nil then
            return nil
        end
        fields.name = name
    end
    if fields.rk ~= nil then
        local rk = ValidRk(fields.rk)
        if rk == nil then
            return nil
        end
        if rk == "" then
            fields.rk = nil
        else
            fields.rk = rk
        end
    end
    if fields.slotsEncoded ~= nil and fields.slotsEncoded ~= "" then
        fields.slots = RL.DecodeSlots(fields.slotsEncoded)
        if fields.slots == nil or SlotsHaveMainAndContainer(fields.slots) ~= true then
            return nil
        end
    end
    if fields.detailsEncoded ~= nil and fields.detailsEncoded ~= "" then
        fields.details = RL.DecodeItemDetails(fields.detailsEncoded)
        if fields.details == nil then
            return nil
        end
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

--- Fingerprint from slots. Link rk is not trusted.
function RL.ResolvedRecipeKey(fields)
    if type(fields) ~= "table" then
        return ""
    end
    local slots = fields.slots
    if (type(slots) ~= "table" or #slots < 1) and type(fields.slotsEncoded) == "string" then
        slots = RL.DecodeSlots(fields.slotsEncoded)
    end
    if type(slots) ~= "table" or #slots < 1 then
        return ""
    end
    local RS = StockPiler.RecipeSpec
    if not (RS and RS.RecipeSpecKey) then
        return ""
    end
    return tostring(RS.RecipeSpecKey(slots) or "")
end

--- True when this potion already lists the recomputed fingerprint.
function RL.RecipeIsKnown(fields)
    local uid = tonumber(fields and fields.uid) or 0
    if uid <= 0 then
        return false
    end
    local rk = RL.ResolvedRecipeKey(fields)
    if rk == "" then
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

local function RaiseChatLimit()
    if type(TextEditBoxSetMaxChars) == "function" then
        TextEditBoxSetMaxChars(RL.CHAT_EDIT_BOX, RL.CHAT_MAX_CHARS)
    end
end

local function ExistingChatText()
    if type(TextEditBoxGetText) ~= "function" then
        return ""
    end
    return ToNarrow(TextEditBoxGetText(RL.CHAT_EDIT_BOX))
end

local function ChatTextFits(text)
    local combined = string.len(ExistingChatText()) + string.len(ToNarrow(text))
    if combined > RL.CHAT_MAX_CHARS then
        Print(T("link.too_long"))
        return false
    end
    return true
end

local function ResolvedShareSlots(fields)
    if type(fields) ~= "table" then
        return nil
    end
    if type(fields.slots) == "table" and #fields.slots > 0 then
        return fields.slots
    end
    if type(fields.slotsEncoded) == "string" and fields.slotsEncoded ~= "" then
        return RL.DecodeSlots(fields.slotsEncoded)
    end
    return nil
end

local function PlainForShare(fields)
    fields = AttachSlotsFromKnowledge(fields)
    local slots = ResolvedShareSlots(fields)
    if type(slots) ~= "table" or #slots < 1 then
        Print(T("link.share_no_slots"))
        return nil
    end
    -- Same gate as import. A learned main with no container must not become a link.
    if SlotsHaveMainAndContainer(slots) ~= true then
        Print(T("link.share_need_both"))
        return nil
    end
    local plain = RL.SerializePlain(fields)
    if plain == nil or string.find(plain, "slots=", 1, true) == nil then
        Print(T("link.share_no_slots"))
        return nil
    end
    if string.len("StockPiler:" .. plain) > RL.LINK_MAX_DATA then
        Print(T("link.too_long"))
        return nil
    end
    return plain
end

function RL.ShareFields(fields)
    fields = type(fields) == "table" and fields or nil
    if fields == nil then
        Print(T("link.empty"))
        return false
    end
    local plain = PlainForShare(fields)
    if plain == nil then
        return false
    end
    if type(CreateHyperLink) ~= "function" or type(EA_ChatWindow) ~= "table"
        or type(EA_ChatWindow.InsertText) ~= "function"
    then
        Print(T("link.no_chat"))
        return false
    end
    RaiseChatLimit()
    local linkText = T("link.chat_label_named", { name = RL.DisplayName(fields) })
    local linkData = ToW("StockPiler:" .. plain)
    local doneLink = CreateHyperLink(linkData, linkText, RL.LINK_COLOR, {})
    if doneLink == nil or not ChatTextFits(doneLink) then
        if doneLink == nil then
            Print(T("link.no_chat"))
        end
        return false
    end
    EA_ChatWindow.InsertText(doneLink)
    local key = RL.WatchKeyFromFields(fields)
    if key then
        RL._lastShareKey = key
    end
    return true
end

function RL.CopyFields(fields)
    fields = type(fields) == "table" and fields or nil
    if fields == nil then
        Print(T("link.empty"))
        return false
    end
    local plain = PlainForShare(fields)
    if plain == nil then
        return false
    end
    if type(EA_ChatWindow) ~= "table" or type(EA_ChatWindow.InsertText) ~= "function" then
        Print(T("link.no_chat"))
        return false
    end
    RaiseChatLimit()
    local line = ToW("/stp apply " .. plain)
    if not ChatTextFits(line) then
        return false
    end
    EA_ChatWindow.InsertText(line)
    Print(T("link.copied"))
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
    local uid = StrictInt(fields.uid, 1, ID_MAX, false)
    if uid == nil then
        return "failed"
    end
    if fields.name ~= nil and tostring(fields.name) ~= "" then
        local name = ValidName(fields.name)
        if name == nil then
            return "failed"
        end
        fields.name = name
    end
    if fields.icon ~= nil and tostring(fields.icon) ~= "" then
        local icon = StrictInt(fields.icon, 0, ID_MAX, false)
        if icon == nil then
            return "failed"
        end
        fields.icon = icon
    end
    if fields.rk ~= nil and tostring(fields.rk) ~= "" then
        if ValidRk(fields.rk) == nil then
            return "failed"
        end
    end

    local slots = fields.slots
    if (type(slots) ~= "table" or #slots < 1) and type(fields.slotsEncoded) == "string" and fields.slotsEncoded ~= "" then
        slots = RL.DecodeSlots(fields.slotsEncoded)
        if slots == nil then
            return "failed"
        end
    end
    if type(slots) ~= "table" or #slots < 1 then
        return "noslots"
    end
    local enc = RL.EncodeSlots(slots)
    if enc == nil or enc == "" then
        return "failed"
    end
    slots = RL.DecodeSlots(enc)
    if type(slots) ~= "table" or SlotsHaveMainAndContainer(slots) ~= true then
        return "failed"
    end

    local RS = StockPiler.RecipeSpec
    if not (RS and RS.RegisterKnownPotion and RS.RecipeSpecKey) then
        return "failed"
    end
    local rk = tostring(RS.RecipeSpecKey(slots) or "")
    if rk == "" then
        return "failed"
    end
    if RL.RecipeIsKnown({ uid = uid, slots = slots }) then
        return "known"
    end

    local Know = StockPiler.Knowledge
    local recipes = Know and Know.Recipes and Know.Recipes() or nil
    if type(recipes) ~= "table" then
        return "failed"
    end

    if type(recipes[rk]) ~= "table" then
        recipes[rk] = {
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
            outputUid = uid,
            activeOutcomeUid = uid,
            sharedImport = true,
            unverified = true,
        }
        if RS and RS.SlimRecipeForStorage then
            pcall(RS.SlimRecipeForStorage, recipes[rk])
        end
    end

    local out = { uniqueID = uid }
    if fields.name ~= nil and ToNarrow(fields.name) ~= "" then
        out.name = ToW(fields.name)
    end
    local icon = tonumber(fields.icon) or 0
    if icon > 0 then
        out.iconNum = icon
    end
    RS.RegisterKnownPotion(uid, out, rk, "good", { linkImport = true })
    AfterPotionImport()
    return "imported"
end

--- Import a chat link or pasted recipe into Known Potions (no watch).
function RL.OpenLinkedRecipe(fields)
    fields = type(fields) == "table" and fields or nil
    if fields == nil then
        Print(T("link.bad_payload"))
        return false
    end
    local name = RL.DisplayName(fields)
    local result = RL.ImportKnownPotion(fields)
    if result == "known" then
        ShowPotionsTab()
        Print(T("link.already_known", { name = name }))
        return true
    end
    if result == "imported" then
        ShowPotionsTab()
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
    EA_Window_ContextMenu.AddMenuItem(
        T("link.menu_copy"),
        RL.OnContextCopyString,
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

function RL.OnContextCopyString()
    local fields = RL._contextFields
    RL._contextFields = nil
    if type(fields) ~= "table" then
        Print(T("link.empty"))
        return
    end
    RL.CopyFields(fields)
end

function RL.IsShiftFlags(flags)
    local shift = SystemData and SystemData.ButtonFlags and SystemData.ButtonFlags.SHIFT
    if shift == nil then
        return false
    end
    if flags == shift then
        return true
    end
    if type(flags) == "number" and flags ~= 0 and bit and bit.band then
        return bit.band(flags, shift) ~= 0
    end
    return false
end

--- Shift+left-click inserts the chat link. An ordinary click does nothing here.
function RL.ShareRowIfShift(data, flags)
    if RL.IsShiftFlags(flags) ~= true then
        return false
    end
    if type(data) ~= "table" then
        return false
    end
    if data.kind == "plant" or data.isPlantWatch == true or data.skillUp == true
        or data.upgradeWatch == true or data.addonOwned == true
    then
        return false
    end
    local fields = RL.FieldsFromRow(data)
    if fields == nil then
        return false
    end
    return RL.ShareFields(fields) == true
end

--- Chat click and /stp apply open the preview. Learn is the import.
function RL.PresentLinkedRecipe(fields)
    local Share = StockPiler.RecipeShare
    if Share and Share.Show then
        return Share.Show(fields) == true
    end
    return RL.OpenLinkedRecipe(fields) == true
end

function RL.OpenApply(text)
    local Share = StockPiler.RecipeShare
    if Share and Share.ShowFromPlain then
        return Share.ShowFromPlain(text) == true
    end
    local fields = RL.ParsePlain(text)
    if fields then
        return RL.OpenLinkedRecipe(fields) == true
    end
    Print(T("link.bad_payload"))
    return false
end

local function OnHyperLinkLButtonUp(linkData, flags, x, y)
    local parsed = RL.ParseLinkData(linkData)
    if parsed ~= nil then
        RL.PresentLinkedRecipe(parsed)
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
    if type(EA_ChatWindow) == "table"
        and EA_ChatWindow.OnHyperLinkLButtonUp == OnHyperLinkLButtonUp
        and RL._prevOnHyperLinkLButtonUp ~= nil
    then
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
