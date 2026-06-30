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
      if #structs == 0 then return vim.notify("fox-symdeps · no structs found here", vim.log.levels.INFO) end
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

return M
