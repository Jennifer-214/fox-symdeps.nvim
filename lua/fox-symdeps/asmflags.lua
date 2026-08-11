-- asmflags.lua — W15 flag-set store. Ships built-in sets so 'a' works with zero setup; you can
-- switch the compared pair or add a set via a picker, and it auto-saves to a state file (no config
-- editing). Persists across restarts under stdpath('data').
local M = {}

local DEFAULTS = {
  { name = "O2", flags = { "-O2" } },
  { name = "O3-native", flags = { "-O3", "-march=native" } },
  { name = "O3-avx2", flags = { "-O3", "-mavx2" } },
  { name = "ffast", flags = { "-O3", "-ffast-math" } },
}

local function path() return vim.fn.stdpath("data") .. "/fox-symdeps/asmflags.json" end

function M.load()
  local p, st = path(), nil
  if vim.fn.filereadable(p) == 1 then
    local ok, data = pcall(function() return vim.json.decode(table.concat(vim.fn.readfile(p), "\n")) end)
    if ok and type(data) == "table" and type(data.sets) == "table" and #data.sets > 0 then st = data end
  end
  if not st then st = { sets = vim.deepcopy(DEFAULTS), a = "O2", b = "O3-native" } end
  return st
end

function M.save(st)
  local p = path()
  pcall(vim.fn.mkdir, vim.fn.fnamemodify(p, ":h"), "p")
  local tmp = p .. ".tmp"
  if pcall(vim.fn.writefile, { vim.json.encode(st) }, tmp) then pcall(os.rename, tmp, p) end
end

-- pure: resolve the {a, b} set objects from a state table (falls back to first two sets).
function M._pair_from(st)
  local function find(name) for _, s in ipairs(st.sets) do if s.name == name then return s end end end
  return (find(st.a) or st.sets[1]), (find(st.b) or st.sets[2] or st.sets[1])
end

function M.pair() return M._pair_from(M.load()) end

-- picker: choose baseline (A) then comparison (B); persist. cb() after.
function M.choose(cb)
  local st = M.load()
  local names = {}
  for _, s in ipairs(st.sets) do names[#names + 1] = s.name end
  names[#names + 1] = "+ add a flag-set…"
  vim.ui.select(names, { prompt = "asm baseline (A):" }, function(a)
    if not a then return end
    if a:match("^%+") then return M.add(function() M.choose(cb) end) end
    vim.ui.select(names, { prompt = "asm compare (B):" }, function(b)
      if not b or b:match("^%+") then return end
      st.a, st.b = a, b
      M.save(st)
      require("fox-symdeps.ui").notify_raw(("fox-symdeps · asm-diff pair: %s vs %s (saved)"):format(a, b), vim.log.levels.INFO)
      if cb then cb() end
    end)
  end)
end

-- add a named flag-set via prompts; persist.
function M.add(cb)
  vim.ui.input({ prompt = "flag-set name: " }, function(name)
    if not name or name == "" then return end
    vim.ui.input({ prompt = "flags (space-separated): " }, function(flags)
      if not flags then return end
      local st = M.load()
      local list = {}
      for f in flags:gmatch("%S+") do list[#list + 1] = f end
      table.insert(st.sets, { name = name, flags = list })
      M.save(st)
      require("fox-symdeps.ui").notify_raw("fox-symdeps · added flag-set " .. name .. " (saved)", vim.log.levels.INFO)
      if cb then cb() end
    end)
  end)
end

M._DEFAULTS = DEFAULTS
return M
