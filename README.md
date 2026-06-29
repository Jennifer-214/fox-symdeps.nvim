# fox-symdeps.nvim

A symbol-intelligence HUD for C++. Put the cursor on a symbol, press `<leader>dd`, and a
calm float shows what the compiler actually knows about it: memory **layout** from clangd
(size / alignment / cache-line fit) and the real list of **consumers** (LSP references).

Ground truth from your toolchain — not a guess. C++-only in v1.

## Requirements

- Neovim 0.11+ (developed on 0.12). Uses `vim.lsp.Client:request`, `vim.uv`, `vim.treesitter`.
- `clangd` on `PATH`, attached to the buffer — i.e. a `compile_commands.json` in or above the project.
- Optional: `which-key.nvim` — adds the `<leader>d` group label; harmless if absent.

## Install

lazy.nvim:

```lua
{
  "Jennyfirrr/fox-symdeps.nvim",
  ft = { "c", "cpp" },
  opts = {
    -- key     = "<leader>dd",  -- trigger (default)
    -- palette = { header = "#e0a0a0", badge = "#a0907f", title = "#e0a0a0",
    --             border = "#b8967a", winblend = 0 },
  },
}
```

Local development — use a working checkout when it exists, fall back to the remote on
machines that don't have it (same spec for both, flip nothing):

```lua
-- lazy setup opts:
{ dev = { path = "~/code", fallback = true } }

-- plugin spec:
{ "Jennyfirrr/fox-symdeps.nvim", dev = true, ft = { "c", "cpp" }, opts = { … } }
```

## Usage

- `<leader>dd` — open the HUD for the symbol under the cursor.
- In the HUD: `j`/`k` scroll · `<CR>` jump to a consumer (drops a jumplist mark, so `<C-o>` returns) · `q`/`<Esc>` close.

Sections:

- **Layout** — size, alignment, and cache-line fit, parsed from clangd hover. Reads
  `unavailable` calmly when clangd has nothing yet; it never throws.
- **Consumers** — files that reference the symbol (LSP references), shown relative to cwd.

## Health

```
:checkhealth fox-symdeps
```

Verifies `clangd` is on `PATH`, a client is attached, and a `compile_commands.json` is
reachable from the cwd.

## Theming

The front-end ships no palette of its own — colors arrive through `opts.palette`, so it
inherits whatever theme passes it tokens. The background stays transparent (it picks up
the terminal's opacity), and highlights re-apply on `ColorScheme` so a theme swap re-themes
the HUD.

## Status

v1 — the portable clangd-only core (Layout + Consumers). Planned: neo-tree consumer-count
decoration, a provider interface for project-specific sections (callers / byte-context /
embedders via external tools), and parser/extractor unit tests.
