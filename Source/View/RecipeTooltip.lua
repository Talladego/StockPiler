----------------------------------------------------------------
-- StockPiler RecipeTooltip -- Potions-tab recipe hover + colored rows
-- Same row kinds / separators as Watch status tip (ShowColoredRows).
----------------------------------------------------------------

StockPiler = StockPiler or {}
StockPiler.RecipeTooltip = StockPiler.RecipeTooltip or {}
local RecipeTooltip = StockPiler.RecipeTooltip

-- Yellow stats line (matches stock item-bonus tint when available).
local COLOR_STATS = { 220, 180, 60 }
-- Slot headers ("150 Apothecary - Container"): white on recipe and status tips.
local COLOR_INGREDIENT_HEADER = { r = 255, g = 255, b = 255 }

local function T(key, tokens)
    return StockPiler.Util.T(key, tokens)
end

RecipeTooltip.SEP_LINE = T("recipe.sep")

--- Private row windows. Tooltips.NUM_ROWS stays raised until the next ClearTooltip
--- so stock clear walks the extra rows. SetTooltipText ignores rows above that count.
local RECIPE_TOOLTIP_MAX_ROWS = 80
local STOCK_TOOLTIP_ROWS = 17
RecipeTooltip._numRows = 17
RecipeTooltip._raisedRows = nil

local function InstallClearTooltipHook()
    if RecipeTooltip._origClearTooltip or not Tooltips or type(Tooltips.ClearTooltip) ~= "function" then
        return
    end
    local stockRows = tonumber(Tooltips.NUM_ROWS)
    if not stockRows or stockRows < 1 then
        stockRows = STOCK_TOOLTIP_ROWS
    end
    STOCK_TOOLTIP_ROWS = stockRows
    RecipeTooltip._origClearTooltip = Tooltips.ClearTooltip
    Tooltips.ClearTooltip = function(...)
        local raised = tonumber(RecipeTooltip._raisedRows) or 0
        if raised > stockRows then
            Tooltips.NUM_ROWS = raised
        end
        local r = { RecipeTooltip._origClearTooltip(...) }
        if raised > stockRows then
            Tooltips.NUM_ROWS = stockRows
            RecipeTooltip._raisedRows = nil
        end
        return unpack(r)
    end
end

local function RgbDef(rgb)
    if not rgb then
        return nil
    end
    return { r = rgb[1] or 255, g = rgb[2] or 255, b = rgb[3] or 255 }
end

--- Grow this tooltip's own row windows. The count stays on RecipeTooltip._numRows.
--- Brand-new rows return 0 from LabelGetTextDimensions until the next frame, so
--- EnsureRows marks _layoutDirty; ShowColoredRows schedules a one-frame re-Finalize.
function RecipeTooltip.EnsureRows(want)
    want = tonumber(want) or 0
    if want < 1 then
        return tonumber(RecipeTooltip._numRows) or STOCK_TOOLTIP_ROWS
    end
    if want > RECIPE_TOOLTIP_MAX_ROWS then
        want = RECIPE_TOOLTIP_MAX_ROWS
    end
    local have = tonumber(RecipeTooltip._numRows) or STOCK_TOOLTIP_ROWS
    if have >= want then
        return have
    end
    if type(DoesWindowExist) ~= "function"
        or type(CreateWindowFromTemplate) ~= "function"
        or not DoesWindowExist("DefaultTooltip")
    then
        return have
    end
    local grew = false
    for rowNum = have + 1, want do
        local rowName = "DefaultTooltipRow" .. tostring(rowNum)
        if not DoesWindowExist(rowName) then
            local ok = pcall(CreateWindowFromTemplate, rowName, "TooltipRow", "DefaultTooltip")
            if not ok or not DoesWindowExist(rowName) then
                break
            end
            if type(WindowClearAnchors) == "function" and type(WindowAddAnchor) == "function" then
                WindowClearAnchors(rowName)
                local prev = "DefaultTooltipRow" .. tostring(rowNum - 1)
                WindowAddAnchor(rowName, "bottomleft", prev, "topleft", 0, 5)
                WindowAddAnchor(rowName, "bottomright", prev, "topright", 0, 5)
            end
            grew = true
        end
        have = rowNum
    end
    RecipeTooltip._numRows = have
    if grew then
        RecipeTooltip._layoutDirty = true
    end
    return have
