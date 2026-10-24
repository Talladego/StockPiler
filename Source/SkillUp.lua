----------------------------------------------------------------
-- StockPiler SkillUp - idle Cult + Apo skill-up
--
-- Cult tier policy (all rungs until Cult 200):
--   Prefer the highest seed/plant tier unlocked by current Cult skill
--   (1 -> 25 -> 50 -> 75 -> 100 -> 125 -> 150 -> 175). When that tier is not
--   in bags, keep planting/refining lower tiers for rare skillups and
--   crit upgrades into the next tier. Stop when Cult reaches 200.
--   When Apo SkillUp is also on, never *plant* above Apo tier (tandem),
--   except while Apo has no vial: Cultivation then levels on its own tier
--   so it can unlock plots. A vial returns Cultivation to feeding Apo.
--   Still refine lucky higher Cult-floor plants into seeds for later.
--   Prefer exact Apo floor so Cult feeds Apo instead of racing ahead.
--   Fill every unlocked plot (1 / 50 / 100 / 150 -> 1-4 plots).
--   Prefer a bag seed line already at buffer (or plant-refinable to it);
--   fill every empty plot (planting preserves seed-buffer credit via ground).
--   AutoBuy tops up SeedDeficit (plots + buffer) even when bags hold some seeds.
--
-- Apo (when Skill up Apo is on and watches allow idle SkillUp):
--   Brew only at FloorApoTier (exact rung). No lower-tier waste after
--   tier-up. A lower cultivation main waits for Cult to supply this tier.
--   A butcher main has no seed: it is not seed-buffer reserved. Flask buy
--   is unchanged (exact-tier main in bags, AutoBuy on).
--   Idle when watches stocked+buffer OK, or when every short watch is
--   progress-blocked (AG off / vendor stall / need_skill) and buffer OK.
--   Never consume plants/seeds still claimed by short watches
--   (WatchDemandReserve / PlantBrewSurplus for brew; PlantRefineSurplus
--   for SkillUp refine - buffer headroom is a refine target, not a hold).
--   Apo brew uses the same seed-buffer headroom reserve as normal potion
--   watches (no extra standing plant cushion when the seed buffer is full).
--   Stabilizer: any positive-stability stabilizer at or under the floor
--   (Arboreal Resin or a butchered stabilizer). Compose main + container
--   (+0/+1/+2) + lowest-skillReq stabilizers that still reach engine HIGH
--   (sum > 0). Prefer burning lower-tier stabilizers over fewer units of a
--   stronger one when both stabilize. Resin short -> refine leftover
--   lower-tier mains first, then surplus of the exact-floor brew main
--   (keep >=1 for brew).
--   Never hard-stall on "upgrade plant exists" when that plant cannot
--   actually refine (fall through to same-tier refine / plant / AutoBuy).
--   SkillUp crafts are not recorded as known potions (BrewLearn skips
--   session.skillUp learns). Legacy skillUpOrigin rows stay hidden in Potions.
--   Cult AutoGrow assists at Apo tier even at Cult 200 / Cult SkillUp off.
----------------------------------------------------------------

StockPiler = StockPiler or {}
StockPiler.SkillUp = StockPiler.SkillUp or {}
local SkillUp = StockPiler.SkillUp
local TOr

SkillUp.CULT_MAX = 200
SkillUp.APO_MAX = 200
SkillUp.CULT_TIERS = { 1, 25, 50, 75, 100, 125, 150, 175, 200 }
SkillUp.APO_TIERS = { 1, 25, 50, 75, 100, 125, 150, 175, 200 }

SkillUp._stallLatch = nil

local function Caps()
    return StockPiler.TradeSkillCaps
end

local function CharRow(create)
    local Watch = StockPiler.Watch
    if Watch and Watch.CharacterRow then
        return Watch.CharacterRow(create ~= false)
    end
    return nil
end

function SkillUp.FloorApoTier(apoSkill)
    apoSkill = tonumber(apoSkill) or 0
    local best = 1
    local tiers = SkillUp.APO_TIERS
    for i = 1, #tiers do
        local t = tiers[i]
        if apoSkill >= t then
            best = t
        end
    end
    return best
end

--- Highest cult seed/plant tier the current Cult skill can use (1, 25, 50, ...).
function SkillUp.FloorCultTier(cultSkill)
    local SE = StockPiler.SeedEconomy
    if SE and SE.FloorCultTier then
        return SE.FloorCultTier(cultSkill)
    end
    cultSkill = tonumber(cultSkill) or 0
    local best = 1
    local tiers = SkillUp.CULT_TIERS or SkillUp.APO_TIERS
    for i = 1, #tiers do
        local t = tiers[i]
        if cultSkill >= t then
            best = t
        end
    end
    return best
end

function SkillUp.GetCultSkill()
    local C = Caps()
    return C and C.GetCultSkill and tonumber(C.GetCultSkill()) or 0
end

function SkillUp.GetApoSkill()
    local C = Caps()
    return C and C.GetApoSkill and tonumber(C.GetApoSkill()) or 0
end

function SkillUp.IsCultVisible()
    local cult = SkillUp.GetCultSkill()
    return cult > 0 and cult < (SkillUp.CULT_MAX or 200)
end

function SkillUp.IsApoVisible()
    local apo = SkillUp.GetApoSkill()
    return apo > 0 and apo < (SkillUp.APO_MAX or 200)
end

--- "missing" (not learned), "max" (at the cap), or "ready" (can still level).
function SkillUp.LevelKind(level, maxLevel)
    level = tonumber(level) or 0
    maxLevel = tonumber(maxLevel) or 200
    if level <= 0 then
        return "missing"
    end
    if level >= maxLevel then
        return "max"
    end
    return "ready"
end

function SkillUp.CultLevelKind()
    return SkillUp.LevelKind(SkillUp.GetCultSkill(), SkillUp.CULT_MAX or 200)
end

function SkillUp.ApoLevelKind()
    return SkillUp.LevelKind(SkillUp.GetApoSkill(), SkillUp.APO_MAX or 200)
end

--- CharRow toggle only (ignores skill blips). Used to keep Watch rows mounted.
--- Latch last known so a nil CharacterRow mid-load cannot hide SkillUp rows.
function SkillUp.IsCultToggleOn()
    local row = CharRow(false)
    if type(row) == "table" then
        SkillUp._latchedCultToggle = row.skillUpCultEnabled == true
        return SkillUp._latchedCultToggle == true
    end
    return SkillUp._latchedCultToggle == true
end

function SkillUp.IsApoToggleOn()
    local row = CharRow(false)
    if type(row) == "table" then
        SkillUp._latchedApoToggle = row.skillUpApoEnabled == true
        return SkillUp._latchedApoToggle == true
    end
    return SkillUp._latchedApoToggle == true
end

function SkillUp.IsCultEnabled()
    if not SkillUp.IsCultVisible() then
        return false
    end
    return SkillUp.IsCultToggleOn() == true
end

function SkillUp.IsApoEnabled()
    if not SkillUp.IsApoVisible() then
        return false
    end
    return SkillUp.IsApoToggleOn() == true
end

function SkillUp.SetCultEnabled(enabled)
    local row = CharRow(true)
    if type(row) ~= "table" then
        return false
    end
    row.skillUpCultEnabled = enabled == true
    SkillUp._latchedCultToggle = enabled == true
    local Watch = StockPiler.Watch
    if Watch and Watch.BumpGen then
        Watch.BumpGen()
    end
    local Grow = StockPiler.Grow
    if Grow and Grow.InvalidatePlantQueue then
        Grow.InvalidatePlantQueue({ reason = "skillup-cult" })
    end
    local Sch = StockPiler.Scheduler
    if Sch and Sch.WakeAutoGrow then
        Sch.WakeAutoGrow()
    end
    return true
end

function SkillUp.SetApoEnabled(enabled)
    local row = CharRow(true)
    if type(row) ~= "table" then
        return false
    end
    row.skillUpApoEnabled = enabled == true
    SkillUp._latchedApoToggle = enabled == true
    local Watch = StockPiler.Watch
    if Watch and Watch.BumpGen then
        Watch.BumpGen()
    end
    local Grow = StockPiler.Grow
    if Grow and Grow.InvalidatePlantQueue then
        Grow.InvalidatePlantQueue({ reason = "skillup-apo" })
    end
    local Sch = StockPiler.Scheduler
    if Sch and Sch.WakeAutoGrow then
        Sch.WakeAutoGrow()
    end
    return true
end

local function AllEnabledPlantWatchesStocked()
    local SE = StockPiler.SeedEconomy
    if SE and SE.PlantWatchesStocked then
        return SE.PlantWatchesStocked() == true
    end
    return true
end

local function SeedBufferOk()
    local SE = StockPiler.SeedEconomy
    if SE and SE.SeedBufferOk then
        return SE.SeedBufferOk() == true
    end
    return true
end

--- No short potion/plant watches (and seed buffer satisfied when enabled).
function SkillUp.WatchesDone()
    local Watch = StockPiler.Watch
    if Watch and Watch.AllEnabledPotionWatchesStocked
        and Watch.AllEnabledPotionWatchesStocked() ~= true
    then
        return false
    end
    if AllEnabledPlantWatchesStocked() ~= true then
        return false
    end
    -- SkillUp must not run while the seed buffer is short (even with no AutoGrow watches).
    return SeedBufferOk()
end

-- Statuses where a short watch can still advance (SkillUp must wait).
local SHORT_WATCH_WORKING = {
    restocking = true,
    need_seeds = true,
    upgrading_seed = true,
    planting = true,
    buffer_plant = true,
    growing = true,
    refining = true,
    ready_to_craft = true,
    ready_to_craft_shared = true,
}

-- Statuses where AutoGrow/AutoBuy cannot progress the short watch.
local SHORT_WATCH_BLOCKED = {
    enable_autogrow = true,
    buy_ingredients = true,
    need_apothecary = true,
    need_vendor = true,
    no_vendor_seed = true,
    no_vendor_container = true,
    need_container_vendor = true,
    autobuy_off = true,
    no_seeds = true,
    no_recipe = true,
    no_target = true,
    need_skill = true,
}

local function AutoBuyCanProgress()
    local Watch = StockPiler.Watch
    if not (Watch and Watch.IsAutoBuyEnabled and Watch.IsAutoBuyEnabled() == true) then
        return false
    end
    local VA = StockPiler.VendorAdapter
    return VA and VA.IsStoreOpen and VA.IsStoreOpen() == true
end

local function ShortStatusIsWorking(statusKey)
    statusKey = tostring(statusKey or "")
    if statusKey == "buy_ingredients" then
        return AutoBuyCanProgress()
    end
    return SHORT_WATCH_WORKING[statusKey] == true
end

local function ShortStatusIsBlocked(statusKey)
    statusKey = tostring(statusKey or "")
    if statusKey == "buy_ingredients" then
        return AutoBuyCanProgress() ~= true
    end
    return SHORT_WATCH_BLOCKED[statusKey] == true
end

local function PotionWatchHave(key, watch)
    local RS = StockPiler.RecipeSpec
    local Catalog = StockPiler.Catalog
    local have = 0
    if RS and RS.ResolveWatchPotion then
        local resolved = RS.ResolveWatchPotion(key)
        local potion = resolved and resolved.potion
        if type(potion) == "table" and Catalog and Catalog.PotionHaveCombined then
            have = tonumber(Catalog.PotionHaveCombined(potion)) or 0
        elseif resolved and resolved.outputUid and StockPiler.Inventory and StockPiler.Inventory.CountByUid then
            have = tonumber(StockPiler.Inventory.CountByUid(resolved.outputUid)) or 0
        end
    end
    return have
end

local function PotionNeedsSkill(key)
    local RS = StockPiler.RecipeSpec
    if not (RS and RS.RecipeSpecForPotion and RS.RecipeSkillRequirements) then
        return false
    end
    local recipe = RS.RecipeSpecForPotion(key)
    if type(recipe) ~= "table" then
        return false
    end
    local req = RS.RecipeSkillRequirements(recipe)
    if type(req) ~= "table" then
        return false
    end
    local Caps = StockPiler.TradeSkillCaps
    local apo = Caps and Caps.GetApoSkill and tonumber(Caps.GetApoSkill()) or 0
    local need = tonumber(req.apothecary) or tonumber(req.apo) or 0
    return need > 0 and apo < need
end

local function PotionWatchWantsAutoGrow(key, watch)
    local RS = StockPiler.RecipeSpec
    if RS and RS.ShouldAutoGrowPotion then
        return RS.ShouldAutoGrowPotion(key, watch) == true
    end
    local Watch = StockPiler.Watch
    if type(watch) ~= "table" or watch.enabled ~= true then
        return false
    end
    if Watch and Watch.IsAutoGrowEnabled and Watch.IsAutoGrowEnabled() ~= true then
        return false
    end
    return watch.autoGrow == true
end

--- Plan row still matches a short live watch. Missing/stocked watches are stale.
local function PlanRowLiveStillShort(row)
    local Watch = StockPiler.Watch
    if not Watch or type(row) ~= "table" then
        return true
    end
    if row.isPlantWatch == true or tostring(row.kind or "") == "plant" then
        local plantKey = row.plantKey or row.potionKey
        local watches = Watch.GetPlantWatches and Watch.GetPlantWatches() or {}
        local watch = type(watches) == "table" and watches[plantKey] or nil
        if type(watch) ~= "table" then
            return true
        end
        if watch.enabled ~= true then
            return false
        end
        local target = tonumber(watch.targetStock) or 0
        local plantUid = tonumber(row.plantUid) or 0
        if plantUid <= 0 and Watch.ParsePlantKey then
            plantUid = tonumber(Watch.ParsePlantKey(plantKey)) or 0
        end
        local have = 0
        local Inv = StockPiler.Inventory
        if plantUid > 0 and Inv and Inv.CountByUid then
            have = tonumber(Inv.CountByUid(plantUid)) or 0
        end
        return target > 0 and have < target
    end
    local key = tostring(row.potionKey or row.potionRecipeKey or row.id or "")
    if key == "" or key == "seed_buffer" then
        return true
    end
    local watches = Watch.GetWatches and Watch.GetWatches() or {}
    local watch = type(watches) == "table" and watches[key] or nil
    if type(watch) ~= "table" then
        return true
    end
    if watch.enabled ~= true then
        return false
    end
    local target = tonumber(watch.targetStock) or 0
    local have = PotionWatchHave(key, watch)
    return target > 0 and have < target
end

--- True when every short enabled potion/plant watch is progress-blocked
--- (AG off, vendor stall, need_skill, no recipe, etc.). No short watches -> true.
function SkillUp.AllShortWatchesProgressBlocked()
    local shortCount = 0

    local PS = StockPiler.PlanSnapshot
    local plan = nil
    if PS and PS.Get then
        plan = PS.Get()
    end
    if type(plan) == "table" and type(plan.rows) == "table" and #plan.rows > 0 then
        for i = 1, #plan.rows do
            local row = plan.rows[i]
            if type(row) == "table" and row.skillUp ~= true and row.addonOwned ~= true then
                local key = tostring(row.statusKey or "")
                if key ~= "potion_stocked" and key ~= "plant_stocked" and key ~= "" then
                    local target = tonumber(row.potionMin) or tonumber(row.target) or tonumber(row.targetStock) or 0
                    local have = tonumber(row.potionHave) or tonumber(row.have) or tonumber(row.plantHave) or 0
                    local deficit = tonumber(row.potionDeficit) or tonumber(row.deficit) or 0
                    local short = deficit > 0 or (target > 0 and have < target)
                    if not short and (SHORT_WATCH_WORKING[key] or SHORT_WATCH_BLOCKED[key]) then
                        -- Live status can mark progress work even when stock columns lag.
                        if key ~= "seed_buffer" then
                            short = true
                        end
                    end
                    if short and PlanRowLiveStillShort(row) ~= true then
                        -- Stale plan status; live watch is stocked or gone.
                        short = false
                    end
                    if short then
                        shortCount = shortCount + 1
                        if ShortStatusIsWorking(key) then
                            return false
                        end
                        if not ShortStatusIsBlocked(key) then
                            -- Unknown status -> treat as still working (safe).
                            return false
                        end
                    end
                end
            end
        end
        -- SkillUp-only (or fully stocked) snapshots must not skip the live watch list.
        if shortCount > 0 then
            return true
        end
    end

    -- No plan snapshot: classify from Watch store + AG / skill gates.
    local Watch = StockPiler.Watch
    local watches = Watch and Watch.GetWatches and Watch.GetWatches() or {}
    if type(watches) == "table" then
        for key, watch in pairs(watches) do
            if type(watch) == "table" and watch.enabled == true then
                local target = tonumber(watch.targetStock) or 40
                local have = PotionWatchHave(key, watch)
                if target > 0 and have < target then
                    shortCount = shortCount + 1
                    if PotionNeedsSkill(key) then
                        -- need_skill: watch brew blocked; SkillUp Apo is the unlock path.
                    elseif PotionWatchWantsAutoGrow(key, watch) then
                        return false
                    end
                    -- AG off / buy-only without progress -> blocked.
                end
            end
        end
    end
    local plantWatches = Watch and Watch.GetPlantWatches and Watch.GetPlantWatches() or {}
    if type(plantWatches) == "table" then
        local Inv = StockPiler.Inventory
        for plantKey, watch in pairs(plantWatches) do
            if type(watch) == "table" and watch.enabled == true then
                local target = tonumber(watch.targetStock) or 40
                local plantUid = Watch.ParsePlantKey and tonumber(Watch.ParsePlantKey(plantKey)) or 0
                local have = 0
                if plantUid > 0 and Inv and Inv.CountByUid then
                    have = tonumber(Inv.CountByUid(plantUid)) or 0
                end
                if target > 0 and have < target then
                    shortCount = shortCount + 1
                    if Watch.ShouldAutoGrowPlant and Watch.ShouldAutoGrowPlant(plantKey) == true then
                        return false
                    end
                end
            end
        end
    end
    return true
end

--- Soft gate: stocked+buffer, or all short watches blocked with seed buffer OK.
function SkillUp.WatchesAllowIdleSkillUp()
    local US = StockPiler.UpgradeSeed
    if US and US.IsActivelyClimbingPlantWatches
        and US.IsActivelyClimbingPlantWatches() == true
    then
        return false
    end
    if SkillUp.WatchesDone() == true then
        return true
    end
    if SeedBufferOk() ~= true then
        return false
    end
    return SkillUp.AllShortWatchesProgressBlocked() == true
end

--- Max skillReq for SkillUp plant/seed picks.
--- Cult SkillUp only -> cult tier; Apo SkillUp only (Cult available) -> apo tier;
--- both on -> min(cult, apo) so Cult never outpaces Apo.
--- No vial for Apo: Cultivation uses its own tier until a vial is back.
function SkillUp.TargetMaxSkill()
    local cult = SkillUp.GetCultSkill()
    local cultOn = SkillUp.IsCultEnabled() == true
    local apoOn = SkillUp.IsApoEnabled() == true
    local cultTier = 0
    if cult > 0 then
        cultTier = SkillUp.FloorCultTier(cult)
    end
    local apoTier = 0
    if apoOn then
        apoTier = SkillUp.FloorApoTier(SkillUp.GetApoSkill())
    end

    if cultOn and apoOn then
        if cultTier < 1 then
            return apoTier
        end
        if apoTier < 1 then
            return cultTier
        end
        local apo = tonumber(SkillUp.GetApoSkill()) or 0
        if apo > 0 and apo < (SkillUp.APO_MAX or 200)
            and (tonumber(SkillUp.CountApoContainers()) or 0) < 1
            and SkillUp.ApoVialObtainable() ~= true
        then
            return cultTier
        end
        if apoTier < cultTier then
            return apoTier
        end
        return cultTier
    end
    if apoOn then
        -- Apo SkillUp alone (or Cult already 200): grow/feed at Apo tier when Cult exists.
        return apoTier
    end
    if cultOn then
        return cultTier
    end
    return cultTier
end

--- Cultivation can plant/refine for SkillUp when skilling Cult or assisting Apo.
function SkillUp.ShouldCultGrowForSkillUp()
    local cult = SkillUp.GetCultSkill()
    if cult <= 0 then
        return false
    end
    local Caps = StockPiler.TradeSkillCaps
    if Caps and Caps.CanAutoGrow and Caps.CanAutoGrow() ~= true then
        return false
    end
    local Watch = StockPiler.Watch
    if not (Watch and Watch.IsAutoGrowEnabled and Watch.IsAutoGrowEnabled() == true) then
        return false
    end
    if SkillUp.WatchesAllowIdleSkillUp() ~= true then
        return false
    end
    if SkillUp.IsCultEnabled() == true then
        return true
    end
    -- Implicit assist: Apo SkillUp on -> Cult grows Apo-tier mains (even at Cult 200).
    if SkillUp.IsApoEnabled() == true then
        return true
    end
    return false
end

--- Back-compat alias used by plant/refine/buy paths.
function SkillUp.ShouldCultPlant()
    return SkillUp.ShouldCultGrowForSkillUp() == true
end

local function SeedSkillReq(item)
    local SM = StockPiler.SeedMap
    if SM and SM.ItemSkillReq then
        return tonumber(SM.ItemSkillReq(item)) or 0
    end
    if type(item) ~= "table" then
        return 0
    end
    local function positive(value)
        value = tonumber(value)
        if value ~= nil and value > 0 then
            return value
        end
        return nil
    end
    local req = positive(item.craftingSkillRequirement)
        or positive(item.skillReq)
        or positive(item.skillLevel)
        or 0
    if req <= 0 and type(item.bonuses) == "table" then
        req = positive(item.bonuses[9]) or positive(item.bonuses["9"]) or 0
    end
    return req
end

