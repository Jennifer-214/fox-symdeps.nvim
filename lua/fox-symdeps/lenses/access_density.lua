-- lenses/access_density.lua — cache-line working-set density. For the struct under the cursor, how
-- many DISTINCT 64 B lines each function that touches it spans. A function that touches 2 lines pays
-- 2 loads where 1 would do — the density signal the engine hand-optimizes by eye (ExecutionCore.hpp's
-- comments narrate packing `active/live_tp/live_sl` into one line to cut a tick from 2 loads to 1).
-- Path-agnostic: EVERY touching function is listed (hot or slow), most-lines-first. ON-DEMAND via `t`
-- (the references-per-field pass is heavy). Advisory — it never repacks (sizeof is fingerprinted).
local lens = require("fox-symdeps.lens")
local writers = require("fox-symdeps.writers")

local LABEL = "◈ Cache-line access density"

-- one collapsible role per function: "fn   L0 L2  (2)" — most-lines-first (top = biggest density).
local function build_tree(res)
  local tree = {}
  for _, d in ipairs(writers.density(res.fields, res.touches)) do
    local ls = {}
    for _, ln in ipairs(d.lines) do ls[#ls + 1] = "L" .. ln end
    tree[#tree + 1] = {
      label = ("%s   %s"):format(d.fn, table.concat(ls, " ")),
      role = "density", count = d.nlines, collapsed = false, files = {},
    }
  end
  return tree
end

lens.define{
  name = "access_density",
  applies = function(ctx) return ctx ~= nil and ctx.kind ~= "function" end,
  render = function(_, hud) end, -- nothing on open; the analysis is on-demand
  hints = { t = "lines-touched" },
  actions = {
    t = function(ctx, hud)
      vim.notify("fox-symdeps · access density: analyzing…", vim.log.levels.INFO)
      writers.for_struct(ctx, function(res, state)
        if state ~= "ok" or not res then
          local why = (state == "no_client") and "clangd not attached"
            or (hud.layout and hud.layout.data and hud.layout.data.is_template)
            and "templated struct — put the cursor on a concrete Foo<N> use"
            or "couldn't resolve fields — put the cursor on the struct's DEFINITION"
          return hud:set_message("access density (t): " .. why, "warn")
        end
        local tree = build_tree(res)
        if #tree == 0 then
          return hud:set_message("access density (t): no functions touch this struct's fields", "info")
        end
        hud:set_section("access_density", LABEL .. "  (distinct 64B lines per function · advisory)", tree, "ok")
        hud:set_message(("access density (t): %d function(s) — most lines first"):format(#tree), "info")
      end)
    end,
  },
}
