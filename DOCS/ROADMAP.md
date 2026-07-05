# fox-symdeps.nvim — roadmap & integration ideas

Living design doc. What this tool is, where it's going, and how it hooks into the rest of nvim.

## What it is (and the design principle)

A **compiled-reality cockpit** for C++: per-symbol analysis (layout, cache lines, asm, break-check,
consumers/callers, docs mentions) surfaced in a HUD. It is deliberately **a hub, not an IDE.**

- **It CONSUMES the ecosystem** (clangd, treesitter, your picker, the file tree) as data + UI. It rides
  `vim.ui.select`, so every picker is *your* fzf/telescope automatically.
- **It EXPOSES its analysis** so the rest of your config can hook in.
- **It never reinvents commodity** (completion, git, file management, fuzzy-finding). Those stay with the
  plugins that already do them better than we would. The differentiator is the *analysis layer* — the one
  thing no off-the-shelf tool has, because it only matters for a fixed-point, branchless, cache-aware engine.

The "custom IDE" is your nvim **distribution** bundling the commodity plugins + fox-symdeps as the crown
jewel — not fox-symdeps swallowing everything.

## The planes (where each surface lives) + how they connect

Several surfaces, deliberately **NOT all in nvim.** Split by *mode*. This mirrors the engine's actual
decouple — the `.E.2` **headless-engine ↔ viewer split** (tick-trader workspace,
`plans/v5.15-live-readiness/`; specs `headless-engine-viewer-split-pattern`,
`native-tui-via-mmap-readonly-pattern`, `dual-format-metrics-publication-pattern`,
`built-in-observability-pattern`). The engine side below is the **current** design and **will change**
before this ships — so the plugin couples to *none* of its specifics; it talks only to the **integration
contract** (next section). Treat the mmap / `fox-tui` / Prometheus details as context, not a dependency.

- **Data plane — the headless engine.** Runs 24/7, single-writer. PUBLISHES its state to a read-only
  **mmap shared-memory region** (lock-free seqlock reads), plus **dual-format metrics** (mmap for real-time +
  a Prometheus `/metrics` endpoint), plus a **JSONL audit log**. Commands come back over a **UDS** channel
  (`fox-cli`). No UI of its own.
- **Monitoring plane — the read-only viewers.** `fox-tui` (notcurses, attaches to the mmap region) + Grafana
  (scrapes Prometheus). Every viewer is a **read-only consumer** of the engine's published state; the
  single-writer design keeps them decoupled *by construction* (Class-18-clean).
- **Editor plane — nvim + fox-symdeps (this repo).** DEV-TIME static analysis (layout, asm, cache lines,
  break-check, roam). **Cross-plane hook:** nvim depends only on the **runtime-provider contract**
  (`live_facts(symbol)` — see "Integration contract"), *never* on the engine's transport. A concrete adapter
  (an mmap-reader today, a socket client or whatever the engine settles on later) sits behind the contract —
  so the cockpit fuses *static* (what a symbol IS) with *live* (what it's DOING) without knowing or caring how
  the engine publishes, and the engine's architecture can change freely.
- **CLI / CI plane.** Headless fact producers + regression gates (pre-commit / CI).
- **AI plane — libfox-intel.** Explanation / suggestion over the facts.

**Data flow:** `headless engine → (mmap state + Prometheus + JSONL) → read-only consumers`. Consumers:
`fox-tui`, Grafana, and — the hook — the nvim cockpit. They all read the *same* published state; none writes.

**The join key is the symbol — and the important ones already ARE the published state.** `ExecutionCore` is
a per-core state struct the engine publishes; a hot-path function has a per-node latency histogram
(`built-in-observability-pattern`). So "inspect `ExecutionCore` in nvim" reads its live per-core state from
the mmap region right beside its static layout + asm. (The map is *symbol → published-state field*, not
automatic — symbols with no published counterpart simply show static only.)

## Integration contract (the stable seam — do NOT couple to the transport)

The engine's telemetry mechanism **will change** before this ships (mmap + `fox-tui` is today's `.E.2`
design; it could become sockets, a different IPC, or something else entirely). So the plugin depends on a
**contract**, never on the transport. A minimal runtime provider:

```lua
-- live facts for a symbol, or nil if none/unavailable. Non-blocking.
provider.live_facts(symbol) -> { [metric_name] = value, ... } | nil
```

- The plugin only ever calls this, and fuses whatever comes back with the static analysis (keyed by symbol).
- A concrete **adapter** fulfills it — an mmap-reader, a socket client, a Prometheus scraper — whatever the
  engine actually exposes. Swap the engine's transport → rewrite the (small) adapter; the plugin is untouched.
- Ships with a **null adapter** (returns nil) so the plugin works standalone today and gains the live column
  the day a real adapter lands.

The transport stays out of scope until the engine settles. The contract is the only thing that has to hold —
and it's small enough to revise cheaply if even it needs to.

## Exploratory — roam the codebase, not just cursor-point

