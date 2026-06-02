--[=[
    Deck.lua - Deck tracking logic for Discipline Priest Void Shield.

    Detection: UNIT_SPELLCAST_CHANNEL_START with Penance spell IDs.
    Reset: proc buff reapplies after 3 casts (detected via UNIT_AURA).

    Spell ID chain (per SimulationCraft / SpellData):
      47540  base driver cast on enemy (fires CHANNEL_START for offensive)
      47758  damage channel triggered by 47540
      47666  per-bolt tick — damage or healing (fires UNIT_SPELLCAST_SUCCEEDED)
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

-- ============================================================
-- Proc buff detection (for deck reset detection)
-- ============================================================
local PROC_BUFF_NAME = "Master the Darkness"
local PROC_BUFF_ID = 1253591

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
    DEFAULT_CHAT_FRAME:AddMessage(string.format(
        "%s INIT complete: deckCount=%d ui=%s ui.icons=%s",
        DBG, deckCount, tostring(addon.ui), tostring(addon.ui and addon.ui.icons)))
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
    DEFAULT_CHAT_FRAME:AddMessage(string.format(
        "%s   ui=%s icons=%s", DBG, tostring(addon.ui), tostring(addon.ui and addon.ui.icons)))

    if not PENANCE_SPELL_IDS[spellID] then
        DEFAULT_CHAT_FRAME:AddMessage(string.format(
            "%s   SPELL NOT MATCHED", DBG))
        return
    end
    DEFAULT_CHAT_FRAME:AddMessage(string.format(
        "%s   SPELL MATCHED", DBG))

    local now = GetGameTime()
    local debounceGap = now - lastCastTime
    if debounceGap < CAST_DEBOUNCE then
        DEFAULT_CHAT_FRAME:AddMessage(string.format(
            "%s   DEBOUNCE SKIP (%.3f < %.3f)", DBG, debounceGap, CAST_DEBOUNCE))
        return
    end
    lastCastTime = now

    deckCount = deckCount + 1
    DEFAULT_CHAT_FRAME:AddMessage(string.format(
        "%s   Setting icon slot %d to noproc", DBG, deckCount))
    addon.SafeSetIcon(addon.ui, deckCount, "noproc")
    DEFAULT_CHAT_FRAME:AddMessage(string.format(
        "%s   icon set complete. deckCount=%d", DBG, deckCount))
    marked[deckCount] = true
    history[#history + 1] = 0
    if #history > HISTORY_MAX then table.remove(history, 1) end

    DEFAULT_CHAT_FRAME:AddMessage(string.format(
        "%s   deckCount=%d/3 history=[%s]",
        DBG, deckCount, table.concat(history, ",")))

    if deckCount >= 3 then
        DEFAULT_CHAT_FRAME:AddMessage(string.format(
            "%s   DECK FULL (3) — scheduling 1s reset", DBG))
        C_Timer.After(1, function()
            DEFAULT_CHAT_FRAME:AddMessage(string.format(
                "%s   RESET TIMER FIRED", DBG))
            ResetDeck()
        end)
    end

    if not inDungeon and not historyLocked then
        CheckSmartDetection()
    end
end

-- ============================================================
-- Aura check (called from UNIT_AURA event on "player")
-- Used only for proc buff reapplied detection (deck reset)
-- ============================================================
function deck:OnPlayerAura()
    local hasBuff = false
    local buffAura = nil

    local auraList = ""
    local playerAuras = nil
    local ok, result = pcall(C_UnitAuras.GetUnitAuras, "player", "HELPFUL")
    if ok and result then
        playerAuras = result
    end
    if playerAuras then
        for i = 1, #playerAuras do
            local aura = playerAuras[i]
            if aura.spellID == PROC_BUFF_ID or aura.name == PROC_BUFF_NAME then
                hasBuff = true
                buffAura = aura
            end
            local name = aura.name or "(no name)"
            local sid = aura.spellID or 0
            if auraList ~= "" then auraList = auraList .. ", " end
            auraList = auraList .. string.format("[%d] %s", sid, name)
        end
    end

    local prevState = lastBuffPresent
    lastBuffPresent = hasBuff

    DEFAULT_CHAT_FRAME:AddMessage(string.format(
        "%s AURA evt: hasBuff=%s prev=%s deck=%d totalAuras=%d auras=[%s]",
        DBG, tostring(hasBuff), tostring(prevState), deckCount,
        playerAuras and #playerAuras or 0, auraList))
    if buffAura then
        DEFAULT_CHAT_FRAME:AddMessage(string.format(
            "%s   ^^^ PROC BUFF: name=%s spellID=%d", DBG, buffAura.name, buffAura.spellID))
    end

    -- Buff reapplied after deck reset
    if not prevState and hasBuff then
        DEFAULT_CHAT_FRAME:AddMessage(string.format(
            "%s RESET: buff reapplied deckCount=%d", DBG, deckCount))
        if deckCount > 0 then
            ResetDeck()
            DEFAULT_CHAT_FRAME:AddMessage(string.format(
                "%s   reset deck to 0", DBG))
        end
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
