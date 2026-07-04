-- fox-symdeps.nvim — symbol-intelligence HUD for C++.
-- setup(opts):
--   key     = "<leader>dd"                                            -- trigger for the symbol HUD
--   palette = { header, badge, title, border, selection, winblend }  -- theme cohesion
local M = {}

local defaults = {
  key = "<leader>dd",
  palette = {},
  pack_dirs = {}, -- W14: dirs of private provider modules to auto-load (e.g. the trader tool-pack)
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
    h:set_trace(nil, "loading")
    require("fox-symdeps.trace").incoming(ctx, function(items, state) h:set_trace(items, state) end)
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
    -- W22: recursive composition ("what this struct contains") — deferred so it never blocks the open
    vim.schedule(function()
      local root = vim.fs.root(ctx.file, { ".git", "compile_commands.json" }) or vim.fn.fnamemodify(ctx.file, ":h")
      local ok, tree = pcall(require("fox-symdeps.compose").tree, ctx.symbol, root, 2)
      if ok and tree and not h.closed then h:set_composition(tree) end
    end)
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

-- W13 use-lens: project the symbol-under-cursor's uses onto the source as eol role tags.
local function toggle_lens()
  local lens = require("fox-symdeps.highlight")
  if lens.active() then
    lens.clear()
    return vim.notify("fox-symdeps · use-lens off", vim.log.levels.INFO)
  end
  local ctx = require("fox-symdeps.context").under_cursor()
  if not ctx then
    return vim.notify("fox-symdeps · no symbol under cursor", vim.log.levels.INFO)
  end
  require("fox-symdeps.clangd").consumers(ctx, function(items, state)
    if state ~= "ok" or not items or #items == 0 then
      return vim.notify("fox-symdeps · no uses (clangd " .. tostring(state) .. ")", vim.log.levels.INFO)
    end
    local n
    if ctx.kind == "function" then
      for _, it in ipairs(items) do it.role = "called" end
      n = lens.show(items)
    else
      n = lens.show(require("fox-symdeps.classify").classify(items))
    end
    vim.notify(("fox-symdeps · use-lens on · %d uses · ]u/[u to hop"):format(n), vim.log.levels.INFO)
  end)
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
  hl("FoxSymdepsAlarm", { fg = p.alarm or "#e06c75", bold = true })       -- RED — reserved for breaks/straddle/danger only
  hl("FoxSymdepsLensTag", { fg = p.badge or p.muted or "#a0907f", italic = true }) -- calm in-code use tag (W13)
end

function M.setup(opts)
  M.config = vim.tbl_deep_extend("force", defaults, opts or {})
  set_highlights(M.config.palette)
  -- Load built-in lenses (lua/fox-symdeps/lenses/*.lua) plus any user pack_dirs (W14) through the
  -- pack host, so :FoxSymdepsReload hot-reloads them all. Built-in lenses self-gate, so loading is
  -- cheap even off-topic. dofile'd fresh per (re)load; provider.clear() runs first → no double-register.
  local lenses_dir = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":h") .. "/lenses"
  require("fox-symdeps.pack").setup(vim.list_extend({ lenses_dir }, M.config.pack_dirs))
  vim.api.nvim_create_user_command("FoxSymdepsReload", function()
    local n = require("fox-symdeps.pack").reload()
    vim.notify(("fox-symdeps · reloaded %d provider(s)"):format(n), vim.log.levels.INFO)
  end, { desc = "fox-symdeps: re-scan tool-pack dirs" })
  vim.api.nvim_create_user_command("FoxSymdepsAsmFlags", function()
    require("fox-symdeps.asmflags").choose()
  end, { desc = "fox-symdeps: pick / add asm flag-sets (auto-saved)" })
  -- re-apply on colorscheme change so a theme swap re-themes the HUD
  vim.api.nvim_create_autocmd("ColorScheme", {
    group = vim.api.nvim_create_augroup("FoxSymdeps", { clear = true }),
    callback = function() set_highlights(M.config.palette) end,
  })
  vim.keymap.set("n", M.config.key, trigger, { desc = "fox-symdeps: symbol HUD" })
  vim.keymap.set("n", "<leader>dD", function()
    require("fox-symdeps.panel").toggle(M.config.palette)
  end, { desc = "fox-symdeps: live panel (track symbol)" })
  vim.keymap.set("n", "<leader>dS", function()
    require("fox-symdeps.browse").browse(M.config.palette)
  end, { desc = "fox-symdeps: browse structs" })
  vim.keymap.set("n", "<leader>du", toggle_lens, { desc = "fox-symdeps: use-lens (in-code tags)" })
  vim.keymap.set("n", "]u", function() require("fox-symdeps.highlight").next() end, { desc = "fox-symdeps: next use" })
  vim.keymap.set("n", "[u", function() require("fox-symdeps.highlight").prev() end, { desc = "fox-symdeps: prev use" })
  local ok, wk = pcall(require, "which-key")
  if ok and wk.add then
    pcall(wk.add, { { "<leader>d", group = "symdeps" } })
  end
end

return M
