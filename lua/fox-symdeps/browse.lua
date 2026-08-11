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
      vim.ui.select(structs, {
        prompt = "fox-symdeps · track struct:",
        format_item = function(it) return ("%-28s %s:%d"):format(it.name, it.file, it.line) end,
      }, function(choice)
        if not choice then return end
        vim.cmd.edit(vim.fn.fnameescape(root .. "/" .. choice.file))
        local lc = vim.fn.getline(choice.line)
        pcall(vim.api.nvim_win_set_cursor, 0, { choice.line, (lc:find(choice.name, 1, true) or 1) - 1 })
        require("fox-symdeps.panel").toggle(palette)
      end)
    end
  )
end

M._parse = parse -- for tests

-- roam: fuzzy-pick ANY symbol (struct OR function, anywhere in the project) via
-- clangd's workspace/symbol index, then inspect it in the cockpit. The IDE
-- "go to symbol in workspace" → analyze. Rides vim.ui.select (so your fzf).
local SYMBOL_ICON = { [5] = "◇", [23] = "◇", [12] = "→", [6] = "→", [10] = "▢", [11] = "▢" }
function M.roam(palette)
  vim.ui.input({ prompt = "fox-symdeps · roam to symbol: " }, function(query)
    if not query or vim.trim(query) == "" then return end
    require("fox-symdeps.clangd").workspace_symbols(query, function(syms)
      if not syms or #syms == 0 then
        return require("fox-symdeps.ui").notify_raw("fox-symdeps · no symbols match '" .. query .. "' (is clangd attached?)", vim.log.levels.INFO)
      end
      vim.ui.select(syms, {
        prompt = "fox-symdeps · inspect:",
        format_item = function(s)
          local qn = (s.container ~= "" and (s.container .. "::") or "") .. s.name
          return ("%s %-34s %s:%d"):format(SYMBOL_ICON[s.kind] or "·", qn, vim.fn.fnamemodify(s.file, ":."), s.line)
        end,
      }, function(choice)
        if not choice then return end
        vim.cmd.edit(vim.fn.fnameescape(choice.file))
        pcall(vim.api.nvim_win_set_cursor, 0, { choice.line, choice.col })
        require("fox-symdeps").inspect_cursor()
      end)
    end)
  end)
end

return M
