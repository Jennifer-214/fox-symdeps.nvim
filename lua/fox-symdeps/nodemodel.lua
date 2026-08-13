-- nodemodel.lua — the plugin's SINGLE source for the [TAG]_ node model (E.1.2.B 0.3 / D-365).
--
-- The node model (which [TYPE]s are units, and which of those are CLOSABLE — i.e. carry a matching
-- [END_<TYPE>]) is DERIVED from the fact core, never hardcoded here:
--
--   foxtag grammar --json  ->  envelope.payload.unit_types = { schema={name,closable}, rows={...} }
--
-- Two copies of this set used to live in tag_grammar_adapter.lua and tagcontext.lua; both had drifted
-- (missing ASSERT) AND both wrongly listed FILE/MACRO as openers — which are units but have NO closer,
-- so enclosing_block scanned whole buffers for a nonexistent [END_FILE] and returned nil. Deriving the
-- `closable` column fixes that class at the source (D-384). This module is the ONE consumer seam:
-- there is deliberately NO bundled fallback copy (a copy would re-create the Class-18 mirror the
-- cutover deletes — foxtag is the core, not an optional dependency).
--
-- Unavailable foxtag is handled as ERROR HANDLING, not a fallback: silent probe, then a one-keypress
-- heal at point of use (build -> refresh -> retry). Never a silent auto-build (an editor spawning g++
-- unasked breaks the flag-not-auto rule the toolchain enforces everywhere else).
--
--   setup(opts)          -- config + async warm probe (opts.foxtag_bin optional)
--   model()              -> { closable = {T=bool}, openers = {T=true}, meta = {...} } | nil
--   is_unit(t) / closable(t) / scope_openers()
--   available()          -> bool
--   staleness()          -> nil | { derived_at, repo_at, version, toolchain_version }
--   heal(retry)          -- point-of-use prompt -> build -> refresh -> retry()
--   refresh(cb)          -- force re-probe (NEVER caches a permanent failure)
local M = {}

local cfg = { foxtag_bin = nil, engine_dirname = nil }
local cache = nil -- { closable, openers, meta } — nil means "not primed / unavailable"

-- Negative-probe throttle. `model()` is called PER TOKEN by tag_grammar_adapter.parse, and a failed
-- fetch is deliberately never cached (foxtag built after attach must recover with no restart). Without
-- a cooldown those two facts combine badly: a PRESENT-but-BROKEN foxtag would re-spawn a subprocess —
-- with the 2s bounded wait — on every token, freezing the editor. The cooldown keeps "never cache a
-- PERMANENT failure" (it re-probes after the window) while making a storm impossible. `refresh()`
-- clears it so an explicit heal retries immediately.
local MISS_COOLDOWN_MS = 3000
local last_miss = 0
local function now_ms() return (vim.uv or vim.loop).now() end

-- ── discovery ────────────────────────────────────────────────────────────────
-- opts.foxtag_bin -> PATH -> script-relative anchor LAST. The anchor is a last resort ONLY: this
-- plugin is publishable and documents a remote lazy.nvim install (README), which clones it far away
-- from any sibling tools/foxtag/ tree — so an anchor-first design would be a silent break there.
local function anchor_guess()
  -- ":p" FIRST — when the module is loaded via a relative package.path (e.g. "./lua/?.lua" in the
  -- headless test/parity harness) `source` is relative, and walking parents off it lands nowhere.
  local src = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p")
  local plugin_root = vim.fn.fnamemodify(src, ":h:h:h")           -- .../fox-symdeps.nvim
  return vim.fn.fnamemodify(plugin_root, ":h:h") .. "/foxtag/foxtag" -- .../tools/foxtag/foxtag
end

