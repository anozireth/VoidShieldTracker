--[[
UI.lua - Frame creation, icon management, minimap button, slash commands.
Loaded third (after Core.lua and Deck.lua). Attaches to addon.ui.
]]

local addon = _G["VoidShieldTracker"]

local ui = {}
addon.ui = ui

-- ============================================================
-- Constants
-- ============================================================
local TX_PROC    = "Interface\\Icons\\Inv12_apextalent_priest_voidshield"
local TX_NOPROC  = "Interface\\Icons\\spell_holy_penance"
local TX_EMPTY   = "Interface\\Buttons\\UI-EmptySlot"

-- ============================================================
-- Icon update
-- ============================================================
ui.icons = {}

function ui:SetIcon(slot, state)
    local icon = ui.icons[slot]
    if not icon then return end

    if state == "empty" then
        icon.texture:SetTexture(TX_EMPTY)
        icon.texture:SetVertexColor(0.3, 0.3, 0.3, 0.5)
    elseif state == "proc" then
        icon.texture:SetTexture(TX_PROC)
        icon.texture:SetVertexColor(0.4, 0.9, 0.4, 1)
    elseif state == "noproc" then
        icon.texture:SetTexture(TX_NOPROC)
        icon.texture:SetVertexColor(0.9, 0.2, 0.2, 1)
    end
end

function ui:SetAllIcons(state)
    for i = 1, 3 do
        self:SetIcon(i, state)
    end
end

-- ============================================================
-- Frame creation
-- ============================================================
function ui:Create()
    -- Main tracker frame (BackdropTemplate for native backdrop support)
    local frame = CreateFrame("Frame", nil, UIParent, "BackdropTemplate")
    frame:SetWidth(200)
    frame:SetHeight(64)
    frame:SetPoint("CENTER", UIParent, "CENTER", 0, 0)
    frame:SetMovable(true)
    frame:EnableMouse(true)
    frame:RegisterForDrag("LeftButton")
    frame:SetScript("OnDragStart", frame.StartMoving)
    frame:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
        VSTDB = VSTDB or {}
        local cx, cy = self:GetCenter()
        local pcx, pcy = UIParent:GetCenter()
        VSTDB.frameX = cx - pcx
        VSTDB.frameY = cy - pcy
    end)
    frame:SetFrameStrata("MEDIUM")
    frame:SetFrameLevel(5)
    frame:SetBackdrop({
        bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        edgeSize = 16,
        insets = { left = 4, right = 4, top = 4, bottom = 4 },
    })
    frame:SetBackdropColor(0, 0, 0, 0.75)
    frame:SetBackdropBorderColor(0.4, 0.4, 0.5, 1)

    -- Title
    local title = frame:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
    title:SetPoint("TOP", frame, "TOP", 0, -4)
    title:SetText("VOID SHIELD DECK")
    title:SetTextColor(0.7, 0.7, 0.9)

    -- Icon slots
    local SLOT_SIZE = 48
    local SLOT_GAP = 8
    local totalWidth = SLOT_SIZE * 3 + SLOT_GAP * 2

    for i = 1, 3 do
        local icon = CreateFrame("Frame", nil, frame)
        icon:SetSize(SLOT_SIZE, SLOT_SIZE)

        local xPos = -totalWidth / 2 + (SLOT_SIZE + SLOT_GAP) * (i - 1) + SLOT_SIZE / 2
        icon:SetPoint("CENTER", frame, "CENTER", xPos, 0)

        local tex = icon:CreateTexture(nil, "ARTWORK")
        tex:SetAllPoints(icon)
        tex:SetTexture(TX_EMPTY)
        tex:SetVertexColor(0.3, 0.3, 0.3, 0.5)

        local slotBorder = icon:CreateTexture(nil, "OVERLAY")
        slotBorder:SetAllPoints(icon)
        slotBorder:SetTexture(0.3, 0.3, 0.4, 0.8)

        ui.icons[i] = { frame = icon, texture = tex }
    end

    ui.frame = frame

    -- Minimap button
    self:CreateMinimapButton()
end

