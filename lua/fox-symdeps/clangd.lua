-- Async clangd queries: layout (size/align/offset via hover) + consumers (LSP references).
-- Every call is non-blocking and reports a state so the HUD can render graceful placeholders.
local M = {}

local function client(bufnr)
  return vim.lsp.get_clients({ bufnr = bufnr, name = "clangd" })[1]
end

-- clangd hover markdown carries e.g. "Size: 112 bytes, alignment 8 bytes" (+ "offset: N bytes" on a field).
local function parse_layout(md)
  if not md then
    return nil
  end
  local size = md:match("[Ss]ize:%s*(%d+)%s*bytes")
  local align = md:match("[Aa]lignment%s*(%d+)%s*bytes")
  local offset = md:match("[Oo]ffset:%s*(%d+)%s*bytes")
  if not (size or offset) then
    return nil
  end
  return {
    size = size and tonumber(size) or nil,
    align = align and tonumber(align) or nil,
    offset = offset and tonumber(offset) or nil,
  }
end

-- template parameter NAMES from a hover's `template <...>` clause — the last identifier of each
-- comma-separated parameter: "template <int RADIX, int FRAC>" → { RADIX=true, FRAC=true }. Lets
-- spec_of tell an un-instantiated injected-class-name (`Foo<RADIX,FRAC>`) from a concrete one.
local function tparam_names(md)
  local names = {}
  local clause = md and md:match("template%s*<(.-)>")
  if not clause then return names end
  for seg in (clause .. ","):gmatch("(.-),") do
    local nm = seg:match("([%a_][%w_]*)%s*$") -- the param name is the segment's last identifier
    if nm then names[nm] = true end
  end
  return names
end

