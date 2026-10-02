-- Guided learning sessions.
--
--  generic/tv/fan/media: per-key  prompt -> receive -> save -> auto test send -> confirm/retry/skip
--  ac:                   analyzer-driven (next_request picks the most informative state)
--  import:               test-send a representative code, confirm activates the remote
--
-- Only one learning window can be open per bridge; the parent records the owner.
local log = require "log"
local caps = require "caps"
local store = require "ir.store"
local zosung_codec = require "ir.codec_zosung"
local zosung = require "transport.zosung"
local dispatcher = require "children.dispatcher"
local common = require "devices.common"

local ok_fp, fingerprint = pcall(require, "ir.fingerprint")
if not ok_fp then fingerprint = nil end
local ok_l, ac_learner = pcall(require, "analysis.ac_learner")
if not ok_l then ac_learner = nil end

local M = {}

local F_SESSION = "learn_session"
local F_OWNER = "learn_owner" -- on parent: { device_id = child id | "bridge" }

local function emit_status(device, status, key)
  device:emit_event(caps.learning.learnStatus({ value = status }))
  device:emit_event(caps.learning.currentKey({ value = key or "" }))
end

local function prompt(device, text, status, key)
  dispatcher.prompt(device, text)
  emit_status(device, status, key)
end

local function parent_of(device)
  return device:get_parent_device()
end

local function open_window(child)
  local parent = parent_of(child)
  if not parent then return false end
  local owner = parent:get_field(F_OWNER)
  if owner and owner.device_id ~= child.id and zosung.is_learning(parent) then
    prompt(child, "다른 리모컨이 학습 중입니다. 잠시 후 다시 시도하세요.", "busy")
    return false
  end
  parent:set_field(F_OWNER, { device_id = child.id })
  zosung.start_learning(parent)
  return true
end

local function close_window(child)
  local parent = parent_of(child)
  if not parent then return end
  local owner = parent:get_field(F_OWNER)
  if owner and owner.device_id == child.id then
    parent:set_field(F_OWNER, nil)
    if zosung.is_learning(parent) then zosung.stop_learning(parent) end
  end
end

local function fp_of(sig)
  if not fingerprint then return nil end
  local ok, fp = pcall(fingerprint.fingerprint, sig)
  return ok and fp or nil
end

local function duplicate_of(def, fp, key)
  if not fp then return nil end
  for k, rec in pairs(def.commands or {}) do
    if k ~= key and rec.fp == fp then return k end
  end
  return nil
end

--------------------------------------------------------------------------
-- per-key sessions

