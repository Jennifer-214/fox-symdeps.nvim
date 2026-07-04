-- lenses/notes.lua — surface recorded KNOWLEDGE for the symbol under cursor: word-boundary mentions
-- across the project's markdown docs AND any extra `doc_dirs` (a setup opt). Design specs, invariants,
-- FAILED_OPTIMIZATIONS, changelogs and plans often live in a SEPARATE workspace repo — point doc_dirs
-- at it and `n` pulls from there too. On-demand. So when Claude touches a symbol, you see everything
-- you've ever written about it. Generic (rg over *.md).
local lens = require("fox-symdeps.lens")
local runner = require("fox-symdeps.runner")

local FILE_CAP = 25 -- a hot symbol can appear in 100+ docs; show the first N files, note the rest

local function search_dirs(file)
  local root = vim.fs.root(file, { ".git", "compile_commands.json" }) or vim.fn.fnamemodify(file, ":h")
  local dirs, seen = { root }, { [root] = true }
  local ok, cfg = pcall(function() return require("fox-symdeps").config end)
  if ok and cfg and type(cfg.doc_dirs) == "table" then
    for _, d in ipairs(cfg.doc_dirs) do
      local e = vim.fn.expand(d)
      if not seen[e] and vim.fn.isdirectory(e) == 1 then seen[e] = true; dirs[#dirs + 1] = e end
    end
  end
  return dirs
end

lens.define{
  name = "notes",
  applies = function(ctx) return ctx ~= nil and type(ctx.symbol) == "string" and #ctx.symbol >= 3 end,
  render = function(_, _) end, -- on-demand only
  hints = { n = "notes/docs" },
  actions = {
    n = function(ctx, hud)
      local dirs = search_dirs(ctx.file)
      vim.notify("fox-symdeps · notes: searching docs…", vim.log.levels.INFO)
      local argv = { "rg", "--no-heading", "--line-number", "--color", "never", "-g", "*.md", "-w", ctx.symbol }
      for _, d in ipairs(dirs) do argv[#argv + 1] = d end
      runner.run(argv, dirs[1], function(lines)
        local sites = runner.parse_sites(lines or {})
        if #sites == 0 then
          vim.notify(("fox-symdeps · %s: no doc mentions"):format(ctx.symbol), vim.log.levels.INFO)
          return
        end
        local byfile, order = {}, {}
        for _, s in ipairs(sites) do
          if not byfile[s.file] then byfile[s.file] = { file = s.file, entries = {} }; order[#order + 1] = s.file end
          table.insert(byfile[s.file].entries, { line = s.line, scope = (s.text or ""):sub(1, 60) })
        end
        local files, count = {}, 0
        for _, f in ipairs(order) do
          local fe = byfile[f]; fe.count = #fe.entries; fe.collapsed = true; count = count + fe.count; files[#files + 1] = fe
        end
        local nfiles = #files
        if nfiles > FILE_CAP then
          local capped = {}
          for i = 1, FILE_CAP do capped[i] = files[i] end
          files = capped
        end
        hud:set_section("notes",
          ("📝 Docs mention %s · %d hit(s) in %d file(s)%s")
            :format(ctx.symbol, count, nfiles, nfiles > FILE_CAP and (" — showing " .. FILE_CAP) or ""),
          { { label = "Mentions", role = "notes", count = count, collapsed = false, files = files } }, "ok")
        vim.notify(("fox-symdeps · %s: %d doc mention(s) in %d file(s)"):format(ctx.symbol, count, nfiles),
          vim.log.levels.WARN)
      end)
    end,
  },
}
