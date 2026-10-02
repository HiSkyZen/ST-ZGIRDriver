local protocols = require "ir.protocols"
local signal = require "ir.signal"
local M = { name = "protocols", cases = {} }

M.cases[#M.cases + 1] = { "LG NEC and NEC32 vectors", function(t)
  local a = assert(protocols.nec(0x04, 0x08))
  local b = assert(protocols.nec32(0x20DF10EF))
  t.eq(a.timings_us[1], 9000); t.eq(a.timings_us[2], 4500)
  t.same(a.timings_us, b.timings_us)
  t.eq(#a.timings_us, 67); t.eq(a.timings_us[#a.timings_us], 560)
  t.ok(signal.validate(a)); t.ok(signal.validate(b))
end }

M.cases[#M.cases + 1] = { "protocol builders validate all supported encoders", function(t)
  local specs = {
    { protocol="nec", address=4, command=8 }, { protocol="nec32", code=0x20DF10EF },
    { protocol="samsung32", address=7, command=2 }, { protocol="sony_sirc", address=1, command=21, bits=12 },
    { protocol="rc5", address=0, command=0, toggle=false },
  }
  for _, spec in ipairs(specs) do t.ok(signal.validate(assert(protocols.build(spec))), spec.protocol) end
end }

return M
