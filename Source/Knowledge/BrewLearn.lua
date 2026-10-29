----------------------------------------------------------------
-- StockPiler Knowledge/BrewLearn - capture apo board -> StoreLearnedRecipeSpec
----------------------------------------------------------------

StockPiler = StockPiler or {}
StockPiler.BrewLearn = StockPiler.BrewLearn or {}
local BL = StockPiler.BrewLearn

BL.CraftBonus = {
    STABILITY = 1,
    POWER = 2,
    DURATION = 3,
    MULTIPLIER = 4,
    CRAFTING_FAMILY = 5,
    EFFECT = 6,
    TYPE = 8,
    CRITICAL_CHANCE = 12,
    FAIL_CHANCE = 13,
    SPECIAL_CHANCE = 14,
}

BL._pendingCraft = nil

local function ToNarrow(value)
    return StockPiler.Util.ToNarrow(value)
end

local function IsPotionType(itemData)
    if type(itemData) ~= "table" then
        return false
    end
    if GameData and GameData.ItemTypes and GameData.ItemTypes.POTION then
        return (itemData.type or itemData.itemType) == GameData.ItemTypes.POTION
    end
    return tonumber(itemData.type) == 31
end

-- Potion-ness does not change between the before and after bag snapshots.
local potionKindByUid = {}

local function IsFinishedPotionItem(itemData)
    local uid = tonumber(itemData and itemData.uniqueID) or 0
    if uid > 0 and potionKindByUid[uid] ~= nil then
        return potionKindByUid[uid] == true
    end
    local ok = IsPotionType(itemData) == true
    if uid > 0 then
        potionKindByUid[uid] = ok
    end
    return ok
end

local function StackSize(item)
    local n = tonumber(item.stackCount) or tonumber(item.Count) or 0
    if n < 1 then
        return 1
    end
    return n
end

local function MatResourceRole(resourceType, slotNum)
    resourceType = tonumber(resourceType) or 0
    if GameData and GameData.CraftingItemType then
        local cit = GameData.CraftingItemType
        if resourceType == cit.CONTAINER or resourceType == cit.CONTAINER_DYE then
            return "container"
        end
        if resourceType == cit.MAIN_INGREDIENT or resourceType == cit.PIGMENT then
            return "main"
        end
        if resourceType == cit.STABILIZER or resourceType == cit.GOLDWEED then
            return "stabilizer"
        end
        if resourceType == cit.EXTENDER then
            return "extender"
        end
        if resourceType == cit.MULTIPLIER then
            return "multiplier"
        end
        if resourceType == cit.STIMULANT then
            return "stimulant"
        end
    end
    if slotNum == 0 then
        return "container"
    end
    if slotNum == 1 then
        return "main"
    end
    return "ingredient"
end

