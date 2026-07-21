// v0.1.52+151 «Замеры» — speed-profile sessions (consumption per speed
// band + automatic 0–100 stopwatch). SPEC_plus151_speed_profile.md v1.2.
//
// Data path: this service is a PASSIVE observer of the existing HAL
// stream — it subscribes through HalTelemetryService.rawEvents and
// brackets the subscription with retainStream()/releaseStream(),
// exactly the HAL Test path, so it never owns or restarts the native
// subscription and never touches the vendored Kotlin. No new channels.
// connection.dart is never imported (AA2), no Drift schema changes —
// everything persists to SharedPreferences JSON (crash-safe pattern of
// the +116 SOH session: 30 s snapshots + one on stream stop).
//
// Honesty rules carried over from the spec:
//   • band detection runs on the DASH speed (the number the driver
//     thinks in); distance/energy integrate the REAL speed
//     (dash × kSpeedRealFactor) — Alex's field calibration says the
//     cluster reads ~2% high;
//   • power is the FULL vehicle draw |V×I| (traction + climate +
//     electronics) — the table answers "what does it really cost to
//     hold 100", not "clean traction";
//   • a band with no data does not exist (no zero rows);
//   • regen/coast ticks (P ≤ 0) are never written;
//   • pack temperature is session METADATA, not a season classifier —
//     a heated LFP pack shows plus in winter, a binary label would lie
//     exactly on the target sessions.

import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'diag_dump_file.dart';
import 'hal_telemetry_channel.dart';
import 'hal_telemetry_service.dart';

/// Steady-state gate: |acceleration| must stay under this (km/h per
/// second) for a tick to count into a band. A named constant on
/// purpose — field tuning knob (spec Q2). Field calibration 21.07
/// (+154): 1.5 → 2.5 — at the real ~2.5 Hz speed cadence the honest
/// «держу 40» wander reads as 1.5–2 km/h/s and 1.5 starved the bands
/// (79% of ticks rejected); real launches live at 5–8 km/h/s, so 2.5
/// still separates cleanly.
const double kSteadyAccelMax = 2.5;

/// Cluster-to-real speed correction (dash reads ~2% high; Alex's
/// measurement, spec §2). Bands detect on dash speed, distance and the
/// 0–100 finish line use real speed (finish at dash × factor ≥ 100).
const double kSpeedRealFactor = 0.98;

/// Band shape: round tens, ±3 km/h dash window, 40…180 range. A band
/// materialises only after `kBandMinSeconds` of qualified time
/// (+154: 60 → 120 s — Alex's call: a two-minute floor makes a row
/// statistically worth trusting before it starts promising range).
const int kBandHalfWidthKmh = 3;
const int kBandMinKmh = 40;
const int kBandMaxKmh = 180;
const double kBandMinSeconds = 120.0;

/// Integration guard: stream gaps longer than this are not integrated
/// (dt-гард, same idea as the trip integrators).
const double kDtGuardS = 2.0;

/// A session forgotten for this long without any movement stops
/// itself: an idle-but-active session would hold the native stream
/// retained and grind a prefs snapshot every 30 s forever. The session
/// body is NOT discarded — it stays in place as «остановлена — можно
/// сохранить», only the recording ends.
const int kAutoStopIdleDays = 7;

/// Accumulators of one speed band. Additive by design (spec Q1): every
/// qualified stretch of the session sums into the same three numbers.
class SpeedBandAgg {
  double energyKwh;
  double distKm;
  double timeS;

  SpeedBandAgg({this.energyKwh = 0, this.distKm = 0, this.timeS = 0});

  /// kWh/100km over everything accumulated so far; null until any
  /// distance exists (never render a fake zero).
  double? get consumptionKwh100 =>
      distKm > 1e-6 ? energyKwh / distKm * 100.0 : null;

  Map<String, dynamic> toJson() =>
      {'e': energyKwh, 'd': distKm, 't': timeS};

