# Project status — ZG-IR01 Universal IR Platform

Last updated: 2026-10-02. The driver runs on the user's hub (V3, fw 000.062.00007) with the real ZG-IR01
(HOBEIAN, fw DateCode 23062026).

## Verified on real hardware

| Area | Evidence |
| --- | --- |
| Learn → store → replay round trip (spec §17 regression) | LG remote power learned through the TV child flow, stored, replayed via `press("lg_power")`; the user confirmed the TV toggled |
| Generated IR (no learning) | `sendCode("builtin:lg-tv:power")`, built by the NEC encoder → canonical → native packet; the user confirmed the TV toggled |
| Native format | ZG-IR01 learns **Broadlink packets** (len counts the header, no terminator); device-learned codes re-encode byte-identically (self-test) |
| Zosung transport | E004 study 0/1, ED00 0x00–0x05, seq fixed 0, chunk retry, checksum, malformed-frame guards, Default Response |
| Central TX queue | FIFO for stateless keys (3× vol_up serialized), AC coalescing (debounce 1 s), watchdog retry, stall detection after a dropped start (observed once and recovered) |
| Sensors | temperature, humidity, battery %, battery voltage 3.0 V emitted as `voltageMeasurement`; Configure Reporting accepted (SUCCESS) for all four attributes |
| Children | TV (builtin LG), generic, fan, media and AC children created as EDGE_CHILD under the bridge; standard capabilities emit correctly |
| Import | named lines mixing signed raw / Global Caché / Pronto; SmartIR climate (Raw encoding) → codebook + constraints → promoted to a parametric model in ~1 s on the hub |
| Remote Pack | export → `STIR1:` share string → import into another child (checksum verified) → keys restored; `tools/export.ps1` writes `.stir` |
| Persistence | definitions and state survive driver restarts. Values read back from the persistent store must not be mutated in place (data loss observed and fixed with copy-on-read) |
| Self-tests on the hub | 38 core/transport/import/packs/protocols/devices cases + 17 analysis cases pass |
| Independent audit (Astra A1) | 15 findings; 1–14 fixed with regression tests; 15 (`tx_queue.clear` window) has no production caller |

## Known limits / follow-ups

- AC analyzer CPU cost: resolved in W1b. Full analysis suite 41 s (was ~250 s); guided sessions 3–4 s
  in total; analysis yields to cosock and is capped by a 20 s budget with raw fallback.
- AC guided learning with a physical AC remote has not been run yet (no physical AC session so far).
- Community registry: not implemented (optional in the spec). Sharing works offline through
  `.stir` files and `STIR1:` strings.
- Girr and decoded (non-raw) LIRC protocols: not implemented (spec: "추후").
- Custom capability presentations are generated automatically. App layout has not been tuned with
  a device-config/vid.
- `mediaInputSource` lists only inputs that have learned `source_<name>` keys. Otherwise `setInputSource`
  sends the generic `input` key.

## Accepted decisions

- Native TX/RX format = Broadlink packet in the device's own layout (`ir/native.lua`); Tuya-LZ is import-only.
- Custom capabilities only for remote keys, learning workflow, packs and bridge control
  (namespace `drumpepper55014`, assigned to the SmartThings developer organization).
- AC extras (turbo/eco/sleep/display) are standard `switch` components rather than custom capabilities.
- Imported remotes start inactive until a test transmit is confirmed. The pending state is derived
  from the persisted definition.
