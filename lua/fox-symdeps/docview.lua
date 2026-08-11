-- docview.lua — the [REFERENCE] pop-out doc-viewer (north-star §6; the 0.4 dead-link check).
-- Renders the [REFERENCE] vocab axis (§9's law — an affordance cites which axis it renders):
-- the enclosing unit's `[REFERENCE]_[SUBCAT]_[ids]` tags resolve to their DEFINING sites via
-- `citable_ids.py --where` (ONE subprocess, a `defining_site/1` envelope) and the doc floats
-- beside the code. Tri-state honest at the UI seam (Class 57): FOUND → float · resolver
-- failed-to-run → named ERROR · MISSING id → named refusal — NEVER a blank float.
local M = {}

-- pure: block lines → ordered unique {subcat, id} entries from [REFERENCE] lines. cursor_rel
-- (1-based index into `lines`, optional): if THAT line is a [REFERENCE] line, only its
-- entries win (point-at-a-thing beats whole-unit).
function M.ref_entries(lines, cursor_rel)
  local function entries_of(l)
    local sub, val = l:match("%[REFERENCE%]_%[([%u%d_|]+)%]_%[(.+)%]%s*$")
    if not sub then return nil end
    local out = {}
    for tok in val:gmatch("%[([^%[%]]+)%]") do out[#out + 1] = { subcat = sub, id = tok } end
    if #out == 0 then out[1] = { subcat = sub, id = vim.trim(val) } end
    return out
  end
  if cursor_rel then
    local at = entries_of(lines[cursor_rel] or "")
    if at then return at end
  end
  local seen, out = {}, {}
  for _, l in ipairs(lines) do
    for _, e in ipairs(entries_of(l) or {}) do
      local k = e.subcat .. "\0" .. e.id
      if not seen[k] then seen[k] = true; out[#out + 1] = e end
    end
  end
  return out
end

-- back-compat id list (tests + file_header_ids callers)
function M.ref_ids(lines, cursor_rel)
  local out = {}
  for _, e in ipairs(M.ref_entries(lines, cursor_rel)) do out[#out + 1] = e.id end
  return out
end

-- pure: entries → { where = {id…}, resolve = {name…}, skipped = {label…} }. ID-shaped subcats
-- ride `--where` (defining-site lookup); DOC-shaped (DESIGN_SPEC/MEMORY/PLAN) ride `--resolve`
-- (bare-name path probe; `.md` appended when absent); AUDIT/SOURCE/URL are existence-unchecked
-- free-form → skipped, NAMED (never silently dropped).
local DOC_SUBCATS = { DESIGN_SPEC = true, MEMORY = true, PLAN = true }
local FREE_SUBCATS = { AUDIT = true, SOURCE = true, URL = true }
function M.route(entries)
  -- vocab-validated (fleet K3): an UNFENCED subcat is skipped-NAMED, never silently defaulted
  -- into --where. nil-safe: without the grammar payload (tests / foxtag-less checkout) the
  -- known-set check is simply not applied.
  local okn, nmod = pcall(require, "fox-symdeps.nodemodel")
  local fenced = okn and nmod.vocab and nmod.vocab()
  fenced = fenced and fenced.ref_subcats or nil
  local r = { where = {}, resolve = {}, skipped = {} }
  for _, e in ipairs(entries) do
    if DOC_SUBCATS[e.subcat] then
      r.resolve[#r.resolve + 1] = e.id:match("%.md$") and e.id or (e.id .. ".md")
    elseif FREE_SUBCATS[e.subcat] then
      r.skipped[#r.skipped + 1] = ("%s:%s"):format(e.subcat, e.id)
    elseif fenced and not fenced[e.subcat] then
      r.skipped[#r.skipped + 1] = ("%s:%s (unknown subcat)"):format(e.subcat, e.id)
    else
      r.where[#r.where + 1] = e.id
    end
  end
  return r
end

-- pure: RECENCY sort for the chooser (operator rule 2026-08-10, renderer-level): group by id
-- prefix, NEWEST (highest number) first within a group — for the namespaces where numbering IS
-- chronology (D/TECH_DEBT/PARITY/Class); no-digit doc names fall back to name order.
function M.sort_found(found)
  table.sort(found, function(a, b)
    local ap = a.id:gsub("%d.*$", "")
    local bp = b.id:gsub("%d.*$", "")
    local an = tonumber(a.id:match("(%d+)")) or -1
    local bn = tonumber(b.id:match("(%d+)")) or -1
    if ap ~= bp then return ap < bp end
    if an ~= bn then return an > bn end
    return a.id < b.id
  end)
  return found
end

-- pure: envelope rows → { found = { {id,file,line} … }, missing = { id … } }. A row set with
-- BOTH is rendered as float(s) + a named warning — the missing ids are never silently dropped.
function M.partition(rows)
  local found, missing = {}, {}
  for _, r in ipairs(rows or {}) do
    if r[2] == "FOUND" then
      found[#found + 1] = { id = r[1], file = r[3], line = r[4] }
    else
      missing[#missing + 1] = r[1]
    end
  end
  return { found = found, missing = missing }
end

-- PIN — the persistent role of the §6 HUD-vs-PANEL duality (operator ask 2026-08-10: "docs +
-- code" side by side while working). A real RIGHTMOST vertical split, not a pinned float: a
-- split participates in the layout (resizes with it, stacks multiple pins, closes like any
-- window — :q), so persistence costs zero custom lifecycle code.
function M.pin(site)
  vim.cmd("botright vsplit")
  local win = vim.api.nvim_get_current_win()
  local buf = vim.fn.bufadd(site.file)
  vim.fn.bufload(buf)
  vim.api.nvim_win_set_buf(win, buf)
  pcall(vim.api.nvim_win_set_cursor, win, { math.max(site.line, 1), 0 })
  vim.wo[win].cursorline = true
  vim.api.nvim_win_set_width(win, math.max(60, math.floor(vim.o.columns * 0.42)))
  vim.wo[win].winfixwidth = true   -- survives `wincmd =` rebalances (fleet S6)
end

-- Float the REAL buffer of the defining doc beside the code (right edge), cursor on the
-- defining line — syntax, search, and jumps all work. q closes; p PROMOTES the float to the
-- pinned split (both buffer-local maps removed when the float closes — incl. by promotion).
local function open_float(site)
  local buf = vim.fn.bufadd(site.file)
  vim.fn.bufload(buf)
  local W, H = vim.o.columns, vim.o.lines
  local w = math.min(110, math.max(60, math.floor(W * 0.55)))
  local h = math.floor(H * 0.72)
  local win = vim.api.nvim_open_win(buf, true, {
    relative = "editor", row = math.max(1, math.floor((H - h) / 2) - 1), col = W - w - 2,
    width = w, height = h, border = "rounded",
    title = ("  %s — %s:%d · p=pin · q=close "):format(
      site.id, vim.fn.fnamemodify(site.file, ":t"), site.line),
    title_pos = "left",
  })
  pcall(vim.api.nvim_win_set_cursor, win, { math.max(site.line, 1), 0 })
  vim.wo[win].cursorline = true
  vim.keymap.set("n", "q", function() pcall(vim.api.nvim_win_close, win, true) end,
                 { buffer = buf, nowait = true, desc = "fox-symdeps: close doc float" })
  vim.keymap.set("n", "p", function()
    M.pin(site)
    pcall(vim.api.nvim_win_close, win, true)   -- close AFTER pinning; WinClosed clears the maps
  end, { buffer = buf, nowait = true, desc = "fox-symdeps: pin doc to a split" })
  -- TRANSIENT-LENS semantics (operator §11(v), 2026-08-10): leaving the float dismisses it —
  -- directional window-nav skips floats, so a survive-on-leave float becomes an unreachable
  -- orphan; KEEPING the doc is what p-pin exists for (a split IS hjkl-navigable).
  local dismiss = vim.api.nvim_create_autocmd("WinLeave", {
    callback = function()
      if vim.api.nvim_get_current_win() ~= win then return end
      vim.schedule(function() pcall(vim.api.nvim_win_close, win, true) end)
    end,
  })
  vim.api.nvim_create_autocmd("WinClosed", {
    pattern = tostring(win), once = true,
    callback = function()
      pcall(vim.api.nvim_del_autocmd, dismiss)
      pcall(vim.keymap.del, "n", "q", { buffer = buf })
      pcall(vim.keymap.del, "n", "p", { buffer = buf })
    end,
  })
end

-- FILE-header fallback (macros + file-scope): [FILE]/[MACRO] are LIGHT units (no span), so a
-- cursor outside any closable unit — or inside one carrying no [REFERENCE] — falls back to
-- the FILE banner's refs (the header region above the first closable opener).
function M.file_header_ids(buf)
  local nmod = require("fox-symdeps.nodemodel").scope_openers()
  local n = math.min(vim.api.nvim_buf_line_count(buf), 400)
  local lines = vim.api.nvim_buf_get_lines(buf, 0, n, false)
  local stop = #lines
  if nmod then
    for i, l in ipairs(lines) do
      local ty = l:match("//%s*%[(%u+)%]_%[")
      if ty and nmod[ty] then stop = i - 1; break end
    end
  end
  local head = {}
  for i = 1, stop do head[i] = lines[i] end
  return M.ref_entries(head)
end

-- The entry point: resolve the enclosing unit's [REFERENCE] ids → float / chooser / refusal;
-- unit-first, FILE-header fallback (named when it fires).
local function _decode(out_lines, table_name)
  if not out_lines then return nil end
  local ok, env = pcall(vim.json.decode, table.concat(out_lines, "\n"))
  if not ok or type(env) ~= "table"
     or not (env.payload and env.payload[table_name] and env.payload[table_name].rows) then
    return nil
  end
  return env.payload[table_name].rows
end

function M.open()
  local buf = vim.api.nvim_get_current_buf()
  local row0 = vim.api.nvim_win_get_cursor(0)[1] - 1
  local blk = require("fox-symdeps.tagcontext").enclosing_block(buf, row0)
  local entries = {}
  if blk then
    local blines = vim.api.nvim_buf_get_lines(buf, blk.opener, blk.closer + 1, false)
    entries = M.ref_entries(blines, row0 - blk.opener + 1)
  end
  if #entries == 0 then
    entries = M.file_header_ids(buf)
    if #entries > 0 and blk then
      vim.notify("fox-symdeps · " .. (blk.name or "unit") ..
                 " has no [REFERENCE] — showing the FILE header's", vim.log.levels.INFO)
    end
  end
  if #entries == 0 then
    return vim.notify("fox-symdeps · no [REFERENCE] tags here (unit or FILE header)",
                      vim.log.levels.INFO)
  end
  local r = M.route(entries)
  if #r.skipped > 0 then
    vim.notify("fox-symdeps · free-form ref(s) not routable (AUDIT/SOURCE/URL): "
               .. table.concat(r.skipped, " · "), vim.log.levels.INFO)
  end
  local file = vim.api.nvim_buf_get_name(buf)
  local root = vim.fs.root(file, { ".git", "compile_commands.json" })
               or vim.fn.fnamemodify(file, ":h")
  local runner = require("fox-symdeps.runner")
  local found, missing = {}, {}
  local pending = (#r.where > 0 and 1 or 0) + (#r.resolve > 0 and 1 or 0)
  if pending == 0 then return end
  -- perceived-latency chip (operator polish #2): the resolver round-trip is ~200-500ms — name
  -- the wait so the gap reads as work, not deadness
  vim.notify(("fox-symdeps · resolving %d ref(s)…"):format(#entries), vim.log.levels.INFO)

  local function finish()
    if #missing > 0 then
      vim.notify("fox-symdeps · DEAD [REFERENCE] — does not resolve at HEAD: "
                 .. table.concat(missing, " · "), vim.log.levels.WARN)
    end
    if #found == 0 then return end                 -- refusals named above; never a blank float
    if #found == 1 then return open_float(found[1]) end
    M.sort_found(found)
    local items = {}
    for _, s in ipairs(found) do
      -- compact label: last two path segments (full-path labels wrapped the chooser);
      -- the float title carries file:line after opening
      local segs = {}
      for seg in s.file:gmatch("[^/]+") do segs[#segs + 1] = seg end
      local short = (#segs >= 2) and (segs[#segs - 1] .. "/" .. segs[#segs]) or s.file
      items[#items + 1] = {
        label = ("%s — %s:%d"):format(s.id, short, s.line),
        run = function() open_float(s) end,
      }
    end
    local pal_ok, fox = pcall(require, "fox-symdeps")
    require("fox-symdeps.menu").open(items, {
      title = "[REFERENCE] → defining site",
      palette = pal_ok and fox.config and fox.config.palette or nil,   -- family styling (fleet P6/S6)
    })
  end
  local function done_one() pending = pending - 1; if pending == 0 then finish() end end

  if #r.where > 0 then
    local argv = { "python3", "tools/citable_ids.py", "--where" }
    for _, id in ipairs(r.where) do argv[#argv + 1] = id end
    runner.run(argv, root, function(out_lines)
      local rows = _decode(out_lines, "sites")
      if not rows then
        vim.notify("fox-symdeps · --where resolver FAILED to run (refusal, not empty facts)",
                   vim.log.levels.ERROR)
      else
        local p = M.partition(rows)
        vim.list_extend(found, p.found)
        vim.list_extend(missing, p.missing)
      end
      done_one()
    end)
  end
  if #r.resolve > 0 then
    local argv = { "python3", "tools/citable_ids.py", "--resolve" }
    for _, nm in ipairs(r.resolve) do argv[#argv + 1] = nm end
    runner.run(argv, root, function(out_lines)
      local rows = _decode(out_lines, "resolutions")
      if not rows then
        vim.notify("fox-symdeps · --resolve resolver FAILED to run (refusal, not empty facts)",
                   vim.log.levels.ERROR)
      else
        for _, row in ipairs(rows) do
          if row[2] == "RESOLVED" then
            found[#found + 1] = { id = row[1], file = row[3], line = 1 }
          elseif row[2] == "RENAMED" then
            vim.notify(("fox-symdeps · %s RENAMED → %s (re-run the miner to repair the tag)")
                       :format(row[1], row[3]), vim.log.levels.INFO)
          else
            missing[#missing + 1] = row[1]
          end
        end
      end
      done_one()
    end)
  end
end

return M
