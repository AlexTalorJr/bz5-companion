/// v0.1.29+100: Status screen — vehicle service health.
///
/// Reads the byd `car_status` ContentProvider (via [CarStatusService]):
/// health/issue flag, maintenance threshold, fluid/tyre reminder flags.
/// NO HAL, NO UDS, NO dongle for the provider data itself — but the
/// "remaining km to service" line needs a live odometer, which we resolve
/// from HAL (preferred) or OBD2, exactly like the wide dashboard.
///
/// Head-unit only: the provider does not exist on a phone. The entry
/// points (Settings tile, dashboard_wide card) are gated on
/// HalTelemetryService.canUseHal so this screen is only reachable where it
/// can succeed. If it is somehow opened with no provider, it shows an
/// honest "data unavailable" state.
///
/// Layout adapts: narrow (phone-width window) → stacked cards; wide (head
/// unit landscape) → the three summary blocks sit in a row.
library;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../l10n/strings.dart';
import '../services/car_status_service.dart';
import '../services/connection.dart';
import '../services/hal_telemetry_service.dart';
import '../services/locale_service.dart';
import '../widgets/responsive.dart';

class StatusScreen extends StatefulWidget {
  const StatusScreen({super.key});

  @override
  State<StatusScreen> createState() => _StatusScreenState();
}

class _StatusScreenState extends State<StatusScreen> {
  late final CarStatusService _service;

  @override
  void initState() {
    super.initState();
    // The screen owns its CarStatusService lifecycle — it is a leaf
    // feature, not something the rest of the app needs in the Provider
    // tree. Mirrors how settings.dart owns its NativeDetector.
    _service = CarStatusService();
    _service.refresh();
  }

  @override
  void dispose() {
    _service.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Live odometer for the "remaining km" computation, resolved the same
    // way as the wide dashboard: HAL when fresh, else OBD2 791/0026.
    final svc = context.watch<ConnectionService>();
    final hal = context.watch<HalTelemetryService>();
    // v0.1.29+100: per-screen language-rebuild contract (+58). The const
    // home subtree shields this route from MaterialApp rebuilds, so it
    // subscribes to LocaleService itself — switching language re-renders
    // every S.of() string here instantly.
    context.watch<LocaleService>();
    final odo =
        hal.useHalForOdometer ? hal.halOdometerKm : svc.readNumeric('791', '0026');

    return Scaffold(
      appBar: AppBar(
        title: Text(S.of('status.title')),
        actions: [
          AnimatedBuilder(
            animation: _service,
            builder: (_, __) => IconButton(
              icon: _service.loading
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.refresh),
              tooltip: S.of('status.refresh'),
              onPressed: _service.loading ? null : () => _service.refresh(),
            ),
          ),
        ],
      ),
      body: AnimatedBuilder(
        animation: _service,
        builder: (context, _) {
          final st = _service.status;
          final wide = LayoutBreakpoints.useHeadUnitLayout(context);
          return RefreshIndicator(
            onRefresh: () => _service.refresh(),
            child: ListView(
              padding: const EdgeInsets.all(12),
              children: [
                if (!st.available)
                  _UnavailableCard(loading: _service.loading)
                else if (wide)
                  _WideBody(status: st, odometerKm: odo)
                else
                  _NarrowBody(status: st, odometerKm: odo),
                const SizedBox(height: 16),
                _SourceFooter(lastFetch: _service.lastFetch),
              ],
            ),
          );
        },
      ),
    );
  }
}

// ─── bodies ────────────────────────────────────────────────────────────

class _NarrowBody extends StatelessWidget {
  final CarStatus status;
  final double? odometerKm;
  const _NarrowBody({required this.status, required this.odometerKm});

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        _HealthCard(status: status),
        const SizedBox(height: 12),
        _MaintenanceCard(status: status, odometerKm: odometerKm),
        const SizedBox(height: 12),
        _FluidsCard(status: status),
      ],
    );
  }
}

class _WideBody extends StatelessWidget {
  final CarStatus status;
  final double? odometerKm;
  const _WideBody({required this.status, required this.odometerKm});

  @override
  Widget build(BuildContext context) {
    return IntrinsicHeight(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(child: _HealthCard(status: status)),
          const SizedBox(width: 12),
          Expanded(
              child: _MaintenanceCard(status: status, odometerKm: odometerKm)),
          const SizedBox(width: 12),
          Expanded(child: _FluidsCard(status: status)),
        ],
      ),
    );
  }
}

