local signal = require "ir.signal"
local codec_bl = require "ir.codec_broadlink"
local codec_z = require "ir.codec_zosung"
local pronto = require "import.pronto"
local raw = require "import.raw"
local util = require "util"
local M = {}

local function json_decode(text)
  local ok, json = pcall(require, "st.json")
  if not ok then return nil, "JSON module unavailable" end
  local good, value = pcall(json.decode, text)
  if not good or type(value) ~= "table" then return nil, "invalid SmartIR JSON" end
  return value
end

local function decode_code(code, enc, controller)
  if type(code) == "table" then
    if #code > 1024 then return nil, "too many Raw timings" end
    local list = {}
    for i = 1, #code do
      local n = tonumber(code[i]); if not n then return nil, "invalid Raw timing" end
      list[i] = math.floor(math.abs(n) + 0.5)
    end
    local sig = signal.new(38000, list, { source = { format = "smartir", encoding = "Raw" } })
    local ok, err = signal.validate(sig); if not ok then return nil, err end
    return sig
  end
  if type(code) ~= "string" then return nil, "missing SmartIR code" end
  if enc == "Pronto" then
    local parsed, err = pronto.parse(code); if not parsed then return nil, err end
    return parsed.signals[1].sig
  elseif enc == "Raw" then
    local parsed, err = raw.parse(code); if not parsed then return nil, err end
    return parsed.signals[1].sig
  end
  local sig = codec_bl.decode_b64(code)
  if sig then return sig end
  if controller == "UFOR11" or controller == "MQTT" or controller == "Zigbee2MQTT" or controller == "ZHA" or codec_z.looks_like(code) then
    local z, err = codec_z.decode(code)
    if z then return z end
    return nil, err
  end
  return nil, "invalid SmartIR Base64 code"
end

local modes = { cool="cool", heat="heat", dry="dry", fan_only="fan", auto="auto", heat_cool="auto" }
local function norm_fan(v) v = tostring(v):lower(); if v == "mid" or v == "middle" then return "medium" end; return v end
local function norm_dim(v)
  v = tostring(v):lower()
  if v == "default" or v == "none" or v == "-" then return "-" end
  return v
end
local function state_key(mode, fan, swing, temp)
  local n = tonumber(temp)
  local formatted = n and tostring(n) or tostring(temp)
  return mode .. "|" .. fan .. "|" .. swing .. "|" .. formatted
end

