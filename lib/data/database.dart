import 'package:drift/drift.dart';
import 'package:drift_flutter/drift_flutter.dart';
import 'package:path_provider/path_provider.dart';

part 'database.g.dart';

/// v0.1.9 schema v2 changes:
///   - Trip: added aggregate columns (distance, energy used, avg/peak metrics,
///     min/max battery temp & cell spread, peak power & regen)
///   - Snapshot: added pack voltage, HV bus voltage, gear, parking pawl,
///     charging power for richer long-term trends
///   - New: indexes on Sample.timestamp and Snapshot.capturedAt for fast
///     time-range queries
///
/// Migration is automatic via the MigrationStrategy below. Existing user
/// data is preserved — new columns default to null until populated.

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

/// Поездка — сессия от старта до выключения зажигания (или вручную).
///
/// v0.1.9: aggregates are computed at endTrip from per-sample data.
/// Fields are nullable because:
///   1) old (pre-v2) trips don't have them
///   2) some metrics may not be computable (e.g., peakSpeedKmh until we
///      identify the speed DID)
/// UI falls back to "—" for null.
@DataClassName('Trip')
class Trips extends Table {
  IntColumn get id => integer().autoIncrement()();
  DateTimeColumn get startedAt => dateTime()();
  DateTimeColumn get endedAt => dateTime().nullable()();

  // Basic boundaries (v1, kept)
  RealColumn get startSoc => real().nullable()();
  RealColumn get endSoc => real().nullable()();
  RealColumn get startOdometer => real().nullable()();
  RealColumn get endOdometer => real().nullable()();
  IntColumn get sampleCount => integer().withDefault(const Constant(0))();
  TextColumn get notes => text().nullable()();

  // v0.1.9 aggregates computed from samples at endTrip:
  RealColumn get distanceKm => real().nullable()();          // end - start odometer
  RealColumn get energyUsedKwh => real().nullable()();       // from delta SOC × capacity
  RealColumn get avgConsumptionKwh100km => real().nullable()();

  // Battery health during trip
  RealColumn get minBatteryTempC => real().nullable()();
  RealColumn get maxBatteryTempC => real().nullable()();
  RealColumn get maxCellSpreadMv => real().nullable()();    // max(maxV - minV) across all samples
  RealColumn get minSoc => real().nullable()();              // intra-trip min (might dip below endSoc with regen)
  RealColumn get maxSoc => real().nullable()();

  // Drive metrics (filled when DIDs are identified)
  RealColumn get peakSpeedKmh => real().nullable()();
  RealColumn get peakPowerKw => real().nullable()();         // max instantaneous discharge power
  RealColumn get peakRegenKw => real().nullable()();         // max instantaneous regen power (signed negative)
  RealColumn get regenEnergyKwh => real().nullable()();      // total recovered energy
}

/// Снимок — состояние ключевых метрик в момент времени.
///
/// v0.1.9: written periodically by ConnectionService:
///   - every 2 min when a trip is active
///   - every 10 min when not in a trip
/// Powers long-term charts (24h / 7d / 30d / year / all-time).
@DataClassName('Snapshot')
class Snapshots extends Table {
  IntColumn get id => integer().autoIncrement()();
  DateTimeColumn get capturedAt => dateTime()();

  // v1 fields (kept)
  RealColumn get soc => real().nullable()();
  RealColumn get soh => real().nullable()();
  RealColumn get batteryTempC => real().nullable()();
  RealColumn get cellVoltageMin => real().nullable()();
  RealColumn get cellVoltageMax => real().nullable()();
  RealColumn get cellSpread => real().nullable()();
  RealColumn get odometer => real().nullable()();
  IntColumn get tripId => integer().nullable().references(Trips, #id)();

  // v0.1.9 additions:
  RealColumn get packVoltageV => real().nullable()();        // 740/0x0022
  RealColumn get hvBusV => real().nullable()();              // 790/0x0015
  IntColumn get gear => integer().nullable()();              // 791/0x0009: 1=P, 2=R, 3=N, 4=D
  BoolColumn get pawlEngaged => boolean().nullable()();
  BoolColumn get isCharging => boolean().nullable()();
  RealColumn get chargingPowerKw => real().nullable()();
  IntColumn get cycleCount => integer().nullable()();        // 790/0x0B02 — slow-changing
}

@DriftDatabase(tables: [Samples, Trips, Snapshots])
class AppDatabase extends _$AppDatabase {
  AppDatabase() : super(_openConnection());

