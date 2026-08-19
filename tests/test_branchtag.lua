-- branchtag: shipped-sidecar parse + data-branch line extraction + per-function verdict
-- (green/yellow/red/dim). Pure.  Run:  nvim -l tests/test_branchtag.lua
package.path = "./lua/?.lua;" .. package.path
local B = require("fox-symdeps.branchtag")

local pass, fail = 0, 0
local function ok(c, m) if c then pass = pass + 1 else fail = fail + 1; io.write("  ✗ " .. m .. "\n") end end

-- ── parse_shipped: objdump -l text → (instrs, srclines) attributed to THIS file only ────────
local SRC = "/home/x/CoreFrameworks/ExecutionCore.hpp"
local fixture = {
  "0000000000045000 <SomeFn(ExecutionCore<64>*)>:",
  "SomeFn():",
  SRC .. ":100",
  "   45000:\tmov    (%rdi),%rax",
  "   45003:\ttest   %rax,%rax",
  "   45006:\tje     45010 <SomeFn+0x10>        # annotation stripped",
  "/usr/include/other.hpp:9",
  "   45008:\tadd    $0x1,%rbx",
  "",
  "0000000000046000 <Other()>:",
  "   46000:\tret",
}
local instrs, srcl = B.parse_shipped(fixture, SRC)
ok(#instrs == 5, "parse_shipped: every instruction row extracted (got " .. #instrs .. ")")
ok(srcl[1] == 100 and srcl[2] == 100 and srcl[3] == 100,
  "instructions under a this-file marker attribute to its line")
ok(instrs[3] == "je     45010 <SomeFn+0x10>" or instrs[3]:match("^je"),
  "trailing # annotation stripped from the instruction")
ok(srcl[4] == 0, "an inlined-from-another-file run attributes to 0, never this file's lines")
ok(srcl[5] == 0, "a new block resets attribution — never inherits the previous block's line")

-- workspace-symlink root: same basename+parent under a different root still attributes
local instrs2, srcl2 = B.parse_shipped(
  { "/other/root/CoreFrameworks/ExecutionCore.hpp:7", "   1:\tret" }, SRC)
ok(#instrs2 == 1 and srcl2[1] == 7, "same_source basename+parent rule reaches across roots")

-- ── data_lines + verdicts (operate on any (instrs, srclines) pair) ──────────────────────────
-- a data-dependent branch (cmp reads memory) on line 5, a register/loop branch on line 6
local di = { "cmpq $1, (%rdi)", "jne .L1", "cmpl %eax, %ecx", "jl .L2", "retq" }
local ds = { 5, 5, 6, 6, 7 }

local dl = B.data_lines(di, ds)
ok(#dl == 1 and dl[1] == 5, "data_lines: only the memory-fed branch's line (5), not the register one (6)")

-- verdict for a function spanning lines 4..8: branch lines 5+6, line 5 data-dependent → RED
local v = B.verdicts(di, ds, { { lo = 4, hi = 8, sig = 4 } })
ok(#v == 1 and v[1].verdict == "data", "fn with a data-dependent branch → data (red)")
ok(v[1].nbr == 2 and v[1].ndata == 1, "counts: 2 branch lines, 1 data-dependent")
ok(v[1].sig == 4, "verdict rides the signature line")

-- the SAME source branch inlined 3× counts ONCE (distinct-line counting — a hot header
-- inlines into many callers; instruction-counting would report one branch dozens of times)
local mi = { "cmpq $1, (%rdi)", "jne .L1", "cmpq $1, (%rdi)", "jne .L1", "cmpq $1, (%rdi)", "jne .L1" }
local ms = { 5, 5, 5, 5, 5, 5 }
local mv = B.verdicts(mi, ms, { { lo = 4, hi = 8, sig = 4 } })
ok(mv[1].nbr == 1 and mv[1].ndata == 1, "inline multiplicity: one source branch line counts once")

-- a function with only register/loop branches → YELLOW "branches"
local v2 = B.verdicts({ "cmpl %eax, %ecx", "jl .L2" }, { 3, 3 }, { { lo = 2, hi = 4, sig = 2 } })
ok(v2[1].verdict == "branches" and v2[1].ndata == 0, "only non-data branches → branches (yellow)")

-- a function with instructions and NO branches → GREEN "branchless"
local v3 = B.verdicts({ "movq %rdi, %rax", "retq" }, { 3, 3 }, { { lo = 2, hi = 4, sig = 2 } })
ok(v3[1].verdict == "branchless" and v3[1].nbr == 0, "no branches (with real codegen) → branchless (green)")

-- RC-E law: a function with ZERO attributed instructions is NEVER greened — "nocode", not
-- "branchless" (the old assertion here encoded the false-green: a template that emitted
-- nothing under the buffer compile was painted ✓ branchless on the hot tick function)
local v4 = B.verdicts(di, ds, { { lo = 10, hi = 20, sig = 10 } })
ok(v4[1].verdict == "nocode" and v4[1].nins == 0, "zero attributed instructions → nocode (dim), never green")

ok(#B.verdicts(di, ds, {}) == 0, "no functions → no verdicts")

io.write(("test_branchtag: %d passed, %d failed\n"):format(pass, fail))
os.exit(fail == 0 and 0 or 1)
