--[=[
    Deck.lua - Void Shield proc-deck tracking for Discipline Priest.

    Mechanic:
      The Void Shield proc behaves like a shuffled 3-card deck. Each Penance
      cast turns over one card; exactly one of the three cards carries the
      Void Shield proc. When all three cards are turned, the deck reshuffles.

    Detection (proven approach, shared with VoidShieldHelper):
      - Penance casts are detected via UNIT_SPELLCAST_CHANNEL_START on matched
        spell IDs (COMBAT_LOG_EVENT_UNFILTERED is forbidden for addons in 12.0).
      - The proc itself is read from the Power Word: Shield action-button
        texture: a different texture (PROC_SLOT_TEXTURE) is shown while the
        Void Shield proc is up. We snapshot the texture at cast start and again
        a short delay later to classify each cast.

    Prediction (phase-state filter):
      We never know which slot of the deck we start observing on, so three
      candidate phases (deck-start offsets 0/1/2) run in parallel. Casts that
      violate "at most one proc per 3-card block" invalidate a phase; surviving
      phases give an honest probability for the next proc. This converges within
      a few casts and lets the card display align to the true deck boundary.
]=]

local addon = _G["VoidShieldTracker"]

local deck = {}
addon.deck = deck

-- ============================================================
-- Constants
-- ============================================================

-- Penance spell IDs matched on UNIT_SPELLCAST_CHANNEL_START.
--   47540  base driver cast on enemy  (offensive Penance)
--   47758  damage channel triggered by 47540
--   47666  per-bolt tick (damage or healing)
--   47757  healing channel cast on friendly
--   47750  per-bolt healing tick
local PENANCE_SPELL_IDS = {
    [47540] = true,
    [47758] = true,
    [47666] = true,
    [47757] = true,
    [47750] = true,
}

-- Power Word: Shield action-button textures (fileIDs).
--   BASE  : normal / not-procced PW:S icon
--   PROC  : Void Shield proc overlay is up
local BASE_SLOT_TEXTURE = 135940
local PROC_SLOT_TEXTURE = 7514191

-- Spell IDs that identify the PW:S button on the action bar.
local PW_SHIELD_SPELL_IDS = {
    [17]      = true,  -- Power Word: Shield (base)
    [1253593] = true,  -- Power Word: Shield (Void Shield variant)
}

local ACTION_BUTTON_PREFIXES = {
    "ActionButton",
    "MultiActionBar1Button",
    "MultiActionBar2Button",
    "MultiActionBar3Button",
    "MultiActionBar4Button",
}

local PROC_CHECK_DELAY_DEFAULT_MS = 200

-- Result values fed to the predictor.
local RESULT_PROC    = "proc"
local RESULT_NOPROC  = "noproc"
local RESULT_UNKNOWN = "unknown"   -- shield was already up at cast time

local MAX_HISTORY            = 30
local RECOVERY_REPLAY_WINDOW = 4

-- ============================================================
-- Runtime state (module-local)
-- ============================================================
local penanceHistory      = {}     -- newest first; values: "proc"/"noproc"/"unknown"
local predictor                    -- phase-state filter (built in Initialize)
local predictorHistoryDepth = 0    -- history entries the current predictor has seen
local predictorBreakCount   = 0

local watchSlot           = nil    -- cached PW:S action-bar slot
local slotRefreshCountdown = 0
local shieldActive        = false  -- true when PROC_SLOT_TEXTURE is visible

-- Per-cast detection state.
local pendingCheck        = false
local shieldActiveOnCast  = false

-- ============================================================
-- Phase-state filter
-- ============================================================
local function Predictor_new()
    -- offset N => first observed cast sits at slot N of a block. Casts before
    -- tracking began are injected as virtual unknowns so partial blocks resolve.
    local phases = {}
    for offset = 0, 2 do
        local v = (3 - offset) % 3
        phases[offset + 1] = {
            isValid     = true,
            minSum      = 0,
            maxSum      = v,
            slotsFilled = v,
        }
    end
    return { phases = phases }
end

local function Predictor_update(self, val)
    -- val: 1 = proc, 0 = no-proc, -1 = unknown
    for _, p in ipairs(self.phases) do
        if p.isValid then
            if val == 1 then
                p.minSum = p.minSum + 1
                p.maxSum = p.maxSum + 1
            elseif val == -1 then
                p.maxSum = p.maxSum + 1
            end

            if p.minSum > 1 then
                p.isValid = false
            elseif p.slotsFilled == 2 then
                if p.maxSum == 0 then
                    p.isValid = false
                end
                p.minSum, p.maxSum, p.slotsFilled = 0, 0, 0
            else
                p.slotsFilled = p.slotsFilled + 1
            end
        end
    end
end

