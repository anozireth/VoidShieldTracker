# AGENTS.md

Guidance for AI coding agents working on **Void Shield Tracker**, a World of
Warcraft (Retail) addon written in Lua. It supports both **12.0.7** (live) and
**12.1** (PTR) from one codebase, adapting at runtime.

## What this addon does

Tracks the Discipline Priest **Void Shield** proc, which behaves as a shuffled
**N-card deck**: each Penance cast turns one card, exactly one of the N carries
the proc, and the deck reshuffles after all N are turned. The addon shows the
deck as N cards and predicts the probability of the next cast proccing.

**N is version-dependent** (`addon.deckSize`): **3** on 12.0.7 (33%/Penance), **4**
on 12.1 (25%/Penance). In 12.1, Mind Blast is a *separate, deterministic* proc
source and the proc accumulates up to **2 charges** (`addon.maxCharges`); 12.0.7
holds 1. Mind Blast does **not** turn a deck card, so it never enters the
predictor — its charge simply shows up via aura polling. Active charges are shown
as **pips** above the deck.

### Version detection

`Core.lua` reads `select(4, GetBuildInfo())` (the TOC number) once at load and
sets `addon.deckSize` / `addon.maxCharges` (threshold `>= 120100` ⇒ 12.1). These
are the single source of truth that `Deck.lua` (predictor size, charge cap) and
`UI.lua` (card count, pip count) read. Re-check the `120100` threshold if a PTR
build reports a different TOC number.

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
| `UNIT_SPELLCAST_SUCCEEDED` | Charge inference: Mind Blast +1, Void Shield cast -1 (player only) |
| `ACTIONBAR_SLOT_CHANGED` | Refresh cached PW:S slot |

## Detection mechanism (important, non-obvious)

- **Reading the proc aura directly is NOT possible.** In 12.0 aura fields
  (`spellId`, `applications`, …) are **"secret values"** while addon execution is
  tainted: any *comparison* on them throws `attempt to compare ... a secret number
  value, while execution tainted by 'VoidShieldTracker'`. So you cannot find the
  aura by matching `spellId`, nor branch on its stack count.
  `C_UnitAuras.GetPlayerAuraBySpellID` is also unreliable for this proc. **Do not
  reintroduce aura inspection.** Likewise `COMBAT_LOG_EVENT_UNFILTERED` is
  forbidden (`ADDON_ACTION_FORBIDDEN`). A probe confirmed `GetActionCount`,
  `C_Spell.GetSpellCastCount`, etc. are all secret too; only `GetActionTexture`
  (binary) is directly usable.
- **Penance detection.** `UNIT_SPELLCAST_CHANNEL_START` matched against
  `PENANCE_SPELL_IDS` (Deck.lua). Spell IDs from cast events are **not** secret.
- **Proc up/down from the PW:S action-button texture.** `pollShieldState()` reads
  the button: `PROC_SLOT_TEXTURE = 7514191` while a proc is up; **any other
  (non-nil) texture means zero charges**. The base icon (`BASE_SLOT_TEXTURE =
  135940`, same on 12.0.7 and 12.1) is deliberately not required to match, so a
  base-icon change in a future patch degrades to "no charge" instead of silently
  freezing the state; it is kept only for `scanBarTexture`'s button-locating
  fallback. Requires **PW:S on a visible action bar**; `refreshWatchSlot()`
  caches the slot. This is the authoritative 0-vs-(≥1) signal.
- **Every `deck:Tick()` caller MUST honor the `changed` return** by calling
  `ui:Refresh()`. Tick consumes the state change (prev vs current snapshot), so
  a caller that discards it swallows the update for everyone: spending the last
  proc changes the PW:S button icon → fires `ACTIONBAR_SLOT_CHANGED` → that
  handler's Tick ate the 1→0 transition and the pip stayed lit until the next
  unconditional refresh. Core's ticker and the `ACTIONBAR_SLOT_CHANGED` handler
  both refresh-on-changed now; keep it that way for any new caller.
