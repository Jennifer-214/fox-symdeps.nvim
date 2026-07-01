-- trace.lua — transitive call trace via clangd callHierarchy. For a FUNCTION: who calls it,
-- recursively (depth-bounded + cycle-guarded), DFS-flattened with a depth field for indenting.
-- The "fingerprint → stamp → model-load" chain.
local M = {}

local function client(bufnr)
  return vim.lsp.get_clients({ bufnr = bufnr, name = "clangd" })[1]
end

function M.incoming(ctx, cb, max_depth)
  max_depth = max_depth or 3
  local c = client(ctx.bufnr)
  if not c then return cb(nil, "no_client") end
  c:request("textDocument/prepareCallHierarchy",
    { textDocument = { uri = vim.uri_from_bufnr(ctx.bufnr) }, position = { line = ctx.line - 1, character = ctx.col } },
    function(err, res)
      if err or not (res and res[1]) then return cb(nil, "empty") end
      local seen, pending, roots = {}, 0, {}
      local function walk(item, depth, siblings)
        if depth > max_depth then return end
        pending = pending + 1
        c:request("callHierarchy/incomingCalls", { item = item }, function(e2, calls)
          for _, call in ipairs(calls or {}) do
            local f = call.from
            local r = f.selectionRange or f.range
            local key = (f.uri or "") .. ":" .. r.start.line
            if not seen[key] then
              seen[key] = true
              local node = { name = f.name, file = vim.uri_to_fname(f.uri), line = r.start.line + 1,
                depth = depth, children = {} }
              siblings[#siblings + 1] = node
              walk(f, depth + 1, node.children)
            end
          end
          pending = pending - 1
          if pending == 0 then
            local flat = {}
            local function dfs(nodes)
              for _, n in ipairs(nodes) do flat[#flat + 1] = n; dfs(n.children) end
            end
            dfs(roots)
            cb(flat, "ok")
          end
        end, ctx.bufnr)
      end
      walk(res[1], 1, roots)
    end, ctx.bufnr)
end

return M
