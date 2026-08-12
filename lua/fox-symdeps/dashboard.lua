-- dashboard.lua — the codebase-wide surface. Where the HUD answers "tell me about THIS symbol,"
-- the dashboard answers "where are my engine's risks?" — one warm, tree-navigable panel of tiles,
-- each a whole-project cut. Same palette + nav + glyph language as the HUD, so it reads as one tool.
-- Tiles fill async (grep is instant; the struct census waits on a compile) with a per-tile spinner.
local M = {}
local NS = vim.api.nvim_create_namespace("fox_symdeps_dash")
local SPIN = { "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" }

local Dash = {}
Dash.__index = Dash

-- pretty byte size: bytes under 8 KiB (the cache-relevant range stays exact), KB above.
local function human(n)
  if n < 8192 then return n .. " B" end
  return math.floor(n / 1024) .. " KB"
end
M._human = human

-- cache-residency verdict for a struct size → { note, hl }. The story the tile tells: green fits a
-- line, wheat spills a line (the band you'd want resident but that straddles). Above 256 B a struct
-- is never cache-resident anyway, so the cache-line count is just noise — drop it, show footprint only.
local function residency(size)
  if size <= 64 then return { note = "fits a cache line", hl = "FoxSymdepsOk" } end
  if size <= 256 then return { note = ("spills %d cache lines"):format(math.ceil(size / 64)), hl = "FoxSymdepsWarn" } end
  return { note = "", hl = "FoxSymdepsBadge" }
end
M._residency = residency

-- the base identifier of a possibly-qualified, possibly-templated name, for a definition grep:
-- "tt::detail::FixedPoint<10, 8>" -> "FixedPoint".
local function base_ident(name)
  local n = name:gsub("%s*<.*$", "")      -- drop template args
  n = n:gsub("^.*::", "")                 -- drop namespace qualifiers
  return n
end
M._base_ident = base_ident

function M.open(palette)
  local origin_buf = vim.api.nvim_get_current_buf()
  local origin_win = vim.api.nvim_get_current_win()
  local self = setmetatable({
    palette = palette or {},
    origin_buf = origin_buf,
    origin_win = origin_win,
    root = (function()
      local f = vim.api.nvim_buf_get_name(origin_buf)
      return (f ~= "" and vim.fs.root(f, { ".git", "compile_commands.json" })) or vim.fn.getcwd()
    end)(),
    -- default-CLOSED drops (operator §9, 2026-08-11 — "drop downs are default closed"); the
    -- header counts tell the story, `l` opens what you want.
    tiles = {
      { key = "widest", glyph = "⊃", label = "Widest headers", hint = "include blast-radius · grouped by directory",
        state = "loading", collapsed = true, rows = {}, folds = {} },
      { key = "biggest", glyph = "▦", label = "Biggest structs", hint = "cache-residency · [SIZE] tag corpus (repo-wide)",
        state = "loading", collapsed = true, rows = {}, folds = {} },
      { key = "straddlers", glyph = "▲", label = "Cache-line straddlers",
        hint = "written [STRADDLE] facts on the converted corpus · placement / false-sharing risk",
        state = "loading", collapsed = true, rows = {}, folds = {} },
    },
    items = {},
    sel = 1,
    spin = 1,
    closed = false,
  }, Dash)
  self:_window()
  self:_hide_cursor()
  self:_spinner()
  self:render()
  self:_load()
  return self
end

function Dash:_window()
  self.buf = vim.api.nvim_create_buf(false, true)
  vim.bo[self.buf].bufhidden = "wipe"
  vim.bo[self.buf].filetype = "fox-symdeps-dashboard"
  local W = math.min(96, math.floor(vim.o.columns * 0.82))
  local H = math.min(40, math.floor(vim.o.lines * 0.82))
  self.win = vim.api.nvim_open_win(self.buf, true, {
    relative = "editor",
    width = W,
    height = H,
    row = math.max(0, math.floor((vim.o.lines - H) / 2)),
    col = math.max(0, math.floor((vim.o.columns - W) / 2)),
    style = "minimal",
    border = "rounded",
    title = { { "  ✦ fox-symdeps · dashboard  ", "FoxSymdepsTitle" } },
    title_pos = "center",
  })
  vim.wo[self.win].winblend = self.palette.winblend or 0
  vim.wo[self.win].cursorline = false
  vim.wo[self.win].wrap = true
  vim.wo[self.win].linebreak = true
  vim.wo[self.win].breakindent = true
  vim.wo[self.win].breakindentopt = "shift:2"
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
  map("l", function() self:_activate() end)
  map("<Right>", function() self:_activate() end)
  map("h", function() self:_collapse(true) end)
  map("<Left>", function() self:_collapse(true) end)
  map("r", function() self:_load(true) end)
  map("q", function() self:close() end)
  map("<Esc>", function() self:close() end)
  vim.api.nvim_create_autocmd("BufLeave", { buffer = self.buf, once = true, callback = function() self:close() end })
end

function Dash:_hide_cursor()
  self.saved_guicursor = vim.o.guicursor
  pcall(function()
    vim.api.nvim_set_hl(0, "FoxSymdepsHiddenCursor", { blend = 100 })
    vim.o.guicursor = "a:FoxSymdepsHiddenCursor"
  end)
end

function Dash:_spinner()
  self.timer = vim.uv.new_timer()
  self.timer:start(80, 80, vim.schedule_wrap(function()
    if self.closed then return end
    self.spin = (self.spin % #SPIN) + 1
    for _, t in ipairs(self.tiles) do
      if t.state == "loading" then return self:render() end
    end
  end))
end

-- fire each tile's producer; results stream back into the tile + a re-render. `refresh` re-runs.
function Dash:_load(refresh)
  for _, t in ipairs(self.tiles) do t.state = "loading"; t.rows = {} end
  self:render()

  -- widest headers — grep, near-instant; GROUPED BY DIRECTORY (operator §9, 2026-08-11),
  -- dirs ordered by their subtotal, entries count-desc within.
  vim.schedule(function()
    if self.closed then return end
    local ranked = require("fox-symdeps.aggregate").widest_headers(self.root, 40)
    local prefix = self.root:gsub("/*$", "") .. "/"
    local groups, order = {}, {}
    for _, h in ipairs(ranked) do
      local rel = h.path or ""
      if rel:sub(1, #prefix) == prefix then rel = rel:sub(#prefix + 1) end
      local dir = rel:match("^(.*)/[^/]+$") or "(root)"
      if not groups[dir] then groups[dir] = { total = 0, entries = {} }; order[#order + 1] = dir end
      groups[dir].total = groups[dir].total + (h.count or 0)
      table.insert(groups[dir].entries, h)
    end
    table.sort(order, function(a, b) return groups[a].total > groups[b].total end)
    local rows = {}
    for _, dir in ipairs(order) do
      local g = groups[dir]
      local gid = "widest:" .. dir
      rows[#rows + 1] = {
        group = gid,
        label = ("%-24s %d header(s) · %d includer(s)"):format(dir, #g.entries, g.total),
        hl = "FoxSymdepsHeader",
      }
      for _, h in ipairs(g.entries) do
        rows[#rows + 1] = {
          parent = gid,
          text = ("  %4d  %s"):format(h.count, h.header),
          loc = h.path and { file = h.path, line = 1 } or nil,
        }
      end
    end
    self:_set("widest", #ranked > 0 and "ok" or "empty", rows)
  end)

  -- biggest structs + straddlers — from the [DERIVED] TAG CORPUS, repo-wide (operator catch
  -- 2026-08-11: the old origin-TU compile showed 16-32B "biggest" structs in a codebase whose
  -- giants are 50KB+, and "straddlers (0)" against 4 live baseline straddlers — origin-scoped
  -- facts presented as codebase-wide). The [SIZE]/[STRADDLE] tags are check_cache_layout's
  -- tool-owned, CI-guarded truth: one producer, this tile is just another consumer (§9). One
  -- rg pass, no compile, whole corpus, can never disagree with the source.
  require("fox-symdeps.runner").run(
    { "rg", "-n", "--no-heading", "--sort", "path",
      "-e", "\\[STRUCT\\]_\\[", "-e", "\\[SIZE\\]_\\[", "-e", "\\[STRADDLE\\]_\\[",
      "--glob", "*.hpp", "--glob", "*.cpp",
      "--glob", "!tools/**", "--glob", "!DOCS/**", "--glob", "!build*/**" },
    self.root, function(lines)
    if self.closed then return end
    if not lines then
      local err = { { text = "tag-corpus scan failed (rg unavailable?)", hl = "FoxSymdepsAlarm" } }
      self:_set("biggest", "error", err)
      return self:_set("straddlers", "error", err)
    end
    local structs, cur = {}, nil
    for _, l in ipairs(lines) do
      local file, lno, rest = l:match("^([^:]+):(%d+):(.*)$")
      if file then
        local nm = rest:match("%[STRUCT%]_%[([^%]]+)%]")
        if nm and not rest:match("%[END_STRUCT%]") then
          cur = { name = nm, file = file, line = tonumber(lno) }
          structs[#structs + 1] = cur
        elseif cur and file == cur.file then
          local sz = rest:match("%[SIZE%]_%[(%d+)B%]")
          local straddle = rest:match("%[STRADDLE%]_%[(.+)%]%s*$")
          if sz then cur.size = tonumber(sz) end
          if straddle and straddle ~= "none" then cur.straddle = straddle end
        end
      end
    end

    -- directory → file → list (the operator's settled format rule, 2026-08-11), heaviest-first
    -- at every level. Shared shape for both fact tiles.
    local function grouped_rows(tile_key, list, weight, render)
      local dirs, dorder = {}, {}
      for _, r in ipairs(list) do
        local dir = r.file:match("^(.*)/[^/]+$") or "(root)"
        local fname = r.file:match("([^/]+)$") or r.file
        local d = dirs[dir]
        if not d then d = { w = 0, files = {}, forder = {} }; dirs[dir] = d; dorder[#dorder + 1] = dir end
        d.w = math.max(d.w, weight(r))
        local f = d.files[fname]
        if not f then f = { w = 0, list = {} }; d.files[fname] = f; d.forder[#d.forder + 1] = fname end
        f.w = math.max(f.w, weight(r))
        f.list[#f.list + 1] = r
      end
      table.sort(dorder, function(a, b) return dirs[a].w > dirs[b].w end)
      local rows = {}
      for _, dir in ipairs(dorder) do
        local d = dirs[dir]
        local did = tile_key .. ":" .. dir
        table.sort(d.forder, function(a, b) return d.files[a].w > d.files[b].w end)
        rows[#rows + 1] = { group = did, label = dir, hl = "FoxSymdepsHeader" }
        for _, fname in ipairs(d.forder) do
          local f = d.files[fname]
          local fid = did .. "/" .. fname
          table.sort(f.list, function(a, b) return weight(a) > weight(b) end)
          rows[#rows + 1] = { group = fid, parent = did,
                              label = ("  %s  (%d)"):format(fname, #f.list), hl = "FoxSymdepsBadge" }
          for _, r in ipairs(f.list) do
            local row = render(r)
            row.parent = fid
            rows[#rows + 1] = row
          end
        end
      end
      return rows
    end

    local stradd = {}
    for _, s in ipairs(structs) do
      if s.straddle then stradd[#stradd + 1] = s end
    end
    local srows = grouped_rows("straddlers", stradd,
      function(s) return s.straddle:match("unverified") and 1 or 2 end,   -- verified facts outrank
      function(s)
        local unv = s.straddle:match("unverified")
        return { text = ("    %-26s  %s"):format(s.name, s.straddle),
                 hl = unv and "FoxSymdepsBadge" or "FoxSymdepsWarn",
                 loc = { file = self.root .. "/" .. s.file, line = s.line } }
      end)
    self:_set("straddlers", #stradd > 0 and "ok" or "empty", srows)

    local sized = {}
    for _, s in ipairs(structs) do
      if s.size then sized[#sized + 1] = s end
    end
    table.sort(sized, function(a, b) return a.size > b.size end)
    local top = {}
    for i = 1, math.min(60, #sized) do top[i] = sized[i] end
    local rows = grouped_rows("biggest", top,
      function(r) return r.size end,
      function(r)
        local v = residency(r.size)
        return { text = ("    %8s  %-32s %s"):format(human(r.size), r.name, v.note),
                 hl = v.hl,
                 loc = { file = self.root .. "/" .. r.file, line = r.line } }
      end)
    rows[#rows + 1] = {
      text = ("· facts = the written [DERIVED] corpus (%d converted blocks; check_cache_layout owns them)")
             :format(#structs),
      hl = "FoxSymdepsBadge",
    }
    self:_set("biggest", #sized > 0 and "ok" or "empty", rows)
  end)
end

function Dash:_set(key, state, rows)
  for _, t in ipairs(self.tiles) do
    if t.key == key then t.state = state; t.rows = rows or {} end
  end
  self:render()
end

function Dash:render()
  if self.closed or not vim.api.nvim_buf_is_valid(self.buf) then return end
  local lines, hls = {}, {}
  self.items = {}
  local function add(text, hl)
    lines[#lines + 1] = text
    if hl then hls[#lines] = hl end
    return #lines
  end
  local function add_tile(t, text)
    self.items[#self.items + 1] = { bufline = add(text, "FoxSymdepsHeader"), tile = t }
  end
  local function add_row(row, t)
    self.items[#self.items + 1] =
      { bufline = add("      " .. row.text, row.hl or "FoxSymdepsBadge"),
        loc = row.loc, struct = row.struct, parent_grp = row.parent, tile_ref = t }
  end

  add("")
  add(("  scanning %s"):format(vim.fn.fnamemodify(self.root, ":~")), "FoxSymdepsBadge")
  add("")

  for _, t in ipairs(self.tiles) do
    local n = #t.rows
    local head = ("  %s %s %s  (%s)"):format(
      t.collapsed and "▸" or "▾", t.glyph, t.label,
      t.state == "loading" and (SPIN[self.spin] .. " …")
        or (t.state == "error" and "!") or (t.state == "empty" and "0") or tostring(n))
    add_tile(t, head)
    add("        " .. t.hint, "FoxSymdepsBadge")
    if not t.collapsed then
      if t.state == "loading" then
        add("      " .. SPIN[self.spin] .. " working…", "FoxSymdepsBadge")
      elseif t.state == "empty" then
        add("      — nothing found", "FoxSymdepsBadge")
      else
        -- per-GROUP folds (dir → file → list; groups precede their children in row order).
        -- Default CLOSED per the operator rule; a folded ancestor hides the whole subtree.
        local gparent = {}   -- group id → parent id (built as encountered)
        local function folded(id)
          local f = t.folds[id]
          if f == nil then f = true end
          return f
        end
        local function chain_hidden(pid)
          while pid do
            if folded(pid) then return true end
            pid = gparent[pid]
          end
          return false
        end
        for _, row in ipairs(t.rows) do
          if row.group then
            gparent[row.group] = row.parent
            if not chain_hidden(row.parent) then
              local indent = row.parent and "        " or "      "
              self.items[#self.items + 1] = {
                bufline = add(indent .. (folded(row.group) and "▸ " or "▾ ") .. row.label,
                              row.hl or "FoxSymdepsHeader"),
                grp = row.group, tile_ref = t,
              }
            end
          elseif not chain_hidden(row.parent) then
            add_row(row, t)
          end
        end
      end
    end
    add("")
  end

  add("  j/k move · l/h open/fold · ⏎ jump · r refresh · q close", "FoxSymdepsBadge")

  self.sel = math.max(1, math.min(math.max(#self.items, 1), self.sel))
  vim.bo[self.buf].modifiable = true
  vim.api.nvim_buf_set_lines(self.buf, 0, -1, false, lines)
  vim.bo[self.buf].modifiable = false
  vim.api.nvim_buf_clear_namespace(self.buf, NS, 0, -1)
  for ln, hl in pairs(hls) do
    vim.api.nvim_buf_set_extmark(self.buf, NS, ln - 1, 0, { line_hl_group = hl })
  end
  if #self.items > 0 then
    local line = self.items[self.sel].bufline
    vim.api.nvim_buf_set_extmark(self.buf, NS, line - 1, 0, {
      line_hl_group = "FoxSymdepsSelection",
      virt_text = { { "❯", "FoxSymdepsHeader" } }, virt_text_pos = "overlay", virt_text_win_col = 0,
    })
    if vim.api.nvim_win_is_valid(self.win) then pcall(vim.api.nvim_win_set_cursor, self.win, { line, 0 }) end
  end
end

function Dash:_move(dir)
  if #self.items == 0 then return end
  self.sel = math.max(1, math.min(#self.items, self.sel + dir))
  self:render()
end

function Dash:_page(dir)
  local h = (self.win and vim.api.nvim_win_is_valid(self.win)) and vim.api.nvim_win_get_height(self.win) or 20
  self:_move(dir * math.max(1, math.floor(h / 2)))
end

function Dash:_collapse(want)
  local it = self.items[self.sel]
  if not it then return end
  if it.tile then
    it.tile.collapsed = want
    return self:render()
  end
  if it.grp then                                   -- fold the group under the cursor
    it.tile_ref.folds[it.grp] = want
    return self:render()
  end
  if it.parent_grp and want then                   -- h on a child folds its parent + lands on it
    it.tile_ref.folds[it.parent_grp] = true
    self:render()
    for i, item in ipairs(self.items) do
      if item.grp == it.parent_grp then self.sel = i; break end
    end
    return self:render()
  end
end

-- a window to jump into: the origin code window, else any other window.
function Dash:_code_win()
  if self.origin_win and vim.api.nvim_win_is_valid(self.origin_win) and self.origin_win ~= self.win then
    return self.origin_win
  end
  for _, w in ipairs(vim.api.nvim_list_wins()) do if w ~= self.win then return w end end
end

-- resolve a struct name → its definition {file, line} via rg (grep the def, prefer a header).
function Dash:_resolve_struct(name)
  local ok, out = pcall(vim.fn.systemlist, {
    "rg", "--no-heading", "--line-number", "--color", "never",
    "-g", "*.hpp", "-g", "*.h", "-g", "*.hh", "-g", "*.cpp", "-g", "*.cc",
    "-e", "(struct|class|union)[[:space:]]+" .. name .. "[[:space:]{:<;]", self.root,
  })
  if ok and type(out) == "table" and out[1] then
    local file, line = out[1]:match("^([^:]+):(%d+):")
    if file then return { file = file, line = tonumber(line) } end
  end
end

function Dash:_activate()
  local it = self.items[self.sel]
  if not it then return end
  if it.tile then
    it.tile.collapsed = not it.tile.collapsed
    return self:render()
  end
  if it.grp then                                   -- group rows toggle (l/⏎ open, h closes)
    local cur = it.tile_ref.folds[it.grp]
    if cur == nil then cur = true end
    it.tile_ref.folds[it.grp] = not cur
    return self:render()
  end
  local loc = it.loc
  if not loc and it.struct then loc = self:_resolve_struct(it.struct) end
  if not loc then
    return require("fox-symdeps.ui").notify_raw("fox-symdeps · couldn't locate a definition to jump to", vim.log.levels.INFO)
  end
  local target = self:_code_win()
  self:close()
  if target and vim.api.nvim_win_is_valid(target) then vim.api.nvim_set_current_win(target) end
  vim.cmd("normal! m`")
  vim.cmd.edit(vim.fn.fnameescape(loc.file))
  pcall(vim.api.nvim_win_set_cursor, 0, { loc.line, 0 })
  pcall(vim.cmd, "normal! zz")
end

function Dash:close()
  if self.closed then return end
  self.closed = true
  if self.timer then self.timer:stop(); self.timer:close() end
  if self.saved_guicursor then vim.o.guicursor = self.saved_guicursor end
  if self.win and vim.api.nvim_win_is_valid(self.win) then vim.api.nvim_win_close(self.win, true) end
end

return M
