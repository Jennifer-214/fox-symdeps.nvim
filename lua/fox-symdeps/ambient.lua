-- ambient.lua — the "code with it, not open it" lens. When on, the struct under your cursor gets a
-- soft end-of-line tag with its size + cache-line fit (◇ 66 B · fits a cache line / ▲ spans 2 lines),
-- refreshed on CursorHold. No float, no modal — compiled-reality layout truth sitting next to the code
-- as you move through it. Opt-in (<leader>dl), off by default; clears itself when toggled off.
local M = {}
local NS = vim.api.nvim_create_namespace("fox_symdeps_ambient")
local aug
M.enabled = false
-- Where the chip renders. Default RIGHT_ALIGN (window right edge): git-blame virtual text owns
-- the eol slot on the cursor line, and two plugins competing for one space made both unreadable
-- (operator screenshot, 2026-08-09). "eol" restores the old behavior; set via setup{ambient_pos=...}.
M.pos = "right_align"

-- pure: size → { text, hl } for the inline tag. Green fits a line, wheat spills the residency band,
-- plain when it's a large aggregate (still shown, just not alarming). Unit-tested.
function M.note(size)
  if size <= 64 then return { text = ("◇ %d B · fits a cache line"):format(size), hl = "FoxSymdepsOk" } end
  local lines = math.ceil(size / 64)
  if size <= 256 then return { text = ("◇ %d B · spans %d cache lines ▲"):format(size, lines), hl = "FoxSymdepsWarn" } end
  return { text = ("◇ %d B · %d cache lines"):format(size, lines), hl = "FoxSymdepsBadge" }
end

-- pure: the unresolved-template chip (census 2026-08-18, row-17 residue: the lens went SILENT
-- on templates — status.lua's chip says `<T>`, the ambient tag said nothing). Honest, dim,
-- and it names the fix (the template_args knob resolves a canonical instantiation).
function M.template_note(symbol)
  return { text = ("◇ %s <T> · template — no concrete size (set template_args)"):format(symbol or "?"),
           hl = "FoxSymdepsDim" }
end

local function update()
  if not M.enabled then return end
  local buf = vim.api.nvim_get_current_buf()
  local ok, ctx = pcall(function() return require("fox-symdeps.context").under_cursor() end)
  if not ok or not ctx or ctx.kind == "function" then
    return vim.api.nvim_buf_clear_namespace(buf, NS, 0, -1) -- off a struct: clearing IS the paint
  end
  local line = (ctx.line or 1) - 1
  require("fox-symdeps.clangd").layout(ctx, function(data, state)
    if not (M.enabled and vim.api.nvim_buf_is_valid(buf)) then return end
    -- swap old→new in ONE paint inside the callback — the old clear-first-then-async-repaint
    -- blinked the chip on every CursorHold (census row-17 flicker residue)
    vim.api.nvim_buf_clear_namespace(buf, NS, 0, -1)
    local n
    if state == "ok" and data and data.size then
      n = M.note(data.size)
    elseif state == "ok" and data and data.is_template then
      n = M.template_note(ctx.symbol)
    end
    if n then
      pcall(vim.api.nvim_buf_set_extmark, buf, NS, line, 0, {
        virt_text = { { "  " .. n.text, n.hl } }, virt_text_pos = M.pos,
      })
    end
  end)
end

function M.toggle()
  M.enabled = not M.enabled
  if M.enabled then
    pcall(vim.api.nvim_set_hl, 0, "FoxSymdepsDim", { default = true, link = "Comment" })
    aug = vim.api.nvim_create_augroup("FoxSymdepsAmbient", { clear = true })
    vim.api.nvim_create_autocmd({ "CursorHold", "CursorHoldI" }, { group = aug, callback = update })
    update()
  else
    if aug then pcall(vim.api.nvim_del_augroup_by_id, aug); aug = nil end
    for _, b in ipairs(vim.api.nvim_list_bufs()) do
      if vim.api.nvim_buf_is_valid(b) then vim.api.nvim_buf_clear_namespace(b, NS, 0, -1) end
    end
  end
  require("fox-symdeps.ui").notify_raw("fox-symdeps · ambient layout lens " .. (M.enabled and "ON (rest on a struct)" or "off"),
    vim.log.levels.INFO)
end

return M
