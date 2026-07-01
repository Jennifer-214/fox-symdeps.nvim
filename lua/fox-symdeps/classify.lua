-- Classify a clangd reference site by its syntactic ROLE via treesitter — because the
-- role is the signal (a param depends on the type's fields; a local on its size; a field
-- embeds it; a sizeof locks its bytes). Content-based, so it works for files not open.
local M = {}

local ROLE_ORDER = { "input", "returned", "embedded", "instantiated", "byte", "called", "other" }
local ROLE_LABEL = {
  input = "Used as input",
  returned = "Returned by",
  embedded = "Embedded in structs",
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

-- the name of the nearest enclosing function/struct/class — the "who uses it" at level 3
local function enclosing_name(node, content)
  local n = node
  while n do
    local t = n:type()
    if t == "struct_specifier" or t == "class_specifier" or t == "union_specifier" then
      local nm = n:field("name")[1]
      return nm and vim.treesitter.get_node_text(nm, content) or nil
    end
    if t == "function_definition" then
      local d = n:field("declarator")[1]
      while d do
        local dt = d:type()
        if dt == "identifier" or dt == "field_identifier" or dt == "qualified_identifier"
          or dt == "destructor_name" or dt == "operator_name" then
          return vim.treesitter.get_node_text(d, content)
        end
        d = d:field("declarator")[1]
      end
      return nil
    end
    n = n:parent()
  end
  return nil
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
    local root, content
    local ok, lines = pcall(vim.fn.readfile, file)
    if ok and lines then
      content = table.concat(lines, "\n")
      local okp, parser = pcall(vim.treesitter.get_string_parser, content, "cpp")
      if okp and parser then
        local trees = parser:parse()
        root = trees and trees[1] and trees[1]:root()
      end
    end
    for _, it in ipairs(its) do
      it.role = "other"
      if root and it.col then
        local node = root:named_descendant_for_range(it.line - 1, it.col, it.line - 1, it.col)
        if node then
          it.role = classify_node(node)
          it.scope = enclosing_name(node, content)
        end
      end
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

function M._scope_at(content, row0, col0)
  local okp, parser = pcall(vim.treesitter.get_string_parser, content, "cpp")
  if not okp or not parser then return nil end
  local trees = parser:parse()
  local root = trees and trees[1] and trees[1]:root()
  if not root then return nil end
  local node = root:named_descendant_for_range(row0, col0, row0, col0)
  return node and enclosing_name(node, content) or nil
end

-- Build a role → file → entries tree for the collapsible HUD. Level-3 label = it.scope
-- (enclosing fn/struct) when present, else the line. Files with > THRESH refs start collapsed.
local TREE_THRESH = 5
function M.tree(items)
  local roles = {}
  for _, it in ipairs(items or {}) do
    local r = it.role or "other"
    roles[r] = roles[r] or { byfile = {}, order = {} }
    if not roles[r].byfile[it.file] then
      roles[r].byfile[it.file] = { file = it.file, entries = {} }
      roles[r].order[#roles[r].order + 1] = it.file
    end
    table.insert(roles[r].byfile[it.file].entries, it)
  end
  local out = {}
  for _, r in ipairs(ROLE_ORDER) do
    if roles[r] then
      local files, count = {}, 0
      for _, fpath in ipairs(roles[r].order) do
        local fe = roles[r].byfile[fpath]
        table.sort(fe.entries, function(a, b) return a.line < b.line end)
        fe.count = #fe.entries
        fe.collapsed = fe.count > TREE_THRESH
        count = count + fe.count
        files[#files + 1] = fe
      end
      table.sort(files, function(a, b) return a.file < b.file end)
      out[#out + 1] = { label = ROLE_LABEL[r], role = r, count = count, collapsed = true, files = files }
    end
  end
  return out
end

return M
