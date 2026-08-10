-- recordlayout.lua — struct census straight from the compiler. Compiles the current TU (a copy of
-- the buffer, source tree untouched) with `-Xclang -fdump-record-layouts` and parses every record's
-- sizeof / align / top-level field offsets out of the dump. Reliable sizes with no clangd round-trip
-- per type — feeds the dashboard's "biggest structs" (cache-residency) tile. Generic: any C++ repo
-- with a compile_commands.json. parse() is pure (unit-tested); census() is the impure compile driver.
local M = {}
local sizeprobe = require("fox-symdeps.sizeprobe")

-- primitive byte widths (x86-64 LP64) for the conservative field-size resolver.
local PRIM = {
  ["bool"] = 1, ["_Bool"] = 1, ["char"] = 1, ["signed char"] = 1, ["unsigned char"] = 1,
  ["int8_t"] = 1, ["uint8_t"] = 1,
  ["short"] = 2, ["unsigned short"] = 2, ["int16_t"] = 2, ["uint16_t"] = 2, ["char16_t"] = 2,
  ["int"] = 4, ["unsigned"] = 4, ["unsigned int"] = 4, ["int32_t"] = 4, ["uint32_t"] = 4,
  ["float"] = 4, ["char32_t"] = 4, ["wchar_t"] = 4,
  ["long"] = 8, ["unsigned long"] = 8, ["long long"] = 8, ["unsigned long long"] = 8,
  ["int64_t"] = 8, ["uint64_t"] = 8, ["double"] = 8, ["size_t"] = 8, ["ptrdiff_t"] = 8,
  ["intptr_t"] = 8, ["uintptr_t"] = 8,
  ["__int128"] = 16, ["unsigned __int128"] = 16, ["long double"] = 16,
}

-- canonicalize a type/record name for the size map: drop struct/class/union + all whitespace.
local function canon(t) return (t:gsub("struct ", ""):gsub("class ", ""):gsub("union ", ""):gsub("%s", "")) end
-- strip leading namespace qualifiers ("tt::detail::Foo<...>" → "Foo<...>"); leaves template args intact.
local function stripns(c) return (c:gsub("^([%w_]+::)+", "")) end

-- library/compiler noise we never want in a project census: std::, __impl, _Reserved, anon/lambda.
local function is_noise(name)
  return name:match("^std::") ~= nil
    or name:match("^__") ~= nil
    or name:match("^_[%u]") ~= nil
    or name:find("anonymous", 1, true) ~= nil
    or name:find("lambda", 1, true) ~= nil
end
M._is_noise = is_noise

