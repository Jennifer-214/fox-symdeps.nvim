-- asmview: pure comparison-cell helpers (status classification, instruction-delta formatting).
-- Run:  nvim -l tests/test_asmview.lua   (from the repo root)
package.path = "./lua/?.lua;" .. package.path
local A = require("fox-symdeps.asmview")

local pass, fail = 0, 0
local function ok(c, m) if c then pass = pass + 1 else fail = fail + 1; io.write("  ✗ " .. m .. "\n") end end

-- status: nil when metrics present, else a reason string
ok(A._status({ insns = 10 }) == nil, "has insns → no status note")
ok(A._status(nil) ~= nil, "nil result → note")
ok(A._status({ inlined = true }):find("inlined", 1, true), "inlined → 'inlined' note")
ok(A._status({ error = "boom" }) == "boom", "error → the error text")

-- ins_cell: reference column (nil other) has no delta; compare column shows signed delta
ok(A._ins_cell({ insns = 83 }, nil) == "83", "reference column is bare count")
local c = A._ins_cell({ insns = 71 }, { insns = 83 })
ok(c:find("71", 1, true) == 1, "compare column starts with its own count")
ok(c:find("−12", 1, true) ~= nil, "fewer instructions → −12 with a real minus glyph")
ok(A._ins_cell({ insns = 90 }, { insns = 83 }):find("+7", 1, true) ~= nil, "more instructions → +7")
ok(A._ins_cell({ insns = 83 }, { insns = 83 }) == "83", "equal counts → no delta suffix")
ok(A._ins_cell({ inlined = true }, { insns = 83 }) == "—", "inlined column → em dash")

io.write(("test_asmview: %d passed, %d failed\n"):format(pass, fail))
os.exit(fail == 0 and 0 or 1)
