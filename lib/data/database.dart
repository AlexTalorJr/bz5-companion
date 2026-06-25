import 'package:drift/drift.dart';
import 'package:drift_flutter/drift_flutter.dart';
import 'package:path_provider/path_provider.dart';

import 'trip_extra.dart';

part 'database.g.dart';

/// Schema history:
///   v1 (pre-v0.1.9): Samples, Trips (basic), Snapshots (basic)
///   v2 (v0.1.9):     Trips +12 aggregate cols, Snapshots +7 cols
///   v3 (v0.1.11):    + SweepRuns, SweepResults tables for in-car sweeps
///                    (tables created empty in v0.1.11; populated in v0.1.12
///                    when in-car sweep UI ships)
///   v4 (v0.1.15):    + LiveLogSessions, LiveLogEntries tables for time-series
///                    polling of up to 7 DIDs simultaneously. Built on top of
///                    sweep infra; reuses pause-polling pattern.

/// Записывает каждое отдельное измерение значения DID.
@DataClassName('Sample')
class Samples extends Table {
  IntColumn get id => integer().autoIncrement()();
  IntColumn get tripId => integer().nullable().references(Trips, #id)();
  DateTimeColumn get timestamp => dateTime()();
  TextColumn get ecuTx => text().withLength(min: 3, max: 8)();
  TextColumn get did => text().withLength(min: 4, max: 4)();
  TextColumn get rawHex => text()();
  RealColumn get numericValue => real().nullable()();
  TextColumn get textValue => text().nullable()();
}

@DataClassName('Trip')
class Trips extends Table {
  IntColumn get id => integer().autoIncrement()();
  DateTimeColumn get startedAt => dateTime()();
  DateTimeColumn get endedAt => dateTime().nullable()();

  RealColumn get startSoc => real().nullable()();
  RealColumn get endSoc => real().nullable()();
  RealColumn get startOdometer => real().nullable()();
  RealColumn get endOdometer => real().nullable()();
  IntColumn get sampleCount => integer().withDefault(const Constant(0))();
  TextColumn get notes => text().nullable()();

  // v0.1.9 aggregates
  RealColumn get distanceKm => real().nullable()();
  RealColumn get energyUsedKwh => real().nullable()();
  RealColumn get avgConsumptionKwh100km => real().nullable()();
  RealColumn get minBatteryTempC => real().nullable()();
  RealColumn get maxBatteryTempC => real().nullable()();
  RealColumn get maxCellSpreadMv => real().nullable()();
  RealColumn get minSoc => real().nullable()();
  RealColumn get maxSoc => real().nullable()();
  RealColumn get peakSpeedKmh => real().nullable()();
  RealColumn get peakPowerKw => real().nullable()();
  RealColumn get peakRegenKw => real().nullable()();
  RealColumn get regenEnergyKwh => real().nullable()();

  // v0.1.21 additions (schema v5) — speed-based metrics enabled by the
  // discovery that 740/0x0008 is vehicle speed:
  RealColumn get avgMovingSpeedKmh => real().nullable()();
  IntColumn get movingSeconds => integer().nullable()();
  IntColumn get idleSeconds => integer().nullable()();
  // Precise SOC-based energy delta (via 790/0x1FFD high16 / 100). Same
  // unit as energyUsedKwh but computed from precise SOC rather than
  // power×time integration. Useful as a sanity check on the integrator.
  RealColumn get energyFromSocKwh => real().nullable()();

  // v0.1.29+37: JSON blob for compact derived aggregates that should
  // survive a DB wipe / reinstall via cloud backup (samples are NOT
  // uploaded — server rejects them 403 samples_disabled — so anything
  // we want restorable must live on the trip row). Currently holds the
  // speed-distribution histogram so a restored trip can still render its
  // Speed Distribution chart without the raw sample series. Nullable;
  // mirrors the server-side trips.extra jsonb that the bridge already
  // accepts. Schema-versioned inside the JSON ("v":1), not by column.
  TextColumn get extra => text().nullable()();
}

@DataClassName('Snapshot')
class Snapshots extends Table {
  IntColumn get id => integer().autoIncrement()();
  DateTimeColumn get capturedAt => dateTime()();

