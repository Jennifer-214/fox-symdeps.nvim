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
ok(not W.is_suspect("uint64_t log[16];", 16), "wide-element array [16] = element count, not 16 bytes")
ok(not W.is_suspect("Foo items[16];", 16), "struct array [16] not a 16-byte pin")
ok(not W.is_suspect("x = obj16.f();", 16), "16 inside an identifier not matched")
ok(not W.is_suspect("// char buf[16]; historical note", 16), "line comment ignored")
ok(not W.is_suspect("   * nodes[16] in a doc block", 16), "block-comment continuation ignored")
ok(W.is_suspect("char buf[16]; // 16-byte serialized T", 16), "real code with a trailing comment still matches")

-- PRECISION at the common widths (4, 8): the bare stride heuristic must NOT cry wolf, but the
-- strong contexts (byte-array, alignas, mem*-with-arg) must still fire. This is the trust fix.
ok(not W.is_suspect("return idx * 8 + off;", 8), "size 8: idx*8 stride is ordinary arithmetic, not a suspect")
ok(not W.is_suspect("hash = seed + 8;", 8), "size 8: +8 stride not a suspect")
ok(not W.is_suspect("return a * 4;", 4), "size 4: *4 stride not a suspect")
ok(not W.is_suspect("total = count * 8;", 8), "size 8: count*8 not a suspect")
ok(W.is_suspect("char scratch[8];", 8), "size 8: byte-array [8] IS still a suspect (strong context)")
ok(W.is_suspect("memcpy(dst, src, 8);", 8), "size 8: memcpy(...,8) with the literal as an arg IS a suspect")
ok(W.is_suspect("struct alignas(8) X {};", 8), "size 8: alignas(8) IS a suspect")
ok(W.is_suspect("nbytes = width * 72;", 72), "size 72 (> 8): uncommon-width stride still fires")
-- mem* tightening: the literal must be INSIDE the call, not merely co-occurring on the line
ok(not W.is_suspect("memcpy(dst, src, n);  offset += 8;", 8), "8 outside the memcpy args is not the mem* suspect")
ok(W.is_suspect("fwrite(&m, 8, 1, f);", 8), "size 8: fwrite(&m, 8, ...) literal inside the call fires")

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