end

--- Pre-create private tip rows so the first user hover never grows mid-paint.
function RecipeTooltip.WarmRows(want)
    InstallClearTooltipHook()
    local n = RecipeTooltip.EnsureRows(tonumber(want) or RECIPE_TOOLTIP_MAX_ROWS)
    -- Warmed rows sit idle until first hover; no tip to re-Finalize yet.
    RecipeTooltip._layoutDirty = false
    RecipeTooltip._needsRelayout = false
    return n
end

--- Second-frame Finalize after EnsureRows grew (LabelGetTextDimensions ready).
--- Returns true when a relayout ran.
function RecipeTooltip.TryRelayout()
    if not RecipeTooltip._needsRelayout then
        return false
    end
    RecipeTooltip._needsRelayout = false
    RecipeTooltip._layoutDirty = false
    if not Tooltips or Tooltips.visible ~= true then
        return false
    end
    if Tooltips.curTooltipWindow ~= "DefaultTooltip" then
        return false
    end
    if type(Tooltips.Finalize) ~= "function" then
        return false
    end
    local engineMax = tonumber(RecipeTooltip._numRows) or STOCK_TOOLTIP_ROWS
    local stockRows = STOCK_TOOLTIP_ROWS
    if engineMax > stockRows then
        RecipeTooltip._raisedRows = engineMax
        Tooltips.NUM_ROWS = engineMax
    end
    Tooltips.Finalize()
    if type(Tooltips.AnchorTooltip) == "function" then
        Tooltips.AnchorTooltip(
            RecipeTooltip._pendingAnchor or Tooltips.ANCHOR_WINDOW_RIGHT
        )
    end
    return true
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
    if kind == "ingredient" then
        return COLOR_INGREDIENT_HEADER
    end
    if kind == "effect" or kind == "bonus" or kind == "positive" or kind == "negative" then
        return Tooltips.COLOR_ITEM_BONUS or Tooltips.COLOR_HEADING
    end
    if kind == "warning" or kind == "block" then
        return Tooltips.COLOR_WARNING
    end
    if kind == "stocked" then
        return Tooltips.COLOR_ABILITY_STATE_READY or Tooltips.COLOR_HEADING
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

