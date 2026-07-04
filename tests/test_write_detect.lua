-- writers.is_write_at — L0 write-detection. Needs the cpp treesitter parser (rtp += site).
-- Run: nvim --headless --clean -u NONE -l tests/test_write_detect.lua
local here = debug.getinfo(1, "S").source:sub(2):match("(.*/)") or "./"
package.path = here .. "../lua/?.lua;" .. package.path
vim.opt.runtimepath:append(vim.fn.expand("~/.local/share/nvim/site"))
local W = require("fox-symdeps.writers")

if not pcall(vim.treesitter.get_string_parser, "int x;", "cpp") then
  print("SKIP: no cpp treesitter parser available"); os.exit(0)
end

local pass, fail = 0, 0
local function ok(c, m) if c then pass = pass + 1 else fail = fail + 1; io.write("  ✗ " .. m .. "\n") end end

-- (row0, col0) of the nth occurrence of `token`
local function pos_of(content, token, nth)
  nth = nth or 1
  local row = 0
  for line in (content .. "\n"):gmatch("(.-)\n") do
    local from = 1
    while true do
      local s = line:find(token, from, true)
      if not s then break end
      nth = nth - 1
      if nth == 0 then return row, s - 1 end
      from = s + 1
    end
    row = row + 1
  end
end

local src = table.concat({
  "struct S { int aa; int bb; };",
  "void f(S& s, S& t) {",
  "  s.aa = 1;",       -- aa#2 write
  "  s.bb += 2;",      -- bb#2 write (compound)
  "  t.aa = s.bb;",    -- aa#3 write, bb#3 read
  "  s.aa++;",         -- aa#4 write
  "  int x = s.aa;",   -- aa#5 read (init)
  "  g(s.bb);",        -- bb#4 read (arg)
  "}",
}, "\n")

ok(W.is_write_at(src, pos_of(src, "aa", 2)) == true,  "s.aa = 1 -> WRITE")
ok(W.is_write_at(src, pos_of(src, "bb", 2)) == true,  "s.bb += 2 -> WRITE (compound)")
ok(W.is_write_at(src, pos_of(src, "aa", 3)) == true,  "t.aa = s.bb -> t.aa WRITE")
ok(W.is_write_at(src, pos_of(src, "bb", 3)) == false, "t.aa = s.bb -> s.bb READ (RHS)")
ok(W.is_write_at(src, pos_of(src, "aa", 4)) == true,  "s.aa++ -> WRITE")
ok(W.is_write_at(src, pos_of(src, "aa", 5)) == false, "int x = s.aa -> READ (init)")
ok(W.is_write_at(src, pos_of(src, "bb", 4)) == false, "g(s.bb) -> READ (arg)")

io.write(("test_write_detect: %d passed, %d failed\n"):format(pass, fail))
os.exit(fail == 0 and 0 or 1)
