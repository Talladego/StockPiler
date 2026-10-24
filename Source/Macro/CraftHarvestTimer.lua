----------------------------------------------------------------
-- Craft macro harvest countdown.
-- Growing: stock Action…Cooldown wipe + Action…CooldownTimer text ("149s"),
-- same centered timer slot abilities use (m_Windows[3]).
-- Ready plant / brew icons: Action…Count (m_Windows[7]), lower-right.
-- Floating-button optional timer: /stp button timer (CraftButton).
-- User wait (buy vials/mats, garden idle): 75% red tint on Craft macro + HUD
-- (stock ability-block red blended 75% toward DefaultColor.RED from white).
----------------------------------------------------------------

StockPiler = StockPiler or {}
StockPiler.CraftHarvestTimer = StockPiler.CraftHarvestTimer or {}

local Timer = StockPiler.CraftHarvestTimer

local DISPLAY_CAP = 999
local LABEL_WIDTH = 58
local LABEL_HEIGHT = 20
local STOCK_LABEL_WIDTH = 45
local STACK_COUNT_TEXT = 7
-- ea_actionbars actionbutton.lua window indices
local COOLDOWN = 2
local COOLDOWN_TIMER = 3
local ACTION_BUTTON_BASE_ICON = 0
-- Match floating CraftButton grow wipe (black @ 50%).
local CD_TINT = { r = 0, g = 0, b = 0, a = 0.5 }
-- Stock DefaultTimerFrame cooldown label color.
local CD_TIMER_COLOR = { r = 243, g = 243, b = 16 }
-- User-block tint: 75% blend white → DefaultColor.RED (206,44,44).
Timer.BLOCK_TINT = { r = 218, g = 97, b = 97 }
Timer.CLEAR_TINT = { r = 255, g = 255, b = 255 }

Timer._acc = 0
Timer._hooked = false
Timer._orgUpdateInventory = nil
Timer._cdHooked = false
Timer._orgUpdateCooldownAnimation = nil
Timer._cdMax = 0
Timer._cdRemain = nil
Timer._cdArmed = false

local fitted = {}
-- Cooldown window names already armed for the current grow cycle.
local growCdArmed = {}

local function StageNum(key, fallback)
    local stages = GameData and GameData.CultivationStage
    if type(stages) == "table" and stages[key] ~= nil then
        return tonumber(stages[key]) or fallback
    end
    return fallback
end

local function LabelOf(button)
    local windows = button and button.m_Windows
    return windows and windows[STACK_COUNT_TEXT]
end

local function LabelName(label, button)
    if label and label.GetName then
        local name = label:GetName()
        if name ~= nil and name ~= "" then
            return name
        end
    end
    if button and button.GetName then
        local buttonName = button:GetName()
        if buttonName ~= nil and buttonName ~= "" then
            return buttonName .. "ActionCount"
        end
    end
    return nil
end

local function HarvestIconMode()
    local Macro = StockPiler.Macro
    if not Macro then
        return false
    end
    return (Macro._craftIconMode or "harvest") ~= "brew"
end

-- Filled on the first plot read during a refresh. Forward-declared.
local FillPlotSnap

--- Smallest totalTimer among planted plots that are still growing.
--- Nil when nothing is growing. Live cultivator read, same as the Craft tip.
function Timer.ShortestSeconds()
    local snap = Timer._refreshSnap
    if type(snap) == "table" then
        FillPlotSnap(snap)
        return snap.shortest
    end
    local CA = StockPiler.CultivatorAdapter
    if not (CA and CA.GetPlotInfo) then
        return nil
    end
    local n = 4
    if CA.MaxPlotSlots then
        n = tonumber(CA.MaxPlotSlots()) or n
    end
    local empty = StageNum("EMPTY", 0)
    local grown = StageNum("GROWN", 4)
    local harvestable = StageNum("HARVESTABLE", grown)
    local harvesting = StageNum("HARVESTING", 5)
    local best = nil
    for plotNum = 1, n do
        local plot = CA.GetPlotInfo(plotNum)
        if type(plot) == "table" then
            local stage = tonumber(plot.stage) or 0
            local seedUid = tonumber(plot.seedUid) or 0
            local total = tonumber(plot.totalTimer) or 0
            if seedUid > 0 and stage ~= empty and stage ~= 255
                and stage ~= grown and stage ~= harvestable and stage ~= harvesting
                and total > 0
            then
                if best == nil or total < best then
                    best = total
                end
            end
        end
    end
    return best
end

