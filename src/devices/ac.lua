-- Air conditioner: one logical state, transmitted as a full-state frame.
-- Every change is coalesced (22 -> 23 -> 24 -> 25 sends only 25) and resolved
-- parametric -> hybrid -> raw codebook by analysis/ac_learner.
local capabilities = require "st.capabilities"
local log = require "log"
local native = require "ir.native"
local common = require "devices.common"

local ok_learner, ac_learner = pcall(require, "analysis.ac_learner")
if not ok_learner then ac_learner = nil end

local M = { TYPE = "ac", PROFILE = "ir-ac", LABEL = "IR Air Conditioner" }

M.TOGGLES = { "turbo", "eco", "sleep", "display" }
M.COALESCE_DELAY = 1.0

M.DEFAULT_CONSTRAINTS = {
  min_temp = 16, max_temp = 30, step = 1,
  modes = { "cool", "heat", "dry", "fan", "auto" },
  fan_modes = { "auto", "low", "medium", "high" },
  swing_modes = { "off", "on" },
}

M.DEFAULT_STATE = {
  power = "off", mode = "cool", temp = 24, fan = "auto", swing = "off",
  turbo = false, eco = false, sleep = false, display = true,
}

-- Guided learning for AC is driven by the analyzer (children/learning.lua);
-- these keys are the optional stand-alone toggles.
M.GUIDED = {}

-- ST enum <-> internal mode names
local MODE_TO_ST = { cool = "cool", heat = "heat", dry = "dry", fan = "fanOnly", auto = "auto" }
local MODE_FROM_ST = { cool = "cool", heat = "heat", dry = "dry", fanOnly = "fan", wind = "fan", auto = "auto",
  coolClean = "cool", dryClean = "dry", heatClean = "heat" }
local SWING_TO_ST = { off = "off", on = "all", both = "all", vertical = "vertical", horizontal = "horizontal" }
local SWING_FROM_ST = { off = "off", fixed = "off", all = "on", vertical = "vertical", horizontal = "horizontal" }

