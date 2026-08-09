-- Persistent side panel — the ACCUMULATE BOARD (north-star §6 role-swap, 2026-08-09).
-- EXPLICIT-add, multi-card: <leader>dD ADDS the unit at the cursor as a card (opening the board
-- if closed); it NEVER auto-rotates onto whatever the cursor touches and NEVER closes-on-reuse —
-- §6 names both as design bugs against the model ("the panel must accumulate, not replace").
-- Cursor-FOLLOWING is the follow card's job (followcard.lua, the §6 HUD role; cockpit docks that).
-- Flip cards: H/L in-panel or <leader>d[ / d] anywhere; x drops a card; q closes the board.
-- Winbar: symbol · idx/total · ⊞ board. Re-adding a symbol RE-SELECTS its card (dedupe, no dup tab).
-- Reuses the float's render + the shared M.inspect fetch; switching re-fetches (clangd is fast).
local M = {}
local P = { hud = nil, aug = nil, palette = {}, cards = {}, idx = 0 }
local CARD_CAP = 8

-- pure: push ctx into `cards` (dedupe by symbol, most-recent-last, capped). Returns the new index.
function M._remember(cards, ctx, cap)
  for i, c in ipairs(cards) do
    if c.symbol == ctx.symbol then table.remove(cards, i); break end
  end
  cards[#cards + 1] = ctx
  while #cards > cap do table.remove(cards, 1) end
  return #cards
end

-- pure: 1-based index after stepping `delta`, wrapping over `n` (0 if empty).
function M._wrap(idx, delta, n)
  if n == 0 then return 0 end
  return ((idx - 1 + delta) % n) + 1
end

function M._count() return #P.cards end -- test seam
function M._visible() return P.hud and P.hud.ctx and P.hud.ctx.symbol end -- test seam

-- Cursor-ANYWHERE resolution (same stack as the HUD entry): on-symbol fast path, else the
-- enclosing unit's declared symbol. The board should add the unit you are IN, not demand the
-- cursor sit on its name.
local function ctx_at_cursor() return require("fox-symdeps.tagcontext").resolve_unit() end

local function set_tabbar()
  if not (P.hud and P.hud.win and vim.api.nvim_win_is_valid(P.hud.win)) then return end
  local cur = P.cards[P.idx]
  local sym = cur and cur.symbol or "?"
  local pos = #P.cards > 1 and ("%%#FoxSymdepsBadge# · %d/%d%%*"):format(P.idx, #P.cards) or ""
  vim.wo[P.hud.win].winbar = ("%%#FoxSymdepsTitle# %s %%*%s%%#FoxSymdepsBadge#  ⊞ board%%*"):format(sym, pos)
end

local function show(ctx) -- swap the visible card: reset + re-fetch + redraw the tab bar
  P.hud:reset(ctx)
  require("fox-symdeps").inspect(ctx, P.hud)
  set_tabbar()
end

function M.close() if P.hud then P.hud:close() end end

function M.is_open() return P.hud ~= nil and not P.hud.closed end

function M.switch(delta)
  if not M.is_open() or #P.cards == 0 then return end
  P.idx = M._wrap(P.idx, delta, #P.cards)
  show(P.cards[P.idx])
end

function M.close_tab()
  if #P.cards <= 1 then return M.close() end
  table.remove(P.cards, P.idx)
  if P.idx > #P.cards then P.idx = #P.cards end
  show(P.cards[P.idx])
end

-- ADD the unit at the cursor as a card (§6's <leader>dD). Opens the board if closed; on an
-- already-carded symbol it re-selects that card. NEVER closes — q / :q close the board.
function M.add(palette)
  P.palette = palette or P.palette
  local ctx = ctx_at_cursor()
  if not ctx then
    if not require("fox-symdeps.nodemodel").available() then
      return require("fox-symdeps.nodemodel").heal(function() M.add(P.palette) end)
    end
    return vim.notify("fox-symdeps · put the cursor in a tagged unit (or on a symbol) to add its card",
      vim.log.levels.INFO)
  end

  if M.is_open() then
    P.idx = M._remember(P.cards, ctx, CARD_CAP)
    show(P.cards[P.idx])
    return
  end

  local hud = require("fox-symdeps.hud")
  local origin = vim.api.nvim_get_current_win()
  P.cards, P.idx = {}, 0
  P.hud = hud.open(ctx, P.palette, {
    mode = "panel",
    on_close = function()
      if P.aug then pcall(vim.api.nvim_del_augroup_by_id, P.aug); P.aug = nil end
      if P.hud and P.hud.edit_timer then pcall(function() P.hud.edit_timer:stop(); P.hud.edit_timer:close() end) end
      if P.hud and P.hud._detach_autoread then P.hud._detach_autoread() end
      P.hud = nil; P.cards, P.idx = {}, 0
    end,
  })
  for _, k in ipairs({
    { "L", function() M.switch(1) end }, { "H", function() M.switch(-1) end },
    { "x", M.close_tab },
  }) do
    vim.keymap.set("n", k[1], k[2], { buffer = P.hud.buf, nowait = true, silent = true })
  end
  P.idx = M._remember(P.cards, ctx, CARD_CAP)
  require("fox-symdeps").inspect(ctx, P.hud)
  set_tabbar()
  if vim.api.nvim_win_is_valid(origin) then vim.api.nvim_set_current_win(origin) end

  P.aug = vim.api.nvim_create_augroup("FoxSymdepsPanel", { clear = true })
  hud.attach_live_refresh(P.hud, P.aug)      -- debounced layout re-fetch of the VISIBLE card
  hud.attach_external_reload(P.hud, P.aug)   -- co-programming: disk edits re-inspect + cascade
  hud.attach_last_window_guard(P.hud, P.aug, M.close)
end

-- Back-compat shim: cockpit + old muscle memory called toggle(). The board's verb is ADD —
-- close-on-reuse was the §6 design bug, so toggle no longer closes. q closes.
function M.toggle(palette) return M.add(palette) end

return M
