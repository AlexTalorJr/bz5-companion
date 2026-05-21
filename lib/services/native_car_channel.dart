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

  /// Pull recent log entries from the in-process ring buffer. This is
  /// the no-adb workflow: every BydLogger.{i,w,e} call on the platform
  /// side both writes to logcat AND appends to this ring. The Native
  /// Explorer screen polls this on a timer so the user can see errors
  /// without ever connecting a cable.
  ///
  /// [count] caps the returned list size (max 500).
  /// [sinceTs] is the millisecond timestamp of the newest entry the
  /// caller already has; only strictly newer entries are returned.
  /// Pass null on the first pull, then the `ts` of the last entry on
  /// subsequent pulls for incremental tailing.
  Future<List<NativeLogEntry>> pullLogs({int count = 200, int? sinceTs}) async {
    final raw = await _method.invokeMethod<List<Object?>>('pullLogs', {
      'count': count,
      'sinceTs': sinceTs,
    });
    if (raw == null) return const [];
    return raw
        .whereType<Map<Object?, Object?>>()
        .map((m) => NativeLogEntry.fromMap(
            m.map((k, v) => MapEntry(k.toString(), v))))
        .toList();
  }

  /// Wipe the in-process log ring. Does not affect android.util.Log /
  /// logcat — only the in-app buffer.
  Future<void> clearLogs() async {
    await _method.invokeMethod<bool>('clearLogs');
  }

  /// Launch Android Settings → App info for our package, so the user
  /// can flip dangerous-level BYDAUTO_* permissions manually. Returns
  /// false only if the launcher rejected the intent (very rare).
  ///
  /// This is the no-adb substitute for `adb shell pm grant ...`.
  Future<bool> openAppSettings() async {
    final r = await _method.invokeMethod<bool>('openAppSettings');
    return r ?? false;
  }

  /// One-shot environment snapshot: carserver presence/version, content
  /// provider resolution, BYD framework class availability, granted
  /// permission count, etc. Used by the "Diagnostics" panel and by the
  /// "Export diagnostics" button.
  Future<Map<String, Object?>> getDiagnostics() async {
    final r = await _method
        .invokeMethod<Map<Object?, Object?>>('getDiagnostics');
    if (r == null) return const {};
    return r.map((k, v) => MapEntry(k.toString(), v));
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

/// One log line pulled from the platform-side ring buffer.
///
/// [ts] is the millisecond timestamp at which BydLogger captured the
/// entry on the JVM side. [level] is one of `I`/`W`/`E` (`V` and `D`
/// are intentionally not retained in the ring). [throwable], when
/// non-null, is a 6-frame stack summary.
class NativeLogEntry {
  final int ts;
  final String level;
  final String tag;
  final String message;
  final String? throwable;

  const NativeLogEntry({
    required this.ts,
    required this.level,
    required this.tag,
    required this.message,
    required this.throwable,
  });

  factory NativeLogEntry.fromMap(Map<String, Object?> m) => NativeLogEntry(
        ts: (m['ts'] as num?)?.toInt() ?? 0,
        level: (m['level'] ?? '?').toString(),
        tag: (m['tag'] ?? '').toString(),
        message: (m['message'] ?? '').toString(),
        throwable: m['throwable'] as String?,
      );

  DateTime get dateTime => DateTime.fromMillisecondsSinceEpoch(ts);

  @override
  String toString() {
    final t = DateTime.fromMillisecondsSinceEpoch(ts);
    final h = t.hour.toString().padLeft(2, '0');
    final m = t.minute.toString().padLeft(2, '0');
    final s = t.second.toString().padLeft(2, '0');
    final ms = t.millisecond.toString().padLeft(3, '0');
    return '$h:$m:$s.$ms $level/$tag: $message';
  }
}
