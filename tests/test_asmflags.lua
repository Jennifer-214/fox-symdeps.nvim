-- W15 flag-set store: built-in defaults + pair resolution (with fallback). Pure.
-- Run:  nvim -l tests/test_asmflags.lua   (from the repo root)
package.path = "./lua/?.lua;" .. package.path
local F = require("fox-symdeps.asmflags")

local pass, fail = 0, 0
local function eq(a, b, m) if a == b then pass = pass + 1 else fail = fail + 1; io.write(("  ✗ %s (got %s want %s)\n"):format(m, tostring(a), tostring(b))) end end

eq(#F._DEFAULTS >= 2, true, "ships >= 2 default flag-sets")
eq(F._DEFAULTS[1].name, "O2", "first default is O2")

local st = { sets = F._DEFAULTS, a = "O2", b = "O3-native" }
local a, b = F._pair_from(st)
eq(a.name, "O2", "pair A resolves by name")
eq(b.name, "O3-native", "pair B resolves by name")
eq(a.flags[1], "-O2", "A carries its flags")

-- fallback when the saved name is gone
local a2, b2 = F._pair_from({ sets = F._DEFAULTS, a = "nope", b = "gone" })
eq(a2.name, F._DEFAULTS[1].name, "missing A → first set")
eq(b2.name, F._DEFAULTS[2].name, "missing B → second set")

io.write(("test_asmflags: %d passed, %d failed\n"):format(pass, fail))
os.exit(fail == 0 and 0 or 1)