-- Explicit constraints (learned or imported) win; an explicitly empty
-- fan/swing list means the remote has no such dimension (state key "-").
function M.constraints(def)
  local explicit = def.ac and def.ac.constraints
  local c = explicit or {}
  local d = M.DEFAULT_CONSTRAINTS
  local function list(v, default)
    if type(v) == "table" and (#v > 0 or explicit) then return v end
    return default
  end
  return {
    min_temp = c.min_temp or d.min_temp, max_temp = c.max_temp or d.max_temp, step = c.step or d.step,
    modes = (c.modes and #c.modes > 0) and c.modes or d.modes,
    fan_modes = list(c.fan_modes, d.fan_modes),
    swing_modes = list(c.swing_modes, d.swing_modes),
  }
end

-- State used for code lookup: dimensions the remote lacks are nil (the
-- state key prints them as "-"), matching analysis/ac_learner.
function M.normalize(def, s)
  local c = M.constraints(def)
  local n = {}
  for k, v in pairs(s) do n[k] = v end
  if #c.fan_modes == 0 then n.fan = nil end
  if #c.swing_modes == 0 then n.swing = nil end
  return n
end

function M.state_key(s)
  if ac_learner and ac_learner.state_key then return ac_learner.state_key(s) end
  if s.power == "off" then return "off" end
  return string.format("%s|%s|%s|%g", s.mode or "-", s.fan or "-", s.swing or "-", s.temp or 0)
end

-- Resolve a state to a native code.  Returns code, method | nil, err
function M.resolve(def, s)
  local ac = def.ac or {}
  s = M.normalize(def, s)
  if ac_learner and ac_learner.resolve then
    local ok, sig, method = pcall(ac_learner.resolve, ac, s)
    if ok and sig then
      local code, err = native.encode(sig)
      if code then return code, method, sig.carrier_hz end
      log.warn("[ZGIR] AC encode failed: " .. tostring(err))
    elseif not ok then
      log.error("[ZGIR] ac_learner.resolve error: " .. tostring(sig))
    end
  end
  -- direct raw codebook fallback (also used while the analyzer is unavailable)
  local rec = ac.codebook and ac.codebook[M.state_key(s)]
  if rec then return rec.z, "raw", rec.carrier end
  if s.power == "off" then
    local off = (ac.codebook and ac.codebook.off) or (def.commands and (def.commands.off or def.commands.power_off))
    if off then return off.z, "key", off.carrier end
  end
  return nil, "no code for state " .. M.state_key(s)
end

local function snap_temp(c, t)
  t = tonumber(t) or 24
  t = math.max(c.min_temp, math.min(c.max_temp, t))
  local step = c.step > 0 and c.step or 1
  t = c.min_temp + math.floor((t - c.min_temp) / step + 0.5) * step
  if math.floor(t) == t then t = math.tointeger(t) end
  return t
end

-- Apply a patch to the logical state and transmit the resulting full state.
function M.apply(ctx, patch)
  local st = ctx.update(patch)
  local s = st.desired
  local code, method_or_err, carrier = M.resolve(ctx.def, s)
  if not code then
    ctx.prompt("이 상태의 IR 코드가 아직 없습니다: " .. M.state_key(M.normalize(ctx.def, s)) .. " (에어컨 학습에서 추가하세요)", "missing")
    log.warn("[ZGIR] AC " .. method_or_err)
    M.emit_all(ctx)
    return false
  end
  local key = M.state_key(M.normalize(ctx.def, s))
  log.info(string.format("[ZGIR] AC state %s via %s", key, method_or_err))
  ctx.send_code(code, carrier, {
    label = "ac:" .. key, coalesce = "ac:" .. ctx.device.id, delay = M.COALESCE_DELAY,
  })
  M.emit_all(ctx)
  return true
end

local function toggle_handler(name)
  return function(ctx, want)
    local s = ctx.state.desired
    -- A stand-alone learned toggle key wins when the state model lacks the field.
    if ctx.has(name) and not (ctx.def.ac and ctx.def.ac.model) then
      if ctx.send_key(name) then
        ctx.update({ [name] = want })
        M.emit_all(ctx)
      end
      return
    end
    if s.power ~= "on" then ctx.update({ [name] = want }); return M.emit_all(ctx) end
    M.apply(ctx, { [name] = want })
  end
end

M.handlers = {}

M.handlers[capabilities.switch.ID] = {
  [capabilities.switch.commands.on.NAME] = function(ctx, cmd)
    if cmd.component ~= "main" then return toggle_handler(cmd.component)(ctx, true) end
    M.apply(ctx, { power = "on" })
  end,
  [capabilities.switch.commands.off.NAME] = function(ctx, cmd)
    if cmd.component ~= "main" then return toggle_handler(cmd.component)(ctx, false) end
    M.apply(ctx, { power = "off" })
  end,
}

local acm = capabilities.airConditionerMode
M.handlers[acm.ID] = {
  [acm.commands.setAirConditionerMode.NAME] = function(ctx, cmd)
    local m = MODE_FROM_ST[cmd.args.mode]
    if not m then return log.warn("[ZGIR] unsupported AC mode " .. tostring(cmd.args.mode)) end
    M.apply(ctx, { power = "on", mode = m })
  end,
}

local function setpoint(ctx, cmd)
  local c = M.constraints(ctx.def)
  M.apply(ctx, { temp = snap_temp(c, cmd.args.setpoint) })
end
M.handlers[capabilities.thermostatCoolingSetpoint.ID] = {
  [capabilities.thermostatCoolingSetpoint.commands.setCoolingSetpoint.NAME] = setpoint,
}
M.handlers[capabilities.thermostatHeatingSetpoint.ID] = {
  [capabilities.thermostatHeatingSetpoint.commands.setHeatingSetpoint.NAME] = setpoint,
}

local acf = capabilities.airConditionerFanMode
M.handlers[acf.ID] = {
  [acf.commands.setFanMode.NAME] = function(ctx, cmd)
    local f = tostring(cmd.args.fanMode):lower()
    if f == "mid" then f = "medium" end
    M.apply(ctx, { fan = f })
  end,
}

local fom = capabilities.fanOscillationMode
M.handlers[fom.ID] = {
  [fom.commands.setFanOscillationMode.NAME] = function(ctx, cmd)
    local sw = SWING_FROM_ST[cmd.args.fanOscillationMode] or "on"
    local c = M.constraints(ctx.def)
    local supported = false
    for _, v in ipairs(c.swing_modes) do if v == sw then supported = true end end
    if not supported then sw = (sw == "off") and "off" or (c.swing_modes[#c.swing_modes] or "off") end
    M.apply(ctx, { swing = sw })
  end,
}

function M.emit_all(ctx)
  local s = ctx.state.desired
  local c = M.constraints(ctx.def)
  ctx.emit(s.power == "on" and capabilities.switch.switch.on() or capabilities.switch.switch.off())
  local modes = {}
  for _, m in ipairs(c.modes) do if MODE_TO_ST[m] then modes[#modes + 1] = MODE_TO_ST[m] end end
  ctx.emit(acm.supportedAcModes({ value = modes }))
  ctx.emit(acm.airConditionerMode({ value = MODE_TO_ST[s.mode] or "cool" }))
  local range = { value = { minimum = c.min_temp, maximum = c.max_temp, step = c.step }, unit = "C" }
  ctx.emit(capabilities.thermostatCoolingSetpoint.coolingSetpointRange(range))
  ctx.emit(capabilities.thermostatHeatingSetpoint.heatingSetpointRange(range))
  ctx.emit(capabilities.thermostatCoolingSetpoint.coolingSetpoint({ value = s.temp, unit = "C" }))
  ctx.emit(capabilities.thermostatHeatingSetpoint.heatingSetpoint({ value = s.temp, unit = "C" }))
  ctx.emit(acf.supportedAcFanModes({ value = c.fan_modes }))
  ctx.emit(acf.fanMode({ value = s.fan or "auto" }))
  local swings, seen = {}, {}
  for _, v in ipairs(c.swing_modes) do
    local stv = SWING_TO_ST[v]
    if stv and not seen[stv] then swings[#swings + 1] = stv; seen[stv] = true end
  end
  if #swings == 0 then swings = { "off" } end
  ctx.emit(fom.supportedFanOscillationModes({ value = swings }))
  ctx.emit(fom.fanOscillationMode({ value = SWING_TO_ST[s.swing] or "off" }))
  for _, t in ipairs(M.TOGGLES) do
    ctx.emit(s[t] and capabilities.switch.switch.on() or capabilities.switch.switch.off(), t)
  end
end

return M