  static SpeedBandAgg fromJson(Map<String, dynamic> j) => SpeedBandAgg(
        energyKwh: (j['e'] as num?)?.toDouble() ?? 0,
        distKm: (j['d'] as num?)?.toDouble() ?? 0,
        timeS: (j['t'] as num?)?.toDouble() ?? 0,
      );
}

/// One completed 0–100 run (real km/h), seconds interpolated on both
/// ends (launch threshold crossing and the real-100 crossing).
class ZeroTo100Run {
  final int tsMs;
  final double seconds;
  const ZeroTo100Run(this.tsMs, this.seconds);

  Map<String, dynamic> toJson() => {'ts': tsMs, 's': seconds};
  static ZeroTo100Run fromJson(Map<String, dynamic> j) => ZeroTo100Run(
      (j['ts'] as num).toInt(), (j['s'] as num).toDouble());
}

/// TEMP DIAG (+153): per-session tick-gate counters. One field per
/// rejection reason (first failing gate wins), so one drive names the
/// gate that eats ticks. REMOVE after the field diagnosis — the user
/// never needs these; the permanent progress UX is maturingBands.
class TickDiag {
  int total; // integration ticks entering the band pipeline
  int noAccel; // accel window not filled yet (null)
  int accelHigh; // |a| > kSteadyAccelMax
  int outOfBand; // dash speed outside every ±3 round-ten window
  int powerStale; // V/I freshness gate failed (P null)
  int powerNonPos; // P <= 0 (regen/coast)
  int qualified;

  TickDiag({
    this.total = 0,
    this.noAccel = 0,
    this.accelHigh = 0,
    this.outOfBand = 0,
    this.powerStale = 0,
    this.powerNonPos = 0,
    this.qualified = 0,
  });

  Map<String, dynamic> toJson() => {
        'tot': total,
        'na': noAccel,
        'ah': accelHigh,
        'ob': outOfBand,
        'ps': powerStale,
        'pn': powerNonPos,
        'q': qualified,
      };

  static TickDiag fromJson(Map<String, dynamic> j) => TickDiag(
        total: (j['tot'] as num?)?.toInt() ?? 0,
        noAccel: (j['na'] as num?)?.toInt() ?? 0,
        accelHigh: (j['ah'] as num?)?.toInt() ?? 0,
        outOfBand: (j['ob'] as num?)?.toInt() ?? 0,
        powerStale: (j['ps'] as num?)?.toInt() ?? 0,
        powerNonPos: (j['pn'] as num?)?.toInt() ?? 0,
        qualified: (j['q'] as num?)?.toInt() ?? 0,
      );
}

/// Whole-session state — bands, 0–100 runs, total distance (for the
/// auto-name) and the pack-temperature passport (U4).
class SpeedProfileSession {
  int startedAtMs;

  /// Last time the car actually moved (dash ≥ 2 km/h) — feeds the idle
  /// auto-stop. Persists with the session so a head-unit restart does
  /// not reset the idle clock.
  int lastMoveMs;

  final Map<int, SpeedBandAgg> bands;
  final List<ZeroTo100Run> runs;
  double totalDistKm;

  // U4 temperature passport (dt-weighted mean; min/max; share <10°).
  double? tempMinC;
  double? tempMaxC;
  double tempWeightedSum; // Σ t·dt
  double tempTimeS; // Σ dt with a fresh temp reading
  double tempBelow10S;

  /// TEMP DIAG (+153) — remove with the counters.
  TickDiag diag;

  SpeedProfileSession({
    required this.startedAtMs,
    int? lastMoveMs,
    Map<int, SpeedBandAgg>? bands,
    List<ZeroTo100Run>? runs,
    this.totalDistKm = 0,
    this.tempMinC,
    this.tempMaxC,
    this.tempWeightedSum = 0,
    this.tempTimeS = 0,
    this.tempBelow10S = 0,
    TickDiag? diag,
  })  : lastMoveMs = lastMoveMs ?? startedAtMs,
        bands = bands ?? {},
        runs = runs ?? [],
        diag = diag ?? TickDiag();

