-- Shared behaviour for appliance child types.
--
-- A device module is a table:
--   TYPE, PROFILE, LABEL       identity
--   GUIDED = { {key=, ko=}, }  ordered guided-learning sequence
--   DEFAULT_STATE = {...}
--   emit_all(ctx)              emit every capability from ctx.state.desired
--   handlers[cap_id][cmd] = function(ctx, command)
-- ctx (built by children/dispatcher.lua):
--   device, def, state (children/state record),
--   send_key(key, opts) -> bool, has(key) -> bool, update(patch), emit(event, component)
local capabilities = require "st.capabilities"

local M = {}

M.KO = {
  power = "전원", power_on = "전원 켜기", power_off = "전원 끄기",
  vol_up = "볼륨 +", vol_down = "볼륨 -", mute = "음소거",
  ch_up = "채널 +", ch_down = "채널 -", input = "입력 전환",
  up = "위", down = "아래", left = "왼쪽", right = "오른쪽", ok = "확인(OK)",
  back = "뒤로", home = "홈", menu = "메뉴", exit = "나가기", info = "정보", guide = "편성표",
  red = "빨강", green = "초록", yellow = "노랑", blue = "파랑",
  play = "재생", pause = "일시정지", play_pause = "재생/일시정지", stop = "정지",
  rewind = "되감기", fast_forward = "빨리감기", next = "다음", previous = "이전", record = "녹화",
  speed_up = "풍량 +", speed_down = "풍량 -", oscillate = "회전", timer = "타이머",
  mode_natural = "자연풍", mode_sleep = "수면풍",
  turbo = "터보", eco = "절전", sleep = "취침", display = "디스플레이", light = "조명",
}
for i = 0, 9 do M.KO["digit_" .. i] = "숫자 " .. i end
for i = 1, 9 do M.KO["speed_" .. i] = "풍량 " .. i end

function M.label(key)
  return M.KO[key] or key
end

