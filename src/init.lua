-- HOBEIAN ZG-IR01 Universal IR Platform (SmartThings Edge, Zigbee)
--
-- Wiring only.  See ARCHITECTURE.md for the layering:
--   transport/*  Zosung E004/ED00 + central TX queue (parent bridge only)
--   sensors/*    temperature / humidity / battery / voltage + reporting prefs
--   children/*   EDGE_CHILD appliances, dispatch, state, learning, import/export
--   devices/*    TV / AC / fan / media / generic capability mapping
local capabilities = require "st.capabilities"
local ZigbeeDriver = require "st.zigbee"
local defaults = require "st.zigbee.defaults"
local log = require "log"

local caps = require "caps"
local zosung = require "transport.zosung"
local tx_queue = require "transport.tx_queue"
local environment = require "sensors.environment"
local reporting = require "sensors.reporting"
local manager = require "children.manager"
local dispatcher = require "children.dispatcher"
local learning = require "children.learning"
local remote_io = require "children.remote_io"
local state = require "children.state"
local bridge = require "bridge"

local driver -- set after construction; used by transport callbacks

--------------------------------------------------------------------------
-- transport sinks

zosung.on_tx_status = function(device, ok, status)
  tx_queue.on_tx_status(device, ok, status)
end

zosung.on_learned = function(device, code, raw_len)
  if not learning.on_learned(driver, device, code) then
    bridge.on_raw_learned(device, code, raw_len)
  end
end

zosung.on_learn_timeout = function(device)
  if not learning.on_timeout(driver, device) then bridge.on_raw_timeout(device) end
end

--------------------------------------------------------------------------
-- capability routing

local function child_only(fn)
  return function(drv, device, cmd)
    if not manager.is_child(device) then
      return log.warn("[ZGIR] child command on bridge: " .. cmd.capability .. "." .. cmd.command)
    end
    fn(drv, device, cmd)
  end
end

local CHILD_CAPS = {
  capabilities.switch, capabilities.audioVolume, capabilities.audioMute, capabilities.tvChannel,
  capabilities.mediaInputSource, capabilities.mediaPlayback, capabilities.mediaTrackControl,
  capabilities.airConditionerMode, capabilities.airConditionerFanMode, capabilities.fanOscillationMode,
  capabilities.thermostatCoolingSetpoint, capabilities.thermostatHeatingSetpoint,
  capabilities.fanSpeed, capabilities.fanSpeedPercent, capabilities.mode, caps.remote,
}

local capability_handlers = {}
for _, cap in ipairs(CHILD_CAPS) do
  local h = {}
  for name in pairs(cap.commands or {}) do h[name] = child_only(dispatcher.handle) end
  capability_handlers[cap.ID] = h
end

capability_handlers[caps.LEARNING_ID] = {
  startGuided = child_only(function(_, d) learning.start_guided(d) end),
  learn = child_only(function(_, d, cmd) learning.learn_key(d, cmd.args.key) end),
  confirm = child_only(function(_, d) learning.confirm(d) end),
  retry = child_only(function(_, d) learning.retry(d) end),
  skip = child_only(function(_, d) learning.skip(d) end),
  cancel = child_only(function(_, d) learning.cancel(d) end),
}

capability_handlers[caps.PACK_ID] = {
  importData = child_only(function(drv, d, cmd) remote_io.import(drv, d, cmd.args.data) end),
  exportPack = child_only(function(drv, d) remote_io.export(drv, d) end),
}

capability_handlers[caps.BRIDGE_ID] = bridge.capability_handlers[caps.BRIDGE_ID]

capability_handlers[capabilities.refresh.ID] = {
  [capabilities.refresh.commands.refresh.NAME] = function(drv, device)
    if manager.is_child(device) then return dispatcher.refresh_ui(device) end
    bridge.refresh(drv, device)
  end,
}

--------------------------------------------------------------------------
-- lifecycle

local function child_ready(drv, child)
  local def = manager.ensure_def(child)
  dispatcher.refresh_ui(child)
  remote_io.pack_info(child)
  if def.active == false then
    -- verification state is derived from the persisted definition, so it
    -- survives restarts and the added -> init lifecycle ordering
    child:emit_event(caps.learning.learnStatus({ value = "verify-import" }))
    child:emit_event(caps.learning.prompt({ value = "가져온 리모컨을 확인하세요: '재시도'로 시험 송신, 동작하면 '확인'." }))
    return
  end
  child:emit_event(caps.learning.learnStatus({ value = "idle" }))
  child:emit_event(caps.learning.prompt({ value = "'학습 시작' 또는 버튼 이름 입력으로 학습하세요." }))
end

local function device_added(drv, device)
  if manager.is_child(device) then
    local def = manager.on_child_added(drv, device)
    if def.active == false then learning.begin_import_verify(device) end
    return
  end
  bridge.emit_initial(drv, device)
end

local function device_init(drv, device)
  if manager.is_child(device) then
    state.get(device) -- load persisted logical state
    return child_ready(drv, device)
  end
  device:set_field("txq", nil)
  bridge.emit_initial(drv, device)
end

local function do_configure(drv, device)
  if manager.is_child(device) then return end
  reporting.configure(device)
  environment.refresh(device)
end

local function info_changed(drv, device, event, args)
  if manager.is_child(device) then return end
  if reporting.prefs_changed(args and args.old_st_store and args.old_st_store.preferences, device.preferences) then
    reporting.configure(device)
  end
end

local function device_removed(drv, device)
  if manager.is_child(device) then
    state.flush(device)
    local parent = device:get_parent_device()
    if parent then
      parent.thread:call_with_delay(1, function() manager.after_change(drv, parent) end)
    end
  end
end

local function driver_switched(drv, device)
  if not manager.is_child(device) then do_configure(drv, device) end
end

--------------------------------------------------------------------------

local template = {
  supported_capabilities = {
    capabilities.temperatureMeasurement,
    capabilities.relativeHumidityMeasurement,
    capabilities.battery,
    capabilities.voltageMeasurement,
    capabilities.refresh,
  },
  zigbee_handlers = {
    attr = environment.attr_handlers,
    cluster = zosung.cluster_handlers,
  },
  capability_handlers = capability_handlers,
  lifecycle_handlers = {
    added = device_added,
    init = device_init,
    doConfigure = do_configure,
    infoChanged = info_changed,
    removed = device_removed,
    driverSwitched = driver_switched,
  },
  health_check = false,
}

defaults.register_for_default_handlers(template, environment.CAPABILITIES)

driver = ZigbeeDriver("zg-ir01-universal-ir", template)
driver:run()