local function AggregateMaterials(slots)
    local byKey = {}
    local list = {}
    if type(slots) ~= "table" then
        return list
    end
    for i = 1, #slots do
        local m = slots[i]
        if type(m) == "table" then
            local uid = tonumber(m.uniqueID) or 0
            if uid > 0 then
                local key = tostring(uid) .. ":" .. tostring(m.role or "ingredient")
                local row = byKey[key]
                if row == nil then
                    row = {
                        uniqueID = uid,
                        role = m.role or "ingredient",
                        perCraft = 0,
                        itemData = m.itemData,
                        name = m.name,
                        nameNarrow = m.nameNarrow,
                        iconNum = m.iconNum,
                    }
                    byKey[key] = row
                    list[#list + 1] = row
                end
                row.perCraft = (tonumber(row.perCraft) or 0) + (tonumber(m.perCraft) or 1)
            end
        end
    end
    return list
end

--- Materials rebuilt from a saved recipe - never invent a board-only fingerprint.
local function MaterialsFromSavedRecipe(recipe)
    local list = {}
    if type(recipe) ~= "table" or type(recipe.slots) ~= "table" then
        return list
    end
    local RS = StockPiler.RecipeSpec
    if RS and RS.HydrateRecipeSlots then
        RS.HydrateRecipeSlots(recipe)
    end
    for i = 1, #recipe.slots do
        local slot = recipe.slots[i]
        if type(slot) == "table" then
            local spec = slot.spec
            if type(spec) ~= "table" and RS and RS.ResolveSlotSpec then
                spec = RS.ResolveSlotSpec(slot)
            end
            local uid = tonumber(slot.uniqueID) or tonumber(slot.uid) or 0
            if uid <= 0 and type(spec) == "table" then
                uid = tonumber(spec.uid) or tonumber(spec.uniqueID) or tonumber(spec.boundUid) or 0
            end
            if uid > 0 then
                list[#list + 1] = {
                    uniqueID = uid,
                    role = tostring(slot.role or slot.materialRole or "ingredient"),
                    perCraft = math.max(1, tonumber(slot.perCraft) or 1),
                    itemData = spec,
                    name = slot.name or (spec and spec.name),
                }
            end
        end
    end
    return AggregateMaterials(list)
end

local function SnapshotPotionCounts()
    local counts = {}
    local function addItem(item)
        if IsFinishedPotionItem(item) ~= true then
            return
        end
        local uid = tonumber(item.uniqueID) or 0
        if uid > 0 then
            counts[uid] = (counts[uid] or 0) + StackSize(item)
        end
    end
    local Inv = StockPiler.Inventory
    local ready = not (Inv and Inv.IsReady) or Inv.IsReady() == true
    if ready and Inv and Inv.ForEachItem then
        Inv.ForEachItem(addItem)
        return counts
    end
    local BA = StockPiler.BagAdapter
    if BA and BA.FetchLight and BA.IterateSlots then
        local bags = BA.FetchLight()
        if type(bags) == "table" then
            for i = 1, #bags do
                BA.IterateSlots(bags[i], function(_, _, item)
                    addItem(item)
                end)
            end
            return counts
        end
    end
    if Inv and Inv.ForEachItem then
        Inv.ForEachItem(addItem)
    end
    return counts
end

local function DiffPotionOutputs(before, after)
    local outputs = {}
    after = type(after) == "table" and after or {}
    before = type(before) == "table" and before or {}
    local seen = {}
    for uid, count in pairs(after) do
        uid = tonumber(uid) or 0
        count = tonumber(count) or 0
        local prev = tonumber(before[uid]) or 0
        local delta = count - prev
        if uid > 0 and delta > 0 then
            seen[uid] = true
            local sample = nil
            if StockPiler.Inventory and StockPiler.Inventory.GetSample then
                sample = StockPiler.Inventory.GetSample(uid)
            end
            outputs[#outputs + 1] = {
                uniqueID = uid,
                lastDelta = delta,
                crafts = delta,
                name = sample and sample.name,
                nameNarrow = ToNarrow(sample and sample.name),
                iconNum = sample and tonumber(sample.iconNum) or 0,
                itemData = sample,
            }
        end
    end
    return outputs
end

function BL.CaptureApothecaryMaterials()
    local AA = StockPiler.ApothecaryAdapter
    local board = nil
    if AA and AA.ReadBoard then
        board = AA.ReadBoard()
    end
    if type(board) ~= "table" and type(ApothecaryWindow) == "table"
        and type(ApothecaryWindow.craftingData) == "table"
    then
        board = {}
        for slotNum = 0, 4 do
            local cd = ApothecaryWindow.craftingData[slotNum]
            if type(cd) == "table" and (tonumber(cd.objectId) or 0) > 0 then
                local itemData = nil
                if AA and AA.GetSlottedItem then
                    itemData = AA.GetSlottedItem(slotNum)
                end
                board[slotNum] = itemData or {
                    uniqueID = tonumber(cd.objectId) or 0,
                    iconNum = tonumber(cd.iconId) or 0,
                }
            end
        end
    end
    if type(board) ~= "table" then
        return nil
    end

    local slots = {}
    for slotNum = 0, 4 do
        local item = board[slotNum]
        if type(item) == "table" then
            local uid = tonumber(item.uniqueID) or 0
            if uid > 0 then
                local resourceType = 0
                if CraftingSystem and type(CraftingSystem.GetCraftingData) == "function" then
                    local ok, _, rt = pcall(CraftingSystem.GetCraftingData, item)
                    if ok then
                        resourceType = tonumber(rt) or 0
                    end
                end
                local role = MatResourceRole(resourceType, slotNum)
                slots[#slots + 1] = {
                    slot = slotNum,
                    uniqueID = uid,
                    role = role,
                    perCraft = 1,
                    itemData = item,
                    name = item.name,
                    nameNarrow = ToNarrow(item.name),
                    iconNum = tonumber(item.iconNum) or 0,
                }
                if StockPiler.Items and StockPiler.Items.StoreItem then
                    StockPiler.Items.StoreItem(item, "mat")
                end
            end
        end
    end
    if #slots == 0 then
        return nil
    end
    return slots
end

local BOARD_SNAPSHOT_TTL_SEC = 45

local function NowSec()
    return StockPiler.Util and StockPiler.Util.NowSec and StockPiler.Util.NowSec() or 0
end

local function LatchSuccessChance()
    local AA = StockPiler.ApothecaryAdapter
    if AA and AA.SuccessChance then
        return tonumber(AA.SuccessChance()) or -1
    end
    return -1
end

--- Engine truth: only HIGH/MEDIUM boards can succeed (LOW = definite fail, INVALID = incomplete).
local function SuccessChanceAllowsLearn(chance)
    local CSC = GameData and GameData.CraftingSuccessChance
    if type(CSC) ~= "table" then
        return true
    end
    chance = tonumber(chance)
    if chance == nil or chance < 0 then
        return true
    end
    return chance == CSC.HIGH or chance == CSC.MEDIUM
end

local function LatchSkillUpOrigin()
    local Brew = StockPiler.Brew
    local session = Brew and Brew.GetSession and Brew.GetSession() or nil
    if type(session) == "table" and session.skillUp == true then
        return true
    end
    if type(session) == "table"
        and type(session.recipe) == "table"
        and session.recipe.skillUpOrigin == true
    then
        return true
    end
    return false
end

--- Prefer the loaded brew-session recipe over a thin board snapshot.
--- Returns materials, recipeKey, skillUpOrigin (or nil materials when unavailable).
local function SessionRecipeLatch()
    local Brew = StockPiler.Brew
    local session = Brew and Brew.GetSession and Brew.GetSession() or nil
    if type(session) ~= "table" or type(session.recipe) ~= "table" then
        return nil, nil, false
    end
    local materials = MaterialsFromSavedRecipe(session.recipe)
    if type(materials) ~= "table" or #materials == 0 then
        return nil, nil, false
    end
    local recipeKey = tostring(session.recipeSpecKey or "")
    if recipeKey == "" and StockPiler.RecipeSpec and StockPiler.RecipeSpec.RecipeSpecKey then
        recipeKey = tostring(StockPiler.RecipeSpec.RecipeSpecKey(materials) or "")
    end
    local skillUp = session.skillUp == true
        or (type(session.recipe) == "table" and session.recipe.skillUpOrigin == true)
    return materials, recipeKey, skillUp
end

local function MaterialsStability(materials)
    local RS = StockPiler.RecipeSpec
    if not (RS and RS.MaterialsToSpecSlots and RS.SpecStabilityTotal) then
        return 0
    end
    local slots = RS.MaterialsToSpecSlots(materials)
    return tonumber(RS.SpecStabilityTotal(slots)) or 0
end

--- Keep a soft board snapshot while the apo recipe is loaded (VALID), so instant
--- SUCCESS / bag-update / "You created" can still learn after the board clears.
function BL.RefreshBoardSnapshot()
    local sessionMats, sessionKey, sessionSkillUp = SessionRecipeLatch()
    local materials = sessionMats
    local recipeKey = sessionKey or ""
    if type(materials) ~= "table" then
        local slots = BL.CaptureApothecaryMaterials()
        if slots == nil then
            return false
        end
        materials = AggregateMaterials(slots)
    end
    local hasMain = false
    for i = 1, #materials do
        if materials[i].role == "main" then
            hasMain = true
            break
        end
    end
    if not hasMain then
        return false
    end
    if recipeKey == "" and StockPiler.RecipeSpec and StockPiler.RecipeSpec.RecipeSpecKey then
        recipeKey = tostring(StockPiler.RecipeSpec.RecipeSpecKey(materials) or "")
    end
    -- Sticky SkillUp only while this snapshot is still a SkillUp session.
    local skillUpOrigin = sessionSkillUp == true or LatchSkillUpOrigin()
    BL._lastBoardMaterials = materials
    BL._lastBoardRecipeKey = recipeKey
    BL._lastBoardPotionCounts = SnapshotPotionCounts()
    BL._lastBoardSuccessChance = LatchSuccessChance()
    BL._lastBoardAt = NowSec()
    if skillUpOrigin then
        BL._lastBoardSkillUpOrigin = true
    else
        BL._lastBoardSkillUpOrigin = nil
    end
    BL._lastBoardFromSession = sessionMats ~= nil
    -- A loaded board is not a brew. Only Perform / PERFORMING may arm a learn.
    BL._lastBoardFromPerform = nil
    return true
end

function BL.ArmPendingFromLastBoard()
    if type(BL._pendingCraft) == "table" then
        return true
    end
    if type(BL._lastBoardMaterials) ~= "table" or BL._lastBoardFromPerform ~= true then
        return false
    end
    local at = tonumber(BL._lastBoardAt) or 0
    local now = NowSec()
    if at > 0 and now > 0 and (now - at) > BOARD_SNAPSHOT_TTL_SEC then
        return false
    end
    local materials = BL._lastBoardMaterials
    local recipeKey = tostring(BL._lastBoardRecipeKey or "")
    if recipeKey == "" and StockPiler.RecipeSpec and StockPiler.RecipeSpec.RecipeSpecKey then
        recipeKey = StockPiler.RecipeSpec.RecipeSpecKey(materials) or ""
    end
    local skillUpOrigin = BL._lastBoardSkillUpOrigin == true or LatchSkillUpOrigin()
    BL._pendingCraft = {
        materials = materials,
        recipeKey = recipeKey,
        potionCountsBefore = BL._lastBoardPotionCounts or {},
        successChance = tonumber(BL._lastBoardSuccessChance) or LatchSuccessChance(),
        skillUpOrigin = skillUpOrigin,
        fromSessionRecipe = BL._lastBoardFromSession == true,
        fromPerform = true,
        rearmed = true,
    }
    return true
end

function BL.HasFreshPendingCraftForFrame(tradeSkill)
    local frame = tonumber(StockPiler.FrameCounter) or 0
    if frame <= 0 or BL._pendingCraftFrame ~= frame then
        return false
    end
    if type(BL._pendingCraft) ~= "table" then
        return false
    end
    if tradeSkill ~= nil and BL._pendingCraftTrade ~= nil
        and tonumber(tradeSkill) ~= tonumber(BL._pendingCraftTrade)
    then
        return false
    end
    return true
end

function BL.BeginPendingCraft()
    if BL.HasFreshPendingCraftForFrame() then
        return true
    end
    local sessionMats, sessionKey, sessionSkillUp = SessionRecipeLatch()
    local materials = sessionMats
    local recipeKey = sessionKey or ""
    local fromSession = sessionMats ~= nil
    if type(materials) ~= "table" then
        local slots = BL.CaptureApothecaryMaterials()
        if slots == nil then
            -- Instant craft may clear the board before PERFORMING; keep last board if fresh.
            return BL.ArmPendingFromLastBoard() == true
        end
        materials = AggregateMaterials(slots)
        fromSession = false
    end
    local hasMain = false
    for i = 1, #materials do
        if materials[i].role == "main" then
            hasMain = true
            break
        end
    end
    if not hasMain then
        BL._pendingCraft = nil
        return false
    end
    if recipeKey == "" and StockPiler.RecipeSpec and StockPiler.RecipeSpec.RecipeSpecKey then
        recipeKey = StockPiler.RecipeSpec.RecipeSpecKey(materials) or ""
    end
    local potionCounts = SnapshotPotionCounts()
    local successChance = LatchSuccessChance()
    local skillUpOrigin = sessionSkillUp == true or LatchSkillUpOrigin()
    BL._lastBoardMaterials = materials
    BL._lastBoardRecipeKey = recipeKey
    BL._lastBoardPotionCounts = potionCounts
    BL._lastBoardSuccessChance = successChance
    BL._lastBoardAt = NowSec()
    if skillUpOrigin then
        BL._lastBoardSkillUpOrigin = true
    else
        BL._lastBoardSkillUpOrigin = nil
    end
    BL._lastBoardFromSession = fromSession
    BL._lastBoardFromPerform = true
    BL._pendingCraft = {
        materials = materials,
        recipeKey = recipeKey,
        potionCountsBefore = potionCounts,
        successChance = successChance,
        skillUpOrigin = skillUpOrigin,
        fromSessionRecipe = fromSession,
        fromPerform = true,
    }
    local frame = tonumber(StockPiler.FrameCounter) or 0
    if frame > 0 then
        BL._pendingCraftFrame = frame
        local AA = StockPiler.ApothecaryAdapter
        BL._pendingCraftTrade = AA and AA.TradeSkill and AA.TradeSkill() or nil
    end
    return true
end

local function BonusEffectId(item)
    if type(item) ~= "table" then
        return 0
    end
    local bonuses = item.craftingBonus or item.bonuses
    if type(bonuses) ~= "table" then
        return 0
    end
    local effectRef = BL.CraftBonus.EFFECT or 6
    for i = 1, #bonuses do
        local bonus = bonuses[i]
        if type(bonus) == "table" and tonumber(bonus.bonusReference) == effectRef then
            return tonumber(bonus.bonusValue) or 0
        end
    end
    for _, bonus in pairs(bonuses) do
        if type(bonus) == "table" and tonumber(bonus.bonusReference) == effectRef then
            return tonumber(bonus.bonusValue) or 0
        end
    end
    return 0
end

local function MainEffectId(materials)
    if type(materials) ~= "table" then
        return 0
    end
    for i = 1, #materials do
        local row = materials[i]
        if type(row) == "table" and row.role == "main" then
            local id = BonusEffectId(row.itemData)
            if id <= 0 then
                id = BonusEffectId(row)
            end
            if id > 0 then
                return id
            end
        end
    end
    return 0
end

local function FilterOutputsForMain(materials, outputs)
    local mainEffect = MainEffectId(materials)
    if mainEffect <= 0 or type(outputs) ~= "table" then
        return outputs
    end
    local kept = {}
    for i = 1, #outputs do
        local out = outputs[i]
        local effect = BonusEffectId(out and out.itemData)
        if effect > 0 and effect == mainEffect then
            kept[#kept + 1] = out
        end
    end
    return kept
end

function BL.CompletePendingCraftLearn(opts)
    opts = type(opts) == "table" and opts or {}
    local pending = BL._pendingCraft
    if type(pending) ~= "table" or type(pending.materials) ~= "table" then
        BL._pendingCraft = nil
        return false
    end
    if pending.fromPerform ~= true then
        BL._pendingCraft = nil
        return false
    end

    local after = SnapshotPotionCounts()
    local outputs = {}
    if opts.failed ~= true then
        outputs = DiffPotionOutputs(pending.potionCountsBefore, after)
        if pending.rearmed == true then
            outputs = FilterOutputsForMain(pending.materials, outputs)
        end
    end
    -- Keep pending when bag has not updated yet (SUCCESS can beat inventory).
    if #outputs == 0 and opts.failed ~= true then
        -- Drop stale re-arms whose before-counts already match the bag (blocks next brew).
        local before = pending.potionCountsBefore or {}
        local stale = true
        for uid, count in pairs(after) do
            if (tonumber(count) or 0) ~= (tonumber(before[uid]) or 0) then
                stale = false
                break
            end
        end
        if stale then
            for uid, count in pairs(before) do
                if (tonumber(after[uid]) or 0) ~= (tonumber(count) or 0) then
                    stale = false
                    break
                end
            end
        end
        if stale then
            BL._pendingCraft = nil
            BL._lastBoardSkillUpOrigin = nil
        end
        return false
    end
    -- Claim only once we will notify: chat + SUCCESS used to both print Brewed.
    BL._pendingCraft = nil
    BL._lastBoardMaterials = nil
    -- Advance baseline so ArmPendingFromLastBoard cannot re-diff the same bag gain.
    BL._lastBoardPotionCounts = after
    BL._lastBoardAt = NowSec()
    -- Consume sticky SkillUp arm for this brew cycle (skip or store).
    local pendingSkillUp = pending.skillUpOrigin == true
    if pendingSkillUp then
        BL._lastBoardSkillUpOrigin = true
    end

    local function NotifyBrewOutcome(msg)
        if StockPiler.Debug and StockPiler.Debug.Notify then
            StockPiler.Debug.Notify(msg)
        elseif StockPiler.Debug and StockPiler.Debug.Print then
            StockPiler.Debug.Print(msg)
        end
    end
    local function T(key, tokens)
        if StockPiler.T then
            return StockPiler.T(key, tokens)
        end
        return towstring(tostring(key or ""))
    end
    if #outputs > 0 then
        local CC = StockPiler.CraftChatAdapter
        for i = 1, #outputs do
            local out = outputs[i]
            local delta = tonumber(out.lastDelta) or tonumber(out.crafts) or 1
            local name = out.name
            if name == nil or name == L"" then
                name = T("brew.potion_fallback")
            end
            local uid = tonumber(out.uniqueID) or 0
            if CC and CC.NamedItem and uid > 0 then
                name = CC.NamedItem(uid, name, out.iconNum)
            elseif CC and CC.ItemLink and uid > 0 then
                name = CC.ItemLink(uid, name)
            end
            NotifyBrewOutcome(T("brew.outcome_ok", {
                name = name,
                count = tostring(delta),
            }))
        end
    elseif opts.failed == true then
        NotifyBrewOutcome(T("brew.outcome_fail", { name = T("brew.potion_fallback") }))
    end
    local RS = StockPiler.RecipeSpec
    local ok = false
    -- Prefer materials latched from the brew-session recipe (stable SkillUp / watch load).
    -- Fall back to live session.recipe, then pending board snapshot.
    local materials = pending.materials
    local Brew = StockPiler.Brew
    local session = Brew and Brew.GetSession and Brew.GetSession() or nil
    local intendedKey = tostring(pending.recipeKey or "")
    if intendedKey == "" and type(session) == "table" then
        intendedKey = tostring(session.recipeSpecKey or "")
    end
    if pending.fromSessionRecipe ~= true
        and type(session) == "table"
        and type(session.recipe) == "table"
    then
        local exact = MaterialsFromSavedRecipe(session.recipe)
        if type(exact) == "table" and #exact > 0 then
            materials = exact
            pending.fromSessionRecipe = true
            if intendedKey == "" then
                intendedKey = tostring(session.recipeSpecKey or "")
            end
            pending.recipeKey = intendedKey
            if session.skillUp == true or session.recipe.skillUpOrigin == true then
                pending.skillUpOrigin = true
                pendingSkillUp = true
            end
        end
    end
    local skillUpOrigin = pendingSkillUp == true
        or pending.skillUpOrigin == true
        or LatchSkillUpOrigin()
    -- SkillUp Apo invents throwaway boards - never stamp them into known potions.
    -- Check before fingerprint/stab rejects so a cleared session cannot race-learn.
    if skillUpOrigin == true then
        BL._lastBoardSkillUpOrigin = nil
        if StockPiler.Debug and StockPiler.Debug.LogOp then
            StockPiler.Debug.LogOp("brewlearn", "skip skillUpOrigin learn")
        end
        return true
    end
    BL._lastBoardSkillUpOrigin = nil
    if intendedKey ~= ""
        and tostring(pending.recipeKey or "") ~= ""
        and tostring(pending.recipeKey) ~= intendedKey
        and pending.fromSessionRecipe ~= true
    then
        -- Board snapshot drifted from the loaded recipe - do not register a new fingerprint.
        if StockPiler.Debug and StockPiler.Debug.LogOp then
            StockPiler.Debug.LogOp("brewlearn", "reject board fingerprint != session recipe")
        end
        return false
    end
    -- Never stamp a success recipe whose board cannot succeed (stab < 0 = engine LOW).
    -- Bag deltas must not bypass this gate (incomplete SkillUp/board snapshots).
    local stab = MaterialsStability(materials)
    if opts.failed ~= true and stab < 0 then
        if StockPiler.Debug and StockPiler.Debug.LogOp then
            StockPiler.Debug.LogOp(
                "brewlearn",
                "reject unstable learn stab=" .. tostring(stab)
            )
        end
        return false
    end
    -- Engine SuccessChance is SoT for speculative learns (LOW = definite fail,
    -- INVALID = incomplete). Stable SkillUp boards may latch LOW while still
    -- succeeding via ActionBar - allow bag-delta learn only when stab >= 0.
    if opts.failed ~= true
        and #outputs == 0
        and not SuccessChanceAllowsLearn(pending.successChance)
    then
        if StockPiler.Debug and StockPiler.Debug.LogOp then
            StockPiler.Debug.LogOp(
                "brewlearn",
                "reject learn SuccessChance=" .. tostring(pending.successChance)
            )
        end
        return false
    end
    if opts.failed ~= true
        and #outputs > 0
        and not SuccessChanceAllowsLearn(pending.successChance)
        and StockPiler.Debug and StockPiler.Debug.LogOp
    then
        StockPiler.Debug.LogOp(
            "brewlearn",
            "learn despite SuccessChance=" .. tostring(pending.successChance)
                .. " outputs=" .. tostring(#outputs)
                .. " stab=" .. tostring(stab)
        )
    end
    if RS and RS.StoreLearnedRecipeSpec then
        ok = RS.StoreLearnedRecipeSpec(materials, outputs, {
            mainConsumed = opts.mainConsumed,
            failed = opts.failed == true,
            skillUpOrigin = false,
        }) == true
    end
    return ok
end

function BL.OnCraftingUpdated()
    local AA = StockPiler.ApothecaryAdapter
    local state = AA and AA.CraftingState and AA.CraftingState() or -1
    local States = GameData and GameData.CraftingStates
    if type(States) ~= "table" then
        return false
    end
    -- VALID_RECIPE is only a loaded board. Learn from Perform / PERFORMING.
    if state == States.PERFORMING then
        -- Always refresh before-counts for this brew (do not keep a stale re-arm).
        BL.BeginPendingCraft()
        return false
    end
    if state == States.SUCCESS or state == States.SUCCESS_REPEAT or state == (States.DONE) then
        if type(BL._pendingCraft) ~= "table" then
            BL.ArmPendingFromLastBoard()
        end
        return BL.CompletePendingCraftLearn() == true
    end
    if state == States.FAIL then
        if type(BL._pendingCraft) ~= "table" then
            BL.ArmPendingFromLastBoard()
        end
        return BL.CompletePendingCraftLearn({ failed = true }) == true
    end
    return false
end

function BL.MarkInventoryCraftPollDue()
    BL._inventoryCraftPollDue = true
end

function BL.DrainInventoryCraftPoll()
    if BL._inventoryCraftPollDue ~= true then
        return false
    end
    BL._inventoryCraftPollDue = false
    if type(BL._pendingCraft) ~= "table" then
        -- Only arm when a prior Complete has not already advanced the bag baseline.
        if not BL.ArmPendingFromLastBoard() then
            return false
        end
    end
    if type(BL._pendingCraft) ~= "table" then
        return false
    end
    local pending = BL._pendingCraft
    local after = SnapshotPotionCounts()
    local before = pending.potionCountsBefore or {}
    local gained = false
    for uid, count in pairs(after) do
        if (tonumber(count) or 0) > (tonumber(before[uid]) or 0) then
            gained = true
            break
        end
    end
    if not gained then
        return false
    end
    return BL.CompletePendingCraftLearn() == true
end

--- Crafting chat "You created ..." when SUCCESS state was skipped (instant brew).
--- Complete only if bag already gained; otherwise arm inventory poll.
function BL.OnCreatedChat(createdName)
    if type(BL._pendingCraft) ~= "table" then
        -- Instant brew may skip PERFORMING; arm from last board if still fresh.
        if not BL.ArmPendingFromLastBoard() then
            return false
        end
    end
    if type(BL._pendingCraft) ~= "table" then
        return false
    end
    if createdName ~= nil and createdName ~= "" then
        BL._pendingCraft.chatCreatedName = createdName
    end
    local pending = BL._pendingCraft
    local after = SnapshotPotionCounts()
    local before = pending.potionCountsBefore or {}
    for uid, count in pairs(after) do
        if (tonumber(count) or 0) > (tonumber(before[uid]) or 0) then
            return BL.CompletePendingCraftLearn() == true
        end
    end
    BL.MarkInventoryCraftPollDue()
    return false
end

function BL.OnCraftChat(payload)
    if type(payload) == "table" and payload.kind == "created" then
        BL.OnCreatedChat(payload.name)
    end
end