- [x] **roam** (`<leader>dr`): clangd `workspace/symbol` fuzzy pick (functions *and* structs) → inspect.
- [x] **includers** (`⊃` view): files that `#include` a type's defining header, **grouped into
  collapsible per-directory subsections** (land on the dir histogram; expand a dir for its files). The
  *honest breadth* Consumers can't give — clangd references don't follow type aliases (`using Money =
  FixedPoint<…>`), so a type reached only through aliases looks far narrower than it is. `#include` can't
  be aliased away. (`FixedPoint`: Consumers 75-refs-in-header vs Includers **42 files** across 8 dirs.)
- [x] **codebase dashboard** (`<leader>dw`): a warm, tree-navigable surface (same palette/nav/glyphs as
  the HUD, so it reads as one tool) holding whole-project tiles that fill async. Shipped tiles:
  - **⊃ Widest headers** — every in-repo header ranked by `#include` count = change-blast-radius
    (`FixedPointN.hpp` 42 · `BitmapMacros.hpp` 26 · …). One grep + tally, system headers excluded.
  - **▦ Biggest structs** — struct census straight from `clang -fdump-record-layouts` (reliable sizes,
    no clangd round-trip). Sorted by footprint, colored by cache-residency (green fits a line · wheat
    spills the residency band · plain = large aggregate). `<CR>` grep-resolves the def and jumps.
- [ ] **more dashboard tiles**: every cache-line straddler (needs per-field span from the same layout
  dump), project-wide width-literal audit, hot-path branch budget. Each slots into the tile array.
- [ ] **graph navigation**: fluid walk of consumers ↔ includers ↔ callers ↔ uses ↔ contains with
  breadcrumbs + pin-and-compare (the panel's history is the seed).

## Integration — INBOUND (fox-symdeps consumes other plugins)

- **File tree** (neo-tree; partially wired via `neotree.lua`):
  - annotate the tree — badge files containing straddlers / width-literal suspects / the tracked symbol's
    consumers, so it reads as "where are the interesting files."
  - reveal-from-HUD — jump the tree to a consumer/entry file.
  - scope-to-selection — pick a dir in the tree, run an aggregate lens on just that subtree.
- **Picker**: roam/browse already ride `vim.ui.select`. Keep everything on it.
- **LSP / treesitter**: already the data spine.

## Integration — OUTBOUND (expose fox-symdeps so others hook in) ← the "cohesive" unlock

- **Diagnostics** *(highest-leverage)*: publish cache-line straddles + width-literal suspects as nvim
  `vim.diagnostic` entries (virtual text + signs + Trouble list). Turns the lenses into an **ambient layer**
  that shows *as you code*, through the native plumbing every UI already understands. This is what turns it
  from "a thing you open" into "an integrated experience."
- **Statusline / winbar**: a component with the current symbol's size/straddle status
  (e.g. `◇ FixedPoint 16B ✓`) for lualine/heirline.
- **Telescope extension**: `:Telescope fox-symdeps roam|offenders|…`.
- **Lua API**: `require("fox-symdeps").layout_of(name)`, `.offenders()`, `.asm_of(fn)` — so your config and
  other plugins can query the analysis.
- **User events**: fire `User FoxSymdeps*` autocmds on inspect/analysis so other plugins can react.
- **Quickfix / loclist**: aggregate results → quickfix (`:cnext` the offenders). `width-lits` already does this.

## Visual-selection suite

- **analyze-selection**: select fields / a range → layout footprint of just those (cache-line cost of the selection).
- **asm-of-selection**: block asm for a selected region.
- **pin-all-in-selection**: select a region spanning several symbols → pin all → compare layouts side by side.
- **scope-aggregate**: visually select a dir/set → run an aggregate lens on just it.
- an **operator / textobject** (`gs{motion}`) to inspect the symbol in a motion range.

## Toolchain — beyond the plugin ("one core, many surfaces")

The fox-health pattern (one `lib*.a` → many surfaces) applied to the analysis:

- Factor the analysis into a **shared core** (lib / CLI) emitting JSON fact-records → consumed by the
  **editor plane** (explore), the **CLI / CI plane** (fail a commit on a `sizeof`/offset change or a new
  hot-path branch), the **AI plane** (`libfox-intel` explain/suggest), and the **monitoring plane** (the
  custom runtime UI — see "The planes"). One core, many surfaces; each surface lives where its *mode* fits.
- **Measurement — two kinds, don't conflate them:**
  - *Dev-time* (`fox-bench`): microbenchmark the hot path under `perf` (cycles / cache-misses /
    branch-mispredicts), fingerprinted per commit → feeds CI regression + annotates the cockpit (measured
    cycles *next to* the static asm). Static says "gained a branch"; the bench says "and it cost 12ns."
  - *Runtime* (live telemetry from the running engine): per-core latency / fills / state, published to the
    engine's read-only surface → `fox-tui` / Grafana, NOT nvim. The cockpit can *read* these back for the
    inspected symbol through the runtime-provider contract (keyed by symbol; whatever transport backs it) —
    but it never hosts the live dashboard itself.

## Priority

Near-term, highest-leverage: (1) **diagnostics integration** (ambient, hooks the whole ecosystem),
(2) **aggregate dashboard** (the exploratory marquee), (3) **visual-selection analyze**. The toolchain /
measurement pieces are the big bets once the plugin is fleshed out.

Guardrail: the plugin exists to serve *building the engine*. Keep it in that ratio — don't let the cockpit
become the mission.
