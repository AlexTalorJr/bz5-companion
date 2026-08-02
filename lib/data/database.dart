import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:drift_flutter/drift_flutter.dart';
import 'package:flutter/foundation.dart' show debugPrint;
import 'package:path_provider/path_provider.dart';

import 'trip_extra.dart';
import 'uuid_v7.dart';

part 'database.g.dart';

/// v0.1.83+182: одна строка фонового журнала HAL для пакетной вставки.
///
/// Запись, а не класс, и объявлена ЗДЕСЬ, а не в `hal_bg_journal.dart`:
/// иначе база импортировала бы сервис, который импортирует базу. Круговой
/// импорт Dart переварит, но читаться дерево перестанет.
typedef BgHalRow = ({
  DateTime at,
  String name,
  String? targetKey,
  String? subtype,
  double? value,
});

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
  // v0.1.29+94: tags a sample as belonging to a charging-log session
  // (per-module UDS capture during DC/AC charge). Null for normal trip /
  // ad-hoc samples. A trip sample has tripId set; a charging sample has
  // chargingSessionId set; the two are mutually exclusive in practice
  // (charging happens with no active trip). Lets recon filter the charge
  // block out of the export by one column.
  TextColumn get chargingSessionId => text().nullable()();
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

  /// v0.1.86+185: ПРОИСХОЖДЕНИЕ ПОЕЗДКИ. Пусто — поездка построена живым
  /// путём из OBD2, как все поездки до этого патча; правило честности
  /// («агрегаты поездки чисто OBD2») для таких строк соблюдено буквально.
  /// 'hal_bg' — поездка собрана постфактум из фонового журнала HAL, когда
  /// приложение было закрыто. Колонка добавлена, а не переиспользована
  /// под `notes`, именно чтобы HAL-поездка нигде не притворялась
  /// донглом: прецедент — `soh_estimates.source`, где HAL так же
  /// подписывается открыто.
  TextColumn get source => text().nullable()();

  // v0.1.29+37: JSON blob for compact derived aggregates that should
  // survive a DB wipe / reinstall via cloud backup (samples are NOT
  // uploaded — server rejects them 403 samples_disabled — so anything
  // we want restorable must live on the trip row). Currently holds the
  // speed-distribution histogram so a restored trip can still render its
  // Speed Distribution chart without the raw sample series. Nullable;
  // mirrors the server-side trips.extra jsonb that the bridge already
  // accepts. Schema-versioned inside the JSON ("v":1), not by column.
  TextColumn get extra => text().nullable()();

  // v0.1.29+106: watchdog "last alive" timestamp for an active HAL trip. The
  // HAL tracker stamps this (plus the current aggregates) every ~15 s while a
  // trip is live, WITHOUT setting endedAt — so the row stays ACTIVE and
  // cloud-sync won't push it early, but a process kill (head unit sleep) leaves
  // a recent checkpoint. Orphan recovery then closes the trip at this time with
  // the aggregates already on the row, instead of "ACTIVE 2 h / all dashes".
  // Local-only: NOT serialized into the trip JSON (server schema unchanged).
  DateTimeColumn get lastAliveTs => dateTime().nullable()();

  // v0.1.29+117 (C1, spec v1.3 D1): globally-unique UUIDv7 identity for cloud
  // dedup — survives local-DB wipes where the autoincrement id restarts and
  // silently overwrites server trips (UPSERT on (device_id, client_trip_id)).
  // Nullable by design: a row without a uuid stays valid (restore payloads
  // predating S4 don't carry one; the restore path generates locally).
  // Uniqueness enforced by a partial unique index (SQLite can't ADD COLUMN
  // UNIQUE), created in the from<14 migration step.
  TextColumn get clientUuid => text().nullable()();
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

  // v0.1.29+117 (C1): cloud dedup identity — see Trips.clientUuid.
  TextColumn get clientUuid => text().nullable()();
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

  // v0.1.29+117 (C1): cloud dedup identity — see Trips.clientUuid.
  TextColumn get clientUuid => text().nullable()();
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

  // v0.1.29+117 (C1): cloud dedup identity — see Trips.clientUuid.
  TextColumn get clientUuid => text().nullable()();
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

  // v0.1.29+117 (C1): cloud dedup identity — see Trips.clientUuid.
  TextColumn get clientUuid => text().nullable()();
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

/// v0.1.29+104: persisted result of the independent coulomb-counted SOH
/// estimate. v0.1.29+105: now up to TWO rows — id=1 (UDS, dongle) and id=2
/// (HAL, dongle-free) — each holding the LAST valid result for its estimator.
/// The Ah method yields one figure per qualifying charge session (ΔSOC ≥ 20%
/// and ≥ 90% current-coverage), so there is no time series to keep here; the
/// dashboard reads the latest value, preferring HAL (id=2) over UDS (id=1).
/// Survives restarts. When no row exists yet, the UI falls back to the
/// BMS-reported SOH (0x0029) with a "(BMS)" tag.
class SohEstimates extends Table {
  /// Row id. Two independent estimators share this single table:
  ///   id=1 → UDS coulomb count (ConnectionService, dongle-fed pack_current)
  ///   id=2 → HAL coulomb count (HalTelemetryService, dongle-free pack_current)
  /// Splitting by id keeps the two sources from blind last-write-wins over
  /// each other; the dashboard prefers HAL (id=2) then UDS (id=1) then BMS.
  IntColumn get id => integer()();
  /// Independent SOH estimate, percent (full_Ah / batteryCapacityAh × 100).
  RealColumn get sohAhPct => real()();
  /// When this estimate was computed (charge-session close time).
  DateTimeColumn get computedAt => dateTime()();
  /// SOC span covered by the session that produced it, percent — for
  /// transparency / debugging (a wider span is a more trustworthy estimate).
  RealColumn get deltaSocCovered => real()();
  /// v0.1.29+105: which estimator produced this row ('uds' | 'hal'). Nullable
  /// for backward compatibility — a pre-+105 row (always UDS) reads as null
  /// and is treated as 'uds' by callers.
  TextColumn get source => text().nullable()();

  @override
  Set<Column> get primaryKey => {id};
}

/// v0.1.31+130 (Trends v2): append-only history of coulomb-counted SOH
/// estimates. SohEstimates above keeps only the LAST value per estimator
/// (the dashboard widget reads it); this table accumulates the full time
/// series so the Trends tab can plot Ah-method degradation over months.
/// Never updated, never deleted — one row per qualifying charge session
/// (dedup guard in [AppDatabase.appendSohHistory] filters the HAL
/// crash-recovery re-write of the same session).
class SohHistory extends Table {
  IntColumn get id => integer().autoIncrement()();

  /// Independent SOH estimate, percent (full_Ah / batteryCapacityAh × 100).
  RealColumn get sohAhPct => real()();

  /// When this estimate was computed (charge-session close time).
  DateTimeColumn get computedAt => dateTime()();

  /// SOC span covered by the producing session, percent.
  RealColumn get deltaSocCovered => real()();

  /// Which estimator produced this row: 'uds' | 'hal'. NOT nullable — the
  /// table is new, there are no legacy rows to accommodate.
  TextColumn get source => text()();

  /// Reserved for a future cloud sync of this table (push v2 style dedup
  /// key). Always null until that patch lands; nullable so the sync patch
  /// is a pure addColumn-free backfill.
  TextColumn get clientUuid => text().nullable()();
}

/// v0.1.41+140: downsampled per-trip chart series (SPEC trip_series).
/// One row = one series of one trip, points as a JSON blob
/// `[[epoch_s, value], ...]` (≤240, LTTB). Synced to the cloud as a
/// first-class restore-scope entity — the structural fix for "charts die
/// on every head-unit reinstall" (samples/hal_samples never leave the
/// device; these do). Identity is (tripClientUuid, series) — the trip's
/// client_uuid, NOT its restart-prone local id; tripId here is only the
/// local FK convenience link, re-derivable at any time.
@DataClassName('TripSeriesRow')
class TripSeries extends Table {
  IntColumn get id => integer().autoIncrement()();

  /// UUIDv7 of this row (pull idempotency); immutable server-side.
  TextColumn get clientUuid => text()();

  /// client_uuid of the owning trip — the wipe-safe linkage key.
  TextColumn get tripClientUuid => text()();

  /// Local trip FK (nullable: a pulled orphan may precede its trip;
  /// re-linked lazily after every pull pass).
  IntColumn get tripId => integer().nullable()();

  /// Series vocabulary (client-owned): 'soc' | 'battery_temp_c' |
  /// 'pack_voltage_v' | 'power_kw'.
  TextColumn get series => text()();

  /// Downsampler version tag, currently 'lttb240'.
  TextColumn get algo => text()();

  IntColumn get pointCount => integer()();
  DateTimeColumn get tsMin => dateTime()();
  DateTimeColumn get tsMax => dateTime()();

  /// JSON text: [[epoch_s, value], ...] ascending, no nulls.
  TextColumn get pointsJson => text()();

  /// Push watermark: null → needs push; set on 200 from ingest.
  /// Regeneration nulls it again.
  DateTimeColumn get syncedAt => dateTime().nullable()();

  DateTimeColumn get updatedAt => dateTime()();
}

