local signal = require "ir.signal"
local M = {}

local map = { KEY_POWER="power", KEY_POWER2="power", KEY_VOLUMEUP="vol_up", KEY_VOLUMEDOWN="vol_down",
  KEY_MUTE="mute", KEY_CHANNELUP="ch_up", KEY_CHANNELDOWN="ch_down", KEY_UP="up", KEY_DOWN="down",
  KEY_LEFT="left", KEY_RIGHT="right", KEY_OK="ok", KEY_ENTER="ok", KEY_BACK="back", KEY_HOME="home",
  KEY_MENU="menu", KEY_EXIT="exit", KEY_INFO="info", KEY_GUIDE="guide", KEY_PLAY="play", KEY_PAUSE="pause",
  KEY_STOP="stop", KEY_REWIND="rewind", KEY_FASTFORWARD="fast_forward", KEY_RECORD="record",
  KEY_RED="red", KEY_GREEN="green", KEY_YELLOW="yellow", KEY_BLUE="blue", KEY_PREVIOUS="previous",
  KEY_NEXT="next", KEY_INPUT="input" }
for i=0,9 do map["KEY_"..i] = "digit_"..i end

local function normalize(name)
  if map[name] then return map[name] end
  local s = name:lower():gsub("^key_", ""):gsub("[^a-z0-9]+", "_"):gsub("^_+", ""):gsub("_+$", "")
  if s == "volume_up" then s = "vol_up" elseif s == "volume_down" then s = "vol_down"
  elseif s == "channel_up" then s = "ch_up" elseif s == "channel_down" then s = "ch_down" end
  return s:sub(1, 32)
end

function M.parse(text)
  if type(text) ~= "string" then return nil, "LIRC input must be text" end
  if not text:match("begin%s+remote") then return nil, "LIRC begin remote missing" end
  local freq = tonumber(text:match("frequency%s+(%d+)")) or 38000
  if not text:match("begin%s+raw_codes") then return nil, "decoded LIRC protocols not supported yet" end
  local signals, in_raw, current = {}, false, nil
  for line in (text .. "\n"):gmatch("([^\r\n]*)\r?\n") do
    local s = line:match("^%s*(.-)%s*$")
    if s == "begin raw_codes" then in_raw = true
    elseif s == "end raw_codes" then in_raw = false
    elseif in_raw then
      local name = s:match("^name%s+(%S+)")
      if name then current = { name = normalize(name), values = {} }; signals[#signals + 1] = current
      elseif current and s ~= "" and not s:match("^#") then
        for token in s:gmatch("%S+") do
          local n = tonumber(token)
          if not n or n < 1 then return nil, "invalid LIRC raw duration" end
          current.values[#current.values + 1] = n
          if #current.values > 1024 then return nil, "too many LIRC durations" end
        end
      end
    end
  end
  local out = {}
  for _, item in ipairs(signals) do
    if #item.values >= 2 then
      local sig = signal.new(freq, item.values, { source = { format = "lirc" } })
      local ok, err = signal.validate(sig); if not ok then return nil, err end
      out[#out + 1] = { name = item.name, sig = sig }
    end
  end
  if #out == 0 then return nil, "LIRC raw_codes contains no usable signals" end
  return { format = "lirc", signals = out }
end

return M
