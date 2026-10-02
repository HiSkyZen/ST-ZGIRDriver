# ZG-IR01 Universal IR Platform — Architecture & Contracts

Authoritative interface record for all workstreams. Requirements source:
`docs/개발 사양 및 구현 지시서.md` (local, untracked).

## Runtime facts

- SmartThings Edge, Lua **5.3** (integers, `//`, bitwise ops, `string.pack`).
- No local Lua toolchain. Pure modules are verified **on the hub** through
  `src/selftest.lua` (bridge command `selfTest`) and `smartthings edge:drivers:logcat`.
- Pure modules may require only: `util`, `ir.*`, `import.*`, `packs.*`,
  `analysis.*`, `st.json`, `log`. No `st.zigbee`, no device objects, no timers.
- Error convention: functions taking external input never throw; they return
  `nil, "reason"`. Internal invariant violations may `error()`.
- Log prefix `[ZGIR]`. No globals. Module = `local M = {} ... return M`.

## Layering

```
init.lua (wiring only)
 ├─ transport/zosung.lua   E004/ED00 frames, learn RX, chunk TX (parent device only)
 ├─ transport/tx_queue.lua central serialized queue, seq=0, watchdog/retry, coalesce
 ├─ transport/zigbee.lua   raw ZCL send helpers / default response
 ├─ sensors/environment.lua, sensors/reporting.lua
 ├─ children/manager.lua   EDGE_CHILD create/remove, parent<->child lookup
 ├─ children/dispatcher.lua capability command -> device module -> tx request
 ├─ children/state.lua     desired/lastCommanded/source/confidence + debounced persist
 ├─ children/learning.lua  guided learning sessions (generic + AC)
 ├─ devices/{tv,ac,fan,media,generic}.lua  key vocabulary, capability mapping
 ├─ ir/      signal, codec_zosung, codec_broadlink, fingerprint, protocols, store
 ├─ import/  detect, broadlink, pronto, lirc, globalcache, smartir, raw
 ├─ packs/   schema, import, export, migration, catalog
 └─ analysis/ timings, symbols, diff, fields, checksum, ac_learner
```

Children never touch Zigbee: child -> `dispatcher` -> `tx_queue` (parent) -> `zosung`.

## Canonical IR signal (`ir/signal.lua`) — FROZEN

```lua
{ carrier_hz = 38000,            -- integer, 0 = unknown (TX uses 38000)
  timings_us = {9000,4500,...},  -- positive integers, alternating mark/space, starts with mark
  repeat_timings_us = nil|{...}, -- optional repeat frame
  repeat_count = 0,              -- repeat frames appended on TX
  source = { format = "pronto", ... } }  -- provenance only
```
API: `signal.new(carrier, timings, {repeat_timings_us, repeat_count, source})`,
`signal.validate(sig) -> true | nil, err`, `signal.flatten(sig) -> timings`,
`signal.carrier(sig)`, `signal.timings_close(a, b, tol)`, `signal.describe(sig)`.

## Native codec (`ir/codec_zosung.lua`) — FROZEN

`encode(sig) -> b64 | nil, err`, `decode(b64, carrier?) -> sig | nil, err`,
`looks_like(b64) -> bool`, `compress/decompress(bytes)`.
Format: base64(Tuya-LZ(uint16le timings)). Learned codes from the device are this format.

## Stored command record

Persisted everywhere (child definitions, packs) as the compact native form:

```lua
{ z = "<zosung base64>", carrier = 38000, fp = "<fingerprint>" }  -- fp optional
```

## Key vocabulary (lower_snake_case, `[a-z0-9_]+`, ≤ 32 chars)

- Common: `power`, `power_on`, `power_off`
- TV/media: `vol_up vol_down mute ch_up ch_down input digit_0..digit_9 up down left right ok
  back home menu exit info guide red green yellow blue play pause play_pause stop rewind
  fast_forward next previous record` and inputs `source_<name>` (e.g. `source_hdmi1`).
- Fan: `speed_up speed_down speed_1..speed_9 oscillate timer mode_<name>` (`mode_natural`, `mode_sleep`).
- AC toggles (when not part of the state model): `turbo eco sleep display light`.
- Generic: any valid key name.

## AC logical state

