-- dashboard: pure formatting helpers (human size, cache-residency verdict, base identifier).
-- Run:  nvim -l tests/test_dashboard.lua   (from the repo root)
package.path = "./lua/?.lua;" .. package.path
local D = require("fox-symdeps.dashboard")

local pass, fail = 0, 0
local function ok(c, m) if c then pass = pass + 1 else fail = fail + 1; io.write("  ✗ " .. m .. "\n") end end

-- human size: exact bytes under 8 KiB, KB above
ok(D._human(16) == "16 B", "16 → 16 B")
ok(D._human(8191) == "8191 B", "just under 8 KiB stays bytes")
ok(D._human(8192) == "8 KB", "8 KiB → KB")
ok(D._human(262288) == "256 KB", "256 KB struct")

-- residency: green fits a line, wheat spills (interesting band), plain when just large
ok(D._residency(64).hl == "FoxSymdepsOk", "≤64 B fits a cache line (green)")
ok(D._residency(64).note:find("fits", 1, true), "≤64 B note says fits")
ok(D._residency(128).hl == "FoxSymdepsWarn", "65–256 B spills (wheat/warn)")
ok(D._residency(128).note:find("spills 2", 1, true), "128 B spills 2 cache lines")
ok(D._residency(65).note:find("spills 2", 1, true), "65 B already spills 2 lines")
ok(D._residency(4096).hl == "FoxSymdepsBadge", ">256 B is plain (just large)")
ok(D._residency(4096).note == "", ">256 B drops the noisy cache-line count (footprint only)")

-- base identifier: strip namespace + template args for a definition grep
ok(D._base_ident("tt::detail::FixedPoint<10, 8>") == "FixedPoint", "namespace + template args stripped")
ok(D._base_ident("Order") == "Order", "plain name unchanged")
ok(D._base_ident("tt::EventLoopState<64>") == "EventLoopState", "namespace + <64> stripped")
ok(D._base_ident("std::vector<int>") == "vector", "std::vector → vector")

io.write(("test_dashboard: %d passed, %d failed\n"):format(pass, fail))
os.exit(fail == 0 and 0 or 1)
