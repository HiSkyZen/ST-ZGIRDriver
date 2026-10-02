local util = require "util"
local schema = require "packs.schema"
local M = {}

local function record(rec)
  if type(rec) ~= "table" then return nil end
  local out = { z = rec.z, carrier = rec.carrier or 38000 }
  if rec.fp ~= nil then out.fp = rec.fp end
  return out
end

local function records(src)
  local out = {}
  for key, rec in pairs(src or {}) do out[key] = record(rec) end
  return out
end

function M.to_pack(def, opts)
  opts = opts or {}
  local meta, ac = def.meta or {}, def.ac
  local provenance = {
    source = meta.source or "learned", author = opts.author or "HiSky", created = opts.created or "",
  }
  local pack = {
    format = "stir", schemaVersion = schema.SCHEMA_VERSION, packVersion = "1.0.0",
    deviceType = def.device_type or "generic", manufacturer = meta.manufacturer or "",
    model = meta.model or "", region = meta.region or "", name = meta.name, minDriverVersion = schema.DRIVER_VERSION,
    provenance = provenance, capabilityMappings = util.deep_copy(def.capability_mappings or {}),
    commands = records(def.commands),
  }
  if ac then
    pack.ac = {}
    if ac.model ~= nil then pack.ac.model = util.deep_copy(ac.model) end
    if ac.codebook ~= nil then pack.ac.codebook = records(ac.codebook) end
    if ac.constraints ~= nil then
      local c = ac.constraints
      pack.ac.constraints = {
        minTemp = c.min_temp, maxTemp = c.max_temp, step = c.step,
        modes = util.deep_copy(c.modes), fanModes = util.deep_copy(c.fan_modes), swingModes = util.deep_copy(c.swing_modes),
      }
    end
    if opts.include_samples and ac.learner ~= nil then pack.ac.learner = util.deep_copy(ac.learner) end
  end
  pack.id = schema.compute_id(pack)
  pack.checksum = schema.compute_checksum(pack)
  return pack
end

function M.export(def, opts)
  if type(def) ~= "table" then return nil, "definition must be a table" end
  local ok, pack = pcall(M.to_pack, def, opts)
  if not ok then return nil, tostring(pack) end
  local valid, err = schema.validate(pack)
  if not valid then return nil, err end
  local enc_ok, text = pcall(util.json_canonical, pack)
  if not enc_ok or type(text) ~= "string" then return nil, "JSON encode failed: " .. tostring(text) end
  return text, pack.id
end

function M.export_compact(def, opts)
  local text, id = M.export(def, opts)
  if not text then return nil, id end
  return "STIR1:" .. util.b64_encode(text), id
end

return M
