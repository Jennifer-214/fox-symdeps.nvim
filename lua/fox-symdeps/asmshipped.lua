-- asmshipped.lua — the SHIPPED-asm card (0.5; the TD-257 viewer half; ideas §2's "use the real
-- build to view"). Reads the `./build.sh asm` sidecars (`build*/asm/<binary>.asm` — objdump of
-- the LINKED artifact) and NEVER recompiles: under -flto the shipped code exists only post-link,
-- so the sidecar IS the 1:1 truth the explorer's editor-flags recompile only approximates.
--
-- Honest states, all NAMED (Class 57 — never an empty pane):
--   FOUND         the function's shipped instructions, provenance in the winbar; other binaries
--                 carrying it are listed, instantiation blocks all shown (multiplicity is fact)
--   INLINED-AWAY  zero standalone copies across every sidecar searched — a FACT about the shipped
--                 binary (the Notify_Send answer), rendered as a statement, not a blank
--   STALE         sidecar's recorded binary-sha16 ≠ the binary's current sha16 → rendered WITH a
--                 loud banner (old asm is real asm — of the OLD binary), never silently
--   NO-SIDECAR    refusal naming the fix: run `./build.sh asm`
--
-- Sweep order = newest recorded binary first (recency-as-rule, §11(iii): the binary you just
-- built is the one you're dogfooding). <leader>ds.
local M = {}

-- ── pure core (the teeth hit these directly) ─────────────────────────────────────────────────

-- sidecar header (the ./build.sh asm provenance contract, 3 lines) → { binary, sha16, mtime,
-- head } | nil, reason. Tri-state: a mutilated header is a NAMED refusal, never {}.
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

-- pure: an extracted `-l` block → { display, src_of, by_src, n_insn }. Marker lines
-- (`/abs/path:NNN`) become dimmed `· name:NNN` rows — `· from <file>:NNN` when the code was
-- INLINED FROM another file (visible cross-TU attribution, which no per-TU compile can show);
-- instruction rows under a current-file marker enter the bidirectional maps. n_insn = the
-- function's SHIPPED instruction count (the budget-checkable number — H7/H8 join rides the
-- probe-cutover leaf).
function M.line_map(block_lines, src_abs, offset)
  offset = offset or 0
  local display, src_of, by_src, n_insn = {}, {}, {}, 0
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
  return { display = display, src_of = src_of, by_src = by_src, n_insn = n_insn }
end

-- newest-first over parsed sidecars (recorded binary mtime; recency-as-rule §11(iii)).
function M.sweep_order(cars)
  table.sort(cars, function(a, b) return (a.prov.mtime or 0) > (b.prov.mtime or 0) end)
  return cars
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

-- ── the card ─────────────────────────────────────────────────────────────────────────────────

local NS_SYNC = vim.api.nvim_create_namespace("fox_symdeps_asmshipped_sync")
local NS_PAINT = vim.api.nvim_create_namespace("fox_symdeps_asmshipped_paint")

