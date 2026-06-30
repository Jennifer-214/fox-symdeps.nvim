-- The calm float HUD — a picker over the symbol's layout + consumers. j/k snap between
-- selectable entries (headers/blanks skipped), the active one gets a warm highlight + ▸,
-- the text cursor is hidden, <CR> jumps (jumplist-friendly), q/<Esc> closes. Async-filled.
local M = {}
local NS = vim.api.nvim_create_namespace("fox_symdeps_hud")
local SPIN = { "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" }

local Hud = {}
Hud.__index = Hud

function M.open(ctx, palette, on_close)
  local self = setmetatable({
    ctx = ctx,
    palette = palette or {},
    on_close = on_close,
    origin = vim.api.nvim_get_current_win(),
    layout = { state = "loading" },
    consumers = { state = "loading", groups = {} },
    items = {}, -- selectable rows: { bufline (1-based), loc = { file, line } }
    sel = 1,
    spin = 1,
    closed = false,
  }, Hud)
  self:_window()
  self:_hide_cursor()
  self:_spinner()
  self:render()
  return self
end

function Hud:set_layout(data, state)
  self.layout = { state = state, data = data }
  self:render()
end

function Hud:set_consumers(groups, state)
  self.consumers = { state = state, groups = groups or {} }
  self:render()
end

function Hud:_window()
  self.buf = vim.api.nvim_create_buf(false, true)
  vim.bo[self.buf].bufhidden = "wipe"
  vim.bo[self.buf].filetype = "fox-symdeps"
  self.win = vim.api.nvim_open_win(self.buf, true, {
    relative = "cursor",
    row = 1,
    col = 2,
    width = 66,
    height = 18,
    style = "minimal",
    border = "rounded",
    title = { { " " .. self.ctx.symbol .. " ", "FoxSymdepsTitle" } },
    title_pos = "center",
  })
  vim.wo[self.win].winblend = self.palette.winblend or 0
  vim.wo[self.win].cursorline = false -- selection is an explicit highlight, not the cursor line
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
  map("<CR>", function() self:_jump() end)
  map("q", function() self:close() end)
  map("<Esc>", function() self:close() end)
  map("?", function()
    vim.notify("fox-symdeps · j/k select · <CR> jump · q/<Esc> close", vim.log.levels.INFO)
  end)
  -- keep it a picker, not an editor: neutralize stray motions/edits
  for _, k in ipairs({ "h", "l", "<Left>", "<Right>", "i", "a", "o", "x", "dd", "p" }) do
    map(k, function() end)
  end
  vim.api.nvim_create_autocmd("BufLeave", {
    buffer = self.buf,
    once = true,
    callback = function() self:close() end,
  })
end

-- Hide the text cursor while the float is focused (restored on close) so it reads as a
-- menu, not a text buffer. guicursor is global; we save + restore around the float.
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

function Hud:_spinner()
  self.timer = vim.uv.new_timer()
  self.timer:start(80, 80, vim.schedule_wrap(function()
    if self.closed then return end
    self.spin = (self.spin % #SPIN) + 1
    if self.layout.state == "loading" or self.consumers.state == "loading" then
      self:render()
    end
  end))
end

-- One or more detail lines for the Layout section. Beyond size/align: cache-line span +
-- free space, plus density (how many fit a 64 B line) and which vector register the type
-- fits — the readouts that matter for hot-path packing / SWAR.
function Hud:_layout_lines()
  local d = self.layout
  if d.state == "loading" then return { SPIN[self.spin] .. " sizing…" } end
  if d.state == "no_client" then return { "clangd not attached" } end
  if d.state ~= "ok" or not d.data or not d.data.size then return { "layout unavailable" } end
  local sz, al = d.data.size, d.data.align or 0
  local out = { ("size %d B · align %d"):format(sz, al) }
  if sz <= 64 then
    local reg = sz <= 16 and "XMM 128b" or (sz <= 32 and "YMM 256b" or "ZMM 512b")
    out[#out + 1] = ("fits 1 cache line · %d B slack · %d/line · → %s"):format(64 - sz, math.floor(64 / sz), reg)
  else
    local lines = math.ceil(sz / 64)
    out[#out + 1] = ("spans %d cache lines · %d B free in line %d"):format(lines, lines * 64 - sz, lines)
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
  local function add_item(text, loc)
    local ln = add(text)
    self.items[#self.items + 1] = { bufline = ln, loc = loc }
  end

  add(" ◆ Layout", "FoxSymdepsHeader")
  for _, l in ipairs(self:_layout_lines()) do add("   " .. l, "FoxSymdepsBadge") end
  add("")

  local c = self.consumers
  local total = 0
  for _, g in ipairs(c.groups or {}) do total = total + #g.items end
  local count = c.state == "ok" and total or nil
  add(" ◇ Consumers" .. (count and (" (" .. count .. ")") or ""), "FoxSymdepsHeader")
  if c.state == "loading" then
    add("   " .. SPIN[self.spin] .. " finding…", "FoxSymdepsBadge")
  elseif c.state == "no_client" then
    add("   clangd not attached", "FoxSymdepsBadge")
  elseif not count or count == 0 then
    add("   none", "FoxSymdepsBadge")
  else
    local home = vim.fn.getcwd()
    for _, g in ipairs(c.groups) do
      add("   " .. g.label .. " (" .. #g.items .. ")", "FoxSymdepsBadge")
      for _, it in ipairs(g.items) do
        local rel = it.file:gsub("^" .. vim.pesc(home) .. "/", "")
        local txt = it.name and (it.name .. "  " .. rel .. ":" .. it.line) or (rel .. ":" .. it.line)
        add_item("     " .. txt, it)
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

  -- selection: warm bar + ▸ marker on the active item, cursor parked there for scroll
  if #self.items > 0 then
    local line = self.items[self.sel].bufline
    vim.api.nvim_buf_set_extmark(self.buf, NS, line - 1, 0, { line_hl_group = "FoxSymdepsSelection" })
    vim.api.nvim_buf_set_extmark(self.buf, NS, line - 1, 0,
      { virt_text = { { " ▸", "FoxSymdepsHeader" } }, virt_text_pos = "overlay" })
    if vim.api.nvim_win_is_valid(self.win) then
      pcall(vim.api.nvim_win_set_cursor, self.win, { line, 0 })
    end
  end
end

function Hud:_jump()
  local it = self.items[self.sel]
  if not (it and it.loc) then return end
  self:close()
  if vim.api.nvim_win_is_valid(self.origin) then
    vim.api.nvim_set_current_win(self.origin)
  end
  vim.cmd("normal! m`") -- jumplist mark so <C-o> returns
  vim.cmd.edit(vim.fn.fnameescape(it.loc.file))
  pcall(vim.api.nvim_win_set_cursor, 0, { it.loc.line, 0 })
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
