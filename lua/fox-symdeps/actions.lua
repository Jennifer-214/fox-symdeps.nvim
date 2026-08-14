-- actions.lua — the context-aware action registry behind the palette (:FoxSymdepsMenu / <leader>dm).
--
-- Each row declares WHICH unit types it applies to; the palette resolves the tag [TYPE] from the
-- cursor's enclosing block (tagcontext) and shows only the matching actions. Add a capability =
-- add ONE row — X-macro-registry-shaped, the codebase's own framework discipline applied to the UX.
-- The tag system does the hard part (which unit · what type); this is a thin router to the ops that
-- already exist as the <leader>d* functions.
local M = {}

local function pal() return require("fox-symdeps").config.palette end

-- bless flows open in a terminal split that CLOSES ITSELF when the process exits (operator
-- QOL 2026-08-14: type the confirmation, the window goes away — no manual ctrl-c/:q after).
local function bless_term(cmd)
  vim.cmd("botright 20split | terminal " .. cmd)
  local buf = vim.api.nvim_get_current_buf()
  local win = vim.api.nvim_get_current_win()
  vim.api.nvim_create_autocmd("TermClose", {
    buffer = buf, once = true,
    callback = function()
      vim.schedule(function() pcall(vim.api.nvim_win_close, win, true) end)
    end,
  })
  vim.cmd("startinsert")
end

-- `all = true` → every unit type. Else `types = { ["function"]=true, struct=true, … }` — the
-- LOWERCASED tag type ("function"/"struct"/"registry"/"file"). ("function" is a keyword → bracket key.)
M.registry = {
  -- universal — any unit. Every row carries an `id`: the keymap registry's `action_id` links a
  -- bind to its row and the menu DERIVES the "(<leader>dX)" suffix — the bind string lives only
  -- in the keymap registry (operator ask 2026-08-13: every option shows its key).
  { id = "hud", label = "Symbol HUD — layout · uses · calls · trace", all = true,
    run = function() require("fox-symdeps").inspect_cursor() end },
  { id = "board-add", label = "Board — ADD this unit's card (accumulates; s in-board compares)", all = true,
    run = function() require("fox-symdeps.panel").add(pal()) end },
  { id = "follow", label = "Follow card — auto-follows the enclosing unit", all = true,
    run = function() require("fox-symdeps.followcard").toggle(pal()) end },
  { id = "board-compare", label = "Board — compare two cards side-by-side", all = true,
    when = function()
      local ok, pnl = pcall(require, "fox-symdeps.panel")
      return ok and pnl.is_open() and pnl._count() >= 2
    end,
    run = function() require("fox-symdeps.panel").compare() end },
  { id = "derived-preview", label = "Preview derived facts", all = true,
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
  { id = "docs", label = "Docs — [REFERENCE] → open the defining doc (float beside code)", all = true,
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
  { id = "tag-add", label = "Add [TAG] — browse the vocab, merge into this unit", all = true,
    writes = "comments",   -- ✎ tier: a tag-comment merge; the picker DERIVES from the vocab (§9)
    when = function(ctx)
      local ok, tc = pcall(require, "fox-symdeps.tagcontext")
      if not ok then return false end
      local buf = (ctx and ctx.bufnr) or vim.api.nvim_get_current_buf()
      local row0 = (ctx and ctx.line and (ctx.line - 1)) or (vim.api.nvim_win_get_cursor(0)[1] - 1)
      return tc.enclosing_block(buf, row0) ~= nil
    end,
    run = function(ctx) require("fox-symdeps.tagadd").add(ctx) end },
  -- function
  { id = "derived-write", label = "Write [DERIVED] call-graph in place (+ save)", types = { ["function"] = true, struct = true },
    writes = "comments", -- T6: tag-comments only, never logic — the ✎ tier
    run = function() vim.cmd("FoxSymdepsDerived!") end },
  { id = "asm-explorer", label = "Source ↔ ASM explorer", types = { ["function"] = true },
    run = function() require("fox-symdeps.asmexplorer").open(pal()) end },
  { id = "asm-shipped", label = "SHIPPED asm — this function in the ACTUAL binary (1:1 sidecar)", types = { ["function"] = true },
    run = function() require("fox-symdeps.asmshipped").open(pal()) end },
  { id = "branch-tags", label = "Branch tags (data-dependent ▲)", types = { ["function"] = true },
    run = function() require("fox-symdeps.branchtag").toggle() end },
  -- struct
  { id = "diagnostics", label = "Cache-straddle diagnostics", types = { struct = true },
    run = function() require("fox-symdeps.diagnostics").toggle() end },
  { id = "ambient", label = "Ambient layout lens (inline size)", types = { struct = true },
    run = function() require("fox-symdeps.ambient").toggle() end },
  { id = "lock-layout", label = "Lock layout — insert static_assert(sizeof/alignof)", types = { struct = true },
    writes = "code", -- inserts a SOURCE line (the one sanctioned code-writer) — the ⚠ tier
    run = function() require("fox-symdeps.assertion").insert() end },
  { id = "regfit", label = "Register-fit — per-field access cost (single-mov vs shift/mask)", types = { struct = true },
    run = function() require("fox-symdeps.regfit").open(pal()) end },
  { id = "output-log", label = "Output log — every notification, newest first", all = true,
    run = function() require("fox-symdeps.ui").output() end },
  -- bless flows, IN-EDITOR (operator ask 2026-08-14): nvim's :terminal is a REAL pty, so
  -- bless.py's isatty human-check passes and the D-394 control (diff + typed confirmation)
  -- runs intact inside the editor — the control is anti-AGENT, not anti-convenience. These
  -- never write anything themselves; the terminal flow does, with the operator confirming.
  { id = "bless-latency", label = "Bless — latency budgets (terminal: diff + typed confirm)", all = true,
    run = function() bless_term("python3 tools/check_latency_path_conformance.py --update-budgets") end },
  { id = "bless-golden", label = "Bless — goldens console (terminal: bless.py --console)", all = true,
    run = function() bless_term("python3 tools/bless.py --console") end },
}

-- pure: the display label with its derived bind suffix — `bind` (launcher rows carry theirs
-- directly) or the keymap registry's action_id→lhs map. No bind → label unchanged.
function M._bind_suffix(a, binds)
  local b = a.bind or (a.id and binds and binds[a.id])
  return b and (a.label .. "  (" .. b .. ")") or a.label
end

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
      require("fox-symdeps.ui").notify_raw("fox-symdeps · " .. msg,
                 lvl == "warn" and vim.log.levels.WARN or vim.log.levels.INFO)
    end,
    set_section = function(_, _, header)
      require("fox-symdeps.ui").notify_raw("fox-symdeps · " .. tostring(header)
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
        require("fox-symdeps.ui").notify_raw(("fox-symdeps · actions row %q gates on unknown unit type %q")
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
  local okf, fox = pcall(require, "fox-symdeps")
  local binds = (okf and fox.action_binds and fox.action_binds()) or {}
  local rows = {}
  for _, a in ipairs(acts) do
    -- the bind suffix is DERIVED here (one site, keymap-registry-sourced) so every row shows
    -- its key the same way — the wrapper's own label wins over __index passthrough.
    rows[#rows + 1] = setmetatable({ run = function() M.run(a, ctx) end, label = M._bind_suffix(a, binds) },
                                   { __index = a })
  end
  return rows
end

return M
