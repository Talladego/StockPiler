----------------------------------------------------------------

-- StockPilerTabAutoGrow - watched potion cultivation plan

----------------------------------------------------------------



StockPilerTabAutoGrow = {}



StockPilerTabAutoGrow.listData = {}

StockPilerTabAutoGrow.displayOrder = {}



local ICON_SCALE = 0.34

local TARGET_MAX = 200
local ENABLE_WIN = "SPTabAutoGrowEnable"
local ADDITIVES_WIN = "SPTabAutoGrowAdditives"
local AUTOBUY_WIN = "SPTabAutoGrowAutoBuy"
local BREW_MACRO_WIN = "SPTabAutoGrowBrewMacro"
local syncingUi = false
local InvalidateAutoGrowPlan
local STEPPER_BG = { 96, 86, 52 }

local function TintStepper(windowName)
    if windowName and DoesWindowExist(windowName) then
        WindowSetTintColor(windowName, STEPPER_BG[1], STEPPER_BG[2], STEPPER_BG[3])
    end
end



local STATUS_COLORS = {

    no_target = { 180, 180, 180 },

    no_recipe = { 220, 120, 120 },

    potion_stocked = { 180, 220, 180 },

    ready_to_craft = { 140, 210, 140 },

    need_crafting_bag = { 180, 200, 255 },

    restocking = { 255, 200, 120 },

    need_materials = { 220, 190, 140 },

    converting_material = { 180, 220, 160 },

    need_seeds = { 255, 180, 90 },

    need_seed = { 255, 180, 90 },

    need_spore = { 255, 180, 90 },

    buy_seed = { 255, 170, 80 },

    buy_spore = { 255, 170, 80 },

    buy_flasks = { 255, 190, 130 },

    farm_butchering = { 255, 190, 130 },

    buy_ingredients = { 255, 190, 130 },

}



local function GetSettings()

    if StockPiler.EnsureSettings then

        return StockPiler.EnsureSettings()

    end

    return StockPiler.Settings

end



local function SetIconTexture(iconWin, iconNum)

    if not DoesWindowExist(iconWin) then

        return

    end

    if iconNum and iconNum > 0 and type(GetIconData) == "function" then

        local ok, texture, x, y = StockPiler.TryCallQuiet("GetIconData", GetIconData, iconNum)

        if ok and texture and texture ~= "" then

            DynamicImageSetTexture(iconWin, texture, x or 0, y or 0)

            if type(DynamicImageSetTextureScale) == "function" then

                DynamicImageSetTextureScale(iconWin, ICON_SCALE)

            end

            WindowSetShowing(iconWin, true)

            return

        end

    end

    DynamicImageSetTexture(iconWin, "", 0, 0)

    WindowSetShowing(iconWin, false)

end



local function CultivatorDenied()
    return StockPiler.Inventory
        and StockPiler.Inventory.CultivatorState
        and StockPiler.Inventory.CultivatorState() == false
end

local function IsApothecary()
    if StockPiler.Inventory and StockPiler.Inventory.IsApothecary then
        return StockPiler.Inventory.IsApothecary() == true
    end
    return true
end

local function UpdateEnableCheckbox()
    local s = GetSettings()
    if not DoesWindowExist(ENABLE_WIN) then
        return
    end
    syncingUi = true
    ButtonSetCheckButtonFlag(ENABLE_WIN, true)
    ButtonSetDisabledFlag(ENABLE_WIN, CultivatorDenied())
    ButtonSetPressedFlag(ENABLE_WIN, s.autoGrowEnabled == true)
    syncingUi = false
end

local function UpdateAdditivesCheckbox()
    local s = GetSettings()
    if not DoesWindowExist(ADDITIVES_WIN) then
        return
    end
    syncingUi = true
    ButtonSetCheckButtonFlag(ADDITIVES_WIN, true)
    ButtonSetDisabledFlag(ADDITIVES_WIN, CultivatorDenied())
    ButtonSetPressedFlag(ADDITIVES_WIN, s.autoGrowAdditives == true)
    syncingUi = false
end

local function UpdateAutoBuyCheckbox()
    local s = GetSettings()
    if not DoesWindowExist(AUTOBUY_WIN) then
        return
    end
    syncingUi = true
    ButtonSetCheckButtonFlag(AUTOBUY_WIN, true)
    ButtonSetDisabledFlag(AUTOBUY_WIN, false)
    ButtonSetPressedFlag(AUTOBUY_WIN, s.autoBuyEnabled == true)
    syncingUi = false
end

local function ApothecaryDenied()
    return StockPiler.Inventory and StockPiler.Inventory.IsApothecary
        and not StockPiler.Inventory.IsApothecary()
end

local function UpdateBrewMacroCheckbox()
    if not DoesWindowExist(BREW_MACRO_WIN) then
        return
    end
    local enabled = true
    if StockPiler.Brew and StockPiler.Brew.IsMacroEnabled then
        enabled = StockPiler.Brew.IsMacroEnabled() == true
    end
    syncingUi = true
    ButtonSetCheckButtonFlag(BREW_MACRO_WIN, true)
    ButtonSetDisabledFlag(BREW_MACRO_WIN, ApothecaryDenied())
    ButtonSetPressedFlag(BREW_MACRO_WIN, enabled)
    syncingUi = false
end



local SEED_BUFFER_CHIP_WIN = "SPTabAutoGrowSeedBufferChip"
local SEED_BUFFER_VALUE_WIN = "SPTabAutoGrowSeedBufferChipValue"

local function UpdateSeedBufferLabel()
    local buf = 4
    if StockPiler.Planner and StockPiler.Planner.GetSeedBufferMin then
        buf = StockPiler.Planner.GetSeedBufferMin()
    end
    local text = towstring(tostring(buf))
    -- Nested under the chip so a click raise cannot cover the number.
    -- Also write the old sibling name if a stale layout still has it.
    local wins = { SEED_BUFFER_VALUE_WIN, "SPTabAutoGrowSeedBufferValue" }
    for i = 1, #wins do
        local win = wins[i]
        if DoesWindowExist(win) then
            LabelSetText(win, L"")
            LabelSetText(win, text)
            LabelSetTextColor(win, 255, 255, 255)
            if WindowSetShowing then
                WindowSetShowing(win, true)
            end
        end
    end
    if DoesWindowExist(SEED_BUFFER_CHIP_WIN) and WindowSetShowing then
        WindowSetShowing(SEED_BUFFER_CHIP_WIN, true)
    end
