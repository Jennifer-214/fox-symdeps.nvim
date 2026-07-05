-- status.lua — the always-on chip. The purest cure for "modal": the one fact you check constantly
-- (size + cache-line fit) lives permanently in the chrome — `◇ ExecutionCore 66B ▲` / `◇ FixedPoint
-- 16B ✓` — instead of behind a float you open. Two surfaces off one cache: a pull function for
-- lualine/heirline (`require("fox-symdeps").status()`) and a zero-config winbar toggle (<leader>dc).
-- The CursorHold-fed cache is also the seed of the public query API (a synchronous `current()`).
local M = {}
local cache = {} -- bufnr -> { symbol, size?, is_template? }
local aug
M.enabled = false -- winbar mode

-- pure: format a chip from cached facts (or "" when there's nothing on the cursor). ✓ = fits a
-- cache line, ▲ = spills one — the at-a-glance residency verdict, same threshold as the lenses.
function M.format(facts)
  if not facts or not facts.symbol then return "" end
  if facts.is_template then return "◇ " .. facts.symbol .. " <T>" end
  if not facts.size then return "" end
  return ("◇ %s %dB %s"):format(facts.symbol, facts.size, facts.size <= 64 and "✓" or "▲")
end

-- a C++ buffer we chip on (headers included; the winbar stays off elsewhere).
local function is_cpp(buf)
  local ft = vim.bo[buf] and vim.bo[buf].filetype or ""
  return ft == "cpp" or ft == "c" or ft == "cuda" or ft == "objcpp"
end

local function apply_winbar(win)
  if not (win and vim.api.nvim_win_is_valid(win)) then return end
  local buf = vim.api.nvim_win_get_buf(win)
  if not M.enabled or not is_cpp(buf) then return end
  local text = M.format(cache[buf])
  vim.wo[win].winbar = text ~= "" and ("%#FoxSymdepsHeader# " .. text .. " %*") or ""
end

-- refresh the cache for the current buffer's cursor symbol (async), then repaint its winbar.
local function refresh()
  local win = vim.api.nvim_get_current_win()
  local buf = vim.api.nvim_win_get_buf(win)
  local ok, ctx = pcall(function() return require("fox-symdeps.context").under_cursor() end)
  if not ok or not ctx or ctx.kind == "function" then
    cache[buf] = nil
    return apply_winbar(win)
  end
  require("fox-symdeps.clangd").layout(ctx, function(data, state)
    if state == "ok" and data and data.size then
      cache[buf] = { symbol = ctx.symbol, size = data.size }
    elseif state == "ok" and data and data.is_template then
      cache[buf] = { symbol = ctx.symbol, is_template = true }
    else
      cache[buf] = nil
    end
    if vim.api.nvim_win_is_valid(win) then apply_winbar(win) end
  end)
end

-- public pull: the current window's chip string, for a statusline/lualine component. Synchronous —
-- returns the cached value (never blocks redraw); the CursorHold refresh keeps it fresh.
function M.status()
  return M.format(cache[vim.api.nvim_get_current_buf()])
end

function M.toggle()
  M.enabled = not M.enabled
  if M.enabled then
    aug = vim.api.nvim_create_augroup("FoxSymdepsStatus", { clear = true })
    vim.api.nvim_create_autocmd({ "CursorHold", "CursorHoldI" }, { group = aug, callback = refresh })
    vim.api.nvim_create_autocmd({ "WinEnter", "BufEnter" }, {
      group = aug, callback = function() apply_winbar(vim.api.nvim_get_current_win()) end,
    })
    refresh()
  else
    if aug then pcall(vim.api.nvim_del_augroup_by_id, aug); aug = nil end
    for _, w in ipairs(vim.api.nvim_list_wins()) do
      if vim.api.nvim_win_is_valid(w) and is_cpp(vim.api.nvim_win_get_buf(w)) then
        pcall(function() vim.wo[w].winbar = "" end)
      end
    end
    cache = {}
  end
  vim.notify("fox-symdeps · status chip " .. (M.enabled and "ON (winbar)" or "off"), vim.log.levels.INFO)
end

return M
