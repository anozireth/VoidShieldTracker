--[[
Deck.lua - Deck tracking logic. Pure state machine.
Loaded second (after Core.lua). Attaches to addon.deck.

WoW 12.0: COMBAT_LOG_EVENT_UNFILTERED is forbidden for addons.
We detect Penance casts via the "Master the Darkness" proc buff
in UNIT_AURA instead.

Deck state machine:
  - Proc buff PRESENT  -> deckCount = 0, waiting for next Penance
  - Proc buff ABSENT   -> Penance was cast, deckCount = deckCount + 1
  - Proc buff REAPPEARS -> mark current slot as proc
  - deckCount reaches 3 -> reset after 1 second, proc buff reapplies
]]

local addon = _G["VoidShieldTracker"]

local deck = {}
addon.deck = deck

-- Spell IDs / names
local PROC_BUFF_NAME = "Master the Darkness"
local PROC_BUFF_ID = 1253591

local DBG = "|cffffaa00[VST-DBG]|r"

-- Deck state
local deckCount
local procPending
local marked = {}
local inDungeon
local history = {}
local HISTORY_MAX = 20
local historyLocked

-- Track whether the proc buff was present on the PREVIOUS aura event.
-- This lets us detect state changes (present->absent = cast, absent->present = reset)
-- and ignore UNIT_AURA events from unrelated auras.
local lastBuffPresent = nil

-- Debounce: ignore rapid "buff absent" events from multi-bolt casts
local lastCastTime = 0
local CAST_DEBOUNCE = 0.5

-- ============================================================
-- Initialization
-- ============================================================
function deck:Initialize()
    deckCount = 0
    procPending = false
    lastBuffPresent = nil
    lastCastTime = 0
    marked = {}
    inDungeon = false
    history = {}
    historyLocked = false
    for i = 1, 3 do marked[i] = false end
    addon.SafeSetAllIcons(addon.ui, "empty")
end

-- ============================================================
-- Deck operations
-- ============================================================
local function ResetDeck()
    deckCount = 0
    procPending = false
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
-- Aura check (called from UNIT_AURA event on "player")
--
-- State machine for tracking Penance casts and the proc buff:
--
--   buff PRESENT at login -> deckCount = 0 (waiting for Penance)
--   buff ABSENT at login  -> deckCount = 1 (Penance already cast since last reset)
--   buff reappears        -> mark current slot as proc, procPending = false
--   buff absent (while deckCount < 3) -> Penance cast, increment deck
--   deckCount reaches 3   -> reset after 1 second (buff reapplies then)
-- ============================================================
function deck:OnPlayerAura()
    local hasBuff = false
    local buffAura = nil

    -- Print all helpful auras for debugging
    local auraList = ""
    local playerAuras = C_UnitAuras.GetAuras("player", "HELPFUL")
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
        "%s AURA evt: hasBuff=%s prev=%s deck=%d procPend=%s totalAuras=%d auras=[%s]",
        DBG, tostring(hasBuff), tostring(prevState), deckCount, tostring(procPending),
        playerAuras and #playerAuras or 0, auraList))
    if buffAura then
        DEFAULT_CHAT_FRAME:AddMessage(string.format(
            "%s   ^^^ PROC BUFF MATCH: name=%s spellID=%d", DBG, buffAura.name, buffAura.spellID))
    end

    -- First event after login: just set state, don't act on it
    if prevState == nil then
        DEFAULT_CHAT_FRAME:AddMessage(string.format(
            "%s FIRST EVENT: buff=%s deck=%d", DBG, tostring(hasBuff), deckCount))
        if not hasBuff then
            deckCount = 1
            if deckCount >= 1 then
                addon.SafeSetIcon(addon.ui, deckCount, "proc")
                history[#history + 1] = 1
                if #history > HISTORY_MAX then table.remove(history, 1) end
                marked[1] = true
            end
            DEFAULT_CHAT_FRAME:AddMessage(string.format(
                "%s init: buff absent => deckCount=1", DBG))
        end
        return
    end

    -- State transition: buff went from present to absent => Penance cast
    if prevState and not hasBuff then
        local now = GetTime()
        local debounceGap = now - lastCastTime
        DEFAULT_CHAT_FRAME:AddMessage(string.format(
            "%s TRANSITION: present->absent (PENCE cast?) time=%s debounceGap=%.3f",
            DBG, tostring(now), debounceGap))
        if debounceGap < CAST_DEBOUNCE then
            DEFAULT_CHAT_FRAME:AddMessage(string.format(
                "%s   DEBOUNCE SKIP (%.3f < %.3f)", DBG, debounceGap, CAST_DEBOUNCE))
            return
        end
        lastCastTime = now

        DEFAULT_CHAT_FRAME:AddMessage(string.format(
            "%s   procPending=%s deckCount=%d", DBG, tostring(procPending), deckCount))
        if procPending and deckCount >= 1 then
            addon.SafeSetIcon(addon.ui, deckCount, "proc")
            if #history > 0 and history[#history] == 0 then
                history[#history] = 1
            end
            DEFAULT_CHAT_FRAME:AddMessage(string.format(
                "%s   marked slot %d as PROC", DBG, deckCount))
        end
        procPending = false

        deckCount = deckCount + 1
        addon.SafeSetIcon(addon.ui, deckCount, "noproc")
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

    -- State transition: buff went from absent to present => deck reset
    if not prevState and hasBuff then
        DEFAULT_CHAT_FRAME:AddMessage(string.format(
            "%s TRANSITION: absent->present (RESET) deckCount=%d",
            DBG, deckCount))
        procPending = true
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
