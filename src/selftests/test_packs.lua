local util = require "util"
local schema = require "packs.schema"
local export = require "packs.export"
local importer = require "packs.import"
local migration = require "packs.migration"
local catalog = require "packs.catalog"
local codec = require "ir.codec_zosung"
local M = { name = "packs", cases = {} }

local function sample_def()
  local sig = assert(require("ir.protocols").nec(4, 8))
  local z = assert(codec.encode(sig))
  return { schema = 1, device_type = "tv", meta = { manufacturer = "LG", model = "Test", source = "learned" },
    commands = { power = { z = z, carrier = 38000 } }, state = { power = "on" } }
end

M.cases[#M.cases + 1] = { "pack export import and compact", function(t)
  local text, id = assert(export.export(sample_def(), { created = "2026-01-01" }))
  local def, info = assert(importer.import(text))
  t.eq(info.id, id); t.eq(info.commands, 1); t.eq(def.active, false)
  t.same(def.commands.power, sample_def().commands.power)
  t.eq(def.state, nil)
  local compact = assert(export.export_compact(sample_def(), { created = "2026-01-01" }))
  t.ok(compact:match("^STIR1:")); t.ok(importer.import(compact))
end }

M.cases[#M.cases + 1] = { "tampering and driver version checks", function(t)
  local text = assert(export.export(sample_def()))
  local json = require "st.json"
  local pack = json.decode(text)
  pack.checksum = "00000000"
  local bad = json.encode(pack)
  local got = importer.import(bad)
  t.eq(got, nil)
  t.ok(importer.import(bad, { allow_checksum_mismatch = true }))
  pack = json.decode(text); pack.minDriverVersion = "99.0.0"
  pack.id = schema.compute_id(pack)
  pack.checksum = schema.compute_checksum(pack)
  local too_new = importer.import(json.encode(pack))
  t.eq(too_new, nil)
end }

M.cases[#M.cases + 1] = { "v0 migration", function(t)
  local z = sample_def().commands.power.z
  local pack = assert(migration.migrate({ version = 0, type = "tv", codes = { power = z } }))
  t.eq(pack.schemaVersion, 1); t.eq(pack.deviceType, "tv"); t.ok(schema.validate(pack))
end }

M.cases[#M.cases + 1] = { "builtin LG commands decode", function(t)
  local def = assert(catalog.get("builtin:lg-tv"))
  t.eq(def.active, false); t.eq(def.meta.source, "builtin")
  for key, rec in pairs(def.commands) do t.ok(codec.decode(rec.z, rec.carrier), key) end
end }

return M
