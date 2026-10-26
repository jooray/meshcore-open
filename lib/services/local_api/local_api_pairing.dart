import 'dart:async';
import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

/// A client asking for access. Shown to the user before anything is allowed.
class PairingRequest {
  final String id;
  final String name;
  final String version;
  final String publicKey;
  final String fingerprint;
  final DateTime requestedAt;

  PairingRequest({
    required this.id,
    required this.name,
    required this.version,
    required this.publicKey,
    required this.fingerprint,
    required this.requestedAt,
  });
}

/// The UI half of pairing: the server asks, the app answers.
class PairingBroker {
  final StreamController<PairingRequest> _requests =
      StreamController<PairingRequest>.broadcast();
  final Map<String, Completer<bool>> _pending = {};

  Stream<PairingRequest> get requests => _requests.stream;

  int get pendingCount => _pending.length;

  Future<bool> ask(
    PairingRequest request, {
    Duration timeout = const Duration(minutes: 2),
  }) {
    final completer = Completer<bool>();
    _pending[request.id] = completer;
    _requests.add(request);
    return completer.future.timeout(
      timeout,
      onTimeout: () {
        _pending.remove(request.id);
        return false;
      },
    );
  }

  void resolve(String id, bool allow) {
    final completer = _pending.remove(id);
    if (completer != null && !completer.isCompleted) completer.complete(allow);
  }

  Future<void> dispose() async {
    for (final completer in _pending.values) {
      if (!completer.isCompleted) completer.complete(false);
    }
    _pending.clear();
    await _requests.close();
  }
}

class PairedClient {
  final String name;
  final String publicKey;
  final String fingerprint;
  final DateTime pairedAt;

  PairedClient({
    required this.name,
    required this.publicKey,
    required this.fingerprint,
    required this.pairedAt,
  });

  Map<String, Object?> toJson() => {
    'name': name,
    'publicKey': publicKey,
    'fingerprint': fingerprint,
    'pairedAt': pairedAt.toUtc().toIso8601String(),
  };

  static PairedClient? fromJson(Object? value) {
    if (value is! Map) return null;
    final name = value['name'];
    final publicKey = value['publicKey'];
    final fingerprint = value['fingerprint'];
    final pairedAt = value['pairedAt'];
    if (name is! String || publicKey is! String || fingerprint is! String) {
      return null;
    }
    final at = pairedAt is String ? DateTime.tryParse(pairedAt) : null;
    return PairedClient(
      name: name,
      publicKey: publicKey,
      fingerprint: fingerprint,
      pairedAt: at ?? DateTime.fromMillisecondsSinceEpoch(0),
    );
  }
}

abstract class PairingStore {
  Future<void> load();

  List<PairedClient> get clients;

  bool isPaired(String publicKey);

  Future<void> add(PairedClient client);

  Future<void> remove(String publicKey);
}

class MemoryPairingStore implements PairingStore {
  final List<PairedClient> _clients = [];

  @override
  List<PairedClient> get clients => List.unmodifiable(_clients);

  @override
  Future<void> load() async {}

  @override
  bool isPaired(String publicKey) =>
      _clients.any((client) => client.publicKey == publicKey);

  @override
  Future<void> add(PairedClient client) async {
    _clients.removeWhere((existing) => existing.publicKey == client.publicKey);
    _clients.add(client);
  }

  @override
  Future<void> remove(String publicKey) async {
    _clients.removeWhere((client) => client.publicKey == publicKey);
  }
}

/// Persisted in SharedPreferences as a JSON list. No secrets: these are public
/// keys of apps the user explicitly allowed.
class PrefsPairingStore implements PairingStore {
  static const String _key = 'local_api_paired_clients';

  final List<PairedClient> _clients = [];

  @override
  List<PairedClient> get clients => List.unmodifiable(_clients);

  @override
  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_key);
    if (raw == null) return;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) return;
      _clients
        ..clear()
        ..addAll(decoded.map(PairedClient.fromJson).whereType<PairedClient>());
    } catch (_) {
      _clients.clear();
    }
  }

  @override
  bool isPaired(String publicKey) =>
      _clients.any((client) => client.publicKey == publicKey);

  @override
  Future<void> add(PairedClient client) async {
    _clients.removeWhere((existing) => existing.publicKey == client.publicKey);
    _clients.add(client);
    await _save();
  }

  @override
  Future<void> remove(String publicKey) async {
    _clients.removeWhere((client) => client.publicKey == publicKey);
    await _save();
  }

  Future<void> _save() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _key,
      jsonEncode(_clients.map((client) => client.toJson()).toList()),
    );
  }
}
