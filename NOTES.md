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

## Stage 2: classic Bluetooth and the Wear OS channel (2026-11-07)

`fake_watch.py` is now dual-mode: LE advertising with the netsim public
address, BR/EDR with Secure Simple Pairing (numeric comparison confirmed by
the script), and an SDP record plus RFCOMM server for the Wear OS service.

- The app bonds over BR/EDR. Android shows its normal numeric comparison
  dialog (code 000000 under netsim); after "Pair" setup continues.
- Then the phone's Wear OS stack (`WearableConn` in Play services) looks up
  RFCOMM service `5E8945B0-9525-11E3-A5E2-0800200C9A66` via SDP and connects.
  Without that record it retries every few seconds and the app stays on
  "Connecting to your watch".
- The phone is the RFCOMM client and speaks first: a 4-byte big-endian length
  followed by a protobuf message (104 bytes in the first test). It carries a
  node id, the phone's device name, the Android API level (35) and further
  ids. Raw captures stay local in `captures/` (gitignored, they contain device
  ids).
- For the bridge this means: on the watch side the Mac only has to pair and
  act as RFCOMM client (IOBluetooth `openRFCOMMChannel`); the relay can pass
  bytes through without understanding them.

## Next

1. When the watch is here: find its BR/EDR address from the Mac (CoreBluetooth
   hides addresses; try IOBluetooth inquiry, the setup screen name, or the
   advertisement), pair with it via IOBluetooth and read its SDP records.
2. Mac helper: open RFCOMM to the watch's Wear OS service and expose it on a
   local socket.
3. Relay: `fake_watch.py` forwards the emulator's RFCOMM channel to that
   socket and back.

Open questions: whether the watch accepts pairing from a Mac, and whether
anything in the protocol is tied to Bluetooth addresses.

## Run

- Emulator, in its own process group so it survives an interrupted shell:
  `emulator -avd pixelwatch_setup -no-audio -camera-back none -camera-front none -no-boot-anim -no-snapshot`.
  On the external PC keyboard AltGr+Q is ⌘Q and quits the emulator.
- Fake watch: `.venv/bin/python fake_watch.py` (needs `bumble`, `grpcio`,
  `protobuf`).
