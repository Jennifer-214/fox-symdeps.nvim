-- branchtag LIVE path: toggle → sidecar discovery → awk spawn → parse → extmarks, against a
-- self-contained fixture tree. Exists because the pure tests + a bash-side probe both passed
-- while the SHIPPED path was dead: the awk program string carried Lua-interpreted newlines
-- ('unterminated string', exit 1) and the overlay silently painted nothing — the seam nobody
-- crossed (operator-reported live, 2026-08-18). This test crosses it on every run.
-- Run:  nvim -l tests/test_branchtag_live.lua
package.path = "./lua/?.lua;" .. package.path
local B = require("fox-symdeps.branchtag")

local pass, fail = 0, 0
local function ok(c, m) if c then pass = pass + 1 else fail = fail + 1; io.write("  ✗ " .. m .. "\n") end end

-- fixture tree: root/.git (root marker) · root/build/asm/mini.asm · root/CoreFrameworks/mini.hpp
local root = vim.fn.tempname()
vim.fn.mkdir(root .. "/.git", "p")
vim.fn.mkdir(root .. "/build/asm", "p")
vim.fn.mkdir(root .. "/CoreFrameworks", "p")
local src = root .. "/CoreFrameworks/mini.hpp"
vim.fn.writefile({
  "#pragma once",
  "inline long MiniFn(long* p) {",
  "  if (*p == 1) return 2;",
  "  long r = (p[1] > 0) ? 5 : 7;",
  "  for (int i = 0; i < 3; ++i) r += i;",
  "  return r;",
  "}",
}, src)
-- sidecar: real header shape (parse_header contract) + one objdump -l block carrying every
-- mark class — a data-dep branch @3 whose FEEDER load attributes to line 6, a benign
-- reg/const loop branch @5, and a cmov (branchless select) @4. Registers chosen so the
-- benign compare (%ecx/%edx) can't inherit data-dependence from the %rbx load through the
-- classifier's backtrace window.
vim.fn.writefile({
  "# 1:1 disassembly of build/mini — the SHIPPED artifact, never a re-compile",
  "# binary-sha256-16: deadbeefdeadbeef  binary-mtime: 1700000000  emitted-at-HEAD: testfix",
  "",
  "0000000000001000 <MiniFn(long*)>:",
  "MiniFn():",
  src .. ":6",
  "    1000:\tmov    0x8(%rdi),%rbx",
  src .. ":3",
  "    1006:\ttest   %rbx,%rbx",
  "    1009:\tjne    1020 <MiniFn(long*)+0x20>",
  src .. ":5",
  "    100b:\tcmpl   $0x3,%ecx",
  "    100e:\tjl     1006 <MiniFn(long*)+0x6>",
  src .. ":4",
  "    1010:\tcmovg  %rdx,%rax",
  "    1014:\tret",
  "",
}, root .. "/build/asm/mini.asm")

local NS = vim.api.nvim_create_namespace("fox_symdeps_branchtag")
local function marks_of(buf)
  return vim.api.nvim_buf_get_extmarks(buf, NS, 0, -1, { details = true })
end
local function texts(marks)
  local out = {}
  for _, m in ipairs(marks) do
    out[#out + 1] = { lnum = m[2] + 1,
      text = (m[4] and m[4].virt_text and m[4].virt_text[1] and m[4].virt_text[1][1]) or "?" }
  end
  return out
end

-- ① the covered file paints the ▲ on the marker's line
vim.cmd("edit " .. vim.fn.fnameescape(src))
local buf = vim.api.nvim_get_current_buf()
B.toggle()
local painted = vim.wait(8000, function() return #marks_of(buf) > 0 end, 50)
ok(painted, "LIVE: toggling on a sidecar-covered file paints extmarks (async awk path completes)")
local at = {}
local wrong_green = false
for _, t in ipairs(texts(marks_of(buf))) do
  at[t.lnum] = (at[t.lnum] or "") .. t.text
  -- treesitter cpp may be absent under --clean: fn verdicts are optional here, but a GREEN
  -- VERDICT on this file would be a lie either way (its function branches on data). The
  -- ✓ cmov LINE chip is not a verdict — only the "· shipped" green is.
  if t.text:find("branchless", 1, true) and t.text:find("shipped", 1, true) then wrong_green = true end
end
ok((at[3] or ""):find("data-dependent branch", 1, true) ~= nil,
  "LIVE: the memory-fed branch's ▲ lands on the marker's source line (3)")
ok((at[5] or ""):find("branch (reg/loop)", 1, true) ~= nil,
  "LIVE: the reg/const loop conditional gets its △ on line 5")
ok((at[4] or ""):find("branchless (cmov)", 1, true) ~= nil,
  "LIVE: the compiled-branchless select gets its ✓ on line 4")
ok((at[6] or ""):find("data source for ▲ @3", 1, true) ~= nil,
  "LIVE: the feeding LOAD's own line (6) is flagged as the ▲@3's data source")
ok(not wrong_green, "LIVE: no green VERDICT painted on a function that branches on data")

-- ② a file with NO sidecar coverage paints NOTHING (never green on nothing, at the live layer)
local other = root .. "/CoreFrameworks/uncovered.hpp"
vim.fn.writefile({ "#pragma once", "inline int Two() { return 2; }" }, other)
vim.cmd("edit " .. vim.fn.fnameescape(other))
local obuf = vim.api.nvim_get_current_buf()
vim.wait(1500, function() return false end, 200) -- give a wrong paint every chance to happen
ok(#marks_of(obuf) == 0, "LIVE: an uncovered file gets ZERO extmarks — no false all-clear")

-- ③ toggle off clears the covered buffer
B.toggle()
ok(#marks_of(buf) == 0, "LIVE: toggle off clears the painted buffer")

io.write(("test_branchtag_live: %d passed, %d failed\n"):format(pass, fail))
os.exit(fail == 0 and 0 or 1)
