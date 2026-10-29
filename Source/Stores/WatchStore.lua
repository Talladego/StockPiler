----------------------------------------------------------------
-- StockPiler Stores/WatchStore - per-character watches + toggles
----------------------------------------------------------------

StockPiler = StockPiler or {}
StockPiler.Watch = StockPiler.Watch or {}
local Watch = StockPiler.Watch

Watch._gen = 0

--- Fields the Watch tab may write. Built once; SetCharacterField rejects the rest.
local CHARACTER_FIELDS = {
    autoGrowEnabled = true,
    autoGrowAdditives = true,
    growSeedBufferEnabled = true,
    growSeedBufferMin = true,
    autoBuyEnabled = true,
    autoBuyReserveGold = true,
    autoBuyBudgetGold = true,
    autoBrewEnabled = true,
    watchOptimisticOutcomeEstimate = true,
}

--- Per-character settings bucket (autoGrowEnabled, watches, AutoBuy, etc.).
function Watch.CharacterRow(create)
    return StockPiler.Util.CharacterRow(create)
end

-- Alias: some call sites expect GetCharacter for settings access.
Watch.GetCharacter = Watch.CharacterRow

local function CharacterRow(create)
    return Watch.CharacterRow(create)
end

function Watch.GetGen()
    return tonumber(Watch._gen) or 0
end

function Watch.BumpGen()
    Watch._gen = (tonumber(Watch._gen) or 0) + 1
end

function Watch.GetCharacterKey()
    if StockPiler.Persistence and StockPiler.Persistence.GetCharacterKey then
        return StockPiler.Persistence.GetCharacterKey()
    end
    return "_default"
end

function Watch.GetWatches()
    local row = CharacterRow(true)
    if type(row) ~= "table" or type(row.watches) ~= "table" then
        return {}
    end
    return row.watches
end

local function DefaultWatch()
    return { enabled = false, targetStock = 40, autoGrow = false, priorityTier = nil }
end

