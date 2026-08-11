-- tagcontext.lua — resolve the unit from the ENCLOSING [TAG]_ block, so tag features work with the
-- cursor ANYWHERE between a `[<TYPE>]_[<name>]` opener and its `[END_<TYPE>]` — not only when it sits
-- on the symbol. The [DERIVED] generator, a future drift-verify, and navigation all route through this.
--
--   enclosing_block(buf,row0) -> { type, name, opener, closer } | nil   (pure; block detection)
--   resolve()                 -> ctx (as context.under_cursor) | nil    (symbol facts, cursor-tolerant)
local M = {}

-- RETIRED (E.1.2.B 0.3, soak-then-delete per D-349): this hardcoded copy is NO LONGER the authority —
-- the node model is derived from `foxtag grammar --json` via nodemodel.lua. Kept in-tree only for the
-- soak window; delete once the plugin parity section has passed NON-SKIPPED and the derived path has
-- been dogfooded. It is retained as evidence of exactly why deriving matters: it is missing ASSERT,
-- and it wrongly lists FILE/MACRO — units that carry NO [END_<TYPE>] closer.
local _RETIRED_UNIT = { FUNCTION = true, STRUCT = true, REGISTRY = true, FILE = true,
                        TYPE = true, ENUM = true, STRATEGY = true, MACRO = true, TEST = true }
local _ = _RETIRED_UNIT

local function line(buf, i) return vim.api.nvim_buf_get_lines(buf, i, i + 1, false)[1] or "" end

-- The enclosing unit block for the cursor at row0 (0-indexed). Scan UP: a scope-CLOSER hit first means
-- the cursor sits between blocks (nil); a scope-OPENER hit first means we're inside it. Non-unit tag
-- lines ([TAG]/[SCHEMA]/[CODE]/[DERIVED]/[END_CODE]) and code are skipped.
--
-- Openers are the CLOSABLE units only (nodemodel.scope_openers(), derived from foxtag). A LIGHT unit —
-- FILE / MACRO / TEST / ASSERT — is a point marker with NO [END_<TYPE>]; treating one as an opener
-- makes the inner scan run to the buffer end and abort the whole search. That was a live bug for
-- FILE/MACRO (a cursor in a file header resolved to nil), and inside-block [ASSERT] (canonical per
-- D-340) would have extended it to every unit containing an assert. Skip-and-keep-scanning instead.
--
-- Returns (blk|nil, err) — err == "no-model" means foxtag is unavailable, so the caller can offer the
-- one-keypress heal rather than reporting a misleading "not in a tagged unit".
function M.enclosing_block(buf, row0)
  local openers = require("fox-symdeps.nodemodel").scope_openers()
  if not openers then return nil, "no-model" end
  for i = row0, 0, -1 do
    local l = line(buf, i)
    local et = l:match("//%s*%[END_(%u+)%]")
    if et and openers[et] then return nil end -- closer first → between blocks
    -- name class is [^%]] not [%w_]: per-instantiation unit names carry angle-form
    -- (`[STRUCT]_[FixedPoint<2,64>]`) — the old class rejected `<`/`,`/`>`, so the WHOLE
    -- unit failed to resolve on those blocks (generic palette, no type-gated rows — operator
    -- screenshot 2026-08-10). Only opener TYPES act on this capture, so widening is safe.
    local ty, nm = l:match("//%s*%[(%u+)%]_%[([^%]]+)%]")
    if ty and openers[ty] then -- opener first → inside it; confirm the matching closer is at/below cursor
      local n = vim.api.nvim_buf_line_count(buf)
      for j = i + 1, math.min(n - 1, i + 2000) do
        if line(buf, j):match("//%s*%[END_" .. ty .. "%]") then
          return (j >= row0) and { type = ty, name = nm, opener = i, closer = j } or nil
        end
      end
      return nil
    end
    -- a non-closable unit line ([FILE]/[MACRO]/[TEST]/[ASSERT]) is NOT an opener → keep scanning up
  end
  return nil
end

-- Locate the block's declared symbol inside its [CODE] region → { row1, col0 } | nil.
local function symbol_pos(buf, blk)
  local cs, ce
  for i = blk.opener, blk.closer do
    local l = line(buf, i)
    if not cs and l:match("//%s*%[CODE%]") then cs = i end
    if cs and l:match("//%s*%[END_CODE%]") then ce = i; break end
  end
  if not cs then return nil end
  ce = ce or blk.closer
  local pat = "%f[%w_]" .. blk.name:gsub("(%W)", "%%%1") .. "%f[^%w_]" -- whole-word, escaped
  for i = cs + 1, ce - 1 do
    local s = line(buf, i):find(pat)
    if s then return { row1 = i + 1, col0 = s - 1 } end
  end
  return nil
end

-- UNIT-FIRST resolution (§6 board/follow semantics): the ENCLOSING unit's declared symbol wins
-- over whatever word happens to sit under the cursor — the board adds the unit you are IN, and
-- the follow card follows unit TRANSITIONS, never the words the cursor passes over (following
-- words is precisely the swapped-out-from-under-you behavior the old panel kind-filter fought).
-- Falls back to word-under-cursor only OUTSIDE any tagged unit. resolve() below stays word-first
-- for the point-at-a-thing HUD.
function M.resolve_unit()
  local buf = vim.api.nvim_get_current_buf()
  local row0 = vim.api.nvim_win_get_cursor(0)[1] - 1
  local blk = M.enclosing_block(buf, row0)
  if blk then
    local pos = symbol_pos(buf, blk)
    if pos then
      local save = vim.api.nvim_win_get_cursor(0)
      local ok = pcall(vim.api.nvim_win_set_cursor, 0, { pos.row1, pos.col0 })
      local rctx = ok and require("fox-symdeps.context").under_cursor() or nil
      pcall(vim.api.nvim_win_set_cursor, 0, save) -- ALWAYS restore
      if rctx then return rctx end
    end
  end
  return require("fox-symdeps.context").under_cursor()
end

-- Resolve a full ctx (symbol/kind/container/is_template) for the unit at the cursor, tolerating a
-- cursor that isn't on the symbol. Fast path = the plain resolve; fallback = read the block + resolve
-- at the symbol in [CODE] (temporarily, cursor restored). Returns a ctx table | nil.
function M.resolve()
  local ctxmod = require("fox-symdeps.context")
  local direct = ctxmod.under_cursor()
  if direct then return direct end
  local buf = vim.api.nvim_get_current_buf()
  local row0 = vim.api.nvim_win_get_cursor(0)[1] - 1
  local blk = M.enclosing_block(buf, row0)
  if not blk then return nil end
  local pos = symbol_pos(buf, blk)
  if not pos then return nil end
  local save = vim.api.nvim_win_get_cursor(0)
  local ok = pcall(vim.api.nvim_win_set_cursor, 0, { pos.row1, pos.col0 })
  local rctx = ok and ctxmod.under_cursor() or nil
  pcall(vim.api.nvim_win_set_cursor, 0, save) -- ALWAYS restore
  return rctx
end

return M
