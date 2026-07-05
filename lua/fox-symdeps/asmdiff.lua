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

-- pure: does a demangled block label name the function `fn_name`? EXACT match on the qualified name
-- with the argument list stripped — NOT a substring test. Substring made `add` match a `padding`
-- block and `tt::add` match `tt::add_fees`, silently reporting the wrong function's counts (a false
-- "branchless ✓" is a dangerous all-clear). Template args are normalized off for the fallback because
-- `<64>` demangles to `<64u>`; the [[gnu::used]] probe forces a single instantiation, so the base
-- name is unambiguous. `label` may be demangled ("tt::foo(int)") or a mangled fallback (won't match).
function M.name_matches(label, fn_name)
  if not label or not fn_name then return false end
  local lname = vim.trim(label:match("^(.-)%(") or label) -- drop the (arg list)
  if lname == fn_name then return true end
  if lname:find("<", 1, true) or fn_name:find("<", 1, true) then
    local lbase = lname:gsub("%b<>%s*$", "")
    local fbase = fn_name:gsub("%b<>%s*$", "")
    return lbase ~= "" and lbase == fbase -- exact base-name match (still not substring)
  end
  return false
end

-- ── data-dependent branch classification (heuristic, advisory) ───────────────────────────────────
-- A conditional branch is DATA-DEPENDENT when the compare/test that sets its flags reads a value
-- from MEMORY through a pointer register (a struct field / tick input) — the branch the CPU can't
-- reliably predict, the misprediction risk on a branchless hot path. A compare of only immediates /
-- registers never sourced from such a load (a loop bound, a constant) is NOT data-dependent. cmov
-- (branchless conditional move) is counted too — the GOOD codegen the branchless hot path wants.
local FLAG_PREFIX = { "cmp", "test", "sub", "add", "and", "or", "xor", "inc", "dec", "neg", "sbb", "adc", "bt" }
local function is_flag_setter(op)
  for _, p in ipairs(FLAG_PREFIX) do
    if op == p or op == p .. "b" or op == p .. "w" or op == p .. "l" or op == p .. "q" then return true end
  end
  return false
end
local REG = {
  rax = "a", eax = "a", ax = "a", al = "a", ah = "a", rbx = "b", ebx = "b", bx = "b", bl = "b", bh = "b",
  rcx = "c", ecx = "c", cx = "c", cl = "c", ch = "c", rdx = "d", edx = "d", dx = "d", dl = "d", dh = "d",
  rsi = "si", esi = "si", si = "si", sil = "si", rdi = "di", edi = "di", di = "di", dil = "di",
  rbp = "bp", ebp = "bp", bp = "bp", bpl = "bp", rsp = "sp", esp = "sp", sp = "sp", spl = "sp",
}
local function reg_core(r)
  r = r:gsub("^%%", "")
  return REG[r] or r:match("^(r1?[0-5])") or r
end
-- a memory dereference through a register base OTHER than %rip (rip-relative = a constant-pool load,
-- not runtime data). "8(%rdi)" / "(%rax,%rbx,8)" → true; ".LCPI0_0(%rip)" → false.
local function derefs_memory(instr)
  for reg in instr:gmatch("%(%%(%w+)") do if reg ~= "rip" then return true end end
  return false
end
M._is_flag_setter = is_flag_setter
M._derefs_memory = derefs_memory

-- pure: classify a function's conditional branches → { data, indep, cmov, total, details }. `data` =
-- the data-dependent (mispredict-risk) count; `cmov` = branchless conditional moves emitted. `details`
-- = { {idx, data}, ... } per conditional branch (idx into `lines`) so callers can map back to source.
function M.classify_branches(lines)
  local data, indep, cmov, details = 0, 0, 0, {}
  for i, l in ipairs(lines or {}) do
    local op = l:match("^(%S+)") or ""
    if op:match("^cmov") then cmov = cmov + 1 end
    if COND[op] then
      local setter
      for j = i - 1, math.max(1, i - 8), -1 do
        local jop = lines[j]:match("^(%S+)")
        if jop then
          if is_flag_setter(jop) then setter = j; break end
          if jop:match("^j") or jop == "ret" or jop == "retq" then break end -- prior branch/return → stop
        end
      end
      local dd = false
      if setter then
        local sl = lines[setter]
        if derefs_memory(sl) then
          dd = true -- the compare/test reads memory directly
        else
          local want = {} -- the registers the flag-setter reads
          for r in sl:gmatch("%%(%w+)") do want[reg_core("%" .. r)] = true end
          for k = setter - 1, math.max(1, setter - 8), -1 do
            local kl = lines[k]
            local kop = kl:match("^(%S+)")
            if kop and kop:match("^mov") and derefs_memory(kl) then
              local dest = kl:match("%%(%w+)%s*$") -- AT&T dest = last operand
              if dest and want[reg_core("%" .. dest)] then dd = true; break end
            end
          end
        end
      end
      if dd then data = data + 1 else indep = indep + 1 end
      details[#details + 1] = { idx = i, data = dd }
    end
  end
  return { data = data, indep = indep, cmov = cmov, total = data + indep, details = details }
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
  local bc = M.classify_branches(lines)
  return {
    insns = insns, cond_branches = cond, branch_lines = branch_lines,
    calls = calls, vector = vector, branchless = cond == 0,
    data_branches = bc.data, cmov = bc.cmov, -- data-dependent branch count + branchless moves
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
  if file == "" then return cb({ error = "buffer has no file on disk (save it first)" }) end
  local base, dir = sizeprobe._flags_for(file)
  if not base then return cb({ error = "no compile_commands.json found for this file" }) end
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  -- force a standalone emission even at -O2/-O3 (else static/inline hot-path fns optimize away):
  -- taking the address under [[gnu::used]] keeps a non-inlined copy to read.
  lines[#lines + 1] = ("[[gnu::used]] static auto __fox_keep = &%s;"):format(fn_name)
  local tmp = vim.fn.tempname() .. ".cpp"
  if not pcall(vim.fn.writefile, lines, tmp) then return cb({ error = "could not write temp source" }) end

  local argv = { "clang++", "-S", "-o", "-", "-I" .. vim.fn.fnamemodify(file, ":h") }
  vim.list_extend(argv, strip_opt(base))
  vim.list_extend(argv, flagset)
  argv[#argv + 1] = tmp

  local ok = pcall(vim.system, argv, { cwd = dir, text = true }, function(res)
    pcall(os.remove, tmp)
    local asm = res.stdout or ""
    local blocks = M.blocks(asm)
    if #blocks == 0 then
      -- compile produced no function blocks — surface WHY instead of a silent
      -- "unavailable". Pull the first real error line out of stderr.
      local err
      for line in (res.stderr or ""):gmatch("[^\n]+") do
        if line:find("error:", 1, true) then err = (line:gsub("^%s+", "")); break end
      end
      if not err and (res.code or 0) ~= 0 then err = "compile exited " .. tostring(res.code) end
      return vim.schedule(function() cb(err and { error = err } or nil) end)
    end
    -- demangle + match + analyze on the MAIN LOOP: c++filt uses vim.system
    -- :wait(), which throws E5560 in this fast-event on_exit context. The pcall
    -- would swallow it, fall back to the mangled label, and a qualified name
    -- like tt::foo would then never match (the "::" form only appears
    -- demangled). Deferring makes demangling reliable.
    vim.schedule(function()
      local labels = {}
      for _, b in ipairs(blocks) do labels[#labels + 1] = b.label end
      local dem = {}
      local okd, out = pcall(function()
        return vim.system(vim.list_extend({ "c++filt" }, labels), { text = true }):wait().stdout or ""
      end)
      if okd then local i = 0; for line in out:gmatch("[^\n]+") do i = i + 1; dem[i] = line end end
      -- Match the demangled qualified name EXACTLY (arg list stripped, template args normalized) —
      -- never a substring, which grabbed same-prefix siblings and reported the wrong function.
      local hit
      for i, b in ipairs(blocks) do
        if M.name_matches(dem[i] or b.label, fn_name) then hit = b; break end
      end
      if not hit then return cb({ inlined = true }) end
      local a = M.analyze(hit.lines)
      a.flagset = table.concat(flagset, " ")
      a.lines_shown = vim.list_slice(hit.lines, 1, 60) -- cap the displayed listing
      cb(a)
    end)
  end)
  if not ok then pcall(os.remove, tmp); cb({ error = "could not run clang++ (is it installed?)" }) end
end

M._strip_opt = strip_opt -- exposed for tests
return M
