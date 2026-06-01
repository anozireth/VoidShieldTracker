--[[
Void Shield Tracker
Tracks Discipline Priest Void Shift proc deck mechanics.
Deck: 3 cards (1 proc, 2 non-proc), reshuffles after all 3 drawn.
Each Penance cast draws one card. Deck resets after 3 casts.
]]

local addonName = ...
local addon = CreateFromMixins(CreateFrame("Frame"))
addon.name = addonName

-- Spell IDs
local SPELL_ID_PENANCE = 47540
local SPELL_ID_VOID_SHIFT = 194322
local PROC_BUFF_NAME = "Master the Darkness"

-- Textures
local TX_PROC = "Interface\\Icons\\Spell_Holy_PowerWordShield"
local TX_NOPROC = "Interface\\Icons\\INV_Misc_QuestionMark"
local TX_EMPTY = "Interface\\Buttons\\UI-EmptySlot"

-- ============================================================
-- State
-- ============================================================
local deckCount = 0          -- 0-3, number of draws in current deck
local procPending = false    -- true if proc buff arrived but not yet applied to icon
local marked = {}            -- tracks which deck slots have been written
local inDungeon = false      -- true when in a dungeon/Mythic+
local history = {}           -- rolling proc history for smart detection (0=no, 1=yes)
local HISTORY_MAX = 20
local historyLocked = false  -- true once smart detection found a boundary
local hadProcBuff = false    -- track if proc buff was present last check

-- ============================================================
-- Frame setup
-- ============================================================
local frame = CreateFrame("Frame", "VoidShieldTrackerFrame", UIParent)
frame:SetWidth(200)
frame:SetHeight(64)
frame:SetPoint("CENTER", UIParent, "CENTER", 0, 0)
frame:SetMovable(true)
frame:EnableMouse(true)
frame:RegisterForDrag("LeftButton")
frame:SetScript("OnDragStart", frame.StartMoving)
frame:SetScript("OnDragStop", function(self)
    self:StopMovingOrSizing()
    -- Save position
    VSTDB = VSTDB or {}
    VSTDB.frameX = self:GetCenter() - UIParent:GetCenter()
    VSTDB.frameY = self:GetTop() - UIParent:GetTop()
end)
frame:SetFrameStrata("MEDIUM")
frame:SetFrameLevel(5)

-- Background
local bg = frame:CreateTexture(nil, "BACKGROUND")
bg:SetAllPoints(frame)
bg:SetTexture(0, 0, 0, 0.75)

-- Border
local border = frame:CreateTexture(nil, "BORDER")
border:SetAllPoints(frame)
border:SetTexture(0.4, 0.4, 0.5, 1)

-- Title
local title = frame:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
title:SetPoint("TOP", frame, "TOP", 0, -4)
title:SetText("VOID SHIFT DECK")
title:SetTextColor(0.7, 0.7, 0.9)

-- Icon slots
local icons = {}
local SLOT_SIZE = 48
local SLOT_GAP = 8
local totalWidth = SLOT_SIZE * 3 + SLOT_GAP * 2

for i = 1, 3 do
    local icon = CreateFrame("Frame", nil, frame)
    icon:SetSize(SLOT_SIZE, SLOT_SIZE)

    -- Position centered horizontally
    local xPos = -totalWidth / 2 + (SLOT_SIZE + SLOT_GAP) * (i - 1) + SLOT_SIZE / 2
    icon:SetPoint("CENTER", frame, "CENTER", xPos, 0)

    local tex = icon:CreateTexture(nil, "ARTWORK")
    tex:SetAllPoints(icon)
    tex:SetTexture(TX_EMPTY)
    tex:SetVertexColor(0.3, 0.3, 0.3, 0.5)

    -- Border around slot
    local slotBorder = icon:CreateTexture(nil, "OVERLAY")
    slotBorder:SetAllPoints(icon)
    slotBorder:SetTexture(0.3, 0.3, 0.4, 0.8)

    icons[i] = { frame = icon, texture = tex }
