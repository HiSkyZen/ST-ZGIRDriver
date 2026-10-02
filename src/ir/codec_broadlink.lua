local signal = require "ir.signal"
local util = require "util"

local M = {}
local TICK = 8192 / 269

local function decode_bytes(bytes)
  if type(bytes) ~= "string" or #bytes < 6 then return nil, "Broadlink packet too short" end
  local kind = bytes:byte(1)
  if kind == 0xB2 or kind == 0xD7 then return nil, "Broadlink RF packets are not supported" end
  if kind ~= 0x26 then return nil, "unsupported Broadlink packet type" end
  local length = bytes:byte(3) | (bytes:byte(4) << 8)
  if length < 3 or length > #bytes - 4 then return nil, "Broadlink payload length invalid" end
  local finish, vals, i, terminated = 4 + length, {}, 5, false
  while i <= finish do
    local b = bytes:byte(i)
    if b == 0x0D and i < finish and bytes:byte(i + 1) == 0x05 then
      terminated = true
      for tail = i + 2, finish do if bytes:byte(tail) ~= 0 then return nil, "nonzero Broadlink padding" end end
      break
    end
    local ticks
    if b == 0 then
      if i + 2 > finish then return nil, "truncated long pulse" end
      ticks = (bytes:byte(i + 1) << 8) | bytes:byte(i + 2)
      i = i + 3
    else
      ticks = b
      i = i + 1
    end
    if ticks == 0 then return nil, "zero pulse duration" end
    vals[#vals + 1] = math.floor(ticks * TICK + 0.5)
    if #vals > 1024 then return nil, "too many Broadlink pulses" end
  end
  if not terminated then return nil, "Broadlink terminator missing" end
  if #vals < 2 then return nil, "Broadlink pulse sequence missing" end
  if #vals % 2 == 1 then return nil, "Broadlink pulse sequence incomplete" end
  local repeat_count = bytes:byte(2) or 0
  local sig = signal.new(38000, vals, { repeat_count = repeat_count, repeat_timings_us = repeat_count > 0 and vals or nil,
    source = { format = "broadlink" } })
  local ok, err = signal.validate(sig)
  if not ok then return nil, err end
  return sig
end

function M.decode(bytes)
  local ok, a, b = pcall(decode_bytes, bytes)
  if not ok then return nil, "malformed Broadlink packet" end
  return a, b
end

function M.looks_like(bytes)
  local sig = M.decode(bytes)
  return sig ~= nil
end

function M.encode(sig)
  local ok, err = signal.validate(sig)
  if not ok then return nil, err end
  local data, timings = {}, sig.timings_us
  for i = 1, #timings do
    local ticks = math.floor(timings[i] / TICK + 0.5)
    ticks = math.max(1, math.min(65535, ticks))
    if ticks < 256 then data[#data + 1] = string.char(ticks)
    else data[#data + 1] = string.char(0, ticks >> 8, ticks & 255) end
  end
  data[#data + 1] = "\r\5"
  local payload = table.concat(data)
  if #payload > 65535 then return nil, "Broadlink payload too large" end
  local packet = string.char(0x26, math.max(0, math.min(255, sig.repeat_count or 0)), #payload & 255, #payload >> 8) .. payload
  local pad = (16 - (#packet % 16)) % 16
  if pad > 0 then packet = packet .. string.rep("\0", pad) end
  return packet
end

function M.decode_b64(text)
  local bytes, err = util.b64_decode(text)
  if not bytes then return nil, err end
  return M.decode(bytes)
end

return M
