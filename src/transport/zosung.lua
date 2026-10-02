-- Zosung IR protocol: 0xE004 learning control + 0xED00 chunked transfer.
--
-- Learn RX : dev 0x00 start -> hub 0x01 ack + 0x02 req(pos) -> dev 0x03 chunk ...
--            -> hub 0x04 done -> dev 0x05 finish  => learned bytes (Tuya-LZ timings)
-- Send TX  : hub 0x00 start -> dev 0x01 ack -> dev 0x02 req -> hub 0x03 chunk ...
--            -> dev 0x04 status -> hub 0x05 finish
--
-- Only the parent bridge device is ever passed in here.  Higher layers use
-- transport/tx_queue.lua for sending and the learn sink for receiving.
local json = require "st.json"
local log = require "log"
local util = require "util"
local zigbee = require "transport.zigbee"

local M = {}

M.CLUSTER_CONTROL = 0xE004
M.CLUSTER_TRANSFER = 0xED00
M.CHUNK_SIZE = 0x38
M.LEARN_TIMEOUT_SEC = 45
M.CHUNK_RETRY_SEC = 5 -- the device can take >3 s to answer the first request
M.CHUNK_RETRIES = 5
M.FIRST_CHUNK_WAIT_SEC = 10
M.FINISH_WAIT_SEC = 5
-- Firmware 23062026 requests chunks with seq=0 regardless of the announced
-- sequence, so every outbound transfer uses seq 0 and transfers are serialized.
M.TX_SEQ = 0

local F_RX = "zosung_rx"         -- learn transfer in progress
local F_TX = "zosung_tx"         -- outbound transfer in progress
local F_LEARN = "zosung_learning" -- learning window token

-- sinks set by init.lua
M.on_learned = function(device, code_b64, raw_len) end
M.on_learn_timeout = function(device, outcome) end
M.on_tx_status = function(device, ok, status) end

local function crc(bytes)
  local s = 0
  for i = 1, #bytes do s = (s + bytes:byte(i)) & 0xFF end
  return s
end
M.crc = crc

