-- Physical ZG-IR01 bridge: remote creation, raw learn/send, self-test.
local log = require "log"
local caps = require "caps"
local util = require "util"
local native = require "ir.native"
local signal = require "ir.signal"
local zosung = require "transport.zosung"
local tx_queue = require "transport.tx_queue"
local manager = require "children.manager"
local learning = require "children.learning"
local environment = require "sensors.environment"

local M = {}

local F_LAST_RAW = "last_raw_code"

function M.status(device, text)
  device:emit_event(caps.bridge.bridgeStatus({ value = text:sub(1, 500) }))
end

function M.emit_initial(driver, device)
  M.status(device, "준비됨")
  manager.after_change(driver, device)
end

-- Resolve user text into a native code: zosung b64, any importer format, or
-- builtin:<id>:<key>.
function M.resolve_code(text)
  text = util.trim(text or "")
  local bid, key = text:match("^(builtin:[%w%-_]+):([%w_]+)$")
  if bid then
    local ok, cat = pcall(require, "packs.catalog")
    local def = ok and cat.get(bid)
    local rec = def and def.commands[key]
    if not rec then return nil, "unknown builtin key " .. text end
    return rec.z, rec.carrier
  end
  -- Native/Broadlink/Tuya codes are normalized into the device's own packet
  -- layout (lossless for device-learned codes: ticks round-trip exactly).
  local nsig = native.decode(text)
  if nsig then return native.encode(nsig), signal.carrier(nsig) end
  local ok, detect = pcall(require, "import.detect")
  if not ok then return nil, "importers unavailable" end
  local result, err = detect.parse_any(text)
  if not result or not result.signals or not result.signals[1] then return nil, err or "no signal" end
  local sig = result.signals[1].sig
  local code, eerr = native.encode(sig)
  if not code then return nil, eerr end
  return code, signal.carrier(sig)
end

local handlers = {}

handlers.createRemote = function(driver, device, cmd)
  local key, err = manager.create(driver, device, cmd.args.spec)
  if key then
    M.status(device, "리모컨 생성 중: " .. key)
  else
    M.status(device, "생성 실패: " .. tostring(err))
  end
end

handlers.learnRaw = function(driver, device)
  learning.claim_for_bridge(device)
  zosung.start_learning(device)
  M.status(device, "원시 코드 학습 대기 중 — 리모컨 버튼을 누르세요")
end

handlers.sendCode = function(driver, device, cmd)
  local code, carrier = M.resolve_code(cmd.args.code)
  if not code then return M.status(device, "송신 실패: " .. tostring(carrier)) end
  tx_queue.enqueue(device, {
    code = code, freq = carrier, label = "bridge:sendCode",
    on_done = function(ok, err) M.status(device, ok and "송신 완료" or ("송신 실패: " .. tostring(err))) end,
  })
  M.status(device, "송신 대기열에 추가됨")
end

handlers.selfTest = function(driver, device, cmd)
  local selftest = require "selftest"
  local ok, res = pcall(selftest.run, cmd.args.filter)
  if not ok then return M.status(device, "selftest crashed: " .. tostring(res)) end
  local text = string.format("selftest passed=%d failed=%d", res.passed, res.failed)
  if res.failed > 0 then text = text .. " first: " .. tostring(res.failures[1]) end
  M.status(device, text)
end

M.capability_handlers = {
  [caps.BRIDGE_ID] = handlers,
}

function M.refresh(driver, device)
  environment.refresh(device)
  manager.after_change(driver, device)
end

-- learned code not owned by any child session
function M.on_raw_learned(device, code, raw_len)
  device:set_field(F_LAST_RAW, code, { persist = true })
  local sig = native.decode(code)
  local desc = sig and signal.describe(sig) or "undecodable"
  log.info("[ZGIR] bridge raw learn " .. desc)
  M.status(device, string.format("학습 완료 %d bytes, %s — 코드: %s", raw_len or 0, desc,
    #code > 300 and (code:sub(1, 300) .. "…") or code))
end

function M.on_raw_timeout(device)
  M.status(device, "학습 시간 초과")
end

return M
