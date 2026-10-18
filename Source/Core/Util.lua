----------------------------------------------------------------
-- StockPiler Core/Util - shared micro-helpers (NowSec, ToNarrow, T, TryCall)
----------------------------------------------------------------

StockPiler = StockPiler or {}
StockPiler.Util = StockPiler.Util or {}
local U = StockPiler.Util

function U.NowSec()
    if type(GetGameTime) == "function" then
        local t = tonumber(GetGameTime())
        if t ~= nil then
            return t
        end
    end
    local fc = tonumber(StockPiler.FrameCounter)
    if fc ~= nil then
        return fc * 0.001
    end
    return 0
end

function U.ToNarrow(value)
    if StockPiler.Persistence and StockPiler.Persistence.ToNarrow then
        return StockPiler.Persistence.ToNarrow(value)
    end
    if value == nil then
        return ""
    end
    if type(value) == "string" then
        return value
    end
    if type(value) == "wstring" and type(WStringToString) == "function" then
        local ok, text = pcall(WStringToString, value)
        if ok and type(text) == "string" then
            return text
        end
        return ""
    end
    return tostring(value)
end

function U.T(key, tokens)
    if StockPiler.T then
        return StockPiler.T(key, tokens)
    end
    return L"[" .. towstring(tostring(key or "")) .. L"]"
end

function U.TryCall(context, fn, ...)
    if StockPiler.Debug and StockPiler.Debug.TryCall then
        return StockPiler.Debug.TryCall(context, fn, ...)
    end
    if type(fn) ~= "function" then
        return false
    end
    return pcall(fn, ...)
end

function U.TryCallQuiet(context, fn, ...)
    if StockPiler.Debug and StockPiler.Debug.TryCallQuiet then
        return StockPiler.Debug.TryCallQuiet(context, fn, ...)
    end
    if type(fn) ~= "function" then
        return false
    end
    return pcall(fn, ...)
end

function U.CharacterRow(create)
    if StockPiler.Persistence and StockPiler.Persistence.GetCharacterBucket then
        return StockPiler.Persistence.GetCharacterBucket(create ~= false)
    end
    return nil
end
