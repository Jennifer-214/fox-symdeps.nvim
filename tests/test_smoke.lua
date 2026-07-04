-- Smoke test: every module requires without error, setup() runs, and all built-in lenses register.
-- Catches syntax errors / load regressions that the pure-logic tests miss (no clangd needed — this
-- only loads code + runs setup). This is the hand "load check" turned into a committed test.
-- Run: nvim --headless --clean -u NONE -l tests/test_smoke.lua   (run.sh handles the rtp)
local here = debug.getinfo(1, "S").source:sub(2):match("(.*/)") or "./"
vim.opt.runtimepath:append(vim.fn.fnamemodify(here .. "..", ":p"))

local pass, fail = 0, 0
local function ok(c, m) if c then pass = pass + 1 else fail = fail + 1; io.write("  ✗ " .. m .. "\n") end end

-- every module loads (a syntax error anywhere fails here, not at HUD-open time)
for _, mod in ipairs({
  "provider", "lens", "pack", "hud", "panel", "clangd", "layout", "classify", "compose",
  "bytemap", "trace", "runner", "sizeprobe", "context", "writers", "breakcheck",
  "asmdiff", "asmflags", "asmview", "browse", "highlight", "neotree", "widthlit", "health",
}) do
  local okr, err = pcall(require, "fox-symdeps." .. mod)
  ok(okr, "require fox-symdeps." .. mod .. (okr and "" or (" — " .. tostring(err))))
end

-- setup runs + the built-in lenses (lenses/*.lua) self-register through the pack loader
local oks, serr = pcall(function() require("fox-symdeps").setup({}) end)
ok(oks, "setup({}) runs" .. (oks and "" or (" — " .. tostring(serr))))
local n = require("fox-symdeps.provider").count()
ok(n >= 5, "built-in lenses registered (expected >=5: cascade/false_sharing/mutations/notes/hotpath, got " .. n .. ")")

io.write(("test_smoke: %d passed, %d failed\n"):format(pass, fail))
os.exit(fail == 0 and 0 or 1)
