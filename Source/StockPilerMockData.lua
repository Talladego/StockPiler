----------------------------------------------------------------
-- L200 Apothecary catalog (wiki + waremu GraphQL)
-- ASCII only in L"" / narrow strings -- see docs/api/lua-chat-strings.md
--
-- Sources:
--   https://wiki.returnofreckoning.com/Apothecary
--   https://wiki.returnofreckoning.com/Cultivating
--   https://production-api.waremu.com/graphql/
--
-- Potions catalog = stock targets (Have/Min/watchlist), NOT brew recipes.
-- Apothecary brew recipes are learned from crafting (Recipes tab).
-- seedMatch = Cultivation seed/spore for the main plant (AutoGrow planner), not a brew slot.
----------------------------------------------------------------

StockPiler.Catalog = StockPiler.Catalog or {}

StockPiler.Catalog.GrowSuggestion = L"Majestic Goldweed -> Taut Gobswort -> Elder Beardweed"

--[[
  Potions listed in the UI: L200 *normal* craft targets (not Potent).
  Potent is a crit byproduct of crafting normals; it is not a separate row.
  Have still counts Potent stacks toward the same effect family.

  Fields:
    id, name, effect, effectKey, tier
    matchName / matchNames: bag name substrings (counts all durations/qualities, incl. Potent)
    uniqueID, uniqueIDs: preferred *normal* item ids (GraphQL); dual ranges common
    knownIconNum: optional fallback icon when not yet observed in bags
    tooltip: fallback text when CreateItemTooltip has no bag itemData
    defaultMin, defaultWatch
    recipeYield: finished potions per craft (for Min -> material need math on Potions tab)
    seedMatch: cultivating seed/spore for the main plant (AutoGrow tab only)
]]