-- pure: parse `-fdump-record-layouts` output → { { name, size, align, offsets = {N,...} }, ... }.
-- The dump repeats a block per record:
--     *** Dumping AST Record Layout
--              0 | struct tt::ExecutionCore
--              0 |   int seqlock
--              8 |   double pnl
--                | [sizeof=64, dsize=64, align=64,
--                |  nvsize=64, nvalign=64]
-- We take the first `N | struct/class/union NAME` as the record name, the offset column of the
-- remaining `N | …` lines as field offsets, and `[sizeof=…]` / ` align=…` as the size/align. Deduped
-- by name (a later, more-complete dump wins), project records only (is_noise filtered).
function M.parse(dump)
  local records, order, seen = {}, {}, {}
  local cur
  local function flush()
    if cur and cur.name and cur.size and not is_noise(cur.name) then
      if not seen[cur.name] then seen[cur.name] = true; order[#order + 1] = cur.name end
      records[cur.name] = cur
    end
    cur = nil
  end
  for line in (dump or ""):gmatch("[^\n]+") do
    if line:find("Dumping AST Record Layout", 1, true) then
      flush(); cur = { offsets = {}, fields = {} }
    elseif cur then
      local named = false
      if not cur.name then
        local kind, name = line:match("^%s*%d+ | (%a+) (.+)$")
        if kind == "struct" or kind == "class" or kind == "union" then
          cur.name = vim.trim(name); named = true
        end
      end
      local sz = line:match("%[sizeof=(%d+)")
      if sz then cur.size = tonumber(sz) end
      local al = line:match(" align=(%d+)") -- leading space so it never matches nv align/nvalign
      if al and not cur.align then cur.align = tonumber(al) end
      if not named and cur.name then
        local off = line:match("^%s*(%d+) |")
        if off then cur.offsets[#cur.offsets + 1] = tonumber(off) end
        -- TOP-LEVEL field: `offset | ` + exactly 3 spaces + `TYPE NAME`. Deeper-nested members
        -- (5+ spaces) and the `[sizeof=…]` summary don't match. name = last token, type = the rest.
        local o2, decl = line:match("^%s*(%d+) |   (%S.*)$")
        if o2 then
          local fname = decl:match("(%S+)%s*$")
          local ftype = decl:gsub("%s*%S+%s*$", "")
          if fname and ftype ~= "" then
            cur.fields[#cur.fields + 1] = { name = fname, type = ftype, off = tonumber(o2) }
          end
        end
      end
    end
  end
  flush()
  local out = {}
  for _, name in ipairs(order) do out[#out + 1] = records[name] end
  return out
end

-- census(bufnr, cb): compile the buffer's TU with the record-layout dump on, parse it.
-- ABI-constant system types (x86-64 SysV / glibc / libstdc++) the dump can't resolve by
-- record-name (typedefs of anonymous unions / opaque handles). Values PINNED by the compiled
-- probe tooth in the recordlayout tests (D-413 leaf-2; A-class C(c) confirmed by probe) —
-- extend the table and the tooth TOGETHER. The v1 endgame replaces this with compiler-answered
-- member-sizeof probes (O2b), deleting the table.
local ABI = {
  ["pthread_mutex_t"] = 40, ["pthread_cond_t"] = 48, ["pthread_t"] = 8,
  ["std::thread"] = 8,  -- one native_handle (pthread_t) on libstdc++
  ["time_t"] = 8, ["sig_atomic_t"] = 4, ["__sig_atomic_t"] = 4,
}

-- pure: byte size of a field TYPE, or nil if it can't be resolved exactly (opaque typedef, enum,
-- unknown). `by_name` maps a canonicalized record name → sizeof (built from the census itself, so
-- nested engine structs resolve). Arrays multiply the element size; pointers are 8; cv-qualifiers
-- strip before lookup; `std::atomic<T>` sizes as T (lock-free ≤16 B — probe-tooth-pinned). Never
-- GUESSES — an unresolvable field goes to the caller's UNVERIFIED path (tri-state per D-413),
-- never to a made-up value.
function M.field_size(typ, by_name)
  if not typ then return nil end
  typ = typ:gsub("^%s+", ""):gsub("%s+$", "")
  typ = typ:gsub("^const%s+", ""):gsub("^volatile%s+", ""):gsub("^const%s+", "")
  local at = typ:match("^std::atomic<(.+)>$") or typ:match("^atomic<(.+)>$")
  if at then return M.field_size(at, by_name) end
  local base, dims = typ:match("^(.-)(%[.+%])$")
  if base then
    local n = 1
    for d in dims:gmatch("%[(%d+)%]") do n = n * tonumber(d) end
    local es = M.field_size(base:gsub("%s+$", ""), by_name)
    return es and es * n or nil
  end
  if typ:find("%*%s*$") then return 8 end -- pointer / reference-to-pointer
  if PRIM[typ] then return PRIM[typ] end
  if ABI[typ] then return ABI[typ] end
  local c = canon(typ)
  return by_name and (by_name[c] or by_name[stripns(c)]) or nil
end

-- pure: the cache-line straddlers across a census. A "straddler" here is a field ≤ 64 B (one that
-- COULD be cache-resident) whose byte span crosses a 64 B boundary because of where it sits — the
-- placement/false-sharing risk. Fields > 64 B span lines inherently (a big buffer), so they're not
-- flagged. TRI-STATE honest (D-413 leaf-2 — the NotifyState class): RESOLVED hits ALWAYS report,
-- even inside a partially-resolved record (the old record-wide veto silently hid real straddlers);
-- an UNRESOLVED field is bounded by the next field's offset (record size at the tail) — if even
-- that UPPER BOUND stays inside one 64 B line the field is PROVEN non-straddling (padding only
-- inflates the bound), so only bound-crossing unresolved fields stay UNVERIFIED. No guessing
-- anywhere: bounds are proofs, unverified is NAMED, and a record is never silently vetoed.
-- Returns { report = { { name, size, fields={{name,off,size}}, unverified={names} }, ... },
--           partial = N }  (partial = records with ≥1 genuinely-UNVERIFIED field).
function M.straddlers(records)
  local by = {}
  for _, r in ipairs(records or {}) do
    if r.size then by[canon(r.name)] = r.size; by[stripns(canon(r.name))] = r.size end
  end
  local report, partial = {}, 0
  for _, r in ipairs(records or {}) do
    if r.fields and #r.fields > 0 and not is_noise(r.name) then
      local hits, unverified = {}, {}
      for i, f in ipairs(r.fields) do
        local s = M.field_size(f.type, by)
        if s then
          if s > 0 and s <= 64 and math.floor(f.off / 64) ~= math.floor((f.off + s - 1) / 64) then
            hits[#hits + 1] = { name = f.name, off = f.off, size = s }
          end
        else
          local nxt = r.fields[i + 1]
          local bound = nxt and (nxt.off - f.off) or (r.size and (r.size - f.off) or nil)
          if not bound or bound <= 0
             or math.floor(f.off / 64) ~= math.floor((f.off + bound - 1) / 64) then
            unverified[#unverified + 1] = f.name
          end
        end
      end
      if #hits > 0 or #unverified > 0 then
        report[#report + 1] = { name = r.name, size = r.size, fields = hits, unverified = unverified }
      end
      if #unverified > 0 then partial = partial + 1 end
    end
  end
  table.sort(report, function(a, b) return #a.fields > #b.fields end)
  return { report = report, partial = partial }
end

-- cb({ records = {...} }) on success, cb({ error = "…" }) with the first compiler error otherwise.
function M.census(bufnr, cb)
  local file = vim.api.nvim_buf_get_name(bufnr)
  if file == "" then return cb({ error = "buffer has no file on disk (save it first)" }) end
  local flags, dir = sizeprobe._flags_for(file)
  if not flags then return cb({ error = "no compile_commands.json found for this file" }) end
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local tmp = vim.fn.tempname() .. ".cpp"
  if not pcall(vim.fn.writefile, lines, tmp) then return cb({ error = "could not write temp source" }) end

  local argv = { "clang++", "-fsyntax-only", "-ferror-limit=0",
    "-Xclang", "-fdump-record-layouts", "-I" .. vim.fn.fnamemodify(file, ":h") }
  vim.list_extend(argv, flags)
  argv[#argv + 1] = tmp

  local ok = pcall(vim.system, argv, { cwd = dir or vim.fn.fnamemodify(file, ":h"), text = true }, function(res)
    pcall(os.remove, tmp)
    local dump = (res.stdout or "") .. "\n" .. (res.stderr or "")
    local recs = M.parse(dump)
    vim.schedule(function()
      if #recs == 0 then
        local err
        for l in (res.stderr or ""):gmatch("[^\n]+") do
          if l:find("error:", 1, true) then err = vim.trim(l); break end
        end
        cb({ error = err or "no records dumped (does this TU compile?)" })
      else
        cb({ records = recs })
      end
    end)
  end)
  if not ok then pcall(os.remove, tmp); cb({ error = "could not run clang++ (is it installed?)" }) end
end

return M
