-- Classify a clangd reference site by its syntactic ROLE via treesitter — because the
-- role is the signal (a param depends on the type's fields; a local on its size; a field
-- embeds it; a sizeof locks its bytes). Content-based, so it works for files not open.
local M = {}

local ROLE_ORDER = { "input", "returned", "embedded", "instantiated", "byte", "called", "other" }
local ROLE_LABEL = {
  input = "Used as input",
  returned = "Returned by",
  embedded = "Embedded in",
  instantiated = "Instantiated in",
  byte = "Byte / sizeof",
  called = "Called by",
  other = "Other",
}

local function classify_node(node)
  local n = node
  while n do
    local t = n:type()
    if t == "parameter_declaration" then return "input" end
    if t == "field_declaration" then return "embedded" end
    if t == "sizeof_expression" then return "byte" end
    if t == "call_expression" then return "called" end
    if t == "declaration" then
      for child in n:iter_children() do
        if child:type() == "function_declarator" then return "returned" end -- return type of a decl
      end
      local p = n:parent()
      while p do
        local pt = p:type()
        if pt == "compound_statement" or pt == "function_definition" then return "instantiated" end
        p = p:parent()
      end
      return "other" -- global var declaration (rare)
    end
    if t == "function_definition" then return "returned" end -- type sits as the return type
    n = n:parent()
  end
  return "other"
end

local function role_at(content, row0, col0)
  local okp, parser = pcall(vim.treesitter.get_string_parser, content, "cpp")
  if not okp or not parser then return "other" end
  local trees = parser:parse()
  local root = trees and trees[1] and trees[1]:root()
  if not root then return "other" end
  local node = root:named_descendant_for_range(row0, col0, row0, col0)
  return node and classify_node(node) or "other"
end

-- Annotate each item {file, line(1-based), col(0-based)} with .role. Parses each file once.
function M.classify(items)
  if not items or #items == 0 then return items end
  local by_file = {}
  for _, it in ipairs(items) do
    by_file[it.file] = by_file[it.file] or {}
    table.insert(by_file[it.file], it)
  end
  for file, its in pairs(by_file) do
    local root
    local ok, lines = pcall(vim.fn.readfile, file)
    if ok and lines then
      local okp, parser = pcall(vim.treesitter.get_string_parser, table.concat(lines, "\n"), "cpp")
      if okp and parser then
        local trees = parser:parse()
        root = trees and trees[1] and trees[1]:root()
      end
    end
    for _, it in ipairs(its) do
      local role = "other"
      if root and it.col then
        local node = root:named_descendant_for_range(it.line - 1, it.col, it.line - 1, it.col)
        if node then role = classify_node(node) end
      end
      it.role = role
    end
  end
  return items
end

-- Bucket annotated items into ordered, labelled groups for the HUD.
function M.group(items)
  local buckets = {}
  for _, it in ipairs(items or {}) do
    local r = it.role or "other"
    buckets[r] = buckets[r] or {}
    table.insert(buckets[r], it)
  end
  local groups = {}
  for _, r in ipairs(ROLE_ORDER) do
    if buckets[r] then groups[#groups + 1] = { label = ROLE_LABEL[r], items = buckets[r] } end
  end
  return groups
end

M._role_at = role_at -- exposed for tests

return M