-- the template spec named in a hover ("struct `Foo<64>`") → "Foo<64>", param_args — else nil.
-- An UN-instantiated primary template renders its injected-class-name with its OWN parameter
-- names (`FixedPoint<RADIX,FRAC>`, `FPN_Binary<F>`) — NOT probe-able as-is: those identifiers
-- exist only inside the template, so a sizeof probe hits "use of undeclared identifier RADIX".
-- param_args lists such args (spec args that name the hover's own template parameters) so the
-- caller can substitute canonical values (config template_args) or degrade to is_template. A
-- real instantiation (`Foo<64>`, `FixedPoint<10,8>`) has concrete args → param_args is empty.
-- NOTE the variable-hover blind spot this contract serves: hovering a VARIABLE whose type is
-- `ExecutionCore<F> *` gives a hover with NO template clause, so `F` can't be classified here —
-- it looks concrete, and only the probe's compile error reveals it. layout() handles that case
-- by substitution-before-probe + an actionable error, both driven by the same template_args map.
local function spec_of(md)
  local spec = md and md:match("([%w_:]+%b<>)")
  if not spec then return nil end
  local params = tparam_names(md)
  local args, seen = {}, {}
  for tok in spec:match("%b<>"):gmatch("[%a_][%w_]*") do
    if params[tok] and not seen[tok] then seen[tok] = true; args[#args + 1] = tok end
  end
  return spec, args
end

-- pure: substitute canonical template arguments into a spec's angle-bracket args (outer AND
-- nested): "ExecutionCore<F>" + { F = "64" } → "ExecutionCore<64>", { "F=64" }. Word-boundary —
-- only whole identifiers that are keys of `map` are rewritten; anything else (literals, real
-- file-scope constants, nested type names) passes through untouched for the compiler to judge.
local function subst_spec(spec, map)
  local applied = {}
  if not (spec and map and next(map)) then return spec, applied end
  local head, angle = spec:match("^([%w_:]+)(%b<>)$")
  if not head then return spec, applied end
  local seen = {}
  local out = angle:gsub("[%a_][%w_]*", function(tok)
    local v = map[tok]
    if v ~= nil then
      if not seen[tok] then seen[tok] = true; applied[#applied + 1] = tok .. "=" .. tostring(v) end
      return tostring(v)
    end
  end)
  return head .. out, applied
end

-- pure: rebuild a probe spelling around clang's did-you-mean SUGGESTION ("tt::ExecutionCore")
-- when it is a qualified form of the spelling's head — the self-healing retry for namespaced
-- types (the probe compiles at FILE scope; a hover's spelling is written from inside the
-- symbol's scope, so `ExecutionCore<64>` needs `tt::` there). nil when the suggestion isn't
-- a `…::head` requalification (never chase an unrelated fuzzy match into a wrong sizeof).
local function requalify(spelling, suggestion)
  local head, angle = (spelling or ""):match("^([%w_:]+)(%b<>)$")
  if not (head and suggestion and #suggestion > #head + 2) then return nil end
  if suggestion:sub(-#head) == head and suggestion:sub(-#head - 2, -#head - 1) == "::" then
    return suggestion .. angle
  end
end

-- the enclosing namespace clangd notes in a hover ("// In namespace tt") → "tt", else nil.
local function namespace_from_md(md)
  return md and md:match("//%s*In namespace%s+([%w_:]+)") or nil
end

-- clangd workspace/symbol result (SymbolInformation[]) → { {name, kind, container, file, line, col} }.
-- Skips entries with no resolvable location. Pure (vim.uri_to_fname only).
local function parse_workspace_symbols(result)
  local out = {}
  for _, s in ipairs(result or {}) do
    local loc = s.location or {}
    local uri = loc.uri or loc.targetUri
    local range = loc.range or loc.targetSelectionRange
    if uri and range and range.start then
      out[#out + 1] = {
        name = s.name,
        kind = s.kind,
        container = s.containerName or "",
        file = vim.uri_to_fname(uri),
        line = range.start.line + 1,
        col = range.start.character or 0,
      }
    end
  end
  return out
end

local function pos_params(ctx)
  return {
    textDocument = { uri = vim.uri_from_bufnr(ctx.bufnr) },
    position = { line = ctx.line - 1, character = ctx.col },
  }
end

-- state ∈ "ok" | "no_client" | "empty"  (so the HUD never errors, just shows a calm placeholder)
function M.layout(ctx, cb)
  local c = client(ctx.bufnr)
  if not c then
    return cb(nil, "no_client")
  end
  -- functions have no byte layout — never run a sizeof probe on one (it errors "invalid application
  -- of sizeof to a function", which now surfaces loudly). The HUD shows a function-appropriate line.
  if ctx.kind == "function" then
    return cb({ is_function = true }, "ok")
  end
  c:request("textDocument/hover", pos_params(ctx), function(err, result)
    if err or not (result and result.contents) then
      return cb(nil, "empty")
    end
    local md = type(result.contents) == "table" and (result.contents.value or "") or tostring(result.contents)
    local layout = parse_layout(md)
    if layout and layout.size then
      return cb(layout, "ok")
    end
    -- W23: clangd hover omits Size for a template instantiation. If the hover names a spec
    -- (`Foo<...>`), recover size/align via a sizeof probe. Dependent args — `Foo<F>` from an
    -- injected-class-name OR from a variable's type inside a template body — are substituted
    -- from config template_args (the repo's canonical instantiation, e.g. F=64) so the probe
    -- compiles at file scope; the result is labeled with what was assumed (computed_for).
    -- A dependent arg with NO mapping degrades to is_template (hover-classified) or to an
    -- actionable probe_error naming the config knob (variable-hover, compiler-classified).
    local spec, param_args = spec_of(md)
    if spec then
      local tmap = (require("fox-symdeps").config or {}).template_args or {}
      local missing = {}
      for _, p in ipairs(param_args or {}) do
        if tmap[p] == nil then missing[#missing + 1] = p end
      end
      if #missing > 0 then
        return cb({ is_template = true, missing_args = missing }, "ok")
      end
      local sub, applied = subst_spec(spec, tmap)
      -- the probe compiles at FILE scope but the hover's spelling is written from inside the
      -- symbol's scope — a namespaced type needs qualification there. Pre-qualify from the
      -- hover's "// In namespace" note when present; clang's own did-you-mean drives one
      -- self-healing retry for the rest (param hovers often carry no namespace note).
      local ns = namespace_from_md(md)
      local head = sub:match("^([%w_:]+)<")
      local first = (ns and head and not head:find("::")) and (ns .. "::" .. sub) or sub
      local probe = require("fox-symdeps.sizeprobe").compute
      local function finish(sz, spelling, retried)
        if sz and sz.size then
          return cb({ size = sz.size, align = sz.align or (layout and layout.align), computed = true,
               spec = spelling, computed_for = #applied > 0 and table.concat(applied, ", ") or nil }, "ok")
        end
        if sz and sz.error then
          if not retried then
            local fixed = requalify(spelling, sz.error:match("did you mean '([%w_:]+)'"))
            if fixed then return probe(ctx.bufnr, fixed, function(s2) finish(s2, fixed, true) end) end
            -- the ns pre-qualification itself can be the miss (global-scope type hovered
            -- inside a namespace) → fall back to the unqualified spelling once
            if spelling ~= sub then return probe(ctx.bufnr, sub, function(s2) finish(s2, sub, true) end) end
          end
          -- an "undeclared identifier" naming one of the spec's angle args is the dependent-type
          -- case with no mapping (variable hover — no template clause to classify it up front):
          -- point at the config knob instead of the raw compiler spew.
          local ident = sz.error:match("undeclared identifier '([%a_][%w_]*)'")
          if ident and sub:match("%b<>"):find("%f[%w_]" .. ident .. "%f[^%w_]") then
            return cb({ probe_error = ("type depends on template param '%s' — set template_args.%s in setup() for the canonical instantiation"):format(ident, ident),
                 missing_args = { ident } }, "probe_error")
          end
          return cb({ probe_error = sz.error }, "probe_error") -- compile failed → surface it, don't blame the DB
        end
        cb(layout, layout and "ok" or "empty")
      end
      probe(ctx.bufnr, first, function(sz) finish(sz, first, false) end)
    elseif md:match("template%s*<") then
      cb({ is_template = true }, "ok") -- un-instantiated template: no concrete size (put cursor on Foo<N>)
    else
      cb(layout, layout and "ok" or "empty")
    end
  end, ctx.bufnr)
end

-- Recover the enclosing namespace from a symbol's clangd hover — the asm probe's
-- fallback when the cursor is on a CALL site (outside the namespace block) so
-- treesitter can't climb to it. cb(namespace|"") — "" for global/unresolved.
function M.namespace_of(ctx, cb)
  local c = client(ctx.bufnr)
  if not c then return cb("") end
  c:request("textDocument/hover", pos_params(ctx), function(err, result)
    if err or not (result and result.contents) then return cb("") end
    local md = type(result.contents) == "table" and (result.contents.value or "") or tostring(result.contents)
    cb(namespace_from_md(md) or "")
  end, ctx.bufnr)
end

-- workspace/symbol fuzzy search across the whole index — structs, functions,
-- everything. The "go to symbol in workspace" primitive behind roam. cb(list|nil).
function M.workspace_symbols(query, cb)
  local c = vim.lsp.get_clients({ name = "clangd" })[1]
  if not c then return cb(nil) end
  c:request("workspace/symbol", { query = query }, function(err, result)
    if err or not result then return cb(nil) end
    cb(parse_workspace_symbols(result))
  end)
end

function M.consumers(ctx, cb)
  local c = client(ctx.bufnr)
  if not c then
    return cb(nil, "no_client")
  end
  local params = pos_params(ctx)
  params.context = { includeDeclaration = false }
  c:request("textDocument/references", params, function(err, result)
    if err or not result then
      return cb(nil, "empty")
    end
    local items = {}
    for _, loc in ipairs(result) do
      local range = loc.range or loc.targetSelectionRange
      items[#items + 1] = {
        file = vim.uri_to_fname(loc.uri or loc.targetUri),
        line = range.start.line + 1,
        col = range.start.character,
      }
    end
    cb(items, "ok")
  end, ctx.bufnr)
end

-- Callers via clangd call hierarchy (for function symbols): who *invokes* this, not every
-- textual mention. prepareCallHierarchy → incomingCalls; each caller is its own function.
function M.callers(ctx, cb)
  local c = client(ctx.bufnr)
  if not c then
    return cb(nil, "no_client")
  end
  c:request("textDocument/prepareCallHierarchy", pos_params(ctx), function(err, result)
    if err or not (result and result[1]) then
      return cb(nil, "empty")
    end
    c:request("callHierarchy/incomingCalls", { item = result[1] }, function(e2, calls)
      if e2 or not calls then
        return cb(nil, "empty")
      end
      local items = {}
      for _, call in ipairs(calls) do
        local f = call.from
        local range = f.selectionRange or f.range
        items[#items + 1] = {
          name = f.name,
          file = vim.uri_to_fname(f.uri),
          line = range.start.line + 1,
        }
      end
      cb(items, "ok")
    end, ctx.bufnr)
  end, ctx.bufnr)
end

-- Callees via clangd call hierarchy: what this function *calls* — the outbound direction, mirror of
-- callers. prepareCallHierarchy → outgoingCalls; each callee is its own function.
function M.callees(ctx, cb)
  local c = client(ctx.bufnr)
  if not c then
    return cb(nil, "no_client")
  end
  c:request("textDocument/prepareCallHierarchy", pos_params(ctx), function(err, result)
    if err or not (result and result[1]) then
      return cb(nil, "empty")
    end
    c:request("callHierarchy/outgoingCalls", { item = result[1] }, function(e2, calls)
      if e2 or not calls then
        return cb(nil, "empty")
      end
      local items = {}
      for _, call in ipairs(calls) do
        local f = call.to
        local range = f.selectionRange or f.range
        items[#items + 1] = {
          name = f.name,
          file = vim.uri_to_fname(f.uri),
          line = range.start.line + 1,
        }
      end
      cb(items, "ok")
    end, ctx.bufnr)
  end, ctx.bufnr)
end

-- exposed for unit tests (pure parse, no nvim needed); see tests/test_parse_layout.lua
M._parse_layout = parse_layout
M._spec_of = spec_of
M._subst_spec = subst_spec
M._requalify = requalify
M._namespace_from_md = namespace_from_md
M._parse_workspace_symbols = parse_workspace_symbols

return M
