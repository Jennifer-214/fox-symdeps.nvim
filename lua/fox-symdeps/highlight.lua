-- highlight.lua — W13 "use-lens": project a tracked symbol's uses onto the source as eol
-- virtual-text tags, role-labelled. Color is reserved for danger: byte-sites (sizeof/memcmp/
-- fwrite) glow RED (FoxSymdepsAlarm); every other role stays calm (the label carries the role).
-- ]u / [u hop between uses across files. Non-destructive (extmarks only) + fully reversible.
local M = {}
local NS = vim.api.nvim_create_namespace("fox_symdeps_lens")
local AUG = vim.api.nvim_create_augroup("FoxSymdepsLens", { clear = true })

local state = { active = false, refs = {}, by_file = {}, idx = 0 }

local ROLE_TAG = {
  input = "in", returned = "out", embedded = "field",
  instantiated = "local", byte = "sizeof", called = "call", other = "use",
}

local function tag_buffer(bufnr)
  if not vim.api.nvim_buf_is_valid(bufnr) then return end
  -- clear first so re-entering the buffer (BufEnter fires repeatedly) doesn't stack duplicate tags
  pcall(vim.api.nvim_buf_clear_namespace, bufnr, NS, 0, -1)
  local abs = vim.fn.fnamemodify(vim.api.nvim_buf_get_name(bufnr), ":p")
  local refs = state.by_file[abs]
  if not refs then return end
  local nlines = vim.api.nvim_buf_line_count(bufnr)
  for _, r in ipairs(refs) do
    if r.line >= 1 and r.line <= nlines then
      local byte = r.role == "byte"
      pcall(vim.api.nvim_buf_set_extmark, bufnr, NS, r.line - 1, 0, {
        virt_text = { { (byte and "▲ " or "◂ ") .. (ROLE_TAG[r.role] or "use"),
          byte and "FoxSymdepsAlarm" or "FoxSymdepsLensTag" } },
        virt_text_pos = "eol",
        hl_mode = "combine",
      })
    end
  end
end

local function tag_all_loaded()
  for _, b in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(b) then tag_buffer(b) end
  end
end

function M.clear()
  for _, b in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_valid(b) then pcall(vim.api.nvim_buf_clear_namespace, b, NS, 0, -1) end
  end
  pcall(vim.api.nvim_clear_autocmds, { group = AUG })
  state.active, state.refs, state.by_file, state.idx = false, {}, {}, 0
end

-- refs: { {file, line(1-based), col(0-based), role}, ... }. Returns the count tagged.
function M.show(refs)
  M.clear()
  state.active = true
  for _, r in ipairs(refs or {}) do
    if r.file and r.line then
      r.file = vim.fn.fnamemodify(r.file, ":p")
      state.refs[#state.refs + 1] = r
      state.by_file[r.file] = state.by_file[r.file] or {}
      table.insert(state.by_file[r.file], r)
    end
  end
  table.sort(state.refs, function(a, b)
    if a.file == b.file then return a.line < b.line end
    return a.file < b.file
  end)
  tag_all_loaded()
  vim.api.nvim_create_autocmd({ "BufReadPost", "BufEnter" }, {
    group = AUG,
    callback = function(ev) if state.active then tag_buffer(ev.buf) end end,
  })
  return #state.refs
end

function M.active() return state.active end

local function jump(r)
  vim.cmd("normal! m`") -- jumplist mark so <C-o> returns
  vim.cmd.edit(vim.fn.fnameescape(r.file))
  pcall(vim.api.nvim_win_set_cursor, 0, { r.line, r.col or 0 })
end

function M.next()
  local n = #state.refs
  if not state.active or n == 0 then return end
  state.idx = state.idx % n + 1
  jump(state.refs[state.idx])
end

function M.prev()
  local n = #state.refs
  if not state.active or n == 0 then return end
  state.idx = (state.idx - 2) % n + 1
  jump(state.refs[state.idx])
end

M._ns = NS                 -- exposed for tests
M._state = state           -- exposed for tests
M._tag_buffer = tag_buffer -- exposed for tests (idempotency)
return M
