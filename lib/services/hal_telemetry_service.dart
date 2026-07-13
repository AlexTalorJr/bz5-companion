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
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
// v0.1.39+138: Value for the SnapshotsCompanion of the HAL snapshot
// writer — same show-only import shape as connection.dart line 5.
import 'package:drift/drift.dart' show Value;

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

/// v0.1.32+131: user-selectable SOC for the UI (prefs 'soc_source').
///
/// The car keeps TWO state-of-charge figures and they legitimately differ
/// by ~1-2% (non-linearly across the range):
///   - display : the buffered/scaled percentage the instrument cluster
///               shows (HAL soc_display, live-verified equal to the
///               cluster on 2026-06-11). Integer, event-driven.
///   - precise : the BMS-internal (true) SOC — HAL soc_precise, 0.1%
///               resolution, ~30 s cadence.
/// Showing `precise` (the pre-+131 behaviour) made users compare against
/// the cluster and conclude the app "lies". Default is therefore
/// `display`; `precise` remains one toggle away for those who want the
/// real figure. The setting changes DISPLAYED digits only — trip energy,
/// SOH and charging-ETA math stay on precise unconditionally.
enum SocSource { display, precise }

SocSource _socSourceFromString(String? s) =>
    s == 'precise' ? SocSource.precise : SocSource.display;

