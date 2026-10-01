-- HOBEIAN ZG-IR01 arbitrary-IR probe
--
-- Probe UI mapping (uses only stock SmartThings capabilities):
--   Refresh    -> start IR learning
--   Switch ON  -> replay the last code learned through the hub
--   Switch OFF -> cancel IR learning
--
-- Purpose:
--   Prove that the 2026 ZG-IR01 firmware supports the Zosung E004/ED00
--   arbitrary IR path, not merely the 12 on-device EF00 slots.
--
-- Protocol is ported from current zigbee-herdsman-converters lib/zosung.ts
-- and a SmartThings Edge TS1201 Zosung implementation that has been tested
-- on physical hardware.  ZG-IR01 uses the same chunk handshake.
--
-- IMPORTANT:
-- Current Zigbee2MQTT definitions create these custom clusters without a
-- manufacturer code, so this probe sends ordinary cluster-specific frames.
-- If logcat shows no response at all after a real remote is aimed at the
-- device during learning, set USE_MFG_SPECIFIC to true and repackage as a
-- diagnostic fallback (some TS1201 variants accept/use 0x1002).

local capabilities = require "st.capabilities"
local ZigbeeDriver = require "st.zigbee"
local defaults = require "st.zigbee.defaults"
local clusters = require "st.zigbee.zcl.clusters"
local zcl_messages = require "st.zigbee.zcl"
local zcl_types = require "st.zigbee.zcl.types"
local messages = require "st.zigbee.messages"
local data_types = require "st.zigbee.data_types"
local zb_const = require "st.zigbee.constants"
local generic_body = require "st.zigbee.generic_body"
local default_response = require "st.zigbee.zcl.global_commands.default_response"
local json = require "st.json"
local log = require "log"

local Basic = clusters.Basic

local CLUSTER_ZOSUNG_CONTROL = 0xE004
local CLUSTER_ZOSUNG_TRANSMIT = 0xED00
local ZOSUNG_MFG_CODE = 0x1002
local USE_MFG_SPECIFIC = false
local CHUNK_SIZE = 0x38
local LEARN_TIMEOUT_SEC = 60

--------------------------------------------------
-- base64 (pure Lua)

local B64_CHARS = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"

