-- lens.lua — the one small convenience for defining a HUD lens.
-- A lens is a spec: { name, applies(ctx)->bool, render(ctx, hud), actions = { key = fn(ctx,hud) } }
--   applies  cheap self-gate — return false and the lens stays silent (off-topic buffer, wrong kind)
--   render   draw sections via hud:set_section(...). pcall'd, so one lens erroring never kills the HUD.
--   actions  bind HUD-buffer keys. render() may ALSO bind keys itself (hud:map_action) when a key
--            depends on async state — see lenses/byte_layout_cascade.lua.
-- Registering a lens = require this + call define{}. That's the whole extension surface.
local provider = require("fox-symdeps.provider")
local M = {}

function M.define(spec)
  provider.register(function(ctx, hud)
    if spec.applies and not spec.applies(ctx) then return end
    local ok, err = pcall(spec.render, ctx, hud)
    if not ok then
      hud:set_section(spec.name, (spec.name or "lens") .. " · error", {}, "ok")
      vim.notify(("fox-symdeps lens %q: %s"):format(spec.name or "?", err), vim.log.levels.WARN)
      return
    end
    for key, fn in pairs(spec.actions or {}) do
      hud:map_action(key, function() fn(ctx, hud) end, spec.hints and spec.hints[key])
    end
  end)
end

return M
