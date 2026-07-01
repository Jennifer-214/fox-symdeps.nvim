-- W22 field-hover parse: pull offset/size/TYPE (what the struct contains) from a field hover.
-- Run:  nvim -l tests/test_layout.lua   (from the repo root)
package.path = "./lua/?.lua;" .. package.path
local parse = require("fox-symdeps.layout")._parse_field

local pass, fail = 0, 0
local function eq(a, b, m) if a == b then pass = pass + 1 else fail = fail + 1; io.write(("  ✗ %s (got %s want %s)\n"):format(m, tostring(a), tostring(b))) end end

-- backtick-wrapped type (clangd's usual form)
local f = parse("### field `entry_price`\n\nType: `Money`\n\nSize: 16 bytes, offset: 0 bytes.")
eq(f and f.offset, 0, "offset parsed")
eq(f and f.size, 16, "size parsed")
eq(f and f.type, "Money", "member type parsed (reverse composition)")

-- array type, non-zero offset
local g = parse("Type: `char[40]`\nSize: 40 bytes, offset: 8 bytes.")
eq(g and g.offset, 8, "offset 8")
eq(g and g.type, "char[40]", "array member type")

-- no offset → not a field hover
eq(parse("### struct `Foo`\nSize: 16 bytes"), nil, "no offset → nil (not a field)")
eq(parse(nil), nil, "nil md → nil")

io.write(("test_layout: %d passed, %d failed\n"):format(pass, fail))
os.exit(fail == 0 and 0 or 1)
