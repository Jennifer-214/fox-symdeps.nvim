-- aggregate.lua — whole-codebase cuts (vs the per-symbol HUD). First tile: widest headers = the
-- change-blast-radius ranking. Edit a most-included header and you recompile half the engine; this
-- surfaces which headers those are, project-wide, in one pass. It's the includers idea inverted:
-- instead of "who includes THIS header," it's "rank every header by how many files include it."
local M = {}

-- pure: given raw `rg --line-number` #include lines (file:line:content) and a set of in-repo header
-- basenames (basename -> path), tally DISTINCT including files per header, keep only in-repo headers
-- (system headers like <vector> aren't editable → not blast-radius), rank by count desc then name.
-- Returns { { header = basename, count = N, path = <a repo path> }, ... }, truncated to `limit`.
function M.rank(include_lines, repo_headers, limit)
  local by = {} -- basename -> set of including files
  for _, l in ipairs(include_lines or {}) do
    local incfile, _, content = l:match("^(.-):(%d+):(.*)$")
    if incfile and content then
      local inc = content:match("#include%s*[<\"]([^<>\"]+)[>\"]")
      local base = inc and inc:gsub(".*/", "") -- strip any include-path prefix → basename
      if base and (not repo_headers or repo_headers[base]) then
        by[base] = by[base] or {}
        by[base][incfile] = true
      end
    end
  end
  local out = {}
  for base, files in pairs(by) do
    local n = 0
    for _ in pairs(files) do n = n + 1 end
    out[#out + 1] = { header = base, count = n, path = repo_headers and repo_headers[base] or nil }
  end
  table.sort(out, function(a, b)
    if a.count ~= b.count then return a.count > b.count end
    return a.header < b.header
  end)
  if limit and #out > limit then
    local t = {}
    for i = 1, limit do t[i] = out[i] end
    out = t
  end
  return out
end

-- in-repo header basenames -> a representative path (for jump). Impure (rg --files).
local function repo_header_set(root)
  local ok, files = pcall(vim.fn.systemlist, {
    "rg", "--files", "-g", "*.hpp", "-g", "*.h", "-g", "*.hh", "-g", "*.hxx", root,
  })
  local set = {}
  if ok and type(files) == "table" then
    for _, f in ipairs(files) do
      local base = f:gsub(".*/", "")
      if not set[base] then set[base] = f end -- first path wins on a basename collision
    end
  end
  return set
end

-- project-wide widest-headers ranking (one #include scan + one file list). limit caps the result.
function M.widest_headers(root, limit)
  if not root then return {} end
  local headers = repo_header_set(root)
  local ok, lines = pcall(vim.fn.systemlist, {
    "rg", "--no-heading", "--line-number", "--color", "never",
    "-g", "*.hpp", "-g", "*.h", "-g", "*.hh", "-g", "*.hxx",
    "-g", "*.cpp", "-g", "*.cc", "-g", "*.cxx", "-g", "*.c",
    "-e", "#include[[:space:]]*[<\"]", root,
  })
  return M.rank((ok and type(lines) == "table") and lines or {}, headers, limit)
end

return M
