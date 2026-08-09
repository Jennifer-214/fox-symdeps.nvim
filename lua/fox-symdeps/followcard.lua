-- followcard.lua — the FOLLOW CARD (north-star §6's HUD role: transient, SINGLE card,
-- AUTO-FOLLOWS the cursor). The role-swap counterpart of panel.lua's accumulate board: the old
-- panel's cursor-follow lived on raw word-under-cursor CursorHold and swapped out from under you
-- on every local/keyword; this follows the ENCLOSING UNIT via tagcursor's debounced
-- `User FoxUnitChanged` event — it moves only when you actually change units, which is the §6
-- "quick check / nav lens" semantics. Cockpit docks THIS ("follows your cursor, analysis simply
-- THERE"), not the board. <leader>df toggles; q closes.
local M = {}
local S = { hud = nil, aug = nil, palette = {} }

function M.is_open() return S.hud ~= nil and not S.hud.closed end

function M.win() return M.is_open() and S.hud.win or nil end

function M._symbol() return S.hud and S.hud.ctx and S.hud.ctx.symbol end -- test seam

function M.close() if S.hud then S.hud:close() end end

local function set_bar()
  if not (S.hud and S.hud.win and vim.api.nvim_win_is_valid(S.hud.win)) then return end
  local sym = S.hud.ctx and S.hud.ctx.symbol or "?"
  vim.wo[S.hud.win].winbar = ("%%#FoxSymdepsTitle# %s %%*%%#FoxSymdepsBadge#  ↻ following%%*"):format(sym)
end

local function show(ctx)
  S.hud:reset(ctx)
  require("fox-symdeps").inspect(ctx, S.hud)
  set_bar()
end

function M.toggle(palette)
  S.palette = palette or S.palette
  if M.is_open() then return M.close() end
  local tc = require("fox-symdeps.tagcontext")
  local ctx = tc.resolve_unit()
  if not ctx then
    if not require("fox-symdeps.nodemodel").available() then
      return require("fox-symdeps.nodemodel").heal(function() M.toggle(S.palette) end)
    end
    return vim.notify("fox-symdeps · put the cursor in a tagged unit (or on a symbol) to follow",
      vim.log.levels.INFO)
  end

  local hud = require("fox-symdeps.hud")
  local origin = vim.api.nvim_get_current_win()
  S.hud = hud.open(ctx, S.palette, {
    mode = "panel",
    on_close = function()
      if S.aug then pcall(vim.api.nvim_del_augroup_by_id, S.aug); S.aug = nil end
      if S.hud and S.hud.edit_timer then pcall(function() S.hud.edit_timer:stop(); S.hud.edit_timer:close() end) end
      if S.hud and S.hud._detach_autoread then S.hud._detach_autoread() end
      S.hud = nil
    end,
  })
  require("fox-symdeps").inspect(ctx, S.hud)
  set_bar()
  if vim.api.nvim_win_is_valid(origin) then vim.api.nvim_set_current_win(origin) end

  S.aug = vim.api.nvim_create_augroup("FoxSymdepsFollowCard", { clear = true })
  -- THE follow: tagcursor already debounces cursor motion and fires only on unit TRANSITIONS,
  -- so this handler is rare + cheap. Resolve the full ctx at the new position (fast path on-symbol,
  -- else the unit's declared symbol) and swap the card only when the symbol genuinely changed.
  vim.api.nvim_create_autocmd("User", {
    group = S.aug, pattern = "FoxUnitChanged",
    callback = function()
      if not M.is_open() then return end
      if vim.api.nvim_get_current_win() == S.hud.win then return end
      local c = tc.resolve_unit()
      if c and S.hud.ctx and c.symbol ~= S.hud.ctx.symbol then show(c) end
    end,
  })
  hud.attach_live_refresh(S.hud, S.aug)     -- "watch it shrink" on the followed unit
  hud.attach_external_reload(S.hud, S.aug)  -- co-programming reload + cascade
  hud.attach_last_window_guard(S.hud, S.aug, M.close)
end

return M
