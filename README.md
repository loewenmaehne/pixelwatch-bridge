# pixelwatch-bridge

Sets up a Google Pixel Watch from a Mac, without an Android phone.

The Pixel Watch app runs in the Android emulator. A fake watch inside the emulator's virtual Bluetooth takes the app's connection, and a small Mac app relays it to the real watch over the Mac's built-in Bluetooth. During setup the watch also gets its internet through this chain, in the other direction.

It has worked once, end to end: on 9 November 2026 the app reported setup status FINISHED for a Pixel Watch 4. It has not been tried with another watch or another Mac. Expect to read logs.

## How it works

```
                 Wear OS channel, opened by the app
       ----------------------------------------------------------------->
+-----------------+        +---------------+  TCP 7700  +-------------+        +--------------+
| Pixel Watch app | netsim | fake_watch.py | ---------> | mac: bridge | RFCOMM | Pixel Watch  |
| (emulator)      | ------ | (Bumble)      | <--------- | mac: proxy  | ------ | (setup mode) |
+-----------------+        +---------------+  TCP 7701  +-------------+        +--------------+
       <-----------------------------------------------------------------
                 Flow15 internet proxy, opened by the watch
```

1. The app finds watches with a BLE scan filter on Google's manufacturer data. `fake_watch.py` sends that advertisement from inside netsim, so the app lists it.
2. The app bonds with the fake watch over classic Bluetooth, and `fake_watch.py` confirms the code. On the Mac, bluetoothd pairs with the real watch and shows its own dialog, where you click Connect.
3. The phone's Wear OS stack opens the RFCOMM service `5E8945B0-9525-11E3-A5E2-0800200C9A66` on the watch. `fake_watch.py --relay 7700` hands that channel to the Mac app over TCP, and `bridge` opens the same service on the real watch and passes the bytes through unchanged.
4. During setup the watch goes online through the phone's RFCOMM service "Flow15" (`6a1eafb1-61c0-42a0-8bb0-a336fb1c3f00`), which it looks for on the device it is paired with: the Mac. `proxy` publishes Flow15 on the Mac and hands every channel the watch opens to `fake_watch.py` on port 7701, which opens the matching channel to the app.

[NOTES.md](NOTES.md) has the findings behind each step, in the order they came up.

## Requirements

- A Mac with Apple silicon and built-in Bluetooth, on macOS 27. Tested on macOS 27.0.1 on an M1.
- Xcode command line tools (`xcrun swiftc`). Tested with Swift 6.4.
- Android SDK with the emulator (tested 36.2.11), platform-tools (`adb`) and the system image `system-images;android-35;google_apis_playstore;arm64-v8a`.
- An emulator (AVD) from that image with the Pixel 7 profile, 1080 x 2400. The taps in `tools/setup_run.sh` assume that screen.
- In the emulator: a Google account and the Pixel Watch app from Google Play (tested 5.1.0).
- Python with `bumble`, `grpcio` and `protobuf`. Tested with Python 3.12, bumble 0.0.236, grpcio 1.85.1 and protobuf 7.36.2.
- A Pixel Watch in setup mode, after a factory reset. Tested only with a Pixel Watch 4.

## Install

```sh
python3 -m venv .venv
.venv/bin/pip install bumble grpcio protobuf
zsh mac/build.sh
```

`mac/build.sh` builds `mac/build/PixelWatchBridge.app`. It signs the app with an "Apple Development" identity if there is one, so macOS keeps the Bluetooth permission across rebuilds, and falls back to an ad hoc signature. Set `SIGN_IDENTITY` to use another identity. The first Mac command asks for Bluetooth access.

The emulator, from the command line or with Android Studio's Device Manager:

```sh
sdkmanager "emulator" "platform-tools" "system-images;android-35;google_apis_playstore;arm64-v8a"
avdmanager create avd -n pixelwatch_setup -d pixel_7 -k "system-images;android-35;google_apis_playstore;arm64-v8a"
emulator -avd pixelwatch_setup -no-audio -camera-back none -camera-front none -no-boot-anim -no-snapshot
```

Sign in to Google Play in the emulator and install the Pixel Watch app.

## Run

1. Start the emulator and open the Pixel Watch app on its "Your watches" screen.
2. Factory reset the watch so it shows its pairing screen. Without a phone this works through Fastboot, see Google's Pixel Watch troubleshooting page.
3. Read the watch's advertisement:

   ```sh
   zsh mac/run.sh watch-scan
   ```

   It prints the watch's name and `watch: payload <hex>`, the manufacturer data after the company id. Bytes 10 to 15 of the payload, counted from 0 (hex characters 21 to 32), are the watch's Bluetooth address.

4. Start the fake watch once and note the address it prints (`advertising as ... (<address>/P)`):

   ```sh
   .venv/bin/python fake_watch.py --relay 7700
   ```

   The app bonds with the address of the watch it picked, so the payload has to carry the fake watch's own address. Stop the fake watch, write its address without colons and without `/P` into bytes 10 to 15 of the watch's payload and start it again with the result. Check that it prints the same address as before.

   ```sh
   .venv/bin/python fake_watch.py --relay 7700 --payload <new payload> --name "<watch name>"
   ```

5. Run the setup script. When macOS asks to pair with the watch, click Connect right away.

   ```sh
   zsh tools/setup_run.sh
   ```

