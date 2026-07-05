-- fox-symdeps.nvim — symbol-intelligence HUD for C++.
-- setup(opts):
--   key     = "<leader>dd"                                            -- trigger for the symbol HUD
--   palette = { header, badge, title, border, selection, winblend }  -- theme cohesion
local M = {}

local defaults = {
  key = "<leader>dd",
  palette = {},
  pack_dirs = {}, -- W14: dirs of private provider modules to auto-load (e.g. the trader tool-pack)
  doc_dirs = {},  -- extra dirs the `n` notes lens greps for symbol mentions (design specs / a workspace repo)
  auto_panel = false, -- cockpit mode: auto-dock the tracking panel on C++ buffers (min-width gated)
}

-- callees {name,file,line} → a one-role "Calls" tree for the HUD (file-grouped, jumpable).
local function calls_tree(items)
  local byfile, order = {}, {}
  for _, it in ipairs(items) do
    if not byfile[it.file] then byfile[it.file] = { file = it.file, entries = {} }; order[#order + 1] = it.file end
    table.insert(byfile[it.file].entries, { line = it.line, scope = it.name })
  end
  local files, count = {}, 0
  for _, f in ipairs(order) do
    local fe = byfile[f]
    fe.count = #fe.entries; fe.collapsed = fe.count > 5; count = count + fe.count; files[#files + 1] = fe
  end
  return { { label = "Calls", role = "calls", count = count, collapsed = false, files = files } }
end

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
    -- Calls: the outbound direction (what this function calls), mirror of "Called by"
    h:set_calls(nil, "loading")
    clangd.callees(ctx, function(items, state)
      if state == "ok" and items and #items > 0 then h:set_calls(calls_tree(items), "ok") else h:set_calls(nil, state) end
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
    require("fox-symdeps.layout").fields(ctx, function(items, state)
      h:set_fields(items, state)
      if state == "ok" then require("fox-symdeps.diagnostics").struct_layout(ctx, items) end
    end)
    -- W22: recursive composition ("what this struct contains") — deferred so it never blocks the open
    vim.schedule(function()
      local root = vim.fs.root(ctx.file, { ".git", "compile_commands.json" }) or vim.fn.fnamemodify(ctx.file, ":h")
      local compose = require("fox-symdeps.compose")
      local ok, tree = pcall(compose.tree, ctx.symbol, root, 2)
      if ok and tree and not h.closed then h:set_composition(tree) end
      local oku, uses = pcall(compose.uses, ctx.symbol, root)
      if oku and uses and not h.closed then h:set_uses(uses) end
      -- Includers: files that #include this symbol's header — the breadth Consumers misses because
      -- references don't follow type aliases (`using Money = FixedPoint<…>`). Same grep tier as compose.
      local inc = require("fox-symdeps.includers")
      local oki, incs = pcall(inc.of, ctx.symbol, root)
      if oki and incs and not h.closed then h:set_includers(inc.group_by_dir(incs, root), #incs) end
    end)
  end
end

-- Lighter re-fetch for live-edit: just layout + field map (what changes when you edit a
-- struct's body). Consumers are left intact — an in-struct edit doesn't change who uses it.
function M.refresh_layout(ctx, h)
  require("fox-symdeps.clangd").layout(ctx, function(data, state) h:set_layout(data, state) end)
  if ctx.kind ~= "function" then
    require("fox-symdeps.layout").fields(ctx, function(items, state)
      h:set_fields(items, state)
      if state == "ok" then require("fox-symdeps.diagnostics").struct_layout(ctx, items) end
    end)
  end
end

-- Public query API (the outbound seam other plugins + your statusline ride).
-- status(): the current symbol's chip string for a lualine/heirline component (synchronous, cached).
function M.status()
  return require("fox-symdeps.status").status()
end

-- open the float HUD on the symbol under the cursor + fire the fetch. Public so
-- browse/roam can reuse it after landing the cursor on a picked symbol.
function M.inspect_cursor()
  local ctx = require("fox-symdeps.context").under_cursor()
  if not ctx then
    return vim.notify("fox-symdeps · no symbol under cursor", vim.log.levels.INFO)
  end
  local neotree = require("fox-symdeps.neotree")
  local h = require("fox-symdeps.hud").open(ctx, M.config.palette, { on_close = function() neotree.clear() end })
  M.inspect(ctx, h)
  return h
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
  hl("FoxSymdepsBorder", { fg = p.border or p.header or "#d4985a", bg = "none" })            -- peach
  hl("FoxSymdepsTitle", { fg = p.title or p.header or "#c89eb5", bold = true, bg = "none" }) -- blush
  hl("FoxSymdepsHeader", { fg = p.header or "#d4985a", bold = true })                        -- peach
  hl("FoxSymdepsBadge", { fg = p.badge or p.muted or "#b0a498" })                            -- warm
  hl("FoxSymdepsTreeCount", { fg = p.header or "#d4985a", bold = true })                     -- neo-tree count badge
  hl("FoxSymdepsSelection", { bg = p.selection or "#b5702f", fg = "#1a140e", bold = true })    -- bright peach row bar + dark ink for contrast
  hl("FoxSymdepsWarn", { fg = p.warn or "#d4b483", bold = true })                            -- wheat — caution (▲ straddle)
  hl("FoxSymdepsAlarm", { fg = p.alarm or "#b0603a", bold = true })                          -- terracotta — breaks/danger (not raw red)
  hl("FoxSymdepsOk", { fg = p.ok or "#7aab88" })                                             -- green — clean/ok
  hl("FoxSymdepsLensTag", { fg = p.badge or p.muted or "#b0a498", italic = true })           -- calm in-code use tag
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
  vim.api.nvim_create_user_command("FoxSymdepsCockpit", function()
    require("fox-symdeps.cockpit").toggle()
  end, { desc = "fox-symdeps: toggle cockpit mode (auto-dock panel on C++ buffers)" })
  vim.api.nvim_create_user_command("FoxSymdepsReloadAll", function()
    -- clear every fox-symdeps.* submodule so the next require re-reads from disk (keymaps require
    -- fresh each press). Unlike :FoxSymdepsReload (lenses only) this picks up core edits (hud/clangd/…)
    -- WITHOUT restarting nvim — the fix for "I changed a core file but nvim still runs the old one."
    local n = 0
    for name in pairs(package.loaded) do
      if name:match("^fox%-symdeps%.") and name ~= "fox-symdeps.init" then package.loaded[name] = nil; n = n + 1 end
    end
    set_highlights(M.config.palette)
    vim.notify(("fox-symdeps · reloaded %d module(s) from disk (core + lenses)"):format(n), vim.log.levels.INFO)
  end, { desc = "fox-symdeps: hot-reload ALL modules (core + lenses) from disk" })
  -- re-apply on colorscheme change so a theme swap re-themes the HUD
  vim.api.nvim_create_autocmd("ColorScheme", {
    group = vim.api.nvim_create_augroup("FoxSymdeps", { clear = true }),
    callback = function() set_highlights(M.config.palette) end,
  })
  vim.keymap.set("n", M.config.key, M.inspect_cursor, { desc = "fox-symdeps: symbol HUD" })
  vim.keymap.set("n", "<leader>dD", function()
    require("fox-symdeps.panel").toggle(M.config.palette)
  end, { desc = "fox-symdeps: live panel (track symbol)" })
  vim.keymap.set("n", "<leader>dS", function()
    require("fox-symdeps.browse").browse(M.config.palette)
  end, { desc = "fox-symdeps: browse structs" })
  vim.keymap.set("n", "<leader>dr", function()
    require("fox-symdeps.browse").roam(M.config.palette)
  end, { desc = "fox-symdeps: roam to any symbol (workspace)" })
  vim.keymap.set("n", "<leader>dw", function()
    require("fox-symdeps.dashboard").open(M.config.palette)
  end, { desc = "fox-symdeps: codebase dashboard (whole-project risks)" })
  vim.keymap.set("n", "<leader>dg", function()
    require("fox-symdeps.diagnostics").toggle()
  end, { desc = "fox-symdeps: toggle straddle diagnostics" })
  vim.keymap.set("n", "<leader>dl", function()
    require("fox-symdeps.ambient").toggle()
  end, { desc = "fox-symdeps: ambient layout lens (inline size as you move)" })
  vim.keymap.set("n", "<leader>da", function()
    require("fox-symdeps.assertion").insert()
  end, { desc = "fox-symdeps: lock layout (insert static_assert sizeof/alignof)" })
  vim.keymap.set("n", "<leader>dc", function()
    require("fox-symdeps.status").toggle()
  end, { desc = "fox-symdeps: toggle the always-on size chip (winbar)" })
  vim.keymap.set("n", "<leader>de", function()
    require("fox-symdeps.asmexplorer").open(M.config.palette)
  end, { desc = "fox-symdeps: source↔asm explorer (side-by-side, cursor-synced, 1:1)" })
  vim.keymap.set("n", "<leader>db", function()
    require("fox-symdeps.branchtag").toggle()
  end, { desc = "fox-symdeps: inline data-dependent branch tags (▲, non-destructive)" })
  vim.keymap.set("n", "<leader>du", toggle_lens, { desc = "fox-symdeps: use-lens (in-code tags)" })
  vim.keymap.set("n", "]u", function() require("fox-symdeps.highlight").next() end, { desc = "fox-symdeps: next use" })
  vim.keymap.set("n", "[u", function() require("fox-symdeps.highlight").prev() end, { desc = "fox-symdeps: prev use" })
  -- panel tab flip from ANYWHERE (the panel's own H/L are buffer-local + collide with bufferline;
  -- these are global so you can flip tracked symbols without leaving your code window)
  vim.keymap.set("n", "<leader>d[", function() require("fox-symdeps.panel").switch(-1) end, { desc = "fox-symdeps: panel prev tab" })
  vim.keymap.set("n", "<leader>d]", function() require("fox-symdeps.panel").switch(1) end, { desc = "fox-symdeps: panel next tab" })
  local ok, wk = pcall(require, "which-key")
  if ok and wk.add then
    pcall(wk.add, { { "<leader>d", group = "symdeps" } })
  end
  if M.config.auto_panel then require("fox-symdeps.cockpit").toggle(true) end
end

return M
