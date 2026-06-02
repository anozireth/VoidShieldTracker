--[[
    UI.lua - Card display, minimap button, options panel, slash commands.
    Loaded last (after Core.lua and Deck.lua). Attaches to addon.ui.
]]

local addon = _G["VoidShieldTracker"]

local ui = {}
addon.ui = ui

-- ============================================================
-- Constants
-- ============================================================
local TX_PROC    = "Interface\\Icons\\Inv12_apextalent_priest_voidshield"
local TX_NOPROC  = "Interface\\Icons\\spell_holy_penance"
local TX_UNKNOWN = "Interface\\Icons\\INV_Misc_QuestionMark"

local CARD_SIZE = 46
local CARD_GAP  = 8
local PADDING   = 12

-- Probability colour thresholds.
local THRESH_LO, THRESH_HI = 0.34, 0.66

local function probColor(prob)
    if prob == nil   then return 0.5, 0.5, 0.5 end
    if prob >= 1.0   then return 0.0, 0.9, 0.9 end   -- cyan: guaranteed
    if prob <= 0.0   then return 0.9, 0.2, 0.2 end   -- red:  impossible
    if prob >= THRESH_HI then return 0.1, 0.9, 0.1 end -- green
    if prob >= THRESH_LO then return 0.9, 0.9, 0.1 end -- yellow
    return 1.0, 0.5, 0.0                                -- orange
end

-- ============================================================
-- Card rendering
-- ============================================================
local function renderCard(card, state, highlight, hr, hg, hb)
    local icon = card.icon
    local bg   = card.bg

    if state == "proc" then
        icon:SetTexture(TX_PROC)
        icon:SetDesaturated(false)
        icon:SetVertexColor(1, 1, 1, 1)
        icon:SetAlpha(1)
        bg:SetColorTexture(0.05, 0.30, 0.10, 0.9)
    elseif state == "noproc" then
        icon:SetTexture(TX_NOPROC)
        icon:SetDesaturated(true)
        icon:SetVertexColor(0.85, 0.45, 0.45, 1)
        icon:SetAlpha(0.9)
        bg:SetColorTexture(0.30, 0.06, 0.06, 0.9)
    elseif state == "unknown" then
        icon:SetTexture(TX_UNKNOWN)
        icon:SetDesaturated(false)
        icon:SetVertexColor(0.95, 0.9, 0.3, 1)
        icon:SetAlpha(0.9)
        bg:SetColorTexture(0.18, 0.16, 0.05, 0.9)
    else -- "future" (face-down)
        icon:SetTexture(TX_UNKNOWN)
        icon:SetDesaturated(true)
        icon:SetVertexColor(0.5, 0.6, 0.8, 1)
        icon:SetAlpha(0.18)
        bg:SetColorTexture(0.06, 0.08, 0.16, 0.9)
    end

    if highlight then
        card:SetBackdropBorderColor(hr, hg, hb, 1)
    else
        card:SetBackdropBorderColor(0.35, 0.35, 0.45, 1)
    end
end

