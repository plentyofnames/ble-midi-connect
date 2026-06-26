#!/bin/bash
# Build and install blemidi.
#
# Installs two things from one source (src/blemidi.m):
#   1. ~/.local/bin/blemidi            — CLI (list / status / connect / disconnect)
#   2. ~/Applications/BLEMIDIConnect.app — faceless .app used to run `connect` from
#      a menu-bar app (SwiftBar etc). CoreBluetooth needs a TCC grant, and only a
#      signed .app bundle with an on-disk Info.plist reliably gets its own
#      Bluetooth permission when launched by another app.
set -e
DIR="$(cd "$(dirname "$0")" && pwd)"
mkdir -p "$HOME/.local/bin"

CFLAGS=(-fobjc-arc -O2 -framework Foundation -framework CoreAudioKit -framework CoreMIDI)

# 1. CLI. Embedded Info.plist lets `blemidi list`/`connect` work from Terminal
#    (Terminal already holds a Bluetooth grant).
clang "${CFLAGS[@]}" \
    -Xlinker -sectcreate -Xlinker __TEXT -Xlinker __info_plist -Xlinker "$DIR/Info.plist" \
    "$DIR/src/blemidi.m" -o "$HOME/.local/bin/blemidi"
echo "installed CLI:  $HOME/.local/bin/blemidi"

# 2. BLEMIDIConnect.app — real bundle Info.plist + ad-hoc signature so TCC can
#    attribute and remember the Bluetooth grant to a stable identity.
APP="$HOME/Applications/BLEMIDIConnect.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
clang "${CFLAGS[@]}" "$DIR/src/blemidi.m" -o "$APP/Contents/MacOS/blemidi"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key>
    <string>com.plentyofnames.blemidiconnect</string>
    <key>CFBundleName</key>
    <string>BLEMIDIConnect</string>
    <key>CFBundleExecutable</key>
    <string>blemidi</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSBluetoothAlwaysUsageDescription</key>
    <string>BLEMIDIConnect connects your BLE-MIDI device through the CoreMIDI Bluetooth driver.</string>
</dict>
</plist>
PLIST
codesign --force --deep --sign - --identifier com.plentyofnames.blemidiconnect "$APP"
echo "installed app:  $APP"
echo
echo "Next: run  blemidi list  (from Terminal) to find your device's UUID."
