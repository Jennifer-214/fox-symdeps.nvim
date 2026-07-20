-- emit_nodemodel.lua — dump the PLUGIN's derived node model as JSON, for the parity gate.
--
-- Not a test (deliberately not named test_*, so tests/run.sh skips it). This is the consumer half of
-- the D-349 cutover gate: parity_check.sh diffs what the PLUGIN derives against what `foxtag grammar
-- --json` emits. The plugin derives FROM foxtag, so this is not a tautology — it validates the
-- plugin's decode/transform layer (envelope → {type→closable} → the closable-only opener set), which
-- is real code that can silently mis-index a column, drop rows, or mis-read `closable`. Post-delete it
-- also proves no hardcoded set crept back in.
--
-- Usage:  nvim --headless --clean -u NONE -l tests/emit_nodemodel.lua    (cwd = plugin repo root)
-- Output: {"unit_types":{"NAME":bool,...},"openers":["NAME",...],"count":N}   on stdout; exit 0
--         on failure: a bare error line on stderr, exit 1 (so the gate can tell APART "ran and
--         disagreed" from "could not run at all").
package.path = "./lua/?.lua;" .. package.path

local ok, nm = pcall(require, "fox-symdeps.nodemodel")
if not ok then
  io.stderr:write("emit_nodemodel: cannot load fox-symdeps.nodemodel\n")
  os.exit(1)
end

local m = nm.model()
if not m then
  io.stderr:write("emit_nodemodel: no node model (foxtag unavailable at " .. tostring(nm.bin()) .. ")\n")
  os.exit(1)
end

local openers = {}
for t in pairs(m.openers) do openers[#openers + 1] = t end
table.sort(openers)

local names = {}
for t in pairs(m.closable) do names[#names + 1] = t end
table.sort(names)
local ut = {}
for _, t in ipairs(names) do ut[t] = m.closable[t] end

io.write(vim.json.encode({ unit_types = ut, openers = openers, count = #names }))
os.exit(0)
