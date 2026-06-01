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

local addonName = ...
local addon = _G[addonName]

local deck = {}
addon.deck = deck

-- Spell IDs / names
local PROC_BUFF_NAME = "Master the Darkness"

-- Deck state
local deckCount
local procPending
local marked = {}
local inDungeon
local history = {}
local HISTORY_MAX = 20
local historyLocked

-- ============================================================
-- Initialization
-- ============================================================
function deck:Initialize()
    deckCount = 0
    procPending = false
    marked = {}
    inDungeon = false
    history = {}
    historyLocked = false
    for i = 1, 3 do marked[i] = false end
    addon.ui:SetAllIcons("empty")
end

-- ============================================================
-- Deck operations
-- ============================================================
local function ResetDeck()
    deckCount = 0
    procPending = false
    for i = 1, 3 do marked[i] = false end
    addon.ui:SetAllIcons("empty")
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
                    addon.ui:SetIcon(j, history[histIdx] == 1 and "proc" or "noproc")
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
                    addon.ui:SetIcon(j, history[histIdx] == 1 and "proc" or "noproc")
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
    AuraUtil.ForEachAura("player", "HELPFUL", nil, function(aura)
        if aura.name == PROC_BUFF_NAME then
            hasBuff = true
        end
    end)

    if hasBuff then
        -- Proc buff present -> deck is at 0 (waiting for next Penance)
        -- Mark the deck as having a proc pending for the NEXT cast
        procPending = true

        -- If deckCount was non-zero, this means the deck already reset
        -- (buff reapplied after reaching 3) -- reset cleanly
        if deckCount > 0 then
            ResetDeck()
        end
    elseif deckCount < 3 then
        -- Proc buff absent and deck not full -> Penance was cast
        -- If a proc buff arrived since last cast, mark the previous slot as proc
        if procPending and deckCount >= 1 then
            addon.ui:SetIcon(deckCount, "proc")
            -- Update history: change last entry from 0 to 1
            if #history > 0 and history[#history] == 0 then
                history[#history] = 1
            end
        end
        procPending = false

        -- Draw the next card (increment deck count)
        deckCount = deckCount + 1

        -- Mark this slot as non-proc (default; proc buff may override on reappearance)
        addon.ui:SetIcon(deckCount, "noproc")
        marked[deckCount] = true
        history[#history + 1] = 0
        if #history > HISTORY_MAX then table.remove(history, 1) end

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
