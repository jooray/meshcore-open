import 'dart:typed_data';

import '../../connector/meshcore_connector.dart';
import '../../models/channel.dart';
import '../../models/contact.dart';
import '../../models/mesh_event.dart';

/// What the local API needs from the radio, separated from the connector so the
/// server can be tested without BLE.
abstract class LocalApiHost {
  bool get isConnected;

  /// Node identity, firmware, battery, radio parameters and channels.
  Map<String, Object?> deviceInfo();

  List<Map<String, Object?>> channels();

  List<Map<String, Object?>> contacts({int limit = 200});

  /// Live traffic, including this app's own sends (flagged `outgoing`).
  Stream<MeshEvent> get events;

  /// Channel by name (e.g. `#roadstr`) or slot number. Null when unknown;
  /// [ambiguous] is set when more than one channel carries the name.
  Channel? resolveChannel(String nameOrIndex, {void Function()? onAmbiguous});

  Contact? resolveContact(String pubkeyHex);

  Future<void> sendChannelText(Channel channel, String text, {String? region});

  /// Returns false when the transport cannot send (disconnected, firmware too
  /// old); throws on a firmware error or command timeout.
  Future<bool> sendChannelData(
    Channel channel,
    int dataType,
    Uint8List payload, {
    String? region,
  });

  Future<void> sendDirectText(Contact contact, String text);

  Future<void> sendAdvert({bool flood = true});
}

class ConnectorLocalApiHost implements LocalApiHost {
  final MeshCoreConnector connector;

  ConnectorLocalApiHost(this.connector);

  @override
  bool get isConnected => connector.isConnected;

  @override
  Map<String, Object?> deviceInfo() {
    final pubkey = connector.selfPublicKey;
    return {
      'connected': connector.isConnected,
      'name': connector.selfName,
      'pubkey': pubkey == null ? null : _hex(pubkey),
      'firmwareVerCode': connector.firmwareVerCode,
      'batteryMv': connector.batteryMillivolts,
      'batteryPercent': connector.batteryPercent,
      'radio': {
        'freqHz': connector.currentFreqHz,
        'bwHz': connector.currentBwHz,
        'sf': connector.currentSf,
        'cr': connector.currentCr,
        'txPowerDbm': connector.currentTxPower,
      },
    };
  }

  @override
  List<Map<String, Object?>> channels() => [
    for (final channel in connector.channels)
      {
        'index': channel.index,
        'name': channel.name,
        'isPublic': channel.isPublicChannel,
        'storageId': channel.storageId,
      },
  ];

  @override
  List<Map<String, Object?>> contacts({int limit = 200}) {
    final list = connector.contacts.take(limit);
    return [
      for (final contact in list)
        {
          'pubkey': contact.publicKeyHex,
          'name': contact.name,
          'type': contact.type,
          'lastSeen': contact.lastSeen.toUtc().toIso8601String(),
        },
    ];
  }

  @override
  Stream<MeshEvent> get events => connector.meshEvents;

  @override
  Channel? resolveChannel(String nameOrIndex, {void Function()? onAmbiguous}) {
    final index = int.tryParse(nameOrIndex);
    if (index != null) {
      for (final channel in connector.channels) {
        if (channel.index == index) return channel;
      }
      return null;
    }
    final matches = connector.channels
        .where((channel) => channel.name == nameOrIndex)
        .toList();
    if (matches.length > 1) {
      onAmbiguous?.call();
      return null;
    }
    return matches.isEmpty ? null : matches.first;
  }

  @override
  Contact? resolveContact(String pubkeyHex) =>
      connector.getContactByPubKeyHex(pubkeyHex);

  @override
  Future<void> sendChannelText(
    Channel channel,
    String text, {
    String? region,
  }) => connector.sendChannelMessage(channel, text, region: region);

  @override
  Future<bool> sendChannelData(
    Channel channel,
    int dataType,
    Uint8List payload, {
    String? region,
  }) => connector.sendChannelData(
    channelIndex: channel.index,
    dataType: dataType,
    payload: payload,
    region: region,
  );

  @override
  Future<void> sendDirectText(Contact contact, String text) =>
      connector.sendMessage(contact, text);

  @override
  Future<void> sendAdvert({bool flood = true}) =>
      connector.sendSelfAdvert(flood: flood);
}

String _hex(Uint8List bytes) =>
    bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
