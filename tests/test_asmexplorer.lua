-- asmexplorer: the -S -g asm → source-map builder + range filter (pure).
-- Run:  nvim -l tests/test_asmexplorer.lua
package.path = "./lua/?.lua;" .. package.path
local E = require("fox-symdeps.asmexplorer")

local pass, fail = 0, 0
local function ok(c, m) if c then pass = pass + 1 else fail = fail + 1; io.write("  ✗ " .. m .. "\n") end end

-- a clang-ish TU (main file index 0) with a data-dependent branch on source line 4
local clang = table.concat({
  '\t.file\t0 "/tmp" "probe.cpp"',
  '\t.loc\t0 3 1',
  "g:",
  '\t.loc\t0 4 9',
  "\tcmpq\t$100, (%rdi)",
  "\tjg\t.LBB0_1",
  '\t.loc\t0 5 1',
  "\tretq",
  "\t.cfi_endproc",
  ".Ldebug_info0:",   -- must be dropped (debug label after function end)
}, "\n")
local b = E.build(clang, "probe.cpp")
ok(b.src[#b.src] ~= nil, "built")
-- find the jg line
local jg
for i, d in ipairs(b.disp) do if d:find("jg", 1, true) then jg = i end end
ok(jg ~= nil, "jg present in display")
ok(b.src[jg] == 4, "jg mapped to source line 4")
ok(b.data[jg] == true, "jg flagged data-dependent (cmp reads memory)")
local hasdebug = false
for _, d in ipairs(b.disp) do if d:find("debug", 1, true) then hasdebug = true end end
ok(not hasdebug, "debug label dropped from display")

-- g++ dual-index: temp under BOTH .file 0 and .file 1, .loc keys off 1
local gpp = table.concat({
  '\t.file 0 "/tmp" "probe.cpp"',
  '\t.file 1 "probe.cpp"',
  '\t.loc 1 4 9 view .LVU1',
  "\tcmpq\t$100, (%rdi)",
  "\tjg\t.L4",
}, "\n")
local g = E.build(gpp, "probe.cpp")
local gjg
for i, d in ipairs(g.disp) do if d:find("jg", 1, true) then gjg = i end end
ok(gjg and g.src[gjg] == 4, "g++ dual-index: jg mapped to line 4 (uses index 1, not 0)")

-- filter_range keeps only lines within the enclosing function + re-indexes data flags. Line 4
-- ("  i3", src=4, data-dep) is in-range and is the 3rd surviving line after the src=8 line is dropped.
local built = { disp = { "a:", "  i1", "  i2", "  i3" }, src = { 3, 4, 8, 4 }, data = { [4] = true } }
local fr = E.filter_range(built, 3, 5)
ok(#fr.disp == 3, "range [3,5] keeps 3 of 4 lines (drops the src=8 line)")
ok(fr.data[3] == true, "the in-range data flag re-indexes onto the 3rd surviving line")
ok(fr.data[1] == nil and fr.data[2] == nil, "non-data lines carry no flag")
ok(E.filter_range(built, nil, nil) == built, "nil range → unchanged")

-- line_costs: instructions per source line (labels don't count)
local costed = {
  disp = { "g:", "    cmpq $1, (%rdi)", "    jg .L1", "    movl $7, %eax", "  .L1:", "    retq" },
  src  = { 4,    4,                     4,           5,                 5,        6 },
}
local lc = E.line_costs(costed)
ok(lc[4] == 2, "line 4 → 2 instructions (cmpq + jg; the 'g:' label doesn't count)")
ok(lc[5] == 1, "line 5 → 1 instruction (movl; the .L1: label doesn't count)")
ok(lc[6] == 1, "line 6 → 1 instruction (retq)")
ok(E.line_costs({ disp = {}, src = {} })[1] == nil, "empty → no costs")

io.write(("test_asmexplorer: %d passed, %d failed\n"):format(pass, fail))
os.exit(fail == 0 and 0 or 1)
