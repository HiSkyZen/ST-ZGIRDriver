local util = require "util"
local schema = require "packs.schema"
local migration = require "packs.migration"
local codec = require "ir.codec_zosung"
local signal = require "ir.signal"
local M = {}

local function pack_to_def(pack)
  local commands = {}
  for key, rec in pairs(pack.commands or {}) do commands[key] = util.deep_copy(rec) end
  local meta = {
    manufacturer = pack.manufacturer, model = pack.model, region = pack.region,
    name = pack.name, source = (pack.provenance and pack.provenance.source) or "learned", pack_id = pack.id,
  }
  local def = { schema = 1, device_type = pack.deviceType, meta = meta, commands = commands, active = false }
  if pack.capabilityMappings ~= nil and next(pack.capabilityMappings) ~= nil then
    def.capability_mappings = util.deep_copy(pack.capabilityMappings)
  end
  if pack.ac then
    def.ac = {}
    if pack.ac.model ~= nil then def.ac.model = util.deep_copy(pack.ac.model) end
    if pack.ac.learner ~= nil then def.ac.learner = util.deep_copy(pack.ac.learner) end
    if pack.ac.codebook ~= nil then def.ac.codebook = util.deep_copy(pack.ac.codebook) end
    if pack.ac.constraints ~= nil then
      local c = pack.ac.constraints
      def.ac.constraints = {
        min_temp = c.minTemp, max_temp = c.maxTemp, step = c.step,
        modes = util.deep_copy(c.modes), fan_modes = util.deep_copy(c.fanModes), swing_modes = util.deep_copy(c.swingModes),
      }
    end
  end
  local n, cn = 0, 0
  for _ in pairs(commands) do n = n + 1 end
  for _ in pairs((def.ac and def.ac.codebook) or {}) do cn = cn + 1 end
  return def, { id = pack.id, deviceType = pack.deviceType, commands = n, codebook = cn,
    has_model = def.ac ~= nil and def.ac.model ~= nil }
end

function M.import(text, opts)
  opts = opts or {}
  if type(text) ~= "string" then return nil, "pack input must be a string" end
  local ok, result = pcall(function()
    if text:sub(1, 6) == "STIR1:" then
      local raw, err = util.b64_decode(text:sub(7))
      if not raw then error(err) end
      text = raw
    end
    local json = require "st.json"
    local decoded = json.decode(text)
    if type(decoded) ~= "table" then error("JSON pack must be an object") end
    local pack, err = migration.migrate(decoded)
    if not pack then error(err) end
    local checksum = pack.checksum
    if type(checksum) ~= "string" or checksum ~= schema.compute_checksum(pack) then
      if not opts.allow_checksum_mismatch then error("checksum mismatch") end
      pack.checksum = schema.compute_checksum(pack)
    end
    local valid, verr = schema.validate(pack)
    if not valid then error(verr) end
    local cmp, cerr = schema.version_cmp(pack.minDriverVersion, schema.DRIVER_VERSION)
    if cmp == nil then error(cerr) end
    if cmp > 0 then error("pack requires newer driver " .. pack.minDriverVersion) end
    return pack
  end)
  if not ok then return nil, tostring(result) end
  local def, info = pack_to_def(result)
  return def, info
end

local function key_name(name, index, used)
  local key = type(name) == "string" and name:lower():gsub("[^a-z0-9_]", "_"):gsub("^_+", ""):gsub("_+$", "") or ""
  key = key:sub(1, 32)
  if key == "" then
    repeat index = index + 1; key = "key_" .. index until not used[key]
  end
  local base, suffix = key, 1
  while used[key] do
    local tail = "_" .. suffix
    key = base:sub(1, 32 - #tail) .. tail
    suffix = suffix + 1
  end
  used[key] = true
  return key, index
end

local function encode_record(sig)
  local valid, err = signal.validate(sig)
  if not valid then return nil, err end
  local z
  z, err = codec.encode(sig)
  if not z then return nil, err end
  return { z = z, carrier = sig.carrier_hz > 0 and sig.carrier_hz or signal.DEFAULT_CARRIER }
end

function M.from_import_result(result, device_type, meta)
  if type(result) ~= "table" then return nil, "import result must be a table" end
  if result.signals ~= nil and type(result.signals) ~= "table" then return nil, "signals must be a table" end
  if meta ~= nil and type(meta) ~= "table" then return nil, "meta must be a table" end
  if result.meta ~= nil and type(result.meta) ~= "table" then return nil, "result meta must be a table" end
  local def = { schema = 1, device_type = device_type or (result.meta and result.meta.device_type) or "generic",
    meta = util.deep_copy(meta or result.meta or {}), commands = {}, active = false }
  local used, unnamed = {}, 0
  for _, item in ipairs(result.signals or {}) do
    if type(item) == "table" and item.sig then
      local key
      key, unnamed = key_name(item.name, unnamed, used)
      local rec, err = encode_record(item.sig)
      if not rec then return nil, "signal " .. key .. ": " .. err end
      def.commands[key] = rec
    end
  end
  local smart = result.smartir
  if type(smart) == "table" then
    if smart.codebook ~= nil and type(smart.codebook) ~= "table" then return nil, "SmartIR codebook must be a table" end
    if smart.commands ~= nil and type(smart.commands) ~= "table" then return nil, "SmartIR commands must be a table" end
    if smart.kind == "climate" or def.device_type == "ac" then
      def.device_type = "ac"
      def.ac = { codebook = {}, constraints = {} }
      local c = smart.constraints or {}
      if type(c) ~= "table" then return nil, "SmartIR constraints must be a table" end
      def.ac.constraints = { min_temp = c.min_temp, max_temp = c.max_temp, step = c.step,
        modes = util.deep_copy(c.modes), fan_modes = util.deep_copy(c.fan_modes), swing_modes = util.deep_copy(c.swing_modes) }
      for state, sig in pairs(smart.codebook or {}) do
        local rec, err = encode_record(sig)
        if not rec then return nil, "AC codebook " .. tostring(state) .. ": " .. err end
        def.ac.codebook[state] = rec
      end
      for name, sig in pairs(smart.commands or {}) do
        local key
        key, unnamed = key_name(name, unnamed, used)
        local rec, err = encode_record(sig)
        if not rec then return nil, "SmartIR command " .. tostring(name) .. ": " .. err end
        def.commands[key] = rec
      end
    elseif smart.kind == "media_player" or smart.kind == "fan" then
      if smart.kind == "media_player" then def.device_type = "media" else def.device_type = "fan" end
      for name, sig in pairs(smart.commands or {}) do
        local key
        key, unnamed = key_name(name, unnamed, used)
        local rec, err = encode_record(sig)
        if not rec then return nil, "SmartIR command " .. tostring(name) .. ": " .. err end
        def.commands[key] = rec
      end
    end
    if def.meta.manufacturer == nil then def.meta.manufacturer = smart.manufacturer end
    if def.meta.model == nil and type(smart.models) == "table" then def.meta.model = smart.models[1] end
  end
  return def
end

return M
