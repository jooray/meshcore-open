import 'dart:async';

import '../../connector/meshcore_connector.dart';
import '../../utils/app_logger.dart';
import 'local_api_host.dart';
import 'local_api_pairing.dart';
import 'local_api_server.dart';

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
  static const bool _enabled = bool.fromEnvironment('LOCAL_API_ENABLED');
  static const int _port = int.fromEnvironment(
    'LOCAL_API_PORT',
    defaultValue: LocalApiServer.defaultPort,
  );

  static LocalApiService? instance;

  LocalApiService() {
    instance = this;
  }

  final PairingStore pairingStore = PrefsPairingStore();
  final PairingBroker pairingBroker = PairingBroker();
  LocalApiServer? _server;

  bool get isEnabled => _enabled;

  bool get isRunning => _server?.isRunning ?? false;

  int? get port => _server?.boundPort;

  Future<void> start(MeshCoreConnector connector) async {
    if (!isEnabled || _server != null) return;
    instance = this;
    await pairingStore.load();
    final server = LocalApiServer(
      host: ConnectorLocalApiHost(connector),
      pairingStore: pairingStore,
      pairingBroker: pairingBroker,
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
    await _server?.stop();
    _server = null;
  }
}
