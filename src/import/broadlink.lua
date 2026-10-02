local util = require "util"
local signal = require "ir.signal"
local codec = require "ir.codec_broadlink"
local M = {}

local function parsed(sig, format)
  local ok, err = signal.validate(sig)
  if not ok then return nil, err end
  return { format = format, signals = { { sig = sig } } }
end

function M.parse(text)
  if type(text) ~= "string" then return nil, "Broadlink input must be text" end
  local s = util.trim(text)
  local fmt, bytes
  local compact = s:gsub("[%s:,]", "")
  compact = compact:gsub("^0[xX]", "")
  if compact:match("^[0-9a-fA-F]+$") and compact:sub(1,2):lower() == "26" then
    fmt = "broadlink_hex"; bytes = util.hex_decode(s)
  else
    fmt = "broadlink_b64"; bytes = util.b64_decode(s)
  end
  if not bytes then return nil, "invalid Broadlink encoding" end
  local sig, err = codec.decode(bytes)
  if not sig then return nil, err end
  return parsed(sig, fmt)
end

return M
