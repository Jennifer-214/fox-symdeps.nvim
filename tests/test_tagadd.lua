-- tagadd: [TAG] line merge + orient-tier locate (pure). Run: nvim -l tests/test_tagadd.lua
package.path = "./lua/?.lua;" .. package.path
local T = require("fox-symdeps.tagadd")

local pass, fail = 0, 0
local function ok(c, m) if c then pass = pass + 1 else fail = fail + 1; io.write("  ✗ " .. m .. "\n") end end

ok(T.merge_tag_line("// [TAG]_[[ENGINE] [MONITORING_PLANE]]", "LIVE_TRADING")
   == "// [TAG]_[[ENGINE] [MONITORING_PLANE] [LIVE_TRADING]]", "multi-form merge appends")
ok(T.merge_tag_line("// [TAG]_[ENGINE]", "DETERMINISM")
   == "// [TAG]_[[ENGINE] [DETERMINISM]]", "single bare form upgrades to multi")
ok(T.merge_tag_line("    // [TAG]_[[ENGINE]]", "HOT_PATH")
   == "    // [TAG]_[[ENGINE] [HOT_PATH]]", "indent preserved (nested banners)")
local same = "// [TAG]_[[ENGINE] [DETERMINISM]]"
ok(T.merge_tag_line(same, "ENGINE") == same, "already-present token → identical line (idempotent)")
ok(T.merge_tag_line("// [OVERVIEW]_[not a tag line]", "X") == nil, "non-[TAG] line refused (nil)")

ok(T.find_tag_line({ "// [STRUCT]_[X]", "// [TAG]_[[A]]", "// [CODE]" }) == 2,
   "finds the orient [TAG] line")
ok(T.find_tag_line({ "// [STRUCT]_[X]", "// [CODE]", "// [TAG]_[[A]]" }) == nil,
   "a [TAG] inside [CODE] is NOT the orient line (tier discipline)")
ok(T.find_tag_line({ "// [STRUCT]_[X]", "// [OVERVIEW]_[y]" }) == nil, "no [TAG] line → nil (merge-only)")

io.write(("tagadd: %d pass, %d fail\n"):format(pass, fail))
os.exit(fail == 0 and 0 or 1)
