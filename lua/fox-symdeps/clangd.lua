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
    cb(parse_layout(md), "ok")
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

-- exposed for unit tests (pure parse, no nvim needed); see tests/test_parse_layout.lua
M._parse_layout = parse_layout

return M
