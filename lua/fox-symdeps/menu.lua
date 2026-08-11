-- menu.lua — a small keyboard-first action menu float. NUMBER = run that item immediately; j/k (native)
-- move + cursorline highlights; <CR> = run the highlighted item; q / <Esc> = cancel. Rounded border,
-- title = the unit. Reused by the source palette (<leader>dm) and the HUD 'm' key. No dependency on
-- vim.ui.select (whose default box is the janky "type a number and Enter" confirm).
local M = {}

-- open(items, opts): items = { { label = string, run = function() end }, … }
--   opts = { title = string?, palette = table? }
-- write-tier icon: ⚠ = edits SOURCE lines · ✎ = writes tag-comments only (T6) · " " = read-only.
function M._writes_icon(it)
  if it.writes == "code" then return "⚠" end
  if it.writes == "comments" then return "✎" end
  return " "
end

-- Where the menu floats. Operator ask (2026-08-09): "rather than popping up here, maybe attached
-- to the hud, or within the panel as a sub panel" — an open board/follow/HUD window passed as
-- `anchor_win` docks the menu INSIDE that window's top-left (sub-panel feel); otherwise cursor.
function M._placement(anchor_win)
  if anchor_win and vim.api.nvim_win_is_valid(anchor_win) then
    return { relative = "win", win = anchor_win, row = 1, col = 2 }
  end
  return { relative = "cursor", row = 1, col = 0 }
end

function M.open(items, opts)
  opts = opts or {}
  if not items or #items == 0 then
    return vim.notify("fox-symdeps · no actions for this unit", vim.log.levels.INFO)
  end
  local lines, width = {}, (opts.title and #opts.title + 6 or 16)
  local any_writes = false
  for i, it in ipairs(items) do
    lines[i] = ("  %d %s %s"):format(i, M._writes_icon(it), it.label)
    if it.writes then any_writes = true end
    width = math.max(width, vim.fn.strdisplaywidth(lines[i]) + 2)
  end
  if any_writes then
    -- operator ask (2026-08-09): "a caution icon so i know if it changes the source or not"
    lines[#lines + 1] = "  ✎ writes tag-comments · ⚠ edits source"
    width = math.max(width, vim.fn.strdisplaywidth(lines[#lines]) + 2)
  end

  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  vim.bo[buf].bufhidden = "wipe"
  -- LAYER-STACK marker (operator rule 2026-08-10: opened-item > menu > HUD): ancestors check
  -- this to keep themselves alive while their child menu is open (hud float BufLeave guard).
  vim.b[buf].fox_symdeps_menu = true

  local place = M._placement(opts.anchor_win)
  place.width, place.height = width, #lines
  place.style, place.border = "minimal", "rounded"
  place.title = opts.title and (" " .. opts.title .. " ") or nil
  if place.title then place.title_pos = "center" end
  local win = vim.api.nvim_open_win(buf, true, place)
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
