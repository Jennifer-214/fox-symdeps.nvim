-- diagnostics: cache-line straddle detection (pure) + publish/clear roundtrip.
-- Run:  nvim -l tests/test_diagnostics.lua   (from the repo root)
package.path = "./lua/?.lua;" .. package.path
local D = require("fox-symdeps.diagnostics")
local S = D.straddlers

local pass, fail = 0, 0
local function ok(c, m) if c then pass = pass + 1 else fail = fail + 1; io.write("  ✗ " .. m .. "\n") end end

-- straddle detection: a field straddles iff its byte span crosses a 64 B boundary
ok(#S({ { name = "a", offset = 60, size = 8 } }) == 1, "field spanning 60..67 crosses 64 → straddler")
ok(S({ { name = "a", offset = 60, size = 8 } })[1] == "a", "reports the field name")
ok(#S({ { name = "b", offset = 0, size = 8 } }) == 0, "aligned field → not a straddler")
ok(#S({ { name = "c", offset = 56, size = 8 } }) == 0, "field ending exactly at 64 B → ok")
ok(#S({ { name = "d", offset = 64, size = 8 } }) == 0, "field starting at the next line → ok")
ok(#S({ { name = "e", offset = 0, size = 128 } }) == 1, "field larger than a line → straddler")
ok(#S({}) == 0, "no fields → none")

-- publish/clear roundtrip through vim.diagnostic
D.enabled = true
local buf = vim.api.nvim_create_buf(false, true)
vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "struct Foo {", "  char x;", "};" })
D.struct_layout({ symbol = "Foo", kind = "struct", bufnr = buf, line = 1, col = 0 }, { { name = "p", offset = 60, size = 8 } })
local diags = vim.diagnostic.get(buf)
ok(#diags == 1, "enabled + straddler → 1 diagnostic published")
ok(diags[1] and diags[1].message:find("straddle", 1, true) ~= nil, "message mentions straddle")
D.clear(buf)
ok(#vim.diagnostic.get(buf) == 0, "clear removes it")
-- disabled → no publish
D.enabled = false
D.struct_layout({ symbol = "Bar", kind = "struct", bufnr = buf, line = 1, col = 0 }, { { name = "p", offset = 60, size = 8 } })
ok(#vim.diagnostic.get(buf) == 0, "disabled → nothing published")

io.write(("test_diagnostics: %d passed, %d failed\n"):format(pass, fail))
os.exit(fail == 0 and 0 or 1)
