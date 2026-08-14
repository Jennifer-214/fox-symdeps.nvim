-- asmshipped.lua — the SHIPPED-asm card (0.5; the TD-257 viewer half; ideas §2's "use the real
-- build to view"). Reads the `./build.sh asm` sidecars (`build*/asm/<binary>.asm` — objdump of
-- the LINKED artifact) and NEVER recompiles: under -flto the shipped code exists only post-link,
-- so the sidecar IS the 1:1 truth the explorer's editor-flags recompile only approximates.
--
-- Honest states, all NAMED (Class 57 — never an empty pane):
--   FOUND         the function's shipped instructions, provenance in the winbar; other binaries
--                 carrying it are listed, instantiation blocks all shown (multiplicity is fact)
--   INLINED-AWAY  zero standalone copies across every sidecar searched — a FACT about the shipped
--                 binary, rendered as a statement, not a blank
--   STALE         sidecar's recorded binary-sha16 ≠ the binary's current sha16 → rendered WITH a
--                 loud banner (old asm is real asm — of the OLD binary), never silently
--   NO-SIDECAR    refusal naming the fix: run `./build.sh asm`
--
-- A FOLLOW surface (operator ask 2026-08-14, the followcard shape): `<leader>ds` TOGGLES the ONE
-- card; while open it retargets to the enclosing FUNCTION as the cursor moves — across files —
-- on idle (CursorHold; comments/structs HOLD the last view, no flicker). `<CR>` on a `· file:line`
-- marker jumps the source window there (including INTO the inlined-from files — and follow then
-- retargets to the function you landed in). `r` re-resolves (pairs with the stale banner after a
-- rebuild). Sweep order = newest recorded binary first (recency-as-rule §11(iii)).
local M = {}

-- ── pure core (the teeth hit these directly) ─────────────────────────────────────────────────

-- sidecar header (the ./build.sh asm provenance contract) → { binary, sha16, mtime, head } |
-- nil, reason. Tri-state: a mutilated header is a NAMED refusal, never {}.
function M.parse_header(l1, l2)
  local binary = (l1 or ""):match("^# 1:1 disassembly of (%S+)")
  local sha16, mtime, head = (l2 or ""):match(
    "^# binary%-sha256%-16: (%x+)%s+binary%-mtime: (%d+)%s+emitted%-at%-HEAD: (%S+)")
  if not (binary and sha16) then
    return nil, "sidecar header unreadable (regen: ./build.sh asm)"
  end
  return { binary = binary, sha16 = sha16, mtime = tonumber(mtime), head = head }
end

-- the base identifier a tag/cursor name searches under: instantiation angle-forms are stripped
-- (`BG_Evaluate<64>` tags vs `BG_Evaluate<64u>` demangles — spellings differ; the base matches
-- ALL instantiations and the card shows every block, which is the honest multiplicity anyway).
function M.base_symbol(name)
  return (name or ""):match("^([%w_:~]+)") or ""
end

-- skip a balanced <...> template group starting at index i ('<'); returns the index AFTER it.
local function skip_angles(s, i)
  local depth = 0
  for k = i, #s do
    local c = s:sub(k, k)
    if c == "<" then depth = depth + 1
    elseif c == ">" then depth = depth - 1; if depth == 0 then return k + 1 end end
  end
  return nil
end

-- is this line an objdump DEFINITION block header for `symbol`? Header form (column 1):
-- `hex <demangled>:`. The symbol must sit in NAME POSITION — identifier boundaries AND
-- followed (after an optional template arg-list) by its argument-list `(` or end-of-name.
-- A symbol appearing in a PARAMETER or RETURN type does NOT match (the FPN_Binary dogfood
-- bug: searching a struct name matched every function taking it as an argument). Call-site
-- annotations (`call … <Sym+0x10>`) are indented operands, never column-1 headers.
function M.match_block_header(line, symbol)
  local inner = (line or ""):match("^%x+ <(.+)>:$")
  if not inner or symbol == "" then return false end
  local from = 1
  while true do
    local s, e = inner:find(symbol, from, true)
    if not s then return false end
    local before = s == 1 and "" or inner:sub(s - 1, s - 1)
    local j = e + 1
    if not before:match("[%w_]") and not inner:sub(j, j):match("[%w_]") then
      if inner:sub(j, j) == "<" then j = skip_angles(inner, j) end
      if j then
        while inner:sub(j, j) == " " do j = j + 1 end
        local c = inner:sub(j, j)
        if c == "(" or c == "" then return true end
      end
    end
    from = e + 1
  end
