-- asmshipped: the shipped-asm card's pure core — header provenance, definition-vs-callsite
-- matching, block slicing, sweep order. The honest-states contract (Class 57): mutilated
-- header = named refusal; zero blocks = inlined-away FACT (distinct from refusal).
-- Run: nvim -l tests/test_asmshipped.lua   (suite: bash tests/run.sh)
package.path = "./lua/?.lua;" .. package.path
local A = require("fox-symdeps.asmshipped")

local pass, fail = 0, 0
local function ok(c, m) if c then pass = pass + 1 else fail = fail + 1; io.write("  ✗ " .. m .. "\n") end end

-- header provenance
local prov = A.parse_header(
  "# 1:1 disassembly of build_gui/engine_gui — the SHIPPED artifact, never a re-compile",
  "# binary-sha256-16: 706181519eaa9495  binary-mtime: 1784355657  emitted-at-HEAD: a71b893")
ok(prov and prov.binary == "build_gui/engine_gui" and prov.sha16 == "706181519eaa9495"
   and prov.mtime == 1784355657 and prov.head == "a71b893", "provenance header parses whole")
local bad, why = A.parse_header("# something else", "# not a provenance line")
ok(bad == nil and type(why) == "string", "mutilated header = named refusal, never {}")

-- base symbol (instantiation angle-forms strip; methods keep ::; destructors keep ~)
ok(A.base_symbol("BG_Evaluate<64>") == "BG_Evaluate", "angle-form tag name → base identifier")
ok(A.base_symbol("Notify_Send") == "Notify_Send", "plain name unchanged")
ok(A.base_symbol("OrderManagerState::~OrderManagerState") == "OrderManagerState::~OrderManagerState",
   "method/destructor base keeps :: and ~")

-- definition-header matching (the shared rule the async rg path filters with)
ok(A.match_block_header("0000000000401000 <Notify_Send(NotifyState&, char const*)>:", "Notify_Send"),
   "plain definition header matches")
ok(A.match_block_header("0000000000402000 <void BG_Evaluate<64u>(int)>:", "BG_Evaluate"),
   "template instantiation header matches on the base")
ok(not A.match_block_header("0000000000403000 <XNotify_Send()>:", "Notify_Send"),
   "identifier-boundary: prefixed symbol rejected")
ok(not A.match_block_header("    call   401000 <Notify_Send(NotifyState&)>", "Notify_Send"),
   "indented call-site annotation is NOT a definition header")
ok(not A.match_block_header("0000000000404000 <Notify_Sender()>:", "Notify_Send"),
   "identifier-boundary: suffixed symbol rejected")

-- NAME-POSITION rule (the FPN_Binary dogfood bug: a struct name matched functions TAKING it)
ok(not A.match_block_header(
     "0000000000405000 <void Regime_ComputeSignals<64u>(RegimeSignals<64u>*, FPN_Binary<64u>)>:",
     "FPN_Binary"),
   "PARAMETER-type mention does NOT match (the dogfood bug)")
ok(not A.match_block_header("0000000000406000 <FPN_Binary<64u> Money_ToBinary(Money)>:", "FPN_Binary"),
   "RETURN-type mention does not match")
ok(A.match_block_header("0000000000407000 <main>:", "main"), "plain C symbol at end-of-name matches")
ok(A.match_block_header("0000000000408000 <OrderManagerState::OrderManagerState()>:", "OrderManagerState"),
   "constructor: the name-position occurrence matches past the scope-qualifier one")
ok(A.match_block_header(
     "0000000000409000 <Money_FromBinary(FPN_Binary<64u>)>:", "Money_FromBinary"),
   "function taking the type still matches ITS OWN name")