  RealColumn get soc => real().nullable()();
  RealColumn get soh => real().nullable()();
  RealColumn get batteryTempC => real().nullable()();
  RealColumn get cellVoltageMin => real().nullable()();
  RealColumn get cellVoltageMax => real().nullable()();
  RealColumn get cellSpread => real().nullable()();
  RealColumn get odometer => real().nullable()();
  IntColumn get tripId => integer().nullable().references(Trips, #id)();

  // v0.1.9 additions
  RealColumn get packVoltageV => real().nullable()();
  RealColumn get hvBusV => real().nullable()();
  IntColumn get gear => integer().nullable()();
  BoolColumn get pawlEngaged => boolean().nullable()();
  BoolColumn get isCharging => boolean().nullable()();
  RealColumn get chargingPowerKw => real().nullable()();
  IntColumn get cycleCount => integer().nullable()();
}

/// v0.1.11: header for a single in-car sweep run.
/// Populated by v0.1.12 sweep UI; tables exist in v0.1.11 schema so the
/// migration only happens once.
@DataClassName('SweepRun')
class SweepRuns extends Table {
  IntColumn get id => integer().autoIncrement()();
  DateTimeColumn get startedAt => dateTime()();
  DateTimeColumn get endedAt => dateTime().nullable()();
  TextColumn get txEcu => text()();
  TextColumn get rxEcu => text()();
  TextColumn get startDid => text()();
  TextColumn get endDid => text()();
  IntColumn get periodMs => integer().withDefault(const Constant(250))();
  TextColumn get carState => text().nullable()();   // e.g. "P+Ready, AC off"
  TextColumn get notes => text().nullable()();
  IntColumn get totalProbes => integer().withDefault(const Constant(0))();
  IntColumn get validResponses => integer().withDefault(const Constant(0))();
}

/// One row per probed DID in a sweep run.
@DataClassName('SweepResult')
class SweepResults extends Table {
  IntColumn get id => integer().autoIncrement()();
  IntColumn get sweepRunId => integer().references(SweepRuns, #id)();
  TextColumn get did => text()();
  TextColumn get rawHex => text().nullable()();
  TextColumn get errorCode => text().nullable()();
  IntColumn get sequence => integer()();
}

/// v0.1.15: header for a Live Log session.
/// Time-series polling of a small fixed set of DIDs (max 7) during driving.
/// Used to identify dynamic parameters (speed/power/current) by correlating
/// their values with vehicle behaviour over time, which a one-shot sweep
/// cannot do.
@DataClassName('LiveLogSession')
class LiveLogSessions extends Table {
  IntColumn get id => integer().autoIncrement()();
  DateTimeColumn get startedAt => dateTime()();
  DateTimeColumn get endedAt => dateTime().nullable()();
  /// Comma-separated list of "ecuTx/didHex" pairs, e.g. "791/0038,791/0101".
  /// Persists the exact set of DIDs polled in this session.
  TextColumn get didList => text()();
  TextColumn get carState => text().nullable()();
  TextColumn get notes => text().nullable()();
  /// Number of full poll cycles completed (1 cycle = one round of all DIDs).
  IntColumn get cycleCount => integer().withDefault(const Constant(0))();
  /// Total entries written (= cycleCount × didCount in the ideal case).
  IntColumn get entryCount => integer().withDefault(const Constant(0))();
}

/// v0.1.15: one row per (DID, poll cycle) within a Live Log session.
/// Indexed by sessionId+timestamp for time-series queries.
@DataClassName('LiveLogEntry')
class LiveLogEntries extends Table {
  IntColumn get id => integer().autoIncrement()();
  IntColumn get sessionId => integer().references(LiveLogSessions, #id)();
  DateTimeColumn get timestamp => dateTime()();
  TextColumn get ecuTx => text()();
  TextColumn get did => text()();
  TextColumn get rawHex => text().nullable()();
  TextColumn get errorCode => text().nullable()();
  /// Sequence within the session — same number for all DIDs polled in one
  /// cycle. Allows reconstructing rows: cycle 1: DID A, DID B; cycle 2: A, B.
  IntColumn get cycle => integer()();
}

/// v0.1.29+28: header for a CAN monitor session.
/// Passive CAN bus sniff via ELM327 `AT MA` (Monitor All). Unlike sweep or
/// livelog (UDS request/response on specific DIDs), this captures **all
/// broadcast frames** the adapter sees on the OBD-II bus segment over a
/// fixed time window. Primary use case: hunting CAN IDs documented in
/// BydDataCollect's VehicleData.conf (0x43D pack voltage, 0x444 pack
/// current/SOC, 0x46C MCU currents, 0x45B MCU voltage, 0x121 speed)
/// without needing UDS DIDs.
///
/// Independence: this is gated by its own [_canMonitorRunning] mutex
/// (mutually exclusive with sweep / live-log / DTC scan, same way they
/// guard each other). Has its own kill-signal / watchdog infrastructure
/// mirroring the +22/+24 livelog/sweep hardening; does not touch any
/// existing data path.
@DataClassName('CanMonitorSession')
class CanMonitorSessions extends Table {
  IntColumn get id => integer().autoIncrement()();
  DateTimeColumn get startedAt => dateTime()();
  DateTimeColumn get endedAt => dateTime().nullable()();
  /// CAN bus protocol used. ELM327 protocols: "6" = ISO 15765-4 CAN
  /// 11-bit 500kbps (the default we send via AT SP 6). Recorded so we
  /// can replay the bus configuration when re-analysing data.
  TextColumn get protocol => text().withDefault(const Constant('6'))();
  /// Requested duration in seconds (server-side cap).
  IntColumn get durationSec => integer()();
  TextColumn get carState => text().nullable()();
  TextColumn get notes => text().nullable()();
  /// Frames captured before the session ended (cancel / duration / BLE
  /// drop / watchdog).
  IntColumn get frameCount => integer().withDefault(const Constant(0))();
  /// Number of distinct CAN IDs seen. Single most useful number for
  /// answering "is the OBD-II gateway open or whitelist-only?" — a
  /// whitelist gateway will show 1-3 IDs (UDS traffic only), an open
  /// one will show 50+.
  IntColumn get uniqueCanIds => integer().withDefault(const Constant(0))();
}

/// v0.1.29+28: one row per CAN broadcast frame captured.
@DataClassName('CanFrame')
class CanFrames extends Table {
  IntColumn get id => integer().autoIncrement()();
  IntColumn get monitorSessionId =>
      integer().references(CanMonitorSessions, #id)();
  /// Monotonic count within the session — 0..N-1, set client-side at
  /// capture time. Cheaper than indexing on timestamp for replay.
  IntColumn get sequence => integer()();
  /// Wall-clock at capture (client device clock). Millisecond resolution.
  DateTimeColumn get tsMs => dateTime()();
  /// 3-hex-char (11-bit) or 8-hex-char (29-bit) CAN identifier, uppercase.
  TextColumn get canId => text()();
  /// Payload bytes as uppercase hex, no separators (e.g. "0102030405060708").
  TextColumn get payloadHex => text().withDefault(const Constant(''))();
}

/// v0.1.29+32: one row per RAW line emitted by the adapter during a
/// monitor session, captured BEFORE any parsing/filtering.
///
/// Why this exists: the [CanFrames] parser only stores lines it can
/// recognise as hex CAN frames (≥3 hex chars, all-hex). Anything else —
/// STN timestamp-prefixed frames, status strings ("BUFFER FULL",
/// "CAN ERROR"), odd delimiters, mixed formats from an unexpected
/// protocol — is silently dropped. During Path-A exploration (+32) we
/// don't yet know what format each protocol/filter combo will produce,
/// so we persist the unmodified line stream here for offline analysis.
/// If a config that looked like "0 frames" actually returned data in a
/// shape we didn't parse, it's recoverable from this table postfactum.
///
/// This is capture-everything-verbatim: do NOT filter on write. Bounded
/// only by the session duration and a per-line length guard applied at
/// the call site.
@DataClassName('CanRawLine')
class CanRawLines extends Table {
  IntColumn get id => integer().autoIncrement()();
  IntColumn get monitorSessionId =>
      integer().references(CanMonitorSessions, #id)();
  /// Monotonic count within the session — 0..N-1, set client-side.
  IntColumn get sequence => integer()();
  /// Wall-clock at capture (client device clock). Millisecond resolution.
  DateTimeColumn get tsMs => dateTime()();
  /// The line EXACTLY as received from monitorLines, before trimming,
  /// whitespace-stripping, hex-validation, or ID/payload splitting.
  TextColumn get rawLine => text()();
  /// True if the parser accepted this line as a CAN frame (so it also
  /// produced a CanFrames row). Lets offline analysis quickly isolate
  /// the lines we DIDN'T understand: `WHERE parsed = 0`.
  BoolColumn get parsed => boolean().withDefault(const Constant(false))();
}

/// v0.1.29+87: diagnostic capture of the HAL telemetry stream — the
/// second data source — so an export can show what HAL/BigData actually
/// delivered, at what rate, from which signal. Until now ONLY UDS samples
/// ([Samples]: ecuTx/did/rawHex) were persisted; HAL lived purely in
/// memory and vanished, which made it impossible to verify on the car why
/// a HAL-fed value (e.g. soc_precise) wasn't flowing. This table closes
/// that blind spot.
///
/// Two kinds of row, distinguished by [source]:
///   - 'hal'     — a decoded HAL signal: [name] + [numericValue]/[textValue].
///                 targetKey/subtype identify the framework origin.
///   - 'bigdata' — a raw BigData CAN frame: [canId] + [rawHex] (full frame
///                 hex incl. the 4-byte header). [name] is null. Lets us
///                 confirm a frame (e.g. 0x044C) arrived at all and inspect
///                 its bytes offline.
///
/// WRITE IS THROTTLED at the call site (see HalTelemetryService) — the HAL
/// stream is ~15 Hz aggregate and writing every frame would bloat the DB
/// (recon's lesson: raw 24 h = gigabytes). Decoded signals are sampled at
/// most once per few seconds per name; BigData raw is whitelisted to a few
/// CAN-IDs of interest, not the whole stream.
@DataClassName('HalSample')
class HalSamples extends Table {
  IntColumn get id => integer().autoIncrement()();
  IntColumn get tripId => integer().nullable()();
  DateTimeColumn get timestamp => dateTime()();
  /// 'hal' (decoded signal) or 'bigdata' (raw CAN frame).
  TextColumn get source => text()();
  /// Framework target, e.g. "BYDAutoStatisticDevice". Null for raw frames
  /// where only the CAN-ID is meaningful.
  TextColumn get targetKey => text().nullable()();
  /// HAL subtype/fid as uppercase hex (e.g. "2D300030"), or null.
  TextColumn get subtype => text().nullable()();
  /// Decoded signal name (e.g. "soc_precise", "speed"). Null for raw frames.
  TextColumn get name => text().nullable()();
  /// CAN-ID for raw BigData frames (e.g. "044C"). Null for decoded signals.
  TextColumn get canId => text().nullable()();
  /// Full raw frame hex for 'bigdata' rows. Null for decoded signals.
  TextColumn get rawHex => text().nullable()();
  RealColumn get numericValue => real().nullable()();
  TextColumn get textValue => text().nullable()();
}

@DriftDatabase(tables: [
  Samples, Trips, Snapshots,
  SweepRuns, SweepResults,
  LiveLogSessions, LiveLogEntries,
  CanMonitorSessions, CanFrames, CanRawLines,
  HalSamples,
])
class AppDatabase extends _$AppDatabase {
  AppDatabase() : super(_openConnection());

