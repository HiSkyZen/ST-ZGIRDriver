# HOBEIAN ZG-IR01 Arbitrary IR Probe

This is a temporary SmartThings Edge driver whose only job is to prove that a
HOBEIAN `ZG-IR01` can use its `0xE004` / `0xED00` Zosung path for arbitrary IR,
instead of being limited to the 12 EF00 on-device slots.

## Probe controls

The driver intentionally uses only stock SmartThings capabilities:

- **Refresh**: enter IR learning mode.
- **Switch ON**: send the most recently learned IR code back to the blaster.
- **Switch OFF**: cancel IR learning.

The learned code is kept in a persistent driver field and is also printed in
Live Logging as `LEARNED_CODE=<base64>`.

## Deploy

From this directory:

```powershell
smartthings edge:drivers:package .
smartthings edge:channels:assign
smartthings edge:drivers:install
```

Switch the already-paired ZG-IR01 to this driver:

```powershell
smartthings edge:drivers:switch ccf1f35c-413d-40b4-8942-b759b33af330
```

Then run Live Logging with the packaged driver ID:

```powershell
smartthings edge:drivers:logcat <DRIVER_ID>
```

No re-pairing should be necessary.

## Test

### 1. Learn

In the SmartThings app press **Refresh**, or:

```powershell
smartthings devices:commands ccf1f35c-413d-40b4-8942-b759b33af330 'main:refresh:refresh()'
```

Within a few seconds point a physical IR remote at the ZG-IR01 and press a
button.

A successful learn should contain lines resembling:

```text
[ZGIR] RX 0x00 learned-transfer start ...
[ZGIR] RX 0x03 learn chunk ...
[ZGIR] LEARN SUCCESS raw_bytes=...
[ZGIR] LEARNED_CODE=...
```

### 2. Replay through the hub

Turn the probe **Switch ON**, or:

```powershell
smartthings devices:commands ccf1f35c-413d-40b4-8942-b759b33af330 'main:switch:on()'
```

A successful arbitrary transmit should show `0x02` chunk requests followed by:

```text
[ZGIR] ARBITRARY IR TRANSMIT COMPLETED seq=...
```

The physical appliance should react to the same IR command. If that happens,
the important question is settled: this firmware supports arbitrary
hub-supplied IR, so the final SmartThings driver does not need to be limited to
the 12 hardware slots.

## Header-mode fallback

Current Zigbee2MQTT/ZHA Zosung definitions use ordinary cluster-specific
commands without a manufacturer code. Therefore this probe defaults to:

```lua
local USE_MFG_SPECIFIC = false
```

If learning produces no `0xED00` traffic at all despite the physical remote
being aimed correctly, change it to `true`, repackage, reassign the new driver
version to your channel, reinstall, and retry. That fallback uses manufacturer
code `0x1002`, which some TS1201-family SmartThings implementations use.

## Notes

The probe also keeps stock handlers for the ZG-IR01 standard temperature,
humidity and battery clusters. It reads Basic-cluster firmware identity fields
on init, but lack of a response to `SWBuildID (0x4000)` is not considered a
failure.


## ZG-IR01 TX sequence quirk

Firmware `DateCode=23062026` was observed to accept the first arbitrary transmit
with sequence 0, but when a later transfer was initiated with sequence 1 the
device acknowledged that start and nevertheless requested chunks for sequence 0.

This probe therefore keeps outbound IR-transfer `seq` fixed at `0`.  It also
serializes replays so a second tap cannot overwrite the in-flight seq-0 payload.
This matches the effective behavior of the current upstream Zosung converter for
independent sends.
