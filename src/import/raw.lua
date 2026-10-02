local signal = require "ir.signal"
local M = {}

local function json_array(s)
  local ok, json = pcall(require, "st.json")
  if not ok then return nil end
  local good, v = pcall(json.decode, s)
  if good and type(v) == "table" then return v end
  return nil
end

local function timings_from_table(v)
  local out = {}
  if type(v) ~= "table" then return nil, "raw timings must be an array" end
  for i = 1, #v do
    local n = tonumber(v[i])
    if not n or n == 0 then return nil, "invalid raw timing" end
    out[i] = math.floor(math.abs(n) + 0.5)
    if out[i] < 1 then out[i] = 1 end
  end
  if #out < 2 then return nil, "raw timing list too short" end
  return out
end

function M.parse(text)
  if type(text) ~= "string" then return nil, "raw input must be text" end
  local s = text:gsub("^%s+", ""):gsub("%s+$", "")
  local carrier = 38000
  local cv, rest = s:match("^[Ff][Rr][Ee][Qq]%s*=%s*(%d+)%s*[,;]?%s*(.*)$")
  if not cv then cv, rest = s:match("^[Cc][Aa][Rr][Rr][Ii][Ee][Rr]%s*:%s*(%d+)%s*[,;]?%s*(.*)$") end
  if cv then carrier, s = tonumber(cv), rest end
  if not carrier or carrier < 0 or carrier > 1000000 then return nil, "carrier out of range" end
  local list = json_array(s)
  if not list then
    s = s:gsub("[,+]", " ")
    local vals = {}
    for token in s:gmatch("%S+") do
      local n = tonumber(token)
      if not n then return nil, "invalid raw timing token" end
      vals[#vals + 1] = math.floor(math.abs(n) + 0.5)
      if #vals > 1024 then return nil, "too many raw timings" end
    end
    list = vals
  end
  local t, err = timings_from_table(list)
  if not t then return nil, err end
  -- Explicit signed raw notation carries mark/space signs; force alternating polarity.
  local sig = signal.new(carrier, t, { source = { format = "raw" } })
  local ok; ok, err = signal.validate(sig); if not ok then return nil, err end
  return { format = "raw", signals = { { sig = sig } } }
end

return M