-- ============================================================
-- Main frame
-- ============================================================
function ui:Create()
    if self.frame then return end

    local totalCards = CARD_SIZE * 3 + CARD_GAP * 2
    local width  = totalCards + PADDING * 2
    local height = CARD_SIZE + 56

    local frame = CreateFrame("Frame", "VoidShieldTrackerFrame", UIParent, "BackdropTemplate")
    frame:SetSize(width, height)
    frame:SetScale(VSTDB.scale or 1.0)

    -- Restore saved position, else centre.
    local p = VSTDB.pos
    if p and p.point then
        frame:SetPoint(p.point, UIParent, p.relPoint, p.x, p.y)
    else
        frame:SetPoint("CENTER", UIParent, "CENTER", 0, 120)
    end

    frame:SetBackdrop({
        bgFile   = "Interface\\Buttons\\WHITE8x8",
        edgeFile = "Interface\\Buttons\\WHITE8x8",
        edgeSize = 1, tile = true, tileSize = 16,
    })
    frame:SetBackdropColor(0, 0, 0, 0.82)
    frame:SetBackdropBorderColor(0.32, 0.32, 0.4, 1)

    frame:SetMovable(true)
    frame:EnableMouse(true)
    frame:RegisterForDrag("LeftButton")
    frame:SetScript("OnDragStart", function(self)
        if not VSTDB.locked then self:StartMoving() end
    end)
    frame:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
        local point, _, relPoint, x, y = self:GetPoint()
        VSTDB.pos = { point = point, relPoint = relPoint, x = x, y = y }
    end)

    frame:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_BOTTOM")
        GameTooltip:AddLine("Void Shield Tracker", 0.5, 0.7, 1)
        GameTooltip:AddLine("Drag to move (when unlocked)", 0.8, 0.8, 0.8)
        GameTooltip:AddLine("/vst for options", 0.8, 0.8, 0.8)
        GameTooltip:Show()
    end)
    frame:SetScript("OnLeave", function() GameTooltip:Hide() end)

    -- Title
    local title = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    title:SetPoint("TOP", frame, "TOP", 0, -8)
    title:SetText("VOID SHIELD DECK")
    title:SetTextColor(0.7, 0.7, 0.9)
    frame.title = title

    -- Cards
    frame.cards = {}
    for i = 1, 3 do
        local card = CreateFrame("Frame", nil, frame, "BackdropTemplate")
        card:SetSize(CARD_SIZE, CARD_SIZE)
        local x = -totalCards / 2 + (CARD_SIZE + CARD_GAP) * (i - 1) + CARD_SIZE / 2
        card:SetPoint("CENTER", frame, "CENTER", x, 2)
        card:SetBackdrop({
            edgeFile = "Interface\\Buttons\\WHITE8x8",
            edgeSize = 2,
        })

        local bg = card:CreateTexture(nil, "BACKGROUND")
        bg:SetPoint("TOPLEFT", card, "TOPLEFT", 2, -2)
        bg:SetPoint("BOTTOMRIGHT", card, "BOTTOMRIGHT", -2, 2)
        card.bg = bg

        local icon = card:CreateTexture(nil, "ARTWORK")
        icon:SetPoint("TOPLEFT", card, "TOPLEFT", 3, -3)
        icon:SetPoint("BOTTOMRIGHT", card, "BOTTOMRIGHT", -3, 3)
        icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
        card.icon = icon

        frame.cards[i] = card
    end

    -- "Next proc" readout
    local readout = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    readout:SetPoint("BOTTOM", frame, "BOTTOM", 0, 7)
    readout:SetText("Next proc: --")
    frame.readout = readout

    self.frame = frame

    self:CreateMinimapButton()
    self:CreateOptions()
    self:UpdateScale()
    self:UpdateOpacity()
end

-- ============================================================
-- Refresh display from deck state
-- ============================================================
function ui:Refresh()
    local frame = self.frame
    if not frame then return end

    local s = addon.deck:GetDisplayState()
    local hr, hg, hb = probColor(s.nextProb)

    for i = 1, 3 do
        local isHi = (s.highlightSlot == i)
        renderCard(frame.cards[i], s.cards[i], isHi, hr, hg, hb)
    end

    -- Readout line
    if not s.watchSlotOk then
        frame.readout:SetText("|cffff5555PW:S not on action bar|r")
    elseif s.nextProb == nil then
        frame.readout:SetText("|cffff8800Recalibrating...|r")
    else
        local pct = math.floor(s.nextProb * 100 + 0.5)
        local r, g, b = probColor(s.nextProb)
        local hex = string.format("%02x%02x%02x",
            math.floor(r * 255 + 0.5), math.floor(g * 255 + 0.5), math.floor(b * 255 + 0.5))
        local thenStr = ""
        if s.next2Prob then
            thenStr = string.format("  |cff888888then %d%%|r",
                math.floor(s.next2Prob * 100 + 0.5))
        end
        local calib = s.calibrating and " |cff888888(calibrating)|r" or ""
        frame.readout:SetText(string.format(
            "Next proc: |cff%s%d%%|r%s%s", hex, pct, thenStr, calib))
    end

    -- Title tints cyan when a guaranteed proc is next.
    if s.nextProb and s.nextProb >= 1.0 then
        frame.title:SetTextColor(0.2, 0.9, 0.9)
    else
        frame.title:SetTextColor(0.7, 0.7, 0.9)
    end
end

-- ============================================================
-- Visibility / scale
-- ============================================================
function ui:UpdateVisibility()
    if not self.frame then return end
    if addon.isDiscPriest and VSTDB.shown then
        self.frame:Show()
    else
        self.frame:Hide()
    end
    if self.minimapButton then
        if VSTDB.minimap.hide then
            self.minimapButton:Hide()
        else
            self.minimapButton:Show()
        end
    end
end

function ui:UpdateScale()
    if self.frame then self.frame:SetScale(VSTDB.scale or 1.0) end
end

function ui:UpdateOpacity()
    if self.frame then self.frame:SetAlpha(VSTDB.opacity or 1.0) end
end

function ui:ToggleShown()
    VSTDB.shown = not VSTDB.shown
    self:UpdateVisibility()
end

function ui:ResetPosition()
    VSTDB.pos = nil
    self.frame:ClearAllPoints()
    self.frame:SetPoint("CENTER", UIParent, "CENTER", 0, 120)
end

