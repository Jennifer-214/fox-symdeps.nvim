-- fox-symdeps.nvim — symbol-intelligence HUD for C++.
-- setup(opts):
--   key     = "<leader>dd"                                            -- trigger for the symbol HUD
--   palette = { header, badge, title, border, selection, winblend }  -- theme cohesion
--   template_args = { F = "64" }                                      -- canonical args for dependent template params
local M = {}

local defaults = {
  key = "<leader>dd",
  palette = {},
  pack_dirs = {}, -- W14: dirs of private provider modules to auto-load (e.g. the trader tool-pack)
  doc_dirs = {},  -- extra dirs the `n` notes lens greps for symbol mentions (design specs / a workspace repo)
  auto_panel = false, -- cockpit mode: auto-dock the tracking panel on C++ buffers (min-width gated)
  ambient_pos = "right_align", -- ambient size-chip placement: "right_align" (clear of git-blame eol text) | "eol"
  foxtag_bin = nil, -- path to the `foxtag` fact-core binary. Resolution: this opt → PATH → a
                    -- script-relative guess (last resort). Set it when the plugin is installed
                    -- remotely (lazy.nvim clones it far from any sibling tools/foxtag/ tree), since
                    -- the tag node model is DERIVED from `foxtag grammar --json` (E.1.2.B 0.3).
  template_args = {}, -- map: template param NAME → literal arg (strings). Lets the sizeof probe
                      -- instantiate a DEPENDENT spelling — `ExecutionCore<F>` hovered via a variable
                      -- inside a template body, or a primary template's injected-class-name — at the
                      -- repo's canonical instantiation. The HUD labels what was assumed (@ F=64).
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

-- open the float HUD on the unit at the cursor + fire the fetch. Public so
-- browse/roam can reuse it after landing the cursor on a picked symbol.
-- Cursor-ANYWHERE (north-star §6, the tagcursor slice): resolution routes through
-- tagcontext.resolve() — on-symbol stays the fast path, but a cursor anywhere between a
-- unit's opener and [END_X] resolves via the enclosing block + its declared symbol. Same
-- heal branch as :FoxSymdepsDerived: a missing foxtag is a one-keypress fix, not user error.
function M.inspect_cursor()
  local ctx = require("fox-symdeps.tagcontext").resolve()
  if not ctx then
    if not require("fox-symdeps.nodemodel").available() then
      return require("fox-symdeps.nodemodel").heal(function() M.inspect_cursor() end)
    end
    return vim.notify("fox-symdeps · put the cursor in a tagged unit (or on a symbol)", vim.log.levels.INFO)
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
  -- Tag layer (E.1.2.B 0.3): warm the foxtag-derived node model (silent — a missing foxtag surfaces
  -- at point of use with a one-keypress heal, never as boot-time noise), then light up the REAL tag
  -- adapter through the single install seam. Until this call the adapter was dormant (null no-ops).
  require("fox-symdeps.nodemodel").setup(M.config)
  require("fox-symdeps.tagadapter").install(require("fox-symdeps.tag_grammar_adapter"))
  -- Ambient enclosing-unit layer (0.4 tagcursor slice): debounced cursor-follow → vim.b.fox_unit
  -- + User FoxUnitChanged + :FoxUnit. Passive publisher only — consumers opt in; nothing else
  -- changes behavior by its presence. `tagcursor = { debounce_ms = N }` in setup opts to tune.
  require("fox-symdeps.tagcursor").enable(M.config.tagcursor or {})
  require("fox-symdeps.ambient").pos = M.config.ambient_pos or "right_align"
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
  vim.api.nvim_create_user_command("FoxSymdepsDerived", function(cmdopts)
    local ctx = require("fox-symdeps.tagcontext").resolve() -- cursor ANYWHERE in a tagged unit (or on the symbol)
    if not ctx then
      -- Distinguish "no tagged unit here" from "the node model isn't available" — the latter is
      -- fixable in one keypress (build foxtag → refresh → retry this command), not user error.
      if not require("fox-symdeps.nodemodel").available() then
        return require("fox-symdeps.nodemodel").heal(function() vim.cmd(cmdopts.bang and "FoxSymdepsDerived!" or "FoxSymdepsDerived") end)
      end
      return vim.notify("fox-symdeps · put the cursor in a tagged unit (or on a symbol)", vim.log.levels.INFO)
    end
    local write = cmdopts.bang -- `:FoxSymdepsDerived!` GENERATES the block into the source
    local buf, row0 = vim.api.nvim_get_current_buf(), vim.api.nvim_win_get_cursor(0)[1] - 1
    vim.notify(write and "fox-symdeps · writing derived facts…" or "fox-symdeps · gathering derived facts…", vim.log.levels.INFO)
    require("fox-symdeps.facts").derived(ctx, function(f)
      if write then -- GENERATOR: write the STABLE facts ([UPSTREAM]/[CONSUMERS]) into the [DERIVED] block
        local n = require("fox-symdeps.tagwriter").write(buf, row0, f)
        if n == nil then return vim.notify("fox-symdeps · no [DERIVED] block below the cursor's unit — convert it first", vim.log.levels.WARN) end
        if n == 0 then return vim.notify("fox-symdeps · no stable facts to write (deps/consumers empty)", vim.log.levels.INFO) end
        pcall(function() vim.api.nvim_buf_call(buf, function() vim.cmd("silent keepjumps write") end) end) -- persist: disk == buffer (safe — .clang-format is DisableFormat)
        return vim.notify(("fox-symdeps · wrote %d [DERIVED] line(s) for %s + saved (instr/simd stay live-preview)"):format(n, ctx.symbol), vim.log.levels.INFO)
      end
      local lines = require("fox-symdeps.tagadapter").format_derived(f) -- real adapter → the [DERIVED] block
      if lines and #lines > 0 then return vim.notify(table.concat(lines, "\n"), vim.log.levels.INFO) end
      vim.notify(("fox-symdeps · %s%s%s · deps: %s · consumers: %s"):format(f.symbol, -- null adapter → raw facts
        f.data_size and (" · " .. f.data_size .. " instr") or "",
        f.simd ~= nil and (" · " .. (f.simd and "simd" or "scalar")) or "",
        #f.dep_chain > 0 and table.concat(f.dep_chain, ", ") or "—",
        #f.consumers > 0 and table.concat(f.consumers, ", ") or "—"), vim.log.levels.INFO)
    end)
  end, { bang = true, desc = "fox-symdeps: derived facts (! writes the stable [DERIVED] block in place)" })
  -- Context action menu — the tag [TYPE] under the cursor filters which ops are offered (D-328).
  vim.api.nvim_create_user_command("FoxSymdepsMenu", function()
    local buf = vim.api.nvim_get_current_buf()
    local blk, err = require("fox-symdeps.tagcontext").enclosing_block(buf, vim.api.nvim_win_get_cursor(0)[1] - 1)
    if err == "no-model" then -- foxtag unavailable → one-keypress heal, then re-open the menu
      return require("fox-symdeps.nodemodel").heal(function() vim.cmd("FoxSymdepsMenu") end)
    end
    local acts = require("fox-symdeps.actions").for_type(blk and blk.type:lower() or "")
    local anchor = require("fox-symdeps.panel").win() or require("fox-symdeps.followcard").win()
    require("fox-symdeps.menu").open(acts, {
      title = blk and ("%s %s"):format(blk.type, blk.name) or "fox-symdeps",
      palette = M.config.palette,
      anchor_win = anchor, -- dock to the open board/follow card (sub-panel); cursor otherwise
    })
  end, { desc = "fox-symdeps: context action menu (ops filtered by the tag [TYPE])" })
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
    require("fox-symdeps.panel").add(M.config.palette)
  end, { desc = "fox-symdeps: board — ADD this unit's card (accumulates; s compares; q closes)" })
  vim.keymap.set("n", "<leader>df", function()
    require("fox-symdeps.followcard").toggle(M.config.palette)
  end, { desc = "fox-symdeps: follow card (auto-follows the enclosing unit)" })
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
  vim.keymap.set("n", "<leader>dm", function() vim.cmd("FoxSymdepsMenu") end, { desc = "fox-symdeps: action menu (context-filtered by tag [TYPE])" })
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
