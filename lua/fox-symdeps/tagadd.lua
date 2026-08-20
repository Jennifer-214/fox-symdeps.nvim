-- tagadd.lua — TAG ADD (operator idea, ideas §11(ii) 2026-08-10): browse the REAL vocab —
-- the concern + surface tables the grammar payload already emits (§9's law: the picker
-- DERIVES, never invents) — and merge the pick into the unit's orient-tier [TAG] line.
-- ✎ tier: writes a tag-comment only; the buffer is edited, you save. MERGE-ONLY v1: a unit
-- with no [TAG] line yet is NAMED, never format-guessed. New-vocab minting routes through
-- the SSoT (tools/add_vocab.py → schema fence + vocabulary doc) — never plugin-local.
local M = {}

-- pure: a `[TAG]_[[A] [B]]` (or single `[TAG]_[A]`) line + token → merged line, indent
-- preserved, deduped (returns the SAME line when the token is already present — idempotent);
-- nil = not a [TAG] line.
function M.merge_tag_line(line, token)
  local pre, val = line:match("^(%s*//%s*)%[TAG%]_%[(.+)%]%s*$")
  if not pre then return nil end
  local toks, seen = {}, {}
  for t in val:gmatch("%[([^%[%]]+)%]") do
    if not seen[t] then seen[t] = true; toks[#toks + 1] = t end
  end
  if #toks == 0 then
    local bare = val:match("^%s*(.-)%s*$")
    if bare ~= "" then seen[bare] = true; toks[1] = bare end
  end
  if seen[token] then return line end
  toks[#toks + 1] = token
  return ("%s[TAG]_[[%s]]"):format(pre, table.concat(toks, "] ["))
end

-- pure: block lines → 1-based index of the ORIENT-tier [TAG] line (stops at [CODE] — the
-- same tier discipline as THREAD/STRADDLE_EXEMPT) or nil.
function M.find_tag_line(lines)
  for i, l in ipairs(lines) do
    if l:match("^%s*//%s*%[CODE%]") then return nil end
    if l:match("^%s*//%s*%[TAG%]_%[") then return i end
  end
  return nil
end

function M.add(ctx)
  local ui = require("fox-symdeps.ui")
  local okt, tc = pcall(require, "fox-symdeps.tagcontext")
  if not okt then return end
  local buf = (ctx and ctx.bufnr) or vim.api.nvim_get_current_buf()
  local row0 = (ctx and ctx.line and (ctx.line - 1)) or (vim.api.nvim_win_get_cursor(0)[1] - 1)
  local blk = tc.enclosing_block(buf, row0)
  if not blk then
    return ui.notify_raw("TAG ADD: not inside a tagged unit", vim.log.levels.INFO)
  end
  local lines = vim.api.nvim_buf_get_lines(buf, blk.opener, blk.closer + 1, false)
  local rel = M.find_tag_line(lines)
  if not rel then
    return ui.notify_raw("TAG ADD: " .. (blk.name or "unit")
      .. " has no orient [TAG] line yet — merge-only, no format guessing", vim.log.levels.WARN)
  end
  local vocab = require("fox-symdeps.nodemodel").vocab()
  if not (vocab and (vocab.concern or vocab.surface)) then
    return ui.notify_raw("TAG ADD: vocab unavailable (foxtag unreachable) — refusing to free-type",
      vim.log.levels.WARN)
  end
  local items, seen = {}, {}
  for axis, set in pairs({ concern = vocab.concern or {}, surface = vocab.surface or {} }) do
    for name in pairs(set) do
      if not seen[name] then seen[name] = true; items[#items + 1] = { name = name, axis = axis } end
    end
  end
  table.sort(items, function(a, b) return a.name < b.name end)
  items[#items + 1] = { mint = true }
  ui.fuzzy_pick({
    title = ("add [TAG] · %s %s"):format(blk.type, blk.name or ""),
    items = items,
    format = function(it)
      if it.mint then return "＋ mint NEW vocab (SSoT: tools/add_vocab.py — never plugin-local)" end
      return ("%s   (%s)"):format(it.name, it.axis)
    end,
    on_choice = function(choice)
    if not choice then return end
    if choice.mint then
      return ui.notify_raw("mint vocab via the SSoT: python3 tools/add_vocab.py "
        .. "(schema fence + vocabulary doc), then re-run TAG ADD", vim.log.levels.INFO)
    end
    local abs = blk.opener + rel - 1                 -- 0-indexed buffer line of the [TAG] line
    local cur = vim.api.nvim_buf_get_lines(buf, abs, abs + 1, false)[1] or ""
    local merged = M.merge_tag_line(cur, choice.name)
    if not merged then
      return ui.notify_raw("TAG ADD: the [TAG] line moved — re-open the menu", vim.log.levels.WARN)
    end
    if merged == cur then
      return ui.notify_raw(("TAG ADD: %s already carries [%s]"):format(blk.name or "unit", choice.name),
        vim.log.levels.INFO)
    end
    vim.api.nvim_buf_set_lines(buf, abs, abs + 1, false, { merged })
    ui.notify_raw(("TAG ADD ✎ %s + [%s]  (buffer edited — save to keep)")
      :format(blk.name or "unit", choice.name), vim.log.levels.INFO)
    end,
  })
end

return M
