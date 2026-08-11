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

-- ONE notification voice (operator polish #4): every plugin notification routes through here —
-- the `fox-symdeps · ` prefix is applied exactly once (call sites that already carry it keep
-- their text; bare ones gain it), so the product speaks with one voice everywhere.
function M.notify_raw(msg, level, opts)
  if type(msg) == "string" and not msg:match("^fox%-symdeps") then
    msg = "fox-symdeps · " .. msg
  end
  vim.notify(msg, level, opts)
end

return M
