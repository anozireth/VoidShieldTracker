# AGENTS.md

Guidance for AI coding agents working on **Void Shield Tracker**, a World of
Warcraft (Retail, interface 12.0.x) addon written in Lua.

## What this addon does

Tracks the Discipline Priest **Void Shield** proc, which behaves as a shuffled
3-card deck: each Penance cast turns one card, exactly one of three carries the
proc, and the deck reshuffles after all three are turned. The addon shows the
deck as three cards and predicts the probability of the next cast proccing.

## Project layout

```
VoidShieldTracker.toc   Load manifest. Lists files in load order; declares
                        SavedVariables: VSTDB; interface version; icon.
Core.lua                Namespace, saved-vars defaults, single event frame +
                        dispatch, spec detection, polling ticker, init.
Deck.lua                Detection (Penance + proc) and the phase-state deck
                        predictor. Owns all tracking state. Exposes display
                        state to the UI.
UI.lua                  Card frame, minimap button, Settings-API options panel,
                        slash commands.
```

**Load order matters.** `Core.lua` creates `_G["VoidShieldTracker"]` (the shared
`addon` table). `Deck.lua` and `UI.lua` fetch it via `local addon =
_G["VoidShieldTracker"]` and attach `addon.deck` / `addon.ui` at file scope, so
by `PLAYER_LOGIN` both submodules are present. Keep the `.toc` order:
`Core.lua`, `Deck.lua`, `UI.lua`.

## Lifecycle / control flow

1. `Core.lua` registers one `eventFrame` and dispatches by event name in a
   single `OnEvent` `if/elseif` chain. **Do not add a second event frame** — the
   original bug that made the addon never load was a second frame that only
   registered the events present at file-load time.
2. `PLAYER_LOGIN` → `onLogin()`: initializes `VSTDB` with defaults, builds the
   UI, initializes the deck, detects spec, then `addon:UpdateActiveState()`.
   Every other event early-returns until `addon.initialized` is true.
3. `addon:UpdateActiveState()` starts/stops the 0.1s ticker and shows/hides the
   UI based on `addon.isDiscPriest` and `VSTDB.shown`.
4. The ticker calls `deck:Tick()` (refreshes the cached PW:S action slot ~1/s,
   polls shield state); if shield state changed it calls `ui:Refresh()`.

### Events consumed

| Event | Purpose |
|-------|---------|
| `PLAYER_LOGIN` | One-time init |
| `PLAYER_ENTERING_WORLD` | Reset/prune deck on zone (instance = reshuffle) |
| `PLAYER_SPECIALIZATION_CHANGED` / `PLAYER_TALENT_UPDATE` / `TRAIT_CONFIG_UPDATED` | Re-detect spec, reset |
| `UNIT_SPELLCAST_CHANNEL_START` | **Penance detection** (player only) |
| `ACTIONBAR_SLOT_CHANGED` | Refresh cached PW:S slot |

## Detection mechanism (important, non-obvious)

- **Combat log is forbidden.** Registering `COMBAT_LOG_EVENT_UNFILTERED` from an
  addon triggers `ADDON_ACTION_FORBIDDEN` in 12.0. Do **not** use it. Penance is
  detected from `UNIT_SPELLCAST_CHANNEL_START` matched against
  `PENANCE_SPELL_IDS` (Deck.lua).
- **Proc is read from the action-bar texture.** While the Void Shield proc is
  up, the Power Word: Shield action button shows a different texture
  (`PROC_SLOT_TEXTURE = 7514191`) vs the normal one (`BASE_SLOT_TEXTURE =
  135940`). On each Penance: snapshot the texture at cast start, then re-read it
  after `procCheckDelayMs` (default 200ms). Classification:
  - shield already up at cast start → `RESULT_UNKNOWN` (a new proc can't be seen)
  - was down, now up → `RESULT_PROC`
  - was down, still down → `RESULT_NOPROC`
- This requires **PW:S on a visible action bar**. `watchSlot` is the cached slot;
  `refreshWatchSlot()` scans slots 1–180 for `PW_SHIELD_SPELL_IDS`. If not found,
  the UI shows a warning and detection can't work.
- These magic numbers (spell IDs, texture fileIDs) can change between game
  patches. If detection breaks after a patch, verify them first.

## The deck predictor (phase-state filter)

Lives in `Deck.lua`. Models "sampling without replacement": every 3-cast block
contains exactly one proc. Because we don't know which slot we started observing
on, **three phases** run in parallel for deck-start offsets 0/1/2. Casts that
violate "at most one proc per block" invalidate a phase.

- Input values: `1` = proc, `0` = no-proc, `-1` = unknown (shield already up).
- `Predictor_getProb` returns `P(next cast = proc)` averaged over valid phases,
  or `nil` if every phase died.
- `recordResult` auto-recovers when all phases die: rebuilds the predictor and
  replays the last `RECOVERY_REPLAY_WINDOW` results.
- `convergedOffset()` returns the sole surviving phase's offset (or nil), used to
  align the card display to the true deck boundary.

**Invariant:** there is exactly one proc per 3-card block. The UI relies on this
to resolve `UNKNOWN` cards to `noproc` once the block's proc is known (see
`GetDisplayState`). Preserve this invariant in any predictor changes.

