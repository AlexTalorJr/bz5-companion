import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show Clipboard, ClipboardData;
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../l10n/strings.dart';
import '../services/connection.dart';
import '../services/locale_service.dart';
import '../services/native_detector.dart';
import '../widgets/responsive.dart';
import '../services/cost_settings.dart';
import '../services/cloud_sync_service.dart';
import '../services/bridge_diag_service.dart';
import 'about.dart';
import 'data_management.dart';
import 'diagnostics.dart';
import 'ecu_explorer.dart';
import 'hal_test.dart';
import 'wide/raw_data_wide.dart';
import 'wide/native_explorer_wide.dart';
import 'live_log.dart';
import 'polling_diagnostics.dart';
import 'sweep.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  List<ScanResult> _devices = [];
  bool _scanning = false;
  bool _autoConnect = false;
  // v0.1.24: persistent toggle for matching the car's analog/digital
  // speedometer reading (which by UN R39 reads ~5% higher than true
  // wheel speed). When enabled, Driver view multiplies 740/0x0008
  // by 1.05 before display.
  bool _matchSpeedometer = false;
  // v0.1.29+59: Advanced (research tools) is hidden until unlocked by
  // 15 taps on the APP card in the About screen (Android dev-options
  // style). Persisted — once unlocked, stays unlocked.
  bool _advancedUnlocked = false;

  @override
  void initState() {
    super.initState();
    _loadSettings();
  }

  Future<void> _loadSettings() async {
    final prefs = await SharedPreferences.getInstance();
    if (!mounted) return;
    setState(() {
      _autoConnect = prefs.getBool('auto_connect_enabled') ?? false;
      _matchSpeedometer = prefs.getBool('match_speedometer') ?? false;
      _advancedUnlocked = prefs.getBool('advanced_unlocked') ?? false;
    });
  }

  Future<void> _setAutoConnect(bool v) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('auto_connect_enabled', v);
    if (!mounted) return;
    setState(() => _autoConnect = v);
  }

  Future<void> _setMatchSpeedometer(bool v) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('match_speedometer', v);
    if (!mounted) return;
    setState(() => _matchSpeedometer = v);
    // Tell ConnectionService to refresh — Driver view watches the
    // service, and the multiplier is applied in the UI rather than
    // in the service, so a notifyListeners forces the redraw.
    if (mounted) {
      // ignore: use_build_context_synchronously
      Provider.of<ConnectionService>(context, listen: false)
          .refreshSpeedometerPref();
    }
  }

  // v0.1.27: cost settings editors. Both use a simple AlertDialog +
  // TextField pattern rather than going through a separate screen —
  // we have exactly two scalars to edit and a dedicated screen would
  // be overkill. The dialog dismisses on Save/Cancel; current value
  // is pre-filled for easy correction of typos.
  Future<void> _editCostPerKwh(
      BuildContext context, CostSettings cs) async {
    final ctrl = TextEditingController(
      text: cs.costPerKwh > 0 ? cs.costPerKwh.toString() : '',
    );
    final result = await showDialog<double>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(S.of('dialog.cost.title')),
        content: TextField(
          controller: ctrl,
          keyboardType:
              const TextInputType.numberWithOptions(decimal: true),
          autofocus: true,
          decoration: InputDecoration(
            labelText: S.of('dialog.cost.label'),
            hintText: S.of('dialog.cost.hint'),
            helperText: S.of('dialog.cost.helper'),
            suffixText: cs.currencySymbol,
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(null),
            child: Text(S.of('common.cancel')),
          ),
          TextButton(
            onPressed: () {
              // Accept comma as decimal separator too — many EU
              // locales use it natively, and Android numeric keypad
              // may emit either depending on system locale.
              final raw = ctrl.text.trim().replaceAll(',', '.');
              final parsed = double.tryParse(raw);
              Navigator.of(ctx).pop(parsed);
            },
            child: Text(S.of('common.save')),
          ),
        ],
      ),
    );
    if (result != null) {
      await cs.setCostPerKwh(result);
    }
  }

  Future<void> _editCurrencySymbol(
      BuildContext context, CostSettings cs) async {
    final ctrl = TextEditingController(text: cs.currencySymbol);
    final result = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(S.of('dialog.currency.title')),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(
              controller: ctrl,
              autofocus: true,
              maxLength: 4,
              decoration: InputDecoration(
                labelText: S.of('dialog.currency.label'),
                hintText: '\$, €, ₽, ¥, RUB, USD...',
              ),
            ),
            const SizedBox(height: 4),
            Text(S.of('dialog.currency.quick'),
                style: const TextStyle(fontSize: 12, color: Colors.grey)),
            const SizedBox(height: 4),
            Wrap(
              spacing: 6,
              children: [
                for (final s in ['\$', '€', '£', '¥', '₽', 'RUB'])
                  ActionChip(
                    label: Text(s),
                    onPressed: () => Navigator.of(ctx).pop(s),
                  ),
              ],
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(null),
            child: Text(S.of('common.cancel')),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(ctrl.text),
            child: Text(S.of('common.save')),
          ),
        ],
      ),
    );
    if (result != null) {
      await cs.setCurrencySymbol(result);
    }
  }

  // v0.1.28: cloud backup UI helpers. Three pieces:
  //   * _buildCloudHeader — section title + icon
  //   * _buildCloudBody — the four states (disconnected, paused,
  //     ok, error) each with its own buttons and status text
  //   * _showCloudSetupDialog — multi-step setup flow (token →
  //     vehicle list → confirm)
  // No state on the screen itself — CloudSyncService is the source
  // of truth and triggers rebuilds via Provider.

  Widget _buildCloudHeader(CloudSyncService cs) {
    final color = _cloudStatusColor(cs.status);
    return ListTile(
      leading: Icon(Icons.cloud_outlined, color: color),
      title: Text(S.of('cloud.title')),
      subtitle: Text(_cloudStatusLabel(cs)),
    );
  }

  Widget _buildCloudBody(BuildContext context, CloudSyncService cs) {
    if (!cs.isInitialized) {
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        child: Text(S.of('common.loading'),
            style: const TextStyle(color: Colors.grey)),
      );
    }
    if (!cs.isRegistered) {
      // Disconnected. Two paths from here:
      //   * Set up — fresh register-device (mints a new device_id;
      //     used for first-ever cloud setup or after Disconnect).
      //   * Restore — bring back history from a previous device by
      //     swapping in its old client_token. This is the head-unit
      //     reinstall path: the head unit can only be uninstalled +
      //     reinstalled (no in-place updates), so Drift is wiped at
      //     every app upgrade. Restore makes that recoverable in
      //     one step instead of forcing a fresh setup + restore.
      return Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text(
            S.of('cloud.intro'),
            style: const TextStyle(fontSize: 12, color: Colors.grey),
          ),
          const SizedBox(height: 8),
          ElevatedButton.icon(
            icon: const Icon(Icons.cloud_sync),
            label: Text(S.of('cloud.setup_btn')),
            onPressed: cs.isRestoring
                ? null
                : () => _showCloudSetupDialog(context, cs),
          ),
          const SizedBox(height: 6),
          OutlinedButton.icon(
            icon: const Icon(Icons.cloud_download_outlined),
            label: Text(S.of('cloud.restore_btn')),
            onPressed: cs.isRestoring
                ? null
                : () => _showRestoreDialog(context, cs),
          ),
          // v0.1.29+18: restore can run from disconnected state. Show
          // progress / last-result here too so the user gets feedback
          // before the card flips into the registered layout.
          if (cs.isRestoring) ...[
            const SizedBox(height: 8),
            Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: Colors.lightBlueAccent.withOpacity(0.12),
                borderRadius: BorderRadius.circular(4),
              ),
              child: Text(
                _restoreProgressLine(cs),
                style: const TextStyle(
                    fontSize: 12, color: Colors.lightBlueAccent),
              ),
            ),
          ],
          if (cs.restoreError != null && !cs.isRestoring) ...[
            const SizedBox(height: 8),
            Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: Colors.orange.withOpacity(0.15),
                borderRadius: BorderRadius.circular(4),
              ),
              child: Text(
                '${S.of('cloud.last_restore')}: ${cs.restoreError!}',
                style: const TextStyle(fontSize: 12, color: Colors.orange),
              ),
            ),
          ],
        ]),
      );
    }
    // Registered. Show toggle + status + actions.
    return Padding(
      padding: const EdgeInsets.fromLTRB(0, 0, 0, 8),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        SwitchListTile(
          dense: true,
          title: Text(S.of('cloud.enabled')),
          subtitle: Text(cs.vehicleName ?? S.of('cloud.unknown_vehicle')),
          value: cs.enabled,
          onChanged: (v) => cs.setEnabled(v),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            if (cs.lastSuccessAt != null)
              Text('${S.of('cloud.last_sync')}: ${_relTime(cs.lastSuccessAt!)}',
                  style: const TextStyle(fontSize: 12, color: Colors.grey))
            else
              Text('${S.of('cloud.last_sync')}: ${S.of('cloud.never')}',
                  style: const TextStyle(fontSize: 12, color: Colors.grey)),
            if (cs.stats.totalPending > 0)
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Text(
                  S
                      .of('cloud.pending')
                      .replaceFirst('{t}', '${cs.stats.pendingTrips}')
                      .replaceFirst('{s}', '${cs.stats.pendingSnapshots}')
                      .replaceFirst('{w}', '${cs.stats.pendingSweeps}')
                      .replaceFirst('{l}', '${cs.stats.pendingLiveLogs}'),
                  style: const TextStyle(fontSize: 12, color: Colors.grey),
                ),
              ),
            if (cs.lastError != null) ...[
              const SizedBox(height: 4),
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: Colors.red.withOpacity(0.15),
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Text(
                  cs.lastError!,
                  style: const TextStyle(fontSize: 12, color: Colors.redAccent),
                ),
              ),
            ],
            // v0.1.29+18: restore status. Mutually exclusive surfaces —
            // either an in-flight progress card OR a last-result line.
            if (cs.isRestoring) ...[
              const SizedBox(height: 6),
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: Colors.lightBlueAccent.withOpacity(0.12),
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Text(
                  _restoreProgressLine(cs),
                  style: const TextStyle(
                      fontSize: 12, color: Colors.lightBlueAccent),
                ),
              ),
            ] else if (cs.lastRestoreAt != null) ...[
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Text(
                  '${S.of('cloud.last_restore')}: ${_relTime(cs.lastRestoreAt!)}',
                  style: const TextStyle(fontSize: 12, color: Colors.grey),
                ),
              ),
            ],
            if (cs.restoreError != null && !cs.isRestoring) ...[
              const SizedBox(height: 4),
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: Colors.orange.withOpacity(0.15),
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Text(
                  '${S.of('cloud.last_restore')}: ${cs.restoreError!}',
                  style: const TextStyle(fontSize: 12, color: Colors.orange),
                ),
              ),
            ],
          ]),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
          child: Wrap(spacing: 8, runSpacing: 4, children: [
            OutlinedButton.icon(
              icon: const Icon(Icons.refresh, size: 18),
              label: Text(S.of('cloud.sync_now')),
              onPressed: cs.status == CloudSyncStatus.syncing || cs.isRestoring
                  ? null
                  : () => cs.syncOnce(reason: 'manual-button'),
            ),
            OutlinedButton.icon(
              icon: const Icon(Icons.replay, size: 18),
              label: Text(S.of('cloud.force_resync')),
              onPressed: cs.status == CloudSyncStatus.syncing || cs.isRestoring
                  ? null
                  : () => _confirmAndForceResync(context, cs),
            ),
            OutlinedButton.icon(
              icon: const Icon(Icons.cloud_download_outlined, size: 18),
              label: Text(S.of('cloud.restore_btn')),
              onPressed: cs.status == CloudSyncStatus.syncing || cs.isRestoring
                  ? null
                  : () => _showRestoreDialog(context, cs),
            ),
            // v0.1.29+18: owner-self-service token backup. Without
            // this, every head-unit reinstall requires Friend 2 to
            // admin-rotate; with it, owner pre-saves the token once
            // and reinstalls become a self-contained operation.
            OutlinedButton.icon(
              icon: const Icon(Icons.vpn_key_outlined, size: 18),
              label: Text(S.of('cloud.backup_token')),
              onPressed: cs.isRestoring
                  ? null
                  : () => _showBackupTokenDialog(context, cs),
            ),
            OutlinedButton.icon(
              icon: const Icon(Icons.link_off, size: 18),
              label: Text(S.of('settings.disconnect')),
              onPressed:
                  cs.isRestoring ? null : () => _confirmAndDisconnect(context, cs),
            ),
          ]),
        ),
      ]),
    );
  }

  /// v0.1.29+18: format the active restore progress for the inline
  /// status card. Phase + counters; falls back to a "Starting…"
  /// placeholder for the brief preflight window.
  String _restoreProgressLine(CloudSyncService cs) {
    final p = cs.restoreProgress;
    if (cs.restoreStatus == CloudRestoreStatus.preflight) {
      return S.of('cloud.restoring.validating');
    }
    final phase = p.phase;
    if (phase == 'trips') {
      return S
          .of('cloud.restoring.trips')
          .replaceFirst('{a}', '${p.tripsInserted}')
          .replaceFirst('{b}', '${p.tripsFetched}');
    }
    if (phase == 'snapshots') {
      return S
          .of('cloud.restoring.snapshots')
          .replaceFirst('{a}', '${p.snapshotsInserted}')
          .replaceFirst('{b}', '${p.snapshotsFetched}')
          .replaceFirst('{c}', '${p.tripsInserted}');
    }
    return S.of('cloud.restoring.generic');
  }

  Color _cloudStatusColor(CloudSyncStatus s) {
    switch (s) {
      case CloudSyncStatus.idle:
        return Colors.lightGreenAccent;
      case CloudSyncStatus.syncing:
        return Colors.lightBlueAccent;
      case CloudSyncStatus.error:
      case CloudSyncStatus.authFailed:
        return Colors.redAccent;
      case CloudSyncStatus.pausedByUser:
        return Colors.amber;
      case CloudSyncStatus.disconnected:
        return Colors.grey;
    }
  }

  String _cloudStatusLabel(CloudSyncService cs) {
    switch (cs.status) {
      case CloudSyncStatus.disconnected:
        return S.of('cloud.status.not_set_up');
      case CloudSyncStatus.pausedByUser:
        return S.of('cloud.status.paused');
      case CloudSyncStatus.idle:
        return cs.stats.totalPending == 0
            ? S.of('cloud.status.up_to_date')
            : S.of('cloud.status.caught_up');
      case CloudSyncStatus.syncing:
        return S.of('cloud.status.syncing');
      case CloudSyncStatus.error:
        return S.of('cloud.status.error');
      case CloudSyncStatus.authFailed:
        return S.of('cloud.status.auth_failed');
    }
  }

  // ── v0.1.29+15: Bridge diagnostic card ────────────────────────────
  //
  // The diag service shares the client_token with CloudSyncService,
  // so its UI is minimalist: a header with status, a toggle, and a
  // small stats line. No separate setup flow — registration happens
  // inside Cloud backup.

  Widget _buildBridgeDiagHeader(BridgeDiagService bd) {
    final color = _bridgeDiagStatusColor(bd.status);
    return ListTile(
      leading: Icon(Icons.cell_tower, color: color),
      title: Text(S.of('bridge.title')),
      subtitle: Text(_bridgeDiagStatusLabel(bd)),
    );
  }

  Widget _buildBridgeDiagBody(BuildContext context, BridgeDiagService bd) {
    return Column(children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
        child: Text(
          S.of('bridge.intro'),
          style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: Colors.white60,
              ),
        ),
      ),
      SwitchListTile(
        title: Text(S.of('bridge.enable')),
        // Block the toggle if not yet registered — the long-poll loop
        // can't function without a token, and we share the token with
        // Cloud backup.
        value: bd.isEnabled,
        onChanged: bd.isRegistered
            ? (v) async {
                // If user just enabled, refresh token from secure
                // storage (CloudSyncService may have just finished
                // setup in this same app session).
                if (v) await bd.refreshTokenFromSharedStorage();
                await bd.setEnabled(v);
              }
            : null,
        secondary: const Icon(Icons.toggle_on),
      ),
      if (bd.isEnabled && bd.isRegistered) ...[
        ListTile(
          dense: true,
          leading: const Icon(Icons.assignment_turned_in,
              color: Colors.white54, size: 20),
          title: Text(
              S
                  .of('bridge.stats')
                  .replaceFirst('{a}', '${bd.stats.commandsExecuted}')
                  .replaceFirst('{b}', '${bd.stats.commandsRejected}'),
              style: const TextStyle(fontSize: 12)),
          subtitle: bd.stats.lastCommandAt != null
              ? Text(
                  S
                      .of('bridge.last')
                      .replaceFirst(
                          '{kind}', bd.stats.lastCommandKind ?? '?')
                      .replaceFirst(
                          '{when}', _relTime(bd.stats.lastCommandAt!)),
                  style: const TextStyle(fontSize: 11))
              : null,
        ),
      ],
      if (bd.lastError != null && bd.status == BridgeDiagStatus.error)
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
          child: Text(
            bd.lastError!,
            style: const TextStyle(fontSize: 11, color: Colors.redAccent),
          ),
        ),
    ]);
  }

  Color _bridgeDiagStatusColor(BridgeDiagStatus s) {
    switch (s) {
      case BridgeDiagStatus.polling:
        return Colors.lightGreenAccent;
      case BridgeDiagStatus.executing:
        return Colors.lightBlueAccent;
      case BridgeDiagStatus.error:
      case BridgeDiagStatus.authFailed:
        return Colors.redAccent;
      case BridgeDiagStatus.disabled:
      case BridgeDiagStatus.notRegistered:
        return Colors.grey;
    }
  }

  String _bridgeDiagStatusLabel(BridgeDiagService bd) {
    switch (bd.status) {
      case BridgeDiagStatus.disabled:
        return S.of('bridge.status.off');
      case BridgeDiagStatus.notRegistered:
        return S.of('bridge.status.register_first');
      case BridgeDiagStatus.polling:
        return S.of('bridge.status.listening');
      case BridgeDiagStatus.executing:
        return S.of('bridge.status.executing').replaceFirst(
            '{kind}', bd.stats.lastCommandKind ?? 'command');
      case BridgeDiagStatus.error:
        return S.of('bridge.status.error');
      case BridgeDiagStatus.authFailed:
        return S.of('bridge.status.auth_failed');
    }
  }

  String _relTime(DateTime t) {
    final diff = DateTime.now().difference(t);
    if (diff.inSeconds < 60) {
      return S.of('rel.s_ago').replaceFirst('{n}', '${diff.inSeconds}');
    }
    if (diff.inMinutes < 60) {
      return S.of('rel.m_ago').replaceFirst('{n}', '${diff.inMinutes}');
    }
    if (diff.inHours < 24) {
      return S.of('rel.h_ago').replaceFirst('{n}', '${diff.inHours}');
    }
    return S.of('rel.d_ago').replaceFirst('{n}', '${diff.inDays}');
  }

  Future<void> _showCloudSetupDialog(
      BuildContext context, CloudSyncService cs) async {
    final tokenCtrl = TextEditingController();
    final urlCtrl = TextEditingController(text: cs.baseUrl);
    // Step 1: collect setup token + (optionally) override base URL.
    final phase1 = await showDialog<Map<String, String>?>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(S.of('cloud.setup.title')),
        content: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Text(
              S.of('cloud.setup.intro'),
              style: const TextStyle(fontSize: 12),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: tokenCtrl,
              autofocus: true,
              decoration: const InputDecoration(
                labelText: 'Setup token',
                hintText: 'e.g. n0u…',
              ),
            ),
            const SizedBox(height: 8),
            ExpansionTile(
              title: Text(S.of('cloud.setup.advanced'),
                  style: const TextStyle(fontSize: 13)),
              tilePadding: EdgeInsets.zero,
              childrenPadding: EdgeInsets.zero,
              children: [
                TextField(
                  controller: urlCtrl,
                  decoration: const InputDecoration(
                    labelText: 'Bridge URL',
                    hintText: 'https://carbridge.neardo.work',
                  ),
                ),
              ],
            ),
          ]),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(null),
            child: Text(S.of('common.cancel')),
          ),
          ElevatedButton(
            onPressed: () {
              if (tokenCtrl.text.trim().isEmpty) return;
              Navigator.of(ctx).pop({
                'token': tokenCtrl.text.trim(),
                'url': urlCtrl.text.trim(),
              });
            },
            child: Text(S.of('common.continue')),
          ),
        ],
      ),
    );
    if (phase1 == null) return;
    final setupToken = phase1['token']!;
    final newUrl = phase1['url']!;

    if (newUrl.isNotEmpty && newUrl != cs.baseUrl) {
      await cs.setBaseUrl(newUrl);
    }

    // Step 2: fetch vehicle list and let user pick. Show a "loading"
    // dialog while the request is in flight.
    List<CloudVehicle>? vehicles;
    String? err;
    if (!context.mounted) return;
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => const AlertDialog(
        content: SizedBox(
          height: 60,
          child: Center(child: CircularProgressIndicator()),
        ),
      ),
    );
    try {
      vehicles = await cs.listVehiclesForSetup(setupToken);
    } catch (e) {
      err = e.toString();
    }
    if (!context.mounted) return;
    Navigator.of(context, rootNavigator: true).pop(); // dismiss loader

    if (err != null) {
      await showDialog<void>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text(S.of('cloud.setup.failed')),
          content: Text(err!),
          actions: [
            TextButton(
                onPressed: () => Navigator.of(ctx).pop(),
                child: Text(S.of('common.ok'))),
          ],
        ),
      );
      return;
    }
    if (vehicles == null || vehicles.isEmpty) {
      await showDialog<void>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text(S.of('cloud.setup.no_vehicles.title')),
          content: Text(S.of('cloud.setup.no_vehicles.body')),
        ),
      );
      return;
    }

    final picked = await showDialog<CloudVehicle>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(S.of('cloud.setup.choose_vehicle')),
        content: SizedBox(
          width: double.maxFinite,
          child: ListView(
            shrinkWrap: true,
            children: vehicles!
                .map((v) => ListTile(
                      title: Text(v.displayName),
                      subtitle: Text('${v.manufacturer} ${v.model}'
                          '${v.modelYear != null ? " ${v.modelYear}" : ""}'),
                      onTap: () => Navigator.of(ctx).pop(v),
                    ))
                .toList(),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: Text(S.of('common.cancel')),
          ),
        ],
      ),
    );
    if (picked == null) return;

    // Step 3: register. Show loader, capture error.
    if (!context.mounted) return;
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => const AlertDialog(
        content: SizedBox(
          height: 60,
          child: Center(child: CircularProgressIndicator()),
        ),
      ),
    );
    String? regErr;
    try {
      // Display name reflects this app instance — "phone" is a sensible
      // default since the user is doing setup from their phone. The
      // owner can rename via admin tools later if needed.
      await cs.registerDevice(
        setupToken: setupToken,
        vehicleId: picked.id,
        displayName: 'BZ5 companion (phone)',
        clientVersion: '0.1.28+1',
        kind: 'phone',
      );
    } catch (e) {
      regErr = e.toString();
    }
    if (!context.mounted) return;
    Navigator.of(context, rootNavigator: true).pop();

    if (regErr != null) {
      await showDialog<void>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text(S.of('cloud.setup.reg_failed')),
          content: Text(regErr!),
          actions: [
            TextButton(
                onPressed: () => Navigator.of(ctx).pop(),
                child: Text(S.of('common.ok'))),
          ],
        ),
      );
    } else {
      // v0.1.29+15: registration succeeded → notify BridgeDiagService
      // that it can now read the fresh client_token from shared
      // secure storage. The diag service starts disabled — user must
      // flip the Bridge diagnostic toggle explicitly to begin
      // polling. We refresh here so that when they do, the token is
      // already loaded into memory.
      await context.read<BridgeDiagService>()
          .refreshTokenFromSharedStorage();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
            content: Text(S
                .of('cloud.setup.connected_snack')
                .replaceFirst('{name}', picked.displayName))),
      );
    }
  }

  Future<void> _confirmAndForceResync(
      BuildContext context, CloudSyncService cs) async {
    final ok = await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: Text(S.of('cloud.resync.title')),
            content: Text(S.of('cloud.resync.body')),
            actions: [
              TextButton(
                  onPressed: () => Navigator.of(ctx).pop(false),
                  child: Text(S.of('common.cancel'))),
              ElevatedButton(
                  onPressed: () => Navigator.of(ctx).pop(true),
                  child: Text(S.of('cloud.resync.confirm'))),
            ],
          ),
        ) ??
        false;
    if (ok) {
      await cs.forceFullResync();
    }
  }

  Future<void> _confirmAndDisconnect(
      BuildContext context, CloudSyncService cs) async {
    final ok = await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: Text(S.of('cloud.disconnect.title')),
            content: Text(S.of('cloud.disconnect.body')),
            actions: [
              TextButton(
                  onPressed: () => Navigator.of(ctx).pop(false),
                  child: Text(S.of('common.cancel'))),
              TextButton(
                  style: TextButton.styleFrom(foregroundColor: Colors.red),
                  onPressed: () => Navigator.of(ctx).pop(true),
                  child: Text(S.of('cloud.disconnect.confirm'))),
            ],
          ),
        ) ??
        false;
    if (ok) {
      await cs.disconnect();
    }
  }

  /// v0.1.29+18: three-phase restore dialog.
  ///   1. Collect old client_token (TextField).
  ///   2. Probe + confirmation (token validated, warning shown).
  ///   3. Progress dialog (Consumer<CloudSyncService>) — runs the
  ///      fetch in the background while the user watches counters.
  /// User can cancel any phase. After completion, snackbar summarises.
  Future<void> _showRestoreDialog(
      BuildContext context, CloudSyncService cs) async {
    final tokenCtrl = TextEditingController();

    // Phase 1: token entry.
    final entered = await showDialog<String?>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(S.of('cloud.restore.title')),
        content: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Text(
              S.of('cloud.restore.intro'),
              style: const TextStyle(fontSize: 12),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: tokenCtrl,
              autofocus: true,
              decoration: const InputDecoration(
                labelText: 'Client token',
                hintText: 'uuid.secret',
              ),
            ),
          ]),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(null),
            child: Text(S.of('common.cancel')),
          ),
          ElevatedButton(
            onPressed: () {
              final t = tokenCtrl.text.trim();
              if (t.isEmpty) return;
              Navigator.of(ctx).pop(t);
            },
            child: Text(S.of('common.continue')),
          ),
        ],
      ),
    );
    if (entered == null) return;

    // Phase 2a: probe (with loader).
    if (!context.mounted) return;
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => const AlertDialog(
        content: SizedBox(
          height: 60,
          child: Center(child: CircularProgressIndicator()),
        ),
      ),
    );
    String? probedDeviceId;
    String? probeErr;
    try {
      probedDeviceId = await cs.probeRestoreToken(entered);
    } catch (e) {
      probeErr = e.toString();
    }
    if (!context.mounted) return;
    Navigator.of(context, rootNavigator: true).pop();

    if (probeErr != null) {
      await showDialog<void>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text(S.of('cloud.restore.rejected')),
          content: Text(probeErr!),
          actions: [
            TextButton(
                onPressed: () => Navigator.of(ctx).pop(),
                child: Text(S.of('common.ok'))),
          ],
        ),
      );
      return;
    }

    // Phase 2b: confirm + warning.
    if (!context.mounted) return;
    final confirm = await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: Text(S.of('cloud.restore.replace.title')),
            content: SingleChildScrollView(
              child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                        S.of('cloud.restore.replace.device').replaceFirst(
                            '{id}', '$probedDeviceId'),
                        style: const TextStyle(fontWeight: FontWeight.bold)),
                    const SizedBox(height: 8),
                    Text(
                      S.of('cloud.restore.replace.body'),
                      style: const TextStyle(fontSize: 12),
                    ),
                    const SizedBox(height: 8),
                    Container(
                      padding: const EdgeInsets.all(8),
                      decoration: BoxDecoration(
                        color: Colors.amber.withOpacity(0.15),
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: Text(
                        S.of('cloud.restore.replace.warning'),
                        style: const TextStyle(
                            fontSize: 12, color: Colors.amber),
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      S.of('cloud.restore.replace.note'),
                      style:
                          const TextStyle(fontSize: 11, color: Colors.grey),
                    ),
                  ]),
            ),
            actions: [
              TextButton(
                  onPressed: () => Navigator.of(ctx).pop(false),
                  child: Text(S.of('common.cancel'))),
              ElevatedButton(
                  onPressed: () => Navigator.of(ctx).pop(true),
                  child: Text(S.of('cloud.restore.confirm'))),
            ],
          ),
        ) ??
        false;
    if (!confirm) return;

    // Phase 3: launch + watch via Consumer in a dismiss-on-finish dialog.
    // Fire-and-forget; the service updates its own state and notifies.
    unawaited(cs.startRestore(oldClientToken: entered));
    if (!context.mounted) return;
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => Consumer<CloudSyncService>(
        builder: (_, watched, __) {
          final p = watched.restoreProgress;
          final st = watched.restoreStatus;
          final isDone = st == CloudRestoreStatus.done ||
              st == CloudRestoreStatus.cancelled ||
              st == CloudRestoreStatus.error ||
              st == CloudRestoreStatus.idle;
          String header;
          switch (st) {
            case CloudRestoreStatus.preflight:
              header = S.of('cloud.restore.hdr.validating');
              break;
            case CloudRestoreStatus.fetching:
              header = p.phase == 'snapshots'
                  ? S.of('cloud.restore.hdr.fetch_snapshots')
                  : S.of('cloud.restore.hdr.fetch_trips');
              break;
            case CloudRestoreStatus.done:
              header = S.of('cloud.restore.hdr.done');
              break;
            case CloudRestoreStatus.cancelled:
              header = S.of('cloud.restore.hdr.cancelled');
              break;
            case CloudRestoreStatus.error:
              header = S.of('cloud.restore.hdr.error');
              break;
            case CloudRestoreStatus.idle:
              header = S.of('cloud.restore.hdr.finished');
              break;
          }
          return AlertDialog(
            title: Text(header),
            content: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (!isDone) const LinearProgressIndicator(),
                  if (!isDone) const SizedBox(height: 12),
                  Text(
                      S
                          .of('cloud.restore.line.trips')
                          .replaceFirst('{a}', '${p.tripsInserted}')
                          .replaceFirst('{b}', '${p.tripsFetched}'),
                      style: const TextStyle(fontSize: 13)),
                  Text(
                      S
                          .of('cloud.restore.line.snapshots')
                          .replaceFirst('{a}', '${p.snapshotsInserted}')
                          .replaceFirst('{b}', '${p.snapshotsFetched}'),
                      style: const TextStyle(fontSize: 13)),
                  if (watched.restoreError != null) ...[
                    const SizedBox(height: 8),
                    Text(watched.restoreError!,
                        style: const TextStyle(
                            fontSize: 12, color: Colors.redAccent)),
                  ],
                ]),
            actions: [
              if (!isDone)
                TextButton(
                  onPressed: () => watched.cancelRestore(),
                  child: Text(S.of('common.cancel')),
                )
              else
                TextButton(
                  onPressed: () => Navigator.of(ctx).pop(),
                  child: Text(S.of('common.close')),
                ),
            ],
          );
        },
      ),
    );

    // v0.1.29+18: post-completion side effects (out of dialog so the
    // dismiss animation isn't blocked). Plane A shares the secure-
    // storage token with us; same pattern as _showCloudSetupDialog.
    // Only run on success — cancelled/error leaves Plane A on its
    // previous token (which may or may not still be valid).
    if (!context.mounted) return;
    if (cs.restoreStatus == CloudRestoreStatus.done) {
      await context
          .read<BridgeDiagService>()
          .refreshTokenFromSharedStorage();
      if (!context.mounted) return;
      final p = cs.restoreProgress;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
            content: Text(S
                .of('cloud.restore.done_snack')
                .replaceFirst('{t}', '${p.tripsInserted}')
                .replaceFirst('{s}', '${p.snapshotsInserted}'))),
      );
    }
  }

  /// v0.1.29+18: dialog for backing up the active client_token to a
  /// password manager. Token is hidden by default (bullets) with a
  /// Reveal/Hide toggle to defend against over-the-shoulder + screen
  /// recording. Copy goes through Clipboard.setData and surfaces a
  /// snackbar; the owner is expected to paste into their vault and
  /// then close.
  ///
  /// Threat model: phone is single-owner, unlocked screen → owner
  /// only. Token in clipboard sits there until the OS clears it
  /// (Android 13+: auto-clears in ~60s). Acceptable risk in exchange
  /// for removing Friend 2 from the routine reinstall loop.
  Future<void> _showBackupTokenDialog(
      BuildContext context, CloudSyncService cs) async {
    final token = cs.clientTokenForBackup;
    if (token == null) {
      // Shouldn't be reachable — button is hidden in disconnected
      // state and disabled while restoring. Defensive guard in case
      // someone wires it differently later.
      await showDialog<void>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text(S.of('cloud.token.none.title')),
          content: Text(S.of('cloud.token.none.body')),
          actions: [
            TextButton(
                onPressed: () => Navigator.of(ctx).pop(),
                child: Text(S.of('common.ok'))),
          ],
        ),
      );
      return;
    }
    await showDialog<void>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (innerCtx, setLocal) {
          bool revealed = _backupTokenRevealed;
          return AlertDialog(
            title: Text(S.of('cloud.token.title')),
            content: SingleChildScrollView(
              child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      S.of('cloud.token.intro'),
                      style: const TextStyle(fontSize: 12),
                    ),
                    const SizedBox(height: 12),
                    Container(
                      padding: const EdgeInsets.all(8),
                      decoration: BoxDecoration(
                        color: Colors.black.withOpacity(0.3),
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: SelectableText(
                        revealed ? token : '•' * token.length,
                        style: const TextStyle(
                          fontFamily: 'monospace',
                          fontSize: 12,
                        ),
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      S
                          .of('cloud.token.length')
                          .replaceFirst('{n}', '${token.length}'),
                      style:
                          const TextStyle(fontSize: 11, color: Colors.grey),
                    ),
                  ]),
            ),
            actions: [
              TextButton.icon(
                icon: Icon(
                    revealed ? Icons.visibility_off : Icons.visibility,
                    size: 18),
                label: Text(revealed
                    ? S.of('cloud.token.hide')
                    : S.of('cloud.token.reveal')),
                onPressed: () {
                  setLocal(() {
                    _backupTokenRevealed = !_backupTokenRevealed;
                  });
                },
              ),
              TextButton.icon(
                icon: const Icon(Icons.copy, size: 18),
                label: Text(S.of('cloud.token.copy')),
                onPressed: () async {
                  await Clipboard.setData(ClipboardData(text: token));
                  if (!innerCtx.mounted) return;
                  ScaffoldMessenger.of(innerCtx).showSnackBar(
                    SnackBar(
                      content: Text(S.of('cloud.token.copied')),
                      duration: const Duration(seconds: 3),
                    ),
                  );
                },
              ),
              TextButton(
                onPressed: () => Navigator.of(innerCtx).pop(),
                child: Text(S.of('common.close')),
              ),
            ],
          );
        },
      ),
    );
    // Reset reveal flag after dialog closes — don't carry state
    // into the next invocation. Each open starts hidden.
    _backupTokenRevealed = false;
  }

  /// v0.1.29+18: scratch state for the Backup token dialog's
  /// Reveal/Hide toggle. Lives on _SettingsScreenState (the dialog
  /// uses StatefulBuilder for re-render but the flag itself
  /// outlives the closure scope so we can reset it on dialog
  /// close).
  bool _backupTokenRevealed = false;

  @override
  Widget build(BuildContext context) {
    final svc = context.watch<ConnectionService>();
    // v0.1.29+58: subscribe to language changes. MaterialApp's const
    // home subtree shields this screen from top-level rebuilds, so the
    // screen watches LocaleService itself — switching the language
    // radio below re-renders every S.of() string instantly.
    final locale = context.watch<LocaleService>();
    return Scaffold(
      appBar: AppBar(title: Text(S.of('settings.title'))),
      body: ListView(
        children: [
          _StatusTile(svc: svc),
          const Divider(),

          // ════════════ Connection ════════════
          _SectionLabel(S.of('settings.section.connection')),
          ListTile(
            title: Text(S.of('settings.adapter.title')),
            subtitle: Text(
                svc.adapterAddress ?? S.of('settings.adapter.not_connected')),
          ),
          SwitchListTile(
            secondary: Icon(Icons.bluetooth_connected,
                color: _autoConnect ? Colors.lightBlueAccent : Colors.grey),
            title: Text(S.of('settings.autoconnect.title')),
            subtitle: Text(S.of('settings.autoconnect.subtitle')),
            value: _autoConnect,
            onChanged: _setAutoConnect,
          ),
          SwitchListTile(
            secondary: Icon(Icons.speed,
                color: _matchSpeedometer ? Colors.cyanAccent : Colors.grey),
            title: Text(S.of('settings.speedmatch.title')),
            subtitle: Text(S.of('settings.speedmatch.subtitle')),
            value: _matchSpeedometer,
            onChanged: _setMatchSpeedometer,
          ),
          if (svc.status != ConnectionStatus.connected) ...[
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
              child: ElevatedButton.icon(
                icon: _scanning
                    ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                    : const Icon(Icons.bluetooth_searching),
                label: Text(_scanning
                    ? S.of('settings.scan.busy')
                    : S.of('settings.scan.start')),
                onPressed: _scanning ? null : () => _scan(svc),
              ),
            ),
            if (svc.adapterAddress != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                child: OutlinedButton.icon(
                  icon: const Icon(Icons.refresh),
                  label: Text(S.of('settings.scan.reconnect_last')),
                  onPressed: _scanning
                      ? null
                      : () async {
                          setState(() => _scanning = true);
                          await svc.tryAutoConnect();
                          if (!mounted) return;
                          setState(() => _scanning = false);
                        },
                ),
              ),
            ..._devices.map((d) => _DeviceTile(result: d, onTap: () => _connect(svc, d))),
          ] else ...[
            ListTile(
              leading: const Icon(Icons.link_off, color: Colors.red),
              title: Text(S.of('settings.disconnect')),
              onTap: () => svc.disconnect(),
            ),
          ],
          const Divider(),

          // ════════════ Cost ════════════
          _SectionLabel(S.of('settings.section.cost')),
          Builder(builder: (context) {
            final cs = context.watch<CostSettings>();
            return Column(children: [
              ListTile(
                leading: const Icon(Icons.attach_money,
                    color: Colors.amber),
                title: Text(S.of('settings.cost.per_kwh.title')),
                subtitle: Text(cs.costPerKwh > 0
                    ? S.of('settings.cost.per_kwh.value').replaceFirst(
                        '{amount}', cs.formatAmount(cs.costPerKwh))
                    : S.of('settings.cost.per_kwh.unset')),
                trailing: const Icon(Icons.edit),
                onTap: () => _editCostPerKwh(context, cs),
              ),
              ListTile(
                leading: const Icon(Icons.currency_exchange,
                    color: Colors.lightGreenAccent),
                title: Text(S.of('settings.cost.currency.title')),
                subtitle: Text(S
                    .of('settings.cost.currency.value')
                    .replaceFirst('{symbol}', cs.currencySymbol)
                    .replaceFirst('{example}', cs.formatAmount(10))),
                trailing: const Icon(Icons.edit),
                onTap: () => _editCurrencySymbol(context, cs),
              ),
            ]);
          }),
          const Divider(),

          // ════════════ Cloud ════════════
          _SectionLabel(S.of('settings.section.cloud')),
          Builder(builder: (context) {
            final cs = context.watch<CloudSyncService>();
            return Column(children: [
              _buildCloudHeader(cs),
              _buildCloudBody(context, cs),
            ]);
          }),
          const Divider(),

          // ════════════ Vehicle ════════════
          _SectionLabel(S.of('settings.section.vehicle')),
          ListTile(
            leading: const Icon(Icons.medical_information,
                color: Colors.lightBlueAccent),
            title: Text(S.of('settings.dtc.title')),
            subtitle: Text(S.of('settings.dtc.subtitle')),
            trailing: const Icon(Icons.chevron_right, color: Colors.grey),
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute(
                builder: (_) => const DiagnosticsScreen(),
              ),
            ),
          ),
          ListTile(
            leading: const Icon(Icons.info_outline,
                color: Colors.lightBlueAccent),
            title: Text(S.of('settings.about.title')),
            subtitle: Text(S.of('settings.about.subtitle')),
            trailing: const Icon(Icons.chevron_right, color: Colors.grey),
            // v0.1.29+59: await the route and re-read prefs on return —
            // the About screen is where Advanced gets unlocked (15 taps
            // on the APP card), and the ExpansionTile below must appear
            // immediately when the user comes back.
            onTap: () async {
              await Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) => const AboutScreen(),
                ),
              );
              _loadSettings();
            },
          ),
          const Divider(),

          // ════════════ Язык / Language (v0.1.29+58, simplified +59) ════
          // Two explicit modes: English (default) / Русский. 'System'
          // removed in +59 (owner decision). setMode() updates S.locale
          // before notifying, and this screen watches LocaleService, so
          // the whole list re-renders in the new language on the same
          // frame the radio is tapped.
          _SectionLabel(S.of('settings.section.language')),
          RadioListTile<String>(
            dense: true,
            title: Text(S.of('settings.language.en')),
            value: 'en',
            groupValue: locale.mode,
            onChanged: (v) => locale.setMode(v!),
          ),
          RadioListTile<String>(
            dense: true,
            title: Text(S.of('settings.language.ru')),
            value: 'ru',
            groupValue: locale.mode,
            onChanged: (v) => locale.setMode(v!),
          ),
          const Divider(),

          // ════════════ Data ════════════
          _SectionLabel(S.of('settings.section.data')),
          ListTile(
            leading: const Icon(Icons.archive_outlined,
                color: Colors.lightBlueAccent),
            title: Text(S.of('settings.data.title')),
            subtitle: Text(S.of('settings.data.subtitle')),
            trailing: const Icon(Icons.chevron_right, color: Colors.grey),
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute(
                builder: (_) => const DataManagementScreen(),
              ),
            ),
          ),
          const Divider(),

          // ════════════ Advanced (research tools, hidden) ════════════
          // v0.1.29+56: research/diagnostic tooling moved here from the
          // top-level list. Nothing is deleted — these tools are needed
          // for the upcoming HAL integration work — they're just out of
          // the casual user's way. Collapsed by default.
          // v0.1.29+59: hidden entirely until unlocked via 15 taps on
          // the APP card in About (advanced_unlocked pref).
          if (_advancedUnlocked)
          ExpansionTile(
            leading: const Icon(Icons.build_outlined, color: Colors.grey),
            title: Text(S.of('settings.advanced.title')),
            subtitle: Text(S.of('settings.advanced.subtitle')),
            childrenPadding: const EdgeInsets.only(left: 8),
            children: [
              // Raw Data — wide-only research view (live DID table). On
              // phone the EcuExplorerScreen below covers the same need.
              if (LayoutBreakpoints.useHeadUnitLayout(context))
                ListTile(
                  leading: const Icon(Icons.table_rows_outlined,
                      color: Colors.grey),
                  title: const Text('Raw Data'),
                  subtitle: Text(S.of('settings.rawdata.subtitle')),
                  trailing:
                      const Icon(Icons.chevron_right, color: Colors.grey),
                  onTap: () => Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (_) => Scaffold(
                        appBar: AppBar(title: const Text('Raw Data')),
                        body: const RawDataWideScreen(),
                      ),
                    ),
                  ),
                ),
              ListTile(
                leading: const Icon(Icons.memory, color: Colors.grey),
                title: const Text('ECU Explorer'),
                subtitle: Text(S.of('settings.ecu.subtitle')),
                trailing: const Icon(Icons.chevron_right, color: Colors.grey),
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => const EcuExplorerScreen(),
                  ),
                ),
              ),
              ListTile(
                leading: const Icon(Icons.search, color: Colors.grey),
                title: const Text('DID Sweep'),
                subtitle: Text(S.of('settings.sweep.subtitle')),
                trailing: const Icon(Icons.chevron_right, color: Colors.grey),
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => const SweepScreen(),
                  ),
                ),
              ),
              ListTile(
                leading: const Icon(Icons.timeline, color: Colors.grey),
                title: const Text('Live Log'),
                subtitle: Text(S.of('settings.livelog.subtitle')),
                trailing: const Icon(Icons.chevron_right, color: Colors.grey),
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => const LiveLogScreen(),
                  ),
                ),
              ),
              ListTile(
                leading: const Icon(Icons.troubleshoot, color: Colors.grey),
                title: const Text('Polling diagnostics'),
                subtitle: Text(S.of('settings.polldiag.subtitle')),
                trailing: const Icon(Icons.chevron_right, color: Colors.grey),
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => const PollingDiagnosticsScreen(),
                  ),
                ),
              ),
              // v0.1.29+58: HAL Explorer moved here from the head-unit
              // rail (owner: research workbench, not daily-driver — hide
              // in Advanced). Unlike Raw Data this is NOT wide-gated:
              // BZ3 runs the phone layout but is still a BYD head unit,
              // so the friend needs a path to it; on real phones the
              // screen degrades to its built-in "BLE mode only" notice.
              // The route owns its NativeDetector lifecycle — see
              // _HalExplorerRoute below (on the rail the detector lived
              // in HeadUnitScaffold state, which no longer hosts the
              // screen).
              ListTile(
                leading: const Icon(Icons.api, color: Colors.grey),
                title: const Text('HAL Explorer'),
                subtitle: Text(S.of('settings.hal.subtitle')),
                trailing: const Icon(Icons.chevron_right, color: Colors.grey),
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => const _HalExplorerRoute(),
                  ),
                ),
              ),
              // v0.1.29+63: temporary HAL push-telemetry bring-up test.
              // Start/Stop the live subscription, watch registered status +
              // per-decoder value & Hz. Developer surface — removed once the
              // SPEED overlapping pilot (+64) proves the stream path.
              ListTile(
                leading: const Icon(Icons.sensors, color: Colors.grey),
                title: const Text('HAL Test'),
                subtitle: const Text('Live push-telemetry bring-up (dev)'),
                trailing: const Icon(Icons.chevron_right, color: Colors.grey),
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => const HalTestScreen(),
                  ),
                ),
              ),
              // Bridge diagnostic — cloud bridge debug telemetry.
              Builder(builder: (context) {
                final bd = context.watch<BridgeDiagService>();
                return Column(children: [
                  _buildBridgeDiagHeader(bd),
                  _buildBridgeDiagBody(context, bd),
                ]);
              }),
            ],
          ),
        ],
      ),
    );
  }

  Future<void> _scan(ConnectionService svc) async {
    setState(() {
      _scanning = true;
      _devices = [];
    });
    final found = await svc.scanForAdapters();
    setState(() {
      _devices = found;
      _scanning = false;
    });
  }

  Future<void> _connect(ConnectionService svc, ScanResult r) async {
    final ok = await svc.connect(r.device);
    if (ok && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(S.of('settings.connected_snack'))),
      );
    }
  }
}

