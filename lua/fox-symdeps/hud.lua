-- The calm float HUD: Layout badges + Consumers list for the symbol under cursor.
-- Stacked + scrollable (j/k native), <CR> jumps (jumplist-friendly), q/<Esc> closes. Async-filled.
local M = {}
local NS = vim.api.nvim_create_namespace("fox_symdeps_hud")
local SPIN = { "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" }

local Hud = {}
Hud.__index = Hud

function M.open(ctx, palette)
  local self = setmetatable({
    ctx = ctx,
    palette = palette or {},
    origin = vim.api.nvim_get_current_win(),
    layout = { state = "loading" },
    consumers = { state = "loading", items = {} },
    locs = {}, -- buffer line (1-based) -> { file, line } for <CR>
    spin = 1,
    closed = false,
  }, Hud)
  self:_window()
  self:_spinner()
  self:render()
  return self
end

function Hud:set_layout(data, state)
  self.layout = { state = state, data = data }
  self:render()
end

function Hud:set_consumers(items, state)
  self.consumers = { state = state, items = items or {} }
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
  vim.wo[self.win].cursorline = true
  vim.wo[self.win].wrap = false
  vim.wo[self.win].winhighlight =
    "Normal:FoxSymdepsNormal,FloatBorder:FoxSymdepsBorder,FloatTitle:FoxSymdepsTitle"

  local function map(lhs, fn)
    vim.keymap.set("n", lhs, fn, { buffer = self.buf, nowait = true, silent = true })
  end
  map("q", function() self:close() end)
  map("<Esc>", function() self:close() end)
  map("<CR>", function() self:_jump() end)
  map("?", function()
    vim.notify("fox-symdeps · j/k scroll · <CR> jump · q/<Esc> close", vim.log.levels.INFO)
  end)
  vim.api.nvim_create_autocmd("BufLeave", {
    buffer = self.buf,
    once = true,
    callback = function() self:close() end,
  })
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

function Hud:_badge_line()
  local d = self.layout
  if d.state == "loading" then return SPIN[self.spin] .. " sizing…" end
  if d.state == "no_client" then return "clangd not attached" end
  if d.state ~= "ok" or not d.data or not d.data.size then return "layout unavailable" end
  local sz = d.data.size
  local nlines = math.max(1, math.ceil(sz / 64))
  local fit = nlines == 1 and ("fits 1 cache line · " .. (64 - sz) .. " B slack")
    or ("spans " .. nlines .. " cache lines")
  return ("size %d B · align %d · %s"):format(sz, d.data.align or 0, fit)
end

function Hud:render()
  if self.closed or not vim.api.nvim_buf_is_valid(self.buf) then return end
  local lines, hls = {}, {}
  self.locs = {}
  local function add(text, hl)
    lines[#lines + 1] = text
    if hl then hls[#lines] = hl end
    return #lines
  end

  add(" ◆ Layout", "FoxSymdepsHeader")
  add("   " .. self:_badge_line(), "FoxSymdepsBadge")
  add("")

  local c = self.consumers
  local count = c.state == "ok" and #c.items or nil
  add(" ◇ Consumers" .. (count and (" (" .. count .. ")") or ""), "FoxSymdepsHeader")
  if c.state == "loading" then
    add("   " .. SPIN[self.spin] .. " finding…", "FoxSymdepsBadge")
  elseif c.state == "no_client" then
    add("   clangd not attached", "FoxSymdepsBadge")
  elseif count == 0 then
    add("   none", "FoxSymdepsBadge")
  else
    local home = vim.fn.getcwd()
    for _, it in ipairs(c.items) do
      local rel = it.file:gsub("^" .. vim.pesc(home) .. "/", "")
      self.locs[add("   " .. rel .. ":" .. it.line)] = it
    end
  end

  vim.bo[self.buf].modifiable = true
  vim.api.nvim_buf_set_lines(self.buf, 0, -1, false, lines)
  vim.bo[self.buf].modifiable = false
  vim.api.nvim_buf_clear_namespace(self.buf, NS, 0, -1)
  for ln, hl in pairs(hls) do
    vim.api.nvim_buf_set_extmark(self.buf, NS, ln - 1, 0, { line_hl_group = hl })
  end
end

function Hud:_jump()
  local loc = self.locs[vim.api.nvim_win_get_cursor(self.win)[1]]
  if not loc then return end
  self:close()
  if vim.api.nvim_win_is_valid(self.origin) then
    vim.api.nvim_set_current_win(self.origin)
  end
  vim.cmd("normal! m`") -- drop a jumplist mark so <C-o> returns
  vim.cmd.edit(vim.fn.fnameescape(loc.file))
  pcall(vim.api.nvim_win_set_cursor, 0, { loc.line, 0 })
end

function Hud:close()
  if self.closed then return end
  self.closed = true
  if self.timer then
    self.timer:stop()
    self.timer:close()
  end
  if self.win and vim.api.nvim_win_is_valid(self.win) then
    vim.api.nvim_win_close(self.win, true)
  end
end

return M
