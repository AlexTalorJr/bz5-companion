import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../l10n/strings.dart';
import '../services/account_auth_service.dart';
import '../services/app_diag_log.dart';
import '../services/cloud_sync_service.dart';
import '../services/diag_dump_file.dart';
import '../services/hal_telemetry_service.dart';
import '../services/locale_service.dart';
import '../services/vehicle_catalog_service.dart';
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
    final vcat = context.watch<VehicleCatalogService>();
    // Compact cache age for the catalog row: 45m / 3h / 2d.
    String age(DateTime t) {
      final d = DateTime.now().difference(t);
      if (d.inHours < 1) return '${d.inMinutes}m';
      if (d.inDays < 1) return '${d.inHours}h';
      return '${d.inDays}d';
    }

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
      // v0.1.29+128: fingerprint shown shortened (identity hint, not a
      // copy source); attach_mode verifies the §1.2 re-attach path in
      // the field without server-side help.
      (
        'hw fingerprint',
        cloud.hwFingerprint == null
            ? '—'
            : '${cloud.hwFingerprint!.length > 8 ? cloud.hwFingerprint!.substring(0, 8) : cloud.hwFingerprint!}…',
        false
      ),
      ('pair attach_mode (last)', cloud.lastAttachMode ?? '—', false),
      (
        'vehicle',
        '${cloud.vehicleName ?? '—'} (${cloud.vehicleId ?? '—'})',
        false
      ),
      // v0.1.36+135 (Q2): catalog observability for field check §6 —
      // seed vs cached server version + cache age, one cheap row.
      (
        'vehicle catalog',
        vcat.catalog == null
            ? 'seed (built-in)'
            : 'v${vcat.cachedVersion}'
                ' (${vcat.fetchedAt == null ? '—' : age(vcat.fetchedAt!)})',
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
      // v0.1.37+136 (F3): sync-down observability — cursor (0 = not
      // initialized), last pull timestamp with its insert counters, and
      // the pull-plane error kept separate from the push-plane one.
      ('pull cursor', '${cloud.pullCursor}', false),
      (
        'last pull',
        cloud.lastPullAt == null
            ? '—'
            : '${dt(cloud.lastPullAt)} '
                '+${cloud.lastPullTrips}'
                '(~${cloud.lastPullTripsUpdated} upd)'
                '/+${cloud.lastPullSnaps}',
        false
      ),
      ('pull error', cloud.lastPullError ?? '—', cloud.lastPullError != null),
      // v0.1.34+133: approval-gate state — server code if gated,
      // otherwise the plain sync status name.
      ('account approval', cloud.lastError?.startsWith('account_') == true
          ? cloud.lastError!
          : cloud.status.name, false),
      ('last error', cloud.lastError ?? '—', cloud.lastError != null),
    ];
    // v0.1.29+124 (C2): account-plane state alongside the device-plane
    // rows — separate credential, shown together for field debugging.
    final auth = context.watch<AccountAuthService>();
    final accessLeft = auth.accessExpiresAt == null
        ? '—'
        : '${auth.accessExpiresAt!.difference(DateTime.now()).inSeconds}s';
    rows.addAll([
      ('account status', auth.status.name, false),
      ('account email', auth.email ?? '—', false),
      ('account access expires in', accessLeft, false),
      (
        'account last error',
        auth.lastErrorCode ?? '—',
        auth.lastErrorCode != null
      ),
    ]);
    // v0.1.32+131: the three raw SOC figures side by side + the active UI
    // source — closes any future "the app shows the wrong percent" dispute
    // with one glance at this screen (per the +131 SOC-source work).
    final hal = context.watch<HalTelemetryService>();
    String socV(String name, [int dec = 0]) {
      final v = hal.halValue(name);
      return v == null ? '—' : v.toStringAsFixed(dec);
    }

    rows.addAll([
      ('soc source (ui)', hal.socSource.name, false),
      (
        'soc precise · display · battery',
        '${socV('soc_precise', 1)} · ${socV('soc_display')} · '
            '${socV('soc_battery')}',
        false
      ),
    ]);
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
