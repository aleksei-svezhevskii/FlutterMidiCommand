# BLE MIDI write throughput

## Problem

SysEx transfers over the BLE transport are far slower than the link allows. A
GEWA piano firmware update (188 KB, 1,686 SysEx messages of 137 bytes) took
13 minutes — about 340 bytes/second.

Root cause, in two parts:

1. `send()` hard-coded `packetSize = 20`, so a 137-byte SysEx went out as 8 BLE
   writes. `_requestMtu()` already negotiated 247 and discarded the result.
2. `universal_ble` queues every write in one global FIFO and completes it only
   from the platform's write callback — even for `WRITE_TYPE_NO_RESPONSE`
   (`UniversalBlePlugin.kt` `writeValue`/`onCharacteristicWrite`). So each write
   costs a full BLE connection event: measured ~58 ms, ×8 = 463 ms per SysEx.

The same mechanism explains a regression reported after apps moved from the
0.4.x native Android BLE path to 1.0.x. That path was fire-and-forget, so an
app-level fixed send interval (e.g. 40 ms) was *slower* than the stack. On 1.0.x
the same interval is ~11× *faster* than the real drain rate, so the queue backs
up by minutes and any teardown truncates the transfer. `_sendBytes` swallowed
every error with `catch (_) {}`, so none of it was observable.

## Changes

- [x] Size writes from the negotiated MTU. `_requestMtu` stores `mtu - 3` in
      `_maxWriteSize`; correct on both platforms, since universal_ble's darwin
      side returns `maximumWriteValueLength(.withoutResponse) + 3`. Floors at 20
      and resets on every disconnect so a large size cannot leak into a
      reconnect that negotiates smaller.
- [x] Replace the inline chunker with `buildBleMidiSysExPackets`, a pure
      function. This also fixes a framing bug: when the remainder was exactly
      `packetSize - 1` bytes the closing `0xF7` went out with no preceding
      timestamp byte. Verified against the old algorithm — 15 SysEx lengths in
      0..300 were affected, every 19 bytes from 18 up.
- [x] Request `BleConnectionPriority.highPerformance` on connect, `balanced` on
      disconnect. Placed after service discovery and subscription for the same
      reason as the MTU request: they share universal_ble's command queue, and
      going early stalls discovery into Android's GATT 133.
- [x] Report write failures on `MidiBleTransport.onWriteFailure`, surfaced as
      `MidiCommand.onBleWriteFailure`. `_sendBytes` still continues after a
      failure — abandoning the rest of a SysEx would leave the peripheral
      parsing a truncated message — but the caller can now see it.
- [x] `useNegotiatedMtu` and `requestHighPerformanceConnection` constructor
      flags, both defaulting to true, documented in both READMEs.

## Review

**Result: the premise was wrong.** The changes work as designed and do not
speed up firmware transfers, because the BLE write path was never the
bottleneck.

Measured on Android against a PP-3, with the changes active (`negotiated MTU
96, packet size 93`, `connection priority set to highPerformance`, `137-byte
SysEx -> 2 write(s)`, down from 8):

| Packet | send | awaiting piano |
|---|---|---|
| 0 (header) | 2.1 ms | 392.5 ms |
| 25 | 0.9 ms | 492.4 ms |
| 50 | 1.5 ms | 494.7 ms |
| 75 | 1.3 ms | 492.0 ms |
| 100 | 1.7 ms | 507.6 ms |

The app spends ~1.4 ms per packet; the piano spends ~495 ms. The write path is
**0.3%** of the round trip. Cutting writes 4x and the connection interval ~4x
moved the per-packet time not at all — it stayed at ~500 ms, and the transfer
stayed at ~14 minutes (1685 x 0.5 s).

**Where the original analysis went wrong.** The 463 ms per packet was
decomposed into "8 writes x 58 ms per connection event" by reading the
universal_ble source and the connection-interval spec. That decomposition was
never measured. The write cost was real but two orders of magnitude smaller
than assumed; the 463 ms was always the peripheral. The lesson is narrow and
concrete: an end-to-end timing split costs ten lines of instrumentation and
should have come before the fix, not after it.

**What is still worth shipping.** All of it, on its own merits, with the
throughput claim removed:

- 4x fewer BLE writes per SysEx — less radio time, less queue pressure.
- A ~7.5-15 ms connection interval instead of ~30-50 ms on Android, which is a
  genuine latency improvement for ordinary MIDI playing.
- The missing-timestamp-before-`0xF7` framing fix, a real correctness bug.
- `onWriteFailure`, which turns silently dropped writes into a signal.

**What would actually speed up firmware transfers.** Fewer round trips. At
~495 ms each, the only lever is more payload per acknowledged message. The app
currently moves 112 raw bytes per round trip, capped by `_maximumGroupCount =
16` — a limit of the piano protocol's 7-bit packet-size field, not of BLE (93-
byte writes work fine, and a 137-byte SysEx already splits across two without
trouble). Raising it needs GEWA firmware work: a wider size field, or letting
the piano accept more than one unacknowledged packet so the app can pipeline.
At ~1 KB per round trip the transfer would be roughly 90 seconds.

Worth asking the firmware team why a 112-byte block costs ~495 ms. That is long
even for flash programming and suggests a full sector erase per packet, or a
fixed delay.

**Tests.** 33 in `flutter_midi_command_ble` (was 23), 85 in the root package
(was 83). `flutter analyze` clean across the workspace.

The load-bearing test is the round-trip: `buildBleMidiSysExPackets` output is
fed back through the real receive parser via `onValueChange` for every body
length 0..200 at write sizes 20/23/100/244 — 804 messages, each asserted to
reassemble byte-for-byte. A separate structural sweep to 300 bytes asserts the
MTU bound and the timestamp-before-`F7` framing that was previously broken.

**Note on the interface change.** `onWriteFailure` has a default body, which
helps subclasses but not the two internal fakes that `implements
MidiBleTransport` — Dart requires those to declare every member. Both were
updated. External implementers using `implements` will need the same one-line
addition; this matches the existing precedent of `registerKnownDevice`.

**Deliberately not done.** `teardown()` does not close the write-failure
controller, matching the existing `_rxStreamController`/`_setupStreamController`
handling — the transport can be revived through `_activateIfNeeded()`.

**Hardware verification — done on Android.** Confirmed active and correct
against a PP-3: MTU 96 negotiated, connection priority granted, 8 writes down
to 2, transfer completes. See the timing table above for why the total time is
unchanged.

**Outstanding — iOS.** The in-app firmware transfer does not work on iOS at
all: the header gets no response through three 10 s attempts. The connect log
shows `Handoff: waiting for CoreMIDI counterpart` with no subsequent
`Handoff: connected CoreMIDI endpoint`, so the device stayed on the
CoreBluetooth route — which, per `tasks/todo.md`, cannot exchange data after
bonding because CoreMIDI claims the characteristic. Unrelated to these changes
(`useNegotiatedMtu: false` behaves identically), and needs its own
investigation: has in-app firmware update ever worked on iOS?

**Release.** Versions and CHANGELOGs come from melos via conventional commits;
commit as `feat(ble):` / `fix(ble):` and leave `melos version` to the release
step.
