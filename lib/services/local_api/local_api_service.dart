import 'dart:async';

import 'package:shared_preferences/shared_preferences.dart';

import '../../connector/meshcore_connector.dart';
import '../../models/mesh_event.dart';
import '../../utils/app_logger.dart';
import 'local_api_archive.dart';
import 'local_api_host.dart';
import 'local_api_pairing.dart';
import 'local_api_server.dart';
import 'mesh_regions.dart';

/// Lifecycle for the local API.
///
/// For now the API is enabled at build time:
///
///   flutter build apk --dart-define=LOCAL_API_TOKEN=<64 hex> \
///       --dart-define=LOCAL_API_PORT=8787
///
/// With no token the server does not start and nothing listens. A settings
/// screen with a generated, revocable token and a pairing QR is the next step
/// (see documentation/LOCAL_API.md); keeping the token in the build until the
/// transport and security model are agreed avoids shipping a half-configured
/// listener.
class LocalApiService {
  static const String _enabledKey = 'local_api_enabled';
  static const String _portKey = 'local_api_port';
  static const bool _defaultEnabled = bool.fromEnvironment('LOCAL_API_ENABLED');

  static LocalApiService? instance;

  LocalApiService() {
    instance = this;
  }

  final PairingStore pairingStore = PrefsPairingStore();
  final PairingBroker pairingBroker = PairingBroker();
  final LocalApiArchive archive = LocalApiArchive();
  MeshRegionCatalog? _regions;
  LocalApiServer? _server;
  MeshCoreConnector? _connector;
  StreamSubscription<MeshEvent>? _eventSubscription;
  bool _enabled = _defaultEnabled;
  int _port = LocalApiServer.defaultPort;

  bool get isEnabled => _enabled;

  bool get isRunning => _server?.isRunning ?? false;

  int? get port => _server?.boundPort ?? (_enabled ? _port : null);

  Future<void> start(MeshCoreConnector connector) async {
    _connector = connector;
    instance = this;
    await _loadSettings();
    await pairingStore.load();
    await archive.load();
    _regions ??= await MeshRegionCatalog.load();
    _eventSubscription ??= connector.meshEvents.listen((event) {
      if (event is ChannelDataEvent) archive.record(event);
    });
    if (!_enabled) return;
    await _startServer(connector);
  }

  Future<void> setEnabled(bool value) async {
    _enabled = value;
    await _loadSettings();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_enabledKey, value);
    if (value) {
      final connector = _connector;
      if (connector != null) await _startServer(connector);
    } else {
      await _server?.stop();
      _server = null;
    }
  }

  Future<void> revoke(String publicKey) async {
    await pairingStore.remove(publicKey);
    archive.forgetClient(publicKey);
  }

  List<PairedClient> get pairedClients => pairingStore.clients;

  List<MeshRegion> get regions => _regions?.regions ?? const [];

  Future<void> _loadSettings() async {
    final prefs = await SharedPreferences.getInstance();
    _enabled = prefs.getBool(_enabledKey) ?? _defaultEnabled;
    _port = prefs.getInt(_portKey) ?? _port;
  }

  Future<void> _startServer(MeshCoreConnector connector) async {
    if (_server != null) return;
    final server = LocalApiServer(
      host: ConnectorLocalApiHost(connector),
      pairingStore: pairingStore,
      pairingBroker: pairingBroker,
      archive: archive,
      regions: _regions,
      port: _port,
    );
    try {
      await server.start();
      _server = server;
    } catch (error) {
      appLogger.warn('Local API did not start: $error', tag: 'LocalApi');
    }
  }

  Future<void> stop() async {
    await _eventSubscription?.cancel();
    _eventSubscription = null;
    await _server?.stop();
    _server = null;
    await archive.flush();
  }
}
