-- actions: registry gating + verbatim row pass-through + layer-stack collapse (pure).
-- Run: nvim -l tests/test_actions.lua  — the menu-seam teeth the fleet found missing
-- (cd971ac claimed headless proofs that were never committed; these are them, permanent).
package.path = "./lua/?.lua;./lua/?/init.lua;" .. package.path
local A = require("fox-symdeps.actions")

local pass, fail = 0, 0
local function ok(c, m) if c then pass = pass + 1 else fail = fail + 1; io.write("  ✗ " .. m .. "\n") end end
local function has(list, id)
  for _, a in ipairs(list) do if a.id == id then return true end end
  return false
end

-- bind-suffix derivation (operator ask 2026-08-13: every menu row shows its key) — pure
ok(A._bind_suffix({ label = "L", id = "hud" }, { hud = "<leader>dd" }) == "L  (<leader>dd)",
   "action-row suffix derives from the keymap registry's action_id map")
ok(A._bind_suffix({ label = "L", bind = "<leader>dw" }, {}) == "L  (<leader>dw)",
   "launcher rows carry their bind directly")
ok(A._bind_suffix({ label = "L", id = "no-bind-row" }, { hud = "<leader>dd" }) == "L",
   "row without a bind renders unchanged")

-- keymap-registry ↔ action-registry parity (the anti-drift tooth): every action_id in the
-- keymap SPEC must resolve to a real action row id, and every registry row must carry an id.
do
  local fox = require("fox-symdeps")
  local ids = {}
  for _, a in ipairs(A.registry) do
    ok(a.id ~= nil, "every action row carries an id (found one without)")
    ok(ids[a.id] == nil, "action ids are unique (dup: " .. tostring(a.id) .. ")")
    ids[a.id] = true
  end
  local n_linked = 0
  for _, r in ipairs(fox._keymap_spec()) do
    if r.action_id then
      n_linked = n_linked + 1
      ok(ids[r.action_id], ("keymap %s action_id %q resolves to a real action row"):format(r.lhs, r.action_id))
    end
  end
  ok(n_linked >= 9, "the bind links exist (expected the 9 twin rows at minimum, got " .. n_linked .. ")")
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
