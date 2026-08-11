-- actions: registry gating + verbatim row pass-through + layer-stack collapse (pure).
-- Run: nvim -l tests/test_actions.lua  — the menu-seam teeth the fleet found missing
-- (cd971ac claimed headless proofs that were never committed; these are them, permanent).
package.path = "./lua/?.lua;" .. package.path
local A = require("fox-symdeps.actions")

local pass, fail = 0, 0
local function ok(c, m) if c then pass = pass + 1 else fail = fail + 1; io.write("  ✗ " .. m .. "\n") end end
local function has(list, id)
  for _, a in ipairs(list) do if a.id == id then return true end end
  return false
end

-- gating: universal vs typed vs when(ctx)
local uni = A.for_type("", nil)
local st = A.for_type("struct", nil)
ok(#st > #uni, "struct rows are a superset of universal-only")
ok(not has(st, "mutations"), "kind-gated row hidden without ctx")
ok(has(A.for_type("struct", { kind = "field" }), "mutations"),
   "when(ctx): kind=field shows who-writes (explicit ctx, not current-window)")
ok(has(A.for_type("struct", { kind = "struct" }), "false-sharing"),
   "when(ctx): non-function kind shows false-sharing")
ok(not has(A.for_type("function", { kind = "function" }), "false-sharing"),
   "function kind hides false-sharing")
ok(not has(A.for_type("function", nil), "mutations"), "no ctx → analysis rows hidden everywhere")

-- verbatim pass-through + the layer-stack rule
local calls = { ran = 0, collapsed = 0 }
local ctx = { collapse = function() calls.collapsed = calls.collapsed + 1 end }
local row = { label = "L", writes = "comments", run = function() calls.ran = calls.ran + 1 end }
local rows = A.menu_rows({ row }, ctx)
ok(rows[1].label == "L" and rows[1].writes == "comments",
   "menu_rows: every field reads through (__index — the P1 re-wrap class is dead)")
rows[1].run()
ok(calls.ran == 1 and calls.collapsed == 1, "run: a normal row collapses ancestors (layer-stack)")
local krow = { label = "K", keep_stack = true, run = function() calls.ran = calls.ran + 1 end }
A.menu_rows({ krow }, ctx)[1].run()
ok(calls.ran == 2 and calls.collapsed == 1, "run: keep_stack row keeps its ancestors alive")

-- shim honesty: dm (no HUD) analysis surfaces via notify — methods exist, never a nil crash
local shim = A._hud_or_shim({})
local okshim = pcall(function()
  shim:set_message("x", "warn")
  shim:set_section("s", "header", {}, "ok")
end)
ok(okshim, "hud shim: notify-fallback methods callable (says what it can't render)")

io.write(("actions: %d pass, %d fail\n"):format(pass, fail))
os.exit(fail == 0 and 0 or 1)
