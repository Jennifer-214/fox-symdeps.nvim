# fox-symdeps.nvim — REFERENCE (start here)

The single organizing doc: what this is, where it lives, the current state, the vision, the open
threads, and the implementation queue. Written so the operator (or a fresh agent) can pick everything
back up without re-deriving it. Points to the detail docs; doesn't duplicate them. Last synced 2026-07-05.

> Much of the below is **in-progress / operator-owned / not finalized** (esp. the tag scheme). This doc
> captures the *thinking* so it's not lost between sessions — not a spec. When something is decided, it
> graduates into DECISIONS.md (calls) / ROADMAP.md (backlog) / TAG-INTEGRATION.md (tag layer).

## What it is

A **compiled-reality cockpit** for C++ — per-symbol truth (byte-layout, cache-line fit, x86 asm,
data-dependent branches, break-check, consumers/callers, doc mentions) + a codebase-wide dashboard +
a source↔asm explorer, in a warm terminal HUD. It exists to serve building **FoxML_Trader_v2** (a
cache-aware, branchless, fixed-point, per-core trading engine). Its job description: **in-house dev
tooling / a private editor plugin.**

## Where it lives

`~/code/tick-trader-percore-workspace/tools/plugins/fox-symdeps.nvim/` — its **own private repo**
(remote `Jennyfirrr/fox-symdeps.nvim`), **gitignored by the workspace** so it stays independent +
portable + AGPL-clean. nvim loads it via a lazy `dir=` in the Linux_Theme nvim template + live
`~/.config/nvim/init.lua` (isdirectory-guarded). Both those repos are actually **private** (their
CLAUDE.md "Public" is stale). Core edits need **`:FoxSymdepsReloadAll`** (plain `:FoxSymdepsReload`
is lenses-only) or an nvim restart.

## The detail docs (read for specifics)

| Doc                   | What's in it |
| --------------------- | ------------ |
| `DECISIONS.md`        | Architecture + the calls: home, core/pack split, 1:1 real-toolchain, tag scheme, trust discipline. |
| `ROADMAP.md`          | Built-vs-next: the source↔asm explorer section, the six-lens agent-sweep backlog (tiered), every shipped tile/lens. |
| `TAG-INTEGRATION.md`  | The `[TAG]_` comment scheme + the plugin's TWO-WAY role (read + generate/verify `[DERIVED]`) + the scaffolded seam. |
| `LANDMINES.md`        | The swallowed-error bug class + the "never confidently wrong" trust rule. |
| `EDGE-CASES.md`       | The running list of fixed / pending edge cases + inherent caveats — the concrete side of the cohesion discipline. |

## Current state (what's built)

A large 2026-07-05 buildout (see `git log` + ROADMAP for detail):
trust fixes (width-lit / asm-match / sizeprobe) · always-on size chip (winbar + lualine) · cockpit
auto-panel · lock-layout static_assert · ambient size lens · dashboard tiles (widest-headers /
biggest-structs / cache-line-straddlers) · access-density lens · **source↔asm explorer** (1:1
real-toolchain compile, cursor-synced, per-line instruction cost) · inline data-dependent branch tags +
green/yellow/red per-function verdicts · persistent readable HUD errors.

**Architecture:** generic core + `lenses/*.lua` (self-gating, hot-reload) + a trader **pack**
(`pack_dirs`) for convention-specific intelligence. Asm tooling compiles **1:1 with the shipped binary**
(real compiler + flags, only LTO stripped). The **fact seam** (`facts.lua` → `{data_size, simd,
dep_chain, consumers}`) + **null tag-adapter** (`tagadapter.lua`) are scaffolded so the tag layer swaps
in via one `tagadapter.install{}` call.

## The vision (the operator's thinking — the "why we keep building this")

Keep **hands-on manual coding first-class even as AI-assisted coding grows.** The cockpit is the
**see-and-manipulate-compiled-reality layer** that makes generated code *trustworthy* — someone still
has to understand + verify at the level that matters for a cache-aware engine, and that's the durable
skill. So this isn't nostalgia; it's a custom in-house IDE/dev-environment on nvim, built around *this*
codebase's realities. Development of the plugin may increasingly organize around the tag/comment style
as complexity grows (possibly in a dedicated session).

