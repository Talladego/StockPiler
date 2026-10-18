----------------------------------------------------------------
-- StockPiler Core/SeedEconomy -- seed budget lookup.
-- GetSeedBudget delegates to Refine, then UpgradeSeed. SkillUp keeps its own deficit math.
----------------------------------------------------------------

StockPiler = StockPiler or {}
StockPiler.SeedEconomy = StockPiler.SeedEconomy or {}
local SE = StockPiler.SeedEconomy

local function EmptyBudget()
    return {
        live = 0,
        ground = 0,
        outstanding = 0,
        credit = 0,
        headroom = 0,
        bufferMin = 0,
        unsettled = true,
    }
end

function SE.GetSeedBudget(seedUid)
    local Refine = StockPiler.Refine
    if Refine and Refine.GetSeedBudget then
        local b = Refine.GetSeedBudget(seedUid)
        if type(b) == "table" then
            return b
        end
    end
    local US = StockPiler.UpgradeSeed
    if US and US.GetSeedBudget then
        local b = US.GetSeedBudget(seedUid)
        if type(b) == "table" then
            return b
        end
    end
    return EmptyBudget()
end

local CULT_TIERS = { 1, 25, 50, 75, 100, 125, 150, 175, 200 }

--- Highest cult seed tier the skill can use. Floor is 1.
function SE.FloorCultTier(cultSkill)
    cultSkill = tonumber(cultSkill) or 0
    local tiers = CULT_TIERS
    local SkillUp = StockPiler.SkillUp
    if SkillUp and type(SkillUp.CULT_TIERS) == "table" then
        tiers = SkillUp.CULT_TIERS
    end
    local best = 1
    for i = 1, #tiers do
        local t = tonumber(tiers[i]) or 0
        if cultSkill >= t and t >= 1 then
            best = t
        end
    end
    return best
end

function SE.SeedBufferOk()
    local Watch = StockPiler.Watch
    if not (Watch and Watch.IsSeedBufferEnabled and Watch.IsSeedBufferEnabled() == true) then
        return true
    end
    local Grow = StockPiler.Grow
    return Grow and Grow.IsSeedBufferSatisfied and Grow.IsSeedBufferSatisfied() == true
end

--- Enabled plant watches are at target. A watch whose plant uid is still 0 is
--- skipped. A watch owned by an upgrade climb counts as stocked.
function SE.PlantWatchesStocked()
    local Watch = StockPiler.Watch
    local plantWatches = Watch and Watch.GetPlantWatches and Watch.GetPlantWatches() or {}
    if type(plantWatches) ~= "table" then
        return true
    end
    local Catalog = StockPiler.Catalog
    local Inv = StockPiler.Inventory
    local US = StockPiler.UpgradeSeed
    for plantKey, watch in pairs(plantWatches) do
        if type(watch) == "table" and watch.enabled == true then
            local plantUid = Watch.ParsePlantKey and Watch.ParsePlantKey(plantKey) or 0
            plantUid = tonumber(plantUid) or 0
            if plantUid > 0 then
                local owned = US and US.IsPlantWatchOwnedByUpgrade
                    and US.IsPlantWatchOwnedByUpgrade(plantUid) == true
                if owned ~= true then
                    local target = tonumber(watch.targetStock) or 40
                    local have = 0
                    if Catalog and Catalog.PlantHave then
                        have = tonumber(Catalog.PlantHave(plantUid)) or 0
                    elseif Inv and Inv.CountByUid then
                        have = tonumber(Inv.CountByUid(plantUid)) or 0
                    end
                    if have < target then
                        return false
                    end
                end
            end
        end
    end
    return true
end

function SE.PlayUserActionSound()
    if type(PlaySound) == "function" and GameData and GameData.Sound
        and GameData.Sound.RESPAWN ~= nil
    then
        pcall(PlaySound, GameData.Sound.RESPAWN)
    elseif type(PlaySound) == "function" then
        pcall(PlaySound, 216)
    end
end

function SE.SeedBuyJob(opts)
    opts = type(opts) == "table" and opts or {}
    local seedUid = tonumber(opts.seedUid) or 0
    local specKey = tostring(opts.specKey or "")
    local job = {
        uid = seedUid,
        uniqueID = seedUid,
        deficit = tonumber(opts.deficit) or 0,
        skillUp = true,
        growable = true,
        isGrowable = true,
        role = tostring(opts.role or "main"),
        spec = opts.spec,
        specKey = specKey,
        acquireKey = tostring(opts.acquireKey or specKey),
        skillReq = tonumber(opts.skillReq) or 0,
    }
    if opts.upgradeSeed == true then
        job.upgradeSeed = true
    end
    if opts.familyKey ~= nil then
        job.familyKey = opts.familyKey
    end
    return job
end
