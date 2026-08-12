-- unitindex: enclosing-unit + orient-[TAG] resolution from raw file lines (pure).
-- Run: nvim -l tests/test_unitindex.lua
package.path = "./lua/?.lua;" .. package.path
local U = require("fox-symdeps.unitindex")

local pass, fail = 0, 0
local function ok(c, m) if c then pass = pass + 1 else fail = fail + 1; io.write("  ✗ " .. m .. "\n") end end

local openers = { STRUCT = true, FUNCTION = true, REGISTRY = true }
local lines = {
  "// [STRUCT]_[Outer]",                       -- 1
  "// [TAG]_[[ENGINE] [SLOW_PATH]]",           -- 2  orient tag
  "// [CODE]",                                 -- 3
  "// [TAG]_[[SHOULD_NOT_ATTACH]]",            -- 4  in-CODE → ignored (tier discipline)
  "int x;",                                    -- 5
  "// [FUNCTION]_[Inner_Fn]",                  -- 6
  "// [TAG]_[HOT_PATH]",                       -- 7  single form
  "// [CODE]",                                 -- 8
  "int y;",                                    -- 9
  "// [END_CODE]",                             -- 10 (not an opener END — ignored)
  "// [END_FUNCTION]_[Inner_Fn]",              -- 11
  "// [END_CODE]",                             -- 12
  "// [END_STRUCT]_[Outer]",                   -- 13
  "plain code with no unit",                   -- 14
}
local blocks = U._parse(lines, openers)
ok(#blocks == 2, "two closable units parsed (got " .. #blocks .. ")")

local function at(line)   -- local resolver over the parsed blocks (mirror of M.at's innermost pick)
  local best
  for _, b in ipairs(blocks) do
    if b.opener <= line and line <= b.closer then
      if not best or (b.closer - b.opener) < (best.closer - best.opener) then best = b end
    end
  end
  return best
end

local outer, inner = at(5), at(9)
ok(outer and outer.name == "Outer", "line 5 → Outer")
ok(inner and inner.name == "Inner_Fn", "line 9 → INNERMOST unit wins")
ok(outer.tags and outer.tags[1] == "ENGINE" and outer.tags[2] == "SLOW_PATH",
   "orient [TAG] multi-form attaches to Outer")
ok(inner.tags and inner.tags[1] == "HOT_PATH" and #inner.tags == 1, "single-form [TAG] attaches")
local leaked = false
for _, b in ipairs(blocks) do
  for _, t in ipairs(b.tags or {}) do if t == "SHOULD_NOT_ATTACH" then leaked = true end end
end
ok(not leaked, "a [TAG] inside [CODE] never attaches (tier discipline)")
ok(at(14) == nil, "outside every unit → nil (caller keeps clangd names)")

io.write(("unitindex: %d pass, %d fail\n"):format(pass, fail))
os.exit(fail == 0 and 0 or 1)
