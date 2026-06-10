import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show Clipboard, ClipboardData;
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../services/connection.dart';
import '../widgets/responsive.dart';
import '../services/cost_settings.dart';
import '../services/cloud_sync_service.dart';
import '../services/bridge_diag_service.dart';
import 'about.dart';
import 'data_management.dart';
import 'diagnostics.dart';
import 'ecu_explorer.dart';
import 'wide/raw_data_wide.dart';
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
        title: const Text('Стоимость 1 кВт·ч'),
        content: TextField(
          controller: ctrl,
          keyboardType:
              const TextInputType.numberWithOptions(decimal: true),
          autofocus: true,
          decoration: InputDecoration(
            labelText: 'Цена',
            hintText: 'Например: 5.50',
            helperText:
                'В вашей валюте (символ — ниже в настройках). '
                '0 = выключить отображение стоимости.',
            suffixText: cs.currencySymbol,
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(null),
            child: const Text('Отмена'),
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
            child: const Text('Сохранить'),
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
        title: const Text('Символ валюты'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(
              controller: ctrl,
              autofocus: true,
              maxLength: 4,
              decoration: const InputDecoration(
                labelText: 'Символ',
                hintText: '\$, €, ₽, ¥, RUB, USD...',
              ),
            ),
            const SizedBox(height: 4),
            const Text('Быстрый выбор:',
                style: TextStyle(fontSize: 12, color: Colors.grey)),
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
            child: const Text('Отмена'),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(ctrl.text),
            child: const Text('Сохранить'),
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
      title: const Text('Cloud backup'),
      subtitle: Text(_cloudStatusLabel(cs)),
    );
  }

  Widget _buildCloudBody(BuildContext context, CloudSyncService cs) {
    if (!cs.isInitialized) {
      return const Padding(
        padding: EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        child: Text('Loading…', style: TextStyle(color: Colors.grey)),
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
          const Text(
            'Save trip history and BMS snapshots to the bz5-bridge so '
            'they survive head-unit reinstalls. Setup needs a token '
            'from the bridge owner; Restore needs the previous '
            'device\'s client_token.',
            style: TextStyle(fontSize: 12, color: Colors.grey),
          ),
          const SizedBox(height: 8),
          ElevatedButton.icon(
            icon: const Icon(Icons.cloud_sync),
            label: const Text('Set up cloud backup'),
            onPressed: cs.isRestoring
                ? null
                : () => _showCloudSetupDialog(context, cs),
          ),
          const SizedBox(height: 6),
          OutlinedButton.icon(
            icon: const Icon(Icons.cloud_download_outlined),
            label: const Text('Restore from cloud'),
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
                'Last restore: ${cs.restoreError!}',
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
          title: const Text('Enabled'),
          subtitle: Text(cs.vehicleName ?? '(unknown vehicle)'),
          value: cs.enabled,
          onChanged: (v) => cs.setEnabled(v),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            if (cs.lastSuccessAt != null)
              Text('Last sync: ${_relTime(cs.lastSuccessAt!)}',
                  style: const TextStyle(fontSize: 12, color: Colors.grey))
            else
              const Text('Last sync: never',
                  style: TextStyle(fontSize: 12, color: Colors.grey)),
            if (cs.stats.totalPending > 0)
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Text(
                  'Pending: ${cs.stats.pendingTrips} trips, '
                  '${cs.stats.pendingSnapshots} snapshots, '
                  '${cs.stats.pendingSweeps} sweeps, '
                  '${cs.stats.pendingLiveLogs} live-logs',
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
                  'Last restore: ${_relTime(cs.lastRestoreAt!)}',
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
                  'Last restore: ${cs.restoreError!}',
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
              label: const Text('Sync now'),
              onPressed: cs.status == CloudSyncStatus.syncing || cs.isRestoring
                  ? null
                  : () => cs.syncOnce(reason: 'manual-button'),
            ),
            OutlinedButton.icon(
              icon: const Icon(Icons.replay, size: 18),
              label: const Text('Force full resync'),
              onPressed: cs.status == CloudSyncStatus.syncing || cs.isRestoring
                  ? null
                  : () => _confirmAndForceResync(context, cs),
            ),
            OutlinedButton.icon(
              icon: const Icon(Icons.cloud_download_outlined, size: 18),
              label: const Text('Restore from cloud'),
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
              label: const Text('Backup token'),
              onPressed: cs.isRestoring
                  ? null
                  : () => _showBackupTokenDialog(context, cs),
            ),
            OutlinedButton.icon(
              icon: const Icon(Icons.link_off, size: 18),
              label: const Text('Disconnect'),
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
      return 'Restoring: validating token…';
    }
    final phase = p.phase;
    if (phase == 'trips') {
      return 'Restoring trips: '
          '${p.tripsInserted} new / ${p.tripsFetched} fetched';
    }
    if (phase == 'snapshots') {
      return 'Restoring snapshots: '
          '${p.snapshotsInserted} new / ${p.snapshotsFetched} fetched '
          '(trips: ${p.tripsInserted})';
    }
    return 'Restoring…';
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
        return 'Not set up';
      case CloudSyncStatus.pausedByUser:
        return 'Paused';
      case CloudSyncStatus.idle:
        return cs.stats.totalPending == 0 ? 'Up to date' : 'Caught up, scheduled';
      case CloudSyncStatus.syncing:
        return 'Syncing…';
      case CloudSyncStatus.error:
        return 'Error — retrying';
      case CloudSyncStatus.authFailed:
        return 'Auth failed — re-register required';
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
      title: const Text('Bridge diagnostic'),
      subtitle: Text(_bridgeDiagStatusLabel(bd)),
    );
  }

  Widget _buildBridgeDiagBody(BuildContext context, BridgeDiagService bd) {
    return Column(children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
        child: Text(
          'Allows the bridge owner to push diagnostic commands to this '
          'device for sweep / live-log / native probe sessions. Uses the '
          'same registration as Cloud backup above — set that up first. '
          'Off by default.',
          style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: Colors.white60,
              ),
        ),
      ),
      SwitchListTile(
        title: const Text('Enable bridge diagnostic'),
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
              'Executed: ${bd.stats.commandsExecuted}'
              '  ·  Rejected: ${bd.stats.commandsRejected}',
              style: const TextStyle(fontSize: 12)),
          subtitle: bd.stats.lastCommandAt != null
              ? Text(
                  'Last: ${bd.stats.lastCommandKind ?? "?"} '
                  '(${_relTime(bd.stats.lastCommandAt!)})',
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
        return 'Off';
      case BridgeDiagStatus.notRegistered:
        return 'Register via Cloud backup first';
      case BridgeDiagStatus.polling:
        return 'Listening for commands';
      case BridgeDiagStatus.executing:
        return 'Executing ${bd.stats.lastCommandKind ?? "command"}…';
      case BridgeDiagStatus.error:
        return 'Error — retrying';
      case BridgeDiagStatus.authFailed:
        return 'Auth failed — re-register via Cloud backup';
    }
  }

  String _relTime(DateTime t) {
    final diff = DateTime.now().difference(t);
    if (diff.inSeconds < 60) return '${diff.inSeconds}s ago';
    if (diff.inMinutes < 60) return '${diff.inMinutes}m ago';
    if (diff.inHours < 24) return '${diff.inHours}h ago';
    return '${diff.inDays}d ago';
  }

  Future<void> _showCloudSetupDialog(
      BuildContext context, CloudSyncService cs) async {
    final tokenCtrl = TextEditingController();
    final urlCtrl = TextEditingController(text: cs.baseUrl);
    // Step 1: collect setup token + (optionally) override base URL.
    final phase1 = await showDialog<Map<String, String>?>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Cloud backup — Setup'),
        content: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            const Text(
              'Enter the setup token provided by the bridge owner. '
              'This token can only be used once; the owner will need '
              'to reissue it if you re-register later.',
              style: TextStyle(fontSize: 12),
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
              title: const Text('Advanced', style: TextStyle(fontSize: 13)),
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
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () {
              if (tokenCtrl.text.trim().isEmpty) return;
              Navigator.of(ctx).pop({
                'token': tokenCtrl.text.trim(),
                'url': urlCtrl.text.trim(),
              });
            },
            child: const Text('Continue'),
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
          title: const Text('Setup failed'),
          content: Text(err!),
          actions: [
            TextButton(
                onPressed: () => Navigator.of(ctx).pop(),
                child: const Text('OK')),
          ],
        ),
      );
      return;
    }
    if (vehicles == null || vehicles.isEmpty) {
      await showDialog<void>(
        context: context,
        builder: (ctx) => const AlertDialog(
          title: Text('No vehicles'),
          content: Text(
              'The bridge has no vehicles configured. Ask the owner to seed one.'),
        ),
      );
      return;
    }

    final picked = await showDialog<CloudVehicle>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Choose vehicle'),
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
            child: const Text('Cancel'),
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
          title: const Text('Registration failed'),
          content: Text(regErr!),
          actions: [
            TextButton(
                onPressed: () => Navigator.of(ctx).pop(),
                child: const Text('OK')),
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
            content: Text('Connected to ${picked.displayName}. '
                'First sync will run in the background.')),
      );
    }
  }

  Future<void> _confirmAndForceResync(
      BuildContext context, CloudSyncService cs) async {
    final ok = await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: const Text('Force full resync?'),
            content: const Text(
                'This re-uploads every trip, snapshot, sweep and live-log '
                'from local DB. The bridge will dedupe — old records '
                'already on the server are not duplicated. Useful after '
                'a Drift restore. May take a few minutes.'),
            actions: [
              TextButton(
                  onPressed: () => Navigator.of(ctx).pop(false),
                  child: const Text('Cancel')),
              ElevatedButton(
                  onPressed: () => Navigator.of(ctx).pop(true),
                  child: const Text('Force resync')),
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
            title: const Text('Disconnect from bridge?'),
            content: const Text(
                'This removes the saved client token. Local Drift data '
                'stays intact. To re-enable you will need a fresh setup '
                'token from the bridge owner.'),
            actions: [
              TextButton(
                  onPressed: () => Navigator.of(ctx).pop(false),
                  child: const Text('Cancel')),
              TextButton(
                  style: TextButton.styleFrom(foregroundColor: Colors.red),
                  onPressed: () => Navigator.of(ctx).pop(true),
                  child: const Text('Disconnect')),
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
        title: const Text('Restore from cloud'),
        content: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            const Text(
              'Paste the previous device\'s client_token. The bridge '
              'owner can look this up server-side; it has the form '
              '<device_id>.<secret>. This will REPLACE the current '
              'cloud identity — pushes resume under the restored '
              'device.',
              style: TextStyle(fontSize: 12),
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
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () {
              final t = tokenCtrl.text.trim();
              if (t.isEmpty) return;
              Navigator.of(ctx).pop(t);
            },
            child: const Text('Continue'),
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
          title: const Text('Token rejected'),
          content: Text(probeErr!),
          actions: [
            TextButton(
                onPressed: () => Navigator.of(ctx).pop(),
                child: const Text('OK')),
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
            title: const Text('Replace cloud identity?'),
            content: SingleChildScrollView(
              child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Device: $probedDeviceId',
                        style: const TextStyle(fontWeight: FontWeight.bold)),
                    const SizedBox(height: 8),
                    const Text(
                      'After confirmation:\n'
                      '  • current token is replaced (current registration '
                      'becomes an orphan on the server — ask owner to revoke '
                      'if desired)\n'
                      '  • trips + snapshots are pulled into local Drift '
                      'with dedup\n'
                      '  • push cursors advance past max local id so '
                      'restored rows are not re-uploaded',
                      style: TextStyle(fontSize: 12),
                    ),
                    const SizedBox(height: 8),
                    Container(
                      padding: const EdgeInsets.all(8),
                      decoration: BoxDecoration(
                        color: Colors.amber.withOpacity(0.15),
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: const Text(
                        'If you have driven any trips on this install '
                        'since reinstalling the app, those local records '
                        'will stay in the app but will NOT be uploaded '
                        'under the restored identity. (To avoid this, '
                        'restore immediately after reinstall.)',
                        style:
                            TextStyle(fontSize: 12, color: Colors.amber),
                      ),
                    ),
                    const SizedBox(height: 8),
                    const Text(
                      'Sweeps and live-log sessions are NOT restored in '
                      'this version — they remain accessible only via '
                      'admin inspection on the bridge.',
                      style: TextStyle(fontSize: 11, color: Colors.grey),
                    ),
                  ]),
            ),
            actions: [
              TextButton(
                  onPressed: () => Navigator.of(ctx).pop(false),
                  child: const Text('Cancel')),
              ElevatedButton(
                  onPressed: () => Navigator.of(ctx).pop(true),
                  child: const Text('Restore')),
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
              header = 'Validating token…';
              break;
            case CloudRestoreStatus.fetching:
              header = p.phase == 'snapshots'
                  ? 'Fetching snapshots…'
                  : 'Fetching trips…';
              break;
            case CloudRestoreStatus.done:
              header = 'Restore complete';
              break;
            case CloudRestoreStatus.cancelled:
              header = 'Restore cancelled';
              break;
            case CloudRestoreStatus.error:
              header = 'Restore failed';
              break;
            case CloudRestoreStatus.idle:
              header = 'Restore finished';
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
                      'Trips: ${p.tripsInserted} new / ${p.tripsFetched} fetched',
                      style: const TextStyle(fontSize: 13)),
                  Text(
                      'Snapshots: ${p.snapshotsInserted} new / ${p.snapshotsFetched} fetched',
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
                  child: const Text('Cancel'),
                )
              else
                TextButton(
                  onPressed: () => Navigator.of(ctx).pop(),
                  child: const Text('Close'),
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
            content: Text(
                'Restore complete: ${p.tripsInserted} trips, '
                '${p.snapshotsInserted} snapshots inserted. '
                'Cloud sync resumed.')),
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
          title: const Text('No token to back up'),
          content: const Text(
              'There is no active client token in secure storage. '
              'Run Setup or Restore first.'),
          actions: [
            TextButton(
                onPressed: () => Navigator.of(ctx).pop(),
                child: const Text('OK')),
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
            title: const Text('Backup client token'),
            content: SingleChildScrollView(
              child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'Save this token in a password manager. '
                      'The server cannot recover it (sha256-hashed) — '
                      'you\'ll need it to Restore after a head-unit '
                      'reinstall.',
                      style: TextStyle(fontSize: 12),
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
                      'Length: ${token.length} chars',
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
                label: Text(revealed ? 'Hide' : 'Reveal'),
                onPressed: () {
                  setLocal(() {
                    _backupTokenRevealed = !_backupTokenRevealed;
                  });
                },
              ),
              TextButton.icon(
                icon: const Icon(Icons.copy, size: 18),
                label: const Text('Copy'),
                onPressed: () async {
                  await Clipboard.setData(ClipboardData(text: token));
                  if (!innerCtx.mounted) return;
                  ScaffoldMessenger.of(innerCtx).showSnackBar(
                    const SnackBar(
                      content: Text('Token copied to clipboard'),
                      duration: Duration(seconds: 3),
                    ),
                  );
                },
              ),
              TextButton(
                onPressed: () => Navigator.of(innerCtx).pop(),
                child: const Text('Close'),
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
    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: ListView(
        children: [
          _StatusTile(svc: svc),
          const Divider(),

          // ════════════ Подключение ════════════
          const _SectionLabel('Подключение'),
          ListTile(
            title: const Text('ELM327 BLE adapter'),
            subtitle: Text(svc.adapterAddress ?? 'Не подключен'),
          ),
          SwitchListTile(
            secondary: Icon(Icons.bluetooth_connected,
                color: _autoConnect ? Colors.lightBlueAccent : Colors.grey),
            title: const Text('Auto-connect at startup'),
            subtitle: const Text(
                'Подключаться к запомненному адаптеру при запуске приложения'),
            value: _autoConnect,
            onChanged: _setAutoConnect,
          ),
          SwitchListTile(
            secondary: Icon(Icons.speed,
                color: _matchSpeedometer ? Colors.cyanAccent : Colors.grey),
            title: const Text('Speed match speedometer (+5%)'),
            subtitle: const Text(
                'Показывать скорость как на штатной приборке '
                '(приборка по закону UN R39 завышает на ~5%)'),
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
                label: Text(_scanning ? 'Поиск...' : 'Найти адаптер'),
                onPressed: _scanning ? null : () => _scan(svc),
              ),
            ),
            if (svc.adapterAddress != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                child: OutlinedButton.icon(
                  icon: const Icon(Icons.refresh),
                  label: const Text('Подключиться к последнему адаптеру'),
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
              title: const Text('Disconnect'),
              onTap: () => svc.disconnect(),
            ),
          ],
          const Divider(),

          // ════════════ Стоимость ════════════
          const _SectionLabel('Стоимость'),
          Builder(builder: (context) {
            final cs = context.watch<CostSettings>();
            return Column(children: [
              ListTile(
                leading: const Icon(Icons.attach_money,
                    color: Colors.amber),
                title: const Text('Cost per kWh'),
                subtitle: Text(cs.costPerKwh > 0
                    ? '${cs.formatAmount(cs.costPerKwh)} за 1 кВт·ч'
                    : 'Не настроено — стоимость поездки не показывается'),
                trailing: const Icon(Icons.edit),
                onTap: () => _editCostPerKwh(context, cs),
              ),
              ListTile(
                leading: const Icon(Icons.currency_exchange,
                    color: Colors.lightGreenAccent),
                title: const Text('Currency symbol'),
                subtitle: Text(
                    'Текущий: "${cs.currencySymbol}" '
                    '(пример: ${cs.formatAmount(10)})'),
                trailing: const Icon(Icons.edit),
                onTap: () => _editCurrencySymbol(context, cs),
              ),
            ]);
          }),
          const Divider(),

          // ════════════ Облако ════════════
          const _SectionLabel('Облако'),
          Builder(builder: (context) {
            final cs = context.watch<CloudSyncService>();
            return Column(children: [
              _buildCloudHeader(cs),
              _buildCloudBody(context, cs),
            ]);
          }),
          const Divider(),

          // ════════════ Автомобиль ════════════
          const _SectionLabel('Автомобиль'),
          ListTile(
            leading: const Icon(Icons.medical_information,
                color: Colors.lightBlueAccent),
            title: const Text('Diagnostics (DTC)'),
            subtitle: const Text(
                'Считать коды ошибок со всех ECU (read-only)'),
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
            title: const Text('About / Pack specification'),
            subtitle: const Text(
                'BZ5 battery pack details, DID sources, experiments'),
            trailing: const Icon(Icons.chevron_right, color: Colors.grey),
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute(
                builder: (_) => const AboutScreen(),
              ),
            ),
          ),
          const Divider(),

          // ════════════ Данные ════════════
          const _SectionLabel('Данные'),
          ListTile(
            leading: const Icon(Icons.archive_outlined,
                color: Colors.lightBlueAccent),
            title: const Text('Data & Export'),
            subtitle: const Text(
                'Экспорт trips/snapshots/samples на флешку или в облако, очистка'),
            trailing: const Icon(Icons.chevron_right, color: Colors.grey),
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute(
                builder: (_) => const DataManagementScreen(),
              ),
            ),
          ),
          const Divider(),

          // ════════════ Advanced (research tools, collapsed) ════════════
          // v0.1.29+56: research/diagnostic tooling moved here from the
          // top-level list. Nothing is deleted — these tools are needed
          // for the upcoming HAL integration work — they're just out of
          // the casual user's way. Collapsed by default.
          ExpansionTile(
            leading: const Icon(Icons.build_outlined, color: Colors.grey),
            title: const Text('Advanced'),
            subtitle: const Text(
                'Инструменты исследования и диагностики приложения'),
            childrenPadding: const EdgeInsets.only(left: 8),
            children: [
              // Raw Data — wide-only research view (live DID table). On
              // phone the EcuExplorerScreen below covers the same need.
              if (LayoutBreakpoints.useHeadUnitLayout(context))
                ListTile(
                  leading: const Icon(Icons.table_rows_outlined,
                      color: Colors.grey),
                  title: const Text('Raw Data'),
                  subtitle: const Text(
                      'Live DID таблица + diagnostics sweep (wide view)'),
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
                subtitle: const Text('Реестр DID со всех ECU, live значения'),
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
                subtitle: const Text(
                    'In-car ECU probe — presets и custom диапазоны'),
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
                subtitle: const Text(
                    'Time-series polling до 7 DIDs одновременно'),
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
                subtitle: const Text(
                    'Pack current read counters, gaps, null rate'),
                trailing: const Icon(Icons.chevron_right, color: Colors.grey),
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => const PollingDiagnosticsScreen(),
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
        const SnackBar(content: Text('Подключено! Перейдите на Dashboard')),
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
