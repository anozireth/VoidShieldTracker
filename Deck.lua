--[=[
    Deck.lua - Void Shield proc-deck tracking for Discipline Priest.

    Mechanic:
      The Void Shield proc behaves like a shuffled N-card deck. Each Penance
      cast turns over one card; exactly one of the N cards carries the Void
      Shield proc. When all N cards are turned, the deck reshuffles. The deck
      size is version-dependent (addon.deckSize): 3 on 12.0.7 (33%/Penance),
      4 on 12.1 (25%/Penance). In 12.1 Mind Blast is a *separate* deterministic
      proc source and the proc holds up to 2 charges; Mind Blast does NOT turn
      a deck card, so it never enters this predictor.

    Detection (constrained by 12.0 "secret values"):
      Reading the proc buff aura is NOT viable: aura fields (spellId,
      applications, ...) are "secret" while addon execution is tainted, and any
      comparison on them throws. So both proc state and charge count come from
      sources that are NOT secret:
      - Penance casts: UNIT_SPELLCAST_CHANNEL_START on matched spell IDs
        (COMBAT_LOG_EVENT_UNFILTERED is also forbidden for addons in 12.0).
      - Proc up/down: the PW:S action-button texture. PROC_SLOT_TEXTURE means a
        charge is up; any OTHER texture means none (only the proc icon is
        matched, so a base-icon change can't freeze the state). This is the
        authoritative 0-vs-(>=1) charge signal.
      - Exact charge count (1 vs 2 on 12.1): piggybacked off Blizzard's Cooldown
        Manager. Blizzard renders the secret stack into a FontString only when
        stacks > 1 (empty string otherwise). We never read the number — we ask
        whether the FontString's text IS a secret (issecretvalue, sanctioned
        API): secret text can only mean a rendered count, so stacks > 1 => 2
        (our cap); plain empty text => exactly 1. We find our item by its
        non-secret cooldownID (readBlizzardStacks). With an exact count,
        classifyCast uses the charge delta, so a Penance proc that lands while a
        charge is already up is still detected.
      - Fallback when the Cooldown Manager isn't showing this buff: infer the
        count with our own integer (Mind Blast +1 via UNIT_SPELLCAST_SUCCEEDED,
        Void Shield cast -1), anchored by the texture. In this mode a proc landing
        on top of an existing charge can't be seen (binary texture), so the deck
        cast is UNKNOWN and the count can read low until the next reset.

    Prediction (phase-state filter):
      We never know which slot of the deck we start observing on, so N candidate
      phases (deck-start offsets 0..N-1) run in parallel. Casts that violate "at
      most one proc per N-card block" invalidate a phase; surviving phases give
      an honest probability for the next proc. This converges within a few casts
      and lets the card display align to the true deck boundary.
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

-- Power Word: Shield action-button textures (fileIDs). The proc state (a charge
-- is up vs not) is read from which texture the PW:S button shows: PROC while a
-- charge is up, anything else means no charge (pollShieldState matches only
-- PROC, so a future base-icon change can't freeze the state). BASE is used only
-- by scanBarTexture to locate the PW:S button when the action-slot scan failed.
--   BASE  : normal / not-procced PW:S icon (same fileID on 12.0.7 and 12.1)
--   PROC  : Void Shield proc overlay is up
local BASE_SLOT_TEXTURE = 135940
local PROC_SLOT_TEXTURE = 7514191

-- Spell IDs that identify the PW:S button on the action bar.
local PW_SHIELD_SPELL_IDS = {
    [17]      = true,  -- Power Word: Shield (base)
    [1253593] = true,  -- Power Word: Shield (Void Shield variant)
}

-- Casting the Void Shield variant of PW:S consumes one proc charge.
local VOID_SHIELD_CAST_IDS = {
    [1253593] = true,
}

-- Mind Blast grants a proc charge on 12.1 ("Master the Darkness" R3). Used only
-- by the fallback charge inference to disambiguate 1 vs 2; ignored when
-- maxCharges < 2 (12.0.7).
local MIND_BLAST_SPELL_IDS = {
    [8092] = true,
}

-- Void Shield proc aura ("Master the Darkness"). Used only to find which
-- Cooldown Manager item is ours, by matching it against each item's non-secret
-- config cooldownInfo (C_CooldownViewer). We never read the item's secret
-- auraSpellID / icon.
local VOID_SHIELD_AURA_ID = 1253591

-- Blizzard Cooldown Manager buff viewers whose item frames render an exact stack
-- count we can piggyback on (see readBlizzardStacks). Icon viewer keeps the
-- count in itemFrame.Applications.Applications; bar viewer in
-- itemFrame.Icon.Applications.
local COOLDOWN_VIEWER_FRAMES = { "BuffIconCooldownViewer", "BuffBarCooldownViewer" }

local ACTION_BUTTON_PREFIXES = {
    "ActionButton",
    "MultiActionBar1Button",
    "MultiActionBar2Button",
    "MultiActionBar3Button",
    "MultiActionBar4Button",
}

local PROC_CHECK_DELAY_DEFAULT_MS = 200

-- Once a deck (N casts) completes, blank the display this long after the
-- completing cast so the board shows fresh face-down cards for the next deck.
local DECK_CLEAR_DELAY = 2.0

-- Result values fed to the predictor.
local RESULT_PROC    = "proc"
local RESULT_NOPROC  = "noproc"
local RESULT_UNKNOWN = "unknown"   -- shield was already up at cast time

local MAX_HISTORY            = 30
local RECOVERY_REPLAY_WINDOW = 4

-- ============================================================
-- Runtime state (module-local)
-- ============================================================
-- Deck size (cards per block), set from addon.deckSize in Initialize.
-- 3 on 12.0.7, 4 on 12.1. Default keeps things sane before login.
local N = 3

local penanceHistory      = {}     -- newest first; values: "proc"/"noproc"/"unknown"
local predictor                    -- phase-state filter (built in Initialize)
local predictorHistoryDepth = 0    -- history entries the current predictor has seen
local predictorBreakCount   = 0

local watchSlot           = nil    -- cached PW:S action-bar slot
local slotRefreshCountdown = 0
local shieldActive        = false  -- true when a proc charge is up (texture = PROC)
local chargeCount         = 0      -- active proc charges (0..maxCharges)
local blizzardCount       = false  -- true when chargeCount came from the Cooldown Manager
local cooldownIDCache     = nil    -- cached Cooldown Manager cooldownID for our proc

-- Per-cast detection state.
local pendingCheck        = false
local shieldActiveOnCast  = false
local chargesOnCast       = 0

-- Display-clear state: once a deck completes the board blanks to face-down
-- until the next Penance starts a new deck.
local displayCleared      = false
local clearGen            = 0       -- bumped each cast; stale clear timers no-op

-- ============================================================
-- Phase-state filter
-- ============================================================
local function Predictor_new()
    -- offset => first observed cast sits at that slot of a block. Casts before
    -- tracking began are injected as virtual unknowns so partial blocks resolve.
    local phases = {}
    for offset = 0, N - 1 do
        local v = (N - offset) % N
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
            elseif p.slotsFilled == N - 1 then
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
            local remaining   = N - p.slotsFilled
            probPhi = 1.0 / (numUnknowns + remaining)
        end
        total = total + probPhi
    end
    return total / #valid, #valid
end

local function probForState(sf, minS, maxS)
    if minS == 1 then return 0 end
    return 1.0 / ((maxS - minS) + (N - sf))
end

local function advanceState(sf, minS, maxS, val)
    local newMin = minS + (val == 1 and 1 or 0)
    local newMax = maxS + (val == 1 and 1 or 0)
    if newMin > 1 then return 0, 0, 0, false end
    if sf == N - 1 then
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

-- Does a Cooldown Manager item's (config) cooldownInfo reference our proc spell?
-- These are static data-table fields, not live combat data, so comparing them is
-- not secret. (The item's own auraSpellID / icon ARE secret, so we never use them.)
local function cooldownInfoMatches(info)
    if not info then return false end
    if info.spellID == VOID_SHIELD_AURA_ID
        or info.overrideSpellID == VOID_SHIELD_AURA_ID
        or info.overrideTooltipSpellID == VOID_SHIELD_AURA_ID then
        return true
    end
    local linked = info.linkedSpellIDs
    if linked then
        for _, id in ipairs(linked) do
            if id == VOID_SHIELD_AURA_ID then return true end
        end
    end
    return false
end

-- The Applications FontString for an item (icon viewer vs bar viewer layout).
local function itemApplicationsFontString(itemFrame)
    local iconField = itemFrame.Icon
    if not iconField then return nil end
    if iconField.GetObjectType and iconField:GetObjectType() == "Texture" then
        return itemFrame.Applications and itemFrame.Applications.Applications  -- buff-icon item
    end
    return iconField.Applications                                              -- buff-bar item
end

-- True if v is a 12.0 "secret value". issecretvalue is the sanctioned way to
-- ask WITHOUT using the value (comparisons/arithmetic on secrets throw).
local function isSecret(v)
    if issecretvalue then return issecretvalue(v) end
    return false
end

-- Does this FontString currently render any text?
--
-- Blizzard writes the aura stack count into the item's Applications FontString
-- only when stacks > 1; at <= 1 stack it is set to the plain empty string
-- (CooldownViewerBuffItemMixin:GetApplicationsText). The count itself is a
-- secret value we can never read — but we don't need to: the text BEING secret
-- can only mean Blizzard rendered a count, i.e. stacks > 1. That one bit is all
-- we need at a cap of 2.
--
-- The text is the ONLY usable channel. In-game probing (/vst cdm, 2026-07)
-- showed every layout metric (GetStringWidth / GetStringHeight / GetWidth /
-- GetUnboundedStringWidth) reads SECRET even while the text is plainly nil —
-- metric secrecy sticks to the FontString regardless of current content — so
-- metrics carry no information and must never be consulted. GetText is cleanly
-- discriminating: plain nil/"" at 1 stack, secret at >1.
--
-- Returns true/false, or nil if the probe threw (no usable channel).
local function fontStringHasText(fs)
    local ok, hasText = pcall(function()
        local t = fs:GetText()
        if isSecret(t) then return true end
        return t ~= nil and t ~= ""
    end)
    if ok then return hasText end
    return nil
end

-- Exact charge count, piggybacked off Blizzard's Cooldown Manager. We locate
-- our item by its non-secret cooldownID (mapped to our spell via the
-- C_CooldownViewer config table), then ask whether its Applications FontString
-- renders text (see fontStringHasText): text => stacks > 1 => our cap of 2;
-- no text => exactly 1 (the PW:S texture already said >= 1).
--
-- Returns nil when the count can't be determined (item not in the viewers, or
-- every probe hit a secret); the caller falls back to event inference. The
-- whole body additionally runs under pcall so an unexpected secret elsewhere
-- degrades the same way instead of erroring every tick.
local function readBlizzardStacksUnsafe()
    if not (C_CooldownViewer and C_CooldownViewer.GetCooldownViewerCooldownInfo) then
        return nil
    end
    for _, frameName in ipairs(COOLDOWN_VIEWER_FRAMES) do
        local viewer = _G[frameName]
        local pool = viewer and viewer.itemFramePool
        if pool then
            for itemFrame in pool:EnumerateActive() do
                local cdID = itemFrame.cooldownID
                if cdID and (cdID == cooldownIDCache
                        or cooldownInfoMatches(C_CooldownViewer.GetCooldownViewerCooldownInfo(cdID))) then
                    cooldownIDCache = cdID
                    local appsFS = itemApplicationsFontString(itemFrame)
                    local hasText = appsFS and fontStringHasText(appsFS)
                    if hasText == nil or appsFS == nil then
                        return nil
                    end
                    if hasText then
                        return addon.maxCharges or 2
                    end
                    return 1
                end
            end
        end
    end
    return nil
end

local function readBlizzardStacks()
    local ok, n = pcall(readBlizzardStacksUnsafe)
    if ok then return n end
    return nil
end

-- Read proc state from the PW:S action-button texture (not secret), the
-- authoritative 0-vs-(>=1) signal. Only the PROC texture is matched explicitly:
-- ANY other texture on the PW:S slot means no charge is up. The base icon's
-- fileID (BASE_SLOT_TEXTURE) is deliberately not required to match here, so a
-- base-icon change in a future patch degrades to "no charge" instead of
-- silently freezing the state. When a proc is up, refine 1-vs-2 from the
-- Cooldown Manager (readBlizzardStacks); if that isn't available, fall back to
-- the value maintained by event inference (deck:OnSpellSucceeded).
local function pollShieldState()
    local tex = getCurrentSlotTexture()
    if tex == PROC_SLOT_TEXTURE then
        shieldActive = true
        local n = readBlizzardStacks()
        if n then
            blizzardCount = true
            chargeCount   = n
        else
            blizzardCount = false
            if chargeCount < 1 then chargeCount = 1 end
        end
    elseif tex ~= nil then
        shieldActive  = false
        chargeCount   = 0
        blizzardCount = false
    end
    -- nil texture (PW:S not found on any bar): keep last known state
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

-- The valid phase used to read block position: prefer the offset-0 phase, else
-- the first surviving phase. Returns nil only if every phase died (transient,
-- recordResult auto-recovers).
local function alignPhase()
    local fallback
    for idx, p in ipairs(predictor.phases) do
        if p.isValid then
            if idx == 1 then return p end
            if not fallback then fallback = p end
        end
    end
    return fallback
end

-- 0-based slot (0..N-1) of the newest recorded cast within its block, or nil if
-- no casts have been recorded since the last reset.
--
-- Derived from the phase's slotsFilled rather than history length, so it keeps
-- advancing once history saturates at MAX_HISTORY. After a cast, slotsFilled is
-- the count consumed in the *current* (next) block: 0 means the cast just
-- completed a block (slot N-1), otherwise the cast was at slotsFilled - 1.
local function currentSlotIndex()
    if predictorHistoryDepth <= 0 then return nil end
    local p = alignPhase()
    if not p then return nil end
    local sf = p.slotsFilled
    if sf == 0 then return N - 1 end
    return sf - 1
end

-- True when the newest recorded cast filled the last slot of its block,
-- i.e. the deck just completed and is about to reshuffle.
local function isBlockComplete()
    return currentSlotIndex() == N - 1
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

    -- A new cast un-blanks the board and cancels any pending clear timer.
    displayCleared = false
    clearGen = clearGen + 1

    -- When the deck completes, schedule the board to blank shortly before
    -- Penance is back up so it's fresh for the next deck.
    if isBlockComplete() then
        local myGen = clearGen
        C_Timer.After(DECK_CLEAR_DELAY, function()
            if myGen == clearGen and not displayCleared then
                displayCleared = true
                refreshUI()
            end
        end)
    end

    refreshUI()
end

-- Classify the just-finished Penance by comparing post-cast state to the cast
-- snapshot. When the Cooldown Manager gives us an exact count, use the charge
-- delta (catches a proc that landed while a charge was already up, except at the
-- cap). Otherwise fall back to the binary texture (a proc already up hides a new
-- one, so it's UNKNOWN).
local function classifyCast()
    if blizzardCount then
        local cap = addon.maxCharges or 1
        if chargesOnCast >= cap then
            return RESULT_UNKNOWN
        elseif chargeCount > chargesOnCast then
            return RESULT_PROC
        else
            return RESULT_NOPROC
        end
    else
        if shieldActiveOnCast then
            return RESULT_UNKNOWN
        elseif shieldActive then
            return RESULT_PROC
        else
            return RESULT_NOPROC
        end
    end
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
        recordResult(classifyCast())
    end

    pollShieldState()
    shieldActiveOnCast = shieldActive
    chargesOnCast      = chargeCount
    pendingCheck = true

    C_Timer.After(getProcCheckDelay(), function()
        if not pendingCheck then return end
        pendingCheck = false
        pollShieldState()
        recordResult(classifyCast())
    end)

    refreshUI()
end

-- ============================================================
-- Charge inference (UNIT_SPELLCAST_SUCCEEDED)
-- ============================================================
-- Fallback charge inference for when the Cooldown Manager isn't providing an
-- exact count: Mind Blast adds a charge (12.1 only); casting the Void Shield
-- variant of PW:S consumes one. The texture (pollShieldState) is the 0-vs-(>=1)
-- anchor. Skipped while blizzardCount is authoritative.
function deck:OnSpellSucceeded(spellID)
    if blizzardCount then return end
    local maxCharges = addon.maxCharges or 1
    if MIND_BLAST_SPELL_IDS[spellID] then
        if maxCharges < 2 then return end  -- Mind Blast only procs Void Shield on 12.1
        if chargeCount < maxCharges then
            chargeCount  = chargeCount + 1
            shieldActive = chargeCount > 0
            refreshUI()
        end
    elseif VOID_SHIELD_CAST_IDS[spellID] then
        if chargeCount > 0 then
            chargeCount  = chargeCount - 1
            shieldActive = chargeCount > 0
            refreshUI()
        end
    end
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
    local prevActive, prevCharges = shieldActive, chargeCount
    pollShieldState()
    return shieldActive ~= prevActive or chargeCount ~= prevCharges
end

-- ============================================================
-- Reset / lifecycle
-- ============================================================
function deck:Initialize()
    N                     = addon.deckSize or 3
    penanceHistory        = {}
    predictor             = Predictor_new()
    predictorHistoryDepth = 0
    predictorBreakCount   = 0
    shieldActive          = false
    chargeCount           = 0
    blizzardCount         = false
    cooldownIDCache       = nil
    pendingCheck          = false
    shieldActiveOnCast    = false
    chargesOnCast         = 0
    displayCleared        = false
    clearGen              = clearGen + 1
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
        chargesOnCast         = 0
        shieldActive          = false
        chargeCount           = 0
        blizzardCount         = false
        displayCleared        = false
        clearGen              = clearGen + 1
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
--   cards        : { [1..N] = "proc"|"noproc"|"unknown"|"future" }
--   highlightSlot: 1-N slot index the NEXT cast will reveal (nil if block done)
--   nextProb     : probability next cast is a proc (0..1, or nil)
--   next2Prob    : probability the cast after next is a proc (0..1, or nil)
--   procFound    : true if the proc has already turned up this block
--   calibrating  : true while >1 phase is still possible (alignment unsure)
--   watchSlotOk  : true if PW:S was found on the action bar
--   charges      : active proc charges (0..maxCharges)
--   maxCharges   : charge cap for this client (1 on 12.0.7, 2 on 12.1)
function deck:GetDisplayState()
    -- Board blanked (deck completed): show a fresh face-down deck while still
    -- reporting the predictor's odds for the next cast.
    if displayCleared then
        local cards = {}
        for i = 1, N do cards[i] = "future" end
        return {
            cards         = cards,
            highlightSlot = 1,
            nextProb      = Predictor_getProb(predictor),
            next2Prob     = Predictor_getProbNextNext(predictor),
            procFound     = false,
            calibrating   = (convergedOffset() == nil),
            watchSlotOk   = (watchSlot ~= nil),
            shieldActive  = shieldActive,
            charges       = chargeCount,
            maxCharges    = addon.maxCharges or 1,
        }
    end

    local calibrating = (convergedOffset() == nil)

    local cards = {}
    for i = 1, N do cards[i] = "future" end
    -- 0-based slot of the newest cast within its block (from the predictor's
    -- block tracking, so it doesn't freeze once history saturates).
    local currentSlot0 = currentSlotIndex()
    local procFound = false

    if currentSlot0 ~= nil then
        -- Fill the current block from newest history backwards: the newest cast
        -- (penanceHistory[1]) sits at currentSlot0, the one before it at
        -- currentSlot0 - 1, down to slot 0. Earlier slots with no recorded cast
        -- (only possible in the very first partial block) stay face-down.
        for slot = 0, currentSlot0 do
            local r = penanceHistory[currentSlot0 - slot + 1]
            if r then
                cards[slot + 1] = r
                if r == RESULT_PROC then procFound = true end
            end
        end

        -- One proc per deck: once it's known, any "unknown" cast in this block
        -- (shield was already up, so a new proc couldn't be seen) must be a
        -- no-proc. Resolve those question marks to the no-proc face.
        if procFound then
            for slot = 1, N do
                if cards[slot] == RESULT_UNKNOWN then
                    cards[slot] = RESULT_NOPROC
                end
            end
        end
    end

    -- Slot the next cast will fill. If the block is complete, the next cast
    -- starts a fresh deck (no current-block highlight).
    local highlightSlot
    if currentSlot0 == nil then
        highlightSlot = 1
    elseif currentSlot0 >= N - 1 then
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
        charges       = chargeCount,
        maxCharges    = addon.maxCharges or 1,
    }
end

function deck:Status()
    local prob, count = Predictor_getProb(predictor)
    return string.format(
        "Next proc: %s | deck: %d | charges: %d/%d (%s) | phases: %d | history: %d | resets: %d | PW:S slot: %s",
        prob and string.format("%d%%", math.floor(prob * 100 + 0.5)) or "?",
        N, chargeCount, addon.maxCharges or 1, blizzardCount and "CDM" or "inferred",
        count or 0, #penanceHistory, predictorBreakCount,
        watchSlot and tostring(watchSlot) or "not found")
end

-- TEMPORARY diagnostic (/vst cdm): dump every candidate stack-count channel on
-- the Cooldown Manager item. Run once at 1 charge and once at 2 charges; the
-- pair of outputs shows which channels are readable vs secret vs throwing.
-- Remove before commit.
function deck:DebugCDM()
    local out = {}
    local function add(fmt, ...) out[#out + 1] = string.format(fmt, ...) end
    local function describe(label, fn)
        local ok = pcall(function()
            local v = fn()
            if isSecret(v) then
                add("%s: SECRET", label)
                return
            end
            add("%s: %s (%s)", label, tostring(v), type(v))
        end)
        if not ok then add("%s: THREW", label) end
    end

    add("issecretvalue global: %s", issecretvalue and "present" or "MISSING")
    add("state: charges %d, blizzardCount %s, shieldActive %s",
        chargeCount, tostring(blizzardCount), tostring(shieldActive))
    add("watchSlot: %s", tostring(watchSlot))
    describe("GetActionTexture(watchSlot)", function()
        return watchSlot and GetActionTexture(watchSlot) or nil
    end)
    add("(proc texture constant: %d)", PROC_SLOT_TEXTURE)

    for _, frameName in ipairs(COOLDOWN_VIEWER_FRAMES) do
        local viewer = _G[frameName]
        local pool = viewer and viewer.itemFramePool
        if pool then
            for itemFrame in pool:EnumerateActive() do
                local cdID = itemFrame.cooldownID
                local okM, isM = pcall(function()
                    return cdID ~= nil
                        and (cdID == cooldownIDCache
                            or cooldownInfoMatches(C_CooldownViewer.GetCooldownViewerCooldownInfo(cdID)))
                end)
                if okM and isM then
                    add("item found in %s (cooldownID %s)", frameName, tostring(cdID))
                    local fs = itemApplicationsFontString(itemFrame)
                    if not fs then
                        add("Applications FontString: NOT FOUND")
                    else
                        describe("GetText", function() return fs:GetText() end)
                        describe("GetStringWidth", function() return fs:GetStringWidth() end)
                        describe("GetUnboundedStringWidth", function() return fs:GetUnboundedStringWidth() end)
                        describe("GetStringHeight", function() return fs:GetStringHeight() end)
                        describe("GetWidth", function() return fs:GetWidth() end)
                        describe("IsShown", function() return fs:IsShown() end)
                        describe("fontStringHasText", function() return fontStringHasText(fs) end)
                    end
                end
            end
        end
    end
    if #out <= 1 then
        add("no matching Cooldown Manager item active (buff not up, or not tracked)")
    end
    add("readBlizzardStacks() -> %s", tostring(readBlizzardStacks()))
    return out
end
