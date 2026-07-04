-- includers.lua — "who includes this." clangd's symbol-references only find DIRECT textual uses of
-- a name; when a codebase reaches a type through aliases (`using Money = FixedPoint<10,8>`,
-- `using FP = FPN_Binary<F>`), those uses say "Money"/"FP" and never mention the underlying symbol,
-- so Consumers looks far thinner than reality. #include can't be aliased away — the set of files
-- that include the symbol's DEFINING header is the honest "used across N files" breadth signal.
local M = {}

-- rg-friendly literal: escape regex metachars in a filename basename ("FixedPointN.hpp").
local function esc(s) return (s:gsub("[%.%+%-%*%?%(%)%[%]%^%$]", "\\%0")) end

-- the #include-line pattern for a header basename: matches <base> or "base" after #include,
-- tolerating a path prefix ( #include "detail/FixedPointN.hpp" ). Pure — unit-tested.
function M.pattern(base)
  return "#include[[:space:]]*[<\"][^<>\"]*" .. esc(base) .. "[>\"]"
end

-- parse `rg --line-number` output lines → deduped { {file, line}, ... } (first include per file).
-- Pure so it's testable without a filesystem.
function M.parse(lines)
  local seen, res = {}, {}
  for _, l in ipairs(lines or {}) do
    local file, line = l:match("^(.-):(%d+):")
    if file and not seen[file] then
      seen[file] = true
      res[#res + 1] = { file = file, line = tonumber(line) }
    end
  end
  return res
end

-- the header that DEFINES `symbol`. Prefer a real struct/class/union definition in a header file;
-- fall back to an alias/typedef definition (so inspecting the alias itself still resolves a header).
function M.header_of(symbol, root)
  if not (symbol and root) then return nil end
  local hdr_globs = { "-g", "*.hpp", "-g", "*.h", "-g", "*.hh", "-g", "*.hxx" }
  local function first(pat)
    local args = { "rg", "--no-heading", "-l", "--color", "never" }
    vim.list_extend(args, hdr_globs)
    vim.list_extend(args, { "-e", pat, root })
    local ok, out = pcall(vim.fn.systemlist, args)
    return (ok and type(out) == "table") and out[1] or nil
  end
  return first("(struct|class|union)[[:space:]]+" .. symbol .. "[[:space:]{:<;]")
    or first("(using|typedef)[[:space:]].*[^%w_]" .. symbol .. "[[:space:]=;]")
end

-- files that #include `header` (matched by basename), each with the #include line. Deduped by file.
function M.includers(header, root)
  if not (header and root) then return {} end
  local base = header:gsub(".*/", "")
  local args = { "rg", "--no-heading", "--line-number", "--color", "never" }
  vim.list_extend(args, {
    "-g", "*.hpp", "-g", "*.h", "-g", "*.hh", "-g", "*.hxx",
    "-g", "*.cpp", "-g", "*.cc", "-g", "*.cxx", "-g", "*.c",
  })
  vim.list_extend(args, { "-e", M.pattern(base), root })
  local ok, out = pcall(vim.fn.systemlist, args)
  local list = M.parse((ok and type(out) == "table") and out or {})
  -- the defining header never includes itself, but a co-located file matching the same basename in
  -- another dir shouldn't be dropped — dedupe is by full path, so nothing to strip here.
  return list
end

-- symbol → sorted { {file, line}, ... } of files that #include its defining header (+ the header
-- path). {} if the header can't be located.
function M.of(symbol, root)
  local header = M.header_of(symbol, root)
  if not header then return {}, nil end
  local list = M.includers(header, root)
  table.sort(list, function(a, b) return a.file < b.file end)
  return list, header
end

return M