function M.bin()
  if cfg.foxtag_bin and cfg.foxtag_bin ~= "" and vim.fn.executable(cfg.foxtag_bin) == 1 then
    return cfg.foxtag_bin
  end
  local onpath = vim.fn.exepath("foxtag")
  if onpath ~= "" then return onpath end
  local a = anchor_guess()
  if vim.fn.executable(a) == 1 then return a end
  return nil
end

-- The ENGINE root — `Version.hpp` is the marker (same shape check foxroots.py / parity_check.sh use).
-- foxtag must be RUN from here: it resolves the corpus relative to cwd, so inheriting nvim's cwd makes
-- it fail with "cannot resolve the engine root". Resolution is deliberately marker-based rather than
-- "walk up N from the binary", because `tools/` is a SYMLINK into the workspace — a path walk off the
-- binary lands in the workspace, which has no Version.hpp (Landmine 5).
local function has_marker(d) return d ~= "" and vim.fn.filereadable(d .. "/Version.hpp") == 1 end

-- Walk up from `start`, testing each level as the engine root AND as a sibling of one. The sibling
-- probe is what recovers the symlink case: the physical plugin path lives under the WORKSPACE, whose
-- own parent holds the engine checkout beside it (the foxroots.py sibling-recovery convention).
local function walk_up(start)
  local d = vim.fn.fnamemodify(start or "", ":p:h")
  for _ = 1, 12 do
    if has_marker(d) then return d end
    -- `engine_dirname` is the escape hatch: the default is this workspace's engine checkout name, but
    -- a hardcoded repo name has no business being load-bearing in a PUBLISHABLE plugin, so it is an
    -- opt. (Env `FOXML_ENGINE` and the cwd walk-up both take precedence; this is the last resort.)
    local sib = vim.fn.fnamemodify(d, ":h") .. "/" .. (cfg.engine_dirname or "FoxML_Trader_v2")
    if has_marker(sib) then return sib end
    local up = vim.fn.fnamemodify(d, ":h")
    if up == d or up == "" then break end
    d = up
  end
  return nil
end

local function engine_root(bin)
  local env = vim.env.FOXML_ENGINE
  if env and has_marker(env) then return env end
  return walk_up(vim.fn.getcwd()) or (bin and walk_up(bin)) or nil
end

local function root_of(bin) return engine_root(bin) end

-- ── envelope → model ─────────────────────────────────────────────────────────
local function decode(stdout)
  if not stdout or stdout == "" then return nil end
  local ok, env = pcall(vim.json.decode, stdout)
  if not ok or type(env) ~= "table" then return nil end
  -- kind gate (TD-258): a stale/wrong foxtag emitting a non-grammar/1 envelope degrades the tag
  -- layer LOUDLY-downstream (nil model → the checkhealth rebuild warning), never decodes wrong.
  if require("fox-symdeps.toolio_kinds").assert_consumed(env, "grammar/1") then return nil end
  local pay = env.payload and env.payload.unit_types
  if not (pay and pay.schema and pay.rows) then return nil end
  local ci = {}
  for i, col in ipairs(pay.schema) do ci[col] = i end
  if not (ci.name and ci.closable) then return nil end
  local closable, openers, n = {}, {}, 0
  for _, row in ipairs(pay.rows) do
    local nm, cl = row[ci.name], row[ci.closable]
    if type(nm) == "string" then
      closable[nm] = cl and true or false
      if cl then openers[nm] = true end
      n = n + 1
    end
  end
  if n == 0 then return nil end
  -- fleet K3: decode the four previously-unclaimed vocab tables (the payload always carried
  -- them; only unit_types was read). Name-column sets; a missing/empty table decodes to nil.
  local function names_of(tbl)
    local t = env.payload and env.payload[tbl]
    if not (t and t.schema and t.rows) then return nil end
    local nci
    for i, col in ipairs(t.schema) do
      if col == "name" then nci = i break end
    end
    if not nci then return nil end
    local set, k = {}, 0
    for _, row in ipairs(t.rows) do
      if type(row[nci]) == "string" then set[row[nci]] = true; k = k + 1 end
    end
    return k > 0 and set or nil
  end
  return {
    closable = closable,
    openers = openers,
    vocab = {
      ref_subcats = names_of("ref_subcats"),
      categories  = names_of("categories"),
      concern     = names_of("concern"),
      surface     = names_of("surface"),
    },
    meta = {
      git_head = env.target and env.target.git_head,
      version = env.producer and env.producer.version,
      schema_version = env.schema_version,
      count = n,
    },
  }
