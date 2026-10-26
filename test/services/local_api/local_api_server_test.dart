import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:meshcore_open/models/channel.dart';
import 'package:meshcore_open/models/contact.dart';
import 'package:meshcore_open/models/mesh_event.dart';
import 'package:meshcore_open/services/local_api/local_api_host.dart';
import 'package:meshcore_open/services/local_api/local_api_pairing.dart';
import 'package:meshcore_open/services/local_api/local_api_server.dart';
import 'package:pointycastle/export.dart';

void main() {
  group('LocalApiServer', () {
    late _FakeHost host;
    late MemoryPairingStore store;
    late LocalApiServer server;
    late List<PairingRequest> requests;
    var approve = true;

    setUp(() async {
      host = _FakeHost();
      store = MemoryPairingStore();
      approve = true;
      requests = [];
      server = LocalApiServer(host: host, pairingStore: store, port: 0);
      server.pairingBroker.requests.listen((request) {
        requests.add(request);
        server.pairingBroker.resolve(request.id, approve);
      });
      await server.start();
    });

    tearDown(() async {
      await server.stop();
      await host.close();
    });

    Future<_Connection> connect(
      _Peer peer, {
      String name = 'Roadbeacon',
    }) async {
      final socket = await WebSocket.connect(
        'ws://127.0.0.1:${server.boundPort}/api/v1',
      );
      final connection = _Connection(socket);
      socket.add(
        jsonEncode({
          'type': 'hello',
          'client': {
            'name': name,
            'version': '0.4.0',
            'publicKey': peer.publicKeyBase64,
          },
        }),
      );
      return connection;
    }

    Future<void> pair(_Connection connection, _Peer peer) async {
      final challenge = await connection.next();
      expect(challenge['type'], 'pairing.challenge');
      final signature = peer.sign(challenge['message'] as String);
      connection.socket.add(
        jsonEncode({'type': 'pair', 'signature': signature}),
      );
      final hello = await connection.next();
      expect(hello['type'], 'hello');
      expect(hello['protocol'], 1);
    }

    test('requires hello before any method', () async {
      final socket = await WebSocket.connect(
        'ws://127.0.0.1:${server.boundPort}/api/v1',
      );
      final connection = _Connection(socket);
      socket.add(jsonEncode({'id': 1, 'method': 'device.info'}));
      final reply = await connection.next();
      expect(reply['error']['code'], 'unauthorized');
      await socket.close();
    });

    test('pairs a new app after the user approves', () async {
      final peer = _Peer.generate(1);
      final connection = await connect(peer);
      await pair(connection, peer);

      expect(requests, hasLength(1));
      expect(requests.single.name, 'Roadbeacon');
      expect(requests.single.fingerprint, hasLength(19));
      expect(store.isPaired(peer.publicKeyBase64), isTrue);

      connection.socket.add(jsonEncode({'id': 1, 'method': 'device.info'}));
      final info = await connection.next();
      expect(info['ok'], true);
      expect(info['result']['name'], 'Test Node');
      await connection.socket.close();
    });

    test('remembers the client and does not ask again', () async {
      final peer = _Peer.generate(2);
      final first = await connect(peer);
      await pair(first, peer);
      await first.socket.close();

      final second = await connect(peer);
      final challenge = await second.next();
      expect(challenge['known'], isTrue);
      final signature = peer.sign(challenge['message'] as String);
      second.socket.add(jsonEncode({'type': 'pair', 'signature': signature}));
      final hello = await second.next();
      expect(hello['type'], 'hello');
      expect(requests, hasLength(1));
      await second.socket.close();
    });

    test('rejects a signature from a different key', () async {
      final peer = _Peer.generate(3);
      final impostor = _Peer.generate(4);
      final connection = await connect(peer);
      final challenge = await connection.next();
      final signature = impostor.sign(challenge['message'] as String);
      connection.socket.add(
        jsonEncode({'type': 'pair', 'signature': signature}),
      );
      final reply = await connection.next();
      expect(reply['error']['code'], 'unauthorized');
      expect(store.isPaired(peer.publicKeyBase64), isFalse);
      await connection.socket.close();
    });

    test('closes when the user denies', () async {
      approve = false;
      final peer = _Peer.generate(5);
      final connection = await connect(peer);
      final challenge = await connection.next();
      final signature = peer.sign(challenge['message'] as String);
      connection.socket.add(
        jsonEncode({'type': 'pair', 'signature': signature}),
      );
      final reply = await connection.next();
      expect(reply['error']['code'], 'unauthorized');
      expect(store.isPaired(peer.publicKeyBase64), isFalse);
      await connection.socket.close();
    });

    test('delivers only matching channel data', () async {
      final peer = _Peer.generate(6);
      final connection = await connect(peer);
      await pair(connection, peer);

      connection.socket.add(
        jsonEncode({
          'id': 2,
          'method': 'events.subscribe',
          'params': {
            'events': ['channel.data'],
            'channel': '#roadstr',
            'dataTypes': [0xDA20],
          },
        }),
      );
      final ack = await connection.next();
      expect(ack['ok'], true);
      final sub = ack['result']['subscriptionId'];

      host.emit(
        ChannelDataEvent(
          channelIndex: 1,
          channelName: 'other',
          dataType: 0xDA20,
          payload: Uint8List.fromList([1, 2]),
          snrRaw: -20,
          outgoing: false,
          receivedAt: DateTime.utc(2026, 1, 1),
        ),
      );
      host.emit(
        ChannelDataEvent(
          channelIndex: 0,
          channelName: '#roadstr',
          dataType: 0xDA20,
          payload: Uint8List.fromList([9, 8, 7]),
          snrRaw: -30,
          outgoing: false,
          receivedAt: DateTime.utc(2026, 1, 1),
        ),
      );

      final event = await connection.next();
      expect(event['type'], 'event');
      expect(event['subscriptionId'], sub);
      expect(event['event']['channel'], '#roadstr');
      expect(base64Decode(event['event']['payload'] as String), [9, 8, 7]);
      expect(event['event']['snrDb'], -7.5);
      await connection.socket.close();
    });

    test(
      'sends channel data, rejects oversized payloads and enforces the gap',
      () async {
        final peer = _Peer.generate(7);
        final connection = await connect(peer);
        await pair(connection, peer);

        Future<Map<String, dynamic>> send(int id, List<int> bytes) async {
          connection.socket.add(
            jsonEncode({
              'id': id,
              'method': 'channel.sendData',
              'params': {
                'channel': '#roadstr',
                'dataType': 0xDA20,
                'payload': base64Encode(bytes),
              },
            }),
          );
          return connection.next();
        }

        final ok = await send(3, [1, 2, 3]);
        expect(ok['ok'], true);
        expect(host.sent.single, [1, 2, 3]);

        final tooBig = await send(4, List.filled(164, 0));
        expect(tooBig['error']['code'], 'payload_too_large');

        final tooSoon = await send(5, [4]);
        expect(tooSoon['error']['code'], 'rate_limited');
        await connection.socket.close();
      },
    );

    test('binary frames close the connection', () async {
      final peer = _Peer.generate(8);
      final connection = await connect(peer);
      await pair(connection, peer);
      connection.socket.add(Uint8List.fromList([1, 2, 3]));
      await connection.socket.done.timeout(const Duration(seconds: 2));
      expect(server.clientCount, 0);
    });
  });
}

