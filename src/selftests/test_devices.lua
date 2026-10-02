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
    { "smartir climate keeps constraints through from_import_result", function(t)
      local frame = "[3000,3000,500,1500,500,500,500,500]"
      local text = '{"manufacturer":"TestCo","commandsEncoding":"Raw","minTemperature":24,"maxTemperature":26,' ..
        '"precision":1,"operationModes":["cool"],"fanModes":["auto","low"],"commands":{"off":' .. frame ..
        ',"cool":{"auto":{"24":' .. frame .. '},"low":{"24":' .. frame .. '}}}}'
      local result = assert(require("import.detect").parse_any(text))
      t.eq(result.smartir.constraints.min_temp, 24, "parser min_temp")
      t.eq(#result.smartir.constraints.fan_modes, 2, "parser fan modes")
      local def = assert(require("packs.import").from_import_result(result, "ac", result.meta))
      t.eq(def.ac.constraints.min_temp, 24, "def min_temp")
      t.eq(#def.ac.constraints.fan_modes, 2, "def fan modes")
      t.ok(def.ac.codebook["cool|low|-|24"], "codebook key")
    end },
    { "native codec matches device-learned layout", function(t)
      local native = require "ir.native"
      -- learned from a physical NEC remote by ZG-IR01 fw 23062026 (2026-10-02)
      local learned = "JgBhAAABGY0REhESETUREhERERIREhESEDURNRESETQRNBE1ETURNBESERIQEhA1ERIREhESERIRNRE1ETQREhE0EDUQNRE0EQAE4wABGEYRAAvLAAEZRhAAC8sAARlGEQ=="
      local sig = assert(native.decode(learned))
      t.near(sig.timings_us[1], 8557, 40, "header mark")
      t.near(sig.timings_us[2], 4293, 40, "header space")
      t.eq(native.encode(sig), learned, "lossless re-encode")
      local nec = require("ir.protocols").nec(0x04, 0x08)
      local back = assert(native.decode(native.encode(nec)))
      t.ok(require("ir.signal").timings_close(nec.timings_us, back.timings_us, 0.03), "NEC round trip")
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
