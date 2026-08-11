-- actions.lua — the context-aware action registry behind the palette (:FoxSymdepsMenu / <leader>dm).
--
-- Each row declares WHICH unit types it applies to; the palette resolves the tag [TYPE] from the
-- cursor's enclosing block (tagcontext) and shows only the matching actions. Add a capability =
-- add ONE row — X-macro-registry-shaped, the codebase's own framework discipline applied to the UX.
-- The tag system does the hard part (which unit · what type); this is a thin router to the ops that
-- already exist as the <leader>d* functions.
local M = {}

local function pal() return require("fox-symdeps").config.palette end

-- `all = true` → every unit type. Else `types = { ["function"]=true, struct=true, … }` — the
-- LOWERCASED tag type ("function"/"struct"/"registry"/"file"). ("function" is a keyword → bracket key.)
M.registry = {
  -- universal — any unit
  { label = "Symbol HUD — layout · uses · calls · trace", all = true,
    run = function() require("fox-symdeps").inspect_cursor() end },
  { label = "Board — ADD this unit's card (accumulates; s in-board compares)", all = true,
    run = function() require("fox-symdeps.panel").add(pal()) end },
  { label = "Follow card — auto-follows the enclosing unit", all = true,
    run = function() require("fox-symdeps.followcard").toggle(pal()) end },
  { label = "Board — compare two cards side-by-side", all = true,
    when = function()
      local ok, pnl = pcall(require, "fox-symdeps.panel")
      return ok and pnl.is_open() and pnl._count() >= 2
    end,
    run = function() require("fox-symdeps.panel").compare() end },
  { label = "Preview derived facts", all = true,
    run = function() vim.cmd("FoxSymdepsDerived") end },
  { label = "Docs — [REFERENCE] → open the defining doc (float beside code)", all = true,
    -- context-gated (§6's rule): shown only when the enclosing unit actually carries the
    -- [REFERENCE] axis this affordance renders (§9's law)
    when = function()
      local buf = vim.api.nvim_get_current_buf()
      local row0 = vim.api.nvim_win_get_cursor(0)[1] - 1
      local ok, tc = pcall(require, "fox-symdeps.tagcontext")
      if not ok then return false end
      local blk = tc.enclosing_block(buf, row0)
      if blk then
        for _, l in ipairs(vim.api.nvim_buf_get_lines(buf, blk.opener, blk.closer + 1, false)) do
          if l:find("[REFERENCE]_", 1, true) then return true end
        end
      end
      -- FILE-header fallback (macros / file-scope / units without refs)
      local okd, dv = pcall(require, "fox-symdeps.docview")
      return okd and #dv.file_header_ids(buf) > 0
    end,
    run = function() require("fox-symdeps.docview").open() end },
  -- function
  { label = "Write [DERIVED] call-graph in place (+ save)", types = { ["function"] = true, struct = true },
    writes = "comments", -- T6: tag-comments only, never logic — the ✎ tier
    run = function() vim.cmd("FoxSymdepsDerived!") end },
  { label = "Source ↔ ASM explorer", types = { ["function"] = true },
    run = function() require("fox-symdeps.asmexplorer").open(pal()) end },
  { label = "Branch tags (data-dependent ▲)", types = { ["function"] = true },
    run = function() require("fox-symdeps.branchtag").toggle() end },
  -- struct
  { label = "Cache-straddle diagnostics", types = { struct = true },
    run = function() require("fox-symdeps.diagnostics").toggle() end },
  { label = "Ambient layout lens (inline size)", types = { struct = true },
    run = function() require("fox-symdeps.ambient").toggle() end },
  { label = "Lock layout — insert static_assert(sizeof/alignof)", types = { struct = true },
    writes = "code", -- inserts a SOURCE line (the one sanctioned code-writer) — the ⚠ tier
    run = function() require("fox-symdeps.assertion").insert() end },
}

-- filter the registry for a lowercased tag type; "" (not in a block) → the universal actions only.
-- An optional per-item `when()` gate adds RUNTIME context-gating (§6: "the menu shows only what's
-- valid") — e.g. compare only lists once the board holds 2+ cards. pcall-safe: a broken gate hides
-- its item rather than breaking the menu.
function M.for_type(t)
  local out = {}
  for _, a in ipairs(M.registry) do
    if a.all or (a.types and a.types[t]) then
      local visible = true
      if a.when then
        local ok, v = pcall(a.when)
        visible = ok and v or false
      end
      if visible then out[#out + 1] = a end
    end
  end
  return out
end

return M
