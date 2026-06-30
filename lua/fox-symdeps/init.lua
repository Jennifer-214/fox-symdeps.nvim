-- fox-symdeps.nvim — symbol-intelligence HUD for C++ (v1: clangd-only core).
-- setup(opts):
--   key     = "<leader>dd"           -- trigger for the symbol HUD
--   palette = { header, badge, title, border, winblend }  -- theme cohesion; bg stays transparent
local M = {}

local defaults = {
  key = "<leader>dd",
  palette = {},
}

-- one trigger → context → async clangd(layout, consumers) → HUD. (v1 hardcodes the two sections;
-- the provider/registry abstraction arrives in W2 with the trader provider as the 2nd caller.)
local function trigger()
  local ctx = require("fox-symdeps.context").under_cursor()
  if not ctx then
    return vim.notify("fox-symdeps · no symbol under cursor", vim.log.levels.INFO)
  end
  local clangd = require("fox-symdeps.clangd")
  local neotree = require("fox-symdeps.neotree")
  local h = require("fox-symdeps.hud").open(ctx, M.config.palette, function() neotree.clear() end)
  clangd.layout(ctx, function(data, state) h:set_layout(data, state) end)
  if ctx.kind == "function" then
    -- functions: who actually calls it (call hierarchy), not every textual mention
    clangd.callers(ctx, function(items, state)
      if state == "ok" then
        local classify = require("fox-symdeps.classify")
        for _, it in ipairs(items) do it.role = "called"; it.scope = it.name end
        h:set_consumers(classify.tree(items), state)
        neotree.set(items)
      else
        h:set_consumers(nil, state)
      end
    end)
  else
    -- types: classify each reference by role
    clangd.consumers(ctx, function(items, state)
      if state == "ok" then
        local classify = require("fox-symdeps.classify")
        h:set_consumers(classify.tree(classify.classify(items)), state)
        neotree.set(items)
      else
        h:set_consumers(nil, state)
      end
    end)
    require("fox-symdeps.layout").fields(ctx, function(items, state) h:set_fields(items, state) end)
  end
end

local function set_highlights(p)
  local function hl(name, spec) vim.api.nvim_set_hl(0, name, spec) end
  hl("FoxSymdepsNormal", { bg = "none" }) -- transparent → inherits the terminal's opacity
  hl("FoxSymdepsBorder", { fg = p.border or p.header or "#b8967a", bg = "none" })
  hl("FoxSymdepsTitle", { fg = p.title or p.header or "#e0a0a0", bold = true, bg = "none" })
  hl("FoxSymdepsHeader", { fg = p.header or "#e0a0a0", bold = true })
  hl("FoxSymdepsBadge", { fg = p.badge or p.muted or "#a0907f" })
  hl("FoxSymdepsTreeCount", { fg = p.header or "#e0a0a0", bold = true }) -- neo-tree consumer-count badge
  hl("FoxSymdepsSelection", { bg = p.selection or "#4a3340" })           -- picker selected-row bar (warm)
end

function M.setup(opts)
  M.config = vim.tbl_deep_extend("force", defaults, opts or {})
  set_highlights(M.config.palette)
  -- re-apply on colorscheme change so a theme swap re-themes the HUD
  vim.api.nvim_create_autocmd("ColorScheme", {
    group = vim.api.nvim_create_augroup("FoxSymdeps", { clear = true }),
    callback = function() set_highlights(M.config.palette) end,
  })
  vim.keymap.set("n", M.config.key, trigger, { desc = "fox-symdeps: symbol HUD" })
  local ok, wk = pcall(require, "which-key")
  if ok and wk.add then
    pcall(wk.add, { { "<leader>d", group = "symdeps" } })
  end
end

return M
