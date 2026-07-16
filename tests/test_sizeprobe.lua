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
-- parameter names → NOT probe-able as-is (a sizeof probe hits "undeclared identifier RADIX").
-- Contract (dependent-spec substitution): the spec is returned WITH its param args listed, so
-- layout() can substitute canonical values from config template_args (or degrade to is_template
-- naming the unmapped param). Supersedes the old reject-to-nil behavior.
local s1, p1 = spec_of("### struct `FixedPoint<RADIX, FRAC>`\ntemplate <int RADIX, int FRAC> struct FixedPoint")
eq(s1, "FixedPoint<RADIX, FRAC>", "injected-class-name → spec returned")
same(p1, { "RADIX", "FRAC" }, "injected-class-name → param args listed")
local s2, p2 = spec_of("### struct `FPN_Binary<F>`\ntemplate <unsigned F> struct FPN_Binary")
eq(s2, "FPN_Binary<F>", "single template param F → spec returned")
same(p2, { "F" }, "single template param F → param arg listed")
local s3, p3 = spec_of("### struct `FixedPoint<10, 8>`\ntemplate <int RADIX, int FRAC> struct FixedPoint")
eq(s3, "FixedPoint<10, 8>", "concrete args survive even with the template clause present")
same(p3, {}, "concrete args → no param args")

-- 3. subst_spec: canonical-arg substitution for dependent spellings (the variable-hover case:
-- hovering `core` of type `ExecutionCore<F> *` gives no template clause — the spec looks
-- concrete, and only substitution makes the probe compile at file scope).
local subst = require("fox-symdeps.clangd")._subst_spec
local r1, a1 = subst("ExecutionCore<F>", { F = "64" })
eq(r1, "ExecutionCore<64>", "F substituted")
same(a1, { "F=64" }, "substitution recorded for the @ label")
local r2, a2 = subst("SPSCRing<TradeEvent<F>, 1024>", { F = "64" })
eq(r2, "SPSCRing<TradeEvent<64>, 1024>", "nested dependent arg substituted; literals untouched")
same(a2, { "F=64" }, "nested substitution recorded once")
local r3, a3 = subst("Foo<MAX_ORDERS>", { F = "64" })
eq(r3, "Foo<MAX_ORDERS>", "unmapped identifier (real file-scope constant) passes through")
same(a3, {}, "no substitution recorded when nothing mapped")
local r4, a4 = subst("FixedPoint<10, 8>", { F = "64" })
eq(r4, "FixedPoint<10, 8>", "concrete spec untouched")
same(a4, {}, "concrete spec records nothing")
local r5, a5 = subst("Pair<F, FRAC>", { F = "64", FRAC = "8" })
eq(r5, "Pair<64, 8>", "multiple params substituted")
same(a5, { "F=64", "FRAC=8" }, "multiple substitutions recorded in arg order")
-- a param named `F` must never rewrite `FLAGS` — whole-token match only
eq(subst("Foo<FLAGS>", { F = "64" }), "Foo<FLAGS>", "prefix-sharing identifier NOT rewritten")
local r7, a7 = subst("tt::ExecutionCore<F>", { F = "64" })
eq(r7, "tt::ExecutionCore<64>", "namespace-qualified spec substituted")
same(a7, { "F=64" }, "qualified spec records the substitution")

-- 4. requalify: rebuild the probe spelling around clang's did-you-mean suggestion — the
-- namespaced-type retry (probe compiles at FILE scope; `ExecutionCore<64>` needs `tt::` there).
local requalify = require("fox-symdeps.clangd")._requalify
eq(requalify("ExecutionCore<64>", "tt::ExecutionCore"), "tt::ExecutionCore<64>",
  "did-you-mean requalifies the head, args preserved")
eq(requalify("ExecutionCore<64>", "a::b::ExecutionCore"), "a::b::ExecutionCore<64>",
  "nested namespaces requalify")
eq(requalify("ExecutionCore<64>", "tt::SomethingElse"), nil,
  "unrelated fuzzy suggestion rejected (never chase a wrong sizeof)")
eq(requalify("ExecutionCore<64>", "ExecutionCore"), nil, "suggestion == head → nothing to fix")
eq(requalify("ExecutionCore<64>", "MyExecutionCore"), nil,
  "suffix-sharing but unqualified suggestion rejected (:: required)")
eq(requalify("ExecutionCore<64>", nil), nil, "no suggestion → nil")
eq(requalify("Plain", "tt::Plain"), nil, "no angle args → not a probe spelling → nil")

io.write(("test_sizeprobe: %d passed, %d failed\n"):format(pass, fail))
os.exit(fail == 0 and 0 or 1)
