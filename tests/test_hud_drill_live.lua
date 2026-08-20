-- HUD graph-walk LIVE path: drill (f) re-roots the card on a tree entry's unit, <C-t> pops the
-- trail, L opens the entry's unit as a board card — through real windows, real buffers, and the
-- real code-window excursion (target resolution must restore the operator's buffer + view
-- exactly). Node model injected (no foxtag binary needed); treesitter cpp required (run.sh adds
-- the site dir). Lives under the 2026-08-18 rule: no plugin feature is done without its live
-- path exercised.  Run:  bash tests/run.sh  (or standalone with the site rtp added)
package.path = "./lua/?.lua;./lua/?/init.lua;" .. package.path -- ?/init.lua: _drill requires the ROOT module
local nm = require("fox-symdeps.nodemodel")
local TC = require("fox-symdeps.tagcontext")
local hud = require("fox-symdeps.hud")
local panel = require("fox-symdeps.panel")

local pass, fail = 0, 0
local function ok(c, m) if c then pass = pass + 1 else fail = fail + 1; io.write("  ✗ " .. m .. "\n") end end

vim.o.hidden = true
nm._inject({
  closable = { ASSERT = false, ENUM = true, FILE = false, FUNCTION = true, MACRO = false,
               REGISTRY = true, STRATEGY = true, STRUCT = true, TEST = false, TYPE = true },
  openers  = { ENUM = true, FUNCTION = true, REGISTRY = true, STRATEGY = true, STRUCT = true, TYPE = true },
  meta = { count = 10 },
})

-- two tagged units in two files; Beta is the drill target Alpha's tree points at
local root = vim.fn.tempname()
vim.fn.mkdir(root, "p")
local alpha = root .. "/alpha.hpp"
local beta = root .. "/beta.hpp"
vim.fn.writefile({
  "// [FUNCTION]_[AlphaFn]",
  "// [CODE]",
  "inline int AlphaFn(int x) {",
  "  return x + 1;",
  "}",
  "// [END_CODE]",
  "// [END_FUNCTION]",
}, alpha)
vim.fn.writefile({
  "// [FUNCTION]_[BetaFn]",
  "// [CODE]",
  "inline int BetaFn(int y) {",
  "  return y * 2;",
  "}",
  "// [END_CODE]",
  "// [END_FUNCTION]",
}, beta)

vim.cmd("edit " .. vim.fn.fnameescape(alpha))
vim.bo[0].filetype = "cpp"
pcall(vim.api.nvim_win_set_cursor, 0, { 4, 4 }) -- inside AlphaFn's body
local code_win = vim.api.nvim_get_current_win()
local ctx = TC.resolve_unit()
ok(ctx ~= nil and ctx.symbol == "AlphaFn", "fixture resolves: cursor-in-body → AlphaFn ctx")
if not ctx then io.write("test_hud_drill_live: aborted — fixture ctx unresolvable\n"); os.exit(1) end

local h = hud.open(ctx, {}, {})
ok(h ~= nil and not h.closed, "LIVE: HUD opens on AlphaFn")

-- inject a consumers tree whose one leaf points INSIDE BetaFn (line 4)
local function inject_tree()
  h:set_consumers({ { label = "Consumers", count = 1, collapsed = false, files = {
    { file = beta, count = 1, collapsed = false, entries = { { line = 4 } } },
  } } }, "ok")
end
inject_tree()
local function select_leaf()
  for i, it in ipairs(h.items or {}) do
    if it.kind == "entry" and it.loc then h.sel = i; return true end
  end
  return false
end
-- sections open FOLDED by design (§6 collapsed-by-default) — expand them the way a user
-- would (<CR> on the section header) until the leaf row exists
local function expand_until_leaf()
  for _ = 1, 6 do
    if select_leaf() then return true end
    local flipped = false
    for i, it in ipairs(h.items or {}) do
      if it.kind == "section" and it.node and h:_sec_collapsed(it.node.sec) then
        h.sel = i; h:_activate(); flipped = true; break
      end
    end
    if not flipped then return select_leaf() end
  end
  return select_leaf()
end
ok(expand_until_leaf(), "LIVE: the injected tree renders a jumpable leaf row (after unfolding)")

-- ① drill: re-roots on BetaFn, pushes the trail, and the code window is UNDISTURBED
h:_drill()
ok(h.ctx and h.ctx.symbol == "BetaFn", "LIVE drill: card re-rooted on the entry's unit (BetaFn)")
ok(h.trail and #h.trail == 1 and h.trail[1].symbol == "AlphaFn", "LIVE drill: trail carries AlphaFn")
ok(vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(code_win)) == alpha,
  "LIVE drill: the code window still shows alpha.hpp (excursion restored)")
local title = ""
local okc, cfg = pcall(vim.api.nvim_win_get_config, h.win)
if okc and type(cfg.title) == "table" then
  for _, part in ipairs(cfg.title) do title = title .. (part[1] or "") end
end
ok(title:find("AlphaFn ▸ BetaFn", 1, true) ~= nil, "LIVE drill: the float title is the breadcrumb")

-- ② back: pops to AlphaFn, trail empty
h:_back()
ok(h.ctx and h.ctx.symbol == "AlphaFn" and #h.trail == 0, "LIVE back: trail pops to AlphaFn")
h:_back() -- empty trail must be a calm no-op
ok(h.ctx.symbol == "AlphaFn", "LIVE back: empty trail is a no-op, never an error")

-- ③ open-beside: the entry's unit joins the BOARD; focus returns to the code window
inject_tree() -- reset() cleared the injected tree on back — re-arm and re-select
ok(expand_until_leaf(), "LIVE: tree re-injected after back")
h:_open_beside()
ok(panel.is_open() and panel._visible() == "BetaFn", "LIVE open-beside: BetaFn joined the board")
ok(vim.api.nvim_get_current_win() == code_win, "LIVE open-beside: focus returned to the code window")

panel.close()
io.write(("test_hud_drill_live: %d passed, %d failed\n"):format(pass, fail))
os.exit(fail == 0 and 0 or 1)