class _Peer {
  final ECPrivateKey _private;
  final ECPublicKey _public;

  _Peer._(this._private, this._public);

  static _Peer generate(int seed) {
    final random = SecureRandom('Fortuna')
      ..seed(KeyParameter(Uint8List.fromList(List.filled(32, seed))));
    final generator = ECKeyGenerator()
      ..init(
        ParametersWithRandom(
          ECKeyGeneratorParameters(ECCurve_secp256r1()),
          random,
        ),
      );
    final pair = generator.generateKeyPair();
    return _Peer._(pair.privateKey, pair.publicKey);
  }

  String get publicKeyBase64 {
    final q = _public.Q!;
    return base64Encode([
      ..._encode(q.x!.toBigInteger()!),
      ..._encode(q.y!.toBigInteger()!),
    ]);
  }

  String sign(String message) {
    final random = SecureRandom('Fortuna')
      ..seed(KeyParameter(Uint8List.fromList(List.filled(32, 9))));
    final signer = ECDSASigner(SHA256Digest())
      ..init(
        true,
        ParametersWithRandom(
          PrivateKeyParameter<ECPrivateKey>(_private),
          random,
        ),
      );
    final signature =
        signer.generateSignature(utf8.encode(message)) as ECSignature;
    return base64Encode([..._encode(signature.r), ..._encode(signature.s)]);
  }

  static Uint8List _encode(BigInt value) {
    final hex = value.toRadixString(16).padLeft(64, '0');
    return Uint8List.fromList(
      List<int>.generate(
        32,
        (index) =>
            int.parse(hex.substring(index * 2, index * 2 + 2), radix: 16),
      ),
    );
  }
}

class _Connection {
  final WebSocket socket;
  final List<dynamic> _queue = [];
  Completer<dynamic>? _waiter;

  _Connection(this.socket) {
    socket.listen((data) {
      final waiter = _waiter;
      if (waiter != null) {
        _waiter = null;
        waiter.complete(data);
      } else {
        _queue.add(data);
      }
    });
  }

  Future<Map<String, dynamic>> next() async {
    final raw = _queue.isNotEmpty
        ? _queue.removeAt(0)
        : await (_waiter = Completer<dynamic>()).future.timeout(
            const Duration(seconds: 2),
          );
    return jsonDecode(raw as String) as Map<String, dynamic>;
  }
}

class _FakeHost implements LocalApiHost {
  final _controller = StreamController<MeshEvent>.broadcast();
  final List<List<int>> sent = [];

  @override
  Stream<MeshEvent> get events => _controller.stream;

  Future<void> close() => _controller.close();

  void emit(MeshEvent event) => _controller.add(event);

  @override
  bool get isConnected => true;

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
    {'index': 0, 'name': '#roadstr', 'type': 'hashtag'},
    {'index': 1, 'name': 'other', 'type': 'public'},
  ];

  @override
  List<Map<String, Object?>> contacts({int limit = 200}) => const [];

  @override
  Channel? resolveChannel(String nameOrIndex, {void Function()? onAmbiguous}) {
    final index = int.tryParse(nameOrIndex);
    if (index != null) {
      return index < 2
          ? Channel(
              index: index,
              name: index == 0 ? '#roadstr' : 'other',
              psk: Uint8List(16),
            )
          : null;
    }
    if (nameOrIndex == '#roadstr') {
      return Channel(index: 0, name: '#roadstr', psk: Uint8List(16));
    }
    return null;
  }

  @override
  Contact? resolveContact(String pubkeyHex) => null;

  @override
  Future<void> sendChannelText(Channel channel, String text) async {}

  @override
  Future<bool> sendChannelData(
    Channel channel,
    int dataType,
    Uint8List payload,
  ) async {
    sent.add(payload.toList());
    return true;
  }

  @override
  Future<void> sendDirectText(Contact contact, String text) async {}

  @override
  Future<void> sendAdvert({bool flood = true}) async {}
}
