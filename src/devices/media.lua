-- AV receivers, soundbars, set-top boxes, projectors.
local capabilities = require "st.capabilities"
local common = require "devices.common"

local M = { TYPE = "media", PROFILE = "ir-media", LABEL = "IR Media" }

M.GUIDED = {}
for _, k in ipairs({ "power", "vol_up", "vol_down", "mute", "input", "play", "pause", "stop",
  "next", "previous", "up", "down", "left", "right", "ok", "back", "menu", "home" }) do
  M.GUIDED[#M.GUIDED + 1] = { key = k, ko = common.label(k) }
end

M.DEFAULT_STATE = { power = "off", volume = 20, mute = false, playback = "stopped" }

M.handlers = {}
common.switch_handlers(M.handlers)
common.volume_handlers(M.handlers)
common.playback_handlers(M.handlers)
common.input_handlers(M.handlers)

local mtc = capabilities.mediaTrackControl
M.handlers[mtc.ID] = {
  [mtc.commands.nextTrack.NAME] = function(ctx) ctx.send_key("next") end,
  [mtc.commands.previousTrack.NAME] = function(ctx) ctx.send_key("previous") end,
}

function M.emit_all(ctx)
  common.emit_switch_volume(ctx)
  common.emit_inputs(ctx)
  common.emit_playback(ctx)
  local cmds = {}
  if ctx.has("next") then cmds[#cmds + 1] = "nextTrack" end
  if ctx.has("previous") then cmds[#cmds + 1] = "previousTrack" end
  ctx.emit(mtc.supportedTrackControlCommands({ value = cmds }))
end

return M