end

-- pure slice over sidecar TEXT: every definition block for `symbol` (header + body up to the
-- terminating blank). Small-input path + the shared rule the async rg/sed path filters with.
function M.slice(text, symbol)
  local blocks, cur = {}, nil
  -- vim.split, not gmatch("[^\n]*"): the star pattern yields a phantom empty match after every
  -- line, which would terminate a block right after its header.
  for _, line in ipairs(vim.split(text or "", "\n", { plain = true })) do
    if cur then
      if line == "" then blocks[#blocks + 1] = cur; cur = nil
      else cur[#cur + 1] = line end
    elseif M.match_block_header(line, symbol) then
      cur = { line }
    end
  end
  if cur then blocks[#blocks + 1] = cur end
  return blocks
end

-- does a DWARF marker path refer to the invoking source buffer? Exact match first; else
-- basename + parent-dir (the engine tree is reachable via the workspace symlink too, so the
-- compile-time path and the buffer's path can differ by root — the last two components are
-- the stable identity).
function M.same_source(marker_path, src_abs)
  if not (marker_path and src_abs) then return false end
  if marker_path == src_abs then return true end
  local mb, sb = marker_path:match("([^/]+)$"), src_abs:match("([^/]+)$")
  if mb ~= sb then return false end
  local mp, sp = marker_path:match("([^/]+)/[^/]+$"), src_abs:match("([^/]+)/[^/]+$")
  return mp == sp
end

-- pure: an extracted `-l` block → { display, src_of, by_src, jump, n_insn }. Marker lines
-- (`/abs/path:NNN`) become dimmed `· name:NNN` rows — `· from <file>:NNN` when the code was
-- INLINED FROM another file (cross-TU attribution no per-TU compile can show); instruction
-- rows under a current-file marker enter the bidirectional maps; EVERY marker row enters
-- `jump` ({row → {path, line}}) so <CR> can go there — including into the inlined-from files.
-- n_insn = the function's SHIPPED instruction count (the budget-checkable number — the
-- H7/H8 join rides the probe-cutover rung).
function M.line_map(block_lines, src_abs, offset)
  offset = offset or 0
  local display, src_of, by_src, jump, n_insn = {}, {}, {}, {}, 0
  local cur_src = nil
  for _, line in ipairs(block_lines) do
    local path, ln = line:match("^(/[^:]+):(%d+)")
    if path then
      local name = path:match("([^/]+)$") or path
      if M.same_source(path, src_abs) then
        cur_src = tonumber(ln)
        display[#display + 1] = ("  · %s:%s"):format(name, ln)
        src_of[offset + #display] = cur_src
      else
        cur_src = nil
        display[#display + 1] = ("  · from %s:%s"):format(name, ln)
      end
      jump[offset + #display] = { path = path, line = tonumber(ln) }
    else
      display[#display + 1] = line
      if line:match("^%s+%x+:\t") then
        n_insn = n_insn + 1
        if cur_src then
          src_of[offset + #display] = cur_src
          by_src[cur_src] = by_src[cur_src] or {}
          table.insert(by_src[cur_src], offset + #display)
        end
      end
    end
  end
  return { display = display, src_of = src_of, by_src = by_src, jump = jump, n_insn = n_insn }
end

-- newest-first over parsed sidecars (recorded binary mtime; recency-as-rule §11(iii)).
function M.sweep_order(cars)
  table.sort(cars, function(a, b) return (a.prov.mtime or 0) > (b.prov.mtime or 0) end)
  return cars
end

-- follow decision, pure: a candidate symbol → the NEW base to retarget to, or nil (HOLD —
-- nil/empty and the already-shown function never flicker the card).
function M.follow_target(sym, cur_symbol)
  sym = M.base_symbol(sym)
  if sym == "" or sym == cur_symbol then return nil end
  return sym
end

-- C++ keywords a bare <cword> must never resolve as (the "for" dogfood bug: an untagged
-- function + cursor on a keyword → the card searched the sidecars for `for`).
M.KEYWORDS = {
  ["for"] = true, ["if"] = true, ["while"] = true, ["return"] = true, ["switch"] = true,
  ["case"] = true, ["do"] = true, ["else"] = true, ["break"] = true, ["continue"] = true,
  ["const"] = true, ["auto"] = true, ["void"] = true, ["int"] = true, ["long"] = true,
  ["double"] = true, ["float"] = true, ["char"] = true, ["bool"] = true, ["struct"] = true,
  ["template"] = true, ["inline"] = true, ["static"] = true, ["unsigned"] = true,
  ["namespace"] = true, ["using"] = true, ["new"] = true, ["delete"] = true,
  ["sizeof"] = true, ["true"] = true, ["false"] = true, ["nullptr"] = true, ["this"] = true,
}

-- the ENCLOSING function's name via treesitter (the untagged-function rung — Portfolio_Init
-- has no [FUNCTION] tag block, and <cword> mid-body is a keyword lottery).
local function ts_fn_symbol(bufnr, row0)
  local okp, parser = pcall(vim.treesitter.get_parser, bufnr, "cpp")
  if not okp or not parser then return nil end
  local tree = parser:parse()[1]
  if not tree then return nil end
  local node = tree:root():named_descendant_for_range(row0, 0, row0, 0)
  while node do
    if node:type() == "function_definition" then
      local decl = node:field("declarator")[1]
      while decl do
        local t = decl:type()
        if t == "identifier" or t == "qualified_identifier" or t == "field_identifier"
           or t == "operator_name" or t == "destructor_name" then
          return vim.treesitter.get_node_text(decl, bufnr)
        end
        decl = decl:field("declarator")[1] or decl:named_child(0)
      end
      return nil
    end
    node = node:parent()
  end
end

-- the ONE symbol-resolution chain (open + follow share it): tagged FUNCTION block name →
-- treesitter enclosing function → nil. Returns symbol, blk (blk for the struct guard).
local function symbol_at(buf, row0)
  local ok, tc = pcall(require, "fox-symdeps.tagcontext")
  local blk = ok and tc.enclosing_block(buf, row0) or nil
  if blk and blk.type == "FUNCTION" then return M.base_symbol(blk.name), blk end
  local ts = ts_fn_symbol(buf, row0)
  if ts then return M.base_symbol(ts), blk end
  return nil, blk
end

-- ── async assembly ───────────────────────────────────────────────────────────────────────────

local function root_of(file)
  return (file ~= "" and vim.fs.root(file, { ".git", "compile_commands.json" })) or vim.fn.getcwd()
end

-- enumerate sidecars under root; parse each header (io read of 2 lines — never the 80MB body).
local function sidecars(root)
  local cars = {}
  for _, p in ipairs(vim.fn.glob(root .. "/build*/asm/*.asm", false, true)) do
    local f = io.open(p, "r")
    if f then
      local l1, l2 = f:read("*l"), f:read("*l")
      f:close()
      local prov = M.parse_header(l1, l2)
      if prov then cars[#cars + 1] = { path = p, prov = prov } end
    end
  end
  return M.sweep_order(cars)
end

-- rg the symbol across all sidecars (ONE subprocess); Lua filters to definition headers via the
-- shared rule. cb({ [sidecar_path] = { {lnum, header}, … } }, callsites_per_path).
local function find_blocks(cars, symbol, cb)
  local paths = {}
  for _, c in ipairs(cars) do paths[#paths + 1] = c.path end
  local argv = { "rg", "-nF", "--no-heading", symbol }
  vim.list_extend(argv, paths)
  vim.system(argv, { text = true }, function(res)
    local defs, calls = {}, {}
    for line in (res.stdout or ""):gmatch("[^\n]+") do
      local path, lnum, content = line:match("^(.-):(%d+):(.*)$")
      if path then
        if M.match_block_header(content, symbol) then
          defs[path] = defs[path] or {}
          table.insert(defs[path], { lnum = tonumber(lnum), header = content })
        else
          calls[path] = (calls[path] or 0) + 1
        end
      end
    end
    vim.schedule(function() cb(defs, calls) end)
  end)
end

-- extract one block's lines: sed from the header line to the terminating blank (exact — no
-- silent -A caps; a 900-instruction monster prints whole).
local function extract(path, lnum, cb)
  vim.system({ "sed", "-n", ("%d,/^$/p"):format(lnum), path }, { text = true }, function(res)
    local lines = vim.split(res.stdout or "", "\n", { plain = true })
    while #lines > 0 and lines[#lines] == "" do table.remove(lines) end
    vim.schedule(function() cb(lines) end)
  end)
end

-- freshness: recorded sha16 vs the binary's current sha16. cb("fresh"|"stale"|"binary-missing", now16)
local function freshness(prov, root, cb)
  local bin = prov.binary
  if not bin:match("^/") then bin = root .. "/" .. bin end
  if vim.fn.filereadable(bin) ~= 1 then return cb("binary-missing") end
  vim.system({ "sha256sum", bin }, { text = true }, function(res)
    local now16 = ((res.stdout or ""):match("^(%x+)") or ""):sub(1, 16)
    vim.schedule(function() cb(now16 == prov.sha16 and "fresh" or "stale", now16) end)
  end)
end

-- ── the card (ONE live follow surface) ───────────────────────────────────────────────────────

local NS_SYNC = vim.api.nvim_create_namespace("fox_symdeps_asmshipped_sync")
local NS_PAINT = vim.api.nvim_create_namespace("fox_symdeps_asmshipped_paint")

-- deterministic painter — theme-linked BUILTIN groups, zero parser deps (dogfood 2026-08-13:
-- "the asm is missing the text colors"; an asm treesitter/syntax file may or may not exist on
-- a given setup, and our content isn't pure asm anyway — markers + demangled context lines).
local function paint_lines(buf, lines)
  local function mark(row, s, e, grp)
    pcall(vim.api.nvim_buf_set_extmark, buf, NS_PAINT, row - 1, s - 1, { end_col = e, hl_group = grp })
  end
  vim.api.nvim_buf_clear_namespace(buf, NS_PAINT, 0, -1)
  for i, l in ipairs(lines) do
    if l:find("  · from ", 1, true) == 1 then
      mark(i, 1, #l, "DiagnosticHint")
    elseif l:find("  · ", 1, true) == 1 then
      mark(i, 1, #l, "Comment")
    elseif l:find("⚠", 1, true) then
      mark(i, 1, #l, "WarningMsg")
    elseif l:find("  shipped: ", 1, true) == 1 or l:find("  also in: ", 1, true) == 1
        or l:find("shipped instruction", 1, true) then
      mark(i, 1, #l, "Title")
    elseif l:match("^%x+ <.+>:$") then
      mark(i, 1, #l, "Function")
    elseif l:match("^%s+%x+:") then
      local _, e_addr = l:find("^%s+%x+:")
      mark(i, 1, e_addr, "Number")
      local ms, me = l:find("[%a][%w.]*", e_addr + 1)
      if ms then mark(i, ms, me, "Statement") end
      local from = (me or e_addr) + 1
      while true do
        local rs, re = l:find("%%[%w]+", from)
        if not rs then break end
        mark(i, rs, re, "Identifier")
        from = re + 1
      end
      local is_, ie_ = l:find("%$%-?0?x?%x+")
      if is_ then mark(i, is_, ie_, "Constant") end
      local ts, te = l:find("<[^>]+>")
      if ts then mark(i, ts, te, "Special") end
    elseif l:match("^%S.*:$") then
      mark(i, 1, #l, "Type")   -- demangled inlined-from context line (`Name():`)
    end
  end
end

local S = nil   -- { win, buf, aug, symbol, busy, sync = { srcbuf, srcwin, by_src, src_of, jump } }
local resolve_into   -- fwd decl (maybe_follow ↔ resolve_into)

local function close_card()
  if not S then return end
  if S.aug then pcall(vim.api.nvim_del_augroup_by_id, S.aug) end
  if S.sync and S.sync.srcbuf and vim.api.nvim_buf_is_valid(S.sync.srcbuf) then
    pcall(vim.api.nvim_buf_clear_namespace, S.sync.srcbuf, NS_SYNC, 0, -1)
  end
  if S.win and vim.api.nvim_win_is_valid(S.win) then pcall(vim.api.nvim_win_close, S.win, true) end
  S = nil
end

local function paint_sync(srcline, asmrows)
  if not S then return end
  if S.sync.srcbuf and vim.api.nvim_buf_is_valid(S.sync.srcbuf) then
    pcall(vim.api.nvim_buf_clear_namespace, S.sync.srcbuf, NS_SYNC, 0, -1)
  end
  pcall(vim.api.nvim_buf_clear_namespace, S.buf, NS_SYNC, 0, -1)
  if srcline and S.sync.srcbuf then
    pcall(vim.api.nvim_buf_set_extmark, S.sync.srcbuf, NS_SYNC, srcline - 1, 0,
          { line_hl_group = "FoxSymdepsSelection" })
  end
  -- asm side = the hover-look BAND (bg-only; a vectorized line maps to ~40 rows — text colors stay)
  for _, r in ipairs(asmrows or {}) do
    pcall(vim.api.nvim_buf_set_extmark, S.buf, NS_SYNC, r - 1, 0,
          { line_hl_group = "FoxSymdepsSyncLine" })
  end
end

local function maybe_follow()
  if not (S and vim.api.nvim_win_is_valid(S.win)) or S.busy then return end
  local buf = vim.api.nvim_get_current_buf()
  if buf == S.buf or vim.bo[buf].buftype ~= "" then return end
  local row0 = vim.api.nvim_win_get_cursor(0)[1] - 1
  local cand = symbol_at(buf, row0)   -- tagged OR treesitter — untagged functions follow too
  local sym = cand and M.follow_target(cand, S.symbol)
  if sym then resolve_into(sym, buf, vim.api.nvim_get_current_win()) end
end

-- jump the SOURCE window to a marker row's file:line (<CR>); foreign files load via bufadd
-- (never :edit — unsaved-changes-safe). Landing in another file, follow retargets there.
local function jump_to_marker()
  if not S then return end
  local row = vim.api.nvim_win_get_cursor(S.win)[1]
  local j = S.sync.jump and S.sync.jump[row]
  if not j then return end
  local win = (S.sync.srcwin and vim.api.nvim_win_is_valid(S.sync.srcwin)) and S.sync.srcwin or nil
  if not win then
    return require("fox-symdeps.ui").notify_raw("fox-symdeps · source window gone — reopen a code window", vim.log.levels.WARN)
  end
  local path = j.path
  if vim.fn.filereadable(path) ~= 1 then
    -- DWARF paths can carry ../ compositions or a different root — resolve via the same rule
    local norm = vim.fs.normalize(path)
    if vim.fn.filereadable(norm) == 1 then path = norm
    else
      return require("fox-symdeps.ui").notify_raw("fox-symdeps · " .. path .. " not readable here (out-of-tree DWARF path)", vim.log.levels.WARN)
    end
  end
  local b = vim.fn.bufadd(path)
  vim.fn.bufload(b)
  vim.api.nvim_set_current_win(win)
  vim.api.nvim_win_set_buf(win, b)
  pcall(vim.api.nvim_win_set_cursor, win, { math.max(j.line, 1), 0 })
end

local function ensure_card(title, invoking_win)
  if S and vim.api.nvim_buf_is_valid(S.buf) and vim.api.nvim_win_is_valid(S.win) then
    vim.wo[S.win].winbar = "%#FoxSymdepsTitle# " .. title .. " %*"
    return
  end
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].filetype = "asm"
  vim.cmd("rightbelow vsplit")
  local win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(win, buf)
  vim.wo[win].number = false
  vim.wo[win].relativenumber = false   -- the global rnu leaked in (dogfood gutter 16..0..25)
  vim.wo[win].wrap = false             -- long demangled call targets wrapped into 6-line blocks
  vim.wo[win].winbar = "%#FoxSymdepsTitle# " .. title .. " %*"
  vim.wo[win].winhighlight = "Normal:FoxSymdepsNormal"
  S = { win = win, buf = buf, sync = {} }
  vim.keymap.set("n", "q", close_card, { buffer = buf, nowait = true, desc = "fox-symdeps: close shipped-asm card" })
  vim.keymap.set("n", "<CR>", jump_to_marker, { buffer = buf, nowait = true, desc = "fox-symdeps: jump to marker file:line" })
  vim.keymap.set("n", "r", function()
    if S and S.symbol and not S.busy then
      resolve_into(S.symbol, S.sync.srcbuf, S.sync.srcwin)
    end
  end, { buffer = buf, nowait = true, desc = "fox-symdeps: re-resolve (after a rebuild)" })
  S.aug = vim.api.nvim_create_augroup("FoxSymdepsAsmShipped", { clear = true })
  vim.api.nvim_create_autocmd("CursorMoved", {   -- source → asm sync (global; srcbuf changes on follow)
    group = S.aug,
    callback = function()
      if not (S and S.sync.by_src) then return end
      if vim.api.nvim_get_current_buf() ~= S.sync.srcbuf then return end
      if not vim.api.nvim_win_is_valid(S.win) then return end
      local sl = vim.api.nvim_win_get_cursor(0)[1]
      local rows = S.sync.by_src[sl]
      if not rows or #rows == 0 then return end
      paint_sync(sl, rows)
      pcall(vim.api.nvim_win_set_cursor, S.win, { rows[1], 0 })
      vim.api.nvim_win_call(S.win, function() vim.cmd("normal! zz") end)
    end,
  })
  vim.api.nvim_create_autocmd("CursorMoved", {   -- asm → source sync
    group = S.aug, buffer = buf,
    callback = function()
      if not (S and S.sync.src_of) then return end
      if vim.api.nvim_get_current_win() ~= S.win then return end
      if not (S.sync.srcwin and vim.api.nvim_win_is_valid(S.sync.srcwin)) then return end
      local sl = S.sync.src_of[vim.api.nvim_win_get_cursor(S.win)[1]]
      if not sl then return end
      paint_sync(sl, S.sync.by_src[sl])
      pcall(vim.api.nvim_win_set_cursor, S.sync.srcwin, { sl, 0 })
      vim.api.nvim_win_call(S.sync.srcwin, function() vim.cmd("normal! zz") end)
    end,
  })
  vim.api.nvim_create_autocmd({ "CursorHold", "CursorHoldI", "BufEnter" }, {  -- the FOLLOW trigger
    group = S.aug, callback = maybe_follow,
  })
  vim.api.nvim_create_autocmd("WinClosed", {
    pattern = tostring(win), once = true, callback = close_card,
  })
  if invoking_win and vim.api.nvim_win_is_valid(invoking_win) then
    vim.api.nvim_set_current_win(invoking_win)   -- keep the user in their code
  end
end

local function render(lines, title, sync_tbl, invoking_win)
  ensure_card(title, invoking_win)
  vim.bo[S.buf].modifiable = true
  vim.api.nvim_buf_set_lines(S.buf, 0, -1, false, lines)
  vim.bo[S.buf].modifiable = false
  paint_lines(S.buf, lines)
  -- clear stale sync highlights from the previous target before swapping maps
  if S.sync.srcbuf and vim.api.nvim_buf_is_valid(S.sync.srcbuf) then
    pcall(vim.api.nvim_buf_clear_namespace, S.sync.srcbuf, NS_SYNC, 0, -1)
  end
  pcall(vim.api.nvim_buf_clear_namespace, S.buf, NS_SYNC, 0, -1)
  S.sync = sync_tbl
end

-- the resolve pipeline → render into the ONE card. Used by open (initial), follow, and `r`.
resolve_into = function(symbol, srcbuf, srcwin)
  local root = root_of(vim.api.nvim_buf_get_name(srcbuf))
  local cars = sidecars(root)
  if #cars == 0 then
    return require("fox-symdeps.ui").notify_raw(
      "fox-symdeps · shipped-asm REFUSED: no build*/asm sidecars — run ./build.sh asm first", vim.log.levels.ERROR)
  end
  if S then S.busy = true end
  find_blocks(cars, symbol, function(defs, calls)
    local pick, others, callsum = nil, {}, 0
    for _, c in ipairs(cars) do
      if defs[c.path] then
        if pick then others[#others + 1] = c.prov.binary else pick = c end
      end
      callsum = callsum + (calls[c.path] or 0)
    end
    if not pick then
      local searched = {}
      for _, c in ipairs(cars) do searched[#searched + 1] = c.prov.binary end
      local lines = {
        ("  %s — NO standalone copy in any shipped binary"):format(symbol),
        ("  inlined at every call site — a FACT about the shipped code, not a failure"),
        ("  (%d sidecar%s searched: %s)"):format(#cars, #cars == 1 and "" or "s", table.concat(searched, " · ")),
      }
      if callsum > 0 then
        lines[#lines + 1] = ("  referenced %d time%s across the sidecars (call-site annotations)")
                            :format(callsum, callsum == 1 and "" or "s")
      end
      render(lines, "asm · SHIPPED 1:1 · " .. symbol .. " · INLINED-AWAY",
             { srcbuf = srcbuf, srcwin = srcwin }, srcwin)
      S.symbol, S.busy = symbol, false
      return
    end
    freshness(pick.prov, root, function(verdict, now16)
      local hits = defs[pick.path]
      local done, out = 0, {}
      for i, h in ipairs(hits) do
        extract(pick.path, h.lnum, function(blines)
          out[i] = blines
          done = done + 1
          if done == #hits then
            local src_abs = vim.api.nvim_buf_get_name(srcbuf)
            local lines = {
              ("  shipped: %s · sha16 %s · emitted at %s"):format(pick.prov.binary, pick.prov.sha16, pick.prov.head),
            }
            if verdict == "stale" then
              lines[#lines + 1] = ("  ⚠ STALE — binary rebuilt since emit (now %s); re-run ./build.sh asm, then `r`"):format(now16 or "?")
            elseif verdict == "binary-missing" then
              lines[#lines + 1] = "  ⚠ binary no longer on disk — sidecar is an orphan of an old build"
            end
            if #others > 0 then lines[#lines + 1] = "  also in: " .. table.concat(others, " · ") end
            if #hits > 1 then
              lines[#lines + 1] = ("  %d instantiation blocks in this binary (all shown — each is real shipped code)"):format(#hits)
            end
            local insn_at = #lines + 1
            lines[#lines + 1] = ""   -- per-function instruction count, filled after mapping
            lines[#lines + 1] = ""
            local by_src, src_of, jump, total = {}, {}, {}, 0
            for _, b in ipairs(out) do
              local m = M.line_map(b, src_abs, #lines)
              vim.list_extend(lines, m.display)
              for k, v in pairs(m.src_of) do src_of[k] = v end
              for k, v in pairs(m.jump) do jump[k] = v end
              for sl, rows in pairs(m.by_src) do
                by_src[sl] = by_src[sl] or {}
                vim.list_extend(by_src[sl], rows)
              end
              total = total + m.n_insn
              lines[#lines + 1] = ""
            end
            lines[insn_at] = ("  %d shipped instruction%s%s"):format(
              total, total == 1 and "" or "s",
              next(by_src) and "  ·  synced (move in either pane · <CR> jumps markers · r refreshes)"
                            or "  ·  no line info in this sidecar — rebuild (./build.sh engine|gui) for source-sync")
            local mark = verdict == "fresh" and "" or " · ⚠ " .. verdict
            render(lines, ("asm · SHIPPED 1:1 · %s · %s%s"):format(
                     symbol, pick.prov.binary:match("[^/]+$") or pick.prov.binary, mark),
                   { srcbuf = srcbuf, srcwin = srcwin, by_src = by_src, src_of = src_of, jump = jump },
                   srcwin)
            S.symbol, S.busy = symbol, false
          end
        end)
      end
    end)
  end)
end

function M.open(palette)
  if S then return close_card() end   -- toggle (operator ask: the ONE live card)
  local buf = vim.api.nvim_get_current_buf()
  local srcwin = vim.api.nvim_get_current_win()
  local row0 = vim.api.nvim_win_get_cursor(0)[1] - 1
  -- resolution chain: tagged FUNCTION block → treesitter enclosing function → <cword>
  -- (keyword-guarded — the "for" dogfood bug: untagged fn + mid-body cursor grabbed a keyword)
  local symbol, blk = symbol_at(buf, row0)
  -- per-FUNCTION view, said honestly (dogfood 2026-08-13: firing inside the FPN_Binary STRUCT
  -- rendered a function that merely TAKES the type — misleading; the guard names the mismatch)
  if not symbol and blk and blk.type ~= "FUNCTION" then
    return require("fox-symdeps.ui").notify_raw(
      ("fox-symdeps · shipped-asm is a per-FUNCTION view; %s is a %s — put the cursor inside a "
       .. "function body (struct layout lives on the HUD / board)"):format(blk.name, blk.type:lower()),
      vim.log.levels.WARN)
  end
  if not symbol then
    local cw = vim.fn.expand("<cword>")
    if cw ~= "" and not M.KEYWORDS[cw] then symbol = M.base_symbol(cw) end
  end
  if not symbol or symbol == "" then
    return require("fox-symdeps.ui").notify_raw(
      "fox-symdeps · shipped-asm: no function at cursor (and no symbol under it)", vim.log.levels.WARN)
  end
  resolve_into(symbol, buf, srcwin)
end

-- test hooks (asmexplorer's M._ convention): the async glue, drivable from fixtures/smokes
M._sidecars, M._find_blocks, M._extract, M._freshness = sidecars, find_blocks, extract, freshness
M._state = function() return S end
return M
