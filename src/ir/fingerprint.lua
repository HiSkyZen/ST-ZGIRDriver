local util = require "util"
local M = {}

local function first_frame(sig)
  local t = sig and sig.timings_us
  if type(t) ~= "table" then return {} end
  local spaces, gaps = {}, {}
  for i = 2, #t, 2 do
    spaces[#spaces + 1] = { i = i, v = t[i] }
    if t[i] > 20000 then gaps[#gaps + 1] = { i = i, v = t[i] } end
  end
  local cut
  if #gaps > 0 then
    table.sort(gaps, function(a,b) return a.i < b.i end)
    cut = gaps[1].i
  elseif #spaces > 0 then
    local ordered = {}
    for i, g in ipairs(spaces) do ordered[i] = g.v end
    table.sort(ordered)
    local median = ordered[math.ceil(#ordered / 2)]
    local largest = spaces[1]
    for _, g in ipairs(spaces) do if g.v > largest.v then largest = g end end
    if largest.v > 5 * median then cut = largest.i end
  end
  local out = {}
  for i = 1, (cut or (#t + 1)) - 1 do out[#out + 1] = t[i] end
  return out
end

local function quantize(t)
  local centers, assigned = { {}, {} }, {}
  for parity = 1, 2 do
    local vals = {}
    for i = parity, #t, 2 do vals[#vals + 1] = t[i] end
    table.sort(vals)
    for _, v in ipairs(vals) do
      local found
      for j, c in ipairs(centers[parity]) do
        -- A +/-25% acquisition swing spans a 1.67x range.  Keep that entire
        -- band in one symbol while leaving NEC short/long spaces well apart.
        if math.abs(v - c) <= math.max(90, c * 0.7) then found = j; break end
      end
      if found then
        local c = centers[parity][found]
        centers[parity][found] = math.floor((c * 3 + v + 2) / 4)
      elseif #centers[parity] < 8 then centers[parity][#centers[parity] + 1] = v end
    end
    table.sort(centers[parity])
  end
  local seq = {}
  for i, v in ipairs(t) do
    local p = i % 2 == 1 and 1 or 2
    local best, dist = 1, math.huge
    for j, c in ipairs(centers[p]) do if math.abs(v-c) < dist then best,dist=j,math.abs(v-c) end end
    seq[i] = tostring(best)
  end
  local ratios = {}
  for p = 1, 2 do
    local c = centers[p]
    for j = 2, #c do
      local ratio = c[j] / c[1]
      local bucket = ratio < 1.5 and 0 or (ratio <= 6 and 1 or (ratio <= 12 and 2 or 3))
      ratios[#ratios + 1] = tostring(bucket)
    end
  end
  return table.concat(seq, ""), table.concat(ratios, ",")
end

function M.fingerprint(sig)
  local frame = first_frame(sig)
  if #frame == 0 then return "fp-00000000" end
  local seq, ratios = quantize(frame)
  return "fp-" .. util.fnv1a32(seq .. ":" .. ratios)
end

function M.same(a, b)
  return M.fingerprint(a) == M.fingerprint(b)
end

return M