- **Exact charge count: piggyback Blizzard's Cooldown Manager.** Blizzard writes
  the aura stack count into an item FontString **only when stacks > 1** (plain
  `""` otherwise — `CooldownViewerBuffItemMixin:GetApplicationsText`). The number
  itself is secret and can never be read — but **whether a value is secret is
  itself readable** via the sanctioned `issecretvalue()` global. Secret text can
  only mean Blizzard rendered a count ⇒ stacks > 1 ⇒ 2 (our cap); plain empty
  text ⇒ 1 (texture already said ≥1). That one bit is all we need
  (`fontStringHasText` in Deck.lua). **The text is the ONLY usable channel**:
  in-game probing showed every layout metric (`GetStringWidth`,
  `GetStringHeight`, `GetWidth`, `GetUnboundedStringWidth`) reads SECRET even
  while the text is plainly nil — metric secrecy sticks to the FontString
  regardless of content, so metrics carry no information and consulting them
  as a "text present" signal falsely reports 2 stacks forever. `GetText` is
  cleanly discriminating: plain `nil`/`""` at 1 stack, secret at >1.
  `readBlizzardStacks()` scans the
  `BuffIconCooldownViewer` / `BuffBarCooldownViewer` item pools
  (`itemFramePool:EnumerateActive()`), matches our item by its **non-secret
  `cooldownID`** (mapped to the spell via `C_CooldownViewer.GetCooldownViewerCooldownInfo`),
  then probes the `Applications` FontString (`itemFrame.Applications.Applications`
  icon viewer / `itemFrame.Icon.Applications` bar viewer). **Never** match by
  `itemFrame:GetSpellID()` or the icon texture — both carry the secret aura
  spellId. Each probe is individually `pcall`'d and the whole read runs under
  `pcall`, so any secret we touch degrades to the inference fallback instead of
  erroring. Needs the user's Cooldown Manager to track the buff; ref
  `wow-ui-source` `Blizzard_CooldownViewer/CooldownViewer.lua`.
- **Classification.** With an exact count (`blizzardCount`), `classifyCast` uses
  the charge **delta** (`chargesOnCast` vs `chargeCount`): increase ⇒ `RESULT_PROC`
  even while a charge was already up; at cap ⇒ `RESULT_UNKNOWN`. Without it, it
  falls back to the binary texture (proc already up ⇒ `RESULT_UNKNOWN`).
- **Fallback count inference.** When the Cooldown Manager isn't showing the buff,
  `deck:OnSpellSucceeded` (from `UNIT_SPELLCAST_SUCCEEDED`) infers 1-vs-2: Mind
  Blast (`MIND_BLAST_SPELL_IDS`, 12.1 only) +1, Void Shield cast
  (`VOID_SHIELD_CAST_IDS = 1253593`) −1; skipped while `blizzardCount` is
  authoritative. Known gap in this mode: a proc landing on top of an existing
  charge isn't seen until the next reset. `/vst status` shows `(CDM)` vs
  `(inferred)`.
- These magic numbers (spell IDs, texture fileIDs, viewer frame names) can change
  between game patches. If detection breaks after a patch, verify them first.

## The deck predictor (phase-state filter)

Lives in `Deck.lua`. Models "sampling without replacement": every N-cast block
contains exactly one proc, where `N = addon.deckSize` (module-local `N`, set in
`deck:Initialize()`). Because we don't know which slot we started observing on,
**N phases** run in parallel for deck-start offsets `0..N-1`. Casts that violate
"at most one proc per block" invalidate a phase. (The predictor was originally
hardcoded to 3; all such literals are now expressed in terms of `N` / `N-1`.)

- Input values: `1` = proc, `0` = no-proc, `-1` = unknown (shield already up).
- `Predictor_getProb` returns `P(next cast = proc)` averaged over valid phases,
  or `nil` if every phase died.
- `recordResult` auto-recovers when all phases die: rebuilds the predictor and
  replays the last `RECOVERY_REPLAY_WINDOW` results.
