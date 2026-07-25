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

import 'package:drift/drift.dart' show Value;
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../data/database.dart';
import '../data/uuid_v7.dart';
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

/// Band shape: round tens, ±2 km/h dash window, 40…180 range. A band
/// materialises only after `kBandMinSeconds` of qualified time
/// (+154: 60 → 120 s — Alex's call: a two-minute floor makes a row
/// statistically worth trusting before it starts promising range).
///
/// +158 (Атлас, spec v2): 3 → 2. There is no explicit accel gate since
/// +155 — its role is played by dwell physics: you cannot cross a
/// corridor faster than width/dwell and still qualify. Narrowing the
/// window tightens the effective threshold 6/3 = 2.0 → 4/3 ≈ 1.33
/// km/h·s (−33%) with ONE constant. Field motive (23.07 heartbeat day):
/// band 50 read 6.2 kWh/100 — regen contamination from smooth ~1 km/h·s
/// braking passing straight through the corridor (~3 s of negative
/// energy inside ±3; ~1 s inside ±2). The reserve second step
/// (kBandDwellS 3.0 → 4.0) is NOT taken — one knob per field check.
const int kBandHalfWidthKmh = 2;
const int kBandMinKmh = 40;
const int kBandMaxKmh = 180;
const double kBandMinSeconds = 120.0;

// ── +158 «Атлас» — temperature-window ledger (spec v2 + UI contract) ──

/// Pack-temperature window grid: 5 °C windows, lower bounds −20…35
/// (12 windows). Clamps: t < −20 → window −20 («≤ −20»), t ≥ 40 →
/// window 35. A tick with no usable temperature goes to the reserve
/// «t° неизвестна» column (window == null).
const int kAtlasWindowStepC = 5;
const int kAtlasWindowMinC = -20;
const int kAtlasWindowMaxC = 35;

/// Border hysteresis: the active window switches only when a FRESH
/// reading has penetrated ≥ 1 °C into the new window — a pack breathing
/// 19.7↔20.3 around a border must not shred snapshots.
const double kAtlasHysteresisC = 1.0;

/// Temp stickiness for tick assignment (review R1): a tick belongs to
/// the window of the last fresh reading if it is at most this old — an
/// LFP pack cannot jump 5 °C in 5 minutes of driving, but the BigData
/// temp frame drops out for up to ~75 s routinely; without stickiness
/// every dropout would freeze-and-restart the real window's cells.
/// Older than this → the honest «t° неизвестна» reserve. Window
/// SWITCHES happen only on fresh readings, never on staleness.
const double kAtlasTempMaxAgeS = 300.0;

/// Atlas-session idle gap: movement resuming after this long a pause
/// closes the previous session (matured cells freeze retroactively at
/// the last movement) and rotates session_uid. 30 min: a long traffic
/// light or a quick charge does not split a session; morning and
/// evening drives are independent (coverage-star semantics, contract).
const int kAtlasSessionGapMin = 30;

/// +160 (§2.2 п.5): «Полоса {v} почти дозрела» — the anticipation line
/// of the summary card names the un-matured cell with the largest
/// timeS at or past this threshold. Deliberately coarse, no numbers
/// toward a goal on the card itself (инвариант И2).
const double kAtlasAnticipationS = 90.0;

/// +162: the collection ceiling. Bands above this are still MEASURED by
/// the profiler (the chart keeps its 40–180 range) but they are not part
/// of the atlas: no snapshot is frozen and no reveal is generated. The
/// grid, the counters and the export enforce the same number on the read
/// side (`kAtlasBandMaxKmh` in atlas_projection.dart) — the two are the
/// only places 140 is written down.
const int kAtlasBandMaxCollectKmh = 140;

/// +162 (§3.2): an untouched intention is dropped silently after this
/// many days. Nagging is the one thing the card must never do.
const int kAtlasIntentTtlDays = 14;

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

/// +158: accumulators of one atlas cell (band × temp window). Signed
/// energy like the session bands; its OWN dt-weighted pack-temp mean
/// (the snapshot's pack_temp_avg_c); startedAtMs latches on the first
/// qualified tick of the current accumulation round and may predate the
/// freezing session — sub-120 s accumulation carries across trips.
class _AtlasCell {
  double energyKwh;
  double distKm;
  double timeS;
  double tempSum;
  double tempTimeS;
  int startedAtMs;

  /// +160 (§1.4): timeS at the start of the CURRENT atlas session —
  /// set to timeS on session rotation and to 0 on cell creation.
  /// gained = timeS − t0 feeds the micro-loot line of the summary
  /// card. JSON default 0 keeps old ledgers loading (one slightly
  /// inflated first card is the accepted migration cost).
  double t0;

  _AtlasCell({
    this.energyKwh = 0,
    this.distKm = 0,
    this.timeS = 0,
    this.tempSum = 0,
    this.tempTimeS = 0,
    required this.startedAtMs,
    this.t0 = 0,
  });

  /// Steady seconds earned by the current atlas session (micro-loot).
  double get gainedS => timeS - t0;

  double? get tempMeanC => tempTimeS > 1e-6 ? tempSum / tempTimeS : null;

  Map<String, dynamic> toJson() => {
        'e': energyKwh,
        'd': distKm,
        't': timeS,
        'ts': tempSum,
        'tt': tempTimeS,
        'sa': startedAtMs,
        't0': t0,
      };

  static _AtlasCell fromJson(Map<String, dynamic> j) => _AtlasCell(
        energyKwh: (j['e'] as num?)?.toDouble() ?? 0,
        distKm: (j['d'] as num?)?.toDouble() ?? 0,
        timeS: (j['t'] as num?)?.toDouble() ?? 0,
        tempSum: (j['ts'] as num?)?.toDouble() ?? 0,
        tempTimeS: (j['tt'] as num?)?.toDouble() ?? 0,
        startedAtMs: (j['sa'] as num?)?.toInt() ??
            DateTime.now().millisecondsSinceEpoch,
        t0: (j['t0'] as num?)?.toDouble() ?? 0,
      );
}

/// +158: the whole always-on atlas ledger — persisted to its own prefs
/// key on the shared 30 s snapshot cadence (dirty-gated), hydrated and
/// crash-recovered in init(). Cell keys: '$band:$window' with the
/// unknown-temp reserve encoded as '$band:u'.
/// +162 (§3.2): a taken (or candidate) intention — «next drive: this
/// speed at this pack temperature». No seconds, no percentages inside:
/// the goal is named by the cell, never by progress toward it.
class AtlasIntent {
  final int band;
  final int? window;
  final int takenAtMs;
  const AtlasIntent({
    required this.band,
    required this.window,
    required this.takenAtMs,
  });

