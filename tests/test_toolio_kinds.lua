-- toolio_kinds: the TD-258 data-enumeration half — plugin-consumed kinds ⇄ tools/lib/toolio_schemas.json.
-- Live leg proves today's parity; planted legs prove the check can actually fire (non-vacuity);
-- refusal leg proves unreadable ≠ clean (Class 57 tri-state).
-- Run: nvim -l tests/test_toolio_kinds.lua   (suite: bash tests/run.sh)
package.path = "./lua/?.lua;" .. package.path
local TK = require("fox-symdeps.toolio_kinds")

local pass, fail = 0, 0
local function ok(c, m) if c then pass = pass + 1 else fail = fail + 1; io.write("  ✗ " .. m .. "\n") end end

-- live leg: the REAL registry (cwd = plugin root; engine root is three dirs up)
local root = vim.fn.fnamemodify(vim.fn.getcwd(), ":h:h:h")
local r = TK.parity(root)
ok(r.refusal == nil, "live registry readable (got refusal: " .. tostring(r.refusal) .. ")")
if r.refusal == nil then
  ok(#r.missing_consumer == 0, "no registry kind lacks a consumer (missing: " .. table.concat(r.missing_consumer, ", ") .. ")")
  ok(#r.unknown_kind == 0, "no plugin-claimed kind is absent from the registry (unknown: " .. table.concat(r.unknown_kind, ", ") .. ")")
  ok(r.n_kinds >= 3, "registry carries at least the three consumed kinds (floor, not a tally)")
end

-- planted drift: a NEW producer kind with no consumer MUST fire (the whole point of the check)
local plant = TK.compare({ "grammar/1", "new_kind/1" },
                         { ["grammar/1"] = { consumer = "x" } }, {})
ok(#plant.missing_consumer == 1 and plant.missing_consumer[1] == "new_kind/1",
   "planted registry kind with no consumer is DETECTED")

-- planted drift: a plugin-claimed kind absent from the registry MUST fire
local ghost = TK.compare({ "grammar/1" },
                         { ["grammar/1"] = { consumer = "x" }, ["ghost/1"] = { consumer = "y" } }, {})
ok(#ghost.unknown_kind == 1 and ghost.unknown_kind[1] == "ghost/1",
   "planted plugin-side ghost kind is DETECTED")

-- planted drift: a STALE exemption (key gone from the registry) MUST fire
local stale = TK.compare({ "grammar/1" },
                         { ["grammar/1"] = { consumer = "x" } },
                         { ["gone/1"] = "old reason" })
ok(#stale.unknown_kind == 1 and stale.unknown_kind[1] == "gone/1 (exempt row)",
   "stale exemption row is DETECTED as drift")

-- refusal leg: unreadable registry is a REFUSAL, never a clean pass
local ref = TK.parity("/nonexistent-root-toolio-kinds-test")
ok(ref.refusal ~= nil, "unreadable registry returns a refusal, not empty-parity ok")

io.write(("toolio_kinds: %d passed, %d failed\n"):format(pass, fail))
if fail > 0 then os.exit(1) end
