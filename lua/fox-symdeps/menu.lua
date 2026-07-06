-- menu.lua — a small keyboard-first action menu float. NUMBER = run that item immediately; j/k (native)
-- move + cursorline highlights; <CR> = run the highlighted item; q / <Esc> = cancel. Rounded border,
-- title = the unit. Reused by the source palette (<leader>dm) and the HUD 'm' key. No dependency on
-- vim.ui.select (whose default box is the janky "type a number and Enter" confirm).
local M = {}

-- open(items, opts): items = { { label = string, run = function() end }, … }
--   opts = { title = string?, palette = table? }
function M.open(items, opts)
  opts = opts or {}
  if not items or #items == 0 then
    return vim.notify("fox-symdeps · no actions for this unit", vim.log.levels.INFO)
  end
  local lines, width = {}, (opts.title and #opts.title + 6 or 16)
  for i, it in ipairs(items) do
    lines[i] = ("  %d  %s"):format(i, it.label)
    width = math.max(width, vim.fn.strdisplaywidth(lines[i]) + 2)
  end

  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  vim.bo[buf].bufhidden = "wipe"

  local win = vim.api.nvim_open_win(buf, true, {
    relative = "cursor", row = 1, col = 0, width = width, height = #lines,
    style = "minimal", border = "rounded",
    title = opts.title and (" " .. opts.title .. " ") or nil, title_pos = "center",
  })
  vim.wo[win].cursorline = true
  vim.wo[win].cursorlineopt = "line" -- highlight the WHOLE row, not just the number column
  -- the selection BAR: reuse the HUD's own FoxSymdepsSelection (bright peach row + dark ink, bold) so
  -- the menu's selected row matches the panel's exactly.
  local wh = "CursorLine:FoxSymdepsSelection"
  if opts.palette and opts.palette.border then
    pcall(vim.api.nvim_set_hl, 0, "FoxSymdepsMenuBorder", { fg = opts.palette.border })
    wh = "FloatBorder:FoxSymdepsMenuBorder,FloatTitle:FoxSymdepsMenuBorder," .. wh
  end
  vim.wo[win].winhighlight = wh

  -- hide the cursor block so the selection bar is the SOLE indicator (that stray `•` was the cursor).
  local saved_gc = vim.o.guicursor
  pcall(function()
    vim.api.nvim_set_hl(0, "FoxSymdepsMenuHiddenCursor", { blend = 100 })
    vim.o.guicursor = "a:FoxSymdepsMenuHiddenCursor"
  end)

  local closed = false
  local function close()
    if closed then return end
    closed = true
    vim.o.guicursor = saved_gc -- restore the cursor
    pcall(vim.api.nvim_win_close, win, true)
  end
  local function run(i)
    local it = items[i]
    close()
    if it and it.run then vim.schedule(it.run) end -- schedule: let the float close before the op fires
  end

  local function run_cur() run(vim.api.nvim_win_get_cursor(win)[1]) end
  for i = 1, math.min(#items, 9) do
    vim.keymap.set("n", tostring(i), function() run(i) end, { buffer = buf, nowait = true, silent = true })
  end
  for _, k in ipairs({ "<CR>", "l" }) do -- <CR> / l (hjkl) = select the highlighted row
    vim.keymap.set("n", k, run_cur, { buffer = buf, nowait = true, silent = true })
  end
  for _, k in ipairs({ "q", "<Esc>", "h" }) do -- q / <Esc> / h (hjkl) = cancel
    vim.keymap.set("n", k, close, { buffer = buf, nowait = true, silent = true })
  end
  -- j / k navigate the selection natively (the cursorline bar follows)
  -- close if focus leaves the menu (click away / :b switch)
  vim.api.nvim_create_autocmd({ "BufLeave", "WinLeave" }, { buffer = buf, once = true, callback = close })
end

return M
