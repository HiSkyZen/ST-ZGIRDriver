-- EDGE_CHILD lifecycle: each appliance is its own SmartThings device under
-- the physical ZG-IR01 bridge.  The bridge owns no appliance state.
local log = require "log"
local caps = require "caps"
local store = require "ir.store"
local dispatcher = require "children.dispatcher"

local M = {}

local F_SEQ = "child_seq"
local F_PENDING = "pending_defs"

M.DEFAULT_LABELS = { tv = "IR TV", ac = "IR 에어컨", fan = "IR 선풍기", media = "IR 미디어", generic = "IR 리모컨" }

function M.is_child(device)
  return device.network_type == "DEVICE_EDGE_CHILD"
end

local function catalog()
  local ok, c = pcall(require, "packs.catalog")
  return ok and c or nil
end

-- spec: "<type>[:label]" | "builtin:<id>[:label]"
function M.parse_spec(spec)
  spec = tostring(spec or ""):gsub("^%s+", ""):gsub("%s+$", "")
  local builtin, rest = spec:match("^builtin:([%w%-_]+):?(.*)$")
  if builtin then return { builtin = "builtin:" .. builtin, label = rest ~= "" and rest or nil } end
  local t, label = spec:match("^(%a+):?(.*)$")
  t = t and t:lower()
  if t == "aircon" or t == "airconditioner" then t = "ac" end
  if t == "remote" then t = "generic" end
  if not (t and dispatcher.MODULES[t]) then return nil, "unknown remote type: " .. spec end
  return { device_type = t, label = label ~= "" and label or nil }
end

function M.create(driver, parent, spec_text)
  local spec, err = M.parse_spec(spec_text)
  if not spec then return nil, err end
  local def
  if spec.builtin then
    local cat = catalog()
    def = cat and cat.get(spec.builtin)
    if not def then return nil, "unknown builtin remote " .. spec.builtin end
  else
    def = store.new_def(spec.device_type, { name = spec.label })
  end
  local mod = dispatcher.MODULES[def.device_type]
  if not mod then return nil, "unsupported device type " .. tostring(def.device_type) end
  local seq = (parent:get_field(F_SEQ) or 0) + 1
  parent:set_field(F_SEQ, seq, { persist = true })
  local key = def.device_type .. "-" .. seq
  local pending = parent:get_field(F_PENDING) or {}
  pending[key] = def
  parent:set_field(F_PENDING, pending, { persist = true })
  local label = spec.label or (def.meta and def.meta.name) or M.DEFAULT_LABELS[def.device_type]
  log.info(string.format("[ZGIR] creating child %s profile=%s label=%s", key, mod.PROFILE, label))
  driver:try_create_device({
    type = "EDGE_CHILD",
    label = label,
    profile = mod.PROFILE,
    parent_device_id = parent.id,
    parent_assigned_child_key = key,
    vendor_provided_label = label,
  })
  return key
end

-- Bind the pending definition to a freshly added child.
function M.on_child_added(driver, child)
  local parent = child:get_parent_device()
  local key = child.parent_assigned_child_key or ""
  local def = store.get(child)
  if def == nil and parent then
    local pending = parent:get_field(F_PENDING) or {}
    def = pending[key]
    if def then
      pending[key] = nil
      parent:set_field(F_PENDING, pending, { persist = true })
    end
  end
  if def == nil then
    local t = key:match("^(%a+)%-") or "generic"
    def = store.new_def(dispatcher.MODULES[t] and t or "generic")
  end
  store.save(child, def, "child created")
  M.after_change(driver, parent)
  return def
end

function M.ensure_def(child)
  local def = store.get(child)
  if def then return def end
  local t = (child.parent_assigned_child_key or ""):match("^(%a+)%-") or "generic"
  def = store.new_def(dispatcher.MODULES[t] and t or "generic")
  store.save(child, def, "recovered missing definition")
  return def
end

function M.children(driver, parent)
  local out = {}
  for _, d in ipairs(driver:get_devices()) do
    if M.is_child(d) and d.parent_device_id == parent.id then out[#out + 1] = d end
  end
  table.sort(out, function(a, b) return (a.parent_assigned_child_key or "") < (b.parent_assigned_child_key or "") end)
  return out
end

function M.summary(driver, parent)
  local parts = {}
  for _, c in ipairs(M.children(driver, parent)) do
    local def = store.get(c)
    local n = 0
    if def then for _ in pairs(def.commands or {}) do n = n + 1 end end
    parts[#parts + 1] = string.format("%s (%s, %d keys)", c.label or "?", def and def.device_type or "?", n)
  end
  if #parts == 0 then return "리모컨 없음 — 'tv', 'ac', 'fan', 'media', 'generic' 또는 builtin:lg-tv 로 추가" end
  local s = table.concat(parts, ", ")
  return #s > 1990 and s:sub(1, 1990) .. "…" or s
end

function M.after_change(driver, parent)
  if parent == nil then return end
  parent:emit_event(caps.bridge.remotes({ value = M.summary(driver, parent) }))
end

return M