  String get key => '$band:${window ?? 'u'}';
}

/// +162: a matured cell still waiting for the session to rotate.
class AtlasPendingCell {
  final int band;
  final int? window;
  final double kwh100;
  final double steadySeconds;
  const AtlasPendingCell({
    required this.band,
    required this.window,
    required this.kwh100,
    required this.steadySeconds,
  });

  String get key => '$band:${window ?? 'u'}';
}

class _AtlasLedger {
  String sessionUid;
  int sessionStartedAtMs;
  int lastMoveMs;
  int? activeWindow;
  double? lastFreshTempC;
  int? lastFreshTempMs;
  final Map<String, _AtlasCell> cells;

  /// +160 (§1.4): real km of the CURRENT atlas session — every moving
  /// tick, BEFORE qualification (vDash·factor·dt). The «7.2 км» line
  /// of the summary card. Resets on session rotation.
  double sessionDistKm;

  /// +160 (§2.1): the moment of the last «Ок» — the card's «показывать
  /// ли микро-лут без событий» anchor. Survives restarts with the
  /// ledger (a lost lastOkMs would merely re-show an honest card).
  int? lastOkMs;

  /// +160: the moment of the last QUALIFIED atlas tick. «Σ gained с
  /// момента lastOkMs > 0» ≡ (gain exists AND lastGainMs > lastOkMs) —
  /// one timestamp instead of a per-cell second baseline; freezing a
  /// cell (which removes it) cannot lose the flag.
  int? lastGainMs;

  _AtlasLedger({
    required this.sessionUid,
    required this.sessionStartedAtMs,
    required this.lastMoveMs,
    this.activeWindow,
    this.lastFreshTempC,
    this.lastFreshTempMs,
    Map<String, _AtlasCell>? cells,
    this.sessionDistKm = 0,
    this.lastOkMs,
    this.lastGainMs,
  }) : cells = cells ?? {};

  static _AtlasLedger fresh() {
    final now = DateTime.now().millisecondsSinceEpoch;
    return _AtlasLedger(
        sessionUid: uuidV7(), sessionStartedAtMs: now, lastMoveMs: now);
  }

  static String cellKey(int band, int? window) =>
      '$band:${window == null ? 'u' : window.toString()}';

  Map<String, dynamic> toJson() => {
        'uid': sessionUid,
        'ss': sessionStartedAtMs,
        'lm': lastMoveMs,
        'aw': activeWindow,
        'lt': lastFreshTempC,
        'lts': lastFreshTempMs,
        'sd': sessionDistKm,
        'lok': lastOkMs,
        'lg': lastGainMs,
        'cells': cells.map((k, v) => MapEntry(k, v.toJson())),
      };

  static _AtlasLedger fromJson(Map<String, dynamic> j) {
    final rawCells = (j['cells'] as Map<String, dynamic>? ?? {});
    final cells = <String, _AtlasCell>{};
    rawCells.forEach((k, v) {
      if (v is Map<String, dynamic>) cells[k] = _AtlasCell.fromJson(v);
    });
    final now = DateTime.now().millisecondsSinceEpoch;
    return _AtlasLedger(
      sessionUid: j['uid'] as String? ?? uuidV7(),
      sessionStartedAtMs: (j['ss'] as num?)?.toInt() ?? now,
      lastMoveMs: (j['lm'] as num?)?.toInt() ?? now,
      activeWindow: (j['aw'] as num?)?.toInt(),
      lastFreshTempC: (j['lt'] as num?)?.toDouble(),
      lastFreshTempMs: (j['lts'] as num?)?.toInt(),
      cells: cells,
      sessionDistKm: (j['sd'] as num?)?.toDouble() ?? 0,
      lastOkMs: (j['lok'] as num?)?.toInt(),
      lastGainMs: (j['lg'] as num?)?.toInt(),
    );
  }
}

/// +160 (§1.3): lightweight projection of an atlas snapshot for the
/// session dedup — everything the contract rule reads and nothing else.
class SnapshotLite {
  final String sessionUid;
  final String source;
  final int startedAtMs;
  final int frozenAtMs;
  const SnapshotLite({
    required this.sessionUid,
    required this.source,
    required this.startedAtMs,
    required this.frozenAtMs,
  });
}

