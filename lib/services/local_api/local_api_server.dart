import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import '../../models/channel.dart';
import '../../models/mesh_event.dart';
import 'local_api_archive.dart';
import 'local_api_crypto.dart';
import 'local_api_pairing.dart';
import '../../utils/app_logger.dart';
import 'local_api_host.dart';
import 'mesh_regions.dart';

/// Local WebSocket API for other apps on the same device.
///
/// One radio, one BLE connection: this server lets a second application (a
/// road-event client, a bot, a bridge) subscribe to live traffic and send
/// through the same connection the chat UI uses. It is loopback-only and
/// requires a token in the first message. See documentation/LOCAL_API.md.
class LocalApiServer {
  static const int protocolVersion = 1;
  static const int defaultPort = 8787;

  /// Largest channel-data payload a client may send. Same BLE-bound limit as
  /// an image chunk; the radio itself accepts 165.
  static const int maxPayloadBytes = 163;

  static const int maxSubscriptionsPerClient = 16;
  static const int maxClients = 4;
  static const int maxQueuedMessages = 256;
  static const int sendsPerMinute = 30;
  static const Duration minSendGap = Duration(seconds: 2);

  final LocalApiHost host;
  final PairingStore pairingStore;
  final PairingBroker pairingBroker;
  final LocalApiArchive? archive;
  final MeshRegionCatalog? regions;
  final int port;

  HttpServer? _server;
  final List<_ApiClient> _clients = [];
  StreamSubscription<MeshEvent>? _eventSubscription;

  LocalApiServer({
    required this.host,
    required this.pairingStore,
    PairingBroker? pairingBroker,
    this.archive,
    this.regions,
    this.port = defaultPort,
  }) : pairingBroker = pairingBroker ?? PairingBroker();

  bool get isRunning => _server != null;

  /// Actual port, useful when [port] was 0 (tests) or when reporting the URI.
  int? get boundPort => _server?.port;

  int get clientCount => _clients.length;

  Future<void> start() async {
    if (_server != null) return;
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, port);
    _server = server;
    _eventSubscription = host.events.listen(_broadcast);
    server.listen(
      _handleRequest,
      onError: (Object error) {
        appLogger.warn('Local API server error: $error', tag: 'LocalApi');
      },
    );
    appLogger.info(
      'Local API listening on ws://127.0.0.1:$port/api/v1',
      tag: 'LocalApi',
    );
  }

  Future<void> stop() async {
    await _eventSubscription?.cancel();
    _eventSubscription = null;
    for (final client in List<_ApiClient>.of(_clients)) {
      await client.close(1001, 'server stopping');
    }
    _clients.clear();
    await _server?.close(force: true);
    _server = null;
  }

  void _handleRequest(HttpRequest request) {
    if (request.uri.path != '/api/v1') {
      request.response
        ..statusCode = HttpStatus.notFound
        ..write('Not found');
      unawaited(request.response.close());
      return;
    }
    if (!WebSocketTransformer.isUpgradeRequest(request)) {
      request.response
        ..statusCode = HttpStatus.upgradeRequired
        ..headers.set(HttpHeaders.connectionHeader, 'Upgrade')
        ..write('This endpoint speaks WebSocket only');
      unawaited(request.response.close());
      return;
    }
    if (_clients.length >= maxClients) {
      request.response
        ..statusCode = HttpStatus.serviceUnavailable
        ..write('Too many clients');
      unawaited(request.response.close());
      return;
    }
    unawaited(_accept(request));
  }

  Future<void> _accept(HttpRequest request) async {
    final socket = await WebSocketTransformer.upgrade(request);
    final client = _ApiClient(this, socket);
    _clients.add(client);
    client.start();
    appLogger.info('Local API client connected', tag: 'LocalApi');
  }

  void _remove(_ApiClient client) {
    _clients.remove(client);
    appLogger.info('Local API client disconnected', tag: 'LocalApi');
  }

  void _broadcast(MeshEvent event) {
    for (final client in _clients) {
      client.deliver(event);
    }
  }
}

