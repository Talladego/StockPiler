----------------------------------------------------------------
-- StockPilerBrew - load learned recipes into the Apothecary from the crafting bag
-- Prefers spec-slot matching (same as AutoGrow); falls back to named/UID materials.
----------------------------------------------------------------

StockPiler.Brew = StockPiler.Brew or {}

local TICK_INTERVAL_SEC = 0.05
local OPEN_WAIT_TICKS = 60
local STEP_WAIT_TICKS = 60
local CLEAR_WAIT_TICKS = 80

-- Apothecary load order: flask first, then main, then supplements.
local LOAD_ROLE_ORDER = {
    container = 1,
    main = 2,
    stabilizer = 3,
    goldweed = 3,
    extender = 4,
    multiplier = 5,
    stimulant = 5,
    ingredient = 6,
}

local function ToNarrow(s)
    return StockPiler.ToNarrow(s)
end

-- Brew/load breadcrumbs → uilog.log. Gated by /stp debug.
local function D(msg)
    if not (StockPiler and StockPiler.DebugEnabled == true) then
        return
    end
    local text = "[Load] " .. tostring(msg)
    if StockPiler._EmitLog and StockPiler._LogText then
        StockPiler._EmitLog("StockPiler| " .. StockPiler._LogText(text))
    elseif type(d) == "function" then
        d("StockPiler| " .. text)
    end
end

-- Forward declarations (Lua 5.1).
local CraftingState
local CraftingSkillType
local ApothecaryWindowOpen
local SlotLoaded
local GetCraftingBagTable
local FindCraftingBagItem
local DumpApoBoard
local StepWhy
local LoadLooksCompleteReason

local function ApothecaryStateLabel()
    if type(ApothecaryWindow) ~= "table" then
        return "no-window"
    end
    return tostring(ApothecaryWindow.currentState or "?")
end

local function CraftingStateLabel(state)
    state = tonumber(state) or CraftingState()
    if GameData and GameData.CraftingStates then
        local cs = GameData.CraftingStates
        if state == cs.VALID_RECIPE then return "VALID_RECIPE" end
        if state == cs.PERFORMING then return "PERFORMING" end
        if state == cs.SUCCESS then return "SUCCESS" end
        if state == cs.SUCCESS_REPEAT then return "SUCCESS_REPEAT" end
        if state == cs.FAIL then return "FAIL" end
        if state == cs.ADDCONTAINER then return "ADDCONTAINER" end
        if state == cs.ADDDETERMINENT then return "ADDDETERMINENT" end
        if state == cs.ADDINGREDIENT then return "ADDINGREDIENT" end
    end
    return tostring(state)
end

