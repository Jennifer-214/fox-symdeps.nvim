-- assertion: the static_assert source line (pure). Run:  nvim -l tests/test_assertion.lua
package.path = "./lua/?.lua;" .. package.path
local A = require("fox-symdeps.assertion")

local pass, fail = 0, 0
local function ok(c, m) if c then pass = pass + 1 else fail = fail + 1; io.write("  ✗ " .. m .. "\n") end end

local l = A.line("ExecutionCore", 64, 64, "")
ok(l:find("sizeof(ExecutionCore) == 64", 1, true) ~= nil, "size clause")
ok(l:find("alignof(ExecutionCore) == 64", 1, true) ~= nil, "align clause when align given")
ok(l:find("static_assert(", 1, true) == 1, "starts with static_assert")
ok(l:sub(-2) == ");", "terminated with );")
ok(l:find("fox-symdeps", 1, true) ~= nil, "message tags the source")

-- indentation is preserved
ok(A.line("Foo", 8, 8, "    "):sub(1, 4) == "    ", "leading indent kept")

-- align omitted → size-only assert, no alignof clause
local s = A.line("Tick", 16, nil, "")
ok(s:find("sizeof(Tick) == 16", 1, true) ~= nil, "size-only: size clause")
ok(s:find("alignof", 1, true) == nil, "size-only: no alignof clause")
ok(s:sub(-2) == ");", "size-only terminated")

io.write(("test_assertion: %d passed, %d failed\n"):format(pass, fail))
os.exit(fail == 0 and 0 or 1)
