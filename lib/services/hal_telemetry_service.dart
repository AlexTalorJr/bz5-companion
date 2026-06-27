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

import '../data/database.dart';
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

  // v0.1.29+87: optional diagnostic sink. When [_diagDb] is set, the HAL
  // stream is throttle-logged to the hal_samples table so an export can
  // show what HAL/BigData actually delivered (closing the blind spot where
  // HAL lived only in memory). Null in tests / if not wired — logging is
  // then simply skipped. [_currentTripId] lets rows be tagged with the
  // active OBD2 trip when one exists, without importing ConnectionService.
  final AppDatabase? _diagDb;
  final int? Function()? _currentTripId;

  HalTelemetryService({AppDatabase? diagDb, int? Function()? currentTripId})
      : _diagDb = diagDb,
        _currentTripId = currentTripId;

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
    // v0.1.29+90: BigData BMS signals. soh (0x02D3 b[10]) arrives ~1 Hz —
    // a short 10 s window is enough. battery_temp_bigdata (0x044C b[7])
    // shares 0x044C's ~30 s cadence → 75 s window like soc_precise.
    'soh': Duration(seconds: 10),
    'battery_temp_bigdata': Duration(seconds: 75),
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
    // v0.1.29+90: SOH percent (0x02D3 b[10], =97 confirmed). battery_temp
    // from BigData (0x044C b[7], °C = raw−40) shares the temp guard band.
    'soh': (0, 100),
    'battery_temp_bigdata': (-40, 150),
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
    // v0.1.29+90: SOH + BigData battery temp held sticky across frame gaps
    // (soh ~1 Hz, battery_temp_bigdata ~30 s) so the dashboard cells don't
    // flicker to "—" between frames.
    'soh',
    'battery_temp_bigdata',
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
  // v0.1.29+91: DB-backed HAL trip. _halTripDbId holds the Trips row id
  // opened on start (db.startTrip), written on close (db.endTrip) — the
  // SAME contract the OBD2 tracker uses, so halOnly drives populate history
  // and feed the cumulative-energy total. connection.dart is NOT touched:
  // this write path lives entirely here (honesty AA2: connection.dart stays
  // HAL-free). The write is best-effort/async; a DB failure never disturbs
  // the live tracker or the stream. Null when no DB or no live HAL trip.
  int? _halTripDbId;
  double? _halTripStartOdo;     // latched start odometer (km) for the row
  // Lightweight min/max accumulators so the persisted row is as complete as
  // the OBD2 one (these mirror ConnectionService's _tripMin*/_tripMax*).
  // Updated on each frame in _accumulateHalTripStats; reset on start/close.
  double? _halTripMinTempC;
  double? _halTripMaxTempC;
  double? _halTripMaxCellSpreadMv;
  double? _halTripMinSoc;
  double? _halTripMaxSoc;
  double? _halTripPeakPowerKw;  // most-positive power (discharge)
  double? _halTripPeakRegenKw;  // most-negative power (regen), stored signed
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

  // v0.1.29+91: cached lifetime cumulative drive energy (kWh) = SUM over all
  // Trips rows. Read synchronously by the dashboard cell at paint; refreshed
  // async from the DB on init and whenever a HAL trip closes. Null until the
  // first refresh completes (cell shows "—"). This is "energy spent driving"
  // (sum of per-trip ΔSOC consumption), not a net battery balance.
  double? _totalDriveEnergyKwh;
  double? get totalDriveEnergyKwh => _totalDriveEnergyKwh;

  /// Refresh the cached cumulative drive energy from the DB (best-effort).
  /// Cheap single-row SUM; notifies listeners on change so the cell repaints.
  Future<void> refreshTotalDriveEnergy() async {
    final db = _diagDb;
    if (db == null) return;
    try {
      final v = await db.totalDriveEnergyKwh();
      if (v != _totalDriveEnergyKwh) {
        _totalDriveEnergyKwh = v;
        notifyListeners();
      }
    } catch (_) {
      // best-effort — cell stays on its last value / "—"
    }
  }

  /// v0.1.29+92: sweep HAL trips left open by a previous run and resolve each
  /// one. Runs once at init() on the head unit, BEFORE this session opens any
  /// new trip, so `_halTripDbId` is still null and every open row is a true
  /// orphan (never the live drive). Two outcomes per row, matching the agreed
  /// policy:
  ///
  ///   • empty pup (no distance AND no HAL samples) → DELETE. A power-off that
  ///     happened seconds after pulling away leaves a row with nothing in it;
  ///     keeping it would show "Nh — — —" in history and add nothing to the
  ///     cumulative-energy SUM. Drop it.
  ///   • real drive (has samples) → CLOSE at its last HAL-sample timestamp
  ///     (variant A: the real end-of-drive instant), leaving aggregates as
  ///     they are. We do NOT fabricate distance/energy from raw hal_samples
  ///     here — those rows are diagnostic signal/CAN dumps, not the OBD2
  ///     sample series forceCloseTrip recovers from, and inventing aggregates
  ///     would violate the honesty rule. The row simply stops being ACTIVE
  ///     and shows what it legitimately captured (often just duration).
  ///
  /// Idempotent: a second run finds nothing open. Best-effort throughout —
  /// any failure is logged and swallowed so startup never blocks on the DB.
  Future<void> _recoverOrphanHalTrips() async {
    final db = _diagDb;
    if (db == null) return;
    try {
      final open = await db.getOpenTrips();
      for (final t in open) {
        // Never touch the live drive (null this early, but guard anyway).
        if (_halTripDbId != null && t.id == _halTripDbId) continue;
        final samples = await db.countHalSamplesForTrip(t.id);
        final isEmptyPup = t.distanceKm == null && samples == 0;
        if (isEmptyPup) {
          await db.deleteTrip(t.id);
          debugPrint('HAL recovery: deleted empty orphan Trip #${t.id} '
              '(started ${t.startedAt})');
          continue;
        }
        final endTs = await db.lastHalSampleTimeForTrip(t.id) ??
            t.startedAt.add(const Duration(seconds: 1));
        await db.closeHalOrphanAt(t.id, endTs, note: 'auto-closed: orphaned');
        debugPrint('HAL recovery: closed orphan Trip #${t.id} '
            '(started ${t.startedAt}) → endedAt=$endTs');
      }
    } catch (e) {
      debugPrint('HAL orphan recovery failed (non-fatal): $e');
    }
  }

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

  /// v0.1.29+96: STICKY gear for the trip state machine.
  ///
  /// gear_enum is purely event-driven on this car — the platform pushes a
  /// frame only when the driver actually moves the selector. On a normal
  /// drive that means one frame leaving Park, then nothing for the whole
  /// trip (export 2026-06-27 showed gaps of 348 s / 1014 s / 1497 s between
  /// gear frames). The display getters gate on _coreHold (90 s), which is
  /// correct for a speedo cell but WRONG for the trip machine: after 90 s the
  /// held gear expired to null, so _updateHalTrip saw neither "in Park" nor
  /// "moving", the park-close timer kept resetting, and the trip panel
  /// flickered / vanished (the bug Alex saw — trip screen disappearing).
  ///
  /// The fix: the selector position is genuinely sticky. Once HAL reports
  /// Drive, the car IS in Drive until a NEW frame says otherwise — there is
  /// no "staleness" to a gear lever. So the trip machine reads the last good
  /// gear with no time window (only the _running guard, so a stopped stream
  /// still resets it). Park is always an explicit frame, never an expiry.
  double? get _stickyGear {
    if (!_running) return null;
    return _lastGood['gear_enum']?.value;
  }

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

  // ── SOC. v0.1.29+90: PREFER the fractional soc_precise (BigData 0x044C,
  //    u16LE[10]×0.1, ~30 s cadence) so the displayed % carries the tenth
  //    (53.2, not 53) — Alex's standing rule: fractional SOC everywhere.
  //    Falls back to the integer cluster value (soc_display, live-verified
  //    = cluster) then soc_battery only when soc_precise hasn't arrived yet.
  //    soc_precise is held ~75 s so it spans its own gaps. (Trip energy uses
  //    halSocForTrip, which has the same precise-first preference.)
  double? get halSocPct {
    final p = _heldValue('soc_precise', _socPreciseHold);
    if (p != null) return p;
    if (_useHal('soc_display')) return halValue('soc_display');
    return halValue('soc_battery');
  }
  bool get useHalForSoc =>
      _heldValue('soc_precise', _socPreciseHold) != null ||
      _useHal('soc_display') ||
      _useHal('soc_battery');

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

  // Battery temp: confirmed probe 0x47800010 (exact = cluster) FIRST; it is
  // event-driven and sleeps at standstill, so when it's silent fall back to
  // the BigData candidate 0x044C b[7] (°C = raw−40, matched OBD2 002F at 98%
  // over a narrow range — held ~30 s). v0.1.29+90: the fallback keeps the
  // cell populated in halOnly when the probe hasn't fired (the dash Alex
  // saw). Probe still wins whenever present, so accuracy is unchanged when
  // it's awake; the candidate only fills the gaps.
  double? get halBatteryTempC {
    final probe = _tempValue('probe_highest_temp');
    if (probe != null) return probe;
    return _heldValue('battery_temp_bigdata', _socPreciseHold);
  }
  bool get useHalForBatteryTemp => halBatteryTempC != null;

  double? get halMotorTempC => _tempValue('motor_temp');
  bool get useHalForMotorTemp => _tempValue('motor_temp') != null;

  double? get halInverterTempC => _tempValue('inverter_temp');
  bool get useHalForInverterTemp => _tempValue('inverter_temp') != null;

  // ── SOH (v0.1.29+90). state-of-health % from the BigData BMS frame
  //    0x02D3 b[10] (direct read, =97 matched OBD2 790/0029, ~1 Hz). This
  //    is the ONLY HAL source of SOH — without it halOnly shows "SOH —"
  //    (OBD2 790/0029 needs the dongle). Held sticky (~1 Hz, 10 s window).
  double? get halSoh => _heldValue('soh', _coreHold);
  bool get useHalForSoh => _heldValue('soh', _coreHold) != null;

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
    // v0.1.29+96: trip start/stop reads the STICKY gear (last good, no time
    // window) — see _stickyGear. The old _heldValue(_coreHold) expired the
    // gear to null between the rare selector frames and made the panel
    // flicker. Display getters keep their _coreHold gating; only the trip
    // machine changes.
    final gear = _stickyGear;
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
      // v0.1.29+91: back-fill the DB row's start_soc once we have it (the row
      // was opened with a null anchor). Same pattern as the OBD2 tracker's
      // updateTripStartAnchors. Best-effort; null odo leaves that column be.
      _backfillHalTripStart();
    }
    // trip_a may also have been null at start — latch it once it arrives so
    // distance reads from zero (handled in halTripDistanceKm).
    // v0.1.29+91: also latch the absolute start odometer for the DB row if it
    // was null at start; once present, back-fill the row anchor.
    if (_halTripStartOdo == null) {
      final odoNow = _heldValue('odometer', _coreHold);
      if (odoNow != null) {
        _halTripStartOdo = odoNow;
        _backfillHalTripStart();
      }
    }

    // v0.1.29+91: fold this frame into the persisted-row min/max accumulators.
    _accumulateHalTripStats();

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
    // v0.1.29+91: latch the absolute odometer at start, used ONLY for the
    // row's start_odometer column (so history shows the odometer at trip
    // start). The trip DISTANCE itself comes from halTripDistanceKm = Δ trip_a
    // (cluster trip meter), the same value the live dashboard shows — so the
    // persisted distance matches what was on screen during the drive.
    _halTripStartOdo = _heldValue('odometer', _coreHold); // may be null early
    // Open the DB row best-effort. _halTripDbId stays null on failure (or no
    // DB) and the close path simply skips the write — the live tracker is
    // unaffected either way. startSoc/startOdo may be null this early; they
    // are back-filled on close from the latched values if they arrive later.
    _openHalTripRow();
    // Kick the speed tick if it isn't already running.
    _halTripTick ??= Timer.periodic(
        const Duration(seconds: 1), (_) => _onHalTripTick());
  }

  /// v0.1.29+91: open a Trips row for the live HAL trip (best-effort/async).
  /// Mirrors db.startTrip used by the OBD2 tracker. Guards against double-open.
  Future<void> _openHalTripRow() async {
    final db = _diagDb;
    if (db == null || _halTripDbId != null) return;
    try {
      final id = await db.startTrip(
        startSoc: _halTripStartSoc,
        startOdo: _halTripStartOdo,
      );
      // Only adopt the id if a trip is still live (a close may have raced).
      if (_halTripActive) {
        _halTripDbId = id;
      }
    } catch (_) {
      // best-effort — no DB row, history just won't include this drive
    }
  }

  /// v0.1.29+91: back-fill the HAL trip row's start_soc / start_odometer once
  /// those anchors arrive (they may be null at open time). Mirrors the OBD2
  /// tracker's updateTripStartAnchors. Best-effort/async; no-op without a row.
  Future<void> _backfillHalTripStart() async {
    final db = _diagDb;
    final id = _halTripDbId;
    if (db == null || id == null) return;
    try {
      await db.updateTripStartAnchors(
        id,
        startSoc: _halTripStartSoc,
        startOdo: _halTripStartOdo,
      );
    } catch (_) {
      // best-effort
    }
  }

  void _closeHalTrip() {
    // v0.1.29+91: persist the row BEFORE clearing state — finalize reads the
    // live getters/accumulators, which the resets below would wipe. The write
    // itself is async/best-effort and detached from this synchronous reset so
    // the lifecycle (and the stream) never blocks on the DB.
    _finalizeHalTripRow();
    _halTripActive = false;
    _halTripStartedAt = null;
    _halTripStartSoc = null;
    _halTripStartTripA = null;
    _halTripStartOdo = null;
    _halParkConfirmStart = null;
    _halParkedSince = null;
    _resetHalTripAggregates();
    _halTripTick?.cancel();
    _halTripTick = null;
    _halTripDbId = null;
  }

  /// v0.1.29+91: write the HAL trip's final aggregates to its Trips row via
  /// db.endTrip — the SAME call the OBD2 tracker uses. Snapshots every value
  /// it needs synchronously (BEFORE _closeHalTrip's resets run), then fires
  /// the async write. No-op when there is no DB row (open failed / no DB).
  /// Any present field is written; anything the HAL tracker doesn't know
  /// stays null (honest — no fabricated values), exactly like an orphan
  /// recovery on the OBD2 side.
  void _finalizeHalTripRow() {
    final db = _diagDb;
    final id = _halTripDbId;
    if (db == null || id == null) return;
    // Snapshot now — these getters/accumulators are wiped by _closeHalTrip.
    final endSoc = halSocForTrip;
    final endOdo = _heldValue('odometer', _coreHold);
    final distanceKm = halTripDistanceKm;       // Δ trip_a (live display delta)
    final energyKwh = halTripEnergyUsedKwh;     // ΔSOC × capacity (EMA)
    final consumption = halTripAvgConsumptionKwh100km;
    final peakSpeed = _halPeakSpeedKmh;
    final avgMoving = halTripCurrentAvgMovingKmh;
    // v0.1.29+91: movingSeconds = seconds spent MOVING (speed > 1 km/h),
    // NOT the full trip duration. _halSpeedSamples is exactly that — one
    // increment per 1 s tick while moving — mirroring the OBD2 tracker's
    // _tripMovingMs ~/ 1000. Trip duration is derived separately by the UI
    // from endedAt − startedAt, so it must NOT be written here (writing the
    // full duration would make trip_detail show "[whole trip] / —" for the
    // moving/idle split, which is wrong).
    final movingSecs = _halSpeedSamples > 0 ? _halSpeedSamples : null;
    final minTemp = _halTripMinTempC;
    final maxTemp = _halTripMaxTempC;
    final maxSpread = _halTripMaxCellSpreadMv;
    final minSoc = _halTripMinSoc;
    final maxSoc = _halTripMaxSoc;
    final peakPower = _halTripPeakPowerKw;
    final peakRegen = _halTripPeakRegenKw;
    // Fire-and-forget; a DB error must never disturb the stream/lifecycle.
    db
        .endTrip(
          id,
          endSoc: endSoc,
          endOdo: endOdo,
          distanceKm: distanceKm,
          energyUsedKwh: energyKwh,
          avgConsumptionKwh100km: consumption,
          minBatteryTempC: minTemp,
          maxBatteryTempC: maxTemp,
          maxCellSpreadMv: maxSpread,
          minSoc: minSoc,
          maxSoc: maxSoc,
          peakSpeedKmh: peakSpeed,
          peakPowerKw: peakPower,
          peakRegenKw: peakRegen,
          avgMovingSpeedKmh: avgMoving,
          movingSeconds: movingSecs,
        )
        // v0.1.29+93: freeze the speed-distribution histogram onto the row
        // from this trip's hal_samples speed series, so the chart renders in
        // history AND survives a DB wipe + cloud restore (mirrors the OBD2
        // endTrip path, which writes extra inline). Computed here because the
        // hal_samples read is async and can't be done at the synchronous
        // snapshot point above. Best-effort; null (no HAL speed samples)
        // leaves extra untouched.
        .then((_) => db.computeHalSpeedHistogramJson(id))
        .then((extraJson) => db.updateTripExtra(id, extraJson))
        .then((_) => refreshTotalDriveEnergy())
        .catchError((_) {});
  }

  void _resetHalTripAggregates() {
    _halPeakSpeedKmh = null;
    _halSpeedSum = 0;
    _halSpeedSamples = 0;
    _halEnergyEma = null;
    // v0.1.29+91: min/max accumulators for the persisted row.
    _halTripMinTempC = null;
    _halTripMaxTempC = null;
    _halTripMaxCellSpreadMv = null;
    _halTripMinSoc = null;
    _halTripMaxSoc = null;
    _halTripPeakPowerKw = null;
    _halTripPeakRegenKw = null;
  }

  /// v0.1.29+91: fold the current frame into the trip min/max accumulators
  /// (temp, cell spread, SOC, peak power/regen) so db.endTrip writes a row
  /// as complete as the OBD2 one. Called from _updateHalTrip while a trip is
  /// live; reads only held values, so it's cheap. Each field self-guards on
  /// availability — a missing signal simply doesn't update its accumulator.
  void _accumulateHalTripStats() {
    final t = halBatteryTempC;
    if (t != null) {
      _halTripMinTempC = _halTripMinTempC == null
          ? t
          : (t < _halTripMinTempC! ? t : _halTripMinTempC);
      _halTripMaxTempC = _halTripMaxTempC == null
          ? t
          : (t > _halTripMaxTempC! ? t : _halTripMaxTempC);
    }
    final spread = halCellSpreadMv;
    if (spread != null) {
      _halTripMaxCellSpreadMv = _halTripMaxCellSpreadMv == null
          ? spread
          : (spread > _halTripMaxCellSpreadMv! ? spread : _halTripMaxCellSpreadMv);
    }
    final soc = halSocForTrip;
    if (soc != null) {
      _halTripMinSoc =
          _halTripMinSoc == null ? soc : (soc < _halTripMinSoc! ? soc : _halTripMinSoc);
      _halTripMaxSoc =
          _halTripMaxSoc == null ? soc : (soc > _halTripMaxSoc! ? soc : _halTripMaxSoc);
    }
    final p = halPowerKw;
    if (p != null) {
      // v0.1.29+91: peakPowerKw stores the peak DISCHARGE magnitude (positive),
      // matching the OBD2 tracker which writes pwr.abs() into this column and
      // the UI which renders it unsigned. Discharge is positive in halPowerKw
      // (V×I, discharge-positive), so only positive samples update peak power;
      // an all-coast/regen trip leaves it null rather than writing a negative.
      if (p > 0 && (_halTripPeakPowerKw == null || p > _halTripPeakPowerKw!)) {
        _halTripPeakPowerKw = p;
      }
      // peakRegenKw stays SIGNED most-negative (regen), exactly like OBD2.
      if (p < 0 && (_halTripPeakRegenKw == null || p < _halTripPeakRegenKw!)) {
        _halTripPeakRegenKw = p;
      }
    }
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

  /// v0.1.29+96: the DB row id of the live HAL trip, or null before the row
  /// opens / after it closes. Exposed so the driver panel can show the real
  /// trip number ("#42") instead of the +85 placeholder literal "trip".
  int? get halTripDbId => _halTripDbId;

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
  /// trip has at least one moving sample. (Internal / parity with OBD2.)
  double? get halTripCurrentAvgMovingKmh {
    if (!_halTripActive || _halSpeedSamples == 0) return null;
    return _halSpeedSum / _halSpeedSamples;
  }

  /// v0.1.29+91: live OVERALL average speed (km/h), INCLUDING stops —
  /// distance ÷ wall-clock elapsed. Shown in the driver "avg speed" cell in
  /// halOnly (mirrors ConnectionService.tripCurrentAvgSpeedKmh). distance is
  /// Δ trip_a; elapsed is the HAL trip wall clock. Null until both exist and
  /// elapsed is non-zero.
  double? get halTripCurrentAvgSpeedKmh {
    final dist = halTripDistanceKm;
    final dur = halTripDuration;
    if (dist == null || dur == null) return null;
    final secs = dur.inSeconds;
    if (secs <= 0 || dist <= 0) return null;
    return dist / secs * 3600.0;
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
    // v0.1.29+92: recover HAL trips orphaned by a previous ignition-off,
    // BEFORE starting the stream (so it runs before _updateHalTrip can open
    // this session's trip — _halTripDbId is still null, every open row is a
    // true orphan). A clean close needs the Park-window timer to fire, but
    // that timer only ticks while HAL frames arrive — ignition-off kills the
    // process first, so the row is left open and the next drive stacks a
    // second ACTIVE trip on top (the bug Alex saw: #42 stuck ACTIVE, #43
    // opened over it). Head-unit only (phones never open HAL trips).
    // Best-effort; a failure must not block startup.
    if (_isHeadUnit) {
      await _recoverOrphanHalTrips();
    }
    // Start the stream unless the user pinned OBD2-only. On a phone the
    // platform returns null and we simply stay on OBD2 — no harm.
    if (_mode != HalSourceMode.obd2Only) {
      await _startStream();
    }
    // v0.1.29+91: prime the cumulative drive-energy cell from existing trips.
    await refreshTotalDriveEnergy();
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
    // v0.1.29+88: raw BigData diagnostic frames (whitelisted CAN-IDs) come
    // through as name=="bigdata_raw" carrying the full frame hex. They are
    // NOT a consumed signal and carry no value — log them straight to
    // hal_samples (source='bigdata') and return BEFORE the range-guard, so
    // they never touch _latest / the trip state machine. This is the row
    // recon diffs against, and the one that answers "did 0x044C arrive?".
    if (e.name == 'bigdata_raw') {
      _logBigDataRaw(e);
      return;
    }
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
    // v0.1.29+87/+88: diagnostic capture — throttle-log this decoded signal
    // to hal_samples with its real target/subtype (parsed from e.key) so an
    // export shows the real HAL stream and matches recon's schema. Throttled
    // per-name so the ~15 Hz stream doesn't bloat the DB. No-op without DB.
    _logHalDiag(e, d);
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

  // ── HAL diagnostic logging (+87/+88) ──
  //
  // Per-name throttle so a high-rate signal writes at most once per window.
  // soc_precise is slow (~1 frame / 15 s) so it is NOT throttled away — the
  // window is short enough that every soc_precise frame is captured. The
  // map holds the last-logged time per signal name.
  static const Duration _halDiagThrottle = Duration(seconds: 3);
  final Map<String, DateTime> _halDiagLastLog = {};

  /// Split a canonical key "targetKey|0xSUBTYPE" into its parts.
  /// Returns ('targetKey', 'SUBTYPE') or (key, '') if it doesn't match.
  (String, String) _splitKey(String key) {
    final i = key.indexOf('|0x');
    if (i < 0) return (key, '');
    return (key.substring(0, i), key.substring(i + 3));
  }

  void _logHalDiag(HalEvent e, double value) {
    final db = _diagDb;
    if (db == null) return; // diagnostics not wired
    final now = DateTime.now();
    final last = _halDiagLastLog[e.name];
    if (last != null && now.difference(last) < _halDiagThrottle) return;
    _halDiagLastLog[e.name] = now;
    final (target, subtypeHex) = _splitKey(e.key);
    // v0.1.29+92: tag with the live HAL trip's own row id when one is open,
    // so the rows form a per-trip series (orphan recovery reads the last
    // such timestamp as the real end-of-drive). Fall back to the OBD2 trip
    // id (the +91 behaviour) when there's a dongle trip but no HAL row.
    final tid = _halTripDbId ?? _currentTripId?.call();
    // Fire-and-forget; never let a logging failure disturb the stream.
    db
        .insertHalSignal(
          tripId: tid,
          targetKey: target,
          subtype: subtypeHex,
          name: e.name,
          numeric: value,
        )
        .catchError((_) => 0);
  }

  /// v0.1.29+88: log a raw BigData frame (source='bigdata'). NOT throttled —
  /// only whitelisted CAN-IDs reach here (gated platform-side), so volume is
  /// already bounded. This is the row Друг 3 diffs against recon and the one
  /// that confirms whether a frame (e.g. 0x044C) actually arrives.
  void _logBigDataRaw(HalEvent e) {
    final db = _diagDb;
    if (db == null) return;
    final canId = e.canIdHex;
    final buf = e.bufHex;
    if (canId == null || buf == null) return;
    // v0.1.29+92: same per-trip tagging as the decoded path above.
    final tid = _halTripDbId ?? _currentTripId?.call();
    db
        .insertBigDataFrame(
          tripId: tid,
          canId: canId,
          rawHex: buf,
        )
        .catchError((_) => 0);
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
