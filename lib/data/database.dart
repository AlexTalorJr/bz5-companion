import 'package:drift/drift.dart';
import 'package:drift_flutter/drift_flutter.dart';

part 'database.g.dart';

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
}

/// Снимок — что-то вроде "состояние всех ECU в момент времени".
/// Используется для health-screen и архивных данных.
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
}

@DriftDatabase(tables: [Samples, Trips, Snapshots])
class AppDatabase extends _$AppDatabase {
  AppDatabase() : super(_openConnection());

  @override
  int get schemaVersion => 1;

  // Trips
  Future<int> startTrip({double? startSoc, double? startOdo}) {
    return into(trips).insert(TripsCompanion(
      startedAt: Value(DateTime.now()),
      startSoc: Value(startSoc),
      startOdometer: Value(startOdo),
    ));
  }

  Future endTrip(int id, {double? endSoc, double? endOdo, int? sampleCount}) {
    return (update(trips)..where((t) => t.id.equals(id))).write(
      TripsCompanion(
        endedAt: Value(DateTime.now()),
        endSoc: Value(endSoc),
        endOdometer: Value(endOdo),
        sampleCount: sampleCount != null ? Value(sampleCount) : const Value.absent(),
      ),
    );
  }

  Future<List<Trip>> getRecentTrips({int limit = 50}) {
    return (select(trips)
          ..orderBy([(t) => OrderingTerm(expression: t.startedAt, mode: OrderingMode.desc)])
          ..limit(limit))
        .get();
  }

  // Samples
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

  // Snapshots (для долговременной истории)
  Future<int> insertSnapshot(SnapshotsCompanion data) => into(snapshots).insert(data);

  Future<List<Snapshot>> getRecentSnapshots({int limit = 1000}) {
    return (select(snapshots)
          ..orderBy([(s) => OrderingTerm(expression: s.capturedAt, mode: OrderingMode.desc)])
          ..limit(limit))
        .get();
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
