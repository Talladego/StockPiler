<?xml version="1.0" encoding="UTF-8"?>
<ModuleFile xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
        <UiMod name="StockPiler" version="0.8.75" date="2026-08-30">
        <Author name="Talladego" email="" />
        <Description text="Apothecary stock planner with AutoGrow and harvest/brew macros." />
        <VersionSettings gameVersion="1.4.8" windowsVersion="1.0" savedVariablesVersion="1.0" />

        <Dependencies>
            <Dependency name="EASystem_Utils" />
            <Dependency name="EASystem_WindowUtils" />
            <Dependency name="EATemplate_DefaultWindowSkin" />
            <!-- SettingsSectionBackground, EA_Settings_SectionTitle, settings image -->
            <Dependency name="EA_SettingsWindow" />
            <Dependency name="EA_ChatWindow" />
            <Dependency name="EASystem_Tooltips" />
            <Dependency name="LibSlash" optional="true" />
            <Dependency name="PotionBar" optional="true" />
            <Dependency name="CraftValueTip" optional="true" />
            <!-- Soft runtime hooks: GatherButton, Shinies -->
        </Dependencies>

        <Files>
            <File name="Source/StockPiler.lua" />
            <File name="Source/StockPilerCharacter.lua" />
            <File name="Source/StockPilerNotify.lua" />
            <File name="Source/StockPilerMockData.lua" />
            <File name="Source/StockPilerClassify.lua" />
            <File name="Source/StockPilerMaterialSpec.lua" />
            <File name="Source/StockPilerRecipeSpec.lua" />
            <File name="Source/StockPilerInventory.lua" />
            <File name="Source/StockPilerAdditives.lua" />
            <File name="Source/StockPilerSeedMap.lua" />
            <File name="Source/StockPilerTemplates.xml" />
            <File name="Source/StockPilerPlanner.lua" />
            <File name="Source/StockPilerBrew.lua" />
            <File name="Source/StockPilerAutoGrow.lua" />
            <File name="Source/StockPilerMacro.lua" />
            <File name="Source/StockPilerRecipeTooltip.lua" />
            <File name="Source/StockPilerTabPotions.xml" />
            <File name="Source/StockPilerTabAutoGrow.xml" />
            <File name="Source/StockPilerWindow.xml" />
        </Files>

        <SavedVariables>
            <SavedVariable name="StockPiler.Settings" />
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
            <Careers>
                <Career name="BLACKGUARD" />
                <Career name="WITCH_ELF" />
                <Career name="DISCIPLE" />
                <Career name="SORCERER" />
                <Career name="IRON_BREAKER" />
                <Career name="SLAYER" />
                <Career name="RUNE_PRIEST" />
                <Career name="ENGINEER" />
                <Career name="BLACK_ORC" />
                <Career name="CHOPPA" />
                <Career name="SHAMAN" />
                <Career name="SQUIG_HERDER" />
                <Career name="WITCH_HUNTER" />
                <Career name="KNIGHT" />
                <Career name="BRIGHT_WIZARD" />
                <Career name="WARRIOR_PRIEST" />
                <Career name="CHOSEN" />
                <Career name="MARAUDER" />
                <Career name="ZEALOT" />
                <Career name="MAGUS" />
                <Career name="SWORDMASTER" />
                <Career name="SHADOW_WARRIOR" />
                <Career name="WHITE_LION" />
                <Career name="ARCHMAGE" />
            </Careers>
        </WARInfo>
    </UiMod>
</ModuleFile>