// ─── cards ─────────────────────────────────────────────────────────────

class _HealthCard extends StatelessWidget {
  final CarStatus status;
  const _HealthCard({required this.status});

  @override
  Widget build(BuildContext context) {
    final healthy = status.isHealthy;
    final unknown = !status.hasHealthSignal;
    final n = status.issueNum;

    final Color bg;
    final Color fg;
    final IconData icon;
    final String title;
    final String sub;

    if (unknown) {
      bg = Colors.grey.withValues(alpha: 0.15);
      fg = Colors.grey;
      icon = Icons.help_outline;
      title = S.of('status.health.unknown');
      sub = S.of('status.health.unknown_sub');
    } else if (healthy) {
      bg = Colors.green.withValues(alpha: 0.15);
      fg = Colors.green;
      icon = Icons.check_circle;
      title = S.of('status.health.ok');
      sub = S.of('status.health.ok_sub');
    } else {
      bg = Colors.red.withValues(alpha: 0.15);
      fg = Colors.redAccent;
      icon = Icons.error;
      title = S.of('status.health.fault');
      sub = S
          .of('status.health.fault_sub')
          .replaceFirst('{n}', '${n ?? '?'}');
    }

    return Card(
      color: bg,
      elevation: 0,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          children: [
            Icon(icon, size: 40, color: fg),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(title,
                      style: TextStyle(
                          fontSize: 17, fontWeight: FontWeight.w600, color: fg)),
                  const SizedBox(height: 2),
                  Text(sub,
                      style: TextStyle(
                          fontSize: 13, color: fg.withValues(alpha: 0.85))),
                  // When there is a fault, show the raw issue list so the
                  // owner has something concrete to act on.
                  if (!healthy && !unknown &&
                      (status.issueRaw != null &&
                          status.issueRaw!.trim().isNotEmpty &&
                          status.issueRaw!.trim() != '[]')) ...[
                    const SizedBox(height: 8),
                    Text(status.issueRaw!,
                        style: TextStyle(
                            fontSize: 12,
                            color: fg,
                            fontFamily: 'monospace')),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _MaintenanceCard extends StatelessWidget {
  final CarStatus status;
  final double? odometerKm;
  const _MaintenanceCard({required this.status, required this.odometerKm});

  @override
  Widget build(BuildContext context) {
    final rem = status.remainingKmToService(odometerKm);
    final threshold = status.maintenanceMileThresholdKm;

    return Card(
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: Theme.of(context).dividerColor, width: 0.5),
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                Icon(Icons.build, size: 18, color: Theme.of(context).hintColor),
                const SizedBox(width: 8),
                Text(S.of('status.service.header'),
                    style: TextStyle(
                        fontSize: 13, color: Theme.of(context).hintColor)),
              ],
            ),
            const SizedBox(height: 14),
            Row(
              crossAxisAlignment: CrossAxisAlignment.baseline,
              textBaseline: TextBaseline.alphabetic,
              children: [
                Text(rem != null ? _grouped(rem) : '—',
                    style: const TextStyle(
                        fontSize: 32, fontWeight: FontWeight.w600)),
                const SizedBox(width: 8),
                Text(S.of('status.unit.km'),
                    style: TextStyle(
                        fontSize: 16, color: Theme.of(context).hintColor)),
              ],
            ),
            const SizedBox(height: 2),
            Text(
                rem != null
                    ? S.of('status.service.remaining')
                    : S.of('status.service.remaining_unknown'),
                style: TextStyle(
                    fontSize: 13, color: Theme.of(context).disabledColor)),
            const SizedBox(height: 14),
            const Divider(height: 1),
            const SizedBox(height: 12),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                _miniStat(
                  context,
                  S.of('status.service.threshold'),
                  threshold != null
                      ? '${_grouped(threshold)} ${S.of('status.unit.km')}'
                      : '—',
                ),
                _miniStat(
                  context,
                  S.of('status.service.odometer'),
                  odometerKm != null
                      ? '${_grouped(odometerKm!.round())} ${S.of('status.unit.km')}'
                      : '—',
                  alignEnd: true,
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _miniStat(BuildContext context, String label, String value,
      {bool alignEnd = false}) {
    return Column(
      crossAxisAlignment:
          alignEnd ? CrossAxisAlignment.end : CrossAxisAlignment.start,
      children: [
        Text(label,
            style:
                TextStyle(fontSize: 12, color: Theme.of(context).disabledColor)),
        const SizedBox(height: 2),
        Text(value,
            style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w500)),
      ],
    );
  }

  static String _grouped(int n) {
    // Thin-space thousands grouping (4347 → "4 347").
    final s = n.abs().toString();
    final buf = StringBuffer(n < 0 ? '-' : '');
    for (int i = 0; i < s.length; i++) {
      if (i > 0 && (s.length - i) % 3 == 0) buf.write('\u202F');
      buf.write(s[i]);
    }
    return buf.toString();
  }
}

class _FluidsCard extends StatelessWidget {
  final CarStatus status;
  const _FluidsCard({required this.status});

  // Map provider keys → localized labels. Kept here (UI layer) so the
  // service stays l10n-free.
  static const Map<String, String> _labelKeys = {
    'dicare_engine_oil_no_prompt': 'status.fluid.engine_oil',
    'dicare_at_fluid_no_prompt': 'status.fluid.at_fluid',
    'dicare_brake_fluid_no_prompt': 'status.fluid.brake_fluid',
    'dicare_battery_coolant_no_prompt': 'status.fluid.battery_coolant',
    'dicare_motor_coolant_no_prompt': 'status.fluid.motor_coolant',
    'tyre_pressure_guidance_no_prompt': 'status.fluid.tyre_pressure',
  };

  @override
  Widget build(BuildContext context) {
    final fluids = status.fluids;
    return Card(
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: Theme.of(context).dividerColor, width: 0.5),
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                Icon(Icons.water_drop,
                    size: 18, color: Theme.of(context).hintColor),
                const SizedBox(width: 8),
                Text(S.of('status.fluids.header'),
                    style: TextStyle(
                        fontSize: 13, color: Theme.of(context).hintColor)),
              ],
            ),
            const SizedBox(height: 8),
            if (fluids.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Text(S.of('status.fluids.none'),
                    style: TextStyle(
                        fontSize: 13,
                        color: Theme.of(context).disabledColor)),
              )
            else
              ...fluids.map((f) => _fluidRow(context, f)),
            const SizedBox(height: 8),
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.surfaceContainerHighest
                    .withValues(alpha: 0.4),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(Icons.info_outline,
                      size: 14, color: Theme.of(context).disabledColor),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(S.of('status.fluids.note'),
                        style: TextStyle(
                            fontSize: 12,
                            height: 1.4,
                            color: Theme.of(context).disabledColor)),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _fluidRow(BuildContext context, FluidFlag f) {
    final ok = f.isOk;
    final labelKey = _labelKeys[f.key] ?? f.key;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Expanded(
            child: Text(S.of(labelKey), style: const TextStyle(fontSize: 15)),
          ),
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(ok ? Icons.check : Icons.warning_amber,
                  size: 16,
                  color: ok ? Colors.green : Colors.orangeAccent),
              const SizedBox(width: 5),
              Text(
                  ok
                      ? S.of('status.fluid.ok')
                      : S.of('status.fluid.attention'),
                  style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w500,
                      color: ok ? Colors.green : Colors.orangeAccent)),
            ],
          ),
        ],
      ),
    );
  }
}

