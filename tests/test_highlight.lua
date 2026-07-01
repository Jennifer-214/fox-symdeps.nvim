-- W13 use-lens tests: eol role tags placed at the right lines, byte-sites RED (Alarm) and other
-- roles calm (LensTag), ]u/[u navigation, and clean teardown. No clangd: refs are fed directly.
-- Run:  nvim -l tests/test_highlight.lua   (from the repo root)
package.path = "./lua/?.lua;" .. package.path
local lens = require("fox-symdeps.highlight")

local pass, fail = 0, 0
local function ok(c, m) if c then pass = pass + 1 else fail = fail + 1; io.write("  ✗ " .. m .. "\n") end end

local tmp = vim.fn.tempname() .. ".cpp"
vim.fn.writefile(
  { "struct Foo {", "  int a;", "  int b;", "};", "static_assert(sizeof(Foo)==8);", "Foo make();" }, tmp)
vim.cmd("edit " .. tmp)
local buf = vim.api.nvim_get_current_buf()
local abs = vim.fn.fnamemodify(tmp, ":p")

local n = lens.show({
  { file = abs, line = 2, col = 6, role = "input" },
  { file = abs, line = 5, col = 20, role = "byte" },
  { file = abs, line = 6, col = 0, role = "returned" },
})
ok(n == 3, "show returns ref count")
ok(lens.active(), "lens active after show")

local marks = vim.api.nvim_buf_get_extmarks(buf, lens._ns, 0, -1, { details = true })
ok(#marks == 3, "3 extmarks placed (got " .. #marks .. ")")
local by_row = {}
for _, mk in ipairs(marks) do by_row[mk[2]] = mk[4].virt_text[1] end -- mk[2]=row0, [1]={text,hl}
ok(by_row[1] and by_row[1][2] == "FoxSymdepsLensTag", "input tag (line 2) uses calm LensTag")
ok(by_row[1] and by_row[1][1]:find("in", 1, true) ~= nil, "input tag text says 'in'")
ok(by_row[4] and by_row[4][2] == "FoxSymdepsAlarm", "byte tag (line 5) uses RED Alarm")
ok(by_row[4] and by_row[4][1]:find("⚠", 1, true) ~= nil, "byte tag glows ⚠")
ok(by_row[5] and by_row[5][2] == "FoxSymdepsLensTag", "returned tag (line 6) stays calm")

-- re-entering the buffer (BufEnter re-tags) must NOT stack duplicate tags (the buildup bug)
lens._tag_buffer(buf); lens._tag_buffer(buf)
ok(#vim.api.nvim_buf_get_extmarks(buf, lens._ns, 0, -1, {}) == 3, "re-tag is idempotent (no buildup)")

lens.next(); ok(vim.api.nvim_win_get_cursor(0)[1] == 2, "]u → first use (line 2)")
lens.next(); ok(vim.api.nvim_win_get_cursor(0)[1] == 5, "]u → line 5")
lens.prev(); ok(vim.api.nvim_win_get_cursor(0)[1] == 2, "[u → back to line 2")

lens.clear()
ok(not lens.active(), "cleared → inactive")
ok(#vim.api.nvim_buf_get_extmarks(buf, lens._ns, 0, -1, {}) == 0, "cleared → no extmarks left")

io.write(("test_highlight: %d passed, %d failed\n"):format(pass, fail))
os.exit(fail == 0 and 0 or 1)
