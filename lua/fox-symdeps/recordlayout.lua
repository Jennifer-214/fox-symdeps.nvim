-- recordlayout.lua — struct census straight from the compiler. Compiles the current TU (a copy of
-- the buffer, source tree untouched) with `-Xclang -fdump-record-layouts` and parses every record's
-- sizeof / align / top-level field offsets out of the dump. Reliable sizes with no clangd round-trip
-- per type — feeds the dashboard's "biggest structs" (cache-residency) tile. Generic: any C++ repo
-- with a compile_commands.json. parse() is pure (unit-tested); census() is the impure compile driver.
local M = {}
local sizeprobe = require("fox-symdeps.sizeprobe")

-- library/compiler noise we never want in a project census: std::, __impl, _Reserved, anon/lambda.
local function is_noise(name)
  return name:match("^std::") ~= nil
    or name:match("^__") ~= nil
    or name:match("^_[%u]") ~= nil
    or name:find("anonymous", 1, true) ~= nil
    or name:find("lambda", 1, true) ~= nil
end
M._is_noise = is_noise

-- pure: parse `-fdump-record-layouts` output → { { name, size, align, offsets = {N,...} }, ... }.
-- The dump repeats a block per record:
--     *** Dumping AST Record Layout
--              0 | struct tt::ExecutionCore
--              0 |   int seqlock
--              8 |   double pnl
--                | [sizeof=64, dsize=64, align=64,
--                |  nvsize=64, nvalign=64]
-- We take the first `N | struct/class/union NAME` as the record name, the offset column of the
-- remaining `N | …` lines as field offsets, and `[sizeof=…]` / ` align=…` as the size/align. Deduped
-- by name (a later, more-complete dump wins), project records only (is_noise filtered).
function M.parse(dump)
  local records, order, seen = {}, {}, {}
  local cur
  local function flush()
    if cur and cur.name and cur.size and not is_noise(cur.name) then
      if not seen[cur.name] then seen[cur.name] = true; order[#order + 1] = cur.name end
      records[cur.name] = cur
    end
    cur = nil
  end
  for line in (dump or ""):gmatch("[^\n]+") do
    if line:find("Dumping AST Record Layout", 1, true) then
      flush(); cur = { offsets = {} }
    elseif cur then
      local named = false
      if not cur.name then
        local kind, name = line:match("^%s*%d+ | (%a+) (.+)$")
        if kind == "struct" or kind == "class" or kind == "union" then
          cur.name = vim.trim(name); named = true
        end
      end
      local sz = line:match("%[sizeof=(%d+)")
      if sz then cur.size = tonumber(sz) end
      local al = line:match(" align=(%d+)") -- leading space so it never matches nv align/nvalign
      if al and not cur.align then cur.align = tonumber(al) end
      if not named and cur.name then
        local off = line:match("^%s*(%d+) |")
        if off then cur.offsets[#cur.offsets + 1] = tonumber(off) end
      end
    end
  end
  flush()
  local out = {}
  for _, name in ipairs(order) do out[#out + 1] = records[name] end
  return out
end

-- census(bufnr, cb): compile the buffer's TU with the record-layout dump on, parse it.
-- cb({ records = {...} }) on success, cb({ error = "…" }) with the first compiler error otherwise.
function M.census(bufnr, cb)
  local file = vim.api.nvim_buf_get_name(bufnr)
  if file == "" then return cb({ error = "buffer has no file on disk (save it first)" }) end
  local flags, dir = sizeprobe._flags_for(file)
  if not flags then return cb({ error = "no compile_commands.json found for this file" }) end
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local tmp = vim.fn.tempname() .. ".cpp"
  if not pcall(vim.fn.writefile, lines, tmp) then return cb({ error = "could not write temp source" }) end

  local argv = { "clang++", "-fsyntax-only", "-ferror-limit=0",
    "-Xclang", "-fdump-record-layouts", "-I" .. vim.fn.fnamemodify(file, ":h") }
  vim.list_extend(argv, flags)
  argv[#argv + 1] = tmp

  local ok = pcall(vim.system, argv, { cwd = dir or vim.fn.fnamemodify(file, ":h"), text = true }, function(res)
    pcall(os.remove, tmp)
    local dump = (res.stdout or "") .. "\n" .. (res.stderr or "")
    local recs = M.parse(dump)
    vim.schedule(function()
      if #recs == 0 then
        local err
        for l in (res.stderr or ""):gmatch("[^\n]+") do
          if l:find("error:", 1, true) then err = vim.trim(l); break end
        end
        cb({ error = err or "no records dumped (does this TU compile?)" })
      else
        cb({ records = recs })
      end
    end)
  end)
  if not ok then pcall(os.remove, tmp); cb({ error = "could not run clang++ (is it installed?)" }) end
end

return M