class _ApiClient {
  final LocalApiServer server;
  final WebSocket socket;
  final Map<String, _Subscription> _subscriptions = {};
  final List<DateTime> _sendTimes = [];
  Timer? _helloTimeout;
  _Handshake? _handshake;
  String? _publicKey;
  bool _authenticated = false;
  bool _closed = false;
  int _queued = 0;

  _ApiClient(this.server, this.socket);

  void start() {
    _helloTimeout = Timer(const Duration(seconds: 10), () {
      if (!_authenticated) close(4001, 'hello timeout');
    });
    socket.listen(
      _handleMessage,
      onDone: () => _onDone(),
      onError: (Object error) {
        appLogger.warn('Local API socket error: $error', tag: 'LocalApi');
        _onDone();
      },
      cancelOnError: true,
    );
  }

  void _onDone() {
    if (_closed) return;
    _closed = true;
    _helloTimeout?.cancel();
    server._remove(this);
  }

  Future<void> close(int code, String reason) async {
    if (_closed) return;
    _closed = true;
    _helloTimeout?.cancel();
    try {
      await socket.close(code, reason);
    } catch (_) {
      // Socket may already be gone.
    }
    server._remove(this);
  }

  void _handleMessage(dynamic raw) {
    if (_closed) return;
    if (raw is! String) {
      unawaited(close(4003, 'text frames only'));
      return;
    }
    final Object? decoded;
    try {
      decoded = jsonDecode(raw);
    } catch (_) {
      _enqueue({
        'type': 'error',
        'error': {'code': 'bad_request', 'message': 'invalid JSON'},
      });
      return;
    }
    if (decoded is! Map<String, dynamic>) {
      _enqueue({
        'type': 'error',
        'error': {'code': 'bad_request', 'message': 'expected an object'},
      });
      return;
    }

    if (!_authenticated) {
      unawaited(_handleHandshake(decoded));
      return;
    }
    unawaited(_dispatch(decoded));
  }

  Future<void> _handleHandshake(Map<String, dynamic> message) async {
    switch (message['type']) {
      case 'hello':
        _startChallenge(message);
      case 'pair':
        await _completePairing(message);
      default:
        _enqueue({
          'type': 'error',
          'error': {'code': 'unauthorized', 'message': 'hello first'},
        });
        unawaited(close(4001, 'hello first'));
    }
  }

  void _startChallenge(Map<String, dynamic> message) {
    if (_handshake != null) {
      _enqueue({
        'type': 'error',
        'error': {'code': 'bad_request', 'message': 'already started'},
      });
      return;
    }
    final client = message['client'];
    if (client is! Map) {
      _enqueue({
        'type': 'error',
        'error': {'code': 'bad_request', 'message': 'client is required'},
      });
      unawaited(close(4003, 'bad hello'));
      return;
    }
    final name = client['name'];
    final version = client['version'];
    final publicKey = client['publicKey'];
    if (name is! String ||
        name.trim().isEmpty ||
        name.length > 64 ||
        version is! String ||
        version.length > 32 ||
        publicKey is! String) {
      _enqueue({
        'type': 'error',
        'error': {'code': 'bad_request', 'message': 'bad client identity'},
      });
      unawaited(close(4003, 'bad hello'));
      return;
    }
    final raw = LocalApiCrypto.decodePublicKey(publicKey);
    if (raw == null) {
      _enqueue({
        'type': 'error',
        'error': {'code': 'bad_request', 'message': 'invalid public key'},
      });
      unawaited(close(4003, 'bad key'));
      return;
    }
    final fingerprint = LocalApiCrypto.fingerprint(raw);
    final known = server.pairingStore.isPaired(publicKey);
    _handshake = _Handshake(
      name: name.trim(),
      version: version,
      publicKey: publicKey,
      fingerprint: fingerprint,
      nonce: LocalApiCrypto.newNonce(),
      known: known,
      startedAt: DateTime.now(),
    );
    _enqueue({
      'type': 'pairing.challenge',
      'protocol': LocalApiServer.protocolVersion,
      'nonce': _handshake!.nonce,
      'known': known,
      'fingerprint': fingerprint,
      'message': 'meshcore-open-pair-v1:${_handshake!.nonce}',
    });
  }

