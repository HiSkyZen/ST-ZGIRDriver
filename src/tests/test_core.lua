local util = require "util"
local signal = require "ir.signal"
local zosung = require "ir.codec_zosung"

local function nec_like()
  local t = { 9000, 4500 }
  for i = 1, 32 do
    t[#t + 1] = 560
    t[#t + 1] = (i % 3 == 0) and 1690 or 560
  end
  t[#t + 1] = 560
  return signal.new(38000, t)
end

return {
  name = "core",
  cases = {
    { "b64 roundtrip", function(t)
      for _, s in ipairs({ "", "a", "ab", "abc", "abcd", "\0\255\1\254" }) do
        if #s > 0 then t.eq(util.b64_decode(util.b64_encode(s)), s, "rt " .. #s) end
      end
      t.eq(util.b64_encode("Man"), "TWFu")
      t.eq(util.b64_encode("Ma"), "TWE=")
      t.eq(util.b64_decode("TWE="), "Ma")
      t.eq(util.b64_decode("@@@@"), nil)
    end },
    { "hex and fnv", function(t)
      t.eq(util.hex_decode("0a ff"), "\10\255")
      t.eq(util.hex_encode("\10\255"), "0aff")
      t.eq(util.fnv1a32(""), "811c9dc5")
      t.eq(util.fnv1a32("a"), "e40c292c")
    end },
    { "split and json_canonical", function(t)
      t.same(util.split("a,,b", ","), { "a", "", "b" })
      t.eq(util.json_canonical({ b = 1, a = { 1, 2 }, c = "x\"" }), '{"a":[1,2],"b":1,"c":"x\\""}')
      t.eq(util.json_canonical({}), "[]")
      t.eq(util.json_canonical(2.0), "2")
    end },
    { "lz decompress literal and backref", function(t)
      -- literal "ab" then back-reference len 4 dist 2 -> "ababab"
      local stream = string.char(1) .. "ab" .. string.char((2 << 5) | 0, 1)
      t.eq(zosung.decompress(stream), "ababab")
      -- long match uses the extension byte
      local long = string.char(0) .. "x" .. string.char((7 << 5), 10, 0)
      t.eq(zosung.decompress(long), string.rep("x", 1 + 19))
      t.eq(zosung.decompress(string.char(5) .. "ab"), nil, "truncated")
    end },
    { "lz compress roundtrip", function(t)
      local inputs = { "", "a", "abcabcabcabcabc", string.rep("\1\2", 300), string.rep("q", 1000) }
      local rnd = {}
      local x = 7
      for i = 1, 700 do x = (x * 1103515245 + 12345) & 0x7FFFFFFF; rnd[i] = string.char(x % 7) end
      inputs[#inputs + 1] = table.concat(rnd)
      for idx, s in ipairs(inputs) do
        t.eq(zosung.decompress(zosung.compress(s)), s, "rt input " .. idx)
      end
      t.ok(#zosung.compress(string.rep("q", 1000)) < 40, "compresses runs")
    end },
    { "signal validate/flatten", function(t)
      local s = signal.new(38000, { 100, 200, 300 }, { repeat_timings_us = { 9000, 2250, 560 }, repeat_count = 2 })
      t.ok(signal.validate(s))
      t.same(signal.flatten(s), { 100, 200, 300, 40000, 9000, 2250, 560, 40000, 9000, 2250, 560 })
      t.eq(signal.validate(signal.new(38000, {})), nil)
      local big = signal.new(38000, { 500, 100000 })
      t.same(signal.flatten(big), { 500, 65535 })
    end },
    { "zosung encode/decode roundtrip", function(t)
      local s = nec_like()
      local code = assert(zosung.encode(s))
      local back = assert(zosung.decode(code))
      t.same(back.timings_us, s.timings_us)
      t.ok(zosung.looks_like(code))
      t.ok(not zosung.looks_like("JgBGAJKVEjYSNhI2EhESERIREhESERI2EjYSNhIREhESERIR"), "broadlink is not zosung")
    end },
  },
}
