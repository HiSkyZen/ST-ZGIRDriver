-- Wire-order bits are always retained; byte views never pad emitted frames.
local timings = require "analysis.timings"
local M = {}

function M.to_bytes(bits, order)
  if type(bits) ~= "table" then return nil, "invalid bits" end
  local out = {}
  for start = 1, #bits, 8 do
    local value = 0
    for j = 0, math.min(7, #bits - start) do
      local bit = bits[start + j]
      if bit ~= 0 and bit ~= 1 then return nil, "invalid bit" end
      value = value | (bit << (order == "msb" and (7 - j) or j))
    end
    out[#out + 1] = value
  end
  return out
end

function M.from_bytes(bytes, count, order)
  if type(bytes) ~= "table" or math.type(count) ~= "integer" or count < 0 or count > #bytes * 8 then
    return nil, "invalid bytes or bit count"
  end
  local out = {}
  for i = 1, count do
    local b = bytes[(i - 1) // 8 + 1]
    if math.type(b) ~= "integer" or b < 0 or b > 255 then return nil, "invalid byte" end
    local shift = (i - 1) % 8
    out[i] = (b >> (order == "msb" and 7 - shift or shift)) & 1
  end
  return out
end

local function close(v, expected)
  return type(v) == "number" and type(expected) == "number" and expected > 0
    and math.abs(v - expected) <= expected * 0.36 + 35
end

local function payload(list, p)
  if type(list) ~= "table" or type(p) ~= "table" or type(p.header) ~= "table" or type(p.footer) ~= "table" then
    return nil, "invalid frame parameters"
  end
  local h, f = #p.header, #p.footer
  if #list < h + f then return nil, "short frame" end
  for i, v in ipairs(p.header) do if not close(list[i], v) then return nil, "header mismatch" end end
  for i, v in ipairs(p.footer) do if not close(list[#list - f + i], v) then return nil, "footer mismatch" end end
  local out = {}
  for i = h + 1, #list - f do out[#out + 1] = list[i] end
  return out
end

function M.decode_frame(list, p)
  local data, err = payload(list, p)
  if not data then return nil, err end
  local bits = {}
  if p.encoding == "literal" then
    if #data ~= 0 then return nil, "literal frame mismatch" end
  elseif p.encoding == "manchester" then
    if type(p.unit_us) ~= "number" or p.unit_us <= 0 then return nil, "invalid Manchester unit" end
    local halves = {}
    for i, v in ipairs(data) do
      local n = math.floor(v / p.unit_us + 0.5)
      if (n ~= 1 and n ~= 2) or not close(v, n * p.unit_us) then return nil, "invalid Manchester run" end
      for _ = 1, n do halves[#halves + 1] = i % 2 end
    end
    if #halves % 2 ~= 0 then return nil, "incomplete Manchester symbol" end
    for i = 1, #halves, 2 do
      if halves[i] == halves[i + 1] then return nil, "invalid Manchester symbol" end
      bits[#bits + 1] = halves[i]
    end
  else
    if p.encoding ~= "pulse_distance" and p.encoding ~= "pulse_width" then return nil, "unknown encoding" end
    if #data % 2 ~= 0 or type(p.zero) ~= "table" or type(p.one) ~= "table" then return nil, "invalid pulse pairs" end
    for i = 1, #data, 2 do
      local best, distance
      for bit = 0, 1 do
        local s = bit == 0 and p.zero or p.one
        if not close(data[i], s[1]) or not close(data[i + 1], s[2]) then
          -- Try the other symbol.
        else
          local d = math.abs(data[i] - s[1]) / s[1] + math.abs(data[i + 1] - s[2]) / s[2]
          if not distance or d < distance then best, distance = bit, d end
        end
      end
      if best == nil then return nil, "unknown pulse symbol" end
      bits[#bits + 1] = best
    end
  end
  if #bits ~= p.bit_count then return nil, "bit count mismatch" end
  return { bits = bits, bytes_lsb = M.to_bytes(bits, "lsb"), bytes_msb = M.to_bytes(bits, "msb") }
end

local function learn_impl(frames)
  if type(frames) ~= "table" or #frames == 0 then return nil, "no frames" end
  local lists = {}
  for i, frame in ipairs(frames) do
    local a = type(frame) == "table" and (frame.timings_us or frame)
    if type(a) ~= "table" or #a < 2 then return nil, "invalid frame" end
    for _, v in ipairs(a) do if type(v) ~= "number" or v <= 0 then return nil, "invalid timing" end end
    if i > 1 and #a ~= #lists[1] then return nil, "frame length changes" end
    lists[i] = a
  end
  local first, marks = lists[1], {}
  for _, a in ipairs(lists) do for i = 3, #a - 1, 2 do marks[#marks + 1] = a[i] end end
  local mark = timings.median(marks) or first[1]
  local h = first[1] > mark * 2 and 2 or 0
  local f = #first % 2
  local function med_at(index)
    local a = {}; for _, list in ipairs(lists) do a[#a + 1] = list[index] end
    return timings.median(a)
  end
  local p = { header = {}, footer = {}, bit_count = (#first - h - f) // 2 }
  for i = 1, h do p.header[i] = med_at(i) end
  for i = 1, f do p.footer[i] = med_at(#first - f + i) end
  local mv, sv = {}, {}
  for _, a in ipairs(lists) do
    for i = h + 1, #a - f, 2 do mv[#mv + 1], sv[#sv + 1] = a[i], a[i + 1] end
  end
  local mc, sc = timings.cluster(mv), timings.cluster(sv)
  if #mc == 1 and #sc == 2 then
    p.encoding = "pulse_distance"
    p.zero, p.one = { mc[1].center, sc[1].center }, { mc[1].center, sc[2].center }
  elseif #mc == 2 and #sc == 1 then
    p.encoding = "pulse_width"
    p.zero, p.one = { mc[1].center, sc[1].center }, { mc[2].center, sc[1].center }
  else
    -- Conservative Manchester discovery: every run is one/two half periods,
    -- every half-pair transitions, and all samples have the same decoded length.
    for _, footer in ipairs({ 0, f }) do
      local durations = {}
      for _, a in ipairs(lists) do for i = h + 1, #a - footer do durations[#durations + 1] = a[i] end end
      local clusters = timings.cluster(durations)
      if #clusters >= 1 and #clusters <= 2 then
        local candidate = { encoding = "manchester", header = p.header, footer = {}, unit_us = clusters[1].center }
        for i = 1, footer do candidate.footer[i] = med_at(#first - footer + i) end
        local count, valid = nil, true
        for _, a in ipairs(lists) do
          local halves = 0
          for i = h + 1, #a - footer do halves = halves + math.floor(a[i] / candidate.unit_us + 0.5) end
          candidate.bit_count = halves // 2
          if count and count ~= candidate.bit_count then valid = false; break end
          count = candidate.bit_count
          if not M.decode_frame(a, candidate) then valid = false; break end
        end
        if valid and count and count >= 4 then return candidate end
      end
    end
    -- Unchanging short/preamble frames can be preserved without inventing bits.
    for _, a in ipairs(lists) do
      for i, v in ipairs(a) do if not close(v, med_at(i)) then return nil, "unsupported symbol encoding" end end
    end
    p = { encoding = "literal", header = {}, footer = {}, bit_count = 0 }
    for i = 1, #first do p.header[i] = med_at(i) end
  end
  for _, a in ipairs(lists) do if not M.decode_frame(a, p) then return nil, "inconsistent symbols" end end
  return p
end

function M.learn(frames)
  local ok, value, err = pcall(learn_impl, frames)
  if not ok then return nil, "invalid frames" end
  return value, err
end

function M.encode_bits(p, bits)
  if type(p) ~= "table" or type(bits) ~= "table" or #bits ~= p.bit_count or type(p.header) ~= "table" or type(p.footer) ~= "table" then
    return nil, "invalid frame or bits"
  end
  local out = {}
  for _, v in ipairs(p.header) do out[#out + 1] = v end
  if p.encoding == "manchester" then
    local level, run
    local function half(x)
      if x == level then run = run + 1 else
        if level ~= nil then out[#out + 1] = math.floor(run * p.unit_us + 0.5) end
        level, run = x, 1
      end
    end
    if #bits > 0 and bits[1] ~= 1 then return nil, "Manchester leading space unsupported" end
    for _, bit in ipairs(bits) do
      if bit ~= 0 and bit ~= 1 then return nil, "invalid bit" end
      half(bit); half(1 - bit)
    end
    if level ~= nil then out[#out + 1] = math.floor(run * p.unit_us + 0.5) end
  elseif p.encoding == "pulse_distance" or p.encoding == "pulse_width" then
    for _, bit in ipairs(bits) do
      if bit ~= 0 and bit ~= 1 then return nil, "invalid bit" end
      local pair = bit == 0 and p.zero or p.one
      if type(pair) ~= "table" or type(pair[1]) ~= "number" or type(pair[2]) ~= "number" then return nil, "invalid symbol" end
      out[#out + 1], out[#out + 2] = pair[1], pair[2]
    end
  elseif p.encoding ~= "literal" then return nil, "unknown encoding" end
  for _, v in ipairs(p.footer) do out[#out + 1] = v end
  return out
end

function M.encode_bytes(p, bytes, order)
  if type(p) ~= "table" then return nil, "invalid parameters" end
  local bits, err = M.from_bytes(bytes, p.bit_count, order)
  if not bits then return nil, err end
  return M.encode_bits(p, bits)
end

-- Keep malformed externally supplied tables from throwing at the pure API boundary.
for name, fn in pairs(M) do
  if type(fn) == "function" then
    local call = fn
    M[name] = function(...)
      local ok, value, err = pcall(call, ...)
      if not ok then return nil, "invalid analyzer input" end
      return value, err
    end
  end
end

return M
