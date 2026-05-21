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
///
/// v0.1.26+14: head-unit detection used to require a successful VIN
/// read for `isOnHeadUnit == true`. Field test on a real BZ5 found
/// that BYDAutoBodyworkDevice exists (framework present) but its VIN
/// methods throw with no diagnostic, leaving the detector permanently
/// in `isOnHeadUnit=false` even though we WERE running on the head
/// unit. Fix: framework presence is now the truth signal. VIN is
/// reported separately for display, but doesn't gate the boolean.
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
      // The framework-present probe is the head-unit signal. On a real
      // BZ5 this returns true; on a phone the class doesn't exist and
      // it returns false. Reflection only — no CAN I/O — so it's cheap
      // and never throws here (the platform side swallows exceptions).
      final present = await ch.isNativeAvailable();
      _isOnHeadUnit = present;

      // VIN read is a separate concern. We try it for display, but its
      // failure does NOT downgrade isOnHeadUnit. Some firmware revisions
      // throw on getRealAutoVIN() even though everything else is fine —
      // see BydVinDetector for the multi-method fallback dance and the
      // diagnostic logging we now emit so the failure mode is visible.
      if (present) {
        try {
          _vin = await ch.detectVin(fresh: false);
        } catch (_) {
          _vin = null;
        }
      } else {
        _vin = null;
      }

      _detected = true;
      _lastError = null;
    } catch (e) {
      // Top-level failure of isNativeAvailable() — only happens if the
      // MethodChannel itself is broken. Falls back to BLE mode.
      _isOnHeadUnit = false;
      _vin = null;
      _detected = true;
      _lastError = e.toString();
    }
    notifyListeners();
  }
}
