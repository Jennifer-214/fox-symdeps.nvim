-- W14 tool-pack host: discover + load provider modules from a pack dir; skip broken/non-lua;
-- reload is idempotent (clears first). Run:  nvim -l tests/test_pack.lua   (from repo root)
package.path = "./lua/?.lua;" .. package.path
local pack = require("fox-symdeps.pack")
local provider = require("fox-symdeps.provider")

local pass, fail = 0, 0
local function ok(c, m) if c then pass = pass + 1 else fail = fail + 1; io.write("  ✗ " .. m .. "\n") end end

local dir = vim.fn.tempname()
vim.fn.mkdir(dir, "p")
vim.fn.writefile({ 'require("fox-symdeps.provider").register(function() end)' }, dir .. "/a.lua")
vim.fn.writefile({ 'require("fox-symdeps.provider").register(function() end)' }, dir .. "/b.lua")
vim.fn.writefile({ 'this is not valid lua (' }, dir .. "/broken.lua")
vim.fn.writefile({ 'ignore me' }, dir .. "/notes.txt")

local n = pack.setup({ dir })
ok(provider.count() == 2, "2 valid providers loaded (broken + .txt skipped) — got " .. provider.count())
ok(n == 2, "setup returns the loaded count")

pack.reload()
ok(provider.count() == 2, "reload clears first → no double-register — got " .. provider.count())

pack.setup({ dir .. "/does-not-exist" })
ok(provider.count() == 0, "missing dir → registry cleared, 0 providers")

io.write(("test_pack: %d passed, %d failed\n"):format(pass, fail))
os.exit(fail == 0 and 0 or 1)
