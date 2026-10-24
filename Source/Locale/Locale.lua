----------------------------------------------------------------
-- StockPiler Locale -- keyed phrases + named {token} substitution
-- Catalog values must be L"..." wstrings with ASCII punctuation for chat.
----------------------------------------------------------------

StockPiler = StockPiler or {}
StockPiler.Locale = StockPiler.Locale or {}

local Locale = StockPiler.Locale
Locale.Packs = Locale.Packs or {}
Locale._langId = nil
Locale._pack = nil

local function EnglishLangId()
    if SystemData and SystemData.Settings and SystemData.Settings.Language
        and SystemData.Settings.Language.ENGLISH ~= nil
    then
        return SystemData.Settings.Language.ENGLISH
    end
    return 1
end

local function ActiveGameLangId()
    if SystemData and SystemData.Settings and SystemData.Settings.Language
        and SystemData.Settings.Language.active ~= nil
    then
        return SystemData.Settings.Language.active
    end
    return EnglishLangId()
end

local function EnglishPack()
    return Locale.Packs[EnglishLangId()]
end

local function CoerceWString(val)
    if val == nil then
        return L""
    end
    if type(val) == "wstring" then
        return val
    end
    if type(val) == "string" then
        return towstring(val)
    end
    return towstring(tostring(val))
end

--- A replacement string treats % as a capture marker. Double each percent so
--- "%2" and a trailing "%" stay literal text instead of raising
--- "invalid capture index".
local function LiteralReplacement(value)
    value = CoerceWString(value)
    return wstring.gsub(value, L"%%", L"%%%%")
end

local function ApplyTokens(template, tokens)
    if type(template) ~= "wstring" then
        template = CoerceWString(template)
    end
    if type(tokens) ~= "table" then
        return template
    end
    local out = template
    for name, value in pairs(tokens) do
        local key = tostring(name or "")
        if key ~= "" then
            local needle = L"{" .. towstring(key) .. L"}"
            out = wstring.gsub(out, needle, LiteralReplacement(value))
        end
    end
    return out
end

--- id: SystemData.Settings.Language.* or 0/nil for game language (auto).
function Locale.SetLanguage(id)
    id = tonumber(id) or 0
    if id <= 0 then
        id = ActiveGameLangId()
    end
    local pack = Locale.Packs[id]
    if type(pack) ~= "table" then
        pack = EnglishPack()
        id = EnglishLangId()
    end
    Locale._langId = id
    Locale._pack = pack
    return id
end

function Locale.ResolveTemplate(key)
    key = tostring(key or "")
    if key == "" then
        return nil
    end
    local pack = Locale._pack
    if type(pack) ~= "table" then
        Locale.SetLanguage(0)
        pack = Locale._pack
    end
    -- Packs are wstrings in game. A plain string is accepted so a rewritten
    -- catalog (and any already-narrow template) still substitutes tokens.
    if type(pack) == "table" and (type(pack[key]) == "wstring" or type(pack[key]) == "string") then
        return pack[key]
    end
    local en = EnglishPack()
    if type(en) == "table" and (type(en[key]) == "wstring" or type(en[key]) == "string") then
        return en[key]
    end
    return nil
end

function Locale.Format(key, tokens)
    local template = Locale.ResolveTemplate(key)
    if template == nil then
        return L"[" .. CoerceWString(key) .. L"]"
    end
    return ApplyTokens(template, tokens)
end

function StockPiler.T(key, tokens)
    return Locale.Format(key, tokens)
end

function Locale.Initialize()
    local lang = 0
    if StockPiler.Persistence and StockPiler.Persistence.EnsureSettings then
        local s = StockPiler.Persistence.EnsureSettings()
        if type(s) == "table" then
            if s.language == nil then
                s.language = 0
            end
            lang = tonumber(s.language) or 0
        end
    end
    Locale.SetLanguage(lang)
end
