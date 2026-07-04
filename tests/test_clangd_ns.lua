-- clangd namespace extraction from hover markdown (WS2 call-site fallback). Pure.
-- Run:  nvim -l tests/test_clangd_ns.lua   (from the repo root)
package.path = "./lua/?.lua;" .. package.path
local C = require("fox-symdeps.clangd")
local ns = C._namespace_from_md

local pass, fail = 0, 0
local function ok(c, m) if c then pass = pass + 1 else fail = fail + 1; io.write("  ✗ " .. m .. "\n") end end

ok(ns("void foo()\n\n// In namespace tt") == "tt", "simple namespace tt")
ok(ns("```cpp\nstatic void f()\n```\n// In namespace tt::detail") == "tt::detail", "nested tt::detail")
ok(ns("//   In namespace  foo_bar") == "foo_bar", "extra spaces + underscore")
ok(ns("int x;  // no namespace comment here") == nil, "unrelated comment → nil")
ok(ns("global function, no namespace directive") == nil, "global → nil")
ok(ns(nil) == nil, "nil md → nil")

io.write(("test_clangd_ns: %d passed, %d failed\n"):format(pass, fail))
os.exit(fail == 0 and 0 or 1)
