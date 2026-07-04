-- notes lens: doc categorization/ranking + relative-path display. Pure helpers.
-- Run:  nvim -l tests/test_notes.lua   (from the repo root)
package.path = "./lua/?.lua;" .. package.path
local N = require("fox-symdeps.lenses.notes")

local pass, fail = 0, 0
local function ok(c, m) if c then pass = pass + 1 else fail = fail + 1; io.write("  ✗ " .. m .. "\n") end end
local function rank(p) return (N._doc_category(p)) end
local function cat(p) return select(2, N._doc_category(p)) end

-- category assignment
ok(cat("/ws/DESIGN_SPECS/foo.md") == "specs", "design_specs → specs")
ok(cat("/ws/INVARIANTS.md") == "specs", "invariants → specs")
ok(cat("/ws/CHANGELOG.md") == "changelog", "changelog → changelog")
ok(cat("/ws/plans/2026-x.md") == "plans", "plans/ → plans")
ok(cat("/ws/memory.backup/fe.md") == "backups", "*.backup → backups")
ok(cat("/ws/notes/random.md") == "docs", "unclassified → docs")
ok(cat("/ws/README.md") == "logs", "readme → logs")

-- ranking order: specs > changelog > plans > docs > logs > backups
ok(rank("/ws/DESIGN_SPECS/a.md") > rank("/ws/CHANGELOG.md"), "specs > changelog")
ok(rank("/ws/CHANGELOG.md") > rank("/ws/plans/a.md"), "changelog > plans")
ok(rank("/ws/plans/a.md") > rank("/ws/notes/a.md"), "plans > docs")
ok(rank("/ws/notes/a.md") > rank("/ws/README.md"), "docs > logs")
ok(rank("/ws/README.md") > rank("/ws/x.backup/a.md"), "logs > backups")
ok(rank("/ws/x.backup/a.md") == 0, "backups rank 0 (bottom)")

-- relative path: strip to the matching repo, prefix with its basename
local dirs = { "/home/caramel/code/FoxML_Trader_v2", "/home/caramel/code/tick-trader-percore-workspace" }
ok(N._rel_to_dirs("/home/caramel/code/tick-trader-percore-workspace/DOCS/CHANGELOG.md", dirs)
  == "tick-trader-percore-workspace/DOCS/CHANGELOG.md", "rel path prefixed with repo basename")
ok(N._rel_to_dirs("/some/unrelated/x.md", dirs) == "x.md", "unmatched → filename only")

io.write(("test_notes: %d passed, %d failed\n"):format(pass, fail))
os.exit(fail == 0 and 0 or 1)
