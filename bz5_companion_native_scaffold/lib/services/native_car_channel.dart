/// Low-level Dart wrapper around the `BydNativePlugin` Kotlin code.
///
/// This file is a 1:1 mirror of the platform channel — no business
/// logic, no caching, no decoding beyond what the channel itself
/// already does. Higher-level features (e.g. `NativeCarDataSource`)
/// build on top of it.
///
/// Two channels:
///   * MethodChannel `bz5_companion/native_car` — request/response
///   * EventChannel  `bz5_companion/native_car/events` — push events
///     from active subscriptions, flowing in a single broadcast
///     [Stream] for the whole process.
///
/// All methods are idempotent and safe to call repeatedly. They
/// return Dart-native types (no opaque handles): `int`, `double`,
/// `String`, `bool`, `List`, `Map`, `Uint8List`.
library;

import 'dart:async';
import 'package:flutter/services.dart';

class NativeCarChannel {
  static const MethodChannel _method =
      MethodChannel('bz5_companion/native_car');
  static const EventChannel _events =
      EventChannel('bz5_companion/native_car/events');

  // We expose a single broadcast Stream so multiple subscribers can
  // share one underlying EventChannel listener.
  static Stream<NativeEvent>? _eventStream;

  /// Singleton for cheap dependency injection in widgets.
  static final instance = NativeCarChannel._();
  NativeCarChannel._();

  /// Cheap probe — true if the BYD framework class (BYDAutoBodyworkDevice)
  /// is loadable on this device. Cached by the platform side.
  Future<bool> isNativeAvailable() async {
    try {
      final r = await _method.invokeMethod<bool>('isNativeAvailable');
      return r ?? false;
    } on PlatformException {
      // We never want this probe to throw to the UI — a false return
      // simply means "fall back to BLE".
      return false;
    }
  }

  /// Returns the VIN, or null if unavailable.
  /// [fresh] forces a CAN-side fetch (slower); default uses the
  /// framework's cached value.
  Future<String?> detectVin({bool fresh = false}) async {
    try {
      return await _method.invokeMethod<String>('detectVin', {'fresh': fresh});
    } on PlatformException catch (e) {
      // Surface as null — the auto-detector UI should treat this as
      // "not on a head unit" rather than "error". Logs go via the
      // platform side.
      return null;
    }
  }

  /// Read a one-shot DTC snapshot from the diag socket.
  ///
  /// [command] is one of `latest_diag_data` (active faults) or
  /// `all_diag_data` (active + historic).
  Future<List<Map<String, Object?>>> diagSnapshot({
    String command = 'latest_diag_data',
    Duration timeout = const Duration(seconds: 5),
  }) async {
    final raw = await _method.invokeMethod<List<Object?>>('diagSnapshot', {
      'command': command,
      'timeoutMs': timeout.inMilliseconds,
    });
    if (raw == null) return const [];
    // Each entry is a Map<String, Object?>; coerce to that type.
    return raw
        .whereType<Map<Object?, Object?>>()
        .map((m) => m.map((k, v) => MapEntry(k.toString(), v)))
        .toList();
  }

  /// Read a single property by hex name (`"0x99002B0A"`).
  ///
  /// Returns the structured response map produced by
  /// [BydCarPropertyClient.decodeResponse]:
  /// `{name, ok, code?, errorMsg?, value?, type?, featureId?}`.
  Future<Map<String, Object?>> getProperty(String name) async {
    final r = await _method.invokeMethod<Map<Object?, Object?>>(
        'getProperty', {'name': name});
    return (r ?? {}).map((k, v) => MapEntry(k.toString(), v));
  }

  /// Bulk read.
  Future<List<Map<String, Object?>>> getProperties(List<String> names) async {
    final r = await _method.invokeMethod<List<Object?>>(
        'getProperties', {'names': names});
    if (r == null) return const [];
    return r
        .whereType<Map<Object?, Object?>>()
        .map((m) => m.map((k, v) => MapEntry(k.toString(), v)))
        .toList();
  }

  /// Probe the server-side config for one or more property names.
  /// Useful as a runtime calibration tool — for unknown features the
  /// returned `dataType` reveals whether the value will be an int /
  /// long / float / byte array.
  Future<List<Map<String, Object?>>> getPropertyConfig(List<String> names) async {
    final r = await _method.invokeMethod<List<Object?>>(
        'getPropertyConfig', {'names': names});
    if (r == null) return const [];
    return r
        .whereType<Map<Object?, Object?>>()
        .map((m) => m.map((k, v) => MapEntry(k.toString(), v)))
        .toList();
  }

