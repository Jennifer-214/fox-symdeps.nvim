-- W26 byte-map renderer: per-byte glyphs on 64B lines, padding vs free, straddle detection. Pure.
-- Run:  nvim -l tests/test_bytemap.lua   (from the repo root)
package.path = "./lua/?.lua;" .. package.path
local render = require("fox-symdeps.bytemap").render

local pass, fail = 0, 0
local function ok(c, m) if c then pass = pass + 1 else fail = fail + 1; io.write("  ✗ " .. m .. "\n") end end

-- 1. A 16B field on line 0: 16 'a', then free '░' to fill the 64B line, no straddle.
local a = render({ { name = "v", offset = 0, size = 16 } }, 16)
ok(#a.lines == 1, "16B → one cache line")
ok(a.straddle == false, "no straddle")
ok(select(2, a.lines[1]:gsub("a", "")) == 16, "16 'a' bytes")
ok(a.lines[1]:find("░", 1, true) ~= nil, "free tail shown past the struct")
ok(a.lines[1]:find("·", 1, true) == nil, "no padding inside a full field")

-- 2. Padding gap: x@0..3, y@8..15 → bytes 4..7 are padding '·'.
local p = render({ { name = "x", offset = 0, size = 4 }, { name = "y", offset = 8, size = 8 } }, 16)
ok(select(2, p.lines[1]:gsub("·", "")) == 4, "4 padding bytes between x and y")

-- 3. Straddle: payload crosses the 64B boundary → two lines + straddle flag.
local s = render({
  { name = "header", offset = 0, size = 40 },
  { name = "payload", offset = 40, size = 64 }, -- 40..103 crosses 64
  { name = "length", offset = 104, size = 4 },
}, 108)
ok(#s.lines == 2, "108B → two cache lines")
ok(s.straddle == true, "payload straddle detected")
ok(s.straddlers[1] == "payload", "straddler named")
ok(s.lines[1]:find("ab", 1, true) ~= nil or s.lines[1]:find("a", 1, true) and s.lines[1]:find("b", 1, true), "line 0 has header then payload")
ok(s.lines[2]:find("b", 1, true) and s.lines[2]:find("c", 1, true), "line 1 continues payload then length")

-- 4. Degenerate input.
ok(render({}, 16).lines[1] == "(no field map)", "empty fields → placeholder")
ok(render({ { name = "z", offset = 0, size = 4 } }, 0).lines[1] == "(no field map)", "zero total → placeholder")

io.write(("test_bytemap: %d passed, %d failed\n"):format(pass, fail))
os.exit(fail == 0 and 0 or 1)
