-- Infer only from labeled, single-variable differences. Positions are 1-based
-- across the concatenated wire-order frames; linear positions are LSB first.
local M = {}
M.NAMES = { "temp", "mode", "fan", "swing", "turbo", "eco", "sleep", "display" }

function M.key(value)
  if value == nil then return "-" end
  return tostring(value)
end

function M.same_except(a, b, name)
  if type(a) ~= "table" or type(b) ~= "table" then return false end
  if a.power ~= b.power then return false end
  for _, key in ipairs(M.NAMES) do if key ~= name and a[key] ~= b[key] then return false end end
  return true
end

local function isolated_changes(samples, name, excluded)
  local positions, pairs_found = {}, 0
  for i = 1, #samples do
    for j = i + 1, #samples do
      local a, b = samples[i], samples[j]
      if a.state[name] ~= b.state[name] and M.same_except(a.state, b.state, name) then
        pairs_found = pairs_found + 1
        for p, bit in ipairs(a.bits) do if bit ~= b.bits[p] and not excluded[tostring(p)] then positions[p] = true end end
      end
    end
  end
  return positions, pairs_found
end

local function value_at(bits, positions)
  local value = 0
  for i, p in ipairs(positions) do value = value | (bits[p] << (i - 1)) end
  return value
end

local function orders(start, width)
  local out, seen = {}, {}
  for variant = 1, 4 do
    local positions = {}
    for i = 0, width - 1 do
      local j = i
      if variant == 2 then j = width - 1 - i
      elseif variant == 3 and width % 4 == 0 then j = (i // 4) * 4 + 3 - i % 4
      elseif variant == 4 and width % 4 == 0 then j = (width // 4 - 1 - i // 4) * 4 + i % 4 end
      positions[i + 1] = start + j
    end
    local key = table.concat(positions, ",")
    if not seen[key] then out[#out + 1] = positions; seen[key] = true end
  end
  return out
end

local function infer_temp(samples, constraints, excluded, occupied)
  local changed, pairs_found = isolated_changes(samples, "temp", excluded)
  local temps, count = {}, 0
  for _, s in ipairs(samples) do
    if not temps[tostring(s.state.temp)] then temps[tostring(s.state.temp)] = true; count = count + 1 end
  end
  if count < 3 or pairs_found < 2 then return nil, "need independent temperature anchors" end
  local second
  for i = 2, #samples do if samples[i].state.temp ~= samples[1].state.temp then second = samples[i]; break end end
  if not second then return nil, "temperature constant" end
  local candidates = {}
  for width = 1, math.min(12, #samples[1].bits) do
    for start = 1, #samples[1].bits - width + 1 do
      local valid, relevant = true, false
      for p = start, start + width - 1 do
        if excluded[tostring(p)] or occupied[tostring(p)] then valid = false; break end
        if changed[p] then relevant = true end
      end
      if valid and relevant then
        for _, positions in ipairs(orders(start, width)) do
          local v1, v2 = value_at(samples[1].bits, positions), value_at(second.bits, positions)
          local a = (v2 - v1) / (second.state.temp - samples[1].state.temp)
          local b, fits = v1 - a * samples[1].state.temp, a ~= 0
          for _, s in ipairs(samples) do
            if math.abs(value_at(s.bits, positions) - (a * s.state.temp + b)) > 0.000001 then fits = false; break end
          end
          if fits then
            local minimum, maximum, step = constraints.min_temp, constraints.max_temp, constraints.step
            for k = 0, math.floor((maximum - minimum) / step + 0.000001) do
              local value = a * (minimum + k * step) + b
              if value < -0.000001 or value > (1 << width) - 1 + 0.000001 or math.abs(value - math.floor(value + 0.5)) > 0.000001 then fits = false; break end
            end
          end
          if fits then candidates[#candidates + 1] = { positions = positions, a = a, b = b, width = width } end
        end
      end
    end
  end
  local regions, covered = {}, {}
  for _, candidate in ipairs(candidates) do
    local relevant, overlaps = false, false
    for _, p in ipairs(candidate.positions) do
      if covered[p] then overlaps = true end
      if changed[p] and not covered[p] then relevant = true end
    end
    if relevant and not overlaps then
      local alternatives = {}
      for _, other in ipairs(candidates) do
        if other.width == candidate.width then
          local same = true
          for _, p in ipairs(other.positions) do
            local found = false; for _, q in ipairs(candidate.positions) do if p == q then found = true; break end end
            if not found then same = false; break end
          end
          if same then alternatives[#alternatives + 1] = other end
        end
      end
      -- Alternatives above are distinct plain tables; avoid a self-reference.
      local primary = { positions = candidate.positions, a = candidate.a, b = candidate.b, alternatives = {} }
      for _, alt in ipairs(alternatives) do primary.alternatives[#primary.alternatives + 1] = { positions = alt.positions, a = alt.a, b = alt.b } end
      regions[#regions + 1] = primary
      for _, p in ipairs(candidate.positions) do covered[p] = true; occupied[tostring(p)] = true end
    end
  end
  for p in pairs(changed) do if not covered[p] then return nil, "temperature changes not linear" end end
  if #regions == 0 then
    -- A temperature ignored by the protocol needs multiple isolated anchors too.
    if next(changed) == nil then return { kind = "ignored", positions = {} } end
    return nil, "no temperature range"
  end
  return { kind = "linear", regions = regions, evidence = count }
end

function M.infer(samples, constraints, excluded)
  if type(samples) ~= "table" or #samples == 0 or type(constraints) ~= "table" then return nil, "invalid samples" end
  excluded = excluded or {}
  local result, occupied, report = {}, {}, { unknown = {}, confounded = {} }
  if constraints.min_temp == constraints.max_temp then
    result.temp = { kind = "fixed", value = constraints.min_temp, positions = {} }
  else
    local temp_occupied = {}
    local field, reason = infer_temp(samples, constraints, excluded, temp_occupied)
    if field then occupied = temp_occupied end
    result.temp = field
    if not field then report.unknown.temp = reason end
  end
  for _, name in ipairs(M.NAMES) do
    if name ~= "temp" then
      local changed, independent = isolated_changes(samples, name, excluded)
      local positions, values, seen = {}, {}, {}
      for _, s in ipairs(samples) do seen[M.key(s.state[name])] = true end
      local category_count = 0; for _ in pairs(seen) do category_count = category_count + 1 end
      for p in pairs(changed) do
        if not occupied[tostring(p)] then
          local by_value, predictive = {}, true
          for _, s in ipairs(samples) do
            local key = M.key(s.state[name])
            if by_value[key] ~= nil and by_value[key] ~= s.bits[p] then predictive = false; break end
            by_value[key] = s.bits[p]
          end
          if predictive then positions[#positions + 1] = p end
        end
      end
      table.sort(positions)
      local complete_difference = true
      for p in pairs(changed) do
        local found = false; for _, q in ipairs(positions) do if p == q then found = true; break end end
        if not found then complete_difference = false; break end
      end
      if category_count == 1 or (independent > 0 and complete_difference) then
        for _, s in ipairs(samples) do
          local a = {}; for _, p in ipairs(positions) do a[#a + 1] = s.bits[p] end
          values[M.key(s.state[name])] = a
        end
        result[name] = { kind = "table", positions = positions, values = values, evidence = category_count }
        for _, p in ipairs(positions) do occupied[tostring(p)] = true end
      else report.unknown[name] = "need an independent change"; report.confounded[#report.confounded + 1] = name end
    end
  end
  return result, report
end

local function positions_valid(positions)
  if type(positions) ~= "table" then return false end
  local count, seen = 0, {}
  for k, p in pairs(positions) do
    if math.type(k) ~= "integer" or k < 1 or k > #positions or math.type(p) ~= "integer" or p < 1 or seen[p] then return false end
    count = count + 1; seen[p] = true
  end
  return count == #positions
end

local function linear_bits(region, temp)
  if type(region) ~= "table" or type(temp) ~= "number" or temp ~= temp or not positions_valid(region.positions)
    or #region.positions > 12 or type(region.a) ~= "number" or type(region.b) ~= "number" then return nil, "invalid temperature" end
  local value = region.a * temp + region.b
  local integer = math.tointeger(math.floor(value + 0.5))
  if not integer or math.abs(value - integer) > 0.000001 or integer < 0 or integer >= 1 << #region.positions then return nil, "temperature out of range" end
  local out = {}
  for i, p in ipairs(region.positions) do out[tostring(p)] = (integer >> (i - 1)) & 1 end
  return out
end

function M.patch(field, value)
  if type(field) ~= "table" then return nil, "field unknown" end
  local out = {}
  if field.kind == "linear" then
    if type(field.regions) ~= "table" then return nil, "invalid linear field" end
    for _, region in ipairs(field.regions) do
      local bits, err = linear_bits(region, value)
      if not bits then return nil, err end
      for _, alt in ipairs(region.alternatives or {}) do
        local other = linear_bits(alt, value)
        if not other then return nil, "temperature ambiguous" end
        for p, bit in pairs(bits) do if bit ~= other[p] then return nil, "temperature ambiguous" end end
      end
      for p, bit in pairs(bits) do out[p] = bit end
    end
  elseif field.kind == "table" then
    local bits = type(field.values) == "table" and field.values[M.key(value)]
    if type(bits) ~= "table" then return nil, "category unknown" end
    if not positions_valid(field.positions) or #bits ~= #field.positions then return nil, "invalid categorical field" end
    for i, p in ipairs(field.positions) do
      if bits[i] ~= 0 and bits[i] ~= 1 then return nil, "invalid categorical bit" end
      out[tostring(p)] = bits[i]
    end
  elseif field.kind == "fixed" then
    if field.value ~= value then return nil, "fixed field mismatch" end
  elseif field.kind ~= "ignored" then return nil, "field is raw-only" end
  return out
end

function M.apply(model_fields, bits, state, partial)
  if type(model_fields) ~= "table" or type(bits) ~= "table" or type(state) ~= "table" then return nil, "invalid fields" end
  local skipped = {}
  for _, name in ipairs(M.NAMES) do
    local patch, err = M.patch(model_fields[name], state[name])
    if not patch then
      if not partial then return nil, name .. ": " .. err end
      skipped[#skipped + 1] = name
    else
      for p, bit in pairs(patch) do
        local index = tonumber(p)
        if math.type(index) ~= "integer" or index < 1 or index > #bits or (bit ~= 0 and bit ~= 1) then return nil, "invalid field position" end
        bits[index] = bit
      end
    end
  end
  return true, skipped
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