local function EachPlot(fn)
    local CA = StockPiler.CultivatorAdapter
    if not (CA and CA.GetPlotInfo) then
        return
    end
    local n = 4
    if CA.MaxPlotSlots then
        n = tonumber(CA.MaxPlotSlots()) or n
    end
    for plotNum = 1, n do
        local plot = CA.GetPlotInfo(plotNum)
        if type(plot) == "table" then
            fn(plot)
        end
    end
end

local function SeedIconNum(plot)
    local icon = tonumber(plot.seedIconNum) or 0
    if icon <= 0 and type(plot.seed) == "table" then
        icon = tonumber(plot.seed.iconNum) or 0
    end
    if icon <= 0 then
        local uid = tonumber(plot.seedUid) or 0
        local Items = StockPiler.Items
        local item = uid > 0 and Items and Items.Get and Items.Get(uid) or nil
        if type(item) == "table" then
            icon = tonumber(item.iconNum) or 0
        end
    end
    return icon
end

local function PlantIconNum(plot)
    local plantUid = tonumber(plot.plantUid) or 0
    if plantUid <= 0 then
        local SM = StockPiler.SeedMap
        local seedUid = tonumber(plot.seedUid) or 0
        if seedUid > 0 and SM and SM.PrimaryPlantForSeed then
            plantUid = tonumber(SM.PrimaryPlantForSeed(seedUid)) or 0
        end
    end
    if plantUid <= 0 then
        return 0
    end
    local Items = StockPiler.Items
    local Inv = StockPiler.Inventory
    local item = nil
    if Inv and Inv.GetSample then
        item = Inv.GetSample(plantUid)
    end
    if type(item) ~= "table" and Items and Items.GetByUid then
        item = Items.GetByUid(plantUid)
    end
    if type(item) ~= "table" and Items and Items.Get then
        item = Items.Get(plantUid)
    end
    if type(item) == "table" then
        return tonumber(item.iconNum) or 0
    end
    return 0
end

--- True when this plot can be harvested now (or the timer already hit 0 and
--- stage has not flipped to GROWN yet). Used to stop grow CD as soon as the
--- first plot is ready — do not re-arm for still-growing siblings.
local function IsPlotHarvestReady(plot)
    if type(plot) ~= "table" then
        return false
    end
    local seedUid = tonumber(plot.seedUid) or 0
    if seedUid <= 0 then
        return false
    end
    local stage = tonumber(plot.stage) or 0
    local empty = StageNum("EMPTY", 0)
    local grown = StageNum("GROWN", 4)
    local harvestable = StageNum("HARVESTABLE", grown)
    local harvesting = StageNum("HARVESTING", 5)
    if stage == empty or stage == 255 or stage == harvesting then
        return false
    end
    if stage == grown or stage == harvestable then
        return true
    end
    -- Cultivator often leaves stage mid-grow for a beat after totalTimer hits 0.
    local total = tonumber(plot.totalTimer) or 0
    return total <= 0
end

--- One cultivator walk for every plot-derived refresh field.
FillPlotSnap = function(snap)
    if type(snap) ~= "table" or snap._plotsFilled == true then
        return
    end
    snap._plotsFilled = true
    local shortest = nil
    local harvestReady = false
    local plantIcon = nil
    local seedIcon = nil
    local empty = StageNum("EMPTY", 0)
    local grown = StageNum("GROWN", 4)
    local harvestable = StageNum("HARVESTABLE", grown)
    local harvesting = StageNum("HARVESTING", 5)
    EachPlot(function(plot)
        local stage = tonumber(plot.stage) or 0
        local seedUid = tonumber(plot.seedUid) or 0
        local total = tonumber(plot.totalTimer) or 0
        if seedUid > 0 and stage ~= empty and stage ~= 255
            and stage ~= grown and stage ~= harvestable and stage ~= harvesting
            and total > 0
        then
            if shortest == nil or total < shortest then
                shortest = total
            end
        end
        if IsPlotHarvestReady(plot) then
            harvestReady = true
            if seedIcon == nil then
                local n = SeedIconNum(plot)
                if n > 0 then
                    seedIcon = n
                end
            end
            if plantIcon == nil then
                local n = PlantIconNum(plot)
                if n <= 0 then
                    n = SeedIconNum(plot)
                end
                if n > 0 then
                    plantIcon = n
                end
            end
        end
    end)
    snap.shortest = shortest
    snap.harvestReady = harvestReady
    snap.plantIcon = plantIcon
    snap.seedIcon = seedIcon
end