  @override
  int get schemaVersion => 9;

  @override
  MigrationStrategy get migration => MigrationStrategy(
        onCreate: (m) async {
          await m.createAll();
        },
        onUpgrade: (m, from, to) async {
          // v1 → v2 (v0.1.9): Trip + Snapshot extra columns.
          if (from < 2) {
            await m.addColumn(trips, trips.distanceKm);
            await m.addColumn(trips, trips.energyUsedKwh);
            await m.addColumn(trips, trips.avgConsumptionKwh100km);
            await m.addColumn(trips, trips.minBatteryTempC);
            await m.addColumn(trips, trips.maxBatteryTempC);
            await m.addColumn(trips, trips.maxCellSpreadMv);
            await m.addColumn(trips, trips.minSoc);
            await m.addColumn(trips, trips.maxSoc);
            await m.addColumn(trips, trips.peakSpeedKmh);
            await m.addColumn(trips, trips.peakPowerKw);
            await m.addColumn(trips, trips.peakRegenKw);
            await m.addColumn(trips, trips.regenEnergyKwh);

            await m.addColumn(snapshots, snapshots.packVoltageV);
            await m.addColumn(snapshots, snapshots.hvBusV);
            await m.addColumn(snapshots, snapshots.gear);
            await m.addColumn(snapshots, snapshots.pawlEngaged);
            await m.addColumn(snapshots, snapshots.isCharging);
            await m.addColumn(snapshots, snapshots.chargingPowerKw);
            await m.addColumn(snapshots, snapshots.cycleCount);
          }
          // v2 → v3 (v0.1.11): sweep tables.
          if (from < 3) {
            await m.createTable(sweepRuns);
            await m.createTable(sweepResults);
          }
          // v3 → v4 (v0.1.15): live-log tables.
          if (from < 4) {
            await m.createTable(liveLogSessions);
            await m.createTable(liveLogEntries);
          }
          // v4 → v5 (v0.1.21): speed-based trip metrics + SOC-derived
          // energy estimate. All additive (addColumn only), zero risk
          // to existing data.
          if (from < 5) {
            await m.addColumn(trips, trips.avgMovingSpeedKmh);
            await m.addColumn(trips, trips.movingSeconds);
            await m.addColumn(trips, trips.idleSeconds);
            await m.addColumn(trips, trips.energyFromSocKwh);
          }
          // v5 → v6 (v0.1.29+28): CAN passive-monitor tables.
          // Additive only — pre-existing tables untouched.
          if (from < 6) {
            await m.createTable(canMonitorSessions);
            await m.createTable(canFrames);
          }
          // v6 → v7 (v0.1.29+32): raw monitor-line capture table for
          // Path-A exploration. Additive only.
          if (from < 7) {
            await m.createTable(canRawLines);
          }
          // v7 → v8 (v0.1.29+37): trips.extra JSON blob for restorable
          // derived aggregates (speed-distribution histogram). Additive,
          // nullable — existing trip rows get NULL and behave exactly as
          // before (the UI falls back to raw samples when extra is null).
          if (from < 8) {
            await m.addColumn(trips, trips.extra);
          }
          // v8 → v9 (v0.1.29+87): HAL/BigData diagnostic capture table.
          // Additive only — pre-existing tables untouched, existing data
          // behaves exactly as before.
          if (from < 9) {
            await m.createTable(halSamples);
          }
        },
      );