-- ============================================================
-- Minimap button
-- ============================================================
function ui:CreateMinimapButton()
    local btn = CreateFrame("Button", "VoidShieldTrackerMinimapButton", Minimap)
    btn:SetSize(32, 32)
    btn:SetPoint("TOP", Minimap, "TOP", 0, 0)
    btn:SetFrameStrata("LOW")
    btn:Hide()

    btn:SetNormalTexture(TX_PROC)
    btn:SetPushedTexture(TX_PROC)
    btn:SetHighlightTexture("Interface\\Buttons\\UI-Minimap-ZoomButton-Highlight")

    btn:SetScript("OnEnter", function()
        GameTooltip:SetOwner(btn, "ANCHOR_RIGHT")
        GameTooltip:AddLine("Void Shield Tracker", 0.5, 0.7, 1, true)
        GameTooltip:AddLine("Left-click: Toggle visibility", 0.7, 0.7, 0.7)
        GameTooltip:AddLine("Right-click: Reset deck & position", 0.7, 0.7, 0.7)
        GameTooltip:Show()
    end)

    -- Show frame position reset on right-click
    ui.frame:SetScript("OnEnter", function()
        GameTooltip:SetOwner(ui.frame, "ANCHOR_RIGHT")
        GameTooltip:AddLine("Void Shield Tracker", 0.5, 0.7, 1, true)
        GameTooltip:AddLine("Drag: Move frame", 0.7, 0.7, 0.7)
        GameTooltip:AddLine("Right-click: Reset position", 0.7, 0.7, 0.7)
        GameTooltip:Show()
    end)
    ui.frame:SetScript("OnLeave", function()
        GameTooltip:Hide()
    end)
    btn:SetScript("OnLeave", function()
        GameTooltip:Hide()
    end)

    btn:EnableMouse(true)
    btn:RegisterForDrag("LeftButton")
    btn:SetScript("OnDragStart", btn.StartMoving)
    btn:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
        self:ClearAllPoints()
        self:SetClampRectInsets(5, 5, 5, 5)
        self:SetClampRectRelativeToCurrentParent()
    end)

     btn:SetScript("OnClick", function(self, button)
        if button == "LeftButton" then
            if ui.frame:IsShown() then
                ui.frame:Hide()
            else
                ui.frame:Show()
            end
        elseif button == "RightButton" then
            addon.deck:Reset()
            VSTDB = VSTDB or {}
            VSTDB.frameX = 0
            VSTDB.frameY = 0
            ui.frame:ClearAllPoints()
            ui.frame:SetPoint("CENTER", UIParent, "CENTER", 0, 0)
            DEFAULT_CHAT_FRAME:AddMessage(
                "|cff88ccffVoid Shield Tracker|r: Deck reset & frame position cleared",
                0.5, 0.7, 1)
        end
    end)

    -- Reset position context menu (right-click on frame)
    ui.frame:SetScript("OnMouseDown", function(self, button)
        if button == "RightButton" then
            -- Reset position to center and clear saved position
            VSTDB = VSTDB or {}
            VSTDB.frameX = 0
            VSTDB.frameY = 0
            self:ClearAllPoints()
            self:SetPoint("CENTER", UIParent, "CENTER", 0, 0)
            DEFAULT_CHAT_FRAME:AddMessage(
                "|cff88ccffVoid Shield Tracker|r: Frame position reset to center",
                0.5, 0.7, 1)
        end
    end)

    ui.minimapButton = btn

    -- Show minimap button after a short delay (Minimap may not be ready yet)
    C_Timer.After(0.5, function()
        btn:Show()
    end)
end

-- ============================================================
-- Slash commands
-- ============================================================
_G.SLASH_VST1 = "/vst"
_G.SLASH_VST2 = "/voidshieldtracker"
_G.SlashCmdList["VST"] = function(msg)
    if not ui.frame then
        DEFAULT_CHAT_FRAME:AddMessage(
            "|cff88ccffVoid Shield Tracker|r: Not ready yet",
            0.5, 0.7, 1)
        return
    end

    msg = msg:lower():gsub("^%s*(.-)%s*$", "%1")

    if msg == "toggle" or msg == "" then
        if ui.frame:IsShown() then
            ui.frame:Hide()
            DEFAULT_CHAT_FRAME:AddMessage(
                "|cff88ccffVoid Shield Tracker|r: Hidden", 0.5, 0.7, 1)
        else
            ui.frame:Show()
            DEFAULT_CHAT_FRAME:AddMessage(
                "|cff88ccffVoid Shield Tracker|r: Shown", 0.5, 0.7, 1)
        end
    elseif msg == "reset" then
        addon.deck:Reset()
        DEFAULT_CHAT_FRAME:AddMessage(
            "|cff88ccffVoid Shield Tracker|r: Deck manually reset",
            0.5, 0.7, 1)
    elseif msg == "resetpos" then
        VSTDB = VSTDB or {}
        VSTDB.frameX = 0
        VSTDB.frameY = 0
        ui.frame:ClearAllPoints()
        ui.frame:SetPoint("CENTER", UIParent, "CENTER", 0, 0)
        DEFAULT_CHAT_FRAME:AddMessage(
            "|cff88ccffVoid Shield Tracker|r: Frame position reset to center",
            0.5, 0.7, 1)
    elseif msg == "status" then
        DEFAULT_CHAT_FRAME:AddMessage(
            "|cff88ccffVoid Shield Tracker|r: " .. addon.deck:Status(),
            0.5, 0.7, 1)
    else
        DEFAULT_CHAT_FRAME:AddMessage(
            "|cff88ccffVoid Shield Tracker|r: Commands: /vst [toggle|reset|status]",
            0.5, 0.7, 1)
    end
end
