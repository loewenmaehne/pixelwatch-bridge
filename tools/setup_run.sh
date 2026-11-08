#!/bin/zsh
# Waits for the watch in pairing mode, then: removes the stale Mac pairing,
# starts "Add watch" in the app, picks the fake watch, confirms the emulator
# pairing and starts the bridge (macOS then asks to pair with the real watch).
REPO=/Users/julian/github/pixelwatch-bridge
ADB=$HOME/Library/Android/sdk/platform-tools/adb
WATCH=${1:?usage: tools/setup_run.sh <watch address> [CoreBluetooth id prefix]}
WATCH_ID=${2:-}

focus() { $ADB shell dumpsys window | grep -m1 "mCurrentFocus"; }
wait_focus() {  # wait_focus <pattern> <seconds>
  for i in $(seq 1 $2); do focus | grep -q "$1" && return 0; sleep 1; done
  return 1
}

until zsh $REPO/mac/run.sh watch-scan 10 2>/dev/null | grep -q "watch: ${WATCH_ID}"; do sleep 1; done
echo "$(date +%T) watch in pairing mode"
zsh $REPO/mac/run.sh unpair $WATCH | grep "unpair:"

$ADB shell input tap 540 2045            # "Add watch" on the Your watches screen
if wait_focus GrantPermissionsActivity 5; then
  sleep 1; $ADB shell input tap 540 1378 # allow nearby devices
  echo "$(date +%T) nearby devices allowed"
fi
if wait_focus CompanionAssociationActivity 20; then
  sleep 4                                # let the scan list the watch
  $ADB shell input tap 455 1081          # pick the watch in the list
  echo "$(date +%T) watch picked"
else
  echo "$(date +%T) no watch list shown: $(focus)"
fi
if wait_focus BluetoothPairingDialog 40; then
  sleep 1.5                              # let the dialog finish drawing
  for t in 1 2 3; do
    $ADB shell input tap 894 1491        # Pair
    sleep 1.5
    focus | grep -q BluetoothPairingDialog || break
  done
  echo "$(date +%T) emulator pairing confirmed"
fi
echo "$(date +%T) starting the bridge"
exec zsh $REPO/mac/run.sh bridge $WATCH 7700 5
