-- Canonical IR signal representation.  Every importer, analyzer and codec
-- converts to/from this shape; nothing outside ir/codec_* knows device formats.
--
--   {
--     carrier_hz = 38000,              -- integer; 0 means unknown (TX uses 38000)
--     timings_us = { mark, space, ... }, -- positive integers, starts with a mark
--     repeat_timings_us = nil | {...}, -- optional repeat frame (Pronto seq2, NEC repeat)
--     repeat_count = 0,                -- times the repeat frame is appended on TX
--     source = { format = "...", ... },-- provenance only; never affects TX
--   }
local M = {}

M.DEFAULT_CARRIER = 38000
M.MAX_TIMING = 65535      -- Zosung native timings are uint16 microseconds
M.MAX_TIMINGS = 1024      -- sanity limit per flattened signal
M.FRAME_GAP_US = 40000    -- inserted between frames when a frame ends on a mark

local function to_int_list(list)
  local out = {}
  for i = 1, #list do
    local v = math.tointeger(math.floor((tonumber(list[i]) or 0) + 0.5))
    out[i] = v
  end
  return out
end

function M.new(carrier_hz, timings_us, opts)
  opts = opts or {}
  local sig = {
    carrier_hz = math.tointeger(math.floor((tonumber(carrier_hz) or 0) + 0.5)) or 0,
    timings_us = to_int_list(timings_us or {}),
    repeat_count = opts.repeat_count or 0,
    source = opts.source or {},
  }
  if opts.repeat_timings_us and #opts.repeat_timings_us > 0 then
    sig.repeat_timings_us = to_int_list(opts.repeat_timings_us)
  end
  return sig
end

local function validate_list(list, name)
  if type(list) ~= "table" or #list == 0 then return nil, name .. " empty" end
  for i = 1, #list do
    local v = list[i]
    if math.type(v) ~= "integer" or v <= 0 then
      return nil, string.format("%s[%d] invalid (%s)", name, i, tostring(v))
    end
  end
  return true
end

function M.validate(sig)
  if type(sig) ~= "table" then return nil, "signal is not a table" end
  local ok, err = validate_list(sig.timings_us, "timings_us")
  if not ok then return nil, err end
  if #sig.timings_us < 2 then return nil, "signal too short" end
  if sig.repeat_timings_us ~= nil then
    ok, err = validate_list(sig.repeat_timings_us, "repeat_timings_us")
    if not ok then return nil, err end
  end
  if math.type(sig.carrier_hz) ~= "integer" or sig.carrier_hz < 0 or sig.carrier_hz > 1000000 then
    return nil, "carrier_hz invalid"
  end
  if #M.flatten(sig) > M.MAX_TIMINGS then return nil, "signal too long" end
  return true
end

-- Timings for transmission: main frame followed by repeat_count repeat frames.
-- Values above MAX_TIMING are clamped (they are always long gaps in practice).
function M.flatten(sig)
  local out = {}
  local function append(list)
    if #out % 2 == 1 then out[#out + 1] = M.FRAME_GAP_US end
    for i = 1, #list do out[#out + 1] = list[i] end
  end
  append(sig.timings_us)
  if sig.repeat_timings_us then
    for _ = 1, (sig.repeat_count or 0) do append(sig.repeat_timings_us) end
  end
  for i = 1, #out do
    if out[i] > M.MAX_TIMING then out[i] = M.MAX_TIMING end
  end
  return out
end

function M.carrier(sig)
  if sig.carrier_hz and sig.carrier_hz > 0 then return sig.carrier_hz end
  return M.DEFAULT_CARRIER
end

-- Approximate equality of two timing lists (relative tolerance, default 25%).
function M.timings_close(a, b, tol)
  tol = tol or 0.25
  if #a ~= #b then return false end
  for i = 1, #a do
    local x, y = a[i], b[i]
    if math.abs(x - y) > tol * math.max(x, y) + 60 then return false end
  end
  return true
end

function M.describe(sig)
  local t = sig.timings_us or {}
  local head = {}
  for i = 1, math.min(8, #t) do head[i] = tostring(t[i]) end
  return string.format("carrier=%d n=%d [%s%s]", sig.carrier_hz or 0, #t,
    table.concat(head, ","), #t > 8 and ",..." or "")
end

return M