  Future<void> _completePairing(Map<String, dynamic> message) async {
    final handshake = _handshake;
    if (handshake == null) {
      _enqueue({
        'type': 'error',
        'error': {'code': 'bad_request', 'message': 'send hello first'},
      });
      unawaited(close(4001, 'hello first'));
      return;
    }
    if (DateTime.now().difference(handshake.startedAt) >
        const Duration(minutes: 2)) {
      _enqueue({
        'type': 'error',
        'error': {'code': 'unauthorized', 'message': 'challenge expired'},
      });
      unawaited(close(4001, 'expired'));
      return;
    }
    final signature = message['signature'];
    if (signature is! String) {
      _enqueue({
        'type': 'error',
        'error': {'code': 'bad_request', 'message': 'signature is required'},
      });
      unawaited(close(4003, 'bad signature'));
      return;
    }
    final publicKeyRaw = LocalApiCrypto.decodePublicKey(handshake.publicKey);
    final signedMessage = 'meshcore-open-pair-v1:${handshake.nonce}';
    if (publicKeyRaw == null ||
        !LocalApiCrypto.verify(publicKeyRaw, signedMessage, signature)) {
      _enqueue({
        'type': 'error',
        'error': {'code': 'unauthorized', 'message': 'bad signature'},
      });
      unawaited(close(4003, 'bad signature'));
      return;
    }

    if (!handshake.known) {
      final request = PairingRequest(
        id: 'p${DateTime.now().microsecondsSinceEpoch}',
        name: handshake.name,
        version: handshake.version,
        publicKey: handshake.publicKey,
        fingerprint: handshake.fingerprint,
        requestedAt: DateTime.now(),
      );
      final allowed = await server.pairingBroker.ask(request);
      if (!allowed) {
        _enqueue({
          'type': 'error',
          'error': {'code': 'unauthorized', 'message': 'pairing denied'},
        });
        unawaited(close(4003, 'pairing denied'));
        return;
      }
      await server.pairingStore.add(
        PairedClient(
          name: handshake.name,
          publicKey: handshake.publicKey,
          fingerprint: handshake.fingerprint,
          pairedAt: DateTime.now(),
        ),
      );
    }

    _authenticated = true;
    _publicKey = handshake.publicKey;
    _helloTimeout?.cancel();
    _handshake = null;
    _sendHelloOk(handshake);
  }

  void _sendHelloOk(_Handshake handshake) {
    final info = server.host.deviceInfo();
    _enqueue({
      'type': 'hello',
      'protocol': LocalApiServer.protocolVersion,
      'client': {'name': handshake.name, 'fingerprint': handshake.fingerprint},
      'device': {
        'name': info['name'],
        'pubkey': info['pubkey'],
        'firmwareVerCode': info['firmwareVerCode'],
        'connected': info['connected'],
      },
      'eventTypes': const [
        'channel.text',
        'channel.data',
        'direct.text',
        'advert',
      ],
      'limits': {
        'maxPayloadBytes': LocalApiServer.maxPayloadBytes,
        'sendsPerMinute': LocalApiServer.sendsPerMinute,
        'minSendGapMs': LocalApiServer.minSendGap.inMilliseconds,
        'maxSubscriptions': LocalApiServer.maxSubscriptionsPerClient,
      },
    });
  }

