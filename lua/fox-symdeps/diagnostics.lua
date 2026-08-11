-- diagnostics.lua — surface analysis findings as vim.diagnostic entries so they show ambiently
-- (inline virtual text + gutter signs + Trouble/loclist), not just inside the HUD. Opt-in via
-- <leader>dg. Findings accumulate per buffer, keyed so re-inspecting a symbol replaces just its own
-- group. The first consumer is cache-line straddles; width-lits / others can join the same namespace.
local M = {}
local NS = vim.api.nvim_create_namespace("fox_symdeps")
local by_buf = {} -- bufnr -> { [key] = { diagnostic, ... } }

M.enabled = false

-- pure: which fields straddle a 64 B cache line. fields = { {name, offset, size}, ... }. Returns names.
function M.straddlers(fields)
  local out = {}
  for _, f in ipairs(fields or {}) do
    if f.offset and f.size and f.size > 0
      and math.floor(f.offset / 64) ~= math.floor((f.offset + f.size - 1) / 64) then
      out[#out + 1] = f.name or "?"
    end
  end
  return out
end

local function republish(bufnr)
  if not (bufnr and vim.api.nvim_buf_is_valid(bufnr)) then return end
  local all = {}
  for _, ds in pairs(by_buf[bufnr] or {}) do
    for _, d in ipairs(ds) do all[#all + 1] = d end
  end
  vim.diagnostic.set(NS, bufnr, all)
end

-- set the diagnostics for one group (key) in a buffer; other groups are preserved.
function M.set(bufnr, key, diags)
  by_buf[bufnr] = by_buf[bufnr] or {}
  by_buf[bufnr][key] = diags
  republish(bufnr)
end

function M.clear(bufnr)
  by_buf[bufnr] = nil
  if bufnr and vim.api.nvim_buf_is_valid(bufnr) then vim.diagnostic.reset(NS, bufnr) end
end

-- pure: the straddling field ITEMS (not just names) + where each crosses. Unit-testable.
function M._straddler_items(fields)
  local out = {}
  for _, f in ipairs(fields or {}) do
    if f.offset and f.size and f.size > 0 then
      local first_boundary = (math.floor(f.offset / 64) + 1) * 64
      if f.offset + f.size > first_boundary then
        out[#out + 1] = { field = f, boundary = first_boundary,
                          over = f.offset + f.size - first_boundary }
      end
    end
  end
  return out
end

-- publish cache-line straddle findings for a struct inspected at `ctx` (fields = its layout field
-- list). IDE-humanization (operator, 2026-08-09): the old form was ONE summary diagnostic on the
-- struct's declaration naming the fields — it said THAT and WHO, never WHERE. Now each straddling
-- field gets a WARN on ITS OWN LINE (layout items carry lnum since the same change), with the
-- boundary math in the message; the declaration keeps a summary so the count is visible even when
-- the fields are scrolled off-screen.
function M.struct_layout(ctx, fields)
  if not M.enabled or not ctx or ctx.kind == "function" or not ctx.bufnr then return end
  local key = "layout:" .. (ctx.symbol or "?")
  local bad = M._straddler_items(fields)
  if #bad == 0 then return M.set(ctx.bufnr, key, {}) end
  local diags = {}
  local names = {}
  for _, s in ipairs(bad) do
    names[#names + 1] = s.field.name
    if s.field.lnum then
      diags[#diags + 1] = {
        lnum = s.field.lnum, col = s.field.col or 0,
        severity = vim.diagnostic.severity.WARN,
        source = "fox-symdeps",
        message = ("%s straddles the %d-byte cache-line boundary (offset %d, size %d — %d byte(s) past line %d)")
          :format(s.field.name, s.boundary, s.field.offset, s.field.size, s.over, s.boundary / 64),
      }
    end
  end
  diags[#diags + 1] = {
    lnum = (ctx.line or 1) - 1,
    col = ctx.col or 0,
    severity = vim.diagnostic.severity.WARN,
    source = "fox-symdeps",
    message = ("%s: %d field(s) straddle a cache line — %s"):format(ctx.symbol or "?", #bad, table.concat(names, ", ")),
  }
  M.set(ctx.bufnr, key, diags)
end

function M.toggle()
  M.enabled = not M.enabled
  if not M.enabled then
    for b in pairs(by_buf) do
      if vim.api.nvim_buf_is_valid(b) then vim.diagnostic.reset(NS, b) end
    end
    by_buf = {}
  end
  require("fox-symdeps.ui").notify_raw("fox-symdeps · straddle diagnostics " ..
    (M.enabled and "ON (inspect a struct to populate)" or "off"), vim.log.levels.INFO)
end

return M
