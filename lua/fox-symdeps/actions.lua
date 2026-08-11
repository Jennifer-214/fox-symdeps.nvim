-- actions.lua — the context-aware action registry behind the palette (:FoxSymdepsMenu / <leader>dm).
--
-- Each row declares WHICH unit types it applies to; the palette resolves the tag [TYPE] from the
-- cursor's enclosing block (tagcontext) and shows only the matching actions. Add a capability =
-- add ONE row — X-macro-registry-shaped, the codebase's own framework discipline applied to the UX.
-- The tag system does the hard part (which unit · what type); this is a thin router to the ops that
-- already exist as the <leader>d* functions.
local M = {}

local function pal() return require("fox-symdeps").config.palette end

-- `all = true` → every unit type. Else `types = { ["function"]=true, struct=true, … }` — the
-- LOWERCASED tag type ("function"/"struct"/"registry"/"file"). ("function" is a keyword → bracket key.)
M.registry = {
  -- universal — any unit
  { label = "Symbol HUD — layout · uses · calls · trace", all = true,
    run = function() require("fox-symdeps").inspect_cursor() end },
  { label = "Board — ADD this unit's card (accumulates; s in-board compares)", all = true,
    run = function() require("fox-symdeps.panel").add(pal()) end },
  { label = "Follow card — auto-follows the enclosing unit", all = true,
    run = function() require("fox-symdeps.followcard").toggle(pal()) end },
  { label = "Board — compare two cards side-by-side", all = true,
    when = function()
      local ok, pnl = pcall(require, "fox-symdeps.panel")
      return ok and pnl.is_open() and pnl._count() >= 2
    end,
    run = function() require("fox-symdeps.panel").compare() end },
  { label = "Preview derived facts", all = true,
    run = function() vim.cmd("FoxSymdepsDerived") end },
  -- Analysis rows (fleet phase 2; dm-EQUAL per the operator's one-registry call — these render
  -- INTO the invoking HUD when one is open [keep_stack], and fall back to verdict NOTIFIES from
  -- dm with a pointer at the full tree; they replaced the lens key-binds that silently
  -- clobbered `m` and board-`s` for months):
  { id = "mutations", label = "Who writes — mutation sites for this field/symbol", all = true,
    keep_stack = true,
    when = function(ctx) return ctx and (ctx.kind == "field" or ctx.kind == "symbol") end,
    run = function(ctx)
      require("fox-symdeps.lenses.mutations").who_writes(ctx, M._hud_or_shim(ctx))
    end },
  { id = "false-sharing", label = "False-sharing scan — disjoint writers on shared 64B lines", all = true,
    keep_stack = true,
    when = function(ctx) return ctx and ctx.kind ~= nil and ctx.kind ~= "function" end,
    run = function(ctx)
      require("fox-symdeps.lenses.false_sharing").analyze(ctx, M._hud_or_shim(ctx))
    end },
  { label = "Docs — [REFERENCE] → open the defining doc (float beside code)", all = true,
    -- context-gated (§6's rule): shown only when the enclosing unit actually carries the
    -- [REFERENCE] axis this affordance renders (§9's law). Takes the EXPLICIT ctx (fleet P2
    -- fix): evaluated from the SOURCE buffer the invoker names — never the current window
    -- (the HUD invokes from its own scratch buffer, where this gate used to scan HUD text).
    when = function(ctx)
      local buf = (ctx and ctx.bufnr) or vim.api.nvim_get_current_buf()
      local row0 = (ctx and ctx.line and (ctx.line - 1))
                   or (vim.api.nvim_win_get_cursor(0)[1] - 1)
      local ok, tc = pcall(require, "fox-symdeps.tagcontext")
      if not ok then return false end
      local blk = tc.enclosing_block(buf, row0)
      if blk then
        for _, l in ipairs(vim.api.nvim_buf_get_lines(buf, blk.opener, blk.closer + 1, false)) do
          if l:find("[REFERENCE]_", 1, true) then return true end
        end
      end
      -- FILE-header fallback (macros / file-scope / units without refs)
      local okd, dv = pcall(require, "fox-symdeps.docview")
      return okd and #dv.file_header_ids(buf) > 0
    end,
    run = function() require("fox-symdeps.docview").open() end },
  -- function
  { label = "Write [DERIVED] call-graph in place (+ save)", types = { ["function"] = true, struct = true },
    writes = "comments", -- T6: tag-comments only, never logic — the ✎ tier
    run = function() vim.cmd("FoxSymdepsDerived!") end },
  { label = "Source ↔ ASM explorer", types = { ["function"] = true },
    run = function() require("fox-symdeps.asmexplorer").open(pal()) end },
  { label = "Branch tags (data-dependent ▲)", types = { ["function"] = true },
    run = function() require("fox-symdeps.branchtag").toggle() end },
  -- struct
  { label = "Cache-straddle diagnostics", types = { struct = true },
    run = function() require("fox-symdeps.diagnostics").toggle() end },
  { label = "Ambient layout lens (inline size)", types = { struct = true },
    run = function() require("fox-symdeps.ambient").toggle() end },
  { label = "Lock layout — insert static_assert(sizeof/alignof)", types = { struct = true },
    writes = "code", -- inserts a SOURCE line (the one sanctioned code-writer) — the ⚠ tier
    run = function() require("fox-symdeps.assertion").insert() end },
}

-- filter the registry for a lowercased tag type; "" (not in a block) → the universal actions only.
-- An optional per-item `when(ctx)` gate adds RUNTIME context-gating (§6: "the menu shows only
-- what's valid") — evaluated against the EXPLICIT invoker ctx (fleet P2: the HUD invokes from
-- its scratch buffer, so implicit current-window gates lied there). pcall-safe: a broken gate
-- hides its item rather than breaking the menu.
-- dm has no HUD open — the analysis rows still run there (one registry, EVERY invoker equal;
-- operator call 2026-08-10): verdict headlines surface via notify; the jumpable section tree
-- needs a HUD, and the shim SAYS so instead of silently dropping it.
function M._hud_or_shim(ctx)
  if ctx and ctx.hud then return ctx.hud end
  return {
    set_message = function(_, msg, lvl)
      vim.notify("fox-symdeps · " .. msg,
                 lvl == "warn" and vim.log.levels.WARN or vim.log.levels.INFO)
    end,
    set_section = function(_, _, header)
      vim.notify("fox-symdeps · " .. tostring(header)
                 .. "  (open the HUD — <leader>dd — for the jumpable tree)", vim.log.levels.INFO)
    end,
  }
end

-- One-time registration validation (fleet K3): every `types` key must be a REAL unit type
-- from the grammar payload — an unknown key can never match, so it warns (dev-time) instead
-- of silently gating a row out of existence. Runs at the first for_type once the model is up.
local types_validated = false
local function validate_types()
  if types_validated then return end
  local ok, nmod = pcall(require, "fox-symdeps.nodemodel")
  local known = ok and nmod.unit_types and nmod.unit_types() or nil
  if not known then return end          -- model not up yet; re-check on a later call
  types_validated = true
  for _, a in ipairs(M.registry) do
    for t in pairs(a.types or {}) do
      if not known[t] then
        vim.notify(("fox-symdeps · actions row %q gates on unknown unit type %q")
                   :format(a.id or a.label, t), vim.log.levels.WARN)
      end
    end
  end
end

function M.for_type(t, ctx)
  validate_types()
  local out = {}
  for _, a in ipairs(M.registry) do
    if a.all or (a.types and a.types[t]) then
      local visible = true
      if a.when then
        local ok, v = pcall(a.when, ctx)
        visible = ok and v or false
      end
      if visible then out[#out + 1] = a end
    end
  end
  -- MENU-AS-ROOT (operator rule): the global launchers ride every menu, DERIVED from the
  -- keymap registry — the menu always has EVERY option that is valid here.
  local okl, fox = pcall(require, "fox-symdeps")
  if okl and fox.menu_launchers then
    for _, r in ipairs(fox.menu_launchers()) do out[#out + 1] = r end
  end
  return out
end

-- Central runner (fleet P1): restore the SOURCE window/cursor from the explicit ctx — the dance
-- the HUD wrapper used to hand-roll by RE-SHAPING rows (which dropped `writes` and every future
-- field; moving it here makes re-shaped copies structurally unnecessary) — then apply the
-- operator's LAYER-STACK rule (2026-08-10: "opened item > menu > HUD; when the top level item
-- opens, it closes the other 2"): ctx.collapse is the invoker's ancestor-close chain, called
-- before the action opens its own surface.
function M.run(row, ctx)
  ctx = ctx or {}
  if ctx.bufnr then
    local w = vim.fn.bufwinid(ctx.bufnr)
    if w ~= -1 then
      pcall(vim.api.nvim_set_current_win, w)
      if ctx.line then pcall(vim.api.nvim_win_set_cursor, w, { ctx.line, ctx.col or 0 }) end
    end
  end
  if ctx.collapse and not row.keep_stack then pcall(ctx.collapse) end
  row.run(ctx)
end

-- Wrap registry rows for menu.open WITHOUT re-shaping them: run routes through M.run(ctx);
-- every other field (label, writes, …) reads through to the registry row via __index, so the
-- renderer sees the SAME item shape from every invoker — identical popups by construction.
function M.menu_rows(acts, ctx)
  local rows = {}
  for _, a in ipairs(acts) do
    rows[#rows + 1] = setmetatable({ run = function() M.run(a, ctx) end }, { __index = a })
  end
  return rows
end

return M
