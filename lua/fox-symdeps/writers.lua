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

-- pure: per-function cache-line access density over a struct's fields — how many DISTINCT 64 B lines
-- of the struct each function touches. `touches`: fn -> set of field names it references (read OR
-- write). A function touching >1 line per call is the working-set-density concern (every extra line
-- is a load); this is path-agnostic — it reports EVERY function (hot or slow), not just budgeted ones.
-- Returns { { fn, nlines, lines = {sorted 0-based line indices} }, ... } sorted by nlines desc, fn.
function M.density(fields, touches, opts)
  local cl = (opts and opts.cache_line) or CACHE_LINE
  local byname = {}
  for _, f in ipairs(fields or {}) do byname[f.name] = f end
  local out = {}
  for fn, fset in pairs(touches or {}) do
    local lineset = {}
    for name in pairs(fset) do
      local f = byname[name]
      if f then
        local first, last = lines_of(f, cl)
        for ln = first, last do lineset[ln] = true end
      end
    end
    local lines = {}
    for ln in pairs(lineset) do lines[#lines + 1] = ln end
    table.sort(lines)
    if #lines > 0 then out[#out + 1] = { fn = fn, nlines = #lines, lines = lines } end
  end
  table.sort(out, function(a, b)
    if a.nlines ~= b.nlines then return a.nlines > b.nlines end
    return a.fn < b.fn
  end)
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

-- ── L0/L1 orchestration (impure: clangd + treesitter; verified live, not headless) ──────────────
local function client(bufnr) return vim.lsp.get_clients({ bufnr = bufnr, name = "clangd" })[1] end

-- documentSymbol tree → { fieldname -> {line, character} } for the struct `name`'s field children.
local function field_positions(syms, name)
  for _, s in ipairs(syms or {}) do
    if s.name == name and s.children then
      local pos = {}
      for _, ch in ipairs(s.children) do
        local r = ch.selectionRange or ch.range
        if r then pos[ch.name] = r.start end
      end
      return pos
    end
    if s.children then
      local p = field_positions(s.children, name)
      if p then return p end
    end
  end
end

-- Build the write-owner picture for the struct under ctx and hand it to cb(result, state):
--   result = { fields, writers = name->set, sites = name->{ {file,line,scope} }, risks = risk(...) }
-- Async (clangd references per field). cb(nil, state) on no clangd / empty.
function M.for_struct(ctx, cb)
  local c = client(ctx.bufnr)
  if not c then return cb(nil, "no_client") end
  local layout = require("fox-symdeps.layout")
  local classify = require("fox-symdeps.classify")
  layout.fields(ctx, function(fields, fstate)
    if fstate ~= "ok" or not fields or #fields == 0 then return cb(nil, fstate) end
    local td = { uri = vim.uri_from_bufnr(ctx.bufnr) }
    c:request("textDocument/documentSymbol", { textDocument = td }, function(err, syms)
      if err or not syms then return cb(nil, "empty") end
      local fpos = field_positions(syms, ctx.symbol) or {}
      local writers, sites, cache = {}, {}, {}
      local touches = {} -- fn -> set of field names it references (read OR write) — for density
      local function content_of(uri)
        local file = vim.uri_to_fname(uri)
        if cache[file] == nil then
          local okr, lines = pcall(vim.fn.readfile, file)
          cache[file] = okr and table.concat(lines, "\n") or false
        end
        return cache[file] or nil, file
      end
      local pending = 0
      local function finish()
        cb({ fields = fields, writers = writers, sites = sites, touches = touches,
          risks = M.risk(fields, writers) }, "ok")
      end
      for _, f in ipairs(fields) do
        local p = fpos[f.name]
        if p then
          pending = pending + 1
          c:request("textDocument/references",
            { textDocument = td, position = p, context = { includeDeclaration = false } },
            function(_, refs)
              local wset = {}
              for _, r in ipairs(refs or {}) do
                local content, file = content_of(r.uri)
                if content then
                  local row0, col0 = r.range.start.line, r.range.start.character
                  local scope = classify._scope_at(content, row0, col0) or "?"
                  touches[scope] = touches[scope] or {} -- every reference (read or write) → density
                  touches[scope][f.name] = true
                  if M.is_write_at(content, row0, col0) then
                    wset[scope] = true
                    sites[f.name] = sites[f.name] or {}
                    table.insert(sites[f.name], { file = file, line = row0 + 1, scope = scope })
                  end
                end
              end
              if next(wset) then writers[f.name] = wset end
              pending = pending - 1
              if pending == 0 then finish() end
            end, ctx.bufnr)
        end
      end
      if pending == 0 then finish() end
    end, ctx.bufnr)
  end)
end

-- Write-owner for the SINGLE symbol under ctx (a field / variable): who WRITES it. cb(result, state):
--   result = { writers = set, sites = { {file,line,scope} }, reads = N, total = N }. Reuses is_write_at.
function M.for_symbol(ctx, cb)
  local c = client(ctx.bufnr)
  if not c then return cb(nil, "no_client") end
  local classify = require("fox-symdeps.classify")
  local params = {
    textDocument = { uri = vim.uri_from_bufnr(ctx.bufnr) },
    position = { line = ctx.line - 1, character = ctx.col },
    context = { includeDeclaration = false },
  }
  c:request("textDocument/references", params, function(err, refs)
    if err or not refs then return cb(nil, "empty") end
    local cache, writers, sites, reads = {}, {}, {}, 0
    for _, r in ipairs(refs) do
      local file = vim.uri_to_fname(r.uri)
      if cache[file] == nil then
        local okr, lines = pcall(vim.fn.readfile, file)
        cache[file] = okr and table.concat(lines, "\n") or false
      end
      local content = cache[file]
      if content then
        local row0, col0 = r.range.start.line, r.range.start.character
        if M.is_write_at(content, row0, col0) then
          local scope = classify._scope_at(content, row0, col0) or "?"
          writers[scope] = true
          sites[#sites + 1] = { file = file, line = row0 + 1, scope = scope }
        else
          reads = reads + 1
        end
      end
    end
    cb({ writers = writers, sites = sites, reads = reads, total = #refs }, "ok")
  end, ctx.bufnr)
end

M._lines_of = lines_of
M._to_set = to_set
M._disjoint = disjoint
return M
