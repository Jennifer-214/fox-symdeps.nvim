-- Unit tests for W18 break-check diagnostic parsing: only FAILED static_asserts surface, keyed
-- by abs-file:line. (No clang here — that path is covered by the headless e2e.)
-- Run:  nvim -l tests/test_breakcheck.lua   (from the repo root)
package.path = "./lua/?.lua;" .. package.path
local parse = require("fox-symdeps.breakcheck").parse_failures

local pass, fail = 0, 0
local function ok(cond, label)
  if cond then pass = pass + 1 else fail = fail + 1; io.write("  ✗ " .. label .. "\n") end
end

local sample = table.concat({
  "/eng/FixedPoint/FixedPointN.hpp:44:1: error: static assertion failed: FPN_Binary<64> is 16B",
  "/eng/ML_Headers/GateControlNetwork.hpp:31:1: error: static assertion failed due to requirement 'sizeof(GCN_input<64>) == 96': size mismatch",
  "/eng/Foo.hpp:10:5: warning: unused variable 'x'",
  "/eng/Bar.hpp:20:1: error: use of undeclared identifier 'y'",
}, "\n")

local f = parse(sample)
ok(f["/eng/FixedPoint/FixedPointN.hpp:44"] ~= nil, "plain static_assert failure captured")
ok(f["/eng/ML_Headers/GateControlNetwork.hpp:31"] ~= nil, "requirement-form static_assert failure captured")
ok(f["/eng/Foo.hpp:10"] == nil, "a warning is NOT a break")
ok(f["/eng/Bar.hpp:20"] == nil, "a non-static_assert error is NOT a break")
local n = 0; for _ in pairs(f) do n = n + 1 end
ok(n == 2, "exactly two breaks parsed")
ok(parse(nil) and next(parse(nil)) == nil, "nil input → empty table")

io.write(("test_breakcheck: %d passed, %d failed\n"):format(pass, fail))
os.exit(fail == 0 and 0 or 1)
