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

-- is this line an objdump DEFINITION block header for `symbol`? Header form (column 1):
-- `hex <demangled>:`. The symbol must sit on identifier boundaries inside <…> (call-site
-- annotations like `call … <Sym+0x10>` are indented operands, not column-1 headers).
function M.match_block_header(line, symbol)
  local inner = (line or ""):match("^%x+ <(.+)>:$")
  if not inner or symbol == "" then return false end
  local from = 1
  while true do
    local s, e = inner:find(symbol, from, true)
    if not s then return false end
    local before = s == 1 and "" or inner:sub(s - 1, s - 1)
    local after = inner:sub(e + 1, e + 1)
    if not before:match("[%w_]") and not after:match("[%w_]") then return true end
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

local function show(lines, title, palette)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].filetype = "asm"
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  vim.cmd("rightbelow vsplit")
  local win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(win, buf)
  vim.wo[win].number = false
  vim.wo[win].winbar = "%#FoxSymdepsTitle# " .. title .. " %*"
  vim.wo[win].winhighlight = "Normal:FoxSymdepsNormal"
  vim.keymap.set("n", "q", function() pcall(vim.api.nvim_win_close, win, true) end,
                 { buffer = buf, nowait = true, desc = "fox-symdeps: close shipped-asm card" })
end

function M.open(palette)
  local buf = vim.api.nvim_get_current_buf()
  local row0 = vim.api.nvim_win_get_cursor(0)[1] - 1
  local blk = require("fox-symdeps.tagcontext").enclosing_block(buf, row0)
  local raw = (blk and blk.type == "FUNCTION" and blk.name) or vim.fn.expand("<cword>")
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
            lines[#lines + 1] = ""
            for _, b in ipairs(out) do
              vim.list_extend(lines, b)
              lines[#lines + 1] = ""
            end
            local mark = verdict == "fresh" and "" or " · ⚠ " .. verdict
            show(lines, ("asm · SHIPPED 1:1 · %s · %s%s"):format(symbol, pick.prov.binary:match("[^/]+$") or pick.prov.binary, mark), palette)
          end
        end)
      end
    end)
  end)
end

-- test hooks (asmexplorer's M._ convention): the async glue, drivable from fixtures/smokes
M._sidecars, M._find_blocks, M._extract, M._freshness = sidecars, find_blocks, extract, freshness
return M
