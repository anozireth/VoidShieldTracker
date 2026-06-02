--[[
    Core.lua - Addon namespace, saved variables, event dispatch, lifecycle.
    Loaded first. Creates the shared addon table and the single event frame.

    WoW 12.0 note: COMBAT_LOG_EVENT_UNFILTERED is forbidden for addons. Penance
    casts are detected via UNIT_SPELLCAST_CHANNEL_START instead (see Deck.lua).
]]

local addonName = ...

-- Shared addon table (global so Deck.lua / UI.lua reference the same table).
local addon = _G[addonName] or {}
_G[addonName] = addon

addon.name = addonName
addon.initialized = false
addon.isDiscPriest = false

-- ============================================================
-- Saved-variable defaults
-- ============================================================
local DB_DEFAULTS = {
    shown            = true,
    locked           = false,
    scale            = 1.0,
    opacity          = 1.0,
    procCheckDelayMs = 200,
    pruneOnZone      = true,   -- assume a fresh deck when entering an instance
    minimap          = { hide = false, angle = 220 },
}

local function applyDefaults(db, defaults)
    for k, v in pairs(defaults) do
        if type(v) == "table" then
            if type(db[k]) ~= "table" then db[k] = {} end
            applyDefaults(db[k], v)
        elseif db[k] == nil then
            db[k] = v
        end
    end
end

-- ============================================================
-- Spec detection (Discipline Priest only)
-- ============================================================
local function updateSpecState()
    local _, class = UnitClass("player")
    local spec = GetSpecialization and GetSpecialization()
    addon.isDiscPriest = (class == "PRIEST" and spec == 1)
end

-- ============================================================
-- Ticker (drives action-bar polling + shield-state refresh)
-- ============================================================
local ticker

local function startTicker()
    if ticker then return end
    ticker = C_Timer.NewTicker(0.1, function()
        if addon.deck and addon.deck.Tick then
            local changed = addon.deck:Tick()
            if changed and addon.ui and addon.ui.Refresh then
                addon.ui:Refresh()
            end
        end
    end)
end

local function stopTicker()
    if ticker then
        ticker:Cancel()
        ticker = nil
    end
end

-- Show/hide and start/stop based on spec + user preference.
function addon:UpdateActiveState()
    local active = self.isDiscPriest
    if active then
        startTicker()
    else
        stopTicker()
    end
    if self.ui and self.ui.UpdateVisibility then
        self.ui:UpdateVisibility()
    end
end

-- ============================================================
-- Initialization (PLAYER_LOGIN)
-- ============================================================
local function onLogin()
    if addon.initialized then return end

    VSTDB = VSTDB or {}
    applyDefaults(VSTDB, DB_DEFAULTS)

    addon.ui:Create()
    addon.deck:Initialize()
    updateSpecState()

    addon.initialized = true

    addon:UpdateActiveState()
    addon.ui:Refresh()

    DEFAULT_CHAT_FRAME:AddMessage(
        "|cff88ccffVoid Shield Tracker|r loaded. Type |cffffd100/vst|r for options.",
        0.5, 0.7, 1)
end

-- ============================================================
-- Event frame
-- ============================================================
local eventFrame = CreateFrame("Frame")
eventFrame:RegisterEvent("PLAYER_LOGIN")
eventFrame:RegisterEvent("PLAYER_ENTERING_WORLD")
eventFrame:RegisterEvent("PLAYER_SPECIALIZATION_CHANGED")
eventFrame:RegisterEvent("PLAYER_TALENT_UPDATE")
eventFrame:RegisterEvent("TRAIT_CONFIG_UPDATED")
eventFrame:RegisterEvent("UNIT_SPELLCAST_CHANNEL_START")
eventFrame:RegisterEvent("ACTIONBAR_SLOT_CHANGED")

eventFrame:SetScript("OnEvent", function(_, event, ...)
    if event == "PLAYER_LOGIN" then
        onLogin()

    elseif not addon.initialized then
        return

    elseif event == "PLAYER_ENTERING_WORLD" then
        updateSpecState()
        addon.deck:OnEnterWorld()
        addon:UpdateActiveState()

    elseif event == "PLAYER_SPECIALIZATION_CHANGED"
        or event == "PLAYER_TALENT_UPDATE"
        or event == "TRAIT_CONFIG_UPDATED" then
        local unit = ...
        if event == "PLAYER_SPECIALIZATION_CHANGED" and unit ~= "player" then
            return
        end
        updateSpecState()
        addon.deck:Reset()
        addon:UpdateActiveState()

    elseif event == "UNIT_SPELLCAST_CHANNEL_START" then
        if not addon.isDiscPriest then return end
        local unit, _, spellID = ...
        if unit == "player" then
            addon.deck:OnPenanceCast(spellID)
        end

    elseif event == "ACTIONBAR_SLOT_CHANGED" then
        if addon.deck and addon.deck.Tick then
            addon.deck:Tick()
        end
    end
end)
