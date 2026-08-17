# Lessons

## Don't stop at "the platform error is generic" — find our own call that provokes it

**Context:** Android BLE connect failed with
`UniversalBleException: Code: unknownError, Message: Unknown Error 133`.
133 is Android's catch-all `GATT_ERROR`, so it's tempting to file it as flaky
hardware. Morten's hint ("appears related to MTU settings") pointed at our code
instead, and it held up: we fired `requestMtu` from the `onConnectionChange`
callback, which lands in universal_ble's single global GATT command queue
*ahead of* the service discovery our own `connect()` was about to issue.

**Rule:** when an upstream/native error is generic, first map every call *we*
make in that window and their real execution order. In an async plugin,
"fire-and-forget from a callback" is not free — it can jump the queue in front
of the awaited sequence.

## Ordering rule for GATT work in this plugin

Everything universal_ble exposes goes through one shared command queue. So:

- The connect sequence is `discover → pair → subscribe`, awaited, in that order.
- Anything opportunistic (MTU) runs **after** the MIDI path is live, with its
  own short timeout, and swallows failures. It must never be able to stall or
  break a working link.
- Never issue a GATT command from `updateConnectionState` / a callback while a
  `connect()` is in flight.