class _StatusTile extends StatelessWidget {
  final ConnectionService svc;
  const _StatusTile({required this.svc});

  @override
  Widget build(BuildContext context) {
    final color = switch (svc.status) {
      ConnectionStatus.connected => Colors.green,
      ConnectionStatus.connecting || ConnectionStatus.scanning => Colors.orange,
      ConnectionStatus.error => Colors.red,
      _ => Colors.grey,
    };
    final icon = switch (svc.status) {
      ConnectionStatus.connected => Icons.check_circle,
      ConnectionStatus.connecting || ConnectionStatus.scanning => Icons.sync,
      ConnectionStatus.error => Icons.error,
      _ => Icons.circle_outlined,
    };

    return ListTile(
      leading: Icon(icon, color: color, size: 28),
      title: Text(svc.status.name.toUpperCase(),
          style: TextStyle(color: color, fontWeight: FontWeight.w500)),
      subtitle: Text(svc.statusMessage ?? '—'),
    );
  }
}

class _DeviceTile extends StatelessWidget {
  final ScanResult result;
  final VoidCallback onTap;

  const _DeviceTile({required this.result, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final name = result.advertisementData.advName.isEmpty
        ? '<unknown>'
        : result.advertisementData.advName;
    return ListTile(
      leading: const Icon(Icons.bluetooth, color: Colors.blue),
      title: Text(name),
      subtitle: Text('${result.device.remoteId.str}\nRSSI: ${result.rssi}'),
      isThreeLine: true,
      onTap: onTap,
    );
  }
}

/// v0.1.29+58: pushed-route host for the HAL Explorer (moved off the
/// head-unit rail into Settings → Advanced). NativeExplorerWide takes a
/// NativeDetector via constructor; when it lived on the rail the
/// detector belonged to HeadUnitScaffold's state. Here the route owns
/// the full lifecycle: create + fire-and-forget detect() in initState,
/// dispose() with the route. Each open re-probes — cheap (one
/// Class.forName + optional VIN read) and always-fresh.
class _HalExplorerRoute extends StatefulWidget {
  const _HalExplorerRoute();

  @override
  State<_HalExplorerRoute> createState() => _HalExplorerRouteState();
}

class _HalExplorerRouteState extends State<_HalExplorerRoute> {
  late final NativeDetector _detector;

  @override
  void initState() {
    super.initState();
    _detector = NativeDetector();
    _detector.detect();
  }

  @override
  void dispose() {
    _detector.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('HAL Explorer')),
      body: NativeExplorerWide(detector: _detector),
    );
  }
}

/// v0.1.29+56: section label for grouped Settings layout. Small
/// uppercase accent header above each settings group.
class _SectionLabel extends StatelessWidget {
  final String text;
  const _SectionLabel(this.text);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
      child: Text(
        text.toUpperCase(),
        style: const TextStyle(
          fontSize: 11,
          letterSpacing: 1.2,
          color: Colors.lightBlueAccent,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}
