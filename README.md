# Void Shield Tracker

A lightweight World of Warcraft addon that tracks the **Void Shield** proc deck
for **Discipline Priests** and predicts when your next proc is coming.

![Version](https://img.shields.io/badge/version-2.2.1-blue) ![WoW](https://img.shields.io/badge/WoW-12.0-orange)

## What it does

The Void Shield proc works like a shuffled **3-card deck**: every Penance cast
turns over one card, exactly **one** of the three cards carries the proc, and
once all three are turned the deck reshuffles. Void Shield Tracker shows that
deck as three cards and tells you the odds of your next Penance proccing.

- **Three-card display** — each Penance reveals a card as a **proc** (Void
  Shield icon) or **no-proc** (Penance icon). Once the proc is found, the
  remaining cards are shown as no-procs automatically.
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

## How it works (short version)

Penance casts are detected via `UNIT_SPELLCAST_CHANNEL_START` (the combat log is
off-limits to addons in 12.0). Each proc is read from the Power Word: Shield
action-button texture, which swaps to a distinct art while the Void Shield proc
is up. A small "phase-state filter" runs three candidate deck offsets in
parallel and discards any that break the one-proc-per-three-cards rule, which
yields an honest probability for upcoming casts. See [AGENTS.md](AGENTS.md) for
the full technical breakdown.

## Credits

Detection approach and the deck-prediction model are shared with
[VoidShieldHelper](https://github.com/Jerry-Ma/void_shield_helper) by
CeilingPanda — Void Shield Tracker reimagines the same proven core as a
card-based deck visualization.

## License

See [LICENSE](LICENSE) if present, otherwise all rights reserved by the author.
