-- tagcursor.lua — cursor-tracking by ENCLOSING UNIT (north-star §6's foundational primitive:
-- "most current HUD/panel functionality reworks around this"). Debounced cursor-follow + a
-- per-buffer cache, so the enclosing unit is a cheap ambient fact every surface (HUD · panel ·
-- statusline · context-gated menus) reads instead of re-deriving.
--
-- DESIGN (T1 honored, no second parser): LIVE resolution routes through the EXISTING
-- tagcontext.enclosing_block() — a buffer scan, zero subprocess per cursor move, correct against
-- UNSAVED edits (which a disk parse can never be). The [TAG] list is read from the block's own
-- `// [TAG]_[..]` header line (syntax match only; the VOCAB stays foxtag-derived per T2 — this
-- file defines no grammar). `foxtag unit <file> <line>` remains the DISK-authoritative resolver
-- (contract proven 2026-08-09: FUNCTION ExecutionCore_Init 263-318 [ENGINE][BOOT_TIME]) — the
-- cross-check/enrichment seam for on-save features, NOT the per-cursor-move path. foxtag is
-- CWD-SENSITIVE (Landmine 5): any subprocess use inherits nodemodel.lua's engine-root discipline.
--
--   M.get(buf?)      -> unit | nil       cached resolve at the current cursor (never spawns)
--   M.statusline()   -> "[FUNCTION ExecutionCore_Init] [ENGINE][BOOT_TIME]" | ""
--   M.enable(opts?)  -> autocmd attach on *.hpp/*.cpp: debounced follow, vim.b.fox_unit,
--                       User FoxUnitChanged autocmd on unit transitions
--   :FoxUnit          one-shot echo of the enclosing unit (works without enable())
--
-- Cache: keyed on (changedtick, opener..closer span). Cursor motion INSIDE a unit is a pure
-- table hit; any buffer edit invalidates via changedtick — no stale spans after line shifts.
local M = {}

local uv = vim.uv or vim.loop
local AUG = vim.api.nvim_create_augroup("fox_symdeps_tagcursor", { clear = true })

-- per-buffer: { tick, lo, hi, unit|false }  (false = resolved-to-nothing, still cacheable)
local cache = {}

local function buf_line(buf, i)
  return vim.api.nvim_buf_get_lines(buf, i, i + 1, false)[1] or ""
end

-- The block's [TAG] list, read from its header region (opener → first [CODE]/closer). Syntax
-- match only — the value set is foxtag's business, not ours.
local function block_tags(buf, blk)
  for i = blk.opener, math.min(blk.closer, blk.opener + 40) do
    local l = buf_line(buf, i)
    local inner = l:match("//%s*%[TAG%]_%[(.+)%]%s*$")
    if inner then
      local tags = {}
      for t in inner:gmatch("%[?([%u_]+)%]?") do tags[#tags + 1] = t end
      return tags
    end
    if l:match("//%s*%[CODE%]") then break end -- header region ended tagless
  end
  return {}
end

local function resolve(buf, row0)
  local blk, err = require("fox-symdeps.tagcontext").enclosing_block(buf, row0)
  if err == "no-model" then return nil end -- foxtag unavailable: silent here; health.lua owns the heal
  if not blk then return nil end
  return {
    type = blk.type, name = blk.name,
    open_line = blk.opener + 1, close_line = blk.closer + 1, -- 1-based, matching foxtag unit_json
    tags = block_tags(buf, blk),
  }
end

--- Cached enclosing unit at the cursor. Pure read on the hot path; resolves at most once per
--- (edit, unit-span) pair.
function M.get(buf)
  buf = buf or vim.api.nvim_get_current_buf()
  local row0 = vim.api.nvim_win_get_cursor(0)[1] - 1
  local tick = vim.api.nvim_buf_get_var(buf, "changedtick")
  local c = cache[buf]
  if c and c.tick == tick and row0 >= c.lo and row0 <= c.hi then return c.unit or nil end
  local unit = resolve(buf, row0)
  if unit then
    cache[buf] = { tick = tick, lo = unit.open_line - 1, hi = unit.close_line - 1, unit = unit }
  else
    -- Cache the miss for THIS row only: between-blocks motion stays cheap, but entering a real
    -- block one line down must re-resolve (a wide negative span would swallow neighbors).
    cache[buf] = { tick = tick, lo = row0, hi = row0, unit = false }
  end
  return unit
end

--- "[FUNCTION ExecutionCore_Init] [ENGINE][BOOT_TIME]" — for statusline/winbar consumers.
function M.statusline()
  local u = M.get()
  if not u then return "" end
  local t = #u.tags > 0 and (" [" .. table.concat(u.tags, "][") .. "]") or ""
  return ("[%s %s]%s"):format(u.type, u.name, t)
end

-- Debounced follow: on motion, after `debounce_ms` of quiet, re-read the cached unit; announce
-- transitions via vim.b.fox_unit + the User autocmd so HUD/panel/statusline consume passively.
local timer, last_key = nil, nil

local function announce(buf)
  local u = M.get(buf)
  local key = u and (u.type .. "|" .. u.name .. "|" .. u.open_line) or ""
  if key == last_key then return end
  last_key = key
  vim.b[buf].fox_unit = u
  vim.api.nvim_exec_autocmds("User", { pattern = "FoxUnitChanged", data = { unit = u } })
end

function M.enable(opts)
  opts = opts or {}
  local ms = opts.debounce_ms or 150
  vim.api.nvim_clear_autocmds({ group = AUG })
  vim.api.nvim_create_autocmd({ "CursorMoved", "CursorMovedI" }, {
    group = AUG, pattern = "*",
    callback = function(ev)
      local name = vim.api.nvim_buf_get_name(ev.buf)
      if not (name:match("%.hpp$") or name:match("%.cpp$")) then return end
      if timer then timer:stop() end
      timer = timer or uv.new_timer()
      timer:start(ms, 0, vim.schedule_wrap(function()
        if vim.api.nvim_buf_is_valid(ev.buf) then announce(ev.buf) end
      end))
    end,
  })
  vim.api.nvim_create_autocmd("BufDelete", {
    group = AUG, pattern = "*",
    callback = function(ev) cache[ev.buf] = nil end,
  })
end

vim.api.nvim_create_user_command("FoxUnit", function()
  local u = M.get()
  if u then
    vim.notify(M.statusline() .. ("  (%d–%d)"):format(u.open_line, u.close_line))
  else
    vim.notify("[fox-symdeps] cursor is not inside a tagged unit", vim.log.levels.INFO)
  end
end, { desc = "Show the enclosing tagged unit at the cursor" })

return M