-- slicing: two instantiations → two blocks, bodies intact; unrelated blocks excluded
local fixture = table.concat({
  "0000000000401000 <void BG_Evaluate<64u>(int)>:",
  "  401000:	push   %rbp",
  "  401001:	ret",
  "",
  "0000000000402000 <Other_Fn()>:",
  "  402000:	nop",
  "",
  "0000000000403000 <void BG_Evaluate<32u>(int)>:",
  "  403000:	ret",
  "",
}, "\n")
local blocks = A.slice(fixture, "BG_Evaluate")
ok(#blocks == 2, "two instantiations → two blocks")
ok(blocks[1][2] and blocks[1][2]:find("push") ~= nil and #blocks[1] == 3, "block body intact (header + 2 insns)")
ok(#A.slice(fixture, "Notify_Send") == 0, "absent symbol → ZERO blocks (the inlined-away fact, not an error)")

-- same_source: the engine↔workspace symlink duality (compile-time path vs buffer path)
ok(A.same_source("/a/CoreFrameworks/Portfolio.hpp", "/a/CoreFrameworks/Portfolio.hpp"), "exact path matches")
ok(A.same_source("/home/x/eng/CoreFrameworks/Portfolio.hpp", "/home/y/ws/CoreFrameworks/Portfolio.hpp"),
   "different roots, same last-two components → same source (symlink duality)")
ok(not A.same_source("/a/CoreFrameworks/Portfolio.hpp", "/a/CoreFrameworks/Other.hpp"), "different basename rejected")
ok(not A.same_source("/a/MemHeaders/Run.hpp", "/a/EngineSharded/Run.hpp"), "same basename, different parent rejected")

-- line_map: -l markers → dimmed rows + bidirectional maps + shipped instruction count
local lm_fix = {
  "0000000000053c00 <void Portfolio_Init<64u>(Portfolio<64u>*)>:",
  "Portfolio_Init():",
  "/home/x/CoreFrameworks/Portfolio.hpp:58",
  "   53c00:\tvpxor  %xmm1,%xmm1,%xmm1",
  "   53c04:\txor    %eax,%eax",
  "/home/x/CoreFrameworks/Portfolio.hpp:60 (discriminator 2)",
  "   53c06:\tret",
  "/home/x/MemHeaders/Other.hpp:99",
  "   53c07:\tnop",
}
local m = A.line_map(lm_fix, "/home/y/CoreFrameworks/Portfolio.hpp")
ok(m.display[3] == "  · Portfolio.hpp:58", "current-file marker renders dimmed name:line")
ok(m.display[8] == "  · from Other.hpp:99", "foreign-file marker renders 'from' (inlined-from attribution)")
ok(m.by_src[58] and #m.by_src[58] == 2 and m.by_src[58][1] == 4 and m.by_src[58][2] == 5,
   "by_src[58] = the two instruction rows under its marker")
ok(m.by_src[60] and #m.by_src[60] == 1 and m.by_src[60][1] == 7, "discriminator suffix parses; by_src[60] = ret row")
ok(m.src_of[4] == 58 and m.src_of[7] == 60, "src_of maps instruction rows back to source lines")
ok(m.src_of[9] == nil and m.by_src[99] == nil, "foreign-attributed instructions stay OUT of the sync maps")
ok(m.n_insn == 4, "shipped instruction count = ALL instruction rows (the budget number)")
local mo = A.line_map(lm_fix, "/home/y/CoreFrameworks/Portfolio.hpp", 10)
ok(mo.by_src[58][1] == 14 and mo.src_of[14] == 58, "offset shifts map keys to final display-buffer rows")

-- sweep order: newest recorded binary first (recency-as-rule)
local cars = A.sweep_order({
  { path = "a", prov = { mtime = 100 } },
  { path = "b", prov = { mtime = 300 } },
  { path = "c", prov = { mtime = 200 } },
})
ok(cars[1].path == "b" and cars[3].path == "a", "sidecars sort newest-recorded-binary first")

io.write(("asmshipped: %d passed, %d failed\n"):format(pass, fail))
if fail > 0 then os.exit(1) end
