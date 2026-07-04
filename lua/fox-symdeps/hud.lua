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

-- W20: format a size change across a live edit ("watch it shrink"). Pure.
local function size_delta(prev, cur)
  if not prev or not cur or prev == cur then return "" end
  local d = cur - prev
  return ("  (was %d, %s%d)"):format(prev, d > 0 and "+" or "", d)
end
M._size_delta = size_delta

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

-- Orientation-aware panel placement: a wide (landscape) editor gets a right-side
-- strip; a tall/narrow (portrait) editor gets a bottom strip — using the ample
-- vertical space instead of scarce width, which also dodges truncation on a
-- portrait monitor. Pure — unit-tested via M._resolve_placement.
local function resolve_placement(cols, lines)
  cols, lines = cols or 80, math.max(lines or 24, 1)
  if (cols / lines) >= 2.2 then
    return { cfg = { split = "right", width = math.min(60, math.floor(cols * 0.4)) }, fix = "winfixwidth" }
  end
  return { cfg = { split = "below", height = math.max(12, math.floor(lines * 0.4)) }, fix = "winfixheight" }
end
M._resolve_placement = resolve_placement

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
  -- W20: remember the prior size so a live edit shows the delta (watch it shrink)
  if self.layout and self.layout.data and self.layout.data.size then self.prev_size = self.layout.data.size end
  self.layout = { state = state, data = data }
  -- ambient alert: an EXTERNAL edit (Claude in another window) that moved sizeof — notify the delta and
  -- flag a cache-line boundary crossing (the fingerprint / false-sharing concern), even off-panel.
  if self.external_reload and data and data.size and self.prev_size and data.size ~= self.prev_size then
    local d = data.size - self.prev_size
    local crossed = math.floor((self.prev_size - 1) / 64) ~= math.floor((data.size - 1) / 64)
    vim.notify(("fox-symdeps · %s: sizeof %d→%d (%s%d)%s"):format(
      self.ctx.symbol, self.prev_size, data.size, d > 0 and "+" or "", d,
      crossed and "  ▲ crossed a cache line" or ""), vim.log.levels.WARN)
  end
  self.external_reload = nil
  self:render() -- panel winbar is the tab bar, owned by panel.lua (set_tabbar)
end

function Hud:set_consumers(tree, state)
  self.consumers = { state = state, tree = tree or {} }
  self:render()
end

-- Outbound calls (functions): what this function calls — the mirror of "Called by".
function Hud:set_calls(tree, state)
  self.calls = { state = state, tree = tree or {} }
  self:render()
end

function Hud:set_fields(items, state)
  self.fields = { state = state, items = items or {} }
  self:render()
end

-- W22: the recursive composition tree ("what this struct contains, all the way down").
function Hud:set_composition(tree)
  self.composition = tree or {}
  self:render()
end

-- Upstream "Uses": the distinct types this struct depends on (the mirror of Consumers).
function Hud:set_uses(list)
  self.uses = list or {}
  self:render()
end

