-- bytemap.lua — W26: the struct's fields drawn on 64-byte cache lines as a picture. Each byte is
-- a per-field letter (a=first field, matching the Fields list order), '·' = padding gap, '░' =
-- free tail past the struct. A field that crosses a 64B boundary visibly spans two rows (a
-- straddle — the caller renders the header RED). Pure: fields + size in, grid strings out.
local M = {}
local LINE = 64
local LETTERS = "abcdefghijklmnopqrstuvwxyz"

-- fields: { {name, offset, size}, ... } (any order). total: struct size in bytes.
-- → { lines = {..}, straddle = bool, straddlers = {names} }  (or { lines = {msg} } on bad input)
function M.render(fields, total)
  if not fields or #fields == 0 or not total or total <= 0 then
    return { lines = { "(no field map)" }, straddle = false, straddlers = {} }
  end
  local nlines = math.ceil(total / LINE)
  local glyph, straddlers = {}, {}
  for i, f in ipairs(fields) do
    if f.offset and f.size and f.size > 0 then
      local ch = LETTERS:sub(((i - 1) % 26) + 1, ((i - 1) % 26) + 1)
      if math.floor((f.offset + f.size - 1) / LINE) > math.floor(f.offset / LINE) then
        straddlers[#straddlers + 1] = f.name or ("field " .. i)
      end
      for b = f.offset, f.offset + f.size - 1 do glyph[b] = ch end
    end
  end
  local lines = {}
  for l = 0, nlines - 1 do
    local row = {}
    for c = 0, LINE - 1 do
      local pos = l * LINE + c
      row[#row + 1] = glyph[pos] or (pos < total and "·" or "░")
    end
    lines[#lines + 1] = ("L%d │%s│"):format(l, table.concat(row))
  end
  return { lines = lines, straddle = #straddlers > 0, straddlers = straddlers }
end

return M
