/// HAL telemetry service — overlapping data source for the display layer.
///
/// v0.1.29+64 proved the pattern with SPEED (HAL=cluster, confirmed on a
/// live drive); v0.1.29+66 extends it to the full overlapping wave:
/// pack_voltage, pack_current (as derived power), gear_enum and SOC —
/// each one an invisible source swap inside the SAME widget, with
/// automatic per-name fallback to OBD2.
///
/// Owns the live HAL push-telemetry subscription (the +61/+62 stream) and
/// exposes the latest decoded values the UI cares about.
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

  // ─── Latest decoded values (v0.1.29+66 overlapping wave) ────────────
  //
  // Per-name latest sample. Two freshness classes, matching how the HAL
  // actually delivers (field rates from the 2026-06-11 drive, HAL Test):
  //
  //  * CONTINUOUS — pushed at a steady rate while the stream is up:
  //      speed ~8 Hz, pack_current ~2.2 Hz, pack_voltage ~0.8 Hz,
  //      gear_enum ~3.4 Hz. Freshness = sample age within a per-name
  //      window; a stall (binder loss) trips the fallback well before
  //      the user notices a frozen value.
  //  * EVENT-DRIVEN — pushed only when the value CHANGES: soc_display,
  //      soc_battery (0.0 Hz at steady state; SOC can sit for many
  //      minutes). An age window would falsely expire them, so they
  //      count as fresh while the stream is RUNNING and are cleared on
  //      stop.
  static const Map<String, Duration> _continuousWindow = {
    'speed': Duration(milliseconds: 1500),
    'pack_voltage': Duration(seconds: 6),
    'pack_current': Duration(seconds: 6),
    'gear_enum': Duration(seconds: 6),
    // v0.1.29+72: battery/drive temperatures. Slow signals — probe runs
    // ~0.5 Hz (n=12-15 per recon chunk), motor/inverter similar — so the
    // freshness window is generous (8 s) to avoid flicker between updates.
    'probe_highest_temp': Duration(seconds: 8),
    'motor_temp': Duration(seconds: 8),
    'inverter_temp': Duration(seconds: 8),
    // v0.1.29+74: odometer + trip meters. Monotonic, change slowly; the
    // sticky hold keeps them populated. Generous window.
    'odometer': Duration(seconds: 10),
    'trip_a': Duration(seconds: 10),
    'trip_b': Duration(seconds: 10),
    // v0.1.29+75: drive-side motor signals (BYDAutoEngineDevice). Fast,
    // live drive data — rpm/torque/power update with the powertrain, so
    // the window is tight (1.5 s) like speed; the sticky hold still keeps
    // the driver HAL split populated across brief gaps (dims via isStale).
    'motor_rpm': Duration(milliseconds: 1500),
    'motor_torque': Duration(milliseconds: 1500),
    'motor_power': Duration(milliseconds: 1500),
  };
  static const Set<String> _eventDriven = {'soc_display', 'soc_battery'};

  // Range guards per name — same role as the 0..220 speed guard from the
  // +64 pilot: drop frame-misalignment junk before it reaches a display.
  static const Map<String, (double, double)> _range = {
    'speed': (0, 220),
    'pack_voltage': (250, 500),
    'pack_current': (-600, 600),
    'gear_enum': (0, 15),
    'soc_display': (0, 100),
    'soc_battery': (0, 100),
    // v0.1.29+72: temperatures. probe_highest_temp verified as battery
    // temp (HAL 22 °C = cluster Bat 21 °C, recon p083 promotes it as
    // canonical). motor/inverter are distinct sensors (r=0.03). Guard
    // band −40..150 °C drops frame-misalignment junk (e.g. the broken
    // cell_temp_lowest 1.03e9 raw).
    'probe_highest_temp': (-40, 150),
    'motor_temp': (-40, 150),
    'inverter_temp': (-40, 150),
    // v0.1.29+74: odometer up to 1e6 km; trips up to 100k km. Lower bound
    // 0 (can't be negative). Decoder already applies ×0.1 → value in km.
    'odometer': (0, 1000000),
    'trip_a': (0, 100000),
    'trip_b': (0, 100000),
    // v0.1.29+75: motor signals. rpm 0..25000 (nameplate max ~16000, head-
    // room above); torque ±400 Nm (peak 330 Nm nameplate, signed for
    // regen); power ±250 kW (peak 208 ≈ 200 kW spec, signed for regen).
    // Guards drop frame-misalignment junk before display.
    'motor_rpm': (0, 25000),
    'motor_torque': (-400, 400),
    'motor_power': (-250, 250),
  };

  final Map<String, ({double value, DateTime at})> _latest = {};

  /// v0.1.29+73: sticky cache for the slow temperature signals. probe /
  /// motor / inverter update at ~0.5 Hz and individual frames sometimes
  /// arrive misaligned (dropped by the range guard), so the plain
  /// _latest+8s-window flickers to "—" between good frames. The temps are
  /// physically slow (battery/coolant temperature can't jump in seconds),
  /// so we keep the last in-range value for a long hold (90 s) and only
  /// fall back to OBD2/"—" if the stream is truly gone. A bad/out-of-range
  /// frame never overwrites a good one — it's simply ignored.
  static const _tempHold = Duration(seconds: 90);

  /// v0.1.29+74: the discrete-source UX (HAL vs OBD2, no Auto) needs the
  /// overlapping core (speed/V/I/SOC/power/gear + odometer) to keep
  /// reading even across brief stream gaps when the user pinned HAL —
  /// otherwise the widgets would blink. So ALL of these get the same
  /// sticky hold as temps: the last good value is retained for _coreHold,
  /// and [isStale] reports when the retained value is older than the
  /// per-name freshness window so the UI can dim it (held but ageing).
  /// This does NOT change auto-mode behaviour (still per-name OBD2
  /// fallback) — it only adds the held value + staleness signal.
  static const _coreHold = Duration(seconds: 90);
  static const _stickyNames = {
    'speed', 'pack_voltage', 'pack_current', 'gear_enum',
    'soc_display', 'soc_battery', 'odometer', 'trip_a', 'trip_b',
    'probe_highest_temp', 'motor_temp', 'inverter_temp',
    // v0.1.29+75: motor signals held across brief drive-stream gaps so
    // the driver HAL split stays populated (dims via isStale when ageing).
    'motor_rpm', 'motor_torque', 'motor_power',
  };
  final Map<String, ({double value, DateTime at})> _lastGood = {};

  /// Last good value held across short dropouts / bad frames, or null if
  /// never received or the hold expired. Used by both the temp getters
  /// and (in halOnly mode) the overlapping-core getters.
  double? _heldValue(String name, Duration hold) {
    final s = _lastGood[name];
    if (s == null) return null;
    if (!_running) return null;
    if (DateTime.now().difference(s.at) > hold) return null;
    return s.value;
  }

  /// Back-compat shim for the +73 temp getters.
  double? _tempValue(String name) => _heldValue(name, _tempHold);

  /// Latest raw value for a consumed name, or null if never received.
  double? halValue(String name) => _latest[name]?.value;

  /// Freshness per the name's class (see the field-rate table above).
  bool halFresh(String name) {
    final s = _latest[name];
    if (s == null) return false;
    if (_eventDriven.contains(name)) return _running;
    final w = _continuousWindow[name];
    if (w == null) return false;
    return DateTime.now().difference(s.at) <= w;
  }

  /// v0.1.29+74: the displayed HAL value is stale — i.e. we are showing a
  /// held value that is older than its freshness window. The widget stays
  /// populated (held), but the UI should dim it to signal "ageing". Only
  /// meaningful while a HAL value is actually on display.
  bool isStale(String name) {
    if (_mode == HalSourceMode.obd2Only) return false;
    if (_lastGood[name] == null) return false;
    return !halFresh(name);
  }

  /// Source policy gate: does the UI show HAL for this name?
  /// v0.1.29+74 (discrete sources, Approach 1):
  ///   - obd2Only : never (false).
  ///   - halOnly  : yes whenever we have a held value within _coreHold —
  ///                even if momentarily stale (UI dims via [isStale]).
  ///                This is what keeps HAL feeling like a complete
  ///                interface with no gaps.
  ///   - auto     : UNCHANGED legacy behaviour — HAL only while genuinely
  ///                fresh, else per-name OBD2 fallback. Kept as a safety
  ///                net; the UI no longer offers Auto, but persisted
  ///                'auto' prefs still resolve here harmlessly.
  bool _useHal(String name) {
    switch (_mode) {
      case HalSourceMode.obd2Only:
        return false;
      case HalSourceMode.halOnly:
        return _heldValue(name, _coreHold) != null;
      case HalSourceMode.auto:
        return halFresh(name);
    }
  }

  // ── speed (kept from the +64 pilot — same names, same semantics) ──

  /// Raw HAL speed in km/h, or null if never received.
  double? get halSpeedKmh => halValue('speed');

  /// True if a HAL speed value arrived within the freshness window.
  bool get halSpeedFresh => halFresh('speed');

  /// Whether the resolver should use HAL speed for display right now:
  /// mode permits it AND a fresh value exists.
  bool get useHalForSpeed => _useHal('speed');

  // ── pack voltage (direct measurement; OBD2 shows sum-of-cells) ──

  double? get halPackVoltage => halValue('pack_voltage');
  bool get useHalForPackV => _useHal('pack_voltage');

  // ── gear (HAL gear_enum confirmed same encoding as OBD2 791/0009:
  //    1=P 2=R 4=D live-verified 2026-06-11; both feed the same
  //    _gearStr mapping so the swap is invisible) ──

  double? get halGear => halValue('gear_enum');
  bool get useHalForGear => _useHal('gear_enum');

  // ── SOC (soc_display = instrument-cluster %, live-verified equal to
  //    the cluster AND to soc_battery at 32% on 2026-06-11; prefer the
  //    cluster value, fall back to the raw BMS one) ──

  double? get halSocPct => _useHal('soc_display')
      ? halValue('soc_display')
      : halValue('soc_battery');
  bool get useHalForSoc =>
      _useHal('soc_display') || _useHal('soc_battery');

  // ── power (derived: HAL pack_current × HAL pack_voltage). Both
  //    sources are discharge-positive (same convention as the OBD2
  //    C33 path — see the vendored decoder-table header note), so the
  //    sign semantics of instantPowerKw carry over unchanged. ──

  double? get halPowerKw {
    if (!_useHal('pack_current') || !_useHal('pack_voltage')) return null;
    final i = halValue('pack_current');
    final v = halValue('pack_voltage');
    if (i == null || v == null) return null;
    return v * i / 1000.0;
  }

  /// Flow direction mirroring ConnectionService.powerFlowDirection
  /// (1 discharge / −1 regen-or-charge / 0 near zero). Same ±3 A
  /// deadband so the UI behaves identically whichever source feeds it.
  int? get halFlowDir {
    if (!_useHal('pack_current')) return null;
    final i = halValue('pack_current');
    if (i == null) return null;
    if (i > 3.0) return 1;
    if (i < -3.0) return -1;
    return 0;
  }

  bool get useHalForPower => halPowerKw != null;

  // ── temperatures (v0.1.29+72). Battery temp = probe_highest_temp
  //    (0x47800010), verified against the instrument cluster (HAL 22 °C
  //    vs Bat 21 °C) and recon's ~0.5 Hz stream. motor_temp (0x3DB00010)
  //    and inverter_temp (0x3DB00008) are distinct drive-side sensors
  //    (r=0.03). OBD2 has battery temp only (790/002F → ConnectionService
  //    .avgTemp); motor/inverter have no OBD2 source, so their card cells
  //    show "—" when HAL is stale (honesty rule). ──

  double? get halBatteryTempC => _tempValue('probe_highest_temp');
  bool get useHalForBatteryTemp => _tempValue('probe_highest_temp') != null;

  double? get halMotorTempC => _tempValue('motor_temp');
  bool get useHalForMotorTemp => _tempValue('motor_temp') != null;

  double? get halInverterTempC => _tempValue('inverter_temp');
  bool get useHalForInverterTemp => _tempValue('inverter_temp') != null;

  // ── odometer + trip meters (v0.1.29+74). All from BYDAutoStatistic-
  //    Device, decoder applies ×0.1 so values are already in km. Held via
  //    the sticky cache (monotonic, slow). odometer is part of the cross-
  //    mode core (also readable from OBD2 791/0026); trip_a/trip_b are
  //    HAL-only cluster trip meters shown in the driver HAL split. ──

  double? get halOdometerKm => _heldValue('odometer', _coreHold);
  // 0x49502010 = STATISTIC_TOTAL_MILEAGE, decoder applies ×0.1 → km.
  // Sanity-check HAL vs OBD2 791/0026 once while parked (values must match
  // at a standstill); both should equal the cluster odometer.
  bool get useHalForOdometer => _useHal('odometer');

  double? get halTripAKm => _heldValue('trip_a', _coreHold);
  bool get useHalForTripA => _useHal('trip_a');

  double? get halTripBKm => _heldValue('trip_b', _coreHold);
  bool get useHalForTripB => _useHal('trip_b');

  // ── motor signals (v0.1.29+75). BYDAutoEngineDevice, HAL-only (no OBD2
  //    source): motor_rpm 0x28A00008 (RPM, slope 79.3 RPM per km/h vs
  //    speed r=0.968, recon-confirmed), motor_torque 0x28A00018 (Nm,
  //    signed — drive +, regen −, peak 330 Nm nameplate), motor_power
  //    0x15100020 = ENGINE_POWER (kW, signed, peak 208 ≈ 200 kW spec;
  //    confirmed power, NOT a current proxy). Shown only in the driver HAL
  //    trip-split; held via the sticky cache and dimmed by isStale. ──

  double? get halMotorRpm => _heldValue('motor_rpm', _coreHold);
  bool get useHalForMotorRpm => _useHal('motor_rpm');

  double? get halMotorTorqueNm => _heldValue('motor_torque', _coreHold);
  bool get useHalForMotorTorque => _useHal('motor_torque');

  double? get halMotorPowerKw => _heldValue('motor_power', _coreHold);
  bool get useHalForMotorPower => _useHal('motor_power');


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
    // v0.1.29+74: discrete-source migration. The UI no longer offers Auto.
    // Anyone with a persisted 'auto' (the old default) is moved to halOnly
    // — which behaves like the old auto for the common case (HAL live) but
    // holds values across gaps instead of silently swapping to OBD2. The
    // 'auto' enum value still resolves safely in _useHal as a net.
    if (_mode == HalSourceMode.auto) {
      _mode = HalSourceMode.halOnly;
      await prefs.setString('hal_source_mode', _modeToString(_mode));
    }
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
    // Stale values must not survive a stop — event-driven names (SOC)
    // count as fresh while running, so leaving them would lie after a
    // restart with the car in a different state.
    _latest.clear();
    _lastGood.clear();
  }

  void _onEvent(HalEvent e) {
    // v0.1.29+66: consume the overlapping-wave allowlist (speed,
    // pack_voltage, pack_current, gear_enum, soc_display, soc_battery).
    // v0.1.29+72: + battery/drive temps (probe_highest_temp, motor_temp,
    // inverter_temp) — promoted after probe verified vs the cluster.
    // Everything else flows but is ignored here — the HAL Test screen
    // still shows the full set, including the charging-context temp
    // CANDIDATES from CompanionDecoderOverrides, which stay out of this
    // allowlist until verified on a charge session.
    final guard = _range[e.name];
    if (guard == null) return; // not a consumed name
    final v = e.value;
    if (v == null) return;
    final d = v.toDouble();
    if (d < guard.$1 || d > guard.$2) return; // frame-misalignment junk
    _latest[e.name] = (value: d, at: DateTime.now());
    // v0.1.29+73/+74: sticky-held names (temps + overlapping core) feed
    // the _lastGood cache so the widgets hold the last good reading across
    // dropouts / bad frames (no flicker; halOnly mode shows held values).
    if (_stickyNames.contains(e.name)) {
      _lastGood[e.name] = (value: d, at: DateTime.now());
    }
    // No notifyListeners() per event — at ~15 Hz aggregate that would
    // over-rebuild. The widgets already rebuild on the OBD2
    // ConnectionService poll cadence; the resolvers read our latest
    // values at paint time. A coalesced notify keeps displays lively
    // without flooding.
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
