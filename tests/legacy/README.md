# Legacy / archived sources

Superseded originals, kept verbatim as harvest/reference material — **not run**, not part of the suite.

- **`provider.lua`** — the original trader byte-layout provider (`fox-symdeps-trader/provider.lua`,
  2026-07-03), *before* it was adapted into the self-gating lens
  `lua/fox-symdeps/lenses/byte_layout_cascade.lua`. The lens is the living version; this is the
  un-adapted original, preserved for reference/scrape. Its test (`test_wfix1.lua`), header fixtures
  (`fx/`), and runner were folded into `tests/` already — this file was the only piece not duplicated
  there, so it's the sole thing kept from the old `fox-symdeps-trader.folded-in-*` archive.