StockPiler.Catalog.Potions = {
    ------------------------------------------------------------------
    -- Stat potions (Lasting)
    ------------------------------------------------------------------
    {
        id = "l200-str",
        name = L"Lasting Potion of Power",
        effect = L"Strength",
        effectKey = "str",
        tier = 200,
        matchName = "Potion of Power",
        uniqueID = 3000649,
        uniqueIDs = { 3000649, 197022 },
        modelId = 735,  -- armory only; not GetIconData
        abilityName = L"Lasting Potion of Strength",
        tooltip = L"L200 Strength buff (1 hour with extender). Main: Elder Beardweed. Potent counts toward Have.",
        defaultMin = 20,
        defaultWatch = true,
        recipeYield = 2,
        seedMatch = "Elder Beardweed Seed",
    },
    {
        id = "l200-bs",
        name = L"Lasting Potion of Verity",
        effect = L"Ballistic",
        effectKey = "bs",
        tier = 200,
        matchName = "Potion of Verity",
        matchNames = { "Potion of Verity", "Potion of Accuracy", "Potion of Deftness" },
        uniqueID = 3001249,
        uniqueIDs = { 3001249, 197252, 3001234, 157735 },
        knownIconNum = 449,
        modelId = 599,
        abilityName = L"Lasting Potion of Accuracy",
        tooltip = L"L200 Ballistic Skill buff (Verity/Accuracy/Deftness). Main: Rugged Thief's Nettle. Potent counts toward Have.",
        defaultMin = 10,
        defaultWatch = false,
        recipeYield = 2,
        seedMatch = "Rugged Thief's Nettle Seed",
    },
    {
        id = "l200-int",
        name = L"Lasting Potion of Brilliance",
        effect = L"Intelligence",
        effectKey = "int",
        tier = 200,
        matchName = "Potion of Brilliance",
        uniqueID = 3000849,
        uniqueIDs = { 3000849, 197082 },
        knownIconNum = 509,
        modelId = 747,
        abilityName = L"Lasting Potion of Knowledge",
        tooltip = L"L200 Intelligence buff. Main: Hightop Smedleycap.",
        defaultMin = 10,
        defaultWatch = true,
        recipeYield = 2,
        seedMatch = "Hightop Smedleycap Spore",
    },
    {
        id = "l200-wp",
        name = L"Lasting Potion of Discipline",
        effect = L"Willpower",
        effectKey = "wp",
        tier = 200,
        matchName = "Potion of Discipline",
        uniqueID = 3001049,
        uniqueIDs = { 3001049, 197142 },
        modelId = 747,
        abilityName = L"Lasting Potion of Wisdom",
        tooltip = L"L200 Willpower buff. Main: Bitter Grumpleaf.",
        defaultMin = 10,
        defaultWatch = false,
        recipeYield = 2,
        seedMatch = "Bitter Grumpleaf Seed",
    },
    {
        id = "l200-tou",
        name = L"Lasting Liquid Fortitude",
        effect = L"Toughness",
        effectKey = "tou",
        tier = 200,
        matchName = "Liquid Fortitude",
        uniqueID = 3002049,
        uniqueIDs = { 3002049, 197192 },
        modelId = 587,
        abilityName = L"Lasting Liquid Fortitude",
        tooltip = L"L200 Toughness buff. Main: Pristine Arachnid Venom (Butchering). Potent counts toward Have.",
        defaultMin = 20,
        defaultWatch = true,
        recipeYield = 2,
        seedMatch = nil,
    },

    ------------------------------------------------------------------
    -- Armor / Absorb (Lasting) -- butchering mains
    ------------------------------------------------------------------
    {
        id = "l200-arm",
        name = L"Lasting Stanchion Unguent",
        effect = L"Armor",
        effectKey = "armor",
        tier = 200,
        matchName = "Stanchion Unguent",
        uniqueID = 3002249,
        uniqueIDs = { 3002249 },
        knownIconNum = 509,
        modelId = 747,
        abilityName = L"Lasting Stanchion Unguent",
        tooltip = L"L200 Armor buff. Main: Firebreath Scale (Butchering). Potent counts toward Have.",
        defaultMin = 20,
        defaultWatch = true,
        recipeYield = 2,
        seedMatch = nil,
    },
    {
        id = "l200-abs",
        name = L"Lasting Aversion Potion",
        effect = L"Absorb",
        effectKey = "absorb",
        tier = 200,
        matchName = "Aversion Potion",
        uniqueID = 3003049,
        uniqueIDs = { 3003049, 197312 },
        modelId = 759,
        abilityName = L"Lasting Screening Potion",
        tooltip = L"L200 Absorb / screening buff. Main: Monstrous Bat Wing (Butchering). Potent counts toward Have.",
        defaultMin = 15,
        defaultWatch = true,
        recipeYield = 2,
        seedMatch = nil,
    },

    ------------------------------------------------------------------
    -- Instant heal / AP draughts
    ------------------------------------------------------------------
    {
        id = "l200-heal",
        name = L"Draught of Recovery",
        effect = L"Heal",
        effectKey = "heal",
        tier = 200,
        matchName = "Draught of Recovery",
        uniqueID = 3000209,
        uniqueIDs = { 3000209, 3000264, 157870 },
        modelId = 699,
        abilityName = L"Potion Of Healing",
        tooltip = L"L200 instant heal. Main: Hurling Spumepetal. No extender.",
        defaultMin = 20,
        defaultWatch = true,
        recipeYield = 2,
        seedMatch = "Hurling Spumepetal Seed",
    },
    {
        id = "l200-ap",
        name = L"Rejuvenating Draught",
        effect = L"AP",
        effectKey = "ap",
        tier = 200,
        matchName = "Rejuvenating Draught",
        uniqueID = 3000409,
        uniqueIDs = { 3000409, 3000464, 197002 },
        modelId = 759,
        abilityName = L"Charging Draught",
        tooltip = L"L200 AP / invigoration draught. Main: Drunken Dandedragon. No extender.",
        defaultMin = 20,
        defaultWatch = false,
        recipeYield = 2,
        seedMatch = "Drunken Dandedragon Seed",
    },

    ------------------------------------------------------------------
    -- Heal over Time (Lasting elixir)
    ------------------------------------------------------------------
    {
        id = "l200-hot",
        name = L"Lasting Elixir of Recovery",
        effect = L"HoT",
        effectKey = "hot",
        tier = 200,
        matchName = "Elixir of Recovery",
        uniqueID = 3000049,
        uniqueIDs = { 3000049, 3000104, 157930 },
        modelId = 723,
        abilityName = L"Lasting Elixir of Mending",
        tooltip = L"L200 HoT / restoration elixir. Main: Bittersweet Elvish Parsley.",
        defaultMin = 15,
        defaultWatch = true,
        recipeYield = 2,
        seedMatch = "Bittersweet Elvish Parsley Seed",
    },
}

-- Back-compat alias
StockPiler.Mock = StockPiler.Mock or {}
StockPiler.Mock.GrowSuggestion = StockPiler.Catalog.GrowSuggestion
StockPiler.Mock.Potions = StockPiler.Catalog.Potions
