-- tissue: the compare pair's connective tissue — pure legs (embedding word-boundary + the
-- straddles-INSIDE-parent math + co-includer intersection + line assembly) and a LIVE leg
-- (board → two struct cards → compare → the ⋈ Between section renders on the companion),
-- per the live-path rule. Treesitter cpp needed for the live leg (run.sh adds the site dir).
-- Run:  bash tests/run.sh
package.path = "./lua/?.lua;./lua/?/init.lua;" .. package.path
local T = require("fox-symdeps.tissue")

local pass, fail = 0, 0
local function ok(c, m) if c then pass = pass + 1 else fail = fail + 1; io.write("  ✗ " .. m .. "\n") end end

-- ── embedding: word-boundary on the type string; parent-relative cache-line math ────────────
local fields = {
  { name = "pair", type = "MoneyPair", offset = 0, size = 32 },
  { name = "px", type = "Money", offset = 120, size = 16 },
}
local e = T.embedding(fields, "Money")
ok(e ~= nil and e.name == "px", "embedding: word-boundary — 'Money' never matches 'MoneyPair'")
ok(e.lo == 1 and e.hi == 2 and e.straddle,
  "embedding: @120+16B occupies parent lines L1–L2 → straddles INSIDE the parent")
local e2 = T.embedding({ { name = "q", type = "Money", offset = 64, size = 16 } }, "Money")
ok(e2 and e2.lo == 1 and e2.hi == 1 and not e2.straddle, "embedding: aligned field sits on one parent line")
ok(T.embedding(fields, "Tick") == nil, "embedding: absent type → nil")
ok(T.embedding(nil, "Money") == nil and T.embedding(fields, "") == nil, "embedding: nil/empty inputs are safe")

-- ── co_includers: intersection, dedup, sorted ────────────────────────────────────────────────
local co = T.co_includers(
  { { file = "b.hpp" }, { file = "a.hpp" }, { file = "z.hpp" } },
  { { file = "z.hpp" }, { file = "a.hpp" }, { file = "a.hpp" } })
ok(#co == 2 and co[1] == "a.hpp" and co[2] == "z.hpp", "co_includers: sorted intersection, deduped")
ok(#T.co_includers({}, { { file = "x" } }) == 0, "co_includers: empty side → empty")

-- ── lines: assembly + honest empty states ────────────────────────────────────────────────────
local L = T.lines("A", "B", { name = "f", offset = 136, size = 48, lo = 2, hi = 2, straddle = false }, nil,
  { "/r/g1.hpp", "/r/g2.hpp" })
ok(L[1]:find("A ⊃ B — field f @136 · 48B · L2 (one line)", 1, true) ~= nil, "lines: embedding line format")
ok(L[2]:find("co-included by 2 files: g1.hpp g2.hpp", 1, true) ~= nil, "lines: co-includer basenames")
local L2 = T.lines("A", "B", nil, nil, {})
ok(L2[1]:find("no direct embedding", 1, true) ~= nil and L2[2]:find("no files include both", 1, true) ~= nil,
  "lines: honest empty states, never blank")
local Ls = T.lines("A", "B", { name = "f", offset = 60, size = 16, lo = 0, hi = 1, straddle = true }, nil, {})
ok(Ls[1]:find("L0–1  ▲ straddles inside A", 1, true) ~= nil, "lines: the straddles-inside flag renders")

-- ── LIVE: board → two struct cards → compare → ⋈ Between renders on the companion ──────────
vim.o.hidden = true
vim.o.columns = 180 -- compare is width-gated; give it room headlessly
require("fox-symdeps.nodemodel")._inject({
  closable = { ASSERT = false, ENUM = true, FILE = false, FUNCTION = true, MACRO = false,
               REGISTRY = true, STRATEGY = true, STRUCT = true, TEST = false, TYPE = true },
  openers  = { ENUM = true, FUNCTION = true, REGISTRY = true, STRATEGY = true, STRUCT = true, TYPE = true },
  meta = { count = 10 },
})
local root = vim.fn.tempname()
vim.fn.mkdir(root .. "/.git", "p") -- root marker: the tissue hook resolves root via vim.fs.root
local function write_struct(name)
  vim.fn.writefile({
    "// [STRUCT]_[" .. name .. "]",
    "// [CODE]",
    "struct " .. name .. " {",
    "  long x;",
    "};",
    "// [END_CODE]",
    "// [END_STRUCT]",
  }, ("%s/%s.hpp"):format(root, name))
end
write_struct("AlphaS")
write_struct("BetaS")
vim.fn.writefile({ '#include "AlphaS.hpp"', '#include "BetaS.hpp"' }, root .. "/gamma.hpp")

local TC = require("fox-symdeps.tagcontext")
local panel = require("fox-symdeps.panel")
local function ctx_of(name)
  vim.cmd("edit " .. vim.fn.fnameescape(("%s/%s.hpp"):format(root, name)))
  vim.bo[0].filetype = "cpp"
  pcall(vim.api.nvim_win_set_cursor, 0, { 4, 3 })
  return TC.resolve_unit()
end
local ca = ctx_of("AlphaS")
local cb = ctx_of("BetaS")
ok(ca ~= nil and cb ~= nil, "LIVE: both struct fixtures resolve to ctxs")
if ca and cb then
  panel.add_ctx(ca, {})
  panel.add_ctx(cb, {})
  panel.compare()
  local comp
  local got = vim.wait(10000, function()
    comp = panel._companion_card()
    return comp ~= nil and comp.between ~= nil
  end, 100)
  ok(got, "LIVE: the tissue computes and lands on the companion card")
  if got then
    local body = table.concat(vim.api.nvim_buf_get_lines(comp.buf, 0, -1, false), "\n")
    ok(body:find("⋈ Between (compare)", 1, true) ~= nil, "LIVE: the ⋈ Between section renders, expanded")
    ok(body:find("co-included by 1 file: gamma.hpp", 1, true) ~= nil,
      "LIVE: the co-includer coupling line names gamma.hpp")
  end
  panel.close()
end

io.write(("test_tissue: %d passed, %d failed\n"):format(pass, fail))
os.exit(fail == 0 and 0 or 1)