-- ============================================================
-- Minimap button
-- ============================================================
-- Place the button centre on the minimap rim (half in / half out) regardless
-- of the minimap's actual size, matching LibDBIcon / other addons.
local function minimapRadius()
    return (Minimap:GetWidth() / 2) + 6
end

function ui:UpdateMinimapPosition()
    local btn = self.minimapButton
    if not btn then return end
    local angle = math.rad(VSTDB.minimap.angle or 220)
    local r = minimapRadius()
    btn:ClearAllPoints()
    btn:SetPoint("CENTER", Minimap, "CENTER",
        math.cos(angle) * r,
        math.sin(angle) * r)
end

function ui:CreateMinimapButton()
    local btn = CreateFrame("Button", "VoidShieldTrackerMinimapButton", Minimap)
    btn:SetSize(31, 31)
    btn:SetFrameStrata("MEDIUM")
    btn:SetFrameLevel(8)

    local icon = btn:CreateTexture(nil, "BACKGROUND")
    icon:SetSize(20, 20)
    icon:SetPoint("CENTER", btn, "CENTER", 0, 0)
    icon:SetTexture(TX_PROC)
    icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)

    local overlay = btn:CreateTexture(nil, "OVERLAY")
    overlay:SetSize(53, 53)
    overlay:SetPoint("TOPLEFT", btn, "TOPLEFT", 0, 0)
    overlay:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")

    btn:SetHighlightTexture("Interface\\Minimap\\UI-Minimap-ZoomButton-Highlight")

    btn:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    btn:RegisterForDrag("LeftButton")

    btn:SetScript("OnDragStart", function(self)
        self:SetScript("OnUpdate", function()
            local mx, my = Minimap:GetCenter()
            local scale  = Minimap:GetEffectiveScale()
            local px, py = GetCursorPosition()
            px, py = px / scale, py / scale
            VSTDB.minimap.angle = math.deg(math.atan2(py - my, px - mx))
            ui:UpdateMinimapPosition()
        end)
    end)
    btn:SetScript("OnDragStop", function(self)
        self:SetScript("OnUpdate", nil)
    end)

    btn:SetScript("OnClick", function(_, button)
        if button == "LeftButton" then
            ui:OpenOptions()
        elseif button == "RightButton" then
            addon.deck:Reset()
            DEFAULT_CHAT_FRAME:AddMessage(
                "|cff88ccffVoid Shield Tracker|r: deck reset.", 0.5, 0.7, 1)
        end
    end)

    btn:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_LEFT")
        GameTooltip:AddLine("Void Shield Tracker", 0.5, 0.7, 1)
        GameTooltip:AddLine("Left-click: options", 0.8, 0.8, 0.8)
        GameTooltip:AddLine("Right-click: reset deck", 0.8, 0.8, 0.8)
        GameTooltip:AddLine("Drag: reposition", 0.8, 0.8, 0.8)
        GameTooltip:Show()
    end)
    btn:SetScript("OnLeave", function() GameTooltip:Hide() end)

    self.minimapButton = btn
    self:UpdateMinimapPosition()
end

-- ============================================================
-- Options panel (modern Settings API)
-- ============================================================
local function makeCheckbox(parent, label, x, y, getFn, setFn)
    local cb = CreateFrame("CheckButton", nil, parent, "UICheckButtonTemplate")
    cb:SetPoint("TOPLEFT", parent, "TOPLEFT", x, y)
    cb:SetSize(26, 26)
    local text = cb:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
    text:SetPoint("LEFT", cb, "RIGHT", 4, 0)
    text:SetText(label)
    cb:SetScript("OnShow", function(self) self:SetChecked(getFn()) end)
    cb:SetScript("OnClick", function(self) setFn(self:GetChecked()) end)
    cb:SetChecked(getFn())
    return cb
end

local function makeSlider(parent, label, x, y, minV, maxV, step, getFn, setFn, fmt)
    local slider = CreateFrame("Slider", nil, parent, "UISliderTemplate")
    slider:SetPoint("TOPLEFT", parent, "TOPLEFT", x + 4, y - 18)
    slider:SetWidth(220)
    slider:SetHeight(16)
    slider:SetOrientation("HORIZONTAL")
    slider:SetMinMaxValues(minV, maxV)
    slider:SetValueStep(step)
    slider:SetObeyStepOnDrag(true)

    local title = slider:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
    title:SetPoint("BOTTOMLEFT", slider, "TOPLEFT", 0, 2)

    local function updateLabel(v)
        title:SetText(label .. ": " .. fmt(v))
    end

    slider:SetScript("OnValueChanged", function(self, value)
        updateLabel(value)
        setFn(value)
    end)
    slider:SetScript("OnShow", function(self)
        self:SetValue(getFn())
        updateLabel(getFn())
    end)
    slider:SetValue(getFn())
    updateLabel(getFn())
    return slider
