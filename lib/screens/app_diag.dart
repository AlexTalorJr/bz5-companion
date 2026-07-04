import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../l10n/strings.dart';
import '../services/app_diag_log.dart';
import '../services/cloud_sync_service.dart';
import '../services/diag_dump_file.dart';
import '../services/locale_service.dart';
import 'dashboard.dart' show kAppVersion;

/// v0.1.29+122: App Diagnostics — the on-device answer to "no ADB".
///
/// Two blocks:
///   1. Cloud sync state — the CloudSyncService internals that field
///      verification kept needing second-hand from the server operator:
///      the push-v2 gate (`uuidMapInitialDone`), per-entity uuid-mapping
///      watermarks, push cursors, pushed-trip set size, pending counts,
///      last error / last success / last restore.
///   2. App log — the live [AppDiagLog] ring buffer over debugPrint,
///      newest first, with Copy / Export / Clear. Export appends to the
///      proven `bz5_companion_diag.md` Downloads file (DiagDumpFile), so
///      the existing "file manager → USB stick" workflow applies as-is.
///
/// Dev surface (like HAL Test / Polling diagnostics): row labels stay in
/// raw technical English by project l10n rule — diag vocabulary is not
/// translated; screen chrome (title, buttons, snackbars) is localized.
///
/// Accessible from Settings → Advanced → "App log & sync state".
class AppDiagScreen extends StatefulWidget {
  const AppDiagScreen({super.key});

  @override
  State<AppDiagScreen> createState() => _AppDiagScreenState();
}

class _AppDiagScreenState extends State<AppDiagScreen> {
  bool _exporting = false;

  Future<void> _copyAll() async {
    await Clipboard.setData(
        ClipboardData(text: AppDiagLog.instance.exportText()));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(S.of('appdiag.copied'))),
    );
  }

  Future<void> _export() async {
    if (_exporting) return;
    setState(() => _exporting = true);
    try {
      final res = await DiagDumpFile.instance.append(
        title: 'App log export — $kAppVersion',
        body: '```\n${AppDiagLog.instance.exportText()}```',
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(res.describeForUi())),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Export failed: $e')),
      );
    } finally {
      if (mounted) setState(() => _exporting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    // Rebuild on language change (project rule X4 — every S.of screen
    // watches LocaleService so strings flip without re-navigation).
    context.watch<LocaleService>();
    return Scaffold(
      appBar: AppBar(title: Text(S.of('appdiag.title'))),
      body: AnimatedBuilder(
        animation: AppDiagLog.instance,
        builder: (context, _) {
          final log = AppDiagLog.instance;
          // Newest first — the interesting line is usually the last one
          // emitted, and on a head unit scrolling down is cheaper than
          // scrolling to the bottom of 1500 rows.
          final lines = log.lines.reversed.toList(growable: false);
          return ListView.builder(
            padding: const EdgeInsets.all(8),
            itemCount: lines.length + 1,
            itemBuilder: (context, i) {
              if (i == 0) return _header(context, log);
              return Padding(
                padding: const EdgeInsets.symmetric(
                    horizontal: 8, vertical: 1),
                child: SelectableText(
                  lines[i - 1],
                  style: const TextStyle(
                    fontFamily: 'monospace',
                    fontSize: 11,
                    height: 1.25,
                  ),
                ),
              );
            },
          );
        },
      ),
    );
  }

  Widget _header(BuildContext context, AppDiagLog log) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _cloudCard(context),
        Card(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '${S.of('appdiag.log.header')} — '
                  '${log.length} lines'
                  '${log.dropped > 0 ? ', ${log.dropped} dropped' : ''}',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                const SizedBox(height: 4),
                Wrap(
                  spacing: 8,
                  children: [
                    OutlinedButton.icon(
                      icon: const Icon(Icons.copy, size: 16),
                      label: Text(S.of('appdiag.copy')),
                      onPressed: log.length == 0 ? null : _copyAll,
                    ),
                    OutlinedButton.icon(
                      icon: _exporting
                          ? const SizedBox(
                              width: 16,
                              height: 16,
                              child:
                                  CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.save_alt, size: 16),
                      label: Text(S.of('appdiag.export')),
                      onPressed:
                          log.length == 0 || _exporting ? null : _export,
                    ),
                    OutlinedButton.icon(
                      icon: const Icon(Icons.delete_outline, size: 16),
                      label: Text(S.of('appdiag.clear')),
                      onPressed: log.length == 0
                          ? null
                          : () => AppDiagLog.instance.clear(),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _cloudCard(BuildContext context) {
    final cloud = context.watch<CloudSyncService>();
    final wm = cloud.uuidMapWatermarks;
    final st = cloud.stats;
    String dt(DateTime? t) => t == null
        ? '—'
        : t.toLocal().toString().substring(0, 19);
    final rows = <(String, String, bool)>[
      ('status', cloud.status.name, false),
      (
        'enabled / registered',
        '${cloud.enabled} / ${cloud.isRegistered}',
        false
      ),
      ('device_id', cloud.deviceId ?? '—', false),
      (
        'vehicle',
        '${cloud.vehicleName ?? '—'} (${cloud.vehicleId ?? '—'})',
        false
      ),
      (
        'push v2 gate (uuidMapInitialDone)',
        cloud.uuidMapInitialDone ? 'ON' : 'OFF — legacy push',
        !cloud.uuidMapInitialDone
      ),
      (
        'uuid-map watermarks',
        'trips=${wm['trips']} snap=${wm['snapshots']} '
            'sweep=${wm['sweeps']} log=${wm['livelogs']} '
            'can=${wm['canmonitor']}',
        false
      ),
      (
        'push cursors',
        'trip=${cloud.cursorTrip} snap=${cloud.cursorSnapshot} '
            'sweep=${cloud.cursorSweep} log=${cloud.cursorLiveLog} '
            'can=${cloud.cursorCanMonitor}',
        false
      ),
      ('pushed trips (set size)', '${cloud.pushedTripCount}', false),
      (
        'pending',
        'trip=${st.pendingTrips} snap=${st.pendingSnapshots} '
            'sweep=${st.pendingSweeps} log=${st.pendingLiveLogs} '
            'can=${st.pendingCanMonitors}',
        false
      ),
      ('last success', dt(cloud.lastSuccessAt), false),
      ('last restore', dt(cloud.lastRestoreAt), false),
      ('restore status', cloud.restoreStatus.name, false),
      ('last error', cloud.lastError ?? '—', cloud.lastError != null),
    ];
    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              S.of('appdiag.cloud.header'),
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 4),
            for (final (k, v, warn) in rows)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 1),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SizedBox(
                      width: 190,
                      child: Text(
                        k,
                        style: const TextStyle(
                            fontSize: 11, color: Colors.grey),
                      ),
                    ),
                    Expanded(
                      child: SelectableText(
                        v,
                        style: TextStyle(
                          fontFamily: 'monospace',
                          fontSize: 11,
                          color: warn ? Colors.orangeAccent : null,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}
