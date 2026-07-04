-- WS5 orientation-aware panel placement: wide editor → right strip, portrait → bottom strip.
-- Run:  nvim -l tests/test_hud_placement.lua   (from the repo root)
package.path = "./lua/?.lua;" .. package.path
local R = require("fox-symdeps.hud")._resolve_placement

local pass, fail = 0, 0
local function ok(c, m) if c then pass = pass + 1 else fail = fail + 1; io.write("  ✗ " .. m .. "\n") end end

-- landscape ~1920x1080 terminal (~240x63): ratio ~3.8 → right strip
local land = R(240, 63)
ok(land.cfg.split == "right", "landscape → right split")
ok(land.fix == "winfixwidth", "landscape → winfixwidth")
ok(land.cfg.width == 60, "landscape width clamped to 60 (min(60, 96))")

-- portrait ~1080x1920 terminal (~135x113): ratio ~1.19 → bottom strip
local port = R(135, 113)
ok(port.cfg.split == "below", "portrait → below split")
ok(port.fix == "winfixheight", "portrait → winfixheight")
ok(port.cfg.height == 45, "portrait height = floor(113*0.4) = 45")

-- narrow-but-wide (few cols) → width scales down, not a fixed 60
local narrow = R(120, 40) -- ratio 3.0 → right; width = min(60, floor(48)) = 48
ok(narrow.cfg.split == "right", "narrow-wide still right")
ok(narrow.cfg.width == 48, "narrow width scales to 48")

-- boundary at 2.2 (inclusive → right)
ok(R(220, 100).cfg.split == "right", "ratio exactly 2.2 → right")
ok(R(219, 100).cfg.split == "below", "ratio just under 2.2 → below")

-- degenerate inputs must not crash
ok(R(nil, nil).cfg ~= nil, "nil inputs default safely")
ok(R(100, 0).cfg ~= nil, "zero lines guarded (no divide-by-zero)")

io.write(("test_hud_placement: %d passed, %d failed\n"):format(pass, fail))
os.exit(fail == 0 and 0 or 1)
