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

        local ok, texture, x, y = pcall(GetIconData, iconNum)

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
    ButtonSetPressedFlag(ENABLE_WIN, s.autoGrowEnabled == true and not CultivatorDenied())
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
    ButtonSetPressedFlag(ADDITIVES_WIN, s.autoGrowAdditives == true and not CultivatorDenied())
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






local HARVEST_WIN = "SPTabAutoGrowHarvest"
local HARVEST_COLOR_IDLE = { 92, 92, 92 }
local HARVEST_COLOR_GROWING = { 200, 160, 80 }
local HARVEST_COLOR_READY = { 255, 204, 102 }

local function SetHarvestButtonTextColor(r, g, b)
    if not DoesWindowExist(HARVEST_WIN) or type(ButtonSetTextColor) ~= "function" then
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
        pcall(ButtonSetTextColor, HARVEST_WIN, states[i], r, g, b)
    end
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

    LabelSetText("SPTabAutoGrowAdditivesLabel", L"Additives")

    LabelSetText("SPTabAutoGrowSeedBufferLabel", L"Seed buffer:")

    TintStepper("SPTabAutoGrowSeedBufferChipBg")

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

    UpdateSeedBufferLabel()

    UpdateHarvestButton()

end



function StockPilerTabAutoGrow.Refresh()

    if not DoesWindowExist("SPTabAutoGrow") then

        return

    end

    UpdateEnableCheckbox()

    UpdateAdditivesCheckbox()

    UpdateSeedBufferLabel()

    UpdateHarvestButton()

    BuildVisibleList()

    if DoesWindowExist("SPTabAutoGrowList") then

        ListBoxSetDisplayOrder("SPTabAutoGrowList", {})

        ListBoxSetDisplayOrder("SPTabAutoGrowList", StockPilerTabAutoGrow.displayOrder)

        StockPilerTabAutoGrow.UpdateRows()

    end

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

            LabelSetText(rowName .. "Name", data.name or L"")

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
                ButtonSetPressedFlag(autoGrowWin, data.autoGrow == true and not CultivatorDenied())
                syncingUi = false
            end

            local loadWin = rowName .. "Load"
            if not DoesWindowExist(loadWin) then
                loadWin = rowName .. "Brew"
            end

            if data.hasRecipe == true or data.canLoad == true or data.canBrew == true or (tonumber(data.craftable) or 0) > 0 then

                WindowSetShowing(loadWin, true)

                ButtonSetText(loadWin, L"Load")

                local loadReady = IsApothecary()
                    and (data.canLoad == true or data.canBrew == true
                    or (tonumber(data.craftable) or 0) > 0)

                ButtonSetDisabledFlag(loadWin, loadReady ~= true)

            else

                WindowSetShowing(loadWin, false)

            end

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
        if DoesWindowExist(ENABLE_WIN) then
            syncingUi = true
            ButtonSetPressedFlag(ENABLE_WIN, false)
            syncingUi = false
        end
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
        if DoesWindowExist(ADDITIVES_WIN) then
            syncingUi = true
            ButtonSetPressedFlag(ADDITIVES_WIN, false)
            syncingUi = false
        end
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
        tip = L"Additives are disabled: this character is not a Cultivator."
    end
    Tooltips.CreateTextOnlyTooltip(SystemData.ActiveWindow.name, tip)
    Tooltips.AnchorTooltip(Tooltips.ANCHOR_WINDOW_RIGHT)
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
        watch.autoGrow = false
        if DoesWindowExist(flagWin) then
            syncingUi = true
            ButtonSetPressedFlag(flagWin, false)
            syncingUi = false
        end
        if StockPiler.Print then
            StockPiler.Print(L"AutoGrow is only available to Cultivators.")
        end
        local s = GetSettings()
        if StockPiler.PersistActiveCharacterSettings then
            StockPiler.PersistActiveCharacterSettings(s)
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



local function ShowCraftableTooltip()
    Tooltips.CreateTextOnlyTooltip(SystemData.ActiveWindow.name)
    Tooltips.SetTooltipText(1, 1, L"Craftable*")
    Tooltips.SetTooltipText(
        2,
        1,
        L"Best-case count if every brew output is this exact potion."
    )
    Tooltips.SetTooltipText(
        3,
        1,
        L"Potent / other rarities do not fill this watch, so reaching Target# can take more brews (and more plants) than this number."
    )
    Tooltips.SetTooltipText(
        4,
        1,
        L"Other watches that share materials are not deducted (*)."
    )
    Tooltips.Finalize()
    Tooltips.AnchorTooltip(Tooltips.ANCHOR_WINDOW_TOP)
end

function StockPilerTabAutoGrow.OnMouseOverCraftableHeader()
    ShowCraftableTooltip()
end

function StockPilerTabAutoGrow.OnCraftableHeaderClick()
end

