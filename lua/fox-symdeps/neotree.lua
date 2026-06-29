-- neo-tree consumer-count decoration. Badges each file (and rolls the count up to its
-- parent dirs) with how many times the active symbol is referenced there. Drop-in: it
-- injects its own component + renderer entry into neo-tree at runtime (no edit to the
-- user's neo-tree config) and redraws. Cleared when the HUD closes. neo-tree optional —
-- absent → silently no-ops, the HUD still works.
local M = {}

local lookup = {} -- abspath (file or ancestor dir) -> reference count for the active symbol
local injected = false

-- path -> count from clangd reference items, with ancestor-directory rollup (mirrors how
-- neo-tree's diagnostics bubbles a file's count up to every parent dir, so the component
-- stays a single-key lookup for directory nodes too).
local function build_lookup(items)
  local file_counts = {}
  for _, it in ipairs(items or {}) do
    if it.file then file_counts[it.file] = (file_counts[it.file] or 0) + 1 end
  end
  local out = {}
  for file, n in pairs(file_counts) do
    out[file] = (out[file] or 0) + n
    local dir = vim.fn.fnamemodify(file, ":h")
    while dir and dir ~= "" and dir ~= "/" do
      out[dir] = (out[dir] or 0) + n
      local parent = vim.fn.fnamemodify(dir, ":h")
      if parent == dir then break end
      dir = parent
    end
  end
  return out
end

local function component(_, node, _)
  local key = node.path or (node.get_id and node:get_id())
  local n = key and lookup[key]
  if not n then return {} end
  return { text = " ◇" .. n, highlight = "FoxSymdepsTreeCount" }
end

local function ensure_injected()
  if injected then return true end
  local ok_nt, nt = pcall(require, "neo-tree")
  local ok_mgr, manager = pcall(require, "neo-tree.sources.manager")
  if not (ok_nt and ok_mgr) then return false end
  pcall(function() nt.ensure_config() end)
  local cfg = nt.config and nt.config.filesystem
  if not (cfg and cfg.components and cfg.renderers) then return false end
  cfg.components.fox_symdeps_count = component
  for _, t in ipairs({ "file", "directory" }) do
    if cfg.renderers[t] then table.insert(cfg.renderers[t], { "fox_symdeps_count" }) end
  end
  -- states created before this injection won't have copied the template; patch them too
  pcall(function()
    manager._for_each_state("filesystem", function(state)
      state.components.fox_symdeps_count = component
      for _, t in ipairs({ "file", "directory" }) do
        if state.renderers[t] then table.insert(state.renderers[t], { "fox_symdeps_count" }) end
      end
    end)
  end)
  injected = true
  return true
end

local function redraw()
  pcall(function() require("neo-tree.sources.manager").redraw("filesystem") end)
end

-- Decorate the tree for the active symbol's consumers (items = clangd reference list).
function M.set(items)
  if not ensure_injected() then return end
  lookup = build_lookup(items)
  redraw()
end

-- Clear the decoration (the HUD's on_close hook calls this).
function M.clear()
  if next(lookup) == nil then return end
  lookup = {}
  redraw()
end

M._build_lookup = build_lookup -- exposed for tests

return M
