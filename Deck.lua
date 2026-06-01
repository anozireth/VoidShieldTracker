--[[
Deck.lua - Deck tracking logic. Pure state machine.
Loaded second (after Core.lua). Attaches to addon.deck.
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
local hadProcBuff

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
    hadProcBuff = false
    for i = 1, 3 do marked[i] = false end
    addon.ui:SetAllIcons("empty")
end

-- ============================================================
-- Deck operations
-- ============================================================
local function ResetDeck()
    deckCount = 0
    procPending = false
    hadProcBuff = false
    for i = 1, 3 do marked[i] = false end
    addon.ui:SetAllIcons("empty")
end

function deck:OnPenanceCast()
    -- If a proc buff arrived since last cast, mark the PREVIOUS slot as proc
    if procPending and deckCount >= 1 then
        addon.ui:SetIcon(deckCount, "proc")
        -- Update history: change last entry from 0 to 1
        if #history > 0 and history[#history] == 0 then
            history[#history] = 1
        end
        procPending = false
    end

    -- Draw the next card (increment deck count)
    deckCount = deckCount + 1

    if deckCount > 3 then
        ResetDeck()
        deckCount = 1
    end

    -- Mark this slot as non-proc (default; proc buff may override on next cast)
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

function deck:OnProcBuffGained()
    procPending = true
end

-- ============================================================
-- Aura check (called from UNIT_AURA event)
-- ============================================================
function deck:CheckAura()
    local hasProcBuff = false
    for i = 1, 100 do
        local aura = UnitAura("player", i, "PLAYER|HELPFUL")
        if not aura then break end
        if aura.name == PROC_BUFF_NAME then
            hasProcBuff = true
            break
        end
    end

    if hasProcBuff and not hadProcBuff then
        self:OnProcBuffGained()
    end
    hadProcBuff = hasProcBuff
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
