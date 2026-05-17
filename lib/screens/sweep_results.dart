import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:archive/archive_io.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:provider/provider.dart';
import 'package:share_plus/share_plus.dart';

import '../data/database.dart';
import '../services/connection.dart';

/// v0.1.14: list of all past sweep runs.
///
/// Tap any row to open SweepResultsScreen for that run.
class SweepRunListScreen extends StatelessWidget {
  const SweepRunListScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final svc = context.watch<ConnectionService>();
    return Scaffold(
      appBar: AppBar(title: const Text('Sweep history')),
      body: FutureBuilder<List<SweepRun>>(
        future: svc.db.getAllSweepRuns(),
        builder: (context, snap) {
          if (!snap.hasData) {
            return const Center(child: CircularProgressIndicator());
          }
          final runs = snap.data!;
          if (runs.isEmpty) {
            return Center(
              child: Padding(
                padding: const EdgeInsets.all(32),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(Icons.search_off,
                        size: 56, color: Colors.grey.shade600),
                    const SizedBox(height: 16),
                    const Text('No sweep runs yet',
                        style: TextStyle(fontSize: 15)),
                    const SizedBox(height: 8),
                    Text(
                      'Run a sweep from Settings → DID Sweep '
                      'or from Raw Data → Run sweep on head unit.',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                          fontSize: 12, color: Colors.grey.shade600),
                    ),
                  ],
                ),
              ),
            );
          }
          return ListView.separated(
            itemCount: runs.length,
            separatorBuilder: (_, __) => const Divider(height: 1),
            itemBuilder: (context, i) {
              final r = runs[i];
              final dateStr = DateFormat('d MMM HH:mm').format(r.startedAt);
              final duration = r.endedAt != null
                  ? r.endedAt!.difference(r.startedAt).inSeconds
                  : null;
              return ListTile(
                leading: const Icon(Icons.search),
                title: Text('${r.txEcu} → 0x${r.startDid}..0x${r.endDid}'),
                subtitle: Text(
                  '$dateStr · ${r.validResponses}/${r.totalProbes} valid'
                  '${duration != null ? ' · ${duration}s' : ' · in progress'}'
                  '${r.carState != null ? ' · ${r.carState}' : ''}',
                  style: const TextStyle(fontSize: 12),
                ),
                trailing: Text('#${r.id}',
                    style: const TextStyle(color: Colors.grey, fontSize: 11)),
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => SweepResultsScreen(runId: r.id),
                  ),
                ),
              );
            },
          );
        },
      ),
    );
  }
}

/// v0.1.14: results viewer for a single sweep run.
///
/// Shows run header (ECU, range, timing, counts) and a filterable list of
/// results. Filter: All / Valid / Errors / Empty.
///
/// Share action exports just this run's results as a small zip
/// (sweep_run_N.csv + sweep_results_N.csv + metadata) — convenient for
/// sending one sweep to a chat without dumping the entire DB.
class SweepResultsScreen extends StatefulWidget {
  final int runId;
  const SweepResultsScreen({super.key, required this.runId});

  @override
  State<SweepResultsScreen> createState() => _SweepResultsScreenState();
}

enum _Filter { all, valid, errors, empty }

class _SweepResultsScreenState extends State<SweepResultsScreen> {
  _Filter _filter = _Filter.valid;
  bool _exporting = false;

