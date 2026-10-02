local capabilities = require "st.capabilities"
local common = require "devices.common"

local M = { TYPE = "tv", PROFILE = "ir-tv", LABEL = "IR TV" }

M.GUIDED = {}
for _, k in ipairs({ "power", "vol_up", "vol_down", "mute", "ch_up", "ch_down", "input",
  "up", "down", "left", "right", "ok", "back", "home", "menu", "exit",
  "digit_1", "digit_2", "digit_3", "digit_4", "digit_5", "digit_6", "digit_7", "digit_8", "digit_9", "digit_0",
  "red", "green", "yellow", "blue", "play", "pause", "stop", "rewind", "fast_forward", "info" }) do
  M.GUIDED[#M.GUIDED + 1] = { key = k, ko = common.label(k) }
end

M.DEFAULT_STATE = { power = "off", volume = 10, mute = false, channel = "1", playback = "stopped" }

M.handlers = {}
common.switch_handlers(M.handlers)
common.volume_handlers(M.handlers)
common.playback_handlers(M.handlers)
common.input_handlers(M.handlers)

local tvc = capabilities.tvChannel
M.handlers[tvc.ID] = {
  [tvc.commands.channelUp.NAME] = function(ctx)
    if ctx.send_key("ch_up") then
      local n = tonumber(ctx.state.desired.channel)
      if n then
        ctx.update({ channel = tostring(n + 1) })
        ctx.emit(tvc.tvChannel({ value = tostring(n + 1) }))
      end
    end
  end,
  [tvc.commands.channelDown.NAME] = function(ctx)
    if ctx.send_key("ch_down") then
      local n = tonumber(ctx.state.desired.channel)
      if n and n > 1 then
        ctx.update({ channel = tostring(n - 1) })
        ctx.emit(tvc.tvChannel({ value = tostring(n - 1) }))
      end
    end
  end,
  -- Channel number entry: one digit key per character, then OK when learned.
  [tvc.commands.setTvChannel.NAME] = function(ctx, cmd)
    local ch = tostring(cmd.args.tvChannel or "")
    if not ch:match("^%d+$") or #ch > 5 then return end
    for d in ch:gmatch("%d") do
      if not ctx.send_key("digit_" .. d) then return end
    end
    if ctx.has("ok") then ctx.send_key("ok") end
    ctx.update({ channel = ch })
    ctx.emit(tvc.tvChannel({ value = ch }))
  end,
}

function M.emit_all(ctx)
  common.emit_switch_volume(ctx)
  ctx.emit(tvc.tvChannel({ value = ctx.state.desired.channel or "1" }))
  common.emit_inputs(ctx)
  common.emit_playback(ctx)
end

return M
