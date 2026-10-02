local util = require "util"
local M = {}

local function decode_json(text)
  local ok, json = pcall(require, "st.json")
  if not ok then return nil end
  local good, v = pcall(json.decode, text)
  if good and type(v) == "table" then return v end
end

local function broadlink_b64(s)
  local bytes = util.b64_decode(s)
  if not bytes or #bytes < 6 or bytes:byte(1) ~= 0x26 then return false end
  local n = bytes:byte(3) | (bytes:byte(4) << 8)
  return n >= 3 and n <= #bytes - 4
end

function M.detect(text)
  if type(text) ~= "string" then return nil end
  local s = util.trim(text)
  if s == "" then return nil end
  local doc = decode_json(s)
  if doc then
    if doc.format == "stir" then return "stir" end
    if type(doc.commands) == "table" then return "smartir" end
    if type(doc[1]) == "number" then return "raw" end
  end
  if s:match("^[Ss][Ee][Nn][Dd][Ii][Rr],") then return "globalcache" end
  if s:find("begin%s+remote") then return "lirc" end
  if s:match("^0000%s+[%x][%x][%x][%x]") or s:match("^0100%s+[%x][%x][%x][%x]") then return "pronto" end
  local compact = s:gsub("[%s:,]", "")
  if #compact >= 12 and #compact % 2 == 0 and compact:sub(1,2):lower() == "26" and not compact:find("[^%x]") then return "broadlink_hex" end
  if broadlink_b64(s) then return "broadlink_b64" end
  local okz, zosung = pcall(require, "ir.codec_zosung")
  if okz then
    local ok, yes = pcall(zosung.looks_like, s)
    if ok and yes then return "zosung" end
  end
  if s:match("^[Ff][Rr][Ee][Qq]%s*=%s*%d+") or s:match("^[Cc][Aa][Rr][Rr][Ii][Ee][Rr]%s*:%s*%d+") then return "raw" end
  if s:match("^[%+%-]?%d") and s:match("^[%+%-]?[%d%.]+[%s,;+%-]") then return "raw" end
  return nil
end

local function one(text, name)
  local format = M.detect(text)
  if not format then return nil, "unrecognized IR format" end
  if format == "stir" then return nil, "stir pack: use packs.import" end
  local modules = {
    broadlink_b64 = "import.broadlink", broadlink_hex = "import.broadlink", pronto = "import.pronto",
    globalcache = "import.globalcache", lirc = "import.lirc", smartir = "import.smartir", raw = "import.raw"
  }
  local parsed, err
  if format == "zosung" then
    local codec = require "ir.codec_zosung"
    local good, sig, decode_err = pcall(codec.decode, text)
    if good then err = decode_err else err = "malformed Zosung data" end
    if sig then parsed = { format = "zosung", signals = { { sig = sig } } } end
  else
    local mod = require(modules[format])
    parsed, err = mod.parse(text)
  end
  if not parsed then return nil, err end
  if name and #parsed.signals > 0 then for _, entry in ipairs(parsed.signals) do entry.name = name end end
  return parsed
end

function M.parse_any(text)
  if type(text) ~= "string" then return nil, "input must be text" end
  local doc = decode_json(text)
  if doc and doc.format == "stir" then return nil, "stir pack: use packs.import" end
  local named = {}
  for line in (text .. "\n"):gmatch("([^\r\n]*)\r?\n") do
    local name, code = line:match("^%s*([%w_%-]+)%s*[:=]%s*(.-)%s*$")
    local lname = name and name:lower()
    if lname == "freq" or lname == "frequency" or lname == "carrier" then name = nil end
    if name and code and code ~= "" then named[#named + 1] = { name = name, code = code } end
  end
  if #named > 0 then
    local result = { format = nil, signals = {} }
    for _, entry in ipairs(named) do
      local p, err = one(entry.code, entry.name)
      if not p then return nil, err end
      result.format = result.format or p.format
      for _, sig in ipairs(p.signals or {}) do result.signals[#result.signals + 1] = sig end
      if p.smartir then return nil, "named SmartIR records are not supported" end
    end
    return result
  end
  return one(text)
end

return M
