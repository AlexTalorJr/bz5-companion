import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../data/database.dart';
import '../l10n/strings.dart';
import '../services/connection.dart';
import '../services/locale_service.dart';
import '../services/export_service.dart';

/// v0.1.11: Data management screen — export all data to share sheet,
/// or clear specific tables when storage starts filling up.
///
/// v0.1.13: added "Save to Downloads" path for Toyota head unit where the
/// system share sheet has no registered handlers (no Telegram/Drive/etc.
/// available). Direct write to /storage/emulated/0/Download/ works there.
///
/// Sections:
///   STORAGE — live counts of trips / snapshots / samples / sweep_runs / live_log_sessions
///   EXPORT  — toggles + two buttons:
///             "Поделиться" → system share sheet (phone-friendly)
///             "Сохранить в Downloads" → straight to public Downloads folder
///   CLEANUP — four destructive actions with confirmation dialogs
class DataManagementScreen extends StatefulWidget {
  const DataManagementScreen({super.key});

  @override
  State<DataManagementScreen> createState() => _DataManagementScreenState();
}

class _DataManagementScreenState extends State<DataManagementScreen> {
  bool _includeTrips = true;
  bool _includeSnapshots = true;
  bool _includeSamples = true;
  bool _includeSweeps = true;
  bool _includeLiveLogs = true;

  bool _exporting = false;
  String _stage = '';
  String? _lastResult;

  // Counts shown in UI — fetched on init & after any clear.
  Map<String, int>? _counts;
  bool _loadingCounts = true;

  @override
  void initState() {
    super.initState();
    _refreshCounts();
  }