end

local RESERVE_CHIP_WIN = "SPTabAutoGrowReserveChip"
local RESERVE_VALUE_WIN = "SPTabAutoGrowReserveChipValue"
local BUDGET_CHIP_WIN = "SPTabAutoGrowBudgetChip"
local BUDGET_VALUE_WIN = "SPTabAutoGrowBudgetChipValue"

local function SetChipNumber(valueWin, chipWin, value)
    local text = towstring(tostring(value))
    if DoesWindowExist(valueWin) then
        LabelSetText(valueWin, L"")
        LabelSetText(valueWin, text)
        LabelSetTextColor(valueWin, 255, 255, 255)
        if WindowSetShowing then
            WindowSetShowing(valueWin, true)
        end
    end
    if DoesWindowExist(chipWin) and WindowSetShowing then
        WindowSetShowing(chipWin, true)
    end
end

local function UpdateAutoBuyChips()
    local reserve = 10
    local budget = 50
    if StockPiler.Buy and StockPiler.Buy.GetReserveGold then
        reserve = StockPiler.Buy.GetReserveGold()
    else
        local s = GetSettings()
        reserve = tonumber(s.autoBuyReserveGold) or 10
    end
    if StockPiler.Buy and StockPiler.Buy.GetBudgetGold then
        budget = StockPiler.Buy.GetBudgetGold()
    else
        local s = GetSettings()
        budget = tonumber(s.autoBuyBudgetGold) or 50
    end
    SetChipNumber(RESERVE_VALUE_WIN, RESERVE_CHIP_WIN, reserve)
    SetChipNumber(BUDGET_VALUE_WIN, BUDGET_CHIP_WIN, budget)
end






local HARVEST_WIN = "SPTabAutoGrowHarvest"
local HARVEST_COLOR_IDLE = { 92, 92, 92 }
local HARVEST_COLOR_GROWING = { 200, 160, 80 }
local HARVEST_COLOR_READY = { 255, 204, 102 }

local CRAFT_COLOR_BREW = { 140, 210, 140 }
local CRAFT_COLOR_LOAD = { 255, 220, 120 }
local CRAFT_COLOR_IDLE = { 140, 140, 140 }

local function SetButtonTextColorAll(windowName, r, g, b)
    if not windowName or not DoesWindowExist(windowName) or type(ButtonSetTextColor) ~= "function" then
        return
    end
    local states = { 0, 1, 2, 3, 4 }
    if Button and Button.ButtonState then
        states = {
            Button.ButtonState.NORMAL or 0,
            Button.ButtonState.HIGHLIGHTED or 1,
            Button.ButtonState.PRESSED or 2,
            Button.ButtonState.PRESSED_HIGHLIGHTED or 3,
            Button.ButtonState.DISABLED or 4,
        }
    end
    for i = 1, #states do
        StockPiler.TryCall("ButtonSetTextColor", ButtonSetTextColor, windowName, states[i], r, g, b)
    end
end

local function SetHarvestButtonTextColor(r, g, b)
    SetButtonTextColorAll(HARVEST_WIN, r, g, b)
end

local function UpdateHarvestButton()
    if not DoesWindowExist(HARVEST_WIN) then
        return
    end
    local state = "idle"
    if StockPiler.AutoGrow and StockPiler.AutoGrow.GetHarvestUiState then
        state = StockPiler.AutoGrow.GetHarvestUiState() or "idle"
    end
    if StockPilerTabAutoGrow._harvestUiState == state then
        return
    end
    StockPilerTabAutoGrow._harvestUiState = state
    if state == "harvest" then
        ButtonSetText(HARVEST_WIN, L"Harvest")
        ButtonSetDisabledFlag(HARVEST_WIN, false)
        SetHarvestButtonTextColor(HARVEST_COLOR_READY[1], HARVEST_COLOR_READY[2], HARVEST_COLOR_READY[3])
    elseif state == "growing" then
        ButtonSetText(HARVEST_WIN, L"Growing")
        ButtonSetDisabledFlag(HARVEST_WIN, true)
        SetHarvestButtonTextColor(HARVEST_COLOR_GROWING[1], HARVEST_COLOR_GROWING[2], HARVEST_COLOR_GROWING[3])
    else
        ButtonSetText(HARVEST_WIN, L"Idle")
        ButtonSetDisabledFlag(HARVEST_WIN, true)
        SetHarvestButtonTextColor(HARVEST_COLOR_IDLE[1], HARVEST_COLOR_IDLE[2], HARVEST_COLOR_IDLE[3])
    end
end

local function ApplyRowCraftButton(loadWin, data)
    if not loadWin or not DoesWindowExist(loadWin) then
        return
    end
    local show = data.hasRecipe == true or data.canLoad == true or data.canBrew == true
    if not show then
        WindowSetShowing(loadWin, false)
        return
    end
    WindowSetShowing(loadWin, true)
    local state = "idle"
    if StockPiler.Brew and StockPiler.Brew.GetRowCraftUiState then
        state = StockPiler.Brew.GetRowCraftUiState(data) or "idle"
    end
    if state == "brew" then
        ButtonSetText(loadWin, L"Brew")
        ButtonSetDisabledFlag(loadWin, false)
        SetButtonTextColorAll(loadWin, CRAFT_COLOR_BREW[1], CRAFT_COLOR_BREW[2], CRAFT_COLOR_BREW[3])
    elseif state == "load" then
        ButtonSetText(loadWin, L"Load")
        ButtonSetDisabledFlag(loadWin, false)
        SetButtonTextColorAll(loadWin, CRAFT_COLOR_LOAD[1], CRAFT_COLOR_LOAD[2], CRAFT_COLOR_LOAD[3])
    else
        ButtonSetText(loadWin, L"Idle")
        ButtonSetDisabledFlag(loadWin, true)
        SetButtonTextColorAll(loadWin, CRAFT_COLOR_IDLE[1], CRAFT_COLOR_IDLE[2], CRAFT_COLOR_IDLE[3])
    end
end



function StockPilerTabAutoGrow.RefreshHarvestButton()

    UpdateHarvestButton()

end



local function BuildVisibleList()

    if StockPiler.Inventory and StockPiler.Inventory.RefreshAllIfNeeded then
        StockPiler.Inventory.RefreshAllIfNeeded()
    end

    local plan = { rows = {}, queue = {} }

    if StockPiler.Planner and StockPiler.Planner.BuildPlan then

        plan = StockPiler.Planner.BuildPlan({ refresh = false })

    end



    StockPilerTabAutoGrow.listData = plan.rows or {}

    StockPilerTabAutoGrow.displayOrder = {}

    for i = 1, #StockPilerTabAutoGrow.listData do

        StockPilerTabAutoGrow.displayOrder[i] = i

    end

