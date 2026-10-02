-- Normalization of learned key signals.
--
-- A learned capture contains whatever the remote sent while the button was
-- held.  NEC-family remotes follow the frame with "repeat codes" (a ~9 ms
-- mark, ~2.25 ms space, one bit mark) every ~108 ms, and the appliance treats
-- each one as another press (verified: one replay of a held LG "volume +"
-- raised the volume by 5).  For stateless keys one press must mean one step,
-- so trailing repeat-code frames are removed.  Full-frame repetitions (Sony
-- SIRC, RC5, many AC protocols) are left untouched.
local signal = require "ir.signal"

local M = {}

M.FRAME_GAP_US = 20000

local function split_frames(t)
  local frames, cur = {}, {}
  for i = 1, #t do
    cur[#cur + 1] = t[i]
    if i % 2 == 0 and t[i] >= M.FRAME_GAP_US then
      frames[#frames + 1] = { timings = cur, gap = t[i] }
      cur = {}
    end
  end
  if #cur > 0 then frames[#frames + 1] = { timings = cur } end
  return frames
end

-- NEC-style repeat code: long leader mark, ~2.25 ms space, single short mark.
local function is_repeat_code(timings)
  local n = #timings
  if n < 3 or n > 4 then return false end
  local mark, space, bit = timings[1], timings[2], timings[3]
  return mark >= 6000 and mark <= 12000 and space >= 1500 and space <= 3200 and bit <= 1200
end

-- Returns a new signal without trailing repeat codes (and the gap that
-- preceded them), or the original signal when nothing applies.
function M.strip_repeat_codes(sig)
  local frames = split_frames(sig.timings_us or {})
  if #frames < 2 or is_repeat_code(frames[1].timings) then return sig, 0 end
  local keep = #frames
  while keep > 1 and is_repeat_code(frames[keep].timings) do keep = keep - 1 end
  local removed = #frames - keep
  if removed == 0 then return sig, 0 end
  local out = {}
  for f = 1, keep do
    for _, v in ipairs(frames[f].timings) do out[#out + 1] = v end
  end
  -- drop the trailing inter-frame gap: the signal now ends on its last mark
  if #out % 2 == 0 and out[#out] >= M.FRAME_GAP_US then out[#out] = nil end
  local s = signal.new(sig.carrier_hz, out, { source = sig.source })
  if not signal.validate(s) then return sig, 0 end
  return s, removed
end

return M
