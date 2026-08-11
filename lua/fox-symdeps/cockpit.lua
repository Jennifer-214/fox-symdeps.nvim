-- cockpit.lua — "code inside it, not open it." When on, the tracking panel auto-docks the moment you
-- enter a C++ buffer and follows your cursor, so the compiled-reality analysis is simply THERE from
-- the start — no key to remember, the co-programming loop is the default. Opt-in (setup{auto_panel} or
-- :FoxSymdepsCockpit); min-width gated so it never crowds a narrow / portrait editor.
local M = {}
local aug
M.enabled = false
local MIN_WIDTH = 120 -- below this the docked strip crowds the code; leave it to the manual <leader>dD

local function is_cpp(buf)
  local ft = vim.bo[buf] and vim.bo[buf].filetype or ""
  return ft == "cpp" or ft == "c" or ft == "cuda" or ft == "objcpp"
end

local function maybe_open()
  if not M.enabled then return end
  if not is_cpp(vim.api.nvim_get_current_buf()) then return end
  if vim.o.columns < MIN_WIDTH then return end
  -- §6 role-swap: cockpit's semantics ("follows your cursor, analysis simply THERE") are the
  -- FOLLOW CARD's role — the accumulate board is explicit-add and must never auto-dock.
  local fc = require("fox-symdeps.followcard")
  if not fc.is_open() then
    fc.toggle((require("fox-symdeps").config or {}).palette)
  end
end

function M.toggle(from_setup)
  M.enabled = not M.enabled
  if M.enabled then
    aug = vim.api.nvim_create_augroup("FoxSymdepsCockpit", { clear = true })
    vim.api.nvim_create_autocmd({ "FileType", "BufWinEnter" }, {
      group = aug, callback = vim.schedule_wrap(maybe_open),
    })
    maybe_open()
  else
    if aug then pcall(vim.api.nvim_del_augroup_by_id, aug); aug = nil end
    if require("fox-symdeps.followcard").is_open() then require("fox-symdeps.followcard").close() end
  end
  if not from_setup then
    require("fox-symdeps.ui").notify_raw("fox-symdeps · cockpit " ..
      (M.enabled and "ON (follow card auto-docks on C++ buffers)" or "off"), vim.log.levels.INFO)
  end
end

return M
