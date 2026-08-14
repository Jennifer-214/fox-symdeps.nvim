-- ui output log: the notify ring + pure render (operator 2026-08-14: outputs without :Noice).
-- Run: nvim -l tests/test_ui_output.lua   (suite: bash tests/run.sh)
package.path = "./lua/?.lua;./lua/?/init.lua;" .. package.path
local U = require("fox-symdeps.ui")

local pass, fail = 0, 0
local function ok(c, m) if c then pass = pass + 1 else fail = fail + 1; io.write("  ✗ " .. m .. "\n") end end

-- empty state is honest, never a blank float
local empty = U._render_ring({})
ok(#empty == 1 and empty[1]:find("no fox%-symdeps output"), "empty ring renders the honest empty state")

-- notify_raw appends to the ring (voice prefix + level + newline flattening)
vim.notify = function() end   -- silence the toast half in headless
U.notify_raw("plain message", vim.log.levels.WARN)
U.notify_raw("fox-symdeps · already prefixed\nsecond line", vim.log.levels.ERROR)
ok(#U._ring == 2, "ring captured both notifications")
ok(U._ring[1].msg:find("^fox%-symdeps · plain message") ~= nil, "voice prefix applied once")
ok(U._ring[2].msg:find("⏎") ~= nil, "multi-line messages flatten with a visible break")

-- newest first (recency-as-rule) + level icons
local lines = U._render_ring(U._ring)
ok(lines[1]:find("✗") ~= nil and lines[1]:find("already prefixed") ~= nil, "newest entry renders FIRST with its ✗")
ok(lines[2]:find("⚠") ~= nil and lines[2]:find("plain message") ~= nil, "older warn renders second with its ⚠")

io.write(("ui_output: %d passed, %d failed\n"):format(pass, fail))
if fail > 0 then os.exit(1) end
