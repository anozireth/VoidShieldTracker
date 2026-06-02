--[=[
    Deck.lua - Deck tracking logic for Discipline Priest Void Shield.

    Detection: UNIT_SPELLCAST_CHANNEL_START with Penance spell IDs.
    Reset: proc buff reapplies after 3 casts (detected via UNIT_AURA).

    Spell ID chain (per SimulationCraft / SpellData):
      47540  base driver cast on enemy (fires CHANNEL_START for offensive)
      47758  damage channel triggered by 47540
      47666  per-bolt tick - damage or healing (fires UNIT_SPELLCAST_SUCCEEDED)
      47757  healing channel cast on friendly (fires CHANNEL_START for healing)
      47750  per-bolt healing tick (fires UNIT_SPELLCAST_SUCCEEDED)
    All IDs are matched so any variant that surfaces on CHANNEL_START is caught.
]=]

local addon = _G["VoidShieldTracker"]

local deck = {}
addon.deck = deck

-- ============================================================
-- Penance spell IDs to match on UNIT_SPELLCAST_CHANNEL_START
-- ============================================================
local PENANCE_SPELL_IDS = {
    [47540] = true,  -- Penance base driver (enemy / offensive)
    [47758] = true,  -- Penance damage channel
    [47666] = true,  -- Penance per-bolt tick
    [47757] = true,  -- Penance healing channel (friendly)
    [47750] = true,  -- Penance per-bolt healing tick
}

-- Power Word: Shield action-button textures for proc detection
-- PROC_SLOT_TEXTURE = proc overlay visible (borrowed time / void shield proc)
-- BASE_SLOT_TEXTURE = normal not-proced PW:S icon
local BASE_SLOT_TEXTURE = 135940
local PROC_SLOT_TEXTURE = 7514191

-- PW:S spell IDs to find the action-bar slot
local PW_SHIELD_SPELL_IDS = {
    [17] = true,
    [1253593] = true,
}

local PROC_CHECK_DELAY_MS = 200  -- configurable, default 200ms

local DBG = "|cffffaa00[VST-DBG]|r"

-- ============================================================
-- Deck state
-- ============================================================
local deckCount
local marked = {}
local inDungeon
local history = {}
local HISTORY_MAX = 20
local historyLocked

-- Track whether the proc buff was present on the PREVIOUS aura event.
local lastBuffPresent = nil

-- Debounce: ignore rapid CHANNEL_START events from multi-bolt casts
local lastCastTime = 0
local CAST_DEBOUNCE = 0.5

-- Detection state (owned by onPenanceCastStart)
local pendingCheck = false
local shieldActiveOnCast = false

-- ============================================================
-- Action bar slot cache for PW:S
-- ============================================================
local watchSlot = nil
local function refreshWatchSlot()
    for slot = 1, 180 do
        local actionType, id = GetActionInfo(slot)
        if actionType == "spell" and PW_SHIELD_SPELL_IDS[id] then
            watchSlot = slot
            return
        end
    end
    watchSlot = nil
end

-- Get current PW:S button texture, preferring cached slot
local function getShieldTexture()
    if watchSlot then
        local tex = GetActionTexture(watchSlot)
        if tex then return tex end
    end
    -- Fallback: scan action bars
    local prefixes = {"ActionButton", "MultiActionBar1Button", "MultiActionBar2Button", "MultiActionBar3Button", "MultiActionBar4Button"}
    for _, prefix in ipairs(prefixes) do
        for i = 1, 12 do
            local btn = _G[prefix .. i]
            if btn and btn.icon then
                local tex = btn.icon:GetTexture()
                if tex == PROC_SLOT_TEXTURE or tex == BASE_SLOT_TEXTURE then
                    return tex
                end
            end
        end
    end
    return nil
end

-- Update shieldActive from current button texture
local function pollShieldState()
    local tex = getShieldTexture()
    if tex == PROC_SLOT_TEXTURE then
        pendingCheck = false
    elseif tex == BASE_SLOT_TEXTURE then
        pendingCheck = false
    end
    -- If tex is nil, keep last state
end

local function GetGameTime()
    local t = GetTime()
    if t and t > 1000000 then
        local gameStart = 1717200000
        return t - gameStart
    end
    return t
end

-- ============================================================
-- Initialization
-- ============================================================
function deck:Initialize()
    deckCount = 0
    lastBuffPresent = nil
    lastCastTime = 0
    inDungeon = false
    history = {}
    historyLocked = false
    for i = 1, 3 do marked[i] = false end
    addon.SafeSetAllIcons(addon.ui, "empty")
    refreshWatchSlot()
    DEFAULT_CHAT_FRAME:AddMessage(string.format(
        "%s INIT: watchSlot=%d ui=%s",
        DBG, watchSlot and watchSlot or "nil", tostring(addon.ui)))
end

-- ============================================================
-- Deck operations
-- ============================================================
local function ResetDeck()
    deckCount = 0
    lastCastTime = 0
    for i = 1, 3 do marked[i] = false end
    addon.SafeSetAllIcons(addon.ui, "empty")
end

