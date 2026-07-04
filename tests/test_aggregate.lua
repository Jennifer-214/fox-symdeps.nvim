-- aggregate: widest-headers ranking (pure). Run:  nvim -l tests/test_aggregate.lua
package.path = "./lua/?.lua;" .. package.path
local A = require("fox-symdeps.aggregate")

local pass, fail = 0, 0
local function ok(c, m) if c then pass = pass + 1 else fail = fail + 1; io.write("  ✗ " .. m .. "\n") end end

-- basename -> path (the in-repo header set); <vector> is NOT in it → must be excluded
local repo = {
  ["FixedPointN.hpp"] = "/ws/FixedPoint/FixedPointN.hpp",
  ["Order.hpp"] = "/ws/CoreFrameworks/Order.hpp",
}
local lines = {
  "/ws/a.cpp:1:#include \"FixedPointN.hpp\"",
  "/ws/b.cpp:1:#include <detail/FixedPointN.hpp>",   -- path-prefixed → same basename
  "/ws/b.cpp:2:#include \"FixedPointN.hpp\"",          -- dup within same file → counted once
  "/ws/c.hpp:9:#include \"Order.hpp\"",
  "/ws/a.cpp:3:#include <vector>",                      -- system header → excluded (not in repo set)
  "trailing garbage",
}
local r = A.rank(lines, repo)
ok(#r == 2, "2 in-repo headers ranked (<vector> excluded)")
ok(r[1].header == "FixedPointN.hpp" and r[1].count == 2, "FixedPointN wins with 2 distinct includers")
ok(r[1].path == "/ws/FixedPoint/FixedPointN.hpp", "path carried through for jump")
ok(r[2].header == "Order.hpp" and r[2].count == 1, "Order.hpp second with 1")

-- tie-break: equal counts → alphabetical by header
local tie = A.rank({
  "/ws/x.cpp:1:#include \"Order.hpp\"",
  "/ws/y.cpp:1:#include \"FixedPointN.hpp\"",
}, repo)
ok(tie[1].header == "FixedPointN.hpp" and tie[2].header == "Order.hpp", "equal counts break alphabetically")

-- limit truncates
ok(#A.rank(lines, repo, 1) == 1, "limit=1 keeps only the top header")

-- no repo set → keep everything (system headers included when unfiltered)
local unfiltered = A.rank({ "/ws/a.cpp:1:#include <vector>" }, nil)
ok(#unfiltered == 1 and unfiltered[1].header == "vector", "nil repo set → no filtering")

ok(#A.rank(nil, repo) == 0, "nil lines → empty")
ok(#A.rank({}, repo) == 0, "empty lines → empty")

io.write(("test_aggregate: %d passed, %d failed\n"):format(pass, fail))
os.exit(fail == 0 and 0 or 1)
