local signal = require "ir.signal"
local M = {}

local function bits_lsb(value, count)
  local bits = {}
  for i = 0, count - 1 do bits[#bits + 1] = (value >> i) & 1 end
  return bits
end

local function bits_msb(value, count)
  local bits = {}
  for i = count - 1, 0, -1 do bits[#bits + 1] = (value >> i) & 1 end
  return bits
end

local function nec_frame(bits)
  local t = { 9000, 4500 }
  for _, bit in ipairs(bits) do
    t[#t + 1] = 560
    t[#t + 1] = bit == 1 and 1690 or 560
  end
  t[#t + 1] = 560
  return t
end

local function checked(carrier, timings, opts)
  local sig = signal.new(carrier, timings, opts)
  local ok, err = signal.validate(sig)
  if not ok then return nil, err end
  return sig
end

function M.nec(addr, cmd, opts)
  opts = opts or {}
  if type(addr) ~= "number" or addr < 0 or addr > 0xFFFF or addr % 1 ~= 0 or
    type(cmd) ~= "number" or cmd < 0 or cmd > 255 or cmd % 1 ~= 0 then return nil, "invalid NEC address or command" end
  local a = {}
  if addr <= 0xFF then
    a = { addr, (~addr) & 0xFF }
  else
    a = { addr & 0xFF, (addr >> 8) & 0xFF }
  end
  a[#a + 1] = cmd
  a[#a + 1] = (~cmd) & 0xFF
  local bits = {}
  for _, byte in ipairs(a) do for _, bit in ipairs(bits_lsb(byte, 8)) do bits[#bits + 1] = bit end end
  local repeat_frame, count
  count = opts.repeat_count or (opts["repeat"] and 1) or 0
  if type(count) ~= "number" or count < 0 or count > 10 or count % 1 ~= 0 then return nil, "invalid NEC repeat_count" end
  if count > 0 then repeat_frame = { 9000, 2250, 560 } end
  return checked(opts.carrier_hz or 38000, nec_frame(bits), { repeat_timings_us = repeat_frame, repeat_count = count })
end

function M.nec32(code)
  if type(code) ~= "number" or code < 0 or code > 0xFFFFFFFF or code % 1 ~= 0 then return nil, "invalid NEC32 code" end
  -- LG remote words are conventionally written in wire order (MSB first).
  local t = nec_frame(bits_msb(code, 32))
  return checked(38000, t)
end

function M.samsung32(addr, cmd)
  if type(addr) ~= "number" or addr < 0 or addr > 255 or addr % 1 ~= 0 or
    type(cmd) ~= "number" or cmd < 0 or cmd > 255 or cmd % 1 ~= 0 then return nil, "invalid Samsung address or command" end
  -- Samsung32 repeats the address byte (E0E0xxxx), unlike NEC's inverted address.
  local bytes = { addr, addr, cmd, (~cmd) & 0xFF }
  local bits = {}
  for _, byte in ipairs(bytes) do for _, bit in ipairs(bits_lsb(byte, 8)) do bits[#bits + 1] = bit end end
  local t = { 4500, 4500 }
  for _, bit in ipairs(bits) do t[#t + 1] = 560; t[#t + 1] = bit == 1 and 1690 or 560 end
  t[#t + 1] = 560
  return checked(38000, t)
end

function M.sony_sirc(cmd, addr, bits)
  bits = bits or 12
  if bits ~= 12 and bits ~= 15 and bits ~= 20 then return nil, "SIRC bits must be 12, 15, or 20" end
  local addr_bits = bits - 7
  if type(cmd) ~= "number" or cmd < 0 or cmd >= 2^7 or cmd % 1 ~= 0 or
    type(addr) ~= "number" or addr < 0 or addr >= 2^addr_bits or addr % 1 ~= 0 then return nil, "invalid SIRC address or command" end
  local frame = { 2400, 600 }
  local all = bits_lsb(cmd, 7)
  for _, bit in ipairs(bits_lsb(addr, addr_bits)) do all[#all + 1] = bit end
  for _, bit in ipairs(all) do
    frame[#frame + 1] = bit == 1 and 1200 or 600
    frame[#frame + 1] = 600
  end
  -- Each complete frame occupies less than 45 ms. The trailing space establishes
  -- the specified 45 ms frame period, including when the frame is repeated.
  local duration = 0
  for _, us in ipairs(frame) do duration = duration + us end
  frame[#frame] = frame[#frame] + (45000 - duration)
  local opts = { repeat_timings_us = frame, repeat_count = 2 }
  return checked(40000, frame, opts)
end

local function rc5_bits(addr, cmd, toggle)
  local field = cmd < 64 and 1 or 0
  local bits = { 1, field, toggle and 1 or 0 }
  for _, b in ipairs(bits_msb(addr, 5)) do bits[#bits + 1] = b end
  for _, b in ipairs(bits_msb(cmd & 0x3F, 6)) do bits[#bits + 1] = b end
  return bits
end

function M.rc5(addr, cmd, toggle)
  if type(addr) ~= "number" or addr < 0 or addr > 31 or addr % 1 ~= 0 or
    type(cmd) ~= "number" or cmd < 0 or cmd > 127 or cmd % 1 ~= 0 then return nil, "invalid RC5 address or command" end
  local halves = {}
  for _, bit in ipairs(rc5_bits(addr, cmd, toggle)) do
    -- RC5 Manchester: 1 = space->mark, 0 = mark->space
    if bit == 1 then halves[#halves + 1] = 0; halves[#halves + 1] = 1
    else halves[#halves + 1] = 1; halves[#halves + 1] = 0 end
  end
  -- the leading start-bit half is idle (space); trailing idle is not encoded
  while halves[1] == 0 do table.remove(halves, 1) end
  while halves[#halves] == 0 do halves[#halves] = nil end
  local timings, level, count = {}, halves[1], 0
  for _, half in ipairs(halves) do
    if half == level then count = count + 1
    else timings[#timings + 1] = count * 889; count = 1; level = half end
  end
  timings[#timings + 1] = count * 889
  if halves[1] == 0 then return nil, "RC5 frame must start with mark" end
  return checked(36000, timings)
end

function M.build(spec)
  if type(spec) ~= "table" then return nil, "protocol spec must be a table" end
  local p = spec.protocol
  if p == "nec" then return M.nec(spec.address, spec.command, spec)
  elseif p == "nec32" then return M.nec32(spec.code)
  elseif p == "samsung32" then return M.samsung32(spec.address, spec.command)
  elseif p == "sony_sirc" or p == "sirc" then return M.sony_sirc(spec.command, spec.address, spec.bits)
  elseif p == "rc5" then return M.rc5(spec.address, spec.command, spec.toggle)
  end
  return nil, "unsupported protocol " .. tostring(p)
end

return M
