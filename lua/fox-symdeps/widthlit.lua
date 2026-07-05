-- widthlit.lua — W21: find hardcoded width literals that silently break if a type's size changes
-- (the break class a sizeof-based static_assert can't catch). Heuristic SUSPECTS, not proof: the
-- size value as a bare number in a byte-ish context (array dim / mem*/fwrite size / stride /
-- alignas) on a line that does NOT already use sizeof. Review candidates. Generic + pure core.
--
-- Precision note (trust): the bare `*N`/`+N` stride rule is only applied for size > 8. At 4 and 8 —
-- the two most common widths in this engine (every pointer / int64 / fixed-point type is 8 B) —
-- `idx*8+off` and `seed+4` are ubiquitous ordinary arithmetic unrelated to the type, so the stride
-- rule there is pure noise that buries the real suspects. The strong contexts (byte-array dim,
-- alignas, mem* with the literal as an actual argument) stay on at all sizes.
local M = {}

local MEMFN = { "memcpy", "memmove", "memset", "memcmp", "fwrite", "fread" }
local STRIDE_MIN = 8 -- below this the bare */+ stride heuristic is noise; require a strong context

-- is this line a suspect hardcoded width literal for `size`? Pure.
function M.is_suspect(line, size)
  if not line or not size then return false end
  local code = line:gsub("//.*$", "")            -- drop line comments (the // ...16... noise)
  local trimmed = vim.trim(code)
  if trimmed == "" or trimmed:match("^%*") or trimmed:match("^/%*") then return false end -- comment-only / block line
  if code:find("sizeof", 1, true) then return false end -- already parameterized → safe
  local n = tostring(size)
  if not code:match("%f[%d]" .. n .. "%f[%D]") then return false end -- the size as a standalone number
  -- byte-ish context (raises precision above "any line with this number")
  local dim = "[%w_]+%s*%[%s*" .. n .. "%s*%]"                                 -- name[N]
  if code:match("char%s+" .. dim) or code:match("u?int8_t%s+" .. dim)
    or code:match("byte%s+" .. dim) then
    return true                                                                -- BYTE array [N] (== N bytes; wider T[N] is element count, skip)
  end
  if code:find("alignas", 1, true) then return true end                       -- alignas(N)
  -- mem*/f{write,read}: require N to be an ACTUAL ARGUMENT inside the call's parens, not merely
  -- co-occurring on the line (at size 8, half the memcpy/memset calls mention 8 incidentally).
  for _, fn in ipairs(MEMFN) do
    local args = code:match(fn .. "%s*(%b())")
    if args and args:match("%f[%d]" .. n .. "%f[%D]") then return true end
  end
  -- bare stride: only a signal for uncommon widths (> 8); at 4/8 it's ordinary arithmetic.
  if size > STRIDE_MIN
    and (code:match("[%*%+]%s*" .. n .. "%f[%D]") or code:match("%f[%d]" .. n .. "%s*[%*%+]")) then
    return true                                                                -- stride: *N / N* / +N / N+
  end
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
