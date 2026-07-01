-- breakcheck.lua — compiler-truth break detection (W18). Compile the byte-layout enforcement
-- files and return which static_asserts FAIL: after you shrink a type, this is the exact set of
-- `static_assert(sizeof(T)==N)` guards that break — not a guess, the compiler's own verdict.
-- fwrite/memcmp sites can't fail at compile time, so they never surface here (honest — you can't
-- statically prove a runtime size mismatch). Compiles against the SAVED (on-disk) state. Generic:
-- any C++ repo with a compile_commands.json. Reuses the sizeprobe flag extraction.
local M = {}
local sizeprobe = require("fox-symdeps.sizeprobe")

-- parse clang diagnostics → { ["<abs file>:<line>"] = message } for FAILED static_asserts. Pure.
function M.parse_failures(out)
  local fails = {}
  for line in (out or ""):gmatch("[^\n]+") do
    local file, ln = line:match("^(.-):(%d+):%d+:%s+error:%s+static assertion failed")
    if file and ln then
      fails[vim.fn.fnamemodify(file, ":p") .. ":" .. ln] = (line:gsub("^.-error:%s+", ""))
    end
  end
  return fails
end

-- check(files, flags_file, cb): compile each unique file (#include it, -fsyntax-only) and report
-- cb(failset) keyed "<abs file>:<line>". flags_file seeds compile_commands lookup + flags.
function M.check(files, flags_file, cb)
  local flags, dir = sizeprobe._flags_for(flags_file)
  if not flags then return cb({}) end
  local seen, uniq = {}, {}
  for _, f in ipairs(files or {}) do
    local abs = f and vim.fn.fnamemodify(f, ":p")
    if abs and not seen[abs] then seen[abs] = true; uniq[#uniq + 1] = abs end
  end
  if #uniq == 0 then return cb({}) end

  local failset, pending = {}, #uniq
  local function done_one(out)
    for k, v in pairs(M.parse_failures(out)) do failset[k] = v end
    pending = pending - 1
    if pending == 0 then vim.schedule(function() cb(failset) end) end
  end

  for _, f in ipairs(uniq) do
    local tmp = vim.fn.tempname() .. ".cpp"
    local okw = pcall(vim.fn.writefile, { ('#include "%s"'):format(f) }, tmp)
    if not okw then
      done_one("")
    else
      local argv = { "clang++", "-fsyntax-only", "-ferror-limit=0" }
      vim.list_extend(argv, flags)
      argv[#argv + 1] = tmp
      local ok = pcall(vim.system, argv, { cwd = dir, text = true }, function(res)
        pcall(os.remove, tmp)
        done_one((res.stderr or "") .. (res.stdout or ""))
      end)
      if not ok then pcall(os.remove, tmp); done_one("") end
    end
  end
end

return M
