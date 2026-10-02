-- Small dependency-free helpers shared by all pure modules.
local M = {}

local B64 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
local B64_INV = {}
for i = 1, #B64 do B64_INV[B64:byte(i)] = i - 1 end
B64_INV[("-"):byte()] = 62 -- url-safe alphabet accepted on decode
B64_INV[("_"):byte()] = 63

function M.b64_encode(data)
  local out = {}
  for i = 1, #data, 3 do
    local b1, b2, b3 = data:byte(i, i + 2)
    local n = (b1 << 16) | ((b2 or 0) << 8) | (b3 or 0)
    local rem = #data - i + 1
    out[#out + 1] = B64:sub((n >> 18) + 1, (n >> 18) + 1)
    out[#out + 1] = B64:sub(((n >> 12) & 63) + 1, ((n >> 12) & 63) + 1)
    out[#out + 1] = rem >= 2 and B64:sub(((n >> 6) & 63) + 1, ((n >> 6) & 63) + 1) or "="
    out[#out + 1] = rem >= 3 and B64:sub((n & 63) + 1, (n & 63) + 1) or "="
  end
  return table.concat(out)
end

-- Returns decoded bytes, or nil, err for non-base64 input.  Whitespace ignored.
function M.b64_decode(text)
  if type(text) ~= "string" then return nil, "not a string" end
  local s = text:gsub("%s", ""):gsub("=+$", "")
  if #s == 0 then return nil, "empty" end
  if #s % 4 == 1 then return nil, "bad base64 length" end
  local out, acc, bits = {}, 0, 0
  for i = 1, #s do
    local v = B64_INV[s:byte(i)]
    if v == nil then return nil, "bad base64 char at " .. i end
    acc = ((acc << 6) | v) & 0xFFFFFF
    bits = bits + 6
    if bits >= 8 then
      bits = bits - 8
      out[#out + 1] = string.char((acc >> bits) & 0xFF)
    end
  end
  return table.concat(out)
end

function M.is_b64(text)
  return type(text) == "string" and #text >= 4 and text:gsub("%s", ""):match("^[A-Za-z0-9+/_%-]+=*$") ~= nil
end

function M.hex_decode(text)
  local s = text:gsub("[%s:,]", ""):gsub("^0[xX]", "")
  if #s == 0 or #s % 2 == 1 or s:find("[^0-9a-fA-F]") then return nil, "bad hex" end
  return (s:gsub("..", function(h) return string.char(tonumber(h, 16)) end))
end

function M.hex_encode(data)
  return (data:gsub(".", function(c) return string.format("%02x", c:byte()) end))
end

-- FNV-1a 32-bit over a string; returns 8 lowercase hex chars.
function M.fnv1a32(s)
  local h = 0x811C9DC5
  for i = 1, #s do
    h = ((h ~ s:byte(i)) * 0x01000193) & 0xFFFFFFFF
  end
  return string.format("%08x", h)
end

function M.trim(s)
  return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

-- Split on a Lua pattern separator; empty fields are kept.
function M.split(s, sep_pattern)
  local out, pos = {}, 1
  while true do
    local a, b = s:find(sep_pattern, pos)
    if not a or b < a then
      out[#out + 1] = s:sub(pos)
      return out
    end
    out[#out + 1] = s:sub(pos, a - 1)
    pos = b + 1
  end
end

function M.deep_copy(v)
  if type(v) ~= "table" then return v end
  local out = {}
  for k, x in pairs(v) do out[k] = M.deep_copy(x) end
  return out
end

function M.keys_sorted(t)
  local ks = {}
  for k in pairs(t) do ks[#ks + 1] = k end
  table.sort(ks, function(a, b) return tostring(a) < tostring(b) end)
  return ks
end

local function is_array(t)
  local n = #t
  local count = 0
  for _ in pairs(t) do count = count + 1 end
  return count == n
end

local function encode_string(s)
  return '"' .. s:gsub('[%c"\\]', function(c)
    local map = { ['"'] = '\\"', ['\\'] = '\\\\', ['\n'] = '\\n', ['\r'] = '\\r', ['\t'] = '\\t' }
    return map[c] or string.format("\\u%04x", c:byte())
  end) .. '"'
end

-- Deterministic JSON (sorted object keys, integers without decimals).
-- Used where byte-identical output matters (pack checksums, fingerprints).
function M.json_canonical(v)
  local tv = type(v)
  if tv == "nil" then return "null"
  elseif tv == "boolean" then return v and "true" or "false"
  elseif tv == "number" then
    if math.type(v) == "integer" then return tostring(v) end
    if v ~= v or v == math.huge or v == -math.huge then return "null" end
    if v == math.floor(v) and math.abs(v) < 2^53 then return string.format("%d", v) end
    return string.format("%.10g", v)
  elseif tv == "string" then return encode_string(v)
  elseif tv == "table" then
    if next(v) == nil then return "[]" end
    local parts = {}
    if is_array(v) then
      for i = 1, #v do parts[i] = M.json_canonical(v[i]) end
      return "[" .. table.concat(parts, ",") .. "]"
    end
    for _, k in ipairs(M.keys_sorted(v)) do
      parts[#parts + 1] = encode_string(tostring(k)) .. ":" .. M.json_canonical(v[k])
    end
    return "{" .. table.concat(parts, ",") .. "}"
  end
  return "null"
end

return M
