-- Named {token} substitution must replace every occurrence.
-- wstring.gsub returns (result, count) and accepts an optional 4th arg n.
-- A helper that forwards both values makes count the outer gsub's n:
-- count 0 replaces nothing, count 1 replaces only the first {token}.
-- Run: lua5.1 tests/locale_tokens.lua

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

local function check(cond, msg)
    checks = checks + 1
    if cond ~= true then
        failures = failures + 1
        io.stderr:write("FAIL ", msg, "\n")
    end
end

function towstring(s)
    return tostring(s)
end

SystemData = {
    Settings = {
        Language = { ENGLISH = 1, active = 1 },
    },
}

-- Same contract as the game client's wstring.gsub.
wstring = {
    gsub = function(s, pat, repl, n)
        return string.gsub(tostring(s or ""), tostring(pat or ""), repl, n)
    end,
}

local stubResult, stubCount = wstring.gsub("ab%c", "%%", "%%%%")
eq(stubResult, "ab%%c", "stub returns the escaped string")
eq(stubCount, 1, "stub returns the match count")
local limited, limitedCount = wstring.gsub("{a} {a}", "{a}", "Z", 1)
eq(limited, "Z {a}", "stub forwards n")
eq(limitedCount, 1, "stub count respects n")
local none, noneCount = wstring.gsub("{a}", "{a}", "Z", 0)
eq(none, "{a}", "stub n=0 replaces nothing")
eq(noneCount, 0, "stub n=0 count is 0")
local both = { wstring.gsub("a%b%c", "%%", "%%%%") }
eq(both[1], "a%%b%%c", "stub first value doubles every percent")
eq(both[2], 2, "stub second value is the percent count")

load_module("Source/Locale/Locale.lua")
load_module("Source/Locale/enUS.lua")
StockPiler.Locale.SetLanguage(1)

local pack = StockPiler.Locale.Packs[1]
pack["test.repeat_name"] = "{name} and {name}"
pack["test.repeat_name_3"] = "{name}|{name}|{name}"
pack["test.value"] = "Value {name} end"
pack["test.tail"] = "Ends {name}"

eq(StockPiler.T("ui.title_version", { version = "1.1.1" }), "StockPiler v1.1.1",
    "version token with no percent is replaced")
eq(StockPiler.T("tip.watch.have_target", { have = 3, target = 10 }), "Have 3 / Target 10",
    "multi-token template with no percents replaces every token")
eq(StockPiler.T("test.repeat_name", { name = "Potion" }), "Potion and Potion",
    "repeated token with no percent replaces every occurrence")
eq(StockPiler.T("test.repeat_name_3", { name = "Potion" }), "Potion|Potion|Potion",
    "three copies of a token with no percent are all replaced")
eq(StockPiler.T("test.repeat_name", { name = "A%B" }), "A%B and A%B",
    "repeated token with one percent replaces every occurrence")
eq(StockPiler.T("test.repeat_name_3", { name = "A%B" }), "A%B|A%B|A%B",
    "one percent does not stop after the first repeated token")

local okPct, imported = pcall(StockPiler.T, "link.imported", { name = "Bad %2" })
check(okPct == true, "%2 token does not throw")
eq(imported, "Added Bad %2 to Known Potions.", "%2 stays literal text")

local okHundred, forgetLine = pcall(StockPiler.T, "potions.forget_confirm", { name = "Elixir 100%" })
check(okHundred == true, "100% token does not throw")
eq(forgetLine, "Forget this learned potion recipe?\nElixir 100%", "100% stays literal text")

local okDoubled, doubledLine = pcall(StockPiler.T, "test.value", { name = "%%" })
check(okDoubled == true, "%% token does not throw")
eq(doubledLine, "Value %% end", "a value of two percent signs stays two percent signs")

local okTrail, trailLine = pcall(StockPiler.T, "test.tail", { name = "Trail%" })
check(okTrail == true, "trailing percent does not throw")
eq(trailLine, "Ends Trail%", "a trailing percent stays literal text")

local okOnly, onlyLine = pcall(StockPiler.T, "test.value", { name = "%" })
check(okOnly == true, "a lone percent does not throw")
eq(onlyLine, "Value % end", "a lone percent stays literal text")

eq(StockPiler.T("share.slot_line", { qty = "1", role = "main", name = "Root %2" }),
    "1x main: Root %2",
    "tokens without a percent are still replaced beside a %2 name")
eq(StockPiler.T("recipe.success", { pct = 50, ok = 3, att = 4 }),
    "Success: 50% (3/4)",
    "a percent that belongs to the template is kept")
eq(StockPiler.T("material.bonus.pct_plus", { value = 15, name = "Crit%" }),
    "+15% Crit%",
    "a plain number token is replaced next to a trailing percent")
eq(StockPiler.T("test.repeat_name", { name = "100%" }), "100% and 100%",
    "100% is substituted at every repeated token")
eq(StockPiler.T("test.repeat_name", { name = "%%" }), "%% and %%",
    "two percent signs are substituted at every repeated token")
eq(StockPiler.T("test.repeat_name", { name = "Trail%" }), "Trail% and Trail%",
    "a trailing percent is substituted at every repeated token")

if failures > 0 then
    io.stderr:write(string.format("%d/%d checks failed\n", failures, checks))
    os.exit(1)
end
print(string.format("locale_tokens: %d checks passed", checks))
