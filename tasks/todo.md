# Single, consistently-named BLE MIDI device on Apple platforms

## Problem
On iOS, a BLE MIDI peripheral appears twice:
- via `UniversalBleMidiTransport` (CoreBluetooth) with its advertised name — but
  this path **cannot exchange data** after bonding (CoreMIDI claims the GATT
  characteristic).
- via CoreMIDI as a duplicate named "Bluetooth" — this path **works** for data.

Goal: one device in the list, consistent (advertised) name through discovery →
connection → pairing → bonding, supporting multiple devices and multiple
concurrent connections.

## Decided design (confirmed with user)
- Android/Linux/Windows/Web: keep `universal_ble` GATT as the data path (unchanged).
- iOS/macOS: `universal_ble` is used only for scan + pair/bond. **CoreMIDI carries
  the data.** The single visible entry stays the `universal_ble` device (stable id +
  advertised name); the CoreMIDI "Bluetooth" duplicate is hidden but used under the
  hood as the data transport.

## Correlation key (FOUND on device)
CoreMIDI Bluetooth device exposes property `"BLE MIDI Device UUID"` ==
the universal_ble `deviceId` (CoreBluetooth UUID), e.g.
`79A0DE45-5296-B31C-7162-2A07A8E84643`. Device-level `name` = "PP-3 - MIDI"
(entity name is the generic "Bluetooth", which is why the list showed
"Bluetooth"). driver = com.apple.AppleMIDIBluetoothDriver.

## Implementation (unified id = BLE UUID; no pigeon schema change)
Swift (darwin):
- [x] Helper `bleMidiDeviceUUID(_:)` reads the `"BLE MIDI Device UUID"` property.
- [x] Helper `bluetoothEntity(forUUID:)` resolves UUID -> (device, entity).
- [x] getDevices(): Bluetooth devices report `id = UUID`, `name = device name`.
- [x] ConnectedNativeDevice resolves a UUID id -> entity (so connect/data work).
- [x] Disable diagnostics (dump flag false; remove temp register/setup logs).

Dart (lib/flutter_midi_command.dart):
- [x] devices: dedup by shared id. Bonded -> show advertised-name entry routed to
      platform (CoreMIDI). Un-bonded -> advertised entry routed to bleTransport.
- [x] connectToDevice: pre-bond connect via bleTransport (pair/bond), then
      background handoff to platform once the CoreMIDI counterpart appears.
- [x] disconnectDevice: tear down both routes for a bonded BLE device.
- [x] Remove temp FMC_DIAG logging.

## Verify (USER STEP, on real iOS device)
- [ ] Single entry per device, advertised name throughout lifecycle.
- [ ] Data (incl. the app's SysEx handshake) works after bonding.
- [ ] Multiple devices + multiple concurrent connections work.
- [ ] Android still uses universal_ble data path (no regression).

## Review
Implemented (needs on-device verification — no iOS toolchain in dev env):
- Swift: BLE CoreMIDI devices now report `id = "BLE MIDI Device UUID"` and the
  descriptive device name; UUID ids resolve back to the entity on connect.
- Dart: `devices` merges the universal_ble entry and the CoreMIDI entry by shared
  id into one visible device; bonded devices route data via CoreMIDI.
- Dart: `connectToDevice` pairs via universal_ble then background-hands-off the
  data path to CoreMIDI when the bonded device appears; `disconnectDevice` tears
  down both. No-op handoff on Android (universal_ble stays the data path).
- Removed all temp diagnostics. Added `darwin/` podspec (real repo bug) and
  example `pubspec_overrides.yaml`.

KNOWN FOLLOW-UP: the CoreMIDI device appears ~10s after pairing, so an app that
runs an immediate post-connect handshake (e.g. the GEWA "Verify Piano link"
SysEx) may still race the handoff. Option: make connect on Apple report
"connected" only once the platform data path is ready. Decide after testing.
