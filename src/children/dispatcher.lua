-- Routes capability commands on appliance children to their device module and
-- turns key presses into requests on the parent's central TX queue.
-- Children never touch Zigbee.
local log = require "log"
local caps = require "caps"
local store = require "ir.store"
local state = require "children.state"
local tx_queue = require "transport.tx_queue"
local common = require "devices.common"

local M = {}

M.MODULES = {
  tv = require "devices.tv",
  ac = require "devices.ac",
  fan = require "devices.fan",
  media = require "devices.media",
  generic = require "devices.generic",
}

function M.module_for(device)
  local def = store.get(device)
  return def and M.MODULES[def.device_type], def
end

-- UI prompt on the learning capability (shared by learning/import code).
function M.prompt(device, text, status)
  device:emit_event(caps.learning.prompt({ value = text }, { visibility = { displayed = false } }))
  if status then device:emit_event(caps.learning.learnStatus({ value = status })) end
end

-- Enqueue a native code on the parent bridge.
function M.send_code(device, code, carrier, opts)
  opts = opts or {}
  local parent = device:get_parent_device()
  if parent == nil then
    log.error("[ZGIR] child without parent: " .. tostring(device.id))
    return false
  end
  return tx_queue.enqueue(parent, {
    code = code, freq = carrier or 38000, label = opts.label, coalesce = opts.coalesce, delay = opts.delay,
    on_done = function(ok, err)
      if ok then
        if opts.on_success then opts.on_success() end
      elseif err ~= "superseded" then
        log.warn(string.format("[ZGIR] %s transmit failed: %s", opts.label or "?", tostring(err)))
        if opts.on_fail then opts.on_fail(err) end
      end
    end,
  })
end

-- Fallback chain for missing keys (e.g. discrete power falls back to toggle).
local FALLBACK = {
  power_on = { "power" }, power_off = { "power" }, play = { "play_pause" }, pause = { "play_pause" },
}

function M.send_key(device, key, opts)
  opts = opts or {}
  local def = store.get(device)
  if not def then return false end
  local rec = def.commands and def.commands[key]
  if rec == nil and not opts.exact then
    for _, alt in ipairs(FALLBACK[key] or {}) do
      rec = def.commands[alt]
      if rec then key = alt; break end
    end
  end
  if rec == nil then
    M.prompt(device, string.format("'%s' 버튼이 아직 학습되지 않았습니다. 학습할 버튼 이름에 '%s'를 입력하세요.",
      common.label(key), key), "missing")
    log.info("[ZGIR] key not learned: " .. key)
    return false
  end
  if def.active == false and not opts.test then
    M.prompt(device, "가져온 리모컨이 아직 확인되지 않았습니다. 시험 송신 후 '확인'을 눌러 활성화하세요.", "verify-import")
    return false
  end
  local label = (device.label or "child") .. ":" .. key
  M.send_code(device, rec.z, rec.carrier, {
    label = label,
    on_success = function() state.commanded(device) end,
    on_fail = opts.on_fail,
  })
  device:emit_event(caps.remote.lastKey({ value = key }, { state_change = true }))
  return true
end

function M.ctx(device)
  local mod, def = M.module_for(device)
  if not mod then return nil end
  local ctx = { device = device, def = def, module = mod }
  ctx.state = state.get(device, mod.DEFAULT_STATE)
  ctx.has = function(key) return def.commands[key] ~= nil end
  ctx.send_key = function(key, opts) return M.send_key(device, key, opts) end
  ctx.send_code = function(code, carrier, opts)
    opts = opts or {}
    opts.on_success = opts.on_success or function() state.commanded(device) end
    return M.send_code(device, code, carrier, opts)
  end
  ctx.update = function(patch) return state.update(device, patch, "commanded") end
  ctx.confident = function() return state.is_confident(device) end
  ctx.emit = function(event, component)
    if component and component ~= "main" then
      local comp = device.profile.components[component]
      if comp then device:emit_component_event(comp, event) end
    else
      device:emit_event(event)
    end
  end
  ctx.prompt = function(text, status) M.prompt(device, text, status) end
  return ctx
end

-- Emit supportedKeys + every module capability from current state.
function M.refresh_ui(device)
  local ctx = M.ctx(device)
  if not ctx then return end
  device:emit_event(caps.remote.supportedKeys({ value = common.sorted_keys(ctx.def.commands) },
    { visibility = { displayed = false } }))
  local ok, err = pcall(ctx.module.emit_all, ctx)
  if not ok then log.error("[ZGIR] emit_all failed: " .. tostring(err)) end
end

-- Generic capability command entry point for children.
function M.handle(driver, device, command)
  local ctx = M.ctx(device)
  if not ctx then
    return log.warn("[ZGIR] command for child without definition: " .. tostring(device.id))
  end
  if command.capability == caps.REMOTE_ID and command.command == "press" then
    local key = common.sanitize_key(command.args.key)
    if key == "" then return end
    return M.send_key(device, key)
  end
  local h = ctx.module.handlers[command.capability]
  local fn = h and h[command.command]
  if not fn then
    return log.warn(string.format("[ZGIR] %s: unsupported %s.%s", ctx.module.TYPE, command.capability, command.command))
  end
  local ok, err = pcall(fn, ctx, command)
  if not ok then log.error("[ZGIR] handler error: " .. tostring(err)) end
end

return M