  static SpeedProfileSession fresh() => SpeedProfileSession(
      startedAtMs: DateTime.now().millisecondsSinceEpoch);

  double? get bestZeroTo100 {
    double? best;
    for (final r in runs) {
      if (best == null || r.seconds < best) best = r.seconds;
    }
    return best;
  }

  /// dt-weighted mean pack temperature, or null if never seen.
  double? get tempMeanC =>
      tempTimeS > 1e-6 ? tempWeightedSum / tempTimeS : null;

  /// "Cold pack" badge: >30% of temp-covered time under 10 °C (U4).
  bool get coldPack =>
      tempTimeS > 1e-6 && tempBelow10S / tempTimeS > 0.30;

  /// Bands that earned their table row (≥ kBandMinSeconds of qualified
  /// time), sorted ascending. Everything below the threshold stays
  /// invisible — no data ≠ zero.
  List<int> get visibleBands {
    final keys = bands.entries
        .where((e) => e.value.timeS >= kBandMinSeconds)
        .map((e) => e.key)
        .toList()
      ..sort();
    return keys;
  }

  /// Bands accumulating but not yet past the 60 s threshold — the
  /// permanent «полоса зреет» progress UX: the user must SEE the
  /// process even before a row earns its place.
  List<int> get maturingBands {
    final keys = bands.entries
        .where((e) => e.value.timeS > 0 && e.value.timeS < kBandMinSeconds)
        .map((e) => e.key)
        .toList()
      ..sort();
    return keys;
  }

  Map<String, dynamic> toJson() => {
        'startedAtMs': startedAtMs,
        'lastMoveMs': lastMoveMs,
        'bands': bands.map((k, v) => MapEntry(k.toString(), v.toJson())),
        'runs': runs.map((r) => r.toJson()).toList(),
        'totalDistKm': totalDistKm,
        'tempMinC': tempMinC,
        'tempMaxC': tempMaxC,
        'tempWeightedSum': tempWeightedSum,
        'tempTimeS': tempTimeS,
        'tempBelow10S': tempBelow10S,
        'diag': diag.toJson(),
      };

  static SpeedProfileSession fromJson(Map<String, dynamic> j) {
    final rawBands = (j['bands'] as Map<String, dynamic>? ?? {});
    final bands = <int, SpeedBandAgg>{};
    rawBands.forEach((k, v) {
      final band = int.tryParse(k);
      if (band != null && v is Map<String, dynamic>) {
        bands[band] = SpeedBandAgg.fromJson(v);
      }
    });
    return SpeedProfileSession(
      startedAtMs: (j['startedAtMs'] as num?)?.toInt() ??
          DateTime.now().millisecondsSinceEpoch,
      lastMoveMs: (j['lastMoveMs'] as num?)?.toInt(),
      bands: bands,
      runs: (j['runs'] as List<dynamic>? ?? [])
          .whereType<Map<String, dynamic>>()
          .map(ZeroTo100Run.fromJson)
          .toList(),
      totalDistKm: (j['totalDistKm'] as num?)?.toDouble() ?? 0,
      tempMinC: (j['tempMinC'] as num?)?.toDouble(),
      tempMaxC: (j['tempMaxC'] as num?)?.toDouble(),
      tempWeightedSum: (j['tempWeightedSum'] as num?)?.toDouble() ?? 0,
      tempTimeS: (j['tempTimeS'] as num?)?.toDouble() ?? 0,
      tempBelow10S: (j['tempBelow10S'] as num?)?.toDouble() ?? 0,
      diag: j['diag'] is Map<String, dynamic>
          ? TickDiag.fromJson(j['diag'] as Map<String, dynamic>)
          : null,
    );
  }
}

/// An archived, named session (U3). Up to [SpeedProfileService.kArchiveMax]
/// entries; oldest is evicted with an explicit user confirmation.
class ArchivedSession {
  final String name;
  final String note;
  final int savedAtMs;
  final SpeedProfileSession session;
  const ArchivedSession({
    required this.name,
    required this.note,
    required this.savedAtMs,
    required this.session,
  });

