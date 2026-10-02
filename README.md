# ZG-IR01 Universal IR (SmartThings Edge)

A fully local, universal IR platform for the HOBEIAN **ZG-IR01** Zigbee IR blaster.

The physical ZG-IR01 acts only as a bridge. Each TV, air conditioner, fan, AV/media
device or free-form remote becomes its own SmartThings `EDGE_CHILD` device, with
standard capabilities wherever SmartThings has them.

- Learn and transmit arbitrary IR. The 12 on-device slots are not used.
- Child types: TV, air conditioner, fan, media (AV/soundbar/projector/set-top), generic remote.
- Guided learning (prompt → receive → save → automatic test send → confirm/retry/skip), single-key re-learning, duplicate detection.
- Air conditioners keep one logical state and send full-state frames. A differential
  analyzer turns labelled samples into a parametric model, with hybrid and raw-codebook fallback.
- Importers: Broadlink (base64/hex), Pronto Hex, LIRC raw, Global Caché `sendir`, SmartIR JSON,
  Tuya/Zosung base64, raw timing lists, and `name: code` lines (auto-detected).
- Remote Packs (`.stir`, versioned, checksummed): export, import, and a single-line `STIR1:` share string.
- Built-in remotes generated from protocol encoders: `builtin:lg-tv`, `builtin:samsung-tv`, `builtin:sony-tv`.
- Built-in temperature, humidity, battery % and battery voltage, with configurable Zigbee reporting.
- Everything runs on the hub. No internet or cloud service is involved in learning or sending.

Architecture and module contracts are in [ARCHITECTURE.md](ARCHITECTURE.md). Verification status is in
[PROJECT_STATUS.md](PROJECT_STATUS.md).

## Install

```powershell
./tools/deploy.ps1                      # package -> assign to channel -> install on hub
smartthings edge:drivers:switch <ZG-IR01 deviceId> --driver <driverId>
```

No re-pairing is needed.

## Using it

The bridge device (`ZG-IR01`) shows the sensors and an **IR Bridge** panel:

| Action | App field / CLI |
| --- | --- |
| Add a remote | `createRemote("tv")`, `"ac:거실 에어컨"`, `"fan"`, `"media"`, `"generic:My remote"`, `"builtin:lg-tv"` |
| Learn a raw code (shown in status/log) | `learnRaw()` |
| Send any code once | `sendCode("<Broadlink/Pronto/raw/... or builtin:lg-tv:power>")` |
| On-hub self-test | `selfTest("")` (results in status and `edge:drivers:logcat`) |

Each appliance child has:

- **Standard controls** for its type (switch, volume, channel, input, playback, AC mode/setpoint/fan/swing, fan speed…)
- **IR Remote**: every learned key in a list, plus a "send key by name" field (`press("vol_up")`).
- **IR Learning**: `startGuided()`, `learn("key_name")`, `confirm()`, `retry()`, `skip()`, `cancel()`.
  The prompt line tells you what to press.
- **IR Remote Pack**: `importData("<anything importable>")` and `exportPack()`. The share string appears in *Exported pack*.

Imported remotes start **unverified**. The driver test-sends power (or a representative
code); press `confirm()` once the appliance reacted.

Air conditioners: `startGuided()` runs the differential learning. Set the physical remote to the
state named in the prompt and press any button. The analyzer picks whichever state reduces
uncertainty most. Imported SmartIR climate files are used as a raw codebook immediately and are
promoted to a parametric model when the protocol is regular. The four extra switches (Turbo, Eco,
Sleep, Display) are standard `switch` components.

### Files

```powershell
./tools/import.ps1 -Device <childId> -File smartir_1180.json   # large files are sent in parts
./tools/export.ps1 -Device <childId> -Out living-tv.stir
```

### Sensor reporting preferences (bridge device settings)

`periodicReporting`, `reportingInterval` (1 min … 6 h), `tempChange`, `humidityChange`,
`batteryReporting`, `batteryInterval`. They are applied with Zigbee *Configure Reporting*. Frequent
reporting increases battery drain. With reporting off, the driver stops requesting periodic
reports, but reports the device sends on its own are still recorded.

## Development

There is no local Lua toolchain. Pure modules are verified on the real hub:

```powershell
./tools/deploy.ps1
smartthings edge:drivers:logcat <driverId> --hub-address <hub ip>
smartthings devices:commands <bridgeId> 'main:drumpepper55014.irBridge:selfTest("")'
```

Self-test modules live in `src/selftests/` (the Edge packager strips `src/tests/`).
Custom capability definitions and presentations are in `capabilities/`. `drumpepper55014` is the
capability namespace SmartThings assigned to the developer organization.
