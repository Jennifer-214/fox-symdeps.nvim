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

-- name_matches: EXACT qualified-name match, never substring (the wrong-function trust bug)
local function tt(label, fn, want, m) eq(A.name_matches(label, fn), want, m) end
tt("tt::add(int, int)", "tt::add", true, "exact demangled match (arg list stripped)")
tt("tt::parse_double_fast(char const*)", "tt::parse_double_fast", true, "exact match with args")
tt("padding()", "add", false, "'add' must NOT match a padding() block (substring bug)")
tt("tt::add_fees(int)", "tt::add", false, "'tt::add' must NOT match tt::add_fees (same-prefix sibling)")
tt("tt::address(char*)", "tt::add", false, "'tt::add' must NOT match tt::address")
tt("tt::ExecutionCore_Init<64u>(tt::Config&)", "tt::ExecutionCore_Init<64>", true, "template <64> matches demangled <64u>")
tt("tt::ExecutionCore_Init<64u>(x)", "tt::ExecutionCore_Init", true, "templated label matches un-templated fn base")
tt("tt::Other_Init<64u>(x)", "tt::ExecutionCore_Init<64>", false, "different template base does not match")
tt("_ZN2tt3addEi", "tt::add", false, "a mangled fallback label does not spuriously match")
tt(nil, "tt::add", false, "nil label → no match")

-- strip_opt: removes opt/arch/LTO flags (so -S emits native asm, not LLVM IR), keeps the rest
local so = A._strip_opt({ "-std=c++17", "-O2", "-flto", "-flto=thin", "-march=native", "-emit-llvm", "-Iinc", "-DFOO" })
eq(table.concat(so, " "), "-std=c++17 -Iinc -DFOO", "strips -O/-flto/-march/-emit-llvm, keeps std/I/D")

io.write(("test_asmdiff: %d passed, %d failed\n"):format(pass, fail))
os.exit(fail == 0 and 0 or 1)
