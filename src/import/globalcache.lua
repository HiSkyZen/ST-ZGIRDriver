local signal = require "ir.signal"
local M = {}

function M.parse(text)
  if type(text) ~= "string" then return nil, "GlobalCache input must be text" end
  local f = {}
  for v in text:gmatch("[^,]+") do f[#f + 1] = v:match("^%s*(.-)%s*$") end
  if #f < 8 or f[1] ~= "sendir" then return nil, "invalid GlobalCache sendir command" end
  local freq, repeats, offset = tonumber(f[4]), tonumber(f[5]), tonumber(f[6])
  if not freq or freq <= 0 or freq > 1000000 then return nil, "invalid GlobalCache frequency" end
  if not repeats or repeats < 1 or repeats > 255 or not offset or offset < 0 then return nil, "invalid GlobalCache repeat fields" end
  if offset > 0 and offset % 2 == 0 then return nil, "GlobalCache repeat offset must start on a mark" end
  local cyc = {}
  for i = 7, #f do
    local n = tonumber(f[i])
    if not n or n < 1 or n > 10000000 then return nil, "invalid GlobalCache cycle" end
    cyc[#cyc + 1] = n
  end
  if #cyc < 2 or #cyc % 2 ~= 0 then return nil, "GlobalCache on/off pairs incomplete" end
  local main, rep = {}, {}
  local split = offset > 0 and math.min(#cyc + 1, offset) or #cyc + 1
  if split % 2 == 0 then split = split - 1 end
  for i, n in ipairs(cyc) do
    local us = math.max(1, math.floor(n * 1000000 / freq + 0.5))
    if i < split then main[#main + 1] = us else rep[#rep + 1] = us end
  end
  if #main == 0 then main, rep = rep, {} end
  if #rep < 2 then rep = nil end
  local sig = signal.new(freq, main, { repeat_timings_us = rep, repeat_count = rep and math.max(0, repeats - 1) or 0,
    source = { format = "globalcache" } })
  local ok, err = signal.validate(sig); if not ok then return nil, err end
  return { format = "globalcache", signals = { { sig = sig } } }
end

return M
