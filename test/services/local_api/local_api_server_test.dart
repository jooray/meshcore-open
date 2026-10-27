import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:meshcore_open/models/channel.dart';
import 'package:meshcore_open/models/contact.dart';
import 'package:meshcore_open/models/mesh_event.dart';
import 'package:meshcore_open/services/local_api/local_api_archive.dart';
import 'package:meshcore_open/services/local_api/local_api_host.dart';
import 'package:meshcore_open/services/local_api/local_api_pairing.dart';
import 'package:meshcore_open/services/local_api/local_api_server.dart';
import 'package:meshcore_open/services/local_api/mesh_regions.dart';

import 'local_api_test_peer.dart';

void main() {
  late _FakeHost host;
  late MemoryPairingStore store;
  late LocalApiServer server;
  late List<PairingRequest> requests;
  late Directory tempDir;
  late LocalApiArchive archive;
  // null leaves requests unanswered.
  bool? approve;

  Future<void> startServer({
    LocalApiLimits limits = const LocalApiLimits(minSendGap: Duration.zero),
    PairingBroker? broker,
  }) async {
    server = LocalApiServer(
      host: host,
      pairingStore: store,
      pairingBroker: broker,
      archive: archive,
      regions: MeshRegionCatalog.fromJsonString('''
        {"regions":[
          {"name":"sk","label":"Slovakia","kind":"country","lat":48.7164,"lon":19.5,"radiusKm":350},
          {"name":"sk-ba","label":"Bratislava","kind":"city","lat":48.1486,"lon":17.1077,"radiusKm":100}
        ]}
      '''),
      limits: limits,
      port: 0,
    );
    server.pairingBroker.requests.listen((request) {
      requests.add(request);
      final answer = approve;
      if (answer != null) server.pairingBroker.resolve(request.id, answer);
    });
    await server.start();
  }

  Future<void> restartServer({
    LocalApiLimits limits = const LocalApiLimits(minSendGap: Duration.zero),
    PairingBroker? broker,
  }) async {
    await server.stop();
    await startServer(limits: limits, broker: broker);
  }

  setUp(() async {
    host = _FakeHost();
    store = MemoryPairingStore();
    approve = true;
    requests = [];
    tempDir = await Directory.systemTemp.createTemp('local_api_test');
    archive = LocalApiArchive(
      file: () async => File('${tempDir.path}/local_api/archive.json'),
    );
    await startServer();
  });

  tearDown(() async {
    await server.stop();
    await host.close();
    await tempDir.delete(recursive: true);
  });

  String url() => 'ws://127.0.0.1:${server.boundPort}/api/v1';

  Future<Connection> open() async => Connection(await WebSocket.connect(url()));

  Future<Connection> connect(
    TestPeer peer, {
    String name = 'Roadbeacon',
  }) async {
    final connection = await open();
    connection.send({
      'type': 'hello',
      'client': {
        'name': name,
        'version': '0.4.0',
        'publicKey': peer.publicKeyBase64,
      },
    });
    return connection;
  }

  Future<Map<String, dynamic>> sendPair(
    Connection connection,
    TestPeer peer, {
    bool der = false,
  }) async {
    final challenge = await connection.next();
    expect(challenge['type'], 'pairing.challenge');
    final nonce = challenge['nonce'] as String;
    final message = 'meshcore-open-pair-v1:$nonce';
    expect(challenge['message'], message);
    connection.send({
      'type': 'pair',
      'signature': der ? peer.signDer(message) : peer.signRaw(message),
    });
    return challenge;
  }

  Future<Connection> paired(TestPeer peer) async {
    final connection = await connect(peer);
    await sendPair(connection, peer);
    final hello = await connection.next();
    expect(hello['type'], 'hello');
    return connection;
  }

  Future<Map<String, dynamic>> call(
    Connection connection,
    int id,
    String method, [
    Map<String, Object?> params = const {},
  ]) {
    connection.send({'id': id, 'method': method, 'params': params});
    return connection.next();
  }

  ChannelDataEvent dataEvent(
    List<int> payload, {
    String channel = '#roadstr',
    int dataType = 0xB652,
    bool outgoing = false,
    DateTime? at,
  }) => ChannelDataEvent(
    channelIndex: channel == '#roadstr' ? 0 : 1,
    channelName: channel,
    dataType: dataType,
    payload: Uint8List.fromList(payload),
    snrRaw: -30,
    outgoing: outgoing,
    receivedAt: at ?? DateTime.now(),
  );

  group('handshake', () {
    test('requires hello before any method', () async {
      final connection = await open();
      connection.send({'id': 1, 'method': 'device.info'});
      final reply = await connection.next();
      expect(reply['type'], 'error');
      expect(reply['error']['code'], 'unauthorized');
      expect(await connection.closeCode(), 4001);
    });

    test('pairs a new app after the user approves', () async {
      final peer = TestPeer.generate(1);
      final connection = await connect(peer);
      final challenge = await sendPair(connection, peer);
      expect(challenge.containsKey('known'), isFalse);
      final hello = await connection.next();
      expect(hello['type'], 'hello');
      expect(hello['protocol'], 1);
      expect(hello['limits']['maxQueuedBytes'], 256 * 1024);

      expect(requests.single.name, 'Roadbeacon');
      expect(requests.single.fingerprint, hasLength(19));
      expect(store.isPaired(peer.publicKeyBase64), isTrue);

      final info = await call(connection, 1, 'device.info');
      expect(info['ok'], true);
      expect(info['result']['name'], 'Test Node');
    });

    test('a paired key gets the same challenge and no prompt', () async {
      final peer = TestPeer.generate(2);
      await (await paired(peer)).close();

      final second = await connect(peer);
      final challenge = await sendPair(second, peer);
      expect(challenge.containsKey('known'), isFalse);
      expect((await second.next())['type'], 'hello');
      expect(requests, hasLength(1));
    });

    test('accepts a DER signature as made by SHA256withECDSA', () async {
      final peer = TestPeer.generate(3);
      final connection = await connect(peer);
      await sendPair(connection, peer, der: true);
      expect((await connection.next())['type'], 'hello');
    });

    test('rejects a signature from a different key', () async {
      final peer = TestPeer.generate(4);
      final impostor = TestPeer.generate(5);
      final connection = await connect(peer);
      final challenge = await connection.next();
      connection.send({
        'type': 'pair',
        'signature': impostor.signRaw(challenge['message'] as String),
      });
      expect((await connection.next())['error']['code'], 'unauthorized');
      expect(await connection.closeCode(), 4003);
      expect(requests, isEmpty);
      expect(store.isPaired(peer.publicKeyBase64), isFalse);
    });

    test('rejects a public key that is not on P-256', () async {
      final connection = await open();
      connection.send({
        'type': 'hello',
        'client': {
          'name': 'Bad',
          'version': '1',
          'publicKey': base64Encode(List<int>.filled(64, 1)),
        },
      });
      final reply = await connection.next();
      expect(reply['error']['code'], 'bad_request');
      expect(reply['error']['message'], 'invalid public key');
      expect(await connection.closeCode(), 4003);
    });

    test('closes when the user denies', () async {
      approve = false;
      final peer = TestPeer.generate(6);
      final connection = await connect(peer);
      await sendPair(connection, peer);
      expect((await connection.next())['error']['code'], 'unauthorized');
      expect(await connection.closeCode(), 4003);
      expect(store.isPaired(peer.publicKeyBase64), isFalse);
    });

    test('a second pair frame on one connection is refused', () async {
      approve = null;
      final peer = TestPeer.generate(7);
      final connection = await connect(peer);
      final challenge = await sendPair(connection, peer);
      connection.send({
        'type': 'pair',
        'signature': peer.signRaw(challenge['message'] as String),
      });
      expect((await connection.next())['error']['code'], 'unauthorized');
      expect(await connection.closeCode(), 4001);
      // Closing cancelled the one prompt that was opened.
      expect(requests, hasLength(1));
      expect(server.pairingBroker.pendingCount, 0);
    });

    test('one key has at most one open prompt', () async {
      approve = null;
      final peer = TestPeer.generate(8);
      final first = await connect(peer);
      await sendPair(first, peer);
      await pumpUntil(() => requests.isNotEmpty);

      final second = await connect(peer);
      await sendPair(second, peer);
      expect((await second.next())['error']['code'], 'pairing_pending');
      expect(requests, hasLength(1));

      server.pairingBroker.resolve(requests.single.id, true);
      expect((await first.next())['type'], 'hello');
    });

    test('a closed socket cancels its prompt', () async {
      approve = null;
      final cancelled = <String>[];
      server.pairingBroker.cancelled.listen(cancelled.add);
      final peer = TestPeer.generate(9);
      final connection = await connect(peer);
      await sendPair(connection, peer);
      await pumpUntil(() => requests.isNotEmpty);

      await connection.close();
      await pumpUntil(() => cancelled.isNotEmpty);
      expect(cancelled.single, requests.single.id);
      expect(server.pairingBroker.resolve(requests.single.id, true), isFalse);
      expect(store.isPaired(peer.publicKeyBase64), isFalse);
    });

    test('the challenge expires with the hello timeout', () async {
      await restartServer(
        limits: const LocalApiLimits(helloTimeout: Duration(milliseconds: 200)),
      );
      final peer = TestPeer.generate(10);
      final connection = await connect(peer);
      await connection.next();
      expect(await connection.closeCode(), 4001);
    });
  });

  group('transport', () {
    test('rejects upgrades that carry an Origin header', () async {
      await expectLater(
        WebSocket.connect(url(), headers: {'Origin': 'https://example.com'}),
        throwsA(isA<WebSocketException>()),
      );
      expect(server.clientCount, 0);
    });

    test('caps unpaired and paired connections', () async {
      await restartServer(
        limits: const LocalApiLimits(maxClients: 1, maxPendingClients: 2),
      );
      final idle = [await open(), await open()];
      await expectLater(open(), throwsA(isA<WebSocketException>()));
      for (final connection in idle) {
        await connection.close();
      }
      await pumpUntil(() => server.clientCount == 0);

      await paired(TestPeer.generate(11));
      final peer = TestPeer.generate(12);
      final second = await connect(peer);
      await sendPair(second, peer);
      expect((await second.next())['error']['code'], 'too_many_clients');
      expect(await second.closeCode(), 4013);
    });

    test('binary frames close the connection', () async {
      final connection = await paired(TestPeer.generate(13));
      connection.socket.add(Uint8List.fromList([1, 2, 3]));
      expect(await connection.closeCode(), 1003);
      expect(server.clientCount, 0);
    });

    test('an oversized message closes the connection', () async {
      await restartServer(limits: const LocalApiLimits(maxMessageBytes: 1024));
      final connection = await open();
      connection.socket.add('x' * 4000);
      expect(await connection.closeCode(), 1009);
      await pumpUntil(() => server.clientCount == 0);
    });

    test('a client that stops reading is closed', () async {
      final slow = await paired(TestPeer.generate(14));
      final reading = await paired(TestPeer.generate(15));
      for (final connection in [slow, reading]) {
        await call(connection, 1, 'events.subscribe', {
          'events': ['channel.data'],
        });
      }
      slow.pause();

      // About 350 bytes per event: well past the 256 KiB queue plus what the
      // OS buffers on loopback. The client that keeps reading stays.
      final payload = List<int>.generate(163, (i) => i);
      for (var i = 0; i < 100000 && server.clientCount > 1; i++) {
        host.emit(dataEvent(payload));
        if (i % 100 == 0) await Future<void>.delayed(Duration.zero);
      }
      expect(server.clientCount, 1);
      expect((await reading.next())['type'], 'event');
    });
  });

  group('subscriptions', () {
    test('delivers only matching channel data', () async {
      final connection = await paired(TestPeer.generate(20));
      final ack = await call(connection, 2, 'events.subscribe', {
        'events': ['channel.data'],
        'channel': '#roadstr',
        'dataTypes': [0xB652],
      });
      final sub = ack['result']['subscriptionId'];

      host.emit(dataEvent([1, 2], channel: 'other'));
      host.emit(dataEvent([5], dataType: 0xAE1C));
      host.emit(dataEvent([9, 8, 7]));

      final event = await connection.next();
      expect(event['subscriptionId'], sub);
      expect(event['event']['channel'], '#roadstr');
      expect(base64Decode(event['event']['payload'] as String), [9, 8, 7]);
      expect(event['event']['snrDb'], -7.5);
    });

    test('subscription ids are not reused after unsubscribe', () async {
      final connection = await paired(TestPeer.generate(21));
      Future<String> subscribe(int id) async =>
          (await call(
                connection,
                id,
                'events.subscribe',
              ))['result']['subscriptionId']
              as String;
      final first = await subscribe(1);
      final second = await subscribe(2);
      expect(
        (await call(connection, 3, 'events.unsubscribe', {
          'subscriptionId': first,
        }))['ok'],
        true,
      );
      final third = await subscribe(4);
      expect({first, second, third}, hasLength(3));
    });

    test('rejects bad and oversized filters', () async {
      final connection = await paired(TestPeer.generate(22));
      final negative = await call(connection, 1, 'events.subscribe', {
        'dataTypes': [-1],
      });
      expect(negative['error']['code'], 'invalid_data_type');
      final long = await call(connection, 2, 'events.subscribe', {
        'pubkeys': List.filled(33, 'ab'),
      });
      expect(long['error']['code'], 'bad_request');
    });
  });

  group('sending', () {
    Future<Map<String, dynamic>> sendData(
      Connection connection,
      int id,
      List<int> bytes,
    ) => call(connection, id, 'channel.sendData', {
      'channel': '#roadstr',
      'dataType': 0xB652,
      'payload': base64Encode(bytes),
    });

    test('rejects oversized payloads and enforces the send gap', () async {
      await restartServer(limits: const LocalApiLimits());
      final connection = await paired(TestPeer.generate(30));
      expect((await sendData(connection, 1, [1, 2, 3]))['ok'], true);
      expect(host.sent.single, [1, 2, 3]);
      expect(
        (await sendData(connection, 2, List.filled(164, 0)))['error']['code'],
        'payload_too_large',
      );
      expect(
        (await sendData(connection, 3, [4]))['error']['code'],
        'rate_limited',
      );
    });

    test('allows the configured sends per minute', () async {
      await restartServer(
        limits: const LocalApiLimits(
          minSendGap: Duration.zero,
          sendsPerMinute: 3,
        ),
      );
      final connection = await paired(TestPeer.generate(31));
      for (var i = 0; i < 3; i++) {
        expect((await sendData(connection, i, [i]))['ok'], true);
      }
      expect(
        (await sendData(connection, 9, [9]))['error']['code'],
        'rate_limited',
      );
    });

    test('a send the radio refuses does not spend quota', () async {
      await restartServer(
        limits: const LocalApiLimits(
          minSendGap: Duration.zero,
          sendsPerMinute: 1,
        ),
      );
      final connection = await paired(TestPeer.generate(32));
      host.sendResult = false;
      expect(
        (await sendData(connection, 1, [1]))['error']['code'],
        'not_connected',
      );
      host.throwOnSend = true;
      expect(
        (await sendData(connection, 2, [2]))['error']['code'],
        'radio_error',
      );
      host
        ..sendResult = true
        ..throwOnSend = false;
      expect((await sendData(connection, 3, [3]))['ok'], true);
    });

    test('reports firmware without channel data', () async {
      host.channelData = false;
      final connection = await paired(TestPeer.generate(33));
      expect(
        (await sendData(connection, 1, [1]))['error']['code'],
        'unsupported_firmware',
      );
    });
  });

  group('regions', () {
    Future<Map<String, dynamic>> sendWithRegion(
      Connection connection,
      int id,
      String region,
    ) => call(connection, id, 'channel.sendData', {
      'channel': '#roadstr',
      'dataType': 0xB652,
      'payload': base64Encode([id]),
      'region': region,
    });

    test('accepts catalogue and saved regions only', () async {
      host.saved = ['home-repeaters'];
      final connection = await paired(TestPeer.generate(50));

      expect((await sendWithRegion(connection, 1, 'sk-ba'))['ok'], true);
      expect(host.lastRegion, 'sk-ba');
      expect(
        (await sendWithRegion(connection, 2, 'home-repeaters'))['ok'],
        true,
      );
      expect(host.lastRegion, 'home-repeaters');

      expect(
        (await sendWithRegion(connection, 3, 'sk-xx'))['error']['code'],
        'unknown_region',
      );
      for (final bad in ['!unscoped', 'Not A Region', '']) {
        expect(
          (await sendWithRegion(connection, 4, bad))['error']['code'],
          'bad_request',
        );
      }
      // Refused requests did not reach the radio.
      expect(host.sent, hasLength(2));
    });

    test('resolves a point to the nearest containing region', () async {
      final connection = await paired(TestPeer.generate(51));
      final ba = await call(connection, 1, 'regions.resolve', {
        'lat': 48.15,
        'lon': 17.11,
      });
      expect(ba['result']['region']['name'], 'sk-ba');
      final none = await call(connection, 2, 'regions.resolve', {
        'lat': 40,
        'lon': 0,
      });
      expect(none['result']['region'], isNull);
      final bad = await call(connection, 3, 'regions.resolve', {
        'lat': 91,
        'lon': 0,
      });
      expect(bad['error']['code'], 'coordinate_range');
      final list = await call(connection, 4, 'regions.list');
      expect(list['result']['regions'], hasLength(2));
    });
  });

  group('archive and replay', () {
    Future<Map<String, dynamic>> subscribe(
      Connection connection,
      int id, {
      Object? since,
    }) => call(connection, id, 'events.subscribe', {
      'events': ['channel.data'],
      'channel': '#roadstr',
      'dataTypes': [0xB652],
      'since': ?since,
    });

    test('replays after the ack, oldest first, then live events', () async {
      final peer = TestPeer.generate(40);
      final first = await paired(peer);
      await subscribe(first, 1);
      await first.close();
      await pumpUntil(() => server.clientCount == 0);

      final start = DateTime.now().toUtc().subtract(
        const Duration(seconds: 10),
      );
      host.emit(dataEvent([1], at: start));
      host.emit(dataEvent([2], at: start.add(const Duration(seconds: 1))));
      host.emit(dataEvent([3], outgoing: true));
      host.emit(dataEvent([4], dataType: 0xAE1C));
      await Future<void>.delayed(Duration.zero);

      final second = await paired(peer);
      second.send({
        'id': 2,
        'method': 'events.subscribe',
        'params': {
          'events': ['channel.data'],
          'channel': '#roadstr',
          'dataTypes': [0xB652],
          'since': start.toIso8601String(),
        },
      });
      host.emit(dataEvent([5]));

      final ack = await second.next();
      expect(ack['id'], 2);
      final sub = ack['result']['subscriptionId'];
      final payloads = <List<int>>[];
      for (var i = 0; i < 3; i++) {
        final event = await second.next();
        expect(event['subscriptionId'], sub);
        payloads.add(base64Decode(event['event']['payload'] as String));
      }
      expect(payloads, [
        [1],
        [2],
        [5],
      ]);
    });

    test('since is inclusive', () async {
      final peer = TestPeer.generate(41);
      final connection = await paired(peer);
      await subscribe(connection, 1);
      final at = DateTime.utc(2030, 1, 1, 12);
      host.emit(dataEvent([7], at: at));
      await connection.next();
      final ack = await subscribe(
        connection,
        2,
        since: at.millisecondsSinceEpoch,
      );
      expect(ack['ok'], true);
      final replayed = await connection.next();
      expect(base64Decode(replayed['event']['payload'] as String), [7]);
    });

    test('a client only replays what it registered for', () async {
      final interested = TestPeer.generate(42);
      await subscribe(await paired(interested), 1);
      host.emit(dataEvent([1]));
      await Future<void>.delayed(Duration.zero);

      final other = await paired(TestPeer.generate(43));
      final ack = await call(other, 1, 'events.subscribe', {
        'events': ['channel.data'],
        'since': 0,
      });
      expect(ack['ok'], true);
      await expectLater(other.next(), throwsA(isA<TimeoutException>()));
    });

    test('revoke closes live sessions and drops the archive', () async {
      final peer = TestPeer.generate(44);
      final connection = await paired(peer);
      await subscribe(connection, 1);
      host.emit(dataEvent([1]));
      await connection.next();

      await server.revoke(peer.publicKeyBase64);
      expect(await connection.closeCode(), 4003);
      expect(connection.socket.closeReason, 'revoked');
      expect(store.isPaired(peer.publicKeyBase64), isFalse);
      expect(
        archive.replay(peer.publicKeyBase64, since: DateTime.utc(2000)),
        isEmpty,
      );
    });
  });
}

