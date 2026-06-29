-- :checkhealth fox-symdeps — is everything the HUD needs reachable?
local M = {}

function M.check()
  local h = vim.health
  h.start("fox-symdeps")

  if vim.fn.executable("clangd") == 1 then
    h.ok("clangd: " .. vim.fn.exepath("clangd"))
  else
    h.error("clangd not on PATH — layout + consumers need it")
  end

  local cs = vim.lsp.get_clients({ name = "clangd" })
  if #cs > 0 then
    h.ok("clangd attached (" .. #cs .. " client" .. (#cs > 1 and "s" or "") .. ")")
  else
    h.warn("no clangd client active — open a C++ file in a project to attach")
  end

  local cc = vim.fs.find("compile_commands.json", { upward = true, path = vim.fn.getcwd() })[1]
  if cc then
    h.ok("compile_commands.json: " .. cc)
  else
    h.warn("no compile_commands.json upward from cwd — layout may read 'unavailable'")
  end

  if pcall(require, "which-key") then
    h.ok("which-key present — <leader>d group label active")
  else
    h.info("which-key absent — group label skipped (harmless)")
  end
end

return M
