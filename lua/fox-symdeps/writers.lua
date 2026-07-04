-- writers.lua — write-owner analysis for false-sharing.
--
-- L1 (this file) is the PURE core: given a struct's fields + a map of which functions WRITE each
-- field, find the false-sharing risks — two WRITTEN fields sharing a 64 B cache line whose writer-sets
-- are DISJOINT (different code paths writing the same line → cross-core MESI invalidation). Filtered
-- out (NOT risks): read-only fields, and same-/overlapping-writer pairs (coordinated, single owner).
--
-- L0 (who-writes-what — clangd references + treesitter write-detection) feeds the `writers` map and is
-- verified live, not here (treesitter isn't available in the --clean test harness).
local M = {}

local CACHE_LINE = 64

-- the 0-based cache lines a field occupies: first..last (a field can straddle a boundary).
local function lines_of(field, cl)
  local first = math.floor(field.offset / cl)
  local last = math.floor((field.offset + math.max(field.size, 1) - 1) / cl)
  return first, last
end

-- accept a writers entry as a list {"push"} or a set {push=true}; empty/nil → nil (not a writer).
local function to_set(v)
  if type(v) ~= "table" then return nil end
  local s, n = {}, 0
  if v[1] ~= nil then
    for _, w in ipairs(v) do s[w] = true; n = n + 1 end
  else
    for w in pairs(v) do s[w] = true; n = n + 1 end
  end
  return n > 0 and s or nil
end

local function disjoint(a, b)
  for w in pairs(a) do if b[w] then return false end end
  return true
end

local function sorted_keys(set)
  local out = {}
  for k in pairs(set) do out[#out + 1] = k end
  table.sort(out)
  return out
end

-- fields:  { {name, offset, size}, ... }   (as layout.fields returns)
-- writers: name -> (list|set) of writer-function names   (from L0)
-- opts.cache_line (default 64)
-- returns: { { line, a, b, writers_a = {..}, writers_b = {..} }, ... }  a<b field names, line shared.
function M.risk(fields, writers, opts)
  local cl = (opts and opts.cache_line) or CACHE_LINE
  writers = writers or {}
  local on_line = {} -- line -> { { name, wset }, ... }  (written fields only)
  for _, f in ipairs(fields or {}) do
    local wset = to_set(writers[f.name])
    if wset then
      local first, last = lines_of(f, cl)
      for ln = first, last do
        on_line[ln] = on_line[ln] or {}
        table.insert(on_line[ln], { name = f.name, wset = wset })
      end
    end
  end
  local order = {}
  for ln in pairs(on_line) do order[#order + 1] = ln end
  table.sort(order)
  local risks, seen = {}, {}
  for _, ln in ipairs(order) do
    local fs = on_line[ln]
    for i = 1, #fs do
      for j = i + 1, #fs do
        if disjoint(fs[i].wset, fs[j].wset) then
          local a, b = fs[i].name, fs[j].name
          if a > b then a, b = b, a end
          local key = a .. "\0" .. b
          if not seen[key] then
            seen[key] = true
            risks[#risks + 1] = {
              line = ln, a = a, b = b,
              writers_a = sorted_keys(fs[i].name == a and fs[i].wset or fs[j].wset),
              writers_b = sorted_keys(fs[i].name == b and fs[i].wset or fs[j].wset),
            }
          end
        end
      end
    end
  end
  return risks
end

-- L0 write-detection: is the identifier reference at (row0, col0) a WRITE? Conservative — only the
-- unambiguous mutations (assignment LHS incl. compound `+=` etc.; `++`/`--`). Ambiguous cases
-- (address-of, non-const ref args, initialization) are treated as READS, because a spurious
-- false-sharing risk erodes trust more than a missed one (calm by construction). Needs the cpp parser.
function M.is_write_at(content, row0, col0)
  local okp, parser = pcall(vim.treesitter.get_string_parser, content, "cpp")
  if not okp or not parser then return false end
  local trees = parser:parse()
  local root = trees and trees[1] and trees[1]:root()
  if not root then return false end
  local node = root:named_descendant_for_range(row0, col0, row0, col0)
  if not node then return false end
  local sr, sc = node:range() -- our node's start, for the "within the LHS" test
  local n = node
  while n do
    local t = n:type()
    if t == "update_expression" then return true end -- x++  --x
    if t == "assignment_expression" then
      local left = n:field("left")[1]
      if not left then return false end
      local lsr, lsc, ler, lec = left:range()
      local after_start = (sr > lsr) or (sr == lsr and sc >= lsc)
      local before_end = (sr < ler) or (sr == ler and sc <= lec)
      return after_start and before_end -- true iff our node sits inside the LHS
    end
    if t == "compound_statement" or t == "function_definition" or t == "translation_unit" then
      return false -- reached a statement/scope boundary without an assignment → a read
    end
    n = n:parent()
  end
  return false
end

M._lines_of = lines_of
M._to_set = to_set
M._disjoint = disjoint
return M