end

-- ============================================================
-- Icon update functions
-- ============================================================
local function SetIcon(slot, state)
    -- slot: 1-3, state: "empty" / "proc" / "noproc"
    local icon = icons[slot]
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

local function ClearIcons()
    for i = 1, 3 do
        SetIcon(i, "empty")
    end
end

-- ============================================================
-- Deck logic
-- ============================================================
local function ResetDeck()
    deckCount = 0
    procPending = false
    hadProcBuff = false
    for i = 1, 3 do marked[i] = false end
    ClearIcons()
end

local function OnPenanceCast()
    -- If a proc buff arrived since last cast, mark the previous slot as proc
    if procPending then
        -- Find the last unmarked slot and mark it as proc
        for i = deckCount, 1, -1 do
            if not marked[i] then
                SetIcon(i, "proc")
                marked[i] = true
                history[#history + 1] = 1
                if #history > HISTORY_MAX then table.remove(history, 1) end
                procPending = false
                break
            end
        end
    end

    -- Draw the next card (increment deck count)
    deckCount = deckCount + 1

    if deckCount > 3 then
        -- Overflow safety net
        ResetDeck()
        deckCount = 1
    end

    -- Mark this slot as non-proc (default; proc buff may override later)
    if not marked[deckCount] then
        SetIcon(deckCount, "noproc")
        marked[deckCount] = true
        history[#history + 1] = 0
        if #history > HISTORY_MAX then table.remove(history, 1) end
    end

    -- Deck complete? Schedule reset after 1 second
    if deckCount >= 3 then
        C_Timer.After(1, function()
            ResetDeck()
        end)
    end

    -- Smart detection check (only outside dungeons)
    if not inDungeon and not historyLocked then
        CheckSmartDetection()
    end
end

local function OnProcBuffGained()
    procPending = true
end

-- ============================================================
-- Smart detection (outside dungeons)
-- ============================================================
local function CheckSmartDetection()
    if historyLocked then return end
    if #history < 6 then return end

    local n = #history

    -- Pattern 1: Two procs in a row -> boundary between them
    -- The second proc is position 1 of a new deck
    for i = 2, n do
        if history[i] == 1 and history[i - 1] == 1 then
            -- Boundary is between i-1 and i
            -- i is position 1 of new deck
            local castsAfterBoundary = n - i  -- number of casts after the boundary proc
            deckCount = 1 + castsAfterBoundary
            if deckCount > 3 then
                deckCount = ((deckCount - 1) % 3) + 1
            end

            -- Rebuild marked array for current deck
            for j = 1, 3 do marked[j] = false end
            for j = 1, deckCount do
                local histIdx = i + j
                if histIdx <= n then
                    SetIcon(j, history[histIdx] == 1 and "proc" or "noproc")
                    marked[j] = true
                end
            end
            historyLocked = true
            DEFAULT_CHAT_FRAME:AddMessage("|cff88ccffVoid Shield Tracker|r: Deck boundary detected (consecutive procs)", 0.5, 0.7, 1)
            return
        end
    end

    -- Pattern 2: Four non-procs in a row -> boundary after the 2nd
    -- A single deck can only produce max 2 non-procs before a proc,
    -- so 4 non-procs means the boundary is between non-proc 2 and 3
    for i = 4, n do
        if history[i] == 0 and history[i-1] == 0 and
           history[i-2] == 0 and history[i-3] == 0 then
            -- Boundary is between i-2 and i-1
            -- i-1 is position 1 of new deck (non-proc)
            local boundaryPos = i - 1
            local castsFromBoundary = n - boundaryPos + 1
            deckCount = castsFromBoundary
            if deckCount > 3 then
                deckCount = ((deckCount - 1) % 3) + 1
            end

            for j = 1, 3 do marked[j] = false end
            for j = 1, deckCount do
                local histIdx = boundaryPos + j - 1
                if histIdx <= n then
                    SetIcon(j, history[histIdx] == 1 and "proc" or "noproc")
                    marked[j] = true
                end
            end
            historyLocked = true
            DEFAULT_CHAT_FRAME:AddMessage("|cff88ccffVoid Shield Tracker|r: Deck boundary detected (4 non-procs)", 0.5, 0.7, 1)
            return
        end
    end
end

-- ============================================================
-- Dungeon detection
-- ============================================================
local function CheckDungeonState()
    local wasDungeon = inDungeon

    -- Check multiple indicators
    inDungeon = false
    if C_GossipInfo and C_GossipInfo.GetPOIData and C_GossipInfo.GetPOIData() then
        inDungeon = true
    end
    if C_MythicPlus and C_MythicPlus.GetMapState and C_MythicPlus.GetMapState() then
        inDungeon = true
    end
    if IsInGroup(LE_PARTY_CATEGORY_HOME) then
        inDungeon = true
    end

    if inDungeon and not wasDungeon then
        ResetDeck()
        historyLocked = false
        history = {}
        DEFAULT_CHAT_FRAME:AddMessage("|cff88ccffVoid Shield Tracker|r: Dungeon detected - deck reset", 0.5, 0.7, 1)
    elseif not inDungeon and wasDungeon then
        historyLocked = false
        history = {}
    end
end

-- ============================================================
-- Event handlers
-- =================================================-----------
local playerGUID = nil

frame:RegisterEvent("COMBAT_LOG_EVENT_UNFILTERED")
frame:RegisterEvent("UNIT_AURA")
frame:RegisterEvent("GROUP_ROSTER_UPDATE")
frame:RegisterEvent("PLAYER_ENTERING_WORLD")
frame:RegisterEvent("MINIMAP_BUTTONS_REGISTERED")

frame:SetScript("OnEvent", function(self, event, ...)
    if event == "COMBAT_LOG_EVENT_UNFILTERED" then
        if not playerGUID then
            playerGUID = UnitGUID("player")
        end

        local _, eventType, srcGUID, srcName, srcFlags, dstGUID, dstName, dstFlags, spellID = CombatLogGetCurrentEventInfo()

        -- Detect Penance cast by player
        if eventType == "SPELL_CAST_SUCCESS" and srcGUID == playerGUID and spellID == SPELL_ID_PENANCE then
            OnPenanceCast()
        end

    elseif event == "UNIT_AURA" then
        local unit = select(1, ...)
        if unit == "player" then
            -- Check for Master the Darkness buff using UnitAura
            local hasProcBuff = false
            for i = 1, 100 do
                local auraName = UnitAura(unit, i, "PLAYER|HELPFUL")
                if auraName == PROC_BUFF_NAME then
                    hasProcBuff = true
                    break
                end
            end

            if hasProcBuff and not hadProcBuff then
                OnProcBuffGained()
            end
            hadProcBuff = hasProcBuff

        end

    elseif event == "GROUP_ROSTER_UPDATE" then
        CheckDungeonState()

    elseif event == "PLAYER_ENTERING_WORLD" then
        -- Check if we entered a dungeon/scenario
        local isInstance, instanceType = IsInInstance()
        if instanceType == "party" or instanceType == "raid" or instanceType == "scenario" then
            inDungeon = true
            ResetDeck()
            historyLocked = false
            history = {}
            DEFAULT_CHAT_FRAME:AddMessage("|cff88ccffVoid Shield Tracker|r: Entered instance - deck reset", 0.5, 0.7, 1)
        end

    elseif event == "MINIMAP_BUTTONS_REGISTERED" then
        if minimapButton then
            minimapButton:Show()
        end
    end
end)

-- ============================================================
-- Minimap button
-- ============================================================
local minimapButton = CreateFrame("Button", "VoidShieldTrackerMinimapButton", Minimap)
minimapButton:SetSize(32, 32)
minimapButton:SetPoint("TOP", Minimap, "TOP", 0, 0)
minimapButton:SetFrameStrata("LOW")
minimapButton:Hide()

minimapButton:SetNormalTexture(TX_PROC)
minimapButton:SetPushedTexture(TX_PROC)
minimapButton:SetHighlightTexture("Interface\\Buttons\\UI-Minimap-ZoomButton-Highlight")

-- Tooltip
minimapButton:SetScript("OnEnter", function()
    GameTooltip:SetOwner(minimapButton, "ANCHOR_RIGHT")
    GameTooltip:AddLine("Void Shield Tracker", 0.5, 0.7, 1, true)
    GameTooltip:AddLine("Left-click: Toggle visibility", 0.7, 0.7, 0.7)
    GameTooltip:AddLine("Right-click: Reset deck", 0.7, 0.7, 0.7)
    GameTooltip:Show()
end)
minimapButton:SetScript("OnLeave", function()
    GameTooltip:Hide()
end)

-- Minimap button drag
minimapButton:EnableMouse(true)
minimapButton:RegisterForDrag("LeftButton")
minimapButton:SetScript("OnDragStart", minimapButton.StartMoving)
minimapButton:SetScript("OnDragStop", function(self)
    self:StopMovingOrSizing()
    self:ClearAllPoints()
    self:SetClampRectInsets(5, 5, 5, 5)
    self:SetClampRectRelativeToCurrentParent()
end)

minimapButton:SetScript("OnClick", function(self, button)
    if button == "LeftButton" then
        if frame:IsShown() then
            frame:Hide()
        else
            frame:Show()
        end
    elseif button == "RightButton" then
        ResetDeck()
        historyLocked = false
        history = {}
        DEFAULT_CHAT_FRAME:AddMessage("|cff88ccffVoid Shield Tracker|r: Deck manually reset", 0.5, 0.7, 1)
    end
end)

-- ============================================================
-- Slash command
-- ============================================================
SLASH_VST1 = "/vst"
SLASH_VST2 = "/voidshieldtracker"
SlashCmdList["VST"] = function(msg)
    msg = msg:lower():gsub("^%s*(.-)%s*$", "%1")
    if msg == "toggle" or msg == "" then
        if frame:IsShown() then
            frame:Hide()
            DEFAULT_CHAT_FRAME:AddMessage("|cff88ccffVoid Shield Tracker|r: Hidden", 0.5, 0.7, 1)
        else
            frame:Show()
            DEFAULT_CHAT_FRAME:AddMessage("|cff88ccffVoid Shield Tracker|r: Shown", 0.5, 0.7, 1)
        end
    elseif msg == "reset" then
        ResetDeck()
        historyLocked = false
        history = {}
        DEFAULT_CHAT_FRAME:AddMessage("|cff88ccffVoid Shield Tracker|r: Deck manually reset", 0.5, 0.7, 1)
    elseif msg == "status" then
        DEFAULT_CHAT_FRAME:AddMessage(string.format(
            "|cff88ccffVoid Shield Tracker|r: Deck: %d/3 | Dungeon: %s | Smart locked: %s | History: %d",
            deckCount, inDungeon and "yes" or "no", historyLocked and "yes" or "no", #history), 0.5, 0.7, 1)
    else
        DEFAULT_CHAT_FRAME:AddMessage("|cff88ccffVoid Shield Tracker|r: Commands: /vst [toggle|reset|status]", 0.5, 0.7, 1)
    end
end

-- ============================================================
-- Saved variables: frame position
-- ============================================================
VSTDB = VSTDB or {}

-- Load saved frame position
if VSTDB.frameX and VSTDB.frameY then
    frame:ClearAllPoints()
    frame:SetPoint("CENTER", UIParent, "CENTER", VSTDB.frameX, VSTDB.frameY)
end

-- Show frame by default
frame:Show()

DEFAULT_CHAT_FRAME:AddMessage("|cff88ccffVoid Shield Tracker|r: Loaded (use /vst for commands)", 0.5, 0.7, 1)
