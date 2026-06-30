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
      if P.edit_timer then pcall(function() P.edit_timer:stop(); P.edit_timer:close() end); P.edit_timer = nil end
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

  -- live-edit: debounced (~1.5s ≈ clangd's re-analysis latency) re-fetch of the tracked symbol's
  -- LAYOUT when a code buffer changes, so size / cache-density / straddle recompute as you edit
  -- (consumers left intact — an in-struct edit doesn't change who uses it)
  vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI" }, {
    group = P.aug,
    callback = function()
      if not P.hud or P.hud.closed then return end
      if vim.api.nvim_get_current_win() == P.hud.win then return end
      if P.edit_timer then P.edit_timer:stop(); P.edit_timer:close() end
      P.edit_timer = vim.uv.new_timer()
      P.edit_timer:start(1500, 0, vim.schedule_wrap(function()
        if P.edit_timer then P.edit_timer:stop(); P.edit_timer:close(); P.edit_timer = nil end
        if P.hud and not P.hud.closed then
          require("fox-symdeps").refresh_layout(P.hud.ctx, P.hud)
        end
      end))
    end,
  })

  -- close the panel when it would be the last window (so :q can quit nvim), and clean up if the
  -- panel window itself is closed directly (e.g. :q! inside it)
  vim.api.nvim_create_autocmd("WinClosed", {
    group = P.aug,
    callback = function()
      vim.schedule(function()
        if not P.hud then return end
        if not vim.api.nvim_win_is_valid(P.hud.win) then return M.close() end
        local others = 0
        for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
          if vim.api.nvim_win_is_valid(w) and w ~= P.hud.win then others = others + 1 end
        end
        if others == 0 then M.close() end
      end)
    end,
  })
end

return M
