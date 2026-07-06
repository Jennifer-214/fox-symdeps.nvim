-- tag_grammar_adapter.lua — a REAL adapter for the codified [TAG]_ comment grammar (E.1.2.A).
--
-- Grammar SSoT: the workspace DESIGN_SPECS/doc-disciplines/in-code-documentation-schema.md.
-- CI reference parser: tools/check_code_tag_blocks.py — this Lua adapter mirrors its ONE parse rule
-- (innermost-bracket regex; token[0]=CATEGORY, rest=values), so the plugin (read-back) and the CI
-- (validate) read the SAME grammar. No two-fact-cores mirror (D-310).
--
-- Install (ONE call — lights up tagadapter.parse/format_derived/verify everywhere downstream):
--   require("fox-symdeps.tagadapter").install(require("fox-symdeps.tag_grammar_adapter"))
--
-- Interface (see tagadapter.lua):
--   parse(block_text)     -> tags | nil
--   format_derived(facts) -> { lines } | nil
--   verify(tags, facts)   -> { drift, ... }
local M = {}

-- The ONE parse rule (schema § "The three invariants" #1): innermost brackets on a `// [...]` line.
-- The outer list-grouping [[a] [b]] is non-innermost -> yields a,b for free.
local function line_tokens(payload)
  local toks = {}
  for t in payload:gmatch("%[([^%[%]]+)%]") do
    toks[#toks + 1] = vim.trim and vim.trim(t) or t:gsub("^%s*(.-)%s*$", "%1")
  end
  return toks
end

local UNIT = { FUNCTION = true, STRUCT = true, REGISTRY = true, FILE = true, TYPE = true, ENUM = true,
               STRATEGY = true, MACRO = true, TEST = true }

-- parse a comment block's tags. Returns { unit = {type,name}, tags = {CAT = {v,...}}, order = {CAT,...} }
-- or nil when the block carries no [SCHEMA]_ marker (i.e. it's un-converted prose).
function M.parse(block_text)
  if not block_text or not block_text:find("%[SCHEMA%]_") then return nil end
  local out = { tags = {}, order = {} }
  local in_prose = false
  for _, raw in ipairs(vim.split(block_text, "\n")) do
    if in_prose then
      if raw:match("^%s*//=+%s*$") then in_prose = false end   -- ==== bar closes a freeform region
    else
      local payload = raw:match("^%s*//%s*(%[.*)$")            -- a structured tag-line (first payload = '[')
      if payload then
        local toks = line_tokens(payload)
        local cat = toks[1]
        if cat then
          local vals = {}
          for i = 2, #toks do vals[#vals + 1] = toks[i] end
          if not out.tags[cat] then out.order[#out.order + 1] = cat end
          out.tags[cat] = vals
          if UNIT[cat] and vals[1] then out.unit = { type = cat, name = vals[1] } end
          if cat == "COMMENT" or cat == "DIAGRAM" then in_prose = true end  -- freeform body follows
        end
      end
    end
  end
  if not out.unit and not next(out.tags) then return nil end
  return out
end

-- render facts.derived() as codified [DERIVED] comment lines. Field contract (facts.lua):
--   data_size = instruction count (FUNCTIONS only; nil for structs) · simd = bool | nil (functions)
--   dep_chain = callees(fn)/upstream type deps(struct) · consumers = callers(fn)/consumer scopes(struct)
-- (a struct's BYTE [SIZE] is the cache-gate's path — check_cache_layout --fix — not this facts path.)
function M.format_derived(facts)
  if not facts then return nil end
  local L = { "// [DERIVED]   (tool-refreshed by fox-symdeps; do NOT hand-edit)",
              "//----------------------------------------------------------------------" }
  if facts.data_size then L[#L + 1] = ("// [SIZE]_[%s instr]"):format(facts.data_size) end  -- fn: instr count (unit disambiguates struct bytes)
  if facts.simd ~= nil then L[#L + 1] = ("// [SIMD]_[%s]"):format(facts.simd and "simd" or "scalar") end  -- ~= nil: scalar(false) still emits
  if facts.dep_chain and #facts.dep_chain > 0 then
    L[#L + 1] = ("// [UPSTREAM]_[[%s]]"):format(table.concat(facts.dep_chain, "] ["))
  end
  if facts.consumers and #facts.consumers > 0 then
    L[#L + 1] = ("// [CONSUMERS]_[[%s]]"):format(table.concat(facts.consumers, "] ["))
  end
  return #L > 2 and L or nil
end

-- compare a parsed block's [DERIVED] tags vs live facts -> drift findings (the comment lies about codegen).
-- (struct byte-[SIZE] drift is the cache-gate's authority; this covers the facts-path fn instr/simd.)
local function num(s) return s and s:match("%-?%d+") end   -- leading number, unit-agnostic ("8 instr" -> "8")
function M.verify(tags, facts)
  local drift = {}
  if not (tags and tags.tags and facts) then return drift end
  local d = tags.tags
  if d.SIZE and d.SIZE[1] and facts.data_size and num(d.SIZE[1]) ~= tostring(facts.data_size) then
    drift[#drift + 1] = { tag = "SIZE", comment = d.SIZE[1], live = tostring(facts.data_size) }
  end
  if d.SIMD and d.SIMD[1] and facts.simd ~= nil then
    local live = facts.simd and "simd" or "scalar"
    if d.SIMD[1] ~= live then drift[#drift + 1] = { tag = "SIMD", comment = d.SIMD[1], live = live } end
  end
  return drift
end

return M
