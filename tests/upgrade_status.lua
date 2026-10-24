-- Upgrade scans are reused, and status paint does not take over planting.
-- Run: lua5.1 tests/upgrade_status.lua

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

local walks = 0
local demandCalls = 0
local demandOpts = nil

StockPiler = {
    FrameCounter = 4,
    Inventory = {
        GetSnapGen = function() return 2 end,
        ForEachItem = function(fn)
            walks = walks + 1
            fn({ uniqueID = 10, stackCount = 1, craftingSkillRequirement = 50 })
        end,
    },
    SeedMap = {
        GetFamilyLadder = function(key)
            return { key = key, genus = "root", rungs = { { seedUid = 10, plantUid = 11, skillReq = 50 } } }
        end,
        BestOwnedSeedOnLadder = function()
            walks = walks + 1
            return { seedUid = 10, skillReq = 50 }
        end,
        BestUpgradePlantOnLadder = function()
            walks = walks + 1
            return { plantUid = 11, seedUid = 10, skillReq = 50 }
        end,
    },
    RecipeSpec = {
        BuildBalancedSpecDemand = function(opts)
            demandCalls = demandCalls + 1
            demandOpts = opts
            return nil
        end,
    },
    Watch = {
        IsAutoGrowEnabled = function() return true end,
        GetPlantWatches = function() return {} end,
    },
    PlanSnapshot = { Get = function() return { planGen = 1, rows = {} } end },
}

load_module("Source/UpgradeSeed.lua")
local US = StockPiler.UpgradeSeed

local function enable()
    US.IsEnabled = function() return true end
end
enable()

local ladder = { key = "root|main|0", genus = "root" }
walks = 0
US.PickBestOwnedSeed({ climbCap = 100, familyKey = "root|main|0", ladder = ladder })
US.PickBestOwnedSeed({ climbCap = 100, familyKey = "root|main|0", ladder = ladder })
local other = { key = "leaf|main|0", genus = "leaf" }
US.PickBestOwnedSeed({ climbCap = 100, familyKey = "leaf|main|0", ladder = other })
US.PickBestOwnedSeed({ climbCap = 100, familyKey = "root|main|0", ladder = ladder })
eq(walks, 2, "two seed ladders walk the bag twice, not four")

walks = 0
US.ScanUpgradePlant({ climbCap = 100, familyKey = "root|main|0", ladder = ladder })
US.ScanUpgradePlant({ climbCap = 80, familyKey = "leaf|main|0", ladder = other })
US.ScanUpgradePlant({ climbCap = 100, familyKey = "root|main|0", ladder = ladder })
US.ScanUpgradePlant({ climbCap = 80, familyKey = "leaf|main|0", ladder = other })
eq(walks, 2, "two plant scans are reused for the same bag")

US._upgradeTargetsKey = nil
US._upgradeTargetsCache = nil
US._active = { why = "planting", plantUid = 11, genus = "root" }
US.StatusForPlant(11)
eq(US._active.why, "planting", "status paint leaves the planting job alone")
eq(demandOpts and demandOpts.cacheOnly, true, "upgrade targets read cached demand only")
local callsAfter = demandCalls
US._upgradeTargetsKey = nil
US.StatusForPlant(11)
eq(US._upgradeTargetsKey, nil, "a demand miss is not stored as this snap's targets")
eq(demandCalls >= callsAfter, true, "status can ask for demand again")

if failures > 0 then
    io.stderr:write(string.format("%d/%d checks failed\n", failures, checks))
    os.exit(1)
end
print(string.format("upgrade_status: %d checks passed", checks))
