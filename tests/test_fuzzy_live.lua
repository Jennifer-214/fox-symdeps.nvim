-- fuzzy_pick LIVE path: real windows + buffers, driven through the programmatic handle
-- (headless -l cannot drive insert-mode typeahead — feedkeys 'x!' silently ends the script;
-- the handle calls the SAME functions the keys map to, so everything except nvim's own key
-- decoding is exercised: refilter, render, selection, confirm identity, cancel, live debounce).
-- Sister of test_branchtag_live — the pure filter was toothed while the WINDOW path shipped
-- unexercised; same class of seam, same rule (plugin work is not done until the live path
-- runs; operator, 2026-08-18).  Run:  nvim -l tests/test_fuzzy_live.lua
package.path = "./lua/?.lua;" .. package.path
local U = require("fox-symdeps.ui")

local pass, fail = 0, 0
local function ok(c, m) if c then pass = pass + 1 else fail = fail + 1; io.write("  ✗ " .. m .. "\n") end end
local function floats()
  local n = 0
  for _, w in ipairs(vim.api.nvim_list_wins()) do
    if vim.api.nvim_win_get_config(w).relative ~= "" then n = n + 1 end
  end
  return n
end

-- ① static: two floats open (prompt + results), query narrows, confirm picks the ORIGINAL item
local items = { { label = "alpha" }, { label = "beta" }, { label = "gamma" } }
local picked, called = nil, false
local h = U.fuzzy_pick({ title = "t", items = items,
  on_choice = function(c) picked = c; called = true end })
ok(type(h) == "table" and h.is_open(), "LIVE static: picker opens and returns its handle")
ok(floats() == 2, "LIVE static: prompt + results floats are both up")
-- BROWSE-FIRST: a static picker opens in NORMAL mode with the browse keys bound (no typing needed)
ok(vim.api.nvim_get_mode().mode == "n", "LIVE static: opens in browse (normal) mode — typing optional")
local has_j, has_i = false, false
for _, m in ipairs(vim.api.nvim_buf_get_keymap(vim.api.nvim_get_current_buf(), "n")) do
  if m.lhs == "j" then has_j = true end
  if m.lhs == "i" then has_i = true end
end
ok(has_j and has_i, "LIVE static: browse keys bound (j moves, i enters the filter)")
h.set_query("bet")
h.confirm()
vim.wait(3000, function() return called end, 50)
ok(called, "LIVE static: confirm reaches on_choice")
ok(picked == items[2], "LIVE static: query 'bet' narrows to beta — the ORIGINAL item table, not a copy")
ok(floats() == 0, "LIVE static: no floating windows survive a pick")

-- ② selection movement: move(1) steps to row 2 before confirm
picked, called = nil, false
h = U.fuzzy_pick({ title = "t", items = items, on_choice = function(c) picked = c; called = true end })
h.move(1)
h.confirm()
vim.wait(3000, function() return called end, 50)
ok(called and picked == items[2], "LIVE static: move(1) selects row 2; confirm picks it")

-- ③ cancel: on_choice(nil), windows gone, handle reports closed
picked, called = "sentinel", false
h = U.fuzzy_pick({ title = "t", items = items, on_choice = function(c) picked = c; called = true end })
h.cancel()
vim.wait(3000, function() return called end, 50)
ok(called and picked == nil, "LIVE static: cancel calls on_choice(nil)")
ok(floats() == 0 and not h.is_open(), "LIVE: no floats survive a cancel; handle reports closed")

-- ④ live mode: the debounced source's rows are what confirm picks from
picked, called = nil, false
local queries = {}
h = U.fuzzy_pick({
  title = "t",
  live = function(q, update)
    queries[#queries + 1] = q
    if q == "ab" then update({ { label = "hit-" .. q } }) else update({}) end
  end,
  on_choice = function(c) picked = c; called = true end,
})
h.set_query("ab")
local sourced = vim.wait(3000, function() return queries[#queries] == "ab" end, 50)
ok(sourced, "LIVE live-mode: the debounced source fires with the final query")
vim.wait(300, function() return false end, 100) -- let update() render settle
h.confirm()
vim.wait(3000, function() return called end, 50)
ok(called and picked and picked.label == "hit-ab", "LIVE live-mode: confirm picks from the source's rows")

-- ⑤ a stale live generation never lands: a newer query invalidates the older debounce
picked, called = nil, false
local landed = {}
h = U.fuzzy_pick({
  title = "t",
  live = function(q, update) landed[#landed + 1] = q; update({ { label = q } }) end,
  on_choice = function(c) picked = c; called = true end,
})
h.set_query("old")
h.set_query("new") -- within the 120ms debounce window: 'old' must never fire
vim.wait(2000, function() return #landed > 0 end, 50)
vim.wait(300, function() return false end, 100)
ok(#landed == 1 and landed[1] == "new", "LIVE live-mode: a superseded query is debounced away (generation guard)")
h.confirm()
vim.wait(3000, function() return called end, 50)
ok(called and picked and picked.label == "new", "LIVE live-mode: the surviving generation's row is picked")

io.write(("test_fuzzy_live: %d passed, %d failed\n"):format(pass, fail))
os.exit(fail == 0 and 0 or 1)