end



local function ApplyStatusColor(labelWin, statusKey, growable)

    local rgb = STATUS_COLORS[statusKey]

    if rgb == nil and growable then

        rgb = STATUS_COLORS.restocking

    end

    if rgb == nil then

        LabelSetTextColor(labelWin, 255, 255, 255)

        return

    end

    LabelSetTextColor(labelWin, rgb[1], rgb[2], rgb[3])

end



local function SetArrowShowing(win, show)

    if DoesWindowExist(win) then

        WindowSetShowing(win, show == true)

    end

end



local function ResetSortArrow(win, isUp)

    if not DoesWindowExist(win) then

        return

    end

    if isUp then

        DynamicImageSetTexture(win, "shared_01", 194, 55)

    else

        DynamicImageSetTexture(win, "shared_01", 203, 55)

    end

    if type(DynamicImageSetTextureDimensions) == "function" then

        DynamicImageSetTextureDimensions(win, 9, 12)

    end

end



function StockPilerTabAutoGrow.Initialize()

    LabelSetText("SPTabAutoGrowBannerTitle", L"Watch dashboard")
    LabelSetText(
        "SPTabAutoGrowBannerText",
        L"Enabled watches. Set Target#, toggle AutoGrow per potion. Planner balances cultivation by relative stock deficit."
    )

    LabelSetText("SPTabAutoGrowEnableLabel", L"Enable AutoGrow")

    LabelSetText("SPTabAutoGrowAdditivesLabel", L"Use Additives")

    LabelSetText("SPTabAutoGrowSeedBufferLabel", L"Seed buffer:")

    LabelSetText("SPTabAutoGrowAutoBuyLabel", L"AutoBuy")

    LabelSetText("SPTabAutoGrowReserveLabel", L"Reserve:")

    LabelSetText("SPTabAutoGrowBudgetLabel", L"Budget:")

    LabelSetText("SPTabAutoGrowBrewMacroLabel", L"Enable One-Click Brew")

    TintStepper("SPTabAutoGrowSeedBufferChipBg")

    TintStepper("SPTabAutoGrowReserveChipBg")

    TintStepper("SPTabAutoGrowBudgetChipBg")

    UpdateHarvestButton()

    if StockPiler.AutoGrow and StockPiler.AutoGrow.EnsureHarvestActionBound then
        StockPiler.AutoGrow.EnsureHarvestActionBound()
    end

    ButtonSetText("SPTabAutoGrowColPotion", L"Potion")

    ButtonSetText("SPTabAutoGrowColStock", L"Stock")

    ButtonSetText("SPTabAutoGrowColStatus", L"Status")

    ButtonSetText("SPTabAutoGrowColCraftable", L"Craftable*")

    ButtonSetText("SPTabAutoGrowColTarget", L"Target")

    ButtonSetText("SPTabAutoGrowColPriority", L"AutoGrow")

    ButtonSetText("SPTabAutoGrowColCraft", L"Craft")

    UpdateEnableCheckbox()

    UpdateAdditivesCheckbox()

    UpdateAutoBuyCheckbox()

    UpdateBrewMacroCheckbox()

    UpdateSeedBufferLabel()

    UpdateAutoBuyChips()

    UpdateHarvestButton()

end



function StockPilerTabAutoGrow.Refresh()

    if not DoesWindowExist("SPTabAutoGrow") then

        return

    end

    UpdateEnableCheckbox()

    UpdateAdditivesCheckbox()

    UpdateAutoBuyCheckbox()

    UpdateBrewMacroCheckbox()

    UpdateSeedBufferLabel()

    UpdateAutoBuyChips()

    UpdateHarvestButton()

    BuildVisibleList()

    if DoesWindowExist("SPTabAutoGrowList") then

        ListBoxSetDisplayOrder("SPTabAutoGrowList", {})

        ListBoxSetDisplayOrder("SPTabAutoGrowList", StockPilerTabAutoGrow.displayOrder)

        StockPilerTabAutoGrow.UpdateRows()

    end

end

function StockPilerTabAutoGrow.RefreshBrewUi()
    if not DoesWindowExist("SPTabAutoGrow") then
        return
    end
    UpdateBrewMacroCheckbox()
    StockPilerTabAutoGrow.UpdateRows()
end



function StockPilerTabAutoGrow.UpdateRows()

    if SPTabAutoGrowList.PopulatorIndices == nil then

        return

    end

    for rowIndex, dataIndex in ipairs(SPTabAutoGrowList.PopulatorIndices) do

        local data = StockPilerTabAutoGrow.listData[dataIndex]

        if data then

            local rowName = "SPTabAutoGrowListRow" .. rowIndex

            DefaultColor.SetListRowTint(rowName .. "Background", rowIndex, false)

            SetIconTexture(rowName .. "Icon", data.iconNum)

            LabelSetText(rowName .. "Name", data.displayName or data.name or L"")

            LabelSetText(rowName .. "Status", data.statusText or L"")

            LabelSetText(rowName .. "Stock", data.stockText or towstring(tostring(data.potionHave or 0)))

            LabelSetText(rowName .. "Craftable", data.craftableText or L"-")

            LabelSetText(rowName .. "Target", data.targetText or towstring(tostring(data.target or 0)))

            TintStepper(rowName .. "TargetChipBg")

            ApplyStatusColor(rowName .. "Status", data.statusKey, data.growable)

            local autoGrowWin = rowName .. "AutoGrow"
            if DoesWindowExist(autoGrowWin) then
                syncingUi = true
                ButtonSetCheckButtonFlag(autoGrowWin, true)
                ButtonSetDisabledFlag(autoGrowWin, CultivatorDenied())
                ButtonSetPressedFlag(autoGrowWin, data.autoGrow == true)
                syncingUi = false
            end

            local loadWin = rowName .. "Load"
            if not DoesWindowExist(loadWin) then
                loadWin = rowName .. "Brew"
            end
            ApplyRowCraftButton(loadWin, data)

            local target = data.target or 0

            if target > 0 and (data.potionHave or 0) < target then

                LabelSetTextColor(rowName .. "Stock", 220, 160, 60)

                LabelSetTextColor(rowName .. "Target", 220, 160, 60)

            else

                LabelSetTextColor(rowName .. "Stock", 255, 255, 255)

                LabelSetTextColor(rowName .. "Target", 255, 255, 255)

            end

            local craftable = tonumber(data.craftable) or 0
            if craftable > 0 then
                LabelSetTextColor(rowName .. "Craftable", 140, 210, 140)
            else
                LabelSetTextColor(rowName .. "Craftable", 255, 255, 255)
            end

        end

    end

