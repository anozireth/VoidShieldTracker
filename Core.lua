--[[
Core.lua - Addon core: namespace, event dispatch, initialization.
Loaded FIRST (top of TOC). Creates the shared addon namespace table
and the event frame at module load time.

Pattern: the addon table is stored in a global (_G[addonName]) so
Deck.lua and UI.lua can reference the same table via `...`.

IMPORTANT: WoW 12.0 blocks RegisterEvent for combat-related events
(COMBAT_LOG_EVENT_UNFILTERED, UNIT_AURA, etc.) when called during
the addon loading phase. We only register ADDON_LOADED and PLAYER_LOGIN
at load time, then register the rest inside the PLAYER_LOGIN handler
after the UI is fully initialized.
]]

local addonName = ...

-- Shared addon table (global so other files see the same table via ...)
local addon = _G[addonName] or {}
_G[addonName] = addon

-- ============================================================
-- State (populated by submodules)
-- ============================================================
addon.deck = nil    -- populated by Deck.lua
addon.ui = nil      -- populated by UI.lua
addon.initialized = false

-- ============================================================
-- Event frame (anonymous - avoids action security issues)
-- Only bootstrap events registered here. Combat events are
-- deferred to PLAYER_LOGIN to avoid WoW 12.0 action security
-- restrictions on RegisterEvent during addon loading.
-- ============================================================
local eventFrame = CreateFrame("Frame")
eventFrame:RegisterEvent("ADDON_LOADED")
eventFrame:RegisterEvent("PLAYER_LOGIN")

-- Events to register AFTER PLAYER_LOGIN fires
local DEFERRED_EVENTS = {
    "COMBAT_LOG_EVENT_UNFILTERED",
    "UNIT_AURA",
    "GROUP_ROSTER_UPDATE",
    "PLAYER_ENTERING_WORLD",
}

-- ============================================================
-- Player GUID cache
-- ============================================================
local playerGUID

-- ============================================================
-- Event dispatch
-- ============================================================
eventFrame:SetScript("OnEvent", function(self, event, ...)
    if event == "ADDON_LOADED" then
        local name = select(1, ...)
        if name == addonName then
            playerGUID = nil
        end
        return
    end

    if event == "PLAYER_LOGIN" then
        -- Register combat-dependent events NOW, after UI is ready
        for _, e in ipairs(DEFERRED_EVENTS) do
            eventFrame:RegisterEvent(e)
        end

        addon:OnLogin()
        addon.initialized = true
        return
    end

    -- Everything below requires the addon to be initialized
    if not addon.initialized then
        return
    end

    if event == "COMBAT_LOG_EVENT_UNFILTERED" then
        if not playerGUID then
            playerGUID = UnitGUID("player")
        end
        local _, eventType, srcGUID, _, _, _, _, _, spellID = CombatLogGetCurrentEventInfo()
        if eventType == "SPELL_CAST_SUCCESS" and srcGUID == playerGUID then
            addon.deck:OnPenanceCast()
        end

    elseif event == "UNIT_AURA" then
        local unit = select(1, ...)
        if unit == "player" then
            addon.deck:CheckAura()
        end

    elseif event == "GROUP_ROSTER_UPDATE" then
        addon.deck:CheckDungeonState()

    elseif event == "PLAYER_ENTERING_WORLD" then
        addon.deck:OnEnterWorld()
    end
end)

-- ============================================================
-- Initialization entry point (called from PLAYER_LOGIN event)
-- ============================================================
function addon:OnLogin()
    -- Initialize deck state
    self.deck:Initialize()

    -- Build UI
    self.ui:Create()

    -- Restore saved position
    local db = VSTDB or {}
    if db.frameX and db.frameY then
        local f = self.ui.frame
        f:ClearAllPoints()
        f:SetPoint("CENTER", UIParent, "CENTER", db.frameX, db.frameY)
    end

    -- Check initial dungeon state
    self.deck:CheckDungeonState()

    -- Show
    self.ui.frame:Show()

    DEFAULT_CHAT_FRAME:AddMessage(
        "|cff88ccffVoid Shield Tracker|r: Loaded (use /vst for commands)",
        0.5, 0.7, 1
    )
end
