-- Per-child logical appliance state.
--
-- IR is one-way: the state is what SmartThings last commanded ("assumed"),
-- not something read back from the appliance.
--   {
--     desired = {...},          -- what the user/automation asked for
--     last_commanded = {...},   -- what was actually transmitted successfully
--     source = "default"|"commanded"|"user_override"|"import",
--     confidence = "high"|"low",
--     updated = os.time(),
--   }
-- Writes go to RAM immediately and are checkpointed to persistent storage
-- after CHECKPOINT_SEC of quiet, to avoid a flash write per button press.
local log = require "log"
local util = require "util"

local M = {}

M.CHECKPOINT_SEC = 30
M.STALE_SEC = 1800 -- commanded state older than this is low-confidence

local F_STATE = "state"        -- persisted snapshot (never mutated in place)
local F_RAM = "state_ram"      -- working copy

function M.get(device, defaults)
  local st = device:get_field(F_RAM)
  if st == nil then
    local saved = device:get_field(F_STATE)
    if saved ~= nil then
      st = util.deep_copy(saved)
      device:set_field(F_RAM, st)
    end
  end
  if st == nil then
    st = {
      desired = util.deep_copy(defaults or {}),
      last_commanded = {},
      source = "default",
      confidence = "low",
      updated = 0,
    }
    device:set_field(F_RAM, st)
  end
  if defaults then
    for k, v in pairs(defaults) do
      if st.desired[k] == nil then st.desired[k] = util.deep_copy(v) end
    end
  end
  if st.updated > 0 and os.time() - st.updated > M.STALE_SEC then st.confidence = "low" end
  return st
end

local function schedule_checkpoint(device, st)
  st.dirty_gen = (st.dirty_gen or 0) + 1
  local gen = st.dirty_gen
  device.thread:call_with_delay(M.CHECKPOINT_SEC, function()
    if st.dirty_gen == gen then M.flush(device) end
  end)
end

function M.flush(device)
  local st = device:get_field(F_RAM)
  if st == nil then return end
  st.dirty_gen = nil
  local copy = util.deep_copy(st)
  device:set_field(F_STATE, copy, { persist = true })
  log.debug("[ZGIR] state checkpoint " .. (device.label or device.id) .. " " .. util.json_canonical(copy.desired))
end

-- Merge `patch` into desired state.  Confidence is tracked per field: only
-- the fields in the patch become trusted (a volume press says nothing about power).
function M.update(device, patch, source)
  local st = M.get(device)
  st.conf = st.conf or {}
  local now = os.time()
  for k, v in pairs(patch) do
    st.desired[k] = v
    st.conf[k] = now
  end
  st.source = source or "commanded"
  st.updated = now
  st.confidence = "high"
  schedule_checkpoint(device, st)
  return st
end

-- Record values that were actually transmitted successfully (a snapshot taken
-- when the request was queued, not the current desired state).
function M.commanded(device, values)
  if not values then return end
  local st = M.get(device)
  for k, v in pairs(values) do st.last_commanded[k] = util.deep_copy(v) end
  st.updated = os.time()
  schedule_checkpoint(device, st)
end

-- A transmission failed: the assumed values of these fields are not trusted.
function M.invalidate(device, fields)
  local st = M.get(device)
  st.conf = st.conf or {}
  for _, k in ipairs(fields or {}) do st.conf[k] = nil end
end

function M.is_confident(device, field)
  local st = M.get(device)
  local t = st.conf and st.conf[field]
  return t ~= nil and os.time() - t <= M.STALE_SEC
end

return M
