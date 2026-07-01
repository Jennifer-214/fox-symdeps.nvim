-- W21 width-literal detector: byte-ish hardcoded literals == the size, excluding sizeof lines.
-- Run:  nvim -l tests/test_widthlit.lua   (from the repo root)
package.path = "./lua/?.lua;" .. package.path
local W = require("fox-symdeps.widthlit")

local pass, fail = 0, 0
local function ok(c, m) if c then pass = pass + 1 else fail = fail + 1; io.write("  ✗ " .. m .. "\n") end end

-- SUSPECTS (size = 16)
ok(W.is_suspect("char buf[16];", 16), "array dimension [16]")
ok(W.is_suspect("memcpy(dst, src, 16);", 16), "memcpy with literal 16")
ok(W.is_suspect("fwrite(&m, 16, 1, f);", 16), "fwrite with literal 16")
ok(W.is_suspect("offset = idx * 16;", 16), "stride idx * 16")
ok(W.is_suspect("struct alignas(16) X {};", 16), "alignas(16)")

-- NOT suspects
ok(not W.is_suspect("char buf[sizeof(Money)];", 16), "sizeof line is safe (parameterized)")
ok(not W.is_suspect("int total = 16;", 16), "plain assignment (no byte-ish context)")
ok(not W.is_suspect("for (i = 0; i < 160; i++)", 16), "16 inside 160 not matched (token boundary)")
ok(not W.is_suspect("char buf[8];", 16), "wrong size not matched")
ok(not W.is_suspect("x = obj16.f();", 16), "16 inside an identifier not matched")

-- scan a fixture file
local tmp = vim.fn.tempname() .. ".hpp"
vim.fn.writefile({ "char a[16];", "int ok = sizeof(T);", "memset(p, 0, 16);", "int z = 3;" }, tmp)
local abs = vim.fn.fnamemodify(tmp, ":p")
local hits = W.scan({ abs, abs }, 16) -- duplicate path → deduped
ok(#hits == 2, "scan finds 2 suspects (array + memset), dedups files — got " .. #hits)
ok(hits[1].line == 1 and hits[2].line == 3, "suspects at lines 1 and 3")
ok(hits[1].text == "char a[16];", "trimmed line text carried")

io.write(("test_widthlit: %d passed, %d failed\n"):format(pass, fail))
os.exit(fail == 0 and 0 or 1)
