-- On-hub self-test harness.  There is no local Lua toolchain in this project:
-- pure-logic modules are verified inside the real Edge runtime by invoking
-- the bridge "selfTest" command and reading `edge:drivers:logcat`.
--
-- A test module (src/tests/test_<area>.lua) returns:
--   { name = "area", cases = { { "case name", function(t) ... end }, ... } }
-- Assertions: t.ok(cond, msg)  t.eq(actual, expected, msg)
--             t.near(a, b, tol, msg)  t.same(a, b, msg) (deep compare)
-- A failed assertion aborts only the current case.
local log = require "log"
local util = require "util"

local M = {}

-- Fixed registry so parallel workstreams only add files, never edit a list.
M.MODULES = {
  "tests.test_core",       -- util, signal, codec_zosung (Opus)
  "tests.test_transport",  -- tx queue / frames (Opus)
  "tests.test_import",     -- import/* + ir/fingerprint + ir/codec_broadlink
  "tests.test_packs",      -- packs/*
  "tests.test_protocols",  -- ir/protocols
  "tests.test_analysis",   -- analysis/*
  "tests.test_devices",    -- children/devices logic (Opus)
}

local FAIL = {}

local function fmt(v)
  if type(v) == "table" then
    local ok, s = pcall(util.json_canonical, v)
    if ok then return #s > 200 and s:sub(1, 200) .. "..." or s end
  end
  return tostring(v)
end

local function deep_same(a, b)
  if type(a) ~= type(b) then return false end
  if type(a) ~= "table" then return a == b end
  for k, v in pairs(a) do if not deep_same(v, b[k]) then return false end end
  for k in pairs(b) do if a[k] == nil then return false end end
  return true
end

local function make_t()
  local t = {}
  local function fail(msg) error(setmetatable({ msg = msg }, FAIL), 0) end
  function t.ok(cond, msg) if not cond then fail(msg or "expected truthy") end end
  function t.eq(a, b, msg)
    if a ~= b then fail(string.format("%s: got %s expected %s", msg or "eq", fmt(a), fmt(b))) end
  end
  function t.near(a, b, tol, msg)
    if type(a) ~= "number" or math.abs(a - b) > tol then
      fail(string.format("%s: got %s expected %s±%s", msg or "near", fmt(a), fmt(b), fmt(tol)))
    end
  end
  function t.same(a, b, msg)
    if not deep_same(a, b) then
      fail(string.format("%s: got %s expected %s", msg or "same", fmt(a), fmt(b)))
    end
  end
  return t
end

-- filter: optional substring matched against "<module>/<case>".
-- Returns { passed = n, failed = n, skipped_modules = {...}, failures = {...} }
function M.run(filter)
  local res = { passed = 0, failed = 0, skipped_modules = {}, failures = {} }
  for _, modname in ipairs(M.MODULES) do
    local ok, mod = pcall(require, modname)
    if not ok then
      if not tostring(mod):find("module '" .. modname .. "' not found", 1, true) then
        res.failed = res.failed + 1
        res.failures[#res.failures + 1] = modname .. ": load error: " .. tostring(mod)
        log.error("[ZGIR][TEST] LOAD FAIL " .. modname .. ": " .. tostring(mod))
      else
        res.skipped_modules[#res.skipped_modules + 1] = modname
      end
    elseif type(mod) == "table" and type(mod.cases) == "table" then
      for _, case in ipairs(mod.cases) do
        local label = (mod.name or modname) .. "/" .. tostring(case[1])
        if filter == nil or filter == "" or label:find(filter, 1, true) then
          local t = make_t()
          local cok, cerr = xpcall(case[2], function(e)
            if getmetatable(e) == FAIL then return e.msg end
            return tostring(e) .. "\n" .. debug.traceback("", 2)
          end, t)
          if cok then
            res.passed = res.passed + 1
          else
            res.failed = res.failed + 1
            res.failures[#res.failures + 1] = label .. ": " .. tostring(cerr)
            log.warn("[ZGIR][TEST] FAIL " .. label .. ": " .. tostring(cerr))
          end
        end
      end
    end
  end
  log.info(string.format("[ZGIR][TEST] SUMMARY passed=%d failed=%d skipped=%s",
    res.passed, res.failed, table.concat(res.skipped_modules, ",")))
  return res
end

return M
