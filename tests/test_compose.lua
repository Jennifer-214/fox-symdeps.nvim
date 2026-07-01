-- W22 recursive composition: member extraction (treesitter) + recursive tree (rg-resolved defs).
-- Run:  nvim -l tests/test_compose.lua   (from the repo root; needs the cpp treesitter parser)
package.path = "./lua/?.lua;" .. package.path
local C = require("fox-symdeps.compose")

local pass, fail = 0, 0
local function eq(a, b, m) if a == b then pass = pass + 1 else fail = fail + 1; io.write(("  ✗ %s (got %s want %s)\n"):format(m, tostring(a), tostring(b))) end end

-- is_struct_type: recurse into user structs, skip primitives/pointers/templates/std
eq(C._is_struct_type("Money"), true, "Money is a struct type")
eq(C._is_struct_type("FPN_Binary"), true, "FPN_Binary is a struct type")
eq(C._is_struct_type("int"), false, "int is not")
eq(C._is_struct_type("Money*"), false, "pointer not recursed")
eq(C._is_struct_type("std::string"), false, "std:: not recursed")
eq(C._is_struct_type("FPN_Binary<64>"), true, "template instantiation recurses (base)")
eq(C._is_struct_type("Box<F>*"), false, "pointer-to-template not recursed")

-- members via content override (pure treesitter, no rg/files)
local m = C.members("Position", nil, "struct Position { Money entry; Money exit; int qty; };")
eq(#m, 3, "Position has 3 members")
eq(m[1].name .. ":" .. m[1].type, "entry:Money", "member 1 name:type")
eq(m[3].name .. ":" .. m[3].type, "qty:int", "member 3 name:type")

-- recursive tree against a fixture dir (rg resolves each type's def file)
local dir = vim.fn.tempname(); vim.fn.mkdir(dir, "p")
vim.fn.writefile({ "struct Inner { int a; double b; };" }, dir .. "/inner.hpp")
vim.fn.writefile({ '#include "inner.hpp"', "struct Outer { Inner i; int c; };" }, dir .. "/outer.hpp")
local tree = C.tree("Outer", dir, 3)
eq(#tree, 2, "Outer has 2 members")
eq(tree[1].name .. ":" .. tree[1].type, "i:Inner", "Outer.i is Inner")
eq(tree[1].children ~= nil, true, "Inner member expanded (has children)")
eq(tree[1].children and #tree[1].children, 2, "Inner has 2 members")
eq(tree[1].children and tree[1].children[1].name, "a", "Inner.a")
eq(tree[2].children, nil, "int member not expanded")

-- template member drills into the BASE template's fields (the engine is template-heavy)
local tdir = vim.fn.tempname(); vim.fn.mkdir(tdir, "p")
vim.fn.writefile({ "template<int N> struct Box { int cap; long tag; };" }, tdir .. "/box.hpp")
vim.fn.writefile({ '#include "box.hpp"', "struct Holder { Box<8> b; int n; };" }, tdir .. "/holder.hpp")
local tt = C.tree("Holder", tdir, 3)
eq(tt[1].name .. ":" .. tt[1].type, "b:Box<8>", "member keeps its instantiation type")
eq(tt[1].children ~= nil, true, "Box<8> drills into base template Box")
eq(tt[1].children and tt[1].children[1].name, "cap", "Box.cap surfaced")

io.write(("test_compose: %d passed, %d failed\n"):format(pass, fail))
os.exit(fail == 0 and 0 or 1)
