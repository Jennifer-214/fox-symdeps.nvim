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
-- D-413 leaf-2 resolver extensions (cv-strip · atomic-unwrap · the ABI table)
ok(R.field_size("volatile int", by) == 4, "cv-strip: volatile int = 4")
ok(R.field_size("const uint64_t", by) == 8, "cv-strip: const uint64_t = 8")
ok(R.field_size("volatile uint8_t[16]", by) == 16, "cv + array: volatile uint8_t[16] = 16")
ok(R.field_size("std::atomic<uint64_t>", by) == 8, "std::atomic<T> sizes as T (lock-free ≤16B)")
ok(R.field_size("volatile sig_atomic_t", by) == 4, "ABI: volatile sig_atomic_t = 4")
ok(R.field_size("pthread_mutex_t", by) == 40, "ABI: pthread_mutex_t = 40")
ok(R.field_size("pthread_cond_t", by) == 48, "ABI: pthread_cond_t = 48")
ok(R.field_size("pthread_t", by) == 8, "ABI: pthread_t = 8")
ok(R.field_size("std::thread", by) == 8, "ABI: std::thread = 8 (one native_handle)")
ok(R.field_size("time_t", by) == 8, "ABI: time_t = 8")

-- ABI-table PROBE (compiled ground truth — the table and this tooth extend TOGETHER; D-413/C(c)):
-- skip-advisory when clang++ is unavailable so a compiler-less env still runs the pure teeth.
if vim.fn.executable("clang++") == 1 then
  local src = os.tmpname() .. ".cpp"
  local pf = io.open(src, "w")
  pf:write([[
#include <pthread.h>
#include <ctime>
#include <csignal>
#include <thread>
static_assert(sizeof(pthread_mutex_t) == 40, "mutex");
static_assert(sizeof(pthread_cond_t) == 48, "cond");
static_assert(sizeof(pthread_t) == 8, "tid");
static_assert(sizeof(std::thread) == 8, "thread");
static_assert(sizeof(time_t) == 8, "time");
static_assert(sizeof(sig_atomic_t) == 4, "sig");
int main() { return 0; }
]])
  pf:close()
  local pr = vim.system({ "clang++", "-std=c++17", "-fsyntax-only", src }):wait()
  os.remove(src)
  ok(pr.code == 0, "ABI table PROBE: compiler confirms every table value")
else
  io.write("  (ABI probe SKIPPED — clang++ unavailable; table values unpinned this run)\n")
end

-- straddlers: TRI-STATE (D-413 leaf-2) — resolved hits ALWAYS report (even in partial records);
-- unresolved fields are delta-BOUNDED (next field's offset / record size at the tail): a bound
-- inside one line = PROVEN clean, a crossing bound = named UNVERIFIED. The old record-wide veto
-- (any unresolved field hid ALL resolved straddlers — the NotifyState escape) is the regression
-- this section pins against.
local sd = R.straddlers({
  { name = "tt::Straddled", size = 128, fields = { -- a 48B field @40 crosses the 64 boundary
    { name = "a", type = "uint8_t[40]", off = 0 }, { name = "cross", type = "uint8_t[48]", off = 40 } } },
  { name = "tt::Clean", size = 64, fields = { { name = "x", type = "uint64_t", off = 0 } } },
  { name = "tt::BigField", size = 512, fields = { { name = "buf", type = "uint8_t[512]", off = 0 } } }, -- >64B, not a placement bug
  { name = "tt::Partial", size = 32, fields = { { name = "q", type = "ImGuiID", off = 60 } } },  -- unresolvable, degenerate bound → UNVERIFIED
  { name = "tt::MixedVeto", size = 192, fields = { -- THE NotifyState class: resolved hit + unresolved neighbor
    { name = "cross", type = "uint8_t[48]", off = 40 },   -- REAL straddler — must report despite the opaque field
    { name = "opq", type = "ImGuiID", off = 96 } } },     -- bound = 192-96 = 96 → crosses → UNVERIFIED
  { name = "tt::ProvenClean", size = 64, fields = {       -- unresolved BUT the delta bound proves one-line residency
    { name = "opq", type = "ImGuiID", off = 48 },         -- bound = next(56) - 48 = 8 → bytes 48..55, one line → PROVEN
    { name = "tail", type = "uint64_t", off = 56 } } },
})
local rep = {}
for _, r in ipairs(sd.report) do rep[r.name] = r end
ok(rep["tt::Straddled"] and rep["tt::Straddled"].fields[1].name == "cross", "Straddled: the crossing field named")
ok(rep["tt::Straddled"].fields[1].off == 40 and rep["tt::Straddled"].fields[1].size == 48, "field offset + resolved size")
ok(rep["tt::Clean"] == nil and rep["tt::BigField"] == nil, "Clean/BigField not reported (no hits, nothing unverified)")
ok(rep["tt::Partial"] and #rep["tt::Partial"].fields == 0 and rep["tt::Partial"].unverified[1] == "q",
  "Partial: no guessed hit; the unresolvable field NAMED as unverified")
ok(rep["tt::MixedVeto"] and rep["tt::MixedVeto"].fields[1].name == "cross"
   and rep["tt::MixedVeto"].unverified[1] == "opq",
  "MixedVeto (NotifyState class): resolved straddler REPORTS despite the unresolved neighbor")
ok(rep["tt::ProvenClean"] == nil, "ProvenClean: one-line delta bound = PROVEN clean (no report, not partial)")
ok(sd.partial == 2, "partial = records with genuinely-UNVERIFIED fields only (Partial + MixedVeto)")

io.write(("test_recordlayout: %d passed, %d failed\n"):format(pass, fail))
os.exit(fail == 0 and 0 or 1)