--- Any planted plot ready to harvest (stage or timer).
function Timer.HasHarvestReady()
    local snap = Timer._refreshSnap
    if type(snap) == "table" then
        FillPlotSnap(snap)
        return snap.harvestReady == true
    end
    local ready = false
    EachPlot(function(plot)
        if ready ~= true and IsPlotHarvestReady(plot) then
            ready = true
        end
    end)
    return ready
end

--- Icon of a plot that is already grown. Nil while every planted plot is still growing.
--- Seed art fallback for overlays.
function Timer.ReadySeedIcon()
    local snap = Timer._refreshSnap
    if type(snap) == "table" then
        FillPlotSnap(snap)
        return snap.seedIcon
    end
    local icon = nil
    EachPlot(function(plot)
        if icon ~= nil then
            return
        end
        if IsPlotHarvestReady(plot) then
            local n = SeedIconNum(plot)
            if n > 0 then
                icon = n
            end
        end
    end)
    return icon
end

--- Grown plant product icon. Falls back to seed icon when the plant art is unknown.
function Timer.ReadyPlantIcon()
    local snap = Timer._refreshSnap
    if type(snap) == "table" then
        FillPlotSnap(snap)
        return snap.plantIcon
    end
    local icon = nil
    EachPlot(function(plot)
        if icon ~= nil then
            return
        end
        if IsPlotHarvestReady(plot) then
            local n = PlantIconNum(plot)
            if n <= 0 then
                n = SeedIconNum(plot)
            end
            if n > 0 then
                icon = n
            end
        end
    end)
    return icon
end

--- Empty flask in bags that matches this brew's container slot.
local function ContainerIconForRow(row)
    local recipe = row.recipe or row.specRecipe
    local slots = type(recipe) == "table" and recipe.slots or nil
    if type(slots) ~= "table" then
        return 0
    end
    local RS = StockPiler.RecipeSpec
    local spec = nil
    for i = 1, #slots do
        local slot = slots[i]
        if type(slot) == "table" and tostring(slot.role or slot.materialRole or "") == "container" then
            if RS and RS.ResolveSlotSpec then
                spec = RS.ResolveSlotSpec(slot)
            end
            if type(spec) ~= "table" then
                spec = slot.spec
            end
            break
        end
    end
    if type(spec) ~= "table" then
        return 0
    end
    local MS = StockPiler.MaterialSpec
    local found = 0
    local Inv = StockPiler.Inventory
    if Inv and Inv.ForEachItem and MS and MS.ProductMatches then
        Inv.ForEachItem(function(item)
            if found > 0 or type(item) ~= "table" then
                return
            end
            if MS.ProductMatches(item, spec) ~= true then
                return
            end
            found = tonumber(item.iconNum) or 0
            if found <= 0 then
                local uid = tonumber(item.uniqueID) or 0
                local Items = StockPiler.Items
                local known = uid > 0 and Items and Items.GetByUid and Items.GetByUid(uid) or nil
                if type(known) == "table" then
                    found = tonumber(known.iconNum) or 0
                end
            end
        end)
    end
    return found
end

--- Icon of the potion Brew would perform. Falls back to the matching flask
--- when the potion has no catalog icon yet.
function Timer.ReadyPotionIcon()
    local snap = Timer._refreshSnap
    if type(snap) == "table" and snap._potionFilled == true then
        return snap.potionIcon
    end
    local Brew = StockPiler.Brew
    if not (Brew and Brew.PickReadyWatch) then
        return nil
    end
    local row = Brew.PickReadyWatch()
    if type(row) ~= "table" then
        return nil
    end
    local icon = tonumber(row.iconNum) or 0
    if icon <= 0 then
        local uid = tonumber(row.uniqueID) or tonumber(row.outputUid) or 0
        local Items = StockPiler.Items
        local item = uid > 0 and Items and Items.GetByUid and Items.GetByUid(uid) or nil
        if type(item) ~= "table" and uid > 0 and Items and Items.AsItemData then
            item = Items.AsItemData(uid)
        end
        if type(item) == "table" then
            icon = tonumber(item.iconNum) or 0
        end
    end
    if icon <= 0 then
        icon = ContainerIconForRow(row)
    end
    if icon <= 0 then
        icon = nil
    end
    snap = Timer._refreshSnap
    if type(snap) == "table" then
        snap._potionFilled = true
        snap.potionIcon = icon
    end
    return icon
end

local function IconMarkup(iconNum)
    iconNum = tonumber(iconNum) or 0
    if iconNum <= 0 then
        return nil
    end
    return towstring(string.format("<icon%05d>", iconNum))
end

local USER_STALL = {
    buy_ingredients = true,
    need_container_vendor = true,
    no_vendor_container = true,
    need_vendor = true,
    autobuy_off = true,
    no_vendor_seed = true,
    need_buy = true,
}