  Map<String, dynamic> toJson() => {
        'name': name,
        'note': note,
        'savedAtMs': savedAtMs,
        'session': session.toJson(),
      };

  static ArchivedSession fromJson(Map<String, dynamic> j) =>
      ArchivedSession(
        name: j['name'] as String? ?? '',
        note: j['note'] as String? ?? '',
        savedAtMs: (j['savedAtMs'] as num?)?.toInt() ?? 0,
        session: SpeedProfileSession.fromJson(
            j['session'] as Map<String, dynamic>? ?? const {}),
      );
}

/// The service. Lifecycle: Старт → (drive, screen closed, ticks
/// accumulate) → Стоп → save-to-archive dialog / discard. A session
/// lives ACROSS trips and head-unit restarts until an explicit Стоп —
/// init() silently reattaches when the persisted `active` flag is set.
class SpeedProfileService extends ChangeNotifier {
  SpeedProfileService(this._hal);

  final HalTelemetryService _hal;

  static const String _kSessionKey = 'speed_profile_session';
  static const String _kActiveKey = 'speed_profile_active';
  static const String _kArchiveKey = 'speed_profile_archive';
  static const int kArchiveMax = 24;

  /// BZ5 pack capacity for the U1 "≈ N km per charge" line. A private
  /// copy on purpose — importing ConnectionService here would break the
  /// AA2 one-way rule (same pattern as _halPackCapacityKwh in the HAL
  /// service). Known limitation, out of +151 scope: BZ3 (49.92 kWh)
  /// would overstate the range; the tab is HU-only and this vehicle is
  /// a BZ5 (the +144/+129 plaque history).
  static const double _kPackCapacityKwh = 65.28;
  static double get packCapacityKwh => _kPackCapacityKwh;

  SpeedProfileSession? _session;
  bool _active = false;
  List<ArchivedSession> _archive = [];

  StreamSubscription<HalEvent>? _sub;
  Timer? _persistTimer;
  bool _retained = false;

  // ── tick state (not persisted; a 30 s tail is the accepted loss) ──
  int? _lastTickMs;
  final List<_SpeedFrame> _speedBuf = [];
  int _lastNotifyMs = 0;

  // ── 0–100 state machine ──
  _ZPhase _zPhase = _ZPhase.idle;
  int? _zBelowSinceMs;
  double? _zT0Ms;
  double _zPeakDash = 0;
  int? _zPrevMs;
  double? _zPrevDash;

  bool get active => _active;
  SpeedProfileSession? get session => _session;
  List<ArchivedSession> get archive => List.unmodifiable(_archive);
  bool get archiveFull => _archive.length >= kArchiveMax;

  /// Status-line helper: wall minutes since session start.
  int get sessionMinutes {
    final s = _session;
    if (s == null) return 0;
    return ((DateTime.now().millisecondsSinceEpoch - s.startedAtMs) /
            60000)
        .floor();
  }

  Future<void> init() async {
    final prefs = await SharedPreferences.getInstance();
    _active = prefs.getBool(_kActiveKey) ?? false;
    final rawSession = prefs.getString(_kSessionKey);
    if (rawSession != null) {
      try {
        _session = SpeedProfileSession.fromJson(
            jsonDecode(rawSession) as Map<String, dynamic>);
      } catch (_) {
        _session = null;
      }
    }
    final rawArchive = prefs.getString(_kArchiveKey);
    if (rawArchive != null) {
      try {
        _archive = (jsonDecode(rawArchive) as List<dynamic>)
            .whereType<Map<String, dynamic>>()
            .map(ArchivedSession.fromJson)
            .toList();
      } catch (_) {
        _archive = [];
      }
    }
    if (_active && _session != null) {
      // A week-idle session must not resurrect the retained stream on
      // boot — same rule as the running timer below (p.7).
      if (_idleTooLong(_session!)) {
        _active = false;
        await _persist();
      } else {
        // Crash / HU sleep / reinstall-free restart: the session
        // silently continues (spec §5). At most a 30-second tail was
        // lost.
        await _attach();
      }
    } else if (_active) {
      // Flag without a body — self-heal.
      _active = false;
      await _persist();
    }
    notifyListeners();
  }

