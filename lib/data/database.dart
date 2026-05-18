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

@DriftDatabase(tables: [
  Samples, Trips, Snapshots,
  SweepRuns, SweepResults,
  LiveLogSessions, LiveLogEntries,
])
class AppDatabase extends _$AppDatabase {
  AppDatabase() : super(_openConnection());

  @override
  int get schemaVersion => 4;

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
}

QueryExecutor _openConnection() {
  return driftDatabase(
    name: 'bz5_data',
    native: const DriftNativeOptions(
      databaseDirectory: getApplicationSupportDirectory,
    ),
  );
}
