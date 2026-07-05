-- asmexplorer.lua — a godbolt, inside nvim. Compiles the buffer with the REAL toolchain (the compiler
-- + flags from compile_commands, only LTO stripped, + -g) so the asm is 1:1 with the shipped binary,
-- then shows it side-by-side with your code and SYNCS the two: put the cursor on a C++ line and its
-- instructions highlight + scroll into view in the asm pane (via the -g `.loc` map). Data-dependent
-- branches glow. No instantiation prompt — the `Foo<64>` in your code just gets compiled as used.
--
-- The map is built ONCE per compile and cached; cursor-sync is a pure lookup (no recompile on move).
-- A save (BufWritePost) recompiles. Heuristic branch marking is advisory. <leader>de.
local M = {}
local NS_DATA = vim.api.nvim_create_namespace("fox_symdeps_asmexp_data") -- persistent: data-dep branches
local NS_CUR = vim.api.nvim_create_namespace("fox_symdeps_asmexp_cur")   -- transient: the synced lines
local sizeprobe = require("fox-symdeps.sizeprobe")
local asmdiff = require("fox-symdeps.asmdiff")

local S = {} -- srcbuf -> { asmbuf, asmwin, srcwin, src_of (asmline->srcline), by_src (srcline->{asmlines}),
             --            data (set of asm display lines that are data-dep branches), aug, range }

