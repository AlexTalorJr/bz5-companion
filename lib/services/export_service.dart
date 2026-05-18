import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:archive/archive_io.dart';
import 'package:flutter/foundation.dart';
import 'package:intl/intl.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:share_plus/share_plus.dart';

import '../data/database.dart';

/// v0.1.11: bundles all app data into one timestamped zip and hands it off
/// to the system share sheet for the user to save (e.g. to a USB flash via
/// the head unit's "Files" app, or to Google Drive / Telegram / email).
///
/// v0.1.13: added [exportToDownloads] path. Toyota BZ5 head unit launcher
/// does NOT register a share-sheet handler (system reports "no application
/// can perform this action" when share is invoked). For that platform we
/// instead write the zip straight to /storage/emulated/0/Download/, where
/// the user can find it via Toyota's built-in "Проводник" / file manager
/// and copy to USB flash from there.
///
/// Format inside the zip:
///   metadata.json            — schema version, export timestamp, table counts
///   trips.csv                — one row per trip with all aggregates
///   snapshots.csv            — long-term snapshots for trends
///   samples.sqlite           — raw drift DB copy (compact, opens in DB Browser)
///   sweep_runs.csv           — sweep run headers
///   sweep_results.csv        — sweep probe results
///   live_log_sessions.csv    — live-log session headers (v0.1.15+)
///   live_log_entries.csv     — live-log time-series entries (v0.1.15+)
class ExportService {
  final AppDatabase db;
  ExportService(this.db);

  /// Public method: build zip + open system share sheet.
  /// Works on phones (Telegram, Drive, Email etc.).
  /// On Toyota head unit the share sheet may be empty — use
  /// [exportToDownloads] instead.
  Future<ExportResult> exportAll({
    bool includeSamples = true,
    bool includeSweeps = true,
    bool includeSnapshots = true,
    bool includeTrips = true,
    bool includeLiveLogs = true,
    void Function(String stage)? onProgress,
  }) async {
    final built = await _buildZip(
      includeSamples: includeSamples,
      includeSweeps: includeSweeps,
      includeSnapshots: includeSnapshots,
      includeTrips: includeTrips,
      includeLiveLogs: includeLiveLogs,
      onProgress: onProgress,
      destDir: await getTemporaryDirectory(),
    );

    onProgress?.call('sharing');
    // ignore: deprecated_member_use
    final shareResult = await Share.shareXFiles(
      [
        XFile(
          built.zipPath,
          mimeType: 'application/zip',
          name: p.basename(built.zipPath),
        ),
      ],
      subject: 'BZ5 Companion export — ${built.timestamp}',
      text: 'Battery & trip data export from BZ5 Companion.',
    );

    return ExportResult(
      zipPath: built.zipPath,
      sizeBytes: built.sizeBytes,
      counts: built.counts,
      destinationKind: ExportDestinationKind.share,
      sharedSuccessfully: shareResult.status == ShareResultStatus.success,
    );
  }

  /// Public method: build zip and write it directly to the public Downloads
  /// folder (/storage/emulated/0/Download/). User can then access it via any
  /// file manager including Toyota's built-in "Проводник".
  ///
  /// Falls back to app's external files dir if Downloads is not writable
  /// (some Android storage policies restrict legacy paths even with
  /// MANAGE_EXTERNAL_STORAGE off).
  Future<ExportResult> exportToDownloads({
    bool includeSamples = true,
    bool includeSweeps = true,
    bool includeSnapshots = true,
    bool includeTrips = true,
    bool includeLiveLogs = true,
    void Function(String stage)? onProgress,
  }) async {
    // Try public Downloads first. If we can't write there (Android 11+
    // scoped storage restrictions), fall back to app's external Downloads.
    final destDir = await _resolveDownloadsDir();

    final built = await _buildZip(
      includeSamples: includeSamples,
      includeSweeps: includeSweeps,
      includeSnapshots: includeSnapshots,
      includeTrips: includeTrips,
      includeLiveLogs: includeLiveLogs,
      onProgress: onProgress,
      destDir: destDir,
    );

    return ExportResult(
      zipPath: built.zipPath,
      sizeBytes: built.sizeBytes,
      counts: built.counts,
      destinationKind: ExportDestinationKind.downloads,
      sharedSuccessfully: false,
    );
  }