  // ─────────────────────────── Trips ─────────────────────────────

  Future<int> startTrip({double? startSoc, double? startOdo}) {
    return into(trips).insert(TripsCompanion(
      startedAt: Value(DateTime.now()),
      startSoc: Value(startSoc),
      startOdometer: Value(startOdo),
    ));
  }

  /// v0.1.26+8: backfill start_soc / start_odometer for a trip whose row
  /// already exists. Used by the fallback capture path in ConnectionService:
  /// when _maybeStartTrip can't pull these anchors from _latestValues
  /// at trip-creation time (e.g. 791/0026 hadn't been read yet), a later
  /// successful read calls this to fix the column in-place.
  ///
  /// Idempotent and forgiving — passing null for either field leaves
  /// that column alone, so the caller can update just one anchor without
  /// racing the other.
  Future<void> updateTripStartAnchors(
    int tripId, {
    double? startSoc,
    double? startOdo,
  }) async {
    await (update(trips)..where((t) => t.id.equals(tripId))).write(
      TripsCompanion(
        startSoc: startSoc != null ? Value(startSoc) : const Value.absent(),
        startOdometer: startOdo != null ? Value(startOdo) : const Value.absent(),
      ),
    );
  }

  /// v0.1.21.1: find orphaned trips (endedAt IS NULL) from previous app
  /// runs. Caller should iterate and call [forceCloseTrip] on each.
  ///
  /// "Orphaned" here means: trip row exists, started in the past, but was
  /// never properly closed because the app crashed, BLE dropped without
  /// the fix path firing, or the user force-killed the app.
  /// v0.1.29+41: trips that need (re)finalization. Two cases:
  ///   1. endedAt IS NULL — classic orphan (never finalized).
  ///   2. endedAt set but distanceKm IS NULL — closed by the OLD
  ///      forceCloseTrip (or a finalize that ran with a stale cache)
  ///      that left summary fields empty even though samples exist.
  ///      Re-running forceCloseTrip on these backfills the aggregates
  ///      from the sample series (fixes the already-empty #1/#13/#15…
  ///      trips on the next app start, not just future ones).
  /// forceCloseTrip is idempotent (it only writes derived values), so
  /// re-closing an already-good trip is harmless — but we exclude trips
  /// that already have a distance to avoid needless work.
  Future<List<Trip>> getOrphanedTrips() {
    return (select(trips)
          ..where((t) => t.endedAt.isNull() | t.distanceKm.isNull())
          ..orderBy([(t) => OrderingTerm.asc(t.startedAt)]))
        .get();
  }

  /// v0.1.21.1: close an orphaned trip by setting endedAt to its last
  /// known sample timestamp (or startedAt + 1s as last resort) and
  /// leaving all summary fields null. Better than leaving the trip
  /// open forever — UI can show it as "(closed on recovery)".
  ///
  /// Returns the timestamp used.
  /// v0.1.29+41: force-close an orphaned trip. PREVIOUSLY this only set
  /// endedAt and left every summary field null — so an orphan (a trip the
  /// app never cleanly finalized: process killed, BLE drop down a path
  /// that skipped stopPolling/_finalizeTripFromLastKnown) showed up in
  /// history with samples present but distance/energy/sample_count all
  /// NULL. That was the actual cause of "trips empty in history, but the
  /// speed/SOC graphs render" — +38 only fixed the two interactive
  /// finalize paths and missed THIS one (orphan cleanup at session start).
  ///
  /// Now it recovers what it can straight from the sample series, which is
  /// intact even for an orphan: first/last odometer → distance, first/last
  /// SOC → energy (ΔSOC × capacity) → avg consumption, plus sample_count.
  /// [batteryCapacityKwh] is passed in so the DB layer stays free of any
  /// vehicle-model dependency. Best-effort: any field that can't be
  /// derived stays null (no fabricated values).
  Future<DateTime> forceCloseTrip(int tripId,
      {double? batteryCapacityKwh}) async {
    final lastSample = await (select(samples)
          ..where((s) => s.tripId.equals(tripId))
          ..orderBy([(s) => OrderingTerm.desc(s.timestamp)])
          ..limit(1))
        .getSingleOrNull();
    final trip = await getTrip(tripId);
    final endTs = lastSample?.timestamp ??
        (trip != null
            ? trip.startedAt.add(const Duration(seconds: 1))
            : DateTime.now());

    // Recover start/end odometer (791/0026) and SOC (790/0005) from the
    // sample series and derive the summary fields the live paths would
    // have computed.
    final startOdo = await firstNumericSampleForTrip(tripId, '791', '0026');
    final endOdo = await lastNumericSampleForTrip(tripId, '791', '0026');
    final startSoc = await firstNumericSampleForTrip(tripId, '790', '0005');
    final endSoc = await lastNumericSampleForTrip(tripId, '790', '0005');

    double? distanceKm;
    if (startOdo != null && endOdo != null && endOdo > startOdo) {
      distanceKm = endOdo - startOdo;
    }
    double? energyUsedKwh;
    if (batteryCapacityKwh != null &&
        startSoc != null &&
        endSoc != null &&
        startSoc > endSoc) {
      energyUsedKwh = (startSoc - endSoc) * batteryCapacityKwh / 100.0;
    }
    double? avgConsumption;
    if (distanceKm != null && energyUsedKwh != null && distanceKm > 0.1) {
      avgConsumption = (energyUsedKwh / distanceKm) * 100.0;
    }
    final sampleCount = await countSamplesForTrip(tripId);

    // Speed histogram too, so a recovered orphan also backs up its
    // distribution (mirrors the live endTrip path, +37).
    String? extraJson;
    try {
      extraJson = await computeSpeedHistogramJson(tripId);
    } catch (_) {}

    // v0.1.29+42: also recover the heavy aggregates (peak speed, temp/SOC
    // range, moving/idle, cell spread) from samples and merge them in, so
    // a force-closed trip isn't left with those columns blank (the screen
    // showed peak_speed=3.3 and empty temp/spread while the histogram had
    // real 60-70 km/h data). copyWith layers the light fields below on top
    // of the heavy companion.
    final heavy = await recoverHeavyAggregates(tripId);

    await (update(trips)..where((t) => t.id.equals(tripId))).write(
      heavy.copyWith(
        endedAt: Value(endTs),
        startOdometer:
            startOdo != null ? Value(startOdo) : const Value.absent(),
        endOdometer: endOdo != null ? Value(endOdo) : const Value.absent(),
        startSoc: startSoc != null ? Value(startSoc) : const Value.absent(),
        endSoc: endSoc != null ? Value(endSoc) : const Value.absent(),
        distanceKm:
            distanceKm != null ? Value(distanceKm) : const Value.absent(),
        energyUsedKwh: energyUsedKwh != null
            ? Value(energyUsedKwh)
            : const Value.absent(),
        avgConsumptionKwh100km: avgConsumption != null
            ? Value(avgConsumption)
            : const Value.absent(),
        sampleCount: Value(sampleCount),
        extra: extraJson != null ? Value(extraJson) : const Value.absent(),
      ),
    );
    return endTs;
  }

