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
//   • band energy is SIGNED (+155): regen/coast inside the corridor
//     subtract, exactly like they do in trip averages;
//   • the HAL speed fid is ON-CHANGE (+156 field proof, 22.07: 25 of
//     69 odometer km lost to >2 s stream silences at steady speed) —
//     a 1 Hz virtual-tick pump carries the last dash value forward,
//     because a value that did not change did not emit;
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

/// Corridor-dwell gate (+155): a tick qualifies once the dash speed
/// has stayed INSIDE one band window (±3) continuously for this long.
/// This replaced the slope estimator (+153 edge, +154 LSQ): both died
/// in the field — the 21.07 dumps showed the accel gate still eating
/// 65% of city ticks, a physically implausible share, i.e. the
/// estimator systematically over-read the ~2.7 Hz quantized stream.
/// Dwell IS a steadiness measurement, but a robust one: you cannot
/// accelerate harder than ~2 km/h/s and remain 3 s inside a 6-km/h
/// corridor — the physics does the filtering, the estimator retires.
const double kBandDwellS = 3.0;

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

/// Virtual-tick cadence (+156). The HAL speed fid is ON-CHANGE: at a
/// held speed the dash value does not change, so NO events arrive, the
/// inter-tick gap blows past kDtGuardS and the steadiest stretches —
/// the exact target of the whole feature — were structurally invisible
/// (22.07 field: totalDistKm 44.05 vs одометр 69.3, −36%; the third
/// starvation in a row after +153/+154, this time the mechanism is
/// proven by the distance loss, which ONLY the dt-guard can cause).
/// A periodic pump re-integrates the LAST dash value: on-change
/// semantics guarantee the carry-forward is honest — the speed cannot
/// change without emitting an event. Liveness is gated on fresh V/I
/// (the 6 s windows the energy path already requires): a dead stream
/// freezes the whole tick, so an ignition-off never grows phantom km.
const double kVirtualTickS = 1.0;

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
  int total; // integration ticks entering the band pipeline (v ≥ 2)
  int warming; // inside a band window but dwell < kBandDwellS
  int outOfBand; // dash speed outside every ±3 round-ten window
  int powerStale; // V/I freshness gate failed (P null)
  int negPower; // INFORMATIONAL: qualified ticks written with P <= 0
  int qualified;
  // +156 on-change proof counters. After the virtual pump, gapDrops
  // must collapse to ~0 while the car is alive — the one-drive field
  // confirmation that the starvation mechanism is closed.
  int virtualTicks; // integrated ticks that came from the 1 Hz pump
  int gapDrops; // ticks rejected by the dt-guard (gap > kDtGuardS)
  double maxGapS; // longest observed inter-tick gap

  TickDiag({
    this.total = 0,
    this.warming = 0,
    this.outOfBand = 0,
    this.powerStale = 0,
    this.negPower = 0,
    this.qualified = 0,
    this.virtualTicks = 0,
    this.gapDrops = 0,
    this.maxGapS = 0,
  });

  Map<String, dynamic> toJson() => {
        'tot': total,
        'wu': warming,
        'ob': outOfBand,
        'ps': powerStale,
        'pn': negPower,
        'q': qualified,
        'vt': virtualTicks,
        'gd': gapDrops,
        'gm': maxGapS,
      };

  static TickDiag fromJson(Map<String, dynamic> j) => TickDiag(
        total: (j['tot'] as num?)?.toInt() ?? 0,
        warming: (j['wu'] as num?)?.toInt() ?? 0,
        outOfBand: (j['ob'] as num?)?.toInt() ?? 0,
        powerStale: (j['ps'] as num?)?.toInt() ?? 0,
        negPower: (j['pn'] as num?)?.toInt() ?? 0,
        qualified: (j['q'] as num?)?.toInt() ?? 0,
        virtualTicks: (j['vt'] as num?)?.toInt() ?? 0,
        gapDrops: (j['gd'] as num?)?.toInt() ?? 0,
        maxGapS: (j['gm'] as num?)?.toDouble() ?? 0,
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
  int _lastNotifyMs = 0;
  // +156 carry-forward pump: the last dash value seen on the stream
  // (on-change ⇒ still the true value until the next event) and the
  // 1 Hz timer that re-integrates it through the SAME clock/guards.
  double? _lastSpeedDash;
  Timer? _virtualTimer;
  // Corridor dwell (+155): which band window the dash currently sits
  // in and since when. Leaving the window (or hopping to a neighbour)
  // resets the clock; ticks qualify only past kBandDwellS.
  int? _dwellBand;
  int? _dwellSinceMs;

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
        'kBandDwellS': kBandDwellS,
        'kSpeedRealFactor': kSpeedRealFactor,
        'kBandHalfWidthKmh': kBandHalfWidthKmh,
        'kBandMinKmh': kBandMinKmh,
        'kBandMaxKmh': kBandMaxKmh,
        'kBandMinSeconds': kBandMinSeconds,
        'kDtGuardS': kDtGuardS,
        'kVirtualTickS': kVirtualTickS,
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
    _virtualTimer?.cancel();
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
    // +156: the carry-forward pump lives exactly as long as the
    // subscription — attach starts it, detach kills it.
    _virtualTimer ??= Timer.periodic(
        const Duration(seconds: 1), (_) => _onVirtualTick());
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
    _virtualTimer?.cancel();
    _virtualTimer = null;
    if (_retained) {
      _retained = false;
      await _hal.releaseStream();
    }
    _resetTickState();
  }

  void _resetTickState() {
    _lastTickMs = null;
    _lastSpeedDash = null;
    _dwellBand = null;
    _dwellSinceMs = null;
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
    // stream is fast enough that transport jitter is noise at the
    // 3 s dwell and 2 s dt guards.
    final now = DateTime.now().millisecondsSinceEpoch;

    _lastSpeedDash = vDash; // feed the +156 carry-forward pump
    _integrate(s, vDash, now, virtual: false);

    // The 0–100 automaton stays on REAL events only: it needs actual
    // threshold crossings for the two-sided interpolation, and during
    // a hard launch the on-change stream is dense by construction.
    _stepZeroTo100(s, vDash, now);

    _maybeNotify(now);
  }

  /// +156: one virtual tick of the carry-forward pump. Re-runs the
  /// SAME integration path with the last dash value — on-change
  /// semantics make this honest (the value did not change, or an
  /// event would have arrived first). The whole tick — distance, temp
  /// AND bands — is gated on stream liveness (fresh V/I, the same 6 s
  /// windows the energy path requires): a dead stream must never grow
  /// phantom kilometres out of a frozen speed. A rejected tick does
  /// NOT touch _lastTickMs, so on revival the dt-guard resets the
  /// integration baseline cleanly on the first real event.
  void _onVirtualTick() {
    if (!_active) return;
    final s = _session;
    if (s == null) return;
    final vDash = _lastSpeedDash;
    if (vDash == null) return; // no speed seen yet on this attach
    if (_freshPowerKw() == null) return; // stream dead — freeze
    final now = DateTime.now().millisecondsSinceEpoch;
    _integrate(s, vDash, now, virtual: true);
    _maybeNotify(now);
  }

  /// Shared integration step — real events and virtual ticks run the
  /// SAME clock (_lastTickMs), so interleaving can never double-count:
  /// every dt slice is consumed exactly once.
  void _integrate(SpeedProfileSession s, double vDash, int now,
      {required bool virtual}) {
    // Corridor dwell (+155): the slope estimators are retired — see
    // kBandDwellS. Track which band window the dash sits in; any exit
    // or hop resets the clock. Virtual ticks re-run this with the
    // carried value: same window ⇒ the dwell clock keeps maturing —
    // silence IS holding the speed.
    final cand = (vDash / 10.0).round() * 10;
    final inWindow = cand >= kBandMinKmh &&
        cand <= kBandMaxKmh &&
        (vDash - cand).abs() <= kBandHalfWidthKmh;
    if (!inWindow) {
      _dwellBand = null;
      _dwellSinceMs = null;
    } else if (_dwellBand != cand) {
      _dwellBand = cand;
      _dwellSinceMs = now;
    }

    final last = _lastTickMs;
    _lastTickMs = now;
    double? dtS;
    if (last != null) {
      final d = (now - last) / 1000.0;
      if (d > 0 && d <= kDtGuardS) dtS = d;
      if (d > kDtGuardS) {
        // +156 on-change proof: with the pump alive these must stay
        // ~0 while driving; a nonzero share names a real stream hole.
        s.diag.gapDrops++;
        if (d > s.diag.maxGapS) s.diag.maxGapS = d;
      }
    }

    if (dtS != null) {
      // Total real distance — the auto-name «82 км» and nothing else.
      s.totalDistKm += vDash * kSpeedRealFactor * dtS / 3600.0;
      // +156: the temp passport describes DRIVING — a 40-minute
      // charging stop must not out-weigh the trip now that the pump
      // also ticks at standstill.
      if (vDash >= 2.0) _accumTemp(s, dtS);
      _accumBand(s, vDash, now, dtS, virtual: virtual);
    }

    // Idle clock for the auto-stop (p.7): any real movement resets it.
    if (vDash >= 2.0) s.lastMoveMs = now;
  }

  /// The screen may be open while recording — repaint at most 1/s so
  /// a ~10 Hz speed stream doesn't burn the UI thread.
  void _maybeNotify(int now) {
    if (now - _lastNotifyMs >= 1000) {
      _lastNotifyMs = now;
      notifyListeners();
    }
  }

  void _accumBand(
      SpeedProfileSession s, double vDash, int nowMs, double dtS,
      {required bool virtual}) {
    // Tick qualification (+155 redesign after the 21.07 field dumps):
    //   1) the dash has dwelt INSIDE one ±3 round-ten window for
    //      ≥ kBandDwellS (corridor gate — replaces the slope
    //      estimators that over-rejected 65-79% of honest city ticks);
    //   2) V/I fresh (ps was 1/2861 in the field — the gate is cheap
    //      and stays);
    //   3) dt ≤ 2 s (guarded by the caller).
    // Energy is integrated SIGNED (+155): the old «P ≤ 0 не пишем»
    // rule skewed city bands to the traction-pulse phase only — the
    // 19:55 dump read 32.4 kWh/100km at band 40 and FALLING with
    // speed, inverted EV physics. A band answers «что суммарно стоит
    // держать эту скорость здесь», so regen/coast inside the corridor
    // must субtract exactly like they do in trip averages.
    final d = s.diag;
    // +156: standstill ticks (the pump runs at red lights and while
    // charging) are invisible to the counters — otherwise `вне` drowns
    // in parked seconds and the ✓-доля stops meaning anything.
    if (vDash < 2.0) return;
    d.total++;
    if (virtual) d.virtualTicks++;
    final band = _dwellBand;
    final since = _dwellSinceMs;
    if (band == null || since == null) {
      d.outOfBand++;
      return;
    }
    if (nowMs - since < kBandDwellS * 1000.0) {
      d.warming++;
      return;
    }
    final p = _freshPowerKw();
    if (p == null) {
      d.powerStale++;
      return;
    }
    d.qualified++;
    if (p <= 0) d.negPower++; // informational — the tick IS written

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