local function SeedBufferSettled()
    local Watch = StockPiler.Watch
    if not (Watch and Watch.IsSeedBufferEnabled and Watch.IsSeedBufferEnabled() == true) then
        return true
    end
    local Grow = StockPiler.Grow
    return Grow and Grow.IsSeedBufferSatisfied and Grow.IsSeedBufferSatisfied() == true
end

local function VendorBuyInProgress()
    local Watch = StockPiler.Watch
    if not (Watch and Watch.IsAutoBuyEnabled and Watch.IsAutoBuyEnabled() == true) then
        return false
    end
    local VA = StockPiler.VendorAdapter
    return VA and VA.IsStoreOpen and VA.IsStoreOpen() == true
end

local function HasPendingPlant()
    local CC = StockPiler.CraftChatAdapter
    if not (CC and CC.HasSoilPending) then
        return false
    end
    local n = 4
    local CA = StockPiler.CultivatorAdapter
    if CA and CA.MaxPlotSlots then
        n = tonumber(CA.MaxPlotSlots()) or n
    end
    for plotNum = 1, n do
        if CC.HasSoilPending(plotNum) == true then
            return true
        end
    end
    return false
end

--- Garden / buffer / buy still moving: stay icon must wait.
local function HasActiveWork()
    if Timer.ShortestSeconds() ~= nil then
        return true
    end
    if Timer.ReadySeedIcon() ~= nil then
        return true
    end
    local Grow = StockPiler.Grow
    if Grow and Grow.IsHarvestOpActive and Grow.IsHarvestOpActive() == true then
        return true
    end
    local Refine = StockPiler.Refine
    if Refine and Refine.HasOutstanding and Refine.HasOutstanding() == true then
        return true
    end
    if HasPendingPlant() then
        return true
    end
    if SeedBufferSettled() ~= true then
        return true
    end
    if VendorBuyInProgress() then
        return true
    end
    return false
end

local function PlanUserBuyInfo()
    local PS = StockPiler.PlanSnapshot
    local plan = PS and PS.Get and PS.Get()
    local rows = plan and plan.rows
    if type(rows) ~= "table" then
        return nil
    end
    local Watch = StockPiler.Watch
    local autoGrow = Watch and Watch.IsAutoGrowEnabled and Watch.IsAutoGrowEnabled() == true
    for i = 1, #rows do
        local row = rows[i]
        if type(row) == "table" then
            local sk = tostring(row.statusKey or "")
            if USER_STALL[sk] == true then
                local match = autoGrow == true
                    or row.kind == "skillup"
                    or row.skillUp == true
                    or row.addonOwned == true
                if match then
                    return {
                        key = sk,
                        text = row.statusText,
                        name = row.name,
                    }
                end
            end
        end
    end
    return nil
end

--- Why Craft is user-blocked (red tint). Nil when not waiting on the player.
--- key is a USER_STALL reason; text/name are optional plan-row hints.
function Timer.UserStayInfo()
    if HasActiveWork() == true then
        return nil
    end
    local SkillUp = StockPiler.SkillUp
    if SkillUp then
        if SkillUp.ShouldApoBrew and SkillUp.ShouldApoBrew() == true
            and SkillUp.ShouldApoBuyContainer and SkillUp.ShouldApoBuyContainer() == true
        then
            return { key = "need_container_vendor" }
        end
        local apo = tostring(SkillUp._apoStallLatch or "")
        if USER_STALL[apo] == true then
            return { key = apo }
        end
        if SkillUp.CultStallReason then
            local cult = SkillUp.CultStallReason()
            if cult ~= nil and USER_STALL[tostring(cult)] == true then
                return { key = tostring(cult) }
            end
        end
    end
    local US = StockPiler.UpgradeSeed
    if US then
        local latch = tostring(US._stallLatch or "")
        if USER_STALL[latch] == true then
            return { key = latch }
        end
        local active = US._active
        if type(active) == "table" then
            local why = tostring(active.why or "")
            if USER_STALL[why] == true then
                return {
                    key = why,
                    name = active.genus or active.name,
                }
            end
        end
    end
    return PlanUserBuyInfo()
end

--- True when SP is waiting on the player (vendor / buy) and AutoGrow has
--- nothing left to plant, harvest, refine, or buy on an open store.
function Timer.NeedsUserStay()
    local snap = Timer._refreshSnap
    if type(snap) == "table" and snap._userStayFilled == true then
        return snap.userStay == true
    end
    local stay = Timer.UserStayInfo() ~= nil
    snap = Timer._refreshSnap
    if type(snap) == "table" then
        snap._userStayFilled = true
        snap.userStay = stay
    end
    return stay
