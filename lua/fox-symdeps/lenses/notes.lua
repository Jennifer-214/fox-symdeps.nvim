-- lenses/notes.lua — surface recorded KNOWLEDGE for the symbol under cursor: word-boundary mentions
-- across the project's markdown docs AND any extra `doc_dirs` (a setup opt). Design specs, invariants,
-- FAILED_OPTIMIZATIONS, changelogs and plans often live in a SEPARATE workspace repo — point doc_dirs
-- at it and `n` pulls from there too. On-demand. So when Claude touches a symbol, you see everything
-- you've ever written about it. Generic (rg over *.md). Results group into collapsible categories
-- (most-relevant first, backups last), with paths shown relative to their repo.
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

-- (rank, category) for a doc path. Higher rank = more relevant → surfaces first; backups sink to the
-- bottom (near-dupes that otherwise drown the real docs). Category is the collapsible group label. Pure.
local function doc_category(path)
  local p = path:lower()
  if p:find("%.backup") or p:find("/backup") or p:find("%.bak") or p:find("/archive") then return 0, "backups" end
  if p:find("design_spec") or p:find("invariant") or p:find("failed_opt") then return 5, "specs" end
  if p:find("changelog") then return 4, "changelog" end
  if p:find("spec") or p:find("discipline") or p:find("taxonomy") or p:find("hot_path") then return 4, "reference" end
  if p:find("/plan") then return 3, "plans" end
  if p:find("readme") or p:find("/log") or p:find("handoff") then return 1, "logs" end
  return 2, "docs"
end

-- display path: relative to the deepest matching search dir, prefixed with that dir's basename so
-- multi-repo mentions stay unambiguous. Falls back to the filename if nothing matches. Pure.
local function rel_to_dirs(path, dirs)
  local best
  for _, d in ipairs(dirs or {}) do
    if path:sub(1, #d + 1) == d .. "/" and (not best or #d > #best) then best = d end
  end
  if best then
    return vim.fn.fnamemodify(best, ":t") .. "/" .. path:sub(#best + 2)
  end
  return vim.fn.fnamemodify(path, ":t")
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
        -- group hits by file
        local byfile, order = {}, {}
        for _, s in ipairs(sites) do
          if not byfile[s.file] then byfile[s.file] = { file = s.file, entries = {} }; order[#order + 1] = s.file end
          table.insert(byfile[s.file].entries, { line = s.line, scope = (s.text or ""):sub(1, 60) })
        end
        local files, count = {}, 0
        for _, f in ipairs(order) do
          local fe = byfile[f]
          fe.count = #fe.entries; fe.collapsed = true; fe.mtime = vim.fn.getftime(fe.file)
          fe.rel = rel_to_dirs(fe.file, dirs)
          fe.rank, fe.cat = doc_category(fe.file)
          count = count + fe.count; files[#files + 1] = fe
        end
        -- relevance-first: high-signal category on top, backups last; then recency, then density
        table.sort(files, function(a, b)
          if a.rank ~= b.rank then return a.rank > b.rank end
          if a.mtime ~= b.mtime then return a.mtime > b.mtime end
          return a.count > b.count
        end)
        local nfiles = #files
        if nfiles > FILE_CAP then
          local capped = {}; for i = 1, FILE_CAP do capped[i] = files[i] end; files = capped
        end
        -- group the (already sorted) files into collapsible category roles; backups collapsed by default
        local roles, byrole = {}, {}
        for _, fe in ipairs(files) do
          local r = byrole[fe.cat]
          if not r then
            r = { label = fe.cat, role = "notes", count = 0, files = {}, rank = fe.rank,
                  collapsed = true }
            byrole[fe.cat] = r; roles[#roles + 1] = r
          end
          r.files[#r.files + 1] = fe; r.count = r.count + fe.count
        end
        table.sort(roles, function(a, b) return a.rank > b.rank end)
        hud:set_section("notes",
          ("◇ Docs mention %s · %d hit(s) in %d file(s)%s")
            :format(ctx.symbol, count, nfiles, nfiles > FILE_CAP and (" — showing " .. FILE_CAP) or ""),
          roles, "ok")
        vim.notify(("fox-symdeps · %s: %d doc mention(s) in %d file(s)"):format(ctx.symbol, count, nfiles),
          vim.log.levels.WARN)
      end)
    end,
  },
}

return { _doc_category = doc_category, _rel_to_dirs = rel_to_dirs }