  Future<void> _dispatch(Map<String, dynamic> message) async {
    final id = message['id'];
    final method = message['method'];
    final params = message['params'];
    if (method is! String) {
      _respondError(id, 'bad_request', 'method is required');
      return;
    }
    try {
      final result = await _call(
        method,
        params is Map<String, dynamic> ? params : const {},
      );
      _respondOk(id, result);
    } on _ApiError catch (error) {
      _respondError(id, error.code, error.message);
    } catch (error) {
      appLogger.warn('Local API $method failed: $error', tag: 'LocalApi');
      _respondError(id, 'internal', 'request failed');
    }
  }

  Future<Object?> _call(String method, Map<String, dynamic> params) async {
    switch (method) {
      case 'device.info':
        final info = server.host.deviceInfo();
        return {...info, 'channels': server.host.channels()};
      case 'channels.list':
        return {'channels': server.host.channels()};
      case 'regions.list':
        return {'regions': server.regions?.toJson() ?? const []};
      case 'regions.resolve':
        final latitude = params['lat'] is num
            ? (params['lat'] as num).toDouble()
            : null;
        final longitude = params['lon'] is num
            ? (params['lon'] as num).toDouble()
            : null;
        if (latitude == null || longitude == null) {
          throw _ApiError('bad_request', 'lat and lon are required');
        }
        if (latitude < -90 ||
            latitude > 90 ||
            longitude < -180 ||
            longitude > 180) {
          throw _ApiError('coordinate_range', 'lat/lon out of range');
        }
        final region = server.regions?.resolve(latitude, longitude);
        return {
          'region': region == null
              ? null
              : {
                  ...region.toJson(),
                  'distanceKm': distanceKmBetween(
                    latitude,
                    longitude,
                    region.latitude,
                    region.longitude,
                  ),
                },
        };
      case 'contacts.list':
        final limit = _intParam(params, 'limit', fallback: 200);
        return {'contacts': server.host.contacts(limit: limit.clamp(1, 500))};
      case 'events.subscribe':
        return _subscribe(params);
      case 'events.unsubscribe':
        final id = params['subscriptionId'];
        if (id is! String || _subscriptions.remove(id) == null) {
          throw _ApiError('bad_request', 'unknown subscription');
        }
        return const <String, Object?>{};
      case 'channel.sendText':
        final channel = _channelParam(params);
        final text = _textParam(params, 'text');
        final region = _regionParam(params);
        _spendSendQuota();
        await server.host.sendChannelText(channel, text, region: region);
        return const {'queued': true};
      case 'channel.sendData':
        final channel = _channelParam(params);
        final dataType = _intParam(params, 'dataType');
        if (dataType <= 0 || dataType > 0xFFFF) {
          throw _ApiError('invalid_data_type', 'dataType must be 1..65535');
        }
        final payload = _payloadParam(params);
        if (payload.length > LocalApiServer.maxPayloadBytes) {
          throw _ApiError(
            'payload_too_large',
            'payload is ${payload.length} bytes; the limit is '
                '${LocalApiServer.maxPayloadBytes}',
          );
        }
        final region = _regionParam(params);
        _spendSendQuota();
        final sent = await server.host.sendChannelData(
          channel,
          dataType,
          payload,
          region: region,
        );
        if (!sent) {
          throw _ApiError(
            'not_connected',
            'the radio is not connected or its firmware is too old',
          );
        }
        return const {'queued': true};
      case 'direct.sendText':
        final pubkey = params['pubkey'];
        if (pubkey is! String) {
          throw _ApiError('bad_request', 'pubkey is required');
        }
        final contact = server.host.resolveContact(pubkey);
        if (contact == null) {
          throw _ApiError('unknown_contact', 'no contact with that pubkey');
        }
        final text = _textParam(params, 'text');
        _spendSendQuota();
        await server.host.sendDirectText(contact, text);
        return const {'queued': true};
      case 'advert.send':
        final flood = params['flood'];
        _spendSendQuota();
        await server.host.sendAdvert(flood: flood is bool ? flood : true);
        return const {'queued': true};
      default:
        throw _ApiError('unknown_method', 'unknown method: $method');
    }
  }