  /// Subscribe to push events on the given property names. Returns
  /// the list of names that were actually subscribed to (the platform
  /// dedupes — repeated calls for the same name don't multiply
  /// listeners).
  ///
  /// Use [events] to receive the actual updates.
  Future<List<String>> subscribe(List<String> names) async {
    final r = await _method.invokeMethod<List<Object?>>('subscribe', {'names': names});
    if (r == null) return const [];
    return r.whereType<String>().toList();
  }

  Future<void> unsubscribe(List<String> names) async {
    await _method.invokeMethod<bool>('unsubscribe', {'names': names});
  }

  /// Write a property. The type hint helps the platform side serialize:
  /// `'int'`, `'long'`, `'float'`, `'double'`, `'bytes'`.
  Future<NativeStatus> setProperty(
    String name,
    Object value, {
    String? type,
  }) async {
    final r = await _method.invokeMethod<Map<Object?, Object?>>(
      'setProperty',
      {'name': name, 'value': value, 'type': type},
    );
    return NativeStatus.fromMap((r ?? const {}).map(
        (k, v) => MapEntry(k.toString(), v)));
  }

  /// Get the OS-side permission state for every BYDAUTO_* permission
  /// the plugin knows about. Useful for a settings/onboarding screen
  /// that walks the user through runtime grants.
  Future<List<PermissionStatus>> checkPermissions() async {
    final r = await _method.invokeMethod<List<Object?>>('checkPermissions');
    if (r == null) return const [];
    return r
        .whereType<Map<Object?, Object?>>()
        .map((m) => PermissionStatus.fromMap(
            m.map((k, v) => MapEntry(k.toString(), v))))
        .toList();
  }

  /// Broadcast stream of all subscription events. Multiple listeners
  /// share one underlying EventChannel handle.
  Stream<NativeEvent> get events {
    return _eventStream ??= _events
        .receiveBroadcastStream()
        .map((raw) {
          if (raw is Map) {
            return NativeEvent.fromMap(raw.map(
                (k, v) => MapEntry(k.toString(), v)));
          }
          // Some platform implementations may stream non-Map payloads
          // (e.g. raw strings for debug builds). Wrap so the UI never
          // sees an untyped object.
          return NativeEvent.raw(raw);
        })
        .asBroadcastStream();
  }
}

/// A single push event from `registerValueCallback`.
class NativeEvent {
  final String name;
  final Object? value;
  final String? type;
  final int? tsMs;
  final Object? raw; // populated for non-standard payloads only

  const NativeEvent({
    required this.name,
    required this.value,
    required this.type,
    required this.tsMs,
    this.raw,
  });

  factory NativeEvent.fromMap(Map<String, Object?> m) => NativeEvent(
        name: (m['name'] ?? '').toString(),
        value: m['value'],
        type: m['type'] as String?,
        tsMs: (m['tsMs'] as num?)?.toInt(),
      );

  factory NativeEvent.raw(Object? raw) => NativeEvent(
        name: '<raw>',
        value: null,
        type: null,
        tsMs: DateTime.now().millisecondsSinceEpoch,
        raw: raw,
      );

  @override
  String toString() => 'NativeEvent($name=$value [$type])';
}

class NativeStatus {
  final int code;
  final String? description;
  const NativeStatus(this.code, this.description);
  bool get ok => code == 0;
  factory NativeStatus.fromMap(Map<String, Object?> m) => NativeStatus(
        (m['code'] as num?)?.toInt() ?? -1,
        m['description'] as String?,
      );

  @override
  String toString() => ok ? 'NativeStatus.ok' : 'NativeStatus($code, $description)';
}

class PermissionStatus {
  final String permission;
  final String label;
  final bool declared;
  final bool granted;
  final bool dangerous;

  const PermissionStatus({
    required this.permission,
    required this.label,
    required this.declared,
    required this.granted,
    required this.dangerous,
  });

  factory PermissionStatus.fromMap(Map<String, Object?> m) => PermissionStatus(
        permission: (m['permission'] ?? '').toString(),
        label: (m['label'] ?? '').toString(),
        declared: (m['declared'] as bool?) ?? false,
        granted: (m['granted'] as bool?) ?? false,
        dangerous: (m['dangerous'] as bool?) ?? false,
      );
}