```lua
{ power = "on"|"off", mode = "cool"|"heat"|"dry"|"fan"|"auto", temp = 24,
  fan = "auto"|"low"|"medium"|"high"|"quiet"|"turbo", swing = "off"|"on"|"vertical"|"horizontal"|"both",
  turbo = false, eco = false, sleep = false, display = true }
```
Codebook state key: `"off"` when power off, else `mode.."|"..fan.."|"..swing.."|"..temp`
with temp formatted `%g` (e.g. `cool|auto|off|24`, `heat|low|on|22.5`).
Missing fan/swing dimension uses `"-"` (e.g. `dry|-|-|24`).

## Remote definition (child persistent field `def`)

```lua
{ schema = 1, device_type = "tv"|"ac"|"fan"|"media"|"generic",
  meta = { name, manufacturer, model, region, pack_id, source },
  commands = { [key] = <command record> },
  ac = nil | { model = <analysis model table, JSON-serializable>, codebook = { [state_key] = <command record> },
               constraints = { min_temp, max_temp, step, modes = {...}, fan_modes = {...}, swing_modes = {...} },
               learner = <ac_learner export table> },
  active = true }    -- false until an imported pack passed its test transmit
```
Device instance state (`state` field) is NEVER part of a definition or pack.

## Remote Pack (`*.stir`, JSON) — schemaVersion 1

```json
{ "format": "stir", "schemaVersion": 1, "packVersion": "1.0.0", "id": "STIR-xxxxxxxx",
  "deviceType": "tv", "manufacturer": "LG", "model": "", "region": "",
  "minDriverVersion": "1.0.0",
  "provenance": { "source": "learned|smartir|broadlink|pronto|lirc|globalcache|builtin", "author": "", "created": "" },
  "capabilityMappings": { },
  "commands": { "power": { "carrier": 38000, "z": "<zosung b64>" } },
  "ac": { "model": {}, "codebook": { "cool|auto|off|24": { "carrier": 38000, "z": "..." } },
          "constraints": { "minTemp": 16, "maxTemp": 30, "step": 1, "modes": [], "fanModes": [], "swingModes": [] } },
  "checksum": "<fnv1a32 of util.json_canonical(pack without checksum)>" }
```
`id` = `"STIR-" .. fnv1a32(json_canonical(pack without id/checksum/provenance))`.

## Importer contract (`import/*`)

Each format module: `M.parse(text) -> result | nil, err` where

```lua
result = { format = "pronto", signals = { { name = "power"|nil, sig = <canonical signal> }, ... },
           meta = { manufacturer=?, model=?, device_type=? },   -- optional
           smartir = nil | <smartir structure, see below> }
```
`import.detect.detect(text) -> format_name | nil` and
`import.detect.parse_any(text) -> result | nil, err` (auto-detect then parse).
Format names: `zosung broadlink_b64 broadlink_hex pronto lirc globalcache smartir raw`.

SmartIR structure (`import/smartir.lua`):
```lua
{ kind = "climate"|"media_player"|"fan", manufacturer, models = {...}, encoding = "Base64"|"Pronto"|...,
  constraints = { min_temp, max_temp, step, modes, fan_modes, swing_modes },  -- climate
  codebook = { [state_key] = <canonical signal> },   -- climate, AC state key format above
  commands = { [key] = <canonical signal> } }       -- media/fan (and climate "off")
```

## AC analyzer contract (`analysis/ac_learner.lua`)

```lua
local L = ac_learner.new({ constraints = {...} })
L:add_sample(state, sig)        -> true | nil, err
L:next_request()                -> { state = <AC state>, reason = "...", prompt_ko = "..." } | nil
L:analyze()                     -> model | nil, report   -- model is plain JSON-serializable data
L:export() / ac_learner.load(t) -- persistence of samples + model
ac_learner.encode(model, state) -> sig | nil, err        -- parametric generation
ac_learner.resolve(acdef, state)-> sig, "parametric"|"hybrid"|"raw" | nil, err
ac_learner.from_codebook(constraints, codebook) -> learner  -- SmartIR ingestion
```

## Persistence policy

Immediate (`persist=true` write now): learned code, import, AC model, child create/delete, prefs.
Debounced (RAM then 30 s checkpoint): logical state (temp, fan, volume, input...).

## TX policy

Single in-flight transfer per bridge, **seq fixed 0**, 15 s watchdog, 1 retry on timeout.
Stateless keys queue FIFO; stateful (AC) requests carry `coalesce` key and replace queued
entries with the same key (debounce ≈ 600 ms before dispatch).
