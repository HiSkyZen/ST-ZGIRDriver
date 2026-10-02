-- Central serialized IR transmit queue (one per ZG-IR01 bridge).
--
-- request = {
--   code = "<zosung base64>", freq = 38000, label = "tv1:vol_up",
--   coalesce = nil | "ac:<child id>",  -- replaces a queued (not in-flight) request with same key
--   delay = 0,                         -- seconds the request waits before it may be sent (debounce)
--   on_done = function(ok, err) end,
-- }
-- Stateless requests (VOL+ x3) are all kept in FIFO order.  Stateful requests
-- with a coalesce key collapse so only the final state is transmitted.
local log = require "log"
local zosung = require "transport.zosung"

local M = {}

M.WATCHDOG_SEC = 15
M.MAX_ATTEMPTS = 2       -- first try + one retry after watchdog timeout
M.INTER_FRAME_SEC = 0.25 -- settle time between consecutive transfers
M.MAX_QUEUE = 40

local F_Q = "txq"

local function q(device)
  local st = device:get_field(F_Q)
  if st == nil then
    st = { items = {}, inflight = nil, gen = 0 }
    device:set_field(F_Q, st)
  end
  return st
end

local function finish(item, ok, err)
  if item and item.on_done then
    local cok, cerr = pcall(item.on_done, ok, err)
    if not cok then log.error("[ZGIR] tx on_done error: " .. tostring(cerr)) end
  end
end

local pump

local function start(device, st, item)
  st.inflight = item
  item.attempt = (item.attempt or 0) + 1
  st.gen = st.gen + 1
  local gen = st.gen
  log.info(string.format("[ZGIR] TXQ send %s attempt=%d queued=%d", item.label or "?", item.attempt, #st.items))
  zosung.begin_transmit(device, zosung.build_ir_json(item.code, item.freq))
  device.thread:call_with_delay(M.WATCHDOG_SEC, function()
    if st.inflight ~= item or st.gen ~= gen then return end
    zosung.abort_transmit(device)
    st.inflight = nil
    if item.attempt < M.MAX_ATTEMPTS then
      log.warn("[ZGIR] TXQ watchdog: retrying " .. (item.label or "?"))
      table.insert(st.items, 1, item)
    else
      log.warn("[ZGIR] TXQ watchdog: giving up " .. (item.label or "?"))
      finish(item, false, "timeout")
    end
    pump(device)
  end)
end

pump = function(device)
  local st = q(device)
  if st.inflight ~= nil or st.pumping then return end
  for idx, item in ipairs(st.items) do
    if item.ready then
      table.remove(st.items, idx)
      st.pumping = true
      device.thread:call_with_delay(st.last_done and M.INTER_FRAME_SEC or 0, function()
        st.pumping = false
        if st.inflight ~= nil then
          table.insert(st.items, 1, item)
          return
        end
        start(device, st, item)
      end)
      return
    end
    -- FIFO: a not-yet-ready stateless item blocks the ones behind it
    if not item.coalesce then return end
  end
end

local function arm(device, st, item)
  item.arm_id = (item.arm_id or 0) + 1
  local id = item.arm_id
  if (item.delay or 0) <= 0 then
    item.ready = true
    return pump(device)
  end
  item.ready = false
  device.thread:call_with_delay(item.delay, function()
    if item.arm_id ~= id then return end
    item.ready = true
    pump(device)
  end)
end

function M.enqueue(device, req)
  local st = q(device)
  if type(req.code) ~= "string" or #req.code == 0 then
    finish(req, false, "empty code")
    return false
  end
  if req.coalesce then
    for _, item in ipairs(st.items) do
      if item.coalesce == req.coalesce then
        log.debug("[ZGIR] TXQ coalesce " .. req.coalesce)
        local old_done = item.on_done
        item.code, item.freq, item.label, item.on_done = req.code, req.freq, req.label, req.on_done
        item.delay = req.delay
        if old_done then pcall(old_done, false, "superseded") end
        arm(device, st, item)
        return true
      end
    end
  end
  if #st.items >= M.MAX_QUEUE then
    log.warn("[ZGIR] TXQ full; dropping " .. (req.label or "?"))
    finish(req, false, "queue full")
    return false
  end
  local item = {
    code = req.code, freq = req.freq, label = req.label, coalesce = req.coalesce,
    delay = req.delay, on_done = req.on_done,
  }
  st.items[#st.items + 1] = item
  arm(device, st, item)
  return true
end

-- Called from zosung.on_tx_status.
function M.on_tx_status(device, ok, status)
  local st = q(device)
  local item = st.inflight
  st.inflight = nil
  st.last_done = true
  st.gen = st.gen + 1
  if item then
    local err = nil
    if not ok then err = string.format("device status 0x%02X", status or 0xFF) end
    finish(item, ok, err)
  end
  pump(device)
end

function M.clear(device)
  local st = q(device)
  for _, item in ipairs(st.items) do finish(item, false, "cleared") end
  st.items = {}
  if st.inflight then
    zosung.abort_transmit(device)
    finish(st.inflight, false, "cleared")
    st.inflight = nil
  end
end

function M.stats(device)
  local st = q(device)
  return { queued = #st.items, inflight = st.inflight and st.inflight.label or nil }
end

return M
