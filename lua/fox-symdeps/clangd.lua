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

-- the concrete template spec named in a hover ("struct `Foo<64>`") → "Foo<64>", else nil.
-- An UN-instantiated primary template renders its injected-class-name with its OWN parameter
-- names (`FixedPoint<RADIX,FRAC>`, `FPN_Binary<F>`) — NOT probe-able: those identifiers exist
-- only inside the template, so a sizeof probe hits "use of undeclared identifier RADIX". Reject
-- such a pseudo-spec (any arg is a template parameter) → the caller degrades to is_template. A
-- real instantiation (`Foo<64>`, `FixedPoint<10,8>`) has literal / concrete args and survives.
local function spec_of(md)
  local spec = md and md:match("([%w_:]+%b<>)")
  if not spec then return nil end
  local params = tparam_names(md)
  for tok in spec:match("%b<>"):gmatch("[%a_][%w_]*") do
    if params[tok] then return nil end -- an arg names a template parameter → un-instantiated
  end
  return spec
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
    -- W23: clangd hover omits Size for a template instantiation. If the hover names a concrete
    -- spec (`Foo<...>`), recover size/align via a sizeof probe; else degrade gracefully.
    local spec = spec_of(md)
    if spec then
      require("fox-symdeps.sizeprobe").compute(ctx.bufnr, spec, function(sz)
        if sz and sz.size then
          cb({ size = sz.size, align = sz.align or (layout and layout.align), computed = true }, "ok")
        elseif sz and sz.error then
          cb({ probe_error = sz.error }, "probe_error") -- compile failed → surface it, don't blame the DB
        else
          cb(layout, layout and "ok" or "empty")
        end
      end)
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
M._namespace_from_md = namespace_from_md
M._parse_workspace_symbols = parse_workspace_symbols

return M