function RecipeTooltip.AppendSeparator(rows)
    if type(rows) ~= "table" then
        return
    end
    rows[#rows + 1] = { text = RecipeTooltip.SEP_LINE or T("recipe.sep"), kind = "separator" }
end

--- Shared colored text-only tooltip (Status / Craftable / Recipe use the same kinds).
--- rows: { { text = L"...", kind = "...", color? }, ... }
function RecipeTooltip.ShowColoredRows(anchorWindow, rows, anchor, maxRows)
    if type(rows) ~= "table" then
        rows = {}
    end
    if not Tooltips or type(Tooltips.CreateTextOnlyTooltip) ~= "function" then
        return
    end
    local want = tonumber(maxRows) or #rows
    if want < #rows then
        want = #rows
    end
    local engineMax = RecipeTooltip.EnsureRows(want)
    InstallClearTooltipHook()
    local stockRows = STOCK_TOOLTIP_ROWS
    if engineMax > stockRows then
        RecipeTooltip._raisedRows = engineMax
        Tooltips.NUM_ROWS = engineMax
    end
    Tooltips.CreateTextOnlyTooltip(anchorWindow)
    -- ClearTooltip restores the stock count. Raise it again for this draw.
    if engineMax > stockRows then
        RecipeTooltip._raisedRows = engineMax
        Tooltips.NUM_ROWS = engineMax
    end
    local limit = engineMax
    if tonumber(maxRows) and tonumber(maxRows) < limit then
        limit = tonumber(maxRows)
    end
    local rowCount = math.min(#rows, limit)
    for i = 1, rowCount do
        local entry = rows[i]
        if type(entry) ~= "table" then
            entry = { text = entry, kind = "body" }
        end
        Tooltips.SetTooltipText(i, 1, entry.text or L"", false)
        SetRecipeTooltipRowColor(i, entry.color or RecipeTooltipColor(entry.kind, entry.role))
    end
    for i = rowCount + 1, engineMax do
        Tooltips.SetTooltipText(i, 1, L"", false)
    end
    local tipAnchor = anchor or Tooltips.ANCHOR_WINDOW_RIGHT
    Tooltips.Finalize()
    Tooltips.AnchorTooltip(tipAnchor)
    -- New DefaultTooltipRowN windows report 0 text height until the next frame.
    if RecipeTooltip._layoutDirty then
        RecipeTooltip._needsRelayout = true
        RecipeTooltip._pendingAnchor = tipAnchor
        RecipeTooltip._layoutDirty = false
        -- Watch / Plants tips have no live update callback; arm a one-shot.
        -- CraftTooltip.Show replaces this with OnTooltipUpdate, which calls TryRelayout first.
        if type(Tooltips.SetUpdateCallback) == "function" then
            Tooltips.SetUpdateCallback(function()
                RecipeTooltip.TryRelayout()
                if type(Tooltips.SetUpdateCallback) == "function" then
                    Tooltips.SetUpdateCallback(nil)
                end
            end)
        end
    end
end

--- Fit row budget without dropping ingredient dividers (--- before next ingredient).
local function TrimRecipeTooltipRows(rows, limit)
    limit = tonumber(limit) or 17
    if type(rows) ~= "table" or #rows <= limit then
        return rows
    end

    local function isIngredientDivider(i)
        local prev = rows[i - 1]
        local nextRow = rows[i + 1]
        if not (nextRow and nextRow.kind == "ingredient") or not prev then
            return false
        end
        return prev.kind == "bonus"
            or prev.kind == "ingredient"
            or prev.kind == "body"
            or prev.kind == "stocked"
            or prev.kind == "effect"
            or prev.kind == "positive"
            or prev.kind == "negative"
    end

    -- Prefer dropping optional meta (yield / success) before any separators.
    for i = #rows, 1, -1 do
        if #rows <= limit then
            return rows
        end
        local r = rows[i]
        if r.kind == "meta" then
            table.remove(rows, i)
        end
    end

    -- Drop non-ingredient separators only (keep --- between materials).
    while #rows > limit do
        local removed = false
        for i = #rows, 1, -1 do
            if rows[i].kind == "separator" and not isIngredientDivider(i) then
                table.remove(rows, i)
                removed = true
                break
            end
        end
        if not removed then
            break
        end
    end

    -- Drop extra match name rows (keep at least one body per ingredient section).
    while #rows > limit do
        local removed = false
        for i = #rows, 1, -1 do
            local r = rows[i]
            if r.kind == "body" then
                local prev = rows[i - 1]
                if prev and prev.kind == "body" then
                    table.remove(rows, i)
                    removed = true
                    break
                end
            end
        end
        if not removed then
            break
        end
    end
    return rows
end

local function ResolveSlot(slot)
    if type(slot) ~= "table" then
        return nil, nil
    end
    local RS = StockPiler.RecipeSpec
    local spec = slot.spec
    if RS and RS.ResolveSlotSpec then
        spec = RS.ResolveSlotSpec(slot) or spec
    end
    return slot, spec
end

local function SlotHeaderAndStats(slot, spec, tipContext)
    local MS = StockPiler.MaterialSpec
    local role = slot.role or (type(spec) == "table" and spec.role) or nil
    local parts = nil
    if MS and MS.NeedLabelParts and type(spec) == "table" then
        parts = MS.NeedLabelParts(spec, tipContext)
    end
    local header = parts and parts.header or nil
    if header == nil or header == L"" then
        local roleTitle = (MS and MS.RoleTitle and MS.RoleTitle(role))
            or towstring(tostring(role or "mat"))
        header = roleTitle
    end
    local stats = parts and parts.detail or L""
    return header, stats, role
end

local function IconMarkup(iconNum)
    iconNum = tonumber(iconNum) or 0
    if iconNum <= 0 then
        return L""
    end
    return towstring(string.format("<icon%05d> ", iconNum))
end

--- Learned exemplar uid from recipe slot (fingerprint brew still uses MatchSpec).
local function SlotExemplarUid(slot, spec)
    if type(slot) ~= "table" then
        return 0
    end
    local uid = tonumber(slot.uid) or 0
    if uid <= 0 then
        uid = tonumber(slot.boundUid) or 0
    end
    if uid <= 0 and type(spec) == "table" then
        uid = tonumber(spec.boundUid) or tonumber(spec.uid) or 0
    end
    return uid
end

local function ItemsStore()
    local acct = StockPiler.Account
    if type(acct) == "table" and type(acct.items) == "table" then
        return acct.items
    end
    if StockPiler.Knowledge and StockPiler.Knowledge.Items then
        return StockPiler.Knowledge.Items()
    end
    return nil
end

local function NarrowName(name)
    return StockPiler.Util.ToNarrow(name)
end

--- Prefer bag sample for rarity tint; fall back to learned Items row.
local function ResolveDisplayItem(uid)
    uid = tonumber(uid) or 0
    if uid <= 0 then
        return nil
    end
    local itemData = nil
    if StockPiler.Inventory and StockPiler.Inventory.GetSample then
        itemData = StockPiler.Inventory.GetSample(uid)
    end
    local Items = StockPiler.Items
    if type(itemData) ~= "table" and Items and Items.AsItemData then
        itemData = Items.AsItemData(uid)
    elseif type(itemData) == "table"
        and (tonumber(itemData.rarity) or 0) <= 0
        and Items and Items.AsItemData
    then
        local cached = Items.AsItemData(uid)
        if type(cached) == "table" and (tonumber(cached.rarity) or 0) > 0 then
            -- Avoid mutating the live bag sample; clone tint fields for tip display.
            itemData = {
                uniqueID = uid,
                name = itemData.name or cached.name,
                iconNum = tonumber(itemData.iconNum) or tonumber(cached.iconNum) or 0,
                rarity = cached.rarity,
                itemSet = tonumber(itemData.itemSet) or tonumber(cached.itemSet) or 0,
            }
        end
    end
    if type(itemData) ~= "table" then
        return nil
    end
    local name = itemData.name
    if name == nil or name == L"" then
        return nil
    end
    return itemData
end

--- Resolve display item for the ingredient used when the recipe was learned.
--- Returns nil when uid/name cannot be resolved (skip for older recipes).
local function ResolveLearnedExemplar(slot, spec)
    local item = ResolveDisplayItem(SlotExemplarUid(slot, spec))
    if type(item) == "table" then
        return item
    end
    local name = type(slot) == "table" and slot.name or nil
    local icon = tonumber(type(slot) == "table" and slot.iconNum) or 0
    if (name == nil or NarrowName(name) == "") and type(spec) == "table" then
        name = spec.name
    end
    if icon <= 0 and type(spec) == "table" then
        icon = tonumber(spec.iconNum) or 0
    end
    if name == nil or NarrowName(name) == "" then
        return nil
    end
    return {
        uniqueID = SlotExemplarUid(slot, spec),
        name = name,
        iconNum = icon,
    }
end

local function ItemMatchesSpec(itemData, spec)
    local MS = StockPiler.MaterialSpec
    if type(itemData) ~= "table" or type(spec) ~= "table" or not MS then
        return false
    end
    if MS.IsSeedOrSpore and MS.IsSeedOrSpore(itemData) == true then
        return false
    end
    if MS.ProductMatches and MS.ProductMatches(itemData, spec) == true then
        return true
    end
    if MS.Matches and MS.Matches(itemData, spec) == true then
        return true
    end
    return false
end

local function SortMatchList(list, exemplarUid)
    exemplarUid = tonumber(exemplarUid) or 0
    table.sort(list, function(a, b)
        local au = tonumber(a and a.uniqueID) or 0
        local bu = tonumber(b and b.uniqueID) or 0
        if exemplarUid > 0 then
            if au == exemplarUid and bu ~= exemplarUid then
                return true
            end
            if bu == exemplarUid and au ~= exemplarUid then
                return false
            end
        end
        local an = string.lower(NarrowName(a and a.name))
        local bn = string.lower(NarrowName(b and b.name))
        if an ~= bn then
            return an < bn
        end
        return au < bu
    end)
end

--- Cache key: knowledge + bag snap + recipe fingerprint (bag butcher twins).
local _matchCacheKey = nil
local _matchCacheBySlot = nil

local function KnownMatchesCacheKey(materials)
    local knowGen = 0
    if StockPiler.Knowledge and StockPiler.Knowledge.GetGen then
        knowGen = tonumber(StockPiler.Knowledge.GetGen()) or 0
    end
    local snapGen = 0
    if StockPiler.Inventory and StockPiler.Inventory.GetSnapGen then
        snapGen = tonumber(StockPiler.Inventory.GetSnapGen()) or 0
    end
    local fp = ""
    local RS = StockPiler.RecipeSpec
    if RS and RS.RecipeSpecKey then
        fp = tostring(RS.RecipeSpecKey(materials) or "")
    end
    return tostring(knowGen) .. "|" .. tostring(snapGen) .. "|" .. fp
end

local function SampleHasCraftingBonus(sample)
    return type(sample) == "table"
        and type(sample.craftingBonus) == "table"
        and next(sample.craftingBonus) ~= nil
end

--- Prefer a bag sample that already has crafting stats. A first brew often
--- hands back uniqueID and icon only; that must not hide a learned spec.
local function MatchProbeForUid(uid)
    uid = tonumber(uid) or 0
    if uid <= 0 then
        return nil
    end
    local sample = nil
    local Inv = StockPiler.Inventory
    if Inv and Inv.GetSample then
        sample = Inv.GetSample(uid)
    end
    if SampleHasCraftingBonus(sample) then
        return sample
    end
    local Items = StockPiler.Items
    if Items and Items.ToSpec then
        local spec = Items.ToSpec(uid)
        local shows = StockPiler.MaterialSpec and StockPiler.MaterialSpec.SpecShowsBonus
        if type(spec) == "table" and spec.incomplete ~= true
            and (not shows or shows(spec) == true)
        then
            return spec
        end
    end
    if type(sample) == "table" and sample.name ~= nil and sample.name ~= L"" and sample.name ~= "" then
        return sample
    end
    if Items and Items.AsItemData then
        return Items.AsItemData(uid)
    end
    return nil
end

--- Try one uid against all open slots; append display on first ProductMatches hit.
local function ConsiderMatchUid(infos, uid, probeHint)
    uid = tonumber(uid) or 0
    if uid <= 0 or type(infos) ~= "table" then
        return
    end
    local probe = probeHint
    local display = nil
    for i = 1, #infos do
        local info = infos[i]
        if type(info.slot) == "table" and type(info.spec) == "table" and not info.seen[uid] then
            if probe == nil then
                probe = MatchProbeForUid(uid)
                if type(probe) ~= "table" then
                    return
                end
            end
            if ItemMatchesSpec(probe, info.spec) then
                if display == nil then
                    display = ResolveDisplayItem(uid) or probe
                end
                if type(display) == "table" then
                    info.seen[uid] = true
                    info.matches[#info.matches + 1] = display
                end
            end
        end
    end
end

--- Learned Items + bag samples: fingerprint matches per material slot (exemplar first).
--- Bags matter for butcher/vendor twins that Brew accepts but Account.items never saw.
local function CollectKnownMatchesBySlot(materials)
    local bySlot = {}
    if type(materials) ~= "table" then
        return bySlot
    end
    local cacheKey = KnownMatchesCacheKey(materials)
    if cacheKey ~= "" and cacheKey == _matchCacheKey and type(_matchCacheBySlot) == "table" then
        return _matchCacheBySlot
    end

    local infos = {}
    for i = 1, #materials do
        local slot, spec = ResolveSlot(materials[i])
        local info = {
            slot = slot,
            spec = spec,
            exemplarUid = SlotExemplarUid(slot, spec),
            seen = {},
            matches = {},
        }
        infos[i] = info
        bySlot[i] = info.matches
        if type(slot) == "table" then
            local exemplar = ResolveLearnedExemplar(slot, spec)
            if type(exemplar) == "table" then
                local uid = tonumber(exemplar.uniqueID) or info.exemplarUid
                if uid > 0 then
                    info.seen[uid] = true
                end
                info.matches[#info.matches + 1] = exemplar
            end
        end
    end

    local store = ItemsStore()
    if type(store) == "table" then
        for key, row in pairs(store) do
            local uid = tonumber(key) or 0
            if uid <= 0 and type(row) == "table" then
                uid = tonumber(row.uniqueID) or 0
            end
            if uid > 0 then
                ConsiderMatchUid(infos, uid, nil)
            end
        end
    end

    -- Same ProductMatches path Brew uses on bag samples (Preserved / butcher twins).
    local Inv = StockPiler.Inventory
    if Inv and Inv.ForEachItem then
        Inv.ForEachItem(function(item)
            if type(item) ~= "table" then
                return
            end
            local uid = tonumber(item.uniqueID) or 0
            if uid <= 0 then
                return
            end
            local anyOpen = false
            for i = 1, #infos do
                if not infos[i].seen[uid] then
                    anyOpen = true
                    break
                end
            end
            if anyOpen then
                ConsiderMatchUid(infos, uid, item)
            end
        end)
    end

    for i = 1, #infos do
        SortMatchList(infos[i].matches, infos[i].exemplarUid)
    end
    -- A first hover can run before CraftItemInfo arrives. Do not keep that
    -- empty slot, or the next hover would paint the same blank stabilizer.
    local cacheable = true
    for i = 1, #infos do
        local info = infos[i]
        if (tonumber(info.exemplarUid) or 0) > 0 and #info.matches == 0 then
            cacheable = false
            break
        end
        local spec = info.spec
        local shows = StockPiler.MaterialSpec and StockPiler.MaterialSpec.SpecShowsBonus
        if shows and type(spec) == "table" and (tonumber(spec.skillLevel) or 0) > 0
            and shows(spec) ~= true
        then
            cacheable = false
            break
        end
    end
    if cacheable then
        _matchCacheKey = cacheKey
        _matchCacheBySlot = bySlot
    else
        _matchCacheKey = nil
        _matchCacheBySlot = nil
    end
    return bySlot
end

local function AppendMatchNameRow(rows, itemData, role)
    if type(itemData) ~= "table" then
        return
    end
    local name = itemData.name
    if name == nil or name == L"" then
        return
    end
    local r, g, b = 255, 255, 255
    local VL = StockPiler.ViewList
    if VL and VL.ItemRarityNameColor then
        r, g, b = VL.ItemRarityNameColor(itemData)
    end
    rows[#rows + 1] = {
        text = IconMarkup(itemData.iconNum) .. name,
        kind = "body",
        role = role,
        color = { r = r, g = g, b = b },
    }
end

--- Append one fingerprint ingredient block (white header, yellow stats, then materials).
local function AppendIngredientSection(rows, header, stats, role, statsColor, matches)
    rows[#rows + 1] = {
        text = header,
        kind = "ingredient",
        role = role,
    }
    if stats ~= nil and stats ~= L"" then
        rows[#rows + 1] = {
            text = stats,
            kind = "bonus",
            role = role,
            color = statsColor,
        }
    end
    if type(matches) == "table" then
        for i = 1, #matches do
            AppendMatchNameRow(rows, matches[i], role)
        end
    end
end

--- Recipe tip rows: title/meta, then one section per perCraft unit.
--- Each section lists all known fingerprint-matching ingredients (rarity tint).
function RecipeTooltip.BuildRows(recipeData)
    if type(recipeData) ~= "table" then
        return {}
    end
    local name = recipeData.name or T("ui.potion_fallback")
    local rows = {
        {
            text = T("recipe.title", { name = name }),
            kind = "title",
        },
    }

    local function appendMeta(text)
        if text and text ~= L"" then
            rows[#rows + 1] = { text = text, kind = "meta" }
        end
    end

    local level = tonumber(recipeData.potionLevel) or 0
    if level > 0 then
        appendMeta(T("recipe.level", { level = tostring(level) }))
    end
    local yield = tonumber(recipeData.recipeYield) or 0
    if yield > 0 then
        appendMeta(T("recipe.yield", { yield = tostring(yield) }))
    end
    local rate = tonumber(recipeData.successRate)
    local ok = tonumber(recipeData.brewSuccesses) or 0
    local att = tonumber(recipeData.brewAttempts) or 0
    if rate ~= nil and att > 0 then
        local pct = math.floor((rate * 100) + 0.5)
        appendMeta(T("recipe.success", {
            pct = tostring(pct),
            ok = tostring(ok),
            att = tostring(att),
        }))
    end

    local recipe = recipeData.recipe
    local RS = StockPiler.RecipeSpec
    if type(recipe) == "table" and RS and RS.HydrateRecipeSlots then
        RS.HydrateRecipeSlots(recipe)
    end
    local materials = recipeData.materials
    if type(materials) ~= "table" and type(recipe) == "table" then
        materials = recipe.slots
    end
    if type(materials) ~= "table" or #materials == 0 then
        return rows
    end

    RecipeTooltip.AppendSeparator(rows)

    local statsColor = RgbDef(COLOR_STATS)
    if Tooltips and Tooltips.COLOR_ITEM_BONUS then
        statsColor = Tooltips.COLOR_ITEM_BONUS
    end

    -- Potion Effect (from Use:) fills incomplete mains that omit craftingBonus EFFECT.
    local tipContext = nil
    local effectKey = recipeData.effectKey
    if (type(effectKey) ~= "string" or effectKey == "") and type(recipe) == "table" then
        effectKey = recipe.effectKey
    end
    if type(effectKey) == "string" and effectKey ~= "" then
        tipContext = { effectKey = effectKey }
    elseif RS and RS.NormalizeEffectKeyForUi and type(recipeData.potionUid) == "number" then
        -- Resolve from potion record when recipeData was built without effectKey.
        local potions = StockPiler.Knowledge and StockPiler.Knowledge.Potions
            and StockPiler.Knowledge.Potions()
        local pk = RS.PotionKeyFromUid and RS.PotionKeyFromUid(recipeData.potionUid)
        local potion = type(potions) == "table" and pk and potions[pk] or nil
        if type(potion) == "table" and type(potion.effectKey) == "string" and potion.effectKey ~= "" then
            tipContext = { effectKey = potion.effectKey }
        end
    end

    local matchesBySlot = CollectKnownMatchesBySlot(materials)
    local sectionShown = 0
    for i = 1, #materials do
        local slot, spec = ResolveSlot(materials[i])
        if type(slot) == "table" then
            local header, stats, role = SlotHeaderAndStats(slot, spec, tipContext)
            local matches = matchesBySlot[i]
            local copies = math.max(1, tonumber(slot.perCraft) or 1)
            for _ = 1, copies do
                if sectionShown > 0 then
                    RecipeTooltip.AppendSeparator(rows)
                end
                sectionShown = sectionShown + 1
                AppendIngredientSection(rows, header, stats, role, statsColor, matches)
            end
        end
    end
    return rows
end

function RecipeTooltip.Show(mouseoverWindow, recipeData)
    mouseoverWindow = mouseoverWindow or (SystemData and SystemData.ActiveWindow and SystemData.ActiveWindow.name)
    if mouseoverWindow == nil or mouseoverWindow == "" or type(recipeData) ~= "table" then
        return
    end
    local rows = RecipeTooltip.BuildRows(recipeData)
    local engineMax = RecipeTooltip.EnsureRows(#rows)
    TrimRecipeTooltipRows(rows, engineMax)
    RecipeTooltip.ShowColoredRows(
        mouseoverWindow,
        rows,
        Tooltips and Tooltips.ANCHOR_WINDOW_RIGHT,
        engineMax
    )
end