  Future<void> _refreshCounts() async {
    setState(() => _loadingCounts = true);
    final db = context.read<ConnectionService>().db;
    final counts = {
      'trips': (await db.getAllTrips()).length,
      'snapshots': await db.countAllSnapshots(),
      'samples': await db.countAllSamples(),
      'sweep_runs': await db.countAllSweepRuns(),
      'live_log_sessions': await db.countAllLiveLogSessions(),
    };
    if (!mounted) return;
    setState(() {
      _counts = counts;
      _loadingCounts = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final svc = context.watch<ConnectionService>();
    // v0.1.29+60: re-render on language switch (per-screen subscription).
    context.watch<LocaleService>();
    return Scaffold(
      appBar: AppBar(title: Text(S.of('settings.data.title'))),
      body: ListView(
        padding: const EdgeInsets.symmetric(vertical: 8),
        children: [
          _section(S.of('dataexp.sec_storage')),
          if (_loadingCounts)
            ListTile(
              leading: const SizedBox(
                width: 18, height: 18,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
              title: Text(S.of('dataexp.counting')),
            )
          else if (_counts != null) ...[
            ListTile(
              dense: true,
              leading: const Icon(Icons.route, size: 20),
              title: const Text('Trips'),
              trailing: Text('${_counts!['trips']}',
                  style: const TextStyle(
                      fontFeatures: [FontFeature.tabularFigures()])),
            ),
            ListTile(
              dense: true,
              leading: const Icon(Icons.timeline, size: 20),
              title: const Text('Snapshots'),
              trailing: Text('${_counts!['snapshots']}',
                  style: const TextStyle(
                      fontFeatures: [FontFeature.tabularFigures()])),
            ),
            ListTile(
              dense: true,
              leading: const Icon(Icons.dns, size: 20),
              title: const Text('Raw samples'),
              trailing: Text('${_counts!['samples']}',
                  style: const TextStyle(
                      fontFeatures: [FontFeature.tabularFigures()])),
            ),
            ListTile(
              dense: true,
              leading: const Icon(Icons.search, size: 20),
              title: const Text('Sweep runs'),
              trailing: Text('${_counts!['sweep_runs']}',
                  style: const TextStyle(
                      fontFeatures: [FontFeature.tabularFigures()])),
            ),
            ListTile(
              dense: true,
              leading: const Icon(Icons.timeline, size: 20),
              title: const Text('Live Log sessions'),
              trailing: Text('${_counts!['live_log_sessions']}',
                  style: const TextStyle(
                      fontFeatures: [FontFeature.tabularFigures()])),
            ),
          ],

          const Divider(),
          _section(S.of('dataexp.sec_export')),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
            child: Text(
              S.of('dataexp.export_intro'),
              style: const TextStyle(fontSize: 12, color: Colors.grey),
            ),
          ),
          SwitchListTile(
            value: _includeTrips,
            onChanged: _exporting ? null : (v) => setState(() => _includeTrips = v),
            secondary: const Icon(Icons.route),
            title: const Text('Trips'),
            subtitle: Text(S.of('dataexp.trips_sub')),
            dense: true,
          ),
          SwitchListTile(
            value: _includeSnapshots,
            onChanged: _exporting
                ? null
                : (v) => setState(() => _includeSnapshots = v),
            secondary: const Icon(Icons.timeline),
            title: const Text('Snapshots'),
            subtitle: Text(S.of('dataexp.snapshots_sub')),
            dense: true,
          ),
          SwitchListTile(
            value: _includeSamples,
            onChanged: _exporting
                ? null
                : (v) => setState(() => _includeSamples = v),
            secondary: const Icon(Icons.dns),
            title: const Text('Raw samples'),
            subtitle: Text(S.of('dataexp.samples_sub')),
            dense: true,
          ),
          SwitchListTile(
            value: _includeSweeps,
            onChanged: _exporting ? null : (v) => setState(() => _includeSweeps = v),
            secondary: const Icon(Icons.search),
            title: const Text('Sweep results'),
            subtitle: const Text('sweep_runs.csv + sweep_results.csv'),
            dense: true,
          ),
          SwitchListTile(
            value: _includeLiveLogs,
            onChanged: _exporting ? null : (v) => setState(() => _includeLiveLogs = v),
            secondary: const Icon(Icons.timeline),
            title: const Text('Live Log sessions'),
            subtitle: Text(S.of('dataexp.livelogs_sub')),
            dense: true,
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
            child: ElevatedButton.icon(
              icon: _exporting
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.ios_share),
              label: Text(_exporting
                  ? S.of('dataexp.exporting').replaceFirst('{stage}', _stage)
                  : S.of('dataexp.share_btn')),
              style: ElevatedButton.styleFrom(
                minimumSize: const Size.fromHeight(48),
              ),
              onPressed: _exporting ? null : () => _doExport(svc, toDownloads: false),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
            child: OutlinedButton.icon(
              icon: const Icon(Icons.download),
              label: Text(_exporting
                  ? S.of('dataexp.exporting').replaceFirst('{stage}', _stage)
                  : S.of('dataexp.save_btn')),
              style: OutlinedButton.styleFrom(
                minimumSize: const Size.fromHeight(48),
              ),
              onPressed: _exporting ? null : () => _doExport(svc, toDownloads: true),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: Text(
              S.of('dataexp.hu_note'),
              style: const TextStyle(fontSize: 11, color: Colors.grey),
            ),
          ),
          if (_lastResult != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
              child: Text(_lastResult!,
                  style: const TextStyle(
                      fontSize: 12, color: Colors.greenAccent)),
            ),

          const Divider(),
          _section(S.of('dataexp.sec_cleanup')),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
            child: Text(
              S.of('dataexp.cleanup_warn'),
              style: const TextStyle(fontSize: 12, color: Colors.orangeAccent),
            ),
          ),
          ListTile(
            leading: const Icon(Icons.delete_outline, color: Colors.orangeAccent),
            title: Text(S.of('dataexp.clear_samples')),
            subtitle: Text(S.of('dataexp.clear_samples_sub')),
            onTap: () => _confirmAndClear(
              title: S.of('dataexp.clear_samples_q'),
              description: S.of('dataexp.clear_samples_desc'),
              action: () async {
                final n = await svc.db.clearAllSamples();
                return S
                    .of('dataexp.n_samples_deleted')
                    .replaceFirst('{n}', '$n');
              },
            ),
          ),
          ListTile(
            leading: const Icon(Icons.delete_outline, color: Colors.orangeAccent),
            title: Text(S.of('dataexp.clear_snapshots')),
            subtitle: Text(S.of('dataexp.clear_snapshots_sub')),
            onTap: () => _confirmAndClear(
              title: S.of('dataexp.clear_snapshots_q'),
              description: S.of('dataexp.clear_snapshots_desc'),
              action: () async {
                final n = await svc.db.clearAllSnapshots();
                return S
                    .of('dataexp.n_snapshots_deleted')
                    .replaceFirst('{n}', '$n');
              },
            ),
          ),
          ListTile(
            leading: const Icon(Icons.delete_forever, color: Colors.redAccent),
            title: Text(S.of('dataexp.clear_trips')),
            subtitle: Text(S.of('dataexp.clear_trips_sub')),
            onTap: () => _confirmAndClear(
              title: S.of('dataexp.clear_trips_q'),
              description: S.of('dataexp.clear_trips_desc'),
              action: () async {
                final (trips, samples) = await svc.db.clearAllTrips();
                return S
                    .of('dataexp.trips_samples_deleted')
                    .replaceFirst('{t}', '$trips')
                    .replaceFirst('{s}', '$samples');
              },
            ),
          ),
          ListTile(
            leading: const Icon(Icons.delete_outline, color: Colors.orangeAccent),
            title: Text(S.of('dataexp.clear_sweeps')),
            subtitle: Text(S.of('dataexp.clear_sweeps_sub')),
            onTap: () => _confirmAndClear(
              title: S.of('dataexp.clear_sweeps_q'),
              description: S.of('dataexp.clear_sweeps_desc'),
              action: () async {
                final (runs, results) = await svc.db.clearAllSweeps();
                return S
                    .of('dataexp.runs_results_deleted')
                    .replaceFirst('{r}', '$runs')
                    .replaceFirst('{s}', '$results');
              },
            ),
          ),
          ListTile(
            leading: const Icon(Icons.delete_outline, color: Colors.orangeAccent),
            title: Text(S.of('dataexp.clear_livelogs')),
            subtitle: Text(S.of('dataexp.clear_livelogs_sub')),
            onTap: () => _confirmAndClear(
              title: S.of('dataexp.clear_livelogs_q'),
              description: S.of('dataexp.clear_livelogs_desc'),
              action: () async {
                final (sessions, entries) = await svc.db.clearAllLiveLogs();
                return S
                    .of('dataexp.sessions_entries_deleted')
                    .replaceFirst('{a}', '$sessions')
                    .replaceFirst('{b}', '$entries');
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _section(String title) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
        child: Text(title,
            style: const TextStyle(
                fontSize: 11,
                letterSpacing: 1.5,
                color: Colors.grey,
                fontWeight: FontWeight.w500)),
      );

  Future<void> _doExport(ConnectionService svc, {required bool toDownloads}) async {
    setState(() {
      _exporting = true;
      _stage = 'init';
      _lastResult = null;
    });

    try {
      final exporter = ExportService(svc.db);
      final result = toDownloads
          ? await exporter.exportToDownloads(
              includeTrips: _includeTrips,
              includeSnapshots: _includeSnapshots,
              includeSamples: _includeSamples,
              includeSweeps: _includeSweeps,
              includeLiveLogs: _includeLiveLogs,
              onProgress: (stage) {
                if (mounted) setState(() => _stage = stage);
              },
            )
          : await exporter.exportAll(
              includeTrips: _includeTrips,
              includeSnapshots: _includeSnapshots,
              includeSamples: _includeSamples,
              includeSweeps: _includeSweeps,
              includeLiveLogs: _includeLiveLogs,
              onProgress: (stage) {
                if (mounted) setState(() => _stage = stage);
              },
            );
      if (!mounted) return;
      final summary = result.counts.entries
          .where((e) => e.value > 0)
          .map((e) => '${e.key}=${e.value}')
          .join(', ');
      setState(() {
        if (result.destinationKind == ExportDestinationKind.downloads) {
          _lastResult = S
              .of('dataexp.saved_fmt')
              .replaceFirst('{size}', result.humanSize)
              .replaceFirst('{summary}', summary)
              .replaceFirst('{path}', result.zipPath);
        } else {
          _lastResult = result.sharedSuccessfully
              ? S
                  .of('dataexp.shared_fmt')
                  .replaceFirst('{size}', result.humanSize)
                  .replaceFirst('{summary}', summary)
              : S
                  .of('dataexp.share_cancelled_fmt')
                  .replaceFirst('{size}', result.humanSize)
                  .replaceFirst('{summary}', summary);
        }
      });
    } catch (e) {
      if (!mounted) return;
      setState(() =>
          _lastResult = S.of('dataexp.error_fmt').replaceFirst('{e}', '$e'));
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
            content: Text(S
                .of('dataexp.export_failed_fmt')
                .replaceFirst('{e}', '$e'))),
      );
    } finally {
      if (mounted) {
        setState(() {
          _exporting = false;
          _stage = '';
        });
      }
    }
  }

  Future<void> _confirmAndClear({
    required String title,
    required String description,
    required Future<String> Function() action,
  }) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: Text(title),
        content: Text(description),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: Text(S.of('common.cancel')),
          ),
          TextButton(
            style: TextButton.styleFrom(foregroundColor: Colors.redAccent),
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(S.of('common.delete')),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    try {
      final result = await action();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(result)),
      );
      await _refreshCounts();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
            content:
                Text(S.of('dataexp.error_fmt').replaceFirst('{e}', '$e'))),
      );
    }
  }
}
