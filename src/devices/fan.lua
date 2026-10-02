local capabilities = require "st.capabilities"
local common = require "devices.common"

local M = { TYPE = "fan", PROFILE = "ir-fan", LABEL = "IR Fan" }

M.GUIDED = {}
for _, k in ipairs({ "power", "speed_up", "speed_down", "speed_1", "speed_2", "speed_3",
  "oscillate", "timer", "mode_natural", "mode_sleep" }) do
  M.GUIDED[#M.GUIDED + 1] = { key = k, ko = common.label(k) }
end

M.DEFAULT_STATE = { power = "off", speed = 1, oscillation = "off", mode = nil }

-- Number of discrete speeds: highest learned speed_N, else 3.
local function speed_count(ctx)
  local n = 0
  for i = 1, 9 do if ctx.has("speed_" .. i) then n = i end end
  return n > 0 and n or 3
end

-- Go to speed level `target` (1..count) with direct keys or up/down steps.
local function set_speed(ctx, target)
  local count = speed_count(ctx)
  target = math.max(0, math.min(count, target))
  if target == 0 then return common.set_power(ctx, false) end
  if ctx.state.desired.power ~= "on" and not ctx.has("speed_" .. target) then
    if not common.set_power(ctx, true) then return false end
  end
  local ok
  if ctx.has("speed_" .. target) then
    ok = ctx.send_key("speed_" .. target)
  else
    local cur = ctx.state.desired.speed or 1
    local diff = target - cur
    local key = diff > 0 and "speed_up" or "speed_down"
    ok = true
    for _ = 1, math.abs(diff) do ok = ok and ctx.send_key(key) end
  end
  if ok then
    ctx.update({ speed = target, power = "on" })
    ctx.emit(capabilities.switch.switch.on())
    ctx.emit(capabilities.fanSpeed.fanSpeed(target))
    ctx.emit(capabilities.fanSpeedPercent.percent(math.floor(target * 100 / count + 0.5)))
  end
  return ok
end

M.handlers = {}
common.switch_handlers(M.handlers)

M.handlers[capabilities.fanSpeed.ID] = {
  [capabilities.fanSpeed.commands.setFanSpeed.NAME] = function(ctx, cmd)
    set_speed(ctx, math.floor(tonumber(cmd.args.speed) or 0))
  end,
}
M.handlers[capabilities.fanSpeedPercent.ID] = {
  [capabilities.fanSpeedPercent.commands.setPercent.NAME] = function(ctx, cmd)
    local pct = tonumber(cmd.args.percent) or 0
    local count = speed_count(ctx)
    set_speed(ctx, pct <= 0 and 0 or math.max(1, math.floor(pct * count / 100 + 0.5)))
  end,
}

local fom = capabilities.fanOscillationMode
M.handlers[fom.ID] = {
  [fom.commands.setFanOscillationMode.NAME] = function(ctx, cmd)
    local want = cmd.args.fanOscillationMode
    local on = want ~= "off" and want ~= "fixed"
    if common.set_toggle(ctx, "oscillation_on", on, "oscillate", "oscillate_on", "oscillate_off") then
      local v = on and "all" or "off"
      ctx.update({ oscillation = v, oscillation_on = on })
      ctx.emit(fom.fanOscillationMode(v))
    end
  end,
}

local function modes(ctx)
  local list = {}
  for _, key in ipairs(common.sorted_keys(ctx.def.commands)) do
    local m = key:match("^mode_(.+)$")
    if m then list[#list + 1] = m end
  end
  return list
end

M.handlers[capabilities.mode.ID] = {
  [capabilities.mode.commands.setMode.NAME] = function(ctx, cmd)
    local m = cmd.args.mode
    if ctx.send_key("mode_" .. tostring(m)) then
      ctx.update({ mode = m })
      ctx.emit(capabilities.mode.mode(m))
    end
  end,
}

function M.emit_all(ctx)
  local d = ctx.state.desired
  local count = speed_count(ctx)
  ctx.emit(d.power == "on" and capabilities.switch.switch.on() or capabilities.switch.switch.off())
  ctx.emit(capabilities.fanSpeed.fanSpeed(d.speed or 1))
  ctx.emit(capabilities.fanSpeedPercent.percent(math.floor((d.speed or 1) * 100 / count + 0.5)))
  ctx.emit(fom.supportedFanOscillationModes({ value = { "off", "all" } }))
  ctx.emit(fom.fanOscillationMode(d.oscillation or "off"))
  local ms = modes(ctx)
  ctx.emit(capabilities.mode.supportedModes({ value = ms }))
  ctx.emit(capabilities.mode.supportedArguments({ value = ms }))
  if d.mode then ctx.emit(capabilities.mode.mode(d.mode)) end
end

return M