/// v0.1.59+158 «Атлас» patch 1: one frozen band reading — the atom of the
/// atlas collection (spec v2 + API contract 3a6ca9ed…48faf). Immutable,
/// append-only: a row is INSERTed once by the freeze funnel in
/// SpeedProfileService and never updated — sync is conflict-free by
/// construction. Cloud is the canon (BZ5 cannot update-in-place; every
/// install wipes the local DB), the device is a cache: rows push through
/// /v1/data/ingest/atlas_snapshots and come back via the unified
/// /v2/sync/pull + restore, exactly the trip_series pattern.
@DataClassName('AtlasSnapshotRow')
class AtlasSnapshots extends Table {
  IntColumn get id => integer().autoIncrement()();

  /// UUIDv7 of this row — the idempotency key (server UNIQUE on
  /// (vehicle_id, client_uuid); pulled duplicates are skipped locally).
  TextColumn get clientUuid => text()();

  /// Atlas session uid (UUIDv7, rotates on the 30-min idle gap). Feeds
  /// the CONTRACT-fixed client-side session dedup for coverage stars.
  TextColumn get sessionUid => text()();

  /// 'hu' | 'phone' (verbatim, the cloud is multi-make).
  TextColumn get source => text()();

  IntColumn get bandKmh => integer()();

  /// Lower bound of the 5 °C pack-temp window (−20…35, multiple of 5;
  /// −20 also holds everything colder — «≤ −20»). NULL = «t° неизвестна»
  /// (reserve for cars without a usable pack-temp source).
  IntColumn get tempWindowC => integer().nullable()();

  /// Signed consumption — regen-heavy descent cells may be ≤ 0; written
  /// honestly (server CHECK removed by agreement, 23.07).
  RealColumn get kwh100 => real()();

  RealColumn get steadySeconds => real()();
  RealColumn get packTempAvgC => real().nullable()();

  /// First qualified tick of this accumulation round — may PREDATE the
  /// freezing session (sub-120 s accumulation carries across trips).
  DateTimeColumn get startedAt => dateTime()();
  DateTimeColumn get frozenAt => dateTime()();

  TextColumn get appVersion => text().nullable()();

  /// Push watermark: null → needs push; set on 200 from ingest and on
  /// pull-apply (a pulled row is server-side by definition).
  DateTimeColumn get syncedAt => dateTime().nullable()();

  DateTimeColumn get updatedAt => dateTime()();
}

/// v0.1.59+158: reveal-event queue for the parking summary card.
/// Table + sync land in patch 1 (one migration, one plumbing pass);
/// EVENT GENERATION is deliberately absent until patch 2 (карточка
/// итогов) — regress AX6 pins that promise, so an empty queue in the
/// field is expected, not a bug. The ONLY mutable field is revealedAt
/// (+revealedBy): write-once, first-write-wins, mirrored on the server
/// by the COALESCE upsert — the card never shows twice across devices.
@DataClassName('AtlasRevealRow')
class AtlasReveals extends Table {
  IntColumn get id => integer().autoIncrement()();
  TextColumn get clientUuid => text()();
  TextColumn get sessionUid => text()();

  /// band_matured | star_up | cell_new (patch-2 vocabulary).
  TextColumn get type => text()();

  /// Event payload verbatim (band, window, value, star…). NEVER touched
  /// by the write-once update — the null-preserve-upsert trap.
  TextColumn get payloadJson => text()();

  DateTimeColumn get createdAt => dateTime()();
  DateTimeColumn get revealedAt => dateTime().nullable()();
  TextColumn get revealedBy => text().nullable()();

  /// Push watermark. A LOCAL reveal (patch 2) nulls it again so the row
  /// re-pushes and the server merges write-once.
  DateTimeColumn get syncedAt => dateTime().nullable()();
  DateTimeColumn get updatedAt => dateTime()();
}

@DriftDatabase(tables: [
  Samples, Trips, Snapshots,
  SweepRuns, SweepResults,
  LiveLogSessions, LiveLogEntries,
  CanMonitorSessions, CanFrames, CanRawLines,
  HalSamples,
  SohEstimates,
  SohHistory,
  TripSeries,
  AtlasSnapshots,
  AtlasReveals,
])
class AppDatabase extends _$AppDatabase {
  AppDatabase() : super(_openConnection());

  /// +166 (D1): база на переданном исполнителе — для тестов
  /// (`NativeDatabase.memory()`). Приложение продолжает ходить через
  /// обычный конструктор и файловую базу.
  AppDatabase.forTesting(QueryExecutor e) : super(e);

  @override
  int get schemaVersion => 18;

  @override
  MigrationStrategy get migration => MigrationStrategy(
        onCreate: (m) async {
          await m.createAll();
        },
        onUpgrade: (m, from, to) async {
          // v0.1.29+125: migration start marker — with the AppDiagLog
          // ring buffer (+122) the whole run is visible on-device.
          debugPrint('DB migrate: $from → $to starting');
          // v1 → v2 (v0.1.9): Trip + Snapshot extra columns.
          if (from < 2) {
            await _addColumnIfAbsent(m, trips, trips.distanceKm);
            await _addColumnIfAbsent(m, trips, trips.energyUsedKwh);
            await _addColumnIfAbsent(m, trips, trips.avgConsumptionKwh100km);
            await _addColumnIfAbsent(m, trips, trips.minBatteryTempC);
            await _addColumnIfAbsent(m, trips, trips.maxBatteryTempC);
            await _addColumnIfAbsent(m, trips, trips.maxCellSpreadMv);
            await _addColumnIfAbsent(m, trips, trips.minSoc);
            await _addColumnIfAbsent(m, trips, trips.maxSoc);
            await _addColumnIfAbsent(m, trips, trips.peakSpeedKmh);
            await _addColumnIfAbsent(m, trips, trips.peakPowerKw);
            await _addColumnIfAbsent(m, trips, trips.peakRegenKw);
            await _addColumnIfAbsent(m, trips, trips.regenEnergyKwh);

            await _addColumnIfAbsent(m, snapshots, snapshots.packVoltageV);
            await _addColumnIfAbsent(m, snapshots, snapshots.hvBusV);
            await _addColumnIfAbsent(m, snapshots, snapshots.gear);
            await _addColumnIfAbsent(m, snapshots, snapshots.pawlEngaged);
            await _addColumnIfAbsent(m, snapshots, snapshots.isCharging);
            await _addColumnIfAbsent(m, snapshots, snapshots.chargingPowerKw);
            await _addColumnIfAbsent(m, snapshots, snapshots.cycleCount);
          }
          // v2 → v3 (v0.1.11): sweep tables.
          if (from < 3) {
            await _createTableIfAbsent(m, sweepRuns);
            await _createTableIfAbsent(m, sweepResults);
          }
          // v3 → v4 (v0.1.15): live-log tables.
          if (from < 4) {
            await _createTableIfAbsent(m, liveLogSessions);
            await _createTableIfAbsent(m, liveLogEntries);
          }
          // v4 → v5 (v0.1.21): speed-based trip metrics + SOC-derived
          // energy estimate. All additive (addColumn only), zero risk
          // to existing data.
          if (from < 5) {
            await _addColumnIfAbsent(m, trips, trips.avgMovingSpeedKmh);
            await _addColumnIfAbsent(m, trips, trips.movingSeconds);
            await _addColumnIfAbsent(m, trips, trips.idleSeconds);
            await _addColumnIfAbsent(m, trips, trips.energyFromSocKwh);
          }
          // v5 → v6 (v0.1.29+28): CAN passive-monitor tables.
          // Additive only — pre-existing tables untouched.
          if (from < 6) {
            await _createTableIfAbsent(m, canMonitorSessions);
            await _createTableIfAbsent(m, canFrames);
          }
          // v6 → v7 (v0.1.29+32): raw monitor-line capture table for
          // Path-A exploration. Additive only.
          if (from < 7) {
            await _createTableIfAbsent(m, canRawLines);
          }
          // v7 → v8 (v0.1.29+37): trips.extra JSON blob for restorable
          // derived aggregates (speed-distribution histogram). Additive,
          // nullable — existing trip rows get NULL and behave exactly as
          // before (the UI falls back to raw samples when extra is null).
          if (from < 8) {
            await _addColumnIfAbsent(m, trips, trips.extra);
          }
          // v8 → v9 (v0.1.29+87): HAL/BigData diagnostic capture table.
          // Additive only — pre-existing tables untouched, existing data
          // behaves exactly as before.
          if (from < 9) {
            await _createTableIfAbsent(m, halSamples);
          }
          // v9 → v10 (v0.1.29+94): samples.charging_session_id for the
          // per-module UDS charge logger. Additive, nullable — existing
          // sample rows get NULL (they're trip / ad-hoc samples, unchanged).
          if (from < 10) {
            await _addColumnIfAbsent(m, samples, samples.chargingSessionId);
          }
          // v10 → v11 (v0.1.29+104): soh_estimates single-row table for the
          // independent coulomb-counted SOH result. Additive (createTable) —
          // pre-existing tables untouched; until the first qualifying charge
          // session writes a row, the UI falls back to BMS SOH (0x0029).
          if (from < 11) {
            await _createTableIfAbsent(m, sohEstimates);
          }
          // v11 → v12 (v0.1.29+105): add soh_estimates.source so the UDS
          // (id=1) and HAL (id=2) coulomb-count estimators can coexist in the
          // single table without overwriting each other. Additive + nullable
          // (addColumn) — any pre-existing id=1 row stays valid and reads as
          // null → treated as 'uds' by callers.
          if (from < 12) {
            await _addColumnIfAbsent(m, sohEstimates, sohEstimates.source);
          }
          if (from < 13) {
            // v0.1.29+106: watchdog last-alive checkpoint for HAL trips.
            await _addColumnIfAbsent(m, trips, trips.lastAliveTs);
          }
          // v13 → v14 (v0.1.29+117, cloud-v2 C1 / spec v1.3 D1): client_uuid
          // (UUIDv7) on the 5 syncable parent tables — the global cloud dedup
          // key. Additive + nullable (addColumn); uniqueness via partial
          // unique indexes because SQLite can't ADD COLUMN UNIQUE (NULLs
          // excluded so uuid-less rows never conflict). Existing rows are
          // backfilled with UUIDv7 stamped from their own started_at /
          // captured_at (cosmetic ordering only — the server treats the uuid
          // as opaque, pull is ordered by server_seq; review Q6).
          if (from < 14) {
            await _addColumnIfAbsent(m, trips, trips.clientUuid);
            await _addColumnIfAbsent(m, snapshots, snapshots.clientUuid);
            await _addColumnIfAbsent(m, sweepRuns, sweepRuns.clientUuid);
            await _addColumnIfAbsent(m, liveLogSessions, liveLogSessions.clientUuid);
            await _addColumnIfAbsent(
                m, canMonitorSessions, canMonitorSessions.clientUuid);
            for (final table in const [
              'trips',
              'snapshots',
              'sweep_runs',
              'live_log_sessions',
              'can_monitor_sessions',
            ]) {
              await customStatement(
                  'CREATE UNIQUE INDEX IF NOT EXISTS idx_${table}_client_uuid '
                  'ON $table (client_uuid) WHERE client_uuid IS NOT NULL');
            }
            await _backfillClientUuids();
          }
          // v14 → v15 (v0.1.31+130, Trends v2): soh_history append-only
          // time series of coulomb-counted SOH estimates. Additive
          // (createTable), idempotent via _createTableIfAbsent — same
          // pattern as v10→v11 for soh_estimates. Empty until the first
          // qualifying charge session after the upgrade; the Trends SOH
          // combo card shows the BMS line alone until then.
          if (from < 15) {
            await _createTableIfAbsent(m, sohHistory);
          }
          // v15 → v16 (v0.1.41+140): trip_series — downsampled chart
          // series, cloud-synced restore-scope entity. Additive
          // (createTable), idempotent via _createTableIfAbsent.
          if (from < 16) {
            await _createTableIfAbsent(m, tripSeries);
          }
          // v16 → v17 (v0.1.59+158): atlas_snapshots + atlas_reveals —
          // the Атлас data layer (immutable band readings + write-once
          // reveal queue), both cloud-synced restore-scope entities.
          // Additive (createTable), idempotent via _createTableIfAbsent.
          if (from < 17) {
            await _createTableIfAbsent(m, atlasSnapshots);
            await _createTableIfAbsent(m, atlasReveals);
          }
          // v17 → v18 (v0.1.86+185): trips.source — происхождение поездки.
          // Строго аддитивно и nullable: у всех существующих строк остаётся
          // null, что и означает «OBD2, живой путь». Ни одна старая
          // поездка не переписывается и не перечитывается.
          if (from < 18) {
            await _addColumnIfAbsent(m, trips, trips.source);
          }
          debugPrint('DB migrate: $from → $to complete');
        },
      );