end



function StockPilerTabAutoGrow.OnToggleEnabled()
    if syncingUi then
        return
    end
    if CultivatorDenied() then
        UpdateEnableCheckbox()
        if StockPiler.Print then
            StockPiler.Print(L"AutoGrow is only available to Cultivators.")
        end
        return
    end
    if not (StockPiler.AutoGrow and StockPiler.AutoGrow.SetEnabled) then
        return
    end
    -- Same setting as Ctrl-click on the harvest macro button.
    StockPiler.AutoGrow.SetEnabled(ButtonGetPressedFlag(ENABLE_WIN) == true)
end

function StockPilerTabAutoGrow.OnMouseOverEnabled()
    local tip = L"Master AutoGrow switch (same as Ctrl-click on the harvest macro). Per-potion AutoGrow boxes also need to be checked for those potions to be grown."
    if CultivatorDenied() then
        tip = L"AutoGrow is disabled: this character is not a Cultivator."
    end
    Tooltips.CreateTextOnlyTooltip(SystemData.ActiveWindow.name, tip)
    Tooltips.AnchorTooltip(Tooltips.ANCHOR_WINDOW_RIGHT)
end

function StockPilerTabAutoGrow.OnToggleAdditives()
    if syncingUi then
        return
    end
    if CultivatorDenied() then
        UpdateAdditivesCheckbox()
        return
    end
    if not (StockPiler.Additives and StockPiler.Additives.SetEnabled) then
        return
    end
    StockPiler.Additives.SetEnabled(ButtonGetPressedFlag(ADDITIVES_WIN) == true)
end

function StockPilerTabAutoGrow.OnMouseOverAdditives()
    local tip = L"When AutoGrow is on, add Soil at Germination, Watering at Seedling, then Nutrient at Flowering. Uses the highest Cultivating-skill additive in the crafting bag that you can use."
    if CultivatorDenied() then
        tip = L"Use Additives is disabled: this character is not a Cultivator."
    end
    Tooltips.CreateTextOnlyTooltip(SystemData.ActiveWindow.name, tip)
    Tooltips.AnchorTooltip(Tooltips.ANCHOR_WINDOW_RIGHT)
end

function StockPilerTabAutoGrow.OnToggleBrewMacro()
    if syncingUi then
        return
    end
    if ApothecaryDenied() then
        UpdateBrewMacroCheckbox()
        if StockPiler.Print then
            StockPiler.Print(L"One-Click Brew is only available to Apothecaries.")
        end
        return
    end
    if not (StockPiler.Brew and StockPiler.Brew.SetMacroEnabled) then
        return
    end
    StockPiler.Brew.SetMacroEnabled(ButtonGetPressedFlag(BREW_MACRO_WIN) == true)
    StockPilerTabAutoGrow.UpdateRows()
end

function StockPilerTabAutoGrow.OnMouseOverBrewMacro()
    local tip = L"When on: Brew hotbar macro and Watch Craft Load/Brew buttons. Ctrl-click the Brew macro to toggle."
    if ApothecaryDenied() then
        tip = L"One-Click Brew is disabled: this character is not an Apothecary."
    end
    Tooltips.CreateTextOnlyTooltip(SystemData.ActiveWindow.name, tip)
    Tooltips.Finalize()
    Tooltips.AnchorTooltip(Tooltips.ANCHOR_WINDOW_RIGHT)
end

function StockPilerTabAutoGrow.OnToggleAutoBuy()
    if syncingUi then
        return
    end
    if not (StockPiler.Buy and StockPiler.Buy.SetEnabled) then
        return
    end
    StockPiler.Buy.SetEnabled(ButtonGetPressedFlag(AUTOBUY_WIN) == true)
    UpdateAutoBuyCheckbox()
end

function StockPilerTabAutoGrow.OnMouseOverAutoBuy()
    Tooltips.CreateTextOnlyTooltip(SystemData.ActiveWindow.name)
    Tooltips.SetTooltipText(1, 1, L"AutoBuy")
    Tooltips.SetTooltipText(
        2,
        1,
        L"While an NPC vendor is open, buy whatever Watch already says to buy: containers, butcher mats, flasks, missing seeds, and other non-growable shortages. Independent of AutoGrow."
    )
    Tooltips.SetTooltipText(
        3,
        1,
        L"Never buys growable plants or refine byproducts. Auction House is not used. Confirm on Buy does not apply. Stops at the gold reserve or this visit's budget."
    )
    Tooltips.Finalize()
    Tooltips.AnchorTooltip(Tooltips.ANCHOR_WINDOW_RIGHT)
end

local function AdjustAutoBuyChip(kind, increase)
    if not StockPiler.Buy then
        return
    end
    if kind == "reserve" and StockPiler.Buy.AdjustReserve then
        StockPiler.Buy.AdjustReserve(increase)
    elseif kind == "budget" and StockPiler.Buy.AdjustBudget then
        StockPiler.Buy.AdjustBudget(increase)
    end
    UpdateAutoBuyChips()
end

function StockPilerTabAutoGrow.OnReserveLButtonUp()
    AdjustAutoBuyChip("reserve", true)
end

function StockPilerTabAutoGrow.OnReserveRButtonUp()
    AdjustAutoBuyChip("reserve", false)
end

function StockPilerTabAutoGrow.OnMouseOverReserve()
    Tooltips.CreateTextOnlyTooltip(SystemData.ActiveWindow.name)
    Tooltips.SetTooltipText(1, 1, L"Gold reserve")
    Tooltips.SetTooltipText(
        2,
        1,
        L"AutoBuy will not spend below this many gold. Left-click +1, right-click -1."
    )
    Tooltips.Finalize()
    Tooltips.AnchorTooltip(Tooltips.ANCHOR_WINDOW_TOP)
end

function StockPilerTabAutoGrow.OnBudgetLButtonUp()
    AdjustAutoBuyChip("budget", true)
end

function StockPilerTabAutoGrow.OnBudgetRButtonUp()
    AdjustAutoBuyChip("budget", false)
