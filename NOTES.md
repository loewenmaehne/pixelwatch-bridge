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

## Stage 3: Mac helper and relay (2026-11-07)

- `mac/` holds the Mac side, a small app bundle (`build.sh`, `run.sh`) so that
  macOS grants Bluetooth to this tool only. Signed with the Apple Development
  identity, so the permission survives rebuilds. Commands: `le-scan`,
  `inquiry`, `paired`, `sdp`, `pair`, `bridge`.
- Tested on the Mac (macOS 27.0.1, M1): Bluetooth permission granted, BLE
  scan, classic inquiry and the paired list work from the app.
- `fake_watch.py --relay PORT` hands the emulator's Wear OS channel to the Mac
  helper over TCP. Tested with `tools/dummy_mac_helper.py`: the phone's first
  108 bytes arrive on the Mac side. Without an answer the phone drops the
  channel after about 15 seconds and pairs again.
- Not tested yet, needs the watch: `pair`, `sdp` and `bridge` against the real
  watch.

## With the watch

1. Watch on, in setup mode, next to the Mac.
2. `mac/run.sh le-scan 20 --google`: note the watch's manufacturer data.
3. `mac/run.sh inquiry 15`: look for the watch's classic address. If it does
   not show up, the address has to come from elsewhere (CoreBluetooth hides
   addresses).
4. `mac/run.sh pair <address>`: the code is printed; compare with the watch.
5. `mac/run.sh sdp <address>`: the Wear OS service
   `5e8945b0952511e3a5e20800200c9a66` should be listed with an RFCOMM channel.
6. `mac/run.sh bridge <address> 7700` (keep running).
7. `.venv/bin/python fake_watch.py --relay 7700 --payload <data after e000>`.
8. Emulator: Pixel Watch app, "Set up watch", pick the watch, "Pair". From
   here the app talks to the real watch through the relay.

Open questions: whether the watch accepts pairing from a Mac, and whether
anything in the protocol is tied to Bluetooth addresses.

## Run

- Emulator, in its own process group so it survives an interrupted shell:
  `emulator -avd pixelwatch_setup -no-audio -camera-back none -camera-front none -no-boot-anim -no-snapshot`.
  On the external PC keyboard AltGr+Q is ⌘Q and quits the emulator.
- Fake watch: `.venv/bin/python fake_watch.py [--relay PORT]` (needs `bumble`,
  `grpcio`, `protobuf`).
- Mac helper: `zsh mac/build.sh`, then `zsh mac/run.sh <command>`.
