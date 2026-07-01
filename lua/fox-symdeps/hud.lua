-- The calm float HUD — a collapsible picker over the symbol's layout + a role→file→function
-- consumer tree. j/k select · l/h expand/collapse · <CR> opens a branch or jumps a leaf · q closes.
-- The text cursor is hidden so it reads as a menu, not a buffer. Async-filled.
local M = {}
local NS = vim.api.nvim_create_namespace("fox_symdeps_hud")
local SPIN = { "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" }

-- arithmetic cost at a native scalar width (confirmed vs clang -S: 128-bit add = addq+adcq;
-- 64-bit = single add/lea). Shown in Layout so it updates live as you resize a field.
local WIDTH_OPS = {
  [4] = "→ 32-bit ALU · add/cmp/mul = 1 insn each",
  [8] = "→ 64-bit ALU · add/cmp/mul = 1 insn each",
  [16] = "→ 128-bit · add = add+adc (2) · cmp = cmp+sbb (2) · mul = umul128",
}

local Hud = {}
Hud.__index = Hud

-- W17: turn the HUD's jumpable rows into quickfix items, BROKEN ones first (so :cnext walks the
-- breaks first). Pure — takes the rendered items, returns a quickfix-list table.
local function build_qf(items)
  local broken, rest = {}, {}
  for _, it in ipairs(items or {}) do
    if it.loc then
      local qi = { filename = it.loc.file, lnum = it.loc.line, col = (it.loc.col or 0) + 1, text = it.qftext or "" }
      table.insert(it.broken and broken or rest, qi)
    end
  end
  vim.list_extend(broken, rest)
  return broken
end
M._build_qf = build_qf

function M.open(ctx, palette, opts)
  opts = opts or {}
  local self = setmetatable({
    ctx = ctx,
    palette = palette or {},
    mode = opts.mode or "float",
    on_close = opts.on_close,
    origin = vim.api.nvim_get_current_win(),
    layout = { state = "loading" },
    fields = { state = "loading", items = {} },
    consumers = { state = "loading", tree = {} },
    trace = { state = "skip", items = {} }, -- transitive call trace (functions only)
    sections = {}, -- provider-contributed extra sections: { {key, label, state, tree} }
    items = {}, -- selectable rows: { bufline, kind, node? (branch), loc? (leaf) }
    sel = 1,
    spin = 1,
    closed = false,
  }, Hud)
  self:_window()
  if self.mode == "float" then self:_hide_cursor() end
  self:_spinner()
  self:render()
  return self
end

function Hud:set_layout(data, state)
  self.layout = { state = state, data = data }
  self:render() -- panel winbar is the tab bar, owned by panel.lua (set_tabbar)
end

function Hud:set_consumers(tree, state)
  self.consumers = { state = state, tree = tree or {} }
  self:render()
end

function Hud:set_fields(items, state)
  self.fields = { state = state, items = items or {} }
  self:render()
end