end

--- Verified Craft macro id for the current synchronous Refresh, or nil outside one.
--- Zero means the refresh checked and found no owned macro.
function Timer.SnapCraftMacroId()
    local snap = Timer._refreshSnap
    if type(snap) ~= "table" then
        return nil
    end
    return tonumber(snap.craftId) or 0
end

--- 75% red tint on an action-button base icon (or false to leave unchanged).
function Timer.ApplyActionIconBlockTint(button, blocked)
    local icon = button and button.m_Windows and button.m_Windows[ACTION_BUTTON_BASE_ICON]
    if not (icon and type(icon.SetTintColor) == "function") then
        return false
    end
    if blocked == true then
        local t = Timer.BLOCK_TINT
        icon:SetTintColor(t.r, t.g, t.b)
        return true
    end
    return false
end

--- 75% red tint on a named window (floating Craft HUD icon).
function Timer.ApplyWindowBlockTint(windowName, blocked)
    if type(windowName) ~= "string" or windowName == "" then
        return false
    end
    if type(DoesWindowExist) ~= "function" or not DoesWindowExist(windowName) then
        return false
    end
    if type(WindowSetTintColor) ~= "function" then
        return false
    end
    local t = (blocked == true) and Timer.BLOCK_TINT or Timer.CLEAR_TINT
    WindowSetTintColor(windowName, t.r, t.g, t.b)
    return true
end

local function LocaleHit(key)
    if not (StockPiler.T and key ~= nil and key ~= "") then
        return nil
    end
    local text = StockPiler.T(key)
    if text == nil or text == L"" then
        return nil
    end
    if text == L"[" .. towstring(tostring(key)) .. L"]" then
        return nil
    end
    return text
end

--- Tip / chat-friendly stay reason (no leading harvest icon).
function Timer.UserStayReasonText()
    local info = Timer.UserStayInfo()
    if type(info) ~= "table" then
        return nil
    end
    local key = tostring(info.key or "")
    if key == "" then
        return nil
    end
    if info.text ~= nil and info.text ~= L"" and info.text ~= "" then
        if type(info.text) == "wstring" then
            return info.text
        end
        return towstring(tostring(info.text))
    end
    return LocaleHit("macro.craft_tip_stay." .. key)
        or LocaleHit("plan.status." .. key)
        or towstring(key)
end

function Timer.Format(seconds)
    local n = math.floor((tonumber(seconds) or 0) + 0.5)
    if n < 0 then
        n = 0
    end
    if n > DISPLAY_CAP then
        n = DISPLAY_CAP
    end
    return towstring(tostring(n) .. "s")
end

local function FitLabel(label, button)
    local name = LabelName(label, button)
    if name == nil or fitted[name] == true then
        return
    end
    if WindowSetDimensions then
        WindowSetDimensions(name, LABEL_WIDTH, LABEL_HEIGHT)
    end
    if label.SetFont then
        local spacing = 0
        if WindowUtils and WindowUtils.FONT_DEFAULT_TEXT_LINESPACING ~= nil then
            spacing = WindowUtils.FONT_DEFAULT_TEXT_LINESPACING
        end
        label:SetFont("font_chat_text", spacing)
    end
    if label.SetTextColor then
        label:SetTextColor(255, 255, 0)
    end
    fitted[name] = true
end

local function RestoreLabel(label, button)
    local name = LabelName(label, button)
    if name ~= nil and fitted[name] == true and WindowSetDimensions then
        WindowSetDimensions(name, STOCK_LABEL_WIDTH, LABEL_HEIGHT)
    end
    if name ~= nil then
        fitted[name] = nil
    end
    if label then
        if label.SetText then
            label:SetText(L"")
        end
        if label.Show then
            label:Show(false)
        end
    end
end

local function CooldownFrame(button)
    return button and button.m_Windows and button.m_Windows[COOLDOWN]
end

local function CooldownTimerFrame(button)
    return button and button.m_Windows and button.m_Windows[COOLDOWN_TIMER]
end

-- One row per cooldown-timer window. Created the first time that window paints,
-- then reused so the per-frame hook does not allocate.
local cdPaint = {}

local function WholeSecond(remain)
    local n = math.floor((tonumber(remain) or 0) + 0.5)
    if n < 0 then
        n = 0
    end
    if n > DISPLAY_CAP then
        n = DISPLAY_CAP
    end
    return n
end

