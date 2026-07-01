-- pack.lua — W14 tool-pack host. Discover + (re)load provider modules from configured pack
-- dirs. Each *.lua in a pack dir is a thin provider that calls provider.register(...) to add a
-- HUD section for the symbol under the cursor. Drop a new per-symbol tool in the dir and it
-- shows up; :FoxSymdepsReload re-scans (scripts run fresh per call, so "constantly updated" is
-- free). The core stays generic/publishable; the pack itself is private (per D9: fox-symdeps-trader/).
local M = {}
local provider = require("fox-symdeps.provider")
local dirs = {}

-- load every *.lua provider file under a pack dir. Returns how many loaded OK.
local function load_dir(dir)
  local expanded = vim.fn.expand(dir)
  if vim.fn.isdirectory(expanded) ~= 1 then return 0 end
  local loaded = 0
  for name, t in vim.fs.dir(expanded) do
    if t == "file" and name:match("%.lua$") then
      local ok, err = pcall(dofile, expanded .. "/" .. name)
      if ok then loaded = loaded + 1
      else vim.notify(("fox-symdeps pack · %s failed: %s"):format(name, err), vim.log.levels.WARN) end
    end
  end
  return loaded
end

-- (re)scan all configured pack dirs from a clean registry. Returns total providers loaded.
function M.reload()
  provider.clear()
  local total = 0
  for _, d in ipairs(dirs) do total = total + load_dir(d) end
  return total
end

function M.setup(pack_dirs)
  dirs = pack_dirs or {}
  return M.reload()
end

return M
