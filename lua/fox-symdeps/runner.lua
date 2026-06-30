-- runner.lua — async shell-out (vim.system) + parsers for the line shapes external tools
-- emit. Generic: NO tool-specific knowledge here (the trader provider drives it with
-- gen_code_map args). The plugin's one "shell a tool and parse it" primitive.
local M = {}

-- Run argv async in `cwd`; cb(lines) with stdout split to lines, or cb(nil) on hard failure.
function M.run(argv, cwd, cb)
  local ok = pcall(vim.system, argv, { cwd = cwd, text = true }, function(res)
    vim.schedule(function()
      if (res.code ~= 0) and (not res.stdout or res.stdout == "") then return cb(nil) end
      local lines = {}
      for line in (res.stdout or ""):gmatch("[^\n]+") do lines[#lines + 1] = line end
      cb(lines)
    end)
  end)
  if not ok then cb(nil) end
end

-- "  <file>:<line>:<text>" site lines (byte-context / callers / types). → { {file, line, text} }
function M.parse_sites(lines)
  local out = {}
  for _, l in ipairs(lines or {}) do
    local file, line, text = l:match("^%s*([^:]+):(%d+):(.*)$")
    if file and line then
      out[#out + 1] = { file = file, line = tonumber(line), text = (text or ""):gsub("^%s+", "") }
    end
  end
  return out
end

-- "  <file>   struct <name>   { <fields> }" embedder lines (--structs). → { {file, name, fields} }
function M.parse_structs(lines)
  local out = {}
  for _, l in ipairs(lines or {}) do
    local file, name, fields = l:match("^%s*(%S+)%s+struct%s+(%S+)%s+{(.*)}")
    if file and name then
      out[#out + 1] = { file = file, name = name, fields = vim.trim(fields or "") }
    end
  end
  return out
end

-- "  [transitive] <Name>" lines (--composition). → { name, ... }
function M.parse_transitive(lines)
  local out = {}
  for _, l in ipairs(lines or {}) do
    local name = l:match("^%s*%[transitive%]%s+(%S+)")
    if name then out[#out + 1] = name end
  end
  return out
end

return M
