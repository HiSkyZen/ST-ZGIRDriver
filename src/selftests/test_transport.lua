-- TX queue policy and ED00 frame layout, using a fake device whose timers
-- are run manually (no Zigbee traffic is generated).
local zosung = require "transport.zosung"
local tx_queue = require "transport.tx_queue"

local function fake_device()
  local d = { fields = {}, timers = {}, sent = {} }
  function d:get_field(k) return self.fields[k] end
  function d:set_field(k, v) self.fields[k] = v end
  d.thread = {
    call_with_delay = function(_, delay, fn) d.timers[#d.timers + 1] = { delay = delay, fn = fn } end,
  }
  -- run all timers whose delay <= max_delay (repeatedly, as they may schedule more)
  function d:run(max_delay)
    local progressed = true
    while progressed do
      progressed = false
      for i, tm in ipairs(self.timers) do
        if tm.delay <= (max_delay or 1) then
          table.remove(self.timers, i)
          tm.fn()
          progressed = true
          break
        end
      end
    end
  end
  return d
end

-- Replace the radio with a recorder for the duration of a case.
local function with_fake_radio(fn)
  local orig_begin, orig_abort = zosung.begin_transmit, zosung.abort_transmit
  local sent = {}
  zosung.begin_transmit = function(device, json) sent[#sent + 1] = json end
  zosung.abort_transmit = function() end
  local ok, err = pcall(fn, sent)
  zosung.begin_transmit, zosung.abort_transmit = orig_begin, orig_abort
  if not ok then error(err, 0) end
end

local function code_of(json)
  return json:match('"key_code":"([^"]+)"')
end


-- Drive inbound ED00 handlers with the radio stubbed out.
local zigbee = require "transport.zigbee"

local function with_stub_zigbee(fn)
  local orig_send, orig_ack = zigbee.send_cluster_command, zigbee.ack
  local sent = {}
  zigbee.send_cluster_command = function(_, cluster, cmd, payload) sent[#sent + 1] = { cluster = cluster, cmd = cmd } end
  zigbee.ack = function() end
  local orig_learned, orig_timeout = zosung.on_learned, zosung.on_learn_timeout
  local ok, err = pcall(fn, sent)
  zigbee.send_cluster_command, zigbee.ack = orig_send, orig_ack
  zosung.on_learned, zosung.on_learn_timeout = orig_learned, orig_timeout
  if not ok then error(err, 0) end
end

local function rx(cmd, body)
  return { body = { zcl_header = {}, zcl_body = { body_bytes = body } } }
end

local function inbound(device, cmd, body)
  zosung.cluster_handlers[zosung.CLUSTER_TRANSFER][cmd](nil, device, rx(cmd, body))
end

local function chunk(seq, pos, data)
  return string.pack("<I1I2I4", 0, seq, pos) .. string.char(#data) .. data .. string.char(zosung.crc(data))
end

return {
  name = "transport",
  cases = {
    { "frame layouts", function(t)
      t.eq(#zosung.frame_00(0, 100, 2), 16)
      t.eq(select(2, string.unpack("<I2I4", zosung.frame_00(0, 100, 2))), 100)
      t.eq(#zosung.frame_02(0, 56, 0x38), 7)
      local f3 = zosung.frame_03(0, 0, "abc")
      t.eq(#f3, 7 + 1 + 3 + 1)
      t.eq(f3:byte(#f3), (97 + 98 + 99) & 0xFF, "checksum byte")
      t.eq(zosung.TX_SEQ, 0, "seq fixed at 0")
      t.ok(zosung.build_ir_json("QUJD", 38000):find('"key_code":"QUJD"', 1, true))
    end },
    { "fifo keeps every stateless press", function(t)
      with_fake_radio(function(sent)
        local d = fake_device()
        for i = 1, 3 do tx_queue.enqueue(d, { code = "VOL" .. i, label = "vol" }) end
        d:run(1)
        t.eq(#sent, 1, "only one in flight")
        tx_queue.on_tx_status(d, true, 0); d:run(1)
        tx_queue.on_tx_status(d, true, 0); d:run(1)
        t.eq(#sent, 3)
        t.eq(code_of(sent[1]), "VOL1"); t.eq(code_of(sent[3]), "VOL3")
      end)
    end },
    { "coalesce keeps only the final AC state", function(t)
      with_fake_radio(function(sent)
        local d = fake_device()
        local results = {}
        for temp = 22, 25 do
          tx_queue.enqueue(d, { code = "T" .. temp, coalesce = "ac:1", delay = 0.6,
            on_done = function(ok, err) results[#results + 1] = tostring(ok) .. ":" .. tostring(err) end })
        end
        t.eq(#sent, 0, "debounced")
        d:run(1)
        t.eq(#sent, 1)
        t.eq(code_of(sent[1]), "T25")
        tx_queue.on_tx_status(d, true, 0)
        t.eq(results[#results], "true:nil")
        local superseded = 0
        for _, r in ipairs(results) do if r == "false:superseded" then superseded = superseded + 1 end end
        t.eq(superseded, 3)
      end)
    end },
    { "watchdog retries once then fails", function(t)
      with_fake_radio(function(sent)
        local d = fake_device()
        local final
        tx_queue.enqueue(d, { code = "X", on_done = function(ok, err) final = err end })
        d:run(1)
        t.eq(#sent, 1)
        d:run(tx_queue.WATCHDOG_SEC) -- first timeout -> retry
        t.eq(#sent, 2, "retried")
        d:run(tx_queue.WATCHDOG_SEC) -- second timeout -> give up
        t.eq(final, "timeout")
        t.eq(tx_queue.stats(d).queued, 0)
      end)
    end },
    { "learn completes even if the 0x05 finish is lost", function(t)
      with_stub_zigbee(function()
        local d = fake_device()
        local got
        zosung.on_learned = function(_, code) got = code end
        zosung.start_learning(d, 30)
        inbound(d, 0x00, string.pack("<I2I4I4I2I1I1I2", 7, 3, 0, 0xE004, 1, 2, 0))
        t.ok(zosung.rx_busy(d), "busy during transfer")
        inbound(d, 0x03, chunk(7, 0, "abc"))
        t.eq(got, nil, "not before finish wait")
        d:run(zosung.FINISH_WAIT_SEC)
        t.eq(got, "YWJj", "delivered after finish timeout")
        t.ok(not zosung.rx_busy(d), "bridge released")
      end)
    end },
    { "bad checksum and premature finish fail cleanly", function(t)
      with_stub_zigbee(function()
        local d = fake_device()
        local outcome, got
        zosung.on_learned = function(_, code) got = code end
        zosung.on_learn_timeout = function(_, o) outcome = o end
        zosung.start_learning(d, 30)
        inbound(d, 0x00, string.pack("<I2I4I4I2I1I1I2", 1, 6, 0, 0xE004, 1, 2, 0))
        local bad = string.pack("<I1I2I4", 0, 1, 0) .. string.char(3) .. "abc" .. string.char(0)
        inbound(d, 0x03, bad)
        inbound(d, 0x03, string.pack("<I1I2I4", 0, 1, 0) .. string.char(3) .. "abc") -- no checksum byte
        inbound(d, 0x05, string.pack("<I2I2", 1, 0))
        t.eq(got, nil, "partial buffer never delivered")
        t.eq(outcome, "failed")
        t.ok(not zosung.rx_busy(d))
      end)
    end },
    { "stale transmit status before any chunk is ignored", function(t)
      with_stub_zigbee(function()
        local d = fake_device()
        local statuses = 0
        local orig = zosung.on_tx_status
        zosung.on_tx_status = function() statuses = statuses + 1 end
        zosung.begin_transmit(d, '{"x":1}')
        inbound(d, 0x04, string.pack("<I1I2", 0, 0))
        t.eq(statuses, 0, "late status of an abandoned transfer ignored")
        t.ok(zosung.tx_active(d))
        inbound(d, 0x02, zosung.frame_02(0, 0, 0x38))
        inbound(d, 0x04, string.pack("<I1I2", 0, 0))
        t.eq(statuses, 1)
        zosung.on_tx_status = orig
      end)
    end },
    { "queue waits while the bridge is learning", function(t)
      with_fake_radio(function(sent)
        local d = fake_device()
        d.fields.zosung_learning = 1
        tx_queue.enqueue(d, { code = "K" })
        d:run(0.5)
        t.eq(#sent, 0, "held during learning")
        d.fields.zosung_learning = nil
        d:run(1)
        t.eq(#sent, 1, "released after learning")
      end)
    end },
  },
}