  /// Старт — always a fresh session (a stopped-but-unsaved one is
  /// replaced; the save dialog already had its chance on Стоп).
  Future<void> start() async {
    if (_active) return;
    _session = SpeedProfileSession.fresh();
    _resetTickState();
    _active = true;
    await _attach();
    await _persist();
    notifyListeners();
  }

  /// Стоп — detach from the stream, keep the finished session in place
  /// so the UI can offer "save to archive". Returns it for convenience.
  Future<SpeedProfileSession?> stop() async {
    if (!_active) return _session;
    _active = false;
    await _detach();
    await _persist();
    notifyListeners();
    return _session;
  }

  /// Сброс — while recording: restart the accumulators in place (the
  /// stream stays up); while stopped: drop the unsaved session.
  Future<void> reset() async {
    if (_active) {
      _session = SpeedProfileSession.fresh();
      _resetTickState();
    } else {
      _session = null;
    }
    await _persist();
    notifyListeners();
  }

  /// Suggested archive name: «19.07 · 82 км[ · 28°]» (U3/U4 — the
  /// dt-weighted mean pack temp rides in the auto-name when known).
  String autoName() {
    final s = _session;
    if (s == null) return '';
    final d = DateTime.fromMillisecondsSinceEpoch(s.startedAtMs);
    final dd = d.day.toString().padLeft(2, '0');
    final mm = d.month.toString().padLeft(2, '0');
    final km = s.totalDistKm.round();
    final t = s.tempMeanC;
    final tempPart = t == null ? '' : ' · ${t.round()}°';
    return '$dd.$mm · $km км$tempPart';
  }

  /// Archive the finished session under [name]. When the archive is
  /// full the caller must have confirmed eviction ([evictOldest]);
  /// without confirmation a full archive refuses the save.
  Future<bool> saveToArchive(String name, String note,
      {bool evictOldest = false}) async {
    final s = _session;
    if (s == null || _active) return false;
    if (archiveFull) {
      if (!evictOldest) return false;
      var oldestIdx = 0;
      for (var i = 1; i < _archive.length; i++) {
        if (_archive[i].savedAtMs < _archive[oldestIdx].savedAtMs) {
          oldestIdx = i;
        }
      }
      _archive.removeAt(oldestIdx);
    }
    _archive.add(ArchivedSession(
      name: name.trim().isEmpty ? autoName() : name.trim(),
      note: note.trim(),
      savedAtMs: DateTime.now().millisecondsSinceEpoch,
      session: s,
    ));
    _session = null;
    await _persist();
    notifyListeners();
    return true;
  }

  Future<void> deleteArchived(int index) async {
    if (index < 0 || index >= _archive.length) return;
    _archive.removeAt(index);
    await _persist();
    notifyListeners();
  }

  /// TEMP DIAG (+153): dump the CURRENT session (raw band aggregates
  /// including sub-threshold ones, gate counters, 0–100 runs, temp
  /// passport) as a fenced JSON section into the proven diagnostic
  /// channel — bz5_companion_diag.md in public Downloads, the same
  /// file the Native Explorer diary uses and the same USB pickup
  /// workflow. The active constants ride along so the analysis knows
  /// which thresholds produced the numbers. Remove with the counters.
  Future<DiagDumpAppendResult?> dumpDiag() async {
    final s = _session;
    if (s == null) return null;
    final payload = <String, dynamic>{
      'schema': 'speed_profile_diag_v1',
      'dumped_at': DateTime.now().toIso8601String(),
      'active': _active,
      'constants': {
        'kSteadyAccelMax': kSteadyAccelMax,
        'kSpeedRealFactor': kSpeedRealFactor,
        'kBandHalfWidthKmh': kBandHalfWidthKmh,
        'kBandMinKmh': kBandMinKmh,
        'kBandMaxKmh': kBandMaxKmh,
        'kBandMinSeconds': kBandMinSeconds,
        'kDtGuardS': kDtGuardS,
        'packCapacityKwh': _kPackCapacityKwh,
      },
      'session': s.toJson(),
    };
    try {
      return await DiagDumpFile.instance.append(
        title: 'Замеры — диаг-дамп сессии',
        body: '```json\n${jsonEncode(payload)}\n```',
      );
    } catch (_) {
      return null;
    }
  }

