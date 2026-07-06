-- Unit tests for the W23 template-size probe's pure logic: compile-flag filtering + the
-- concrete-spec extraction that decides when to probe. Pure Lua: no nvim, no clangd, no clang.
-- Run:  nvim -l tests/test_sizeprobe.lua   (from the repo root)
package.path = "./lua/?.lua;" .. package.path
local filter = require("fox-symdeps.sizeprobe")._filter_flags
local spec_of = require("fox-symdeps.clangd")._spec_of

local pass, fail = 0, 0
local function eq(got, want, label)
  if got == want then pass = pass + 1
  else fail = fail + 1; io.write(("  ✗ %s (got %s, want %s)\n"):format(label, tostring(got), tostring(want))) end
end
local function same(got, want, label) -- list compare
  local ok = #got == #want
  if ok then for i = 1, #want do if got[i] ~= want[i] then ok = false break end end end
  if ok then pass = pass + 1
  else fail = fail + 1; io.write(("  ✗ %s (got [%s], want [%s])\n"):format(label, table.concat(got, " "), table.concat(want, " "))) end
end

-- 1. filter_flags: drops compiler, -c, -o X, and the input TU; keeps -I/-D/-std.
same(filter({ "clang++", "-std=gnu++17", "-I/x/inc", "-DFOO", "-c", "/x/a.cpp", "-o", "/x/a.o" }, "/x/a.cpp"),
  { "-std=gnu++17", "-I/x/inc", "-DFOO" }, "drops compiler/-c/-o/input, keeps std/I/D")
same(filter({ "clang++", "-Iinc", "src/main.cc" }, "src/main.cc"),
  { "-Iinc" }, "drops a .cc input by extension")
same(filter({ "g++", "-O2", "-isystem", "/sys", "file.cpp" }, "file.cpp"),
  { "-O2", "-isystem", "/sys" }, "keeps -isystem and its path (not an -o pair)")
same(filter({ "clang++", "-o", "out", "-DKEEP", "t.cxx" }, "t.cxx"),
  { "-DKEEP" }, "-o consumes only its argument")

-- 2. spec_of: extract the concrete instantiation that triggers a probe; nil for non-templates.
eq(spec_of("### struct `FPN_Binary<64>`\n\n```cpp\ntemplate <> struct FPN_Binary<64> {}\n```"),
  "FPN_Binary<64>", "concrete spec extracted")
eq(spec_of("### struct `T<8>`"), "T<8>", "simple spec")
eq(spec_of("### struct `Plain`\nSize: 16 bytes"), nil, "plain struct → no spec (no probe)")
eq(spec_of("### struct `T`\ntemplate <int N> struct T {}"), nil, "generic template def → no spec")
eq(spec_of(nil), nil, "nil md → nil")
-- injected-class-name of an un-instantiated primary template: the "args" are the template's OWN
-- parameter names → NOT probe-able (a sizeof probe hits "undeclared identifier RADIX"). Must be
-- nil so the HUD degrades to is_template. Regression for the FixedPoint<RADIX,FRAC> probe error.
eq(spec_of("### struct `FixedPoint<RADIX, FRAC>`\ntemplate <int RADIX, int FRAC> struct FixedPoint"),
  nil, "injected-class-name (param args) → no spec")
eq(spec_of("### struct `FPN_Binary<F>`\ntemplate <unsigned F> struct FPN_Binary"),
  nil, "single template param F → no spec")
eq(spec_of("### struct `FixedPoint<10, 8>`\ntemplate <int RADIX, int FRAC> struct FixedPoint"),
  "FixedPoint<10, 8>", "concrete args survive even with the template clause present")

io.write(("test_sizeprobe: %d passed, %d failed\n"):format(pass, fail))
os.exit(fail == 0 and 0 or 1)
