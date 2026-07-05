-- fox-symdeps-trader/provider.lua — PRIVATE trader provider. Registers a fox-symdeps provider
-- that, for a TYPE, shells the engine's gen_code_map to surface the byte-layout CASCADE: direct
-- + transitive embedders + sizeof/memcmp/fwrite enforcement sites ("what realigns if I shrink
-- it"). Auto-activates only where tools/gen_code_map.sh exists (the trader). NOT part of the
-- publishable plugin — load it project-local (see the loading note at the bottom).
local provider = require("fox-symdeps.provider")
local runner = require("fox-symdeps.runner")

-- walk up from `file` to a project root containing tools/gen_code_map.sh
local function find_gcm(file)
  local dir = vim.fn.fnamemodify(file or "", ":h")
  while dir and dir ~= "/" and dir ~= "" do
    local p = dir .. "/tools/gen_code_map.sh"
    if vim.fn.filereadable(p) == 1 then return p, dir end
    local parent = vim.fn.fnamemodify(dir, ":h")
    if parent == dir then break end
    dir = parent
  end
end

local function group_by_file(items)
  local byfile, order = {}, {}
  for _, it in ipairs(items) do
    if not byfile[it.file] then byfile[it.file] = { file = it.file, entries = {} }; order[#order + 1] = it.file end
    table.insert(byfile[it.file].entries, it)
  end
  local files = {}
  for _, f in ipairs(order) do
    local fe = byfile[f]; fe.count = #fe.entries; fe.collapsed = fe.count > 5; files[#files + 1] = fe
  end
  return files
end

local function role_node(label, items)
  if #items == 0 then return nil end
  local files = group_by_file(items)
  local cnt = 0
  for _, f in ipairs(files) do cnt = cnt + f.count end
  return { label = label, role = label, count = cnt, collapsed = true, files = files }
end

-- gen_code_map emits embedder NAMES, not def locations, so every embedder row would jump to
-- :1 (W-FIX1). One rg over the project's C++ tree builds a name -> {file,line} index; engine
-- struct names are unique (enforced), so a single global index resolves BOTH direct and
-- transitive embedders. Prefer a real definition over a forward-declaration (`struct Foo;`).
local function build_def_index(root)
  local index = {}
  local ok, out = pcall(vim.fn.systemlist, {
    "rg", "--no-heading", "--line-number", "--color", "never",
    "-g", "*.hpp", "-g", "*.h", "-g", "*.hh", "-g", "*.cpp", "-g", "*.cc",
    "-e", "(struct|class)[[:space:]]+[A-Za-z_]", root,
  })
  if not ok or type(out) ~= "table" then return index end
  for _, l in ipairs(out) do
    local file, line, text = l:match("^([^:]+):(%d+):(.*)$")
    if file and line then
      local code = text:gsub("//.*$", "")
      -- strip attributes between the keyword and the name (`struct alignas(64) Name`, the
      -- cache-line-aligned hot structs — else the attribute token is parsed as the name)
      code = code:gsub("alignas%b()", ""):gsub("__attribute__%s*%b()", ""):gsub("%[%[.-%]%]", "")
      local name = code:match("struct%s+([%w_]+)") or code:match("class%s+([%w_]+)")
      if name then
        local is_fwd = code:match(";%s*$") ~= nil and not code:find("{", 1, true)
        local cur = index[name]
        if not cur or (cur.fwd and not is_fwd) then
          index[name] = { file = file, line = tonumber(line), fwd = is_fwd }
        end
      end
    end
  end
  return index
end

local function build_tree(structs, transitive, sites, root)
  local defidx = build_def_index(root)
  local tree = {}
  local embed = {}
  for _, s in ipairs(structs) do
    local d = defidx[s.name]
    embed[#embed + 1] = { file = d and d.file or (root .. "/" .. s.file), line = d and d.line or 1, scope = s.name }
  end
  tree[#tree + 1] = role_node("Direct embedders", embed)
  local trans = {}
  for _, n in ipairs(transitive) do
    local d = defidx[n]
    trans[#trans + 1] = { file = d and d.file or "(transitive)", line = d and d.line or 1, scope = n }
  end
  tree[#tree + 1] = role_node("Transitive embedders", trans)
  local sx = {}
  for _, s in ipairs(sites) do sx[#sx + 1] = { file = root .. "/" .. s.file, line = s.line, scope = (s.text or ""):sub(1, 48) } end
  tree[#tree + 1] = role_node("Enforcement sites (sizeof/fwrite/memcmp)", sx)
  -- drop nils (empty roles)
  local out = {}
  for _, r in ipairs(tree) do if r then out[#out + 1] = r end end
  return out
end

local CASCADE_LABEL = "⚠ Byte-layout blast radius"

local function enforcement_role(tree)
  for _, role in ipairs(tree) do
    if role.role and role.role:find("Enforcement", 1, true) then return role end
  end
end

-- W18: compiler-truth break-check. Compile the enforcement-site files and mark the static_asserts
-- that now FAIL (RED). On-demand ('b') — one clang pass per site file, so it stays calm.
local function run_breakcheck(hud, tree)
  local role = enforcement_role(tree)
  if not role then return end
  local files, entries = {}, {}
  for _, fe in ipairs(role.files) do
    for _, e in ipairs(fe.entries) do
      files[#files + 1] = e.file
      entries[#entries + 1] = e
    end
  end
  if #files == 0 then return end
  hud:set_section("cascade", CASCADE_LABEL .. " · checking…", tree, "ok")
  require("fox-symdeps.breakcheck").check(files, files[1], function(failset)
    local nbroken = 0
    for _, e in ipairs(entries) do
      e.broken = failset[vim.fn.fnamemodify(e.file, ":p") .. ":" .. e.line] ~= nil
      if e.broken then nbroken = nbroken + 1 end
    end
    local suffix = nbroken > 0 and (" · " .. nbroken .. " BROKEN") or " · none broken"
    hud:set_section("cascade", CASCADE_LABEL .. suffix, tree, "ok")
  end)
end

provider.register(function(ctx, hud)
  if not ctx or ctx.kind == "function" then return end
  local gcm, root = find_gcm(ctx.file)
  if not gcm then return end -- not the trader → stay silent
  hud:set_section("cascade", CASCADE_LABEL, {}, "loading")
  local r = {}
  local function maybe_emit()
    if r.structs and r.transitive and r.sites then
      local tree = build_tree(r.structs, r.transitive, r.sites, root)
      hud:set_section("cascade", CASCADE_LABEL, tree, "ok")
      if hud.map_action then
        hud:map_action("b", function() run_breakcheck(hud, tree) end)
      end
    end
  end
  runner.run({ gcm, "--structs", ctx.symbol }, root, function(l) r.structs = l and runner.parse_structs(l) or {}; maybe_emit() end)
  runner.run({ gcm, "--composition", ctx.symbol }, root, function(l) r.transitive = l and runner.parse_transitive(l) or {}; maybe_emit() end)
  runner.run({ gcm, "--byte-context", ctx.symbol }, root, function(l) r.sites = l and runner.parse_sites(l) or {}; maybe_emit() end)
end)

-- LOADING (operator decision pending): auto-load this when working in the trader, e.g. an
-- autocmd in your config —  if cwd matches FoxML_Trader_v2 then dofile(this) —  or nvim exrc.
-- Kept local + un-pushed for now (private/opt-in).

-- Exposed for tests only (dofile ignores this return; the auto-loader's side effect above still runs).
return { _build_def_index = build_def_index, _build_tree = build_tree }
