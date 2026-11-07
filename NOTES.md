# pixelwatch-bridge

Goal: set up a Google Pixel Watch 4 without an Android phone. The Google Pixel
Watch app runs in the Android emulator on the Mac; a bridge relays Bluetooth
between the emulator (netsim) and the real watch through the Mac's built-in
Bluetooth.

## Findings (2026-11-07)

Setup: emulator 36.2.11, AVD `pixelwatch_setup` (Android 15, Google Play image),
Google Pixel Watch app 5.1.0 (minSdk 30).

- The app installs from Play and runs in the emulator.
- Watch discovery is a Companion Device Manager association request
  (profile `COMPANION_DEVICE_WATCH`) with BLE scan filters: manufacturer id
  `0x00E0` (Google), data byte 1 in `{0x13, 0x14}`, data byte 6 in
  `{0x80, 0x81}`, all other bytes masked out. A classic
  `BluetoothDeviceFilter` with address `00:00:00:00:00:00` is listed too.
- A Bumble device inside netsim that advertises this data appears in the app's
  "Choose a watch to set up" list (`fake_watch.py`).
- After selecting it, the app bonds over BR/EDR (`btm_sec_bond_by_transport:
  Transport used 1`). The watch link is classic Bluetooth, so the bridge has to
  relay BR/EDR (pairing, SDP, RFCOMM), not only BLE.
- Netsim's controller rejects Android's APCF filter command
  (`LE_ADV_FILTER 0xfd57`, status 0x02); matching results still arrive.
- After "Retry" a stale scanner can swallow the results. Before a new attempt:
  force-stop `com.google.android.apps.wear.companion` and
  `com.android.companiondevicemanager`, then toggle Bluetooth.

## Next

1. When the watch is here: read its real advertisement, address and SDP
   records from the Mac.
2. Make the fake watch dual-mode with that data (LE advertising plus BR/EDR
   with Secure Simple Pairing and mirrored SDP records).
3. Relay RFCOMM/L2CAP between Bumble (emulator side) and IOBluetooth (watch
   side).

## Run

- Emulator, in its own process group so it survives an interrupted shell:
  `emulator -avd pixelwatch_setup -no-audio -camera-back none -camera-front none -no-boot-anim -no-snapshot`.
  On the external PC keyboard AltGr+Q is ⌘Q and quits the emulator.
- Fake watch: `.venv/bin/python fake_watch.py` (needs `bumble`, `grpcio`,
  `protobuf`).
