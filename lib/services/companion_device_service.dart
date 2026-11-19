import 'dart:async';

import 'package:flutter/services.dart';

import '../utils/app_logger.dart';
import '../utils/platform_info.dart';

/// A presence change Android reported for an associated radio.
class CompanionPresence {
  /// Bluetooth address, upper case (`AA:BB:CC:DD:EE:FF`).
  final String address;
  final bool present;

  const CompanionPresence({required this.address, required this.present});

  static CompanionPresence? fromMap(Object? value) {
    if (value is! Map) return null;
    final address = value['address'];
    final present = value['present'];
    if (address is! String || address.isEmpty || present is! bool) return null;
    return CompanionPresence(address: address.toUpperCase(), present: present);
  }
}

/// How an association request ended.
enum CompanionAssociationResult { associated, cancelled, notFound, failed }

/// Android Companion Device Manager for the BLE radio.
///
/// An association lets Android start the app when the radio comes into range
/// (also after the system killed the process) and lets the app start its
/// foreground service from the background. Everything is a no-op returning
/// false where CDM does not exist: iOS, desktop, web and Android before 8.0.
class CompanionDeviceService {
  CompanionDeviceService._();

  static final CompanionDeviceService instance = CompanionDeviceService._();

  static const MethodChannel _channel = MethodChannel(
    'meshcore_open/companion_device',
  );
  static const EventChannel _presenceChannel = EventChannel(
    'meshcore_open/companion_device/presence',
  );

  bool? _supported;
  Stream<CompanionPresence>? _presence;

  /// Whether this device can associate a radio. On Android 8 to 11 an
  /// association exists but Android cannot report presence.
  Future<bool> isSupported() async {
    if (!PlatformInfo.isAndroid) return false;
    final cached = _supported;
    if (cached != null) return cached;
    final supported = await _invoke<bool>('isSupported') ?? false;
    _supported = supported;
    return supported;
  }

  /// Whether Android tells the app when the radio comes into range
  /// (Android 12 and later).
  Future<bool> canObservePresence() async {
    if (!await isSupported()) return false;
    return await _invoke<bool>('canObservePresence') ?? false;
  }

  Future<bool> isAssociated(String address) async {
    if (!await isSupported()) return false;
    return await _invoke<bool>('isAssociated', {'address': address}) ?? false;
  }

  /// Shows the system dialog that lets the user allow the app to manage
  /// the radio, then starts presence observation.
  Future<CompanionAssociationResult> associate(
    String address, {
    String? name,
  }) async {
    if (!await isSupported()) return CompanionAssociationResult.failed;
    try {
      final result = await _channel.invokeMethod<String>('associate', {
        'address': address,
        'name': ?name,
      });
      return switch (result) {
        'associated' => CompanionAssociationResult.associated,
        'cancelled' => CompanionAssociationResult.cancelled,
        'notFound' => CompanionAssociationResult.notFound,
        _ => CompanionAssociationResult.failed,
      };
    } on PlatformException catch (e) {
      appLogger.warn('Companion association failed: $e', tag: 'Companion');
      return CompanionAssociationResult.failed;
    } on MissingPluginException {
      return CompanionAssociationResult.failed;
    }
  }

  Future<void> disassociate(String address) async {
    if (!await isSupported()) return;
    await _invoke<void>('disassociate', {'address': address});
  }

  /// Starts or stops presence observation for an associated radio. A radio
  /// the user disconnected should not wake the app.
  Future<void> setObserving(String address, bool observe) async {
    if (!await isSupported()) return;
    await _invoke<void>('setObserving', {
      'address': address,
      'observe': observe,
    });
  }

  /// True once if Android started this process because an associated radio
  /// came into range.
  Future<bool> takeStartedByPresence() async {
    if (!PlatformInfo.isAndroid) return false;
    return await _invoke<bool>('takeStartedByPresence') ?? false;
  }

  /// Presence changes of associated radios while the app runs.
  Stream<CompanionPresence> get presence {
    if (!PlatformInfo.isAndroid) return const Stream.empty();
    return _presence ??= _presenceChannel
        .receiveBroadcastStream()
        .map(CompanionPresence.fromMap)
        .where((event) => event != null)
        .cast<CompanionPresence>()
        .handleError((Object e) {
          appLogger.warn('Companion presence stream: $e', tag: 'Companion');
        });
  }

  Future<T?> _invoke<T>(String method, [Map<String, Object?>? args]) async {
    try {
      return await _channel.invokeMethod<T>(method, args);
    } on PlatformException catch (e) {
      appLogger.warn('Companion $method failed: $e', tag: 'Companion');
      return null;
    } on MissingPluginException {
      return null;
    }
  }
}
