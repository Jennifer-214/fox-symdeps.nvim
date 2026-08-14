-- sizeprobe.lua — recover sizeof/alignof for a TEMPLATE instantiation, which clangd hover omits
-- (W23: hover gives Size only for plain records, never for `Foo<N>`). We compile a COPY of the
-- current buffer + a size-extraction probe line and read the value out of the compiler error.
-- The engine source tree is never touched (temp file) and the buffer is never saved (no
-- format-on-save landmine). Generic: works on any C++ repo with a compile_commands.json.
local M = {}

local function is_source(a)
  return a:match("%.cpp$") or a:match("%.cc$") or a:match("%.cxx$") or a:match("%.c$") or a:match("%.mm$")
end

-- keep only usable flags: drop the compiler (argv[1]), -c, -o X, and the input TU. Pure.
local function filter_flags(args, entry_file)
  local keep, skipnext = {}, false
  for i, a in ipairs(args) do
    if skipnext then skipnext = false
    elseif i == 1 then         -- the compiler
    elseif a == "-c" then      -- compile-only (we use -fsyntax-only)
    elseif a == "-o" then skipnext = true
    elseif a == entry_file or is_source(a) then -- the input TU
    else keep[#keep + 1] = a end
  end
  return keep
end

-- usable compiler flags (drop the compiler, inputs, -c, -o X) from compile_commands.json found
-- upward from `file`'s dir. → flags(list), directory(string), compiler(string, args[0]) | nil.
-- The compiler (3rd value) lets asm tooling compile with the REAL toolchain (g++ vs clang) for a
-- 1:1 match with the shipped binary, not an isolated clang that diverges in instruction selection.
local function flags_for(file)
  local dir = vim.fn.fnamemodify(file, ":h")
  local cc = vim.fs.find("compile_commands.json", { upward = true, path = dir })[1]
  if not cc then return nil end
  -- TD-257 (the best-of-both split, operator 2026-08-14): FACTS read the SHIPPING db —
  -- build/compile_commands.json regenerates every configure and carries the real shipped
  -- flags (-DNDEBUG, target defines) — while the root symlink keeps serving the EDITOR its
  -- liveness db. Every probe/asm consumer of flags_for inherits shipped truth here.
  local ship = vim.fs.dirname(cc) .. "/build/compile_commands.json"
  if vim.fn.filereadable(ship) == 1 then cc = ship end
  local ok, txt = pcall(vim.fn.readfile, cc)
  if not ok then return nil end
  local okj, db = pcall(vim.json.decode, table.concat(txt, "\n"))
  if not okj or type(db) ~= "table" then return nil end
  local abs = vim.fn.fnamemodify(file, ":p")
  local entry
  for _, e in ipairs(db) do
    if e.file and vim.fn.fnamemodify(e.file, ":p") == abs then entry = e; break end
  end
  entry = entry or db[1]
  if not entry then return nil end
  local args = entry.arguments
  if not args then
    args = {}
    for tok in (entry.command or ""):gmatch("%S+") do args[#args + 1] = tok end
  end
  return filter_flags(args, entry.file), entry.directory, args[1]
end

-- compute { size, align } for `type_name` (e.g. "FPN_Binary<64>") as seen from `bufnr`. cb(tbl|nil).
function M.compute(bufnr, type_name, cb)
  local file = vim.api.nvim_buf_get_name(bufnr)
  if file == "" then return cb(nil) end
  local flags, dir = flags_for(file)
  if not flags then return cb(nil) end

  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  -- undefined-template trick: `__FoxSzP<sizeof(T)>` forces the constant into the diagnostic text.
  lines[#lines + 1] = "template<unsigned long> struct __FoxSzP;"
  lines[#lines + 1] = "template<unsigned long> struct __FoxAlP;"
  lines[#lines + 1] = ("__FoxSzP<sizeof(%s)> __fox_s; __FoxAlP<alignof(%s)> __fox_a;"):format(type_name, type_name)

  local tmp = vim.fn.tempname() .. ".cpp"
  local okw = pcall(vim.fn.writefile, lines, tmp)
  if not okw then return cb(nil) end

  local argv = { "clang++", "-fsyntax-only", "-ferror-limit=0", "-I" .. vim.fn.fnamemodify(file, ":h") }
  vim.list_extend(argv, flags)
  argv[#argv + 1] = tmp

  local ok = pcall(vim.system, argv, { cwd = dir or vim.fn.fnamemodify(file, ":h"), text = true }, function(res)
    pcall(os.remove, tmp)
    local out = (res.stderr or "") .. (res.stdout or "")
    local sz = out:match("__FoxSzP<(%d+)>")
    local al = out:match("__FoxAlP<(%d+)>")
    vim.schedule(function()
      if sz then
        return cb({ size = tonumber(sz), align = al and tonumber(al) or nil })
      end
      -- No value in the diagnostic → the probe TU failed to compile. Surface the first real error
      -- instead of letting it fall through to a "needs compile_commands.json" message downstream
      -- (LANDMINES L1: a compile failure must never masquerade as "no data").
      local err
      for line in (res.stderr or ""):gmatch("[^\n]+") do
        if line:find("error:", 1, true) then err = vim.trim(line); break end
      end
      cb({ error = err or "sizeof probe produced no value (type incomplete or not instantiable here)" })
    end)
  end)
  if not ok then pcall(os.remove, tmp); cb(nil) end
end

M._flags_for = flags_for      -- exposed for tests
M._filter_flags = filter_flags -- pure; exposed for tests
return M