  @override
  Widget build(BuildContext context) {
    final svc = context.watch<ConnectionService>();

    return Scaffold(
      appBar: AppBar(
        title: Text('Sweep #${widget.runId}'),
        actions: [
          IconButton(
            icon: _exporting
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.ios_share),
            tooltip: 'Share this run',
            onPressed: _exporting ? null : () => _shareRun(svc, share: true),
          ),
          IconButton(
            icon: const Icon(Icons.download),
            tooltip: 'Save to Downloads',
            onPressed: _exporting ? null : () => _shareRun(svc, share: false),
          ),
        ],
      ),
      body: FutureBuilder<SweepRun?>(
        future: _getRun(svc),
        builder: (context, runSnap) {
          if (!runSnap.hasData || runSnap.data == null) {
            return const Center(child: CircularProgressIndicator());
          }
          final run = runSnap.data!;
          return Column(
            children: [
              _RunHeader(run: run),
              _FilterBar(
                current: _filter,
                onChanged: (f) => setState(() => _filter = f),
              ),
              const Divider(height: 1),
              Expanded(
                child: FutureBuilder<List<SweepResult>>(
                  future: svc.db.getSweepResults(widget.runId),
                  builder: (context, resSnap) {
                    if (!resSnap.hasData) {
                      return const Center(
                          child: CircularProgressIndicator());
                    }
                    final all = resSnap.data!;
                    final filtered = _applyFilter(all, _filter);
                    if (filtered.isEmpty) {
                      return Center(
                        child: Text('No results match filter',
                            style: TextStyle(color: Colors.grey.shade600)),
                      );
                    }
                    return ListView.builder(
                      itemCount: filtered.length,
                      itemBuilder: (_, i) => _ResultTile(result: filtered[i]),
                    );
                  },
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  Future<SweepRun?> _getRun(ConnectionService svc) async {
    final runs = await svc.db.getAllSweepRuns();
    for (final r in runs) {
      if (r.id == widget.runId) return r;
    }
    return null;
  }

  List<SweepResult> _applyFilter(List<SweepResult> all, _Filter f) {
    switch (f) {
      case _Filter.all:
        return all;
      case _Filter.valid:
        return all
            .where((r) => r.rawHex != null && r.rawHex!.isNotEmpty)
            .toList();
      case _Filter.errors:
        return all.where((r) => r.errorCode != null).toList();
      case _Filter.empty:
        return all
            .where((r) =>
                r.rawHex == null &&
                r.errorCode == null)
            .toList();
    }
  }

  /// Build a small zip with just this sweep run's data and either share it
  /// (system share sheet) or save it to public Downloads.
  Future<void> _shareRun(ConnectionService svc, {required bool share}) async {
    setState(() => _exporting = true);
    try {
      final run = await _getRun(svc);
      if (run == null) throw Exception('Run not found');
      final results = await svc.db.getSweepResults(widget.runId);

      // Build the run-specific zip
      final archive = Archive();
      final ts = DateFormat('yyyyMMdd-HHmmss').format(DateTime.now());

      // Run header CSV
      final runCsv = StringBuffer()
        ..writeln(
          'id,started_at,ended_at,duration_seconds,tx_ecu,rx_ecu,'
          'start_did,end_did,period_ms,total_probes,valid_responses,'
          'car_state,notes',
        )
        ..writeln([
          run.id,
          run.startedAt.toIso8601String(),
          run.endedAt?.toIso8601String() ?? '',
          run.endedAt?.difference(run.startedAt).inSeconds ?? '',
          run.txEcu,
          run.rxEcu,
          run.startDid,
          run.endDid,
          run.periodMs,
          run.totalProbes,
          run.validResponses,
          _csvEsc(run.carState ?? ''),
          _csvEsc(run.notes ?? ''),
        ].join(','));
      final runBytes = utf8.encode(runCsv.toString());
      archive.addFile(ArchiveFile('sweep_run_${run.id}.csv',
          runBytes.length, runBytes));

      // Results CSV
      final resCsv = StringBuffer()
        ..writeln('sequence,did,raw_hex,error_code');
      for (final r in results) {
        resCsv.writeln(
            '${r.sequence},${r.did},${r.rawHex ?? ''},${r.errorCode ?? ''}');
      }
      final resBytes = utf8.encode(resCsv.toString());
      archive.addFile(ArchiveFile('sweep_results_${run.id}.csv',
          resBytes.length, resBytes));

      // Metadata
      final meta = {
        'app': 'BZ5 Companion',
        'sweep_run_id': run.id,
        'tx_ecu': run.txEcu,
        'rx_ecu': run.rxEcu,
        'start_did': run.startDid,
        'end_did': run.endDid,
        'total_probes': run.totalProbes,
        'valid_responses': run.validResponses,
        'started_at': run.startedAt.toIso8601String(),
        'ended_at': run.endedAt?.toIso8601String(),
        'exported_at': DateTime.now().toIso8601String(),
      };
      final metaBytes =
          utf8.encode(const JsonEncoder.withIndent('  ').convert(meta));
      archive.addFile(
          ArchiveFile('metadata.json', metaBytes.length, metaBytes));

      // Write zip
      final destDir = share
          ? await getTemporaryDirectory()
          : await _resolveDownloadsDir();
      final zipName =
          'bz5_sweep_${run.id}_${run.txEcu}_${run.startDid}-${run.endDid}_$ts.zip';
      final zipPath = p.join(destDir.path, zipName);

      final zipBytes = ZipEncoder().encode(archive);
      if (zipBytes == null) throw Exception('zip encoding failed');
      final zipFile = File(zipPath);
      await zipFile.create(recursive: true);
      await zipFile.writeAsBytes(zipBytes, flush: true);

      if (!mounted) return;
      if (share) {
        // ignore: deprecated_member_use
        await Share.shareXFiles(
          [XFile(zipPath, mimeType: 'application/zip', name: zipName)],
          subject: 'BZ5 sweep #${run.id}',
          text:
              '${run.txEcu} → 0x${run.startDid}..0x${run.endDid} · '
              '${run.validResponses}/${run.totalProbes} valid responses',
        );
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Saved: $zipPath')),
        );
      }
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Export failed: $e')),
      );
    } finally {
      if (mounted) setState(() => _exporting = false);
    }
  }

  Future<Directory> _resolveDownloadsDir() async {
    try {
      if (Platform.isAndroid) {
        await Permission.storage.request();
      }
    } catch (_) {}
    final publicDownloads = Directory('/storage/emulated/0/Download');
    try {
      if (await publicDownloads.exists()) {
        final probe = File(p.join(publicDownloads.path,
            '.bz5_probe_${DateTime.now().millisecondsSinceEpoch}'));
        try {
          await probe.create();
          await probe.delete();
          return publicDownloads;
        } catch (_) {}
      }
    } catch (_) {}
    try {
      final ext = await getExternalStorageDirectory();
      if (ext != null) {
        final dl = Directory(p.join(ext.path, 'Downloads'));
        await dl.create(recursive: true);
        return dl;
      }
    } catch (_) {}
    return getApplicationDocumentsDirectory();
  }

  String _csvEsc(String s) {
    if (s.isEmpty) return '';
    if (s.contains(',') || s.contains('"') || s.contains('\n')) {
      return '"${s.replaceAll('"', '""')}"';
    }
    return s;
  }
}

class _RunHeader extends StatelessWidget {
  final SweepRun run;
  const _RunHeader({required this.run});

  @override
  Widget build(BuildContext context) {
    final dateStr = DateFormat('d MMM y, HH:mm:ss').format(run.startedAt);
    final duration = run.endedAt != null
        ? run.endedAt!.difference(run.startedAt).inSeconds
        : null;
    final inProgress = run.endedAt == null;

    return Card(
      margin: const EdgeInsets.all(8),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Text('${run.txEcu} → ${run.rxEcu}',
                    style: const TextStyle(
                        fontSize: 18, fontWeight: FontWeight.w500)),
                const Spacer(),
                if (inProgress)
                  const Padding(
                    padding: EdgeInsets.only(right: 8),
                    child: Text('RUNNING',
                        style: TextStyle(
                            fontSize: 10,
                            color: Colors.orangeAccent,
                            letterSpacing: 1.5)),
                  ),
                Text('#${run.id}',
                    style: const TextStyle(color: Colors.grey)),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              'Range: 0x${run.startDid} .. 0x${run.endDid} '
              '(${run.totalProbes} DIDs)',
              style: const TextStyle(
                  fontSize: 13,
                  fontFeatures: [FontFeature.tabularFigures()]),
            ),
            Text(
              '$dateStr'
              '${duration != null ? ' · ${duration}s' : ''}',
              style: const TextStyle(fontSize: 12, color: Colors.grey),
            ),
            const SizedBox(height: 4),
            Text(
              '${run.validResponses} valid · '
              '${run.totalProbes - run.validResponses} no response or error',
              style: const TextStyle(
                  fontSize: 13,
                  fontFeatures: [FontFeature.tabularFigures()]),
            ),
            if (run.carState != null && run.carState!.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text('Car state: ${run.carState}',
                    style: const TextStyle(
                        fontSize: 12, color: Colors.lightBlueAccent)),
              ),
            if (run.notes != null && run.notes!.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Text('Notes: ${run.notes}',
                    style: const TextStyle(
                        fontSize: 12, fontStyle: FontStyle.italic)),
              ),
          ],
        ),
      ),
    );
  }
}

class _FilterBar extends StatelessWidget {
  final _Filter current;
  final ValueChanged<_Filter> onChanged;
  const _FilterBar({required this.current, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      child: SegmentedButton<_Filter>(
        segments: const [
          ButtonSegment(value: _Filter.valid, label: Text('Valid')),
          ButtonSegment(value: _Filter.errors, label: Text('Errors')),
          ButtonSegment(value: _Filter.empty, label: Text('Empty')),
          ButtonSegment(value: _Filter.all, label: Text('All')),
        ],
        selected: {current},
        onSelectionChanged: (s) => onChanged(s.first),
        showSelectedIcon: false,
      ),
    );
  }
}

class _ResultTile extends StatelessWidget {
  final SweepResult result;
  const _ResultTile({required this.result});

