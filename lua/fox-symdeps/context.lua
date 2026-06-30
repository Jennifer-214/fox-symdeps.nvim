-- Resolve the symbol under the cursor into a ctx table the providers consume.
local M = {}

-- treesitter node-type → our coarse kind (refined by parent below)
local KIND = {
  type_identifier = "type",
  primitive_type = "type",
  field_identifier = "field",
}

---@return table|nil ctx { symbol, kind, file, line(1-based), col(0-based), bufnr }
function M.under_cursor()
  local bufnr = vim.api.nvim_get_current_buf()
  local symbol = vim.fn.expand("<cword>")
  -- only resolve real identifiers — skip numbers / operators / punctuation
  if not symbol:match("^[%a_][%w_]*$") then
    return nil
  end
  local cursor = vim.api.nvim_win_get_cursor(0) -- { row(1-based), col(0-based) }

  local kind = "symbol"
  local ok, node = pcall(vim.treesitter.get_node, { bufnr = bufnr })
  if ok and node then
    -- don't chase a name written inside a comment (// FPN_Binary is EXTENDED …)
    local n = node
    while n do
      if n:type():find("comment") then return nil end
      n = n:parent()
    end
    kind = KIND[node:type()] or kind
    local parent = node:parent()
    local pt = parent and parent:type() or ""
    if pt == "struct_specifier" or pt == "class_specifier" or pt == "union_specifier" then
      kind = "struct"
    elseif pt == "function_declarator" or pt == "call_expression" then
      kind = "function"
    end
  end

  return {
    symbol = symbol,
    kind = kind,
    file = vim.api.nvim_buf_get_name(bufnr),
    line = cursor[1],
    col = cursor[2],
    bufnr = bufnr,
  }
end

return M