  /// Internal: build zip in [destDir]. Returns a _BuildResult so callers
  /// know the final path / size / counts.
  Future<_BuildResult> _buildZip({
    required bool includeSamples,
    required bool includeSweeps,
    required bool includeSnapshots,
    required bool includeTrips,
    required bool includeLiveLogs,
    required Directory destDir,
    void Function(String stage)? onProgress,
  }) async {
    final ts = DateFormat('yyyyMMdd-HHmmss').format(DateTime.now());
    final zipPath = p.join(destDir.path, 'bz5_export_$ts.zip');

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

    if (includeLiveLogs) {
      onProgress?.call('live_logs');
      final sessions = await db.getAllLiveLogSessions();
      counts['live_log_sessions'] = sessions.length;
      archive.addFile(ArchiveFile(
        'live_log_sessions.csv',
        0,
        utf8.encode(_liveLogSessionsToCsv(sessions)),
      ));
      final allEntries = <LiveLogEntry>[];
      for (final s in sessions) {
        allEntries.addAll(await db.getLiveLogEntries(s.id));
      }
      counts['live_log_entries'] = allEntries.length;
      archive.addFile(ArchiveFile(
        'live_log_entries.csv',
        0,
        utf8.encode(_liveLogEntriesToCsv(allEntries)),
      ));
    }

    if (includeSamples) {
      onProgress?.call('samples');
      counts['samples'] = await db.countAllSamples();
      final dbFile = await _findDatabaseFile();
      if (dbFile != null && await dbFile.exists()) {
        final bytes = await dbFile.readAsBytes();
        archive.addFile(ArchiveFile('samples.sqlite', bytes.length, bytes));
      } else {
        debugPrint('ExportService: db file not found, falling back to CSV');
        final samples = await db.getAllSamples();
        archive.addFile(ArchiveFile(
          'samples.csv',
          0,
          utf8.encode(_samplesToCsv(samples)),
        ));
      }
    }

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
        'live_logs': includeLiveLogs,
        'samples': includeSamples,
      },
    };
    final metaBytes =
        utf8.encode(const JsonEncoder.withIndent('  ').convert(metadata));
    archive.addFile(ArchiveFile('metadata.json', metaBytes.length, metaBytes));

    onProgress?.call('compressing');
    final encoder = ZipEncoder();
    final zipBytes = encoder.encode(archive);
    if (zipBytes == null) {
      throw Exception('zip encoding returned null');
    }
    final zipFile = File(zipPath);
    await zipFile.create(recursive: true);
    await zipFile.writeAsBytes(zipBytes, flush: true);

    return _BuildResult(
      zipPath: zipPath,
      sizeBytes: zipBytes.length,
      counts: counts,
      timestamp: ts,
    );
  }

  /// Resolve the best directory for "save to Downloads" — public Downloads
  /// if writable, else app's external Downloads dir as fallback.
  Future<Directory> _resolveDownloadsDir() async {
    // On Android < 11, public Downloads requires WRITE_EXTERNAL_STORAGE
    // permission. On Android 11+ the permission is gone (scoped storage),
    // but Flutter's File API can still write to public Downloads if the
    // manifest has android:requestLegacyExternalStorage="true". Many Toyota
    // head units run Android 9-10 where the permission path works.
    try {
      if (Platform.isAndroid) {
        final status = await Permission.storage.request();
        if (!status.isGranted) {
          debugPrint('Storage permission denied, falling back to app-private dir');
        }
      }
    } catch (e) {
      debugPrint('Permission request error: $e (continuing anyway)');
    }

    // Public Downloads — works without permission on Android < 11, and on
    // Android 11+ if app has legacy storage opt-in.
    final publicDownloads = Directory('/storage/emulated/0/Download');
    try {
      if (await publicDownloads.exists()) {
        // Probe write access by creating + deleting a tiny test file.
        final probe = File(p.join(publicDownloads.path,
            '.bz5_write_probe_${DateTime.now().millisecondsSinceEpoch}'));
        try {
          await probe.create();
          await probe.delete();
          return publicDownloads;
        } catch (_) {
          // Not writable — fall through to app-private.
        }
      }
    } catch (_) {}

    // App-private external Downloads — always writable, visible to user
    // through some file managers under "Android/data/com.bz5companion/files".
    try {
      final ext = await getExternalStorageDirectory();
      if (ext != null) {
        final dlDir = Directory(p.join(ext.path, 'Downloads'));
        await dlDir.create(recursive: true);
        return dlDir;
      }
    } catch (_) {}

    // Last resort — app docs dir (private).
    return getApplicationDocumentsDirectory();
  }

  Future<File?> _findDatabaseFile() async {
    try {
      final dir = await getApplicationSupportDirectory();
      final f = File(p.join(dir.path, 'bz5_data.sqlite'));
      if (await f.exists()) return f;
    } catch (_) {}
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

  String _liveLogSessionsToCsv(List<LiveLogSession> sessions) {
    final buf = StringBuffer();
    buf.writeln(
      'id,started_at,ended_at,duration_seconds,did_list,cycle_count,'
      'entry_count,car_state,notes',
    );
    for (final s in sessions) {
      buf.writeln([
        s.id,
        s.startedAt.toIso8601String(),
        s.endedAt?.toIso8601String() ?? '',
        s.endedAt?.difference(s.startedAt).inSeconds ?? '',
        _csvEscape(s.didList),
        s.cycleCount,
        s.entryCount,
        _csvEscape(s.carState ?? ''),
        _csvEscape(s.notes ?? ''),
      ].join(','));
    }
    return buf.toString();
  }

  String _liveLogEntriesToCsv(List<LiveLogEntry> entries) {
    final buf = StringBuffer();
    buf.writeln('id,session_id,cycle,timestamp,ecu_tx,did,raw_hex,error_code');
    for (final e in entries) {
      buf.writeln([
        e.id,
        e.sessionId,
        e.cycle,
        e.timestamp.toIso8601String(),
        e.ecuTx,
        e.did,
        e.rawHex ?? '',
        e.errorCode ?? '',
      ].join(','));
    }
    return buf.toString();
  }

  String _csvEscape(String s) {
    if (s.isEmpty) return '';
    if (s.contains(',') || s.contains('"') || s.contains('\n')) {
      final escaped = s.replaceAll('"', '""');
      return '"$escaped"';
    }
    return s;
  }
}

enum ExportDestinationKind { share, downloads }

class _BuildResult {
  final String zipPath;
  final int sizeBytes;
  final Map<String, int> counts;
  final String timestamp;
  _BuildResult({
    required this.zipPath,
    required this.sizeBytes,
    required this.counts,
    required this.timestamp,
  });
}

class ExportResult {
  final String zipPath;
  final int sizeBytes;
  final Map<String, int> counts;
  final ExportDestinationKind destinationKind;
  final bool sharedSuccessfully;
  ExportResult({
    required this.zipPath,
    required this.sizeBytes,
    required this.counts,
    required this.destinationKind,
    required this.sharedSuccessfully,
  });

  String get humanSize {
    if (sizeBytes < 1024) return '${sizeBytes}B';
    if (sizeBytes < 1024 * 1024) {
      return '${(sizeBytes / 1024).toStringAsFixed(1)} KB';
    }
    return '${(sizeBytes / 1024 / 1024).toStringAsFixed(1)} MB';
  }
}