-- Probability that the NEXT cast is a proc, averaged over valid phases.
-- Returns nil if every phase has been invalidated.
local function Predictor_getProb(self)
    local valid = {}
    for _, p in ipairs(self.phases) do
        if p.isValid then valid[#valid + 1] = p end
    end
    if #valid == 0 then return nil, 0 end

    local total = 0
    for _, p in ipairs(valid) do
        local probPhi
        if p.minSum == 1 then
            probPhi = 0
        else
            local numUnknowns = p.maxSum - p.minSum
            local remaining   = 3 - p.slotsFilled
            probPhi = 1.0 / (numUnknowns + remaining)
        end
        total = total + probPhi
    end
    return total / #valid, #valid
end

local function probForState(sf, minS, maxS)
    if minS == 1 then return 0 end
    return 1.0 / ((maxS - minS) + (3 - sf))
end

local function advanceState(sf, minS, maxS, val)
    local newMin = minS + (val == 1 and 1 or 0)
    local newMax = maxS + (val == 1 and 1 or 0)
    if newMin > 1 then return 0, 0, 0, false end
    if sf == 2 then
        if newMax == 0 then return 0, 0, 0, false end
        return 0, 0, 0, true
    end
    return sf + 1, newMin, newMax, true
end

-- Probability the cast AFTER next is a proc (one-step lookahead).
local function Predictor_getProbNextNext(self)
    local valid = {}
    for _, p in ipairs(self.phases) do
        if p.isValid then valid[#valid + 1] = p end
    end
    if #valid == 0 then return nil end

    local total = 0
    for _, p in ipairs(valid) do
        local sf, minS, maxS = p.slotsFilled, p.minSum, p.maxSum
        local p1 = probForState(sf, minS, maxS)
        local p0 = 1 - p1
        local prob2 = 0
        if p1 > 0 then
            local s, mn, mx, ok = advanceState(sf, minS, maxS, 1)
            if ok then prob2 = prob2 + p1 * probForState(s, mn, mx) end
        end
        if p0 > 0 then
            local s, mn, mx, ok = advanceState(sf, minS, maxS, 0)
            if ok then prob2 = prob2 + p0 * probForState(s, mn, mx) end
        end
        total = total + prob2
    end
    return total / #valid
end

-- Keep only the offset-0 phase (assume a clean deck boundary). Used on
-- instance entry when the "fresh deck on zone" option is enabled.
local function Predictor_pruneToOffset0(self)
    for i, p in ipairs(self.phases) do
        if i == 1 then
            p.isValid, p.minSum, p.maxSum, p.slotsFilled = true, 0, 0, 0
        else
            p.isValid = false
        end
    end
end

-- Offset (0/1/2) of the sole surviving phase, or nil if not converged.
local function convergedOffset()
    local found, count = nil, 0
    for idx, p in ipairs(predictor.phases) do
        if p.isValid then
            count = count + 1
            found = idx - 1
        end
    end
    if count == 1 then return found end
    return nil
end

-- ============================================================
-- Action-bar texture scanning
-- ============================================================
local function scanBarTexture()
    for _, prefix in ipairs(ACTION_BUTTON_PREFIXES) do
        for i = 1, 12 do
            local btn = _G[prefix .. i]
            if btn and btn.icon then
                local tex = btn.icon:GetTexture()
                if tex == PROC_SLOT_TEXTURE then return PROC_SLOT_TEXTURE end
                if tex == BASE_SLOT_TEXTURE  then return BASE_SLOT_TEXTURE  end
            end
        end
    end
end

local function getCurrentSlotTexture()
    if watchSlot then
        local tex = GetActionTexture(watchSlot)
        if tex then return tex end
    end
    return scanBarTexture()
end

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

local function pollShieldState()
    local tex = getCurrentSlotTexture()
    if tex == PROC_SLOT_TEXTURE then
        shieldActive = true
    elseif tex == BASE_SLOT_TEXTURE then
        shieldActive = false
    end
    -- nil/unknown texture: keep last known state
end

local function getProcCheckDelay()
    local db = VSTDB
    local ms = (db and db.procCheckDelayMs) or PROC_CHECK_DELAY_DEFAULT_MS
    return ms / 1000
end

-- ============================================================
-- Result recording
-- ============================================================
local function refreshUI()
    if addon.ui and addon.ui.Refresh then addon.ui:Refresh() end
end

local function recordResult(result)
    table.insert(penanceHistory, 1, result)
    if #penanceHistory > MAX_HISTORY then
        penanceHistory[#penanceHistory] = nil
    end

    local val = (result == RESULT_PROC and 1)
             or (result == RESULT_NOPROC and 0)
             or -1
    predictorHistoryDepth = math.min(predictorHistoryDepth + 1, MAX_HISTORY)
    Predictor_update(predictor, val)

    -- Auto-recover if the observed sequence broke every phase.
    if Predictor_getProb(predictor) == nil then
        predictorBreakCount = predictorBreakCount + 1
        predictor = Predictor_new()
        local replayN = math.min(#penanceHistory, RECOVERY_REPLAY_WINDOW)
        for j = replayN, 1, -1 do
            local rv = (penanceHistory[j] == RESULT_PROC and 1)
                    or (penanceHistory[j] == RESULT_NOPROC and 0)
                    or -1
            Predictor_update(predictor, rv)
        end
        predictorHistoryDepth = replayN
    end

    refreshUI()
end

-- ============================================================
-- Penance cast handling (UNIT_SPELLCAST_CHANNEL_START)
-- ============================================================
function deck:OnPenanceCast(spellID)
    if not PENANCE_SPELL_IDS[spellID] then return end

    if pendingCheck then
        -- A previous cast's timer is still live: force-complete it so history
        -- stays contiguous on a fast recast inside the delay window.
        pendingCheck = false
        pollShieldState()
        if shieldActiveOnCast then
            recordResult(RESULT_UNKNOWN)
        elseif shieldActive then
            recordResult(RESULT_PROC)
        else
            recordResult(RESULT_NOPROC)
        end
    end

    pollShieldState()
    shieldActiveOnCast = shieldActive
    pendingCheck = true

    C_Timer.After(getProcCheckDelay(), function()
        if not pendingCheck then return end
        pendingCheck = false
        pollShieldState()
        if shieldActiveOnCast then
            recordResult(RESULT_UNKNOWN)
        elseif shieldActive then
            recordResult(RESULT_PROC)
        else
            recordResult(RESULT_NOPROC)
        end
    end)

    refreshUI()
end

-- ============================================================
-- Periodic tick (called by Core's ticker, ~10/s)
-- Returns true if the display should be refreshed.
-- ============================================================
function deck:Tick()
    slotRefreshCountdown = slotRefreshCountdown - 1
    if slotRefreshCountdown <= 0 then
        refreshWatchSlot()
        slotRefreshCountdown = 10  -- ~once per second
    end
    local prev = shieldActive
    pollShieldState()
    return shieldActive ~= prev
end

-- ============================================================
-- Reset / lifecycle
-- ============================================================
function deck:Initialize()
    penanceHistory        = {}
    predictor             = Predictor_new()
    predictorHistoryDepth = 0
    predictorBreakCount   = 0
    shieldActive          = false
    pendingCheck          = false
    shieldActiveOnCast    = false
    watchSlot             = nil
    slotRefreshCountdown  = 0
    refreshWatchSlot()
end

function deck:Reset()
    self:Initialize()
    refreshUI()
end

-- Instance entry: the deck reshuffles, so reset (or prune to a clean boundary).
function deck:OnEnterWorld()
    local db = VSTDB
    if db and db.pruneOnZone and predictor then
        Predictor_pruneToOffset0(predictor)
        penanceHistory        = {}
        predictorHistoryDepth = 0
        predictorBreakCount   = 0
        pendingCheck          = false
        shieldActiveOnCast    = false
        shieldActive          = false
    else
        self:Initialize()
    end
    refreshWatchSlot()
    refreshUI()
end

-- ============================================================
-- Display state for the UI
-- ============================================================
-- Returns a table describing the current deck cycle:
--   cards        : { [1..3] = "proc"|"noproc"|"unknown"|"future" }
--   highlightSlot: 1-3 slot index the NEXT cast will reveal (nil if block done)
--   nextProb     : probability next cast is a proc (0..1, or nil)
--   next2Prob    : probability the cast after next is a proc (0..1, or nil)
--   procFound    : true if the proc has already turned up this block
--   calibrating  : true while >1 phase is still possible (alignment unsure)
--   watchSlotOk  : true if PW:S was found on the action bar
function deck:GetDisplayState()
    local off = convergedOffset()
    local calibrating = (off == nil)
    local v = (3 - (off or 0)) % 3

    local cards = { "future", "future", "future" }
    local n = math.min(#penanceHistory, predictorHistoryDepth)
    local currentSlot0  -- 0-based slot of the newest cast within its block
    local procFound = false

    if n > 0 then
        local absNew = (n - 1) + v
        local currentBlock = math.floor(absNew / 3)
        currentSlot0 = absNew % 3

        for i = 1, n do
            local abs = (n - i) + v
            if math.floor(abs / 3) == currentBlock then
                local slot0 = abs % 3
                local r = penanceHistory[i]
                cards[slot0 + 1] = r
                if r == RESULT_PROC then procFound = true end
            end
        end
    end

    -- Slot the next cast will fill. If the block is complete, the next cast
    -- starts a fresh deck (no current-block highlight).
    local highlightSlot
    if currentSlot0 == nil then
        highlightSlot = 1
    elseif currentSlot0 >= 2 then
        highlightSlot = nil
    else
        highlightSlot = currentSlot0 + 2  -- (slot0+1) is current, +2 in 1-based is next
    end

    return {
        cards         = cards,
        highlightSlot = highlightSlot,
        nextProb      = Predictor_getProb(predictor),
        next2Prob     = Predictor_getProbNextNext(predictor),
        procFound     = procFound,
        calibrating   = calibrating,
        watchSlotOk   = (watchSlot ~= nil),
        shieldActive  = shieldActive,
    }
end

function deck:Status()
    local prob, count = Predictor_getProb(predictor)
    return string.format(
        "Next proc: %s | phases: %d | history: %d | resets: %d | PW:S slot: %s",
        prob and string.format("%d%%", math.floor(prob * 100 + 0.5)) or "?",
        count or 0, #penanceHistory, predictorBreakCount,
        watchSlot and tostring(watchSlot) or "not found")
end