  Object? _subscribe(Map<String, dynamic> params) {
    if (_subscriptions.length >= LocalApiServer.maxSubscriptionsPerClient) {
      throw _ApiError('rate_limited', 'too many subscriptions');
    }
    final events = params['events'];
    final List<String> types;
    if (events == null) {
      types = const ['channel.text', 'channel.data', 'direct.text', 'advert'];
    } else if (events is List && events.every((e) => e is String)) {
      types = events.cast<String>();
    } else {
      throw _ApiError('bad_request', 'events must be a list of strings');
    }
    const known = {'channel.text', 'channel.data', 'direct.text', 'advert'};
    for (final type in types) {
      if (!known.contains(type)) {
        throw _ApiError('bad_request', 'unknown event type: $type');
      }
    }

    final rawChannel = params['channel'] ?? params['channelIndex'];
    int? channelIndex;
    String? channelName;
    if (rawChannel != null) {
      if (rawChannel is int) {
        channelIndex = rawChannel;
      } else if (rawChannel is String) {
        final resolved = server.host.resolveChannel(
          rawChannel,
          onAmbiguous: () {
            throw _ApiError(
              'ambiguous_channel',
              'more than one channel named '
                  '$rawChannel',
            );
          },
        );
        if (resolved == null) {
          throw _ApiError('unknown_channel', 'no channel named $rawChannel');
        }
        channelIndex = resolved.index;
        channelName = resolved.name;
      } else {
        throw _ApiError('bad_request', 'channel must be a name or an index');
      }
    }

    final dataTypes = params['dataTypes'];
    final List<int> dataTypeFilter;
    if (dataTypes == null) {
      dataTypeFilter = const [];
    } else if (dataTypes is List && dataTypes.every((e) => e is int)) {
      dataTypeFilter = dataTypes.cast<int>();
    } else {
      throw _ApiError('bad_request', 'dataTypes must be a list of integers');
    }

    final pubkeys = params['pubkeys'];
    final List<String> pubkeyFilter;
    if (pubkeys == null) {
      pubkeyFilter = const [];
    } else if (pubkeys is List && pubkeys.every((e) => e is String)) {
      pubkeyFilter = pubkeys.cast<String>();
    } else {
      throw _ApiError('bad_request', 'pubkeys must be a list of strings');
    }

    final subscriptionId = 's${_subscriptions.length + 1}';
    _subscriptions[subscriptionId] = _Subscription(
      types: types.toSet(),
      channelIndex: channelIndex,
      channelName: channelName,
      dataTypes: dataTypeFilter.toSet(),
      pubkeys: pubkeyFilter.toSet(),
    );

    final archive = server.archive;
    if (archive != null && types.contains('channel.data')) {
      final resolvedName =
          channelName ??
          (channelIndex == null
              ? null
              : server.host.channels().firstWhere(
                      (channel) => channel['index'] == channelIndex,
                      orElse: () => const {},
                    )['name']
                    as String?);
      final key = _publicKey;
      if (key != null && resolvedName != null) {
        archive.noteInterest(key, resolvedName, dataTypeFilter);
      }
      final since = _parseSince(params['since']);
      if (since != null) {
        final replay = archive.replay(
          channel: resolvedName,
          dataTypes: dataTypeFilter.toSet(),
          since: since,
        );
        // Send the ack first, then the replay.
        scheduleMicrotask(() {
          for (final item in replay) {
            _enqueue({
              'type': 'event',
              'subscriptionId': subscriptionId,
              'event': _encodeEvent(
                ChannelDataEvent(
                  channelIndex: channelIndex ?? -1,
                  channelName: item.channel,
                  dataType: item.dataType,
                  payload: item.payload,
                  snrRaw: (item.snrDb * 4).round(),
                  outgoing: false,
                  receivedAt: item.receivedAt,
                ),
              ),
            });
          }
        });
      }
    }
    return {'subscriptionId': subscriptionId};
  }