6. Go through setup in the app. At the account step: Sign in, screen lock, Copy, screen lock.

`tools/setup_run.sh` follows the order of the run that worked:

1. It waits for the watch on its pairing screen and reads the address from `watch-scan`.
2. It removes an old pairing of that address from the Mac (`unpair`).
3. It starts `bridge <address> 7700`. The bridge connects to the watch's SDP server, bluetoothd pairs and shows its dialog, and the bridge holds the link and asks for the Wear OS service until the watch publishes it ("bridge: ready").
4. It starts setup in the app with `adb` taps, picks the watch and confirms the emulator's pairing dialog. If a tap misses, do that step by hand; the script waits.
5. Once the Wear OS channel is open, it starts `proxy 7701 <channel>` on an RFCOMM channel that no proxy used since bluetoothd started (see Limits).

Logs go to `mac/build/bridge.log` and `mac/build/proxy.log`. Bridge and proxy keep running after the script ends.

If the watch's data crawls, with bridge log lines about 9 s apart while the app waits, restart the bridge with the Wear OS channel given, so it opens no SDP link:

```sh
zsh tools/setup_run.sh restart
```

This worked in the middle of setup: the link to the watch stayed up, the emulator reconnected within a second and the app went on where it had waited. `zsh tools/setup_run.sh stop` stops bridge and proxy.

## Mac commands

`zsh mac/run.sh <command>` runs the Mac app through Launch Services, so that macOS attributes the Bluetooth use to the app, and prints its log.

| Command | What it does |
| --- | --- |
| `watch-scan [seconds]` | Waits for a watch in setup mode (the app's scan filter) and prints its advertisement |
| `le-scan [seconds] [--google]` | Lists BLE advertisements |
| `inquiry [seconds] [--le\|--both]` | Device inquiry; delivered no results on macOS 27 |
| `paired` | Lists the devices paired with the Mac |
| `pair <address>` | Pairs through `IOBluetoothDevicePair`; times out on macOS 27, see Limits |
| `unpair <address>` | Removes a pairing from the Mac (private IOBluetooth API) |
| `sdp <address>` | Lists SDP records through IOBluetooth |
| `services <address>` | Lists the SDP records macOS has cached |
| `sdp-raw <address>` | Asks the watch's SDP server directly for the Wear OS service |
| `disconnect <address>` | Drops the link and keeps the pairing |
| `bridge <address> <port> [channel]` | Relays the watch's Wear OS channel to TCP clients on 127.0.0.1:`<port>` |
| `proxy <port> [channel]` | Publishes Flow15 on RFCOMM `<channel>` (default 12) and hands the watch's channels to 127.0.0.1:`<port>` |

## When a run fails

- After an aborted setup, Play services in the emulator reconnects to the fake watch every second. Tap Retry on the app's "Can't connect" screen to stop it.
- If the app lists no watch after Retry, a stale scanner may hold the results. Force-stop `com.google.android.apps.wear.companion` and `com.android.companiondevicemanager` with `adb shell am force-stop`, then turn Bluetooth in the emulator off and on.
- If the link to the watch drops before the Wear OS channel is open, start over from the watch's pairing screen. After pairing the watch takes no new connections.

## Limits

- It has worked once, with one Pixel Watch 4 on one Mac.
- macOS ignores pairing confirmations from apps without Apple's entitlement for programmatic pairing. So the bridge lets bluetoothd pair, and you confirm its dialog on the Mac.
- bluetoothd on macOS 27 has quirks the tool works around but cannot fix:
  - It keeps the data pipe of a closed incoming RFCOMM channel registered. Each proxy run needs a channel no proxy used since bluetoothd started; a reboot starts it fresh. `tools/setup_run.sh` keeps count in `mac/build/proxy_channels`, and `PROXY_CHANNEL=<n>` overrides its choice.
  - A bridge killed while a channel was open left that channel in bluetoothd. Afterwards macOS refused every RFCOMM connect to the watch until the pairing was removed on the Mac and the watch was reset. The Mac app closes its channels on SIGTERM and SIGINT; never stop it with SIGKILL.
- The tool does not touch factory reset protection. A watch locked to another Google account stays locked.
- Wi-Fi sync fails during setup, because the emulator only has its virtual network. Add Wi-Fi on the watch afterwards.
- After setup the watch treats the Mac, through the emulator, as its phone. What it does once the bridge stops has not been tested.
- The taps in `tools/setup_run.sh` are fixed screen positions for a 1080 x 2400 screen and Pixel Watch app 5.1.0.
- `fake_watch.py` writes raw captures of the Wear OS channel to `captures/` and its pairing keys to `keys.json`, and the Mac app's logs in `mac/build/` contain Bluetooth addresses. All of them are gitignored. Remove device ids before you share any of it.

## Not affiliated with Google

This is an independent project, not affiliated with, endorsed or supported by Google. Pixel, Pixel Watch, Wear OS, Android and Google Play are trademarks of Google LLC. Mac and macOS are trademarks of Apple Inc.

The Android emulator is part of the Android SDK, which Google licenses for developing apps for Android (Android Software Development Kit License Agreement, section 3). Check that your use fits those terms.

## No support

The code is shared as is, for anyone stuck in the same spot. There is no support, and issues and pull requests may go unanswered.

## License

MIT, see [LICENSE](LICENSE).
