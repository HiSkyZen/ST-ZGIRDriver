-- Remote definition persistence on the child device (field "def").
-- Definitions change rarely (learn/import/model) and are committed at once.
local log = require "log"
local util = require "util"

local M = {}

local F_DEF = "def"

function M.new_def(device_type, meta)
  return {
    schema = 1,
    device_type = device_type,
    meta = meta or {},
    commands = {},
    ac = (device_type == "ac") and { codebook = {} } or nil,
    active = true,
  }
end

-- Persisted field values must not be mutated in place (nested assignment
-- into a value read back from the persistent store was observed on the hub
-- to lose data).  Callers get a private copy and commit with M.save.
function M.get(device)
  local v = device:get_field(F_DEF)
  if v == nil then return nil end
  return util.deep_copy(v)
end

-- Immediate commit (persist=true).  `reason` is logged for traceability.
function M.save(device, def, reason)
  device:set_field(F_DEF, util.deep_copy(def), { persist = true })
  local n = 0
  for _ in pairs(def.commands or {}) do n = n + 1 end
  log.info(string.format("[ZGIR] def saved %s (%s) commands=%d", device.label or device.id, reason or "?", n))
end

function M.set_command(device, key, record, reason)
  local def = M.get(device)
  if not def then return nil, "no definition" end
  def.commands = def.commands or {}
  def.commands[key] = record
  M.save(device, def, reason or ("learn " .. key))
  return true
end

function M.delete_command(device, key)
  local def = M.get(device)
  if not def or not def.commands or not def.commands[key] then return false end
  def.commands[key] = nil
  M.save(device, def, "delete " .. key)
  return true
end

return M
