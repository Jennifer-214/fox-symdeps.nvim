-- lenses/struct_budget.lua — cache-residency context for a STRUCT. If the struct is in the engine's
-- size-budget manifest (check_struct_size_budget.py), show "▣ cache-residency gated · tier(s)" — so
-- when you (or Claude) edit it you know it's under a cache-tier size budget (the struct-side sister of
-- the hot-path instruction budget). Auto (a file read). Self-gates on the tool + a manifest match.
local lens = require("fox-symdeps.lens")

local TOOL = "tools/check_struct_size_budget.py"

local function find_up(file, rel)
  local dir = vim.fn.fnamemodify(file or "", ":h")
  while dir and dir ~= "/" and dir ~= "" do
    local p = dir .. "/" .. rel
    if vim.fn.filereadable(p) == 1 then return p, dir end
    local parent = vim.fn.fnamemodify(dir, ":h")
    if parent == dir then break end
    dir = parent
  end
end

-- manifest rows: {"type": "RollingStats<64,128>", ..., "tier": "L1d"}. Distinct tiers for base `name`
-- (template instantiations share a base — RollingStats<64,128>/<64,256> → base "RollingStats").
local function tiers_for(tool, name)
  local ok, lines = pcall(vim.fn.readfile, tool)
  if not ok then return {} end
  local seen, out = {}, {}
  for _, l in ipairs(lines) do
    local t = l:match('"type":%s*"([^"]+)"')
    if t and t:gsub("%s*<.*$", "") == name then
      local tier = l:match('"tier":%s*"(%w+)"')
      if tier and not seen[tier] then seen[tier] = true; out[#out + 1] = tier end
    end
  end
  return out
end

lens.define{
  name = "struct_budget",
  applies = function(ctx)
    return ctx ~= nil and (ctx.kind == "struct" or ctx.kind == "type") and find_up(ctx.file, TOOL) ~= nil
  end,
  render = function(ctx, hud)
    local tool = find_up(ctx.file, TOOL)
    if not tool then return end
    local tiers = tiers_for(tool, ctx.symbol)
    if #tiers == 0 then return end -- not budget-gated → silent
    hud:set_section("struct_budget",
      ("▣ cache-residency gated · size-budget tier(s): %s"):format(table.concat(tiers, ", ")),
      nil, "ok") -- header-only info line
  end,
}
