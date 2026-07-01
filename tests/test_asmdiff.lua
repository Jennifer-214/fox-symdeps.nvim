-- W15 asm analysis: block extraction from -S output + metrics (insns / cond branches / calls /
-- vector / branchless verdict). Pure. Run:  nvim -l tests/test_asmdiff.lua   (from repo root)
package.path = "./lua/?.lua;" .. package.path
local A = require("fox-symdeps.asmdiff")

local pass, fail = 0, 0
local function eq(a, b, m) if a == b then pass = pass + 1 else fail = fail + 1; io.write(("  ✗ %s (got %s want %s)\n"):format(m, tostring(a), tostring(b))) end end

local asm = table.concat({
  "\t.text",
  "\t.globl\t_ZL9money_addv",
  "_ZL9money_addv:                         # @money_add",
  "\tpushq\t%rbp",
  "\tmovq\t%rdi, %rax",
  "\taddq\t%rsi, %rax               # add",
  "\tadcq\t%rdx, %rdx",
  "\tje\t.LBB0_1",
  ".LBB0_1:",
  "\tvaddps\t%ymm0, %ymm1, %ymm2",
  "\tretq",
  "\t.size\t_ZL9money_addv, .-_ZL9money_addv",
  "\t.globl\tmain",
  "main:                                   # @main",
  "\txorl\t%eax, %eax",
  "\tretq",
  "\t.size\tmain, .-main",
}, "\n")

local blocks = A.blocks(asm)
eq(#blocks, 2, "two function blocks")
eq(blocks[1].label, "_ZL9money_addv", "first label")
eq(blocks[2].label, "main", "second label")
eq(#blocks[1].lines, 7, "money_add body = 7 instructions (.LBB0_1 label skipped, .size ends)")

local m = A.analyze(blocks[1].lines)
eq(m.insns, 7, "money_add insns")
eq(m.cond_branches, 1, "one conditional branch (je)")
eq(m.branchless, false, "not branchless (has je)")
eq(m.vector, true, "vectorized (ymm)")
eq(#m.branch_lines, 1, "branch line captured")

local mm = A.analyze(blocks[2].lines)
eq(mm.insns, 2, "main insns")
eq(mm.cond_branches, 0, "main has no conditional branch")
eq(mm.branchless, true, "main is branchless")
eq(mm.vector, false, "main not vectorized")

eq(#A.blocks(""), 0, "empty asm → no blocks")

-- strip_opt: removes opt/arch/LTO flags (so -S emits native asm, not LLVM IR), keeps the rest
local so = A._strip_opt({ "-std=c++17", "-O2", "-flto", "-flto=thin", "-march=native", "-emit-llvm", "-Iinc", "-DFOO" })
eq(table.concat(so, " "), "-std=c++17 -Iinc -DFOO", "strips -O/-flto/-march/-emit-llvm, keeps std/I/D")

io.write(("test_asmdiff: %d passed, %d failed\n"):format(pass, fail))
os.exit(fail == 0 and 0 or 1)