  Future endTrip(
    int id, {
    double? endSoc,
    double? endOdo,
    int? sampleCount,
    double? distanceKm,
    double? energyUsedKwh,
    double? avgConsumptionKwh100km,
    double? minBatteryTempC,
    double? maxBatteryTempC,
    double? maxCellSpreadMv,
    double? minSoc,
    double? maxSoc,
    double? peakSpeedKmh,
    double? peakPowerKw,
    double? peakRegenKw,
    double? regenEnergyKwh,
    // v0.1.21:
    double? avgMovingSpeedKmh,
    int? movingSeconds,
    int? idleSeconds,
    double? energyFromSocKwh,
    // v0.1.29+37: precomputed restorable aggregates (speed histogram).
    String? extra,
  }) {
    return (update(trips)..where((t) => t.id.equals(id))).write(
      TripsCompanion(
        endedAt: Value(DateTime.now()),
        endSoc: Value(endSoc),
        endOdometer: Value(endOdo),
        sampleCount:
            sampleCount != null ? Value(sampleCount) : const Value.absent(),
        distanceKm: Value(distanceKm),
        energyUsedKwh: Value(energyUsedKwh),
        avgConsumptionKwh100km: Value(avgConsumptionKwh100km),
        minBatteryTempC: Value(minBatteryTempC),
        maxBatteryTempC: Value(maxBatteryTempC),
        maxCellSpreadMv: Value(maxCellSpreadMv),
        minSoc: Value(minSoc),
        maxSoc: Value(maxSoc),
        peakSpeedKmh: Value(peakSpeedKmh),
        peakPowerKw: Value(peakPowerKw),
        peakRegenKw: Value(peakRegenKw),
        regenEnergyKwh: Value(regenEnergyKwh),
        // v0.1.21:
        avgMovingSpeedKmh: Value(avgMovingSpeedKmh),
        movingSeconds: Value(movingSeconds),
        idleSeconds: Value(idleSeconds),
        energyFromSocKwh: Value(energyFromSocKwh),
        // v0.1.29+37: only write extra when non-null, so a caller that
        // didn't compute it (or recomputed nothing) leaves any existing
        // value untouched rather than nulling it.
        extra: extra != null ? Value(extra) : const Value.absent(),
      ),
    );
  }

  /// v0.1.29+37: compute the speed-distribution histogram for a trip
  /// directly from its stored 740/0008 speed samples, returning the
  /// canonical extra-JSON string (or null if there are no usable speed
  /// samples). Called at endTrip so the histogram is frozen onto the
  /// trip row and survives a later DB wipe + cloud restore. Uses the
  /// shared [buildSpeedHistogram] so the result matches what
  /// SpeedHistogramCard would draw from the raw samples.
  Future<String?> computeSpeedHistogramJson(int tripId) async {
    final speedSamples =
        await getSamplesForTrip(tripId, ecuTx: '740', did: '0008');
    if (speedSamples.isEmpty) return null;
    final hist = buildSpeedHistogram(speedSamples.map((s) => s.numericValue));
    return TripExtra.encode(speedHist: hist);
  }

  Future<List<Trip>> getRecentTrips({int limit = 50}) {
    return (select(trips)
          ..orderBy(
              [(t) => OrderingTerm(expression: t.startedAt, mode: OrderingMode.desc)])
          ..limit(limit))
        .get();
  }

  Future<List<Trip>> getAllTrips() {
    return (select(trips)
          ..orderBy(
              [(t) => OrderingTerm(expression: t.startedAt, mode: OrderingMode.desc)]))
        .get();
  }

  Future<Trip?> getTrip(int id) {
    return (select(trips)..where((t) => t.id.equals(id))).getSingleOrNull();
  }

  /// v0.1.29+35: trips whose startedAt falls in [from, to], oldest first.
  /// Backs the Trends period aggregation (cumulative + per-period charts).
  /// Ordered ascending so the aggregator can walk them chronologically
  /// without re-sorting.
  Future<List<Trip>> getTripsInRange(DateTime from, DateTime to) {
    return (select(trips)
          ..where((t) =>
              t.startedAt.isBiggerOrEqualValue(from) &
              t.startedAt.isSmallerOrEqualValue(to))
          ..orderBy([(t) => OrderingTerm(expression: t.startedAt)]))
        .get();
  }

  // ─────────────────────────── Samples ───────────────────────────

  Future<int> insertSample({
    int? tripId,
    required String ecuTx,
    required String did,
    required String rawHex,
    double? numeric,
    String? text,
  }) {
    return into(samples).insert(SamplesCompanion(
      tripId: Value(tripId),
      timestamp: Value(DateTime.now()),
      ecuTx: Value(ecuTx),
      did: Value(did),
      rawHex: Value(rawHex),
      numericValue: Value(numeric),
      textValue: Value(text),
    ));
  }