/// +160 (§1.3): Dart port of the CONTRACT session-dedup rule — the
/// behavioural reference is mirror_plus158.py S10a, carried bit-for-bit
/// into mirror_plus160 as the port cross-check. Rule: group snapshots
/// by session_uid (interval = [min started, max frozen], source of the
/// first snapshot — one recording device per uid by construction);
/// merge two groups iff their sources DIFFER and the interval overlap
/// is STRICTLY > 50% of the SHORTER interval; transitive closure via
/// union-find (two HU sessions may end up one logical session through a
/// phone bridge — intended); same source never merges directly. The
/// result is the number of independent logical sessions (star levels
/// 1 / 5 / 15).
int dedupSessionCount(List<SnapshotLite> snaps) {
  final keys = <String>[];
  final aMs = <String, int>{};
  final bMs = <String, int>{};
  final src = <String, String>{};
  for (final s in snaps) {
    if (!aMs.containsKey(s.sessionUid)) {
      keys.add(s.sessionUid);
      aMs[s.sessionUid] = s.startedAtMs;
      bMs[s.sessionUid] = s.frozenAtMs;
      src[s.sessionUid] = s.source;
    } else {
      if (s.startedAtMs < aMs[s.sessionUid]!) {
        aMs[s.sessionUid] = s.startedAtMs;
      }
      if (s.frozenAtMs > bMs[s.sessionUid]!) {
        bMs[s.sessionUid] = s.frozenAtMs;
      }
    }
  }
  final parent = <String, String>{for (final k in keys) k: k};
  String find(String x) {
    var cur = x;
    while (parent[cur] != cur) {
      parent[cur] = parent[parent[cur]!]!;
      cur = parent[cur]!;
    }
    return cur;
  }

  for (var i = 0; i < keys.length; i++) {
    for (var j = i + 1; j < keys.length; j++) {
      final ki = keys[i], kj = keys[j];
      if (src[ki] == src[kj]) continue; // same source never merges
      final lo = aMs[ki]! > aMs[kj]! ? aMs[ki]! : aMs[kj]!;
      final hi = bMs[ki]! < bMs[kj]! ? bMs[ki]! : bMs[kj]!;
      final ov = hi - lo;
      final li = bMs[ki]! - aMs[ki]!;
      final lj = bMs[kj]! - aMs[kj]!;
      final shorter = li < lj ? li : lj;
      if (shorter <= 0) continue; // zero-length group never merges
      if (ov > 0.5 * shorter) {
        parent[find(ki)] = find(kj); // STRICTLY > 50% of the shorter
      }
    }
  }
  final roots = <String>{for (final k in keys) find(k)};
  return roots.length;
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
  /// +158: the service now owns the atlas write path — [db] for the
  /// freeze funnel (the HAL-service _diagDb precedent; connection.dart
  /// is still never imported, AA2 holds) and [appVersion] for snapshot
  /// provenance (kAppVersion handed down by main.dart — a service must
  /// not import a screen).
  SpeedProfileService(this._hal,
      {required AppDatabase db, required String appVersion})
      : _db = db,
        _appVersion = appVersion;

  final HalTelemetryService _hal;
  final AppDatabase _db;
  final String _appVersion;

  static const String _kSessionKey = 'speed_profile_session';
  static const String _kActiveKey = 'speed_profile_active';
  static const String _kArchiveKey = 'speed_profile_archive';
  static const String _kAtlasLedgerKey = 'atlas_ledger';
  // +162 (§3.2): intention lives beside the ledger, not inside it — it
  // must survive a session rotation, which rewrites the ledger.
  static const String _kIntentBandKey = 'atlas_intent_band';
  static const String _kIntentWinKey = 'atlas_intent_win';
  static const String _kIntentMsKey = 'atlas_intent_ms';
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

  // ── +158 atlas recorder (always-on on the head unit) ──
  _AtlasLedger? _ledger;
  bool _atlasArmed = false;
  // Prefs write-amplification guard (review R6): the 30 s timer
  // persists only after qualified ticks / freezes / rotations — a
  // parked-but-awake head unit stops grinding prefs forever.
  bool _dirtySincePersist = false;
  // Process-lifetime freeze counter — diag visibility only.
  int _atlasFreezeCount = 0;

  // ── +160: reveal generation (§1) + badge counter (§2.3) ──
  // Existence checks are ASYNC after a maturity crossing; two cells of
  // one band can cross in quick succession (crossings are rare, but a
  // convoy of two is physical) — a serialized chain makes every check
  // see the inserts of the previous one, so band_matured cannot double.
  Future<void> _revealChain = Future<void>.value();
  // Cached badge source (§2.3): refreshed after generation, after «Ок»
  // and in init() from countUnrevealedAtlasReveals.
  int _unrevealedCount = 0;
  int get unrevealedCount => _unrevealedCount;

  /// +162: monotonic «the atlas on disk changed» counter — bumped after
  /// a freeze, after a reveal is generated and after «Ок». Screens that
  /// cache a DB read (the grid, the entry card) watch it and re-read.
  /// The field-reported symptom it fixes: the entry card kept saying
  /// «1 клетка» all day because the tab lives in an IndexedStack and its
  /// initState never ran again.
  int _atlasRevision = 0;
  int get atlasRevision => _atlasRevision;

  /// +162 (§3.2): the taken intention — band, window, moment.
  int? _intentBand;
  int? _intentWindow;
  int? _intentTakenMs;

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
    // +162: intention first — a stale one is dropped before any screen
    // can render it.
    _intentBand = prefs.getInt(_kIntentBandKey);
    _intentWindow = prefs.getInt(_kIntentWinKey);
    _intentTakenMs = prefs.getInt(_kIntentMsKey);
    if (_intentBand != null && _intentTakenMs != null) {
      final ageDays = (DateTime.now().millisecondsSinceEpoch -
              _intentTakenMs!) /
          86400000.0;
      if (ageDays > kAtlasIntentTtlDays) {
        _intentBand = null;
        _intentWindow = null;
        _intentTakenMs = null;
        unawaited(_persistIntent());
      }
    }
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
    // ── +158: atlas ledger hydration + crash-recovery ──
    // The HU process dies at ignition-off, so the «freeze at session
    // end» path almost never runs live — recovery on the NEXT boot is
    // the normal path, not the exception (the +116 SOH pattern). If the
    // persisted ledger went idle past the gap, close that session
    // retroactively: matured cells freeze with frozen_at = the last
    // movement, session_uid rotates. Sub-threshold cells carry.
    final rawLedger = prefs.getString(_kAtlasLedgerKey);
    if (rawLedger != null) {
      try {
        _ledger = _AtlasLedger.fromJson(
            jsonDecode(rawLedger) as Map<String, dynamic>);
      } catch (_) {
        _ledger = null;
      }
      final l = _ledger;
      if (l != null &&
          DateTime.now().millisecondsSinceEpoch - l.lastMoveMs >
              kAtlasSessionGapMin * 60000) {
        debugPrint('Atlas: recovery — stale session '
            '${l.sessionUid.substring(0, 8)}…, closing at lastMove');
        _closeAtlasSession(frozenAtMs: l.lastMoveMs);
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

    // ── +158: arm the always-on atlas recorder (review R5) ──
    // The platform probe settles ASYNCHRONOUSLY inside hal.init(), which
    // races this init on a cold start — a direct canUseHal check here
    // would reliably miss. The listener is the only correct path (the
    // +139/+141 probe discipline); after arming it is a no-op.
    _hal.addListener(_maybeArmAtlas);
    _maybeArmAtlas();

    // +160 (§2.3): hydrate the badge counter — reveals survive in the
    // DB (and arrive by pull), the cache must not start at a lying 0.
    try {
      _unrevealedCount = await _db.countUnrevealedAtlasReveals();
    } catch (_) {
      _unrevealedCount = 0;
    }

    notifyListeners();
  }

  /// +158: arm once the head-unit verdict settles. Phones never arm —
  /// the recorder is HAL-stream-fed; phone collection (BLE dongle,
  /// source='phone') is a future patch, the contract is already ready
  /// for it.
  void _maybeArmAtlas() {
    if (_atlasArmed) return;
    if (!_hal.platformProbed || !_hal.canUseHal) return;
    _atlasArmed = true;
    _ledger ??= _AtlasLedger.fresh();
    debugPrint('Atlas: armed — session '
        '${_ledger!.sessionUid.substring(0, 8)}…');
    unawaited(_attach());
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

  /// Стоп — keep the finished session in place so the UI can offer
  /// "save to archive". Returns it for convenience.
  ///
  /// +158: the stream detaches ONLY when the atlas recorder is not
  /// armed — on the head unit the subscription/pump/persist machinery
  /// now lives as long as the process (the always-on ledger), a manual
  /// Стоп merely flips the session overlay off. On a phone (never
  /// armed) the old full-detach behaviour is preserved verbatim.
  Future<SpeedProfileSession?> stop() async {
    if (!_active) return _session;
    _active = false;
    if (!_atlasArmed) await _detach();
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
    // +158: an armed atlas is dumpable WITHOUT a manual session — the
    // always-on ledger is the field-check target now; only a phone
    // with neither has nothing to say.
    if (s == null && _ledger == null) return null;
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
        // +158 atlas constants — the analysis must know the grid.
        'kAtlasWindowStepC': kAtlasWindowStepC,
        'kAtlasWindowMinC': kAtlasWindowMinC,
        'kAtlasWindowMaxC': kAtlasWindowMaxC,
        'kAtlasHysteresisC': kAtlasHysteresisC,
        'kAtlasTempMaxAgeS': kAtlasTempMaxAgeS,
        'kAtlasSessionGapMin': kAtlasSessionGapMin,
      },
      'session': s?.toJson(),
      // +158: raw atlas ledger + counters — the field check of the
      // freeze machinery reads THIS (verification rule: the burden is
      // on Друг, the dump must show the data flow).
      'atlas': {
        'armed': _atlasArmed,
        'freezes_this_process': _atlasFreezeCount,
        'snapshots_in_db': await _db.countAtlasSnapshots(),
        // +160 field check (§5): the badge source + reveal totals;
        // lastOkMs / t0 ride inside the ledger JSON ('lok' / 't0').
        'unrevealed': _unrevealedCount,
        'reveals_in_db': await _db.countAtlasReveals(),
        'ledger': _ledger?.toJson(),
      },
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
    _hal.removeListener(_maybeArmAtlas);
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
      // +158 (R6): persist only after qualified ticks / freezes /
      // rotations since the last write — the always-on recorder must
      // not grind prefs forever on a parked-but-awake head unit.
      if (_dirtySincePersist) {
        _dirtySincePersist = false;
        _persist();
      }
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
      // +158: the atlas ledger rides the same crash-safe snapshot.
      final l = _ledger;
      if (l != null) {
        await prefs.setString(_kAtlasLedgerKey, jsonEncode(l.toJson()));
      }
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
    // +158: two consumers share the pipeline — the manual session
    // (overlay, exactly the old behaviour) and the always-on atlas
    // ledger. Either one keeps the tick alive.
    if (!_active && !_atlasArmed) return;
    final s = _session;
    if (_active && s == null) return;
    if (e.name != 'speed') return;
    final vDash = e.value?.toDouble();
    if (vDash == null) return;

    // Wall clock over HalEvent.ts — the framework timestamp base is
    // unspecified (boot vs epoch); receipt time is uniform and the
    // stream is fast enough that transport jitter is noise at the
    // 3 s dwell and 2 s dt guards.
    final now = DateTime.now().millisecondsSinceEpoch;

    _lastSpeedDash = vDash; // feed the +156 carry-forward pump
    _integrate(vDash, now, virtual: false);

    // The 0–100 automaton stays on REAL events only: it needs actual
    // threshold crossings for the two-sided interpolation, and during
    // a hard launch the on-change stream is dense by construction.
    // Session-scoped: runs live in the session body.
    if (_active && s != null) _stepZeroTo100(s, vDash, now);

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
    if (!_active && !_atlasArmed) return;
    if (_active && _session == null) return;
    final vDash = _lastSpeedDash;
    if (vDash == null) return; // no speed seen yet on this attach
    if (_freshPowerKw() == null) return; // stream dead — freeze
    final now = DateTime.now().millisecondsSinceEpoch;
    _integrate(vDash, now, virtual: true);
    _maybeNotify(now);
  }

  /// Shared integration step — real events and virtual ticks run the
  /// SAME clock (_lastTickMs), so interleaving can never double-count:
  /// every dt slice is consumed exactly once.
  ///
  /// +158: the step now feeds TWO independent accumulators from one dt
  /// slice — the manual session (only while _active; behaviour
  /// bit-for-bit as before) and the always-on atlas ledger. The dwell
  /// tracker and the clock are shared: the atlas qualifies the exact
  /// same tick set as the session bands (the mirror's no-double-count
  /// invariant), only the sink differs.
  void _integrate(double vDash, int now, {required bool virtual}) {
    final s = _active ? _session : null;
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
      if (d > kDtGuardS && s != null) {
        // +156 on-change proof: with the pump alive these must stay
        // ~0 while driving; a nonzero share names a real stream hole.
        s.diag.gapDrops++;
        if (d > s.diag.maxGapS) s.diag.maxGapS = d;
      }
    }

    if (dtS != null) {
      if (s != null) {
        // Total real distance — the auto-name «82 км» and nothing else.
        s.totalDistKm += vDash * kSpeedRealFactor * dtS / 3600.0;
        // +156: the temp passport describes DRIVING — a 40-minute
        // charging stop must not out-weigh the trip now that the pump
        // also ticks at standstill.
        if (vDash >= 2.0) _accumTemp(s, dtS);
        _accumBand(s, vDash, now, dtS, virtual: virtual);
      }
      // +158: the always-on atlas ledger consumes the SAME slice.
      if (_atlasArmed) _atlasTick(vDash, now, dtS);
    }

    // Idle clock for the auto-stop (p.7): any real movement resets it.
    if (vDash >= 2.0) {
      s?.lastMoveMs = now;
      _dirtySincePersist = true;
    }
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

  // ───────────────────── +158 atlas ledger ─────────────────────

  /// Window lower bound for a temperature. Dart floor() is correct for
  /// negatives: −7.3/5 → −1.46 → floor −2 → −10, i.e. −7.3 ∈ [−10,−5).
  /// Clamps (Q7): t < −20 → −20 («≤ −20»), t ≥ 40 → 35.
  static int atlasWindowOfTemp(double t) {
    if (t < kAtlasWindowMinC) return kAtlasWindowMinC;
    if (t >= kAtlasWindowMaxC + kAtlasWindowStepC) return kAtlasWindowMaxC;
    return (t / kAtlasWindowStepC).floor() * kAtlasWindowStepC;
  }

  /// One atlas tick. Runs on EVERY integrated slice (standstill
  /// included — the pack warms while charging and the window
  /// bookkeeping must see it), qualification mirrors _accumBand
  /// exactly (the deliberate small duplication keeps the session path
  /// bit-for-bit untouched; the gates are cheap getter reads).
  void _atlasTick(double vDash, int nowMs, double dtS) {
    final l = _ledger;
    if (l == null) return;

    // Session rotation (Q5): movement resuming after the idle gap
    // closes the previous session FIRST — its matured cells freeze
    // retroactively at the last movement, then the tick lands in the
    // fresh session.
    if (vDash >= 2.0) {
      if (nowMs - l.lastMoveMs > kAtlasSessionGapMin * 60000) {
        _closeAtlasSession(frozenAtMs: l.lastMoveMs);
      }
      l.lastMoveMs = nowMs;
      // +160 (§1.4): the trip line of the summary card — every MOVING
      // tick, before qualification (the card says how far this session
      // drove, not how much of it qualified).
      l.sessionDistKm += vDash * kSpeedRealFactor * dtS / 3600.0;
    }

    // Window bookkeeping — fresh readings update the stickiness anchor
    // and may switch the active window (hysteresis, review R1).
    final t = _packTempC();
    if (t != null) {
      l.lastFreshTempC = t;
      l.lastFreshTempMs = nowMs;
      _maybeSwitchWindow(t, nowMs);
    }

    // Qualification — the same gate chain as _accumBand.
    if (vDash < 2.0) return;
    final band = _dwellBand;
    final since = _dwellSinceMs;
    if (band == null || since == null) return;
    if (nowMs - since < kBandDwellS * 1000.0) return;
    final p = _freshPowerKw();
    if (p == null) return;

    final win = _tickWindow(nowMs);
    final key = _AtlasLedger.cellKey(band, win);
    final cell = l.cells.putIfAbsent(
        key, () => _AtlasCell(startedAtMs: nowMs));
    // +160 (§1.1): the maturity CROSSING (before < 120 ≤ after) is the
    // reveal generation point — freezing would be one trip too late
    // (on the HU it usually runs at the NEXT start, recovery/rotation)
    // and the card contract says «итоги ЭТОЙ поездки». A matured cell
    // is guaranteed to freeze eventually, so the prediction is honest
    // with certainty 1. ≤ 1 crossing per accumulation round by
    // construction (timeS grows monotonically until the freeze reset).
    final beforeS = cell.timeS;
    cell.energyKwh += p * dtS / 3600.0;
    cell.distKm += vDash * kSpeedRealFactor * dtS / 3600.0;
    cell.timeS += dtS;
    final ct = _packTempC();
    if (ct != null) {
      cell.tempSum += ct * dtS;
      cell.tempTimeS += dtS;
    }
    l.lastGainMs = nowMs; // +160: «Σ gained с момента lastOkMs» anchor
    if (beforeS < kBandMinSeconds && cell.timeS >= kBandMinSeconds) {
      // kwh in the payload is the value AT THE CROSSING — realtime
      // correction continues afterwards; the card renders from the
      // payload, an honest moment-in-time snapshot (spec §1.1).
      _maybeGenerateReveal(
          band, win, cell.energyKwh / cell.distKm * 100.0);
    }
    _dirtySincePersist = true;
  }

  /// The window a tick belongs to: the window of the last FRESH reading
  /// if it is at most kAtlasTempMaxAgeS old (stickiness, R1 — an LFP
  /// pack cannot jump 5 °C in 5 min of driving), otherwise the honest
  /// «t° неизвестна» reserve (null).
  int? _tickWindow(int nowMs) {
    final l = _ledger!;
    final lm = l.lastFreshTempMs;
    if (lm == null || nowMs - lm > kAtlasTempMaxAgeS * 1000.0) return null;
    return l.activeWindow;
  }

  /// Active-window switch on a FRESH reading only (staleness never
  /// switches — R1), with the 1 °C hysteresis: the reading must have
  /// penetrated at least kAtlasHysteresisC past the boundary shared
  /// with the travel direction. A switch freezes the matured cells of
  /// the OLD window — the «пак пересёк границу» rule of spec v2.
  void _maybeSwitchWindow(double t, int nowMs) {
    final l = _ledger!;
    final cand = atlasWindowOfTemp(t);
    final act = l.activeWindow;
    if (act == null) {
      l.activeWindow = cand; // first reading — no hysteresis, no freeze
      return;
    }
    if (cand == act) return;
    final double depth = cand > act
        ? t - cand // entered from below: past cand's lower bound
        : (cand + kAtlasWindowStepC) - t; // from above: below its upper
    if (depth < kAtlasHysteresisC) return;
    _freezeMatured(windowFilter: act, frozenAtMs: nowMs);
    l.activeWindow = cand;
    debugPrint('Atlas: window $act → $cand (t=${t.toStringAsFixed(1)}°)');
  }

  /// Close the atlas session: freeze matured cells of ALL windows
  /// (unknown included) at [frozenAtMs] — retroactive on recovery /
  /// rotation — and rotate session_uid. Sub-threshold cells carry into
  /// the new session untouched (their startedAt stays — spec v2
  /// «накопление переносится между поездками»).
  void _closeAtlasSession({required int frozenAtMs}) {
    final l = _ledger;
    if (l == null) return;
    _freezeMatured(all: true, frozenAtMs: frozenAtMs);
    final old = l.sessionUid;
    l.sessionUid = uuidV7();
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    l.sessionStartedAtMs = nowMs;
    // +160 (§1.4): the new session starts with zero gain — surviving
    // sub-threshold cells re-anchor their micro-loot baseline (timeS
    // itself carries, spec v2 «накопление переносится»); the trip line
    // starts from zero km.
    for (final c in l.cells.values) {
      c.t0 = c.timeS;
    }
    l.sessionDistKm = 0;
    // Refresh the idle anchor too: without this an init-recovery close
    // would be followed by a second (empty) rotation on the first
    // movement tick — harmless but sloppy (a wasted session_uid).
    l.lastMoveMs = nowMs;
    _dirtySincePersist = true;
    debugPrint('Atlas: session rotated ${old.substring(0, 8)}… → '
        '${l.sessionUid.substring(0, 8)}…');
  }

  /// The ONE write funnel for atlas snapshots (regress AX7). Cells of
  /// the filtered window (or all, on session close) with
  /// timeS ≥ kBandMinSeconds freeze into atlas_snapshots and reset in
  /// memory; sub-threshold cells are neither frozen nor reset.
  ///
  /// Durability order (review R2, Alex-approved): Drift INSERTs first,
  /// then _persist() writes the reset ledger — a kill in between leaves
  /// a duplicate snapshot at worst, which the contract dedup collapses
  /// (same session_uid → same logical session; identical value cannot
  /// move a median). The reverse order would LOSE the snapshot.
  ///
  /// NOTE (review R4, by design — do not "fix"): the on-screen session
  /// band may read «дозрела» (120 s flat) while no single cell reached
  /// 120 s in its own window (warm-up spread the time over 2–3
  /// windows) — no snapshot for that drive; it matures on later trips.
  void _freezeMatured(
      {int? windowFilter, bool all = false, required int frozenAtMs}) {
    final l = _ledger;
    if (l == null) return;
    final rows = <AtlasSnapshotsCompanion>[];
    final frozenKeys = <String>[];
    final now = DateTime.now();
    l.cells.forEach((key, cell) {
      if (cell.timeS < kBandMinSeconds) return;
      final sep = key.indexOf(':');
      final band = int.tryParse(key.substring(0, sep));
      final winStr = key.substring(sep + 1);
      final int? win = winStr == 'u' ? null : int.tryParse(winStr);
      if (band == null) return;
      // +162: the collection ceiling. Above 140 the cell is dropped from
      // the ledger WITHOUT a snapshot — it is measured, it is simply not
      // part of the atlas. Dropping (rather than skipping) keeps the
      // ledger from carrying a cell that can never leave it.
      if (band > kAtlasBandMaxCollectKmh) {
        frozenKeys.add(key);
        debugPrint('Atlas: drop band=$band (above the $kAtlasBandMaxCollectKmh '
            'collection ceiling)');
        return;
      }
      if (!all && win != windowFilter) return;
      if (cell.distKm <= 1e-6) return; // impossible by construction
      rows.add(AtlasSnapshotsCompanion(
        clientUuid: Value(uuidV7()),
        sessionUid: Value(l.sessionUid),
        source: const Value('hu'),
        bandKmh: Value(band),
        tempWindowC: Value(win),
        kwh100: Value(cell.energyKwh / cell.distKm * 100.0),
        steadySeconds: Value(cell.timeS),
        packTempAvgC: Value(cell.tempMeanC),
        startedAt:
            Value(DateTime.fromMillisecondsSinceEpoch(cell.startedAtMs)),
        frozenAt: Value(DateTime.fromMillisecondsSinceEpoch(frozenAtMs)),
        appVersion: Value(_appVersion),
        updatedAt: Value(now),
      ));
      frozenKeys.add(key);
      debugPrint('Atlas: freeze band=$band win=${win ?? 'u'} '
          'kwh=${(cell.energyKwh / cell.distKm * 100.0).toStringAsFixed(1)} '
          's=${cell.timeS.round()} session=${l.sessionUid.substring(0, 8)}…');
    });
    if (rows.isEmpty) {
      // Ceiling drops still have to leave the ledger.
      if (frozenKeys.isNotEmpty) {
        for (final k in frozenKeys) {
          l.cells.remove(k);
        }
        _dirtySincePersist = true;
        unawaited(_persist());
      }
      return;
    }
    for (final k in frozenKeys) {
      l.cells.remove(k);
      // +162 (§3.2): the intention is fulfilled the moment its cell
      // actually freezes — silently, with no congratulation card. The
      // reward for the intention is the new cell in the atlas.
      if (_intentBand != null && k == _intentKey()) {
        _intentBand = null;
        _intentWindow = null;
        _intentTakenMs = null;
        unawaited(_persistIntent());
      }
    }
    _atlasFreezeCount += rows.length;
    _dirtySincePersist = true;
    // INSERTs before the ledger persist (R2); Drift serialises writes,
    // overlapping funnels both end on an idempotent post-reset persist.
    unawaited(() async {
      try {
        for (final r in rows) {
          await _db.insertAtlasSnapshot(r);
        }
      } catch (e) {
        debugPrint('Atlas: freeze insert failed — $e');
      }
      await _persist();
      // +162: tell every cached DB reader that the atlas moved.
      _atlasRevision++;
      notifyListeners();
    }());
  }

  // ───────────── +160: reveal generation (spec §1.1–§1.2) ─────────────

  /// Queue one crossing into the serialized generation chain. The
  /// ledger identity (session uid + start) and the wall clock are
  /// captured SYNCHRONOUSLY at the crossing — the async checks must
  /// not see a rotated session.
  void _maybeGenerateReveal(int band, int? win, double kwh100) {
    final l = _ledger;
    if (l == null) return;
    // +162: the collection ceiling — above 140 there are no events at
    // all (the second and last place the number is enforced).
    if (band > kAtlasBandMaxCollectKmh) return;
    final sessionUid = l.sessionUid;
    final sessionStartMs = l.sessionStartedAtMs;
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    _revealChain = _revealChain
        .then((_) => _generateReveal(
            band, win, kwh100, sessionUid, sessionStartMs, nowMs))
        .catchError((Object e) {
      debugPrint('Atlas: reveal generation failed — $e');
    });
  }

  /// One crossing → at most ONE event (§1.2): band_matured suppresses
  /// cell_new (two lines about one fact are noise — the band milestone
  /// swallows the cell milestone); a first-snapshot cell IS star level
  /// 1 semantically, so star_up never fires at 1; star_up at 5 / 15
  /// implies snapshots exist, so it never collides with cell_new.
  /// Generation is SILENT — a DB row + the badge counter, no UI
  /// reaction in motion (инвариант И1; the badge itself only exists
  /// under P).
  Future<void> _generateReveal(int band, int? win, double kwh100,
      String sessionUid, int sessionStartMs, int nowMs) async {
    // band_matured — the FIRST maturity of this band in the atlas's
    // life: no snapshot of the band anywhere AND no prior band_matured
    // reveal (a reveal may predate its snapshot while the session is
    // still open — the second condition covers exactly that gap).
    final bandKnown = await _db.hasAtlasSnapshotForBand(band);
    if (!bandKnown && !await _hasReveal('band_matured', band: band)) {
      await _insertReveal('band_matured',
          {'band': band, 'kwh100': kwh100, 'window': win}, sessionUid);
      return; // подавление: band_matured поглощает cell_new (AY6)
    }

    final cellSnaps = await _db.getAtlasSnapshotsForCell(band, win);
    if (cellSnaps.isEmpty) {
      // cell_new — first snapshot of this band × window cell.
      if (!await _hasReveal('cell_new',
          band: band, window: win, matchWindow: true)) {
        await _insertReveal(
            'cell_new', {'band': band, 'window': win}, sessionUid);
      }
      return;
    }

    // star_up — the cell crosses 5 (silver) or 15 (gold) INDEPENDENT
    // logical sessions, live-corrected for the current one: if no
    // existing snapshot carries the current session_uid, the current
    // session rides in as a virtual [start, now] 'hu' group — the
    // union-frame equivalent of «+1 если не сливается по правилу
    // дедупа» (merging keeps the count, independence adds one).
    final lites = <SnapshotLite>[
      for (final r in cellSnaps)
        SnapshotLite(
          sessionUid: r.sessionUid,
          source: r.source,
          startedAtMs: r.startedAt.millisecondsSinceEpoch,
          frozenAtMs: r.frozenAt.millisecondsSinceEpoch,
        ),
    ];
    final contributed = cellSnaps.any((r) => r.sessionUid == sessionUid);
    if (!contributed) {
      lites.add(SnapshotLite(
        sessionUid: sessionUid,
        source: 'hu',
        startedAtMs: sessionStartMs,
        frozenAtMs: nowMs,
      ));
    }
    final count = dedupSessionCount(lites);
    if (count != 5 && count != 15) return;
    final level = count == 5 ? 'silver' : 'gold';
    // Existence check (§1.1: re-maturity after a freeze-reset is a new
    // round — the checks decide): a window-switch freeze inside one
    // session lets the same cell cross twice with the same count; the
    // level guard keeps the star single for the cell's lifetime.
    if (await _hasReveal('star_up',
        band: band, window: win, matchWindow: true, level: level)) {
      return;
    }
    await _insertReveal(
        'star_up',
        {'band': band, 'window': win, 'level': level, 'sessions': count},
        sessionUid);
  }

  /// Payload-level existence check — the reveal table is small by
  /// construction, parsing beats a JSON column query.
  Future<bool> _hasReveal(String type,
      {required int band,
      int? window,
      bool matchWindow = false,
      String? level}) async {
    final rows = await _db.getAtlasRevealsByType(type);
    for (final r in rows) {
      try {
        final p = jsonDecode(r.payloadJson) as Map<String, dynamic>;
        if ((p['band'] as num?)?.toInt() != band) continue;
        if (matchWindow && (p['window'] as num?)?.toInt() != window) {
          continue;
        }
        if (level != null && p['level'] != level) continue;
        return true;
      } catch (_) {
        // unparseable payload — treat as non-matching, never crash
      }
    }
    return false;
  }

  /// The single producer call-site of insertAtlasReveal (regress AY1).
  /// Born with syncedAt = null → the next push cycle delivers it
  /// (patch-1 plumbing; Друг 2 is expecting the channel to go live).
  Future<void> _insertReveal(
      String type, Map<String, dynamic> payload, String sessionUid) async {
    final now = DateTime.now();
    await _db.insertAtlasReveal(AtlasRevealsCompanion(
      clientUuid: Value(uuidV7()),
      sessionUid: Value(sessionUid),
      type: Value(type),
      payloadJson: Value(jsonEncode(payload)),
      createdAt: Value(now),
      updatedAt: Value(now),
    ));
    _atlasRevision++; // +162: a new reveal is a change of the atlas
    _unrevealedCount = await _db.countUnrevealedAtlasReveals();
    debugPrint('Atlas: reveal $type $payload (unrevealed '
        '$_unrevealedCount)');
    notifyListeners();
  }

  // ───────────── +160: parking summary card API (spec §2) ─────────────

  /// Real km of the current atlas session — the card's trip line.
  double get atlasSessionDistKm => _ledger?.sessionDistKm ?? 0;

  /// Current pack temperature for the trip line («пак 19°») — the same
  /// combined freshness priority the recorder itself integrates with.
  double? get currentPackTempC => _packTempC();

  /// «Σ gained по ячейкам с момента lastOkMs > 0» (§2.1): any
  /// qualified tick after the last «Ок» keeps the micro-loot card
  /// meaningful even at zero reveal events (§138 приёмки).
  bool get atlasHasUnseenGain {
    final l = _ledger;
    if (l == null) return false;
    final lg = l.lastGainMs;
    if (lg == null) return false;
    final lok = l.lastOkMs;
    return lok == null || lg > lok;
  }

  /// Micro-loot cell (§2.2 п.4): the un-matured cell (timeS < 120)
  /// with the LARGEST session gain; ties break toward the larger
  /// timeS. Null → everything matured / empty — the caller renders
  /// the degenerate «+{s} с ровного времени» line instead.
  ({int band, double gainedS, double timeS})? atlasLootCell() {
    final l = _ledger;
    if (l == null) return null;
    ({int band, double gainedS, double timeS})? best;
    l.cells.forEach((key, c) {
      if (c.timeS >= kBandMinSeconds) return; // matured — not loot
      final sep = key.indexOf(':');
      final band = int.tryParse(key.substring(0, sep));
      if (band == null) return;
      final b = best;
      if (b == null ||
          c.gainedS > b.gainedS ||
          (c.gainedS == b.gainedS && c.timeS > b.timeS)) {
        best = (band: band, gainedS: c.gainedS, timeS: c.timeS);
      }
    });
    return best;
  }

  /// Degenerate micro-loot fallback: total session gain across cells.
  double get atlasGainedTotalS {
    final l = _ledger;
    if (l == null) return 0;
    var sum = 0.0;
    for (final c in l.cells.values) {
      sum += c.gainedS;
    }
    return sum;
  }

  // ───────────── +162: intention (§3.2) and pending cells ─────────────

  String _intentKey() => '$_intentBand:${_intentWindow ?? 'u'}';

  Future<void> _persistIntent() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final b = _intentBand;
      if (b == null) {
        await prefs.remove(_kIntentBandKey);
        await prefs.remove(_kIntentWinKey);
        await prefs.remove(_kIntentMsKey);
        return;
      }
      await prefs.setInt(_kIntentBandKey, b);
      final w = _intentWindow;
      if (w == null) {
        await prefs.remove(_kIntentWinKey);
      } else {
        await prefs.setInt(_kIntentWinKey, w);
      }
      await prefs.setInt(_kIntentMsKey,
          _intentTakenMs ?? DateTime.now().millisecondsSinceEpoch);
    } catch (e) {
      debugPrint('Atlas: intent persist failed — $e');
    }
  }

  /// The taken intention, or null. An intention older than
  /// [kAtlasIntentTtlDays] reports as absent and clears itself — an
  /// untouched goal must fade, never nag.
  AtlasIntent? get atlasIntent {
    final b = _intentBand;
    final t = _intentTakenMs;
    if (b == null || t == null) return null;
    final ageDays = (DateTime.now().millisecondsSinceEpoch - t) / 86400000.0;
    if (ageDays > kAtlasIntentTtlDays) {
      _intentBand = null;
      _intentWindow = null;
      _intentTakenMs = null;
      unawaited(_persistIntent());
      return null;
    }
    return AtlasIntent(band: b, window: _intentWindow, takenAtMs: t);
  }

  /// Take (or replace) the intention. Replacing is silent: an intention
  /// is a note to self, not a contract.
  void takeAtlasIntent(int band, int? window) {
    if (band > kAtlasBandMaxCollectKmh) return;
    _intentBand = band;
    _intentWindow = window;
    _intentTakenMs = DateTime.now().millisecondsSinceEpoch;
    unawaited(_persistIntent());
    notifyListeners();
  }

  void clearAtlasIntent() {
    if (_intentBand == null) return;
    _intentBand = null;
    _intentWindow = null;
    _intentTakenMs = null;
    unawaited(_persistIntent());
    notifyListeners();
  }

  /// Default candidate for the intention card: the un-matured cell with
  /// the most steady time **inside the ACTIVE temperature window**.
  ///
  /// The +160 anticipation helper walked every window and returned a
  /// bare band, which is how the field got advice for a cell that could
  /// not be reached in today's weather (§3.2). Pinning the window fixes
  /// the advice at its source.
  AtlasIntent? atlasIntentCandidate() {
    final l = _ledger;
    if (l == null) return null;
    final win = l.activeWindow;
    int? band;
    var bestT = -1.0;
    l.cells.forEach((key, c) {
      if (c.timeS >= kBandMinSeconds) return;
      final sep = key.indexOf(':');
      final b = int.tryParse(key.substring(0, sep));
      if (b == null || b > kAtlasBandMaxCollectKmh) return;
      final winStr = key.substring(sep + 1);
      final int? w = winStr == 'u' ? null : int.tryParse(winStr);
      if (w != win) return; // ACTIVE window only — reachable today
      if (c.timeS > bestT) {
        bestT = c.timeS;
        band = b;
      }
    });
    final bb = band;
    if (bb == null) return null;
    return AtlasIntent(band: bb, window: win, takenAtMs: 0);
  }

  /// Cells that have matured but whose snapshot is not frozen yet — the
  /// freeze happens on session rotation, so between «полоса дозрела» and
  /// the new cell in the grid there is a real gap the field ran into
  /// (25.07: band 40 matured, the grid still showed three cells). The
  /// grid paints these as «дозрела, ждёт конца поездки». They are NOT
  /// cells: no counter, no star, no export fill.
  List<AtlasPendingCell> atlasPendingCells() {
    final l = _ledger;
    if (l == null) return const [];
    final out = <AtlasPendingCell>[];
    l.cells.forEach((key, c) {
      if (c.timeS < kBandMinSeconds) return;
      if (c.distKm <= 1e-6) return;
      final sep = key.indexOf(':');
      final b = int.tryParse(key.substring(0, sep));
      if (b == null || b > kAtlasBandMaxCollectKmh) return;
      final winStr = key.substring(sep + 1);
      final int? w = winStr == 'u' ? null : int.tryParse(winStr);
      out.add(AtlasPendingCell(
        band: b,
        window: w,
        kwh100: c.energyKwh / c.distKm * 100.0,
        steadySeconds: c.timeS,
      ));
    });
    return out;
  }

  /// Anticipation line (§2.2 п.5): the un-matured cell with
  /// timeS ≥ kAtlasAnticipationS and the largest timeS, or null.
  int? atlasAnticipationBand() {
    final l = _ledger;
    if (l == null) return null;
    int? band;
    var bestT = -1.0;
    l.cells.forEach((key, c) {
      if (c.timeS >= kBandMinSeconds || c.timeS < kAtlasAnticipationS) {
        return;
      }
      final sep = key.indexOf(':');
      final b = int.tryParse(key.substring(0, sep));
      if (b == null) return;
      if (c.timeS > bestT) {
        bestT = c.timeS;
        band = b;
      }
    });
    return band;
  }

  /// Card body — everything unrevealed, newest first per type.
  Future<List<AtlasRevealRow>> unrevealedReveals() =>
      _db.getUnrevealedAtlasReveals();

  /// «Ок» (§2.1): reveal EVERYTHING pending (revealedBy = 'hu',
  /// syncedAt → null for the re-push — the server merge is
  /// write-once), latch lastOkMs, drop the badge counter. Persisted
  /// immediately: a lost lastOkMs would re-show an honest card, but
  /// sloppy is sloppy.
  Future<void> acknowledgeReveals() async {
    final now = DateTime.now();
    try {
      await _db.revealAllUnrevealedAtlasReveals(now, revealedBy: 'hu');
      _atlasRevision++; // +162
      _unrevealedCount = await _db.countUnrevealedAtlasReveals();
    } catch (e) {
      debugPrint('Atlas: acknowledge failed — $e');
    }
    final l = _ledger;
    if (l != null) {
      l.lastOkMs = now.millisecondsSinceEpoch;
      _dirtySincePersist = true;
    }
    await _persist();
    notifyListeners();
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
            _dirtySincePersist = true; // +158: runs ride the dirty gate
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

