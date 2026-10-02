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
M.LEARN_TIMEOUT_SEC = 30
M.CHUNK_RETRY_SEC = 5 -- the device can take >3 s to answer the first request
M.CHUNK_RETRIES = 5
-- Firmware 23062026 requests chunks with seq=0 regardless of the announced
-- sequence, so every outbound transfer uses seq 0 and transfers are serialized.
M.TX_SEQ = 0

local F_RX = "zosung_rx"         -- learn transfer in progress
local F_TX = "zosung_tx"         -- outbound transfer in progress
local F_LEARN = "zosung_learning" -- learning window token

-- sinks set by init.lua
M.on_learned = function(device, code_b64, raw_len) end
M.on_learn_timeout = function(device) end
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

function M.start_learning(device, timeout_sec)
  local token = (device:get_field("zosung_learn_seqno") or 0) + 1
  device:set_field("zosung_learn_seqno", token)
  device:set_field(F_LEARN, token)
  device:set_field(F_RX, nil)
  log.info("[ZGIR] E004 study=0 (learning window open)")
  zigbee.send_cluster_command(device, M.CLUSTER_CONTROL, 0x00, json.encode({ study = 0 }))
  device.thread:call_with_delay(timeout_sec or M.LEARN_TIMEOUT_SEC, function()
    if device:get_field(F_LEARN) == token and device:get_field(F_RX) == nil then
      log.warn("[ZGIR] learning timed out")
      M.stop_learning(device)
      M.on_learn_timeout(device)
    end
  end)
end

function M.stop_learning(device)
  device:set_field(F_LEARN, nil)
  log.info("[ZGIR] E004 study=1 (learning window closed)")
  zigbee.send_cluster_command(device, M.CLUSTER_CONTROL, 0x00, json.encode({ study = 1 }))
end

local function request_chunk(device, rx)
  rx.req_id = (rx.req_id or 0) + 1
  local req = rx.req_id
  send(device, 0x02, M.frame_02(rx.seq, #rx.buffer, M.CHUNK_SIZE))
  device.thread:call_with_delay(M.CHUNK_RETRY_SEC, function()
    local cur = device:get_field(F_RX)
    if cur ~= rx or rx.req_id ~= req or rx.done then return end
    rx.retries = (rx.retries or 0) + 1
    if rx.retries > M.CHUNK_RETRIES then
      log.warn("[ZGIR] learn transfer stalled; giving up at " .. #rx.buffer .. "/" .. rx.length)
      device:set_field(F_RX, nil)
      return
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
  local part = tx.msg:sub(position + 1, position + math.max(1, maxlen))
  send(device, 0x03, M.frame_03(seq, position, part))
end

local function rx_03(driver, device, zb_rx)
  local zclh, body = zb_rx.body.zcl_header, zb_rx.body.zcl_body.body_bytes
  zigbee.ack(device, M.CLUSTER_TRANSFER, zclh)
  local ok, _, seq, position = unpack_safe("<I1I2I4", body)
  local part_len = body:byte(8)
  if not ok or part_len == nil or #body < 8 + part_len then
    return log.warn("[ZGIR] malformed ED00/0x03 len=" .. #body)
  end
  local rx = device:get_field(F_RX)
  if rx == nil or seq ~= rx.seq then
    return log.warn("[ZGIR] unexpected learn chunk seq=" .. seq)
  end
  local part = body:sub(9, 8 + part_len)
  local sum = body:byte(9 + part_len)
  if sum ~= nil and sum ~= crc(part) then
    log.warn("[ZGIR] learn chunk checksum mismatch at pos=" .. position .. "; re-requesting")
    return request_chunk(device, rx)
  end
  if position > #rx.buffer then
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
  end
end

local function rx_04(driver, device, zb_rx)
  local zclh, body = zb_rx.body.zcl_header, zb_rx.body.zcl_body.body_bytes
  zigbee.ack(device, M.CLUSTER_TRANSFER, zclh)
  local ok, status, seq = unpack_safe("<I1I2", body)
  if not ok then return log.warn("[ZGIR] malformed ED00/0x04") end
  send(device, 0x05, M.frame_05(seq))
  local tx = device:get_field(F_TX)
  device:set_field(F_TX, nil)
  if tx == nil then return log.debug("[ZGIR] transmit status without active transmit") end
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
  device:set_field(F_RX, nil)
  if rx == nil then return log.debug("[ZGIR] 0x05 without learn transfer") end
  rx.done = true
  if #rx.buffer ~= rx.length then
    log.warn(string.format("[ZGIR] learned length mismatch got=%d expected=%d", #rx.buffer, rx.length))
    if #rx.buffer == 0 then return end
  end
  local code = util.b64_encode(rx.buffer)
  log.info(string.format("[ZGIR] LEARN SUCCESS raw_bytes=%d", #rx.buffer))
  log.info("[ZGIR] LEARNED_CODE=" .. code)
  if M.is_learning(device) then M.stop_learning(device) end
  M.on_learned(device, code, #rx.buffer)
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
