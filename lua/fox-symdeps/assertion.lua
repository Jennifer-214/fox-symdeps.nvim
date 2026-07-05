-- assertion.lua — "lock this layout." Cursor on a struct → verify its size/align via clangd → drop
-- a static_assert into the code right after the definition. Turns the tool from "shows you the
-- layout" into "helps you WRITE the guard": once pinned, any future edit (yours or the model's) that
-- moves sizeof/alignof fails the build. The compiled-reality equivalent of a snapshot test. <leader>da.
local M = {}

-- pure: the static_assert source line, indented. align optional (some probes only recover size).
function M.line(symbol, size, align, indent)
  indent = indent or ""
  if align then
    return ("%sstatic_assert(sizeof(%s) == %d && alignof(%s) == %d, \"%s layout locked (fox-symdeps)\");")
      :format(indent, symbol, size, symbol, align, symbol)
  end
  return ("%sstatic_assert(sizeof(%s) == %d, \"%s size locked (fox-symdeps)\");")
    :format(indent, symbol, size, symbol)
end

-- the struct/class/union definition of `symbol` enclosing the cursor → (end_row_0based, indent).
-- nil when the cursor isn't on a definition of `symbol` (e.g. a use site) — caller falls back to
-- inserting at the cursor line. Placing it after the closing `};`, in the same scope, keeps the
-- name unqualified + guarantees the type is complete where the assert lands. Uses the explicit
-- parser API (not vim.treesitter.get_node, which needs active TS highlighting → nil without it).
local function def_end(symbol, bufnr, row0, col0)
  local ok, parser = pcall(vim.treesitter.get_parser, bufnr, "cpp")
  if not ok or not parser then return nil end
  local tree = parser:parse()[1]
  if not tree then return nil end
  local node = tree:root():named_descendant_for_range(row0, col0, row0, col0)
  while node do
    local t = node:type()
    if t == "struct_specifier" or t == "class_specifier" or t == "union_specifier" then
      local nm = node:field("name")[1]
      if nm and vim.treesitter.get_node_text(nm, bufnr) == symbol then
        local srow, _, erow = node:range()
        local indent = ((vim.api.nvim_buf_get_lines(bufnr, srow, srow + 1, false)[1]) or ""):match("^%s*")
        return erow, indent
      end
    end
    node = node:parent()
  end
end

function M.insert()
  local ctx = require("fox-symdeps.context").under_cursor()
  if not ctx or ctx.kind == "function" then
    return vim.notify("fox-symdeps · put the cursor on a struct/type to lock its layout", vim.log.levels.INFO)
  end
  local bufnr = vim.api.nvim_get_current_buf()
  local cur = vim.api.nvim_win_get_cursor(0)
  -- resolve the insertion point synchronously (cursor is stable now, before the async query)
  local erow, indent = def_end(ctx.symbol, bufnr, cur[1] - 1, cur[2])
  local at = erow and (erow + 1) or cur[1]
  indent = indent or (vim.api.nvim_get_current_line():match("^%s*")) or ""

  require("fox-symdeps.clangd").layout(ctx, function(data, state)
    if state ~= "ok" or not data or not data.size then
      local msg = (data and data.is_template)
        and "templated type — put the cursor on a concrete Foo<N> use, then lock that"
        or "size unavailable — needs clangd + compile_commands.json + cursor on a type"
      return vim.notify("fox-symdeps · " .. msg, vim.log.levels.WARN)
    end
    if not vim.api.nvim_buf_is_valid(bufnr) then return end
    local line = M.line(ctx.symbol, data.size, data.align, indent)
    vim.api.nvim_buf_set_lines(bufnr, at, at, false, { line })
    vim.notify(("fox-symdeps · locked %s = %d B%s → static_assert inserted (u to undo)"):format(
      ctx.symbol, data.size, data.align and (" · align " .. data.align) or ""), vim.log.levels.INFO)
  end)
end

return M
