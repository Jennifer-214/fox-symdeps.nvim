-- regfit: the RC-F card's pure render — flagged-first ordering, both-costs header, honest
-- counts, the H14 advisory footer. Run: nvim -l tests/test_regfit.lua
package.path = "./lua/?.lua;./lua/?/init.lua;" .. package.path
local R = require("fox-symdeps.regfit")

local pass, fail = 0, 0
local function ok(c, m) if c then pass = pass + 1 else fail = fail + 1; io.write("  ✗ " .. m .. "\n") end end

local structs = { { "TUISharedState", 58368, 64 } }
local fields = {
  { "TUISharedState", "seq", 58112, 8, "single-mov", "" },
  { "TUISharedState", "swap_strategy_requested", 58168, 16, "unaligned", "off%size ~= 0" },
  { "TUISharedState", "original_term", 20, 60, "multi-op", "60B is not a single-mov width" },
  { "TUISharedState", "entry_time", 96, -1, "unknown", "size unresolved" },
}
local r = R.render(structs, fields)

ok(r.lines[1]:find("TUISharedState") and r.lines[1]:find("58368B") and r.lines[1]:find("912 cache lines"),
   "header carries BOTH costs: bytes + cache-line footprint")
ok(r.lines[2]:find("original_term") ~= nil or r.lines[2]:find("swap_strategy") ~= nil,
   "flagged fields render FIRST (the review surface)")
local seq_row, flag_rows_before = nil, 0
for i, l in ipairs(r.lines) do
  if l:find("seq", 1, true) and l:find("single%-mov") then seq_row = i end
end
for i = 2, (seq_row or 2) - 1 do
  if r.lines[i]:find("⚠") or r.lines[i]:find("✗") or r.lines[i]:find("?%s*@") then
    flag_rows_before = flag_rows_before + 1
  end
end
ok(seq_row and flag_rows_before >= 2, "single-mov rows sort BELOW the flagged tier")
ok(r.counts["single-mov"] == 1 and r.counts["unaligned"] == 1 and r.counts["multi-op"] == 1
   and r.counts["unknown"] == 1, "verdict counts are per-field honest")
local footer = table.concat(r.lines, "\n")
ok(footer:find("ADVISORY") and footer:find("H14") and footer:find("never auto%-unpacked"),
   "the H14 honest-tension footer is ALWAYS rendered")
ok(footer:find("%?B") ~= nil, "unresolved size renders ?B, never -1B")
ok(r.hls[1] == "Title", "header row gets the Title group")

io.write(("regfit: %d passed, %d failed\n"):format(pass, fail))
if fail > 0 then os.exit(1) end
