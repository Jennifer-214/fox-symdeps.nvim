-- unitindex.lua — resolve an arbitrary {file, line} to its ENCLOSING tagged unit + [TAG] list
-- (north-star §6 R3: "every file:line in the HUD's trees resolves to its enclosing unit and
-- shows [TYPE Name] + the unit's [TAG] list"). The DISK-based sibling of tagcontext (which is
-- buffer-based); per-file mtime cache; the openers set DERIVES from the node model (§9).
-- Degrades to nil — the caller keeps its clangd names — when foxtag is unavailable or the
-- file is unconverted.
local M = {}

local cache = {}   -- path → { mtime, blocks = { {type, name, opener, closer, tags} } }

-- pure-ish: file lines → closable unit blocks with their ORIENT-tier [TAG] tokens (a [TAG]
-- inside [CODE] never attaches — the same tier discipline as THREAD/STRADDLE_EXEMPT).
function M._parse(lines, openers)
  local blocks, stack = {}, {}
  for i, l in ipairs(lines) do
    local et = l:match("^%s*//%s*%[END_(%u+)%]")
    if et and openers[et] then
      for s = #stack, 1, -1 do
        if stack[s].type == et then
          local b = table.remove(stack, s)
          b.closer = i
          blocks[#blocks + 1] = b
          break
        end
      end
    else
      local ty = l:match("^%s*//%s*%[(%u+)%]")
      if ty and openers[ty] then
        local nm = l:match("^%s*//%s*%[%u+%]_%[([^%]]+)%]")
        if nm then stack[#stack + 1] = { type = ty, name = nm, opener = i } end
      elseif ty == "CODE" and #stack > 0 then
        stack[#stack].code = true
      elseif ty == "TAG" and #stack > 0 and not stack[#stack].code and not stack[#stack].tags then
        local toks = {}
        for t in l:gmatch("%[([%u%d_]+)%]") do
          if t ~= "TAG" then toks[#toks + 1] = t end
        end
        stack[#stack].tags = toks
      end
    end
  end
  return blocks
end

--- The innermost tagged unit enclosing `line` of `path`, or nil (unconverted / no model).
function M.at(path, line)
  local ok, nmod = pcall(require, "fox-symdeps.nodemodel")
  local openers = ok and nmod.scope_openers and nmod.scope_openers() or nil
  if not openers then return nil end
  local st = vim.uv.fs_stat(path)
  if not st then return nil end
  local c = cache[path]
  if not c or c.mtime ~= st.mtime.sec then
    local fh = io.open(path, "r")
    if not fh then return nil end
    local lines = {}
    for l in fh:lines() do lines[#lines + 1] = l end
    fh:close()
    c = { mtime = st.mtime.sec, blocks = M._parse(lines, openers) }
    cache[path] = c
  end
  local best
  for _, b in ipairs(c.blocks) do
    if b.opener <= line and line <= b.closer then
      if not best or (b.closer - b.opener) < (best.closer - best.opener) then best = b end
    end
  end
  return best
end

return M
