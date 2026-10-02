local util = require "util"
local codec = require "ir.native"

local M = { SCHEMA_VERSION = 1, DRIVER_VERSION = "1.0.0" }
local TYPES = { tv = true, ac = true, fan = true, media = true, generic = true }

local function copy_without(t, ...)
  local out = util.deep_copy(t or {})
  for i = 1, select("#", ...) do out[select(i, ...)] = nil end
  return out
end

function M.compute_id(pack)
  local body = copy_without(pack, "id", "checksum", "provenance")
  return "STIR-" .. util.fnv1a32(util.json_canonical(body))
end

function M.compute_checksum(pack)
  return util.fnv1a32(util.json_canonical(copy_without(pack, "checksum")))
end

local function valid_record(rec)
  if type(rec) ~= "table" or type(rec.z) ~= "string" then return nil, "command record requires z" end
  if rec.fp ~= nil and type(rec.fp) ~= "string" then return nil, "command fp must be a string" end
  if rec.carrier ~= nil then
    if type(rec.carrier) ~= "number" or math.tointeger(rec.carrier) == nil or rec.carrier < 0 or rec.carrier > 1000000 then
      return nil, "invalid command carrier"
    end
  end
  local sig, err = codec.decode(rec.z, rec.carrier)
  if not sig then return nil, "invalid command code: " .. tostring(err) end
  return true
end

local function validate_records(records, label)
  if type(records) ~= "table" then return nil, label .. " must be a table" end
  for key, rec in pairs(records) do
    if type(key) ~= "string" or #key > 32 or not key:match("^[a-z0-9_]+$") then
      return nil, "invalid " .. label .. " key: " .. tostring(key)
    end
    local ok, err = valid_record(rec)
    if not ok then return nil, label .. "." .. key .. ": " .. err end
  end
  return true
end

function M.validate(pack)
  if type(pack) ~= "table" then return nil, "pack must be a table" end
  if pack.format ~= "stir" then return nil, "format must be stir" end
  if pack.schemaVersion ~= M.SCHEMA_VERSION then return nil, "unsupported schemaVersion" end
  if type(pack.packVersion) ~= "string" or not pack.packVersion:match("^%d+%.%d+%.%d+$") then return nil, "invalid packVersion" end
  if type(pack.id) ~= "string" or pack.id ~= M.compute_id(pack) then return nil, "pack id mismatch" end
  if type(pack.deviceType) ~= "string" or not TYPES[pack.deviceType] then return nil, "invalid deviceType" end
  for _, f in ipairs({ "manufacturer", "model", "region", "minDriverVersion" }) do
    if type(pack[f]) ~= "string" then return nil, f .. " must be a string" end
  end
  if pack.name ~= nil and type(pack.name) ~= "string" then return nil, "name must be a string" end
  if type(pack.provenance) ~= "table" or type(pack.provenance.source) ~= "string" or
    type(pack.provenance.author) ~= "string" or type(pack.provenance.created) ~= "string" then
    return nil, "invalid provenance"
  end
  if pack.capabilityMappings ~= nil and type(pack.capabilityMappings) ~= "table" then return nil, "capabilityMappings must be a table" end
  local ok, err = validate_records(pack.commands, "commands")
  if not ok then return nil, err end
  if pack.ac ~= nil then
    if type(pack.ac) ~= "table" then return nil, "ac must be a table" end
    if pack.ac.model ~= nil and type(pack.ac.model) ~= "table" then return nil, "ac.model must be a table" end
    if pack.ac.learner ~= nil and type(pack.ac.learner) ~= "table" then return nil, "ac.learner must be a table" end
    if pack.ac.constraints ~= nil and type(pack.ac.constraints) ~= "table" then return nil, "ac.constraints must be a table" end
    if pack.ac.codebook ~= nil then
      if type(pack.ac.codebook) ~= "table" then return nil, "ac.codebook must be a table" end
      for state, rec in pairs(pack.ac.codebook) do
        if type(state) ~= "string" then return nil, "invalid AC codebook state" end
        ok, err = valid_record(rec)
        if not ok then return nil, "ac.codebook." .. state .. ": " .. err end
      end
    end
  end
  if type(pack.checksum) ~= "string" or pack.checksum ~= M.compute_checksum(pack) then return nil, "checksum mismatch" end
  return true
end

local function version(v)
  if type(v) ~= "string" then return nil end
  local a, b, c = v:match("^(%d+)%.(%d+)%.(%d+)$")
  if not a then return nil end
  return tonumber(a), tonumber(b), tonumber(c)
end

function M.version_cmp(a, b)
  local aa, ab, ac = version(a)
  local ba, bb, bc = version(b)
  if not aa or not ba then return nil, "invalid version" end
  local x, y = { aa, ab, ac }, { ba, bb, bc }
  for i = 1, 3 do if x[i] < y[i] then return -1 elseif x[i] > y[i] then return 1 end end
  return 0
end

return M