- `convergedOffset()` returns the sole surviving phase's offset (or nil), used to
  align the card display to the true deck boundary.

**Invariant:** there is exactly one Penance proc per N-card block (Mind Blast
procs are a separate source and never enter the predictor). The UI relies on this
to resolve `UNKNOWN` cards to `noproc` once the block's proc is known (see
`GetDisplayState`). Preserve this invariant in any predictor changes.

### Display contract

`deck:GetDisplayState()` is the single interface to the UI. It returns:

```lua
{
  cards         = { [1..N] = "proc"|"noproc"|"unknown"|"future" },
  highlightSlot = <1-N next card to flip, or nil if deck complete>,
  nextProb      = <0..1 or nil>,   -- P(next cast procs)
  next2Prob     = <0..1 or nil>,   -- P(cast after next procs)
  procFound     = <bool>,          -- proc already seen this block
  calibrating   = <bool>,          -- >1 phase still possible
  watchSlotOk   = <bool>,          -- PW:S found on a bar
  shieldActive  = <bool>,
  charges       = <0..maxCharges>, -- active proc charges (drives the pips)
  maxCharges    = <1 on 12.0.7, 2 on 12.1>,
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
- **Card count and pip count are built from `addon.deckSize` / `addon.maxCharges`
  at `ui:Create()` time** (which is why Core sets them before `ui:Create()`).
  `ui:Refresh()` loops `#frame.cards` (not a literal) and lights `frame.pips`
  `1..charges`.
- `ui:Refresh()` reads `deck:GetDisplayState()` and re-renders; it's cheap and
  called on every recorded result and on shield- or charge-state changes.
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
- Bump `## Version` in the `.toc` with user-visible changes. It is the single
  source of truth for the release version — see **Releasing** below.
- This is a Git repo. Commit messages: imperative subject, brief body explaining
  the *why*. Commit only when asked.

## Releasing

Distribution is automated by [BigWigsMods/packager](https://github.com/BigWigsMods/packager)
in `.github/workflows/release.yml`, triggered by pushing a `v*` tag. It builds the
zip (contents governed by `.pkgmeta`), generates a changelog from the commits
since the previous tag, and uploads to a GitHub Release plus whichever addon
sites have both an ID in the `.toc` and a matching secret in the repo.

| Site | `.toc` key | Repo secret |
|------|-----------|-------------|
| GitHub Releases | — | `GITHUB_TOKEN` (automatic) |
| CurseForge | `## X-Curse-Project-ID` | `CF_API_KEY` |
| Wago | `## X-Wago-ID` | `WAGO_API_TOKEN` |
| WoWInterface | `## X-WoWI-ID` | `WOWI_API_TOKEN` |

Both halves are required — a site with no ID line, or no secret, is silently
skipped rather than failing the build.

**The `.toc` version is authoritative.** A CI step rejects the release if the tag
disagrees with `## Version`, so the bump belongs in the release commit:

```
# 1. bump ## Version in VoidShieldTracker.toc (and the README badge)
# 2. commit
git tag -a v2.4.0 -m "..."
git push origin main --follow-tags
```

Pre-release tags (`v2.4.0-alpha`, `v2.4.0-beta1`) are compared against the `.toc`
with the suffix stripped, and the packager marks the upload as alpha/beta.

Gotchas:

- The packager maps each `## Interface` number to a CurseForge game version via
  their API. If a number isn't in CF's list yet (common right after a PTR build
  appears), the CF upload fails — wait for CF to add it or drop that interface
  number for the release.
- The `.toc` version is *not* keyword-substituted, deliberately: this repo is
  cloned directly into `Interface/AddOns`, so a `@project-version@` placeholder
  would be what the maintainer sees in-game.

## Related project

`VoidShieldHelper` (../VoidShieldHelper, by CeilingPanda) is the proven
reference for the detection approach and predictor. If a detection/predictor
question arises, its `VoidShieldHelper.lua` is the canonical source to compare
against.
