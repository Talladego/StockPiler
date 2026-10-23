----------------------------------------------------------------
-- StockPiler View/WarBoardBridge -- optional WarBoard board chip
-- Registers only when WarBoard is present (AddMod). No LibWBToggler.
----------------------------------------------------------------

StockPiler = StockPiler or {}
StockPiler.WarBoardBridge = StockPiler.WarBoardBridge or {}
local WB = StockPiler.WarBoardBridge

local MOD_NAME = "WarBoard_StockPiler"
local ICON_ID = 2486

WB.WINDOW_NAME = MOD_NAME

local function T(key, tokens)
    if StockPiler.T then
        return StockPiler.T(key, tokens)
    end
    return towstring(tostring(key or ""))
end

local function TipAnchor()
    if type(WarBoard) == "table" and type(WarBoard.GetModToolTipAnchor) == "function" then
        return WarBoard.GetModToolTipAnchor(MOD_NAME)
    end
    return nil
end

local function AlreadyLoaded()
    if type(WarBoard) ~= "table" or type(WarBoard.LoadedMods) ~= "table" then
        return false
    end
    for i = 1, #WarBoard.LoadedMods do
        if WarBoard.LoadedMods[i] == MOD_NAME then
            return true
        end
    end
    return DoesWindowExist(MOD_NAME) == true
end

local function SetIcon(windowName, iconId)
    if type(GetIconData) ~= "function" or type(DynamicImageSetTexture) ~= "function" then
        return
    end
    local texture, x, y = GetIconData(iconId)
    if texture == nil then
        return
    end
    DynamicImageSetTexture(windowName, texture, x or 0, y or 0)
    -- Match WBToggler icon cell; craft atlas tiles otherwise look oversized.
    if type(DynamicImageSetTextureScale) == "function" then
        DynamicImageSetTextureScale(windowName, 0.75)
    end
    if type(DynamicImageSetTextureDimensions) == "function" then
        DynamicImageSetTextureDimensions(windowName, 64, 64)
    end
end

function WB.OnClick()
    if StockPiler.Ui and StockPiler.Ui.ToggleWindow then
        StockPiler.Ui.ToggleWindow()
    end
end

function WB.OnMouseOver()
    -- Reuse Craft harvest/brew tip; CraftTooltip appends warboard.tip_click for this window.
    local tip = StockPiler.CraftTooltip
    if tip and tip.Show then
        tip.Show(MOD_NAME, TipAnchor())
        return
    end
    if type(Tooltips) ~= "table" or type(Tooltips.CreateTextOnlyTooltip) ~= "function" then
        return
    end
    local anchor = TipAnchor()
    Tooltips.CreateTextOnlyTooltip(MOD_NAME, nil)
    if anchor ~= nil and type(Tooltips.AnchorTooltip) == "function" then
        Tooltips.AnchorTooltip(anchor)
    end
    if type(Tooltips.SetTooltipColor) == "function" then
        Tooltips.SetTooltipColor(1, 1, 0, 255, 255)
    end
    if type(Tooltips.SetTooltipText) == "function" then
        Tooltips.SetTooltipText(1, 1, T("warboard.tip_title"))
        Tooltips.SetTooltipText(2, 1, T("warboard.tip_click"))
    end
    if type(Tooltips.Finalize) == "function" then
        Tooltips.Finalize()
    end
end

function WB.Initialize()
    if type(WarBoard) ~= "table" or type(WarBoard.AddMod) ~= "function" then
        return false
    end
    if AlreadyLoaded() then
        return true
    end
    local ok = WarBoard.AddMod(MOD_NAME)
    if ok ~= true then
        return false
    end
    if DoesWindowExist(MOD_NAME) ~= true then
        return false
    end
    if type(LabelSetText) == "function" then
        LabelSetText(MOD_NAME .. "Label", T("warboard.tip_title"))
    end
    SetIcon(MOD_NAME .. "Icon", ICON_ID)
    return true
end
