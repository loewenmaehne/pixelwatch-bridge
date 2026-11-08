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
- With the proxy inside the bridge, a restart during setup broke the run: a
  proxy channel left open by a killed bridge stayed attached to bluetoothd and
  its data ended up in the next bridge's Wear OS channel. After such runs macOS
  also refused every new RFCOMM connect to the watch at once
  (`OI_RFCOMM_Connect` status 911, no callback); unpairing on the Mac and a
  factory reset of the watch clear it. Since the proxy runs as its own process,
  restarting the bridge alone works (see stage 5).
- Setup steps seen in the app log: CDM discovery, pairing, watch connection,
  factory reset protection, Wi-Fi sync (fails: the emulator's network), Google
  accounts (FIDO direct transfer, needs the watch's internet), terms, digital
  warranty, GMS check-in (needs internet).

## Stage 5: setup completed (2026-11-08/09)

The first complete setup: the app reported setup status FINISHED and shows the
watch connected, with its battery level. What it took:

- Write completions: macOS 27 calls only
  `rfcommChannelWriteComplete:refcon:status:bytesWritten:`, never the variant
  without `bytesWritten`. Waiting for the old one made every write sit out the
  5 s stall timer. The writer now listens to both, carries its buffer as
  refcon and waits 0.1 s at most.
- Main queue held for 9 s at a time: an L2CAP open of the SDP link that failed
  or hung (the first open right after pairing fails with -536870212) completes
  later inside IOBluetooth, which then runs `openL2CAPChannelSync` with a
  nested run loop on the main queue (`instantiateChannel:findExisting:` →
  `waitforChanneOpen`). Every callback waited about 9 s, the watch's data came
  in 4 KB per 9 s and the app waited for "watch ready" forever. Found with
  `sample <pid>`. With the channel given, `bridge <address> 7700 <channel>`
  opens no SDP link; after that 1.2 MB came through in 9 s.
- Stale pipe for incoming channels: bluetoothd keeps the data pipe of a closed
  incoming channel registered ("Pipe 0x0019 is already registered in
  registerSocketInternal", then "Failed to register a socket"). The watch's
  next Flow15 connection on that channel opens and dies at once. `proxy 7701
  <channel>` takes a fresh channel instead (13, 14, … until bluetoothd
  restarts).
- "No free data structures" (Stack.RFCOMM) comes from the proxy's registration
  every second and stays until bluetoothd restarts. Runs still worked with it;
  it was not the cause of the stalls.
- Restarting the bridge in the middle of setup worked: the baseband link stayed
  up, the phone reconnected within a second and the app went on where it
  waited.
- After an aborted setup Play services reconnects to the fake watch every
  second. "Retry" on the app's "Can't connect" screen stops it and leads back
  to "Set up watch".
- Terms: the optional ones are 1 usage and diagnostic reports, 3 location and
  5 watch backup; diagnostics is ticked by default. The app logs the choice
  ("Accepted terms: 3, 5, 2", "Logging terms were accepted is: false").
- Steps after the terms: warranty, orientation, band, decision point, Fitbit,
  Spacetime, safety, screen lock, Pay, app install, exit.

Order that worked: watch on its pairing screen; unpair on the Mac; `bridge
<address> 7700` (macOS asks to pair, click Connect at once); after "bridge:
ready" start setup in the app and confirm the emulator's pairing; once the
Wear OS channel is open, `proxy 7701 <fresh channel>`; if the data crawls,
restart the bridge with the channel from the log.

## Run

Install and run steps are in `README.md`. `tools/setup_run.sh` follows the
order above; `restart` restarts the bridge with the Wear OS channel given,
`stop` stops bridge and proxy. Start the emulator in its own process group,
so it survives an interrupted shell.
