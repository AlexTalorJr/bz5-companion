/// HAL telemetry service (v0.1.29+64) — SPEED overlapping pilot.
///
/// Owns the live HAL push-telemetry subscription (the +61/+62 stream) and
/// exposes the latest decoded values the UI cares about. For the pilot
/// that's just SPEED; the same pattern extends to packV / current / SOC /
/// gear / temps once speed is proven.
///
/// Source policy (persisted in prefs 'hal_source_mode'):
///   - auto      : prefer HAL when its stream is live and fresh, else OBD2
///   - halOnly   : force HAL (display shows nothing if HAL is stale/down)
///   - obd2Only  : never use HAL for display (stream may still run for the
///                 HAL Test screen, but the resolver ignores it)
///
/// IMPORTANT — honesty of the data layer: this service feeds the DISPLAYED
/// speedometer only. Trip aggregates / livelog continue to read the OBD2
/// ConnectionService.vehicleSpeedKmh untouched, so the recorded data stays
/// single-sourced and honest during the pilot. Promoting HAL into the
/// aggregate path is a later, deliberate step.
library;

import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'hal_telemetry_channel.dart';

enum HalSourceMode { auto, halOnly, obd2Only }

HalSourceMode _modeFromString(String? s) {
  switch (s) {
    case 'halOnly':
      return HalSourceMode.halOnly;
    case 'obd2Only':
      return HalSourceMode.obd2Only;
    default:
      return HalSourceMode.auto;
  }
}

String _modeToString(HalSourceMode m) {
  switch (m) {
    case HalSourceMode.halOnly:
      return 'halOnly';
    case HalSourceMode.obd2Only:
      return 'obd2Only';
    case HalSourceMode.auto:
      return 'auto';
  }
}

class HalTelemetryService extends ChangeNotifier {
  final _hal = HalTelemetryChannel.instance;
  StreamSubscription<HalEvent>? _sub;

  HalSourceMode _mode = HalSourceMode.auto;
  HalSourceMode get mode => _mode;

  bool _running = false;
  bool get running => _running;

  HalStartStatus? _status;
  HalStartStatus? get status => _status;

  // Latest SPEED (km/h, raw — no speedometer-match multiplier) + when it
  // arrived. Freshness is judged against [_freshnessWindow].
  double? _speedKmh;
  DateTime? _speedAt;

  // How long a HAL value stays "fresh" before the resolver falls back to
  // OBD2. Speed streams at ~8 Hz, so 1.5 s is generous — a real stall
  // (BLE/binder loss) trips it well before the user notices a frozen gauge.
  static const _freshnessWindow = Duration(milliseconds: 1500);

  /// Raw HAL speed in km/h, or null if never received.
  double? get halSpeedKmh => _speedKmh;

  /// True if a HAL speed value arrived within the freshness window.
  bool get halSpeedFresh {
    final at = _speedAt;
    if (at == null || _speedKmh == null) return false;
    return DateTime.now().difference(at) <= _freshnessWindow;
  }

  /// Whether the resolver should use HAL speed for display right now:
  /// mode permits it AND a fresh value exists.
  bool get useHalForSpeed {
    if (_mode == HalSourceMode.obd2Only) return false;
    return halSpeedFresh;
  }

  /// Raw event stream (all decoders), for the dev HAL Test screen. The
  /// service is the SINGLE owner of the native subscription; HAL Test
  /// observes through here and brackets the screen with retain/release so
  /// it never stops a stream the speedometer is relying on.
  Stream<HalEvent> get rawEvents => _hal.events;

  // Diagnostic retainers (HAL Test). The stream stays up while the source
  // mode wants it OR at least one diagnostic retainer is active.
  int _retain = 0;

  /// Ensure the stream is running for a diagnostic consumer (HAL Test).
  Future<void> retainStream() async {
    _retain++;
    if (!_running) {
      await _startStream();
      notifyListeners();
    }
  }

  /// Release a diagnostic retainer. Stops the stream only if nothing else
  /// wants it — i.e. the source mode is obd2Only AND no retainers remain.
  Future<void> releaseStream() async {
    if (_retain > 0) _retain--;
    if (_retain == 0 && _mode == HalSourceMode.obd2Only) {
      await _stopStream();
      notifyListeners();
    }
  }

  Future<void> init() async {
    final prefs = await SharedPreferences.getInstance();
    _mode = _modeFromString(prefs.getString('hal_source_mode'));
    // Start the stream unless the user pinned OBD2-only. On a phone the
    // platform returns null and we simply stay on OBD2 — no harm.
    if (_mode != HalSourceMode.obd2Only) {
      await _startStream();
    }
    notifyListeners();
  }

  Future<void> setMode(HalSourceMode m) async {
    if (m == _mode) return;
    _mode = m;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('hal_source_mode', _modeToString(m));

    if (m == HalSourceMode.obd2Only) {
      // Keep the stream alive if HAL Test is currently retaining it.
      if (_retain == 0) await _stopStream();
    } else if (!_running) {
      await _startStream();
    }
    notifyListeners();
  }

  Future<void> _startStream() async {
    if (_running) return;
    // Listen FIRST (platform rejects start with HAL_NO_SINK otherwise).
    _sub = _hal.events.listen(_onEvent, onError: (Object _) {});
    final status = await _hal.start();
    _status = status;
    if (status == null) {
      // HAL unavailable (phone, or stream failed) — drop the listener and
      // stay on OBD2. Not an error from the user's perspective.
      await _sub?.cancel();
      _sub = null;
      _running = false;
    } else {
      _running = true;
    }
  }

  Future<void> _stopStream() async {
    await _hal.stop();
    await _sub?.cancel();
    _sub = null;
    _running = false;
    _speedKmh = null;
    _speedAt = null;
  }

  void _onEvent(HalEvent e) {
    // Pilot: only SPEED is consumed for display. Everything else flows but
    // is ignored here (the HAL Test screen shows the full set).
    if (e.name != 'speed') return;
    final v = e.value;
    if (v == null) return;
    final d = v.toDouble();
    // Same range guard the OBD2 path uses, to drop frame-misalignment junk.
    if (d < 0 || d > 220) return;
    _speedKmh = d;
    _speedAt = DateTime.now();
    // No notifyListeners() per event — at ~8 Hz that would over-rebuild.
    // The Driver gauge already rebuilds on the OBD2 ConnectionService
    // poll cadence (it watches that service); the resolver reads our
    // latest value at paint time. A coalesced notify keeps the gauge
    // lively without flooding.
    _scheduleNotify();
  }

  Timer? _notifyTimer;
  void _scheduleNotify() {
    _notifyTimer ??= Timer(const Duration(milliseconds: 200), () {
      _notifyTimer = null;
      notifyListeners();
    });
  }

  @override
  void dispose() {
    _notifyTimer?.cancel();
    _stopStream();
    super.dispose();
  }
}
