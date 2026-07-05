-- status: the chip formatter (pure). Run:  nvim -l tests/test_status.lua
package.path = "./lua/?.lua;" .. package.path
local S = require("fox-symdeps.status")

local pass, fail = 0, 0
local function ok(c, m) if c then pass = pass + 1 else fail = fail + 1; io.write("  ✗ " .. m .. "\n") end end

ok(S.format({ symbol = "FixedPoint", size = 16 }) == "◇ FixedPoint 16B ✓", "≤64 B → ✓ (fits a cache line)")
ok(S.format({ symbol = "ExecutionCore", size = 66 }) == "◇ ExecutionCore 66B ▲", ">64 B → ▲ (spills a line)")
ok(S.format({ symbol = "Cell", size = 64 }) == "◇ Cell 64B ✓", "exactly 64 B still fits")
ok(S.format({ symbol = "RollingStats", is_template = true }) == "◇ RollingStats <T>", "template → <T> placeholder")
ok(S.format(nil) == "", "no facts → empty chip")
ok(S.format({}) == "", "no symbol → empty chip")
ok(S.format({ symbol = "Foo" }) == "", "symbol but no size (non-template) → empty (nothing to assert)")

io.write(("test_status: %d passed, %d failed\n"):format(pass, fail))
os.exit(fail == 0 and 0 or 1)
