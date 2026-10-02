-- ZG-IR01 native key_code: base64 of a Broadlink IR packet.
--
-- Verified on hardware (firmware 23062026): learned codes arrive as
--   0x26 <repeat> <len lo> <len hi> <pulses...>
-- with pulses in Broadlink ticks (8192/269 us; 0x00 hi lo for values > 255),
-- `len` counting the whole buffer including the 4-byte header, and no
-- 0x0d 0x05 terminator or padding.  Replaying such a code works, so generated
-- codes use exactly the same layout.
--
-- decode() also accepts standard Broadlink packets and Tuya-LZ (TS1201)
-- codes so stored/imported data from either family can be read back.
local util = require "util"
local signal = require "ir.signal"
local broadlink = require "ir.codec_broadlink"
local zosung = require "ir.codec_zosung"

local M = {}

M.TICK_US = 8192 / 269

function M.encode_packet(sig)
  local ok, err = signal.validate(sig)
  if not ok then return nil, err end
  local t = signal.flatten(sig, math.floor(0xFFFF * M.TICK_US))
  local parts = {}
  for i = 1, #t do
    local ticks = math.floor(t[i] / M.TICK_US + 0.5)
    if ticks < 1 then ticks = 1 end
    if ticks > 0xFFFF then ticks = 0xFFFF end
    if ticks < 256 then
      parts[#parts + 1] = string.char(ticks)
    else
      parts[#parts + 1] = string.char(0, ticks >> 8, ticks & 0xFF)
    end
  end
  local payload = table.concat(parts)
  local total = 4 + #payload
  if total > 0xFFFF then return nil, "signal too long" end
  return string.char(0x26, 0, total & 0xFF, total >> 8) .. payload
end

function M.encode(sig)
  local packet, err = M.encode_packet(sig)
  if not packet then return nil, err end
  return util.b64_encode(packet)
end

function M.decode(b64, carrier_hz)
  local bytes, err = util.b64_decode(b64)
  if not bytes then return nil, err end
  if bytes:byte(1) == 0x26 then
    local sig
    sig, err = broadlink.decode(bytes)
    if sig then
      sig.carrier_hz = math.tointeger(carrier_hz or 0) or 0
      if sig.carrier_hz == 0 then sig.carrier_hz = signal.DEFAULT_CARRIER end
      sig.source = { format = "native" }
      return sig
    end
  end
  local zsig = zosung.decode(b64, carrier_hz)
  if zsig then return zsig end
  return nil, err or "not a native/Broadlink/Tuya code"
end

function M.looks_like(b64)
  if not util.is_b64(b64) then return false end
  return M.decode(b64) ~= nil
end

return M