-- deterministic painter — theme-linked BUILTIN groups, zero parser deps (dogfood 2026-08-13:
-- "the asm is missing the text colors"; an asm treesitter/syntax file may or may not exist on
-- a given setup, and our content isn't pure asm anyway — markers + demangled context lines).
-- addresses=Number · mnemonics=Statement · %registers=Identifier · $immediates=Constant ·
-- <call-targets>=Special · `· file:line` markers=Comment (`· from` foreign=DiagnosticHint) ·
-- demangled context lines=Type · block headers=Function · provenance/⚠=Title/WarningMsg.
local function paint_lines(buf, lines)
  local function mark(row, s, e, grp)
    pcall(vim.api.nvim_buf_set_extmark, buf, NS_PAINT, row - 1, s - 1, { end_col = e, hl_group = grp })
  end
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

-- show the card; when `sync` = { srcbuf, srcwin, by_src, src_of } is given, wire BIDIRECTIONAL
-- cursor sync (operator ask 2026-08-13: "highlight the lines on both so they both scroll at the
-- same time"): source line ↔ its shipped instructions, both panes highlighted, the counterpart
-- scrolled into view. Each direction fires only from the pane that HAS focus (no ping-pong).
local function show(lines, title, palette, sync)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].filetype = "asm"
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  paint_lines(buf, lines)
  vim.cmd("rightbelow vsplit")
  local win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(win, buf)
  vim.wo[win].number = false
  vim.wo[win].relativenumber = false   -- the global rnu leaked in (dogfood gutter 16..0..25)
  vim.wo[win].wrap = false             -- long demangled call targets wrapped into 6-line blocks
  vim.wo[win].winbar = "%#FoxSymdepsTitle# " .. title .. " %*"
  vim.wo[win].winhighlight = "Normal:FoxSymdepsNormal"

  local aug
  local function cleanup()
    if aug then pcall(vim.api.nvim_del_augroup_by_id, aug) end
    if sync and vim.api.nvim_buf_is_valid(sync.srcbuf) then
      vim.api.nvim_buf_clear_namespace(sync.srcbuf, NS_SYNC, 0, -1)
    end
    pcall(vim.api.nvim_win_close, win, true)
  end
  vim.keymap.set("n", "q", cleanup, { buffer = buf, nowait = true, desc = "fox-symdeps: close shipped-asm card" })

  if sync and next(sync.by_src) then
    vim.api.nvim_set_current_win(sync.srcwin)   -- keep the user in their code
    local function paint(srcline, asmrows)
      pcall(vim.api.nvim_buf_clear_namespace, sync.srcbuf, NS_SYNC, 0, -1)
      pcall(vim.api.nvim_buf_clear_namespace, buf, NS_SYNC, 0, -1)
      if srcline then
        pcall(vim.api.nvim_buf_set_extmark, sync.srcbuf, NS_SYNC, srcline - 1, 0,
              { line_hl_group = "FoxSymdepsSelection" })
      end
      -- asm side = the whisper BAND (bg-only; a vectorized line maps to ~40 rows — a solid bar
      -- group swallowed the text, operator dogfood): text keeps its painted colors.
      for _, r in ipairs(asmrows or {}) do
        pcall(vim.api.nvim_buf_set_extmark, buf, NS_SYNC, r - 1, 0,
              { line_hl_group = "FoxSymdepsSyncLine" })
      end
    end
    aug = vim.api.nvim_create_augroup("FoxSymdepsAsmShipped_" .. buf, { clear = true })
    vim.api.nvim_create_autocmd("CursorMoved", {
      group = aug, buffer = sync.srcbuf,
      callback = function()
        if vim.api.nvim_get_current_win() ~= sync.srcwin then return end
        if not vim.api.nvim_win_is_valid(win) then return end
        local sl = vim.api.nvim_win_get_cursor(sync.srcwin)[1]
        local rows = sync.by_src[sl]
        if not rows or #rows == 0 then return end
        paint(sl, rows)
        pcall(vim.api.nvim_win_set_cursor, win, { rows[1], 0 })
        vim.api.nvim_win_call(win, function() vim.cmd("normal! zz") end)
      end,
    })
    vim.api.nvim_create_autocmd("CursorMoved", {
      group = aug, buffer = buf,
      callback = function()
        if vim.api.nvim_get_current_win() ~= win then return end
        if not vim.api.nvim_win_is_valid(sync.srcwin) then return end
        local ar = vim.api.nvim_win_get_cursor(win)[1]
        local sl = sync.src_of[ar]
        if not sl then return end
        paint(sl, sync.by_src[sl])
        pcall(vim.api.nvim_win_set_cursor, sync.srcwin, { sl, 0 })
        vim.api.nvim_win_call(sync.srcwin, function() vim.cmd("normal! zz") end)
      end,
    })
    vim.api.nvim_create_autocmd("WinClosed", {
      pattern = tostring(win), once = true,
      callback = function()
        if aug then pcall(vim.api.nvim_del_augroup_by_id, aug) end
        if vim.api.nvim_buf_is_valid(sync.srcbuf) then
          pcall(vim.api.nvim_buf_clear_namespace, sync.srcbuf, NS_SYNC, 0, -1)
        end
      end,
    })
  end
end

function M.open(palette)
  local buf = vim.api.nvim_get_current_buf()
  local srcwin = vim.api.nvim_get_current_win()
  local row0 = vim.api.nvim_win_get_cursor(0)[1] - 1
  local blk = require("fox-symdeps.tagcontext").enclosing_block(buf, row0)
  -- per-FUNCTION view, said honestly (dogfood 2026-08-13: firing inside the FPN_Binary STRUCT
  -- rendered a function that merely TAKES the type — misleading; the guard names the mismatch)
  if blk and blk.type ~= "FUNCTION" then
    return require("fox-symdeps.ui").notify_raw(
      ("fox-symdeps · shipped-asm is a per-FUNCTION view; %s is a %s — put the cursor inside a "
       .. "function body (struct layout lives on the HUD / board)"):format(blk.name, blk.type:lower()),
      vim.log.levels.WARN)
  end
  local raw = (blk and blk.name) or vim.fn.expand("<cword>")
  local symbol = M.base_symbol(raw)
  if symbol == "" then
    return require("fox-symdeps.ui").notify_raw("fox-symdeps · shipped-asm: no symbol at cursor", vim.log.levels.WARN)
  end
  local root = root_of(vim.api.nvim_buf_get_name(buf))
  local cars = sidecars(root)
  if #cars == 0 then
    return require("fox-symdeps.ui").notify_raw(
      "fox-symdeps · shipped-asm REFUSED: no build*/asm sidecars — run ./build.sh asm first", vim.log.levels.ERROR)
  end
  find_blocks(cars, symbol, function(defs, calls)
    -- pick the first sidecar (newest recorded binary) that carries a definition
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
      return show(lines, "asm · SHIPPED 1:1 · " .. symbol .. " · INLINED-AWAY", palette)
    end
    freshness(pick.prov, root, function(verdict, now16)
      local hits = defs[pick.path]
      local done, out = 0, {}
      for i, h in ipairs(hits) do
        extract(pick.path, h.lnum, function(blines)
          out[i] = blines
          done = done + 1
          if done == #hits then
            local src_abs = vim.api.nvim_buf_get_name(buf)
            local lines = {
              ("  shipped: %s · sha16 %s · emitted at %s"):format(pick.prov.binary, pick.prov.sha16, pick.prov.head),
            }
            if verdict == "stale" then
              lines[#lines + 1] = ("  ⚠ STALE — binary rebuilt since emit (now %s); re-run ./build.sh asm"):format(now16 or "?")
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
            -- per-block line_map: markers become dimmed rows, instructions enter the
            -- bidirectional maps (indices are FINAL display-buffer line numbers)
            local by_src, src_of, total = {}, {}, 0
            for _, b in ipairs(out) do
              local m = M.line_map(b, src_abs, #lines)
              vim.list_extend(lines, m.display)
              for k, v in pairs(m.src_of) do src_of[k] = v end
              for sl, rows in pairs(m.by_src) do
                by_src[sl] = by_src[sl] or {}
                vim.list_extend(by_src[sl], rows)
              end
              total = total + m.n_insn
              lines[#lines + 1] = ""
            end
            lines[insn_at] = ("  %d shipped instruction%s%s"):format(
              total, total == 1 and "" or "s",
              next(by_src) and "  ·  cursor-synced (both panes highlight; move in either)"
                            or "  ·  no line info in this sidecar — rebuild (./build.sh engine|gui) for source-sync")
            local mark = verdict == "fresh" and "" or " · ⚠ " .. verdict
            show(lines, ("asm · SHIPPED 1:1 · %s · %s%s"):format(symbol, pick.prov.binary:match("[^/]+$") or pick.prov.binary, mark),
                 palette, { srcbuf = buf, srcwin = srcwin, by_src = by_src, src_of = src_of })
          end
        end)
      end
    end)
  end)
end

-- test hooks (asmexplorer's M._ convention): the async glue, drivable from fixtures/smokes
M._sidecars, M._find_blocks, M._extract, M._freshness = sidecars, find_blocks, extract, freshness
return M
