-- asmdiff.lua — W15: compile the buffer under a flag-set (-S), pull the function-under-cursor's
-- asm, and analyze it: instruction count, conditional branches (+ a branchless? verdict — the
-- engine's hot path is branchless, so this is a real check), calls, and SIMD/vectorization. Two
-- flag-sets diffed side by side answers "does -O3/-mavx2 change the codegen?". Generic core;
-- reuses sizeprobe._flags_for for the base compile flags. blocks()/analyze() are pure (tested).
local M = {}
local sizeprobe = require("fox-symdeps.sizeprobe")

local COND = { -- conditional jumps (a data-dependent branch); jmp/call/ret are control flow, not this
  je = 1, jne = 1, jz = 1, jnz = 1, jg = 1, jge = 1, jl = 1, jle = 1, ja = 1, jae = 1, jb = 1,
  jbe = 1, js = 1, jns = 1, jo = 1, jno = 1, jp = 1, jnp = 1, jc = 1, jnc = 1, jrcxz = 1,
  loop = 1, loope = 1, loopne = 1,
}

-- pure: split -S output into function blocks → { {label, lines={instruction lines}}, ... }.
-- A block starts at a non-dot label `name:` and ends at its `.size`; .Lxxx local labels + other
-- directives inside are skipped, instructions are cleaned (comment/whitespace stripped).
function M.blocks(asm_text)
  local out, cur = {}, nil
  for raw in (asm_text or ""):gmatch("[^\n]+") do
    local line = raw:gsub("#.*$", ""):gsub("%s+$", "") -- clang labels carry a trailing "# @name" comment
    local label = line:match("^([%w_%.%$@]+):%s*$")
    if label and label:sub(1, 1) ~= "." then
      cur = { label = label, lines = {} }; out[#out + 1] = cur
    elseif line:match("^%s*%.size") then
      cur = nil
    elseif line:match("^%s*%.") or label then
      -- directive or local (.Lxxx) label — skip, don't end the block
    elseif cur then
      local instr = line:gsub("^%s+", "")
      if instr ~= "" then cur.lines[#cur.lines + 1] = instr end
    end
  end
  return out
end

-- pure: metrics for a function's instruction lines.
function M.analyze(lines)
  local insns, cond, calls, branch_lines, vector = 0, 0, 0, {}, false
  for _, l in ipairs(lines or {}) do
    local op = l:match("^([%w]+)")
    if op then
      insns = insns + 1
      if COND[op] then cond = cond + 1; branch_lines[#branch_lines + 1] = l end
      if op == "call" then calls = calls + 1 end
      if l:match("[yz]mm%d") then vector = true end            -- 256/512-bit reg → wide SIMD
      if op:match("^vp") or op:match("^v%a+p[sd]$") then vector = true end -- packed AVX (vaddps/vpxor…)
    end
  end
  return {
    insns = insns, cond_branches = cond, branch_lines = branch_lines,
    calls = calls, vector = vector, branchless = cond == 0,
  }
end

-- strip optimization/arch flags from the base so the chosen flag-set fully controls codegen.
-- Critically also strip -flto/-emit-llvm: with LTO, `clang -S` emits LLVM IR, not x86 asm.
local function strip_opt(flags)
  local out = {}
  for _, f in ipairs(flags) do
    if not (f:match("^%-O") or f:match("^%-march") or f:match("^%-mavx") or f:match("^%-mtune")
        or f:match("^%-ffast%-math") or f:match("^%-mfma") or f:match("^%-msse")
        or f:match("^%-flto") or f == "-emit-llvm" or f:match("^%-fwhole%-program%-vtables")
        or f:match("^%-fsplit%-lto%-unit")) then
      out[#out + 1] = f
    end
  end
  return out
end

-- run(bufnr, fn_name, flagset, cb): compile the buffer copy `-S` under (base − opt) + flagset,
-- find the fn's block by demangled name, analyze. cb(result | {inlined=true} | nil).
function M.run(bufnr, fn_name, flagset, cb)
  local file = vim.api.nvim_buf_get_name(bufnr)
  if file == "" then return cb(nil) end
  local base, dir = sizeprobe._flags_for(file)
  if not base then return cb(nil) end
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  -- force a standalone emission even at -O2/-O3 (else static/inline hot-path fns optimize away):
  -- taking the address under [[gnu::used]] keeps a non-inlined copy to read.
  lines[#lines + 1] = ("[[gnu::used]] static auto __fox_keep = &%s;"):format(fn_name)
  local tmp = vim.fn.tempname() .. ".cpp"
  if not pcall(vim.fn.writefile, lines, tmp) then return cb(nil) end

  local argv = { "clang++", "-S", "-o", "-", "-I" .. vim.fn.fnamemodify(file, ":h") }
  vim.list_extend(argv, strip_opt(base))
  vim.list_extend(argv, flagset)
  argv[#argv + 1] = tmp

  local ok = pcall(vim.system, argv, { cwd = dir, text = true }, function(res)
    pcall(os.remove, tmp)
    local asm = res.stdout or ""
    local blocks = M.blocks(asm)
    if #blocks == 0 then return vim.schedule(function() cb(nil) end) end
    -- demangle all labels in one c++filt call, match the one containing fn_name
    local labels = {}
    for _, b in ipairs(blocks) do labels[#labels + 1] = b.label end
    local dem = {}
    local okd, out = pcall(function()
      return vim.system(vim.list_extend({ "c++filt" }, labels), { text = true }):wait().stdout or ""
    end)
    if okd then local i = 0; for line in out:gmatch("[^\n]+") do i = i + 1; dem[i] = line end end
    local hit
    for i, b in ipairs(blocks) do
      local name = dem[i] or b.label
      if name:find(fn_name, 1, true) then hit = b; break end
    end
    vim.schedule(function()
      if not hit then return cb({ inlined = true }) end
      local a = M.analyze(hit.lines)
      a.flagset = table.concat(flagset, " ")
      a.lines_shown = vim.list_slice(hit.lines, 1, 60) -- cap the displayed listing
      cb(a)
    end)
  end)
  if not ok then pcall(os.remove, tmp); cb(nil) end
end

M._strip_opt = strip_opt -- exposed for tests
return M
