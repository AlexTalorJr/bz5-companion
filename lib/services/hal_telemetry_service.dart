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
import 'native_car_channel.dart';

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

  // v0.1.29+83: platform gate. HAL only exists on the BYD head unit (the
  // BYDAutoBodyworkDevice framework class is present there and absent on a
  // phone). Probed once in init() via the same reflection NativeDetector
  // uses — no CAN I/O, .kt untouched. When false (phone), halOnly is not a
  // real option: the UI hides the HAL radio and the startup gate never
  // unblocks on it. Truth source for "can this device do HAL at all".
  bool _isHeadUnit = false;
  bool get canUseHal => _isHeadUnit;

  bool _running = false;
  bool get running => _running;

  /// v0.1.29+84: HAL is the active driving source — pinned to halOnly AND
  /// the stream is up. The driver screen's middle band (motor rpm/torque/
  /// power, motor/inverter temp via HalExtrasPanel) was previously gated on
  /// an OBD2 trip (currentTripId), so in halOnly without a BLE dongle the
  /// whole band — and all motor data — vanished even though the signals
  /// flow. This getter lets the band show on live HAL alone. The panel
  /// itself is honest per-signal (held→shown, stale→dimmed, absent→"—"),
  /// so showing it with some cells empty on a stationary car is fine.
  bool get halDriveActive => _mode == HalSourceMode.halOnly && _running;

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
    // v0.1.29+82: brake_pedal is EDGE-triggered (frame on change only) and
    // now STICKY — halBrakePedalPressed reads the held _lastGood value, not
    // halFresh, so this window is no longer the gate. Kept (used by isStale/
    // halFresh elsewhere); 3 s is harmless given the value is held sticky.
    'brake_pedal': Duration(seconds: 3),
    // v0.1.29+84: BigData-borne battery signals (recon confirmed flowing
    // via DecodedStreamSink on v0.10.68, ground-truth-matched). cell_v
    // lo/hi update with balancing — moderately fast, 6 s like pack_voltage.
    // cell_idx tracks the same frames. insulation is slow (Statistic), so a
    // generous 30 s window avoids flicker between sparse updates.
    'cell_v_lowest': Duration(seconds: 6),
    'cell_v_highest': Duration(seconds: 6),
    'cell_idx_lowest': Duration(seconds: 6),
    'cell_idx_highest': Duration(seconds: 6),
    'insulation_resistance': Duration(seconds: 30),
    // v0.1.29+86: fractional SOC from BigData 0x044C (recon p091 decode
    // record → soc_precise, DBL = u16LE[10]×0.1). Confirmed by Друг 3 to
    // arrive once per ~30 s on the CAN bus (NOT 1 Hz — frame is genuinely
    // sparse; whitelist did not raise the rate). Window set to 75 s — a
    // 2.5× cushion over the 30 s cadence so a single dropped frame does
    // not expire it (continuous-tight windows would falsely flap it).
    'soc_precise': Duration(seconds: 75),
  };
  // soc_precise is NOT event-driven — it arrives on a steady ~30 s tick,
  // so it lives in _continuousWindow above, not in _eventDriven (those are
  // the integer-SOC change-only frames). See halSocForTrip below.
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
    // v0.1.29+80: brake-pedal toggle (GEARBOX_BRAKE_PEDAL, already decoded
    // by the vendored DecoderTable and pushed via the Gearbox subscription;
    // adding it to _range is what makes the service actually CONSUME it).
    // 0 = released, 1 = pressed. Guard 0..1 drops any junk.
    'brake_pedal': (0, 1),
    // v0.1.29+84: BigData battery signals. cell_v LFP 3.10–3.44 V observed
    // (recon) → guard 2.5..4.0 drops misalignment junk. cell_idx 1..136
    // (pack is 136S) → guard 0..200. insulation arrives RAW (~13272–15919,
    // recon confirms scale ×0.001 NOT applied upstream) so the guard is in
    // RAW units: 1000..100000 (→ 1..100 MΩ after the getter scales it).
    'cell_v_lowest': (2.5, 4.0),
    'cell_v_highest': (2.5, 4.0),
    'cell_idx_lowest': (0, 200),
    'cell_idx_highest': (0, 200),
    'insulation_resistance': (1000, 100000),
    // v0.1.29+86: fractional SOC (soc_precise) is a percentage. Recon
    // already validates frame integrity upstream (length==14 AND the
    // b[10]+b[13]==325 checksum AND 0..100) and emits null on failure, so
    // anything that reaches us is in-range; this guard is the same belt-
    // and-braces 0..100 we use for the integer SOC names.
    'soc_precise': (0, 100),
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
    // v0.1.29+82: brake_pedal is EDGE-triggered — the framework pushes a
    // frame only on CHANGE (1 on press, 0 on release), nothing while the
    // pedal is held. +81 treated it as a level signal with a 3 s freshness
    // window, so the bar went dark ~3 s into a held brake (no refresh frame
    // arrived). Owner-confirmed: a 0 frame DOES arrive on release. So hold
    // the last value sticky and let the explicit 0 clear it — the bar now
    // stays lit for the whole brake and drops the instant 0 lands.
    // _stopStream() clears _lastGood, so no cross-session latch.
    'brake_pedal',
    // v0.1.29+86: soc_precise held sticky like the other core signals so a
    // brief gap between the ~30 s frames keeps the trip energy populated
    // (dims via isStale when ageing past its 75 s window).
    'soc_precise',
  };
  final Map<String, ({double value, DateTime at})> _lastGood = {};

  // ─── HAL trip tracker (v0.1.29+85, Design C) ────────────────────────
  //
  // A SECOND trip tracker that lives entirely here, mirroring the OBD2
  // ConnectionService trip math so the driver/dashboard look identical in
  // halOnly mode with no BLE dongle. The OBD2 tracker (ConnectionService)
  // is NOT touched — it keeps owning the database, history and the
  // honest single-sourced aggregates. This one is display-only:
  //
  //   distance     ← Δ HAL trip_a (cluster trip meter A)
  //   energy       ← (startSoc − nowSoc) × capacity, the SAME ΔSOC×kWh
  //                  method ConnectionService uses (batteryCapacityKwh)
  //   consumption  ← energy / distance × 100
  //   duration     ← wall clock since start
  //   peak / avg   ← accumulated from HAL speed via the ~1 s tick below
  //
  // Start: gear_enum ≠ Park (1) AND the first valid HAL SOC has arrived
  //   (latches _halTripStartSoc on that frame, so the first seconds of
  //   energy are anchored honestly to a real reading).
  // Stop / segmentation: parked (gear == P) longer than the SAME
  //   thresholds OBD2 uses (_kHalParkConfirm debounce + _kHalParkClose).
  //   On close we reset the aggregates so the next drive starts clean.
  //
  // Battery capacity duplicated here as a const (Bz5Model.batteryCapacityKwh
  // = 65.28) to avoid importing ConnectionService into this service — same
  // value, kept in sync by hand if the pack variant ever changes.
  static const double _halPackCapacityKwh = 65.28;
  static const double _halMovingKmh = 1.0; // > this counts as moving
  static const Duration _kHalParkConfirm = Duration(seconds: 30);
  static const Duration _kHalParkClose = Duration(minutes: 10);

  bool _halTripActive = false;
  DateTime? _halTripStartedAt;
  double? _halTripStartSoc;     // latched start SOC (whole %, smoothed via EMA)
  double? _halTripStartTripA;   // latched start odo-trip (km) from trip_a
  double? _halPeakSpeedKmh;
  double _halSpeedSum = 0;      // moving-sample speed sum (for avg)
  int _halSpeedSamples = 0;     // moving-sample count
  // EMA-smoothed energy so a whole-% SOC step (~0.65 kWh on this pack)
  // doesn't make the energy cell jump. v0.1.29+85 uses whole SOC only;
  // the fractional BigData SOC (0x044C) is a later step once recon p090
  // adds it to the frame_trace whitelist (~1 Hz). The EMA hides the steps
  // in the meantime.
  double? _halEnergyEma;
  static const double _halEnergyEmaAlpha = 0.15;
  // Park-segmentation debounce/clock, same shape as the OBD2 tracker.
  DateTime? _halParkConfirmStart;
  DateTime? _halParkedSince;
  // ~1 s tick that samples HAL speed into peak/avg while a trip is live.
  // Lives with the stream — started on first trip start, cancelled in
  // _stopStream() so a stopped stream never keeps accumulating.
  Timer? _halTripTick;

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

  // ── BigData battery signals (v0.1.29+84). Recon confirmed these flow via
  //    DecodedStreamSink on v0.10.68 and ground-truth-matched them, so no
  //    recon patch is needed — only the allowlist + these getters. Used to
  //    fill the halOnly dashboard cells that were OBD2-only (cell spread,
  //    insulation), via invisible source substitution like speed/SOC.
  //
  //    cell_v_lowest 0x45400010 / cell_v_highest 0x45400030 (DBL, V,
  //    BYDAutoEnergyDevice) — the pair gives cell spread = max − min without
  //    the 136-cell UDS poll. cell_idx_* 0x45400008/0x45400028 (INT, 1..136)
  //    name which cell. insulation_resistance 0x47300018 (Statistic) arrives
  //    RAW (~13272) — scale ×0.001 → MΩ is applied HERE (recon does not
  //    apply it upstream). ──

  double? get halCellVLowest => _heldValue('cell_v_lowest', _coreHold);
  double? get halCellVHighest => _heldValue('cell_v_highest', _coreHold);

  /// Cell spread in mV from the HAL min/max pair, or null if either is
  /// absent. (max − min) V × 1000 → mV, matching the OBD2 cell-spread unit.
  double? get halCellSpreadMv {
    final lo = halCellVLowest;
    final hi = halCellVHighest;
    if (lo == null || hi == null) return null;
    final mv = (hi - lo) * 1000.0;
    return mv < 0 ? 0 : mv;
  }

  bool get useHalForCellSpread =>
      _useHal('cell_v_lowest') && _useHal('cell_v_highest');

  double? get halCellIdxLowest => _heldValue('cell_idx_lowest', _coreHold);
  double? get halCellIdxHighest => _heldValue('cell_idx_highest', _coreHold);

  /// Insulation resistance in MΩ. Raw value is scaled ×0.001 here (recon
  /// emits it unscaled, e.g. 13272 → 13.27 MΩ).
  double? get halInsulationMOhm {
    final raw = _heldValue('insulation_resistance', _coreHold);
    return raw == null ? null : raw * 0.001;
  }

  bool get useHalForInsulation => _useHal('insulation_resistance');

  // ── brake-light indicator (v0.1.29+78, reworked +80). The real stop-lamp
  //    state (LIGHT_CMD_STOP_LIGHT_STATE 0x33100012) is UNREACHABLE for our
  //    uid: recon p086/p087 closed it for good (class_not_found on the HAL
  //    class, BYDAUTO_LIGHT COMMON+GET both granted=false, all three light
  //    binders null; the Bodywork 0x06200020 alternative is dead too since
  //    p078). So this bar is DERIVED, not the lamp wire — flagged as such.
  //
  //    Two independent triggers, OR'd (v0.1.29+80):
  //
  //    (A) brake_pedal == 1 — UNCONDITIONAL. Foot physically on the brake is
  //        a 100%-reliable "the car is braking", so we light the bar without
  //        qualification. GEARBOX_BRAKE_PEDAL is granted and pushed with the
  //        Gearbox wave (it shows live on HAL Test). This covers ordinary
  //        friction braking that the regen pair might miss.
  //
  //    (B) regen pair — motor_torque < −50 Nm AND pack_current < −60 A
  //        (discharge-positive, so regen is negative). This is the case the
  //        pedal signal CANNOT cover: hard one-pedal regen with the foot OFF
  //        the brake. BOTH are required inside this branch — torque alone
  //        twitches at the −48/−56 Nm coast/regen boundary; pairing it with a
  //        clear charge current removes those false positives (run data
  //        2026-06-21: −97/−134, −117/−124, −56/−83 Nm/A — both well past
  //        the thresholds together).
  //
  //    +80 freshness fix — the root cause of the bar never lighting on the
  //    drive: the old code read halValue() = the RAW _latest with NO age
  //    check, so it would test a stale coast-frame (e.g. −10 Nm captured
  //    ~400 ms before regen built up) and, with torque/current arriving at
  //    different rates (~1.5 s vs ~2.2 Hz windows), the two raw latests
  //    rarely sat inside the regen window together on a short (1–2 s) brake.
  //    We now gate every input through halFresh(name) (per-name age window)
  //    so only a genuinely-current frame counts; a signal that has gone
  //    stale no longer "hangs" at its last value. HAL-only by nature: in
  //    OBD2-only mode none of these are present, so the bar never fires. ──
  static const double _brakeTorqueNm = -50;
  // v0.1.29+82: loosened −60 → −45 A. recon run 09:56 (HAL↔OBD2 journal)
  // logged the weakest real regen episode at −48 Nm / −64 A and a faint
  // coast at the −50/−64 boundary; with torque pinned at −50 the AND gate
  // could miss soft one-pedal regen on "D". −45 A widens the current side
  // while keeping both-required, so coast noise (small −I, near-zero torque)
  // still can't trip it.
  static const double _brakeCurrentA = -45;

  /// True if the brake pedal is currently reported pressed, per the LAST
  /// known HAL frame (GEARBOX_BRAKE_PEDAL, 0/1).
  ///
  /// v0.1.29+82: brake_pedal is EDGE-triggered — a frame arrives only on
  /// change (1 press / 0 release), nothing while held. +81 gated on
  /// halFresh() with a 3 s window, so a held brake went dark ~3 s in (no
  /// refresh frame). Now brake_pedal is sticky (_lastGood holds the last
  /// value), and we read that held value: it stays "pressed" for the whole
  /// brake and clears the instant the explicit 0 release-frame lands.
  /// _heldValue gates on _running and a generous hold, so a stopped stream
  /// (which also clears _lastGood) won't latch the bar between sessions.
  bool get halBrakePedalPressed {
    if (_mode == HalSourceMode.obd2Only) return false;
    final p = _heldValue('brake_pedal', _coreHold);
    return p != null && p >= 0.5;
  }

  bool get brakeRegenActive {
    // (A) foot on the brake — unconditional, last-known sticky value
    // (held through the press; clears on the explicit 0 release-frame).
    if (halBrakePedalPressed) return true;
    // (B) hard one-pedal regen with foot off the brake. Both signals must
    // be fresh (age-guarded) AND past their thresholds — no stale latest.
    final torqueOk = _useHal('motor_torque') && halFresh('motor_torque');
    final currentOk = _useHal('pack_current') && halFresh('pack_current');
    if (!torqueOk || !currentOk) return false;
    final t = halValue('motor_torque');
    final i = halValue('pack_current');
    if (t == null || i == null) return false;
    return t < _brakeTorqueNm && i < _brakeCurrentA;
  }

  // ─── HAL trip tracker logic (v0.1.29+85) ────────────────────────────
  //
  // Driven once per HAL frame from _onEvent (cheap — just reads held
  // values) plus the ~1 s tick for speed accumulation. Mirrors the OBD2
  // ConnectionService trip lifecycle; see the field block above.

  /// SOC (%) for the trip energy calc, halOnly. Priority:
  ///   1. soc_precise — fractional, ~30 s cadence (recon p091, 0x044C).
  ///      Preferred: finer resolution AND 10× more frequent than (2).
  ///   2. soc_display / soc_battery — integer, ~5 min cadence (0x2D300030).
  ///      Fallback used until soc_precise is flowing (pre-p091) or if it
  ///      drops out.
  ///
  /// soc_precise is read through its 75 s held window (a dropped 30 s frame
  /// still counts). The INTEGER SOC is read via halValue (latest, no
  /// expiry) on purpose: it arrives only ~every 5 min, so any age-based
  /// window would null it out between frames (exactly the +85 start bug).
  /// The value is monotonic battery state — the latest reading is always
  /// the current truth, so holding it indefinitely while the stream is up
  /// is correct. Cleared on _stopStream like everything else.
  double? get halSocForTrip {
    final p = _heldValue('soc_precise', _socPreciseHold);
    if (p != null) return p;
    if (!_running) return null;
    final d = halValue('soc_display');
    if (d != null) return d;
    return halValue('soc_battery');
  }

  static const _socPreciseHold = Duration(seconds: 75);

  /// Run the start/stop state machine. Called from _onEvent after a frame
  /// is consumed; no-ops when HAL is not the live driving source.
  void _updateHalTrip() {
    // Only meaningful as a display tracker when HAL is the pinned, live
    // source (halOnly + stream up). In obd2Only / phone this stays idle
    // and the UI keeps reading the OBD2 tracker.
    if (!halDriveActive) {
      if (_halTripActive) _closeHalTrip();
      return;
    }
    final gear = _heldValue('gear_enum', _coreHold);
    final soc = halSocForTrip;
    final inPark = gear != null && gear.round() == 1; // 1 = Park

    if (!_halTripActive) {
      // v0.1.29+86: start on gear ≠ Park ALONE — do NOT wait for SOC.
      // The integer SOC can take up to ~5 min to arrive and soc_precise up
      // to ~30 s; gating the whole trip section on it left the driver with
      // no trip panel for minutes after pulling away (the bug Alex saw with
      // no dongle). Distance/duration/speed all come from continuously-
      // flowing signals, so the section is useful immediately. The start
      // SOC is latched LATER, on the first valid frame (see below), and
      // until then the energy cell shows "—" honestly.
      if (gear != null && !inPark) {
        _startHalTrip();
      }
      return;
    }

    // Late-latch the start SOC: the trip began without one, so capture the
    // first valid SOC that arrives as the energy baseline. Energy reads "—"
    // until this fires, then counts from here.
    if (_halTripStartSoc == null && soc != null) {
      _halTripStartSoc = soc;
    }
    // trip_a may also have been null at start — latch it once it arrives so
    // distance reads from zero (handled in halTripDistanceKm).

    // Active trip — handle park-based segmentation (same thresholds as
    // the OBD2 tracker: debounce P, then close after the park window).
    if (!inPark) {
      _halParkConfirmStart = null;
      _halParkedSince = null;
      return;
    }
    final now = DateTime.now();
    _halParkConfirmStart ??= now;
    if (now.difference(_halParkConfirmStart!) < _kHalParkConfirm) return;
    _halParkedSince ??= now;
    if (now.difference(_halParkedSince!) >= _kHalParkClose) {
      _closeHalTrip();
    }
  }

  void _startHalTrip() {
    _resetHalTripAggregates();
    _halTripActive = true;
    _halTripStartedAt = DateTime.now();
    _halTripStartSoc = null;      // latched later, on first valid SOC frame
    _halTripStartTripA = _heldValue('trip_a', _coreHold); // may be null early
    // Kick the speed tick if it isn't already running.
    _halTripTick ??= Timer.periodic(
        const Duration(seconds: 1), (_) => _onHalTripTick());
  }

  void _closeHalTrip() {
    _halTripActive = false;
    _halTripStartedAt = null;
    _halTripStartSoc = null;
    _halTripStartTripA = null;
    _halParkConfirmStart = null;
    _halParkedSince = null;
    _resetHalTripAggregates();
    _halTripTick?.cancel();
    _halTripTick = null;
  }

  void _resetHalTripAggregates() {
    _halPeakSpeedKmh = null;
    _halSpeedSum = 0;
    _halSpeedSamples = 0;
    _halEnergyEma = null;
  }

  /// ~1 s tick: sample HAL speed into peak + moving-average accumulators
  /// while a trip is live. Mirrors the OBD2 moving>1.0 km/h gate.
  void _onHalTripTick() {
    if (!_halTripActive) return;
    final s = _heldValue('speed', _coreHold);
    if (s == null) return;
    if (_halPeakSpeedKmh == null || s > _halPeakSpeedKmh!) {
      _halPeakSpeedKmh = s;
    }
    if (s > _halMovingKmh) {
      _halSpeedSum += s;
      _halSpeedSamples++;
    }
  }

  // ── HAL trip getters: SAME names as the OBD2 ConnectionService getters,
  //    so TripMetricsPanel can swap source invisibly (like speed/SOC). ──

  /// True while the HAL trip tracker holds a live trip. The UI pairs this
  /// with halDriveActive to decide whether to read HAL or OBD2 trip data.
  bool get halTripActive => _halTripActive;

  /// Synthetic trip flag for the panel's "trip exists?" checks. v0.1.29+85
  /// writes no DB row in halOnly (history comes in the next patch), so
  /// there is no real id — the panel shows the label "trip" without a
  /// number. Non-null while a HAL trip is live so the null-guards pass.
  Object? get halCurrentTripMarker => _halTripActive ? 'trip' : null;

  /// Distance so far = Δ trip_a (cluster trip meter A). Null until both a
  /// start anchor and a current reading exist and the delta is sane.
  double? get halTripDistanceKm {
    if (!_halTripActive) return null;
    final start = _halTripStartTripA;
    final cur = _heldValue('trip_a', _coreHold);
    // trip_a can be null at the very start (frame not yet seen). Once it
    // arrives, latch it as the start so distance reads from zero.
    if (start == null) {
      if (cur != null) _halTripStartTripA = cur;
      return cur != null ? 0.0 : null;
    }
    if (cur == null || cur < start) return null;
    return cur - start;
  }

  /// Energy used so far (kWh) = (startSoc − nowSoc) × capacity, the SAME
  /// ΔSOC×kWh method as ConnectionService.tripEnergyUsedPreciseKwh. EMA-
  /// smoothed so a coarse SOC step doesn't make the value jump.
  ///
  /// v0.1.29+86: the start SOC is latched late (on the first valid frame
  /// after pull-away), so until then _halTripStartSoc is null and this
  /// returns null → the cell shows "—" honestly rather than a fake 0.
  double? get halTripEnergyUsedKwh {
    if (!_halTripActive) return null;
    final start = _halTripStartSoc;
    if (start == null) return null; // start SOC not captured yet → "—"
    final now = halSocForTrip;
    if (now == null || now >= start) {
      return _halEnergyEma; // hold last smoothed value through transient
    }
    final raw = (start - now) * _halPackCapacityKwh / 100.0;
    _halEnergyEma = _halEnergyEma == null
        ? raw
        : _halEnergyEma! + _halEnergyEmaAlpha * (raw - _halEnergyEma!);
    return _halEnergyEma;
  }

  /// Consumption so far (kWh/100km) = energy / distance × 100. Null below
  /// 0.1 km to match the OBD2 getter's guard.
  double? get halTripAvgConsumptionKwh100km {
    final dist = halTripDistanceKm;
    final energy = halTripEnergyUsedKwh;
    if (dist == null || energy == null || dist < 0.1) return null;
    return (energy / dist) * 100.0;
  }

  /// Duration so far. Null if no trip.
  Duration? get halTripDuration {
    if (!_halTripActive || _halTripStartedAt == null) return null;
    return DateTime.now().difference(_halTripStartedAt!);
  }

  /// Peak speed seen this trip (km/h). Null until the first sample.
  double? get halTripPeakSpeedKmh => _halPeakSpeedKmh;

  /// Live moving-average speed (km/h), moving samples only. Null until the
  /// trip has at least one moving sample.
  double? get halTripCurrentAvgMovingKmh {
    if (!_halTripActive || _halSpeedSamples == 0) return null;
    return _halSpeedSum / _halSpeedSamples;
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
    // v0.1.29+74: discrete-source migration. The UI no longer offers Auto.
    // Anyone with a persisted 'auto' (the old default) is moved to halOnly
    // — which behaves like the old auto for the common case (HAL live) but
    // holds values across gaps instead of silently swapping to OBD2. The
    // 'auto' enum value still resolves safely in _useHal as a net.
    if (_mode == HalSourceMode.auto) {
      _mode = HalSourceMode.halOnly;
      await prefs.setString('hal_source_mode', _modeToString(_mode));
    }
    // v0.1.29+83: platform probe. isNativeAvailable() is a cheap reflection
    // check (Class.forName on the BYD framework) — true on the head unit,
    // false on a phone. Never throws (platform side swallows). On a phone
    // HAL is physically impossible, so force obd2Only: this keeps a stray
    // persisted 'halOnly' from stranding the user on a dead screen, and the
    // Settings UI drops the HAL radio when !canUseHal.
    try {
      _isHeadUnit = await NativeCarChannel.instance.isNativeAvailable();
    } catch (_) {
      _isHeadUnit = false;
    }
    if (!_isHeadUnit && _mode == HalSourceMode.halOnly) {
      _mode = HalSourceMode.obd2Only;
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
    // v0.1.29+85: a stopped stream must not keep a HAL trip "open" or let
    // the 1 s tick accumulate against a dead stream. Close it cleanly.
    _closeHalTrip();
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
    // v0.1.29+85/+86: drive the HAL trip state machine off the same frames
    // (cheap — it only reads held values). Start fires on gear≠Park alone;
    // the start SOC latches later on the first soc_precise/integer frame.
    _updateHalTrip();
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
    _halTripTick?.cancel();
    _stopStream();
    super.dispose();
  }
}
