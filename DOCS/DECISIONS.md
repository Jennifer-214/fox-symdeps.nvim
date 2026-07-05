# fox-symdeps.nvim — decisions & architecture

The durable record of what this plugin is, how it's organized, and the calls that shaped it. Pairs
with `ROADMAP.md` (what's built / what's next). Written 2026-07-05.

## What it is

A **compiled-reality cockpit** for C++: per-symbol truth (byte-layout, cache-line fit, x86 asm,
data-dependent branches, break-check, consumers/callers, doc mentions) + a codebase-wide dashboard,
surfaced in a warm, terminal-native HUD. It exists to serve building **FoxML_Trader_v2** — a
cache-aware, branchless, fixed-point, per-core trading engine.

## Home & organization (decided 2026-07-05)

- **It is a trader tool, not a general plugin.** It has grown enough trader-specific dependencies
  (the conformance analyzer in `tools/`, `latency_path_budgets.json`, the struct-budget checks, the
  `[TAG]_` comment scheme, the deep_dives anatomy) that generality has no payoff — the operator only
  ever works on this one codebase.
- **Lives in the private workspace, not merged into the engine.** Home: `tick-trader-percore-workspace/
  tools/plugins/fox-symdeps.nvim/`, kept as **its own private git repo** (remote
  `Jennyfirrr/fox-symdeps.nvim`), **gitignored** by the workspace. Rationale:
  - The workspace is the private meta-layer (plans, skills, tools) — the right place for a private
    dev/workflow tool, per the operator's code-vs-workflow privacy split.
  - Staying its own repo keeps it **portable** (copyable elsewhere) and avoids **AGPL entanglement**
    with the engine (FoxML_Trader_v2 is AGPL; it was public before and visibility flips — a nested,
    gitignored, separately-licensed repo can never be swept into the engine's publication).
  - Side-by-side navigation with the analyzer it integrates with, without repo coupling.
- **NOT a mono-repo, NOT in Linux_Theme** (that's an unrelated desktop theme). The seams between
  engine ↔ tool stay explicit (see "Integration contract" in ROADMAP.md).

## Core vs pack

- **Generic core** = the compiled-reality engine (layout, asm, branch classification, straddlers,
  census, explorer). Works on any C++ repo with a `compile_commands.json`.
- **Trader pack** (via `pack_dirs`) = the convention-specific intelligence: the `[TAG]_` vocab reader,
  the conformance-manifest reader, the latency budgets, the deep_dives anatomy. This is where "custom
  for THIS code" lives. The split is now directory-level (both in one repo), not repo-level.

## 1:1 with the real build (decided 2026-07-05)

Asm tooling (explorer, branch tags, branch classification) compiles with the **real toolchain** — the
compiler + flags from `compile_commands.json`, only LTO stripped, `-g` added — so the asm is 1:1 with
the shipped binary, not an isolated clang that diverges in instruction selection. `sizeprobe._flags_for`
returns the compiler for this. (The census stays clang-only — `-fdump-record-layouts` is clang-specific.)
This also begins to heal the divergence with the engine's own g++/objdump conformance gate.

## The `[TAG]_` comment scheme (deferred, operator-owned)

Grep-able prefix-category tags (`[TAG]_LAT_EXEMPT`, `[TAG]_HOT-PATH`, `[DESIGN_SPEC]_<name>`, `[DATE]_`,
`[FUNCTION]_`, `[VERSION]_`) as terse machine directives; block-header anatomy carries the WHY prose.
**Principle: additive + explicit** — a directive must be an explicit tag; prose is never a directive. So
old comments and the legacy manifest keep working (backwards-compat is free), and migration is
opportunistic. The plugin side (a tags lens that folds/colors by category, `[DESIGN_SPEC]_` → doc-block
linking) is **parked until the operator codifies the grammar in the workspace**. Flat, repeatable tokens
— not nested brackets — so `rg '\[TAG\]_X'` works per token.

## Trust discipline (why findings are conservative)

The tool must never be confidently wrong (a false "branchless ✓" or a phantom straddler erodes trust
more than a missed one). So: heuristics that fire on the common case were de-noised (width-lits at
size 4/8), exact-only reporting (the straddler tile reports only fully-resolved structs + discloses the
rest), asm matches the exact qualified function name (not a substring), and compile failures surface
loudly (never masquerade as "no data"). See `DOCS/LANDMINES.md`.

## Session buildout (2026-07-05) — see git log + ROADMAP for detail

Trust fixes (width-lit / asm-match / sizeprobe) · always-on size chip (winbar + lualine) · cockpit
auto-panel · lock-layout static_assert · ambient size lens · dashboard tiles (widest headers · biggest
structs · cache-line straddlers) · cache-line access-density lens · source↔asm explorer (1:1,
cursor-synced) · inline data-dependent branch tags + green/yellow/red per-function verdicts · persistent
readable HUD errors · `:FoxSymdepsReloadAll`.
