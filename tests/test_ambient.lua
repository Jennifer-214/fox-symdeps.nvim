-- ambient: inline layout-tag note (pure). Run:  nvim -l tests/test_ambient.lua
package.path = "./lua/?.lua;" .. package.path
local A = require("fox-symdeps.ambient")

local pass, fail = 0, 0
local function ok(c, m) if c then pass = pass + 1 else fail = fail + 1; io.write("  ✗ " .. m .. "\n") end end

ok(A.note(16).hl == "FoxSymdepsOk", "≤64 B is green")
ok(A.note(16).text:find("fits a cache line", 1, true), "≤64 B says fits")
ok(A.note(64).hl == "FoxSymdepsOk", "exactly 64 B still fits")
ok(A.note(72).hl == "FoxSymdepsWarn", "65–256 B is wheat/warn")
ok(A.note(72).text:find("spans 2 cache lines", 1, true), "72 B spans 2 lines")
ok(A.note(72).text:find("▲", 1, true), "warn band carries the ▲")
ok(A.note(4096).hl == "FoxSymdepsBadge", ">256 B is plain")
ok(A.note(4096).text:find("64 cache lines", 1, true), "4096 B = 64 cache lines")
ok(A.note(128).text:find("128 B", 1, true), "size echoed in the tag")

io.write(("test_ambient: %d passed, %d failed\n"):format(pass, fail))
os.exit(fail == 0 and 0 or 1)
