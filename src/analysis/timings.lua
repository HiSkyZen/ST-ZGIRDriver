-- Timing-only operations. Frames start with a mark; gap_us is the following space.
local signal = require "ir.signal"
local M = {}

function M.median(values)
  if type(values) ~= "table" or #values == 0 then return nil, "empty values" end
  local a = {}
  for i, v in ipairs(values) do
    if type(v) ~= "number" or v ~= v or v <= 0 or v == math.huge then return nil, "invalid duration" end
    a[i] = v
  end
  table.sort(a)
  local n = #a
  return math.floor((a[(n + 1) // 2] + a[(n + 2) // 2]) / 2 + 0.5)
end

-- A cluster spans at most 1.85:1, so +/-25% jitter cannot chain two symbols.
function M.cluster(values)
  if type(values) ~= "table" then return nil, "values must be a table" end
  local a = {}
  for i, v in ipairs(values) do
    if type(v) ~= "number" or v <= 0 or v ~= v or v == math.huge then return nil, "invalid duration" end
    a[i] = v
  end
  table.sort(a)
  local groups = {}
  for _, v in ipairs(a) do
    local g = groups[#groups]
    if not g or v > g[1] * 1.85 + 30 then g = {}; groups[#groups + 1] = g end
    g[#g + 1] = v
  end
  local out = {}
  for _, g in ipairs(groups) do out[#out + 1] = { center = M.median(g), count = #g, min = g[1], max = g[#g] } end
  return out
end

function M.nearest(value, clusters, tolerance)
  if type(value) ~= "number" or type(clusters) ~= "table" then return nil, "invalid symbol" end
  local best, distance
  for i, c in ipairs(clusters) do
    local center = type(c) == "table" and c.center or c
    if type(center) ~= "number" or center <= 0 then return nil, "invalid cluster" end
    local d = math.abs(value - center) / center
    if not distance or d < distance then best, distance = i, d end
  end
  if not best or distance > (tolerance or 0.36) then return nil, "unrecognized duration" end
  return best
end

local function checked(sig)
  if type(sig) ~= "table" then return nil, "invalid signal" end
  if sig.repeat_count ~= nil and (math.type(sig.repeat_count) ~= "integer" or sig.repeat_count < 0 or sig.repeat_count > 16) then
    return nil, "invalid repeat count"
  end
  local ok, err = signal.validate(sig)
  if not ok then return nil, err end
  return signal.flatten(sig)
end

function M.split(sig, opts)
  opts = type(opts) == "table" and opts or {}
  local ok, list, err = pcall(checked, sig)
  if not ok then return nil, "invalid signal" end
  if not list then return nil, err end
  -- A header space follows only one mark, so it is never a gap. A short
  -- repeat (header pair + footer mark) can still end at the next long space.
  local spaces = {}
  for i = 4, #list, 2 do if list[i] < 4000 then spaces[#spaces + 1] = list[i] end end
  local short = M.median(spaces) or 560
  local threshold = opts.gap_us or math.max(5000, short * 4)
  if type(threshold) ~= "number" or threshold <= 0 then return nil, "invalid gap threshold" end
  local frames, current = {}, {}
  for i, v in ipairs(list) do
    if i % 2 == 0 and v >= threshold and #current >= 3 then
      frames[#frames + 1] = { timings_us = current, gap_us = math.min(v, 65535) }
      current = {}
    else
      current[#current + 1] = math.min(v, 65535)
    end
  end
  if #current > 0 then frames[#frames + 1] = { timings_us = current, gap_us = 0 } end
  if #frames == 0 then return nil, "empty frames" end
  return frames
end

function M.normalize(list, marks, spaces)
  if type(list) ~= "table" then return nil, "invalid timings" end
  local out = {}
  for i, v in ipairs(list) do
    local clusters = i % 2 == 1 and marks or spaces
    local index, err = M.nearest(v, clusters)
    if not index then return nil, err end
    local c = clusters[index]
    out[i] = math.floor((type(c) == "table" and c.center or c) + 0.5)
  end
  return out
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
