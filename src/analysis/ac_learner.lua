-- Differential AC learner. Learners have methods; all persisted data is plain.
local util = require "util"
local signal = require "ir.signal"
local native = require "ir.native"
local timings = require "analysis.timings"
local symbols = require "analysis.symbols"
local diff = require "analysis.diff"
local fields = require "analysis.fields"
local checksum = require "analysis.checksum"
local work_control = require "analysis.work"
local M, Learner = {}, {}
Learner.__index = Learner
function M.set_yield(fn) return work_control.set_yield(fn) end
local FLAGS = { "turbo", "eco", "sleep", "display" }
local DEFAULT_FLAGS = { turbo = false, eco = false, sleep = false, display = true }

local function protect(fn, ...)
  local ok, a, b = pcall(fn, ...)
  if not ok then return nil, "invalid input" end
  return a, b
end

local function plain(value, stack, depth)
  local kind = type(value)
  if kind == "nil" or kind == "boolean" or kind == "string" then return value end
  if kind == "number" then
    if value ~= value or value == math.huge or value == -math.huge then error("nonfinite number") end
    return value
  end
  if kind ~= "table" or getmetatable(value) ~= nil then error("not plain data") end
  stack, depth = stack or {}, (depth or 0) + 1
  if depth > 32 or stack[value] then error("cyclic data") end
  stack[value] = true
  local numeric, named, maximum = 0, 0, 0
  for k in pairs(value) do
    if type(k) == "string" then named = named + 1
    elseif math.type(k) == "integer" and k >= 1 then numeric = numeric + 1; maximum = math.max(maximum, k)
    else error("invalid key") end
  end
  if numeric > 0 and (named > 0 or numeric ~= maximum) then error("not a JSON array") end
  local out = {}
  for k, v in pairs(value) do
    if type(k) ~= "string" and (math.type(k) ~= "integer" or k < 1) then error("invalid key") end
    out[k] = plain(v, stack, depth)
  end
  stack[value] = nil
  return out
end

