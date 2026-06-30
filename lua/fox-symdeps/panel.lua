-- Persistent side panel: pin a symbol and watch its full classified consumption tree.
-- Reuses the float's render + the shared M.inspect fetch. Tracks the cursor (re-resolving the
-- symbol under it) until you pin, so the panel persists as a management cockpit for one struct
-- no matter which files you jump to and from.
local M = {}
local P = { hud = nil, pinned = false, aug = nil, palette = {} }

local function ctx_under_cursor()
  return require("fox-symdeps.context").under_cursor()
end

function M.close()
  if P.hud then P.hud:close() end -- on_close (set in toggle) clears P.aug / P.hud / P.pinned
end

function M.pin()
  if not (P.hud and P.hud.win and vim.api.nvim_win_is_valid(P.hud.win)) then return end
  P.pinned = not P.pinned
  vim.wo[P.hud.win].winbar =
    "%#FoxSymdepsTitle# " .. P.hud.ctx.symbol .. (P.pinned and "  [pinned]" or "") .. " %*"
  vim.notify("fox-symdeps panel " .. (P.pinned and ("pinned to " .. P.hud.ctx.symbol) or "tracking cursor"),
    vim.log.levels.INFO)
end

function M.toggle(palette)
  P.palette = palette or P.palette
  if P.hud and not P.hud.closed then
    M.close()
    return
  end
  local ctx = ctx_under_cursor()
  if not ctx then
    return vim.notify("fox-symdeps · put the cursor on a symbol to track", vim.log.levels.INFO)
  end
  local origin = vim.api.nvim_get_current_win()
  P.pinned = false
  P.hud = require("fox-symdeps.hud").open(ctx, P.palette, {
    mode = "panel",
    on_close = function()
      if P.aug then pcall(vim.api.nvim_del_augroup_by_id, P.aug); P.aug = nil end
      P.hud = nil
      P.pinned = false
    end,
  })
  vim.keymap.set("n", "p", function() M.pin() end, { buffer = P.hud.buf, nowait = true, silent = true })
  require("fox-symdeps").inspect(ctx, P.hud)
  if vim.api.nvim_win_is_valid(origin) then vim.api.nvim_set_current_win(origin) end

  -- track the cursor: re-resolve the symbol under it (unless pinned) and re-inspect on change
  P.aug = vim.api.nvim_create_augroup("FoxSymdepsPanel", { clear = true })
  vim.api.nvim_create_autocmd("CursorHold", {
    group = P.aug,
    callback = function()
      if not P.hud or P.hud.closed or P.pinned then return end
      if vim.api.nvim_get_current_win() == P.hud.win then return end
      local c = ctx_under_cursor()
      if c and c.symbol ~= P.hud.ctx.symbol then
        P.hud:reset(c)
        require("fox-symdeps").inspect(c, P.hud)
      end
    end,
  })
end

return M