  Future<List<Sample>> getSamplesForTrip(int tripId,
      {String? ecuTx, String? did}) {
    final query = select(samples)..where((s) => s.tripId.equals(tripId));
    if (ecuTx != null) query.where((s) => s.ecuTx.equals(ecuTx));
    if (did != null) query.where((s) => s.did.equals(did));
    query.orderBy([(s) => OrderingTerm(expression: s.timestamp)]);
    return query.get();
  }

  // ───────────────────── HAL diagnostic samples (+87) ─────────────────

  /// Insert one decoded HAL signal row (source='hal'). Throttled at the
  /// call site — see HalTelemetryService.
  Future<int> insertHalSignal({
    int? tripId,
    required String targetKey,
    required String subtype,
    required String name,
    double? numeric,
    String? text,
  }) {
    return into(halSamples).insert(HalSamplesCompanion(
      tripId: Value(tripId),
      timestamp: Value(DateTime.now()),
      source: const Value('hal'),
      targetKey: Value(targetKey),
      subtype: Value(subtype),
      name: Value(name),
      numericValue: Value(numeric),
      textValue: Value(text),
    ));
  }

  /// Insert one raw BigData CAN frame row (source='bigdata'). Whitelisted
  /// to CAN-IDs of interest at the call site.
  Future<int> insertBigDataFrame({
    int? tripId,
    required String canId,
    required String rawHex,
  }) {
    return into(halSamples).insert(HalSamplesCompanion(
      tripId: Value(tripId),
      timestamp: Value(DateTime.now()),
      source: const Value('bigdata'),
      canId: Value(canId),
      rawHex: Value(rawHex),
    ));
  }

  Future<List<HalSample>> getHalSamplesForTrip(int tripId, {String? source}) {
    final query = select(halSamples)..where((s) => s.tripId.equals(tripId));
    if (source != null) query.where((s) => s.source.equals(source));
    query.orderBy([(s) => OrderingTerm(expression: s.timestamp)]);
    return query.get();
  }

  /// v0.1.29+38: the most recent numeric sample value for a given DID in
  /// a trip, or null if none. Used at trip finalization as a fallback for
  /// end_odometer / end_soc when the in-memory _latestValues cache is
  /// stale/empty (791/0026 in particular times out once the car is moving,
  /// so the cache often lacks a fresh odometer at trip end — but the
  /// sample series in this table still has the last good reading).
  Future<double?> lastNumericSampleForTrip(
      int tripId, String ecuTx, String did) async {
    final row = await (select(samples)
          ..where((s) =>
              s.tripId.equals(tripId) &
              s.ecuTx.equals(ecuTx) &
              s.did.equals(did) &
              s.numericValue.isNotNull())
          ..orderBy([
            (s) => OrderingTerm(
                expression: s.timestamp, mode: OrderingMode.desc)
          ])
          ..limit(1))
        .getSingleOrNull();
    return row?.numericValue;
  }

  /// v0.1.29+41: mirror of lastNumericSampleForTrip but the EARLIEST
  /// non-null sample — used to recover a trip's start odometer/SOC when
  /// force-closing an orphan whose in-memory start values are long gone.
  Future<double?> firstNumericSampleForTrip(
      int tripId, String ecuTx, String did) async {
    final row = await (select(samples)
          ..where((s) =>
              s.tripId.equals(tripId) &
              s.ecuTx.equals(ecuTx) &
              s.did.equals(did) &
              s.numericValue.isNotNull())
          ..orderBy([
            (s) => OrderingTerm(
                expression: s.timestamp, mode: OrderingMode.asc)
          ])
          ..limit(1))
        .getSingleOrNull();
    return row?.numericValue;
  }

