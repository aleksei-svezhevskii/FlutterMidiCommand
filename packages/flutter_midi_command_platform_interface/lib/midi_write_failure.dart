/// A MIDI write that the transport could not deliver.
///
/// BLE transports keep sending after a failed write, since abandoning a SysEx
/// mid-message would leave the peripheral parsing a truncated one. The failure
/// is reported here so callers can retry or abort on their own terms.
class MidiWriteFailure {
  const MidiWriteFailure({
    required this.deviceId,
    required this.error,
    this.stackTrace,
  });

  /// Transport-specific id of the device the write was addressed to.
  final String deviceId;

  /// The error the underlying stack reported.
  final Object error;

  final StackTrace? stackTrace;

  @override
  String toString() => 'MidiWriteFailure($deviceId): $error';
}