--- Resolve a watch by exact store key, or by unique uid:N / uid:N|rk:... match.
--- Composite keys (uid:N|rk:...) never alias a sibling recipe for the same
--- output - Potions-tab multi-recipe rows must toggle independently.
--- Legacy plain uid:N still resolves when no composite watches exist yet.
--- Returns watch, storeKey (nil, nil when missing or ambiguous).
function Watch.ResolveWatchEntry(recipeKey)
    local key = tostring(recipeKey or "")
    if key == "" then
        return nil, nil
    end
    local watches = Watch.GetWatches()
    if type(watches) ~= "table" then
        return nil, nil
    end
    local direct = watches[key]
    if type(direct) == "table" then
        return direct, key
    end

    local RS = StockPiler.RecipeSpec
    local parsed = RS and RS.ParsePotionRecipeKey and RS.ParsePotionRecipeKey(key) or nil
    if type(parsed) == "table" and parsed.isComposite == true then
        local plain = tostring(parsed.potionKey or "")
        if plain == "" then
            return nil, nil
        end
        local prefixPipe = plain .. "|"
        for k, w in pairs(watches) do
            if type(w) == "table" and type(k) == "string"
                and string.sub(k, 1, #prefixPipe) == prefixPipe
            then
                -- Exact key missed; a composite for this output exists (sibling or
                -- scrubbed self). Do not treat sibling / plain as this recipe.
                return nil, nil
            end
        end
        local plainWatch = watches[plain]
        if type(plainWatch) == "table" then
            return plainWatch, plain
        end
        return nil, nil
    end

    local uidPrefix = string.match(key, "^(uid:%d+)$")
    if uidPrefix == nil then
        local bare = tonumber(key)
        if bare and bare > 0 then
            uidPrefix = "uid:" .. tostring(math.floor(bare))
        end
    end
    if uidPrefix == nil then
        return nil, nil
    end
    local prefixPipe = uidPrefix .. "|"
    local function scan(enabledOnly)
        local found, foundKey, n = nil, nil, 0
        for k, w in pairs(watches) do
            if type(w) == "table" and (not enabledOnly or w.enabled == true) then
                local ks = tostring(k)
                if ks == uidPrefix or string.sub(ks, 1, #prefixPipe) == prefixPipe then
                    n = n + 1
                    found, foundKey = w, ks
                end
            end
        end
        if n == 1 then
            return found, foundKey
        end
        return nil, nil
    end
    local watch, storeKey = scan(true)
    if type(watch) == "table" then
        return watch, storeKey
    end
    return scan(false)
end

--- When toggling a composite recipe key, move a legacy plain uid:N watch onto
--- that key so sibling recipes stop sharing one enabled flag.
local function MigratePlainWatchToComposite(recipeKey)
    local key = tostring(recipeKey or "")
    if key == "" then
        return
    end
    local RS = StockPiler.RecipeSpec
    local parsed = RS and RS.ParsePotionRecipeKey and RS.ParsePotionRecipeKey(key) or nil
    if type(parsed) ~= "table" or parsed.isComposite ~= true then
        return
    end
    local plain = tostring(parsed.potionKey or "")
    if plain == "" then
        return
    end
    local row = CharacterRow(true)
    if type(row) ~= "table" then
        return
    end
    if type(row.watches) ~= "table" then
        row.watches = {}
    end
    if type(row.watches[key]) == "table" then
        return
    end
    if type(row.watches[plain]) ~= "table" then
        return
    end
    local prefixPipe = plain .. "|"
    for k, w in pairs(row.watches) do
        if type(w) == "table" and type(k) == "string"
            and string.sub(k, 1, #prefixPipe) == prefixPipe
        then
            return
        end
    end
    row.watches[key] = row.watches[plain]
    row.watches[plain] = nil
    Watch.BumpGen()
end

--- Read-only watch peek (does not create SV stubs).
function Watch.GetWatch(recipeKey)
    local watch = select(1, Watch.ResolveWatchEntry(recipeKey))
    if type(watch) == "table" then
        return watch
    end
    return DefaultWatch()
end

--- Count watches with enabled==true (Clear watches / footer / priority N).
function Watch.CountEnabled()
    local watches = Watch.GetWatches()
    local n = 0
    if type(watches) ~= "table" then
        return 0
    end
    for _, watch in pairs(watches) do
        if type(watch) == "table" and watch.enabled == true then
            n = n + 1
        end
    end
    return n
end

local function MaxPriorityTier(excludeKey)
    excludeKey = excludeKey and tostring(excludeKey) or nil
    local watches = Watch.GetWatches()
    local maxTier = 0
    if type(watches) ~= "table" then
        return 0
    end
    for key, watch in pairs(watches) do
        if type(watch) == "table" and watch.enabled == true and tostring(key) ~= excludeKey then
            local t = tonumber(watch.priorityTier) or 0
            if t > maxTier then
                maxTier = t
            end
        end
    end
    return maxTier
end

--- Next unique tier for a newly enabled watch (add order).
function Watch.NextPriorityTier(excludeKey)
    return MaxPriorityTier(excludeKey) + 1
end

function Watch.GetPriorityTier(recipeKey)
    local watch = Watch.GetWatch(recipeKey)
    local n = Watch.CountEnabled()
    if n < 1 then
        n = 1
    end
    local t = tonumber(watch and watch.priorityTier)
    if t == nil or t < 1 then
        return 1
    end
    if t > n then
        return n
    end
    return math.floor(t)
end

function Watch.ClampAllPriorityTiers()
    local watches = Watch.GetWatches()
    local n = Watch.CountEnabled()
    if type(watches) ~= "table" then
        return
    end
    if n < 1 then
        n = 1
    end
    for _, watch in pairs(watches) do
        if type(watch) == "table" and watch.enabled == true then
            local t = tonumber(watch.priorityTier)
            if t == nil or t < 1 then
                watch.priorityTier = 1
            elseif t > n then
                watch.priorityTier = n
            else
                watch.priorityTier = math.floor(t)
            end
        end
    end
end

--- Remap enabled tiers to dense 1..K preserving shared groups and relative order.
function Watch.DensifyPriorityTiers()
    local watches = Watch.GetWatches()
    if type(watches) ~= "table" then
        return
    end
    local used = {}
    for _, watch in pairs(watches) do
        if type(watch) == "table" and watch.enabled == true then
            local t = tonumber(watch.priorityTier)
            if t ~= nil and t >= 1 then
                used[math.floor(t)] = true
            end
        end
    end
    local sorted = {}
    for t in pairs(used) do
        sorted[#sorted + 1] = t
    end
    table.sort(sorted)
    if #sorted == 0 then
        return
    end
    local map = {}
    for i = 1, #sorted do
        map[sorted[i]] = i
    end
    local changed = false
    for _, watch in pairs(watches) do
        if type(watch) == "table" and watch.enabled == true then
            local t = tonumber(watch.priorityTier)
            if t ~= nil and map[math.floor(t)] ~= nil then
                local neu = map[math.floor(t)]
                if watch.priorityTier ~= neu then
                    watch.priorityTier = neu
                    changed = true
                end
            end
        end
    end
    Watch.ClampAllPriorityTiers()
    if changed then
        Watch.BumpGen()
    end
end

local function WatchDisplayName(key, watch)
    local RS = StockPiler.RecipeSpec
    if RS and RS.ResolveWatchPotion then
        local resolved = RS.ResolveWatchPotion(key)
        local potion = resolved and resolved.potion
        if type(potion) == "table" and potion.name ~= nil then
            if StockPiler.Persistence and StockPiler.Persistence.ToNarrow then
                return StockPiler.Persistence.ToNarrow(potion.name)
            end
            return tostring(potion.name)
        end
    end
    return tostring(key or "")
end

--- One-shot: assign unique 1..N by name/key for legacy saves without tiers.
function Watch.MigratePriorityTiersIfNeeded()
    local row = CharacterRow(true)
    if type(row) ~= "table" then
        return false
    end
    if row.watchPriorityTiersMigrated == true then
        return false
    end
    local watches = row.watches
    if type(watches) ~= "table" then
        row.watchPriorityTiersMigrated = true
        return false
    end
    local list = {}
    for key, watch in pairs(watches) do
        if type(watch) == "table" and watch.enabled == true then
            list[#list + 1] = { key = tostring(key), watch = watch }
        end
    end
    table.sort(list, function(a, b)
        local na = WatchDisplayName(a.key, a.watch)
        local nb = WatchDisplayName(b.key, b.watch)
        if na ~= nb then
            return na < nb
        end
        return a.key < b.key
    end)
    for i = 1, #list do
        list[i].watch.priorityTier = i
    end
    row.watchPriorityTiersMigrated = true
    Watch.BumpGen()
    return true
end

function Watch.SetPriorityTier(recipeKey, tier)
    local watch = Watch.EnsureWatch(recipeKey)
    if type(watch) ~= "table" or watch.enabled ~= true then
        return watch
    end
    local n = Watch.CountEnabled()
    if n < 1 then
        n = 1
    end
    tier = tonumber(tier)
    if tier == nil then
        return watch
    end
    tier = math.floor(tier)
    if tier < 1 then
        tier = 1
    elseif tier > n then
        tier = n
    end
    watch.priorityTier = tier
    -- Soft: priority does not change craftable/demand structure. Callers patch UI
    -- / focus caches. SetPriorityTier does not BumpGen (that forces BuildFull via
    -- StructuralNonRefineKey). SetTarget and SetEnabled still bump generation.
    return watch
end

function Watch.BumpPriorityTier(recipeKey, delta)
    delta = tonumber(delta) or 0
    if delta == 0 then
        return Watch.GetWatch(recipeKey)
    end
    local cur = Watch.GetPriorityTier(recipeKey)
    return Watch.SetPriorityTier(recipeKey, cur + delta)
end

--- Remove disabled watch rows that still look like EnsureWatch defaults
--- (from Potions list creating SV stubs). Keeps unchecked watches with custom target/autoGrow.
function Watch.ScrubPristineDisabledStubs()
    local row = CharacterRow(false)
    if type(row) ~= "table" or type(row.watches) ~= "table" then
        return 0
    end
    local n = 0
    for key, watch in pairs(row.watches) do
        if type(watch) == "table"
            and watch.enabled ~= true
            and (tonumber(watch.targetStock) or 40) == 40
            and watch.autoGrow ~= true
        then
            row.watches[key] = nil
            n = n + 1
        end
    end
    if n > 0 then
        Watch.BumpGen()
    end
    return n
end

--- Ensure watch row. Defaults: enabled=false, targetStock=40, autoGrow=false.
--- When opts.fromPotionsToggle (or opts.autoGrow=true), new rows get autoGrow=true.
function Watch.EnsureWatch(recipeKey, opts)
    opts = type(opts) == "table" and opts or {}
    local key = tostring(recipeKey or "")
    local defaultAutoGrow = false
    if opts.fromPotionsToggle == true or opts.autoGrow == true then
        defaultAutoGrow = true
    end
    if key == "" then
        return { enabled = false, targetStock = 40, autoGrow = defaultAutoGrow }
    end
    local row = CharacterRow(true)
    if type(row) ~= "table" then
        return { enabled = false, targetStock = 40, autoGrow = defaultAutoGrow }
    end
    if type(row.watches) ~= "table" then
        row.watches = {}
    end
    local watch = row.watches[key]
    if type(watch) ~= "table" then
        watch = {
            enabled = false,
            targetStock = 40,
            autoGrow = defaultAutoGrow,
        }
        row.watches[key] = watch
        Watch.BumpGen()
    end
    if watch.targetStock == nil then
        watch.targetStock = 40
    end
    if watch.autoGrow == nil then
        watch.autoGrow = defaultAutoGrow
    end
    if watch.enabled == nil then
        watch.enabled = false
    end
    return watch
end

function Watch.SetTarget(recipeKey, targetStock)
    MigratePlainWatchToComposite(recipeKey)
    local watch = Watch.EnsureWatch(recipeKey)
    targetStock = tonumber(targetStock)
    if targetStock == nil then
        return watch
    end
    if targetStock < 0 then
        targetStock = 0
    end
    watch.targetStock = math.floor(targetStock)
    Watch.BumpGen()
    return watch
end

function Watch.SetAutoGrow(recipeKey, enabled)
    MigratePlainWatchToComposite(recipeKey)
    -- Prefer an existing store row (uid fallback) so toggles do not orphan a new key.
    local watch, storeKey = Watch.ResolveWatchEntry(recipeKey)
    if type(watch) ~= "table" then
        watch = Watch.EnsureWatch(recipeKey)
    elseif storeKey ~= nil and storeKey ~= tostring(recipeKey or "") then
        -- keep mutating the resolved store entry
    end
    watch.autoGrow = enabled == true
    Watch.BumpGen()
    return watch
end

local function SkillsReady()
    local Caps = StockPiler.TradeSkillCaps
    if Caps and Caps.AreTradeSkillsReady then
        return Caps.AreTradeSkillsReady() == true
    end
    return (Caps and Caps.GetApoSkill and Caps.GetApoSkill() or 0) > 0
        or (Caps and Caps.GetCultSkill and Caps.GetCultSkill() or 0) > 0
end

local function NotifySkillBlocked(kind, need, have)
    local key = kind == "cult" and "watch.need_cult_skill" or "watch.need_apo_skill"
    local msg = nil
    if StockPiler.T then
        msg = StockPiler.T(key, {
            need = tostring(need or 0),
            have = tostring(have or 0),
        })
    end
    if msg == nil then
        msg = L"Need higher crafting skill."
    end
    if StockPiler.Ui and StockPiler.Ui.Print then
        StockPiler.Ui.Print(msg)
    elseif StockPiler.Debug and StockPiler.Debug.Print then
        StockPiler.Debug.Print(msg)
    end
end

--- Apo skill required to craft this potion watch (0 if unknown).
function Watch.PotionSkillNeed(recipeKey)
    local RS = StockPiler.RecipeSpec
    if not RS then
        return 0
    end
    local recipe = nil
    if RS.RecipeSpecForPotion then
        recipe = RS.RecipeSpecForPotion(recipeKey)
    end
    if type(recipe) ~= "table" and RS.ResolveWatchPotion then
        local resolved = RS.ResolveWatchPotion(recipeKey)
        if type(resolved) == "table" and resolved.recipeSpecKey and RS.GetRecipe then
            recipe = RS.GetRecipe(resolved.recipeSpecKey)
            if type(recipe) == "table" and (tonumber(resolved.outputUid) or 0) > 0 then
                recipe.outputUid = resolved.outputUid
            end
        end
    end
    if RS.RecipeSkillRequirements then
        local req = RS.RecipeSkillRequirements(recipe)
        if type(req) == "table" then
            local need = tonumber(req.apothecary) or tonumber(req.apo) or 0
            if need > 0 then
                return need
            end
        end
    end
    if RS.ResolveWatchPotion then
        local resolved = RS.ResolveWatchPotion(recipeKey)
        local uid = type(resolved) == "table" and (tonumber(resolved.outputUid) or 0) or 0
        if uid > 0 and StockPiler.Items and StockPiler.Items.GetByUid then
            local row = StockPiler.Items.GetByUid(uid)
            if type(row) == "table" then
                return tonumber(row.skillReq) or tonumber(row.skillLevel)
                    or tonumber(row.craftingSkillRequirement) or 0
            end
        end
    end
    return 0
end

--- Cult skill required to grow this plant watch (0 if unknown).
function Watch.PlantSkillNeed(plantKey)
    local uid = Watch.ParsePlantKey(plantKey)
    if uid <= 0 then
        return 0
    end
    if StockPiler.Items and StockPiler.Items.GetByUid then
        local row = StockPiler.Items.GetByUid(uid)
        if type(row) == "table" then
            local need = tonumber(row.skillReq) or tonumber(row.skillLevel)
                or tonumber(row.craftingSkillRequirement) or 0
            if need > 0 then
                return need
            end
        end
    end
    if StockPiler.Items and StockPiler.Items.ToSpec then
        local spec = StockPiler.Items.ToSpec(uid)
        if type(spec) == "table" then
            return tonumber(spec.skillLevel) or tonumber(spec.craftingSkillRequirement)
                or tonumber(spec.skillReq) or 0
        end
    end
    return 0
end

--- True when potion watch may be enabled at current Apo skill.
--- Returns ok, need, have. When skills are not ready yet, returns true (defer).
--- Apo=0 while Cult already loaded is treated as not-ready (login race); never
--- treat a missing Apo reading as "player has 0 Apo".
function Watch.CanEnablePotionWatch(recipeKey)
    if not SkillsReady() then
        return true, 0, 0
    end
    local need = Watch.PotionSkillNeed(recipeKey)
    if need <= 0 then
        return true, 0, 0
    end
    local Caps = StockPiler.TradeSkillCaps
    local have = Caps and Caps.GetApoSkill and tonumber(Caps.GetApoSkill()) or 0
    if have <= 0 then
        return true, need, have
    end
    if have < need then
        return false, need, have
    end
    return true, need, have
end

--- True when plant watch may be enabled at current Cult skill.
--- Cult=0 is treated as not-ready (same login-race defer as Apo).
function Watch.CanEnablePlantWatch(plantKey)
    if not SkillsReady() then
        return true, 0, 0
    end
    local need = Watch.PlantSkillNeed(plantKey)
    if need <= 0 then
        return true, 0, 0
    end
    local Caps = StockPiler.TradeSkillCaps
    local have = Caps and Caps.GetCultSkill and tonumber(Caps.GetCultSkill()) or 0
    if have <= 0 then
        return true, need, have
    end
    if have < need then
        return false, need, have
    end
    return true, need, have
end

--- Disable enabled watches whose craft/grow skill exceeds current levels.
--- opts.notify == true prints a one-line summary when any were disabled.
--- Returns count disabled.
--- Never persists disables while Apo/Cult still read as 0 (partial skill update).
function Watch.DisableOverSkillWatches(opts)
    opts = type(opts) == "table" and opts or {}
    if not SkillsReady() then
        return 0
    end
    local Caps = StockPiler.TradeSkillCaps
    local apoHave = Caps and Caps.GetApoSkill and tonumber(Caps.GetApoSkill()) or 0
    local cultHave = Caps and Caps.GetCultSkill and tonumber(Caps.GetCultSkill()) or 0
    local disabledN = 0
    local watches = Watch.GetWatches and Watch.GetWatches() or nil
    if type(watches) == "table" and apoHave > 0 then
        for key, watch in pairs(watches) do
            if type(watch) == "table" and watch.enabled == true then
                local ok = Watch.CanEnablePotionWatch(key)
                if ok ~= true then
                    watch.enabled = false
                    disabledN = disabledN + 1
                end
            end
        end
    end
    local plants = Watch.GetPlantWatches and Watch.GetPlantWatches() or nil
    if type(plants) == "table" and cultHave > 0 then
        for key, watch in pairs(plants) do
            if type(watch) == "table" and watch.enabled == true then
                local ok = Watch.CanEnablePlantWatch(key)
                if ok ~= true then
                    watch.enabled = false
                    disabledN = disabledN + 1
                end
            end
        end
    end
    if disabledN > 0 then
        Watch.DensifyPriorityTiers()
        Watch.ClampAllPriorityTiers()
        Watch.BumpGen()
        if opts.notify == true then
            local msg = nil
            if StockPiler.T then
                msg = StockPiler.T("watch.disabled_over_skill", { count = tostring(disabledN) })
            end
            if msg == nil then
                msg = L"Disabled watches above your crafting skill."
            end
            if StockPiler.Ui and StockPiler.Ui.Print then
                StockPiler.Ui.Print(msg)
            elseif StockPiler.Debug and StockPiler.Debug.Print then
                StockPiler.Debug.Print(msg)
            end
        end
        if StockPiler.PlanSnapshot and StockPiler.PlanSnapshot.Invalidate then
            StockPiler.PlanSnapshot.Invalidate()
        end
    end
    return disabledN
end

function Watch.SetEnabled(recipeKey, enabled, opts)
    opts = type(opts) == "table" and opts or {}
    if enabled == true and opts.fromPotionsToggle == true then
        opts.autoGrow = true
    end
    MigratePlainWatchToComposite(recipeKey)
    local watch = Watch.EnsureWatch(recipeKey, opts)
    local wasEnabled = watch.enabled == true
    if enabled == true then
        local ok, need, have = Watch.CanEnablePotionWatch(recipeKey)
        if ok ~= true then
            watch.enabled = false
            if opts.silent ~= true then
                NotifySkillBlocked("apo", need, have)
            end
            if wasEnabled then
                Watch.DensifyPriorityTiers()
                Watch.ClampAllPriorityTiers()
                Watch.BumpGen()
            end
            return watch, false, { reason = "need_skill", skill = "apo", need = need, have = have }
        end
    end
    watch.enabled = enabled == true
    if enabled == true and opts.fromPotionsToggle == true then
        watch.autoGrow = true
    end
    if enabled == true then
        if not wasEnabled or tonumber(watch.priorityTier) == nil then
            watch.priorityTier = Watch.NextPriorityTier(recipeKey)
        end
        Watch.ClampAllPriorityTiers()
    else
        if wasEnabled then
            Watch.DensifyPriorityTiers()
            Watch.ClampAllPriorityTiers()
        end
    end
    Watch.BumpGen()
    return watch, true
end

function Watch.ClearAll()
    local row = CharacterRow(true)
    local enabledN = 0
    if type(row) == "table" and type(row.watches) == "table" then
        for _, watch in pairs(row.watches) do
            if type(watch) == "table" and watch.enabled == true then
                enabledN = enabledN + 1
            end
        end
        -- Drop enabled watches and disabled list stubs alike.
        row.watches = {}
    end
    Watch.BumpGen()
    if StockPiler.PlanSnapshot and StockPiler.PlanSnapshot.Invalidate then
        StockPiler.PlanSnapshot.Invalidate()
    end
    return enabledN
end

--- Drop all plant watches (enabled + disabled stubs). Returns prior enabled count.
function Watch.ClearAllPlantWatches()
    local row = CharacterRow(true)
    local enabledN = 0
    if type(row) == "table" and type(row.plantWatches) == "table" then
        for _, watch in pairs(row.plantWatches) do
            if type(watch) == "table" and watch.enabled == true then
                enabledN = enabledN + 1
            end
        end
        row.plantWatches = {}
    end
    Watch.BumpGen()
    if StockPiler.PlanSnapshot and StockPiler.PlanSnapshot.Invalidate then
        StockPiler.PlanSnapshot.Invalidate()
    end
    return enabledN
end

function Watch.ScrubPotionRecipeWatch(outputUid, recipeSpecKey)
    outputUid = tonumber(outputUid) or 0
    recipeSpecKey = tostring(recipeSpecKey or "")
    local RS = StockPiler.RecipeSpec
    local watchKey = nil
    if outputUid > 0 and recipeSpecKey ~= "" and RS and RS.PotionRecipeKey then
        watchKey = RS.PotionRecipeKey(outputUid, recipeSpecKey)
    end
    local watches = Watch.GetWatches and Watch.GetWatches() or nil
    if type(watches) ~= "table" then
        return watchKey
    end
    local storeKey = nil
    if watchKey ~= nil and type(watches[watchKey]) == "table" then
        storeKey = watchKey
    elseif Watch.ResolveWatchEntry then
        local _, resolvedKey = Watch.ResolveWatchEntry(watchKey or ("uid:" .. tostring(outputUid)))
        if resolvedKey ~= nil and type(watches[resolvedKey]) == "table" then
            storeKey = resolvedKey
            watchKey = resolvedKey
        end
    end
    if storeKey ~= nil then
        watches[storeKey] = nil
        if Watch.BumpGen then
            Watch.BumpGen()
        end
    end
    return watchKey or storeKey
end

function Watch.SetCharacterField(name, value)
    if CHARACTER_FIELDS[name] ~= true then
        return false
    end
    local row = CharacterRow(true)
    if type(row) ~= "table" then
        return false
    end
    row[name] = value
    -- SettingsHash reads these fields. Drop the plan-key memo on the write so
    -- a same-tick lookup does not keep the previous hash.
    local Planner = StockPiler.Planner
    if Planner and Planner.InvalidateSettingsHashMemo then
        Planner.InvalidateSettingsHashMemo()
    end
    return true
end

function Watch.IsAutoGrowEnabled()
    local Caps = StockPiler.TradeSkillCaps
    if Caps and Caps.CanAutoGrow and Caps.CanAutoGrow() ~= true then
        return false
    end
    local row = CharacterRow(false)
    return type(row) == "table" and row.autoGrowEnabled == true
end

--- True when master AutoGrow is on and at least one enabled watch has AutoGrow.
function Watch.HasAnyAutoGrow()
    if Watch.IsAutoGrowEnabled() ~= true then
        return false
    end
    local Caps = StockPiler.TradeSkillCaps
    if Caps and Caps.CanAutoGrow and Caps.CanAutoGrow() ~= true then
        return false
    end
    local watches = Watch.GetWatches()
    if type(watches) == "table" then
        for _, watch in pairs(watches) do
            if type(watch) == "table" and watch.enabled == true and watch.autoGrow == true then
                return true
            end
        end
    end
    -- Plant watches have no per-row autoGrow flag; an enabled plant watch is AutoGrow.
    if Watch.CountEnabledPlantWatches and Watch.CountEnabledPlantWatches() > 0 then
        return true
    end
    return false
end

function Watch.IsAutoGrowAdditivesEnabled()
    local row = CharacterRow(false)
    return type(row) == "table" and row.autoGrowAdditives == true
end

function Watch.IsSeedBufferEnabled()
    local Caps = StockPiler.TradeSkillCaps
    if not (Caps and Caps.CanAutoGrow and Caps.CanAutoGrow() == true) then
        return false
    end
    local row = CharacterRow(false)
    if type(row) ~= "table" then
        return true
    end
    return row.growSeedBufferEnabled ~= false
end

function Watch.GetSeedBufferMin()
    local row = CharacterRow(false)
    local n = type(row) == "table" and tonumber(row.growSeedBufferMin) or nil
    if n == nil or n < 0 then
        return 5
    end
    return math.floor(n)
end

function Watch.IsAutoGrowPauseCombat()
    local row = CharacterRow(false)
    if type(row) ~= "table" then
        return false
    end
    return row.autoGrowPauseCombat == true
end

-- Alias used by Scheduler.ShouldDeferAutoGrowPlant
function Watch.IsCombatPauseEnabled()
    return Watch.IsAutoGrowPauseCombat()
end

--- When true (default), craftable / AutoGrow assume each brew is the watched potion
--- and each harvest yields a plant. When false, scale brew craftable by potion drop
--- rate (min 5 brews) and plantings by harvest success (min 5 harvests).
function Watch.IsOptimisticOutcomeEstimate()
    local row = CharacterRow(false)
    if type(row) ~= "table" then
        return true
    end
    return row.watchOptimisticOutcomeEstimate ~= false
end

function Watch.IsAutoBuyEnabled()
    local row = CharacterRow(false)
    return type(row) == "table" and row.autoBuyEnabled == true
end

--- Master AutoBrew: auto-perform Ready watches to target (load already silent).
function Watch.IsAutoBrewEnabled()
    local Caps = StockPiler.TradeSkillCaps
    if Caps and Caps.CanBrewPotions and Caps.CanBrewPotions() ~= true then
        return false
    end
    local row = CharacterRow(false)
    return type(row) == "table" and row.autoBrewEnabled == true
end

function Watch.GetAutoBuyReserveGold()
    local row = CharacterRow(false)
    local n = type(row) == "table" and tonumber(row.autoBuyReserveGold) or nil
    if n == nil or n < 1 then
        return 10
    end
    if n > 99 then
        return 99
    end
    return math.floor(n)
end

function Watch.GetAutoBuyBudgetGold()
    local row = CharacterRow(false)
    local n = type(row) == "table" and tonumber(row.autoBuyBudgetGold) or nil
    if n == nil or n < 1 then
        return 50
    end
    if n > 999 then
        return 999
    end
    return math.floor(n)
end

--- Lifetime AutoBuy spend (brass) against autoBuyBudgetGold until manual reset.
function Watch.GetAutoBuySpentBrass()
    local row = CharacterRow(false)
    local n = type(row) == "table" and tonumber(row.autoBuySpentBrass) or nil
    if n == nil or n < 0 then
        return 0
    end
    return math.floor(n)
end

function Watch.AddAutoBuySpentBrass(delta)
    delta = tonumber(delta) or 0
    if delta <= 0 then
        return Watch.GetAutoBuySpentBrass()
    end
    local row = CharacterRow(true)
    if type(row) ~= "table" then
        return Watch.GetAutoBuySpentBrass()
    end
    local nextVal = (tonumber(row.autoBuySpentBrass) or 0) + math.floor(delta)
    if nextVal < 0 then
        nextVal = 0
    end
    row.autoBuySpentBrass = nextVal
    return nextVal
end

function Watch.ResetAutoBuySpentBrass()
    local row = CharacterRow(true)
    if type(row) ~= "table" then
        return 0
    end
    row.autoBuySpentBrass = 0
    return 0
end

----------------------------------------------------------------
-- Plant watches (material stock floors; always below potion priority)
----------------------------------------------------------------

function Watch.PlantKeyFromUid(plantUid)
    plantUid = tonumber(plantUid) or 0
    if plantUid <= 0 then
        return ""
    end
    return "plant:" .. tostring(plantUid)
end

function Watch.ParsePlantKey(key)
    key = tostring(key or "")
    local uid = key:match("^plant:(%d+)$")
    if uid then
        return tonumber(uid) or 0
    end
    return 0
end

function Watch.GetPlantWatches()
    local row = CharacterRow(true)
    if type(row) ~= "table" then
        return {}
    end
    if type(row.plantWatches) ~= "table" then
        row.plantWatches = {}
    end
    return row.plantWatches
end

local function DefaultPlantWatch()
    return { enabled = false, targetStock = 40, autoGrow = true }
end

function Watch.GetPlantWatch(plantKey)
    local key = tostring(plantKey or "")
    if key == "" then
        return DefaultPlantWatch()
    end
    local row = CharacterRow(false)
    if type(row) ~= "table" or type(row.plantWatches) ~= "table" then
        return DefaultPlantWatch()
    end
    local watch = row.plantWatches[key]
    if type(watch) ~= "table" then
        return DefaultPlantWatch()
    end
    return watch
end

function Watch.EnsurePlantWatch(plantKey, opts)
    opts = type(opts) == "table" and opts or {}
    local key = tostring(plantKey or "")
    if key == "" then
        return DefaultPlantWatch()
    end
    local row = CharacterRow(true)
    if type(row) ~= "table" then
        return DefaultPlantWatch()
    end
    if type(row.plantWatches) ~= "table" then
        row.plantWatches = {}
    end
    local watch = row.plantWatches[key]
    if type(watch) ~= "table" then
        watch = {
            enabled = false,
            targetStock = 40,
            autoGrow = true,
        }
        row.plantWatches[key] = watch
        Watch.BumpGen()
    end
    if watch.targetStock == nil then
        watch.targetStock = 40
    end
    if watch.autoGrow == nil then
        watch.autoGrow = true
    end
    if watch.enabled == nil then
        watch.enabled = false
    end
    if opts.fromPlantsToggle == true then
        watch.autoGrow = true
    end
    return watch
end

function Watch.SetPlantTarget(plantKey, targetStock)
    local watch = Watch.EnsurePlantWatch(plantKey)
    targetStock = tonumber(targetStock)
    if targetStock == nil then
        return watch
    end
    if targetStock < 0 then
        targetStock = 0
    end
    watch.targetStock = math.floor(targetStock)
    Watch.BumpGen()
    return watch
end

function Watch.SetPlantEnabled(plantKey, enabled, opts)
    opts = type(opts) == "table" and opts or {}
    local watch = Watch.EnsurePlantWatch(plantKey, opts)
    if enabled == true then
        local ok, need, have = Watch.CanEnablePlantWatch(plantKey)
        if ok ~= true then
            watch.enabled = false
            if opts.silent ~= true then
                NotifySkillBlocked("cult", need, have)
            end
            return watch, false, { reason = "need_skill", skill = "cult", need = need, have = have }
        end
        watch.autoGrow = true
    end
    watch.enabled = enabled == true
    Watch.BumpGen()
    -- Drop Upgrade Seeds targets immediately so unwatch stops that genus climb.
    local US = StockPiler.UpgradeSeed
    if US and US.InvalidateUpgradeTargetsCache then
        US.InvalidateUpgradeTargetsCache()
    end
    if enabled ~= true and US and US.ClearActive then
        US.ClearActive()
    end
    return watch, true
end

function Watch.SetPlantAutoGrow(plantKey, enabled)
    local watch = Watch.EnsurePlantWatch(plantKey)
    watch.autoGrow = enabled == true
    Watch.BumpGen()
    return watch
end

function Watch.CountEnabledPlantWatches()
    local watches = Watch.GetPlantWatches()
    local n = 0
    if type(watches) ~= "table" then
        return 0
    end
    for _, watch in pairs(watches) do
        if type(watch) == "table" and watch.enabled == true then
            n = n + 1
        end
    end
    return n
end

--- True when every enabled potion watch has have >= targetStock.
function Watch.AllEnabledPotionWatchesStocked()
    local watches = Watch.GetWatches()
    if type(watches) ~= "table" then
        return true
    end
    local RS = StockPiler.RecipeSpec
    local Catalog = StockPiler.Catalog
    for key, watch in pairs(watches) do
        if type(watch) == "table" and watch.enabled == true then
            local target = tonumber(watch.targetStock) or 40
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
            if have < target then
                return false
            end
        end
    end
    return true
end

--- Soft plant_stock gate: true when an enabled potion watch still needs Cultivation.
--- With a plan: only Cult statuses (restocking / need_seeds / upgrading_seed /
--- ready_to_craft_shared). Buy materials and Ready to brew do not count.
--- With no plan: fall back to bag-vs-target (AllEnabledPotionWatchesStocked).
function Watch.EnabledPotionWatchesNeedCultGrow(rows)
    local CULT = {
        restocking = true,
        need_seeds = true,
        upgrading_seed = true,
        -- Craftable covers the bottle gap, but AutoBrew will not claim contested
        -- mats; Cult still needs to grow (or buy) until the contest clears.
        ready_to_craft_shared = true,
    }
    if type(rows) ~= "table" or #rows == 0 then
        local PS = StockPiler.PlanSnapshot
        local plan = PS and PS.Get and PS.Get()
        rows = plan and plan.rows
    end
    if type(rows) == "table" and #rows > 0 then
        for i = 1, #rows do
            local row = rows[i]
            if type(row) == "table"
                and row.skillUp ~= true
                and row.kind ~= "plant"
                and row.isPlantWatch ~= true
                and (tonumber(row.potionDeficit) or 0) > 0
            then
                local key = tostring(row.statusKey or "")
                if CULT[key] then
                    return true
                end
            end
        end
        return false
    end
    return Watch.AllEnabledPotionWatchesStocked() ~= true
end

function Watch.ShouldAutoGrowPlant(plantKey)
    if Watch.IsAutoGrowEnabled() ~= true then
        return false
    end
    local watch = Watch.GetPlantWatch(plantKey)
    return type(watch) == "table" and watch.enabled == true and watch.autoGrow ~= false
end

--- Enabled watches still short of target (potion + plant). Used by Craft tip when
--- master AutoGrow is off. Prefer PlanSnapshot deficit; fall back to bag counts.
--- Each entry: { name = wstring, perWatchOff = bool, kind = "potion"|"plant" }.
function Watch.CollectShortEnabledWatches()
    local list = {}
    local PS = StockPiler.PlanSnapshot
    local plan = PS and PS.Get and PS.Get()
    local rows = plan and plan.rows
    if type(rows) == "table" and #rows > 0 then
        for i = 1, #rows do
            local row = rows[i]
            if type(row) == "table"
                and row.skillUp ~= true
                and (tonumber(row.potionDeficit) or 0) > 0
            then
                local kind = "potion"
                if row.kind == "plant" or row.isPlantWatch == true then
                    kind = "plant"
                end
                list[#list + 1] = {
                    name = row.name,
                    perWatchOff = row.autoGrow ~= true,
                    kind = kind,
                }
            end
        end
        return list
    end

    local RS = StockPiler.RecipeSpec
    local Catalog = StockPiler.Catalog
    local Inv = StockPiler.Inventory
    local watches = Watch.GetWatches()
    if type(watches) == "table" then
        for key, watch in pairs(watches) do
            if type(watch) == "table" and watch.enabled == true then
                local target = tonumber(watch.targetStock) or 40
                local have = 0
                if RS and RS.ResolveWatchPotion then
                    local resolved = RS.ResolveWatchPotion(key)
                    local potion = resolved and resolved.potion
                    if type(potion) == "table" and Catalog and Catalog.PotionHaveCombined then
                        have = tonumber(Catalog.PotionHaveCombined(potion)) or 0
                    elseif resolved and resolved.outputUid and Inv and Inv.CountByUid then
                        have = tonumber(Inv.CountByUid(resolved.outputUid)) or 0
                    end
                end
                if have < target then
                    local name = nil
                    if RS and RS.ResolveWatchPotion then
                        local resolved = RS.ResolveWatchPotion(key)
                        local potion = resolved and resolved.potion
                        if type(potion) == "table" then
                            name = potion.name
                        end
                    end
                    list[#list + 1] = {
                        name = name,
                        perWatchOff = watch.autoGrow ~= true,
                        kind = "potion",
                    }
                end
            end
        end
    end

    local plants = Watch.GetPlantWatches and Watch.GetPlantWatches() or nil
    if type(plants) == "table" then
        for plantKey, watch in pairs(plants) do
            if type(watch) == "table" and watch.enabled == true then
                local target = tonumber(watch.targetStock) or 40
                local plantUid = tonumber(plantKey) or 0
                if plantUid <= 0 and type(plantKey) == "string" then
                    plantUid = tonumber((tostring(plantKey)):match("(%d+)")) or 0
                end
                local have = 0
                if plantUid > 0 then
                    if Catalog and Catalog.PlantHave then
                        have = tonumber(Catalog.PlantHave(plantUid)) or 0
                    elseif Inv and Inv.CountByUid then
                        have = tonumber(Inv.CountByUid(plantUid)) or 0
                    end
                end
                if have < target then
                    local name = nil
                    if plantUid > 0 and Inv and Inv.GetSample then
                        local sample = Inv.GetSample(plantUid)
                        if type(sample) == "table" then
                            name = sample.name
                        end
                    end
                    list[#list + 1] = {
                        name = name,
                        perWatchOff = watch.autoGrow ~= true,
                        kind = "plant",
                    }
                end
            end
        end
    end
    return list
end
