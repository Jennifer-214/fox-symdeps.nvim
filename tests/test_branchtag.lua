-- branchtag: data-branch line extraction + per-function verdict (green/yellow/red). Pure.
-- Run:  nvim -l tests/test_branchtag.lua
package.path = "./lua/?.lua;" .. package.path
local B = require("fox-symdeps.branchtag")

local pass, fail = 0, 0
local function ok(c, m) if c then pass = pass + 1 else fail = fail + 1; io.write("  ✗ " .. m .. "\n") end end

-- a data-dependent branch (cmp reads memory) on line 5, a register/loop branch on line 6
local instrs = { "cmpq $1, (%rdi)", "jne .L1", "cmpl %eax, %ecx", "jl .L2", "retq" }
local srcl = { 5, 5, 6, 6, 7 }

local dl = B.data_lines(instrs, srcl)
ok(#dl == 1 and dl[1] == 5, "data_lines: only the memory-fed branch's line (5), not the register one (6)")

-- verdict for a function spanning lines 4..8: 2 branches, 1 data-dependent → RED "data"
local v = B.verdicts(instrs, srcl, { { lo = 4, hi = 8, sig = 4 } })
ok(#v == 1 and v[1].verdict == "data", "fn with a data-dependent branch → data (red)")
ok(v[1].nbr == 2 and v[1].ndata == 1, "counts: 2 branches, 1 data-dependent")
ok(v[1].sig == 4, "verdict rides the signature line")

-- a function with only register/loop branches → YELLOW "branches"
local v2 = B.verdicts({ "cmpl %eax, %ecx", "jl .L2" }, { 3, 3 }, { { lo = 2, hi = 4, sig = 2 } })
ok(v2[1].verdict == "branches" and v2[1].ndata == 0, "only non-data branches → branches (yellow)")

-- a function with NO branches → GREEN "branchless"
local v3 = B.verdicts({ "movq %rdi, %rax", "retq" }, { 3, 3 }, { { lo = 2, hi = 4, sig = 2 } })
ok(v3[1].verdict == "branchless" and v3[1].nbr == 0, "no branches → branchless (green)")

-- branches outside a function's range don't count toward it
local v4 = B.verdicts(instrs, srcl, { { lo = 10, hi = 20, sig = 10 } })
ok(v4[1].verdict == "branchless", "a function whose range holds no branch lines is branchless")

ok(#B.verdicts(instrs, srcl, {}) == 0, "no functions → no verdicts")

io.write(("test_branchtag: %d passed, %d failed\n"):format(pass, fail))
os.exit(fail == 0 and 0 or 1)
