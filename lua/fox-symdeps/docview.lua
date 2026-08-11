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

-- Float the REAL buffer of the defining doc beside the code (right edge), cursor on the
-- defining line — syntax, search, and jumps all work; q closes the float (buffer-local map
-- removed when the float closes).
local function open_float(site)
  local buf = vim.fn.bufadd(site.file)
  vim.fn.bufload(buf)
  local W, H = vim.o.columns, vim.o.lines
  local w = math.min(110, math.max(60, math.floor(W * 0.55)))
  local h = math.floor(H * 0.72)
  local win = vim.api.nvim_open_win(buf, true, {
    relative = "editor", row = math.max(1, math.floor((H - h) / 2) - 1), col = W - w - 2,
    width = w, height = h, border = "rounded",
    title = ("  %s — %s:%d "):format(site.id, vim.fn.fnamemodify(site.file, ":t"), site.line),
    title_pos = "left",
  })
  pcall(vim.api.nvim_win_set_cursor, win, { math.max(site.line, 1), 0 })
  vim.wo[win].cursorline = true
  vim.keymap.set("n", "q", function() pcall(vim.api.nvim_win_close, win, true) end,
                 { buffer = buf, nowait = true, desc = "fox-symdeps: close doc float" })
  vim.api.nvim_create_autocmd("WinClosed", {
    pattern = tostring(win), once = true,
    callback = function() pcall(vim.keymap.del, "n", "q", { buffer = buf }) end,
  })
end

-- The entry point: resolve the enclosing unit's [REFERENCE] ids → float / chooser / refusal.
function M.open()
  local buf = vim.api.nvim_get_current_buf()
  local row0 = vim.api.nvim_win_get_cursor(0)[1] - 1
  local blk = require("fox-symdeps.tagcontext").enclosing_block(buf, row0)
  if not blk then
    return vim.notify("fox-symdeps · not inside a tagged unit (docview reads [REFERENCE])",
                      vim.log.levels.INFO)
  end
  local lines = vim.api.nvim_buf_get_lines(buf, blk.opener, blk.closer + 1, false)
  local ids = M.ref_ids(lines, row0 - blk.opener + 1)
  if #ids == 0 then
    return vim.notify("fox-symdeps · no [REFERENCE] tags in " .. (blk.name or "this unit"),
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
      items[#items + 1] = {
        label = ("%s — %s:%d"):format(s.id, vim.fn.fnamemodify(s.file, ":~:."), s.line),
        run = function() open_float(s) end,
      }
    end
    require("fox-symdeps.menu").open(items, { title = "[REFERENCE] → defining site" })
  end)
end

return M