-- ============================================================
-- Smart detection (outside dungeons)
-- ============================================================
local function CheckSmartDetection()
    if historyLocked then return end
    if #history < 6 then return end

    local n = #history

    -- Pattern 1: Two procs in a row -> boundary between them
    for i = 2, n do
        if history[i] == 1 and history[i - 1] == 1 then
            local castsAfterBoundary = n - i
            deckCount = 1 + castsAfterBoundary
            if deckCount > 3 then
                deckCount = ((deckCount - 1) % 3) + 1
            end

            for j = 1, 3 do marked[j] = false end
            for j = 1, deckCount do
                local histIdx = i + j - 1
                if histIdx <= n then
                    addon.SafeSetIcon(addon.ui, j, history[histIdx] == 1 and "proc" or "noproc")
                    marked[j] = true
                end
            end
            historyLocked = true
            DEFAULT_CHAT_FRAME:AddMessage(
                "|cff88ccffVoid Shield Tracker|r: Deck boundary detected (consecutive procs)",
                0.5, 0.7, 1)
            return
        end
    end

    -- Pattern 2: Four non-procs in a row -> boundary after the 2nd
    for i = 4, n do
        if history[i] == 0 and history[i-1] == 0 and
           history[i-2] == 0 and history[i-3] == 0 then
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
                    addon.SafeSetIcon(addon.ui, j, history[histIdx] == 1 and "proc" or "noproc")
                    marked[j] = true
                end
            end
            historyLocked = true
            DEFAULT_CHAT_FRAME:AddMessage(
                "|cff88ccffVoid Shield Tracker|r: Deck boundary detected (4 non-procs)",
                0.5, 0.7, 1)
            return
        end
    end
end

-- ============================================================
-- Penance channel detection (called from UNIT_SPELLCAST_CHANNEL_START)
-- ============================================================
function deck:OnPenanceChannel(spellID, spellName)
    DEFAULT_CHAT_FRAME:AddMessage(string.format(
        "%s PENCE CHANNEL_START: spellID=%d name=%s",
        DBG, spellID, spellName or "(none)"))

    -- Debounce check
    local now = GetGameTime()
    local debounceGap = now - lastCastTime
    if debounceGap < CAST_DEBOUNCE then
        DEFAULT_CHAT_FRAME:AddMessage(string.format(
            "%s   DEBOUNCE SKIP (%.3f < %.3f)", DBG, debounceGap, CAST_DEBOUNCE))
        return
    end

    -- Start proc detection via action button texture
    pendingCheck = true
    shieldActiveOnCast = (getShieldTexture() == PROC_SLOT_TEXTURE)
    DEFAULT_CHAT_FRAME:AddMessage(string.format(
        "%s   shieldActiveOnCast=%s", DBG, tostring(shieldActiveOnCast)))
    pollShieldState()

    C_Timer.After(PROC_CHECK_DELAY_MS / 1000, function()
        if not pendingCheck then return end
        pendingCheck = false

        local tex = getShieldTexture()
        local result = "NO_PROC"
        if shieldActiveOnCast then
            result = "PROC"
        elseif tex == PROC_SLOT_TEXTURE then
            result = "PROC"
        end

        DEFAULT_CHAT_FRAME:AddMessage(string.format(
            "%s   RESULT=%s (tex=%s, prev=%s)", DBG, result, tostring(tex), tostring(shieldActiveOnCast)))

        lastCastTime = now
        deckCount = deckCount + 1
        addon.SafeSetIcon(addon.ui, deckCount, result == "PROC" and "proc" or "noproc")
        marked[deckCount] = true
        history[#history + 1] = result == "PROC" and 1 or 0
        if #history > HISTORY_MAX then table.remove(history, 1) end

        DEFAULT_CHAT_FRAME:AddMessage(string.format(
            "%s   deckCount=%d/3 history=[%s]",
            DBG, deckCount, table.concat(history, ",")))

        if deckCount >= 3 then
            DEFAULT_CHAT_FRAME:AddMessage(string.format(
                "%s   DECK FULL (3) - scheduling 1s reset", DBG))
            C_Timer.After(1, function()
                DEFAULT_CHAT_FRAME:AddMessage(string.format(
                    "%s   RESET TIMER FIRED", DBG))
                ResetDeck()
            end)
        end

        if not inDungeon and not historyLocked then
            CheckSmartDetection()
        end
    end)
end

-- ============================================================
-- Aura check (UNIT_AURA event on "player")
-- Used only for proc buff reapplied detection (deck reset)
-- ============================================================
function deck:OnPlayerAura()
    -- Check if Master the Darkness buff reapplied (deck reset)
    local hasBuff = false
    local ok, result = pcall(C_UnitAuras.GetUnitAuras, "player", "HELPFUL")
    if ok and result then
        for i = 1, #result do
            local a = result[i]
            if a.spellID == 1253591 or a.name == "Master the Darkness" then
                hasBuff = true
                break
            end
        end
    end

    if hasBuff and deckCount > 0 then
        DEFAULT_CHAT_FRAME:AddMessage(string.format(
            "%s RESET: proc buff reapplied, resetting deck from %d", DBG, deckCount))
        ResetDeck()
    end
end

-- ============================================================
-- Dungeon detection
-- ============================================================
function deck:CheckDungeonState()
    local wasDungeon = inDungeon

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
        DEFAULT_CHAT_FRAME:AddMessage(
            "|cff88ccffVoid Shield Tracker|r: Dungeon detected - deck reset",
            0.5, 0.7, 1)
    elseif not inDungeon and wasDungeon then
        historyLocked = false
        history = {}
    end
end

function deck:OnEnterWorld()
    local isInstance, instanceType = IsInInstance()
    if instanceType == "party" or instanceType == "raid" or instanceType == "scenario" then
        inDungeon = true
        ResetDeck()
        historyLocked = false
        history = {}
        DEFAULT_CHAT_FRAME:AddMessage(
            "|cff88ccffVoid Shield Tracker|r: Entered instance - deck reset",
            0.5, 0.7, 1)
    end
end

-- ============================================================
-- Public API for slash commands
-- ============================================================
function deck:Reset()
    ResetDeck()
    historyLocked = false
    history = {}
end

function deck:Status()
    return string.format(
        "Deck: %d/3 | Dungeon: %s | Smart locked: %s | History: %d",
        deckCount, inDungeon and "yes" or "no",
        historyLocked and "yes" or "no", #history)
end
