-- lenses/docs_refs.lua — CURATED-FIRST Docs (operator polish #1, 2026-08-10): the unit's
-- `[REFERENCE]` entries as an always-on HUD section — the ids that GOVERN this unit, signal
-- before haystack (the 473-hit mention SWEEP stays the on-demand heavy path via `n`). Zero
-- subprocess cost: entries parse from the buffer's tag lines; RESOLUTION stays in docview
-- (menu → Docs), which floats/pins the defining doc.
local lens = require("fox-symdeps.lens")

lens.define{
  name = "docs_refs",
  applies = function(ctx) return ctx ~= nil and ctx.bufnr ~= nil end,
  render = function(ctx, hud)
    local okt, tc = pcall(require, "fox-symdeps.tagcontext")
    local okd, dv = pcall(require, "fox-symdeps.docview")
    if not (okt and okd) then return end
    local entries = {}
    local blk = ctx.line and tc.enclosing_block(ctx.bufnr, ctx.line - 1) or nil
    if blk then
      local lines = vim.api.nvim_buf_get_lines(ctx.bufnr, blk.opener, blk.closer + 1, false)
      entries = dv.ref_entries(lines)
    end
    if #entries == 0 then entries = dv.file_header_ids(ctx.bufnr) end
    if #entries == 0 then return end   -- self-gates silent; nothing curated here
    local by, order = {}, {}
    for _, e in ipairs(entries) do
      if not by[e.subcat] then by[e.subcat] = {}; order[#order + 1] = e.subcat end
      by[e.subcat][#by[e.subcat] + 1] = e.id
    end
    local parts = {}
    for _, s in ipairs(order) do
      parts[#parts + 1] = ("%s %s"):format(s:lower(), table.concat(by[s], " "))
    end
    hud:set_section("docs_refs",
      ("◆ Docs — governs this unit (%d)  ·  open: m → Docs"):format(#entries),
      { { label = table.concat(parts, "  ·  "), role = "docs", count = 0,
          collapsed = true, files = {} } }, "ok")
  end,
}
