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
-- cb(failset, errors). failset keyed "<abs file>:<line>" = FAILED static_asserts. errors =
-- { "<file>: <reason>", ... } for files that could NOT be compiled — so a break-check that never
-- actually ran is reported as UNVERIFIED, never as a false "nothing broke". flags_file seeds
-- compile_commands lookup + flags.
function M.check(files, flags_file, cb)
  local flags, dir = sizeprobe._flags_for(flags_file)
  if not flags then return cb({}, { "no compile_commands.json — break-check could not run" }) end
  local seen, uniq = {}, {}
  for _, f in ipairs(files or {}) do
    local abs = f and vim.fn.fnamemodify(f, ":p")
    if abs and not seen[abs] then seen[abs] = true; uniq[#uniq + 1] = abs end
  end
  if #uniq == 0 then return cb({}, {}) end

  local failset, errors, pending = {}, {}, #uniq
  local function finish()
    pending = pending - 1
    if pending == 0 then vim.schedule(function() cb(failset, errors) end) end
  end
  local function fail_to_run(file, why)
    errors[#errors + 1] = vim.fn.fnamemodify(file, ":t") .. ": " .. why
    finish()
  end

  for _, f in ipairs(uniq) do
    local tmp = vim.fn.tempname() .. ".cpp"
    if not pcall(vim.fn.writefile, { ('#include "%s"'):format(f) }, tmp) then
      fail_to_run(f, "could not write temp source")
    else
      local argv = { "clang++", "-fsyntax-only", "-ferror-limit=0" }
      vim.list_extend(argv, flags)
      argv[#argv + 1] = tmp
      local ok = pcall(vim.system, argv, { cwd = dir, text = true }, function(res)
        pcall(os.remove, tmp)
        local out = (res.stderr or "") .. (res.stdout or "")
        local fails = M.parse_failures(out)
        for k, v in pairs(fails) do failset[k] = v end
        -- Non-zero exit with NO static_assert failure means the file failed to
        -- compile for some OTHER reason → its asserts were never actually
        -- checked. Record it so a broken build isn't reported as "clean".
        if (res.code or 0) ~= 0 and next(fails) == nil then
          errors[#errors + 1] = vim.fn.fnamemodify(f, ":t") .. ": " .. (out:match("error:%s*([^\n]+)") or "compile failed")
        end
        finish()
      end)
      if not ok then pcall(os.remove, tmp); fail_to_run(f, "could not run clang++") end
    end
  end
end

return M
