--[[
Core.lua - Addon core: namespace, event dispatch, initialization.
Loaded FIRST (top of TOC). Creates the shared addon namespace table
and the event frame at module load time.

WoW 12.0: COMBAT_LOG_EVENT_UNFILTERED registration is forbidden
for addons (triggers ADDON_ACTION_FORBIDDEN). We detect Penance casts
via the "Master the Darkness" proc buff in UNIT_AURA instead.
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
-- ============================================================
local eventFrame = CreateFrame("Frame")
local EVENT_LIST = {
    "ADDON_LOADED",
    "PLAYER_LOGIN",
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

    if event == "PLAYER_LOGIN" then
        addon:OnLogin()
        addon.initialized = true
        return
    end

    -- Everything below requires the addon to be initialized
    if not addon.initialized then
        return
    end

    if event == "UNIT_AURA" then
        local unit = select(1, ...)
        if unit == "player" then
            addon.deck:OnPlayerAura()
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
    -- Build UI FIRST (so OnPlayerAura has addon.ui available during init)
    self.ui:Create()

    -- Initialize deck state
    self.deck:Initialize()

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
        0.5, 0.7, 1)
    local f = self.ui.frame
    local numPoints = f:GetNumPoints()
    DEFAULT_CHAT_FRAME:AddMessage(
        "|cff88ccffVST|r: shown=" .. tostring(f:IsShown())
        .. " size=" .. tostring(f:GetWidth()) .. "x" .. tostring(f:GetHeight())
        .. " strata=" .. tostring(f:GetFrameStrata())
        .. " numAnchors=" .. tostring(numPoints))
end