## Open threads (organized, with status)

1. **The `[TAG]_` comment scheme** — machine-readable prefix-category tags + a grouped block-header
   anatomy; the `[DERIVED]` section is auto-generated/CI-checked. **Status:** grammar being designed in a
   parallel session (workspace `DESIGN_SPECS`); **not finalized — the examples so far are illustrative.**
   The plugin side is **deferred**, but the **seam is scaffolded** (facts + null adapter). → TAG-INTEGRATION.md.
   *Key insight:* `[DERIVED]` = exactly what the plugin computes, so the plugin is the **generator +
   drift-verifier**, not just a reader.
2. **Manual-editing features** — codebase-wide **rename-preview** (LSP rename + the consumer tree as the
   preview), **edit-all-consumers** (references → quickfix → scripted substitution), **multi-cursor** (a
   small dedicated plugin). All ride the existing reference graph. Tag-independent.
2a. **Absorb-and-customize** — replace generic plugins with cohesive in-house equivalents where it tightens
   the toolchain and intertwines with the cockpit's analysis. Decided so far: `neotest` → a custom test
   runner (drives the trader's own suite). `vimtex` dropped (no LaTeX). Candidates to weigh: an
   analysis-aware symbol outline (vs `aerial`), the offenders/straddlers as the diagnostics source (vs a
   generic Trouble list). **The operator surfaces which plugins feel redundant/replaceable; the agent's job
   is to articulate the custom version + build it** — the ideas don't need to arrive pre-specified.
3. **Snappiness / polish** — the Uses/Includers/dashboard `rg` calls run **sync** and hitch the HUD on
   open → make them async (biggest felt-jank fix). Also: grep **loud-failure** (rg-absent currently reads
   as a calm "nothing here"). Tag-independent.
4. **Cohesion/usability as a CLASS** — rough edges (misleading messages, type-vs-function-vs-template
   handling, color/glyph consistency, cursor-context assumptions) are a *class*, not one-offs. Discipline:
   a running edge-case list (**EDGE-CASES.md** — the concrete fixed/pending list) + a periodic cohesion
   audit. Headless tests the mechanical; the operator surfaces the interactive/visual layer (documented
   reality, not a gap).
5. **Beyond the editor** — unify with the engine's existing conformance gate (both do asm analysis, on
   divergent compilers); the plugin as editor-side generator, the gate as CI-side verifier, one fact set.
   → ROADMAP "beyond the plugin".

## Implementation queue (by readiness)

- **Ready now (tag-independent):** edit-all-consumers · rename-preview · async-greps · grep loud-failure ·
  the cohesion/usability audit · more dashboard tiles (project-wide width-lits, hot-path budget) ·
  **custom test runner** (replaces `neotest` — drives the trader's OWN suite: `run_all_tests.sh` / the
  conformance gate / a gtest binary, parse the output, surface pass-fail in the cockpit + inline signs).
- **Needs the tag grammar first:** the tags lens (fold/color/jump by category) · `[DESIGN_SPEC]_`
  doc-block linking · the `[DERIVED]` generator + drift-verifier (write the `tagadapter` + `install`).
- **Bigger bets:** the conformance-gate unify · `fox-bench` (measured cycles beside static asm) ·
  AI-explain over the facts (libfox-intel).

## Working discipline

- **Trust > features:** never confidently wrong — conservative/exact reporting, disclose coverage gaps,
  surface compile failures loudly. (LANDMINES.md.)
- **Template-first** for the nvim config: edit the Linux_Theme template, propagate to live.
- **Test what's mechanical** (unit + `nvim -l` e2e probes); the operator surfaces interactive/visual
  edge cases (headless has real limits).
- **`:FoxSymdepsReloadAll`** after core edits — this is why some fixes "didn't take" in a live session.
- **Iterative co-design:** build small, verify, react. No big packaged one-shots.

## Resume checklist (fresh session)

1. Read `DECISIONS.md` + `ROADMAP.md` + `TAG-INTEGRATION.md`.
2. `:FoxSymdepsReloadAll` (or restart nvim) so core edits are live.
3. Check the parallel-session status of the tag grammar before touching anything tag-related.
4. Pick from the queue above; stay tag-independent until the grammar is codified.
