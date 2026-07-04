-- Pure L1 false-sharing risk logic (writers.risk). No treesitter/LSP → runs in the --clean harness.
-- Run: nvim --headless --clean -u NONE -l tests/test_writers.lua   (from repo root)
package.path = "./lua/?.lua;" .. package.path
local W = require("fox-symdeps.writers")

local pass, fail = 0, 0
local function ok(c, m) if c then pass = pass + 1 else fail = fail + 1; io.write("  ✗ " .. m .. "\n") end end
local function count(fields, writers, opts) return #W.risk(fields, writers, opts) end
local function has(risks, a, b)
  if a > b then a, b = b, a end
  for _, r in ipairs(risks) do if r.a == a and r.b == b then return r end end
  return nil
end

-- lines_of: straddle math
do
  local f, l = W._lines_of({ offset = 0, size = 8 }, 64); ok(f == 0 and l == 0, "0..7 → line 0")
  f, l = W._lines_of({ offset = 60, size = 8 }, 64); ok(f == 0 and l == 1, "60..67 straddles line 0→1")
  f, l = W._lines_of({ offset = 64, size = 8 }, 64); ok(f == 1 and l == 1, "64..71 → line 1")
end

-- SPSC ring, cache-line separated → CLEAN even with disjoint writers (validates an existing fix).
do
  local fields = { { name = "head_", offset = 0, size = 8 }, { name = "tail_", offset = 64, size = 8 } }
  ok(count(fields, { head_ = { "push" }, tail_ = { "pop" } }) == 0, "separated head_/tail_ → 0 risks (fix validated)")
end

-- Merged onto one line, disjoint writers → the classic false-sharing FLAG.
do
  local fields = { { name = "head_", offset = 0, size = 8 }, { name = "tail_", offset = 8, size = 8 } }
  local risks = W.risk(fields, { head_ = { "push" }, tail_ = { "pop" } })
  ok(#risks == 1, "merged head_/tail_ disjoint → 1 risk")
  local r = has(risks, "head_", "tail_")
  ok(r ~= nil and r.line == 0, "risk is head_↔tail_ on line 0")
  ok(r and r.writers_a[1] == "push" and r.writers_b[1] == "pop", "writer-sets attributed (push / pop)")
end

-- Same writer, or overlapping writers → NOT a risk (coordinated single owner).
do
  local fields = { { name = "a", offset = 0, size = 8 }, { name = "b", offset = 8, size = 8 } }
  ok(count(fields, { a = { "upd" }, b = { "upd" } }) == 0, "same writer → 0 risks")
  ok(count(fields, { a = { "x", "y" }, b = { "y", "z" } }) == 0, "overlapping writers (shared y) → 0 risks")
end

-- Read-only neighbour → NOT a risk (no write contention).
do
  local fields = { { name = "a", offset = 0, size = 8 }, { name = "b", offset = 8, size = 8 } }
  ok(count(fields, { a = { "push" } }) == 0, "written next to read-only → 0 risks")
  ok(count(fields, { a = { "push" }, b = {} }) == 0, "empty writer list counts as read-only")
end

-- Set form accepted, and a straddling field contends on BOTH lines it touches.
do
  local fields = {
    { name = "c", offset = 0, size = 8 },   -- line 0
    { name = "a", offset = 56, size = 16 }, -- lines 0 and 1
    { name = "b", offset = 72, size = 8 },  -- line 1
  }
  local risks = W.risk(fields, { c = { upd = true }, a = { push = true }, b = { pop = true } })
  ok(#risks == 2, "straddling field a contends on both its lines → 2 risks (a↔c, a↔b)")
  ok(has(risks, "a", "c") ~= nil, "a↔c risk on line 0")
  ok(has(risks, "a", "b") ~= nil, "a↔b risk on line 1")
end

io.write(("test_writers: %d passed, %d failed\n"):format(pass, fail))
os.exit(fail == 0 and 0 or 1)
