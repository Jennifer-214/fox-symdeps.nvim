-- asmview.lua — W15 render: the flag-diff for a function, presented as what it actually is — an
-- A-vs-B COMPARISON. A metric table up top (instructions / branches / simd, with the delta and a
-- branchless verdict) makes the codegen difference legible at a glance; the two asm listings follow,
-- numbered, with conditional-branch lines glowing (a branch on a branchless hot path is the alarm).
-- q closes; f re-picks the flag-sets and re-runs.
local M = {}
local NS = vim.api.nvim_create_namespace("fox_symdeps_asm")

local COND = { je = 1, jne = 1, jz = 1, jnz = 1, jg = 1, jge = 1, jl = 1, jle = 1, ja = 1, jae = 1,
  jb = 1, jbe = 1, js = 1, jns = 1, jo = 1, jno = 1, jp = 1, jnp = 1, jc = 1, jnc = 1 }

-- nil when a result carries real metrics; otherwise a short reason the column can't compare.
local function status(r)
  if not r then return "(unavailable)" end
  if r.inlined then return "inlined — no standalone body" end
  if not r.insns then return r.error or "unavailable" end
  return nil
end
M._status = status

-- pad `s` to display-width `w` (unicode-aware, so ✓/▲/─ don't skew the columns).
local function pad(s, w)
  return s .. string.rep(" ", math.max(1, w - vim.fn.strdisplaywidth(s)))
end

-- instructions cell with a signed delta vs the other column (−12 / +3), using a real minus glyph.
local function ins_cell(r, other)
  if status(r) then return "—" end
  local d = (other and not status(other)) and (r.insns - other.insns) or nil
  local delta = (d and d ~= 0) and ("  (" .. (d > 0 and "+" or "−") .. math.abs(d) .. ")") or ""
  return tostring(r.insns) .. delta
end
M._ins_cell = ins_cell

local function br_cell(r)
  if status(r) then return "—" end
  local n = r.cond_branches or 0
  if n == 0 then return "0  branchless ✓" end
  local d = r.data_branches or 0
  return ("%d · %d data-dep%s"):format(n, d, d > 0 and " ▲" or "")
end

local function vec_cell(r)
  if status(r) then return "—" end
  return r.vector and "vectorized" or "scalar"
end

local function cmov_cell(r)
  if status(r) then return "—" end
  return tostring(r.cmov or 0) .. ((r.cmov or 0) > 0 and "  branchless moves ✓" or "")
end

-- show(fn, a, b, ra, rb, rerun): a/b = {name,flags}; ra/rb = analyze results; rerun = fn to re-run.
function M.show(fn, a, b, ra, rb, rerun)
  local lines, hls = {}, {}
  local function add(t, hl) lines[#lines + 1] = t; if hl then hls[#lines] = hl end end
  local LW, CW = 14, 22 -- metric-label width · per-column width

  add(" ◆ asm flag-diff", "FoxSymdepsTitle")
  add("   " .. fn, "FoxSymdepsHeader")
  add("   isolated compile · no LTO · indicative, not the final binary", "FoxSymdepsBadge")
  add("")

  -- comparison table: header row (flag-set names) then one row per metric
  add("   " .. pad("", LW) .. pad(a.name, CW) .. b.name, "FoxSymdepsHeader")
  -- first column is the reference (no delta); the second carries the signed delta vs it.
  add("   " .. pad("instructions", LW) .. pad(ins_cell(ra, nil), CW) .. ins_cell(rb, ra), "FoxSymdepsBadge")
  -- the alarm is DATA-DEPENDENT branches (the mispredict risk), not benign loop/constant branches.
  local br_alarm = (ra and (ra.data_branches or 0) > 0) or (rb and (rb.data_branches or 0) > 0)
  add("   " .. pad("branches", LW) .. pad(br_cell(ra), CW) .. br_cell(rb),
    br_alarm and "FoxSymdepsAlarm" or "FoxSymdepsBadge")
  add("   " .. pad("cmov", LW) .. pad(cmov_cell(ra), CW) .. cmov_cell(rb), "FoxSymdepsBadge")
  add("   " .. pad("simd", LW) .. pad(vec_cell(ra), CW) .. vec_cell(rb), "FoxSymdepsBadge")
  local sa, sb = status(ra), status(rb)
  if sa then add("   " .. pad("", LW) .. a.name .. ": " .. sa, "FoxSymdepsBadge") end
  if sb then add("   " .. pad("", LW) .. b.name .. ": " .. sb, "FoxSymdepsBadge") end
  add("")

  -- the two listings, numbered, conditional branches glowing
  local function dump(name, r)
    add("── " .. name .. " " .. string.rep("─", math.max(3, 46 - vim.fn.strdisplaywidth(name))), "FoxSymdepsHeader")
    if not r or r.inlined then
      add("   (inlined at this opt level — nothing to list)", "FoxSymdepsBadge")
    elseif not r.insns then
      add("   " .. (r.error or "(unavailable — compile failed?)"),
        r.error and "FoxSymdepsAlarm" or "FoxSymdepsBadge")
    else
      for i, l in ipairs(r.lines_shown or {}) do
        local op = l:match("^([%w]+)")
        add(("   %3d  %s"):format(i, l), op and COND[op] and "FoxSymdepsAlarm" or "FoxSymdepsBadge")
      end
    end
    add("")
  end
  dump(a.name, ra)
  dump(b.name, rb)
  add("   q close · f re-pick flag-sets", "FoxSymdepsBadge")

  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden = "wipe"
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  vim.bo[buf].filetype = "fox-symdeps-asm"
  for ln, hl in pairs(hls) do
    vim.api.nvim_buf_set_extmark(buf, NS, ln - 1, 0, { line_hl_group = hl })
  end
  local win = vim.api.nvim_open_win(buf, true, { split = "below", height = math.min(#lines + 1, 26) })
  vim.wo[win].winbar = "%#FoxSymdepsTitle# asm · " .. fn .. " %*"
  vim.wo[win].winhighlight = "Normal:FoxSymdepsNormal"
  vim.wo[win].winblend = 0
  vim.wo[win].wrap = true
  vim.wo[win].cursorline = false
  vim.keymap.set("n", "q", function() pcall(vim.api.nvim_win_close, win, true) end, { buffer = buf, nowait = true })
  if rerun then
    vim.keymap.set("n", "f", function() pcall(vim.api.nvim_win_close, win, true); rerun() end, { buffer = buf, nowait = true })
  end
  return buf
end

return M
