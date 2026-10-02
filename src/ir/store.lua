-- Remote definition persistence on the child device (field "def").
-- Definitions change rarely (learn/import/model) and are committed at once.
local log = require "log"

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

function M.get(device)
  return device:get_field(F_DEF)
end

-- Immediate commit (persist=true).  `reason` is logged for traceability.
function M.save(device, def, reason)
  device:set_field(F_DEF, def, { persist = true })
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
