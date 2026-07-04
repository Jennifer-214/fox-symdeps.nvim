-- Contract / canary test: guards the gen_code_map ↔ runner parser INTERFACE. Runs the REAL tool
-- and asserts runner.parse_structs / parse_transitive still consume its output. If gen_code_map's
-- output format ever drifts, THIS fails loudly instead of the cascade lens silently blanking.
-- Skips cleanly when the engine isn't present.
--
-- Run: nvim --headless --clean -u NONE -l tests/test_gen_code_map_contract.lua

local here = debug.getinfo(1, "S").source:sub(2):match("(.*/)") or "./"
local plugin = vim.fn.fnamemodify(here .. "..", ":p")
vim.opt.runtimepath:append(plugin)
local runner = require("fox-symdeps.runner")

local ENGINE = vim.fn.expand("~/code/FoxML_Trader_v2")
local GCM = ENGINE .. "/tools/gen_code_map.sh"
local ANCHOR = "FPN_Binary" -- core fixed-point type: always has embedders (stable structural fact)

if vim.fn.filereadable(GCM) ~= 1 then
  print("SKIP: gen_code_map not present (" .. GCM .. ") — interface contract unverifiable here")
  vim.cmd("cq 0")
end

local fails = 0
local function ok(c, m) if c then print("  ok  " .. m) else fails = fails + 1; print("  FAIL " .. m) end end

local function run(flag, sym)
  local res = vim.system({ "bash", GCM, flag, sym }, { cwd = ENGINE, text = true }):wait()
  local lines = {}
  for l in (res.stdout or ""):gmatch("[^\n]+") do lines[#lines + 1] = l end
  return lines
end

print("== gen_code_map --structs contract (anchor: " .. ANCHOR .. ") ==")
local structs = runner.parse_structs(run("--structs", ANCHOR))
ok(#structs >= 1, ("--structs parses >=1 embedder (got %d) — `<file> struct <name> { <fields> }` intact"):format(#structs))
if #structs >= 1 then
  local s = structs[1]
  ok(s.file and s.file:match("%.hpp$") ~= nil, "embedder row has a .hpp file: " .. tostring(s.file))
  ok(s.name and s.name ~= "", "embedder row has a struct name: " .. tostring(s.name))
end

print("== gen_code_map --composition contract ==")
local trans = runner.parse_transitive(run("--composition", ANCHOR))
ok(type(trans) == "table", "--composition output parses without error (transitive count = " .. #trans .. ")")

print(fails == 0 and "\nALL PASS" or ("\n" .. fails .. " FAILURE(S)"))
vim.cmd(fails == 0 and "cq 0" or "cq 1")