String _socSourceToString(SocSource s) =>
    s == SocSource.precise ? 'precise' : 'display';

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
  // v0.1.29+106: reads ConnectionService.isBleConnected — true when an ELM327
  // dongle is physically connected RIGHT NOW. Trip ownership keys off this
  // fact (NOT the source mode): dongle present → OBD2 owns the trip and the
  // HAL tracker stays silent; dongle absent → HAL owns, in ANY mode. AA2-safe:
  // a bool callback, never an import of ConnectionService (same one-way bridge
  // as _currentTripId). Null in tests / if unwired → treated as "no dongle".
  final bool Function()? _dongleConnected;

  HalTelemetryService({
    AppDatabase? diagDb,
    int? Function()? currentTripId,
    bool Function()? dongleConnected,
  })  : _diagDb = diagDb,
        _currentTripId = currentTripId,
        _dongleConnected = dongleConnected;

  HalSourceMode _mode = HalSourceMode.auto;
  HalSourceMode get mode => _mode;

  // v0.1.32+131: UI SOC source (see the SocSource doc above). Read by
  // resolveUiSocPct (soc_resolver.dart); persisted in init()/setSocSource.
  SocSource _socSource = SocSource.display;
  SocSource get socSource => _socSource;

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

  /// v0.1.29+99: does HAL own trip creation right now? Used by the OBD2
  /// tracker (via a callback set in main) to suppress its own trip rows so
  /// only ONE tracker writes Trips at a time — otherwise, with the dongle
  /// connected in halOnly, both trackers opened a trip into the same table
  /// and history showed two simultaneous "ACTIVE" trips (the #45 OBD2 +
  /// #46 HAL pair seen on 2026-06-27).
  ///
  /// v0.1.29+106: ownership keys off the DONGLE, not the mode (Alex, 30 Jun).
  ///   dongle connected  → OBD2 owns; HAL stays silent (only OBD2 can read
  ///                       UDS, so it's the right owner whenever it's live).
  ///   dongle absent      → HAL owns, in ANY mode — this fixes bug C, where
  ///                       in `auto` with no dongle NEITHER tracker logged a
  ///                       trip (HAL waited for halOnly, OBD2 was dead).
  /// Gated on `_running` too, so a dead HAL stream doesn't claim ownership.
  /// No duplicates: dongle present → only OBD2 can physically log; absent →
  /// only HAL. The cumulative-energy SUM stays clean. Distinct from
  /// halDriveActive (display-only, halOnly-bound) — the dashboard is unaffected.
  bool get halOwnsTrip => _running && !(_dongleConnected?.call() ?? false);

  HalStartStatus? _status;
  HalStartStatus? get status => _status;

  // ─── Latest decoded values (v0.1.29+66 overlapping wave) ────────────
  //
  // Per-name latest sample. Two freshness classes, matching how the HAL
  // actually delivers (field rates from the 2026-06-11 drive, HAL Test):
  //
  //  * CONTINUOUS — pushed at a steady rate while the stream is up:
  //      speed ~8 Hz, pack_current ~2.2 Hz, pack_voltage ~0.8 Hz.
  //      Freshness = sample age within a per-name
  //      window; a stall (binder loss) trips the fallback well before
  //      the user notices a frozen value.
  //  * EVENT-DRIVEN — pushed only when the value CHANGES: soc_display,
  //      soc_battery (0.0 Hz at steady state; SOC can sit for many
  //      minutes) and — v0.1.29+111 — gear_enum: the selector pushes ONE
  //      frame per lever move (the +96 export showed 348/1014/1497 s
  //      mid-drive gaps; the "~3.4 Hz" from the 2026-06-11 drive was an
  //      artifact of frequent shifting during that test). Under the old
  //      6 s window + 90 s hold the gear cell fell back to OBD2 — a dash
  //      without a dongle — 90 s after every shift. An age window would
  //      falsely expire event-driven names, so they count as fresh while
  //      the stream is RUNNING and are cleared on stop.
  static const Map<String, Duration> _continuousWindow = {
    'speed': Duration(milliseconds: 1500),
    'pack_voltage': Duration(seconds: 6),
    'pack_current': Duration(seconds: 6),
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
  static const Set<String> _eventDriven = {
    'soc_display', 'soc_battery',
    // v0.1.29+111: gear is event-driven (see the class comment) — display
    // now holds it for the whole running stream, like _stickyGear does
    // for the trip machine and +82 did for brake_pedal.
    'gear_enum',
  };

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
    // v0.1.29+105: cell-spread pair held sticky. REGRESSION FIX for +103.
    // These four flow from BYDAutoEnergyDevice (DOUBLE, ~48 Hz, dongle-free
    // via BigData) and pass the range guard in _onEvent → they land in
    // _latest, but WITHOUT being in this set they were never copied to
    // _lastGood. useHalForCellSpread → _useHal('cell_v_lowest') reads the
    // held value (_lastGood) in halOnly, found null, and the dashboard_wide
    // battery block fell through to the OBD2 branch — empty M1–M10 list +
    // an "Экстремумы: загрузка…" that never resolved (OBD2 cell extremes are
    // null with no dongle). Adding them here makes the held value populate,
    // so the +103 HAL fork fires and shows the pack-temp panel + min/max V.
    // The signal is physically present (Друг 3 confirmed) — it just wasn't
    // being held. Same treatment as soh/battery_temp_bigdata above.
    'cell_v_lowest', 'cell_v_highest',
    'cell_idx_lowest', 'cell_idx_highest',
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
  // v0.1.29+105: nominal pack capacity in Ah — the 100%-SOH reference for the
  // HAL coulomb-counted SOH (full_Ah / this × 100). Duplicated here as a const
  // (Bz5Model.batteryCapacityAh = 150.0) to avoid importing ConnectionService
  // — same rationale as _halPackCapacityKwh above. The DC fast-charge session
  // of 2026-06-28 integrated 38.2 Ah over a 25.9% SOC rise → 147.5 Ah full,
  // against BMS SOH ~98%; 150.0 nominal resolves that to 98.3%. Keep in sync
  // with ConnectionService.Bz5Model.batteryCapacityAh by hand.
  static const double _halSohPackCapacityAh = 150.0;
  static const double _kHalSohMinDeltaSocPct = 20.0; // min SOC span to accept
  static const double _kHalSohMinCoverage = 0.90;    // min live-current frac
  // v0.1.29+116: crash-safe SOH sessions. The whole session state used to
  // live in RAM only and was finalized ONLY on a live charge→idle edge — so
  // the realistic DC-charge flow (charge, lock the car, walk away → the head
  // unit powers the process down) silently lost the entire session (Alex,
  // 3 Jul field run: 26→68% DC charge, no SOH update). While a session is
  // CONFIRMED, its running state is snapshotted to SharedPreferences every
  // _kHalSohPersistEvery; on the next init() the snapshot is consumed and,
  // if it passes the exact same ΔSOC/coverage/sanity gates, written to id=2.
  static const String _kHalSohPendingKey = 'hal_soh_pending_session';
  static const Duration _kHalSohPersistEvery = Duration(seconds: 30);
  static const double _halMovingKmh = 1.0; // > this counts as moving
  static const Duration _kHalParkConfirm = Duration(seconds: 30);
  static const Duration _kHalParkClose = Duration(minutes: 10);
  // v0.1.29+106: how often the active-trip watchdog flushes lastAliveTs + the
  // aggregate snapshot to the row. 15 s is well inside the park-close window
  // and cheap (one row update); on a kill, recovery is at most this stale.
  static const Duration _kHalAliveFlush = Duration(seconds: 15);

  // v0.1.29+104: speed-based trip-start fallback. The primary start path
  // keys off the gear selector leaving Park (see _updateHalTrip), but
  // gear_enum is EVENT-DRIVEN — a frame arrives only when the lever moves.
  // If the app launches while the car is ALREADY rolling in D, no gear
  // frame ever lands, _stickyGear stays null, and the gear path never
  // fires — so the whole drive produces no trip (the bug Alex hit). This
  // fallback starts the trip on sustained speed alone when gear is still
  // unknown: speed > _halMovingKmh held for _kHalSpeedStartConfirm. Both
  // paths funnel into _startHalTrip(), guarded by !_halTripActive, so they
  // never double-start. Distance/duration then anchor from THIS moment
  // (app launch), which is the accepted behaviour for this edge case.
  static const Duration _kHalSpeedStartConfirm = Duration(milliseconds: 2500);
  // v0.1.29+101: charge-onset close. A HAL trip that doesn't close promptly
  // when the car stops can swallow a charge that starts a few minutes later
  // (observed: trip #45 ended at 4% SOC but the row showed 18% because a DC
  // charge begun ~4 min after Park flowed into the still-open trip). OBD2 is
  // immune because its isCharging gate (b00History) freezes its tracker —
  // but isCharging is OBD2-only (needs the dongle reading 790/0B00) and is
  // dead in halOnly, so the HAL tracker needs its OWN charge detector built
  // from HAL data it already has: pack_current.
  //
  // Charge ≠ regen. Regen happens WHILE MOVING and is brief; a real charge
  // is STATIONARY and sustained. Field check of trip #45 found regen bursts
  // up to 40 s at -80 A while driving at 89 km/h — so current+time ALONE
  // would false-fire mid-drive. The discriminator is speed: charge requires
  // speed ≈ 0. So: (speed ≤ _halMovingKmh) AND (pack_current < threshold)
  // held for the debounce → it's a charge, close the trip.
  static const double _kHalChargeCurrentA = -10.0; // more negative = charging
  static const Duration _kHalChargeConfirm = Duration(seconds: 20);

  bool _halTripActive = false;
  DateTime? _halTripStartedAt;
  double? _halTripStartSoc;     // latched start SOC (whole %, smoothed via EMA)
  double? _halTripStartTripA;   // latched start odo-trip (km) from trip_a
  // v0.1.29+103: survive a user-reset of the native trip_a counter mid-trip.
  // trip_a is the dashboard "Trip A" the driver can zero from the car's own
  // UI. The HAL trip distance is Δtrip_a from a latched start, so a reset
  // makes the live trip_a drop below the latched start and (pre-+103) the
  // distance getter returned null forever — the dashboard showed 0.0 km while
  // duration/energy kept counting (observed 2026-06-29). We now detect the
  // drop, bank the distance covered up to the reset into an accumulator, and
  // re-latch the start to the new (low) trip_a so counting continues from the
  // new zero without losing the kilometres already driven.
  double _halTripDistAccumKm = 0;   // banked km from before any trip_a reset
  double? _halTripLastTripA;        // last seen trip_a (to bank on reset)
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
  // v0.1.29+98: idle/regen accumulators so the persisted HAL row reaches
  // full parity with the OBD2 one (history showed HAL trips missing the
  // moving/idle split, regen energy and sample count). Both are summed in
  // the 1 s tick: _halIdleSeconds counts ticks with speed ≤ _halMovingKmh
  // (Ready-but-stationary, the same notion as the OBD2 tracker's
  // _tripIdleMs), and _halRegenEnergyKwh integrates regen power (halPowerKw
  // < 0) over time (kW × 1 s ÷ 3600 = kWh), mirroring OBD2's
  // _tripRegenEnergyKwh. sampleCount is read async on close from
  // db.countHalSamplesForTrip (the hal_samples row count for the trip),
  // since OBD2 stores per-sample rows but HAL's per-sample stream lives in
  // the hal_samples table.
  int _halIdleSeconds = 0;
  double _halRegenEnergyKwh = 0;
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
  // v0.1.29+101: charge-onset debounce clock — first sample of the current
  // (stationary + charging-current) streak. Reset whenever the car moves or
  // the current goes non-charging.
  DateTime? _halChargeConfirmStart;
  // v0.1.29+104: speed-based start debounce clock — first sample of the
  // current (moving + gear-still-unknown) streak. Reset when speed drops to
  // ≤ _halMovingKmh or once a gear frame arrives (then the gear path owns
  // the start). See _kHalSpeedStartConfirm and the start block in
  // _updateHalTrip.
  DateTime? _halSpeedStartConfirmStart;
  // v0.1.29+101: rolling snapshot of the LAST moment the car was moving,
  // captured each tick while speed > _halMovingKmh. When a charge-onset
  // close fires, the trip is finalized AS OF this snapshot (variant A:
  // back-date to the stop) so the charge never contaminates end_soc /
  // distance / energy. Null until the first moving sample.
  _HalStopSnapshot? _halLastMovingSnapshot;
  // v0.1.29+106: watchdog flush clock. While a HAL trip is active, the trip's
  // aggregate snapshot + a last-alive timestamp are written to the row every
  // _kHalAliveFlush (on the speed ticks — no separate Timer). If the process is
  // killed (head unit sleeps) the row keeps a recent snapshot, so orphan
  // recovery can close it with full aggregates + a real end time instead of the
  // old "ACTIVE for 2 h, all dashes" outcome. Crucially the watchdog never
  // writes endedAt (that would let cloud-sync push a still-active trip early —
  // the +19 bug), only lastAliveTs + the aggregates. Null until the first flush.
  DateTime? _halLastAliveFlush;
  // ── v0.1.29+105: HAL coulomb-counted SOH charge-state machine ──────────
  //
  // INDEPENDENT of the trip machine above (Вариант A). The UDS SOH integral
  // in connection.dart only runs while the OBD2 isCharging gate is true, and
  // that gate reads 0x0B00 over UDS — DEAD in halOnly with no dongle. So this
  // is the HAL-side equivalent: it detects a charge from HAL data alone
  // (stationary + charging current, the same discriminator the +101 trip
  // close uses) and integrates ∫|pack_current|·dt across the session. It does
  // NOT depend on a trip being active — a real charge happens AFTER the car
  // has parked and the trip has already closed, so this must run on its own.
  //
  // Driven from _updateHalCharge(), called from _onEvent alongside (NOT
  // inside) _updateHalTrip, so it ticks regardless of trip state. On the
  // charge→idle edge, if ΔSOC ≥ _kHalSohMinDeltaSocPct AND coverage ≥
  // _kHalSohMinCoverage, full_Ah = accumAh / ΔSOC_frac and SOH% = full_Ah /
  // _halSohPackCapacityAh × 100 is written to soh_estimates id=2 (source
  // 'hal'). connection.dart is NOT touched — AA2 stays intact.
  bool _halSohCharging = false;          // confirmed charging right now
  // v0.1.29+105: anchor set (start SOC latched + integral running) on the
  // FIRST charge-level frame, BEFORE the debounce confirms. This separates
  // "session anchored / integrating" from "debounce satisfied" so the charge
  // delivered during the 20 s debounce is counted in BOTH the Ah integral and
  // the ΔSOC (latching the start SOC only after the debounce would exclude
  // ~0.7% SOC of DC charge from ΔSOC and understate SOH).
  bool _halSohSessionAnchored = false;
  DateTime? _halSohChargeConfirmStart;   // debounce clock for charge onset
  DateTime? _halSohStartedAt;            // session start (debounce satisfied)
  double? _halSohStartSoc;               // SOC latched at session start
  double _halSohChargeAhAccum = 0.0;     // ∫|I|·dt this session, Ah
  DateTime? _halSohLastIntegrationAt;    // previous integration tick
  double _halSohCoverageLiveSec = 0.0;   // seconds with a live pack_current
  double _halSohCoverageTotalSec = 0.0;  // total seconds integrated
  // v0.1.29+116: last time the confirmed session was snapshotted to prefs
  // (crash-safe recovery). Null until the first snapshot of a session.
  DateTime? _halSohLastPersistAt;
  // Cached latest HAL SOH percent (id=2), hydrated on init, refreshed on each
  // qualifying session close. Null until the first valid HAL charge session.
  double? _halSohAhPctCached;
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
        // v0.1.29+106: two cases now.
        //
        //   (a) lastAliveTs present → the watchdog flushed before the kill, so
        //       the row ALREADY holds correct aggregates (distance, energy,
        //       min/max, …). We only need to stamp endedAt = lastAliveTs +
        //       notes. closeHalOrphanAt touches just those two columns and
        //       leaves aggregates alone — so this gives a full record with no
        //       recompute. This is the main path (a normal drive / DC flushes
        //       within _kHalAliveFlush).
        //
        //   (b) lastAliveTs null → an old pre-+106 row, or a kill before the
        //       first flush. Aggregates weren't snapshotted, so fall back to
        //       the last hal-sample time for endedAt and try a COARSE energy
        //       reconstruction from soc_precise (ΔSOC × pack capacity). We do
        //       NOT reconstruct distance — the throttled hal_samples can't give
        //       an honest figure — so it stays whatever the row had (likely
        //       null). energyUsedKwh is only written when the reconstruction
        //       yields a value AND the row doesn't already have one.
        if (t.lastAliveTs != null) {
          await db.closeHalOrphanAt(t.id, t.lastAliveTs!,
              note: 'auto-closed: orphaned');
          // v0.1.29+111: freeze the derived row bits too (see helper).
          await _backfillOrphanDerived(db, t.id, samples);
          debugPrint('HAL recovery: closed orphan Trip #${t.id} via watchdog '
              'snapshot (started ${t.startedAt}) → endedAt=${t.lastAliveTs}');
          continue;
        }
        final endTs = await db.lastHalSampleTimeForTrip(t.id) ??
            t.startedAt.add(const Duration(seconds: 1));
        double? energyKwh;
        if (t.energyUsedKwh == null) {
          energyKwh = await db.reconstructHalEnergyFromSamples(t.id);
        }
        await db.closeHalOrphanAt(t.id, endTs,
            note: 'auto-closed: orphaned', energyUsedKwh: energyKwh);
        // v0.1.29+111: freeze the derived row bits too (see helper).
        await _backfillOrphanDerived(db, t.id, samples);
        debugPrint('HAL recovery: closed orphan Trip #${t.id} '
            '(started ${t.startedAt}) → endedAt=$endTs'
            '${energyKwh != null ? ', energy≈$energyKwh kWh (reconstructed)' : ''}');
      }
    } catch (e) {
      debugPrint('HAL orphan recovery failed (non-fatal): $e');
    }
  }

  /// v0.1.29+111: derived-row backfill for a recovered orphan. The LIVE
  /// finalize freezes the speed histogram (+93) and the hal sample count
  /// (+98) onto the row, but the orphan path never did. Ignition-off ends
  /// most real drives (the head unit kills the app before the park timer
  /// fires), and hal_samples are NOT cloud-restored — so after the next
  /// reinstall wipe those trips lost their speed distribution for good
  /// (the "sometimes no distribution" bug). Compute both from hal_samples
  /// while the rows still exist. Best-effort: a null histogram (no speed
  /// rows) leaves `extra` untouched; count is written only when > 0 so an
  /// OBD2-counted row is never clobbered with a zero.
  Future<void> _backfillOrphanDerived(
      AppDatabase db, int tripId, int samples) async {
    if (samples == 0) return;
    final extraJson = await db.computeHalSpeedHistogramJson(tripId);
    await db.updateTripExtra(tripId, extraJson);
    await db.updateTripSampleCount(tripId, samples);
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
        // v0.1.29+111: event-driven names (gear, the SOC pair) have no
        // staleness — a frame arrives only on CHANGE, so the last good
        // value is valid for the whole running stream (mirrors
        // _stickyGear and the +82 brake_pedal precedent). The 90 s hold
        // below stays for the continuous names only.
        if (_eventDriven.contains(name)) {
          return _running && _lastGood[name] != null;
        }
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

  /// v0.1.32+131: cluster-matching SOC for SocSource.display. Same
  /// no-window sticky semantics as halSocForTrip (both names are
  /// event-driven — the last frame is valid for the whole running
  /// stream); null on a dead stream or before the first frame, letting
  /// resolveUiSocPct fall back honestly.
  double? get halSocDisplayPct {
    if (!_running) return null;
    final d = halValue('soc_display');
    if (d != null) return d;
    return halValue('soc_battery');
  }

  // ── EV range estimate (v0.1.29+102). The OBD2 path (connection.dart
  //    rangeEstimateKm) needs readNumeric('790','0005') for SOC plus the
  //    OBD2 trip-consumption history, so in halOnly without a dongle it
  //    returns null and the SOC card shows "—". This HAL path mirrors the
  //    SAME hybrid logic OBD2 uses, but sourced entirely from HAL so range
  //    works dongle-free:
  //      remaining kWh = halSocPct × capacity / 100
  //      consumption   = live HAL-trip avg IF the trip is ≥5 min and the
  //                      value is sane (5..50 kWh/100km), else the nominal
  //                      constant (matches Bz5Model.avgConsumptionWhKm=144).
  //    AA2: HAL never imports connection.dart, so the nominal is duplicated
  //    here as a const (same as _halPackCapacityKwh above).
  static const double _halNominalConsumptionWhKm = 144.0;

  double? get halRangeKm {
    final soc = halSocPct;
    if (soc == null) return null;
    final remainingKwh = _halPackCapacityKwh * soc / 100.0;

    // Live HAL-trip consumption: only trust it once the trip is old enough
    // for the ΔSOC/distance ratio to settle (≥5 min, same gate as the OBD2
    // getter's tripAgeSec>300), and only inside the sane band.
    final dur = halTripDuration;
    final smoothed = halTripAvgConsumptionKwh100km;
    if (dur != null &&
        dur.inSeconds > 300 &&
        smoothed != null &&
        smoothed > 5 &&
        smoothed < 50) {
      return remainingKwh / smoothed * 100.0;
    }

    // Fallback: nominal constant (Wh/km → km).
    return remainingKwh * 1000 / _halNominalConsumptionWhKm;
  }

  /// True when the HAL range estimate can be shown (SOC available via HAL).
  /// The display substitutes hal.halRangeKm for svc.rangeEstimateKm under
  /// this flag, invisibly, like speed/SOC/odometer.
  bool get useHalForRange => halSocPct != null;

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

  /// v0.1.29+116: HAL-confirmed charging, for the dashboard badge/panel.
  /// The old badge read ONLY ConnectionService.isCharging (UDS) — dead
  /// without a dongle, so a 90 kW DC charge showed "Not charging" (Alex,
  /// 3 Jul). True once the SOH charge machine has confirmed a session past
  /// the 20 s debounce AND pack_current is still fresh at charge level —
  /// the freshness re-check keeps a stalled stream from freezing the badge
  /// on. Display-only; trips/SOH have their own machines.
  bool get halChargingActive {
    if (!_running || !_halSohCharging) return false;
    final pi = halValue('pack_current');
    return pi != null && pi < _kHalChargeCurrentA;
  }

  /// v0.1.29+116: charge power for the badge/panel while halChargingActive —
  /// |pack V × I| in kW, same signals as halPowerKw, unsigned because the
  /// charging UI renders magnitude. Null when not HAL-charging so callers
  /// can fall back to the OBD2 value verbatim.
  double? get halChargePowerKw {
    if (!halChargingActive) return null;
    final p = halPowerKw;
    if (p == null) return null;
    return p.abs();
  }

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

  /// v0.1.29+105: independent HAL coulomb-counted SOH percent (id=2), or null
  /// until the first qualifying HAL charge session. This is the dongle-free
  /// twin of ConnectionService.sohAhPct (UDS, id=1); the dashboard prefers
  /// this over the UDS estimate and the BMS value (HAL-priority). Computed by
  /// the _updateHalCharge state machine, hydrated by loadHalSohEstimate().
  double? get halSohAhPct => _halSohAhPctCached;

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

  /// v0.1.32+131: the min/max frames must have arrived close together
  /// before we subtract them. Both cell_v names stream at ~48 Hz, so a
  /// healthy pair is milliseconds apart; a gap means one side stalled and
  /// _heldValue (90 s) is serving a frame from a different electrical
  /// moment — subtracting across that gap manufactures a spread that
  /// never existed. Field evidence: the 195 mV outlier latched into a
  /// trip's max (the +130 Trends spread card) while the UDS path — whose
  /// min/max come from ONE poll and are immune by construction — never
  /// saw anything like it.
  static const _cellPairWindow = Duration(seconds: 3);

  /// Cell spread in mV from the HAL min/max pair, or null if either is
  /// absent. (max − min) V × 1000 → mV, matching the OBD2 cell-spread unit.
  /// v0.1.32+131: null too when the pair is mismatched in time (see
  /// [_cellPairWindow]) — feeds BOTH consumers (the live Balance tile and
  /// the per-trip max accumulator) through this single gate.
  double? get halCellSpreadMv {
    final lo = halCellVLowest;
    final hi = halCellVHighest;
    if (lo == null || hi == null) return null;
    final loAt = _lastGood['cell_v_lowest']?.at;
    final hiAt = _lastGood['cell_v_highest']?.at;
    if (loAt == null || hiAt == null) return null;
    if (hiAt.difference(loAt).abs() > _cellPairWindow) return null;
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
    // v0.1.29+106: gate on OWNERSHIP (halOwnsTrip), not display (halDriveActive).
    // HAL runs the trip whenever it owns it = stream live AND no dongle, in ANY
    // mode (Alex, 30 Jun). This is what lets a trip get logged in `auto` with no
    // dongle (bug C). halDriveActive stays display-only for the widgets — do NOT
    // swap it here. When ownership is lost (dongle plugged in mid-drive, or the
    // stream dies) close any open HAL trip and stand down.
    if (!halOwnsTrip) {
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
        _halSpeedStartConfirmStart = null;
        return;
      }

      // v0.1.29+104: speed-based start fallback for the "launched while
      // already rolling" case. gear_enum is event-driven, so if the lever
      // hasn't moved since app start, gear is still null here and the path
      // above can't fire. Start on sustained motion instead: speed >
      // _halMovingKmh held for _kHalSpeedStartConfirm, but ONLY while gear
      // is still unknown (gear == null) — once any gear frame arrives the
      // gear path takes over and we drop this clock. Funnels into the same
      // _startHalTrip(); the !_halTripActive guard above prevents any
      // double-start. Distance/duration anchor from here (app launch).
      if (gear == null) {
        final sp = halSpeedKmh;
        if (sp != null && sp > _halMovingKmh) {
          _halSpeedStartConfirmStart ??= DateTime.now();
          if (DateTime.now().difference(_halSpeedStartConfirmStart!) >=
              _kHalSpeedStartConfirm) {
            _startHalTrip();
            _halSpeedStartConfirmStart = null;
          }
        } else {
          // Dropped below the moving threshold before confirming — reset.
          _halSpeedStartConfirmStart = null;
        }
      } else {
        // A gear frame has arrived (gear != null but it's Park) — the gear
        // path owns start/stop from now on; clear the speed clock.
        _halSpeedStartConfirmStart = null;
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

    final now = DateTime.now();
    final speed = halSpeedKmh;
    final moving = speed != null && speed > _halMovingKmh;

    // v0.1.29+106: watchdog flush. Every _kHalAliveFlush, stamp the row with a
    // last-alive time + the current aggregate snapshot, WITHOUT setting endedAt
    // (the trip stays ACTIVE; cloud-sync won't push it early). If the process
    // is killed before a clean close, orphan recovery finds this fresh snapshot
    // and finalizes the trip with real aggregates + endedAt = lastAliveTs,
    // instead of leaving "ACTIVE 2 h / all dashes". Runs on the speed ticks
    // (no separate Timer); the lastAliveTs tracks the last MOVING moment so it
    // never drifts forward into a post-stop charge. Gated on a live DB row.
    if (_halTripDbId != null &&
        (_halLastAliveFlush == null ||
            now.difference(_halLastAliveFlush!) >= _kHalAliveFlush)) {
      _halLastAliveFlush = now;
      final db = _diagDb;
      final id = _halTripDbId;
      if (db != null && id != null) {
        final a = _collectHalTripAggregates();
        final aliveTs = _halLastMovingSnapshot?.at ?? now;
        db
            .touchTripAlive(
              id,
              lastAliveTs: aliveTs,
              endSoc: a.endSoc,
              endOdo: a.endOdo,
              distanceKm: a.distanceKm,
              energyUsedKwh: a.energyKwh,
              avgConsumptionKwh100km: a.consumption,
              minBatteryTempC: a.minTemp,
              maxBatteryTempC: a.maxTemp,
              maxCellSpreadMv: a.maxSpread,
              minSoc: a.minSoc,
              maxSoc: a.maxSoc,
              peakSpeedKmh: a.peakSpeed,
              peakPowerKw: a.peakPower,
              peakRegenKw: a.peakRegen,
              avgMovingSpeedKmh: a.avgMoving,
              movingSeconds: a.movingSecs,
              idleSeconds: a.idleSecs,
              regenEnergyKwh: a.regenKwh,
            )
            .catchError((_) {});
      }
    }

    // v0.1.29+101: while moving, keep a rolling snapshot of the trip end-state
    // (time + SOC + odometer). If a charge-onset close fires later, we
    // back-date the trip to this stop (variant A) so the charge never
    // contaminates end_soc / distance / energy.
    if (moving) {
      _halLastMovingSnapshot = _HalStopSnapshot(
        at: now,
        soc: halSocForTrip,
        odometerKm: _heldValue('odometer', _coreHold),
      );
    }

    // v0.1.29+101: charge-onset close. Charge ≠ regen — regen is brief and
    // happens WHILE MOVING, a charge is STATIONARY and sustained. So require
    // BOTH stationary (speed ≈ 0) AND charging current, held for the debounce.
    // This is the HAL-side equivalent of the OBD2 isCharging gate (which is
    // dead in halOnly). On fire, finalize AS OF the last moving snapshot so
    // the post-stop charge is excluded.
    final packI = halValue('pack_current');
    final chargingNow =
        !moving && packI != null && packI < _kHalChargeCurrentA;
    if (chargingNow) {
      _halChargeConfirmStart ??= now;
      if (now.difference(_halChargeConfirmStart!) >= _kHalChargeConfirm) {
        _closeHalTrip(asOf: _halLastMovingSnapshot);
        return;
      }
    } else {
      _halChargeConfirmStart = null;
    }

    // Active trip — park-based segmentation (same thresholds as the OBD2
    // tracker: debounce P, then close after the park window). v0.1.29+101:
    // closing now requires Park AND stationary (speed ≈ 0), not Park alone —
    // a stray Park frame while still rolling must not close a live trip.
    final parkedStill = inPark && !moving;
    if (!parkedStill) {
      _halParkConfirmStart = null;
      _halParkedSince = null;
      return;
    }
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
    _halSpeedStartConfirmStart = null; // v0.1.29+104: clear speed-start clock
    _halLastAliveFlush = null;    // v0.1.29+106: flush promptly for the new trip
    _halTripStartTripA = _heldValue('trip_a', _coreHold); // may be null early
    // v0.1.29+103: reset the distance accumulator / last-seen on trip start.
    _halTripDistAccumKm = 0;
    _halTripLastTripA = _halTripStartTripA;
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

  void _closeHalTrip({_HalStopSnapshot? asOf}) {
    // v0.1.29+91: persist the row BEFORE clearing state — finalize reads the
    // live getters/accumulators, which the resets below would wipe. The write
    // itself is async/best-effort and detached from this synchronous reset so
    // the lifecycle (and the stream) never blocks on the DB.
    // v0.1.29+101: asOf (when non-null) back-dates the end-state to the last
    // moving moment so a post-stop charge is excluded (variant A).
    _finalizeHalTripRow(asOf: asOf);
    _halTripActive = false;
    _halTripStartedAt = null;
    _halTripStartSoc = null;
    _halTripStartTripA = null;
    // v0.1.29+103: clear distance accumulator / last-seen on trip close.
    _halTripDistAccumKm = 0;
    _halTripLastTripA = null;
    _halTripStartOdo = null;
    _halParkConfirmStart = null;
    _halParkedSince = null;
    _halChargeConfirmStart = null;
    _halSpeedStartConfirmStart = null; // v0.1.29+104: clear speed-start clock
    _halLastMovingSnapshot = null;
    _halLastAliveFlush = null;         // v0.1.29+106: clear watchdog clock
    _resetHalTripAggregates();
    _halTripTick?.cancel();
    _halTripTick = null;
    _halTripDbId = null;
  }

  /// v0.1.29+106: snapshot of every HAL-trip aggregate, taken at one instant
  /// from the live getters/accumulators. Shared by the watchdog flush
  /// (touchTripAlive) and the final write (_finalizeHalTripRow) so both derive
  /// the SAME numbers — a watchdog snapshot then equals what a clean close
  /// would have written, and orphan recovery just stamps endedAt onto a row
  /// that already holds correct aggregates (no recompute, no fabrication).
  /// All fields nullable: anything HAL doesn't know stays null (honest).
  ///
  /// `asOf` (charge-onset close): when supplied, end SOC/odometer come from the
  /// last moving moment, not the live charging values — otherwise the charge
  /// inflates end_soc (the #45 bug: ended 4% but recorded 18%). Distance/energy
  /// derive from trip_a / start-SOC deltas captured while driving, so they stay
  /// correct; only the absolute end anchors need the back-date.
  _HalTripAgg _collectHalTripAggregates({_HalStopSnapshot? asOf}) {
    return (
      endSoc: asOf?.soc ?? halSocForTrip,
      endOdo: asOf?.odometerKm ?? _heldValue('odometer', _coreHold),
      distanceKm: halTripDistanceKm, // Δ trip_a (live display delta)
      energyKwh: halTripEnergyUsedKwh, // ΔSOC × capacity (EMA)
      consumption: halTripAvgConsumptionKwh100km,
      peakSpeed: _halPeakSpeedKmh,
      avgMoving: halTripCurrentAvgMovingKmh,
      // movingSeconds = seconds spent MOVING (speed > 1 km/h), NOT the full
      // trip duration — _halSpeedSamples is one increment per 1 s moving tick,
      // mirroring the OBD2 tracker's _tripMovingMs ~/ 1000. Trip duration is
      // derived by the UI from endedAt − startedAt, so it must NOT be written
      // here (writing full duration would show "[whole trip] / —" for the
      // moving/idle split, which is wrong).
      movingSecs: _halSpeedSamples > 0 ? _halSpeedSamples : null,
      idleSecs: _halIdleSeconds > 0 ? _halIdleSeconds : null,
      regenKwh: _halRegenEnergyKwh > 0 ? _halRegenEnergyKwh : null,
      minTemp: _halTripMinTempC,
      maxTemp: _halTripMaxTempC,
      maxSpread: _halTripMaxCellSpreadMv,
      minSoc: _halTripMinSoc,
      maxSoc: _halTripMaxSoc,
      peakPower: _halTripPeakPowerKw,
      peakRegen: _halTripPeakRegenKw,
    );
  }

  /// v0.1.29+91: write the HAL trip's final aggregates to its Trips row via
  /// db.endTrip — the SAME call the OBD2 tracker uses. Snapshots every value
  /// it needs synchronously (BEFORE _closeHalTrip's resets run), then fires
  /// the async write. No-op when there is no DB row (open failed / no DB).
  /// Any present field is written; anything the HAL tracker doesn't know
  /// stays null (honest — no fabricated values), exactly like an orphan
  /// recovery on the OBD2 side.
  void _finalizeHalTripRow({_HalStopSnapshot? asOf}) {
    final db = _diagDb;
    final id = _halTripDbId;
    if (db == null || id == null) return;
    // v0.1.29+106: collect the aggregate snapshot through the SHARED collector
    // so the watchdog flush (touchTripAlive) and this final write derive every
    // field identically — a recovered orphan then carries exactly what a clean
    // close would have. See _collectHalTripAggregates for the per-field notes.
    final a = _collectHalTripAggregates(asOf: asOf);
    // Fire-and-forget; a DB error must never disturb the stream/lifecycle.
    db
        .endTrip(
          id,
          endSoc: a.endSoc,
          endOdo: a.endOdo,
          distanceKm: a.distanceKm,
          energyUsedKwh: a.energyKwh,
          avgConsumptionKwh100km: a.consumption,
          minBatteryTempC: a.minTemp,
          maxBatteryTempC: a.maxTemp,
          maxCellSpreadMv: a.maxSpread,
          minSoc: a.minSoc,
          maxSoc: a.maxSoc,
          peakSpeedKmh: a.peakSpeed,
          peakPowerKw: a.peakPower,
          peakRegenKw: a.peakRegen,
          avgMovingSpeedKmh: a.avgMoving,
          movingSeconds: a.movingSecs,
          // v0.1.29+98: OBD2-parity fields — idle time and regen energy.
          idleSeconds: a.idleSecs,
          regenEnergyKwh: a.regenKwh,
          // v0.1.29+101: back-date the end time when closing because a charge
          // began (asOf = the stop). Null asOf → endTrip defaults to now, the
          // normal clean/park close.
          endedAt: asOf?.at,
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
        // v0.1.29+98: backfill sample_count from the hal_samples row count
        // for this trip. OBD2 increments sample_count per inserted sample; the
        // HAL per-sample stream lives in hal_samples, so the equivalent count
        // is read here (async, like the histogram) and written to the row.
        // Without this, HAL trips showed sample_count = 0 in history despite
        // thousands of hal_samples.
        .then((_) => db.countHalSamplesForTrip(id))
        .then((n) => db.updateTripSampleCount(id, n))
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
    // v0.1.29+98: reset the idle/regen accumulators for the new trip.
    _halIdleSeconds = 0;
    _halRegenEnergyKwh = 0;
  }

  // ── v0.1.29+105: HAL coulomb-counted SOH charge-state machine (Вариант A)
  //
  // Called every frame from _onEvent, INDEPENDENT of the trip machine. Mirrors
  // the UDS integral in connection.dart (_maintainChargingHistory +
  // _finalizeSohEstimate) but sources both the charge detection and the
  // current from HAL, so it works in halOnly with no dongle. Charge detection
  // reuses the +101 discriminator: stationary (speed ≈ 0) AND charge-level
  // current (pack_current < _kHalChargeCurrentA), held for _kHalChargeConfirm
  // — that rejects mid-drive regen (always moving) and brief glitches.
  //
  // Integration runs ∫|pack_current|·dt (Ah) every frame once a session is
  // confirmed. Coverage = liveSec / totalSec (a frame with no pack_current
  // contributes 0 Ah but still counts time, lowering coverage); a session
  // with too many gaps is discarded. On the charge→idle edge the session is
  // finalized (ΔSOC + coverage gates) and, if valid, written to id=2.
  void _updateHalCharge() {
    // v0.1.29+116: gate on OWNERSHIP (halOwnsTrip = stream live AND no
    // dongle), not display (halDriveActive) — the exact +106 rule the trip
    // machine already follows. The old halDriveActive gate additionally
    // required mode == halOnly; today init() migrates 'auto' to halOnly so
    // the practical gap is small, but the two machines must not diverge:
    // with a dongle the UDS integral in connection.dart owns SOH (id=1) and
    // this machine stands down; without one HAL owns it (id=2) in ANY mode.
    // If we were mid-session and ownership is lost (dongle plugged in, or
    // the stream died), finalize what we have (the gates will discard a
    // too-short one) and reset.
    if (!halOwnsTrip) {
      if (_halSohSessionAnchored) {
        if (_halSohCharging) _finalizeHalSohEstimate();
        _resetHalSohSession();
      }
      return;
    }

    final sp = halSpeedKmh;
    final pi = halValue('pack_current');
    final stationary = sp == null || sp <= _halMovingKmh;
    final chargingLevel = pi != null && pi < _kHalChargeCurrentA;
    final chargingNow = stationary && chargingLevel;

    if (chargingNow) {
      // Anchor on the FIRST charge-level frame so the start SOC and the
      // integral both begin at plug-in, not 20 s later. _halSohChargeConfirm
      // then gates VALIDITY (a brief glitch that doesn't last the debounce is
      // discarded on the next non-charging frame before it ever counts).
      //
      // v0.1.29+116: the anchor now WAITS for a live SOC. pack_current flows
      // within ~a second of stream start, but SOC can take up to ~30 s
      // (soc_precise) — the same lag the trip machine documents. Anchoring
      // with a null SOC latched _halSohStartSoc = null PERMANENTLY, and
      // _finalizeHalSohEstimate then silently discarded the whole session —
      // exactly what killed the 3 Jul field run (app restarted mid-charge,
      // 26→68% DC session, no SOH). Deferring the anchor keeps Ah and ΔSOC
      // starting at the SAME instant, so the estimate stays unbiased; the
      // few seconds of charge lost before SOC arrives shrink the window,
      // never skew it.
      final now = DateTime.now();
      if (!_halSohSessionAnchored) {
        final anchorSoc = halSocForTrip;
        if (anchorSoc == null) return; // SOC not up yet — retry next frame
        _halSohSessionAnchored = true;
        _halSohChargeConfirmStart = now;
        _halSohStartedAt = now;
        _halSohStartSoc = anchorSoc;
        _halSohChargeAhAccum = 0.0;
        _halSohLastIntegrationAt = now; // seed only; first dt next frame
        _halSohCoverageLiveSec = 0.0;
        _halSohCoverageTotalSec = 0.0;
        return;
      }

      // Promote anchored → confirmed once the debounce has elapsed. This flag
      // only marks that the session is now trusted; integration has been
      // running since the anchor frame regardless.
      if (!_halSohCharging &&
          _halSohChargeConfirmStart != null &&
          now.difference(_halSohChargeConfirmStart!) >= _kHalChargeConfirm) {
        _halSohCharging = true;
      }

      // Integrate ∫|I|·dt every frame from the anchor onward.
      if (_halSohLastIntegrationAt != null) {
        final dtSec =
            now.difference(_halSohLastIntegrationAt!).inMilliseconds / 1000.0;
        // Guard clock weirdness / suspends: ignore non-positive or > 30 s gaps
        // (same bound as the UDS integral — a long gap isn't trustworthy to
        // interpolate across).
        if (dtSec > 0 && dtSec <= 30.0) {
          _halSohCoverageTotalSec += dtSec;
          // pi is guaranteed non-null here (chargingLevel), but re-read defen-
          // sively in case a frame without it slips through a future edit.
          final i = halValue('pack_current');
          if (i != null) {
            _halSohChargeAhAccum += i.abs() * dtSec / 3600.0;
            _halSohCoverageLiveSec += dtSec;
          }
        }
      }
      _halSohLastIntegrationAt = now;

      // v0.1.29+116: crash-safe snapshot. Once the session is CONFIRMED,
      // persist its running state every _kHalSohPersistEvery so a process
      // death (ignition off / car locked mid- or right after a charge — the
      // realistic DC flow) loses at most the last 30 s of the window instead
      // of the whole session. Consumed by _recoverPendingSohSession() on the
      // next init(); cleared on any clean finalize/reset. Anchored-but-not-
      // confirmed sessions are never persisted — a glitch must not survive
      // a restart.
      if (_halSohCharging &&
          (_halSohLastPersistAt == null ||
              now.difference(_halSohLastPersistAt!) >=
                  _kHalSohPersistEvery)) {
        _halSohLastPersistAt = now;
        unawaited(_persistPendingSohSession());
      }
    } else {
      // Not charging this frame. If a session was anchored, the charge has
      // ended (unplugged / driving away). Finalize only if it ever confirmed
      // past the debounce; either way reset so the next charge starts clean.
      // A glitch that anchored but never confirmed is dropped silently.
      if (_halSohSessionAnchored) {
        if (_halSohCharging) _finalizeHalSohEstimate();
        _resetHalSohSession();
      }
    }
  }

  /// Compute + persist the HAL SOH from the just-finished charge session, to
  /// soh_estimates id=2 (source 'hal'). Discards the session unless the SOC
  /// span and current-coverage gates both pass. Mirrors
  /// ConnectionService._finalizeSohEstimate exactly, but on HAL data.
  void _finalizeHalSohEstimate() {
    final startSoc = _halSohStartSoc;
    if (startSoc == null) return;
    final curSoc = halSocForTrip;
    if (curSoc == null) return;
    _storeHalSohIfValid(
      startSoc: startSoc,
      endSoc: curSoc,
      chargeAh: _halSohChargeAhAccum,
      liveSec: _halSohCoverageLiveSec,
      totalSec: _halSohCoverageTotalSec,
    );
  }

  /// v0.1.29+116: the gate + store half of the old _finalizeHalSohEstimate,
  /// split out so the crash-recovery path (_recoverPendingSohSession) runs
  /// the EXACT same ΔSOC / coverage / sanity gates and the same id=2 write
  /// as a live finalize — one rule set, two entry points.
  void _storeHalSohIfValid({
    required double startSoc,
    required double endSoc,
    required double chargeAh,
    required double liveSec,
    required double totalSec,
  }) {
    final deltaSocPct = endSoc - startSoc;
    // v0.1.29+119: gate failures now clear the pending snapshot EXPLICITLY
    // (it used to happen in _resetHalSohSession) — a discarded session is
    // void and must not resurrect at the next startup. The single valid
    // path below, in contrast, keeps the snapshot alive until the DB write
    // is CONFIRMED.
    final bool gatesPass = deltaSocPct >= _kHalSohMinDeltaSocPct &&
        totalSec > 0 &&
        (liveSec / totalSec) >= _kHalSohMinCoverage &&
        chargeAh > 0;
    if (!gatesPass) {
      unawaited(_clearPendingSohSession());
      return;
    }
    final fullAh = chargeAh / (deltaSocPct / 100.0);
    final sohPct = fullAh / _halSohPackCapacityAh * 100.0;
    // Sanity clamp — outside this band means a bad session, so drop it.
    if (sohPct < 50.0 || sohPct > 110.0) {
      unawaited(_clearPendingSohSession());
      return;
    }
    _halSohAhPctCached = sohPct;
    final db = _diagDb;
    if (db == null) {
      // No DB this run: the RAM cache is all we have. Keep the pending
      // snapshot — next-startup recovery is then the only persistence path.
      notifyListeners();
      return;
    }
    // v0.1.29+119 (BZ3 field bug, "SOH сбрасывается на старый"): the +116..
    // +118 code fired this upsert unawaited AND _resetHalSohSession cleared
    // the crash snapshot immediately after. Ignition-off in that window
    // (charge just ended → driver leaves → head unit killed) lost BOTH the
    // write and the safety net, so the next run hydrated the OLD id=2 row.
    // Order guarantee now: upsert first, snapshot cleared only after the
    // write lands; if the write never completes, the snapshot survives and
    // _recoverPendingSohSession recomputes the same estimate at next init.
    unawaited(() async {
      try {
        await db.upsertSohEstimate(
          sohAhPct: sohPct,
          computedAt: DateTime.now(),
          deltaSocCovered: deltaSocPct,
          rowId: 2,
          source: 'hal',
        );
        debugPrint('HalSoh: id=2 upsert landed '
            '(${sohPct.toStringAsFixed(1)}%, ΔSOC '
            '${deltaSocPct.toStringAsFixed(1)}%)');
        // v0.1.31+130 (Trends v2): append the same estimate to the
        // soh_history time series. Placement matters: AFTER the upsert
        // landed (so history never leads the dashboard), BEFORE the
        // snapshot cleanup (inside the +119 ordered section). Guarded
        // separately — a history failure must NOT abort the cleanup below
        // or the recovery path would replay forever; the recovery re-write
        // of the same session is deduped inside appendSohHistory itself.
        try {
          await db.appendSohHistory(
            sohAhPct: sohPct,
            computedAt: DateTime.now(),
            deltaSocCovered: deltaSocPct,
            source: 'hal',
          );
        } catch (e) {
          debugPrint('HalSoh: history append failed ($e) — non-fatal');
        }
        // Clear the snapshot ONLY if no new session anchored while this
        // write was in flight — a live session owns the key now (its 30 s
        // persist cadence refreshes it), and deleting it here would strip
        // that session's crash safety. Worst case of skipping: a stale
        // snapshot of THIS (already written) session survives and is
        // re-recovered once at next startup — same value, idempotent
        // id=2 upsert, harmless.
        if (!_halSohSessionAnchored) {
          await _clearPendingSohSession();
        }
      } catch (e) {
        // Keep the cache AND the pending snapshot — recovery next start.
        debugPrint('HalSoh: id=2 upsert failed ($e), '
            'pending snapshot kept for recovery');
      }
    }());
    notifyListeners();
  }

  /// v0.1.29+116: snapshot the CONFIRMED in-flight session to prefs so a
  /// process death mid-charge doesn't lose it. Best-effort — a failed write
  /// just means recovery has a staler (or no) snapshot.
  Future<void> _persistPendingSohSession() async {
    final startSoc = _halSohStartSoc;
    final curSoc = halSocForTrip;
    if (startSoc == null || curSoc == null) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
          _kHalSohPendingKey,
          jsonEncode(<String, Object>{
            'start_soc': startSoc,
            'last_soc': curSoc,
            'ah': _halSohChargeAhAccum,
            'live_sec': _halSohCoverageLiveSec,
            'total_sec': _halSohCoverageTotalSec,
            'saved_at': DateTime.now().toIso8601String(),
          }));
    } catch (_) {/* best-effort */}
  }

  /// v0.1.29+116: drop the pending snapshot. Called from _resetHalSohSession
  /// — by then the session has either been finalized through the normal gates
  /// or intentionally discarded, so the snapshot must not outlive it.
  Future<void> _clearPendingSohSession() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_kHalSohPendingKey);
    } catch (_) {/* best-effort */}
  }

  /// v0.1.29+116: consume a session snapshot left by a process death and, if
  /// it passes the standard gates, store it as the HAL SOH (id=2). Runs once
  /// per startup from init(), AFTER loadHalSohEstimate (so hydration can't
  /// clobber a fresher recovered value) and BEFORE the stream starts (so a
  /// new session can't race the snapshot). The snapshot is removed up front —
  /// whatever the outcome, it must be consumed exactly once. The recovered
  /// window ends at the last snapshot (≤ _kHalSohPersistEvery before the
  /// kill): Ah and last_soc were captured at the same instant, so the
  /// estimate stays unbiased — the tail of the charge is simply not counted.
  Future<void> _recoverPendingSohSession() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_kHalSohPendingKey);
      if (raw == null) return;
      await prefs.remove(_kHalSohPendingKey);
      final m = jsonDecode(raw) as Map<String, dynamic>;
      final startSoc = (m['start_soc'] as num?)?.toDouble();
      final lastSoc = (m['last_soc'] as num?)?.toDouble();
      final ah = (m['ah'] as num?)?.toDouble();
      final liveSec = (m['live_sec'] as num?)?.toDouble();
      final totalSec = (m['total_sec'] as num?)?.toDouble();
      if (startSoc == null ||
          lastSoc == null ||
          ah == null ||
          liveSec == null ||
          totalSec == null) {
        return;
      }
      _storeHalSohIfValid(
        startSoc: startSoc,
        endSoc: lastSoc,
        chargeAh: ah,
        liveSec: liveSec,
        totalSec: totalSec,
      );
    } catch (_) {/* corrupt / unreadable snapshot — drop silently */}
  }

  /// Clear the HAL SOH session state for the next charge.
  void _resetHalSohSession() {
    _halSohCharging = false;
    _halSohSessionAnchored = false;
    _halSohChargeConfirmStart = null;
    _halSohStartedAt = null;
    _halSohStartSoc = null;
    _halSohChargeAhAccum = 0.0;
    _halSohLastIntegrationAt = null;
    _halSohCoverageLiveSec = 0.0;
    _halSohCoverageTotalSec = 0.0;
    _halSohLastPersistAt = null;
    // v0.1.29+119: reset NO LONGER clears the pending snapshot. Ownership
    // moved to the two consumers: _storeHalSohIfValid clears it on gate
    // failure or after a CONFIRMED db write (keeping it when the write
    // fails or the process dies first), and _recoverPendingSohSession
    // consumes it at startup. Clearing here raced the unawaited upsert —
    // the +118 field bug where a corrected SOH reverted on the next trip.
    // Every path into this reset goes through finalize-or-discard first,
    // so the key is never left owning stale data by skipping the clear.
  }

  /// v0.1.29+105: hydrate the cached HAL SOH (id=2) from the DB at startup so
  /// the dashboard shows the last computed value before any new session.
  /// Best-effort — a missing/un-migrated DB just leaves the cache null and the
  /// UI falls through to the UDS estimate / BMS.
  Future<void> loadHalSohEstimate() async {
    // v0.1.29+116: never clobber a value already computed THIS run — the
    // crash-recovery path (_recoverPendingSohSession) fills the cache before
    // this hydration runs, and its DB upsert is fire-and-forget, so reading
    // the DB here could still see the OLD row and silently roll the fresher
    // recovered estimate back.
    if (_halSohAhPctCached != null) return;
    final db = _diagDb;
    if (db == null) return;
    try {
      final row = await db.getLatestSohEstimate(rowId: 2);
      if (row != null) {
        _halSohAhPctCached = row.sohAhPct;
        debugPrint('HalSoh: hydrated id=2 → '
            '${row.sohAhPct.toStringAsFixed(1)}% '
            '(computed ${row.computedAt.toIso8601String()})');
      } else {
        debugPrint('HalSoh: no stored id=2 estimate — '
            'display falls through to live BMS/UDS');
      }
    } catch (_) {/* no DB / not migrated yet — stay on fallback */}
  }

  /// v0.1.29+91: fold the current frame into the trip min/max accumulators
  /// (temp, cell spread, SOC, peak power/regen) so db.endTrip writes a row
  /// as complete as the OBD2 one. Called from _updateHalTrip while a trip is
  /// live; reads only held values, so it's cheap. Each field self-guards on
  /// availability — a missing signal simply doesn't update its accumulator.
  void _accumulateHalTripStats() {
    // v0.1.29+101: do not fold stats while stationary AND charging. A charge
    // that begins after the car stops (before the charge-onset close fires
    // its debounce) would otherwise inflate max_soc / temp into the trip
    // (the #45 symptom: 18% max on a trip that ended at 4%). Driving regen is
    // unaffected — this guard only trips when speed ≈ 0 and current is
    // charge-level, i.e. a genuine plugged-in charge, never mid-drive regen.
    final sp = halSpeedKmh;
    final pi = halValue('pack_current');
    final stationaryCharging = (sp == null || sp <= _halMovingKmh) &&
        pi != null &&
        pi < _kHalChargeCurrentA;
    if (stationaryCharging) return;
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
    } else {
      // v0.1.29+98: stationary-but-Ready second → idle time, the OBD2 parity
      // counterpart of _halSpeedSamples (moving seconds). The trip tick only
      // runs while a trip is active, so every non-moving tick is genuine idle.
      _halIdleSeconds++;
    }
    // v0.1.29+98: integrate regen energy (negative power) over this 1 s tick.
    // kW × (1 s / 3600) = kWh. Stored as a positive magnitude to match the
    // OBD2 _tripRegenEnergyKwh column and the way the UI renders regen energy.
    final pw = halPowerKw;
    if (pw != null && pw < 0) {
      _halRegenEnergyKwh += (-pw) / 3600.0;
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
  /// v0.1.29+111/+112: the History screens also select() on this to refresh
  /// their trips list the moment a dongle-free trip opens/closes. (+112:
  /// +111 accidentally added a DUPLICATE of this getter near halOwnsTrip —
  /// missed that this one already existed — which broke compilation; the
  /// duplicate is gone, this original serves both consumers.)
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
      if (cur != null) {
        _halTripStartTripA = cur;
        _halTripLastTripA = cur;
      }
      return cur != null ? 0.0 : null;
    }
    if (cur == null) return null;
    // v0.1.29+103: native trip_a was reset under us (dropped below the
    // latched start by more than noise). Bank the distance driven up to the
    // reset (last seen − start) and re-latch the start to the new low value
    // so counting resumes from the new zero. ε guards against trip_a jitter
    // triggering a false re-anchor. The kilometres already driven are kept
    // in the accumulator, so distance never regresses to zero.
    const double kEpsKm = 0.05;
    if (cur < start - kEpsKm) {
      final lastBeforeReset = _halTripLastTripA ?? start;
      final banked = lastBeforeReset - start;
      if (banked > 0) _halTripDistAccumKm += banked;
      _halTripStartTripA = cur;
      _halTripLastTripA = cur;
      return _halTripDistAccumKm;
    }
    _halTripLastTripA = cur;
    return _halTripDistAccumKm + (cur - start);
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
    // v0.1.32+131: UI SOC source. Missing pref → display (cluster match).
    _socSource = _socSourceFromString(prefs.getString('soc_source'));
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
    // v0.1.29+116: consume any SOH session snapshot left by a process death
    // (ignition off mid-charge). MUST run before _startStream — once frames
    // flow, a new session's reset would clear the pending key before it is
    // read. Writes the recovered value to the cache + DB; the hydration
    // below is guarded so it can't clobber this fresher value.
    await _recoverPendingSohSession();
    // Start the stream unless the user pinned OBD2-only. On a phone the
    // platform returns null and we simply stay on OBD2 — no harm.
    if (_mode != HalSourceMode.obd2Only) {
      await _startStream();
    }
    // v0.1.29+91: prime the cumulative drive-energy cell from existing trips.
    await refreshTotalDriveEnergy();
    // v0.1.29+105: hydrate the cached HAL SOH (id=2) so the dashboard shows
    // the last computed value before any new charge session this run.
    await loadHalSohEstimate();
    notifyListeners();
  }

  /// v0.1.32+131: persist + broadcast the UI SOC source. Applies without
  /// a restart — every consumer resolves through resolveUiSocPct inside a
  /// widget that already watches this service, so notifyListeners is the
  /// whole live-apply mechanism (same contract as setMode).
  Future<void> setSocSource(SocSource s) async {
    if (s == _socSource) return;
    _socSource = s;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('soc_source', _socSourceToString(s));
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
    // v0.1.29+105: same for the SOH charge session — finalize what we have
    // (the gates discard a too-short one) and reset so a stopped stream never
    // leaves a session dangling. _onEvent won't tick once the stream is down,
    // so this is the only place a mid-charge stop gets cleaned up. Finalize
    // only if the session confirmed past the debounce.
    if (_halSohSessionAnchored) {
      if (_halSohCharging) _finalizeHalSohEstimate();
      _resetHalSohSession();
    }
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
    // v0.1.39+138: periodic HAL snapshot — same event path, own 60-s gate
    // inside (no new timers). Restores the snapshots plane that died on
    // 2026-06-24 with the move to HAL-only (OBD2 ConnectionService was
    // the only snapshot writer; HAL never wrote any).
    _maybeWriteHalSnapshot();
    // No notifyListeners() per event — at ~15 Hz aggregate that would
    // over-rebuild. The widgets already rebuild on the OBD2
    // ConnectionService poll cadence; the resolvers read our latest
    // values at paint time. A coalesced notify keeps displays lively
    // without flooding.
    // v0.1.29+85/+86: drive the HAL trip state machine off the same frames
    // (cheap — it only reads held values). Start fires on gear≠Park alone;
    // the start SOC latches later on the first soc_precise/integer frame.
    _updateHalTrip();
    // v0.1.29+105: drive the independent HAL SOH charge-state machine off the
    // same frames, ALONGSIDE the trip machine (not inside it) — a charge runs
    // after the trip has closed, so this must tick regardless of trip state.
    _updateHalCharge();
    _scheduleNotify();
  }

  // ── HAL diagnostic logging (+87/+88) ──
  //
  // v0.1.39+138: periodic HAL snapshot writer state. Cadence gate lives
  // inside _maybeWriteHalSnapshot (pattern of _halDiagThrottle below).
  static const Duration _halSnapshotEvery = Duration(seconds: 60);
  DateTime? _lastHalSnapshotAt;
  int _halSnapshotsWritten = 0;

  /// v0.1.39+138: app_diag observability.
  DateTime? get lastHalSnapshotAt => _lastHalSnapshotAt;
  int get halSnapshotsWritten => _halSnapshotsWritten;

  /// v0.1.39+138: write one snapshots row from live HAL values, at most
  /// once per [_halSnapshotEvery]. Ordered gates, each a silent return:
  /// db → running → dongle → cadence → min-fields. Dongle present means
  /// the OBD2 ConnectionService owns the snapshots plane (its two write
  /// sites in connection.dart) — we stay silent so the two writers can
  /// never double-write. insertSnapshot injects clientUuid, so cloud
  /// push (_syncSnapshots) and phone pull pick these up with zero sync
  /// changes. Charging comes free: the stream is alive on charge, so
  /// isCharging/chargingPowerKw land in the same rows. gear stays NULL
  /// on purpose — halGear is gear_enum, a different encoding than the
  /// OBD2 raw 791/0009 this column historically holds; do not mix.
  void _maybeWriteHalSnapshot() {
    final db = _diagDb;
    if (db == null) return;
    if (!_running) return;
    if (_dongleConnected?.call() == true) return;
    final now = DateTime.now();
    if (_lastHalSnapshotAt != null &&
        now.difference(_lastHalSnapshotAt!) < _halSnapshotEvery) {
      return;
    }
    final soc = halSocPct;
    final packV = halPackVoltage;
    if (soc == null && packV == null) return; // warm-up: no empty rows
    final cellLo = halCellVLowest;
    final cellHi = halCellVHighest;
    _lastHalSnapshotAt = now;
    unawaited(() async {
      try {
        await db.insertSnapshot(SnapshotsCompanion(
          capturedAt: Value(now),
          soc: Value(soc),
          soh: Value(halSoh),
          batteryTempC: Value(halBatteryTempC),
          cellVoltageMin:
              Value(cellLo == null ? null : (cellLo * 1000).roundToDouble()),
          cellVoltageMax:
              Value(cellHi == null ? null : (cellHi * 1000).roundToDouble()),
          cellSpread: Value(halCellSpreadMv),
          odometer: Value(halOdometerKm),
          tripId: Value(_halTripDbId),
          packVoltageV: Value(packV),
          isCharging: Value(halChargingActive),
          chargingPowerKw: Value(halChargePowerKw),
        ));
        _halSnapshotsWritten++;
      } catch (e) {
        debugPrint('HAL snapshot write failed: $e');
      }
    }());
  }

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

/// v0.1.29+101: immutable snapshot of the trip's end-state as of the last
/// moving moment, used to back-date a charge-onset close to the stop
/// (variant A) so a charge that begins after the car parks never flows into
/// the trip's end_soc / distance / energy. Captured each tick while moving;
/// consumed by the charge-onset branch of _updateHalTrip.
class _HalStopSnapshot {
  final DateTime at;
  final double? soc;
  final double? odometerKm;
  const _HalStopSnapshot({required this.at, this.soc, this.odometerKm});
}

/// v0.1.29+106: one HAL-trip aggregate snapshot. A Dart record (not a class)
/// to keep it lightweight — produced by _collectHalTripAggregates and consumed
/// by both the watchdog flush and the final endTrip write so the two agree
/// field-for-field. Every field nullable: unknown stays null (honesty rule).
typedef _HalTripAgg = ({
  double? endSoc,
  double? endOdo,
  double? distanceKm,
  double? energyKwh,
  double? consumption,
  double? peakSpeed,
  double? avgMoving,
  int? movingSecs,
  int? idleSecs,
  double? regenKwh,
  double? minTemp,
  double? maxTemp,
  double? maxSpread,
  double? minSoc,
  double? maxSoc,
  double? peakPower,
  double? peakRegen,
});