local function JobContext(job)
    if type(job) ~= "table" then
        return ""
    end
    local parts = {
        "phase=" .. tostring(job.phase),
        "tick=" .. tostring(job.waitTicks or 0),
        "row=" .. tostring(job.rowId),
        "gameState=" .. CraftingStateLabel(),
        "apoState=" .. ApothecaryStateLabel(),
        "performLock=" .. tostring(type(ApothecaryWindow) == "table" and ApothecaryWindow.PerformingLock == true),
        "windowOpen=" .. tostring(ApothecaryWindowOpen()),
    }
    if job.phase == "load" and type(job.steps) == "table" then
        local step = job.steps[job.stepIndex]
        parts[#parts + 1] = "step=" .. tostring(job.stepIndex) .. "/" .. tostring(#job.steps)
        if type(step) == "table" then
            parts[#parts + 1] = "craftSlot=" .. tostring(step.craftingSlot)
            parts[#parts + 1] = "uid=" .. tostring(step.uniqueID)
            parts[#parts + 1] = "loaded=" .. tostring(SlotLoaded(step))
        end
    end
    return table.concat(parts, " ")
end

local function LogJob(job, detail)
    if type(detail) == "wstring" then
        detail = ToNarrow(detail)
    elseif detail ~= nil and type(detail) ~= "string" then
        detail = tostring(detail)
    end
    D(JobContext(job) .. (detail and (" | " .. detail) or ""))
end

local function SetPhase(job, phase, detail)
    local prev = job.phase
    job.phase = phase
    job.waitTicks = 0
    if prev ~= phase then
        LogJob(job, (detail and (detail .. " ") or "") .. "(was " .. tostring(prev) .. ")")
    end
end

local function DescribeSteps(steps)
    if type(steps) ~= "table" then
        return "[]"
    end
    local parts = {}
    for i = 1, #steps do
        local step = steps[i]
        local specKey = ""
        if type(step.spec) == "table" and StockPiler.MaterialSpec and StockPiler.MaterialSpec.Key then
            specKey = tostring(StockPiler.MaterialSpec.Key(step.spec) or "")
        end
        parts[#parts + 1] = tostring(i) .. ":slot" .. tostring(step.craftingSlot)
            .. "/uid" .. tostring(step.uniqueID)
            .. "/" .. tostring(step.role or "?")
            .. (specKey ~= "" and ("/spec" .. specKey) or "")
    end
    return "[" .. table.concat(parts, ", ") .. "]"
end

local function ApothecarySkill()
    return (GameData and GameData.TradeSkills and GameData.TradeSkills.APOTHECARY) or 4
end

local function CraftingBackpackType()
    if EA_Window_Backpack and EA_Window_Backpack.TYPE_CRAFTING then
        return EA_Window_Backpack.TYPE_CRAFTING
    end
    return 4
end

local function ItemValid(item)
    if item == nil or type(item) ~= "table" then
        return false
    end
    if DataUtils and type(DataUtils.IsValidItem) == "function" then
        local ok, valid = StockPiler.TryCallQuiet("DataUtils.IsValidItem", DataUtils.IsValidItem, item)
        if ok then
            return valid == true
        end
    end
    local uid = tonumber(item.uniqueID) or 0
    return uid > 0
end

local function NameMatches(item, narrowName)
    narrowName = ToNarrow(narrowName)
    if narrowName == "" or item == nil then
        return false
    end
    local name = string.lower(ToNarrow(item.name))
    local needle = string.lower(narrowName)
    return name ~= "" and string.find(name, needle, 1, true) ~= nil
end

GetCraftingBagTable = function()
    if DataUtils and type(DataUtils.GetCraftingItems) == "function" then
        local ok, data = StockPiler.TryCallQuiet("DataUtils.GetCraftingItems", DataUtils.GetCraftingItems)
        if ok and type(data) == "table" then
            return data
        end
    end
    if type(EA_Window_Backpack) == "table"
        and type(EA_Window_Backpack.GetItemsFromBackpack) == "function"
    then
        return EA_Window_Backpack.GetItemsFromBackpack(CraftingBackpackType())
    end
    return nil
end

local function EachCraftingBagSlot(fn)
    local bag = GetCraftingBagTable()
    if type(bag) ~= "table" then
        return 0
    end
    local n = 0
    for slot, item in pairs(bag) do
        if type(slot) == "number" and ItemValid(item) then
            n = n + 1
            fn(slot, item)
        end
    end
    return n
end

local function ItemMatchesSpec(item, spec)
    if type(spec) ~= "table" then
        return false
    end
    if StockPiler.Inventory and StockPiler.Inventory.IsSeedOrSporeItem
        and StockPiler.Inventory.IsSeedOrSporeItem(item)
    then
        return false
    end
    return StockPiler.MaterialSpec
        and StockPiler.MaterialSpec.Matches
        and StockPiler.MaterialSpec.Matches(item, spec) == true
end

local function ItemMatchesStep(item, step)
    if not ItemValid(item) or type(step) ~= "table" then
        return false
    end
    if type(step.spec) == "table" then
        return ItemMatchesSpec(item, step.spec)
    end
    local uid = tonumber(step.uniqueID) or 0
    local itemUid = tonumber(item.uniqueID) or 0
    if uid > 0 then
        return itemUid == uid
    end
    return NameMatches(item, step.narrowName)
end

local function ItemAllowedForRole(item, role)
    if type(item) ~= "table" or role == nil or role == "" then
        return true
    end
    if type(ApothecaryWindow) ~= "table" or type(ApothecaryWindow.ItemIsAllowedInSlot) ~= "function" then
        return true
    end
    local function allowedIn(slot)
        local ok, allowed = StockPiler.TryCallQuiet("ApothecaryWindow.ItemIsAllowedInSlot", ApothecaryWindow.ItemIsAllowedInSlot, item, slot)
        return ok and allowed == true
    end
    if role == "container" then
        return allowedIn(ApothecaryWindow.SLOT_CONTAINER or 0)
    end
    if role == "main" then
        return allowedIn(ApothecaryWindow.SLOT_DETERMINENT or 1)
    end
    local first = ApothecaryWindow.SLOT_INGREDIENT1 or 2
    local last = ApothecaryWindow.SLOT_INGREDIENT3 or 4
    for slot = first, last do
        if allowedIn(slot) then
            return true
        end
    end
    return false
end

local function SpecKey(spec)
    if type(spec) == "table" and StockPiler.MaterialSpec and StockPiler.MaterialSpec.Key then
        return tostring(StockPiler.MaterialSpec.Key(spec) or "")
    end
    return ""
end

local function ResourceTypeLabel(rt)
    rt = tonumber(rt) or 0
    local T = GameData and GameData.CraftingItemType
    if type(T) == "table" then
        for name, val in pairs(T) do
            if val == rt then
                return tostring(name) .. "(" .. tostring(rt) .. ")"
            end
        end
    end
    return tostring(rt)
end

local function BonusDump(item)
    local bonuses = item and item.craftingBonus
    if type(bonuses) ~= "table" then
        return "bonus=nil"
    end
    local ip, pp = 0, 0
    local parts = {}
    for _, b in ipairs(bonuses) do
        ip = ip + 1
        if type(b) == "table" then
            parts[#parts + 1] = tostring(b.bonusReference) .. "=" .. tostring(b.bonusValue)
        end
    end
    for _ in pairs(bonuses) do
        pp = pp + 1
    end
    return "bonusIpairs=" .. tostring(ip) .. " pairs=" .. tostring(pp)
        .. " [" .. table.concat(parts, ",") .. "]"
end

local function ClientCraftInfo(item)
    if type(item) ~= "table" then
        return 0, "no-item", 0, false
    end
    local types, rt, req
    if type(CraftingSystem) == "table" and type(CraftingSystem.GetCraftingData) == "function" then
        local ok = StockPiler.TryCallQuiet("CraftingSystem.GetCraftingData", function()
            types, rt, req = CraftingSystem.GetCraftingData(item)
        end)
        if not ok then
            return 0, "GetCraftingData-err", 0, false
        end
    end
    local isApo = false
    if type(CraftingSystem) == "table" and type(CraftingSystem.IsCraftingItem) == "function"
        and GameData and GameData.TradeSkills
    then
        local ok, v = StockPiler.TryCallQuiet("CraftingSystem.IsCraftingItem", CraftingSystem.IsCraftingItem, item, GameData.TradeSkills.APOTHECARY)
        isApo = ok and v == true
    end
    return tonumber(rt) or 0, ResourceTypeLabel(rt), tonumber(req) or 0, isApo
end

local function AllowedSlotsDump(item)
    if type(item) ~= "table" or type(ApothecaryWindow) ~= "table"
        or type(ApothecaryWindow.ItemIsAllowedInSlot) ~= "function"
    then
        return "allowed=n/a"
    end
    local parts = {}
    for slot = 0, 4 do
        local ok, allowed = StockPiler.TryCallQuiet("ApothecaryWindow.ItemIsAllowedInSlot", ApothecaryWindow.ItemIsAllowedInSlot, item, slot)
        parts[#parts + 1] = tostring(slot) .. "=" .. tostring(ok and allowed)
    end
    return "allowed[" .. table.concat(parts, " ") .. "]"
end

local function DescribeItem(item)
    if not ItemValid(item) then
        return "item=nil"
    end
    local rt, rtLabel, req, isApo = ClientCraftInfo(item)
    local itemSpec = ""
    if StockPiler.MaterialSpec and StockPiler.MaterialSpec.FromItemData then
        local spec = StockPiler.MaterialSpec.FromItemData(item)
        if type(spec) == "table" then
            itemSpec = SpecKey(spec)
        end
    end
    return "name=" .. ToNarrow(item.name)
        .. " uid=" .. tostring(item.uniqueID)
        .. " stack=" .. tostring(item.stackCount)
        .. " ct=" .. tostring(item.cultivationType)
        .. " skillReq=" .. tostring(item.craftingSkillRequirement or req)
        .. " isApo=" .. tostring(isApo)
        .. " res=" .. tostring(rtLabel)
        .. " itemSpec=" .. itemSpec
        .. " " .. BonusDump(item)
        .. " " .. AllowedSlotsDump(item)
end

local function BagSearchReason(item, uniqueID, narrowName, spec, role, exclude, bagType, slot)
    local key = tostring(bagType) .. ":" .. tostring(slot)
    local used = tonumber(exclude and exclude[key]) or 0
    local stack = tonumber(item.stackCount) or 1
    if used > 0 and used >= stack then
        return "reject=used"
    end
    local cultType = tonumber(item.cultivationType) or 0
    local seedType = (GameData and GameData.CultivationTypes and GameData.CultivationTypes.SEED) or 1
    local sporeType = (GameData and GameData.CultivationTypes and GameData.CultivationTypes.SPORE) or 5
    if cultType == seedType or cultType == sporeType then
        return "reject=seed"
    end
    if StockPiler.Inventory and StockPiler.Inventory.CanUseCraftingItem
        and not StockPiler.Inventory.CanUseCraftingItem(item)
    then
        return "reject=skill"
    end
    local matched = false
    if type(spec) == "table" then
        matched = ItemMatchesSpec(item, spec)
        if not matched then
            return "reject=spec want=" .. SpecKey(spec)
        end
    else
        local uid = tonumber(item.uniqueID) or 0
        if uniqueID > 0 then
            matched = uid == uniqueID
            if not matched then
                return "reject=uid"
            end
        elseif narrowName ~= "" then
            matched = NameMatches(item, narrowName)
            if not matched then
                return "reject=name"
            end
        end
    end
    if not ItemAllowedForRole(item, role) then
        return "reject=roleAllowed"
    end
    return "ok"
end

FindCraftingBagItem = function(uniqueID, narrowName, exclude, spec, role)
    uniqueID = tonumber(uniqueID) or 0
    narrowName = ToNarrow(narrowName)
    exclude = exclude or {}
    local bagType = CraftingBackpackType()
    local bestSlot, bestItem = nil, nil
    local bestStack = 100000
    EachCraftingBagSlot(function(slot, item)
        local key = tostring(bagType) .. ":" .. tostring(slot)
        local used = tonumber(exclude[key]) or 0
        local stack = tonumber(item.stackCount) or 1
        if used > 0 and used >= stack then
            return
        end
        local uid = tonumber(item.uniqueID) or 0
        local matched = false
        if type(spec) == "table" then
            matched = ItemMatchesSpec(item, spec)
        elseif uniqueID > 0 and uid == uniqueID then
            matched = true
        elseif uniqueID <= 0 and narrowName ~= "" and NameMatches(item, narrowName) then
            matched = true
        end
        local cultType = tonumber(item.cultivationType) or 0
        local seedType = (GameData and GameData.CultivationTypes and GameData.CultivationTypes.SEED) or 1
        local sporeType = (GameData and GameData.CultivationTypes and GameData.CultivationTypes.SPORE) or 5
        if cultType == seedType or cultType == sporeType then
            return
        end
        if matched and ItemAllowedForRole(item, role) then
            if stack < bestStack or (stack == bestStack and (bestSlot == nil or slot < bestSlot)) then
                bestSlot = slot
                bestStack = stack
                bestItem = item
            end
        end
    end)
    return bestSlot, bestItem, bagType
end

local function CraftingStates()
    return GameData and GameData.CraftingStates or nil
end

local _craftDataCache = nil

local function GetApothecaryCraftData()
    if type(_craftDataCache) == "table" then
        return _craftDataCache
    end
    if type(GetCraftingData) ~= "function" then
        return nil
    end
    local ok, data = StockPiler.TryCallQuiet("GetCraftingData", GetCraftingData, ApothecarySkill())
    if ok and type(data) == "table" then
        _craftDataCache = data
        return data
    end
    return nil
end

local function GetServerCraftItemId(craftingSlot)
    local data = GetApothecaryCraftData()
    if type(data) ~= "table" then
        return 0
    end
    local row = data[craftingSlot]
    if type(row) == "table" then
        return tonumber(row.id) or tonumber(row.objectId) or tonumber(row.uniqueID) or 0
    end
    return 0
end

local function ServerHasCraftingItems()
    for slotNum = 0, 4 do
        if GetServerCraftItemId(slotNum) > 0 then
            return true
        end
    end
    if type(GetCraftingBackPackSlots) ~= "function" then
        return false
    end
    local ok, slots = StockPiler.TryCallQuiet("GetCraftingBackPackSlots", GetCraftingBackPackSlots, ApothecarySkill())
    if ok and type(slots) == "table" then
        for _, entry in pairs(slots) do
            if type(entry) == "table" and entry.slot then
                return true
            end
        end
    end
    return false
end

local function RemoveApothecaryEntry(apo, slot, backpack, seen)
    if slot == nil or backpack == nil then
        return false
    end
    local key = tostring(backpack) .. ":" .. tostring(slot)
    if type(seen) == "table" then
        if seen[key] then
            return false
        end
        seen[key] = true
    end
    StockPiler.TryCall("RemoveCraftingItem", RemoveCraftingItem, apo, slot, backpack)
    return true
end

local function ClearClientApothecarySlots()
    if type(ApothecaryWindow) ~= "table" or type(RemoveCraftingItem) ~= "function" then
        return false
    end
    local apo = ApothecarySkill()
    local cleared = false
    -- Ingredients first, flask last so the session can fall back to ADDCONTAINER.
    for slotNum = 4, 0, -1 do
        local cd = ApothecaryWindow.craftingData and ApothecaryWindow.craftingData[slotNum]
        if type(cd) == "table" and cd.sourceSlot and cd.sourceBackpack then
            if RemoveApothecaryEntry(apo, cd.sourceSlot, cd.sourceBackpack) then
                cleared = true
            end
        end
    end
    return cleared
end

local function ClearServerApothecarySlots()
    if type(RemoveCraftingItem) ~= "function" then
        return ClearClientApothecarySlots()
    end
    local apo = ApothecarySkill()
    local cleared = false
    local seen = {}
    if type(GetCraftingBackPackSlots) == "function" then
        local ok, slots = StockPiler.TryCallQuiet("GetCraftingBackPackSlots", GetCraftingBackPackSlots, apo)
        if ok and type(slots) == "table" then
            for index = 4, 0, -1 do
                local entry = slots[index]
                if type(entry) == "table" then
                    if RemoveApothecaryEntry(apo, entry.slot, entry.backpack, seen) then
                        cleared = true
                    end
                end
            end
            for _, entry in pairs(slots) do
                if type(entry) == "table" then
                    if RemoveApothecaryEntry(apo, entry.slot, entry.backpack, seen) then
                        cleared = true
                    end
                end
            end
        end
    end
    if ClearClientApothecarySlots() then
        cleared = true
    end
    return cleared
end

local function ReleaseApothecaryBackpackLocks()
    local name = (type(ApothecaryWindow) == "table" and ApothecaryWindow.windowName) or "ApothecaryWindow"
    if type(EA_BackpackUtilsMediator) == "table"
        and type(EA_BackpackUtilsMediator.ReleaseAllLocksForWindow) == "function"
    then
        StockPiler.TryCall(
            "ReleaseAllLocksForWindow",
            EA_BackpackUtilsMediator.ReleaseAllLocksForWindow,
            name
        )
    elseif type(EA_Window_Backpack) == "table"
        and type(EA_Window_Backpack.ReleaseAllLocksForWindow) == "function"
    then
        StockPiler.TryCall(
            "EA_Window_Backpack.ReleaseAllLocksForWindow",
            EA_Window_Backpack.ReleaseAllLocksForWindow,
            name
        )
    end
    if type(EA_BackpackUtilsMediator) == "table"
        and type(EA_BackpackUtilsMediator.EnableSoftLocks) == "function"
    then
        StockPiler.TryCall(
            "EnableSoftLocks",
            EA_BackpackUtilsMediator.EnableSoftLocks,
            false
        )
    elseif type(EA_Window_Backpack) == "table"
        and type(EA_Window_Backpack.EnableSoftLocks) == "function"
    then
        StockPiler.TryCall(
            "EA_Window_Backpack.EnableSoftLocks",
            EA_Window_Backpack.EnableSoftLocks,
            false
        )
    end
end

local function EnsureBrewApothecarySoftLocks(enabled)
    if type(EA_BackpackUtilsMediator) == "table"
        and type(EA_BackpackUtilsMediator.EnableSoftLocks) == "function"
    then
        StockPiler.TryCallQuiet(
            "EnableSoftLocks",
            EA_BackpackUtilsMediator.EnableSoftLocks,
            enabled == true
        )
    elseif type(EA_Window_Backpack) == "table"
        and type(EA_Window_Backpack.EnableSoftLocks) == "function"
    then
        StockPiler.TryCallQuiet(
            "EA_Window_Backpack.EnableSoftLocks",
            EA_Window_Backpack.EnableSoftLocks,
            enabled == true
        )
    end
end

--- Claim ownership when One-Click Load uses the engine session — including the common
--- case where ADDCONTAINER is already active and OpenApothecary is skipped.
local function ClaimBrewOwnedSession()
    if ApothecaryWindowOpen and ApothecaryWindowOpen() then
        return false
    end
    StockPiler.Brew._brewOwnedSession = true
    StockPiler.Brew._brewApoStealth = true
    EnsureBrewApothecarySoftLocks(true)
    if CraftingSystem and type(CraftingSystem.SetCurrentTradeSkill) == "function" then
        StockPiler.TryCallQuiet(
            "SetCurrentTradeSkill",
            CraftingSystem.SetCurrentTradeSkill,
            ApothecarySkill()
        )
    end
    return true
end

--- End engine Apo session and clear crafting-bag blue soft-locks.
local function CloseApothecarySession()
    local apo = ApothecarySkill()
    local closeApo = StockPiler.Brew._brewOpenedApo == true
    local closeBag = StockPiler.Brew._brewOpenedBackpack == true
    local ownedSession = StockPiler.Brew._brewOwnedSession == true
    local stealth = StockPiler.Brew._brewApoStealth == true
    local playerVisible = ApothecaryWindowOpen and ApothecaryWindowOpen() == true
    local apoSkillActive = CraftingSkillType and CraftingSkillType() == apo

    ClearServerApothecarySlots()
    -- Always clear blue tint — ownership is often unset when Load skipped OpenApothecary.
    ReleaseApothecaryBackpackLocks()

    StockPiler.Brew._brewOpenedApo = false
    StockPiler.Brew._brewOpenedBackpack = false
    StockPiler.Brew._brewOwnedSession = false
    StockPiler.Brew._brewApoStealth = false

    if closeBag and type(EA_BackpackUtilsMediator) == "table"
        and type(EA_BackpackUtilsMediator.HideBackpack) == "function"
    then
        StockPiler.TryCall("EA_BackpackUtilsMediator.HideBackpack", EA_BackpackUtilsMediator.HideBackpack)
    end

    local endEngine = ownedSession or stealth or closeApo
        or (apoSkillActive == true and not playerVisible)
    if not endEngine then
        D("apo locks released (left player Apo session alone)")
        return
    end

    if CraftingSystem and type(CraftingSystem.SetCurrentTradeSkill) == "function" then
        StockPiler.TryCallQuiet(
            "SetCurrentTradeSkill",
            CraftingSystem.SetCurrentTradeSkill,
            apo
        )
    end

    if type(ApothecaryWindow) == "table" then
        local slider = ApothecaryWindow.windowName
            and (ApothecaryWindow.windowName .. "StabilityMeterSlider")
            or nil
        if type(slider) == "string" and DoesWindowExist(slider)
            and type(WindowStopPositionAnimation) == "function"
        then
            StockPiler.TryCallQuiet(
                "WindowStopPositionAnimation",
                WindowStopPositionAnimation,
                slider
            )
        end
        if type(ApothecaryWindow.Clear) == "function" then
            StockPiler.TryCall("ApothecaryWindow.Clear", ApothecaryWindow.Clear)
        end
        ApothecaryWindow.nextFreeSlot = 0
        ApothecaryWindow.PerformingLock = false
    end

    if type(SendCloseCrafting) == "function" then
        StockPiler.TryCall("SendCloseCrafting", SendCloseCrafting, apo)
    end

    ReleaseApothecaryBackpackLocks()

    local name = type(ApothecaryWindow) == "table" and ApothecaryWindow.windowName or nil
    if type(name) == "string" and DoesWindowExist(name) then
        StockPiler.TryCall("WindowSetShowing", WindowSetShowing, name, false)
        if type(WindowUtils) == "table" and type(WindowUtils.RemoveFromOpenList) == "function" then
            StockPiler.TryCallQuiet("RemoveFromOpenList", WindowUtils.RemoveFromOpenList, name)
        end
    end

    D("apo session closed owned=" .. tostring(ownedSession)
        .. " stealth=" .. tostring(stealth)
        .. " skillActive=" .. tostring(apoSkillActive)
        .. " playerVisible=" .. tostring(playerVisible))
end

local function BackpackWindowOpen()
    local name = type(EA_Window_Backpack) == "table" and EA_Window_Backpack.windowName or nil
    return type(name) == "string" and DoesWindowExist(name) and WindowGetShowing(name) == true
end

local function HideApothecaryWindowOnly()
    -- Visual hide only — do NOT call ApothecaryWindow.Hide (that SendCloseCrafting).
    local name = type(ApothecaryWindow) == "table" and ApothecaryWindow.windowName or nil
    if type(name) == "string" and DoesWindowExist(name) and WindowGetShowing(name) then
        StockPiler.TryCall("WindowSetShowing", WindowSetShowing, name, false)
        if type(WindowUtils) == "table" and type(WindowUtils.RemoveFromOpenList) == "function" then
            StockPiler.TryCallQuiet("RemoveFromOpenList", WindowUtils.RemoveFromOpenList, name)
        end
        return true
    end
    return false
end

CraftingState = function()
    if not GameData or not GameData.CraftingStatus then
        return -1
    end
    return tonumber(GameData.CraftingStatus.State) or -1
end

CraftingSkillType = function()
    if not GameData or not GameData.CraftingStatus then
        return -1
    end
    return tonumber(GameData.CraftingStatus.SkillType) or -1
end

local function IsValidRecipeState()
    if type(ApothecaryWindow) ~= "table" then
        return false
    end
    if ApothecaryWindow.STATE_VALID_RECIPE and ApothecaryWindow.currentState == ApothecaryWindow.STATE_VALID_RECIPE then
        return true
    end
    if GameData and GameData.CraftingStates and GameData.CraftingStates.VALID_RECIPE then
        return CraftingSkillType() == ApothecarySkill()
            and CraftingState() == GameData.CraftingStates.VALID_RECIPE
    end
    return false
end

local function IsPerformingState()
    if type(ApothecaryWindow) == "table" and ApothecaryWindow.STATE_PERFORMING then
        if ApothecaryWindow.currentState == ApothecaryWindow.STATE_PERFORMING then
            return true
        end
    end
    if GameData and GameData.CraftingStates and GameData.CraftingStates.PERFORMING then
        return CraftingSkillType() == ApothecarySkill()
            and CraftingState() == GameData.CraftingStates.PERFORMING
    end
    return type(ApothecaryWindow) == "table" and ApothecaryWindow.PerformingLock == true
end

function StockPiler.Brew.IsBusy()
    return type(StockPiler.Brew._job) == "table"
end

local function EmptySession()
    return {
        phase = "idle",
        potionKey = nil,
        rowId = nil,
        name = nil,
    }
end

local function GetSession()
    local session = StockPiler.Brew._session
    if type(session) ~= "table" then
        session = EmptySession()
        StockPiler.Brew._session = session
    end
    return session
end

local function ClearSession()
    StockPiler.Brew._session = EmptySession()
end

local function RefreshBrewAppearance()
    if StockPilerMacro and StockPilerMacro.RefreshMacroButtonAppearance then
        StockPilerMacro.RefreshMacroButtonAppearance()
    end
    if StockPilerTabAutoGrow and StockPilerTabAutoGrow.RefreshBrewUi then
        StockPilerTabAutoGrow.RefreshBrewUi()
    end
end

local function AsWString(text)
    if type(text) == "wstring" then
        return text
    end
    if text == nil then
        return L""
    end
    return towstring(tostring(text))
end

local function RowKey(row)
    if type(row) ~= "table" then
        return ""
    end
    if row.potionKey ~= nil and tostring(row.potionKey) ~= "" then
        return tostring(row.potionKey)
    end
    return tostring(row.id or "")
end

local function RowMatchesSession(row, session)
    if type(row) ~= "table" or type(session) ~= "table" then
        return false
    end
    if session.potionKey ~= nil and row.potionKey ~= nil
        and tostring(row.potionKey) == tostring(session.potionKey)
    then
        return true
    end
    if session.rowId ~= nil and row.id ~= nil
        and tostring(row.id) == tostring(session.rowId)
    then
        return true
    end
    return false
end

local function RowIsReadyToCraft(row)
    if type(row) ~= "table" then
        return false
    end
    if (tonumber(row.potionDeficit) or 0) <= 0 then
        return false
    end
    if row.canLoad == true then
        return true
    end
    if row.statusKey == "ready_to_craft" and (tonumber(row.craftable) or 0) > 0 then
        return true
    end
    return false
end

local function CompareReadyWatch(a, b)
    local da = tonumber(a.potionDeficit) or 0
    local db = tonumber(b.potionDeficit) or 0
    if da ~= db then
        return da > db
    end
    return ToNarrow(a.name) < ToNarrow(b.name)
end

local function CurrentPlan(opts)
    if not StockPiler.Planner or not StockPiler.Planner.BuildPlan then
        return nil
    end
    local plan = StockPiler.Planner.BuildPlan(opts or { refresh = false })
    if type(plan) == "table" then
        return plan
    end
    return nil
end

local function FindSessionRow()
    local session = GetSession()
    if session.phase == "idle" and session.potionKey == nil and session.rowId == nil then
        return nil
    end
    local plan = CurrentPlan({ refresh = false })
    local rows = plan and plan.rows
    if type(rows) ~= "table" then
        return nil
    end
    for i = 1, #rows do
        if RowMatchesSession(rows[i], session) then
            return rows[i]
        end
    end
    return nil
end

local function SetSessionFromRow(row, phase)
    local session = GetSession()
    session.phase = phase or "idle"
    if type(row) == "table" then
        session.potionKey = row.potionKey
        session.rowId = row.id
        session.name = row.name
    else
        session.potionKey = nil
        session.rowId = nil
        session.name = nil
    end
end

function StockPiler.Brew.GetSession()
    return GetSession()
end

function StockPiler.Brew.PickReadyWatch()
    if StockPiler.Inventory and StockPiler.Inventory.IsApothecary
        and not StockPiler.Inventory.IsApothecary()
    then
        return nil
    end
    -- Trust plan Craftable* (stable recipes). Do not invalidate bags or walk
    -- the crafting bag here — this runs from glow/tooltip hot paths.
    local plan = CurrentPlan({ refresh = false })
    local rows = plan and plan.rows
    if type(rows) ~= "table" then
        return nil
    end
    local best = nil
    for i = 1, #rows do
        local row = rows[i]
        if RowIsReadyToCraft(row) then
            if best == nil or CompareReadyWatch(row, best) then
                best = row
            end
        end
    end
    return best
end

function StockPiler.Brew.HasReadyToCraft()
    if StockPiler.Brew.PickReadyWatch() ~= nil then
        return true
    end
    local session = GetSession()
    if session.phase == "loading" then
        return true
    end
    if session.phase == "loaded" then
        local row = FindSessionRow()
        if row == nil then
            return session.potionKey ~= nil or session.rowId ~= nil
        end
        return (tonumber(row.potionDeficit) or 0) > 0
    end
    return false
end

function StockPiler.Brew.IsMacroEnabled()
    local s = StockPiler.EnsureSettings and StockPiler.EnsureSettings() or StockPiler.Settings
    return type(s) == "table" and s.brewMacroEnabled ~= false
end

function StockPiler.Brew.SetMacroEnabled(enabled)
    local s = StockPiler.EnsureSettings and StockPiler.EnsureSettings() or StockPiler.Settings
    if type(s) ~= "table" then
        return false
    end
    enabled = enabled == true
    if enabled and StockPiler.Inventory and StockPiler.Inventory.IsApothecary
        and not StockPiler.Inventory.IsApothecary()
    then
        if StockPiler.Print then
            StockPiler.Print(L"Brew macro is only available to Apothecaries.")
        end
        enabled = false
    end
    local changed = (s.brewMacroEnabled ~= false) ~= enabled
    s.brewMacroEnabled = enabled
    if StockPiler.PersistActiveCharacterSettings then
        StockPiler.PersistActiveCharacterSettings(s)
    end
    if changed then
        if StockPiler.NotifyManual then
            if enabled then
                StockPiler.NotifyManual(L"Brew", L"one-click enabled.")
            else
                StockPiler.NotifyManual(L"Brew", L"one-click disabled.")
            end
        end
    end
    if StockPilerMacro and StockPilerMacro.RefreshMacroButtonAppearance then
        StockPilerMacro.RefreshMacroButtonAppearance()
    end
    return enabled
end

function StockPiler.Brew.ToggleMacroEnabled()
    return StockPiler.Brew.SetMacroEnabled(not StockPiler.Brew.IsMacroEnabled())
end

--- Row craft button: "brew" if this watch is loaded in apo, "load" if ready to craft, else "idle".
function StockPiler.Brew.GetRowCraftUiState(row)
    if type(row) ~= "table" then
        return "idle"
    end
    if StockPiler.Inventory and StockPiler.Inventory.IsApothecary
        and not StockPiler.Inventory.IsApothecary()
    then
        return "idle"
    end
    if StockPiler.Brew.IsMacroEnabled and not StockPiler.Brew.IsMacroEnabled() then
        return "idle"
    end
    local session = GetSession()
    if type(session) == "table" and RowMatchesSession(row, session) then
        if session.phase == "loaded" or session.phase == "loading" then
            return "brew"
        end
    end
    if RowIsReadyToCraft(row) or row.canLoad == true or row.canBrew == true then
        return "load"
    end
    return "idle"
end

--- Fire PerformCrafting for the current loaded apo session (same as brew macro).
function StockPiler.Brew.FirePerform()
    if not (StockPilerMacro and StockPilerMacro.FireApothecaryBrew) then
        return false
    end
    StockPilerMacro._brewFired = false
    local ok = StockPilerMacro.FireApothecaryBrew() == true
    StockPilerMacro._brewFired = false
    return ok
end

--- Watch-row Load/Brew click: brew if this row is loaded, else load materials for this row.
function StockPiler.Brew.OnRowCraftClick(row)
    if StockPiler.Brew.IsMacroEnabled and not StockPiler.Brew.IsMacroEnabled() then
        if StockPiler.Print then
            StockPiler.Print(L"One-Click Brew is disabled.")
        end
        return false
    end
    if StockPiler.Inventory and StockPiler.Inventory.IsApothecary
        and not StockPiler.Inventory.IsApothecary()
    then
        if StockPiler.Print then
            StockPiler.Print(L"Load is only available to Apothecaries.")
        end
        return false
    end
    if type(row) ~= "table" then
        return false
    end
    local state = StockPiler.Brew.GetRowCraftUiState(row)
    if state == "brew" then
        local session = GetSession()
        if session.phase == "loaded" and StockPiler.Brew.ValidateApothecaryPerform() == true then
            D("row brew potion=" .. ToNarrow(row.name) .. " key=" .. RowKey(row))
            return StockPiler.Brew.FirePerform()
        end
        if session.phase == "loading" then
            return false
        end
        return false
    end
    if state == "load" then
        return StockPiler.Brew.BeginForRow(row) == true
    end
    return false
end

function StockPiler.Brew.CancelSession()
    StockPiler.Brew._job = nil
    StockPiler.Brew._updateAccum = 0
    StockPiler.Brew._lastLoad = nil
    ClearSession()
    if StockPiler.Brew._brewOpenedApo == true
        or StockPiler.Brew._brewOpenedBackpack == true
        or StockPiler.Brew._brewOwnedSession == true
    then
        CloseApothecarySession()
    end
    if StockPiler.Print then
        StockPiler.Print(L"Brew session cancelled.")
    end
    RefreshBrewAppearance()
end

--- End One-Click Brew's engine session when the current board cannot brew.
--- Do not wait for PickReadyWatch()==nil: stale Craftable* would leave soft-locks on.
local function MaybeCloseBrewSessionIfIdle(reason)
    if StockPiler.Brew.IsBusy and StockPiler.Brew.IsBusy() then
        return false
    end
    if StockPiler.Brew._brewOpenedApo ~= true
        and StockPiler.Brew._brewOpenedBackpack ~= true
        and StockPiler.Brew._brewOwnedSession ~= true
        and StockPiler.Brew._brewApoStealth ~= true
    then
        return false
    end
    local session = GetSession()
    if session.phase == "loaded"
        and StockPiler.Brew.ValidateApothecaryPerform
        and StockPiler.Brew.ValidateApothecaryPerform() == true
    then
        return false
    end
    D("closing brew-owned apo session: " .. tostring(reason or "idle"))
    ClearSession()
    CloseApothecarySession()
    return true
end

function StockPiler.Brew.RefreshSessionAfterBrew()
    local session = GetSession()
    if session.phase ~= "loaded" then
        MaybeCloseBrewSessionIfIdle("after brew (no loaded session)")
        RefreshBrewAppearance()
        return
    end
    if StockPiler.Planner and StockPiler.Planner.InvalidatePlanCache then
        StockPiler.Planner.InvalidatePlanCache()
    end
    if StockPiler.Inventory and StockPiler.Inventory.InvalidateSnapshot then
        StockPiler.Inventory.InvalidateSnapshot()
    end
    local row = nil
    local plan = CurrentPlan({ refresh = true })
    local rows = plan and plan.rows
    if type(rows) == "table" then
        for i = 1, #rows do
            if RowMatchesSession(rows[i], session) then
                row = rows[i]
                break
            end
        end
    end
    if row and (tonumber(row.potionDeficit) or 0) <= 0 then
        ClearSession()
    else
        session.phase = "loaded"
        if row then
            session.name = row.name
        end
    end
    -- Last brew with nothing else ready: end headless/owned engine session now
    -- (do not wait for an extra idle macro click).
    MaybeCloseBrewSessionIfIdle("after brew nothing ready")
    RefreshBrewAppearance()
end

local function ChatBrewBlocked()
    if StockPiler.Inventory and StockPiler.Inventory.IsApothecary
        and not StockPiler.Inventory.IsApothecary()
    then
        if StockPiler.Print then
            StockPiler.Print(L"Brew is only available to Apothecaries.")
        end
        return
    end
    if not MaybeCloseBrewSessionIfIdle("macro idle") then
        -- Still drop blue tint if a leftover headless session left locks.
        D("idle: force apo lock release")
        CloseApothecarySession()
    end
end

--- Returns "go" to fire PerformCrafting(APOTHECARY), or "blocked" to swallow the click.
function StockPiler.Brew.TryBrewClick()
    if StockPiler.Brew.IsMacroEnabled and not StockPiler.Brew.IsMacroEnabled() then
        return "blocked"
    end
    if StockPiler.Inventory and StockPiler.Inventory.IsApothecary
        and not StockPiler.Inventory.IsApothecary()
    then
        ChatBrewBlocked()
        return "blocked"
    end
    if StockPiler.Brew.IsBusy() then
        return "blocked"
    end

    local session = GetSession()
    if session.phase == "loaded" then
        local row = FindSessionRow()
        local stillShort = row == nil or (tonumber(row.potionDeficit) or 0) > 0
        if stillShort then
            local ok = StockPiler.Brew.ValidateApothecaryPerform()
            if ok == true then
                D("macro brew potion=" .. ToNarrow((row and row.name) or session.name)
                    .. " key=" .. tostring(session.potionKey or session.rowId)
                    .. " def=" .. tostring(row and row.potionDeficit)
                    .. " craftable=" .. tostring(row and row.craftable))
                return "go"
            end
            D("session apo mismatch or empty; pick a new watch")
        else
            D("session target met; pick next")
        end
        StockPiler.Brew._lastLoad = nil
        ClearSession()
        -- Always end headless session + clear bag locks before next Load / idle.
        D("clearing apo before picking next watch")
        CloseApothecarySession()
    end

    local nextRow = StockPiler.Brew.PickReadyWatch()
    if type(nextRow) == "table" then
        D("macro load potion=" .. ToNarrow(nextRow.name)
            .. " key=" .. RowKey(nextRow)
            .. " def=" .. tostring(nextRow.potionDeficit)
            .. " craftable=" .. tostring(nextRow.craftable))
        StockPiler.Brew.BeginForRow(nextRow)
        return "blocked"
    end

    ChatBrewBlocked()
    return "blocked"
end

function StockPiler.Brew.ShowBrewTooltip(anchorWindow, anchor)
    if not Tooltips or type(Tooltips.CreateTextOnlyTooltip) ~= "function" then
        return
    end
    if anchorWindow == nil or anchorWindow == "" then
        return
    end
    Tooltips.CreateTextOnlyTooltip(anchorWindow)
    local heading = (Tooltips and Tooltips.COLOR_HEADING) or { r = 255, g = 204, b = 102 }
    local title = L"<icon00529> StockPiler Brew"
    Tooltips.SetTooltipText(1, 1, title)
    if type(Tooltips.SetTooltipColor) == "function" then
        StockPiler.TryCall("Tooltips.SetTooltipColor", Tooltips.SetTooltipColor, 1, 1, heading.r, heading.g, heading.b)
    end

    local line = 2
    local function body(text)
        Tooltips.SetTooltipText(line, 1, text, false)
        line = line + 1
    end

    if StockPiler.Inventory and StockPiler.Inventory.IsApothecary
        and not StockPiler.Inventory.IsApothecary()
    then
        body(L"Brew is only available to Apothecaries.")
    elseif StockPiler.Brew.IsBusy() then
        local session = GetSession()
        local name = AsWString(session.name)
        if name ~= L"" then
            body(L"Loading " .. name .. L" into the Apothecary.")
        else
            body(L"Loading materials into the Apothecary.")
        end
    else
        local session = GetSession()
        if session.phase == "loaded" then
            local row = FindSessionRow()
            local name = AsWString((row and row.name) or session.name)
            local have = row and tonumber(row.potionHave) or nil
            local target = row and (tonumber(row.potionMin) or tonumber(row.target)) or nil
            if name ~= L"" and have ~= nil and target ~= nil then
                body(L"Loaded: " .. name .. L" ("
                    .. towstring(tostring(have)) .. L"/"
                    .. towstring(tostring(target)) .. L"). Click to brew.")
            elseif name ~= L"" then
                body(L"Loaded: " .. name .. L". Click to brew.")
            else
                body(L"Recipe loaded. Click to brew.")
            end
        else
            local nextRow = StockPiler.Brew.PickReadyWatch()
            if type(nextRow) == "table" then
                local name = AsWString(nextRow.name)
                local have = tonumber(nextRow.potionHave) or 0
                local target = tonumber(nextRow.potionMin) or tonumber(nextRow.target) or 0
                body(L"Next: " .. name .. L" ("
                    .. towstring(tostring(have)) .. L"/"
                    .. towstring(tostring(target)) .. L"). Click to load.")
            else
                body(L"No watches ready to craft.")
            end
        end
    end
    body(L"Ctrl+click: enable/disable one-click Brew.")
    if StockPiler.Brew.IsMacroEnabled and not StockPiler.Brew.IsMacroEnabled() then
        body(L"One-click Brew is disabled.")
    end
    Tooltips.Finalize()
    Tooltips.AnchorTooltip(anchor or Tooltips.ANCHOR_WINDOW_TOP)
end

local function FailJob(message)
    local job = StockPiler.Brew._job
    if type(job) == "table" then
        local step = type(job.steps) == "table" and job.steps[job.stepIndex] or nil
        LogJob(job, "FAIL " .. tostring(message)
            .. " complete=" .. LoadLooksCompleteReason(job)
            .. (step and (" | " .. StepWhy(step)) or ""))
        DumpApoBoard("fail")
    else
        D("FAIL " .. tostring(message))
    end
    if message and StockPiler.Print then
        StockPiler.Print(message)
    end
    StockPiler.Brew._job = nil
    StockPiler.Brew._updateAccum = 0
    ClearSession()
    -- Partial / failed loads leave materials + soft-locks — end owned/headless session too.
    if StockPiler.Brew._brewOpenedApo == true
        or StockPiler.Brew._brewOwnedSession == true
        or StockPiler.Brew._brewApoStealth == true
        or ApothecaryWindowOpen()
    then
        D("closing apo after load fail")
        CloseApothecarySession()
    end
    if StockPilerTabAutoGrow and StockPilerTabAutoGrow.RefreshBrewUi then
        StockPilerTabAutoGrow.RefreshBrewUi()
    elseif StockPilerTabAutoGrow and StockPilerTabAutoGrow.UpdateRows then
        StockPilerTabAutoGrow.UpdateRows()
    end
    RefreshBrewAppearance()
end

--- Clear session and close Apothecary. No bag/plan invalidation (too heavy / unsafe on hot paths).
local function AbortBrewStation(reason)
    StockPiler.Brew._job = nil
    StockPiler.Brew._updateAccum = 0
    StockPiler.Brew._lastLoad = nil
    ClearSession()
    if StockPiler.Brew._brewOpenedApo == true
        or StockPiler.Brew._brewOwnedSession == true
        or StockPiler.Brew._brewApoStealth == true
        or ApothecaryWindowOpen()
    then
        D("closing apo: " .. tostring(reason or "abort"))
        CloseApothecarySession()
    end
    if StockPilerTabAutoGrow and StockPilerTabAutoGrow.RefreshBrewUi then
        StockPilerTabAutoGrow.RefreshBrewUi()
    elseif StockPilerTabAutoGrow and StockPilerTabAutoGrow.UpdateRows then
        StockPilerTabAutoGrow.UpdateRows()
    end
    RefreshBrewAppearance()
end

local function CompleteJob(message)
    local job = StockPiler.Brew._job
    StockPiler.Brew._job = nil
    StockPiler.Brew._updateAccum = 0
    if type(job) == "table" then
        LogJob(job, ToNarrow(message) or "complete")
        local stepsCopy = {}
        if type(job.steps) == "table" then
            for i = 1, #job.steps do
                local step = job.steps[i]
                if type(step) == "table" then
                    stepsCopy[#stepsCopy + 1] = {
                        craftingSlot = step.craftingSlot,
                        uniqueID = step.uniqueID,
                        narrowName = step.narrowName,
                        role = step.role,
                        optional = step.optional,
                        spec = step.spec,
                    }
                end
            end
        end
        if #stepsCopy > 0 then
            local recipeKey = nil
            if type(job.recipe) == "table" then
                recipeKey = job.recipe.recipeKey or job.recipe.recipeSpecKey
            end
            StockPiler.Brew._lastLoad = {
                recipeKey = recipeKey,
                rowId = job.rowId,
                potionKey = job.potionKey,
                steps = stepsCopy,
            }
        end
        local session = GetSession()
        session.phase = "loaded"
        session.rowId = job.rowId
        session.potionKey = job.potionKey or session.potionKey
        session.name = job.potionName or session.name
    else
        D(message or "complete")
    end
    if message and StockPiler.Print then
        StockPiler.Print(message)
    end
    StockPiler.Brew._job = nil
    StockPiler.Brew._updateAccum = 0
    if StockPilerTabAutoGrow and StockPilerTabAutoGrow.Refresh then
        StockPilerTabAutoGrow.Refresh()
    end
    RefreshBrewAppearance()
end

function StockPiler.Brew.CountInCraftingBag(uniqueID, narrowName, spec)
    uniqueID = tonumber(uniqueID) or 0
    narrowName = ToNarrow(narrowName)
    local total = 0
    EachCraftingBagSlot(function(_, item)
        if StockPiler.Inventory and StockPiler.Inventory.CanUseCraftingItem
            and not StockPiler.Inventory.CanUseCraftingItem(item)
        then
            return
        end
        if type(spec) == "table" then
            if ItemMatchesSpec(item, spec) then
                total = total + (tonumber(item.stackCount) or 1)
            end
        else
            local uid = tonumber(item.uniqueID) or 0
            if uniqueID > 0 and uid == uniqueID then
                total = total + (tonumber(item.stackCount) or 1)
            elseif uniqueID <= 0 and narrowName ~= "" and NameMatches(item, narrowName) then
                total = total + (tonumber(item.stackCount) or 1)
            end
        end
    end)
    return total
end

local function SortMaterials(materials)
    local sorted = {}
    for i = 1, #materials do
        sorted[i] = materials[i]
    end
    table.sort(sorted, function(a, b)
        local ra = LOAD_ROLE_ORDER[a.role] or 99
        local rb = LOAD_ROLE_ORDER[b.role] or 99
        if ra == rb then
            return (tonumber(a.uniqueID) or 0) < (tonumber(b.uniqueID) or 0)
        end
        return ra < rb
    end)
    return sorted
end

local function SortSpecSlots(slots)
    local sorted = {}
    for i = 1, #slots do
        sorted[i] = slots[i]
    end
    table.sort(sorted, function(a, b)
        local ra = LOAD_ROLE_ORDER[a.role] or 99
        local rb = LOAD_ROLE_ORDER[b.role] or 99
        if ra == rb then
            local ka, kb = "", ""
            if StockPiler.MaterialSpec and StockPiler.MaterialSpec.Key then
                ka = tostring(StockPiler.MaterialSpec.Key(a.spec) or "")
                kb = tostring(StockPiler.MaterialSpec.Key(b.spec) or "")
            end
            return ka < kb
        end
        return ra < rb
    end)
    return sorted
end

local function IsOptionalRole(role)
    return role == "extender" or role == "multiplier" or role == "stimulant"
end

local function AssignCraftingSlot(role, supplementSlot)
    if role == "container" then
        return ApothecaryWindow and ApothecaryWindow.SLOT_CONTAINER or 0, supplementSlot
    end
    if role == "main" then
        return ApothecaryWindow and ApothecaryWindow.SLOT_DETERMINENT or 1, supplementSlot
    end
    local maxSlot = ApothecaryWindow and ApothecaryWindow.SLOT_INGREDIENT3 or 4
    if supplementSlot > maxSlot then
        return nil, supplementSlot
    end
    return supplementSlot, supplementSlot + 1
end

local function SpecSlotLabel(spec)
    if type(spec) == "table" and StockPiler.MaterialSpec and StockPiler.MaterialSpec.Label then
        return ToNarrow(StockPiler.MaterialSpec.Label(spec))
    end
    return ""
end

local function BuildLoadStepsFromSpec(recipe)
    local steps = {}
    local slots = recipe.slots
    if type(slots) ~= "table" or #slots == 0 then
        return steps
    end
    local RS = StockPiler.RecipeSpec
    local supplementSlot = ApothecaryWindow and ApothecaryWindow.SLOT_INGREDIENT1 or 2
    local sorted = SortSpecSlots(slots)
    for i = 1, #sorted do
        local slot = sorted[i]
        if type(slot) == "table" and type(slot.spec) == "table" then
            local perCraft = tonumber(slot.perCraft) or 1
            if RS and RS.EffectiveSpecPerCraft then
                perCraft = RS.EffectiveSpecPerCraft(slot, slots)
            end
            if perCraft < 1 then
                perCraft = 1
            end
            local label = SpecSlotLabel(slot.spec)
            for _ = 1, perCraft do
                local craftingSlot
                craftingSlot, supplementSlot = AssignCraftingSlot(slot.role, supplementSlot)
                if craftingSlot == nil then
                    return steps
                end
                steps[#steps + 1] = {
                    craftingSlot = craftingSlot,
                    uniqueID = 0,
                    narrowName = label,
                    role = slot.role,
                    optional = IsOptionalRole(slot.role),
                    spec = slot.spec,
                }
            end
        end
    end
    return steps
end

local function BuildLoadSteps(recipe)
    local steps = {}
    if type(recipe) ~= "table" then
        return steps
    end
    if type(recipe.slots) == "table" and #recipe.slots > 0 then
        return BuildLoadStepsFromSpec(recipe)
    end
    if type(recipe.materials) ~= "table" then
        return steps
    end
    local supplementSlot = ApothecaryWindow and ApothecaryWindow.SLOT_INGREDIENT1 or 2
    local sorted = SortMaterials(recipe.materials)
    for i = 1, #sorted do
        local mat = sorted[i]
        local uid = tonumber(mat.uniqueID) or 0
        local narrowName = mat.nameNarrow or mat.match or ToNarrow(mat.name)
        if uid > 0 or narrowName ~= "" then
            local perCraft = tonumber(mat.perCraft) or 1
            if perCraft < 1 then
                perCraft = 1
            end
            if StockPiler.Inventory and StockPiler.Inventory.EffectiveMaterialPerCraft then
                perCraft = StockPiler.Inventory.EffectiveMaterialPerCraft(mat, recipe.materials)
            end
            for _ = 1, perCraft do
                local craftingSlot
                craftingSlot, supplementSlot = AssignCraftingSlot(mat.role, supplementSlot)
                if craftingSlot == nil then
                    return steps
                end
                steps[#steps + 1] = {
                    craftingSlot = craftingSlot,
                    uniqueID = uid,
                    narrowName = narrowName,
                    role = mat.role,
                    optional = StockPiler.Inventory
                        and StockPiler.Inventory.IsOptionalModifierMat
                        and StockPiler.Inventory.IsOptionalModifierMat(mat) == true,
                }
            end
        end
    end
    return steps
end

function StockPiler.Brew.DescribeMissingInCraftingBag(recipe)
    if type(recipe) ~= "table" then
        return L""
    end
    local names = {}
    local seen = {}
    local function addName(label)
        if label == nil or label == L"" or label == "" then
            return
        end
        local key = ToNarrow(label)
        if key == "" or seen[key] then
            return
        end
        seen[key] = true
        names[#names + 1] = towstring(key)
    end
    if type(recipe.slots) == "table" and #recipe.slots > 0 then
        local RS = StockPiler.RecipeSpec
        for i = 1, #recipe.slots do
            local slot = recipe.slots[i]
            if type(slot) == "table" and type(slot.spec) == "table" then
                local need = tonumber(slot.perCraft) or 1
                if RS and RS.EffectiveSpecPerCraft then
                    need = RS.EffectiveSpecPerCraft(slot, recipe.slots)
                end
                if need < 1 then
                    need = 1
                end
                if StockPiler.Brew.CountInCraftingBag(0, "", slot.spec) < need then
                    local label = ""
                    if StockPiler.MaterialSpec and StockPiler.MaterialSpec.NeedLabel then
                        label = ToNarrow(StockPiler.MaterialSpec.NeedLabel(slot.spec))
                    end
                    if label == "" then
                        label = SpecSlotLabel(slot.spec)
                    end
                    addName(label)
                end
            end
        end
    elseif type(recipe.materials) == "table" then
        for i = 1, #recipe.materials do
            local mat = recipe.materials[i]
            if type(mat) == "table" then
                local uid = tonumber(mat.uniqueID) or 0
                local need = tonumber(mat.perCraft) or 1
                local narrowName = mat.nameNarrow or mat.match or ToNarrow(mat.name)
                if StockPiler.Brew.CountInCraftingBag(uid, narrowName) < need then
                    addName(mat.name or narrowName)
                end
            end
        end
    end
    if #names == 0 then
        return L""
    end
    local joined = names[1]
    for i = 2, #names do
        joined = joined .. L", " .. names[i]
    end
    return joined
end

function StockPiler.Brew.MaterialsReadyInCraftingBag(recipe)
    if type(recipe) ~= "table" then
        return false
    end
    if type(recipe.slots) == "table" and #recipe.slots > 0 then
        local RS = StockPiler.RecipeSpec
        local any = false
        for i = 1, #recipe.slots do
            local slot = recipe.slots[i]
            if type(slot) == "table" and type(slot.spec) == "table" then
                any = true
                local need = tonumber(slot.perCraft) or 1
                if RS and RS.EffectiveSpecPerCraft then
                    need = RS.EffectiveSpecPerCraft(slot, recipe.slots)
                end
                if need < 1 then
                    need = 1
                end
                if StockPiler.Brew.CountInCraftingBag(0, "", slot.spec) < need then
                    return false
                end
            end
        end
        return any
    end
    if type(recipe.materials) ~= "table" then
        return false
    end
    for i = 1, #recipe.materials do
        local mat = recipe.materials[i]
        local uid = tonumber(mat.uniqueID) or 0
        local need = tonumber(mat.perCraft) or 1
        local narrowName = mat.nameNarrow or mat.match or ToNarrow(mat.name)
        if StockPiler.Brew.CountInCraftingBag(uid, narrowName) < need then
            return false
        end
    end
    if #recipe.materials <= 0 then
        return false
    end
    if StockPiler.Inventory and StockPiler.Inventory.RecipeIsStable then
        return StockPiler.Inventory.RecipeIsStable(recipe.materials) == true
    end
    return true
end

ApothecaryWindowOpen = function()
    return type(ApothecaryWindow) == "table"
        and ApothecaryWindow.windowName
        and DoesWindowExist(ApothecaryWindow.windowName)
        and WindowGetShowing(ApothecaryWindow.windowName)
end

--- Start an Apothecary crafting session for One-Click Load without showing UI when possible.
--- Engine AddCrafting* / PerformCrafting need SendInitCrafting, not a visible window.
local function OpenApothecary()
    if StockPiler.EnsureApothecaryHook then
        StockPiler.EnsureApothecaryHook()
    end

    -- Player (or us) already has Apo visible — reuse, do not claim stealth ownership.
    if ApothecaryWindowOpen() then
        if CraftingSystem and type(CraftingSystem.SetCurrentTradeSkill) == "function" then
            StockPiler.TryCallQuiet(
                "SetCurrentTradeSkill",
                CraftingSystem.SetCurrentTradeSkill,
                ApothecarySkill()
            )
        end
        return true
    end

    -- Prefer headless init: same as ApothecaryWindow.Show() without WindowSetShowing / backpack.
    if CraftingSystem and type(CraftingSystem.SetCurrentTradeSkill) == "function" then
        StockPiler.TryCallQuiet(
            "SetCurrentTradeSkill",
            CraftingSystem.SetCurrentTradeSkill,
            ApothecarySkill()
        )
    end
    if CraftingSystem and type(CraftingSystem.SetStaticData) == "function" then
        StockPiler.TryCallQuiet("SetStaticData", CraftingSystem.SetStaticData)
    end
    if type(SendInitCrafting) == "function" then
        StockPiler.TryCall("SendInitCrafting", SendInitCrafting, ApothecarySkill())
    end
    EnsureBrewApothecarySoftLocks(true)
    StockPiler.Brew._brewOwnedSession = true
    StockPiler.Brew._brewApoStealth = true
    HideApothecaryWindowOnly()
    D("apo session headless init skill=" .. tostring(CraftingSkillType())
        .. " state=" .. CraftingStateLabel())
    -- SessionReadyToFill is checked by RunSetupPhases; engine may take a tick.
    if CraftingSkillType() == ApothecarySkill() then
        return true
    end

    -- Fallback: stock ToggleShowing (may flash), then immediately hide UI without closing session.
    if not (CraftingSystem and type(CraftingSystem.ToggleShowing) == "function") then
        return CraftingSkillType() == ApothecarySkill()
    end
    local bagWasOpen = BackpackWindowOpen()
    local mediator = EA_BackpackUtilsMediator
    local savedShow = nil
    if type(mediator) == "table" and type(mediator.ShowBackpack) == "function" then
        savedShow = mediator.ShowBackpack
        mediator.ShowBackpack = function()
            return true
        end
    end
    StockPiler.TryCall(
        "CraftingSystem.ToggleShowing",
        CraftingSystem.ToggleShowing,
        ApothecarySkill()
    )
    if savedShow ~= nil then
        mediator.ShowBackpack = savedShow
    end

    if CraftingSkillType() ~= ApothecarySkill() and not ApothecaryWindowOpen() then
        return false
    end

    StockPiler.Brew._brewOwnedSession = true
    StockPiler.Brew._brewOpenedApo = true
    StockPiler.Brew._brewApoStealth = true
    HideApothecaryWindowOnly()
    if not bagWasOpen and BackpackWindowOpen() then
        StockPiler.Brew._brewOpenedBackpack = true
        if type(mediator) == "table" and type(mediator.HideBackpack) == "function" then
            StockPiler.TryCall("EA_BackpackUtilsMediator.HideBackpack", mediator.HideBackpack)
        end
    end
    D("apo session stealth-hide after ToggleShowing state=" .. CraftingStateLabel())
    return true
end

local function ApothecaryHasItems()
    if ServerHasCraftingItems() then
        return true
    end
    if type(ApothecaryWindow) ~= "table" or type(ApothecaryWindow.craftingData) ~= "table" then
        return false
    end
    for slotNum = 0, 4 do
        local cd = ApothecaryWindow.craftingData[slotNum]
        if type(cd) == "table" and tonumber(cd.objectId) and tonumber(cd.objectId) > 0 then
            return true
        end
    end
    return false
end

local function RequestClearApothecary()
    return ClearServerApothecarySlots()
end

local function GetSlottedItem(craftingSlot)
    craftingSlot = tonumber(craftingSlot) or -1
    if craftingSlot < 0 then
        return nil
    end
    if type(GetCraftingBackPackSlots) == "function"
        and type(EA_Window_Backpack) == "table"
        and type(EA_Window_Backpack.GetItemsFromBackpack) == "function"
    then
        local ok, slots = StockPiler.TryCallQuiet("GetCraftingBackPackSlots", GetCraftingBackPackSlots, ApothecarySkill())
        if ok and type(slots) == "table" then
            local entry = slots[craftingSlot]
            if type(entry) == "table" and entry.slot and entry.backpack then
                local bag = EA_Window_Backpack.GetItemsFromBackpack(entry.backpack)
                local item = type(bag) == "table" and bag[entry.slot] or nil
                if ItemValid(item) then
                    return item
                end
            end
        end
    end
    if type(ApothecaryWindow) == "table" and type(ApothecaryWindow.craftingData) == "table" then
        local cd = ApothecaryWindow.craftingData[craftingSlot]
        if type(cd) == "table" then
            local srcSlot = cd.sourceSlot
            local srcBag = cd.sourceBackpack
            if srcSlot ~= nil and type(EA_Window_Backpack) == "table"
                and type(EA_Window_Backpack.GetItemsFromBackpack) == "function"
            then
                local bag = EA_Window_Backpack.GetItemsFromBackpack(srcBag or CraftingBackpackType())
                local fromBag = type(bag) == "table" and bag[srcSlot] or nil
                if ItemValid(fromBag) then
                    return fromBag
                end
            end
            local objectId = tonumber(cd.objectId) or 0
            if objectId > 0 then
                if type(GetDatabaseItemData) == "function" then
                    local ok, data = StockPiler.TryCallQuiet("GetDatabaseItemData", GetDatabaseItemData, objectId)
                    if ok and ItemValid(data) then
                        return data
                    end
                end
                return { uniqueID = objectId }
            end
        end
    end
    return nil
end

local function CraftingDataOccupied(craftingSlot)
    if type(ApothecaryWindow) ~= "table" or type(ApothecaryWindow.craftingData) ~= "table" then
        return false
    end
    local cd = ApothecaryWindow.craftingData[craftingSlot]
    if type(cd) ~= "table" then
        return false
    end
    if (tonumber(cd.objectId) or 0) > 0 then
        return true
    end
    return cd.sourceSlot ~= nil
end

local function ClearStaleIngredientClientSlots()
    if type(ApothecaryWindow) ~= "table" or type(ApothecaryWindow.clientSlotList) ~= "table" then
        return
    end
    local first = ApothecaryWindow.SLOT_INGREDIENT1 or 2
    local last = ApothecaryWindow.SLOT_INGREDIENT3 or 4
    for slot = first, last do
        if ApothecaryWindow.clientSlotList[slot] ~= nil and not CraftingDataOccupied(slot) then
            ApothecaryWindow.clientSlotList[slot] = nil
        end
    end
end

local function AutoAddSlotForItem(item)
    if type(item) ~= "table" or type(ApothecaryWindow) ~= "table"
        or type(ApothecaryWindow.WouldBePossibleToAdd) ~= "function"
    then
        return nil
    end
    local tryToAdd, craftingSlot
    local ok = StockPiler.TryCallQuiet("ApothecaryWindow.WouldBePossibleToAdd", function()
        tryToAdd, craftingSlot = ApothecaryWindow.WouldBePossibleToAdd(item)
    end)
    if ok and tryToAdd == true then
        return craftingSlot
    end
    return nil
end

local function GetSlottedBagUid(craftingSlot)
    local item = GetSlottedItem(craftingSlot)
    if item then
        return tonumber(item.uniqueID) or 0
    end
    return 0
end

local function SlotHasWrongItem(step)
    if type(step) ~= "table" then
        return false
    end
    local craftingSlot = tonumber(step.craftingSlot) or -1
    if craftingSlot < 0 then
        return false
    end
    local item = GetSlottedItem(craftingSlot)
    if item == nil then
        return false
    end
    if ItemMatchesStep(item, step) then
        return false
    end
    local itemUid = tonumber(item.uniqueID) or 0
    local wantUid = tonumber(step.uniqueID) or 0
    if wantUid > 0 and itemUid == wantUid then
        return false
    end
    if type(step.spec) == "table" and item.craftingBonus == nil and wantUid <= 0 then
        -- Thin item data cannot confirm a spec match; treat occupied slot as wrong
        -- only when we already picked a UID for this step.
        return itemUid > 0
    end
    return itemUid > 0
end

local function SlotHasItem(step)
    if type(step) ~= "table" then
        return false
    end
    local craftingSlot = tonumber(step.craftingSlot) or -1
    if craftingSlot < 0 then
        return false
    end
    local item = GetSlottedItem(craftingSlot)
    if item == nil then
        return false
    end
    if ItemMatchesStep(item, step) then
        return true
    end
    local itemUid = tonumber(item.uniqueID) or 0
    local wantUid = tonumber(step.uniqueID) or 0
    if wantUid > 0 and itemUid == wantUid then
        return true
    end
    if type(step.spec) ~= "table" and wantUid <= 0 and itemUid > 0 then
        return true
    end
    return false
end

local function SlottedStabilityTotal(slots)
    local total = 0
    if type(slots) ~= "table" or not StockPiler.Inventory then
        return total
    end
    for i = 1, #slots do
        local slot = slots[i]
        if not StockPiler.Inventory.IsOptionalModifierMat(slot) then
            total = total + StockPiler.Inventory.GetMaterialStability(slot)
        end
    end
    return total
end

local function MissingLoadStepMessage(step)
    local name = ""
    if type(step) == "table" then
        if type(step.spec) == "table" then
            name = SpecSlotLabel(step.spec)
        end
        if name == "" then
            name = step.narrowName or ""
        end
    end
    if name ~= "" then
        return towstring("Missing " .. tostring(name) .. " in the Apothecary. Click Load to refill.")
    end
    return L"Missing a recipe material in the Apothecary. Click Load to refill."
end

local function ValidateAgainstLastLoad()
    local last = StockPiler.Brew._lastLoad
    if type(last) ~= "table" or type(last.steps) ~= "table" or #last.steps == 0 then
        return true
    end
    for i = 1, #last.steps do
        local step = last.steps[i]
        local craftSlot = tonumber(step.craftingSlot)
        if craftSlot ~= nil then
            if SlotHasWrongItem(step) then
                return false, L"Apothecary slot has the wrong material. Click Load."
            end
            if not SlotHasItem(step) then
                return false, MissingLoadStepMessage(step)
            end
        end
    end
    return true
end

function StockPiler.Brew.ValidateApothecaryPerform()
    if type(ApothecaryWindow) ~= "table" then
        return false, L"Apothecary window is not open."
    end
    local state = ApothecaryWindow.currentState
    local validState = ApothecaryWindow.STATE_VALID_RECIPE
    local repeatState = ApothecaryWindow.STATE_SUCCESS_REPEAT
    if state ~= validState and state ~= repeatState then
        return false, L"Recipe is incomplete or invalid."
    end
    if GameData and GameData.CraftingSuccessChance and GameData.CraftingStatus then
        local chance = tonumber(GameData.CraftingStatus.SuccessChance) or 0
        if chance == GameData.CraftingSuccessChance.LOW then
            return false, L"Recipe stability is too low to brew."
        end
        if chance == GameData.CraftingSuccessChance.INVALID then
            return false, L"Recipe is not stable enough to brew."
        end
        if chance == GameData.CraftingSuccessChance.MEDIUM then
            return false, L"Recipe is unstable. Add stabilizers or click Load."
        end
    end
    if not StockPiler.Inventory or not StockPiler.Inventory.CaptureApothecaryMaterials then
        return ValidateAgainstLastLoad()
    end
    local slots = StockPiler.Inventory.CaptureApothecaryMaterials()
    if type(slots) ~= "table" or #slots == 0 then
        return false, L"No materials in the Apothecary."
    end
    local hasMain = false
    local hasContainer = false
    for i = 1, #slots do
        if slots[i].role == "main" then
            hasMain = true
        elseif slots[i].role == "container" then
            hasContainer = true
        end
    end
    if not hasMain or not hasContainer then
        return false, L"Missing container or main ingredient."
    end
    if SlottedStabilityTotal(slots) < 0 then
        return false, L"Recipe stability is negative."
    end
    local ok, msg = ValidateAgainstLastLoad()
    if ok ~= true then
        return false, msg
    end
    return true
end

local function SessionReadyToFill()
    if ServerHasCraftingItems() or ApothecaryHasItems() then
        return false
    end
    local cs = CraftingStates()
    if cs == nil then
        return true
    end
    -- Leftover VALID_RECIPE/SUCCESS after a brew looks "ready" but slots are empty.
    -- Loading into that state skips the flask and the game rejects later adds.
    return CraftingState() == cs.ADDCONTAINER
end

local function StepSatisfied(step)
    if type(step) ~= "table" then
        return false
    end
    if SlotHasItem(step) then
        return true
    end
    -- Optional modifiers (extender, multiplier, stimulant) must still be slotted
    -- even though the game may already show VALID_RECIPE without them.
    if step.optional == true then
        return false
    end
    -- Do not trust leftover VALID_RECIPE from a previous brew. Only use the
    -- flask/main state shortcuts after this job actually sent the item.
    if step.loadIssued ~= true then
        return false
    end
    local cs = CraftingStates()
    if cs == nil then
        return false
    end
    local state = CraftingState()
    if step.role == "container" and state >= cs.ADDDETERMINENT then
        return true
    end
    if step.role == "main" and state >= cs.ADDINGREDIENT then
        return true
    end
    if step.role == "stabilizer" or step.role == "goldweed" then
        return false
    end
    return false
end

SlotLoaded = function(step)
    return StepSatisfied(step)
end

local function AdvanceCompletedSteps(job)
    if type(job) ~= "table" or type(job.steps) ~= "table" then
        return
    end
    while job.stepIndex <= #job.steps do
        local step = job.steps[job.stepIndex]
        if StepSatisfied(step) then
            LogJob(job, "skip done step craftSlot=" .. tostring(step.craftingSlot)
                .. " role=" .. tostring(step.role)
                .. " bagUid=" .. tostring(GetSlottedBagUid(step.craftingSlot)))
            job.stepIndex = job.stepIndex + 1
            job.waitTicks = 0
        else
            break
        end
    end
end

local function AllStepsLoaded(job)
    if type(job) ~= "table" or type(job.steps) ~= "table" then
        return false
    end
    for i = 1, #job.steps do
        if not StepSatisfied(job.steps[i]) then
            return false
        end
    end
    return #job.steps > 0
end

local function AllRequiredStepsLoaded(job)
    if type(job) ~= "table" or type(job.steps) ~= "table" or #job.steps == 0 then
        return false
    end
    for i = 1, #job.steps do
        local step = job.steps[i]
        if step.optional ~= true and not StepSatisfied(step) then
            return false
        end
    end
    return true
end

local function AllStepsIssued(job)
    if type(job) ~= "table" or type(job.steps) ~= "table" or #job.steps == 0 then
        return false
    end
    for i = 1, #job.steps do
        if job.steps[i].loadIssued ~= true then
            return false
        end
    end
    return true
end

local function LoadLooksComplete(job)
    -- VALID_RECIPE fires as soon as flask + main land. Supplements are
    -- still missing then; only finish after every planned step is slotted.
    return AllStepsLoaded(job)
end

local function JobShouldRelease(job)
    local cs = CraftingStates()
    if cs == nil then
        return false
    end
    local state = CraftingState()
    if state == cs.PERFORMING or state == cs.SUCCESS or state == cs.SUCCESS_REPEAT or state == cs.FAIL then
        return true
    end
    return LoadLooksComplete(job)
end

DumpApoBoard = function(tag)
    local parts = {}
    for slot = 0, 4 do
        local client = "client=nil"
        if type(ApothecaryWindow) == "table" and type(ApothecaryWindow.clientSlotList) == "table" then
            local e = ApothecaryWindow.clientSlotList[slot]
            if type(e) == "table" then
                client = "client=" .. tostring(e.backpack) .. ":" .. tostring(e.slot)
            end
        end
        local cd = "cd=nil"
        if type(ApothecaryWindow) == "table" and type(ApothecaryWindow.craftingData) == "table" then
            local row = ApothecaryWindow.craftingData[slot]
            if type(row) == "table" then
                cd = "cdId=" .. tostring(row.objectId)
                    .. " src=" .. tostring(row.sourceBackpack) .. ":" .. tostring(row.sourceSlot)
            end
        end
        parts[#parts + 1] = "s" .. tostring(slot)
            .. " srv=" .. tostring(GetServerCraftItemId(slot))
            .. " bagUid=" .. tostring(GetSlottedBagUid(slot))
            .. " " .. client .. " " .. cd
    end
    local bp = ""
    if type(GetCraftingBackPackSlots) == "function" then
        local ok, slots = StockPiler.TryCallQuiet("GetCraftingBackPackSlots", GetCraftingBackPackSlots, ApothecarySkill())
        if ok and type(slots) == "table" then
            local bpParts = {}
            for i = 0, 4 do
                local e = slots[i]
                if type(e) == "table" then
                    bpParts[#bpParts + 1] = tostring(i) .. "=" .. tostring(e.backpack) .. ":" .. tostring(e.slot)
                end
            end
            bp = " backpackSlots=[" .. table.concat(bpParts, " ") .. "]"
        else
            bp = " backpackSlots=err"
        end
    end
    D((tag or "board") .. " " .. table.concat(parts, " | ") .. bp)
end

local function DumpBagSearch(step, exclude)
    if type(step) ~= "table" then
        return
    end
    local bagType = CraftingBackpackType()
    D("bag search role=" .. tostring(step.role)
        .. " name=" .. tostring(step.narrowName)
        .. " uid=" .. tostring(step.uniqueID)
        .. " spec=" .. SpecKey(step.spec)
        .. " craftSlot=" .. tostring(step.craftingSlot)
        .. " used=" .. tostring(exclude and next(exclude) ~= nil))
    EachCraftingBagSlot(function(slot, item)
        D("  bag[" .. tostring(slot) .. "] " .. DescribeItem(item)
            .. " | " .. BagSearchReason(item, step.uniqueID, step.narrowName, step.spec, step.role, exclude, bagType, slot))
    end)
end

StepWhy = function(step)
    if type(step) ~= "table" then
        return "step=nil"
    end
    return "role=" .. tostring(step.role)
        .. " craftSlot=" .. tostring(step.craftingSlot)
        .. " uid=" .. tostring(step.uniqueID)
        .. " optional=" .. tostring(step.optional)
        .. " issued=" .. tostring(step.loadIssued)
        .. " hasItem=" .. tostring(SlotHasItem(step))
        .. " wrong=" .. tostring(SlotHasWrongItem(step))
        .. " satisfied=" .. tostring(StepSatisfied(step))
        .. " bagUid=" .. tostring(GetSlottedBagUid(step.craftingSlot))
end

LoadLooksCompleteReason = function(job)
    if AllStepsLoaded(job) then
        return "all-steps"
    end
    if IsValidRecipeState() then
        return "valid-recipe"
    end
    if AllRequiredStepsLoaded(job) then
        return "required-only"
    end
    if AllStepsIssued(job) then
        return "all-issued"
    end
    return "no"
end

local function ConfirmStepBagUse(job, step)
    if type(job) ~= "table" or type(step) ~= "table" then
        return
    end
    local bagSlot = tonumber(step.bagSlot)
    local bagType = step.bagType
    if bagSlot == nil or bagType == nil then
        return
    end
    local key = tostring(bagType) .. ":" .. tostring(bagSlot)
    job.usedBagSlots = job.usedBagSlots or {}
    job.usedBagSlots[key] = (tonumber(job.usedBagSlots[key]) or 0) + 1
    step.bagSlot = nil
    step.bagType = nil
end

local function IssueLoadStep(job, step)
    if type(ApothecaryWindow) ~= "table" or type(step) ~= "table" then
        return false
    end
    if step.loadIssued == true then
        return true
    end
    if SlotHasWrongItem(step) then
        LogJob(job, "wrong item in craftSlot=" .. tostring(step.craftingSlot)
            .. " want uid=" .. tostring(step.uniqueID)
            .. " have uid=" .. tostring(GetSlottedBagUid(step.craftingSlot)))
        return false
    end
    local backpackSlot, item, backpackType = FindCraftingBagItem(
        step.uniqueID,
        step.narrowName,
        job.usedBagSlots,
        step.spec,
        step.role
    )
    if backpackSlot == nil or item == nil then
        DumpBagSearch(step, job.usedBagSlots)
        LogJob(job, "load missing uid=" .. tostring(step.uniqueID)
            .. " name=" .. tostring(step.narrowName)
            .. " spec=" .. SpecKey(step.spec)
            .. " role=" .. tostring(step.role)
            .. " in crafting bag")
        return false
    end

    if GameData and GameData.Player then
        GameData.Player.craftingItemsDirty = true
    end
    if type(EA_Window_Backpack) == "table" and type(EA_Window_Backpack.GetItemsFromBackpack) == "function" then
        local liveBag = EA_Window_Backpack.GetItemsFromBackpack(backpackType)
        local liveItem = type(liveBag) == "table" and liveBag[backpackSlot] or nil
        if ItemValid(liveItem) then
            item = liveItem
        end
    end

    local addSlot = tonumber(step.craftingSlot) or 2
    local autoSlot = nil
    if step.role ~= "container" and step.role ~= "main" then
        ClearStaleIngredientClientSlots()
        autoSlot = AutoAddSlotForItem(item)
        local firstIng = ApothecaryWindow.SLOT_INGREDIENT1 or 2
        local lastIng = ApothecaryWindow.SLOT_INGREDIENT3 or 4
        if autoSlot ~= nil and autoSlot >= firstIng and autoSlot <= lastIng then
            addSlot = autoSlot
        elseif addSlot < firstIng or addSlot > lastIng then
            addSlot = firstIng
        end
        step.craftingSlot = addSlot
        DumpBagSearch(step, job.usedBagSlots)
        DumpApoBoard("before-add")
    end

    D("issue " .. DescribeItem(item)
        .. " bag=" .. tostring(backpackType) .. ":" .. tostring(backpackSlot)
        .. " wantSlot=" .. tostring(addSlot)
        .. " autoSlot=" .. tostring(autoSlot)
        .. " role=" .. tostring(step.role)
        .. " spec=" .. SpecKey(step.spec))

    -- AddItem plays APOTHECARY_ADD_FAILED when ItemIsAllowedInSlot is a
    -- false negative (or the bag lookup is nil). Send the same engine calls.
    if type(ApothecaryWindow.clientSlotList) == "table" then
        ApothecaryWindow.clientSlotList[addSlot] = {
            slot = backpackSlot,
            backpack = backpackType,
        }
    end
    step.uniqueID = tonumber(item.uniqueID) or step.uniqueID
    LogJob(job, "AddItem bagSlot=" .. tostring(backpackSlot)
        .. " craftSlot=" .. tostring(addSlot)
        .. " uid=" .. tostring(item.uniqueID)
        .. " role=" .. tostring(step.role)
        .. " spec=" .. SpecKey(step.spec)
        .. " gameState=" .. CraftingStateLabel())
    step.bagSlot = backpackSlot
    step.bagType = backpackType
    step.loadIssued = true
    local skill = ApothecarySkill()
    if step.role == "container" and type(AddCraftingContainer) == "function" then
        local ok, err = StockPiler.TryCall("AddCraftingContainer", AddCraftingContainer, skill, backpackSlot, backpackType)
        D("AddCraftingContainer ok=" .. tostring(ok) .. " ret=" .. tostring(err)
            .. " skill=" .. tostring(skill)
            .. " bag=" .. tostring(backpackType) .. ":" .. tostring(backpackSlot))
        return true
    end
    if type(AddCraftingItem) == "function" then
        local ok, err = StockPiler.TryCall("AddCraftingItem", AddCraftingItem, skill, addSlot, backpackSlot, backpackType)
        D("AddCraftingItem ok=" .. tostring(ok) .. " ret=" .. tostring(err)
            .. " skill=" .. tostring(skill)
            .. " craftSlot=" .. tostring(addSlot)
            .. " bag=" .. tostring(backpackType) .. ":" .. tostring(backpackSlot))
        return true
    end
    if type(ApothecaryWindow.AddItem) == "function" then
        local ok, err = StockPiler.TryCall("ApothecaryWindow.AddItem", ApothecaryWindow.AddItem, backpackSlot, addSlot, backpackType)
        D("AddItem-fallback ok=" .. tostring(ok) .. " ret=" .. tostring(err)
            .. " craftSlot=" .. tostring(addSlot)
            .. " bag=" .. tostring(backpackType) .. ":" .. tostring(backpackSlot))
        return true
    end
    D("no add API available")
    return false
end

local function BeginLoadSteps(job, reason)
    ClaimBrewOwnedSession()
    SetPhase(job, "load", reason)
    job.stepIndex = 1
    job.usedBagSlots = job.usedBagSlots or {}
end

local function RunSetupPhases(job)
    if job.phase == "reset" then
        if not job.didReset then
            job.didReset = true
            if not SessionReadyToFill() then
                LogJob(job, "clear existing loadout")
                -- Clear board only — do not hide apo/backpack mid-load.
                ClearServerApothecarySlots()
            end
        end
        if SessionReadyToFill() then
            -- Engine session is enough; visible Apo UI is not required to AddCrafting*.
            BeginLoadSteps(job, "slots empty, session ready")
        elseif ServerHasCraftingItems() or ApothecaryHasItems() then
            if job.waitTicks == 1 or job.waitTicks % 8 == 0 then
                LogJob(job, "waiting for empty ADDCONTAINER state=" .. CraftingStateLabel())
                ClearServerApothecarySlots()
            end
            if job.waitTicks > CLEAR_WAIT_TICKS then
                FailJob(L"Could not clear the Apothecary window.")
            end
            return false
        else
            SetPhase(job, "open", "need session")
        end
    end

    if job.phase == "open" then
        if not OpenApothecary() then
            if job.waitTicks > OPEN_WAIT_TICKS then
                FailJob(L"Could not open the Apothecary window.")
            elseif job.waitTicks == 1 or job.waitTicks % 10 == 0 then
                LogJob(job, "waiting for Apothecary session")
            end
            return false
        end
        if StockPiler.Brew._brewApoStealth == true then
            HideApothecaryWindowOnly()
        end
        if SessionReadyToFill() then
            BeginLoadSteps(job, "session ready (stealth)")
        else
            SetPhase(job, "clear", "session init")
        end
    end

    if job.phase == "clear" then
        if ServerHasCraftingItems() or ApothecaryHasItems() then
            if job.waitTicks == 1 or job.waitTicks % 8 == 0 then
                local cleared = RequestClearApothecary() == true
                LogJob(job, (cleared and "cleared slots" or "clear found nothing")
                    .. " state=" .. CraftingStateLabel())
            end
            if job.waitTicks > CLEAR_WAIT_TICKS then
                FailJob(L"Could not clear the Apothecary window.")
            end
            return false
        end
        if not SessionReadyToFill() then
            if job.waitTicks > OPEN_WAIT_TICKS then
                FailJob(L"Could not reset the Apothecary window.")
            end
            return false
        end
        BeginLoadSteps(job, "slots empty")
    end

    return job.phase == "load"
end

local function FinishLoadSuccess()
    CompleteJob(L"Materials loaded. Click the brew macro to brew.")
    return true
end

local function MaybeCompleteLoad(job)
    if not LoadLooksComplete(job) then
        return false
    end
    return FinishLoadSuccess()
end

function StockPiler.Brew.BeginForRow(row)
    if StockPiler.Inventory and StockPiler.Inventory.IsApothecary
        and not StockPiler.Inventory.IsApothecary()
    then
        if StockPiler.Print then
            StockPiler.Print(L"Load is only available to Apothecaries.")
        end
        return false
    end
    if StockPiler.Brew.IsBusy() then
        D("cancel previous load to start a new one")
        StockPiler.Brew._job = nil
        StockPiler.Brew._updateAccum = 0
    end
    if type(row) ~= "table" then
        return false
    end
    local craftable = tonumber(row.craftable) or 0
    if row.canLoad ~= true and craftable <= 0 then
        return false
    end
    local recipe = nil
    if type(row.specRecipe) == "table" and type(row.specRecipe.slots) == "table" and #row.specRecipe.slots > 0 then
        recipe = row.specRecipe
    elseif type(row.recipe) == "table" and type(row.recipe.slots) == "table" and #row.recipe.slots > 0 then
        recipe = row.recipe
    elseif type(row.recipe) == "table" and type(row.recipe.materials) == "table" then
        recipe = row.recipe
    end
    if type(recipe) ~= "table" then
        if StockPiler.Print then
            StockPiler.Print(L"No learned recipe for this potion.")
        end
        return false
    end
    if not StockPiler.Brew.MaterialsReadyInCraftingBag(recipe) then
        if StockPiler.Print then
            local missing = L""
            if StockPiler.Brew.DescribeMissingInCraftingBag then
                missing = StockPiler.Brew.DescribeMissingInCraftingBag(recipe)
            end
            if missing ~= nil and missing ~= L"" then
                StockPiler.Print(L"Load blocked: missing " .. missing .. L" in the crafting bag.")
            else
                StockPiler.Print(L"Move all recipe materials into the crafting bag first.")
            end
        end
        -- Stale Craftable* often picks this path after a brew; clear leftover apo loadout.
        AbortBrewStation("load blocked: materials not in crafting bag")
        return false
    end
    local steps = BuildLoadSteps(recipe)
    if #steps == 0 then
        if StockPiler.Print then
            StockPiler.Print(L"Could not build brew steps for this recipe.")
        end
        return false
    end

    local bagCount = EachCraftingBagSlot(function() end)
    D("crafting bag items=" .. tostring(bagCount))
    if type(recipe.slots) == "table" then
        for i = 1, #recipe.slots do
            local slot = recipe.slots[i]
            if type(slot) == "table" then
                D("recipe.slot[" .. tostring(i) .. "] role=" .. tostring(slot.role)
                    .. " perCraft=" .. tostring(slot.perCraft)
                    .. " spec=" .. SpecKey(slot.spec)
                    .. " label=" .. SpecSlotLabel(slot.spec))
            end
        end
    end
    EachCraftingBagSlot(function(slot, item)
        D("bag[" .. tostring(slot) .. "] " .. DescribeItem(item))
    end)
    if StockPiler.DebugEnabled == true and StockPiler.Print then
        StockPiler.Print(L"Load debug writing to logs/uilog.log (search StockPiler| [Load]).")
    end

    local stability = "?"
    if type(recipe.slots) == "table" and StockPiler.RecipeSpec and StockPiler.RecipeSpec.SpecStabilityTotal then
        stability = tostring(StockPiler.RecipeSpec.SpecStabilityTotal(recipe.slots))
    elseif StockPiler.Inventory and StockPiler.Inventory.RecipeStabilityTotal then
        stability = tostring(StockPiler.Inventory.RecipeStabilityTotal(recipe.materials))
    end

    SetSessionFromRow(row, "loading")
    StockPiler.Brew._job = {
        phase = "reset",
        rowId = row.id,
        potionKey = row.potionKey,
        potionName = row.name,
        recipe = recipe,
        steps = steps,
        stepIndex = 1,
        waitTicks = 0,
        clearRequested = false,
        didReset = false,
        usedBagSlots = {},
    }
    StockPiler.Brew._updateAccum = 0
    LogJob(StockPiler.Brew._job, "BEGIN potion=" .. tostring(row.name or row.id)
        .. " recipeKey=" .. tostring(recipe.recipeKey or recipe.recipeSpecKey or recipe.id or "?")
        .. " steps=" .. DescribeSteps(steps)
        .. " stability=" .. stability
        .. " startState=" .. CraftingStateLabel())
    StockPiler.Brew.Tick()
    return true
end

function StockPiler.Brew.OnCraftingUpdated()
    local job = StockPiler.Brew._job
    if type(job) == "table" then
        if not GameData or not GameData.CraftingStates then
            return
        end
        if CraftingSkillType() ~= ApothecarySkill() then
            return
        end
        local state = CraftingState()
        LogJob(job, "crafting event state=" .. CraftingStateLabel(state)
            .. " complete=" .. LoadLooksCompleteReason(job))
        if JobShouldRelease(job) then
            D("event release complete=" .. LoadLooksCompleteReason(job))
            DumpApoBoard("event-release")
            FinishLoadSuccess()
            return
        end
        if job.phase == "load" or job.phase == "valid" or job.phase == "clear"
            or job.phase == "open" or job.phase == "reset"
        then
            StockPiler.Brew.Tick()
        end
        return
    end
    if CraftingSkillType() ~= ApothecarySkill() then
        return
    end
    RefreshBrewAppearance()
end

function StockPiler.Brew.OnInventoryDeferred()
    local session = GetSession()
    if session.phase == "loaded" then
        StockPiler.Brew.RefreshSessionAfterBrew()
        return
    end
    RefreshBrewAppearance()
end

function StockPiler.Brew.OnCraftingSlotUpdated()
    if not StockPiler.Brew.IsBusy() then
        return
    end
    StockPiler.Brew.Tick()
end

function StockPiler.Brew.Tick()
    local job = StockPiler.Brew._job
    if type(job) ~= "table" then
        return
    end

    _craftDataCache = nil
    job.waitTicks = (tonumber(job.waitTicks) or 0) + 1
    job.totalTicks = (tonumber(job.totalTicks) or 0) + 1
    if job.totalTicks > 400 then
        FailJob(L"Load timed out.")
        return
    end

    if job.phase == "load" or job.phase == "valid" then
        if JobShouldRelease(job) then
            D("release complete=" .. LoadLooksCompleteReason(job)
                .. " state=" .. CraftingStateLabel())
            DumpApoBoard("release")
            FinishLoadSuccess()
            return
        end
    end

    if job.phase == "reset" or job.phase == "open" or job.phase == "clear" then
        if not RunSetupPhases(job) then
            return
        end
    end

    if job.phase == "load" then
        local before = job.stepIndex
        AdvanceCompletedSteps(job)
        if job.stepIndex ~= before then
            job.waitTicks = 0
            return
        end
        local step = job.steps[job.stepIndex]
        if step == nil then
            if LoadLooksComplete(job) then
                FinishLoadSuccess()
                return
            end
            local resumed = false
            for i = 1, #job.steps do
                if not StepSatisfied(job.steps[i]) then
                    job.stepIndex = i
                    job.waitTicks = 0
                    resumed = true
                    LogJob(job, "resume missing step " .. tostring(i))
                    break
                end
            end
            if not resumed then
                FinishLoadSuccess()
            end
            return
        end
        if SlotLoaded(step) then
            LogJob(job, "slot confirmed " .. StepWhy(step))
            DumpApoBoard("confirmed")
            ConfirmStepBagUse(job, step)
            job.stepIndex = job.stepIndex + 1
            job.waitTicks = 0
            return
        end
        if not step.loadIssued then
            if SlotHasWrongItem(step) then
                FailJob(L"Apothecary slot has the wrong material. Clear the window and try again.")
                return
            end
            if not IssueLoadStep(job, step) then
                FailJob(L"Missing a recipe material in the crafting bag.")
                return
            end
            job.waitTicks = 0
            return
        elseif SlotHasWrongItem(step) then
            FailJob(L"Apothecary slot has the wrong material. Clear the window and try again.")
            return
        elseif job.waitTicks == 1 then
            D("waiting after add " .. StepWhy(step)
                .. " complete=" .. LoadLooksCompleteReason(job))
            DumpApoBoard("wait1")
        elseif job.waitTicks > 0 and job.waitTicks < STEP_WAIT_TICKS and job.waitTicks % 15 == 0 then
            step.retryCount = (tonumber(step.retryCount) or 0) + 1
            if step.retryCount > 3 then
                FailJob(L"Could not add the next ingredient. Check the crafting bag for plants (not seeds).")
                return
            end
            LogJob(job, "retry add " .. StepWhy(step)
                .. " retry=" .. tostring(step.retryCount)
                .. " complete=" .. LoadLooksCompleteReason(job))
            DumpApoBoard("retry")
            if type(ApothecaryWindow.clientSlotList) == "table" and step.craftingSlot ~= nil then
                ApothecaryWindow.clientSlotList[step.craftingSlot] = nil
            end
            step.loadIssued = false
            step.bagSlot = nil
            step.bagType = nil
            return
        end
        if job.waitTicks > STEP_WAIT_TICKS then
            FailJob(L"Timed out loading materials into the Apothecary.")
        end
        return
    end

    if job.phase == "valid" then
        if MaybeCompleteLoad(job) or IsValidRecipeState() then
            CompleteJob(L"Materials loaded. Click the brew macro to brew.")
            return
        end
        local cs = CraftingStates()
        if cs and CraftingState() == cs.ADDCONTAINER and not ApothecaryHasItems() then
            CompleteJob(L"Materials loaded. Click the brew macro to brew.")
            return
        end
        if job.waitTicks > STEP_WAIT_TICKS then
            FailJob(L"Materials did not load into Apothecary slots.")
        elseif job.waitTicks % 5 == 0 then
            LogJob(job, "waiting slots loaded=" .. tostring(AllStepsLoaded(job))
                .. " valid=" .. tostring(IsValidRecipeState()))
        end
        return
    end
end

function StockPiler.Brew.OnUpdate(timeElapsed)
    if not StockPiler.Brew.IsBusy() then
        return
    end
    StockPiler.Brew._updateAccum = (StockPiler.Brew._updateAccum or 0) + (tonumber(timeElapsed) or 0)
    if StockPiler.Brew._updateAccum < TICK_INTERVAL_SEC then
        return
    end
    StockPiler.Brew._updateAccum = StockPiler.Brew._updateAccum - TICK_INTERVAL_SEC
    StockPiler.Brew.Tick()
end

function StockPiler.Brew.Initialize()
    StockPiler.Brew._job = nil
    StockPiler.Brew._updateAccum = 0
    StockPiler.Brew._lastLoad = nil
    ClearSession()
    D("Initialize")
end

function StockPiler.Brew.Shutdown()
    StockPiler.Brew._job = nil
    ClearSession()
end
