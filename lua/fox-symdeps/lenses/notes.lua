-- lenses/notes.lua — surface recorded KNOWLEDGE for the symbol under cursor: word-boundary mentions
-- across the project's markdown docs (FAILED_OPTIMIZATIONS, invariants, changelogs, design specs,
-- READMEs). On-demand via `n`. So when Claude touches a function, you see at a glance whether there's
-- a note / gotcha / invariant about it — the "don't re-walk dead ends" signal. Generic (rg over *.md).
local lens = require("fox-symdeps.lens")
local runner = require("fox-symdeps.runner")

local function project_root(file)
  return vim.fs.root(file, { ".git", "compile_commands.json" }) or vim.fn.fnamemodify(file, ":h")
end

lens.define{
  name = "notes",
  applies = function(ctx) return ctx ~= nil and type(ctx.symbol) == "string" and #ctx.symbol >= 3 end,
  render = function(_, _) end, -- on-demand only
  hints = { n = "notes/docs" },
  actions = {
    n = function(ctx, hud)
      local root = project_root(ctx.file)
      vim.notify("fox-symdeps · notes: searching docs…", vim.log.levels.INFO)
      runner.run(
        { "rg", "--no-heading", "--line-number", "--color", "never", "-g", "*.md", "-w", ctx.symbol, root },
        root,
        function(lines)
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
            local fe = byfile[f]; fe.count = #fe.entries; fe.collapsed = fe.count > 5; count = count + fe.count; files[#files + 1] = fe
          end
          hud:set_section("notes", ("📝 Docs mention %s"):format(ctx.symbol),
            { { label = "Mentions", role = "notes", count = count, collapsed = false, files = files } }, "ok")
          vim.notify(("fox-symdeps · %s: %d doc mention(s)"):format(ctx.symbol, count), vim.log.levels.INFO)
        end)
    end,
  },
}
