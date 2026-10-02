-- Native ZG-IR01 / Zosung (Tuya) IR code format.
--
-- key_code = base64( lz_compress( uint16le timing[1..n] ) )
-- Timings alternate mark/space in microseconds.  The LZ stream is the
-- FastLZ-level-1 style format used by Tuya IR blasters:
--   000LLLLL                  literal run of L+1 bytes follows
--   LLLDDDDD [E] DDDDDDDD     back-reference, len = L+2 (L=7: len = 9+E),
--                             distance = D+1 (13 bits, up to 8192)
local util = require "util"
local signal = require "ir.signal"

local M = {}

local MAX_LITERAL = 32
local MIN_MATCH = 3
local MAX_MATCH = 264
local MAX_DIST = 8192

function M.decompress(data)
  local out, n = {}, 0
  local i, len = 1, #data
  while i <= len do
    local h = data:byte(i)
    i = i + 1
    local l, d = h >> 5, h & 0x1F
    if l == 0 then
      local count = d + 1
      if i + count - 1 > len then return nil, "truncated literal" end
      for k = 0, count - 1 do
        n = n + 1
        out[n] = data:byte(i + k)
      end
      i = i + count
    else
      if l == 7 then
        if i > len then return nil, "truncated length" end
        l = l + data:byte(i)
        i = i + 1
      end
      l = l + 2
      if i > len then return nil, "truncated distance" end
      local dist = ((d << 8) | data:byte(i)) + 1
      i = i + 1
      if dist > n then return nil, "distance beyond output" end
      for _ = 1, l do
        n = n + 1
        out[n] = out[n - dist]
      end
    end
  end
  local parts = {}
  for k = 1, n, 4096 do
    parts[#parts + 1] = string.char(table.unpack(out, k, math.min(n, k + 4095)))
  end
  return table.concat(parts)
end

-- Greedy LZ compressor producing the stream above.
function M.compress(data)
  local out = {}
  local n = #data
  local last = {}          -- 3-byte key -> most recent position
  local lit_start = 1
  local i = 1

  local function flush_literals(upto)
    local p = lit_start
    while p < upto do
      local count = math.min(MAX_LITERAL, upto - p)
      out[#out + 1] = string.char(count - 1) .. data:sub(p, p + count - 1)
      p = p + count
    end
  end

  while i <= n - MIN_MATCH + 1 do
    local key = data:sub(i, i + 2)
    local cand = last[key]
    last[key] = i
    local mlen = 0
    if cand and i - cand <= MAX_DIST then
      while i + mlen <= n and mlen < MAX_MATCH and data:byte(cand + mlen) == data:byte(i + mlen) do
        mlen = mlen + 1
      end
    end
    if mlen >= MIN_MATCH then
      flush_literals(i)
      local dist = i - cand - 1
      local l = mlen - 2
      if l >= 7 then
        out[#out + 1] = string.char((7 << 5) | (dist >> 8), l - 7, dist & 0xFF)
      else
        out[#out + 1] = string.char((l << 5) | (dist >> 8), dist & 0xFF)
      end
      for k = i + 1, math.min(i + mlen - 1, n - MIN_MATCH + 1) do
        last[data:sub(k, k + 2)] = k
      end
      i = i + mlen
      lit_start = i
    else
      i = i + 1
    end
  end
  flush_literals(n + 1)
  return table.concat(out)
end

function M.timings_to_bytes(timings)
  local parts = {}
  for i = 1, #timings do
    local v = timings[i]
    if v > 65535 then v = 65535 end
    if v < 1 then v = 1 end
    parts[i] = string.pack("<I2", v)
  end
  return table.concat(parts)
end

function M.bytes_to_timings(raw)
  if #raw < 4 or #raw % 2 == 1 then return nil, "raw length invalid" end
  local t = {}
  for i = 1, #raw - 1, 2 do
    t[#t + 1] = string.unpack("<I2", raw, i)
  end
  return t
end

-- Canonical signal -> base64 key_code (repeats flattened).
function M.encode(sig)
  local ok, err = signal.validate(sig)
  if not ok then return nil, err end
  return util.b64_encode(M.compress(M.timings_to_bytes(signal.flatten(sig))))
end

-- base64 key_code -> canonical signal.  carrier_hz defaults to 38000 because
-- the device does not report the learned carrier.
function M.decode(b64, carrier_hz)
  local packed, err = util.b64_decode(b64)
  if not packed then return nil, err end
  local raw
  raw, err = M.decompress(packed)
  if not raw then return nil, err end
  local t
  t, err = M.bytes_to_timings(raw)
  if not t then return nil, err end
  local sig = signal.new(carrier_hz or signal.DEFAULT_CARRIER, t, { source = { format = "zosung" } })
  local ok, verr = signal.validate(sig)
  if not ok then return nil, verr end
  return sig
end

-- True when the text decodes as a plausible Zosung code.
function M.looks_like(b64)
  if not util.is_b64(b64) then return false end
  local sig = M.decode(b64)
  if not sig then return false end
  -- Plausibility: first mark between 100us and 20ms, most timings sane.
  local t = sig.timings_us
  return t[1] >= 100 and t[1] <= 20000 and #t >= 4
end

return M
