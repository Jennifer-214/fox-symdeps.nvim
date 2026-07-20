-- tagcontext.enclosing_block — the CLOSABLE-only opener filter (E.1.2.B 0.3 / D-384).
--
-- The node model is DERIVED from foxtag; here it is injected so the test is pure (no binary needed).
-- What this guards, in order of why it exists:
--   1. inline [ASSERT] inside a closable unit must NOT abort resolution (ASSERT has no [END_ASSERT];
--      canonical placement per D-340 — a membership-only unit set regresses every such unit);
--   2. a cursor under a [FILE] header must not scan the buffer for a nonexistent [END_FILE] (the LIVE
--      bug the derived closable column fixes — FILE/MACRO were openers in the old hardcoded set);
--   3. ordinary + nested resolution still works;
--   4. no node model → (nil, "no-model") so callers can offer the heal instead of "not in a unit".
-- Run:  nvim -l tests/test_tagcontext.lua   (from the repo root)
package.path = "./lua/?.lua;" .. package.path

local nm = require("fox-symdeps.nodemodel")
local TC = require("fox-symdeps.tagcontext")

local pass, fail = 0, 0
local function ok(c, m) if c then pass = pass + 1 else fail = fail + 1; io.write("  ✗ " .. m .. "\n") end end
local function eq(a, b, m)
  if a == b then pass = pass + 1 else fail = fail + 1
    io.write(("  ✗ %s (got %s want %s)\n"):format(m, tostring(a), tostring(b))) end
end

-- the real 10-type / 6-closable model foxtag emits (mirrors `foxtag grammar --json`)
nm._inject({
  closable = { ASSERT = false, ENUM = true, FILE = false, FUNCTION = true, MACRO = false,
               REGISTRY = true, STRATEGY = true, STRUCT = true, TEST = false, TYPE = true },
  openers  = { ENUM = true, FUNCTION = true, REGISTRY = true, STRATEGY = true, STRUCT = true, TYPE = true },
  meta = { count = 10 },
})

local function buf_from(lines)
  local b = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(b, 0, -1, false, lines)
  return b
end

-- ── 1. inline [ASSERT] inside a closable REGISTRY (the D-340 canonical shape) ────────────────────
-- Cursor BELOW the assert must still resolve to the enclosing REGISTRY, not nil.
local reg = buf_from({
  "//====================================================",     -- 0
  "// [REGISTRY]_[OmsExitPredictorMeta]",                        -- 1
  "// [CODE]",                                                   -- 2
  "#define FOREACH_X(X) \\",                                     -- 3
  "// [ASSERT]_[LAYOUT_LOCK]",                                   -- 4  ← light unit, NO [END_ASSERT]
  "static_assert(sizeof(T) == 64);",                             -- 5
  "int after_the_assert = 1;",                                   -- 6  ← cursor here
  "// [END_CODE]",                                               -- 7
  "// [END_REGISTRY]",                                           -- 8
})
local b1 = TC.enclosing_block(reg, 6)
ok(b1 ~= nil, "cursor below an inline [ASSERT] still resolves (ASSERT is not an opener)")
eq(b1 and b1.type, "REGISTRY", "resolves to the enclosing REGISTRY, not the ASSERT")
eq(b1 and b1.name, "OmsExitPredictorMeta", "carries the registry name")

-- cursor ON the [ASSERT] line resolves to the enclosing unit too (it is inside the REGISTRY)
local b2 = TC.enclosing_block(reg, 4)
eq(b2 and b2.type, "REGISTRY", "cursor ON the [ASSERT] line resolves to the enclosing REGISTRY")

-- ── 1b. the same class for a NON-ASSERT light unit: [MACRO] nested inside a closable FUNCTION ────
-- Discriminating: treating MACRO as an opener makes the inner scan hunt a nonexistent [END_MACRO]
-- and abort, so the cursor below it resolves to nil instead of the enclosing FUNCTION.
local macrobuf = buf_from({
  "// [FUNCTION]_[Wrapper]",                                     -- 0
  "// [CODE]",                                                   -- 1
  "// [MACRO]_[LOCAL_HELPER]",                                   -- 2  ← light unit, NO [END_MACRO]
  "#define LOCAL_HELPER(x) ((x)+1)",                             -- 3
  "int Wrapper() { return LOCAL_HELPER(1); }",                   -- 4  ← cursor here
  "// [END_CODE]",                                               -- 5
  "// [END_FUNCTION]",                                           -- 6
})
eq((TC.enclosing_block(macrobuf, 4) or {}).type, "FUNCTION",
   "cursor below an inline [MACRO] still resolves to the enclosing FUNCTION")

-- ── 2. [FILE] opens no scope ─────────────────────────────────────────────────────────────────────
-- NOTE: at top-of-file both the old and new code return nil for a header-region cursor, so this is
-- not a wrong-answer fix there — the win is that resolution SKIPS the light unit and keeps scanning
-- instead of hunting a nonexistent [END_FILE] across the whole buffer. The wrong-answer cases are
-- 1/1b above (a light unit nested INSIDE a closable one).
local filebuf = buf_from({
  "// [FILE]_[CoreFrameworks/EngineSharded/Run.hpp]",            -- 0  ← light unit, no [END_FILE]
  "// [OVERVIEW]_[the sharded run loop]",                        -- 1
  "",                                                            -- 2
  "// [FUNCTION]_[EngineSharded_Run]",                           -- 3
  "// [CODE]",                                                   -- 4
  "int EngineSharded_Run() { return 0; }",                       -- 5  ← cursor here
  "// [END_CODE]",                                               -- 6
  "// [END_FUNCTION]",                                           -- 7
})
local b3 = TC.enclosing_block(filebuf, 5)
eq(b3 and b3.type, "FUNCTION", "resolves the FUNCTION even though a [FILE] header sits above")
-- cursor in the file-header region (above any closable unit) → nil, but WITHOUT a runaway scan
eq(TC.enclosing_block(filebuf, 1), nil, "cursor in the [FILE] header region → nil (FILE opens no scope)")

-- ── 3. ordinary + nested + between-blocks ────────────────────────────────────────────────────────
local nested = buf_from({
  "// [STRUCT]_[Outer]",                                         -- 0
  "// [CODE]",                                                   -- 1
  "struct Outer {",                                              -- 2
  "// [END_CODE]",                                               -- 3
  "// [END_STRUCT]",                                             -- 4
  "",                                                            -- 5  ← between blocks
  "// [FUNCTION]_[Helper]",                                      -- 6
  "// [CODE]",                                                   -- 7
  "void Helper() {}",                                            -- 8  ← cursor here
  "// [END_CODE]",                                               -- 9
  "// [END_FUNCTION]",                                           -- 10
})
eq((TC.enclosing_block(nested, 2) or {}).type, "STRUCT", "STRUCT resolves")
eq((TC.enclosing_block(nested, 8) or {}).type, "FUNCTION", "second block resolves independently")
eq(TC.enclosing_block(nested, 5), nil, "cursor between blocks (after a closer) → nil")

-- ── 4. no node model → (nil, 'no-model') so the caller can offer the heal ────────────────────────
nm._inject(false) -- force unavailable (NOT nil: the in-tree anchor would find the real binary)
local b4, err = TC.enclosing_block(nested, 8)
eq(b4, nil, "no node model → nil block")
eq(err, "no-model", "no node model → 'no-model' err (caller offers the one-keypress heal)")

io.write(("test_tagcontext: %d passed, %d failed\n"):format(pass, fail))
os.exit(fail == 0 and 0 or 1)
