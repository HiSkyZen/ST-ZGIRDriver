local protocols = require "ir.protocols"
local codec = require "ir.native"
local M = {}

local entries = {
  ["builtin:lg-tv"] = { name = "LG TV", deviceType = "tv", protocol = "nec", address = 0x04, commands = {
    power=0x08, vol_up=0x02, vol_down=0x03, mute=0x09, ch_up=0x00, ch_down=0x01, input=0x0B,
    digit_0=0x10, digit_1=0x11, digit_2=0x12, digit_3=0x13, digit_4=0x14, digit_5=0x15,
    digit_6=0x16, digit_7=0x17, digit_8=0x18, digit_9=0x19, up=0x40, down=0x41, left=0x07,
    right=0x06, ok=0x44, back=0x28, home=0x7C, menu=0x43, exit=0x5B, red=0x72, green=0x71,
    yellow=0x63, blue=0x61, play=0xB0, pause=0xBA, stop=0xB1, rewind=0x8F,
    fast_forward=0x8E, power_on=0xC4, power_off=0xC5, info=0xAA,
  } },
  ["builtin:samsung-tv"] = { name = "Samsung TV", deviceType = "tv", protocol = "samsung32", address = 0x07, commands = {
    power=0x02, vol_up=0x07, vol_down=0x0B, mute=0x0F, ch_up=0x12, ch_down=0x10, input=0x01,
    digit_1=0x04, digit_2=0x05, digit_3=0x06, digit_4=0x08, digit_5=0x09, digit_6=0x0A,
    digit_7=0x0C, digit_8=0x0D, digit_9=0x0E, digit_0=0x11, up=0x60, down=0x61,
    left=0x65, right=0x62, ok=0x68, back=0x58, home=0x79, menu=0x1A, exit=0x2D,
    -- Discrete power codes vary by Samsung generation; these are common service mappings.
    power_off=0x98, power_on=0x99,
  } },
  ["builtin:sony-tv"] = { name = "Sony TV", deviceType = "tv", protocol = "sony_sirc", address = 1, bits = 12, commands = {
    power=21, vol_up=18, vol_down=19, mute=20, ch_up=16, ch_down=17,
    digit_1=0, digit_2=1, digit_3=2, digit_4=3, digit_5=4, digit_6=5,
    digit_7=6, digit_8=7, digit_9=8, digit_0=9, input=37,
  } },
}

function M.list()
  local out = {}
  for id, e in pairs(entries) do out[#out + 1] = { id = id, name = e.name, deviceType = e.deviceType } end
  table.sort(out, function(a, b) return a.id < b.id end)
  return out
end

function M.get(id)
  local e = entries[id]
  if not e then return nil end
  local def = { schema = 1, device_type = e.deviceType, meta = { name = e.name, manufacturer = e.name:match("^(%S+)"), source = "builtin" }, commands = {}, active = false }
  for key, code in pairs(e.commands) do
    local spec = { protocol = e.protocol, address = e.address, command = code, bits = e.bits }
    if e.protocol == "nec32" then spec.code = code end
    local sig = protocols.build(spec)
    if not sig then return nil end
    local z, err = codec.encode(sig)
    if not z then return nil, err end
    def.commands[key] = { z = z, carrier = sig.carrier_hz }
  end
  return def
end

return M
