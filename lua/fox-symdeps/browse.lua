-- browse.lua — struct browser: pick a struct/class from the project and start tracking it in the
-- panel. The higher-level entry above per-symbol inspection ("show all structs to trace from").
local M = {}

-- parse "file:line: ... struct Name ..." grep lines → sorted, de-duped { {name, file, line} }
local function parse(lines)
  local out, seen = {}, {}
  for _, l in ipairs(lines or {}) do
    local file, line, rest = l:match("^([^:]+):(%d+):(.*)$")
    if file then
      local name = rest:match("struct%s+([%w_]+)") or rest:match("class%s+([%w_]+)")
      if name and not seen[name] then
        seen[name] = true
        out[#out + 1] = { name = name, file = file:gsub("^%./", ""), line = tonumber(line) }
      end
    end
  end
  table.sort(out, function(a, b) return a.name < b.name end)
  return out
end

function M.browse(palette)
  local root = vim.fn.getcwd()
  require("fox-symdeps.runner").run(
    { "grep", "-rIn", "--include=*.hpp", "--include=*.cpp", "-E",
      "^[[:space:]]*(struct|class)[[:space:]]+[A-Za-z_][A-Za-z0-9_]*", "." },
    root,
    function(lines)
      local structs = parse(lines)
      if #structs == 0 then return require("fox-symdeps.ui").notify_raw("fox-symdeps · no structs found here", vim.log.levels.INFO) end
      require("fox-symdeps.ui").fuzzy_pick({
        title = "track struct", items = structs, palette = palette,
        format = function(it) return ("%-28s %s:%d"):format(it.name, it.file, it.line) end,
        on_choice = function(choice)
          if not choice then return end
          vim.cmd.edit(vim.fn.fnameescape(root .. "/" .. choice.file))
          local lc = vim.fn.getline(choice.line)
          pcall(vim.api.nvim_win_set_cursor, 0, { choice.line, (lc:find(choice.name, 1, true) or 1) - 1 })
          require("fox-symdeps.panel").toggle(palette)
        end,
      })
    end
  )
end

M._parse = parse -- for tests

-- roam: fuzzy-pick ANY symbol (struct OR function, anywhere in the project) via clangd's
-- workspace/symbol index, then inspect it in the cockpit. The IDE "go to symbol in
-- workspace" → analyze. LIVE fuzzy_pick (2026-08-18): the old shape was type-BLIND
-- (input → submit → then a list); now every keystroke re-queries clangd and the list
-- narrows under the prompt — clangd does the matching server-side.
local SYMBOL_ICON = { [5] = "◇", [23] = "◇", [12] = "→", [6] = "→", [10] = "▢", [11] = "▢" }
function M.roam(palette)
  require("fox-symdeps.ui").fuzzy_pick({
    title = "roam to symbol", palette = palette,
    hint = "type to search workspace symbols (clangd)",
    format = function(s)
      local qn = (s.container ~= "" and (s.container .. "::") or "") .. s.name
      return ("%s %-34s %s:%d"):format(SYMBOL_ICON[s.kind] or "·", qn, vim.fn.fnamemodify(s.file, ":."), s.line)
    end,
    live = function(query, update)
      if vim.trim(query) == "" then return update({}) end
      require("fox-symdeps.clangd").workspace_symbols(query, function(syms)
        update(syms or {})
      end)
    end,
    on_choice = function(choice)
      if not choice then return end
      vim.cmd.edit(vim.fn.fnameescape(choice.file))
      pcall(vim.api.nvim_win_set_cursor, 0, { choice.line, choice.col })
      require("fox-symdeps").inspect_cursor()
    end,
  })
end

-- Browse units BY [TAG] (north-star 0.4 "browse-units-by-tag"; §9: BOTH pickers derive — the
-- tag list from the grammar vocab, the unit list from the WRITTEN corpus). fuzzy_pick at both
-- stages, like the other pickers.
function M.by_tag(_palette)
  local uihelper = require("fox-symdeps.ui")
  local okn, nmod = pcall(require, "fox-symdeps.nodemodel")
  local vocab = okn and nmod.vocab and nmod.vocab() or nil
  local toks, seen = {}, {}
  for _, set in pairs({ vocab and vocab.concern or {}, vocab and vocab.surface or {} }) do
    for name in pairs(set) do
      if not seen[name] then seen[name] = true; toks[#toks + 1] = name end
    end
  end
  table.sort(toks)
  if #toks == 0 then
    return uihelper.notify_raw("browse-by-tag: vocab unavailable (foxtag unreachable)",
                               vim.log.levels.WARN)
  end
  uihelper.fuzzy_pick({ title = "browse by [TAG]", items = toks, palette = _palette,
                        on_choice = function(tok)
    if not tok then return end
    local f = vim.api.nvim_buf_get_name(0)
    local root = (f ~= "" and vim.fs.root(f, { ".git", "compile_commands.json" })) or vim.fn.getcwd()
    require("fox-symdeps.runner").run(
      { "rg", "-n", "--no-heading", "-e", "\\[TAG\\]_\\[.*\\[" .. tok .. "\\]",
        "--glob", "*.hpp", "--glob", "*.cpp",
        "--glob", "!tools/**", "--glob", "!DOCS/**", "--glob", "!build*/**" },
      root, function(lines)
        if not lines or #lines == 0 then
          return uihelper.notify_raw("browse-by-tag: no unit carries [" .. tok .. "]",
                                     vim.log.levels.INFO)
        end
        local unitindex = require("fox-symdeps.unitindex")
        local items = {}
        for _, l in ipairs(lines) do
          local file, lno = l:match("^([^:]+):(%d+):")
          if file then
            local abs = root .. "/" .. file
            local u = unitindex.at(abs, tonumber(lno))
            items[#items + 1] = {
              label = u and ("%s %s — %s"):format(u.type, u.name, file) or (file .. ":" .. lno),
              file = abs, line = (u and u.opener) or tonumber(lno),
            }
          end
        end
        table.sort(items, function(a, b) return a.label < b.label end)
        uihelper.fuzzy_pick({
          title = ("[%s] units"):format(tok), items = items, palette = _palette,
          format = function(it) return it.label end,
          on_choice = function(choice)
            if not choice then return end
            vim.cmd("normal! m`")
            vim.cmd(("edit +%d %s"):format(choice.line, vim.fn.fnameescape(choice.file)))
          end,
        })
      end)
  end })
end

return M
