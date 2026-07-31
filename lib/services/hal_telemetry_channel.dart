/// Dart side of the HAL push-telemetry stream (v0.1.29+61).
///
/// Mirrors the dedicated platform channel exposed by `BydNativePlugin`:
///
///   * MethodChannel `bz5_companion/native_car` (shared with the rest of
///     the native plugin) — carries `halStreamStart` / `halStreamStop`.
///   * EventChannel  `bz5_companion/hal_telemetry/events` — push stream of
///     decoded telemetry, one [HalEvent] per decoded value, delivered in
///     batches (the platform coalesces binder-thread events into lists to
///     avoid flooding the channel; we flatten them back to a flat stream).
///
/// This is the LOW-LEVEL wrapper only — no caching, no source selection,
/// no UI. The `HalDataSource` (next patch) will sit on top and adapt this
/// into the `VehicleDataSource` contract; the SPEED overlapping pilot will
/// consume that. Nothing in companion subscribes to this yet — bringing
/// up the stream and watching the logs is the whole job of +61.
///
/// Lifecycle:
///   final hal = HalTelemetryChannel.instance;
///   final sub = hal.events.listen((e) => print(e));   // listen FIRST
///   final status = await hal.start();                  // then start
///   // ... later:
///   await hal.stop();
///   await sub.cancel();
///
/// `start()` MUST be called after a listener is attached — the platform
/// rejects `halStreamStart` with `HAL_NO_SINK` if nothing is listening on
/// the event channel yet (there'd be nowhere to push).
library;

import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// One decoded telemetry value off the HAL stream.
///
/// The platform decodes raw framework events through the vendored
/// `TelemetryDecoderTable` and ships finished values — [value] is already
/// in [unit] (HAL gives finished units; NO client-side scale/offset/sign
/// is applied anywhere on this path).
@immutable
class HalEvent {
  /// Decoder name, e.g. `speed`, `pack_current`, `cell_v_highest`.
  final String name;

  /// Unit string from the decoder, e.g. `km/h`, `A`, `V`, `cm`. Empty
  /// (`—` upstream) for enum/index values like `gear_enum`, `cell_idx_*`.
  final String unit;

  /// Decoded numeric value in [unit]. May be int or double depending on
  /// the decoder's `ValueSource`; kept as [num] here.
  final num? value;

  /// Canonical decoder key `"<targetKey>|0x<SUBTYPE_HEX8>"`, suffix-
  /// normalized platform-side (no `_tail`/`_priority`/... variants).
  final String key;

  /// Raw subtype (unsigned u32 widened to int).
  final int subtype;

  /// Source timestamp (ms since boot/epoch as the framework reports it).
  final int ts;

  /// v0.1.29+88: diagnostic extras, present only on raw BigData frames
  /// (name=="bigdata_raw"). Null for normal decoded signals.
  final String? canIdHex;
  final String? bufHex;
  final int? bufSize;

  const HalEvent({
    required this.name,
    required this.unit,
    required this.value,
    required this.key,
    required this.subtype,
    required this.ts,
    this.canIdHex,
    this.bufHex,
    this.bufSize,
  });

  factory HalEvent.fromMap(Map<Object?, Object?> m) => HalEvent(
        name: (m['name'] as String?) ?? '',
        unit: (m['unit'] as String?) ?? '',
        value: m['value'] as num?,
        key: (m['key'] as String?) ?? '',
        subtype: (m['subtype'] as num?)?.toInt() ?? 0,
        ts: (m['ts'] as num?)?.toInt() ?? 0,
        canIdHex: m['can_id_hex'] as String?,
        bufHex: m['buf_hex'] as String?,
        bufSize: (m['buf_size'] as num?)?.toInt(),
      );

  @override
  String toString() => 'HalEvent($name=$value $unit @$key ts=$ts)';
}

