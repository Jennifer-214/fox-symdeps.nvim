-- regfit.lua — the RC-F per-field register-fit / access-cost card (0.5; D-366; the struct-typed
-- complement to the shipped-asm card). Consumes `check_register_fit.py --json --struct <name>`
-- (ONE `register_fit/1` envelope) and renders each field's access cost: single aligned `mov`,
-- or more (unaligned/split load · multi-op for non-mov widths · unknown for opaque/template).
--
-- THE HONEST H14 TENSION, rendered on every card: the engine bit-packs DELIBERATELY for cache
-- footprint / L1 residency — single-mov alignment TRADES bytes for access-ops. The card SHOWS
-- both costs (per-field ops AND the struct's byte/cache-line footprint) and flags candidates;
-- it NEVER auto-unpacks or reorders (H21/H12). The operator decides per field. <leader>dR.
local M = {}

local ICON = { ["single-mov"] = "  ", ["unaligned"] = "✗ ", ["multi-op"] = "⚠ ", ["unknown"] = "? " }
local HL = { ["single-mov"] = "Comment", ["unaligned"] = "DiagnosticError",
             ["multi-op"] = "DiagnosticWarn", ["unknown"] = "DiagnosticHint" }

-- pure: envelope payload tables → { lines, hls = {row → group}, counts }. Newest concern first:
-- flagged fields render ABOVE single-mov ones (the review surface), original order within tiers.
function M.render(structs, fields)
  local lines, hls = {}, {}
  local counts = { ["single-mov"] = 0, ["unaligned"] = 0, ["multi-op"] = 0, ["unknown"] = 0 }
  for _, s in ipairs(structs) do
    local name, size, align = s[1], s[2], s[3]
    local cl = size > 0 and math.ceil(size / 64) or 0
    lines[#lines + 1] = ("%s  ·  %dB · align %d · %d cache line%s"):format(name, size, align, cl, cl == 1 and "" or "s")
    hls[#lines] = "Title"
    local mine = {}
    for _, f in ipairs(fields) do
      if f[1] == name then mine[#mine + 1] = f end
    end
    table.sort(mine, function(a, b)
      local af, bf = a[5] ~= "single-mov", b[5] ~= "single-mov"
      if af ~= bf then return af end
      return a[3] < b[3]
    end)
    for _, f in ipairs(mine) do
      local _, fname, off, size_f, verdict, note = f[1], f[2], f[3], f[4], f[5], f[6]
      counts[verdict] = (counts[verdict] or 0) + 1
      lines[#lines + 1] = ("  %s@%-5d %-6s %-11s %s%s"):format(
        ICON[verdict] or "  ", off, (size_f >= 0 and (size_f .. "B") or "?B"), verdict, fname,
        note ~= "" and ("  — " .. note) or "")
      hls[#lines] = HL[verdict] or "Comment"
    end
    lines[#lines + 1] = ""
  end
  lines[#lines + 1] = ("  %d single-mov · %d unaligned · %d multi-op · %d unknown"):format(
    counts["single-mov"], counts["unaligned"], counts["multi-op"], counts["unknown"])
  hls[#lines] = "Title"
  lines[#lines + 1] = "  ADVISORY — bit-packing is deliberate (H14): both costs shown, never auto-unpacked;"
  lines[#lines + 1] = "  you decide per field (align for single-mov OR keep the cache footprint)."
  hls[#lines - 1] = "Comment"
  hls[#lines] = "Comment"
  return { lines = lines, hls = hls, counts = counts }
end

local NS = vim.api.nvim_create_namespace("fox_symdeps_regfit")

function M.open(palette)
  local buf = vim.api.nvim_get_current_buf()
  local row0 = vim.api.nvim_win_get_cursor(0)[1] - 1
  local ok, tc = pcall(require, "fox-symdeps.tagcontext")
  local blk = ok and tc.enclosing_block(buf, row0) or nil
  if not (blk and blk.type == "STRUCT") then
    return require("fox-symdeps.ui").notify_raw(
      "regfit: cursor a converted [STRUCT] block (the per-field facts ride the tag conversion)",
      vim.log.levels.WARN)
  end
  local sname = blk.name:match("^([%w_:]+)") or blk.name   -- base-before-< (the tool's filter rule)
  local file = vim.api.nvim_buf_get_name(buf)
  local root = (file ~= "" and vim.fs.root(file, { ".git", "compile_commands.json" })) or vim.fn.getcwd()
  local rel = file:sub(#root + 2)
  require("fox-symdeps.ui").notify_raw("regfit: analyzing " .. sname .. "…", vim.log.levels.INFO)
  vim.system({ "python3", "tools/check_register_fit.py", "--json", "--struct", sname, "--paths", rel },
             { cwd = root, text = true }, function(res)
    vim.schedule(function()
      if res.code ~= 0 or not res.stdout or res.stdout == "" then
        return require("fox-symdeps.ui").notify_raw(
          "regfit REFUSED: " .. ((res.stderr or ""):match("[^\n]+") or "analyzer failed to run"),
          vim.log.levels.ERROR)
      end
      local okd, env = pcall(vim.json.decode, res.stdout)
      if not okd then
        return require("fox-symdeps.ui").notify_raw("regfit: envelope undecodable (refusal, not empty facts)",
                                                    vim.log.levels.ERROR)
      end
      local why = require("fox-symdeps.toolio_kinds").assert_consumed(env, "register_fit/1")
      if why then
        return require("fox-symdeps.ui").notify_raw("regfit: " .. why, vim.log.levels.ERROR)
      end
      local structs = (env.payload.structs or {}).rows or {}
      local fields = (env.payload.fields or {}).rows or {}
      if #structs == 0 then
        return require("fox-symdeps.ui").notify_raw(
          ("regfit: no per-field facts for %s — unconverted [STRUCT] or template-opaque (a fact, not a failure)"):format(sname),
          vim.log.levels.WARN)
      end
      local r = M.render(structs, fields)
      local b = vim.api.nvim_create_buf(false, true)
      vim.bo[b].bufhidden = "wipe"
      vim.api.nvim_buf_set_lines(b, 0, -1, false, r.lines)
      vim.bo[b].modifiable = false
      for row, grp in pairs(r.hls) do
        pcall(vim.api.nvim_buf_set_extmark, b, NS, row - 1, 0, { line_hl_group = grp })
      end
      local ui = require("fox-symdeps.ui")
      local w, h = ui.card_dims()
      h = math.min(h, #r.lines + 2)
      local win = vim.api.nvim_open_win(b, true, {
        relative = "cursor", row = 1, col = 2, width = w, height = h,
        border = "rounded", title = "  register-fit · " .. sname .. " · q closes ", title_pos = "left",
      })
      vim.wo[win].winhighlight = "Normal:FoxSymdepsNormal"
      vim.keymap.set("n", "q", function() pcall(vim.api.nvim_win_close, win, true) end,
                     { buffer = b, nowait = true, desc = "fox-symdeps: close register-fit card" })
    end)
  end)
end

return M
