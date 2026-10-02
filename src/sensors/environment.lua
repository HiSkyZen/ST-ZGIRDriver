-- ZG-IR01 built-in environment sensors on the standard clusters.
-- Temperature (0x0402), humidity (0x0405) and battery % (0x0001/0x0021) use the
-- stock SmartThings default handlers; battery voltage (0x0001/0x0020) is handled
-- here so it becomes a voltageMeasurement event instead of an unhandled report.
local capabilities = require "st.capabilities"
local clusters = require "st.zigbee.zcl.clusters"
local log = require "log"

local PowerConfiguration = clusters.PowerConfiguration
local TemperatureMeasurement = clusters.TemperatureMeasurement
local RelativeHumidity = clusters.RelativeHumidity

local M = {}

M.CAPABILITIES = {
  capabilities.temperatureMeasurement,
  capabilities.relativeHumidityMeasurement,
  capabilities.battery,
}

local function battery_voltage(driver, device, value, zb_rx)
  local raw = value.value
  if raw == nil or raw == 0xFF or raw == 0 then return end
  local volts = raw / 10
  log.debug(string.format("[ZGIR] battery voltage %.1f V", volts))
  device:emit_event(capabilities.voltageMeasurement.voltage({ value = volts, unit = "V" }))
end

M.attr_handlers = {
  [PowerConfiguration.ID] = {
    [PowerConfiguration.attributes.BatteryVoltage.ID] = battery_voltage,
  },
}

function M.refresh(device)
  device:send(TemperatureMeasurement.attributes.MeasuredValue:read(device))
  device:send(RelativeHumidity.attributes.MeasuredValue:read(device))
  device:send(PowerConfiguration.attributes.BatteryPercentageRemaining:read(device))
  device:send(PowerConfiguration.attributes.BatteryVoltage:read(device))
end

return M