Future<void> pumpUntil(bool Function() condition) async {
  final end = DateTime.now().add(const Duration(seconds: 5));
  while (!condition()) {
    if (DateTime.now().isAfter(end)) fail('Timed out waiting for condition');
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

class Connection {
  final WebSocket socket;
  final List<String> _queue = [];
  late final StreamSubscription<dynamic> _subscription;
  Completer<String>? _waiter;
  final Completer<void> _done = Completer<void>();

  Connection(this.socket) {
    _subscription = socket.listen((data) {
      final waiter = _waiter;
      if (waiter != null) {
        _waiter = null;
        waiter.complete(data as String);
      } else {
        _queue.add(data as String);
      }
    }, onDone: _done.complete);
  }

  void send(Map<String, Object?> message) => socket.add(jsonEncode(message));

  void pause() => _subscription.pause();

  Future<Map<String, dynamic>> next() async {
    final raw = _queue.isNotEmpty
        ? _queue.removeAt(0)
        : await (_waiter = Completer<String>()).future.timeout(
            const Duration(seconds: 2),
          );
    return jsonDecode(raw) as Map<String, dynamic>;
  }

  Future<int?> closeCode() async {
    await _done.future.timeout(const Duration(seconds: 3));
    return socket.closeCode;
  }

  Future<void> close() => socket.close();
}

class _FakeHost implements LocalApiHost {
  final _controller = StreamController<MeshEvent>.broadcast(sync: true);
  final List<List<int>> sent = [];
  bool channelData = true;
  bool sendResult = true;
  bool throwOnSend = false;
  List<String> saved = [];
  String? lastRegion;

  @override
  Stream<MeshEvent> get events => _controller.stream;

  Future<void> close() => _controller.close();

  void emit(MeshEvent event) => _controller.add(event);

  @override
  bool get isConnected => true;

  @override
  bool get supportsChannelData => channelData;

  @override
  Map<String, Object?> deviceInfo() => {
    'connected': true,
    'name': 'Test Node',
    'pubkey': 'ab' * 32,
    'firmwareVerCode': 11,
    'batteryMv': 4000,
  };

  @override
  List<Map<String, Object?>> channels() => [
    {'index': 0, 'name': '#roadstr'},
    {'index': 1, 'name': 'other'},
  ];

  @override
  List<Map<String, Object?>> contacts({int limit = 200}) => const [];

  @override
  Channel? resolveChannel(String nameOrIndex, {void Function()? onAmbiguous}) {
    final index =
        int.tryParse(nameOrIndex) ??
        switch (nameOrIndex) {
          '#roadstr' => 0,
          'other' => 1,
          _ => null,
        };
    if (index == null || index > 1) return null;
    return Channel(
      index: index,
      name: index == 0 ? '#roadstr' : 'other',
      psk: Uint8List(16),
    );
  }

  @override
  Contact? resolveContact(String pubkeyHex) => null;

  @override
  List<String> savedRegions() => saved;

  @override
  Future<void> sendChannelText(
    Channel channel,
    String text, {
    String? region,
  }) async {}

  @override
  Future<bool> sendChannelData(
    Channel channel,
    int dataType,
    Uint8List payload, {
    String? region,
  }) async {
    lastRegion = region;
    if (throwOnSend) throw Exception('Command failed with error code 3');
    if (sendResult) sent.add(payload.toList());
    return sendResult;
  }

  @override
  Future<void> sendDirectText(Contact contact, String text) async {}

  @override
  Future<void> sendAdvert({bool flood = true}) async {}
}
