-- Unit tests for runner.lua's output parsers (pure string parsing — golden lines from real
-- gen_code_map output). Run: nvim -l tests/test_runner.lua
package.path = "./lua/?.lua;" .. package.path
local R = require("fox-symdeps.runner")
local pass, fail = 0, 0
local function eq(got, want, label)
  if got == want then pass = pass + 1
  else fail = fail + 1; io.write(("  ✗ %s: got %s want %s\n"):format(label, tostring(got), tostring(want))) end
end

-- parse_sites: "  <file>:<line>:<text>" (byte-context / callers / types) — headers ignored
local sites = R.parse_sites({
  "## sizeof(FPN_Binary...) sites",
  '  FixedPoint/FixedPointN.hpp:44:static_assert(sizeof(FPN_Binary<64>) == 16, "...");',
  "  CoreFrameworks/PortfolioController.hpp:2046:  fwrite(&ctrl->realized_pnl, sizeof(FPN_Binary<F>), 1, f);",
})
eq(#sites, 2, "sites count (header skipped)")
eq(sites[1].file, "FixedPoint/FixedPointN.hpp", "site file")
eq(sites[1].line, 44, "site line")
eq(sites[2].file, "CoreFrameworks/PortfolioController.hpp", "site2 file")
eq(sites[2].line, 2046, "site2 line")

-- parse_structs: "  <file>   struct <name>   { <fields> }" (--structs)
local structs = R.parse_structs({
  "# Structs/classes embedding FPN_Binary as a field",
  "  Strategies/MeanReversion.hpp       struct MeanReversionState         { live_vol_mult live_stddev_mult }",
  "  ML_Headers/RidgeBlender.hpp        struct RidgeWeights               { w }",
})
eq(#structs, 2, "structs count (header skipped)")
eq(structs[1].name, "MeanReversionState", "struct name")
eq(structs[1].file, "Strategies/MeanReversion.hpp", "struct file")
eq(structs[1].fields, "live_vol_mult live_stddev_mult", "struct fields")
eq(structs[2].fields, "w", "struct2 fields")

-- parse_transitive: "  [transitive] <Name>" (--composition) — summary line ignored
local trans = R.parse_transitive({
  "# Structs byte-affected via TRANSITIVE composition",
  "  [transitive] RunControlState",
  "  [transitive] NodeContext",
  "  (5 DIRECT + 10 TRANSITIVE)",
})
eq(#trans, 2, "transitive count (summary skipped)")
eq(trans[1], "RunControlState", "transitive 1")
eq(trans[2], "NodeContext", "transitive 2")

io.write(("\nrunner: %d passed, %d failed\n"):format(pass, fail))
os.exit(fail == 0 and 0 or 1)
