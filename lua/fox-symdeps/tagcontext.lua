-- tagcontext.lua — resolve the unit from the ENCLOSING [TAG]_ block, so tag features work with the
-- cursor ANYWHERE between a `[<TYPE>]_[<name>]` opener and its `[END_<TYPE>]` — not only when it sits
-- on the symbol. The [DERIVED] generator, a future drift-verify, and navigation all route through this.
--
--   enclosing_block(buf,row0) -> { type, name, opener, closer } | nil   (pure; block detection)
--   resolve()                 -> ctx (as context.under_cursor) | nil    (symbol facts, cursor-tolerant)
local M = {}

local UNIT = { FUNCTION = true, STRUCT = true, REGISTRY = true, FILE = true,
               TYPE = true, ENUM = true, STRATEGY = true, MACRO = true, TEST = true }

local function line(buf, i) return vim.api.nvim_buf_get_lines(buf, i, i + 1, false)[1] or "" end

-- The enclosing unit block for the cursor at row0 (0-indexed). Scan UP: a unit-CLOSER hit first means
-- the cursor sits between blocks (nil); a unit-OPENER hit first means we're inside it. Non-unit tag
-- lines ([TAG]/[SCHEMA]/[CODE]/[DERIVED]/[END_CODE]) and code are skipped — only [END_CODE] is NOT a
-- unit closer (UNIT has no CODE), so a cursor in [DERIVED] still resolves up to its opener.
function M.enclosing_block(buf, row0)
  for i = row0, 0, -1 do
    local l = line(buf, i)
    local et = l:match("//%s*%[END_(%u+)%]")
    if et and UNIT[et] then return nil end -- closer first → between blocks
    local ty, nm = l:match("//%s*%[(%u+)%]_%[([%w_]+)%]")
    if ty and UNIT[ty] then -- opener first → inside it; confirm the matching closer is at/below cursor
      local n = vim.api.nvim_buf_line_count(buf)
      for j = i + 1, math.min(n - 1, i + 2000) do
        if line(buf, j):match("//%s*%[END_" .. ty .. "%]") then
          return (j >= row0) and { type = ty, name = nm, opener = i, closer = j } or nil
        end
      end
      return nil
    end
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