local function CooldownPaintState(timer)
    local name = timer.GetName and timer:GetName() or nil
    if name == nil or name == "" then
        return nil
    end
    local state = cdPaint[name]
    if state == nil then
        state = { sec = false, colored = false }
        cdPaint[name] = state
    end
    return state
end

local function PaintCooldownTimer(button, remain)
    local timer = CooldownTimerFrame(button)
    if type(timer) ~= "table" then
        return
    end
    local state = CooldownPaintState(timer)
    remain = tonumber(remain)
    if remain == nil or remain <= 0 then
        if state == nil or state.sec ~= false then
            if timer.SetText then
                timer:SetText(L"")
            end
            if state then
                state.sec = false
                state.colored = false
            end
        end
        if timer.Show then
            timer:Show(false)
        end
        return
    end
    if state == nil or state.colored ~= true then
        if timer.SetTextColor then
            timer:SetTextColor(CD_TIMER_COLOR.r, CD_TIMER_COLOR.g, CD_TIMER_COLOR.b)
        end
        if state then
            state.colored = true
        end
    end
    local sec = WholeSecond(remain)
    if state == nil or state.sec ~= sec then
        if timer.SetText then
            timer:SetText(Timer.Format(remain))
        end
        if state then
            state.sec = sec
        end
    end
    if timer.Show then
        timer:Show(true)
    end
end

local function ClearGrowCooldownOnButton(button)
    local cd = CooldownFrame(button)
    if type(cd) ~= "table" then
        PaintCooldownTimer(button, nil)
        return
    end
    local name = cd.GetName and cd:GetName() or nil
    if name and name ~= "" then
        growCdArmed[name] = nil
        if type(CooldownDisplaySetCooldown) == "function" then
            pcall(CooldownDisplaySetCooldown, name, 0, 0)
        end
    end
    if cd.Show then
        cd:Show(false)
    end
    PaintCooldownTimer(button, nil)
end

local function StyleGrowCooldown(cd, button)
    if type(cd) ~= "table" then
        return
    end
    if cd.SetTintColor then
        cd:SetTintColor(CD_TINT.r, CD_TINT.g, CD_TINT.b)
    elseif cd.SetTint then
        cd:SetTint(CD_TINT)
    end
    if cd.SetAlpha then
        cd:SetAlpha(CD_TINT.a)
    end
end

--- Arm square wipe once per grow cycle (and per craft slot); re-arm on timer jump.
--- Stock ActionButton.UpdateCooldownAnimation hides Action…Cooldown whenever
--- GetHotbarCooldown is 0 (macros never have one). The cooldown hook below
--- keeps Show(true) while Timer._cdArmed; arm-once still avoids SetCooldown flicker.
local function UpdateGrowCooldown(button, remain)
    remain = tonumber(remain)
    if remain == nil or remain <= 0 then
        ClearGrowCooldownOnButton(button)
        return
    end
    local cd = CooldownFrame(button)
    if type(cd) ~= "table" or type(CooldownDisplaySetCooldown) ~= "function" then
        return
    end
    local name = cd.GetName and cd:GetName() or nil
    if name == nil or name == "" then
        return
    end
    local prev = Timer._cdRemain
    local cycleRearm = Timer._cdArmed ~= true
        or (tonumber(Timer._cdMax) or 0) <= 0
        or remain > (tonumber(Timer._cdMax) or 0)
        or (prev ~= nil and remain > prev + 0.7)
    if cycleRearm then
        Timer._cdMax = remain
        Timer._cdRemain = remain
        Timer._cdArmed = true
        growCdArmed = {}
    else
        Timer._cdRemain = remain
    end
    if cycleRearm or growCdArmed[name] ~= true then
        StyleGrowCooldown(cd, button)
        if cd.Show then
            cd:Show(true)
        end
        pcall(CooldownDisplaySetCooldown, name, remain, Timer._cdMax)
        growCdArmed[name] = true
    elseif cd.Show then
        -- Hook usually owns visibility; re-assert after inventory/icon passes.
        cd:Show(true)
    end
    PaintCooldownTimer(button, remain)
end

