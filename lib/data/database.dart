import 'package:drift/drift.dart';
import 'package:drift_flutter/drift_flutter.dart';
import 'package:path_provider/path_provider.dart';

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

@DriftDatabase(tables: [
  Samples, Trips, Snapshots,
  SweepRuns, SweepResults,
  LiveLogSessions, LiveLogEntries,
  CanMonitorSessions, CanFrames,
])
class AppDatabase extends _$AppDatabase {
  AppDatabase() : super(_openConnection());

  @override
  int get schemaVersion => 6;

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
  Future<List<Trip>> getOrphanedTrips() {
    return (select(trips)
          ..where((t) => t.endedAt.isNull())
          ..orderBy([(t) => OrderingTerm.asc(t.startedAt)]))
        .get();
  }

  /// v0.1.21.1: close an orphaned trip by setting endedAt to its last
  /// known sample timestamp (or startedAt + 1s as last resort) and
  /// leaving all summary fields null. Better than leaving the trip
  /// open forever — UI can show it as "(closed on recovery)".
  ///
  /// Returns the timestamp used.
  Future<DateTime> forceCloseTrip(int tripId) async {
    // Find latest sample for this trip
    final lastSample = await (select(samples)
          ..where((s) => s.tripId.equals(tripId))
          ..orderBy([(s) => OrderingTerm.desc(s.timestamp)])
          ..limit(1))
        .getSingleOrNull();
    final trip = await getTrip(tripId);
    final endTs = lastSample?.timestamp ??
        (trip != null ? trip.startedAt.add(const Duration(seconds: 1)) : DateTime.now());
    await (update(trips)..where((t) => t.id.equals(tripId)))
        .write(TripsCompanion(endedAt: Value(endTs)));
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
      ),
    );
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

  Future<(int, int)> clearAllCanMonitors() async {
    final framesDeleted = await delete(canFrames).go();
    final sessionsDeleted = await delete(canMonitorSessions).go();
    return (sessionsDeleted, framesDeleted);
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