/// Status returned by [HalTelemetryChannel.start] — the subscriber's
/// registration result, for bring-up diagnostics.
@immutable
class HalStartStatus {
  final int attempted;
  final int registered;
  final int failed;

  /// key → register-phase error message; only for failed targets.
  final Map<Object?, Object?> errors;

  const HalStartStatus({
    required this.attempted,
    required this.registered,
    required this.failed,
    required this.errors,
  });

  factory HalStartStatus.fromMap(Map<Object?, Object?> m) => HalStartStatus(
        attempted: (m['attempted'] as num?)?.toInt() ?? 0,
        registered: (m['registered'] as num?)?.toInt() ?? 0,
        failed: (m['failed'] as num?)?.toInt() ?? 0,
        errors: (m['errors'] as Map<Object?, Object?>?) ?? const {},
      );

  /// A target may register OK and still never deliver an event (the silent
  /// push wall) — so this only reflects register-time success, not flow.
  bool get ok => registered > 0 && failed == 0;

  @override
  String toString() =>
      'HalStartStatus(registered=$registered/$attempted, failed=$failed)';
}

class HalTelemetryChannel {
  static const MethodChannel _method =
      MethodChannel('bz5_companion/native_car');
  static const EventChannel _events =
      EventChannel('bz5_companion/hal_telemetry/events');

  static final instance = HalTelemetryChannel._();
  HalTelemetryChannel._();

  Stream<HalEvent>? _stream;

  /// Broadcast stream of decoded events. The platform delivers batches
  /// (List<Map>) to spare the channel; we flatten them so consumers see a
  /// flat [HalEvent] stream. Lazily created and shared.
  Stream<HalEvent> get events {
    return _stream ??= _events
        .receiveBroadcastStream()
        .expand<HalEvent>((batch) {
          // Each delivery is a List of per-value maps. Be defensive: a
          // single map (non-batched) is tolerated too.
          if (batch is List) {
            return batch
                .whereType<Map<Object?, Object?>>()
                .map(HalEvent.fromMap);
          }
          if (batch is Map<Object?, Object?>) {
            return [HalEvent.fromMap(batch)];
          }
          return const <HalEvent>[];
        })
        .asBroadcastStream();
  }

  /// Start the live subscription. Call AFTER attaching a listener to
  /// [events] — the platform returns `HAL_NO_SINK` otherwise.
  ///
  /// Returns the subscriber start status, or null if the platform errored
  /// (logged platform-side; caller treats null as "HAL stream unavailable,
  /// stay on the other source").
  Future<HalStartStatus?> start() async {
    try {
      final r = await _method.invokeMethod<Map<Object?, Object?>>(
        'halStreamStart',
      );
      return r == null ? null : HalStartStatus.fromMap(r);
    } on PlatformException catch (e) {
      debugPrint('HAL halStreamStart failed: ${e.code} ${e.message}');
      return null;
    }
  }

  /// v0.1.83+182: сообщить платформе, что файл фонового журнала забран.
  ///
  /// Не косметика. Журнал, дойдя до потолка, останавливает запись и сам
  /// из этого состояния не выходит: его `emit` при `full` до файловой
  /// системы не доходит и заметить пропажу файла не может. Без этого
  /// вызова первая же переполненная поездка выключила бы фоновый сбор до
  /// конца жизни процесса — а процесс на этом ГУ живёт часами.
  Future<void> noteJournalConsumed() async {
    try {
      await _method.invokeMethod<bool>('halJournalConsumed');
    } on PlatformException catch (e) {
      debugPrint('HAL halJournalConsumed failed: ${e.code} ${e.message}');
    }
  }

  /// Stop the live subscription. Idempotent; safe even if not started.
  Future<void> stop() async {
    try {
      await _method.invokeMethod<bool>('halStreamStop');
    } on PlatformException catch (e) {
      debugPrint('HAL halStreamStop failed: ${e.code} ${e.message}');
    }
  }
}