end

local function makeButton(parent, label, x, y, onClick)
    local b = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
    b:SetSize(150, 24)
    b:SetPoint("TOPLEFT", parent, "TOPLEFT", x, y)
    b:SetText(label)
    b:SetScript("OnClick", onClick)
    return b
end

function ui:CreateOptions()
    if self.optionsPanel then return end

    local panel = CreateFrame("Frame", "VoidShieldTrackerOptionsPanel", UIParent)
    panel.name = "Void Shield Tracker"

    local title = panel:CreateFontString(nil, "ARTWORK", "GameFontNormalLarge")
    title:SetPoint("TOPLEFT", 16, -16)
    title:SetText("Void Shield Tracker")

    local subtitle = panel:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
    subtitle:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -4)
    subtitle:SetText("Tracks the Discipline Priest Void Shield proc deck.")

    local y = -64
    makeCheckbox(panel, "Show tracker", 16, y,
        function() return VSTDB.shown end,
        function(v) VSTDB.shown = v; ui:UpdateVisibility() end)

    y = y - 30
    makeCheckbox(panel, "Lock frame position", 16, y,
        function() return VSTDB.locked end,
        function(v) VSTDB.locked = v end)

    y = y - 30
    makeCheckbox(panel, "Show minimap button", 16, y,
        function() return not VSTDB.minimap.hide end,
        function(v) VSTDB.minimap.hide = not v; ui:UpdateVisibility() end)

    y = y - 30
    makeCheckbox(panel, "Assume fresh deck on entering an instance", 16, y,
        function() return VSTDB.pruneOnZone end,
        function(v) VSTDB.pruneOnZone = v end)

    y = y - 46
    makeSlider(panel, "Frame scale", 16, y, 0.5, 2.0, 0.05,
        function() return VSTDB.scale end,
        function(v) VSTDB.scale = v; ui:UpdateScale() end,
        function(v) return string.format("%.0f%%", v * 100) end)

    y = y - 56
    makeSlider(panel, "Opacity", 16, y, 0.1, 1.0, 0.05,
        function() return VSTDB.opacity end,
        function(v) VSTDB.opacity = v; ui:UpdateOpacity() end,
        function(v) return string.format("%.0f%%", v * 100) end)

    y = y - 56
    makeSlider(panel, "Proc detection delay", 16, y, 50, 500, 10,
        function() return VSTDB.procCheckDelayMs end,
        function(v) VSTDB.procCheckDelayMs = math.floor(v + 0.5) end,
        function(v) return string.format("%d ms", math.floor(v + 0.5)) end)

    y = y - 60
    makeButton(panel, "Reset deck", 16, y, function()
        addon.deck:Reset()
    end)
    makeButton(panel, "Reset frame position", 180, y, function()
        ui:ResetPosition()
    end)

    self.optionsPanel = panel

    -- Register with the Settings API (12.0). Keep the auto-assigned numeric
    -- category ID intact; OpenToCategory expects that number, not a string.
    if Settings and Settings.RegisterCanvasLayoutCategory then
        local category = Settings.RegisterCanvasLayoutCategory(panel, panel.name)
        Settings.RegisterAddOnCategory(category)
        self.optionsCategory = category
    end
end

function ui:OpenOptions()
    if self.optionsCategory and Settings and Settings.OpenToCategory then
        Settings.OpenToCategory(self.optionsCategory:GetID())
    elseif InterfaceOptionsFrame_OpenToCategory and self.optionsPanel then
        InterfaceOptionsFrame_OpenToCategory(self.optionsPanel)
    end
end

-- ============================================================
-- Slash commands
-- ============================================================
_G.SLASH_VST1 = "/vst"
_G.SLASH_VST2 = "/voidshieldtracker"
_G.SlashCmdList["VST"] = function(msg)
    msg = (msg or ""):lower():gsub("^%s*(.-)%s*$", "%1")
    local function p(t) DEFAULT_CHAT_FRAME:AddMessage("|cff88ccffVoid Shield Tracker|r: " .. t, 0.5, 0.7, 1) end

    if msg == "" or msg == "options" or msg == "config" then
        ui:OpenOptions()
    elseif msg == "toggle" then
        ui:ToggleShown()
        p(VSTDB.shown and "shown." or "hidden.")
    elseif msg == "reset" then
        addon.deck:Reset()
        p("deck reset.")
    elseif msg == "resetpos" then
        ui:ResetPosition()
        p("frame position reset.")
    elseif msg == "status" then
        p(addon.deck:Status())
    else
        p("commands: /vst [options|toggle|reset|resetpos|status]")
    end
end
