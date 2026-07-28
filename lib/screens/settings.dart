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
import '../services/account_auth_service.dart';
import '../services/cloud_sync_service.dart';
import '../services/bridge_diag_service.dart';
import '../services/speed_profile_service.dart';
import 'about.dart';
import 'data_management.dart';
import 'diagnostics.dart';
import 'status.dart';
import '../services/hal_telemetry_service.dart';
import 'ecu_explorer.dart';
import 'account.dart';
import 'app_diag.dart';
import 'pairing.dart';
import 'hal_test.dart';
import 'install_update.dart';
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
      _advancedUnlocked = prefs.getBool('advanced_unlocked') ?? false;
    });
  }

  Future<void> _setAutoConnect(bool v) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('auto_connect_enabled', v);
    if (!mounted) return;
    setState(() => _autoConnect = v);
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

  // ── v0.1.29+110: user-friendly settings restructure (spec B2/О1) ──
  //
  // Groups are self-contained cards; the connection plaque spans the
  // full width on every form factor. Wide landscape head unit (BZ5,
  // LayoutBreakpoints.useHeadUnitLayout) lays the group cards out in
  // TWO columns (left: Connection + Vehicle, right: Cost + App);
  // narrow form factors (BZ3 portrait 720×1106, phone) keep a single
  // column. Card INTERNALS are identical across form factors — only
  // the container column count changes. Cards size to content — no
  // vertical flex stretching, so the columns never tear a card.

  Widget _groupCard(List<Widget> children) => Card(
        margin: const EdgeInsets.fromLTRB(12, 6, 12, 6),
        clipBehavior: Clip.antiAlias,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: children,
        ),
      );

  List<Widget> _connectionGroup(BuildContext context, ConnectionService svc) {
    return [
      _SectionLabel(S.of('settings.section.connection')),
      SwitchListTile(
        secondary: Icon(Icons.bluetooth_connected,
            color: _autoConnect ? Colors.lightBlueAccent : Colors.grey),
        title: Text(S.of('settings.autoconnect.title')),
        subtitle: Text(S.of('settings.autoconnect.subtitle')),
        value: _autoConnect,
        onChanged: _setAutoConnect,
      ),
      // v0.1.29+64: data-source selector. v0.1.29+74: DISCRETE choice
      // — HAL or OBD2 only (Auto removed from the UI). Each mode is a
      // complete interface: overlapping core stays in place (held +
      // dimmed when stale), mode-specific params fill the rest. The
      // 'auto' enum value is kept internally as a back-compat net for
      // any persisted 'auto' pref but is no longer offered here.
      // v0.1.29+110: visible labels are plain-language now ("From the
      // car" / "Through the adapter") — l10n values only; the
      // HalSourceMode enum and setMode behaviour are untouched.
      Builder(builder: (context) {
        final hal = context.watch<HalTelemetryService>();
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            ListTile(
              leading: const Icon(Icons.cable, color: Colors.grey),
              title: Text(S.of('settings.datasource.title')),
              subtitle: Text(
                // v0.1.29+83: three states. No HAL platform (phone) →
                // explain OBD2-only. HAL selected but stream dead →
                // unavailable. Otherwise the normal subtitle.
                !hal.canUseHal
                    ? S.of('settings.datasource.hal_no_platform')
                    : hal.mode == HalSourceMode.halOnly && !hal.running
                        ? S.of('settings.datasource.hal_unavailable')
                        : S.of('settings.datasource.subtitle'),
              ),
            ),
            // v0.1.29+83: HAL radio only on a real head unit. On a phone
            // the BYD framework is absent, so halOnly is not offered and
            // OBD2 is the sole choice (forced in init() too).
            if (hal.canUseHal)
              RadioListTile<HalSourceMode>(
                dense: true,
                title: Text(S.of('settings.datasource.hal')),
                value: HalSourceMode.halOnly,
                groupValue: hal.mode,
                onChanged: (m) => hal.setMode(m!),
              ),
            RadioListTile<HalSourceMode>(
              dense: true,
              title: Text(S.of('settings.datasource.obd2')),
              value: HalSourceMode.obd2Only,
              groupValue: hal.mode,
              onChanged: (m) => hal.setMode(m!),
            ),
          ],
        );
      }),
      // v0.1.32+131: user-selectable SOC source. Plain-language options
      // ("Same as the car" / "Exact, from the battery") — the words SOC /
      // BMS / display never surface. Same visual pattern as the data
      // source block above; applies live via HalTelemetryService
      // notifyListeners (no restart). On a dongle-only setup the cluster
      // figure does not exist in UDS — the subtitle says so and the
      // resolver falls back to the exact value either way.
      Builder(builder: (context) {
        final hal = context.watch<HalTelemetryService>();
        // v0.1.42+141: on a CONFIRMED phone the setting is gone (Alex,
        // 14.07). Over a dongle the cluster figure does not exist in
        // UDS — "Same as the car" silently degraded to a rounded
        // precise value, so both options fed one source and the choice
        // was noise. The resolver force-returns precise there (see
        // soc_resolver.dart); head units (BZ5/BZ3) keep the setting.
        // Probe discipline mirrors the +139 stale gate: canUseHal alone
        // reads false on a cold-starting BZ3 too — hide only once the
        // platform probe has settled, never flicker the block away on
        // a warming head unit.
        if (hal.platformProbed && !hal.canUseHal) {
          return const SizedBox.shrink();
        }
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            ListTile(
              leading:
                  const Icon(Icons.battery_std_outlined, color: Colors.grey),
              title: Text(S.of('settings.socsource.title')),
              subtitle: Text(
                !hal.canUseHal
                    ? S.of('settings.socsource.subtitle_obd2')
                    : S.of('settings.socsource.subtitle'),
              ),
            ),
            RadioListTile<SocSource>(
              dense: true,
              title: Text(S.of('settings.socsource.display')),
              subtitle: Text(S.of('settings.socsource.display_sub')),
              value: SocSource.display,
              groupValue: hal.socSource,
              onChanged: (s) => hal.setSocSource(s!),
            ),
            RadioListTile<SocSource>(
              dense: true,
              title: Text(S.of('settings.socsource.precise')),
              subtitle: Text(S.of('settings.socsource.precise_sub')),
              value: SocSource.precise,
              groupValue: hal.socSource,
              onChanged: (s) => hal.setSocSource(s!),
            ),
          ],
        );
      }),
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
    ];
  }

  List<Widget> _vehicleGroup(BuildContext context, HalTelemetryService hal) {
    return [
      _SectionLabel(S.of('settings.section.vehicle')),
      // v0.1.29+100: Status screen (car_status provider — health /
      // maintenance / fluids). Head-unit only: the provider does not
      // exist on a phone, so the tile is hidden there (canUseHal is the
      // same "on the HU?" signal HAL gates on). No dongle required.
      if (hal.canUseHal)
        ListTile(
          leading: const Icon(Icons.health_and_safety,
              color: Colors.greenAccent),
          title: Text(S.of('status.title')),
          subtitle: Text(S.of('status.subtitle')),
          trailing: const Icon(Icons.chevron_right, color: Colors.grey),
          onTap: () => Navigator.of(context).push(
            MaterialPageRoute(
              builder: (_) => const StatusScreen(),
            ),
          ),
        ),
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
        // immediately when the user comes back. The build version is
        // shown inside (kAppVersion, +94).
        onTap: () async {
          await Navigator.of(context).push(
            MaterialPageRoute(
              builder: (_) => const AboutScreen(),
            ),
          );
          _loadSettings();
        },
      ),
    ];
  }

  List<Widget> _costGroup(BuildContext context) {
    return [
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
    ];
  }

  List<Widget> _appGroup(BuildContext context, LocaleService locale) {
    return [
      _SectionLabel(S.of('settings.section.app')),
      // Язык / Language — compact entry with the current language on
      // the row; the two radios live in a dialog (the +58/+59 setMode
      // contract is unchanged: exactly two explicit modes).
      ListTile(
        leading: const Icon(Icons.language, color: Colors.lightBlueAccent),
        title: Text(S.of('settings.section.language')),
        subtitle: Text(locale.mode == 'ru'
            ? S.of('settings.language.ru')
            : S.of('settings.language.en')),
        trailing: const Icon(Icons.chevron_right, color: Colors.grey),
        onTap: () => _showLanguageDialog(context, locale),
      ),
      // v0.1.29+110 (О1): Cloud services › — the whole cloud block now
      // lives on its own sub-screen; this row shows a live 4-state
      // summary (see _cloudMenuLabel). Watching CloudSyncService here
      // keeps the row updating without entering the sub-screen.
      Builder(builder: (context) {
        final cs = context.watch<CloudSyncService>();
        return ListTile(
          leading: Icon(Icons.cloud_outlined, color: _cloudMenuColor(cs)),
          title: Text(S.of('settings.cloud_services.title')),
          subtitle: Text(_cloudMenuLabel(cs),
              style: TextStyle(color: _cloudMenuColor(cs))),
          trailing: const Icon(Icons.chevron_right, color: Colors.grey),
          onTap: () => Navigator.of(context).push(
            MaterialPageRoute(
              builder: (_) => const CloudServicesScreen(),
            ),
          ),
        );
      }),
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
    ];
  }

  Future<void> _showLanguageDialog(
      BuildContext context, LocaleService locale) async {
    await showDialog<void>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: Text(S.of('settings.section.language')),
        children: [
          RadioListTile<String>(
            dense: true,
            title: Text(S.of('settings.language.en')),
            value: 'en',
            groupValue: locale.mode,
            onChanged: (v) {
              locale.setMode(v!);
              Navigator.of(ctx).pop();
            },
          ),
          RadioListTile<String>(
            dense: true,
            title: Text(S.of('settings.language.ru')),
            value: 'ru',
            groupValue: locale.mode,
            onChanged: (v) {
              locale.setMode(v!);
              Navigator.of(ctx).pop();
            },
          ),
        ],
      ),
    );
  }

  // v0.1.29+110: 4-state cloud summary for the Settings menu row —
  // the sensible collapse of the six internal CloudSyncStatus values.
  // Each state maps to a DIFFERENT user action: nothing / sign in
  // again / switch back on / set up. Order of checks matters; a
  // registered device is never left on `disconnected` by
  // _recomputeStatus (verified: cloud_sync_service.dart), so a
  // transient `disconnected` while registered reads as connected.
  Color _cloudMenuColor(CloudSyncService cs) {
    if (!cs.isRegistered) return Colors.grey;
    switch (cs.status) {
      case CloudSyncStatus.authFailed:
      case CloudSyncStatus.error:
      case CloudSyncStatus.pausedByUser:
      // v0.1.34+133: approval gate — pending with the paused group,
      // denied with the auth/error group; menu row is amber for both.
      case CloudSyncStatus.pendingApproval:
      case CloudSyncStatus.accessDenied:
        return Colors.amber;
      default: // idle | syncing | transient disconnected
        return Colors.lightGreenAccent;
    }
  }

  String _cloudMenuLabel(CloudSyncService cs) {
    if (!cs.isRegistered) return S.of('cloud.menu.disconnected');
    switch (cs.status) {
      case CloudSyncStatus.authFailed:
      case CloudSyncStatus.error:
        return S.of('cloud.menu.auth_error');
      case CloudSyncStatus.pausedByUser:
        return S.of('cloud.menu.paused');
      // v0.1.34+133: approval gate states get their own labels.
      case CloudSyncStatus.pendingApproval:
        return S.of('cloud.status.pending_approval');
      case CloudSyncStatus.accessDenied:
        return S.of('cloud.status.access_denied');
      default: // idle | syncing | transient disconnected
        return S.of('cloud.menu.connected');
    }
  }

  @override
  Widget build(BuildContext context) {
    final svc = context.watch<ConnectionService>();
    // v0.1.29+100: head-unit signal for the vehicle Status tile. Same
    // truth source HAL uses ("are we on the HU?"). The car_status
    // provider only exists on the head unit, so the tile is hidden on
    // a phone.
    final hal = context.watch<HalTelemetryService>();
    // v0.1.29+58: subscribe to language changes. MaterialApp's const
    // home subtree shields this screen from top-level rebuilds, so the
    // screen watches LocaleService itself — switching the language
    // radio re-renders every S.of() string instantly.
    final locale = context.watch<LocaleService>();
    final wide = LayoutBreakpoints.useHeadUnitLayout(context);

    final connection = _groupCard(_connectionGroup(context, svc));
    final vehicle = _groupCard(_vehicleGroup(context, hal));
    final cost = _groupCard(_costGroup(context));
    final app = _groupCard(_appGroup(context, locale));

    return Scaffold(
      appBar: AppBar(title: Text(S.of('settings.title'))),
      body: ListView(
        padding: const EdgeInsets.only(bottom: 24),
        children: [
          _StatusTile(svc: svc),
          if (wide)
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [connection, vehicle],
                  ),
                ),
                Expanded(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [cost, app],
                  ),
                ),
              ],
            )
          else ...[
            connection,
            vehicle,
            cost,
            app,
          ],
          if (_advancedUnlocked)
            _advancedCard(context, svc),
        ],
      ),
    );
  }

  Widget _advancedCard(BuildContext context, ConnectionService svc) {
    // ════════════ Advanced (research tools, hidden) ════════════
    // v0.1.29+56: research/diagnostic tooling moved here from the
    // top-level list. Nothing is deleted — these tools are needed
    // for the upcoming HAL integration work — they're just out of
    // the casual user's way. Collapsed by default.
    // v0.1.29+59: hidden entirely until unlocked via 15 taps on
    // the APP card in About (advanced_unlocked pref).
    return ExpansionTile(
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
        // +163 (BB7, решение владельца 26.07 п.9): the «Замеры» diag
        // dump moved here from the measure screen — behind the same
        // 15-tap unlock the rest of the research tools live behind.
        // The service call is untouched (session + ledger JSON into
        // bz5_companion_diag.md, the Native Explorer diary workflow).
        ListTile(
          leading: const Icon(Icons.save_alt, color: Colors.grey),
          title: Text(S.of('settings.adv.dump')),
          subtitle: Text(S.of('settings.adv.dump_sub')),
          onTap: () async {
            final res =
                await context.read<SpeedProfileService>().dumpDiag();
            if (!context.mounted) return;
            ScaffoldMessenger.of(context).showSnackBar(SnackBar(
              content: Text(res == null
                  ? S.of('settings.adv.dump_fail')
                  : '${S.of('settings.adv.dump_ok')} ${res.path}'),
            ));
          },
        ),
        // v0.1.73+172: путь установки. Здесь, а не на верхнем уровне
        // (решение владельца 29.07) — это инструмент, а не функция для
        // ежедневного пользования, и живёт он за тем же 15-тапным
        // замком, что и остальная исследовательская оснастка.
        ListTile(
          leading: const Icon(Icons.system_update, color: Colors.grey),
          title: Text(S.of('settings.install.title')),
          subtitle: Text(S.of('settings.install.subtitle')),
          trailing: const Icon(Icons.chevron_right, color: Colors.grey),
          onTap: () => Navigator.of(context).push(
            MaterialPageRoute(
              builder: (_) => const InstallUpdateScreen(),
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
        // v0.1.29+122: on-device debugPrint ring buffer + CloudSync
        // internals (push-v2 gate, watermarks, cursors, last error).
        // Exists because the head unit has no ADB — see AppDiagScreen.
        ListTile(
          leading: const Icon(Icons.receipt_long, color: Colors.grey),
          title: Text(S.of('settings.appdiag.title')),
          subtitle: Text(S.of('settings.appdiag.subtitle')),
          trailing: const Icon(Icons.chevron_right, color: Colors.grey),
          onTap: () => Navigator.of(context).push(
            MaterialPageRoute(
              builder: (_) => const AppDiagScreen(),
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
        // ── v0.1.29+96 → moved here in +110: per-module charge logger.
        // A recon instrument (20 cell V + 20 module T under one
        // charging_session_id, all UDS/dongle) — not a daily-driver
        // control. It still MUST be started from Settings (not the
        // charging screen) BEFORE plug-in, so the baseline and the
        // pack_I sign-flip onset are both captured.
        Builder(builder: (context) {
          final active = svc.chargingLogActive;
          final rows = svc.chargingLogRowsWritten;
          final pass = svc.chargingBlockAvgPassSeconds;
          final passStr = pass != null ? pass.toStringAsFixed(1) : '—';
          return ListTile(
            leading: Icon(
              active ? Icons.fiber_manual_record : Icons.battery_charging_full,
              color: active ? Colors.redAccent : Colors.lightBlueAccent,
            ),
            title: Text(
                active ? S.of('chg.log.active') : S.of('chg.log.idle')),
            subtitle: Text(active
                ? S
                    .of('chg.log.stats')
                    .replaceFirst('{rows}', '$rows')
                    .replaceFirst('{pass}', passStr)
                : S.of('chg.log.hint')),
            trailing: active
                ? TextButton.icon(
                    icon: const Icon(Icons.stop, color: Colors.redAccent),
                    label: Text(S.of('chg.log.stop'),
                        style: const TextStyle(color: Colors.redAccent)),
                    onPressed: () => svc.stopChargingLog(),
                  )
                : TextButton.icon(
                    icon: const Icon(Icons.play_arrow,
                        color: Colors.lightGreenAccent),
                    label: Text(S.of('chg.log.start'),
                        style:
                            const TextStyle(color: Colors.lightGreenAccent)),
                    // v0.1.29+97: always tappable. The logger reads the
                    // modules over UDS, which needs the dongle connected —
                    // but a disabled grey button gave no clue WHY. Now the
                    // button is live; if the dongle isn't connected it shows
                    // an honest snackbar instead of doing nothing silently.
                    // On a real charge the dongle is connected, so it just
                    // starts.
                    onPressed: () {
                      if (svc.status == ConnectionStatus.connected) {
                        svc.startChargingLog(manual: true);
                      } else {
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(content: Text(S.of('dtc.not_connected'))),
                        );
                      }
                    },
                  ),
          );
        }),
        // Bridge diagnostic — cloud bridge debug telemetry.
        Builder(builder: (context) {
          final bd = context.watch<BridgeDiagService>();
          return Column(children: [
            _buildBridgeDiagHeader(bd),
            _buildBridgeDiagBody(context, bd),
          ]);
        }),
      ],
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

    // v0.1.29+110: localized human status instead of the raw enum name.
    // The dev polling-telemetry line (svc.statusMessage, "Polling N
    // DIDs @ X Hz") is REMOVED from the UI entirely (owner decision) —
    // internal jargon, not user information. The adapter address is
    // the only small print.
    final label = switch (svc.status) {
      ConnectionStatus.connected => S.of('settings.conn.connected'),
      ConnectionStatus.connecting => S.of('settings.conn.connecting'),
      ConnectionStatus.scanning => S.of('settings.conn.scanning'),
      ConnectionStatus.error => S.of('settings.conn.error'),
      ConnectionStatus.disconnected => S.of('settings.conn.disconnected'),
    };
    final addr = svc.adapterAddress;
    return Card(
      margin: const EdgeInsets.fromLTRB(12, 8, 12, 4),
      color: color.withOpacity(0.10),
      child: ListTile(
        leading: Icon(icon, color: color, size: 28),
        title: Text(label,
            style: TextStyle(color: color, fontWeight: FontWeight.w500)),
        subtitle: addr != null
            ? Text(
                S.of('settings.conn.adapter').replaceFirst('{addr}', addr))
            : null,
      ),
    );
  }
}

class _DeviceTile extends StatelessWidget {
  final ScanResult result;
  final VoidCallback onTap;

  const _DeviceTile({required this.result, required this.onTap});

  @override
  Widget build(BuildContext context) {
    // v0.1.29+110: '<unknown>' → localized human label.
    final name = result.advertisementData.advName.isEmpty
        ? S.of('settings.device.unknown')
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

/// Shared relative-time formatter — used by the cloud sub-screen
/// and the bridge-diag card in Advanced. Was a _SettingsScreenState
/// method; hoisted to file scope in +110 when the cloud block moved
/// to its own screen.
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

/// v0.1.42+141: the device-whoami line for the cloud block and the
/// pairing screen. Never fetched OK → '—' placeholder key (tap
/// refetches); account:null → "not linked"; otherwise
/// "Linked to a***@… · <status>".
String _deviceMeLine(CloudSyncService cs) {
  if (cs.deviceMeFetchedAt == null) return S.of('cloud.device_me.unknown');
  if (cs.deviceMeLinked == false) return S.of('cloud.device_me.not_linked');
  final email = cs.deviceMeEmail ?? '?';
  return '${S.of('cloud.device_me.linked').replaceFirst('{email}', email)}'
      ' · ${_deviceMeStatusLabel(cs.deviceMeStatus)}';
}

/// Same status dictionary as /v2/account/me — the l10n keys are shared
/// with the +133 gate where they exist (pending, rejected|blocked);
/// 'approved' gets its own key. An unknown word passes through raw
/// (server vocabulary may grow; raw beats hiding).
String _deviceMeStatusLabel(String? st) {
  switch (st) {
    case 'pending':
      return S.of('cloud.status.pending_approval');
    case 'approved':
      return S.of('cloud.device_me.approved');
    case 'rejected':
    case 'blocked':
      return S.of('cloud.status.access_denied');
    default:
      return st ?? '—';
  }
}


/// v0.1.29+110 (decision О1 — freeze & relocate): the ENTIRE cloud block
/// moved VERBATIM from the Settings top level to this sub-screen behind
/// the «Cloud services ›» entry (Settings → App group). Internals are
/// deliberately untouched — the cloud UX redesign (free app + paid cloud
/// services, phone↔car sync) is a separate future phase. The 4-state
/// summary lives on the Settings entry row; this screen keeps the
/// original detailed header/body and all five dialogs unchanged.
class CloudServicesScreen extends StatefulWidget {
  const CloudServicesScreen({super.key});

  @override
  State<CloudServicesScreen> createState() => _CloudServicesScreenState();
}

class _CloudServicesScreenState extends State<CloudServicesScreen> {
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
            // v0.1.42+141: device whoami — "linked to a***@… · status".
            // Tap = manual refetch (Alex Q2); shown on ALL platforms
            // (Q1: email arrives masked, no reason to gate). Display-
            // only: this line never drives CloudSyncStatus (Q3).
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: InkWell(
                onTap: () => cs.fetchDeviceMe(),
                child: Text(
                  _deviceMeLine(cs),
                  style: const TextStyle(fontSize: 12, color: Colors.grey),
                ),
              ),
            ),
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
            if (cs.lastError != null &&
                cs.status != CloudSyncStatus.pendingApproval &&
                cs.status != CloudSyncStatus.accessDenied) ...[
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
            // v0.1.34+133: approval-gate hints replace the raw error box
            // (the raw box would show the bare server code) — same visual
            // pattern, state-appropriate colors (Alex decision Q1).
            if (cs.status == CloudSyncStatus.pendingApproval) ...[
              const SizedBox(height: 4),
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: Colors.orange.withOpacity(0.15),
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Text(
                  S.of('cloud.pending_approval.hint'),
                  style: const TextStyle(
                      fontSize: 12, color: Colors.orangeAccent),
                ),
              ),
            ],
            if (cs.status == CloudSyncStatus.accessDenied) ...[
              const SizedBox(height: 4),
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: Colors.red.withOpacity(0.15),
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Text(
                  S.of('cloud.access_denied.hint'),
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
      // v0.1.34+133: approval gate (Alex decision Q1: pending = orange).
      case CloudSyncStatus.pendingApproval:
        return Colors.orangeAccent;
      case CloudSyncStatus.accessDenied:
        return Colors.redAccent;
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
      // v0.1.34+133: approval gate states.
      case CloudSyncStatus.pendingApproval:
        return S.of('cloud.status.pending_approval');
      case CloudSyncStatus.accessDenied:
        return S.of('cloud.status.access_denied');
    }
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
    final cs = context.watch<CloudSyncService>();
    return Scaffold(
      appBar: AppBar(title: Text(S.of('settings.cloud_services.title'))),
      body: ListView(
        padding: const EdgeInsets.only(bottom: 16),
        children: [
          _buildCloudHeader(cs),
          _buildCloudBody(context, cs),
          // v0.1.29+124 (C2): account (email OTP) — phone-side login,
          // device list + revoke. Separate credential from the device
          // token; the cloud-backup block above is untouched by it.
          Builder(builder: (context) {
            final auth = context.watch<AccountAuthService>();
            final signed = auth.isSignedIn;
            return ListTile(
              leading: Icon(Icons.account_circle_outlined,
                  color: signed ? Colors.lightBlueAccent : Colors.grey),
              title: Text(S.of('account.title')),
              subtitle: Text(signed
                  ? (auth.email ?? S.of('account.signed_in_as'))
                  : S.of('account.settings_subtitle')),
              trailing: const Icon(Icons.chevron_right, color: Colors.grey),
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const AccountScreen()),
              ),
            );
          }),
          // v0.1.29+127 (C3): device-side pairing (§1.2). Fresh device:
          // code → claim on the phone → token minted → auto-restore.
          // Live device: attaches this install to the account.
          ListTile(
            leading: const Icon(Icons.link, color: Colors.grey),
            title: Text(S.of('pairing.title')),
            subtitle: Text(S.of('pairing.settings_subtitle')),
            trailing: const Icon(Icons.chevron_right, color: Colors.grey),
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const PairingScreen()),
            ),
          ),
        ],
      ),
    );
  }
}