  /// v0.1.29+42: recover the "heavy" trip aggregates that +41 left null —
  /// peak speed, moving/idle split, avg moving speed, battery-temp range,
  /// SOC range, and max cell spread — by scanning the trip's sample
  /// series. These normally accumulate in connection.dart runtime state
  /// during a live trip; an orphaned/force-closed trip has no such state,
  /// so we derive them from the stored samples instead (which are intact —
  /// the screen showed the speed histogram fine while these scalars were
  /// blank). Returns a companion with only the recoverable fields set
  /// (Value.absent for anything with no samples), so callers can merge it
  /// without clobbering good values.
  ///
  /// Speed bookkeeping mirrors the live path: samples ≥ 1 km/h count as
  /// "moving", below as "idle"; seconds are estimated from the sample
  /// cadence (count × median inter-sample gap) since samples are the only
  /// time reference we have post-hoc.
  Future<TripsCompanion> recoverHeavyAggregates(int tripId) async {
    Future<List<double>> vals(String tx, String did) async {
      final rows = await (select(samples)
            ..where((s) =>
                s.tripId.equals(tripId) &
                s.ecuTx.equals(tx) &
                s.did.equals(did) &
                s.numericValue.isNotNull())
            ..orderBy([(s) => OrderingTerm(expression: s.timestamp)]))
          .get();
      return rows.map((r) => r.numericValue!).toList();
    }

    // Speed (740/0008): peak, avg-moving, moving/idle seconds.
    final speedRows = await (select(samples)
          ..where((s) =>
              s.tripId.equals(tripId) &
              s.ecuTx.equals('740') &
              s.did.equals('0008') &
              s.numericValue.isNotNull())
          ..orderBy([(s) => OrderingTerm(expression: s.timestamp)]))
        .get();

    double? peakSpeed;
    double? avgMoving;
    int? movingSec;
    int? idleSec;
    if (speedRows.isNotEmpty) {
      double maxS = 0, movingSum = 0;
      int movingN = 0, idleN = 0;
      for (final r in speedRows) {
        final v = r.numericValue!;
        if (v > maxS) maxS = v;
        if (v >= 1.0) {
          movingSum += v;
          movingN++;
        } else {
          idleN++;
        }
      }
      peakSpeed = maxS;
      if (movingN > 0) avgMoving = movingSum / movingN;
      // Estimate seconds from median inter-sample gap (robust to outliers).
      final gaps = <int>[];
      for (var i = 1; i < speedRows.length; i++) {
        gaps.add(speedRows[i].timestamp.millisecondsSinceEpoch -
            speedRows[i - 1].timestamp.millisecondsSinceEpoch);
      }
      double gapMs = 1000; // fallback 1s if only one sample
      if (gaps.isNotEmpty) {
        gaps.sort();
        gapMs = gaps[gaps.length ~/ 2].toDouble();
        if (gapMs <= 0 || gapMs > 10000) gapMs = 1000; // sanity
      }
      movingSec = (movingN * gapMs / 1000).round();
      idleSec = (idleN * gapMs / 1000).round();
    }

    // Battery temp (790/002F): min/max.
    final temps = await vals('790', '002F');
    double? minTemp, maxTemp;
    if (temps.isNotEmpty) {
      minTemp = temps.reduce((a, b) => a < b ? a : b);
      maxTemp = temps.reduce((a, b) => a > b ? a : b);
    }

    // SOC (790/0005): min/max.
    final socs = await vals('790', '0005');
    double? minSoc, maxSoc;
    if (socs.isNotEmpty) {
      minSoc = socs.reduce((a, b) => a < b ? a : b);
      maxSoc = socs.reduce((a, b) => a > b ? a : b);
    }

    // Cell spread: max over the trip of (maxCell 002D − minCell 002B).
    // Pair them by nearest timestamp would be ideal, but for a robust
    // post-hoc max-spread it's enough to take (max of 002D) − (min of
    // 002B) as an upper-bound estimate, then also the per-sample max if
    // both streams are dense. We use the simple bound: the largest 002D
    // minus the smallest 002B is the worst spread seen.
    final maxCells = await vals('790', '002D');
    final minCells = await vals('790', '002B');
    double? maxSpread;
    if (maxCells.isNotEmpty && minCells.isNotEmpty) {
      final hi = maxCells.reduce((a, b) => a > b ? a : b);
      final lo = minCells.reduce((a, b) => a < b ? a : b);
      if (hi >= lo) maxSpread = hi - lo;
    }

    return TripsCompanion(
      peakSpeedKmh:
          peakSpeed != null ? Value(peakSpeed) : const Value.absent(),
      avgMovingSpeedKmh:
          avgMoving != null ? Value(avgMoving) : const Value.absent(),
      movingSeconds:
          movingSec != null ? Value(movingSec) : const Value.absent(),
      idleSeconds: idleSec != null ? Value(idleSec) : const Value.absent(),
      minBatteryTempC:
          minTemp != null ? Value(minTemp) : const Value.absent(),
      maxBatteryTempC:
          maxTemp != null ? Value(maxTemp) : const Value.absent(),
      minSoc: minSoc != null ? Value(minSoc) : const Value.absent(),
      maxSoc: maxSoc != null ? Value(maxSoc) : const Value.absent(),
      maxCellSpreadMv:
          maxSpread != null ? Value(maxSpread) : const Value.absent(),
    );
  }

  /// v0.1.11: all samples for export (no filter). Use sparingly — can be huge.
  Future<List<Sample>> getAllSamples({int? limit}) {
    final q = select(samples)
      ..orderBy([(s) => OrderingTerm(expression: s.timestamp)]);
    if (limit != null) q.limit(limit);
    return q.get();
  }

  Future<int> countSamplesForTrip(int tripId) async {
    final cnt = countAll();
    final row = await (selectOnly(samples)
          ..addColumns([cnt])
          ..where(samples.tripId.equals(tripId)))
        .getSingle();
    return row.read(cnt) ?? 0;
  }

  Future<int> countAllSamples() async {
    final cnt = countAll();
    final row = await (selectOnly(samples)..addColumns([cnt])).getSingle();
    return row.read(cnt) ?? 0;
  }

  /// v0.1.29+87: all HAL diagnostic samples, oldest first, for export.
  Future<List<HalSample>> getAllHalSamples({int? limit}) {
    final q = select(halSamples)
      ..orderBy([(s) => OrderingTerm(expression: s.timestamp)]);
    if (limit != null) q.limit(limit);
    return q.get();
  }

  Future<int> countAllHalSamples() async {
    final cnt = countAll();
    final row = await (selectOnly(halSamples)..addColumns([cnt])).getSingle();
    return row.read(cnt) ?? 0;
  }

  // ────────────────────────── Snapshots ──────────────────────────

  Future<int> insertSnapshot(SnapshotsCompanion data) =>
      into(snapshots).insert(data);

  Future<List<Snapshot>> getRecentSnapshots({int limit = 1000}) {
    return (select(snapshots)
          ..orderBy(
              [(s) => OrderingTerm(expression: s.capturedAt, mode: OrderingMode.desc)])
          ..limit(limit))
        .get();
  }

  Future<List<Snapshot>> getAllSnapshots() {
    return (select(snapshots)
          ..orderBy([(s) => OrderingTerm(expression: s.capturedAt)]))
        .get();
  }

  Future<List<Snapshot>> getSnapshotsInRange(DateTime from, DateTime to) {
    return (select(snapshots)
          ..where((s) =>
              s.capturedAt.isBiggerOrEqualValue(from) &
              s.capturedAt.isSmallerOrEqualValue(to))
          ..orderBy([(s) => OrderingTerm(expression: s.capturedAt)]))
        .get();
  }

  Future<Snapshot?> getLatestSnapshot() {
    return (select(snapshots)
          ..orderBy(
              [(s) => OrderingTerm(expression: s.capturedAt, mode: OrderingMode.desc)])
          ..limit(1))
        .getSingleOrNull();
  }

  Future<int> countAllSnapshots() async {
    final cnt = countAll();
    final row = await (selectOnly(snapshots)..addColumns([cnt])).getSingle();
    return row.read(cnt) ?? 0;
  }

  // ────────────────────────── Sweeps (v0.1.11 schema, v0.1.12 fill) ──

  Future<int> insertSweepRun(SweepRunsCompanion data) =>
      into(sweepRuns).insert(data);

  Future<int> insertSweepResult(SweepResultsCompanion data) =>
      into(sweepResults).insert(data);

  Future<List<SweepRun>> getAllSweepRuns() {
    return (select(sweepRuns)
          ..orderBy(
              [(s) => OrderingTerm(expression: s.startedAt, mode: OrderingMode.desc)]))
        .get();
  }

