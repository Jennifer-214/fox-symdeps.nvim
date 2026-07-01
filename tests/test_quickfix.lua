-- W17 quickfix builder: jumpable rows → quickfix items, BROKEN first, non-jumpable rows skipped.
-- Run:  nvim -l tests/test_quickfix.lua   (from the repo root)
package.path = "./lua/?.lua;" .. package.path
local build_qf = require("fox-symdeps.hud")._build_qf

local pass, fail = 0, 0
local function ok(c, m) if c then pass = pass + 1 else fail = fail + 1; io.write("  ✗ " .. m .. "\n") end end

local items = {
  { kind = "role" }, -- a branch header: no loc → skipped
  { loc = { file = "/e/a.hpp", line = 10 }, qftext = "foo :10" },
  { loc = { file = "/e/b.hpp", line = 44, col = 4 }, broken = true, qftext = "⚠ assert :44" },
  { loc = { file = "/e/c.hpp", line = 7 }, qftext = "bar :7" },
}
local qf = build_qf(items)
ok(#qf == 3, "3 jumpable rows (branch header skipped) — got " .. #qf)
ok(qf[1].filename == "/e/b.hpp" and qf[1].lnum == 44, "BROKEN row sorted first")
ok(qf[1].col == 5, "col is 1-based (0-based 4 → 5)")
ok(qf[1].text == "⚠ assert :44", "text carried through")
ok(qf[2].filename == "/e/a.hpp" and qf[3].filename == "/e/c.hpp", "non-broken rows keep order after")
ok(qf[2].col == 1, "missing col defaults to 1")
ok(#build_qf({}) == 0, "empty input → empty list")

-- W20 diff-on-edit: size-delta string
local sd = require("fox-symdeps.hud")._size_delta
ok(sd(16, 8) == "  (was 16, -8)", "size delta shrink")
ok(sd(8, 12) == "  (was 8, +4)", "size delta grow")
ok(sd(16, 16) == "", "no change → empty")
ok(sd(nil, 8) == "", "no prev → empty")

io.write(("test_quickfix: %d passed, %d failed\n"):format(pass, fail))
os.exit(fail == 0 and 0 or 1)
