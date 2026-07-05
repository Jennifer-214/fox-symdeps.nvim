-- facts.lua — the DERIVED fact record for a symbol: the plugin's compiled-reality analysis, normalized
-- into the shape the [TAG]_ scheme's [DERIVED] section wants ([DATA_SIZE] [SIMD] [DEP_CHAIN] [CONSUMERS]).
-- This is the STABLE SEAM — tag-INDEPENDENT. The (deferred) tag adapter formats these into comment tags
-- and diffs them against the comment's claims. Building it now means swapping the tag layer in later is
-- just filling `tagadapter`, no changes here. See DOCS/TAG-INTEGRATION.md.
--
--   M.derived(ctx, cb) → cb(facts), facts = {
--     symbol, kind,
--     data_size = <instruction count> | nil,   -- functions only (needs a compile)
--     simd      = <bool> | nil,                 -- functions only
--     dep_chain = { name, ... },                -- callees (fn) / upstream type deps (struct)
--     consumers = { name, ... },                -- callers (fn) / consumer scopes (struct)
--   }
local M = {}

function M.derived(ctx, cb)
  local facts = { symbol = ctx.symbol, kind = ctx.kind, dep_chain = {}, consumers = {} }
  local clangd = require("fox-symdeps.clangd")
  local tasks = {}

  if ctx.kind == "function" then
    tasks[#tasks + 1] = function(done)
      clangd.callers(ctx, function(items, state)
        if state == "ok" and items then for _, it in ipairs(items) do facts.consumers[#facts.consumers + 1] = it.name end end
        done()
      end)
    end
    tasks[#tasks + 1] = function(done)
      clangd.callees(ctx, function(items, state)
        if state == "ok" and items then for _, it in ipairs(items) do facts.dep_chain[#facts.dep_chain + 1] = it.name end end
        done()
      end)
    end
    tasks[#tasks + 1] = function(done)
      require("fox-symdeps.asmexplorer").fn_metrics(ctx, function(m)
        if m then facts.data_size = m.insns; facts.simd = m.simd end
        done()
      end)
    end
  else
    tasks[#tasks + 1] = function(done)
      clangd.consumers(ctx, function(items, state)
        if state == "ok" and items then
          require("fox-symdeps.classify").classify(items)
          local seen = {}
          for _, it in ipairs(items) do
            local s = it.scope
            if s and not seen[s] then seen[s] = true; facts.consumers[#facts.consumers + 1] = s end
          end
        end
        done()
      end)
    end
    tasks[#tasks + 1] = function(done)
      vim.schedule(function()
        local root = vim.fs.root(ctx.file, { ".git", "compile_commands.json" }) or vim.fn.fnamemodify(ctx.file, ":h")
        local ok, uses = pcall(require("fox-symdeps.compose").uses, ctx.symbol, root)
        if ok and uses then for _, u in ipairs(uses) do facts.dep_chain[#facts.dep_chain + 1] = u.name end end
        done()
      end)
    end
  end

  local pending = #tasks
  if pending == 0 then return cb(facts) end
  local fired = false
  local function done()
    pending = pending - 1
    if pending == 0 and not fired then fired = true; cb(facts) end
  end
  for _, t in ipairs(tasks) do t(done) end
end

return M
