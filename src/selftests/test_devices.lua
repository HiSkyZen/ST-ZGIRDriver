local ac = require "devices.ac"
local common = require "devices.common"
local manager = require "children.manager"
local protocols = require "ir.protocols"
local zosung = require "ir.codec_zosung"

local function bits_of(sig, from)
  local out = {}
  local t = sig.timings_us
  for i = from, #t - 1, 2 do out[#out + 1] = t[i + 1] > 1000 and 1 or 0 end
  return out
end

return {
  name = "devices",
  cases = {
    { "ac state keys and dimensionless constraints", function(t)
      t.eq(ac.state_key({ power = "off", mode = "cool" }), "off")
      t.eq(ac.state_key({ power = "on", mode = "cool", fan = "auto", swing = "off", temp = 24 }), "cool|auto|off|24")
      t.eq(ac.state_key({ power = "on", mode = "heat", fan = "low", swing = "on", temp = 22.5 }), "heat|low|on|22.5")
      local def = { device_type = "ac", commands = {}, ac = { constraints = { modes = { "cool" }, fan_modes = { "low" }, swing_modes = {} } } }
      local n = ac.normalize(def, { power = "on", mode = "cool", fan = "low", swing = "off", temp = 24 })
      t.eq(ac.state_key(n), "cool|low|-|24")
      local plain = { device_type = "ac", commands = {} }
      t.eq(#ac.constraints(plain).swing_modes, 2, "defaults when no explicit constraints")
    end },
    { "ac raw codebook resolve and off fallback", function(t)
      local z = zosung.encode(protocols.nec(1, 2))
      local def = { device_type = "ac", commands = { off = { z = z, carrier = 38000 } },
        ac = { codebook = { ["cool|auto|off|24"] = { z = z, carrier = 38000 } } } }
      t.ok(ac.resolve(def, { power = "on", mode = "cool", fan = "auto", swing = "off", temp = 24 }))
      t.ok(ac.resolve(def, { power = "off" }), "off via commands.off")
      local code, err = ac.resolve(def, { power = "on", mode = "heat", fan = "auto", swing = "off", temp = 30 })
      t.eq(code, nil); t.ok(err)
    end },
    { "key helpers", function(t)
      t.same(common.sorted_keys({ ok = 1, power = 1, zz_custom = 1, vol_up = 1 }), { "power", "vol_up", "ok", "zz_custom" })
      t.eq(common.sanitize_key("Vol Up!"), "vol_up")
      t.ok(common.valid_key("digit_0")); t.ok(not common.valid_key("Bad Key"))
    end },
    { "remote spec parsing", function(t)
      t.same(manager.parse_spec("tv:거실 TV"), { device_type = "tv", label = "거실 TV" })
      t.same(manager.parse_spec("aircon"), { device_type = "ac" })
      t.same(manager.parse_spec("builtin:lg-tv:LG"), { builtin = "builtin:lg-tv", label = "LG" })
      t.eq(manager.parse_spec("toaster"), nil)
    end },
    { "samsung32 repeats address byte", function(t)
      local s = protocols.samsung32(0x07, 0x02)
      local want = {}
      for _, byte in ipairs({ 0x07, 0x07, 0x02, 0xFD }) do
        for i = 0, 7 do want[#want + 1] = (byte >> i) & 1 end
      end
      t.same(bits_of(s, 3), want)
    end },
    { "rc5 starts with a mark and uses 889us halves", function(t)
      local s = assert(protocols.rc5(0, 12, false))
      for _, v in ipairs(s.timings_us) do t.ok(v == 889 or v == 1778, "half-bit multiple " .. v) end
    end },
  },
}
