import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:meshcore_open/models/channel.dart';
import 'package:meshcore_open/models/contact.dart';
import 'package:meshcore_open/models/mesh_event.dart';
import 'package:meshcore_open/services/local_api/local_api_host.dart';
import 'package:meshcore_open/services/local_api/local_api_server.dart';

void main() {
  group('LocalApiServer', () {
    late _FakeHost host;
    late LocalApiServer server;
    late WebSocket socket;
    late _Frames frames;

    setUp(() async {
      host = _FakeHost();
      server = LocalApiServer(host: host, token: 'a' * 64, port: 0);
      await server.start();
      socket = await WebSocket.connect(
        'ws://127.0.0.1:${server.boundPort}/api/v1',
      );
      frames = _Frames(socket);
    });

    tearDown(() async {
      await socket.close();
      await server.stop();
      await host.close();
    });

    Future<Map<String, dynamic>> next() async {
      final raw = await frames.next();
      return jsonDecode(raw as String) as Map<String, dynamic>;
    }

    Future<void> hello([String? token]) async {
      socket.add(jsonEncode({'type': 'hello', 'token': token ?? 'a' * 64}));
      final reply = await next();
      expect(reply['type'], 'hello');
      expect(reply['protocol'], 1);
    }

    test('rejects a bad token', () async {
      socket.add(jsonEncode({'type': 'hello', 'token': 'b' * 64}));
      final reply = await next();
      expect(reply['error']['code'], 'unauthorized');
    });

    test('requires hello before any method', () async {
      socket.add(jsonEncode({'id': 1, 'method': 'device.info'}));
      final reply = await next();
      expect(reply['error']['code'], 'unauthorized');
    });

    test('answers device.info and lists channels', () async {
      await hello();
      socket.add(jsonEncode({'id': 1, 'method': 'device.info'}));
      final reply = await next();
      expect(reply['ok'], true);
      expect(reply['result']['name'], 'Test Node');
      expect(reply['result']['channels'], hasLength(2));
    });

    test('delivers only matching channel data', () async {
      await hello();
      socket.add(
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
      final ack = await next();
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

      final event = await next();
      expect(event['type'], 'event');
      expect(event['subscriptionId'], sub);
      expect(event['event']['channel'], '#roadstr');
      expect(base64Decode(event['event']['payload'] as String), [9, 8, 7]);
      expect(event['event']['snrDb'], -7.5);
    });

    test('sends channel data and rejects oversized payloads', () async {
      await hello();
      socket.add(
        jsonEncode({
          'id': 3,
          'method': 'channel.sendData',
          'params': {
            'channel': '#roadstr',
            'dataType': 0xDA20,
            'payload': base64Encode([1, 2, 3]),
          },
        }),
      );
      final ok = await next();
      expect(ok['ok'], true);
      expect(host.sent.single, [1, 2, 3]);

      socket.add(
        jsonEncode({
          'id': 4,
          'method': 'channel.sendData',
          'params': {
            'channel': '#roadstr',
            'dataType': 0xDA20,
            'payload': base64Encode(List.filled(164, 0)),
          },
        }),
      );
      final tooBig = await next();
      expect(tooBig['error']['code'], 'payload_too_large');
    });

    test('enforces the send gap', () async {
      await hello();
      for (var i = 0; i < 2; i++) {
        socket.add(
          jsonEncode({
            'id': 10 + i,
            'method': 'channel.sendData',
            'params': {
              'channel': '#roadstr',
              'dataType': 0xDA20,
              'payload': base64Encode([i]),
            },
          }),
        );
      }
      final first = await next();
      final second = await next();
      expect(first['ok'], true);
      expect(second['error']['code'], 'rate_limited');
    });

    test('unknown channel is an error', () async {
      await hello();
      socket.add(
        jsonEncode({
          'id': 20,
          'method': 'channel.sendData',
          'params': {
            'channel': '#nope',
            'dataType': 0xDA20,
            'payload': base64Encode([1]),
          },
        }),
      );
      final reply = await next();
      expect(reply['error']['code'], 'unknown_channel');
    });

    test('binary frames close the connection', () async {
      await hello();
      socket.add(Uint8List.fromList([1, 2, 3]));
      await socket.done.timeout(const Duration(seconds: 2));
      expect(server.clientCount, 0);
    });
  });
}

class _Frames {
  final List<dynamic> _queue = [];
  Completer<dynamic>? _waiter;

  _Frames(WebSocket socket) {
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

  Future<dynamic> next() {
    if (_queue.isNotEmpty) return Future.value(_queue.removeAt(0));
    final waiter = Completer<dynamic>();
    _waiter = waiter;
    return waiter.future.timeout(const Duration(seconds: 2));
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