local function LooksNonMainSeed(item, plantSpec)
    local role = tostring(plantSpec and plantSpec.role or "")
    if role == "stabilizer" or role == "extender" or role == "multiplier"
        or role == "stimulant" or role == "goldweed" or role == "container"
    then
        return true
    end
    local SM = StockPiler.SeedMap
    if SM and SM.SpecHasGoldweedMultiplier and type(plantSpec) == "table"
        and SM.SpecHasGoldweedMultiplier(plantSpec) == true
    then
        return true
    end
    if SM and SM.IsHarvestByproduct and type(plantSpec) == "table"
        and SM.IsHarvestByproduct(plantSpec) == true
    then
        return true
    end
    local n = ""
    if type(item) == "table" and item.name ~= nil then
        if type(item.name) == "wstring" and type(WStringToString) == "function" then
            n = string.lower(WStringToString(item.name) or "")
        else
            n = string.lower(tostring(item.name or ""))
        end
    end
    if string.find(n, "goldweed", 1, true) or string.find(n, "gobswort", 1, true)
        or string.find(n, "resin", 1, true)
    then
        return true
    end
    return false
end

local function IsMainIngredientSeed(seedUid, item)
    seedUid = tonumber(seedUid) or 0
    local SM = StockPiler.SeedMap
    local plantUid = 0
    if SM and SM.PrimaryPlantForSeed then
        plantUid = tonumber(SM.PrimaryPlantForSeed(seedUid)) or 0
    end
    local plantSpec = nil
    if plantUid > 0 then
        local Items = StockPiler.Items
        if Items and Items.ToSpec then
            plantSpec = Items.ToSpec(plantUid)
        end
        if type(plantSpec) ~= "table" then
            local MS = StockPiler.MaterialSpec
            if MS and MS.FromUid then
                plantSpec = MS.FromUid(plantUid)
            end
        end
    end
    if type(plantSpec) == "table" then
        local role = tostring(plantSpec.role or "")
        if role == "main" then
            return true
        end
        if LooksNonMainSeed(item, plantSpec) then
            return false
        end
    end
    -- Unlinked: prefer seeds that look like mains (EFFECT bonus / Grows *).
    local MS = StockPiler.MaterialSpec
    if MS and MS.FromItemData and type(item) == "table" then
        local hinted = MS.FromItemData(item, "main")
        if type(hinted) == "table" then
            local fx = tonumber(hinted.effectId) or 0
            if fx > 0 and not LooksNonMainSeed(item, hinted) then
                return true
            end
        end
    end
    if type(plantSpec) == "table" and tostring(plantSpec.role or "") == "" then
        return not LooksNonMainSeed(item, plantSpec)
    end
    -- Unknown linkage: allow if not obviously non-main.
    return not LooksNonMainSeed(item, plantSpec)
end

local function CanUseCraftingSample(sample)
    local Inv = StockPiler.Inventory
    if type(sample) ~= "table" then
        return false
    end
    if Inv and Inv.CanUseCraftingItem then
        return Inv.CanUseCraftingItem(sample) == true
    end
    return true
end

--- In-bag refinable plant for a SkillUp seed line (PrimaryPlant / harvest / name+skill).
--- Needed when grow products never linked the same-tier seed (crit plant sits on
--- ladder with s0) so PrimaryPlantForSeed returns 0 while the plant is in bags.
--- Cached per inventory snapGen — must not full-scan bags inside PickBestBagSeed
--- (seen: Orchestrator.Tick + PickPlantCandidate ~1s every 5s).
local _findBagPlantCache = {}
local _findBagPlantCacheGen = nil

local function FindBagPlantForSeed(seedUid, seedItem)
    seedUid = tonumber(seedUid) or 0
    if seedUid <= 0 then
        return 0
    end
    local Inv = StockPiler.Inventory
    local snapGen = Inv and Inv.GetSnapGen and Inv.GetSnapGen() or nil
    if snapGen == nil then
        snapGen = StockPiler.Knowledge and StockPiler.Knowledge.GetGen
            and StockPiler.Knowledge.GetGen() or 0
    end
    if _findBagPlantCacheGen ~= snapGen then
        _findBagPlantCache = {}
        _findBagPlantCacheGen = snapGen
    end
    local cached = _findBagPlantCache[seedUid]
    if cached ~= nil then
        return cached
    end
    local SM = StockPiler.SeedMap
    local Refine = StockPiler.Refine
    local Items = StockPiler.Items
    local function refinableCount(pUid)
        pUid = tonumber(pUid) or 0
        if pUid <= 0 or not (Refine and Refine.CountRefinablePlants) then
            return 0
        end
        local spec = Items and Items.ToSpec and Items.ToSpec(pUid) or nil
        return tonumber(Refine.CountRefinablePlants(pUid, spec)) or 0
    end
    local function finish(pUid)
        pUid = tonumber(pUid) or 0
        _findBagPlantCache[seedUid] = pUid
        return pUid
    end
    if SM and SM.PrimaryPlantForSeed then
        local pUid = tonumber(SM.PrimaryPlantForSeed(seedUid)) or 0
        if pUid > 0 and refinableCount(pUid) > 0 then
            return finish(pUid)
        end
    end
    if SM and SM.HarvestProducts then
        local products = SM.HarvestProducts(seedUid) or {}
        for i = 1, #products do
            local pUid = tonumber(products[i] and products[i].uid) or 0
            if pUid > 0 and refinableCount(pUid) > 0 then
                return finish(pUid)
            end
        end
    end
    local seedReq = 0
    local seedName = nil
    if type(seedItem) == "table" then
        seedReq = SeedSkillReq(seedItem)
        seedName = seedItem.name
    end
    if seedReq < 1 and Items and Items.GetByUid then
        local row = Items.GetByUid(seedUid)
        if type(row) == "table" then
            seedReq = SeedSkillReq(row)
            if seedName == nil then
                seedName = row.name
            end
        end
    end
    -- Cheap ladder plantUid (no bag walk). GetGenusLadder is Knowledge-gen cached.
    if SM and SM.GetGenusLadder and seedReq >= 1 and seedName then
        local genus = SM.GenusKeyFromName and SM.GenusKeyFromName(seedName) or ""
        if genus ~= "" then
            local ladder = SM.GetGenusLadder(genus)
            if type(ladder) == "table" and type(ladder.rungs) == "table" then
                for i = 1, #ladder.rungs do
                    local rung = ladder.rungs[i]
                    if (tonumber(rung.skillReq) or 0) == seedReq then
                        local pUid = tonumber(rung.plantUid) or 0
                        if pUid > 0 and refinableCount(pUid) > 0 then
                            return finish(pUid)
                        end
                        break
                    end
                end
            end
        end
    end
    if not (Inv and Inv.ForEachItem) then
        return finish(0)
    end
    local best = 0
    Inv.ForEachItem(function(item)
        if best > 0 or type(item) ~= "table" then
            return
        end
        if SM and SM.IsBagSeedOrSpore and SM.IsBagSeedOrSpore(item) then
            return
        end
        local pUid = tonumber(item.uniqueID) or 0
        if pUid <= 0 or refinableCount(pUid) < 1 then
            return
        end
        local matched = false
        if SM and SM.GetSeedUidsForPlant then
            local seeds = SM.GetSeedUidsForPlant(pUid) or {}
            for i = 1, #seeds do
                if (tonumber(seeds[i]) or 0) == seedUid then
                    matched = true
                    break
                end
            end
        end
        if not matched and seedReq >= 1 then
            local pReq = SeedSkillReq(item)
            if pReq < 1 and Items and Items.ToSpec then
                local spec = Items.ToSpec(pUid)
                pReq = tonumber(spec and spec.skillLevel) or 0
            end
            if pReq == seedReq and seedName and item.name and SM and SM.GenusKeyFromName then
                local g = SM.GenusKeyFromName(seedName)
                matched = g ~= "" and g == SM.GenusKeyFromName(item.name)
            end
        end
        if matched then
            best = pUid
        end
    end)
    return finish(best)
end

--- Cheap plantUid for seed scoring (no inventory walk).
local function LadderPlantUidForSeed(seedUid, seedItem, seedReq)
    seedUid = tonumber(seedUid) or 0
    seedReq = tonumber(seedReq) or 0
    local SM = StockPiler.SeedMap
    if SM and SM.PrimaryPlantForSeed then
        local pUid = tonumber(SM.PrimaryPlantForSeed(seedUid)) or 0
        if pUid > 0 then
            return pUid
        end
    end
    if not (SM and SM.GetGenusLadder) or seedReq < 1 then
        return 0
    end
    local seedName = type(seedItem) == "table" and seedItem.name or nil
    if not seedName and StockPiler.Items and StockPiler.Items.GetByUid then
        local row = StockPiler.Items.GetByUid(seedUid)
        seedName = row and row.name
    end
    if not seedName or not SM.GenusKeyFromName then
        return 0
    end
    local genus = SM.GenusKeyFromName(seedName)
    if genus == "" then
        return 0
    end
    local ladder = SM.GetGenusLadder(genus)
    if type(ladder) ~= "table" or type(ladder.rungs) ~= "table" then
        return 0
    end
    for i = 1, #ladder.rungs do
        local rung = ladder.rungs[i]
        if (tonumber(rung.skillReq) or 0) == seedReq then
            return tonumber(rung.plantUid) or 0
        end
    end
    return 0
end

--- Best plantable main seed for Cult SkillUp (nil if none in bags).
--- Prefers highest skillReq <= TargetMaxSkill; else next-best lower tier.
--- Cult 200 + Apo SkillUp: still plant Apo-tier seeds (assist).
function SkillUp.PickBestBagSeed()
    local cult = SkillUp.GetCultSkill()
    if cult <= 0 then
        SkillUp._bagMainList = nil
        SkillUp._bestBagSeed = nil
        SkillUp._bestBagSeedKey = nil
        return nil
    end
    if cult >= (SkillUp.CULT_MAX or 200) and SkillUp.IsApoEnabled() ~= true then
        SkillUp._bagMainList = nil
        SkillUp._bestBagSeed = nil
        SkillUp._bestBagSeedKey = nil
        return nil
    end
    local targetMax = SkillUp.TargetMaxSkill()
    if targetMax < 1 then
        targetMax = 1
    end
    local snapGen = 0
    local PS = StockPiler.PlanSnapshot
    local plan = PS and PS.Get and PS.Get()
    if type(plan) == "table" then
        snapGen = tonumber(plan.planGen) or 0
    end
    local invSnap = 0
    local Inv = StockPiler.Inventory
    if Inv and Inv.GetSnapGen then
        invSnap = tonumber(Inv.GetSnapGen()) or 0
    end
    local emptyPlots = SkillUp.CountEmptyPlots and SkillUp.CountEmptyPlots() or 0
    local cacheKey = tostring(snapGen) .. ":" .. tostring(invSnap)
        .. ":" .. tostring(cult) .. ":" .. tostring(targetMax)
        .. ":" .. tostring(emptyPlots)
    if SkillUp._bestBagSeedKey == cacheKey then
        return SkillUp._bestBagSeed
    end
    local SM = StockPiler.SeedMap
    local Refine = StockPiler.Refine
    local Items = StockPiler.Items
    if not (SM and Inv and Inv.ForEachItem) then
        SkillUp._bagMainList = nil
        SkillUp._bestBagSeed = nil
        SkillUp._bestBagSeedKey = nil
        return nil
    end
    local ranked = {}
    Inv.ForEachItem(function(item)
        if type(item) ~= "table" then
            return
        end
        local uid = tonumber(item.uniqueID) or 0
        if uid <= 0 then
            return
        end
        if SM.IsSeedPacketUid and SM.IsSeedPacketUid(uid) then
            return
        end
        if not (SM.IsBagSeedOrSpore and SM.IsBagSeedOrSpore(item)) then
            return
        end
        if not CanUseCraftingSample(item) then
            return
        end
        local req = SeedSkillReq(item)
        if req > targetMax then
            return
        end
        if not IsMainIngredientSeed(uid, item) then
            return
        end
        local count = Inv.CountByUid and tonumber(Inv.CountByUid(uid)) or 0
        if count <= 0 then
            return
        end
        local plantUid = LadderPlantUidForSeed(uid, item, req)
        local refinable = 0
        if plantUid > 0 and Refine and Refine.CountRefinablePlants then
            local spec = Items and Items.ToSpec and Items.ToSpec(plantUid) or nil
            refinable = tonumber(Refine.CountRefinablePlants(plantUid, spec)) or 0
        end
        -- Same-skillReq tie-break only (must stay < 1_000_000 so a higher rung
        -- in bags always wins, even when buffer-short / no refinable plants).
        -- Settled lower rungs used to score +50M and beat exact-tier after Apo
        -- brewed away refinable plants while Milksap seeds remained in bags.
        local deficit = SkillUp.SeedDeficit and tonumber(SkillUp.SeedDeficit(uid)) or 0
        local settleBonus = 0
        if deficit <= 0 then
            settleBonus = 500000
        elseif refinable >= deficit then
            settleBonus = 300000
        elseif refinable > 0 then
            settleBonus = 100000 + math.min(refinable, 99) * 100
        else
            settleBonus = math.max(0, 5000 - deficit * 10)
        end
        local tier = 1
        if SM.SeedReplantTier then
            tier = tonumber(SM.SeedReplantTier(uid)) or 1
        end
        -- Highest skillReq <= targetMax first; settle / Eternal / count tie-break.
        local score = (req * 1000000) + settleBonus + (tier * 10000) + count
        ranked[#ranked + 1] = {
            seedUid = uid,
            skillReq = req,
            plantUid = plantUid,
            count = count,
            item = item,
            score = score,
        }
    end)
    table.sort(ranked, function(a, b)
        return (tonumber(a.score) or 0) > (tonumber(b.score) or 0)
    end)
    SkillUp._bagMainList = ranked
    SkillUp._bestBagSeedKey = cacheKey
    SkillUp._bestBagSeed = ranked[1]
    return ranked[1]
end

--- Bag seeds left after short-watch claims (seed and linked plant).
function SkillUp.FreeBagSeeds(pick)
    if type(pick) ~= "table" then
        return 0
    end
    local bag = tonumber(pick.count) or 0
    local seedUid = tonumber(pick.seedUid) or 0
    local plantUid = tonumber(pick.plantUid) or 0
    local need = 0
    if SkillUp.WatchDemandReserve then
        need = tonumber(SkillUp.WatchDemandReserve(seedUid)) or 0
        if plantUid > 0 then
            local plantNeed = tonumber(SkillUp.WatchDemandReserve(plantUid)) or 0
            if plantNeed > need then
                need = plantNeed
            end
        end
    end
    local free = bag - need
    if free < 0 then
        return 0
    end
    return free
end

--- Highest-scoring bag main that still has seeds SkillUp may use.
function SkillUp.PickMovableBagSeed()
    SkillUp.PickBestBagSeed()
    local list = SkillUp._bagMainList
    if type(list) ~= "table" then
        return nil
    end
    for i = 1, #list do
        if SkillUp.FreeBagSeeds(list[i]) >= 1 then
            return list[i]
        end
    end
    return nil
end

--- First movable bag main that still needs seeds (buffer or empty plots).
function SkillUp.PickCultSupplySeed()
    SkillUp.PickBestBagSeed()
    local list = SkillUp._bagMainList
    if type(list) ~= "table" then
        return nil
    end
    for i = 1, #list do
        local pick = list[i]
        if SkillUp.FreeBagSeeds(pick) >= 1 then
            local deficit = tonumber(SkillUp.SeedDeficit(pick.seedUid)) or 0
            if deficit >= 1 then
                return pick
            end
        end
    end
    return nil
end

--- Seed budget - SeedEconomy / UpgradeSeed facade over Refine.GetSeedBudget.
local function SeedBudget(seedUid)
    local SE = StockPiler.SeedEconomy
    if SE and SE.GetSeedBudget then
        local b = SE.GetSeedBudget(seedUid)
        if type(b) == "table" then
            return b
        end
    end
    local US = StockPiler.UpgradeSeed
    if US and US.GetSeedBudget then
        return US.GetSeedBudget(seedUid)
    end
    local Refine = StockPiler.Refine
    if Refine and Refine.GetSeedBudget then
        local b = Refine.GetSeedBudget(seedUid)
        if type(b) == "table" then
            return b
        end
    end
    return {
        live = 0,
        ground = 0,
        outstanding = 0,
        credit = 0,
        headroom = 0,
        bufferMin = 0,
    }
end

--- True when SkillUp should refine before planting (upgrade or buffer fill).
--- Used by PickPlantJob hold and Refine.ShouldAllowRefineNow so plant-first
--- cannot starve a live refine path.
function SkillUp.PreferRefineOverPlant()
    if SkillUp.ShouldCultPlant() ~= true then
        return false
    end
    if SkillUp.HasUpgradePlant() == true then
        return true
    end
    local target = SkillUp.PickRefineTarget()
    if type(target) ~= "table" or target.upgrade == true then
        return false
    end
    local seedUid = tonumber(target.seedUid) or 0
    if seedUid <= 0 then
        return false
    end
    local budget = SeedBudget(seedUid)
    local buffer = tonumber(budget.bufferMin) or 0
    local headroom = tonumber(budget.headroom) or 0
    if buffer <= 0 or headroom <= 0 then
        return false
    end
    local uses = SkillUp.RefineUsesForTarget(target)
    return (tonumber(uses) or 0) >= 1
end

function SkillUp.PickPlantJob()
    if SkillUp.ShouldCultPlant() ~= true then
        return nil
    end
    -- Hold planting while refine can make progress (upgrade or buffer fill).
    if SkillUp.PreferRefineOverPlant() == true then
        if StockPiler.Refine and StockPiler.Refine.MarkRefineDue then
            if SkillUp.HasUpgradePlant() == true then
                StockPiler.Refine.MarkRefineDue("skill-up")
            else
                StockPiler.Refine.MarkRefineDue("skill-up-buffer")
            end
        end
        if StockPiler.Debug and StockPiler.Debug.LogOp then
            local pick = SkillUp.PickMovableBagSeed()
            local seedUid = type(pick) == "table" and (tonumber(pick.seedUid) or 0) or 0
            local budget = SeedBudget(seedUid)
            StockPiler.Debug.LogOp("skillup", string.format(
                "hold-plant seedUid=%d headroom=%d upgrade=%s (prefer refine)",
                seedUid,
                tonumber(budget.headroom) or 0,
                tostring(SkillUp.HasUpgradePlant() == true)
            ))
        end
        return nil
    end
    local pick = SkillUp.PickMovableBagSeed()
    if type(pick) ~= "table" or (tonumber(pick.seedUid) or 0) <= 0 then
        return nil
    end
    local seedUid = tonumber(pick.seedUid) or 0
    local plantUid = tonumber(pick.plantUid) or 0
    local budget = SeedBudget(seedUid)
    local buffer = tonumber(budget.bufferMin) or 0
    local live = tonumber(budget.live) or 0
    local headroom = tonumber(budget.headroom) or 0
    local empty = SkillUp.CountEmptyPlots()
    local bagSeeds = tonumber(pick.count) or 0

    local refinable = 0
    if plantUid > 0 and StockPiler.Refine and StockPiler.Refine.CountRefinablePlants then
        local Items = StockPiler.Items
        local spec = Items and Items.ToSpec and Items.ToSpec(plantUid) or nil
        refinable = tonumber(StockPiler.Refine.CountRefinablePlants(plantUid, spec)) or 0
    end

    -- Fill empty plots whenever bag has seeds (shared PlantableSurplus skillup mode).
    local US = StockPiler.UpgradeSeed
    local plantable = 0
    if US and US.PlantableSurplus then
        plantable = tonumber(US.PlantableSurplus(seedUid, bagSeeds, empty, { mode = "skillup" })) or 0
    elseif empty > 0 and bagSeeds > 0 then
        plantable = math.min(bagSeeds, empty)
    end
    -- Never plant seeds still claimed by short enabled watches.
    local watchSeedNeed = SkillUp.WatchDemandReserve(seedUid)
    if plantUid > 0 then
        local plantNeed = SkillUp.WatchDemandReserve(plantUid)
        if plantNeed > watchSeedNeed then
            watchSeedNeed = plantNeed
        end
    end
    if watchSeedNeed > 0 then
        local freeSeeds = bagSeeds - watchSeedNeed
        if freeSeeds < 1 then
            plantable = 0
        elseif plantable > freeSeeds then
            plantable = freeSeeds
        end
    end

    if plantable < 1 then
        if StockPiler.Debug and StockPiler.Debug.LogOp then
            StockPiler.Debug.LogOp("skillup", string.format(
                "no-plant-job seedUid=%d live=%d buffer=%d headroom=%d empty=%d refinable=%d bag=%d",
                seedUid, live, buffer, headroom, empty, refinable, bagSeeds
            ))
        end
        return nil
    end
    if StockPiler.Debug and StockPiler.Debug.LogOp then
        StockPiler.Debug.LogOp("skillup", string.format(
            "plant-job seedUid=%d live=%d headroom=%d empty=%d plantable=%d",
            seedUid, live, headroom, empty, plantable
        ))
    end
    SkillUp._lastSeedUid = seedUid
    SkillUp._lastPlantUid = plantUid
    return {
        seedUid = seedUid,
        plantUid = plantUid,
        seed = pick.item or { uniqueID = seedUid },
        seedHave = bagSeeds,
        plantable = plantable,
        deficit = plantable,
        craftsShort = plantable,
        skillReq = tonumber(pick.skillReq) or 0,
        pickMode = "skill_up",
        plantReason = "skill_up",
        role = "main",
    }
end

function SkillUp.CountEmptyPlots()
    local US = StockPiler.UpgradeSeed
    if US and US.CountEmptyPlots then
        return US.CountEmptyPlots()
    end
    local Grow = StockPiler.Grow
    if Grow and Grow.CountEmptyPlots then
        return tonumber(Grow.CountEmptyPlots()) or 0
    end
    return 0
end

--- Seeds still needed for buffer headroom and/or empty-plot planting.
--- Delegates to UpgradeSeed.SeedDeficit(..., "skillup").
function SkillUp.SeedDeficit(seedUid)
    local US = StockPiler.UpgradeSeed
    if US and US.SeedDeficit then
        return US.SeedDeficit(seedUid, "skillup")
    end
    seedUid = tonumber(seedUid) or 0
    local empty = SkillUp.CountEmptyPlots()
    local budget = SeedBudget(seedUid)
    local headroom = tonumber(budget.headroom) or 0
    local live = tonumber(budget.live) or 0
    local needPlots = empty
    if live >= empty then
        needPlots = 0
    else
        needPlots = empty - live
    end
    return math.max(headroom, needPlots)
end

