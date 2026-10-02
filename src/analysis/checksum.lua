-- Checksum hypotheses are data. Generation refuses disagreement between them.
local M = {}

local function read(bits, start, width, order)
  local value = 0
  for i = 0, width - 1 do
    local b = bits[start + i]
    if b ~= 0 and b ~= 1 then return nil end
    value = value | (b << (order == "msb" and width - i - 1 or i))
  end
  return value
end
M.read = read

local function base(rule, bits)
  local width = rule.kind == "sum_nibbles" and 4 or 8
  local value = 0
  if rule.kind == "complement" then
    local v = read(bits, rule.out_start - rule.width, rule.width, rule.input_order)
    if v == nil then return nil end
    return (~v) & ((1 << rule.width) - 1)
  end
  for start = 1, rule.out_start - 1, width do
    local count = math.min(width, rule.out_start - start)
    local v = read(bits, start, count, rule.input_order)
    if v == nil then return nil end
    if rule.kind == "xor" then value = value ~ v else value = value + v end
  end
  if rule.negate then value = -value end
  return value & ((1 << rule.width) - 1)
end

function M.value(rule, bits)
  if type(rule) ~= "table" or type(bits) ~= "table" or (rule.width ~= 4 and rule.width ~= 8)
    or math.type(rule.out_start) ~= "integer" or rule.out_start < 1 or rule.out_start + rule.width - 1 > #bits then
    return nil, "invalid checksum rule"
  end
  if rule.kind ~= "sum_bytes" and rule.kind ~= "sum_nibbles" and rule.kind ~= "xor" and rule.kind ~= "complement" then
    return nil, "unknown checksum"
  end
  local v = base(rule, bits)
  if v == nil or math.type(rule.offset) ~= "integer" then return nil, "invalid checksum data" end
  local mask = (1 << rule.width) - 1
  if rule.kind == "xor" then return (v ~ rule.offset) & mask end
  return (v + rule.offset) & mask
end

function M.predicted_bits(rule, bits)
  local value, err = M.value(rule, bits)
  if value == nil then return nil, err end
  local out = {}
  for i = 0, rule.width - 1 do out[i + 1] = (value >> (rule.output_order == "msb" and rule.width - 1 - i or i)) & 1 end
  return out
end

function M.apply(check, bits)
  if type(check) ~= "table" or type(bits) ~= "table" then return nil, "invalid checksum" end
  if check.kind == "constant" then return true end
  if not check.verified or type(check.candidates) ~= "table" or #check.candidates == 0 then return nil, "checksum unverified" end
  local predicted
  for _, rule in ipairs(check.candidates) do
    local value, err = M.predicted_bits(rule, bits)
    if not value then return nil, err end
    if predicted then
      for i, b in ipairs(value) do if b ~= predicted[i] then return nil, "checksum ambiguous" end end
    else predicted = value end
  end
  local start = check.candidates[1].out_start
  for i, bit in ipairs(predicted) do bits[start + i - 1] = bit end
  return true
end

local function infer_impl(samples)
  if type(samples) ~= "table" or #samples == 0 then return nil, "no checksum samples" end
  local first = samples[1].bits or samples[1]
  if type(first) ~= "table" then return nil, "invalid bits" end
  local n, unique, values = #first, {}, 0
  for _, sample in ipairs(samples) do
    local bits = sample.bits or sample
    if type(bits) ~= "table" or #bits ~= n then return nil, "checksum length mismatch" end
    local key = table.concat(bits)
    if not unique[key] then unique[key] = true; values = values + 1 end
  end
  if values == 1 then return { kind = "constant", verified = true, candidates = {} } end
  if values < 3 then return { verified = false, candidates = {}, reason = "need three payloads" } end
  for _, width in ipairs({ 8, 4 }) do
    local candidates = {}
    local start = n - width + 1
    if start > width then
      for _, kind in ipairs({ "sum_bytes", "sum_nibbles", "xor", "complement" }) do
        local unit = kind == "sum_nibbles" and 4 or 8
        -- A 4-bit checksum can follow a partial final payload byte.
        if kind == "complement" or (start - 1) % unit == 0 or (start - 1) % unit == 4 then
          for _, input in ipairs({ "lsb", "msb" }) do
            for _, output in ipairs({ "lsb", "msb" }) do
              for _, negate in ipairs({ false, true }) do
                if not negate or kind == "sum_bytes" or kind == "sum_nibbles" then
                  local rule = { kind = kind, width = width, out_start = start,
                    input_order = input, output_order = output, negate = negate, offset = 0 }
                  local v = base(rule, first)
                  local expected = read(first, start, width, output)
                  if v ~= nil and expected ~= nil then
                    rule.offset = kind == "xor" and (v ~ expected) or ((expected - v) & ((1 << width) - 1))
                    local valid, seen = true, {}
                    for _, sample in ipairs(samples) do
                      local bits = sample.bits or sample
                      local actual = read(bits, start, width, output)
                      if M.value(rule, bits) ~= actual then valid = false; break end
                      seen[tostring(actual)] = true
                    end
                    local varied = 0; for _ in pairs(seen) do varied = varied + 1 end
                    if valid and varied >= 2 then candidates[#candidates + 1] = rule end
                  end
                end
              end
            end
          end
        end
      end
    end
    if #candidates > 0 then return { verified = true, candidates = candidates, width = width, out_start = start } end
  end
  return { verified = false, candidates = {}, reason = "no validated checksum" }
end

function M.infer(samples)
  local ok, value, err = pcall(infer_impl, samples)
  if not ok then return nil, "invalid checksum samples" end
  return value, err
end

-- Confirm hypotheses from a representative study against the complete codebook.
function M.validate(check, samples)
  if type(check) ~= "table" or type(samples) ~= "table" or #samples == 0 then return nil, "invalid checksum evidence" end
  if check.kind == "constant" then
    local first = samples[1].bits or samples[1]
    for _, sample in ipairs(samples) do
      local bits = sample.bits or sample
      if #bits ~= #first then return { verified = false, candidates = {}, reason = "frame changed" } end
      for i, bit in ipairs(bits) do
        if bit ~= first[i] then return { verified = false, candidates = {}, reason = "frame changed" } end
      end
    end
    return check
  end
  local candidates = {}
  for _, rule in ipairs(check.candidates or {}) do
    local valid = true
    for _, sample in ipairs(samples) do
      local bits = sample.bits or sample
      if M.value(rule, bits) ~= read(bits, rule.out_start, rule.width, rule.output_order) then valid = false; break end
    end
    if valid then candidates[#candidates + 1] = rule end
  end
  return { verified = #candidates > 0, candidates = candidates, out_start = check.out_start, width = check.width,
    reason = #candidates == 0 and "no checksum survives full evidence" or nil }
end

-- Keep malformed externally supplied tables from throwing at the pure API boundary.
for name, fn in pairs(M) do
  if type(fn) == "function" then
    local call = fn
    M[name] = function(...)
      local ok, value, err = pcall(call, ...)
      if not ok then return nil, "invalid analyzer input" end
      return value, err
    end
  end
end

return M
