-- provider.lua — registry of external providers that contribute EXTRA HUD sections (e.g. the
-- private trader provider's byte-layout cascade). Keeps tool-specific logic OUT of the
-- publishable plugin: a provider is just a function(ctx, hud) that, when it has something to
-- show, calls hud:set_section(key, label, tree, state). The trader registers one project-local.
local M = {}
local providers = {}

function M.register(fn)
  providers[#providers + 1] = fn
end

function M.run_all(ctx, hud)
  for _, fn in ipairs(providers) do
    pcall(fn, ctx, hud)
  end
end

function M.clear() providers = {} end -- for tests / re-registration
function M.count() return #providers end

return M
