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

/// v0.1.15: list of all past Live Log sessions.
class LiveLogSessionListScreen extends StatelessWidget {
  const LiveLogSessionListScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final svc = context.watch<ConnectionService>();
    return Scaffold(
      appBar: AppBar(title: const Text('Live Log history')),
      body: FutureBuilder<List<LiveLogSession>>(
        future: svc.db.getAllLiveLogSessions(),
        builder: (context, snap) {
          if (!snap.hasData) {
            return const Center(child: CircularProgressIndicator());
          }
          final sessions = snap.data!;
          if (sessions.isEmpty) {
            return Center(
              child: Padding(
                padding: const EdgeInsets.all(32),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(Icons.timeline,
                        size: 56, color: Colors.grey.shade600),
                    const SizedBox(height: 16),
                    const Text('No live-log sessions yet',
                        style: TextStyle(fontSize: 15)),
                    const SizedBox(height: 8),
                    Text(
                      'Run a session from Settings → Live Log.',
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
            itemCount: sessions.length,
            separatorBuilder: (_, __) => const Divider(height: 1),
            itemBuilder: (context, i) {
              final s = sessions[i];
              final dateStr = DateFormat('d MMM HH:mm').format(s.startedAt);
              final duration = s.endedAt != null
                  ? s.endedAt!.difference(s.startedAt).inSeconds
                  : null;
              return ListTile(
                leading: const Icon(Icons.timeline),
                title: Text(s.didList,
                    style: const TextStyle(
                        fontSize: 13,
                        fontFeatures: [FontFeature.tabularFigures()])),
                subtitle: Text(
                  '$dateStr · ${s.cycleCount} cycles · ${s.entryCount} entries'
                  '${duration != null ? " · ${duration}s" : " · in progress"}'
                  '${s.carState != null ? " · ${s.carState}" : ""}',
                  style: const TextStyle(fontSize: 12),
                ),
                trailing: Text('#${s.id}',
                    style: const TextStyle(color: Colors.grey, fontSize: 11)),
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => LiveLogResultsScreen(sessionId: s.id),
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

/// v0.1.15: results viewer for a single Live Log session.
/// Shows summary stats + time-series table. Share/save zip per session.
class LiveLogResultsScreen extends StatefulWidget {
  final int sessionId;
  const LiveLogResultsScreen({super.key, required this.sessionId});

  @override
  State<LiveLogResultsScreen> createState() => _LiveLogResultsScreenState();
}

class _LiveLogResultsScreenState extends State<LiveLogResultsScreen> {
  bool _exporting = false;

  @override
  Widget build(BuildContext context) {
    final svc = context.watch<ConnectionService>();

    return Scaffold(
      appBar: AppBar(
        title: Text('Live Log #${widget.sessionId}'),
        actions: [
          IconButton(
            icon: _exporting
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.ios_share),
            tooltip: 'Share this session',
            onPressed: _exporting ? null : () => _shareSession(svc, share: true),
          ),
          IconButton(
            icon: const Icon(Icons.download),
            tooltip: 'Save to Downloads',
            onPressed: _exporting ? null : () => _shareSession(svc, share: false),
          ),
        ],
      ),
      body: FutureBuilder<LiveLogSession?>(
        future: svc.db.getLiveLogSession(widget.sessionId),
        builder: (context, sessionSnap) {
          if (!sessionSnap.hasData || sessionSnap.data == null) {
            return const Center(child: CircularProgressIndicator());
          }
          final session = sessionSnap.data!;
          return Column(
            children: [
              _Header(session: session),
              const Divider(height: 1),
              Expanded(
                child: FutureBuilder<List<LiveLogEntry>>(
                  future: svc.db.getLiveLogEntries(widget.sessionId),
                  builder: (context, entrySnap) {
                    if (!entrySnap.hasData) {
                      return const Center(
                          child: CircularProgressIndicator());
                    }
                    return _EntriesTable(
                      entries: entrySnap.data!,
                      didList: session.didList,
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

  /// Build a small zip with this session's data and share or save.
  Future<void> _shareSession(ConnectionService svc, {required bool share}) async {
    setState(() => _exporting = true);
    try {
      final session = await svc.db.getLiveLogSession(widget.sessionId);
      if (session == null) throw Exception('Session not found');
      final entries = await svc.db.getLiveLogEntries(widget.sessionId);

      final archive = Archive();
      final ts = DateFormat('yyyyMMdd-HHmmss').format(DateTime.now());

      // Session header
      final hdr = StringBuffer()
        ..writeln(
          'id,started_at,ended_at,duration_seconds,did_list,'
          'cycle_count,entry_count,car_state,notes',
        )
        ..writeln([
          session.id,
          session.startedAt.toIso8601String(),
          session.endedAt?.toIso8601String() ?? '',
          session.endedAt?.difference(session.startedAt).inSeconds ?? '',
          _csvEsc(session.didList),
          session.cycleCount,
          session.entryCount,
          _csvEsc(session.carState ?? ''),
          _csvEsc(session.notes ?? ''),
        ].join(','));
      final hdrBytes = utf8.encode(hdr.toString());
      archive.addFile(ArchiveFile(
          'livelog_session_${session.id}.csv', hdrBytes.length, hdrBytes));

      // Entries — long format
      final entCsv = StringBuffer()
        ..writeln('cycle,timestamp,ecu_tx,did,raw_hex,error_code');
      for (final e in entries) {
        entCsv.writeln(
          '${e.cycle},${e.timestamp.toIso8601String()},${e.ecuTx},${e.did},'
          '${e.rawHex ?? ""},${e.errorCode ?? ""}',
        );
      }
      final entBytes = utf8.encode(entCsv.toString());
      archive.addFile(ArchiveFile(
          'livelog_entries_${session.id}.csv', entBytes.length, entBytes));

      // Also a WIDE format CSV: one row per cycle with columns = DIDs.
      // Easier for plotting in Excel/Numbers.
      final didKeys = session.didList.split(',');
      final wideCsv = StringBuffer()
        ..writeln('cycle,timestamp,${didKeys.map(_csvEsc).join(",")}');
      // Group by cycle
      final byCycle = <int, Map<String, String>>{};
      final cycleTime = <int, DateTime>{};
      for (final e in entries) {
        final key = '${e.ecuTx}/${e.did}';
        byCycle.putIfAbsent(e.cycle, () => {})[key] = e.rawHex ?? '';
        cycleTime.putIfAbsent(e.cycle, () => e.timestamp);
      }
      final cycles = byCycle.keys.toList()..sort();
      for (final c in cycles) {
        final row = byCycle[c]!;
        final ts = cycleTime[c]!.toIso8601String();
        wideCsv.writeln(
          '$c,$ts,${didKeys.map((k) => row[k] ?? "").join(",")}',
        );
      }
      final wideBytes = utf8.encode(wideCsv.toString());
      archive.addFile(ArchiveFile(
          'livelog_wide_${session.id}.csv', wideBytes.length, wideBytes));

      // Metadata
      final meta = {
        'app': 'BZ5 Companion',
        'live_log_session_id': session.id,
        'did_list': session.didList,
        'cycle_count': session.cycleCount,
        'entry_count': session.entryCount,
        'started_at': session.startedAt.toIso8601String(),
        'ended_at': session.endedAt?.toIso8601String(),
        'car_state': session.carState,
        'notes': session.notes,
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
          'bz5_livelog_${session.id}_${session.cycleCount}cycles_$ts.zip';
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
          subject: 'BZ5 live log #${session.id}',
          text:
              '${session.didList} · ${session.cycleCount} cycles · '
              '${session.entryCount} entries',
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
    final pub = Directory('/storage/emulated/0/Download');
    try {
      if (await pub.exists()) {
        final probe = File(p.join(pub.path,
            '.bz5_probe_${DateTime.now().millisecondsSinceEpoch}'));
        try {
          await probe.create();
          await probe.delete();
          return pub;
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

class _Header extends StatelessWidget {
  final LiveLogSession session;
  const _Header({required this.session});

  @override
  Widget build(BuildContext context) {
    final dateStr = DateFormat('d MMM y, HH:mm:ss').format(session.startedAt);
    final duration = session.endedAt != null
        ? session.endedAt!.difference(session.startedAt).inSeconds
        : null;
    final inProgress = session.endedAt == null;
    final dids = session.didList.split(',');

    return Card(
      margin: const EdgeInsets.all(8),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Text('${dids.length} DIDs',
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
                Text('#${session.id}',
                    style: const TextStyle(color: Colors.grey)),
              ],
            ),
            const SizedBox(height: 4),
            Wrap(
              spacing: 4,
              children: dids
                  .map((d) => Chip(
                        label: Text(d,
                            style: const TextStyle(
                                fontSize: 11,
                                fontFeatures: [FontFeature.tabularFigures()])),
                        padding: EdgeInsets.zero,
                        materialTapTargetSize:
                            MaterialTapTargetSize.shrinkWrap,
                        visualDensity: VisualDensity.compact,
                      ))
                  .toList(),
            ),
            const SizedBox(height: 4),
            Text(
              '$dateStr'
              '${duration != null ? " · ${duration}s" : ""}',
              style: const TextStyle(fontSize: 12, color: Colors.grey),
            ),
            const SizedBox(height: 2),
            Text(
              '${session.cycleCount} cycles · ${session.entryCount} entries',
              style: const TextStyle(
                  fontSize: 13,
                  fontFeatures: [FontFeature.tabularFigures()]),
            ),
            if (session.carState != null && session.carState!.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text('Car state: ${session.carState}',
                    style: const TextStyle(
                        fontSize: 12, color: Colors.lightBlueAccent)),
              ),
            if (session.notes != null && session.notes!.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Text('Notes: ${session.notes}',
                    style: const TextStyle(
                        fontSize: 12, fontStyle: FontStyle.italic)),
              ),
          ],
        ),
      ),
    );
  }
}

/// Tabular view of entries — easier for the user to skim raw values.
class _EntriesTable extends StatelessWidget {
  final List<LiveLogEntry> entries;
  final String didList;
  const _EntriesTable({required this.entries, required this.didList});

  @override
  Widget build(BuildContext context) {
    if (entries.isEmpty) {
      return const Center(child: Text('No entries'));
    }

    // Build wide layout: rows = cycle, columns = DIDs
    final didKeys = didList.split(',');
    final byCycle = <int, Map<String, String>>{};
    for (final e in entries) {
      final key = '${e.ecuTx}/${e.did}';
      byCycle.putIfAbsent(e.cycle, () => {})[key] =
          e.rawHex ?? e.errorCode ?? '';
    }
    final cycles = byCycle.keys.toList()..sort();

    return ListView.builder(
      itemCount: cycles.length,
      itemBuilder: (_, idx) {
        final c = cycles[idx];
        final row = byCycle[c]!;
        return Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          decoration: BoxDecoration(
            border: Border(
              bottom: BorderSide(
                  color: Colors.grey.shade800.withValues(alpha: 0.5)),
            ),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(
                width: 40,
                child: Text('$c',
                    style: const TextStyle(
                        fontSize: 11,
                        color: Colors.grey,
                        fontFeatures: [FontFeature.tabularFigures()])),
              ),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: didKeys.map((k) {
                    final v = row[k] ?? '';
                    final isError = v.startsWith('7F') ||
                        v == 'TIMEOUT' ||
                        v == 'EMPTY' ||
                        v.startsWith('MALFORMED');
                    return Padding(
                      padding: const EdgeInsets.symmetric(vertical: 1),
                      child: Row(
                        children: [
                          SizedBox(
                            width: 80,
                            child: Text(k,
                                style: const TextStyle(
                                    fontSize: 11,
                                    color: Colors.grey,
                                    fontFeatures: [
                                      FontFeature.tabularFigures()
                                    ])),
                          ),
                          Expanded(
                            child: GestureDetector(
                              onTap: () => Clipboard.setData(
                                  ClipboardData(text: v)),
                              child: Text(v,
                                  style: TextStyle(
                                      fontSize: 12,
                                      fontFamily: 'monospace',
                                      color: isError
                                          ? Colors.orangeAccent
                                          : Colors.white)),
                            ),
                          ),
                        ],
                      ),
                    );
                  }).toList(),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}
