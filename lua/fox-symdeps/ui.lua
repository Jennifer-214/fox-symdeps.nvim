-- ui.lua — the shared PLACEMENT/SIZE policy layer (fleet I-2's token helper). Every window
-- role's sizing lives HERE, not per-surface: five ad-hoc caps and a duplicated aspect
-- threshold was the S4/S9 finding. Widgets consume tokens; policy has ONE home. The values
-- are the surfaces' proven formulas, moved verbatim — no behavior change at extraction.
local M = {}

M.ASPECT_WIDE = 2.2                        -- landscape/portrait split (was hud.lua + panel.lua, duplicated)
M.COMPARE_MIN = { cols = 140, lines = 36 } -- room for two strips (panel compare gate)
M.COCKPIT_MIN_WIDTH = 120                  -- auto-dock roominess gate (cockpit)

-- board-card strip: right strip on landscape, bottom strip on portrait (moved verbatim from
-- hud.resolve_placement; hud re-exports it so its unit test keeps its seam).
function M.resolve_placement(cols, lines)
  cols, lines = cols or 80, math.max(lines or 24, 1)
  if (cols / lines) >= M.ASPECT_WIDE then
    return { cfg = { split = "right", width = math.min(60, math.floor(cols * 0.4)) }, fix = "winfixwidth" }
  end
  return { cfg = { split = "below", height = math.max(12, math.floor(lines * 0.4)) }, fix = "winfixheight" }
end

-- card: the HUD float — preferred 72×28, editor-clamped (S3)
function M.card_dims(cols, lines)
  cols, lines = cols or vim.o.columns, lines or vim.o.lines
  return math.min(72, math.max(40, cols - 6)), math.min(28, math.max(10, lines - 4))
end

-- reading-pane: the doc float — right-edge, readable measure (docview's formula, codified;
-- returns w, h, row, col)
function M.reading_pane(cols, lines)
  cols, lines = cols or vim.o.columns, lines or vim.o.lines
  local w = math.min(110, math.max(60, math.floor(cols * 0.55)))
  local h = math.floor(lines * 0.72)
  return w, h, math.max(1, math.floor((lines - h) / 2) - 1), cols - w - 2
end

-- pin split width (docview persistence — the operator's docs+code layout)
function M.pin_width(cols)
  return math.max(60, math.floor((cols or vim.o.columns) * 0.42))
end

-- fuzzy-picker float: prompt row stacked on a result list, upper-third, content-driven width
-- CLAMPED (S1 law — a row must never wrap out of the row count). Returns w, h, row, col.
function M.fzf_dims(cols, lines, want_w)
  cols, lines = cols or vim.o.columns, lines or vim.o.lines
  local w = math.min(math.max(want_w or 64, 48), cols - 8)
  local h = math.min(18, math.max(6, lines - 10))
  local row = math.max(1, math.floor(lines * 0.16))
  return w, h, row, math.max(0, math.floor((cols - w) / 2))
end

-- ── the plugin's OWN output log (operator 2026-08-14: "outputs shouldn't need :Noice") ──────
-- Every notify_raw ALSO lands in this ring; <leader>dn / the menu row opens the float —
-- newest first (recency-as-rule §11(iii)), level-iconed, persistent until q. The toast stays
-- for the moment it fires; the LOG is where you read what you missed, without leaving the
-- plugin's own surfaces.
M._ring = {}
local RING_CAP = 200
local ICON = {}
ICON[vim.log.levels.ERROR] = "✗"
ICON[vim.log.levels.WARN] = "⚠"
ICON[vim.log.levels.INFO] = "·"

-- pure: ring → display lines, newest first; honest empty state.
function M._render_ring(ring)
  local lines = {}
  for i = #ring, 1, -1 do
    local e = ring[i]
    lines[#lines + 1] = ("  %s %s  %s"):format(e.time, ICON[e.level] or "·", e.msg)
  end
  if #lines == 0 then lines[1] = "  (no fox-symdeps output yet this session)" end
  return lines
end

function M.output()
  local lines = M._render_ring(M._ring)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden = "wipe"
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  local w, h, row, col = M.reading_pane()
  local win = vim.api.nvim_open_win(buf, true, {
    relative = "editor", row = row, col = col, width = w, height = h,
    border = "rounded", title = "  fox-symdeps · output (newest first) · q closes ", title_pos = "left",
  })
  vim.wo[win].winhighlight = "Normal:FoxSymdepsNormal"
  vim.keymap.set("n", "q", function() pcall(vim.api.nvim_win_close, win, true) end,
                 { buffer = buf, nowait = true, desc = "fox-symdeps: close the log" })
  vim.keymap.set("n", "?", function() M.buffer_help(buf) end,
                 { buffer = buf, nowait = true, desc = "fox-symdeps: this help (derived from the keys themselves)" })
end

-- ── `?` help for CARD surfaces (operator 2026-08-14) — DERIVED from the buffer's OWN keymaps:
-- the `desc` strings the keys register with ARE the SSoT (fleet-K4 applied to buffer-local
-- keys). A new key self-registers into its card's help; nothing is hand-copied, ever.
function M._help_lines(maps)
  local rows = {}
  for _, m in ipairs(maps or {}) do
    if m.desc and m.desc:find("fox%-symdeps") then
      rows[#rows + 1] = { lhs = m.lhs or "?", txt = (m.desc:gsub("^fox%-symdeps:%s*", "")) }
    end
  end
  table.sort(rows, function(a, b) return a.lhs < b.lhs end)
  local lines = {}
  for _, r in ipairs(rows) do
    lines[#lines + 1] = ("  %-6s %s"):format(r.lhs, r.txt)
  end
  if #lines == 0 then lines[1] = "  (no keys registered here)" end
  return lines
end

function M.buffer_help(buf)
  local lines = M._help_lines(vim.api.nvim_buf_get_keymap(buf, "n"))
  local w = 0
  for _, l in ipairs(lines) do w = math.max(w, vim.fn.strdisplaywidth(l)) end
  local b = vim.api.nvim_create_buf(false, true)
  vim.bo[b].bufhidden = "wipe"
  vim.api.nvim_buf_set_lines(b, 0, -1, false, lines)
  vim.bo[b].modifiable = false
  local win = vim.api.nvim_open_win(b, true, {
    relative = "cursor", row = 1, col = 1, width = math.min(w + 2, vim.o.columns - 4),
    height = #lines, border = "rounded", title = "  keys here ", title_pos = "left",
  })
  vim.wo[win].winhighlight = "Normal:FoxSymdepsNormal"
  local function close() pcall(vim.api.nvim_win_close, win, true) end
  vim.keymap.set("n", "q", close, { buffer = b, nowait = true })
  vim.keymap.set("n", "<Esc>", close, { buffer = b, nowait = true })
  vim.api.nvim_create_autocmd("WinLeave", { buffer = b, once = true, callback = close })
end

-- the output-log float gains ? too (self-describing surfaces, everywhere)

-- ── fuzzy_pick — the fzf-style live picker (operator 2026-08-18: "the things that pull up a
-- search bar for browsing tags and vocab … would be better used as like a fzf pop up"). ONE
-- surface: a prompt line stacked on a live-narrowing result list — type = filter,
-- <CR> = pick the selected row, <C-n>/<C-p>/<Down>/<Up>/<Tab> = move, <Esc> = cancel.
-- Matching is vim.fn.matchfuzzypos (nvim built-in) — zero new dependencies, so the pickers
-- stop riding whatever happens to back vim.ui.select. Two modes:
--   static — opts.items filtered locally (structs / tags / vocab);
--   live   — opts.live(query, update) re-queries a source per keystroke, debounced (roam:
--            clangd does the matching server-side; the list shows what it returned).

-- pure: (items, query, format) → { {item, text, pos={cols}}, … }. Empty query = every item in
-- original order; otherwise matchfuzzypos order (score-desc) with matched-char positions.
function M._fuzzy_filter(items, query, format)
  format = format or function(it)
    return type(it) == "table" and (it.label or it.name or "?") or tostring(it)
  end
  local rows = {}
  for i, it in ipairs(items or {}) do rows[#rows + 1] = { text = format(it), i = i } end
  if not query or query == "" then
    local out = {}
    for _, r in ipairs(rows) do out[#out + 1] = { item = items[r.i], text = r.text, pos = {} } end
    return out
  end
  local ok, res = pcall(vim.fn.matchfuzzypos, rows, query, { key = "text" })
  if not ok or type(res) ~= "table" or not res[1] then return {} end
  local out = {}
  for k, r in ipairs(res[1]) do
    out[#out + 1] = { item = items[r.i], text = r.text, pos = res[2] and res[2][k] or {} }
  end
  return out
end

-- fuzzy_pick(opts): opts = { title?, items? | live(query, update)?, format(item)→string?,
-- on_choice(item|nil), palette?, hint?, start? }. on_choice(nil) = cancelled.
-- BROWSE-FIRST (operator 2026-08-19: "i just dont wanna have to type anything when browsing
-- tags and stuff"): static pickers open in NORMAL mode — j/k move, <CR>/l picks, q/<Esc>
-- cancels, and i / / / a drop into the filter only when wanted; <Esc> in the filter returns
-- to browsing (filter kept), <C-c> cancels outright. Live pickers (roam) default to the
-- filter — they are queries by nature. opts.start = "browse" | "filter" overrides.
function M.fuzzy_pick(opts)
  opts = opts or {}
  pcall(vim.api.nvim_set_hl, 0, "FoxSymdepsFzfMatch", { default = true, link = "Special" })
  pcall(vim.api.nvim_set_hl, 0, "FoxSymdepsDim", { default = true, link = "Comment" })
  local NSF = vim.api.nvim_create_namespace("fox_symdeps_fuzzy")
  local prev_win = vim.api.nvim_get_current_win()
  local items = opts.items or {}
  local rows = M._fuzzy_filter(items, "", opts.format)

  local want = (opts.title and #opts.title + 12) or 48
  for _, r in ipairs(rows) do want = math.max(want, vim.fn.strdisplaywidth(r.text) + 4) end
  local w, h, row, col = M.fzf_dims(nil, nil, want)

  local rbuf = vim.api.nvim_create_buf(false, true); vim.bo[rbuf].bufhidden = "wipe"
  local pbuf = vim.api.nvim_create_buf(false, true); vim.bo[pbuf].bufhidden = "wipe"
  vim.bo[pbuf].buftype = "prompt"
  vim.fn.prompt_setprompt(pbuf, "  ")
  -- LAYER-STACK marker (operator rule 2026-08-10): an open HUD/board stays alive under its picker.
  vim.b[pbuf].fox_symdeps_menu = true
  vim.b[rbuf].fox_symdeps_menu = true

  local border_hl = ""
  if opts.palette and opts.palette.border then
    pcall(vim.api.nvim_set_hl, 0, "FoxSymdepsFzfBorder", { fg = opts.palette.border })
    border_hl = ",FloatBorder:FoxSymdepsFzfBorder,FloatTitle:FoxSymdepsFzfBorder"
  end
  local rwin = vim.api.nvim_open_win(rbuf, false, {
    relative = "editor", row = row + 3, col = col, width = w, height = h,
    style = "minimal", border = "rounded",
  })
  vim.wo[rwin].wrap = false
  vim.wo[rwin].cursorline = true
  vim.wo[rwin].cursorlineopt = "line"
  vim.wo[rwin].winhighlight = "CursorLine:FoxSymdepsSelection" .. border_hl
  local pwin = vim.api.nvim_open_win(pbuf, true, {
    relative = "editor", row = row, col = col, width = w, height = 1,
    style = "minimal", border = "rounded",
    title = opts.title and (" " .. opts.title .. " ") or nil,
    title_pos = opts.title and "center" or nil,
  })
  vim.wo[pwin].winhighlight = "Normal:FoxSymdepsNormal" .. border_hl

  local sel, closed, gen = 1, false, 0
  local function render()
    local lines, n = {}, math.min(#rows, 500)
    for k = 1, n do lines[k] = "  " .. rows[k].text end
    if #rows == 0 then lines[1] = "  " .. (opts.hint or "(no matches)") end
    vim.bo[rbuf].modifiable = true
    vim.api.nvim_buf_set_lines(rbuf, 0, -1, false, lines)
    vim.bo[rbuf].modifiable = false
    vim.api.nvim_buf_clear_namespace(rbuf, NSF, 0, -1)
    for k = 1, n do
      for _, p in ipairs(rows[k].pos or {}) do
        pcall(vim.api.nvim_buf_set_extmark, rbuf, NSF, k - 1, p + 2,
          { end_col = p + 3, hl_group = "FoxSymdepsFzfMatch" })
      end
    end
    if #rows == 0 then
      pcall(vim.api.nvim_buf_set_extmark, rbuf, NSF, 0, 0,
        { end_col = #lines[1], hl_group = "FoxSymdepsDim" })
    end
    sel = math.min(math.max(sel, 1), math.max(#rows, 1))
    pcall(vim.api.nvim_win_set_cursor, rwin, { math.min(sel, math.max(#rows, 1)), 0 })
    pcall(vim.api.nvim_win_set_config, pwin,
      { title = (" %s · %d "):format(opts.title or "pick", #rows), title_pos = "center" })
  end

  local function query_text()
    local l = vim.api.nvim_buf_get_lines(pbuf, 0, -1, false)[1] or ""
    return l:sub(#vim.fn.prompt_getprompt(pbuf) + 1)
  end
  local function refilter()
    if closed then return end
    local q = query_text()
    if opts.live then
      gen = gen + 1
      local g = gen
      vim.defer_fn(function()
        if closed or g ~= gen then return end
        opts.live(q, function(new_items)
          if closed or g ~= gen then return end
          items = new_items or {}
          rows = M._fuzzy_filter(items, "", opts.format) -- the live source already matched
          sel = 1
          render()
        end)
      end, 120)
    else
      rows = M._fuzzy_filter(items, q, opts.format)
      sel = 1
      render()
    end
  end
  vim.api.nvim_create_autocmd({ "TextChangedI", "TextChanged" }, { buffer = pbuf, callback = refilter })

  local function close(choice)
    if closed then return end
    closed = true
    pcall(vim.api.nvim_win_close, pwin, true)
    pcall(vim.api.nvim_win_close, rwin, true)
    vim.cmd("stopinsert")
    pcall(vim.api.nvim_set_current_win, prev_win)
    if opts.on_choice then vim.schedule(function() opts.on_choice(choice) end) end
  end
  local function confirm() close(rows[sel] and rows[sel].item or nil) end
  vim.fn.prompt_setcallback(pbuf, confirm) -- <CR> in a prompt buffer fires this
  local function move(d)
    if #rows == 0 then return end
    sel = ((sel - 1 + d) % #rows) + 1
    pcall(vim.api.nvim_win_set_cursor, rwin, { sel, 0 })
  end
  for lhs, d in pairs({ ["<C-n>"] = 1, ["<Down>"] = 1, ["<Tab>"] = 1,
                        ["<C-p>"] = -1, ["<Up>"] = -1, ["<S-Tab>"] = -1 }) do
    vim.keymap.set("i", lhs, function() move(d) end, { buffer = pbuf, nowait = true })
  end
  -- filter-mode exits: <Esc> RETURNS TO BROWSE (filter kept — never a surprise close); <C-c> cancels
  vim.keymap.set("i", "<Esc>", function() vim.cmd("stopinsert") end, { buffer = pbuf, nowait = true })
  vim.keymap.set("i", "<C-c>", function() close(nil) end, { buffer = pbuf, nowait = true })
  -- browse mode (normal): the menu's own muscle memory
  for lhs, d in pairs({ j = 1, k = -1, ["<Down>"] = 1, ["<Up>"] = -1 }) do
    vim.keymap.set("n", lhs, function() move(d) end, { buffer = pbuf, nowait = true })
  end
  vim.keymap.set("n", "<C-d>", function() move(5) end, { buffer = pbuf, nowait = true })
  vim.keymap.set("n", "<C-u>", function() move(-5) end, { buffer = pbuf, nowait = true })
  for _, k in ipairs({ "<CR>", "l" }) do
    vim.keymap.set("n", k, confirm, { buffer = pbuf, nowait = true })
  end
  for _, k in ipairs({ "i", "a", "/" }) do
    vim.keymap.set("n", k, function() vim.cmd("startinsert!") end, { buffer = pbuf, nowait = true })
  end
  for _, k in ipairs({ "q", "<Esc>" }) do
    vim.keymap.set("n", k, function() close(nil) end, { buffer = pbuf, nowait = true })
  end
  vim.api.nvim_create_autocmd("WinLeave", { buffer = pbuf, once = true, callback = function() close(nil) end })
  render()
  if (opts.start or (opts.live and "filter" or "browse")) == "filter" then
    vim.cmd("startinsert!")
  end
  if opts.live then refilter() end -- fire the initial (empty) live query → hint state

  -- programmatic handle: the SAME functions the keys map to, callable without keystrokes —
  -- the test seam (headless -l cannot drive insert-mode typeahead; test_fuzzy_live rides
  -- this) and the hook for pre-seeded queries later. set_query writes the prompt line and
  -- refilters exactly as typing would.
  return {
    set_query = function(q)
      if closed then return end
      local pr = vim.fn.prompt_getprompt(pbuf)
      vim.bo[pbuf].modifiable = true
      vim.api.nvim_buf_set_lines(pbuf, 0, -1, false, { pr .. (q or "") })
      refilter()
    end,
    move = move, confirm = confirm, cancel = function() close(nil) end,
    is_open = function() return not closed end,
  }
end

-- ONE notification voice (operator polish #4): every plugin notification routes through here —
-- the `fox-symdeps · ` prefix is applied exactly once (call sites that already carry it keep
-- their text; bare ones gain it), so the product speaks with one voice everywhere.
function M.notify_raw(msg, level, opts)
  if type(msg) == "string" and not msg:match("^fox%-symdeps") then
    msg = "fox-symdeps · " .. msg
  end
  M._ring[#M._ring + 1] = { time = os.date("%H:%M:%S"),
                            level = level or vim.log.levels.INFO,
                            msg = type(msg) == "string" and msg:gsub("\n", " ⏎ ") or tostring(msg) }
  if #M._ring > RING_CAP then table.remove(M._ring, 1) end
  vim.notify(msg, level, opts)
end

return M
