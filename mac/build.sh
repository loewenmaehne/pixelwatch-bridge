#!/bin/zsh
# Builds mac/build/PixelWatchBridge.app and signs it with the Apple Development
# identity (stable signature, so macOS keeps the Bluetooth permission across
# rebuilds). Falls back to an ad-hoc signature.
set -euo pipefail

DIR="${0:A:h}"
APP="$DIR/build/PixelWatchBridge.app"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$DIR/Info.plist" "$APP/Contents/Info.plist"

xcrun swiftc -O -swift-version 5 \
  -framework IOBluetooth -framework CoreBluetooth -framework Network \
  -o "$APP/Contents/MacOS/PixelWatchBridge" "$DIR/main.swift"

if ! codesign --force --sign "${SIGN_IDENTITY:-Apple Development}" "$APP" 2>/dev/null; then
  codesign --force --sign - "$APP"
  echo "signed ad-hoc"
fi
codesign --display --verbose=1 "$APP" 2>&1 | grep -E "^(Identifier|Authority)=" | head -2
echo "built $APP"
