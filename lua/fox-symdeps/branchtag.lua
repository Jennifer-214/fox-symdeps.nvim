-- branchtag.lua — inline data-dependent-branch tags on the SOURCE, read from the SHIPPED-asm
-- sidecars (build*/asm/*.asm, objdump -l of the linked binary — the D-419 honest basis). The
-- old buffer-compile basis could not work on this codebase: header/template functions emit
-- NOTHING in a standalone TU (ExecutionCore_Tick_Impl compiled to zero blocks), and the
-- verdict pass then painted "✓ branchless" on every function — the RC-E false-green, on the
-- hot tick function of a branchless-discipline engine. The sidecar has the REAL instantiations
-- with per-instruction source-line markers, costs no compile, and its `/path:line` rows map
-- data-dependent branches straight back to buffer lines. Non-destructive — extmarks only.
-- Opt-in (<leader>db); refreshes on save/enter (changedtick-guarded, one awk scan per refresh).
-- Basis caveat: verdicts describe the LAST BUILD; after source edits the marks re-anchor at
-- sidecar line numbers until a rebuild (the ON-notify names the basis binary + HEAD).
local M = {}
local NS = vim.api.nvim_create_namespace("fox_symdeps_branchtag")
local asmdiff = require("fox-symdeps.asmdiff")
local aug
M.enabled = false

-- pure: objdump -l text (any number of blocks) → (instrs, srclines) parallel lists.
-- srclines[i] = the source line of THIS file the instruction attributes to (0 = elsewhere:
-- an inlined-from-another-file run, or before any marker). Attribution rules:
--   `/abs/path:NNN` marker → current line if the path names the invoking buffer
--   (asmshipped.same_source — exact, or basename+parent across the workspace-symlink roots),
--   else 0 (never tag this file's lines with a foreign inline body);
--   `hex <sym>:` block header → reset to 0 (a block never inherits the previous block's line);
--   `name():` inline-context rows carry no line — the marker that follows them decides.
function M.parse_shipped(lines, src_abs)
  local asmshipped = require("fox-symdeps.asmshipped")
  local instrs, srclines, cur = {}, {}, 0
  for _, line in ipairs(lines or {}) do
    local path, ln = line:match("^(/[^:]+):(%d+)")
    if path then
      cur = asmshipped.same_source(path, src_abs) and tonumber(ln) or 0
    elseif line:match("^%x+ <") then
      cur = 0
    else
      local instr = line:match("^%s+%x+:\t(.+)$")
      if instr then
        instr = instr:gsub("%s*#.*$", "")
        if instr ~= "" then instrs[#instrs + 1] = instr; srclines[#srclines + 1] = cur end
      end
    end
  end
  return instrs, srclines
end

-- pure: per-line classification of every branch-shaped construct (operator asks 2026-08-18:
-- "show branchless ones as well" + "flag the statement AND the thing that's data dependent").
-- Returns sorted, de-duped line lists:
--   data    — lines with a data-dependent conditional branch (▲, the mispredict risk)
--   benign  — lines whose conditionals compare only registers/constants (△, loop bounds etc.)
--   cmov    — lines the compiler compiled BRANCHLESS via conditional moves (✓, the good codegen)
--   feeders — { {ln, branch}, … }: the MEMORY LOAD's line when it differs from its branch's
--             line — the "thing that's data dependent", flagged at its own statement
-- Precedence per line: data > benign > cmov (one chip per line); a feeder mark never lands on
-- a line that already carries a chip.
function M.line_classes(instrs, srclines)
  local bc = asmdiff.classify_branches(instrs)
  local data, benign, cmovl, feed = {}, {}, {}, {}
  for _, d in ipairs(bc.details or {}) do
    local ln = srclines[d.idx]
    if ln and ln > 0 then
      if d.data then
        data[ln] = true
        local fl = d.feeder and srclines[d.feeder]
        if fl and fl > 0 and fl ~= ln then feed[fl] = feed[fl] or ln end
      else
        benign[ln] = true
      end
    end
  end
  for _, i in ipairs(bc.cmovs or {}) do
    local ln = srclines[i]
    if ln and ln > 0 then cmovl[ln] = true end
  end
  local out = { data = {}, benign = {}, cmov = {}, feeders = {} }
  for ln in pairs(data) do out.data[#out.data + 1] = ln end
  for ln in pairs(benign) do if not data[ln] then out.benign[#out.benign + 1] = ln end end
  for ln in pairs(cmovl) do
    if not data[ln] and not benign[ln] then out.cmov[#out.cmov + 1] = ln end
  end
  for ln, br in pairs(feed) do
    if not (data[ln] or benign[ln] or cmovl[ln]) then
      out.feeders[#out.feeders + 1] = { ln = ln, branch = br }
    end
  end
  table.sort(out.data); table.sort(out.benign); table.sort(out.cmov)
  table.sort(out.feeders, function(a, b) return a.ln < b.ln end)
  return out
end

-- back-compat seam (older tests + any external caller): just the ▲ lines.
function M.data_lines(instrs, srclines)
  return M.line_classes(instrs, srclines).data
end

-- pure: per-function branch verdict. fns = { {lo, hi, sig}, ... } (1-based source ranges + the
-- signature line). Counts DISTINCT SOURCE LINES, not instructions — a hot header inlines into
-- many callers, and instruction-counting would report one source branch dozens of times.
-- Verdict: "branchless" (green — the hot-path ideal) · "branches" (yellow — has branches, none
-- data-dependent) · "data" (red — ≥1 data-dependent branch line, the mispredict risk) ·
-- "nocode" (dim — ZERO shipped instructions attribute to this function: not instantiated /
-- fully inlined-away; RC-E law: never green on nothing). Returns { {sig, verdict, nbr, ndata,
-- nins}, ... }.
function M.verdicts(instrs, srclines, fns)
  local bc = asmdiff.classify_branches(instrs)
  local det = bc.details or {}
  local out = {}
  for _, fn in ipairs(fns or {}) do
    local nins = 0
    for i = 1, #(instrs or {}) do
      local sl = srclines[i]
      if sl and sl >= fn.lo and sl <= fn.hi then nins = nins + 1 end
    end
    local brl, ddl, cml = {}, {}, {}
    for _, d in ipairs(det) do
      local sl = srclines[d.idx]
      if sl and sl >= fn.lo and sl <= fn.hi then
        brl[sl] = true
        if d.data then ddl[sl] = true end
      end
    end
    for _, i in ipairs(bc.cmovs or {}) do
      local sl = srclines[i]
      if sl and sl >= fn.lo and sl <= fn.hi then cml[sl] = true end
    end
    local nbr, ndata, ncmov = vim.tbl_count(brl), vim.tbl_count(ddl), vim.tbl_count(cml)
    local verdict = (nins == 0) and "nocode"
      or (nbr == 0) and "branchless"
      or (ndata > 0) and "data" or "branches"
    out[#out + 1] = { sig = fn.sig, verdict = verdict, nbr = nbr, ndata = ndata,
                      nins = nins, ncmov = ncmov }
  end
  return out
end

-- the 1-based { lo, hi, sig } range of every function_definition in the buffer (sig = the line the
-- verdict tag rides — the signature). treesitter; impure.
local function all_fn_ranges(bufnr)
  local ok, parser = pcall(vim.treesitter.get_parser, bufnr, "cpp")
  if not ok or not parser then return {} end
  local tree = parser:parse()[1]
  if not tree then return {} end
  local out = {}
  local function walk(node)
    if node:type() == "function_definition" then
      local sr, _, er = node:range()
      out[#out + 1] = { lo = sr + 1, hi = er + 1, sig = sr + 1 }
    end
    for c in node:iter_children() do walk(c) end
  end
  walk(tree:root())
  return out
end

local function apply(bufnr, classes, verdicts)
  if not (M.enabled and vim.api.nvim_buf_is_valid(bufnr)) then return end
  pcall(vim.api.nvim_set_hl, 0, "FoxSymdepsDim", { default = true, link = "Comment" })
  vim.api.nvim_buf_clear_namespace(bufnr, NS, 0, -1)
  local n = vim.api.nvim_buf_line_count(bufnr)
  local function mark(ln, text, hl)
    if ln <= n then
      pcall(vim.api.nvim_buf_set_extmark, bufnr, NS, ln - 1, 0, {
        virt_text = { { text, hl } }, virt_text_pos = "eol",
      })
    end
  end
  -- per-line marks, one chip per line (precedence lives in line_classes):
  -- ▲ the mispredict risk · △ benign reg/loop conditional · ✓ the compiler went branchless ·
  -- · the LOAD feeding a ▲ on another line (the "thing that's data dependent", at its statement)
  for _, ln in ipairs(classes.data or {}) do mark(ln, "  ▲ data-dependent branch", "FoxSymdepsAlarm") end
  for _, ln in ipairs(classes.benign or {}) do mark(ln, "  △ branch (reg/loop)", "FoxSymdepsDim") end
  for _, ln in ipairs(classes.cmov or {}) do mark(ln, "  ✓ branchless (cmov)", "FoxSymdepsOk") end
  for _, f in ipairs(classes.feeders or {}) do
    mark(f.ln, ("  · data source for ▲ @%d"):format(f.branch), "FoxSymdepsDim")
  end
  -- per-function verdict at the signature line. The GREEN carries its basis ("shipped") — the
  -- all-clear is the claim that must never overreach; warnings don't overclaim.
  for _, v in ipairs(verdicts or {}) do
    if v.sig then
      local text, hl
      if v.verdict == "nocode" then
        text, hl = "  · no shipped codegen", "FoxSymdepsDim"
      elseif v.verdict == "branchless" then
        text = (v.ncmov or 0) > 0 and ("  ✓ branchless (%d cmov) · shipped"):format(v.ncmov)
          or "  ✓ branchless · shipped"
        hl = "FoxSymdepsOk"
      elseif v.verdict == "data" then
        text, hl = ("  ▲ %d data-dependent"):format(v.ndata), "FoxSymdepsAlarm"
      else
        text, hl = ("  ▲ %d branch line%s"):format(v.nbr, v.nbr == 1 and "" or "s"), "FoxSymdepsWarn"
      end
      mark(v.sig, text, hl)
    end
  end
end

local function refresh(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  if not M.enabled then return end
  local file = vim.api.nvim_buf_get_name(bufnr)
  if file == "" or not (file:match("%.hpp$") or file:match("%.cpp$") or file:match("%.h$")) then return end
  -- changedtick guard: BufEnter with nothing changed re-paints nothing new — skip the 80MB scan
  local tick = vim.api.nvim_buf_get_changedtick(bufnr)
  if vim.b[bufnr].fox_branchtag_tick == tick then return end
  local asmshipped = require("fox-symdeps.asmshipped")
  local ui = require("fox-symdeps.ui")
  local root = (vim.fs.root(file, { ".git", "compile_commands.json" })) or vim.fn.getcwd()
  local cars = asmshipped.sidecars(root)
  if #cars == 0 then
    return ui.notify_raw("branch tags: no build*/asm sidecars under " .. root .. " — ./build.sh emits them",
      vim.log.levels.WARN)
  end
  -- newest sidecar carrying codegen for THIS file wins (recency-as-rule §11(iii)); one awk
  -- paragraph scan per sidecar, fixed-string pre-filter on `<parent>/<base>:` (same_source
  -- confirms per marker — the pre-filter may over-collect a same-basename file elsewhere).
  local base = vim.fn.fnamemodify(file, ":t")
  local parent = vim.fn.fnamemodify(file, ":h:t")
  local pat = "/" .. (parent ~= "" and (parent .. "/") or "") .. base .. ":"
  local function try(i)
    if i > #cars then
      return vim.schedule(function()
        if vim.api.nvim_buf_is_valid(bufnr) then vim.api.nvim_buf_clear_namespace(bufnr, NS, 0, -1) end
        ui.notify_raw(("branch tags: %s has no shipped codegen in any sidecar — nothing tagged, nothing greened"
          ):format(base), vim.log.levels.INFO)
      end)
    end
    local car = cars[i]
    -- ⚠ the ORS escapes are DOUBLED on purpose: awk must receive backslash-n, not a real
    -- newline (Lua interprets \n in 'single quotes' too — a real newline inside the awk
    -- program is 'unterminated string', exit 1, and the overlay silently paints NOTHING;
    -- operator-reported live 2026-08-18, now pinned by test_branchtag_live).
    local ok = pcall(vim.system,
      { "awk", "-v", "P=" .. pat, 'BEGIN{RS="";ORS="\\n\\n"} index($0,P)', car.path },
      { text = true },
      function(res)
        if (res.code or 0) ~= 0 or (res.stdout or "") == "" then return try(i + 1) end
        vim.schedule(function()
          if not (M.enabled and vim.api.nvim_buf_is_valid(bufnr)) then return end
          local instrs, srclines = M.parse_shipped(vim.split(res.stdout, "\n", { plain = true }), file)
          local attributed = 0
          for _, s in ipairs(srclines) do if s > 0 then attributed = attributed + 1 end end
          if attributed == 0 then return try(i + 1) end -- pre-filter hit a same-basename foreign file
          apply(bufnr, M.line_classes(instrs, srclines), M.verdicts(instrs, srclines, all_fn_ranges(bufnr)))
          vim.b[bufnr].fox_branchtag_tick = tick
          -- staleness is a TRANSITION notify (refresh fires on every save): editing after the
          -- build shifts functions off their shipped line spans — marks drift and small fns go
          -- `nocode`, which reads as breakage unless the basis-lag is said out loud (measured
          -- live 2026-08-18: two verdicts flipped between operator edits, zero code change).
          local stale = (vim.fn.getftime(file) or 0) > (car.prov.mtime or 0)
          if vim.b[bufnr].fox_branchtag_basis ~= car.path or vim.b[bufnr].fox_branchtag_stale ~= stale then
            vim.b[bufnr].fox_branchtag_basis = car.path
            vim.b[bufnr].fox_branchtag_stale = stale
            ui.notify_raw(("branch tags · shipped basis: %s (HEAD %s)%s"):format(
              car.prov.binary or "?", car.prov.head or "?",
              stale and " — ⚠ source newer than this binary; marks may drift until ./build.sh" or ""),
              stale and vim.log.levels.WARN or vim.log.levels.INFO)
          end
        end)
      end)
    if not ok then
      -- schedule: try() re-enters from vim.system's on_exit (a fast event context, where
      -- vim.notify's echo path is not allowed)
      vim.schedule(function()
        ui.notify_raw("branch tags: could not run awk over the sidecar", vim.log.levels.WARN)
      end)
    end
  end
  try(1)
end

function M.toggle()
  M.enabled = not M.enabled
  local ui = require("fox-symdeps.ui")
  if M.enabled then
    aug = vim.api.nvim_create_augroup("FoxSymdepsBranchTag", { clear = true })
    vim.api.nvim_create_autocmd({ "BufWritePost", "BufEnter" }, {
      group = aug, callback = function(a) refresh(a.buf) end,
    })
    ui.notify_raw("fox-symdeps · data-dependent branch tags ON — shipped-asm basis (build*/asm)", vim.log.levels.INFO)
    refresh()
  else
    if aug then pcall(vim.api.nvim_del_augroup_by_id, aug); aug = nil end
    for _, b in ipairs(vim.api.nvim_list_bufs()) do
      if vim.api.nvim_buf_is_valid(b) then
        vim.api.nvim_buf_clear_namespace(b, NS, 0, -1)
        vim.b[b].fox_branchtag_tick = nil -- a re-toggle must repaint, not hit the guard
      end
    end
    ui.notify_raw("fox-symdeps · data-dependent branch tags off", vim.log.levels.INFO)
  end
end

return M
