# Void Shield Tracker

A lightweight World of Warcraft addon that tracks the **Void Shield** proc deck
for **Discipline Priests** and predicts when your next proc is coming.

![Version](https://img.shields.io/badge/version-2.3.0-blue) ![WoW](https://img.shields.io/badge/WoW-12.0.7%20%7C%2012.1-orange)

## What it does

The Void Shield proc works like a shuffled deck of cards: every Penance cast
turns over one card, exactly **one** card in the deck carries the proc, and once
all of them are turned the deck reshuffles. Void Shield Tracker shows that deck
and tells you the odds of your next Penance proccing.

The mechanic changed in 12.1, and the addon adapts to whichever client you're
running — no separate download:

| | 12.0.7 | 12.1 |
|---|---|---|
| Penance deck | 3 cards (33% each) | 4 cards (25% each) |
| Proc charges held | 1 | up to 2 |
| Proc sources | Penance | Penance + Mind Blast |

On 12.1 **Mind Blast grants a charge outright** — it's not a gamble, so it never
turns a deck card and never affects the prediction.

- **Card display** — each Penance reveals a card as a **proc** (Void Shield
  icon) or **no-proc** (Penance icon). Once the proc is found, the remaining
  cards are shown as no-procs automatically.
- **Charge pips** — a row of pips above the deck shows how many Void Shield
  charges you're currently holding (one pip on 12.0.7, two on 12.1).
- **Next-proc prediction** — a colour-coded readout shows the probability that
  your next cast (and the one after) procs, from red (impossible) through
  orange/yellow/green to cyan (guaranteed).
- **Self-calibrating** — you don't have to start watching at a deck boundary.
  The tracker figures out where you are within a few casts; enable *fresh deck
  on entering an instance* for instant alignment in dungeons/raids.
- **Auto-reset** — the board blanks to face-down shortly after a deck completes,
  ready for the next one.

## Installation

1. Download or clone this repository.
2. Copy the `VoidShieldTracker` folder into:
   ```
   World of Warcraft/_retail_/Interface/AddOns/
   ```
3. Restart WoW or run `/reload`. The addon only displays on a Discipline Priest.

## Usage

The tracker window appears automatically while you're playing Discipline. Drag
it to reposition (unless locked).

### Reading the cards

| Card | Meaning |
|------|---------|
| Void Shield icon (green tint) | This cast **procced** |
| Penance icon (dimmed/red) | This cast did **not** proc |
| Face-down (blue, dim) | Not yet turned this deck |
| Highlighted border | The next card to be revealed; border colour = proc chance |

The **Next proc** line shows the chance your next Penance procs, with the
following cast's chance after it. `(calibrating)` appears until alignment is
certain.

### Slash commands

| Command | Action |
|---------|--------|
| `/vst` | Open the options panel |
| `/vst toggle` | Show/hide the tracker |
| `/vst reset` | Reset the deck |
| `/vst resetpos` | Recenter the frame |
| `/vst status` | Print current state to chat |

### Minimap button

- **Left-click** — open options
- **Right-click** — reset the deck
- **Drag** — reposition around the minimap

### Options

Open with `/vst` or the minimap button:

- Show tracker / lock frame / show minimap button
- Assume a fresh deck when entering an instance
- Frame **scale** and **opacity**
- **Proc detection delay** (how long after a cast the proc texture is read)

## Requirements

- **Discipline Priest** — the addon is inactive on other specs/classes.
- **Power Word: Shield on an action bar** — proc detection reads the PW:S
  button texture. If it isn't on a visible bar, the readout warns you.
- **Blizzard's Cooldown Manager showing the Void Shield buff** — *optional, 12.1
  only.* With it, the addon knows the exact charge count and can spot a Penance
  proc that lands while you're already holding a charge. Without it, the count
  is inferred from your casts and such a cast is recorded as unknown. `/vst
  status` reports which mode is active.

## How it works (short version)

Penance casts are detected via `UNIT_SPELLCAST_CHANNEL_START` (the combat log is
off-limits to addons in 12.0). Whether a proc is up is read from the Power Word:
Shield action-button texture, which swaps to distinct art while the Void Shield
proc is active.

Reading the *number* of charges is harder, because 12.0 made aura data "secret"
— an addon can't inspect the buff's stack count at all. So on 12.1 the addon
piggybacks off Blizzard's own Cooldown Manager, which displays the stack number
only when you hold more than one. It never reads that number; it only asks
whether the text is secret, and text being present at all means you're at two.

A small "phase-state filter" runs one candidate deck offset per card in
parallel and discards any that break the one-proc-per-deck rule, which yields an
honest probability for upcoming casts. See [AGENTS.md](AGENTS.md) for the full
technical breakdown.

## Credits

Detection approach and the deck-prediction model are shared with
[VoidShieldHelper](https://github.com/Jerry-Ma/void_shield_helper) by
CeilingPanda — Void Shield Tracker reimagines the same proven core as a
card-based deck visualization.

## License

[MIT](LICENSE) © anozireth
