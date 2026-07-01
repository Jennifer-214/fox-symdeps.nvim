-- widthlit.lua — W21: find hardcoded width literals that silently break if a type's size changes
-- (the break class a sizeof-based static_assert can't catch). Heuristic SUSPECTS, not proof: the
-- size value as a bare number in a byte-ish context (array dim / mem*/fwrite size / stride /
-- alignas) on a line that does NOT already use sizeof. Review candidates. Generic + pure core.
local M = {}

local MEMFN = { "memcpy", "memmove", "memset", "memcmp", "fwrite", "fread" }

-- is this line a suspect hardcoded width literal for `size`? Pure.
function M.is_suspect(line, size)
  if not line or not size then return false end
  if line:find("sizeof", 1, true) then return false end -- already parameterized → safe
  local n = tostring(size)
  if not line:match("%f[%d]" .. n .. "%f[%D]") then return false end -- the size as a standalone number
  -- byte-ish context (raises precision above "any line with this number")
  if line:match("%[%s*" .. n .. "%s*%]") then return true end                 -- array dimension [N]
  if line:find("alignas", 1, true) then return true end                       -- alignas(N)
  if line:match("[%*%+]%s*" .. n .. "%f[%D]") or line:match("%f[%d]" .. n .. "%s*[%*%+]") then
    return true                                                                -- stride: *N / N* / +N / N+
  end
  for _, fn in ipairs(MEMFN) do if line:find(fn, 1, true) then return true end end -- mem*/f{write,read}(..N..)
  return false
end

-- scan `files` for suspect lines → { {file, line, text}, ... }. Sync (a handful of files, fast).
function M.scan(files, size)
  local seen, out = {}, {}
  for _, f in ipairs(files or {}) do
    if f and not seen[f] then
      seen[f] = true
      local ok, lines = pcall(vim.fn.readfile, f)
      if ok and lines then
        for i, line in ipairs(lines) do
          if M.is_suspect(line, size) then out[#out + 1] = { file = f, line = i, text = vim.trim(line) } end
        end
      end
    end
  end
  return out
end

return M