local function send(device, cmd, payload)
  log.debug(string.format("[ZGIR] TX ED00 cmd=0x%02X len=%d", cmd, #payload))
  zigbee.send_cluster_command(device, M.CLUSTER_TRANSFER, cmd, payload)
end

-- frame builders (little-endian)
function M.frame_00(seq, length, cmd)
  return string.pack("<I2I4I4I2I1I1I2", seq, length, 0, M.CLUSTER_CONTROL, 0x01, cmd or 0x02, 0)
end
function M.frame_01(seq, length, unk1, clusterid, unk2, cmd, unk3)
  return string.pack("<I1I2I4I4I2I1I1I2", 0, seq, length, unk1, clusterid, unk2, cmd, unk3)
end
function M.frame_02(seq, position, maxlen)
  return string.pack("<I2I4I1", seq, position, maxlen)
end
function M.frame_03(seq, position, part)
  return string.pack("<I1I2I4", 0, seq, position) .. string.char(#part) .. part .. string.char(crc(part))
end
function M.frame_04(seq) return string.pack("<I1I2I2", 0, seq, 0) end
function M.frame_05(seq) return string.pack("<I2I2", seq, 0) end

function M.build_ir_json(code_b64, freq)
  return json.encode({
    key_num = 1, delay = 300,
    key1 = { num = 1, freq = freq or 38000, type = 1, key_code = code_b64 },
  })
end

local function unpack_safe(fmt, body)
  local ok, a, b, c, d, e, f, g = pcall(string.unpack, fmt, body)
  if not ok then return nil end
  return true, a, b, c, d, e, f, g
end

--------------------------------------------------------------------------
-- Learning

function M.is_learning(device)
  return device:get_field(F_LEARN) ~= nil
end

-- Bridge busy with learning (window open or learned transfer in progress):
-- outbound transfers must wait (the ED00 cluster carries one transfer at a time).
function M.rx_busy(device)
  return device:get_field(F_LEARN) ~= nil or device:get_field(F_RX) ~= nil
end

-- Single terminal path for a learning attempt.  outcome: "timeout" | "failed".
local function end_learning(device, outcome, why)
  local had = device:get_field(F_LEARN) ~= nil or device:get_field(F_RX) ~= nil
  device:set_field(F_RX, nil)
  if device:get_field(F_LEARN) ~= nil then M.stop_learning(device) end
  if had then
    log.warn("[ZGIR] learning ended: " .. outcome .. (why and (" (" .. why .. ")") or ""))
    M.on_learn_timeout(device, outcome)
  end
end

local function open_window(device, timeout_sec)
  local token = (device:get_field("zosung_learn_seqno") or 0) + 1
  device:set_field("zosung_learn_seqno", token)
  device:set_field(F_LEARN, token)
  device:set_field(F_RX, nil)
  log.info("[ZGIR] E004 study=0 (learning window open)")
  zigbee.send_cluster_command(device, M.CLUSTER_CONTROL, 0x00, json.encode({ study = 0 }))
  local function check(extra)
    if device:get_field(F_LEARN) ~= token then return end
    local rx = device:get_field(F_RX)
    if rx == nil then return end_learning(device, "timeout") end
    -- a transfer is in progress: give it a bounded grace period
    if extra < 2 then
      return device.thread:call_with_delay(10, function() check(extra + 1) end)
    end
    end_learning(device, "failed", "transfer did not finish")
  end
  device.thread:call_with_delay(timeout_sec or M.LEARN_TIMEOUT_SEC, function() check(0) end)
end

-- Opening the window waits for an in-flight outbound transfer (bounded).
function M.start_learning(device, timeout_sec, attempt)
  attempt = attempt or 0
  if device:get_field(F_TX) ~= nil and attempt < 40 then
    return device.thread:call_with_delay(0.5, function() M.start_learning(device, timeout_sec, attempt + 1) end)
  end
  open_window(device, timeout_sec)
end

function M.stop_learning(device)
  device:set_field(F_LEARN, nil)
  log.info("[ZGIR] E004 study=1 (learning window closed)")
  zigbee.send_cluster_command(device, M.CLUSTER_CONTROL, 0x00, json.encode({ study = 1 }))
end

local function deliver(device, rx)
  device:set_field(F_RX, nil)
  local code = util.b64_encode(rx.buffer)
  log.info(string.format("[ZGIR] LEARN SUCCESS raw_bytes=%d", #rx.buffer))
  log.info("[ZGIR] LEARNED_CODE=" .. code)
  if M.is_learning(device) then M.stop_learning(device) end
  M.on_learned(device, code, #rx.buffer)
end

local function request_chunk(device, rx)
  rx.req_id = (rx.req_id or 0) + 1
  local req = rx.req_id
  send(device, 0x02, M.frame_02(rx.seq, #rx.buffer, M.CHUNK_SIZE))
  -- observed on hardware: the first chunk can take several seconds, later ones are fast
  local wait = (#rx.buffer == 0 and (rx.retries or 0) == 0) and M.FIRST_CHUNK_WAIT_SEC or M.CHUNK_RETRY_SEC
  device.thread:call_with_delay(wait, function()
    local cur = device:get_field(F_RX)
    if cur ~= rx or rx.req_id ~= req or rx.done then return end
    rx.retries = (rx.retries or 0) + 1
    if rx.retries > M.CHUNK_RETRIES then
      return end_learning(device, "failed", "transfer stalled at " .. #rx.buffer .. "/" .. rx.length)
    end
    log.debug("[ZGIR] learn chunk retry pos=" .. #rx.buffer)
    request_chunk(device, rx)
  end)
end

local function rx_00(driver, device, zb_rx)
  local zclh, body = zb_rx.body.zcl_header, zb_rx.body.zcl_body.body_bytes
  zigbee.ack(device, M.CLUSTER_TRANSFER, zclh)
  local ok, seq, length, unk1, clusterid, unk2, cmd, unk3 = unpack_safe("<I2I4I4I2I1I1I2", body)
  if not ok then return log.warn("[ZGIR] malformed ED00/0x00") end
  if length == 0 or length > 16384 then
    return log.warn("[ZGIR] learn start with implausible length " .. length)
  end
  log.info(string.format("[ZGIR] RX learn start seq=%d len=%d", seq, length))
  local rx = { seq = seq, length = length, buffer = "" }
  device:set_field(F_RX, rx)
  send(device, 0x01, M.frame_01(seq, length, unk1, clusterid, unk2, cmd, unk3))
  request_chunk(device, rx)
end

local function rx_01(driver, device, zb_rx)
  zigbee.ack(device, M.CLUSTER_TRANSFER, zb_rx.body.zcl_header)
  log.debug("[ZGIR] RX 0x01 transmit start acknowledged")
end

local function rx_02(driver, device, zb_rx)
  local zclh, body = zb_rx.body.zcl_header, zb_rx.body.zcl_body.body_bytes
  zigbee.ack(device, M.CLUSTER_TRANSFER, zclh)
  local ok, seq, position, maxlen = unpack_safe("<I2I4I1", body)
  if not ok then return log.warn("[ZGIR] malformed ED00/0x02") end
  local tx = device:get_field(F_TX)
  if tx == nil then return log.warn("[ZGIR] chunk request without active transmit seq=" .. seq) end
  if position >= #tx.msg then return log.warn("[ZGIR] chunk request beyond payload pos=" .. position) end
  tx.last_activity = os.time()
  tx.chunks = (tx.chunks or 0) + 1
  local part = tx.msg:sub(position + 1, position + math.max(1, maxlen))
  send(device, 0x03, M.frame_03(seq, position, part))
end

local function rx_03(driver, device, zb_rx)
  local zclh, body = zb_rx.body.zcl_header, zb_rx.body.zcl_body.body_bytes
  zigbee.ack(device, M.CLUSTER_TRANSFER, zclh)
  local ok, _, seq, position = unpack_safe("<I1I2I4", body)
  local part_len = body:byte(8)
  if not ok or part_len == nil or #body < 9 + part_len then -- data + checksum byte
    return log.warn("[ZGIR] malformed ED00/0x03 len=" .. #body)
  end
  local rx = device:get_field(F_RX)
  if rx == nil or seq ~= rx.seq then
    return log.warn("[ZGIR] unexpected learn chunk seq=" .. seq)
  end
  local part = body:sub(9, 8 + part_len)
  local sum = body:byte(9 + part_len)
  if sum ~= crc(part) then
    log.warn("[ZGIR] learn chunk checksum mismatch at pos=" .. position .. "; re-requesting")
    return request_chunk(device, rx)
  end
  if position > #rx.buffer or position + #part > rx.length then
    log.warn("[ZGIR] learn chunk gap pos=" .. position .. " have=" .. #rx.buffer)
    return request_chunk(device, rx)
  end
  -- overwrite at position so retransmissions never duplicate data
  rx.buffer = rx.buffer:sub(1, position) .. part .. rx.buffer:sub(position + #part + 1)
  rx.retries = 0
  if #rx.buffer < rx.length then
    request_chunk(device, rx)
  else
    rx.done = true
    rx.req_id = (rx.req_id or 0) + 1
    send(device, 0x04, M.frame_04(seq))
    -- the buffer is complete and checksummed; if the 0x05 finish is lost,
    -- deliver anyway instead of leaving the bridge busy
    device.thread:call_with_delay(M.FINISH_WAIT_SEC, function()
      if device:get_field(F_RX) == rx then
        log.warn("[ZGIR] learn finish (0x05) not received; delivering complete buffer")
        deliver(device, rx)
      end
    end)
  end
end

local function rx_04(driver, device, zb_rx)
  local zclh, body = zb_rx.body.zcl_header, zb_rx.body.zcl_body.body_bytes
  zigbee.ack(device, M.CLUSTER_TRANSFER, zclh)
  local ok, status, seq = unpack_safe("<I1I2", body)
  if not ok then return log.warn("[ZGIR] malformed ED00/0x04") end
  send(device, 0x05, M.frame_05(seq))
  local tx = device:get_field(F_TX)
  if tx == nil then return log.debug("[ZGIR] transmit status without active transmit") end
  if (tx.chunks or 0) == 0 then
    -- seq is always 0, so a late status of an abandoned transfer is only
    -- recognisable by phase: this transfer has not delivered any chunk yet
    return log.warn("[ZGIR] ignoring transmit status before any chunk was requested (stale)")
  end
  device:set_field(F_TX, nil)
  if status == 0 then
    log.info(string.format("[ZGIR] IR TRANSMIT COMPLETED seq=%d bytes=%d", seq, #tx.msg))
  else
    log.warn(string.format("[ZGIR] IR transmit failed seq=%d status=0x%02X", seq, status))
  end
  M.on_tx_status(device, status == 0, status)
end

local function rx_05(driver, device, zb_rx)
  zigbee.ack(device, M.CLUSTER_TRANSFER, zb_rx.body.zcl_header)
  local rx = device:get_field(F_RX)
  if rx == nil then return log.debug("[ZGIR] 0x05 without learn transfer") end
  if not rx.done or #rx.buffer ~= rx.length then
    return end_learning(device, "failed",
      string.format("finish before transfer complete got=%d expected=%d", #rx.buffer, rx.length))
  end
  deliver(device, rx)
end

-- Begin an outbound transfer of an IR JSON message.  Caller (tx_queue)
-- guarantees there is no other transfer in flight.
function M.begin_transmit(device, ir_json)
  device:set_field(F_TX, { msg = ir_json, started = os.time(), last_activity = os.time() })
  log.info(string.format("[ZGIR] IR transmit start seq=%d json_bytes=%d", M.TX_SEQ, #ir_json))
  send(device, 0x00, M.frame_00(M.TX_SEQ, #ir_json, 0x02))
end

function M.abort_transmit(device)
  device:set_field(F_TX, nil)
end

-- number of chunk requests served for the in-flight transfer (nil if none)
function M.tx_progress(device)
  local tx = device:get_field(F_TX)
  return tx and (tx.chunks or 0) or nil
end

function M.tx_active(device)
  return device:get_field(F_TX) ~= nil
end

M.cluster_handlers = {
  [M.CLUSTER_TRANSFER] = {
    [0x00] = rx_00, [0x01] = rx_01, [0x02] = rx_02,
    [0x03] = rx_03, [0x04] = rx_04, [0x05] = rx_05,
  },
  [M.CLUSTER_CONTROL] = {
    [0x00] = function(driver, device, zb_rx)
      zigbee.ack(device, M.CLUSTER_CONTROL, zb_rx.body.zcl_header)
      log.debug("[ZGIR] RX E004 " .. tostring(zb_rx.body.zcl_body.body_bytes))
    end,
  },
}

return M