--- Stock UpdateCooldownAnimation: if m_Cooldown<=0 and the frame is showing, it
--- Hide()s every tick. Grow wipe uses the same window with no hotbar CD, so
--- skip that path while craft grow is armed. Keep CooldownTimer text visible.
local function installCooldownHook()
    if Timer._cdHooked == true then
        return
    end
    if not ActionButton or type(ActionButton.UpdateCooldownAnimation) ~= "function" then
        return
    end
    Timer._orgUpdateCooldownAnimation = ActionButton.UpdateCooldownAnimation
    ActionButton.UpdateCooldownAnimation = function(self, timeElapsed, updateCooldown)
        -- Match the cached craft macro id. Refresh / UpdateCraftMacro re-scan
        -- it about once a second. Do not call GetMacrosData from this hook.
        if Timer._cdArmed == true and self then
            local actions = GameData and GameData.PlayerActions
            local doMacro = actions and actions.DO_MACRO
            local macro = StockPiler.Macro
            local craftId = macro and tonumber(macro.CraftMacroId) or 0
            if doMacro ~= nil and craftId > 0
                and self.m_ActionType == doMacro
                and tonumber(self.m_ActionId) == craftId
            then
                local remain = tonumber(Timer._cdRemain)
                if remain ~= nil and remain > 0 then
                    local cd = CooldownFrame(self)
                    if type(cd) == "table" and cd.Show then
                        cd:Show(true)
                    end
                    PaintCooldownTimer(self, remain)
                    return
                end
            end
        end
        return Timer._orgUpdateCooldownAnimation(self, timeElapsed, updateCooldown)
    end
    Timer._cdHooked = true
end

function Timer.Paint(button)
    local label = LabelOf(button)
    if not label then
        return
    end
    local Macro = StockPiler.Macro
    if not (Macro and Macro.IsCraftMacroButton and Macro.IsCraftMacroButton(button) == true) then
        if LabelName(label, button) ~= nil and fitted[LabelName(label, button)] == true then
            RestoreLabel(label, button)
        end
        ClearGrowCooldownOnButton(button)
        return
    end
    local overlayText = nil
    local growSeconds = nil
    if HarvestIconMode() ~= true then
        -- Brew icon is up: potion overlay only. Do not keep the harvest countdown.
        local readyIcon = Timer.ReadyPotionIcon()
        if readyIcon ~= nil then
            overlayText = IconMarkup(readyIcon)
        end
    else
        -- As soon as any plot is harvest-ready: plant icon, no grow wipe.
        -- Do not keep animating sibling plots that are still ticking.
        if Timer.HasHarvestReady() == true then
            local readyIcon = Timer.ReadyPlantIcon() or Timer.ReadySeedIcon()
            if readyIcon ~= nil then
                overlayText = IconMarkup(readyIcon)
            end
        else
            growSeconds = Timer.ShortestSeconds()
        end
    end
    UpdateGrowCooldown(button, growSeconds)
    if growSeconds == nil and Timer._cdArmed == true then
        Timer._cdMax = 0
        Timer._cdRemain = nil
        Timer._cdArmed = false
        growCdArmed = {}
    end
    -- User block: 75% red tint on enabled icon (harvest or brew latch). Re-apply
    -- each paint so stock UpdateEnabledState cannot leave grey/white on top.
    if Timer.NeedsUserStay() == true then
        Timer.ApplyActionIconBlockTint(button, true)
    end
    -- Grow seconds live on CooldownTimer (centered). Count overlay is icons only.
    if overlayText == nil or overlayText == L"" then
        if label.SetText then
            label:SetText(L"")
        end
        if label.Show then
            label:Show(false)
        end
        return
    end
    FitLabel(label, button)
    if label.SetTextColor then
        label:SetTextColor(255, 255, 255)
    end
    if label.SetText then
        label:SetText(overlayText)
    end
    if label.Show then
        label:Show(true)
    end
end

local function EachActionButton(fn)
    if not ActionBars or not ActionBars.m_Bars then
        return
    end
    for _, bar in pairs(ActionBars.m_Bars) do
        local buttons = bar and bar.m_Buttons
        if type(buttons) == "table" then
            for _, button in pairs(buttons) do
                if type(button) == "table" then
                    fn(button)
                end
            end
        end
    end
end

local function RefreshBody()
    local Macro = StockPiler.Macro
    local craftId = 0
    if Macro and Macro.GetCraftMacroId then
        craftId = tonumber(Macro.GetCraftMacroId()) or 0
    end
    -- No owned Craft macro: skip plot scans and the hotbar walk.
    if craftId == 0 then
        local CB = StockPiler.CraftButton
        if CB and CB.TickGrowVisuals then
            CB.TickGrowVisuals()
        end
        return
    end
    -- Plot, potion, and user-stay fields fill on the first read.
    Timer._refreshSnap = { craftId = craftId }
    if Macro and Macro.IsCraftMacroButton then
        EachActionButton(function(button)
            if Macro.IsCraftMacroButton(button) then
                Timer.Paint(button)
            end
        end)
    end
    -- Floating craft button: grow pie + lit harvest while plots tick.
    local CB = StockPiler.CraftButton
    if CB and CB.TickGrowVisuals then
        CB.TickGrowVisuals()
    end
    -- Harvest/Brew readiness never flips when plots start growing, so the
    -- appearance key would leave Craft on the disabled texture until the
    -- player re-places the slot. Retint when grow/ready activity changes.
    if Macro and Macro.AlignCraftEnable then
        local growLit = Timer.HasHarvestReady() == true
            or (Timer.ShortestSeconds() ~= nil)
        local userStay = Timer.NeedsUserStay() == true
        if Timer._macroGrowLit ~= growLit or Timer._macroUserStay ~= userStay then
            Timer._macroGrowLit = growLit
            Timer._macroUserStay = userStay
            pcall(
                Macro.AlignCraftEnable,
                Macro._commitCanHarvest == true,
                Macro._commitCanBrew == true
            )
        end
    end
