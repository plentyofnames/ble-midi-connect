#!/bin/bash
#
# <bitbar.title>BLE-MIDI Connect</bitbar.title>
# <bitbar.version>v1.0</bitbar.version>
# <bitbar.desc>Menu-bar toggle to connect/disconnect a BLE-MIDI device via the macOS CoreMIDI Bluetooth driver (low latency).</bitbar.desc>
# <bitbar.dependencies>blemidi</bitbar.dependencies>
#
# Example SwiftBar plugin. Set UUID to your device (find it with `blemidi list`),
# then drop this file in your SwiftBar plugins folder.

# --- configure -------------------------------------------------------------
UUID="REPLACE-WITH-YOUR-DEVICE-UUID"     # e.g. A1B2C3D4-E5F6-7890-ABCD-EF1234567890
LABEL="BLE keyboard"
# ---------------------------------------------------------------------------

CLI="$HOME/.local/bin/blemidi"
APP="$HOME/Applications/BLEMIDIConnect.app"

if [ ! -x "$CLI" ]; then
    echo ":pianokeys:"; echo "---"; echo "blemidi not installed | color=red"; exit 0
fi

CONNECT="bash=/usr/bin/open param1=-n param2=$APP param3=--args param4=connect param5=$UUID terminal=false refresh=true"
echo ":pianokeys:"
echo "---"

if "$CLI" status "$UUID" >/dev/null 2>&1; then
    # disconnect is CoreMIDI-only, safe to run straight from SwiftBar
    echo "$LABEL — connected | sfimage=checkmark.circle.fill bash=$CLI param1=disconnect param2=$UUID terminal=false refresh=true"
else
    # Three-state: connected / available / off. A scan can only run in the signed
    # .app, so kick a throttled `probe` (writes /tmp/blemidi-<UUID>.state) and show
    # its last result. `connect` itself also goes through the .app for the TCC grant.
    STATE_FILE="/tmp/blemidi-$(printf '%s' "$UUID" | tr '[:lower:]' '[:upper:]').state"
    now=$(date +%s); mt=$(stat -f %m "$STATE_FILE" 2>/dev/null || echo 0)
    [ $((now - mt)) -ge 10 ] && /usr/bin/open -n "$APP" --args probe "$UUID" >/dev/null 2>&1
    case "$(cat "$STATE_FILE" 2>/dev/null)" in
        available) echo "$LABEL — available, tap to connect | sfimage=circle $CONNECT" ;;
        off)       echo "$LABEL — off (powered down) | sfimage=zzz $CONNECT" ;;
        *)         echo "$LABEL — tap to connect | sfimage=circle $CONNECT" ;;
    esac
fi

echo "---"
echo "List BLE-MIDI devices… | bash=$CLI param1=list terminal=true"
