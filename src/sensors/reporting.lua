-- Zigbee Configure Reporting driven by device preferences.
--
-- Preferences (profiles/zg-ir01-bridge.yml):
--   periodicReporting, reportingInterval (s), tempChange (°C),
--   humidityChange (%RH), batteryReporting, batteryInterval (s)
-- Disabled periodic reporting sets max interval 0xFFFF ("no periodic
-- report"); change-triggered and spontaneous device reports still arrive.
local clusters = require "st.zigbee.zcl.clusters"
local device_management = require "st.zigbee.device_management"
local log = require "log"

local PowerConfiguration = clusters.PowerConfiguration
local TemperatureMeasurement = clusters.TemperatureMeasurement
local RelativeHumidity = clusters.RelativeHumidity

local M = {}

M.NO_PERIODIC = 0xFFFF
M.PREF_KEYS = {
  "periodicReporting", "reportingInterval", "tempChange",
  "humidityChange", "batteryReporting", "batteryInterval",
}

local function num(v, default)
  local n = tonumber(v)
  if n == nil then return default end
  return n
end

local function prefs(device)
  local p = device.preferences or {}
  local function bool(v, d) if v == nil then return d end return v == true or v == "true" end
  return {
    periodic = bool(p.periodicReporting, true),
    interval = math.floor(num(p.reportingInterval, 600)),
    temp_change = num(p.tempChange, 0.3),
    hum_change = num(p.humidityChange, 2),
    battery = bool(p.batteryReporting, true),
    battery_interval = math.floor(num(p.batteryInterval, 21600)),
  }
end
M.prefs = prefs

function M.configure(device)
  local c = prefs(device)
  local hub = device.driver and device.driver.environment_info and device.driver.environment_info.hub_zigbee_eui
  local function bind(cluster_id)
    if hub then device:send(device_management.build_bind_request(device, cluster_id, hub)) end
  end

  local env_max = c.periodic and c.interval or M.NO_PERIODIC
  local env_min = math.min(30, math.max(1, math.floor((c.periodic and c.interval or 600) / 4)))
  local temp_change = math.max(1, math.floor(c.temp_change * 100 + 0.5))
  local hum_change = math.max(1, math.floor(c.hum_change * 100 + 0.5))

  bind(TemperatureMeasurement.ID)
  device:send(TemperatureMeasurement.attributes.MeasuredValue:configure_reporting(device, env_min, env_max, temp_change))
  bind(RelativeHumidity.ID)
  device:send(RelativeHumidity.attributes.MeasuredValue:configure_reporting(device, env_min, env_max, hum_change))

  local bat_max = c.battery and c.battery_interval or M.NO_PERIODIC
  local bat_min = math.min(3600, math.max(30, math.floor((c.battery and c.battery_interval or 21600) / 4)))
  bind(PowerConfiguration.ID)
  device:send(PowerConfiguration.attributes.BatteryPercentageRemaining:configure_reporting(device, bat_min, bat_max, 2))
  device:send(PowerConfiguration.attributes.BatteryVoltage:configure_reporting(device, bat_min, bat_max, 1))

  log.info(string.format(
    "[ZGIR] reporting configured env=%s/%ds dT=%.2f dRH=%.1f battery=%s/%ds",
    tostring(c.periodic), env_max, temp_change / 100, hum_change / 100, tostring(c.battery), bat_max))
end

function M.prefs_changed(old, new)
  if old == nil or new == nil then return true end
  for _, k in ipairs(M.PREF_KEYS) do
    if old[k] ~= new[k] then return true end
  end
  return false
end

return M
