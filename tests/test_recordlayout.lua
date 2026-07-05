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
        16 |   char[16] symbol
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

-- TOP-LEVEL field capture: depth-1 lines (3 spaces after |), nested members (5 spaces) excluded
ok(#recs[1].fields == 3, "ExecutionCore: 3 top-level fields (nested __int128 v NOT captured)")
ok(recs[1].fields[1].name == "seqlock" and recs[1].fields[1].type == "int" and recs[1].fields[1].off == 0,
  "field 1: int seqlock @0")
ok(recs[1].fields[3].name == "symbol" and recs[1].fields[3].type == "char[16]" and recs[1].fields[3].off == 16,
  "field 3: char[16] symbol @16 (array type kept)")

-- field_size resolver
local by = { ["FixedPoint<10,8>"] = 16, ["tt::Order<64>"] = 256 }
ok(R.field_size("int", by) == 4, "primitive int = 4")
ok(R.field_size("uint8_t", by) == 1, "uint8_t = 1")
ok(R.field_size("__int128", by) == 16, "__int128 = 16")
ok(R.field_size("uint8_t[6]", by) == 6, "array uint8_t[6] = 6")
ok(R.field_size("double[2][3]", by) == 48, "multi-dim double[2][3] = 48")
ok(R.field_size("Foo *", by) == 8, "pointer = 8")
ok(R.field_size("struct FixedPoint<10, 8>", by) == 16, "nested struct via census (namespace/space-normalized)")
ok(R.field_size("tt::Order<64>", by) == 256, "nested via full name")
ok(R.field_size("ImGuiID", by) == nil, "opaque typedef → nil (unresolvable, conservative)")

-- straddlers: a ≤64B field crossing a 64B line, fully-resolved structs only, partial counted
local sd = R.straddlers({
  { name = "tt::Straddled", size = 128, fields = { -- a 48B field @40 crosses the 64 boundary
    { name = "a", type = "uint8_t[40]", off = 0 }, { name = "cross", type = "uint8_t[48]", off = 40 } } },
  { name = "tt::Clean", size = 64, fields = { { name = "x", type = "uint64_t", off = 0 } } },
  { name = "tt::BigField", size = 512, fields = { { name = "buf", type = "uint8_t[512]", off = 0 } } }, -- >64B, not a placement bug
  { name = "tt::Partial", size = 32, fields = { { name = "q", type = "ImGuiID", off = 60 } } },       -- unresolvable → partial
})
ok(#sd.report == 1, "1 struct reported (Straddled); Clean/BigField/Partial excluded")
ok(sd.report[1].name == "tt::Straddled" and sd.report[1].fields[1].name == "cross", "the crossing field named")
ok(sd.report[1].fields[1].off == 40 and sd.report[1].fields[1].size == 48, "field offset + resolved size")
ok(sd.partial == 1, "Partial (unresolvable field) counted, not silently dropped")

io.write(("test_recordlayout: %d passed, %d failed\n"):format(pass, fail))
os.exit(fail == 0 and 0 or 1)
