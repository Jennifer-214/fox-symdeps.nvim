-- tagwriter.lua — the GENERATOR half of the [TAG]_ seam: write the tool-owned [DERIVED] block
-- back INTO the source, in place. The preview (:FoxSymdepsDerived) shows every live fact; THIS
-- writes only the STABLE subset so the committed source never carries a lie.
--
-- Stable (WRITTEN):   [UPSTREAM] / [CONSUMERS]  — clangd call-graph, reliable across compiles.
-- Volatile (PREVIEW): instr-count / simd        — flip with -O/-march, and are 0/meaningless for an
--                                                 un-instantiated template. Never written.
-- (Struct byte-layout — [SIZE]/[ALIGN]/[STRADDLE] — is the cache-gate's path: check_cache_layout --fix.)
local M = {}

-- the stable, writable facts as codified [DERIVED] lines (call-graph only).
local function stable_lines(facts)
  local L = {}
  if facts.dep_chain and #facts.dep_chain > 0 then
    L[#L + 1] = ("// [UPSTREAM]_[[%s]]"):format(table.concat(facts.dep_chain, "] ["))
  end
  if facts.consumers and #facts.consumers > 0 then
    L[#L + 1] = ("// [CONSUMERS]_[[%s]]"):format(table.concat(facts.consumers, "] ["))
  end
  return L
end

-- Locate the [DERIVED] fact region for the unit at/below cursor_row0 (0-indexed). Returns s,e
-- (0-indexed, half-open) of the fact lines — between the [DERIVED] '//----' separator and the
-- closing '//====' bar. nil if the unit has no [DERIVED] block (convert it first).
local function fact_range(buf, cursor_row0)
  local n = vim.api.nvim_buf_line_count(buf)
  local function line(i) return vim.api.nvim_buf_get_lines(buf, i, i + 1, false)[1] or "" end
  local d
  for i = cursor_row0, math.min(n - 1, cursor_row0 + 800) do
    local l = line(i)
    if l:find("%[DERIVED%]") then d = i; break end
    -- stop at the UNIT terminator ([END_FUNCTION]/[END_STRUCT]/…) — but NOT [END_CODE], which
    -- sits between the body and the [DERIVED] block.
    if l:find("%[END_") and not l:find("%[END_CODE%]") then return nil end
  end
  if not d then return nil end
  local s = d + 2 -- [DERIVED] header, then the '//----' separator, then the facts
  for i = s, math.min(n - 1, d + 60) do
    if line(i):find("^%s*//=+%s*$") then return s, i end -- facts end at the '//====' bar
  end
  return nil
end

-- Write the plugin-owned stable [DERIVED] facts for the unit at the cursor, in place — MERGING, not
-- clobbering: keep the cache-gate's filled layout facts ([SIZE]/[ALIGN]/[STRADDLE]), drop the old
-- call-graph + any unfilled '<tool:' placeholder, append the fresh [UPSTREAM]/[CONSUMERS].
-- Returns: #call-graph lines written · 0 (none to write) · nil (no [DERIVED] block found).
function M.write(buf, cursor_row0, facts)
  local new = stable_lines(facts)
  -- seed the [DERIVED] search from the enclosing block's opener (cursor may be anywhere in the block,
  -- even inside/below [DERIVED]); fall back to the cursor row if we're not inside a tagged unit.
  local blk = require("fox-symdeps.tagcontext").enclosing_block(buf, cursor_row0)
  local s, e = fact_range(buf, blk and blk.opener or cursor_row0)
  if not s then return nil end
  local kept = {}
  for _, l in ipairs(vim.api.nvim_buf_get_lines(buf, s, e, false)) do
    local drop = l:find("%[UPSTREAM%]") or l:find("%[CONSUMERS%]") or l:find("<tool") -- call-graph or placeholder
    if not drop then kept[#kept + 1] = l end -- keep filled layout facts (struct [SIZE]/[ALIGN]/…)
  end
  if #kept == 0 and #new == 0 then return 0 end
  local merged = {}
  vim.list_extend(merged, kept)
  vim.list_extend(merged, new)
  vim.api.nvim_buf_set_lines(buf, s, e, false, merged)
  return #new
end

M._fact_range = fact_range -- exposed for the headless test
return M
