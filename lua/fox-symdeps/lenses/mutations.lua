-- lenses/mutations.lua — "who writes this?" for a field / variable. On-demand via `m`. Surfaces
-- write-owner (the same L0 write-detection false-sharing uses) as a navigation aid: which functions
-- mutate it + jumpable write sites, or "read-only ✓" when it's never written. Directly answers the
-- co-programming question — when Claude touches a field, who else mutates it. Generic (any C++).
local lens = require("fox-symdeps.lens")
local writers = require("fox-symdeps.writers")

local LABEL = "✎ Written by"

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

lens.define{
  name = "mutations",
  applies = function(ctx) return ctx ~= nil and (ctx.kind == "field" or ctx.kind == "symbol") end,
  render = function(_, _) end, -- on-demand only
  hints = { m = "mutations" },
  actions = {
    m = function(ctx, hud)
      vim.notify("fox-symdeps · mutations: scanning…", vim.log.levels.INFO)
      writers.for_symbol(ctx, function(res, state)
        if state ~= "ok" or not res then
          vim.notify("fox-symdeps · mutations: " .. tostring(state), vim.log.levels.WARN)
        elseif #res.sites == 0 then
          vim.notify(("fox-symdeps · %s: never written (%d reads) — read-only ✓"):format(ctx.symbol, res.reads),
            vim.log.levels.INFO)
        else
          local names = {}
          for w in pairs(res.writers) do names[#names + 1] = w end
          table.sort(names)
          local files = group_by_file(res.sites)
          local count = 0
          for _, f in ipairs(files) do count = count + f.count end
          hud:set_section("mutations",
            ("%s: %s  (%d writes · %d reads)"):format(LABEL, table.concat(names, ", "), #res.sites, res.reads),
            { { label = "Written by", role = "writes", count = count, collapsed = false, files = files } }, "ok")
          vim.notify(("fox-symdeps · %s: written by %s"):format(ctx.symbol, table.concat(names, ", ")), vim.log.levels.WARN)
        end
      end)
    end,
  },
}
