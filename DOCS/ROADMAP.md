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

Several surfaces over one shared fact-spine, deliberately **NOT all in nvim.** Split by *mode*, with a
clear data flow between them:

- **Data plane — the engine itself.** Runs 24/7. PRODUCES runtime facts (per-core state, latency, fills).
  No UI of its own; it just emits telemetry.
- **Monitoring plane — the custom runtime UI (planned, NOT nvim).** CONSUMES the data plane's telemetry,
  shows it live (dashboards, histograms — glanceable, always-on, wall-monitor style), AND serves those live
  facts to anyone who asks. Its own app because live monitoring is a different interaction mode than editing.
- **Editor plane — nvim + fox-symdeps (this repo).** DEV-TIME, static, compiled-reality analysis (layout,
  cache lines, asm, break-check, roam). AND — the cross-plane hook — it CONSUMES live facts from the
  monitoring plane for the symbol under inspection, so the cockpit fuses *static* (what a symbol IS) with
  *live* (what it's DOING right now).
- **CLI / CI plane.** Headless fact producers + regression gates (pre-commit / CI).
- **AI plane — libfox-intel.** Explanation / suggestion over the facts.

**Data flow:** `engine → monitoring plane → (its dashboard UI) + (the nvim cockpit)`. nvim reads from the
monitoring plane, **never from the engine directly** — dev tooling stays decoupled from the running
production system; it only reads already-collected telemetry.

**The join key is the symbol.** A struct/function's static facts (clangd/compile, in nvim) and its runtime
facts (latency/fills, from the monitoring plane) share one identity — so "inspect `ExecutionCore` in nvim"
can show its layout + asm AND pull its live per-core latency from the monitoring plane, side by side. That
symbol-keyed fusion is what makes the planes one *system* instead of three separate apps.

## Exploratory — roam the codebase, not just cursor-point

- [x] **roam** (`<leader>dr`): clangd `workspace/symbol` fuzzy pick (functions *and* structs) → inspect.
- [ ] **aggregate health dashboard**: whole-codebase views instead of per-symbol — every cache-line
  straddler, biggest structs by size, project-wide width-literal audit, hot-path branch budget. The marquee
  "where are my engine's perf/layout risks" surface.
- [ ] **graph navigation**: fluid walk of consumers ↔ callers ↔ uses ↔ contains with breadcrumbs +
  pin-and-compare (the panel's history is the seed).

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
  - *Runtime* (live telemetry from the running engine): per-core latency / fills / state → the **monitoring
    plane** (custom UI), NOT nvim. The nvim cockpit can *read* these back for the inspected symbol (via the
    monitoring plane, keyed by symbol) — but it never hosts the live dashboard itself.

## Priority

Near-term, highest-leverage: (1) **diagnostics integration** (ambient, hooks the whole ecosystem),
(2) **aggregate dashboard** (the exploratory marquee), (3) **visual-selection analyze**. The toolchain /
measurement pieces are the big bets once the plugin is fleshed out.

Guardrail: the plugin exists to serve *building the engine*. Keep it in that ratio — don't let the cockpit
become the mission.