  @override
  void dispose() {
    _sub?.cancel();
    _persistTimer?.cancel();
    if (_retained) {
      _retained = false;
      _hal.releaseStream();
    }
    super.dispose();
  }

  // ─────────────────────── stream plumbing ───────────────────────

  Future<void> _attach() async {
    _sub ??= _hal.rawEvents.listen(_onEvent, onError: (Object _) {});
    if (!_retained) {
      _retained = true;
      await _hal.retainStream();
    }
    _persistTimer ??= Timer.periodic(const Duration(seconds: 30), (_) {
      _maybeAutoStop();
      _persist();
    });
  }

  bool _idleTooLong(SpeedProfileSession s) =>
      DateTime.now().millisecondsSinceEpoch - s.lastMoveMs >
      kAutoStopIdleDays * 86400000;

  /// p.7 of the +151 review: an active session with no movement for
  /// [kAutoStopIdleDays] stops itself — releases the retained stream
  /// and the 30 s prefs grind. The accumulated body survives as a
  /// normal stopped session («остановлена — можно сохранить»).
  void _maybeAutoStop() {
    final s = _session;
    if (!_active || s == null) return;
    if (!_idleTooLong(s)) return;
    _active = false;
    _detach();
    _persist();
    notifyListeners();
  }

  Future<void> _detach() async {
    await _sub?.cancel();
    _sub = null;
    _persistTimer?.cancel();
    _persistTimer = null;
    if (_retained) {
      _retained = false;
      await _hal.releaseStream();
    }
    _resetTickState();
  }

  void _resetTickState() {
    _lastTickMs = null;
    _speedBuf.clear();
    _zPhase = _ZPhase.idle;
    _zBelowSinceMs = null;
    _zT0Ms = null;
    _zPeakDash = 0;
    _zPrevMs = null;
    _zPrevDash = null;
  }

