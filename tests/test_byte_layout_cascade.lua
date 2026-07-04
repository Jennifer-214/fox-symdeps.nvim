-- Byte-layout cascade lens — regression test for embedder NAME -> def file:line resolution in
-- build_def_index / build_tree. gen_code_map emits struct NAMES (not locations), so before W-FIX1
-- every embedder row jumped to :1. Guards: fwd-decl preference, class + template + alignas structs,
-- and (if the engine tree is present) the real rows that were broken in the HUD.
-- Folded in from fox-symdeps-trader/tests/test_wfix1.lua (2026-07-03).
--
-- Run:  nvim --headless --clean -u NONE -l tests/test_byte_layout_cascade.lua   (from repo root)

local here = debug.getinfo(1, "S").source:sub(2):match("(.*/)") or "./"
local fx = here .. "fx"
local lens = vim.fn.fnamemodify(here .. "../lua/fox-symdeps/lenses/byte_layout_cascade.lua", ":p")

local plugin = vim.fn.fnamemodify(here .. "..", ":p")
vim.opt.runtimepath:append(plugin)

local P = dofile(lens)
assert(P and P._build_def_index and P._build_tree, "lens helpers not exposed (dofile return)")

local fails = 0
local function eq(a, b, msg)
  if a ~= b then fails = fails + 1; print(("  FAIL %s: got %s want %s"):format(msg, tostring(a), tostring(b)))
  else print("  ok  " .. msg) end
end
local function truthy(v, msg)
  if not v then fails = fails + 1; print("  FAIL " .. msg) else print("  ok  " .. msg) end
end

print("== Test A: fixture (fwd-decl preference, class, template, alignas) ==")
local A = P._build_def_index(fx)
truthy(A.Foo, "Foo indexed")
eq(A.Foo.file, fx .. "/b.hpp", "Foo resolves to the DEFINITION file (not the fwd-decl in a.hpp)")
eq(A.Foo.line, 4, "Foo def line")
truthy(A.Bar, "class Bar indexed")
eq(A.Bar.line, 8, "Bar def line")
truthy(A.Baz, "template struct Baz indexed")
eq(A.Baz.line, 13, "Baz def line (line after the template<> prefix)")
truthy(A.Qux, "alignas(64) struct Qux indexed (attribute stripped, not parsed as name)")
eq(A.Qux.line, 17, "Qux def line")
truthy(A.alignas == nil, "'alignas' is NOT indexed as a bogus struct name")

local root = vim.fn.expand("~/code/FoxML_Trader_v2")
if vim.fn.isdirectory(root) == 1 then
  print("== Test B: real engine — embedders resolve to real file:line, not :1 ==")
  local B = P._build_def_index(root)
  truthy(B.PortfolioController, "PortfolioController resolved")
  eq(B.PortfolioController.file, root .. "/CoreFrameworks/PortfolioController.hpp", "PortfolioController file")
  eq(B.PortfolioController.line, 130, "PortfolioController line")
  truthy(B.RunControlState, "RunControlState (transitive) resolved")
  eq(B.RunControlState.line, 144, "RunControlState line")
  truthy(B.BookImbalanceHistory, "BookImbalanceHistory (alignas(64)) resolved — was :1 in the HUD")
  eq(B.BookImbalanceHistory.file, root .. "/ML_Headers/FlowFeatures.hpp", "BookImbalanceHistory file")
  eq(B.BookImbalanceHistory.line, 72, "BookImbalanceHistory line")

  print("== Test C: build_tree wires resolution through both tiers ==")
  local tree = P._build_tree(
    { { file = "CoreFrameworks/PortfolioController.hpp", name = "PortfolioController", fields = "" } },
    { "RunControlState" },
    { { file = "FixedPoint/FixedPointN.hpp", line = 44, text = "static_assert" } },
    root)
  local direct = tree[1].files[1].entries[1]
  truthy(direct.line ~= 1, "direct embedder NOT on :1 (was the bug)")
  eq(direct.line, 130, "direct embedder resolved line")
  local trans = tree[2].files[1].entries[1]
  truthy(trans.file ~= "(transitive)", "transitive embedder is now jumpable (has a real file)")
  eq(trans.line, 144, "transitive embedder resolved line")
  local site = tree[3].files[1].entries[1]
  eq(site.line, 44, "enforcement site line preserved (untouched)")
else
  print("== Test B/C skipped: ~/code/FoxML_Trader_v2 not present (fixture tests still ran) ==")
end

print(fails == 0 and "\nALL PASS" or ("\n" .. fails .. " FAILURE(S)"))
vim.cmd(fails == 0 and "cq 0" or "cq 1")
