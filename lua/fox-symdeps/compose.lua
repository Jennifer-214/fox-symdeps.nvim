-- compose.lua — W22 reverse composition (recursive): "what does this struct contain, all the way
-- down." Resolves a type's definition via rg, extracts its members (name + type) via treesitter,
-- and recurses into struct-typed members (depth-bounded, cycle-guarded). Nested levels are
-- structure-only (name:type) — the top level's offsets/sizes come from clangd's field map. Generic.
local M = {}

-- the base name of a type, template args stripped: "FPN_Binary<F>" -> "FPN_Binary".
local function base_of(t)
  return t and (t:gsub("%s*<.*$", ""):gsub("%s+$", "")) or t
end

-- a member type worth recursing into: a bare user type (Capitalized ident, template args OK),
-- not a primitive / pointer / array / std:: type. Recurses into the base template.
local function is_struct_type(t)
  if not t or t:find("[%*%[]") then return false end -- pointer / array → don't recurse
  local b = base_of(t)
  return b:match("^[%u][%w_]*$") ~= nil
end

local function def_file(name, root)
  local ok, out = pcall(vim.fn.systemlist, {
    "rg", "--no-heading", "-l", "--color", "never",
    "-g", "*.hpp", "-g", "*.h", "-g", "*.hh", "-g", "*.cpp", "-g", "*.cc",
    "-e", "(struct|class)[[:space:]]+" .. name .. "[[:space:]{:]", root,
  })
  return (ok and type(out) == "table") and out[1] or nil
end

local function find_struct(node, name, content)
  local t = node:type()
  if t == "struct_specifier" or t == "class_specifier" or t == "union_specifier" then
    local nm = node:field("name")[1]
    if nm and vim.treesitter.get_node_text(nm, content) == name then return node end
  end
  for c in node:iter_children() do
    local r = find_struct(c, name, content)
    if r then return r end
  end
end

local function field_name(decl, content)
  if not decl then return nil end
  if decl:type() == "field_identifier" then return vim.treesitter.get_node_text(decl, content) end
  for c in decl:iter_children() do
    local r = field_name(c, content)
    if r then return r end
  end
end

-- direct members {name, type} of `struct name`, resolved from its definition file. Pure-ish
-- (rg + treesitter; needs the cpp parser). content_override lets tests pass source directly.
function M.members(name, root, content_override)
  local content = content_override
  if not content then
    local file = def_file(name, root)
    if not file then return {} end
    local ok, lines = pcall(vim.fn.readfile, file)
    if not ok then return {} end
    content = table.concat(lines, "\n")
  end
  local okp, parser = pcall(vim.treesitter.get_string_parser, content, "cpp")
  if not okp or not parser then return {} end
  local trees = parser:parse()
  local rootn = trees and trees[1] and trees[1]:root()
  if not rootn then return {} end
  local s = find_struct(rootn, name, content)
  local body = s and s:field("body")[1]
  if not body then return {} end
  local out = {}
  for f in body:iter_children() do
    if f:type() == "field_declaration" then
      local ty = f:field("type")[1]
      local nm = field_name(f:field("declarator")[1], content)
      if nm then
        out[#out + 1] = { name = nm, type = ty and vim.trim(vim.treesitter.get_node_text(ty, content)) or "?" }
      end
    end
  end
  return out
end

-- recursive composition tree for `name`: { {name, type, children?}, ... }. Depth-bounded +
-- cycle-guarded. Root-level callers pass depth (e.g. 3).
function M.tree(name, root, depth, seen)
  seen = seen or {}
  if depth <= 0 or seen[name] then return {} end
  seen[name] = true
  local out = {}
  for _, m in ipairs(M.members(name, root)) do
    local node = { name = m.name, type = m.type }
    if is_struct_type(m.type) then
      local kids = M.tree(base_of(m.type), root, depth - 1, seen) -- recurse the base template
      if #kids > 0 then node.children = kids end
    end
    out[#out + 1] = node
  end
  seen[name] = nil
  return out
end

-- def location {file, line} of a type via rg ("struct|class NAME" up to a delimiter). nil if unfound.
local function def_loc(name, root)
  if not root then return nil end
  local ok, out = pcall(vim.fn.systemlist, {
    "rg", "--no-heading", "--line-number", "--color", "never",
    "-g", "*.hpp", "-g", "*.h", "-g", "*.hh", "-g", "*.cpp", "-g", "*.cc",
    "-e", "(struct|class)[[:space:]]+" .. name .. "[[:space:]{:;<]", root,
  })
  if ok and type(out) == "table" and out[1] then
    local file, line = out[1]:match("^([^:]+):(%d+):")
    if file then return file, tonumber(line) end
  end
end

-- UPSTREAM "Uses": the distinct user-defined types this struct depends on (struct/class-typed members,
-- template args stripped, deduped + sorted), each resolved to its definition so the HUD can JUMP.
-- The mirror of Consumers. Returns { {name, file?, line?}, ... }. content_override lets tests pass source.
function M.uses(name, root, content_override)
  local seen, out = {}, {}
  for _, m in ipairs(M.members(name, root, content_override)) do
    if is_struct_type(m.type) then
      local b = base_of(m.type)
      if not seen[b] then
        seen[b] = true
        local file, line = def_loc(b, root)
        out[#out + 1] = { name = b, file = file, line = line }
      end
    end
  end
  table.sort(out, function(a, b) return a.name < b.name end)
  return out
end

M._is_struct_type = is_struct_type
return M
