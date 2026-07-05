-- lenses/false_sharing.lua — flags false-sharing risk on a struct: two WRITTEN fields sharing a
-- 64 B cache line whose writer-sets are DISJOINT (different code paths writing the same line →
-- cross-core invalidation). Generic (any C++ struct). ON-DEMAND via `s` — the references-per-field
-- pass is too heavy to auto-run on every HUD open; the Phase-4 ambient layer can auto-run it later.
--
-- ADVISORY ONLY: the obvious fix (alignas(64)/pad) changes sizeof, which in the engine is
-- fwrite/memcmp/SHA-fingerprinted. So this flags + explains; it never auto-pads.
local lens = require("fox-symdeps.lens")
local writers = require("fox-symdeps.writers")

local LABEL = "▲ False-sharing risk"

local function group_by_file(sites)
  local byfile, order = {}, {}
  for _, s in ipairs(sites) do
    if not byfile[s.file] then byfile[s.file] = { file = s.file, entries = {} }; order[#order + 1] = s.file end
    table.insert(byfile[s.file].entries, { line = s.line, scope = s.scope })
  end
  local files = {}
  for _, f in ipairs(order) do
    local fe = byfile[f]; fe.count = #fe.entries; fe.collapsed = fe.count > 5; files[#files + 1] = fe
  end
  return files
end

-- render each risk as a role: "a ↔ b · line N  [writers_a | writers_b]" → the write sites, jumpable.
local function build_tree(res)
  local tree = {}
  for _, r in ipairs(res.risks) do
    local sites = {}
    for _, s in ipairs(res.sites[r.a] or {}) do sites[#sites + 1] = s end
    for _, s in ipairs(res.sites[r.b] or {}) do sites[#sites + 1] = s end
    local files = group_by_file(sites)
    local count = 0
    for _, f in ipairs(files) do count = count + f.count end
    tree[#tree + 1] = {
      label = ("%s ↔ %s · line %d  [%s | %s]"):format(
        r.a, r.b, r.line, table.concat(r.writers_a, ","), table.concat(r.writers_b, ",")),
      role = "fs", count = count, collapsed = false, files = files,
    }
  end
  return tree
end

lens.define{
  name = "false_sharing",
  applies = function(ctx) return ctx ~= nil and ctx.kind ~= "function" end,
  render = function(_, hud) end, -- nothing on open; analysis is on-demand (below)
  hints = { s = "false-sharing" }, -- shows in the HUD footer so `s` is discoverable
  actions = {
    s = function(ctx, hud)
      vim.notify("fox-symdeps · false-sharing: analyzing…", vim.log.levels.INFO)
      writers.for_struct(ctx, function(res, state)
        if state ~= "ok" or not res then
          local why
          if state == "no_client" then
            why = "clangd not attached"
          elseif hud.layout and hud.layout.data and hud.layout.data.is_template then
            -- templated struct: clangd gives no concrete field offsets until it's
            -- instantiated, so field resolution comes back empty even ON the
            -- definition. Don't blame the cursor position — name the real cause.
            why = "templated struct — no concrete field offsets un-instantiated; put the cursor on a concrete Foo<N> use"
          else
            why = "couldn't resolve fields — put the cursor on the struct's DEFINITION (same limit as Layout/Fields)"
          end
          hud:set_message("false-sharing (s): " .. why, "warn") -- persists in the HUD, readable
        elseif #res.risks == 0 then
          hud:set_message("false-sharing (s): none on shared lines ✓", "info")
        else
          hud:set_section("false_sharing", LABEL .. "  (advisory — sizeof is fingerprinted)", build_tree(res), "ok")
          hud:set_message(("false-sharing (s): %d risk(s) — advisory only"):format(#res.risks), "warn")
        end
      end)
    end,
  },
}
