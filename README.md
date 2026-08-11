# fox-symdeps.nvim

A symbol-intelligence HUD for C++. Put the cursor on a struct or function, press
`<leader>dd`, and a calm float shows what the compiler actually knows about it — memory
layout, cache-line packing, and a role-classified map of what depends on it.

Ground truth from your toolchain (clangd + treesitter), not a guess. C++-only.

## What it shows

For the symbol under the cursor (`<leader>dd` float or `<leader>dD` panel):

**Types / structs**
- **Layout** — size · alignment · how it sits across 64 B cache lines · which vector register it fits.
- **Fields** — per-field cache-line map: offset, size, line, straddle flags, padding gaps.
- **Uses** — the distinct types this struct depends on (upstream), each jumpable to its definition.
- **Contains** — recursive composition, all the way down.
- **Consumers** — references classified by role: input / returned / embedded / instantiated / byte (sizeof).
- **🎯 size-budget** — if the struct is cache-residency-gated (from a size-budget manifest), its tier.

**Functions**
- **Called by** + **→ Calls** — both call directions (real call hierarchy, not textual mentions).
- **Call trace** — transitive callers.
- **🔥 hot-path** — if it's latency-critical, its compiled instruction budget.

**On-demand** (press the key — discoverable in the footer and in `?`):
- `s` false-sharing · `m` who-writes-this-field · `n` doc mentions (design specs / invariants) ·
  `c` change-impact (what a size change breaks downstream, **loud vs silent**) · `b` break-check ·
  `a` asm flag-diff · `w` width-literal scan · `r` refresh.

**Project-specific** (self-gates on the tool being present): a **byte-layout blast radius** cascade
— embedders + `sizeof`/`fwrite`/`memcmp` enforcement sites via `gen_code_map`, with an auto
break-check that lights up broken `static_assert`s across files when a struct changes.

It's a picker: `j`/`k` snap between entries, `l`/`h` expand/fold, `<CR>` jumps.

## Requirements

- Neovim 0.11+ (developed on 0.12). Uses `vim.lsp`, `vim.treesitter`, `vim.uv`.
- `clangd` on `PATH`, attached to the buffer — a `compile_commands.json` in or above the project.
- Optional: `which-key.nvim` (group label) and `neo-tree.nvim` (consumer-count tree badges). Both harmless if absent.

## Install

lazy.nvim:

```lua
{
  "Jennyfirrr/fox-symdeps.nvim",
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

Wiring it into a theme that already has a palette (pass your own tokens; private local plugin,
so point `dir` at the checkout):

```lua
{
  dir = vim.fn.expand("~/code/tick-trader-percore-workspace/tools/plugins/fox-symdeps.nvim"),
  name = "fox-symdeps",
  ft = { "c", "cpp" },
  opts = { palette = { header = P.peach, title = P.blush, border = P.peach,
                       badge = P.warm, selection = P.sel } },
}
```

## Usage

**The action menu is the root surface** — `<leader>dm` (or `m` inside any HUD) reaches EVERY
operation: the unit-scoped analyses (type/context-gated) plus the global launchers, with ✎/⚠
write-tier icons. Keybinds are shortcuts into it. The full, always-current key list lives in
`?` inside any surface — it derives from the keymap registry, so this README no longer
hand-copies it (it had drifted twice).

- `<leader>dd` — float HUD on the unit at cursor · `<leader>dm` — the action menu
- In the HUD: `j`/`k` select · `l`/`h` expand/fold · `<CR>` jump (`<C-o>` back) · `/` filter ·
  `?` all keys + glossary · `q`/`<Esc>` close · `m` menu

### Config

`opts.palette` (theme tokens — see Install above) — optional. (`opts.doc_dirs` retired with the
`n` mention-sweep lens, 2026-08-10: the curated `◆ Docs` section + `m → Docs` supersede it.)

## Health

```
:checkhealth fox-symdeps
```

Checks `clangd` on `PATH`, a client attached, a reachable `compile_commands.json`, and the
optional which-key / neo-tree integrations.

## Testing

```
make test          # or:  bash tests/run.sh
```

Runs the full headless suite (`tests/test_*.lua`, 21 tests). The runner puts the cpp treesitter
parser on the runtimepath so the treesitter-based tests (classify, compose, write-detection) run —
a bare `nvim --clean` has none. Pure-logic tests (byte-map, false-sharing risk, parsers) need no
parser and run anywhere. A failing test prints its tail; exit code is non-zero on any failure.

## Theming

The front-end ships no palette of its own — colors arrive through `opts.palette`, so it
inherits whatever theme passes it tokens. The background stays transparent (it picks up the
terminal's opacity), and highlights re-apply on `ColorScheme`.

## Status

Active personal tool. On top of the clangd + treesitter core (layout, field cache-line map,
role-classified consumers):

- **Uses** (upstream types), **→ Calls** + **Called by**, transitive **Call trace**
- a persistent **live panel** that reflects *external* edits — when another process (e.g. an AI
  in a second window) writes the tracked file, the cross-file cascade + break-check re-run and a
  `sizeof` delta alerts (the co-programming loop)
- **byte-layout blast radius** cascade with an auto break-check (what a minor change broke, cross-file)
- on-demand lenses: `s` false-sharing · `b` break-check · `m` who-writes · `n` doc-notes
- a **hot-path** instruction-budget readout, a keybind-hint footer, and a `?` help/glossary float

Extensible: drop a `lenses/*.lua` file that self-registers via `lens.define` — see
`lenses/_TEMPLATE.lua.txt`.
