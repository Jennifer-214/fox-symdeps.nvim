# fox-symdeps.nvim

A symbol-intelligence HUD for C++. Put the cursor on a struct or function, press
`<leader>dd`, and a calm float shows what the compiler actually knows about it — memory
layout, cache-line packing, and a role-classified map of what depends on it.

Ground truth from your toolchain (clangd + treesitter), not a guess. C++-only.

## What it shows

For the symbol under the cursor:

- **Layout** (types) — size, alignment, and how it sits across 64 B cache lines: free
  space, how many fit a line, and which vector register it fits (XMM / YMM / ZMM).
- **Fields** (types) — a per-field cache-line map: each field's offset, size, and line,
  flagging fields that **straddle** a line boundary and the padding gaps between them.
- **Consumers** (types) — references **classified by role**: used as input (param),
  returned, embedded (field), instantiated (local), or byte sites (sizeof) — because the
  role is what tells you the *kind* of impact a change has.
- **Called by** (functions) — the real callers, from clangd's call hierarchy, not every
  textual mention.

It's a picker: `j`/`k` snap between entries, the active one highlighted, `<CR>` jumps.

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

Wiring it into a theme that already has a palette (pass your own tokens — local checkout,
or drop `dir` for the published remote):

```lua
{
  dir = vim.fn.expand("~/code/fox-symdeps.nvim"),
  name = "fox-symdeps",
  ft = { "c", "cpp" },
  opts = { palette = { header = P.peach, title = P.blush, border = P.peach,
                       badge = P.warm, selection = P.sel } },
}
```

## Usage

- `<leader>dd` — open the HUD for the symbol under the cursor.
- In the HUD: `j`/`k` select · `<CR>` jump to the selected entry (drops a jumplist mark, so `<C-o>` returns) · `q`/`<Esc>` close.

## Health

```
:checkhealth fox-symdeps
```

Checks `clangd` on `PATH`, a client attached, a reachable `compile_commands.json`, and the
optional which-key / neo-tree integrations.

## Theming

The front-end ships no palette of its own — colors arrive through `opts.palette`, so it
inherits whatever theme passes it tokens. The background stays transparent (it picks up the
terminal's opacity), and highlights re-apply on `ColorScheme`.

## Status

The clangd + treesitter core: enriched layout, the field cache-line map, role-classified
consumers, callers via call hierarchy, neo-tree consumer-count badges, and a picker UI.
Planned: a transitive call trace, a persistent live panel that updates as you edit, and an
optional project-specific provider for richer byte-layout blast-radius analysis.
