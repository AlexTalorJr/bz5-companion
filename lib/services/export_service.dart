import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:archive/archive_io.dart';
import 'package:flutter/foundation.dart';
import 'package:intl/intl.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../data/database.dart';

/// v0.1.11: bundles all app data into one timestamped zip and hands it off
/// to the system share sheet for the user to save (e.g. to a USB flash via
/// the head unit's "Files" app, or to Google Drive / Telegram / email).
///
/// Format inside the zip:
///   metadata.json     — schema version, export timestamp, table counts
///   trips.csv         — one row per trip with all aggregates
///   snapshots.csv     — long-term snapshots for trends
///   samples.sqlite    — raw drift DB copy (compact, opens in DB Browser)
///   sweep_runs.csv    — sweep run headers
///   sweep_results.csv — sweep probe results
///
/// Mixed format chosen so:
///  - trips / snapshots can be opened directly in Excel / Numbers
///  - samples (millions of rows) stay compact as binary SQLite
///  - everything is in one zip → one tap to share
class ExportService {
  final AppDatabase db;
  ExportService(this.db);

  /// Build the zip and trigger share. Optionally [includeSamples] can be
  /// disabled when the user just wants trips/snapshots (the samples DB
  /// dump is the heaviest part).
  Future<ExportResult> exportAll({
    bool includeSamples = true,
    bool includeSweeps = true,
    bool includeSnapshots = true,
    bool includeTrips = true,
    bool Function(String stage)? onProgress,
  }) async {
    final tmpDir = await getTemporaryDirectory();
    final ts = DateFormat('yyyyMMdd-HHmmss').format(DateTime.now());
    final zipPath = p.join(tmpDir.path, 'bz5_export_$ts.zip');

    // Counts collected for metadata + UI feedback
    final counts = <String, int>{};

    final archive = Archive();

    if (includeTrips) {
      onProgress?.call('trips');
      final trips = await db.getAllTrips();
      counts['trips'] = trips.length;
      final csv = _tripsToCsv(trips);
      final bytes = utf8.encode(csv);
      archive.addFile(ArchiveFile('trips.csv', bytes.length, bytes));
    }

    if (includeSnapshots) {
      onProgress?.call('snapshots');
      final snapshots = await db.getAllSnapshots();
      counts['snapshots'] = snapshots.length;
      final csv = _snapshotsToCsv(snapshots);
      final bytes = utf8.encode(csv);
      archive.addFile(ArchiveFile('snapshots.csv', bytes.length, bytes));
    }

    if (includeSweeps) {
      onProgress?.call('sweeps');
      final runs = await db.getAllSweepRuns();
      counts['sweep_runs'] = runs.length;
      archive.addFile(ArchiveFile(
        'sweep_runs.csv',
        0,
        utf8.encode(_sweepRunsToCsv(runs)),
      ));
      // Sweep results — concatenated, one row per (run_id, did)
      final allResults = <SweepResult>[];
      for (final r in runs) {
        allResults.addAll(await db.getSweepResults(r.id));
      }
      counts['sweep_results'] = allResults.length;
      archive.addFile(ArchiveFile(
        'sweep_results.csv',
        0,
        utf8.encode(_sweepResultsToCsv(allResults)),
      ));
    }

    if (includeSamples) {
      onProgress?.call('samples');
      counts['samples'] = await db.countAllSamples();
      // Copy raw SQLite file directly — much smaller than CSV-encoding millions
      // of rows. The file is at the app's drift_flutter standard location.
      final dbFile = await _findDatabaseFile();
      if (dbFile != null && await dbFile.exists()) {
        final bytes = await dbFile.readAsBytes();
        archive.addFile(ArchiveFile('samples.sqlite', bytes.length, bytes));
      } else {
        // Couldn't find db file — fall back to CSV of samples (slow & huge but
        // at least the user gets something).
        debugPrint('ExportService: db file not found, falling back to CSV');
        final samples = await db.getAllSamples();
        archive.addFile(ArchiveFile(
          'samples.csv',
          0,
          utf8.encode(_samplesToCsv(samples)),
        ));
      }
    }

    // Metadata last so we know all counts
    onProgress?.call('metadata');
    final metadata = {
      'app': 'BZ5 Companion',
      'schema_version': db.schemaVersion,
      'exported_at': DateTime.now().toIso8601String(),
      'counts': counts,
      'includes': {
        'trips': includeTrips,
        'snapshots': includeSnapshots,
        'sweeps': includeSweeps,
        'samples': includeSamples,
      },
    };
    final metaBytes = utf8.encode(const JsonEncoder.withIndent('  ').convert(metadata));
    archive.addFile(ArchiveFile('metadata.json', metaBytes.length, metaBytes));

    // Write the zip
    onProgress?.call('compressing');
    final encoder = ZipEncoder();
    final zipBytes = encoder.encode(archive);
    if (zipBytes == null) {
      throw Exception('zip encoding returned null');
    }
    final zipFile = File(zipPath);
    await zipFile.writeAsBytes(zipBytes, flush: true);

    onProgress?.call('sharing');
    // ignore: deprecated_member_use
    final shareResult = await Share.shareXFiles(
      [XFile(zipPath, mimeType: 'application/zip', name: 'bz5_export_$ts.zip')],
      subject: 'BZ5 Companion export — $ts',
      text: 'Battery & trip data export from BZ5 Companion.',
    );

    return ExportResult(
      zipPath: zipPath,
      sizeBytes: zipBytes.length,
      counts: counts,
      sharedSuccessfully: shareResult.status == ShareResultStatus.success,
    );
  }

