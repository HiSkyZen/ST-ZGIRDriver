-- Infer only from labeled, single-variable differences. Positions are 1-based
-- across the concatenated wire-order frames; linear positions are LSB first.
local M = {}
local NIL_VALUE = {}
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

-- Typed, length-delimited labels replace canonical JSON in analysis loops.
function M.signature(state, except)
  local out = {}
  local function add(value)
    local kind = type(value)
    if kind == "nil" then out[#out + 1] = "-"
    elseif kind == "boolean" then out[#out + 1] = value and "t" or "f"
    elseif kind == "number" then
      local integer = math.tointeger(value)
      out[#out + 1] = "n" .. (integer and tostring(integer) or string.format("%.17g", value)) .. ";"
    elseif kind == "string" then out[#out + 1] = #value .. ":" .. value
    else error("invalid state label") end
  end
  add(state.power)
  for _, name in ipairs(M.NAMES) do if name ~= except then add(state[name]) end end
  return table.concat(out)
end

local function isolated_changes(samples, name, excluded, work)
  local groups, positions, pairs_found = {}, {}, 0
  for _, s in ipairs(samples) do
    local label = M.signature(s.state, name)
    local group = groups[label]
    if not group then group = { samples = {}, counts = {} }; groups[label] = group end
    local key = s.state[name]
    if key == nil then key = NIL_VALUE end
    local count = group.counts[key] or 0
    pairs_found = pairs_found + #group.samples - count
    group.counts[key] = count + 1
    group.samples[#group.samples + 1] = s
    if work and not work:step(#M.NAMES) then return nil, "budget" end
  end
  for _, group in pairs(groups) do
    -- In a group with two labels, every differing bit participates in at least
    -- one cross-label pair. Compare to one representative instead of all pairs.
    if next(group.counts, next(group.counts)) ~= nil then
      local first = group.samples[1].bits
      for i = 2, #group.samples do
        local bits = group.samples[i].bits
        for p, bit in ipairs(first) do
          if bit ~= bits[p] and not excluded[p] then positions[p] = true end
        end
        if work and not work:step(#first) then return nil, "budget" end
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

local function infer_temp(samples, constraints, excluded, occupied, work)
  local changed, pairs_found = isolated_changes(samples, "temp", excluded, work)
  if not changed then return nil, pairs_found end
  local temps, count = {}, 0
  for _, s in ipairs(samples) do
    if not temps[s.state.temp] then temps[s.state.temp] = true; count = count + 1 end
  end
  if count < 3 or pairs_found < 2 then return nil, "need independent temperature anchors" end
  if next(changed) == nil then return { kind = "ignored", positions = {} } end
  local second
  for i = 2, #samples do if samples[i].state.temp ~= samples[1].state.temp then second = samples[i]; break end end
  if not second then return nil, "temperature constant" end
  local regions, covered, remaining = {}, {}, 0
  for _ in pairs(changed) do remaining = remaining + 1 end
  -- The old selection sorted by width/start/order. Accept the first fitting
  -- window immediately, retaining every fitting order for that same window.
  -- Later overlapping windows could never be selected; do not evaluate them.
  for width = 1, math.min(12, #samples[1].bits) do
    for start = 1, #samples[1].bits - width + 1 do
      if work and not work:step(width) then return nil, "budget" end
      local valid, relevant = true, false
      for p = start, start + width - 1 do
        if covered[p] or excluded[p] or occupied[p] then valid = false; break end
        if changed[p] then relevant = true end
      end
      if valid and relevant then
        local fits_here = {}
        for _, positions in ipairs(orders(start, width)) do
          local v1, v2 = value_at(samples[1].bits, positions), value_at(second.bits, positions)
          local slope = (v2 - v1) / (second.state.temp - samples[1].state.temp)
          local intercept, fits = v1 - slope * samples[1].state.temp, slope ~= 0
          if fits then
            for _, s in ipairs(samples) do
              if work and not work:step(width) then return nil, "budget" end
              if math.abs(value_at(s.bits, positions) - (slope * s.state.temp + intercept)) > 0.000001 then fits = false; break end
            end
          end
          if fits then
            local minimum, maximum, step = constraints.min_temp, constraints.max_temp, constraints.step
            for k = 0, math.floor((maximum - minimum) / step + 0.000001) do
              local value = slope * (minimum + k * step) + intercept
              if value < -0.000001 or value > (1 << width) - 1 + 0.000001
                or math.abs(value - math.floor(value + 0.5)) > 0.000001 then fits = false; break end
            end
          end
          if fits then fits_here[#fits_here + 1] = { positions = positions, a = slope, b = intercept } end
        end
        if #fits_here > 0 then
          local primary = fits_here[1]
          regions[#regions + 1] = { positions = primary.positions, a = primary.a, b = primary.b, alternatives = fits_here }
          for _, p in ipairs(primary.positions) do
            covered[p], occupied[p] = true, true
            if changed[p] then remaining = remaining - 1 end
          end
          if remaining == 0 then return { kind = "linear", regions = regions, evidence = count } end
        end
      end
    end
  end
  return nil, "temperature changes not linear"
end

function M.infer(samples, constraints, excluded, work)
  if type(samples) ~= "table" or #samples == 0 or type(constraints) ~= "table" then return nil, "invalid samples" end
  local excluded_bits = {}
  for p, value in pairs(excluded or {}) do excluded_bits[tonumber(p) or p] = value end
  excluded = excluded_bits
  local result, occupied, report = {}, {}, { unknown = {}, confounded = {} }
  if constraints.min_temp == constraints.max_temp then
    result.temp = { kind = "fixed", value = constraints.min_temp, positions = {} }
  else
    local temp_occupied = {}
    local field, reason = infer_temp(samples, constraints, excluded, temp_occupied, work)
    if reason == "budget" then return nil, reason end
    if field then occupied = temp_occupied end
    result.temp = field
    if not field then report.unknown.temp = reason end
  end
  for _, name in ipairs(M.NAMES) do
    if name ~= "temp" then
      local changed, independent = isolated_changes(samples, name, excluded, work)
      if not changed then return nil, independent end
      local positions, values, seen = {}, {}, {}
      for _, s in ipairs(samples) do seen[M.key(s.state[name])] = true end
      local category_count = 0; for _ in pairs(seen) do category_count = category_count + 1 end
      for p in pairs(changed) do
        if work and not work:step(#samples) then return nil, "budget" end
        if not occupied[p] then
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
        for _, p in ipairs(positions) do occupied[p] = true end
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
