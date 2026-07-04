-- asmview.lua — W15 render: a scratch split showing the flag-diff for a function. Summary line per
-- flag-set (insns / branches + branchless verdict / vector), then the two asm listings stacked with
-- conditional-branch lines glowing RED (a branch on a branchless hot path is the alarm). q closes;
-- f re-picks the flag-sets and re-runs.
local M = {}
local NS = vim.api.nvim_create_namespace("fox_symdeps_asm")

local COND = { je = 1, jne = 1, jz = 1, jnz = 1, jg = 1, jge = 1, jl = 1, jle = 1, ja = 1, jae = 1,
  jb = 1, jbe = 1, js = 1, jns = 1, jo = 1, jno = 1, jp = 1, jnp = 1, jc = 1, jnc = 1 }

local function summary(name, r)
  if not r or r.inlined then return ("  [%s]  (inlined / no standalone body)"):format(name) end
  if not r.insns then return ("  [%s]  %s"):format(name, r.error or "(unavailable)") end
  return ("  [%s]  insns %d · branches %d %s · %s"):format(
    name, r.insns, r.cond_branches or 0,
    (r.branchless and "(branchless ✓)" or "(has branches ▲)"),
    (r.vector and "vectorized" or "scalar"))
end

-- show(fn, a, b, ra, rb, rerun): a/b = {name,flags}; ra/rb = analyze results; rerun = fn to re-run.
function M.show(fn, a, b, ra, rb, rerun)
  local lines, hls = {}, {} -- hls[lineidx] = hlgroup
  local function add(t, hl) lines[#lines + 1] = t; if hl then hls[#lines] = hl end end
  add("asm flag-diff · " .. fn, "FoxSymdepsTitle")
  add("  isolated compile · no LTO · indicative, not the final binary", "FoxSymdepsBadge")
  add(summary(a.name, ra), ra and ra.branchless == false and "FoxSymdepsAlarm" or "FoxSymdepsBadge")
  add(summary(b.name, rb), rb and rb.branchless == false and "FoxSymdepsAlarm" or "FoxSymdepsBadge")
  add("")
  local function dump(name, r)
    add("── " .. name .. " ──", "FoxSymdepsHeader")
    if r and r.inlined then add("   (inlined at this opt level)", "FoxSymdepsBadge")
    elseif not (r and r.insns) then
      add("   " .. ((r and r.error) or "(unavailable — compile failed?)"),
        (r and r.error) and "FoxSymdepsAlarm" or "FoxSymdepsBadge")
    else
      for _, l in ipairs(r.lines_shown or {}) do
        local op = l:match("^([%w]+)")
        add("   " .. l, op and COND[op] and "FoxSymdepsAlarm" or "FoxSymdepsBadge")
      end
    end
    add("")
  end
  dump(a.name, ra)
  dump(b.name, rb)

  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden = "wipe"
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  vim.bo[buf].filetype = "fox-symdeps-asm"
  for ln, hl in pairs(hls) do
    vim.api.nvim_buf_set_extmark(buf, NS, ln - 1, 0, { line_hl_group = hl })
  end
  local win = vim.api.nvim_open_win(buf, true, { split = "below", height = math.min(#lines + 1, 24) })
  vim.wo[win].winhighlight = "Normal:FoxSymdepsNormal"
  vim.wo[win].winblend = 0
  vim.wo[win].wrap = true
  vim.keymap.set("n", "q", function() pcall(vim.api.nvim_win_close, win, true) end, { buffer = buf, nowait = true })
  if rerun then vim.keymap.set("n", "f", function() pcall(vim.api.nvim_win_close, win, true); rerun() end, { buffer = buf, nowait = true }) end
  return buf
end

return M