local function begin_key(child, session)
  local item = session.keys[session.idx]
  if item == nil then
    child:set_field(F_SESSION, nil)
    close_window(child)
    local def = store.get(child)
    local n = 0
    for _ in pairs(def.commands) do n = n + 1 end
    return prompt(child, string.format("학습 완료. 저장된 버튼 %d개.", n), "done")
  end
  session.phase = "waiting"
  if not open_window(child) then return end
  prompt(child, string.format("[%s] 버튼을 ZG-IR01을 향해 눌러 주세요 (%d/%d)",
    item.ko or common.label(item.key), session.idx, #session.keys), "waiting", item.key)
end

function M.start_guided(child)
  local mod, def = dispatcher.module_for(child)
  if not mod then return end
  if def.device_type == "ac" then return M.start_ac(child) end
  local keys = {}
  for _, g in ipairs(mod.GUIDED) do keys[#keys + 1] = g end
  local session = { mode = "keys", keys = keys, idx = 1 }
  child:set_field(F_SESSION, session)
  begin_key(child, session)
end

function M.learn_key(child, raw_key)
  local key = common.sanitize_key(raw_key)
  if not common.valid_key(key) then
    return prompt(child, "버튼 이름은 영문 소문자/숫자/_ 만 사용할 수 있습니다 (예: power, vol_up, my_key).", "error")
  end
  local session = { mode = "keys", keys = { { key = key, ko = common.label(key) } }, idx = 1 }
  child:set_field(F_SESSION, session)
  begin_key(child, session)
end

local function on_key_code(child, session, code, sig)
  local item = session.keys[session.idx]
  local def = store.get(child)
  local fp = fp_of(sig)
  local dup = duplicate_of(def, fp, item.key)
  store.set_command(child, item.key, { z = code, carrier = sig.carrier_hz, fp = fp }, "learn " .. item.key)
  dispatcher.refresh_ui(child)
  session.phase = "verify"
  dispatcher.send_key(child, item.key, { test = true, exact = true })
  local note = dup and string.format(" (주의: '%s'와 같은 신호)", common.label(dup)) or ""
  prompt(child, string.format("[%s] 저장 후 시험 송신했습니다%s. 가전이 반응했으면 '확인', 아니면 '재시도'.",
    item.ko or common.label(item.key), note), "verify", item.key)
end

--------------------------------------------------------------------------
-- AC differential learning

local function load_learner(def)
  if not ac_learner then return nil end
  local ac = def.ac or {}
  local constraints = require("devices.ac").constraints(def)
  if ac.learner then
    local ok, l = pcall(ac_learner.load, ac.learner)
    if ok and l then return l end
  end
  return ac_learner.new({ constraints = constraints })
end

-- Fallback when the analyzer is unavailable: a fixed raw-codebook sequence.
local function raw_ac_sequence(def)
  local c = require("devices.ac").constraints(def)
  local seq = { { power = "off" } }
  for _, mode in ipairs(c.modes) do
    for t = c.min_temp, c.max_temp, c.step do
      seq[#seq + 1] = { power = "on", mode = mode, fan = c.fan_modes[1], swing = c.swing_modes[1], temp = t }
    end
  end
  return seq
end

local function describe_state(s)
  if s.power == "off" then return "전원 끔" end
  local mode_ko = { cool = "냉방", heat = "난방", dry = "제습", fan = "송풍", auto = "자동" }
  return string.format("%s · %s°C · 바람 %s · 스윙 %s", mode_ko[s.mode] or s.mode, tostring(s.temp), s.fan or "-", s.swing or "-")
end

local function ac_next(child, session)
  local def = store.get(child)
  local req
  if session.learner then
    local ok, r = pcall(session.learner.next_request, session.learner)
    if not ok then log.error("[ZGIR] next_request error: " .. tostring(r)) end
    req = ok and r or nil
  else
    session.raw_idx = (session.raw_idx or 0) + 1
    local s = session.raw_seq[session.raw_idx]
    if s then req = { state = s, prompt_ko = "리모컨을 [" .. describe_state(s) .. "] 상태로 맞춘 뒤 버튼을 눌러 주세요" } end
  end
  if req == nil then
    child:set_field(F_SESSION, nil)
    close_window(child)
    local model = def.ac and def.ac.model
    return prompt(child, model and "에어컨 분석 완료: 상태로부터 IR을 직접 생성합니다." or
      "에어컨 학습 완료 (학습한 상태 코드 사용).", "done")
  end
  session.request = req
  session.phase = "waiting"
  if not open_window(child) then return end
  local n = 0
  for _ in pairs(def.ac.codebook or {}) do n = n + 1 end
  prompt(child, string.format("%s (샘플 %d)", req.prompt_ko or describe_state(req.state), n + 1), "waiting",
    require("devices.ac").state_key(req.state))
end

function M.start_ac(child)
  local def = store.get(child)
  def.ac = def.ac or { codebook = {} }
  def.ac.codebook = def.ac.codebook or {}
  local session = { mode = "ac", learner = load_learner(def) }
  if not session.learner then session.raw_seq = raw_ac_sequence(def) end
  child:set_field(F_SESSION, session)
  ac_next(child, session)
end

local function on_ac_code(child, session, code, sig)
  local def = store.get(child)
  local s = session.request.state
  local ac_mod = require "devices.ac"
  def.ac.codebook[ac_mod.state_key(s)] = { z = code, carrier = sig.carrier_hz }
  local report
  if session.learner then
    local ok, err = session.learner:add_sample(s, sig)
    if not ok then log.warn("[ZGIR] add_sample rejected: " .. tostring(err)) end
    local aok, model, rep = pcall(session.learner.analyze, session.learner)
    if aok and model then def.ac.model = model end
    report = aok and rep or model
    local eok, exported = pcall(session.learner.export, session.learner)
    if eok then def.ac.learner = exported end
  end
  store.save(child, def, "ac sample " .. ac_mod.state_key(s))
  if report then log.info("[ZGIR] AC analysis: " .. require("util").json_canonical(report):sub(1, 400)) end
  session.phase = "verify"
  dispatcher.send_code(child, code, sig.carrier_hz, { label = "ac-test" })
  prompt(child, "[" .. describe_state(s) .. "] 저장 후 시험 송신했습니다. 반응했으면 '확인', 아니면 '재시도'.",
    "verify", ac_mod.state_key(s))
end

--------------------------------------------------------------------------
-- import verification

function M.begin_import_verify(child)
  local def = store.get(child)
  local session = { mode = "import" }
  child:set_field(F_SESSION, session)
  local sent = false
  if def.device_type == "ac" then
    local ac_mod = require "devices.ac"
    local s = { power = "on", mode = "cool", temp = 24, fan = "auto", swing = "off" }
    local code, _, carrier = ac_mod.resolve(def, s)
    if not code then code, _, carrier = ac_mod.resolve(def, { power = "off" }) end
    if code then sent = dispatcher.send_code(child, code, carrier, { label = "import-test" }) end
  else
    for _, k in ipairs({ "power", "power_on", "power_off" }) do
      if def.commands[k] then sent = dispatcher.send_key(child, k, { test = true }); break end
    end
    if not sent then
      local first = common.sorted_keys(def.commands)[1]
      if first then sent = dispatcher.send_key(child, first, { test = true }) end
    end
  end
  if sent then
    prompt(child, "가져온 리모컨의 대표 신호(전원)를 시험 송신했습니다. 가전이 반응했으면 '확인'을 눌러 활성화하세요.",
      "verify-import")
  else
    prompt(child, "시험 송신할 신호가 없습니다. '확인'으로 그대로 활성화할 수 있습니다.", "verify-import")
  end
end

--------------------------------------------------------------------------
-- UI commands

function M.confirm(child)
  local session = child:get_field(F_SESSION)
  if session == nil then return prompt(child, "진행 중인 학습이 없습니다.", "idle") end
  if session.mode == "import" then
    local def = store.get(child)
    def.active = true
    store.save(child, def, "import verified")
    child:set_field(F_SESSION, nil)
    dispatcher.refresh_ui(child)
    return prompt(child, "리모컨이 활성화되었습니다.", "done")
  end
  if session.phase ~= "verify" then return prompt(child, "신호를 받은 뒤 '확인'을 눌러 주세요.", "waiting") end
  if session.mode == "ac" then return ac_next(child, session) end
  session.idx = session.idx + 1
  begin_key(child, session)
end

function M.retry(child)
  local session = child:get_field(F_SESSION)
  if session == nil then return prompt(child, "진행 중인 학습이 없습니다.", "idle") end
  if session.mode == "import" then return M.begin_import_verify(child) end
  if session.mode == "ac" then
    session.phase = "waiting"
    if open_window(child) then
      prompt(child, "다시: " .. (session.request.prompt_ko or describe_state(session.request.state)), "waiting")
    end
    return
  end
  begin_key(child, session)
end

function M.skip(child)
  local session = child:get_field(F_SESSION)
  if session == nil then return prompt(child, "진행 중인 학습이 없습니다.", "idle") end
  if session.mode == "ac" then
    -- AC: skipping ends the analyzer session; the model learned so far stays usable.
    return M.cancel(child, "에어컨 학습을 종료했습니다. 지금까지의 샘플/모델은 유지됩니다.")
  end
  if session.mode == "import" then return M.confirm(child) end
  session.idx = session.idx + 1
  begin_key(child, session)
end

function M.cancel(child, text)
  child:set_field(F_SESSION, nil)
  close_window(child)
  prompt(child, text or "학습을 취소했습니다.", "idle")
end

--------------------------------------------------------------------------
-- bridge callbacks (installed by init.lua)

-- returns true when the code was consumed by a child session
function M.on_learned(driver, parent, code)
  local owner = parent:get_field(F_OWNER)
  parent:set_field(F_OWNER, nil)
  if owner == nil or owner.device_id == "bridge" then return false end
  local child = driver:get_device_info(owner.device_id)
  if child == nil then return false end
  local session = child:get_field(F_SESSION)
  if session == nil or session.phase ~= "waiting" then
    log.info("[ZGIR] learned code arrived without waiting session; ignored for child")
    return true
  end
  local sig, err = zosung_codec.decode(code)
  if not sig then
    log.warn("[ZGIR] learned code undecodable: " .. tostring(err))
    return prompt(child, "수신한 신호를 해석할 수 없습니다. '재시도'를 눌러 주세요.", "error") or true
  end
  log.info("[ZGIR] learned " .. require("ir.signal").describe(sig))
  local ok, perr
  if session.mode == "ac" then
    ok, perr = pcall(on_ac_code, child, session, code, sig)
  else
    ok, perr = pcall(on_key_code, child, session, code, sig)
  end
  if not ok then
    log.error("[ZGIR] learn processing error: " .. tostring(perr))
    prompt(child, "저장 중 오류가 발생했습니다. '재시도'를 눌러 주세요.", "error")
  end
  return true
end

function M.on_timeout(driver, parent)
  local owner = parent:get_field(F_OWNER)
  parent:set_field(F_OWNER, nil)
  if owner == nil or owner.device_id == "bridge" then return false end
  local child = driver:get_device_info(owner.device_id)
  if child == nil then return false end
  local session = child:get_field(F_SESSION)
  if session then session.phase = "timeout" end
  prompt(child, "신호를 받지 못했습니다. '재시도' 또는 '건너뛰기'를 눌러 주세요.", "timeout")
  return true
end

function M.claim_for_bridge(parent)
  parent:set_field(F_OWNER, { device_id = "bridge" })
end

return M