  Future<File?> _findDatabaseFile() async {
    // drift_flutter uses getApplicationSupportDirectory by default; the file
    // name is 'bz5_data.sqlite' (matching the name we passed to driftDatabase).
    try {
      final dir = await getApplicationSupportDirectory();
      final f = File(p.join(dir.path, 'bz5_data.sqlite'));
      if (await f.exists()) return f;
    } catch (_) {}
    // Fallback paths to try in case Android layout differs
    try {
      final docs = await getApplicationDocumentsDirectory();
      final f = File(p.join(docs.path, 'bz5_data.sqlite'));
      if (await f.exists()) return f;
    } catch (_) {}
    return null;
  }

  // ───────────────────────────── CSV builders ──────────────────────────────

  String _tripsToCsv(List<Trip> trips) {
    final buf = StringBuffer();
    buf.writeln(
      'id,started_at,ended_at,duration_seconds,'
      'start_soc,end_soc,start_odometer_km,end_odometer_km,'
      'distance_km,energy_used_kwh,avg_consumption_kwh_100km,'
      'min_battery_temp_c,max_battery_temp_c,max_cell_spread_mv,'
      'min_soc,max_soc,peak_speed_kmh,peak_power_kw,peak_regen_kw,'
      'regen_energy_kwh,sample_count,notes',
    );
    for (final t in trips) {
      final duration = t.endedAt?.difference(t.startedAt).inSeconds;
      buf.writeln([
        t.id,
        t.startedAt.toIso8601String(),
        t.endedAt?.toIso8601String() ?? '',
        duration ?? '',
        t.startSoc ?? '',
        t.endSoc ?? '',
        t.startOdometer ?? '',
        t.endOdometer ?? '',
        t.distanceKm ?? '',
        t.energyUsedKwh ?? '',
        t.avgConsumptionKwh100km ?? '',
        t.minBatteryTempC ?? '',
        t.maxBatteryTempC ?? '',
        t.maxCellSpreadMv ?? '',
        t.minSoc ?? '',
        t.maxSoc ?? '',
        t.peakSpeedKmh ?? '',
        t.peakPowerKw ?? '',
        t.peakRegenKw ?? '',
        t.regenEnergyKwh ?? '',
        t.sampleCount,
        _csvEscape(t.notes ?? ''),
      ].join(','));
    }
    return buf.toString();
  }

