local fields = require "analysis.fields"
local signal = require "ir.signal"
local M = {}

function M.flatten(frames)
  if type(frames) ~= "table" then return nil, "invalid frames" end
  local bits, offsets = {}, {}
  for i, frame in ipairs(frames) do
    local a = type(frame) == "table" and (frame.bits or frame)
    if type(a) ~= "table" then return nil, "invalid bits" end
    offsets[i] = #bits
    for _, bit in ipairs(a) do
      if bit ~= 0 and bit ~= 1 then return nil, "invalid bit" end
      bits[#bits + 1] = bit
    end
  end
  return bits, offsets
end

function M.positions(a, b)
  if type(a) ~= "table" or type(b) ~= "table" or #a ~= #b then return nil, "bit count mismatch" end
  local changed = {}
  for i, bit in ipairs(a) do if bit ~= b[i] then changed[#changed + 1] = i end end
  return changed
end

local function same(a, b)
  if #a ~= #b then return false end
  for i, bit in ipairs(a) do if bit ~= b[i] then return false end end
  return true
end

function M.analyze(samples, work)
  if type(samples) ~= "table" or #samples == 0 then return nil, "no samples" end
  local first = samples[1]
  if type(first) ~= "table" or type(first.bits) ~= "table" or type(first.frames) ~= "table" then return nil, "invalid sample" end
  local result = { changing = {}, constants = {}, toggles = {}, repeat_of = {}, bit_count = #first.bits }
  local changing, toggles = {}, {}
  for _, s in ipairs(samples) do
    if type(s) ~= "table" or type(s.bits) ~= "table" or #s.bits ~= #first.bits or type(s.frames) ~= "table" or #s.frames ~= #first.frames then
      return nil, "sample structure changes"
    end
    for i, bit in ipairs(s.bits) do if bit ~= first.bits[i] then changing[i] = true end end
    if work and not work:step(#s.bits) then return nil, "budget" end
  end
  -- Repeated identical labels with different bits are sequence/toggle evidence.
  local labels = {}
  for _, sample in ipairs(samples) do
    local label = sample.label or fields.signature(sample.state)
    local previous = labels[label]
    if previous then
      for p, bit in ipairs(sample.bits) do if bit ~= previous[p] then toggles[p] = true end end
    else labels[label] = sample.bits end
    if work and not work:step(#sample.bits) then return nil, "budget" end
  end
  for i, bit in ipairs(first.bits) do
    if changing[i] then result.changing[#result.changing + 1] = i else result.constants[#result.constants + 1] = { position = i, value = bit } end
    if toggles[i] then result.toggles[#result.toggles + 1] = i end
  end
  for f = 1, #first.frames do
    result.repeat_of[f] = 0
    for previous = 1, f - 1 do
      local repeated = true
      for _, s in ipairs(samples) do
        if work and not work:step(#s.frames[f].bits) then return nil, "budget" end
        local a, b = s.frames[f], s.frames[previous]
        if not same(a.bits, b.bits) or (a.timings_us and b.timings_us and not signal.timings_close(a.timings_us, b.timings_us, 0.45)) then
          repeated = false; break
        end
      end
      if repeated then result.repeat_of[f] = previous; break end
    end
  end
  return result
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
