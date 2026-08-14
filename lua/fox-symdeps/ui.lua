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