  Future<List<SweepResult>> getSweepResults(int runId) {
    return (select(sweepResults)
          ..where((s) => s.sweepRunId.equals(runId))
          ..orderBy([(s) => OrderingTerm(expression: s.sequence)]))
        .get();
  }

  Future<int> countAllSweepRuns() async {
    final cnt = countAll();
    final row = await (selectOnly(sweepRuns)..addColumns([cnt])).getSingle();
    return row.read(cnt) ?? 0;
  }

  // ────────────────────────── LiveLog (v0.1.15) ──────────────────

  Future<int> insertLiveLogSession(LiveLogSessionsCompanion data) =>
      into(liveLogSessions).insert(data);

  Future<int> insertLiveLogEntry(LiveLogEntriesCompanion data) =>
      into(liveLogEntries).insert(data);

  Future<List<LiveLogSession>> getAllLiveLogSessions() {
    return (select(liveLogSessions)
          ..orderBy(
              [(s) => OrderingTerm(expression: s.startedAt, mode: OrderingMode.desc)]))
        .get();
  }

  Future<LiveLogSession?> getLiveLogSession(int id) {
    return (select(liveLogSessions)..where((s) => s.id.equals(id)))
        .getSingleOrNull();
  }

  Future<List<LiveLogEntry>> getLiveLogEntries(int sessionId) {
    return (select(liveLogEntries)
          ..where((e) => e.sessionId.equals(sessionId))
          ..orderBy([(e) => OrderingTerm(expression: e.cycle), (e) => OrderingTerm(expression: e.did)]))
        .get();
  }

  /// v0.1.21: fetch only one cycle's worth of entries, used by the
  /// post-cycle cell-pair sanity guard. Cheap query — usually 6 rows.
  Future<List<LiveLogEntry>> getLiveLogEntriesForCycle(
      int sessionId, int cycle) {
    return (select(liveLogEntries)
          ..where((e) => e.sessionId.equals(sessionId) & e.cycle.equals(cycle)))
        .get();
  }

  /// v0.1.21: post-update one livelog entry's error code without
  /// touching its rawHex. Used to retroactively flag a row that
  /// individually passed sanity but failed cross-DID validation.
  Future<int> markLiveLogEntryError(int entryId, String errorCode) {
    return (update(liveLogEntries)..where((e) => e.id.equals(entryId)))
        .write(LiveLogEntriesCompanion(
      rawHex: const Value(null),
      errorCode: Value(errorCode),
    ));
  }

  Future<int> countAllLiveLogSessions() async {
    final cnt = countAll();
    final row = await (selectOnly(liveLogSessions)..addColumns([cnt])).getSingle();
    return row.read(cnt) ?? 0;
  }

  // ────────────────────────── Cleanup ─────────────────────────────

  /// v0.1.11: delete samples older than [cutoff]. Returns rows deleted.
  /// Trips/snapshots/sweeps preserved — they're the long-term record.
  Future<int> pruneOldSamples(DateTime cutoff) async {
    return await (delete(samples)
          ..where((s) => s.timestamp.isSmallerThanValue(cutoff)))
        .go();
  }

  /// Delete ALL samples regardless of age. Use when user explicitly clicks
  /// "clear raw data" in Settings.
  Future<int> clearAllSamples() => delete(samples).go();

  /// Delete ALL snapshots. Wipes the long-term trends data.
  Future<int> clearAllSnapshots() => delete(snapshots).go();

  /// Delete ALL trips and their cascade samples.
  /// Returns (tripsDeleted, samplesDeleted).
  Future<(int, int)> clearAllTrips() async {
    final samplesDeleted = await delete(samples).go();
    final tripsDeleted = await delete(trips).go();
    return (tripsDeleted, samplesDeleted);
  }

  /// Delete ALL sweep runs and their results.
  Future<(int, int)> clearAllSweeps() async {
    final resultsDeleted = await delete(sweepResults).go();
    final runsDeleted = await delete(sweepRuns).go();
    return (runsDeleted, resultsDeleted);
  }

  /// v0.1.15: delete ALL live-log sessions and entries.
  Future<(int, int)> clearAllLiveLogs() async {
    final entriesDeleted = await delete(liveLogEntries).go();
    final sessionsDeleted = await delete(liveLogSessions).go();
    return (sessionsDeleted, entriesDeleted);
  }

  // ───────────────────── CAN monitor DAO (v0.1.29+28) ─────────────────

  Future<int> insertCanMonitorSession(CanMonitorSessionsCompanion data) =>
      into(canMonitorSessions).insert(data);

  Future<int> insertCanFrame(CanFramesCompanion data) =>
      into(canFrames).insert(data);

  Future<List<CanMonitorSession>> getAllCanMonitorSessions() {
    return (select(canMonitorSessions)
          ..orderBy([
            (s) => OrderingTerm(expression: s.startedAt, mode: OrderingMode.desc)
          ]))
        .get();
  }

  Future<CanMonitorSession?> getCanMonitorSession(int id) {
    return (select(canMonitorSessions)..where((s) => s.id.equals(id)))
        .getSingleOrNull();
  }

  Future<List<CanFrame>> getCanFrames(int sessionId) {
    return (select(canFrames)
          ..where((f) => f.monitorSessionId.equals(sessionId))
          ..orderBy([(f) => OrderingTerm(expression: f.sequence)]))
        .get();
  }

  // v0.1.29+32: raw monitor-line capture.
  Future<int> insertCanRawLine(CanRawLinesCompanion data) =>
      into(canRawLines).insert(data);

  Future<List<CanRawLine>> getCanRawLines(int sessionId) {
    return (select(canRawLines)
          ..where((r) => r.monitorSessionId.equals(sessionId))
          ..orderBy([(r) => OrderingTerm(expression: r.sequence)]))
        .get();
  }

  Future<(int, int, int)> clearAllCanMonitors() async {
    final rawDeleted = await delete(canRawLines).go();
    final framesDeleted = await delete(canFrames).go();
    final sessionsDeleted = await delete(canMonitorSessions).go();
    return (sessionsDeleted, framesDeleted, rawDeleted);
  }
}

QueryExecutor _openConnection() {
  return driftDatabase(
    name: 'bz5_data',
    native: const DriftNativeOptions(
      databaseDirectory: getApplicationSupportDirectory,
    ),
  );
}
