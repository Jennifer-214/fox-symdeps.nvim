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

-- the concrete template spec named in a hover ("struct `Foo<64>`") → "Foo<64>", else nil.
local function spec_of(md)
  return md and md:match("([%w_:]+%b<>)") or nil
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
        if sz then
          cb({ size = sz.size, align = sz.align or (layout and layout.align), computed = true }, "ok")
        else
          cb(layout, layout and "ok" or "empty")
        end
      end)
    else
      cb(layout, layout and "ok" or "empty")
    end
  end, ctx.bufnr)
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

-- exposed for unit tests (pure parse, no nvim needed); see tests/test_parse_layout.lua
M._parse_layout = parse_layout
M._spec_of = spec_of

return M
