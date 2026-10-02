-- Paste/import of IR codes and Remote Packs into a child; pack export.
--
-- importData accepts:
--   builtin:<id>                      builtin catalog remote
--   STIR1:<base64> / {"format":"stir"} Remote Pack (replaces the definition)
--   any importer format               merged into the definition
--   "name: code" lines                multiple named codes
-- Large payloads can be sent in parts: "@part <i>/<n> <data>" (concatenated).
local log = require "log"
local util = require "util"
local caps = require "caps"
local store = require "ir.store"
local native = require "ir.native"
local dispatcher = require "children.dispatcher"
local learning = require "children.learning"

local M = {}

M.EXPORT_ATTR_MAX = 60000
M.LOG_CHUNK = 900
M.AUTHOR = "HiSky"

local F_PARTS = "import_parts"

local function opt(name)
  local ok, mod = pcall(require, name)
  if ok then return mod end
  log.warn("[ZGIR] optional module unavailable: " .. name .. " (" .. tostring(mod):sub(1, 120) .. ")")
  return nil
end

local function status(child, text)
  child:emit_event(caps.pack.importStatus({ value = text:sub(1, 500) }))
  log.info("[ZGIR] import: " .. text)
end

local function pack_info(child)
  local def = store.get(child)
  if not def then return end
  local n, cb = 0, 0
  for _ in pairs(def.commands or {}) do n = n + 1 end
  for _ in pairs((def.ac and def.ac.codebook) or {}) do cb = cb + 1 end
  local m = def.meta or {}
  local text = string.format("%s %s %s | %s | keys=%d%s%s%s",
    def.device_type, m.manufacturer or "", m.model or "", m.pack_id or "local",
    n, cb > 0 and (" states=" .. cb) or "",
    (def.ac and def.ac.model) and " model=parametric" or "",
    def.active == false and " (미확인)" or "")
  child:emit_event(caps.pack.packInfo({ value = text:sub(1, 500) }))
  if def.ac then
    log.info("[ZGIR] AC constraints " .. util.json_canonical(def.ac.constraints or {}) ..
      " fan_n=" .. tostring(def.ac.constraints and def.ac.constraints.fan_modes and #def.ac.constraints.fan_modes))
  end
end
M.pack_info = pack_info

-- Accumulate "@part i/n data" pieces; returns full text when complete.
local function assemble(child, text)
  local i, n, data = text:match("^@part%s+(%d+)/(%d+)%s+(.*)$")
  if not i then return text end
  i, n = tonumber(i), tonumber(n)
  local parts = child:get_field(F_PARTS)
  if i == 1 or parts == nil or parts.n ~= n then parts = { n = n, got = {} } end
  parts.got[i] = data
  child:set_field(F_PARTS, parts)
  local have = 0
  for _ in pairs(parts.got) do have = have + 1 end
  if have < n then
    status(child, string.format("수신 중 %d/%d", have, n))
    return nil
  end
  child:set_field(F_PARTS, nil)
  local all = {}
  for k = 1, n do all[k] = parts.got[k] or "" end
  return table.concat(all)
end

local function merge_def(child, def, incoming)
  for k, rec in pairs(incoming.commands or {}) do def.commands[k] = rec end
  if incoming.ac then
    def.ac = def.ac or { codebook = {} }
    def.ac.codebook = def.ac.codebook or {}
    for k, rec in pairs(incoming.ac.codebook or {}) do def.ac.codebook[k] = rec end
    if incoming.ac.constraints then def.ac.constraints = incoming.ac.constraints end
    if incoming.ac.model then def.ac.model = incoming.ac.model end
  end
  for k, v in pairs(incoming.meta or {}) do
    if def.meta[k] == nil or def.meta[k] == "" then def.meta[k] = v end
  end
end

-- Try to promote an imported AC codebook to a parametric model.
local function analyze_codebook(def)
  if not (def.ac and def.ac.codebook and next(def.ac.codebook)) then return end
  local learner_mod = opt("analysis.ac_learner")
  if not learner_mod then return end
  local codebook = {}
  for k, rec in pairs(def.ac.codebook) do
    local sig = native.decode(rec.z, rec.carrier)
    if sig then codebook[k] = sig end
  end
  local ok, l = pcall(learner_mod.from_codebook, require("devices.ac").constraints(def), codebook)
  if not ok or not l then return log.warn("[ZGIR] from_codebook failed: " .. tostring(l)) end
  local aok, model, report = pcall(l.analyze, l)
  if aok and model then
    def.ac.model = model
    log.info("[ZGIR] imported AC codebook promoted to parametric model")
  else
    log.info("[ZGIR] imported AC codebook stays raw: " .. util.json_canonical(report or model or {}):sub(1, 300))
  end
end

function M.import(driver, child, raw_text)
  local text = assemble(child, util.trim(tostring(raw_text or "")))
  if text == nil then return end
  if text == "" then return status(child, "빈 입력") end
  local def = store.get(child)
  local packs_import = opt("packs.import")

  local incoming, info, err, replace
  if text:match("^builtin:") then
    local cat = opt("packs.catalog")
    incoming = cat and cat.get(text:match("^(builtin:[%w%-_]+)"))
    if not incoming then return status(child, "알 수 없는 builtin: " .. text) end
    replace = true
  elseif text:match("^STIR1:") or text:match('^%s*{.-"format"%s*:%s*"stir"') then
    if not packs_import then return status(child, "pack 모듈 없음") end
    incoming, err = packs_import.import(text)
    if not incoming then return status(child, "Pack 오류: " .. tostring(err)) end
    replace = true
  else
    local detect = opt("import.detect")
    local result
    if detect then
      result, err = detect.parse_any(text)
    elseif native.looks_like(text) then
      result = { format = "native", signals = { { sig = native.decode(text) } } }
    end
    if not result then return status(child, "형식을 인식하지 못했습니다: " .. tostring(err)) end
    if packs_import and packs_import.from_import_result then
      incoming, err = packs_import.from_import_result(result, def.device_type, result.meta or {})
      if not incoming then return status(child, "변환 오류: " .. tostring(err)) end
    else
      incoming = { commands = {} }
      for i, s in ipairs(result.signals or {}) do
        local code = native.encode(s.sig)
        if code then incoming.commands[s.name or ("key_" .. i)] = { z = code, carrier = s.sig.carrier_hz } end
      end
    end
    info = result.format
  end

  if replace then
    if incoming.device_type ~= def.device_type and def.device_type ~= "generic" then
      return status(child, string.format("이 Pack은 %s용입니다 (현재 %s)", tostring(incoming.device_type), def.device_type))
    end
    incoming.device_type = def.device_type
    incoming.meta = incoming.meta or {}
    def = incoming
  else
    merge_def(child, def, incoming)
  end
  if def.device_type == "ac" and not (def.ac and def.ac.model) then analyze_codebook(def) end
  def.active = false
  store.save(child, def, "import " .. tostring(info or (def.meta and def.meta.pack_id) or "pack"))
  local n, cb = 0, 0
  for _ in pairs(incoming.commands or {}) do n = n + 1 end
  for _ in pairs((incoming.ac and incoming.ac.codebook) or {}) do cb = cb + 1 end
  status(child, string.format("가져오기 완료 (%s): 버튼 %d%s. 시험 송신 후 확인하세요.",
    info or "pack", n, cb > 0 and (", 상태 코드 " .. cb) or ""))
  dispatcher.refresh_ui(child)
  pack_info(child)
  learning.begin_import_verify(child)
end

function M.export(driver, child)
  local def = store.get(child)
  local exporter = opt("packs.export")
  if not (def and exporter) then return status(child, "내보내기를 사용할 수 없습니다") end
  local ok, text, id = pcall(exporter.export, def, { author = M.AUTHOR, created = (pcall(os.date, "!%Y-%m-%d") and os.date("!%Y-%m-%d")) or "" })
  if not ok or not text then return status(child, "내보내기 오류: " .. tostring(text)) end
  if def.meta.pack_id ~= id then
    def.meta.pack_id = id
    store.save(child, def, "pack id assigned")
  end
  local n = math.ceil(#text / M.LOG_CHUNK)
  for i = 1, n do
    log.info(string.format("[ZGIR][EXPORT] %s %d/%d %s", id, i, n, text:sub((i - 1) * M.LOG_CHUNK + 1, i * M.LOG_CHUNK)))
  end
  -- exportData carries the single-line share string (link / QR payload);
  -- tools/export.ps1 turns it back into a .stir JSON file.
  local share = "STIR1:" .. util.b64_encode(text)
  if #share <= M.EXPORT_ATTR_MAX then
    child:emit_event(caps.pack.exportData({ value = share }, { visibility = { displayed = false } }))
  else
    child:emit_event(caps.pack.exportData({ value = string.format("%s: %d bytes — logcat [ZGIR][EXPORT] 참조", id, #text) }))
  end
  status(child, string.format("내보내기 완료 %s (%d bytes)", id, #text))
  pack_info(child)
end

return M
