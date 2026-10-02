-- Capability handles.  Custom capabilities exist only where SmartThings has no
-- standard equivalent (free-form remote keys, learning workflow, packs, bridge).
local capabilities = require "st.capabilities"

local NS = "drumpepper55014" -- SmartThings-assigned namespace of the developer org

local M = {
  NS = NS,
  remote = capabilities[NS .. ".irRemote"],
  learning = capabilities[NS .. ".irLearning"],
  pack = capabilities[NS .. ".irRemotePack"],
  bridge = capabilities[NS .. ".irBridge"],
}

M.REMOTE_ID = NS .. ".irRemote"
M.LEARNING_ID = NS .. ".irLearning"
M.PACK_ID = NS .. ".irRemotePack"
M.BRIDGE_ID = NS .. ".irBridge"

return M
