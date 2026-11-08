#!/bin/zsh
# Sets up a Pixel Watch in the order that worked (NOTES.md, stage 5):
#   1. wait for the watch on its pairing screen and read its address from the
#      advertisement (watch-scan),
#   2. remove an old pairing of that address from the Mac,
#   3. start the bridge without a channel: macOS asks to pair (click Connect at
#      once), the bridge holds the link and finds the Wear OS channel over SDP,
#   4. after "bridge: ready", start setup in the Pixel Watch app and confirm the
#      emulator's pairing dialog (taps for a 1080 x 2400 screen, app 5.1.0),
#   5. once the Wear OS channel is open, start the Flow15 proxy on an RFCOMM
#      channel that no proxy used since bluetoothd started.
# Needs the emulator with the Pixel Watch app on its "Your watches" screen and
# fake_watch.py --relay 7700 running with the watch's payload (see README.md).
#
#   zsh tools/setup_run.sh          run setup as above
#   zsh tools/setup_run.sh restart  restart the bridge with the Wear OS channel
#                                   given, so it opens no SDP link (when the
#                                   watch's data crawls)
#   zsh tools/setup_run.sh stop     stop bridge and proxy with SIGTERM, so they
#                                   close their channels
set -u

SELF=${0:A}
REPO=${SELF:h:h}
RUN=$REPO/mac/run.sh
BUILD=$REPO/mac/build
ADB=${ADB:-$HOME/Library/Android/sdk/platform-tools/adb}
PORT=7700                       # fake_watch.py --relay; the proxy uses PORT + 1
STATE=$BUILD/setup_run.state    # watch address and Wear OS channel of the last run
CHANNELS=$BUILD/proxy_channels  # "<bluetoothd pid> <channel>" for each proxy start
BRIDGE_LOG=$BUILD/bridge.log    # mac/run.sh logs to mac/build/<command>.log
PROXY_LOG=$BUILD/proxy.log

say() { print -r -- "$(date +%T) $*"; }
die() { say "$*"; exit 1; }

app_running() { pgrep -qf "MacOS/PixelWatchBridge $1 "; }

start_app() {  # start_app <command> [args]: runs in the background
  : > "$BUILD/$1.log"
  zsh "$RUN" "$@" > /dev/null 2>&1 &!
}

stop_app() {  # stop_app <command>: SIGTERM, then wait up to 5 s
  local i
  app_running $1 || return 0
  pkill -TERM -f "MacOS/PixelWatchBridge $1 "
  for (( i = 0; i < 50; i++ )); do
    app_running $1 || return 0
    sleep 0.1
  done
  say "$1 still runs 5 s after SIGTERM"
  return 1
}

wait_log() {  # wait_log <file> <pattern> <seconds>
  local i
  for (( i = 0; i < $3; i++ )); do
    grep -q -- "$2" "$1" 2>/dev/null && return 0
    sleep 1
  done
  return 1
}

focus() { "$ADB" shell dumpsys window | grep -m1 mCurrentFocus; }
wait_focus() {  # wait_focus <pattern> <seconds>
  local i
  for (( i = 0; i < $2; i++ )); do
    focus | grep -q -- "$1" && return 0
    sleep 1
  done
  return 1
}

