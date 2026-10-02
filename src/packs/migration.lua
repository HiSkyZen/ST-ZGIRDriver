local util = require "util"
local M = {}

function M.migrate(pack)
  if type(pack) ~= "table" then return nil, "pack must be a table" end
  local version = pack.schemaVersion
  if version == nil then version = pack.version end
  if version == 0 then
    if type(pack.codes) ~= "table" then return nil, "v0 codes must be a table" end
    local commands = {}
    for name, z in pairs(pack.codes) do
      if type(name) ~= "string" or type(z) ~= "string" then return nil, "invalid v0 code" end
      commands[name] = { z = z, carrier = 38000 }
    end
    local v1 = {
      format = "stir", schemaVersion = 1, packVersion = "1.0.0",
      deviceType = pack.type or "generic", manufacturer = pack.manufacturer or "",
      model = pack.model or "", region = pack.region or "", minDriverVersion = "1.0.0",
      provenance = { source = "learned", author = pack.author or "", created = pack.created or "" },
      capabilityMappings = {}, commands = commands,
    }
    v1.id = require("packs.schema").compute_id(v1)
    v1.checksum = require("packs.schema").compute_checksum(v1)
    return v1
  end
  if version == 1 then return util.deep_copy(pack) end
  if type(version) ~= "number" then return nil, "missing or invalid schemaVersion" end
  return nil, "unsupported future schemaVersion " .. tostring(version)
end

return M