class _UnavailableCard extends StatelessWidget {
  final bool loading;
  const _UnavailableCard({required this.loading});

  @override
  Widget build(BuildContext context) {
    return Card(
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: Theme.of(context).dividerColor, width: 0.5),
      ),
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(loading ? Icons.hourglass_empty : Icons.cloud_off,
                size: 40, color: Theme.of(context).disabledColor),
            const SizedBox(height: 12),
            Text(
                loading
                    ? S.of('status.loading')
                    : S.of('status.unavailable'),
                textAlign: TextAlign.center,
                style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w500)),
            const SizedBox(height: 6),
            Text(S.of('status.unavailable_sub'),
                textAlign: TextAlign.center,
                style: TextStyle(
                    fontSize: 13, color: Theme.of(context).disabledColor)),
          ],
        ),
      ),
    );
  }
}

class _SourceFooter extends StatelessWidget {
  final DateTime? lastFetch;
  const _SourceFooter({required this.lastFetch});

  @override
  Widget build(BuildContext context) {
    final t = lastFetch;
    final stamp = t == null
        ? ''
        : ' · ${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}:${t.second.toString().padLeft(2, '0')}';
    return Center(
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.storage,
              size: 13, color: Theme.of(context).disabledColor),
          const SizedBox(width: 5),
          Text('car_status$stamp',
              style: TextStyle(
                  fontSize: 11, color: Theme.of(context).disabledColor)),
        ],
      ),
    );
  }
}