function StockPilerTabAutoGrow.OnMouseOverCraftable()
    ShowCraftableTooltip()
end

function StockPilerTabAutoGrow.OnMouseOverTarget()

    Tooltips.CreateTextOnlyTooltip(SystemData.ActiveWindow.name)

    Tooltips.SetTooltipText(1, 1, L"Target finished potions in bags")

    Tooltips.SetTooltipText(2, 1, L"Left-click +1, right-click -1.")

    Tooltips.Finalize()

    Tooltips.AnchorTooltip(Tooltips.ANCHOR_WINDOW_TOP)

end



function StockPilerTabAutoGrow.OnMouseOverStatus()

    local data = RowDataFromActiveChild()

    if not data then

        return

    end

    Tooltips.CreateTextOnlyTooltip(SystemData.ActiveWindow.name)

    local lines = {}
    lines[#lines + 1] = data.statusText or L"Status"
    local slots = data.statusSlots
    if type(slots) == "table" and #slots > 0 then
        if data.statusNeedLine and data.statusNeedLine ~= L"" then
            lines[#lines + 1] = data.statusNeedLine
        end
        for i = 1, #slots do
            local entry = slots[i]
            if type(entry) == "table" and type(entry.spec) == "table" then
                local name = StockPiler.MaterialSpec.NeedLabel
                    and StockPiler.MaterialSpec.NeedLabel(entry.spec)
                    or StockPiler.MaterialSpec.Label(entry.spec)
                local counts = towstring(tostring(entry.have or 0)) .. L"/" .. towstring(tostring(entry.need or 0))
                local line
                if entry.kind == "plant" then
                    line = L"Plant " .. name .. L" (" .. counts .. L")"
                    if data.statusKey == "converting_material" then
                        line = L"Convert then plant " .. name .. L" (" .. counts .. L")"
                    end
                    if StockPiler.AutoGrow and StockPiler.AutoGrow.GrowingNotesForSpec then
                        local notes = StockPiler.AutoGrow.GrowingNotesForSpec(entry.spec)
                        if notes and notes ~= L"" then
                            line = line .. L" -- " .. notes
                        elseif data.statusKey == "converting_material" then
                            line = line .. L" -- converting plants to seeds"
                        else
                            line = line .. L" -- needs planting"
                        end
                    end
                elseif entry.kind == "convert" then
                    line = L"Convert plants for " .. name .. L" (" .. counts .. L")"
                elseif entry.role == "container" then
                    line = L"Buy flasks: " .. name .. L" (" .. counts .. L")"
                else
                    line = L"Buy " .. name .. L" (" .. counts .. L")"
                end
                lines[#lines + 1] = line
            end
        end
    elseif type(data.statusLines) == "table" and #data.statusLines > 0 then
        for i = 1, #data.statusLines do
            lines[#lines + 1] = data.statusLines[i]
        end
    elseif data.statusDetail and data.statusDetail ~= L"" then
        lines[#lines + 1] = data.statusDetail
    end

    local limit = math.min(#lines, 12)
    for i = 1, limit do
        Tooltips.SetTooltipText(i, 1, lines[i])
    end

    Tooltips.Finalize()

    Tooltips.AnchorTooltip(Tooltips.ANCHOR_WINDOW_TOP)

end



function StockPilerTabAutoGrow.OnLoadRow()
    StockPilerTabAutoGrow.OnBrewRow()
end

function StockPilerTabAutoGrow.OnBrewRow()

    if not IsApothecary() then
        if StockPiler.Print then
            StockPiler.Print(L"Load is only available to Apothecaries.")
        end
        return
    end

    local data = RowDataFromActiveChild()

    if not data or (data.canLoad ~= true and data.canBrew ~= true and (tonumber(data.craftable) or 0) <= 0) then

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

        Tooltips.SetTooltipText(1, 1, L"Load is disabled: this character is not an Apothecary.")

        Tooltips.SetTooltipText(2, 1, L"Apothecary plus Butchering or Scavenging is fine. Talisman making is not.")

    elseif data and (data.canLoad == true or data.canBrew == true or (tonumber(data.craftable) or 0) > 0) then

        Tooltips.SetTooltipText(1, 1, L"Load materials into the Apothecary")

        Tooltips.SetTooltipText(2, 1, L"Picks crafting-bag items by slot stats (same matching as AutoGrow), not a fixed item id.")

        Tooltips.SetTooltipText(3, 1, L"Brew in the Apothecary window after Load.")

    else

        Tooltips.SetTooltipText(1, 1, L"Load")

        Tooltips.SetTooltipText(2, 1, L"Faded when Craftable is 0. Clickable when bags can make at least one potion.")

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

        local ok = pcall(

            Tooltips.CreateItemTooltip,

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

    ShowItemOrTextTooltip(itemData, data.name or L"Potion", line2, line3 ~= L"" and line3 or nil)

end