local function parse_climate(doc)
  local cmds = doc.commands or {}
  local constraints = { min_temp = tonumber(doc.min_temp or doc.minTemp or doc.minTemperature), max_temp = tonumber(doc.max_temp or doc.maxTemp or doc.maxTemperature),
    step = tonumber(doc.precision or doc.step) or 1, modes = {}, fan_modes = {}, swing_modes = {} }
  for _, v in ipairs(doc.operation_modes or doc.operationModes or doc.modes or {}) do if modes[v] then constraints.modes[#constraints.modes+1] = modes[v] end end
  for _, v in ipairs(doc.fan_modes or doc.fanModes or {}) do constraints.fan_modes[#constraints.fan_modes+1] = norm_fan(v) end
  for _, v in ipairs(doc.swing_modes or doc.swingModes or {}) do constraints.swing_modes[#constraints.swing_modes+1] = norm_dim(v) end
  local out = { kind = "climate", manufacturer = doc.manufacturer, models = doc.supportedModels or doc.models,
    encoding = doc.commandsEncoding or "Base64", constraints = constraints, codebook = {}, commands = {} }
  local controller = doc.irController or doc.controller or doc.supportedController
  if cmds.off then
    local sig, err = decode_code(cmds.off, out.encoding, controller); if not sig then return nil, err end
    out.commands.off = sig
  end
  for raw_mode, mtable in pairs(cmds) do
    local mode = modes[raw_mode]
    if mode and type(mtable) == "table" then
      for raw_fan, node in pairs(mtable) do
        local fan = norm_dim(raw_fan)
        if fan ~= "-" then fan = norm_fan(fan) end
        if type(node) == "table" then
          for k, value in pairs(node) do
            if type(value) == "table" and tonumber(k) == nil then
              local swing = norm_dim(k)
              for temp, code in pairs(value) do
                local sig, err = decode_code(code, out.encoding, controller); if not sig then return nil, err end
                local sk = state_key(mode, fan, swing, temp)
                out.codebook[sk] = sig
              end
            elseif tonumber(k) then
              local sig, err = decode_code(value, out.encoding, controller); if not sig then return nil, err end
              out.codebook[state_key(mode, fan, "-", k)] = sig
            end
          end
        end
      end
    end
  end
  if next(out.codebook) == nil and not out.commands.off then return nil, "SmartIR climate contains no codes" end
  return out
end

local media_names = { on="power_on", off="power_off", volumeUp="vol_up", volumeDown="vol_down", mute="mute",
  previousChannel="ch_down", nextChannel="ch_up" }
local function parse_media(doc)
  local out = { kind = "media_player", manufacturer = doc.manufacturer, models = doc.supportedModels or doc.models,
    encoding = doc.commandsEncoding or "Base64", commands = {} }
  local controller = doc.irController or doc.controller or doc.supportedController
  local c = doc.commands or {}
  for name, key in pairs(media_names) do if c[name] then
    local sig, err = decode_code(c[name], out.encoding, controller); if not sig then return nil, err end
    out.commands[key] = sig
  end end
  for source, code in pairs(c.sources or {}) do
    local sig, err = decode_code(code, out.encoding, controller); if not sig then return nil, err end
    local key = "source_" .. tostring(source):lower():gsub("[^a-z0-9]+", "_"):gsub("^_+", ""):gsub("_+$", "")
    out.commands[key:sub(1,32)] = sig
  end
  if next(out.commands) == nil then return nil, "SmartIR media_player contains no codes" end
  return out
end

local function parse_fan(doc)
  local out = { kind = "fan", manufacturer = doc.manufacturer, models = doc.supportedModels or doc.models,
    encoding = doc.commandsEncoding or "Base64", commands = {} }
  local c, controller = doc.commands or {}, doc.irController or doc.controller or doc.supportedController
  if c.off then local s,e=decode_code(c.off,out.encoding,controller); if not s then return nil,e end; out.commands.power_off=s end
  for i, speed in ipairs(doc.speed or {}) do
    local speed_key = tostring(speed)
    local code = (c.default or {})[speed_key] or (c.default or {})[speed] or (c.forward or {})[speed_key] or (c.forward or {})[speed]
    if code then local s,e=decode_code(code,out.encoding,controller); if not s then return nil,e end; out.commands["speed_"..i]=s end
  end
  if c.oscillate then local s,e=decode_code(c.oscillate,out.encoding,controller); if not s then return nil,e end; out.commands.oscillate=s end
  if next(out.commands) == nil then return nil, "SmartIR fan contains no codes" end
  return out
end

local function parse_impl(text)
  local doc, err = json_decode(text); if not doc then return nil, err end
  if type(doc.commands) ~= "table" then return nil, "SmartIR commands missing" end
  local kind = tostring(doc.kind or doc.deviceType or doc.type or doc.entity or ""):lower()
  local has_mode_tree = false
  for k, v in pairs(doc.commands) do if modes[k] and type(v) == "table" then has_mode_tree = true; break end end
  if kind == "climate" or doc.operation_modes or doc.operationModes or doc.swing_modes or doc.swingModes then kind = "climate"
  elseif has_mode_tree then kind = "climate"
  elseif kind == "fan" or doc.speed then kind = "fan"
  else kind = "media_player" end
  local smart
  if kind == "climate" then smart, err = parse_climate(doc)
  elseif kind == "fan" then smart, err = parse_fan(doc)
  else smart, err = parse_media(doc) end
  if not smart then return nil, err end
  return { format = "smartir", signals = {}, smartir = smart,
    meta = { manufacturer = smart.manufacturer, device_type = smart.kind } }
end

function M.parse(text)
  local ok, result, err = pcall(parse_impl, text)
  if not ok then return nil, "malformed SmartIR data" end
  return result, err
end

return M
