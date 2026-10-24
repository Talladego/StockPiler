-- Named {token} substitution must replace every occurrence.
-- wstring.gsub is the real two-return string.gsub (result, count), optional n.
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

-- Same contract as the game client: both return values, optional n.
wstring = { gsub = string.gsub }

local stubResult, stubCount = wstring.gsub("ab%c", "%%", "%%%%")
eq(stubResult, "ab%%c", "stub returns the escaped string")
eq(stubCount, 1, "stub returns the match count")
local limited, limitedCount = wstring.gsub("{a} {a}", "{a}", "Z", 1)
eq(limited, "Z {a}", "stub forwards n")
eq(limitedCount, 1, "stub count respects n")

load_module("Source/Locale/Locale.lua")
load_module("Source/Locale/enUS.lua")
StockPiler.Locale.SetLanguage(1)

local pack = StockPiler.Locale.Packs[1]
pack["test.repeat_name"] = "{x} and {x}"

eq(StockPiler.T("ui.title_version", { version = "1.1.2" }), "StockPiler v1.1.2",
    "version token is replaced")
eq(StockPiler.T("boot.chat", { state = "ON" }), "Chat ON",
    "chat state token is replaced")
eq(StockPiler.T("grow.planted", { plot = 1, name = "Spore", reason = "watch" }),
    "<icon02486> Plot 1 planted Spore (watch).",
    "planted line replaces every token")
eq(StockPiler.T("test.repeat_name", { x = "abc" }), "abc and abc",
    "a repeated token with no percent is replaced every time")
eq(StockPiler.T("test.repeat_name", { x = "50%" }), "50% and 50%",
    "a repeated token with one percent is replaced every time")

local okPct, imported = pcall(StockPiler.T, "link.imported", { name = "Bad %2" })
check(okPct == true, "%2 token does not throw")
eq(imported, "Added Bad %2 to Known Potions.", "%2 stays literal text")

local okHundred, hundred = pcall(StockPiler.T, "potions.forget_confirm", { name = "100%" })
check(okHundred == true, "100% token does not throw")
eq(hundred, "Forget this learned potion recipe?\n100%", "100% stays literal text")

eq(StockPiler.T("share.slot_line", { qty = "1", role = "main", name = "Root %2" }),
    "1x main: Root %2",
    "Root %2 is literal and the other tokens are replaced")

local function sample_for(name)
    if name == "version" then
        return "1.1.2"
    end
    if name == "state" then
        return "ON"
    end
    if name == "name" then
        return "Spore"
    end
    if name == "reason" then
        return "watch"
    end
    return "1"
end

local templateCount = 0
for key, template in pairs(pack) do
    if type(template) == "string" then
        templateCount = templateCount + 1
        local tokens = {}
        for name in string.gmatch(template, "{([^}]+)}") do
            tokens[name] = sample_for(name)
        end
        local ok, formatted = pcall(StockPiler.T, key, tokens)
        check(ok == true, "format " .. tostring(key) .. " does not throw")
        if ok and type(formatted) == "string" then
            local leftover = string.match(formatted, "{[^}]*}")
            check(leftover == nil, "no unreplaced token in " .. tostring(key)
                .. " leftover=" .. tostring(leftover)
                .. " got=" .. formatted)
        end
    end
end
check(templateCount > 50, "english pack has templates to format")

local helpExpected = {
    "Commands:",
    "/stp - open or close window",
    "/stp help - command list",
    "/stp chat [on|quiet|off] - chat messages",
    "/stp button [<scale>] - HUD button size (0.50-2.00)",
    "/stp button timer [on|off] - HUD grow countdown",
    "/stp button reset - reset HUD button",
    "/stp link - link last shared recipe",
    "/stp apply <recipe> - preview pasted recipe",
}
local helpKeys = {
    "boot.help.header",
    "boot.help.open",
    "boot.help.help",
    "boot.help.chat",
    "boot.help.button",
    "boot.help.button_timer",
    "boot.help.button_reset",
    "boot.help.link",
    "boot.help.apply",
}
for i = 1, #helpKeys do
    eq(StockPiler.T(helpKeys[i]), helpExpected[i], helpKeys[i] .. " text")
end

load_module("Source/Core/Util.lua")
local helpLines = {}
StockPiler.Debug = {
    Reply = function(msg)
        helpLines[#helpLines + 1] = tostring(msg)
    end,
}
load_module("Source/Bootstrap.lua")
StockPiler.OnSlash("help")
eq(#helpLines, #helpExpected, "/stp help prints one row per command")
for i = 1, #helpExpected do
    eq(helpLines[i], helpExpected[i], "/stp help row " .. i)
end
for i = 1, #helpLines do
    local line = helpLines[i]
    check(string.find(line, "/stp debug", 1, true) == nil, "help hides debug: " .. line)
    check(string.find(line, "dump", 1, true) == nil, "help hides dumps: " .. line)
    check(string.find(line, "/stp reset", 1, true) == nil, "help hides /stp reset: " .. line)
end

local function assert_ascii_file(path)
    local fh = assert(io.open(path, "rb"))
    local data = fh:read("*a")
    fh:close()
    local line = 1
    for i = 1, #data do
        local b = string.byte(data, i)
        if b == 10 then
            line = line + 1
        elseif b ~= 9 and b ~= 13 and (b < 32 or b > 126) then
            eq(b, 32, path .. " line " .. line .. " has non-ascii byte " .. b)
            return
        end
    end
    check(true, path .. " is pure ascii")
end

local function list_cmd(cmd)
    local pipe = assert(io.popen(cmd))
    local out = pipe:read("*a")
    pipe:close()
    local files = {}
    for path in string.gmatch(out, "[^\r\n]+") do
        files[#files + 1] = path
    end
    return files
end

local luaFiles = list_cmd('find "' .. ROOT .. '/Source" -type f -name "*.lua" | sort')
check(#luaFiles > 10, "found Source lua files to scan")
for i = 1, #luaFiles do
    assert_ascii_file(luaFiles[i])
end
assert_ascii_file(ROOT .. "/StockPiler.mod")
assert_ascii_file(ROOT .. "/README.md")
assert_ascii_file(ROOT .. "/CHANGELOG.md")
assert_ascii_file(ROOT .. "/Source/Locale/enUS.lua")

if failures > 0 then
    io.stderr:write(string.format("%d/%d checks failed\n", failures, checks))
    os.exit(1)
end
print(string.format("locale_tokens: %d checks passed", checks))
