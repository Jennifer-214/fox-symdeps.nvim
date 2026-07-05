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

local function apply(bufnr, dlines)
  if not (M.enabled and vim.api.nvim_buf_is_valid(bufnr)) then return end
  vim.api.nvim_buf_clear_namespace(bufnr, NS, 0, -1)
  local n = vim.api.nvim_buf_line_count(bufnr)
  for _, ln in ipairs(dlines) do
    if ln <= n then
      pcall(vim.api.nvim_buf_set_extmark, bufnr, NS, ln - 1, 0, {
        virt_text = { { "  ▲ data-dependent branch", "FoxSymdepsWarn" } }, virt_text_pos = "eol",
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
    local instrs, srclines = M.parse(res.stdout or "", tempbase)
    local dlines = M.data_lines(instrs, srclines)
    vim.schedule(function() apply(bufnr, dlines) end)
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
