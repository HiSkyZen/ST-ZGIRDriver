local util = require "util"
local signal = require "ir.signal"
local zosung = require "ir.codec_zosung"
local timings = require "analysis.timings"
local symbols = require "analysis.symbols"
local checksum = require "analysis.checksum"
local ac = require "analysis.ac_learner"

local C = { min_temp = 16, max_temp = 30, step = 1, modes = { "cool", "heat" },
  fan_modes = { "auto", "low", "high" }, swing_modes = { "off", "on" } }
local function state(temp, mode, fan, swing)
  return { power = "on", temp = temp or 24, mode = mode or "cool", fan = fan or "auto", swing = swing or "off",
    turbo = false, eco = false, sleep = false, display = true }
end
local function control(s)
  return (s.mode == "heat" and 1 or 0) + ({ auto = 0, low = 1, high = 2 })[s.fan] * 4 + (s.swing == "on" and 16 or 0)
end
local function flags(s)
  return (s.turbo and 1 or 0) + (s.eco and 2 or 0) + (s.sleep and 4 or 0) + (s.display ~= false and 8 or 0)
end
local function byte_bits(bytes, order)
  return assert(symbols.from_bytes(bytes, #bytes * 8, order))
end
local function sum_frame(bytes)
  local value = 0; for _, b in ipairs(bytes) do value = value + b end
  bytes[#bytes + 1] = value & 255
  return byte_bits(bytes, "lsb")
end
local function protocol(s, kind)
  if s.power == "off" then return { byte_bits({ 0x5A, 0xA5, 0, 0xFF }, "lsb") } end
  if kind == "lg" or kind == "gree" then
    local nibbles = { 8, 8, flags(s), s.mode == "heat" and 1 or 0,
      ({ auto = 0, low = 1, high = 2 })[s.fan] + (s.swing == "on" and 4 or 0), s.temp - 16 }
    if kind == "gree" then
      nibbles = { 1, 2, 3, flags(s), s.mode == "heat" and 1 or 0,
        ({ auto = 0, low = 1, high = 2 })[s.fan] + (s.swing == "on" and 4 or 0), 0, s.temp - 16,
        0, 0, 0, 0, 0, 0, 0 }
    end
    local total, bits = 0, {}
    for _, n in ipairs(nibbles) do total = total + n; for j = 3, 0, -1 do bits[#bits + 1] = (n >> j) & 1 end end
    if kind == "gree" then
      total = 10
      for i = 1, #nibbles, 2 do
        total = total + (i < #nibbles and nibbles[i] * 16 + nibbles[i + 1] or nibbles[i])
      end
    end
    for j = 3, 0, -1 do bits[#bits + 1] = ((total & 15) >> j) & 1 end
    return { bits }
  end
  local a = sum_frame({ 0xA0 + flags(s), control(s), s.temp - 16 })
  if kind == "multi" then return { sum_frame({ 0x11, control(s), s.temp - 16 }), sum_frame({ 0xD0 + flags(s), 0x2A, s.temp - 16 }) } end
  if kind == "samsung" then return { byte_bits({ 0xB2, 0x4D }, "lsb"), a, sum_frame({ 0xD0 + flags(s), 0x2A, s.temp - 16 }) } end
  if kind == "repeat" then return { a, util.deep_copy(a) } end
  return { a }
end
local function capture(s, kind, jitter, seed)
  local frames, out = protocol(s, kind), {}
  for f, bits in ipairs(frames) do
    out[#out + 1], out[#out + 2] = f == 2 and kind ~= "repeat" and 3500 or 9000, f == 2 and kind ~= "repeat" and 1750 or 4500
    for _, b in ipairs(bits) do
      out[#out + 1] = kind == "width" and (b == 1 and 1500 or 500) or 500
      out[#out + 1] = kind == "width" and 500 or (b == 1 and 1500 or 500)
    end
    out[#out + 1], out[#out + 2] = 500, f < #frames and (kind == "repeat" and 17500 or 29000) or 65535
  end
  if jitter then
    local x = seed or 7
    for i, v in ipairs(out) do
      x = (x * 1103515245 + 12345) & 0x7FFFFFFF
      out[i] = math.min(65535, math.floor(v * (1 + ((x % 301) - 150) / 1000) + 0.5))
    end
  end
  return signal.new(38000, out)
end
local function learn(t, kind)
  local learner, count = assert(ac.new({ constraints = C })), 0
  for i = 1, 15 do
    local req = learner:next_request()
    if not req then break end
    t.ok(type(req.prompt_ko) == "string" and #req.prompt_ko > 0)
    if req.state.power == "on" and count > 1 then
      local one_change = false
      for _, sample in ipairs(learner.samples) do
        if sample.state.power == "on" then
          local changed = 0
          for _, name in ipairs({ "mode", "temp", "fan", "swing", "turbo", "eco", "sleep", "display" }) do
            if req.state[name] ~= sample.state[name] then changed = changed + 1 end
          end
          if changed == 1 then one_change = true end
        end
      end
      t.ok(one_change, "request changes one variable")
    end
    t.ok(learner:add_sample(req.state, capture(req.state, kind, true, i * 17)))
    count = count + 1
  end
  t.eq(learner:next_request(), nil, "learning converges within 15 captures: " .. kind)
  local model, report = learner:analyze()
  t.ok(model, util.json_canonical(report))
  t.eq(report.status, "parametric", kind .. " promoted")
  t.ok(model.complete, kind .. " constraint coverage")
  t.ok(model.checksum_verified and model.training_verified)
  t.ok(type(util.json_canonical(model)) == "string")
  local unseen = state(23, "heat", "high", "on")
  unseen.turbo, unseen.eco, unseen.sleep, unseen.display = true, true, true, false
  local sig, err = ac.encode(model, unseen)
  t.ok(sig, err)
  t.ok(signal.validate(sig))
  local parts = assert(timings.split(sig))
  local expected = protocol(unseen, kind)
  t.eq(#parts, #expected)
  for f, part in ipairs(parts) do
    local decoded = assert(symbols.decode_frame(part.timings_us, model.frames[f].params))
    t.same(decoded.bits, expected[f], kind .. " unseen frame " .. f)
    t.ok(math.abs(model.frames[f].params.header[1] - (f == 2 and kind ~= "repeat" and 3500 or 9000)) <= 1400)
  end
  return learner, model, unseen
end

return { name = "analysis", cases = {
  { "single-frame byte sum with jitter", function(t) learn(t, "byte") end },
  { "LG 28-bit nibble sum with jitter", function(t)
    local _, model = learn(t, "lg"); t.eq(model.frames[1].params.bit_count, 28)
    t.eq(model.frames[1].checksum.width, 4)
  end },
  { "Gree-style 64-bit byte sum modulo 16", function(t)
    local _, model = learn(t, "gree"); t.eq(model.frames[1].params.bit_count, 64)
    t.eq(model.frames[1].checksum.width, 4)
  end },
  { "Daikin-style two frames with jitter", function(t)
    local _, model = learn(t, "multi"); t.eq(#model.frames, 2)
    t.ok(model.frames[1].gap_us > 24000 and model.frames[1].gap_us < 34000)
  end },
  { "Samsung-style three frames with jitter", function(t) learn(t, "samsung") end },
  { "Mitsubishi-style repeated frame", function(t)
    local _, model = learn(t, "repeat"); t.eq(model.frames[2].repeat_of, 1)
    t.near(model.frames[1].params.header[1], model.frames[2].params.header[1], 1400)
    local comparison = require "analysis.diff"
    local decoded = { bits = { 0, 1, 0, 1 }, state = state(), frames = {
      { bits = { 0, 1 }, timings_us = { 9000, 4500, 500, 500, 500, 1500, 500 } },
      { bits = { 0, 1 }, timings_us = { 3500, 1750, 500, 500, 500, 1500, 500 } } } }
    t.eq(assert(comparison.analyze({ decoded })).repeat_of[2], 0, "different headers are not identical repeats")
  end },
  { "pulse-width symbols", function(t) learn(t, "width") end },
  { "parametric hybrid raw and missing resolution", function(t)
    local learner, model, unseen = learn(t, "byte")
    local off = { power = "off" }
    local offz = assert(zosung.encode(capture(off, "byte")))
    local def = { constraints = C, model = model, learner = learner:export(), codebook = { off = { z = offz, carrier = 38000 } } }
    local sig, tier = ac.resolve(def, unseen); t.ok(sig); t.eq(tier, "parametric")
    local partial = util.deep_copy(model); partial.fields.mode = nil; partial.training_verified = false
    def.model = partial
    local hybrid_state = state(23, "cool", "auto", "off")
    sig, tier = ac.resolve(def, hybrid_state); t.ok(sig); t.eq(tier, "hybrid")
    local decoded = assert(symbols.decode_frame(assert(timings.split(sig))[1].timings_us, model.frames[1].params))
    t.same(decoded.bits, protocol(hybrid_state, "byte")[1])
    sig, tier = ac.resolve({ constraints = C, codebook = def.codebook }, off); t.ok(sig); t.eq(tier, "raw")
    sig, tier = ac.resolve({ constraints = C, codebook = {} }, unseen); t.eq(sig, nil); t.eq(tier, "no code for state")
    -- Corrupt analysis cannot hide an exact raw code.
    local key, z = ac.state_key(hybrid_state), assert(zosung.encode(capture(hybrid_state, "byte")))
    sig, tier = ac.resolve({ constraints = C, model = { schema = 1, checksum_verified = true, toggles = {} }, codebook = { [key] = { z = z, carrier = 38000 } } }, hybrid_state)
    t.ok(sig); t.eq(tier, "raw")
    sig, tier = ac.resolve({ model = { constraints = { step = 0 } }, codebook = { [key] = { z = z, carrier = 38000 } } }, hybrid_state)
    t.ok(sig); t.eq(tier, "raw")
    local bad = {}; bad.mode = bad
    sig, tier = ac.resolve({ constraints = C, learner = { samples = { { state = bad, sig = false } } }, codebook = { [key] = { z = z, carrier = 38000 } } }, hybrid_state)
    t.ok(sig); t.eq(tier, "raw")
  end },
  { "SmartIR promotion and random raw-only codebook", function(t)
    local book = {}
    for _, mode in ipairs(C.modes) do for _, fan in ipairs(C.fan_modes) do for _, swing in ipairs(C.swing_modes) do
      for temp = C.min_temp, C.max_temp do local s = state(temp, mode, fan, swing); book[ac.state_key(s)] = capture(s, "byte", true, temp * 9) end
    end end end
    book.off = capture({ power = "off" }, "byte")
    local learner = assert(ac.from_codebook(C, book))
    local model, report = learner:analyze(); t.ok(model); t.eq(report.status, "parametric")
    t.eq(report.sample_count, 181); t.ok(report.study_count <= 96)
    local s = state(22, "heat", "high", "on")
    local sig = assert(ac.encode(model, s))
    t.same(assert(symbols.decode_frame(assert(timings.split(sig))[1].timings_us, model.frames[1].params)).bits, protocol(s, "byte")[1])
    local random, x, compact = {}, 71, {}
    for _, temp in ipairs({ 16, 20, 24, 25, 30 }) do
      local bits = {}; for i = 1, 32 do x = (x * 1664525 + 1013904223) & 0xFFFFFFFF; bits[i] = (x >> 17) & 1 end
      local p = { encoding = "pulse_distance", header = { 9000, 4500 }, footer = { 500 }, zero = { 500, 500 }, one = { 500, 1500 }, bit_count = 32 }
      local a = assert(symbols.encode_bits(p, bits)); a[#a + 1] = 65535
      local key = ac.state_key(state(temp)); random[key] = signal.new(38000, a)
      compact[key] = { z = assert(zosung.encode(random[key])), carrier = 38000 }
    end
    local raw = assert(ac.from_codebook(C, random)); local m, r = raw:analyze()
    t.ok(not m or not m.training_verified); t.eq(r.status, "raw-only")
    local resolved, tier = ac.resolve({ model = m, constraints = C, learner = raw:export(), codebook = compact }, state(24))
    t.ok(resolved); t.eq(tier, "raw")
  end },
  { "confounded temperature requests an independent anchor", function(t)
    local learner = assert(ac.new({ constraints = C }))
    t.ok(learner:add_sample({ power = "off" }, capture({ power = "off" }, "byte")))
    t.ok(learner:add_sample(state(), capture(state(), "byte")))
    local confounded = state(25, "heat", "low", "on")
    t.ok(learner:add_sample(confounded, capture(confounded, "byte")))
    local req = assert(learner:next_request())
    t.same(req.state, state(25), "seen but confounded temperature must be isolated")
  end },
  { "export load and malformed input", function(t)
    local learner, model, unseen = learn(t, "byte")
    local exported = learner:export(); t.ok(util.json_canonical(exported))
    local loaded = assert(ac.load(exported)); local roundtrip = assert(loaded:analyze())
    t.same(ac.encode(roundtrip, unseen), ac.encode(model, unseen))
    local ok, value = pcall(ac.load, { schema = 1, samples = { false } }); t.ok(ok); t.eq(value, nil)
    ok, value = pcall(ac.encode, {}, {}); t.ok(ok); t.eq(value, nil)
    ok, value = pcall(ac.resolve, { model = false }, false); t.ok(ok); t.eq(value, nil)
    t.eq(learner:add_sample(state(), { carrier_hz = 38000, timings_us = { 1, 2 }, repeat_count = "bad" }), nil)
    t.eq(learner:add_sample(state(), { carrier_hz = 38000, timings_us = { 1, 0 } }), nil)
    t.eq(ac.new({ constraints = { step = 0 } }), nil)
    t.eq(ac.load({ schema = 1, constraints = C, samples = {}, raw_only = { "bad" } }), nil)
    local fieldmod = require "analysis.fields"
    t.eq(fieldmod.patch({ kind = "table", positions = { 1 }, values = { cool = {} } }, "cool"), nil)
    t.eq(fieldmod.patch({ kind = "table", positions = { 1.5 }, values = { cool = { 1 } } }, "cool"), nil)
    local simple = assert(ac.new({ constraints = { min_temp = 24, max_temp = 24, modes = { "dry" }, fan_modes = {}, swing_modes = {} } }))
    local no_dimensions = { power = "on", mode = "dry", temp = 24 }
    t.ok(simple:add_sample(no_dimensions, capture(state(), "byte")))
    local raw, tier = ac.resolve({ model = { constraints = { step = 0 } }, learner = simple:export() }, no_dimensions)
    t.ok(raw); t.eq(tier, "raw")
    t.eq(ac.state_key({ power = "off" }), "off")
    t.eq(ac.state_key({ mode = "dry", temp = 22.5 }), "dry|-|-|22.5")
    local cyclic = {}; cyclic.samples = cyclic; t.eq(ac.load(cyclic), nil)
    for _, call in ipairs({ function() return checksum.read({}, nil, nil) end,
      function() return symbols.encode_bits({ encoding = "manchester", header = {}, footer = {}, bit_count = 1 }, { 1 }) end,
      function() return require("analysis.fields").patch({ kind = "linear", regions = { false } }, 24) end }) do
      local safe, result = pcall(call); t.ok(safe); t.eq(result, nil)
    end
  end },
  { "checksum ambiguity needs combined evidence", function(t)
    local checks = {}
    for _, bytes in ipairs({ { 0, 0, 0 }, { 1, 0, 1 }, { 0, 1, 1 } }) do checks[#checks + 1] = byte_bits(bytes, "lsb") end
    local candidate = assert(checksum.infer(checks)); t.ok(candidate.verified)
    local bits = byte_bits({ 1, 1, 0 }, "lsb")
    local ok, err = checksum.apply(candidate, bits); t.eq(ok, nil); t.eq(err, "checksum ambiguous")
    checks[#checks + 1] = byte_bits({ 1, 1, 2 }, "lsb")
    candidate = assert(checksum.infer(checks)); t.ok(checksum.apply(candidate, bits))
    t.eq(symbols.to_bytes(bits, "lsb")[3], 2)
  end },
  { "bit-reversed byte sum and complement", function(t)
    local function reverse(v)
      local out = 0; for i = 0, 7 do out = (out << 1) | ((v >> i) & 1) end
      return out
    end
    local captures = {}
    for _, a in ipairs({ 1, 7, 32, 125, 203, 255 }) do
      local b = (a * 17 + 0x36) & 255
      local sum = (reverse(a) + reverse(b)) & 255
      captures[#captures + 1] = byte_bits({ a, b, reverse(sum) }, "lsb")
    end
    local check = assert(checksum.infer(captures)); t.ok(check.verified)
    local value = (reverse(19) + reverse(0xA2)) & 255
    local bits = byte_bits({ 19, 0xA2, 0 }, "lsb"); t.ok(checksum.apply(check, bits))
    t.eq(symbols.to_bytes(bits, "lsb")[3], reverse(value))
    captures = {}
    for _, command in ipairs({ 0, 1, 17, 49, 128 }) do captures[#captures + 1] = byte_bits({ 0x34, 0xCB, command, (~command) & 255 }, "lsb") end
    check = assert(checksum.infer(captures)); t.ok(check.verified)
    bits = byte_bits({ 0x34, 0xCB, 93, 0 }, "lsb"); t.ok(checksum.apply(check, bits))
    t.eq(symbols.to_bytes(bits, "lsb")[4], (~93) & 255)
  end },
  { "same-state toggle stays raw-resolvable", function(t)
    local learner = assert(ac.new({ constraints = C }))
    local s = state(24)
    for i, temp in ipairs({ 24, 25, 16, 30 }) do t.ok(learner:add_sample(state(temp), capture(state(temp), "byte"))) end
    local alternate = state(24); alternate.turbo = true
    t.ok(learner:add_sample(s, capture(alternate, "byte")))
    local model = assert(learner:analyze()); t.ok(#model.toggles > 0); t.eq(model.fields.sequence.kind, "toggle")
    t.eq(ac.encode(model, state(23)), nil)
    local sig, tier = ac.resolve({ constraints = C, model = model, learner = learner:export() }, s)
    t.ok(sig); t.eq(tier, "raw")
  end },
  { "split jittered headers and canonical repeat metadata", function(t)
    local s = capture(state(), "byte")
    s.timings_us[2] = 5175
    local parts = assert(timings.split(s)); t.eq(#parts, 1); t.eq(parts[1].gap_us, 65535)
    local repeated = signal.new(38000, { 9000, 4500, 500, 500, 500, 1500, 500, 500, 500, 1500, 500 },
      { repeat_timings_us = { 9000, 4500, 500, 500, 500, 1500, 500, 500, 500, 1500, 500 }, repeat_count = 2 })
    parts = assert(timings.split(repeated)); t.eq(#parts, 3); t.eq(parts[1].gap_us, 40000)
    local short = signal.new(38000, capture(state(), "byte").timings_us,
      { repeat_timings_us = { 9000, 2250, 500 }, repeat_count = 2 })
    parts = assert(timings.split(short)); t.eq(#parts, 3); t.eq(#parts[2].timings_us, 3)
    local clusters = assert(timings.cluster({ 375, 500, 625, 1125, 1500, 1875 })); t.eq(#clusters, 2)
  end },
} }
