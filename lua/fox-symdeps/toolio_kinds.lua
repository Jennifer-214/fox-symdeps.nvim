-- toolio_kinds.lua — the plugin-side PAYLOAD-KIND registry (the TD-258 data-enumeration half).
--
-- The Python-side truth is tools/lib/toolio_schemas.json (toolio.py reads it, never hardcodes —
-- D-380/D-384). This table is the Lua-side enumeration of WHICH envelope kinds this plugin can
-- actually render, and M.compare() is what keeps the pair honest: a NEW producer kind with no
-- plugin surface shows up in :checkhealth as missing-consumer instead of being silently absent
-- (TD-258 / the advertised-capability-never-exercised shape). Add a consumer = add ONE row here —
-- X-macro-registry-shaped, same discipline as actions.lua.
local M = {}

-- full payload_schema_version key → who renders it. One row per consumed kind.
-- ⚠ SHAPE CONTRACT: the repo-floor tool (tools/check_toolio_kind_parity.py) parses this block
-- strictly — one ["kind/N"] key per line, closing `}` at column 0. Reshaping it REDs the floor
-- with a named parse-refusal (deliberate: an unparseable registry must never pass as empty).
M.consumed = {
  ["grammar/1"]       = { consumer = "nodemodel", what = "foxtag grammar --json → the tag node model (0.3)" },
  ["defining_site/1"] = { consumer = "docview",   what = "citable_ids --where → [REFERENCE] defining-site floats (0.4)" },
  ["cited_path/1"]    = { consumer = "docview",   what = "citable_ids --resolve → doc-shaped [REFERENCE] resolution + dead-link check (0.4)" },
}

-- registry keys that are NOT renderable payload kinds, with the reason (toolio.py's own vocab).
-- A stale exemption (key gone from the registry) is flagged as drift too — shrink-only spirit.
M.exempt = {
  ["findings/1"] = "envelope-level status.findings schema shared by every kind (D-384) — not a payload",
  ["compile_command/1"] = "producer-first (compile_command.py, TD-257 substrate) — the asm/layout card view rides 0.5; flip to a consumed row when it lands",
}

-- Pure compare core (the teeth hit this directly; parity() feeds it the live registry).
-- registry_keys = list of non-underscore json keys. Empty result tables = parity holds.
function M.compare(registry_keys, consumed, exempt)
  local inreg, missing, unknown = {}, {}, {}
  for _, k in ipairs(registry_keys) do
    inreg[k] = true
    if not consumed[k] and not exempt[k] then missing[#missing + 1] = k end
  end
  for k in pairs(consumed) do
    if not inreg[k] then unknown[#unknown + 1] = k end
  end
  for k in pairs(exempt) do
    if not inreg[k] then unknown[#unknown + 1] = k .. " (exempt row)" end
  end
  table.sort(missing); table.sort(unknown)
  return { missing_consumer = missing, unknown_kind = unknown }
end

-- Runtime seam (TD-258 half 2 — the table is LOAD-BEARING, not documentation): a consumer names
-- the kind it expects; the envelope must carry it AND the registry row must exist (a consumer
-- reading an unregistered kind = this table rotted). Returns nil when fine, else a short reason
-- the caller folds into its refusal message — never a silent nil-rows.
function M.assert_consumed(env, want)
  if not M.consumed[want] then
    return ("plugin consumes '%s' with no toolio_kinds row — registry rot"):format(want)
  end
  local got = env and env.payload_schema_version
  if got ~= want then
    return ("expected payload kind '%s', producer sent '%s' — fact-source mismatch"):format(want, tostring(got))
  end
  return nil
end

-- Read tools/lib/toolio_schemas.json under `root` (engine root) and compare against M.consumed.
-- TRI-STATE honest (Class 57): an unreadable/undecodable registry is a REFUSAL — never an
-- empty-parity "ok" (zero kinds found ≠ zero kinds drifted).
function M.parity(root)
  local path = root .. "/tools/lib/toolio_schemas.json"
  local f = io.open(path, "r")
  if not f then return { refusal = "toolio_schemas.json unreadable at " .. path } end
  local txt = f:read("*a"); f:close()
  local okd, data = pcall(vim.json.decode, txt)
  if not okd or type(data) ~= "table" then
    return { refusal = "toolio_schemas.json undecodable at " .. path }
  end
  local keys = {}
  for k in pairs(data) do
    if k:sub(1, 1) ~= "_" then keys[#keys + 1] = k end
  end
  table.sort(keys)
  local r = M.compare(keys, M.consumed, M.exempt)
  r.path, r.n_kinds = path, #keys
  return r
end

return M