### Display contract

`deck:GetDisplayState()` is the single interface to the UI. It returns:

```lua
{
  cards         = { [1..3] = "proc"|"noproc"|"unknown"|"future" },
  highlightSlot = <1-3 next card to flip, or nil if deck complete>,
  nextProb      = <0..1 or nil>,   -- P(next cast procs)
  next2Prob     = <0..1 or nil>,   -- P(cast after next procs)
  procFound     = <bool>,          -- proc already seen this block
  calibrating   = <bool>,          -- >1 phase still possible
  watchSlotOk   = <bool>,          -- PW:S found on a bar
  shieldActive  = <bool>,
}
```

When `displayCleared` is set (deck completed, board blanked after
`DECK_CLEAR_DELAY`), it returns a fresh face-down board but still reports live
`nextProb`. Adding a UI feature? Extend this table rather than reaching into
Deck.lua internals.

## Saved variables (`VSTDB`)

Defaults live in `Core.lua` `DB_DEFAULTS` and are merged recursively by
`applyDefaults` on login (so adding a new key with a default is forward-safe).
Current keys: `shown`, `locked`, `scale`, `opacity`, `procCheckDelayMs`,
`pruneOnZone`, `minimap = { hide, angle }`, `pos = { point, relPoint, x, y }`.

## UI conventions

- Frames use `BackdropTemplate` + `WHITE8x8` for pixel borders.
- `ui:Refresh()` reads `deck:GetDisplayState()` and re-renders; it's cheap and
  called on every recorded result and on shield-state changes.
- Probability colour mapping is `probColor()` in UI.lua (red→orange→yellow→
  green, cyan at 100%); keep thresholds (`THRESH_LO/HI`) consistent if changed.
- **Minimap button**: positioned by angle on the rim with radius derived from
  `Minimap:GetWidth()/2` (do not hardcode a radius — minimap size varies).
- **Options**: registered via the modern `Settings` API
  (`Settings.RegisterCanvasLayoutCategory` + `RegisterAddOnCategory`). Open with
  `Settings.OpenToCategory(category:GetID())`. **Pass the numeric category ID,
  not a string** — passing a string throws a range error in
  `C_SettingsUtil.OpenSettingsPanel`. Don't overwrite `category.ID`.

## Testing & validation

- **There is no in-repo test harness and no Lua interpreter is assumed.** The
  maintainer tests in-game via `/reload`. Don't claim a change is verified
  unless it actually was.
- A useful pre-flight is a structural check (balanced parens/braces/brackets and
  `function`/`if`/`for`/`while` vs `end`). Lua syntax errors in an addon surface
  in-game as a load error; enable with `/console scriptErrors 1`.
- Quick in-game checks: `/vst status`, watch the cards across several Penance
  casts, confirm the minimap button sits on the rim and `/vst` opens options
  without error.

## Conventions & gotchas

- WoW uses **Lua 5.1**. `math.atan2` exists; integer-only `%x` formatting is
  lenient but prefer `math.floor` before `string.format("%x", ...)`.
- Avoid global leakage; module state is file-local in Deck.lua. Public surface is
  `addon.deck:*` / `addon.ui:*`.
- Keep user-facing chat output minimal — the rewrite intentionally removed debug
  spam. Don't reintroduce `DEFAULT_CHAT_FRAME` debug prints in committed code.
- Bump `## Version` in the `.toc` with user-visible changes.
- This is a Git repo. Commit messages: imperative subject, brief body explaining
  the *why*. Commit only when asked.

## Related project

`VoidShieldHelper` (../VoidShieldHelper, by CeilingPanda) is the proven
reference for the detection approach and predictor. If a detection/predictor
question arises, its `VoidShieldHelper.lua` is the canonical source to compare
against.
