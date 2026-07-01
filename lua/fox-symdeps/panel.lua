-- Persistent side panel with a TAB BAR. Follows the cursor as before (swaps to the symbol under
-- it), and remembers the distinct symbols it has shown as tabs. H / L flip back through them (which
-- pauses follow so it doesn't yank you away); p resumes following; x drops a tab; q closes. Reuses
-- the float's render + the shared M.inspect fetch; switching re-fetches (clangd is fast).
local M = {}
local P = { hud = nil, pinned = false, aug = nil, palette = {}, hist = {}, idx = 0 }
local HIST_CAP = 8

-- pure: push ctx into `hist` (dedupe by symbol, most-recent-last, capped). Returns the new index.
function M._remember(hist, ctx, cap)
  for i, c in ipairs(hist) do
    if c.symbol == ctx.symbol then table.remove(hist, i); break end
  end
  hist[#hist + 1] = ctx
  while #hist > cap do table.remove(hist, 1) end
  return #hist
end

-- pure: 1-based index after stepping `delta`, wrapping over `n` (0 if empty).
function M._wrap(idx, delta, n)
  if n == 0 then return 0 end
  return ((idx - 1 + delta) % n) + 1
end

local function ctx_under_cursor() return require("fox-symdeps.context").under_cursor() end

local function set_tabbar()
  if not (P.hud and P.hud.win and vim.api.nvim_win_is_valid(P.hud.win)) then return end
  local parts = {}
  for i, c in ipairs(P.hist) do
    if i == P.idx then
      parts[#parts + 1] = "%#FoxSymdepsTitle#‹" .. c.symbol .. (P.pinned and " ⏸" or "") .. "›%*"
    else
      parts[#parts + 1] = "%#FoxSymdepsBadge# " .. c.symbol .. " %*"
    end
  end
  vim.wo[P.hud.win].winbar = table.concat(parts, "%#FoxSymdepsBadge#│%*")
end

local function show(ctx) -- swap the panel to ctx: reset + re-fetch + redraw the tab bar
  P.hud:reset(ctx)
  require("fox-symdeps").inspect(ctx, P.hud)
  set_tabbar()
end

function M.close() if P.hud then P.hud:close() end end

function M.switch(delta)
  if not (P.hud and not P.hud.closed) or #P.hist == 0 then return end
  P.idx = M._wrap(P.idx, delta, #P.hist)
  P.pinned = true -- flipping the tab bar pauses cursor-follow; 'p' resumes
  show(P.hist[P.idx])
end

function M.close_tab()
  if #P.hist <= 1 then return M.close() end
  table.remove(P.hist, P.idx)
  if P.idx > #P.hist then P.idx = #P.hist end
  show(P.hist[P.idx])
end

function M.pin()
  if not (P.hud and P.hud.win and vim.api.nvim_win_is_valid(P.hud.win)) then return end
  P.pinned = not P.pinned
  set_tabbar()
  vim.notify("fox-symdeps panel " .. (P.pinned and "pinned (H/L to flip · p to follow)" or "following cursor"),
    vim.log.levels.INFO)
end

function M.toggle(palette)
  P.palette = palette or P.palette
  if P.hud and not P.hud.closed then return M.close() end
  local ctx = ctx_under_cursor()
  if not ctx then return vim.notify("fox-symdeps · put the cursor on a symbol to track", vim.log.levels.INFO) end
  local origin = vim.api.nvim_get_current_win()
  P.pinned = false
  P.hist, P.idx = {}, 0
  P.hud = require("fox-symdeps.hud").open(ctx, P.palette, {
    mode = "panel",
    on_close = function()
      if P.aug then pcall(vim.api.nvim_del_augroup_by_id, P.aug); P.aug = nil end
      if P.edit_timer then pcall(function() P.edit_timer:stop(); P.edit_timer:close() end); P.edit_timer = nil end
      P.hud = nil; P.pinned = false; P.hist, P.idx = {}, 0
    end,
  })
  for _, k in ipairs({
    { "p", M.pin }, { "L", function() M.switch(1) end }, { "H", function() M.switch(-1) end },
    { "x", M.close_tab },
  }) do
    vim.keymap.set("n", k[1], k[2], { buffer = P.hud.buf, nowait = true, silent = true })
  end
  P.idx = M._remember(P.hist, ctx, HIST_CAP)
  require("fox-symdeps").inspect(ctx, P.hud)
  set_tabbar()
  if vim.api.nvim_win_is_valid(origin) then vim.api.nvim_set_current_win(origin) end

  P.aug = vim.api.nvim_create_augroup("FoxSymdepsPanel", { clear = true })
  -- follow the cursor: re-resolve the symbol under it (unless paused) + remember it as a tab
  vim.api.nvim_create_autocmd("CursorHold", {
    group = P.aug,
    callback = function()
      if not P.hud or P.hud.closed or P.pinned then return end
      if vim.api.nvim_get_current_win() == P.hud.win then return end
      local c = ctx_under_cursor()
      if c and c.symbol ~= P.hud.ctx.symbol then
        P.idx = M._remember(P.hist, c, HIST_CAP)
        show(c)
      end
    end,
  })
  -- live-edit: debounced re-fetch of the tracked symbol's LAYOUT on a code change
  vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI" }, {
    group = P.aug,
    callback = function()
      if not P.hud or P.hud.closed then return end
      if vim.api.nvim_get_current_win() == P.hud.win then return end
      if P.edit_timer then P.edit_timer:stop(); P.edit_timer:close() end
      P.edit_timer = vim.uv.new_timer()
      P.edit_timer:start(1500, 0, vim.schedule_wrap(function()
        if P.edit_timer then P.edit_timer:stop(); P.edit_timer:close(); P.edit_timer = nil end
        if P.hud and not P.hud.closed then require("fox-symdeps").refresh_layout(P.hud.ctx, P.hud) end
      end))
    end,
  })
  -- close the panel when it would be the last window; clean up if closed directly
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