end

-- ── fetch ────────────────────────────────────────────────────────────────────
local function argv(bin) return { bin, "grammar", "--json" } end

-- Async probe (setup warm path). Never caches a failure: on failure `cache` simply stays nil, so the
-- next call re-probes — foxtag built AFTER nvim attached recovers with no restart.
local function fetch_async(cb)
  local bin = M.bin()
  if not bin then return cb and cb(nil) end
  require("fox-symdeps.runner").run(argv(bin), engine_root(bin), function(lines)
    local m = lines and decode(table.concat(lines, "\n")) or nil
    if m then m.meta.bin = bin; cache = m end
    if cb then cb(m) end
  end)
end

-- Bounded synchronous fetch — the guarantee for enclosing_block, which is called inline and cannot
-- await. `grammar` is a static emit (two markdown parses, single-digit ms), so this is safe; the
-- setup warm probe means it virtually never actually runs.
local function fetch_sync()
  local bin = M.bin()
  if not bin then return nil end
  local ok, res = pcall(function()
    return vim.system(argv(bin), { text = true, cwd = engine_root(bin) }):wait(2000)
  end)
  if not ok or type(res) ~= "table" then return nil end
  local m = decode(res.stdout)
  if m then m.meta.bin = bin; cache = m end
  return m
end

-- ── public ───────────────────────────────────────────────────────────────────
function M.setup(opts)
  opts = opts or {}
  cfg.foxtag_bin = opts.foxtag_bin
  cfg.engine_dirname = opts.engine_dirname
  cache, last_miss = nil, 0
  pcall(fetch_async, nil) -- silent warm probe; no boot-time nagging on failure
end

--- Vocab sets from the grammar payload (fleet K3) — nil when foxtag is unavailable.
function M.vocab()
  local m = M.model()
  return m and m.vocab or nil
end

