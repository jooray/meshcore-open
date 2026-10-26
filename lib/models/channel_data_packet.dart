import 'dart:typed_data';

/// A `GRP_DATA` datagram heard on (or sent to) a channel.
///
/// MeshCore's channel data frames carry no sender identity and no timestamp:
/// applications that need either must put them inside [payload]. What the
/// radio does provide is the channel, the application data type and the SNR of
/// the last hop.
class ChannelDataPacket {
  final int channelIndex;

  /// Channel name as configured in the app, or an empty string when the slot
  /// has no name.
  final String channelName;

  /// Application namespace (`data_type`). `0` is rejected by the firmware.
  final int dataType;

  final Uint8List payload;

  /// Signed SNR of the last hop, quarter-dB units (divide by 4 for dB).
  final int snrRaw;

  final DateTime receivedAt;

  /// True for a datagram this app sent, after the radio acknowledged it.
  final bool outgoing;

  ChannelDataPacket({
    required this.channelIndex,
    required this.channelName,
    required this.dataType,
    required this.payload,
    required this.receivedAt,
    this.snrRaw = 0,
    this.outgoing = false,
  });
}