--- Best refinable main plant under Cult skill floor (nil if none).
--- Uses FloorCultTier (not TargetMaxSkill) so lucky crits above the Apo pace
--- can still be refined into seeds; planting stays capped by TargetMaxSkill.
function SkillUp.ScanBestRefinePlant()
    local cult = SkillUp.GetCultSkill()
    local targetMax = SkillUp.FloorCultTier(cult)
    if targetMax < 1 then
        targetMax = SkillUp.TargetMaxSkill()
    end
    if targetMax < 1 then
        targetMax = 1
    end
    local US = StockPiler.UpgradeSeed
    if US and US.ScanUpgradePlant then
        local seed = SkillUp.PickBestBagSeed and SkillUp.PickBestBagSeed() or nil
        local ownedReq = type(seed) == "table" and (tonumber(seed.skillReq) or 0) or 0
        return US.ScanUpgradePlant({
            climbCap = targetMax,
            ownedSeedReq = ownedReq,
            mainsOnly = true,
        })
    end
    return nil
end

--- True when a higher-tier plant can *actually* refine into seeds now.
--- A lone upgrade plant that fails PlantRefineSurplus must not block planting.
function SkillUp.HasUpgradePlant()
    if SkillUp.ShouldCultPlant() ~= true then
        return false
    end
    local plant = SkillUp.ScanBestRefinePlant()
    if type(plant) ~= "table" then
        return false
    end
    local plantReq = tonumber(plant.skillReq) or 0
    if plantReq < 1 then
        return false
    end
    local seed = SkillUp.PickBestBagSeed()
    local seedReq = type(seed) == "table" and (tonumber(seed.skillReq) or 0) or 0
    if plantReq <= seedReq then
        return false
    end
    local uses = SkillUp.RefineUsesForTarget({
        seedUid = tonumber(plant.seedUid) or 0,
        plantUid = tonumber(plant.plantUid) or 0,
        skillReq = plantReq,
        upgrade = true,
    })
    return (tonumber(uses) or 0) >= 1
end

--- Resolve seed/plant for SkillUp refine (replant + tier graduation).
--- Prefers upgrade only when RefineUsesForTarget >= 1; else same-tier.
function SkillUp.PickRefineTarget()
    local SM = StockPiler.SeedMap

    -- Prefer graduating when the upgrade plant can refine now.
    local upgrade = SkillUp.ScanBestRefinePlant()
    if type(upgrade) == "table" then
        local plantReq = tonumber(upgrade.skillReq) or 0
        local seed = SkillUp.PickBestBagSeed()
        local seedReq = type(seed) == "table" and (tonumber(seed.skillReq) or 0) or 0
        if plantReq > seedReq then
            local target = {
                seedUid = tonumber(upgrade.seedUid) or 0,
                plantUid = tonumber(upgrade.plantUid) or 0,
                skillReq = plantReq,
                upgrade = true,
            }
            local uses = SkillUp.RefineUsesForTarget(target)
            if (tonumber(uses) or 0) >= 1 then
                return target
            end
            if StockPiler.Debug and StockPiler.Debug.LogOp then
                StockPiler.Debug.LogOp("skillup", string.format(
                    "upgrade-skip plantUid=%d req=%d (no refine uses; fall through)",
                    tonumber(upgrade.plantUid) or 0, plantReq
                ))
            end
        end
    end

    local pick = SkillUp.PickMovableBagSeed()
    if type(pick) == "table" and (tonumber(pick.seedUid) or 0) > 0 then
        local plantUid = tonumber(pick.plantUid) or 0
        if plantUid <= 0 then
            plantUid = FindBagPlantForSeed(pick.seedUid, pick.item)
        end
        -- Prefer an in-bag harvest product for this seed when available.
        if SM and SM.HarvestProducts and (tonumber(pick.seedUid) or 0) > 0 then
            local Refine = StockPiler.Refine
            local products = SM.HarvestProducts(pick.seedUid) or {}
            for i = 1, #products do
                local pUid = tonumber(products[i] and products[i].uid) or 0
                if pUid > 0 and Refine and Refine.CountRefinablePlants
                    and (tonumber(Refine.CountRefinablePlants(pUid, nil)) or 0) > 0
                then
                    plantUid = pUid
                    break
                end
            end
        end
        if plantUid <= 0 then
            plantUid = FindBagPlantForSeed(pick.seedUid, pick.item)
        end
        return {
            seedUid = tonumber(pick.seedUid) or 0,
            plantUid = plantUid,
            skillReq = tonumber(pick.skillReq) or 0,
        }
    end

    local seedUid = tonumber(SkillUp._lastSeedUid) or 0
    local plantUid = tonumber(SkillUp._lastPlantUid) or 0
    if seedUid > 0 then
        if plantUid <= 0 and SM and SM.PrimaryPlantForSeed then
            plantUid = tonumber(SM.PrimaryPlantForSeed(seedUid)) or 0
        end
        if plantUid > 0 then
            return { seedUid = seedUid, plantUid = plantUid }
        end
        if SM and SM.HarvestProducts then
            local Refine = StockPiler.Refine
            local products = SM.HarvestProducts(seedUid) or {}
            local fallback = nil
            for i = 1, #products do
                local pUid = tonumber(products[i] and products[i].uid) or 0
                if pUid > 0 then
                    local refinable = 0
                    if Refine and Refine.CountRefinablePlants then
                        refinable = tonumber(Refine.CountRefinablePlants(pUid, nil)) or 0
                    end
                    if refinable > 0 then
                        return { seedUid = seedUid, plantUid = pUid }
                    end
                    if fallback == nil then
                        fallback = pUid
                    end
                end
            end
            if fallback ~= nil then
                return { seedUid = seedUid, plantUid = fallback }
            end
        end
    end

    return nil
end

--- How many SkillUp refine uses a PickRefineTarget-shaped row can issue (0 if none).
--- Shared by HasUpgradePlant / PickRefineTarget / AppendRefineIntents / HasRefinablePlants.
function SkillUp.RefineUsesForTarget(target)
    if type(target) ~= "table" then
        return 0, nil
    end
    local seedUid = tonumber(target.seedUid) or 0
    local plantUid = tonumber(target.plantUid) or 0
    if seedUid <= 0 or plantUid <= 0 then
        return 0, nil
    end
    local SM = StockPiler.SeedMap
    if SM and SM.ResolveSeedUidForPlant then
        local resolved = tonumber(SM.ResolveSeedUidForPlant(plantUid, nil)) or 0
        if resolved > 0 then
            -- Never downgrade an explicit same/higher-tier target seed to a lower
            -- crit-refine seed (83542 used to resolve to 84042 and waste L175 plants).
            local function skillOf(uid)
                uid = tonumber(uid) or 0
                if uid <= 0 then
                    return 0
                end
                local Items = StockPiler.Items
                if Items and Items.GetByUid then
                    local row = Items.GetByUid(uid)
                    if type(row) == "table" then
                        return SeedSkillReq(row)
                    end
                end
                return 0
            end
            local rReq = skillOf(resolved)
            local tReq = skillOf(seedUid)
            if seedUid <= 0 then
                seedUid = resolved
            elseif rReq > 0 and tReq > 0 and rReq < tReq then
                -- keep target seedUid
            else
                seedUid = resolved
            end
        end
    end
    local budget = SeedBudget(seedUid)
    local deficit = SkillUp.SeedDeficit(seedUid)
    local isUpgrade = target.upgrade == true
    -- Tier graduation must refine even when SeedDeficit is 0.
    if deficit <= 0 and not isUpgrade then
        return 0, nil
    end
    local headroom = tonumber(budget.headroom) or 0
    local usesCap = deficit
    if isUpgrade and usesCap < 1 then
        usesCap = 5
    end
    -- Headroom caps same-tier buffer fills. Graduation keeps its own cap
    -- (full buffer used to refine 5, a 1-seed gap refined only 1).
    if not isUpgrade and headroom > 0 and headroom < usesCap then
        usesCap = headroom
    elseif not isUpgrade and headroom <= 0 and deficit > 0 then
        usesCap = deficit
    end
    if isUpgrade and usesCap < 1 then
        usesCap = 5
    end
    local Inv = StockPiler.Inventory
    local bagCount = 0
    if plantUid > 0 and Inv and Inv.CountByUid then
        bagCount = tonumber(Inv.CountByUid(plantUid)) or 0
    end
    local surplus = SkillUp.PlantRefineSurplus(plantUid, seedUid, bagCount)
    if surplus < 1 then
        return 0, nil
    end
    if surplus < usesCap then
        usesCap = surplus
    end
    local Items = StockPiler.Items
    local spec = Items and Items.ToSpec and Items.ToSpec(plantUid) or nil
    local Refine = StockPiler.Refine
    local refinable = 0
    if Refine and Refine.CountRefinablePlants then
        refinable = tonumber(Refine.CountRefinablePlants(plantUid, spec)) or 0
    end
    if refinable <= 0 then
        return 0, nil
    end
    local uses = math.min(refinable, usesCap, 5)
    if uses < 1 then
        return 0, nil
    end
    return uses, {
        seedUid = seedUid,
        plantUid = plantUid,
        spec = spec,
        budget = budget,
        isUpgrade = isUpgrade,
        headroom = headroom,
        deficit = deficit,
        skillReq = tonumber(target.skillReq) or 0,
        refinable = refinable,
    }
end

--- Refine intent: convert plants for buffer headroom / empty-plot gaps / upgrades.
function SkillUp.AppendRefineIntents(intents, appendFn)
    if type(intents) ~= "table" or type(appendFn) ~= "function" then
        return
    end
    if SkillUp.ShouldCultPlant() ~= true then
        return
    end
    local target = SkillUp.PickRefineTarget()
    local uses, info = SkillUp.RefineUsesForTarget(target)
    if (tonumber(uses) or 0) < 1 or type(info) ~= "table" then
        return
    end
    SkillUp._lastSeedUid = info.seedUid
    SkillUp._lastPlantUid = info.plantUid
    appendFn({
        spec = info.spec,
        seedUid = info.seedUid,
        plantUid = info.plantUid,
        specKey = "skill_up:" .. tostring(info.seedUid),
    }, "skill-up", uses, info.budget)
    if StockPiler.Debug and StockPiler.Debug.LogOp then
        StockPiler.Debug.LogOp("skillup", string.format(
            "refine-intent seedUid=%d plantUid=%d uses=%d empty=%d refinable=%d upgrade=%s req=%d headroom=%d deficit=%d",
            info.seedUid, info.plantUid, uses, SkillUp.CountEmptyPlots(), info.refinable,
            tostring(info.isUpgrade), info.skillReq,
            info.headroom, info.deficit
        ))
    end
end

--- Preferred vendor seed for AutoBuy: same line as bag pick / refine plants when possible.
function SkillUp.ResolveBuySeedTarget()
    -- Top up a movable SkillUp line that still needs seeds. Skip a bag line
    -- whose copies are all claimed by short watches.
    local pick = SkillUp.PickCultSupplySeed and SkillUp.PickCultSupplySeed() or nil
    if type(pick) == "table" and (tonumber(pick.seedUid) or 0) > 0 then
        return {
            seedUid = tonumber(pick.seedUid) or 0,
            skillReq = tonumber(pick.skillReq) or 0,
            targetMax = SkillUp.TargetMaxSkill(),
        }
    end

    local targetMax = SkillUp.TargetMaxSkill()
    if targetMax < 1 then
        targetMax = 1
    end
    -- Prefer the seed linked to refinable plants already in bags.
    local preferUid = 0
    local plant = SkillUp.ScanBestRefinePlant and SkillUp.ScanBestRefinePlant() or nil
    if type(plant) == "table" then
        preferUid = tonumber(plant.seedUid) or 0
    end

    local bestUid, bestReq, bestScore = 0, -1, -1
    local function consider(uid, item)
        uid = tonumber(uid) or 0
        if uid <= 0 or type(item) ~= "table" then
            return
        end
        local SM = StockPiler.SeedMap
        if SM and SM.IsSeedPacketUid and SM.IsSeedPacketUid(uid) then
            return
        end
        if SM and SM.IsBagSeedOrSpore and not SM.IsBagSeedOrSpore(item) then
            return
        end
        local req = SeedSkillReq(item)
        if req <= 0 or req > targetMax then
            return
        end
        if not IsMainIngredientSeed(uid, item) then
            return
        end
        local Inv = StockPiler.Inventory
        local bag = Inv and Inv.CountByUid and tonumber(Inv.CountByUid(uid)) or 0
        if bag >= 1 then
            local plantUid = 0
            if SM and SM.PrimaryPlantForSeed then
                plantUid = tonumber(SM.PrimaryPlantForSeed(uid)) or 0
            end
            if SkillUp.FreeBagSeeds({
                seedUid = uid,
                plantUid = plantUid,
                count = bag,
            }) < 1 then
                return
            end
        end
        local tier = SM and SM.SeedReplantTier and tonumber(SM.SeedReplantTier(uid)) or 1
        local exactBonus = (req == targetMax) and 100000000 or 0
        local preferBonus = (preferUid > 0 and uid == preferUid) and 50000000 or 0
        local score = exactBonus + preferBonus + (req * 1000000) + (tier * 10000)
        if score > bestScore then
            bestScore = score
            bestReq = req
            bestUid = uid
        end
    end

    -- Learned items (may include seeds not in bags).
    local items = StockPiler.Account and StockPiler.Account.items
    if type(items) == "table" then
        for key, row in pairs(items) do
            if type(row) == "table" then
                local uid = tonumber(row.uniqueID) or tonumber(key) or 0
                consider(uid, row)
            end
        end
    end

    -- Open vendor rows.
    local VA = StockPiler.VendorAdapter
    if VA and VA.GetMatchIndex then
        local index = VA.GetMatchIndex()
        if type(index) == "table" and type(index.rows) == "table" then
            for i = 1, #index.rows do
                local row = index.rows[i]
                local item = row and row.item
                if type(item) == "table" then
                    consider(item.uniqueID, item)
                end
            end
        end
    end

    if bestUid <= 0 then
        return nil
    end
    return {
        seedUid = bestUid,
        skillReq = bestReq,
        targetMax = targetMax,
    }
end

--- True when SkillUp can issue at least one refine use right now.
function SkillUp.HasRefinablePlants()
    local target = SkillUp.PickRefineTarget()
    local uses = SkillUp.RefineUsesForTarget(target)
    return (tonumber(uses) or 0) >= 1
end

--- Buy when SeedDeficit >= 1 for the chosen line (plots + buffer), even if bags
--- already hold some seeds. Refine-before-buy when plants can cover that line.
function SkillUp.ShouldCultBuy()
    if SkillUp.ShouldCultPlant() ~= true then
        return false
    end
    local Watch = StockPiler.Watch
    if not (Watch and Watch.IsAutoBuyEnabled and Watch.IsAutoBuyEnabled() == true) then
        return false
    end

    local pick = SkillUp.PickCultSupplySeed()
    local seedUid = 0
    local plantUid = 0
    if type(pick) == "table" then
        seedUid = tonumber(pick.seedUid) or 0
        plantUid = tonumber(pick.plantUid) or 0
    elseif SkillUp.PickMovableBagSeed() ~= nil then
        -- Movable seeds are already at buffer and plots; do not buy the reserved line.
        return false
    else
        -- Empty or fully reserved bags: refine leftover plants before opening the vendor.
        if SkillUp.HasRefinablePlants() == true or SkillUp.HasUpgradePlant() == true then
            return false
        end
        local target = SkillUp.ResolveBuySeedTarget()
        if type(target) ~= "table" then
            return false
        end
        seedUid = tonumber(target.seedUid) or 0
    end
    if seedUid <= 0 then
        return false
    end

    local deficit = SkillUp.SeedDeficit(seedUid)
    if deficit < 1 then
        return false
    end

    -- Plants for this seed: refine before AutoBuy only when refine can run.
    if plantUid <= 0 then
        local SM = StockPiler.SeedMap
        if SM and SM.PrimaryPlantForSeed then
            plantUid = tonumber(SM.PrimaryPlantForSeed(seedUid)) or 0
        end
    end
    if plantUid > 0 then
        local uses = SkillUp.RefineUsesForTarget({
            seedUid = seedUid,
            plantUid = plantUid,
            upgrade = false,
        })
        if (tonumber(uses) or 0) >= 1 then
            return false
        end
    end
    return true
end

