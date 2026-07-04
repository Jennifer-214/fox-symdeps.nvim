-- :checkhealth fox-symdeps — is everything the HUD needs reachable?
local M = {}

function M.check()
  local h = vim.health
  h.start("fox-symdeps")

  -- ── core deps ──────────────────────────────────────────────────────────────
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

  if vim.fn.executable("rg") == 1 then
    h.ok("ripgrep: " .. vim.fn.exepath("rg"))
  else
    h.warn("ripgrep (rg) not on PATH — Contains / Uses / notes / cascade resolution degrade")
  end

  if pcall(vim.treesitter.get_string_parser, "int x;", "cpp") then
    h.ok("treesitter cpp parser available")
  else
    h.warn("no cpp treesitter parser — role classification, Uses, false-sharing degrade (install via nvim-treesitter)")
  end

  -- ── plugin state ───────────────────────────────────────────────────────────
  local ok_p, provider = pcall(require, "fox-symdeps.provider")
  if ok_p then
    local n = provider.count()
    if n > 0 then h.ok(n .. " lens(es) registered")
    else h.warn("no lenses registered — check lenses/ loaded at setup") end
  end

  local ok_m, mod = pcall(require, "fox-symdeps")
  local dd = (ok_m and mod.config and mod.config.doc_dirs) or {}
  if #dd == 0 then
    h.info("doc_dirs empty — `n` (notes) searches only the project repo (set opts.doc_dirs to also grep a workspace)")
  else
    local missing = {}
    for _, d in ipairs(dd) do
      if vim.fn.isdirectory(vim.fn.expand(d)) ~= 1 then missing[#missing + 1] = d end
    end
    if #missing == 0 then h.ok(("doc_dirs: %d configured, all present"):format(#dd))
    else h.warn("doc_dirs has missing dirs: " .. table.concat(missing, ", ")) end
  end

  -- ── optional integrations ──────────────────────────────────────────────────
  if pcall(require, "which-key") then
    h.ok("which-key present — <leader>d group label active")
  else
    h.info("which-key absent — group label skipped (harmless)")
  end

  if pcall(require, "neo-tree") then
    h.ok("neo-tree present — consumer-count tree badges enabled")
  else
    h.info("neo-tree absent — tree badges skipped (HUD still works)")
  end
end

return M