  // ── v0.1.29+125: idempotent migration guards ──────────────────────
  //
  // Field incident (phone, 2026-07-05): a 9→14 upgrade chain was
  // interrupted mid-run (long 13→14 backfill on a large DB; process
  // killed), leaving the ALTERs of the early steps applied but
  // user_version still at 9. Every subsequent open re-ran step 9→10 and
  // died on "duplicate column: charging_session_id" — wedging ALL DB
  // access until reinstall. These guards make every structural step
  // safely re-runnable, so a torn migration self-heals on the next
  // launch instead of bricking the app. (The 13→14 tail was already
  // idempotent: indexes are IF NOT EXISTS, the uuid backfill filters
  // WHERE client_uuid IS NULL.)

  Future<bool> _columnExists(String table, String column) async {
    final rows = await customSelect('PRAGMA table_info($table)').get();
    return rows.any((r) => r.data['name'] == column);
  }

  Future<bool> _tableExists(String table) async {
    final rows = await customSelect(
        "SELECT name FROM sqlite_master WHERE type='table' AND name = ?",
        variables: [Variable.withString(table)]).get();
    return rows.isNotEmpty;
  }

  Future<void> _addColumnIfAbsent(
      Migrator m, TableInfo table, GeneratedColumn column) async {
    if (await _columnExists(table.actualTableName, column.name)) {
      debugPrint('DB migrate: ${table.actualTableName}.${column.name} '
          'already present — skipped');
      return;
    }
    await m.addColumn(table, column);
  }

  Future<void> _createTableIfAbsent(Migrator m, TableInfo table) async {
    if (await _tableExists(table.actualTableName)) {
      debugPrint('DB migrate: table ${table.actualTableName} '
          'already present — skipped');
      return;
    }
    await m.createTable(table);
  }

  /// v0.1.29+117 (C1): stamp a UUIDv7 onto every pre-schema-14 row of the 5
  /// syncable tables. Runs once inside the from<14 migration step.
  ///
  /// Raw SQL on purpose: (a) typed queries inside a migration are fragile if
  /// the schema mid-migration doesn't match the generated code, and (b) the
  /// timestamp column may be stored either as INTEGER unix-seconds (drift
  /// default) or as ISO-8601 TEXT depending on build options — the raw read
  /// handles both, so the backfill can't silently mis-parse.
  Future<void> _backfillClientUuids() async {
    const specs = [
      ('trips', 'started_at'),
      ('snapshots', 'captured_at'),
      ('sweep_runs', 'started_at'),
      ('live_log_sessions', 'started_at'),
      ('can_monitor_sessions', 'started_at'),
    ];
    for (final (table, tsCol) in specs) {
      final rows = await customSelect(
              'SELECT id, $tsCol AS ts FROM $table WHERE client_uuid IS NULL')
          .get();
      for (final row in rows) {
        final id = row.read<int>('id');
        final rawTs = row.data['ts'];
        DateTime? ts;
        if (rawTs is int) {
          // drift default: unix seconds.
          ts = DateTime.fromMillisecondsSinceEpoch(rawTs * 1000);
        } else if (rawTs is String) {
          ts = DateTime.tryParse(rawTs);
        }
        await customUpdate(
          'UPDATE $table SET client_uuid = ? WHERE id = ?',
          variables: [
            Variable<String>(uuidV7(time: ts)),
            Variable<int>(id),
          ],
        );
      }
    }
  }

  // ─────────────────────────── Trips ─────────────────────────────

