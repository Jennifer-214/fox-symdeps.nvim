-- fox-symdeps.nvim — symbol-intelligence HUD for C++.
-- setup(opts):
--   key     = "<leader>dd"                                            -- trigger for the symbol HUD
--   palette = { header, badge, title, border, selection, winblend }  -- theme cohesion
local M = {}

local defaults = {
  key = "<leader>dd",
  palette = {},
}

-- Fire the async queries for `ctx` and stream results into the HUD/panel `h`. Reusable so the
-- transient float and the persistent panel share one fetch engine.
function M.inspect(ctx, h)
  local clangd = require("fox-symdeps.clangd")
  local neotree = require("fox-symdeps.neotree")
  local classify = require("fox-symdeps.classify")
  require("fox-symdeps.provider").run_all(ctx, h)
  clangd.layout(ctx, function(data, state) h:set_layout(data, state) end)
  if ctx.kind == "function" then
    -- functions: who actually calls it (call hierarchy), not every textual mention
    clangd.callers(ctx, function(items, state)
      if state == "ok" then
        for _, it in ipairs(items) do it.role = "called"; it.scope = it.name end
        h:set_consumers(classify.tree(items), state)
        neotree.set(items)
      else
        h:set_consumers(nil, state)
      end
    end)
  else
    -- types: classify each reference by role + map the byte layout
    clangd.consumers(ctx, function(items, state)
      if state == "ok" then
        h:set_consumers(classify.tree(classify.classify(items)), state)
        neotree.set(items)
      else
        h:set_consumers(nil, state)
      end
    end)
    require("fox-symdeps.layout").fields(ctx, function(items, state) h:set_fields(items, state) end)
  end
end

-- Lighter re-fetch for live-edit: just layout + field map (what changes when you edit a
-- struct's body). Consumers are left intact — an in-struct edit doesn't change who uses it.
function M.refresh_layout(ctx, h)
  require("fox-symdeps.clangd").layout(ctx, function(data, state) h:set_layout(data, state) end)
  if ctx.kind ~= "function" then
    require("fox-symdeps.layout").fields(ctx, function(items, state) h:set_fields(items, state) end)
  end
end

local function trigger()
  local ctx = require("fox-symdeps.context").under_cursor()
  if not ctx then
    return vim.notify("fox-symdeps · no symbol under cursor", vim.log.levels.INFO)
  end
  local neotree = require("fox-symdeps.neotree")
  local h = require("fox-symdeps.hud").open(ctx, M.config.palette, { on_close = function() neotree.clear() end })
  M.inspect(ctx, h)
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
  vim.keymap.set("n", "<leader>dD", function()
    require("fox-symdeps.panel").toggle(M.config.palette)
  end, { desc = "fox-symdeps: live panel (track symbol)" })
  local ok, wk = pcall(require, "which-key")
  if ok and wk.add then
    pcall(wk.add, { { "<leader>d", group = "symdeps" } })
  end
end

return M
