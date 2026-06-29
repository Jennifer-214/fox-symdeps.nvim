-- Unit tests for the neo-tree consumer-count rollup: clangd reference items → a
-- path→count map with ancestor-directory aggregation. Run from the repo root:
--   nvim -l tests/test_neotree_rollup.lua   (needs vim.fn.fnamemodify)
package.path = "./lua/?.lua;" .. package.path
local build = require("fox-symdeps.neotree")._build_lookup

local pass, fail = 0, 0
local function eq(got, want, label)
  if got == want then
    pass = pass + 1
  else
    fail = fail + 1
    io.write(("  ✗ %s (got %s, want %s)\n"):format(label, tostring(got), tostring(want)))
  end
end

-- two refs in one file, one in a sibling, one in a different subtree
local lk = build({
  { file = "/p/src/a.cpp", line = 10 },
  { file = "/p/src/a.cpp", line = 22 },
  { file = "/p/src/b.cpp", line = 3 },
  { file = "/p/other/c.cpp", line = 5 },
})
eq(lk["/p/src/a.cpp"], 2, "file a.cpp = 2 refs")
eq(lk["/p/src/b.cpp"], 1, "file b.cpp = 1 ref")
eq(lk["/p/other/c.cpp"], 1, "file c.cpp = 1 ref")
eq(lk["/p/src"], 3, "dir /p/src rolls up 2+1")
eq(lk["/p/other"], 1, "dir /p/other rolls up 1")
eq(lk["/p"], 4, "dir /p rolls up all 4")
eq(lk["/unreferenced"], nil, "unreferenced path = nil (component renders nothing)")

local empty = build({})
eq(next(empty), nil, "empty items = empty lookup")

io.write(("\nneotree rollup: %d passed, %d failed\n"):format(pass, fail))
os.exit(fail == 0 and 0 or 1)