scan_watch() {  # sets WATCH to the address of the one watch in setup mode
  local out line hex
  local -a found
  say "waiting for a watch on its pairing screen"
  while true; do
    out=$(zsh "$RUN" watch-scan 10 2>/dev/null)
    found=()
    for line in ${(f)out}; do
      [[ $line == *"watch: payload "* ]] || continue
      hex=${line##*watch: payload }
      (( ${#hex} >= 32 )) || continue
      # Bytes 10 to 15 of the payload (after the company id) hold the address.
      hex=${(U)hex[21,32]}
      found+=("${hex[1,2]}:${hex[3,4]}:${hex[5,6]}:${hex[7,8]}:${hex[9,10]}:${hex[11,12]}")
    done
    found=(${(u)found})
    (( ${#found} > 1 )) && die "${#found} watches in setup mode nearby; leave only one on its pairing screen"
    (( ${#found} == 1 )) && break
    sleep 1
  done
  WATCH=$found[1]
}

next_proxy_channel() {  # sets CHANNEL to one that no proxy used since bluetoothd started
  local pid used
  pid=$(pgrep -x bluetoothd | head -1)
  used=$(awk -v pid="$pid" 'BEGIN { n = 0 } $1 == pid && $2 + 0 > n { n = $2 + 0 } END { print n }' \
    "$CHANNELS" 2>/dev/null)
  CHANNEL=${PROXY_CHANNEL:-$(( used ? used + 1 : 12 ))}
  (( CHANNEL <= 30 )) || die "every RFCOMM channel was used since bluetoothd started; restart the Mac"
  print -r -- "$pid $CHANNEL" >> "$CHANNELS"
}

start_setup_in_app() {  # taps for a 1080 x 2400 screen and Pixel Watch app 5.1.0
  local t wait=40
  "$ADB" shell input tap 540 2045             # "Add watch" on the Your watches screen
  if wait_focus GrantPermissionsActivity 5; then
    sleep 1; "$ADB" shell input tap 540 1378  # allow nearby devices
    say "nearby devices allowed"
  fi
  if wait_focus CompanionAssociationActivity 20; then
    sleep 4                                   # let the scan list the watch
    "$ADB" shell input tap 455 1081           # pick the watch in the list
    say "watch picked"
  else
    say "no watch list in the app ($(focus)); start setup and pick the watch by hand"
    wait=120
  fi
  if wait_focus BluetoothPairingDialog $wait; then
    sleep 1.5                                 # let the dialog finish drawing
    for t in 1 2 3; do
      "$ADB" shell input tap 894 1491         # Pair
      sleep 1.5
      focus | grep -q BluetoothPairingDialog || break
    done
    say "emulator pairing confirmed"
  else
    say "no pairing dialog in the emulator; confirm it by hand if it comes"
  fi
}

setup() {
  local channel stop_hint="bridge and proxy keep running, stop them with: zsh $SELF stop"
  [[ -x $BUILD/PixelWatchBridge.app/Contents/MacOS/PixelWatchBridge ]] \
    || die "Mac app missing, build it first: zsh $REPO/mac/build.sh"
  [[ $("$ADB" get-state 2>/dev/null) == device ]] || die "adb finds no single emulator ($ADB)"
  app_running bridge && die "a bridge runs already, stop it first: zsh $SELF stop"
  app_running proxy && die "a proxy runs already, stop it first: zsh $SELF stop"
  pgrep -qf "fake_watch.py.*--relay $PORT" || say "fake_watch.py --relay $PORT does not seem to run"

  scan_watch
  say "watch in setup mode: $WATCH"
  zsh "$RUN" unpair "$WATCH" | grep "unpair:"
  print -r -- "watch=$WATCH" > "$STATE"

  start_app bridge "$WATCH" $PORT
  say "bridge started: click Connect in the macOS pairing dialog now"
  wait_log "$BRIDGE_LOG" "bridge: ready" 120 \
    || die "no Wear OS service after 120 s, see $BRIDGE_LOG; $stop_hint"
  channel=$(grep -m1 -o "Wear OS service on RFCOMM channel [0-9]*" "$BRIDGE_LOG" | grep -o "[0-9]*$")
  print -r -- "channel=$channel" >> "$STATE"
  say "bridge ready, Wear OS service on RFCOMM channel $channel"

  start_setup_in_app

  say "waiting for the Wear OS channel to the watch"
  wait_log "$BRIDGE_LOG" "bridge: RFCOMM open status=0 " 300 \
    || die "Wear OS channel not open after 300 s, see $BRIDGE_LOG; $stop_hint"
  say "Wear OS channel open"

  next_proxy_channel
  start_app proxy $(( PORT + 1 )) $CHANNEL
  wait_log "$PROXY_LOG" "Flow15 service published" 10 \
    || die "the proxy did not publish Flow15, see $PROXY_LOG; $stop_hint"
  say "proxy: Flow15 on $(grep -m1 -o 'RFCOMM channel [0-9]*' "$PROXY_LOG")"

  grep -q "sdplink: open failed" "$BRIDGE_LOG" \
    && say "an SDP link open failed while pairing; in earlier runs that stalled the bridge 9 s at a time"
  say "logs: $BRIDGE_LOG and $PROXY_LOG; $stop_hint"
  say "go on in the app; if the watch's data crawls, run: zsh $SELF restart"
}

restart() {
  local watch channel
  [[ -f $STATE ]] || die "no earlier run found ($STATE)"
  watch=$(sed -n 's/^watch=//p' "$STATE")
  channel=$(sed -n 's/^channel=//p' "$STATE")
  [[ -n $watch && -n $channel ]] || die "address or channel missing in $STATE"
  stop_app bridge || die "the old bridge did not stop"
  start_app bridge "$watch" $PORT "$channel"
  say "bridge restarted with RFCOMM channel $channel, waiting for the Wear OS channel"
  wait_log "$BRIDGE_LOG" "bridge: RFCOMM open status=0 " 60 \
    || die "Wear OS channel not open again after 60 s, see $BRIDGE_LOG"
  say "Wear OS channel open again"
}

stop_all() {
  stop_app bridge
  stop_app proxy
  app_running bridge || app_running proxy || say "bridge and proxy stopped"
}

case ${1:-} in
  "") setup ;;
  restart) restart ;;
  stop) stop_all ;;
  *) print -r -- "usage: zsh $SELF [restart|stop]"; exit 2 ;;
esac
