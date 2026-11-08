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

## Stage 4: the real watch (2026-11-08)

Tested with a Pixel Watch 4 in setup mode, emulator Play services 26.43.

What works through the bridge: pairing, the Wear OS channel, the setup screens
up to the Google account, terms, warranty and GMS check-in, and the watch's
internet access through the phone.

Findings, in the order they mattered:

- Advertisement: manufacturer data (Google) of 17 bytes. Bytes 10 to 15 after
  the company id hold the watch's BR/EDR address, which is also its public
  advertising address. `watch-scan` prints it. The app bonds with the
  advertising address of the device it picked, so `fake_watch.py` gets the
  payload with its own netsim address in those six bytes.
- Discovery: classic inquiry finds nothing (the watch is not discoverable) and
  `IOBluetoothDeviceInquiry` delivers no results at all on this macOS. The
  address comes from the advertisement instead.
- Pairing: macOS ignores pairing confirmations from apps without Apple's
  programmatic-pairing entitlement; `IOBluetoothDevicePair` times out after
  30 s (error 31). When bluetoothd starts the pairing itself, after an app
  connects to an unpaired device, it shows its own dialog with the code the
  watch displays, and the user confirms on the Mac. The watch only shows the
  code. So the bridge never pairs; it opens a connection and the user clicks
  Connect.
- After pairing the watch takes no new connections. The link from pairing has
  to stay up until the Wear OS channel is open, as on a phone. The watch
  publishes the Wear OS service 2 to 3 s after pairing (RFCOMM channel 5 in
  every run), and its SDP server closes an idle connection after 30 s.
- SDP: IOBluetooth queries are answered from macOS's cache, which holds only
  the profiles macOS looked for (Handsfree, A2DP, AVRCP), and the completion
  callback often never arrives. The bridge asks the watch's SDP server itself
  over L2CAP PSM 1 (`SDPLink`), keeps that channel open as the link holder and
  repeats the query every 10 s until the RFCOMM channel is open.
- Internet: during setup the watch reaches the internet through the phone. The
  Pixel Watch app offers an RFCOMM service "Flow15"
  (`6a1eafb1-61c0-42a0-8bb0-a336fb1c3f00`, plus an LE L2CAP channel) and the
  watch connects to it on the device it is paired with, the Mac. Without it the
  account copy fails with "Remote device error" (10760) and setup stops at GMS
  check-in ("factory reset required"). The bridge publishes Flow15 on the Mac,
  hands every channel the watch opens to `fake_watch.py` (TCP, relay port + 1),
  which opens a channel to the phone's Flow15 over the phone's own RFCOMM
  session (odd DLCI, since the phone is the initiator there).
- Incoming RFCOMM on macOS: bluetoothd matches an incoming connection only
  against sessions that register *after* it arrived ("No sessions found saving
  incoming connection info", then "Found Incoming Connection channel" on the
  next registration). The bridge registers again every second while no proxy
  channel is open.
- Do not restart the bridge during setup. A proxy channel left open by a killed
  bridge stays attached to bluetoothd, and its data ends up in the next
  bridge's Wear OS channel, which garbles the stream to the phone. After such
  runs macOS also refused every new RFCOMM connect to the watch at once
  (`OI_RFCOMM_Connect` status 911, no callback); unpairing on the Mac and a
  factory reset of the watch clear it. The bridge gives an RFCOMM open 12 s.
- Setup steps seen in the app log: CDM discovery, pairing, watch connection,
  factory reset protection, Wi-Fi sync (fails: the emulator's network), Google
  accounts (FIDO direct transfer, needs the watch's internet), terms, digital
  warranty, GMS check-in (needs internet).

## Run with the watch

1. Emulator with the Pixel Watch app on its first screen; `fake_watch.py
   --relay 7700 --payload <payload with the fake address> --name <watch name>`
   running.
2. Watch factory reset (without a phone: Fastboot, see Google's Pixel Watch
   troubleshooting page) and on the pairing screen.
3. `tools/setup_run.sh`: waits for the watch's advertisement, removes a stale
   pairing on the Mac, starts setup in the app, picks the watch, confirms the
   emulator's pairing dialog and starts `mac/run.sh bridge <address> 7700 5`.
4. Click Connect in the macOS pairing dialog. The rest runs through the bridge.
5. Account step in the app: Sign in, screen lock, "Copy", screen lock.

## Run

- Emulator, in its own process group so it survives an interrupted shell:
  `emulator -avd pixelwatch_setup -no-audio -camera-back none -camera-front none -no-boot-anim -no-snapshot`.
  On the external PC keyboard AltGr+Q is ⌘Q and quits the emulator.
- Fake watch: `.venv/bin/python fake_watch.py [--relay PORT]` (needs `bumble`,
  `grpcio`, `protobuf`).
- Mac helper: `zsh mac/build.sh`, then `zsh mac/run.sh <command>`.
