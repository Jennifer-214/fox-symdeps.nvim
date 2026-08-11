-- docview.lua — the [REFERENCE] pop-out doc-viewer (north-star §6; the 0.4 dead-link check).
-- Renders the [REFERENCE] vocab axis (§9's law — an affordance cites which axis it renders):
-- the enclosing unit's `[REFERENCE]_[SUBCAT]_[ids]` tags resolve to their DEFINING sites via
-- `citable_ids.py --where` (ONE subprocess, a `defining_site/1` envelope) and the doc floats
-- beside the code. Tri-state honest at the UI seam (Class 57): FOUND → float · resolver
-- failed-to-run → named ERROR · MISSING id → named refusal — NEVER a blank float.
local M = {}

-- pure: block lines → ordered unique ids from [REFERENCE] lines. cursor_rel (1-based index
-- into `lines`, optional): if THAT line is a [REFERENCE] line, only its ids win
-- (point-at-a-thing beats whole-unit).
function M.ref_ids(lines, cursor_rel)
  local function ids_of(l)
    local val = l:match("%[REFERENCE%]_%[[%u%d_]+%]_%[(.+)%]%s*$")
    if not val then return nil end
    local out = {}
    for tok in val:gmatch("%[([^%[%]]+)%]") do out[#out + 1] = tok end
    if #out == 0 then out[1] = vim.trim(val) end
    return out
  end
  if cursor_rel then
    local at = ids_of(lines[cursor_rel] or "")
    if at then return at end
  end
  local seen, out = {}, {}
  for _, l in ipairs(lines) do
    for _, id in ipairs(ids_of(l) or {}) do
      if not seen[id] then seen[id] = true; out[#out + 1] = id end
    end
  end
  return out
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
  vim.api.nvim_create_autocmd("WinClosed", {
    pattern = tostring(win), once = true,
    callback = function()
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
  return M.ref_ids(head)
end

-- The entry point: resolve the enclosing unit's [REFERENCE] ids → float / chooser / refusal;
-- unit-first, FILE-header fallback (named when it fires).
function M.open()
  local buf = vim.api.nvim_get_current_buf()
  local row0 = vim.api.nvim_win_get_cursor(0)[1] - 1
  local blk = require("fox-symdeps.tagcontext").enclosing_block(buf, row0)
  local ids = {}
  if blk then
    local blines = vim.api.nvim_buf_get_lines(buf, blk.opener, blk.closer + 1, false)
    ids = M.ref_ids(blines, row0 - blk.opener + 1)
  end
  if #ids == 0 then
    ids = M.file_header_ids(buf)
    if #ids > 0 and blk then
      vim.notify("fox-symdeps · " .. (blk.name or "unit") ..
                 " has no [REFERENCE] — showing the FILE header's", vim.log.levels.INFO)
    end
  end
  if #ids == 0 then
    return vim.notify("fox-symdeps · no [REFERENCE] tags here (unit or FILE header)",
                      vim.log.levels.INFO)
  end
  local file = vim.api.nvim_buf_get_name(buf)
  local root = vim.fs.root(file, { ".git", "compile_commands.json" })
               or vim.fn.fnamemodify(file, ":h")
  local argv = { "python3", "tools/citable_ids.py", "--where" }
  for _, id in ipairs(ids) do argv[#argv + 1] = id end
  require("fox-symdeps.runner").run(argv, root, function(out_lines)
    if not out_lines then
      -- refusal ≠ empty facts: the resolver failed to RUN (missing python/tools — a
      -- different fact from a dead reference)
      return vim.notify("fox-symdeps · citable_ids resolver FAILED to run", vim.log.levels.ERROR)
    end
    local ok, env = pcall(vim.json.decode, table.concat(out_lines, "\n"))
    if not ok or type(env) ~= "table"
       or not (env.payload and env.payload.sites and env.payload.sites.rows) then
      return vim.notify("fox-symdeps · undecodable defining_site envelope (refusal)",
                        vim.log.levels.ERROR)
    end
    local p = M.partition(env.payload.sites.rows)
    if #p.missing > 0 then
      vim.notify("fox-symdeps · DEAD [REFERENCE] — no defining site at HEAD: "
                 .. table.concat(p.missing, " · "), vim.log.levels.WARN)
    end
    if #p.found == 0 then return end               -- refusal already named; never a blank float
    if #p.found == 1 then return open_float(p.found[1]) end
    local items = {}
    for _, s in ipairs(p.found) do
      -- compact label: last two path segments only (full-path labels wrapped the chooser —
      -- operator screenshot 2026-08-10); the float title carries file:line after opening
      local segs = {}
      for seg in s.file:gmatch("[^/]+") do segs[#segs + 1] = seg end
      local short = (#segs >= 2) and (segs[#segs - 1] .. "/" .. segs[#segs]) or s.file
      items[#items + 1] = {
        label = ("%s — %s:%d"):format(s.id, short, s.line),
        run = function() open_float(s) end,
      }
    end
    require("fox-symdeps.menu").open(items, { title = "[REFERENCE] → defining site" })
  end)
end

return M
