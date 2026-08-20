# fox-symdeps.nvim

A symbol-intelligence HUD for C++. Put the cursor in a struct or function, press
`<leader>dd`, and a calm float shows what the compiler actually knows about it — memory
layout, cache-line packing, shipped assembly, and a role-classified map of what depends on it.

Ground truth from your toolchain (clangd + treesitter + the foxtag tag system + the build's own
asm sidecars), not a guess. C++-only.

## What it shows

For the unit at the cursor — anywhere inside it, not only on its name (tag-block resolution):

**Types / structs**
- **Layout** — size · alignment · how it sits across 64 B cache lines · which vector register it fits.
- **Fields** — per-field cache-line map: offset, size, line, straddle flags, padding gaps; a visual
  **byte map** on wide windows; **register-fit** per field (single-`mov` vs shift/mask, both costs shown).
- **Uses / Contains / Includers** — upstream types · recursive composition · who `#include`s the header.
- **Consumers** — references classified by role, each entry resolved to its ENCLOSING tagged unit
  with its `[TAG]` list; filterable by text (`/`) or by tag (`T`).
- **▣ size-budget** — if the struct is cache-residency-gated, its tier.

**Functions**
- **Called by** + **→ Calls** + transitive **Call trace** (real call hierarchy, not textual mentions).
- **SHIPPED asm** — the function in the ACTUAL linked binary (1:1 objdump sidecar, never a re-compile):
  instruction/SIMD/budget chips, ▲ branch-class marks, inline attribution, call-follow, source↔asm sync.
- **Branch tags** (source overlay, shipped basis) — per line: `▲ data-dependent branch` ·
  `△ branch (reg/loop)` · `✓ branchless (cmov)` · the feeding LOAD flagged on its own line; per
  function: a green/red/dim verdict that never greens on nothing.
- **◈ hot-path** — if it's latency-critical, its compiled instruction budget.

**Docs** — the curated `◆ Docs` section lists the `[REFERENCE]` ids that govern the unit; the
doc viewer floats the defining doc beside the code (pin it with `p`).

## Surfaces

One fetch engine, several presentations — all reachable from **the root menu** (`<leader>dm`):

- **Float HUD** — transient, point-at-a-thing (`<leader>dd`).
- **Follow card** — auto-follows the enclosing unit as you move (`<leader>df`); the cockpit docks it.
- **Board** — persistent, multi-card, explicit-add (`<leader>dD` ADDS a card; it accumulates,
  never replaces); side-by-side **compare** from in-board, with the **⋈ Between** section on
  the companion: does one embed the other (which parent cache lines it occupies, straddle
  flagged), and which files include both — the pair's connective tissue, not just two panes.
- **Graph-walk** — in any card, `f` drills into the selected tree entry's unit (breadcrumb in the
  title, `<C-t>` walks back); `L` opens the entry's unit as a board card beside you.
- **Pickers** — browse structs, browse units by `[TAG]`, roam any workspace symbol, TAG ADD from
  the vocab: one fuzzy popup, **browse-first** (j/k immediately, typing is the optional filter).
- **Dashboard** — whole-project risks; **Output log** — every notification, newest first (`<leader>dn`).

## Requirements

- Neovim 0.11+ (developed on 0.12). Uses `vim.lsp`, `vim.treesitter`, `vim.uv`.
- `clangd` on `PATH`, attached to the buffer — a `compile_commands.json` in or above the project.
- For shipped-asm surfaces: the build's asm sidecars (`./build.sh` emits `build*/asm/*.asm`).
- Optional: `which-key.nvim` (group label) and `neo-tree.nvim` (consumer-count tree badges). Both harmless if absent.

## Install

lazy.nvim (private local plugin — point `dir` at the checkout):

```lua
{
  dir = vim.fn.expand("~/code/tick-trader-percore-workspace/tools/plugins/fox-symdeps.nvim"),
  name = "fox-symdeps",
  ft = { "c", "cpp" },
  opts = {
    -- key     = "<leader>dd",  -- trigger (default)
    -- palette = {              -- all optional; sensible warm defaults otherwise
    --   header = "#e0a0a0", title = "#f0c0c0", border = "#b8967a",
    --   badge = "#a0907f", selection = "#4a3340", winblend = 0,
    -- },
  },
}
```

## Usage

**The action menu is the root surface** — `<leader>dm` (or `m` inside any HUD) reaches EVERY
operation: the unit-scoped analyses (type/context-gated) plus the global launchers, with ✎/⚠
write-tier icons. Keybinds are shortcuts into it. The full, always-current key list lives in
`?` inside any surface — it derives from the keymap registry, so this README doesn't
hand-copy it (it had drifted twice before that rule).

- `<leader>dd` — float HUD on the unit at cursor · `<leader>dm` — the action menu
- In a card: `j`/`k` select · `l`/`h` expand/fold · `<CR>` jump (`<C-o>` back) · `f` drill /
  `<C-t>` back · `/` filter · `T` tag-filter · `?` all keys + glossary · `q` close · `m` menu

### Config

`opts.palette` (theme tokens — see Install above) and `opts.template_args` (canonical
instantiations for template units, so size/asm probes resolve `Foo<N>`) — both optional.

## Health

```
:checkhealth fox-symdeps
```

Checks `clangd` on `PATH`, a client attached, a reachable `compile_commands.json`, the doc-viewer
resolver chain, and the optional which-key / neo-tree integrations.

## Testing

```
make test          # or:  bash tests/run.sh
```

Runs the full headless suite (`tests/test_*.lua` — the runner prints the count). Two tiers, by
rule: **pure tests** for the logic, and **`test_*_live.lua` members that drive the REAL path**
(fixture trees on disk, real subprocess spawns, real windows/extmarks) — because a green pure
suite once shipped a dead feature across a subprocess seam nothing crossed. No feature is done
without its live path exercised (see `DOCS/DECISIONS.md` § live-path verification). The runner
puts the cpp treesitter parser on the runtimepath; pure-logic tests run anywhere.

## Theming

The front-end ships no palette of its own — colors arrive through `opts.palette`, so it
inherits whatever theme passes it tokens. The background stays transparent (it picks up the
terminal's opacity), and highlights re-apply on `ColorScheme`.

## Status

Active personal tool, dogfooded daily on an HFT engine. The pillars:

- the clangd + treesitter core (layout, field cache-line map, role-classified consumers)
- the **tag-system integration** — units resolve from `[TYPE]`…`[END_TYPE]` blocks anywhere in
  the body; trees are tag-enriched + tag-filterable; TAG ADD merges vocab; `[REFERENCE]` docs float
- the **shipped-asm truth surface** — 1:1 sidecar cards, branch taxonomy overlay, register-fit
- a persistent **live board** that reflects *external* edits — when another process (e.g. an AI
  in a second window) writes the tracked file, the cascade + break-check re-run and a
  `sizeof` delta alerts (the co-programming loop)
- **byte-layout blast radius** cascade with an auto break-check (what a change broke, cross-file)
- the **graph-walk**: every dependency tree is a browsable graph, drill in / walk back

Extensible: drop a `lenses/*.lua` file that self-registers via `lens.define` — see
`lenses/_TEMPLATE.lua.txt`.
