import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:shared_preferences/shared_preferences.dart';

import '../../models/mesh_event.dart';
import '../../utils/app_logger.dart';

/// A channel-data frame kept for a client that was not connected when it arrived.
class ArchivedChannelData {
  final String channel;
  final int dataType;
  final Uint8List payload;
  final double snrDb;
  final DateTime receivedAt;

  ArchivedChannelData({
    required this.channel,
    required this.dataType,
    required this.payload,
    required this.snrDb,
    required this.receivedAt,
  });

  Map<String, Object?> toJson() => {
    'channel': channel,
    'dataType': dataType,
    'payload': base64Encode(payload),
    'snrDb': snrDb,
    'receivedAt': receivedAt.toUtc().toIso8601String(),
  };

  static ArchivedChannelData? fromJson(Object? value) {
    if (value is! Map) return null;
    final channel = value['channel'];
    final dataType = value['dataType'];
    final payload = value['payload'];
    final receivedAt = value['receivedAt'];
    if (channel is! String ||
        dataType is! int ||
        payload is! String ||
        receivedAt is! String) {
      return null;
    }
    final at = DateTime.tryParse(receivedAt);
    if (at == null) return null;
    try {
      return ArchivedChannelData(
        channel: channel,
        dataType: dataType,
        payload: base64Decode(payload),
        snrDb: (value['snrDb'] as num?)?.toDouble() ?? 0,
        receivedAt: at,
      );
    } catch (_) {
      return null;
    }
  }
}

/// Channel-data history, kept only for channels and data types at least one
/// paired app has subscribed to.
///
/// The radio's own offline queue is drained destructively when this app
/// connects; if the frame is not kept here, a client that starts later can
/// never see it. Interests are persisted per client so the archive works while
/// that client is not running.
class LocalApiArchive {
  static const String _interestKey = 'local_api_interests';
  static const String _archiveKey = 'local_api_channel_data';
  static const int maxEntries = 200;
  static const Duration maxAge = Duration(hours: 24);

  /// client public key -> channel -> data types
  final Map<String, Map<String, Set<int>>> _interests = {};
  final List<ArchivedChannelData> _entries = [];
  Timer? _saveTimer;

  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    _interests.clear();
    _entries.clear();
    try {
      final raw = prefs.getString(_interestKey);
      if (raw != null) {
        final decoded = jsonDecode(raw);
        if (decoded is Map) {
          decoded.forEach((key, value) {
            if (key is! String || value is! Map) return;
            final channels = <String, Set<int>>{};
            value.forEach((channel, types) {
              if (channel is! String || types is! List) return;
              channels[channel] = types.whereType<int>().toSet();
            });
            _interests[key] = channels;
          });
        }
      }
      final archived = prefs.getString(_archiveKey);
      if (archived != null) {
        final decoded = jsonDecode(archived);
        if (decoded is List) {
          _entries.addAll(
            decoded
                .map(ArchivedChannelData.fromJson)
                .whereType<ArchivedChannelData>(),
          );
        }
      }
      _prune();
    } catch (error) {
      appLogger.warn('archive unreadable: $error', tag: 'LocalApi');
      _interests.clear();
      _entries.clear();
    }
  }

  /// A client subscribed to [channel] for [dataTypes]. Empty dataTypes means
  /// "all types on that channel".
  void noteInterest(String pubkey, String channel, List<int> dataTypes) {
    final channels = _interests.putIfAbsent(pubkey, () => {});
    final types = channels.putIfAbsent(channel, () => <int>{});
    if (dataTypes.isEmpty) {
      // A wildcard is recorded as such so it survives a reload.
      types.add(-1);
    } else {
      types.addAll(dataTypes);
    }
    _scheduleSave();
  }

  void forgetClient(String pubkey) {
    _interests.remove(pubkey);
    _scheduleSave();
  }

  bool _interested(ArchivedChannelData entry) {
    for (final channels in _interests.values) {
      final types = channels[entry.channel];
      if (types == null) continue;
      if (types.contains(-1) || types.contains(entry.dataType)) return true;
    }
    return false;
  }

  /// Called for every channel-data frame the radio hands us.
  void record(ChannelDataEvent event) {
    final entry = ArchivedChannelData(
      channel: event.channelName,
      dataType: event.dataType,
      payload: event.payload,
      snrDb: event.snrDb,
      receivedAt: event.receivedAt,
    );
    if (!_interested(entry)) return;
    _entries.add(entry);
    _prune();
    _scheduleSave();
  }

  List<ArchivedChannelData> replay({
    String? channel,
    Set<int> dataTypes = const {},
    DateTime? since,
    int limit = maxEntries,
  }) {
    _prune();
    final result = _entries.where((entry) {
      if (channel != null && entry.channel != channel) return false;
      if (dataTypes.isNotEmpty && !dataTypes.contains(entry.dataType)) {
        return false;
      }
      if (since != null && entry.receivedAt.isBefore(since)) return false;
      return true;
    }).toList()..sort((a, b) => a.receivedAt.compareTo(b.receivedAt));
    return result.length <= limit
        ? result
        : result.sublist(result.length - limit);
  }

  Future<void> clear() async {
    _entries.clear();
    await _saveNow();
  }

  void _prune() {
    final cutoff = DateTime.now().toUtc().subtract(maxAge);
    _entries.removeWhere((entry) => entry.receivedAt.isBefore(cutoff));
    if (_entries.length > maxEntries) {
      _entries.removeRange(0, _entries.length - maxEntries);
    }
  }

  void _scheduleSave() {
    _saveTimer?.cancel();
    _saveTimer = Timer(const Duration(seconds: 2), () {
      unawaited(_saveNow());
    });
  }

  Future<void> _saveNow() async {
    _saveTimer?.cancel();
    _saveTimer = null;
    final prefs = await SharedPreferences.getInstance();
    try {
      await prefs.setString(
        _interestKey,
        jsonEncode(
          _interests.map(
            (key, value) => MapEntry(
              key,
              value.map((channel, types) => MapEntry(channel, types.toList())),
            ),
          ),
        ),
      );
      await prefs.setString(
        _archiveKey,
        jsonEncode(_entries.map((entry) => entry.toJson()).toList()),
      );
    } catch (error) {
      appLogger.warn('archive save failed: $error', tag: 'LocalApi');
    }
  }

  Future<void> flush() => _saveNow();
}