  Future<void> _persist() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_kActiveKey, _active);
      final s = _session;
      if (s == null) {
        await prefs.remove(_kSessionKey);
      } else {
        await prefs.setString(_kSessionKey, jsonEncode(s.toJson()));
      }
      await prefs.setString(_kArchiveKey,
          jsonEncode(_archive.map((a) => a.toJson()).toList()));
    } catch (_) {
      // prefs failure is non-fatal — worst case the crash-safe tail
      // grows; never let persistence take the tick pipeline down.
    }
  }

  // ───────────────────────── tick pipeline ─────────────────────────

  /// Signed full-vehicle power in kW with the STRICT 6 s freshness gate
  /// (halFresh uses the continuous windows regardless of source mode —
  /// the charging-banner pattern). halPowerKw itself is NOT reused: in
  /// halOnly mode it sits behind the 90 s display hold, far too loose
  /// for integration. Discharge is positive (both signals are
  /// discharge-positive, same convention as the OBD2 C33 path).
  double? _freshPowerKw() {
    if (!_hal.halFresh('pack_voltage') ||
        !_hal.halFresh('pack_current')) {
      return null;
    }
    final v = _hal.halValue('pack_voltage');
    final i = _hal.halValue('pack_current');
    if (v == null || i == null) return null;
    return v * i / 1000.0;
  }

  /// Pack temperature with per-name freshness; probe first (8 s window,
  /// verified battery temp), BigData frame second (75 s window) — the
  /// same combined priority trip_detail charts use.
  double? _packTempC() {
    if (_hal.halFresh('probe_highest_temp')) {
      return _hal.halValue('probe_highest_temp');
    }
    if (_hal.halFresh('battery_temp_bigdata')) {
      return _hal.halValue('battery_temp_bigdata');
    }
    return null;
  }

  void _onEvent(HalEvent e) {
    if (!_active) return;
    final s = _session;
    if (s == null) return;
    if (e.name != 'speed') return;
    final vDash = e.value?.toDouble();
    if (vDash == null) return;

    // Wall clock over HalEvent.ts — the framework timestamp base is
    // unspecified (boot vs epoch); receipt time is uniform and the
    // stream is fast enough that transport jitter is noise at 1 s
    // acceleration windows and 2 s dt guards.
    final now = DateTime.now().millisecondsSinceEpoch;

    _speedBuf.add(_SpeedFrame(now, vDash));
    while (_speedBuf.length > 2 && now - _speedBuf.first.ms > 2000) {
      _speedBuf.removeAt(0);
    }

    // Steady-state slope — least squares over ALL buffer frames in a
    // ~2 s window (+154). Edge-to-edge was the +153 field failure: at
    // the real ~2.5 Hz cadence it stood on two samples, so an honest
    // ±1 km/h wander read as a launch and 79% of ticks died at the
    // accel gate. LSQ over every frame averages the jitter out while
    // a real ramp still shows its true slope. Null until the window
    // spans ≥400 ms — an unknown acceleration NEVER qualifies a tick
    // (no data ≠ steady).
    double? accelKmhPerS;
    if (_speedBuf.length >= 2 && now - _speedBuf.first.ms >= 400) {
      double sumT = 0, sumV = 0;
      final n = _speedBuf.length;
      for (final f in _speedBuf) {
        sumT += f.ms;
        sumV += f.v;
      }
      final meanT = sumT / n;
      final meanV = sumV / n;
      double sTT = 0, sTV = 0;
      for (final f in _speedBuf) {
        final dt = (f.ms - meanT).toDouble();
        sTT += dt * dt;
        sTV += dt * (f.v - meanV);
      }
      if (sTT > 0) accelKmhPerS = sTV / sTT * 1000.0;
    }

    final last = _lastTickMs;
    _lastTickMs = now;
    double? dtS;
    if (last != null) {
      final d = (now - last) / 1000.0;
      if (d > 0 && d <= kDtGuardS) dtS = d;
    }

    if (dtS != null) {
      // Total real distance — the auto-name «82 км» and nothing else.
      s.totalDistKm += vDash * kSpeedRealFactor * dtS / 3600.0;
      _accumTemp(s, dtS);
      _accumBand(s, vDash, accelKmhPerS, dtS);
    }

    // Idle clock for the auto-stop (p.7): any real movement resets it.
    if (vDash >= 2.0) s.lastMoveMs = now;

    _stepZeroTo100(s, vDash, now);

    // The screen may be open while recording — repaint at most 1/s so
    // a ~10 Hz speed stream doesn't burn the UI thread.
    if (now - _lastNotifyMs >= 1000) {
      _lastNotifyMs = now;
      notifyListeners();
    }
  }

  void _accumBand(SpeedProfileSession s, double vDash,
      double? accelKmhPerS, double dtS) {
    // Tick qualification — ALL gates at once (spec §3):
    //   1) dash speed inside a round-ten band window (±3);
    //   2) steady state: |a| ≤ kSteadyAccelMax over the ~1 s window;
    //   3) power > 0 — regen/coast is never written;
    //   4) V/I freshness ≤ 6 s (inside _freshPowerKw);
    //   5) dt ≤ 2 s (already guarded by the caller).
    // TEMP DIAG (+153): each rejection increments its counter (first
    // failing gate wins) — a single drive names the guilty gate.
    final d = s.diag;
    d.total++;
    if (accelKmhPerS == null) {
      d.noAccel++;
      return;
    }
    if (accelKmhPerS.abs() > kSteadyAccelMax) {
      d.accelHigh++;
      return;
    }
    final band = (vDash / 10.0).round() * 10;
    if (band < kBandMinKmh ||
        band > kBandMaxKmh ||
        (vDash - band).abs() > kBandHalfWidthKmh) {
      d.outOfBand++;
      return;
    }
    final p = _freshPowerKw();
    if (p == null) {
      d.powerStale++;
      return;
    }
    if (p <= 0) {
      d.powerNonPos++;
      return;
    }
    d.qualified++;

    final agg = s.bands.putIfAbsent(band, SpeedBandAgg.new);
    agg.energyKwh += p * dtS / 3600.0;
    agg.distKm += vDash * kSpeedRealFactor * dtS / 3600.0;
    agg.timeS += dtS;
  }

  void _accumTemp(SpeedProfileSession s, double dtS) {
    final t = _packTempC();
    if (t == null) return;
    if (s.tempMinC == null || t < s.tempMinC!) s.tempMinC = t;
    if (s.tempMaxC == null || t > s.tempMaxC!) s.tempMaxC = t;
    s.tempWeightedSum += t * dtS;
    s.tempTimeS += dtS;
    if (t < 10.0) s.tempBelow10S += dtS;
  }

  /// 0–100 automaton (spec §4). Arms at standstill (dash < 2 held
  /// ≥ 1 s), starts on the first frame above 2 with t0 interpolated to
  /// the threshold crossing, finishes when REAL speed reaches 100
  /// (dash × 0.98 ≥ 100 ⇒ dash ≈ 102) with the finish time
  /// interpolated between the straddling frames. An attempt dies on a
  /// > 2 km/h drop below the running peak or a 30 s timeout.
  void _stepZeroTo100(SpeedProfileSession s, double vDash, int nowMs) {
    switch (_zPhase) {
      case _ZPhase.idle:
        if (vDash < 2.0) {
          _zBelowSinceMs ??= nowMs;
          if (nowMs - _zBelowSinceMs! >= 1000) {
            _zPhase = _ZPhase.armed;
          }
        } else {
          _zBelowSinceMs = null;
        }
        break;

      case _ZPhase.armed:
        if (vDash > 2.0) {
          double t0 = nowMs.toDouble();
          final pm = _zPrevMs;
          final pv = _zPrevDash;
          if (pm != null && pv != null && vDash > pv) {
            final f = (2.0 - pv) / (vDash - pv);
            if (f >= 0 && f <= 1) t0 = pm + f * (nowMs - pm);
          }
          _zT0Ms = t0;
          _zPeakDash = vDash;
          _zPhase = _ZPhase.running;
        }
        break;

      case _ZPhase.running:
        if (vDash > _zPeakDash) _zPeakDash = vDash;
        final t0 = _zT0Ms!;
        final vReal = vDash * kSpeedRealFactor;
        if (vReal >= 100.0) {
          double tf = nowMs.toDouble();
          final pm = _zPrevMs;
          final pv = _zPrevDash;
          if (pm != null && pv != null) {
            final prevReal = pv * kSpeedRealFactor;
            if (vReal > prevReal && prevReal < 100.0) {
              final f = (100.0 - prevReal) / (vReal - prevReal);
              if (f >= 0 && f <= 1) tf = pm + f * (nowMs - pm);
            }
          }
          final secs = (tf - t0) / 1000.0;
          if (secs > 0 && secs <= 30.0) {
            s.runs.add(ZeroTo100Run(nowMs, secs));
            _lastNotifyMs = 0; // force a repaint on the next tick
          }
          _zPhase = _ZPhase.idle;
          _zBelowSinceMs = null;
        } else if (vDash < _zPeakDash - 2.0 || nowMs - t0 > 30000) {
          // Lifted off / traffic — the attempt is void, re-arm on the
          // next standstill.
          _zPhase = _ZPhase.idle;
          _zBelowSinceMs = null;
        }
        break;
    }
    _zPrevMs = nowMs;
    _zPrevDash = vDash;
  }
}

enum _ZPhase { idle, armed, running }

class _SpeedFrame {
  final int ms;
  final double v;
  const _SpeedFrame(this.ms, this.v);
}