end

function StockPilerTabAutoGrow.OnMouseOverBudget()
    Tooltips.CreateTextOnlyTooltip(SystemData.ActiveWindow.name)
    Tooltips.SetTooltipText(1, 1, L"Visit budget")
    Tooltips.SetTooltipText(
        2,
        1,
        L"Gold AutoBuy may spend this vendor visit. Resets when the store window opens. Left-click +1, right-click -1."
    )
    Tooltips.Finalize()
    Tooltips.AnchorTooltip(Tooltips.ANCHOR_WINDOW_TOP)
end



function StockPilerTabAutoGrow.OnHarvest()

    if not (StockPiler.AutoGrow and StockPiler.AutoGrow.ExecuteHarvest) then

        return

    end

    if StockPiler.AutoGrow.ExecuteHarvest(true) then

        StockPilerTabAutoGrow.RefreshHarvestButton()

    end

end



function StockPilerTabAutoGrow.OnHarvestPrepare()

    if not StockPiler.AutoGrow then

        return

    end

    if StockPiler.AutoGrow.CanHarvestNow and not StockPiler.AutoGrow.CanHarvestNow() then

        return

    end

    if StockPiler.AutoGrow.EnsureHarvestActionBound then

        StockPiler.AutoGrow.EnsureHarvestActionBound()

    end

    if StockPiler.AutoGrow.SelectHarvestPlot then

        StockPiler.AutoGrow.SelectHarvestPlot(true)

    end

end



function StockPilerTabAutoGrow.OnMouseOverHarvest()
    if StockPiler.AutoGrow and StockPiler.AutoGrow.ShowHarvestTooltip then
        StockPiler.AutoGrow.ShowHarvestTooltip(SystemData.ActiveWindow.name, Tooltips.ANCHOR_WINDOW_TOP)
        return
    end
end



local function AdjustSeedBufferAndRefresh(increase)
    if StockPiler.Planner and StockPiler.Planner.AdjustSeedBuffer then
        StockPiler.Planner.AdjustSeedBuffer(increase)
    end
    UpdateSeedBufferLabel()
    InvalidateAutoGrowPlan()
    StockPilerTabAutoGrow.Refresh()
    UpdateSeedBufferLabel()
end

function StockPilerTabAutoGrow.OnSeedBufferLButtonUp()
    AdjustSeedBufferAndRefresh(true)
end

function StockPilerTabAutoGrow.OnSeedBufferRButtonUp()
    AdjustSeedBufferAndRefresh(false)
end



function StockPilerTabAutoGrow.OnMouseOverSeedBuffer()

    Tooltips.CreateTextOnlyTooltip(SystemData.ActiveWindow.name)

    Tooltips.SetTooltipText(1, 1, L"Keep this many seeds in bags")

    Tooltips.SetTooltipText(
        2,
        1,
        L"Refine target: AutoGrow may plant down to 0 seeds. When plants are in bags it converts them back up to this count. Left-click +1, right-click -1."
    )

    Tooltips.Finalize()

    Tooltips.AnchorTooltip(Tooltips.ANCHOR_WINDOW_TOP)

end



local function RowDataFromActiveChild()
    local win = SystemData.ActiveWindow and SystemData.ActiveWindow.name
    for _ = 1, 6 do
        if win == nil or win == "" or win == ENABLE_WIN then
            break
        end
        local rowIndex = WindowGetId(win)
        if rowIndex and rowIndex > 0 and DoesWindowExist("SPTabAutoGrowList") then
            local dataIndex = ListBoxGetDataIndex("SPTabAutoGrowList", rowIndex)
            local data = StockPilerTabAutoGrow.listData[dataIndex]
            if data then
                return data, win
            end
        end
        if type(WindowGetParent) == "function" then
            win = WindowGetParent(win)
        else
            break
        end
    end
    return nil, nil
end



function InvalidateAutoGrowPlan()
    if StockPiler.AutoGrow and StockPiler.AutoGrow.OnDemandChanged then
        StockPiler.AutoGrow.OnDemandChanged()
    elseif StockPiler.AutoGrow and StockPiler.AutoGrow.InvalidatePlantQueue then
        StockPiler.AutoGrow.InvalidatePlantQueue()
    end
end

function StockPilerTabAutoGrow.OnToggleRowAutoGrow()
    if syncingUi then
        return
    end
    local data, clickWin = RowDataFromActiveChild()
    if not data then
        return
    end
    local potionKey = data.potionKey or data.id
    if not potionKey or not (StockPiler.RecipeSpec and StockPiler.RecipeSpec.EnsureWatch) then
        return
    end
    local flagWin = SystemData.ActiveWindow.name
    if clickWin and string.find(tostring(clickWin), "AutoGrow", 1, true) then
        flagWin = clickWin
    end
    local watch = StockPiler.RecipeSpec.EnsureWatch(potionKey)
    if CultivatorDenied() then
        if DoesWindowExist(flagWin) then
            syncingUi = true
            ButtonSetPressedFlag(flagWin, watch.autoGrow ~= false)
            syncingUi = false
        end
        if StockPiler.Print then
            StockPiler.Print(L"AutoGrow is only available to Cultivators.")
        end
        return
    end
    watch.autoGrow = ButtonGetPressedFlag(flagWin) == true
    local s = GetSettings()
    if StockPiler.PersistActiveCharacterSettings then
        StockPiler.PersistActiveCharacterSettings(s)
    end
    InvalidateAutoGrowPlan()
    StockPilerTabAutoGrow.Refresh()
end

function StockPilerTabAutoGrow.OnMouseOverRowAutoGrow()
    local tip = L"Include this potion in AutoGrow cultivation. Uncheck to skip growing for it."
    if CultivatorDenied() then
        tip = L"AutoGrow is disabled: this character is not a Cultivator."
    end
    Tooltips.CreateTextOnlyTooltip(SystemData.ActiveWindow.name, tip)
    Tooltips.AnchorTooltip(Tooltips.ANCHOR_WINDOW_RIGHT)
end

