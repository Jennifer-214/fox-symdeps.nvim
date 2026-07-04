-- lenses/hotpath.lua — latency-critical context for a FUNCTION. Reads the engine's compiled
-- instruction-budget sidecar (tools/lib/latency_path_budgets.json) + the manifest tier, and shows
-- "🔥 hot-path · budget N instr" when the function under cursor is on a gated latency path. Auto
-- (a cheap JSON + file read — no clang/clangd). Self-gates on the sidecar existing → silent elsewhere.
-- So when you (or Claude) touch a hot function, you immediately see it's budgeted, and by how much.
local lens = require("fox-symdeps.lens")

local SIDECAR = "tools/lib/latency_path_budgets.json"
local TOOL = "tools/check_latency_path_conformance.py"

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

-- the manifest carries the tier on the same line as the name: `"name": "X", "tier": "hot"`.
local function tier_of(root, name)
  local tool = root .. "/" .. TOOL
  if vim.fn.filereadable(tool) ~= 1 then return nil end
  local ok, lines = pcall(vim.fn.readfile, tool)
  if not ok then return nil end
  for _, l in ipairs(lines) do
    if l:find('"name": "' .. name .. '"', 1, true) then return l:match('"tier":%s*"(%w+)"') end
  end
end

lens.define{
  name = "hotpath",
  applies = function(ctx)
    return ctx ~= nil and ctx.kind == "function" and find_up(ctx.file, SIDECAR) ~= nil
  end,
  render = function(ctx, hud)
    local sidecar, root = find_up(ctx.file, SIDECAR)
    if not sidecar then return end
    local ok, lines = pcall(vim.fn.readfile, sidecar)
    if not ok then return end
    local okj, data = pcall(vim.json.decode, table.concat(lines, "\n"))
    if not okj or type(data) ~= "table" then return end
    local b = data[ctx.symbol]
    if not b then return end -- not on a gated latency path → silent
    local tier = tier_of(root, ctx.symbol) or "latency"
    local icon = tier == "hot" and "🔥" or (tier == "slow" and "🐢" or "⏱")
    hud:set_section("hotpath",
      ("%s %s-path · budget %d instr · %d data-dependent branch(es)")
        :format(icon, tier, b.instructions or 0, b.data_dependent or 0),
      nil, "ok") -- header-only info line
  end,
}
