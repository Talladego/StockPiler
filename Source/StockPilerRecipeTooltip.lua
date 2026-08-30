----------------------------------------------------------------
-- StockPilerRecipeTooltip - shared recipe tooltip for Potions tab
----------------------------------------------------------------

StockPilerRecipeTooltip = {}

local RECIPE_TOOLTIP_SEP_LINE = L"----------------------------------------"
local RECIPE_TOOLTIP_MAX_ROWS = 17

local function AppendRecipeSeparator(body)
    body[#body + 1] = { text = RECIPE_TOOLTIP_SEP_LINE, kind = "separator" }
end

local function JoinTooltipParts(parts, sep)
    if #parts == 0 then
        return L""
    end
    local text = parts[1]
    for i = 2, #parts do
        text = text .. sep .. parts[i]
    end
    return text
end

local function CompactIngredientStatLines(rows)
    local i = 1
    while i <= #rows do
        if rows[i].kind == "ingredient" then
            i = i + 1
            local stats = {}
            while i <= #rows and rows[i].kind ~= "separator" and rows[i].kind ~= "ingredient" and rows[i].kind ~= "title" and rows[i].kind ~= "meta" do
                if rows[i].text and rows[i].text ~= L"" then
                    stats[#stats + 1] = rows[i]
                end
                table.remove(rows, i)
            end
            if #stats > 1 then
                local parts = {}
                for s = 1, #stats do
                    parts[s] = stats[s].text
                end
                table.insert(rows, i, {
                    text = JoinTooltipParts(parts, L"   "),
                    kind = stats[1].kind or "bonus",
                })
                i = i + 1
            elseif #stats == 1 then
                table.insert(rows, i, stats[1])
                i = i + 1
            end
        else
            i = i + 1
        end
    end
    return rows
end

local function RecipeTooltipColor(kind, role)
    if not Tooltips then
        return nil
    end
    if kind == "title" then
        return Tooltips.COLOR_HEADING
    end
    if kind == "meta" then
        return Tooltips.COLOR_EXTRA_TEXT_DEFAULT
    end
    if kind == "separator" then
        return Tooltips.COLOR_ITEM_DEFAULT_GRAY
    end
    if kind == "effect" then
        return Tooltips.COLOR_HEADING
    end
    if kind == "ingredient" then
        if role == "main" then
            return Tooltips.COLOR_HEADING
        end
        if role == "container" then
            return Tooltips.COLOR_BODY
        end
        if role == "stabilizer" or role == "goldweed" then
            return Tooltips.COLOR_ITEM_BONUS
        end
        if role == "extender" then
            return Tooltips.COLOR_ACTION
        end
        if role == "multiplier" or role == "stimulant" then
            return Tooltips.COLOR_ITEM_HIGHLIGHT
        end
        return Tooltips.COLOR_HEADING
    end
    if kind == "positive" then
        return Tooltips.COLOR_ACTION
    end
    if kind == "negative" or kind == "warning" then
        return Tooltips.COLOR_WARNING
    end
    if kind == "bonus" then
        return Tooltips.COLOR_ITEM_BONUS
    end
    return Tooltips.COLOR_BODY
end

local function SetRecipeTooltipRowColor(row, color)
    if not color or not Tooltips then
        return
    end
    if Tooltips.SetTooltipColorDef then
        Tooltips.SetTooltipColorDef(row, 1, color)
    elseif Tooltips.SetTooltipColor then
        Tooltips.SetTooltipColor(row, 1, color.r or 255, color.g or 255, color.b or 255)
    end
end

local function ResolveRecipePotionLevel(data)
    local level = tonumber(data and data.potionLevel) or 0
    if level > 0 then
        return level
    end
    local uid = tonumber(data and data.potionUid) or 0
    if uid <= 0 then
        return 0
    end
    if StockPiler.RecipeSpec and StockPiler.RecipeSpec.PotionKeyFromUid then
        local potionKey = StockPiler.RecipeSpec.PotionKeyFromUid(uid)
        local s = StockPiler.EnsureSettings and StockPiler.EnsureSettings() or StockPiler.Settings
        local potion = s and s.knownPotions and potionKey and s.knownPotions[potionKey]
        if type(potion) == "table" and StockPiler.Inventory then
            local entry = {
                id = potionKey,
                uniqueID = uid,
                uniqueIDs = { uid },
            }
            local itemData = nil
            if StockPiler.Inventory.ResolveTooltipItemData then
                itemData = StockPiler.Inventory.ResolveTooltipItemData(entry, nil)
            end
            if StockPiler.Classify and StockPiler.Classify.GetPotionStats then
                local minRank = StockPiler.Classify.GetPotionStats(itemData, entry)
                level = tonumber(minRank) or 0
            end
        end
    end
    return level
end

local function MergeMetaRows(rows)
    local firstMeta, secondMeta
    for i = 1, #rows do
        if rows[i].kind == "meta" then
            if not firstMeta then
                firstMeta = i
            else
                secondMeta = i
                break
            end
        end
    end
    if firstMeta and secondMeta then
        rows[firstMeta].text = rows[firstMeta].text .. L"  " .. rows[secondMeta].text
        table.remove(rows, secondMeta)
    end
end

local function CompactRecipeTooltipRows(rows)
    CompactIngredientStatLines(rows)

    if #rows > RECIPE_TOOLTIP_MAX_ROWS then
        MergeMetaRows(rows)
    end

    while #rows > RECIPE_TOOLTIP_MAX_ROWS do
        local removed = false
        for i = #rows, 1, -1 do
            if rows[i].kind == "separator" then
                table.remove(rows, i)
                removed = true
                break
            end
        end
        if removed then
            -- keep trimming separators while over limit
        elseif rows[#rows].kind == "ingredient" then
            table.remove(rows, #rows)
        else
            for i = #rows - 1, 1, -1 do
                if rows[i].kind == "bonus" and rows[i + 1] and rows[i + 1].kind == "bonus" then
                    rows[i] = {
                        text = rows[i].text .. L"   " .. rows[i + 1].text,
                        kind = "bonus",
                    }
                    table.remove(rows, i + 1)
                    removed = true
                    break
                end
            end
            if not removed then
                table.remove(rows, #rows)
            end
        end
    end

    return rows
end

function StockPilerRecipeTooltip.BuildRecipeTooltipLines(data)
    local rows = StockPilerRecipeTooltip.BuildRecipeTooltipRows(data)
    local lines = {}
    for i = 1, #rows do
        lines[i] = rows[i].text
    end
    return lines
end

function StockPilerRecipeTooltip.BuildRecipeTooltipRows(data)
    local body = {}
    if not data then
        return body
    end

    local potionName = data.name or L"Potion"
    body[#body + 1] = { text = L"Recipe - " .. potionName, kind = "title" }

    local level = ResolveRecipePotionLevel(data)
    if level > 0 then
        body[#body + 1] = { text = L"Level " .. towstring(tostring(level)), kind = "meta" }
    end

    local metaParts = {}
    if data.recipeYield and data.recipeYield > 0 then
        metaParts[#metaParts + 1] = L"Yield: " .. towstring(tostring(data.recipeYield)) .. L" per brew"
    end
    if data.crafts and data.crafts > 0 then
        metaParts[#metaParts + 1] = L"Brewed " .. towstring(tostring(data.crafts)) .. L" time(s)"
    end
    if #metaParts == 1 then
        body[#body + 1] = { text = metaParts[1], kind = "meta" }
    elseif #metaParts == 2 then
        body[#body + 1] = { text = metaParts[1] .. L"  " .. metaParts[2], kind = "meta" }
    end

    local materials = data.materials or {}
    for i = 1, #materials do
        local mat = materials[i]
        if type(mat) == "table" then
            local per = math.max(1, tonumber(mat.perCraft) or 1)
            for _n = 1, per do
                AppendRecipeSeparator(body)

                local slotRows
                if mat.spec and StockPiler.MaterialSpec and StockPiler.MaterialSpec.DescribeTooltipRows then
                    slotRows = StockPiler.MaterialSpec.DescribeTooltipRows(mat.spec, 1)
                else
                    local role = mat.role or "ingredient"
                    local matTitle = mat.name or mat.nameNarrow or role
                    slotRows = {
                        {
                            text = towstring(tostring(role)) .. L": " .. towstring(tostring(matTitle)),
                            kind = "ingredient",
                            role = role,
                        },
                    }
                end
                for j = 1, #slotRows do
                    body[#body + 1] = slotRows[j]
                end
            end
        end
    end

    return CompactRecipeTooltipRows(body)
end

function StockPilerRecipeTooltip.ShowRecipeTooltip(anchorWindow, data)
    local rows = StockPilerRecipeTooltip.BuildRecipeTooltipRows(data)
    Tooltips.CreateTextOnlyTooltip(anchorWindow)
    local rowCount = math.min(#rows, RECIPE_TOOLTIP_MAX_ROWS)
    for i = 1, rowCount do
        local entry = rows[i]
        Tooltips.SetTooltipText(i, 1, entry.text or L"", false)
        SetRecipeTooltipRowColor(i, entry.color or RecipeTooltipColor(entry.kind, entry.role))
    end
    for i = rowCount + 1, RECIPE_TOOLTIP_MAX_ROWS do
        Tooltips.SetTooltipText(i, 1, L"", false)
    end
    Tooltips.Finalize()
    Tooltips.AnchorTooltip(Tooltips.ANCHOR_WINDOW_RIGHT)
end