--- Set of LOWERCASED unit-type names — the gating axis actions.lua `types` keys validate
--- against (§9's "cite your axis or it does not belong", made mechanical). nil sans model.
function M.unit_types()
  local m = M.model()
  if not m then return nil end
  local t = {}
  for nm in pairs(m.closable) do t[nm:lower()] = true end
  return t
end

--- The node model, or nil when foxtag is unavailable. Memoized; re-probes after a failure.
function M.model()
  if cache == false then return nil end -- test seam: forced-unavailable
  if cache then return cache end
  if now_ms() - last_miss < MISS_COOLDOWN_MS then return nil end -- throttle: no per-token respawn
  local m = fetch_sync()
  if not m then last_miss = now_ms() end
  return m
end

function M.available() return M.model() ~= nil end
function M.is_unit(t) local m = M.model(); return (m and t ~= nil) and m.closable[t] ~= nil or false end
function M.closable(t) local m = M.model(); return (m and t ~= nil) and m.closable[t] == true or false end

--- The set of types that OPEN a scannable scope — closable units only. A LIGHT unit (FILE/MACRO/
--- TEST/ASSERT) is a point marker with no [END_<TYPE>]; treating one as an opener is the live bug
--- this filter removes.
function M.scope_openers()
  local m = M.model()
  return m and m.openers or nil
end

function M.refresh(cb)
  cache = nil
  last_miss = 0 -- an explicit heal/refresh must retry NOW, never wait out the cooldown
  fetch_async(cb)
end

--- Staleness: the envelope records the HEAD it was produced at. A STALE binary still emits a
--- valid-looking envelope, so the plugin would be silently WRONG — detection is the only fix.
--- Returns nil when everything agrees OR when we cannot establish a comparison (no false alarms).
function M.staleness()
  local m = M.model()
  if not m then return nil end
  local root = root_of(m.meta.bin)
  if not root then return nil end
  local out = nil
  local head = M._repo_head(root)
  if head and m.meta.git_head and m.meta.git_head ~= "" and head ~= m.meta.git_head then
    out = out or {}; out.derived_at, out.repo_at = m.meta.git_head, head
  end
  local tv = M._toolchain_version(root)
  if tv and m.meta.version and tv ~= m.meta.version then
    out = out or {}; out.version, out.toolchain_version = m.meta.version, tv
  end
  return out
end

function M._repo_head(root)
  local h = (vim.fn.readfile(root .. "/.git/HEAD") or {})[1]
  if not h then return nil end
  local ref = h:match("^ref:%s*(%S+)")
  if not ref then return h:match("^(%x+)$") end
  local sha = (vim.fn.readfile(root .. "/.git/" .. ref) or {})[1] -- packed-refs → nil → no claim
  return sha and sha:match("^(%x+)")
end

function M._toolchain_version(root)
  local v = (vim.fn.readfile(root .. "/tools/TOOLCHAIN_VERSION") or {})[1]
  return v and vim.trim(v) or nil
end

--- One-keypress heal. Deliberately NOT a silent auto-build: building spawns a compiler, so the
--- operator confirms. On success: refresh the model and RETRY whatever the user was doing.
function M.heal(retry)
  local st = M.staleness()
  local prompt
  if st and st.derived_at then
    prompt = ("fox-symdeps · node-model derived at %s, repo at %s — rebuild foxtag?")
      :format(st.derived_at:sub(1, 8), st.repo_at:sub(1, 8))
  elseif st then
    prompt = ("fox-symdeps · foxtag %s vs TOOLCHAIN_VERSION %s — rebuild foxtag?")
      :format(tostring(st.version), tostring(st.toolchain_version))
  else
    prompt = "fox-symdeps · tag-nav needs foxtag (not built) — build it now?"
  end
  local bin = M.bin()
  local root = bin and root_of(bin) or nil
  local build = root and (root .. "/tools/foxtag/build.sh") or nil
  if not build or vim.fn.filereadable(build) ~= 1 then
    return require("fox-symdeps.ui").notify_raw(prompt:gsub("%?$", "") .. " — run: bash tools/foxtag/build.sh", vim.log.levels.WARN)
  end
  vim.ui.select({ "Build now", "Not now" }, { prompt = prompt }, function(choice)
    if choice ~= "Build now" then return end
    require("fox-symdeps.ui").notify_raw("fox-symdeps · building foxtag…", vim.log.levels.INFO)
    require("fox-symdeps.runner").run({ "bash", build }, root, function(lines)
      if lines == nil then
        return require("fox-symdeps.ui").notify_raw("fox-symdeps · foxtag build FAILED — run `bash tools/foxtag/build.sh` to see why",
          vim.log.levels.ERROR)
      end
      M.refresh(function(m)
        if not m then
          return require("fox-symdeps.ui").notify_raw("fox-symdeps · built, but the node-model still won't load", vim.log.levels.ERROR)
        end
        require("fox-symdeps.ui").notify_raw(("fox-symdeps · foxtag rebuilt · node-model refreshed (%d types)"):format(m.meta.count),
          vim.log.levels.INFO)
        if type(retry) == "function" then pcall(retry) end
      end)
    end)
  end)
end

--- Test seam — exercise the closable filter without a foxtag binary.
---   _inject(tbl)   use this model      ·  _inject(false) force "unavailable" (no probe)
---   _inject(nil)   clear the cache (a real probe may then run, as in normal operation)
function M._inject(m) cache = m end

return M