-- pure: parse `-S -g` asm → { disp = {display strings}, src = {parallel source line per disp line},
-- data = { [disp_index]=true for data-dependent branches } }. Labels are kept (structure); .loc drives
-- the source line (main file only, matched by `tempbase`); directives are dropped.
function M.build(asm, tempbase)
  -- the main file's DWARF index/indices — g++ emits the temp under BOTH `.file 0 "dir" "name"` and
  -- `.file 1 "name"` then keys .loc off index 1; clang uses one index. So collect EVERY index whose
  -- .file names the temp (an #include has a different basename → its indices never enter the set).
  local main = {}
  for line in (asm or ""):gmatch("[^\n]+") do
    local idx = line:match("^%s*%.file%s+(%d+)%s")
    if idx and tempbase and line:find(tempbase, 1, true) then main[tonumber(idx)] = true end
  end
  local disp, src, instrs, instr_disp, cur = {}, {}, {}, {}, 0
  for line in (asm or ""):gmatch("[^\n]+") do
    local fidx, ln = line:match("^%s*%.loc%s+(%d+)%s+(%d+)")
    local label = line:match("^([%w_%.%$@]+):%s*$")
    if fidx then
      if main[tonumber(fidx)] then cur = tonumber(ln) end
    elseif line:find("%.cfi_endproc") or (label and label:find("^%.Lfunc_end")) then
      cur = 0 -- function boundary → the DWARF/debug labels that follow are not code
    elseif label then
      if not label:find("^%.[LK]?debug") and not label:find("^%.Letext") and not label:find("^%.Ldwarf") then
        disp[#disp + 1] = label .. ":"; src[#src + 1] = cur -- keep code labels; drop debug/section ones
      end
    elseif line:match("^%s*%.") then                       -- directive → drop
    else
      local instr = line:gsub("#.*$", ""):gsub("^%s+", ""):gsub("%s+$", "")
      if instr ~= "" then
        disp[#disp + 1] = "    " .. instr; src[#src + 1] = cur
        instrs[#instrs + 1] = instr; instr_disp[#instrs] = #disp
      end
    end
  end
  local data = {}
  for _, d in ipairs(asmdiff.classify_branches(instrs).details or {}) do
    if d.data and instr_disp[d.idx] then data[instr_disp[d.idx]] = true end
  end
  return { disp = disp, src = src, data = data }
end

-- pure: keep only display lines whose source line is within [lo, hi] (the enclosing function), and
-- re-index. lo/hi nil → keep everything (capped by the caller). Returns the same shape, renumbered.
function M.filter_range(built, lo, hi)
  if not (lo and hi) then return built end
  local disp, src, data = {}, {}, {}
  for i, s in ipairs(built.disp) do
    local sl = built.src[i]
    if sl and sl >= lo and sl <= hi then
      disp[#disp + 1] = s; src[#src + 1] = built.src[i]
      if built.data[i] then data[#disp] = true end
    end
  end
  return { disp = disp, src = src, data = data }
end
M._build = M.build

-- the enclosing function's 1-based source line range at the cursor, or nil (via treesitter).
local function fn_range(bufnr, row0, col0)
  local ok, parser = pcall(vim.treesitter.get_parser, bufnr, "cpp")
  if not ok or not parser then return nil end
  local tree = parser:parse()[1]
  if not tree then return nil end
  local node = tree:root():named_descendant_for_range(row0, col0, row0, col0)
  while node do
    local t = node:type()
    if t == "function_definition" then
      local sr, _, er = node:range()
      return sr + 1, er + 1
    end
    node = node:parent()
  end
end

local function paint_data(st)
  for ln in pairs(st.data) do
    pcall(vim.api.nvim_buf_set_extmark, st.asmbuf, NS_DATA, ln - 1, 0, {
      line_hl_group = "FoxSymdepsAlarm", virt_text = { { "  ▲ data-dep", "FoxSymdepsAlarm" } }, virt_text_pos = "eol",
    })
  end
end

-- sync the asm pane to the source line under the cursor: highlight the mapped instructions + scroll.
local function sync(st)
  if not (st.asmwin and vim.api.nvim_win_is_valid(st.asmwin)) then return end
  vim.api.nvim_buf_clear_namespace(st.asmbuf, NS_CUR, 0, -1)
  local sl = vim.api.nvim_win_get_cursor(st.srcwin)[1]
  local lines = st.by_src[sl]
  if not lines or #lines == 0 then return end
  for _, al in ipairs(lines) do
    pcall(vim.api.nvim_buf_set_extmark, st.asmbuf, NS_CUR, al - 1, 0, { line_hl_group = "FoxSymdepsSelection" })
  end
  pcall(vim.api.nvim_win_set_cursor, st.asmwin, { lines[1], 0 })
  vim.api.nvim_win_call(st.asmwin, function() vim.cmd("normal! zz") end)
end

local function render(st, built)
  st.by_src, st.data = {}, {}
  for i, sl in ipairs(built.src) do
    if sl and sl > 0 then st.by_src[sl] = st.by_src[sl] or {}; table.insert(st.by_src[sl], i) end
  end
  for ln in pairs(built.data) do st.data[ln] = true end
  vim.bo[st.asmbuf].modifiable = true
  vim.api.nvim_buf_set_lines(st.asmbuf, 0, -1, false, built.disp)
  vim.bo[st.asmbuf].modifiable = false
  vim.api.nvim_buf_clear_namespace(st.asmbuf, NS_DATA, 0, -1)
  paint_data(st)
  sync(st)
end

-- compile the buffer with the real toolchain (-S -g), build the source↔asm map. cb(built) | cb(nil,err).
-- Takes a bufnr (not the explorer state) so facts.lua + others can reuse it without a window.
local function compile(bufnr, cb)
  local file = vim.api.nvim_buf_get_name(bufnr)
  if file == "" then return cb(nil, "buffer has no file on disk (save it first)") end
  local flags, dir, cc = sizeprobe._flags_for(file)
  if not flags then return cb(nil, "no compile_commands.json for this file") end
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local tmp = vim.fn.tempname() .. ".cpp"
  if not pcall(vim.fn.writefile, lines, tmp) then return cb(nil, "could not write temp source") end
  local tempbase = vim.fn.fnamemodify(tmp, ":t")
  local argv = { cc or "clang++", "-S", "-g", "-o", "-", "-I" .. vim.fn.fnamemodify(file, ":h") }
  for _, f in ipairs(flags) do
    if not (f:match("^%-flto") or f == "-emit-llvm") then argv[#argv + 1] = f end
  end
  argv[#argv + 1] = tmp
  local ok = pcall(vim.system, argv, { cwd = dir or vim.fn.fnamemodify(file, ":h"), text = true }, function(res)
    pcall(os.remove, tmp)
    local asm = res.stdout or ""
    if asm == "" then
      local err
      for l in (res.stderr or ""):gmatch("[^\n]+") do if l:find("error:", 1, true) then err = vim.trim(l); break end end
      return vim.schedule(function() cb(nil, err or "compile produced no asm") end)
    end
    vim.schedule(function() cb(M.build(asm, tempbase)) end)
  end)
  if not ok then pcall(os.remove, tmp); cb(nil, "could not run " .. (cc or "clang++")) end
end

-- reusable: compile the ctx's buffer, isolate the enclosing function, and count its instructions +
-- detect SIMD — the compiled-reality metrics feeding the [DATA_SIZE]/[SIMD] derived tags. cb({insns,
-- simd}) | cb(nil). No window; pure metric extraction over the same 1:1 build the explorer uses.
function M.fn_metrics(ctx, cb)
  local lo, hi = fn_range(ctx.bufnr, (ctx.line or 1) - 1, ctx.col or 0)
  compile(ctx.bufnr, function(built, _)
    if not built then return cb(nil) end
    local f = M.filter_range(built, lo, hi)
    local insns, simd = 0, false
    for _, d in ipairs(f.disp) do
      if not d:match(":%s*$") then -- labels end in ":"; everything else is an instruction
        insns = insns + 1
        if d:match("[yz]mm%d") or d:match("%svp%a") or d:match("%sv%a+p[sd]%s") then simd = true end
      end
    end
    cb({ insns = insns, simd = simd })
  end)
end

local function refresh(st)
  compile(st.srcbuf, function(built, err)
    if not (st.asmbuf and vim.api.nvim_buf_is_valid(st.asmbuf)) then return end
    if not built then
      vim.bo[st.asmbuf].modifiable = true
      vim.api.nvim_buf_set_lines(st.asmbuf, 0, -1, false, { "  asm explorer — " .. (err or "unavailable") })
      vim.bo[st.asmbuf].modifiable = false
      return
    end
    render(st, M.filter_range(built, st.range and st.range[1], st.range and st.range[2]))
  end)
end

function M.close(srcbuf)
  local st = S[srcbuf]
  if not st then return end
  if st.aug then pcall(vim.api.nvim_del_augroup_by_id, st.aug) end
  if st.asmwin and vim.api.nvim_win_is_valid(st.asmwin) then pcall(vim.api.nvim_win_close, st.asmwin, true) end
  S[srcbuf] = nil
end

function M.open(palette)
  local srcbuf = vim.api.nvim_get_current_buf()
  if S[srcbuf] then return M.close(srcbuf) end -- toggle
  local srcwin = vim.api.nvim_get_current_win()
  local cur = vim.api.nvim_win_get_cursor(srcwin)
  local lo, hi = fn_range(srcbuf, cur[1] - 1, cur[2])
  local st = { srcbuf = srcbuf, srcwin = srcwin, range = (lo and { lo, hi }) or nil, by_src = {}, data = {} }

  st.asmbuf = vim.api.nvim_create_buf(false, true)
  vim.bo[st.asmbuf].bufhidden = "wipe"
  vim.bo[st.asmbuf].filetype = "asm"
  vim.api.nvim_buf_set_lines(st.asmbuf, 0, -1, false, { "  ⚙ compiling with your real toolchain (1:1)…" })
  vim.bo[st.asmbuf].modifiable = false
  vim.cmd("rightbelow vsplit")
  st.asmwin = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(st.asmwin, st.asmbuf)
  vim.wo[st.asmwin].number = false
  vim.wo[st.asmwin].winbar = "%#FoxSymdepsTitle# asm · 1:1 · " .. (st.range and "this function" or "buffer") .. " %*"
  vim.wo[st.asmwin].winhighlight = "Normal:FoxSymdepsNormal"
  vim.api.nvim_set_current_win(srcwin) -- keep the user in their code
  vim.keymap.set("n", "q", function() M.close(srcbuf) end, { buffer = st.asmbuf, nowait = true })

  S[srcbuf] = st
  st.aug = vim.api.nvim_create_augroup("FoxSymdepsAsmExp_" .. srcbuf, { clear = true })
  vim.api.nvim_create_autocmd("CursorMoved", {
    group = st.aug, buffer = srcbuf, callback = function() if S[srcbuf] then sync(S[srcbuf]) end end,
  })
  vim.api.nvim_create_autocmd("BufWritePost", {
    group = st.aug, buffer = srcbuf, callback = function() if S[srcbuf] then refresh(S[srcbuf]) end end,
  })
  vim.api.nvim_create_autocmd({ "BufWipeout", "BufDelete" }, {
    group = st.aug, buffer = srcbuf, callback = function() M.close(srcbuf) end,
  })
  refresh(st)
  return st
end

M._state = function(buf) return S[buf] end -- test hook
M._sync = sync
return M