-- Upsert a provider-contributed section (by key, so a provider can update its own section).
-- tree: a role-tree to render · {} = show only when non-empty (calm) · nil = header-only info line.
function Hud:set_section(key, label, tree, state)
  for _, s in ipairs(self.sections) do
    if s.key == key then
      s.label, s.tree, s.state = label, tree, state
      self:render()
      return
    end
  end
  self.sections[#self.sections + 1] = { key = key, label = label, tree = tree, state = state }
  self:render()
end

function Hud:set_trace(items, state)
  self.trace = { state = state, items = items or {} }
  self:render()
end

-- Register an on-demand action key (e.g. a provider's break-check on 'b'). Buffer-local so it
-- only lives while the HUD is open; providers call this once their section is ready.
function Hud:map_action(key, fn, desc)
  if self.closed or not self.buf or not vim.api.nvim_buf_is_valid(self.buf) then return end
  vim.keymap.set("n", key, function() fn() end, { buffer = self.buf, nowait = true, silent = true })
  if desc then -- register a footer hint (dedupe by key) so lens keys are discoverable inline
    self.action_hints = self.action_hints or {}
    for _, h in ipairs(self.action_hints) do if h.key == key then return end end
    self.action_hints[#self.action_hints + 1] = { key = key, desc = desc }
    self:render()
  end
end

-- Re-track (panel): point at a new symbol, reset sections to loading, re-render.
function Hud:reset(ctx)
  self.ctx = ctx
  self.layout = { state = "loading" }
  self.fields = { state = "loading", items = {} }
  self.consumers = { state = "loading", tree = {} }
  self.trace = { state = "skip", items = {} }
  self.calls = nil -- outbound calls (functions); refilled by set_calls
  self.sections = {}
  self.action_hints = {} -- lens hints re-register when providers re-run on re-inspect
  self.composition = nil -- W22: cleared on struct switch, refilled by set_composition
  self.uses = nil -- upstream deps; cleared on struct switch, refilled by set_uses
  self.sel = 1
  self.prev_size = nil -- W20: don't carry a size delta across a struct switch
  self:render() -- panel winbar (tab bar) is re-set by panel.lua after reset
end

function Hud:_window()
  self.buf = vim.api.nvim_create_buf(false, true)
  vim.bo[self.buf].bufhidden = "wipe"
  vim.bo[self.buf].filetype = "fox-symdeps"
  if self.mode == "panel" then
    -- Orientation-aware: right strip on a wide editor, bottom strip on a
    -- portrait/narrow one (uses the ample vertical space, dodges truncation).
    local place = resolve_placement(vim.o.columns, vim.o.lines)
    place.cfg.style = "minimal"
    self.win = vim.api.nvim_open_win(self.buf, true, place.cfg)
    vim.wo[self.win].winbar = "%#FoxSymdepsTitle# " .. self.ctx.symbol .. " %*"
    vim.wo[self.win][place.fix] = true
  else
    self.win = vim.api.nvim_open_win(self.buf, true, {
      relative = "cursor",
      row = 1,
      col = 2,
      width = 72,
      height = 28,
      style = "minimal",
      border = "rounded",
      title = { { " " .. self.ctx.symbol .. " ", "FoxSymdepsTitle" } },
      title_pos = "center",
    })
  end
  vim.wo[self.win].winblend = self.palette.winblend or 0
  vim.wo[self.win].cursorline = false
  -- wrap + breakindent so long content (Layout op-costs, cascade headers, doc
  -- paths) reflows instead of hard-truncating at the panel edge. Tree hierarchy
  -- is LEFT-indentation and nav is by-item, so breakindent preserves the layout
  -- and j/k / the ❯ pointer are unaffected.
  vim.wo[self.win].wrap = true
  vim.wo[self.win].linebreak = true
  vim.wo[self.win].breakindent = true
  vim.wo[self.win].breakindentopt = "shift:2"
  vim.wo[self.win].winhighlight =
    "Normal:FoxSymdepsNormal,FloatBorder:FoxSymdepsBorder,FloatTitle:FoxSymdepsTitle"

  self.action_hints = {} -- lens-contributed keybind hints for the footer (registered via map_action)
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
  map("r", function() -- re-run the full analysis (cascade + break-check) for the current symbol
    self.external_breakcheck = true
    require("fox-symdeps").inspect(self.ctx, self)
    vim.notify("fox-symdeps · refreshed", vim.log.levels.INFO)
  end)
  map("w", function() self:_width_lits() end)
  map("a", function() self:_asm() end)
  map("/", function() self:_filter() end)
  map("?", function() self:_help() end)
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

-- `?` help: a readable float of every key + a glossary of what each section means (tooltips).
function Hud:_help()
  local lines = {
    "",
    "  Open    <leader>dd float · <leader>dD panel · <leader>dS browse structs · <leader>du use-lens",
    "",
    "  Move    j/k · <C-d>/<C-u> page · l / h  expand / fold · <CR>  jump to code",
    "  Filter  /   filter the Consumers tree",
    "",
    "  Actions",
    "    s  false-sharing scan          m  who writes this field",
    "    b  break-check (what broke)     c  change-impact (size → downstream)",
    "    n  doc mentions (notes)         a  asm flag-diff (functions)",
    "    w  width-literal scan           r  refresh (re-run analysis)",
    "    Q  rows → quickfix              y  yank readout",
    "    q / <Esc>  close",
    "",
    "  Panel (<leader>dD)   p follow/pin · x drop tab · flip tabs: H/L in-panel · <leader>d[ / d] anywhere",
    "",
    "  Sections",
    "    ◆ Layout        size · align · cache-line fit · op-cost",
    "    ▪ Fields        per-field offset · size · line · straddle flag",
    "    ▦ Byte map      fields laid on 64 B cache lines (wide view)",
    "    ⊐ Uses          types this depends on (upstream)",
    "    ⊟ Contains      what it contains, recursively",
    "    ◇ Consumers     who uses this  ·  Called by (functions)",
    "    → Calls         what a function calls (outbound)",
    "    ↪ Call trace    transitive callers",
    "    ▲ Blast radius  byte-layout cascade · embedders + sizeof/fwrite/memcmp",
    "    ◈ hot-path      latency-critical · compiled instruction budget",
    "    ▣ size-budget   struct is cache-residency gated (L1d / L2 tier)",
    "    ◇ Written/Docs  on-demand — m: who writes a field · n: doc mentions",
    "",
  }
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  vim.bo[buf].bufhidden = "wipe"
  local w = 0
  for _, l in ipairs(lines) do w = math.max(w, vim.fn.strdisplaywidth(l)) end
  local win = vim.api.nvim_open_win(buf, true, {
    relative = "editor", width = w + 2, height = #lines,
    row = math.max(0, math.floor((vim.o.lines - #lines) / 2)),
    col = math.max(0, math.floor((vim.o.columns - w) / 2)),
    style = "minimal", border = "rounded",
    title = { { " fox-symdeps · keys ", "FoxSymdepsTitle" } }, title_pos = "center",
  })
  vim.wo[win].winhighlight = "Normal:FoxSymdepsNormal,FloatBorder:FoxSymdepsBorder,FloatTitle:FoxSymdepsTitle"
  vim.wo[win].winblend = self.palette.winblend or 0
  for _, k in ipairs({ "q", "<Esc>", "?" }) do
    vim.keymap.set("n", k, function() pcall(vim.api.nvim_win_close, win, true) end,
      { buffer = buf, nowait = true, silent = true })
  end
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
  if d.state ~= "ok" or not d.data or not d.data.size then
    return { "layout unavailable — needs compile_commands.json + cursor on a type" }
  end
  local sz, al = d.data.size, d.data.align or 0
  local out = { ("size %d B · align %d%s%s"):format(sz, al,
    d.data.computed and "  (sizeof probe)" or "", size_delta(self.prev_size, sz)) }
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

-- relative "edited N ago" — only files that carry .mtime (the notes lens) get a suffix; others don't.
local function ago(t)
  local d = os.time() - t
  if d < 90 then return "just now" end
  if d < 3600 then return math.floor(d / 60) .. "m ago" end
  if d < 86400 then return math.floor(d / 3600) .. "h ago" end
  return math.floor(d / 86400) .. "d ago"
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
  local function render_files(files)
    for _, file in ipairs(files) do
      local rel = file.file:gsub("^" .. vim.pesc(home) .. "/", "")
      local when = (file.mtime and file.mtime > 0) and ("  · " .. ago(file.mtime)) or ""
      add_branch(("     %s %s (%d)%s"):format(file.collapsed and "▸" or "▾", rel, file.count, when),
        "file", file, "FoxSymdepsBadge")
      if not file.collapsed then
        for _, e in ipairs(file.entries) do
          local tail = e.scope and (e.scope .. "  :" .. e.line) or (":" .. e.line)
          if e.broken then
            add_leaf("     ▲   " .. tail, { file = file.file, line = e.line }, "FoxSymdepsAlarm", true)
          else
            add_leaf("         " .. tail, { file = file.file, line = e.line })
          end
        end
      end
    end
  end
  local function render_tree(tree)
    for _, role in ipairs(tree) do
      add_branch(("   %s %s (%d)"):format(role.collapsed and "▸" or "▾", role.label, role.count),
        "role", role, "FoxSymdepsHeader")
      if not role.collapsed then render_files(role.files) end
    end
  end

  add(" ◆ Layout", "FoxSymdepsHeader")
  for _, l in ipairs(self:_layout_lines()) do add("   " .. l, "FoxSymdepsBadge") end
  add("")

  -- guardrail info-lines (◈ hot-path / ▣ size-budget) — the highest-signal "this is budgeted"
  -- context; lifted to a priority band right under Layout so it's never buried below Consumers.
  for _, sec in ipairs(self.sections or {}) do
    if sec.state == "ok" and sec.tree == nil then
      add(" " .. sec.label, "FoxSymdepsHeader")
      add("")
    end
  end

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
        local lstr = (lo == hi) and ("L" .. lo) or ("L" .. lo .. "–" .. hi .. "  ▲ straddles")
        local ty = f.type or ""
        if #ty > 18 then ty = ty:sub(1, 17) .. "…" end
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
    add(" ▦ Byte map" .. (bm.straddle and "  ▲ straddles a cache line" or ""),
      bm.straddle and "FoxSymdepsWarn" or "FoxSymdepsHeader")
    for _, l in ipairs(bm.lines) do add("   " .. l, "FoxSymdepsBadge") end
    add("")
  end

  -- Reverse composition (types only): what this struct contains, recursively (W22)
  if self.ctx.kind ~= "function" and self.composition and #self.composition > 0 then
    add(" ⊟ Contains", "FoxSymdepsHeader")
    local function render_comp(nodes, depth)
      for _, n in ipairs(nodes) do
        add(("   %s%s : %s"):format(("  "):rep(depth), n.name, n.type), "FoxSymdepsBadge")
        if n.children then render_comp(n.children, depth + 1) end
      end
    end
    render_comp(self.composition, 0)
    add("")
  end

  -- Upstream "Uses" (types only): distinct types this struct depends on — the mirror of Consumers.
  -- Each is jumpable to its definition (add_leaf); an unresolved one (e.g. a template param T) stays plain.
  if self.ctx.kind ~= "function" and self.uses ~= nil then
    add(" ⊐ Uses" .. (#self.uses > 0 and (" (" .. #self.uses .. ")") or ""), "FoxSymdepsHeader")
    if #self.uses == 0 then
      add("   — (no struct deps)", "FoxSymdepsBadge")
    else
      for _, u in ipairs(self.uses) do
        if u.file then
          add_leaf("   " .. u.name, { file = u.file, line = u.line or 1 })
        else
          add("   " .. u.name, "FoxSymdepsBadge")
        end
      end
    end
    add("")
  end

  -- Consumers: collapsible role → file → function tree (+ optional /filter)
  local c = self.consumers
  local vtree = self:_visible_tree()
  local total = 0
  for _, role in ipairs(vtree) do total = total + role.count end
  local count = c.state == "ok" and total or nil
  local chdr = " ◇ " .. (self.ctx.kind == "function" and "Called by" or "Consumers") .. (count and (" (" .. count .. ")") or "")
  if self.filter then chdr = chdr .. "  /" .. self.filter end
  add(chdr, "FoxSymdepsHeader")
  if c.state == "loading" then
    add("   " .. SPIN[self.spin] .. " finding…", "FoxSymdepsBadge")
  elseif c.state == "no_client" then
    add("   — (clangd — see Layout)", "FoxSymdepsBadge")
  elseif not count or count == 0 then
    add(self.filter and ("   no match for /" .. self.filter) or "   none", "FoxSymdepsBadge")
  elseif self.ctx.kind == "function" then
    for _, role in ipairs(vtree) do render_files(role.files) end -- single "Called by" role → files directly
  else
    render_tree(vtree)
  end

  -- Calls (functions only): what this function calls — the outbound direction (mirror of "Called by")
  local calls = self.calls
  if self.ctx.kind == "function" and calls and (calls.state == "loading" or (calls.state == "ok" and #calls.tree > 0)) then
    add("")
    local n = 0
    for _, role in ipairs(calls.tree) do n = n + (role.count or 0) end
    add(" → Calls" .. (calls.state == "ok" and (" (" .. n .. ")") or ""), "FoxSymdepsHeader")
    if calls.state == "loading" then
      add("   " .. SPIN[self.spin] .. " walking…", "FoxSymdepsBadge")
    else
      render_tree(calls.tree)
    end
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

  -- Provider TREE sections (e.g. the cascade's "▲ Byte-layout blast radius"). Header-only info-lines
  -- (tree == nil, e.g. hot-path / size-budget) render in the priority band under Layout — skip here.
  for _, sec in ipairs(self.sections or {}) do
    local has = sec.tree and #sec.tree > 0
    if sec.tree ~= nil and (sec.state == "loading" or (sec.state == "ok" and has)) then
      add("")
      local scount = 0
      for _, role in ipairs(sec.tree or {}) do scount = scount + (role.count or 0) end
      add(" " .. sec.label .. ((sec.state == "ok" and has) and (" (" .. scount .. ")") or ""), "FoxSymdepsHeader")
      if sec.state == "loading" then
        add("   " .. SPIN[self.spin] .. " analyzing…", "FoxSymdepsBadge")
      elseif has then
        render_tree(sec.tree)
      end
    end
  end

  -- keybind hint footer: contextual lens keys + always-on keys, WRAPPED to the window width so it
  -- never runs off the edge (it overflowed the float and got badly cut in the narrower panel).
  do
    local parts = {}
    for _, h in ipairs(self.action_hints or {}) do parts[#parts + 1] = h.key .. " " .. h.desc end
    if self.ctx.kind == "function" then parts[#parts + 1] = "a asm" else parts[#parts + 1] = "w width-lits" end
    parts[#parts + 1] = "r refresh"; parts[#parts + 1] = "Q qf"; parts[#parts + 1] = "y yank"; parts[#parts + 1] = "? help"
    local w = (self.win and vim.api.nvim_win_is_valid(self.win)) and vim.api.nvim_win_get_width(self.win) or 72
    add("")
    local line = ""
    for _, p in ipairs(parts) do
      local cand = (line == "") and p or (line .. " · " .. p)
      if line ~= "" and vim.fn.strdisplaywidth("   " .. cand) > (w - 2) then
        add("   " .. line, "FoxSymdepsBadge")
        line = p
      else
        line = cand
      end
    end
    if line ~= "" then add("   " .. line, "FoxSymdepsBadge") end
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
    vim.api.nvim_buf_set_extmark(self.buf, NS, line - 1, 0, {
      line_hl_group = "FoxSymdepsSelection",
      virt_text = { { "❯", "FoxSymdepsHeader" } }, virt_text_pos = "overlay", virt_text_win_col = 0,
    }) -- fzf-style pointer on the active row (mirrors --pointer)
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
    pcall(vim.cmd, "normal! zz") -- recenter the landing line
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
  local ld = self.layout and self.layout.data
  local size = ld and ld.size
  if not size then
    local msg = (ld and ld.is_template)
      and "templated type — no concrete size un-instantiated; put the cursor on a concrete Foo<N> use to scan width literals"
      or "size unknown — can't scan width literals"
    return vim.notify("fox-symdeps · " .. msg, vim.log.levels.WARN)
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
  -- Qualify with the enclosing namespace (resolved in context.under_cursor) so
  -- symbols inside `namespace tt { … }` compile; global-scope symbols get an
  -- empty container → unqualified name (identical to before). Call sites (cursor
  -- outside the namespace block) resolve container="" here — a hover-markdown
  -- fallback for that case is a follow-up.
  local bufnr = self.ctx.bufnr
  local container = self.ctx.container or ""
  local fn = (container ~= "") and (container .. "::" .. self.ctx.symbol) or self.ctx.symbol
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
