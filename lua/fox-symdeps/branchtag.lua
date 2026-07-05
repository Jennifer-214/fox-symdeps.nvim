-- branchtag.lua — inline data-dependent-branch tags on the SOURCE. Compiles the buffer (real project
-- flags + -g), classifies every conditional branch (asmdiff), maps the DATA-DEPENDENT ones back to
-- source lines via the -g `.loc` directives, and tags those lines with a soft "▲ data-dependent
-- branch" virtual text. Non-destructive — extmarks only, never touches code or comments, exactly like
-- the layout/straddle tags. Opt-in (<leader>db); refreshes on save (a compile is too heavy for
-- CursorHold). Heuristic + advisory: a branch that reads a struct field / tick input is the
-- mispredict risk on a branchless hot path; a loop-bound / constant branch is not flagged.
local M = {}
local NS = vim.api.nvim_create_namespace("fox_symdeps_branchtag")
local sizeprobe = require("fox-symdeps.sizeprobe")
local asmdiff = require("fox-symdeps.asmdiff")
local aug
M.enabled = false

-- pure: parse `-S -g` asm → (instrs, srclines) parallel lists. srclines[i] = the MAIN-file source
-- line the instruction maps to (0 = unknown), tracked from `.loc <mainidx> <line>`. mainidx is the
-- .file entry whose path matches `tempbase` (the compiled buffer copy), so #included lines are excluded.
function M.parse(asm, tempbase)
  -- main file DWARF index/indices — g++ names the temp under both index 0 and 1 but keys .loc off 1;
  -- clang uses one. Collect every index whose .file names the temp (includes have other basenames).
  local main = {}
  for line in (asm or ""):gmatch("[^\n]+") do
    local idx = line:match("^%s*%.file%s+(%d+)%s")
    if idx and tempbase and line:find(tempbase, 1, true) then main[tonumber(idx)] = true end
  end
  local instrs, srclines, cur = {}, {}, 0
  for line in (asm or ""):gmatch("[^\n]+") do
    local fidx, ln = line:match("^%s*%.loc%s+(%d+)%s+(%d+)")
    if fidx then
      if main[tonumber(fidx)] then cur = tonumber(ln) end
    elseif line:match("^%s*%.") then          -- other directive → skip
    elseif line:match("^[%w_%.%$@]+:%s*$") then -- label → skip
    else
      local instr = line:gsub("#.*$", ""):gsub("^%s+", ""):gsub("%s+$", "")
      if instr ~= "" then instrs[#instrs + 1] = instr; srclines[#srclines + 1] = cur end
    end
  end
  return instrs, srclines
end

-- pure: sorted, de-duped source lines that carry a data-dependent branch.
function M.data_lines(instrs, srclines)
  local det = asmdiff.classify_branches(instrs).details or {}
  local seen, out = {}, {}
  for _, d in ipairs(det) do
    if d.data then
      local ln = srclines[d.idx]
      if ln and ln > 0 and not seen[ln] then seen[ln] = true; out[#out + 1] = ln end
    end
  end
  table.sort(out)
  return out
end

-- pure: per-function branch verdict. fns = { {lo, hi, sig}, ... } (1-based source ranges + the
-- signature line). Counts the conditional branches whose source line falls in each function's range.
-- Verdict: "branchless" (green — the hot-path ideal) · "branches" (yellow — has branches, none
-- data-dependent) · "data" (red — ≥1 data-dependent branch, the mispredict risk). Returns
-- { { sig, verdict, nbr, ndata }, ... } — only for functions that actually contain branches or
-- are worth a "branchless ✓" (i.e. all of them; a fn with zero branches earns the green).
function M.verdicts(instrs, srclines, fns)
  local det = asmdiff.classify_branches(instrs).details or {}
  local out = {}
  for _, fn in ipairs(fns or {}) do
    local nbr, ndata = 0, 0
    for _, d in ipairs(det) do
      local sl = srclines[d.idx]
      if sl and sl >= fn.lo and sl <= fn.hi then
        nbr = nbr + 1
        if d.data then ndata = ndata + 1 end
      end
    end
    local verdict = (nbr == 0) and "branchless" or (ndata > 0 and "data" or "branches")
    out[#out + 1] = { sig = fn.sig, verdict = verdict, nbr = nbr, ndata = ndata }
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

local function apply(bufnr, dlines, verdicts)
  if not (M.enabled and vim.api.nvim_buf_is_valid(bufnr)) then return end
  vim.api.nvim_buf_clear_namespace(bufnr, NS, 0, -1)
  local n = vim.api.nvim_buf_line_count(bufnr)
  -- RED on each data-dependent branch line (the mispredict risk)
  for _, ln in ipairs(dlines) do
    if ln <= n then
      pcall(vim.api.nvim_buf_set_extmark, bufnr, NS, ln - 1, 0, {
        virt_text = { { "  ▲ data-dependent branch", "FoxSymdepsAlarm" } }, virt_text_pos = "eol",
      })
    end
  end
  -- per-function verdict at the signature line: green branchless / yellow branches / red data-dep
  for _, v in ipairs(verdicts or {}) do
    if v.sig and v.sig <= n then
      local text, hl
      if v.verdict == "branchless" then
        text, hl = "  ✓ branchless", "FoxSymdepsOk"
      elseif v.verdict == "data" then
        text, hl = ("  ▲ %d data-dependent"):format(v.ndata), "FoxSymdepsAlarm"
      else
        text, hl = ("  ▲ %d branch%s"):format(v.nbr, v.nbr == 1 and "" or "es"), "FoxSymdepsWarn"
      end
      pcall(vim.api.nvim_buf_set_extmark, bufnr, NS, v.sig - 1, 0, {
        virt_text = { { text, hl } }, virt_text_pos = "eol",
      })
    end
  end
end

local function refresh(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  if not M.enabled then return end
  local file = vim.api.nvim_buf_get_name(bufnr)
  if file == "" then return end
  local flags, dir, cc = sizeprobe._flags_for(file)
  if not flags then return end
  local src = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local tmp = vim.fn.tempname() .. ".cpp"
  if not pcall(vim.fn.writefile, src, tmp) then return end
  local tempbase = vim.fn.fnamemodify(tmp, ":t")
  -- REAL compiler + project flags for 1:1 codegen; only LTO stripped (else -S emits LLVM IR). -g for .loc.
  local argv = { cc or "clang++", "-S", "-g", "-o", "-", "-I" .. vim.fn.fnamemodify(file, ":h") }
  for _, f in ipairs(flags) do
    if not (f:match("^%-flto") or f == "-emit-llvm") then argv[#argv + 1] = f end
  end
  argv[#argv + 1] = tmp
  pcall(vim.system, argv, { cwd = dir or vim.fn.fnamemodify(file, ":h"), text = true }, function(res)
    pcall(os.remove, tmp)
    local asm = res.stdout or ""
    vim.schedule(function() -- treesitter (all_fn_ranges) needs the main loop
      if not (M.enabled and vim.api.nvim_buf_is_valid(bufnr)) then return end
      local instrs, srclines = M.parse(asm, tempbase)
      apply(bufnr, M.data_lines(instrs, srclines), M.verdicts(instrs, srclines, all_fn_ranges(bufnr)))
    end)
  end)
end

function M.toggle()
  M.enabled = not M.enabled
  if M.enabled then
    aug = vim.api.nvim_create_augroup("FoxSymdepsBranchTag", { clear = true })
    vim.api.nvim_create_autocmd({ "BufWritePost", "BufEnter" }, {
      group = aug, callback = function(a) refresh(a.buf) end,
    })
    vim.notify("fox-symdeps · data-dependent branch tags ON (compiling…)", vim.log.levels.INFO)
    refresh()
  else
    if aug then pcall(vim.api.nvim_del_augroup_by_id, aug); aug = nil end
    for _, b in ipairs(vim.api.nvim_list_bufs()) do
      if vim.api.nvim_buf_is_valid(b) then vim.api.nvim_buf_clear_namespace(b, NS, 0, -1) end
    end
    vim.notify("fox-symdeps · data-dependent branch tags off", vim.log.levels.INFO)
  end
end

return M
