local signal = require "ir.signal"
local util = require "util"
local M = {}

local function parse_words(text)
  local words = {}
  for w in text:gmatch("%S+") do
    if not w:match("^[%x][%x][%x][%x]$") then return nil, "Pronto words must be four hex digits" end
    words[#words + 1] = tonumber(w, 16)
    if #words > 2052 then return nil, "Pronto input too large" end
  end
  if #words < 4 then return nil, "Pronto header incomplete" end
  return words
end

function M.parse(text)
  if type(text) ~= "string" then return nil, "Pronto input must be text" end
  local words, err = parse_words(text)
  if not words then return nil, err end
  local kind, freq, n1, n2 = words[1], words[2], words[3], words[4]
  if kind ~= 0 and kind ~= 0x100 then return nil, string.format("unsupported Pronto type %04X", kind) end
  if #words ~= 4 + 2 * (n1 + n2) then return nil, "Pronto pair count mismatch" end
  local carrier = kind == 0 and math.floor(1000000 / (freq * 0.241246) + 0.5) or 0
  if kind == 0 and (freq == 0 or carrier > 1000000) then return nil, "invalid Pronto frequency" end
  local unit = kind == 0 and freq * 0.241246 or 1
  local a, b = {}, {}
  local idx = 5
  for k = 1, n1 * 2 do a[k] = math.max(1, math.floor(words[idx] * unit + 0.5)); idx = idx + 1 end
  for k = 1, n2 * 2 do b[k] = math.max(1, math.floor(words[idx] * unit + 0.5)); idx = idx + 1 end
  if #a == 0 then a, b = b, {} end
  if #a < 2 then return nil, "Pronto sequence empty" end
  local sig = signal.new(carrier, a, { repeat_timings_us = #b > 0 and b or nil,
    repeat_count = #b > 0 and 1 or 0, source = { format = "pronto", type = kind } })
  local ok; ok, err = signal.validate(sig); if not ok then return nil, err end
  return { format = "pronto", signals = { { sig = sig } } }
end

function M.encode(sig)
  local ok, err = signal.validate(sig); if not ok then return nil, err end
  local carrier = sig.carrier_hz > 0 and sig.carrier_hz or 38000
  local freq = math.floor(1000000 / (carrier * 0.241246) + 0.5)
  if freq < 1 or freq > 0xFFFF then return nil, "carrier outside Pronto frequency range" end
  local unit = freq * 0.241246
  local function pairs_of(t)
    local out = {}
    for _, v in ipairs(t or {}) do out[#out + 1] = math.max(1, math.min(65535, math.floor(v / unit + 0.5))) end
    if #out % 2 == 1 then out[#out + 1] = 1 end
    return out
  end
  local a, b = pairs_of(sig.timings_us), pairs_of(sig.repeat_timings_us)
  if #a == 0 then return nil, "signal empty" end
  local words = { 0, freq, #a / 2, #b / 2 }
  for _, v in ipairs(a) do words[#words + 1] = v end
  for _, v in ipairs(b) do words[#words + 1] = v end
  local out = {}
  for i, v in ipairs(words) do out[i] = string.format("%04X", v) end
  return table.concat(out, " ")
end

return M