  String _snapshotsToCsv(List<Snapshot> snapshots) {
    final buf = StringBuffer();
    buf.writeln(
      'id,captured_at,trip_id,soc,soh,battery_temp_c,'
      'cell_voltage_min_mv,cell_voltage_max_mv,cell_spread_mv,odometer_km,'
      'pack_voltage_v,hv_bus_v,gear,pawl_engaged,is_charging,'
      'charging_power_kw,cycle_count',
    );
    for (final s in snapshots) {
      buf.writeln([
        s.id,
        s.capturedAt.toIso8601String(),
        s.tripId ?? '',
        s.soc ?? '',
        s.soh ?? '',
        s.batteryTempC ?? '',
        s.cellVoltageMin ?? '',
        s.cellVoltageMax ?? '',
        s.cellSpread ?? '',
        s.odometer ?? '',
        s.packVoltageV ?? '',
        s.hvBusV ?? '',
        s.gear ?? '',
        s.pawlEngaged ?? '',
        s.isCharging ?? '',
        s.chargingPowerKw ?? '',
        s.cycleCount ?? '',
      ].join(','));
    }
    return buf.toString();
  }

  String _samplesToCsv(List<Sample> samples) {
    final buf = StringBuffer();
    buf.writeln('id,timestamp,trip_id,ecu_tx,did,raw_hex,numeric,text');
    for (final s in samples) {
      buf.writeln([
        s.id,
        s.timestamp.toIso8601String(),
        s.tripId ?? '',
        s.ecuTx,
        s.did,
        s.rawHex,
        s.numericValue ?? '',
        _csvEscape(s.textValue ?? ''),
      ].join(','));
    }
    return buf.toString();
  }

  String _sweepRunsToCsv(List<SweepRun> runs) {
    final buf = StringBuffer();
    buf.writeln(
      'id,started_at,ended_at,duration_seconds,tx_ecu,rx_ecu,start_did,end_did,'
      'period_ms,total_probes,valid_responses,car_state,notes',
    );
    for (final r in runs) {
      buf.writeln([
        r.id,
        r.startedAt.toIso8601String(),
        r.endedAt?.toIso8601String() ?? '',
        r.endedAt?.difference(r.startedAt).inSeconds ?? '',
        r.txEcu,
        r.rxEcu,
        r.startDid,
        r.endDid,
        r.periodMs,
        r.totalProbes,
        r.validResponses,
        _csvEscape(r.carState ?? ''),
        _csvEscape(r.notes ?? ''),
      ].join(','));
    }
    return buf.toString();
  }

  String _sweepResultsToCsv(List<SweepResult> results) {
    final buf = StringBuffer();
    buf.writeln('id,sweep_run_id,sequence,did,raw_hex,error_code');
    for (final r in results) {
      buf.writeln([
        r.id,
        r.sweepRunId,
        r.sequence,
        r.did,
        r.rawHex ?? '',
        r.errorCode ?? '',
      ].join(','));
    }
    return buf.toString();
  }

  /// Wrap value in quotes if it contains commas, quotes, or newlines.
  /// Returns the value as-is otherwise.
  String _csvEscape(String s) {
    if (s.isEmpty) return '';
    if (s.contains(',') || s.contains('"') || s.contains('\n')) {
      final escaped = s.replaceAll('"', '""');
      return '"$escaped"';
    }
    return s;
  }
}

class ExportResult {
  final String zipPath;
  final int sizeBytes;
  final Map<String, int> counts;
  final bool sharedSuccessfully;
  ExportResult({
    required this.zipPath,
    required this.sizeBytes,
    required this.counts,
    required this.sharedSuccessfully,
  });

  String get humanSize {
    if (sizeBytes < 1024) return '${sizeBytes}B';
    if (sizeBytes < 1024 * 1024) return '${(sizeBytes / 1024).toStringAsFixed(1)} KB';
    return '${(sizeBytes / 1024 / 1024).toStringAsFixed(1)} MB';
  }
}