  Future<int> startTrip({double? startSoc, double? startOdo}) {
    return into(trips).insert(TripsCompanion(
      startedAt: Value(DateTime.now()),
      startSoc: Value(startSoc),
      startOdometer: Value(startOdo),
      // v0.1.29+117 (C1): every new trip is born with its cloud identity.
      clientUuid: Value(uuidV7()),
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
    // v0.1.29+101: optional explicit end time. Defaults to now (the OBD2
    // tracker and every existing caller rely on that). The HAL charge-onset
    // close passes the stop time so a trip that ends because a charge began
    // is dated to when driving actually stopped, not when the close fired.
    DateTime? endedAt,
  }) async {
    return (update(trips)..where((t) => t.id.equals(id))).write(
      TripsCompanion(
        endedAt: Value(endedAt ?? DateTime.now()),
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
        // v0.1.87+186: `extra` ЗДЕСЬ БОЛЬШЕ НЕ ПИШЕТСЯ ЦЕЛИКОМ — см.
        // слияние ниже. Перезапись блоба была безопасна, пока писатель был
        // один; теперь их трое, и она стала тихой потерей чужого ключа.
      ),
    );
    // Слияние — второй запрос, поэтому оба под транзакцией: процесс на
    // этом ГУ умирает штатно, по зажиганию, и врозь они оставили бы
    // поездку с агрегатами и без гистограммы.
    if (extra != null) {
      await transaction(() async {
        await mergeTripExtra(id, extra);
      });
    }
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

  /// v0.1.29+93: HAL-source speed samples for a trip, oldest first. A HAL
  /// trip (head unit, no dongle) records speed into hal_samples as
  /// name='speed' (source='hal'), NOT into the OBD2 `samples` table as
  /// 740/0008 — so the OBD2 getSamplesForTrip above returns nothing for it.
  /// This is the HAL-side equivalent the speed-distribution chart falls back
  /// to. Speed is the same physical quantity from a different source (the
  /// cluster value, live-verified vs OBD2 to 1-3 km/h), so the histogram is
  /// directly comparable — only the sample cadence differs (the diagnostic
  /// log is throttled, so the HAL series is coarser than the OBD2 poll, but
  /// the distribution shape is preserved).
  Future<List<HalSample>> getHalSpeedSamplesForTrip(int tripId) {
    return (select(halSamples)
          ..where((s) =>
              s.tripId.equals(tripId) &
              s.source.equals('hal') &
              s.name.equals('speed'))
          ..orderBy([(s) => OrderingTerm.asc(s.timestamp)]))
        .get();
  }

  /// v0.1.29+93: mirror of computeSpeedHistogramJson for a HAL trip — build
  /// the canonical extra-JSON from hal_samples speed rows so the chart
  /// survives a DB wipe + cloud restore exactly like an OBD2 trip. Same
  /// shared buildSpeedHistogram / bins, so the rendered chart is identical
  /// in form regardless of source. Returns null when the trip has no HAL
  /// speed samples (then the caller leaves extra untouched).
  /// v0.1.29+111: generic per-name HAL series for a trip (oldest first) —
  /// the chart-tile fallback for dongle-free trips. Values are decoded
  /// physical quantities (same units as the registry-decoded OBD2 series),
  /// so a chart can consume either source unchanged.
  Future<List<HalSample>> getHalSamplesForTripByName(int tripId, String name) {
    return (select(halSamples)
          ..where((s) =>
              s.tripId.equals(tripId) &
              s.source.equals('hal') &
              s.name.equals(name))
          ..orderBy([(s) => OrderingTerm.asc(s.timestamp)]))
        .get();
  }

  Future<String?> computeHalSpeedHistogramJson(int tripId) async {
    final speedSamples = await getHalSpeedSamplesForTrip(tripId);
    if (speedSamples.isEmpty) return null;
    final hist = buildSpeedHistogram(speedSamples.map((s) => s.numericValue));
    return TripExtra.encode(speedHist: hist);
  }

  /// v0.1.29+93: write just the `extra` column for a trip (the speed-
  /// histogram JSON). Used by the HAL finalize path, which computes the
  /// histogram from hal_samples AFTER endTrip has written the row — endTrip
  /// can't carry it because the async hal_samples read isn't done at the
  /// synchronous snapshot point. No-op-safe: a null leaves the column alone.
  Future<void> updateTripExtra(int tripId, String? extraJson) async {
    if (extraJson == null) return;
    await mergeTripExtra(tripId, extraJson);
  }

  /// v0.1.87+186 — СЛИЯНИЕ, А НЕ ПЕРЕЗАПИСЬ.
  ///
  /// `trips.extra` — общий блоб, и писателей у него теперь трое: живой
  /// путь кладёт туда гистограмму скорости В КОНЦЕ поездки, фоновый
  /// строитель — метку происхождения ПРИ ВСТАВКЕ, а патч живого старта
  /// добавит `joinedInProgress` В НАЧАЛЕ. При перезаписи целиком конец
  /// съедал бы начало, и метка «подхватили на ходу» исчезала бы ровно на
  /// тех поездках, ради которых заводилась. Молча: сервер увидел бы
  /// валидный JSON без ключа и счёл бы это отсутствием флага.
  ///
  /// Незнакомые ключи сохраняются. Блоб принадлежит контракту с сервером
  /// (`CLIENT_API.md` §3.1), и клиент не вправе решать, какие из них лишние.
  Future<void> mergeTripExtra(int tripId, String patchJson) async {
    Map<String, dynamic> merged;
    try {
      final row = await (select(trips)..where((t) => t.id.equals(tripId)))
          .getSingleOrNull();
      final cur = row?.extra;
      merged = <String, dynamic>{};
      if (cur != null && cur.isNotEmpty) {
        final decoded = jsonDecode(cur);
        if (decoded is Map) merged.addAll(decoded.cast<String, dynamic>());
      }
      final patch = jsonDecode(patchJson);
      if (patch is Map) merged.addAll(patch.cast<String, dynamic>());
    } catch (e) {
      // Битый существующий блоб не должен утащить за собой новые ключи —
      // но и затирать его молча нельзя. Пишем патч и говорим об этом.
      debugPrint('mergeTripExtra: existing extra unreadable ($e) — '
          'writing patch alone');
      await (update(trips)..where((t) => t.id.equals(tripId))).write(
        TripsCompanion(extra: Value(patchJson)),
      );
      return;
    }
    await (update(trips)..where((t) => t.id.equals(tripId))).write(
      TripsCompanion(extra: Value(jsonEncode(merged))),
    );
  }

  /// v0.1.29+98: write the sample_count for a trip. Used by the HAL trip
  /// finaliser to backfill the count from hal_samples (the OBD2 tracker sets
  /// this inline via endTrip's sampleCount arg; the HAL per-sample stream is
  /// in hal_samples, so its count is read separately and written here).
  Future<void> updateTripSampleCount(int tripId, int count) async {
    await (update(trips)..where((t) => t.id.equals(tripId))).write(
      TripsCompanion(sampleCount: Value(count)),
    );
  }

  Future<List<Trip>> getRecentTrips({int limit = 50}) {
    return (select(trips)
          ..orderBy(
              [(t) => OrderingTerm(expression: t.startedAt, mode: OrderingMode.desc)])
          ..limit(limit))
        .get();
  }

  /// v0.1.29+91: lifetime cumulative drive energy (kWh) = SUM(energy_used_kwh)
  /// across every trip row (OBD2 AND HAL — they share this table; HAL trips
  /// are written by HalTelemetryService on the head unit). Carried over from
  /// trip to trip by definition (it's a running total of per-trip energy).
  /// Returns 0.0 when there are no trips / no energy recorded yet. NOTE: this
  /// is a sum of per-trip CONSUMPTION (ΔSOC-derived); it does not subtract
  /// charging between trips, so it is "energy spent driving", not a net
  /// battery balance — the label reflects that.
  Future<double> totalDriveEnergyKwh() async {
    final expr = trips.energyUsedKwh.sum();
    final q = selectOnly(trips)..addColumns([expr]);
    final row = await q.getSingleOrNull();
    return row?.read(expr) ?? 0.0;
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

  // ───────────────── HAL trip orphan recovery (+92) ─────────────────
  //
  // A HAL trip (written by HalTelemetryService on the head unit) is opened
  // with startTrip and finalised with endTrip on a clean Park-and-wait close.
  // But the normal way a drive ENDS is ignition-off, which kills the HU
  // process before the Park-window timer (which only ticks while HAL frames
  // keep arriving) can fire _closeHalTrip. The row is then left endedAt=NULL
  // forever, and the next drive opens a SECOND active row on top of it — the
  // "two ACTIVE trips" Alex saw (#42 stayed open at ignition-off, #43 opened
  // next start).
  //
  // The OBD2 side already recovers its own orphans (getOrphanedTrips +
  // forceCloseTrip in connection.dart), but that path is BLE-gated (never
  // runs on a dongle-less head unit) and forceCloseTrip reads the OBD2
  // `samples` table — a HAL orphan has none, so it can't recover the real
  // end time or aggregates. These helpers are the HAL-side equivalent, run
  // from HalTelemetryService.init() on the head unit.

  /// Open trip rows (endedAt IS NULL), oldest first. Used by
  /// HalTelemetryService._recoverOrphanHalTrips at startup. The caller
  /// excludes the live trip in Dart (it is null at init() time anyway), so
  /// the query itself stays a single trivial predicate.
  Future<List<Trip>> getOpenTrips() {
    return (select(trips)
          ..where((t) => t.endedAt.isNull())
          ..orderBy([(t) => OrderingTerm.asc(t.startedAt)]))
        .get();
  }

  /// Newest hal_samples timestamp for a trip, or null if the row has no HAL
  /// samples. This is the REAL end-of-drive instant for variant A: the last
  /// moment the HAL stream produced a frame before ignition-off. Recovery
  /// uses it as endedAt so a recovered trip's duration reflects when it
  /// actually ended, not when the app next happened to start.
  Future<DateTime?> lastHalSampleTimeForTrip(int tripId) async {
    final row = await (select(halSamples)
          ..where((s) => s.tripId.equals(tripId))
          ..orderBy([(s) => OrderingTerm.desc(s.timestamp)])
          ..limit(1))
        .getSingleOrNull();
    return row?.timestamp;
  }

  /// Count hal_samples tagged to a trip (companion to the OBD2
  /// countSamplesForTrip). Lets recovery distinguish an empty pup (no HAL
  /// samples, nothing worth keeping) from a real drive that simply wasn't
  /// closed cleanly.
  Future<int> countHalSamplesForTrip(int tripId) async {
    final cnt = countAll();
    final row = await (selectOnly(halSamples)
          ..addColumns([cnt])
          ..where(halSamples.tripId.equals(tripId)))
        .getSingle();
    return row.read(cnt) ?? 0;
  }

  /// Close an orphaned HAL trip at an EXPLICIT end timestamp (variant A),
  /// leaving every summary field exactly as it is. endTrip() can't be used
  /// here because it hard-codes endedAt = DateTime.now(); a recovered orphan
  /// must carry its real last-sample time instead. Aggregates are left
  /// untouched (null for a power-off orphan that never finalised) — honest,
  /// no fabricated values, same spirit as the OBD2 forceCloseTrip.
  /// [note] is appended to the row so history can mark it as recovered.
  Future<void> closeHalOrphanAt(int tripId, DateTime endTs,
      {String? note, double? energyUsedKwh}) async {
    await (update(trips)..where((t) => t.id.equals(tripId))).write(
      TripsCompanion(
        endedAt: Value(endTs),
        notes: note != null ? Value(note) : const Value.absent(),
        // v0.1.29+106: optional coarse energy reconstruction for a pre-watchdog
        // orphan (lastAliveTs == null). Written only when supplied; null leaves
        // the column untouched (no fabricated value on the watchdog path).
        energyUsedKwh:
            energyUsedKwh != null ? Value(energyUsedKwh) : const Value.absent(),
      ),
    );
  }

  /// v0.1.29+106: write the active HAL trip's last-alive checkpoint — a
  /// lastAliveTs plus the current aggregate snapshot — WITHOUT touching
  /// endedAt. The trip stays ACTIVE (endedAt still null), so cloud-sync won't
  /// push it early (the +19 bug), but if the process is killed the row carries
  /// a recent snapshot for orphan recovery to finalize from. Mirrors endTrip's
  /// aggregate parameters, EXCEPT every column uses Value.absent() when its
  /// argument is null, so a flush never NULLS an aggregate the row already has
  /// (endTrip, by contrast, writes Value(null) — fine at close, wrong here).
  Future<void> touchTripAlive(
    int id, {
    required DateTime lastAliveTs,
    double? endSoc,
    double? endOdo,
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
    double? avgMovingSpeedKmh,
    int? movingSeconds,
    int? idleSeconds,
    double? regenEnergyKwh,
  }) {
    Value<T> v<T>(T? x) => x != null ? Value(x) : const Value.absent();
    return (update(trips)..where((t) => t.id.equals(id))).write(
      TripsCompanion(
        lastAliveTs: Value(lastAliveTs),
        // NOTE: endedAt deliberately omitted — the trip must stay ACTIVE.
        endSoc: v(endSoc),
        endOdometer: v(endOdo),
        distanceKm: v(distanceKm),
        energyUsedKwh: v(energyUsedKwh),
        avgConsumptionKwh100km: v(avgConsumptionKwh100km),
        minBatteryTempC: v(minBatteryTempC),
        maxBatteryTempC: v(maxBatteryTempC),
        maxCellSpreadMv: v(maxCellSpreadMv),
        minSoc: v(minSoc),
        maxSoc: v(maxSoc),
        peakSpeedKmh: v(peakSpeedKmh),
        peakPowerKw: v(peakPowerKw),
        peakRegenKw: v(peakRegenKw),
        avgMovingSpeedKmh: v(avgMovingSpeedKmh),
        movingSeconds: v(movingSeconds),
        idleSeconds: v(idleSeconds),
        regenEnergyKwh: v(regenEnergyKwh),
      ),
    );
  }

  /// v0.1.29+106: COARSE energy reconstruction for a pre-watchdog HAL orphan
  /// (lastAliveTs == null, so no aggregate snapshot was taken). Reads the
  /// trip's soc_precise hal_samples oldest→newest; if SOC fell by more than a
  /// small epsilon, returns ΔSOC% × pack capacity / 100 (kWh). Returns null if
  /// there are fewer than two samples or SOC didn't drop (a charge / noise) —
  /// honest: no value rather than a fabricated one. Distance is intentionally
  /// NOT reconstructed (the throttled samples can't give an honest figure).
  Future<double?> reconstructHalEnergyFromSamples(int tripId) async {
    final rows = await (select(halSamples)
          ..where((s) => s.tripId.equals(tripId) & s.name.equals('soc_precise'))
          ..orderBy([(s) => OrderingTerm.asc(s.timestamp)]))
        .get();
    final socs = rows
        .map((r) => r.numericValue)
        .whereType<double>()
        .toList(growable: false);
    if (socs.length < 2) return null;
    final first = socs.first;
    final last = socs.last;
    const epsilon = 0.5; // %SOC — ignore flat/noisy series
    if (first <= last + epsilon) return null;
    const packCapacityKwh = 65.28; // LFP pack nominal (same as _halPackCapacityKwh)
    return (first - last) * packCapacityKwh / 100.0;
  }

  /// Delete a single trip row by id. Used by HAL orphan recovery to drop an
  /// empty pup (an orphan with no distance and no samples — a row that would
  /// otherwise show "Nh, all dashes" in history and contribute nothing to
  /// the cumulative-energy SUM). Scoped to one id; the bulk wipe path is
  /// separate. Returns the number of rows removed (0 or 1).
  Future<int> deleteTrip(int id) {
    return (delete(trips)..where((t) => t.id.equals(id))).go();
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

  /// v0.1.29+94: insert a sample tagged to a charging-log session (per-module
  /// UDS capture during charge). Same shape as insertSample but stamps
  /// chargingSessionId instead of tripId — the row carries raw_hex + decoded
  /// numeric + timestamp, exactly the format recon needs to align the module
  /// block against its CAN trace.
  Future<int> insertChargingSample({
    required String chargingSessionId,
    required String ecuTx,
    required String did,
    required String rawHex,
    double? numeric,
    String? text,
  }) {
    return into(samples).insert(SamplesCompanion(
      chargingSessionId: Value(chargingSessionId),
      timestamp: Value(DateTime.now()),
      ecuTx: Value(ecuTx),
      did: Value(did),
      rawHex: Value(rawHex),
      numericValue: Value(numeric),
      textValue: Value(text),
    ));
  }

  /// v0.1.29+94: count samples in a charging-log session — used by the
  /// pre-drive export verification ("did the 20V+20T+pack_I block actually
  /// get written?") and by the UI to show live row counts during a session.
  Future<int> countChargingSamples(String chargingSessionId) async {
    final cnt = countAll();
    final row = await (selectOnly(samples)
          ..addColumns([cnt])
          ..where(samples.chargingSessionId.equals(chargingSessionId)))
        .getSingle();
    return row.read(cnt) ?? 0;
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

  /// v0.1.83+182: пакетная вставка строк ФОНОВОГО журнала HAL.
  ///
  /// Отдельный метод, а не `insertHalSignal` в цикле, по двум причинам, и
  /// обе обязательные.
  ///
  /// ВРЕМЯ. `insertHalSignal` ставит `DateTime.now()`. Для живого потока
  /// это то же самое, что метка события, а для журнала — нет: вся поездка
  /// легла бы в одно мгновение, и любой расчёт по времени получил бы
  /// вертикальную стену вместо ряда. Здесь метка приходит из строки.
  ///
  /// СКОРОСТЬ. Двадцать тысяч отдельных вставок на этом ГУ — минуты на
  /// открытии приложения. `batch` укладывает их в одну транзакцию.
  ///
  /// `tripId` не параметр и не забыт: у фоновых строк его нет и быть не
  /// может (поездку создаёт машинерия Dart, а она не работала). Null —
  /// это измерение, а не пропуск.
  Future<int> insertBackgroundHalSamples(List<BgHalRow> rows) async {
    if (rows.isEmpty) return 0;
    // Форма companion — РОВНО та же, что у `insertHalSignal` ниже
    // (обычный конструктор, каждое поле через Value), а не `.insert`.
    // Причина не в стиле: `database.g.dart` генерируется на CI и в
    // песочнице его нет, проверить подпись `.insert` здесь нечем. Эта
    // форма в этом файле уже работает с +92, и ставить на неудостоверенную
    // подпись там, где рядом лежит удостоверенная, значит платить сборкой
    // на CI за экономию строки.
    await batch((b) {
      b.insertAll(
        halSamples,
        rows.map((r) => HalSamplesCompanion(
              tripId: const Value<int?>(null),
              timestamp: Value(r.at),
              source: const Value('hal'),
              targetKey: Value(r.targetKey),
              subtype: Value(r.subtype),
              name: Value(r.name),
              numericValue: Value(r.value),
            )),
      );
    });
    return rows.length;
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

  /// v0.1.86+185 — ФОНОВЫЙ СТРОИТЕЛЬ ПОЕЗДОК, три запроса.
  ///
  /// Строки журнала HAL, ещё не приписанные ни к одной поездке. Только
  /// `source='hal'`: сырые кадры (`bigdata`) имени не несут и решению о
  /// движении помочь не могут, а объём дают вчетверо.
  /// v0.1.86+185: ПОТОЛОК ОБЯЗАТЕЛЕН. В первой редакции выборка была без предела и
  /// материализовала в память всё, что накопилось с прошлого запуска. На
  /// поле это девять тысяч строк и незаметно; но интервал «с прошлого
  /// открытия приложения» ничем не ограничен, а ГУ просыпается само, и
  /// месяц без открытия даёт сотни тысяч объектов на устройстве, где
  /// столько памяти нет. Остаток разбирается следующим проходом — он и
  /// так идёт при каждом открытии.
  Future<List<HalSample>> getUnassignedHalSamples({
    DateTime? after,
    int limit = 50000,
  }) {
    final q = select(halSamples)
      ..where((s) => s.tripId.isNull() & s.source.equals('hal'))
      ..orderBy([(s) => OrderingTerm.asc(s.timestamp)])
      ..limit(limit);
    if (after != null) {
      q.where((s) => s.timestamp.isBiggerThanValue(after));
    }
    return q.get();
  }

  /// Приписать строки окна к поездке. ШТАМП ОБЯЗАТЕЛЕН И ДЕЛАЕТ ДВА ДЕЛА
  /// СРАЗУ: он же защита от повторной сборки (приписанная строка больше не
  /// попадёт в [getUnassignedHalSamples]), он же вход для генератора
  /// `trip_series` — тот уже умеет падать на `hal_samples` по `trip_id`,
  /// поэтому графики у фоновой поездки появляются без единой новой строки
  /// в облачном сервисе.
  ///
  /// Окно берётся по времени, а не по списку идентификаторов: сырые кадры
  /// внутри поездки тоже должны получить штамп, иначе они останутся
  /// висеть без владельца и переживут вайп поездки бесхозными.
  Future<int> assignHalSamplesToTrip({
    required int tripId,
    required DateTime from,
    required DateTime to,
  }) {
    return (update(halSamples)
          ..where((s) =>
              s.tripId.isNull() &
              s.timestamp.isBiggerOrEqualValue(from) &
              s.timestamp.isSmallerOrEqualValue(to)))
        .write(HalSamplesCompanion(tripId: Value(tripId)));
  }

  /// v0.1.86+185 — ВСТАВКА ПОЕЗДКИ И ШТАМП ЕЁ СТРОК, ОДНОЙ ТРАНЗАКЦИЕЙ.
  ///
  /// В первой редакции этого патча это были два отдельных `await`, и между ними зияла дыра.
  /// Умри процесс в этот миг или брось второй вызов исключение — поездка
  /// записана, строки не приписаны, и при следующем открытии ТА ЖЕ
  /// поездка строится заново, с новым `client_uuid`, и уезжает в облако
  /// дублем. Клиентом такое уже не чинится.
  ///
  /// Окно было в миллисекунды, и соблазн назвать его невероятным велик.
  /// Но выключение зажигания — это штатный способ завершения процесса на
  /// этом ГУ, а не авария; и куда вероятнее смерти процесса второй путь в
  /// ту же дыру — исключение на штампе, которое внешний `try/catch`
  /// проглотит и вернёт результат, будто всё хорошо.
  ///
  /// Оба действия обязаны быть атомарны, и метод здесь именно один, а не
  /// два рядом: разделить их снова означало бы вернуть дефект.
  Future<int> insertTripWithStampedSamples({
    required DateTime windowFrom,
    required DateTime windowTo,
    required DateTime startedAt,
    required DateTime endedAt,
    required String source,
    double? startSoc,
    double? endSoc,
    double? startOdo,
    double? endOdo,
    int sampleCount = 0,
    double? distanceKm,
    double? energyUsedKwh,
    double? avgConsumptionKwh100km,
    double? minBatteryTempC,
    double? maxBatteryTempC,
    double? maxCellSpreadMv,
    double? minSoc,
    double? maxSoc,
    double? peakSpeedKmh,
    double? avgMovingSpeedKmh,
    int? movingSeconds,
    int? idleSeconds,
    double? energyFromSocKwh,
    String? extraJson,
  }) {
    return transaction(() async {
      final tripId = await insertCompletedTrip(
        startedAt: startedAt,
        endedAt: endedAt,
        source: source,
        startSoc: startSoc,
        endSoc: endSoc,
        startOdo: startOdo,
        endOdo: endOdo,
        sampleCount: sampleCount,
        distanceKm: distanceKm,
        energyUsedKwh: energyUsedKwh,
        avgConsumptionKwh100km: avgConsumptionKwh100km,
        minBatteryTempC: minBatteryTempC,
        maxBatteryTempC: maxBatteryTempC,
        maxCellSpreadMv: maxCellSpreadMv,
        minSoc: minSoc,
        maxSoc: maxSoc,
        peakSpeedKmh: peakSpeedKmh,
        avgMovingSpeedKmh: avgMovingSpeedKmh,
        movingSeconds: movingSeconds,
        idleSeconds: idleSeconds,
        energyFromSocKwh: energyFromSocKwh,
      );
      await assignHalSamplesToTrip(
          tripId: tripId, from: windowFrom, to: windowTo);
      if (extraJson != null) await mergeTripExtra(tripId, extraJson);
      return tripId;
    });
  }

  /// Вставить готовую поездку одной строкой. НЕ `startTrip` + `endTrip`:
  /// те ставят `DateTime.now()` в начало, а у фоновой поездки время своё,
  /// из строк журнала, и оно на час старше момента сборки.
  ///
  /// ЗВАТЬ НАПРЯМУЮ НЕЛЬЗЯ — только через
  /// [insertTripWithStampedSamples], которая держит транзакцию. Поездка
  /// без штампа своих строк есть заготовка дубля; см. там же.
  Future<int> insertCompletedTrip({
    required DateTime startedAt,
    required DateTime endedAt,
    required String source,
    double? startSoc,
    double? endSoc,
    double? startOdo,
    double? endOdo,
    int sampleCount = 0,
    double? distanceKm,
    double? energyUsedKwh,
    double? avgConsumptionKwh100km,
    double? minBatteryTempC,
    double? maxBatteryTempC,
    double? maxCellSpreadMv,
    double? minSoc,
    double? maxSoc,
    double? peakSpeedKmh,
    double? avgMovingSpeedKmh,
    int? movingSeconds,
    int? idleSeconds,
    double? energyFromSocKwh,
  }) {
    return into(trips).insert(TripsCompanion(
      startedAt: Value(startedAt),
      endedAt: Value(endedAt),
      source: Value(source),
      startSoc: Value(startSoc),
      endSoc: Value(endSoc),
      startOdometer: Value(startOdo),
      endOdometer: Value(endOdo),
      sampleCount: Value(sampleCount),
      distanceKm: Value(distanceKm),
      energyUsedKwh: Value(energyUsedKwh),
      avgConsumptionKwh100km: Value(avgConsumptionKwh100km),
      minBatteryTempC: Value(minBatteryTempC),
      maxBatteryTempC: Value(maxBatteryTempC),
      maxCellSpreadMv: Value(maxCellSpreadMv),
      minSoc: Value(minSoc),
      maxSoc: Value(maxSoc),
      peakSpeedKmh: Value(peakSpeedKmh),
      avgMovingSpeedKmh: Value(avgMovingSpeedKmh),
      movingSeconds: Value(movingSeconds),
      idleSeconds: Value(idleSeconds),
      energyFromSocKwh: Value(energyFromSocKwh),
      // v0.1.87+186: облачная личность ДЕТЕРМИНИРОВАННАЯ — выводится из
      // источника и границ окна. Пересборка того же выезда после
      // восстановления из архива даёт тот же uuid, и сервер схлопывает
      // повтор сам вместо того, чтобы завести второй экземпляр поездки.
      clientUuid: Value(uuidV7Deterministic(
        time: startedAt,
        seed: '$source|${startedAt.millisecondsSinceEpoch}'
            '|${endedAt.millisecondsSinceEpoch}',
      )),
    ));
  }

  Future<int> countAllHalSamples() async {
    final cnt = countAll();
    final row = await (selectOnly(halSamples)..addColumns([cnt])).getSingle();
    return row.read(cnt) ?? 0;
  }

  // ────────────────────────── Snapshots ──────────────────────────

  // v0.1.29+117 (C1): inject a fresh UUIDv7 unless the caller already set one
  // (the cloud-restore path does — it adopts the server uuid when present).
  Future<int> insertSnapshot(SnapshotsCompanion data) =>
      into(snapshots).insert(data.clientUuid.present
          ? data
          : data.copyWith(clientUuid: Value(uuidV7())));

  /// v0.1.49+148: direct MAX(id). The restore hook previously proxied
  /// "max snapshot id" via getRecentSnapshots(limit: 1) — which orders by
  /// captured_at DESC, not id. A live HAL snapshot written mid-restore
  /// carries the newest captured_at with a MID-RANGE local id, so the
  /// proxy under-reported the max and left the tail of restored rows
  /// above the push cursor / uuid-map watermark (19.07 field: watermark
  /// 1105 of 1865 → 760 mapping conflicts on reattach).
  Future<int> maxSnapshotId() async {
    final row = await customSelect(
      'SELECT COALESCE(MAX(id), 0) AS m FROM snapshots',
      readsFrom: {snapshots},
    ).getSingle();
    return row.read<int>('m');
  }

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

  /// v0.1.42+141: fieldwise last-known for the phone stale dashboard.
  /// Snapshot rows are heterogeneous by writer (a HAL row may carry
  /// soc+soh without odometer, a charging row its own subset), so the
  /// single newest row can hold NULL in a field an older row has —
  /// the +139 cards showed '—' for data that exists. Returns, per
  /// showcased field, the newest row where THAT field is non-null:
  /// (soc, odometer, soh, batteryTemp). Each card renders the value with
  /// its own captured_at. Four LIMIT-1 index-friendly selects — same cost
  /// class as getLatestSnapshot, ran once per 60s stale tick.
  /// v0.1.43+142 §3: fourth element — battery temperature (both writers
  /// fill batteryTempC since +138), for the fourth stale card (2×2 grid).
  Future<(Snapshot?, Snapshot?, Snapshot?, Snapshot?)>
      getLatestFieldwiseSnapshots() async {
    Future<Snapshot?> latestWhere(
        Expression<bool> Function($SnapshotsTable) pred) {
      return (select(snapshots)
            ..where(pred)
            ..orderBy([
              (s) => OrderingTerm(
                  expression: s.capturedAt, mode: OrderingMode.desc)
            ])
            ..limit(1))
          .getSingleOrNull();
    }

    final soc = await latestWhere((s) => s.soc.isNotNull());
    final odo = await latestWhere((s) => s.odometer.isNotNull());
    final soh = await latestWhere((s) => s.soh.isNotNull());
    final temp = await latestWhere((s) => s.batteryTempC.isNotNull());
    return (soc, odo, soh, temp);
  }

  // ── v0.1.41+140: trip_series helpers ────────────────────────────────

  /// Generator scan: trips after [afterId] in id order, ANY state — the
  /// caller stops at the first open trip so the watermark never jumps
  /// over it (single-ACTIVE-trip invariant makes that a clean prefix).
  Future<List<Trip>> getTripsAfter(int afterId, int limit) {
    return (select(trips)
          ..where((t) => t.id.isBiggerThanValue(afterId))
          ..orderBy([(t) => OrderingTerm(expression: t.id)])
          ..limit(limit))
        .get();
  }

  Future<List<TripSeriesRow>> getTripSeriesByTripUuid(String tripUuid) {
    return (select(tripSeries)..where((r) => r.tripClientUuid.equals(tripUuid)))
        .get();
  }

  /// Chart 4th ladder step: one series of one trip by the LOCAL id.
  Future<TripSeriesRow?> getTripSeriesForChart(int tripId, String series) {
    return (select(tripSeries)
          ..where((r) => r.tripId.equals(tripId) & r.series.equals(series))
          ..limit(1))
        .getSingleOrNull();
  }

  /// Upsert by the identity key (tripClientUuid, series) — mirrors the
  /// server's UNIQUE. Keeps the original clientUuid on update (immutable,
  /// same rule as the server side). Returns the row id.
  Future<int> upsertTripSeries(TripSeriesCompanion data) async {
    final existing = await (select(tripSeries)
          ..where((r) =>
              r.tripClientUuid.equals(data.tripClientUuid.value) &
              r.series.equals(data.series.value))
          ..limit(1))
        .getSingleOrNull();
    if (existing == null) {
      return into(tripSeries).insert(data);
    }
    await (update(tripSeries)..where((r) => r.id.equals(existing.id)))
        .write(TripSeriesCompanion(
      tripId: data.tripId,
      algo: data.algo,
      pointCount: data.pointCount,
      tsMin: data.tsMin,
      tsMax: data.tsMax,
      pointsJson: data.pointsJson,
      syncedAt: data.syncedAt,
      updatedAt: data.updatedAt,
    ));
    return existing.id;
  }

  Future<List<TripSeriesRow>> getUnsyncedTripSeries() {
    return (select(tripSeries)..where((r) => r.syncedAt.isNull())).get();
  }

  Future<void> markTripSeriesSynced(List<int> ids, DateTime at) async {
    if (ids.isEmpty) return;
    await (update(tripSeries)..where((r) => r.id.isIn(ids)))
        .write(TripSeriesCompanion(syncedAt: Value(at)));
  }

  /// Lazy orphan re-link: pulled series whose trip arrived in the same
  /// (or a later) pass. Cheap: orphans are rare and shrink to zero.
  Future<int> relinkOrphanTripSeries() async {
    final orphans =
        await (select(tripSeries)..where((r) => r.tripId.isNull())).get();
    var fixed = 0;
    for (final o in orphans) {
      final trip = await (select(trips)
            ..where((t) => t.clientUuid.equals(o.tripClientUuid))
            ..limit(1))
          .getSingleOrNull();
      if (trip == null) continue;
      await (update(tripSeries)..where((r) => r.id.equals(o.id)))
          .write(TripSeriesCompanion(tripId: Value(trip.id)));
      fixed++;
    }
    return fixed;
  }

  Future<int> countAllSnapshots() async {
    final cnt = countAll();
    final row = await (selectOnly(snapshots)..addColumns([cnt])).getSingle();
    return row.read(cnt) ?? 0;
  }

  // ────────────────────────── Sweeps (v0.1.11 schema, v0.1.12 fill) ──

  // v0.1.29+117 (C1): same uuid injection as insertSnapshot.
  Future<int> insertSweepRun(SweepRunsCompanion data) =>
      into(sweepRuns).insert(data.clientUuid.present
          ? data
          : data.copyWith(clientUuid: Value(uuidV7())));

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

  // v0.1.29+117 (C1): same uuid injection as insertSnapshot.
  Future<int> insertLiveLogSession(LiveLogSessionsCompanion data) =>
      into(liveLogSessions).insert(data.clientUuid.present
          ? data
          : data.copyWith(clientUuid: Value(uuidV7())));

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

  // v0.1.29+117 (C1): same uuid injection as insertSnapshot.
  Future<int> insertCanMonitorSession(CanMonitorSessionsCompanion data) =>
      into(canMonitorSessions).insert(data.clientUuid.present
          ? data
          : data.copyWith(clientUuid: Value(uuidV7())));

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

  // ─────────────────── SOH (coulomb-counted) ──────────────────────
  // v0.1.29+104. Single-row table (id = 1): each qualifying charge session
  // overwrites the previous result, so the dashboard always reads the most
  // recent independent estimate.

  /// Write an independent SOH estimate. [rowId] selects the estimator slot:
  /// 1 = UDS (default, unchanged for the existing ConnectionService caller),
  /// 2 = HAL. [source] tags the row ('uds' | 'hal'); defaults to 'uds' so the
  /// pre-+105 ConnectionService call keeps its exact prior behaviour.
  Future<void> upsertSohEstimate({
    required double sohAhPct,
    required DateTime computedAt,
    required double deltaSocCovered,
    int rowId = 1,
    String source = 'uds',
  }) async {
    await into(sohEstimates).insertOnConflictUpdate(
      SohEstimatesCompanion(
        id: Value(rowId),
        sohAhPct: Value(sohAhPct),
        computedAt: Value(computedAt),
        deltaSocCovered: Value(deltaSocCovered),
        source: Value(source),
      ),
    );
  }

  /// Independent SOH estimate for the given estimator slot, or null if none
  /// computed yet. [rowId] defaults to 1 (UDS) so the existing call is
  /// unchanged; HAL reads rowId 2.
  Future<SohEstimate?> getLatestSohEstimate({int rowId = 1}) {
    return (select(sohEstimates)..where((r) => r.id.equals(rowId)))
        .getSingleOrNull();
  }

  /// v0.1.31+130 (Trends v2): append one coulomb-counted SOH estimate to
  /// the append-only history. Called right next to [upsertSohEstimate] by
  /// both estimators (UDS in ConnectionService, HAL in
  /// HalTelemetryService); the upsert keeps feeding the dashboard widget,
  /// this feeds the Trends time series.
  ///
  /// Dedup guard: the HAL path has crash recovery
  /// (`_recoverPendingSohSession`) that recomputes and re-writes the SAME
  /// session's estimate at the next init with a NEW DateTime.now(). For
  /// the single-row upsert that re-write is idempotent; for an append-only
  /// table it would duplicate the point. So: if the latest row with the
  /// same [source] matches within 0.05 on both sohAhPct and
  /// deltaSocCovered AND is younger than 24 h — skip the insert.
  Future<void> appendSohHistory({
    required double sohAhPct,
    required DateTime computedAt,
    required double deltaSocCovered,
    required String source,
  }) async {
    final last = await (select(sohHistory)
          ..where((r) => r.source.equals(source))
          ..orderBy([
            (r) => OrderingTerm(
                expression: r.computedAt, mode: OrderingMode.desc)
          ])
          ..limit(1))
        .getSingleOrNull();
    if (last != null &&
        (sohAhPct - last.sohAhPct).abs() < 0.05 &&
        (deltaSocCovered - last.deltaSocCovered).abs() < 0.05 &&
        computedAt.difference(last.computedAt) < const Duration(hours: 24)) {
      debugPrint('SohHistory: $source re-write of the same estimate '
          'skipped (recovery dedup guard)');
      return;
    }
    await into(sohHistory).insert(
      SohHistoryCompanion.insert(
        sohAhPct: sohAhPct,
        computedAt: computedAt,
        deltaSocCovered: deltaSocCovered,
        source: source,
      ),
    );
  }

  /// v0.1.31+130: SOH history rows inside [from, to], ascending by
  /// computedAt — same contract as [getSnapshotsInRange], consumed by the
  /// Trends SOH combo card (Ah-method points).
  Future<List<SohHistoryData>> getSohHistoryInRange(
      DateTime from, DateTime to) {
    return (select(sohHistory)
          ..where((r) =>
              r.computedAt.isBiggerOrEqualValue(from) &
              r.computedAt.isSmallerOrEqualValue(to))
          ..orderBy([(r) => OrderingTerm(expression: r.computedAt)]))
        .get();
  }

  /// v0.1.29+121 (C5): exact-identity lookups for the /v2/sync/pull restore
  /// apply — D8 says "apply idempotently by client_uuid", and these are that
  /// predicate. Backed by the partial unique indexes from schema 14.
  Future<Trip?> getTripByClientUuid(String uuid) {
    return (select(trips)
          ..where((t) => t.clientUuid.equals(uuid))
          ..limit(1))
        .getSingleOrNull();
  }

  Future<Snapshot?> getSnapshotByClientUuid(String uuid) {
    return (select(snapshots)
          ..where((s) => s.clientUuid.equals(uuid))
          ..limit(1))
        .getSingleOrNull();
  }

  // ── v0.1.59+158: atlas helpers (снимки + reveal-очередь) ──────────

  /// The ONE local write path for atlas snapshots — called only by the
  /// SpeedProfileService freeze funnel (regress AX7). Pull/restore go
  /// through [applyPulledAtlasSnapshot] instead.
  Future<int> insertAtlasSnapshot(AtlasSnapshotsCompanion data) =>
      into(atlasSnapshots).insert(data);

  Future<AtlasSnapshotRow?> getAtlasSnapshotByClientUuid(String uuid) {
    return (select(atlasSnapshots)
          ..where((r) => r.clientUuid.equals(uuid))
          ..limit(1))
        .getSingleOrNull();
  }

  Future<List<AtlasSnapshotRow>> getUnsyncedAtlasSnapshots() {
    return (select(atlasSnapshots)..where((r) => r.syncedAt.isNull())).get();
  }

  Future<void> markAtlasSnapshotsSynced(List<int> ids, DateTime at) async {
    if (ids.isEmpty) return;
    await (update(atlasSnapshots)..where((r) => r.id.isIn(ids)))
        .write(AtlasSnapshotsCompanion(syncedAt: Value(at)));
  }

  Future<int> countAtlasSnapshots() async {
    final cnt = countAll();
    final row =
        await (selectOnly(atlasSnapshots)..addColumns([cnt])).getSingle();
    return row.read(cnt) ?? 0;
  }

  /// Pull/restore apply — idempotent by clientUuid. The row is immutable:
  /// an existing uuid is NEVER updated (server-side canon is identical).
  /// Arriving rows are server-side by definition → syncedAt set, never
  /// re-pushed (the trip_series echo rule).
  Future<bool> applyPulledAtlasSnapshot(AtlasSnapshotsCompanion data) async {
    final existing =
        await getAtlasSnapshotByClientUuid(data.clientUuid.value);
    if (existing != null) return false;
    await into(atlasSnapshots).insert(data);
    return true;
  }

  Future<AtlasRevealRow?> getAtlasRevealByClientUuid(String uuid) {
    return (select(atlasReveals)
          ..where((r) => r.clientUuid.equals(uuid))
          ..limit(1))
        .getSingleOrNull();
  }

  Future<List<AtlasRevealRow>> getUnsyncedAtlasReveals() {
    return (select(atlasReveals)..where((r) => r.syncedAt.isNull())).get();
  }

  Future<void> markAtlasRevealsSynced(List<int> ids, DateTime at) async {
    if (ids.isEmpty) return;
    await (update(atlasReveals)..where((r) => r.id.isIn(ids)))
        .write(AtlasRevealsCompanion(syncedAt: Value(at)));
  }

  Future<int> countAtlasReveals() async {
    final cnt = countAll();
    final row =
        await (selectOnly(atlasReveals)..addColumns([cnt])).getSingle();
    return row.read(cnt) ?? 0;
  }

  /// Badge source (patch 2 flips generation on; always 0 in +158).
  Future<int> countUnrevealedAtlasReveals() async {
    final cnt = countAll();
    final row = await (selectOnly(atlasReveals)
          ..where(atlasReveals.revealedAt.isNull())
          ..addColumns([cnt]))
        .getSingle();
    return row.read(cnt) ?? 0;
  }

  /// Pull/restore apply for reveals — write-once merge, the client-side
  /// mirror of the server's COALESCE upsert:
  ///   • absent locally → insert as-is (syncedAt = now, echo rule);
  ///   • present, local revealedAt == null, incoming != null → write
  ///     revealedAt/revealedBy ONLY (payload untouched — the
  ///     null-preserve-upsert trap from the trips epic);
  ///   • anything else → no-op (first write already won).
  Future<bool> applyPulledAtlasReveal(AtlasRevealsCompanion data) async {
    final existing = await getAtlasRevealByClientUuid(data.clientUuid.value);
    if (existing == null) {
      await into(atlasReveals).insert(data);
      return true;
    }
    final incomingRevealedAt =
        data.revealedAt.present ? data.revealedAt.value : null;
    if (existing.revealedAt == null && incomingRevealedAt != null) {
      await (update(atlasReveals)..where((r) => r.id.equals(existing.id)))
          .write(AtlasRevealsCompanion(
        revealedAt: Value(incomingRevealedAt),
        revealedBy: data.revealedBy,
        syncedAt: data.syncedAt,
        updatedAt: data.updatedAt,
      ));
      return true;
    }
    return false;
  }

  // ── v0.1.61+160: reveal generation + parking summary card ─────────

  /// The ONE local producer of reveal rows (regress AY1/AY2): called
  /// ONLY by the generator in SpeedProfileService, exactly once, on a
  /// maturity crossing. Pull/restore keep going through
  /// [applyPulledAtlasReveal] — the write-once merge path never inserts
  /// through here. Rows are born with syncedAt = null (absent) so the
  /// next push cycle picks them up (patch-1 plumbing, no sync changes).
  Future<int> insertAtlasReveal(AtlasRevealsCompanion data) =>
      into(atlasReveals).insert(data);

  /// Card body: everything still unrevealed, newest first (the screen
  /// re-orders by type; within a type this order is final).
  Future<List<AtlasRevealRow>> getUnrevealedAtlasReveals() {
    return (select(atlasReveals)
          ..where((r) => r.revealedAt.isNull())
          ..orderBy([
            (r) => OrderingTerm(
                expression: r.createdAt, mode: OrderingMode.desc),
            (r) => OrderingTerm(expression: r.id, mode: OrderingMode.desc),
          ]))
        .get();
  }

  /// «Ок» (§2.1): reveal EVERYTHING pending in one write. revealedAt /
  /// revealedBy are the write-once fields; syncedAt is nulled so the
  /// row re-pushes and the server merges first-write-wins (COALESCE).
  /// payloadJson is deliberately untouched (the null-preserve trap).
  Future<int> revealAllUnrevealedAtlasReveals(DateTime at,
      {required String revealedBy}) {
    return (update(atlasReveals)..where((r) => r.revealedAt.isNull()))
        .write(AtlasRevealsCompanion(
      revealedAt: Value(at),
      revealedBy: Value(revealedBy),
      syncedAt: const Value(null),
      updatedAt: Value(at),
    ));
  }

  /// band_matured existence check: does ANY snapshot of this band exist
  /// (any window, «t° неизвестна» included)?
  Future<bool> hasAtlasSnapshotForBand(int band) async {
    final row = await (select(atlasSnapshots)
          ..where((r) => r.bandKmh.equals(band))
          ..limit(1))
        .getSingleOrNull();
    return row != null;
  }

  /// Snapshots of one atlas cell (band × temp window; window == null is
  /// the «t° неизвестна» reserve) — feeds the star_up session dedup and
  /// the cell_new existence check.
  Future<List<AtlasSnapshotRow>> getAtlasSnapshotsForCell(
      int band, int? window) {
    final q = select(atlasSnapshots)
      ..where((r) => r.bandKmh.equals(band));
    if (window == null) {
      q.where((r) => r.tempWindowC.isNull());
    } else {
      q.where((r) => r.tempWindowC.equals(window));
    }
    return q.get();
  }

  /// Reveal existence checks parse the payload in Dart — the reveal
  /// table is small by construction (bounded by bands × cells × star
  /// levels over the atlas lifetime), a JSON column query buys nothing.
  Future<List<AtlasRevealRow>> getAtlasRevealsByType(String type) {
    return (select(atlasReveals)..where((r) => r.type.equals(type))).get();
  }

  // ── v0.1.62+161: the atlas READ path (grid / detail / export) ──────
  //
  /// Every snapshot the atlas surfaces are allowed to see, ordered by
  /// freeze time. [maxBand] is the collection ceiling (140 km/h, §1 of
  /// the patch spec): the reward engine still RECORDS faster bands until
  /// the cutoff lands in the freeze funnel (+162), so the ceiling is
  /// enforced right here — ONE filter, on the ONE query that feeds the
  /// matrix, the header counters, the year row and the export. Nothing
  /// downstream re-filters (and `AtlasGridData` keeps a cheap second
  /// lock only as belt-and-braces).
  ///
  /// The grid reads this table DIRECTLY and never the prefs ledger:
  /// that is precisely why a reinstall needs no rehydration code — the
  /// cloud refills atlas_snapshots and the atlas comes back with it.
  Future<List<AtlasSnapshotRow>> getAtlasSnapshotsForGrid(
      {required int maxBand}) {
    return (select(atlasSnapshots)
          ..where((r) => r.bandKmh.isSmallerOrEqualValue(maxBand))
          ..orderBy([(r) => OrderingTerm(expression: r.frozenAt)]))
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
