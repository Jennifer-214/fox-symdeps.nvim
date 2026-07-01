-- Per-field cache-line map via clangd documentSymbol + per-field hover (offset/size).
-- Surfaces packing: which fields share a 64 B line, the padding gaps, and any field that
-- straddles a line boundary (a split-load / false-sharing smell on the hot path).
local M = {}

local function client(bufnr)
  return vim.lsp.get_clients({ bufnr = bufnr, name = "clangd" })[1]
end

-- parse a field's clangd hover → { offset, size, type } (type = W22 "what it contains"). Pure.
local function parse_field(md)
  if not md then return nil end
  local off = md:match("[Oo]ffset:%s*(%d+)")
  if not off then return nil end
  local ty = md:match("Type:%s*`([^`]+)`") or md:match("Type:%s*([^\n]+)")
  return {
    offset = tonumber(off),
    size = tonumber(md:match("[Ss]ize:%s*(%d+)")) or 0,
    type = ty and vim.trim(ty) or nil,
  }
end

local function find_fields(symbols, name)
  for _, s in ipairs(symbols or {}) do
    if s.name == name and s.children then return s.children end
    if s.children then
      local f = find_fields(s.children, name)
      if f then return f end
    end
  end
  return nil
end

-- async: cb(fields, state) where fields = { {name, offset, size} } sorted by offset.
function M.fields(ctx, cb)
  local c = client(ctx.bufnr)
  if not c then return cb(nil, "no_client") end
  local td = { uri = vim.uri_from_bufnr(ctx.bufnr) }
  c:request("textDocument/documentSymbol", { textDocument = td }, function(err, syms)
    if err or not syms then return cb(nil, "empty") end
    local fields = find_fields(syms, ctx.symbol)
    if not fields or #fields == 0 then return cb(nil, "empty") end
    local out, pending = {}, #fields
    for _, fld in ipairs(fields) do
      local pos = (fld.selectionRange or fld.range).start
      c:request("textDocument/hover", { textDocument = td, position = pos }, function(e2, res)
        if not e2 and res and res.contents then
          local md = type(res.contents) == "table" and (res.contents.value or "") or tostring(res.contents)
          local pf = parse_field(md)
          if pf then
            out[#out + 1] = { name = fld.name, offset = pf.offset, size = pf.size, type = pf.type }
          end
        end
        pending = pending - 1
        if pending == 0 then
          table.sort(out, function(a, b) return a.offset < b.offset end)
          cb(out, "ok")
        end
      end, ctx.bufnr)
    end
  end, ctx.bufnr)
end

M._parse_field = parse_field -- exposed for tests
return M
