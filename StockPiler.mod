<?xml version="1.0" encoding="UTF-8"?>
<ModuleFile xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
    <UiMod name="StockPiler" version="1.0.1" date="2026-10-20">
        <Author name="Talladego" email="" />
        <Description text="Stock potions and plants. Grow, buy, and brew toward the amounts you set." />
        <VersionSettings gameVersion="1.4.8" windowsVersion="1.0" savedVariablesVersion="1.0" />

        <Dependencies>
            <Dependency name="EASystem_Utils" />
            <Dependency name="EASystem_WindowUtils" />
            <Dependency name="EATemplate_DefaultWindowSkin" />
            <Dependency name="EA_SettingsWindow" />
            <Dependency name="EA_ChatWindow" />
            <Dependency name="EASystem_Tooltips" />
            <Dependency name="EA_ActionBars" />
            <Dependency name="EA_CultivationWindow" />
            <Dependency name="EA_CraftingSystem" />
            <Dependency name="LibSlash" optional="true" />
            <Dependency name="LibPerf" optional="true" />
        </Dependencies>

        <Files>
            <File name="Source/Core/Debug.lua" />
            <File name="Source/Locale/Locale.lua" />
            <File name="Source/Locale/enUS.lua" />
            <File name="Source/Core/Util.lua" />
            <File name="Source/Core/EventBus.lua" />
            <File name="Source/Core/Perf.lua" />
            <File name="Source/Core/Scheduler.lua" />
            <File name="Source/Core/FrameWork.lua" />
            <File name="Source/Core/Orchestrator.lua" />
            <File name="Source/Core/EngineEventBridge.lua" />
            <File name="Source/Adapters/BagAdapter.lua" />
            <File name="Source/Adapters/CultivatorAdapter.lua" />
            <File name="Source/Adapters/TradeSkillCaps.lua" />
            <File name="Source/Adapters/ApothecaryAdapter.lua" />
            <File name="Source/Adapters/VendorAdapter.lua" />
            <File name="Source/Adapters/CraftChatAdapter.lua" />
            <File name="Source/Persistence/Settings.lua" />
            <File name="Source/Stores/KnowledgeStore.lua" />
            <File name="Source/Knowledge/MaterialSpec.lua" />
            <File name="Source/Knowledge/MaterialExceptions.lua" />
            <File name="Source/Knowledge/Items.lua" />
            <File name="Source/Knowledge/Classify.lua" />
            <File name="Source/Knowledge/RecipeSpec.lua" />
            <File name="Source/Stores/WatchStore.lua" />
            <File name="Source/Stores/InventoryStore.lua" />
            <File name="Source/Knowledge/BrewLearn.lua" />
            <File name="Source/Knowledge/SeedMap.lua" />
            <File name="Source/Knowledge/Additives.lua" />
            <File name="Source/Knowledge/LearnBridge.lua" />
            <File name="Source/Stores/GardenStore.lua" />
            <File name="Source/Stores/RefinePipelineStore.lua" />
            <File name="Source/Stores/PlanSnapshotStore.lua" />
            <File name="Source/Planner/Planner.lua" />
            <File name="Source/Grow.lua" />
            <File name="Source/SkillUp.lua" />
            <File name="Source/UpgradeSeed.lua" />
            <File name="Source/Core/SeedEconomy.lua" />
            <File name="Source/Brew.lua" />
            <File name="Source/Refine.lua" />
            <File name="Source/Buy.lua" />
            <File name="Source/Macro/Macro.lua" />
            <File name="Source/Macro/CraftHarvestTimer.lua" />
            <File name="Source/View/HarvestChrome.lua" />
            <File name="Source/View/HarvestTooltip.lua" />
            <File name="Source/View/BrewChrome.lua" />
            <File name="Source/View/BrewTooltip.lua" />
            <File name="Source/View/CraftTooltip.lua" />
            <File name="Source/View/Catalog.lua" />
            <File name="Source/View/ViewList.lua" />
            <File name="Source/View/RecipeTooltip.lua" />
            <File name="Source/View/Ui.lua" />
            <File name="Source/View/StockPilerTemplates.xml" />
            <File name="Source/View/StockPilerTabPotions.xml" />
            <File name="Source/View/StockPilerTabPlants.xml" />
            <File name="Source/View/StockPilerTabWatch.xml" />
            <File name="Source/View/StockPilerWindow.xml" />
            <File name="Source/Bootstrap.lua" />
        </Files>

        <SavedVariables>
            <SavedVariable name="StockPiler.Settings" />
            <SavedVariable name="StockPiler.Account" global="true" />
        </SavedVariables>

        <OnInitialize>
            <CreateWindow name="StockPilerWindow" show="false" />
            <CallFunction name="StockPiler.Initialize" />
        </OnInitialize>

        <OnShutdown>
            <CallFunction name="StockPiler.Shutdown" />
        </OnShutdown>

        <WARInfo>
            <Categories>
                <Category name="CRAFTING" />
            </Categories>
        </WARInfo>
    </UiMod>
</ModuleFile>
