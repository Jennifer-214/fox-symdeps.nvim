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

-- sweep order: newest recorded binary first (recency-as-rule)
local cars = A.sweep_order({
  { path = "a", prov = { mtime = 100 } },
  { path = "b", prov = { mtime = 300 } },
  { path = "c", prov = { mtime = 200 } },
})
ok(cars[1].path == "b" and cars[3].path == "a", "sidecars sort newest-recorded-binary first")

io.write(("asmshipped: %d passed, %d failed\n"):format(pass, fail))
if fail > 0 then os.exit(1) end