  /// v0.1.9: bumped to 2.
  /// v2 added: distance/energy/avg-consumption/peak-* on Trip,
  /// pack/HV/gear/charging on Snapshot.
  @override
  int get schemaVersion => 2;

  @override
  MigrationStrategy get migration => MigrationStrategy(
        onCreate: (m) async {
          await m.createAll();
        },
        onUpgrade: (m, from, to) async {
          // v1 → v2: add new aggregate columns to trips and snapshots.
          // No data loss — all new columns are nullable.
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

  /// v0.1.9: endTrip now accepts pre-computed aggregates from ConnectionService
  /// (it has the rolling stats from polling, no need to re-aggregate from db).
  Future endTrip(
    int id, {
    double? endSoc,
    double? endOdo,
    int? sampleCount,
    // v0.1.9 aggregates:
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
        sampleCount: sampleCount != null ? Value(sampleCount) : const Value.absent(),
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
          ..orderBy([(t) => OrderingTerm(expression: t.startedAt, mode: OrderingMode.desc)])
          ..limit(limit))
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

  Future<List<Sample>> getSamplesForTrip(int tripId, {String? ecuTx, String? did}) {
    final query = select(samples)..where((s) => s.tripId.equals(tripId));
    if (ecuTx != null) query.where((s) => s.ecuTx.equals(ecuTx));
    if (did != null) query.where((s) => s.did.equals(did));
    query.orderBy([(s) => OrderingTerm(expression: s.timestamp)]);
    return query.get();
  }

  /// v0.1.9: count samples for a trip without loading them (for badges/UI).
  Future<int> countSamplesForTrip(int tripId) async {
    final cnt = countAll();
    final row = await (selectOnly(samples)
          ..addColumns([cnt])
          ..where(samples.tripId.equals(tripId)))
        .getSingle();
    return row.read(cnt) ?? 0;
  }

  // ────────────────────────── Snapshots ──────────────────────────

  Future<int> insertSnapshot(SnapshotsCompanion data) => into(snapshots).insert(data);

  Future<List<Snapshot>> getRecentSnapshots({int limit = 1000}) {
    return (select(snapshots)
          ..orderBy([(s) => OrderingTerm(expression: s.capturedAt, mode: OrderingMode.desc)])
          ..limit(limit))
        .get();
  }

  /// v0.1.9: snapshots within a time range, ordered ascending (for charts).
  Future<List<Snapshot>> getSnapshotsInRange(DateTime from, DateTime to) {
    return (select(snapshots)
          ..where((s) => s.capturedAt.isBiggerOrEqualValue(from) &
              s.capturedAt.isSmallerOrEqualValue(to))
          ..orderBy([(s) => OrderingTerm(expression: s.capturedAt)]))
        .get();
  }

  /// Most recent snapshot regardless of trip — useful to know "when did we last save".
  Future<Snapshot?> getLatestSnapshot() {
    return (select(snapshots)
          ..orderBy([(s) => OrderingTerm(expression: s.capturedAt, mode: OrderingMode.desc)])
          ..limit(1))
        .getSingleOrNull();
  }

  /// v0.1.9: prune samples older than [cutoff] to keep DB size bounded.
  /// Trips and Snapshots are NOT pruned — they're the long-term record.
  /// Returns count of deleted rows.
  Future<int> pruneOldSamples(DateTime cutoff) async {
    return await (delete(samples)..where((s) => s.timestamp.isSmallerThanValue(cutoff))).go();
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