  @override
  Widget build(BuildContext context) {
    final hasData = result.rawHex != null && result.rawHex!.isNotEmpty;
    final hasError = result.errorCode != null;
    final Color leadingColor = hasData
        ? Colors.greenAccent
        : (hasError ? Colors.orangeAccent : Colors.grey);

    String subtitle;
    if (hasData) {
      subtitle = result.rawHex!;
    } else if (hasError) {
      subtitle = 'Error: ${result.errorCode}';
    } else {
      subtitle = '(empty)';
    }

    return ListTile(
      dense: true,
      leading: Container(
        width: 8, height: 8,
        decoration: BoxDecoration(
            color: leadingColor, shape: BoxShape.circle),
      ),
      title: Text('0x${result.did}',
          style: const TextStyle(
              fontSize: 14,
              fontFeatures: [FontFeature.tabularFigures()])),
      subtitle: Text(subtitle,
          style: const TextStyle(
              fontSize: 11,
              fontFamily: 'monospace',
              color: Colors.grey)),
      trailing: hasData
          ? IconButton(
              icon: const Icon(Icons.copy, size: 16),
              onPressed: () {
                Clipboard.setData(ClipboardData(
                    text: '${result.did}: ${result.rawHex}'));
              },
            )
          : null,
    );
  }
}
