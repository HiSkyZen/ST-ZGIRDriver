-- Free-form remote: the user names and learns any keys.
local capabilities = require "st.capabilities"
local common = require "devices.common"

local M = { TYPE = "generic", PROFILE = "ir-generic", LABEL = "IR Remote" }

M.GUIDED = { { key = "power", ko = common.label("power") } }
M.DEFAULT_STATE = { power = "off" }

M.handlers = {}
common.switch_handlers(M.handlers)

function M.emit_all(ctx)
  ctx.emit(ctx.state.desired.power == "on" and capabilities.switch.switch.on() or capabilities.switch.switch.off())
end

return M