-- Canonical ordering of keys for UI lists.
local ORDER = {}
do
  local seq = { "power", "power_on", "power_off", "vol_up", "vol_down", "mute", "ch_up", "ch_down", "input",
    "up", "down", "left", "right", "ok", "back", "home", "menu", "exit", "info", "guide",
    "red", "green", "yellow", "blue", "play", "pause", "play_pause", "stop", "rewind", "fast_forward",
    "next", "previous", "record" }
  for i = 0, 9 do seq[#seq + 1] = "digit_" .. i end
  for _, k in ipairs({ "speed_up", "speed_down" }) do seq[#seq + 1] = k end
  for i = 1, 9 do seq[#seq + 1] = "speed_" .. i end
  for _, k in ipairs({ "oscillate", "timer", "mode_natural", "mode_sleep", "turbo", "eco", "sleep", "display", "light" }) do
    seq[#seq + 1] = k
  end
  for i, k in ipairs(seq) do ORDER[k] = i end
end

function M.sorted_keys(commands)
  local ks = {}
  for k in pairs(commands or {}) do ks[#ks + 1] = k end
  table.sort(ks, function(a, b)
    local oa, ob = ORDER[a] or 1000, ORDER[b] or 1000
    if oa ~= ob then return oa < ob end
    return a < b
  end)
  return ks
end

function M.valid_key(key)
  return type(key) == "string" and #key >= 1 and #key <= 32 and key:match("^[a-z0-9_]+$") ~= nil
end

function M.sanitize_key(name)
  local k = tostring(name or ""):lower():gsub("[^a-z0-9_]+", "_"):gsub("^_+", ""):gsub("_+$", "")
  if #k > 32 then k = k:sub(1, 32) end
  return k
end

-- Power: discrete on/off codes when learned, otherwise the power toggle.
-- With a toggle-only remote we skip the transmit when the assumed state
-- already matches and is recent; stale state always transmits.
function M.set_power(ctx, on)
  local discrete = on and "power_on" or "power_off"
  local current = ctx.state.desired.power
  local sent
  if ctx.has(discrete) then
    sent = ctx.send_key(discrete)
  elseif ctx.has("power") then
    if current == (on and "on" or "off") and ctx.confident() then
      sent = true
    else
      sent = ctx.send_key("power")
    end
  else
    sent = ctx.send_key(discrete) -- reports missing code
  end
  if sent then
    ctx.update({ power = on and "on" or "off" })
    ctx.emit(on and capabilities.switch.switch.on() or capabilities.switch.switch.off())
  end
  return sent
end

-- Toggle-style boolean (mute, oscillation) with optional discrete keys.
function M.set_toggle(ctx, field, want, toggle_key, on_key, off_key)
  local current = ctx.state.desired[field]
  if want and on_key and ctx.has(on_key) then return ctx.send_key(on_key) end
  if (not want) and off_key and ctx.has(off_key) then return ctx.send_key(off_key) end
  if current == want and ctx.confident() then return true end
  return ctx.send_key(toggle_key)
end

function M.switch_handlers(handlers)
  handlers[capabilities.switch.ID] = {
    [capabilities.switch.commands.on.NAME] = function(ctx) M.set_power(ctx, true) end,
    [capabilities.switch.commands.off.NAME] = function(ctx) M.set_power(ctx, false) end,
  }
end

-- Relative volume: IR has no absolute volume, so setVolume steps from the
-- assumed level (bounded to MAX_STEPS presses).
M.MAX_VOLUME_STEPS = 15

function M.volume_handlers(handlers)
  local av = capabilities.audioVolume
  local function emit(ctx, v)
    v = math.max(0, math.min(100, v))
    ctx.update({ volume = v })
    ctx.emit(av.volume({ value = v, unit = "%" }))
  end
  handlers[av.ID] = {
    [av.commands.volumeUp.NAME] = function(ctx)
      if ctx.send_key("vol_up") then emit(ctx, (ctx.state.desired.volume or 0) + 1) end
    end,
    [av.commands.volumeDown.NAME] = function(ctx)
      if ctx.send_key("vol_down") then emit(ctx, (ctx.state.desired.volume or 0) - 1) end
    end,
    [av.commands.setVolume.NAME] = function(ctx, cmd)
      local target = math.floor(tonumber(cmd.args.volume) or 0)
      local cur = ctx.state.desired.volume or 0
      local diff = math.max(-M.MAX_VOLUME_STEPS, math.min(M.MAX_VOLUME_STEPS, target - cur))
      local key = diff > 0 and "vol_up" or "vol_down"
      for _ = 1, math.abs(diff) do
        if not ctx.send_key(key) then break end
      end
      emit(ctx, target)
    end,
  }
  local am = capabilities.audioMute
  local function set_mute(ctx, want)
    if M.set_toggle(ctx, "mute", want, "mute", "mute_on", "mute_off") then
      ctx.update({ mute = want })
      ctx.emit(want and am.mute.muted() or am.mute.unmuted())
    end
  end
  handlers[am.ID] = {
    [am.commands.mute.NAME] = function(ctx) set_mute(ctx, true) end,
    [am.commands.unmute.NAME] = function(ctx) set_mute(ctx, false) end,
    [am.commands.setMute.NAME] = function(ctx, cmd) set_mute(ctx, cmd.args.state == "muted") end,
  }
end

M.PLAYBACK_KEYS = {
  play = "play", pause = "pause", stop = "stop", rewind = "rewind", fastForward = "fast_forward",
}

function M.playback_handlers(handlers)
  local mp = capabilities.mediaPlayback
  local status = { play = "playing", pause = "paused", stop = "stopped", rewind = "rewinding", fastForward = "fast forwarding" }
  local h = {}
  for cmd_name, key in pairs(M.PLAYBACK_KEYS) do
    h[cmd_name] = function(ctx)
      local k = key
      if (k == "play" or k == "pause") and not ctx.has(k) and ctx.has("play_pause") then k = "play_pause" end
      if ctx.send_key(k) then
        ctx.update({ playback = status[cmd_name] })
        ctx.emit(mp.playbackStatus({ value = status[cmd_name] }))
      end
    end
  end
  h.setPlaybackStatus = function(ctx, cmd)
    local map = { playing = "play", paused = "pause", stopped = "stop" }
    local c = map[cmd.args.status]
    if c then h[c](ctx) end
  end
  handlers[mp.ID] = h
end

function M.emit_playback(ctx)
  local mp = capabilities.mediaPlayback
  local cmds = {}
  for cmd_name, key in pairs(M.PLAYBACK_KEYS) do
    if ctx.has(key) or ((key == "play" or key == "pause") and ctx.has("play_pause")) then cmds[#cmds + 1] = cmd_name end
  end
  table.sort(cmds)
  ctx.emit(mp.supportedPlaybackCommands({ value = cmds }))
  ctx.emit(mp.playbackStatus({ value = ctx.state.desired.playback or "stopped" }))
end

-- Input sources: keys source_<name> map onto the mediaInputSource enum.
M.SOURCE_ENUM = {
  hdmi = "HDMI", hdmi1 = "HDMI1", hdmi2 = "HDMI2", hdmi3 = "HDMI3", hdmi4 = "HDMI4", hdmi5 = "HDMI5", hdmi6 = "HDMI6",
  tv = "digitalTv", dtv = "digitalTv", usb = "USB", youtube = "YouTube", aux = "aux", bluetooth = "bluetooth", bt = "bluetooth",
  digital = "digital", optical = "optical", coaxial = "coaxial", wifi = "wifi", network = "network",
  am = "AM", fm = "FM", cd = "CD", av = "analog1", av1 = "analog1", av2 = "analog2", component = "analog3", phono = "phono",
}

function M.input_sources(ctx)
  local list, reverse = {}, {}
  for _, key in ipairs(M.sorted_keys(ctx.def.commands)) do
    local name = key:match("^source_(.+)$")
    local enum = name and M.SOURCE_ENUM[name]
    if enum and not reverse[enum] then
      list[#list + 1] = enum
      reverse[enum] = key
    end
  end
  return list, reverse
end

function M.input_handlers(handlers)
  local mis = capabilities.mediaInputSource
  handlers[mis.ID] = {
    [mis.commands.setInputSource.NAME] = function(ctx, cmd)
      local _, reverse = M.input_sources(ctx)
      local key = reverse[cmd.args.mode] or "input"
      if ctx.send_key(key) then
        ctx.update({ input = cmd.args.mode })
        ctx.emit(mis.inputSource({ value = cmd.args.mode }))
      end
    end,
  }
end

function M.emit_inputs(ctx)
  local mis = capabilities.mediaInputSource
  local list = M.input_sources(ctx)
  ctx.emit(mis.supportedInputSources({ value = list }))
  if ctx.state.desired.input then ctx.emit(mis.inputSource({ value = ctx.state.desired.input })) end
end

function M.emit_switch_volume(ctx)
  local d = ctx.state.desired
  ctx.emit(d.power == "on" and capabilities.switch.switch.on() or capabilities.switch.switch.off())
  if d.volume ~= nil then ctx.emit(capabilities.audioVolume.volume({ value = d.volume, unit = "%" })) end
  if d.mute ~= nil then
    ctx.emit(d.mute and capabilities.audioMute.mute.muted() or capabilities.audioMute.mute.unmuted())
  end
end

return M