local function base64_encode(data)
  local out = {}
  for i = 1, #data, 3 do
    local b1, b2, b3 = string.byte(data, i, i + 2)
    b2 = b2 or 0
    b3 = b3 or 0
    local n = b1 * 65536 + b2 * 256 + b3
    local c1 = math.floor(n / 262144) % 64
    local c2 = math.floor(n / 4096) % 64
    local c3 = math.floor(n / 64) % 64
    local c4 = n % 64
    local chunk_len = math.min(3, #data - i + 1)
    out[#out + 1] = B64_CHARS:sub(c1 + 1, c1 + 1)
    out[#out + 1] = B64_CHARS:sub(c2 + 1, c2 + 1)
    out[#out + 1] = (chunk_len >= 2) and B64_CHARS:sub(c3 + 1, c3 + 1) or "="
    out[#out + 1] = (chunk_len >= 3) and B64_CHARS:sub(c4 + 1, c4 + 1) or "="
  end
  return table.concat(out)
end

--------------------------------------------------
-- Zosung helpers

local function crc_sum(bytes)
  local sum = 0
  for i = 1, #bytes do
    sum = (sum + string.byte(bytes, i)) % 256
  end
  return sum
end

-- ZG-IR01 firmware 23062026 behaves differently from some TS1201 variants:
-- after accepting a transmit-start frame with a non-zero sequence, it still asks
-- for payload chunks using seq=0.  Current zigbee-herdsman-converters also
-- effectively starts each independent send at seq=0 (nextSeq() does not persist
-- the incremented value).  Keep TX seq fixed at zero for this device.
local function next_seq(device)
  return 0
end

local function build_zcl_header(cmd_id, mfg_specific)
  local header_args = {
    cmd = data_types.ZCLCommandId(cmd_id),
  }

  if mfg_specific then
    header_args.mfg_code =
      data_types.validate_or_build_type(ZOSUNG_MFG_CODE, data_types.Uint16, "mfg_code")
  end

  local zclh = zcl_messages.ZclHeader(header_args)
  zclh.frame_ctrl:set_cluster_specific()

  if mfg_specific then
    zclh.frame_ctrl:set_mfg_specific()
  end

  zclh.frame_ctrl:set_disable_default_response()
  return zclh
end

local function send_zosung_frame(device, cluster_id, cmd_id, payload_bytes)
  local zclh = build_zcl_header(cmd_id, USE_MFG_SPECIFIC)

  local endpoint = device:get_endpoint(cluster_id) or device.fingerprinted_endpoint_id or 1

  local addrh = messages.AddressHeader(
    zb_const.HUB.ADDR,
    zb_const.HUB.ENDPOINT,
    device:get_short_address(),
    endpoint,
    zb_const.HA_PROFILE_ID,
    cluster_id
  )

  local payload_body = generic_body.GenericBody(payload_bytes)
  local message_body =
    zcl_messages.ZclMessageBody({ zcl_header = zclh, zcl_body = payload_body })

  log.debug(string.format(
    "[ZGIR] TX cluster=0x%04X cmd=0x%02X bytes=%d mfg=%s",
    cluster_id, cmd_id, #payload_bytes, tostring(USE_MFG_SPECIFIC)
  ))

  device:send(messages.ZigbeeMessageTx({
    address_header = addrh,
    body = message_body,
  }))
end

local function maybe_ack(device, zclh)
  if zclh.frame_ctrl:is_disable_default_response_set() then
    return
  end

  local header_args = {
    cmd = data_types.ZCLCommandId(default_response.DefaultResponse.ID),
    seqno = data_types.Uint8(zclh.seqno.value),
  }

  local incoming_mfg = zclh.frame_ctrl:is_mfg_specific_set()
  if incoming_mfg and zclh.mfg_code ~= nil then
    header_args.mfg_code = data_types.validate_or_build_type(
      zclh.mfg_code.value, data_types.Uint16, "mfg_code"
    )
  end

  local dr_zclh = zcl_messages.ZclHeader(header_args)
  if incoming_mfg then
    dr_zclh.frame_ctrl:set_mfg_specific()
  end

  local endpoint = device:get_endpoint(CLUSTER_ZOSUNG_TRANSMIT)
    or device.fingerprinted_endpoint_id
    or 1

  local addrh = messages.AddressHeader(
    zb_const.HUB.ADDR,
    zb_const.HUB.ENDPOINT,
    device:get_short_address(),
    endpoint,
    zb_const.HA_PROFILE_ID,
    CLUSTER_ZOSUNG_TRANSMIT
  )

  local dr_body = default_response.DefaultResponse(
    data_types.Uint8(zclh.cmd.value),
    zcl_types.ZclStatus.SUCCESS
  )

  local message_body =
    zcl_messages.ZclMessageBody({ zcl_header = dr_zclh, zcl_body = dr_body })

  device:send(messages.ZigbeeMessageTx({
    address_header = addrh,
    body = message_body,
  }))
end

local function send_ircontrol_json(device, tbl)
  local payload = json.encode(tbl)
  log.info("[ZGIR] E004 control " .. payload)
  send_zosung_frame(device, CLUSTER_ZOSUNG_CONTROL, 0x00, payload)
end

-- 0xED00 payloads, little-endian.
local function build_frame_00(seq, length, clusterid, unk2, cmd)
  return string.pack("<I2I4I4I2I1I1I2",
    seq, length, 0, clusterid, unk2, cmd, 0)
end

local function build_frame_01(seq, length, unk1, clusterid, unk2, cmd, unk3)
  return string.pack("<I1I2I4I4I2I1I1I2",
    0, seq, length, unk1, clusterid, unk2, cmd, unk3)
end

local function build_frame_02(seq, position, maxlen)
  return string.pack("<I2I4I1", seq, position, maxlen)
end

local function build_frame_03(seq, position, msgpart, crc)
  return string.pack("<I1I2I4", 0, seq, position)
    .. string.char(#msgpart)
    .. msgpart
    .. string.char(crc)
end

local function build_frame_04(seq)
  return string.pack("<I1I2I2", 0, seq, 0)
end

local function build_frame_05(seq)
  return string.pack("<I2I2", seq, 0)
end

--------------------------------------------------
-- Learn / replay

local function build_ir_message(base64_code)
  return json.encode({
    key_num = 1,
    delay = 300,
    key1 = {
      num = 1,
      freq = 38000,
      type = 1,
      key_code = base64_code,
    },
  })
end

local function send_ir_code(device, base64_code)
  if base64_code == nil or base64_code:match("^%s*$") then
    log.warn("[ZGIR] no learned IR code to replay")
    return
  end

  -- TX sequence is fixed to 0 on ZG-IR01, so do not let a second replay replace
  -- the payload while the first transfer is still being pulled by the device.
  if device:get_field("zosung_send_busy") then
    log.warn("[ZGIR] transmit already in progress; ignoring overlapping replay")
    return
  end

  local ir_msg = build_ir_message(base64_code)
  local seq = next_seq(device)

  local pending = {}
  pending[seq] = ir_msg
  device:set_field("zosung_send_pending", pending)
  device:set_field("zosung_send_busy", true)

  log.info(string.format(
    "[ZGIR] starting arbitrary IR transmit seq=%d json_bytes=%d",
    seq, #ir_msg
  ))

  send_zosung_frame(
    device,
    CLUSTER_ZOSUNG_TRANSMIT,
    0x00,
    build_frame_00(seq, #ir_msg, CLUSTER_ZOSUNG_CONTROL, 0x01, 0x02)
  )

  -- Recovery guard in case a transfer dies before frame 0x04 arrives.
  device.thread:call_with_delay(15, function()
    if device:get_field("zosung_send_busy") then
      log.warn("[ZGIR] transmit watchdog expired; clearing busy state")
      device:set_field("zosung_send_busy", false)
      device:set_field("zosung_send_pending", {})
    end
  end)
end

local function stop_learning(device)
  local token = (device:get_field("learn_token") or 0) + 1
  device:set_field("learn_token", token)
  send_ircontrol_json(device, { study = 1 })
  log.info("[ZGIR] learning stopped")
end

local function start_learning(device)
  local token = (device:get_field("learn_token") or 0) + 1
  device:set_field("learn_token", token)

  send_ircontrol_json(device, { study = 0 })
  log.info("[ZGIR] learning started; aim a physical remote at ZG-IR01 now")

  device.thread:call_with_delay(LEARN_TIMEOUT_SEC, function()
    if device:get_field("learn_token") == token then
      log.warn("[ZGIR] learning timed out")
      stop_learning(device)
    end
  end)
end

--------------------------------------------------
-- 0xED00 inbound handshake

local function handle_frame_00(driver, device, zb_rx)
  local zclh = zb_rx.body.zcl_header
  local body = zb_rx.body.zcl_body.body_bytes
  local seq, length, unk1, clusterid, unk2, cmd, unk3 =
    string.unpack("<I2I4I4I2I1I1I2", body)

  maybe_ack(device, zclh)

  log.info(string.format(
    "[ZGIR] RX 0x00 learned-transfer start seq=%d len=%d cluster=0x%04X cmd=0x%02X",
    seq, length, clusterid, cmd
  ))

  device:set_field("zosung_learn_seq", seq)
  device:set_field("zosung_learn_length", length)
  device:set_field("zosung_learn_buffer", "")

  send_zosung_frame(
    device,
    CLUSTER_ZOSUNG_TRANSMIT,
    0x01,
    build_frame_01(seq, length, unk1, clusterid, unk2, cmd, unk3)
  )

  send_zosung_frame(
    device,
    CLUSTER_ZOSUNG_TRANSMIT,
    0x02,
    build_frame_02(seq, 0, CHUNK_SIZE)
  )
end

local function handle_frame_01(driver, device, zb_rx)
  maybe_ack(device, zb_rx.body.zcl_header)
  log.debug("[ZGIR] RX 0x01 transmit-start acknowledged")
end

local function handle_frame_02(driver, device, zb_rx)
  local zclh = zb_rx.body.zcl_header
  local body = zb_rx.body.zcl_body.body_bytes
  local seq, position, maxlen = string.unpack("<I2I4I1", body)

  maybe_ack(device, zclh)

  log.debug(string.format(
    "[ZGIR] RX 0x02 chunk request seq=%d pos=%d max=%d",
    seq, position, maxlen
  ))

  local msg = (device:get_field("zosung_send_pending") or {})[seq]
  if msg == nil then
    log.warn("[ZGIR] chunk request for unknown seq " .. tostring(seq))
    return
  end

  local part = msg:sub(position + 1, position + maxlen)

  send_zosung_frame(
    device,
    CLUSTER_ZOSUNG_TRANSMIT,
    0x03,
    build_frame_03(seq, position, part, crc_sum(part))
  )
end

local function handle_frame_03(driver, device, zb_rx)
  local zclh = zb_rx.body.zcl_header
  local body = zb_rx.body.zcl_body.body_bytes

  local _zero, seq, position = string.unpack("<I1I2I4", body)
  local part_len = string.byte(body, 8)

  if part_len == nil then
    log.warn("[ZGIR] malformed 0x03 frame")
    return
  end

  local msgpart = body:sub(9, 8 + part_len)
  local msgpartcrc = string.byte(body, 9 + part_len)

  maybe_ack(device, zclh)

  if seq ~= device:get_field("zosung_learn_seq") then
    log.warn(string.format(
      "[ZGIR] unexpected learn seq=%d expected=%s",
      seq, tostring(device:get_field("zosung_learn_seq"))
    ))
    return
  end

  if msgpartcrc ~= nil and crc_sum(msgpart) ~= msgpartcrc then
    log.warn("[ZGIR] learn chunk checksum mismatch; retaining chunk for diagnosis")
  end

  local buffer = device:get_field("zosung_learn_buffer") or ""

  -- Position is zero-based.  Overwrite at requested position so Zigbee
  -- retransmissions do not duplicate a chunk.
  buffer =
    buffer:sub(1, position)
    .. msgpart
    .. buffer:sub(position + #msgpart + 1)

  device:set_field("zosung_learn_buffer", buffer)

  local expected = device:get_field("zosung_learn_length") or 0

  log.debug(string.format(
    "[ZGIR] RX 0x03 learn chunk pos=%d bytes=%d total=%d/%d",
    position, #msgpart, #buffer, expected
  ))

  if #buffer < expected then
    send_zosung_frame(
      device,
      CLUSTER_ZOSUNG_TRANSMIT,
      0x02,
      build_frame_02(seq, #buffer, CHUNK_SIZE)
    )
  else
    send_zosung_frame(
      device,
      CLUSTER_ZOSUNG_TRANSMIT,
      0x04,
      build_frame_04(seq)
    )
  end
end

local function handle_frame_04(driver, device, zb_rx)
  local zclh = zb_rx.body.zcl_header
  local body = zb_rx.body.zcl_body.body_bytes

  local status, seq = string.unpack("<I1I2", body)
  maybe_ack(device, zclh)

  send_zosung_frame(
    device,
    CLUSTER_ZOSUNG_TRANSMIT,
    0x05,
    build_frame_05(seq)
  )

  local pending = device:get_field("zosung_send_pending")
  if pending ~= nil then
    pending[seq] = nil
  end
  device:set_field("zosung_send_busy", false)

  if status == 0 then
    log.info("[ZGIR] ARBITRARY IR TRANSMIT COMPLETED seq=" .. tostring(seq))
  else
    log.warn(string.format(
      "[ZGIR] arbitrary IR transmit FAILED seq=%d status=0x%02X",
      seq, status
    ))
  end
end

local function handle_frame_05(driver, device, zb_rx)
  maybe_ack(device, zb_rx.body.zcl_header)

  local buffer = device:get_field("zosung_learn_buffer") or ""
  local expected = device:get_field("zosung_learn_length") or 0

  device:set_field("zosung_learn_buffer", nil)
  device:set_field("zosung_learn_seq", nil)
  device:set_field("zosung_learn_length", nil)

  if expected > 0 and #buffer ~= expected then
    log.warn(string.format(
      "[ZGIR] learned buffer length mismatch got=%d expected=%d",
      #buffer, expected
    ))
  end

  if #buffer == 0 then
    log.warn("[ZGIR] learn finished with an empty buffer")
    return
  end

  local learned_code = base64_encode(buffer)

  -- Persist the latest learned raw code so a driver restart does not lose the probe.
  device:set_field("last_ir_code", learned_code, { persist = true })

  -- Invalidate the learning watchdog.
  device:set_field("learn_token", (device:get_field("learn_token") or 0) + 1)

  log.info(string.format(
    "[ZGIR] LEARN SUCCESS raw_bytes=%d base64_bytes=%d",
    #buffer, #learned_code
  ))
  log.info("[ZGIR] LEARNED_CODE=" .. learned_code)

  stop_learning(device)
end

--------------------------------------------------
-- Stock capability mapping for the probe

local function refresh_handler(driver, device, command)
  -- Refresh is deliberately repurposed as the "Learn" button for this probe.
  start_learning(device)
end

local function switch_on_handler(driver, device, command)
  local code = device:get_field("last_ir_code")
  if code == nil then
    log.warn("[ZGIR] replay requested but no code has been learned yet")
    device:emit_event(capabilities.switch.switch.off())
    return
  end

  send_ir_code(device, code)

  -- Make the switch behave like a momentary replay button.
  device.thread:call_with_delay(0.5, function()
    device:emit_event(capabilities.switch.switch.off())
  end)
end

local function switch_off_handler(driver, device, command)
  stop_learning(device)
  device:emit_event(capabilities.switch.switch.off())
end

--------------------------------------------------
-- Firmware read for correlation with the known 2026 build

local function log_basic_attr(name)
  return function(driver, device, value, zb_rx)
    log.info(string.format(
      "[ZGIR] BASIC %s=%s",
      name,
      tostring(value.value)
    ))
  end
end

local function read_identity(device)
  device.thread:call_with_delay(1, function()
    device:send(Basic.attributes.ApplicationVersion:read(device))
  end)

  device.thread:call_with_delay(2, function()
    device:send(Basic.attributes.HWVersion:read(device))
  end)

  device.thread:call_with_delay(3, function()
    device:send(Basic.attributes.DateCode:read(device))
  end)

  device.thread:call_with_delay(4, function()
    device:send(Basic.attributes.SWBuildID:read(device))
  end)
end

local function device_added(driver, device)
  device:emit_event(capabilities.switch.switch.off())
  read_identity(device)
end

local function device_init(driver, device)
  if device:get_latest_state("main", capabilities.switch.ID, capabilities.switch.switch.NAME) == nil then
    device:emit_event(capabilities.switch.switch.off())
  end

  read_identity(device)

  local stored = device:get_field("last_ir_code")
  if stored ~= nil then
    log.info("[ZGIR] persisted learned code is available for replay")
  end
end

--------------------------------------------------

local driver_template = {
  supported_capabilities = {
    capabilities.switch,
    capabilities.refresh,
    capabilities.temperatureMeasurement,
    capabilities.relativeHumidityMeasurement,
    capabilities.battery,
  },

  zigbee_handlers = {
    attr = {
      [Basic.ID] = {
        [Basic.attributes.ApplicationVersion.ID] = log_basic_attr("ApplicationVersion"),
        [Basic.attributes.HWVersion.ID] = log_basic_attr("HWVersion"),
        [Basic.attributes.DateCode.ID] = log_basic_attr("DateCode"),
        [Basic.attributes.SWBuildID.ID] = log_basic_attr("SWBuildID"),
      },
    },

    cluster = {
      [CLUSTER_ZOSUNG_TRANSMIT] = {
        [0x00] = handle_frame_00,
        [0x01] = handle_frame_01,
        [0x02] = handle_frame_02,
        [0x03] = handle_frame_03,
        [0x04] = handle_frame_04,
        [0x05] = handle_frame_05,
      },
    },
  },

  capability_handlers = {
    [capabilities.refresh.ID] = {
      [capabilities.refresh.commands.refresh.NAME] = refresh_handler,
    },

    [capabilities.switch.ID] = {
      [capabilities.switch.commands.on.NAME] = switch_on_handler,
      [capabilities.switch.commands.off.NAME] = switch_off_handler,
    },
  },

  lifecycle_handlers = {
    added = device_added,
    init = device_init,
  },

  health_check = false,
}

-- Keep stock handlers for the device's standard 0x0402/0x0405/0x0001 clusters.
defaults.register_for_default_handlers(
  driver_template,
  driver_template.supported_capabilities
)

local driver = ZigbeeDriver("HOBEIAN ZG-IR01 Arbitrary IR Probe", driver_template)
driver:run()
