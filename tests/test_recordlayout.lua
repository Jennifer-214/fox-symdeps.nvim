-- recordlayout: parse clang -fdump-record-layouts output (pure).
-- Run:  nvim -l tests/test_recordlayout.lua   (from the repo root)
package.path = "./lua/?.lua;" .. package.path
local R = require("fox-symdeps.recordlayout")

local pass, fail = 0, 0
local function ok(c, m) if c then pass = pass + 1 else fail = fail + 1; io.write("  ✗ " .. m .. "\n") end end

local dump = [[
*** Dumping AST Record Layout
         0 | struct tt::ExecutionCore
         0 |   int seqlock
         8 |   double pnl
        16 |   char symbol[16]
           | [sizeof=64, dsize=32, align=64,
           |  nvsize=32, nvalign=8]

*** Dumping AST Record Layout
         0 | struct tt::FixedPoint<10, 8>
         0 |   long raw
           | [sizeof=8, dsize=8, align=8,
           |  nvsize=8, nvalign=8]

*** Dumping AST Record Layout
         0 | struct std::__detail::_Hash_node_base
         0 |   void * _M_nxt
           | [sizeof=8, dsize=8, align=8,
           |  nvsize=8, nvalign=8]
]]

local recs = R.parse(dump)
ok(#recs == 2, "2 project records parsed (std:: filtered out)")
ok(recs[1].name == "tt::ExecutionCore", "first record name (with namespace)")
ok(recs[1].size == 64, "sizeof parsed")
ok(recs[1].align == 64, "align parsed (not confused by nvalign=8)")
ok(#recs[1].offsets == 3, "3 field offsets collected (name line excluded)")
ok(recs[1].offsets[1] == 0 and recs[1].offsets[2] == 8 and recs[1].offsets[3] == 16, "field offsets in order")
ok(recs[2].name == "tt::FixedPoint<10, 8>", "template instantiation name kept with args")
ok(recs[2].size == 8, "template instantiation sizeof")

-- noise filter direct
ok(R._is_noise("std::vector") == true, "std:: is noise")
ok(R._is_noise("__gnu_cxx::foo") == true, "__ prefix is noise")
ok(R._is_noise("_Rb_tree_node") == true, "_Uppercase is noise")
ok(R._is_noise("tt::Order") == false, "project type is not noise")

-- robustness: empty / nil
ok(#R.parse(nil) == 0, "nil dump → empty")
ok(#R.parse("") == 0, "empty dump → empty")

-- a record with no sizeof summary (forward decl artifact) is dropped
ok(#R.parse("*** Dumping AST Record Layout\n     0 | struct tt::Fwd\n") == 0, "no sizeof → dropped")

io.write(("test_recordlayout: %d passed, %d failed\n"):format(pass, fail))
os.exit(fail == 0 and 0 or 1)
