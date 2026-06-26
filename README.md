# ble-midi-connect

Connect a **BLE-MIDI** device on macOS at the **low latency** you get from Audio
MIDI Setup — but as a one-shot CLI and a menu-bar toggle, with no manual clicking
through AMS every time.

```
blemidi list                 # find your device's UUID
blemidi connect   <UUID>     # connect (low latency, via the system driver)
blemidi disconnect <UUID>    # disconnect
blemidi status    <UUID>     # connected? (exit 0 = yes)
```

## The problem this solves

If you write your own macOS app that connects a BLE-MIDI keyboard with
`CBCentralManager` and reads the MIDI characteristic yourself, you get macOS's
**default BLE connection interval (~30 ms)**. That's very audible on a keyboard:
chords arrive smeared across several radio events, and fast runs back up and keep
playing after you've stopped. There is **no public CoreBluetooth API** to request
a faster interval.

Audio MIDI Setup's Bluetooth window doesn't have this problem with the same
keyboard — but it won't auto-reconnect and takes several clicks to reach.

## How it works

Reverse-engineering AMS shows it doesn't keep the connection in its own process.
Its connection engine (CoreAudioKit's private `AMSBTLEConnectionManager`) does the
**discovery + pairing**, then logs:

```
Instructing the driver to connect to peripheral with UUID …
Disconnecting from UI for peripheral … . The driver will manage the connection.
```

i.e. it **hands the connection off to the CoreMIDI Bluetooth driver** (running in
`midiserver`) and drops its own link. The driver owns the data path at a fast
interval — that's the low latency. The app that initiated it isn't in the data
path at all (you can quit it and the keyboard stays connected).

`blemidi` reproduces exactly that:

- **`connect`** drives `AMSBTLEConnectionManager` to scan, pair, and hand off, then
  exits. The driver keeps the connection alive — **no daemon required.**
- **`disconnect`** calls the driver's `MIDIBluetoothDriverDisconnect(uuid)`.
- **`status`** reads the device's `kMIDIPropertyOffline` (maps UUID↔device via the
  private `BLEMIDIAccessor`). CoreMIDI-only, no Bluetooth.
- **`list`** scans and prints discovered BLE-MIDI peripherals.

## Install

```sh
git clone https://github.com/plentyofnames/ble-midi-connect
cd ble-midi-connect
./build.sh
```

This installs:

- `~/.local/bin/blemidi` — the CLI
- `~/Applications/BLEMIDIConnect.app` — a faceless, ad-hoc-signed app used to run
  `connect` from a menu-bar app (see below)

First run `blemidi list` from Terminal; macOS will prompt for Bluetooth access —
allow it. Note the UUID of your device.

## Menu-bar toggle (SwiftBar)

`swiftbar/ble-midi.5s.sh` is a ready-to-use [SwiftBar](https://swiftbar.app)
plugin: a latching connect/disconnect toggle. Set `UUID` at the top to your
device, drop it in your SwiftBar plugins folder, and click to connect.

### Why `connect` goes through the .app

A bare CLI doing CoreBluetooth, **launched by another app** (SwiftBar), gets
killed by TCC — macOS attributes the Bluetooth request to a process that has no
Bluetooth grant and can't surface a prompt. A **signed `.app` bundle with an
on-disk `Info.plist`** has a stable identity TCC can grant and remember, so
`connect` is launched via `open -n BLEMIDIConnect.app --args connect <UUID>`.
`status`/`disconnect` don't touch Bluetooth, so they run as the plain CLI.

First connect click prompts *"BLEMIDIConnect wants to use Bluetooth"* → Allow.
That first click may only grant permission; click once more to actually connect.

## Auto-reconnect

There isn't any, by design — when the device sleeps or powers off you reconnect
with one click. The connection is owned by `midiserver`, so nothing of yours runs
in the background. If you want hands-free reconnect, a small timer that runs
`blemidi connect <UUID>` whenever `blemidi status <UUID>` reports offline does the
job.

## Caveats

- **Private API.** This relies on undocumented symbols — CoreAudioKit's
  `AMSBTLEConnectionManager` and CoreMIDI's `MIDIBluetoothDriverDisconnect` /
  `BLEMIDIAccessor`. They've been stable for years (the AMS Bluetooth UI hasn't
  changed in a decade), but a future macOS could rename them. The tool degrades
  gracefully (prints "unavailable") rather than crashing. If a macOS update breaks
  it, rebuild first; if a symbol was renamed, the runtime-introspection approach in
  the git history shows how to find the new names.
- **The device must be paired in Audio MIDI Setup once** (so the system knows it),
  if it isn't already discoverable.
- Tested on Apple Silicon, current macOS.

## License

MIT — see [LICENSE](LICENSE).
