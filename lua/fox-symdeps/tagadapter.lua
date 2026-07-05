-- tagadapter.lua — the SEAM for the [TAG]_ comment scheme. This NULL adapter is the swap-later hook:
-- when the grammar is codified in the workspace, call M.install{...} with real functions and everything
-- downstream (the derived-tag generator + drift-verifier) lights up — with NO changes anywhere else.
-- Until then it no-ops, so the plugin runs standalone. See DOCS/TAG-INTEGRATION.md.
--
-- Interface (pure; comment-string ↔ the facts.derived() record):
--   parse(block_text)     -> tags | nil        parse a comment block's tags (nil = block isn't tagged)
--   format_derived(facts) -> { lines } | nil    render facts.derived() as [DERIVED] comment lines (nil
--                                               = no adapter → caller falls back to a raw-facts view)
--   verify(tags, facts)   -> { drift, ... }      compare parsed tags vs live facts → drift findings
local M = {}

M.available = false -- flips true once a real adapter is installed

function M.parse(_block_text) return nil end
function M.format_derived(_facts) return nil end
function M.verify(_tags, _facts) return {} end

-- install a real adapter (the tag layer calls this ONCE its grammar exists). Single swap point:
-- no downstream code changes — facts.lua, the :FoxSymdepsDerived preview, and any future drift
-- diagnostic all route through these functions.
function M.install(adapter)
  if type(adapter) ~= "table" then return end
  M.parse = adapter.parse or M.parse
  M.format_derived = adapter.format_derived or M.format_derived
  M.verify = adapter.verify or M.verify
  M.available = true
end

return M
