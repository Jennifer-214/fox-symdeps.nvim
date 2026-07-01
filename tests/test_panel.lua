-- Panel tab-history logic: dedupe-to-end, cap, and wrap-around index stepping. Pure.
-- Run:  nvim -l tests/test_panel.lua   (from the repo root)
package.path = "./lua/?.lua;" .. package.path
local P = require("fox-symdeps.panel")

local pass, fail = 0, 0
local function eq(a, b, m) if a == b then pass = pass + 1 else fail = fail + 1; io.write(("  ✗ %s (got %s want %s)\n"):format(m, tostring(a), tostring(b))) end end
local function syms(hist) local t = {} for _, c in ipairs(hist) do t[#t + 1] = c.symbol end return table.concat(t, ",") end

-- _remember: dedupe-to-end + cap
local h = {}
eq(P._remember(h, { symbol = "A" }, 3), 1, "first add → idx 1")
eq(P._remember(h, { symbol = "B" }, 3), 2, "second add → idx 2")
eq(syms(h), "A,B", "order A,B")
eq(P._remember(h, { symbol = "A" }, 3), 2, "re-add A → moved to end, idx 2")
eq(syms(h), "B,A", "A moved to end")
P._remember(h, { symbol = "C" }, 3)
P._remember(h, { symbol = "D" }, 3) -- cap 3 → drop oldest (B)
eq(syms(h), "A,C,D", "capped at 3, oldest dropped")

-- _wrap: 1-based wrap-around
eq(P._wrap(1, 1, 3), 2, "next from 1 → 2")
eq(P._wrap(3, 1, 3), 1, "next from last → wraps to 1")
eq(P._wrap(1, -1, 3), 3, "prev from 1 → wraps to last")
eq(P._wrap(2, -1, 3), 1, "prev from 2 → 1")
eq(P._wrap(2, 0, 3), 2, "no move")
eq(P._wrap(1, 1, 0), 0, "empty history → 0")

io.write(("test_panel: %d passed, %d failed\n"):format(pass, fail))
os.exit(fail == 0 and 0 or 1)
