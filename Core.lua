--[[
Core.lua - Addon core: namespace, event dispatch, initialization.
Loaded FIRST (top of TOC). Creates the shared addon namespace table
and the event frame at module load time so RegisterEvent happens
before any combat lockdown can apply.

Pattern: the addon table is stored in a global (_G[addonName]) so
Deck.lua and UI.lua can reference the same table via `...`.
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
-- Created at module load time, NOT inside PLAYER_LOGIN.
-- Events registered immediately - no combat lockdown possible
-- because this runs during addon load, before any combat.
-- ============================================================
local eventFrame = CreateFrame("Frame")
local EVENT_LIST = {
    "ADDON_LOADED",
    "PLAYER_LOGIN",
    "COMBAT_LOG_EVENT_UNFILTERED",
    "UNIT_AURA",
    "GROUP_ROSTER_UPDATE",
    "PLAYER_ENTERING_WORLD",
}
for _, e in ipairs(EVENT_LIST) do
    eventFrame:RegisterEvent(e)
end

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

    -- Everything below requires the addon to be initialized
    if not addon.initialized then
        if event == "PLAYER_LOGIN" then
            addon:OnLogin()
            addon.initialized = true
        end
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