-- Upsert a provider-contributed section (by key, so a provider can update its own section).
function Hud:set_section(key, label, tree, state)
  for _, s in ipairs(self.sections) do
    if s.key == key then
      s.label, s.tree, s.state = label, tree or {}, state
      self:render()
      return
    end
  end
  self.sections[#self.sections + 1] = { key = key, label = label, tree = tree or {}, state = state }
  self:render()
end

function Hud:set_trace(items, state)
  self.trace = { state = state, items = items or {} }
  self:render()
end

-- Register an on-demand action key (e.g. a provider's break-check on 'b'). Buffer-local so it
-- only lives while the HUD is open; providers call this once their section is ready.
function Hud:map_action(key, fn)
  if self.closed or not self.buf or not vim.api.nvim_buf_is_valid(self.buf) then return end
  vim.keymap.set("n", key, function() fn() end, { buffer = self.buf, nowait = true, silent = true })
end

-- Re-track (panel): point at a new symbol, reset sections to loading, re-render.
function Hud:reset(ctx)
  self.ctx = ctx
  self.layout = { state = "loading" }
  self.fields = { state = "loading", items = {} }
  self.consumers = { state = "loading", tree = {} }
  self.trace = { state = "skip", items = {} }
  self.sections = {}
  self.sel = 1
  self:render() -- panel winbar (tab bar) is re-set by panel.lua after reset
end

function Hud:_window()
  self.buf = vim.api.nvim_create_buf(false, true)
  vim.bo[self.buf].bufhidden = "wipe"
  vim.bo[self.buf].filetype = "fox-symdeps"
  if self.mode == "panel" then
    self.win = vim.api.nvim_open_win(self.buf, true, { split = "right", width = 52, style = "minimal" })
    vim.wo[self.win].winbar = "%#FoxSymdepsTitle# " .. self.ctx.symbol .. " %*"
    vim.wo[self.win].winfixwidth = true
  else
    self.win = vim.api.nvim_open_win(self.buf, true, {
      relative = "cursor",
      row = 1,
      col = 2,
      width = 72,
      height = 22,
      style = "minimal",
      border = "rounded",
      title = { { " " .. self.ctx.symbol .. " ", "FoxSymdepsTitle" } },
      title_pos = "center",
    })
  end
  vim.wo[self.win].winblend = self.palette.winblend or 0
  vim.wo[self.win].cursorline = false
  vim.wo[self.win].wrap = false
  vim.wo[self.win].winhighlight =
    "Normal:FoxSymdepsNormal,FloatBorder:FoxSymdepsBorder,FloatTitle:FoxSymdepsTitle"

  local function map(lhs, fn)
    vim.keymap.set("n", lhs, fn, { buffer = self.buf, nowait = true, silent = true })
  end
  map("j", function() self:_move(1) end)
  map("k", function() self:_move(-1) end)
  map("<Down>", function() self:_move(1) end)
  map("<Up>", function() self:_move(-1) end)
  map("<C-d>", function() self:_page(1) end)
  map("<C-u>", function() self:_page(-1) end)
  map("<CR>", function() self:_activate() end)
  map("l", function() self:_activate() end) -- leaf = jump, branch = expand
  map("<Right>", function() self:_activate() end)
  map("h", function() self:_set_collapsed(true) end)
  map("<Left>", function() self:_set_collapsed(true) end)
  map("q", function() self:close() end)
  map("<Esc>", function() self:close() end)
  map("Q", function() self:_to_quickfix() end)
  map("y", function() self:_yank() end)
  map("w", function() self:_width_lits() end)
  map("a", function() self:_asm() end)
  map("/", function() self:_filter() end)
  map("?", function()
    vim.notify("fox-symdeps · j/k · C-d/C-u page · l/h fold · <CR> jump · / filter · b break-check · w width-lits · a asm-diff · Q quickfix · y yank · q close",
      vim.log.levels.INFO)
  end)
  for _, k in ipairs({ "i", "o", "x", "dd", "p" }) do
    map(k, function() end)
  end
  if self.mode == "float" then
    vim.api.nvim_create_autocmd("BufLeave", {
      buffer = self.buf,
      once = true,
      callback = function() self:close() end,
    })
  end
end

function Hud:_hide_cursor()
  if not (vim.o.guicursor or ""):find("FoxSymdepsHiddenCursor", 1, true) then
    self.saved_guicursor = vim.o.guicursor
  end
  pcall(function()
    vim.api.nvim_set_hl(0, "FoxSymdepsHiddenCursor", { blend = 100 })
    vim.o.guicursor = "a:FoxSymdepsHiddenCursor"
  end)
end

function Hud:_move(dir)
  if #self.items == 0 then return end
  self.sel = math.max(1, math.min(#self.items, self.sel + dir))
  self:render()
end

-- <C-d>/<C-u>: jump the selection by ~half a window height (fast nav through long lists).
function Hud:_page(dir)
  local h = (self.win and vim.api.nvim_win_is_valid(self.win)) and vim.api.nvim_win_get_height(self.win) or 20
  self:_move(dir * math.max(1, math.floor(h / 2)))
end

function Hud:_spinner()
  self.timer = vim.uv.new_timer()
  self.timer:start(80, 80, vim.schedule_wrap(function()
    if self.closed then return end
    self.spin = (self.spin % #SPIN) + 1
    if self.layout.state == "loading" or self.consumers.state == "loading"
      or (self.fields and self.fields.state == "loading")
      or (self.trace and self.trace.state == "loading") then
      self:render()
    end
  end))
end

-- Layout detail lines: size/align + cache-line span/slack + density (per 64 B line) + vector
-- register fit (XMM/YMM/ZMM) — the readouts that matter for hot-path packing / SWAR.
function Hud:_layout_lines()
  local d = self.layout
  if d.state == "loading" then return { SPIN[self.spin] .. " sizing…" } end
  if d.state == "no_client" then return { "clangd not attached" } end
  if d.state == "ok" and d.data and d.data.is_template then
    return { "template — put cursor on a concrete Foo<N> use for its size" }
  end
  if d.state ~= "ok" or not d.data or not d.data.size then return { "layout unavailable" } end
  local sz, al = d.data.size, d.data.align or 0
  local out = { ("size %d B · align %d%s"):format(sz, al, d.data.computed and "  (sizeof probe)" or "") }
  if sz <= 64 then
    local reg = sz <= 16 and "XMM 128b" or (sz <= 32 and "YMM 256b" or "ZMM 512b")
    out[#out + 1] = ("fits 1 cache line · %d B slack · %d/line · → %s"):format(64 - sz, math.floor(64 / sz), reg)
  else
    local lines = math.ceil(sz / 64)
    out[#out + 1] = ("spans %d cache lines · %d B free in line %d"):format(lines, lines * 64 - sz, lines)
  end
  if WIDTH_OPS[sz] then out[#out + 1] = WIDTH_OPS[sz] end
  return out
end

-- / prompt: filter the consumer tree by function/file/line (empty clears).
function Hud:_filter()
  local q = vim.fn.input("fox-symdeps /")
  self.filter = (q ~= "" and q:lower()) or nil
  self.sel = 1
  self:render()
end

-- The tree to render: full, or (when /filter is active) only matching roles/files/entries,
-- force-expanded so matches are visible.
function Hud:_visible_tree()
  local tree = self.consumers.tree or {}
  if not self.filter then return tree end
  local q, home, out = self.filter, vim.fn.getcwd(), {}
  for _, role in ipairs(tree) do
    local files = {}
    for _, file in ipairs(role.files) do
      local rel = file.file:gsub("^" .. vim.pesc(home) .. "/", "")
      local matched = {}
      for _, e in ipairs(file.entries) do
        if (((e.scope or "") .. " " .. rel .. " " .. e.line):lower()):find(q, 1, true) then
          matched[#matched + 1] = e
        end
      end
      if #matched > 0 then
        files[#files + 1] = { file = file.file, entries = matched, count = #matched, collapsed = false }
      end
    end
    if #files > 0 then
      local cnt = 0
      for _, f in ipairs(files) do cnt = cnt + f.count end
      out[#out + 1] = { label = role.label, role = role.role, files = files, count = cnt, collapsed = false }
    end
  end
  return out
end

function Hud:render()
  if self.closed or not vim.api.nvim_buf_is_valid(self.buf) then return end
  local lines, hls = {}, {}
  self.items = {}
  local function add(text, hl)
    lines[#lines + 1] = text
    if hl then hls[#lines] = hl end
    return #lines
  end
  local function add_branch(text, kind, node, hl)
    self.items[#self.items + 1] = { bufline = add(text, hl), kind = kind, node = node }
  end
  local function add_leaf(text, loc, hl, broken)
    self.items[#self.items + 1] =
      { bufline = add(text, hl), kind = "entry", loc = loc, broken = broken, qftext = vim.trim(text) }
  end
  local home = vim.fn.getcwd()
  local function render_tree(tree)
    for _, role in ipairs(tree) do
      add_branch(("   %s %s (%d)"):format(role.collapsed and "▸" or "▾", role.label, role.count),
        "role", role, "FoxSymdepsHeader")
      if not role.collapsed then
        for _, file in ipairs(role.files) do
          local rel = file.file:gsub("^" .. vim.pesc(home) .. "/", "")
          add_branch(("     %s %s (%d)"):format(file.collapsed and "▸" or "▾", rel, file.count),
            "file", file, "FoxSymdepsBadge")
          if not file.collapsed then
            for _, e in ipairs(file.entries) do
              local tail = e.scope and (e.scope .. "  :" .. e.line) or (":" .. e.line)
              if e.broken then
                add_leaf("     ⚠   " .. tail, { file = file.file, line = e.line }, "FoxSymdepsAlarm", true)
              else
                add_leaf("         " .. tail, { file = file.file, line = e.line })
              end
            end
          end
        end
      end
    end
  end

  add(" ◆ Layout", "FoxSymdepsHeader")
  for _, l in ipairs(self:_layout_lines()) do add("   " .. l, "FoxSymdepsBadge") end
  add("")

  -- Fields cache-line map (types only)
  local fs = self.fields
  if self.ctx.kind ~= "function" and fs and (fs.state == "loading" or (fs.state == "ok" and #fs.items > 0)) then
    add(" ▪ Fields" .. (fs.state == "ok" and (" (" .. #fs.items .. ")") or ""), "FoxSymdepsHeader")
    if fs.state == "loading" then
      add("   " .. SPIN[self.spin] .. " mapping…", "FoxSymdepsBadge")
    else
      local prev_end = 0
      for _, f in ipairs(fs.items) do
        if f.offset > prev_end then
          add(("       · %d B padding"):format(f.offset - prev_end), "FoxSymdepsBadge")
        end
        local lo = math.floor(f.offset / 64)
        local hi = math.floor((f.offset + math.max(f.size, 1) - 1) / 64)
        local lstr = (lo == hi) and ("L" .. lo) or ("L" .. lo .. "–" .. hi .. "  ⚠ straddles")
        local ty = f.type and (f.type:sub(1, 18)) or ""
        add(("     @%-4d %-12s %3dB %-18s %s"):format(f.offset, f.name, f.size, ty, lstr), "FoxSymdepsBadge")
        prev_end = f.offset + f.size
      end
    end
    add("")
  end

  -- Visual byte-map (types only): fields drawn on 64B cache lines. Gated to a wide window (64-col
  -- rows don't fit the narrow panel); a straddling field turns the header RED. (W26)
  if self.ctx.kind ~= "function" and fs and fs.state == "ok" and #fs.items > 0
    and self.layout.state == "ok" and self.layout.data and self.layout.data.size
    and vim.api.nvim_win_is_valid(self.win) and vim.api.nvim_win_get_width(self.win) >= 69 then
    local bm = require("fox-symdeps.bytemap").render(fs.items, self.layout.data.size)
    add(" ▦ Byte map" .. (bm.straddle and "  ⚠ straddles a cache line" or ""),
      bm.straddle and "FoxSymdepsAlarm" or "FoxSymdepsHeader")
    for _, l in ipairs(bm.lines) do add("   " .. l, "FoxSymdepsBadge") end
    add("")
  end

  -- Consumers: collapsible role → file → function tree (+ optional /filter)
  local c = self.consumers
  local vtree = self:_visible_tree()
  local total = 0
  for _, role in ipairs(vtree) do total = total + role.count end
  local count = c.state == "ok" and total or nil
  local chdr = " ◇ Consumers" .. (count and (" (" .. count .. ")") or "")
  if self.filter then chdr = chdr .. "  /" .. self.filter end
  add(chdr, "FoxSymdepsHeader")
  if c.state == "loading" then
    add("   " .. SPIN[self.spin] .. " finding…", "FoxSymdepsBadge")
  elseif c.state == "no_client" then
    add("   clangd not attached", "FoxSymdepsBadge")
  elseif not count or count == 0 then
    add(self.filter and ("   no match for /" .. self.filter) or "   none", "FoxSymdepsBadge")
  else
    render_tree(vtree)
  end

  -- Call trace (functions only): transitive callers, indented by depth
  local tr = self.trace
  if self.ctx.kind == "function" and tr and (tr.state == "loading" or (tr.state == "ok" and #tr.items > 0)) then
    add("")
    add(" ↪ Call trace" .. (tr.state == "ok" and (" (" .. #tr.items .. ")") or ""), "FoxSymdepsHeader")
    if tr.state == "loading" then
      add("   " .. SPIN[self.spin] .. " walking…", "FoxSymdepsBadge")
    else
      for _, it in ipairs(tr.items) do
        add_leaf(("   %s%s  :%d"):format(("  "):rep(it.depth), it.name, it.line), { file = it.file, line = it.line })
      end
    end
  end

  -- Provider sections (e.g. the trader's "⚠ Byte-layout blast radius")
  for _, sec in ipairs(self.sections or {}) do
    if sec.state == "loading" or (sec.state == "ok" and #sec.tree > 0) then
      add("")
      local scount = 0
      for _, role in ipairs(sec.tree) do scount = scount + (role.count or 0) end
      add(" " .. sec.label .. (sec.state == "ok" and (" (" .. scount .. ")") or ""), "FoxSymdepsHeader")
      if sec.state == "loading" then
        add("   " .. SPIN[self.spin] .. " analyzing…", "FoxSymdepsBadge")
      else
        render_tree(sec.tree)
      end
    end
  end

  self.sel = math.max(1, math.min(math.max(#self.items, 1), self.sel))

  vim.bo[self.buf].modifiable = true
  vim.api.nvim_buf_set_lines(self.buf, 0, -1, false, lines)
  vim.bo[self.buf].modifiable = false
  vim.api.nvim_buf_clear_namespace(self.buf, NS, 0, -1)
  for ln, hl in pairs(hls) do
    vim.api.nvim_buf_set_extmark(self.buf, NS, ln - 1, 0, { line_hl_group = hl })
  end

  -- selection: a warm bar on the active row, cursor parked there for scroll (cursor hidden)
  if #self.items > 0 then
    local line = self.items[self.sel].bufline
    vim.api.nvim_buf_set_extmark(self.buf, NS, line - 1, 0, { line_hl_group = "FoxSymdepsSelection" })
    if vim.api.nvim_win_is_valid(self.win) then
      pcall(vim.api.nvim_win_set_cursor, self.win, { line, 0 })
    end
  end
end

-- <CR>: toggle a branch (role/file), or jump to a leaf entry.
-- a window to jump into: the origin code window, else any non-panel window
function Hud:_code_win()
  if self.origin and vim.api.nvim_win_is_valid(self.origin) and self.origin ~= self.win then
    return self.origin
  end
  for _, w in ipairs(vim.api.nvim_list_wins()) do
    if w ~= self.win then return w end
  end
  return nil
end

function Hud:_activate()
  local it = self.items[self.sel]
  if not it then return end
  if it.node then
    it.node.collapsed = not it.node.collapsed
    self:render()
  elseif it.loc then
    local target = self:_code_win()
    if self.mode == "float" then self:close() end -- panel stays docked; float dismisses
    if target and vim.api.nvim_win_is_valid(target) then
      vim.api.nvim_set_current_win(target)
    end
    vim.cmd("normal! m`") -- jumplist mark so <C-o> returns
    vim.cmd.edit(vim.fn.fnameescape(it.loc.file))
    pcall(vim.api.nvim_win_set_cursor, 0, { it.loc.line, 0 })
  end
end

-- <C-q>: send every jumpable row to the quickfix list (breaks first) and open it, so you can
-- :cnext through every site that touches the symbol — the actionable blast-walk (W17).
function Hud:_to_quickfix()
  local qf = build_qf(self.items)
  if #qf == 0 then
    return vim.notify("fox-symdeps · nothing to send to quickfix", vim.log.levels.INFO)
  end
  vim.fn.setqflist({}, " ", { title = "fox-symdeps: " .. (self.ctx.symbol or ""), items = qf })
  if self.mode == "float" then self:close() end
  vim.cmd("botright copen")
  vim.notify(("fox-symdeps · %d sites → quickfix (:cnext / :cprev)"):format(#qf), vim.log.levels.INFO)
end

-- y: yank the whole readout to the system clipboard (+ unnamed) — copy the panel as text
-- instead of screenshotting it (sidesteps the big-screenshot copy snag).
function Hud:_yank()
  local text = table.concat(vim.api.nvim_buf_get_lines(self.buf, 0, -1, false), "\n")
  pcall(vim.fn.setreg, "+", text)
  vim.fn.setreg('"', text)
  vim.notify("fox-symdeps · readout yanked to clipboard", vim.log.levels.INFO)
end

-- w: scan the symbol's files for hardcoded width literals (== its size, byte-ish, no sizeof) and
-- send the suspects to quickfix — the break class W18's static_assert check can't catch (W21).
function Hud:_width_lits()
  local size = self.layout and self.layout.data and self.layout.data.size
  if not size then
    return vim.notify("fox-symdeps · size unknown — can't scan width literals", vim.log.levels.INFO)
  end
  local files = {}
  local function collect(tree)
    for _, role in ipairs(tree or {}) do
      for _, fe in ipairs(role.files or {}) do files[#files + 1] = fe.file end
    end
  end
  collect(self.consumers.tree)
  for _, sec in ipairs(self.sections or {}) do collect(sec.tree) end
  local sus = require("fox-symdeps.widthlit").scan(files, size)
  if #sus == 0 then
    return vim.notify(("fox-symdeps · no width-literal suspects for %d B"):format(size), vim.log.levels.INFO)
  end
  local qf = {}
  for _, s in ipairs(sus) do qf[#qf + 1] = { filename = s.file, lnum = s.line, col = 1, text = s.text } end
  vim.fn.setqflist({}, " ", { title = ("fox-symdeps width-literals %dB: %s"):format(size, self.ctx.symbol or ""), items = qf })
  if self.mode == "float" then self:close() end
  vim.cmd("botright copen")
  vim.notify(("fox-symdeps · %d width-literal suspect(s) → quickfix (review — heuristic)"):format(#sus), vim.log.levels.INFO)
end

-- a: asm flag-diff for a FUNCTION under cursor — compile under two flag-sets, show insns/branches/
-- vector side by side (W15). Flag-sets come from asmflags (built-in defaults + your saved picks).
function Hud:_asm()
  if self.ctx.kind ~= "function" then
    return vim.notify("fox-symdeps · asm-diff is for functions (put the cursor on a function)", vim.log.levels.INFO)
  end
  local flags = require("fox-symdeps.asmflags")
  local a, b = flags.pair()
  local bufnr, fn = self.ctx.bufnr, self.ctx.symbol
  vim.notify(("fox-symdeps · asm-diff %s: %s vs %s…"):format(fn, a.name, b.name), vim.log.levels.INFO)
  local asmdiff = require("fox-symdeps.asmdiff")
  local res, rerun = {}, function() self:_asm() end
  local function done()
    if res.a and res.b then require("fox-symdeps.asmview").show(fn, a, b, res.a, res.b, rerun) end
  end
  asmdiff.run(bufnr, fn, a.flags, function(r) res.a = r or {}; done() end)
  asmdiff.run(bufnr, fn, b.flags, function(r) res.b = r or {}; done() end)
end

-- l / h: expand / collapse the selected branch.
function Hud:_set_collapsed(want)
  local it = self.items[self.sel]
  if it and it.node then
    it.node.collapsed = want
    self:render()
  end
end

function Hud:close()
  if self.closed then return end
  self.closed = true
  if self.timer then
    self.timer:stop()
    self.timer:close()
  end
  if self.saved_guicursor then vim.o.guicursor = self.saved_guicursor end
  if self.win and vim.api.nvim_win_is_valid(self.win) then
    vim.api.nvim_win_close(self.win, true)
  end
  if self.on_close then pcall(self.on_close) end
end

return M
