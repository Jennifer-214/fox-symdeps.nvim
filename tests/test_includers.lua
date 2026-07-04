-- includers: #include pattern build + rg-output parse (both pure).
-- Run:  nvim -l tests/test_includers.lua   (from the repo root)
package.path = "./lua/?.lua;" .. package.path
local I = require("fox-symdeps.includers")

local pass, fail = 0, 0
local function ok(c, m) if c then pass = pass + 1 else fail = fail + 1; io.write("  ✗ " .. m .. "\n") end end

-- pattern: matches the basename, escapes the dot, tolerates a path prefix + both bracket styles
local pat = I.pattern("FixedPointN.hpp")
ok(pat:find("FixedPointN", 1, true) ~= nil, "pattern contains the basename")
ok(pat:find("\\.hpp", 1, true) ~= nil, "the dot before the ext is regex-escaped")
ok(pat:find("[<\"]", 1, true) ~= nil and pat:find("[>\"]", 1, true) ~= nil, "matches <...> and \"...\"")

-- parse: rg --line-number output → deduped {file,line}, first #include per file
local lines = {
  "/ws/CoreFrameworks/ExecutionCore.hpp:12:#include \"FixedPointN.hpp\"",
  "/ws/CoreFrameworks/ExecutionCore.hpp:44:#include <detail/FixedPointN.hpp>", -- dup file → dropped
  "/ws/ml/Model.cpp:3:#include \"../FixedPoint/FixedPointN.hpp\"",
  "garbage line with no colon-number",
}
local out = I.parse(lines)
ok(#out == 2, "2 distinct files (second hit in the same file deduped)")
ok(out[1].file == "/ws/CoreFrameworks/ExecutionCore.hpp" and out[1].line == 12, "first file keeps its first #include line")
ok(out[2].file == "/ws/ml/Model.cpp" and out[2].line == 3, "second file parsed")
ok(#I.parse(nil) == 0, "nil → empty")
ok(#I.parse({}) == 0, "empty → empty")

-- a windows-ish / colon-free path still parses on the first :N: boundary
local out2 = I.parse({ "src/a/b.hpp:9:#include \"x.hpp\"" })
ok(out2[1] and out2[1].file == "src/a/b.hpp" and out2[1].line == 9, "relative path parsed")

io.write(("test_includers: %d passed, %d failed\n"):format(pass, fail))
os.exit(fail == 0 and 0 or 1)