function SkillUp.CollectBuyJobs()
    local jobs = {}
    if SkillUp.ShouldCultBuy() == true then
        local target = SkillUp.ResolveBuySeedTarget()
        if type(target) == "table" and (tonumber(target.seedUid) or 0) > 0 then
            local seedUid = tonumber(target.seedUid) or 0
            local deficit = SkillUp.SeedDeficit(seedUid)
            if deficit >= 1 then
                local MS = StockPiler.MaterialSpec
                local Inv = StockPiler.Inventory
                local sample = Inv and Inv.GetSample and Inv.GetSample(seedUid)
                local spec = nil
                if MS and MS.FromItemData and type(sample) == "table" then
                    spec = MS.FromItemData(sample, "main")
                elseif MS and MS.FromUid then
                    spec = MS.FromUid(seedUid)
                end
                jobs[#jobs + 1] = StockPiler.SeedEconomy.SeedBuyJob({
                    seedUid = seedUid,
                    deficit = deficit,
                    role = "main",
                    spec = spec,
                    specKey = "skill_up_seed:" .. tostring(seedUid),
                    skillReq = tonumber(target.skillReq) or 0,
                })
            end
        end
    end
    local containerJobs = SkillUp.CollectContainerBuyJobs() or {}
    for i = 1, #containerJobs do
        jobs[#jobs + 1] = containerJobs[i]
    end
    return jobs
end

--- Live Cult stall for the watch row. Nil when planting, refining, or the
--- buffer is already met. Same checks as the chat latch, without waiting for
--- the grow tick (that tick runs after the reload paint).
function SkillUp.CultStallReason()
    if SkillUp.ShouldCultPlant() ~= true then
        return nil
    end
    if SkillUp.HasRefinablePlants() == true or SkillUp.HasUpgradePlant() == true then
        return nil
    end
    if SkillUp.CountEmptyPlots() <= 0 then
        return nil
    end
    local pick = SkillUp.PickBestBagSeed()
    local seedUid = 0
    if type(pick) == "table" then
        seedUid = tonumber(pick.seedUid) or 0
    else
        local target = SkillUp.ResolveBuySeedTarget and SkillUp.ResolveBuySeedTarget() or nil
        if type(target) == "table" then
            seedUid = tonumber(target.seedUid) or 0
        end
    end
    if seedUid > 0 and (tonumber(SkillUp.SeedDeficit(seedUid)) or 0) < 1 then
        return nil
    end
    local canBuy = SkillUp.ShouldCultBuy() == true
    local VA = StockPiler.VendorAdapter
    local storeOpen = VA and VA.IsStoreOpen and VA.IsStoreOpen() == true
    if canBuy and storeOpen then
        return nil
    end
    if canBuy and not storeOpen then
        return "need_vendor"
    end
    if not canBuy then
        local Watch = StockPiler.Watch
        if not (Watch and Watch.IsAutoBuyEnabled and Watch.IsAutoBuyEnabled() == true) then
            return "autobuy_off"
        end
        return "no_vendor_seed"
    end
    return "no_seeds"
end

local function RepaintSkillUpWatch()
    local Ui = StockPiler.Ui
    if not Ui then
        return
    end
    -- Content key ignores the stall latch, so an already-open window would
    -- keep the reload paint until /stp dumpall bumped snapGen.
    if Ui.BypassWatchThrottle then
        Ui.BypassWatchThrottle()
    end
    local Bus = StockPiler.EventBus
    if Bus and Bus.FireWatchUiDirty then
        Bus.FireWatchUiDirty({ immediate = true, reason = "skillup-stall" })
    end
end

--- Attention sound only when the player must act (open a vendor, buy seeds
--- or vials). Plant, harvest, and refine waits stay quiet while AutoGrow runs.
local function AutoGrowWillProgress()
    local Watch = StockPiler.Watch
    return Watch and Watch.IsAutoGrowEnabled and Watch.IsAutoGrowEnabled() == true
end

local function ApoStallNeedsUser(why)
    if why == "need_container_vendor" or why == "no_vendor_container" or why == "no_vial"
        or why == "craft_bag_full"
    then
        return true
    end
    return AutoGrowWillProgress() ~= true
end

local function PlayUserActionSound()
    local SE = StockPiler.SeedEconomy
    if SE and SE.PlayUserActionSound then
        SE.PlayUserActionSound()
    end
end

--- Notify once per Cult stall reason; clear latch when condition lifts.
function SkillUp.MaybeNotifyStall()
    local reason = SkillUp.CultStallReason()
    if reason == nil then
        if SkillUp._stallLatch ~= nil then
            SkillUp._stallLatch = nil
            RepaintSkillUpWatch()
        end
        return
    end
    if SkillUp._stallLatch == reason then
        return
    end
    SkillUp._stallLatch = reason
    RepaintSkillUpWatch()
    local msg
    if StockPiler.T then
        msg = StockPiler.T("skillup.stall." .. reason)
    else
        msg = L"<icon02486> Skill up Culti stalled - need seeds."
    end
    if StockPiler.Debug and StockPiler.Debug.Print then
        StockPiler.Debug.Print(msg)
    end
    PlayUserActionSound()
end

----------------------------------------------------------------
-- Apo SkillUp - brew from surplus main + resin + container
----------------------------------------------------------------

SkillUp._apoStallLatch = nil
SkillUp._apoBrewRow = nil

function SkillUp.ApoTargetTier()
    local tier = SkillUp.FloorApoTier(SkillUp.GetApoSkill())
    -- "Vendor has no vial" was for the previous tier. The next shelf can
    -- still sell one, so drop that flag when the tier changes.
    if SkillUp._apoVialTier ~= nil and SkillUp._apoVialTier ~= tier then
        SkillUp._apoNoVendorContainer = nil
    end
    SkillUp._apoVialTier = tier
    return tier
end

function SkillUp.ShouldApoBrew()
    if SkillUp.IsApoEnabled() ~= true then
        return false
    end
    local Caps = StockPiler.TradeSkillCaps
    if Caps and Caps.CanBrewPotions and Caps.CanBrewPotions() ~= true then
        return false
    end
    if SkillUp.WatchesAllowIdleSkillUp() ~= true then
        return false
    end
    return true
end

--- Next Apo ladder step above current skill (25, 50, ..., 200).
function SkillUp.NextApoTier(apoSkill)
    apoSkill = tonumber(apoSkill) or SkillUp.GetApoSkill()
    local tiers = SkillUp.APO_TIERS or { 1, 25, 50, 75, 100, 125, 150, 175, 200 }
    for i = 1, #tiers do
        local t = tiers[i]
        if apoSkill < t then
            return t
        end
    end
    return SkillUp.APO_MAX or 200
end

----------------------------------------------------------------
-- Empirical skill-up rates (per skill level) for buy estimates
----------------------------------------------------------------

SkillUp.SKILL_RATE_MIN_ATTEMPTS = 5
SkillUp.SKILL_PENDING_TTL_SEC = 90
SkillUp.SKILL_RATE_NEARBY_SPAN = 3
-- v3: each SkillUp brew/plant counts as an attempt (v2 under-counted while pending).
SkillUp.SKILL_RATES_SCHEMA = 3
SkillUp.APO_VIAL_BUY_CAP = 300

local function NowSec()
    return StockPiler.Util and StockPiler.Util.NowSec and StockPiler.Util.NowSec() or 0
end

local function RatesTable()
    local Acc = StockPiler.Account
    if type(Acc) ~= "table" then
        return nil
    end
    local wantV = SkillUp.SKILL_RATES_SCHEMA or 2
    if type(Acc.skillUpRates) ~= "table" or tonumber(Acc.skillUpRates.v) ~= wantV then
        -- v1 keyed by tier band; wipe so per-level samples are not mixed with averages.
        Acc.skillUpRates = { v = wantV, cult = {}, apo = {} }
    end
    if type(Acc.skillUpRates.cult) ~= "table" then
        Acc.skillUpRates.cult = {}
    end
    if type(Acc.skillUpRates.apo) ~= "table" then
        Acc.skillUpRates.apo = {}
    end
    return Acc.skillUpRates
end

local function LevelBucket(kind, level, create)
    local rates = RatesTable()
    if type(rates) ~= "table" then
        return nil
    end
    local root = rates[kind]
    if type(root) ~= "table" then
        return nil
    end
    level = math.floor(tonumber(level) or 0)
    if level < 1 then
        return nil
    end
    local key = tostring(level)
    local row = root[key]
    if type(row) ~= "table" then
        if create ~= true then
            return nil
        end
        row = { attempts = 0, hits = 0 }
        root[key] = row
    end
    return row
end

--- Record one Cult attempt at the current skill level (each plant counts).
--- opts.extendOnly: harvest path - extend live pending only; never count an attempt.
function SkillUp.NoteCultAttempt(opts)
    opts = type(opts) == "table" and opts or {}
    local cult = SkillUp.GetCultSkill()
    if cult <= 0 or cult >= (SkillUp.CULT_MAX or 200) then
        return false
    end
    local level = math.floor(cult)
    local ttl = SkillUp.SKILL_PENDING_TTL_SEC or 90
    local seedUid = tonumber(opts.seedUid) or 0
    local now = NowSec()
    local pending = SkillUp._pendingCult
    local pendingLive = type(pending) == "table" and (tonumber(pending.untilTime) or 0) > now

    if opts.extendOnly == true then
        if pendingLive then
            pending.untilTime = now + ttl
            if seedUid > 0 then
                pending.seedUid = seedUid
            end
            return true
        end
        return false
    end

    -- Each plant is an attempt. Credit the level the pending window was armed at.
    local rowLevel = level
    if pendingLive then
        rowLevel = tonumber(pending.level) or level
        pending.untilTime = now + ttl
        if seedUid > 0 then
            pending.seedUid = seedUid
        end
    else
        SkillUp._pendingCult = {
            level = level,
            seedUid = seedUid,
            untilTime = now + ttl,
        }
    end
    local row = LevelBucket("cult", rowLevel, true)
    if type(row) ~= "table" then
        return false
    end
    row.attempts = (tonumber(row.attempts) or 0) + 1
    return true
end

--- Record one Apo SkillUp brew attempt (each Perform counts while SkillUp session).
function SkillUp.NoteApoAttempt(opts)
    opts = type(opts) == "table" and opts or {}
    if opts.skillUp ~= true then
        return false
    end
    local apo = SkillUp.GetApoSkill()
    if apo <= 0 or apo >= (SkillUp.APO_MAX or 200) then
        return false
    end
    local level = math.floor(apo)
    local ttl = SkillUp.SKILL_PENDING_TTL_SEC or 90
    local now = NowSec()
    local pending = SkillUp._pendingApo
    local pendingLive = type(pending) == "table" and (tonumber(pending.untilTime) or 0) > now

    -- Each brew is an attempt. Credit the level the pending window was armed at
    -- so multi-brew streaks before a skill tick are not collapsed to 1/1 = 100%.
    local rowLevel = level
    if pendingLive then
        rowLevel = tonumber(pending.level) or level
        pending.untilTime = now + ttl
    else
        SkillUp._pendingApo = {
            level = level,
            untilTime = now + ttl,
        }
    end
    local row = LevelBucket("apo", rowLevel, true)
    if type(row) ~= "table" then
        return false
    end
    row.attempts = (tonumber(row.attempts) or 0) + 1
    if StockPiler.Debug and StockPiler.Debug.LogOp then
        StockPiler.Debug.LogOp("skillup", string.format(
            "apo-attempt level=%d attempts=%d pending=%s",
            rowLevel,
            tonumber(row.attempts) or 0,
            pendingLive and "extend" or "arm"
        ))
    end
    return true
end

function SkillUp.OnCultSkillDelta(delta)
    delta = tonumber(delta) or 0
    if delta < 1 or delta > 3 then
        SkillUp._pendingCult = nil
        return false
    end
    local pending = SkillUp._pendingCult
    if type(pending) ~= "table" then
        return false
    end
    if (tonumber(pending.untilTime) or 0) < NowSec() then
        SkillUp._pendingCult = nil
        return false
    end
    local level = tonumber(pending.level) or math.floor(SkillUp.GetCultSkill())
    local seedUid = tonumber(pending.seedUid) or 0
    SkillUp._pendingCult = nil
    local row = LevelBucket("cult", level, true)
    if type(row) == "table" then
        -- One craft -> one skill-up event (credit the level the attempt was armed at).
        row.hits = (tonumber(row.hits) or 0) + 1
    end
    local SM = StockPiler.SeedMap
    if seedUid > 0 and SM and SM.NoteCultSkillHit then
        SM.NoteCultSkillHit(seedUid, delta)
    end
    if StockPiler.Debug and StockPiler.Debug.LogOp then
        StockPiler.Debug.LogOp("skillup", string.format(
            "cult-hit level=%d delta=%d hits=%d attempts=%d",
            level, delta, tonumber(row and row.hits) or 0, tonumber(row and row.attempts) or 0
        ))
    end
    return true
end

function SkillUp.OnApoSkillDelta(delta)
    delta = tonumber(delta) or 0
    if delta < 1 or delta > 3 then
        SkillUp._pendingApo = nil
        return false
    end
    local pending = SkillUp._pendingApo
    if type(pending) ~= "table" then
        return false
    end
    if (tonumber(pending.untilTime) or 0) < NowSec() then
        SkillUp._pendingApo = nil
        return false
    end
    local level = tonumber(pending.level) or math.floor(SkillUp.GetApoSkill())
    SkillUp._pendingApo = nil
    local row = LevelBucket("apo", level, true)
    if type(row) == "table" then
        row.hits = (tonumber(row.hits) or 0) + 1
    end
    if StockPiler.Debug and StockPiler.Debug.LogOp then
        StockPiler.Debug.LogOp("skillup", string.format(
            "apo-hit level=%d delta=%d hits=%d attempts=%d",
            level, delta, tonumber(row and row.hits) or 0, tonumber(row and row.attempts) or 0
        ))
    end
    return true
end

--- Empirical skill-up rate at an exact skill level (nil if too few samples).
--- Default expected crafts for one skill-up at `level` (SkillUp Apo floor mats).
--- Rises sharply toward the next tier - brewing T50 at skill 74 is much harder than at 50.
function SkillUp.DefaultCraftsPerLevel(kind, level)
    level = math.floor(tonumber(level) or 0)
    if kind == "apo" then
        local floorTier = SkillUp.FloorApoTier(level)
        local nextTier = SkillUp.NextApoTier(level)
        if nextTier <= floorTier then
            nextTier = floorTier + 25
        end
        local band = math.max(1, nextTier - floorTier)
        local pos = (level - floorTier) / math.max(1, band - 1)
        if pos < 0 then
            pos = 0
        elseif pos > 1 then
            pos = 1
        end
        -- ~1.3 at floor start -> ~28 near next tier (pos^2 curve).
        return 1.3 + (pos * pos) * 26.7
    end
    return 1.5
end

--- Soft rate for buy estimates: exact samples, else nearby, else tier-progress default.
--- Blends thin samples (n < min) with the default so early luck cannot under-buy.
--- opts.noNearby: skip +/-span lookup (Apo vial buy - lower levels look too easy).
function SkillUp.ResolveLevelRate(kind, level, opts)
    level = math.floor(tonumber(level) or 0)
    opts = type(opts) == "table" and opts or {}
    local minN = SkillUp.SKILL_RATE_MIN_ATTEMPTS or 5
    local defaultCrafts = SkillUp.DefaultCraftsPerLevel(kind, level)
    local defaultRate = 1 / math.max(defaultCrafts, 1)

    local function softFromRow(row, srcLevel)
        if type(row) ~= "table" then
            return nil
        end
        local attempts = tonumber(row.attempts) or 0
        local hits = tonumber(row.hits) or 0
        if attempts <= 0 then
            return nil
        end
        local emp = hits / attempts
        if attempts >= minN then
            -- Floor so a 0% sample still plans some crafts.
            local rate = emp
            if rate < 0.02 then
                rate = 0.02
            end
            return rate, hits, attempts, srcLevel, "exact"
        end
        local w = attempts / minN
        local rate = emp * w + defaultRate * (1 - w)
        if rate < 0.02 then
            rate = 0.02
        end
        return rate, hits, attempts, srcLevel, "blend"
    end

    local own = LevelBucket(kind, level, false)
    local rate, hits, attempts, src, how = softFromRow(own, level)
    if rate ~= nil then
        return rate, hits, attempts, src, how
    end

    if opts.noNearby ~= true then
        local span = tonumber(SkillUp.SKILL_RATE_NEARBY_SPAN) or 3
        for d = 1, span do
            local rLo, hLo, aLo, sLo, howLo = softFromRow(LevelBucket(kind, level - d, false), level - d)
            if rLo ~= nil then
                return rLo, hLo, aLo, sLo, howLo or "nearby"
            end
            local rHi, hHi, aHi, sHi, howHi = softFromRow(LevelBucket(kind, level + d, false), level + d)
            if rHi ~= nil then
                return rHi, hHi, aHi, sHi, howHi or "nearby"
            end
        end
    end
    return defaultRate, 0, 0, level, "default"
end

--- Expected crafts to climb from `fromLevel` (inclusive) to `toLevel` (exclusive).
local function ExpectedCraftsForRange(kind, fromLevel, toLevel)
    fromLevel = math.floor(tonumber(fromLevel) or 0)
    toLevel = math.floor(tonumber(toLevel) or 0)
    if toLevel <= fromLevel then
        return 0, false
    end
    local total = 0
    local anyEmpirical = false
    -- Apo vial buys: do not borrow easier nearby levels (e.g. 71 rate at skill 74).
    local rateOpts = kind == "apo" and { noNearby = true } or nil
    for level = fromLevel, toLevel - 1 do
        local rate, _, att, _, how = SkillUp.ResolveLevelRate(kind, level, rateOpts)
        if how == "exact" or how == "blend" or how == "nearby" then
            anyEmpirical = true
        end
        if (tonumber(att) or 0) > 0 then
            anyEmpirical = true
        end
        rate = tonumber(rate) or 0
        if rate > 0.02 then
            total = total + (1 / rate)
        else
            total = total + SkillUp.DefaultCraftsPerLevel(kind, level)
        end
    end
    return total, anyEmpirical
end

--- How many vials to keep for SkillUp Apo (one Apo tier band at a time).
--- Target = expected crafts from current skill to the next tier rung
--- (e.g. 50->75, or remaining 74->75) using per-level rates + tier-progress prior.
--- Not the full path to 200 - fewer vendor trips within a band, without stocking
--- hundreds of vials for every future tier.
function SkillUp.ApoContainerBuyTarget()
    local apo = SkillUp.GetApoSkill()
    local apoMax = SkillUp.APO_MAX or 200
    if apo <= 0 or apo >= apoMax then
        return 0
    end
    local nextTier = SkillUp.NextApoTier(apo)
    if nextTier <= apo then
        nextTier = apoMax
    end
    local gap = nextTier - apo
    if gap < 1 then
        return 0
    end
    local need = ExpectedCraftsForRange("apo", apo, nextTier)
    need = math.ceil(need)
    -- Small safety margin so one vendor visit covers E[crafts] for this band.
    need = need + 2
    -- Cap for bag/budget sanity (full band prior can be ~250 at a tier start).
    local hardCap = tonumber(SkillUp.APO_VIAL_BUY_CAP) or 300
    if need > hardCap then
        need = hardCap
    end
    if need < gap then
        need = gap
    end
    return need
end

function SkillUp.DumpRates(emit)
    emit = type(emit) == "function" and emit or function(msg)
        if StockPiler.Debug and StockPiler.Debug.Print then
            StockPiler.Debug.Print(msg)
        end
    end
    emit("--- skill-up rates (by skill level) ---")
    local rates = RatesTable()
    if type(rates) ~= "table" then
        emit("  (none)")
        return
    end
    local function dumpKind(kind, label)
        local root = rates[kind]
        if type(root) ~= "table" then
            emit("  " .. label .. ": (none)")
            return
        end
        local keys = {}
        for k in pairs(root) do
            keys[#keys + 1] = k
        end
        table.sort(keys, function(a, b)
            return (tonumber(a) or 0) < (tonumber(b) or 0)
        end)
        if #keys == 0 then
            emit("  " .. label .. ": (none)")
            return
        end
        for i = 1, #keys do
            local row = root[keys[i]]
            local att = tonumber(row and row.attempts) or 0
            local hits = tonumber(row and row.hits) or 0
            if att > 0 or hits > 0 then
                local pct = att > 0 and (hits / att * 100) or 0
                if kind == "apo" then
                    local lvl = tonumber(keys[i]) or 0
                    local floorTier = SkillUp.FloorApoTier(lvl)
                    local d = lvl - floorTier
                    emit(string.format(
                        "  %s level=%s d=%d hits=%d attempts=%d rate=%.0f%%",
                        label, tostring(keys[i]), d, hits, att, pct
                    ))
                else
                    emit(string.format(
                        "  %s level=%s hits=%d attempts=%d rate=%.0f%%",
                        label, tostring(keys[i]), hits, att, pct
                    ))
                end
            end
        end
    end
    dumpKind("cult", "Cult")
    dumpKind("apo", "Apo")

    -- Pool Apo by delta = skill - FloorApoTier (repeatable across tiers).
    emit("--- apo skill-up by tier delta (skill - floor) ---")
    local apoRoot = rates.apo
    local byDelta = {}
    if type(apoRoot) == "table" then
        for k, row in pairs(apoRoot) do
            local lvl = tonumber(k) or 0
            if lvl > 0 and type(row) == "table" then
                local att = tonumber(row.attempts) or 0
                local hits = tonumber(row.hits) or 0
                if att > 0 or hits > 0 then
                    local d = lvl - SkillUp.FloorApoTier(lvl)
                    local bucket = byDelta[d]
                    if type(bucket) ~= "table" then
                        bucket = { attempts = 0, hits = 0, levels = 0 }
                        byDelta[d] = bucket
                    end
                    bucket.attempts = bucket.attempts + att
                    bucket.hits = bucket.hits + hits
                    bucket.levels = bucket.levels + 1
                end
            end
        end
    end
    local dKeys = {}
    for d in pairs(byDelta) do
        dKeys[#dKeys + 1] = d
    end
    table.sort(dKeys, function(a, b)
        return (tonumber(a) or 0) < (tonumber(b) or 0)
    end)
    if #dKeys == 0 then
        emit("  (none)")
    else
        for i = 1, #dKeys do
            local d = dKeys[i]
            local b = byDelta[d]
            local att = tonumber(b.attempts) or 0
            local hits = tonumber(b.hits) or 0
            local pct = att > 0 and (hits / att * 100) or 0
            local eCrafts = (hits > 0 and att > 0) and (att / hits) or 0
            emit(string.format(
                "  d=%d levels=%d hits=%d attempts=%d rate=%.0f%% E[crafts/lvl]=%.2f",
                d, tonumber(b.levels) or 0, hits, att, pct, eCrafts
            ))
        end
    end

    -- Expected flasks for one full tier band using pooled f(d).
    local function rateAtDelta(d)
        local b = byDelta[d]
        if type(b) ~= "table" then
            return nil
        end
        local att = tonumber(b.attempts) or 0
        local hits = tonumber(b.hits) or 0
        if att <= 0 or hits <= 0 then
            return nil
        end
        return hits / att, att, hits
    end
    local function expectedCraftsAtDelta(d)
        local p = rateAtDelta(d)
        if p and p > 0 then
            return 1 / p, "obs"
        end
        -- Interpolate / carry across observed deltas.
        local below, above = nil, nil
        for i = 1, #dKeys do
            local od = dKeys[i]
            if od < d then
                below = od
            elseif od > d and above == nil then
                above = od
            end
        end
        if below and above then
            local pb = rateAtDelta(below)
            local pa = rateAtDelta(above)
            if pb and pa and pb > 0 and pa > 0 then
                local t = (d - below) / math.max(1, above - below)
                local p = pb + t * (pa - pb)
                if p > 0 then
                    return 1 / p, "interp"
                end
            end
        end
        if below then
            local pb = rateAtDelta(below)
            if pb and pb > 0 then
                return 1 / pb, "carry"
            end
        end
        if above then
            local pa = rateAtDelta(above)
            if pa and pa > 0 then
                return 1 / pa, "carry"
            end
        end
        return SkillUp.DefaultCraftsPerLevel("apo", SkillUp.FloorApoTier(SkillUp.GetApoSkill()) + d), "default"
    end
    local function flasksForBand(floorTier, nextTier)
        local total = 0
        for s = floorTier, nextTier - 1 do
            local d = s - floorTier
            local e = expectedCraftsAtDelta(d)
            total = total + e
        end
        return total
    end
    emit("--- apo flask estimate (delta model, 1 flask/craft) ---")
    if #dKeys == 0 then
        emit("  (no apo samples yet)")
    else
        local bands = {
            { 1, 25 }, { 25, 50 }, { 50, 75 }, { 75, 100 },
            { 100, 125 }, { 125, 150 }, { 150, 175 }, { 175, 200 },
        }
        local full = 0
        for i = 1, #bands do
            local f, n = bands[i][1], bands[i][2]
            local need = flasksForBand(f, n)
            full = full + need
            emit(string.format("  tier %d->%d E[flasks]=%.0f", f, n, need))
        end
        emit(string.format("  full 1->200 E[flasks]=%.0f", full))
        local apo = SkillUp.GetApoSkill()
        local floorTier = SkillUp.FloorApoTier(apo)
        local nextTier = SkillUp.NextApoTier(apo)
        local rem = 0
        for s = math.floor(apo), nextTier - 1 do
            rem = rem + expectedCraftsAtDelta(s - floorTier)
        end
        emit(string.format(
            "  remaining this tier apo=%d->%d E[flasks]=%.0f (have=%d)",
            apo,
            nextTier,
            rem,
            SkillUp.CountApoContainers and SkillUp.CountApoContainers() or 0
        ))
    end

    local apo = SkillUp.GetApoSkill()
    local rate, hits, att, srcLevel, how = SkillUp.ResolveLevelRate("apo", apo, { noNearby = true })
    local want = SkillUp.ApoContainerBuyTarget()
    local nextTier = SkillUp.NextApoTier(apo)
    local defCrafts = SkillUp.DefaultCraftsPerLevel("apo", apo)
    local tierNeed = ExpectedCraftsForRange("apo", apo, nextTier)
    emit(string.format(
        "  vial buy target (ResolveLevelRate): apo=%d->%d E[crafts]=%.0f rate@%s=%.0f%% (%s n=%d) default@lvl=%.1f want=%d",
        apo,
        nextTier,
        tierNeed,
        tostring(srcLevel or apo),
        (rate or 0) * 100,
        tostring(how or "?"),
        att or 0,
        defCrafts,
        want
    ))
end

--- Full SkillUp diagnostic dump (/stp skillplan).
function SkillUp.DumpSkillPlan(emit)
    emit = type(emit) == "function" and emit or function(msg)
        if StockPiler.Debug and StockPiler.Debug.Print then
            StockPiler.Debug.Print(msg)
        end
    end
    local function yn(v)
        return v == true and "yes" or "no"
    end
    local function narrow(v)
        if v == nil then
            return ""
        end
        if type(v) == "wstring" then
            return tostring(WStringToString and WStringToString(v) or v)
        end
        return tostring(v)
    end

    emit("=== StockPiler skillplan ===")

    local Watch = StockPiler.Watch
    local Caps = StockPiler.TradeSkillCaps
    local cult = SkillUp.GetCultSkill()
    local apo = SkillUp.GetApoSkill()
    emit(string.format(
        "  skills cult=%d (floor=%d targetMax=%d) apo=%d (floor=%d next=%d)",
        cult,
        SkillUp.FloorCultTier(cult),
        SkillUp.TargetMaxSkill(),
        apo,
        SkillUp.FloorApoTier(apo),
        SkillUp.NextApoTier(apo)
    ))
    emit(string.format(
        "  toggles cultOn=%s apoOn=%s cultVis=%s apoVis=%s watchesDone=%s allowIdle=%s blocked=%s showStatus=%s",
        yn(SkillUp.IsCultEnabled()),
        yn(SkillUp.IsApoEnabled()),
        yn(SkillUp.IsCultVisible()),
        yn(SkillUp.IsApoVisible()),
        yn(SkillUp.WatchesDone()),
        yn(SkillUp.WatchesAllowIdleSkillUp()),
        yn(SkillUp.AllShortWatchesProgressBlocked()),
        yn(SkillUp.ShouldShowWatchStatus and SkillUp.ShouldShowWatchStatus())
    ))
    emit(string.format(
        "  gates shouldCultGrow=%s shouldCultPlant=%s shouldApoBrew=%s canAutoGrow=%s autoGrowMaster=%s autoBuy=%s",
        yn(SkillUp.ShouldCultGrowForSkillUp()),
        yn(SkillUp.ShouldCultPlant()),
        yn(SkillUp.ShouldApoBrew()),
        yn(Caps and Caps.CanAutoGrow and Caps.CanAutoGrow()),
        yn(Watch and Watch.IsAutoGrowEnabled and Watch.IsAutoGrowEnabled()),
        yn(Watch and Watch.IsAutoBuyEnabled and Watch.IsAutoBuyEnabled())
    ))
    emit(string.format(
        "  latches cult=%s apo=%s pendingCult=%s pendingApo=%s",
        tostring(SkillUp._stallLatch or "-"),
        tostring(SkillUp._apoStallLatch or "-"),
        SkillUp._pendingCult and string.format("lvl=%s until=%.0f",
            tostring(SkillUp._pendingCult.level),
            tonumber(SkillUp._pendingCult.untilTime) or 0) or "-",
        SkillUp._pendingApo and string.format("lvl=%s until=%.0f",
            tostring(SkillUp._pendingApo.level),
            tonumber(SkillUp._pendingApo.untilTime) or 0) or "-"
    ))

    -- Garden plots
    emit("--- garden ---")
    local empty = SkillUp.CountEmptyPlots()
    emit(string.format("  emptyPlots=%d", empty))
    local Garden = StockPiler.Garden
    local plots = Garden and Garden.GetPlots and Garden.GetPlots() or nil
    if type(plots) == "table" then
        for plotNum, row in pairs(plots) do
            if type(row) == "table" then
                local stage = tonumber(row.stage) or 0
                local seedUid = tonumber(row.seedUid) or 0
                local plantUid = tonumber(row.plantUid) or 0
                emit(string.format(
                    "  plot[%s] stage=%s seedUid=%d plantUid=%d empty=%s",
                    tostring(plotNum),
                    tostring(stage),
                    seedUid,
                    plantUid,
                    tostring(stage == 0 or stage == 255)
                ))
            end
        end
    else
        emit("  plots=(unavailable)")
    end
    local Grow = StockPiler.Grow
    if Grow and type(Grow._pendingPlant) == "table" then
        for plotNum, flag in pairs(Grow._pendingPlant) do
            if (tonumber(flag) or 0) > 0 then
                local su = Grow._pendingSeedUid and Grow._pendingSeedUid[plotNum] or 0
                emit(string.format("  pendingPlant plot=%s seedUid=%s", tostring(plotNum), tostring(su)))
            end
        end
    end

    -- Cult plant / refine
    emit("--- cult plant/refine ---")
    local pick = SkillUp.PickBestBagSeed and SkillUp.PickBestBagSeed() or nil
    if type(pick) == "table" then
        local seedUid = tonumber(pick.seedUid) or 0
        local budget = SeedBudget(seedUid)
        emit(string.format(
            "  pick seedUid=%d plantUid=%d req=%d bag=%d name=%s",
            seedUid,
            tonumber(pick.plantUid) or 0,
            tonumber(pick.skillReq) or 0,
            tonumber(pick.count) or 0,
            narrow(pick.item and pick.item.name)
        ))
        emit(string.format(
            "  budget live=%s ground=%s outstanding=%s credit=%s buffer=%s headroom=%s",
            tostring(budget.live),
            tostring(budget.ground),
            tostring(budget.outstanding),
            tostring(budget.credit),
            tostring(budget.bufferMin),
            tostring(budget.headroom)
        ))
        emit(string.format(
            "  seedDeficit=%d hasUpgrade=%s hasRefinable=%s",
            tonumber(SkillUp.SeedDeficit and SkillUp.SeedDeficit(seedUid)) or 0,
            yn(SkillUp.HasUpgradePlant and SkillUp.HasUpgradePlant()),
            yn(SkillUp.HasRefinablePlants and SkillUp.HasRefinablePlants())
        ))
    else
        emit("  pick=(none)")
    end
    local job = SkillUp.PickPlantJob and SkillUp.PickPlantJob() or nil
    if type(job) == "table" then
        emit(string.format(
            "  plantJob seedUid=%d plantable=%d reason=%s req=%d",
            tonumber(job.seedUid) or 0,
            tonumber(job.plantable) or 0,
            tostring(job.plantReason or job.pickMode or "?"),
            tonumber(job.skillReq) or 0
        ))
    else
        emit("  plantJob=(nil) - see hold/no-plant logs; empty=" .. tostring(empty))
    end
    local refine = SkillUp.ScanBestRefinePlant and SkillUp.ScanBestRefinePlant() or nil
    if type(refine) == "table" then
        emit(string.format(
            "  refineBest plantUid=%d seedUid=%d req=%d count=%s upgrade=%s",
            tonumber(refine.plantUid) or 0,
            tonumber(refine.seedUid) or 0,
            tonumber(refine.skillReq) or 0,
            tostring(refine.count or refine.uses or "?"),
            yn(refine.upgrade == true or SkillUp.HasUpgradePlant())
        ))
    else
        emit("  refineBest=(none)")
    end
    local buySeed = SkillUp.ShouldCultBuy and SkillUp.ShouldCultBuy() == true
    emit(string.format("  shouldCultBuy=%s", yn(buySeed)))
    if SkillUp.CollectBuyJobs then
        local seedJobs = SkillUp.CollectBuyJobs() or {}
        emit(string.format("  cultBuyJobs=%d", #seedJobs))
        for i = 1, #seedJobs do
            local j = seedJobs[i]
            emit(string.format(
                "    buy[%d] uid=%s deficit=%s role=%s skillUp=%s",
                i,
                tostring(j.uid or j.uniqueID),
                tostring(j.deficit),
                tostring(j.role),
                yn(j.skillUp == true)
            ))
        end
    end

    -- Apo brew / vials
    emit("--- apo brew/vials ---")
    emit(string.format(
        "  apoTier=%d vials have=%d want=%d shouldBuy=%s",
        SkillUp.ApoTargetTier(),
        SkillUp.CountApoContainers and SkillUp.CountApoContainers() or 0,
        SkillUp.ApoContainerBuyTarget and SkillUp.ApoContainerBuyTarget() or 0,
        yn(SkillUp.ShouldApoBuyContainer and SkillUp.ShouldApoBuyContainer())
    ))
    local vialTarget = SkillUp.ResolveBuyContainerTarget and SkillUp.ResolveBuyContainerTarget() or nil
    if type(vialTarget) == "table" then
        emit(string.format(
            "  vialTarget uid=%d skillReq=%d",
            tonumber(vialTarget.uid) or 0,
            tonumber(vialTarget.skillReq) or 0
        ))
    end
    if SkillUp.CollectContainerBuyJobs then
        local cJobs = SkillUp.CollectContainerBuyJobs() or {}
        emit(string.format("  containerBuyJobs=%d", #cJobs))
        for i = 1, #cJobs do
            local j = cJobs[i]
            emit(string.format(
                "    vialBuy[%d] uid=%s deficit=%s skillReq=%s",
                i,
                tostring(j.uid or j.uniqueID),
                tostring(j.deficit),
                tostring(j.skillReq)
            ))
        end
    end
    for _, role in ipairs({ "main", "container", "stabilizer" }) do
        local mats = SkillUp.ListApoBagMaterials and SkillUp.ListApoBagMaterials(role) or {}
        emit(string.format("  mats[%s] candidates=%d", role, type(mats) == "table" and #mats or 0))
        if type(mats) == "table" then
            local lim = math.min(#mats, 5)
            for i = 1, lim do
                local m = mats[i]
                emit(string.format(
                    "    [%d] uid=%d count=%s stab=%s req=%s surplus=%s name=%s",
                    i,
                    tonumber(m.uid) or 0,
                    tostring(m.count),
                    tostring(m.stability),
                    tostring(m.skillReq or m.skillLevel),
                    tostring(m.surplus),
                    narrow(m.item and m.item.name)
                ))
            end
        end
    end
    local brewRow = SkillUp.BuildApoBrewRow and SkillUp.BuildApoBrewRow({ quiet = true }) or nil
    if type(brewRow) == "table" then
        emit(string.format(
            "  brewRow craftable=%s mainUid=%s status=%s name=%s",
            tostring(brewRow.craftable),
            tostring(brewRow.mainUid),
            tostring(brewRow.statusKey),
            narrow(brewRow.name)
        ))
    else
        emit(string.format(
            "  brewRow=(nil) stall=%s",
            tostring(SkillUp._apoStallLatch or "-")
        ))
    end

    -- Watch status rows
    emit("--- watch status rows ---")
    local rows = SkillUp.BuildWatchStatusRows and SkillUp.BuildWatchStatusRows() or {}
    emit(string.format("  rows=%d", #rows))
    for i = 1, #rows do
        local r = rows[i]
        emit(string.format(
            "  row[%d] kind=%s name=%s status=%s stock=%s craftable=%s hideAg=%s hideBrew=%s",
            i,
            tostring(r.skillUpKind),
            narrow(r.name),
            tostring(r.statusKey),
            narrow(r.stockText),
            tostring(r.craftable),
            yn(r.hideAutoGrow == true),
            yn(r.hideBrew == true)
        ))
        if type(r.statusLines) == "table" then
            for li = 1, #r.statusLines do
                emit("    tip: " .. narrow(r.statusLines[li]))
            end
        end
    end

    -- Rates (reuse)
    SkillUp.DumpRates(emit)

    emit("=== end skillplan ===")
end

--- Wipe Cult/Apo per-level skill-up samples (and pending attribution).
function SkillUp.ClearRates()
    local Acc = StockPiler.Account
    if type(Acc) ~= "table" then
        return false
    end
    local wantV = SkillUp.SKILL_RATES_SCHEMA or 2
    Acc.skillUpRates = { v = wantV, cult = {}, apo = {} }
    SkillUp._pendingCult = nil
    SkillUp._pendingApo = nil
    if StockPiler.Debug and StockPiler.Debug.LogOp then
        StockPiler.Debug.LogOp("skillup", "rates cleared")
    end
    return true
end

--- craftSlot matches ApothecaryWindow: 0 container, 1 main, 2 ingredient.
local function WindowAcceptsApoItem(item, role)
    local AA = StockPiler.ApothecaryAdapter
    if not (AA and AA.ItemIsAllowedInSlot) then
        return true
    end
    local slot = 2
    if role == "container" then
        slot = 0
    elseif role == "main" then
        slot = 1
    end
    return AA.ItemIsAllowedInSlot(item, slot) == true
end

--- Count usable Apo-tier (or below) containers currently in bags.
--- Memoized per inventory snap and Apo tier. TargetMaxSkill and the watch
--- row call this on every seed pick and paint.
function SkillUp.CountApoContainers()
    local targetTier = SkillUp.ApoTargetTier()
    if targetTier < 1 then
        targetTier = 1
    end
    local Inv = StockPiler.Inventory
    local snap = Inv and Inv.GetSnapGen and tonumber(Inv.GetSnapGen()) or 0
    if SkillUp._apoContainerCount ~= nil
        and SkillUp._apoContainerSnap == snap
        and SkillUp._apoContainerTier == targetTier
    then
        return SkillUp._apoContainerCount
    end
    local MS = StockPiler.MaterialSpec
    local SM = StockPiler.SeedMap
    if not (Inv and Inv.ForEachItem and MS and MS.FromItemData) then
        return 0
    end
    local total = 0
    local seen = {}
    Inv.ForEachItem(function(item)
        if type(item) ~= "table" then
            return
        end
        local uid = tonumber(item.uniqueID) or 0
        if uid <= 0 or seen[uid] == true then
            return
        end
        seen[uid] = true
        local spec = MS.FromItemData(item, nil)
        if type(spec) ~= "table" or tostring(spec.role or "") ~= "container" then
            return
        end
        if WindowAcceptsApoItem(item, "container") ~= true then
            return
        end
        if SM and SM.ItemLooksLikeRefinablePlant and SM.ItemLooksLikeRefinablePlant(item) == true then
            return
        end
        local req = tonumber(spec.skillLevel) or SeedSkillReq(item)
        if req > targetTier then
            return
        end
        local count = Inv.CountByUid and tonumber(Inv.CountByUid(uid)) or 0
        if count <= 0 then
            count = tonumber(item.stackCount) or tonumber(item.StackCount) or 1
        end
        total = total + count
    end)
    SkillUp._apoContainerSnap = snap
    SkillUp._apoContainerTier = targetTier
    SkillUp._apoContainerCount = total
    return total
end

--- AutoBuy can restock vials, and the last vendor visit did not lack them.
--- TargetMaxSkill uses this so Cultivation stays on Apo's tier while a vial
--- is still buyable. Do not call ShouldApoBuyContainer: it needs an exact-tier
--- main and loops back through ShouldApoBrew.
function SkillUp.SetNoVendorContainer(noContainer)
    if noContainer == true then
        SkillUp._apoNoVendorContainer = true
    else
        SkillUp._apoNoVendorContainer = nil
    end
end

function SkillUp.ApoVialObtainable()
    local Watch = StockPiler.Watch
    if not (Watch and Watch.IsAutoBuyEnabled and Watch.IsAutoBuyEnabled() == true) then
        return false
    end
    return SkillUp._apoNoVendorContainer ~= true
end

function SkillUp.ShouldApoBuyContainer()
    if SkillUp.ShouldApoBrew() ~= true then
        return false
    end
    local Watch = StockPiler.Watch
    if not (Watch and Watch.IsAutoBuyEnabled and Watch.IsAutoBuyEnabled() == true) then
        return false
    end
    -- Buy vials when an exact-tier main exists (even if held for seed buffer).
    if SkillUp.PickApoBagMaterial("main", { ignoreReserve = true }) == nil then
        return false
    end
    local want = SkillUp.ApoContainerBuyTarget()
    if want < 1 then
        return false
    end
    local have = SkillUp.CountApoContainers()
    return have < want
end

local function SpecStability(spec)
    if type(spec) ~= "table" then
        return 0
    end
    local stab = tonumber(spec.stability)
    if stab ~= nil then
        return stab
    end
    local B = GameData and GameData.CraftingItemBonus
    if type(spec.bonuses) == "table" and B and B.STABILITY ~= nil then
        return tonumber(spec.bonuses[B.STABILITY]) or 0
    end
    return 0
end

--- Absolute plant/seed/mat need from all short enabled potion/plant watches
--- (AG on or off). Used so SkillUp never drains mats still claimed by watches.
--- Accepts a numeric uid, or a spec/item table with uid/uniqueID.
function SkillUp.WatchDemandReserve(specOrUid)
    local wantUid = 0
    if type(specOrUid) == "table" then
        wantUid = tonumber(specOrUid.uid) or tonumber(specOrUid.uniqueID)
            or tonumber(specOrUid.boundUid) or 0
    else
        wantUid = tonumber(specOrUid) or 0
    end
    if wantUid <= 0 then
        return 0
    end

    local Watch = StockPiler.Watch
    local Inv = StockPiler.Inventory
    local RS = StockPiler.RecipeSpec
    local snap = Inv and Inv.GetSnapGen and tonumber(Inv.GetSnapGen()) or 0
    local watchGen = Watch and Watch.GetGen and tonumber(Watch.GetGen()) or 0
    -- Yield and per-craft counts follow the recipe stats generation. That
    -- bump does not move the bag snap or the watch generation (FullCacheKey).
    local statsGen = RS and RS.GetRecipeStatsGen and tonumber(RS.GetRecipeStatsGen()) or 0
    local cache = SkillUp._watchReserveCache
    if type(cache) ~= "table" or cache.snap ~= snap or cache.watchGen ~= watchGen
        or cache.statsGen ~= statsGen
    then
        cache = { snap = snap, watchGen = watchGen, statsGen = statsGen, byUid = {} }
        SkillUp._watchReserveCache = cache
    end
    local cached = cache.byUid[wantUid]
    if cached ~= nil then
        return cached
    end

    local need = 0
    local SM = StockPiler.SeedMap

    local watches = Watch and Watch.GetWatches and Watch.GetWatches() or {}
    if type(watches) == "table" and RS then
        for key, watch in pairs(watches) do
            if type(watch) == "table" and watch.enabled == true then
                local target = tonumber(watch.targetStock) or 0
                local have = PotionWatchHave(key, watch)
                local deficit = math.max(0, target - have)
                if deficit > 0 and target > 0 then
                    local recipe = RS.RecipeSpecForPotion and RS.RecipeSpecForPotion(key) or nil
                    if type(recipe) == "table" then
                        if RS.HydrateRecipeSlots then
                            RS.HydrateRecipeSlots(recipe)
                        end
                        local yield = math.max(1, tonumber(recipe.recipeYield) or 1)
                        local craftsNeeded = math.ceil(deficit / yield)
                        if RS.CraftsNeededForDeficit then
                            craftsNeeded = tonumber(RS.CraftsNeededForDeficit(deficit, recipe)) or craftsNeeded
                        end
                        local slots = recipe.slots or {}
                        for i = 1, #slots do
                            local slot = slots[i]
                            local spec = nil
                            if RS.ResolveSlotSpec then
                                spec = RS.ResolveSlotSpec(slot)
                            end
                            if type(spec) ~= "table" and type(slot) == "table" then
                                spec = slot.spec
                            end
                            local uid = 0
                            if type(spec) == "table" then
                                uid = tonumber(spec.uid) or tonumber(spec.uniqueID) or tonumber(spec.boundUid) or 0
                            end
                            if uid <= 0 and type(slot) == "table" then
                                uid = tonumber(slot.uid) or tonumber(slot.uniqueID) or 0
                            end
                            if uid == wantUid then
                                local perCraft = 1
                                if RS.EffectiveSpecPerCraft then
                                    perCraft = math.max(1, tonumber(RS.EffectiveSpecPerCraft(slot, slots)) or 1)
                                else
                                    perCraft = math.max(1, tonumber(slot and slot.perCraft) or 1)
                                end
                                need = need + craftsNeeded * perCraft
                            end
                        end
                    end
                end
            end
        end
    end

    local plantWatches = Watch and Watch.GetPlantWatches and Watch.GetPlantWatches() or {}
    if type(plantWatches) == "table" then
        for plantKey, watch in pairs(plantWatches) do
            if type(watch) == "table" and watch.enabled == true then
                local target = tonumber(watch.targetStock) or 0
                local plantUid = Watch.ParsePlantKey and tonumber(Watch.ParsePlantKey(plantKey)) or 0
                local have = 0
                if plantUid > 0 and Inv and Inv.CountByUid then
                    have = tonumber(Inv.CountByUid(plantUid)) or 0
                end
                local deficit = math.max(0, target - have)
                if deficit > 0 then
                    if plantUid == wantUid then
                        need = need + deficit
                    elseif SM and SM.ResolveSeedUidForPlant then
                        local seedUid = tonumber(SM.ResolveSeedUidForPlant(plantUid, nil)) or 0
                        if seedUid == wantUid then
                            need = need + deficit
                        end
                    end
                end
            end
        end
    end

    cache.byUid[wantUid] = need
    return need
end

--- Plants to hold before Apo SkillUp may brew - same rule as watch GrowReserve:
--- this seed's buffer headroom only (plus short-watch demand). When THIS seed's
--- buffer is full (headroom=0), plants are brewable surplus.
--- Max headroom across: resolved same-tier seed and the genus-ladder seed at the
--- plant's skillReq. Do not max over every grow/refine-linked leftover.
--- Refine.IsSeedBufferSatisfied is watched AutoGrow lines only. It is true when
--- there are no watches, which previously zeroed this reserve and let brew eat
--- the SkillUp harvest before the seed buffer was filled.
function SkillUp.PlantFeedstockReserve(seedUid, plantUid)
    seedUid = tonumber(seedUid) or 0
    plantUid = tonumber(plantUid) or 0
    local reserve = 0
    local plantReq = 0
    local function skillReqOfUid(uid)
        uid = tonumber(uid) or 0
        if uid <= 0 then
            return 0
        end
        local Inv = StockPiler.Inventory
        local sample = Inv and Inv.GetSample and Inv.GetSample(uid)
        local req = SeedSkillReq(sample)
        if req <= 0 and StockPiler.Items and StockPiler.Items.GetByUid then
            local row = StockPiler.Items.GetByUid(uid)
            if type(row) == "table" then
                req = SeedSkillReq(row)
            end
        end
        return req
    end
    local function seedSkillReq(uid)
        return skillReqOfUid(uid)
    end
    if plantUid > 0 then
        local SM = StockPiler.SeedMap
        if StockPiler.Items and StockPiler.Items.ToSpec then
            local spec = StockPiler.Items.ToSpec(plantUid)
            plantReq = tonumber(spec and spec.skillLevel) or 0
        end
        if plantReq <= 0 then
            plantReq = skillReqOfUid(plantUid)
        end
    end
    local function bumpFromSeed(uid, requireSameTier)
        uid = tonumber(uid) or 0
        if uid <= 0 then
            return
        end
        if requireSameTier and plantReq > 0 then
            local sReq = seedSkillReq(uid)
            if sReq > 0 and sReq ~= plantReq then
                return
            end
            if sReq <= 0 then
                return
            end
        end
        local budget = SeedBudget(uid)
        local headroom = tonumber(budget.headroom) or 0
        if headroom > reserve then
            reserve = headroom
        end
    end
    -- Resolved seed: count when same-tier or skill unknown; skip known-lower.
    if seedUid > 0 then
        local sReq = seedSkillReq(seedUid)
        if plantReq <= 0 or sReq <= 0 or sReq == plantReq then
            local budget = SeedBudget(seedUid)
            local headroom = tonumber(budget.headroom) or 0
            if headroom > reserve then
                reserve = headroom
            end
        end
    end
    if plantUid > 0 then
        local SM = StockPiler.SeedMap
        if plantReq > 0 and SM and SM.GetGenusLadderForSpec then
            local ladder = SM.GetGenusLadderForSpec({
                uid = plantUid,
                uniqueID = plantUid,
                skillLevel = plantReq,
            })
            if type(ladder) == "table" and type(ladder.rungs) == "table" then
                for i = 1, #ladder.rungs do
                    local rung = ladder.rungs[i]
                    if (tonumber(rung.skillReq) or 0) == plantReq then
                        bumpFromSeed(rung.seedUid, true)
                        break
                    end
                end
            end
        end
    end
    local watchNeed = 0
    if plantUid > 0 then
        watchNeed = SkillUp.WatchDemandReserve(plantUid)
    end
    if seedUid > 0 then
        local seedNeed = SkillUp.WatchDemandReserve(seedUid)
        if seedNeed > watchNeed then
            watchNeed = seedNeed
        end
    end
    if watchNeed > reserve then
        return watchNeed
    end
    return reserve
end

--- How many of this plant stack are safe for SkillUp Apo brew (and resin convert).
--- plantCount - PlantFeedstockReserve. Unresolved cultivation seed -> 0.
--- A non-growable main (butchered ingredient) has no seed; surplus is the
--- stack minus any watch claim. SkillUp refine-into-buffer uses
--- PlantRefineSurplus instead (buffer headroom is a refine target there).
function SkillUp.PlantBrewSurplus(plantUid, seedUid, plantCount, spec)
    plantUid = tonumber(plantUid) or 0
    seedUid = tonumber(seedUid) or 0
    plantCount = tonumber(plantCount) or 0
    if plantCount <= 0 then
        return 0
    end
    if seedUid <= 0 and plantUid > 0 then
        local SM = StockPiler.SeedMap
        if SM and SM.ResolveSeedUidForPlant then
            seedUid = tonumber(SM.ResolveSeedUidForPlant(plantUid, spec)) or 0
        end
        if seedUid <= 0 and SM and SM.GetSeedUidsForPlant then
            local seeds = SM.GetSeedUidsForPlant(plantUid) or {}
            if type(seeds) == "table" and #seeds > 0 then
                seedUid = tonumber(seeds[1]) or 0
            end
        end
    end
    if seedUid <= 0 then
        local SM = StockPiler.SeedMap
        if type(spec) ~= "table" and plantUid > 0 then
            local MS = StockPiler.MaterialSpec
            if MS and MS.FromUid then
                spec = MS.FromUid(plantUid)
            end
        end
        -- Butchered / vendor mains are not seed-buffer feedstock.
        if type(spec) == "table" and tostring(spec.role or "") == "main"
            and (not SM or not SM.IsGrowableSpec or SM.IsGrowableSpec(spec) ~= true)
        then
            local watchNeed = SkillUp.WatchDemandReserve(plantUid)
            local surplus = plantCount - watchNeed
            if surplus < 0 then
                return 0
            end
            return surplus
        end
        return 0
    end
    local reserve = SkillUp.PlantFeedstockReserve(seedUid, plantUid)
    local surplus = plantCount - reserve
    if surplus < 0 then
        return 0
    end
    return surplus
end

--- Plants free for SkillUp refine into seeds. Buffer headroom is a refine *target*
--- (how many seeds we still need), not a plant reserve - only short-watch demand
--- holds plants back. Using PlantBrewSurplus here caused deadlocks: upgrade/buffer
--- refine needed the reserved plants to *create* the buffer.
function SkillUp.PlantRefineSurplus(plantUid, seedUid, plantCount)
    plantUid = tonumber(plantUid) or 0
    seedUid = tonumber(seedUid) or 0
    plantCount = tonumber(plantCount) or 0
    if plantCount <= 0 then
        return 0
    end
    if seedUid <= 0 and plantUid > 0 then
        local SM = StockPiler.SeedMap
        if SM and SM.ResolveSeedUidForPlant then
            seedUid = tonumber(SM.ResolveSeedUidForPlant(plantUid, nil)) or 0
        end
        if seedUid <= 0 and SM and SM.GetSeedUidsForPlant then
            local seeds = SM.GetSeedUidsForPlant(plantUid) or {}
            if type(seeds) == "table" and #seeds > 0 then
                seedUid = tonumber(seeds[1]) or 0
            end
        end
    end
    if seedUid <= 0 then
        return 0
    end
    local watchNeed = 0
    if plantUid > 0 then
        watchNeed = SkillUp.WatchDemandReserve(plantUid)
    end
    local seedNeed = SkillUp.WatchDemandReserve(seedUid)
    if seedNeed > watchNeed then
        watchNeed = seedNeed
    end
    local surplus = plantCount - watchNeed
    if surplus < 0 then
        return 0
    end
    return surplus
end

local function ResolveSeedUidForPlantItem(item, plantUid)
    plantUid = tonumber(plantUid) or 0
    local SM = StockPiler.SeedMap
    if SM and SM.ResolveSeedUidForPlant and plantUid > 0 then
        local plantSpec = nil
        if type(item) == "table" then
            local MS = StockPiler.MaterialSpec
            if MS and MS.FromItemData then
                plantSpec = MS.FromItemData(item, nil)
            end
        end
        local uid = tonumber(SM.ResolveSeedUidForPlant(plantUid, plantSpec)) or 0
        if uid > 0 then
            return uid
        end
    end
    if SM and SM.GetSeedUidsForPlant and plantUid > 0 then
        local seeds = SM.GetSeedUidsForPlant(plantUid) or {}
        if type(seeds) == "table" and #seeds > 0 then
            return tonumber(SM.PickBestSeedUid and SM.PickBestSeedUid(plantUid, seeds) or seeds[1]) or 0
        end
    end
    local entry = StockPiler.Account and StockPiler.Account.refines
        and StockPiler.Account.refines[tostring(plantUid)]
    if type(entry) == "table" then
        return tonumber(entry.seedUid) or 0
    end
    return 0
end

--- True when spec is Arboreal Resin / harvest byproduct stabilizer.
local function IsApoResinSpec(spec, item)
    local SM = StockPiler.SeedMap
    if SM and SM.IsHarvestByproduct and type(spec) == "table" and SM.IsHarvestByproduct(spec) == true then
        return true
    end
    local n = ""
    local src = item or spec
    if type(src) == "table" and src.name ~= nil then
        if type(src.name) == "wstring" and type(WStringToString) == "function" then
            n = string.lower(WStringToString(src.name) or "")
        else
            n = string.lower(tostring(src.name or ""))
        end
    end
    if n == "" and type(spec) == "table" and spec.name ~= nil then
        if type(spec.name) == "wstring" and type(WStringToString) == "function" then
            n = string.lower(WStringToString(spec.name) or "")
        else
            n = string.lower(tostring(spec.name or ""))
        end
    end
    return string.find(n, "resin", 1, true) ~= nil or string.find(n, "arboreal", 1, true) ~= nil
end

local function IsValidApoContainer(item, spec)
    if type(spec) ~= "table" or tostring(spec.role or "") ~= "container" then
        return false
    end
    if WindowAcceptsApoItem(item, "container") ~= true then
        return false
    end
    local SM = StockPiler.SeedMap
    local MS = StockPiler.MaterialSpec
    if SM and SM.ItemLooksLikeRefinablePlant and SM.ItemLooksLikeRefinablePlant(item) == true then
        return false
    end
    if (tonumber(spec.cultivationType) or 0) ~= 0 then
        return false
    end
    if MS and MS.IsCultivationAdditive and MS.IsCultivationAdditive(item) == true then
        return false
    end
    return true
end

--- Units of resin stab needed so main+container+resin > 0 (engine HIGH).
local function ResinStabNeeded(mainStab, containerStab)
    local base = (tonumber(mainStab) or 0) + (tonumber(containerStab) or 0)
    if base > 0 then
        return 0
    end
    -- Need total > 0 => add at least (1 - base).
    return 1 - base
end

--- List bag candidates for Apo SkillUp role.
--- Main: exact FloorApoTier only (cultivation plant or butchered main).
--- Container: skillReq <= floor. Stabilizer: resin or butchered stabilizer.
function SkillUp.ListApoBagMaterials(role, opts)
    role = tostring(role or "")
    opts = type(opts) == "table" and opts or {}
    local ignoreReserve = opts.ignoreReserve == true
    local exactTier = opts.exactTier ~= false
    local targetTier = SkillUp.ApoTargetTier()
    if targetTier < 1 then
        targetTier = 1
    end
    local Inv = StockPiler.Inventory
    local MS = StockPiler.MaterialSpec
    local SM = StockPiler.SeedMap
    local list = {}
    if not (Inv and Inv.ForEachItem and MS and MS.FromItemData) then
        return list
    end
    local seen = {}
    Inv.ForEachItem(function(item)
        if type(item) ~= "table" then
            return
        end
        local uid = tonumber(item.uniqueID) or 0
        if uid <= 0 or seen[uid] == true then
            return
        end
        seen[uid] = true
        if SM and SM.IsBagSeedOrSpore and SM.IsBagSeedOrSpore(item) then
            return
        end
        if not CanUseCraftingSample(item) then
            return
        end
        local spec = MS.FromItemData(item, nil)
        if type(spec) ~= "table" then
            return
        end
        local specRole = tostring(spec.role or "")
        local isResin = false
        if role == "stabilizer" then
            isResin = IsApoResinSpec(spec, item) == true
        end
        if role == "stabilizer" then
            if isResin then
                -- Arboreal Resin stays the cultivator stabilizer.
            elseif specRole == "stabilizer"
                and not (SM and SM.IsGrowableSpec and SM.IsGrowableSpec(spec) == true)
                and not (MS and MS.IsCultivationAdditive and MS.IsCultivationAdditive(item) == true)
            then
                -- Butchered / vendor stabilizer. Competes with resin on the same rules.
            else
                return
            end
        elseif specRole ~= role then
            return
        end
        if role == "container" and not IsValidApoContainer(item, spec) then
            return
        end
        if WindowAcceptsApoItem(item, role) ~= true then
            return
        end
        if role == "main" and LooksNonMainSeed(item, spec) then
            return
        end
        local count = Inv.CountByUid and tonumber(Inv.CountByUid(uid)) or 0
        if count <= 0 then
            count = tonumber(item.stackCount) or tonumber(item.StackCount) or 1
        end
        if count <= 0 then
            return
        end
        local brewable = count
        local seedUid = 0
        if role == "main" then
            seedUid = ResolveSeedUidForPlantItem(item, uid)
            if not ignoreReserve then
                brewable = SkillUp.PlantBrewSurplus(uid, seedUid, count, spec)
                if brewable < 1 then
                    return
                end
            end
        elseif role == "stabilizer" and isResin ~= true and not ignoreReserve then
            -- Butchered and vendor stabilizers compete with resin. A short
            -- watch still owns its share; resin stays unreserved (no seed).
            brewable = count - (tonumber(SkillUp.WatchDemandReserve(uid)) or 0)
            if brewable < 1 then
                return
            end
        end
        local req = tonumber(spec.skillLevel) or SeedSkillReq(item)
        local stab = SpecStability(spec)
        if stab == 0 and type(spec.bonuses) == "table" then
            local B = GameData and GameData.CraftingItemBonus
            if B and B.STABILITY ~= nil then
                stab = tonumber(spec.bonuses[B.STABILITY]) or 0
            end
        end
        if role == "main" then
            -- Exact Apo floor only - no lower-tier brew after tier-up.
            if exactTier then
                if req ~= targetTier then
                    return
                end
            elseif req > targetTier then
                return
            end
        elseif role == "container" then
            if req > targetTier then
                return
            end
        elseif role == "stabilizer" then
            if stab <= 0 then
                return
            end
            if req > targetTier then
                return
            end
        end
        list[#list + 1] = {
            uid = uid,
            uniqueID = uid,
            skillReq = req,
            count = brewable,
            bagCount = count,
            seedUid = seedUid,
            stability = stab,
            item = item,
            spec = spec,
            role = role == "stabilizer" and "stabilizer" or role,
            resin = isResin == true,
        }
    end)
    return list
end

--- Best bag item for role (see ListApoBagMaterials filters).
--- Never force role via MaterialSpec roleHint (that mislabeled plants as containers).
function SkillUp.PickApoBagMaterial(role, opts)
    role = tostring(role or "")
    opts = type(opts) == "table" and opts or {}
    local list = SkillUp.ListApoBagMaterials(role, opts)
    if #list == 0 then
        return nil
    end
    local targetTier = SkillUp.ApoTargetTier()
    if targetTier < 1 then
        targetTier = 1
    end
    local best = nil
    local bestScore = -1
    for i = 1, #list do
        local cand = list[i]
        local score = 0
        if role == "stabilizer" then
            local tierDist = math.abs((tonumber(cand.skillReq) or 0) - targetTier)
            score = (1000 - tierDist) * 100000
                - (tonumber(cand.stability) or 0) * 1000
                + (tonumber(cand.count) or 0)
        elseif role == "container" then
            score = (100 - (tonumber(cand.stability) or 0)) * 1000000
                + (1000 - math.abs((tonumber(cand.skillReq) or 0) - targetTier)) * 100
                + (tonumber(cand.count) or 0)
        else
            score = (tonumber(cand.count) or 0)
        end
        if score > bestScore then
            bestScore = score
            best = cand
        end
    end
    return best
end

--- Build a stable inventable recipe from bag surplus (container + main + stabilizer).
--- Every exact-floor main is eligible (heal, regen, stat, plant, or butchered).
--- The largest usable surplus is brewed first. One brew still uses one main.
function SkillUp.BuildApoBrewRecipe()
    if SkillUp.ShouldApoBrew() ~= true then
        return nil
    end
    local mains = SkillUp.ListApoBagMaterials("main")
    if #mains == 0 then
        local heldList = SkillUp.ListApoBagMaterials("main", { ignoreReserve = true })
        local SM = StockPiler.SeedMap
        local anyHeld = false
        local anyGrowable = false
        if type(heldList) == "table" then
            for i = 1, #heldList do
                local held = heldList[i]
                if type(held) == "table" then
                    anyHeld = true
                    if SM and SM.IsGrowableSpec and type(held.spec) == "table"
                        and SM.IsGrowableSpec(held.spec) == true
                    then
                        anyGrowable = true
                        break
                    end
                end
            end
        end
        if anyGrowable then
            return nil, "seed_buffer"
        end
        if anyHeld then
            return nil, "need_mats"
        end
        local lower = SkillUp.ListApoBagMaterials("main", { exactTier = false, ignoreReserve = true })
        local targetTier = SkillUp.ApoTargetTier()
        for i = 1, #lower do
            local cand = lower[i]
            if (tonumber(cand.skillReq) or 0) < targetTier
                and SM and SM.IsGrowableSpec and type(cand.spec) == "table"
                and SM.IsGrowableSpec(cand.spec) == true
            then
                return nil, "wait_cult"
            end
        end
        return nil, "need_mats"
    end

    local containers = SkillUp.ListApoBagMaterials("container")
    local resins = SkillUp.ListApoBagMaterials("stabilizer")
    if #containers == 0 then
        return nil, "need_mats"
    end

    table.sort(containers, function(a, b)
        local sa, sb = tonumber(a.stability) or 0, tonumber(b.stability) or 0
        if sa ~= sb then
            return sa < sb
        end
        local ta, tb = tonumber(a.skillReq) or 0, tonumber(b.skillReq) or 0
        if ta ~= tb then
            return ta > tb
        end
        return (tonumber(a.count) or 0) > (tonumber(b.count) or 0)
    end)
    -- Prefer lowest-tier stabilizer that can still stabilize.
    table.sort(resins, function(a, b)
        local ta, tb = tonumber(a.skillReq) or 0, tonumber(b.skillReq) or 0
        if ta ~= tb then
            return ta < tb
        end
        local sa, sb = tonumber(a.stability) or 0, tonumber(b.stability) or 0
        if sa ~= sb then
            return sa < sb
        end
        return (tonumber(a.count) or 0) > (tonumber(b.count) or 0)
    end)

    -- Largest surplus first. The first main that can form a stable recipe wins.
    table.sort(mains, function(a, b)
        local ca = tonumber(a.count) or 0
        local cb = tonumber(b.count) or 0
        if ca ~= cb then
            return ca > cb
        end
        return (tonumber(a.uid) or 0) < (tonumber(b.uid) or 0)
    end)

    local RS = StockPiler.RecipeSpec
    local bestRecipe, bestParts = nil, nil
    local bestCost = 1e9

    local function tryCombo(main, container, resin, resinUnits)
        if (tonumber(container.uid) or 0) == (tonumber(main.uid) or 0) then
            return
        end
        resinUnits = tonumber(resinUnits) or 0
        if resinUnits < 0 then
            resinUnits = 0
        end
        if resinUnits > 3 then
            return
        end
        if resinUnits > 0 then
            if type(resin) ~= "table" or (tonumber(resin.count) or 0) < resinUnits then
                return
            end
        end
        local slots = {
            {
                role = "container",
                uid = container.uid,
                uniqueID = container.uid,
                perCraft = 1,
                spec = container.spec,
            },
            {
                role = "main",
                uid = main.uid,
                uniqueID = main.uid,
                perCraft = 1,
                spec = main.spec,
            },
        }
        if resinUnits > 0 and type(resin) == "table" then
            slots[#slots + 1] = {
                role = "stabilizer",
                uid = resin.uid,
                uniqueID = resin.uid,
                perCraft = resinUnits,
                spec = resin.spec,
            }
        end
        if RS and RS.EffectiveSpecPerCraft and resinUnits > 0 then
            local want = tonumber(RS.EffectiveSpecPerCraft(slots[3], slots)) or resinUnits
            if want > resinUnits then
                if (tonumber(resin.count) or 0) < want or want > 3 then
                    return
                end
                slots[3].perCraft = want
                resinUnits = want
            end
        end
        if RS and RS.RecipeIsStable and RS.RecipeIsStable({ slots = slots }) ~= true then
            return
        end
        -- Mains are already ordered by surplus. Stabilizer skill breaks ties.
        local rReq = 0
        local rStab = 0
        if type(resin) == "table" then
            rReq = tonumber(resin.skillReq) or 0
            rStab = tonumber(resin.stability) or 0
        end
        local cost = rReq * 10000
            + resinUnits * 100
            + rStab
            + (tonumber(container.stability) or 0)
        if cost < bestCost then
            bestCost = cost
            bestRecipe = {
                slots = slots,
                skillUpOrigin = true,
                recipeYield = 5,
            }
            if RS and RS.BuildRecipeSpecKey then
                bestRecipe.recipeSpecKey = RS.BuildRecipeSpecKey(slots)
                bestRecipe.key = bestRecipe.recipeSpecKey
            end
            bestParts = {
                main = main,
                container = container,
                stabilizer = resin,
                resinPerCraft = resinUnits,
            }
        end
    end

    for mi = 1, #mains do
        local main = mains[mi]
        for ci = 1, #containers do
            local container = containers[ci]
            local needStab = ResinStabNeeded(main.stability, container.stability)
            if needStab <= 0 then
                tryCombo(main, container, nil, 0)
            else
                for ri = 1, #resins do
                    local resin = resins[ri]
                    local rStab = tonumber(resin.stability) or 0
                    if rStab > 0 then
                        local units = math.ceil(needStab / rStab)
                        if units < 1 then
                            units = 1
                        end
                        if units <= 3 then
                            for u = units, 3 do
                                tryCombo(main, container, resin, u)
                            end
                        end
                    end
                end
            end
        end
        if type(bestRecipe) == "table" then
            break
        end
    end

    if type(bestRecipe) ~= "table" then
        if #resins == 0 then
            return nil, "need_resin"
        end
        return nil, "unstable"
    end
    return bestRecipe, nil, bestParts
end

--- AutoBrew needs one free crafting-bag slot to pull mats. Nil occupancy is not full.
local function CraftBagBlocksBrew()
    local BA = StockPiler.BagAdapter
    local free = BA and BA.CraftBagFreeSlots and BA.CraftBagFreeSlots()
    return type(free) == "number" and free < 1
end

--- Synthetic plan row so Brew can auto-load and CanBrewNow lights for SkillUp.
--- opts.quiet: skip stall notify / MarkRefineDue (Watch paint, skillplan dump).
function SkillUp.BuildApoBrewRow(opts)
    opts = type(opts) == "table" and opts or {}
    local quiet = opts.quiet == true
    if SkillUp.ShouldApoBrew() ~= true then
        SkillUp._apoBrewRow = nil
        return nil
    end
    local recipe, why, parts = SkillUp.BuildApoBrewRecipe()
    if type(recipe) ~= "table" then
        SkillUp._apoBrewRow = nil
        -- Wake refine even on quiet Watch paints: plots-full idle otherwise never
        -- CollectIntents, so Apo seed_buffer stalls until a manual refine.
        if why == "seed_buffer" or why == "need_resin" or why == "unstable" then
            if StockPiler.Refine and StockPiler.Refine.MarkRefineDue then
                local due = (why == "seed_buffer") and "skill-up-buffer" or "skill-up-resin"
                StockPiler.Refine.MarkRefineDue(due)
            end
        end
        if not quiet then
            SkillUp.MaybeNotifyApoStall(why or "need_mats")
        end
        return nil
    end
    local RS = StockPiler.RecipeSpec
    local craftable = 0
    if RS and RS.CountCraftsPossible then
        craftable = tonumber(RS.CountCraftsPossible(recipe, { respectGrowReserve = true })) or 0
    end
    if craftable < 1 then
        SkillUp._apoBrewRow = nil
        -- A main in bags is not enough: seed_buffer only when a slot has the
        -- stack but the grow reserve holds it below one craft. A missing vial
        -- is need_mats (#79).
        local heldForBuffer = false
        local slots = recipe.slots
        if type(slots) == "table" and RS.CountItemsMatchingSpec and RS.BrewAvailableForSpec then
            for i = 1, #slots do
                local slot = slots[i]
                if type(slot) == "table" then
                    local spec = slot.spec
                    if RS.ResolveSlotSpec then
                        spec = RS.ResolveSlotSpec(slot) or spec
                    end
                    if type(spec) == "table" then
                        local per = 1
                        if RS.EffectiveSpecPerCraft then
                            per = math.max(1, tonumber(RS.EffectiveSpecPerCraft(slot, slots)) or 1)
                        else
                            per = math.max(1, tonumber(slot.perCraft) or 1)
                        end
                        local bag = tonumber(RS.CountItemsMatchingSpec(spec)) or 0
                        local avail = tonumber(RS.BrewAvailableForSpec(spec)) or 0
                        if bag >= per and avail < per then
                            heldForBuffer = true
                            break
                        end
                    end
                end
            end
        end
        if heldForBuffer and StockPiler.Refine and StockPiler.Refine.MarkRefineDue then
            StockPiler.Refine.MarkRefineDue("skill-up-buffer")
        end
        if not quiet then
            if heldForBuffer then
                SkillUp.MaybeNotifyApoStall("seed_buffer")
            else
                SkillUp.MaybeNotifyApoStall("need_mats")
            end
        end
        return nil
    end
    -- A craftable recipe with no free craft slot is still a stall. Quiet paints
    -- must not clear that latch or the chat line repeats every tick.
    if CraftBagBlocksBrew() then
        if not quiet then
            SkillUp.MaybeNotifyApoStall("craft_bag_full")
        end
    else
        SkillUp._apoStallLatch = nil
    end
    local tier = SkillUp.ApoTargetTier()
    local mainUid = parts and parts.main and parts.main.uid or 0
    local name = TOr("watch.skillup_apo", L"Skill up Apo")
    if parts and parts.main and type(parts.main.item) == "table" and parts.main.item.name ~= nil then
        name = parts.main.item.name
    end
    local row = {
        id = "skill_up_apo",
        potionKey = "skill_up_apo",
        potionRecipeKey = "skill_up_apo",
        name = name,
        recipe = recipe,
        recipeYield = 5,
        skillUp = true,
        statusKey = CraftBagBlocksBrew() and "craft_bag_full" or "ready_to_craft",
        autoGrow = true,
        craftable = craftable,
        craftableSafe = true,
        potionHave = 0,
        potionMin = craftable * 5 + 5,
        potionDeficit = craftable * 5 + 5,
        target = craftable * 5 + 5,
        uniqueID = 0,
        outputUid = 0,
        skillReq = tier,
        mainUid = mainUid,
    }
    SkillUp._apoBrewRow = row
    if StockPiler.Debug and StockPiler.Debug.LogOp then
        local bagMain = 0
        local surplusMain = 0
        local reserveMain = 0
        if mainUid > 0 then
            local Inv = StockPiler.Inventory
            if Inv and Inv.CountByUid then
                bagMain = tonumber(Inv.CountByUid(mainUid)) or 0
            end
            local seedUid = 0
            if parts and parts.main then
                seedUid = tonumber(parts.main.seedUid) or 0
            end
            if seedUid <= 0 then
                local SM = StockPiler.SeedMap
                if SM and SM.ResolveSeedUidForPlant then
                    seedUid = tonumber(SM.ResolveSeedUidForPlant(mainUid, nil)) or 0
                end
            end
            surplusMain = tonumber(SkillUp.PlantBrewSurplus(mainUid, seedUid, bagMain)) or 0
            reserveMain = tonumber(SkillUp.PlantFeedstockReserve(seedUid, mainUid)) or 0
        end
        StockPiler.Debug.LogOp("skillup", string.format(
            "apo-brew main=%d container=%d resin=%d x%d craftable=%d tier=%d bag=%d surplus=%d reserve=%d",
            mainUid,
            parts and parts.container and parts.container.uid or 0,
            parts and parts.stabilizer and parts.stabilizer.uid or 0,
            parts and parts.resinPerCraft or 0,
            craftable,
            tier,
            bagMain,
            surplusMain,
            reserveMain
        ))
    end
    return row
end

function SkillUp.GetApoBrewRow()
    return SkillUp._apoBrewRow
end

--- Buffer-safe refinable uses for Apo resin convert (0 if none).
--- keepOne: leave one plant for a later brew at this plantUid.
local function ApoResinRefineUses(plantUid, seedUid, spec, bagCount, keepOne)
    plantUid = tonumber(plantUid) or 0
    seedUid = tonumber(seedUid) or 0
    bagCount = tonumber(bagCount) or 0
    if plantUid <= 0 or bagCount < 1 then
        return 0, 0
    end
    local surplus = SkillUp.PlantBrewSurplus(plantUid, seedUid, bagCount)
    if keepOne == true and surplus > 1 then
        surplus = surplus - 1
    elseif keepOne == true and surplus < 1 then
        return 0, 0
    elseif surplus < 1 then
        return 0, 0
    end
    local Refine = StockPiler.Refine
    local refinable = 0
    if Refine and Refine.CountRefinablePlants then
        refinable = tonumber(Refine.CountRefinablePlants(plantUid, spec)) or 0
    end
    return math.min(surplus, refinable, 5), surplus
end

--- Leftover main plants below Apo floor (no longer brewable after tier-up).
--- Prefer lowest skillReq, then richest refinable stack.
local function PickApoLeftoverResinPlant(apoTier)
    apoTier = tonumber(apoTier) or 0
    if apoTier <= 1 then
        return nil
    end
    local Inv = StockPiler.Inventory
    local MS = StockPiler.MaterialSpec
    local SM = StockPiler.SeedMap
    if not (Inv and Inv.ForEachItem and MS and MS.FromItemData) then
        return nil
    end
    local best = nil
    local seen = {}
    Inv.ForEachItem(function(item)
        if type(item) ~= "table" then
            return
        end
        local uid = tonumber(item.uniqueID) or 0
        if uid <= 0 or seen[uid] == true then
            return
        end
        seen[uid] = true
        if SM and SM.IsBagSeedOrSpore and SM.IsBagSeedOrSpore(item) then
            return
        end
        if not CanUseCraftingSample(item) then
            return
        end
        local spec = MS.FromItemData(item, nil)
        if type(spec) ~= "table" then
            return
        end
        if tostring(spec.role or "") ~= "main" then
            return
        end
        if LooksNonMainSeed(item, spec) then
            return
        end
        local req = tonumber(spec.skillLevel) or SeedSkillReq(item)
        if req < 1 or req >= apoTier then
            return
        end
        local seedUid = ResolveSeedUidForPlantItem(item, uid)
        local bagCount = Inv.CountByUid and tonumber(Inv.CountByUid(uid)) or 0
        if bagCount <= 0 then
            bagCount = tonumber(item.stackCount) or tonumber(item.StackCount) or 1
        end
        local uses, surplus = ApoResinRefineUses(uid, seedUid, spec, bagCount, false)
        if uses < 1 then
            return
        end
        if best == nil
            or req < best.req
            or (req == best.req and uses > best.uses)
            or (req == best.req and uses == best.uses and uid < best.plantUid)
        then
            best = {
                plantUid = uid,
                seedUid = seedUid,
                spec = spec,
                uses = uses,
                surplus = surplus,
                req = req,
            }
        end
    end)
    return best
end

--- When Apo SkillUp needs resin: prefer leftover lower-tier mains, then
--- surplus of the exact-floor brew main (keep >=1 for brew).
function SkillUp.AppendApoResinRefineIntents(intents, appendFn)
    if type(intents) ~= "table" or type(appendFn) ~= "function" then
        return
    end
    if SkillUp.ShouldApoBrew() ~= true then
        return
    end
    local recipe, why = SkillUp.BuildApoBrewRecipe()
    if type(recipe) == "table" then
        return
    end
    if why ~= "need_resin" and why ~= "unstable" then
        return
    end

    local apoTier = SkillUp.ApoTargetTier()
    local Refine = StockPiler.Refine
    local pick = PickApoLeftoverResinPlant(apoTier)
    local source = "leftover"

    if type(pick) ~= "table" then
        source = "brew-main"
        local mains = SkillUp.ListApoBagMaterials("main")
        local SM = StockPiler.SeedMap
        local Inv = StockPiler.Inventory
        table.sort(mains, function(a, b)
            return (tonumber(a.count) or 0) > (tonumber(b.count) or 0)
        end)
        for i = 1, #mains do
            local main = mains[i]
            if type(main) == "table" and type(main.spec) == "table"
                and SM and SM.IsGrowableSpec and SM.IsGrowableSpec(main.spec) == true
            then
                local plantUid = tonumber(main.uid) or 0
                local seedUid = tonumber(main.seedUid) or 0
                if plantUid > 0 then
                    local bagCount = Inv and Inv.CountByUid and tonumber(Inv.CountByUid(plantUid))
                        or tonumber(main.bagCount) or tonumber(main.count) or 0
                    local uses, surplus = ApoResinRefineUses(plantUid, seedUid, main.spec, bagCount, true)
                    if (tonumber(uses) or 0) >= 1 then
                        pick = {
                            plantUid = plantUid,
                            seedUid = seedUid,
                            spec = main.spec,
                            uses = uses,
                            surplus = surplus,
                            req = apoTier,
                        }
                        break
                    end
                end
            end
        end
        if type(pick) ~= "table" then
            return
        end
    end

    local plantUid = tonumber(pick.plantUid) or 0
    local seedUid = tonumber(pick.seedUid) or 0
    local uses = tonumber(pick.uses) or 0
    if plantUid <= 0 or uses < 1 then
        return
    end
    local budget = Refine and Refine.GetSeedBudget and Refine.GetSeedBudget(seedUid) or nil
    appendFn({
        spec = pick.spec,
        seedUid = seedUid,
        plantUid = plantUid,
        specKey = "skill_up_resin:" .. tostring(plantUid),
    }, "resin-need", uses, budget)
    if StockPiler.Debug and StockPiler.Debug.LogOp then
        StockPiler.Debug.LogOp("skillup", string.format(
            "apo-resin-refine source=%s plantUid=%d seedUid=%d uses=%d surplus=%d req=%d apoTier=%d",
            source, plantUid, seedUid, uses, tonumber(pick.surplus) or 0,
            tonumber(pick.req) or 0, apoTier
        ))
    end
end

function SkillUp.ResolveBuyContainerTarget()
    local targetTier = SkillUp.ApoTargetTier()
    if targetTier < 1 then
        targetTier = 1
    end
    local VA = StockPiler.VendorAdapter
    local MS = StockPiler.MaterialSpec
    if not MS then
        return nil
    end
    local main = SkillUp.PickApoBagMaterial("main")
        or SkillUp.PickApoBagMaterial("main", { ignoreReserve = true })
    local mainStab = main and (tonumber(main.stability) or SpecStability(main.spec)) or -2
    local resins = SkillUp.ListApoBagMaterials("stabilizer")
    local bestResinStab = 0
    local resinCount = 0
    for i = 1, #resins do
        local r = resins[i]
        local s = tonumber(r.stability) or 0
        if s > bestResinStab then
            bestResinStab = s
        end
        resinCount = resinCount + (tonumber(r.count) or 0)
    end
    if bestResinStab < 1 then
        bestResinStab = 1
    end
    local maxResinStab = math.min(3, math.max(1, resinCount)) * bestResinStab
    local needFromContainer = ResinStabNeeded(mainStab, 0) - maxResinStab
    if needFromContainer < 0 then
        needFromContainer = 0
    end

    local bestUid, bestSpec, bestReq = 0, nil, -1
    local bestScore = -1e18
    local function consider(uid, item)
        uid = tonumber(uid) or 0
        if uid <= 0 or type(item) ~= "table" then
            return
        end
        local spec = MS.FromItemData and MS.FromItemData(item, nil)
        if not IsValidApoContainer(item, spec) then
            return
        end
        local req = tonumber(spec.skillLevel) or SeedSkillReq(item)
        if req > targetTier then
            return
        end
        local stab = SpecStability(spec)
        local ok = (stab >= needFromContainer) and 1 or 0
        local score = ok * 1e12
            - stab * 1e6
            - math.abs(req - targetTier) * 1e3
            + req
        if score > bestScore then
            bestScore = score
            bestUid = uid
            bestReq = req
            bestSpec = spec
        end
    end
    local items = StockPiler.Account and StockPiler.Account.items
    if type(items) == "table" then
        for key, row in pairs(items) do
            if type(row) == "table" then
                local uid = tonumber(row.uniqueID) or tonumber(key) or 0
                consider(uid, row)
            end
        end
    end
    if VA and VA.GetMatchIndex then
        local index = VA.GetMatchIndex()
        if type(index) == "table" and type(index.rows) == "table" then
            for i = 1, #index.rows do
                local row = index.rows[i]
                local item = row and row.item
                if type(item) == "table" then
                    consider(item.uniqueID, item)
                end
            end
        end
    end
    if VA and VA.GetStoreItems then
        local list = VA.GetStoreItems()
        if type(list) == "table" then
            for i = 1, #list do
                local item = list[i]
                if type(item) == "table" then
                    consider(item.uniqueID, item)
                end
            end
        end
    end
    if bestUid > 0 then
        return {
            seedUid = bestUid,
            uid = bestUid,
            skillReq = bestReq,
            targetMax = targetTier,
            spec = bestSpec,
        }
    end
    local cit = GameData and GameData.CraftingItemType or {}
    local Caps = StockPiler.TradeSkillCaps
    local apoId = Caps and Caps.ApothecaryId and Caps.ApothecaryId() or 4
    local slotType = tonumber(cit.CONTAINER) or 5
    return {
        uid = 0,
        seedUid = 0,
        skillReq = targetTier,
        targetMax = targetTier,
        spec = {
            role = "container",
            tradeSkill = apoId,
            slotType = slotType,
            skillLevel = targetTier,
            bonuses = {},
            incomplete = false,
        },
    }
end

function SkillUp.CollectContainerBuyJobs()
    local jobs = {}
    if SkillUp.ShouldApoBuyContainer() ~= true then
        return jobs
    end
    local target = SkillUp.ResolveBuyContainerTarget()
    if type(target) ~= "table" then
        return jobs
    end
    local uid = tonumber(target.uid) or 0
    local spec = target.spec
    if type(spec) ~= "table" then
        local MS = StockPiler.MaterialSpec
        local Inv = StockPiler.Inventory
        local sample = uid > 0 and Inv and Inv.GetSample and Inv.GetSample(uid)
        if MS and MS.FromItemData and type(sample) == "table" then
            spec = MS.FromItemData(sample, nil)
        end
    end
    if type(spec) ~= "table" or tostring(spec.role or "") ~= "container" then
        return jobs
    end
    local want = SkillUp.ApoContainerBuyTarget()
    local have = SkillUp.CountApoContainers()
    local deficit = want - have
    if deficit < 1 then
        return jobs
    end
    jobs[#jobs + 1] = {
        uid = uid,
        uniqueID = uid,
        deficit = deficit,
        skillUp = true,
        growable = false,
        isGrowable = false,
        role = "container",
        spec = spec,
        specKey = "skill_up_container:" .. tostring(uid > 0 and uid or (tonumber(spec.skillLevel) or 1)),
        acquireKey = "skill_up_container:" .. tostring(uid > 0 and uid or (tonumber(spec.skillLevel) or 1)),
        skillReq = tonumber(target.skillReq) or tonumber(spec.skillLevel) or 0,
    }
    local logSig = tostring(uid) .. ":" .. tostring(want) .. ":" .. tostring(have) .. ":" .. tostring(deficit)
    if StockPiler.Debug and StockPiler.Debug.LogOp and SkillUp._buyContainerLogSig ~= logSig then
        SkillUp._buyContainerLogSig = logSig
        StockPiler.Debug.LogOp("skillup", string.format(
            "buy-container uid=%d skillReq=%d want=%d have=%d deficit=%d nextTier=%d",
            uid, tonumber(target.skillReq) or 0, want, have, deficit,
            SkillUp.NextApoTier(SkillUp.GetApoSkill())
        ))
    end
    return jobs
end

--- Same AutoBuy mapping the stall chat uses, so the watch row does not say
--- "No vial" while chat says to open a vendor.
function SkillUp.MapApoBuyStall(why)
    why = tostring(why or "")
    if why == "wait_cult" or why == "need_resin" or why == "seed_buffer"
        or why == "unstable" or why == "craft_bag_full"
    then
        return why
    end
    if SkillUp.ShouldApoBuyContainer() ~= true then
        return why
    end
    local VA = StockPiler.VendorAdapter
    if not (VA and VA.IsStoreOpen and VA.IsStoreOpen() == true) then
        return "need_container_vendor"
    end
    return "no_vendor_container"
end

--- Notify once per Apo stall reason; clear latch when condition lifts.
function SkillUp.MaybeNotifyApoStall(why)
    if SkillUp.ShouldApoBrew() ~= true then
        SkillUp._apoStallLatch = nil
        return
    end
    why = tostring(why or "need_mats")
    if why == "" then
        why = "need_mats"
    end
    -- Brew-row "need main + container" and the watch "no vial" block are the
    -- same shortage. Leaving them distinct reprints both on every tick.
    if why == "need_mats" and (tonumber(SkillUp.CountApoContainers()) or 0) < 1 then
        why = "no_vial"
    end
    why = SkillUp.MapApoBuyStall(why)
    if SkillUp._apoStallLatch == why then
        return
    end
    SkillUp._apoStallLatch = why
    local msg
    if StockPiler.T then
        local key = "skillup.apo.stall." .. why
        msg = StockPiler.T(key)
    else
        msg = L"<icon02486> Skill up Apo stalled - need container, main, or resin."
    end
    if StockPiler.Debug and StockPiler.Debug.Print then
        StockPiler.Debug.Print(msg)
    end
    if ApoStallNeedsUser(why) then
        PlayUserActionSound()
    end
end

----------------------------------------------------------------
-- Ephemeral Watch-tab status rows (never SavedVariables watches)
----------------------------------------------------------------

TOr = function(key, fallback)
    local Locale = StockPiler.Locale
    if Locale and Locale.ResolveTemplate then
        local s = Locale.ResolveTemplate(key)
        if s ~= nil then
            return s
        end
    elseif StockPiler.T then
        local s = StockPiler.T(key)
        if s ~= nil then
            return s
        end
    end
    return fallback
end

local function TFmt(key, tokens, fallback)
    if StockPiler.T then
        local s = StockPiler.T(key, tokens)
        if s ~= nil then
            return s
        end
    end
    return fallback
end

--- Why SkillUp is idle while watches still need work (for ephemeral Watch status).
--- Returns statusKey, statusText, statusLines (or nil,nil,nil when WatchesDone).
--- When short watches are all progress-blocked, returns fallback_blocked so UI can
--- show that SkillUp is allowed to act without consuming watch mats.
local function WaitingWatchesStatus(kind)
    if SkillUp.WatchesDone() == true then
        return nil, nil, nil
    end
    local Watch = StockPiler.Watch
    local potionShort = Watch and Watch.AllEnabledPotionWatchesStocked
        and Watch.AllEnabledPotionWatchesStocked() ~= true
    local plantShort = AllEnabledPlantWatchesStocked() ~= true
    local bufferShort = SeedBufferOk() ~= true

    if bufferShort ~= true and SkillUp.AllShortWatchesProgressBlocked() == true then
        local lines = {
            TOr(
                kind == "apo" and "skillup.watch.apo_fallback_tip" or "skillup.watch.cult_fallback_tip",
                L"Watches cannot progress (AutoGrow/vendor/skill). Skill up uses surplus only."
            ),
        }
        if potionShort then
            lines[#lines + 1] = TOr("skillup.watch.waiting_detail_potions", L"Potion watches still short.")
        end
        if plantShort then
            lines[#lines + 1] = TOr("skillup.watch.waiting_detail_plants", L"Plant watches still short.")
        end
        return "fallback_blocked",
            TOr("skillup.watch.fallback_blocked", L"Skill up while watches blocked"),
            lines
    end

    local key = "waiting_watches"
    local text
    if potionShort and not plantShort and not bufferShort then
        key = "waiting_potions"
        text = TOr("skillup.watch.waiting_potions", L"Waiting - potion watches first")
    elseif plantShort and not potionShort and not bufferShort then
        key = "waiting_plants"
        text = TOr("skillup.watch.waiting_plants", L"Waiting - plant watches first")
    elseif bufferShort and not potionShort and not plantShort then
        key = "waiting_seed_buffer"
        text = TOr("skillup.watch.waiting_seed_buffer", L"Waiting - seed buffer first")
    else
        text = TOr("skillup.watch.waiting_watches", L"Waiting - watches / seed buffer first")
    end
    local lines = {
        TOr(
            kind == "apo" and "skillup.watch.apo_waiting_tip" or "skillup.watch.cult_waiting_tip",
            L"Skill up stays idle until enabled watches are stocked and the seed buffer is met."
        ),
    }
    if potionShort then
        lines[#lines + 1] = TOr("skillup.watch.waiting_detail_potions", L"Potion watches still short.")
    end
    if plantShort then
        lines[#lines + 1] = TOr("skillup.watch.waiting_detail_plants", L"Plant watches still short.")
    end
    if bufferShort then
        lines[#lines + 1] = TOr("skillup.watch.waiting_detail_buffer", L"Seed buffer still short.")
    end
    return key, text, lines
end

local function CultStatusKeyAndText()
    if SkillUp.HasUpgradePlant() == true or SkillUp.HasRefinablePlants() == true then
        local pick = SkillUp.PickBestBagSeed()
        local budget = pick and SeedBudget(tonumber(pick.seedUid) or 0) or nil
        local headroom = type(budget) == "table" and (tonumber(budget.headroom) or 0) or 0
        if headroom > 0 or SkillUp.HasUpgradePlant() == true then
            return "refining", TOr("skillup.watch.cult_refining", L"Refining for seeds")
        end
    end
    local job = SkillUp.PickPlantJob and SkillUp.PickPlantJob() or nil
    if type(job) == "table" and (tonumber(job.plantable) or 0) >= 1 then
        local budget = SeedBudget(tonumber(job.seedUid) or 0)
        local headroom = tonumber(budget.headroom) or 0
        if headroom > 0 then
            return "buffer_plant", TOr("skillup.watch.cult_buffer", L"Planting for seed buffer")
        end
        return "planting", TOr("skillup.watch.cult_planting", L"Planting Skill up seeds")
    end
    -- Prefer live garden over stall latch: buffer AutoBuy while plots are full
    -- must not paint "Open seed vendor" over "Plots full - waiting harvest".
    if SkillUp.CountEmptyPlots() <= 0 then
        return "growing", TOr("skillup.watch.cult_growing", L"Plots full - waiting harvest")
    end
    local reason = SkillUp.CultStallReason and SkillUp.CultStallReason() or nil
    if reason == nil then
        reason = tostring(SkillUp._stallLatch or "")
        if reason == "" then
            reason = nil
        end
    end
    if reason ~= nil then
        local short = TOr("skillup.watch.cult_" .. reason, nil)
        if short ~= nil then
            return reason, short
        end
        return reason, TOr("skillup.stall." .. reason, L"Skill up Culti stalled")
    end
    return "idle", TOr("skillup.watch.cult_idle", L"Skill up Culti idle")
end

--- Highest-skillReq seed currently growing (garden plots + Grow pending).
--- Used for Cult SkillUp watch icon/tooltip so it matches what is in the ground.
local function HighestInGroundSkillUpSeed()
    local bestUid, bestReq, bestPlant, bestIcon, bestItem = 0, -1, 0, 0, nil
    local function consider(seedUid, plantUid, iconNum, item)
        seedUid = tonumber(seedUid) or 0
        if seedUid <= 0 then
            return
        end
        local req = 0
        if type(item) == "table" then
            req = SeedSkillReq(item)
        end
        if req <= 0 then
            local Inv = StockPiler.Inventory
            if Inv and Inv.GetSample then
                local sample = Inv.GetSample(seedUid)
                if type(sample) == "table" then
                    req = SeedSkillReq(sample)
                    if type(item) ~= "table" then
                        item = sample
                    end
                    if (tonumber(iconNum) or 0) <= 0 then
                        iconNum = tonumber(sample.iconNum) or 0
                    end
                end
            end
        end
        if req <= 0 and StockPiler.Items and StockPiler.Items.GetByUid then
            local row = StockPiler.Items.GetByUid(seedUid)
            if type(row) == "table" then
                req = SeedSkillReq(row)
                if type(item) ~= "table" then
                    item = row
                end
            end
        end
        if req > bestReq or (req == bestReq and seedUid > bestUid) then
            bestReq = req
            bestUid = seedUid
            bestPlant = tonumber(plantUid) or 0
            bestIcon = tonumber(iconNum) or 0
            bestItem = item
        end
    end

    local Garden = StockPiler.Garden
    local plots = Garden and Garden.GetPlots and Garden.GetPlots() or nil
    if type(plots) == "table" then
        for _, row in pairs(plots) do
            if type(row) == "table" then
                local stage = tonumber(row.stage) or 0
                -- Empty plots use stage 0 / 255; skip empty.
                if stage ~= 0 and stage ~= 255 and (tonumber(row.seedUid) or 0) > 0 then
                    consider(
                        row.seedUid,
                        row.plantUid,
                        row.seedIconNum,
                        type(row.seed) == "table" and row.seed or nil
                    )
                end
            end
        end
    end

    local Grow = StockPiler.Grow
    if Grow and type(Grow._pendingPlant) == "table" and type(Grow._pendingSeedUid) == "table" then
        for plotNum, flag in pairs(Grow._pendingPlant) do
            if (tonumber(flag) or 0) > 0 then
                consider(Grow._pendingSeedUid[plotNum], 0, 0, nil)
            end
        end
    end

    if bestUid <= 0 then
        return nil
    end
    return {
        seedUid = bestUid,
        plantUid = bestPlant,
        skillReq = bestReq,
        iconNum = bestIcon,
        item = bestItem,
    }
end

local function TradeSkillIcon(kind)
    local Caps = StockPiler.TradeSkillCaps
    if kind == "apo" then
        return Caps and Caps.GetApothecaryIcon and tonumber(Caps.GetApothecaryIcon()) or 0
    end
    return Caps and Caps.GetCultivationIcon and tonumber(Caps.GetCultivationIcon()) or 0
end

--- A zero skill reading is not an unlearn. IsCultEnabled / IsApoEnabled already
--- pause skill-up while the skill reads 0. The saved on/off choice stays (#87).
function SkillUp.DropToggleIfUnlearned()
end

--- The checkbox is one switch for every skill that can still level.
--- Learning Apothecary while Cultivating skill-up is already on (or the
--- reverse) turns the new skill on without another click.
--- Only a confirmed 0 -> >0 learn counts. A skill the player left off, and
--- the first sample after login, stay as they were.
local _adoptCharKey = nil
local _adoptPrevCult = nil
local _adoptPrevApo = nil

function SkillUp.AdoptReadySkills()
    local row = CharRow(false)
    if type(row) ~= "table" then
        return
    end
    local CapsMod = Caps()
    -- Before the first trade-skill pulse a missing persist reads 0. That is
    -- not a learn, and adopting here would turn a saved-off skill back on.
    if not CapsMod or CapsMod._skillsReady ~= true then
        return
    end
    if row.skillUpSeenBackfill ~= true then
        if (tonumber(row.lastCultSkill) or 0) > 0 then
            row.skillUpCultSeen = true
        end
        if (tonumber(row.lastApoSkill) or 0) > 0 then
            row.skillUpApoSeen = true
        end
        row.skillUpSeenBackfill = true
    end
    local Watch = StockPiler.Watch
    local charKey = Watch and Watch.GetCharacterKey and Watch.GetCharacterKey() or ""
    if charKey ~= _adoptCharKey then
        _adoptCharKey = charKey
        _adoptPrevCult = nil
        _adoptPrevApo = nil
    end
    local cult = tonumber(SkillUp.GetCultSkill()) or 0
    local apo = tonumber(SkillUp.GetApoSkill()) or 0
    local prevCult = _adoptPrevCult
    local prevApo = _adoptPrevApo
    _adoptPrevCult = cult
    _adoptPrevApo = apo
    local cultOn = SkillUp.IsCultToggleOn() == true
    local apoOn = SkillUp.IsApoToggleOn() == true
    local function NoteSeen(level, seenKey, prev, otherOn, toggleOn, visible, enable)
        if level <= 0 then
            return
        end
        if row[seenKey] == true then
            return
        end
        row[seenKey] = true
        -- The first sample after login only records that the skill exists.
        if prev == nil then
            return
        end
        if otherOn == true and toggleOn ~= true and visible == true then
            enable(true)
        end
    end
    NoteSeen(cult, "skillUpCultSeen", prevCult, apoOn, cultOn, SkillUp.IsCultVisible() == true, SkillUp.SetCultEnabled)
    NoteSeen(apo, "skillUpApoSeen", prevApo, cultOn, apoOn, SkillUp.IsApoVisible() == true, SkillUp.SetApoEnabled)
end

--- True when the Cult SkillUp watch row should mount.
--- While Cultivating can still level and its toggle is on, or while it is
--- planting to assist Apothecary (including at Cultivation 200). Apothecary
--- alone, with Cultivation unlearned, stays hidden.
function SkillUp.WantCultWatchRow()
    if SkillUp.IsCultEnabled() == true then
        return true
    end
    if SkillUp.IsApoEnabled() == true and (tonumber(SkillUp.GetCultSkill()) or 0) > 0 then
        return true
    end
    return false
end

--- True when the Apo SkillUp watch row should mount.
function SkillUp.WantApoWatchRow()
    return SkillUp.IsApoEnabled() == true
end

local function BuildCultWatchStatusRow()
    if SkillUp.WantCultWatchRow() ~= true then
        return nil
    end
    local cult = SkillUp.GetCultSkill()
    local Caps = StockPiler.TradeSkillCaps
    local Watch = StockPiler.Watch
    local agOn = Watch and Watch.IsAutoGrowEnabled and Watch.IsAutoGrowEnabled() == true
    -- Transient empty tradeSkills: keep a stub row while toggles stay on.
    if cult <= 0 or (Caps and Caps.CanAutoGrow and Caps.CanAutoGrow() ~= true) then
        local dash = TOr("ui.dash", L"-")
        return {
            id = "skill_up_cult",
            potionKey = "skill_up_cult",
            potionRecipeKey = "skill_up_cult",
            kind = "skillup",
            skillUp = true,
            addonOwned = true,
            skillUpKind = "cult",
            isPlantWatch = true,
            name = TOr("watch.skillup_cult", L"Cultivating"),
            iconNum = TradeSkillIcon("cult"),
            uniqueID = 0,
            seedUid = 0,
            plantUid = 0,
            potionHave = 0,
            stockText = dash,
            target = 0,
            potionMin = 0,
            potionDeficit = 0,
            targetText = dash,
            priorityTier = 0,
            priorityTierText = L"-",
            plantPrioSentinel = true,
            autoGrow = agOn == true,
            hideAutoGrow = false,
            hideBrew = true,
            hideCraftable = true,
            craftable = 0,
            craftableText = L"",
            statusKey = "skill_blip",
            statusText = TOr("skillup.watch.skill_blip", L"Waiting for trade skills..."),
            statusLines = {
                TOr("skillup.watch.cult_tip", L"Addon-controlled Cultivating Skill up (not a saved watch)."),
            },
            skillReq = 0,
            nameR = 255,
            nameG = 255,
            nameB = 255,
        }
    end

    -- Internals still track the active seed line (highest in plots, else bag pick).
    local growing = HighestInGroundSkillUpSeed()
    local pick = SkillUp.PickBestBagSeed()
    local seedUid = 0
    local plantUid = 0
    if type(growing) == "table" and (tonumber(growing.seedUid) or 0) > 0 then
        seedUid = tonumber(growing.seedUid) or 0
        plantUid = tonumber(growing.plantUid) or 0
    end
    if seedUid <= 0 and type(pick) == "table" then
        seedUid = tonumber(pick.seedUid) or 0
        plantUid = tonumber(pick.plantUid) or 0
    end
    if plantUid <= 0 and seedUid > 0 then
        local SM = StockPiler.SeedMap
        if SM and SM.PrimaryPlantForSeed then
            plantUid = tonumber(SM.PrimaryPlantForSeed(seedUid)) or 0
        end
    end
    local budget = SeedBudget(seedUid)
    local live = tonumber(budget.live) or 0
    local buffer = tonumber(budget.bufferMin) or 0
    local statusKey, statusText, waitingLines
    statusKey, statusText, waitingLines = WaitingWatchesStatus("cult")
    if statusKey == "fallback_blocked" then
        if agOn ~= true then
            -- Master AG off still blocks Cult planting; keep fallback label.
        else
            local activeKey, activeText = CultStatusKeyAndText()
            if activeKey ~= nil and activeKey ~= "idle" and activeKey ~= "need_mats"
                and activeKey ~= "need_seeds" and activeKey ~= "autobuy_off"
            then
                statusKey, statusText = activeKey, activeText
            end
        end
    elseif statusKey == nil then
        if agOn ~= true then
            statusKey = "enable_autogrow"
            statusText = TOr("plan.status.enable_autogrow", L"Enable AutoGrow")
        else
            statusKey, statusText = CultStatusKeyAndText()
        end
    end
    local displayReq = type(growing) == "table" and (tonumber(growing.skillReq) or 0) or 0
    if displayReq < 1 and type(pick) == "table" then
        displayReq = tonumber(pick.skillReq) or 0
    end
    local tier = SkillUp.TargetMaxSkill()
    if displayReq > 0 then
        tier = displayReq
    end
    if SkillUp.IsCultEnabled() == true and SkillUp.IsApoEnabled() == true then
        local cultTier = SkillUp.FloorCultTier(cult)
        local apoTier = SkillUp.FloorApoTier(SkillUp.GetApoSkill())
        if apoTier > 0 and cultTier > apoTier and SkillUp.TargetMaxSkill() == apoTier then
            statusKey = "cult_for_apo"
            statusText = TFmt("skillup.watch.cult_for_apo", { tier = tostring(apoTier) },
                towstring(string.format("Planting tier %d for Apothecary", apoTier)))
            tier = apoTier
        end
    end
    local dash = TOr("ui.dash", L"-")
    local statusLines = {
        TOr("skillup.watch.cult_tip", L"Addon-controlled Cultivating Skill up (not a saved watch)."),
        TOr("skillup.watch.cult_ag_tip", L"Uses master AutoGrow to plant and refine. Per-row toggle is display-only."),
        TFmt("skillup.watch.cult_tier_line", { tier = tostring(tier) },
            towstring(string.format("Planting tier: %d", tier))),
        TFmt("skillup.watch.cult_buffer_line", {
            have = tostring(live),
            need = tostring(buffer),
        }, towstring(string.format("Seed buffer: %d / %d (live / min)", live, buffer))),
    }
    if type(waitingLines) == "table" then
        for i = 1, #waitingLines do
            statusLines[#statusLines + 1] = waitingLines[i]
        end
    end
    return {
        id = "skill_up_cult",
        potionKey = "skill_up_cult",
        potionRecipeKey = "skill_up_cult",
        kind = "skillup",
        skillUp = true,
        addonOwned = true,
        skillUpKind = "cult",
        isPlantWatch = true,
        name = TOr("watch.skillup_cult", L"Cultivating"),
        iconNum = TradeSkillIcon("cult"),
        itemData = nil,
        uniqueID = 0,
        seedUid = seedUid,
        plantUid = plantUid,
        -- Stock/Craftable/Target are potion-watch columns; blank on SkillUp.
        potionHave = live,
        stockText = dash,
        target = buffer,
        potionMin = buffer,
        potionDeficit = math.max(0, buffer - live),
        targetText = dash,
        priorityTier = 0,
        priorityTierText = L"-",
        plantPrioSentinel = true,
        -- Read-only mirror of master AutoGrow (Cult SkillUp planting requires it).
        autoGrow = agOn == true,
        hideAutoGrow = false,
        hideBrew = true,
        hideCraftable = true,
        craftable = 0,
        craftableText = L"",
        statusKey = statusKey,
        statusText = statusText,
        statusLines = statusLines,
        skillReq = tier,
        nameR = 255,
        nameG = 255,
        nameB = 255,
    }
end

--- Why Apothecary skill-up cannot move, when the player has to act.
--- no_vial lets Cultivation plant its own tier until a vial is back.
--- wait_cult and seed_buffer are Cultivation's job, so they are not a block.
function SkillUp.ApoProgressBlock()
    if SkillUp.IsApoEnabled() ~= true then
        return nil
    end
    local apo = tonumber(SkillUp.GetApoSkill()) or 0
    if apo <= 0 or apo >= (SkillUp.APO_MAX or 200) then
        return nil
    end
    if (tonumber(SkillUp.CountApoContainers()) or 0) < 1 then
        return "no_vial"
    end
    if SkillUp.ShouldApoBrew() ~= true then
        return nil
    end
    local recipe, why = SkillUp.BuildApoBrewRecipe()
    if type(recipe) == "table" then
        return nil
    end
    why = tostring(why or "")
    if why == "" or why == "wait_cult" or why == "seed_buffer" then
        return nil
    end
    return why
end

local function ApoStatusFromWhy(why)
    why = tostring(why or "need_mats")
    if why == "" then
        why = "need_mats"
    end
    local text = TOr("skillup.watch.apo_" .. why, nil)
    if text == nil then
        text = TOr("skillup.apo.stall." .. why, L"Skill up Apo waiting")
    end
    return why, text
end

local function BuildApoWatchStatusRow()
    if SkillUp.WantApoWatchRow() ~= true then
        return nil
    end
    local apo = SkillUp.GetApoSkill()
    if apo <= 0 then
        local dash = TOr("ui.dash", L"-")
        return {
            id = "skill_up_apo",
            potionKey = "skill_up_apo",
            potionRecipeKey = "skill_up_apo",
            kind = "skillup",
            skillUp = true,
            addonOwned = true,
            skillUpKind = "apo",
            name = TOr("watch.skillup_apo", L"Apothecary"),
            iconNum = TradeSkillIcon("apo"),
            uniqueID = 0,
            potionHave = 0,
            stockText = dash,
            target = 0,
            potionMin = 0,
            potionDeficit = 0,
            targetText = dash,
            priorityTier = 0,
            priorityTierText = L"-",
            autoGrow = false,
            hideAutoGrow = true,
            hideBrew = true,
            craftable = 0,
            craftableText = L"",
            craftableSafe = false,
            statusKey = "skill_blip",
            statusText = TOr("skillup.watch.skill_blip", L"Waiting for trade skills..."),
            statusLines = {
                TOr("skillup.watch.apo_tip", L"Addon-controlled Apothecary Skill up (not a saved watch)."),
            },
            skillReq = 0,
            recipe = nil,
            recipeYield = 5,
            nameR = 255,
            nameG = 255,
            nameB = 255,
        }
    end
    local tier = SkillUp.ApoTargetTier()
    local waitingKey, waitingText, waitingLines = WaitingWatchesStatus("apo")
    local brewRow = nil
    local statusKey, statusText, craftable, target, recipe
    if waitingKey == "fallback_blocked" then
        if SkillUp.ShouldApoBrew() == true and SkillUp.BuildApoBrewRow then
            brewRow = SkillUp.BuildApoBrewRow({ quiet = true })
        end
        if type(brewRow) == "table" then
            statusKey = "ready_to_craft"
            statusText = TOr("plan.status.ready_to_craft", L"Ready to brew")
            craftable = tonumber(brewRow.craftable) or 0
            target = tonumber(brewRow.target) or (craftable * 5)
            recipe = brewRow.recipe
        else
            statusKey = waitingKey
            statusText = waitingText
            craftable = 0
            target = 0
            recipe = nil
        end
    elseif waitingKey ~= nil then
        statusKey = waitingKey
        statusText = waitingText
        craftable = 0
        target = 0
        recipe = nil
    else
        if SkillUp.ShouldApoBrew() == true and SkillUp.BuildApoBrewRow then
            brewRow = SkillUp.BuildApoBrewRow({ quiet = true })
        end
        if type(brewRow) == "table" then
            statusKey = "ready_to_craft"
            statusText = TOr("plan.status.ready_to_craft", L"Ready to brew")
            craftable = tonumber(brewRow.craftable) or 0
            target = tonumber(brewRow.target) or (craftable * 5)
            recipe = brewRow.recipe
        else
            local latch = tostring(SkillUp._apoStallLatch or "need_mats")
            statusKey, statusText = ApoStatusFromWhy(latch)
            craftable = 0
            target = 0
            recipe = nil
        end
    end
    if statusKey ~= "ready_to_craft" and (waitingKey == nil or waitingKey == "fallback_blocked") then
        local block = SkillUp.ApoProgressBlock()
        if block ~= nil then
            block = SkillUp.MapApoBuyStall(block)
            statusKey, statusText = ApoStatusFromWhy(block)
            craftable = 0
            target = 0
            recipe = nil
            SkillUp.MaybeNotifyApoStall(block)
        end
    end
    -- AutoBrew refuses a load when the crafting bag has no free slot. Say so
    -- here; a free slot returns this row to Ready on the next build.
    if statusKey == "ready_to_craft" and CraftBagBlocksBrew() then
        statusKey = "craft_bag_full"
        statusText = TOr("plan.status.craft_bag_full", L"Craft bag full")
        SkillUp.MaybeNotifyApoStall("craft_bag_full")
    end

    local name = TOr("watch.skillup_apo", L"Apothecary")
    local dash = TOr("ui.dash", L"-")
    local statusLines = {
        TOr("skillup.watch.apo_tip", L"Addon-controlled Apothecary Skill up (not a saved watch)."),
        TOr("skillup.watch.apo_brew_tip", L"Does not use AutoGrow. Use Brew when ready (or the Craft macro)."),
        TFmt("skillup.watch.apo_tier_line", { tier = tostring(tier) },
            towstring(string.format("Brewing at Apo skill %d", tier))),
        TFmt("skillup.watch.apo_craftable_line", { n = tostring(craftable or 0) },
            towstring(string.format("Craftable batches now: %d", craftable or 0))),
    }
    if statusKey == "craft_bag_full" then
        table.insert(statusLines, 1, TOr("watch.note.craft_bag_full", L"Free craft bag slots to brew / harvest"))
    end
    if type(waitingLines) == "table" then
        for i = 1, #waitingLines do
            statusLines[#statusLines + 1] = waitingLines[i]
        end
    end
    return {
        id = "skill_up_apo",
        potionKey = "skill_up_apo",
        potionRecipeKey = "skill_up_apo",
        kind = "skillup",
        skillUp = true,
        addonOwned = true,
        skillUpKind = "apo",
        name = name,
        iconNum = TradeSkillIcon("apo"),
        itemData = nil,
        uniqueID = 0,
        mainUid = type(brewRow) == "table" and (tonumber(brewRow.mainUid) or 0) or 0,
        -- Stock/Craftable/Target are potion-watch columns; blank on SkillUp.
        potionHave = 0,
        stockText = dash,
        target = target or 0,
        potionMin = target or 0,
        potionDeficit = target or 0,
        targetText = dash,
        priorityTier = 0,
        priorityTierText = L"-",
        -- Apo SkillUp brews without AutoGrow; Cult assist (mats) uses master AutoGrow separately.
        autoGrow = false,
        hideAutoGrow = true,
        hideBrew = statusKey ~= "ready_to_craft",
        craftable = craftable or 0,
        craftableText = L"",
        craftableSafe = statusKey == "ready_to_craft",
        statusKey = statusKey,
        statusText = statusText,
        statusLines = statusLines,
        skillReq = tier,
        recipe = recipe,
        recipeYield = type(brewRow) == "table" and brewRow.recipeYield or 5,
        nameR = 255,
        nameG = 255,
        nameB = 255,
    }
end

--- True when ephemeral SkillUp rows should appear on the Watch tab.
--- Each row mounts only while that skill is learned and under 200.
function SkillUp.ShouldShowWatchStatus()
    return SkillUp.WantCultWatchRow() == true or SkillUp.WantApoWatchRow() == true
end

--- 0-2 ephemeral Watch-tab rows (Cult / Apo). Never written to WatchStore.
--- Built while SkillUp is active (or skill blip); Status shows waiting vs active.
function SkillUp.BuildWatchStatusRows()
    local rows = {}
    local cult = BuildCultWatchStatusRow()
    if type(cult) == "table" then
        rows[#rows + 1] = cult
    end
    local apo = BuildApoWatchStatusRow()
    if type(apo) == "table" then
        rows[#rows + 1] = apo
    end
    return rows
end