end

function Timer.Refresh()
    Timer._refreshSnap = nil
    local ok, err = pcall(RefreshBody)
    Timer._refreshSnap = nil
    if ok ~= true and StockPiler.Debug and StockPiler.Debug.ReportProtectedCallFailure then
        StockPiler.Debug.ReportProtectedCallFailure("CraftHarvestTimer.Refresh", err, true)
    end
end

function Timer.OnUpdate(timeElapsed)
    Timer._acc = (tonumber(Timer._acc) or 0) + (tonumber(timeElapsed) or 0)
    if Timer._acc < 1 then
        return
    end
    Timer._acc = 0
    Timer.Refresh()
end

function Timer.Install()
    if Timer._hooked == true then
        return
    end
    if not ActionButton or type(ActionButton.UpdateInventory) ~= "function" then
        return
    end
    installCooldownHook()
    local org = ActionButton.UpdateInventory
    Timer._orgUpdateInventory = org
    ActionButton.UpdateInventory = function(self)
        org(self)
        if not self then
            return
        end
        -- Restore fitted countdown chrome before the DO_MACRO gate so replacing
        -- the Craft macro with an item/ability does not leave a sticky label (#35 L6).
        local function maybeRestoreFitted()
            local label = LabelOf(self)
            local name = label and LabelName(label, self)
            if name ~= nil and fitted[name] == true then
                local restored, restoreErr = pcall(RestoreLabel, label, self)
                if restored ~= true and StockPiler.Debug
                    and StockPiler.Debug.ReportProtectedCallFailure
                then
                    StockPiler.Debug.ReportProtectedCallFailure(
                        "CraftHarvestTimer.Restore", restoreErr, true)
                end
            end
        end
        local actions = GameData and GameData.PlayerActions
        local doMacro = actions and actions.DO_MACRO
        if doMacro == nil or self.m_ActionType ~= doMacro then
            maybeRestoreFitted()
            return
        end
        local Macro = StockPiler.Macro
        local craftId = Macro and tonumber(Macro.CraftMacroId) or 0
        if craftId <= 0 and Macro and Macro.GetCraftMacroId then
            local frame = tonumber(StockPiler.FrameCounter) or 0
            if Timer._craftIdFrame ~= frame then
                Timer._craftIdFrame = frame
                craftId = tonumber(Macro.GetCraftMacroId()) or 0
            end
        end
        if craftId <= 0 or self.m_ActionId ~= craftId then
            maybeRestoreFitted()
            return
        end
        local painted, paintErr = pcall(Timer.Paint, self)
        if painted ~= true and StockPiler.Debug
            and StockPiler.Debug.ReportProtectedCallFailure
        then
            StockPiler.Debug.ReportProtectedCallFailure(
                "CraftHarvestTimer.Paint", paintErr, true)
        end
    end
    Timer._hooked = true
end

function Timer.Shutdown()
    if Timer._hooked == true and ActionButton and Timer._orgUpdateInventory then
        ActionButton.UpdateInventory = Timer._orgUpdateInventory
    end
    if Timer._cdHooked == true and ActionButton and Timer._orgUpdateCooldownAnimation then
        ActionButton.UpdateCooldownAnimation = Timer._orgUpdateCooldownAnimation
    end
    Timer._hooked = false
    Timer._orgUpdateInventory = nil
    Timer._cdHooked = false
    Timer._orgUpdateCooldownAnimation = nil
    Timer._acc = 0
    Timer._cdMax = 0
    Timer._cdRemain = nil
    Timer._cdArmed = false
    growCdArmed = {}
    EachActionButton(function(button)
        local label = LabelOf(button)
        if label and fitted[LabelName(label, button) or ""] == true then
            RestoreLabel(label, button)
        end
        ClearGrowCooldownOnButton(button)
    end)
end
