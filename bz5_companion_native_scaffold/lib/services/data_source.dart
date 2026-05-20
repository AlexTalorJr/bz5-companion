/// Abstract vehicle data source.
///
/// The bz5-companion app reads from one of two channels depending on
/// where it runs:
///
///   * On a phone with a BLE→ELM327 OBD adapter — the existing
///     [ConnectionService] implementation backed by `flutter_blue_plus`
///     and hand-rolled UDS framing.
///
///   * On the car's head unit — a native channel that talks straight
///     to `com.byd.car.server`'s `ICarPropertyService` AIDL plus the
///     `diag_socket_channel` LocalSocket. No BLE, no adapter, no ELM.
///
/// This file declares the shared contract. The two implementations live
/// in `ble_obd_data_source.dart` (currently the existing
/// `ConnectionService` lightly adapted) and `native_car_data_source.dart`
/// (new, talks to [NativeCarChannel]).
///
/// **Important**: this interface is intentionally narrow. It captures
/// only the cross-cutting operations the high-level features (trip
/// logging, charging detection, snapshots, DTC scans) need. The two
/// implementations remain free to expose richer per-source APIs to UI
/// code that explicitly wants one or the other (e.g. BLE adapter scan
/// is BLE-only, native diag snapshot is native-only).
///
/// Lifecycle:
///   - [connect] — bind / open whatever transport is needed
///   - [disconnect] — release it (idempotent)
///   - [readValue] — one-shot read
///   - [subscribe] — push-based stream
///   - [readDtcSnapshot] — one-shot DTC list
///   - [vin] — auto-detected (may be null if unknown / not connected)
///
/// Errors: every method either returns a tagged failure ([VehicleResult])
/// or throws a [VehicleDataException] for fatal cases (transport gone).
/// Callers should treat per-property failures as data hygiene problems
/// (skip and continue), not application errors.
library;

import 'dart:async';

/// Which underlying channel a [VehicleDataSource] uses. Useful for the
/// UI to label things and for diagnostics ("connected via BLE" vs
/// "connected to head unit native API").
enum DataSourceKind { ble, native, unknown }

/// Connection lifecycle states.
enum ConnState { disconnected, connecting, connected, error }

/// Generic per-read result. Successful reads carry [value]; failures
/// carry [errorCode] / [errorMessage]. Both forms also carry the key
/// the read was for, so a caller iterating a list of keys can route
/// the result back to the right slot without bookkeeping.
class VehicleResult<T> {
  final String key;
  final T? value;
  final bool ok;
  final int? errorCode;
  final String? errorMessage;
  final DateTime ts;

  VehicleResult.ok(this.key, this.value)
      : ok = true,
        errorCode = null,
        errorMessage = null,
        ts = DateTime.now();

  VehicleResult.error(this.key, this.errorCode, this.errorMessage)
      : ok = false,
        value = null,
        ts = DateTime.now();

  @override
  String toString() => ok
      ? 'VehicleResult.ok($key, $value)'
      : 'VehicleResult.error($key, $errorCode, $errorMessage)';
}

/// Fatal transport error — propagate up so callers can switch source.
class VehicleDataException implements Exception {
  final String message;
  final Object? cause;
  VehicleDataException(this.message, [this.cause]);
  @override
  String toString() => 'VehicleDataException: $message${cause != null ? ' ($cause)' : ''}';
}

/// One row from a diagnostic snapshot. Stable across implementations
/// even though only the native source actually populates DTC fields
/// today — the BLE source surfaces UDS-readable codes through the
/// same shape so the UI doesn't care.
class DtcRow {
  final String? moduleName;
  final String? code;
  final String? description;
  final int? state;          // 0 = active fault, !=0 = historic / cleared
  final Map<String, String> freezeFrame; // key→value pairs from the row payload
  final DateTime? recordTime;

  const DtcRow({
    this.moduleName,
    this.code,
    this.description,
    this.state,
    this.freezeFrame = const {},
    this.recordTime,
  });

  bool get isActiveFault => state == 0;
}

/// Abstract over the two transports.
abstract class VehicleDataSource {
  DataSourceKind get kind;

  /// Currently-known VIN, or null if not connected or not yet read.
  String? get vin;

  /// Stream of connection-state changes. Sources that drop and
  /// reconnect emit transitions; subscribers should treat
  /// disconnected→connecting→connected as a normal lifecycle.
  Stream<ConnState> get state;

  ConnState get currentState;

  /// Initialise the transport. Idempotent — calling on an already-
  /// connected source is a no-op. May throw [VehicleDataException]
  /// if hardware/software isn't present (no BLE on this device, no
  /// car framework on this device).
  Future<void> connect();

  /// Release the transport. Idempotent.
  Future<void> disconnect();

  /// Synchronous(-ish) read of one property key. The meaning of the
  /// key string is source-specific:
  ///   - BLE source: `<ecuTx>/<DID>` (e.g. `7E4/0x002C`)
  ///   - Native source: `0x<HEXFEATUREID>` (e.g. `0x99002B0A`)
  /// Mixing keys across sources is undefined.
  Future<VehicleResult<Object?>> readValue(String key);

  /// Bulk read for situations where the underlying source can batch.
  /// Default implementation calls [readValue] in order.
  Future<List<VehicleResult<Object?>>> readValues(List<String> keys) async {
    final out = <VehicleResult<Object?>>[];
    for (final k in keys) {
      out.add(await readValue(k));
    }
    return out;
  }

  /// Push-based subscription. The returned [Stream] is a broadcast
  /// stream — adding/removing listeners doesn't pause the source.
  /// Closing the stream is the caller's responsibility but harmless;
  /// the underlying subscription is reference-counted by key.
  Stream<VehicleResult<Object?>> subscribe(List<String> keys);

  /// One-shot snapshot of all currently-active fault rows.
  /// Returns an empty list when there are none (which is the
  /// common case on a healthy car).
  Future<List<DtcRow>> readDtcSnapshot();
}
