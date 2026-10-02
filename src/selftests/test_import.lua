local signal = require "ir.signal"
local broadlink_codec = require "ir.codec_broadlink"
local fingerprint = require "ir.fingerprint"
local pronto = require "import.pronto"
local globalcache = require "import.globalcache"
local lirc = require "import.lirc"
local smartir = require "import.smartir"
local detect = require "import.detect"
local util = require "util"
local codec_zosung = require "ir.codec_zosung"

local M = { name = "import", cases = {} }
local function case(name, fn) M.cases[#M.cases + 1] = { name, fn } end

local function packet_hex()
  return "2602040010200d05"
end

case("Pronto computes carrier and timings", function(t)
  local p, err = pronto.parse("0000 006D 0002 0000 0010 0020 0010 0030")
  t.ok(p, err)
  t.eq(p.format, "pronto")
  local s = p.signals[1].sig
  t.eq(s.carrier_hz, math.floor(1000000 / (0x6D * 0.241246) + 0.5))
  t.near(s.timings_us[1], 0x10 * 0x6D * 0.241246, 1)
  local encoded = pronto.encode(s)
  local round = pronto.parse(encoded)
  t.ok(round)
  t.ok(signal.timings_close(s.timings_us, round.signals[1].sig.timings_us, 0.01))
  local unsupported = pronto.parse("5000 0000 0000 0000")
  t.eq(unsupported, nil)
end)

case("Broadlink byte packet and codec round trip", function(t)
  local bytes = util.hex_decode(packet_hex())
  local s, err = broadlink_codec.decode(bytes)
  t.ok(s, err)
  t.eq(s.timings_us[1], math.floor(16 * 8192 / 269 + 0.5))
  t.eq(s.repeat_count, 2)
  t.same(s.repeat_timings_us, s.timings_us)
  t.ok(broadlink_codec.looks_like(bytes))
  local encoded = broadlink_codec.encode(s)
  local again = broadlink_codec.decode(encoded)
  t.ok(again)
  for i = 1, #s.timings_us do
    t.near(again.timings_us[i], s.timings_us[i], math.ceil(8192/269))
  end
  t.eq(broadlink_codec.decode(string.char(0xB2,0,4,0,1,2)), nil)
end)

case("GlobalCache sendir carrier-cycle conversion", function(t)
  local p, err = globalcache.parse("sendir,1:1,1,38000,2,3,340,170,340,170")
  t.ok(p, err)
  local s = p.signals[1].sig
  t.eq(s.carrier_hz, 38000)
  t.near(s.timings_us[1], 340 * 1000000 / 38000, 1)
  t.eq(s.repeat_count, 1)
  t.eq(#s.repeat_timings_us, 2)
  t.ok(signal.validate(s))
end)

case("LIRC maps key names and raw durations", function(t)
  local text = [[begin remote
 name sample
 frequency 38000
 begin raw_codes
 name KEY_POWER
 9000 4500 560 560
 name KEY_VOLUMEUP
 9000 4500 560 560
 end raw_codes
 end remote]]
  local p, err = lirc.parse(text)
  t.ok(p, err)
  t.eq(#p.signals, 2)
  t.eq(p.signals[1].name, "power")
  t.eq(p.signals[2].name, "vol_up")
  t.ok(signal.validate(p.signals[2].sig))
  local decoded = lirc.parse("begin remote\n name x\n protocol NEC\n end remote")
  t.eq(decoded, nil)
end)

case("SmartIR climate flat and swing nesting", function(t)
  local flat = [[{"type":"climate","commandsEncoding":"Raw","commands":{"off":[9000,4500],"cool":{"mid":{"24":[9000,4500,560,560]}}},"operation_modes":["cool"],"fan_modes":["mid"]}]]
  local p, err = smartir.parse(flat)
  t.ok(p, err)
  t.eq(p.smartir.codebook["cool|medium|-|24"].timings_us[1], 9000)
  t.ok(p.smartir.commands.off)
  local nested = [[{"type":"climate","commandsEncoding":"Raw","commands":{"heat":{"high":{"vertical":{"22":[9000,4500,560,560]}}}},"operation_modes":["heat"],"fan_modes":["high"],"swing_modes":["vertical"]}]]
  local q, e = smartir.parse(nested)
  t.ok(q, e)
  t.ok(q.smartir.codebook["heat|high|vertical|22"])
end)

case("SmartIR media source mappings", function(t)
  local raw_code = "[9000,4500,560,560]"
  local p, err = smartir.parse([[{"type":"media_player","commandsEncoding":"Raw","commands":{"on":]] .. raw_code .. [[,"off":]] .. raw_code .. [[,"volumeUp":]] .. raw_code .. [[,"sources":{"HDMI 1":]] .. raw_code .. [[}}}]])
  t.ok(p, err)
  t.ok(p.smartir.commands.power_on)
  t.ok(p.smartir.commands.vol_up)
  t.ok(p.smartir.commands.source_hdmi_1)
end)

case("fingerprint survives timing jitter but distinguishes commands", function(t)
  local base = { carrier_hz = 38000, timings_us = {9000,4500,560,560,560,1690,560,560,560,1690,560,560} }
  local jitter = { carrier_hz = 40000, timings_us = {} }
  local seed = 17
  for i, v in ipairs(base.timings_us) do
    seed = (seed * 48271) % 2147483647
    local factor = 0.8 + (seed % 401) / 1000
    jitter.timings_us[i] = math.floor(v * factor + 0.5)
  end
  local other = { carrier_hz = 38000, timings_us = {9000,4500,560,1690,560,560,560,1690,560,560,560,560} }
  t.eq(fingerprint.same(base, jitter), true)
  t.eq(fingerprint.same(base, other), false)
  local gap_a = { carrier_hz = 38000, timings_us = {9000,4500,560,560,560,1690,560,560,560,1690,560,30000} }
  local gap_b = { carrier_hz = 40000, timings_us = {9000,4500,560,560,560,1690,560,560,560,1690,560,70000} }
  t.eq(fingerprint.same(gap_a, gap_b), true)
  t.ok(fingerprint.fingerprint(base):match("^fp%-%x%x%x%x%x%x%x%x$"))
end)

case("detect formats and rejects garbage", function(t)
  local packet = util.hex_decode(packet_hex())
  local native = codec_zosung.encode({ carrier_hz = 38000, timings_us = {9000,4500,560,560} })
  local climate = [[{"type":"climate","commandsEncoding":"Raw","commands":{"cool":{"auto":{"24":[9000,4500]}}}}]]
  t.eq(detect.detect("0000 006D 0002 0000 0010 0020 0010 0030"), "pronto")
  t.eq(detect.detect(packet_hex()), "broadlink_hex")
  t.eq(detect.detect(util.b64_encode(packet)), "broadlink_b64")
  t.eq(detect.detect(native), "zosung")
  t.eq(detect.detect("sendir,1:1,1,38000,1,1,340,170"), "globalcache")
  t.eq(detect.detect("begin remote\nend remote"), "lirc")
  t.eq(detect.detect("[9000,4500,560,560]"), "raw")
  t.eq(detect.detect("freq=38000 9000 4500"), "raw")
  t.eq(detect.detect("carrier:38000,+9000,-4500"), "raw")
  t.eq(detect.detect(climate), "smartir")
  t.eq(detect.detect([[{"format":"stir"}]]), "stir")
  t.eq(detect.detect("garbage"), nil)
  local named = detect.parse_any("power: 0000 006D 0002 0000 0010 0020 0010 0030\nvol_up=9000 4500")
  t.ok(named)
  t.eq(named.signals[1].name, "power")
  t.eq(named.signals[2].name, "vol_up")
  local smart = detect.parse_any(climate)
  t.ok(smart and smart.smartir)
  local _, err = detect.parse_any([[{"format":"stir"}]])
  t.ok(err and err:find("packs.import", 1, true))
end)

return M
