-- tagadapter: the null [TAG]_ seam + the install() swap (the whole point — swapping the real tag
-- layer in must be one call, no downstream changes). Run:  nvim -l tests/test_tagadapter.lua
package.path = "./lua/?.lua;" .. package.path
local T = require("fox-symdeps.tagadapter")

local pass, fail = 0, 0
local function ok(c, m) if c then pass = pass + 1 else fail = fail + 1; io.write("  ✗ " .. m .. "\n") end end

-- null adapter: no-ops, marked unavailable
ok(T.available == false, "starts unavailable (no real adapter)")
ok(T.parse("// [TAG]_HOT-PATH") == nil, "parse → nil (null)")
ok(T.format_derived({ symbol = "f", data_size = 480 }) == nil, "format_derived → nil (null) so callers fall back to raw facts")
ok(type(T.verify({}, {})) == "table" and #T.verify({}, {}) == 0, "verify → empty (no drift claimed by a null adapter)")

-- install() swaps in a real adapter — the single change point
T.install({
  parse = function(txt) return txt:find("%[TAG%]_(%S+)") and { raw = txt } or nil end,
  format_derived = function(f) return { "// [DATA_SIZE]_[" .. tostring(f.data_size) .. " instr]" } end,
  verify = function(_tags, f) return f.data_size == 480 and {} or { "DATA_SIZE drift" } end,
})
ok(T.available == true, "install flips available")
ok(T.parse("x [TAG]_HOT y") ~= nil, "real parse now works")
ok(T.format_derived({ data_size = 480 })[1] == "// [DATA_SIZE]_[480 instr]", "real format_derived renders a tag")
ok(#T.verify({}, { data_size = 520 }) == 1, "real verify flags drift (520 ≠ 480)")
ok(#T.verify({}, { data_size = 480 }) == 0, "real verify: no drift when they agree")

-- install ignores a non-table (defensive)
T.install(nil)
ok(T.available == true, "install(nil) doesn't tear down an installed adapter")

io.write(("test_tagadapter: %d passed, %d failed\n"):format(pass, fail))
os.exit(fail == 0 and 0 or 1)
