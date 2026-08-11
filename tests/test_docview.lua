-- docview: [REFERENCE] id extraction + envelope partition (pure). Run: nvim -l tests/test_docview.lua
package.path = "./lua/?.lua;" .. package.path
local D = require("fox-symdeps.docview")

local pass, fail = 0, 0
local function ok(c, m) if c then pass = pass + 1 else fail = fail + 1; io.write("  ✗ " .. m .. "\n") end end

local lines = {
  "// [STRUCT]_[X]",
  "// [REFERENCE]_[INVARIANT]_[H20]",                     -- single bare form
  "// [REFERENCE]_[DECISION]_[[D-125] [D-142]]",          -- multi form
  "// [REFERENCE]_[PATTERN]_[[Class 51] [H4]]",           -- id WITH a space
  "// [REFERENCE]_[DECISION]_[[D-125]]",                  -- duplicate id → dedup
  "// [CODE]",
  "// int x;  // [REFERENCE]-shaped prose must not parse", -- no _[..]_[..] shape
  "// [END_STRUCT]_[X]",
}

local all = D.ref_ids(lines)
ok(#all == 5, "5 unique ids across the unit (dedup; got " .. #all .. ")")
ok(all[1] == "H20", "bare single form parses (H20)")
ok(all[2] == "D-125" and all[3] == "D-142", "multi form parses in order")
ok(all[4] == "Class 51", "spaced id survives token extraction")

local at = D.ref_ids(lines, 3)
ok(#at == 2 and at[1] == "D-125" and at[2] == "D-142",
   "cursor ON a [REFERENCE] line → that line's ids only")
local off = D.ref_ids(lines, 6)
ok(#off == 5, "cursor on a non-[REFERENCE] line → whole unit")

local p = D.partition({
  { "H20", "FOUND", "/x/CLAUDE.md", 181 },
  { "ZZ-9", "MISSING", "", 0 },
  { "D-125", "FOUND", "/x/log.md", 797 },
})
ok(#p.found == 2 and p.found[1].id == "H20" and p.found[1].line == 181,
   "partition: FOUND rows carry id/file/line")
ok(#p.missing == 1 and p.missing[1] == "ZZ-9",
   "partition: MISSING ids named, never dropped")
ok(#D.ref_ids({ "// [CODE]", "int y;" }) == 0, "no [REFERENCE] → empty list (caller refuses)")

io.write(("docview: %d pass, %d fail\n"):format(pass, fail))
os.exit(fail == 0 and 0 or 1)
