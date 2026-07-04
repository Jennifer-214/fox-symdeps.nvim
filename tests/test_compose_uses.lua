-- compose.uses — distinct upstream struct dependencies. Needs the cpp treesitter parser, loaded via
-- rtp (~/.local/share/nvim/site). Run: nvim --headless --clean -u NONE -l tests/test_compose_uses.lua
local here = debug.getinfo(1, "S").source:sub(2):match("(.*/)") or "./"
package.path = here .. "../lua/?.lua;" .. package.path
vim.opt.runtimepath:append(vim.fn.expand("~/.local/share/nvim/site")) -- for the cpp parser
local compose = require("fox-symdeps.compose")

-- guard: skip cleanly if no cpp parser (so the suite doesn't hard-fail on a bare machine)
if not pcall(vim.treesitter.get_string_parser, "int x;", "cpp") then
  print("SKIP: no cpp treesitter parser available"); os.exit(0)
end

local pass, fail = 0, 0
local function ok(c, m) if c then pass = pass + 1 else fail = fail + 1; io.write("  ✗ " .. m .. "\n") end end

local src = [[
struct Inner { int x; };
struct Big {
  FPN_Binary price;
  OrderBook book;
  FPN_Binary size;   // duplicate struct type
  uint16_t flags;    // primitive — not a dep
  int* ptr;          // pointer — excluded
};
]]

local u = compose.uses("Big", nil, src)
ok(#u == 2, "2 distinct struct deps (got " .. #u .. ": " .. table.concat(u, ",") .. ")")
ok(u[1] == "FPN_Binary" and u[2] == "OrderBook", "sorted + deduped: FPN_Binary, OrderBook (primitives/pointers excluded)")

local leaf = compose.uses("Inner", nil, src)
ok(#leaf == 0, "leaf struct (only int) → 0 deps")

io.write(("test_compose_uses: %d passed, %d failed\n"):format(pass, fail))
os.exit(fail == 0 and 0 or 1)
