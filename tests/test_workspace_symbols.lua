-- clangd workspace/symbol result parsing (roam). Pure.
-- Run:  nvim -l tests/test_workspace_symbols.lua   (from the repo root)
package.path = "./lua/?.lua;" .. package.path
local C = require("fox-symdeps.clangd")
local parse = C._parse_workspace_symbols

local pass, fail = 0, 0
local function ok(c, m) if c then pass = pass + 1 else fail = fail + 1; io.write("  ✗ " .. m .. "\n") end end

local result = {
  { name = "ExecutionCore_Init", kind = 12, containerName = "tt",
    location = { uri = "file:///ws/CoreFrameworks/ExecutionCore.hpp", range = { start = { line = 194, character = 19 } } } },
  { name = "FPN_Binary", kind = 23, containerName = "tt",
    location = { uri = "file:///ws/FixedPoint/FPN.hpp", range = { start = { line = 41, character = 7 } } } },
  { name = "orphan", kind = 12 }, -- no location → must be filtered
}
local out = parse(result)
ok(#out == 2, "2 parsed (1 filtered for missing location)")
ok(out[1].name == "ExecutionCore_Init" and out[1].container == "tt", "name + container")
ok(out[1].file == "/ws/CoreFrameworks/ExecutionCore.hpp", "uri → path")
ok(out[1].line == 195, "line 0-based → 1-based")
ok(out[1].col == 19, "col stays 0-based")
ok(out[1].kind == 12 and out[2].kind == 23, "kinds preserved (fn / struct)")
ok(#parse(nil) == 0, "nil result → empty")

io.write(("test_workspace_symbols: %d passed, %d failed\n"):format(pass, fail))
os.exit(fail == 0 and 0 or 1)
