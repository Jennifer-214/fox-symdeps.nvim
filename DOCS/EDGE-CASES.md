# fox-symdeps.nvim — edge cases & known issues (the running list)

The concrete list behind the "cohesion/usability is a CLASS" discipline (REFERENCE.md). Rough edges
surface in the operator's live testing (headless can't catch the interactive/visual/cursor/color layer);
this is where they get logged so they're fixed as a batch, not rediscovered. Add to it as you hit things.

## Fixed (2026-07-05)

- **Lens fails on a template (`t`/`s`/Fields on `FixedPoint`)** — `find_fields` grabbed the FIRST symbol
  named X (often the un-instantiated primary), so size resolved but per-field offsets didn't. → now picks
  the definition whose range contains the cursor (the concrete specialization). *(902d591)*
- **`w` (width-lits) on a function** noise-outed → guarded to types, message via the persistent line.
- **"size probe failed to compile" on a function** (`ExecutionCore_Init`) — layout ran a sizeof probe on a
  function → guarded; functions short-circuit to a clean "function — …" line. *(043c21e)*
- **Lens errors flashed by unreadably** → persistent `⚠`/`ℹ` line in the HUD (`hud:set_message`).
- **Core edits "didn't take" in a live session** — `:FoxSymdepsReload` was lenses-only → added
  `:FoxSymdepsReloadAll` (core + lenses). This was the cause of several "already-fixed but still broken."
- **width-lits crying wolf at size 4 & 8** (the common widths) → gated the bare stride heuristic to > 8.
- **asm-diff analyzing the WRONG function** — substring match (`add` hit `padding`) → exact qualified-name.
- **Colors** — HUD selection burgundy → bright peach; theme illuminate `#4a3528` → warmer `#5e4029`.
- **g++ vs clang debug-info** — g++ names the temp under two `.file` indices + keys `.loc` off index 1;
  the source↔asm map now handles both dialects.

## Known / pending (not yet fixed)

- **Sync `rg` hitches the HUD** — Uses / Includers / dashboard run `rg` + treesitter *synchronously* on
  the event loop → a visible beat when opening on the 313-file engine. Make async. *(biggest felt jank)*
- **grep loud-failure** — `compose`/`includers`/`aggregate`/`browse`/dashboard `pcall(systemlist)` with no
  `shell_error` check → rg-absent renders as a calm "nothing here," indistinguishable from a real empty.
- **Template on the PRIMARY** — the `find_fields` fix handles cursor-on-a-specialization; if the cursor is
  on the primary template (no concrete instantiation), fields still won't resolve and the message should
  say "inspect a concrete `Foo<N>`" rather than the generic "put cursor on the definition."
- **Anonymous unions/structs dropped from the field map** (`layout.parse_field` needs an `Offset:`) → the
  byte map paints those live bytes as padding; straddle detection can't see them.
- **Header-basename collision** inflates the Includers / widest-headers count + misroutes the jump (latent —
  no collisions in the engine today).
- **Byte-map letters wrap at 26 fields** → ambiguous for exactly the big structs it's meant to explain.
- **Dashboard census fails on the incidental buffer** — opens the whole-project dashboard from a
  non-compiling / non-C++ buffer → the census tile errors though the project is fine. Pick a real TU.
- **compose double-resolve** — `compose.tree` + `compose.uses` each `members()` the root struct (grep +
  parse twice per inspect). Cache it.

## Caveats (inherent — not bugs, don't "fix")

- **`-O2`/`-O3` `.loc` line mapping is fuzzy** — the compiler schedules + inlines, so the explorer's
  source↔asm sync is *close*, not pixel-perfect. An instruction can attribute to a neighbouring line.
- **Compile latency** — the explorer / census / branch tags run a *real optimized build* (a few seconds
  on the engine). Cached after first run; only a save recompiles. Not removable, only maskable.
- **Headless can't test the interactive layer** — window focus, cursor context, clangd-dependent
  resolution, colors/contrast. The agent tests the mechanical (unit + `nvim -l` e2e); the operator
  surfaces the rest. This is the collaboration model, not a coverage gap.

## How these get caught

Unit tests + `nvim -l` e2e probes for the mechanical; operator manual testing for the interactive; a
periodic **cohesion/usability audit** (per lens: type vs function vs template · message accuracy ·
color/glyph consistency · blocking/jank) to sweep the whole class before hitting them live.
