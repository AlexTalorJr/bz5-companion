import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../services/connection.dart';
import '../services/cost_settings.dart';
import '../services/cloud_sync_service.dart';
import 'about.dart';
import 'data_management.dart';
import 'diagnostics.dart';
import 'live_log.dart';
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
      // Disconnected. Show a button to start setup.
      return Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          const Text(
            'Save trip history and BMS snapshots to the bz5-bridge so '
            'they survive head-unit reinstalls. Setup needs a token '
            'from the bridge owner.',
            style: TextStyle(fontSize: 12, color: Colors.grey),
          ),
          const SizedBox(height: 8),
          ElevatedButton.icon(
            icon: const Icon(Icons.cloud_sync),
            label: const Text('Set up cloud backup'),
            onPressed: () => _showCloudSetupDialog(context, cs),
          ),
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
          ]),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
          child: Wrap(spacing: 8, runSpacing: 4, children: [
            OutlinedButton.icon(
              icon: const Icon(Icons.refresh, size: 18),
              label: const Text('Sync now'),
              onPressed: cs.status == CloudSyncStatus.syncing
                  ? null
                  : () => cs.syncOnce(reason: 'manual-button'),
            ),
            OutlinedButton.icon(
              icon: const Icon(Icons.replay, size: 18),
              label: const Text('Force full resync'),
              onPressed: cs.status == CloudSyncStatus.syncing
                  ? null
                  : () => _confirmAndForceResync(context, cs),
            ),
            OutlinedButton.icon(
              icon: const Icon(Icons.link_off, size: 18),
              label: const Text('Disconnect'),
              onPressed: () => _confirmAndDisconnect(context, cs),
            ),
          ]),
        ),
      ]),
    );
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

  @override
  Widget build(BuildContext context) {
    final svc = context.watch<ConnectionService>();
    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: ListView(
        children: [
          _StatusTile(svc: svc),
          const Divider(),
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
          // v0.1.24: match-speedometer toggle. Default OFF (show true
          // wheel speed). When ON, Driver view multiplies displayed
          // speed by 1.05 so the number matches what the analog/digital
          // speedometer reads. Useful for drivers who glance between
          // both displays and want one consistent reading.
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
          // v0.1.27: trip cost. Two soft-settings:
          //   * cost_per_kwh — number in user's currency units.
          //     Default 0 means "not configured" and hides cost
          //     displays everywhere in the UI.
          //   * currency_symbol — short string ($, €, ₽, RUB, etc).
          //
          // Both live in CostSettings (services/cost_settings.dart),
          // a ChangeNotifier registered via Provider in main.dart.
          // Driver view and trip_detail listen via context.watch and
          // rebuild reactively when the user edits these values.
          //
          // No DB schema change: cost is computed on the fly from
          // trip.energyUsedKwh × costPerKwh at display time. Changing
          // the tariff re-prices all historical trips at the new rate
          // (acceptable for a single-owner app; if multi-tariff
          // history becomes a requirement that's a separate patch).
          Builder(builder: (context) {
            final cs = context.watch<CostSettings>();
            return Column(children: [
              const Divider(),
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
          // v0.1.28: cloud backup card. Builder isolates the watch
          // call so only this section rebuilds when sync status
          // changes. UI-only; all logic lives in CloudSyncService.
          Builder(builder: (context) {
            final cs = context.watch<CloudSyncService>();
            return Column(children: [
              const Divider(),
              _buildCloudHeader(cs),
              _buildCloudBody(context, cs),
            ]);
          }),
          const Divider(),
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
            // Manual reconnect to last adapter — useful when auto-connect
            // failed at startup (adapter was sleeping etc) and user wants
            // to retry without scanning the whole BLE neighbourhood.
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
            leading: const Icon(Icons.search,
                color: Colors.lightBlueAccent),
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
            leading: const Icon(Icons.timeline,
                color: Colors.lightBlueAccent),
            title: const Text('Live Log'),
            subtitle: const Text(
                'Time-series polling до 7 DIDs одновременно (для reverse engineering)'),
            trailing: const Icon(Icons.chevron_right, color: Colors.grey),
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute(
                builder: (_) => const LiveLogScreen(),
              ),
            ),
          ),
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
