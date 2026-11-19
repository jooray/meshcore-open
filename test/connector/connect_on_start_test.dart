import 'package:flutter_test/flutter_test.dart';
import 'package:meshcore_open/connector/meshcore_connector.dart';
import 'package:meshcore_open/models/app_settings.dart';
import 'package:meshcore_open/storage/last_radio_store.dart';
import 'package:meshcore_open/storage/prefs_manager.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _key = 'aabbccddeeff00112233445566778899aabbccddeeff00112233445566778899';

void main() {
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    PrefsManager.reset();
    await PrefsManager.initialize();
  });

  group('shouldConnectOnStart', () {
    bool decide({
      bool hasRadio = true,
      bool userDisconnected = false,
      bool settingEnabled = true,
      bool startedByRadio = false,
    }) => MeshCoreConnector.shouldConnectOnStart(
      hasRadio: hasRadio,
      userDisconnected: userDisconnected,
      settingEnabled: settingEnabled,
      startedByRadio: startedByRadio,
    );

    test('connects to a remembered radio by default', () {
      expect(decide(), isTrue);
    });

    test('needs a radio it can reconnect to', () {
      expect(decide(hasRadio: false), isFalse);
      expect(decide(hasRadio: false, startedByRadio: true), isFalse);
    });

    test('never reconnects a radio the user disconnected', () {
      expect(decide(userDisconnected: true), isFalse);
      expect(decide(userDisconnected: true, startedByRadio: true), isFalse);
    });

    test('the setting turns it off, except when Android reported the '
        'associated radio in range', () {
      expect(decide(settingEnabled: false), isFalse);
      expect(decide(settingEnabled: false, startedByRadio: true), isTrue);
    });
  });

  group('shouldWaitForRadioInBackground', () {
    test('Android waits with a pending connection after three quick tries', () {
      for (var attempts = 0; attempts < 3; attempts++) {
        expect(
          MeshCoreConnector.shouldWaitForRadioInBackground(
            reconnectAttempts: attempts,
            isAndroid: true,
          ),
          isFalse,
          reason: 'attempt $attempts',
        );
      }
      expect(
        MeshCoreConnector.shouldWaitForRadioInBackground(
          reconnectAttempts: 3,
          isAndroid: true,
        ),
        isTrue,
      );
      expect(
        MeshCoreConnector.shouldWaitForRadioInBackground(
          reconnectAttempts: 40,
          isAndroid: true,
        ),
        isTrue,
      );
    });

    test('other platforms keep the timer', () {
      expect(
        MeshCoreConnector.shouldWaitForRadioInBackground(
          reconnectAttempts: 40,
          isAndroid: false,
        ),
        isFalse,
      );
    });
  });

  test('the user-disconnected flag survives a restart', () async {
    final store = LastRadioStore();
    expect(store.userDisconnected, isFalse);
    await store.setUserDisconnected(true);
    expect(LastRadioStore().userDisconnected, isTrue);
    await store.setUserDisconnected(false);
    expect(LastRadioStore().userDisconnected, isFalse);
    expect(
      PrefsManager.instance.containsKey(LastRadioStore.userDisconnectedKey),
      isFalse,
    );
  });

  test('stopping the reconnect is remembered, so the next start does not '
      'connect', () async {
    await LastRadioStore().save(
      LastRadio(
        publicKeyHex: _key,
        name: 'Base',
        transport: LastRadio.transportTcp,
        tcpHost: '127.0.0.1',
        tcpPort: 1,
        savedAt: DateTime.fromMillisecondsSinceEpoch(1234),
      ),
    );
    final connector = MeshCoreConnector();
    addTearDown(connector.dispose);
    await connector.restoreLastRadio();

    connector.cancelAutoReconnect();
    await Future<void>.delayed(Duration.zero);

    expect(LastRadioStore().userDisconnected, isTrue);
    expect(await connector.connectOnStart(), isFalse);
    expect(connector.state, MeshCoreConnectionState.disconnected);
  });

  test('connect on start is on by default and stored', () {
    expect(AppSettings().autoConnectOnStart, isTrue);
    final off = AppSettings().copyWith(autoConnectOnStart: false);
    expect(off.toJson()['auto_connect_on_start'], isFalse);
    expect(AppSettings.fromJson(off.toJson()).autoConnectOnStart, isFalse);
    expect(AppSettings.fromJson(const {}).autoConnectOnStart, isTrue);
  });
}
