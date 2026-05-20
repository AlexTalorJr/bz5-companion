/// Auto-detection helper for "are we running on the car's head unit?".
///
/// Lives separately from [NativeCarChannel] because the rest of the
/// app needs to decide channel before any actual data flows. The
/// detection is a single reflection probe + an optional VIN read; we
/// cache the answer for the process lifetime.
///
/// Usage:
///   final detector = NativeDetector();
///   await detector.detect();
///   if (detector.isOnHeadUnit) {
///     // use NativeCarDataSource
///   } else {
///     // use BleObdDataSource (existing ConnectionService)
///   }
///
/// The probe is cheap (single Class.forName on the platform side) so
/// re-running it on each app cold start is fine. Hot-restart preserves
/// the cache via the platform side's memoization.
library;

import 'dart:async';
import 'package:flutter/foundation.dart';

import 'native_car_channel.dart';

class NativeDetector extends ChangeNotifier {
  bool _detected = false;
  bool _isOnHeadUnit = false;
  String? _vin;
  String? _lastError;

  bool get detected => _detected;
  bool get isOnHeadUnit => _isOnHeadUnit;
  String? get vin => _vin;
  String? get lastError => _lastError;

  /// Run the probe. Safe to call multiple times — subsequent calls are
  /// no-ops unless [force] is true.
  Future<void> detect({bool force = false}) async {
    if (_detected && !force) return;
    final ch = NativeCarChannel.instance;
    try {
      // Cheap probe first — no I/O on the CAN bus.
      final present = await ch.isNativeAvailable();
      if (!present) {
        _isOnHeadUnit = false;
        _vin = null;
        _detected = true;
        _lastError = null;
        notifyListeners();
        return;
      }

      // VIN read is the authoritative confirmation. A class can exist
      // but return null/empty if we're on an emulator with stubs, so
      // we treat "framework present + valid VIN" as the real signal.
      final vin = await ch.detectVin(fresh: false);
      _isOnHeadUnit = vin != null && vin.length == 17;
      _vin = vin;
      _detected = true;
      _lastError = null;
    } catch (e) {
      _isOnHeadUnit = false;
      _vin = null;
      _detected = true;
      _lastError = e.toString();
    }
    notifyListeners();
  }
}
