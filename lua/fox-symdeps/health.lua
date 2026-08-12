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

  -- ── tag layer: the foxtag-derived node model (E.1.2.B 0.3) ────────────────
  local ok_nm, nm = pcall(require, "fox-symdeps.nodemodel")
  if ok_nm then
    local bin = nm.bin()
    if not bin then
      h.warn("foxtag not found — tag-nav (:FoxSymdepsDerived / :FoxSymdepsMenu / tag writer) degrades. "
        .. "Build it (`bash tools/foxtag/build.sh`) or set opts.foxtag_bin. Trees/layout/consumers are unaffected.")
    else
      local m = nm.model()
      if not m then
        h.warn("foxtag at " .. bin .. " but `grammar --json` gave no node model — rebuild it")
      else
        h.ok(("node model derived from foxtag (%d unit types, %d closable) · %s")
          :format(m.meta.count, vim.tbl_count(m.openers), bin))
        local st = nm.staleness()
        if st and st.derived_at then
          h.warn(("node model derived at %s but repo HEAD is %s — rebuild foxtag (a stale binary emits a "
            .. "valid-looking envelope, so the tag layer would be silently wrong)")
            :format(st.derived_at:sub(1, 8), st.repo_at:sub(1, 8)))
        elseif st then
          h.warn(("foxtag reports version %s but TOOLCHAIN_VERSION is %s — rebuild foxtag")
            :format(tostring(st.version), tostring(st.toolchain_version)))
        end
      end
    end
  end

  -- ── plugin state ───────────────────────────────────────────────────────────
  local ok_p, provider = pcall(require, "fox-symdeps.provider")
  if ok_p then
    local n = provider.count()
    if n > 0 then h.ok(n .. " lens(es) registered")
    else h.warn("no lenses registered — check lenses/ loaded at setup") end
  end

  -- ── tag-native navigation deps (dashboard tiles · browse-by-tag · corpus scans) ──
  if vim.fn.executable("rg") == 1 then
    h.ok("rg: " .. vim.fn.exepath("rg"))
  else
    h.error("rg not on PATH — dashboard fact tiles + browse-by-[TAG] + notes scans need it")
  end

  -- ── docview resolver chain (the [REFERENCE] doc-viewer's deps) ─────────────
  if vim.fn.executable("python3") == 1 then
    h.ok("python3: " .. vim.fn.exepath("python3"))
  else
    h.error("python3 not on PATH — docview [REFERENCE] resolution (citable_ids.py) needs it")
  end
  do
    local buf_file = vim.api.nvim_buf_get_name(0)
    local root = (buf_file ~= "" and vim.fs.root(buf_file, { ".git", "compile_commands.json" }))
                 or vim.fn.getcwd()
    local resolver = root .. "/tools/citable_ids.py"
    if vim.fn.filereadable(resolver) == 1 then
      h.ok("citable_ids.py reachable (" .. resolver .. ")")
    else
      h.warn("tools/citable_ids.py not found from this root — docview refs will refuse (open a repo file)")
    end
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
