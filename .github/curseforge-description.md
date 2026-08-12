# Void Shield Tracker

**Void Shield Tracker** shows the Discipline Priest Void Shield proc for what it
actually is — a shuffled deck of cards — and tells you the odds that your next
Penance turns over the winning one.

> _[Screenshot 1: the tracker mid-deck, one card revealed as a proc, prediction
> line visible]_

## Before you install — two requirements

- **Discipline Priest.** The addon stays hidden on every other spec and class.
- **Power Word: Shield must be on a visible action bar.** Proc detection works by
  reading the PW:S button's artwork, which changes while the proc is up. If the
  spell isn't on a bar the tracker says so on screen rather than quietly showing
  you nothing.

_Optional, 12.1 only:_ if Blizzard's Cooldown Manager is displaying the Void
Shield buff, the addon knows your exact charge count and can catch a Penance proc
that lands while you're already holding one. Without it, the count is inferred
from your casts — everything still works, just slightly less precisely.

## Why a deck of cards?

The Void Shield proc isn't a flat roll on every cast. It behaves like a shuffled
deck: exactly **one** card in the deck carries the proc, every Penance turns one
card face-up, and once the deck is exhausted it reshuffles. That means your real
odds shift with every cast — and if the deck is nearly out with no proc yet,
your next Penance is close to guaranteed.

Void Shield Tracker draws that deck and does the math for you.

## Features

- **The deck, face up.** Each Penance flips a card: a **proc** (Void Shield icon,
  green) or a **no-proc** (Penance icon, dimmed). Once the proc is found, the
  rest of the deck resolves to no-procs automatically.
- **Next-proc odds.** A colour-coded readout gives the probability that your next
  cast procs — and the one after it — from red (impossible) through orange and
  yellow to green and cyan (guaranteed). The next card to flip is highlighted in
  its odds colour.
- **Charge pips.** A row of pips above the deck shows how many Void Shield
  charges you're currently sitting on.
- **Self-calibrating.** You don't have to start watching at a deck boundary. The
  tracker works out where in the deck you are within a few casts. Turn on
  _"assume a fresh deck when entering an instance"_ for instant alignment in
  dungeons and raids.
- **Auto-reset.** The board blanks to face-down shortly after a deck completes,
  ready for the next one.
- **Stays out of the way.** Draggable and lockable, with adjustable scale and
  opacity, plus an optional minimap button.

> _[Screenshot 2: the options panel]_

## One download, both patches

The Void Shield mechanic changed in 12.1. The addon detects your client build and
adapts at runtime — there is no separate version to install.

|                   | 12.0.7             | 12.1                  |
| ----------------- | ------------------ | --------------------- |
| Penance deck      | 3 cards (33% each) | 4 cards (25% each)    |
| Proc charges held | 1                  | up to 2               |
| Proc sources      | Penance            | Penance + Mind Blast  |

On 12.1, Mind Blast grants a charge outright — it isn't a gamble, so it never
turns a deck card and never skews the prediction.

## Commands

| Command         | Action                      |
| --------------- | --------------------------- |
| `/vst`          | Open the options panel      |
| `/vst toggle`   | Show or hide the tracker    |
| `/vst reset`    | Reset the deck              |
| `/vst resetpos` | Recenter the frame          |
| `/vst status`   | Print current state to chat |

The minimap button opens options on left-click and resets the deck on
right-click.

## How it works

Patch 12.0 made aura data off-limits to addons — a tracker can't simply read the
Void Shield buff or its stack count. So Void Shield Tracker detects Penance casts
through the spellcast events and reads whether a proc is up from the Power Word:
Shield action button, whose art swaps while the proc is active. A "phase-state
filter" then runs one candidate deck alignment per card in parallel, discarding
any that break the one-proc-per-deck rule, which is what produces an honest
probability instead of a guess.

The full technical write-up is in the repository if you're curious.

## Bugs, requests, source

Development happens on
[GitHub](https://github.com/anozireth/VoidShieldTracker) — issues and pull
requests welcome. Please include your patch version and whether `/vst status`
reports `(CDM)` or `(inferred)` when reporting a detection problem.

## Credits

The detection approach and deck-prediction model are shared with
[VoidShieldHelper](https://github.com/Jerry-Ma/void_shield_helper) by
CeilingPanda. Void Shield Tracker reimagines the same proven core as a
card-based deck visualization.

Released under the MIT license.