  void deliver(MeshEvent event) {
    if (_closed || !_authenticated) return;
    for (final entry in _subscriptions.entries) {
      if (!entry.value.matches(event)) continue;
      _enqueue({
        'type': 'event',
        'subscriptionId': entry.key,
        'event': _encodeEvent(event),
      });
    }
  }

  Map<String, Object?> _encodeEvent(MeshEvent event) {
    switch (event) {
      case ChannelTextEvent():
        return {
          'type': 'channel.text',
          'channel': event.channelName,
          'channelIndex': event.channelIndex,
          'senderName': event.senderName,
          'senderKeyHex': event.senderKeyHex,
          'text': event.text,
          'sentAt': event.sentAt.toUtc().toIso8601String(),
          'messageId': event.messageId,
          'outgoing': event.outgoing,
          'receivedAt': event.receivedAt.toUtc().toIso8601String(),
        };
      case ChannelDataEvent():
        return {
          'type': 'channel.data',
          'channel': event.channelName,
          'channelIndex': event.channelIndex,
          'dataType': event.dataType,
          'payload': base64Encode(event.payload),
          'snrDb': event.snrDb,
          'outgoing': event.outgoing,
          'receivedAt': event.receivedAt.toUtc().toIso8601String(),
        };
      case DirectTextEvent():
        return {
          'type': 'direct.text',
          'pubkey': event.pubkeyHex,
          'name': event.name,
          'text': event.text,
          'sentAt': event.sentAt.toUtc().toIso8601String(),
          'messageId': event.messageId,
          'outgoing': event.outgoing,
          'receivedAt': event.receivedAt.toUtc().toIso8601String(),
        };
      case AdvertEvent():
        return {
          'type': 'advert',
          'pubkey': event.pubkeyHex,
          'name': event.name,
          'nodeType': event.type,
          'lastSeen': event.lastSeen?.toUtc().toIso8601String(),
          'receivedAt': event.receivedAt.toUtc().toIso8601String(),
        };
    }
  }

  DateTime? _parseSince(Object? value) {
    if (value == null) return null;
    if (value is String) return DateTime.tryParse(value)?.toUtc();
    if (value is num) {
      final millis = value > 100000000000
          ? value.toInt()
          : value.toInt() * 1000;
      return DateTime.fromMillisecondsSinceEpoch(millis, isUtc: true);
    }
    return null;
  }

  String? _regionParam(Map<String, dynamic> params) {
    final raw = params['region'];
    if (raw == null) return null;
    if (raw is! String || raw.isEmpty || raw.length > 32) {
      throw _ApiError('bad_request', 'region must be a short string');
    }
    return raw;
  }

  void _spendSendQuota() {
    final now = DateTime.now();
    _sendTimes.removeWhere(
      (time) => now.difference(time) > const Duration(minutes: 1),
    );
    if (_sendTimes.isNotEmpty &&
        now.difference(_sendTimes.last) < LocalApiServer.minSendGap) {
      throw _ApiError('rate_limited', 'one send per two seconds');
    }
    if (_sendTimes.length >= LocalApiServer.sendsPerMinute) {
      throw _ApiError('rate_limited', 'too many sends in a minute');
    }
    _sendTimes.add(now);
  }

  Channel _channelParam(Map<String, dynamic> params) {
    final raw = params['channel'];
    if (raw is! String) {
      throw _ApiError('bad_request', 'channel is required');
    }
    final channel = server.host.resolveChannel(
      raw,
      onAmbiguous: () {
        throw _ApiError(
          'ambiguous_channel',
          'more than one channel named $raw',
        );
      },
    );
    if (channel == null) {
      throw _ApiError('unknown_channel', 'no channel named $raw');
    }
    return channel;
  }

