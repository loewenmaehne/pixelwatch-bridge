#!/bin/zsh
# Runs the bridge app through Launch Services (so macOS attributes Bluetooth
# use to the app itself) and prints its output. Example:
#   mac/run.sh le-scan 20 --google
set -euo pipefail

DIR="${0:A:h}"
APP="$DIR/build/PixelWatchBridge.app"
LOG="${PIXELWATCH_BRIDGE_LOG:-$DIR/build/${1:-help}.log}"

: > "$LOG"
open -W -n --stdout "$LOG" --stderr "$LOG" "$APP" --args "$@"
cat "$LOG"
