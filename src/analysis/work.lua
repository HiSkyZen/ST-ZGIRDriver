-- Per-call cooperative work control. No active/global budget crosses a yield.
local M = {}
local yield_hook
local Work = {}
Work.__index = Work

function M.set_yield(fn)
  if fn ~= nil and type(fn) ~= "function" then return nil, "invalid yield hook" end
  yield_hook = fn
  return true
end

function M.budget(value)
  if value == nil then return 20 end
  if type(value) ~= "number" or value ~= value or value < 0 or value == math.huge then
    return nil, "invalid budget"
  end
  return value
end

function M.new(seconds)
  return setmetatable({ started = os.time(), budget = seconds, pending = 0,
    units = 0, yields = 0, hook = yield_hook }, Work)
end

function Work:check()
  if self.expired or os.time() - self.started >= self.budget then
    self.expired = true
    return false
  end
  return true
end

-- Charge batches of bit/pulse/candidate visits, avoiding a clock call per bit.
function Work:step(units, retain_raw)
  self.units = self.units + units
  self.pending = self.pending + units
  if self.pending < 2048 then return not self.expired end
  self.pending = 0
  local within = self:check()
  if not within and not retain_raw then return false end
  if self.hook then
    -- A caller hook cannot turn a valid learner into an input exception.
    pcall(self.hook)
    self.yields = self.yields + 1
  end
  return self:check()
end

return M