local function AdjustTarget(increase)

    local data = RowDataFromActiveChild()

    if not data or not data.id then

        return

    end

    local s = GetSettings()

    local cur = 0
    local potionKey = data.potionKey or data.id
    if not (StockPiler.RecipeSpec and StockPiler.RecipeSpec.EnsureWatch) then
        return
    end
    local watch = StockPiler.RecipeSpec.EnsureWatch(potionKey)
    cur = tonumber(watch.targetStock) or 0

    if increase then

        cur = cur + 1

        if cur > TARGET_MAX then

            cur = TARGET_MAX

        end

    else

        cur = cur - 1

        if cur < 0 then

            cur = 0

        end

    end

    watch.targetStock = cur

    if StockPiler.PersistActiveCharacterSettings then
        StockPiler.PersistActiveCharacterSettings(s)
    end

    InvalidateAutoGrowPlan()
    StockPilerTabAutoGrow.Refresh()

    if StockPilerTabPotions and StockPilerTabPotions.Refresh then

        StockPilerTabPotions.Refresh()

    end

end



function StockPilerTabAutoGrow.OnTargetLButtonUp()

    AdjustTarget(true)

end



function StockPilerTabAutoGrow.OnTargetRButtonUp()

    AdjustTarget(false)

end



local function ShowColoredTooltipRows(rows, anchor)
    if StockPilerRecipeTooltip and StockPilerRecipeTooltip.ShowColoredRows then
        StockPilerRecipeTooltip.ShowColoredRows(
            SystemData.ActiveWindow.name,
            rows,
            anchor or Tooltips.ANCHOR_WINDOW_TOP
        )
        return
    end
    Tooltips.CreateTextOnlyTooltip(SystemData.ActiveWindow.name)
    local limit = math.min(#rows, 12)
    for i = 1, limit do
        local entry = rows[i]
        local text = type(entry) == "table" and entry.text or entry
        Tooltips.SetTooltipText(i, 1, text or L"", false)
    end
    Tooltips.Finalize()
    Tooltips.AnchorTooltip(anchor or Tooltips.ANCHOR_WINDOW_TOP)
end

local function StatusTitleColor(statusKey)
    local rgb = STATUS_COLORS[statusKey or ""]
    if type(rgb) == "table" then
        return { r = rgb[1] or 255, g = rgb[2] or 255, b = rgb[3] or 255 }
    end
    if Tooltips and Tooltips.COLOR_HEADING then
        return Tooltips.COLOR_HEADING
    end
    return nil
end

local function GrowingNoteKind(notes)
    local n = string.lower(StockPiler.ToNarrow and StockPiler.ToNarrow(notes) or tostring(notes or ""))
    if string.find(n, "needs planting", 1, true)
        or string.find(n, "converting", 1, true)
        or string.find(n, "need seed", 1, true)
    then
        return "warning"
    end
    if string.find(n, "ready to harvest", 1, true)
        or string.find(n, "growing", 1, true)
    then
        return "positive"
    end
    return "body"
end

local function FormatTooltipNumber(n)
    n = tonumber(n) or 0
    local rounded = math.floor(n * 10 + 0.5) / 10
    if math.abs(rounded - math.floor(rounded + 0.5)) < 0.05 then
        return towstring(tostring(math.floor(rounded + 0.5)))
    end
    return towstring(string.format("%.1f", rounded))
end

local function ShowCraftableHeaderTooltip()
    ShowColoredTooltipRows({
        { text = L"Craftable*", kind = "title" },
        {
            text = L"Best-case count if every brew output is this exact potion.",
            kind = "body",
        },
        {
            text = L"Hover a row for that watch's observed success rate and expected bottles.",
            kind = "meta",
        },
        {
            text = L"Other watches that share materials are not deducted (*).",
            kind = "meta",
        },
    }, Tooltips.ANCHOR_WINDOW_TOP)
end

local function ShowCraftableRowTooltip(data)
    local rows = {
        { text = L"Craftable*", kind = "title" },
    }
    local craftable = tonumber(data.craftable) or 0
    local recipe = data.recipe or data.specRecipe
    local uid = tonumber(data.uniqueID) or 0
    local RS = StockPiler.RecipeSpec
    local expected, rate, best, crafts = nil, nil, craftable, nil
    if RS and RS.ExpectedCraftableBottles and type(recipe) == "table" then
        expected, rate, best, crafts = RS.ExpectedCraftableBottles(recipe, uid)
        if best ~= nil then
            craftable = best
        end
    end
    if craftable > 0 or (crafts and crafts > 0) then
        local yield = tonumber(data.recipeYield)
        if (not yield or yield <= 0) and RS and RS.RecipeOutputYield and type(recipe) == "table" then
            yield = RS.RecipeOutputYield(recipe, uid)
        end
        local line = towstring(tostring(math.floor((craftable or 0) + 0.5))) .. L"* best-case"
        if crafts and crafts > 0 and yield and yield > 0 then
            line = line
                .. L" ("
                .. towstring(tostring(crafts))
                .. L" crafts x "
                .. FormatTooltipNumber(yield)
                .. L" yield)"
        end
        rows[#rows + 1] = { text = line, kind = "body" }
    else
        rows[#rows + 1] = {
            text = L"No crafts possible with current bag materials.",
            kind = "body",
        }
    end

    if rate ~= nil then
        local pct = math.floor(rate * 100 + 0.5)
        local attempts = tonumber(recipe and recipe.brewAttempts) or 0
        local successes = 0
        if RS and RS.OutcomeForPotion then
            local oc = RS.OutcomeForPotion(recipe, uid)
            if type(oc) == "table" then
                successes = tonumber(oc.successes) or 0
            end
        end
        local rateLine = L"Success rate "
            .. towstring(tostring(pct))
            .. L"% for this potion"
        if attempts > 0 then
            rateLine = rateLine
                .. L" ("
                .. towstring(tostring(successes))
                .. L"/"
                .. towstring(tostring(attempts))
                .. L")"
        end
        local rateKind = "meta"
        if rate < 0.5 then
            rateKind = "warning"
        end
        rows[#rows + 1] = { text = rateLine, kind = rateKind }

        if expected ~= nil and craftable > 0 then
            rows[#rows + 1] = {
                text = L"~"
                    .. FormatTooltipNumber(expected)
                    .. L" expected of this potion from current mats",
                kind = rate < 0.5 and "warning" or "body",
            }
        end

        local deficit = tonumber(data.potionDeficit) or 0
        if deficit > 0 and RS and RS.ExpectedCraftsForDeficit and type(recipe) == "table" then
            local expectedCrafts = RS.ExpectedCraftsForDeficit(deficit, recipe, uid)
            local bestCrafts = RS.CraftsNeededForDeficit and RS.CraftsNeededForDeficit(deficit, recipe) or 0
            if expectedCrafts and expectedCrafts > 0 then
                local needLine = L"Deficit "
                    .. towstring(tostring(deficit))
                    .. L" -> ~"
                    .. towstring(tostring(expectedCrafts))
                    .. L" crafts expected"
                if bestCrafts > 0 and expectedCrafts > bestCrafts then
                    needLine = needLine
                        .. L" (best-case "
                        .. towstring(tostring(bestCrafts))
                        .. L")"
                end
                rows[#rows + 1] = {
                    text = needLine,
                    kind = (rate < 0.5) and "warning" or "meta",
                }
            end
        end
    else
        rows[#rows + 1] = {
            text = L"No observed success rate yet - Craftable* is best case only.",
            kind = "meta",
        }
        rows[#rows + 1] = {
            text = L"Potent / other rarities do not fill a different watch.",
            kind = "meta",
        }
    end

    rows[#rows + 1] = {
        text = L"Other watches that share materials are not deducted (*).",
        kind = "meta",
    }
    ShowColoredTooltipRows(rows, Tooltips.ANCHOR_WINDOW_TOP)
end

function StockPilerTabAutoGrow.OnMouseOverCraftableHeader()
    ShowCraftableHeaderTooltip()
end

function StockPilerTabAutoGrow.OnCraftableHeaderClick()
end

function StockPilerTabAutoGrow.OnMouseOverCraftable()
    local data = RowDataFromActiveChild()
    if data then
        ShowCraftableRowTooltip(data)
    else
        ShowCraftableHeaderTooltip()
    end
end

function StockPilerTabAutoGrow.OnMouseOverTarget()
    ShowColoredTooltipRows({
        { text = L"Target finished potions in bags", kind = "title" },
        { text = L"Left-click +1, right-click -1.", kind = "meta" },
    }, Tooltips.ANCHOR_WINDOW_TOP)
end

function StockPilerTabAutoGrow.OnMouseOverStatus()
    local data = RowDataFromActiveChild()
    if not data then
        return
    end

    local rows = {
        {
            text = data.statusText or L"Status",
            kind = "title",
            color = StatusTitleColor(data.statusKey),
        },
    }

    local function appendMeta(text)
        if text and text ~= L"" then
            rows[#rows + 1] = { text = text, kind = "meta" }
        end
    end

    local slots = data.statusSlots
    if type(slots) == "table" and #slots > 0 then
        local craftsNeeded = tonumber(data.craftsNeeded) or 0
        local deficit = tonumber(data.potionDeficit) or 0
        local yield = tonumber(data.recipeYield) or 0
        if craftsNeeded > 0 and deficit > 0 then
            rows[#rows + 1] = {
                text = L"Need "
                    .. towstring(tostring(craftsNeeded))
                    .. L" crafts for "
                    .. towstring(tostring(deficit))
                    .. L" more of this potion.",
                kind = "body",
            }
            if yield > 0 then
                appendMeta(
                    L"Recipe yield "
                        .. towstring(tostring(yield))
                        .. L" is a best case; Potent / other rarities do not count."
                )
            end
            local RS = StockPiler.RecipeSpec
            local recipe = data.recipe or data.specRecipe
            local uid = tonumber(data.uniqueID) or 0
            if RS and RS.ExpectedCraftsForDeficit and type(recipe) == "table" then
                local expectedCrafts, rate = RS.ExpectedCraftsForDeficit(deficit, recipe, uid)
                if rate ~= nil and rate < 0.99 and expectedCrafts and expectedCrafts > craftsNeeded then
                    local pct = math.floor(rate * 100 + 0.5)
                    rows[#rows + 1] = {
                        text = L"At "
                            .. towstring(tostring(pct))
                            .. L"% success -> ~"
                            .. towstring(tostring(expectedCrafts))
                            .. L" crafts expected.",
                        kind = "warning",
                    }
                end
            end
        elseif data.statusNeedLine and data.statusNeedLine ~= L"" then
            appendMeta(data.statusNeedLine)
        end

        rows[#rows + 1] = { text = L"----------------------------------------", kind = "separator" }

        for i = 1, #slots do
            local entry = slots[i]
            if type(entry) == "table" and type(entry.spec) == "table" then
                local name = StockPiler.MaterialSpec.NeedLabel
                    and StockPiler.MaterialSpec.NeedLabel(entry.spec)
                    or StockPiler.MaterialSpec.Label(entry.spec)
                local action
                if entry.kind == "plant" then
                    if data.statusKey == "converting_material" then
                        action = L"Convert then plant "
                    else
                        action = L"Plant "
                    end
                elseif entry.kind == "convert" then
                    action = L"Convert plants for "
                elseif entry.role == "container" then
                    action = L"Buy flasks: "
                else
                    action = L"Buy "
                end
                rows[#rows + 1] = {
                    text = action .. name,
                    kind = "ingredient",
                    role = entry.role,
                }
                rows[#rows + 1] = {
                    text = L"Have "
                        .. towstring(tostring(entry.have or 0))
                        .. L" / need "
                        .. towstring(tostring(entry.need or 0)),
                    kind = "bonus",
                }
                if entry.kind == "plant" then
                    local notes = L""
                    if StockPiler.AutoGrow and StockPiler.AutoGrow.GrowingNotesForSpec then
                        notes = StockPiler.AutoGrow.GrowingNotesForSpec(entry.spec) or L""
                    end
                    if notes == L"" then
                        if data.statusKey == "converting_material" then
                            notes = L"converting plants to seeds"
                        else
                            notes = L"needs planting"
                        end
                    end
                    rows[#rows + 1] = { text = notes, kind = GrowingNoteKind(notes) }
                end
            end
        end
    elseif type(data.statusLines) == "table" and #data.statusLines > 0 then
        for i = 1, #data.statusLines do
            appendMeta(data.statusLines[i])
        end
    elseif data.statusDetail and data.statusDetail ~= L"" then
        appendMeta(data.statusDetail)
    end

    ShowColoredTooltipRows(rows, Tooltips.ANCHOR_WINDOW_TOP)
end



function StockPilerTabAutoGrow.OnLoadRow()
    StockPilerTabAutoGrow.OnBrewRow()
end

function StockPilerTabAutoGrow.OnBrewRow()
    local data = RowDataFromActiveChild()
    if not data then
        return
    end
    if StockPiler.Brew and StockPiler.Brew.OnRowCraftClick then
        StockPiler.Brew.OnRowCraftClick(data)
        return
    end
    if not IsApothecary() then
        if StockPiler.Print then
            StockPiler.Print(L"Load is only available to Apothecaries.")
        end
        return
    end
    if data.canLoad ~= true and data.canBrew ~= true then
        return
    end
    if StockPiler.Brew and StockPiler.Brew.BeginForRow then
        StockPiler.Brew.BeginForRow(data)
    end
end

function StockPilerTabAutoGrow.OnMouseOverLoad()
    StockPilerTabAutoGrow.OnMouseOverBrew()
end

function StockPilerTabAutoGrow.OnMouseOverBrew()
    local data = RowDataFromActiveChild()
    Tooltips.CreateTextOnlyTooltip(SystemData.ActiveWindow.name, nil)

    if not IsApothecary() then
        Tooltips.SetTooltipText(1, 1, L"Craft is disabled: this character is not an Apothecary.")
        Tooltips.SetTooltipText(2, 1, L"Apothecary plus Butchering or Scavenging is fine. Talisman making is not.")
    elseif StockPiler.Brew and StockPiler.Brew.IsMacroEnabled and not StockPiler.Brew.IsMacroEnabled() then
        Tooltips.SetTooltipText(1, 1, L"Idle - One-Click Brew is disabled.")
        Tooltips.SetTooltipText(2, 1, L"Enable One-Click Brew above, or Ctrl-click the Brew hotbar macro.")
    else
        local state = "idle"
        if data and StockPiler.Brew and StockPiler.Brew.GetRowCraftUiState then
            state = StockPiler.Brew.GetRowCraftUiState(data) or "idle"
        end
        if state == "brew" then
            Tooltips.SetTooltipText(1, 1, L"Brew - materials are loaded in the Apothecary.")
            Tooltips.SetTooltipText(2, 1, L"Same as the Brew hotbar macro: fires PerformCrafting.")
        elseif state == "load" then
            Tooltips.SetTooltipText(1, 1, L"Load materials into the Apothecary for this watch.")
            Tooltips.SetTooltipText(2, 1, L"Picks crafting-bag items by slot stats (same matching as AutoGrow).")
            Tooltips.SetTooltipText(3, 1, L"After Load, this button becomes Brew.")
        else
            Tooltips.SetTooltipText(1, 1, L"Idle - nothing ready to craft for this watch.")
            Tooltips.SetTooltipText(2, 1, L"Needs a stock deficit and Craftable* > 0.")
        end
    end

    Tooltips.Finalize()
    Tooltips.AnchorTooltip(Tooltips.ANCHOR_WINDOW_TOP)
end



function StockPilerTabAutoGrow.OnPriorityUp()

    local data = RowDataFromActiveChild()

    if not data or not data.id then

        return

    end

    if StockPiler.Planner and StockPiler.Planner.MovePriorityUp then

        StockPiler.Planner.MovePriorityUp(data.id)

    end

    InvalidateAutoGrowPlan()
    StockPilerTabAutoGrow.Refresh()

end



function StockPilerTabAutoGrow.OnPriorityDown()

    local data = RowDataFromActiveChild()

    if not data or not data.id then

        return

    end

    if StockPiler.Planner and StockPiler.Planner.MovePriorityDown then

        StockPiler.Planner.MovePriorityDown(data.id)

    end

    InvalidateAutoGrowPlan()
    StockPilerTabAutoGrow.Refresh()

end



function StockPilerTabAutoGrow.OnMouseOverPriorityUp()

    Tooltips.CreateTextOnlyTooltip(SystemData.ActiveWindow.name)

    Tooltips.SetTooltipText(1, 1, L"Raise priority")

    Tooltips.SetTooltipText(2, 1, L"Move this potion up in the grow queue.")

    Tooltips.Finalize()

    Tooltips.AnchorTooltip(Tooltips.ANCHOR_WINDOW_TOP)

end



function StockPilerTabAutoGrow.OnMouseOverPriorityDown()

    Tooltips.CreateTextOnlyTooltip(SystemData.ActiveWindow.name)

    Tooltips.SetTooltipText(1, 1, L"Lower priority")

    Tooltips.SetTooltipText(2, 1, L"Move this potion down in the grow queue.")

    Tooltips.Finalize()

    Tooltips.AnchorTooltip(Tooltips.ANCHOR_WINDOW_TOP)

end



local function ShowItemOrTextTooltip(itemData, title, line2, line3)

    if StockPiler.Inventory and StockPiler.Inventory.ShowItemTooltip then

        if StockPiler.Inventory.ShowItemTooltip(itemData, SystemData.ActiveWindow.name, line2) then

            return

        end

    elseif itemData ~= nil and type(Tooltips.CreateItemTooltip) == "function" then

        local ok = StockPiler.TryCall(

            "Tooltips.CreateItemTooltip", Tooltips.CreateItemTooltip,

            itemData,

            SystemData.ActiveWindow.name,

            Tooltips.ANCHOR_WINDOW_RIGHT,

            true

        )

        if ok then

            return

        end

    end

    Tooltips.CreateTextOnlyTooltip(SystemData.ActiveWindow.name)

    Tooltips.SetTooltipText(1, 1, title or L"AutoGrow")

    if line2 and line2 ~= L"" then

        Tooltips.SetTooltipText(2, 1, line2)

    end

    if line3 and line3 ~= L"" then

        Tooltips.SetTooltipText(3, 1, line3)

    end

    Tooltips.Finalize()

    Tooltips.AnchorTooltip(Tooltips.ANCHOR_WINDOW_RIGHT)

end



function StockPilerTabAutoGrow.OnMouseOverIcon()

    local data = RowDataFromActiveChild()

    if not data then

        return

    end

    local uid = tonumber(data.uniqueID) or 0

    local itemData = data.itemData

    if StockPiler.Inventory and StockPiler.Inventory.ResolvePotionItemData then

        itemData = StockPiler.Inventory.ResolvePotionItemData(data.potionKey, uid, itemData)

        if itemData then

            data.itemData = itemData

        end

    end

    local line2 = L"Have " .. towstring(tostring(data.potionHave or 0))

        .. L" / Target " .. towstring(tostring(data.potionMin or 0))

    if data.statusText and data.statusText ~= L"" then

        line2 = line2 .. L"  |  " .. data.statusText

    end

    local line3 = data.statusDetail or L""

    ShowItemOrTextTooltip(
        itemData,
        data.displayName or data.name or L"Potion",
        line2,
        line3 ~= L"" and line3 or nil
    )

end