  String _textParam(Map<String, dynamic> params, String name) {
    final text = params[name];
    if (text is! String || text.isEmpty) {
      throw _ApiError('bad_request', '$name is required');
    }
    if (text.length > 2000) {
      throw _ApiError('bad_request', '$name is too long');
    }
    return text;
  }

  Uint8List _payloadParam(Map<String, dynamic> params) {
    final raw = params['payload'];
    if (raw is! String || raw.isEmpty) {
      throw _ApiError('bad_request', 'payload (base64) is required');
    }
    try {
      return base64Decode(raw);
    } catch (_) {
      throw _ApiError('bad_request', 'payload is not valid base64');
    }
  }

  int _intParam(Map<String, dynamic> params, String name, {int? fallback}) {
    final value = params[name];
    if (value == null && fallback != null) return fallback;
    if (value is! int) {
      throw _ApiError('bad_request', '$name must be an integer');
    }
    return value;
  }

  void _respondOk(Object? id, Object? result) {
    _enqueue({
      'id': id,
      'ok': true,
      'result': result ?? const <String, Object?>{},
    });
  }

  void _respondError(Object? id, String code, String message) {
    _enqueue({
      'id': id,
      'ok': false,
      'error': {'code': code, 'message': message},
    });
  }

  void _enqueue(Map<String, Object?> message) {
    if (_closed) return;
    if (_queued >= LocalApiServer.maxQueuedMessages) {
      unawaited(close(1013, 'slow consumer'));
      return;
    }
    _queued++;
    try {
      socket.add(jsonEncode(message));
    } catch (_) {
      unawaited(close(1011, 'write failed'));
    } finally {
      _queued--;
    }
  }
}

class _Handshake {
  final String name;
  final String version;
  final String publicKey;
  final String fingerprint;
  final String nonce;
  final bool known;
  final DateTime startedAt;

  _Handshake({
    required this.name,
    required this.version,
    required this.publicKey,
    required this.fingerprint,
    required this.nonce,
    required this.known,
    required this.startedAt,
  });
}

class _Subscription {
  final Set<String> types;
  final int? channelIndex;
  final String? channelName;
  final Set<int> dataTypes;
  final Set<String> pubkeys;

  _Subscription({
    required this.types,
    required this.channelIndex,
    required this.channelName,
    required this.dataTypes,
    required this.pubkeys,
  });

  bool matches(MeshEvent event) {
    final type = switch (event) {
      ChannelTextEvent() => 'channel.text',
      ChannelDataEvent() => 'channel.data',
      DirectTextEvent() => 'direct.text',
      AdvertEvent() => 'advert',
    };
    if (!types.contains(type)) return false;

    if (channelIndex != null) {
      final eventIndex = switch (event) {
        ChannelTextEvent() => event.channelIndex,
        ChannelDataEvent() => event.channelIndex,
        _ => null,
      };
      if (eventIndex != channelIndex) return false;
      if (channelName != null) {
        final eventName = switch (event) {
          ChannelTextEvent() => event.channelName,
          ChannelDataEvent() => event.channelName,
          _ => '',
        };
        if (eventName != channelName) return false;
      }
    }

    if (dataTypes.isNotEmpty) {
      if (event is! ChannelDataEvent || !dataTypes.contains(event.dataType)) {
        return false;
      }
    }

    if (pubkeys.isNotEmpty) {
      final pubkey = switch (event) {
        DirectTextEvent() => event.pubkeyHex,
        AdvertEvent() => event.pubkeyHex,
        _ => null,
      };
      if (pubkey == null || !pubkeys.contains(pubkey)) return false;
    }
    return true;
  }
}

class _ApiError implements Exception {
  final String code;
  final String message;

  _ApiError(this.code, this.message);
}
