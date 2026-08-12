# Changelog

## 2.3.0 — 2026-08-12

First public release. One download now covers both **12.0.7** and **12.1** — the
addon detects your client and adapts at runtime.

**New: 12.1 support.** The Void Shield mechanic changed in 12.1, and the tracker
follows it:

- The Penance deck is **4 cards** on 12.1 (25% per cast) instead of 3 (33%).
- The proc now stacks to **2 charges**, shown as a row of pips above the deck.
- **Mind Blast grants a charge outright.** It isn't a gamble, so it never turns a
  deck card and never skews the prediction.

**Exact charge tracking.** If Blizzard's Cooldown Manager is displaying the Void
Shield buff, the tracker knows precisely how many charges you're holding — which
means it now catches a Penance proc that lands while you already have one. That
case used to be recorded as unknown. Without the Cooldown Manager the count is
inferred from your casts, as before; `/vst status` tells you which mode is
active.

**Fixed**

- The charge pip could stay lit after you spent your last charge, until
  something else forced a refresh.
- Proc detection no longer depends on recognising the *base* Power Word: Shield
  icon. If a future patch changes that art, the tracker reports "no charge"
  instead of freezing on a stale state.

## Earlier versions

These predate publication to any addon site and were never distributed.

- **2.2.3** (2026-06-16) — Updated for 12.0.7.
- **2.2.2** — Fixed the card display freezing after roughly 30 casts.
- **2.2.1** — Unknown cards now resolve to no-proc once the deck's proc is known.
- **2.2.0** — Deck resets only after the third cast; added an opacity setting.
- **2.1.0** — Auto-reset of the deck display; fixed minimap button placement and
  opening the options panel.
- **2.0.0** — Rewrite: card-based UI, minimap button, options panel, and a fix
  for the addon failing to activate.
- **1.0.1** — Split into Core/Deck/UI modules; fixed an action-blocked error on
  load.
- **1.0.0** — Initial version: 3-card deck tracking for Discipline Priest.
