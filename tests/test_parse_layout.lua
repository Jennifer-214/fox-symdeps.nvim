-- Unit tests for the clangd hover → layout extractor. Pure Lua: no nvim, no clangd.
-- Run:  nvim -l tests/test_parse_layout.lua   (from the repo root)
package.path = "./lua/?.lua;" .. package.path
local parse = require("fox-symdeps.clangd")._parse_layout

local pass, fail = 0, 0
local function check(cond, label)
  if cond then
    pass = pass + 1
  else
    fail = fail + 1
    io.write("  ✗ " .. label .. "\n")
  end
end
local function eq(got, want, label)
  check(got == want, ("%s (got %s, want %s)"):format(label, tostring(got), tostring(want)))
end

-- 1. Real struct hover — the W0-proven case (SHA256_State → 112 / 8)
local s = parse("### struct `SHA256_State`\nSize: 112 bytes, alignment 8 bytes.")
check(s ~= nil, "struct hover parses")
eq(s and s.size, 112, "struct size")
eq(s and s.align, 8, "struct align")
eq(s and s.offset, nil, "struct has no offset")

-- 2. Field hover carries an offset
local f = parse("Field `count`\nSize: 8 bytes, offset: 16 bytes.")
eq(f and f.size, 8, "field size")
eq(f and f.offset, 16, "field offset")

-- 3. First-letter case variants clangd actually emits
local c = parse("size: 4 bytes, Alignment 4 bytes")
eq(c and c.size, 4, "lowercase size")
eq(c and c.align, 4, "capital Alignment")

-- 4. No layout info → nil (so the HUD renders 'unavailable', never errors)
eq(parse("Just a doc comment, no layout here."), nil, "no-layout → nil")
eq(parse(nil), nil, "nil input → nil")

io.write(("\nparse_layout: %d passed, %d failed\n"):format(pass, fail))
os.exit(fail == 0 and 0 or 1)
