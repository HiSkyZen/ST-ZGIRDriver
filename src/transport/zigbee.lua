-- Raw ZCL frame helpers for the Zosung manufacturer clusters.
local zcl_messages = require "st.zigbee.zcl"
local zcl_types = require "st.zigbee.zcl.types"
local messages = require "st.zigbee.messages"
local data_types = require "st.zigbee.data_types"
local zb_const = require "st.zigbee.constants"
local generic_body = require "st.zigbee.generic_body"
local default_response = require "st.zigbee.zcl.global_commands.default_response"

local M = {}

-- ZG-IR01 (and current Zigbee2MQTT definitions) use plain cluster-specific
-- frames without a manufacturer code.  Kept switchable for TS1201 variants.
M.USE_MFG_SPECIFIC = false
M.MFG_CODE = 0x1002

local function endpoint_for(device, cluster_id)
  return device:get_endpoint(cluster_id) or device.fingerprinted_endpoint_id or 1
end

local function address(device, cluster_id)
  return messages.AddressHeader(
    zb_const.HUB.ADDR, zb_const.HUB.ENDPOINT,
    device:get_short_address(), endpoint_for(device, cluster_id),
    zb_const.HA_PROFILE_ID, cluster_id)
end

function M.send_cluster_command(device, cluster_id, cmd_id, payload)
  local args = { cmd = data_types.ZCLCommandId(cmd_id) }
  if M.USE_MFG_SPECIFIC then
    args.mfg_code = data_types.validate_or_build_type(M.MFG_CODE, data_types.Uint16, "mfg_code")
  end
  local zclh = zcl_messages.ZclHeader(args)
  zclh.frame_ctrl:set_cluster_specific()
  if M.USE_MFG_SPECIFIC then zclh.frame_ctrl:set_mfg_specific() end
  zclh.frame_ctrl:set_disable_default_response()
  local body = zcl_messages.ZclMessageBody({
    zcl_header = zclh, zcl_body = generic_body.GenericBody(payload),
  })
  device:send(messages.ZigbeeMessageTx({ address_header = address(device, cluster_id), body = body }))
end

-- Default Response for inbound frames that request one.
function M.ack(device, cluster_id, zclh)
  if zclh.frame_ctrl:is_disable_default_response_set() then return end
  local args = {
    cmd = data_types.ZCLCommandId(default_response.DefaultResponse.ID),
    seqno = data_types.Uint8(zclh.seqno.value),
  }
  local mfg = zclh.frame_ctrl:is_mfg_specific_set()
  if mfg and zclh.mfg_code ~= nil then
    args.mfg_code = data_types.validate_or_build_type(zclh.mfg_code.value, data_types.Uint16, "mfg_code")
  end
  local hdr = zcl_messages.ZclHeader(args)
  if mfg then hdr.frame_ctrl:set_mfg_specific() end
  hdr.frame_ctrl:set_disable_default_response()
  local body = zcl_messages.ZclMessageBody({
    zcl_header = hdr,
    zcl_body = default_response.DefaultResponse(data_types.Uint8(zclh.cmd.value), zcl_types.ZclStatus.SUCCESS),
  })
  device:send(messages.ZigbeeMessageTx({ address_header = address(device, cluster_id), body = body }))
end

return M
