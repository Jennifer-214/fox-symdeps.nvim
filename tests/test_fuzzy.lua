-- ui._fuzzy_filter: the fuzzy-picker's pure core (matchfuzzypos wrapper). Pure.
-- Run:  nvim -l tests/test_fuzzy.lua
package.path = "./lua/?.lua;" .. package.path
local U = require("fox-symdeps.ui")

local pass, fail = 0, 0
local function ok(c, m) if c then pass = pass + 1 else fail = fail + 1; io.write("  ✗ " .. m .. "\n") end end

local items = { { label = "Portfolio_Init" }, { label = "BG_Evaluate" }, { label = "OMS_DrainSubmit" } }

-- empty query: every item, original order, no match positions
local r = U._fuzzy_filter(items, "")
ok(#r == 3 and r[1].item == items[1] and r[3].item == items[3], "empty query → all items, original order")
ok(#r[1].pos == 0, "empty query → no match positions")

-- narrowing: only the matching item survives, identity preserved
r = U._fuzzy_filter(items, "oms")
ok(#r == 1 and r[1].item == items[3], "query narrows to the fuzzy match, item identity preserved")
ok(type(r[1].pos) == "table" and #r[1].pos > 0, "a match carries its matched-char positions")

-- ranking: a tight prefix run outranks a scattered subsequence
local rank = { { label = "s_o_x_m_y_s" }, { label = "oms_direct" } }
r = U._fuzzy_filter(rank, "oms")
ok(#r == 2 and r[1].item == rank[2], "tight match ranks above scattered subsequence")

-- duplicate labels map back to DISTINCT items (the i-mapping, not text identity)
local a, b = { label = "dup" }, { label = "dup" }
r = U._fuzzy_filter({ a, b }, "dup")
ok(#r == 2 and r[1].item ~= r[2].item, "duplicate labels resolve to distinct items")

-- plain-string items work; custom format drives the haystack
r = U._fuzzy_filter({ "HOT_PATH", "SLOW_PATH" }, "slow")
ok(#r == 1 and r[1].item == "SLOW_PATH", "string items filter on themselves")
r = U._fuzzy_filter({ { name = "X", axis = "concern" } }, "concern",
  function(it) return it.name .. "   (" .. it.axis .. ")" end)
ok(#r == 1, "custom format string is the haystack (axis matched, not name)")

-- no match → empty, never an error
ok(#U._fuzzy_filter(items, "zzzzqqq") == 0, "no match → empty result")
ok(#U._fuzzy_filter({}, "x") == 0 and #U._fuzzy_filter(nil, "") == 0, "empty/nil item lists are safe")

io.write(("test_fuzzy: %d passed, %d failed\n"):format(pass, fail))
os.exit(fail == 0 and 0 or 1)