local function constraints(input)
  input = input or {}
  if type(input) ~= "table" then return nil, "invalid constraints" end
  local c = { min_temp = input.min_temp or 16, max_temp = input.max_temp or 30, step = input.step or 1 }
  for _, k in ipairs({ "min_temp", "max_temp", "step" }) do
    local v = c[k]
    if type(v) ~= "number" or v ~= v or math.abs(v) == math.huge then return nil, "invalid temperature constraints" end
  end
  if c.step <= 0 or c.min_temp > c.max_temp or (c.max_temp - c.min_temp) / c.step > 256 then return nil, "invalid temperature range" end
  local defaults = { modes = { "cool", "heat", "dry", "fan", "auto" }, fan_modes = { "auto", "low", "medium", "high" }, swing_modes = { "off", "on" } }
  for _, name in ipairs({ "modes", "fan_modes", "swing_modes" }) do
    local a = input[name] or defaults[name]
    if type(a) ~= "table" or #a > 16 or (name == "modes" and #a == 0) then return nil, "invalid " .. name end
    c[name] = {}
    local seen = {}
    for _, v in ipairs(a) do
      if type(v) ~= "string" or #v == 0 or #v > 32 or v:find("|", 1, true) or seen[v] then return nil, "invalid " .. name end
      c[name][#c[name] + 1], seen[v] = v, true
    end
  end
  return c
end

local function contains(a, value)
  if #a == 0 then return value == nil end
  for _, v in ipairs(a) do if value == v then return true end end
  return false
end

local function normalize(state, c)
  if type(state) ~= "table" then return nil, "invalid state" end
  local out = plain(state)
  out.power = out.power or "on"
  if out.power ~= "on" and out.power ~= "off" then return nil, "invalid power" end
  for _, name in ipairs(FLAGS) do
    if out[name] == nil then out[name] = DEFAULT_FLAGS[name] end
    if type(out[name]) ~= "boolean" then return nil, "invalid " .. name end
  end
  if out.power == "off" then
    -- Off labels have no meaningful mode/temperature dimensions.
    return { power = "off", turbo = out.turbo, eco = out.eco, sleep = out.sleep, display = out.display }
  end
  if type(out.mode) ~= "string" or not contains(c.modes, out.mode) then return nil, "mode outside constraints" end
  if not contains(c.fan_modes, out.fan) then return nil, "fan outside constraints" end
  if not contains(c.swing_modes, out.swing) then return nil, "swing outside constraints" end
  local temp = out.temp
  if type(temp) ~= "number" or temp ~= temp or temp < c.min_temp or temp > c.max_temp then return nil, "temperature outside constraints" end
  local steps = (temp - c.min_temp) / c.step
  if math.abs(steps - math.floor(steps + 0.5)) > 0.000001 then return nil, "temperature off step" end
  local result = { power = "on", mode = out.mode, fan = out.fan, swing = out.swing, temp = temp }
  for _, name in ipairs(FLAGS) do result[name] = out[name] end
  return result
end

local function state_key(state)
  if type(state) ~= "table" then return nil, "invalid state" end
  if state.power == "off" then return "off" end
  if state.power ~= nil and state.power ~= "on" then return nil, "invalid power" end
  if type(state.mode) ~= "string" or #state.mode == 0 or state.mode:find("|", 1, true)
    or type(state.temp) ~= "number" or state.temp ~= state.temp or math.abs(state.temp) == math.huge then return nil, "invalid state" end
  for _, k in ipairs({ "fan", "swing" }) do
    if state[k] ~= nil and (type(state[k]) ~= "string" or state[k]:find("|", 1, true)) then return nil, "invalid " .. k end
  end
  return state.mode .. "|" .. (state.fan or "-") .. "|" .. (state.swing or "-") .. "|" .. string.format("%g", state.temp)
end
function M.state_key(state) return protect(state_key, state) end

local function baseline(c)
  local function preferred(a, value)
    for _, v in ipairs(a) do if v == value then return v end end
    return a[1]
  end
  local k = math.floor((24 - c.min_temp) / c.step + 0.5)
  local temp = math.max(c.min_temp, math.min(c.min_temp + math.floor((c.max_temp - c.min_temp) / c.step) * c.step, c.min_temp + k * c.step))
  return { power = "on", mode = preferred(c.modes, "cool"), fan = preferred(c.fan_modes, "auto"),
    swing = preferred(c.swing_modes, "off"), temp = temp, turbo = false, eco = false, sleep = false, display = true }
end

local function new(opts)
  if opts ~= nil and type(opts) ~= "table" then return nil, "invalid options" end
  local c, err = constraints(opts and opts.constraints)
  if not c then return nil, err end
  local budget, berr = work_control.budget(opts and opts.budget_sec)
  if not budget then return nil, berr end
  return setmetatable({ constraints = c, samples = {}, raw_only = {}, budget_sec = budget,
    _revision = 0, _cache = {}, _params = {}, _param_counts = {}, _captured = {} }, Learner)
end
function M.new(opts) return protect(new, opts) end

local function canonical_copy(sig)
  local copy = plain(sig)
  if type(copy) ~= "table" or (copy.repeat_count ~= nil and (math.type(copy.repeat_count) ~= "integer" or copy.repeat_count < 0 or copy.repeat_count > 16)) then
    return nil, "invalid signal"
  end
  local valid, err = signal.validate(copy)
  if not valid then return nil, err end
  return copy
end

local function add_sample(self, state, sig)
  local normalized, err = normalize(state, self.constraints)
  if not normalized then return nil, err end
  local copy, verr = canonical_copy(sig)
  if not copy then return nil, verr end
  if #self.samples >= 4096 then return nil, "sample limit reached" end
  local label = fields.signature(normalized)
  self.samples[#self.samples + 1] = { state = normalized, sig = copy }
  self._captured[label] = true
  self._revision = self._revision + 1
  self._request_revision = nil
  if self.model then self._previous_model = self.model end
  self.model, self.report = nil, nil
  return true
end
function Learner:add_sample(state, sig) return protect(add_sample, self, state, sig) end

local function frame_bits(model, bits)
  local out = {}
  for _, frame in ipairs(model.frames) do
    local a = {}
    for i = 1, frame.params.bit_count do a[i] = bits[frame.offset + i] end
    out[#out + 1] = a
  end
  return out
end

local function patched(model, state, base_bits, partial)
  if type(model) ~= "table" or model.schema ~= 1 or type(model.frames) ~= "table" or type(model.template) ~= "table" or type(model.fields) ~= "table" then
    return nil, "invalid model"
  end
  local source, bits = base_bits or model.template, {}
  for i, bit in ipairs(source) do
    if bit ~= 0 and bit ~= 1 then return nil, "invalid model bits" end
    bits[i] = bit
  end
  local ok, skipped = fields.apply(model.fields, bits, state, partial)
  if not ok then return nil, skipped end
  local frames = frame_bits(model, bits)
  for f, a in ipairs(frames) do
    local valid, err = checksum.apply(model.frames[f].checksum, a)
    if not valid then return nil, err end
  end
  return frames, skipped
end

local function render(model, frames)
  local out = {}
  for f, bits in ipairs(frames) do
    local frame = model.frames[f]
    local a, err = symbols.encode_bits(frame.params, bits)
    if not a then return nil, err end
    if #out % 2 == 1 then return nil, "missing inter-frame space" end
    for _, v in ipairs(a) do out[#out + 1] = v end
    local gap = frame.gap_us or 0
    if gap > 0 then
      if #out % 2 == 0 then return nil, "gap after space unsupported" end
      out[#out + 1] = math.min(65535, gap)
    elseif f < #frames and #out % 2 == 1 then out[#out + 1] = signal.FRAME_GAP_US end
  end
  local sig = signal.new(model.carrier_hz or 38000, out, { source = { format = "ac_model" } })
  local ok, err = signal.validate(sig)
  if not ok then return nil, err end
  return sig
end

local function encode(model, state)
  if type(model) ~= "table" then return nil, "invalid model" end
  local c, err = constraints(model.constraints)
  if not c then return nil, err end
  local s, serr = normalize(state, c)
  if not s then return nil, serr end
  if s.power == "off" then
    if model.off_sig then
      return canonical_copy(model.off_sig)
    end
    return nil, "power field unknown"
  end
  if type(model.template) ~= "table" or #model.template == 0 or model.unexplained ~= 0 or not model.checksum_verified or model.training_verified ~= true then return nil, "model incomplete" end
  local frames, ferr = patched(model, s)
  if not frames then return nil, ferr end
  return render(model, frames)
end
function M.encode(model, state) return protect(encode, model, state) end

local function coverage(model, c)
  local missing = {}
  local domains = { mode = c.modes, fan = c.fan_modes, swing = c.swing_modes,
    turbo = { false, true }, eco = { false, true }, sleep = { false, true }, display = { true, false } }
  for name, domain in pairs(domains) do
    local a = {}
    if #domain == 0 then if not fields.patch(model.fields[name], nil) then a[#a + 1] = "-" end end
    for _, v in ipairs(domain) do if not fields.patch(model.fields[name], v) then a[#a + 1] = fields.key(v) end end
    if #a > 0 then missing[name] = a end
  end
  if not model.fields.temp then missing.temp = { "linear range" } end
  return missing
end

-- Bound quadratic field inference while validating every imported sample.
local function study_indices(samples, c, work)
  if #samples <= 128 then local out = {}; for i = 1, #samples do out[i] = i end; return out end
  local desired = baseline(c)
  local function score(state, reference, except)
    local value = 0
    for _, name in ipairs(fields.NAMES) do
      if name ~= except and state[name] ~= reference[name] then
        value = value + (name == "temp" and math.abs(state.temp - reference.temp) or 100)
      end
    end
    return value
  end
  local first, best = 1, nil
  for i, sample in ipairs(samples) do
    if work and not work:step(#fields.NAMES) then return nil, "budget" end
    local value = score(sample.state, desired)
    if not best or value < best then first, best = i, value end
  end
  local out, selected, base = {}, {}, samples[first].state
  local function add(index)
    if index and not selected[index] and #out < 96 then selected[index] = true; out[#out + 1] = index end
  end
  add(first)
  local temps = { base.temp, math.min(c.max_temp, base.temp + c.step), c.min_temp,
    c.min_temp + math.floor((c.max_temp - c.min_temp) / c.step) * c.step }
  for k = 1, 8 do temps[#temps + 1] = c.min_temp + math.floor((c.max_temp - c.min_temp) / c.step * k / 9 + 0.5) * c.step end
  local domains = { temp = temps, mode = c.modes, fan = c.fan_modes, swing = c.swing_modes,
    turbo = { false, true }, eco = { false, true }, sleep = { false, true }, display = { true, false } }
  for _, name in ipairs(fields.NAMES) do
    for _, value in ipairs(domains[name]) do
      local choice, closest = nil, nil
      for i, sample in ipairs(samples) do
        if work and not work:step(#fields.NAMES) then return nil, "budget" end
        if sample.state[name] == value then
          local distance = score(sample.state, base, name)
          if not closest or distance < closest then choice, closest = i, distance end
        end
      end
      add(choice)
    end
  end
  for k = 0, 95 do add(math.floor(k * (#samples - 1) / 95) + 1) end
  return out
end

local function analyze(self, work)
  local report = { status = "raw-only", sample_count = #self.samples, uncertain = {}, raw_only = plain(self.raw_only), checksum_verified = false }
  if not work:check() then report.reason = "budget"; return nil, report end
  local on, off = {}, nil
  for _, sample in ipairs(self.samples) do
    if sample.state.power == "off" then off = sample.sig else on[#on + 1] = sample end
    if not work:step(1) then report.reason = "budget"; return nil, report end
  end
  if #on == 0 then report.reason = "need an on sample"; self.report = report; return nil, report end
  local indices, ierr = study_indices(on, self.constraints, work)
  if not indices then report.reason = ierr; return nil, report end
  report.study_count = #indices
  local split, decoded = {}, {}
  for i, sample in ipairs(on) do
    local cached = self._cache[sample]
    if not cached then
      local parts, err = timings.split(sample.sig, nil, work)
      if not parts then report.reason = err; return nil, report end
      cached = { state = sample.state, label = fields.signature(sample.state), split = parts, frames = {}, params = {} }
      self._cache[sample] = cached
    end
    if i > 1 and #cached.split ~= #split[1] then report.reason = "frame count changes"; return nil, report end
    split[i], decoded[i] = cached.split, cached
  end
  local model = { schema = 1, constraints = plain(self.constraints), frames = {}, fields = {}, template = {},
    carrier_hz = signal.carrier(on[1].sig), off_sig = off and plain(off), checksum_verified = true, training_verified = false }
  local offset = 0
  for f = 1, #split[1] do
    local examples, gaps = {}, {}
    for _, index in ipairs(indices) do
      local a = split[index]
      examples[#examples + 1] = a[f]; if a[f].gap_us > 0 then gaps[#gaps + 1] = a[f].gap_us end
    end
    local params, data = self._params[f], {}
    local function decode_all(p)
      for i, parts in ipairs(split) do
        local cached, frame = decoded[i], decoded[i].frames[f]
        if cached.params[f] ~= p then
          local err
          frame, err = symbols.decode_frame(parts[f].timings_us, p, work, true)
          if not frame then return nil, err end
          frame.timings_us = parts[f].timings_us
          cached.frames[f], cached.params[f], cached.bits = frame, p, nil
        end
        data[i] = frame
        if not work:step(1) then return nil, "budget" end
      end
      return true
    end
    -- Calibrate with the first three on captures before freezing timing centers;
    -- one jittered capture can bias repeated-frame headers in opposite directions.
    local valid = params and (#on > 3 or self._param_counts[f] == #on) and decode_all(params)
    if not valid then
      if work.expired then report.reason = "budget"; return nil, report end
      local err
      params, err = symbols.learn(examples, work, true)
      if not params then report.reason = err; return nil, report end
      local ok, derr = decode_all(params)
      if not ok then report.reason = derr; return nil, report end
      self._params[f], self._param_counts[f] = params, #on
    end
    local previous = self._previous_model
    local old_check = previous and previous.frames[f] and previous.frames[f].checksum
    local check = old_check and old_check.verified and checksum.validate(old_check, data, work)
    if not check or not check.verified then
      local study = {}; for _, index in ipairs(indices) do study[#study + 1] = data[index] end
      local inferred_check = checksum.infer(study, work)
      check = inferred_check and checksum.validate(inferred_check, data, work)
    end
    if not work:check() then report.reason = "budget"; return nil, report end
    if not check or not check.verified then model.checksum_verified = false end
    model.frames[f] = { params = params, offset = offset, gap_us = timings.median(gaps) or 0, checksum = check or { verified = false, candidates = {} } }
    offset = offset + params.bit_count
  end
  for _, s in ipairs(decoded) do
    if not s.bits then s.bits = diff.flatten(s.frames) end
    if not work:step(#s.bits) then report.reason = "budget"; return nil, report end
  end
  model.template = plain(decoded[1].bits)
  local differences, derr = diff.analyze(decoded, work)
  if not differences then report.reason = derr; self.report = report; return nil, report end
  local excluded, known = {}, {}
  for f, frame in ipairs(model.frames) do
    frame.repeat_of = differences.repeat_of[f]
    local check = frame.checksum
    if check.verified and check.kind ~= "constant" then
      for p = check.out_start, check.out_start + check.width - 1 do excluded[tostring(frame.offset + p)], known[tostring(frame.offset + p)] = true, true end
    end
  end
  for _, p in ipairs(differences.toggles) do excluded[tostring(p)] = true end
  local study = {}; for _, index in ipairs(indices) do study[#study + 1] = decoded[index] end
  local inferred, freport = fields.infer(study, self.constraints, excluded, work)
  if not inferred then report.reason = freport; self.report = report; return nil, report end
  model.fields = inferred
  if #differences.toggles > 0 then model.fields.sequence = { kind = "toggle", positions = differences.toggles, raw_only = true } end
  for _, field in pairs(model.fields) do
    if field.kind ~= "toggle" then
      for _, p in ipairs(field.positions or {}) do known[tostring(p)] = true end
      for _, region in ipairs(field.regions or {}) do for _, p in ipairs(region.positions) do known[tostring(p)] = true end end
    end
  end
  model.unexplained = 0
  for _, p in ipairs(differences.changing) do if not known[tostring(p)] then model.unexplained = model.unexplained + 1 end end
  model.constants, model.toggles = differences.constants, differences.toggles
  local trained = model.unexplained == 0 and model.checksum_verified
  if trained then
    for _, sample in ipairs(decoded) do
      if not work:step(#sample.bits) then report.reason = "budget"; return nil, report end
      local frames = patched(model, sample.state)
      if not frames then trained = false; break end
      for f, a in ipairs(frames) do
        if #a ~= #sample.frames[f].bits then trained = false; break end
        for i, b in ipairs(a) do if b ~= sample.frames[f].bits[i] then trained = false; break end end
        if not trained then break end
      end
      if not trained then break end
    end
  end
  model.training_verified = trained
  report.uncertain, report.fields = coverage(model, self.constraints), freport
  report.checksum_verified, report.unexplained, report.toggles = model.checksum_verified, model.unexplained, plain(differences.toggles)
  model.complete = trained and #model.template > 0 and next(report.uncertain) == nil
  report.status = trained and "parametric" or "hybrid"
  if #model.template == 0 or (not model.fields.temp and model.unexplained > 0) then report.status = "raw-only" end
  report.frame_count, report.training_verified = #model.frames, trained
  if not work:check() then report.reason = "budget"; return nil, report end
  self.model, self.report = model, report
  return model, report
end
local function run_analysis(self, budget, work)
  if type(budget) == "table" then budget = budget.budget_sec end
  local seconds, err = work_control.budget(budget == nil and self.budget_sec or budget)
  if not seconds then return nil, { status = "raw-only", reason = err } end
  if self._analysis_revision == self._revision then return self.model, self.report end
  if self._running then return nil, { status = "raw-only", reason = "analysis in progress" } end
  work = work or work_control.new(seconds)
  local revision = self._revision
  self._running = true
  local ok, model, report = pcall(analyze, self, work)
  self._running = nil
  if work.expired then
    model = nil
    report = { status = "raw-only", reason = "budget", sample_count = #self.samples,
      checksum_verified = false, raw_only = plain(self.raw_only), uncertain = {} }
  elseif not ok then
    model, report = nil, { status = "raw-only", reason = "invalid samples" }
  elseif revision ~= self._revision then
    model, report = nil, { status = "raw-only", reason = "samples changed" }
  end
  report.work_units, report.yield_count = work.units, work.yields
  self.model, self.report = model, report
  if report.reason ~= "budget" and report.reason ~= "samples changed" then self._analysis_revision = revision end
  return model, report
end
function Learner:analyze(budget)
  local ok, model, report = pcall(run_analysis, self, budget)
  if not ok then return nil, { status = "raw-only", reason = "invalid samples" } end
  return model, report
end

local function all_states(self)
  local states = {}
  for _, sample in ipairs(self.samples) do if sample.state.power == "on" then states[#states + 1] = sample.state end end
  return states
end
local function captured(self, state)
  return self._captured[fields.signature(state)] == true
end

local KO = { cool = "냉방", heat = "난방", dry = "제습", fan = "송풍", auto = "자동",
  low = "약", medium = "중", high = "강", quiet = "저소음", turbo = "터보", off = "끔", on = "켬",
  vertical = "상하", horizontal = "좌우", both = "상하·좌우" }
local function request(state, reason, name)
  local prompt
  if state.power == "off" then prompt = "리모컨의 전원 끄기 버튼을 눌러 주세요"
  else
    prompt = "리모컨을 " .. (KO[state.mode] or state.mode) .. " · " .. string.format("%g", state.temp) .. "°C"
    if state.fan then prompt = prompt .. " · 바람 " .. (KO[state.fan] or state.fan) end
    if state.swing then prompt = prompt .. " · 스윙 " .. (KO[state.swing] or state.swing) end
    if name == "temp" then prompt = prompt .. " 으로 맞춘 뒤 온도 버튼을 눌러 주세요"
    elseif name == "turbo" or name == "eco" or name == "sleep" or name == "display" then
      local labels = { turbo = "터보", eco = "절전", sleep = "취침", display = "표시등" }
      prompt = prompt .. " 으로 유지하고 " .. labels[name] .. "을 " .. (state[name] and "켜" or "꺼") .. " 주세요"
    else prompt = prompt .. " 으로 맞춘 뒤 해당 버튼을 눌러 주세요" end
  end
  return { state = plain(state), reason = reason, prompt_ko = prompt }
end

local function variations(state, c)
  local out, domains = {}, { mode = c.modes, fan = c.fan_modes, swing = c.swing_modes,
    turbo = { false, true }, eco = { false, true }, sleep = { false, true }, display = { true, false } }
  local temperatures = {}
  for k = 0, math.floor((c.max_temp - c.min_temp) / c.step + 0.000001) do temperatures[#temperatures + 1] = c.min_temp + k * c.step end
  domains.temp = temperatures
  for _, name in ipairs(fields.NAMES) do
    for _, value in ipairs(domains[name]) do
      if value ~= state[name] then local s = plain(state); s[name] = value; out[#out + 1] = { state = s, name = name } end
    end
  end
  return out
end

local function next_request(self)
  if not captured(self, { power = "off", turbo = false, eco = false, sleep = false, display = true }) then
    local has_off = false; for _, s in ipairs(self.samples) do if s.state.power == "off" then has_off = true end end
    if not has_off then return request({ power = "off" }, "capture off frame") end
  end
  local base = baseline(self.constraints)
  if not captured(self, base) then return request(base, "capture baseline") end
  local model, report = self:analyze()
  if report and (report.reason == "budget" or report.reason == "samples changed" or report.reason == "analysis in progress") then return nil, report.reason end
  local states, c = all_states(self), self.constraints
  local seen = {}
  for _, name in ipairs(fields.NAMES) do
    seen[name] = {}; for _, s in ipairs(states) do seen[name][fields.key(s[name])] = true end
  end
  local best, score
  local function offer(s, value, reason, name)
    if not captured(self, s) and (not score or value > score) then best, score = request(s, reason, name), value end
  end
  local anchors = { math.min(c.max_temp, base.temp + c.step), c.min_temp, c.min_temp + math.floor((c.max_temp - c.min_temp) / c.step) * c.step }
  for i, temp in ipairs(anchors) do
    if not seen.temp[fields.key(temp)] or not model or not model.fields.temp then
      local s = plain(base); s.temp = temp
      offer(s, 120 - i, "identify temperature range and carries", "temp")
    end
  end
  local domains = { mode = c.modes, fan = c.fan_modes, swing = c.swing_modes,
    turbo = { false, true }, eco = { false, true }, sleep = { false, true }, display = { true, false } }
  for index, name in ipairs(fields.NAMES) do
    if name ~= "temp" then
      local domain = domains[name]
      for _, value in ipairs(domain) do
        local unknown = not model or not fields.patch(model.fields[name], value)
        if unknown and not self.raw_only[name] then
          local s = plain(base); s[name] = value
          offer(s, (seen[name][fields.key(value)] and 100 or 90) - index, "isolate " .. name .. " mapping", name)
        end
      end
    end
  end
  if best then return best end
  -- A candidate may require a combined state to distinguish SUM from XOR.
  -- Each probe still changes one variable relative to an existing capture.
  if model and model.checksum_verified and model.unexplained == 0 then
    local evaluated = {}
    for _, state in ipairs(states) do
      for _, variation in ipairs(variations(state, c)) do
        if not captured(self, variation.state) then
          local label = fields.signature(variation.state)
          local err = evaluated[label]
          if err == nil then
            local _
            _, err = patched(model, variation.state)
            evaluated[label] = err or false
          end
          if err == "checksum ambiguous" or (type(err) == "string" and err:find("temperature ambiguous", 1, true)) then
            return request(variation.state, "distinguish remaining encoding hypotheses", variation.name)
          end
        end
      end
    end
  end
  -- Exhausted single-variable evidence is an explicit raw-only declaration,
  -- never a reason to discard the captured remote.
  for _, name in ipairs(fields.NAMES) do
    local field = model and model.fields[name]
    if not field then self.raw_only[name] = "not inferable from independent captures" end
    if name ~= "temp" then
      for _, value in ipairs(domains[name]) do if not field or not fields.patch(field, value) then self.raw_only[name] = "category mapping is raw-only" end end
    end
  end
  if not model or report.status == "raw-only" or not model.checksum_verified or model.unexplained > 0 then self.raw_only.protocol = "unverified protocol; use captured codes" end
  if self.report then self.report.raw_only = plain(self.raw_only) end
  return nil
end
function Learner:next_request()
  if self._request_revision == self._revision then return protect(plain, self._request) end
  local result, err = protect(next_request, self)
  if not err and (not self.report or (self.report.reason ~= "budget" and self.report.reason ~= "samples changed")) then
    self._request, self._request_revision = result, self._revision
  end
  return result, err
end

local function export(self)
  return plain({ schema = 1, budget_sec = self.budget_sec, constraints = self.constraints, samples = self.samples, model = self.model, report = self.report, raw_only = self.raw_only })
end
function Learner:export() return protect(export, self) end

local function load(input)
  local data = plain(input)
  if type(data) ~= "table" or data.schema ~= 1 or type(data.samples) ~= "table" or #data.samples > 4096 then return nil, "invalid learner export" end
  local learner, err = new({ constraints = data.constraints, budget_sec = data.budget_sec })
  if not learner then return nil, err end
  for _, sample in ipairs(data.samples) do
    if type(sample) ~= "table" then return nil, "invalid sample" end
    local ok, serr = add_sample(learner, sample.state, sample.sig)
    if not ok then return nil, serr end
  end
  if data.raw_only ~= nil then
    if type(data.raw_only) ~= "table" then return nil, "invalid raw-only report" end
    for k, v in pairs(data.raw_only) do
      if type(k) ~= "string" or type(v) ~= "string" then return nil, "invalid raw-only report" end
    end
  end
  learner.raw_only = data.raw_only or {}
  -- Rebuild from evidence instead of trusting persisted model claims.
  learner:analyze()
  return learner
end
function M.load(input) return protect(load, input) end

local function parse_key(key)
  if key == "off" then return { power = "off" } end
  if type(key) ~= "string" then return nil end
  local parts = util.split(key, "|")
  if #parts ~= 4 or not tonumber(parts[4]) then return nil end
  return { power = "on", mode = parts[1], fan = parts[2] ~= "-" and parts[2] or nil,
    swing = parts[3] ~= "-" and parts[3] or nil, temp = tonumber(parts[4]) }
end

local function from_codebook(c, codebook, opts)
  if opts ~= nil and type(opts) ~= "table" then return nil, "invalid options" end
  local learner, err = new({ constraints = c, budget_sec = opts and opts.budget_sec })
  if not learner then return nil, err end
  if type(codebook) ~= "table" then return nil, "invalid codebook" end
  local work = work_control.new(learner.budget_sec)
  for _, key in ipairs(util.keys_sorted(codebook)) do
    local state = parse_key(key)
    if not state then return nil, "invalid codebook key" end
    local ok, serr = add_sample(learner, state, codebook[key])
    if not ok then return nil, serr end
    -- Retain every raw state even after the analysis deadline.
    work:step(#learner.samples[#learner.samples].sig.timings_us, true)
  end
  local model, report = run_analysis(learner, nil, work)
  if not model or report.status == "raw-only" then learner.raw_only.protocol = "codebook retained without promotion" end
  return learner
end
function M.from_codebook(c, codebook, opts) return protect(from_codebook, c, codebook, opts) end

local function distance(a, b)
  local value = math.abs((a.temp or 24) - (b.temp or 24))
  if a.mode ~= b.mode then value = value + 1000 end
  for _, name in ipairs(fields.NAMES) do if name ~= "temp" and name ~= "mode" and a[name] ~= b[name] then value = value + 20 end end
  return value
end

local function decode_record(rec)
  if type(rec) ~= "table" or type(rec.z) ~= "string" then return nil end
  return protect(native.decode, rec.z, rec.carrier)
end

local function matches_state(input, target)
  if type(input) ~= "table" or (input.power or "on") ~= target.power then return false end
  for _, name in ipairs(FLAGS) do
    local value = input[name]
    if value == nil then value = DEFAULT_FLAGS[name] end
    if value ~= target[name] then return false end
  end
  if target.power == "off" then return true end
  return input.mode == target.mode and input.fan == target.fan and input.swing == target.swing and input.temp == target.temp
end

local function learner_raw(exported, state)
  if type(exported) ~= "table" or type(exported.samples) ~= "table" then return nil end
  local c = constraints(exported.constraints)
  if not c then return nil end
  local target = protect(normalize, state, c)
  if not target then return nil end
  for i = #exported.samples, 1, -1 do
    local sample = exported.samples[i]
    if type(sample) == "table" and matches_state(sample.state, target) then
      local normalized = protect(normalize, sample.state, c)
      if normalized then
        local sig = protect(canonical_copy, sample.sig)
        if sig then return sig end
      end
    end
  end
end

local function hybrid(model, base, target)
  if type(model.frames) ~= "table" or type(model.fields) ~= "table" then return nil end
  for _, name in ipairs(fields.NAMES) do
    if not fields.patch(model.fields[name], target[name]) and base.state[name] ~= target[name] then return nil end
  end
  local sig = base.sig or decode_record(base.rec)
  local parts = sig and timings.split(sig)
  if not parts or #parts ~= #model.frames then return nil end
  local frames = {}
  for f, part in ipairs(parts) do
    local decoded = symbols.decode_frame(part.timings_us, model.frames[f].params, nil, true)
    if not decoded then return nil end
    frames[f] = decoded
  end
  local bits = diff.flatten(frames)
  local changed = patched(model, target, bits, true)
  return changed and render(model, changed)
end

local function resolve(acdef, state)
  if type(acdef) ~= "table" or type(state) ~= "table" then return nil, "invalid definition or state" end
  local model = type(acdef.model) == "table" and acdef.model or nil
  local generated = model and M.encode(model, state)
  if generated then return generated, "parametric" end
  local codebook = type(acdef.codebook) == "table" and acdef.codebook or {}
  local exact_key = state_key(state)
  local raw = (exact_key and decode_record(codebook[exact_key])) or protect(learner_raw, acdef.learner, state)
  local c, err = constraints(acdef.constraints or (model and model.constraints)
    or (type(acdef.learner) == "table" and acdef.learner.constraints))
  if not c then if raw then return raw, "raw" end; return nil, err end
  local target, serr = normalize(state, c)
  if not target then if raw then return raw, "raw" end; return nil, serr end
  if not model or not model.checksum_verified or target.power ~= "on"
    or type(model.toggles) ~= "table" or #model.toggles > 0
    or type(model.frames) ~= "table" or type(model.fields) ~= "table" then
    if raw then return raw, "raw" end
    return nil, "no code for state"
  end
  -- Evaluate target field support once; discard incompatible bases before any
  -- signal decode. Select the nearest base in one pass, sorting only on failure.
  local unsupported = {}
  for _, name in ipairs(fields.NAMES) do if not fields.patch(model.fields[name], target[name]) then unsupported[#unsupported + 1] = name end end
  local bases, best = {}, nil
  local function add_base(s, sig, rec)
    if not s or s.power ~= "on" then return end
    for _, name in ipairs(unsupported) do if s[name] ~= target[name] then return end end
    local base = { state = s, sig = sig, rec = rec, distance = distance(s, target) }
    bases[#bases + 1] = base
    if not best or base.distance < best.distance then best = base end
  end
  if type(acdef.learner) == "table" and type(acdef.learner.samples) == "table" then
    for _, sample in ipairs(acdef.learner.samples) do
      if type(sample) == "table" then add_base(protect(normalize, sample.state, c), sample.sig) end
    end
  end
  for key, rec in pairs(codebook) do
    local s = parse_key(key)
    if s and type(rec) == "table" and type(rec.z) == "string" then add_base(protect(normalize, s, c), nil, rec) end
  end
  if best then
    local result = protect(hybrid, model, best, target)
    if result then return result, "hybrid" end
    table.sort(bases, function(a, b) return a.distance < b.distance end)
    for _, base in ipairs(bases) do
      if base ~= best then
        result = protect(hybrid, model, base, target)
        if result then return result, "hybrid" end
      end
    end
  end
  if raw then return raw, "raw" end
  return nil, "no code for state"
end
function M.resolve(acdef, state)
  local ok, sig, tier = pcall(resolve, acdef, state)
  if ok then return sig, tier end
  -- Last defence for obsolete/corrupt persisted analysis data.
  if type(acdef) == "table" and type(acdef.codebook) == "table" then
    local key = M.state_key(state)
    local raw = key and decode_record(acdef.codebook[key])
    if raw then return raw, "raw" end
  end
  if type(acdef) == "table" then
    local raw = protect(learner_raw, acdef.learner, state)
    if raw then return raw, "raw" end
  end
  return nil, "invalid input"
end

return M
