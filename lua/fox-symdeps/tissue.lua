-- tissue.lua — the COMPARE pair's connective tissue (north-star §6: "the value is the
-- connective tissue between them" — NEW PRESENTATION, not new analysis). Computed from facts
-- the cards already fetched plus one cheap sync grep:
--   · EMBEDDING — does A carry a field of type B (or B of A)? From the PARENT's own field
--     list: which field, its offset/size, WHICH 64B cache lines of the parent it occupies,
--     and whether it straddles INSIDE the parent — the H6 read a plain side-by-side can't show.
--   · CO-INCLUDERS — files that #include BOTH defining headers (includers.of ∩) — the honest,
--     alias-proof coupling breadth (same rationale as the Includers section).
-- Renders as the companion card's "⋈ Between" section, expanded by default — it is the point
-- of comparing; every other section keeps the collapsed-by-default law.
local M = {}

-- pure: does `fields` (the parent's field list) carry a field whose TYPE names `sym`?
-- Word-boundary match on the type string ("Money" must never match "MoneyPair" — the same
-- never-substring lesson the asm name-matcher learned). Returns
-- { name, offset, size, lo, hi, straddle } | nil.
function M.embedding(fields, sym)
  if not (fields and sym) or sym == "" then return nil end
  for _, f in ipairs(fields) do
    local ty = f.type or ""
    local s, e = ty:find(sym, 1, true)
    while s do
      local before = s == 1 and "" or ty:sub(s - 1, s - 1)
      local after = ty:sub(e + 1, e + 1)
      if not before:match("[%w_]") and not after:match("[%w_]") then
        local off = f.offset or 0
        local lo = math.floor(off / 64)
        local hi = math.floor((off + math.max(f.size or 1, 1) - 1) / 64)
        return { name = f.name, offset = off, size = f.size or 0,
                 lo = lo, hi = hi, straddle = lo ~= hi }
      end
      s, e = ty:find(sym, e + 1, true)
    end
  end
  return nil
end

-- pure: two includer lists ({ {file, line}, … }) → sorted files present in BOTH, deduped.
function M.co_includers(incA, incB)
  local a, seen, out = {}, {}, {}
  for _, r in ipairs(incA or {}) do a[r.file] = true end
  for _, r in ipairs(incB or {}) do
    if a[r.file] and not seen[r.file] then seen[r.file] = true; out[#out + 1] = r.file end
  end
  table.sort(out)
  return out
end

-- pure: assemble the section's display lines from the computed facts. Honest empty states —
-- "no direct embedding" / "no files include both" are findings, never blanks.
function M.lines(symA, symB, embAB, embBA, co)
  local L = {}
  local function emb(parent, child, e)
    if not e then return end
    L[#L + 1] = ("%s ⊃ %s — field %s @%d · %dB · L%d%s"):format(
      parent, child, e.name or "?", e.offset, e.size, e.lo,
      e.straddle and ("–" .. e.hi .. "  ▲ straddles inside " .. parent) or " (one line)")
  end
  emb(symA, symB, embAB)
  emb(symB, symA, embBA)
  if #L == 0 then
    L[#L + 1] = ("no direct embedding between %s and %s"):format(symA or "?", symB or "?")
  end
  if co and #co > 0 then
    local names = {}
    for i = 1, math.min(#co, 5) do names[#names + 1] = vim.fn.fnamemodify(co[i], ":t") end
    L[#L + 1] = ("co-included by %d file%s: %s%s"):format(
      #co, #co == 1 and "" or "s", table.concat(names, " "), #co > 5 and " …" or "")
  else
    L[#L + 1] = "no files include both defining headers"
  end
  return L
end

-- impure: compute the pair's tissue lines. `fieldsA`/`fieldsB` may be nil (function cards /
-- unresolved layouts) — embedding just skips; co-includers is a sync grep (headless-safe).
function M.between(ctxA, ctxB, fieldsA, fieldsB, root)
  local inc = require("fox-symdeps.includers")
  local incA = inc.of((ctxA or {}).symbol, root) or {}
  local incB = inc.of((ctxB or {}).symbol, root) or {}
  return M.lines((ctxA or {}).symbol or "?", (ctxB or {}).symbol or "?",
    M.embedding(fieldsA, (ctxB or {}).symbol), M.embedding(fieldsB, (ctxA or {}).symbol),
    M.co_includers(incA, incB))
end

return M
