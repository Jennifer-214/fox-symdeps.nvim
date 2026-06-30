-- Unit tests for treesitter role-classification of reference sites. Needs the cpp parser
-- on rtp: run from the repo root with
--   nvim --headless --clean --cmd "set rtp+=$HOME/.local/share/nvim/site" -l tests/test_classify.lua
package.path = "./lua/?.lua;" .. package.path
local role = require("fox-symdeps.classify")._role_at

local lines = {
  "struct Foo { int a; };",                  -- 0
  "void take(Foo *f) {}",                     -- 1  Foo = param          → input
  "Foo make() { Foo x; return x; }",          -- 2  1st Foo = return type → returned ; 2nd Foo = local → instantiated
  "struct Bar { Foo member; };",              -- 3  Foo = field           → embedded
  "void use() { unsigned n = sizeof(Foo); }", -- 4  Foo in sizeof         → byte
}
local content = table.concat(lines, "\n")

local pass, fail = 0, 0
local function col(row, occ)
  local line, s = lines[row + 1], 0
  for _ = 1, (occ or 1) do s = line:find("Foo", s + 1, true) end
  return s and (s - 1) or 0
end
local function eq(row, occ, want)
  local got = role(content, row, col(row, occ))
  if got == want then pass = pass + 1
  else fail = fail + 1; io.write(("  ✗ row %d occ %d: got %s want %s\n"):format(row, occ or 1, got, want)) end
end

eq(1, 1, "input")        -- void take(Foo *f)
eq(2, 1, "returned")     -- Foo make()
eq(2, 2, "instantiated") -- Foo x;
eq(3, 1, "embedded")     -- Foo member;
eq(4, 1, "byte")         -- sizeof(Foo)

-- enclosing scope (the "who uses it" at level 3)
local scope = require("fox-symdeps.classify")._scope_at
local function eqs(row, occ, want)
  local got = scope(content, row, col(row, occ))
  if got == want then pass = pass + 1
  else fail = fail + 1; io.write(("  ✗ scope row %d occ %d: got %s want %s\n"):format(row, occ or 1, tostring(got), want)) end
end
eqs(1, 1, "take") -- param → enclosing fn take
eqs(2, 2, "make") -- local → enclosing fn make
eqs(3, 1, "Bar")  -- field → enclosing struct Bar
eqs(4, 1, "use")  -- sizeof → enclosing fn use

-- tree grouping (role → file → entries, sorted, counted)
local tree = require("fox-symdeps.classify").tree({
  { file = "a.cpp", line = 20, role = "input", scope = "f2" },
  { file = "a.cpp", line = 10, role = "input", scope = "f1" },
  { file = "b.cpp", line = 5, role = "embedded", scope = "S" },
})
local function eqn(got, want, label)
  if got == want then pass = pass + 1
  else fail = fail + 1; io.write(("  ✗ %s: got %s want %s\n"):format(label, tostring(got), tostring(want))) end
end
eqn(#tree, 2, "two role groups")
eqn(tree[1].role, "input", "first role = input")
eqn(tree[1].count, 2, "input count = 2")
eqn(#tree[1].files, 1, "input has 1 file")
eqn(tree[1].files[1].entries[1].line, 10, "entries sorted by line")
eqn(tree[2].role, "embedded", "second role = embedded")

io.write(("\nclassify: %d passed, %d failed\n"):format(pass, fail))
os.exit(fail == 0 and 0 or 1)
